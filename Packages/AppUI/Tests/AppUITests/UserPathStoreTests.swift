import XCTest
@testable import AppUI

/// UserPathStore 单测。覆盖 add/list/remove/dedup/persist/normalize。
///
/// 设计：用 `actor` + `testSuite` 构造在 actor 内部创建 UserDefaults，
/// 满足 Swift 6 严格并发对非 Sendable 类型的要求。
final class UserPathStoreTests: XCTestCase {

    func testSelectedNamespaceSurvivesPersistenceAndSymlinksAreNotSilentlyFollowed() async throws {
        let suite = freshSuite()
        let store = UserPathStore(testSuite: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserPathIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let physical = URL(fileURLWithPath: "/private/var/folders/bucket/process/T/fixture")
        _ = await store.add(URL(fileURLWithPath: physical.path + "/./child/.."))
        _ = await store.add(alias)
        let restored = UserPathStore(testSuite: suite)
        let paths = await restored.list().map(\.path)
        XCTAssertEqual(paths, [physical.path, alias.path])
        let removed = await restored.remove(physical)
        XCTAssertTrue(removed)
    }

    private func freshSuite(_ name: String = #function) -> String {
        let s = "GSYCleanMac.tests.UserPathStore.\(name).\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: s)
        return s
    }

    func test_新仓库初始为空() async throws {
        let store = UserPathStore(testSuite: freshSuite())
        let initial = await store.list()
        XCTAssertTrue(initial.isEmpty)
    }

    func test_add两个不同URL_list应返回两个() async throws {
        let store = UserPathStore(testSuite: freshSuite())
        let a = await store.add(URL(fileURLWithPath: "/tmp/aaa"))
        let b = await store.add(URL(fileURLWithPath: "/tmp/bbb"))
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        let list = await store.list()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map { $0.path }, ["/tmp/aaa", "/tmp/bbb"])
    }

    func test_重复add同一URL_第二次返回false_不会重复入列() async throws {
        let store = UserPathStore(testSuite: freshSuite())
        let first = await store.add(URL(fileURLWithPath: "/tmp/x"))
        let second = await store.add(URL(fileURLWithPath: "/tmp/x"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let list = await store.list()
        XCTAssertEqual(list.count, 1)
    }

    func test_尾随斜杠应被规范化为去重() async throws {
        let store = UserPathStore(testSuite: freshSuite())
        _ = await store.add(URL(fileURLWithPath: "/tmp/dir"))
        let dup = await store.add(URL(fileURLWithPath: "/tmp/dir/"))
        XCTAssertFalse(dup, "/tmp/dir 与 /tmp/dir/ 在 normalize 后应等价")
        let list = await store.list()
        XCTAssertEqual(list.count, 1)
    }

    func test_remove存在URL返回true_不存在返回false() async throws {
        let store = UserPathStore(testSuite: freshSuite())
        _ = await store.add(URL(fileURLWithPath: "/tmp/keep"))
        _ = await store.add(URL(fileURLWithPath: "/tmp/drop"))
        let dropped = await store.remove(URL(fileURLWithPath: "/tmp/drop"))
        XCTAssertTrue(dropped)
        let missed = await store.remove(URL(fileURLWithPath: "/tmp/never"))
        XCTAssertFalse(missed)
        let list = await store.list()
        XCTAssertEqual(list.map { $0.path }, ["/tmp/keep"])
    }

    func test_持久化_新实例能读到旧实例的写入() async throws {
        let suite = freshSuite()
        do {
            let s = UserPathStore(testSuite: suite)
            _ = await s.add(URL(fileURLWithPath: "/tmp/p1"))
            _ = await s.add(URL(fileURLWithPath: "/tmp/p2"))
        }
        let s2 = UserPathStore(testSuite: suite)
        let list = await s2.list()
        XCTAssertEqual(list.map { $0.path }, ["/tmp/p1", "/tmp/p2"])
    }

    func test_testReset_清空内存和落盘() async throws {
        let suite = freshSuite()
        do {
            let s = UserPathStore(testSuite: suite)
            _ = await s.add(URL(fileURLWithPath: "/tmp/aaa"))
            await s._testReset()
            let list = await s.list()
            XCTAssertTrue(list.isEmpty)
        }
        // fresh 实例验证持久化也确实被清了
        let s2 = UserPathStore(testSuite: suite)
        let list2 = await s2.list()
        XCTAssertTrue(list2.isEmpty)
    }

    func test_snapshots_跨场景订阅会收到初始值及后续变更() async throws {
        let store = UserPathStore(testSuite: freshSuite())
        let snapshots = await store.snapshots()
        var iterator = snapshots.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.path), [])

        _ = await store.add(URL(fileURLWithPath: "/tmp/shared"))
        let added = await iterator.next()
        XCTAssertEqual(added?.map(\.path), ["/tmp/shared"])

        _ = await store.remove(URL(fileURLWithPath: "/tmp/shared"))
        let removed = await iterator.next()
        XCTAssertEqual(removed?.map(\.path), [])
    }

    func test_snapshots_两个场景订阅者都收到同一最终状态() async {
        let store = UserPathStore(testSuite: freshSuite())
        let mainStream = await store.snapshots()
        let settingsStream = await store.snapshots()
        var main = mainStream.makeAsyncIterator()
        var settings = settingsStream.makeAsyncIterator()

        let mainInitial = await main.next()
        let settingsInitial = await settings.next()
        XCTAssertEqual(mainInitial?.map(\.path), [])
        XCTAssertEqual(settingsInitial?.map(\.path), [])

        _ = await store.add(URL(fileURLWithPath: "/tmp/shared-a"))
        let mainAdded = await main.next()
        let settingsAdded = await settings.next()
        XCTAssertEqual(mainAdded?.map(\.path), ["/tmp/shared-a"])
        XCTAssertEqual(settingsAdded?.map(\.path), ["/tmp/shared-a"])
    }

    func test_snapshots_burst只积压最新完整快照() async {
        let store = UserPathStore(testSuite: freshSuite())
        let stream = await store.snapshots()
        var iterator = stream.makeAsyncIterator()

        _ = await store.add(URL(fileURLWithPath: "/tmp/old-a"))
        _ = await store.add(URL(fileURLWithPath: "/tmp/keep"))
        _ = await store.remove(URL(fileURLWithPath: "/tmp/old-a"))

        let latest = await iterator.next()
        XCTAssertEqual(latest?.map(\.path), ["/tmp/keep"])
    }

    func test_snapshots_旧订阅取消后新订阅仍从当前完整状态开始() async {
        let store = UserPathStore(testSuite: freshSuite())
        let oldStream = await store.snapshots()
        let consumer = Task {
            for await _ in oldStream {
                if Task.isCancelled { return }
            }
        }
        consumer.cancel()
        _ = await consumer.result

        _ = await store.add(URL(fileURLWithPath: "/tmp/current"))
        let newStream = await store.snapshots()
        var iterator = newStream.makeAsyncIterator()
        let current = await iterator.next()
        XCTAssertEqual(current?.map(\.path), ["/tmp/current"])
    }
}
