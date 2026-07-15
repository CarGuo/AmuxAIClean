import Foundation

extension Notification.Name {
    /// 所有成功的废纸篓操作统一广播真实 moved original paths；跨功能页面据此
    /// 使扫描快照失效，避免 Brew/卸载/重复文件删除后 Smart Care 仍展示旧结果。
    static let gsyTrashDidMove = Notification.Name("com.amux.ai.clean.trash-did-move")
}

/// Single execution core for UI trash actions.
///
/// UI surfaces still own confirmation, selection, and presentation, but this
/// type centralizes the actual pipeline call and the invariant that movedPairs
/// are the source of truth for undo/prune/stat updates.
@MainActor
struct TrashActionCoordinator {
    enum Mode {
        case normal
        /// 历史兼容 mode：仍等价于 normal，不能携带任意绕过意图。
        case force
        /// 唯一受支持的 override；请求来自 vendor-only 预检，pipeline 最终仍重验。
        case vendorPathRuleOverride(VendorPathOverrideRequest)
    }

    struct Request {
        let paths: [String]
        let dryRun: Bool
        let source: String
        let accessDeniedPaths: Set<String>
        let mode: Mode

        init(paths: [String],
             dryRun: Bool,
             source: String,
             accessDeniedPaths: Set<String>,
             mode: Mode = .normal) {
            self.paths = paths
            self.dryRun = dryRun
            self.source = source
            self.accessDeniedPaths = accessDeniedPaths
            self.mode = mode
        }
    }

    struct Result: Sendable {
        /// Exact paths that crossed the typed recycle boundary. This is not
        /// derived from moved pairs because every recycle attempt may fail.
        let attemptedPaths: [String]
        let moved: Int
        let skipped: Int
        let err: String?
        let pairs: [(String, String)]
        let outcome: TrashOutcome?
        let succeededPaths: [String]
    }

    /// Opaque proof that one non-preview request crossed the typed recycle boundary.
    /// The initializer is file-private so UI code cannot manufacture a successful
    /// submission from a legacy tuple or a `TrashOutcome` snapshot.
    struct SubmissionReceipt: Identifiable, Sendable, Equatable {
        let id: UUID
        let submittedPaths: [String]
        let submittedAt: Date

        fileprivate init(id: UUID, submittedPaths: [String], submittedAt: Date) {
            self.id = id
            self.submittedPaths = submittedPaths
            self.submittedAt = submittedAt
        }
    }

    struct CompletedSubmission: Identifiable, Sendable {
        let receipt: SubmissionReceipt
        let result: Result

        var id: UUID { receipt.id }
        var attemptedPaths: [String] { result.attemptedPaths }
        var moved: Int { result.moved }
        var skipped: Int { result.skipped }
        var err: String? { result.err }
        var pairs: [(String, String)] { result.pairs }
        var outcome: TrashOutcome? { result.outcome }
        var succeededPaths: [String] { result.succeededPaths }

        fileprivate init(receipt: SubmissionReceipt, result: Result) {
            self.receipt = receipt
            self.result = result
        }
    }

    /// Result of a user-confirmed real deletion request.  The two cases are
    /// deliberately disjoint so a final safety rejection cannot be projected
    /// into an operation result merely because the legacy tuple contains an
    /// error string.
    enum ConfirmedSubmissionResult {
        case preSubmitRejected(TrashPreSubmitRejection)
        case recycleCompleted(CompletedSubmission)
    }

    private struct MovedPairProjection: Sendable {
        let succeededPaths: [String]
        let undoFilePairs: [UndoHistoryStore.Record.FilePair]

        static let empty = MovedPairProjection(succeededPaths: [], undoFilePairs: [])
    }

    let pipeline: DeletionPipeline
    let undoHistoryStore: UndoHistoryStore

    init(pipeline: DeletionPipeline,
         undoHistoryStore: UndoHistoryStore = .shared) {
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
    }

