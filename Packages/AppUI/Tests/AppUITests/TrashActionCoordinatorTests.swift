import XCTest
import SafetyKit
@testable import AppUI

@MainActor
final class TrashActionCoordinatorTests: XCTestCase {

    /// Deliberately implements only the legacy surface. Even if its legacy outcome looks like
    /// a completed operation, Professional submission must fail closed instead of guessing.
    private final class LegacyOnlyPipeline: DeletionPipeline, @unchecked Sendable {
        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            DeletionPreflight(allowedPaths: paths, rejections: [])
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {}

        func moveToTrash(
            paths: [String],
            dryRun: Bool
        ) async -> (Int, Int, String?, [(String, String)]) {
            (1, 0, nil, [(paths[0], "/tmp/fake-trash")])
        }
    }

    private final class StubPipeline: DeletionPipeline, @unchecked Sendable {
        var deniedReceived: Set<String> = []
        var normalCalls: [(paths: [String], dryRun: Bool)] = []
        var atomicCalls: [(paths: [String], dryRun: Bool, denied: Set<String>)] = []
        var forceCalls: [(paths: [String], dryRun: Bool)] = []
        var vendorOverrideCalls: [(paths: [String], dryRun: Bool, denied: Set<String>)] = []
        var submissionCalls: [(paths: [String], denied: Set<String>, hasOverride: Bool)] = []
        var submissionRejection: TrashPreSubmitRejection?
        var submissionLegacy: (Int, Int, String?, [(String, String)]) = (0, 0, nil, [])
        var submissionOutcome: TrashOutcome?

        var normalReturn: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
            = ((0, 0, nil, []), nil)
        var forceReturn: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
            = ((0, 0, nil, []), nil)

        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            DeletionPreflight(allowedPaths: paths, rejections: [])
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {
            deniedReceived = paths
        }

        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            normalCalls.append((paths, dryRun))
            return normalReturn.legacy
        }

