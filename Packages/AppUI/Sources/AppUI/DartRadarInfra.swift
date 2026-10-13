import Darwin
import Foundation
import LogKit

// MARK: - 进程身份与保护

/// 冻结在扫描时的进程身份，而不是把可复用的 PID 当成进程身份。
///
/// 进程可能在确认弹窗停留期间退出，随后 macOS 会把同一个 PID 分配给另一个进程。
/// 执行前必须同时重验 PID、真实 UID、可执行文件路径和内核启动时间，任一字段变化都
/// 拒绝发送信号，避免 PID reuse 误伤无关进程。
public struct ProcessIdentity: Hashable, Sendable {
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

public enum ProcessTerminationProtection: Hashable, Sendable {
    case invalidPID
    case privilegedUser
    case differentUser
    case systemProcess
}

/// 扫描展示与执行提交共享同一份基于内核身份的保护策略。
public enum ProcessTerminationPolicy {
    public static func executionProtection(
        for identity: ProcessIdentity
    ) -> ProcessTerminationProtection? {
        guard identity.pid > 1 else { return .invalidPID }
        guard identity.uid != 0 else { return .privilegedUser }
        guard identity.uid == UInt32(getuid()) else { return .differentUser }
        guard !isProtectedSystemPath(identity.executablePath) else { return .systemProcess }
        return nil
    }

    static func isProtectedSystemPath(_ path: String) -> Bool {
        let normalized: String
        if path == "/System/Volumes/Data" {
            normalized = "/"
        } else if path.hasPrefix("/System/Volumes/Data/") {
            normalized = String(path.dropFirst("/System/Volumes/Data".count))
        } else {
            normalized = path
        }
        return normalized == "/bin"
            || normalized.hasPrefix("/bin/")
            || normalized == "/sbin"
            || normalized.hasPrefix("/sbin/")
            || normalized == "/usr/bin"
            || normalized.hasPrefix("/usr/bin/")
            || normalized == "/usr/sbin"
            || normalized.hasPrefix("/usr/sbin/")
            || normalized == "/usr/libexec"
            || normalized.hasPrefix("/usr/libexec/")
            || normalized == "/System"
            || normalized.hasPrefix("/System/")
            || normalized == "/Library/Apple"
            || normalized.hasPrefix("/Library/Apple/")
    }
}

// MARK: - 结束结果

/// 把“信号已提交”和“原进程已确认退出”拆成两个事实。`kill(2) == 0` 只表示内核
/// 接受了信号；只有有界轮询确认冻结身份消失后才返回 `.terminated`。
public enum ProcessKillDisposition: Hashable, Sendable {
    case terminated
    case terminationRequested
    case alreadyExited
    case invalidPID
    case currentApplicationProtected
    case identityUnavailable
    case identityChanged
    case processBecameProtected
    case notSubmittedBatchLimit
    case systemFailure(code: Int32)

    public var succeeded: Bool {
        self == .terminated || self == .alreadyExited
    }

    public var requestPending: Bool { self == .terminationRequested }

    public var notSubmitted: Bool { self == .notSubmittedBatchLimit }
}

public struct ProcessKillResult: Hashable, Sendable {
    public let pid: Int32
    public let disposition: ProcessKillDisposition

    public var success: Bool { disposition.succeeded }
    public var requestPending: Bool { disposition.requestPending }
    public var notSubmitted: Bool { disposition.notSubmitted }
}

public struct ProcessKillResultSummary: Equatable, Sendable {
    public let confirmedStopped: Int
    public let requestPending: Int
    public let notSubmitted: Int
    public let failed: Int

    public static func summarize(_ results: [ProcessKillResult]) -> ProcessKillResultSummary {
        ProcessKillResultSummary(
            confirmedStopped: results.filter(\.success).count,
            requestPending: results.filter(\.requestPending).count,
            notSubmitted: results.filter(\.notSubmitted).count,
            failed: results.filter { result in
                switch result.disposition {
                case .terminated, .alreadyExited, .terminationRequested, .notSubmittedBatchLimit:
                    return false
                default:
                    return true
                }
            }.count
        )
    }

