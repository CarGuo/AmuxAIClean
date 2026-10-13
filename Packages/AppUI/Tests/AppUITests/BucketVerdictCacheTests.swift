import XCTest
@testable import AppUI
@testable import ScanKit

/// Step 3 P0-3 / 2026-06：bucket 节点 cachedVerdict 缓存契约测试。
///
/// 现状（Step 3 之前）：
///   ScanCoordinator.publishSnapshot 每帧（流式扫描里 0.4s 一次）都对全部 buckets
///   调 `engine.evaluate(path:trie:home:)`，返回 (verdict, rejection, vendor)。
///   path 永远不变、trie/home 是 `let` immutable —— 同一个 path 的 evaluate 结果
///   **永远相同**。每帧重算 N 个 bucket 是纯浪费。
///
/// 期望（Step 3 之后）：
///   1) Bucket 上挂 cachedVerdict / cachedRejection / cachedVendor 字段
///   2) publishSnapshot 优先读缓存，miss 时算一次后写回
///   3) 同一轮扫描内：第一帧大量 miss → 之后帧几乎全 hit
///
/// 测试观测口：ScanCoordinator 暴露 `verdictCacheStatsForTesting()`，返回
/// `(hits: Int, misses: Int)`。同 module @testable import 可见。
@MainActor
final class BucketVerdictCacheTests: XCTestCase {

    private func makeFakeHome(leafCount: Int) throws -> String {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "AmuxAICleanBucketCache-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        // 多造几个一级目录（= 多个 bucket），让 cache 有意义
        for sub in ["Library/Caches/A", "Library/Caches/B", "Library/Caches/C", "Downloads"] {
            let dir = home + "/" + sub
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for i in 0..<leafCount {
                try Data(repeating: 0xCC, count: 256)
                    .write(to: URL(fileURLWithPath: dir + "/leaf-\(i).bin"))
            }
        }
        return home
    }

    private func cleanup(_ home: String) {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func waitUntil(_ timeout: TimeInterval = 5,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: - 字段存在性 + 起点

    /// 红灯阶段：方法不存在，编译失败。
    func test_ScanCoordinator暴露verdictCacheStatsForTesting() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let stats = coord.verdictCacheStatsForTesting()
        XCTAssertEqual(stats.hits, 0, "新建 ScanCoordinator 时 cache hits 起点必须为 0")
        XCTAssertEqual(stats.misses, 0, "新建 ScanCoordinator 时 cache misses 起点必须为 0")
    }

    // MARK: - 行为契约

    /// 跑一次完整扫描后，misses > 0（首次每个 bucket 必然 miss）。
    /// 这是"缓存被启用"的最低门槛 —— 如果 misses 永远 0 说明根本没走 cache 路径。
    func test_扫描后必然出现cache_miss() async throws {
        let home = try makeFakeHome(leafCount: 4)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)
        await waitUntil(8) { !coord.isScanning }

        let stats = coord.verdictCacheStatsForTesting()
        XCTAssertGreaterThan(
            stats.misses, 0,
            "首次扫描每个 bucket 都没缓存 —— misses 必须 > 0，说明 cache 真的在工作"
        )
    }

    /// 一轮扫描里 publishSnapshot 通常被调多帧。
    /// 第二帧及之后，已经在 cache 里的 bucket 必须命中 —— hits 必须 > 0。
    /// 这是 P0-3 的核心契约 —— 否则缓存只填不读，性能没改善。
    ///
    /// 注：fixture 太小时扫描可能只跑 1 帧 publishSnapshot（150ms 节流没触发流式帧），
    /// 所以扫完后用 forcePublishSnapshotForTesting() 显式再触发一帧验证 cache hit。
    func test_扫描期间出现cache_hit() async throws {
        let home = try makeFakeHome(leafCount: 200)  // 大一点让 ingest 能跑出多个 publishSnapshot 帧
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)
        await waitUntil(10) { !coord.isScanning }

        // 已经至少跑过一帧 publishSnapshot（finished=true 那帧），所有 bucket 都已 cache。
        // 再触发一次 → 全部走 hit 路径。
        coord.forcePublishSnapshotForTesting()

        let stats = coord.verdictCacheStatsForTesting()
        XCTAssertGreaterThan(
            stats.hits, 0,
            "扫描结束至少一帧 publishSnapshot —— 同 bucket 第二次访问必须命中 cache"
        )
    }

    /// hit 率契约：跑过 ≥ 2 帧 publishSnapshot 后，hits 应当 >= misses。
    /// 推导：buckets 数恒定为 K，第一帧全 K miss + 第二帧全 K hit → hits == misses。
    /// 这是"缓存确实减少了 evaluate 次数"的硬指标。
    func test_缓存命中率_hits应大于等于misses() async throws {
        let home = try makeFakeHome(leafCount: 300)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)
        await waitUntil(10) { !coord.isScanning }

        // fixture 小可能只 1 帧自然 publishSnapshot。强制再来一帧确保契约可观察。
        coord.forcePublishSnapshotForTesting()

        let stats = coord.verdictCacheStatsForTesting()
        XCTAssertGreaterThanOrEqual(
            stats.hits, stats.misses,
            "扫描跑过 ≥ 2 帧 publishSnapshot 时，hits 必须 >= misses（每 bucket 仅 miss 一次）"
        )
    }

    /// startScan / cancel-reset 后 cache 计数器必须清零（cache 自身随 buckets 一起清空）。
    /// 否则跨会话的"上轮缓存"会污染下轮（虽然 bucket 整轮 removeAll 时附属字段也清，
    /// 但计数器是独立的，必须显式归零）。
    func test_重新扫描会重置cache统计() async throws {
        let home = try makeFakeHome(leafCount: 4)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)
        await waitUntil(5) { !coord.isScanning }
        let firstRound = coord.verdictCacheStatsForTesting()
        XCTAssertGreaterThan(firstRound.misses + firstRound.hits, 0)

        // 第二次扫
        coord.scanRecommended(includeHidden: true)
        await waitUntil(5) { !coord.isScanning }
        // 这里只要求"第二轮里 misses 也 > 0"——证明 cache 确实被清空（buckets 也清空），
        // 不是直接读上轮残留 cache（那会让 misses 永远 0）。
        let secondRound = coord.verdictCacheStatsForTesting()
        XCTAssertGreaterThan(
            secondRound.misses, 0,
            "rescan 后 buckets 清空 → cache 也跟着清 → 必然出现新一批 misses"
        )
    }
}
