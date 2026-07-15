import ScanKit
import XCTest
@testable import AppUI

final class MultiRootCompletionPolicyTests: XCTestCase {
    func testAllExpectedRootsWithCompleteSummariesPublishesSuccess() {
        XCTAssertTrue(
            ScanCoordinator.multiRootCompletionIsSuccessful(
                expectedRootPaths: ["/A", "/B"],
                finishedRootPaths: ["/A", "/B"],
                sawPartialRoot: false,
                sawFailure: false,
                consumerCancelled: false
            )
        )
    }

    func testStreamClosureWithUnscheduledRootNeverPublishesSuccess() {
        XCTAssertFalse(
            ScanCoordinator.multiRootCompletionIsSuccessful(
                expectedRootPaths: ["/A", "/B", "/C"],
                finishedRootPaths: ["/A", "/B"],
                sawPartialRoot: false,
                sawFailure: false,
                consumerCancelled: false
            ),
            "total deadline 关闭 stream 时，未调度根不能被伪装成已完成"
        )
    }

    func testSyntheticPartialSummaryNeverPublishesSuccess() {
        XCTAssertFalse(
            ScanCoordinator.multiRootCompletionIsSuccessful(
                expectedRootPaths: ["/A", "/B"],
                finishedRootPaths: ["/A", "/B"],
                sawPartialRoot: true,
                sawFailure: false,
                consumerCancelled: false
            ),
            "per-root timeout 即使合成 finished 供状态收敛，也只能是 partial"
        )
    }

    func testFailureOrCancellationNeverPublishesSuccess() {
        XCTAssertFalse(
            ScanCoordinator.multiRootCompletionIsSuccessful(
                expectedRootPaths: ["/A"],
                finishedRootPaths: ["/A"],
                sawPartialRoot: false,
                sawFailure: true,
                consumerCancelled: false
            )
        )
        XCTAssertFalse(
            ScanCoordinator.multiRootCompletionIsSuccessful(
                expectedRootPaths: ["/A"],
                finishedRootPaths: ["/A"],
                sawPartialRoot: false,
                sawFailure: false,
                consumerCancelled: true
            )
        )
    }

    func testSingleRootTerminalFallbackOnlyExpandsWhenEvidenceIsNotPrecise() {
        let root = URL(fileURLWithPath: "/A")
        let preciseIssue = ScanIncompleteIssue(
            path: "/A/locked",
            reason: .permissionDenied
        )
        let precisePartial = ScanSummary(
            root: root,
            totalAllocatedBytes: 1,
            totalLogicalBytes: 1,
            fileCount: 1,
            directoryCount: 1,
            dedupedHardlinkBytes: 0,
            elapsed: 0,
            incompleteIssues: [preciseIssue]
        )
        let opaquePartial = ScanSummary(
            root: root,
            totalAllocatedBytes: 1,
            totalLogicalBytes: 1,
            fileCount: 1,
            directoryCount: 1,
            dedupedHardlinkBytes: 0,
            elapsed: 0,
            completionStatus: .partial
        )

        XCTAssertFalse(ScanCoordinator.singleRootNeedsTerminalFallback(
            sawFailure: false,
            summary: precisePartial
        ))
        XCTAssertTrue(ScanCoordinator.singleRootNeedsTerminalFallback(
            sawFailure: false,
            summary: opaquePartial
        ))
        XCTAssertTrue(ScanCoordinator.singleRootNeedsTerminalFallback(
            sawFailure: false,
            summary: nil
        ))
        XCTAssertTrue(ScanCoordinator.singleRootNeedsTerminalFallback(
            sawFailure: true,
            summary: precisePartial
        ))
    }

    func testMultiRootTerminalFallbackIncludesMissingAndFailedRoots() {
        XCTAssertEqual(
            ScanCoordinator.multiRootTerminalFallbackPaths(
                expectedRootPaths: ["/A", "/B", "/C"],
                finishedRootPaths: ["/A", "/B"],
                failedRootPaths: ["/B"]
            ),
            ["/B", "/C"],
            "明确失败和从未发出 finished 的根都必须进入删除拒绝证据"
        )
    }

    func testDeveloperDiscoveryTimeoutOrTruncationCannotPublishComplete() {
        XCTAssertTrue(ScanCoordinator.developerDiscoveryIsComplete(
            didTimeout: false,
            didTruncate: false,
            hasIncompleteEvidence: false
        ))
        XCTAssertFalse(ScanCoordinator.developerDiscoveryIsComplete(
            didTimeout: true,
            didTruncate: false,
            hasIncompleteEvidence: false
        ))
        XCTAssertFalse(ScanCoordinator.developerDiscoveryIsComplete(
            didTimeout: false,
            didTruncate: true,
            hasIncompleteEvidence: false
        ))
        XCTAssertFalse(ScanCoordinator.developerDiscoveryIsComplete(
            didTimeout: true,
            didTruncate: true,
            hasIncompleteEvidence: false
        ))
        XCTAssertFalse(ScanCoordinator.developerDiscoveryIsComplete(
            didTimeout: false,
            didTruncate: false,
            hasIncompleteEvidence: true
        ))
    }
}
