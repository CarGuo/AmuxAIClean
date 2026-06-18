import XCTest
@testable import ScanKit

/// v1.7 M1 PR-1：AppleWorkflow 6 张卡片的注入测试。
///
/// 测试矩阵（三场景）：
/// 1. **空 home**：无 ~/Library/Developer/* → cards 为空（已在 DeveloperWorkflowSkeletonTests 覆盖，本文件不重复）
/// 2. **仅部分子目录存在**：例如只有 DerivedData，验证只出对应卡片，其它不出
/// 3. **全部子目录存在**：验证 6 张卡全出 + ID 全局唯一 + risk 等级正确 + source 类型正确
///
/// 测试不依赖真实 ~ 路径：全部在 tmp 目录下构造伪 home。
final class AppleWorkflowCardsTests: XCTestCase {

    // MARK: - 部分存在场景

    func test_仅_DerivedData_存在_出_DerivedData_整删卡_与_per_project_同伴卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 只造 ~/Library/Developer/Xcode/DerivedData
        try makeDir(at: "Library/Developer/Xcode/DerivedData", in: home)

        // 注入 isSimulatorRunning=false 避免 CI 环境真扫 NSWorkspace
        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        // PR-2 起：DerivedData 同时出整删卡 + per-project 占位卡（同源不同粒度）
        XCTAssertEqual(cards.count, 2, "DerivedData 存在时出整删 + per-project 两张")
        let ids = Set(cards.map(\.id))
        XCTAssertEqual(ids, ["card.apple.derived-data", "card.apple.derived-data-per-project"])

