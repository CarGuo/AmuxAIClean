import Foundation
import XCTest
@testable import SafetyKit

final class AdversarialSymlinkChallengeTests: XCTestCase {
    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdversarialSymlinkChallenge-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/com.example.fixture"),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
        }
        return home
    }

    // MARK: - Challenge 1: Circular Links & Loops
    func testAdversarial_CircularLinks_AllTopologiesFailClosed() async throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)
        let store = WhitelistStore(storageURL: nil)

        // 1. Direct self-referential link: loop -> loop
        let loopSelf = cache.appendingPathComponent("self_loop")
        try FileManager.default.createSymbolicLink(atPath: loopSelf.path, withDestinationPath: "self_loop")

        // 2. Direct mutual cycle: a -> b, b -> a
        let loopA = cache.appendingPathComponent("loop_a")
        let loopB = cache.appendingPathComponent("loop_b")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: "loop_b")
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: "loop_a")

        // 3. Multi-hop cycle (3-hop): c1 -> c2 -> c3 -> c1
        let c1 = cache.appendingPathComponent("c1")
        let c2 = cache.appendingPathComponent("c2")
        let c3 = cache.appendingPathComponent("c3")
        try FileManager.default.createSymbolicLink(atPath: c1.path, withDestinationPath: "c2")
        try FileManager.default.createSymbolicLink(atPath: c2.path, withDestinationPath: "c3")
        try FileManager.default.createSymbolicLink(atPath: c3.path, withDestinationPath: "c1")

        // 4. Multi-hop cycle (10-hop)
        var chainPaths: [String] = []
        for i in 0..<10 {
            let nextI = (i + 1) % 10
            let current = cache.appendingPathComponent("hop_\(i)")
            let target = "hop_\(nextI)"
            try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: target)
            chainPaths.append(current.path)
        }

        // 5. Relative loops with ./ and ../
        let subDir = cache.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let relA = subDir.appendingPathComponent("rel_a")
        let relB = cache.appendingPathComponent("rel_b")
        try FileManager.default.createSymbolicLink(atPath: relA.path, withDestinationPath: "../rel_b")
        try FileManager.default.createSymbolicLink(atPath: relB.path, withDestinationPath: "subdir/rel_a")

        // 6. Dangling cycle with non-existent components:
        // dangCycleA -> nonexistent/../dangCycleB, dangCycleB -> dangCycleA
        let dangCycleA = cache.appendingPathComponent("dang_cycle_a")
        let dangCycleB = cache.appendingPathComponent("dang_cycle_b")
        try FileManager.default.createSymbolicLink(atPath: dangCycleA.path, withDestinationPath: "nonexistent/../dang_cycle_b")
        try FileManager.default.createSymbolicLink(atPath: dangCycleB.path, withDestinationPath: "dang_cycle_a")

        // Gather all test paths including variations with subpaths and trailing slashes
        var testPaths: [String] = [
            loopSelf.path, loopSelf.path + "/", loopSelf.path + "/subpath",
            loopA.path, loopA.path + "/", loopA.path + "/child/grandchild",
            loopB.path,
            c1.path, c2.path, c3.path, c1.path + "/child",
            relA.path, relB.path, relA.path + "/child",
            dangCycleA.path, dangCycleB.path, dangCycleA.path + "/child"
        ]
        testPaths.append(contentsOf: chainPaths)

        for path in testPaths {
            // Resolver MUST return failure
            let resolveRes = SymbolicLinkResolver.resolve(path)
            switch resolveRes {
            case .failure(let err):
                switch err {
                case .fileSystem(_, let code):
                    XCTAssertTrue(code == ELOOP || code == ENOENT, "Error for \(path) should be ELOOP or ENOENT, got \(code)")
                default:
                    XCTFail("Unexpected resolver error type for \(path): \(err)")
                }
            case .success(let resolved):
                XCTFail("Cyclic link \(path) resolved unexpectedly to \(resolved)")
            }

            // SafetyEngine plain MUST fail closed (.forbid, .symbolicLinkResolutionFailed)
            let plain = engine.evaluate(path: path, home: home.path)
            XCTAssertEqual(plain.0, .forbid, "Verdict for cyclic path \(path) must be forbid")
            XCTAssertEqual(plain.1, .symbolicLinkResolutionFailed, "Rejection for \(path) must be symbolicLinkResolutionFailed")

            // SafetyEngine trie MUST fail closed
            let vendor = engine.evaluate(path: path, trie: trie, home: home.path)
            XCTAssertEqual(vendor.0, .forbid, "Vendor verdict for cyclic path \(path) must be forbid")
            XCTAssertEqual(vendor.1, .symbolicLinkResolutionFailed, "Vendor rejection for \(path) must be symbolicLinkResolutionFailed")

            // BundleProtection evidence MUST be unresolved
            let evidence = engine.bundleProtectionEvidence(path: path, home: home.path)
            XCTAssertEqual(evidence, .unresolved, "Evidence for cyclic path \(path) must be unresolved")

            // WhitelistStore MUST return false without hanging or deadlocking
            let hit = await store.isWhitelisted(path)
            XCTAssertFalse(hit, "Cyclic link \(path) must never be whitelisted")
        }
    }

    // MARK: - Challenge 2: Deep Chains and POSIX Limits
    func testAdversarial_SymlinkChainLength_AtAndBeyondPosixLimit() throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()

        let linkLimit = Int(sysconf(_SC_SYMLOOP_MAX))
        XCTAssertGreaterThan(linkLimit, 0, "_SC_SYMLOOP_MAX must be positive")

        let targetFile = cache.appendingPathComponent("real_target.txt")
        try "payload".write(to: targetFile, atomically: true, encoding: .utf8)

        // 1. Chain exceeding linkLimit by 2 (e.g. 34 if limit is 32)
        // link_0 -> link_1 -> ... -> link_N -> real_target.txt
        let excessCount = linkLimit + 2
        for i in 0..<excessCount {
            let link = cache.appendingPathComponent("exceed_\(i)")
            let nextTarget = (i == excessCount - 1) ? targetFile.path : cache.appendingPathComponent("exceed_\(i + 1)").path
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: nextTarget)
        }

        let startExcessLink = cache.appendingPathComponent("exceed_0").path
        let excessResolve = SymbolicLinkResolver.resolve(startExcessLink)
        switch excessResolve {
        case .failure(let err):
            switch err {
            case .fileSystem(_, let code):
                XCTAssertEqual(code, ELOOP, "Exceeding link limit must yield ELOOP")
            default:
                XCTFail("Expected fileSystem error with ELOOP, got \(err)")
            }
        case .success(let res):
            XCTFail("Chain exceeding limit resolved unexpectedly to \(res)")
        }

        let excessEval = engine.evaluate(path: startExcessLink, home: home.path)
        XCTAssertEqual(excessEval.0, .forbid)
        XCTAssertEqual(excessEval.1, .symbolicLinkResolutionFailed)

        // 2. Chain of 60 links (significantly beyond limit)
        for i in 0..<60 {
            let link = cache.appendingPathComponent("deep_\(i)")
            let nextTarget = (i == 59) ? targetFile.path : cache.appendingPathComponent("deep_\(i + 1)").path
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: nextTarget)
        }
        let deepStart = cache.appendingPathComponent("deep_0").path
        let deepEval = engine.evaluate(path: deepStart, home: home.path)
        XCTAssertEqual(deepEval.0, .forbid)
        XCTAssertEqual(deepEval.1, .symbolicLinkResolutionFailed)

        // 3. Valid chain within limit (5 hops) should resolve safely
        for i in 0..<5 {
            let link = cache.appendingPathComponent("valid_\(i)")
            let nextTarget = (i == 4) ? targetFile.path : cache.appendingPathComponent("valid_\(i + 1)").path
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: nextTarget)
        }
        let validStart = cache.appendingPathComponent("valid_0").path
        let validResolve = SymbolicLinkResolver.resolve(validStart)
        XCTAssertEqual(validResolve, .success(targetFile.path))
        let validEval = engine.evaluate(path: validStart, home: home.path)
        XCTAssertEqual(validEval.0, .safe)
        XCTAssertEqual(validEval.1, .ok)
    }

    // MARK: - Challenge 3: Deep Nesting and Path Limits
    func testAdversarial_DeepPathNestingAndLongPaths_BoundedMemoryAndNoCrash() throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()

        // 1. Deep existing directory hierarchy (40 levels, well within PATH_MAX)
        var currentDir = cache
        for i in 0..<40 {
            currentDir = currentDir.appendingPathComponent("lvl_\(i)")
        }
        try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
        let deepFile = currentDir.appendingPathComponent("deep_file.txt")
        try "deep_payload".write(to: deepFile, atomically: true, encoding: .utf8)

        let deepResolve = SymbolicLinkResolver.resolve(deepFile.path)
        XCTAssertEqual(deepResolve, .success(deepFile.path))
        let deepEval = engine.evaluate(path: deepFile.path, home: home.path)
        XCTAssertEqual(deepEval.0, .safe)
        XCTAssertEqual(deepEval.1, .ok)

        // 2a. Deep dangling path WITHIN PATH_MAX (20 non-existent components, ~300 chars)
        let missingRoot = cache.appendingPathComponent("missing_root")
        var moderateDanglingPath = missingRoot.path
        for i in 0..<20 {
            moderateDanglingPath += "/nonexistent_\(i)"
        }
        let moderateResolve = SymbolicLinkResolver.resolve(moderateDanglingPath)
        XCTAssertEqual(moderateResolve, .success(moderateDanglingPath))
        let moderateEval = engine.evaluate(path: moderateDanglingPath, home: home.path)
        XCTAssertEqual(moderateEval.0, .safe)
        XCTAssertEqual(moderateEval.1, .ok)

        // 2b. Deep dangling path EXCEEDING PATH_MAX (100 non-existent components, ~1500 chars > 1024)
        var extremeDanglingPath = missingRoot.path
        for i in 0..<100 {
            extremeDanglingPath += "/nonexistent_\(i)"
        }
        let extremeResolve = SymbolicLinkResolver.resolve(extremeDanglingPath)
        switch extremeResolve {
        case .failure(let failure):
            switch failure {
            case .fileSystem(_, let code):
                XCTAssertEqual(code, ENAMETOOLONG, "Path exceeding PATH_MAX must return ENAMETOOLONG")
            default:
                XCTFail("Unexpected failure for extreme path: \(failure)")
            }
        case .success(let path):
            XCTFail("Path exceeding PATH_MAX should not resolve: \(path)")
        }
        // SafetyEngine must FAIL CLOSED on extreme paths
        let extremeEval = engine.evaluate(path: extremeDanglingPath, home: home.path)
        XCTAssertEqual(extremeEval.0, .forbid)
        XCTAssertEqual(extremeEval.1, .symbolicLinkResolutionFailed)

        // 3a. Redundant . and .. segments within PATH_MAX (20 pairs, ~200 chars)
        var moderateZigzagPath = cache.path
        for _ in 0..<15 {
            moderateZigzagPath += "/./subdir/../."
        }
        let zigzagResolve = SymbolicLinkResolver.resolve(moderateZigzagPath)
        XCTAssertEqual(zigzagResolve, .success(cache.path))

        // 3b. Redundant . and .. segments EXCEEDING PATH_MAX (200 pairs, ~2600 chars)
        var extremeZigzagPath = cache.path
        for _ in 0..<200 {
            extremeZigzagPath += "/./subdir/../."
        }
        let extremeZigzagResolve = SymbolicLinkResolver.resolve(extremeZigzagPath)
        switch extremeZigzagResolve {
        case .failure(let failure):
            switch failure {
            case .fileSystem(_, let code):
                XCTAssertEqual(code, ENAMETOOLONG, "Path exceeding PATH_MAX must return ENAMETOOLONG")
            default:
                XCTFail("Unexpected failure for extreme zigzag: \(failure)")
            }
        case .success(let path):
            XCTFail("Path exceeding PATH_MAX should not resolve: \(path)")
        }
        let extremeZigzagEval = engine.evaluate(path: extremeZigzagPath, home: home.path)
        XCTAssertEqual(extremeZigzagEval.0, .forbid)
        XCTAssertEqual(extremeZigzagEval.1, .dotDotInPath)
    }

    // MARK: - Challenge 4: Non-UTF8 Symlink Byte Sequences
    func testAdversarial_NonUTF8ByteSequences_ComprehensiveEncodingsFailClosed() throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)

        let badByteSequences: [(name: String, bytes: [UInt8])] = [
            ("raw_0xFF", [0xFF, 0xFE, 0xFD, 0x00]),
            ("overlong_slash", [0x2F, 0xC0, 0xAF, 0x61, 0x00]),
            ("lone_surrogate", [0xED, 0xA0, 0x80, 0x00]),
            ("invalid_continuation", [0x80, 0x81, 0x82, 0x00]),
            ("non_utf8_in_middle", [0x61, 0x2F, 0xFE, 0xFF, 0x2F, 0x62, 0x00])
        ]

        for item in badByteSequences {
            let link = cache.appendingPathComponent(item.name)
            let ret = item.bytes.withUnsafeBufferPointer { ptr in
                symlink(ptr.baseAddress!.withMemoryRebound(to: CChar.self, capacity: item.bytes.count) { $0 }, link.path)
            }
            guard ret == 0 else { continue }

            // 1. Direct link resolution must return EILSEQ
            let res = SymbolicLinkResolver.resolve(link.path)
            switch res {
            case .failure(let err):
                switch err {
                case .fileSystem(_, let code):
                    XCTAssertEqual(code, EILSEQ, "\(item.name) must fail with EILSEQ")
                default:
                    XCTFail("Expected fileSystem failure for \(item.name), got \(err)")
                }
            case .success:
                XCTFail("\(item.name) resolved unexpectedly")
            }

            // 2. Trailing slash on non-UTF8 link must also fail closed
            let trailingSlashPath = link.path + "/"
            let resTrailing = SymbolicLinkResolver.resolve(trailingSlashPath)
            switch resTrailing {
            case .failure(let err):
                switch err {
                case .fileSystem(_, let code):
                    XCTAssertEqual(code, EILSEQ, "Trailing slash on \(item.name) must fail with EILSEQ")
                default:
                    XCTFail("Expected fileSystem failure, got \(err)")
                }
            case .success:
                XCTFail("Trailing slash on \(item.name) resolved unexpectedly")
            }

            // 3. Child query into non-UTF8 link must also fail closed
            let childPath = link.path + "/nonexistent_child"
            let resChild = SymbolicLinkResolver.resolve(childPath)
            switch resChild {
            case .failure(let err):
                switch err {
                case .fileSystem(_, let code):
                    XCTAssertEqual(code, EILSEQ, "Child query on \(item.name) must fail with EILSEQ")
                default:
                    XCTFail("Expected fileSystem failure, got \(err)")
                }
            case .success:
                XCTFail("Child of \(item.name) resolved unexpectedly")
            }

            // 4. Multi-hop link pointing to non-UTF8 link
            let multiHop = cache.appendingPathComponent("chain_to_" + item.name)
            try FileManager.default.createSymbolicLink(atPath: multiHop.path, withDestinationPath: item.name)
            let resMulti = SymbolicLinkResolver.resolve(multiHop.path)
            switch resMulti {
            case .failure(let err):
                switch err {
                case .fileSystem(_, let code):
                    XCTAssertEqual(code, EILSEQ, "Chain to \(item.name) must fail with EILSEQ")
                default:
                    XCTFail("Expected fileSystem failure, got \(err)")
                }
            case .success:
                XCTFail("Chain to \(item.name) resolved unexpectedly")
            }

            // SafetyEngine evaluations must ALL be (.forbid, .symbolicLinkResolutionFailed)
            for testPath in [link.path, trailingSlashPath, childPath, multiHop.path] {
                let plain = engine.evaluate(path: testPath, home: home.path)
                XCTAssertEqual(plain.0, .forbid, "Verdict for \(testPath) must be forbid")
                XCTAssertEqual(plain.1, .symbolicLinkResolutionFailed, "Rejection for \(testPath) must be symbolicLinkResolutionFailed")

                let vendor = engine.evaluate(path: testPath, trie: trie, home: home.path)
                XCTAssertEqual(vendor.0, .forbid, "Vendor verdict for \(testPath) must be forbid")
                XCTAssertEqual(vendor.1, .symbolicLinkResolutionFailed, "Vendor rejection for \(testPath) must be symbolicLinkResolutionFailed")

                let evidence = engine.bundleProtectionEvidence(path: testPath, home: home.path)
                XCTAssertEqual(evidence, .unresolved, "Evidence for \(testPath) must be unresolved")
            }
        }
    }

    // MARK: - Challenge 5: Trailing Slashes and Non-Directory Boundary Traversals
    func testAdversarial_TrailingSlashesAndNonDirectoryTraversals_StrictEnforcement() throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()

        // 1. Regular file
        let regFile = cache.appendingPathComponent("regular.txt")
        try "content".write(to: regFile, atomically: true, encoding: .utf8)

        // 2. Symlink to regular file
        let symToFile = cache.appendingPathComponent("symlink_to_regular")
        try FileManager.default.createSymbolicLink(atPath: symToFile.path, withDestinationPath: "regular.txt")

        // Trailing slashes on files/symlinks to files resolve to canonical file path
        XCTAssertEqual(SymbolicLinkResolver.resolve(regFile.path + "/"), .success(regFile.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(regFile.path + "///"), .success(regFile.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(symToFile.path + "/"), .success(regFile.path))
        XCTAssertEqual(SymbolicLinkResolver.resolve(symToFile.path + "///"), .success(regFile.path))

        // But attempting to traverse THROUGH a regular file as a directory MUST return ENOTDIR
        let badChildPaths = [
            regFile.path + "/child",
            regFile.path + "/child/grandchild",
            symToFile.path + "/child",
            symToFile.path + "/child/grandchild"
        ]
        for badPath in badChildPaths {
            let res = SymbolicLinkResolver.resolve(badPath)
            switch res {
            case .failure(let err):
                switch err {
                case .fileSystem(_, let code):
                    XCTAssertEqual(code, ENOTDIR, "\(badPath) must fail with ENOTDIR")
                default:
                    XCTFail("Expected fileSystem ENOTDIR for \(badPath), got \(err)")
                }
            case .success(let target):
                XCTFail("\(badPath) should not resolve, got \(target)")
            }

            let eval = engine.evaluate(path: badPath, home: home.path)
            XCTAssertEqual(eval.0, .forbid, "\(badPath) must be forbid")
            XCTAssertEqual(eval.1, .symbolicLinkResolutionFailed, "\(badPath) rejection must be symbolicLinkResolutionFailed")
        }
    }

    // MARK: - Challenge 6: Relative Symlink Escape Attacks
    func testAdversarial_RelativeEscapeAttacks_AllEscapeVectorsForbidden() throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)

        // Create nested subdirectories in cache: cache/sub1/sub2/sub3
        // Depth from home:
        // home -> Library -> Caches -> com.example.fixture -> sub1 -> sub2 -> sub3
        // Total 6 levels from home. 6 times ".." reaches home root.
        let sub3 = cache.appendingPathComponent("sub1/sub2/sub3")
        try FileManager.default.createDirectory(at: sub3, withIntermediateDirectories: true)

        let rootDotDots = String(repeating: "../", count: 20)
        let homeDotDots = "../../../../../../"

        // 1. Subtree forbidden targets: both the link itself and any child must be .forbid
        let subtreeEscapeTargets: [(name: String, target: String, expectedRejection: SafetyRejection)] = [
            // Escapes to system root directories (hard forbid prefix)
            ("esc_system", rootDotDots + "System", .hardForbidPrefix),
            ("esc_usr_bin", rootDotDots + "usr/bin", .hardForbidPrefix),
            ("esc_applications", rootDotDots + "Applications", .hardForbidPrefix),
            ("esc_etc", rootDotDots + "etc", .hardForbidPrefix),
            ("esc_var_db", rootDotDots + "var/db", .hardForbidPrefix),
            ("esc_missing_sys", rootDotDots + "System/Missing-\(UUID().uuidString)", .hardForbidPrefix),

            // Escapes into sensitive credentials (entire subtree is forbid)
            ("esc_ssh", homeDotDots + ".ssh", .sensitiveCredential),
            ("esc_aws", homeDotDots + ".aws", .sensitiveCredential),
            ("esc_gitconfig", homeDotDots + ".gitconfig", .sensitiveCredential),
            ("esc_keychains", homeDotDots + "Library/Keychains", .sensitiveCredential)
        ]

        for vector in subtreeEscapeTargets {
            let link = sub3.appendingPathComponent(vector.name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: vector.target)

            let pathsToTest = [link.path, link.path + "/child", link.path + "/"]

            for testPath in pathsToTest {
                let plain = engine.evaluate(path: testPath, home: home.path)
                XCTAssertEqual(plain.0, .forbid, "Subtree vector \(vector.name) on path \(testPath) MUST be forbid")
                XCTAssertEqual(plain.1, vector.expectedRejection, "Subtree vector \(vector.name) on path \(testPath) expected \(vector.expectedRejection) but got \(plain.1)")

                let vendor = engine.evaluate(path: testPath, trie: trie, home: home.path)
                XCTAssertEqual(vendor.0, .forbid, "Subtree vector \(vector.name) on path \(testPath) MUST be forbid under trie")
                XCTAssertEqual(vendor.1, vector.expectedRejection, "Subtree vector \(vector.name) on path \(testPath) expected \(vector.expectedRejection) under trie")
            }
        }

        // 2. Root-only forbidden targets (user documents root & filesystem root):
        // The root itself and trailing slash are .forbid, but user documents children are .confirm
        let rootOnlyTargets: [(name: String, target: String, expectedRejection: SafetyRejection)] = [
            ("esc_root", rootDotDots, .rootOrAboveHome),
            ("esc_home_root", homeDotDots, .userDocumentsRoot),
            ("esc_documents", homeDotDots + "Documents", .userDocumentsRoot),
            ("esc_desktop", homeDotDots + "Desktop", .userDocumentsRoot)
        ]

        for vector in rootOnlyTargets {
            let link = sub3.appendingPathComponent(vector.name)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: vector.target)

            // Link itself and trailing slash MUST be forbid
            for testPath in [link.path, link.path + "/"] {
                let plain = engine.evaluate(path: testPath, home: home.path)
                XCTAssertEqual(plain.0, .forbid, "Root vector \(vector.name) on \(testPath) MUST be forbid")
                XCTAssertEqual(plain.1, vector.expectedRejection, "Root vector \(vector.name) on \(testPath) expected \(vector.expectedRejection)")
            }

            // Child path into filesystem root (/child) or user documents is .confirm (not automatically deleted, requires confirmation or pipeline scope rejection)
            let childPath = link.path + "/child"
            let childEval = engine.evaluate(path: childPath, home: home.path)
            XCTAssertEqual(childEval.0, .confirm, "Child of root / or user document root \(childPath) evaluates to confirm")
            XCTAssertEqual(childEval.1, .ok)
        }
    }

    // MARK: - Challenge 7: Malformed and Embedded Null Bytes
    func testAdversarial_EmbeddedNullBytesAndMalformedPaths() {
        let engine = SafetyEngine()

        // 1. Relative paths
        for rel in ["relative/path", "./relative", "../relative"] {
            let res = SymbolicLinkResolver.resolve(rel)
            XCTAssertEqual(res, .failure(.relativePath))
            let eval = engine.evaluate(path: rel)
            XCTAssertEqual(eval.0, .forbid)
            XCTAssertEqual(eval.1, .relativePath)
        }

        // 2. Paths with .. (dot dot)
        for dotPath in ["/Users/foo/../bar", "/Users/foo/..", "/.."] {
            let eval = engine.evaluate(path: dotPath)
            XCTAssertEqual(eval.0, .forbid)
            XCTAssertEqual(eval.1, .dotDotInPath)
        }

        // 3. Embedded null bytes in path
        let nullPath = "/Users/foo\0/bar"
        let resNull = SymbolicLinkResolver.resolve(nullPath)
        switch resNull {
        case .failure(let err):
            switch err {
            case .fileSystem(_, let code):
                XCTAssertEqual(code, EINVAL, "Embedded null byte must return EINVAL")
            default:
                XCTFail("Expected fileSystem EINVAL, got \(err)")
            }
        case .success:
            XCTFail("Embedded null byte resolved unexpectedly")
        }
    }

    // MARK: - Challenge 8: High Concurrency Multi-Threaded Stress Test
    func testAdversarial_ConcurrentStressHarness() async throws {
        let home = try makeTempHome()
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let engine = SafetyEngine()
        let trie = VendorTrie.build(vendors: [], home: home.path)

        // Setup fixture variety:
        // 1. Valid file
        let validFile = cache.appendingPathComponent("concurrent_valid.txt")
        try "content".write(to: validFile, atomically: true, encoding: .utf8)

        // 2. Cycle
        let cycle1 = cache.appendingPathComponent("conc_c1")
        let cycle2 = cache.appendingPathComponent("conc_c2")
        try FileManager.default.createSymbolicLink(atPath: cycle1.path, withDestinationPath: "conc_c2")
        try FileManager.default.createSymbolicLink(atPath: cycle2.path, withDestinationPath: "conc_c1")

        // 3. Escape
        let escLink = cache.appendingPathComponent("conc_esc")
        let rootDotDots = String(repeating: "../", count: 20)
        try FileManager.default.createSymbolicLink(atPath: escLink.path, withDestinationPath: rootDotDots + "System")

        // 4. Dangling
        let dangLink = cache.appendingPathComponent("conc_dang")
        try FileManager.default.createSymbolicLink(atPath: dangLink.path, withDestinationPath: "missing_target_\(UUID().uuidString)")

        let candidates = [
            (path: validFile.path, expectedVerdict: SafetyVerdict.safe),
            (path: cycle1.path, expectedVerdict: SafetyVerdict.forbid),
            (path: cycle2.path, expectedVerdict: SafetyVerdict.forbid),
            (path: escLink.path, expectedVerdict: SafetyVerdict.forbid),
            (path: dangLink.path, expectedVerdict: SafetyVerdict.safe)
        ]

        await withTaskGroup(of: Void.self) { group in
            for threadID in 0..<16 {
                group.addTask {
                    for iteration in 0..<100 {
                        let item = candidates[(threadID + iteration) % candidates.count]
                        let plain = engine.evaluate(path: item.path, home: home.path)
                        XCTAssertEqual(plain.0, item.expectedVerdict, "Mismatch in concurrent stress test for \(item.path)")

                        let vendor = engine.evaluate(path: item.path, trie: trie, home: home.path)
                        XCTAssertEqual(vendor.0, item.expectedVerdict, "Mismatch in concurrent trie stress test for \(item.path)")

                        _ = SymbolicLinkResolver.resolve(item.path)
                    }
                }
            }
        }
    }
}
