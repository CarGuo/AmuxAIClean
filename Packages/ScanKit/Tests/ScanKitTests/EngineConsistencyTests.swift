import XCTest
@testable import ScanKit

/// 双引擎一致性测试：保证 `ScanKit.Scanner`（FileManager 路径）与
/// `BulkScanner`（getattrlistbulk 路径）在同一棵目录树上得到等价的统计结果。
///
/// 这一类测试是回归网，任何一边的实现走偏都会被立刻揪出来。
final class EngineConsistencyTests: XCTestCase {

    // MARK: - Fixture

    /// 在临时目录里搭出题面要求的固定结构：
    /// ```
    /// tmp/
    ///   a.bin (1024)
    ///   b.bin (2048)
    ///   sub/
    ///     c.bin (512)
    ///     d.bin (256)
    /// ```
    /// 返回根目录 URL；调用方负责清理。
    private func 构造基础Fixture() throws -> URL {
        let 根 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-consistency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: 根, withIntermediateDirectories: true)

        // 顶层两个文件
        try Data(count: 1024).write(to: 根.appendingPathComponent("a.bin"))
        try Data(count: 2048).write(to: 根.appendingPathComponent("b.bin"))

        // 子目录 sub 及内部文件
        let sub = 根.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 512).write(to: sub.appendingPathComponent("c.bin"))
        try Data(count: 256).write(to: sub.appendingPathComponent("d.bin"))

        return 根
    }

    /// 收敛 AsyncStream 直到拿到 `.finished`，返回 `ScanSummary`。
    private func 收集Summary(from stream: AsyncStream<ScanEvent>) async -> ScanSummary? {
        for await event in stream {
            if case let .finished(s) = event { return s }
        }
        return nil
    }

    // MARK: - 用例 1：基础目录树一致性

    /// 同一棵目录树下，两个引擎应当给出等价的 fileCount / directoryCount，
    /// 以及在一个 block 对齐误差范围内的 totalAllocatedBytes。
    func test_两引擎在同一目录下统计结果应一致() async throws {
        let 根 = try 构造基础Fixture()
        defer { try? FileManager.default.removeItem(at: 根) }

        let scannerSummary = await 收集Summary(from: ScanKit.Scanner().scan(root: 根))
        let bulkSummary = await 收集Summary(from: BulkScanner().scan(root: 根))

        let s = try XCTUnwrap(scannerSummary, "Scanner 未产生 finished 事件")
        let b = try XCTUnwrap(bulkSummary, "BulkScanner 未产生 finished 事件")

        // (1) 文件数一致：a.bin / b.bin / sub/c.bin / sub/d.bin = 4
        XCTAssertEqual(s.fileCount, b.fileCount, "两引擎 fileCount 应相等")
        XCTAssertEqual(s.fileCount, 4, "fixture 共有 4 个常规文件")

        // (3) 目录数一致：sub（root 本身两边都不计）
        XCTAssertEqual(s.directoryCount, b.directoryCount, "两引擎 directoryCount 应相等")

        // (2) 物理占用差额 <= 4096：APFS block 对齐 / metadata 计入差异允许范围
        let 差额 = abs(s.totalAllocatedBytes - b.totalAllocatedBytes)
        XCTAssertLessThanOrEqual(差额, 4096,
            "totalAllocatedBytes 差额超出一个 block：scanner=\(s.totalAllocatedBytes) bulk=\(b.totalAllocatedBytes)")
    }

    // MARK: - 用例 2：symlink 场景下 followSymlinks=false 不重复计字节

    /// 在基础 fixture 上加一个 `sub2/link -> a.bin` 的符号链接：
    /// 当 `followSymlinks=false`（默认）时，两个引擎都不应该把 a.bin 的 1024 字节再算一次。
    func test_软链接场景下两引擎都不应重复计字节() async throws {
        let 根 = try 构造基础Fixture()
        defer { try? FileManager.default.removeItem(at: 根) }

        // 加一层 sub2 + 一个指向 a.bin 的 symlink
        let sub2 = 根.appendingPathComponent("sub2", isDirectory: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        let link = sub2.appendingPathComponent("link")
        let target = 根.appendingPathComponent("a.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // 先扫一遍"无 symlink"的基线（重新构造一个等价 fixture，避免与本用例的 sub2 混在一起）
        let 基线根 = try 构造基础Fixture()
        defer { try? FileManager.default.removeItem(at: 基线根) }

        // 显式声明 followSymlinks=false（其实就是默认值）
        let options = ScanOptions(followSymlinks: false)

        let 基线Scanner = await 收集Summary(from: ScanKit.Scanner(options: options).scan(root: 基线根))
        let 基线Bulk = await 收集Summary(from: BulkScanner(options: options).scan(root: 基线根))
        let 含链Scanner = await 收集Summary(from: ScanKit.Scanner(options: options).scan(root: 根))
        let 含链Bulk = await 收集Summary(from: BulkScanner(options: options).scan(root: 根))

        let bs = try XCTUnwrap(基线Scanner)
        let bb = try XCTUnwrap(基线Bulk)
        let cs = try XCTUnwrap(含链Scanner)
        let cb = try XCTUnwrap(含链Bulk)

        // 关键断言：含 symlink 的总字节数 - 基线总字节数 < 1024
        // 即不能把 a.bin（1024B）的内容再算进来。symlink 节点自身只占很小的元数据空间。
        let scannerDelta = cs.totalAllocatedBytes - bs.totalAllocatedBytes
        let bulkDelta = cb.totalAllocatedBytes - bb.totalAllocatedBytes

        XCTAssertLessThan(scannerDelta, 1024,
            "Scanner 跟随了 symlink？字节增量=\(scannerDelta)")
        XCTAssertLessThan(bulkDelta, 1024,
            "BulkScanner 跟随了 symlink？字节增量=\(bulkDelta)")

        // 二者在含 symlink 场景下也应保持相互一致（block 对齐误差内）
        let 双引擎差额 = abs(cs.totalAllocatedBytes - cb.totalAllocatedBytes)
        XCTAssertLessThanOrEqual(双引擎差额, 4096,
            "含 symlink 场景下两引擎字节差额超过一个 block：scanner=\(cs.totalAllocatedBytes) bulk=\(cb.totalAllocatedBytes)")
    }
}
