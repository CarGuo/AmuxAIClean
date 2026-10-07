import Foundation

/// 一个 Dart/Flutter 相关进程在雷达中扮演的角色。
///
/// 角色只依据进程的可执行文件与命令行判定，属于可离线测试的纯函数归类；不猜测进程
/// “可能在做什么”。非 Dart/Flutter 进程不会被赋予 `.other`，而是直接不进入雷达，
/// 避免把 node、Gradle 等无关进程混进列表。
public enum DartProcessRole: String, Hashable, Sendable, CaseIterable {
    case flutterTools
    case dartVM
    case dartAOT
    case frontendServer
    case dds
    case devtools
    case flutterTester
    case analyzer
    case mcpServer
    case genSnapshot
    case puro

    public var titleKey: String {
        "dart_radar.role.\(rawValue)"
    }

    public var symbol: String {
        switch self {
        case .flutterTools: "hammer.fill"
        case .dartVM: "circle.grid.2x2"
        case .dartAOT: "bolt.fill"
        case .frontendServer: "server.rack"
        case .dds: "network"
        case .devtools: "slider.horizontal.3"
        case .flutterTester: "testtube.2"
        case .analyzer: "magnifyingglass"
        case .mcpServer: "plug.fill"
        case .genSnapshot: "cpu"
        case .puro: "cube.box.fill"
        }
    }
}

/// 谁（哪个上层应用/环境）最终启动了这条 Dart 进程链。
///
/// 雷达列出的是 Dart 工作进程；IDE、终端等只作为“启动来源”归因，不会因为开着一个
/// IDE 就出现在列表里。固定来源走本地化文案；`.other` 保留进程自身名字用于技术展示。
public enum DartLauncher: Hashable, Sendable {
    case vsCode
    case androidStudio
    case intelliJ
    case xcode
    case terminal
    case puro
    case toolchain
    case other(name: String)
    case unknown

    public var titleKey: String? {
        switch self {
        case .vsCode: "dart_radar.launcher.vs_code"
        case .androidStudio: "dart_radar.launcher.android_studio"
        case .intelliJ: "dart_radar.launcher.intellij"
        case .xcode: "dart_radar.launcher.xcode"
        case .terminal: "dart_radar.launcher.terminal"
        case .puro: "dart_radar.launcher.puro"
        case .toolchain: "dart_radar.launcher.toolchain"
        case .unknown: "dart_radar.launcher.unknown"
        case .other: nil
        }
    }

    public func title(locale: Locale) -> String {
        guard let titleKey else {
            if case .other(let name) = self { return name }
            return ""
        }
        return AppLocalization.string(titleKey, locale: locale)
    }

