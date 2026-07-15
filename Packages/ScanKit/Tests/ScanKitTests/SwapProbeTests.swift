import XCTest
@testable import ScanKit

/// v1.3.x：SwapProbe 行为测试。
/// 重点 cover **解析逻辑** + **物理目录扫描兜底**。
/// 内核 sysctl 在 CI 上的真实数值不可断言，只在 probe() 集成路径里做"非负 + 不抛错"宽松检查。
final class SwapProbeTests: XCTestCase {

    // MARK: - parseSwapUsage：解析 sysctl 字符串

    func test_parse_典型字符串_应正确拆分_total_used_free() {
        let raw = "total = 26624.00M  used = 25589.44M  free = 1034.56M  (encrypted)"
        let parsed = SwapProbe.parseSwapUsage(raw)
        XCTAssertEqual(parsed.total, Int64(26624.00 * 1024 * 1024), "total 26624 MiB")
        XCTAssertEqual(parsed.used, Int64(25589.44 * 1024 * 1024), "used 25589.44 MiB")
        XCTAssertEqual(parsed.free, Int64(1034.56 * 1024 * 1024), "free 1034.56 MiB")
        XCTAssertTrue(parsed.encrypted, "(encrypted) 标签应被识别")
    }

    func test_parse_未加密标签_encrypted应为false() {
        let raw = "total = 1024.00M  used = 256.00M  free = 768.00M"
        let parsed = SwapProbe.parseSwapUsage(raw)
        XCTAssertFalse(parsed.encrypted)
        XCTAssertEqual(parsed.total, 1024 * 1024 * 1024)
    }

    func test_parse_空字符串_应全部为0() {
        let parsed = SwapProbe.parseSwapUsage("")
        XCTAssertEqual(parsed.total, 0)
        XCTAssertEqual(parsed.used, 0)
        XCTAssertEqual(parsed.free, 0)
        XCTAssertFalse(parsed.encrypted)
    }

    func test_parse_乱序与多空格_应稳健() {
        let raw = "free=512.00M  total=2048.00M    used = 1536.00M"
        let parsed = SwapProbe.parseSwapUsage(raw)
        XCTAssertEqual(parsed.total, Int64(2048) * 1024 * 1024)
        XCTAssertEqual(parsed.used, Int64(1536) * 1024 * 1024)
        XCTAssertEqual(parsed.free, Int64(512) * 1024 * 1024)
    }

    func test_parse_K单位与G单位_应正确换算() {
        let raw = "total = 2.00G  used = 512.00K  free = 1.00G"
        let parsed = SwapProbe.parseSwapUsage(raw)
        XCTAssertEqual(parsed.total, Int64(2) * 1024 * 1024 * 1024)
        XCTAssertEqual(parsed.used, Int64(512) * 1024)
        XCTAssertEqual(parsed.free, Int64(1) * 1024 * 1024 * 1024)
    }

    // MARK: - sumSwapFiles / sleepImageSize：临时目录隔离测试

    func test_sumSwapFiles_遍历临时目录_应只累加swapfile前缀文件() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 制造 swapfile0 (1KB), swapfile1 (2KB), other.bin (10KB), .DS_Store (1B)
        let swap0 = try writeFile(in: tmp, name: "swapfile0", bytes: 1024)
        let swap1 = try writeFile(in: tmp, name: "swapfile1", bytes: 2048)
        try writeFile(in: tmp, name: "other.bin", bytes: 10_240)
        try writeFile(in: tmp, name: ".DS_Store", bytes: 1)

