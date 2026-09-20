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
        var id: String {
            switch self {
            case .review(let review): return "review-\(review.id)"
            case .executing(let id): return "executing-\(id)"
            case .result(let completion): return "result-\(completion.id)"
            }
        }
    }
    @Published var sheet: Sheet?
    @Published var notice: DeletionPreflightNotice?
    @Published private(set) var isBusy = false
    private let scanner: ScanCoordinator
    private let interaction: DeletionInteractionCoordinator
    private var preflightTask: Task<Void, Never>?
    private var owner = UUID()
    private var pending: (Review, ToolTrashExecutionPlan)?

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

    static func candidate(_ row: TreeRow) -> DeletionInteractionCandidateSnapshot? {
        guard !row.isSizePending, row.hasCompleteAccessEvidence else { return nil }
        return DeletionInteractionCandidateSnapshot(
            path: row.path, title: row.title,
            isDirectory: row.isDirectory, bytes: row.bytes, fileCount: row.fileCount,
            titlePresentation: row.titlePresentation)
    }

    func prepare(_ row: TreeRow, snapshotIdentity: DeletionSnapshotIdentity?) {
        guard !isBusy, scanner.canUseCurrentScanResultsForActions,
            snapshotIdentity == currentIdentity,
            let candidate = Self.candidate(row)
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
                guard currentIdentity == identity else {
                    rejectStale(path: row.path)
                    return
                }
                switch decision {
                case .confirmation(let prepared): sheet = .review(Review(prepared: prepared))
                case .blocked(let block): show(block)
                case .cancelled: isBusy = false
                }
            } catch {
                guard owner == token, !Task.isCancelled else { return }
                GSYLog.error(.trash, "storage_analysis intent_failed error=\(error)")
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
            if sheet == nil { isBusy = false }
            return
        }
        pending = nil
        guard review.prepared.plan.intent.snapshotIdentity == currentIdentity else {
            rejectStale(path: review.prepared.paths.first ?? "")
            return
        }
        switch interaction.authorize(prepared: review.prepared, executionPlan: plan) {
        case .blocked(let block): show(block)
        case .cancelled: isBusy = false
        case .authorized(let authorization):
            sheet = .executing(review.id)
            Task {
                let result = await interaction.submit(authorization, accessDeniedPaths: [])
                switch result {
                case .completed(let completion):
                    sheet = .result(.deletion(completion))
                case .blocked(let block): show(block)
                case .requiresConfirmation(let prepared): sheet = .review(Review(prepared: prepared))
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
        self.notice = notice
        let wasPresented = sheet != nil
        sheet = nil
        if !wasPresented { isBusy = false }
    }
}
