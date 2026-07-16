import Foundation
import LogKit

/// Mole 对齐 M3-T4：pkgutil receipts 解析器。
///
/// macOS 安装的 `.pkg`（如 OEM 驱动、企业软件 MDM 推装、Apple 自家工具）
/// 会在 `/var/db/receipts/<pkgid>.bom` 留 BOM 包清单。`pkgutil` 命令能：
///   - `pkgutil --pkgs`             列出所有 pkgid
///   - `pkgutil --pkgs=<regex>`     按厂商前缀过滤（如 `com.adobe.*`）
///   - `pkgutil --files <pkgid>`    打出该 pkg 所安装的相对路径列表（**不含**前导斜杠）
///   - `pkgutil --pkg-info <pkgid>` 拿到 install-location（`volume` + `location`）
///
/// 本扫描器是**纯只读探测器**：列举可疑 pkg、解出绝对路径候选，
/// 真正删除依然走 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit) +
/// 用户勾选 + SafetyEngine 守门。它**不**调 `pkgutil --forget`（那是 root 权限动作）。
///
/// 注入策略：`runner` 默认是 `DefaultPkgutilRunner()` 走硬编码 `/usr/sbin/pkgutil`。
/// 单测可注入 `FakePkgutilRunner` 喂死数据，绕过子进程。
public struct PkgutilReceiptsScanner: Sendable {

    public struct Receipt: Sendable, Hashable {
        public let pkgID: String
        /// `pkgutil --pkg-info` 里的 `volume`（通常 `/`）+ `location`（如 `Library/Audio/Plug-Ins`）。
        /// `installAbsoluteRoot` 是它俩合并后的绝对前缀（**末尾不带 `/`**）。
        public let installAbsoluteRoot: String
        /// 该 pkg 安装时落下的所有相对路径（pkgutil --files 原样）。
        public let relativePaths: [String]

        public init(pkgID: String, installAbsoluteRoot: String, relativePaths: [String]) {
            self.pkgID = pkgID
            self.installAbsoluteRoot = installAbsoluteRoot
            self.relativePaths = relativePaths
        }

        /// 把相对路径展开成绝对路径。
        public var absolutePaths: [String] {
            relativePaths.map { rel in
                if installAbsoluteRoot.isEmpty || installAbsoluteRoot == "/" {
                    return "/" + rel.trimmingPrefix("/")
                }
                return installAbsoluteRoot + "/" + rel.trimmingPrefix("/")
            }
        }
    }

    public let runner: PkgutilRunning

    public init(runner: PkgutilRunning = DefaultPkgutilRunner()) {
        self.runner = runner
    }

    /// 按厂商前缀列举 receipt。
    ///
    /// 例：`receipts(matchingBundleIDPrefix: "com.adobe")` -> 所有 `com.adobe.*` pkg。
    /// `prefix` 为空返回所有 pkg（慎用：可能 200+ 条）。
    public func receipts(matchingBundleIDPrefix prefix: String) -> [Receipt] {
        let regex = prefix.isEmpty ? nil : Self.regexEscape(prefix) + ".*"
        guard let pkgList = runner.listPackages(matchingRegex: regex) else {
            GSYLog.warning(.app, "pkgutil --pkgs 调用失败 prefix=\(prefix)")
            return []
        }
        var out: [Receipt] = []
        out.reserveCapacity(pkgList.count)
        for pkgID in pkgList {
            guard let info = runner.packageInfo(pkgID: pkgID) else { continue }
            let files = runner.files(pkgID: pkgID) ?? []
            let root = Self.joinVolumeLocation(volume: info.volume, location: info.location)
            out.append(Receipt(pkgID: pkgID, installAbsoluteRoot: root, relativePaths: files))
        }
        return out
    }

    /// 把 `volume` + `location` 合成不带尾 `/` 的绝对路径。
    /// `volume="/"`, `location="Library/Audio"` -> `/Library/Audio`
    /// `volume="/"`, `location=""`               -> ``（空，表示根）
    static func joinVolumeLocation(volume: String, location: String) -> String {
        let vol = volume.isEmpty ? "/" : volume
        let loc = location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if loc.isEmpty { return vol == "/" ? "" : vol }
        let base = vol == "/" ? "" : vol
        return base + "/" + loc
    }

