import AIKit
import CoreServices
import XCTest
@testable import AppUI

final class KeychainFailurePresentationTests: XCTestCase {
    private let staleReference = KeychainAPIKeyStoreError.staleFileBasedReference(
        OSStatus(kPOSIXErrorENOENT)
    )

    func test_staleFileReference_usesActionableLocalizedMessage() {
        XCTAssertEqual(
            KeychainUserFacingError.localizationKey(for: staleReference),
            "ai.keychain.error.stale_file_reference"
        )
        let message = KeychainUserFacingError.message(for: staleReference)
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("unhandled(100002)"))
    }

    func test_smartCareClassifiesKeychainFailureAsCredentialStorageProblem() {
        let failure = SmartCareAIReviewFailure(error: staleReference)

        XCTAssertEqual(failure.kind, .credentialStorage)
        XCTAssertFalse(failure.canRetry)
        XCTAssertTrue(failure.shouldOpenSettings)
        XCTAssertTrue(failure.stopsBatch)
    }
}
