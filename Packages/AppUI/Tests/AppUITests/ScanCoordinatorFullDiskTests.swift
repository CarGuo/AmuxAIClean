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
}
