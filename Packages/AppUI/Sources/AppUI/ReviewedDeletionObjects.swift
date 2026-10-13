import Foundation
import LogKit
import SafetyKit

/// v2026.09.06 SR-01: a scan revision identifies UI facts, not the current occupant of a
/// pathname. Freeze no-follow identities before confirmation and retain them through every
/// narrowing/replan, durable reservation and claim-adjacent recycle fence.
public struct ReviewedDeletionObjects: Sendable, Equatable, Hashable {
    let identitiesByPath: [String: TrashObjectIdentity]

    init(identitiesByPath: [String: TrashObjectIdentity]) {
        self.identitiesByPath = identitiesByPath
    }

    func matchesExactTargets(_ paths: [String]) -> Bool {
        let normalized = paths.map(DeletionIntentCandidate.pathIdentity)
        return !normalized.isEmpty && Set(normalized).count == normalized.count
            && Set(normalized) == Set(identitiesByPath.keys)
    }

    func restricting(to paths: [String]) -> Self? {
        let normalized = paths.map(DeletionIntentCandidate.pathIdentity)
        guard !normalized.isEmpty, Set(normalized).count == normalized.count,
              normalized.allSatisfy({ identitiesByPath[$0] != nil }) else { return nil }
        let selected = Set(normalized)
        return Self(identitiesByPath: identitiesByPath.filter { selected.contains($0.key) })
    }

    func changedPaths(comparedTo current: [String: TrashObjectIdentity]) -> [String] {
        DeletionExecutionIdentity.changedPaths(
            expected: identitiesByPath.map { (path: $0.key, identity: $0.value) }, reserved: current
        )
    }

    static func capture(
        paths: [String], expectedIdentities: [String: TrashObjectIdentity]
    ) async -> ReviewedDeletionObjectPreparation {
        let worker = Task.detached(priority: .userInitiated) {
            var identities: [String: TrashObjectIdentity] = [:]
            var rejections: [DeletionPreflight.Rejection] = []
            for rawPath in paths {
                guard !Task.isCancelled else {
                    return ReviewedDeletionObjectPreparation.blocked(paths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    })
                }
                let path = DeletionIntentCandidate.pathIdentity(rawPath)
                switch TrashObjectIdentity.probe(path: path) {
                case .present(let identity):
                    if let expected = expectedIdentities[path], !expected.matches(identity) {
                        rejections.append(.init(
                            path: rawPath, reason: TrashPendingOperationRejection.Reason.identityChanged.rawValue))
                    } else {
                        identities[path] = identity
                    }
                case .missing:
                    rejections.append(.init(
                        path: rawPath, reason: TrashPendingOperationRejection.Reason.targetMissing.rawValue))
                case .unavailable(let code):
                    AmuxLog.warning(.trash, "review_identity_unavailable path=\(rawPath) errno=\(code)")
                    rejections.append(.init(
                        path: rawPath, reason: TrashPendingOperationRejection.Reason.freshReviewRequired.rawValue))
                }
            }
            guard rejections.isEmpty else { return .blocked(rejections) }
            let reviewed = Self(identitiesByPath: identities)
            guard reviewed.matchesExactTargets(paths),
                  Set(expectedIdentities.keys).isSubset(of: Set(identities.keys)) else {
                return .blocked(paths.map {
                    .init(path: $0, reason: TrashPendingOperationRejection.Reason.freshReviewRequired.rawValue)
                })
            }
            return .ready(reviewed)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }
}

public enum ReviewedDeletionObjectPreparation: Sendable, Equatable {
    case ready(ReviewedDeletionObjects)
    case blocked([DeletionPreflight.Rejection])
}

extension DeletionPipeline {
    public func prepareReviewedObjects(
        paths: [String], expectedIdentities: [String: TrashObjectIdentity]
    ) async -> ReviewedDeletionObjectPreparation {
        await ReviewedDeletionObjects.capture(paths: paths, expectedIdentities: expectedIdentities)
    }
}
