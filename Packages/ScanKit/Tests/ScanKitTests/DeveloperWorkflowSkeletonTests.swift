import XCTest
@testable import ScanKit

/// v1.7 M1 PR-1：DeveloperWorkflow 协议骨架契约测试。
///
/// 本测试**故意非常薄**——仅验证骨架不破不漏：
/// - AppleWorkflow.cards 返回空（避免半成品 UI 进入用户视线）；
/// - 托管卸载 recipe 是封闭类型，不接受任意 executable/args；
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

    func test_ManagedUninstallRecipe_仅包含两种CoreSimulator资源() {
        XCTAssertEqual(Set(ManagedUninstallRecipe.allCases), [.simulatorDevice, .simulatorRuntime])
        XCTAssertEqual(ManagedUninstallRecipe.simulatorDevice.rawValue, "simulatorDevice")
        XCTAssertEqual(ManagedUninstallRecipe.simulatorRuntime.rawValue, "simulatorRuntime")
    }

    func test_ManagedUninstallRecipe_命令前缀由类型固定() {
        XCTAssertEqual(ManagedUninstallRecipe.simulatorDevice.executable, "/usr/bin/xcrun")
        XCTAssertEqual(ManagedUninstallRecipe.simulatorDevice.argsPrefix, ["simctl", "delete"])
        XCTAssertEqual(ManagedUninstallRecipe.simulatorRuntime.executable, "/usr/bin/xcrun")
        XCTAssertEqual(ManagedUninstallRecipe.simulatorRuntime.argsPrefix,
                       ["simctl", "runtime", "delete"])
    }

    func test_DeletionRecipe_managedUninstall_两种都命中allowlist二道闸() {
        for managed in ManagedUninstallRecipe.allCases {
            XCTAssertTrue(DeletionRecipe.managedUninstall(managed).isExecutableInCurrentBuild,
                          "\(managed) 必须与 SubprocessExecutor allowlist 严格对齐")
        }
    }

    func test_DeveloperCard_Risk_三档与_SafetyEngine_对齐() {
        // 仅做存在性校验，避免 Risk 重命名时悄悄破坏 UI 渲染契约。
        XCTAssertEqual(DeveloperCard.Risk.safe.rawValue, "safe")
        XCTAssertEqual(DeveloperCard.Risk.confirm.rawValue, "confirm")
        XCTAssertEqual(DeveloperCard.Risk.blocked.rawValue, "blocked")
    }
}
