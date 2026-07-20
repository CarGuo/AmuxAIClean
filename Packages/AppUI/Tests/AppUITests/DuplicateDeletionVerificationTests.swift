import Dispatch
import Foundation
import ScanKit
import XCTest
@testable import AppUI

final class DuplicateDeletionVerificationTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private final class LockedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ event: String) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class LedgerSpy: TrashPendingOperationLedger, @unchecked Sendable {
        private let lock = NSLock()
        private var reserveCount = 0
        private var claimCount = 0
        private var finishCount = 0
        private var frozenIdentitiesByOperation: [UUID: [String: TrashObjectIdentity]] = [:]

        func reserve(
            paths: [String],
            operationID: UUID,
            reviewIdentity: DeletionSnapshotIdentity?
        ) -> TrashPendingLedgerReservation {
            let identities: [String: TrashObjectIdentity] = Dictionary(
                uniqueKeysWithValues: paths.compactMap { path in
                    guard case .present(let identity) = TrashObjectIdentity.probe(path: path) else {
                        return nil
                    }
                    return (path, identity)
                }
            )
            lock.lock()
            reserveCount += 1
            frozenIdentitiesByOperation[operationID] = identities
            lock.unlock()
            return .reserved(normalizedPaths: paths, invalidatedPaths: [])
        }

        func claim(
            paths: [String],
            operationID: UUID,
            attemptID: UUID
        ) -> TrashPendingLedgerClaim {
            lock.lock()
            claimCount += 1
            lock.unlock()
            return .claimed
        }

        func markAPIReturned(paths: [String], operationID: UUID, attemptID: UUID) -> Bool { true }
        func markCallbackObserved(
            paths: [String],
            operationID: UUID,
            attemptID: UUID,
            undoJournalBlockedPaths: Set<String>
        ) -> TrashPendingLedgerCallbackObservation { .applied }
        func markRetryReady(paths: [String], operationID: UUID, attemptID: UUID) -> Bool { true }

        func finish(operationID: UUID, retainingPendingPaths: Set<String>) -> Bool {
            lock.lock()
            finishCount += 1
            lock.unlock()
            return true
        }

        func finish(paths: [String], operationID: UUID, attemptID: UUID) -> Bool { true }

