import Foundation
import XCTest
@testable import AppUI

final class ScanIssuePresentationTests: XCTestCase {
    func test_relatedSoftEvidenceProducesOneLimitationsStateAndDeduplicatesPaths() {
        let result = ScanIssuePresentation.make(
            hasTerminalFailure: false,
            permissionDeniedPaths: ["/tmp/blocked", "/tmp/blocked"],
            tccSkippedPaths: ["/tmp/tcc"],
            incompletePaths: ["/tmp/blocked", "/tmp/changed"]
        )

        XCTAssertEqual(result.kind, .limitations)
        XCTAssertEqual(result.permissionDeniedPaths, ["/tmp/blocked"])
        XCTAssertEqual(result.tccSkippedPaths, ["/tmp/tcc"])
        XCTAssertEqual(result.otherIncompletePaths, ["/tmp/changed"])
        XCTAssertEqual(result.allLimitedPaths, ["/tmp/blocked", "/tmp/changed", "/tmp/tcc"])
    }

    func test_terminalFailureIsMutuallyExclusivePrimaryState() {
        let result = ScanIssuePresentation.make(
            hasTerminalFailure: true,
            permissionDeniedPaths: ["/tmp/blocked"],
            tccSkippedPaths: [],
            incompletePaths: ["/tmp/changed"]
        )

        XCTAssertEqual(result.kind, .fatal)
        XCTAssertEqual(result.limitationCount, 2, "诊断证据仍保留，但 UI 主状态只能是 fatal")
    }

    func test_noEvidenceProducesNoIssuePresentation() {
        XCTAssertEqual(
            ScanIssuePresentation.make(
                hasTerminalFailure: false,
                permissionDeniedPaths: [],
                tccSkippedPaths: [],
                incompletePaths: []
            ).kind,
            .none
        )
    }

    func test_mainScanStatusDoesNotRenderRawCoordinatorError() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainView = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Packages/AppUI/Sources/AppUI/MainView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(mainView.contains("Text(err)"))
        XCTAssertFalse(mainView.contains("Text(coordinator.lastError"))
        XCTAssertFalse(mainView.contains("Text(\"\\(error)\")"))
        XCTAssertTrue(mainView.contains("ScanIssuePresentation.make("))
    }
}
