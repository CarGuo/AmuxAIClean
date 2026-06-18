import XCTest
@testable import ScanKit

/// WebNodeWorkflow 6 张卡片的注入测试。
///
/// 测试矩阵：
/// 1. **空 home**：5 张缓存卡条件都不满足 → 仅出 scattered 卡（始终输出）；
/// 2. **仅 pnpm-store 存在**：出 pnpm-store + node-gyp + electron + scattered（4 张）；
/// 3. **全部目录存在**：出齐 6 张 + ID 全局唯一；
/// 4. **scattered 卡**：source 必为 `.dynamicScanner("scanner.node-modules-scattered")`；
/// 5. **所有卡 recipe 都是 .filesystem**：本工作流不引入任何 .commandLine；
/// 6. **risk 等级**：5 张缓存卡 safe + scattered confirm。
///
/// 测试不依赖真实 ~ 路径：全部在 tmp 目录下构造伪 home。
final class WebNodeWorkflowCardsTests: XCTestCase {

    // MARK: - 场景 1：空 home

    func test_空home_仅输出_scattered_卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cards = WebNodeWorkflow().cards(home: home)
        XCTAssertEqual(cards.count, 3,
                       "空 home：pnpm/yarn/npm 三张条件卡不出；node-gyp + electron + scattered 始终输出")
        let ids = Set(cards.map(\.id))
        XCTAssertEqual(ids, [
            "card.webnode.node-gyp-cache",
            "card.webnode.electron-cache",
            "card.webnode.node-modules-scattered",
        ])
    }

    // MARK: - 场景 2：单条件命中

    func test_仅_pnpm_store_存在_出_pnpm_卡_而_yarn_npm_不出() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 只造新版 pnpm store
        try makeDir(at: "Library/pnpm/store", in: home)

        let cards = WebNodeWorkflow().cards(home: home)
        let ids = Set(cards.map(\.id))
        XCTAssertTrue(ids.contains("card.webnode.pnpm-store"),
                      "~/Library/pnpm/store 存在应出 pnpm-store 卡")
        XCTAssertFalse(ids.contains("card.webnode.yarn-cache"),
                       "yarn 相关目录均不存在不应出 yarn-cache 卡")
        XCTAssertFalse(ids.contains("card.webnode.npm-cache"),
                       "~/.npm 不存在不应出 npm-cache 卡")
        // node-gyp / electron / scattered 始终输出
        XCTAssertTrue(ids.contains("card.webnode.node-gyp-cache"))
        XCTAssertTrue(ids.contains("card.webnode.electron-cache"))
        XCTAssertTrue(ids.contains("card.webnode.node-modules-scattered"))
        XCTAssertEqual(cards.count, 4)
    }

    func test_pnpm_老路径_存在_也应触发_pnpm_卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 只造老版兼容路径 ~/.pnpm-store
        try makeDir(at: ".pnpm-store", in: home)

        let cards = WebNodeWorkflow().cards(home: home)
        XCTAssertTrue(cards.contains(where: { $0.id == "card.webnode.pnpm-store" }),
                      "PITFALL：~/.pnpm-store 老路径任一存在也应触发 pnpm 卡")
    }

    func test_yarn_v1_路径_存在_触发_yarn_卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeDir(at: "Library/Caches/Yarn", in: home)

        let cards = WebNodeWorkflow().cards(home: home)
        XCTAssertTrue(cards.contains(where: { $0.id == "card.webnode.yarn-cache" }),
                      "Yarn v1 路径 ~/Library/Caches/Yarn 存在应触发 yarn-cache 卡")
    }

    func test_npm_仅父目录存在_触发_npm_卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 仅造 ~/.npm 父目录，不造 _cacache
        try makeDir(at: ".npm", in: home)

        let cards = WebNodeWorkflow().cards(home: home)
        let npmCard = cards.first(where: { $0.id == "card.webnode.npm-cache" })
        XCTAssertNotNil(npmCard, "~/.npm 父目录存在即可触发 npm 卡，无需 _cacache 子目录")
        if case .literal(let paths) = npmCard?.source {
            XCTAssertEqual(paths, ["~/.npm/_cacache", "~/.npm"],
                           "npm 卡应同时下发 _cacache 与父目录两条路径")
        } else {
            XCTFail("npm 卡必须用 .literal 源")
        }
    }

    // MARK: - 场景 3：全部存在

    func test_全部目录存在_出齐_6_张卡_且_ID_全局唯一() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/pnpm/store",
            ".pnpm-store",
            "Library/Caches/Yarn",
            ".yarn/cache",
            ".cache/yarn",
            ".npm/_cacache",
            "Library/Caches/node-gyp",
            "Library/Caches/electron",
            "Library/Application Support/Caches/electron",
        ] {
            try makeDir(at: sub, in: home)
        }

        let cards = WebNodeWorkflow().cards(home: home)
        XCTAssertEqual(cards.count, 6, "全部目录存在时必须出齐 6 张卡")

        let ids = cards.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "卡片 ID 必须全局唯一")

        let expectedIDs: Set<String> = [
            "card.webnode.pnpm-store",
            "card.webnode.yarn-cache",
            "card.webnode.npm-cache",
            "card.webnode.node-gyp-cache",
            "card.webnode.electron-cache",
            "card.webnode.node-modules-scattered",
        ]
        XCTAssertEqual(Set(ids), expectedIDs)
    }

    // MARK: - 场景 4：scattered 卡 source 类型

    func test_scattered_卡_source_必为_dynamicScanner() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cards = WebNodeWorkflow().cards(home: home)
        let scattered = try XCTUnwrap(
            cards.first(where: { $0.id == "card.webnode.node-modules-scattered" }),
            "scattered 卡必须始终输出"
        )
        if case .dynamicScanner(let id) = scattered.source {
            XCTAssertEqual(id, "scanner.node-modules-scattered",
                           "scattered 卡的 scannerID 必须与 WorkflowRegistry 路由表 case 字面值一致")
        } else {
            XCTFail("scattered 卡 source 必须是 .dynamicScanner")
        }
        XCTAssertEqual(scattered.risk, .confirm,
                       "scattered 卡删除影响工程本地 install 速度，必须 confirm")
        XCTAssertEqual(scattered.recipe, .filesystem,
                       "scattered 卡走回收站（NSWorkspace.recycle），不应引入 commandLine")
    }

    // MARK: - 场景 5：所有卡 recipe 都是 filesystem

    func test_所有卡_recipe_都是_filesystem_本工作流不引入_commandLine() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 把能造的都造上，让 6 张卡全部出场
        for sub in [
            "Library/pnpm/store",
            "Library/Caches/Yarn",
            ".npm",
            "Library/Caches/node-gyp",
            "Library/Caches/electron",
        ] {
            try makeDir(at: sub, in: home)
        }

        let cards = WebNodeWorkflow().cards(home: home)
        XCTAssertEqual(cards.count, 6)
        for card in cards {
            if case .commandLine = card.recipe {
                XCTFail("\(card.id) 不应使用 .commandLine recipe；WebNode 工作流统一走回收站")
            }
            XCTAssertEqual(card.recipe, .filesystem, "\(card.id) recipe 必须是 .filesystem")
            XCTAssertTrue(card.recipe.isExecutableInCurrentBuild,
                          "\(card.id) 的 .filesystem 永远应当可执行")
        }
    }

    // MARK: - 场景 6：risk 等级

    func test_risk_5张缓存卡_safe_scattered_confirm() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/pnpm/store",
            "Library/Caches/Yarn",
            ".npm",
        ] {
            try makeDir(at: sub, in: home)
        }

        let cards = WebNodeWorkflow().cards(home: home)
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

        for id in [
            "card.webnode.pnpm-store",
            "card.webnode.yarn-cache",
            "card.webnode.npm-cache",
            "card.webnode.node-gyp-cache",
            "card.webnode.electron-cache",
        ] {
            XCTAssertEqual(byID[id]?.risk, .safe, "\(id) 风险等级应为 safe")
        }
        XCTAssertEqual(byID["card.webnode.node-modules-scattered"]?.risk, .confirm,
                       "scattered 卡必须 confirm")
    }

    func test_summary_文案非空且不超长_保证侧边栏渲染() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            "Library/pnpm/store",
            "Library/Caches/Yarn",
            ".npm",
        ] {
            try makeDir(at: sub, in: home)
        }

        for card in WebNodeWorkflow().cards(home: home) {
            XCTAssertFalse(card.title.isEmpty, "title 不能为空：\(card.id)")
            XCTAssertFalse(card.summary.isEmpty, "summary 不能为空：\(card.id)")
            XCTAssertLessThanOrEqual(card.summary.count, 80,
                                     "summary 应 ≤ 80 字以保证 UI 不溢出：\(card.id)")
        }
    }

    // MARK: - helper

    private func makeTmpHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebNodeWorkflowCardsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(at relativePath: String, in home: URL) throws {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
