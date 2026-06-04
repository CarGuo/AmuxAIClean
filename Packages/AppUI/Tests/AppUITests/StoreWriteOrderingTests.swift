import XCTest
import ScanKit
@testable import AppUI

/// Step 17-B：GRDB store 写盘 daisychain 顺序契约。
///
/// 背景（docs/AUDIT_2026_06.md L491-L492 "P3-2 GRDB store 写入有界并发"）：
/// ScanCoordinator 在 v1.3.zzz 的 P0-B 修复里把 store 写盘统一通过 storeWriteChain
/// 串成一条单向 daisychain（[ScanCoordinator.swift L156-L161](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L156-L161)），
/// 这是"有界并发=1"的当前形态。Step 17-B 按 audit 要求"必须先有顺序保证测试"——
/// 本次先把 daisychain 现状钉成 contract，未来任何把并发度从 1 提到 2-3 的改动
/// 必须先让这些测试 fail 才能落地。
///
/// 全部断言走"现状钉死"模式（与 Step 17-D / 17-A / 17-C 同款）：
/// 通过 [OrderRecordingScanResultStore](#L31) 这个 actor test double
/// 记录每次 beginSession / insert / finalize 的到达顺序，再通过
/// [ScanCoordinator._seedStoreForTesting](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// + [_flushStoreBatchForTesting](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// 直接驱动 daisychain，避开真扫描 IO。

/// Test double 记录到达顺序的事件枚举。
/// `Equatable` 用于 XCTAssertEqual prefix/序列断言。
enum StoreEvent: Equatable {
    case begin(ScanSessionID)
    case insert(count: Int, firstPath: String?)
    case finalize(ScanSessionID)
}

/// 顺序记录用 ScanResultStore 实现：内部以 actor 串行化记录 events。
///
/// 关键不变量：events 的 append 顺序 == 各 async 方法 await 闭包内的执行顺序，
/// 即 actor 入队顺序 == 测试观察到的事件序。
actor OrderRecordingScanResultStore: ScanResultStore {
    private(set) var events: [StoreEvent] = []
    private(set) var insertedRecords: [ScanResultRecord] = []

    func beginSession(_ id: ScanSessionID) async throws {
        events.append(.begin(id))
    }

    func insert(_ records: [ScanResultRecord]) async throws {
        events.append(.insert(count: records.count, firstPath: records.first?.path))
        insertedRecords.append(contentsOf: records)
    }

    func finalizeSession(_ id: ScanSessionID) async throws {
        events.append(.finalize(id))
    }

    func query(_ q: ScanResultQuery) async throws -> [ScanResultRecord] { [] }

    func aggregate(sessionID: ScanSessionID, parentPath: String?) async throws -> ScanResultAggregate {
        .empty
    }

    func evictSession(_ id: ScanSessionID) async throws {}
    func clearAll() async throws {}

    func snapshotEvents() -> [StoreEvent] { events }
    func snapshotRecords() -> [ScanResultRecord] { insertedRecords }
}

@MainActor
final class StoreWriteOrderingTests: XCTestCase {

    // MARK: - 契约 1：单次 flush 落盘后 store 收到一次 insert

    func test_单次flush之后recorder收到一次insert() async throws {
        let store = OrderRecordingScanResultStore()
        let coord = ScanCoordinator(resultStore: store)
        let sid = ScanSessionID(raw: "S1")
        let records = Self.makeRecords(sid: sid, paths: ["/a", "/b", "/c"])
        coord._seedStoreForTesting(sessionID: sid, storeBatch: records, storeHealthy: true)

        coord._flushStoreBatchForTesting()
        await coord._awaitStoreWriteChainForTesting()

        let events = await store.snapshotEvents()
        XCTAssertEqual(events.count, 1, "1 次 flush 应在 store 上落 1 个 insert event")
        XCTAssertEqual(events.first, .insert(count: 3, firstPath: "/a"))
    }

    // MARK: - 契约 2：多次 flush 必须按入队顺序到达 store（daisychain 保序）

    func test_多次flush必须按入队顺序到达store() async throws {
        let store = OrderRecordingScanResultStore()
        let coord = ScanCoordinator(resultStore: store)
        let sid = ScanSessionID(raw: "S2")
        coord._seedStoreForTesting(sessionID: sid, storeHealthy: true)

        // 入队 5 批，每批一条 path 编号 batch-0..batch-4。daisychain 串行化语义要求
        // store 上观察到的 first-path 也必须严格 batch-0, batch-1, ..., batch-4。
        for i in 0..<5 {
            let recs = Self.makeRecords(sid: sid, paths: ["/batch-\(i)"])
            coord._seedStoreForTesting(storeBatch: recs)
            coord._flushStoreBatchForTesting()
        }
        await coord._awaitStoreWriteChainForTesting()

        let events = await store.snapshotEvents()
        XCTAssertEqual(events.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(events[i], .insert(count: 1, firstPath: "/batch-\(i)"),
                           "事件 #\(i) 必须是 batch-\(i)（daisychain 严格保序契约）")
        }
    }