    public func text(locale: Locale) -> String {
        AppLocalization.format(
            "dart_radar.kill.result_with_not_submitted",
            locale: locale,
            arguments: [
                Int64(confirmedStopped),
                Int64(requestPending),
                Int64(notSubmitted),
                Int64(failed)
            ]
        )
    }
}

// MARK: - 内核查找类型

public enum ProcessIdentityLookup: Equatable, Sendable {
    case found(ProcessIdentity)
    case notRunning
    case unavailable(code: Int32)
}

public enum ProcessTerminationSubmission: Equatable, Sendable {
    case accepted
    case alreadyExited
    case identityUnavailable
    case identityChanged
    case processBecameProtected
    case failed(code: Int32)
}

public struct ProcessCPUTimes: Hashable, Sendable {
    public let totalNanoseconds: UInt64
}

public enum ProcessCPUTimesLookup: Equatable, Sendable {
    case found(ProcessCPUTimes)
    case unavailable(code: Int32)
}

public protocol ProcessControlling: Sendable {
    func identity(for pid: Int32) async -> ProcessIdentityLookup
    func submitTermination(
        expectedIdentity: ProcessIdentity
    ) async -> ProcessTerminationSubmission
}

public protocol ProcessCPUSampling: Sendable {
    func cpuTimes(for pid: Int32) async -> ProcessCPUTimesLookup
}

// MARK: - 内核进程控制器

public struct DarwinProcessController: ProcessControlling, ProcessCPUSampling {
    public init() {}

    public func identity(for pid: Int32) async -> ProcessIdentityLookup {
        identitySynchronously(for: pid)
    }

    public func cpuTimes(for pid: Int32) async -> ProcessCPUTimesLookup {
        cpuTimesSynchronously(for: pid)
    }

    /// expected identity 重验、执行层保护和 SIGTERM 提交在同一个同步调用栈完成，避免
    /// 两次 async 调用之间被调度挂起。
    public func submitTermination(
        expectedIdentity: ProcessIdentity
    ) async -> ProcessTerminationSubmission {
        switch identitySynchronously(for: expectedIdentity.pid) {
        case .notRunning:
            return .alreadyExited
        case .unavailable:
            return .identityUnavailable
        case .found(let liveIdentity):
            guard liveIdentity == expectedIdentity else { return .identityChanged }
            guard ProcessTerminationPolicy.executionProtection(for: liveIdentity) == nil else {
                return .processBecameProtected
            }
        }

        errno = 0
        guard Darwin.kill(pid_t(expectedIdentity.pid), SIGTERM) == 0 else {
            return .failed(code: errno)
        }
        return .accepted
    }

    private func identitySynchronously(for pid: Int32) -> ProcessIdentityLookup {
        guard pid > 0 else { return .notRunning }

        var info = proc_bsdinfo()
        errno = 0
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard byteCount == expectedSize else {
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
        return .found(ProcessIdentity(
            pid: pid,
            uid: info.pbi_uid,
            executablePath: path,
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        ))
    }

    private func cpuTimesSynchronously(for pid: Int32) -> ProcessCPUTimesLookup {
        guard pid > 0 else { return .unavailable(code: EINVAL) }
        var info = proc_taskinfo()
        errno = 0
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, pointer, expectedSize)
        }
        guard byteCount == expectedSize else {
            return .unavailable(code: errno)
        }
        return .found(ProcessCPUTimes(
            totalNanoseconds: UInt64(info.pti_total_user) + UInt64(info.pti_total_system)
        ))
    }
}

// MARK: - 退出核对与批量结束

public struct ProcessTerminationVerificationPolicy: Sendable {
    public let maximumWaitNanoseconds: UInt64
    public let pollIntervalNanoseconds: UInt64

    public static let production = ProcessTerminationVerificationPolicy(
        maximumWaitNanoseconds: 1_500_000_000,
        pollIntervalNanoseconds: 75_000_000
    )

    public init(maximumWaitNanoseconds: UInt64, pollIntervalNanoseconds: UInt64) {
        self.maximumWaitNanoseconds = maximumWaitNanoseconds
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }
}

public enum ProcessTerminationExecutor {
    public static func terminate(
        identities: [ProcessIdentity],
        processController: any ProcessControlling,
        verificationPolicy: ProcessTerminationVerificationPolicy
    ) async -> [ProcessKillResult] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let targets = Array(Set(identities)).sorted { $0.pid < $1.pid }
        let submittedTargetCount = min(targets.count, 128)
        var indexedResults: [Int: ProcessKillResult] = [:]

        // 128 是一轮信号提交的安全上限，超出部分返回 typed not-submitted，不静默截断。
        if submittedTargetCount < targets.count {
            for index in submittedTargetCount..<targets.count {
                indexedResults[index] = ProcessKillResult(
                    pid: targets[index].pid,
                    disposition: .notSubmittedBatchLimit
                )
            }
        }

