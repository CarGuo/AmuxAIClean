import Darwin
import ScanKit
import XCTest
@testable import AppUI

@MainActor
final class ScanCoordinatorFullDiskTests: XCTestCase {

    /// `scanFullDisk()` 必须把 `currentRootPath` 立即置为 "/"。
    /// 不去等扫描完成（整盘真扫太慢/受 TCC 影响），只断言入口契约。
    func test_scanFullDisk_currentRootPath置为根斜杠() async throws {
        let coord = ScanCoordinator()
        XCTAssertNil(coord.currentRootPath, "尚未扫描时应为 nil")

        coord.scanFullDisk()
        XCTAssertEqual(coord.currentRootPath, "/",
                       "scanFullDisk 应把 currentRootPath 立刻置为 / ，让 UI 能渲染整盘视图")
        XCTAssertTrue(coord.isScanning, "应进入 isScanning")

        // 立即取消，避免单测真去扫整盘（CI 上没 TCC 也会卡很久）
        coord.cancel()
        XCTAssertFalse(coord.isScanning, "cancel 后应退出 isScanning")
    }

    /// `scanFullDisk()` 等价于 `scan(category: .fullDisk)`。
    func test_scanFullDisk_等价于scan_fullDisk_category() async throws {
        let coord1 = ScanCoordinator()
        coord1.scanFullDisk()
        let path1 = coord1.currentRootPath
        coord1.cancel()

        let coord2 = ScanCoordinator()
        coord2.scan(category: .fullDisk)
        let path2 = coord2.currentRootPath
        coord2.cancel()

        XCTAssertEqual(path1, path2)
        XCTAssertEqual(path1, "/")
    }

    /// 整盘 category 的 kind 必须是 .fullDisk —— UI 据此渲染特殊图标 / 引导。
    func test_fullDiskCategory_kind() {
        XCTAssertEqual(ScanCategory.fullDisk.kind, .fullDisk)
        XCTAssertEqual(ScanCategory.fullDisk.rootPath, "/")
        XCTAssertEqual(ScanCategory.fullDisk.id, "fulldisk.root")
    }

    func test_fullDiskBucketProjection_doesNotCreateDoubleSlash() {
        let app = ScanCoordinator.bucketProjection(nodePath: "/Applications/Xcode.app",
                                                   rootPath: "/")
        XCTAssertEqual(app?.tail, "Applications/Xcode.app")
        XCTAssertEqual(app?.bucketPath, "/Applications")

        let user = ScanCoordinator.bucketProjection(nodePath: "/Users/guoshuyu/Downloads/a.zip",
                                                    rootPath: "/")
        XCTAssertEqual(user?.tail, "Users/guoshuyu/Downloads/a.zip")
        XCTAssertEqual(user?.bucketPath, "/Users")

        XCTAssertNil(ScanCoordinator.bucketProjection(nodePath: "/", rootPath: "/"),
                     "根自身不能作为自己的第一级子节点")
    }

    func test_fullDiskFirmlinkDataVolumePath_mapsToPublicPathBeforeBucketAndStore() {
        let coord = ScanCoordinator()
        let library = coord._displayPathForScanNodeForTesting(
            "/System/Volumes/Data/Library/Caches/com.example/a.bin",
            rootPath: "/"
        )
        XCTAssertEqual(library, "/Library/Caches/com.example/a.bin",
                       "全盘扫描必须在入 bucket/store 前把 Data 卷 firmlink 投影回用户看到的 /Library，否则 /Library 会显示 0KB 且无法展开")

        let bucket = ScanCoordinator.bucketProjection(nodePath: library, rootPath: "/")
        XCTAssertEqual(bucket?.bucketPath, "/Library")
        XCTAssertEqual(bucket?.tail, "Library/Caches/com.example/a.bin")
    }

    func test_nonFullDiskScan_doesNotRewriteDataVolumePath() {
        let coord = ScanCoordinator()
        let path = "/System/Volumes/Data/Library/Caches/com.example/a.bin"
        XCTAssertEqual(
            coord._displayPathForScanNodeForTesting(path, rootPath: "/System/Volumes/Data"),
            path,
            "非全盘扫描不能擅自改写用户指定根路径，避免推荐/自定义扫描路径口径被污染"
        )
    }

