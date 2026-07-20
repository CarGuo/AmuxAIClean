import Foundation
import LogKit

extension Notification.Name {
    /// 所有成功的废纸篓操作统一广播真实 moved original paths；跨功能页面据此
    /// 使扫描快照失效，避免 Brew/卸载/重复文件删除后 Smart Care 仍展示旧结果。
    static let gsyTrashDidMove = Notification.Name("com.amux.ai.clean.trash-did-move")

    /// v2026.07.16：pending ledger 发现“重启后已不存在 / inode 已替换 / claim 前中断”
    /// 只代表旧扫描模型失效，不代表本次确认了删除成功。通知也不是清除持久 tombstone
    /// 的能力；必须走独立通道，禁止复用 `gsyTrashDidMove` 铸造成功历史。
    static let gsyTrashPendingLedgerDidInvalidate = Notification.Name(
        "com.amux.ai.clean.trash-pending-ledger-did-invalidate"
    )
}

/// v2026.07.16：真实副作用前的请求级核算闸门。pipeline 返回值即使来自未来实现或
/// 测试替身，也必须无重叠、无越权地覆盖“已提交结果 + 未提交后续”；否则不得写 Undo、
/// 发模型通知或铸造 receipt。
enum TrashCompletionAccountingValidator {
    static func isValid(
        _ completion: TrashRecycleCompletion,
        requestedPaths: [String]
    ) -> Bool {
        let requested = requestedPaths.map(TrashPipeline.normalizePath)
        let attempted = completion.attemptedPaths.map(TrashPipeline.normalizePath)
        let requestedSet = Set(requested)
        let attemptedSet = Set(attempted)
        guard requestedSet.count == requested.count,
              attemptedSet.count == attempted.count,
              !attempted.isEmpty,
              attemptedSet.isSubset(of: requestedSet) else { return false }

        // v2026.07.16：真实提交边界必须返回结构化 outcome。仅有 legacy tuple 无法证明
        // attempted 中哪些已移动、失败或仍待系统确认；放行会铸造“0/N 成功”receipt。
        guard let outcome = completion.outcome else { return false }

        let movedPaths = outcome.movedPairs.map { TrashPipeline.normalizePath($0.originalPath) }
        let failedPaths = outcome.failedPaths.map(TrashPipeline.normalizePath)
        let pendingPaths = outcome.pendingPaths.map(TrashPipeline.normalizePath)
        let submissionUnknownPaths = outcome.submissionUnknownPaths.map(TrashPipeline.normalizePath)
        let notSubmittedPaths = outcome.notSubmittedPaths.map(TrashPipeline.normalizePath)
        let moved = Set(movedPaths)
        let failed = Set(failedPaths)
        let pending = Set(pendingPaths)
        let submissionUnknown = Set(submissionUnknownPaths)
        let notSubmitted = Set(notSubmittedPaths)

        // finalize/Undo/通知历史上消费 legacy pair，因此在任何副作用前把它锁定为 outcome
        // 的精确投影。不能只校验 outcome 后又信任另一份可能越权或重复的 tuple。
        let legacyPairs = completion.legacy.3.map {
            (
                original: TrashPipeline.normalizePath($0.0),
                trashed: TrashPipeline.normalizePath($0.1)
            )
        }
        let outcomePairs = outcome.movedPairs.map {
            (
                original: TrashPipeline.normalizePath($0.originalPath),
                trashed: TrashPipeline.normalizePath($0.trashedPath)
            )
        }
        let pairsMatch = legacyPairs.count == outcomePairs.count
            && zip(legacyPairs, outcomePairs).allSatisfy { pair in
                pair.0.original == pair.1.original && pair.0.trashed == pair.1.trashed
            }
        let uniqueTrashedDestinations = Set(outcomePairs.map { $0.trashed }).count == outcomePairs.count
        let expectedSkipped = failedPaths.count
            + pendingPaths.count
            + submissionUnknownPaths.count
            + notSubmittedPaths.count

        guard moved.count == movedPaths.count,
              uniqueTrashedDestinations,
              failed.count == failedPaths.count,
              pending.count == pendingPaths.count,
              submissionUnknown.count == submissionUnknownPaths.count,
              notSubmitted.count == notSubmittedPaths.count,
              moved.isDisjoint(with: failed),
              moved.isDisjoint(with: pending),
              moved.isDisjoint(with: submissionUnknown),
              failed.isDisjoint(with: pending),
              failed.isDisjoint(with: submissionUnknown),
              pending.isDisjoint(with: submissionUnknown),
              notSubmitted.isDisjoint(with: attemptedSet),
              moved.union(failed).union(pending).union(submissionUnknown) == attemptedSet,
              notSubmitted == requestedSet.subtracting(attemptedSet),
              Set(outcome.notSubmittedReasons.keys.map(TrashPipeline.normalizePath))
                .isSubset(of: notSubmitted),
              outcome.safetyRejected.isEmpty,
              outcome.missingPaths.isEmpty,
              pairsMatch,
              completion.legacy.0 == outcomePairs.count,
              completion.legacy.1 == expectedSkipped else { return false }
        return true
    }
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

