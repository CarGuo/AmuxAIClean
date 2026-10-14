import Darwin
import ScanKit
import XCTest
@testable import AppUI

/// v2026.10.14: an unselected discovery root may be unreadable without invalidating
/// the stable object identity and complete snapshot of an independently reviewed candidate.
final class UninstallSelectedEvidenceRegressionTests: XCTestCase {
    func testUnrelatedDiscoveryFailureDoesNotVetoCompleteSelectedCandidate() {
        let selected = completeCandidate()
        let unrelatedRootFailure = UninstallDiscoveryIssue(
            source: .primaryRoot,
            stage: .rootEnumeration,
            path: "/Fixture/Home/Library/Containers",
            reason: .permissionDenied
        )
        XCTAssertTrue(UninstallDeletionSelectionPolicy.isSelectable(selected))
        XCTAssertFalse(UninstallDeletionSelectionPolicy.blocksAllCandidates([unrelatedRootFailure]))
        XCTAssertTrue(UninstallDeletionSelectionPolicy.canSubmit(
            [selected], discoveryIssues: [unrelatedRootFailure]
        ), "An unreadable unselected discovery root must not disable a complete cache candidate")
    }

    func testSelectedAppIdentityFailureStillVetoesEveryCandidate() {
        let selectedIdentityFailure = UninstallDiscoveryIssue(
            source: .selectedAppIdentity,
            stage: .identityValidation,
            path: "/Fixture/Home/Applications/Demo.app",
            reason: .identityMismatch(
                claimedBundleID: "com.example.Demo", actualBundleID: "com.example.Replaced"
            )
        )
        XCTAssertFalse(UninstallDeletionSelectionPolicy.canSubmit(
            [completeCandidate()], discoveryIssues: [selectedIdentityFailure]
        ), "Losing the selected application's identity is different from an unrelated discovery gap")
        XCTAssertTrue(UninstallDeletionSelectionPolicy.blocksAllCandidates([selectedIdentityFailure]))
    }

    func testUnselectedPartialCandidateDoesNotBlockHealthySibling() {
        let healthy = completeCandidate()
        let partial = UninstallCandidate(
            path: "/Fixture/Home/Library/Containers/com.example.Demo",
            bytes: 8, fileCount: 1, isDirectory: true,
            snapshotCompletion: .partial,
            snapshotIssues: [.init(path: "/Fixture/Home/Library/Containers/com.example.Demo",
                                   reason: .permissionDenied, stage: .enumeration)],
            objectIdentity: TrashObjectIdentity(device: 1, inode: 3, fileType: UInt16(S_IFDIR)),
            matchReason: .bundleID("com.example.Demo")
        )
        let discovery = UninstallCandidateDiscoveryResult(candidates: [healthy, partial])
        XCTAssertFalse(discovery.incompleteIssues.isEmpty)
        XCTAssertEqual(UninstallDeletionSelectionPolicy.selectablePaths(in: discovery.candidates), [healthy.path])
        XCTAssertTrue(UninstallDeletionSelectionPolicy.canSubmit(
            [healthy], discoveryIssues: discovery.incompleteIssues
        ))
        XCTAssertFalse(UninstallDeletionSelectionPolicy.canSubmit(
            [partial], discoveryIssues: discovery.incompleteIssues
        ), "The selected object's own incomplete evidence is never promoted by a healthy sibling")
    }

    private func completeCandidate() -> UninstallCandidate {
        UninstallCandidate(
            path: "/Fixture/Home/Library/Caches/com.example.Demo",
            bytes: 128, fileCount: 2, isDirectory: true,
            objectIdentity: TrashObjectIdentity(device: 1, inode: 2, fileType: UInt16(S_IFDIR)),
            matchReason: .bundleID("com.example.Demo")
        )
    }
}
