import Darwin
import Foundation
import SafetyKit
import XCTest
@testable import AppUI

/// v2026.10.14: a completed callback whose first Undo write fails must hand recovery
/// ownership back without waiting for the whole App process to exit. Every filesystem
/// object here belongs to a UUID temporary fixture; recycle is a scripted boundary.
@MainActor
final class TrashRecoveryOwnershipRegressionTests: XCTestCase {
    private nonisolated static func waitForMutation(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 2) == .success
    }

    private struct UnusedPipeline: DeletionPipeline {
        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            DeletionPreflight(allowedPaths: paths, rejections: [])
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {}

        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            XCTFail("Finalization/recovery must never submit another recycle request")
            return (0, paths.count, "Unexpected recycle request", [])
        }
    }

    /// The synchronous adapter callback and test assertions use different executors.
    /// NSLock protects the only mutable field; unchecked conformance adds no unsynchronized state.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// The ledger invokes its writer off actor; NSLock protects this one-shot fault switch.
    private final class NextWriteFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingSuccessfulWrites: Int?

        func arm(afterSuccessfulWrites: Int = 0) {
            lock.lock()
            remainingSuccessfulWrites = afterSuccessfulWrites
            lock.unlock()
        }

        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let remainingSuccessfulWrites else { return false }
            if remainingSuccessfulWrites > 0 {
                self.remainingSuccessfulWrites = remainingSuccessfulWrites - 1
                return false
            }
            self.remainingSuccessfulWrites = nil
            return true
        }
    }

    /// The adapter publishes its callback on a worker queue; the test delivers it after timeout.
    /// Callback storage is protected by NSLock and invocation happens after releasing the lock.
    private final class DelayedCallback: @unchecked Sendable {
        typealias Callback = @Sendable ([(String, String)], String?) -> Void
        private let lock = NSLock()
        private var callback: Callback?

        func store(_ callback: @escaping Callback) {
            lock.lock()
            self.callback = callback
            lock.unlock()
        }

        func invoke(pairs: [(String, String)], error: String?) -> Bool {
            lock.lock()
            let callback = callback
            lock.unlock()
            guard let callback else { return false }
            callback(pairs, error)
            return true
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let target: URL
        let nextTarget: URL
        let trashed: URL
        let ledgerURL: URL
        let journalURL: URL
        let undoURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashRecoveryOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("first.txt")
        let nextTarget = root.appendingPathComponent("second.txt")
        try Data("first fixture".utf8).write(to: target)
        try Data("second fixture".utf8).write(to: nextTarget)
        addTeardownBlock {
            // Only remove this test's generated temporary fixture after its tasks have settled.
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                XCTFail("Temporary ownership fixture cleanup failed: \(error)")
            }
        }
        return Fixture(
            root: root,
            target: target,
            nextTarget: nextTarget,
            trashed: root.appendingPathComponent("scripted-trash/first.txt"),
            ledgerURL: root.appendingPathComponent("pending.json"),
            journalURL: root.appendingPathComponent("completion.json"),
            undoURL: root.appendingPathComponent("UndoHistory.json")
        )
    }

    private func completedCallback(
        fixture: Fixture,
        ledger: PersistentTrashPendingOperationLedger,
        journal: PersistentTrashCompletionJournal,
        store: UndoHistoryStore,
        calls: CallCounter
    ) async throws -> (completion: TrashRecycleCompletion, entry: TrashUndoJournalEntry) {
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else {
            throw NSError(domain: "TrashRecoveryOwnership.fixture.reserve", code: 1)
        }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))
        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 2,
            ledger: ledger,
            completionJournal: journal,
            undoHistoryStore: store,
            frozenIdentities: frozen,
            frozenRestoreRoots: [TrashPipeline.normalizePath(fixture.target.path): fixture.root.path],
            submissionQueue: DispatchQueue(label: "TrashRecoveryOwnership.scripted-submit"),
            workspaceRecycle: { _, callback in
                calls.increment()
                do {
                    try FileManager.default.createDirectory(
                        at: fixture.trashed.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                    callback([(fixture.target.path, fixture.trashed.path)], nil)
                } catch {
                    callback([], "Temporary fixture move failed: \(error)")
                }
            },
            lateHandler: { _, _ in XCTFail("The synchronous fixture callback must not arrive late") },
            callbackSettlementRetryDelays: []
        )
        XCTAssertEqual(result.state, .callbackCompleted)
        XCTAssertEqual(result.moved.map(\.0), [fixture.target.path])
        let entry = try XCTUnwrap(result.undoJournalEntries.first)
        XCTAssertEqual(result.undoJournalEntries.count, 1)
        // This is the production outer-pipeline handoff: moved journal rows remain owned
        // until the coordinator durably finalizes them or explicitly returns recovery ownership.
        XCTAssertTrue(ledger.finish(
            operationID: operationID,
            retainingPendingPaths: Set(result.undoJournalEntries.map(\.originalPath))
        ))
        return (
            TrashRecycleCompletion(
                attemptedPaths: [fixture.target.path],
                legacy: (1, 0, nil, result.moved),
                outcome: TrashOutcome(
                    movedPairs: result.moved,
                    failedPaths: [],
                    safetyRejected: [],
                    missingPaths: []
                ),
                undoCommit: TrashUndoCommitCapability(
                    entries: result.undoJournalEntries,
                    journal: journal,
                    ledger: ledger
                ),
                undoJournalFailedPaths: []
            ),
            entry
        )
    }

    func testCompletedCallbackWithTransientUndoFailureRecoversInSameProcessBeforeNextReserve() async throws {
        let fixture = try makeFixture()
        let registry = TrashActiveOperationRegistry()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let store = UndoHistoryStore(storeURL: fixture.undoURL, allowedRestoreRoots: [fixture.root.path])
        let calls = CallCounter()
        let completed = try await completedCallback(
            fixture: fixture, ledger: ledger, journal: journal, store: store, calls: calls
        )

        // Make exactly this Undo write unavailable, then repair the same lock inode.
        // No persisted callback, ledger row or history payload is removed or rewritten.
        let lockURL = fixture.undoURL.appendingPathExtension("lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path)
        let result = await TrashActionCoordinator(
            pipeline: UnusedPipeline(), undoHistoryStore: store
        ).finalizeRecycleCompletion(completed.completion, source: "ownership regression")
        XCTAssertEqual(result.moved, 1, "The system callback already confirmed the move")
        XCTAssertEqual(store.storageState, .writeFailed)
        XCTAssertEqual(journal.pendingEntries(), [completed.entry])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)

        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: ledger,
            completionJournal: journal,
            undoHistoryStore: store
        )
        let nextOperationID = UUID()
        let reservation = await TrashPipeline.reserveAfterRecovery(
            paths: [fixture.nextTarget.path],
            operationID: nextOperationID,
            reviewIdentity: nil,
            recoveryDependencyDomain: domain
        )
        guard case .ledger(.reserved) = reservation else {
            return XCTFail("A completed live-process finalizer must be replayable after transient Undo failure")
        }
        XCTAssertTrue(ledger.finish(operationID: nextOperationID, retainingPendingPaths: []))
        XCTAssertEqual(store.storageState, .ready)
        XCTAssertEqual(store.completionJournalState, .ready)
        XCTAssertEqual(store.history.flatMap(\.filePairs).compactMap(\.journalID), [completed.entry.id])
        XCTAssertEqual(journal.pendingEntries(), [])
        XCTAssertFalse(registry.contains(completed.entry.operationID))
        XCTAssertEqual(registry.unregisterTransitionCountForTesting(completed.entry.operationID), 1)
        XCTAssertEqual(calls.value, 1, "Recovery may persist callback facts but never recycle again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.nextTarget.path))

        let recoveredAgain = await TrashPipeline.recoverDurableTrashState(
            journal: journal, ledger: ledger, undoHistoryStore: store
        )
        XCTAssertEqual(recoveredAgain, .ready)
        let reloaded = UndoHistoryStore(storeURL: fixture.undoURL, allowedRestoreRoots: [fixture.root.path])
        XCTAssertEqual(reloaded.history.flatMap(\.filePairs).compactMap(\.journalID), [completed.entry.id])
        XCTAssertEqual(calls.value, 1)
    }

    func testRecoveryDoesNotStealCompletedCallbackBeforeLiveFinalizerHandoff() async throws {
        let fixture = try makeFixture()
        let owner = TrashLedgerProcessIdentity(pid: 88_914, startTimeSeconds: 914, startTimeMicroseconds: 1)
        let otherOwner = TrashLedgerProcessIdentity(pid: 88_915, startTimeSeconds: 915, startTimeMicroseconds: 1)
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive }
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let store = UndoHistoryStore(storeURL: fixture.undoURL, allowedRestoreRoots: [fixture.root.path])
        let calls = CallCounter()
        let completed = try await completedCallback(
            fixture: fixture, ledger: ledger, journal: journal, store: store, calls: calls
        )
        let otherProcessLedger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { otherOwner },
            processLivenessProbe: { $0 == owner || $0 == otherOwner ? .active : .inactive }
        )
        // callbackObserved alone is insufficient: the legitimate coordinator has not run yet.
        for observer in [ledger, otherProcessLedger] {
            XCTAssertEqual(observer.replayDisposition(
                paths: [fixture.target.path],
                operationID: completed.entry.operationID,
                attemptID: completed.entry.attemptID
            ), .activeOwner)
            let terminal = await TrashPipeline.recoverDurableTrashState(
                journal: journal, ledger: observer, undoHistoryStore: store
            )
            XCTAssertEqual(terminal, .blocked)
            XCTAssertEqual(journal.pendingEntries(), [completed.entry])
            XCTAssertTrue(store.history.isEmpty)
        }
        _ = await TrashActionCoordinator(
            pipeline: UnusedPipeline(), undoHistoryStore: store
        ).finalizeRecycleCompletion(completed.completion, source: "ownership regression")
        let terminal = await TrashPipeline.recoverDurableTrashState(
            journal: journal, ledger: ledger, undoHistoryStore: store
        )
        XCTAssertEqual(terminal, .ready)
        XCTAssertEqual(store.history.flatMap(\.filePairs).compactMap(\.journalID), [completed.entry.id])
        XCTAssertEqual(journal.pendingEntries(), [])
        XCTAssertEqual(calls.value, 1)
    }

    func testFreshReviewCanReplaceInvalidatedUnsubmittedAttemptWithoutRestartingApp() throws {
        let fixture = try makeFixture()
        let registry = TrashActiveOperationRegistry()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry
        )
        let sessionID = UUID()
        let reviewed = DeletionSnapshotIdentity(
            sessionID: sessionID, revision: 1, categoryID: "ownership-regression"
        )
        let operationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path], operationID: operationID, reviewIdentity: reviewed
        ) else { return XCTFail("Initial reviewed object must reserve") }

        // The original object remains in this fixture, making the replacement's distinct
        // identity deterministic. No request reaches the workspace/recycle boundary.
        try FileManager.default.moveItem(
            at: fixture.target, to: fixture.root.appendingPathComponent("original-before-replacement.txt")
        )
        try Data("reviewed replacement".utf8).write(to: fixture.target)
        guard case .rejected(let rejection, _) = ledger.claim(
            paths: [fixture.target.path], operationID: operationID, attemptID: UUID()
        ) else { return XCTFail("Old authorization must not claim a replacement object") }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .freshReviewRequired)
        XCTAssertFalse(registry.contains(operationID), "The invalidated attempt is already terminal")
        XCTAssertTrue(ledger.finish(operationID: operationID, retainingPendingPaths: []))

        guard case .rejected(let staleRejection, _) = ledger.reserve(
            paths: [fixture.target.path], operationID: UUID(), reviewIdentity: reviewed
        ) else { return XCTFail("The original review must remain invalid") }
        XCTAssertEqual(staleRejection.reasonsByPath[fixture.target.path], .freshReviewRequired)

        let freshOperationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: freshOperationID,
            reviewIdentity: DeletionSnapshotIdentity(
                sessionID: sessionID, revision: 2, categoryID: "ownership-regression"
            )
        ) else {
            return XCTFail("A new review must admit the replacement while the same App process is still alive")
        }
        XCTAssertTrue(ledger.finish(operationID: freshOperationID, retainingPendingPaths: []))
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "reviewed replacement")
    }

    func testFailedPreSubmitFinishCanBeRecoveredByFreshReviewInSameProcess() throws {
        for claimBeforeCancellation in [false, true] {
            try assertFailedPreSubmitFinishRecovers(claimBeforeCancellation: claimBeforeCancellation)
        }
    }

    private func assertFailedPreSubmitFinishRecovers(claimBeforeCancellation: Bool) throws {
        let fixture = try makeFixture()
        let registry = TrashActiveOperationRegistry()
        let writeFailure = NextWriteFailure()
        let owner = TrashLedgerProcessIdentity(pid: 88_916, startTimeSeconds: 916, startTimeMicroseconds: 1)
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry,
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive },
            durableWriter: { data, url in
                guard !writeFailure.consume() else { return false }
                return TrashDurableFileWriter.replace(
                    data,
                    at: url,
                    temporaryPrefix: "ownership-pre-submit-test",
                    logContext: "Pre-submit ownership regression"
                )
            }
        )
        let sessionID = UUID()
        let originalReview = DeletionSnapshotIdentity(
            sessionID: sessionID, revision: 1, categoryID: "ownership-regression"
        )
        let operationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path], operationID: operationID, reviewIdentity: originalReview
        ) else { return XCTFail("Pre-submit operation must reserve before cancellation") }
        if claimBeforeCancellation {
            guard case .claimed = ledger.claim(
                paths: [fixture.target.path], operationID: operationID, attemptID: UUID()
            ) else { return XCTFail("Post-claim fixture must reach the durable claim before cancellation") }
        }
        let originalLedger = try Data(contentsOf: fixture.ledgerURL)

        // Exercise both sides of durable claim, but never invoke AppKit. The outer typed
        // outcome's empty retained set proves no unknown submission remains in either case.
        // A single failed clear must not erase that known terminal fact.
        writeFailure.arm()
        XCTAssertFalse(ledger.finish(operationID: operationID, retainingPendingPaths: []))
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), originalLedger)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "first fixture")
        guard case .rejected = ledger.claim(
            paths: [fixture.target.path], operationID: operationID, attemptID: UUID()
        ) else { return XCTFail("An ended queued worker must never regain its claim after failed cleanup") }

        guard case .rejected(let staleRejection, _) = ledger.reserve(
            paths: [fixture.target.path], operationID: UUID(), reviewIdentity: originalReview
        ) else { return XCTFail("A failed clear must not silently revive the cancelled authorization") }
        XCTAssertEqual(
            staleRejection.reasonsByPath[fixture.target.path], .freshReviewRequired,
            "Cancelled attempt must require fresh review, claimBeforeCancellation=\(claimBeforeCancellation)"
        )

        let newOperationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: newOperationID,
            reviewIdentity: DeletionSnapshotIdentity(
                sessionID: sessionID, revision: 2, categoryID: "ownership-regression"
            )
        ) else {
            return XCTFail("Fresh review must recover an ended, unsubmitted owner after failed clear, claimBeforeCancellation=\(claimBeforeCancellation)")
        }
        XCTAssertTrue(ledger.finish(operationID: newOperationID, retainingPendingPaths: []))
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "first fixture")
    }

    func testCompletedAttemptHandoffDoesNotReleaseAnotherLiveAttemptInSameOperation() throws {
        let fixture = try makeFixture()
        let owner = TrashLedgerProcessIdentity(pid: 88_917, startTimeSeconds: 917, startTimeMicroseconds: 1)
        let otherOwner = TrashLedgerProcessIdentity(pid: 88_918, startTimeSeconds: 918, startTimeMicroseconds: 1)
        let registry = TrashActiveOperationRegistry()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry,
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive }
        )
        let operationID = UUID()
        let completedAttemptID = UUID()
        let liveAttemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path, fixture.nextTarget.path], operationID: operationID
        ), case .claimed = ledger.claim(
            paths: [fixture.target.path], operationID: operationID, attemptID: completedAttemptID
        ), case .claimed = ledger.claim(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ) else { return XCTFail("Both attempts must have distinct claims under one parent operation") }
        XCTAssertEqual(ledger.markCallbackObserved(
            paths: [fixture.target.path], operationID: operationID, attemptID: completedAttemptID
        ), .applied)
        XCTAssertTrue(ledger.markAPIReturned(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ))

        ledger.releaseCompletedAttempt(
            paths: [fixture.target.path], operationID: operationID, attemptID: completedAttemptID
        )
        XCTAssertTrue(registry.contains(operationID), "The other attempt still owns a pending callback")
        XCTAssertEqual(ledger.replayDisposition(
            paths: [fixture.target.path], operationID: operationID, attemptID: completedAttemptID
        ), .replayable)
        XCTAssertEqual(ledger.replayDisposition(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ), .activeOwner)

        let observer = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { otherOwner },
            processLivenessProbe: { $0 == owner || $0 == otherOwner ? .active : .inactive }
        )
        XCTAssertEqual(observer.replayDisposition(
            paths: [fixture.target.path], operationID: operationID, attemptID: completedAttemptID
        ), .activeOwner, "A local recovery handoff is not proof that another live process has stopped")
        XCTAssertEqual(observer.replayDisposition(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ), .activeOwner)

        XCTAssertEqual(ledger.acknowledgeExactAttempt(
            paths: [fixture.target.path], operationID: operationID, attemptID: completedAttemptID
        ), .applied)
        XCTAssertTrue(registry.contains(operationID), "Acknowledging one sibling cannot end the parent owner")
        XCTAssertEqual(ledger.replayDisposition(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ), .activeOwner)

        // Settle the second scripted callback before fixture teardown.
        XCTAssertEqual(ledger.markCallbackObserved(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ), .applied)
        XCTAssertTrue(ledger.finish(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: liveAttemptID
        ))
        XCTAssertFalse(registry.contains(operationID))
        XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 1)
    }

    func testLateUnmovedCallbackWithFailedClearReleasesOnlyItsTerminalPaths() async throws {
        let fixture = try makeFixture()
        let registry = TrashActiveOperationRegistry()
        let writeFailure = NextWriteFailure()
        let owner = TrashLedgerProcessIdentity(pid: 88_919, startTimeSeconds: 919, startTimeMicroseconds: 1)
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry,
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive },
            durableWriter: { data, url in
                guard !writeFailure.consume() else { return false }
                return TrashDurableFileWriter.replace(
                    data, at: url, temporaryPrefix: "ownership-late-callback-test",
                    logContext: "Late callback ownership regression"
                )
            }
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let store = UndoHistoryStore(storeURL: fixture.undoURL, allowedRestoreRoots: [fixture.root.path])
        let operationID = UUID()
        let attemptID = UUID()
        let paths = [fixture.target.path, fixture.nextTarget.path]
        guard case .reserved = ledger.reserve(paths: paths, operationID: operationID) else {
            return XCTFail("Mixed late-callback fixture must reserve both paths")
        }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(paths: paths, operationID: operationID))
        let delayed = DelayedCallback()
        let calls = CallCounter()
        let lateCalls = CallCounter()
        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target, fixture.nextTarget],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 1,
            ledger: ledger,
            completionJournal: journal,
            undoHistoryStore: store,
            frozenIdentities: frozen,
            frozenRestoreRoots: Dictionary(uniqueKeysWithValues: paths.map {
                (TrashPipeline.normalizePath($0), fixture.root.path)
            }),
            submissionQueue: DispatchQueue(label: "TrashRecoveryOwnership.delayed-callback"),
            workspaceRecycle: { _, callback in
                calls.increment()
                delayed.store(callback)
            },
            lateHandler: { _, _ in lateCalls.increment() },
            callbackSettlementRetryDelays: []
        )
        XCTAssertEqual(result.state, .callbackPending(operationID: operationID))
        XCTAssertTrue(ledger.finish(operationID: operationID, retainingPendingPaths: Set(paths)))
        try FileManager.default.createDirectory(
            at: fixture.trashed.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)

        // Keep the moved sibling's real finalizer live while testing the failed/unmoved path.
        // This proves a partial handoff cannot release every path sharing the same attempt ID.
        let mutationEntered = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        store.setPersistenceMutationHookForTesting { kind in
            if kind == "journal" {
                mutationEntered.signal()
                releaseMutation.wait()
            }
        }
        defer { releaseMutation.signal() }
        // First write records callbackObserved for both paths; fail the following exact clear
        // of the unmoved path. No callback transition or Undo write is fault-injected here.
        writeFailure.arm(afterSuccessfulWrites: 1)
        let callbackDelivered = await Task.detached {
            delayed.invoke(
                pairs: [(fixture.target.path, fixture.trashed.path)], error: "Scripted second-file failure"
            )
        }.value
        XCTAssertTrue(callbackDelivered)
        let finalizerStarted = await Task.detached {
            Self.waitForMutation(mutationEntered)
        }.value
        XCTAssertTrue(finalizerStarted)
        XCTAssertEqual(lateCalls.value, 1)

        let nextOperationID = UUID()
        let retryReservation = ledger.reserve(paths: [fixture.nextTarget.path], operationID: nextOperationID)
        if case .reserved = retryReservation {
            XCTAssertTrue(ledger.finish(operationID: nextOperationID, retainingPendingPaths: []))
        } else {
            XCTFail("A late authoritative failure must release its path despite one failed durable clear")
        }
        XCTAssertEqual(ledger.replayDisposition(
            paths: [fixture.target.path], operationID: operationID, attemptID: attemptID
        ), .activeOwner, "The moved sibling still belongs to its blocked live Undo finalizer")
        XCTAssertTrue(registry.contains(operationID))

        store.setPersistenceMutationHookForTesting(nil)
        releaseMutation.signal()
        await store.flushPendingWrites()
        // Wait for the existing finalizer's async receipt-prune phase, without invoking recovery
        // or another finalizer on its behalf. This also prevents tasks escaping fixture teardown.
        for _ in 0..<200 {
            if journal.pendingEntries()?.isEmpty == true, !registry.contains(operationID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(journal.pendingEntries(), [])
        XCTAssertFalse(registry.contains(operationID))
        XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 1)
        XCTAssertEqual(store.history.flatMap(\.filePairs).map(\.original), [fixture.target.path])
        XCTAssertEqual(try String(contentsOf: fixture.nextTarget, encoding: .utf8), "second fixture")
        XCTAssertEqual(calls.value, 1, "A late failed callback must not resubmit the original system request")
        // On a failing old implementation, clear its already-known terminal fixture row only
        // after all assertions, so teardown does not retain a process-local test owner.
        XCTAssertTrue(ledger.finish(operationID: operationID, retainingPendingPaths: []))
    }

    func testReleasedOwnerRetiresOnlyAfterLastRecordIsDurablyCleared() throws {
        for viaReserve in [false, true] {
            try assertReleasedOwnerRetirement(viaReserve: viaReserve)
        }
    }

    private func assertReleasedOwnerRetirement(viaReserve: Bool) throws {
        let fixture = try makeFixture()
        let registry = TrashActiveOperationRegistry()
        let writeFailure = NextWriteFailure()
        let owner = TrashLedgerProcessIdentity(pid: 88_920, startTimeSeconds: 920, startTimeMicroseconds: 1)
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry,
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive },
            durableWriter: { data, url in
                guard !writeFailure.consume() else { return false }
                return TrashDurableFileWriter.replace(
                    data, at: url, temporaryPrefix: "ownership-retirement-test",
                    logContext: "Released owner retirement regression"
                )
            }
        )
        let operationID = UUID()
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path, fixture.nextTarget.path], operationID: operationID
        ), case .claimed = ledger.claim(
            paths: [fixture.target.path], operationID: operationID, attemptID: firstAttemptID
        ), case .claimed = ledger.claim(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: secondAttemptID
        ) else { return XCTFail("Retirement fixture must contain both exact attempts") }
        XCTAssertTrue(ledger.markAPIReturned(
            paths: [fixture.nextTarget.path], operationID: operationID, attemptID: secondAttemptID
        ))

        for (index, item) in [(fixture.target, firstAttemptID), (fixture.nextTarget, secondAttemptID)].enumerated() {
            let (target, attemptID) = item
            XCTAssertEqual(ledger.markCallbackObserved(
                paths: [target.path], operationID: operationID, attemptID: attemptID
            ), .applied)
            writeFailure.arm()
            XCTAssertFalse(ledger.finish(paths: [target.path], operationID: operationID, attemptID: attemptID))
            ledger.releaseCompletedAttempt(paths: [target.path], operationID: operationID, attemptID: attemptID)
            let persistedBeforeRecovery = try Data(contentsOf: fixture.ledgerURL)

            // A failed recovery mutation must keep the old owner's bookkeeping and bytes.
            // This covers both direct reserve takeover and the startup reconciliation path.
            writeFailure.arm()
            XCTAssertFalse(clearReleasedPath(target.path, ledger: ledger, viaReserve: viaReserve))
            XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), persistedBeforeRecovery)
            XCTAssertTrue(registry.contains(operationID))
            XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 0)

            XCTAssertTrue(clearReleasedPath(target.path, ledger: ledger, viaReserve: viaReserve))
            if index == 0 {
                XCTAssertTrue(registry.contains(operationID), "The pending sibling still owns the parent operation")
                XCTAssertEqual(ledger.replayDisposition(
                    paths: [fixture.nextTarget.path], operationID: operationID, attemptID: secondAttemptID
                ), .activeOwner)
                XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 0)
            } else {
                XCTAssertFalse(registry.contains(operationID), "The last successful clear must retire the old owner")
                XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 1)
            }
        }
        XCTAssertTrue(ledger.reconcilePersistedRecords().storageAvailable)
        XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 1)
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "first fixture")
        XCTAssertEqual(try String(contentsOf: fixture.nextTarget, encoding: .utf8), "second fixture")
    }

    private func clearReleasedPath(
        _ path: String,
        ledger: PersistentTrashPendingOperationLedger,
        viaReserve: Bool
    ) -> Bool {
        if viaReserve {
            let newOperationID = UUID()
            guard case .reserved = ledger.reserve(paths: [path], operationID: newOperationID) else { return false }
            XCTAssertTrue(ledger.finish(operationID: newOperationID, retainingPendingPaths: []))
            return true
        }
        return ledger.reconcilePersistedRecords().storageAvailable
    }

    func testReleasedOwnerAbsentAfterUnacknowledgedWriteRequiresDurableReconciliation() throws {
        for viaReserve in [false, true] {
            let fixture = try makeFixture()
            let registry = TrashActiveOperationRegistry()
            let writeFailure = NextWriteFailure()
            let owner = TrashLedgerProcessIdentity(pid: 88_921, startTimeSeconds: 921, startTimeMicroseconds: 1)
            let ledger = PersistentTrashPendingOperationLedger(
                fileURL: fixture.ledgerURL,
                activeOperationRegistry: registry,
                processIdentityProvider: { owner },
                processLivenessProbe: { $0 == owner ? .active : .inactive },
                durableWriter: { data, url in
                    // A production parent-directory fsync can fail after rename already changed
                    // the visible JSON. Model that uncertainty without corrupting fixture bytes.
                    let failAcknowledgement = writeFailure.consume()
                    let persisted = TrashDurableFileWriter.replace(
                        data, at: url, temporaryPrefix: "ownership-post-rename-test",
                        logContext: "Post-rename ownership regression"
                    )
                    return persisted && !failAcknowledgement
                }
            )
            let operationID = UUID()
            let attemptID = UUID()
            guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID),
                  case .claimed = ledger.claim(
                    paths: [fixture.target.path], operationID: operationID, attemptID: attemptID
                  ) else { return XCTFail("Post-rename fixture must have an exact claimed attempt") }
            XCTAssertEqual(ledger.markCallbackObserved(
                paths: [fixture.target.path], operationID: operationID, attemptID: attemptID
            ), .applied)
            writeFailure.arm()
            XCTAssertFalse(ledger.finish(paths: [fixture.target.path], operationID: operationID, attemptID: attemptID))
            ledger.releaseCompletedAttempt(paths: [fixture.target.path], operationID: operationID, attemptID: attemptID)
            XCTAssertFalse(ledger.ownsExactAttempt(
                paths: [fixture.target.path], operationID: operationID, attemptID: attemptID
            ), "Visible row removal does not prove the failed durable clear completed")
            XCTAssertTrue(registry.contains(operationID))

            // Reconciliation must establish a successful commit, even when its current JSON
            // snapshot already has no record to remove; another failed commit cannot retire it.
            writeFailure.arm()
            XCTAssertFalse(ledger.reconcilePersistedRecords().storageAvailable)
            XCTAssertTrue(registry.contains(operationID))
            XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 0)
            XCTAssertTrue(clearReleasedPath(fixture.target.path, ledger: ledger, viaReserve: viaReserve))
            XCTAssertFalse(registry.contains(operationID))
            XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 1)
            XCTAssertTrue(ledger.reconcilePersistedRecords().storageAvailable)
            XCTAssertEqual(registry.unregisterTransitionCountForTesting(operationID), 1)
            XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), "first fixture")
        }
    }
}
