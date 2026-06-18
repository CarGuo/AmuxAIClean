import XCTest
@testable import ScanKit

/// v1.7 M1 PR-1：DeveloperWorkflow 协议骨架契约测试。
///
/// 本测试**故意非常薄**——仅验证骨架不破不漏：
/// - AppleWorkflow.cards 返回空（避免半成品 UI 进入用户视线）；
/// - DeletionRecipe.commandLine 在当前构建下被显式禁执行（守住安全门）；
/// - 协议 ID 命名约定符合 docs/V17_M1_TASKS.md 规约。
///
/// 真正的卡片注入测试放 PR-2 / PR-3 落地时再补。
final class DeveloperWorkflowSkeletonTests: XCTestCase {

    func test_AppleWorkflow_ID_命名约定() {
        let wf = AppleWorkflow()
        XCTAssertEqual(wf.id, "workflow.apple",
                       "workflow ID 必须符合 `workflow.<ecosystem>` 约定")
        XCTAssertFalse(wf.displayName.isEmpty)
        XCTAssertFalse(wf.subtitle.isEmpty)
        XCTAssertLessThanOrEqual(wf.subtitle.count, 60, "subtitle 不应过长，避免侧边栏溢出")
    }

    func test_AppleWorkflow_空_home_cards_为空_无开发者目录不污染UI() {
        let wf = AppleWorkflow()
        let tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleWorkflow-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        XCTAssertTrue(wf.cards(home: tmpHome).isEmpty,
                      "无 ~/Library/Developer/Xcode 与 CoreSimulator 时必须返空，避免空入口污染 UI")
    }

    func test_DeletionRecipe_filesystem_允许执行() {
        XCTAssertTrue(DeletionRecipe.filesystem.isExecutableInCurrentBuild,
                      ".filesystem 是 v1.7 M1 唯一允许的 recipe")
    }

    func test_DeletionRecipe_commandLine_命中allowlist_允许执行_v17_PR2() {
        // v1.7 M1 PR-2 起开放：xcrun simctl delete 在 SubprocessExecutor.defaultAllowlist 内
        let recipe = DeletionRecipe.commandLine(executable: "/usr/bin/xcrun",
                                                args: ["simctl", "delete", "DEADBEEF"])
        XCTAssertTrue(recipe.isExecutableInCurrentBuild,
                      ".commandLine 命中 SubprocessExecutor allowlist 必须允许执行")
    }

    func test_DeletionRecipe_commandLine_未命中allowlist_仍然禁执行_安全门() {
        // PITFALL：未来若有人误改 isExecutableInCurrentBuild 为永远 true，此用例必须红
        let recipe = DeletionRecipe.commandLine(executable: "/bin/rm",
                                                args: ["-rf", "/"])
        XCTAssertFalse(recipe.isExecutableInCurrentBuild,
                       "未授权命令必须挡住，DeletionRecipe 是 SubprocessExecutor 之外的二道闸门")
    }

    func test_DeveloperCard_Risk_三档与_SafetyEngine_对齐() {
        // 仅做存在性校验，避免 Risk 重命名时悄悄破坏 UI 渲染契约。
        XCTAssertEqual(DeveloperCard.Risk.safe.rawValue, "safe")
        XCTAssertEqual(DeveloperCard.Risk.confirm.rawValue, "confirm")
        XCTAssertEqual(DeveloperCard.Risk.blocked.rawValue, "blocked")
    }
}
