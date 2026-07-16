import AIKit
import CoreServices
import XCTest
@testable import AppUI

final class KeychainFailurePresentationTests: XCTestCase {
    private let staleReference = KeychainAPIKeyStoreError.staleFileBasedReference(
        OSStatus(kPOSIXErrorENOENT)
    )

    func test_staleFileReference_usesActionableLocalizedMessage() {
        let presentation = KeychainUserFacingError.presentation(for: staleReference)
        XCTAssertEqual(
            presentation.localizationKey,
            "ai.keychain.error.stale_file_reference"
        )
        let english = presentation.localizedMessage(locale: Locale(identifier: "en"))
        let chinese = presentation.localizedMessage(locale: Locale(identifier: "zh-Hans"))
        XCTAssertFalse(english.isEmpty)
        XCTAssertFalse(chinese.isEmpty)
        XCTAssertNotEqual(english, chinese)
        XCTAssertFalse(english.contains("unhandled(100002)"))
        XCTAssertFalse(chinese.contains("unhandled(100002)"))
    }

    func test_aiSettingsFeedback_reprojectsSameSemanticStateForCurrentLocale() {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")

        XCTAssertEqual(
            AppLocalization.string("settings.ai.api_key.empty", locale: english),
            "(not configured)"
        )
        XCTAssertEqual(
            AppLocalization.string("settings.ai.api_key.empty", locale: chinese),
            "（尚未配置）"
        )
        XCTAssertEqual(
            AISettingsAPIKeyFeedback.saved.localizedMessage(locale: english),
            "Saved to Keychain."
        )
        XCTAssertEqual(
            AISettingsAPIKeyFeedback.saved.localizedMessage(locale: chinese),
            "已保存到钥匙串。"
        )
        XCTAssertEqual(
            AISettingsAPIKeyFeedback.removed.localizedMessage(locale: english),
            "Removed from Keychain."
        )
        XCTAssertEqual(
            AISettingsAPIKeyFeedback.removed.localizedMessage(locale: chinese),
            "已从钥匙串删除。"
        )
    }

    func test_aiSettingsKeychainFailure_reprojectsWithoutRecreatingPayload() {
        let feedback = AISettingsAPIKeyFeedback.failure(
            KeychainUserFacingError.presentation(for: staleReference)
        )

        XCTAssertNotEqual(
            feedback.localizedMessage(locale: Locale(identifier: "en")),
            feedback.localizedMessage(locale: Locale(identifier: "zh-Hans"))
        )
    }

    func test_smartCareClassifiesKeychainFailureAsCredentialStorageProblem() {
        let failure = SmartCareAIReviewFailure(error: staleReference)

        XCTAssertEqual(failure.kind, .credentialStorage)
        XCTAssertFalse(failure.canRetry)
        XCTAssertTrue(failure.shouldOpenSettings)
        XCTAssertTrue(failure.stopsBatch)
    }
}
