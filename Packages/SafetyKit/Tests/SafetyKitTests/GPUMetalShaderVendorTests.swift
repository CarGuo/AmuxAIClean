import XCTest
@testable import SafetyKit

/// Step 17-E：GPU/Metal shader 缓存 vendor 端到端契约。
///
/// 背景（[docs/AUDIT_2026_06.md L123](file:///Users/amuxuser/workspace/AmuxAIClean/docs/AUDIT_2026_06.md#L123)）：
/// `com.apple.{gpuarchiver,metal,metalfe}` 是 GPU 命令归档 / Metal shader / Metal Frontend
/// Compiler 三套缓存，按需重建，安全可清；macOS 重启或 GPU 程序首次启动会自动重建。
/// vendors.yaml 此前完全未覆盖。
///
/// 测试策略与 [InstallerLeftoversVendorTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Tests/SafetyKitTests/InstallerLeftoversVendorTests.swift)
/// 完全一致：直接装载仓库根 `Resources/Rules/vendors.yaml` → 抽样 verdict + 关键不变量
/// + VendorTrie + SafetyEngine.evaluate 端到端。全部断言"现状钉死"。
final class GPUMetalShaderVendorTests: XCTestCase {

    // MARK: - 契约 1：vendor 落地（4 条 path-rule，全部带 reason）

    func test_GPUMetalShader_vendor_存在且含4条path() throws {
        let rules = try Self.loadRealRules()
        guard let v = rules.first(where: { $0.name == "GPU/Metal Shader Cache" }) else {
            return XCTFail("vendors.yaml 应含 'GPU/Metal Shader Cache' vendor")
        }
        XCTAssertEqual(v.paths.count, 4,
                       "Step 17-E 表：3 user-cache（gpuarchiver/metal/metalfe）+ 1 system-cache 多重防御 = 4 条")
        for p in v.paths {
            XCTAssertNotNil(p.reason, "\(p.path) 缺少 reason 字段")
            XCTAssertFalse(p.reason?.isEmpty ?? true,
                           "\(p.path) 的 reason 不能为空字符串")
        }
    }

    // MARK: - 契约 2：每条 verdict 钉死

    func test_GPUMetalShader_每条path_verdict精确匹配() throws {
        let rules = try Self.loadRealRules()
        guard let v = rules.first(where: { $0.name == "GPU/Metal Shader Cache" }) else {
            return XCTFail("vendor 缺失")
        }
        let byPath = Dictionary(uniqueKeysWithValues: v.paths.map { ($0.path, $0.verdict) })

        XCTAssertEqual(byPath["~/Library/Caches/com.apple.metal"], .safe,
                       "用户级 Metal shader 缓存，按需重建")
        XCTAssertEqual(byPath["~/Library/Caches/com.apple.metalfe"], .safe,
                       "Metal Frontend Compiler 缓存，按需重建")
        XCTAssertEqual(byPath["~/Library/Caches/com.apple.gpuarchiver"], .safe,
                       "GPU 命令归档缓存，按需重建")
        XCTAssertEqual(byPath["/Library/Caches/com.apple.metal"], .confirm,
                       "系统级 Metal 缓存，删除安全但全用户首次启动 GPU 程序需重新编译")
    }

    // MARK: - 契约 3：用户级 metal 路径通过端到端 evaluate 命中

    func test_GPUMetalShader_evaluate_用户级metal路径直接命中() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        let path = "/Users/foo/Library/Caches/com.apple.metal"
        let (verdict, _, vendor) = engine.evaluate(path: path, trie: trie, home: home)
        XCTAssertEqual(verdict, .safe,
                       "~/Library/Caches/com.apple.metal 应命中 vendor 且 verdict=safe")
        XCTAssertEqual(vendor?.name, "GPU/Metal Shader Cache")
    }

    // MARK: - 契约 4：系统级 confirm 不被 hardForbid 误吞

    func test_GPUMetalShader_系统级metal路径_命中vendor且verdict为confirm() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // /Library/Caches 不在 SafetyEngine.hardForbidPrefixes（仅 /System、/Library/Frameworks 等
        // 系统关键目录被硬禁），所以 /Library/Caches/com.apple.metal 应原样维持 vendor 给出的 confirm。
        let (verdict, _, vendor) = engine.evaluate(
            path: "/Library/Caches/com.apple.metal", trie: trie, home: home)
        XCTAssertEqual(verdict, .confirm,
                       "系统级 Metal cache：vendor 已声明 confirm，硬禁区不应误吞")
        XCTAssertEqual(vendor?.name, "GPU/Metal Shader Cache")
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