        func frozenIdentities(
            paths: [String],
            operationID: UUID
        ) -> [String: TrashObjectIdentity]? {
            lock.lock()
            defer { lock.unlock() }
            guard let frozen = frozenIdentitiesByOperation[operationID],
                  paths.allSatisfy({ frozen[$0] != nil }) else { return nil }
            return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
                frozen[path].map { (path, $0) }
            })
        }

        func reconcilePersistedRecords() -> TrashPendingLedgerReconciliation {
            TrashPendingLedgerReconciliation(invalidatedPaths: [])
        }

        func snapshot() -> (reserved: Int, claimed: Int, finished: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (reserveCount, claimCount, finishCount)
        }
    }

    private func makeFixture() throws -> (root: URL, first: URL, second: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateDeletionVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("a.bin")
        let second = root.appendingPathComponent("b.bin")
        let payload = Data(repeating: 0x5A, count: 64 * 1_024)
        try payload.write(to: first)
        try payload.write(to: second)
        addTeardownBlock {
            // Best-effort test teardown only: every fixture is isolated under NSTemporaryDirectory.
            try? FileManager.default.removeItem(at: root)
        }
        return (root, first, second)
    }

    private func scanGroup(root: URL) async throws -> DuplicateGroup {
        let groups = await DuplicateScanner(roots: [root], minBytes: 1).scanToCompletion()
        return try XCTUnwrap(groups.first)
    }

    /// v2026.07.18 regression owner: a scripted ledger must never inherit the real user's
    /// completion journal or Undo projection. Construct all three durable dependencies under the
    /// same fixture root and pass them as one recovery domain.
    private func makeRecoveryDomain(
        root: URL,
        ledger: any TrashPendingOperationLedger
    ) async -> TrashRecoveryDependencyDomain {
        await MainActor.run {
            TrashRecoveryDependencyDomain(
                pendingOperationLedger: ledger,
                completionJournal: PersistentTrashCompletionJournal(
                    fileURL: root.appendingPathComponent("trash-completion-journal.json")
                ),
                undoHistoryStore: UndoHistoryStore(
                    storeURL: root.appendingPathComponent("UndoHistory.json"),
                    allowedRestoreRoots: [root.path]
                )
            )
        }
    }

    func testScannerFreezesFullHashAndDescriptorIdentityForEveryFile() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)

        XCTAssertEqual(group.reliability, .full)
        XCTAssertNotNil(group.contentFingerprint)
        XCTAssertTrue(group.files.allSatisfy { $0.snapshotIdentity != nil })
        XCTAssertTrue(DuplicateHandlingPlan.isExecutableGroup(group))
    }

    func testFinalVerifierAcceptsTargetsAndRetainedReferenceFromSameSnapshot() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))

        let rejections = await DuplicateDeletionFinalVerifier.verify(
            request: request,
            authorizedPaths: [target]
        )
        XCTAssertTrue(rejections.isEmpty)
    }

    func testFinalVerifierBlocksChangedTargetBeforeAnySubmissionBoundary() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        try Data(repeating: 0x41, count: 64 * 1_024).write(
            to: URL(fileURLWithPath: target),
            options: .atomic
        )

        let rejections = await DuplicateDeletionFinalVerifier.verify(
            request: request,
            authorizedPaths: [target]
        )
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections[0].path, target)
        XCTAssertEqual(
            rejections[0].reason,
            DuplicateDeletionVerificationRejectionReason.targetIdentityChanged.rawValue
        )
    }

    func testFinalVerifierAlsoBlocksWhenOnlyRetainedCopyChanged() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        try Data(repeating: 0x42, count: 64 * 1_024).write(
            to: URL(fileURLWithPath: request.retainedReference.path),
            options: .atomic
        )

        let rejections = await DuplicateDeletionFinalVerifier.verify(
            request: request,
            authorizedPaths: [target]
        )
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections[0].path, request.retainedReference.path)
        XCTAssertEqual(
            rejections[0].reason,
            DuplicateDeletionVerificationRejectionReason.retainedReferenceChanged.rawValue
        )
    }

    func testVerificationRequestCannotExpandOrIncludeRetainedCopy() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))

        XCTAssertNil(request.restricting(to: [request.retainedReference.path]))
        XCTAssertNil(request.restricting(to: [fixture.root.appendingPathComponent("outside").path]))
    }

    func testExplicitCancellationTokenConvergesWithoutWaitingForGCDTaskContext() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        let token = DuplicateDeletionVerificationCancellationToken()
        token.cancel()

        let rejections = await DuplicateDeletionFinalVerifier.verify(
            request: request,
            authorizedPaths: [target],
            cancellationToken: token
        )

        XCTAssertEqual(
            rejections.map(\.reason),
            [DuplicateDeletionVerificationRejectionReason.verificationCancelled.rawValue]
        )
    }

    func testGCDWorkerObservesCancellationBetweenFullFileReads() async throws {
        let fixture = try makeFixture()
        let third = fixture.root.appendingPathComponent("c.bin")
        try Data(contentsOf: fixture.first).write(to: third)
        let group = try await scanGroup(root: fixture.root)
        let targets = Array(group.files.dropFirst().map(\.path))
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: targets
        ))
        let token = DuplicateDeletionVerificationCancellationToken()

        let rejections = await DuplicateDeletionFinalVerifier.verify(
            request: request,
            authorizedPaths: targets,
            cancellationToken: token,
            progress: { progress in
                if progress.phase == .verifyingTargets, progress.completedItems == 1 {
                    token.cancel()
                }
            }
        )

        XCTAssertEqual(rejections.count, targets.count)
        XCTAssertTrue(rejections.allSatisfy {
            $0.reason == DuplicateDeletionVerificationRejectionReason
                .verificationCancelled.rawValue
        })
    }

    func testExecutionProgressReducerRejectsStaleOwnerAndRevision() {
        let session = UUID()
        let owner = DuplicateDeletionExecutionOwner(
            id: UUID(),
            scanSessionID: session,
            scanRevision: 8
        )
        let event = DeletionExecutionProgress.duplicate(.init(
            phase: .verifyingTargets,
            completedItems: 1,
            totalItems: 3,
            currentPath: "/tmp/a"
        ))

        XCTAssertNil(DuplicateDeletionExecutionProgressReducer.reduce(
            current: nil,
            event: event,
            eventOwner: owner,
            currentOwner: nil,
            currentSessionID: session,
            currentRevision: 8
        ))
        XCTAssertNil(DuplicateDeletionExecutionProgressReducer.reduce(
            current: nil,
            event: event,
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 9
        ))
    }

    func testExecutionProgressReducerIsMonotonicAndDoesNotDeclareRecycleSuccess() throws {
        let session = UUID()
        let owner = DuplicateDeletionExecutionOwner(
            id: UUID(),
            scanSessionID: session,
            scanRevision: 3
        )
        let retained = DuplicateDeletionExecutionProgressReducer.reduce(
            current: .preparing,
            event: .duplicate(.init(
                phase: .verifyingRetainedReference,
                completedItems: 2,
                totalItems: 3,
                currentPath: "/tmp/retained"
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 3
        )
        XCTAssertEqual(retained?.phase, .verifyingRetainedReference)

        let regressed = DuplicateDeletionExecutionProgressReducer.reduce(
            current: retained,
            event: .duplicate(.init(
                phase: .verifyingTargets,
                completedItems: 1,
                totalItems: 3,
                currentPath: "/tmp/late"
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 3
        )
        XCTAssertEqual(regressed, retained)

        let verified = DuplicateDeletionExecutionProgressReducer.reduce(
            current: retained,
            event: .duplicate(.init(
                phase: .completed,
                completedItems: 3,
                totalItems: 3,
                currentPath: nil
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 3
        )
        XCTAssertEqual(verified?.phase, .finalizingVerification,
                       "hash 读完仍可能有拒绝；不能提前声称已进入废纸篓提交")

        let submitting = DuplicateDeletionExecutionProgressReducer.reduce(
            current: verified,
            event: .duplicate(.init(
                phase: .submittingToTrash,
                completedItems: 3,
                totalItems: 3,
                currentPath: nil
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 3
        )
        XCTAssertEqual(submitting?.phase, .submittingToTrash,
                       "只有 pipeline 验证无拒绝后才能进入提交态；成功仍等待 recycle terminal")

        let cancelling = DuplicateDeletionExecutionStatus(
            phase: .cancelling,
            completedItems: 2,
            totalItems: 3,
            currentPath: nil
        )
        let submittedAfterCancellationRace = DuplicateDeletionExecutionProgressReducer.reduce(
            current: cancelling,
            event: .duplicate(.init(
                phase: .submittingToTrash,
                completedItems: 3,
                totalItems: 3,
                currentPath: nil
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 3
        )
        XCTAssertEqual(submittedAfterCancellationRace?.phase, .submittingToTrash,
                       "提交边界赢得竞态后，sheet 不能一直停留在正在停止")

        let staleVerificationAfterCancellation = DuplicateDeletionExecutionProgressReducer.reduce(
            current: cancelling,
            event: .duplicate(.init(
                phase: .verifyingTargets,
                completedItems: 2,
                totalItems: 3,
                currentPath: "/tmp/stale"
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentSessionID: session,
            currentRevision: 3
        )
        XCTAssertEqual(staleVerificationAfterCancellation, cancelling,
                       "停止请求后不得被缓冲的旧验证 frame 回退")
    }

    func testDepartureRequestsCancellationUntilSubmissionAndThenPreservesTracking() {
        let finalizing = DuplicateDeletionExecutionStatus(
            phase: .finalizingVerification,
            completedItems: 2,
            totalItems: 2,
            currentPath: nil
        )
        XCTAssertEqual(
            DuplicateDeletionDeparturePolicy.action(
                for: finalizing,
                hasExecutionTask: true,
                hasCrossedSubmissionBoundary: false
            ),
            .requestCancellation,
            "最终验证完成事件仍位于 recycle 提交边界之前，离页必须请求取消"
        )

        let submitted = DuplicateDeletionExecutionStatus(
            phase: .submittingToTrash,
            completedItems: 2,
            totalItems: 2,
            currentPath: nil
        )
        XCTAssertEqual(
            DuplicateDeletionDeparturePolicy.action(
                for: submitted,
                hasExecutionTask: true,
                hasCrossedSubmissionBoundary: true
            ),
            .preserveTrackedTransaction,
            "NSWorkspace 提交开始后不能把任务丢成无主状态，必须等待类型化终态"
        )
        XCTAssertEqual(
            DuplicateDeletionDeparturePolicy.action(
                for: submitted,
                hasExecutionTask: false,
                hasCrossedSubmissionBoundary: true
            ),
            .none
        )

        XCTAssertEqual(
            DuplicateDeletionDeparturePolicy.action(
                for: finalizing,
                hasExecutionTask: true,
                hasCrossedSubmissionBoundary: true
            ),
            .preserveTrackedTransaction,
            "worker 边界优先于可能滞后的 MainActor phase"
        )
    }

    func testRetainedIdentityFenceRunsBeforeLedgerClaimAndWorkspaceCall() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        try Data(repeating: 0x4F, count: 64 * 1_024).write(
            to: URL(fileURLWithPath: request.retainedReferencePath),
            options: .atomic
        )
        let ledger = LedgerSpy()
        let workspaceCalls = LockedCounter()
        let submissionSignals = LockedCounter()
        let fence = DuplicateDeletionClaimFence(
            request: request,
            cancellationToken: DuplicateDeletionVerificationCancellationToken()
        )

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [URL(fileURLWithPath: target)],
            operationID: UUID(),
            timeoutSeconds: 1,
            ledger: ledger,
            submissionQueue: DispatchQueue(label: "DuplicateDeletionVerificationTests.claim-fence"),
            workspaceRecycle: { _, callback in
                workspaceCalls.increment()
                callback([], nil)
            },
            lateHandler: { _, _ in },
            duplicateClaimFence: fence,
            submissionObserver: { submissionSignals.increment() }
        )

        guard case .preSubmitRejected(let rejection) = result.state else {
            return XCTFail("Changed retained survivor must block beside the concrete claim")
        }
        XCTAssertEqual(
            rejection.reasonsByPath[target],
            .duplicateRetainedReferenceChanged
        )
        XCTAssertEqual(ledger.snapshot().claimed, 0)
        XCTAssertEqual(workspaceCalls.value, 0)
        XCTAssertEqual(submissionSignals.value, 0,
                       "claim-adjacent fence 拒绝时不能提前宣称已提交")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
    }

    func testSubmissionProgressBoundaryIsAfterClaimFenceAndImmediatelyBeforeWorkspaceCall() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        let events = LockedEvents()

        _ = await TrashPipeline.executeRecycleOnce(
            urls: [URL(fileURLWithPath: target)],
            operationID: UUID(),
            timeoutSeconds: 1,
            ledger: LedgerSpy(),
            submissionQueue: DispatchQueue(label: "DuplicateDeletionVerificationTests.progress-boundary"),
            workspaceRecycle: { _, callback in
                events.append("workspace")
                callback([], nil)
            },
            lateHandler: { _, _ in },
            duplicateClaimFence: DuplicateDeletionClaimFence(
                request: request,
                cancellationToken: DuplicateDeletionVerificationCancellationToken()
            ),
            submissionObserver: { events.append("observer") }
        )

        XCTAssertEqual(events.snapshot, ["observer", "workspace"])
    }

    func testTargetIdentityFenceUsesFullHashSnapshotBeforeLedgerClaim() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        try Data(repeating: 0x50, count: 64 * 1_024).write(
            to: URL(fileURLWithPath: target),
            options: .atomic
        )
        let ledger = LedgerSpy()
        let workspaceCalls = LockedCounter()

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [URL(fileURLWithPath: target)],
            operationID: UUID(),
            timeoutSeconds: 1,
            ledger: ledger,
            submissionQueue: DispatchQueue(label: "DuplicateDeletionVerificationTests.target-fence"),
            workspaceRecycle: { _, callback in
                workspaceCalls.increment()
                callback([], nil)
            },
            lateHandler: { _, _ in },
            duplicateClaimFence: DuplicateDeletionClaimFence(
                request: request,
                cancellationToken: DuplicateDeletionVerificationCancellationToken()
            )
        )

        guard case .preSubmitRejected(let rejection) = result.state else {
            return XCTFail("Changed full-hash target identity must block beside the concrete claim")
        }
        XCTAssertEqual(rejection.reasonsByPath[target], .duplicateTargetIdentityChanged)
        XCTAssertEqual(ledger.snapshot().claimed, 0)
        XCTAssertEqual(workspaceCalls.value, 0)
    }

    func testProductionPipelineVerificationFailureReleasesReservationAndNeverClaimsRecycle() async throws {
        let fixture = try makeFixture()
        let group = try await scanGroup(root: fixture.root)
        let target = try XCTUnwrap(group.files.last?.path)
        let request = try XCTUnwrap(DuplicateDeletionVerificationRequest(
            group: group,
            targetPaths: [target]
        ))
        try Data(repeating: 0x43, count: 64 * 1_024).write(
            to: URL(fileURLWithPath: target),
            options: .atomic
        )
        let ledger = LedgerSpy()
        let recoveryDomain = await makeRecoveryDomain(root: fixture.root, ledger: ledger)
        let pipeline = TrashPipeline(
            home: fixture.root.path,
            externalDeletionRoots: [],
            recoveryDependencyDomain: recoveryDomain
        )

        let disposition = await pipeline.submitToTrashReturningDisposition(
            paths: [target],
            accessDeniedPaths: [],
            vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: nil,
            reviewIdentity: DeletionSnapshotIdentity(
                sessionID: UUID(),
                revision: 1,
                categoryID: "duplicate"
            ),
            executionVerification: .duplicate(request)
        )

        guard case .preSubmitRejected(.invalidDuplicateVerification(let rejections)) = disposition else {
            return XCTFail("Changed Duplicate evidence must remain a pre-submit block")
        }
        XCTAssertEqual(rejections.count, 1)
        let ledgerState = ledger.snapshot()
        XCTAssertEqual(ledgerState.reserved, 1)
        XCTAssertEqual(ledgerState.finished, 1)
        XCTAssertEqual(ledgerState.claimed, 0, "Zero claim proves NSWorkspace was never invoked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.retainedReference.path))
    }

    func testUninstallExpectedIdentity在DurableReserve后阻止同路径替换且不ClaimRecycle() async throws {
        let fixture = try makeFixture()
        let measured = DefaultFileManagerSnapshot().snapshot(at: fixture.first.path)
        let candidate = UninstallCandidate(
            path: fixture.first.path,
            snapshot: measured,
            matchReason: .bundleID("com.acme.fixture")
        )
        let request = try XCTUnwrap(UninstallCandidateVerificationRequest(candidates: [candidate]))

        let displaced = fixture.root.appendingPathComponent("displaced-original")
        try FileManager.default.moveItem(at: fixture.first, to: displaced)
        try Data("replacement".utf8).write(to: fixture.first)

        let ledger = LedgerSpy()
        let recoveryDomain = await makeRecoveryDomain(root: fixture.root, ledger: ledger)
        let pipeline = TrashPipeline(
            home: fixture.root.path,
            externalDeletionRoots: [],
            recoveryDependencyDomain: recoveryDomain
        )
        let disposition = await pipeline.submitToTrashReturningDisposition(
            paths: [fixture.first.path],
            accessDeniedPaths: [],
            vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: nil,
            reviewIdentity: DeletionSnapshotIdentity(
                sessionID: UUID(),
                revision: 1,
                categoryID: "uninstall"
            ),
            executionVerification: .uninstall(request)
        )

        guard case .preSubmitRejected(.pendingOperation(let rejection)) = disposition else {
            return XCTFail("same-path replacement must remain a typed pre-submit rejection")
        }
        XCTAssertEqual(rejection.reasonsByPath[fixture.first.path], .identityChanged)
        let ledgerState = ledger.snapshot()
        XCTAssertEqual(ledgerState.reserved, 1)
        XCTAssertEqual(ledgerState.finished, 1)
        XCTAssertEqual(ledgerState.claimed, 0, "zero claim proves NSWorkspace was never invoked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.first.path))
    }
}
