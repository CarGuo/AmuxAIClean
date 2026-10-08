import Combine
import Foundation
import ScanKit

/// v2026.10.07: one owner for duplicate result mutations. A deletion projection belongs to
/// its original scan session and source revision. Concurrent receipts retry from the latest
/// groups so that neither can resurrect a path removed by the other. Group filtering stays
/// on a cancellable worker; MainActor only validates ownership and publishes the result.
@MainActor
final class DuplicateResultsStore: ObservableObject {
    typealias Pruner = @Sendable ([DuplicateGroup], Set<String>) async -> [DuplicateGroup]

    enum Completion: Equatable, Sendable {
        case completed, cancelled, interrupted
    }

    enum ScanState: Equatable, Sendable {
        case idle, scanning, finished(Completion)
    }

    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var scanState: ScanState = .idle
    private var sessionID = UUID()
    private var sourceRevision: UInt64 = 0
    private let pruner: Pruner

    init(pruner: @escaping Pruner = { groups, paths in
        let worker = Task.detached(priority: .utility) {
            DuplicateHandlingPlan.pruning(groups, movedPaths: paths)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }) {
        self.pruner = pruner
    }

    func beginScan(sessionID: UUID) {
        replaceOwner(sessionID: sessionID, state: .scanning)
    }

    func resetForConfiguration(sessionID: UUID) {
        replaceOwner(sessionID: sessionID, state: .idle)
    }

    private func replaceOwner(sessionID: UUID, state: ScanState) {
        self.sessionID = sessionID
        sourceRevision &+= 1
        scanState = state
        groups = []
    }

    /// v2026.10.08 C4: an empty result used to render the pre-scan invitation forever.
    /// Settlement belongs to the same session as its groups; an old cancelled producer must
    /// neither overwrite a newer scan nor turn a completed empty result back into idle.
    func finishScan(_ completion: Completion, sessionID: UUID) {
        guard self.sessionID == sessionID, scanState == .scanning else { return }
        scanState = .finished(completion)
    }

    func emptyMessage(hasIncompleteEvidence: Bool) -> LocalizedTextDescriptor {
        switch scanState {
        case .idle: return .catalog("duplicate.placeholder.no_results")
        case .scanning: return .catalog("duplicate.placeholder.scanning")
        case .finished(.completed):
            return hasIncompleteEvidence
                ? .catalog("duplicate.placeholder.incomplete_empty")
                : .catalog("duplicate.placeholder.completed_empty")
        case .finished(.cancelled): return .catalog("duplicate.placeholder.cancelled_empty")
        case .finished(.interrupted): return .catalog("duplicate.placeholder.interrupted_empty")
        }
    }

    func replaceGroups(_ groups: [DuplicateGroup], sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        sourceRevision &+= 1
        self.groups = groups
    }

    @discardableResult
    func pruneMovedPaths(_ paths: Set<String>, expectedSessionID: UUID) async -> Bool {
        guard !paths.isEmpty else { return false }
        while sessionID == expectedSessionID, !Task.isCancelled {
            let revision = sourceRevision
            let pruned = await pruner(groups, paths)
            guard sessionID == expectedSessionID, !Task.isCancelled else { return false }
            guard sourceRevision == revision else { continue }
            sourceRevision &+= 1
            groups = pruned
            return true
        }
        return false
    }
}