        func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            normalCalls.append((paths, dryRun))
            return normalReturn
        }

        func moveToTrashReturningOutcome(
            paths: [String],
            dryRun: Bool,
            accessDeniedPaths: Set<String>
        ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            atomicCalls.append((paths, dryRun, accessDeniedPaths))
            return normalReturn
        }

        func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            forceCalls.append((paths, dryRun))
            return forceReturn
        }

        func moveToTrashVendorPathOverride(
            request: VendorPathOverrideRequest,
            dryRun: Bool,
            accessDeniedPaths: Set<String>
        ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            vendorOverrideCalls.append((request.paths, dryRun, accessDeniedPaths))
            return forceReturn
        }

        func submitToTrashReturningDisposition(
            paths: [String],
            accessDeniedPaths: Set<String>,
            vendorOverrideRequest: VendorPathOverrideRequest?
        ) async -> TrashSubmissionDisposition {
            submissionCalls.append((paths, accessDeniedPaths, vendorOverrideRequest != nil))
            if let submissionRejection {
                return .preSubmitRejected(submissionRejection)
            }
            return .recycleCompleted(TrashRecycleCompletion(
                attemptedPaths: paths,
                legacy: submissionLegacy,
                outcome: submissionOutcome
            ))
        }
    }

    private func makeUndoStore() -> (UndoHistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrashActionCoordinatorTests-\(UUID().uuidString).json")
        return (UndoHistoryStore(storeURL: url, maxHistoryCount: 10), url)
    }

    func test_run_部分成功即使err非空也写Undo并暴露成功路径() async throws {
        let pipe = StubPipeline()
        pipe.normalReturn = (
            legacy: (
                1,
                1,
                "partial failure",
                [("/tmp/moved", "/Users/me/.Trash/moved")]
            ),
            outcome: TrashOutcome(
                movedPairs: [("/tmp/moved", "/Users/me/.Trash/moved")],
                failedPaths: ["/tmp/failed"],
                safetyRejected: [],
                missingPaths: []
            )
        )
        let (undo, undoURL) = makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        let result = await action.run(TrashActionCoordinator.Request(
            paths: ["/tmp/moved", "/tmp/failed"],
            dryRun: false,
            source: "clean",
            accessDeniedPaths: ["/tmp/denied"]
        ))

        XCTAssertTrue(pipe.deniedReceived.isEmpty, "统一协调器不应再通过共享 setter 交接 denied")
        XCTAssertEqual(pipe.normalCalls.count, 0)
        XCTAssertEqual(pipe.atomicCalls.count, 1)
        XCTAssertEqual(pipe.atomicCalls.first?.paths, ["/tmp/moved", "/tmp/failed"])
        XCTAssertEqual(pipe.atomicCalls.first?.denied, ["/tmp/denied"])
        XCTAssertFalse(pipe.atomicCalls.first?.dryRun ?? true)
        XCTAssertEqual(result.err, "partial failure")
        XCTAssertEqual(result.succeededPaths, ["/tmp/moved"])
        XCTAssertEqual(undo.history.count, 1,
                       "部分成功时 err 可能非空，但 movedPairs 代表真实进废纸篓的项，必须可恢复")
        XCTAssertEqual(undo.history.first?.source, "clean")
        XCTAssertEqual(undo.history.first?.filePairs.map(\.original), ["/tmp/moved"])
    }

    func test_run_dryRun不写UndoHistory() async throws {
        let pipe = StubPipeline()
        pipe.normalReturn = (
            legacy: (1, 0, nil, [("/tmp/would-move", "/Users/me/.Trash/would-move")]),
            outcome: nil
        )
        let (undo, undoURL) = makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        _ = await action.run(TrashActionCoordinator.Request(
            paths: ["/tmp/would-move"],
            dryRun: true,
            source: "clean",
            accessDeniedPaths: []
        ))

        XCTAssertEqual(undo.history.count, 0,
                       "dryRun 即使 stub 错返 pairs，也不能污染恢复历史")
    }

    func test_run_force模式也走完整安全上下文而不调用绕过入口() async throws {
        let pipe = StubPipeline()
        pipe.normalReturn = (
            legacy: (1, 0, nil, [("/tmp/forced", "/Users/me/.Trash/forced")]),
            outcome: nil
        )
        let (undo, undoURL) = makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        let result = await action.run(TrashActionCoordinator.Request(
            paths: ["/tmp/forced"],
            dryRun: false,
            source: "force",
            accessDeniedPaths: [],
            mode: .force
        ))

        XCTAssertEqual(pipe.atomicCalls.count, 1)
        XCTAssertEqual(pipe.forceCalls.count, 0)
        XCTAssertEqual(result.succeededPaths, ["/tmp/forced"])
        XCTAssertEqual(undo.history.first?.source, "force")
    }

    func test_run_vendorOverride使用typed入口并传递requestScopedDenied() async throws {
        let path = "/tmp/vendor-sdk"
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [.init(path: path, reason: "vendorPathRule")],
            vendorOverrideEligiblePaths: [path]
        )
        let request = try XCTUnwrap(VendorPathOverrideRequest(preflight: preflight))
        let pipe = StubPipeline()
        pipe.forceReturn = (legacy: (0, 1, "blocked", []), outcome: nil)
        let (undo, undoURL) = makeUndoStore()
        defer {
            if FileManager.default.fileExists(atPath: undoURL.path) {
                XCTAssertNoThrow(try FileManager.default.removeItem(at: undoURL))
            }
        }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        _ = await action.run(TrashActionCoordinator.Request(
            paths: request.paths,
            dryRun: false,
            source: "vendor-override",
            accessDeniedPaths: ["/tmp/newly-denied"],
            mode: .vendorPathRuleOverride(request)
        ))

        XCTAssertEqual(pipe.vendorOverrideCalls.count, 1)
        XCTAssertEqual(pipe.vendorOverrideCalls.first?.paths, [path])
        XCTAssertEqual(pipe.vendorOverrideCalls.first?.denied, ["/tmp/newly-denied"])
        XCTAssertTrue(pipe.atomicCalls.isEmpty)
    }

    func test_professionalSubmissionHasNoDryRunCapability() async throws {
        let pipe = StubPipeline()
        let (undo, undoURL) = makeUndoStore()
        defer {
            if FileManager.default.fileExists(atPath: undoURL.path) {
                try? FileManager.default.removeItem(at: undoURL)
            }
        }
        let plan = ToolTrashExecutionPlan(
            paths: ["/tmp/professional-cache"],
            runningAppSkipped: []
        )

        let disposition = await ProfessionalTrashSubmissionExecutor(
            pipeline: pipe,
            undoHistoryStore: undo
        ).submit(
            plan: plan,
            source: "tree",
            accessDeniedPaths: ["/tmp/denied-child"]
        )

        guard case .recycleCompleted = disposition else {
            return XCTFail("A typed recycle completion must remain an execution result")
        }
        XCTAssertEqual(pipe.submissionCalls.count, 1)
        XCTAssertEqual(pipe.submissionCalls.first?.paths, plan.paths)
        XCTAssertEqual(pipe.submissionCalls.first?.denied, ["/tmp/denied-child"])
        XCTAssertEqual(pipe.submissionCalls.first?.hasOverride, false)
        XCTAssertTrue(pipe.atomicCalls.isEmpty,
                      "Professional must use the typed real-submit boundary, not the legacy call")
        XCTAssertTrue(pipe.vendorOverrideCalls.isEmpty)
    }

    func test_confirmedSubmissionKeepsFinalSafetyRejectionOutsideResultBoundary() async throws {
        let path = "/tmp/revalidated-block"
        let pipe = StubPipeline()
        pipe.submissionRejection = .safety(DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: path, reason: SafetyRejection.hardForbidPrefix.rawValue)
            ]
        ))
        // A misleading legacy-shaped payload must not be finalized when the
        // typed boundary says recycle was never attempted.
        pipe.submissionLegacy = (
            1,
            0,
            nil,
            [(path, "/tmp/fake-trash/revalidated-block")]
        )
        let (undo, undoURL) = makeUndoStore()
        defer {
            if FileManager.default.fileExists(atPath: undoURL.path) {
                try? FileManager.default.removeItem(at: undoURL)
            }
        }

        let result = await TrashActionCoordinator(
            pipeline: pipe,
            undoHistoryStore: undo
        ).submitConfirmed(
            paths: [path],
            source: "smart-care",
            accessDeniedPaths: []
        )

        guard case .preSubmitRejected(.safety(let preflight)) = result else {
            return XCTFail("Final safety rejection must not become an operation result")
        }
        XCTAssertEqual(preflight.rejections.first?.path, path)
        XCTAssertEqual(pipe.submissionCalls.count, 1)
        XCTAssertTrue(undo.history.isEmpty)
    }

    func test_professionalStrictSubmissionUsesOnlyTypedVendorOverride() async throws {
        let path = "/tmp/vendor-sdk"
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [.init(path: path, reason: SafetyRejection.vendorPathRule.rawValue)],
            vendorOverrideEligiblePaths: [path]
        )
        let request = try XCTUnwrap(VendorPathOverrideRequest(preflight: preflight))
        let pipe = StubPipeline()
        let (undo, undoURL) = makeUndoStore()
        defer {
            if FileManager.default.fileExists(atPath: undoURL.path) {
                try? FileManager.default.removeItem(at: undoURL)
            }
        }
        let plan = ToolTrashExecutionPlan(
            paths: [path],
            runningAppSkipped: [],
            vendorOverrideRequest: request
        )

        let disposition = await ProfessionalTrashSubmissionExecutor(
            pipeline: pipe,
            undoHistoryStore: undo
        ).submit(
            plan: plan,
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .recycleCompleted = disposition else {
            return XCTFail("A strict typed submission must return a recycle completion")
        }
        XCTAssertEqual(pipe.submissionCalls.count, 1)
        XCTAssertEqual(pipe.submissionCalls.first?.hasOverride, true)
        XCTAssertTrue(pipe.vendorOverrideCalls.isEmpty)
        XCTAssertTrue(pipe.atomicCalls.isEmpty)
        XCTAssertTrue(pipe.forceCalls.isEmpty)
    }

    func test_professionalStrictSubmissionRejectsMismatchedCapability() async throws {
        let protectedPath = "/tmp/vendor-sdk"
        let request = try XCTUnwrap(VendorPathOverrideRequest(preflight: DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: protectedPath, reason: SafetyRejection.vendorPathRule.rawValue)
            ],
            vendorOverrideEligiblePaths: [protectedPath]
        )))
        let pipe = StubPipeline()
        let plan = ToolTrashExecutionPlan(
            paths: ["/tmp/different"],
            runningAppSkipped: [],
            vendorOverrideRequest: request
        )

        let disposition = await ProfessionalTrashSubmissionExecutor(pipeline: pipe).submit(
            plan: plan,
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .blocked(.invalidOverrideIdentity) = disposition else {
            return XCTFail("A mismatched typed capability must be blocked before submission")
        }
        XCTAssertTrue(pipe.submissionCalls.isEmpty)
        XCTAssertTrue(pipe.atomicCalls.isEmpty)
        XCTAssertTrue(pipe.vendorOverrideCalls.isEmpty)
    }

    func test_professionalEmptyPlanNeverCrossesSubmissionBoundary() async {
        let pipe = StubPipeline()
        let disposition = await ProfessionalTrashSubmissionExecutor(pipeline: pipe).submit(
            plan: ToolTrashExecutionPlan(paths: [], runningAppSkipped: []),
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .blocked(.emptySelection) = disposition else {
            return XCTFail("An empty plan must remain a pre-submit block")
        }
        XCTAssertTrue(pipe.submissionCalls.isEmpty)
        XCTAssertTrue(pipe.atomicCalls.isEmpty)
        XCTAssertTrue(pipe.vendorOverrideCalls.isEmpty)
        XCTAssertTrue(pipe.forceCalls.isEmpty)
    }

    func test_professionalFinalVendorRejectionRoutesToStrictConfirmationWithoutResult() async throws {
        let path = "/tmp/vendor-sdk"
        let preflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: path, reason: SafetyRejection.vendorPathRule.rawValue)
            ],
            vendorOverrideEligiblePaths: [path]
        )
        let pipe = StubPipeline()
        pipe.submissionRejection = .safety(preflight)

        let disposition = await ProfessionalTrashSubmissionExecutor(pipeline: pipe).submit(
            plan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: []),
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .requiresStrictConfirmation(let request) = disposition else {
            return XCTFail("Vendor-only final rejection must upgrade confirmation, not show a result")
        }
        XCTAssertEqual(request.paths, [path])
        XCTAssertEqual(pipe.submissionCalls.count, 1)
    }

    func test_professionalFinalHardRejectionRoutesToTypedBlockWithoutResult() async {
        let path = "/Users/test/Library"
        let rejection = DeletionPreflight.Rejection(
            path: path,
            reason: SafetyRejection.rootOrAboveHome.rawValue
        )
        let pipe = StubPipeline()
        pipe.submissionRejection = .safety(DeletionPreflight(
            allowedPaths: [],
            rejections: [rejection]
        ))

        let disposition = await ProfessionalTrashSubmissionExecutor(pipeline: pipe).submit(
            plan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: []),
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .blocked(.finalRevalidation(let rejections)) = disposition else {
            return XCTFail("Hard final rejection must remain a typed pre-submit notice")
        }
        XCTAssertEqual(rejections, [rejection])
    }

    func test_professionalMissingOutcomeStillReturnsRecycleCompletion() async {
        let path = "/tmp/missing-outcome"
        let pipe = StubPipeline()
        pipe.submissionLegacy = (0, 1, "system failure", [])
        pipe.submissionOutcome = nil

        let disposition = await ProfessionalTrashSubmissionExecutor(pipeline: pipe).submit(
            plan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: []),
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .recycleCompleted(let result) = disposition else {
            return XCTFail("Outcome presence must not be used to infer the recycle boundary")
        }
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertNil(result.outcome)
    }

    func test_professionalAttemptWithNoMovedPairsStillReturnsRecycleCompletion() async {
        let path = "/tmp/recycle-failed"
        let pipe = StubPipeline()
        pipe.submissionLegacy = (0, 1, "failed", [])
        pipe.submissionOutcome = TrashOutcome(
            movedPairs: [],
            failedPaths: [path],
            safetyRejected: [],
            missingPaths: []
        )

        let disposition = await ProfessionalTrashSubmissionExecutor(pipeline: pipe).submit(
            plan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: []),
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .recycleCompleted(let result) = disposition else {
            return XCTFail("A completed recycle attempt stays an execution result even on total failure")
        }
        XCTAssertEqual(result.outcome?.failedPaths, [path])
        XCTAssertTrue(result.pairs.isEmpty)
    }

    func test_professionalNeverInfersRecycleBoundaryFromLegacyOutcome() async {
        let path = "/tmp/legacy-only"
        let disposition = await ProfessionalTrashSubmissionExecutor(
            pipeline: LegacyOnlyPipeline()
        ).submit(
            plan: ToolTrashExecutionPlan(paths: [path], runningAppSkipped: []),
            source: "tree",
            accessDeniedPaths: []
        )

        guard case .blocked(.unsupportedPipeline) = disposition else {
            return XCTFail("Legacy results cannot be promoted to a recycle completion by inference")
        }
    }
}