    func test_fullDiskFirmlinkIncompleteEvidence_mapsIntoVisiblePathNamespace() {
        let coord = ScanCoordinator()
        let rawIssuePath = "/System/Volumes/Data/Users/example/Library/Locked"
        coord._testInjectIncomplete(
            ScanIncompleteIssue(
                path: rawIssuePath,
                reason: .permissionDenied,
                stage: .open,
                posixErrorCode: EACCES
            ),
            displayRootPath: "/"
        )

        let publicPath = "/Users/example/Library/Locked"
        XCTAssertEqual(coord.permissionDeniedPaths, [publicPath],
                       "整盘投影行与 typed issue 必须使用同一 firmlink 命名空间")
        XCTAssertEqual(coord._testAccessState(for: publicPath), .permissionDenied)
        XCTAssertEqual(
            coord._testSubtreeCompleteness(for: "/Users"),
            .containsIncompleteDescendant,
            "公开 /Users 行必须看到 Data 卷后代的不完整证据"
        )
        XCTAssertEqual(
            coord.incompleteIssues(overlappingAny: ["/Users"]).map(\.path),
            [publicPath],
            "删除父路径的 ancestor overlap 不得因 raw/public 路径不一致而漏拦"
        )
    }

    func test_fullDiskDirectChildren_usesSnapshotRowsForRootWhenStoreCacheMisses() {
        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        let rows = [
            RowItem(id: "/Applications",
                    url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                    title: "Applications",
                    isDirectory: true,
                    bytes: 300,
                    logicalBytes: 300,
                    fileCount: 2,
                    verdict: .safe,
                    rejection: .ok),
            RowItem(id: "/Users",
                    url: URL(fileURLWithPath: "/Users", isDirectory: true),
                    title: "Users",
                    isDirectory: true,
                    bytes: 100,
                    logicalBytes: 100,
                    fileCount: 1,
                    verdict: .safe,
                    rejection: .ok)
        ]
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: ScanCategory.fullDisk.id,
                                   rows: rows,
                                   totalBytes: 400,
                                   scannedFileCount: 3,
                                   isFinished: true,
                                   elapsed: 1),
            currentRootPath: "/"
        )

        let top = coord.directChildren(of: "/", sortedBy: .sizeDesc)
        XCTAssertEqual(top.map(\.path), ["/Applications", "/Users"])
        XCTAssertTrue(top.allSatisfy(\.hasChildren))
    }

    func test_fullDiskDirectChildren_doesNotUseSnapshotRowsWhileScanning() {
        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        let rows = [
            RowItem(id: "/Applications",
                    url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                    title: "Applications",
                    isDirectory: true,
                    bytes: 300,
                    logicalBytes: 300,
                    fileCount: 2,
                    verdict: .safe,
                    rejection: .ok)
        ]
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: ScanCategory.fullDisk.id,
                                   rows: rows,
                                   totalBytes: 300,
                                   scannedFileCount: 2,
                                   isFinished: false,
                                   elapsed: 1),
            currentRootPath: "/",
            isScanning: true
        )

        XCTAssertTrue(coord.directChildren(of: "/", sortedBy: .sizeDesc).isEmpty,
                      "扫描中不能用半成品 snapshot rows 直接画树根，避免滚动期持续抖动/卡死")
        XCTAssertTrue(coord._treeChildrenCacheForTesting().isEmpty,
                      "扫描中不应启动按需下钻写树缓存")
    }

    func test_treeChildrenOnlyStartAfterExplicitOnDemandRequest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TreeOnDemand-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data([0x01]).write(to: child)
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "test.category",
                                   rows: [],
                                   totalBytes: 1,
                                   scannedFileCount: 1,
                                   isFinished: true,
                                   elapsed: 1),
            currentRootPath: root.path,
            isScanning: false
        )

        let cacheKey = "\(parent.path)|\(TreeSortKey.sizeDesc.rawValue)"
        XCTAssertTrue(coord._treeChildrenInFlightForTesting().isEmpty,
                      "扫描完成不能无人触发地自动二次读取 top-level 子树")

        _ = coord.directChildren(of: parent.path, sortedBy: .sizeDesc)
        XCTAssertTrue(coord._treeChildrenInFlightForTesting().contains(cacheKey),
                      "用户显式展开时必须启动 staged shallow + deep 按需加载")

        let deadline = Date().addingTimeInterval(2)
        var cached: [TreeRow] = []
        while Date() < deadline {
            cached = coord._treeChildrenCacheForTesting()[cacheKey] ?? []
            if !cached.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(cached.map(\.path), [child.path])
    }

    func test_onDemandDeepPermissionDenied_doesNotLockDirectParent() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OnDemandAccess-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("A", isDirectory: true)
        let locked = parent.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "secret".write(to: locked.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "test",
                                   rows: [
                                    RowItem(
                                        id: parent.path,
                                        url: parent,
                                        title: parent.lastPathComponent,
                                        isDirectory: true,
                                        bytes: 1,
                                        logicalBytes: 1,
                                        fileCount: 1,
                                        verdict: .safe,
                                        rejection: .ok,
                                        hasChildren: true
                                    )
                                   ],
                                   totalBytes: 1,
                                   scannedFileCount: 1,
                                   isFinished: true,
                                   elapsed: 1),
            currentRootPath: root.path,
            isScanning: false
        )

        XCTAssertEqual(coord.directChildren(of: root.path).map(\.path), [parent.path],
                       "finished root snapshot 是权威结果，不应隐式重扫 root")
        _ = coord.directChildren(of: parent.path)
        let cacheKey = "\(parent.path)|\(TreeSortKey.sizeDesc.rawValue)"
        let deadline = Date().addingTimeInterval(3)
        var cached: [TreeRow] = []
        while Date() < deadline {
            cached = coord._treeChildrenCacheForTesting()[cacheKey] ?? []
            if !cached.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(cached.first { $0.path == locked.path },
                        "用户显式展开父目录后才应启动按需测量")
        XCTAssertEqual(coord._testAccessState(for: parent.path), .normal,
                       "深层 denied/TCC 只应该进入 banner/log，不能把已成功列出的直接父目录画成锁")
    }

    func test_snapshotTopLevelRows_usesFrozenFileKindWithoutRestatting() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FullDiskSnapshotRows-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent(".VolumeIcon.icns")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x01]).write(to: file)

        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "test",
                                   rows: [
                                    RowItem(id: file.path,
                                            url: file,
                                            title: file.lastPathComponent,
                                            // v2026.07.17: RowItem is the authoritative result
                                            // of ScanKit's top-level projection. Supplying the
                                            // opposite kind here used to require a synchronous
                                            // MainActor lstat for every visible row and directly
                                            // recreated the performance regression this suite
                                            // now prevents.
                                            isDirectory: false,
                                            bytes: 1,
                                            logicalBytes: 1,
                                            fileCount: 1,
                                            verdict: .safe,
                                            rejection: .ok,
                                            hasChildren: false)
                                   ],
                                   totalBytes: 1,
                                   scannedFileCount: 1,
                                   isFinished: true,
                                   elapsed: 1),
            currentRootPath: root.path
        )

        let top = coord.directChildren(of: root.path, sortedBy: .sizeDesc)
        XCTAssertEqual(top.count, 1)
        XCTAssertFalse(top[0].isDirectory)
        XCTAssertFalse(top[0].hasChildren)
    }

    func test_normalBucketProjection_keepsExistingRootSemantics() {
        let p = ScanCoordinator.bucketProjection(nodePath: "/Users/me/Library/Caches/a.bin",
                                                 rootPath: "/Users/me")
        XCTAssertEqual(p?.tail, "Library/Caches/a.bin")
        XCTAssertEqual(p?.bucketPath, "/Users/me/Library")

        XCTAssertNil(ScanCoordinator.bucketProjection(nodePath: "/Users/other/file",
                                                      rootPath: "/Users/me"))
    }
}