    func run(_ request: Request) async -> Result {
        let raw: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
        switch request.mode {
        case .normal:
            raw = await pipeline.moveToTrashReturningOutcome(
                paths: request.paths,
                dryRun: request.dryRun,
                accessDeniedPaths: request.accessDeniedPaths
            )
        case .force:
            // 历史 mode 只保留调用兼容；安全语义与 normal 完全一致，vendor `.forbid`
            // 永远不会因为 UI 操作模式被绕过。
            raw = await pipeline.moveToTrashReturningOutcome(
                paths: request.paths,
                dryRun: request.dryRun,
                accessDeniedPaths: request.accessDeniedPaths
            )
        case .vendorPathRuleOverride(let overrideRequest):
            raw = await pipeline.moveToTrashVendorPathOverride(
                request: overrideRequest,
                dryRun: request.dryRun,
                accessDeniedPaths: request.accessDeniedPaths
            )
        }

        return await finalize(
            legacy: raw.legacy,
            outcome: raw.outcome,
            attemptedPaths: request.paths,
            dryRun: request.dryRun,
            source: request.source
        )
    }

    /// Turns a completed pipeline call into undo/model side effects. Professional callers may
    /// reach this only through `TrashSubmissionDisposition.recycleCompleted`; pre-submit
    /// rejection therefore has no route to `Result` or an operation-result sheet.
    private func finalize(
        legacy: (Int, Int, String?, [(String, String)]),
        outcome: TrashOutcome?,
        attemptedPaths: [String],
        dryRun: Bool,
        source: String
    ) async -> Result {
        let (moved, skipped, err, pairs) = legacy
        let projection: MovedPairProjection
        if pairs.isEmpty {
            projection = .empty
        } else {
            projection = await Task.detached(priority: .userInitiated) {
                var succeededPaths: [String] = []
                var undoFilePairs: [UndoHistoryStore.Record.FilePair] = []
                succeededPaths.reserveCapacity(pairs.count)
                undoFilePairs.reserveCapacity(pairs.count)
                for pair in pairs {
                    succeededPaths.append(pair.0)
                    undoFilePairs.append(.init(original: pair.0, trashed: pair.1))
                }
                return MovedPairProjection(
                    succeededPaths: succeededPaths,
                    undoFilePairs: undoFilePairs
                )
            }.value
        }
        if !dryRun, !pairs.isEmpty {
            undoHistoryStore.addRecord(
                source: source,
                filePairs: projection.undoFilePairs
            )
            NotificationCenter.default.post(
                name: .gsyTrashDidMove,
                object: nil,
                userInfo: [
                    "paths": projection.succeededPaths,
                    "source": source
                ]
            )
        }
        return Result(
            attemptedPaths: attemptedPaths,
            moved: moved,
            skipped: skipped,
            err: err,
            pairs: pairs,
            outcome: outcome,
            succeededPaths: projection.succeededPaths
        )
    }

    func finalizeRecycleCompletion(
        _ completion: TrashRecycleCompletion,
        source: String
    ) async -> Result {
        await finalize(
            legacy: completion.legacy,
            outcome: completion.outcome,
            attemptedPaths: completion.attemptedPaths,
            dryRun: false,
            source: source
        )
    }

    /// Shared boundary for every confirmation that means "move now".
    ///
    /// Only `TrashSubmissionDisposition.recycleCompleted` reaches the undo,
    /// model-notification and result projection path.  Callers must keep a
    /// pre-submit rejection inside their confirmation/explanation state
    /// machine; it is not a failed recycle operation.
    func submitConfirmed(
        paths: [String],
        source: String,
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest? = nil,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest? = nil
    ) async -> ConfirmedSubmissionResult {
        let submissionID = UUID()
        let submittedAt = Date()
        switch await pipeline.submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest
        ) {
        case .preSubmitRejected(let rejection):
            return .preSubmitRejected(rejection)
        case .recycleCompleted(let completion):
            let result = await finalizeRecycleCompletion(
                completion,
                source: source
            )
            return .recycleCompleted(CompletedSubmission(
                receipt: SubmissionReceipt(
                    id: submissionID,
                    submittedPaths: completion.attemptedPaths,
                    submittedAt: submittedAt
                ),
                result: result
            ))
        }
    }
}

