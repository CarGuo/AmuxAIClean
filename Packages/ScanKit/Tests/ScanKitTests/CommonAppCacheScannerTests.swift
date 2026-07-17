import Darwin
import SafetyKit
import XCTest
@testable import ScanKit

final class CommonAppCacheScannerTests: XCTestCase {

    func testDetectReturnsOnlyExistingNonEmptyIncludedRules() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let wechat = home.appendingPathComponent("Library/Caches/com.tencent.xinWeChat", isDirectory: true)
        try FileManager.default.createDirectory(at: wechat, withIntermediateDirectories: true)
        try writeFile(in: wechat, name: "cache.bin", bytes: 128)

        let empty = home.appendingPathComponent("Library/Caches/com.empty.App", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let vendors = [
            VendorRule(
                name: "WeChat Cache",
                bundleIDPrefix: "com.tencent.xinWeChat",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .safe,
                             reason: "cache")
                ]
            ),
            VendorRule(
                name: "Empty Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.empty.App",
                             verdict: .safe,
                             reason: "empty")
                ]
            ),
            VendorRule(
                name: "Blocked",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .forbid,
                             reason: "blocked")
                ]
            ),
            VendorRule(
                name: "Other Category",
                category: "developer_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .safe,
                             reason: "wrong category")
                ]
            )
        ]

        let result = CommonAppCacheScanner.detect(vendors: vendors, home: home)
        let hits = result.hits
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].ruleName, "WeChat Cache")
        XCTAssertEqual(hits[0].bundleIDPrefix, "com.tencent.xinWeChat")
        XCTAssertEqual(hits[0].verdict, .safe)
        XCTAssertEqual(hits[0].sizeBytes, allocatedSize(of: wechat.appendingPathComponent("cache.bin")))
        XCTAssertEqual(hits[0].logicalSizeBytes, 128)
        XCTAssertEqual(hits[0].entryCount, 1)
        XCTAssertTrue(hits[0].isDirectory)
    }

    func testDetectExpandsBoundedGlobRules() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent("Library/Caches/com.example.App", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 256)

        let vendors = [
            VendorRule(
                name: "Example Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.example.*",
                             verdict: .safe,
                             reason: "glob cache")
                ]
            )
        ]

        let result = CommonAppCacheScanner.detect(vendors: vendors, home: home)
        let hits = result.hits
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url.lastPathComponent, "com.example.App")
        XCTAssertEqual(hits[0].sizeBytes, allocatedSize(of: cache.appendingPathComponent("cache.bin")))
        XCTAssertEqual(hits[0].logicalSizeBytes, 256)
    }

    /// v2026.07.17 C4 regression: candidate resolution itself must not glob/lstat another
    /// developer's Container before the caller has established FDA. The scanner returns one
    /// stable protected boundary so the UI can stay responsive and deletion remains fail-closed.
    func testProtectedAppDataPatternIsSkippedBeforeCandidateResolutionWithoutFDA() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent(
            "Library/Containers/com.example.Other/Data/Library/Caches/objects",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 64)
        let rule = VendorRule(
            name: "Protected Cache",
            category: "common_app_cache",
            paths: [
                PathRule(
                    path: "~/Library/Containers/com.example.Other/Data/Library/Caches/*",
                    verdict: .safe
                )
            ]
        )

        let result = CommonAppCacheScanner.detect(vendors: [rule], home: home)
        let boundary = home.appendingPathComponent(
            "Library/Containers",
            isDirectory: true
        ).standardizedFileURL.path

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(
            result.incompletePaths,
            [.init(path: boundary, reason: .protectedAppDataSkipped)]
        )
        XCTAssertFalse(result.isComplete)
    }

    func testProtectedAppDataPatternCanBeMeasuredAfterCallerEstablishesAccess() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent(
            "Library/Group Containers/group.example.shared/Library/Caches/objects",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 64)
        let rule = VendorRule(
            name: "Protected Group Cache",
            category: "common_app_cache",
            paths: [
                PathRule(
                    path: "~/Library/Group Containers/group.example.shared/Library/Caches/*",
                    verdict: .safe
                )
            ]
        )
        let options = CommonAppCacheScanner.Options(
            allowsProtectedAppDataAccess: true
        )

        let result = CommonAppCacheScanner.detect(
            vendors: [rule],
            home: home,
            options: options
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.hits.map(\.url.lastPathComponent), ["objects"])
    }

    func testWhitelistedProtectedPatternIsExcludedWithoutInventingTCCPartial() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let excluded = home.appendingPathComponent(
            "Library/Containers/com.example.Other",
            isDirectory: true
        ).standardizedFileURL.path
        let rule = VendorRule(
            name: "Whitelisted Protected Cache",
            category: "common_app_cache",
            paths: [
                PathRule(
                    path: "~/Library/Containers/com.example.Other/Data/Library/Caches/*",
                    verdict: .safe
                )
            ]
        )
        let options = CommonAppCacheScanner.Options(
            excludedCandidatePathPrefixes: [excluded]
        )

        let result = CommonAppCacheScanner.detect(
            vendors: [rule],
            home: home,
            options: options
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.incompletePaths.isEmpty)
        XCTAssertTrue(result.isComplete)
    }

    func testProtectedAppDataBoundaryUsesPathComponents() {
        let home = "/Users/fixture"
        XCTAssertEqual(
            CommonAppCacheScanner.protectedAppDataBoundary(
                for: "/Users/fixture/Library/Containers/com.example/cache",
                homePath: home
            ),
            "/Users/fixture/Library/Containers"
        )
        XCTAssertNil(
            CommonAppCacheScanner.protectedAppDataBoundary(
                for: "/Users/fixture/Library/ContainersBackup/com.example/cache",
                homePath: home
            )
        )
    }

    /// A non-protected lexical base can still be a symlink into Containers. Glob expansion must
    /// refuse that ancestor before enumerating its target; otherwise candidate resolution itself
    /// can trigger the Sonoma App Data sheet even though the boundary string looked ordinary.
    func testGlobBaseSymlinkCannotBypassProtectedBoundary() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let target = containers.appendingPathComponent("com.example.Other/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try writeFile(in: target, name: "cache.bin", bytes: 64)
        let alias = support.appendingPathComponent("ContainerAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: containers)
        let rule = VendorRule(
            name: "Aliased Protected Cache",
            category: "common_app_cache",
            paths: [
                PathRule(
                    path: "~/Library/Application Support/ContainerAlias/*",
                    verdict: .safe
                )
            ]
        )

        let result = CommonAppCacheScanner.detect(
            vendors: [rule],
            home: home,
            options: .init(allowsProtectedAppDataAccess: false)
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(
            result.incompletePaths,
            [.init(path: alias.path, reason: .pathIdentityChanged)]
        )
        XCTAssertFalse(result.isComplete)
    }

    func testDetectCanIncludeOnlySafeVerdicts() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let safe = home.appendingPathComponent("Library/Caches/safe", isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Caches/confirm", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        try writeFile(in: safe, name: "a.bin", bytes: 11)
        try writeFile(in: confirm, name: "b.bin", bytes: 22)

        let vendors = [
            VendorRule(
                name: "Mixed",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/safe", verdict: .safe, reason: "safe"),
                    PathRule(path: "~/Library/Caches/confirm", verdict: .confirm, reason: "confirm")
                ]
            )
        ]

        let options = CommonAppCacheScanner.Options(includedVerdicts: [.safe])
        let result = CommonAppCacheScanner.detect(vendors: vendors, home: home, options: options)
        let hits = result.hits
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url.lastPathComponent, "safe")
    }

    func testDetect_sparseCacheUsesSystemStorageUsageAndKeepsLogicalDetail() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent("Library/Caches/com.example.Docker", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sparse = cache.appendingPathComponent("Docker.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data([0x1])))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try handle.close()

        let vendors = [VendorRule(
            name: "Docker Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Docker", verdict: .safe)]
        )]

        let hit = try XCTUnwrap(CommonAppCacheScanner.detect(vendors: vendors, home: home).hits.first)
        XCTAssertEqual(hit.sizeBytes, allocatedSize(of: sparse))
        XCTAssertLessThan(hit.sizeBytes, 64 * 1_024 * 1_024)
        XCTAssertGreaterThan(hit.logicalSizeBytes, 1 * 1_024 * 1_024 * 1_024)
    }

    func testDetect_hardlinkCacheCountsAllocatedAndLogicalBytesOnce() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent("Library/Caches/com.example.Hardlink", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let original = cache.appendingPathComponent("original.bin")
        let linked = cache.appendingPathComponent("linked.bin")
        try Data(repeating: 0x5A, count: 32 * 1_024).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)

        let vendors = [VendorRule(
            name: "Hardlink Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Hardlink", verdict: .safe)]
        )]

        let hit = try XCTUnwrap(CommonAppCacheScanner.detect(vendors: vendors, home: home).hits.first)
        XCTAssertEqual(hit.sizeBytes, allocatedSize(of: original))
        XCTAssertEqual(hit.logicalSizeBytes, 32 * 1_024)
        XCTAssertEqual(hit.entryCount, 2, "目录项统计不应因字节去重而消失")
    }

    /// v2026.07.17 regression: a rule path may itself be a symlink. The scanner must account
    /// for the object Trash would actually move, never follow the alias and advertise the huge
    /// target directory as reclaimable cache space.
    func testDetect_candidateRootSymlinkDoesNotCountTargetSubtree() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let target = home.appendingPathComponent("Documents/Important", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try writeFile(in: target, name: "large-user-data.bin", bytes: 2 * 1_024 * 1_024)

        let alias = caches.appendingPathComponent("com.example.Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let linkAllocatedBytes = allocatedSize(of: alias)
        let targetAllocatedBytes = allocatedSize(of: target.appendingPathComponent("large-user-data.bin"))

        let result = CommonAppCacheScanner.detect(vendors: [
            VendorRule(
                name: "Alias Cache",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/com.example.Alias", verdict: .safe)]
            )
        ], home: home)

        XCTAssertEqual(result.uniqueTotalBytes, max(0, linkAllocatedBytes))
        XCTAssertLessThan(result.uniqueTotalBytes, targetAllocatedBytes)
        if let hit = result.hits.first {
            XCTAssertFalse(hit.isDirectory, "候选根 symlink 不能继承目标目录类型")
            XCTAssertEqual(hit.sizeBytes, linkAllocatedBytes)
            XCTAssertEqual(hit.entryCount, 1)
        }
    }

    /// v2026.07.17 regression: even when a path changes after candidate resolution, the
    /// directory descriptor must still match the frozen dev/inode identity before enumeration.
    func testDetect_openedReplacementDirectoryFailsIdentityFence() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.Cache", isDirectory: true)
        let replacement = home.appendingPathComponent("Documents/Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 4_096)
        try writeFile(in: replacement, name: "private.bin", bytes: 2 * 1_024 * 1_024)

        let result = CommonAppCacheScanner.detect(
            vendors: [VendorRule(
                name: "Identity Fence",
                category: "common_app_cache",
                paths: [PathRule(
                    path: "~/Library/Caches/com.example.Cache",
                    verdict: .safe
                )]
            )],
            home: home,
            options: .default,
            shouldCancel: { false },
            openDirectory: { path in
                path == cache.path
                    ? Darwin.open(replacement.path, O_RDONLY)
                    : Darwin.open(path, O_RDONLY)
            }
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.uniqueTotalBytes, 0)
        XCTAssertTrue(result.incompletePaths.contains(
            .init(path: cache.path, reason: .pathIdentityChanged)
        ))
    }

    /// A safe nested candidate is measured before the confirm parent. Replacing it at the later
    /// parent open boundary must preserve the safe checkpoint but make deletion fail closed.
    func testDetect_laterParentTraversalDetectsNestedCandidateIdentityChange() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Nested", isDirectory: true)
        let replacement = home.appendingPathComponent("Replacement", isDirectory: true)
        let displaced = home.appendingPathComponent("Displaced", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try writeFile(in: child, name: "old-cache.bin", bytes: 4_096)
        try writeFile(in: replacement, name: "replacement.bin", bytes: 64 * 1_024)

        var swapped = false
        let result = CommonAppCacheScanner.detect(
            vendors: [
                VendorRule(
                    name: "Parent",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/Parent", verdict: .confirm)]
                ),
                VendorRule(
                    name: "Nested",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/Parent/Nested", verdict: .safe)]
                ),
            ],
            home: home,
            options: .default,
            shouldCancel: { false },
            openDirectory: { path in
                if path == parent.path, !swapped {
                    swapped = true
                    XCTAssertEqual(Darwin.rename(child.path, displaced.path), 0)
                    XCTAssertEqual(Darwin.rename(replacement.path, child.path), 0)
                }
                return Darwin.open(path, O_RDONLY)
            }
        )

        XCTAssertNotNil(result.hits.first(where: { $0.ruleName == "Parent" }))
        XCTAssertNotNil(result.hits.first(where: { $0.ruleName == "Nested" }),
                        "safe candidate was measured before the later confirm parent mutation")
        XCTAssertTrue(result.incompletePaths.contains(
            .init(path: child.path, reason: .pathIdentityChanged)
        ), "later replacement must still fail the earlier safe row closed for deletion")
    }

    func testPrioritizedCandidates_scanSafeCachesBeforeConfirmReviewPaths() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let review = home.appendingPathComponent("Library/Application Support/ChatApp", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/Browser", isDirectory: true)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let vendors = [
            VendorRule(
                name: "Chat Review",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Application Support/ChatApp",
                             verdict: .confirm,
                             reason: "large review path")
                ]
            ),
            VendorRule(
                name: "Browser Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/Browser",
                             verdict: .safe,
                             reason: "cache")
                ]
            )
        ]

        let candidates = CommonAppCacheScanner.prioritizedCandidates(
            rules: vendors,
            includedVerdicts: [.safe, .confirm],
            homePath: home.path,
            fileManager: .default,
            maxGlobExpansionsPerRule: 128
        )

        XCTAssertEqual(candidates.map(\.rule.name), ["Browser Cache", "Chat Review"])
    }

    func testDetect_entryLimitReturnsPartialHitAndProtectsItsRootFromDeletion() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent("Library/Caches/com.example.Large",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "a.bin", bytes: 31)
        try writeFile(in: cache, name: "b.bin", bytes: 47)

        let vendors = [VendorRule(
            name: "Large Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Large",
                             verdict: .safe,
                             reason: "fixture")]
        )]
        let options = CommonAppCacheScanner.Options(maxEntriesPerPath: 1)

        let result = CommonAppCacheScanner.detect(vendors: vendors, home: home, options: options)

        XCTAssertEqual(result.hits.count, 1, "部分统计仍可用于展示，但绝不能被当成完整证明")
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.incompletePaths.contains(
            .init(path: cache.path, reason: .entryLimitReached)
        ))
        XCTAssertTrue(result.deletionProtectedPaths.contains(cache.standardizedFileURL.path))
    }

    func testDetect_expiredDeadlineProtectsEveryUnscannedCandidate() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cache = home.appendingPathComponent("Library/Caches/com.example.Timeout",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 16)
        let vendors = [VendorRule(
            name: "Timeout Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Timeout", verdict: .safe)]
        )]
        let options = CommonAppCacheScanner.Options(timeoutSeconds: -1)
        let recorder = CommonAppCacheProgressRecorder()

        let result = CommonAppCacheScanner.detect(
            vendors: vendors,
            home: home,
            options: options,
            onProgress: { recorder.append($0) }
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.incompletePaths, [
            .init(path: cache.path, reason: .deadlineExceeded)
        ])
        XCTAssertEqual(recorder.snapshot().last?.terminalOutcome, .partial)
    }

    func testSizeOfPath_openFailureIsExplicitAndNeverLooksComplete() throws {
        let root = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try writeFile(in: root, name: "cache.bin", bytes: 8)

        let stat = CommonAppCacheScanner.sizeOfPath(
            root.path,
            isDirectory: true,
            deadline: Date().addingTimeInterval(5),
            maxEntries: 100,
            openDirectory: { _ in
                errno = EACCES
                return -1
            }
        )

        XCTAssertEqual(stat.bytes, 0)
        XCTAssertEqual(stat.entryCount, 0)
        XCTAssertEqual(stat.incompletePaths, [
            .init(path: root.path, reason: .directoryOpenFailed)
        ])
        XCTAssertFalse(stat.wasCancelled)
    }

    func testDetect_取消是独立终态且不会伪装成空扫描完成() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.Cancelled",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 32)
        let vendors = [VendorRule(
            name: "Cancelled Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Cancelled", verdict: .safe)]
        )]
        let recorder = CommonAppCacheProgressRecorder()

        let result = CommonAppCacheScanner.detect(
            vendors: vendors,
            home: home,
            shouldCancel: { true },
            onProgress: { recorder.append($0) }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.isComplete,
                       "取消后的空 hits 不能被上层解释成真实的空扫描完成态")
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.incompletePaths.isEmpty,
                      "取消不是权限/枚举失败，不应污染删除保护错误语义")
        XCTAssertEqual(recorder.snapshot().last?.terminalOutcome, .cancelled)
    }

    func testSizeOfPath_bulk枚举途中取消会丢弃部分计量() throws {
        let root = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        for index in 0..<64 {
            try writeFile(in: root, name: "entry-\(index).bin", bytes: 8)
        }

        var cancellationChecks = 0
        var cancellationRequested = false
        let stat = CommonAppCacheScanner.sizeOfPath(
            root.path,
            isDirectory: true,
            deadline: Date().addingTimeInterval(5),
            maxEntries: 1_000,
            shouldCancel: {
                if cancellationRequested { return true }
                cancellationChecks += 1
                if cancellationChecks >= 12 { cancellationRequested = true }
                return cancellationRequested
            }
        )

        XCTAssertTrue(stat.wasCancelled)
        XCTAssertEqual(stat.bytes, 0,
                       "取消后的局部字节数不能泄漏成可提交的完整计量")
        XCTAssertEqual(stat.entryCount, 0)
        XCTAssertTrue(stat.incompletePaths.isEmpty,
                      "协作取消不能被 BulkEnumerate 的 stoppedByConsumer 误报为 enumerationFailed")
    }

    /// v2026.07.17 regression: candidate sorting alone is insufficient. A broad confirm parent
    /// must never become the shared-forest owner that opens before its safe descendant.
    func testDetect_safeChildIsOpenedBeforeConfirmParentAndUnionTotalsStayUnique() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/Browser", isDirectory: true)
        let child = parent.appendingPathComponent("GPUCache", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let parentFile = parent.appendingPathComponent("parent.bin")
        let childFile = child.appendingPathComponent("child.bin")
        try Data(repeating: 0xA1, count: 5_000).write(to: parentFile)
        try Data(repeating: 0xB2, count: 7_000).write(to: childFile)
        let parentBytes = allocatedSize(of: parentFile)
        let childBytes = allocatedSize(of: childFile)

        let vendors = [
            VendorRule(
                name: "Browser Review Root",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Browser", verdict: .confirm)]
            ),
            VendorRule(
                name: "Browser Safe GPU Cache",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Browser/GPUCache", verdict: .safe)]
            ),
        ]
        var openCounts: [String: Int] = [:]
        var openOrder: [String] = []
        let recorder = CommonAppCacheProgressRecorder()
        let result = CommonAppCacheScanner.detect(
            vendors: vendors,
            home: home,
            options: .default,
            shouldCancel: { false },
            openDirectory: { path in
                openCounts[path, default: 0] += 1
                openOrder.append(path)
                if path == parent.path {
                    let lastProgress = recorder.snapshot().last
                    XCTAssertEqual(lastProgress?.currentPath, parent.path)
                    XCTAssertEqual(lastProgress?.checkpoint?.hits.map(\.verdict), [.safe])
                    XCTAssertEqual(lastProgress?.pendingPaths, [parent.path])
                }
                return Darwin.open(path, O_RDONLY)
            },
            onProgress: { recorder.append($0) }
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.hits.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: result.hits.map { ($0.ruleName, $0) })
        XCTAssertEqual(byName["Browser Review Root"]?.verdict, .confirm)
        XCTAssertEqual(byName["Browser Review Root"]?.sizeBytes, parentBytes + childBytes,
                       "父行必须保持完整 inclusive subtree 容量")
        XCTAssertEqual(byName["Browser Review Root"]?.entryCount, 3)
        XCTAssertEqual(byName["Browser Safe GPU Cache"]?.verdict, .safe)
        XCTAssertEqual(byName["Browser Safe GPU Cache"]?.sizeBytes, childBytes,
                       "子行仍显示自己的完整 subtree，而不是父行扣减后的残值")
        XCTAssertEqual(byName["Browser Safe GPU Cache"]?.entryCount, 1)
        XCTAssertEqual(result.uniqueTotalBytes, parentBytes + childBytes)
        XCTAssertEqual(result.uniqueLogicalBytes, 12_000)
        XCTAssertEqual(result.uniqueEntryCount, 3)
        XCTAssertEqual(openOrder.first, child.path,
                       "safe 子路径必须在任何 confirm 父路径之前进入同步 open 边界")
        XCTAssertGreaterThan(
            try XCTUnwrap(openOrder.firstIndex(of: parent.path)),
            try XCTUnwrap(openOrder.firstIndex(of: child.path))
        )
        XCTAssertEqual(openCounts[parent.path], 1)
        XCTAssertEqual(openCounts[child.path], 2,
                       "跨 verdict 为保证 safe 优先允许重叠访问，但 union 结果必须去重")
    }

    func testDetect_sameVerdictParentAndChildStillShareOneForestTraversal() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/SameVerdict", isDirectory: true)
        let child = parent.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeFile(in: parent, name: "parent.bin", bytes: 4_096)
        try writeFile(in: child, name: "child.bin", bytes: 4_096)

        var openCounts: [String: Int] = [:]
        let result = CommonAppCacheScanner.detect(
            vendors: [
                VendorRule(
                    name: "Safe Parent",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/SameVerdict", verdict: .safe)]
                ),
                VendorRule(
                    name: "Safe Child",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/SameVerdict/Nested", verdict: .safe)]
                ),
            ],
            home: home,
            options: .default,
            shouldCancel: { false },
            openDirectory: { path in
                openCounts[path, default: 0] += 1
                return Darwin.open(path, O_RDONLY)
            }
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(openCounts[parent.path], 1)
        XCTAssertEqual(openCounts[child.path], 1,
                       "同 verdict 父子候选必须继续共享一次森林遍历")
    }

    func testDetect_progressReportsEveryVerdictGroupAndExplicitTerminalOutcome() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let safe = home.appendingPathComponent("Library/Caches/Safe", isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Caches/Confirm", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        try writeFile(in: safe, name: "safe.bin", bytes: 64)
        try writeFile(in: confirm, name: "confirm.bin", bytes: 64)

        let recorder = CommonAppCacheProgressRecorder()
        let result = CommonAppCacheScanner.detect(
            vendors: [
                VendorRule(
                    name: "Confirm",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/Confirm", verdict: .confirm)]
                ),
                VendorRule(
                    name: "Safe",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/Safe", verdict: .safe)]
                ),
            ],
            home: home,
            onProgress: { recorder.append($0) }
        )

        XCTAssertTrue(result.isComplete)
        let progress = recorder.snapshot()
        XCTAssertEqual(progress.first?.phase, .resolvingCandidates)
        let measuring = progress.filter { $0.phase == .measuringGroups }
        XCTAssertEqual(measuring.map(\.completedGroups), [0, 1, 1, 2])
        XCTAssertEqual(measuring.map(\.totalGroups), [2, 2, 2, 2])
        XCTAssertEqual(measuring[0].currentVerdict, .safe)
        XCTAssertEqual(measuring[1].currentVerdict, .safe)
        XCTAssertEqual(measuring[2].currentVerdict, .confirm)
        XCTAssertEqual(measuring[3].currentVerdict, .confirm)
        XCTAssertEqual(measuring[1].currentPath, safe.standardizedFileURL.path)
        XCTAssertEqual(measuring[2].currentPath, confirm.standardizedFileURL.path)
        XCTAssertEqual(measuring[0].pendingPaths, [safe.path, confirm.path])
        XCTAssertEqual(measuring[1].pendingPaths, [confirm.path])
        XCTAssertEqual(measuring[1].checkpoint?.completedGroupCount, 1)
        XCTAssertEqual(measuring[1].checkpoint?.hits.map(\.verdict), [.safe])
        XCTAssertEqual(measuring[2].checkpoint, measuring[1].checkpoint,
                       "下一组开始事件必须携带上一组的不可变可信 checkpoint")
        XCTAssertEqual(measuring[3].pendingPaths, [])
        XCTAssertEqual(measuring[3].checkpoint?.completedGroupCount, 2)
        XCTAssertEqual(progress.last?.phase, .terminal)
        XCTAssertEqual(progress.last?.terminalOutcome, .complete)
        XCTAssertEqual(progress.last?.completedGroups, 2)
        XCTAssertEqual(progress.last?.totalGroups, 2)
        XCTAssertEqual(progress.last?.pendingPaths, [])
        XCTAssertEqual(progress.last?.checkpoint, measuring[3].checkpoint)
    }

    func testWorkerProtocolPayloads_roundTripThroughCodable() throws {
        let options = CommonAppCacheScanner.Options(
            includedVerdicts: [.safe, .confirm],
            timeoutSeconds: 7.5,
            maxGlobExpansionsPerRule: 17,
            maxEntriesPerPath: 99,
            allowsProtectedAppDataAccess: true,
            excludedCandidatePathPrefixes: ["/tmp/excluded"]
        )
        let encodedOptions = try JSONEncoder().encode(options)
        let decodedOptions = try JSONDecoder().decode(
            CommonAppCacheScanner.Options.self,
            from: encodedOptions
        )
        XCTAssertEqual(decodedOptions.includedVerdicts, options.includedVerdicts)
        XCTAssertEqual(decodedOptions.timeoutSeconds, options.timeoutSeconds)
        XCTAssertEqual(decodedOptions.maxGlobExpansionsPerRule, options.maxGlobExpansionsPerRule)
        XCTAssertEqual(decodedOptions.maxEntriesPerPath, options.maxEntriesPerPath)
        XCTAssertEqual(
            decodedOptions.allowsProtectedAppDataAccess,
            options.allowsProtectedAppDataAccess
        )
        XCTAssertEqual(decodedOptions.excludedCandidatePathPrefixes,
                       options.excludedCandidatePathPrefixes)

        let hit = CommonAppCacheScanner.Hit(
            ruleName: "Fixture",
            bundleIDPrefix: "com.example",
            source: "test",
            url: URL(fileURLWithPath: "/tmp/cache"),
            isDirectory: true,
            verdict: .safe,
            reason: "cache",
            sizeBytes: 4096,
            logicalSizeBytes: 2048,
            entryCount: 3
        )
        let incomplete: [CommonAppCacheScanner.IncompletePath] = [
            .init(path: "/tmp/pending", reason: .deadlineExceeded),
            .init(path: "/tmp/launch", reason: .workerLaunchFailed),
            .init(path: "/tmp/protocol", reason: .workerProtocolFailed),
            .init(path: "/tmp/app-data", reason: .protectedAppDataSkipped),
        ]
        let checkpoint = CommonAppCacheScanner.Checkpoint(
            hits: [hit],
            incompletePaths: incomplete,
            uniqueTotalBytes: 4096,
            uniqueLogicalBytes: 2048,
            uniqueEntryCount: 3,
            completedGroupCount: 1
        )
        let progress = CommonAppCacheScanner.Progress(
            phase: .measuringGroups,
            completedGroups: 1,
            totalGroups: 2,
            currentVerdict: .confirm,
            currentPath: "/tmp/current",
            checkpoint: checkpoint,
            pendingPaths: ["/tmp/current"]
        )
        let decodedProgress = try JSONDecoder().decode(
            CommonAppCacheScanner.Progress.self,
            from: JSONEncoder().encode(progress)
        )
        XCTAssertEqual(decodedProgress, progress)

        let result = checkpoint.scanResult
        let decodedResult = try JSONDecoder().decode(
            CommonAppCacheScanner.ScanResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decodedResult.hits, [hit])
        XCTAssertEqual(decodedResult.incompletePaths, incomplete)
        XCTAssertEqual(decodedResult.uniqueTotalBytes, 4096)
        XCTAssertEqual(decodedResult.uniqueLogicalBytes, 2048)
        XCTAssertEqual(decodedResult.uniqueEntryCount, 3)
        XCTAssertFalse(decodedResult.wasCancelled)
    }

    func testDetect_hardlinkAcrossParentChildBoundaryHasIndependentRowsAndUniqueUnion() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/HardlinkApp", isDirectory: true)
        let child = parent.appendingPathComponent("SafeChild", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let original = parent.appendingPathComponent("shared.bin")
        let childLink = child.appendingPathComponent("shared-link.bin")
        try Data(repeating: 0xCC, count: 9_000).write(to: original)
        XCTAssertEqual(Darwin.link(original.path, childLink.path), 0)
        let allocated = allocatedSize(of: original)

        let result = CommonAppCacheScanner.detect(vendors: [
            VendorRule(
                name: "Parent",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/HardlinkApp", verdict: .confirm)]
            ),
            VendorRule(
                name: "Child",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/HardlinkApp/SafeChild", verdict: .safe)]
            ),
        ], home: home)

        let byName = Dictionary(uniqueKeysWithValues: result.hits.map { ($0.ruleName, $0) })
        XCTAssertEqual(byName["Parent"]?.sizeBytes, allocated,
                       "父候选必须在自己的完整 subtree 内按 inode 去重")
        XCTAssertEqual(byName["Child"]?.sizeBytes, allocated,
                       "子候选拥有独立 inode 语义，不能被父候选先见顺序归零")
        XCTAssertEqual(result.uniqueTotalBytes, allocated,
                       "跨候选路径并集只能计一次 hardlink 的物理容量")
        XCTAssertEqual(result.uniqueLogicalBytes, 9_000)
        XCTAssertEqual(result.uniqueEntryCount, 3,
                       "目录项数量按路径唯一；两个 hardlink 名称仍是两个 entry")
    }

    func testDetect_exactDuplicatePathUsesHighestPriorityRuleAndOpensOnce() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/Duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeFile(in: cache, name: "cache.bin", bytes: 4_096)

        let vendors = [
            VendorRule(
                name: "Confirm Duplicate",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Duplicate", verdict: .confirm)]
            ),
            VendorRule(
                name: "Safe Duplicate",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Duplicate", verdict: .safe)]
            ),
        ]
        var opens = 0
        let result = CommonAppCacheScanner.detect(
            vendors: vendors,
            home: home,
            options: .default,
            shouldCancel: { false },
            openDirectory: { path in
                if path == cache.path { opens += 1 }
                return Darwin.open(path, O_RDONLY)
            }
        )

        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits.first?.ruleName, "Safe Duplicate")
        XCTAssertEqual(result.hits.first?.verdict, .safe)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(result.uniqueTotalBytes, result.hits.first?.sizeBytes)
        XCTAssertEqual(result.uniqueEntryCount, 1)
    }

    func testDetect_sharedForestEntryLimitsRemainPerCandidate() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/Limited", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeFile(in: child, name: "a.bin", bytes: 4_096)
        try writeFile(in: child, name: "b.bin", bytes: 4_096)
        let options = CommonAppCacheScanner.Options(maxEntriesPerPath: 1)

        let result = CommonAppCacheScanner.detect(vendors: [
            VendorRule(
                name: "Limited Parent",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Limited", verdict: .confirm)]
            ),
            VendorRule(
                name: "Limited Child",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Limited/Child", verdict: .safe)]
            ),
        ], home: home, options: options)

        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.incompletePaths.contains(
            .init(path: parent.path, reason: .entryLimitReached)
        ))
        XCTAssertTrue(result.incompletePaths.contains(
            .init(path: child.path, reason: .entryLimitReached)
        ))
        XCTAssertLessThanOrEqual(result.hits.first(where: { $0.ruleName == "Limited Child" })?.entryCount ?? 0, 1)
        XCTAssertLessThanOrEqual(result.uniqueTotalBytes,
                                 result.hits.reduce(0) { $0 &+ $1.sizeBytes })
    }

    func testDetect_sharedForestCancellationDiscardsRowsAndUniqueTotals() throws {
        let home = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/CancelledForest", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for index in 0..<128 {
            try writeFile(in: child, name: "\(index).bin", bytes: 32)
        }

        var didOpenDirectory = false
        var checksAfterOpen = 0
        let result = CommonAppCacheScanner.detect(
            vendors: [
                VendorRule(
                    name: "Parent",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/CancelledForest", verdict: .confirm)]
                ),
                VendorRule(
                    name: "Child",
                    category: "common_app_cache",
                    paths: [PathRule(path: "~/Library/Caches/CancelledForest/Child", verdict: .safe)]
                ),
            ],
            home: home,
            options: .default,
            shouldCancel: {
                guard didOpenDirectory else { return false }
                checksAfterOpen += 1
                return checksAfterOpen >= 6
            },
            openDirectory: { path in
                didOpenDirectory = true
                return Darwin.open(path, O_RDONLY)
            }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.uniqueTotalBytes, 0)
        XCTAssertEqual(result.uniqueLogicalBytes, 0)
        XCTAssertEqual(result.uniqueEntryCount, 0)
        XCTAssertTrue(result.incompletePaths.isEmpty)
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CommonAppCacheScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(in dir: URL, name: String, bytes: Int) throws {
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: dir.appendingPathComponent(name))
    }

    private func allocatedSize(of url: URL) -> Int64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return -1 }
        return Int64(metadata.st_blocks) * 512
    }
}

private final class CommonAppCacheProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CommonAppCacheScanner.Progress] = []

    func append(_ progress: CommonAppCacheScanner.Progress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    func snapshot() -> [CommonAppCacheScanner.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
