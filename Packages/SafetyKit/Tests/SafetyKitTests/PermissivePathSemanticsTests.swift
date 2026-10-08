import XCTest
@testable import SafetyKit

final class PermissivePathSemanticsTests: XCTestCase {
    func testCachePromotionRespectsFilesystemCapability() {
        let home = "/Users/tester"
        for capability: Bool? in [true, false, nil] {
            let engine = SafetyEngine(pathCaseSensitivity: { _ in capability })
            XCTAssertEqual(engine.evaluate(path: home + "/Library/Caches/acme/item", home: home).0, .safe)
            XCTAssertEqual(engine.evaluate(path: home + "/library/caches/acme/item", home: home).0,
                           capability == false ? .safe : .confirm)
            XCTAssertEqual(engine.evaluate(path: home + "/Library/Caches", home: home).0, .confirm)
            XCTAssertEqual(engine.evaluate(path: home + "/.SSH/key", home: home).0, .forbid)
        }
    }

    func testLiteralAndGlobPositiveRulesShareFilesystemSemantics() {
        let semantics = FileSystemPathSemantics(isCaseSensitive: { _ in true })
        let literal = VendorRule(name: "literal", paths: [PathRule(path: "~/Work/Build", verdict: .safe)])
        let glob = VendorRule(name: "glob", paths: [PathRule(path: "~/Work/Tool*/cache", verdict: .safe)])
        let trie = VendorTrie.build(vendors: [literal, glob], home: "/Users/tester")
        for (path, expected): (String, SafetyVerdict) in [
            ("/Users/tester/Work/Build/item", .safe),
            ("/Users/tester/work/build/item", .confirm),
            ("/Users/tester/Work/ToolA/cache/item", .safe),
            ("/Users/tester/work/toola/cache/item", .confirm)
        ] {
            let engine = SafetyEngine(pathCaseSensitivity: semantics.isCaseSensitive)
            XCTAssertEqual(engine.evaluate(path: path, trie: trie, home: "/Users/tester").0, expected)
        }
    }

    func testSameNormalizedTrieNodeSupportsCaseVariantsAndFirstMatchFallback() {
        let home = "/Users/tester"
        let caseVariantRule = VendorRule(
            name: "case-variants",
            paths: [
                PathRule(path: "~/Work/Build", verdict: .safe),
                PathRule(path: "~/Work/build", verdict: .safe),
            ]
        )
        let caseVariantTrie = VendorTrie.build(vendors: [caseVariantRule], home: home)
        let csEngine = SafetyEngine(pathCaseSensitivity: { _ in true })
        XCTAssertEqual(csEngine.evaluate(path: home + "/Work/Build/item", trie: caseVariantTrie, home: home).0, .safe)
        XCTAssertEqual(csEngine.evaluate(path: home + "/Work/build/item", trie: caseVariantTrie, home: home).0, .safe)
        XCTAssertEqual(csEngine.evaluate(path: home + "/Work/BUILD/item", trie: caseVariantTrie, home: home).0, .confirm)

        let upperSafeVendor = VendorRule(
            name: "upper-safe",
            paths: [PathRule(path: "~/Work/SharedCache", verdict: .safe)]
        )
        let lowerForbidVendor = VendorRule(
            name: "lower-forbid",
            paths: [PathRule(path: "~/Work/sharedcache", verdict: .forbid, reason: "Protected lowercase cache")]
        )
        let mixedTrie = VendorTrie.build(vendors: [upperSafeVendor, lowerForbidVendor], home: home)
        XCTAssertEqual(csEngine.evaluate(path: home + "/Work/SharedCache/item", trie: mixedTrie, home: home).0, .safe)
        let forbidEval = csEngine.evaluate(path: home + "/Work/sharedcache/item", trie: mixedTrie, home: home)
        XCTAssertEqual(forbidEval.0, .forbid)
        XCTAssertEqual(forbidEval.2?.name, "lower-forbid")
    }
}
