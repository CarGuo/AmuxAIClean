import XCTest
@testable import AppUI
import SafetyKit

// v1.3.zzzz 路线 B：HelperClient / MockHelperClient / XPCBridge 已整段下线，
// 删除链路只剩 TrashPipeline 一份；原 HelperClientPipelineTests 三个 case 一并随之删除。

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
@MainActor
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
        // i18n 化后 label 来自 String(localized: "main.results.mode.*", bundle: .module)；
        // 在 SPM xctest 下 Bundle.module 通常 fallback 到 key 字符串，
        // 生产 App 内会渲染为中文/英文。测试只断言 label 非空且两 case 不同。
        let listLabel = MainView.ResultsViewMode.list.label
        let treeLabel = MainView.ResultsViewMode.tree.label
        XCTAssertFalse(listLabel.isEmpty)
        XCTAssertFalse(treeLabel.isEmpty)
        XCTAssertNotEqual(listLabel, treeLabel)
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
