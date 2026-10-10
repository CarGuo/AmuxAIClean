import XCTest
import ScanKit
@testable import AppUI
import SafetyKit

final class AdversarialPathIdentityTests: XCTestCase {

    private func makeCandidate(
        id: UUID = UUID(),
        path: String,
        verdict: SafetyVerdict = .safe,
        rejection: SafetyRejection = .ok
    ) -> DeletionIntentCandidate {
        DeletionIntentCandidate(
            id: id,
            path: path,
            title: "AdversarialCandidate",
            isDirectory: false,
            bytes: 1024,
            fileCount: 1,
            verdict: verdict,
            rejection: rejection
        )
    }

    private func makeSnapshot() -> DeletionSnapshotIdentity {
        DeletionSnapshotIdentity(sessionID: UUID(), revision: 1, categoryID: "adversarial_test")
    }

    // MARK: - 1. Repeated & Consecutive Slashes

    func test_repeatedAndConsecutiveSlashes() {
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/"), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("//"), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("///"), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("////"), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/////"), "/")

        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a//b"), "/a/b")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a///b"), "/a/b")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a////b/////c"), "/a/b/c")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("///private///var////folders/////cache"), "/private/var/folders/cache")
    }

    // MARK: - 2. Trailing Slashes

    func test_trailingSlashes() {
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/"), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/"), "/private/tmp")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp//"), "/private/tmp")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp///"), "/private/tmp")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/var/folders/zz/T/cache/"), "/var/folders/zz/T/cache")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/var/folders/zz/T/cache///"), "/var/folders/zz/T/cache")
    }

    // MARK: - 3. Dot Components (. and ..)

    func test_singleDotComponents() {
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/."), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/./"), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/././."), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/./var/./folders"), "/private/var/folders")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/var/folders/."), "/private/var/folders")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/var/folders/./"), "/private/var/folders")
    }

    func test_doubleDotComponentsAndRootEscapes() {
        // Double dots at root must never escape root
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/.."), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/../.."), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/../../.."), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/../../../../private/tmp"), "/private/tmp")

        // Lexical cancellation
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/.."), "/")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/b/.."), "/a")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/b/../c"), "/a/c")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/b/../../c"), "/c")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/b/../../../c"), "/c")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/b/../../../../c"), "/c")

        // Complex mixed dot navigation
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/a/./b/../c/./d/../e"), "/a/c/e")
        XCTAssertEqual(
            DeletionIntentCandidate.pathIdentity("/private/var/./folders/zz/../zy/./T/../T/cache/."),
            "/private/var/folders/zy/T/cache"
        )
    }

    // MARK: - 4. Multi-Dot Filenames (Not navigation dots)

    func test_multiDotFilenamesPreserved() {
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/..."), "/private/tmp/...")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/...."), "/private/tmp/....")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/..hidden"), "/private/tmp/..hidden")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/.hidden"), "/private/tmp/.hidden")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/file.txt."), "/private/tmp/file.txt.")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("/private/tmp/file.txt.."), "/private/tmp/file.txt..")
    }

    // MARK: - 5. Physical vs Logical Namespace Non-Collapsing

    func test_physicalAndLogicalNamespacesNeverCollapse() {
        let pairs: [(physical: String, logical: String)] = [
            ("/private/var/folders/zz/T/cache", "/var/folders/zz/T/cache"),
            ("/private/tmp/scratch.log", "/tmp/scratch.log"),
            ("/private/etc/hosts", "/etc/hosts"),
            ("/private/var/run/daemon.pid", "/var/run/daemon.pid"),
            ("/private/var/log/system.log", "/var/log/system.log")
        ]

        for pair in pairs {
            let physNorm = DeletionIntentCandidate.pathIdentity(pair.physical)
            let logNorm = DeletionIntentCandidate.pathIdentity(pair.logical)

            XCTAssertEqual(physNorm, pair.physical, "Physical path must remain in physical namespace")
            XCTAssertEqual(logNorm, pair.logical, "Logical path must remain in logical namespace")
            XCTAssertNotEqual(physNorm, logNorm, "Physical and logical namespaces must NEVER collide")
        }
    }

    func test_dirtyPhysicalAndLogicalPathsNormalizeToDistinctIdentities() {
        let dirtyPhysical = "//private///var/./folders/zz/zy/../zy/T//cache///"
        let dirtyLogical = "/var/./folders/zz///zy/../zy/T/cache/"

        let normPhysical = DeletionIntentCandidate.pathIdentity(dirtyPhysical)
        let normLogical = DeletionIntentCandidate.pathIdentity(dirtyLogical)

        XCTAssertEqual(normPhysical, "/private/var/folders/zz/zy/T/cache")
        XCTAssertEqual(normLogical, "/var/folders/zz/zy/T/cache")
        XCTAssertNotEqual(normPhysical, normLogical)
    }

    // MARK: - 6. Non-ASCII and Unicode Paths

    func test_cjkAndEmojiAndAccentedPaths() {
        let cjkPath = "/private/var/folders/测试/缓存//数据/"
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity(cjkPath), "/private/var/folders/测试/缓存/数据")

        let emojiPath = "/private/tmp/🚀/📁//item///"
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity(emojiPath), "/private/tmp/🚀/📁/item")

        let accentedPath = "/private/tmp/./café/../café/résumé/"
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity(accentedPath), "/private/tmp/café/résumé")

        let complexSpecial = "/Library/Application Support/Foo (Bar) [Baz] 'Quoted'//Cache/"
        XCTAssertEqual(
            DeletionIntentCandidate.pathIdentity(complexSpecial),
            "/Library/Application Support/Foo (Bar) [Baz] 'Quoted'/Cache"
        )
    }

    func test_unicodeNormalizationFormsCanonicalEquivalence() {
        // NFC (precomposed: e with acute accent is 1 unicode scalar U+00E9)
        let nfc = "/private/tmp/caf\u{00E9}"
        // NFD (decomposed: e U+0065 followed by combining acute accent U+0301)
        let nfd = "/private/tmp/cafe\u{0301}"

        XCTAssertEqual(nfc, nfd, "Swift Strings are canonically equivalent across NFC/NFD")

        let candNFC = makeCandidate(path: nfc)
        let candNFD = makeCandidate(path: nfd)

        XCTAssertEqual(candNFC.standardizedPath, candNFD.standardizedPath)

        // DeletionIntent must recognize them as duplicate paths due to Swift canonical equivalence
        XCTAssertThrowsError(
            try DeletionIntent(
                origin: .scanSelection,
                mode: .professional,
                snapshotIdentity: makeSnapshot(),
                candidates: [candNFC, candNFD]
            )
        ) { error in
            guard case DeletionIntentValidationError.duplicatePath = error else {
                XCTFail("Expected duplicatePath error for canonically equivalent paths, got: \(error)")
                return
            }
        }
    }

    // MARK: - 7. Empty and Relative Paths Handling

    func test_emptyAndRelativePaths() {
        // Empty path
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity(""), "")

        // Relative paths (pathIdentity preserves without leading slash)
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("relative/path"), "relative/path")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("./relative/path"), "./relative/path")
        XCTAssertEqual(DeletionIntentCandidate.pathIdentity("../relative/path"), "../relative/path")

        // DeletionIntent must reject empty rawPath
        let emptyCand = makeCandidate(path: "")
        XCTAssertThrowsError(
            try DeletionIntent(
                origin: .scanSelection,
                mode: .professional,
                snapshotIdentity: makeSnapshot(),
                candidates: [emptyCand]
            )
        ) { error in
            guard case DeletionIntentValidationError.emptyPath(let candidateID) = error else {
                XCTFail("Expected emptyPath error, got \(error)")
                return
            }
            XCTAssertEqual(candidateID, emptyCand.id)
        }
    }

    // MARK: - 8. Path Length & Stress Test

    func test_extremelyLongPathsNormalizeWithoutCrashOrSlowdown() {
        // Deeply nested 1,000-segment path
        var deepComponents = ["private", "var"]
        for i in 0..<1000 {
            deepComponents.append("seg_\(i)")
        }
        let deepPath = "/" + deepComponents.joined(separator: "/")
        let dirtyDeepPath = "/" + deepComponents.joined(separator: "//") + "/"

        let normalized = DeletionIntentCandidate.pathIdentity(dirtyDeepPath)
        XCTAssertEqual(normalized, deepPath)

        // Deep cancellation chain (500 push/pop cycles)
        var cancellingPath = "/base"
        for _ in 0..<500 {
            cancellingPath += "/down/.."
        }
        cancellingPath += "/final"

        let resolved = DeletionIntentCandidate.pathIdentity(cancellingPath)
        XCTAssertEqual(resolved, "/base/final")
    }

    // MARK: - 9. Candidate Deduplication in DeletionIntent

    func test_deletionIntentAllowsDistinctPhysicalAndLogicalCandidates() throws {
        let physical = "/private/tmp/test_scratch.log"
        let logical = "/tmp/test_scratch.log"

        let candPhys = makeCandidate(path: physical)
        let candLog = makeCandidate(path: logical)

        let intent = try DeletionIntent(
            origin: .scanSelection,
            mode: .professional,
            snapshotIdentity: makeSnapshot(),
            candidates: [candPhys, candLog]
        )

        XCTAssertEqual(intent.candidates.count, 2)
        XCTAssertEqual(Set(intent.candidates.map(\.standardizedPath)).count, 2)
    }

    func test_deletionIntentDeduplicatesDirtyAndCleanEquivalentPaths() {
        let clean = "/private/var/folders/zz/T/cache"
        let dirty = "/private/var/folders/zz/./T/../T//cache///"

        let candClean = makeCandidate(path: clean)
        let candDirty = makeCandidate(path: dirty)

        XCTAssertEqual(candClean.standardizedPath, candDirty.standardizedPath)

        XCTAssertThrowsError(
            try DeletionIntent(
                origin: .scanSelection,
                mode: .professional,
                snapshotIdentity: makeSnapshot(),
                candidates: [candClean, candDirty]
            )
        ) { error in
            guard case DeletionIntentValidationError.duplicatePath(let dupePath) = error else {
                XCTFail("Expected duplicatePath error, got: \(error)")
                return
            }
            XCTAssertEqual(dupePath, clean)
        }
    }

    func test_deletionIntentRejectsEmptyCandidates() {
        XCTAssertThrowsError(
            try DeletionIntent(
                origin: .scanSelection,
                mode: .professional,
                snapshotIdentity: makeSnapshot(),
                candidates: []
            )
        ) { error in
            guard case DeletionIntentValidationError.emptyCandidates = error else {
                XCTFail("Expected emptyCandidates error, got: \(error)")
                return
            }
        }
    }

    func test_deletionIntentRejectsDuplicateCandidateIDs() {
        let sharedID = UUID()
        let cand1 = makeCandidate(id: sharedID, path: "/private/tmp/a")
        let cand2 = makeCandidate(id: sharedID, path: "/private/tmp/b")

        XCTAssertThrowsError(
            try DeletionIntent(
                origin: .scanSelection,
                mode: .professional,
                snapshotIdentity: makeSnapshot(),
                candidates: [cand1, cand2]
            )
        ) { error in
            guard case DeletionIntentValidationError.duplicateCandidateID(let id) = error else {
                XCTFail("Expected duplicateCandidateID error, got: \(error)")
                return
            }
            XCTAssertEqual(id, sharedID)
        }
    }

    // MARK: - 10. ReviewedDeletionObjects Integration with Namespaces

    func test_reviewedDeletionObjectsPreservesPhysicalLogicalDistinction() async throws {
        let tempDir = NSTemporaryDirectory()
        // Ensure trailing slash removed
        let logicalBase = tempDir.hasSuffix("/") ? String(tempDir.dropLast()) : tempDir
        let physicalBase = "/private" + logicalBase

        let testFileName = "test_adversarial_\(UUID().uuidString).txt"
        let logicalPath = logicalBase + "/" + testFileName
        let physicalPath = physicalBase + "/" + testFileName

        // Create temporary fixture file
        FileManager.default.createFile(atPath: logicalPath, contents: Data("test".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: logicalPath)
        }

        // Capture physical path
        let prepPhysical = await ReviewedDeletionObjects.capture(paths: [physicalPath], expectedIdentities: [:])
        guard case .ready(let reviewedPhysical) = prepPhysical else {
            XCTFail("Expected ready for physical path")
            return
        }

        // Capture logical path
        let prepLogical = await ReviewedDeletionObjects.capture(paths: [logicalPath], expectedIdentities: [:])
        guard case .ready(let reviewedLogical) = prepLogical else {
            XCTFail("Expected ready for logical path")
            return
        }

        // Physical reviewed objects must match physical candidates, but NOT logical candidates
        XCTAssertTrue(reviewedPhysical.matchesExactTargets([physicalPath]))
        XCTAssertFalse(reviewedPhysical.matchesExactTargets([logicalPath]))

        // Logical reviewed objects must match logical candidates, but NOT physical candidates
        XCTAssertTrue(reviewedLogical.matchesExactTargets([logicalPath]))
        XCTAssertFalse(reviewedLogical.matchesExactTargets([physicalPath]))

        // Physical and logical candidate standardizations must remain distinct
        let candPhys = makeCandidate(path: physicalPath)
        let candLog = makeCandidate(path: logicalPath)
        XCTAssertNotEqual(candPhys.standardizedPath, candLog.standardizedPath)

        // Both can be safely packaged into the same DeletionIntent without collision
        let intent = try DeletionIntent(
            origin: .scanSelection,
            mode: .professional,
            snapshotIdentity: makeSnapshot(),
            candidates: [candPhys, candLog]
        )
        XCTAssertEqual(intent.candidates.count, 2)
    }

    // MARK: - 11. Large Scale Multi-Candidate Deduplication Stress

    func test_largeScaleCandidateDeduplicationPerformance() throws {
        let count = 1000
        var candidates: [DeletionIntentCandidate] = []
        candidates.reserveCapacity(count)

        for i in 0..<count {
            let path = "/private/var/folders/zz/zyxvpxvq6csfxvn/T/cache_\(i)"
            candidates.append(makeCandidate(path: path))
        }

        // Creating intent with 1000 unique candidates should succeed swiftly
        let start = Date()
        let intent = try DeletionIntent(
            origin: .scanSelection,
            mode: .professional,
            snapshotIdentity: makeSnapshot(),
            candidates: candidates
        )
        let duration = Date().timeIntervalSince(start)
        XCTAssertEqual(intent.candidates.count, count)
        XCTAssertLessThan(duration, 0.5, "Deduplication of 1,000 candidates must complete in under 500ms")

        // Introducing one dirty duplicate candidate in the middle
        let duplicateDirtyCandidate = makeCandidate(
            path: "/private/var/folders/zz/zyxvpxvq6csfxvn/T/cache_500///"
        )
        var candidatesWithDupe = candidates
        candidatesWithDupe.append(duplicateDirtyCandidate)

        XCTAssertThrowsError(
            try DeletionIntent(
                origin: .scanSelection,
                mode: .professional,
                snapshotIdentity: makeSnapshot(),
                candidates: candidatesWithDupe
            )
        ) { error in
            guard case DeletionIntentValidationError.duplicatePath(let dupe) = error else {
                XCTFail("Expected duplicatePath error, got \(error)")
                return
            }
            XCTAssertEqual(dupe, "/private/var/folders/zz/zyxvpxvq6csfxvn/T/cache_500")
        }
    }
}

