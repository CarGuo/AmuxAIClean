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

        let result = CommonAppCacheScanner.detect(vendors: vendors, home: home, options: options)

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.incompletePaths, [
            .init(path: cache.path, reason: .deadlineExceeded)
        ])
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

        let result = CommonAppCacheScanner.detect(
            vendors: vendors,
            home: home,
            shouldCancel: { true }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.isComplete,
                       "取消后的空 hits 不能被上层解释成真实的空扫描完成态")
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.incompletePaths.isEmpty,
                      "取消不是权限/枚举失败，不应污染删除保护错误语义")
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
