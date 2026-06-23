import SafetyKit
import XCTest
@testable import AppUI

@MainActor
final class ScanCoordinatorCommonAppCacheTests: XCTestCase {

    func test_scanCommonAppCaches_publishesOnlyExistingNonEmptyRuleHits() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let wechat = home.appendingPathComponent("Library/Caches/com.tencent.xinWeChat",
                                                 isDirectory: true)
        let empty = home.appendingPathComponent("Library/Caches/com.empty.App",
                                                isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Application Support/Zoom/data/VirtualBkgnd_Custom",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: wechat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 128).write(to: wechat.appendingPathComponent("cache.bin"))
        try Data(repeating: 0xCD, count: 256).write(to: confirm.appendingPathComponent("background.bin"))

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
                name: "Zoom Virtual Backgrounds",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Application Support/Zoom/data/VirtualBkgnd_Custom",
                             verdict: .confirm,
                             reason: "user-selected backgrounds")
                ]
            ),
            VendorRule(
                name: "Blocked Neighbor",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .forbid,
                             reason: "blocked")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.categoryID, ScanCoordinator.commonAppCacheCategoryID)
        XCTAssertEqual(coord.currentRootPath, ScanCoordinator.commonAppCacheSentinelPath)
        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertFalse(coord.isScanning)
        XCTAssertNil(coord.activeCategoryID)
        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Zoom Virtual Backgrounds", "WeChat Cache"])
        XCTAssertEqual(coord.snapshot.totalBytes, 384)
        XCTAssertEqual(coord.snapshot.scannedFileCount, 2)

        let verdicts = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.verdict) })
        XCTAssertEqual(verdicts["WeChat Cache"], .safe)
        XCTAssertEqual(verdicts["Zoom Virtual Backgrounds"], .confirm)
        let prefixes = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.runningBundleIDPrefix) })
        XCTAssertEqual(prefixes["WeChat Cache"]!, "com.tencent.xinWeChat")
        XCTAssertEqual(coord.snapshot.safeBytes, 128)
        XCTAssertEqual(coord.snapshot.confirmBytes, 256)
    }

    func test_scanCommonAppCaches_canExcludeConfirmRules() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let safe = home.appendingPathComponent("Library/Caches/safe", isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Caches/confirm", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 11).write(to: safe.appendingPathComponent("a.bin"))
        try Data(repeating: 0xBB, count: 22).write(to: confirm.appendingPathComponent("b.bin"))

        let vendors = [
            VendorRule(
                name: "Safe Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/safe", verdict: .safe, reason: "safe")
                ]
            ),
            VendorRule(
                name: "Confirm Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/confirm", verdict: .confirm, reason: "confirm")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.scanCommonAppCaches(includeConfirm: false)
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Safe Cache"])
        XCTAssertEqual(coord.snapshot.totalBytes, 11)
        XCTAssertEqual(coord.snapshot.confirmBytes, 0)
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorCommonAppCache-\(UUID().uuidString)",
                                    isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitScanFinished(_ coord: ScanCoordinator,
                                  timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (coord.isScanning || !coord.snapshot.isFinished) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
