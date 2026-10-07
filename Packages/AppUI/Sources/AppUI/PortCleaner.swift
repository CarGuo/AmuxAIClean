import Darwin
import Foundation
import LogKit

public enum PortCleanerProtocol: String, CaseIterable, Hashable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
    case tcp6 = "TCP6"
    case udp6 = "UDP6"
}

/// 冻结在端口扫描时的进程身份，而不是把可复用的 PID 当成进程身份。
///
/// v2026.07.16：进程可能在确认弹窗停留期间退出，随后 macOS 会把同一个 PID 分配给
/// 另一个进程。执行前必须同时重验 PID、真实 UID、可执行文件路径和内核启动时间，任何
/// 字段变化都拒绝发送信号，避免 PID reuse 误伤无关进程。
public struct PortCleanerProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let executablePath: String
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(
        pid: Int32,
        uid: UInt32,
        executablePath: String,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64
    ) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct PortCleanerEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let proto: PortCleanerProtocol
    public let localAddress: String
    public let localPort: Int
    public let remoteAddress: String?
    public let remotePort: Int?
    public let state: String?
    public let pid: Int32
    public let processName: String
    public let processPath: String?
    public let user: String?
    public let processIdentity: PortCleanerProcessIdentity?

    public init(
        proto: PortCleanerProtocol,
        localAddress: String,
        localPort: Int,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        state: String? = nil,
        pid: Int32,
        processName: String,
        processPath: String? = nil,
        user: String? = nil,
        processIdentity: PortCleanerProcessIdentity? = nil
    ) {
        self.proto = proto
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.pid = pid
        self.processName = processName
        self.processPath = processPath
        self.user = user
        self.processIdentity = processIdentity
        self.id = [
            proto.rawValue,
            localAddress,
            String(localPort),
            remoteAddress ?? "",
            remotePort.map(String.init) ?? "",
            String(pid),
            processIdentity.map { String($0.startTimeSeconds) } ?? "",
            processIdentity.map { String($0.startTimeMicroseconds) } ?? ""
        ].joined(separator: "|")
    }

    public var localEndpoint: String {
        "\(localAddress):\(localPort)"
    }

    public var remoteEndpoint: String {
        guard let remoteAddress, let remotePort else { return "-" }
        return "\(remoteAddress):\(remotePort)"
    }

    public var terminationProtection: PortCleanerTerminationProtection? {
        if pid <= 1 { return .invalidPID }
        guard let processIdentity else { return .identityUnavailable }
        if let protection = PortCleanerProcessPolicy.executionProtection(for: processIdentity) {
            return protection
        }
        if processName.hasPrefix("com.apple.") { return .systemProcess }
        return nil
    }

    public var canRequestTermination: Bool {
        terminationProtection == nil
    }

    /// v2026.07.16：扫描期和执行期共用同一份路径保护规则，防止 UI 允许、执行层却按
    /// 不同口径发送信号。执行层仍会独立重验，View 的 disabled 不是安全边界。
    static func isProtectedSystemPath(_ path: String) -> Bool {
        path == "/bin"
            || path.hasPrefix("/bin/")
            || path == "/sbin"
            || path.hasPrefix("/sbin/")
            || path == "/usr/bin"
            || path.hasPrefix("/usr/bin/")
            || path == "/usr/sbin"
            || path.hasPrefix("/usr/sbin/")
            || path == "/usr/libexec"
            || path.hasPrefix("/usr/libexec/")
            || path == "/System"
            || path.hasPrefix("/System/")
            || path == "/Library/Apple"
            || path.hasPrefix("/Library/Apple/")
    }
}

public enum PortCleanerTerminationProtection: Hashable, Sendable {
    case invalidPID
    case identityUnavailable
    case privilegedUser
    case differentUser
    case systemProcess
}

/// v2026.07.16：扫描展示和执行提交共享同一份基于内核身份的保护策略。这里只接收已经
/// 从内核取得的 identity；“身份是否仍是 expected”由 controller 的原子语义操作负责。
private enum PortCleanerProcessPolicy {
    static func executionProtection(
        for identity: PortCleanerProcessIdentity
    ) -> PortCleanerTerminationProtection? {
        guard identity.pid > 1 else { return .invalidPID }
        guard identity.uid != 0 else { return .privilegedUser }
        guard identity.uid == UInt32(getuid()) else { return .differentUser }
        guard !PortCleanerEntry.isProtectedSystemPath(identity.executablePath) else {
            return .systemProcess
        }
        return nil
    }
}

