import XCTest
@testable import AppUI
import SafetyKit

/// Step 15：补 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1379-L1484)
/// 测试死角。
///
/// 该方法是"删除成功后的状态同步核心"——同时清四份内存索引（buckets / dirIndex / fileLeaves
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

    func test_pruneDeleted_删除子项时snapshot祖先行与totalBytes同步扣减() {
        let coord = ScanCoordinator()
        let parent = RowItem(
            id: "/A",
            url: URL(fileURLWithPath: "/A"),
            title: "A",
            isDirectory: true,
            bytes: 1_000,
            logicalBytes: 1_000,
            fileCount: 5,
            verdict: .safe,
            rejection: .ok
        )
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "t",
                rows: [parent],
                totalBytes: 1_000,
                scannedFileCount: 5,
                isFinished: true,
                elapsed: 0
            ),
            dirIndexFull: [
                "/A": (bytes: 1_000, fileCount: 5),
                "/A/build": (bytes: 300, fileCount: 3),
                "/A/keep": (bytes: 700, fileCount: 2),
            ]
        )

        coord.pruneDeleted(paths: ["/A/build"])

        XCTAssertEqual(coord.snapshot.totalBytes, 700)
        XCTAssertEqual(coord.snapshot.rows.first?.bytes, 700,
                       "snapshot 里的可见父级 row 必须随子项删除同步变小")
        XCTAssertEqual(coord.snapshot.rows.first?.fileCount, 2)
    }

    func test_pruneDeleted_删除多根子项时perRoot父级同步扣减() {
        let coord = ScanCoordinator()
        let derivedData = "/Users/test/Library/Developer/Xcode/DerivedData"
        let compilationCache = "\(derivedData)/CompilationCache.noindex"
        coord._seedForTesting(
            currentRootPath: ScanCoordinator.multiRootSentinelPath,
            dirIndexFull: [
                derivedData: (bytes: 1_000, fileCount: 5),
                compilationCache: (bytes: 300, fileCount: 3),
                "\(derivedData)/ModuleCache.noindex": (bytes: 700, fileCount: 2),
            ],
            perRootStaging: [
                derivedData: ScanCoordinator.PerRootProgress(
                    rootPath: derivedData,
                    title: "Xcode 构建产物",
                    bytes: 1_000,
                    fileCount: 5,
                    isFinished: true
                )
            ]
        )

        coord.pruneDeleted(paths: [compilationCache])

        let progress = coord.perRootProgress[derivedData]
        XCTAssertEqual(progress?.bytes, 700,
                       "多根树顶层父级来自 perRootProgress，必须随子项删除同步扣减")
        XCTAssertEqual(progress?.fileCount, 2)
        let topLevel = coord.directChildren(of: ScanCoordinator.multiRootSentinelPath, sortedBy: .sizeDesc)
        XCTAssertEqual(topLevel.first?.bytes, 700)
        XCTAssertEqual(topLevel.first?.fileCount, 2)
    }

    func test_pruneDeleted_删除开发者构建产物顶层根时perRoot同步移除() {
        let coord = ScanCoordinator()
        let derivedData = "/Users/test/Library/Developer/Xcode/DerivedData"
        let moduleCache = "/Users/test/Library/Developer/Xcode/ModuleCache.noindex"
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: ScanCoordinator.developerCategoryID,
                rows: [],
                totalBytes: 1_100,
                scannedFileCount: 8,
                isFinished: true,
                elapsed: 0
            ),
            currentRootPath: ScanCoordinator.developerSentinelPath,
            perRootStaging: [
                derivedData: ScanCoordinator.PerRootProgress(
                    rootPath: derivedData,
                    title: "DerivedData",
                    bytes: 400,
                    fileCount: 3,
                    isFinished: true
                ),
                moduleCache: ScanCoordinator.PerRootProgress(
                    rootPath: moduleCache,
                    title: "ModuleCache",
                    bytes: 700,
                    fileCount: 5,
                    isFinished: true
                )
            ]
        )

        coord.pruneDeleted(paths: [derivedData])

        XCTAssertNil(coord.perRootProgress[derivedData],
            "开发者构建产物顶层行来自 perRootProgress，删除根本身时必须同步移除")
        XCTAssertEqual(coord.perRootProgress[moduleCache]?.bytes, 700)
        XCTAssertEqual(coord.snapshot.totalBytes, 700,
            "没有 dirIndex/snapshot row 的合成顶层根也要按 perRoot 贡献量扣总量")
        let topLevel = coord.directChildren(of: ScanCoordinator.developerSentinelPath, sortedBy: .sizeDesc)
        XCTAssertEqual(topLevel.map(\.path), [moduleCache],
            "TreeBrowserView 读取的多根合成顶层不应再包含已移废纸篓成功的根")
    }

    func test_pruneDeleted_删除多根顶层后旧扫描同步不应复活该根() {
        let coord = ScanCoordinator()
        let derivedData = "/Users/test/Library/Developer/Xcode/DerivedData"
        let caches = "/Users/test/Library/Caches"
        coord._seedForTesting(
            currentRootPath: ScanCoordinator.multiRootSentinelPath,
            perRootStaging: [
                derivedData: ScanCoordinator.PerRootProgress(
                    rootPath: derivedData,
                    title: "Xcode Build Artifacts",
                    bytes: 400,
                    fileCount: 3,
                    isFinished: true
                ),
                caches: ScanCoordinator.PerRootProgress(
                    rootPath: caches,
                    title: "User Caches",
                    bytes: 700,
                    fileCount: 5,
                    isFinished: true
                )
            ]
        )

        coord.pruneDeleted(paths: [derivedData])
        coord._seedForTesting(
            perRootStaging: [
                derivedData: ScanCoordinator.PerRootProgress(
                    rootPath: derivedData,
                    title: "Xcode Build Artifacts",
                    bytes: 400,
                    fileCount: 3,
                    isFinished: true
                ),
                caches: ScanCoordinator.PerRootProgress(
                    rootPath: caches,
                    title: "User Caches",
                    bytes: 700,
                    fileCount: 5,
                    isFinished: true
                )
            ]
        )

        XCTAssertNil(coord.perRootProgress[derivedData],
            "删除成功后的 tombstone 必须挡住旧扫描事件/节流同步把同一路径复活")
        let topLevel = coord.directChildren(of: ScanCoordinator.multiRootSentinelPath, sortedBy: .sizeDesc)
        XCTAssertEqual(topLevel.map(\.path), [caches])
    }

    func test_pruneDeleted_删除后异步子树fetch不应把tombstone路径写回cache() {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            treeChildrenCache: [
                "/A|sizeDesc": [
                    makeTreeRow("/A/drop"),
                    makeTreeRow("/A/keep")
                ]
            ]
        )

        coord.pruneDeleted(paths: ["/A/drop"])
        coord._storeFetchedChildrenForTesting(
            path: "/A",
            sortedBy: .sizeDesc,
            rows: [
                makeTreeRow("/A/drop"),
                makeTreeRow("/A/keep")
            ]
        )

        let cached = coord._treeChildrenCacheForTesting()["/A|sizeDesc"]?.map(\.path)
        XCTAssertEqual(cached, ["/A/keep"],
                       "删除后的后台 directChildren fetch 可能晚到，写 cache 前必须过滤 tombstone")
    }

    func test_pruneDeleted_根路径应匹配所有子孙() {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "t",
                rows: [makeRow("/Applications/X"), makeRow("/Users/me/Y")],
                totalBytes: 2_000,
                scannedFileCount: 2,
                isFinished: true,
                elapsed: 0
            ),
            treeChildrenCache: [
                "/|sizeDesc": [
                    makeTreeRow("/Applications"),
                    makeTreeRow("/Users")
                ]
            ]
        )

        coord.pruneDeleted(paths: ["/"])

        XCTAssertTrue(coord.snapshot.rows.isEmpty)
        XCTAssertTrue(coord._treeChildrenCacheForTesting().isEmpty,
                      "根路径删除语义必须覆盖所有子孙，不能因为 '/' + '/' 变成 '//' 而漏匹配")
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

    // MARK: - 不变量 7（v1.5.7）：祖先 dirIndex 必须做减法

    /// v1.5.7：用户截图 bug——删除子目录后祖先 size 不更新。
    /// 修复后 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1416-L1484)
    /// 在删 dirIndex 自身之前，先沿祖先链做反向减法（与
    /// [ingest L1219-L1231](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1219-L1231)
    /// 严格对称）。
    func test_pruneDeleted_祖先dirIndex的bytes与fileCount被减回去_截图bug回归() {
        // 拟态：祖先 /A 持有 5 个孩子总 1000 bytes；/A/build 自己是个 300 bytes/3 文件的目录。
        // 删 /A/build 后，/A 必须变成 700 bytes / 2 文件。
        let coord = ScanCoordinator()
        coord._seedForTesting(
            dirIndexFull: [
                "/A": (bytes: 1000, fileCount: 5),
                "/A/build": (bytes: 300, fileCount: 3),
                "/A/keep1": (bytes: 400, fileCount: 1),
                "/A/keep2": (bytes: 300, fileCount: 1)
            ]
        )

        coord.pruneDeleted(paths: ["/A/build"])

        guard let aggA = coord._dirIndexAggForTesting("/A") else {
            return XCTFail("祖先 /A 不应被删，dirIndex 必须留着")
        }
        XCTAssertEqual(aggA.bytes, 700,
            "/A.bytes 必须从 1000 减去被删 /A/build.bytes=300")
        XCTAssertEqual(aggA.fileCount, 2,
            "/A.fileCount 必须从 5 减去被删 /A/build.fileCount=3")
        // /A/build 自己已被删
        XCTAssertNil(coord._dirIndexAggForTesting("/A/build"),
            "被删 path 自己必须从 dirIndex 移除")
        // 兄弟分支不受影响
        XCTAssertEqual(coord._dirIndexAggForTesting("/A/keep1")?.bytes, 400)
        XCTAssertEqual(coord._dirIndexAggForTesting("/A/keep2")?.bytes, 300)
    }

    /// v1.5.7：删叶子文件时，所有祖先目录的聚合都应减去叶子贡献。
    func test_pruneDeleted_叶子文件被删时所有祖先聚合都应同步减() {
        // /A -> /A/sub -> /A/sub/file.bin (200 bytes)
        // /A.bytes=200/files=1; /A/sub.bytes=200/files=1
        let coord = ScanCoordinator()
        coord._seedForTesting(
            dirIndexFull: [
                "/A": (bytes: 200, fileCount: 1),
                "/A/sub": (bytes: 200, fileCount: 1)
            ],
            fileLeavesFull: [
                "/A/sub/file.bin": 200
            ]
        )

        coord.pruneDeleted(paths: ["/A/sub/file.bin"])

        XCTAssertNil(coord._fileLeavesKeysForTesting().first { $0 == "/A/sub/file.bin" },
            "叶子文件本身被删")
        XCTAssertEqual(coord._dirIndexAggForTesting("/A/sub")?.bytes, 0,
            "/A/sub 在叶子被删后聚合应 = 0")
        XCTAssertEqual(coord._dirIndexAggForTesting("/A/sub")?.fileCount, 0)
        XCTAssertEqual(coord._dirIndexAggForTesting("/A")?.bytes, 0,
            "/A 作为远祖也必须减去叶子 200 bytes")
        XCTAssertEqual(coord._dirIndexAggForTesting("/A")?.fileCount, 0)
    }

    /// v1.5.7：被删 path 自身的祖先链上若有其他被删 path，
    /// 不应导致祖先 bytes 减负或重复减（max(0, -) 兜底）。
    func test_pruneDeleted_同时删父子时祖先聚合不应被重复减() {
        // /R: 500 bytes / 3 files；/R/sub: 300 bytes / 2 files；/R/sub/leaf: 100 bytes
        // 一次性删 /R/sub 和 /R/sub/leaf（leaf 被父 prefix 命中，已等价被删）；
        // /R 应当只减一次 /R/sub 的贡献：500 - 300 = 200，3 - 2 = 1
        let coord = ScanCoordinator()
        coord._seedForTesting(
            dirIndexFull: [
                "/R": (bytes: 500, fileCount: 3),
                "/R/sub": (bytes: 300, fileCount: 2)
            ],
            fileLeavesFull: [
                "/R/sub/leaf": 100
            ]
        )

        coord.pruneDeleted(paths: ["/R/sub", "/R/sub/leaf"])

        XCTAssertEqual(coord._dirIndexAggForTesting("/R")?.bytes, 200,
            "重复路径（父+子）不应让 /R 减 300+100=400")
        XCTAssertEqual(coord._dirIndexAggForTesting("/R")?.fileCount, 1)
        XCTAssertNil(coord._dirIndexAggForTesting("/R/sub"),
            "/R/sub 自己被删")
    }

    // MARK: - v1.5.7 perf：原生 String 路径切分 vs NSString.deletingLastPathComponent

    /// 钉死 [_gsyParentPath](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L2496-L2521)
    /// 在 ingest 实际会传入的所有路径形态下，与 NSString.deletingLastPathComponent 完全等价。
    /// 任何未来对该 helper 的进一步优化只要不破这条等价，就能安全落地。
    func test_gsyParentPath_与NSString_deletingLastPathComponent等价() {
        let cases: [String] = [
            "/Users/zhangsan/work/repo/.git/objects/pack/pack-deadbeef.idx",
            "/Users/zhangsan/Library/Developer/Xcode/DerivedData",
            "/A/B/C",
            "/A/B",
            "/A",
            "/",
            "/tmp/with space/foo.txt",
            "/中文/路径/文件.bin"
        ]
        for p in cases {
            let nsExpected = (p as NSString).deletingLastPathComponent
            let mine = String._gsyParentPath(of: p)
            XCTAssertEqual(mine, nsExpected, "path=\(p)")
        }
    }
}
