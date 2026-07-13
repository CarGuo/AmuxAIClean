import XCTest
@testable import AppUI
import SafetyKit
import ScanKit

private actor PruneRetirementGate {
    private var entered = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseBeforeRelease() async {
        entered = true
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func resumeRelease() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

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

    private func makeTreeRow(_ path: String,
                             bytes: Int64 = 1,
                             fileCount: Int = 1,
                             isSizePending: Bool = false) -> TreeRow {
        TreeRow(
            path: path,
            title: (path as NSString).lastPathComponent,
            bytes: bytes,
            fileCount: fileCount,
            isDirectory: true,
            hasChildren: false,
            isSizePending: isSizePending
        )
    }

    // MARK: - 不变量 1: snapshot.rows 精确移除 + totalBytes 同步扣减

    func test_pruneDeleted_命中行从snapshot移除并扣减totalBytes() async {
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

        await coord.pruneDeleted(paths: ["/A/drop"])

        XCTAssertEqual(coord.snapshot.rows.map(\.id), ["/A/keep"])
        XCTAssertEqual(coord.snapshot.totalBytes, 100,
            "totalBytes 应扣减被删 row 的 bytes")
    }

    // MARK: - 不变量 2: 前缀级联

    func test_pruneDeleted_前缀级联清buckets_dirIndex_fileLeaves() async {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            buckets: ["/A/sub": 1, "/A/sub/inner": 2, "/B/keep": 3],
            dirIndex: ["/A/sub", "/A/sub/inner", "/B/keep"],
            fileLeaves: ["/A/sub/file.txt", "/A/sub/inner/x.log", "/B/keep/y.txt"]
        )

        await coord.pruneDeleted(paths: ["/A/sub"])

        XCTAssertEqual(coord._bucketsKeysForTesting().sorted(), ["/B/keep"])
        XCTAssertEqual(coord._dirIndexKeysForTesting().sorted(), ["/B/keep"])
        XCTAssertEqual(coord._fileLeavesKeysForTesting().sorted(), ["/B/keep/y.txt"])
    }

    // MARK: - 不变量 3: 同名相邻不误伤

    func test_pruneDeleted_删AB不应误伤ABbb() async {
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

        await coord.pruneDeleted(paths: ["/A/B"])

        let remaining = coord.snapshot.rows.map(\.id).sorted()
        XCTAssertEqual(remaining, ["/A/Bbb"],
            "/A/Bbb 与 /A/B 是平级节点，不能因 hasPrefix 误删")
    }

    // MARK: - 不变量 4: childEdges 双向清理

    func test_pruneDeleted_childEdges双向剔除() async {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            childEdges: [
                "/A": ["/A/x", "/A/y", "/A/drop"],
                "/A/drop": ["/A/drop/inner1", "/A/drop/inner2"],
                "/B": ["/B/k"]
            ]
        )

        await coord.pruneDeleted(paths: ["/A/drop"])

        let edges = coord._childEdgesForTesting()
        XCTAssertNil(edges["/A/drop"], "被删 path 自己作为 key 整段去掉")
        XCTAssertEqual(edges["/A"]?.sorted(), ["/A/x", "/A/y"],
            "父 /A 的 children set 必须剔除已删孩子 /A/drop")
        XCTAssertEqual(edges["/B"]?.sorted(), ["/B/k"],
            "无关父节点 /B 不动")
    }

    // MARK: - 不变量 5: treeChildrenCache 静默 patch

    func test_pruneDeleted_cache被删整段丢_无关cache行内filter() async {
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

        await coord.pruneDeleted(paths: ["/A/drop"])

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

    func test_pruneDeleted_应bump_structuralRevision() async {
        let coord = ScanCoordinator()
        let r = makeRow("/A/drop")
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [r], totalBytes: 1,
                                   scannedFileCount: 1, isFinished: true, elapsed: 0)
        )
        let before = coord.structuralRevision
        await coord.pruneDeleted(paths: ["/A/drop"])
        XCTAssertGreaterThan(coord.structuralRevision, before,
            "pruneDeleted 必须 bump structuralRevision，TreeBrowserView 才会重建 flatRows")
    }

    // MARK: - 边界：空 paths no-op

    func test_pruneDeleted_空paths不应改变状态() async {
        let coord = ScanCoordinator()
        let r = makeRow("/A/x")
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [r], totalBytes: 1,
                                   scannedFileCount: 1, isFinished: true, elapsed: 0)
        )
        let revBefore = coord.structuralRevision
        await coord.pruneDeleted(paths: [])
        XCTAssertEqual(coord.snapshot.rows.count, 1)
        XCTAssertEqual(coord.structuralRevision, revBefore,
            "空 paths 应早返，structuralRevision 不变")
    }

    func test_pruneDeleted_删除子项时snapshot祖先行与totalBytes同步扣减() async {
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

        await coord.pruneDeleted(paths: ["/A/build"])

        XCTAssertEqual(coord.snapshot.totalBytes, 700)
        XCTAssertEqual(coord.snapshot.rows.first?.bytes, 700,
                       "snapshot 里的可见父级 row 必须随子项删除同步变小")
        XCTAssertEqual(coord.snapshot.rows.first?.fileCount, 2)
    }

    func test_pruneDeleted_删除多根子项时perRoot父级同步扣减() async {
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

        await coord.pruneDeleted(paths: [compilationCache])

        let progress = coord.perRootProgress[derivedData]
        XCTAssertEqual(progress?.bytes, 700,
                       "多根树顶层父级来自 perRootProgress，必须随子项删除同步扣减")
        XCTAssertEqual(progress?.fileCount, 2)
        let topLevel = coord.directChildren(of: ScanCoordinator.multiRootSentinelPath, sortedBy: .sizeDesc)
        XCTAssertEqual(topLevel.first?.bytes, 700)
        XCTAssertEqual(topLevel.first?.fileCount, 2)
    }

    func test_pruneDeleted_删除开发者构建产物顶层根时perRoot同步移除() async {
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

        await coord.pruneDeleted(paths: [derivedData])

        XCTAssertNil(coord.perRootProgress[derivedData],
            "开发者构建产物顶层行来自 perRootProgress，删除根本身时必须同步移除")
        XCTAssertEqual(coord.perRootProgress[moduleCache]?.bytes, 700)
        XCTAssertEqual(coord.snapshot.totalBytes, 700,
            "没有 dirIndex/snapshot row 的合成顶层根也要按 perRoot 贡献量扣总量")
        let topLevel = coord.directChildren(of: ScanCoordinator.developerSentinelPath, sortedBy: .sizeDesc)
        XCTAssertEqual(topLevel.map(\.path), [moduleCache],
            "TreeBrowserView 读取的多根合成顶层不应再包含已移废纸篓成功的根")
    }

    func test_pruneDeleted_删除多根顶层后旧扫描同步不应复活该根() async {
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

        await coord.pruneDeleted(paths: [derivedData])
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

    func test_pruneDeleted_晚到多根节点不应重新累计已删除子树() async {
        let coord = ScanCoordinator()
        let root = "/Users/test/Library/Caches"
        coord._seedForTesting(
            currentRootPath: ScanCoordinator.multiRootSentinelPath,
            perRootStaging: [
                root: ScanCoordinator.PerRootProgress(
                    rootPath: root,
                    title: "User Caches"
                )
            ]
        )

        await coord.pruneDeleted(paths: [root + "/drop"])
        coord._testIngestMultiRootNodes(rootPath: root, nodes: [
            FSNode(
                path: root + "/drop/late.bin",
                isDirectory: false,
                isSymlink: false,
                allocatedSize: 400,
                logicalSize: 400,
                inode: 1,
                device: 1,
                modificationDate: nil
            ),
            FSNode(
                path: root + "/keep/visible.bin",
                isDirectory: false,
                isSymlink: false,
                allocatedSize: 200,
                logicalSize: 200,
                inode: 2,
                device: 1,
                modificationDate: nil
            )
        ])

        XCTAssertEqual(coord.perRootProgress[root]?.bytes, 200,
                       "tombstone 拒绝的晚到节点不能重新计入多根进度")
        XCTAssertEqual(coord.perRootProgress[root]?.fileCount, 1)
    }

    func test_pruneDeleted_删除后异步子树fetch不应把tombstone路径写回cache() async {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            treeChildrenCache: [
                "/A|sizeDesc": [
                    makeTreeRow("/A/drop"),
                    makeTreeRow("/A/keep")
                ]
            ]
        )

        await coord.pruneDeleted(paths: ["/A/drop"])
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

    func test_pruneDeleted_根路径应匹配所有子孙() async {
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

        await coord.pruneDeleted(paths: ["/"])

        XCTAssertTrue(coord.snapshot.rows.isEmpty)
        XCTAssertTrue(coord._treeChildrenCacheForTesting().isEmpty,
                      "根路径删除语义必须覆盖所有子孙，不能因为 '/' + '/' 变成 '//' 而漏匹配")
    }

    // MARK: - 边界：尾斜杠归一化

    func test_pruneDeleted_尾斜杠应被等价处理() async {
        let coord = ScanCoordinator()
        let r = makeRow("/A/x")
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [r], totalBytes: 1,
                                   scannedFileCount: 1, isFinished: true, elapsed: 0)
        )
        await coord.pruneDeleted(paths: ["/A/x/"])
        XCTAssertTrue(coord.snapshot.rows.isEmpty,
            "/A/x/ 与 /A/x 应等价处理（实现里 dropLast 末尾 /）")
    }

    // MARK: - 不变量 7（v1.5.7）：祖先 dirIndex 必须做减法

    /// v1.5.7：用户截图 bug——删除子目录后祖先 size 不更新。
    /// 修复后 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1416-L1484)
    /// 在删 dirIndex 自身之前，先沿祖先链做反向减法（与
    /// [ingest L1219-L1231](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1219-L1231)
    /// 严格对称）。
    func test_pruneDeleted_祖先dirIndex的bytes与fileCount被减回去_截图bug回归() async {
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

        await coord.pruneDeleted(paths: ["/A/build"])

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
    func test_pruneDeleted_叶子文件被删时所有祖先聚合都应同步减() async {
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

        await coord.pruneDeleted(paths: ["/A/sub/file.bin"])

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
    func test_pruneDeleted_同时删父子时祖先聚合不应被重复减() async {
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

        await coord.pruneDeleted(paths: ["/R/sub", "/R/sub/leaf"])

        XCTAssertEqual(coord._dirIndexAggForTesting("/R")?.bytes, 200,
            "重复路径（父+子）不应让 /R 减 300+100=400")
        XCTAssertEqual(coord._dirIndexAggForTesting("/R")?.fileCount, 1)
        XCTAssertNil(coord._dirIndexAggForTesting("/R/sub"),
            "/R/sub 自己被删")
    }

    // MARK: - v2026.07 P1：后台 transaction 与代际保护

    func test_pruneDeleted_两万行计划必须在后台完成且保留同名兄弟() async {
        let coord = ScanCoordinator()
        let count = 20_000
        var rows: [RowItem] = []
        var buckets: [String: Int64] = [:]
        var dirIndex: [String: (bytes: Int64, fileCount: Int)] = [:]
        var fileLeaves: [String: Int64] = [:]
        rows.reserveCapacity(count)
        buckets.reserveCapacity(count)
        dirIndex.reserveCapacity(count)
        fileLeaves.reserveCapacity(count)

        for index in 0..<count {
            let branch = index.isMultiple(of: 2) ? "drop" : "dropbox"
            let path = "/R/\(branch)/node-\(index)"
            rows.append(makeRow(path, bytes: 1))
            buckets[path] = 1
            dirIndex[path] = (bytes: 1, fileCount: 1)
            fileLeaves[path + "/leaf.bin"] = 1
        }
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "perf",
                rows: rows,
                totalBytes: Int64(count),
                scannedFileCount: count,
                isFinished: true,
                elapsed: 1
            ),
            buckets: buckets,
            dirIndexFull: dirIndex,
            fileLeavesFull: fileLeaves
        )

        await coord.pruneDeleted(paths: ["/R/drop"])

        let diagnostics = coord._prunePlanDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.ranOnMainThread, false,
                       "全表 filter/reduce/sort 必须在 detached planner，而不是 MainActor")
        let elapsed = Double(diagnostics.durationNanoseconds ?? .max) / 1_000_000_000
        let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        XCTAssertLessThan(elapsed, isCI ? 5.0 : 2.0,
                          "2 万行 prune plan 不应退化成嵌套路径扫描")
        XCTAssertEqual(coord.snapshot.rows.count, count / 2)
        XCTAssertTrue(coord.snapshot.rows.allSatisfy { $0.id.hasPrefix("/R/dropbox/") },
                      "目录边界 matcher 不能把 /R/dropbox 当成 /R/drop 的子孙")
    }

    func test_pruneDeleted_新扫描换代后旧plan不得覆盖新snapshot() async {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "old",
                rows: [makeRow("/old/drop")],
                totalBytes: 1,
                scannedFileCount: 1,
                isFinished: true,
                elapsed: 0
            )
        )
        let newRow = makeRow("/new/keep", bytes: 42)
        let newSnapshot = ScanSnapshot(
            categoryID: "new",
            rows: [newRow],
            totalBytes: 42,
            scannedFileCount: 1,
            isFinished: false,
            elapsed: 0
        )

        await coord._pruneDeletedForTesting(paths: ["/old/drop"]) { @MainActor in
            // 等价于用户在后台 plan 计算期间切换分类并启动新扫描：cancel 刷新 generation，
            // 新 snapshot 随后成为唯一有效状态。
            coord.cancel()
            coord._seedForTesting(snapshot: newSnapshot)
        }

        XCTAssertEqual(coord.snapshot, newSnapshot)
        XCTAssertEqual(coord.storeRevision, 0,
                       "旧 plan 的 CAS 必须失败，不能发布一次伪 store 更新")
    }

    func test_pruneDeleted_旧大COW状态在后台释放且MainActor心跳不中断() async {
        let coord = ScanCoordinator()
        let count = 12_000
        var rows: [RowItem] = []
        var buckets: [String: Int64] = [:]
        var fileLeaves: [String: Int64] = [:]
        rows.reserveCapacity(count)
        buckets.reserveCapacity(count)
        fileLeaves.reserveCapacity(count)
        for index in 0..<count {
            let path = index.isMultiple(of: 2)
                ? "/release/drop/node-\(index)"
                : "/release/keep/node-\(index)"
            rows.append(makeRow(path, bytes: 1))
            buckets[path] = 1
            fileLeaves[path + "/leaf"] = 1
        }
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "release",
                rows: rows,
                totalBytes: Int64(count),
                scannedFileCount: count,
                isFinished: true,
                elapsed: 0
            ),
            buckets: buckets,
            fileLeavesFull: fileLeaves,
            totalBytes: Int64(count),
            scannedFiles: count
        )

        let gate = PruneRetirementGate()
        let pruneTask = Task { @MainActor in
            await coord._pruneDeletedForTesting(
                paths: ["/release/drop"],
                beforeCommit: {},
                beforeRetire: { await gate.pauseBeforeRelease() }
            )
        }
        await gate.waitUntilEntered()

        // 此时 commit 已完成，worker 正持有旧 COW storage 等待后台释放；MainActor
        // 必须仍能调度一拍 heartbeat，而不是在 Dictionary 元素析构里冻结。
        let heartbeat = await Task { @MainActor in true }.value
        XCTAssertTrue(heartbeat)
        XCTAssertEqual(coord.snapshot.rows.count, count / 2)

        await gate.resumeRelease()
        await pruneTask.value
        let lifecycle = coord._pruneLifecycleDiagnosticsForTesting()
        XCTAssertEqual(lifecycle.retirementRanOnMainThread, false,
                       "旧 COW storage 的最后引用必须在 prune worker executor 释放")
        XCTAssertNotNil(lifecycle.retirementDurationNanoseconds)
    }

    func test_pruneDeleted_大量历史tombstone后台合并并保持父子最小集合() async {
        let coord = ScanCoordinator()
        var firstBatch: [String] = []
        firstBatch.reserveCapacity(6_001)
        for index in 0..<3_000 {
            firstBatch.append("/R/branch-\(index)")
            firstBatch.append("/R/branch-\(index)/child")
        }
        // `/R-keep` 会在字典序上插进 `/R` 与 `/R/...` 附近，防止实现退化成
        // “只看前一个排序项”而漏掉真正祖先。
        firstBatch.append("/R-keep")
        await coord.pruneDeleted(paths: firstBatch)

        var lifecycle = coord._pruneLifecycleDiagnosticsForTesting()
        XCTAssertEqual(lifecycle.mergeRanOnMainThread, false,
                       "tombstone 排序、rehash、父子最小化必须在 worker executor")
        XCTAssertEqual(coord._deletedTombstoneRootsForTesting().count, 3_001)

        await coord.pruneDeleted(paths: ["/R"])
        lifecycle = coord._pruneLifecycleDiagnosticsForTesting()
        XCTAssertEqual(lifecycle.mergeRanOnMainThread, false)
        XCTAssertEqual(coord._deletedTombstoneRootsForTesting(), ["/R", "/R-keep"],
                       "新父 root 必须折叠全部历史子 root，同时不能误吞同名前缀兄弟")
    }

    func test_pruneDeleted_deepIndex关闭时从完整树缓存去重聚合精确贡献() async {
        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        let visibleParent = RowItem(
            id: "/R/top",
            url: URL(fileURLWithPath: "/R/top"),
            title: "top",
            isDirectory: true,
            bytes: 1_000,
            logicalBytes: 1_000,
            fileCount: 10,
            verdict: .safe,
            rejection: .ok
        )
        let rootProgress = ScanCoordinator.PerRootProgress(
            rootPath: "/R",
            title: "R",
            bytes: 1_000,
            fileCount: 10,
            isFinished: true
        )
        let cachedChildren = [
            makeTreeRow("/R/top/drop/a.bin", bytes: 100, fileCount: 1),
            makeTreeRow("/R/top/drop/b.bin", bytes: 200, fileCount: 2)
        ]
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "deep-off",
                rows: [visibleParent],
                totalBytes: 1_000,
                scannedFileCount: 10,
                isFinished: true,
                elapsed: 0
            ),
            currentRootPath: ScanCoordinator.multiRootSentinelPath,
            treeChildrenCache: [
                // 相同 direct children 因排序键出现两份，贡献只能算一次。
                "/R/top/drop|sizeDesc": cachedChildren,
                "/R/top/drop|nameAsc": Array(cachedChildren.reversed())
            ],
            perRootStaging: ["/R": rootProgress],
            totalBytes: 1_000,
            scannedFiles: 10
        )
        XCTAssertTrue(coord._dirIndexKeysForTesting().isEmpty,
                      "本用例必须真实覆盖 deep-index off，而不是误走 dirIndex")

        await coord.pruneDeleted(paths: ["/R/top/drop"])

        XCTAssertEqual(coord.snapshot.totalBytes, 700)
        XCTAssertEqual(coord.snapshot.scannedFileCount, 7)
        XCTAssertEqual(coord.snapshot.rows.first?.bytes, 700)
        XCTAssertEqual(coord.snapshot.rows.first?.fileCount, 7)
        XCTAssertEqual(coord.perRootProgress["/R"]?.bytes, 700)
        XCTAssertEqual(coord.perRootProgress["/R"]?.fileCount, 7)
        XCTAssertEqual(coord._aggregateTotalsForTesting().bytes, 700)
        XCTAssertEqual(coord._aggregateTotalsForTesting().files, 7)
        XCTAssertTrue(coord._treeChildrenCacheForTesting().isEmpty)
    }

    func test_pruneDeleted_deepIndex关闭时不把shallow待计量缓存冒充权威贡献() async {
        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        let parent = RowItem(
            id: "/R/top",
            url: URL(fileURLWithPath: "/R/top"),
            title: "top",
            isDirectory: true,
            bytes: 1_000,
            logicalBytes: 1_000,
            fileCount: 10,
            verdict: .safe,
            rejection: .ok
        )
        coord._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "deep-off-pending",
                rows: [parent],
                totalBytes: 1_000,
                scannedFileCount: 10,
                isFinished: true,
                elapsed: 0
            ),
            treeChildrenCache: [
                "/R/top/drop|sizeDesc": [
                    makeTreeRow(
                        "/R/top/drop/not-yet-measured",
                        bytes: 0,
                        fileCount: 0,
                        isSizePending: true
                    )
                ]
            ],
            totalBytes: 1_000,
            scannedFiles: 10
        )

        await coord.pruneDeleted(paths: ["/R/top/drop"])

        XCTAssertEqual(coord.snapshot.totalBytes, 1_000,
                       "shallow pending row 不完整，宁可不扣也不能伪造 exact contribution")
        XCTAssertEqual(coord.snapshot.rows.first?.bytes, 1_000)
        XCTAssertEqual(coord._aggregateTotalsForTesting().bytes, 1_000)
        XCTAssertTrue(coord._treeChildrenCacheForTesting().isEmpty,
                      "路径本身仍需从 UI cache 剔除，只有计量贡献不能采用")
    }

    func test_scanKnown与Common新会话统一清除旧tombstone() async throws {
        let coord = ScanCoordinator()
        let stalePath = "/tmp/prior-session/deleted"

        await coord.pruneDeleted(paths: [stalePath])
        XCTAssertTrue(coord._isDeletedTombstonedForTesting(stalePath + "/late"))
        let emptyHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: emptyHome)
        }

        coord.scanKnownVersionedRoots(home: emptyHome)
        XCTAssertFalse(coord._isDeletedTombstonedForTesting(stalePath + "/late"),
                       "KnownVersionedRoots 必须与普通扫描共享新会话 reset")
        coord.cancel()

        await coord.pruneDeleted(paths: [stalePath])
        XCTAssertTrue(coord._isDeletedTombstonedForTesting(stalePath + "/late"))
        coord.scanCommonAppCaches()
        XCTAssertFalse(coord._isDeletedTombstonedForTesting(stalePath + "/late"),
                       "CommonAppCaches 必须与普通扫描共享新会话 reset")
        coord.cancel()
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