public struct PortCleanerGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String?
    public let user: String?
    public let entries: [PortCleanerEntry]

    public var pids: [Int32] {
        Array(Set(entries.map(\.pid))).sorted()
    }

    public var portCount: Int { entries.count }

    public var terminableEntries: [PortCleanerEntry] {
        entries.filter(\.canRequestTermination)
    }

    public var terminablePids: [Int32] {
        Array(Set(terminableEntries.map(\.pid))).sorted()
    }

    public static func groups(from entries: [PortCleanerEntry]) -> [PortCleanerGroup] {
        let grouped = Dictionary(grouping: entries) { entry in
            "\(entry.processName)|\(entry.processPath ?? "")|\(entry.user ?? "")"
        }
        return grouped.map { key, items in
            let sorted = items.sorted(by: PortCleanerParser.entrySort)
            let first = sorted[0]
            return PortCleanerGroup(
                id: key,
                title: first.processName,
                path: first.processPath,
                user: first.user,
                entries: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.portCount != rhs.portCount { return lhs.portCount > rhs.portCount }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

/// v2026.07.16：把“信号已提交”和“原进程已确认退出”拆成两个事实。
/// `kill(2) == 0` 只表示内核接受了信号，不能向用户声称进程已经退出；只有有界轮询确认
/// 冻结身份消失后才返回 `.terminated`。错误只保存 errno，用户文案在 UI locale 边界投影。
public enum PortCleanerKillDisposition: Hashable, Sendable {
    case terminated
    case terminationRequested
    case alreadyExited
    case invalidPID
    case currentApplicationProtected
    case identityUnavailable
    case identityChanged
    case processBecameProtected
    /// 单轮安全提交上限之外的项没有发送任何信号；调用方必须单独展示，不能静默截断。
    case notSubmittedBatchLimit
    case systemFailure(code: Int32)

    public var succeeded: Bool {
        switch self {
        case .terminated, .alreadyExited: true
        default: false
        }
    }

    public var requestPending: Bool {
        if case .terminationRequested = self { return true }
        return false
    }

    public var notSubmitted: Bool {
        if case .notSubmittedBatchLimit = self { return true }
        return false
    }

    public func message(locale: Locale) -> String {
        switch self {
        case .terminated:
            return AppLocalization.string("port_cleaner.kill.terminated", locale: locale)
        case .terminationRequested:
            return AppLocalization.string("port_cleaner.kill.success", locale: locale)
        case .alreadyExited:
            return AppLocalization.string("port_cleaner.kill.already_exited", locale: locale)
        case .invalidPID:
            return AppLocalization.string("port_cleaner.kill.invalid_pid", locale: locale)
        case .currentApplicationProtected:
            return AppLocalization.string("port_cleaner.kill.refuse_self", locale: locale)
        case .identityUnavailable:
            return AppLocalization.string("port_cleaner.kill.identity_unavailable", locale: locale)
        case .identityChanged:
            return AppLocalization.string("port_cleaner.kill.identity_changed", locale: locale)
        case .processBecameProtected:
            return AppLocalization.string("port_cleaner.kill.became_protected", locale: locale)
        case .notSubmittedBatchLimit:
            return AppLocalization.string("port_cleaner.kill.not_submitted_limit", locale: locale)
        case .systemFailure:
            // v2026.07.16：errno 保留在 typed disposition/结构化诊断，用户文案只呈现
            // 稳定语义；原始错误码不能直接泄漏到本地化界面。
            return AppLocalization.string("port_cleaner.kill.system_failure", locale: locale)
        }
    }
}

public struct PortCleanerKillResult: Hashable, Sendable {
    public let pid: Int32
    public let disposition: PortCleanerKillDisposition

    public var success: Bool { disposition.succeeded }

    public var requestPending: Bool { disposition.requestPending }

    public var notSubmitted: Bool { disposition.notSubmitted }

    public func message(locale: Locale) -> String {
        disposition.message(locale: locale)
    }
}

enum PortCleanerProcessIdentityLookup: Equatable, Sendable {
    case found(PortCleanerProcessIdentity)
    case notRunning
    case unavailable(code: Int32)
}

enum PortCleanerTerminationSubmission: Equatable, Sendable {
    case accepted
    case alreadyExited
    case identityUnavailable
    case identityChanged
    case processBecameProtected
    case failed(code: Int32)
}

protocol PortCleanerProcessControlling: Sendable {
    func identity(for pid: Int32) async -> PortCleanerProcessIdentityLookup
    func submitTermination(
        expectedIdentity: PortCleanerProcessIdentity
    ) async -> PortCleanerTerminationSubmission
}

struct DarwinPortCleanerProcessController: PortCleanerProcessControlling {
    func identity(for pid: Int32) async -> PortCleanerProcessIdentityLookup {
        identitySynchronously(for: pid)
    }

    /// v2026.07.16：本方法内部刻意没有任何 `await`。expected identity 重验、执行层保护
    /// 和 SIGTERM 提交在同一个同步调用栈完成，避免 actor/controller 两次 async 调用之间
    /// 被调度挂起。macOS 没有公开 pidfd，最后一次 proc 查询到 kill(2) 之间仍只有不可再
    /// 缩小的内核 API 极窄窗口。
    func submitTermination(
        expectedIdentity: PortCleanerProcessIdentity
    ) async -> PortCleanerTerminationSubmission {
        switch identitySynchronously(for: expectedIdentity.pid) {
        case .notRunning:
            return .alreadyExited
        case .unavailable:
            return .identityUnavailable
        case .found(let liveIdentity):
            guard liveIdentity == expectedIdentity else { return .identityChanged }
            guard PortCleanerProcessPolicy.executionProtection(for: liveIdentity) == nil else {
                return .processBecameProtected
            }
        }

        errno = 0
        guard Darwin.kill(pid_t(expectedIdentity.pid), SIGTERM) == 0 else {
            return .failed(code: errno)
        }
        return .accepted
    }

    private func identitySynchronously(for pid: Int32) -> PortCleanerProcessIdentityLookup {
        guard pid > 0 else { return .notRunning }

        var info = proc_bsdinfo()
        errno = 0
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard byteCount == Int32(expectedSize) else {
            let code = errno
            return code == ESRCH ? .notRunning : .unavailable(code: code)
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        errno = 0
        let pathLength = proc_pidpath(pid_t(pid), &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else {
            let code = errno
            return code == ESRCH ? .notRunning : .unavailable(code: code)
        }

        let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: pathBytes, as: UTF8.self)
        guard !path.isEmpty else { return .unavailable(code: EINVAL) }
        return .found(PortCleanerProcessIdentity(
            pid: pid,
            uid: info.pbi_uid,
            executablePath: path,
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        ))
    }
}

struct PortCleanerTerminationVerificationPolicy: Sendable {
    let maximumWaitNanoseconds: UInt64
    let pollIntervalNanoseconds: UInt64

    static let production = PortCleanerTerminationVerificationPolicy(
        maximumWaitNanoseconds: 1_500_000_000,
        pollIntervalNanoseconds: 75_000_000
    )
}

protocol PortCleanerCommandRunning: Sendable {
    func run(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> PortCleanerSubprocessOutput
}

struct PortCleanerProductionCommandRunner: PortCleanerCommandRunning {
    func run(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> PortCleanerSubprocessOutput {
        PortCleanerBoundedProcessExecutor.run(path, arguments: arguments, timeout: timeout)
    }
}

public enum PortCleanerScanCommand: Hashable, Sendable {
    case lsof
    case ps
}

/// A port refresh is a snapshot transaction. Failure and cancellation must never be projected
/// to an empty success, because the UI would tell the user that no listeners exist and discard
/// the last trustworthy snapshot.
public enum PortCleanerScanFailure: Hashable, Sendable {
    case launchFailed(command: PortCleanerScanCommand)
    case timedOut(command: PortCleanerScanCommand)
    case outputTruncated(command: PortCleanerScanCommand)
    case commandFailed(command: PortCleanerScanCommand)

    public func message(locale: Locale) -> String {
        let key: String
        switch self {
        case .launchFailed:
            key = "port_cleaner.scan.error.launch_failed"
        case .timedOut:
            key = "port_cleaner.scan.error.timed_out"
        case .outputTruncated:
            key = "port_cleaner.scan.error.output_truncated"
        case .commandFailed:
            key = "port_cleaner.scan.error.command_failed"
        }
        return AppLocalization.string(key, locale: locale)
    }
}

public enum PortCleanerScanOutcome: Sendable {
    case success(entries: [PortCleanerEntry])
    case failure(PortCleanerScanFailure)
    case cancelled
}

public actor PortCleanerScanner {
    private let processController: any PortCleanerProcessControlling
    private let commandRunner: any PortCleanerCommandRunning
    private let verificationPolicy: PortCleanerTerminationVerificationPolicy

    public init() {
        self.processController = DarwinPortCleanerProcessController()
        self.commandRunner = PortCleanerProductionCommandRunner()
        self.verificationPolicy = .production
    }

    init(
        processController: any PortCleanerProcessControlling,
        verificationPolicy: PortCleanerTerminationVerificationPolicy,
        commandRunner: any PortCleanerCommandRunning = PortCleanerProductionCommandRunner()
    ) {
        self.processController = processController
        self.commandRunner = commandRunner
        self.verificationPolicy = verificationPolicy
    }

    public func listPorts() async -> PortCleanerScanOutcome {
        // v2026.07.16：第一次 lsof 只发现候选 PID；随后冻结 identity A，再以第二次 lsof
        // 取得真正展示的端口快照，最后冻结 identity B。仅 A == B 的 PID 可以进入 UI。
        // 这样旧 lsof 输出不会绑定到恰好复用同一 PID 的新进程；新增/变化中的进程等下一轮。
        let discoveryEntries: [PortCleanerEntry]
        switch await lsofEntries() {
        case .success(let entries): discoveryEntries = entries
        case .failure(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        }
        guard !discoveryEntries.isEmpty else { return .success(entries: []) }
        let candidatePIDs = Set(discoveryEntries.map(\.pid))
        guard let identitiesBefore = await identitySnapshot(for: candidatePIDs) else {
            return .cancelled
        }

        let displayEntries: [PortCleanerEntry]
        switch await lsofEntries() {
        case .success(let entries): displayEntries = entries
        case .failure(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        }
        guard !displayEntries.isEmpty else { return .success(entries: []) }
        let displayPIDs = Set(displayEntries.map(\.pid)).intersection(candidatePIDs)
        guard let identitiesAfter = await identitySnapshot(for: displayPIDs) else {
            return .cancelled
        }
        let stableIdentities = identitiesAfter.filter { pid, identity in
            identitiesBefore[pid] == identity
        }
        guard !stableIdentities.isEmpty else { return .success(entries: []) }

        let stableEntries = displayEntries.filter { stableIdentities[$0.pid] != nil }
        let processMetadata: [Int32: ProcessSnapshot]
        switch await processInfo(for: Set(stableEntries.map(\.pid))) {
        case .success(let snapshot): processMetadata = snapshot
        case .failure(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        }
        let entries = stableEntries.map { entry in
            let info = processMetadata[entry.pid]
            let identity = stableIdentities[entry.pid]
            return PortCleanerEntry(
                proto: entry.proto,
                localAddress: entry.localAddress,
                localPort: entry.localPort,
                remoteAddress: entry.remoteAddress,
                remotePort: entry.remotePort,
                state: entry.state,
                pid: entry.pid,
                processName: entry.processName,
                processPath: identity?.executablePath ?? info?.path,
                user: entry.user ?? info?.user,
                processIdentity: identity
            )
        }
        .sorted(by: PortCleanerParser.entrySort)
        return .success(entries: entries)
    }

    private enum SnapshotResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(PortCleanerScanFailure)
        case cancelled
    }

    private func lsofEntries() async -> SnapshotResult<[PortCleanerEntry]> {
        let output = await commandRunner.run(
            "/usr/sbin/lsof",
            arguments: ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpcLnPT"],
            timeout: 8
        )
        if Task.isCancelled { return .cancelled }
        // v2026.07.16: stdout is one indivisible lsof snapshot. Parsing a capped prefix can
        // silently omit listeners or cut an -F record in half, so truncation is a typed scan
        // failure rather than a partial success. stderr is diagnostic-only and does not alter
        // the snapshot contract when lsof itself exits successfully.
        if let failure = output.scanFailure(command: .lsof) { return .failure(failure) }
        return .success(PortCleanerParser.parseLsof(output.stdout).filter { $0.localPort > 0 })
    }

    private func identitySnapshot(
        for pids: Set<Int32>
    ) async -> [Int32: PortCleanerProcessIdentity]? {
        var snapshot: [Int32: PortCleanerProcessIdentity] = [:]
        for pid in pids.sorted() {
            if Task.isCancelled { return nil }
            if case .found(let identity) = await processController.identity(for: pid) {
                snapshot[pid] = identity
            }
        }
        return snapshot
    }

    /// v2026.07.16：执行 API 只接受扫描期冻结的完整身份，刻意不再提供 PID-only 入口。
    /// 这保证所有调用方都无法绕过 PID reuse 重验。
    public func kill(identities: [PortCleanerProcessIdentity]) async -> [PortCleanerKillResult] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let targets = Array(Set(identities)).sorted(by: { $0.pid < $1.pid })
        let submittedTargetCount = min(targets.count, 128)
        var indexedResults: [Int: PortCleanerKillResult] = [:]

        // v2026.07.16：128 是一轮信号提交的安全上限，不得用 prefix 静默丢失其余确认项。
        // 超出部分返回 typed not-submitted，UI 会明确计数，用户重扫后可再发起下一轮。
        if submittedTargetCount < targets.count {
            for index in submittedTargetCount..<targets.count {
                indexedResults[index] = PortCleanerKillResult(
                    pid: targets[index].pid,
                    disposition: .notSubmittedBatchLimit
                )
            }
        }

        // v2026.07.16：每项仍按顺序完成“重验 → 提交信号”，但已提交项的 1.5 秒退出核对
        // 并发进行，整批耗时受单项上限约束，不能退化成 N × 1.5 秒而长时间卡住 UI。
        await withTaskGroup(of: (Int, PortCleanerKillResult).self) { group in
            for (index, frozenIdentity) in targets.prefix(submittedTargetCount).enumerated() {
                let pid = frozenIdentity.pid
                guard pid > 1 else {
                    indexedResults[index] = PortCleanerKillResult(pid: pid, disposition: .invalidPID)
                    continue
                }
                guard pid != currentPID else {
                    indexedResults[index] = PortCleanerKillResult(
                        pid: pid,
                        disposition: .currentApplicationProtected
                    )
                    continue
                }

                // v2026.07.16：expected identity 重验、执行保护和 SIGTERM 已收敛为 controller
                // 内单次 operation；Scanner 不再在两个 await 之间保留可复用 PID。
                switch await processController.submitTermination(expectedIdentity: frozenIdentity) {
                case .alreadyExited:
                    indexedResults[index] = PortCleanerKillResult(pid: pid, disposition: .alreadyExited)
                    continue
                case .identityUnavailable:
                    indexedResults[index] = PortCleanerKillResult(pid: pid, disposition: .identityUnavailable)
                    continue
                case .identityChanged:
                    indexedResults[index] = PortCleanerKillResult(pid: pid, disposition: .identityChanged)
                    continue
                case .processBecameProtected:
                    indexedResults[index] = PortCleanerKillResult(
                        pid: pid,
                        disposition: .processBecameProtected
                    )
                    continue
                case .failed(let code):
                    GSYLog.warning(
                        .operation,
                        "port termination submission rejected pid=\(pid) errno=\(code)"
                    )
                    indexedResults[index] = PortCleanerKillResult(
                        pid: pid,
                        disposition: .systemFailure(code: code)
                    )
                case .accepted:
                    let controller = processController
                    let policy = verificationPolicy
                    group.addTask {
                        let disposition = await Self.verifyTermination(
                            of: frozenIdentity,
                            processController: controller,
                            policy: policy
                        )
                        return (index, PortCleanerKillResult(pid: pid, disposition: disposition))
                    }
                }
            }

            for await (index, result) in group {
                indexedResults[index] = result
            }
        }
        return targets.indices.compactMap { indexedResults[$0] }
    }

    private struct ProcessSnapshot: Sendable {
        let user: String?
        let path: String?
    }

    private func processInfo(
        for pids: Set<Int32>
    ) async -> SnapshotResult<[Int32: ProcessSnapshot]> {
        guard !pids.isEmpty else { return .success([:]) }
        let output = await commandRunner.run(
            "/bin/ps",
            arguments: ["-axo", "pid=,user=,comm="],
            timeout: 5
        )
        if Task.isCancelled { return .cancelled }
        // v2026.07.16: `ps` output is also a whole-table snapshot. Never enrich rows from a
        // truncated prefix; the frozen kernel identity still supplies the executable path,
        // while optional user metadata remains absent until a complete refresh succeeds.
        if let failure = output.scanFailure(command: .ps) { return .failure(failure) }
        var map: [Int32: ProcessSnapshot] = [:]
        for raw in output.stdout.split(whereSeparator: \.isNewline) {
            if Task.isCancelled { return .cancelled }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count >= 2, let pid = Int32(columns[0]), pids.contains(pid) else { continue }
            let user = String(columns[1])
            let path = columns.count >= 3 ? String(columns[2]) : nil
            map[pid] = ProcessSnapshot(user: user, path: path)
        }
        return .success(map)
    }

    private static func verifyTermination(
        of frozenIdentity: PortCleanerProcessIdentity,
        processController: any PortCleanerProcessControlling,
        policy: PortCleanerTerminationVerificationPolicy
    ) async -> PortCleanerKillDisposition {
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start.addingReportingOverflow(policy.maximumWaitNanoseconds)
        let maximum = deadline.overflow ? UInt64.max : deadline.partialValue

        while DispatchTime.now().uptimeNanoseconds < maximum {
            if Task.isCancelled { return .terminationRequested }
            try? await Task.sleep(nanoseconds: policy.pollIntervalNanoseconds)
            switch await processController.identity(for: frozenIdentity.pid) {
            case .notRunning:
                return .terminated
            case .found(let current) where current != frozenIdentity:
                // PID 已被复用同样证明原进程退出；新进程从未收到本轮信号。
                return .terminated
            case .unavailable:
                // 权限/内核瞬态错误不能当成退出证据，继续到有界终点。
                continue
            case .found:
                continue
            }
        }
        return .terminationRequested
    }
}

enum PortCleanerSubprocessStream: Hashable, Sendable {
    case stdout
    case stderr
}

struct PortCleanerSubprocessOutput: Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
    let timedOut: Bool
    let truncatedStreams: Set<PortCleanerSubprocessStream>

    init(
        stdout: String,
        stderr: String,
        status: Int32,
        timedOut: Bool,
        truncatedStreams: Set<PortCleanerSubprocessStream> = []
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.timedOut = timedOut
        self.truncatedStreams = truncatedStreams
    }

    /// lsof/ps are snapshot producers: a successful exit with capped stdout is not a
    /// successful snapshot. Keep this contract next to the subprocess result so future
    /// command consumers cannot accidentally forget the truncation dimension.
    var isCompleteSuccess: Bool {
        scanFailure(command: .lsof) == nil
    }

    func scanFailure(command: PortCleanerScanCommand) -> PortCleanerScanFailure? {
        if timedOut { return .timedOut(command: command) }
        if truncatedStreams.contains(.stdout) {
            return .outputTruncated(command: command)
        }
        if status == -1 { return .launchFailed(command: command) }
        if status != 0 { return .commandFailed(command: command) }
        return nil
    }
}

/// v2026.07.16：`lsof` 和 `ps` 共用的有界执行器。stdout/stderr 从进程启动后立即在
/// 两条独立队列持续读取，避免 pipe 填满死锁。子进程由本线程独占 `waitpid` 所有权：
/// 在 TERM/KILL 之前绝不并发 reap，因此即使子进程刚退出也会保持 zombie、PID 不可复用；
/// 这从状态合同上消除了“wait 线程尚未 signal，裸 PID 已指向新进程”的误杀窗口。
enum PortCleanerBoundedProcessExecutor {
    static func run(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.4,
        killGrace: TimeInterval = 1.0,
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) -> PortCleanerSubprocessOutput {
        guard let child = spawn(path: path, arguments: arguments) else {
            return PortCleanerSubprocessOutput(
                stdout: "",
                stderr: "spawn failed",
                status: -1,
                timedOut: false
            )
        }

        // v2026.07.16：命令输出属于不可信外部数据；即使子进程异常刷屏也只保留每路
        // 16 MiB，reader 仍继续排空 Pipe，兼顾死锁安全和内存上限。
        let stdoutData = PortCleanerLockedData(maximumBytes: maximumOutputBytes)
        let stderrData = PortCleanerLockedData(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()
        let stdoutHandle = FileHandle(fileDescriptor: child.stdoutReadFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: child.stderrReadFD, closeOnDealloc: true)
        startReader(stdoutHandle, output: stdoutData, group: readers)
        startReader(stderrHandle, output: stderrData, group: readers)

        let initialWait = waitForOwnedChild(
            child.pid,
            timeout: max(0.01, timeout)
        )
        let timedOut: Bool
        let normalStatus: Int32?
        var reaped: Bool
        switch initialWait {
        case .reaped(let status):
            timedOut = false
            normalStatus = decodedExitStatus(status)
            reaped = true
        case .notOwned:
            // No signal is safe once child ownership cannot be proven. This should be
            // unreachable because no other waiter exists, but fail closed if libc says ECHILD.
            timedOut = false
            normalStatus = -1
            reaped = true
        case .running:
            timedOut = true
            normalStatus = nil
            // The child has not been reaped, so its PID cannot be allocated to another process.
            // TERM and (if necessary) KILL therefore target only this owned child generation.
            _ = Darwin.kill(child.pid, SIGTERM)
            switch waitForOwnedChild(child.pid, timeout: max(0.01, terminationGrace)) {
            case .reaped:
                reaped = true
            case .notOwned:
                reaped = true
            case .running:
                _ = Darwin.kill(child.pid, SIGKILL)
                switch waitForOwnedChild(child.pid, timeout: max(0.01, killGrace)) {
                case .reaped, .notOwned:
                    reaped = true
                case .running:
                    reaped = false
                    // SIGKILL normally converges immediately. If the kernel still reports the
                    // child running (for example uninterruptible I/O), transfer the one and only
                    // reap obligation to a background waiter. No later signal is permitted.
                    reapOwnedChildEventually(child.pid)
                }
            }
        }

        var readersCompleted = readers.wait(timeout: .now() + 0.5) == .success
        if !readersCompleted {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            readersCompleted = readers.wait(timeout: .now() + 0.2) == .success
        }

        let stdoutSnapshot = stdoutData.snapshot
        let stderrSnapshot = stderrData.snapshot
        var truncatedStreams: Set<PortCleanerSubprocessStream> = []
        if stdoutSnapshot.truncated { truncatedStreams.insert(.stdout) }
        if stderrSnapshot.truncated { truncatedStreams.insert(.stderr) }
        if !readersCompleted {
            // A reader that did not reach EOF cannot prove either retained prefix is a whole
            // stream, even when it happened to stay below the byte cap.
            truncatedStreams.formUnion([.stdout, .stderr])
        }

        return PortCleanerSubprocessOutput(
            stdout: String(data: stdoutSnapshot.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrSnapshot.data, encoding: .utf8) ?? "",
            status: reaped && !timedOut ? (normalStatus ?? -1) : -2,
            timedOut: timedOut,
            truncatedStreams: truncatedStreams
        )
    }

    private struct SpawnedChild {
        let pid: pid_t
        let stdoutReadFD: Int32
        let stderrReadFD: Int32
    }

    private enum OwnedChildWait {
        case reaped(status: Int32)
        case running
        case notOwned
    }

    private static func spawn(path: String, arguments: [String]) -> SpawnedChild? {
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutFDs) == 0 else { return nil }
        guard pipe(&stderrFDs) == 0 else {
            close(stdoutFDs[0])
            close(stdoutFDs[1])
            return nil
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        guard posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutFDs[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrFDs[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutFDs[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrFDs[1]) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return nil
        }

        let values = [path] + arguments
        let duplicated = values.map { strdup($0) }
        guard duplicated.allSatisfy({ $0 != nil }) else {
            duplicated.forEach { free($0) }
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return nil
        }
        defer { duplicated.forEach { free($0) } }
        var argv = duplicated + [nil]
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeMutableBufferPointer { argvBuffer in
            posix_spawn(
                &pid,
                path,
                &actions,
                nil,
                argvBuffer.baseAddress,
                environ
            )
        }
        close(stdoutFDs[1])
        close(stderrFDs[1])
        guard spawnResult == 0 else {
            close(stdoutFDs[0])
            close(stderrFDs[0])
            return nil
        }
        return SpawnedChild(
            pid: pid,
            stdoutReadFD: stdoutFDs[0],
            stderrReadFD: stderrFDs[0]
        )
    }

    /// The caller is the sole waiter. A `.running` result therefore also proves the PID is
    /// still reserved by this child (live or zombie) and cannot have been reused.
    private static func waitForOwnedChild(
        _ pid: pid_t,
        timeout: TimeInterval
    ) -> OwnedChildWait {
        let timeoutNanos = normalizedTimeoutNanoseconds(timeout)
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start.addingReportingOverflow(timeoutNanos)
        let maximum = deadline.overflow ? UInt64.max : deadline.partialValue
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return .reaped(status: status) }
            if result == -1 {
                if errno == EINTR { continue }
                return .notOwned
            }
            if DispatchTime.now().uptimeNanoseconds >= maximum { return .running }
            usleep(2_000)
        }
    }

    /// v2026.07.17：`lsof`/`ps` 的超时是外部命令安全边界，不能让非有限 Double
    /// 在转换纳秒时反过来 trap 宿主 App。语义与 ScanKit subprocess owner 一致。
    static func normalizedTimeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        guard seconds.isFinite else { return UInt64.max }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds)
    }

    private static func reapOwnedChildEventually(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    private static func decodedExitStatus(_ status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return -terminationSignal
    }

    private static func startReader(
        _ handle: FileHandle,
        output: PortCleanerLockedData,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
                        return
                    }
                    output.append(chunk)
                } catch {
                    return
                }
            }
        }
    }
}

/// SAFETY v2026.07.16：这是跨两个 pipe reader 传递字节的最小同步盒；内部 Data 从不
/// 直接逸出，所有 mutation/snapshot 都由 NSLock 保护，因此显式 Sendable 承诺可验证。
private final class PortCleanerLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()
    private var truncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    var snapshot: (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, truncated)
    }

    func append(_ data: Data) {
        lock.lock()
        let remaining = maximumBytes - storage.count
        if remaining > 0 {
            storage.append(data.prefix(remaining))
        }
        if data.count > max(0, remaining) {
            truncated = true
        }
        lock.unlock()
    }
}

