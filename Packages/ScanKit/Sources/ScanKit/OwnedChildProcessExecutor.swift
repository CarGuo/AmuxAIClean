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
enum OwnedChildProcessExecutor {
    enum WaitState: Equatable {
        case reaped(status: Int32)
        case running
        case notOwned
    }

    enum TerminalState: Equatable {
        case exited(status: Int32)
        case timedOut(sentSIGKILL: Bool, reapTransferred: Bool)
        case notOwned
        case launchFailed(message: String)
    }

    struct ExecutionResult: Equatable {
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

    static func run(
        path: String,
        arguments: [String],
        timeout: TimeInterval?,
        stallAfter: TimeInterval? = nil,
        terminationGrace: TimeInterval = 1,
        killGrace: TimeInterval = 1,
        outputLimitPerStream: Int,
        onSpawn: ((pid_t) -> Void)? = nil,
        onStall: ((pid_t, TimeInterval) -> Void)? = nil
    ) -> ExecutionResult {
        let child: SpawnedChild
        switch spawn(path: path, arguments: arguments, outputLimitPerStream: outputLimitPerStream) {
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
            let initial = waitForOwnedChild(child.pid, timeout: max(0, timeout))
            terminal = resolveTimeout(
                pid: child.pid,
                initial: initial,
                terminationGrace: terminationGrace,
                killGrace: killGrace,
                waiter: waitForOwnedChild,
                signaler: { pid, signal in _ = Darwin.kill(pid, signal) }
            )
            if case .timedOut(_, let reapTransferred) = terminal, reapTransferred {
                reapOwnedChildEventually(child.pid)
            }
        } else if let stallAfter {
            switch waitForOwnedChild(child.pid, timeout: max(0, stallAfter)) {
            case .reaped(let status):
                terminal = .exited(status: status)
            case .notOwned:
                terminal = .notOwned
            case .running:
                onStall?(child.pid, stallAfter)
                terminal = waitForOwnedChildUntilExit(child.pid)
            }
        } else {
            terminal = waitForOwnedChildUntilExit(child.pid)
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
            return .timedOut(sentSIGKILL: false, reapTransferred: false)
        case .running:
            signaler(pid, SIGKILL)
        }

        switch waiter(pid, max(0, killGrace)) {
        case .reaped, .notOwned:
            return .timedOut(sentSIGKILL: true, reapTransferred: false)
        case .running:
            // The synchronous caller stops waiting, so ownership moves exactly once to the
            // background blocking waiter. No code is allowed to signal this PID afterwards.
            return .timedOut(sentSIGKILL: true, reapTransferred: true)
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
            outputLimitPerStream: Int
        ) {
            self.pid = pid
            stdoutHandle = FileHandle(fileDescriptor: stdoutReadFD, closeOnDealloc: true)
            stderrHandle = FileHandle(fileDescriptor: stderrReadFD, closeOnDealloc: true)
            stdoutBuffer = LockedByteBuffer(limit: outputLimitPerStream)
            stderrBuffer = LockedByteBuffer(limit: outputLimitPerStream)
            readers = DispatchGroup()
            Self.startReader(stdoutHandle, output: stdoutBuffer, group: readers)
            Self.startReader(stderrHandle, output: stderrBuffer, group: readers)
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
            group: DispatchGroup
        ) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while true {
                    do {
                        guard let chunk = try handle.read(upToCount: 64 * 1_024),
                              !chunk.isEmpty else { return }
                        output.append(chunk)
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
        outputLimitPerStream: Int
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

        guard posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutFDs[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrFDs[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutFDs[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrFDs[1]) == 0 else {
            stdoutFDs.forEach { close($0) }
            stderrFDs.forEach { close($0) }
            return .failure("launch failed: unable to configure spawn file actions")
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
            return .failure(launchFailureMessage(errorNumber: spawnResult))
        }
        return .success(SpawnedChild(
            pid: pid,
            stdoutReadFD: stdoutFDs[0],
            stderrReadFD: stderrFDs[0],
            outputLimitPerStream: outputLimitPerStream
        ))
    }

    private static func launchFailureMessage(errorNumber: Int32) -> String {
        "launch failed: \(String(cString: strerror(errorNumber)))"
    }

    /// The caller is the sole waiter. `.running` therefore proves this PID generation is still
    /// reserved by the owned child, even if it exits and becomes a zombie immediately afterwards.
    private static func waitForOwnedChild(_ pid: pid_t, timeout: TimeInterval) -> WaitState {
        let seconds = min(max(0, timeout), Double(UInt64.max) / 1_000_000_000)
        let timeoutNanos = UInt64(seconds * 1_000_000_000)
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
            if DispatchTime.now().uptimeNanoseconds >= maximum { return .running }
            usleep(2_000)
        }
    }

    private static func waitForOwnedChildUntilExit(_ pid: pid_t) -> TerminalState {
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