        // 整删卡断言（PR-1 契约不变）
        let mainCard = try XCTUnwrap(cards.first(where: { $0.id == "card.apple.derived-data" }))
        XCTAssertEqual(mainCard.risk, .safe)
        XCTAssertEqual(mainCard.recipe, .filesystem)
        if case .literal(let paths) = mainCard.source {
            XCTAssertEqual(paths.count, 1)
            XCTAssertTrue(paths.first!.hasSuffix("Library/Developer/Xcode/DerivedData"))
        } else {
            XCTFail("DerivedData 整删卡应使用 .literal 源")
        }
    }

    func test_仅_CoreSimulator_存在_不出_Caches_卡_因为_Caches_子目录不存在() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 只造 ~/Library/Developer/CoreSimulator（无 Caches 子目录）
        try makeDir(at: "Library/Developer/CoreSimulator", in: home)

        // 注入 isSimulatorRunning=false（避免 CI 环境受 NSWorkspace 影响）
        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        XCTAssertFalse(cards.contains(where: { $0.id == "card.apple.coresimulator-caches" }),
                       "CoreSimulator 目录存在但 Caches 子目录不存在时，不应出 CoreSimulator Caches 卡")
        // PR-2 起：Runtimes 卡仅依赖 csRoot 存在（不需要子目录），所以这里允许出现
        XCTAssertTrue(cards.contains(where: { $0.id == "card.apple.coresimulator-runtimes" }),
                      "PR-2 起：CoreSimulator 根目录存在即出 Runtimes 卡")
    }

    func test_DeviceSupport_iOS_存在_使用_versionedRoot_源_不直接_literal_目录() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // DeviceSupport 目录本身存在即可触发卡片，无需子版本目录
        try makeDir(at: "Library/Developer/Xcode/iOS DeviceSupport", in: home)

        let cards = AppleWorkflow().cards(home: home)
        XCTAssertEqual(cards.count, 1)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.id, "card.apple.ios-devicesupport")
        XCTAssertEqual(card.risk, .safe)
        if case .versionedRoot(let ruleID) = card.source {
            XCTAssertEqual(ruleID, "apple.ios-device-support.versioned",
                           "DeviceSupport 必须复用 KnownVersionedRoots ruleID，不能 .literal 整目录")
        } else {
            XCTFail("DeviceSupport 必须使用 .versionedRoot 源")
        }
    }

    // MARK: - 全部存在场景

    func test_全部目录存在_出齐_10_张卡_且_ID_全局唯一_v17_PR2() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/Archives",
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/macOS DeviceSupport",
            "Library/Developer/CoreSimulator/Caches",
            "Library/Developer/CoreSimulator/Devices",  // PR-2 触发 devices 卡
            "Library/Developer/CoreSimulator/Volumes",  // PR-2 触发 volumes 卡
        ] {
            try makeDir(at: sub, in: home)
        }

        // 注入 isSimulatorRunning=false（确保 risk 期望稳定，不被 CI 上真跑 Simulator 干扰）
        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        // PR-2 后：6 PR-1 卡 + per-project + devices + runtimes + volumes = 10 张
        XCTAssertEqual(cards.count, 10, "PR-2 后全部目录存在时必须出齐 10 卡")

        let ids = cards.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "卡片 ID 必须全局唯一")

        let expectedIDs: Set<String> = [
            "card.apple.derived-data",
            "card.apple.derived-data-per-project",
            "card.apple.archives",
            "card.apple.ios-devicesupport",
            "card.apple.watchos-devicesupport",
            "card.apple.macos-devicesupport",
            "card.apple.coresimulator-caches",
            "card.apple.coresimulator-devices",
            "card.apple.coresimulator-runtimes",
            "card.apple.coresimulator-volumes",
        ]
        XCTAssertEqual(Set(ids), expectedIDs, "卡片 ID 集合与设计文档对位")
    }

    func test_Archives_risk_是_confirm_其它_5_张_是_safe() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/Archives",
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/macOS DeviceSupport",
            "Library/Developer/CoreSimulator/Caches",
        ] {
            try makeDir(at: sub, in: home)
        }

        let cards = AppleWorkflow().cards(home: home)
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

        XCTAssertEqual(byID["card.apple.archives"]?.risk, .confirm,
                       "Archives 必须 confirm（vendors.yaml L60）")
        for id in ["card.apple.derived-data",
                   "card.apple.ios-devicesupport",
                   "card.apple.watchos-devicesupport",
                   "card.apple.macos-devicesupport",
                   "card.apple.coresimulator-caches"] {
            XCTAssertEqual(byID[id]?.risk, .safe, "\(id) 风险等级应为 safe")
        }
    }

    func test_PR1_类卡片_recipe_全部filesystem_simctl卡_仅在simctl_ID下_v17_PR2() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/Archives",
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/macOS DeviceSupport",
            "Library/Developer/CoreSimulator/Caches",
        ] {
            try makeDir(at: sub, in: home)
        }

        // PITFALL：未来若有人把 PR-1 静态卡（DerivedData / Archives / DeviceSupport×3 / Caches / per-project / Volumes）
        // 任何一张偷偷改成 commandLine，本用例必须红
        let pr1AndFilesystemPR2: Set<String> = [
            "card.apple.derived-data",
            "card.apple.derived-data-per-project",
            "card.apple.archives",
            "card.apple.ios-devicesupport",
            "card.apple.watchos-devicesupport",
            "card.apple.macos-devicesupport",
            "card.apple.coresimulator-caches",
            "card.apple.coresimulator-volumes",
        ]
        let cards = AppleWorkflow(isSimulatorRunning: { false }).cards(home: home)
        for card in cards where pr1AndFilesystemPR2.contains(card.id) {
            if case .commandLine = card.recipe {
                XCTFail("\(card.id) 必须是 .filesystem recipe，不应泄漏到 .commandLine")
            }
            XCTAssertTrue(card.recipe.isExecutableInCurrentBuild,
                          "\(card.id) 必须在当前构建可执行")
        }

        // simctl 卡（commandLine）反向断言：仅 devices/runtimes 两 ID 允许 commandLine
        let allowedCommandLine: Set<String> = [
            "card.apple.coresimulator-devices",
            "card.apple.coresimulator-runtimes",
        ]
        for card in cards {
            if case .commandLine = card.recipe {
                XCTAssertTrue(allowedCommandLine.contains(card.id),
                              "\(card.id) 不在白名单内不应使用 .commandLine recipe")
                XCTAssertTrue(card.recipe.isExecutableInCurrentBuild,
                              "\(card.id) 的 commandLine 必须在 SubprocessExecutor allowlist 内")
            }
        }
    }

    func test_summary_文案非空且不超长_保证侧边栏渲染() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/Archives",
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/macOS DeviceSupport",
            "Library/Developer/CoreSimulator/Caches",
        ] {
            try makeDir(at: sub, in: home)
        }

        for card in AppleWorkflow().cards(home: home) {
            XCTAssertFalse(card.title.isEmpty, "title 不能为空：\(card.id)")
            XCTAssertFalse(card.summary.isEmpty, "summary 不能为空：\(card.id)")
            XCTAssertLessThanOrEqual(card.summary.count, 80,
                                     "summary 应 ≤ 80 字以保证 UI 不溢出：\(card.id)")
        }
    }

    // MARK: - 防回归

    func test_DeviceSupport_目录是文件而非目录_不应被识别为卡片() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 先造父目录
        try makeDir(at: "Library/Developer/Xcode", in: home)
        // 故意造成同名文件而非目录（伪造异常情况）
        let fakeFile = home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
        try Data().write(to: fakeFile)

        let cards = AppleWorkflow().cards(home: home)
        // 由于 Xcode 父目录存在，guard 通过；但同名是文件，dirExists 应返回 false
        XCTAssertFalse(cards.contains(where: { $0.id == "card.apple.ios-devicesupport" }),
                       "同名文件（非目录）不应被识别为可清理目录，防御性兜底")
    }

    // MARK: - helper

    private func makeTmpHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleWorkflowCardsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(at relativePath: String, in home: URL) throws {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
