import XCTest
@testable import ScanKit

/// v1.3：MultiRootScanner 多根并行扫描的契约测试。
///
/// 我们关心三件事，与 BulkScanner 单根测试解耦：
/// 1. **每根都会 yield 自己的 .finished**：上层 ScanCoordinator 用此事件翻 perRootProgress.isFinished；
/// 2. **rootPath 信封正确**：每条 MultiRootEvent.rootPath 必须能在传入 roots 里找到（不能串根）；
/// 3. **无共享 inode 时，多根字节合计与单根逐个扫一致**；
/// 4. **跨根 hardlink 只计一份物理分配**：事务账本不能因根并行而重复占用；
/// 5. **空 roots 立刻 finish**：边界。
final class MultiRootScannerTests: XCTestCase {

    /// 在 /tmp 下造一个目录，写入 N 个内容固定的文件。
    /// 返回根 URL 与该根的 logical bytes 总和（用作断言基线）。
    private func makeFixture(prefix: String, fileCount: Int, bytesPerFile: Int) throws -> (URL, Int64) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AmuxMultiRoot-\(prefix)-\(UUID().uuidString)")
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
        let producerTerminals = events.compactMap { event -> Date? in
            guard case .finished = event.event else { return nil }
            return event.producerCompletedAt
        }
        XCTAssertEqual(producerTerminals.count, 2)
        XCTAssertTrue(producerTerminals.allSatisfy { $0 <= Date() })
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
                       "没有跨根共享 inode 时，多根事务合计应与逐根扫描相加一致")
    }

    func test_空roots立刻finish不挂死() async throws {
        let scanner = MultiRootScanner(options: .default)
        let events = await collect(await scanner.scan(roots: []))
        XCTAssertTrue(events.isEmpty, "空 roots 应立刻 finish stream，不应有任何事件")
    }

    /// v2026.07.17：多根是一次物理容量事务，跨根 hardlink 必须只计一个 inode 的分配。
    /// 每根各自去重会让全局容量翻倍；UI 再按路径猜测相减既无法处理并发，也会破坏投影。
    func test_跨根hardlink通过事务账本只计一次物理分配() async throws {
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
        var singleRootAllocated: Int64 = 0
        for await event in BulkScanner(options: opts).scan(root: r1, delivery: .summaryOnly) {
            if case .finished(let summary) = event {
                singleRootAllocated = summary.totalAllocatedBytes
            }
        }
        XCTAssertGreaterThan(singleRootAllocated, 0)

        for delivery in [BulkScanner.EventDelivery.complete, .topLevel] {
            let scanner = MultiRootScanner(options: opts)
            let events = await collect(await scanner.scan(roots: [r1, r2], delivery: delivery))
            let summaries = events.compactMap { event -> ScanSummary? in
                guard case .finished(let summary) = event.event else { return nil }
                return summary
            }
            XCTAssertEqual(summaries.count, 2)
            XCTAssertEqual(
                summaries.reduce(Int64(0)) { $0 + $1.totalAllocatedBytes },
                singleRootAllocated,
                "完整流和一级投影都必须在整个多根事务内只计算一份 hardlink 分配"
            )
            XCTAssertEqual(
                summaries.reduce(Int64(0)) { $0 + $1.dedupedHardlinkBytes },
                singleRootAllocated,
                "跨根被吸收的那份分配必须进入 dedupedHardlinkBytes 证据"
            )

            if delivery == .complete {
                let nodeBytes = events.reduce(Int64(0)) { partial, event in
                    switch event.event {
                    case .node(let node):
                        return partial + node.allocatedSize
                    case .nodes(let nodes):
                        return partial + nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }
                    default:
                        return partial
                    }
                }
                XCTAssertEqual(nodeBytes, singleRootAllocated,
                               "增量节点与事务 summary 必须使用同一份 allocation ledger")
            } else {
                let projectionBytes = summaries.reduce(Int64(0)) { partial, summary in
                    guard case .topLevel(let rows) = summary.projection else { return partial }
                    return partial + rows.reduce(Int64(0)) { $0 + $1.allocatedBytes }
                }
                XCTAssertEqual(projectionBytes, singleRootAllocated,
                               "topLevel 投影与事务 summary 必须使用同一份 allocation ledger")
            }
        }
    }

    func test_timeoutSyntheticSummary_保留已观察到的partial进度() async throws {
        let root = URL(fileURLWithPath: "/tmp/synthetic-root")
        let clock = MultiRootProgressClock()

        await clock.record(nodes: [
            FSNode(path: "/tmp/synthetic-root/a.bin",
                   isDirectory: false,
                   isSymlink: false,
                   allocatedSize: 4096,
                   logicalSize: 2048,
                   inode: 1,
                   device: 1,
                   modificationDate: nil),
            FSNode(path: "/tmp/synthetic-root/sub",
                   isDirectory: true,
                   isSymlink: false,
                   allocatedSize: 0,
                   logicalSize: 0,
                   inode: 2,
                   device: 1,
                   modificationDate: nil)
        ])
        await clock.recordProgress(scannedBytes: 8192, fileCount: 3)
        await clock.recordPermissionDenied()
        await clock.recordTCCProtectedSkipped()

        let summary = await clock.syntheticSummary(root: root, elapsed: 1.25)

        XCTAssertEqual(summary.root, root)
        XCTAssertEqual(summary.totalAllocatedBytes, 8192, "超时合成 summary 不能把已发布进度归零")
        XCTAssertEqual(summary.totalLogicalBytes, 2048)
        XCTAssertEqual(summary.fileCount, 3)
        XCTAssertEqual(summary.directoryCount, 1)
        XCTAssertEqual(summary.permissionDeniedCount, 1)
        XCTAssertEqual(summary.tccProtectedSkippedCount, 1)
        XCTAssertEqual(summary.completionStatus, .partial,
                       "超时合成 summary 只能作为 partial 结果，不能伪装成完整扫描")
    }

    func test_totalDeadlineCancelsRunningRootsAndStopsScheduling() async {
        let probe = MultiRootDeadlineProbe()
        let scanner = MultiRootScanner(
            options: .default,
            rootScanOperation: { _, _, _, _, _, _, _ in
                await probe.recordStarted()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch is CancellationError {
                    await probe.recordCancelled()
                } catch {
                    XCTFail("fake root scanner sleep 失败：\(error)")
                }
            }
        )
        let roots = (0..<8).map { URL(fileURLWithPath: "/tmp/deadline-root-\($0)") }
        let startedAt = Date()

        let events = await collect(
            await scanner.scan(
                roots: roots,
                maxConcurrentRoots: 2,
                perRootTimeout: 30,
                noProgressTimeout: 30,
                totalDeadline: 0.05
            )
        )

        let counts = await probe.counts()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(counts.started, 2, "deadline 前只应启动 sliding window 内的两个 root")
        XCTAssertEqual(counts.cancelled, counts.started, "total deadline 必须取消所有已启动 root")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0, "不能继续等待单根 5 秒任务")
    }

    func test_progressClock_recordsSummaryOnlyProgressAndIgnoresSymlinkFileCount() async {
        let root = URL(fileURLWithPath: "/tmp/summary-only-progress-root")
        let clock = MultiRootProgressClock()

        await clock.record(node: FSNode(
            path: "/tmp/summary-only-progress-root/link",
            isDirectory: false,
            isSymlink: true,
            allocatedSize: 0,
            logicalSize: 0,
            inode: 10,
            device: 1,
            modificationDate: nil
        ))
        await clock.recordProgress(
            scannedBytes: 16_384,
            fileCount: 4,
            logicalBytes: 12_288,
            directoryCount: 2
        )

        let summary = await clock.syntheticSummary(root: root, elapsed: 0.5)
        XCTAssertEqual(summary.totalAllocatedBytes, 16_384)
        XCTAssertEqual(summary.totalLogicalBytes, 12_288)
        XCTAssertEqual(summary.fileCount, 4, "Symlink node must not inflate fileCount and progress logical/directory totals must be preserved")
        XCTAssertEqual(summary.directoryCount, 2)
    }
}

private actor MultiRootDeadlineProbe {
    private var started = 0
    private var cancelled = 0

    func recordStarted() {
        started += 1
    }

    func recordCancelled() {
        cancelled += 1
    }

    func counts() -> (started: Int, cancelled: Int) {
        (started, cancelled)
    }
}
