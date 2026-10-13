import XCTest
@testable import AppUI
@testable import ScanKit

/// v1.3：ScanCoordinator 多根并行扫描入口（scanRecommended）契约测试。
///
/// 关心三件事：
/// 1. 启动后 perRootProgress 立刻含 5 个根（UI 在第一个事件前就要能渲染）；
/// 2. cancel() 必须把 perRootProgress 清空；
/// 3. 真扫一遍小 fixture，所有根 finish 后 isScanning=false 且 perRootProgress 全部 isFinished=true。
@MainActor
final class ScanCoordinatorMultiTests: XCTestCase {

    /// 在 /tmp 下造一个 fake-home，预置 ScanCategories.recommended 的 5 个根目录骨架，
    /// 每根写入 1-2 个小文件让扫描有真东西扫。
    private func makeFakeHome() throws -> String {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "AmuxAICleanScanCoordMulti-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        let subs = [
            "Library/Caches",
            "Library/Logs",
            "Library/Developer/Xcode/DerivedData",
            "Downloads",
            ".Trash"
        ]
        for s in subs {
            let dir = home + "/" + s
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // 写一个小文件，避免空目录被某些路径过滤掉，也让 fileCount 能跨过 0。
            try Data(repeating: 0xAB, count: 256)
                .write(to: URL(fileURLWithPath: dir + "/sample.bin"))
        }
        return home
    }

    private func cleanup(_ home: String) {
        try? FileManager.default.removeItem(atPath: home)
    }

    /// 等指定条件成立，超时 timeout 秒。
    private func waitUntil(_ timeout: TimeInterval = 5,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }
    }

    func test_scanRecommended启动后立刻含5个根() async throws {
        let home = try makeFakeHome()
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        XCTAssertTrue(coord.perRootProgress.isEmpty, "未扫描时应为空")

        coord.scanRecommended(includeHidden: true)
        // 同步部分立即生效（scanRecommended 不是 async）
        XCTAssertEqual(coord.perRootProgress.count, 5,
                       "scanRecommended 应在启动同帧预填 5 条 perRootProgress，UI 立刻能渲染 5 行")
        XCTAssertEqual(coord.currentRootPath, ScanCoordinator.multiRootSentinelPath,
                       "currentRootPath 应被设为多目录占位，避免 UI 用具体某根作展示主体")
        XCTAssertTrue(coord.isScanning, "应进入 isScanning")

        coord.cancel()
    }

    func test_scanRecommended扫描中树表不暴露staging半成品_完成后显示最终根节点() async throws {
        let home = try makeFakeHome()
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)

        XCTAssertEqual(coord.perRootProgress.count, 5,
                       "顶部进度仍应立即拿到 5 个根")
        XCTAssertTrue(coord.directChildren(of: ScanCoordinator.multiRootSentinelPath,
                                           sortedBy: .sizeDesc).isEmpty,
                      "扫描中树表不应读取 perRootStaging，否则会显示 8KB/0KB 这种目录 inode 半成品")

        await waitUntil(10) { !coord.isScanning }

        let rows = coord.directChildren(of: ScanCoordinator.multiRootSentinelPath,
                                        sortedBy: .sizeDesc)
        XCTAssertEqual(rows.count, 5,
                       "扫描完成后树表才应显示 5 个推荐根")
        XCTAssertTrue(rows.allSatisfy { $0.bytes >= 256 && $0.fileCount >= 1 },
                      "完成态树表应使用最终 perRootProgress，不应继续显示半成品 0KB/0 文件")
    }

    func test_cancel清空perRootProgress() async throws {
        let home = try makeFakeHome()
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)
        XCTAssertFalse(coord.perRootProgress.isEmpty)

        coord.cancel()
        XCTAssertTrue(coord.perRootProgress.isEmpty,
                      "cancel 后必须把 perRootProgress 清空，否则 statusBar 残留旧根的'扫描中'行")
        XCTAssertFalse(coord.isScanning)
    }

    func test_elapsedForDisplay扫描中不依赖snapshot发布节奏() async throws {
        let home = try makeFakeHome()
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)
        defer { coord.cancel() }

        XCTAssertEqual(coord.snapshot.elapsed, 0, "启动同帧 snapshot 仍可能是 0")
        let displayElapsed = coord.elapsedForDisplay(referenceDate: Date().addingTimeInterval(3))
        XCTAssertGreaterThanOrEqual(displayElapsed, 2.9,
                                    "扫描中 UI 工作计时必须按 startedAt 推进，不能依赖下一帧 snapshot")
    }

    func test_多根全部finish后isScanning翻false且每根都isFinished() async throws {
        let home = try makeFakeHome()
        defer { cleanup(home) }

        let coord = ScanCoordinator(home: home)
        coord.scanRecommended(includeHidden: true)

        await waitUntil(10) { !coord.isScanning }

        XCTAssertFalse(coord.isScanning, "5 根全部扫完后 isScanning 必须翻 false")
        XCTAssertTrue(coord.snapshot.isFinished, "snapshot 也应进入 finished 态")
        // 5 个根都应有 isFinished=true
        XCTAssertEqual(coord.perRootProgress.count, 5)
        for (rootPath, p) in coord.perRootProgress {
            XCTAssertTrue(p.isFinished,
                          "扫描结束后每根 perRootProgress.isFinished 都应是 true，未翻的根：\(rootPath)")
        }
    }
}