enum ProfessionalTrashSubmissionBlock: Sendable, Equatable {
    case emptySelection
    case invalidOverrideIdentity
    case finalRevalidation([DeletionPreflight.Rejection])
    case unsupportedPipeline
}

/// The UI routing output of a confirmed Professional action. Only
/// `.recycleCompleted` contains an execution result; the other cases remain in the
/// confirmation/explanation state machine.
enum ProfessionalTrashSubmissionDisposition {
    case requiresStrictConfirmation(VendorPathOverrideRequest)
    case blocked(ProfessionalTrashSubmissionBlock)
    case recycleCompleted(TrashActionCoordinator.CompletedSubmission)
}

/// The only execution adapter for a confirmed Professional-mode file request.
///
/// Its API intentionally has no `dryRun` parameter: a simple or strict
/// Professional confirmation either submits one real recycle attempt or is
/// cancelled before this boundary. Vendor override capability remains bound to
/// the typed request frozen by preflight.
@MainActor
struct ProfessionalTrashSubmissionExecutor {
    let pipeline: DeletionPipeline
    let undoHistoryStore: UndoHistoryStore

    init(
        pipeline: DeletionPipeline,
        undoHistoryStore: UndoHistoryStore = .shared
    ) {
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
    }

    func submit(
        plan: ToolTrashExecutionPlan,
        source: String,
        accessDeniedPaths: Set<String>
    ) async -> ProfessionalTrashSubmissionDisposition {
        guard !plan.paths.isEmpty else {
            return .blocked(.emptySelection)
        }
        guard plan.vendorOverrideRequest?.paths == plan.paths
                || plan.vendorOverrideRequest == nil else {
            return .blocked(.invalidOverrideIdentity)
        }
        guard plan.scanIncompleteOverrideRequest?.paths == plan.paths
                || plan.scanIncompleteOverrideRequest == nil else {
            return .blocked(.invalidOverrideIdentity)
        }
        let coordinator = TrashActionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: undoHistoryStore
        )
        let disposition = await coordinator.submitConfirmed(
            paths: plan.paths,
            source: source,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: plan.vendorOverrideRequest,
            scanIncompleteOverrideRequest: plan.scanIncompleteOverrideRequest
        )
        switch disposition {
        case .recycleCompleted(let result):
            return .recycleCompleted(result)

        case .preSubmitRejected(.safety(let preflight)):
            switch ProfessionalDeletionPreflightRouter.route(preflight) {
            case .strictConfirmation(let request):
                return .requiresStrictConfirmation(request)
            case .blockedExplanation(let rejections):
                return .blocked(.finalRevalidation(rejections))
            case .simpleConfirmation:
                // A production pipeline never rejects a can-proceed preflight. Keep an
                // explicit fail-closed route instead of manufacturing an execution result.
                return .blocked(.finalRevalidation(preflight.rejections))
            }

        case .preSubmitRejected(.invalidVendorOverride(let preflight)):
            // A strict capability changed between confirmation and final revalidation. It
            // must not be silently reissued or downgraded to normal submission.
            return .blocked(.finalRevalidation(preflight.rejections))
        case .preSubmitRejected(.invalidScanIncompleteOverride(let rejections)):
            return .blocked(.finalRevalidation(rejections))
        case .preSubmitRejected(.emptyRequest):
            return .blocked(.emptySelection)
        case .preSubmitRejected(.unsupportedPipeline):
            return .blocked(.unsupportedPipeline)
        }
    }
}
