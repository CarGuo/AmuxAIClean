import XCTest
@testable import ScanKit

final class InodeSetTests: XCTestCase {
    func testFirstSeenReturnsTrueOnlyOnce() {
        let set = InodeSet()
        XCTAssertTrue(set.insertIfFirstSeen(device: 1, inode: 100))
        XCTAssertFalse(set.insertIfFirstSeen(device: 1, inode: 100))
        XCTAssertTrue(set.insertIfFirstSeen(device: 2, inode: 100)) // 不同设备同 inode 也算独立
        XCTAssertEqual(set.count, 2)
    }
}

final class FirmlinksTests: XCTestCase {
    func testRecommendedDataVolumeRoot() {
        XCTAssertEqual(Firmlinks.recommendedDataVolumeRoot.path, "/System/Volumes/Data")
    }

    func testLoadDoesNotCrashOnMissingFile() {
        let result = Firmlinks.load(from: "/path/that/definitely/does/not/exist")
        XCTAssertTrue(result.isEmpty)
    }
}

final class ScannerSmokeTests: XCTestCase {
    /// 烟囱测试：扫描临时目录，能拿到 finished 事件且字节数非负。
    func testScanTempDirectoryProducesSummary() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 写一个 1KB 文件
        let file = tmp.appendingPathComponent("sample.bin")
        try Data(count: 1024).write(to: file)

        let scanner = ScanKit.Scanner()
        var summary: ScanSummary?
        for await event in scanner.scan(root: tmp) {
            if case let .finished(s) = event { summary = s; break }
        }
        XCTAssertNotNil(summary)
        XCTAssertGreaterThanOrEqual(summary!.totalAllocatedBytes, 0)
        XCTAssertGreaterThanOrEqual(summary!.fileCount, 1)
    }

    /// BulkScanner 烟囱测试：扫同样的 1KB 临时文件，必须能拿到 finished 且 fileCount >= 1。
    func testBulkScannerProducesSummary() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("sample.bin")
        try Data(count: 1024).write(to: file)

        let scanner = BulkScanner()
        var summary: ScanSummary?
        for await event in scanner.scan(root: tmp) {
            if case let .finished(s) = event { summary = s; break }
        }
        XCTAssertNotNil(summary)
        XCTAssertGreaterThanOrEqual(summary!.fileCount, 1)
        XCTAssertGreaterThanOrEqual(summary!.totalAllocatedBytes, 0)
    }
}
