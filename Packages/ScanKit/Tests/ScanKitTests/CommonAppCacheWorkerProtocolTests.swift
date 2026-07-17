import Darwin
import Foundation
import SafetyKit
import XCTest
@testable import ScanKit

final class CommonAppCacheWorkerProtocolTests: XCTestCase {
    func testOrdinaryLaunchDoesNotEnterPrivateWorkerMode() {
        XCTAssertNil(CommonAppCacheWorkerBridge.runIfRequested(arguments: ["AmuxAIClean"]))
    }

    func testPrivateWorkerMarkerRejectsAnyAdditionalArgumentsBeforeAuthentication() {
        XCTAssertEqual(
            CommonAppCacheWorkerBridge.runIfRequested(
                arguments: [
                    "AmuxAIClean",
                    CommonAppCacheWorkerBridge.workerArgument,
                    "/tmp/caller-controlled-request"
                ]
            ),
            64
        )
    }

    /// SAFETY v2026.07.17: the private marker is not authority by itself. Even a caller that
    /// supplies it inside this test process cannot nominate itself as the worker's parent.
    func testWorkerParentAuthenticationRejectsCurrentProcessAsParent() {
        XCTAssertThrowsError(
            try CommonAppCacheWorkerBridge.authenticateWorkerParent(parentPID: getpid())
        )
    }

