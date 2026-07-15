import Darwin
import XCTest
import SafetyKit
@testable import AppUI
@testable import ScanKit

/// M4-T2 集成测试：[ScanCoordinator.scanKnownVersionedRoots](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L710)
///
/// 覆盖：
/// 1. 注入临时 home + 构造 Xcode iOS DeviceSupport 4 个版本子目录
///    → snapshot.rows 应只剩 2 条（keepLatest=2，保留最新 2 版）
/// 2. snapshot.categoryID = "developer.versioned" + isFinished=true
/// 3. lastFinishedCategoryID / isScanning / currentRootPath 状态正确
/// 4. 空 home（无任何 entries 命中）→ rows 空、isFinished=true、不崩溃
@MainActor
final class ScanCoordinatorKnownVersionedRootsTests: XCTestCase {

    func test_scanKnownVersionedRoots_命中4版本Xcode_仅产2条旧版候选() async throws {
        let tmp = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let support = tmp.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // 构造 4 个版本目录：keepLatest=2 → 应淘汰最旧 2 版
        for v in ["15.0", "16.0", "17.0", "18.0"] {
            let dir = support.appendingPathComponent(v, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload = dir.appendingPathComponent("a.bin")
            try Data("payload".utf8).write(to: payload)
            if v == "15.0" {
                let handle = try FileHandle(forWritingTo: payload)
                try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
                try handle.close()
                try FileManager.default.linkItem(
                    at: payload,
                    to: dir.appendingPathComponent("a-hardlink.bin")
                )
            }
        }

        let coord = ScanCoordinator(home: tmp.path)
        coord.scanKnownVersionedRoots(home: tmp)
        // v2026.06.21 P0：scanKnownVersionedRoots 改为 Task.detached 派后台扫 IO，
        // 需要轮询等 snapshot 落地，与 [ScanCoordinatorStoreTests.waitScanFinished]
        // 同模式（轮询 isScanning + snapshot.isFinished，30ms 间隔，6s 超时）。
        try await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.categoryID, "developer.versioned")
        XCTAssertEqual(coord.snapshot.isFinished, true)
        XCTAssertEqual(coord.snapshot.rows.count, 2,
                       "keepLatest=2 → 4 版本中应有 2 版被识别为可回收旧版")
        XCTAssertEqual(
            coord.snapshot.scannedFileCount,
            coord.snapshot.rows.reduce(0) { $0 + $1.fileCount },
            "扫描文件数必须汇总候选目录内的真实文件数，不能误用候选行数"
        )
        XCTAssertFalse(coord.isScanning)
        XCTAssertNil(coord.activeCategoryID, "完成的版本扫描不能继续占有活跃会话")
        XCTAssertEqual(coord.currentRootPath, ScanCoordinator.versionedRootSentinelPath,
                       "v2026.06.21：开发者旧版本扫描统一用 sentinel 让 TreeBrowserView 走合成顶层")
        // 每条 row 必须是 Xcode DeviceSupport 子目录之一
        for row in coord.snapshot.rows {
            XCTAssertTrue(row.url.path.hasPrefix(support.path),
                          "row 应位于 collectionRoot 子目录下，got=\(row.url.path)")
            XCTAssertTrue(row.isDirectory)
        }
        let sparseVersion = try XCTUnwrap(
            coord.snapshot.rows.first(where: { $0.url.lastPathComponent == "15.0" })
        )
        XCTAssertLessThan(sparseVersion.bytes, 64 * 1_024 * 1_024,
                          "旧版本主值必须使用系统磁盘占用，不能显示 sparse 虚拟容量")
        XCTAssertGreaterThan(sparseVersion.logicalBytes, 1 * 1_024 * 1_024 * 1_024,
                             "旧版本详情仍应保留 Finder 式逻辑容量")
        var metadata = stat()
        let original = support.appendingPathComponent("15.0/a.bin")
        XCTAssertEqual(lstat(original.path, &metadata), 0)
        XCTAssertEqual(sparseVersion.bytes, Int64(metadata.st_blocks) * 512,
                       "同一旧版本目录中的 hardlink 不能重复计算磁盘占用")
        XCTAssertEqual(sparseVersion.logicalBytes, Int64(metadata.st_size),
                       "logical 副值也要按同一 inode 会话去重")
    }

