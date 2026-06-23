import SafetyKit
import XCTest
@testable import ScanKit

final class CommonAppCacheScannerTests: XCTestCase {

    func testDetectReturnsOnlyExistingNonEmptyIncludedRules() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

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

        let hits = CommonAppCacheScanner.detect(vendors: vendors, home: home)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].ruleName, "WeChat Cache")
        XCTAssertEqual(hits[0].bundleIDPrefix, "com.tencent.xinWeChat")
        XCTAssertEqual(hits[0].verdict, .safe)
        XCTAssertEqual(hits[0].sizeBytes, 128)
        XCTAssertEqual(hits[0].entryCount, 1)
        XCTAssertTrue(hits[0].isDirectory)
    }

    func testDetectExpandsBoundedGlobRules() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

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

        let hits = CommonAppCacheScanner.detect(vendors: vendors, home: home)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url.lastPathComponent, "com.example.App")
        XCTAssertEqual(hits[0].sizeBytes, 256)
    }

    func testDetectCanIncludeOnlySafeVerdicts() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

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
        let hits = CommonAppCacheScanner.detect(vendors: vendors, home: home, options: options)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url.lastPathComponent, "safe")
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
}
