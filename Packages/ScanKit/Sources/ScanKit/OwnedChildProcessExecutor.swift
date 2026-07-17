import Foundation
import Darwin

/// A bounded subprocess primitive whose caller is the one and only `waitpid` owner.
///
/// SAFETY v2026.07.16: Foundation `Process` may reap a child before timeout cleanup reads its
/// cached `processIdentifier`. Signalling that bare PID afterwards can target a reused process.
/// This primitive launches with `posix_spawn`, drains stdout/stderr from launch, and never has a
/// competing waiter. A `.running` `waitpid(WNOHANG)` result proves that the PID still belongs to
/// this child generation (a child that exits immediately afterwards remains a zombie until this
/// owner reaps it). `ECHILD` permanently closes the signal path.
///
/// v2026.07.17: stdout can additionally be observed as bounded-reader chunks, and cooperative
/// cancellation is a distinct terminal reason. Neither feature creates another waiter: this
/// primitive still owns every `waitpid`, and every TERM/KILL remains gated by a fresh WNOHANG
/// `.running` observation.
enum OwnedChildProcessExecutor {
    enum WaitState: Equatable, Sendable {
        case reaped(status: Int32)
        case running
        case notOwned
    }

    enum TerminalState: Equatable, Sendable {
        case exited(status: Int32)
        case timedOut(sentSIGKILL: Bool, reapTransferred: Bool)
        case cancelled(sentSIGKILL: Bool, reapTransferred: Bool)
        case notOwned
        case launchFailed(message: String)
    }

    struct ExecutionResult: Equatable, Sendable {
        let terminal: TerminalState
        let stdout: String
        let stderr: String
        let output: String
        let stdoutWasTruncated: Bool
        let stderrWasTruncated: Bool
        let readersReachedEOF: Bool
    }

    typealias Waiter = (_ pid: pid_t, _ timeout: TimeInterval) -> WaitState
    typealias Signaler = (_ pid: pid_t, _ signal: Int32) -> Void
    typealias StdoutChunkHandler = @Sendable (_ chunk: Data) -> Void
    typealias CancellationCheck = @Sendable () -> Bool

    private enum BoundedWaitState: Equatable, Sendable {
        case reaped(status: Int32)
        case deadlineReachedWhileRunning
        case cancellationRequestedWhileRunning
        case notOwned
    }

