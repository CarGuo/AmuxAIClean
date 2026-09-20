import Foundation
import XCTest
@testable import SafetyKit

/// v2026.09.06 SR-02: exercise the entire existing credential rule family, not a .config exception.
final class CredentialAncestorProtectionTests: XCTestCase {
    func testEveryCredentialAndItsHomeAncestorsAreProtected() {
        let home = "/Users/CredentialAncestorFixture"
        let engine = SafetyEngine()
        for protected in SafetyEngine.sensitiveCredentialPrefixes(home: home) {
            var path = protected
            while path.hasPrefix(home + "/") {
                XCTAssertEqual(engine.evaluate(path: path, home: home).0, .forbid, path)
                path = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
        }
    }

    func testProtectionPreservesSiblingAndComponentBoundaries() {
        let home = "/Users/CredentialAncestorFixture"
        let engine = SafetyEngine()
        for relative in [".config/gh-backup", ".config/cache", ".gradle/caches",
                         ".cargo/registry", ".android/cache", "Library/org.swift.swiftpm/cache"] {
            XCTAssertNotEqual(engine.evaluate(path: home + "/" + relative, home: home).0, .forbid, relative)
        }
        XCTAssertEqual(engine.evaluate(path: home + "/Library/Caches/example", home: home).0, .safe)
    }

    func testIntermediateSymlinkCannotHideCredentialAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialScope-\(UUID())")
            .resolvingSymlinksInPath()
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config")
        try FileManager.default.createDirectory(at: config.appendingPathComponent("gh"), withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: config)
        XCTAssertEqual(SafetyEngine().evaluate(path: alias.path, home: home.path).1, .sensitiveCredential)
    }
}
