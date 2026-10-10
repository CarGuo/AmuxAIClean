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

    func testPureRelativeMultiHopDanglingChainResolvesExistingAncestorAndForbiddenEscape() async throws {
        let home = try makeHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let d1 = cache.appendingPathComponent("d1")
        let d2 = cache.appendingPathComponent("d2")
        try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: true)

        // 1. Pure relative chain terminating inside cache:
        // link1 -> d1/link2
        // d1/link2 -> ../d2/link3
        // d2/link3 -> ../missing_dir/non_existent_leaf
        let link1 = cache.appendingPathComponent("link1")
        let link2 = d1.appendingPathComponent("link2")
        let link3 = d2.appendingPathComponent("link3")
        try FileManager.default.createSymbolicLink(atPath: link1.path, withDestinationPath: "d1/link2")
        try FileManager.default.createSymbolicLink(atPath: link2.path, withDestinationPath: "../d2/link3")
        try FileManager.default.createSymbolicLink(
            atPath: link3.path,
            withDestinationPath: "../missing_dir/non_existent_leaf"
        )

        // Verify direct resolution on pure relative dangling chain
        let expectedResolved = cache.path + "/missing_dir/non_existent_leaf"
        let res1 = SymbolicLinkResolver.resolve(link1.path)
        XCTAssertEqual(res1, .success(expectedResolved))

        // Verify descendant queries on pure relative dangling chain
        let resDescendant = SymbolicLinkResolver.resolve(link1.path + "/sub/child")
        XCTAssertEqual(resDescendant, .success(expectedResolved + "/sub/child"))

        // Verify SafetyEngine evaluation on safe dangling target
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)
        let evalSafe = engine.evaluate(path: link1.path, home: home.path)
        XCTAssertEqual(evalSafe.0, .safe)
        XCTAssertEqual(evalSafe.1, .ok)

        // Verify WhitelistStore integration on resolved ancestor
        let store = WhitelistStore(storageURL: nil)
        await store.add(path: cache.path + "/missing_dir")
        let hit = await store.isWhitelisted(link1.path)
        XCTAssertTrue(hit, "pure relative dangling link should match whitelisted ancestor")
        let hitChild = await store.isWhitelisted(link1.path + "/sub/child")
        XCTAssertTrue(hitChild, "descendant of pure relative dangling link should match whitelisted ancestor")

        // 2. Pure relative chain escaping to forbidden /System destination:
        // esc1 -> d1/esc2
        // d1/esc2 -> ../../../../../../../../../../../../../System/Library/Missing-\(UUID().uuidString)
        let esc1 = cache.appendingPathComponent("esc1")
        let esc2 = d1.appendingPathComponent("esc2")
        let missingSysUUID = UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: esc1.path, withDestinationPath: "d1/esc2")
        try FileManager.default.createSymbolicLink(
            atPath: esc2.path,
            withDestinationPath: "../../../../../../../../../../../../../System/Library/Missing-\(missingSysUUID)"
        )

        let expectedEscResolved = "/System/Library/Missing-\(missingSysUUID)"
        let resEsc = SymbolicLinkResolver.resolve(esc1.path)
        XCTAssertEqual(resEsc, .success(expectedEscResolved))

        for path in [esc1.path, esc1.path + "/child", esc2.path] {
            let plain = engine.evaluate(path: path, home: home.path)
            let vendor = engine.evaluate(path: path, trie: trie, home: home.path)
            XCTAssertEqual(plain.0, .forbid, path)
            XCTAssertEqual(plain.1, .hardForbidPrefix, path)
            XCTAssertEqual(vendor.0, plain.0, path)
            XCTAssertEqual(vendor.1, plain.1, path)
        }
    }

    func testNonUTF8SymlinkTargetYieldsEILSEQAndSafetyResolutionFailure() throws {
        let home = try makeHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let badLink = cache.appendingPathComponent("bad_utf8_symlink")

        let invalidBytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0x00]
        let createResult = invalidBytes.withUnsafeBufferPointer { ptr in
            symlink(ptr.baseAddress!.withMemoryRebound(to: CChar.self, capacity: 4) { $0 }, badLink.path)
        }
        XCTAssertEqual(createResult, 0, "POSIX symlink with non-UTF8 target should succeed on APFS")

        let realCache = cache.path.withCString { realpath($0, nil) }
        XCTAssertNotNil(realCache)
        defer { free(realCache) }
        let canonicalBadLink = String(cString: realCache!) + "/bad_utf8_symlink"

        // 1. SymbolicLinkResolver direct failure with typed EILSEQ error
        let resolveResult = SymbolicLinkResolver.resolve(badLink.path)
        XCTAssertEqual(
            resolveResult,
            .failure(.fileSystem(path: canonicalBadLink, code: EILSEQ)),
            "Non-UTF8 target must fail with EILSEQ at canonical path"
        )

        // 2. Multi-hop symlink pointing to the non-UTF8 symlink
        let chainToBad = cache.appendingPathComponent("chain_to_bad")
        try FileManager.default.createSymbolicLink(atPath: chainToBad.path, withDestinationPath: "bad_utf8_symlink")
        let chainResolveResult = SymbolicLinkResolver.resolve(chainToBad.path)
        XCTAssertEqual(
            chainResolveResult,
            .failure(.fileSystem(path: canonicalBadLink, code: EILSEQ)),
            "Chain leading to non-UTF8 target must also fail with EILSEQ at the offending link"
        )

        // 3. SafetyEngine and VendorTrie evaluate to .forbid + .symbolicLinkResolutionFailed
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)
        for path in [badLink.path, badLink.path + "/child", chainToBad.path] {
            let plain = engine.evaluate(path: path, home: home.path)
            let vendor = engine.evaluate(path: path, trie: trie, home: home.path)
            XCTAssertEqual(plain.0, .forbid, path)
            XCTAssertEqual(plain.1, .symbolicLinkResolutionFailed, path)
            XCTAssertEqual(vendor.0, plain.0, path)
            XCTAssertEqual(vendor.1, plain.1, path)
            XCTAssertEqual(
                engine.bundleProtectionEvidence(path: path, home: home.path),
                .unresolved,
                "Unresolvable non-UTF8 symlink target cannot prove bundle protection state"
            )
        }
    }

    func testTrailingSlashesOnSymlinksAndFilesNormalizeConsistentlyAndEnforceDirectoryBoundaries() throws {
        let home = try makeHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")

        // 1. Existing regular file and symlink to file
        let regularFile = cache.appendingPathComponent("test_file")
        try "payload".write(to: regularFile, atomically: true, encoding: .utf8)
        let symlinkToFile = cache.appendingPathComponent("symlink_to_file")
        try FileManager.default.createSymbolicLink(atPath: symlinkToFile.path, withDestinationPath: "test_file")

        // 2. Existing directory and symlink to directory
        let regularDir = cache.appendingPathComponent("test_dir")
        try FileManager.default.createDirectory(at: regularDir, withIntermediateDirectories: true)
        let symlinkToDir = cache.appendingPathComponent("symlink_to_dir")
        try FileManager.default.createSymbolicLink(atPath: symlinkToDir.path, withDestinationPath: "test_dir")

        // 3. Dangling symlink to missing file
        let danglingSymlink = cache.appendingPathComponent("dangling_to_file")
        try FileManager.default.createSymbolicLink(atPath: danglingSymlink.path, withDestinationPath: "missing_file")

        // Trailing slashes on files and file symlinks canonicalize cleanly to file path
        XCTAssertEqual(SymbolicLinkResolver.resolve(regularFile.path), .success(regularFile.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(regularFile.path + "/"), .success(regularFile.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(symlinkToFile.path), .success(regularFile.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(symlinkToFile.path + "/"), .success(regularFile.path))

        // Trailing slashes on directories and directory symlinks canonicalize cleanly to dir path
        XCTAssertEqual(SymbolicLinkResolver.resolve(regularDir.path), .success(regularDir.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(regularDir.path + "/"), .success(regularDir.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(symlinkToDir.path), .success(regularDir.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(symlinkToDir.path + "/"), .success(regularDir.path))

        // Dangling symlink with trailing slash resolves existing ancestor with missing leaf
        XCTAssertEqual(
            SymbolicLinkResolver.resolve(danglingSymlink.path + "/"),
            .success(cache.path + "/missing_file")
        )

        // POSIX directory boundary enforcement: traversing THROUGH a non-directory file MUST fail with ENOTDIR
        let fileChild = regularFile.path + "/non_existent_child"
        let symlinkChild = symlinkToFile.path + "/non_existent_child"
        XCTAssertEqual(
            SymbolicLinkResolver.resolve(fileChild),
            .failure(.fileSystem(path: fileChild, code: ENOTDIR)),
            "Subpath through regular file must return ENOTDIR"
        )
        XCTAssertEqual(
            SymbolicLinkResolver.resolve(symlinkChild),
            .failure(.fileSystem(path: symlinkChild, code: ENOTDIR)),
            "Subpath through symlink to regular file must return ENOTDIR"
        )

        // SafetyEngine must forbid paths attempting to traverse through regular files
        let engine = SafetyEngine()
        for path in [fileChild, symlinkChild] {
            let res = engine.evaluate(path: path, home: home.path)
            XCTAssertEqual(res.0, .forbid, path)
            XCTAssertEqual(res.1, .symbolicLinkResolutionFailed, path)
        }
    }
}
