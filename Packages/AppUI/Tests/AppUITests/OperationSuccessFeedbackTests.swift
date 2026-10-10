import XCTest
@testable import AppUI

final class OperationSuccessFeedbackTests: XCTestCase {
    // v2026.10.10: a debug preview is quiet but cannot tell the user files were trashed.
    // Keep both messages live-localized and preserve the real receipt's timer identity.
    func test_previewAndRealSuccessHaveDistinctLocalizedMeaningAndIdentity() {
        let receiptID = UUID()
        let real = MainDeletionSuccessFeedback.deletion(.init(id: receiptID, movedCount: 2))
        let preview = MainDeletionSuccessFeedback.preview(id: UUID(), processedCount: 2, skippedCount: 0)
        XCTAssertEqual(real.id, receiptID)
        XCTAssertNotEqual(real.id, preview.id)
        XCTAssertEqual(real.accessibilityIdentifier, "delete.success.feedback")
        XCTAssertEqual(preview.accessibilityIdentifier, "delete.preview.feedback")
        for language in ["zh-Hans", "en"] {
            let locale = Locale(identifier: language)
            let message = preview.message.localized(locale: locale)
            XCTAssertTrue(message.contains(language == "en" ? "preview" : "预览"))
            XCTAssertTrue(message.contains("2"))
            XCTAssertTrue(message.contains("0"))
            XCTAssertNotEqual(message, real.message.localized(locale: locale))
            XCTAssertFalse(real.message.localized(locale: locale).contains(language == "en" ? "preview" : "预览"))
        }
    }
}
