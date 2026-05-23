import XCTest
@testable import ScanKit

/// v1.0 T2.6：多 worker BulkScanner 的并发正确性测试。
///
/// 这一组测试专门盯着以下业界踩过的坑：
/// 1. **饥饿 / 死锁**：N worker 并行下钻，结尾 stack 空但还有 worker 在跑 —— 不能让任何
///    worker 提前 .done 退出，必须 inFlight==0 && stack 空才退。
/// 2. **总数一致**：N=1 / N=4 / N=8 扫同一棵子树，文件总数 / 总字节必须完全相等。
/// 3. **跨卷停下钻**：staySingleVolume=true 时，dev_t 不一致的子目录不应该入队。
///    （单卷 fixture 上验证 staySingleVolume 至少不破坏正确性。）
/// 4. **inFlight 终止条件**：极深目录（每层只有 1 个子目录），N=4 worker 仍能完整扫完。
final class BulkScannerConcurrencyTests: XCTestCase {

    /// 造一棵宽 + 深的混合 fixture：100 文件 + 50 子目录、其中一个分支深 6 层，
    /// 用来同时压"宽并行"与"深递归终止"两个场景。
    private func makeFixture(fileCount: Int = 100, depthChain: Int = 6) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GSYCleanScanConc-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 宽 50 子目录 × 每个 2 文件
        for i in 0..<50 {
            let sub = root.appendingPathComponent("dir_\(i)")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: UInt8(i & 0xFF), count: 1024)
                .write(to: sub.appendingPathComponent("a.bin"))
            try Data(repeating: UInt8(i & 0xFF), count: 2048)
                .write(to: sub.appendingPathComponent("b.bin"))
        }

        // 深 depthChain 层链状目录 + 末端一个文件
        var deep = root.appendingPathComponent("deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        for i in 0..<depthChain {
            deep = deep.appendingPathComponent("L\(i)")
            try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        }
        try Data(repeating: 0xFF, count: 4096).write(to: deep.appendingPathComponent("end.bin"))

        // 顶层多余文件填满 fileCount 余量（已有 50*2=100 + 1 end.bin = 101，超出 fileCount 就不补）
        let already = 101
        if fileCount > already {
            for i in 0..<(fileCount - already) {
                try Data(repeating: 0xAA, count: 512)
                    .write(to: root.appendingPathComponent("top_\(i).bin"))
            }
        }
        return root
    }

    private func consume(_ scanner: BulkScanner, root: URL) async -> ScanSummary {
        var summary: ScanSummary?
        for await ev in scanner.scan(root: root) {
            switch ev {
            case .finished(let s): summary = s
            default: break
            }
        }
        return summary!
    }

    func test_单worker与多worker结果完全一致() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // v1.3 review-fix：显式关 mediaAware，否则 SSD 上 SSD 档会把 N=1 升成
        // min(8, maxConcurrency) → 测试名义上的"单 worker"实际跑成 maxConcurrency 个。
        // 关闭后 actualConcurrency 严格等于 concurrency，单/多 worker 一致性才有意义。
        let optsN1 = ScanOptions(includeHidden: true, concurrency: 1, maxConcurrency: 1, mediaAware: false)
        let optsN4 = ScanOptions(includeHidden: true, concurrency: 4, maxConcurrency: 4, mediaAware: false)
        let optsN8 = ScanOptions(includeHidden: true, concurrency: 8, maxConcurrency: 8, mediaAware: false)

        let s1 = await consume(BulkScanner(options: optsN1), root: root)
        let s4 = await consume(BulkScanner(options: optsN4), root: root)
        let s8 = await consume(BulkScanner(options: optsN8), root: root)

        XCTAssertEqual(s1.fileCount, s4.fileCount, "N=1 vs N=4 文件总数必须一致")
        XCTAssertEqual(s1.fileCount, s8.fileCount, "N=1 vs N=8 文件总数必须一致")
        XCTAssertEqual(s1.totalAllocatedBytes, s4.totalAllocatedBytes, "N=1 vs N=4 总字节必须一致")
        XCTAssertEqual(s1.totalAllocatedBytes, s8.totalAllocatedBytes, "N=1 vs N=8 总字节必须一致")
        XCTAssertEqual(s1.directoryCount, s4.directoryCount, "N=1 vs N=4 目录数必须一致")
    }

    func test_深层链状目录在多worker下完整扫完不丢节点() async throws {
        let root = try makeFixture(fileCount: 0, depthChain: 10)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = BulkScanner(options: ScanOptions(concurrency: 4, maxConcurrency: 4))
        var nodeCount = 0
        var summary: ScanSummary?
        for await ev in scanner.scan(root: root) {
            switch ev {
            case .node: nodeCount += 1
            case .finished(let s): summary = s
            default: break
            }
        }
        XCTAssertNotNil(summary, "scan 必须 finished")
        XCTAssertGreaterThan(nodeCount, 10, "10 层链 + 50 宽目录 + 100 文件，节点数应该 > 10")
        // 关键：深链末端的 end.bin 必须被扫到（曾经的 bug：worker 提前 .done 漏扫深链）
        XCTAssertEqual(summary!.fileCount, 1 + 50 * 2, "应是 1（end.bin）+ 100（宽 50 目录×2 文件）= 101 个文件")
    }

    func test_并发扫描总能finished而不卡死() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // 4 个独立 BulkScanner 实例并行扫同一棵 fixture（不共享 InodeSet）
        // 用 withTaskGroup 而不是 async let 来避免 self 跨域 sending 报错。
        let rootPath = root
        let results: [ScanSummary] = await withTaskGroup(of: ScanSummary.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let scanner = BulkScanner(options: .init(concurrency: 4))
                    var summary: ScanSummary?
                    for await ev in scanner.scan(root: rootPath) {
                        if case .finished(let s) = ev { summary = s }
                    }
                    return summary!
                }
            }
            var arr: [ScanSummary] = []
            for await r in group { arr.append(r) }
            return arr
        }

        XCTAssertEqual(results.count, 4)
        for r in results {
            XCTAssertEqual(r.fileCount, results[0].fileCount, "并行多个 BulkScanner 实例结果必须一致")
        }
    }

    func test_staySingleVolume开关不破坏单卷扫描正确性() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let withStay = await consume(
            BulkScanner(options: .init(concurrency: 4, staySingleVolume: true)),
            root: root
        )
        let withoutStay = await consume(
            BulkScanner(options: .init(concurrency: 4, staySingleVolume: false)),
            root: root
        )
        // 整棵 fixture 都在 /tmp 同一卷上 → 两个开关结果应该完全一致
        XCTAssertEqual(withStay.fileCount, withoutStay.fileCount)
        XCTAssertEqual(withStay.totalAllocatedBytes, withoutStay.totalAllocatedBytes)
    }

    func test_actualConcurrency严格cap在maxConcurrency() {
        let opts1 = ScanOptions(concurrency: 100, maxConcurrency: 6)
        XCTAssertEqual(opts1.actualConcurrency, 6, "concurrency=100 应被 cap 到 maxConcurrency=6")

        let opts2 = ScanOptions(concurrency: 2, maxConcurrency: 6)
        XCTAssertEqual(opts2.actualConcurrency, 2)

        let opts3 = ScanOptions(concurrency: 0, maxConcurrency: 6)
        XCTAssertEqual(opts3.actualConcurrency, 1, "concurrency=0 应被托底到 1")
    }
}
