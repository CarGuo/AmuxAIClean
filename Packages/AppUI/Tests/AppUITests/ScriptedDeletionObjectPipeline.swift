import Darwin
import Foundation
@testable import AppUI

/// v2026.09.06: route/accounting spies operate in a synthetic object domain. They explicitly
/// accept only an exact reviewed-object proof before forwarding to their scripted submission.
/// Production identity behavior is exercised separately against real temporary fixtures.
protocol ScriptedDeletionObjectPipeline: DeletionPipeline {}

extension ScriptedDeletionObjectPipeline {
    func prepareReviewedObjects(
        paths: [String], expectedIdentities: [String: TrashObjectIdentity]
    ) async -> ReviewedDeletionObjectPreparation {
        .ready(ReviewedDeletionObjects(identitiesByPath: Dictionary(uniqueKeysWithValues: paths.map { raw in
            let path = DeletionIntentCandidate.pathIdentity(raw)
            let inode = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
            return (path, expectedIdentities[path] ?? TrashObjectIdentity(
                device: 1, inode: inode, fileType: UInt16(S_IFREG)
            ))
        })))
    }

    func submitToTrashReturningDisposition(
        paths: [String], accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?
    ) async -> TrashSubmissionDisposition {
        if let executionVerification {
            guard case .reviewedObjects(let objects) = executionVerification,
                  objects.matchesExactTargets(paths) else { return .preSubmitRejected(.unsupportedPipeline) }
        }
        return await submitToTrashReturningDisposition(
            paths: paths, accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity
        )
    }
}
