import XCTest
import Combine
import Darwin
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

    func test_子层cache写回会同步修正父层聚合避免父目录0KB() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let parentPath = "/Users/guoshuyu"
        let libraryPath = parentPath + "/Library"
        coord._seedForTesting(
            isScanning: false,
            treeChildrenCache: [
                "\(parentPath)|\(TreeSortKey.sizeDesc.rawValue)": [
                    TreeRow(
                        path: libraryPath,
                        title: "Library",
                        bytes: 0,
                        fileCount: 1,
                        isDirectory: true,
                        hasChildren: true
                    )
                ]
            ]
        )

        coord._storeFetchedChildrenForTesting(
            path: libraryPath,
            sortedBy: .sizeDesc,
            rows: [
                TreeRow(path: libraryPath + "/Developer",
                        title: "Developer",
                        bytes: 22_000_000_000,
                        fileCount: 1_190,
                        isDirectory: true,
                        hasChildren: true),
                TreeRow(path: libraryPath + "/Updates",
                        title: "Updates",
                        bytes: 943_100_000,
                        fileCount: 14,
                        isDirectory: true,
                        hasChildren: false)
            ]
        )

        let cache = coord._treeChildrenCacheForTesting()
        let parentRows = cache["\(parentPath)|\(TreeSortKey.sizeDesc.rawValue)"] ?? []
        let library = parentRows.first { $0.path == libraryPath }
        XCTAssertEqual(library?.bytes, 22_943_100_000)
        XCTAssertEqual(library?.fileCount, 1_204)
        XCTAssertTrue(library?.hasChildren == true)
    }

    /// v2026.07.17：完整 refresh 必须是“当前快照替换旧快照”，不能继续使用
    /// max(old, new)。否则目录内容被外部清理后，Tree 容量会永久只增不减。
    func test_完整子层refresh会让父行容量与数量同步缩小() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let grandparent = "/Users/example"
        let parent = grandparent + "/Library"
        let oldParent = TreeRow(
            path: parent,
            title: "Library",
            bytes: 9_000,
            logicalBytes: 12_000,
            fileCount: 90,
            isDirectory: true,
            hasChildren: true
        )
        coord._seedForTesting(
            isScanning: false,
            treeChildrenCache: [
                "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)": [oldParent],
                "\(grandparent)|\(TreeSortKey.nameAsc.rawValue)": [oldParent]
            ]
        )

        coord._storeFetchedChildrenForTesting(
            path: parent,
            sortedBy: .sizeDesc,
            rows: [
                TreeRow(
                    path: parent + "/Caches",
                    title: "Caches",
                    bytes: 700,
                    logicalBytes: 900,
                    fileCount: 7,
                    isDirectory: true,
                    hasChildren: true
                ),
                TreeRow(
                    path: parent + "/state.db",
                    title: "state.db",
                    bytes: 100,
                    logicalBytes: 150,
                    fileCount: 1,
                    isDirectory: false,
                    hasChildren: false
                )
            ]
        )

        let cache = coord._treeChildrenCacheForTesting()
        for sortKey in [TreeSortKey.sizeDesc, .nameAsc] {
            let refreshed = cache["\(grandparent)|\(sortKey.rawValue)"]?.first {
                $0.path == parent
            }
            XCTAssertEqual(refreshed?.bytes, 800)
            XCTAssertEqual(refreshed?.logicalBytes, 1_050)
            XCTAssertEqual(refreshed?.fileCount, 8)
            XCTAssertEqual(refreshed?.hasChildren, true)
            XCTAssertEqual(refreshed?.isSizePending, false)
        }
    }

    func test_完整子层refresh为空时父行归零并移除展开状态() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let grandparent = "/Users/example"
        let parent = grandparent + "/Library"
        coord._seedForTesting(
            isScanning: false,
            treeChildrenCache: [
                "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)": [
                    TreeRow(
                        path: parent,
                        title: "Library",
                        bytes: 9_000,
                        logicalBytes: 12_000,
                        fileCount: 90,
                        isDirectory: true,
                        hasChildren: true
                    )
                ]
            ]
        )

        coord._storeFetchedChildrenForTesting(path: parent, sortedBy: .sizeDesc, rows: [])

        let refreshed = coord._treeChildrenCacheForTesting()[
            "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)"
        ]?.first
        XCTAssertEqual(refreshed?.bytes, 0)
        XCTAssertEqual(refreshed?.logicalBytes, 0)
        XCTAssertEqual(refreshed?.fileCount, 0)
        XCTAssertEqual(refreshed?.hasChildren, false)
        XCTAssertEqual(refreshed?.isSizePending, false)
    }

    func test_shallow预览只提供下界不会把父行容量提前缩小() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let grandparent = "/Users/example"
        let parent = grandparent + "/Library"
        coord._seedForTesting(
            isScanning: false,
            treeChildrenCache: [
                "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)": [
                    TreeRow(
                        path: parent,
                        title: "Library",
                        bytes: 9_000,
                        logicalBytes: 12_000,
                        fileCount: 90,
                        isDirectory: true,
                        hasChildren: true
                    )
                ]
            ]
        )

        coord._storeShallowFetchedChildrenForTesting(
            path: parent,
            sortedBy: .sizeDesc,
            rows: [
                TreeRow(
                    path: parent + "/visible.bin",
                    title: "visible.bin",
                    bytes: 100,
                    logicalBytes: 120,
                    fileCount: 1,
                    isDirectory: false,
                    hasChildren: false
                )
            ]
        )

        let preview = coord._treeChildrenCacheForTesting()[
            "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)"
        ]?.first
        XCTAssertEqual(preview?.bytes, 9_000)
        XCTAssertEqual(preview?.logicalBytes, 12_000)
        XCTAssertEqual(preview?.fileCount, 90)
        XCTAssertEqual(preview?.isSizePending, true)
    }

    func test_partial深扫只提供下界不会把权限缺口误报为空间释放() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        let grandparent = "/Users/example"
        let parent = grandparent + "/Library"
        coord._seedForTesting(
            isScanning: false,
            treeChildrenCache: [
                "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)": [
                    TreeRow(
                        path: parent,
                        title: "Library",
                        bytes: 9_000,
                        logicalBytes: 12_000,
                        fileCount: 90,
                        isDirectory: true,
                        hasChildren: true
                    )
                ]
            ]
        )

        coord._storePartialFetchedChildrenForTesting(
            path: parent,
            sortedBy: .sizeDesc,
            rows: [
                TreeRow(
                    path: parent + "/visible.bin",
                    title: "visible.bin",
                    bytes: 100,
                    logicalBytes: 120,
                    fileCount: 1,
                    isDirectory: false,
                    hasChildren: false,
                    subtreeCompleteness: .containsIncompleteDescendant
                )
            ]
        )

        let partial = coord._treeChildrenCacheForTesting()[
            "\(grandparent)|\(TreeSortKey.sizeDesc.rawValue)"
        ]?.first
        XCTAssertEqual(partial?.bytes, 9_000)
        XCTAssertEqual(partial?.logicalBytes, 12_000)
        XCTAssertEqual(partial?.fileCount, 90)
        XCTAssertEqual(partial?.isSizePending, false)
    }

    func test_真实按需refresh在文件清空后把祖先cache容量降为零() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TreeRefreshShrink-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("Cache", isDirectory: true)
        let file = parent.appendingPathComponent("payload.bin")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 32 * 1_024).write(to: file)
        defer { try? fm.removeItem(at: root) }

        let coord = ScanCoordinator(home: root.path, enableTreeDeepIndex: false)
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "tree.refresh.shrink",
                rows: [],
                totalBytes: 32 * 1_024,
                scannedFileCount: 1,
                isFinished: true,
                elapsed: 0
            ),
            currentRootPath: root.path,
            isScanning: false,
            treeChildrenCache: [
                "\(root.path)|\(TreeSortKey.sizeDesc.rawValue)": [
                    TreeRow(
                        path: parent.path,
                        title: parent.lastPathComponent,
                        bytes: 32 * 1_024,
                        fileCount: 1,
                        isDirectory: true,
                        hasChildren: true
                    )
                ]
            ]
        )

        _ = coord.directChildren(of: parent.path, sortedBy: .sizeDesc)
        await waitUntil(3) {
            !coord._treeChildrenInFlightForTesting().contains {
                $0.hasPrefix(parent.path + "|")
            }
        }
        XCTAssertGreaterThan(
            coord._treeChildrenCacheForTesting()[
                "\(root.path)|\(TreeSortKey.sizeDesc.rawValue)"
            ]?.first?.bytes ?? 0,
            0
        )

        try fm.removeItem(at: file)
        coord.rescanSubtree(at: parent.path)
        _ = coord.directChildren(of: parent.path, sortedBy: .sizeDesc)
        await waitUntil(3) {
            let cache = coord._treeChildrenCacheForTesting()
            let completed = !coord._treeChildrenInFlightForTesting().contains {
                $0.hasPrefix(parent.path + "|")
            }
            return completed && cache["\(parent.path)|\(TreeSortKey.sizeDesc.rawValue)"] != nil
        }

        let refreshedParent = coord._treeChildrenCacheForTesting()[
            "\(root.path)|\(TreeSortKey.sizeDesc.rawValue)"
        ]?.first { $0.path == parent.path }
        XCTAssertEqual(refreshedParent?.bytes, 0)
        XCTAssertEqual(refreshedParent?.fileCount, 0)
        XCTAssertEqual(refreshedParent?.hasChildren, false)
        XCTAssertEqual(refreshedParent?.isSizePending, false)
    }

    func test_离开Tree只取消按需磁盘任务且保留完成快照() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TreeOwnership-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let snapshot = ScanSnapshot(
            categoryID: "tree.ownership",
            rows: [],
            totalBytes: 4_096,
            scannedFileCount: 1,
            isFinished: true,
            elapsed: 0
        )
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: false)
        coordinator._seedForTesting(
            snapshot: snapshot,
            currentRootPath: root.path,
            isScanning: false,
            treeChildrenCache: [
                "\(root.path)|\(TreeSortKey.sizeDesc.rawValue)": [
                    TreeRow(
                        path: child.path,
                        title: child.lastPathComponent,
                        bytes: 4_096,
                        fileCount: 1,
                        isDirectory: true,
                        hasChildren: true
                    )
                ]
            ]
        )

        _ = coordinator.directChildren(of: child.path, sortedBy: .sizeDesc)
        XCTAssertFalse(coordinator._treeChildrenInFlightForTesting().isEmpty)

        coordinator.cancelOnDemandTreeScansPreservingResults()
        await Task.yield()

        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty)
        XCTAssertEqual(coordinator.snapshot, snapshot)
        XCTAssertEqual(coordinator.currentRootPath, root.path)
        XCTAssertFalse(coordinator.wasCancelled)
    }

    /// v2026.07.17 删除安全回归：Tree 展开后新发现的缺口不能只画在行上。
    /// 它必须进入 ScanCoordinator 的 typed evidence，供统一删除预检做祖先/后代重叠判定；
    /// 同一 fetch root 的新终态必须替换旧终态，且不得清掉主扫描的独立证据。
    func test_按需Tree缺口进入删除预检且按fetchRoot替换() {
        let coord = ScanCoordinator(home: "/Users/example")
        let primary = ScanIncompleteIssue(
            path: "/Users/example/Library/PrimaryLocked",
            reason: .permissionDenied,
            stage: .open,
            posixErrorCode: EACCES
        )
        coord._testReplaceIncompleteEvidence([primary])

        let treeRoot = "/Users/example/Library/Caches"
        let oldTreeIssue = ScanIncompleteIssue(
            path: treeRoot + "/OldLocked",
            reason: .permissionDenied,
            stage: .open,
            posixErrorCode: EACCES
        )
        coord._replaceTreeIncompleteEvidenceForTesting(
            rootPath: treeRoot,
            issues: [
                ScanIncompleteIssue(
                    path: oldTreeIssue.path,
                    reason: .permissionDenied
                ),
                oldTreeIssue
            ]
        )

        XCTAssertEqual(
            Set(coord.incompleteIssues(overlappingAny: [treeRoot])),
            Set([oldTreeIssue]),
            "Tree local issue 必须进入和删除目标同一条 typed overlap 链路"
        )
        XCTAssertEqual(coord._testAccessState(for: oldTreeIssue.path), .permissionDenied)
        XCTAssertEqual(
            coord.incompleteScanIssues.filter {
                $0.path == oldTreeIssue.path && $0.reason == .permissionDenied
            },
            [oldTreeIssue],
            "无 stage companion event 不得与丰富 typed issue 重复展示"
        )
        XCTAssertTrue(coord.incompleteScanIssues.contains(primary))

        let refreshedIssue = ScanIncompleteIssue(
            path: treeRoot + "/MetadataLost",
            reason: .metadataUnavailable,
            stage: .metadata
        )
        coord._replaceTreeIncompleteEvidenceForTesting(
            rootPath: treeRoot,
            issues: [refreshedIssue]
        )
        XCTAssertFalse(coord.incompleteScanIssues.contains(oldTreeIssue),
                       "同 root 重扫不得只追加陈旧 issue")
        XCTAssertTrue(coord.incompleteScanIssues.contains(refreshedIssue))
        XCTAssertTrue(coord.incompleteScanIssues.contains(primary),
                      "Tree 替换不得覆盖主扫描证据")

        coord._replaceTreeIncompleteEvidenceForTesting(rootPath: treeRoot, issues: [])
        XCTAssertFalse(coord.incompleteScanIssues.contains(refreshedIssue),
                       "完整重扫应清除该 fetch root 的旧缺口")
        XCTAssertEqual(coord.incompleteScanIssues, [primary])
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
