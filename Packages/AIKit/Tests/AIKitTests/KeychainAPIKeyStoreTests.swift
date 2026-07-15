import CoreServices
import Foundation
import XCTest
@testable import AIKit

final class KeychainAPIKeyStoreTests: XCTestCase {
    func test_posixENOENT_mapsToStaleFileBasedReference() {
        let status = OSStatus(kPOSIXErrorENOENT)
        XCTAssertEqual(
            KeychainAPIKeyStoreError(status: status),
            .staleFileBasedReference(status)
        )
    }

    @MainActor
    func test_injectedBackend_loadRunsOutsideMainThread() async throws {
        let store = KeychainAPIKeyStore(backend: KeychainAPIKeyStoreBackend(
            save: { _ in },
            load: { Thread.isMainThread ? "main" : "background" },
            remove: {}
        ))

        let executionThread = try await store.load()

        XCTAssertEqual(executionThread, "background")
    }

    func test_injectedBackend_errorIsNotConvertedToMissingValue() async {
        let expected = KeychainAPIKeyStoreError.staleFileBasedReference(
            OSStatus(kPOSIXErrorENOENT)
        )
        let store = KeychainAPIKeyStore(backend: KeychainAPIKeyStoreBackend(
            save: { _ in },
            load: { throw expected },
            remove: {}
        ))

        do {
            _ = try await store.load()
            XCTFail("不可访问的旧条目不能伪装成 nil")
        } catch let error as KeychainAPIKeyStoreError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }
}
