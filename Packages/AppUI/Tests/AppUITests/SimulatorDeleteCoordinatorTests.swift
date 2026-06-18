import XCTest
import Foundation
import ScanKit
@testable import AppUI

/// v1.7 M1 PR-9：SimulatorDeleteCoordinator 单测。
///
/// 测试矩阵覆盖：
/// 1. prepare 空选 → .empty；
/// 2. prepare 命中 .filesystem 卡 → 跳过（不进 plan）；
/// 3. prepare 命中 .commandLine 卡但 commandLineTailArg=nil → .invalid；
/// 4. prepare Simulator running → .blockedSimulatorRunning；
/// 5. prepare 正常 → .ready，args 必须形如 `argsPrefix + [tailArg]`；
/// 6. execute dryRun=true → exitCode 0 + output 含 `<dryRun>`，但**不真起进程**（关键安全断言）；
/// 7. execute 多项 + 部分失败 → outcomes 数量 = items 数量，逐条独立结果；
/// 8. execute throw（注入空 allowlist）→ exitCode -3，不中断后续。
final class SimulatorDeleteCoordinatorTests: XCTestCase {
    private let uuid1 = "11111111-2222-3333-4444-555555555555"
    private let uuid2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let uuid3 = "12345678-1234-1234-1234-123456789abc"

    // MARK: - 工具：构造 card / hit

    private func deviceCard() -> DeveloperCard {
        DeveloperCard(
            id: "card.apple.coresimulator-devices",
            title: "iOS Simulator Devices",
            summary: "test",
            source: .dynamicScanner(scannerID: "scanner.simctl-devices"),
            recipe: .commandLine(executable: "/usr/bin/xcrun", args: ["simctl", "delete"]),
            risk: .confirm
        )
    }

    private func runtimeCard() -> DeveloperCard {
        DeveloperCard(
            id: "card.apple.coresimulator-runtimes",
            title: "iOS Simulator Runtimes",
            summary: "test",
            source: .dynamicScanner(scannerID: "scanner.simctl-runtimes"),
            recipe: .commandLine(executable: "/usr/bin/xcrun", args: ["simctl", "runtime", "delete"]),
            risk: .confirm
        )
    }

    private func fsCard() -> DeveloperCard {
        DeveloperCard(
            id: "card.apple.derived-data",
            title: "DerivedData",
            summary: "test",
            source: .literal(paths: []),
            recipe: .filesystem,
            risk: .safe
        )
    }

    private func hit(name: String, path: String, tail: String?) -> WorkflowScanHit {
        WorkflowScanHit(
            url: URL(fileURLWithPath: path),
            sizeBytes: 1024,
            displayName: name,
            note: nil,
            commandLineTailArg: tail
        )
    }

