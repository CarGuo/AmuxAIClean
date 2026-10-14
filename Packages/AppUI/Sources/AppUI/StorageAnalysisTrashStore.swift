import Foundation
import LogKit
import SafetyKit

/// v2026.09.06: map cells carry allocation facts, not deletion authority. Normal
/// analysis uses the shared typed preflight/review/authorization/receipt flow. The
/// scan identity is checked both after preflight and before the dismissed review
/// hands off execution; a result is published only after a real submission receipt.
@MainActor
final class StorageAnalysisTrashStore: ObservableObject {
    struct Review: Identifiable {
        let prepared: DeletionPreparedInteraction
        var id: UUID { prepared.plan.id }
    }
    enum Sheet: Identifiable {
        case review(Review)
        case executing(UUID)
        case result(OperationResultCompletion)
        case preflightNotice(DeletionPreflightNotice)
        var id: String {
            switch self {
            case .review(let review): return "review-\(review.id)"
            case .executing(let id): return "executing-\(id)"
            case .result(let completion): return "result-\(completion.id)"
            case .preflightNotice(let notice): return "preflight-\(notice.id)"
            }
        }
    }
    @Published var sheet: Sheet?
    var notice: DeletionPreflightNotice? {
        get { if case .preflightNotice(let notice) = sheet { notice } else { nil } }
        set {
            if let newValue { sheet = .preflightNotice(newValue) }
            else if case .preflightNotice = sheet { sheet = nil }
        }
    }
    @Published var successFeedback: OperationSuccessFeedback?
    @Published private(set) var isBusy = false
    private let scanner: ScanCoordinator
    private let interaction: DeletionInteractionCoordinator
    private var preflightTask: Task<Void, Never>?
    private var owner = UUID()
    private var pending: (Review, ToolTrashExecutionPlan)?
    private var isCompletingExecution = false

    init(scanner: ScanCoordinator, pipeline: any DeletionPipeline, undoHistoryStore: UndoHistoryStore) {
        self.scanner = scanner
        interaction = DeletionInteractionCoordinator(pipeline: pipeline, undoHistoryStore: undoHistoryStore)
    }

    var currentIdentity: DeletionSnapshotIdentity {
        DeletionSnapshotIdentity(
            sessionID: scanner.currentScanSessionID,
            revision: scanner.deletionPresentationSourceRevision,
            categoryID: scanner.snapshot.categoryID)
    }

    static func candidate(
        _ row: TreeRow,
        accessEvidence: DeletionAccessEvidence = .complete
    ) -> DeletionInteractionCandidateSnapshot? {
        guard !row.isSizePending,
              row.hasCompleteAccessEvidence,
              case .complete = accessEvidence else { return nil }
        return DeletionInteractionCandidateSnapshot(
            path: row.path, title: row.title,
            isDirectory: row.isDirectory, bytes: row.bytes, fileCount: row.fileCount,
            accessEvidence: accessEvidence,
            titlePresentation: row.titlePresentation)
    }

    private func accessEvidence(for path: String) -> DeletionAccessEvidence {
        guard let issue = scanner.incompleteIssues(overlappingAny: [path]).first else {
            return .complete
        }
        return .incomplete(DeletionIncompleteReason(scanIncompleteReason: issue.reason))
    }