    /// v2026.07.20: Undo persistence is an explicit dependency. A default `.shared` allowed
    /// scripted package tests to write fake moved pairs into the user's production history.
    /// Production call sites pass `.shared`; tests must pass a fixture store.
    init(pipeline: DeletionPipeline,
         undoHistoryStore: UndoHistoryStore) {
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
        source: String,
        undoCommit: TrashUndoCommitCapability? = nil,
        undoJournalFailedPaths: [String] = [],
        undoJournalBlockedAttempts: Set<TrashPendingAttemptIdentity> = []
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
            if let undoCommit {
                let persisted = await undoHistoryStore.addJournalEntriesDurably(
                    source: source,
                    entries: undoCommit.entries
                )
                if persisted {
                    if !(await undoCommit.finishDurablyAfterUndoPersisted(
                        pruningReceiptsIn: undoHistoryStore
                    )) {
                        GSYLog.error(.trash, "Undo durable commit persisted but acknowledgement remains pending entries=\(undoCommit.entries.count)")
                    }
                }
            } else if undoJournalFailedPaths.isEmpty {
                // Compatibility-only pipelines do not own the production durable capability.
                undoHistoryStore.addRecord(
                    source: source,
                    filePairs: projection.undoFilePairs
                )
            }
            if !undoJournalFailedPaths.isEmpty {
                undoHistoryStore.reportCompletionJournalFailure(
                    blockedAttempts: undoJournalBlockedAttempts.isEmpty
                        ? nil
                        : undoJournalBlockedAttempts
                )
            }
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
            source: source,
            undoCommit: completion.undoCommit,
            undoJournalFailedPaths: completion.undoJournalFailedPaths,
            undoJournalBlockedAttempts: completion.undoJournalBlockedAttempts
        )
    }

    /// Shared boundary for every confirmation that means "move now".
    ///
    /// Only `TrashSubmissionDisposition.recycleCompleted` reaches the undo,
    /// model-notification and result projection path.  Callers must keep a
    /// pre-submit rejection inside their confirmation/explanation state
    /// machine; it is not a failed recycle operation.
    // v2026.07.17: bounded source-typed progress is a read-only side channel. It cannot mint a
    // receipt or alter completion accounting; the existing typed disposition remains terminal.
    func submitConfirmed(
        paths: [String],
        source: String,
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest? = nil,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest? = nil,
        reviewIdentity: DeletionSnapshotIdentity? = nil,
        executionVerification: DeletionExecutionVerification? = nil,
        executionProgressObserver: DeletionExecutionProgressObserver? = nil
    ) async -> ConfirmedSubmissionResult {
        let submissionID = UUID()
        let submittedAt = Date()
        switch await pipeline.submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity,
            executionVerification: executionVerification,
            executionProgressObserver: executionProgressObserver
        ) {
        case .preSubmitRejected(let rejection):
            return .preSubmitRejected(rejection)
        case .recycleCompleted(let completion):
            guard TrashCompletionAccountingValidator.isValid(
                completion,
                requestedPaths: paths
            ) else {
                GSYLog.error(.trash, "拒绝不一致的 recycle completion requested=\(paths.count) attempted=\(completion.attemptedPaths.count)")
                return .preSubmitRejected(.unsupportedPipeline)
            }
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
        undoHistoryStore: UndoHistoryStore
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
        case .preSubmitRejected(.invalidDuplicateVerification(let rejections)):
            return .blocked(.finalRevalidation(rejections))
        case .preSubmitRejected(.pendingOperation(let rejection)):
            // v2026.07.16: persistent duplicate/identity gates are pre-submit facts. They
            // remain in the typed explanation route and can never mint a result receipt.
            return .blocked(.finalRevalidation(rejection.preflightRejections))
        case .preSubmitRejected(.emptyRequest):
            return .blocked(.emptySelection)
        case .preSubmitRejected(.unsupportedPipeline):
            return .blocked(.unsupportedPipeline)
        }
    }
}