    func test_scanKnownVersionedRoots_空home_finishedSnapshotWithEmptyRows() async throws {
        let tmp = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

        let coord = ScanCoordinator(home: tmp.path)
        coord.scanKnownVersionedRoots(home: tmp)
        try await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.count, 0)
        XCTAssertEqual(coord.snapshot.isFinished, true)
        XCTAssertFalse(coord.isScanning)
    }

    func test_scanKnownVersionedRoots_加载白名单后不发布受保护旧版本() async throws {
        let tmp = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let support = tmp.appendingPathComponent(
            "Library/Developer/Xcode/iOS DeviceSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for version in ["15.0", "16.0", "17.0", "18.0"] {
            let directory = support.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: directory.appendingPathComponent("a.bin"))
        }

        let whitelist = WhitelistStore(storageURL: nil)
        let protected = support.appendingPathComponent("15.0", isDirectory: true)
        await whitelist.add(path: protected.path, reason: "test")
        let coordinator = ScanCoordinator(
            home: tmp.path,
            whitelistStore: whitelist
        )

        coordinator.scanKnownVersionedRoots(home: tmp)
        try await waitScanFinished(coordinator)

        XCTAssertEqual(coordinator.snapshot.rows.map(\.url.path), [
            support.appendingPathComponent("16.0", isDirectory: true).path
        ])
    }

    func test_scanKnownVersionedRoots_隐藏文件计入同一扫描会话大小() async throws {
        let tmp = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let support = tmp.appendingPathComponent(
            "Library/Developer/Xcode/iOS DeviceSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for version in ["15.0", "16.0", "17.0", "18.0"] {
            let directory = support.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0x1]).write(to: directory.appendingPathComponent("visible.bin"))
        }
        let hidden = support.appendingPathComponent("15.0/.hidden-payload")
        try Data(repeating: 0x7f, count: 1_048_576).write(to: hidden)

        let coordinator = ScanCoordinator(home: tmp.path)
        coordinator.scanKnownVersionedRoots(home: tmp)
        try await waitScanFinished(coordinator)

        let row = try XCTUnwrap(
            coordinator.snapshot.rows.first { $0.url.lastPathComponent == "15.0" }
        )
        XCTAssertGreaterThanOrEqual(
            row.logicalBytes,
            1_048_577,
            "旧枚举器会跳过隐藏项；删除预览必须与完整目录使用同一口径"
        )
        XCTAssertEqual(row.fileCount, 2)
        XCTAssertEqual(
            coordinator.snapshot.scannedFileCount,
            coordinator.snapshot.rows.reduce(0) { $0 + $1.fileCount }
        )
    }

    func test_scanKnownVersionedRoots_权限拒绝子树锁住父候选并保留证据() async throws {
        let tmp = try makeTempHome()
        let support = tmp.appendingPathComponent(
            "Library/Developer/Xcode/iOS DeviceSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for version in ["15.0", "16.0", "17.0", "18.0"] {
            let directory = support.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0x1]).write(to: directory.appendingPathComponent("visible.bin"))
        }
        let locked = support.appendingPathComponent("15.0/locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([0x2]).write(to: locked.appendingPathComponent("secret.bin"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer {
            XCTAssertEqual(chmod(locked.path, S_IRWXU), 0)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp))
        }

        let coordinator = ScanCoordinator(home: tmp.path)
        coordinator.scanKnownVersionedRoots(home: tmp)
        try await waitScanFinished(coordinator)

        let row = try XCTUnwrap(
            coordinator.snapshot.rows.first { $0.url.lastPathComponent == "15.0" }
        )
        XCTAssertEqual(row.verdict, .forbid)
        XCTAssertEqual(row.rejection, .accessDenied)
        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.snapshot.isComplete,
                       "候选含未扫描子树时只能发布部分终态，不能伪装成完整成功")
        XCTAssertTrue(
            coordinator.permissionDeniedPaths.contains(locked.path),
            "被拒子树必须进入最终 TrashPipeline 的祖先/后代拒绝集合"
        )
        XCTAssertTrue(
            coordinator.incompleteScanPaths.contains(locked.path),
            "权限拒绝也是扫描完整性缺口，但不能冒充成另一个 FDA 路径"
        )
    }

    func test_scanKnownVersionedRoots_发现根无法枚举不能伪装成空成功() async throws {
        let tmp = try makeTempHome()
        let support = tmp.appendingPathComponent(
            "Library/Developer/Xcode/iOS DeviceSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for version in ["15.0", "16.0", "17.0", "18.0"] {
            let directory = support.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        XCTAssertEqual(chmod(support.path, 0), 0)
        defer {
            XCTAssertEqual(chmod(support.path, S_IRWXU), 0)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp))
        }

        let coordinator = ScanCoordinator(home: tmp.path)
        coordinator.scanKnownVersionedRoots(home: tmp)
        try await waitScanFinished(coordinator)

        XCTAssertTrue(coordinator.snapshot.rows.isEmpty,
                      "候选集不完整时不得基于残缺版本集产出可删 hit")
        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.snapshot.isComplete,
                       "发现失败是部分终态，不是完整的空结果")
        XCTAssertTrue(coordinator.permissionDeniedPaths.contains(support.path))
        XCTAssertTrue(coordinator.incompleteScanPaths.contains(support.path))
        XCTAssertNil(coordinator.lastError,
                     "精确 partial 由统一 limitations presentation 展示，不能冒充整轮致命错误")
        XCTAssertNil(coordinator.terminalFailure)
        XCTAssertEqual(
            ScanIssuePresentation.make(
                hasTerminalFailure: coordinator.terminalFailure != nil,
                permissionDeniedPaths: coordinator.permissionDeniedPaths,
                tccSkippedPaths: coordinator.tccProtectedSkippedPaths,
                incompletePaths: coordinator.incompleteScanPaths
            ).kind,
            .limitations
        )
    }

    func test_scanKnownVersionedRoots_取消后不允许迟到结果覆盖空快照() async throws {
        let tmp = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let support = tmp.appendingPathComponent(
            "Library/Developer/Xcode/iOS DeviceSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for version in ["15.0", "16.0", "17.0", "18.0"] {
            let directory = support.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<64 {
                try Data(repeating: UInt8(index), count: 4_096).write(
                    to: directory.appendingPathComponent("payload-\(index).bin")
                )
            }
        }

        let coordinator = ScanCoordinator(home: tmp.path)
        coordinator.scanKnownVersionedRoots(home: tmp)
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(coordinator.wasCancelled)
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertEqual(coordinator.snapshot.categoryID, ScanSnapshot.empty.categoryID)
        XCTAssertTrue(coordinator.snapshot.rows.isEmpty)
        XCTAssertFalse(coordinator.snapshot.isFinished)
    }

    // MARK: - helpers

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorKnownVersioned-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 轮询等扫描事件循环结束（isScanning false 且 snapshot.isFinished）。
    /// 复用 [ScanCoordinatorStoreTests.waitScanFinished] 的 30ms 间隔 + 6s 超时策略。
    private func waitScanFinished(_ coord: ScanCoordinator,
                                  timeout: TimeInterval = 6) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while (coord.isScanning || !coord.snapshot.isFinished) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(coord.isScanning, "扫描应在测试超时前结束")
        XCTAssertTrue(coord.snapshot.isFinished, "扫描应发布 finished snapshot")
    }
}