    func prepare(_ row: TreeRow, snapshotIdentity: DeletionSnapshotIdentity?) {
        guard !isBusy, scanner.canUseCurrentScanResultsForActions,
            snapshotIdentity == currentIdentity,
            let candidate = Self.candidate(row, accessEvidence: accessEvidence(for: row.path))
        else { return }
        let identity = currentIdentity
        let token = UUID()
        owner = token
        isBusy = true
        notice = nil
        preflightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let intent = try interaction.makeIntent(
                    origin: .storageAnalysis, mode: .normal,
                    snapshotIdentity: identity, candidates: [candidate])
                let decision = await interaction.prepare(intent: intent, currentSnapshotIdentity: identity)
                guard !Task.isCancelled, owner == token else { return }
                preflightTask = nil
                guard currentIdentity == identity,
                      case .complete = accessEvidence(for: row.path) else {
                    rejectStale(path: row.path)
                    return
                }
                switch decision {
                case .confirmation(let prepared):
                    sheet = .review(Review(prepared: prepared))
                case .blocked(let block): show(block)
                case .cancelled: isBusy = false
                }
            } catch {
                guard owner == token, !Task.isCancelled else { return }
                AmuxLog.error(.trash, "storage_analysis intent_failed error=\(error)")
                rejectStale(path: row.path)
            }
        }
    }

    func accept(_ review: Review, plan: ToolTrashExecutionPlan) -> Bool {
        guard case .review(let visible) = sheet, visible.id == review.id,
            pending == nil
        else { return false }
        guard review.prepared.plan.intent.snapshotIdentity == currentIdentity else {
            rejectStale(path: review.prepared.paths.first ?? "")
            return false
        }
        pending = (review, plan)
        sheet = nil
        return true
    }

    func dismiss() {
        guard let (review, plan) = pending else {
            if sheet == nil, !isCompletingExecution { isBusy = false }
            return
        }
        pending = nil
        guard review.prepared.plan.intent.snapshotIdentity == currentIdentity,
              scanner.incompleteIssues(overlappingAny: review.prepared.paths).isEmpty else {
            rejectStale(path: review.prepared.paths.first ?? "")
            return
        }
        let expectedSessionID = review.prepared.plan.intent.snapshotIdentity.sessionID
        switch interaction.authorize(prepared: review.prepared, executionPlan: plan) {
        case .blocked(let block): show(block)
        case .cancelled: isBusy = false
        case .authorized(let authorization):
            sheet = .executing(review.id)
            isCompletingExecution = true
            Task {
                defer {
                    isCompletingExecution = false
                    if sheet == nil, pending == nil {
                        isBusy = false
                    }
                }
                let result = await interaction.submit(
                    authorization,
                    accessDeniedPaths: []
                )
                switch result {
                case .completed(let completion):
                    let succeededPaths = completion.result.succeededPaths
                    let succeededSet = Set(succeededPaths.map(TrashPipeline.normalizePath))
                    let releasedBytes = authorization.prepared.plan.submittableItems.reduce(Int64(0)) { partial, item in
                        succeededSet.contains(TrashPipeline.normalizePath(item.candidate.rawPath))
                            ? partial + max(0, item.candidate.bytes)
                            : partial
                    }
                    if !succeededPaths.isEmpty, scanner.currentScanSessionID == expectedSessionID {
                        await scanner.acknowledgeSuccessfulDeletionForPresentation(paths: succeededPaths)
                    }
                    let presentation = OperationCompletionPresentation(.deletion(completion))
                    successFeedback = presentation.successFeedback
                    sheet = presentation.details.map(Sheet.result)
                    if !succeededPaths.isEmpty {
                        if scanner.currentScanSessionID == expectedSessionID {
                            await scanner.pruneDeleted(paths: succeededPaths)
                        }
                        Task.detached(priority: .utility) { [releasedBytes, succeededPaths] in
                            await HeuristicRecorder.shared.recordTrashed(paths: succeededPaths)
                            if releasedBytes > 0 {
                                await CleanStatsStore.shared.recordTrashed(
                                    bytesTrashed: releasedBytes,
                                    category: "storage-analysis"
                                )
                            }
                        }
                    }
                case .blocked(let block): show(block)
                case .requiresConfirmation(let prepared):
                    sheet = .review(Review(prepared: prepared))
                }
            }
        }
    }

    func cancelReview() {
        sheet = nil
        // Keep the shared modal slot occupied through the actual dismissal callback.
    }

    func deactivate() {
        owner = UUID()
        preflightTask?.cancel()
        preflightTask = nil
        // Submitted operations remain owned until their typed terminal. Normal
        // navigation is disabled during that interval by the workspace busy state.
        if case .executing = sheet { return }
        if isCompletingExecution { return }
        pending = nil
        sheet = nil
        isBusy = false
    }

    private func show(_ block: DeletionInteractionBlock) {
        presentNotice(DeletionPreflightNotice(rejections: block.rejections))
    }

    private func rejectStale(path: String) {
        presentNotice(
            DeletionPreflightNotice(rejections: [
                .init(path: path, reason: SafetyRejection.preflightCancelled.rawValue)
            ]))
    }

    private func presentNotice(_ notice: DeletionPreflightNotice) {
        // v2026.10.14: progress and failure replace content within the same native sheet.
        self.notice = notice
        isBusy = true
    }
}
