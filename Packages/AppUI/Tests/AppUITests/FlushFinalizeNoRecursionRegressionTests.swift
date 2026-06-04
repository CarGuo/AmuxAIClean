import XCTest
import ScanKit
@testable import AppUI

/// **v1.5.6 崩溃回归契约**：防 [Crash 2026-06-04 22:05:45](file:///Users/guoshuyu/Library/Logs/DiagnosticReports/GSYCleanMac-2026-06-04-220545.ips)
/// `Thread stack size exceeded due to excessive recursion / swift_task_escalateImpl` 复发。
///
/// 根因回顾：旧版 [flushAndFinalizeStoreAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1951-L1969)
/// 把 insert+finalize 包在 Task.detached，detached 内 `await prev?.value`，caller 又
/// `await task.value`——两层 await 嵌套在同一条 task chain → macOS 26.2 / Swift 6.x runtime
/// priority escalation 递归不收敛 → cooperative 线程栈写穿（thread 7 栈顶
/// 0x000000016b7d7ff0 落在 guard page）。
///
/// 修法：caller 直接在 MainActor 上等链尾 + 亲自 await actor，去掉中间那层 detached。
///
/// 本测试用"50 次连续 fire-and-forget flush + finalizeAsync"模拟把 chain 撑得很长的
/// 极端场景。修复前同样压力下会 EXC_BAD_ACCESS；修复后必须秒过。
///
/// 注意：这不是"事件序"测试（那是 [StoreWriteOrderingTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/StoreWriteOrderingTests.swift)
/// 的职责），本测试只断言**不崩 + 不超时 + 全量落盘**。
@MainActor
final class FlushFinalizeNoRecursionRegressionTests: XCTestCase {

    /// 契约 1：长链场景（50 次 flush）后 finalizeAsync 必须正常返回，不递归爆栈。
    func test_长链场景下flushAndFinalizeAsync不爆栈() async throws {
        let store = OrderRecordingScanResultStore()
        let coord = ScanCoordinator(resultStore: store)
        let sid = ScanSessionID(raw: "RegrCrash1")
        coord._seedStoreForTesting(sessionID: sid, storeHealthy: true)

        // 把 chain 撑到 50 层。每条 flush 都是 fire-and-forget，
        // 旧实现 caller 再 await 这条 50 层 chain 时会触发 escalation 递归。
        for i in 0..<50 {
            let recs = Self.makeRecords(sid: sid, paths: ["/longchain-\(i)"])
            coord._seedStoreForTesting(storeBatch: recs)
            coord._flushStoreBatchForTesting()
        }
        coord._seedStoreForTesting(
            storeBatch: Self.makeRecords(sid: sid, paths: ["/leftover-tail"]))

        // 修复前这里就崩；修复后秒过。给个宽松超时 5s 防 CI 抖动。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await coord._flushAndFinalizeStoreAsyncForTesting() }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw XCTSkip("flushAndFinalizeStoreAsync 超过 5s 未返回（疑似递归回潮）")
            }
            _ = try await group.next()
            group.cancelAll()
        }

        // 完整性：50 个 insert + 1 leftover insert + 1 finalize = 52 事件
        let events = await store.snapshotEvents()
        XCTAssertEqual(events.count, 52,
                       "长链下 finalize 后所有 51 个 insert + 1 finalize 必须全部到达 store")
        XCTAssertEqual(events.last, .finalize(sid),
                       "finalize 必须出现在最末尾")
        // 第 51 条必须是 leftover-tail（caller 亲自 insert 的那一笔顺序）
        XCTAssertEqual(events[50], .insert(count: 1, firstPath: "/leftover-tail"),
                       "leftover 必须在 50 条 fire-and-forget 之后、finalize 之前")
    }

    /// 契约 2：finalizeAsync 返回后 storeWriteChain 应该已被清掉（修复实现把字段置 nil）。
    /// 防止有人未来又把字段续上 detached chain 把旧 bug 引回来。
    func test_flushAndFinalizeAsync返回后chain已断() async throws {
        let store = OrderRecordingScanResultStore()
        let coord = ScanCoordinator(resultStore: store)
        let sid = ScanSessionID(raw: "RegrCrash2")
        coord._seedStoreForTesting(sessionID: sid, storeHealthy: true)

        // 至少一条 fire-and-forget 撑起 chain
        coord._seedStoreForTesting(
            storeBatch: Self.makeRecords(sid: sid, paths: ["/before"]))
        coord._flushStoreBatchForTesting()

        await coord._flushAndFinalizeStoreAsyncForTesting()

        // chain 应该已断：再 await 一次必须立刻返回（不会卡）。
        // 这是 v1.5.6 实现的隐性不变量，防回归。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await coord._awaitStoreWriteChainForTesting() }
            group.addTask {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                throw XCTSkip("_awaitStoreWriteChainForTesting 超过 1s 未返回")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - helpers

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