enum PortCleanerParser {
    static func parseLsof(_ text: String) -> [PortCleanerEntry] {
        var entries: [PortCleanerEntry] = []
        var pid: Int32 = 0
        var command = ""
        var user: String?
        var fileProto: PortCleanerProtocol?
        var fileState: String?
        var fileAddress: String?

        func flushFile() {
            guard
                pid > 0,
                let proto = fileProto,
                let address = fileAddress,
                let endpoint = parseAddress(address)
            else {
                fileProto = nil
                fileState = nil
                fileAddress = nil
                return
            }
            entries.append(PortCleanerEntry(
                proto: proto,
                localAddress: endpoint.local.host,
                localPort: endpoint.local.port,
                remoteAddress: endpoint.remote?.host,
                remotePort: endpoint.remote?.port,
                state: fileState,
                pid: pid,
                processName: command.isEmpty ? String(format: "PID %d", pid) : command,
                user: user
            ))
            fileProto = nil
            fileState = nil
            fileAddress = nil
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                flushFile()
                pid = Int32(value) ?? 0
                command = ""
                user = nil
            case "f":
                flushFile()
            case "c":
                command = value
            case "L":
                user = value
            case "P":
                if fileProto != nil || fileAddress != nil {
                    flushFile()
                }
                fileProto = PortCleanerProtocol(rawValue: value.uppercased())
            case "T":
                if value.hasPrefix("ST=") {
                    fileState = String(value.dropFirst(3))
                }
            case "n":
                fileAddress = value
            default:
                continue
            }
        }
        flushFile()

