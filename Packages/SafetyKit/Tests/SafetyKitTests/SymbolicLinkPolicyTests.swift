import Foundation
import XCTest
@testable import SafetyKit

/// v2026.10.09: policy must inspect the entire link chain, including missing targets.
/// All filesystem evidence belongs to a temporary fake HOME, never the user's data.
final class SymbolicLinkPolicyTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymbolicLinkPolicy-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/com.example.fixture"),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    func testDanglingChainAndDescendantsKeepForbiddenTargetInBothEvaluators() throws {
        let home = try makeHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let a = cache.appendingPathComponent("a")
        let b = cache.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(
            atPath: b.path, withDestinationPath: "/System/Library/Missing-\(UUID().uuidString)"
        )
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)
        for path in [a.path, a.path + "/child", b.path] {
            let plain = engine.evaluate(path: path, home: home.path)
            let vendor = engine.evaluate(path: path, trie: trie, home: home.path)
            XCTAssertEqual(plain.0, .forbid, path)
            XCTAssertEqual(plain.1, .hardForbidPrefix, path)
            XCTAssertEqual(vendor.0, plain.0, path)
            XCTAssertEqual(vendor.1, plain.1, path)
        }
    }

    func testCyclesTerminateWithTypedSafetyFailureAndWhitelistActorRemainsUsable() async throws {
        let home = try makeHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        // The missing/.. chain forces the component resolver, while the direct cycles
        // exercise libc's ELOOP result. Both boundaries must terminate.
        for (name, target) in [("self", "self"), ("a", "b"), ("b", "a"),
                               ("missingA", "missing/../missingB"), ("missingB", "missingA")] {
            try FileManager.default.createSymbolicLink(
                atPath: cache.appendingPathComponent(name).path, withDestinationPath: target
            )
        }
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: home.appendingPathComponent("other").path)
        for name in ["self", "a", "missingA"] {
            let path = cache.appendingPathComponent(name).path
            let plain = engine.evaluate(path: path, home: home.path)
            let vendor = engine.evaluate(path: path, trie: trie, home: home.path)
            XCTAssertEqual(plain.0, .forbid)
            XCTAssertEqual(plain.1, .symbolicLinkResolutionFailed)
            XCTAssertEqual(vendor.0, plain.0)
            XCTAssertEqual(vendor.1, plain.1)
            XCTAssertEqual(engine.bundleProtectionEvidence(path: path, home: home.path), .unresolved)
            let finished = expectation(description: "cyclic alias lookup terminates")
            let lookup = Task {
                let hit = await store.isWhitelisted(path)
                XCTAssertFalse(hit)
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 1)
            lookup.cancel()
        }
        let entries = await store.list()
        XCTAssertEqual(entries.count, 1, "failed resolution must not monopolize the actor")
    }

    func testRelativeLinkTargetsResolveDotDotAfterIntermediateSymlinksAndMissingSuffix() async throws {
        let home = try makeHome()
        let real = home.appendingPathComponent("actual/内部")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: home.appendingPathComponent("redirect").path, withDestinationPath: "actual/内部"
        )
        try FileManager.default.createSymbolicLink(
            atPath: home.appendingPathComponent("alias").path, withDestinationPath: "redirect/../missing/child"
        )
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: home.appendingPathComponent("actual/missing").path)
        let hit = await store.isWhitelisted(home.appendingPathComponent("alias/grandchild").path)
        XCTAssertTrue(hit, "lexically collapsing redirect/.. would resolve to the wrong parent")
    }

    func testUnreadableAncestorProducesResolutionFailureRatherThanAccessOrSafeVerdict() throws {
        let home = try makeHome()
        let blocked = home.appendingPathComponent("Library/Caches/com.example.fixture/blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        addTeardownBlock { _ = chmod(blocked.path, S_IRWXU) }
        let probe = open(blocked.path, O_RDONLY)
        if probe >= 0 {
            close(probe)
            throw XCTSkip("runner bypasses fixture permission bits")
        }
        let result = SafetyEngine().evaluate(path: blocked.path + "/child", home: home.path)
        XCTAssertEqual(result.0, .forbid)
        XCTAssertEqual(result.1, .symbolicLinkResolutionFailed)
    }
}
