import SwiftUI

/// v2026.10.08: a fully successful Trash receipt needs acknowledgement, not another modal.
/// Every entry uses this policy; partial/unknown/failed outcomes retain their existing details.
/// Classification reads only scalar counts, so wide payload mapping stays out of the UI route.
struct OperationCompletionPresentation {
    let successFeedback: OperationSuccessFeedback?
    let details: OperationResultCompletion?

    init(_ completion: OperationResultCompletion) {
        let submission: TrashActionCoordinator.CompletedSubmission
        let runningSkippedCount: Int
        switch completion {
        case .deletion(let interaction):
            submission = interaction.trashSubmission
            runningSkippedCount = interaction.runningAppSkipped.count
        case .trash(let completed, let skipped):
            submission = completed
            runningSkippedCount = skipped.count
        }
        let outcome = submission.outcome
        let status = OperationResultStatusPolicy.status(
            succeededCount: submission.pairs.count,
            failedCount: (outcome?.failedPaths.count ?? submission.skipped)
                + (outcome?.safetyRejected.count ?? 0),
            runningAppSkippedCount: runningSkippedCount,
            pendingCount: outcome?.pendingPaths.count ?? 0,
            submissionUnknownCount: outcome?.submissionUnknownPaths.count ?? 0,
            notSubmittedCount: outcome?.notSubmittedPaths.count ?? 0
        )
        if status == .success, !submission.pairs.isEmpty,
           submission.skipped == 0, submission.err == nil,
           outcome?.missingPaths.isEmpty ?? true {
            successFeedback = OperationSuccessFeedback(
                id: completion.id, movedCount: submission.pairs.count
            )
            details = nil
        } else {
            successFeedback = nil
            details = completion
        }
    }
}

struct OperationSuccessFeedback: Identifiable, Equatable, Sendable {
    let id: UUID
    let movedCount: Int
}

private struct OperationSuccessFeedbackModifier: ViewModifier {
    @Binding var feedback: OperationSuccessFeedback?
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let feedback {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(verbatim: AppLocalization.format(
                            "op.feedback.trashed %lld", locale: locale,
                            arguments: [Int64(feedback.movedCount)]
                        ))
                        .font(.callout)
                        Button { self.feedback = nil } label: {
                            Image(systemName: "xmark").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(Text("op.feedback.dismiss", bundle: .module))
                        .accessibilityLabel(Text("op.feedback.dismiss", bundle: .module))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                    .padding(.trailing, 18)
                    .padding(.bottom, 64)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("delete.success.feedback")
                }
            }
            .task(id: feedback?.id) {
                guard let id = feedback?.id else { return }
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    // View departure or a newer receipt cancels this presentation timer.
                    return
                }
                guard feedback?.id == id else { return }
                feedback = nil
            }
    }
}

extension View {
    func operationSuccessFeedbackOverlay(
        _ feedback: Binding<OperationSuccessFeedback?>
    ) -> some View {
        modifier(OperationSuccessFeedbackModifier(feedback: feedback))
    }
}
