import XCTest
@testable import AppUI
import SafetyKit

/// Step 15：补 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1379-L1484)
/// 测试死角。
///
/// 该方法是"删除乐观更新核心"——同时清四份内存索引（buckets / dirIndex / fileLeaves
/// / childEdges）+ snapshot.rows + treeChildrenCache，且要触发 structuralRevision bump。
/// AUDIT §3.6 明确"零直接测试"。本套围绕 6 个不变量驱：
///
/// 1. 精确命中：被删 path 必须从 snapshot.rows 移除
/// 2. 前缀级联：被删 path 的子孙必须从 buckets/dirIndex/fileLeaves 一并清除
/// 3. 同名相邻不误伤：被删 `/A/B` 不应误中 `/A/Bbb`（hasPrefix("/A/B") 漏洞防御）
/// 4. childEdges 双向：父集合 set 内的命中项要剔除，自身 key 也要剔除
/// 5. treeChildrenCache 静默 patch：cache key 在删除范围内整段丢；其他 key 行内 filter
/// 6. structuralRevision 必须 +1，UI 才会重建 flatRows
@MainActor
final class PruneDeletedTests: XCTestCase {

    // MARK: - 工具

    private func makeRow(_ path: String, bytes: Int64 = 1_000) -> RowItem {
        RowItem(
            id: path,
            url: URL(fileURLWithPath: path),
            title: (path as NSString).lastPathComponent,
            isDirectory: true,
            bytes: bytes,
            logicalBytes: bytes,
            fileCount: 1,
            verdict: .safe,
            rejection: .ok
        )
    }

    private func makeTreeRow(_ path: String) -> TreeRow {
        TreeRow(
            path: path,
            title: (path as NSString).lastPathComponent,
            bytes: 1,
            fileCount: 1,
            isDirectory: true,
            hasChildren: false
        )
    }

    // MARK: - 不变量 1: snapshot.rows 精确移除 + totalBytes 同步扣减

