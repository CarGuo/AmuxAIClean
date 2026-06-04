import XCTest
@testable import SafetyKit

/// 2026-06-04 批量补 10 个 vendor 的端到端契约（docs/AUDIT_2026_06.md L113 / L115-L122）。
///
/// 与 InstallerLeftoversVendorTests.swift 同样的 4 契约范式，但 10 个 vendor 共用一个
/// 测试文件——因为它们都是"纯数据 + path 级 verdict 钉死"，无独立产品代码。
///
/// 测试覆盖的 vendor（vendors.yaml L949-L1089）：
/// - 包管理器组：NuGet / Bazel / Zig / Corepack / PerlCPAN / CondaNative
/// - 系统残留组：MailDownloads / FinalCutProRender / JetBrainsToolbox / DarwinUserTemp
///
/// 全部断言"现状钉死"——vendor 作者改 yaml 必须先改测试，防止 silent drift。
final class BatchVendorAdditionsTests: XCTestCase {

    // MARK: - 契约 1：10 个 vendor 全部成功落地（未被 RuleLoader 误剔）

    func test_批量vendor_10条全部存在() throws {
        let rules = try Self.loadRealRules()
        let names: Set<String> = [
            "NuGet", "Bazel", "Zig", "Corepack", "PerlCPAN", "CondaNative",
            "MailDownloads", "FinalCutProRender",
            "JetBrainsToolbox", "DarwinUserTemp",
        ]
        let loaded = Set(rules.map { $0.name })
        for n in names {
            XCTAssertTrue(loaded.contains(n),
                          "vendors.yaml 应包含 '\(n)'，但缺失（可能因 hardForbid 过滤被整条丢弃）")
        }
    }

    // MARK: - 契约 2：每个 vendor 的代表性 path verdict 钉死

