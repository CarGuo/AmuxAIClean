import Foundation
import XCTest
@testable import AppUI

final class TreeRowPresentationTests: XCTestCase {
    func testExactMetricsUseCompactCountAndKeepFullDetailValue() {
        let row = makeRow(
            bytes: 123_678_901_234,
            fileCount: 1_423_456,
            subtreeCompleteness: .complete
        )

        let presentation = TreeMetricPresentation(
            row: row,
            locale: Locale(identifier: "en"),
            localization: .english
        )

        XCTAssertEqual(presentation.state, .exact)
        XCTAssertEqual(presentation.size.compactText, presentation.size.detailText)
        XCTAssertEqual(presentation.logicalSize.compactText, presentation.logicalSize.detailText)
        XCTAssertEqual(presentation.count.compactText, "1.4M")
        XCTAssertEqual(presentation.count.detailText, "1,423,456")
        XCTAssertNil(presentation.partialStatusText)
        XCTAssertNil(presentation.helpText)
    }

    func testLowerBoundSizeRoundsDownAndDetailPreservesAtLeastSemantics() throws {
        let row = makeRow(
            bytes: 1_999_999,
            fileCount: 1_999_999,
            subtreeCompleteness: .containsIncompleteDescendant
        )

        let presentation = TreeMetricPresentation(
            row: row,
            locale: Locale(identifier: "en"),
            localization: .english
        )

        XCTAssertEqual(presentation.state, .lowerBound)
        XCTAssertTrue(presentation.size.compactText.hasPrefix("1.99"),
                      "lower-bound size must floor 1.999999 MB instead of rounding it up")
        XCTAssertTrue(presentation.size.compactText.contains("MB"))
        XCTAssertFalse(presentation.size.compactText.hasPrefix("2 "))
        XCTAssertTrue(presentation.logicalSize.compactText.hasPrefix("1.99"))
        XCTAssertFalse(presentation.logicalSize.compactText.hasPrefix("2 "))
        XCTAssertEqual(presentation.count.compactText, "1.9M")
        XCTAssertEqual(presentation.size.detailText, "At least \(presentation.size.compactText)")
        XCTAssertEqual(
            presentation.logicalSize.detailText,
            "At least \(presentation.logicalSize.compactText)"
        )
        XCTAssertEqual(presentation.count.detailText, "At least 1,999,999")
        XCTAssertEqual(presentation.partialStatusText, "Partial")
        XCTAssertTrue(try XCTUnwrap(presentation.helpText).contains("at least"))
    }

    func testCompactCountUsesRequestedLocaleWithoutLosingFullDetail() {
        let row = makeRow(
            bytes: 123_678_901_234,
            fileCount: 1_423_456,
            subtreeCompleteness: .containsIncompleteDescendant
        )

        let english = TreeMetricPresentation(
            row: row,
            locale: Locale(identifier: "en"),
            localization: .english
        )
        let chinese = TreeMetricPresentation(
            row: row,
            locale: Locale(identifier: "zh-Hans"),
            localization: .simplifiedChinese
        )

        XCTAssertEqual(english.count.compactText, "1.4M")
        XCTAssertTrue(chinese.count.compactText.contains("万"),
                      "Chinese compact notation must follow Foundation locale rules")
        XCTAssertFalse(chinese.count.compactText.contains("M"))
        XCTAssertTrue(chinese.count.detailText.hasPrefix("至少 "))
        XCTAssertTrue(chinese.count.detailText.contains("1,423,456"))
        XCTAssertEqual(chinese.partialStatusText, "部分")
    }

    func testUnavailableAndPendingTakePriorityOverPartialSubtree() {
        let unavailable = makeRow(
            bytes: 100,
            fileCount: 10,
            accessState: .permissionDenied,
            subtreeCompleteness: .containsIncompleteDescendant
        )
        let pending = makeRow(
            bytes: 100,
            fileCount: 10,
            subtreeCompleteness: .containsIncompleteDescendant,
            isSizePending: true
        )

        let unavailablePresentation = TreeMetricPresentation(row: unavailable)
        let pendingPresentation = TreeMetricPresentation(row: pending)

        XCTAssertEqual(unavailablePresentation.state, .unavailable)
        XCTAssertEqual(unavailablePresentation.size.compactText, "—")
        XCTAssertEqual(unavailablePresentation.logicalSize.compactText, "—")
        XCTAssertEqual(unavailablePresentation.count.compactText, "—")
        XCTAssertNil(unavailablePresentation.helpText)

        XCTAssertEqual(pendingPresentation.state, .pending)
        XCTAssertEqual(pendingPresentation.size.compactText, "—")
        XCTAssertEqual(pendingPresentation.logicalSize.compactText, "—")
        XCTAssertEqual(pendingPresentation.count.compactText, "—")
        XCTAssertNil(pendingPresentation.helpText)
    }

    private func makeRow(
        bytes: Int64,
        fileCount: Int,
        accessState: TreeRow.AccessState = .normal,
        subtreeCompleteness: TreeRow.SubtreeCompleteness,
        isSizePending: Bool = false
    ) -> TreeRow {
        TreeRow(
            path: "/scan/Library",
            title: "Library",
            bytes: bytes,
            fileCount: fileCount,
            isDirectory: true,
            hasChildren: true,
            accessState: accessState,
            subtreeCompleteness: subtreeCompleteness,
            isSizePending: isSizePending
        )
    }
}

private extension TreeMetricPresentation.Localization {
    static let english = Self(
        lowerBoundFormat: "At least %@",
        partialStatus: "Partial",
        partialHelpFormat: "Partial scan: at least %1$@ is known on disk; the known file count is at least %2$@."
    )

    static let simplifiedChinese = Self(
        lowerBoundFormat: "至少 %@",
        partialStatus: "部分",
        partialHelpFormat: "扫描不完整：当前至少已统计 %1$@ 磁盘占用，已知文件数至少为 %2$@。"
    )
}
