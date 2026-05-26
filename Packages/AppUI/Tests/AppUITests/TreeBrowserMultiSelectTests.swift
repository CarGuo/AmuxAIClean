import XCTest
@testable import AppUI

/// v1.3.zzzz Phase 4-B：TreeBrowserView 多选 + 批量移废纸篓 行为单测。
///
/// 这组测试只覆盖 **pure helper** 层：[TreeBrowserView.sanitize(paths:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// SwiftUI @State 没法从外部反射构造，但 sanitize 是 static + 纯逻辑，
/// 单独 lock 它就足以保证"批量删时 forbid 路径绝不会进 urls"——
/// 这是 [batchActionBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift) 主按钮调用的最后一道闸门。
@MainActor
final class TreeBrowserMultiSelectTests: XCTestCase {

    // MARK: - sanitize: SafetyEngine forbid 路径必须被剔除

    func testSanitizeStripsForbiddenHomeDirectory() {
        // $HOME 自身：SafetyEngine forbid（删了用户全家就完了）
        let home = NSHomeDirectory()
        let result = TreeBrowserView.sanitize(paths: [home, "/tmp/safe-target"])
        XCTAssertFalse(result.contains(home), "$HOME 必须被 sanitize 剔除")
    }

    func testSanitizeStripsRootSlash() {
        // `/` 必拒
        let result = TreeBrowserView.sanitize(paths: ["/", "/tmp/safe-x"])
        XCTAssertFalse(result.contains("/"))
    }

    func testSanitizeStripsSystemDirectory() {
        // /System 是 SIP 保护、SafetyEngine forbid
        let result = TreeBrowserView.sanitize(paths: ["/System", "/tmp/safe-y"])
        XCTAssertFalse(result.contains("/System"))
    }

    // MARK: - sanitize: 安全路径必须保留

    func testSanitizeKeepsTempPaths() {
        let safe1 = "/tmp/cleanmac-batch-test-1"
        let safe2 = "/tmp/cleanmac-batch-test-2"
        let result = TreeBrowserView.sanitize(paths: [safe1, safe2])
        XCTAssertEqual(result, [safe1, safe2])
    }

    func testSanitizeKeepsCachesPaths() {
        // ~/Library/Caches 子路径是清理工具的主战场，必须放行
        let cache = NSHomeDirectory() + "/Library/Caches/com.fake.app"
        let result = TreeBrowserView.sanitize(paths: [cache])
        XCTAssertEqual(result, [cache])
    }

    // MARK: - sanitize: 混合输入

    func testSanitizeMixedKeepsSafeAndDropsForbid() {
        let home = NSHomeDirectory()
        let safe = "/tmp/cleanmac-mixed-safe"
        let result = TreeBrowserView.sanitize(paths: [home, safe, "/", "/System"])
        XCTAssertEqual(result, [safe], "只有 safe 那一条能活下来")
    }

    // MARK: - sanitize: 空集

    func testSanitizeEmptyReturnsEmpty() {
        XCTAssertEqual(TreeBrowserView.sanitize(paths: []), [])
    }
}
