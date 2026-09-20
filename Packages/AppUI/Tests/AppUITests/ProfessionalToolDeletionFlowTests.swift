import XCTest
import Foundation
import BrewKit
import ScanKit
import SafetyKit
@testable import AppUI

private actor DeletionReconciliationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

final class ProfessionalToolDeletionFlowTests: XCTestCase {
    func testDeletionModelSynchronizationUsesOneExactSurfaceAndInvalidatesTheOther() {
        XCTAssertEqual(
            MainDeletionModelSynchronizationPolicy.plan(authoritativeSurface: .professional),
            MainDeletionModelSynchronizationPlan(
                exactSurface: .professional,
                invalidatedSurface: .smartCare
            )
        )
        XCTAssertEqual(
            MainDeletionModelSynchronizationPolicy.plan(authoritativeSurface: .smartCare),
            MainDeletionModelSynchronizationPlan(
                exactSurface: .smartCare,
                invalidatedSurface: .professional
            )
        )
    }

    private actor PipelineState {
        struct Snapshot: Sendable, Equatable {
            let preflightPaths: [[String]]
            let deniedPaths: [Set<String>]
            let moveCalls: Int
        }

        private let preflightResult: DeletionPreflight
        private var preflightPaths: [[String]] = []
        private var deniedPaths: [Set<String>] = []
        private var moveCalls = 0

        init(preflightResult: DeletionPreflight) {
            self.preflightResult = preflightResult
        }

        func preflight(paths: [String], denied: Set<String>) -> DeletionPreflight {
            preflightPaths.append(paths)
            deniedPaths.append(denied)
            return preflightResult
        }

        func recordMove() {
            moveCalls += 1
        }

        func snapshot() -> Snapshot {
            Snapshot(
                preflightPaths: preflightPaths,
                deniedPaths: deniedPaths,
                moveCalls: moveCalls
            )
        }
    }

    private struct SpyPipeline: ScriptedDeletionObjectPipeline {
        let state: PipelineState

        func preflight(
            paths: [String],
            accessDeniedPaths: Set<String>
        ) async -> DeletionPreflight {
            await state.preflight(paths: paths, denied: accessDeniedPaths)
        }

        func moveToTrash(
            paths: [String],
            dryRun: Bool
        ) async -> (Int, Int, String?, [(String, String)]) {
            await state.recordMove()
            return (0, paths.count, "unexpected move", [])
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {}
    }

    private actor UninstallSubmissionState {
        private var submittedPaths: [[String]] = []

        func record(_ paths: [String]) {
            submittedPaths.append(paths)
        }

        func snapshot() -> [[String]] {
            submittedPaths
        }
    }

    private struct UninstallSubmissionSpyPipeline: DeletionPipeline {
        let state: UninstallSubmissionState

        func preflight(
            paths: [String],
            accessDeniedPaths: Set<String>
        ) async -> DeletionPreflight {
            DeletionPreflight(allowedPaths: paths, rejections: [])
        }

        func moveToTrash(
            paths: [String],
            dryRun: Bool
        ) async -> (Int, Int, String?, [(String, String)]) {
            (0, paths.count, "legacy path must not be used", [])
        }

        func submitToTrashReturningDisposition(
            paths: [String],
            accessDeniedPaths: Set<String>,
            vendorOverrideRequest: VendorPathOverrideRequest?
        ) async -> TrashSubmissionDisposition {
            await state.record(paths)
            let pairs = paths.map { ($0, "/tmp/Trash/\(URL(fileURLWithPath: $0).lastPathComponent)") }
            let outcome = TrashOutcome(
                movedPairs: pairs,
                failedPaths: [],
                safetyRejected: [],
                missingPaths: []
            )
            return .recycleCompleted(TrashRecycleCompletion(
                attemptedPaths: paths,
                legacy: (paths.count, 0, nil, pairs),
                outcome: outcome
            ))
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {}
    }

    @MainActor
    func test_duplicateIncompleteRouting_兄弟普通确认_所选目标严格确认() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateIncompleteRouting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let target = home.appendingPathComponent("selected.bin")
        let sibling = home.appendingPathComponent("sibling.bin")
        try Data([0x01]).write(to: target)
        try Data([0x02]).write(to: sibling)

        let pipeline = TrashPipeline(home: home.path)
        // v2026.07.20: coordinator tests must own both pipeline recovery storage and the
        // coordinator's Undo projection. The production shared store is not a test default.
        let coordinator = DeletionInteractionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: UndoHistoryStore(
                storeURL: home.appendingPathComponent("UndoHistory.json"),
                allowedRestoreRoots: [home.path]
            )
        )
        let identity = DeletionSnapshotIdentity(
            sessionID: UUID(),
            revision: 1,
            categoryID: "duplicate"
        )
        let row = RowItem(
            id: target.path,
            url: target,
            title: target.lastPathComponent,
            isDirectory: false,
            bytes: 1,
            logicalBytes: 1,
            fileCount: 1,
            verdict: .safe,
            rejection: .ok
        )

