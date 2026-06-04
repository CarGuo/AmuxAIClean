import XCTest
@testable import ScanKit

/// v1.3：MultiRootScanner 多根并行扫描的契约测试。
///
/// 我们关心三件事，与 BulkScanner 单根测试解耦：
/// 1. **每根都会 yield 自己的 .finished**：上层 ScanCoordinator 用此事件翻 perRootProgress.isFinished；
/// 2. **rootPath 信封正确**：每条 MultiRootEvent.rootPath 必须能在传入 roots 里找到（不能串根）；
/// 3. **多根字节合计与单根逐个扫的合计一致**：保证 InodeSet 独立 + 不漏不重；
/// 4. **空 roots 立刻 finish**：边界。
final class MultiRootScannerTests: XCTestCase {

    /// 在 /tmp 下造一个目录，写入 N 个内容固定的文件。
    /// 返回根 URL 与该根的 logical bytes 总和（用作断言基线）。
    private func makeFixture(prefix: String, fileCount: Int, bytesPerFile: Int) throws -> (URL, Int64) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GSYMultiRoot-\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var total: Int64 = 0
        for i in 0..<fileCount {
            let f = root.appendingPathComponent("file_\(i).bin")
            let data = Data(repeating: UInt8(i & 0xFF), count: bytesPerFile)
            try data.write(to: f)
            total += Int64(bytesPerFile)
        }
        return (root, total)
    }

    /// 收集多根 stream 的全部事件到内存（小 fixture 才能这么干）。
    private func collect(_ stream: AsyncStream<MultiRootEvent>) async -> [MultiRootEvent] {
        var out: [MultiRootEvent] = []
        for await ev in stream {
            out.append(ev)
        }
        return out
    }

    func test_两个根都会yield各自的finished() async throws {
        let (r1, _) = try makeFixture(prefix: "A", fileCount: 3, bytesPerFile: 1024)
        let (r2, _) = try makeFixture(prefix: "B", fileCount: 5, bytesPerFile: 512)
        defer {
            try? FileManager.default.removeItem(at: r1)
            try? FileManager.default.removeItem(at: r2)
        }

        let scanner = MultiRootScanner(options: ScanOptions(includeHidden: true,
                                                            concurrency: 2, maxConcurrency: 2,
                                                            mediaAware: false))
        let events = await collect(await scanner.scan(roots: [r1, r2]))

        // 每根至少 yield 一次 .finished
        let finishedRoots = events.compactMap { ev -> String? in
            if case .finished = ev.event { return ev.rootPath } else { return nil }
        }
        XCTAssertEqual(Set(finishedRoots), Set([r1.path, r2.path]),
                       "两个根都必须 yield 各自的 .finished，缺一会让 UI perRootProgress 永远卡着 ●")
    }

    func test_rootPath信封不会串根() async throws {
        let (r1, _) = try makeFixture(prefix: "C", fileCount: 4, bytesPerFile: 256)
        let (r2, _) = try makeFixture(prefix: "D", fileCount: 4, bytesPerFile: 256)
        defer {
            try? FileManager.default.removeItem(at: r1)
            try? FileManager.default.removeItem(at: r2)
        }

        let scanner = MultiRootScanner(options: .default)
        let events = await collect(await scanner.scan(roots: [r1, r2]))

        // 任何 .node / .nodes 事件，其 url.path 必须以信封里的 rootPath 为前缀。
        for ev in events {
            if case .node(let node) = ev.event {
                XCTAssertTrue(
                    node.url.path == ev.rootPath || node.url.path.hasPrefix(ev.rootPath + "/"),
                    "rootPath 信封串了根：node=\(node.url.path) 信封=\(ev.rootPath)"
                )
            } else if case .nodes(let arr) = ev.event {
                // Step 13B micro-batch：批量 entry 同样要求每个都属于本根
                for node in arr {
                    XCTAssertTrue(
                        node.url.path == ev.rootPath || node.url.path.hasPrefix(ev.rootPath + "/"),
                        "rootPath 信封串了根（batch 内）：node=\(node.url.path) 信封=\(ev.rootPath)"
                    )
                }
            }
        }
    }

    func test_多根文件总数与逐根扫描合计一致() async throws {
        let (r1, _) = try makeFixture(prefix: "E", fileCount: 7, bytesPerFile: 1024)
        let (r2, _) = try makeFixture(prefix: "F", fileCount: 11, bytesPerFile: 256)
        defer {
            try? FileManager.default.removeItem(at: r1)
            try? FileManager.default.removeItem(at: r2)
        }

        let opts = ScanOptions(includeHidden: true,
                               concurrency: 2, maxConcurrency: 2, mediaAware: false)
        // 单根 baseline
        var baselineFiles = 0
        var baselineBytes: Int64 = 0
        for r in [r1, r2] {
            let s = BulkScanner(options: opts)
            for await ev in s.scan(root: r) {
                if case .finished(let summary) = ev {
                    baselineFiles += summary.fileCount
                    baselineBytes += summary.totalAllocatedBytes
                }
            }
        }

        // 多根并行
        let multi = MultiRootScanner(options: opts)
        let events = await collect(await multi.scan(roots: [r1, r2]))
        var multiFiles = 0
        var multiBytes: Int64 = 0
        for ev in events {
            if case .finished(let summary) = ev.event {
                multiFiles += summary.fileCount
                multiBytes += summary.totalAllocatedBytes
            }
        }

        XCTAssertEqual(multiFiles, baselineFiles,
                       "多根合计文件数应等于逐根扫描相加")
        XCTAssertEqual(multiBytes, baselineBytes,
                       "多根合计字节应等于逐根扫描相加（说明 InodeSet 独立 + 没漏没重）")
    }

    func test_空roots立刻finish不挂死() async throws {
        let scanner = MultiRootScanner(options: .default)
        let events = await collect(await scanner.scan(roots: []))
        XCTAssertTrue(events.isEmpty, "空 roots 应立刻 finish stream，不应有任何事件")
    }

    /// v1.3 review-fix P0-3：跨根 hardlink 必须各自计入字节，证明每根独立 InodeSet。
    /// 若 InodeSet 跨根共享，第二根扫到的 hardlink 会被 dedupe 成 0，多根合计会少一份。
    func test_跨根hardlink独立计入字节_证明InodeSet独立() async throws {
        let (r1, _) = try makeFixture(prefix: "Glink-A", fileCount: 1, bytesPerFile: 4096)
        let (r2, _) = try makeFixture(prefix: "Glink-B", fileCount: 0, bytesPerFile: 0)
        defer {
            try? FileManager.default.removeItem(at: r1)
            try? FileManager.default.removeItem(at: r2)
        }
        // 在 r2 创建一个指向 r1/file_0.bin 的硬链接（同卷 /tmp 通常是同卷）。
        let src = r1.appendingPathComponent("file_0.bin").path
        let dst = r2.appendingPathComponent("hardlink-to-r1.bin").path
        // link(2) 失败时跳过此用例（少见——比如 /tmp 跨卷或 SIP 拒绝）
        guard link(src, dst) == 0 else {
            throw XCTSkip("link(2) 失败，可能跨卷或被 SIP 拒绝；当前测试不适用")
        }

        let opts = ScanOptions(includeHidden: true,
                               concurrency: 2, maxConcurrency: 2, mediaAware: false)
        let scanner = MultiRootScanner(options: opts)
        let events = await collect(await scanner.scan(roots: [r1, r2]))

        var totalBytes: Int64 = 0
        for ev in events {
            if case .finished(let summary) = ev.event {
                totalBytes += summary.totalAllocatedBytes
            }
        }
        // 若 InodeSet 跨根共享，r2 的 hardlink 会被 dedupe → 总字节 ≈ 4096
        // 独立 InodeSet 时 r1 与 r2 各自计入 4096 → 总字节 ≈ 8192
        XCTAssertGreaterThanOrEqual(totalBytes, 8192,
            "跨根 hardlink 应各自计入字节（实测 \(totalBytes)），低于 8192 说明 InodeSet 跨根共享了")
    }
}