    /// pkgID 是 reverse-DNS，含 `.`。当 prefix 包含 `.` 时要给 regex 转义。
    static func regexEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if "\\.[]{}()*+?^$|/".contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}

// MARK: - Runner

public protocol PkgutilRunning: Sendable {
    /// `pkgutil --pkgs[=<regex>]`
    func listPackages(matchingRegex: String?) -> [String]?
    /// `pkgutil --pkg-info <pkgID>` 解出来的（volume, location, identifier 等）
    func packageInfo(pkgID: String) -> PkgutilPackageInfo?
    /// `pkgutil --files <pkgID>`
    func files(pkgID: String) -> [String]?
}

public struct PkgutilPackageInfo: Sendable, Hashable {
    public let pkgID: String
    public let volume: String
    public let location: String
    public let installTime: Date?

    public init(pkgID: String, volume: String, location: String, installTime: Date?) {
        self.pkgID = pkgID
        self.volume = volume
        self.location = location
        self.installTime = installTime
    }
}

/// 生产 runner —— 调 /usr/sbin/pkgutil。
public struct DefaultPkgutilRunner: PkgutilRunning {
    /// `pkgutil --files` 在大型 receipt 上可能输出数十万行。32 MiB 足以覆盖正常清单，
    /// 同时给异常输出设置明确内存上限；一旦截断就 fail closed，不解析半份路径清单。
    static let outputLimitPerStream = 32 * 1_024 * 1_024
    static let timeout: TimeInterval = 30

    private let commandExecutor: @Sendable ([String]) -> OwnedChildProcessExecutor.ExecutionResult

    public init() {
        commandExecutor = { args in
            // SAFETY v2026.07.16：生产路径固定为系统 pkgutil，不接受 caller 提供可执行文件。
            // 唯一 waitpid owner 消除 Foundation reap 后缓存 PID 被误 signal 的窗口，两个
            // pipe 从 launch 起持续排空，避免 `--files` 大输出填满 pipe 后永久等待。
            OwnedChildProcessExecutor.run(
                path: "/usr/sbin/pkgutil",
                arguments: args,
                timeout: Self.timeout,
                outputLimitPerStream: Self.outputLimitPerStream
            )
        }
    }

    /// 仅供 ScanKit 确定性测试注入无副作用 fixture；生产 public init 始终硬编码 pkgutil。
    init(commandExecutor: @escaping @Sendable ([String]) -> OwnedChildProcessExecutor.ExecutionResult) {
        self.commandExecutor = commandExecutor
    }

    public func listPackages(matchingRegex regex: String?) -> [String]? {
        var args: [String] = []
        if let regex { args.append("--pkgs=\(regex)") } else { args.append("--pkgs") }
        guard let output = run(args: args) else { return nil }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func packageInfo(pkgID: String) -> PkgutilPackageInfo? {
        guard let output = run(args: ["--pkg-info", pkgID]) else { return nil }
        var volume = "/"
        var location = ""
        var installTime: Date?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "volume": volume = value
            case "location": location = value
            case "install-time":
                if let epoch = TimeInterval(value) {
                    installTime = Date(timeIntervalSince1970: epoch)
                }
            default: break
            }
        }
        return PkgutilPackageInfo(pkgID: pkgID, volume: volume, location: location, installTime: installTime)
    }

    public func files(pkgID: String) -> [String]? {
        guard let output = run(args: ["--files", pkgID]) else { return nil }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func run(args: [String]) -> String? {
        let result = commandExecutor(args)
        guard case .exited(let rawStatus) = result.terminal,
              OwnedChildProcessExecutor.decodedExitStatus(rawStatus) == 0,
              result.readersReachedEOF,
              !result.stdoutWasTruncated else {
            // v2026.07.16：launch/nonzero/timeout/ownership lost 和不完整 stdout 均维持
            // 既有 nil 合同；stderr 仅是诊断，绝不能混入 pkgID 或文件路径解析。
            return nil
        }
        return result.stdout
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
