import Foundation

/// v1.2 P1-7 启动项查看屏 —— 数据模型与扫描器。
///
/// 设计原则（与 [AppFootprint.swift](AppFootprint.swift) 同源）：
/// - **只读、不删** —— 这一屏只展示 ~/Library/LaunchAgents、/Library/LaunchAgents、
///   /Library/LaunchDaemons 三个目录下注册的 plist 文件，**不附带任何"清理"按钮**。
///   要禁用某个启动项请走 `launchctl bootout`，本 App 不代劳。
/// - **跳过损坏 plist** —— 任何解析失败的 plist 都直接 skip，不影响其他条目；
///   不抛出错误中断整次扫描（用户磁盘上偶尔有半截 plist 是常态）。
/// - **不写不删** —— scanner 只调 `Data(contentsOf:)` + `PropertyListSerialization` +
///   `attributesOfItem(atPath:)`，没有任何 `removeItem` / `recycle` / `unlink` 调用。

// MARK: - 数据模型

/// 启动项 plist 的作用域（用来在 UI 上分段展示）。
public enum LaunchAgentScope: String, Hashable, Sendable, CaseIterable {
    /// `~/Library/LaunchAgents` —— 用户级 agent，登录后随用户启动。
    case user
    /// `/Library/LaunchAgents` —— 系统级 agent，所有用户登录后启动。
    case system
    /// `/Library/LaunchDaemons` —— 系统级 daemon，开机即起，不依赖用户登录。
    case daemon

    /// 该 scope 对应的目录绝对路径（user 需注入 home 目录）。
    public func directoryPath(home: String) -> String {
        switch self {
        case .user:   return "\(home)/Library/LaunchAgents"
        case .system: return "/Library/LaunchAgents"
        case .daemon: return "/Library/LaunchDaemons"
        }
    }

    /// UI 展示用的中文名。
    public var displayName: String {
        switch self {
        case .user:   return "用户级 (~/Library/LaunchAgents)"
        case .system: return "系统级 (/Library/LaunchAgents)"
        case .daemon: return "守护进程 (/Library/LaunchDaemons)"
        }
    }
}

/// 单个 launchd plist 的展示模型。
///
/// 字段对应 launchd plist 标准 key：
/// - `Label`：必选；plist 缺它就视为损坏（会被 scanner 跳过）。
/// - `ProgramArguments`：可选；缺失时为空数组。某些 plist 用 `Program` 单字符串字段，
///   也会被归并到这里（首位 = Program，其余 = ProgramArguments[1...]）。
/// - `RunAtLoad`：可选 bool；缺失视为 false。
public struct LaunchAgentItem: Hashable, Sendable, Identifiable {
    public var id: String { path }
    /// plist 文件绝对路径（如 `~/Library/LaunchAgents/com.foo.bar.plist`）。
    public let path: String
    /// plist 内 `Label`（如 `com.foo.bar`）。
    public let label: String
    /// 合并后的 ProgramArguments —— 含可执行文件路径与全部参数。
    public let programArguments: [String]
    /// `RunAtLoad`（缺失视为 false）。
    public let runAtLoad: Bool
    /// plist 文件本身的字节数（FileManager attributes，不递归）。
    public let fileSize: Int64
    /// 该项所属作用域。
    public let scope: LaunchAgentScope

    public init(
        path: String,
        label: String,
        programArguments: [String],
        runAtLoad: Bool,
        fileSize: Int64,
        scope: LaunchAgentScope
    ) {
        self.path = path
        self.label = label
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.fileSize = fileSize
        self.scope = scope
    }
}

// MARK: - 文件系统抽象（便于测试注入）

