import XCTest
@testable import AppUI

/// AppSettings 持久化层单测。每个用例用独立 UserDefaults suite 避免污染主域。
final class AppSettingsTests: XCTestCase {

    private func freshSuite(_ name: String = #function) -> String {
        let s = "GSYCleanMac.tests.AppSettings.\(name).\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: s)
        return s
    }

    @MainActor
    func test_默认值_首次启动时应符合v1拍板默认() throws {
        let s = AppSettings(testSuite: freshSuite())
        XCTAssertTrue(s.showHidden, "隐藏文件 toggle 默认必须 ON（v1.3 修订；为对齐 Finder/du 体积统计）")
        XCTAssertEqual(s.minFileSizeMB, 100, "大文件默认阈值 100MB")
        XCTAssertEqual(s.sortKey, .sizeDesc, "默认按大小降序")
        XCTAssertTrue(s.updateCheckEnabled, "v1.1：启动检查更新默认 ON")
        XCTAssertNil(s.skippedUpdateTag, "默认无跳过版本")
        XCTAssertEqual(s.mtimeFilter, .all, "v1.2：mtime 过滤默认 .all（先看到全貌）")
    }

    @MainActor
    func test_v11更新偏好_持久化() throws {
        let suite = freshSuite()
        do {
            let s = AppSettings(testSuite: suite)
            s.updateCheckEnabled = false
            s.skippedUpdateTag = "v1.2.3"
        }
        let s2 = AppSettings(testSuite: suite)
        XCTAssertFalse(s2.updateCheckEnabled)
        XCTAssertEqual(s2.skippedUpdateTag, "v1.2.3")
    }

    @MainActor
    func test_v11_skipped设置nil应清除() throws {
        let suite = freshSuite()
        do {
            let s = AppSettings(testSuite: suite)
            s.skippedUpdateTag = "v1.2.3"
            s.skippedUpdateTag = nil
        }
        let s2 = AppSettings(testSuite: suite)
        XCTAssertNil(s2.skippedUpdateTag)
    }

    @MainActor
    func test_写入后持久化_重新构造能读到() throws {
        let suite = freshSuite()
        do {
            let s = AppSettings(testSuite: suite)
            s.showHidden = true
            s.minFileSizeMB = 500
            s.sortKey = .mtimeDesc
        }
        let s2 = AppSettings(testSuite: suite)
        XCTAssertTrue(s2.showHidden)
        XCTAssertEqual(s2.minFileSizeMB, 500)
        XCTAssertEqual(s2.sortKey, .mtimeDesc)
    }

    @MainActor
    func test_脏数据_负数阈值或非法sortKey应回退默认() throws {
        let suite = freshSuite()
        let d = UserDefaults(suiteName: suite)!
        d.set(-10, forKey: AppSettings.Keys.minFileSizeMB)
        d.set("not_a_real_key", forKey: AppSettings.Keys.sortKey)
        let s = AppSettings(testSuite: suite)
        XCTAssertEqual(s.minFileSizeMB, 100, "非法负数阈值应回退 100")
        XCTAssertEqual(s.sortKey, .sizeDesc, "非法 sortKey 应回退 sizeDesc")
    }

    @MainActor
    func test_testReset_应把所有键清空() throws {
        let suite = freshSuite()
        let s = AppSettings(testSuite: suite)
        s.showHidden = false
        s.minFileSizeMB = 999
        s.sortKey = .nameAsc
        s._testReset()
        // fresh 一份验证（应回到 v1.3 默认值：showHidden ON）
        let s2 = AppSettings(testSuite: suite)
        XCTAssertTrue(s2.showHidden)
        XCTAssertEqual(s2.minFileSizeMB, 100)
        XCTAssertEqual(s2.sortKey, .sizeDesc)
    }
}
