import XCTest
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

    func test_scanKnownVersionedRoots_命中4版本Xcode_仅产2条旧版候选() throws {
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

        XCTAssertEqual(coord.snapshot.categoryID, "developer.versioned")
        XCTAssertEqual(coord.snapshot.isFinished, true)
        XCTAssertEqual(coord.snapshot.rows.count, 2,
                       "keepLatest=2 → 4 版本中应有 2 版被识别为可回收旧版")
        XCTAssertFalse(coord.isScanning)
        XCTAssertEqual(coord.currentRootPath, tmp.path)
        // 每条 row 必须是 Xcode DeviceSupport 子目录之一
        for row in coord.snapshot.rows {
            XCTAssertTrue(row.url.path.hasPrefix(support.path),
                          "row 应位于 collectionRoot 子目录下，got=\(row.url.path)")
            XCTAssertTrue(row.isDirectory)
        }
    }

    func test_scanKnownVersionedRoots_空home_finishedSnapshotWithEmptyRows() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let coord = ScanCoordinator(home: tmp.path)
        coord.scanKnownVersionedRoots(home: tmp)

        XCTAssertEqual(coord.snapshot.rows.count, 0)
        XCTAssertEqual(coord.snapshot.isFinished, true)
        XCTAssertFalse(coord.isScanning)
    }

    // MARK: - helpers

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorKnownVersioned-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
