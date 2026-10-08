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

    @Published private(set) var groups: [DuplicateGroup] = []
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
        self.sessionID = sessionID
        sourceRevision &+= 1
        groups = []
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
