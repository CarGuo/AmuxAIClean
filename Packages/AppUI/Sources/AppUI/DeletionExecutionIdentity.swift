import Foundation

/// v2026.10.10: policy/review paths preserve the selected namespace, while the durable
/// Trash ledger coalesces system aliases. Join those domains explicitly and bijectively;
/// never change policy input or authorize an object merely because an alias matches.
struct DeletionExecutionIdentity: Sendable {
    private let selectedByExecutionPath: [String: String]

    init?(selectedPaths: [String]) {
        guard !selectedPaths.isEmpty else { return nil }
        var selected: [String: String] = [:]
        for raw in selectedPaths {
            let policy = DeletionIntentCandidate.pathIdentity(raw)
            let execution = TrashPipeline.normalizePath(raw)
            guard selected.updateValue(policy, forKey: execution) == nil else { return nil }
        }
        selectedByExecutionPath = selected
    }

    static func changedPaths(
        expected: [(path: String, identity: TrashObjectIdentity)],
        reserved: [String: TrashObjectIdentity]
    ) -> [String] {
        // Duplicate execution aliases cannot represent independent reviewed targets.
        guard Self(selectedPaths: expected.map(\.path)) != nil else {
            return Array(Set(expected.map { TrashPipeline.normalizePath($0.path) })).sorted()
        }
        return expected.compactMap { entry in
            let execution = TrashPipeline.normalizePath(entry.path)
            guard let observed = reserved[execution], entry.identity.matches(observed) else {
                return execution
            }
            return nil
        }.sorted()
    }

    private enum ProjectionError: Error {
        case outsideRequest
        case duplicateAlias
        case missingOutcome
    }

    private func selectedPath(_ path: String) throws -> String {
        guard let selected = selectedByExecutionPath[TrashPipeline.normalizePath(path)] else {
            throw ProjectionError.outsideRequest
        }
        return selected
    }

    private func selectedKeys<Value>(_ values: [String: Value]) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for (path, value) in values {
            guard result.updateValue(value, forKey: try selectedPath(path)) == nil else {
                throw ProjectionError.duplicateAlias
            }
        }
        return result
    }

    /// Only validated completions reach this projection, before Undo/model side effects.
    /// Durable journal capabilities keep their original execution paths and exact identities.
    func project(_ completion: TrashRecycleCompletion) throws -> TrashRecycleCompletion {
        guard let outcome = completion.outcome else { throw ProjectionError.missingOutcome }
        let summary: TrashFailureSummary?
        if case .recycleFailed(let failed, let moved, let first)? = outcome.failureSummary {
            summary = .recycleFailed(failedCount: failed, movedCount: moved,
                                     firstPath: try first.map(selectedPath))
        } else {
            summary = outcome.failureSummary
        }
        let projected = try TrashOutcome(
            movedPairs: outcome.movedPairs.map { (try selectedPath($0.originalPath), $0.trashedPath) },
            failedPaths: outcome.failedPaths.map(selectedPath),
            pendingPaths: outcome.pendingPaths.map(selectedPath),
            submissionUnknownPaths: outcome.submissionUnknownPaths.map(selectedPath),
            notSubmittedPaths: outcome.notSubmittedPaths.map(selectedPath),
            notSubmittedReasons: selectedKeys(outcome.notSubmittedReasons),
            safetyRejected: outcome.safetyRejected.map { (try selectedPath($0.path), $0.reason) },
            missingPaths: outcome.missingPaths.map(selectedPath),
            failureReasons: selectedKeys(outcome.failureReasons),
            vendorOverrideEligiblePaths: outcome.vendorOverrideEligiblePaths.map(selectedPath),
            failureSummary: summary
        )
        return try TrashRecycleCompletion(
            attemptedPaths: completion.attemptedPaths.map(selectedPath),
            legacy: (completion.legacy.0, completion.legacy.1, completion.legacy.2,
                     completion.legacy.3.map { (try selectedPath($0.0), $0.1) }),
            outcome: projected,
            undoCommit: completion.undoCommit,
            undoJournalFailedPaths: completion.undoJournalFailedPaths.map(selectedPath),
            undoJournalBlockedAttempts: completion.undoJournalBlockedAttempts
        )
    }
}
