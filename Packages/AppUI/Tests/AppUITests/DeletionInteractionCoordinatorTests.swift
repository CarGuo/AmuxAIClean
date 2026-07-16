import Foundation
import ScanKit
import SafetyKit
import XCTest
@testable import AppUI

final class DeletionInteractionCoordinatorTests: XCTestCase {
    private actor PipelineState {
        private var preflights: [DeletionPreflight]
        private var submissions: [TrashSubmissionDisposition]
        private(set) var preflightCalls: [[String]] = []
        private(set) var submissionCalls: [[String]] = []
        private(set) var submittedReviewIdentities: [DeletionSnapshotIdentity?] = []
        private(set) var legacyMoveCalls = 0

        init(
            preflights: [DeletionPreflight],
            submissions: [TrashSubmissionDisposition] = []
        ) {
            self.preflights = preflights
            self.submissions = submissions
        }

        func nextPreflight(paths: [String]) -> DeletionPreflight {
            preflightCalls.append(paths)
            guard !preflights.isEmpty else {
                return DeletionPreflight(allowedPaths: paths, rejections: [])
            }
            return preflights.removeFirst()
        }

        func nextSubmission(paths: [String]) -> TrashSubmissionDisposition {
            submissionCalls.append(paths)
            submittedReviewIdentities.append(nil)
            guard !submissions.isEmpty else {
                return .preSubmitRejected(.unsupportedPipeline)
            }
            return submissions.removeFirst()
        }

        func nextSubmission(
            paths: [String],
            reviewIdentity: DeletionSnapshotIdentity?
        ) -> TrashSubmissionDisposition {
            submissionCalls.append(paths)
            submittedReviewIdentities.append(reviewIdentity)
            guard !submissions.isEmpty else {
                return .preSubmitRejected(.unsupportedPipeline)
            }
            return submissions.removeFirst()
        }

        func recordLegacyMove() { legacyMoveCalls += 1 }

        func snapshot() -> (preflight: Int, submission: Int, legacy: Int) {
            (preflightCalls.count, submissionCalls.count, legacyMoveCalls)
        }

        func reviewIdentitySnapshot() -> [DeletionSnapshotIdentity?] {
            submittedReviewIdentities
        }
    }

    private struct SpyPipeline: DeletionPipeline {
        let state: PipelineState

        func preflight(
            paths: [String],
            accessDeniedPaths: Set<String>
        ) async -> DeletionPreflight {
            await state.nextPreflight(paths: paths)
        }

        func moveToTrash(
            paths: [String],
            dryRun: Bool
        ) async -> (Int, Int, String?, [(String, String)]) {
            await state.recordLegacyMove()
            return (0, paths.count, "legacy path must not be used", [])
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {}

        func submitToTrashReturningDisposition(
            paths: [String],
            accessDeniedPaths: Set<String>,
            vendorOverrideRequest: VendorPathOverrideRequest?
        ) async -> TrashSubmissionDisposition {
            await state.nextSubmission(paths: paths)
        }

        func submitToTrashReturningDisposition(
            paths: [String],
            accessDeniedPaths: Set<String>,
            vendorOverrideRequest: VendorPathOverrideRequest?,
            scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
            reviewIdentity: DeletionSnapshotIdentity?
        ) async -> TrashSubmissionDisposition {
            await state.nextSubmission(
                paths: paths,
                reviewIdentity: reviewIdentity
            )
        }

        func submitToTrashReturningDisposition(
            paths: [String],
            accessDeniedPaths: Set<String>,
            vendorOverrideRequest: VendorPathOverrideRequest?,
            scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
        ) async -> TrashSubmissionDisposition {
            await state.nextSubmission(paths: paths)
        }
    }

    @MainActor
    func test_prepareAllowedIntentProducesNormalPlanWithoutSubmission() async throws {
        let path = "/Users/test/Library/Caches/plain"
        let state = PipelineState(preflights: [
            DeletionPreflight(allowedPaths: [path], rejections: [])
        ])
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 1)
        let intent = try coordinator.makeIntent(
            origin: .brew,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(path)]
        )

