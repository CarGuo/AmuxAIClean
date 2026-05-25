import XCTest
@testable import AppUI
import SafetyKit
import XPCBridge

final class HelperClientPipelineTests: XCTestCase {
    func testMockPipelineRoundTrip() async {
        let key = Data(repeating: 0xCD, count: 32)
        let mock = MockHelperClient(signingKey: key)
        let (moved, skipped, err) = await mock.moveToTrash(
            paths: ["/Users/test/Library/Caches/x"],
            dryRun: true
        )
        XCTAssertNil(err)
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(skipped, 0)
    }

    func testMockSelfVerifyAlwaysPasses() async {
        let key = Data("any-32-byte-secret-for-testing!!".utf8)
        let mock = MockHelperClient(signingKey: key)
        let (_, _, err) = await mock.moveToTrash(paths: ["/tmp/x"], dryRun: true)
        XCTAssertNil(err, "用同 key 自签自验必须通过")
    }

    func testMockBlocksRealDeleteWithoutDryRun() async {
        let key = Data(repeating: 0x01, count: 32)
        let mock = MockHelperClient(signingKey: key)
        let (moved, _, err) = await mock.moveToTrash(paths: ["/tmp/y"], dryRun: false)
        XCTAssertNotNil(err, "mock 不能真删")
        XCTAssertEqual(moved, 1) // 报告"会动"的项数
    }
}

final class ScanCategoryTests: XCTestCase {
    func testRecommendedCategoriesContainCachesAndDownloads() {
        let cats = ScanCategories.recommended(home: "/Users/foo")
        let ids = cats.map(\.id)
        XCTAssertTrue(ids.contains("user.caches"))
        XCTAssertTrue(ids.contains("user.downloads"))
        // 默认 verdict 区分
        let caches = cats.first { $0.id == "user.caches" }
        XCTAssertEqual(caches?.defaultVerdict, .safe)
        let dl = cats.first { $0.id == "user.downloads" }
        XCTAssertEqual(dl?.defaultVerdict, .confirm)
    }
}

final class RowItemSelectionTests: XCTestCase {
    func testForbidIsNotSelectable() {
        let r = RowItem(
            id: "a", url: URL(fileURLWithPath: "/System/Library/x"),
            title: "x", isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
            verdict: .forbid, rejection: .hardForbidPrefix
        )
        XCTAssertFalse(r.isSelectable)
        XCTAssertFalse(r.defaultSelected)
    }

    func testSafeIsDefaultSelected() {
        let r = RowItem(
            id: "b", url: URL(fileURLWithPath: "/Users/foo/Library/Caches/x"),
            title: "x", isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
            verdict: .safe, rejection: .ok
        )
        XCTAssertTrue(r.isSelectable)
        XCTAssertTrue(r.defaultSelected)
    }

    func testConfirmIsSelectableButNotDefaultOn() {
        let r = RowItem(
            id: "c", url: URL(fileURLWithPath: "/Users/foo/Downloads/x.zip"),
            title: "x.zip", isDirectory: false, bytes: 100, logicalBytes: 100, fileCount: 1,
            verdict: .confirm, rejection: .ok
        )
        XCTAssertTrue(r.isSelectable)
        XCTAssertFalse(r.defaultSelected)
    }
}

final class TrashPipelineTests: XCTestCase {
    func testEmptyPathsReturnsZero() async {
        let pipe = TrashPipeline()
        let (moved, skipped, err) = await pipe.moveToTrash(paths: [], dryRun: true)
        XCTAssertEqual(moved, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(err)
    }

    func testDryRunNeverTouchesDisk() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashPipelineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f = dir + "/keep.txt"
        try "hello".write(toFile: f, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (moved, _, err) = await pipe.moveToTrash(paths: [f], dryRun: true)
        XCTAssertEqual(moved, 1)
        XCTAssertNil(err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f), "dryRun 必须不动磁盘")
    }

    /// 真删测试 —— 在 CI 上会真把临时文件移到废纸篓，但因为是临时目录，无副作用
    func testRealRecycleMovesToTrash() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashPipelineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f = dir + "/will-trash.txt"
        try "bye".write(toFile: f, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (moved, skipped, err) = await pipe.moveToTrash(paths: [f], dryRun: false)
        XCTAssertNil(err)
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(skipped, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f), "真删后原路径应不存在")
    }
}

// MARK: - v1.3.zzzz Phase 4-A：默认视图模式断言（方案 C 落地防回归）

/// 这组测试 lock 死方案 C 的两条不变量：
/// - 默认视图模式 == `.tree`（任何回滚到 `.list` 的改动都立刻红线）
/// - `ResultsViewMode` 枚举形态稳定（case 顺序、label 文案、icon symbol 不许悄悄改），
///   是 [viewModeBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) UI 的隐性合同
final class MainViewDefaultViewModeTests: XCTestCase {

    func testPhase4ADefaultIsTree() {
        // 方案 C：默认走树形
        XCTAssertEqual(MainView.phase4ADefaultViewMode, .tree,
                       "方案 C 默认主视图必须是 .tree；任何回滚到 .list 的改动都不允许")
    }

    func testResultsViewModeCaseOrderIsListThenTree() {
        // segmented Picker 显示顺序依赖 CaseIterable.allCases 顺序
        // 调换会让用户老的肌肉记忆位置错位（清单原本在左、树形原本在右）
        XCTAssertEqual(MainView.ResultsViewMode.allCases, [.list, .tree])
    }

    func testResultsViewModeLabelsAreStable() {
        XCTAssertEqual(MainView.ResultsViewMode.list.label, "清单")
        XCTAssertEqual(MainView.ResultsViewMode.tree.label, "树形")
    }

    func testResultsViewModeIconsAreStable() {
        // SF Symbols 名是契约：换 icon 必须显式同步 viewModeBar 的角标 Label
        XCTAssertEqual(MainView.ResultsViewMode.list.icon, "list.bullet")
        XCTAssertEqual(MainView.ResultsViewMode.tree.icon, "rectangle.grid.1x2")
    }

    func testResultsViewModeRawValuesAreStable() {
        // rawValue 用于 @AppStorage / 持久化（如果未来加），不许悄悄改
        XCTAssertEqual(MainView.ResultsViewMode.list.rawValue, "list")
        XCTAssertEqual(MainView.ResultsViewMode.tree.rawValue, "tree")
    }
}
