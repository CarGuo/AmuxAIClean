import SafetyKit
import XCTest
@testable import AppUI

final class DeletionTargetRevalidationPolicyTests: XCTestCase {
    func test_completeSafeTargetUsesOrdinaryConfirmation() {
        let candidate = makeCandidate()
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(for: candidate),
            mode: .professional
        )

        XCTAssertEqual(decision, .ordinaryAllow)
    }

    func test_descendantCannotEnumerateDoesNotMeanSelectedParentCannotMove() {
        let candidate = makeCandidate(
            accessEvidence: .incomplete(.incompleteEnumeration)
        )
        let issue = DeletionScopedIncompleteEvidence(
            reason: .incompleteEnumeration,
            scope: .descendant
        )
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(
                for: candidate,
                scanEvidence: .incomplete([issue]),
                moveAttempt: .eligibleForAttempt
            ),
            mode: .professional
        )

        XCTAssertEqual(
            decision,
            .strictAttempt(DeletionTargetStrictAttempt(
                reasons: [.scanIncomplete(issue)]
            ))
        )
    }

    func test_targetMoveDenialsStayTypedInsteadOfBecomingGenericFullDiskAccess() {
        let candidate = makeCandidate(
            accessEvidence: .incomplete(.permissionDenied)
        )
        let issue = DeletionScopedIncompleteEvidence(
            reason: .permissionDenied,
            scope: .selectedTarget
        )
        let denials: [DeletionTargetMoveDenial] = [
            .posixPermissionDenied,
            .tccDenied,
            .aclDenied,
            .immutable,
            .readOnlyVolume,
            .unclassifiedAccessFailure
        ]

        for denial in denials {
            let decision = DeletionTargetRevalidationPolicy.decision(
                for: candidate,
                evidence: makeEvidence(
                    for: candidate,
                    scanEvidence: .incomplete([issue]),
                    moveAttempt: .denied(denial)
                ),
                mode: .professional
            )
            XCTAssertEqual(decision, .prohibited(.moveDenied(denial)))
        }
    }

    func test_nonBypassableCurrentSafetyBoundariesAlwaysWin() {
        let candidate = makeCandidate()
        let boundaries: [SafetyRejection] = [
            .relativePath,
            .dotDotInPath,
            .rootOrAboveHome,
            .outsideUserDeletionScope,
            .preflightCancelled,
            .hardForbidPrefix,
            .userDocumentsRoot,
            .systemVolume,
            .insideAppBundle,
            .sensitiveCredential,
            .userWhitelisted,
            .batchContainsForbidden,
            .bundleSystemCritical,
            .bundleDataProtected
        ]

        for boundary in boundaries {
            let decision = DeletionTargetRevalidationPolicy.decision(
                for: candidate,
                evidence: makeEvidence(
                    for: candidate,
                    currentVerdict: .forbid,
                    currentRejection: boundary
                ),
                mode: .professional
            )
            XCTAssertEqual(decision, .prohibited(.safety(boundary)))
        }
    }

    func test_snapshotHardBoundaryCannotBeDowngradedByCurrentSafeResult() {
        let candidate = makeCandidate(
            verdict: .forbid,
            rejection: .rootOrAboveHome
        )
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(
                for: candidate,
                currentVerdict: .safe,
                currentRejection: .ok
            ),
            mode: .professional
        )

        XCTAssertEqual(decision, .prohibited(.safety(.rootOrAboveHome)))
    }

    func test_inconsistentSafetyPairFailsClosed() {
        let candidate = makeCandidate()
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(
                for: candidate,
                currentVerdict: .safe,
                currentRejection: .hardForbidPrefix
            ),
            mode: .professional
        )

        XCTAssertEqual(
            decision,
            .prohibited(.inconsistentSafetyEvidence(.safe, .hardForbidPrefix))
        )
    }

    func test_aggregatedAccessDeniedMustBeResolvedBeforeStrictAttempt() {
        let candidate = makeCandidate(
            verdict: .forbid,
            rejection: .accessDenied,
            accessEvidence: .incomplete(.unspecified)
        )
        let unresolved = DeletionScopedIncompleteEvidence(
            reason: .unspecified,
            scope: .selectedTarget
        )
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(
                for: candidate,
                currentVerdict: .forbid,
                currentRejection: .accessDenied,
                scanEvidence: .incomplete([unresolved])
            ),
            mode: .professional
        )

        XCTAssertEqual(decision, .prohibited(.unresolvedIncompleteReason))
    }

    func test_incompleteSnapshotCannotBeErasedByShallowCompleteRevalidation() {
        let candidate = makeCandidate(
            accessEvidence: .incomplete(.incompleteEnumeration)
        )
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(for: candidate, scanEvidence: .complete),
            mode: .professional
        )

        XCTAssertEqual(
            decision,
            .prohibited(.incompleteEvidenceNotCarriedForward)
        )
    }

    func test_vendorAndDescendantIncompleteRisksAreBothRetained() {
        let candidate = makeCandidate(
            verdict: .forbid,
            rejection: .vendorPathRule,
            accessEvidence: .incomplete(.incompleteEnumeration)
        )
        let issue = DeletionScopedIncompleteEvidence(
            reason: .incompleteEnumeration,
            scope: .descendant
        )
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(
                for: candidate,
                currentVerdict: .forbid,
                currentRejection: .vendorPathRule,
                scanEvidence: .incomplete([issue])
            ),
            mode: .professional
        )

        XCTAssertEqual(
            decision,
            .strictAttempt(DeletionTargetStrictAttempt(reasons: [
                .vendorPathRule,
                .scanIncomplete(issue)
            ]))
        )
    }

    func test_strictRiskRequiresProfessionalMode() {
        let candidate = makeCandidate(
            accessEvidence: .incomplete(.incompleteEnumeration)
        )
        let issue = DeletionScopedIncompleteEvidence(
            reason: .incompleteEnumeration,
            scope: .descendant
        )
        let decision = DeletionTargetRevalidationPolicy.decision(
            for: candidate,
            evidence: makeEvidence(
                for: candidate,
                scanEvidence: .incomplete([issue])
            ),
            mode: .normal
        )

        XCTAssertEqual(decision, .prohibited(.requiresProfessionalMode))
    }

    func test_changedIdentityAndUnavailableMoveCapabilityFailClosed() {
        let candidate = makeCandidate()

        XCTAssertEqual(
            DeletionTargetRevalidationPolicy.decision(
                for: candidate,
                evidence: makeEvidence(for: candidate, identity: .changed),
                mode: .professional
            ),
            .prohibited(.identityChanged)
        )
        XCTAssertEqual(
            DeletionTargetRevalidationPolicy.decision(
                for: candidate,
                evidence: makeEvidence(for: candidate, moveAttempt: .unavailable),
                mode: .professional
            ),
            .prohibited(.moveCapabilityUnavailable)
        )
    }

    private func makeCandidate(
        verdict: SafetyVerdict = .safe,
        rejection: SafetyRejection = .ok,
        accessEvidence: DeletionAccessEvidence = .complete
    ) -> DeletionIntentCandidate {
        DeletionIntentCandidate(
            path: "/Users/test/Library/Caches/example",
            title: "example",
            isDirectory: true,
            bytes: 1,
            fileCount: 1,
            verdict: verdict,
            rejection: rejection,
            accessEvidence: accessEvidence
        )
    }

    private func makeEvidence(
        for candidate: DeletionIntentCandidate,
        identity: DeletionTargetIdentityEvidence = .matchesSnapshot,
        currentVerdict: SafetyVerdict = .safe,
        currentRejection: SafetyRejection = .ok,
        scanEvidence: DeletionTargetScanEvidence = .complete,
        moveAttempt: DeletionTargetMoveAttemptEvidence = .eligibleForAttempt
    ) -> DeletionTargetRevalidationEvidence {
        DeletionTargetRevalidationEvidence(
            candidateID: candidate.id,
            path: candidate.rawPath,
            identity: identity,
            currentVerdict: currentVerdict,
            currentRejection: currentRejection,
            scanEvidence: scanEvidence,
            moveAttempt: moveAttempt
        )
    }
}
