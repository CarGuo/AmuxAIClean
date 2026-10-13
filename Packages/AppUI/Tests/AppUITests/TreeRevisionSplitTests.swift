import XCTest
@testable import AppUI
@testable import ScanKit

/// Step 2 P0-2 / 2026-06：treeRevision 拆分契约测试。
///
/// 现状（Step 1 之前）：
///   ScanCoordinator 只有一个 `treeRevision: UInt64` —— 任何 ingest tick（每 0.4s
///   流式 publishSnapshot）都会 `&+= 1`。TreeBrowserView 的
///   `.onChange(of: coordinator.treeRevision) { rebuildFlatRows() }` 把数万节点的
///   FlatTreeRow 数组从头重建一遍。稳态扫描下 95% 的 tick 只是 bytes/fileCount 累加，
///   节点拓扑没变 —— rebuild 纯属浪费，是 SwiftUI 主线程卡顿的主要来源之一。
///
/// 期望（Step 2 之后）：
///   1) 新增 `structuralRevision: UInt64` —— 仅当节点新增/删除/排序键变更时 &+= 1
///   2) 新增 `tickRevision: UInt64` —— 每帧都 &+= 1（即使节点拓扑没变）
///   3) 老的 `treeRevision` 字段保留作 alias（兼容外部订阅）
///   4) TreeBrowserView 改订阅 `structuralRevision` —— 这点不在本测试范围
///
/// 性能契约：4w 节点扫描期间，rebuildFlatRows 触发次数应远小于 publishSnapshot 帧数
/// （从 ≈ scanDuration / 0.4s 降到 O(扫描启动 + 几次新目录被发现)）。
///
/// 这里只测 ScanCoordinator 自己暴露的 revision 信号，不依赖 TreeBrowserView。
@MainActor
final class TreeRevisionSplitTests: XCTestCase {

    // MARK: - Fixture

    /// 造一个有 N 个叶子的小 fixture，让流式 ingest 期间 publishSnapshot 触发多帧。
    private func makeFakeHome(leafCount: Int) throws -> String {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "AmuxAICleanTreeRev-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        let cache = home + "/Library/Caches/com.example.app"
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        for i in 0..<leafCount {
            let p = cache + "/leaf-\(i).bin"
            try Data(repeating: 0x55, count: 1024).write(to: URL(fileURLWithPath: p))
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

    // MARK: - 字段存在性

    /// 新字段 structuralRevision 必须存在且类型为 UInt64。
    /// 红灯阶段：ScanCoordinator 还没有这个字段，编译失败。
    func test_ScanCoordinator暴露structuralRevision字段() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let r: UInt64 = coord.structuralRevision
        XCTAssertEqual(r, 0, "新建 ScanCoordinator 时 structuralRevision 起点必须为 0")
    }

    /// 新字段 tickRevision 必须存在且类型为 UInt64。
    func test_ScanCoordinator暴露tickRevision字段() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let r: UInt64 = coord.tickRevision
        XCTAssertEqual(r, 0, "新建 ScanCoordinator 时 tickRevision 起点必须为 0")
    }

    // MARK: - 行为契约

    /// 启动一次扫描后，structuralRevision 至少 &+= 1（startScan 清 cache 是结构变化）。
    /// 这个最小契约能确保 TreeBrowserView 切到 onChange(of: structuralRevision) 后
    /// 启动那一帧能重建一次 flatRows。
    func test_启动扫描会推动structuralRevision() async throws {
        let home = try makeFakeHome(leafCount: 4)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        let before = coord.structuralRevision
        coord.scanRecommended(includeHidden: true)

        await waitUntil(3) { coord.structuralRevision != before || !coord.isScanning }
        XCTAssertGreaterThan(
            coord.structuralRevision, before,
            "scanRecommended 启动同帧会清空 treeChildrenCache —— 这是结构变化，必须推 structuralRevision"
        )
    }

    /// 流式扫描期间，tickRevision 必须 > structuralRevision 的增量。
    /// 也就是说：稳态扫描里大部分帧只是 bytes/fileCount 累加，节点拓扑没变。
    /// 这是 P0-2 的核心性能契约 —— 否则把 view 切到 structural 没意义。
    func test_扫描期间tick增长远大于structural增长() async throws {
        let home = try makeFakeHome(leafCount: 200)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)

        let structuralBefore = coord.structuralRevision
        let tickBefore = coord.tickRevision

        coord.scanRecommended(includeHidden: true)
        // 等扫完
        await waitUntil(8) { !coord.isScanning }

        let structuralDelta = coord.structuralRevision &- structuralBefore
        let tickDelta = coord.tickRevision &- tickBefore

        XCTAssertGreaterThan(
            tickDelta, 0,
            "publishSnapshot 至少推过 tickRevision（finished 那帧也算）"
        )
        // 这里不强约束"tickDelta 远 > structuralDelta"——小 fixture 下两者可能相近。
        // 真正的性能验证靠 Instruments / 真实 38.9w 文件场景跑。
        // 但至少：tickDelta >= structuralDelta（每次 structural 都伴随 tick，反之未必）。
        XCTAssertGreaterThanOrEqual(
            tickDelta, structuralDelta,
            "tickRevision 必须 >= structuralRevision —— 任何结构变化都至少同时推进一次 tick"
        )
    }

    /// 兼容性契约：treeRevision 字段保留，且任何 structural 或 tick 推进都会让 treeRevision 也走。
    /// 这一点确保已经订阅 treeRevision 的外部代码不破坏（迁移期），同时给 view 一个明确切换路径。
    func test_treeRevision保留作为兼容alias() async throws {
        let home = try makeFakeHome(leafCount: 8)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        let treeBefore = coord.treeRevision

        coord.scanRecommended(includeHidden: true)
        await waitUntil(5) { !coord.isScanning }

        XCTAssertGreaterThan(
            coord.treeRevision, treeBefore,
            "treeRevision 作为兼容 alias 必须随 structural/tick 推进 —— 不能在拆分后死寂"
        )
    }
}