        var seen: Set<String> = []
        let unique = entries.filter { entry in
            if seen.contains(entry.id) { return false }
            seen.insert(entry.id)
            return true
        }
        return unique.sorted(by: entrySort)
    }

    static func entrySort(_ lhs: PortCleanerEntry, _ rhs: PortCleanerEntry) -> Bool {
        if lhs.processName != rhs.processName {
            return lhs.processName.localizedStandardCompare(rhs.processName) == .orderedAscending
        }
        if lhs.localPort != rhs.localPort { return lhs.localPort < rhs.localPort }
        if lhs.proto != rhs.proto { return lhs.proto.rawValue < rhs.proto.rawValue }
        return lhs.pid < rhs.pid
    }

    private static func parseAddress(_ value: String) -> (
        local: (host: String, port: Int),
        remote: (host: String, port: Int)?
    )? {
        let parts = value.split(separator: "->", maxSplits: 1, omittingEmptySubsequences: false)
        guard let local = parseHostPort(String(parts[0])) else { return nil }
        let remote = parts.count > 1 ? parseHostPort(String(parts[1])) : nil
        return (local, remote)
    }

    static func parseHostPort(_ raw: String) -> (host: String, port: Int)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let suffix = text[text.index(after: close)...]
            guard suffix.first == ":" else { return nil }
            return parsePort(String(suffix.dropFirst())).map { (host.isEmpty ? "*" : host, $0) }
        }
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon])
        let port = String(text[text.index(after: colon)...])
        return parsePort(port).map { (host.isEmpty ? "*" : host, $0) }
    }

    private static func parsePort(_ text: String) -> Int? {
        if text == "*" { return 0 }
        guard let port = Int(text), port >= 0 else { return nil }
        return port
    }
}