    func test_批量vendor_代表性path的verdict精确钉死() throws {
        let rules = try Self.loadRealRules()
        func verdict(of vendorName: String, _ path: String) -> SafetyVerdict? {
            guard let v = rules.first(where: { $0.name == vendorName }) else { return nil }
            return v.paths.first(where: { $0.path == path })?.verdict
        }

        // —— 包管理器组：缓存全 safe ——
        XCTAssertEqual(verdict(of: "NuGet", "~/.nuget/packages"), .safe,
                       "dotnet restore 可自愈")
        XCTAssertEqual(verdict(of: "NuGet", "~/Library/Caches/NuGet"), .safe)
        XCTAssertEqual(verdict(of: "Bazel", "~/.cache/bazel"), .safe,
                       "Bazel output user root，可达数十 GB")
        XCTAssertEqual(verdict(of: "Bazel", "~/.cache/bazelisk"), .safe)
        XCTAssertEqual(verdict(of: "Zig", "~/.cache/zig"), .safe)
        XCTAssertEqual(verdict(of: "Zig", "~/.cache/zls"), .safe)
        XCTAssertEqual(verdict(of: "Corepack", "~/Library/Caches/node/corepack"), .safe)
        XCTAssertEqual(verdict(of: "Corepack", "~/.cache/node/corepack"), .safe)
        XCTAssertEqual(verdict(of: "PerlCPAN", "~/.cpan/build"), .safe)
        XCTAssertEqual(verdict(of: "PerlCPAN", "~/.cpanm/work"), .safe)
        XCTAssertEqual(verdict(of: "CondaNative", "~/miniconda3/pkgs"), .safe)
        XCTAssertEqual(verdict(of: "CondaNative", "~/anaconda3/pkgs"), .safe)
        XCTAssertEqual(verdict(of: "CondaNative", "~/.conda/pkgs"), .safe)

        // —— CondaNative 凭证保护：.condarc 必须 forbid ——
        XCTAssertEqual(verdict(of: "CondaNative", "~/.condarc"), .forbid,
                       "含私有 channel 凭证 / proxy 设置，不可删")

        // —— 系统残留组 ——
        XCTAssertEqual(
            verdict(of: "MailDownloads",
                    "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            .confirm,
            "Mail.app 附件下载，删后无法重新打开历史附件")
        XCTAssertEqual(verdict(of: "MailDownloads", "~/Library/Mail Downloads"), .confirm)

        XCTAssertEqual(verdict(of: "FinalCutProRender",
                               "~/Movies/Final Cut Backups.localized"), .confirm,
                       "FCP 项目自动备份，删后无法回滚 untracked 编辑")
        XCTAssertEqual(verdict(of: "FinalCutProRender",
                               "~/Library/Caches/com.apple.FinalCut"), .safe)

        XCTAssertEqual(
            verdict(of: "JetBrainsToolbox",
                    "~/Library/Application Support/JetBrains/Toolbox/.settings.json"),
            .forbid,
            "Toolbox 设置含 JBA 登录态")
        XCTAssertEqual(
            verdict(of: "JetBrainsToolbox",
                    "~/Library/Application Support/JetBrains/Toolbox/apps"),
            .confirm,
            "已安装 IDE 真实文件，需 confirm 区分 current 与历史")
        XCTAssertEqual(verdict(of: "JetBrainsToolbox",
                               "~/Library/Caches/JetBrains/Toolbox"), .safe)

        XCTAssertEqual(verdict(of: "DarwinUserTemp", "/var/folders"), .confirm,
                       "扫描层须按 UID 过滤，此处 vendor 仅作 path 注册")
    }

    // MARK: - 契约 3：所有新 vendor 的所有 path 都带 reason

    func test_批量vendor_所有path_reason非空() throws {
        let rules = try Self.loadRealRules()
        let target: Set<String> = [
            "NuGet", "Bazel", "Zig", "Corepack", "PerlCPAN", "CondaNative",
            "MailDownloads", "FinalCutProRender",
            "JetBrainsToolbox", "DarwinUserTemp",
        ]
        for v in rules where target.contains(v.name) {
            for p in v.paths {
                XCTAssertNotNil(p.reason, "[\(v.name)] \(p.path) 缺少 reason")
                XCTAssertFalse(p.reason?.isEmpty ?? true,
                               "[\(v.name)] \(p.path) reason 不能空")
            }
        }
    }

    // MARK: - 契约 4：端到端 evaluate 命中（VendorTrie + SafetyEngine）

    func test_批量vendor_端到端evaluate命中真实路径() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // 抽 6 条覆盖三大根（~/.cache、~/Library/Caches、~/Library/Application Support）
        let cases: [(String, SafetyVerdict, String)] = [
            ("/Users/foo/.cache/bazel", .safe, "Bazel"),
            ("/Users/foo/.cache/zig", .safe, "Zig"),
            ("/Users/foo/Library/Caches/NuGet", .safe, "NuGet"),
            ("/Users/foo/Library/Caches/JetBrains/Toolbox", .safe, "JetBrainsToolbox"),
            ("/Users/foo/.condarc", .forbid, "CondaNative"),
            ("/Users/foo/Library/Mail Downloads", .confirm, "MailDownloads"),
        ]
        for (path, expectedVerdict, expectedVendor) in cases {
            let (v, _, vendor) = engine.evaluate(path: path, trie: trie, home: home)
            XCTAssertEqual(v, expectedVerdict,
                           "evaluate(\(path)) 期望 \(expectedVerdict)，实际 \(v)")
            XCTAssertEqual(vendor?.name, expectedVendor,
                           "evaluate(\(path)) 应匹配 vendor \(expectedVendor)")
        }
    }

    // MARK: - 契约 5：硬安全网兜底——任何 vendor 都不能让凭证目录变 safe

    func test_批量vendor_硬安全网仍可拦截敏感凭证() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // 即使 Bazel/Zig vendor 没显式声明 ~/.ssh，硬安全网必须确保它仍 forbid
        let (v1, _, _) = engine.evaluate(path: "/Users/foo/.ssh", trie: trie, home: home)
        XCTAssertEqual(v1, .forbid, "硬安全网必须始终拦截 ~/.ssh")