        let decision = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        )

        guard case .confirmation(let prepared) = decision else {
            return XCTFail("Allowed preflight must produce confirmation")
        }
        XCTAssertEqual(prepared.plan.normalItems.map(\.candidate.rawPath), [path])
        XCTAssertTrue(prepared.plan.strictOverrideItems.isEmpty)
        XCTAssertNil(prepared.vendorOverrideRequest)
        XCTAssertNil(prepared.scanIncompleteOverrideRequest)
        let calls = await state.snapshot()
        XCTAssertEqual(calls.preflight, 1)
        XCTAssertEqual(calls.submission, 0)
        XCTAssertEqual(calls.legacy, 0)
    }

    @MainActor
    func test_prepareHardForbidProducesBlockAndNeverSubmission() async throws {
        let path = "/Users/test/Library"
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: path, reason: SafetyRejection.rootOrAboveHome.rawValue)
            ]
        )
        let state = PipelineState(preflights: [preflight])
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 1)
        let intent = try coordinator.makeIntent(
            origin: .uninstall,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(path)]
        )

        guard case .blocked(let block) = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        ) else {
            return XCTFail("Hard forbid must remain a pre-submit explanation")
        }
        XCTAssertEqual(block.rejections, preflight.rejections)
        let calls = await state.snapshot()
        XCTAssertEqual(calls.submission, 0)
        XCTAssertEqual(calls.legacy, 0)
    }

    @MainActor
    func test_confirmedSubmissionMintsReceiptOnlyAfterTypedRecycleCompletion() async throws {
        let path = "/Users/test/Library/Caches/plain"
        let outcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [path],
            safetyRejected: [],
            missingPaths: [],
            failureReasons: [path: "simulated recycle failure"]
        )
        let state = PipelineState(
            preflights: [DeletionPreflight(allowedPaths: [path], rejections: [])],
            submissions: [
                .recycleCompleted(TrashRecycleCompletion(
                    attemptedPaths: [path],
                    legacy: (0, 1, "simulated recycle failure", []),
                    outcome: outcome
                ))
            ]
        )
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 2)
        let intent = try coordinator.makeIntent(
            origin: .duplicate,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(path)]
        )
        guard case .confirmation(let prepared) = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        ) else { return XCTFail("Expected confirmation") }
        guard case .authorized(let authorization) = coordinator.authorize(
            prepared: prepared,
            executionPlan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: [])
        ) else { return XCTFail("Expected typed authorization") }

        guard case .completed(let completed) = await coordinator.submit(
            authorization,
            accessDeniedPaths: []
        ) else { return XCTFail("Typed recycle completion must produce a receipt") }

        XCTAssertEqual(completed.receipt.authorizationID, authorization.authorization.id)
        XCTAssertEqual(completed.receipt.intentID, intent.id)
        XCTAssertEqual(completed.receipt.submittedPaths, [path])
        XCTAssertEqual(completed.receipt.id, completed.trashSubmission.receipt.id)
        XCTAssertTrue(completed.submissionState.mayPresentOperationResult)
        XCTAssertEqual(completed.result.outcome, outcome)
        let payload = OperationResultCompletion.deletion(completed).resultPayload
        XCTAssertEqual(payload.id, completed.receipt.id)
        XCTAssertEqual(payload.failedPaths, [path])
        XCTAssertEqual(payload.failureReasons[path], "simulated recycle failure")
        let calls = await state.snapshot()
        XCTAssertEqual(calls.submission, 1)
        XCTAssertEqual(calls.legacy, 0)
        let reviewIdentities = await state.reviewIdentitySnapshot()
        XCTAssertEqual(
            reviewIdentities,
            [identity],
            "v2026.07.16: submit must carry the exact authorized review snapshot"
        )
    }

    @MainActor
    func test_finalVendorRiskReturnsStrictConfirmationWithoutReceiptOrResult() async throws {
        let path = "/Users/test/Library/Android/sdk/system-images"
        let vendorPreflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: path, reason: SafetyRejection.vendorPathRule.rawValue)
            ],
            vendorOverrideEligiblePaths: [path]
        )
        let state = PipelineState(
            preflights: [DeletionPreflight(allowedPaths: [path], rejections: [])],
            submissions: [.preSubmitRejected(.safety(vendorPreflight))]
        )
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 3)
        let intent = try coordinator.makeIntent(
            origin: .workflowFilesystem,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(path)]
        )
        guard case .confirmation(let prepared) = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        ) else { return XCTFail("Expected initial simple confirmation") }
        guard case .authorized(let authorization) = coordinator.authorize(
            prepared: prepared,
            executionPlan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: [])
        ) else { return XCTFail("Expected authorization") }

        guard case .requiresConfirmation(let strict) = await coordinator.submit(
            authorization,
            accessDeniedPaths: []
        ) else {
            return XCTFail("New vendor risk must re-enter strict confirmation")
        }
        XCTAssertEqual(strict.plan.strictOverrideItems.map(\.candidate.rawPath), [path])
        XCTAssertNotNil(strict.vendorOverrideRequest)
        let calls = await state.snapshot()
        XCTAssertEqual(calls.submission, 1)
        XCTAssertEqual(calls.legacy, 0)
    }

    @MainActor
    func test_strictAuthorizationValidatesTokenInsideCoordinator() async throws {
        let path = "/Users/test/Library/Android/sdk/system-images"
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: path, reason: SafetyRejection.vendorPathRule.rawValue)
            ],
            vendorOverrideEligiblePaths: [path]
        )
        let state = PipelineState(preflights: [preflight])
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 4)
        let intent = try coordinator.makeIntent(
            origin: .brew,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(path)]
        )
        guard case .confirmation(let prepared) = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        ) else { return XCTFail("Expected strict confirmation") }

        let invalid = ToolTrashExecutionPlan(
            paths: [path],
            runningAppSkipped: [],
            vendorOverrideRequest: prepared.vendorOverrideRequest,
            strictConfirmationToken: "wrong"
        )
        guard case .blocked = coordinator.authorize(
            prepared: prepared,
            executionPlan: invalid
        ) else { return XCTFail("Wrong strict token must not mint authorization") }

        // v2026.07.16: mirror the production protocol token, which is deliberately resolved
        // from the invariant English catalog instead of the process/UI locale.
        let expectedToken = AppLocalization.string(
            "delete.vendor_override.token",
            locale: Locale(identifier: "en")
        )
        let valid = ToolTrashExecutionPlan(
            paths: [path],
            runningAppSkipped: [],
            vendorOverrideRequest: prepared.vendorOverrideRequest,
            strictConfirmationToken: expectedToken
        )
        guard case .authorized(let authorized) = coordinator.authorize(
            prepared: prepared,
            executionPlan: valid
        ) else { return XCTFail("Expected valid strict authorization") }
        XCTAssertEqual(authorized.authorization.overrideBindings.map(\.path), [path])
    }

    @MainActor
    func test_recycleCompletionWithDifferentAttemptedPathsCannotMintReceipt() async throws {
        let path = "/Users/test/Library/Caches/authorized"
        let different = "/Users/test/Library/Caches/different"
        let state = PipelineState(
            preflights: [DeletionPreflight(allowedPaths: [path], rejections: [])],
            submissions: [
                .recycleCompleted(TrashRecycleCompletion(
                    attemptedPaths: [different],
                    legacy: (0, 1, "simulated", []),
                    outcome: nil
                ))
            ]
        )
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 5)
        let intent = try coordinator.makeIntent(
            origin: .brew,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(path)]
        )
        guard case .confirmation(let prepared) = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        ), case .authorized(let authorized) = coordinator.authorize(
            prepared: prepared,
            executionPlan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: [])
        ) else { return XCTFail("Expected authorization") }

        guard case .blocked = await coordinator.submit(authorized, accessDeniedPaths: []) else {
            return XCTFail("A completion for different paths must never mint a receipt")
        }
    }

    @MainActor
    func test_pendingRecycleAccountsForUnsubmittedAuthorizationWithoutFalseFailure() async throws {
        let pending = "/Users/test/Library/Caches/pending"
        let notSubmitted = "/Users/test/Library/Caches/not-submitted"
        let outcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [],
            pendingPaths: [pending],
            notSubmittedPaths: [notSubmitted],
            safetyRejected: [],
            missingPaths: [],
            failureSummary: .recyclePending(
                pendingCount: 1,
                notSubmittedCount: 1,
                movedCount: 0
            )
        )
        let state = PipelineState(
            preflights: [DeletionPreflight(
                allowedPaths: [pending, notSubmitted],
                rejections: []
            )],
            submissions: [
                .recycleCompleted(TrashRecycleCompletion(
                    attemptedPaths: [pending],
                    legacy: (0, 2, "recycle pending", []),
                    outcome: outcome
                ))
            ]
        )
        let coordinator = makeCoordinator(state: state)
        let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 51)
        let intent = try coordinator.makeIntent(
            origin: .brew,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [candidate(pending), candidate(notSubmitted)]
        )
        guard case .confirmation(let prepared) = await coordinator.prepare(
            intent: intent,
            currentSnapshotIdentity: identity
        ), case .authorized(let authorized) = coordinator.authorize(
            prepared: prepared,
            executionPlan: ToolTrashExecutionPlan(
                paths: [pending, notSubmitted],
                runningAppSkipped: []
            )
        ) else { return XCTFail("Expected authorization") }

        guard case .completed(let completed) = await coordinator.submit(
            authorized,
            accessDeniedPaths: []
        ) else { return XCTFail("Accounted pending state must reach result presentation") }

        XCTAssertEqual(completed.receipt.submittedPaths, [pending])
        let payload = OperationResultCompletion.deletion(completed).resultPayload
        XCTAssertEqual(payload.status, .pending)
        XCTAssertEqual(payload.pendingPaths, [pending])
        XCTAssertEqual(payload.notSubmittedPaths, [notSubmitted])
        XCTAssertTrue(payload.failedPaths.isEmpty)
    }

    @MainActor
    func test_scanIncompleteCapabilitySurvivesPreparationAuthorizationAndSubmit() async throws {
        let path = "/Users/test/Library/Containers/example"
        let sessionID = UUID()
        let identity = DeletionSnapshotIdentity(sessionID: sessionID, revision: 6)
        let state = PipelineState(
            preflights: [],
            submissions: [
                .recycleCompleted(TrashRecycleCompletion(
                    attemptedPaths: [path],
                    legacy: (0, 1, "simulated", []),
                    // v2026.07.16: a real typed submission must return an exact
                    // completion partition. This test is about preserving the
                    // scan-incomplete capability through submit, not about
                    // bypassing the fail-closed outcome accounting gate.
                    outcome: TrashOutcome(
                        movedPairs: [],
                        failedPaths: [path],
                        safetyRejected: [],
                        missingPaths: []
                    )
                ))
            ]
        )
        let coordinator = makeCoordinator(state: state)
        let intent = try coordinator.makeIntent(
            origin: .workflowFilesystem,
            mode: .professional,
            snapshotIdentity: identity,
            candidates: [DeletionInteractionCandidateSnapshot(
                path: path,
                title: "example",
                isDirectory: true,
                bytes: 1,
                fileCount: 1,
                accessEvidence: .incomplete(.permissionDenied)
            )]
        )
        let request = ScanIncompleteOverrideRequest(
            scanSessionID: sessionID,
            entries: [.init(
                candidateID: intent.candidates[0].id,
                path: path,
                title: "example",
                isDirectory: true,
                bytes: 1,
                fileCount: 1,
                snapshotVerdict: .safe,
                snapshotRejectionRawValue: SafetyRejection.ok.rawValue,
                identity: .init(device: 1, inode: 2, fileType: 4, resolvedPath: path),
                incompleteIssues: [.init(path: path, reason: .permissionDenied)]
            )]
        )
        guard case .confirmation(let prepared) = coordinator.prepareRevalidatedScanIncomplete(
            intent: intent,
            currentSnapshotIdentity: identity,
            preparation: .strictConfirmation(request: request, vendorOverrideRequest: nil)
        ) else { return XCTFail("Expected strict scan-incomplete confirmation") }

        let token = AppLocalization.string(
            "delete.vendor_override.token",
            locale: Locale(identifier: "en")
        )
        guard case .authorized(let authorized) = coordinator.authorize(
            prepared: prepared,
            executionPlan: ToolTrashExecutionPlan(
                paths: [path],
                runningAppSkipped: [],
                scanIncompleteOverrideRequest: request,
                strictConfirmationToken: token
            )
        ) else { return XCTFail("Expected scan-incomplete authorization") }
        XCTAssertEqual(authorized.scanIncompleteOverrideRequest, request)

        guard case .completed(let completed) = await coordinator.submit(
            authorized,
            accessDeniedPaths: [path]
        ) else { return XCTFail("Typed scan capability must reach submit") }
        XCTAssertEqual(completed.receipt.submittedPaths, [path])
    }

    @MainActor
    private func makeCoordinator(state: PipelineState) -> DeletionInteractionCoordinator {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionInteractionCoordinatorTests-\(UUID().uuidString).json")
        return DeletionInteractionCoordinator(
            pipeline: SpyPipeline(state: state),
            undoHistoryStore: UndoHistoryStore(storeURL: storeURL)
        )
    }

    private func candidate(_ path: String) -> DeletionInteractionCandidateSnapshot {
        DeletionInteractionCandidateSnapshot(
            path: path,
            title: URL(fileURLWithPath: path).lastPathComponent,
            isDirectory: true,
            bytes: 1,
            fileCount: 1
        )
    }
}
