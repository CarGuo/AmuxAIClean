import XCTest
@testable import AppUI
@testable import ScanKit

/// Step 9a / 2026-06：treeChildrenCache 解耦 @Published 契约测试。
///
/// 历史背景：
///   `treeChildrenCache: [String: [TreeRow]]` 早期标了 `@Published` —— 任何字典写入都会
///   触发 ScanCoordinator.objectWillChange，无差别让所有订阅 view（MainView 主列表、
///   SystemProbe banner、UndoHistory toolbar 等）跟着重算一帧。但实际只有 TreeBrowserView
///   关心 cache 是否更新，并且 TreeBrowserView 已经通过 [structuralRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
///   订阅"节点拓扑变化"信号。
///
/// 解决：
///   1) `treeChildrenCache` 改普通字典（去掉 @Published）。
///   2) 新增 `childrenCacheVersion: UInt64` 计数器（保持 @Published 给单元测试 / 未来细粒度刷新留 hook）。
///   3) 所有原本写 cache 的位置（写新键 / removeAll / patch-by-prune）必须串到
///      [bumpChildrenCacheVersion()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 单点收敛。
///
/// 本套测试只覆盖"version 自增是否符合契约"——TreeBrowserView 订阅切换不在本范围。
@MainActor
final class ScanCoordinatorCacheVersionTests: XCTestCase {

    // MARK: - 字段存在性

    func test_ScanCoordinator暴露childrenCacheVersion字段() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let v: UInt64 = coord.childrenCacheVersion
        XCTAssertEqual(v, 0, "新建 ScanCoordinator 时 childrenCacheVersion 起点必须为 0")
    }

    // MARK: - 行为契约

    /// 启动一次扫描后，childrenCacheVersion 至少 &+= 1（startScan 清 cache 是版本变化）。
    /// 这是兜底契约：保证 cache 失效路径都串到了 bumpChildrenCacheVersion。
    func test_启动扫描会推动childrenCacheVersion() async throws {
        let home = try makeFakeHome(leafCount: 2)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        let before = coord.childrenCacheVersion
        coord.scanRecommended(includeHidden: true)

        await waitUntil(3) { coord.childrenCacheVersion != before || !coord.isScanning }
        XCTAssertGreaterThan(
            coord.childrenCacheVersion, before,
            "scanRecommended 启动同帧会清空 treeChildrenCache —— 必须推 childrenCacheVersion"
        )
    }

    /// 一次完整扫描结束后，childrenCacheVersion 应至少经历过 startScan 清空 + finalize 后清空。
    /// 即至少 +2。
    func test_扫描结束后childrenCacheVersion多次推进() async throws {
        let home = try makeFakeHome(leafCount: 4)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        let before = coord.childrenCacheVersion
        coord.scanRecommended(includeHidden: true)

        await waitUntil(8) { !coord.isScanning && coord.childrenCacheVersion >= before + 2 }

        XCTAssertGreaterThanOrEqual(
            coord.childrenCacheVersion, before + 2,
            "scan 启动 + finalize 后 invalidateTreeCacheAfterScan 至少各推一次，version 总增量 ≥ 2"
        )
    }

    // MARK: - Fixture helpers

    private func makeFakeHome(leafCount: Int) throws -> String {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "GSYCleanCacheVer-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        let cache = home + "/Library/Caches/com.example.cachever"
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
}
