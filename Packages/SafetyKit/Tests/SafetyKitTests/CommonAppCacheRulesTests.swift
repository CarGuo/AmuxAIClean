import XCTest
@testable import SafetyKit

final class CommonAppCacheRulesTests: XCTestCase {

    func testRealVendorsYamlLoadsCommonAppCacheRules() throws {
        let rules = try Self.loadRealRules()
        let commonRules = rules.filter { $0.category == "common_app_cache" }
        let names = Set(commonRules.map(\.name))

        for expected in [
            "WeChat Cache",
            "Tencent Meeting Cache",
            "Zoom Cache",
            "Notion Cache",
            "Obsidian Cache",
            "Google Drive Cache",
            "Adobe Media Cache",
            "Steam Cache",
            "Teams Cache Safe Subset",
            "Slack Cache",
            "Discord Cache",
            "Codex Cache",
            "Chrome Cache",
            "Postman Cache",
            "Common App Cache Blocks"
        ] {
            XCTAssertTrue(names.contains(expected), "common_app_cache 应包含 \(expected)")
        }

        for expected in [
            "WeChat Data Review",
            "DingTalk Review",
            "Lark / Feishu Review",
            "WPS Office Review",
            "Baidu Netdisk Review",
            "Thunder Review",
            "Telegram Review",
            "Youdao Note Review"
        ] {
            XCTAssertTrue(names.contains(expected), "common_app_cache 应包含展示/确认型规则 \(expected)")
        }

        for rule in commonRules {
            XCTAssertFalse(rule.paths.isEmpty, "\(rule.name) 必须声明 paths")
            for pathRule in rule.paths {
                XCTAssertFalse(pathRule.reason?.isEmpty ?? true,
                               "\(rule.name) \(pathRule.path) 必须有 reason")
            }
        }
    }

    func testCommonAppCacheSafeAndConfirmVerdicts() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        let wechat = engine.evaluate(
            path: "\(home)/Library/Caches/com.tencent.xinWeChat/avatar-cache/a.bin",
            trie: trie,
            home: home
        )
        XCTAssertEqual(wechat.0, .safe)
        XCTAssertEqual(wechat.2?.name, "WeChat Cache")

        let drive = engine.evaluate(
            path: "\(home)/Library/Application Support/Google/DriveFS/account-1/content_cache/chunk",
            trie: trie,
            home: home
        )
        XCTAssertEqual(drive.0, .confirm)
        XCTAssertEqual(drive.2?.name, "Google Drive Cache")

        let adobe = engine.evaluate(
            path: "\(home)/Library/Application Support/Adobe/Common/Media Cache Files/render.cfa",
            trie: trie,
            home: home
        )
        XCTAssertEqual(adobe.0, .confirm)
        XCTAssertEqual(adobe.2?.name, "Adobe Media Cache")

        let slack = engine.evaluate(
            path: "\(home)/Library/Application Support/Slack/Cache/resource",
            trie: trie,
            home: home
        )
        XCTAssertEqual(slack.0, .safe)
        XCTAssertEqual(slack.2?.name, "Slack Cache")

        let chrome = engine.evaluate(
            path: "\(home)/Library/Caches/Google/Chrome/Default/Cache_Data/chunk",
            trie: trie,
            home: home
        )
        XCTAssertEqual(chrome.0, .safe)
        XCTAssertEqual(chrome.2?.name, "Chrome Cache")

        let wechatData = engine.evaluate(
            path: "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_x/file.dat",
            trie: trie,
            home: home
        )
        XCTAssertEqual(wechatData.0, .confirm)
        XCTAssertEqual(wechatData.2?.name, "WeChat Data Review")

        let wpsData = engine.evaluate(
            path: "\(home)/Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/wps/state.db",
            trie: trie,
            home: home
        )
        XCTAssertEqual(wpsData.0, .confirm)
        XCTAssertEqual(wpsData.2?.name, "WPS Office Review")

        let larkCache = engine.evaluate(
            path: "\(home)/Library/Caches/LarkShell/index",
            trie: trie,
            home: home
        )
        XCTAssertEqual(larkCache.0, .safe)
        XCTAssertEqual(larkCache.2?.name, "Lark / Feishu Review")
    }

    func testCommonAppCacheBlockedNeighborsStayForbid() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        let telegram = engine.evaluate(
            path: "\(home)/Library/Group Containers/ABC.ru.keepcoder.Telegram/stable/account-1/postbox/db/messages",
            trie: trie,
            home: home
        )
        XCTAssertEqual(telegram.0, .forbid)
        XCTAssertEqual(telegram.1, .vendorPathRule)
        XCTAssertEqual(telegram.2?.name, "Common App Cache Blocks")

        let arcCookies = engine.evaluate(
            path: "\(home)/Library/Application Support/Arc/User Data/Default/Cookies",
            trie: trie,
            home: home
        )
        XCTAssertEqual(arcCookies.0, .forbid)
        XCTAssertEqual(arcCookies.1, .vendorPathRule)

        let teamsLocalStorage = engine.evaluate(
            path: "\(home)/Library/Application Support/Microsoft/Teams/Local Storage/leveldb",
            trie: trie,
            home: home
        )
        XCTAssertEqual(teamsLocalStorage.0, .forbid)
        XCTAssertEqual(teamsLocalStorage.1, .vendorPathRule)

        let chromeHistory = engine.evaluate(
            path: "\(home)/Library/Application Support/Google/Chrome/Default/History",
            trie: trie,
            home: home
        )
        XCTAssertEqual(chromeHistory.0, .forbid)
        XCTAssertEqual(chromeHistory.1, .vendorPathRule)
    }

    private static func vendorsYamlURL() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