    private func makeCoordinator(dryRun: Bool = true,
                                 running: Bool = false,
                                 allowlist: [SubprocessExecutor.AllowEntry] = SubprocessExecutor.defaultAllowlist) -> SimulatorDeleteCoordinator {
        SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(allowlist: allowlist, timeout: 1, dryRun: dryRun),
            isSimulatorRunning: { running }
        )
    }

    // MARK: - prepare 分支

    /// PR-9：selected 为空 → .empty。
    func test_PR9_prepare_空选_产出empty_v17() {
        let coord = makeCoordinator()
        let plan = coord.prepare(cards: [deviceCard()], cardHits: [:], selected: [])
        XCTAssertEqual(plan, .empty)
    }

    /// PR-9：仅命中 .filesystem 卡 → .empty（commandLine 流程不处理它）。
    func test_PR9_prepare_filesystem卡_不进plan_v17() {
        let coord = makeCoordinator()
        let h = hit(name: "x", path: "/tmp/x", tail: nil)
        let plan = coord.prepare(cards: [fsCard()],
                                  cardHits: ["card.apple.derived-data": [h]],
                                  selected: [h.id])
        XCTAssertEqual(plan, .empty)
    }

    /// PR-9：.commandLine 卡命中但 hit.commandLineTailArg=nil → .invalid，
    /// 防止 args 拼成残缺命令把 allowlist 当后门。
    func test_PR9_prepare_missingTailArg_产出invalid_v17() {
        let coord = makeCoordinator()
        let h = hit(name: "broken", path: "/tmp/broken", tail: nil)
        let plan = coord.prepare(cards: [deviceCard()],
                                  cardHits: ["card.apple.coresimulator-devices": [h]],
                                  selected: [h.id])
        guard case let .invalid(reason) = plan else {
            return XCTFail("应当产出 .invalid")
        }
        XCTAssertTrue(reason.contains("broken"))
    }

    /// PR-9：Simulator 正在跑 → .blockedSimulatorRunning，**永远不放行**。
    /// 这是安全契约硬约束，防止破坏 booted 模拟器实例。
    func test_PR9_prepare_Simulator运行中_产出blocked_v17() {
        let coord = makeCoordinator(running: true)
        let h = hit(name: "iPhone 16", path: "/tmp/d", tail: uuid1)
        let plan = coord.prepare(cards: [deviceCard()],
                                  cardHits: ["card.apple.coresimulator-devices": [h]],
                                  selected: [h.id])
        guard case let .blockedSimulatorRunning(names) = plan else {
            return XCTFail("Simulator 在跑必须 blocked")
        }
        XCTAssertEqual(names, ["iPhone 16"])
    }

    /// PR-9：正常通路。
    /// args 严格 == `argsPrefix + [tailArg]`，确保 SubprocessExecutor allowlist 二道闸能命中。
    func test_PR9_prepare_正常_args严格拼接_v17() {
        let coord = makeCoordinator()
        let dev = hit(name: "iPhone 16", path: "/tmp/dev1", tail: uuid1)
        let rt  = hit(name: "iOS 18.0", path: "/tmp/rt1",  tail: "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        let plan = coord.prepare(
            cards: [deviceCard(), runtimeCard()],
            cardHits: [
                "card.apple.coresimulator-devices":  [dev],
                "card.apple.coresimulator-runtimes": [rt],
            ],
            selected: [dev.id, rt.id]
        )
        guard case let .ready(items) = plan else {
            return XCTFail("应产出 ready")
        }
        XCTAssertEqual(items.count, 2)
        let devItem = items.first { $0.hitID == dev.id }!
        XCTAssertEqual(devItem.executable, "/usr/bin/xcrun")
        XCTAssertEqual(devItem.args, ["simctl", "delete", uuid1])
        let rtItem = items.first { $0.hitID == rt.id }!
        XCTAssertEqual(rtItem.args, ["simctl", "runtime", "delete", "com.apple.CoreSimulator.SimRuntime.iOS-18-0"])
    }

    func test_PR9_prepare_invalidTailArg_产出invalid_v17() {
        let coord = makeCoordinator()
        let h = hit(name: "danger", path: "/tmp/danger", tail: "all")
        let plan = coord.prepare(cards: [deviceCard()],
                                 cardHits: ["card.apple.coresimulator-devices": [h]],
                                 selected: [h.id])
        guard case let .invalid(reason) = plan else {
            return XCTFail("非法 destructive tail 必须产出 .invalid")
        }
        XCTAssertTrue(reason.contains("danger"))
    }

    // MARK: - execute 分支

    /// PR-9：dryRun=true 时执行 → exitCode 0 + output 含 "<dryRun>" 标记，
    /// 这是 CI safe 与单测 safe 的核心契约。
    func test_PR9_execute_dryRun_不发真请求_v17() async {
        let coord = makeCoordinator(dryRun: true)
        let item = SimulatorDeleteCoordinator.Item(
            cardID: "card.apple.coresimulator-devices",
            hitID: "/tmp/dev1",
            displayName: "iPhone 16",
            executable: "/usr/bin/xcrun",
            args: ["simctl", "delete", uuid1]
        )
        let outcomes = await coord.execute(items: [item])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].exitCode, 0)
        XCTAssertTrue(outcomes[0].isSuccess)
        XCTAssertTrue(outcomes[0].truncatedOutput.contains("<dryRun>"))
        XCTAssertTrue(outcomes[0].truncatedOutput.contains(uuid1))
    }

    /// PR-9：execute 多项串行 → outcomes 数量 == items 数量，且次序保留。
    func test_PR9_execute_多项_顺序保留_v17() async {
        let coord = makeCoordinator(dryRun: true)
        let mk: (String) -> SimulatorDeleteCoordinator.Item = { udid in
            .init(cardID: "card.apple.coresimulator-devices",
                  hitID: "/tmp/\(udid)",
                  displayName: udid,
                  executable: "/usr/bin/xcrun",
                  args: ["simctl", "delete", udid])
        }
        let items = [uuid1, uuid2, uuid3].map(mk)
        let outcomes = await coord.execute(items: items)
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(outcomes.map { $0.item.displayName }, [uuid1, uuid2, uuid3])
        for outcome in outcomes {
            XCTAssertTrue(outcome.isSuccess)
        }
    }

    /// PR-9：execute 注入空 allowlist → SubprocessExecutor throw notAllowed，
    /// 协调器吞掉异常并标记 exitCode = -3，不中断后续项。
    func test_PR9_execute_throw时不中断后续_v17() async {
        // 空 allowlist → 任何调用都 throw notAllowed
        let coord = makeCoordinator(dryRun: true, allowlist: [])
        let items = (0..<3).map { i in
            SimulatorDeleteCoordinator.Item(
                cardID: "card.apple.coresimulator-devices",
                hitID: "/tmp/\(i)",
                displayName: "dev\(i)",
                executable: "/usr/bin/xcrun",
                args: ["simctl", "delete", "U\(i)"]
            )
        }
        let outcomes = await coord.execute(items: items)
        XCTAssertEqual(outcomes.count, 3, "throw 也必须 yield outcome，不中断")
        for outcome in outcomes {
            XCTAssertEqual(outcome.exitCode, -3)
            XCTAssertFalse(outcome.isSuccess)
            XCTAssertTrue(outcome.truncatedOutput.contains("throw"))
        }
    }
}