    static func run(
        path: String,
        arguments: [String],
        standardInputFD: Int32? = nil,
        timeout: TimeInterval?,
        stallAfter: TimeInterval? = nil,
        terminationGrace: TimeInterval = 1,
        killGrace: TimeInterval = 1,
        outputLimitPerStream: Int,
        onSpawn: ((pid_t) -> Void)? = nil,
        onStall: ((pid_t, TimeInterval) -> Void)? = nil,
        onStdoutChunk: StdoutChunkHandler? = nil,
        isCancelled: CancellationCheck? = nil
    ) -> ExecutionResult {
        // v2026.07.17：已取消的调用绝不能先启动子进程再“补做取消”。这对未来可能承载
        // 扫描 worker 的同一 primitive 尤其重要；取消先于 spawn 时没有 PID，也无需 signal。
        if isCancelled?() == true {
            return ExecutionResult(
                terminal: .cancelled(sentSIGKILL: false, reapTransferred: false),
                stdout: "",
                stderr: "",
                output: "",
                stdoutWasTruncated: false,
                stderrWasTruncated: false,
                readersReachedEOF: true
            )
        }

        let child: SpawnedChild
        switch spawn(
            path: path,
            arguments: arguments,
            standardInputFD: standardInputFD,
            outputLimitPerStream: outputLimitPerStream,
            onStdoutChunk: onStdoutChunk
        ) {
        case .success(let spawned):
            child = spawned
        case .failure(let message):
            return ExecutionResult(
                terminal: .launchFailed(message: message),
                stdout: "",
                stderr: message,
                output: message,
                stdoutWasTruncated: false,
                stderrWasTruncated: false,
                readersReachedEOF: true
            )
        }

        onSpawn?(child.pid)

        let terminal: TerminalState
        if let timeout {
            switch waitForOwnedChild(
                child.pid,
                timeout: max(0, timeout),
                isCancelled: isCancelled
            ) {
            case .reaped(let status):
                terminal = .exited(status: status)
            case .notOwned:
                terminal = .notOwned
            case .deadlineReachedWhileRunning:
                terminal = resolveTimeout(
                    pid: child.pid,
                    initial: .running,
                    terminationGrace: terminationGrace,
                    killGrace: killGrace,
                    waiter: waitForOwnedChildWithoutCancellation,
                    signaler: { pid, signal in _ = Darwin.kill(pid, signal) }
                )
            case .cancellationRequestedWhileRunning:
                terminal = resolveCancellation(
                    pid: child.pid,
                    initial: .running,
                    terminationGrace: terminationGrace,
                    killGrace: killGrace,
                    waiter: waitForOwnedChildWithoutCancellation,
                    signaler: { pid, signal in _ = Darwin.kill(pid, signal) }
                )
            }
        } else if let stallAfter {
            switch waitForOwnedChild(
                child.pid,
                timeout: max(0, stallAfter),
                isCancelled: isCancelled
            ) {
            case .reaped(let status):
                terminal = .exited(status: status)
            case .notOwned:
                terminal = .notOwned
            case .deadlineReachedWhileRunning:
                onStall?(child.pid, stallAfter)
                terminal = waitForOwnedChildUntilExit(
                    child.pid,
                    terminationGrace: terminationGrace,
                    killGrace: killGrace,
                    isCancelled: isCancelled
                )
            case .cancellationRequestedWhileRunning:
                terminal = resolveCancellation(
                    pid: child.pid,
                    initial: .running,
                    terminationGrace: terminationGrace,
                    killGrace: killGrace,
                    waiter: waitForOwnedChildWithoutCancellation,
                    signaler: { pid, signal in _ = Darwin.kill(pid, signal) }
                )
            }
        } else {
            terminal = waitForOwnedChildUntilExit(
                child.pid,
                terminationGrace: terminationGrace,
                killGrace: killGrace,
                isCancelled: isCancelled
            )
        }

        switch terminal {
        case .timedOut(_, let reapTransferred), .cancelled(_, let reapTransferred):
            if reapTransferred {
                reapOwnedChildEventually(child.pid)
            }
        case .exited, .notOwned, .launchFailed:
            break
        }

        let captured = child.finishReading()
        var stdout = captured.stdout
        var stderr = captured.stderr
        if captured.stdoutDroppedBytes > 0 {
            stdout += "\n<output truncated; \(captured.stdoutDroppedBytes) stdout bytes discarded>"
        }
        if captured.stderrDroppedBytes > 0 {
            stderr += "\n<output truncated; \(captured.stderrDroppedBytes) stderr bytes discarded>"
        }
        if !captured.reachedEOF {
            stderr += "\n<output incomplete; pipe readers did not reach EOF>"
        }
        return ExecutionResult(
            terminal: terminal,
            stdout: stdout,
            stderr: stderr,
            output: stdout + stderr,
            stdoutWasTruncated: captured.stdoutDroppedBytes > 0,
            stderrWasTruncated: captured.stderrDroppedBytes > 0,
            readersReachedEOF: captured.reachedEOF
        )
    }

    /// Deterministic timeout state machine used by production and tests.
    ///
    /// SAFETY v2026.07.16: only `.running` permits a signal. `.reaped` and `.notOwned`
    /// return immediately; after any later `.notOwned`, escalation is permanently forbidden.
    static func resolveTimeout(
        pid: pid_t,
        initial: WaitState,
        terminationGrace: TimeInterval,
        killGrace: TimeInterval,
        waiter: Waiter,
        signaler: Signaler
    ) -> TerminalState {
        resolveForcedTermination(
            pid: pid,
            initial: initial,
            terminationGrace: terminationGrace,
            killGrace: killGrace,
            reason: .timeout,
            waiter: waiter,
            signaler: signaler
        )
    }