        let siblingIssue = ScanIncompleteIssue(
            path: sibling.path,
            reason: .metadataUnavailable
        )
        let unrelated = DuplicateDeletionPreparationPolicy.relevantIssues(
            overlappingAny: [target.path],
            in: [siblingIssue]
        )
        let ordinaryIntent = try coordinator.makeIntent(
            origin: .duplicate,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [DeletionInteractionCandidateSnapshot(
                path: target.path,
                title: target.lastPathComponent,
                isDirectory: false,
                bytes: 1,
                fileCount: 1,
                accessEvidence: DuplicateDeletionPreparationPolicy.accessEvidence(
                    for: target.path,
                    issues: unrelated
                )
            )]
        )
        let ordinary = await DuplicateDeletionPreparationPolicy.prepare(
            pipeline: pipeline,
            coordinator: coordinator,
            intent: ordinaryIntent,
            currentSnapshotIdentity: identity,
            rows: [row],
            relevantIssues: unrelated
        )
        guard case .confirmation(let ordinaryPrepared) = ordinary else {
            return XCTFail("Unrelated Duplicate evidence must keep a normal confirmation")
        }
        XCTAssertNil(ordinaryPrepared.scanIncompleteOverrideRequest)

        let selectedIssue = ScanIncompleteIssue(
            path: target.path,
            reason: .metadataUnavailable,
            stage: .metadata,
            posixErrorCode: EIO
        )
        let relevant = DuplicateDeletionPreparationPolicy.relevantIssues(
            overlappingAny: [target.path],
            in: [siblingIssue, selectedIssue]
        )
        let strictIntent = try coordinator.makeIntent(
            origin: .duplicate,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [DeletionInteractionCandidateSnapshot(
                path: target.path,
                title: target.lastPathComponent,
                isDirectory: false,
                bytes: 1,
                fileCount: 1,
                accessEvidence: DuplicateDeletionPreparationPolicy.accessEvidence(
                    for: target.path,
                    issues: relevant
                )
            )]
        )
        let strict = await DuplicateDeletionPreparationPolicy.prepare(
            pipeline: pipeline,
            coordinator: coordinator,
            intent: strictIntent,
            currentSnapshotIdentity: identity,
            rows: [row],
            relevantIssues: relevant
        )
        guard case .confirmation(let strictPrepared) = strict else {
            return XCTFail("Selected Duplicate incomplete evidence must reach strict confirmation")
        }
        XCTAssertEqual(strictPrepared.scanIncompleteOverrideRequest?.paths, [target.path])
        XCTAssertEqual(
            strictPrepared.scanIncompleteOverrideRequest?.entries.flatMap(\.incompleteIssues),
            [selectedIssue]
        )
    }

