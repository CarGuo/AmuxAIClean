import XCTest
@testable import AppUI

/// v1.1：SemVer 解析与比较的单元测试。
/// 关键不变量：
/// - 老版本 < 新版本（major / minor / patch 分别命中）
/// - 前缀 `v` / `V` 都接受
/// - 后缀 `-beta` / `+build` 不影响主比较
/// - 解析失败时不应崩溃，`isOlder` 返回 false（即"无法判断 → 不弹更新"）
final class SemVerTests: XCTestCase {

    func testParseStripsLeadingV() {
        XCTAssertEqual(SemVer.parse("v1.2.3").map { "\($0.0).\($0.1).\($0.2)" }, "1.2.3")
        XCTAssertEqual(SemVer.parse("V1.2.3").map { "\($0.0).\($0.1).\($0.2)" }, "1.2.3")
        XCTAssertEqual(SemVer.parse("1.2.3").map { "\($0.0).\($0.1).\($0.2)" }, "1.2.3")
    }

    func testParseStripsBuildAndPrerelease() {
        XCTAssertEqual(SemVer.parse("1.2.3-beta")?.0, 1)
        XCTAssertEqual(SemVer.parse("1.2.3-beta")?.2, 3)
        XCTAssertEqual(SemVer.parse("1.2.3+build.5")?.2, 3)
    }

    func testParseShortVersion() {
        XCTAssertEqual(SemVer.parse("1.2")?.1, 2)
        XCTAssertEqual(SemVer.parse("1.2")?.2, 0)
        XCTAssertEqual(SemVer.parse("3")?.0, 3)
        XCTAssertEqual(SemVer.parse("3")?.1, 0)
    }

    func testParseFails() {
        XCTAssertNil(SemVer.parse("not-a-version"))
        XCTAssertNil(SemVer.parse(""))
    }

    // MARK: - isOlder

    func testIsOlderMajor() {
        XCTAssertTrue(SemVer.isOlder("1.0.0", than: "2.0.0"))
        XCTAssertFalse(SemVer.isOlder("2.0.0", than: "1.0.0"))
    }

    func testIsOlderMinor() {
        XCTAssertTrue(SemVer.isOlder("1.0.0", than: "1.1.0"))
        XCTAssertFalse(SemVer.isOlder("1.1.0", than: "1.0.5"))
    }

    func testIsOlderPatch() {
        XCTAssertTrue(SemVer.isOlder("1.0.0", than: "1.0.1"))
        XCTAssertFalse(SemVer.isOlder("1.0.1", than: "1.0.0"))
    }

    func testEqualVersionsAreNotOlder() {
        XCTAssertFalse(SemVer.isOlder("1.2.3", than: "1.2.3"))
        XCTAssertFalse(SemVer.isOlder("v1.2.3", than: "1.2.3"))
    }

    func testInvalidVersionsDoNotPromptUpdate() {
        // 解析失败时 isOlder 返回 false，UI 就不会弹"有更新"——保守策略
        XCTAssertFalse(SemVer.isOlder("garbage", than: "1.0.0"))
        XCTAssertFalse(SemVer.isOlder("1.0.0", than: "garbage"))
    }

    func testRealWorldUpgrade() {
        // 实际场景：本地是 v1.0.0，GitHub Releases 拉到 v1.1.0
        XCTAssertTrue(SemVer.isOlder("1.0.0", than: "v1.1.0"))
        XCTAssertTrue(SemVer.isOlder("v1.1.0", than: "v1.1.1"))
    }
}
