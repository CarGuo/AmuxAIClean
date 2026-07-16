import XCTest
@testable import ScanKit

/// v1.7 M1 PR-2 + v2026.07.15 safety fix：AppleWorkflow simctl/per-project 专项测试。
///
/// 与 [AppleWorkflowCardsTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Tests/ScanKitTests/AppleWorkflowCardsTests.swift) 的分工：
/// - AppleWorkflowCardsTests 守 PR-1 6 张静态卡 + PR-2 整体集合契约（9 张卡 / ID 唯一）；
/// - 本文件聚焦 PR-2 3 张新卡及 Volumes 禁止入口的独立行为：
///   - devices 卡：仅当 `~/Library/Developer/CoreSimulator/Devices` 存在才出
///   - runtimes 卡：仅当 csRoot 存在即出（无需子目录，因为 runtime 是 simctl 自报数据）
///   - volumes：即使目录存在也不生成卡，避免把 CoreSimulator 挂载卷伪装成废纸篓操作
///   - per-project 卡：仅当 DerivedData 存在才出，且为 .dynamicScanner + .filesystem
/// - Simulator 运行中 → devices/runtimes risk = blocked 的安全门
///
/// 注入测试：所有用例都显式 `isSimulatorRunning` 闭包，避免 NSWorkspace 在 CI 上不可用导致偶发。
final class AppleWorkflowPR2CardsTests: XCTestCase {

    // MARK: - simctl Devices 卡

    func test_Devices卡_仅当_CoreSimulator_Devices_子目录存在才出() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator", in: home)
        // 故意不造 Devices 子目录

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        XCTAssertFalse(cards.contains(where: { $0.id == "card.apple.coresimulator-devices" }),
                       "PITFALL：CoreSimulator/Devices 不存在时 devices 卡必须不出")
    }

    func test_Devices卡_存在时_recipe_是类型化托管卸载() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator/Devices", in: home)

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        let card = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.coresimulator-devices" }))

        if case .managedUninstall(let managed) = card.recipe {
            XCTAssertEqual(managed, .simulatorDevice)
            XCTAssertEqual(managed.executable, "/usr/bin/xcrun")
            XCTAssertEqual(managed.argsPrefix, ["simctl", "delete"])
        } else {
            XCTFail("Devices 卡必须用封闭的 .managedUninstall(.simulatorDevice) recipe")
        }

        XCTAssertTrue(card.recipe.isExecutableInCurrentBuild,
                      "PITFALL：Devices recipe 必须命中 SubprocessExecutor allowlist")

        if case .dynamicScanner(let scannerID) = card.source {
            XCTAssertEqual(scannerID, "scanner.simctl-devices")
        } else {
            XCTFail("Devices 卡 source 必须为 .dynamicScanner")
        }
    }

    // MARK: - simctl Runtimes 卡

    func test_Runtimes卡_仅当_CoreSimulator_根目录存在才出_无需子目录() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator", in: home)

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        XCTAssertTrue(cards.contains(where: { $0.id == "card.apple.coresimulator-runtimes" }),
                      "Runtime 数据来自 simctl JSON 而非 FS 枚举，因此 csRoot 在即出卡")
    }

    func test_Runtimes卡_recipe_是类型化托管卸载() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator", in: home)

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        let card = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.coresimulator-runtimes" }))

        if case .managedUninstall(let managed) = card.recipe {
            XCTAssertEqual(managed, .simulatorRuntime)
            XCTAssertEqual(managed.executable, "/usr/bin/xcrun")
            XCTAssertEqual(managed.argsPrefix, ["simctl", "runtime", "delete"])
        } else {
            XCTFail("Runtimes 卡必须用封闭的 .managedUninstall(.simulatorRuntime) recipe")
        }
        XCTAssertTrue(card.recipe.isExecutableInCurrentBuild)
    }

    // MARK: - Volumes 禁止入口

    func test_Volumes目录存在时_也不生成可清理卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator/Volumes", in: home)

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        XCTAssertFalse(
            cards.contains(where: { $0.id == "card.apple.coresimulator-volumes" }),
            "CoreSimulator/Volumes 是挂载卷且规则为 forbid，只能由受管 runtime 卸载间接管理"
        )
    }

    // MARK: - per-project 卡

    func test_perProject卡_伴随DerivedData卡出现_且为_dynamicScanner_filesystem() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/Xcode/DerivedData", in: home)

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        let card = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.derived-data-per-project" }))

        XCTAssertEqual(card.recipe, .filesystem)
        XCTAssertEqual(card.risk, .safe)

        if case .dynamicScanner(let scannerID) = card.source {
            XCTAssertEqual(scannerID, "scanner.derived-data-per-project")
        } else {
            XCTFail("per-project 卡 source 必须为 .dynamicScanner 占位（实现在 PR-4）")
        }
    }

    func test_perProject卡_DerivedData不存在时不出() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/Xcode/Archives", in: home)  // 造别的，不造 DerivedData

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        XCTAssertFalse(cards.contains(where: { $0.id == "card.apple.derived-data-per-project" }),
                       "DerivedData 不存在时 per-project 卡必须不出，避免空入口")
    }

    // MARK: - Simulator 运行中的安全门

    func test_Simulator运行中_Devices_Runtimes_两卡_risk降级为_blocked() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator/Devices", in: home)

        // 注入"运行中" stub
        let cards = AppleWorkflow(isSimulatorRunning: { true }).cards(home: home)

        let devices = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.coresimulator-devices" }))
        let runtimes = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.coresimulator-runtimes" }))

        XCTAssertEqual(devices.risk, .blocked,
                       "PITFALL：Simulator.app 运行时删 devices 会破坏正在运行的实例，必须 blocked")
        XCTAssertEqual(runtimes.risk, .blocked)

        // 产品契约：summary 存 xcstrings raw key（blocked 分支 → `.summary.blocked`），
        // UI 层用 LocalizedStringKey 消费。此处锁 key 后缀，不锁翻译后字面量。
        XCTAssertTrue(devices.summary.hasSuffix(".summary.blocked"),
                      "blocked 时 summary 必须命中 blocked 分支 key，实际=\(devices.summary)")
        XCTAssertTrue(runtimes.summary.hasSuffix(".summary.blocked"),
                      "实际=\(runtimes.summary)")
    }

    func test_Simulator未运行_Devices_Runtimes_两卡_risk为_confirm() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDir(at: "Library/Developer/CoreSimulator/Devices", in: home)

        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)

        let devices = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.coresimulator-devices" }))
        let runtimes = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.coresimulator-runtimes" }))

        XCTAssertEqual(devices.risk, .confirm, "未运行时应允许用户在 confirm 后删除")
        XCTAssertEqual(runtimes.risk, .confirm)

        XCTAssertFalse(devices.summary.contains("⚠️"),
                       "未运行时 summary 不应带警告，避免误导")
    }

    // MARK: - helper

    private func makeTmpHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplePR2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(at relativePath: String, in home: URL) throws {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