    func test_pruneDeleted_命中行从snapshot移除并扣减totalBytes() {
        let coord = ScanCoordinator()
        let rowA = makeRow("/A/keep", bytes: 100)
        let rowB = makeRow("/A/drop", bytes: 250)
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "test",
                rows: [rowA, rowB],
                totalBytes: 350,
                scannedFileCount: 2,
                isFinished: true,
                elapsed: 1.0
            )
        )

        coord.pruneDeleted(paths: ["/A/drop"])

        XCTAssertEqual(coord.snapshot.rows.map(\.id), ["/A/keep"])
        XCTAssertEqual(coord.snapshot.totalBytes, 100,
            "totalBytes 应扣减被删 row 的 bytes")
    }

    // MARK: - 不变量 2: 前缀级联

    func test_pruneDeleted_前缀级联清buckets_dirIndex_fileLeaves() {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            buckets: ["/A/sub": 1, "/A/sub/inner": 2, "/B/keep": 3],
            dirIndex: ["/A/sub", "/A/sub/inner", "/B/keep"],
            fileLeaves: ["/A/sub/file.txt", "/A/sub/inner/x.log", "/B/keep/y.txt"]
        )

        coord.pruneDeleted(paths: ["/A/sub"])

        XCTAssertEqual(coord._bucketsKeysForTesting().sorted(), ["/B/keep"])
        XCTAssertEqual(coord._dirIndexKeysForTesting().sorted(), ["/B/keep"])
        XCTAssertEqual(coord._fileLeavesKeysForTesting().sorted(), ["/B/keep/y.txt"])
    }

    // MARK: - 不变量 3: 同名相邻不误伤

    func test_pruneDeleted_删AB不应误伤ABbb() {
        let coord = ScanCoordinator()
        let r1 = makeRow("/A/B")
        let r2 = makeRow("/A/Bbb")     // 真兄弟，名字带 B 前缀但是不同节点
        let r3 = makeRow("/A/B/inner") // 真孙子，应被一同删
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "t",
                rows: [r1, r2, r3],
                totalBytes: 3_000,
                scannedFileCount: 3,
                isFinished: true,
                elapsed: 0.1
            )
        )

        coord.pruneDeleted(paths: ["/A/B"])

        let remaining = coord.snapshot.rows.map(\.id).sorted()
        XCTAssertEqual(remaining, ["/A/Bbb"],
            "/A/Bbb 与 /A/B 是平级节点，不能因 hasPrefix 误删")
    }

    // MARK: - 不变量 4: childEdges 双向清理

    func test_pruneDeleted_childEdges双向剔除() {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            childEdges: [
                "/A": ["/A/x", "/A/y", "/A/drop"],
                "/A/drop": ["/A/drop/inner1", "/A/drop/inner2"],
                "/B": ["/B/k"]
            ]
        )

        coord.pruneDeleted(paths: ["/A/drop"])

        let edges = coord._childEdgesForTesting()
        XCTAssertNil(edges["/A/drop"], "被删 path 自己作为 key 整段去掉")
        XCTAssertEqual(edges["/A"]?.sorted(), ["/A/x", "/A/y"],
            "父 /A 的 children set 必须剔除已删孩子 /A/drop")
        XCTAssertEqual(edges["/B"]?.sorted(), ["/B/k"],
            "无关父节点 /B 不动")
    }

    // MARK: - 不变量 5: treeChildrenCache 静默 patch

    func test_pruneDeleted_cache被删整段丢_无关cache行内filter() {
        let coord = ScanCoordinator()
        let cache: [String: [TreeRow]] = [
            // 自己就在被删范围 → 整段丢
            "/A/drop|sizeDesc": [makeTreeRow("/A/drop/x"), makeTreeRow("/A/drop/y")],
            // 无关父，但其中含已删孩子 → 行内 filter
            "/A|sizeDesc": [
                makeTreeRow("/A/keep"),
                makeTreeRow("/A/drop"),
                makeTreeRow("/A/another")
            ],
            // 完全无关 → 原样保留
            "/B|sizeDesc": [makeTreeRow("/B/x")]
        ]
        coord._seedForTesting(treeChildrenCache: cache)

        coord.pruneDeleted(paths: ["/A/drop"])

        let after = coord._treeChildrenCacheForTesting()
        XCTAssertNil(after["/A/drop|sizeDesc"], "在删除范围内的 cache key 必须移除")
        XCTAssertEqual(
            after["/A|sizeDesc"]?.map(\.path).sorted(),
            ["/A/another", "/A/keep"],
            "无关父 cache 必须剔掉已删孩子条目"
        )
        XCTAssertEqual(after["/B|sizeDesc"]?.map(\.path), ["/B/x"],
            "完全无关 cache 不动")
    }

    // MARK: - 不变量 6: structuralRevision bump

    func test_pruneDeleted_应bump_structuralRevision() {
        let coord = ScanCoordinator()
        let r = makeRow("/A/drop")
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [r], totalBytes: 1,
                                   scannedFileCount: 1, isFinished: true, elapsed: 0)
        )
        let before = coord.structuralRevision
        coord.pruneDeleted(paths: ["/A/drop"])
        XCTAssertGreaterThan(coord.structuralRevision, before,
            "pruneDeleted 必须 bump structuralRevision，TreeBrowserView 才会重建 flatRows")
    }

    // MARK: - 边界：空 paths no-op

    func test_pruneDeleted_空paths不应改变状态() {
        let coord = ScanCoordinator()
        let r = makeRow("/A/x")
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [r], totalBytes: 1,
                                   scannedFileCount: 1, isFinished: true, elapsed: 0)
        )
        let revBefore = coord.structuralRevision
        coord.pruneDeleted(paths: [])
        XCTAssertEqual(coord.snapshot.rows.count, 1)
        XCTAssertEqual(coord.structuralRevision, revBefore,
            "空 paths 应早返，structuralRevision 不变")
    }

    // MARK: - 边界：尾斜杠归一化

    func test_pruneDeleted_尾斜杠应被等价处理() {
        let coord = ScanCoordinator()
        let r = makeRow("/A/x")
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [r], totalBytes: 1,
                                   scannedFileCount: 1, isFinished: true, elapsed: 0)
        )
        coord.pruneDeleted(paths: ["/A/x/"])
        XCTAssertTrue(coord.snapshot.rows.isEmpty,
            "/A/x/ 与 /A/x 应等价处理（实现里 dropLast 末尾 /）")
    }
}