        // CondaNative 显式 forbid 的 .condarc 在多重防御下仍 forbid
        let (v2, _, _) = engine.evaluate(path: "/Users/foo/.condarc", trie: trie, home: home)
        XCTAssertEqual(v2, .forbid)
    }

    // MARK: - 契约 6：每个 vendor 的 path **总数**精确钉死（防 silent drift）
    //
    // 任何人在 yaml 里加/减 path 都会立刻触发 RED——强迫先更新测试预期才能合入。
    // 这是 "test-layer pin" 范式的核心：让 yaml 的事实数据无法被偷偷改动。

    func test_批量vendor_每个vendor的paths总数精确钉死() throws {
        let rules = try Self.loadRealRules()
        let expected: [(String, Int)] = [
            // —— 包管理器组（合计 20 path）——
            ("NuGet", 4),       // .nuget/packages + 2 NuGet/v3-cache & plugins-cache + Caches/NuGet
            ("Bazel", 2),       // .cache/bazel + .cache/bazelisk
            ("Zig", 2),         // .cache/zig + .cache/zls
            ("Corepack", 2),    // Library/Caches/node/corepack + .cache/node/corepack
            ("PerlCPAN", 4),    // .cpan/build + .cpan/sources + .cpanm/work + .cpanm/latest-build
            ("CondaNative", 6), // 5 pkgs cache safe + .condarc forbid
            // —— 系统残留组（合计 10 path）——
            ("MailDownloads", 2),       // sandboxed Containers + 旧版 ~/Library/Mail Downloads
            ("FinalCutProRender", 3),   // Backups + AppSupport/Caches + Library/Caches/com.apple.FinalCut
            ("JetBrainsToolbox", 4),    // .settings.json forbid + apps confirm + Caches/Toolbox + Logs/Toolbox
            ("DarwinUserTemp", 1),      // /var/folders confirm
        ]
        for (name, count) in expected {
            guard let v = rules.first(where: { $0.name == name }) else {
                XCTFail("vendor '\(name)' 缺失"); continue
            }
            XCTAssertEqual(v.paths.count, count,
                           "[\(name)] paths.count 应为 \(count)，实际 \(v.paths.count)")
        }

        // 还要钉死"10 个 vendor 加起来 30 path"，挡住"加一条减一条互相抵消"
        let totalPaths = expected.reduce(0) { acc, pair in
            acc + (rules.first(where: { $0.name == pair.0 })?.paths.count ?? 0)
        }
        XCTAssertEqual(totalPaths, 30,
                       "10 个新 vendor 共 30 条 path（包管理器 20 + 系统残留 10）")
    }

    // MARK: - 契约 7：所有 path 都有可执行的 recipe 或显式 nil（不允许空字符串"")

    func test_批量vendor_recipe字段不为空字符串() throws {
        let rules = try Self.loadRealRules()
        let target: Set<String> = [
            "NuGet", "Bazel", "Zig", "Corepack", "PerlCPAN", "CondaNative",
            "MailDownloads", "FinalCutProRender",
            "JetBrainsToolbox", "DarwinUserTemp",
        ]
        for v in rules where target.contains(v.name) {
            for p in v.paths {
                if let r = p.recipe {
                    XCTAssertFalse(r.isEmpty,
                                   "[\(v.name)] \(p.path) recipe 字段不能是空字符串，应为 nil 或非空内容")
                }
            }
        }
    }

    // MARK: - helpers

    private static func vendorsYamlURL() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()  // SafetyKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SafetyKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // <repo root>
            .appendingPathComponent("Resources/Rules/vendors.yaml")
    }

    private static func loadRealRules(home: String = "/Users/foo") throws -> [VendorRule] {
        let url = vendorsYamlURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("vendors.yaml 不存在于预期位置 \(url.path)")
        }
        return try RuleLoader.loadVendors(from: url, home: home)
    }
}