    // MARK: - 契约 3：finalize 严格在所有已入队 insert 之后

    func test_finalize严格在所有已入队insert之后() async throws {
        let store = OrderRecordingScanResultStore()
        let coord = ScanCoordinator(resultStore: store)
        let sid = ScanSessionID(raw: "S3")
        coord._seedStoreForTesting(sessionID: sid, storeHealthy: true)

        // 入队 3 批 fire-and-forget flush
        for i in 0..<3 {
            let recs = Self.makeRecords(sid: sid, paths: ["/p-\(i)"])
            coord._seedStoreForTesting(storeBatch: recs)
            coord._flushStoreBatchForTesting()
        }
        // 紧跟着 await 版 finalize：daisychain 语义保证 finalize 必须在 3 个 insert 之后。
        await coord._flushAndFinalizeStoreAsyncForTesting()

        let events = await store.snapshotEvents()
        XCTAssertEqual(events.count, 4, "3 insert + 1 finalize")
        for i in 0..<3 {
            XCTAssertEqual(events[i], .insert(count: 1, firstPath: "/p-\(i)"))
        }
        XCTAssertEqual(events.last, .finalize(sid),
                       "finalize 必须出现在所有 insert 之后（防 v1.3.zzz P0-B 退化）")
    }

    // MARK: - 契约 4：flushAndFinalizeStoreAsync 返回时所有写入都已落盘

    func test_flushAndFinalizeAsync返回时所有写入都已落盘() async throws {
        let store = OrderRecordingScanResultStore()
        let coord = ScanCoordinator(resultStore: store)
        let sid = ScanSessionID(raw: "S4")
        coord._seedStoreForTesting(sessionID: sid, storeHealthy: true)

        // 模拟扫描末期：storeBatch 残留 + 链上还有 in-flight 的 fire-and-forget 写
        for i in 0..<2 {
            let recs = Self.makeRecords(sid: sid, paths: ["/inflight-\(i)"])
            coord._seedStoreForTesting(storeBatch: recs)
            coord._flushStoreBatchForTesting()
        }
        // 残留一批未 flush 的，让 finalizeAsync 必须自己消化它
        coord._seedStoreForTesting(
            storeBatch: Self.makeRecords(sid: sid, paths: ["/leftover"]))

        await coord._flushAndFinalizeStoreAsyncForTesting()

        // 关键差异：await 返回时 events 必须**完整**——不能存在"finalizeAsync 返回了但
        // in-flight insert 还没记录"的 race。这正是 v1.3.zzz P0-B 修复的核心契约。
        // events 顺序：2 inflight insert（每次单独一条 event） + 1 leftover insert
        // + 1 finalize = 4 条。flushAndFinalizeStoreAsync 内部对协议层是 insert + finalize
        // 两次独立 actor 调用，不合并（[ScanCoordinator.swift L1942-L1945](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1942-L1945)）。
        let events = await store.snapshotEvents()
        XCTAssertEqual(events.count, 4, "2 inflight insert + 1 leftover insert + 1 finalize")
        XCTAssertEqual(events[0], .insert(count: 1, firstPath: "/inflight-0"))
        XCTAssertEqual(events[1], .insert(count: 1, firstPath: "/inflight-1"))
        XCTAssertEqual(events[2], .insert(count: 1, firstPath: "/leftover"),
                       "leftover insert 必须先于 finalize（串行性保序）")
        XCTAssertEqual(events.last, .finalize(sid),
                       "finalizeAsync 返回时 finalize 事件必须已经完成（防 fire-and-forget 退化）")

        // 落盘记录数：2 inflight + 1 leftover = 3
        let recs = await store.snapshotRecords()
        XCTAssertEqual(recs.count, 3)
        XCTAssertEqual(Set(recs.map(\.path)), ["/inflight-0", "/inflight-1", "/leftover"])
    }

    // MARK: - helpers

    /// 构造最小可用的 ScanResultRecord 列表（不依赖真扫描）。
    private static func makeRecords(sid: ScanSessionID, paths: [String]) -> [ScanResultRecord] {
        paths.map { path in
            ScanResultRecord(
                sessionID: sid,
                path: path,
                isDirectory: false,
                isSymlink: false,
                allocatedSize: 100,
                logicalSize: 100,
                inode: 0,
                device: 0,
                modificationDate: nil,
                parentPath: nil
            )
        }
    }
}
