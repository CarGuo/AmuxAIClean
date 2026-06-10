import XCTest
@testable import SafetyKit

/// Mole 对齐 M3-T6：CleanStatsStore 行为契约。
final class CleanStatsStoreTests: XCTestCase {

    // MARK: - record / totalBytesReclaimed

    func test_空_store_totalBytes_为_0() async {
        let store = CleanStatsStore(storageURL: nil)
        let total = await store.totalBytesReclaimed()
        XCTAssertEqual(total, 0)
    }

    func test_record_累计_total_单调递增() async {
        let store = CleanStatsStore(storageURL: nil)
        await store.record(bytesReclaimed: 1_000, category: "cache")
        await store.record(bytesReclaimed: 2_000, category: "log")
        let total = await store.totalBytesReclaimed()
        XCTAssertEqual(total, 3_000)
    }

    func test_record_0_字节_不入流() async {
        let store = CleanStatsStore(storageURL: nil)
        await store.record(bytesReclaimed: 0, category: "noise")
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func test_record_负数_不入流() async {
        let store = CleanStatsStore(storageURL: nil)
        await store.record(bytesReclaimed: -10, category: "noise")
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - dailyTrend

    func test_dailyTrend_按天聚合_只返回有事件的天() async {
        let store = CleanStatsStore(storageURL: nil)
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        await store.record(bytesReclaimed: 100, category: "a",
                           timestamp: today.addingTimeInterval(60))
        await store.record(bytesReclaimed: 200, category: "b",
                           timestamp: today.addingTimeInterval(3600))
        await store.record(bytesReclaimed: 500, category: "c", timestamp: twoDaysAgo)

        let trend = await store.dailyTrend(days: 7)
        XCTAssertEqual(trend.count, 2, "只有 2 个有事件的天")
        XCTAssertEqual(trend.first?.day, twoDaysAgo)
        XCTAssertEqual(trend.first?.totalBytes, 500)
        XCTAssertEqual(trend.first?.eventCount, 1)
        XCTAssertEqual(trend.last?.day, today)
        XCTAssertEqual(trend.last?.totalBytes, 300)
        XCTAssertEqual(trend.last?.eventCount, 2)
    }

    func test_dailyTrend_排除_window_外的事件() async {
        let store = CleanStatsStore(storageURL: nil)
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let tenDaysAgo = cal.date(byAdding: .day, value: -10, to: today)!

        await store.record(bytesReclaimed: 100, category: "in",
                           timestamp: today.addingTimeInterval(60))
        await store.record(bytesReclaimed: 500, category: "out", timestamp: tenDaysAgo)

        let trend = await store.dailyTrend(days: 7)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend.first?.totalBytes, 100, "10 天前的事件不应进 7 天 window")
    }

    // MARK: - categoryDistribution

    func test_categoryDistribution_全量_按_totalBytes_降序() async {
        let store = CleanStatsStore(storageURL: nil)
        await store.record(bytesReclaimed: 100, category: "cache")
        await store.record(bytesReclaimed: 500, category: "log")
        await store.record(bytesReclaimed: 50,  category: "cache")
        await store.record(bytesReclaimed: 1000, category: "duplicate")

        let dist = await store.categoryDistribution()
        XCTAssertEqual(dist.map(\.category), ["duplicate", "log", "cache"])
        XCTAssertEqual(dist[0].totalBytes, 1000)
        XCTAssertEqual(dist[1].totalBytes, 500)
        XCTAssertEqual(dist[2].totalBytes, 150)
        XCTAssertEqual(dist[2].eventCount, 2)
    }

    func test_categoryDistribution_按_days_过滤() async {
        let store = CleanStatsStore(storageURL: nil)
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let oldDay = cal.date(byAdding: .day, value: -20, to: today)!

        await store.record(bytesReclaimed: 100, category: "recent",
                           timestamp: today.addingTimeInterval(60))
        await store.record(bytesReclaimed: 999, category: "old", timestamp: oldDay)

        let dist = await store.categoryDistribution(days: 7)
        XCTAssertEqual(dist.count, 1)
        XCTAssertEqual(dist.first?.category, "recent")
    }

    // MARK: - reset

    func test_reset_默认保留_lifetime_累计() async {
        let store = CleanStatsStore(storageURL: nil)
        await store.record(bytesReclaimed: 1_000, category: "x")
        await store.reset()
        let total = await store.totalBytesReclaimed()
        let events = await store.events()
        XCTAssertEqual(total, 1_000, "reset 默认不动 lifetime")
        XCTAssertTrue(events.isEmpty)
    }

    func test_reset_alsoResetLifetime_累计归零() async {
        let store = CleanStatsStore(storageURL: nil)
        await store.record(bytesReclaimed: 1_000, category: "x")
        await store.reset(alsoResetLifetime: true)
        let total = await store.totalBytesReclaimed()
        XCTAssertEqual(total, 0)
    }

    // MARK: - retentionDays prune

    func test_retentionDays_落档时丢弃超期事件但保留_lifetime() async {
        let store = CleanStatsStore(storageURL: nil, retentionDays: 7)
        let cal = Calendar(identifier: .gregorian)
        let veryOld = cal.date(byAdding: .day, value: -30, to: Date())!

        // 先手动塞个超期事件（通过正常 record 不行，因为它走当下时间）
        // 改用直接 record 一个最近的，证明老事件 prune；
        // 此 case 通过持久化往返间接覆盖
        await store.record(bytesReclaimed: 100, category: "fresh",
                           timestamp: Date().addingTimeInterval(-60))
        await store.record(bytesReclaimed: 999, category: "stale",
                           timestamp: veryOld)
        // record 后会 prune，stale 应被剔除，但 lifetime 已累计
        let events = await store.events()
        let total = await store.totalBytesReclaimed()
        XCTAssertEqual(events.map(\.category), ["fresh"],
                       "30 天前的事件应被 retention=7 prune 掉")
        XCTAssertEqual(total, 1099, "lifetime 必须保留全部累计")
    }

    // MARK: - 持久化往返

    func test_持久化_文件_往返() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanStatsStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let s1 = CleanStatsStore(storageURL: tmp)
        await s1.record(bytesReclaimed: 1_000, category: "cache")
        await s1.record(bytesReclaimed: 500, category: "log")

        let s2 = CleanStatsStore(storageURL: tmp)
        let total = await s2.totalBytesReclaimed()
        let events = await s2.events()
        XCTAssertEqual(total, 1_500)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.category)), ["cache", "log"])
    }
}