    public var symbol: String {
        switch self {
        case .vsCode: "chevron.left.forwardslash.chevron.right"
        case .androidStudio: "a.circle.fill"
        case .intelliJ: "app.fill"
        case .xcode: "hammer.fill"
        case .terminal: "terminal.fill"
        case .puro: "cube.box.fill"
        case .toolchain: "wrench.and.screwdriver.fill"
        case .other: "questionmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

/// `ps` 一行的最小数字与命令行快照。可执行文件路径刻意不从这一行解析：macOS 应用路径
/// 可以含空格（如 “Android Studio.app”），命令行拼接后无法可靠切分出第一个参数；
/// 真正的可执行路径由内核 `proc_pidpath` 单独提供。
struct DartRawProcess: Hashable, Sendable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let arguments: String

    var shortName: String {
        Self.firstToken(in: arguments).split(separator: "/").last.map(String.init) ?? "?"
    }

    static func firstToken(in text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .prefix(while: { !$0.isWhitespace })
            .description
    }
}

/// 雷达列表中的一条完整记录。身份、资源占用与归因都在同一次扫描中冻结。
public struct DartProcessEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let pid: Int32
    public let ppid: Int32
    public let role: DartProcessRole
    public let cpuPercent: Double
    public let memoryBytes: Int64
    public let executablePath: String
    public let arguments: String
    public let workingDirectory: String?
    public let projectPath: String?
    public let projectName: String?
    public let launcher: DartLauncher
    public let parentName: String?
    public let identity: ProcessIdentity

    public init(
        pid: Int32,
        ppid: Int32,
        role: DartProcessRole,
        cpuPercent: Double,
        memoryBytes: Int64,
        executablePath: String,
        arguments: String,
        workingDirectory: String?,
        projectPath: String?,
        projectName: String?,
        launcher: DartLauncher,
        parentName: String?,
        identity: ProcessIdentity
    ) {
        self.pid = pid
        self.ppid = ppid
        self.role = role
        self.cpuPercent = max(0, cpuPercent)
        self.memoryBytes = max(0, memoryBytes)
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.projectPath = projectPath
        self.projectName = projectName
        self.launcher = launcher
        self.parentName = parentName
        self.identity = identity
        self.id = "\(pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)"
    }

    /// 只有扫描期冻结了完整内核身份、且执行层保护未命中的进程，才允许结束。
    /// PID reuse 重验与 SIGTERM 提交统一由通用 ProcessTerminationExecutor 负责。
    public var canTerminate: Bool {
        ProcessTerminationPolicy.executionProtection(for: identity) == nil
    }
}

/// 进程资源占用排序的唯一口径：先比 CPU，再比内存，最后比 PID。扫描器与项目分组共用。
public enum DartProcessRanking {
    public static func byLoad(_ lhs: DartProcessEntry, _ rhs: DartProcessEntry) -> Bool {
        if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
        if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        return lhs.pid < rhs.pid
    }
}

/// 一个项目归档分组。有真实 pubspec.yaml 的进程按项目路径聚成一组；归不进任何项目的
/// 进程统一放到 `path == nil` 的「未归属」组。组头展示该项目的进程数与总资源占用。
public struct DartProjectGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String?
    public let entries: [DartProcessEntry]
    public let cpuTotal: Double
    public let memoryTotal: Int64

    public var isUnassigned: Bool { path == nil }
}

public enum DartProjectGrouper {
    public static let unassignedID = "__dart_radar_unassigned_group__"

    public static func groups(from entries: [DartProcessEntry]) -> [DartProjectGroup] {
        var byPath: [String: [DartProcessEntry]] = [:]
        var order: [String] = []
        var unassigned: [DartProcessEntry] = []

        for entry in entries {
            if let path = entry.projectPath {
                if byPath[path] == nil { order.append(path) }
                byPath[path, default: []].append(entry)
            } else {
                unassigned.append(entry)
            }
        }

        var groups: [DartProjectGroup] = order.compactMap { path in
            guard let items = byPath[path] else { return nil }
            return makeGroup(
                id: path,
                title: items.first?.projectName ?? path,
                path: path,
                entries: items
            )
        }
        groups.sort { groupRanking($0, $1) }

        if !unassigned.isEmpty {
            groups.append(makeGroup(
                id: unassignedID,
                title: "",
                path: nil,
                entries: unassigned
            ))
        }
        return groups
    }

    private static func makeGroup(
        id: String,
        title: String,
        path: String?,
        entries: [DartProcessEntry]
    ) -> DartProjectGroup {
        let sorted = entries.sorted(by: DartProcessRanking.byLoad)
        return DartProjectGroup(
            id: id,
            title: title,
            path: path,
            entries: sorted,
            cpuTotal: sorted.reduce(0) { $0 + $1.cpuPercent },
            memoryTotal: sorted.reduce(0) { $0 + $1.memoryBytes }
        )
    }

    private static func groupRanking(_ lhs: DartProjectGroup, _ rhs: DartProjectGroup) -> Bool {
        if lhs.cpuTotal != rhs.cpuTotal { return lhs.cpuTotal > rhs.cpuTotal }
        if lhs.memoryTotal != rhs.memoryTotal { return lhs.memoryTotal > rhs.memoryTotal }
        return lhs.id < rhs.id
    }
}

