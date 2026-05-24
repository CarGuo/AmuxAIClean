import XCTest
@testable import SafetyKit

final class PathGlobTests: XCTestCase {

    // MARK: - isGlob 识别

    func test_isGlob_无元字符返回false() {
        XCTAssertFalse(PathGlob.isGlob("~/Library/Caches/JetBrains"))
        XCTAssertFalse(PathGlob.isGlob(""))
        XCTAssertFalse(PathGlob.isGlob("/"))
    }

    func test_isGlob_含星号或问号返回true() {
        XCTAssertTrue(PathGlob.isGlob("~/Library/Caches/JetBrains/*"))
        XCTAssertTrue(PathGlob.isGlob("a?b"))
        XCTAssertTrue(PathGlob.isGlob("*"))
    }

    // MARK: - 严格 match：完整匹配

    func test_match_字面量相等() {
        XCTAssertTrue(PathGlob.match(pattern: "/foo/bar", path: "/foo/bar"))
    }

    func test_match_字面量不等() {
        XCTAssertFalse(PathGlob.match(pattern: "/foo/bar", path: "/foo/baz"))
    }

    func test_match_星号同段内() {
        XCTAssertTrue(PathGlob.match(
            pattern: "~/Library/Caches/JetBrains/IntelliJIdea*",
            path: "~/Library/Caches/JetBrains/IntelliJIdea2024.3"))
    }

    func test_match_星号不跨斜杠() {
        // pattern `~/.cache/JetBrains/*` 不应匹配两段 path
        XCTAssertFalse(PathGlob.match(
            pattern: "~/Library/Caches/JetBrains/*",
            path: "~/Library/Caches/JetBrains/IntelliJIdea2024.3/log.txt"))
    }

    func test_match_星号匹配空串() {
        XCTAssertTrue(PathGlob.match(pattern: "abc*", path: "abc"))
        XCTAssertTrue(PathGlob.match(pattern: "*abc", path: "abc"))
    }

    func test_match_问号单字符() {
        XCTAssertTrue(PathGlob.match(pattern: "f?o", path: "foo"))
        XCTAssertFalse(PathGlob.match(pattern: "f?o", path: "fo"))
        XCTAssertFalse(PathGlob.match(pattern: "f?o", path: "fooo"))
    }

    func test_match_问号不跨斜杠() {
        XCTAssertFalse(PathGlob.match(pattern: "a?b", path: "a/b"))
    }

    func test_match_jetbrains版本号典型场景() {
        // §2.2 表中 `<product><version>` 的真实命名
        let pat = "~/Library/Caches/JetBrains/*"
        XCTAssertTrue(PathGlob.match(pattern: pat,
                                     path: "~/Library/Caches/JetBrains/IntelliJIdea2024.3"))
        XCTAssertTrue(PathGlob.match(pattern: pat,
                                     path: "~/Library/Caches/JetBrains/PyCharm2025.1"))
        XCTAssertFalse(PathGlob.match(pattern: pat,
                                      path: "~/Library/Caches/JetBrains"))
    }

    // MARK: - matchPrefix：截前 N 段后再 fnmatch

    func test_matchPrefix_子目录命中() {
        XCTAssertTrue(PathGlob.matchPrefix(
            pattern: "~/Library/Caches/JetBrains/*",
            path: "~/Library/Caches/JetBrains/IntelliJIdea2024.3/cache.lock"))
    }

    func test_matchPrefix_精确根命中() {
        XCTAssertTrue(PathGlob.matchPrefix(
            pattern: "~/Library/Caches/JetBrains/*",
            path: "~/Library/Caches/JetBrains/IntelliJIdea2024.3"))
    }

    func test_matchPrefix_段数不足时不匹配() {
        XCTAssertFalse(PathGlob.matchPrefix(
            pattern: "~/Library/Caches/JetBrains/*",
            path: "~/Library/Caches/JetBrains"))
    }

    func test_matchPrefix_不同分支不匹配() {
        XCTAssertFalse(PathGlob.matchPrefix(
            pattern: "~/Library/Caches/JetBrains/*",
            path: "~/Library/Caches/SomethingElse/IntelliJIdea2024.3"))
    }

    // MARK: - takeSegments

    func test_takeSegments_典型场景() {
        XCTAssertEqual(PathGlob.takeSegments("a/b/c/d", count: 2), "a/b")
        XCTAssertEqual(PathGlob.takeSegments("/a/b/c", count: 2), "/a/b")
        XCTAssertEqual(PathGlob.takeSegments("a/b", count: 5), "a/b") // 段数不足返回全部
    }

    // MARK: - 安全约束：glob 不能绕过硬安全网（这是 R3 阶段在 SafetyEngine 中钉死，
    // 这里只验证 PathGlob 自己不会绕过 sanity）

    func test_match_不会接受跨段贪婪吞噬() {
        // 这是关键安全测试：恶意作者写 `~/*` 试图吞掉整个 home —— 即便 fnmatch 通过，
        // VendorTrie/SafetyEngine 调用方仍要走 hardForbid，但 PathGlob 自己也要保证
        // `~/*` 不会匹配 `~/.ssh/id_rsa`（因为后者跨了 1 个 `/`）。
        XCTAssertFalse(PathGlob.match(pattern: "~/*", path: "~/.ssh/id_rsa"))
        // 但它会匹配 `~/.ssh`（同段单层）—— 这是预期行为，最终安全依赖
        // VendorTrie 调用方走的硬安全网检查（B 阶段 sensitiveCredential 红线）。
        XCTAssertTrue(PathGlob.match(pattern: "~/*", path: "~/.ssh"))
    }
}