    func test_duplicate确认后开始新扫描_旧意图类型化取消且不进入执行层() async {
        let path = "/tmp/duplicate-stale-intent"
        let oldSessionID = UUID()
        let confirmedIdentity = DeletionSnapshotIdentity(
            sessionID: oldSessionID,
            revision: 8,
            categoryID: "duplicate"
        )
        let state = PipelineState(preflightResult: DeletionPreflight(
            allowedPaths: [path],
            rejections: []
        ))
        let pipeline = SpyPipeline(state: state)

        XCTAssertEqual(
            DuplicateDeletionSubmissionGate.evaluate(
                requestSessionID: oldSessionID,
                requestRevision: 8,
                boundSnapshotIdentity: confirmedIdentity,
                currentSessionID: oldSessionID,
                currentRevision: 8,
                paths: [path]
            ),
            .current,
            "未发生新扫描时，同一快照的确认仍应允许继续"
        )

        // A new scan advances both session and revision after the user confirmed the old sheet.
        let decision = DuplicateDeletionSubmissionGate.evaluate(
            requestSessionID: oldSessionID,
            requestRevision: 8,
            boundSnapshotIdentity: confirmedIdentity,
            currentSessionID: UUID(),
            currentRevision: 9,
            paths: [path]
        )
        switch decision {
        case .current:
            _ = await pipeline.moveToTrash(paths: [path], dryRun: false)
        case .cancelled(let rejections):
            XCTAssertEqual(rejections, [
                .init(path: path, reason: SafetyRejection.preflightCancelled.rawValue)
            ])
        }

        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.moveCalls, 0,
                       "新扫描后，旧确认不得越过 onDismiss 到达删除执行层")
    }

    func test_uninstall确认后切换App_旧意图类型化取消且不进入提交层() async {
        let path = "/tmp/uninstall-stale-intent"
        let state = UninstallSubmissionState()
        let pipeline = UninstallSubmissionSpyPipeline(state: state)
        let identity = DeletionSnapshotIdentity(
            sessionID: UUID(),
            revision: 12,
            categoryID: "/Applications/Old.app"
        )

        let decision = UninstallDeletionSubmissionGate.evaluate(
            requestAppID: "/Applications/Old.app",
            requestSelectionRevision: 12,
            boundSnapshotIdentity: identity,
            currentAppID: "/Applications/New.app",
            currentScanSessionID: identity.sessionID,
            currentSelectionRevision: 13,
            paths: [path]
        )
        switch decision {
        case .current:
            _ = await pipeline.submitToTrashReturningDisposition(
                paths: [path],
                accessDeniedPaths: [],
                vendorOverrideRequest: nil
            )
        case .cancelled(let rejections):
            XCTAssertEqual(rejections, [
                .init(path: path, reason: SafetyRejection.preflightCancelled.rawValue)
            ])
        }

        let staleSubmissions = await state.snapshot()
        XCTAssertEqual(staleSubmissions, [],
                       "确认后 App/revision 变化时，旧请求不得进入真提交边界")
    }

    func test_uninstall当前请求_进入真提交并投影成功路径() async throws {
        let path = "/tmp/uninstall-current-intent"
        let state = UninstallSubmissionState()
        let pipeline = UninstallSubmissionSpyPipeline(state: state)
        let identity = DeletionSnapshotIdentity(
            sessionID: UUID(),
            revision: 21,
            categoryID: "/Applications/Current.app"
        )
        let decision = UninstallDeletionSubmissionGate.evaluate(
            requestAppID: "/Applications/Current.app",
            requestSelectionRevision: 21,
            boundSnapshotIdentity: identity,
            currentAppID: "/Applications/Current.app",
            currentScanSessionID: identity.sessionID,
            currentSelectionRevision: 21,
            paths: [path]
        )
        XCTAssertEqual(decision, .current)

        let disposition = await pipeline.submitToTrashReturningDisposition(
            paths: [path],
            accessDeniedPaths: [],
            vendorOverrideRequest: nil
        )
        guard case .recycleCompleted(let completion) = disposition else {
            return XCTFail("当前确认必须进入 typed recycle completion")
        }
        let succeededPaths = Set(completion.outcome?.movedPairs.map(\.originalPath) ?? [])
        let candidate = UninstallCandidate(
            path: path,
            bytes: 10,
            fileCount: 1,
            matchReason: .bundleID("com.example.current")
        )
        let terminal = UninstallCandidateTerminalProjection.applying(
            succeededPaths: succeededPaths,
            to: UninstallCandidateTerminalState(
                candidates: [candidate],
                checked: [path]
            )
        )

        let currentSubmissions = await state.snapshot()
        XCTAssertEqual(currentSubmissions, [[path]])
        XCTAssertTrue(terminal.candidates.isEmpty,
                      "真提交成功后必须先从当前 UI 模型投影掉已移动路径")
        XCTAssertTrue(terminal.checked.isEmpty)
    }

    func test_uninstall同App同revision但候选扫描session已变化_旧确认被取消() {
        let path = "/tmp/uninstall-stale-session"
        let identity = DeletionSnapshotIdentity(
            sessionID: UUID(),
            revision: 21,
            categoryID: "/Applications/Current.app"
        )

        let decision = UninstallDeletionSubmissionGate.evaluate(
            requestAppID: "/Applications/Current.app",
            requestSelectionRevision: 21,
            boundSnapshotIdentity: identity,
            currentAppID: "/Applications/Current.app",
            currentScanSessionID: UUID(),
            currentSelectionRevision: 21,
            paths: [path]
        )

        guard case .cancelled(let rejections) = decision else {
            return XCTFail("v2026.07.16: a new candidate scan must invalidate the old review")
        }
        XCTAssertEqual(rejections, [
            .init(path: path, reason: SafetyRejection.preflightCancelled.rawValue)
        ])
    }

    func test_rejectedToolPreflightProducesConfirmationPlanWithoutMoveOrResult() async throws {
        let blockedPath = "/Users/test/Library"
        let siblingPath = "/Users/test/Library/Caches/plain"
        let rejections = [
            DeletionPreflight.Rejection(
                path: blockedPath,
                reason: SafetyRejection.rootOrAboveHome.rawValue
            ),
            DeletionPreflight.Rejection(
                path: siblingPath,
                reason: SafetyRejection.batchContainsForbidden.rawValue
            )
        ]
        let state = PipelineState(preflightResult: DeletionPreflight(
            allowedPaths: [],
            rejections: rejections
        ))
        let pipeline = SpyPipeline(state: state)

        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 1)
        let intent = try DeletionIntent(
            origin: .brew,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [
                makeCandidate(
                    path: blockedPath,
                    verdict: .forbid,
                    rejection: .rootOrAboveHome
                ),
                makeCandidate(path: siblingPath, verdict: .safe, rejection: .ok)
            ]
        )
        let decision = try await ToolDeletionPreflightGate.prepareConfirmationDecision(
            pipeline: pipeline,
            intent: intent,
            currentSnapshotIdentity: identity,
            accessDeniedPaths: ["\(blockedPath)/locked"]
        )

        guard case .requiresConfirmation(let plan) = decision else {
            return XCTFail("Safety rejection must become confirmation/explanation data")
        }
        XCTAssertEqual(plan.nonBypassableItems.map(\.candidate.rawPath), [blockedPath, siblingPath])
        XCTAssertFalse(DeletionSubmissionState.awaitingConfirmation(
            intentID: intent.id,
            planID: plan.id
        ).mayPresentOperationResult)
        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.preflightPaths, [[blockedPath, siblingPath]])
        XCTAssertEqual(snapshot.deniedPaths, [["\(blockedPath)/locked"]])
        XCTAssertEqual(snapshot.moveCalls, 0,
                       "确认前 Safety 拒绝只能进入 plan，不能触发 move 或伪造结果")
    }

    func test_allowedToolPreflightFreezesPipelineApprovedPathsForConfirmation() async {
        let approved = ["/safe/b", "/safe/a"]
        let state = PipelineState(preflightResult: DeletionPreflight(
            allowedPaths: approved,
            rejections: []
        ))
        let pipeline = SpyPipeline(state: state)

        let decision = await ToolDeletionPreflightGate.prepare(
            pipeline: pipeline,
            paths: ["/safe/a", "/safe/b"]
        )

        XCTAssertEqual(decision, .confirmation(paths: approved),
                       "确认页必须消费 pipeline 返回的冻结路径，不能重新读取实时选择")
        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.moveCalls, 0)
    }

    func test_vendorOnlyToolPreflightProducesTypedOverrideInsteadOfGenericRejection() async throws {
        let path = "/Users/test/Library/Android/sdk/system-images"
        let rejection = DeletionPreflight.Rejection(
            path: path,
            reason: "vendorPathRule"
        )
        let state = PipelineState(preflightResult: DeletionPreflight(
            allowedPaths: [],
            rejections: [rejection],
            vendorOverrideEligiblePaths: [path]
        ))

        let decision = await ToolDeletionPreflightGate.prepare(
            pipeline: SpyPipeline(state: state),
            paths: [path]
        )
        guard case .vendorOverride(let request, let rejections) = decision else {
            XCTFail("pure vendor rejection should produce typed override")
            return
        }
        XCTAssertEqual(request.paths, [path])
        XCTAssertEqual(rejections, [rejection])

        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 2)
        let intent = try DeletionIntent(
            origin: .uninstall,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [
                makeCandidate(path: path, verdict: .forbid, rejection: .vendorPathRule)
            ]
        )
        let plan = try DeletionConfirmationPlanner.makePlan(
            intent: intent,
            preflight: DeletionPreflight(
                allowedPaths: [],
                rejections: [rejection],
                vendorOverrideEligiblePaths: [path]
            ),
            currentSnapshotIdentity: identity
        )
        XCTAssertEqual(plan.strictOverrideItems.map(\.candidate.rawPath), [path])
        XCTAssertTrue(plan.nonBypassableItems.isEmpty)
    }

    func test_toolDeletionHandoffRunsOnlyOnceAfterSheetDismissal() {
        var handoff = ToolDeletionHandoff<String>()

        XCTAssertTrue(handoff.schedule("first"))
        XCTAssertFalse(handoff.schedule("second"), "已排队的确认请求不能被后一次点击覆盖")
        XCTAssertTrue(handoff.hasPending)
        XCTAssertEqual(handoff.takeAfterSheetDismissal(), "first")
        XCTAssertFalse(handoff.hasPending)
        XCTAssertNil(handoff.takeAfterSheetDismissal())
    }

    func test_confirmationRejectKeepsInteractionOpenThenAcceptedPlanLatchesExactlyOnce() {
        var handoff = ToolDeletionHandoff<String>()
        var hasSubmitted = false
        var freezeAttempts = 0

        XCTAssertTrue(handoff.schedule("occupied"))
        let rejected = ToolTrashConfirmationSubmissionContract.accepts(
            hasSubmitted: hasSubmitted,
            freezeInCallerHandoff: {
                freezeAttempts += 1
                return handoff.schedule("confirmed")
            }
        )
        XCTAssertFalse(rejected)
        XCTAssertFalse(hasSubmitted,
                       "Caller rejection must not disable the confirmation sheet")
        XCTAssertEqual(freezeAttempts, 1)
        XCTAssertEqual(handoff.takeAfterSheetDismissal(), "occupied")

        let accepted = ToolTrashConfirmationSubmissionContract.accepts(
            hasSubmitted: hasSubmitted,
            freezeInCallerHandoff: {
                freezeAttempts += 1
                return handoff.schedule("confirmed")
            }
        )
        XCTAssertTrue(accepted)
        if accepted { hasSubmitted = true }
        XCTAssertTrue(hasSubmitted)
        XCTAssertEqual(handoff.pending, "confirmed")

        let duplicate = ToolTrashConfirmationSubmissionContract.accepts(
            hasSubmitted: hasSubmitted,
            freezeInCallerHandoff: {
                freezeAttempts += 1
                return handoff.schedule("duplicate")
            }
        )
        XCTAssertFalse(duplicate)
        XCTAssertEqual(freezeAttempts, 2,
                       "After the first accepted plan, a second click must not reach the caller")
        XCTAssertEqual(handoff.takeAfterSheetDismissal(), "confirmed")
    }

    @MainActor
    func test_resultPresentationAndVisibleRemovalDoNotWaitForSlowTerminalModelProjection() async {
        var events: [String] = []
        var visiblePaths = ["/tmp/moved", "/tmp/failed"]
        let gate = DeletionReconciliationGate()

        let operation = Task { @MainActor in
            await DeletionResultAcknowledgementOrdering.acknowledgeThenReconcile(
                makePayload: {
                    XCTAssertEqual(visiblePaths, ["/tmp/moved", "/tmp/failed"])
                    events.append("payload")
                    return 42
                },
                present: { payload in
                    XCTAssertEqual(payload, 42)
                    XCTAssertEqual(visiblePaths, ["/tmp/moved", "/tmp/failed"])
                    events.append("result-presented")
                },
                reconcileModel: {
                    XCTAssertEqual(events, ["payload", "result-presented"])
                    visiblePaths.removeAll { $0 == "/tmp/moved" }
                    events.append("presentation-pruned")
                    // Deterministically hold the wide Tree/model worker. The result must already
                    // be visible and the moved identity must already be gone while authoritative
                    // reconciliation is blocked.
                    await gate.pause()
                    events.append("model-terminal")
                }
            )
        }

        await gate.waitUntilEntered()
        XCTAssertEqual(events, ["payload", "result-presented", "presentation-pruned"])
        XCTAssertEqual(visiblePaths, ["/tmp/failed"])

        await gate.release()
        await operation.value

        XCTAssertEqual(
            events,
            ["payload", "result-presented", "presentation-pruned", "model-terminal"]
        )
        XCTAssertEqual(visiblePaths, ["/tmp/failed"])
    }

    func test_mainListDeletionPresentationRemovesOnlySucceededSubtree() async {
        func row(_ path: String) -> RowItem {
            RowItem(
                id: path,
                url: URL(fileURLWithPath: path),
                title: URL(fileURLWithPath: path).lastPathComponent,
                isDirectory: true,
                bytes: 1,
                logicalBytes: 1,
                fileCount: 1,
                verdict: .safe,
                rejection: .ok
            )
        }
        let snapshot = ScanSnapshot(
            categoryID: "test",
            rows: [row("/tmp/drop"), row("/tmp/drop/child"), row("/tmp/dropbox")],
            totalBytes: 3,
            scannedFileCount: 3,
            isFinished: true,
            elapsed: 1
        )

        let projection = await MainDeletionPresentationExecutor.run(
            snapshot: snapshot,
            succeededPaths: ["/tmp/drop"],
            selection: ["/tmp/drop", "/tmp/dropbox"],
            listDetailPath: "/tmp/drop/child"
        )

        XCTAssertEqual(projection.snapshot.rows.map(\.id), ["/tmp/dropbox"])
        XCTAssertEqual(projection.remainingSelection, ["/tmp/dropbox"])
        XCTAssertTrue(projection.shouldCloseListDetail)
        XCTAssertEqual(projection.snapshot.totalBytes, snapshot.totalBytes,
                       "presentation projection must not pre-empt authoritative accounting")
    }

    func test_mainListDeletionPresentationRejectsStaleSessionOrRevision() {
        let session = UUID()
        let frozen = MainDeletionPresentationSourceIdentity(
            scanSessionID: session,
            sourceRevision: 11,
            sourceCategoryID: "developer",
            selectedCategoryID: "developer",
            interfaceMode: "professional"
        )
        XCTAssertEqual(MainDeletionPresentationCommitPolicy.decision(
            frozen: frozen,
            current: frozen,
            requestRevisionMatches: true
        ), .commit)

        let newerScan = MainDeletionPresentationSourceIdentity(
            scanSessionID: UUID(),
            sourceRevision: 12,
            sourceCategoryID: "developer",
            selectedCategoryID: "developer",
            interfaceMode: "professional"
        )
        XCTAssertEqual(MainDeletionPresentationCommitPolicy.decision(
            frozen: frozen,
            current: newerScan,
            requestRevisionMatches: true
        ), .discard)
        XCTAssertEqual(MainDeletionPresentationCommitPolicy.decision(
            frozen: frozen,
            current: frozen,
            requestRevisionMatches: false
        ), .discard)

        let sameSessionNewRevision = MainDeletionPresentationSourceIdentity(
            scanSessionID: session,
            sourceRevision: 12,
            sourceCategoryID: "developer",
            selectedCategoryID: "developer",
            interfaceMode: "professional"
        )
        XCTAssertEqual(MainDeletionPresentationCommitPolicy.decision(
            frozen: frozen,
            current: sameSessionNewRevision,
            requestRevisionMatches: true
        ), .retryLatestSource)
    }

    @MainActor
    func test_deferredResultIsReleasedWhenSheetDismissesWhileReconciliationIsStillBlocked() async {
        var handoff = ProfessionalDeletePresentationHandoff<Int>()
        let gate = DeletionReconciliationGate()
        var routeWasCalled = false
        var visiblePayload: Int?
        XCTAssertTrue(handoff.beginSheetDismissal())

        let operation = Task { @MainActor in
            await DeletionResultAcknowledgementOrdering.acknowledgeThenReconcile(
                makePayload: { 42 },
                present: { payload in
                    routeWasCalled = true
                    XCTAssertEqual(
                        handoff.routeNextPresentation(payload),
                        .deferUntilSheetDismissal
                    )
                },
                reconcileModel: {
                    await gate.pause()
                }
            )
        }

        await gate.waitUntilEntered()
        XCTAssertTrue(routeWasCalled)
        XCTAssertNil(visiblePayload)
        visiblePayload = handoff.finishSheetDismissal()
        XCTAssertEqual(visiblePayload, 42,
                       "sheet dismissal must release the receipt result without waiting for prune")

        await gate.release()
        await operation.value
    }

    func test_brewTerminalProjectionRemovesOnlySubmittedSuccesses() {
        let moved = URL(fileURLWithPath: "/tmp/brew-moved")
        let failed = URL(fileURLWithPath: "/tmp/brew-failed")
        let terminal = BrewCleanupTerminalProjection.applying(
            succeededPaths: [moved.path],
            to: BrewCleanupTerminalState(
                plan: BrewCleanupPlan(
                    stalePaths: [moved, failed],
                    totalBytes: 30
                ),
                bytesByPath: [moved.path: 10, failed.path: 20]
            )
        )

        XCTAssertEqual(terminal.plan.stalePaths, [failed])
        XCTAssertEqual(terminal.plan.totalBytes, 20)
        XCTAssertEqual(terminal.bytesByPath, [failed.path: 20])
    }

    func test_uninstallTerminalProjectionKeepsFailedCandidateSelected() {
        let moved = UninstallCandidate(
            path: "/tmp/uninstall-moved",
            bytes: 10,
            fileCount: 1,
            matchReason: .bundleID("com.example")
        )
        let failed = UninstallCandidate(
            path: "/tmp/uninstall-failed",
            bytes: 20,
            fileCount: 2,
            matchReason: .bundleID("com.example")
        )
        let terminal = UninstallCandidateTerminalProjection.applying(
            succeededPaths: [moved.path],
            to: UninstallCandidateTerminalState(
                candidates: [moved, failed],
                checked: [moved.path, failed.path]
            )
        )

        XCTAssertEqual(terminal.candidates, [failed])
        XCTAssertEqual(terminal.checked, [failed.path])
    }

    func test_preflightRequestGateRejectsCancelledAndSupersededResults() {
        var gate = ToolDeletionPreflightRequestGate<String>()

        let cancelled = gate.begin(context: "duplicate-group-a")
        XCTAssertTrue(gate.hasCurrentRequest)
        XCTAssertTrue(gate.cancel())
        XCTAssertFalse(gate.finishIfCurrent(cancelled, context: "duplicate-group-a"),
                       "pipeline 不响应 Task.cancel 时，已取消的旧结果仍不能重新弹框")

        let superseded = gate.begin(context: "app-revision-1")
        let current = gate.begin(context: "app-revision-2")
        XCTAssertFalse(gate.finishIfCurrent(superseded, context: "app-revision-1"))
        XCTAssertFalse(gate.finishIfCurrent(current, context: "app-revision-3"),
                       "token 正确但选中 App/revision 已变化时也必须拒绝")
        XCTAssertTrue(gate.finishIfCurrent(current, context: "app-revision-2"))
        XCTAssertFalse(gate.hasCurrentRequest)
    }

    func test_toolTrashExecutionPlanSupportsSkipOrTryAllWithoutChangingSafety() {
        let candidates = [
            RunningAppGuard.Candidate(
                path: "/tmp/running-cache",
                title: "Running Cache",
                bundleIDPrefix: "com.example.editor"
            ),
            RunningAppGuard.Candidate(
                path: "/tmp/offline-cache",
                title: "Offline Cache"
            )
        ]
        let running = [
            RunningAppGuard.RunningApplication(
                bundleID: "com.example.editor",
                localizedName: "Example Editor"
            )
        ]

        let skip = ToolTrashExecutionPlanner.makePlan(
            candidates: candidates,
            resolution: .skipConflictingItems,
            runningApplications: running
        )
        XCTAssertEqual(skip.paths, ["/tmp/offline-cache"])
        XCTAssertEqual(skip.runningAppSkipped, [
            OperationResultPayload.RunningAppSkippedItem(
                path: "/tmp/running-cache",
                itemTitle: "Running Cache",
                appName: "Example Editor"
            )
        ])

        let tryAll = ToolTrashExecutionPlanner.makePlan(
            candidates: candidates,
            resolution: .moveAllToTrash,
            runningApplications: running
        )
        XCTAssertEqual(tryAll.paths, candidates.map(\.path))
        XCTAssertTrue(tryAll.runningAppSkipped.isEmpty)
        // Planner 只投影路径，实际执行仍由各工具的 TrashActionCoordinator / TrashPipeline 完成。
    }

    func test_professionalConfirmationProfileResolverKeepsNormalVendorAndScanDistinct() {
        XCTAssertEqual(
            ToolTrashConfirmationProfile.resolve(
                hasVendorOverride: false,
                hasScanIncompleteOverride: false
            ),
            .normal
        )
        XCTAssertEqual(
            ToolTrashConfirmationProfile.resolve(
                hasVendorOverride: true,
                hasScanIncompleteOverride: false
            ),
            .vendorOverride
        )
        XCTAssertEqual(
            ToolTrashConfirmationProfile.resolve(
                hasVendorOverride: false,
                hasScanIncompleteOverride: true
            ),
            .scanIncompleteOverride
        )
        XCTAssertEqual(
            ToolTrashConfirmationProfile.resolve(
                hasVendorOverride: true,
                hasScanIncompleteOverride: true
            ),
            .scanIncompleteOverride,
            "同时存在两种风险时，标题必须先说明扫描未完整；risk rows 仍会同时展示"
        )
    }

    func test_professionalConfirmationCatalogContainsEnglishAndSimplifiedChineseCopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = root.appendingPathComponent(
            "Packages/AppUI/Sources/AppUI/Resources/Localizable.xcstrings"
        )
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        func localizedValue(_ key: String, locale: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            return try XCTUnwrap(unit["value"] as? String)
        }

        XCTAssertEqual(
            try localizedValue("delete.professional.confirm.title", locale: "en"),
            "Move to Trash?"
        )
        XCTAssertEqual(
            try localizedValue("delete.professional.confirm.title", locale: "zh-Hans"),
            "移到废纸篓？"
        )
        XCTAssertEqual(
            try localizedValue(
                "delete.professional.confirm.message %lld %@",
                locale: "en"
            ),
            "Selected: %1$lld · %2$@ total. Move to Trash?"
        )
        XCTAssertEqual(
            try localizedValue(
                "delete.professional.confirm.message %lld %@",
                locale: "zh-Hans"
            ),
            "已选择 %1$lld 项 · 共 %2$@。要移到废纸篓吗？"
        )
        for key in [
            "delete.vendor_override.action",
            "delete.scan_incomplete_override.action"
        ] {
            XCTAssertEqual(try localizedValue(key, locale: "en"), "Force Move to Trash")
            XCTAssertEqual(try localizedValue(key, locale: "zh-Hans"), "强制移到废纸篓")
        }
    }

    func test_skippingAllVendorProtectedConflictsDowngradesRemainingSafeItemsToNormalMode() throws {
        let vendorPath = "/tmp/vendor-sdk"
        let safePath = "/tmp/safe-cache"
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: vendorPath, reason: "vendorPathRule"),
                .init(path: safePath, reason: "batchContainsForbidden")
            ],
            vendorOverrideEligiblePaths: [vendorPath, safePath]
        )
        let request = try XCTUnwrap(VendorPathOverrideRequest(preflight: preflight))
        let plan = ToolTrashExecutionPlanner.makePlan(
            candidates: [
                .init(path: vendorPath, title: "SDK", bundleIDPrefix: "com.example.ide"),
                .init(path: safePath, title: "Cache")
            ],
            resolution: .skipConflictingItems,
            runningApplications: [
                .init(bundleID: "com.example.ide", localizedName: "Example IDE")
            ],
            vendorOverrideRequest: request
        )

        XCTAssertEqual(plan.paths, [safePath])
        XCTAssertNil(plan.vendorOverrideRequest,
                     "vendor 风险项全部跳过后，剩余普通安全项不应继续携带 override")
    }

    func test_professionalToolsShareTypedPreflightNoticeAndUninstallHasNoDryRunUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Packages/AppUI/Sources/AppUI")
        let brew = try String(contentsOf: sourceRoot.appendingPathComponent("BrewScreen.swift"), encoding: .utf8)
        let duplicate = try String(contentsOf: sourceRoot.appendingPathComponent("DuplicateScreen.swift"), encoding: .utf8)
        let uninstall = try String(contentsOf: sourceRoot.appendingPathComponent("UninstallScreen.swift"), encoding: .utf8)
        let workflow = try String(contentsOf: sourceRoot.appendingPathComponent("WorkflowDetailView.swift"), encoding: .utf8)
        let confirmation = try String(contentsOf: sourceRoot.appendingPathComponent("ToolTrashConfirmationSheet.swift"), encoding: .utf8)
        let main = try String(contentsOf: sourceRoot.appendingPathComponent("MainView.swift"), encoding: .utf8)
        let resultSheet = try String(contentsOf: sourceRoot.appendingPathComponent("OperationResultSheet.swift"), encoding: .utf8)

        XCTAssertTrue(confirmation.contains(
            "let onConfirm: (ToolTrashExecutionPlan) -> Bool"
        ))
        XCTAssertTrue(confirmation.contains(
            "ToolTrashConfirmationSubmissionContract.accepts("
        ))
        // v2026.07.19 regression contract: Main Professional confirmation submits immediately;
        // its active one-shot state, not an onDismiss pending value, guards both entry points.
        XCTAssertGreaterThanOrEqual(
            main.components(separatedBy: "!deleteSubmissionHandoff.blocksNewSubmission").count - 1,
            2
        )
        XCTAssertTrue(main.contains("beginProfessionalSubmission("))
        XCTAssertTrue(main.contains("startProfessionalDeleteSubmission(submission, timing: timing)"))
        XCTAssertTrue(main.contains("onDismiss: finishProfessionalDeleteSheetDismissal"))
        XCTAssertTrue(main.contains("routeProfessionalDeletePresentation"))
        XCTAssertFalse(main.contains(".professional(request:"),
                       "Main Professional submission must never return to onDismiss storage")

        for (source, handoffName) in [
            (brew, "cleanupDeletionHandoff"),
            (uninstall, "uninstallDeletionHandoff")
        ] {
            XCTAssertGreaterThanOrEqual(
                source.components(separatedBy: "!\(handoffName).hasPending").count - 1,
                2,
                "Both preparation entry and async presentation must be mutually exclusive with an accepted pending handoff"
            )
            XCTAssertTrue(source.contains("else { return false }"),
                          "A rejected caller handoff must be reported back to the shared sheet")
        }

        for source in [main, brew, duplicate, uninstall, workflow] {
            XCTAssertTrue(source.contains("DeletionInteractionCoordinator"))
            XCTAssertTrue(source.contains("ToolTrashConfirmationSheet"))
            XCTAssertTrue(source.contains(".deletionPreflightNoticeOverlay("))
            XCTAssertFalse(source.contains("DeletionPreflightNoticeBanner"))
            XCTAssertFalse(source.contains("ProfessionalTrashSubmissionExecutor"),
                           "Professional tools must use the receipt-bearing shared coordinator")
            XCTAssertTrue(source.contains("OperationResultCompletion"),
                          "Professional result presentation must retain an opaque typed completion")
            XCTAssertTrue(source.contains(".deletion("),
                          "Professional Trash results must project only from DeletionCompletedInteraction")
            XCTAssertFalse(source.contains("submissionReceipt:"),
                           "Views must not pair a payload with an optional or independently supplied receipt")
            XCTAssertFalse(source.contains("OperationResultPayload(preflightRejections: rejections)"),
                           "预检拒绝尚未跨过提交边界，不能伪装成执行结果")
        }
        for source in [main, brew, duplicate, uninstall, workflow] {
            XCTAssertFalse(source.contains("delete.vendor_override.title"),
                           "strict copy 只能由共享确认组件解析")
            XCTAssertFalse(source.contains("delete.vendor_override.body %lld"),
                           "strict copy 只能由共享确认组件解析")
            XCTAssertFalse(source.contains("delete.scan_incomplete_override.title"),
                           "scan-only copy 只能由共享确认组件解析")
            XCTAssertTrue(source.contains("totalBytes:"),
                          "Professional 普通确认应由共享组件格式化统一大小摘要")
        }
        XCTAssertFalse(duplicate.contains("uninstall.confirm.title"))
        XCTAssertFalse(duplicate.contains("uninstall.confirm.body"),
                       "Duplicate 不得再复用 Uninstall 确认文案")
        XCTAssertTrue(confirmation.contains("delete.professional.confirm.title"))
        XCTAssertTrue(confirmation.contains("delete.professional.confirm.message %lld %@"))
        XCTAssertFalse(confirmation.contains("dryRun"),
                       "Professional 共享确认组件不得恢复 preview 分支")
        for source in [brew, duplicate, uninstall] {
            XCTAssertTrue(source.contains("ToolDeletionPreflightRequestGate"))
        }
        XCTAssertTrue(confirmation.contains("delete.running_app.choice.move_all"))
        XCTAssertTrue(confirmation.contains("ToolTrashExecutionPlanner.makePlan"))
        XCTAssertTrue(duplicate.contains("cancelDuplicatePreflight"))
        XCTAssertTrue(duplicate.contains("DuplicateConfirmedDeletion"),
                      "Duplicate handoff must retain the frozen request, not only paths")
        XCTAssertTrue(duplicate.contains("bytesByPath"),
                      "A final strict route must preserve the displayed size instead of falling back to Zero KB")
        XCTAssertTrue(duplicate.contains("case .requiresConfirmation"))
        XCTAssertTrue(uninstall.contains("selectedAppRevision"))
        XCTAssertTrue(uninstall.contains("runningBundleIDPrefix: selectedApp.metadata.bundleID"))
        XCTAssertFalse(brew.contains(".confirmationDialog("))
        XCTAssertEqual(uninstall.components(separatedBy: ".sheet(").count - 1, 1,
                       "卸载确认与结果必须共用一个 sheet presenter")
        XCTAssertTrue(uninstall.contains("onDismiss: completeUninstallSheetDismissal"))
        XCTAssertFalse(uninstall.contains("showRealDeleteConfirm"))
        XCTAssertFalse(uninstall.contains("lastResultPayload"))
        XCTAssertFalse(uninstall.contains("DeletionPreviewPolicy"))
        XCTAssertFalse(uninstall.contains("uninstall.button.preview"))
        XCTAssertFalse(uninstall.contains("dryRun: true"))
        XCTAssertFalse(uninstall.contains("dryRun: Bool"))
        XCTAssertFalse(uninstall.contains("TrashActionCoordinator.Request("),
                       "Professional 卸载不得绕过共享真实提交执行器")
        XCTAssertEqual(main.components(separatedBy: "DeleteSheet(").count - 1, 1,
                       "Normal Smart Care is the only detailed DeleteSheet route; Professional uses the compact sheet")
        XCTAssertTrue(main.contains("ToolTrashConfirmationSheet"))
        XCTAssertTrue(main.contains("case .requiresConfirmation"))
        XCTAssertTrue(main.contains(".deletion(completed)"),
                      "Main Professional may present a result only from the shared coordinator completion")
        XCTAssertTrue(main.contains("coordinator.storeRevision =="),
                      "Main Professional confirmation must be invalidated when the scanned store changes")
        XCTAssertFalse(main.contains("deleteSheetVendorOverrideRequest"),
                       "Strict capability belongs to the prepared interaction, not parallel View state")
        XCTAssertFalse(main.contains("onVendorOverride:"),
                       "Vendor escalation must happen before submission, never from Cleanup Result")
        XCTAssertFalse(resultSheet.contains("ToolTrashConfirmationSheet"))
        XCTAssertFalse(resultSheet.contains("onVendorOverride"))
        XCTAssertFalse(resultSheet.contains("onForceDelete"))
        XCTAssertFalse(resultSheet.contains("vendorOverrideCandidates"))
        XCTAssertFalse(resultSheet.contains("submissionReceipt: DeletionSubmissionReceipt?"))
        for source in [main, brew, duplicate, uninstall, workflow] {
            XCTAssertFalse(source.contains("guard let result = await ProfessionalTrashSubmissionExecutor"),
                           "Call sites must switch the typed pre-submit/recycle disposition")
        }
    }

    private func makeCandidate(
        path: String,
        verdict: SafetyVerdict,
        rejection: SafetyRejection
    ) -> DeletionIntentCandidate {
        DeletionIntentCandidate(
            path: path,
            title: URL(fileURLWithPath: path).lastPathComponent,
            isDirectory: true,
            bytes: 1,
            fileCount: 1,
            verdict: verdict,
            rejection: rejection
        )
    }
}
