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
/// 真正删除依然走 [TrashPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit) +
/// 用户勾选 + SafetyEngine 守门。它**不**调 `pkgutil --forget`（那是 root 权限动作）。
///
/// 注入策略：`runner` 默认是 `DefaultPkgutilRunner()` 走硬编码 `/usr/sbin/pkgutil`。
/// 单测可注入 `FakePkgutilRunner` 喂死数据，绕过子进程。
public struct PkgutilReceiptsScanner: Sendable {

    /// `pkgutil` 发现链的精确阶段。列表失败意味着整条 receipt 支路不可信；
    /// 单个 info/files 失败只污染对应 pkgID，不能把其它 receipt 一起抹成失败。
    public enum IncompleteStage: String, Sendable, Hashable {
        case packageList
        case packageInfo
        case files
        /// The command completed, but its install root or one of its payload paths could not
        /// cross the lexical descendant boundary. A partial receipt is never published.
        case receiptValidation
    }

    /// 一条命令缺口的结构化证据。`pkgID == nil` 只允许用于全局 package list；
    /// 原始 stderr/launch 文本不会跨过 ScanKit 边界进入用户界面。
    public struct IncompleteIssue: Sendable, Hashable {
        public let stage: IncompleteStage
        public let pkgID: String?
        public let reason: PkgutilCommandFailure

        public init(
            stage: IncompleteStage,
            pkgID: String?,
            reason: PkgutilCommandFailure
        ) {
            self.stage = stage
            self.pkgID = pkgID
            self.reason = reason
        }
    }

    /// Receipt 命中与完整性证据必须来自同一次命令会话，禁止调用方只消费空数组。
    public struct ScanResult: Sendable, Equatable {
        public let receipts: [Receipt]
        public let incompleteIssues: [IncompleteIssue]

        public var isComplete: Bool { incompleteIssues.isEmpty }

        public init(receipts: [Receipt], incompleteIssues: [IncompleteIssue]) {
            self.receipts = receipts
            self.incompleteIssues = Array(Set(incompleteIssues)).sorted {
                if $0.stage != $1.stage { return $0.stage.rawValue < $1.stage.rawValue }
                if $0.pkgID != $1.pkgID { return ($0.pkgID ?? "") < ($1.pkgID ?? "") }
                return $0.reason.sortKey < $1.reason.sortKey
            }
        }
    }

    public struct Receipt: Sendable, Hashable {
        public let pkgID: String
        /// `pkgutil --pkg-info` 里的 `volume`（通常 `/`）+ `location`（如 `Library/Audio/Plug-Ins`）。
        /// `installAbsoluteRoot` 是它俩合并后的 canonical 绝对前缀；根卷表示为 `/`。
        public let installAbsoluteRoot: String
        /// 该 pkg 安装时落下的所有已验证相对路径。初始化边界会拒绝
        /// 绝对项、空项、`.` / `..` 组件、空组件和任何不是 root 严格后代的结果。
        public let relativePaths: [String]
        private let validatedAbsolutePaths: [String]

        /// Public construction uses the same trust boundary as production parsing. Returning nil
        /// is intentional: a caller cannot manufacture a `Receipt` whose `absolutePaths` escapes
        /// `installAbsoluteRoot`, even in tests or a future alternate runner.
        public init?(
            pkgID: String,
            installAbsoluteRoot: String,
            relativePaths: [String]
        ) {
            guard let canonicalRoot = PkgutilReceiptsScanner.canonicalAbsoluteRoot(
                installAbsoluteRoot
            ) else { return nil }
            var absolutePaths: [String] = []
            absolutePaths.reserveCapacity(relativePaths.count)
            for relativePath in relativePaths {
                guard let absolutePath = PkgutilReceiptsScanner.absoluteDescendant(
                    relativePath: relativePath,
                    canonicalRoot: canonicalRoot
                ) else { return nil }
                absolutePaths.append(absolutePath)
            }
            self.pkgID = pkgID
            self.installAbsoluteRoot = canonicalRoot
            self.relativePaths = relativePaths
            self.validatedAbsolutePaths = absolutePaths
        }

        /// 只返回初始化时已经证明为 install root 严格后代的 canonical 路径。
        public var absolutePaths: [String] {
            validatedAbsolutePaths
        }
    }

    public let runner: PkgutilRunning

    public init(runner: PkgutilRunning = DefaultPkgutilRunner()) {
        self.runner = runner
    }