    /// Deterministic cancellation state machine used by production and tests.
    ///
    /// SAFETY v2026.07.17: cancellation is only a request. Production reaches this method only
    /// after a fresh `waitpid(WNOHANG)` returned `.running`; it never signals a cached PID merely
    /// because a Swift task was cancelled. Timeout and cancellation keep separate terminal states
    /// so callers can present and retry them correctly without weakening the sole-waiter contract.
    static func resolveCancellation(
        pid: pid_t,
        initial: WaitState,
        terminationGrace: TimeInterval,
        killGrace: TimeInterval,
        waiter: Waiter,
        signaler: Signaler
    ) -> TerminalState {
        resolveForcedTermination(
            pid: pid,
            initial: initial,
            terminationGrace: terminationGrace,
            killGrace: killGrace,
            reason: .cancellation,
            waiter: waiter,
            signaler: signaler
        )
    }

    private enum ForcedTerminationReason {
        case timeout
        case cancellation

        func terminal(sentSIGKILL: Bool, reapTransferred: Bool) -> TerminalState {
            switch self {
            case .timeout:
                return .timedOut(
                    sentSIGKILL: sentSIGKILL,
                    reapTransferred: reapTransferred
                )
            case .cancellation:
                return .cancelled(
                    sentSIGKILL: sentSIGKILL,
                    reapTransferred: reapTransferred
                )
            }
        }
    }

    /// The only TERM -> KILL escalation path. `initial == .running` must come from an owned
    /// `waitpid(WNOHANG)` observation; every later signal is likewise preceded by another owned
    /// `.running` observation from `waiter`. `ECHILD` permanently closes the signal path.
    private static func resolveForcedTermination(
        pid: pid_t,
        initial: WaitState,
        terminationGrace: TimeInterval,
        killGrace: TimeInterval,
        reason: ForcedTerminationReason,
        waiter: Waiter,
        signaler: Signaler
    ) -> TerminalState {
        switch initial {
        case .reaped(let status):
            return .exited(status: status)
        case .notOwned:
            return .notOwned
        case .running:
            signaler(pid, SIGTERM)
        }

        switch waiter(pid, max(0, terminationGrace)) {
        case .reaped, .notOwned:
            return reason.terminal(sentSIGKILL: false, reapTransferred: false)
        case .running:
            signaler(pid, SIGKILL)
        }

        switch waiter(pid, max(0, killGrace)) {
        case .reaped, .notOwned:
            return reason.terminal(sentSIGKILL: true, reapTransferred: false)
        case .running:
            // The synchronous caller stops waiting, so ownership moves exactly once to the
            // background blocking waiter. No code is allowed to signal this PID afterwards.
            return reason.terminal(sentSIGKILL: true, reapTransferred: true)
        }
    }

    static func decodedExitStatus(_ status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return -terminationSignal
    }

    private struct CapturedOutput {
        let stdout: String
        let stderr: String
        let stdoutDroppedBytes: Int
        let stderrDroppedBytes: Int
        let reachedEOF: Bool
    }

    private final class SpawnedChild {
        let pid: pid_t
        private let stdoutHandle: FileHandle
        private let stderrHandle: FileHandle
        private let stdoutBuffer: LockedByteBuffer
        private let stderrBuffer: LockedByteBuffer
        private let readers: DispatchGroup

        init(
            pid: pid_t,
            stdoutReadFD: Int32,
            stderrReadFD: Int32,
            outputLimitPerStream: Int,
            onStdoutChunk: StdoutChunkHandler?
        ) {
            self.pid = pid
            stdoutHandle = FileHandle(fileDescriptor: stdoutReadFD, closeOnDealloc: true)
            stderrHandle = FileHandle(fileDescriptor: stderrReadFD, closeOnDealloc: true)
            stdoutBuffer = LockedByteBuffer(limit: outputLimitPerStream)
            stderrBuffer = LockedByteBuffer(limit: outputLimitPerStream)
            readers = DispatchGroup()
            Self.startReader(
                stdoutHandle,
                output: stdoutBuffer,
                group: readers,
                onChunk: onStdoutChunk
            )
            Self.startReader(stderrHandle, output: stderrBuffer, group: readers, onChunk: nil)
        }