/// 仅暴露本扫描所需的最小 IO 接口；实际生产用 [DefaultLaunchAgentFS]，
/// 测试用内存假实现（见 LaunchAgentScannerTests）。
///
/// **契约**：实现方必须保证所有方法都是只读 —— 不允许写、不允许删。
public protocol LaunchAgentFS: Sendable {
    /// 列出目录下的直接子项（返回绝对路径数组）。目录不存在时返回 nil。
    func listDirectory(_ path: String) -> [String]?
    /// 读取整个文件内容；失败返回 nil（权限不足、损坏等）。
    func readFile(_ path: String) -> Data?
    /// 取文件字节数；失败返回 0（不应让大小读取失败影响主流程）。
    func fileSize(_ path: String) -> Int64
}

/// 生产实现 —— 直接打 `FileManager` 与 `Data(contentsOf:)`。
public struct DefaultLaunchAgentFS: LaunchAgentFS {
    public init() {}

    public func listDirectory(_ path: String) -> [String]? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        return names.map { (path as NSString).appendingPathComponent($0) }
    }

    public func readFile(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let n = attrs?[.size] as? NSNumber {
            return n.int64Value
        }
        return 0
    }
}

// MARK: - 扫描器

/// 把三个 launchd 目录下的 .plist 文件聚合成 `[LaunchAgentItem]`。
///
/// 串行处理，因为 plist 单个就是几 KB，IO 不是瓶颈，并发反而引入复杂度。
public actor LaunchAgentScanner {
    private let fs: any LaunchAgentFS
    private let homeDirectory: String

    public init(
        fs: any LaunchAgentFS = DefaultLaunchAgentFS(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.fs = fs
        self.homeDirectory = homeDirectory
    }

    /// 主入口：扫描三个作用域，按 path 升序返回所有可解析 plist。
    ///
    /// 跳过策略（任一即跳，不影响其他条目）：
    /// - 目录不存在 / 不可读
    /// - 文件不是 `.plist` 后缀
    /// - 文件读取失败
    /// - plist 反序列化失败
    /// - plist 顶层不是 dict
    /// - 缺少 `Label` 或 Label 为空
    public func scanAll() -> [LaunchAgentItem] {
        var out: [LaunchAgentItem] = []
        for scope in LaunchAgentScope.allCases {
            out.append(contentsOf: scan(scope: scope))
        }
        out.sort { $0.path < $1.path }
        return out
    }

    /// 单 scope 扫描 —— 包内可见以便测试。
    func scan(scope: LaunchAgentScope) -> [LaunchAgentItem] {
        let dir = scope.directoryPath(home: homeDirectory)
        guard let children = fs.listDirectory(dir) else { return [] }
        var out: [LaunchAgentItem] = []
        out.reserveCapacity(children.count)
        for path in children {
            guard path.hasSuffix(".plist") else { continue }
            if let item = parsePlist(at: path, scope: scope) {
                out.append(item)
            }
        }
        return out
    }

    /// 解析单个 plist —— 包内可见以便测试。
    /// 任何错误情况都返回 nil（视为损坏，跳过）。
    func parsePlist(at path: String, scope: LaunchAgentScope) -> LaunchAgentItem? {
        guard let data = fs.readFile(path) else { return nil }
        guard
            let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = raw as? [String: Any]
        else {
            return nil
        }
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            return nil
        }
        let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
        let args = Self.extractProgramArguments(from: dict)
        let size = fs.fileSize(path)
        return LaunchAgentItem(
            path: path,
            label: label,
            programArguments: args,
            runAtLoad: runAtLoad,
            fileSize: size,
            scope: scope
        )
    }

    /// 合并 launchd 两种 program 写法：
    /// - `ProgramArguments`：`[String]` 完整参数列表。
    /// - `Program`：单 `String`，仅可执行路径，无参数。
    /// 两者并存时以 ProgramArguments 为准（launchd 实际行为）。
    static func extractProgramArguments(from dict: [String: Any]) -> [String] {
        if let argv = dict["ProgramArguments"] as? [String] {
            return argv
        }
        if let prog = dict["Program"] as? String, !prog.isEmpty {
            return [prog]
        }
        return []
    }
}