/// v1.7 M1 PR-9：WorkflowDetailViewModel 的 sheet/真删集成测试。
@MainActor
final class WorkflowDetailViewModel_PR9Tests: XCTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"

    /// PR-9：模拟用户 → performDelete → advance → executeConfirmed，
    /// 验证 sheet 状态机 firstReview → secondConfirm → nil。
    func test_PR9_sheet_状态机_firstReview_secondConfirm_v17() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WFDVM-PR9-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let wf = StubCommandLineWorkflow()
        let coord = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { false }
        )
        let vm = WorkflowDetailViewModel(workflow: wf, home: home, simulatorCoordinator: coord)
        // 不走 bootstrap（会真起 simctl），直接 setTestCards + setTestHits 模拟"扫描完成"
        vm.setTestCards(wf.cards(home: home))
        vm.setTestHits([
            "card.test.simctl": [WorkflowScanHit(
                url: URL(fileURLWithPath: "/tmp/dev"),
                sizeBytes: 0,
                displayName: "iPhone 16",
                note: nil,
                commandLineTailArg: uuid
            )]
        ])
        vm.toggleSelection(hitID: "/tmp/dev", on: true)

        let stubPipeline = StubPipelinePR9()
        await vm.performDelete(pipeline: stubPipeline)
        guard case .firstReview = vm.pendingSimctlStage else {
            return XCTFail("第一轮应进入 firstReview")
        }

        vm.advanceSimctlConfirm()
        guard case .secondConfirm = vm.pendingSimctlStage else {
            return XCTFail("第二轮应进入 secondConfirm")
        }

        await vm.executeConfirmedSimctl()
        XCTAssertNil(vm.pendingSimctlStage, "execute 后 sheet 应关闭")
        XCTAssertNotNil(vm.alertMessage, "应有 alert 文案兜底")
        XCTAssertTrue(vm.alertMessage?.contains("1") ?? false, "alert 应汇总成功 1 项")
    }

    /// PR-9：Simulator 运行中 → performDelete 不开 sheet，只 alert。
    func test_PR9_performDelete_Simulator运行中_不弹sheet_v17() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WFDVM-PR9b-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let wf = StubCommandLineWorkflow()
        let coord = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { true }
        )
        let vm = WorkflowDetailViewModel(workflow: wf, home: home, simulatorCoordinator: coord)
        vm.setTestCards(wf.cards(home: home))
        vm.setTestHits([
            "card.test.simctl": [WorkflowScanHit(
                url: URL(fileURLWithPath: "/tmp/dev"),
                sizeBytes: 0,
                displayName: "iPhone 16",
                note: nil,
                commandLineTailArg: uuid
            )]
        ])
        vm.toggleSelection(hitID: "/tmp/dev", on: true)

        await vm.performDelete(pipeline: StubPipelinePR9())
        XCTAssertNil(vm.pendingSimctlStage, "Simulator 在跑时不应弹 sheet")
        // v2026.06.16 修复 #4：blockedSimulatorRunning 现在写入 lastDeleteResult.safetyRejected，
        // 由 OperationResultSheet 展示具体哪个 Simulator 进程在跑——替代旧的 alertMessage 文案拼接。
        XCTAssertNotNil(vm.lastDeleteResult, "Simulator 在跑时应有结构化结果 payload 弹 OperationResultSheet")
        let blocked = vm.lastDeleteResult?.safetyRejected ?? []
        XCTAssertTrue(blocked.contains(where: { $0.path == "simulator-running" }),
                      "blockedSimulatorRunning 必须以 safetyRejected 一条 'simulator-running' 暴露给 UI")
    }
}

// MARK: - Stubs

/// 单卡 commandLine workflow，专供 PR-9 测试。
private struct StubCommandLineWorkflow: DeveloperWorkflow {
    let id = "workflow.test"
    let displayName = "Test Workflow"
    let subtitle = "for PR-9"
    func cards(home: URL) -> [DeveloperCard] {
        [DeveloperCard(
            id: "card.test.simctl",
            title: "Test simctl card",
            summary: "test",
            source: .dynamicScanner(scannerID: "scanner.simctl-devices"),
            recipe: .commandLine(executable: "/usr/bin/xcrun", args: ["simctl", "delete"]),
            risk: .confirm
        )]
    }
}

/// 不真删的 pipeline stub。
private struct StubPipelinePR9: DeletionPipeline {
    func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
        return (0, 0, nil, [])
    }
    /// v2026.06.17 (AUDIT A2)：协议取消 no-op 默认实现后，测试 stub 必须显式 no-op。
    func setAccessDeniedPaths(_ paths: Set<String>) { /* test stub: no-op */ }
}

// 测试侧 helper 移除：直接调 setTestHits / setTestCards。
