import Darwin
import XCTest
@testable import ScanKit

/// v2026.07.17 Duplicate 全链路性能回归合同。
///
/// 这组测试针对“扫描 producer 已完成，但完整 FSNode 流仍在消费者侧排队”的事故补证：
/// Duplicate 只需要达到逻辑大小阈值的文件，因此必须由 ScanKit 在 worker 侧无损投影；
/// 同时，投影不能以丢逐节点事件为代价丢失容量汇总或 typed incomplete evidence。
/// 根规划与取消也属于同一条链路：重叠根会重复 I/O，取消若仍发布 finished 会把部分结果
/// 伪装成完整结果。
final class DuplicateProjectionRegressionTests: XCTestCase {
    private struct BulkCapture {
        let summary: ScanSummary
        let nodes: [FSNode]
        let nodeEventCount: Int
        let finishedEventCount: Int
    }

    private struct CancellationOutcome: Sendable {
        let reachedCancellationPoint: Bool
        let sawFinished: Bool
        let terminationLatency: Duration?
    }

    private actor CancellationRecorder {
        private var outcome: CancellationOutcome?

        func store(_ value: CancellationOutcome) {
            outcome = value
        }

        func load() -> CancellationOutcome? {
            outcome
        }
    }

    private enum FixtureError: Error {
        case couldNotCreateFile(String)
        case couldNotCreateSparseFile(String, Int32)
    }

    private var deterministicOptions: ScanOptions {
        ScanOptions(
            includeHidden: true,
            concurrency: 1,
            maxConcurrency: 1,
            mediaAware: false,
            respectTCCSkipList: false
        )
    }

    // MARK: - BulkScanner fileCandidates projection

    func test_fileCandidates与完整流候选精确一致且不发布逐节点并保留完整性证据() async throws {
        let root = try makeRoot(prefix: "DuplicateProjection-Candidates")
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try writeFile(root.appendingPathComponent("below.bin"), size: 4 * 1_024, byte: 0x11)
        try writeFile(root.appendingPathComponent("equal.bin"), size: 16 * 1_024, byte: 0x22)
        try writeFile(nested.appendingPathComponent("above.bin"), size: 32 * 1_024, byte: 0x33)
        try writeFile(denied.appendingPathComponent("hidden.bin"), size: 64 * 1_024, byte: 0x44)

        XCTAssertEqual(chmod(denied.path, 0), 0)
        addTeardownBlock {
            _ = chmod(denied.path, S_IRWXU)
            try FileManager.default.removeItem(at: root)
        }

        // root runner 会绕过 POSIX mode bits；这种环境无法制造真实权限缺口，明确 skip，
        // 不能让测试把“本来可读”误判成投影丢失 incomplete evidence。
        let permissionProbe = open(denied.path, O_RDONLY)
        if permissionProbe >= 0 {
            close(permissionProbe)
            throw XCTSkip("当前 test runner 可绕过 chmod(000)，无法构造 POSIX 不完整扫描证据")
        }

        let threshold: Int64 = 16 * 1_024
        let complete = await captureBulk(root: root, delivery: .complete)
        let projected = await captureBulk(
            root: root,
            delivery: .fileCandidates(minimumLogicalBytes: threshold)
        )

        XCTAssertEqual(projected.nodeEventCount, 0,
                       "fileCandidates 不得重新把完整 FSNode 流排队给 Duplicate 消费者")
        XCTAssertEqual(projected.finishedEventCount, 1)
        assertSameAuthoritativeSummary(projected.summary, complete.summary)
        XCTAssertEqual(projected.summary.completionStatus, .partial)
        XCTAssertEqual(projected.summary.incompleteIssues.count, 1)
        XCTAssertEqual(projected.summary.incompleteIssues.first?.path, denied.path)
        XCTAssertEqual(projected.summary.incompleteIssues.first?.reason, .permissionDenied)

        let expected = complete.nodes
            .filter { !$0.isDirectory && $0.logicalSize >= threshold }
            .sorted { $0.path < $1.path }
        guard case .fileCandidates(let actualValue) = projected.summary.projection else {
            return XCTFail("fileCandidates 终态必须携带对应 projection")
        }
        let actual = actualValue.sorted { $0.path < $1.path }

        XCTAssertEqual(actual, expected,
                       "worker 侧阈值过滤必须与静态 fixture 的完整流精确一致")
        XCTAssertEqual(actual.map(\.path), [
            nested.appendingPathComponent("above.bin").path,
            root.appendingPathComponent("equal.bin").path
        ].sorted())
    }

