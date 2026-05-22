import XCTest
@testable import ScanKit

/// 隐藏文件扫描行为测试。
///
/// fixture 结构（在临时目录下构造）：
///   ├── a.txt          (1024 字节，普通文件)
///   ├── .secret        (2048 字节，隐藏文件)
///   └── .hidden_dir/   (隐藏目录)
///       └── inner.bin  (512 字节)
///
/// 期望行为：
/// - includeHidden = true  → 文件总数为 3，已分配字节 ≥ 3584
/// - includeHidden = false → 文件总数为 1（仅 a.txt；隐藏目录内的 inner.bin 也应被跳过）
final class HiddenFileTests: XCTestCase {

    // MARK: - Fixture 构造

    /// 创建临时根目录及内部 fixture 文件，返回根 URL。
    /// 调用者负责在 tearDown / defer 中清理。
    private func makeFixture() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 普通文件 a.txt：1024 字节
        try Data(count: 1024).write(to: tmp.appendingPathComponent("a.txt"))

        // 隐藏文件 .secret：2048 字节
        try Data(count: 2048).write(to: tmp.appendingPathComponent(".secret"))

        // 隐藏目录 .hidden_dir/inner.bin：512 字节
        let hiddenDir = tmp.appendingPathComponent(".hidden_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try Data(count: 512).write(to: hiddenDir.appendingPathComponent("inner.bin"))

        return tmp
    }

    /// 收集扫描事件直到 finished，返回 summary。
    private func runUntilFinished(_ stream: AsyncStream<ScanEvent>) async -> ScanSummary? {
        for await event in stream {
            if case let .finished(s) = event { return s }
        }
        return nil
    }

    // MARK: - 用例 1：BulkScanner 默认包含隐藏文件

    func test_BulkScanner默认includeHidden为true_应统计全部三个文件() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // 默认构造即 includeHidden = true
        let scanner = BulkScanner()
        let summary = await runUntilFinished(scanner.scan(root: root))

        XCTAssertNotNil(summary, "必须能拿到 finished 事件")
        XCTAssertEqual(summary?.fileCount, 3, "应包含 a.txt + .secret + inner.bin")
        // 逻辑大小累计 1024 + 2048 + 512 = 3584；分配大小 ≥ 逻辑大小（APFS 按块对齐）
        XCTAssertGreaterThanOrEqual(summary?.totalAllocatedBytes ?? 0, 3584)
    }

    // MARK: - 用例 2：BulkScanner 排除隐藏文件

    func test_BulkScanner在includeHidden为false时_应仅统计普通文件() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = BulkScanner(options: ScanOptions(includeHidden: false))
        let summary = await runUntilFinished(scanner.scan(root: root))

        XCTAssertNotNil(summary)
        // .secret 被跳过；.hidden_dir 因名字以 "." 开头，整目录都不进入栈，inner.bin 也被跳过
        XCTAssertEqual(summary?.fileCount, 1, "应只剩 a.txt")
    }

    // MARK: - 用例 3：Scanner 路径同样验证两种 includeHidden

    func test_Scanner对includeHidden两种取值的行为应与BulkScanner一致() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // 子用例 3.1：默认 includeHidden = true，三个文件全收
        let scannerAll = ScanKit.Scanner()
        let summaryAll = await runUntilFinished(scannerAll.scan(root: root))
        XCTAssertNotNil(summaryAll)
        XCTAssertEqual(summaryAll?.fileCount, 3, "Scanner 默认应包含全部三个文件")
        XCTAssertGreaterThanOrEqual(summaryAll?.totalAllocatedBytes ?? 0, 3584)

        // 子用例 3.2：includeHidden = false，仅留 a.txt
        // FileManager.enumerator 的 .skipsHiddenFiles 会同时跳过隐藏目录及其内容
        let scannerVisible = ScanKit.Scanner(options: ScanOptions(includeHidden: false))
        let summaryVisible = await runUntilFinished(scannerVisible.scan(root: root))
        XCTAssertNotNil(summaryVisible)
        XCTAssertEqual(summaryVisible?.fileCount, 1, "Scanner 在 includeHidden=false 时应仅剩 a.txt")
    }
}