    /// 按厂商前缀列举 receipt。
    ///
    /// 例：`receipts(matchingBundleIDPrefix: "com.adobe")` -> `com.adobe` 本身或所有
    /// `com.adobe.*` pkg；`com.adobeevil.*` 不是同一 reverse-DNS namespace。
    /// `prefix` 为空返回所有 pkg（慎用：可能 200+ 条）。
    public func receipts(matchingBundleIDPrefix prefix: String) -> ScanResult {
        // v2026.07.18：旧表达式 `com\\.adobe.*` 既没有首尾锚点，也没有 segment
        // 边界，`xcom.adobe.*` / `com.adobeevil.*` 都可能被 pkgutil 作为命中返回。
        // 查询端先收紧到 exact-or-dot-descendant；下面仍对系统命令结果做二次校验，
        // 不能把外部进程是否完整遵守 regexp 当成删除候选的信任边界。
        let regex = prefix.isEmpty
            ? nil
            : "^" + Self.regexEscape(prefix) + "(\\..*)?$"
        let pkgList: [String]
        do {
            pkgList = try runner.listPackages(matchingRegex: regex)
        } catch {
            let failure = Self.commandFailure(from: error)
            AmuxLog.warning(.app, "pkgutil --pkgs 调用失败 prefix=\(prefix) reason=\(failure.sortKey)")
            return ScanResult(
                receipts: [],
                incompleteIssues: [IncompleteIssue(
                    stage: .packageList,
                    pkgID: nil,
                    reason: failure
                )]
            )
        }
        var out: [Receipt] = []
        var incompleteIssues: [IncompleteIssue] = []
        out.reserveCapacity(pkgList.count)
        for pkgID in pkgList {
            guard prefix.isEmpty || Self.isStrictReverseDNSMatch(pkgID, prefix: prefix) else {
                AmuxLog.warning(
                    .app,
                    "pkgutil returned out-of-namespace package ID prefix=\(prefix) pkgID=\(pkgID)"
                )
                continue
            }
            let info: PkgutilPackageInfo
            do {
                info = try runner.packageInfo(pkgID: pkgID)
            } catch {
                let failure = Self.commandFailure(from: error)
                incompleteIssues.append(IncompleteIssue(
                    stage: .packageInfo,
                    pkgID: pkgID,
                    reason: failure
                ))
                AmuxLog.warning(.app, "pkgutil --pkg-info 调用失败 pkgID=\(pkgID) reason=\(failure.sortKey)")
                continue
            }
            let files: [String]
            do {
                files = try runner.files(pkgID: pkgID)
            } catch {
                let failure = Self.commandFailure(from: error)
                incompleteIssues.append(IncompleteIssue(
                    stage: .files,
                    pkgID: pkgID,
                    reason: failure
                ))
                AmuxLog.warning(.app, "pkgutil --files 调用失败 pkgID=\(pkgID) reason=\(failure.sortKey)")
                continue
            }
            guard let root = Self.joinVolumeLocation(
                volume: info.volume,
                location: info.location
            ) else {
                incompleteIssues.append(IncompleteIssue(
                    stage: .receiptValidation,
                    pkgID: pkgID,
                    reason: .invalidInstallRoot
                ))
                AmuxLog.warning(.app, "pkgutil receipt install root rejected pkgID=\(pkgID)")
                continue
            }
            guard let receipt = Receipt(
                pkgID: pkgID,
                installAbsoluteRoot: root,
                relativePaths: files
            ) else {
                incompleteIssues.append(IncompleteIssue(
                    stage: .receiptValidation,
                    pkgID: pkgID,
                    reason: .invalidRelativePath
                ))
                AmuxLog.warning(.app, "pkgutil receipt payload path rejected pkgID=\(pkgID)")
                continue
            }
            out.append(receipt)
        }
        return ScanResult(receipts: out, incompleteIssues: incompleteIssues)
    }

    private static func commandFailure(from error: Error) -> PkgutilCommandFailure {
        (error as? PkgutilCommandFailure) ?? .unexpectedFailure
    }

    /// 把 `volume` + `location` 合成 canonical 绝对路径。两个输入都是
    /// `pkgutil --pkg-info` 的不可信文本：volume 必须是无 `.` / `..` 的绝对路径，
    /// location 只能是空字符串或无空组件的相对路径。
    /// `volume="/"`, `location="Library/Audio"` -> `/Library/Audio`
    /// `volume="/"`, `location=""`               -> `/`
    static func joinVolumeLocation(volume: String, location: String) -> String? {
        guard let canonicalVolume = canonicalAbsoluteRoot(volume) else { return nil }
        // `pkgutil --pkg-info` legitimately emits both `location: /` and directory locations with
        // one trailing slash (for example `Library/Apple/`). Canonicalize only those two surface
        // forms; a different absolute location or internal empty component remains invalid.
        let relativeLocation: String
        if location == "/" || location.isEmpty {
            relativeLocation = ""
        } else if location.hasSuffix("/") {
            relativeLocation = String(location.dropLast())
        } else {
            relativeLocation = location
        }
        guard !relativeLocation.hasPrefix("/") else { return nil }
        if relativeLocation.isEmpty { return canonicalVolume }
        guard let joined = absoluteDescendant(
            relativePath: relativeLocation,
            canonicalRoot: canonicalVolume
        ) else { return nil }
        return joined
    }

