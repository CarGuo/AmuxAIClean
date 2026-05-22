import XCTest
@testable import SafetyKit

final class SafetyEngineTests: XCTestCase {
    let engine = SafetyEngine()

    // MARK: - 黑名单

    func testSystemPathsAreForbidden() {
        XCTAssertEqual(engine.evaluate(path: "/System/Library/Frameworks/Foo").0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/usr/libexec/cups").0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/private/var/db/uuidtext").0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/Applications/Safari.app").0, .forbid)
    }

    // MARK: - 根目录保护

    func testRootIsForbidden() {
        XCTAssertEqual(engine.evaluate(path: "/").1, .rootOrAboveHome)
    }

    func testHomeRootIsForbidden() {
        XCTAssertEqual(engine.evaluate(path: "/Users/foo", home: "/Users/foo").1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Documents", home: "/Users/foo").1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Desktop", home: "/Users/foo").1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Library", home: "/Users/foo").1, .userDocumentsRoot)
    }

    func testHomeSubpathsAreConfirm() {
        // 子节点是允许"考虑删"的（confirm，不是 safe，也不是 forbid）
        let v = engine.evaluate(path: "/Users/foo/Documents/old.zip", home: "/Users/foo")
        XCTAssertEqual(v.0, .confirm)
    }

    // MARK: - 路径攻击

    func testRelativePathRejected() {
        XCTAssertEqual(engine.evaluate(path: "tmp/foo").1, .relativePath)
    }

    func testDotDotInPathRejected() {
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/../etc/passwd").1, .dotDotInPath)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/..").1, .dotDotInPath)
    }

    func testSystemVolumeRejected() {
        XCTAssertEqual(engine.evaluate(path: "/System/Volumes/Preboot/something").1, .hardForbidPrefix)
        // /System/Volumes/Data/Users/... 是数据卷穿透 → 命中 safeCachePrefixes 升级到 .safe
        let v = engine.evaluate(path: "/System/Volumes/Data/Users/foo/Library/Caches/x", home: "/Users/foo")
        XCTAssertEqual(v.0, .safe)
    }

    // MARK: - 缓存（允许处理）

    func testUserCachesAreSafe() {
        // ~/Library/Caches/* 是已知的清理友好路径，升级到 .safe（UI 默认勾选）
        let v = engine.evaluate(path: "/Users/foo/Library/Caches/com.apple.Safari", home: "/Users/foo")
        XCTAssertEqual(v.0, .safe)
    }

    func testXcodeDerivedDataIsSafe() {
        let v = engine.evaluate(
            path: "/Users/foo/Library/Developer/Xcode/DerivedData/MyApp-abc",
            home: "/Users/foo"
        )
        XCTAssertEqual(v.0, .safe)
    }

    func testHomeDocumentsItemsAreConfirm() {
        // 见 testHomeSubpathsAreConfirm；这里再覆盖一次明确的语义
        let v = engine.evaluate(path: "/Users/foo/Documents/x.pdf", home: "/Users/foo")
        XCTAssertEqual(v.0, .confirm)
    }

    // MARK: - isForbidden 包装

    func testIsForbiddenWrapper() {
        XCTAssertTrue(engine.isForbidden(path: "/System/Library", home: "/Users/foo"))
        XCTAssertFalse(engine.isForbidden(path: "/Users/foo/Library/Caches/x", home: "/Users/foo"))
    }
}
