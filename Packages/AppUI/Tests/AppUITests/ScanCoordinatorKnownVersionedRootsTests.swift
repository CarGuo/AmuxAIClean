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
        defer { try? FileManager.default.removeItem(at: tmp) }
        let support = tmp.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // 构造 4 个版本目录：keepLatest=2 → 应淘汰最旧 2 版
        for v in ["15.0", "16.0", "17.0", "18.0"] {
            let dir = support.appendingPathComponent(v, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: dir.appendingPathComponent("a.bin"))
        }

        let coord = ScanCoordinator(home: tmp.path)
        coord.scanKnownVersionedRoots(home: tmp)
        // v2026.06.21 P0：scanKnownVersionedRoots 改为 Task.detached 派后台扫 IO，
        // 需要轮询等 snapshot 落地，与 [ScanCoordinatorStoreTests.waitScanFinished]
        // 同模式（轮询 isScanning + snapshot.isFinished，30ms 间隔，6s 超时）。
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.categoryID, "developer.versioned")
        XCTAssertEqual(coord.snapshot.isFinished, true)
        XCTAssertEqual(coord.snapshot.rows.count, 2,
                       "keepLatest=2 → 4 版本中应有 2 版被识别为可回收旧版")
        XCTAssertFalse(coord.isScanning)
        XCTAssertEqual(coord.currentRootPath, ScanCoordinator.versionedRootSentinelPath,
                       "v2026.06.21：开发者旧版本扫描统一用 sentinel 让 TreeBrowserView 走合成顶层")
        // 每条 row 必须是 Xcode DeviceSupport 子目录之一
        for row in coord.snapshot.rows {
            XCTAssertTrue(row.url.path.hasPrefix(support.path),
                          "row 应位于 collectionRoot 子目录下，got=\(row.url.path)")
            XCTAssertTrue(row.isDirectory)
        }
    }

    func test_scanKnownVersionedRoots_空home_finishedSnapshotWithEmptyRows() async throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let coord = ScanCoordinator(home: tmp.path)
        coord.scanKnownVersionedRoots(home: tmp)
        await waitScanFinished(coord)

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
        await waitScanFinished(coordinator)

        XCTAssertEqual(coordinator.snapshot.rows.map(\.url.path), [
            support.appendingPathComponent("16.0", isDirectory: true).path
        ])
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
                                  timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (coord.isScanning || !coord.snapshot.isFinished) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }
    }
}
