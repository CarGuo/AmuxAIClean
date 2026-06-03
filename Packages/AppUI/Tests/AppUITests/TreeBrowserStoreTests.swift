import XCTest
import Combine
@testable import AppUI
@testable import ScanKit

/// Step 10b / 2026-06：TreeBrowserStore 契约测试。
///
/// 历史背景：
///   ScanCoordinator 早期把 treeChildrenCache / treeChildrenInFlight + 三层 revision
///   计数器（treeRevision / structuralRevision / tickRevision / childrenCacheVersion）
///   全部直接挂在自身。Step 9a 已把 treeChildrenCache 解耦 @Published，但 4 个 revision
///   字段依然在 ScanCoordinator 上 @Published。Step 10b 抽 TreeBrowserStore 作为 SSOT
///   接口外壳，让新代码 / 单测可单独订阅子 store。
///
/// 解决：
///   1) 新建 [TreeBrowserStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift)
///      持有 cache / inflight + 4 个 revision，提供 bumpStructuralRevision /
///      bumpTickRevision / bumpChildrenCacheVersion。
///   2) ScanCoordinator 暴露 `public let treeBrowser: TreeBrowserStore`，
///      并在自身 bump* 三个 helper 中**双写到 store**（store 与 mirror 同步）。
///   3) ScanCoordinator 上原有同名字段保留作 @Published mirror（向后兼容）。
///
/// 本套测试覆盖：store 字段初始值 + 三个 bump 单独行为 + ScanCoordinator bump 时
/// store 与 mirror 同步推进。
@MainActor
final class TreeBrowserStoreTests: XCTestCase {

    // MARK: - 字段存在性

    func test_TreeBrowserStore初始4个revision字段都为0() {
        let store = TreeBrowserStore()
        XCTAssertEqual(store.treeRevision, 0, "新建 store treeRevision 起点必须为 0")
        XCTAssertEqual(store.structuralRevision, 0, "新建 store structuralRevision 起点必须为 0")
        XCTAssertEqual(store.tickRevision, 0, "新建 store tickRevision 起点必须为 0")
        XCTAssertEqual(store.childrenCacheVersion, 0, "新建 store childrenCacheVersion 起点必须为 0")
        XCTAssertTrue(store.treeChildrenCache.isEmpty, "新建 store cache 必须为空")
        XCTAssertTrue(store.treeChildrenInFlight.isEmpty, "新建 store inflight 必须为空")
    }

    func test_ScanCoordinator暴露treeBrowser子store() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        XCTAssertNotNil(coord.treeBrowser, "ScanCoordinator 必须暴露 treeBrowser 子 store")
        XCTAssertEqual(coord.treeBrowser.treeRevision, 0)
        XCTAssertEqual(coord.treeBrowser.structuralRevision, 0)
    }

    // MARK: - bump 行为

    /// bumpStructuralRevision 同时推 structuralRevision + tickRevision + treeRevision。
    func test_bumpStructuralRevision推三个字段() {
        let store = TreeBrowserStore()
        store.bumpStructuralRevision()
        XCTAssertEqual(store.structuralRevision, 1, "structuralRevision 必须 +1")
        XCTAssertEqual(store.tickRevision, 1, "tickRevision 必须 +1（任何 structural 隐含一次 tick）")
        XCTAssertEqual(store.treeRevision, 1, "treeRevision 必须 +1（兼容老订阅者）")
    }

    /// bumpTickRevision 仅推 tickRevision + treeRevision，不动 structuralRevision。
    func test_bumpTickRevision不动structuralRevision() {
        let store = TreeBrowserStore()
        store.bumpTickRevision()
        XCTAssertEqual(store.structuralRevision, 0, "tick 不能升格为 structural")
        XCTAssertEqual(store.tickRevision, 1)
        XCTAssertEqual(store.treeRevision, 1)
    }

    /// bumpChildrenCacheVersion 仅推 cacheVersion，与 revision 解耦。
    func test_bumpChildrenCacheVersion独立() {
        let store = TreeBrowserStore()
        store.bumpChildrenCacheVersion()
        XCTAssertEqual(store.childrenCacheVersion, 1)
        XCTAssertEqual(store.structuralRevision, 0, "cache 写入不应升 structural")
        XCTAssertEqual(store.tickRevision, 0, "cache 写入不应升 tick")
    }

    // MARK: - ScanCoordinator 与 store 同步契约

    /// 一次完整扫描完成后，coord 上的 mirror 与 store 上的 SSOT 必须同步推进。
    func test_扫描期间coord的mirror与store同步() async throws {
        let home = try makeFakeHome(leafCount: 3)
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)

        await waitUntil(8) { !coord.isScanning && coord.structuralRevision >= 1 }

        XCTAssertEqual(
            coord.structuralRevision, coord.treeBrowser.structuralRevision,
            "扫描结束后 coord.structuralRevision 必须与 store.structuralRevision 同值"
        )
        XCTAssertEqual(
            coord.tickRevision, coord.treeBrowser.tickRevision,
            "tickRevision 同样需要同步"
        )
        XCTAssertEqual(
            coord.treeRevision, coord.treeBrowser.treeRevision,
            "treeRevision 同样需要同步"
        )
        XCTAssertEqual(
            coord.childrenCacheVersion, coord.treeBrowser.childrenCacheVersion,
            "childrenCacheVersion 同样需要同步"
        )
    }

    // MARK: - Fixture helpers

    private func makeFakeHome(leafCount: Int) throws -> String {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "GSYCleanTreeStore-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        let cache = home + "/Library/Caches/com.example.treestore"
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        for i in 0..<leafCount {
            let p = cache + "/leaf-\(i).bin"
            try Data(repeating: 0x42, count: 1024).write(to: URL(fileURLWithPath: p))
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
