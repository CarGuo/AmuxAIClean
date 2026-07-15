import Dispatch
import SafetyKit
import ScanKit
import XCTest
@testable import AppUI

@MainActor
final class ScanCoordinatorCommonAppCacheTests: XCTestCase {

    func test_scanCommonAppCaches_publishesOnlyExistingNonEmptyRuleHits() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let wechat = home.appendingPathComponent("Library/Caches/com.tencent.xinWeChat",
                                                 isDirectory: true)
        let empty = home.appendingPathComponent("Library/Caches/com.empty.App",
                                                isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Application Support/Zoom/data/VirtualBkgnd_Custom",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: wechat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        let wechatFile = wechat.appendingPathComponent("cache.bin")
        let confirmFile = confirm.appendingPathComponent("background.bin")
        try Data(repeating: 0xAB, count: 128).write(to: wechatFile)
        try Data(repeating: 0xCD, count: 256).write(to: confirmFile)
        let wechatAllocated = try allocatedBytes(of: wechatFile)
        let confirmAllocated = try allocatedBytes(of: confirmFile)

        let vendors = [
            VendorRule(
                name: "WeChat Cache",
                bundleIDPrefix: "com.tencent.xinWeChat",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .safe,
                             reason: "cache")
                ]
            ),
            VendorRule(
                name: "Empty Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.empty.App",
                             verdict: .safe,
                             reason: "empty")
                ]
            ),
            VendorRule(
                name: "Zoom Virtual Backgrounds",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Application Support/Zoom/data/VirtualBkgnd_Custom",
                             verdict: .confirm,
                             reason: "user-selected backgrounds")
                ]
            ),
            VendorRule(
                name: "Blocked Neighbor",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .forbid,
                             reason: "blocked")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.categoryID, ScanCoordinator.commonAppCacheCategoryID)
        XCTAssertEqual(coord.currentRootPath, ScanCoordinator.commonAppCacheSentinelPath)
        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertFalse(coord.isScanning)
        XCTAssertNil(coord.activeCategoryID)
        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Zoom Virtual Backgrounds", "WeChat Cache"])
        XCTAssertEqual(coord.snapshot.totalBytes, wechatAllocated + confirmAllocated)
        XCTAssertEqual(coord.snapshot.scannedFileCount, 2)

        let verdicts = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.verdict) })
        XCTAssertEqual(verdicts["WeChat Cache"], .safe)
        XCTAssertEqual(verdicts["Zoom Virtual Backgrounds"], .confirm)
        let prefixes = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.runningBundleIDPrefix) })
        XCTAssertEqual(prefixes["WeChat Cache"]!, "com.tencent.xinWeChat")
        XCTAssertEqual(coord.snapshot.safeBytes, wechatAllocated)
        XCTAssertEqual(coord.snapshot.confirmBytes, confirmAllocated)
        let logicalByTitle = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.logicalBytes) })
        XCTAssertEqual(logicalByTitle["WeChat Cache"], 128)
        XCTAssertEqual(logicalByTitle["Zoom Virtual Backgrounds"], 256)
    }

    func test_scanCommonAppCaches_treeRootShowsSnapshotRows() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = home.appendingPathComponent("Library/Caches/com.demo.App",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cacheFile = cache.appendingPathComponent("cache.bin")
        try Data(repeating: 0xAB, count: 64).write(to: cacheFile)
        let allocated = try allocatedBytes(of: cacheFile)

        let vendors = [
            VendorRule(
                name: "Demo Cache",
                bundleIDPrefix: "com.demo.App",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Caches/com.demo.App",
                             verdict: .safe,
                             reason: "cache")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        let children = coord.directChildren(of: ScanCoordinator.commonAppCacheSentinelPath,
                                            sortedBy: .sizeDesc)
        XCTAssertEqual(children.map(\.title), ["Demo Cache"])
        XCTAssertEqual(children.first?.bytes, allocated)
        XCTAssertEqual(children.first?.logicalBytes, 64)
        XCTAssertEqual(children.first?.hasChildren, true)
    }

    func test_scanCommonAppCaches_canExcludeConfirmRules() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let safe = home.appendingPathComponent("Library/Caches/safe", isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Caches/confirm", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        let safeFile = safe.appendingPathComponent("a.bin")
        try Data(repeating: 0xAA, count: 11).write(to: safeFile)
        try Data(repeating: 0xBB, count: 22).write(to: confirm.appendingPathComponent("b.bin"))
        let safeAllocated = try allocatedBytes(of: safeFile)

        let vendors = [
            VendorRule(
                name: "Safe Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/safe", verdict: .safe, reason: "safe")
                ]
            ),
            VendorRule(
                name: "Confirm Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/confirm", verdict: .confirm, reason: "confirm")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.scanCommonAppCaches(includeConfirm: false)
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Safe Cache"])
        XCTAssertEqual(coord.snapshot.totalBytes, safeAllocated)
        XCTAssertEqual(coord.snapshot.rows.first?.logicalBytes, 11)
        XCTAssertEqual(coord.snapshot.confirmBytes, 0)
    }

    func test_scanCommonAppCaches_incompleteRootFlowsIntoParentDeletionHardDeny() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cachesRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let cache = cachesRoot.appendingPathComponent("com.example.Partial", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 19).write(to: cache.appendingPathComponent("a.bin"))
        try Data(repeating: 0xBB, count: 23).write(to: cache.appendingPathComponent("b.bin"))

        let vendors = [VendorRule(
            name: "Partial Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Partial", verdict: .safe)]
        )]
        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.scanCommonAppCaches(
            scannerOptions: CommonAppCacheScanner.Options(maxEntriesPerPath: 1)
        )
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.map(\.url.standardizedFileURL.path),
                       [cache.standardizedFileURL.path],
                       "partial bytes 可以展示，但必须同时携带删除保护上下文")
        XCTAssertEqual(coord.permissionDeniedPaths, [],
                       "entry limit 是通用扫描不完整，不能被误报成 FDA 权限拒绝")
        XCTAssertEqual(coord.incompleteScanPaths, [cache.standardizedFileURL.path])
        XCTAssertTrue(coord.snapshot.isFinished,
                      "部分结果仍是终态，不能让 UI/Smart Care 永久等待")
        XCTAssertFalse(coord.snapshot.isComplete,
                       "带不完整证据的终态不能发布为成功完成")
        let rowsBeforeSort = coord.snapshot.rows
        coord.mainListSortKey = .nameAsc
        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertFalse(coord.snapshot.isComplete,
                       "排序重发布只能改变展示顺序，不能把 partial 终态提升为成功")
        XCTAssertEqual(Set(coord.snapshot.rows), Set(rowsBeforeSort),
                       "专用扫描结果没有通用 buckets，排序不能把已发布 rows 清空")
        XCTAssertEqual(coord.snapshot.rows.first?.verdict, .forbid,
                       "不完整统计只能展示为不可选项，不能先作为 safe 再等删除时失败")
        XCTAssertEqual(coord.snapshot.rows.first?.rejection, .accessDenied)

        let partition = TrashPipeline.partitionByForbid(
            paths: [cachesRoot.path],
            safety: SafetyEngine(),
            accessDeniedPaths: Set(coord.permissionDeniedPaths)
                .union(coord.incompleteScanPaths),
            home: home.path
        )
        XCTAssertTrue(partition.allowed.isEmpty)
        XCTAssertEqual(partition.rejected.first?.reason, .accessDenied,
                       "不完整子树必须阻止 Smart Care/统一删除入口移除其父根")
    }

    func test_scanCommonAppCaches_旧轮晚返回不能覆盖同类别继续扫描() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.Generation",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 73)
            .write(to: cache.appendingPathComponent("current.bin"))

        let vendors = [VendorRule(
            name: "Current Generation",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Generation", verdict: .safe)]
        )]
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let newStarted = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        var releasedOld = false
        var releasedNew = false
        defer {
            if !releasedOld { releaseOld.signal() }
            if !releasedNew { releaseNew.signal() }
        }

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.commonAppCacheDetector = { _, _, options in
            if options.timeoutSeconds == 101 {
                oldStarted.signal()
                releaseOld.wait()
                // 故意模拟不协作 Task cancellation 的同步旧 detector：空结果若能提交，
                // 会把正在运行的新一轮覆盖成“扫描完成但无结果”。
                return CommonAppCacheScanner.ScanResult(hits: [], incompletePaths: [])
            }
            newStarted.signal()
            releaseNew.wait()
            return CommonAppCacheScanner.ScanResult(
                hits: [CommonAppCacheScanner.Hit(
                    ruleName: "Current Generation",
                    bundleIDPrefix: nil,
                    source: "generation-test",
                    url: cache,
                    isDirectory: true,
                    verdict: .safe,
                    reason: "current",
                    sizeBytes: 73,
                    logicalSizeBytes: 2 * 1_024 * 1_024 * 1_024,
                    entryCount: 1
                )],
                incompletePaths: []
            )
        }

        coord.scanCommonAppCaches(
            scannerOptions: CommonAppCacheScanner.Options(timeoutSeconds: 101)
        )
        XCTAssertEqual(oldStarted.wait(timeout: .now() + 2), .success)

        coord.scanCommonAppCaches(
            scannerOptions: CommonAppCacheScanner.Options(timeoutSeconds: 202)
        )
        XCTAssertEqual(newStarted.wait(timeout: .now() + 2), .success)

        releaseOld.signal()
        releasedOld = true
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(coord.isScanning,
                      "旧轮返回时，新 generation 仍必须保有扫描状态与最终提交权")
        XCTAssertFalse(coord.snapshot.isFinished)
        XCTAssertEqual(coord.activeCategoryID, ScanCoordinator.commonAppCacheCategoryID)

        releaseNew.signal()
        releasedNew = true
        await waitScanFinished(coord)

        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Current Generation"])
        XCTAssertEqual(coord.snapshot.totalBytes, 73)
        XCTAssertEqual(coord.snapshot.rows.first?.logicalBytes, 2 * 1_024 * 1_024 * 1_024)
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorCommonAppCache-\(UUID().uuidString)",
                                    isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func allocatedBytes(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private func waitScanFinished(_ coord: ScanCoordinator,
                                  timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while coord.isScanning && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                return
            }
        }
    }
}
