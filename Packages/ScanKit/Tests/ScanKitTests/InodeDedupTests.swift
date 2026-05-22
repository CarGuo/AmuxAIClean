import XCTest
import Darwin
@testable import ScanKit

/// 硬链接 inode 去重测试。
///
/// 通过 `link(2)` 系统调用构造真硬链接（与 APFS clone 不同，硬链接共用同一 inode），
/// 验证 `dedupByInode` 配置项在 BulkScanner / Scanner 两条路径上都能正确"只算一份"。
final class InodeDedupTests: XCTestCase {

    /// 单个文件的逻辑大小（字节）。
    private let 文件字节数 = 4096

    /// 创建临时目录并写入 a.bin（4096B），随后通过 `link(2)` 创建硬链接 b.bin。
    /// 返回临时目录 URL；调用方负责清理。
    private func 准备硬链接目录() throws -> URL {
        let 临时目录 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-inode-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: 临时目录, withIntermediateDirectories: true)

        // 写入 4096 字节的源文件
        let 源文件 = 临时目录.appendingPathComponent("a.bin")
        try Data(count: 文件字节数).write(to: 源文件)

        // Darwin link(2)：创建硬链接 b.bin → a.bin（指向同一 inode）
        let 链接文件 = 临时目录.appendingPathComponent("b.bin")
        let 链接结果 = 源文件.path.withCString { 源指针 in
            链接文件.path.withCString { 目标指针 in
                link(源指针, 目标指针)
            }
        }
        XCTAssertEqual(链接结果, 0, "link(2) 调用失败，errno=\(errno)")

        // 校验确实是硬链接：两个路径的 inode 应该一致，且 nlink >= 2
        var 状态 = stat()
        XCTAssertEqual(lstat(源文件.path, &状态), 0)
        let 源inode = 状态.st_ino
        let 链接数 = 状态.st_nlink
        XCTAssertEqual(lstat(链接文件.path, &状态), 0)
        XCTAssertEqual(状态.st_ino, 源inode, "硬链接两端 inode 必须一致")
        XCTAssertGreaterThanOrEqual(链接数, 2, "源文件 nlink 应 >= 2")

        return 临时目录
    }

    /// 收集 AsyncStream 直至 finished 事件，返回 ScanSummary。
    private func 收集汇总<S: AsyncSequence>(_ 流: S) async throws -> ScanSummary? where S.Element == ScanEvent {
        for try await 事件 in 流 {
            if case let .finished(汇总) = 事件 { return 汇总 }
        }
        return nil
    }

    // MARK: - 用例 1：BulkScanner 默认开启去重

    /// BulkScanner 默认 dedupByInode=true：只应统计一份字节，且 dedupedHardlinkBytes > 0。
    func test_BulkScanner默认去重_只计一份字节() async throws {
        let 目录 = try 准备硬链接目录()
        defer { try? FileManager.default.removeItem(at: 目录) }

        let 扫描器 = BulkScanner() // 默认 ScanOptions：dedupByInode = true
        guard let 汇总 = try await 收集汇总(扫描器.scan(root: 目录)) else {
            return XCTFail("未收到 finished 事件")
        }

        // 文件计数仍是 2（两个目录项），但去重后字节只算一份
        XCTAssertEqual(汇总.fileCount, 2, "两个目录项都应被遍历到")

        // 4096 字节文件在 APFS 上分配大小通常等于 4096，但理论上可能因块大小略有差异；
        // 用区间断言放宽：必须在 [文件字节数, 文件字节数 * 2) 之间，明显小于不去重的两份。
        XCTAssertGreaterThanOrEqual(汇总.totalAllocatedBytes, Int64(文件字节数))
        XCTAssertLessThan(汇总.totalAllocatedBytes, Int64(文件字节数 * 2),
                          "默认去重时不应同时累加两份")

        // 被去重抹掉的字节应当 > 0
        XCTAssertGreaterThan(汇总.dedupedHardlinkBytes, 0, "硬链接去重必须记录 dedupedHardlinkBytes")
    }

    // MARK: - 用例 2：BulkScanner 关闭去重

    /// BulkScanner dedupByInode=false：硬链接被算两份，totalAllocatedBytes 接近 8192。
    func test_BulkScanner关闭去重_累加两份字节() async throws {
        let 目录 = try 准备硬链接目录()
        defer { try? FileManager.default.removeItem(at: 目录) }

        // 关闭 inode 去重
        let 选项 = ScanOptions(dedupByInode: false)
        let 扫描器 = BulkScanner(options: 选项)
        guard let 汇总 = try await 收集汇总(扫描器.scan(root: 目录)) else {
            return XCTFail("未收到 finished 事件")
        }

        XCTAssertEqual(汇总.fileCount, 2)

        // 关闭去重时两个目录项的 allocatedSize 都被累加，应当 >= 2 * 4096
        XCTAssertGreaterThanOrEqual(汇总.totalAllocatedBytes, Int64(文件字节数 * 2),
                                    "关闭去重时应累加两份字节")

        // 不去重路径不会写 dedupedHardlinkBytes
        XCTAssertEqual(汇总.dedupedHardlinkBytes, 0)
    }

    // MARK: - 用例 3：Scanner（FileManager 路径）同样验证去重

    /// Scanner 默认 dedupByInode=true 时同样应只算一份字节，关闭后翻倍——证明两条扫描路径行为一致。
    func test_Scanner路径去重一致性() async throws {
        let 目录 = try 准备硬链接目录()
        defer { try? FileManager.default.removeItem(at: 目录) }

        // 默认去重：只算一份
        let 默认扫描器 = ScanKit.Scanner()
        guard let 默认汇总 = try await 收集汇总(默认扫描器.scan(root: 目录)) else {
            return XCTFail("Scanner 默认路径未收到 finished")
        }
        XCTAssertEqual(默认汇总.fileCount, 2)
        XCTAssertGreaterThanOrEqual(默认汇总.totalAllocatedBytes, Int64(文件字节数))
        XCTAssertLessThan(默认汇总.totalAllocatedBytes, Int64(文件字节数 * 2),
                          "Scanner 默认去重也应只算一份")
        XCTAssertGreaterThan(默认汇总.dedupedHardlinkBytes, 0)

        // 关闭去重：算两份
        let 关闭扫描器 = ScanKit.Scanner(options: ScanOptions(dedupByInode: false))
        guard let 关闭汇总 = try await 收集汇总(关闭扫描器.scan(root: 目录)) else {
            return XCTFail("Scanner 关闭去重路径未收到 finished")
        }
        XCTAssertEqual(关闭汇总.fileCount, 2)
        XCTAssertGreaterThanOrEqual(关闭汇总.totalAllocatedBytes, Int64(文件字节数 * 2),
                                    "Scanner 关闭去重应累加两份")
        XCTAssertEqual(关闭汇总.dedupedHardlinkBytes, 0)

        // 进一步验证：关闭去重 > 默认去重
        XCTAssertGreaterThan(关闭汇总.totalAllocatedBytes, 默认汇总.totalAllocatedBytes,
                             "关闭去重时累计字节应严格大于默认去重")
    }
}
