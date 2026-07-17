import Darwin
import Foundation
import LogKit
import SafetyKit
import Security

/// Selects the execution boundary for common-app-cache discovery.
///
/// Package tests and non-App embedders default to `.inProcess`. The shipped App explicitly uses
/// `.isolated`, because only a separately owned process can be terminated while a synchronous
/// filesystem syscall is blocked in the kernel.
public enum CommonAppCacheExecutionMode: Sendable {
    case inProcess
    case isolated(executableURL: URL?)
}

/// Private same-executable worker protocol for Common App Cache scans.
///
/// v2026.07.17 incident boundary: Swift task cancellation and an in-thread deadline cannot
/// pre-empt `open(2)`. The parent therefore re-executes the already-signed App binary without
/// constructing SwiftUI, owns the child through `posix_spawn`/`waitpid`, consumes group-level
/// checkpoints, and can terminate that process at the declared hard limit. This is one worker per
/// scan, never one process per path.
public enum CommonAppCacheWorkerBridge {
    public static let workerArgument = "--amuxaiclean-common-cache-worker-v1"

    private static let protocolVersion = 1
    private static let maximumRequestBytes = 8 * 1_024 * 1_024
    private static let maximumFrameBytes = 8 * 1_024 * 1_024
    private static let outputLimitPerStream = 8 * 1_024 * 1_024
    private static let maximumHardTimeout: TimeInterval = 5 * 60
    private static let cooperativeDeadlineLead: TimeInterval = 0.25

    /// Called by the process entrypoint before SwiftUI constructs `NSApplication`.
    /// Returns nil for an ordinary App launch, or a worker exit code when the private argument is
    /// present. Worker diagnostics use framed stdout; raw request contents and paths are not logged.
    /// The request is accepted only from stdin inherited by an authenticated same-executable
    /// parent; argv never names a caller-controlled request path.
    public static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Int32? {
        guard arguments.contains(workerArgument) else { return nil }

        let writer = WorkerFrameWriter()
        guard arguments.count == 2,
              arguments[1] == workerArgument else {
            writer.write(.failure(code: "invalid_invocation"))
            return 64
        }

        do {
            try authenticateWorkerParent(parentPID: getppid())
        } catch {
            writer.write(.failure(code: "parent_authentication_failed"))
            return 77
        }

        do {
            let requestData = try readSecureRequest(fromFD: STDIN_FILENO)
            let request = try JSONDecoder().decode(WorkerRequest.self, from: requestData)
            guard request.version == protocolVersion else {
                writer.write(.failure(code: "protocol_version"))
                return 65
            }

            let result = CommonAppCacheScanner.detect(
                vendors: request.vendors.map(\.model),
                home: URL(fileURLWithPath: request.homePath, isDirectory: true),
                options: request.options,
                onProgress: { progress in
                    writer.write(.progress(progress))
                }
            )
            writer.write(.final(result))
            return writer.hasFailed ? 74 : 0
        } catch {
            writer.write(.failure(code: "request_invalid"))
            return 65
        }
    }

