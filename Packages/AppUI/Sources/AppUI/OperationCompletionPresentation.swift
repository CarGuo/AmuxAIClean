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

/// v2026.10.08: confirmed success uses one nonmodal, revision-bound presentation across
/// file operations and process tools. Partial and uncertain outcomes keep their details.
protocol ContextualSuccessFeedback: Identifiable, Sendable where ID == UUID {
    var message: LocalizedTextDescriptor { get }
    var accessibilityIdentifier: String { get }
}

struct OperationSuccessFeedback: ContextualSuccessFeedback, Equatable {
    let id: UUID
    let movedCount: Int

    var message: LocalizedTextDescriptor {
        .catalog("op.feedback.trashed %lld", arguments: [.signed(Int64(movedCount))])
    }

    var accessibilityIdentifier: String { "delete.success.feedback" }
}

struct ProcessTerminationSuccessFeedback: ContextualSuccessFeedback, Equatable {
    let id: UUID
    let stoppedCount: Int

    init?(summary: ProcessKillResultSummary) {
        guard summary.confirmedStopped > 0, summary.requestPending == 0,
              summary.notSubmitted == 0, summary.failed == 0 else { return nil }
        id = UUID()
        stoppedCount = summary.confirmedStopped
    }

    var message: LocalizedTextDescriptor {
        .catalog("op.feedback.processes_stopped %lld", arguments: [.signed(Int64(stoppedCount))])
    }

    var accessibilityIdentifier: String { "process.success.feedback" }
}

private struct OperationSuccessFeedbackModifier<Feedback: ContextualSuccessFeedback>: ViewModifier {
    @Binding var feedback: Feedback?
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let feedback {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(verbatim: feedback.message.localized(locale: locale))
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
                    .accessibilityIdentifier(feedback.accessibilityIdentifier)
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
    func operationSuccessFeedbackOverlay<Feedback: ContextualSuccessFeedback>(
        _ feedback: Binding<Feedback?>
    ) -> some View {
        modifier(OperationSuccessFeedbackModifier(feedback: feedback))
    }
}