        func finishReading() -> CapturedOutput {
            var reachedEOF = readers.wait(timeout: .now() + 0.5) == .success
            if !reachedEOF {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                reachedEOF = readers.wait(timeout: .now() + 0.2) == .success
            }
            let stdout = stdoutBuffer.snapshot
            let stderr = stderrBuffer.snapshot
            return CapturedOutput(
                stdout: String(data: stdout.data, encoding: .utf8) ?? "",
                stderr: String(data: stderr.data, encoding: .utf8) ?? "",
                stdoutDroppedBytes: stdout.droppedBytes,
                stderrDroppedBytes: stderr.droppedBytes,
                reachedEOF: reachedEOF
            )
        }

        private static func startReader(
            _ handle: FileHandle,
            output: LockedByteBuffer,
            group: DispatchGroup,
            onChunk: StdoutChunkHandler?
        ) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while true {
                    do {
                        guard let chunk = try handle.read(upToCount: 64 * 1_024),
                              !chunk.isEmpty else { return }
                        output.append(chunk)
                        // v2026.07.17：进度协议必须在 pipe reader 排空 stdout 时即可消费，
                        // 不能等子进程退出后才一次性拿结果。回调显式 @Sendable 且在该
                        // reader queue 串行调用；调用方必须快速返回，不能反向阻塞排空。
                        onChunk?(chunk)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private enum SpawnResult {
        case success(SpawnedChild)
        case failure(String)
    }

    private static func spawn(
        path: String,
        arguments: [String],
        standardInputFD: Int32?,
        outputLimitPerStream: Int,
        onStdoutChunk: StdoutChunkHandler?
    ) -> SpawnResult {
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutFDs) == 0 else {
            return .failure(launchFailureMessage(errorNumber: errno))
        }
        guard pipe(&stderrFDs) == 0 else {
            let failure = launchFailureMessage(errorNumber: errno)
            stdoutFDs.forEach { close($0) }
            return .failure(failure)
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to initialize spawn file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        // SAFETY v2026.07.17: the child receives only descriptors declared below. In
        // particular, a scan worker request is mapped from a caller-owned read-only descriptor
        // to stdin; it is never named in argv and no ambient App descriptor is inherited.
        let inputActionResult: Int32
        if let standardInputFD {
            guard standardInputFD > STDERR_FILENO else {
                stdoutFDs.forEach { close($0) }
                stderrFDs.forEach { close($0) }
                return .failure("launch failed: standard input descriptor must not alias stdio")
            }
            inputActionResult = posix_spawn_file_actions_adddup2(
                &actions,
                standardInputFD,
                STDIN_FILENO
            )
        } else {
            inputActionResult = posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            )
        }

        guard inputActionResult == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutFDs[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrFDs[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutFDs[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrFDs[1]) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to configure spawn file actions")
        }
        if let standardInputFD,
           posix_spawn_file_actions_addclose(&actions, standardInputFD) != 0 {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to isolate standard input descriptor")
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to initialize spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to enable close-on-exec isolation")
        }

        let values = [path] + arguments
        let duplicated = values.map { strdup($0) }
        guard duplicated.allSatisfy({ $0 != nil }) else {
            duplicated.forEach { free($0) }
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to allocate argv")
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
            return .failure(launchFailureMessage(errorNumber: spawnResult))
        }
        return .success(SpawnedChild(
            pid: pid,
            stdoutReadFD: stdoutFDs[0],
            stderrReadFD: stderrFDs[0],
            outputLimitPerStream: outputLimitPerStream,
            onStdoutChunk: onStdoutChunk
        ))
    }

    private static func launchFailureMessage(errorNumber: Int32) -> String {
        "launch failed: \(String(cString: strerror(errorNumber)))"
    }

    /// Polls the sole-owned child until exit, deadline, cancellation request, or ownership loss.
    /// The caller is the sole waiter. A WNOHANG running result therefore proves this PID generation
    /// is still reserved by the owned child, even if it exits immediately after the observation.
    /// A cancellation request is reported only in the same iteration in which WNOHANG proved the
    /// child is still `.running`, so the caller can safely enter the shared TERM -> KILL machine.
    private static func waitForOwnedChild(
        _ pid: pid_t,
        timeout: TimeInterval,
        isCancelled: CancellationCheck?
    ) -> BoundedWaitState {
        let timeoutNanos = normalizedTimeoutNanoseconds(timeout)
        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(timeoutNanos)
        let maximum = deadline.overflow ? UInt64.max : deadline.partialValue
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return .reaped(status: status) }
            if result == -1 {
                if errno == EINTR { continue }
                return .notOwned
            }
            if isCancelled?() == true { return .cancellationRequestedWhileRunning }
            if DispatchTime.now().uptimeNanoseconds >= maximum {
                return .deadlineReachedWhileRunning
            }
            usleep(2_000)
        }
    }

