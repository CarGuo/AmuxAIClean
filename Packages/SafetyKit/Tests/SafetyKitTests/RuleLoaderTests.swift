import XCTest
@testable import SafetyKit

final class RuleLoaderTests: XCTestCase {

    func testParseMinimalEntry() throws {
        let yaml = """
        # comment
        vendors:
          - name: "Adobe"
            bundle_id_prefix: "com.adobe"
            app_support_subdir: "Adobe"
            note: "shared"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "Adobe")
        XCTAssertEqual(rules[0].bundleIDPrefix, "com.adobe")
        XCTAssertEqual(rules[0].appSupportSubdir, "Adobe")
        XCTAssertEqual(rules[0].note, "shared")
    }

    func testParseMultipleEntries() throws {
        let yaml = """
        vendors:
          - name: "Slack"
            app_support_subdir: "Slack"
          - name: "Homebrew"
            caches_path: "~/Library/Caches/Homebrew"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].name, "Slack")
        XCTAssertEqual(rules[1].cachesPath, "~/Library/Caches/Homebrew")
    }

    func testIgnoresUnknownKeysForwardCompat() throws {
        let yaml = """
        vendors:
          - name: "X"
            app_support_subdir: "X"
            unknown_future_key: "whatever"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "X")
    }

    func testHardForbidRejectsMaliciousRule() throws {
        let yaml = """
        vendors:
          - name: "Malicious"
            app_support_subdir: "../../../../System/Library"
        """
        let dir = NSTemporaryDirectory() + "RuleLoaderTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/v.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        let rules = try RuleLoader.loadVendors(from: url, home: "/Users/foo")
        XCTAssertTrue(rules.isEmpty, "命中 hardForbid 的恶意规则必须被过滤掉")
    }

    func testVendorRulePrefixesExpandHome() {
        let r = VendorRule(name: "X", appSupportSubdir: "Adobe",
                           cachesPath: "~/Library/Caches/Homebrew")
        let prefixes = r.absolutePathPrefixes(home: "/Users/foo")
        XCTAssertTrue(prefixes.contains("/Users/foo/Library/Application Support/Adobe"))
        XCTAssertTrue(prefixes.contains("/Users/foo/Library/Caches/Homebrew"))
    }

    func testEvaluateWithVendorDowngradesSafeRoot() {
        let engine = SafetyEngine()
        let rule = VendorRule(name: "Adobe", appSupportSubdir: "Adobe")
        // 这里造一个 ~/Library/Caches/Adobe 的"根"，本来是 safe
        let path = "/Users/foo/Library/Application Support/Adobe"
        let (verdict, _, hit) = engine.evaluate(path: path, vendors: [rule], home: "/Users/foo")
        XCTAssertEqual(verdict, .confirm, "vendor 根目录必须降级到 confirm")
        XCTAssertEqual(hit?.name, "Adobe")
    }

    func testEvaluateVendorSubpathKeepsSafe() {
        let engine = SafetyEngine()
        let rule = VendorRule(name: "Some", cachesPath: "~/Library/Caches/Homebrew")
        // /Users/foo/Library/Caches/Homebrew/abc 既被 safeCachePrefixes 命中（safe），
        // 也是 vendor 子路径（保留 safe）
        let path = "/Users/foo/Library/Caches/Homebrew/downloads/abc"
        let (verdict, _, _) = engine.evaluate(path: path, vendors: [rule], home: "/Users/foo")
        XCTAssertEqual(verdict, .safe, "vendor 子路径保持 safe，方便用户清掉 brew 缓存内容")
    }
}
