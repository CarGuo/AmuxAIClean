import XCTest
@testable import SafetyKit

/// Mole 对齐 M3-T2：WhitelistStore 行为契约。
final class WhitelistStoreTests: XCTestCase {

    func test_空_store_isWhitelisted_全部为_false() async throws {
        let store = WhitelistStore(storageURL: nil)
        let r1 = await store.isWhitelisted("/Users/foo/Library/Caches/X")
        let r2 = await store.isWhitelisted("/Users/foo/.npm")
        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
    }

    func test_add_后_isWhitelisted_精确命中() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/Library/Caches/X")
        let hit = await store.isWhitelisted("/Users/foo/Library/Caches/X")
        let miss = await store.isWhitelisted("/Users/foo/Library/Caches/Y")
        XCTAssertTrue(hit)
        XCTAssertFalse(miss)
    }

    func test_add_父目录_子项也命中_prefix() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/work")
        let child = await store.isWhitelisted("/Users/foo/work/repo/node_modules")
        XCTAssertTrue(child, "加白父目录后整个子树都应命中")
    }

    func test_add_子项_不会让父目录命中() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/work/repo/node_modules")
        let parent = await store.isWhitelisted("/Users/foo/work")
        XCTAssertFalse(parent, "加白子项不应让父目录被加白")
    }

    func test_prefix_不应误命中_相似前缀_目录() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/X")
        let similar = await store.isWhitelisted("/Users/foo/Xtra")
        XCTAssertFalse(similar, "Xtra 不应被 X 错误命中（必须有 / 分隔符）")
    }

    func test_remove_后_isWhitelisted_回归_false() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/A")
        let beforeRemove = await store.isWhitelisted("/Users/foo/A")
        XCTAssertTrue(beforeRemove)

        let removed = await store.remove(path: "/Users/foo/A")
        XCTAssertTrue(removed)
        let afterRemove = await store.isWhitelisted("/Users/foo/A")
        XCTAssertFalse(afterRemove)
    }

    func test_normalize_去除尾_slash() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/B/")
        let hit = await store.isWhitelisted("/Users/foo/B")
        XCTAssertTrue(hit, "尾部 slash 应被规范化")
    }

    func test_list_按_addedAt_倒序() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/A")
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        await store.add(path: "/Users/foo/B")
        try await Task.sleep(nanoseconds: 10_000_000)
        await store.add(path: "/Users/foo/C")

        let list = await store.list()
        XCTAssertEqual(list.map(\.path), ["/Users/foo/C", "/Users/foo/B", "/Users/foo/A"])
    }

    func test_持久化_文件_往返() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhitelistStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store1 = WhitelistStore(storageURL: tmp)
        await store1.add(path: "/Users/foo/A", reason: "I know it")
        await store1.add(path: "/Users/foo/B", reason: nil)

        // 新建另一个 store 实例读同一个文件
        let store2 = WhitelistStore(storageURL: tmp)
        let isA = await store2.isWhitelisted("/Users/foo/A")
        let isB = await store2.isWhitelisted("/Users/foo/B")
        let list = await store2.list()

        XCTAssertTrue(isA)
        XCTAssertTrue(isB)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first(where: { $0.path == "/Users/foo/A" })?.reason, "I know it")
    }

    func test_重复_add_是_idempotent_刷新_addedAt() async throws {
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: "/Users/foo/A", reason: "old")
        let firstList = await store.list()
        let firstAt = firstList.first?.addedAt
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms

        await store.add(path: "/Users/foo/A", reason: "new")
        let secondList = await store.list()
        XCTAssertEqual(secondList.count, 1, "重复 add 应去重")
        XCTAssertEqual(secondList.first?.reason, "new")
        XCTAssertNotNil(firstAt)
        XCTAssertGreaterThan(secondList.first!.addedAt, firstAt!,
                             "重复 add 应刷新 addedAt")
    }
}