        let (total, count) = SwapProbe.sumSwapFiles(in: tmp.path)
        XCTAssertEqual(count, 2, "只应数出 swapfile0/1 两个")
        XCTAssertEqual(total, allocatedSize(of: swap0) + allocatedSize(of: swap1), "swapfile 磁盘占用累加")
    }

    func test_sumSwapFiles_目录不存在_应回退为0() {
        let (total, count) = SwapProbe.sumSwapFiles(in: "/this/path/never/exists/zzz")
        XCTAssertEqual(total, 0)
        XCTAssertEqual(count, 0)
    }

    func test_sleepImageSize_存在文件_应返回字节数() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sleepImage = try writeFile(in: tmp, name: "sleepimage", bytes: 4096)

        XCTAssertEqual(SwapProbe.sleepImageSize(in: tmp.path), allocatedSize(of: sleepImage))
    }

    func test_sleepImageSize_不存在_应返回0() {
        let path = "/this/path/never/exists/zzz"
        XCTAssertEqual(SwapProbe.sleepImageSize(in: path), 0)
    }

    // MARK: - probe 集成

    func test_probe_自定义vmDirectory_swapfile与sleepimage应组合在totalDiskFootprint() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let swap = try writeFile(in: tmp, name: "swapfile0", bytes: 4096)
        let sleepImage = try writeFile(in: tmp, name: "sleepimage", bytes: 8192)

        let snap = SwapProbe.probe(vmDirectory: tmp.path)
        XCTAssertEqual(snap.swapFileBytesOnDisk, allocatedSize(of: swap))
        XCTAssertEqual(snap.swapFileCount, 1)
        XCTAssertEqual(snap.sleepImageBytes, allocatedSize(of: sleepImage))
        XCTAssertEqual(snap.totalDiskFootprintBytes,
                       allocatedSize(of: swap) + allocatedSize(of: sleepImage))
        XCTAssertTrue(snap.diskFootprintAvailable)

        // sysctl 在 CI/真机 都不抛错；数值非负即可
        XCTAssertGreaterThanOrEqual(snap.swapTotalBytes, 0)
        XCTAssertGreaterThanOrEqual(snap.swapUsedBytes, 0)
        XCTAssertGreaterThanOrEqual(snap.swapFreeBytes, 0)
    }

    func test_Snapshot_diskFootprintAvailable_全为0时为false() {
        // 注意：v1.3.x review-fix 后，swapDiskBytes 会回退到 swapTotalBytes，
        // 所以 swapTotal=0 + swapFile=0 + sleepimage=0 才是"全 0"。
        let s = SwapProbe.Snapshot(
            swapTotalBytes: 0, swapUsedBytes: 0, swapFreeBytes: 0, encrypted: false,
            swapFileBytesOnDisk: 0, swapFileCount: 0, sleepImageBytes: 0
        )
        XCTAssertFalse(s.diskFootprintAvailable)
        XCTAssertEqual(s.totalDiskFootprintBytes, 0)
        XCTAssertFalse(s.swapFileSizeMeasured)
    }

    /// v1.3.x review-fix 用例：用户反馈"虚拟内存只有 2 GB，刚刚还有 50G"——
    /// 因为 SIP 让 App 列不到 /private/var/vm 下的 swapfile（fileCount=0），
    /// 这时必须回退用 sysctl total 而不是 0。
    func test_Snapshot_读不到swapfile时_swapDiskBytes应回退到sysctlTotal() {
        let s = SwapProbe.Snapshot(
            swapTotalBytes: 26 * 1024 * 1024 * 1024, // 26 GiB sysctl total
            swapUsedBytes: 25 * 1024 * 1024 * 1024,
            swapFreeBytes: 1 * 1024 * 1024 * 1024,
            encrypted: true,
            swapFileBytesOnDisk: 0,  // SIP 阻挡 → 读不到任何 swapfile
            swapFileCount: 0,
            sleepImageBytes: 2 * 1024 * 1024 * 1024 // 2 GiB sleepimage
        )
        XCTAssertEqual(s.swapDiskBytes, 26 * 1024 * 1024 * 1024,
                       "读不到 swapfile 时必须回退到 sysctl total")
        XCTAssertEqual(s.totalDiskFootprintBytes, 28 * 1024 * 1024 * 1024,
                       "= 26 (swap 估算) + 2 (sleepimage)")
        XCTAssertTrue(s.diskFootprintAvailable)
        XCTAssertFalse(s.swapFileSizeMeasured, "未真实测量到文件大小")
    }

    /// 真实测量到 swapfile 时优先使用文件大小（即使 sysctl total 更大也以文件为准）。
    func test_Snapshot_测到swapfile时_swapDiskBytes应优先用文件大小() {
        let s = SwapProbe.Snapshot(
            swapTotalBytes: 26 * 1024 * 1024 * 1024,
            swapUsedBytes: 1024,
            swapFreeBytes: 26 * 1024 * 1024 * 1024 - 1024,
            encrypted: true,
            swapFileBytesOnDisk: 24 * 1024 * 1024 * 1024,
            swapFileCount: 24,
            sleepImageBytes: 2 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(s.swapDiskBytes, 24 * 1024 * 1024 * 1024,
                       "测到文件大小时以文件为准")
        XCTAssertTrue(s.swapFileSizeMeasured)
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwapProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(in dir: URL, name: String, bytes: Int) throws -> URL {
        let data = Data(repeating: 0xAB, count: bytes)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func allocatedSize(of url: URL) -> Int64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return -1 }
        return Int64(metadata.st_blocks) * 512
    }
}