    /// Runs the private worker and returns either its final result or the last trustworthy
    /// checkpoint. Launch/protocol failures never fall back to the uninterruptible in-process path.
    public static func scanIsolated(
        executableURL: URL?,
        vendors: [VendorRule],
        home: URL,
        options: CommonAppCacheScanner.Options,
        onProgress: @escaping CommonAppCacheScanner.ProgressHandler = { _ in }
    ) async -> CommonAppCacheScanner.ScanResult {
        let rootEvidencePath = home
            .appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL.path
        guard let executableURL else {
            let result = workerFailureResult(
                rootPath: rootEvidencePath,
                reason: .workerLaunchFailed
            )
            return publishingTerminal(result, after: nil, onProgress: onProgress)
        }

        let hardTimeout = normalizedHardTimeout(options.timeoutSeconds)
        var workerOptions = options
        workerOptions.timeoutSeconds = max(0, hardTimeout - cooperativeDeadlineLead)

        let request = WorkerRequest(
            version: protocolVersion,
            vendors: vendors.map(VendorWire.init),
            homePath: home.standardizedFileURL.path,
            options: workerOptions
        )

        let requestFile: SecureRequestFile
        do {
            requestFile = try makeSecureRequestFile(
                data: JSONEncoder().encode(request)
            )
        } catch {
            GSYLog.error(.scan, "CommonAppCache worker request setup failed error=\(String(describing: error))")
            let result = workerFailureResult(
                rootPath: rootEvidencePath,
                reason: .workerLaunchFailed
            )
            return publishingTerminal(result, after: nil, onProgress: onProgress)
        }
        defer { requestFile.cleanup() }

        let collector = WorkerFrameCollector(onProgress: onProgress)
        let cancellation = CancellationFlag()
        if Task.isCancelled { cancellation.cancel() }

        let executablePath = executableURL.standardizedFileURL.path
        let processTask = Task.detached(priority: .utility) {
            OwnedChildProcessExecutor.run(
                path: executablePath,
                arguments: [workerArgument],
                standardInputFD: requestFile.readFD,
                timeout: hardTimeout,
                terminationGrace: 0.25,
                killGrace: 0.25,
                outputLimitPerStream: outputLimitPerStream,
                onStdoutChunk: { chunk in
                    collector.append(chunk)
                },
                isCancelled: {
                    cancellation.isCancelled
                }
            )
        }
        let execution = await withTaskCancellationHandler {
            await processTask.value
        } onCancel: {
            cancellation.cancel()
        }
        collector.finish()
        let frames = collector.snapshot

        switch execution.terminal {
        case .exited(let status):
            let exitCode = OwnedChildProcessExecutor.decodedExitStatus(status)
            if exitCode == 0,
               execution.readersReachedEOF,
               !execution.stdoutWasTruncated,
               frames.hasSingleValidFinal,
               let finalResult = frames.finalResult {
                return publishingTerminal(
                    finalResult,
                    after: frames.latestProgress,
                    onProgress: onProgress
                )
            }
            GSYLog.error(.scan,
                         "CommonAppCache worker exited without valid final frame code=\(exitCode) protocolError=\(frames.protocolErrorCode ?? "none") workerFailure=\(frames.workerFailureCode ?? "none") finalCount=\(frames.finalFrameCount) stdoutTruncated=\(execution.stdoutWasTruncated) readersEOF=\(execution.readersReachedEOF)")
            let result = checkpointResult(
                progress: frames.latestProgress,
                rootPath: rootEvidencePath,
                pendingReason: .workerProtocolFailed
            )
            return publishingTerminal(result, after: frames.latestProgress, onProgress: onProgress)
        case .timedOut:
            GSYLog.warning(.scan,
                           "CommonAppCache isolated worker reached hard timeout limit=\(String(format: "%.3f", hardTimeout))s")
            let result = checkpointResult(
                progress: frames.latestProgress,
                rootPath: rootEvidencePath,
                pendingReason: .deadlineExceeded
            )
            return publishingTerminal(result, after: frames.latestProgress, onProgress: onProgress)
        case .cancelled:
            let result = CommonAppCacheScanner.ScanResult(
                hits: [],
                incompletePaths: [],
                wasCancelled: true
            )
            return publishingTerminal(result, after: frames.latestProgress, onProgress: onProgress)
        case .notOwned:
            GSYLog.error(.scan, "CommonAppCache worker ownership lost before terminal")
            let result = checkpointResult(
                progress: frames.latestProgress,
                rootPath: rootEvidencePath,
                pendingReason: .workerProtocolFailed
            )
            return publishingTerminal(result, after: frames.latestProgress, onProgress: onProgress)
        case .launchFailed(let message):
            GSYLog.error(.scan, "CommonAppCache worker launch failed detail=\(message)")
            let result = workerFailureResult(
                rootPath: rootEvidencePath,
                reason: .workerLaunchFailed
            )
            return publishingTerminal(result, after: frames.latestProgress, onProgress: onProgress)
        }
    }

    // MARK: - Wire model

    private struct WorkerRequest: Codable, Sendable {
        let version: Int
        let vendors: [VendorWire]
        let homePath: String
        let options: CommonAppCacheScanner.Options
    }

    private struct VendorWire: Codable, Sendable {
        let name: String
        let bundleIDPrefix: String?
        let appSupportSubdir: String?
        let cachesPath: String?
        let category: String?
        let source: String?
        let note: String?
        let paths: [PathWire]

        init(_ value: VendorRule) {
            name = value.name
            bundleIDPrefix = value.bundleIDPrefix
            appSupportSubdir = value.appSupportSubdir
            cachesPath = value.cachesPath
            category = value.category
            source = value.source
            note = value.note
            paths = value.paths.map(PathWire.init)
        }