    /// Lexical canonicalization only. Receipt paths can point to absent payloads, so resolving the
    /// current symlink topology would make a historical receipt depend on mutable filesystem state.
    private static func canonicalAbsoluteRoot(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        if raw == "/" { return "/" }
        guard !raw.hasSuffix("/") else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        // A leading slash owns the first empty component. Any later empty, dot or dot-dot
        // component makes the source non-canonical/ambiguous and is rejected rather than repaired.
        guard components.first?.isEmpty == true else { return nil }
        let tail = components.dropFirst()
        guard tail.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let canonical = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        guard canonical.hasPrefix("/") else { return nil }
        return canonical
    }

    private static func absoluteDescendant(
        relativePath: String,
        canonicalRoot: String
    ) -> String? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let candidate = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL.path
        let descendantPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        guard candidate != canonicalRoot, candidate.hasPrefix(descendantPrefix) else { return nil }
        return candidate
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

    /// Reverse-DNS namespace matching is segment based, never a raw string prefix.
    /// Keeping this check separate from the external regexp makes the trust boundary testable.
    static func isStrictReverseDNSMatch(_ pkgID: String, prefix: String) -> Bool {
        pkgID == prefix || pkgID.hasPrefix(prefix + ".")
    }
}

// MARK: - Runner

public protocol PkgutilRunning: Sendable {
    /// `pkgutil --pkgs[=<regex>]`
    func listPackages(matchingRegex: String?) throws -> [String]
    /// `pkgutil --pkg-info <pkgID>` 解出来的（volume, location, identifier 等）
    func packageInfo(pkgID: String) throws -> PkgutilPackageInfo
    /// `pkgutil --files <pkgID>`
    func files(pkgID: String) throws -> [String]
}

/// 子进程或 receipt 结构失败只保存控制流事实，不保存 raw
/// stderr/系统错误/被拒绝路径。这些 reason 可用于结构化日志和 typed
/// presentation，不得直接作为用户文案。
public enum PkgutilCommandFailure: Error, Sendable, Hashable {
    case launchFailed
    case nonZeroExit(Int32)
    case timedOut
    case cancelled
    case processOwnershipLost
    case outputTruncated
    case incompleteOutput
    case unexpectedFailure
    case invalidInstallRoot
    case invalidRelativePath

    fileprivate var sortKey: String {
        switch self {
        case .launchFailed: return "launchFailed"
        case .nonZeroExit(let code): return "nonZeroExit:\(code)"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .processOwnershipLost: return "processOwnershipLost"
        case .outputTruncated: return "outputTruncated"
        case .incompleteOutput: return "incompleteOutput"
        case .unexpectedFailure: return "unexpectedFailure"
        case .invalidInstallRoot: return "invalidInstallRoot"
        case .invalidRelativePath: return "invalidRelativePath"
        }
    }
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
                outputLimitPerStream: Self.outputLimitPerStream,
                isCancelled: {
                    withUnsafeCurrentTask { $0?.isCancelled ?? false }
                }
            )
        }
    }

    /// 仅供 ScanKit 确定性测试注入无副作用 fixture；生产 public init 始终硬编码 pkgutil。
    init(commandExecutor: @escaping @Sendable ([String]) -> OwnedChildProcessExecutor.ExecutionResult) {
        self.commandExecutor = commandExecutor
    }

    public func listPackages(matchingRegex regex: String?) throws -> [String] {
        var args: [String] = []
        if let regex { args.append("--pkgs=\(regex)") } else { args.append("--pkgs") }
        let output = try run(args: args)
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func packageInfo(pkgID: String) throws -> PkgutilPackageInfo {
        let output = try run(args: ["--pkg-info", pkgID])
        var volume: String?
        var location: String?
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
        // A successful exit with missing structural fields is still incomplete output. Defaulting
        // it to `/` would silently turn a malformed install root into a trusted filesystem root.
        guard let volume, let location else {
            throw PkgutilCommandFailure.incompleteOutput
        }
        return PkgutilPackageInfo(pkgID: pkgID, volume: volume, location: location, installTime: installTime)
    }

    public func files(pkgID: String) throws -> [String] {
        let output = try run(args: ["--files", pkgID])
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func run(args: [String]) throws -> String {
        let result = commandExecutor(args)
        switch result.terminal {
        case .launchFailed:
            throw PkgutilCommandFailure.launchFailed
        case .timedOut:
            throw PkgutilCommandFailure.timedOut
        case .cancelled:
            throw PkgutilCommandFailure.cancelled
        case .notOwned:
            throw PkgutilCommandFailure.processOwnershipLost
        case .exited(let rawStatus):
            let exitCode = OwnedChildProcessExecutor.decodedExitStatus(rawStatus)
            guard exitCode == 0 else {
                throw PkgutilCommandFailure.nonZeroExit(exitCode)
            }
        }
        guard result.readersReachedEOF else {
            throw PkgutilCommandFailure.incompleteOutput
        }
        guard !result.stdoutWasTruncated else {
            throw PkgutilCommandFailure.outputTruncated
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
