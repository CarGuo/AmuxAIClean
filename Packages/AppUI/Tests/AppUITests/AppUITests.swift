import XCTest
@testable import AppUI
import SafetyKit
import XPCBridge

final class HelperClientPipelineTests: XCTestCase {
    func testMockPipelineRoundTrip() async {
        let key = Data(repeating: 0xCD, count: 32)
        let mock = MockHelperClient(signingKey: key)
        let (moved, skipped, err) = await mock.moveToTrash(
            paths: ["/Users/test/Library/Caches/x"],
            dryRun: true
        )
        XCTAssertNil(err)
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(skipped, 0)
    }

    func testMockSelfVerifyAlwaysPasses() async {
        let key = Data("any-32-byte-secret-for-testing!!".utf8)
        let mock = MockHelperClient(signingKey: key)
        let (_, _, err) = await mock.moveToTrash(paths: ["/tmp/x"], dryRun: true)
        XCTAssertNil(err, "用同 key 自签自验必须通过")
    }

    func testMockBlocksRealDeleteWithoutDryRun() async {
        let key = Data(repeating: 0x01, count: 32)
        let mock = MockHelperClient(signingKey: key)
        let (moved, _, err) = await mock.moveToTrash(paths: ["/tmp/y"], dryRun: false)
        XCTAssertNotNil(err, "mock 不能真删")
        XCTAssertEqual(moved, 1) // 报告"会动"的项数
    }
}

final class ScanCategoryTests: XCTestCase {
    func testRecommendedCategoriesContainCachesAndDownloads() {
        let cats = ScanCategories.recommended(home: "/Users/foo")
        let ids = cats.map(\.id)
        XCTAssertTrue(ids.contains("user.caches"))
        XCTAssertTrue(ids.contains("user.downloads"))
        // 默认 verdict 区分
        let caches = cats.first { $0.id == "user.caches" }
        XCTAssertEqual(caches?.defaultVerdict, .safe)
        let dl = cats.first { $0.id == "user.downloads" }
        XCTAssertEqual(dl?.defaultVerdict, .confirm)
    }
}

final class RowItemSelectionTests: XCTestCase {
    func testForbidIsNotSelectable() {
        let r = RowItem(
            id: "a", url: URL(fileURLWithPath: "/System/Library/x"),
            title: "x", isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
            verdict: .forbid, rejection: .hardForbidPrefix
        )
        XCTAssertFalse(r.isSelectable)
        XCTAssertFalse(r.defaultSelected)
    }

    func testSafeIsDefaultSelected() {
        let r = RowItem(
            id: "b", url: URL(fileURLWithPath: "/Users/foo/Library/Caches/x"),
            title: "x", isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
            verdict: .safe, rejection: .ok
        )
        XCTAssertTrue(r.isSelectable)
        XCTAssertTrue(r.defaultSelected)
    }

    func testConfirmIsSelectableButNotDefaultOn() {
        let r = RowItem(
            id: "c", url: URL(fileURLWithPath: "/Users/foo/Downloads/x.zip"),
            title: "x.zip", isDirectory: false, bytes: 100, logicalBytes: 100, fileCount: 1,
            verdict: .confirm, rejection: .ok
        )
        XCTAssertTrue(r.isSelectable)
        XCTAssertFalse(r.defaultSelected)
    }
}

final class TrashPipelineTests: XCTestCase {
    func testEmptyPathsReturnsZero() async {
        let pipe = TrashPipeline()
        let (moved, skipped, err) = await pipe.moveToTrash(paths: [], dryRun: true)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
    }

    func testDryRunNeverTouchesDisk() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashPipelineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f = dir + "/keep.txt"
        try "hello".write(toFile: f, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (moved, _, err) = await pipe.moveToTrash(paths: [f], dryRun: true)
        XCTAssertEqual(moved, 1)
        XCTAssertNil(err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f), "dryRun 必须不动磁盘")
    }

    /// 真删测试 —— 在 CI 上会真把临时文件移到废纸篓，但因为是临时目录，无副作用
    func testRealRecycleMovesToTrash() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashPipelineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f = dir + "/will-trash.txt"
        try "bye".write(toFile: f, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (moved, skipped, err) = await pipe.moveToTrash(paths: [f], dryRun: false)
        XCTAssertNil(err)
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(skipped, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f), "真删后原路径应不存在")
    }
}