    /// Request bytes are accepted only from an already-unlinked, read-only, mode-0600 regular
    /// descriptor. This fixture never touches user data and does not launch the App.
    func testWorkerRequestReaderAcceptsPrivateReadOnlyUnlinkedDescriptor() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkerRequest-\(UUID().uuidString)").path
        let payload = Data("{\"version\":1}".utf8)
        try payload.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, mode_t(0o600)), 0)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        XCTAssertEqual(unlink(path), 0)

        XCTAssertEqual(
            try CommonAppCacheWorkerBridge.readSecureRequest(fromFD: fd),
            payload
        )
    }

    func testWorkerRequestReaderRejectsWritableDescriptor() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkerWritableRequest-\(UUID().uuidString)").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, mode_t(0o600)), 0)
        let fd = open(path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        XCTAssertEqual(unlink(path), 0)

        XCTAssertThrowsError(
            try CommonAppCacheWorkerBridge.readSecureRequest(fromFD: fd)
        )
    }

    func testMissingExecutableFailsClosedWithoutInProcessFallback() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkerMissing-\(UUID().uuidString)", isDirectory: true)
        let progress = WorkerProgressRecorder()
        let result = await CommonAppCacheWorkerBridge.scanIsolated(
            executableURL: nil,
            vendors: [],
            home: home,
            options: .default,
            onProgress: progress.append
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.incompletePaths, [
            CommonAppCacheScanner.IncompletePath(
                path: home.appendingPathComponent("Library", isDirectory: true).path,
                reason: .workerLaunchFailed
            )
        ])
        XCTAssertEqual(progress.snapshot().map(\.phase), [.terminal])
        XCTAssertEqual(progress.snapshot().last?.terminalOutcome, .partial)
        XCTAssertEqual(progress.snapshot().last?.checkpoint?.scanResult.incompletePaths,
                       result.incompletePaths)
    }

    func testForcedStopPreservesCheckpointAndMarksOnlyPendingPaths() throws {
        let completed = URL(fileURLWithPath: "/tmp/AmuxWorker/completed")
        let pending = "/tmp/AmuxWorker/pending"
        let hit = CommonAppCacheScanner.Hit(
            ruleName: "Completed",
            bundleIDPrefix: nil,
            source: "fixture",
            url: completed,
            isDirectory: true,
            verdict: .safe,
            reason: nil,
            sizeBytes: 4096,
            entryCount: 1
        )
        let checkpoint = CommonAppCacheScanner.Checkpoint(
            hits: [hit],
            incompletePaths: [],
            uniqueTotalBytes: 4096,
            uniqueLogicalBytes: 8192,
            uniqueEntryCount: 1,
            completedGroupCount: 1
        )
        let progress = CommonAppCacheScanner.Progress(
            phase: .measuringGroups,
            completedGroups: 1,
            totalGroups: 2,
            currentVerdict: .confirm,
            currentPath: pending,
            checkpoint: checkpoint,
            pendingPaths: [pending]
        )

        let result = CommonAppCacheWorkerBridge.checkpointResult(
            progress: progress,
            rootPath: "/tmp/AmuxWorker/Library",
            pendingReason: .deadlineExceeded
        )

        XCTAssertEqual(result.hits, [hit])
        XCTAssertEqual(result.uniqueTotalBytes, 4096)
        XCTAssertEqual(result.uniqueLogicalBytes, 8192)
        XCTAssertEqual(result.uniqueEntryCount, 1)
        XCTAssertEqual(result.incompletePaths, [
            CommonAppCacheScanner.IncompletePath(
                path: pending,
                reason: .deadlineExceeded
            )
        ])
    }

    func testBlockingWorkerProcessIsHardTimedOutAndReaped() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkerTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fixtureDirectory)) }
        let script = fixtureDirectory.appendingPathComponent("blocking-worker.sh")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        var options = CommonAppCacheScanner.Options.default
        options.timeoutSeconds = 0.05
        let home = fixtureDirectory.appendingPathComponent("home", isDirectory: true)
        let started = Date()
        let progress = WorkerProgressRecorder()

        let result = await CommonAppCacheWorkerBridge.scanIsolated(
            executableURL: script,
            vendors: [],
            home: home,
            options: options,
            onProgress: progress.append
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.incompletePaths, [
            CommonAppCacheScanner.IncompletePath(
                path: home.appendingPathComponent("Library", isDirectory: true).path,
                reason: .deadlineExceeded
            )
        ])
        XCTAssertEqual(progress.snapshot().last?.phase, .terminal)
        XCTAssertEqual(progress.snapshot().last?.terminalOutcome, .partial)
        XCTAssertEqual(progress.snapshot().last?.checkpoint?.scanResult.incompletePaths,
                       result.incompletePaths)
    }

    func testHardTimeoutPolicyIsAlwaysFiniteAndBounded() {
        XCTAssertEqual(CommonAppCacheWorkerBridge.normalizedHardTimeout(.nan), 0)
        XCTAssertEqual(CommonAppCacheWorkerBridge.normalizedHardTimeout(-1), 0)
        XCTAssertEqual(CommonAppCacheWorkerBridge.normalizedHardTimeout(0), 0)
        XCTAssertEqual(CommonAppCacheWorkerBridge.normalizedHardTimeout(12), 12)
        XCTAssertEqual(CommonAppCacheWorkerBridge.normalizedHardTimeout(.infinity), 0)
        XCTAssertEqual(CommonAppCacheWorkerBridge.normalizedHardTimeout(10_000), 300)
    }

    /// v2026.07.17: a last checkpoint with no pending paths must not turn a process failure into a
    /// false complete result. The typed root issue preserves the failed trust boundary.
    func testCheckpointWithoutPendingPathsStillFailsClosed() {
        let progress = CommonAppCacheScanner.Progress(
            phase: .measuringGroups,
            completedGroups: 1,
            totalGroups: 1,
            checkpoint: .init(
                hits: [],
                incompletePaths: [],
                uniqueTotalBytes: 0,
                uniqueLogicalBytes: 0,
                uniqueEntryCount: 0,
                completedGroupCount: 1
            ),
            pendingPaths: []
        )

        let result = CommonAppCacheWorkerBridge.checkpointResult(
            progress: progress,
            rootPath: "/tmp/AmuxWorker/Library",
            pendingReason: .workerProtocolFailed
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.incompletePaths, [.init(
            path: "/tmp/AmuxWorker/Library",
            reason: .workerProtocolFailed
        )])
    }

    func testStrictNDJSONAcceptsExactlyOneFinalFrame() {
        let snapshot = CommonAppCacheWorkerBridge.collectFramesForTesting(
            ndjson(emptyFinalFrame)
        )

        XCTAssertTrue(snapshot.hasSingleValidFinal)
        XCTAssertEqual(snapshot.finalFrameCount, 1)
        XCTAssertNil(snapshot.protocolErrorCode)
    }

    func testStrictNDJSONRejectsDuplicateFinalFrame() {
        let snapshot = CommonAppCacheWorkerBridge.collectFramesForTesting(
            ndjson(emptyFinalFrame, emptyFinalFrame)
        )

        XCTAssertFalse(snapshot.hasSingleValidFinal)
        XCTAssertEqual(snapshot.protocolErrorCode, "frame_after_final")
    }

    func testStrictNDJSONRejectsFailureFollowedByFinal() {
        let failure = #"{"version":1,"kind":"failure","failureCode":"fixture"}"#
        let snapshot = CommonAppCacheWorkerBridge.collectFramesForTesting(
            ndjson(failure, emptyFinalFrame)
        )

        XCTAssertFalse(snapshot.hasSingleValidFinal)
        XCTAssertEqual(snapshot.workerFailureCode, "fixture")
        XCTAssertEqual(snapshot.protocolErrorCode, "frame_after_failure")
    }

    func testStrictNDJSONRejectsBadFrameEvenWhenFollowedByValidFinal() {
        let snapshot = CommonAppCacheWorkerBridge.collectFramesForTesting(
            ndjson("{not-json}", emptyFinalFrame)
        )

        XCTAssertFalse(snapshot.hasSingleValidFinal)
        XCTAssertNil(snapshot.finalResult)
        XCTAssertEqual(snapshot.protocolErrorCode, "decode_failed")
    }

    func testStrictNDJSONRejectsProgressAfterTerminalProgress() {
        let terminal = #"{"version":1,"kind":"progress","progress":{"phase":"terminal","completedGroups":1,"totalGroups":1,"terminalOutcome":"complete","pendingPaths":[]}}"#
        let later = #"{"version":1,"kind":"progress","progress":{"phase":"measuringGroups","completedGroups":1,"totalGroups":1,"pendingPaths":[]}}"#
        let snapshot = CommonAppCacheWorkerBridge.collectFramesForTesting(
            ndjson(terminal, later)
        )

        XCTAssertEqual(snapshot.protocolErrorCode, "progress_after_terminal_progress")
    }

    func testStrictNDJSONRejectsUnterminatedFinalFrame() {
        let snapshot = CommonAppCacheWorkerBridge.collectFramesForTesting(
            Data(emptyFinalFrame.utf8)
        )

        XCTAssertFalse(snapshot.hasSingleValidFinal)
        XCTAssertEqual(snapshot.protocolErrorCode, "unterminated_frame")
    }

    private var emptyFinalFrame: String {
        #"{"version":1,"kind":"final","result":{"hits":[],"incompletePaths":[],"uniqueTotalBytes":0,"uniqueLogicalBytes":0,"uniqueEntryCount":0,"wasCancelled":false}}"#
    }

    private func ndjson(_ frames: String...) -> Data {
        Data((frames.joined(separator: "\n") + "\n").utf8)
    }
}

private final class WorkerProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CommonAppCacheScanner.Progress] = []

    func append(_ value: CommonAppCacheScanner.Progress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [CommonAppCacheScanner.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