/// Dart 雷达的全部解析与归因都是无副作用的纯函数，便于以固定输入做行为测试。
enum DartRadarParser {
    /// 解析 `ps -axo pid=,ppid=,uid=,command=` 的整表输出。
    static func parseProcessTable(_ text: String) -> [DartRawProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            parseProcessLine(String(line))
        }
    }

    static func parseProcessLine(_ raw: String) -> DartRawProcess? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        // 前 3 列是无空格数字，maxSplits: 3 之后的第 4 段保留命令行中的全部空格。
        let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard columns.count >= 4,
              let pid = Int32(columns[0]),
              let ppid = Int32(columns[1]),
              let uid = UInt32(columns[2]) else {
            return nil
        }
        return DartRawProcess(
            pid: pid,
            ppid: ppid,
            uid: uid,
            arguments: String(columns[3])
        )
    }

    /// 判断一条命令行是否属于 Dart/Flutter 工作进程，并给出角色；无关进程返回 nil。
    static func classify(_ arguments: String) -> DartProcessRole? {
        let first = DartRawProcess.firstToken(in: arguments)
        let base = first.split(separator: "/").last.map(String.init)?.lowercased() ?? ""

        switch base {
        case "flutter_tester":
            return .flutterTester
        case "gen_snapshot":
            return .genSnapshot
        case "puro":
            return .puro
        case "dartaotruntime":
            if arguments.contains("frontend_server") { return .frontendServer }
            if arguments.contains("dds_aot") { return .dds }
            if arguments.contains("devtools") { return .devtools }
            return .dartAOT
        case "dart", "dartvm":
            if arguments.contains("flutter_tools.snapshot") { return .flutterTools }
            if arguments.contains("mcp-server") { return .mcpServer }
            if arguments.contains("analysis_server") { return .analyzer }
            if arguments.contains("devtools") { return .devtools }
            return .dartVM
        default:
            break
        }

        // 可执行首 token 无法可靠切分（路径含空格）或被改名时，用命令行中的强信号兜底，
        // 但只承认明确的 Dart/Flutter 工件，避免把普通 node/java 进程误纳入。
        if arguments.contains("flutter_tools.snapshot") { return .flutterTools }
        if arguments.contains("flutter_tester") { return .flutterTester }
        if base.contains("analysis_server") { return .analyzer }
        if base == "dart_mcp_server" || arguments.contains("dart_mcp_server") {
            return .mcpServer
        }
        if base.hasPrefix("frontend_server") { return .frontendServer }
        return nil
    }

    /// 提取命令行中所有 `--packages` 指向的 package_config 路径，保持出现顺序。
    /// 同时兼容 `--packages=PATH`、`--packages PATH` 与 `file://` URI 三种写法。
    static func packageConfigPaths(_ arguments: String) -> [String] {
        let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--packages=") {
                appendPath(String(token.dropFirst("--packages=".count)), into: &paths)
            } else if token == "--packages", index + 1 < tokens.count {
                appendPath(tokens[index + 1], into: &paths)
                index += 1
            }
            index += 1
        }
        return paths
    }

    private static func appendPath(_ raw: String, into paths: inout [String]) {
        let path = sanitizePath(raw)
        guard !path.isEmpty, !paths.contains(path) else { return }
        paths.append(path)
    }

    private static func sanitizePath(_ raw: String) -> String {
        var value = raw
        if let url = URL(string: value), url.scheme == "file" {
            value = url.path
        } else if value.hasPrefix("file://") {
            value = String(value.dropFirst("file://".count))
        }
        return value.removingPercentEncoding ?? value
    }

    /// SDK 自带的 flutter_tools / dart-sdk 内部包配置不是“用户项目”，必须排除，
    /// 否则每条 flutter 命令都会被错误归到 Flutter SDK 目录。
    static func isToolchainReference(_ path: String) -> Bool {
        path.contains("/dart-sdk/")
            || path.contains("/flutter_tools/")
            || path.contains("/flutter/bin/cache/")
    }

    /// `.../project/.dart_tool/package_config.json` → `.../project`。
    static func projectRoot(forPackageConfig path: String) -> String? {
        let suffix = "/.dart_tool/package_config.json"
        guard path.hasSuffix(suffix) else { return nil }
        let root = String(path.dropLast(suffix.count))
        return root.isEmpty ? nil : root
    }

    /// 解析 `lsof -a -d cwd -Fn` 的输出，得到 pid → 工作目录。
    static func parseWorkingDirectories(_ text: String) -> [Int32: String] {
        var currentPID: Int32?
        var result: [Int32: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n"), let pid = currentPID {
                let path = String(line.dropFirst())
                if !path.isEmpty { result[pid] = path }
            }
        }
        return result
    }

    /// 解析 `top -l 1 -n N -stats pid,command,mem` 的输出，得到 pid → 物理足迹字节数。
    /// MEM 是带单位后缀的物理足迹（与活动监视器“内存”同口径），如 791M / 1.2G / 512K。
    static func parseFootprints(_ text: String) -> [Int32: Int64] {
        var result: [Int32: Int64] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let tokens = raw.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2,
                  let pid = Int32(tokens[0]),
                  let bytes = parseByteCount(String(tokens[tokens.count - 1])) else {
                continue
            }
            result[pid] = bytes
        }
        return result
    }

    /// 把 `top` 的内存大小（123B/26K/791M/1.5G，以及带 +/- 变动标记的值如 791M+）解析成字节数。
    static func parseByteCount(_ text: String) -> Int64? {
        var value = text.trimmingCharacters(in: .whitespaces)
        while let last = value.last, last == "+" || last == "-" {
            value.removeLast()
        }
        guard let suffix = value.last, let multiplier = byteUnitMultiplier(suffix) else {
            return nil
        }
        let numberPart = String(value.dropLast())
        guard let number = Double(numberPart), number.isFinite else { return nil }
        let bytes = number * Double(multiplier)
        guard bytes.isFinite, bytes < Double(Int64.max) else { return Int64.max }
        return Int64(bytes)
    }

    private static func byteUnitMultiplier(_ character: Character) -> Int64? {
        switch character {
        case "B": 1
        case "K": 1024
        case "M": 1024 * 1024
        case "G": 1024 * 1024 * 1024
        case "T": 1024 * 1024 * 1024 * 1024
        default: nil
        }
    }

    /// 在同一次进程表快照内沿父链向上，定位启动来源与直接父进程名。
    /// 纯函数 + 防环，输入表缺失时收敛到 `.unknown`，绝不跨快照引用。
    static func resolveLauncher(
        for pid: Int32,
        processTable: [Int32: DartRawProcess]
    ) -> (launcher: DartLauncher, parentName: String?) {
        guard let start = processTable[pid] else { return (.unknown, nil) }
        let directParent = processTable[start.ppid]
        let parentName = directParent?.shortName

        var currentPID = start.ppid
        var visited = Set<Int32>([pid])
        var firstOutsideToolchainName: String?

        while let row = processTable[currentPID], !visited.contains(row.pid) {
            visited.insert(row.pid)

            if let known = knownLauncher(for: row) {
                return (known, parentName)
            }

            // Dart/Flutter 工具链自身的祖先行继续向上跳过；第一个“外部”祖先先记下来，
            // 作为已知 IDE/终端都没命中时的 `.other` 归因。
            if classify(row.arguments) == nil, firstOutsideToolchainName == nil {
                let name = row.shortName
                if name != "launchd" { firstOutsideToolchainName = name }
            }
            currentPID = row.ppid
        }

        if let name = firstOutsideToolchainName {
            return (.other(name: name), parentName)
        }
        if visited.contains(1) {
            return (.toolchain, parentName)
        }
        return (.unknown, parentName)
    }

    private static func knownLauncher(for row: DartRawProcess) -> DartLauncher? {
        let args = row.arguments
        if args.contains("Visual Studio Code.app/Contents") { return .vsCode }
        if args.contains("Android Studio.app/Contents") { return .androidStudio }
        if args.contains("IntelliJ IDEA.app/Contents")
            || args.contains("IntelliJ IDEA CE.app/Contents") {
            return .intelliJ
        }
        if args.contains("/Xcode.app/Contents/") { return .xcode }
        if args.contains("iTerm.app/Contents")
            || args.contains("Terminal.app/Contents")
            || args.contains("Warp.app/Contents")
            || args.contains("Ghostty.app/Contents")
            || args.contains("Alacritty.app/Contents")
            || args.contains("Kitty.app/Contents") {
            return .terminal
        }

        let base = row.shortName.lowercased()
        if ["zsh", "bash", "fish", "tmux"].contains(base) { return .terminal }
        if base == "puro" { return .puro }
        return nil
    }
}
