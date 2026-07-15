import XCTest
@testable import AppUI

@MainActor
final class StashStoreTests: XCTestCase {
    func test_entryFreezesFileCountAndDeniedContextForLaterConfirmation() {
        let store = StashStore()
        let denied: Set<String> = ["/Users/test/Library/Caches/example/locked"]

        XCTAssertTrue(store.add(
            path: "/Users/test/Library/Caches/example",
            title: "example",
            bytes: 42,
            isDirectory: true,
            fileCount: 137,
            accessDeniedPaths: denied
        ))

        XCTAssertEqual(store.entries.first?.fileCount, 137)
        XCTAssertEqual(store.entries.first?.accessDeniedPaths, denied)
    }

    func test_duplicateAddMergesScanEvidenceMonotonically() {
        let store = StashStore()
        let path = "/Users/test/Library/Caches/example"
        let originalDenied: Set<String> = [path + "/first-locked"]

        XCTAssertTrue(store.add(
            path: path,
            title: "example",
            bytes: 42,
            isDirectory: true,
            fileCount: 20,
            accessDeniedPaths: originalDenied
        ))
        XCTAssertFalse(store.add(
            path: path,
            title: "example-new",
            bytes: 99,
            isDirectory: true,
            fileCount: 99,
            accessDeniedPaths: [path + "/second-locked"]
        ))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].fileCount, 99)
        XCTAssertEqual(
            store.entries[0].accessDeniedPaths,
            originalDenied.union([path + "/second-locked"])
        )
    }
}