        await withTaskGroup(of: (Int, ProcessKillResult).self) { group in
            for (index, frozenIdentity) in targets.prefix(submittedTargetCount).enumerated() {
                let pid = frozenIdentity.pid
                guard pid > 1 else {
                    indexedResults[index] = ProcessKillResult(pid: pid, disposition: .invalidPID)
                    continue
                }
                guard pid != currentPID else {
                    indexedResults[index] = ProcessKillResult(
                        pid: pid,
                        disposition: .currentApplicationProtected
                    )
                    continue
                }

                switch await processController.submitTermination(expectedIdentity: frozenIdentity) {
                case .alreadyExited:
                    indexedResults[index] = ProcessKillResult(pid: pid, disposition: .alreadyExited)
                case .identityUnavailable:
                    indexedResults[index] = ProcessKillResult(pid: pid, disposition: .identityUnavailable)
                case .identityChanged:
                    indexedResults[index] = ProcessKillResult(pid: pid, disposition: .identityChanged)
                case .processBecameProtected:
                    indexedResults[index] = ProcessKillResult(
                        pid: pid,
                        disposition: .processBecameProtected
                    )
                case .failed(let code):
                    AmuxLog.warning(
                        .operation,
                        "dart radar termination submission rejected pid=\(pid) errno=\(code)"
                    )
                    indexedResults[index] = ProcessKillResult(
                        pid: pid,
                        disposition: .systemFailure(code: code)
                    )
                case .accepted:
                    let controller = processController
                    let policy = verificationPolicy
                    group.addTask {
                        let disposition = await verifyTermination(
                            of: frozenIdentity,
                            processController: controller,
                            policy: policy
                        )
                        return (index, ProcessKillResult(pid: pid, disposition: disposition))
                    }
                }
            }

            for await (index, result) in group {
                indexedResults[index] = result
            }
        }
        return targets.indices.compactMap { indexedResults[$0] }
    }

    private static func verifyTermination(
        of frozenIdentity: ProcessIdentity,
        processController: any ProcessControlling,
        policy: ProcessTerminationVerificationPolicy
    ) async -> ProcessKillDisposition {
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

// MARK: - 快照失败与统一结果

public enum ProcessSnapshotCommand: Hashable, Sendable {
    case ps
}

public enum ProcessSnapshotFailure: Hashable, Sendable {
    case launchFailed(command: ProcessSnapshotCommand)
    case timedOut(command: ProcessSnapshotCommand)
    case outputTruncated(command: ProcessSnapshotCommand)
    case commandFailed(command: ProcessSnapshotCommand)

    public func message(locale: Locale) -> String {
        let key: String
        switch self {
        case .launchFailed: key = "dart_radar.scan.error.launch_failed"
        case .timedOut: key = "dart_radar.scan.error.timed_out"
        case .outputTruncated: key = "dart_radar.scan.error.output_truncated"
        case .commandFailed: key = "dart_radar.scan.error.command_failed"
        }
        return AppLocalization.string(key, locale: locale)
    }
}

public enum SnapshotOutcome<Entry: Sendable, Failure: Sendable>: Sendable {
    case success([Entry])
    case failure(Failure)
    case cancelled
}

// MARK: - 刷新状态机

/// 一次由 revision 拥有的刷新状态机。失败保留上一次成功结果；取消或迟到的旧 revision
/// 永远不会清空/替换它们。只保存类型化失败语义，不保存原始 stderr。
@MainActor
public final class SnapshotRefreshModel<Entry: Sendable, Failure: Sendable>: ObservableObject {
    public typealias Loader = @Sendable () async -> SnapshotOutcome<Entry, Failure>

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var failure: Failure?

    private let loader: Loader
    private var revision: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func reload() {
        revision &+= 1
        let ownedRevision = revision
        loadTask?.cancel()
        failure = nil
        isLoading = true
        let loader = self.loader
        loadTask = Task { [weak self] in
            let outcome = await loader()
            guard let self,
                  !Task.isCancelled,
                  self.revision == ownedRevision else { return }
            switch outcome {
            case .success(let entries):
                self.entries = entries
                self.failure = nil
            case .failure(let failure):
                self.failure = failure
            case .cancelled:
                break
            }
            self.isLoading = false
            self.loadTask = nil
        }
    }

    public func cancel() {
        revision &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    deinit {
        loadTask?.cancel()
    }
}

// MARK: - 有界子进程

public enum ProcessSubprocessStream: Hashable, Sendable {
    case stdout
    case stderr
}

public struct ProcessSubprocessOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
    public let timedOut: Bool
    public let truncatedStreams: Set<ProcessSubprocessStream>

    public init(
        stdout: String,
        stderr: String,
        status: Int32,
        timedOut: Bool,
        truncatedStreams: Set<ProcessSubprocessStream> = []
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.timedOut = timedOut
        self.truncatedStreams = truncatedStreams
    }

    /// ps/top 都是快照生产者：状态为 0、未超时且 stdout 未被截断才算完整成功。
    public var isCompleteSuccess: Bool {
        !timedOut
            && status == 0
            && !truncatedStreams.contains(.stdout)
    }
}

public protocol ProcessCommandRunning: Sendable {
    func run(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> ProcessSubprocessOutput
}

public struct ProcessProductionCommandRunner: ProcessCommandRunning {
    public init() {}

    public func run(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> ProcessSubprocessOutput {
        let cancellationFlag = ProcessCancellationFlag()
        if Task.isCancelled {
            cancellationFlag.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = ProcessBoundedProcessExecutor.run(
                        path,
                        arguments: arguments,
                        timeout: timeout,
                        shouldCancel: { cancellationFlag.isCancelled }
                    )
                    continuation.resume(returning: output)
                }
            }
        } onCancel: {
            cancellationFlag.cancel()
        }
    }
}

/// 跨异步取消回调与 GCD 执行线程的最小布尔盒；内部状态由 NSLock 保护，Sendable 承诺可验证。
private final class ProcessCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// ps / top / lsof 共用的有界执行器。stdout/stderr 从进程启动后立即在两条独立队列
/// 持续读取，避免 pipe 填满死锁。子进程由本线程独占 `waitpid` 所有权：在 TERM/KILL
/// 之前绝不并发 reap，因此即使子进程刚退出也会保持 zombie、PID 不可复用。
enum ProcessBoundedProcessExecutor {
    static func run(
        _ path: String,
        arguments: [String],
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.4,
        killGrace: TimeInterval = 1.0,
        maximumOutputBytes: Int = 16 * 1_024 * 1_024,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> ProcessSubprocessOutput {
        guard !shouldCancel() else {
            return ProcessSubprocessOutput(
                stdout: "",
                stderr: "cancelled",
                status: -2,
                timedOut: true
            )
        }
        guard let child = spawn(path: path, arguments: arguments) else {
            return ProcessSubprocessOutput(
                stdout: "",
                stderr: "spawn failed",
                status: -1,
                timedOut: false
            )
        }

        // 命令输出属于不可信外部数据；即使子进程异常刷屏也只保留每路 16 MiB，reader
        // 仍继续排空 Pipe，兼顾死锁安全和内存上限。
        let stdoutData = ProcessLockedData(maximumBytes: maximumOutputBytes)
        let stderrData = ProcessLockedData(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()
        let stdoutHandle = FileHandle(fileDescriptor: child.stdoutReadFD, closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: child.stderrReadFD, closeOnDealloc: true)
        startReader(stdoutHandle, output: stdoutData, group: readers)
        startReader(stderrHandle, output: stderrData, group: readers)

        let initialWait = waitForOwnedChild(
            child.pid,
            timeout: max(0.01, timeout),
            shouldCancel: shouldCancel
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
            timedOut = false
            normalStatus = -1
            reaped = true
        case .running:
            timedOut = true
            normalStatus = nil
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
        var truncatedStreams: Set<ProcessSubprocessStream> = []
        if stdoutSnapshot.truncated { truncatedStreams.insert(.stdout) }
        if stderrSnapshot.truncated { truncatedStreams.insert(.stderr) }
        if !readersCompleted {
            truncatedStreams.formUnion([.stdout, .stderr])
        }

        return ProcessSubprocessOutput(
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

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }

        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO) == 0,
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
                &attributes,
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

    private static func waitForOwnedChild(
        _ pid: pid_t,
        timeout: TimeInterval,
        shouldCancel: () -> Bool = { false }
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
            if shouldCancel() { return .running }
            if DispatchTime.now().uptimeNanoseconds >= maximum { return .running }
            usleep(2_000)
        }
    }

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
        output: ProcessLockedData,
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

/// 跨两个 pipe reader 传递字节的最小同步盒；内部 Data 从不直接逸出，所有
/// mutation/snapshot 都由 NSLock 保护，Sendable 承诺可验证。
private final class ProcessLockedData: @unchecked Sendable {
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