        var model: VendorRule {
            VendorRule(
                name: name,
                bundleIDPrefix: bundleIDPrefix,
                appSupportSubdir: appSupportSubdir,
                cachesPath: cachesPath,
                category: category,
                source: source,
                note: note,
                paths: paths.map(\.model)
            )
        }
    }

    private struct PathWire: Codable, Sendable {
        let path: String
        let verdict: SafetyVerdict
        let reason: String?
        let recipe: String?

        init(_ value: PathRule) {
            path = value.path
            verdict = value.verdict
            reason = value.reason
            recipe = value.recipe
        }

        var model: PathRule {
            PathRule(path: path, verdict: verdict, reason: reason, recipe: recipe)
        }
    }

    private struct WorkerFrame: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case progress
            case final
            case failure
        }

        let version: Int
        let kind: Kind
        let progress: CommonAppCacheScanner.Progress?
        let result: CommonAppCacheScanner.ScanResult?
        let failureCode: String?

        static func progress(_ value: CommonAppCacheScanner.Progress) -> WorkerFrame {
            WorkerFrame(
                version: protocolVersion,
                kind: .progress,
                progress: value,
                result: nil,
                failureCode: nil
            )
        }

        static func final(_ value: CommonAppCacheScanner.ScanResult) -> WorkerFrame {
            WorkerFrame(
                version: protocolVersion,
                kind: .final,
                progress: nil,
                result: value,
                failureCode: nil
            )
        }

        static func failure(code: String) -> WorkerFrame {
            WorkerFrame(
                version: protocolVersion,
                kind: .failure,
                progress: nil,
                result: nil,
                failureCode: code
            )
        }
    }

    // MARK: - Parent frame collection

    struct FrameSnapshot: Sendable {
        let latestProgress: CommonAppCacheScanner.Progress?
        let finalResult: CommonAppCacheScanner.ScanResult?
        let finalFrameCount: Int
        let workerFailureCode: String?
        let protocolErrorCode: String?

        /// v2026.07.17 protocol invariant: an exit status of zero is not proof of success.
        /// The worker must publish exactly one valid final frame and no competing failure/error.
        var hasSingleValidFinal: Bool {
            protocolErrorCode == nil
                && workerFailureCode == nil
                && finalFrameCount == 1
                && finalResult != nil
        }
    }

    /// stdout arrives on a dispatch reader while the async caller owns the process wait. The lock
    /// protects only parser state; user progress callbacks run after unlocking to avoid reentrancy.
    private final class WorkerFrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let onProgress: CommonAppCacheScanner.ProgressHandler
        private var buffer = Data()
        private var latestProgress: CommonAppCacheScanner.Progress?
        private var finalResult: CommonAppCacheScanner.ScanResult?
        private var finalFrameCount = 0
        private var workerFailureCode: String?
        private var protocolErrorCode: String?
        private var sawTerminalProgress = false

        init(onProgress: @escaping CommonAppCacheScanner.ProgressHandler) {
            self.onProgress = onProgress
        }

        func append(_ chunk: Data) {
            var callbackProgress: [CommonAppCacheScanner.Progress] = []
            lock.lock()
            if protocolErrorCode == nil {
                buffer.append(chunk)
                while protocolErrorCode == nil,
                      let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.isEmpty {
                        protocolErrorCode = "empty_frame"
                    } else if line.count > maximumFrameBytes {
                        protocolErrorCode = "frame_too_large"
                    } else if let progress = decodeAndAcceptLocked(line) {
                        callbackProgress.append(progress)
                    }
                }
                if protocolErrorCode == nil, buffer.count > maximumFrameBytes {
                    protocolErrorCode = "frame_too_large"
                }
            }
            lock.unlock()

            callbackProgress.forEach(onProgress)
        }

        func finish() {
            lock.lock()
            // Strict NDJSON requires a newline after every frame. Otherwise a cut pipe and a
            // complete last object are indistinguishable at the trust boundary.
            if protocolErrorCode == nil, !buffer.isEmpty {
                protocolErrorCode = "unterminated_frame"
            }
            buffer.removeAll(keepingCapacity: false)
            lock.unlock()
        }

        var snapshot: FrameSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return FrameSnapshot(
                latestProgress: latestProgress,
                finalResult: finalResult,
                finalFrameCount: finalFrameCount,
                workerFailureCode: workerFailureCode,
                protocolErrorCode: protocolErrorCode
            )
        }

        /// Called with `lock` held. A callback value is returned so user code runs only after the
        /// parser lock is released; parsing and state transition nevertheless stay ordered.
        private func decodeAndAcceptLocked(
            _ data: Data
        ) -> CommonAppCacheScanner.Progress? {
            let frame: WorkerFrame
            do {
                frame = try JSONDecoder().decode(WorkerFrame.self, from: data)
            } catch {
                protocolErrorCode = protocolErrorCode ?? "decode_failed"
                return nil
            }
            guard frame.version == protocolVersion else {
                protocolErrorCode = protocolErrorCode ?? "protocol_version"
                return nil
            }

            if finalFrameCount > 0 {
                protocolErrorCode = protocolErrorCode ?? "frame_after_final"
                return nil
            }
            if workerFailureCode != nil {
                protocolErrorCode = protocolErrorCode ?? "frame_after_failure"
                return nil
            }

            switch frame.kind {
            case .progress:
                guard let progress = frame.progress,
                      frame.result == nil,
                      frame.failureCode == nil else {
                    protocolErrorCode = protocolErrorCode ?? "invalid_progress_payload"
                    return nil
                }
                guard !sawTerminalProgress else {
                    protocolErrorCode = protocolErrorCode ?? "progress_after_terminal_progress"
                    return nil
                }
                guard progress.completedGroups <= progress.totalGroups else {
                    protocolErrorCode = protocolErrorCode ?? "invalid_progress_counts"
                    return nil
                }
                if progress.isTerminal {
                    guard progress.terminalOutcome != nil else {
                        protocolErrorCode = protocolErrorCode ?? "missing_terminal_outcome"
                        return nil
                    }
                    sawTerminalProgress = true
                } else if progress.terminalOutcome != nil {
                    protocolErrorCode = protocolErrorCode ?? "unexpected_terminal_outcome"
                    return nil
                }
                latestProgress = progress
                // The parent publishes one authoritative terminal derived from the returned
                // ScanResult. Suppress the worker terminal to avoid duplicate UI terminal states.
                return progress.isTerminal ? nil : progress
            case .final:
                guard let result = frame.result,
                      frame.progress == nil,
                      frame.failureCode == nil else {
                    protocolErrorCode = protocolErrorCode ?? "invalid_final_payload"
                    return nil
                }
                if let terminal = latestProgress, terminal.isTerminal {
                    let expectedOutcome: CommonAppCacheScanner.Progress.TerminalOutcome
                    if result.wasCancelled {
                        expectedOutcome = .cancelled
                    } else if result.isComplete {
                        expectedOutcome = .complete
                    } else {
                        expectedOutcome = .partial
                    }
                    guard terminal.terminalOutcome == expectedOutcome else {
                        protocolErrorCode = protocolErrorCode ?? "terminal_result_mismatch"
                        return nil
                    }
                }
                finalFrameCount += 1
                finalResult = result
                return nil
            case .failure:
                guard !sawTerminalProgress,
                      frame.progress == nil,
                      frame.result == nil,
                      let failureCode = frame.failureCode,
                      !failureCode.isEmpty else {
                    protocolErrorCode = protocolErrorCode ?? "invalid_failure_payload"
                    return nil
                }
                workerFailureCode = failureCode
                return nil
            }
        }
    }

    private final class WorkerFrameWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false

        var hasFailed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }

        func write(_ frame: WorkerFrame) {
            lock.lock()
            defer { lock.unlock() }
            guard !failed else { return }
            do {
                var data = try JSONEncoder().encode(frame)
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                failed = true
            }
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
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

    // MARK: - Terminal projection

    static func checkpointResult(
        progress: CommonAppCacheScanner.Progress?,
        rootPath: String,
        pendingReason: CommonAppCacheScanner.IncompletePath.Reason
    ) -> CommonAppCacheScanner.ScanResult {
        guard let checkpoint = progress?.checkpoint else {
            return workerFailureResult(rootPath: rootPath, reason: pendingReason)
        }
        let pending = progress?.pendingPaths ?? []
        var issues = deduplicatedIssues(
            checkpoint.incompletePaths + pending.map {
                CommonAppCacheScanner.IncompletePath(path: $0, reason: pendingReason)
            }
        )
        // v2026.07.17 fail-closed projection: a checkpoint at the last group may legitimately have
        // no pending path. Process/protocol failure still means the overall scan is not complete,
        // so retain one typed root issue instead of accidentally returning `isComplete == true`.
        if !issues.contains(where: { $0.reason == pendingReason }) {
            issues.append(CommonAppCacheScanner.IncompletePath(
                path: rootPath,
                reason: pendingReason
            ))
        }
        return CommonAppCacheScanner.ScanResult(
            hits: checkpoint.hits,
            incompletePaths: issues,
            uniqueTotalBytes: checkpoint.uniqueTotalBytes,
            uniqueLogicalBytes: checkpoint.uniqueLogicalBytes,
            uniqueEntryCount: checkpoint.uniqueEntryCount
        )
    }

    /// Publishes the one authoritative terminal after process and protocol validation. Worker
    /// terminal frames are intentionally retained only as validation evidence by the collector;
    /// they are not forwarded directly, because transport failure can change the final outcome.
    @discardableResult
    private static func publishingTerminal(
        _ result: CommonAppCacheScanner.ScanResult,
        after progress: CommonAppCacheScanner.Progress?,
        onProgress: CommonAppCacheScanner.ProgressHandler
    ) -> CommonAppCacheScanner.ScanResult {
        onProgress(terminalProgress(for: result, after: progress))
        return result
    }

    static func terminalProgress(
        for result: CommonAppCacheScanner.ScanResult,
        after progress: CommonAppCacheScanner.Progress?
    ) -> CommonAppCacheScanner.Progress {
        let outcome: CommonAppCacheScanner.Progress.TerminalOutcome
        if result.wasCancelled {
            outcome = .cancelled
        } else if result.isComplete {
            outcome = .complete
        } else {
            outcome = .partial
        }
        let completedGroups = progress?.completedGroups ?? 0
        let totalGroups = max(completedGroups, progress?.totalGroups ?? 0)
        let checkpoint: CommonAppCacheScanner.Checkpoint? = result.wasCancelled ? nil : .init(
            hits: result.hits,
            incompletePaths: result.incompletePaths,
            uniqueTotalBytes: result.uniqueTotalBytes,
            uniqueLogicalBytes: result.uniqueLogicalBytes,
            uniqueEntryCount: result.uniqueEntryCount,
            completedGroupCount: completedGroups
        )
        return CommonAppCacheScanner.Progress(
            phase: .terminal,
            completedGroups: completedGroups,
            totalGroups: totalGroups,
            terminalOutcome: outcome,
            checkpoint: checkpoint,
            pendingPaths: []
        )
    }

    /// Internal protocol seam used by static regression source without launching the App binary.
    static func collectFramesForTesting(_ data: Data) -> FrameSnapshot {
        let collector = WorkerFrameCollector(onProgress: { _ in })
        collector.append(data)
        collector.finish()
        return collector.snapshot
    }

    private static func workerFailureResult(
        rootPath: String,
        reason: CommonAppCacheScanner.IncompletePath.Reason
    ) -> CommonAppCacheScanner.ScanResult {
        CommonAppCacheScanner.ScanResult(
            hits: [],
            incompletePaths: [
                CommonAppCacheScanner.IncompletePath(path: rootPath, reason: reason)
            ]
        )
    }

    private static func deduplicatedIssues(
        _ issues: [CommonAppCacheScanner.IncompletePath]
    ) -> [CommonAppCacheScanner.IncompletePath] {
        var seen = Set<String>()
        return issues.filter {
            seen.insert("\($0.path)|\($0.reason.rawValue)").inserted
        }
    }

    static func normalizedHardTimeout(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds, maximumHardTimeout)
    }

    // MARK: - Authenticated worker boundary

    private enum WorkerAuthenticationError: Error {
        case invalidParent
        case processIdentityUnavailable
        case executableMismatch
        case codeIdentityUnavailable
        case codeValidationFailed
        case parentChanged
    }

    private struct ProcessExecutableIdentity: Equatable {
        let uid: uid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let device: dev_t
        let inode: ino_t
    }

    /// SAFETY v2026.07.17: a private-looking argv flag is not authentication. The worker starts
    /// only when its live parent is the same executable vnode and the Security framework confirms
    /// that parent's dynamic code satisfies this binary's designated requirement. Re-reading the
    /// parent identity after validation closes the ordinary PID-exit/reuse race.
    static func authenticateWorkerParent(parentPID: pid_t) throws {
        let currentPID = getpid()
        guard parentPID > 1,
              parentPID != currentPID,
              parentPID == getppid() else {
            throw WorkerAuthenticationError.invalidParent
        }

        let currentIdentity = try processExecutableIdentity(pid: currentPID)
        let parentIdentityBefore = try processExecutableIdentity(pid: parentPID)
        guard currentIdentity.uid == geteuid(),
              parentIdentityBefore.uid == currentIdentity.uid,
              parentIdentityBefore.device == currentIdentity.device,
              parentIdentityBefore.inode == currentIdentity.inode else {
            throw WorkerAuthenticationError.executableMismatch
        }

        let flags = SecCSFlags(rawValue: 0)
        var currentCode: SecCode?
        guard SecCodeCopySelf(flags, &currentCode) == errSecSuccess,
              let currentCode,
              SecCodeCheckValidity(currentCode, flags, nil) == errSecSuccess else {
            throw WorkerAuthenticationError.codeIdentityUnavailable
        }
        var currentStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, flags, &currentStaticCode) == errSecSuccess,
              let currentStaticCode else {
            throw WorkerAuthenticationError.codeIdentityUnavailable
        }
        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            currentStaticCode,
            flags,
            &designatedRequirement
        ) == errSecSuccess,
              let designatedRequirement else {
            throw WorkerAuthenticationError.codeIdentityUnavailable
        }

        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: parentPID)
        ] as CFDictionary
        var parentCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            flags,
            &parentCode
        ) == errSecSuccess,
              let parentCode,
              SecCodeCheckValidity(
                parentCode,
                flags,
                designatedRequirement
              ) == errSecSuccess else {
            throw WorkerAuthenticationError.codeValidationFailed
        }
        guard try codeIdentityDigest(currentCode) == codeIdentityDigest(parentCode) else {
            throw WorkerAuthenticationError.executableMismatch
        }

        guard parentPID == getppid(),
              try processExecutableIdentity(pid: parentPID) == parentIdentityBefore else {
            throw WorkerAuthenticationError.parentChanged
        }
    }

    /// The designated requirement permits developer-approved updates; the unique signing digest
    /// additionally proves this parent/worker pair is the exact same running executable build.
    private static func codeIdentityDigest(_ code: SecCode) throws -> Data {
        var staticCode: SecStaticCode?
        let defaultFlags = SecCSFlags(rawValue: 0)
        guard SecCodeCopyStaticCode(code, defaultFlags, &staticCode) == errSecSuccess,
              let staticCode else {
            throw WorkerAuthenticationError.codeIdentityUnavailable
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        // v2026.07.17 compile-boundary fix: the Swift Security overlay exposes signing-info
        // lookup on SecStaticCode even though the C documentation describes Code or StaticCode.
        // Convert the already dynamically validated process code explicitly; do not weaken the
        // parent requirement or replace it with bundle-id/string comparison.
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let information,
              let digest = (information as NSDictionary)[kSecCodeInfoUnique] as? Data,
              !digest.isEmpty else {
            throw WorkerAuthenticationError.codeIdentityUnavailable
        }
        return digest
    }

    private static func processExecutableIdentity(
        pid: pid_t
    ) throws -> ProcessExecutableIdentity {
        var processInfo = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let count = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard count == Int32(expectedSize) else {
            throw WorkerAuthenticationError.processIdentityUnavailable
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            throw WorkerAuthenticationError.processIdentityUnavailable
        }
        let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executablePath = String(decoding: pathBytes, as: UTF8.self)
        var metadata = stat()
        // `Darwin.stat` resolves to the imported struct initializer in Swift. `lstat` is the
        // unambiguous no-follow identity primitive and binds the exact proc_pidpath object.
        guard !executablePath.isEmpty,
              lstat(executablePath, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw WorkerAuthenticationError.processIdentityUnavailable
        }
        return ProcessExecutableIdentity(
            uid: processInfo.pbi_uid,
            startSeconds: processInfo.pbi_start_tvsec,
            startMicroseconds: processInfo.pbi_start_tvusec,
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    // MARK: - Secure request descriptor

    private enum RequestFileError: Error {
        case createDirectory
        case createFile
        case writeFile
        case openFile
        case invalidMetadata
        case tooLarge
        case readFile
        case identityChanged
    }

    private final class SecureRequestFile: @unchecked Sendable {
        let directoryPath: String
        let readFD: Int32
        private let lock = NSLock()
        private var cleaned = false

        init(directoryPath: String, readFD: Int32) {
            self.directoryPath = directoryPath
            self.readFD = readFD
        }

        func cleanup() {
            lock.lock()
            guard !cleaned else {
                lock.unlock()
                return
            }
            cleaned = true
            lock.unlock()
            // Explicit best-effort cleanup of a process-private, already-unlinked protocol file.
            // This is not a user deletion path and never participates in the Trash pipeline.
            _ = Darwin.close(readFD)
            _ = Darwin.rmdir(directoryPath)
        }

        deinit { cleanup() }
    }

    private static func makeSecureRequestFile(data: Data) throws -> SecureRequestFile {
        guard data.count <= maximumRequestBytes else { throw RequestFileError.tooLarge }
        let directoryPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AmuxAIClean-CommonCache-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.path
        guard Darwin.mkdir(directoryPath, mode_t(S_IRWXU)) == 0 else {
            throw RequestFileError.createDirectory
        }
        guard Darwin.chmod(directoryPath, mode_t(S_IRWXU)) == 0 else {
            _ = Darwin.rmdir(directoryPath)
            throw RequestFileError.createDirectory
        }

        let path = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("request.json", isDirectory: false).path
        let fd = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fd >= 0 else {
            _ = Darwin.rmdir(directoryPath)
            throw RequestFileError.createFile
        }
        let didWrite = Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0
            && writeAll(data, to: fd)
            && syncFile(fd)
        let closeResult = Darwin.close(fd)
        guard didWrite, closeResult == 0 else {
            _ = Darwin.unlink(path)
            _ = Darwin.rmdir(directoryPath)
            throw RequestFileError.writeFile
        }

        let readFD = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard readFD >= 0 else {
            _ = Darwin.unlink(path)
            _ = Darwin.rmdir(directoryPath)
            throw RequestFileError.openFile
        }
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard fstat(readFD, &descriptorMetadata) == 0,
              lstat(path, &pathMetadata) == 0,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino,
              (descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              descriptorMetadata.st_uid == geteuid(),
              (descriptorMetadata.st_mode & mode_t(0o777)) == mode_t(0o600),
              Darwin.unlink(path) == 0 else {
            _ = Darwin.close(readFD)
            _ = Darwin.unlink(path)
            _ = Darwin.rmdir(directoryPath)
            throw RequestFileError.invalidMetadata
        }
        return SecureRequestFile(directoryPath: directoryPath, readFD: readFD)
    }

    /// Reads only the inherited stdin file description. The descriptor must be read-only, private
    /// to this uid, mode 0600, already unlinked, positioned at byte zero, and stable across read.
    /// Keeping this internal allows fixture tests without exposing a production request-path API.
    static func readSecureRequest(fromFD fd: Int32) throws -> Data {
        let descriptorFlags = fcntl(fd, F_GETFL)
        var before = stat()
        guard descriptorFlags >= 0,
              (descriptorFlags & O_ACCMODE) == O_RDONLY,
              fstat(fd, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == geteuid(),
              (before.st_mode & mode_t(0o777)) == mode_t(0o600),
              before.st_nlink == 0,
              lseek(fd, 0, SEEK_CUR) == 0 else {
            throw RequestFileError.invalidMetadata
        }
        guard before.st_size >= 0,
              before.st_size <= off_t(maximumRequestBytes) else {
            throw RequestFileError.tooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw RequestFileError.readFile
            }
            guard data.count + count <= maximumRequestBytes else {
                throw RequestFileError.tooLarge
            }
            data.append(contentsOf: buffer[..<count])
        }

        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_uid == after.st_uid,
              before.st_mode == after.st_mode,
              before.st_nlink == after.st_nlink,
              before.st_size == after.st_size,
              lseek(fd, 0, SEEK_CUR) == after.st_size,
              data.count == Int(after.st_size) else {
            throw RequestFileError.identityChanged
        }
        return data
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private static func syncFile(_ fd: Int32) -> Bool {
        while Darwin.fsync(fd) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }
}