    // MARK: - Duplicate root planning

    func test_duplicate根规划折叠重复与祖先但不误吞同前缀兄弟路径() throws {
        let base = try makeRoot(prefix: "DuplicateProjection-Roots")
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("cache", isDirectory: true)
        let child = parent.appendingPathComponent("nested", isDirectory: true)
        let prefixSibling = base.appendingPathComponent("cache-backup", isDirectory: true)
        for directory in [child, prefixSibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let duplicateWithDots = URL(fileURLWithPath: parent.path + "/./")
        let planned = DuplicateScanner.minimalNonOverlappingRoots([
            child,
            parent,
            duplicateWithDots,
            prefixSibling,
            child
        ])

        XCTAssertEqual(Set(planned.map(\.path)), Set([parent.path, prefixSibling.path]))
        XCTAssertEqual(planned.count, 2,
                       "重复 root 与真实后代只能保留一次；cache-backup 不是 cache 的后代")

        let rootDominatesAll = DuplicateScanner.minimalNonOverlappingRoots([
            child,
            URL(fileURLWithPath: "/"),
            parent
        ])
        XCTAssertEqual(rootDominatesAll.map(\.path), ["/"],
                       "POSIX 根路径的祖先边界必须单独正确处理")
    }

    // MARK: - Cancellation

    /// v2026.10.09: root planning must not turn a protected physical namespace into
    /// the logical temporary alias deliberately exempted for test/workspace scans.
    func testPhysicalTemporaryRootKeepsTCCIdentityThroughDuplicatePipeline() async throws {
        let root = try makeRoot(prefix: "DuplicateProjection-PhysicalTCC")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try writeFile(root.appendingPathComponent("a.bin"), size: 128 * 1_024, byte: 0x33)
        try writeFile(root.appendingPathComponent("b.bin"), size: 128 * 1_024, byte: 0x33)
        let canonical = try XCTUnwrap(root.path.withCString { realpath($0, nil) })
        defer { free(canonical) }
        let physical = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        guard physical.path.hasPrefix("/private/var/folders/") else {
            throw XCTSkip("当前 runner 临时目录不在 macOS physical TCC namespace")
        }
        XCTAssertTrue(TCCSkipList.shouldSkip(physical.path))
        let estimate = await TreeSizeEstimator.estimate(roots: [physical])
        XCTAssertNil(estimate, "pre-scan estimation must honor the same selected namespace")
        let planned = DuplicateScanner.minimalNonOverlappingRoots([
            URL(fileURLWithPath: physical.path + "/./nested/.."), physical
        ])
        XCTAssertEqual(planned.map(\.path), [physical.path])

        let scanner = DuplicateScanner(roots: [physical], minBytes: 1)
        let session = scanner.scanSession()
        var issues: [ScanIncompleteIssue] = []
        var finished: [DuplicateGroup]?
        for await event in session.events {
            switch event {
            case .incomplete(let issue): issues.append(issue)
            case .finished(let groups): finished = groups
            default: break
            }
        }
        await session.waitForTermination()
        XCTAssertEqual(issues, [.init(path: physical.path, reason: .tccProtectedSkipped)])
        XCTAssertEqual(finished?.count, 0, "protected roots must not be enumerated or hashed")
    }

    func test_duplicate枚举阶段取消一秒内收敛且不发布finished() async throws {
        let root = try makeRoot(prefix: "DuplicateProjection-ScanCancellation")
        for directoryIndex in 0..<384 {
            let directory = root.appendingPathComponent("bucket-\(directoryIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileIndex in 0..<4 {
                try writeFile(
                    directory.appendingPathComponent("entry-\(fileIndex).bin"),
                    size: 1_024,
                    byte: UInt8(truncatingIfNeeded: directoryIndex + fileIndex)
                )
            }
        }
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let scanner = DuplicateScanner(roots: [root], minBytes: 1, scanOptions: deterministicOptions)
        let terminated = expectation(description: "Duplicate sizing cancel 后 stream 终止")
        let recorder = CancellationRecorder()

        let consumer = Task {
            let clock = ContinuousClock()
            var cancellationStartedAt: ContinuousClock.Instant?
            var sawFinished = false
            for await event in scanner.scan() {
                switch event {
                case .sizingProgress where cancellationStartedAt == nil:
                    cancellationStartedAt = clock.now
                    withUnsafeCurrentTask { $0?.cancel() }
                case .finished:
                    sawFinished = true
                default:
                    break
                }
            }
            await recorder.store(CancellationOutcome(
                reachedCancellationPoint: cancellationStartedAt != nil,
                sawFinished: sawFinished,
                terminationLatency: cancellationStartedAt.map { $0.duration(to: clock.now) }
            ))
            terminated.fulfill()
        }

        await fulfillment(of: [terminated], timeout: 1.0)
        consumer.cancel()
        let outcome = await recorder.load()
        XCTAssertEqual(outcome?.reachedCancellationPoint, true,
                       "fixture 必须进入真实 sizing progress 后再取消")
        XCTAssertEqual(outcome?.sawFinished, false,
                       "枚举取消不得把部分候选伪装成 finished")
        if let latency = outcome?.terminationLatency {
            XCTAssertLessThan(latency, .seconds(1))
        } else {
            XCTFail("缺少 Duplicate 枚举取消时延证据")
        }
    }

    func test_duplicate全文件hash阶段取消一秒内收敛且不发布finished() async throws {
        let root = try makeRoot(prefix: "DuplicateProjection-HashCancellation")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        // 8 × 128 MiB sparse 文件几乎不占 fixture 磁盘，但若取消没有传到 read loop，
        // 仍需读取 1 GiB logical 数据；因此可以稳定暴露 hash 取消尾延迟。
        let logicalBytes: Int64 = 128 * 1_024 * 1_024
        for index in 0..<8 {
            try makeSparseFile(
                root.appendingPathComponent("same-\(index).bin"),
                logicalBytes: logicalBytes
            )
        }

        let scanner = DuplicateScanner(roots: [root], minBytes: 1, scanOptions: deterministicOptions)
        let terminated = expectation(description: "Duplicate full hash cancel 后 stream 终止")
        let recorder = CancellationRecorder()

        let consumer = Task {
            let clock = ContinuousClock()
            var cancellationStartedAt: ContinuousClock.Instant?
            var sawFinished = false
            for await event in scanner.scan() {
                switch event {
                case .fullHashingProgress(let done, let total)
                    where done == 0 && total > 0 && cancellationStartedAt == nil:
                    cancellationStartedAt = clock.now
                    withUnsafeCurrentTask { $0?.cancel() }
                case .finished:
                    sawFinished = true
                default:
                    break
                }
            }
            await recorder.store(CancellationOutcome(
                reachedCancellationPoint: cancellationStartedAt != nil,
                sawFinished: sawFinished,
                terminationLatency: cancellationStartedAt.map { $0.duration(to: clock.now) }
            ))
            terminated.fulfill()
        }

        await fulfillment(of: [terminated], timeout: 2.0)
        consumer.cancel()
        let outcome = await recorder.load()
        XCTAssertEqual(outcome?.reachedCancellationPoint, true,
                       "fixture 必须进入 full-file hash 阶段后再取消")
        XCTAssertEqual(outcome?.sawFinished, false,
                       "hash 取消不得发布 finished 部分结果")
        if let latency = outcome?.terminationLatency {
            XCTAssertLessThan(latency, .seconds(1),
                              "hashFile 必须在 read batch 边界响应取消")
        } else {
            XCTFail("缺少 Duplicate hash 取消时延证据")
        }
    }

    // MARK: - Hash read evidence

    func test_duplicate候选读取失败产生typedIncomplete且保留其余完整分组() async throws {
        let root = try makeRoot(prefix: "DuplicateProjection-ReadFailure")
        let readableA = root.appendingPathComponent("readable-a.bin")
        let readableB = root.appendingPathComponent("readable-b.bin")
        let unreadable = root.appendingPathComponent("unreadable.bin")
        for url in [readableA, readableB, unreadable] {
            try writeFile(url, size: 1 * 1_024 * 1_024, byte: 0xA5)
        }
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        addTeardownBlock {
            _ = chmod(unreadable.path, S_IRUSR | S_IWUSR)
            try FileManager.default.removeItem(at: root)
        }

        let permissionProbe = open(unreadable.path, O_RDONLY)
        if permissionProbe >= 0 {
            close(permissionProbe)
            throw XCTSkip("当前 test runner 可绕过 chmod(000)，无法注入 hash open 失败")
        }

        var issues: [ScanIncompleteIssue] = []
        var terminalGroups: [DuplicateGroup]?
        var sawCancelled = false
        for await event in DuplicateScanner(
            roots: [root],
            minBytes: 1,
            scanOptions: deterministicOptions
        ).scan() {
            switch event {
            case .incomplete(let issue):
                issues.append(issue)
            case .finished(let groups):
                terminalGroups = groups
            case .cancelled:
                sawCancelled = true
            default:
                break
            }
        }

        XCTAssertFalse(sawCancelled)
        XCTAssertEqual(issues, [ScanIncompleteIssue(
            path: unreadable.path,
            reason: .metadataUnavailable,
            stage: .metadata
        )])
        let groups = try XCTUnwrap(terminalGroups)
        XCTAssertEqual(groups.count, 1,
                       "单条 read failure 不应吞掉同 size 桶内其余可完整验证的重复组")
        XCTAssertEqual(Set(groups[0].paths), Set([readableA.path, readableB.path]))
        XCTAssertEqual(groups[0].reliability, .full)
    }

    // MARK: - Helpers

    private func captureBulk(
        root: URL,
        delivery: BulkScanner.EventDelivery
    ) async -> BulkCapture {
        var terminalSummary: ScanSummary?
        var nodes: [FSNode] = []
        var nodeEventCount = 0
        var finishedEventCount = 0
        for await event in BulkScanner(options: deterministicOptions).scan(
            root: root,
            delivery: delivery
        ) {
            switch event {
            case .node(let node):
                nodeEventCount += 1
                nodes.append(node)
            case .nodes(let batch):
                nodeEventCount += 1
                nodes.append(contentsOf: batch)
            case .finished(let summary):
                finishedEventCount += 1
                terminalSummary = summary
            default:
                break
            }
        }
        guard let terminalSummary else {
            XCTFail("BulkScanner 必须产生终态 summary")
            return BulkCapture(
                summary: ScanSummary(
                    root: root,
                    totalAllocatedBytes: 0,
                    totalLogicalBytes: 0,
                    fileCount: 0,
                    directoryCount: 0,
                    dedupedHardlinkBytes: 0,
                    elapsed: 0,
                    completionStatus: .partial
                ),
                nodes: nodes,
                nodeEventCount: nodeEventCount,
                finishedEventCount: finishedEventCount
            )
        }
        return BulkCapture(
            summary: terminalSummary,
            nodes: nodes,
            nodeEventCount: nodeEventCount,
            finishedEventCount: finishedEventCount
        )
    }

    private func assertSameAuthoritativeSummary(
        _ actual: ScanSummary,
        _ expected: ScanSummary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.root.standardizedFileURL, expected.root.standardizedFileURL,
                       file: file, line: line)
        XCTAssertEqual(actual.totalAllocatedBytes, expected.totalAllocatedBytes,
                       file: file, line: line)
        XCTAssertEqual(actual.totalLogicalBytes, expected.totalLogicalBytes,
                       file: file, line: line)
        XCTAssertEqual(actual.fileCount, expected.fileCount, file: file, line: line)
        XCTAssertEqual(actual.directoryCount, expected.directoryCount, file: file, line: line)
        XCTAssertEqual(actual.dedupedHardlinkBytes, expected.dedupedHardlinkBytes,
                       file: file, line: line)
        XCTAssertEqual(actual.permissionDeniedCount, expected.permissionDeniedCount,
                       file: file, line: line)
        XCTAssertEqual(actual.tccProtectedSkippedCount, expected.tccProtectedSkippedCount,
                       file: file, line: line)
        XCTAssertEqual(actual.completionStatus, expected.completionStatus,
                       file: file, line: line)
        XCTAssertEqual(actual.incompleteIssues, expected.incompleteIssues,
                       file: file, line: line)
    }

    private func makeRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ url: URL, size: Int, byte: UInt8) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(repeating: byte, count: size)
        ) else {
            throw FixtureError.couldNotCreateFile(url.path)
        }
    }

    private func makeSparseFile(_ url: URL, logicalBytes: Int64) throws {
        let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw FixtureError.couldNotCreateSparseFile(url.path, errno)
        }
        defer { close(fd) }
        guard ftruncate(fd, off_t(logicalBytes)) == 0 else {
            throw FixtureError.couldNotCreateSparseFile(url.path, errno)
        }
    }
}
