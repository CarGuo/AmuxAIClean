import Darwin
import Foundation
import ScanKit
import XCTest
@testable import AppUI

/// v2026.07.16 regression suite for the persistent Trash duplicate-submission boundary.
/// Every filesystem target lives under `NSTemporaryDirectory()` and every AppKit call is a
/// scripted closure; this file never invokes the real `NSWorkspace.recycle`.
final class TrashPendingOperationLedgerTests: XCTestCase {
    private static let primaryProcess = TrashLedgerProcessIdentity(
        pid: 51_001,
        startTimeSeconds: 100,
        startTimeMicroseconds: 1
    )
    private static let restartedProcess = TrashLedgerProcessIdentity(
        pid: 51_002,
        startTimeSeconds: 200,
        startTimeMicroseconds: 2
    )

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        func snapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func test_claimDurabilityFailureRejectsBeforeWorkspaceBoundary() async throws {
        let fixture = try makeFixture()
        let writes = LockedCounter()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: fixture.registry,
            processIdentityProvider: { Self.primaryProcess },
            processLivenessProbe: { $0 == Self.primaryProcess ? .active : .inactive },
            durableWriter: { data, url in
                guard writes.next() == 1 else { return false }
                return TrashDurableFileWriter.replace(
                    data,
                    at: url,
                    temporaryPrefix: "ledger-test",
                    logContext: "Ledger test"
                )
            }
        )
        let operationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else { return XCTFail("Durable reserve fixture must succeed") }
        let workspaceCalls = LockedCounter()

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            timeoutSeconds: 0.2,
            ledger: ledger,
            submissionQueue: DispatchQueue(label: "ledger.claim-durability"),
            workspaceRecycle: { _, _ in workspaceCalls.increment() },
            lateHandler: { _, _ in }
        )

        XCTAssertEqual(workspaceCalls.snapshot(), 0)
        guard case .preSubmitRejected(let rejection) = result.state else {
            return XCTFail("A non-durable claim must remain pre-submit")
        }
        XCTAssertEqual(
            rejection.reasonsByPath[TrashPipeline.normalizePath(fixture.target.path)],
            .ledgerUnavailable
        )
    }

    func test_callbackTransitionWriteFailureIsStorageUnavailableNotStale() throws {
        let fixture = try makeFixture()
        let writes = LockedCounter()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: fixture.registry,
            processIdentityProvider: { Self.primaryProcess },
            processLivenessProbe: { $0 == Self.primaryProcess ? .active : .inactive },
            durableWriter: { data, url in
                guard writes.next() <= 2 else { return false }
                return TrashDurableFileWriter.replace(
                    data,
                    at: url,
                    temporaryPrefix: "ledger-test",
                    logContext: "Ledger test"
                )
            }
        )
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID),
              case .claimed = ledger.claim(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: attemptID
              ) else { return XCTFail("Fixture must cross durable claim") }

        XCTAssertEqual(ledger.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .storageUnavailable)
        XCTAssertTrue(ledger.ownsExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), "A failed callback fsync cannot be interpreted as stale ownership")
    }

    func testReplayDispositionSkipsLiveOwnerAndAllowsExactDeadOwner() throws {
        let fixture = try makeFixture()
        let ownerLedger = makeLedger(fixture)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ownerLedger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = ownerLedger.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) else { return XCTFail("Fixture exact attempt must be durable") }

        XCTAssertEqual(ownerLedger.replayDisposition(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .activeOwner)

        let restarted = makeRestartedLedger(fixture)
        XCTAssertEqual(restarted.replayDisposition(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .replayable)
        XCTAssertEqual(restarted.acknowledgeExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .applied)
        XCTAssertEqual(restarted.replayDisposition(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .stale)
    }

    private struct Fixture {
        let root: URL
        let target: URL
        let ledgerURL: URL
        let registry: TrashActiveOperationRegistry
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashPendingLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.bin")
        try Data("first".utf8).write(to: target)
        addTeardownBlock {
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch {
                XCTFail("Temporary fixture cleanup failed: \(error)")
            }
        }
        return Fixture(
            root: root,
            target: target,
            ledgerURL: root.appendingPathComponent("pending.json"),
            registry: TrashActiveOperationRegistry()
        )
    }

    private func makeLedger(
        _ fixture: Fixture,
        processIdentity: TrashLedgerProcessIdentity = TrashPendingOperationLedgerTests.primaryProcess,
        registry: TrashActiveOperationRegistry? = nil,
        processLivenessProbe: PersistentTrashPendingOperationLedger.ProcessLivenessProbe? = nil,
        storageLimits: PersistentTrashPendingOperationLedger.StorageLimits = .production,
        boundedReader: @escaping PersistentTrashPendingOperationLedger.BoundedReader = {
            url,
            maximumBytes in
            try BoundedLocalFileReader.read(at: url, maximumBytes: maximumBytes)
        }
    ) -> PersistentTrashPendingOperationLedger {
        let liveness = processLivenessProbe ?? { expected in
            expected == processIdentity ? .active : .inactive
        }
        return PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry ?? fixture.registry,
            processIdentityProvider: { processIdentity },
            processLivenessProbe: liveness,
            storageLimits: storageLimits,
            boundedReader: boundedReader
        )
    }

    /// A restarted process has a different process-local registry and treats the persisted
    /// primary PID/start-time identity as inactive. This keeps restart tests deterministic and
    /// prevents the XCTest host's real PID from accidentally standing in for lifecycle evidence.
    private func makeRestartedLedger(_ fixture: Fixture) -> PersistentTrashPendingOperationLedger {
        makeLedger(
            fixture,
            processIdentity: Self.restartedProcess,
            registry: TrashActiveOperationRegistry(),
            processLivenessProbe: { expected in
                expected == Self.restartedProcess ? .active : .inactive
            }
        )
    }

    private func reviewIdentity(
        sessionID: UUID,
        revision: UInt64,
        categoryID: String = "trash-ledger-test"
    ) -> DeletionSnapshotIdentity {
        DeletionSnapshotIdentity(
            sessionID: sessionID,
            revision: revision,
            categoryID: categoryID
        )
    }

    /// v2026.07.18 P1 regression: an oversized authority file is unreadable state, not an empty
    /// first run. The reservation must fail before replacing any bytes on disk.
    func test_oversizedLedgerFailsClosedWithoutReplacingExistingFile() throws {
        let fixture = try makeFixture()
        let existing = Data(repeating: 0x5A, count: 257)
        try existing.write(to: fixture.ledgerURL)
        let ledger = makeLedger(
            fixture,
            storageLimits: .init(maximumBytes: 256, maximumRecordCount: 10)
        )

        guard case .rejected(let rejection, _) = ledger.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else { return XCTFail("Oversized pending authority must fail closed") }
        XCTAssertEqual(
            rejection.reasonsByPath[TrashPipeline.normalizePath(fixture.target.path)],
            .ledgerUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), existing)
    }

    /// The final ledger component is an authority file and must never follow a symlink to an
    /// unrelated target, including on the write path after a failed read.
    func test_symlinkLedgerFailsClosedWithoutTouchingDestination() throws {
        let fixture = try makeFixture()
        let destination = fixture.root.appendingPathComponent("ledger-destination.json")
        let existing = Data("do-not-replace".utf8)
        try existing.write(to: destination)
        try FileManager.default.createSymbolicLink(
            at: fixture.ledgerURL,
            withDestinationURL: destination
        )

        guard case .rejected(let rejection, _) = makeLedger(fixture).reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else { return XCTFail("Symlinked pending authority must fail closed") }
        XCTAssertEqual(
            rejection.reasonsByPath[TrashPipeline.normalizePath(fixture.target.path)],
            .ledgerUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    /// Replacement and deletion after the initial pathname lookup are both integrity failures.
    /// Only initial-path ENOENT may construct an empty envelope.
    func test_readReplacementAndFinalDeletionFailClosedWithoutReplacingLedger() throws {
        let fixture = try makeFixture()
        let firstOperation = UUID()
        guard case .reserved = makeLedger(fixture).reserve(
            paths: [fixture.target.path],
            operationID: firstOperation
        ) else { return XCTFail("Fixture ledger must be created") }
        let existing = try Data(contentsOf: fixture.ledgerURL)
        let secondTarget = fixture.root.appendingPathComponent("second-target.bin")
        try Data("second".utf8).write(to: secondTarget)

        let scriptedErrors: [BoundedLocalFileReadError] = [
            .changed,
            .metadataUnavailable(stage: .finalPath, posixErrorCode: ENOENT),
        ]
        for error in scriptedErrors {
            let ledger = makeLedger(
                fixture,
                boundedReader: { _, _ in throw error }
            )
            guard case .rejected(let rejection, _) = ledger.reserve(
                paths: [secondTarget.path],
                operationID: UUID()
            ) else { return XCTFail("A read identity/version race must fail closed") }
            XCTAssertEqual(
                rejection.reasonsByPath[TrashPipeline.normalizePath(secondTarget.path)],
                .ledgerUnavailable
            )
            XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), existing)
        }
    }

    func test_recordCountWriteLimitRejectsWithoutReplacingExistingLedger() throws {
        let fixture = try makeFixture()
        guard case .reserved = makeLedger(fixture).reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else { return XCTFail("Fixture ledger must be created") }
        let existing = try Data(contentsOf: fixture.ledgerURL)
        let secondTarget = fixture.root.appendingPathComponent("record-limit-target.bin")
        try Data("second".utf8).write(to: secondTarget)
        let ledger = makeLedger(
            fixture,
            storageLimits: .init(
                maximumBytes: PersistentTrashPendingOperationLedger.StorageLimits.production.maximumBytes,
                maximumRecordCount: 1
            )
        )

        guard case .rejected(let rejection, _) = ledger.reserve(
            paths: [secondTarget.path],
            operationID: UUID()
        ) else { return XCTFail("A second record must be rejected before write") }
        XCTAssertEqual(
            rejection.reasonsByPath[TrashPipeline.normalizePath(secondTarget.path)],
            .ledgerUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), existing)
    }

    func test_encodedByteWriteLimitRejectsWithoutReplacingExistingLedger() throws {
        let fixture = try makeFixture()
        guard case .reserved = makeLedger(fixture).reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else { return XCTFail("Fixture ledger must be created") }
        let existing = try Data(contentsOf: fixture.ledgerURL)
        let secondTarget = fixture.root.appendingPathComponent(
            "encoded-byte-limit-target-with-a-longer-path.bin"
        )
        try Data("second".utf8).write(to: secondTarget)
        let ledger = makeLedger(
            fixture,
            storageLimits: .init(maximumBytes: existing.count, maximumRecordCount: 2)
        )

        guard case .rejected(let rejection, _) = ledger.reserve(
            paths: [secondTarget.path],
            operationID: UUID()
        ) else { return XCTFail("An oversized encoded envelope must be rejected before write") }
        XCTAssertEqual(
            rejection.reasonsByPath[TrashPipeline.normalizePath(secondTarget.path)],
            .ledgerUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), existing)
    }

    func test_twoLedgerInstancesAtomicallyReserveOnlyOnce() async throws {
        // Multiple rounds exercise both lock acquisition orders. The expected result remains
        // deterministic: one atomic reservation and one typed active-operation rejection.
        for _ in 0..<24 {
            let fixture = try makeFixture()
            let first = makeLedger(fixture)
            let second = makeLedger(fixture)

            async let a = Task.detached {
                first.reserve(paths: [fixture.target.path], operationID: UUID())
            }.value
            async let b = Task.detached {
                second.reserve(paths: [fixture.target.path], operationID: UUID())
            }.value
            let results = await [a, b]

            XCTAssertEqual(results.filter { result in
                if case .reserved = result { return true }
                return false
            }.count, 1)
            XCTAssertEqual(results.filter { result in
                guard case .rejected(let rejection, _) = result else { return false }
                return rejection.reasonsByPath[fixture.target.path] == .priorOperationPending
            }.count, 1)
        }
    }

    func test_concurrentStartupReconciliationCannotInvalidateFreshReservation() async throws {
        // v2026.07.16 regression: reconciliation used to snapshot the in-process registry
        // before taking flock. A fresh reservation could then win flock and be persisted after
        // that snapshot, only to be misclassified as restart residue by the waiting reconciler.
        // Whichever operation wins now, the final active reservation must remain pending.
        for _ in 0..<48 {
            let fixture = try makeFixture()
            let reconciler = makeLedger(fixture)
            let submitter = makeLedger(fixture)
            let observer = makeLedger(fixture)
            let operationID = UUID()

            async let reconciliation = Task.detached {
                reconciler.reconcilePersistedRecords()
            }.value
            async let reservation = Task.detached {
                submitter.reserve(paths: [fixture.target.path], operationID: operationID)
            }.value

            _ = await reconciliation
            guard case .reserved = await reservation else {
                return XCTFail("The fresh operation must reserve exactly once")
            }
            guard case .rejected(let rejection, let invalidated) = observer.reserve(
                paths: [fixture.target.path],
                operationID: UUID()
            ) else {
                return XCTFail("Startup reconciliation must not clear an active reservation")
            }
            XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
            XCTAssertTrue(invalidated.isEmpty)
            XCTAssertTrue(submitter.finish(operationID: operationID, retainingPendingPaths: []))
        }
    }

    func test_sameIdentityStaysPendingAcrossLedgerInstances() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let restarted = makeLedger(fixture)
        let operationID = UUID()

        guard case .reserved = original.reserve(paths: [fixture.target.path], operationID: operationID) else {
            return XCTFail("Initial operation must reserve")
        }
        let second = restarted.reserve(paths: [fixture.target.path], operationID: UUID())

        guard case .rejected(let rejection, _) = second else {
            return XCTFail("Same inode must remain pending after a new ledger instance")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
    }

    func test_restartReplacementPersistsFreshReviewAndStaleAuthorizationNeverReserves() throws {
        let fixture = try makeFixture()
        let first = makeLedger(fixture)
        let second = makeRestartedLedger(fixture)
        let operationID = UUID()
        let reviewSessionID = UUID()
        let staleReview = reviewIdentity(sessionID: reviewSessionID, revision: 7)
        guard case .reserved = first.reserve(
            paths: [fixture.target.path],
            operationID: operationID,
            reviewIdentity: staleReview
        ) else {
            return XCTFail("Initial operation must reserve")
        }
        XCTAssertTrue(fixture.registry.unregister(operationID), "Simulate process restart")

        // Keep the original inode alive at another name so the replacement cannot reuse it.
        let oldTarget = fixture.root.appendingPathComponent("old-target.bin")
        try FileManager.default.moveItem(at: fixture.target, to: oldTarget)
        try Data("replacement".utf8).write(to: fixture.target)

        XCTAssertEqual(
            second.reconcilePersistedRecords().invalidatedPaths,
            [fixture.target.path]
        )
        let changed = second.reserve(
            paths: [fixture.target.path],
            operationID: UUID(),
            reviewIdentity: staleReview
        )
        guard case .rejected(let rejection, let invalidated) = changed else {
            return XCTFail("The old authorization must reject a replacement inode")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .freshReviewRequired)
        XCTAssertTrue(invalidated.isEmpty, "The durable transition is published only once")

        guard case .rejected(let repeated, _) = second.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("A raw-path retry must never clear the durable review requirement")
        }
        XCTAssertEqual(repeated.reasonsByPath[fixture.target.path], .freshReviewRequired)

        let freshOperationID = UUID()
        let freshReview = reviewIdentity(sessionID: reviewSessionID, revision: 8)
        guard case .reserved(let paths, let invalidatedOnFreshReserve) = second.reserve(
            paths: [fixture.target.path],
            operationID: freshOperationID,
            reviewIdentity: freshReview
        ) else {
            return XCTFail("A strictly newer frozen review must atomically replace and reserve")
        }
        XCTAssertEqual(paths, [fixture.target.path])
        XCTAssertTrue(
            invalidatedOnFreshReserve.isEmpty,
            "The already-published invalidation is not emitted again when fresh review clears it"
        )
        guard case .rejected(let competing, _) = second.reserve(
            paths: [fixture.target.path],
            operationID: UUID(),
            reviewIdentity: staleReview
        ) else {
            return XCTFail("The new operation must own the path immediately after replacement")
        }
        XCTAssertEqual(competing.reasonsByPath[fixture.target.path], .priorOperationPending)
        XCTAssertTrue(second.finish(operationID: freshOperationID, retainingPendingPaths: []))
    }

    func test_legacyInvalidationWithoutReviewIdentityRemainsFailClosed() throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let operationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else {
            return XCTFail("Legacy fixture must reserve initially")
        }
        XCTAssertTrue(fixture.registry.unregister(operationID), "Simulate process restart")
        let restarted = makeRestartedLedger(fixture)
        XCTAssertEqual(
            restarted.reconcilePersistedRecords().invalidatedPaths,
            [fixture.target.path]
        )

        guard case .rejected(let rejection, _) = restarted.reserve(
            paths: [fixture.target.path],
            operationID: UUID(),
            reviewIdentity: reviewIdentity(sessionID: UUID(), revision: 1)
        ) else {
            return XCTFail("A legacy tombstone has no comparable review lineage")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .freshReviewRequired)
    }

    func test_restartMissingTargetPersistsFreshReviewAndNeverAutoResubmits() throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let operationID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else {
            return XCTFail("Initial operation must reserve")
        }
        try FileManager.default.removeItem(at: fixture.target)
        XCTAssertTrue(fixture.registry.unregister(operationID), "Simulate process restart")
        let restarted = makeRestartedLedger(fixture)

        XCTAssertEqual(
            restarted.reconcilePersistedRecords().invalidatedPaths,
            [fixture.target.path]
        )
        let result = restarted.reserve(paths: [fixture.target.path], operationID: UUID())
        guard case .rejected(let rejection, let invalidated) = result else {
            return XCTFail("An absent path cannot be submitted")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .freshReviewRequired)
        XCTAssertTrue(invalidated.isEmpty)
    }

    func test_callbackObservedRemainsOwnedByOriginalRetryAlgorithm() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let competingSurface = makeLedger(fixture)
        let operationID = UUID()
        let firstAttemptID = UUID()
        let retryAttemptID = UUID()
        guard case .reserved = original.reserve(paths: [fixture.target.path], operationID: operationID),
              case .claimed = original.claim(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: firstAttemptID
              ),
              original.markAPIReturned(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: firstAttemptID
              ),
              original.markCallbackObserved(
                  paths: [fixture.target.path],
                  operationID: operationID,
                  attemptID: firstAttemptID
              ) == .applied,
              original.markRetryReady(
                  paths: [fixture.target.path],
                  operationID: operationID,
                  attemptID: firstAttemptID
              ) else {
            return XCTFail("Original operation must reach retryReady")
        }

        guard case .rejected(let rejection, _) = competingSurface.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("A competing surface must not clear retryReady")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)

        // The original batch may still do its single-item diagnostic retry.
        guard case .claimed = original.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: retryAttemptID
        ) else {
            return XCTFail("Only the original operation may claim the released retry generation")
        }
        XCTAssertTrue(original.finish(operationID: operationID, retainingPendingPaths: []))
        guard case .reserved = competingSurface.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("A new request may reserve only after the original explicitly finishes")
        }
    }

    func test_reconciliationDoesNotClearLiveCallbackObservedRecord() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let observer = makeLedger(fixture)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = original.reserve(paths: [fixture.target.path], operationID: operationID),
              case .claimed = original.claim(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: attemptID
              ),
              original.markCallbackObserved(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: attemptID
              ) == .applied else {
            return XCTFail("Original operation must reach callbackObserved")
        }

        XCTAssertTrue(observer.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        guard case .rejected(let rejection, _) = observer.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("Reconciliation must not steal a live original operation")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
    }

    func test_activeOperationReconciliationDoesNotClearSourceMovedBeforeCallback() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let newlyConstructedPipelineLedger = makeLedger(fixture)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = original.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = original.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), original.markAPIReturned(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) else {
            return XCTFail("Original operation must be waiting for its AppKit callback")
        }

        // Script the exact race: AppKit has already moved the source, but it has not invoked
        // the callback yet. A newly initialized TrashPipeline must not interpret absence as a
        // restart reconciliation fact and erase the live tombstone.
        let scriptedTrash = fixture.root.appendingPathComponent("scripted-trash-target.bin")
        try FileManager.default.moveItem(at: fixture.target, to: scriptedTrash)
        XCTAssertTrue(
            newlyConstructedPipelineLedger.reconcilePersistedRecords().invalidatedPaths.isEmpty
        )

        let competingOperationID = UUID()
        guard case .rejected(let rejection, let invalidated) = newlyConstructedPipelineLedger.reserve(
            paths: [fixture.target.path],
            operationID: competingOperationID
        ) else {
            return XCTFail("The live operation must still own its absent source tombstone")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
        XCTAssertTrue(invalidated.isEmpty)
        XCTAssertFalse(fixture.registry.contains(competingOperationID))

        XCTAssertTrue(original.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertFalse(fixture.registry.contains(operationID))
    }

    func test_activeOperationProtectsEverySiblingWhenSourcesDisappearOrChange() throws {
        let fixture = try makeFixture()
        let sibling = fixture.root.appendingPathComponent("sibling.bin")
        try Data("sibling".utf8).write(to: sibling)
        let original = makeLedger(fixture)
        let observer = makeLedger(fixture)
        let operationID = UUID()
        let attemptID = UUID()
        let identity = reviewIdentity(sessionID: UUID(), revision: 1)
        guard case .reserved = original.reserve(
            paths: [fixture.target.path, sibling.path],
            operationID: operationID,
            reviewIdentity: identity
        ), case .claimed = original.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), original.markAPIReturned(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) else {
            return XCTFail("The parent operation must own both siblings")
        }

        try FileManager.default.removeItem(at: fixture.target)
        let oldSibling = fixture.root.appendingPathComponent("old-sibling.bin")
        try FileManager.default.moveItem(at: sibling, to: oldSibling)
        try Data("replacement".utf8).write(to: sibling)

        XCTAssertTrue(observer.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        for path in [fixture.target.path, sibling.path] {
            guard case .rejected(let rejection, let invalidated) = observer.reserve(
                paths: [path],
                operationID: UUID(),
                reviewIdentity: reviewIdentity(sessionID: UUID(), revision: 2)
            ) else {
                return XCTFail("Every sibling of the active parent must remain owned: \(path)")
            }
            XCTAssertEqual(rejection.reasonsByPath[path], .priorOperationPending)
            XCTAssertTrue(invalidated.isEmpty)
        }

        XCTAssertTrue(original.finish(operationID: operationID, retainingPendingPaths: []))
        XCTAssertEqual(fixture.registry.unregisterTransitionCountForTesting(operationID), 1)
    }

    /// v2026.07.16 cross-process regression: another `open -n` instance has a different local
    /// registry. Its startup reconciliation must use the persisted PID/start-time owner and may
    /// not reinterpret a live pre-claim reservation as restart residue.
    func test_crossProcessLiveReservedCannotBeReconciledOrFreshReviewReplaced() throws {
        let fixture = try makeFixture()
        let ownerA = TrashLedgerProcessIdentity(
            pid: 52_001,
            startTimeSeconds: 300,
            startTimeMicroseconds: 3
        )
        let ownerB = TrashLedgerProcessIdentity(
            pid: 52_002,
            startTimeSeconds: 400,
            startTimeMicroseconds: 4
        )
        let registryA = TrashActiveOperationRegistry()
        let registryB = TrashActiveOperationRegistry()
        let ownerIsActive: PersistentTrashPendingOperationLedger.ProcessLivenessProbe = {
            expected in expected == ownerA || expected == ownerB ? .active : .inactive
        }
        let first = makeLedger(
            fixture,
            processIdentity: ownerA,
            registry: registryA,
            processLivenessProbe: ownerIsActive
        )
        let second = makeLedger(
            fixture,
            processIdentity: ownerB,
            registry: registryB,
            processLivenessProbe: ownerIsActive
        )
        let operationID = UUID()
        let attemptID = UUID()
        let sessionID = UUID()
        guard case .reserved = first.reserve(
            paths: [fixture.target.path],
            operationID: operationID,
            reviewIdentity: reviewIdentity(sessionID: sessionID, revision: 1)
        ) else {
            return XCTFail("First App instance must own the reservation")
        }

        XCTAssertTrue(second.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        guard case .rejected(let rejection, let invalidated) = second.reserve(
            paths: [fixture.target.path],
            operationID: UUID(),
            reviewIdentity: reviewIdentity(sessionID: sessionID, revision: 2)
        ) else {
            return XCTFail("A fresh review in another live App instance cannot steal owner A")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
        XCTAssertTrue(invalidated.isEmpty)
        guard case .claimed = first.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) else {
            return XCTFail("The exact original owner must remain claimable")
        }
        XCTAssertTrue(first.finish(operationID: operationID, retainingPendingPaths: []))
    }

    /// A missing source is the normal intermediate state after AppKit moves it and before the
    /// callback. A different live App process must preserve that exact attempt so the late
    /// callback can still create Undo/notification state exactly once.
    func test_crossProcessLiveCallbackPendingSourceGonePreservesLateCallbackAttempt() throws {
        let fixture = try makeFixture()
        let ownerA = TrashLedgerProcessIdentity(
            pid: 52_101,
            startTimeSeconds: 500,
            startTimeMicroseconds: 5
        )
        let ownerB = TrashLedgerProcessIdentity(
            pid: 52_102,
            startTimeSeconds: 600,
            startTimeMicroseconds: 6
        )
        let registryA = TrashActiveOperationRegistry()
        let registryB = TrashActiveOperationRegistry()
        let ownerIsActive: PersistentTrashPendingOperationLedger.ProcessLivenessProbe = {
            expected in expected == ownerA || expected == ownerB ? .active : .inactive
        }
        let first = makeLedger(
            fixture,
            processIdentity: ownerA,
            registry: registryA,
            processLivenessProbe: ownerIsActive
        )
        let second = makeLedger(
            fixture,
            processIdentity: ownerB,
            registry: registryB,
            processLivenessProbe: ownerIsActive
        )
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = first.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = first.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), first.markAPIReturned(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) else {
            return XCTFail("First App instance must reach callbackPending")
        }
        let scriptedTrash = fixture.root.appendingPathComponent("scripted-trash.bin")
        try FileManager.default.moveItem(at: fixture.target, to: scriptedTrash)

        XCTAssertTrue(second.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        guard case .rejected(let rejection, let invalidated) = second.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("Another process cannot replace a live absent-source attempt")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
        XCTAssertTrue(invalidated.isEmpty)
        XCTAssertEqual(first.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .applied)
        XCTAssertTrue(first.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertEqual(registryA.unregisterTransitionCountForTesting(operationID), 1)
    }

    /// PID reuse must not revive the old owner. The same numeric PID with a different kernel
    /// start timestamp is a new process, so an unclaimed reservation becomes fresh-review state.
    func test_pidReuseWithDifferentStartTreatsReservedOwnerInactive() throws {
        let fixture = try makeFixture()
        let oldOwner = TrashLedgerProcessIdentity(
            pid: 52_201,
            startTimeSeconds: 700,
            startTimeMicroseconds: 7
        )
        let reusedPIDOwner = TrashLedgerProcessIdentity(
            pid: oldOwner.pid,
            startTimeSeconds: 701,
            startTimeMicroseconds: 8
        )
        let registryA = TrashActiveOperationRegistry()
        let registryB = TrashActiveOperationRegistry()
        let first = makeLedger(
            fixture,
            processIdentity: oldOwner,
            registry: registryA,
            processLivenessProbe: { $0 == oldOwner ? .active : .inactive }
        )
        let second = makeLedger(
            fixture,
            processIdentity: reusedPIDOwner,
            registry: registryB,
            processLivenessProbe: { expected in
                expected == reusedPIDOwner ? .active : .inactive
            }
        )
        let operationID = UUID()
        let sessionID = UUID()
        let staleReview = reviewIdentity(sessionID: sessionID, revision: 1)
        guard case .reserved = first.reserve(
            paths: [fixture.target.path],
            operationID: operationID,
            reviewIdentity: staleReview
        ) else {
            return XCTFail("Old PID generation must reserve")
        }
        XCTAssertTrue(registryA.unregister(operationID), "Simulate old PID generation exit")

        XCTAssertEqual(
            second.reconcilePersistedRecords().invalidatedPaths,
            [fixture.target.path]
        )
        guard case .rejected(let stale, _) = second.reserve(
            paths: [fixture.target.path],
            operationID: UUID(),
            reviewIdentity: staleReview
        ) else {
            return XCTFail("PID reuse must not revive the old authorization")
        }
        XCTAssertEqual(stale.reasonsByPath[fixture.target.path], .freshReviewRequired)

        let replacementOperationID = UUID()
        guard case .reserved = second.reserve(
            paths: [fixture.target.path],
            operationID: replacementOperationID,
            reviewIdentity: reviewIdentity(sessionID: sessionID, revision: 2)
        ) else {
            return XCTFail("A strictly newer review may replace the dead unclaimed generation")
        }
        XCTAssertTrue(second.finish(
            operationID: replacementOperationID,
            retainingPendingPaths: []
        ))
    }

    /// proc_pidinfo failure is not evidence of process death. Even with an absent source, a
    /// liveness-unavailable owner remains untouched and every new submission fails closed.
    func test_ownerProbeUnavailableFailsClosedWithoutMutatingRecord() throws {
        let fixture = try makeFixture()
        let ownerA = TrashLedgerProcessIdentity(
            pid: 52_301,
            startTimeSeconds: 800,
            startTimeMicroseconds: 9
        )
        let ownerB = TrashLedgerProcessIdentity(
            pid: 52_302,
            startTimeSeconds: 900,
            startTimeMicroseconds: 10
        )
        let registryA = TrashActiveOperationRegistry()
        let registryB = TrashActiveOperationRegistry()
        let first = makeLedger(
            fixture,
            processIdentity: ownerA,
            registry: registryA,
            processLivenessProbe: { $0 == ownerA ? .active : .inactive }
        )
        let unavailableObserver = makeLedger(
            fixture,
            processIdentity: ownerB,
            registry: registryB,
            processLivenessProbe: { expected in
                expected == ownerA ? .unavailable : .active
            }
        )
        let operationID = UUID()
        guard case .reserved = first.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else {
            return XCTFail("Owner A must reserve")
        }
        let scriptedTrash = fixture.root.appendingPathComponent("probe-unavailable.bin")
        try FileManager.default.moveItem(at: fixture.target, to: scriptedTrash)

        XCTAssertTrue(unavailableObserver.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        let competingOperationID = UUID()
        guard case .rejected(let unavailable, let invalidated) = unavailableObserver.reserve(
            paths: [fixture.target.path],
            operationID: competingOperationID
        ) else {
            return XCTFail("An unavailable liveness probe must reject, not replace")
        }
        XCTAssertEqual(unavailable.reasonsByPath[fixture.target.path], .ledgerUnavailable)
        XCTAssertTrue(invalidated.isEmpty)
        XCTAssertFalse(registryB.contains(competingOperationID))

        let activeObserver = makeLedger(
            fixture,
            processIdentity: ownerB,
            registry: TrashActiveOperationRegistry(),
            processLivenessProbe: { expected in expected == ownerA ? .active : .inactive }
        )
        guard case .rejected(let stillPending, _) = activeObserver.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("The unavailable probe must leave the original record intact")
        }
        XCTAssertEqual(stillPending.reasonsByPath[fixture.target.path], .priorOperationPending)
        XCTAssertTrue(first.finish(operationID: operationID, retainingPendingPaths: []))
    }

    func test_oldAttemptEventsCannotMutateNewAttemptPendingState() throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let operationID = UUID()
        let attempt1 = UUID()
        let attempt2 = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = ledger.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt1
        ), ledger.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt1
        ) == .applied, ledger.markRetryReady(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt1
        ), case .claimed = ledger.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt2
        ) else {
            return XCTFail("Attempt 1 must release exactly one retry claim to attempt 2")
        }

        XCTAssertEqual(ledger.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt1
        ), .stale, "A duplicate callback from attempt 1 is stale after attempt 2 claims")
        XCTAssertFalse(ledger.markAPIReturned(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt1
        ), "A late API return from attempt 1 cannot advance attempt 2")
        XCTAssertTrue(ledger.markAPIReturned(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt2
        ))

        // Model attempt 2's callback timeout: outer finalization retains the path and every
        // other surface remains blocked by the exact active generation.
        XCTAssertTrue(ledger.finish(
            operationID: operationID,
            retainingPendingPaths: [fixture.target.path]
        ))
        guard case .rejected(let rejection, _) = ledger.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("Attempt 2 must still own the pending path")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
        XCTAssertTrue(ledger.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attempt2
        ))
        XCTAssertEqual(fixture.registry.unregisterTransitionCountForTesting(operationID), 1)
    }

    func test_restartReservedSameIdentityRequiresFreshReviewInsteadOfStayingPending() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let restarted = makeRestartedLedger(fixture)
        let operationID = UUID()
        guard case .reserved = original.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else {
            return XCTFail("Initial operation must reserve")
        }

        // The registry is intentionally process-only. Removing this ID simulates the state
        // after an App restart while preserving the on-disk ledger for recovery.
        XCTAssertTrue(fixture.registry.unregister(operationID))
        XCTAssertEqual(
            restarted.reconcilePersistedRecords().invalidatedPaths,
            [fixture.target.path]
        )
        guard case .rejected(let rejection, _) = restarted.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("A pre-claim interrupted authorization requires a new typed review")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .freshReviewRequired)
    }

    func test_restartClaimedSameIdentityRemainsPendingFailClosed() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let restarted = makeRestartedLedger(fixture)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = original.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = original.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), original.markAPIReturned(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) else {
            return XCTFail("Fixture must reach callbackPending")
        }
        XCTAssertTrue(fixture.registry.unregister(operationID), "Simulate process restart")

        XCTAssertTrue(restarted.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        guard case .rejected(let rejection, _) = restarted.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("A same-inode callback uncertainty must remain pending")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.target.path], .priorOperationPending)
    }

    func test_restartCallbackObservedIsTerminalAndDoesNotStayPending() throws {
        let fixture = try makeFixture()
        let original = makeLedger(fixture)
        let restarted = makeRestartedLedger(fixture)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = original.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = original.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), original.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) == .applied else {
            return XCTFail("Fixture must reach callbackObserved")
        }
        XCTAssertTrue(fixture.registry.unregister(operationID), "Simulate process restart")

        XCTAssertTrue(restarted.reconcilePersistedRecords().invalidatedPaths.isEmpty)
        guard case .reserved = restarted.reserve(
            paths: [fixture.target.path],
            operationID: UUID()
        ) else {
            return XCTFail("An authoritative callback is terminal and must not remain pending")
        }
    }

    func test_independentLockInodeSerializesRMW() throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let descriptor = ledger.lockURLForTesting.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ledger.reserve(paths: [fixture.target.path], operationID: UUID())
            completed.signal()
        }
        XCTAssertEqual(
            completed.wait(timeout: .now() + 0.10),
            .timedOut,
            "The RMW must block on the independent lock inode"
        )
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(completed.wait(timeout: .now() + 2.0), .success)
    }

    func testCrashTempSweepWaitsForStableFlockAndPreservesLookalikes() throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let stale = fixture.root.appendingPathComponent(
            ".trash-pending.\(UUID().uuidString).tmp"
        )
        let malformed = fixture.root.appendingPathComponent(
            ".trash-pending.not-a-uuid.tmp"
        )
        let extraSuffix = fixture.root.appendingPathComponent(
            ".trash-pending.\(UUID().uuidString).tmp.backup"
        )
        let protectedTarget = fixture.root.appendingPathComponent("user-owned.json")
        let exactLookingSymlink = fixture.root.appendingPathComponent(
            ".trash-pending.\(UUID().uuidString).tmp"
        )
        try Data("stale".utf8).write(to: stale)
        try Data("malformed".utf8).write(to: malformed)
        try Data("keep".utf8).write(to: extraSuffix)
        try Data("user".utf8).write(to: protectedTarget)
        try FileManager.default.createSymbolicLink(
            at: exactLookingSymlink,
            withDestinationURL: protectedTarget
        )

        let descriptor = ledger.lockURLForTesting.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ledger.reserve(paths: [fixture.target.path], operationID: UUID())
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 0.10), .timedOut)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stale.path),
            "A competing store cannot sweep until it owns the stable ledger flock"
        )

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactLookingSymlink.path))
        XCTAssertEqual(try String(contentsOf: protectedTarget, encoding: .utf8), "user")
    }

    func test_queueWaitBudgetExpiresBeforeClaimAndNeverCallsWorkspace() async throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let operationID = UUID()
        guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID) else {
            return XCTFail("Initial operation must reserve")
        }
        let queue = DispatchQueue(label: "TrashPendingLedgerTests.blocked-queue")
        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async {
            queueEntered.signal()
            releaseQueue.wait()
        }
        XCTAssertEqual(queueEntered.wait(timeout: .now() + 1), .success)
        let calls = LockedCounter()

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            timeoutSeconds: 0.05,
            ledger: ledger,
            submissionQueue: queue,
            workspaceRecycle: { _, _ in calls.increment() },
            lateHandler: { _, _ in }
        )
        guard case .notSubmittedBudgetExpired = result.state else {
            return XCTFail("Queue starvation must be notSubmitted, got \(result.state)")
        }
        releaseQueue.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.snapshot(), 0, "A timed-out queue item must never call AppKit later")
        XCTAssertTrue(ledger.finish(operationID: operationID, retainingPendingPaths: []))
    }

    func test_synchronousAPICallStallIsSubmissionUnknownAndLateCallbackRunsOnce() async throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let operationID = UUID()
        guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID) else {
            return XCTFail("Initial operation must reserve")
        }
        let apiEntered = DispatchSemaphore(value: 0)
        let releaseAPI = DispatchSemaphore(value: 0)
        let workspaceCalls = LockedCounter()
        let lateCalls = LockedCounter()

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            timeoutSeconds: 0.05,
            ledger: ledger,
            submissionQueue: DispatchQueue(label: "TrashPendingLedgerTests.blocked-api"),
            workspaceRecycle: { _, callback in
                workspaceCalls.increment()
                apiEntered.signal()
                releaseAPI.wait()
                let pair = [(fixture.target.path, "/tmp/scripted-trash-target")]
                callback(pair, nil)
                callback(pair, nil)
            },
            lateHandler: { _, _ in lateCalls.increment() }
        )
        XCTAssertEqual(apiEntered.wait(timeout: .now() + 1), .success)
        guard case .submissionUnknown(let returnedID) = result.state else {
            releaseAPI.signal()
            return XCTFail("A synchronous API stall must remain submissionUnknown, got \(result.state)")
        }
        XCTAssertEqual(returnedID, operationID)
        releaseAPI.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(workspaceCalls.snapshot(), 1)
        XCTAssertEqual(lateCalls.snapshot(), 1, "Duplicate late callbacks must reconcile once")
        XCTAssertFalse(
            fixture.registry.contains(operationID),
            "The first late terminal callback must clear the final record and active owner"
        )
        XCTAssertEqual(
            fixture.registry.unregisterTransitionCountForTesting(operationID),
            1,
            "Late terminal convergence must unregister the parent exactly once"
        )
    }

    func test_normalDuplicateCallbackCompletesOnceAndDoesNotRunLateHandler() async throws {
        let fixture = try makeFixture()
        let ledger = makeLedger(fixture)
        let operationID = UUID()
        guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID) else {
            return XCTFail("Initial operation must reserve")
        }
        let lateCalls = LockedCounter()
        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            timeoutSeconds: 1,
            ledger: ledger,
            submissionQueue: DispatchQueue(label: "TrashPendingLedgerTests.normal-callback"),
            workspaceRecycle: { _, callback in
                callback([], "scripted failure")
                callback([], "duplicate")
            },
            lateHandler: { _, _ in lateCalls.increment() }
        )

        guard case .callbackCompleted = result.state else {
            return XCTFail("The first normal callback must complete the attempt")
        }
        XCTAssertEqual(result.errorDescription, "scripted failure")
        XCTAssertEqual(lateCalls.snapshot(), 0)
        guard case .claimed = ledger.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: UUID()
        ) else {
            return XCTFail("Returning from a normal callback must already expose retryReady")
        }
        XCTAssertTrue(ledger.finish(operationID: operationID, retainingPendingPaths: []))
        XCTAssertFalse(fixture.registry.contains(operationID))
        XCTAssertEqual(
            fixture.registry.unregisterTransitionCountForTesting(operationID),
            1,
            "Normal outer terminal convergence must unregister the parent exactly once"
        )
        XCTAssertTrue(ledger.finish(operationID: operationID, retainingPendingPaths: []))
        XCTAssertEqual(
            fixture.registry.unregisterTransitionCountForTesting(operationID),
            1,
            "Repeated outer cleanup cannot create a second unregister transition"
        )
    }
}