    private static func waitForOwnedChildWithoutCancellation(
        _ pid: pid_t,
        _ timeout: TimeInterval
    ) -> WaitState {
        switch waitForOwnedChild(pid, timeout: timeout, isCancelled: nil) {
        case .reaped(let status):
            return .reaped(status: status)
        case .deadlineReachedWhileRunning:
            return .running
        case .notOwned:
            return .notOwned
        case .cancellationRequestedWhileRunning:
            // A nil cancellation predicate makes this branch unreachable.
            return .running
        }
    }

    /// v2026.07.17：所有 subprocess timeout 最终都经过这里。公开/注入的 Double
    /// 可以是 NaN、infinity 或超大有限值；直接 UInt64 转换会在超时保护代码自身崩溃。
    /// 非正数/NaN 立即到期，正无穷与溢出值饱和，保持 waitpid owner 安全状态机不变。
    static func normalizedTimeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        guard seconds.isFinite else { return UInt64.max }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds)
    }

    private static func waitForOwnedChildUntilExit(
        _ pid: pid_t,
        terminationGrace: TimeInterval,
        killGrace: TimeInterval,
        isCancelled: CancellationCheck?
    ) -> TerminalState {
        guard let isCancelled else {
            return blockingWaitForOwnedChildUntilExit(pid)
        }
        switch waitForOwnedChild(pid, timeout: .infinity, isCancelled: isCancelled) {
        case .reaped(let status):
            return .exited(status: status)
        case .notOwned:
            return .notOwned
        case .cancellationRequestedWhileRunning:
            return resolveCancellation(
                pid: pid,
                initial: .running,
                terminationGrace: terminationGrace,
                killGrace: killGrace,
                waiter: waitForOwnedChildWithoutCancellation,
                signaler: { pid, signal in _ = Darwin.kill(pid, signal) }
            )
        case .deadlineReachedWhileRunning:
            // Positive infinity normalizes to UInt64.max, so this is only a theoretical uptime
            // saturation boundary. Re-observe ownership instead of signalling speculatively.
            return waitForOwnedChildUntilExit(
                pid,
                terminationGrace: terminationGrace,
                killGrace: killGrace,
                isCancelled: isCancelled
            )
        }
    }

    private static func blockingWaitForOwnedChildUntilExit(_ pid: pid_t) -> TerminalState {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return .exited(status: status) }
            if result == -1 {
                if errno == EINTR { continue }
                return .notOwned
            }
        }
    }

    private static func reapOwnedChildEventually(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }
}

/// SAFETY v2026.07.16: pipe readers share this bounded buffer across dispatch queues. Mutable
/// storage never escapes without the lock, making the explicit Sendable promise auditable.
private final class LockedByteBuffer: @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let droppedBytes: Int
    }

    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var droppedBytes = 0

    init(limit: Int) {
        self.limit = max(0, limit)
        storage.reserveCapacity(self.limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        let remaining = max(0, limit - storage.count)
        if remaining > 0 {
            storage.append(chunk.prefix(remaining))
        }
        droppedBytes += max(0, chunk.count - remaining)
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(data: storage, droppedBytes: droppedBytes)
    }
}
