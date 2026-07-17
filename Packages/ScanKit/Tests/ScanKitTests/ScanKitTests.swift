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

    /// v2026.07.17：MultiRoot transaction 会让多个 root/worker 并发声明同一 inode。
    /// 分片锁只能降低无关 key 的竞争，绝不能让“首次观察”出现多个 winner。
    func testConcurrentInsertHasExactlyOneWinnerPerIdentity() {
        let set = InodeSet()
        let winners = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if set.insertIfFirstSeen(device: 7, inode: 42) {
                winners.increment()
            }
        }

        XCTAssertEqual(winners.value, 1)
        XCTAssertEqual(set.count, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
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
