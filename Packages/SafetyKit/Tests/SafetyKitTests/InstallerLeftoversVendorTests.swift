import XCTest
@testable import SafetyKit

/// Step 17-C：macOS 安装器残留 vendor 端到端契约。
///
/// 背景（docs/AUDIT_2026_06.md L491 "P3-2"）：
/// macOS 用户级 installer cache（`~/Library/Caches/com.apple.installer*`、
/// `~/Library/Caches/INSTALLATION`）实测会累积数十 MB 但 vendors.yaml 此前完全未覆盖；
/// 系统级 `/private/var/db/receipts` 已在 SafetyEngine.hardForbidPrefixes 硬禁区，
/// 但 vendors.yaml 加一条多重防御 forbid 让 UI 能展示 reason 并形成"早失败"双层保险。
///
/// 测试策略与 RuleLoaderTests.testRealVendorsYamlLoadsApplePathRules 一致：
/// 直接装载仓库根 `Resources/Rules/vendors.yaml` → 抽样 verdict + 关键不变量 +
/// VendorTrie + SafetyEngine.evaluate 端到端。
///
/// 全部断言"现状钉死"——vendor 作者改 yaml 必须先改测试，禁止 silent drift。
final class InstallerLeftoversVendorTests: XCTestCase {

    // MARK: - 契约 1：vendor 落地（4 条 path-rule，全部带 reason）

    func test_macOSInstallerLeftovers_vendor_存在且含4条path() throws {
        let rules = try Self.loadRealRules()
        guard let v = rules.first(where: { $0.name == "macOS Installer Leftovers" }) else {
            return XCTFail("vendors.yaml 应含 'macOS Installer Leftovers' vendor")
        }
        XCTAssertEqual(v.paths.count, 4,
                       "Step 17-C 表：3 user-cache/log + 1 system-receipts 多重防御 = 4 条")
        for p in v.paths {
            XCTAssertNotNil(p.reason, "\(p.path) 缺少 reason 字段")
            XCTAssertFalse(p.reason?.isEmpty ?? true,
                           "\(p.path) 的 reason 不能为空字符串")
        }
    }

    // MARK: - 契约 2：每条 verdict 钉死

    func test_macOSInstallerLeftovers_每条path_verdict精确匹配() throws {
        let rules = try Self.loadRealRules()
        guard let v = rules.first(where: { $0.name == "macOS Installer Leftovers" }) else {
            return XCTFail("vendor 缺失")
        }
        let byPath = Dictionary(uniqueKeysWithValues: v.paths.map { ($0.path, $0.verdict) })

        XCTAssertEqual(byPath["~/Library/Caches/com.apple.installer*"], .safe,
                       "macOS 安装器 cache（如 osinstallersetupd），下次安装时重建")
        XCTAssertEqual(byPath["~/Library/Caches/INSTALLATION"], .safe,
                       "通用安装器中间产物")
        XCTAssertEqual(byPath["~/Library/Logs/Install.log"], .confirm,
                       "macOS 升级日志，删了无法复盘最近一次安装失败")
        XCTAssertEqual(byPath["/private/var/db/receipts"], .forbid,
                       "多重防御：系统级 .bom/.plist，删后 pkg --forget 失败")
    }

    // MARK: - 契约 3：glob 通配通过端到端 evaluate 命中真实子路径

    func test_macOSInstallerLeftovers_glob_命中真实子路径osinstallersetupd() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // 真机实测路径：~/Library/Caches/com.apple.installer.osinstallersetupd
        let path = "/Users/foo/Library/Caches/com.apple.installer.osinstallersetupd"
        let (verdict, _, vendor) = engine.evaluate(path: path, trie: trie, home: home)
        XCTAssertEqual(verdict, .safe,
                       "com.apple.installer* glob 应命中并降到 safe")
        XCTAssertEqual(vendor?.name, "macOS Installer Leftovers")
    }

    // MARK: - 契约 4：硬安全网兜底（vendor 即使写 safe 也不能穿透 hardForbid）

    func test_macOSInstallerLeftovers_系统receipts路径_永远forbid() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // /private/var/db/receipts 既在 vendor.paths（verdict=forbid 多重防御），
        // 也在 SafetyEngine.hardForbidPrefixes（/private/var/db, /var/db）。
        // 任何一层都应让最终 verdict = .forbid，且 vendor 不会被 RuleLoader 整条丢弃
        // （因为该 path 自己声明 verdict=forbid，与 RuleLoader.swift L97-L102 注释一致）。
        let (v1, _, _) = engine.evaluate(
            path: "/private/var/db/receipts", trie: trie, home: home)
        XCTAssertEqual(v1, .forbid)
        let (v2, _, _) = engine.evaluate(
            path: "/var/db/receipts", trie: trie, home: home)
        XCTAssertEqual(v2, .forbid, "标准化前缀（不含 /private）也必须 forbid")

        // 关键：vendor 仍然存在（多重防御 verdict=forbid 没让整条被丢弃）
        XCTAssertNotNil(rules.first(where: { $0.name == "macOS Installer Leftovers" }),
                        "verdict=forbid 的多重防御 path 不应让整条 vendor 被剔除")
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
