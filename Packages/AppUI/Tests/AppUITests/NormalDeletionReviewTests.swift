import Foundation
import XCTest
@testable import AppUI

final class NormalDeletionReviewTests: XCTestCase {
    func testNormalReviewShowsRecursiveFileCountAndSourceInBothLanguages() throws {
        let intent = try DeletionIntent(
            origin: .storageAnalysis, mode: .normal,
            snapshotIdentity: DeletionSnapshotIdentity(sessionID: UUID(), revision: 1),
            candidates: [.init(path: "/fixture/folder", title: "folder", isDirectory: true,
                               bytes: 4096, fileCount: 123, verdict: .confirm, rejection: .ok)]
        )
        let plan = try DeletionConfirmationPlan(
            intent: intent, items: intent.candidates.map { .init(candidate: $0, disposition: .normal) }
        )
        let english = NormalDeletionReviewCopy.resolve(plan: plan, locale: Locale(identifier: "en"))
        let chinese = NormalDeletionReviewCopy.resolve(plan: plan, locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(english.summary.contains("Selected: 1"))
        XCTAssertTrue(english.summary.contains("Files: 123"))
        XCTAssertEqual(english.source, "Source: Storage analysis")
        XCTAssertTrue(chinese.summary.contains("123 个文件"))
        XCTAssertEqual(chinese.source, "来源：存储分析")
        XCTAssertEqual(AppLocalization.format("delete.review.files %lld", locale: Locale(identifier: "en"), arguments: [Int64(123)]), "Files: 123")
        XCTAssertEqual(AppLocalization.format("delete.review.files %lld", locale: Locale(identifier: "zh-Hans"), arguments: [Int64(123)]), "文件数：123")
    }
}
