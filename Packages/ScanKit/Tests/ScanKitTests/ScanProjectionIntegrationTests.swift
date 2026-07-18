import XCTest
@testable import ScanKit

/// v2026.07.16 扫描投影链路回归合同。
///
/// 性能修复把 UI 原先逐节点完成的一级聚合下沉到了 ScanKit。这里钉死三个容易再次
/// 回归的跨层边界：Data 风格路径必须先规范化再分 bucket；MultiRoot 必须原样保留每根
/// 的有界投影且不恢复 node 风暴；取消不能继续发布一个看似完整的 finished 终态。
final class ScanProjectionIntegrationTests: XCTestCase {
    private enum FixtureError: Error {
        case couldNotCreateFile(String)
    }

    fileprivate struct CancellationOutcome: Sendable {
        let sawCancellationPoint: Bool
        let sawFinished: Bool
        let terminationLatency: Duration?
    }

    private struct CompleteCapture {
        let summary: ScanSummary
        let nodes: [FSNode]
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

    func test_topLevel真实遍历先映射Data嵌套路径再生成一级bucket() async throws {
        let root = try makeRoot(prefix: "ProjectionPathMapping")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let dataRoot = root
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Volumes", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        let dataUsers = dataRoot.appendingPathComponent("Users", isDirectory: true)
        let dataLibrary = dataRoot.appendingPathComponent("Library", isDirectory: true)
        let systemLibrary = root
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)

        try FileManager.default.createDirectory(
            at: dataUsers.appendingPathComponent("alice", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dataLibrary.appendingPathComponent("Caches", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: systemLibrary,
            withIntermediateDirectories: true
        )
        try writeFile(
            dataUsers.appendingPathComponent("alice/user.bin"),
            byteCount: 3 * 1_024,
            seed: 0x11
        )
        try writeFile(
            dataLibrary.appendingPathComponent("Caches/cache.bin"),
            byteCount: 5 * 1_024,
            seed: 0x22
        )
        try writeFile(
            systemLibrary.appendingPathComponent("system.bin"),
            byteCount: 7 * 1_024,
            seed: 0x33
        )

        let mappings = [
            ScanPathPrefixMapping(
                sourcePrefix: dataUsers.path,
                destinationPrefix: root.appendingPathComponent("Users").path
            ),
            ScanPathPrefixMapping(
                sourcePrefix: dataLibrary.path,
                destinationPrefix: root.appendingPathComponent("Library").path
            )
        ]

        // 同一只读 fixture 的完整流是无损基线；不能把 APFS allocated block rounding
        // 或透明压缩假设硬编码进测试。
        let baseline = try await captureComplete(root: root)

        var nodeEventCount = 0
        var terminalSummary: ScanSummary?
        for await event in BulkScanner(options: deterministicOptions).scan(
            root: root,
            delivery: .topLevel,
            topLevelPathMappings: mappings
        ) {
            switch event {
            case .heartbeat, .progress:
                break
            case .node, .nodes:
                nodeEventCount += 1
            case .finished(let summary):
                XCTAssertNil(terminalSummary, "单根扫描只能发布一个 finished")
                terminalSummary = summary
            case .failed(let error):
                XCTFail("临时 fixture 不应整轮失败：\(error)")
            case .incomplete(let issue):
                XCTFail("临时 fixture 不应产生 incomplete：\(issue)")
            case .permissionDenied(let path):
                XCTFail("临时 fixture 不应权限失败：\(path)")
            case .tccProtectedSkipped(let path):
                XCTFail("临时 fixture 不应命中 TCC skip：\(path)")
            case .cacheDirTagged(let path):
                XCTFail("临时 fixture 不应命中 CACHEDIR.TAG：\(path)")
            }
        }

        let summary = try XCTUnwrap(terminalSummary)
        XCTAssertEqual(nodeEventCount, 0, ".topLevel 不能把映射工作重新推回 UI node 流")
        XCTAssertEqual(summary.fileCount, 3)
        XCTAssertEqual(summary.completionStatus, .complete)
        XCTAssertEqual(summary.totalAllocatedBytes, baseline.summary.totalAllocatedBytes)
        XCTAssertEqual(summary.totalLogicalBytes, baseline.summary.totalLogicalBytes)

        guard case .topLevel(let entries) = summary.projection else {
            return XCTFail("映射扫描终态必须携带 topLevel projection")
        }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let usersPath = root.appendingPathComponent("Users").path
        let libraryPath = root.appendingPathComponent("Library").path
        let systemPath = root.appendingPathComponent("System").path

        XCTAssertEqual(Set(byPath.keys), Set([usersPath, libraryPath, systemPath]),
                       "若先折叠 bucket 再映射，Users/Library 会错误地全部落进 System")
        XCTAssertEqual(byPath[usersPath]?.fileCount, 1)
        XCTAssertEqual(byPath[libraryPath]?.fileCount, 1)
        XCTAssertEqual(byPath[systemPath]?.fileCount, 1)
        let baselineByPath = Dictionary(uniqueKeysWithValues: baseline.nodes.map { ($0.path, $0) })
        let userFile = try XCTUnwrap(baselineByPath[dataUsers.appendingPathComponent("alice/user.bin").path])
        let libraryFile = try XCTUnwrap(baselineByPath[dataLibrary.appendingPathComponent("Caches/cache.bin").path])
        let systemFile = try XCTUnwrap(baselineByPath[systemLibrary.appendingPathComponent("system.bin").path])
        XCTAssertEqual(byPath[usersPath]?.allocatedBytes, userFile.allocatedSize)
        XCTAssertEqual(byPath[usersPath]?.logicalBytes, userFile.logicalSize)
        XCTAssertEqual(byPath[libraryPath]?.allocatedBytes, libraryFile.allocatedSize)
        XCTAssertEqual(byPath[libraryPath]?.logicalBytes, libraryFile.logicalSize)
        XCTAssertEqual(byPath[systemPath]?.allocatedBytes, systemFile.allocatedSize)
        XCTAssertEqual(byPath[systemPath]?.logicalBytes, systemFile.logicalSize)
        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.allocatedBytes },
                       summary.totalAllocatedBytes)
        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.logicalBytes },
                       summary.totalLogicalBytes)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.fileCount }, summary.fileCount)
    }

    func test_topLevelPhysicalRootCanProjectIntoDifferentPublicRoot() async throws {
        let fixture = try makeRoot(prefix: "ProjectionPhysicalVsPublicRoot")
        addTeardownBlock { try FileManager.default.removeItem(at: fixture) }
        let physicalRoot = fixture.appendingPathComponent("Data", isDirectory: true)
        let userFile = physicalRoot.appendingPathComponent("Users/alice/cache.bin")
        try FileManager.default.createDirectory(
            at: userFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeFile(userFile, byteCount: 4 * 1_024, seed: 0x51)

        let publicRoot = fixture.appendingPathComponent("Public", isDirectory: true).path
        var terminalSummary: ScanSummary?
        for await event in BulkScanner(options: deterministicOptions).scan(
            root: physicalRoot,
            delivery: .topLevel,
            topLevelPathMappings: [
                ScanPathPrefixMapping(
                    sourcePrefix: physicalRoot.path,
                    destinationPrefix: publicRoot
                )
            ],
            topLevelProjectionRootPath: publicRoot
        ) {
            if case .finished(let summary) = event {
                terminalSummary = summary
            }
        }

        let summary = try XCTUnwrap(terminalSummary)
        guard case .topLevel(let entries) = summary.projection else {
            return XCTFail("物理根与公开根分离后仍必须产生 topLevel projection")
        }
        XCTAssertEqual(entries.map(\.path), [publicRoot + "/Users"])
        XCTAssertEqual(entries.first?.fileCount, 1)
    }

    func test_multiRootTopLevel不发布节点且每根summary投影精确() async throws {
        let rootA = try makeRoot(prefix: "ProjectionMultiRoot-A")
        let rootB = try makeRoot(prefix: "ProjectionMultiRoot-B")
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootA)
            try FileManager.default.removeItem(at: rootB)
        }

        let caches = rootA.appendingPathComponent("Caches", isDirectory: true)
        let cachesDeep = caches.appendingPathComponent("deep", isDirectory: true)
        let downloads = rootA.appendingPathComponent("Downloads", isDirectory: true)
        let logs = rootB.appendingPathComponent("Logs", isDirectory: true)
        let reports = rootB.appendingPathComponent("Reports", isDirectory: true)
        for directory in [cachesDeep, downloads, logs, reports] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeFile(caches.appendingPathComponent("a.bin"), byteCount: 2_048, seed: 0x41)
        try writeFile(cachesDeep.appendingPathComponent("b.bin"), byteCount: 3_072, seed: 0x42)
        try writeFile(downloads.appendingPathComponent("c.bin"), byteCount: 4_096, seed: 0x43)
        try writeFile(logs.appendingPathComponent("a.log"), byteCount: 5_120, seed: 0x51)
        try writeFile(logs.appendingPathComponent("b.log"), byteCount: 6_144, seed: 0x52)
        try writeFile(reports.appendingPathComponent("report.bin"), byteCount: 7_168, seed: 0x53)

        // 两轮扫描之间不再写 fixture；complete 节点流作为每个 bucket 的实际文件系统基线。
        let baselineA = try await captureComplete(root: rootA)
        let baselineB = try await captureComplete(root: rootB)
        let scanner = MultiRootScanner(options: deterministicOptions)
        var nodeEventCount = 0
        var summaries: [String: [ScanSummary]] = [:]
        for await wrapped in await scanner.scan(
            roots: [rootA, rootB],
            maxConcurrentRoots: 2,
            perRootTimeout: 10,
            noProgressTimeout: 10,
            totalDeadline: 10,
            delivery: .topLevel
        ) {
            switch wrapped.event {
            case .heartbeat, .progress:
                break
            case .node, .nodes:
                nodeEventCount += 1
            case .finished(let summary):
                summaries[wrapped.rootPath, default: []].append(summary)
            case .failed(let error):
                XCTFail("临时 fixture 不应整轮失败：\(error)")
            case .incomplete(let issue):
                XCTFail("临时 fixture 不应产生 incomplete：\(issue)")
            case .permissionDenied(let path):
                XCTFail("临时 fixture 不应权限失败：\(path)")
            case .tccProtectedSkipped(let path):
                XCTFail("临时 fixture 不应命中 TCC skip：\(path)")
            case .cacheDirTagged(let path):
                XCTFail("临时 fixture 不应命中 CACHEDIR.TAG：\(path)")
            }
        }

        XCTAssertEqual(nodeEventCount, 0,
                       "MultiRoot .topLevel 不得把 node/nodes 事件恢复到外层 stream")
        XCTAssertEqual(Set(summaries.keys), Set([rootA.path, rootB.path]))
        XCTAssertEqual(summaries[rootA.path]?.count, 1)
        XCTAssertEqual(summaries[rootB.path]?.count, 1)

        let summaryA = try XCTUnwrap(summaries[rootA.path]?.first)
        let summaryB = try XCTUnwrap(summaries[rootB.path]?.first)
        try assertProjection(
            summaryA,
            baseline: baselineA,
            expectedFileCounts: [
                caches.path: 2,
                downloads.path: 1
            ]
        )
        try assertProjection(
            summaryB,
            baseline: baselineB,
            expectedFileCounts: [
                logs.path: 2,
                reports.path: 1
            ]
        )
    }

    func test_取消进行中的topLevel宽深扫描一秒内终止且不发布finished() async throws {
        let root = try makeCancellationFixture(topLevelDirectoryCount: 512, depth: 3)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let stream = BulkScanner(options: deterministicOptions).scan(
            root: root,
            delivery: .topLevel
        )
        let terminated = expectation(description: "取消后的 topLevel stream 已终止")
        let recorder = CancellationOutcomeRecorder()

        // 根目录的首个 progress 发布时，512 条深子树已经入队但单 worker 尚未消费；
        // 在该边界自取消，能够证明“进行中取消”，而不是任务尚未启动的假阳性。
        let consumer = Task {
            let clock = ContinuousClock()
            var cancellationStartedAt: ContinuousClock.Instant?
            var sawFinished = false
            for await event in stream {
                switch event {
                case .progress where cancellationStartedAt == nil:
                    cancellationStartedAt = clock.now
                    withUnsafeCurrentTask { $0?.cancel() }
                case .finished:
                    sawFinished = true
                default:
                    break
                }
            }
            let latency = cancellationStartedAt.map { $0.duration(to: clock.now) }
            await recorder.store(
                CancellationOutcome(
                    sawCancellationPoint: cancellationStartedAt != nil,
                    sawFinished: sawFinished,
                    terminationLatency: latency
                )
            )
            terminated.fulfill()
        }

        await fulfillment(of: [terminated], timeout: 1.0)
        consumer.cancel()
        let outcome = await recorder.value
        XCTAssertEqual(outcome?.sawCancellationPoint, true,
                       "fixture 必须先进入真实扫描 progress 再取消")
        XCTAssertEqual(outcome?.sawFinished, false,
                       "用户取消不能伪造一个完整 finished 终态")
        if let latency = outcome?.terminationLatency {
            XCTAssertLessThan(latency, Duration.seconds(1),
                              "取消后 stream 应在 1 秒内响应，实际 \(latency)")
        } else {
            XCTFail("缺少取消到 stream 终止的时延证据")
        }
    }

    private func assertProjection(
        _ summary: ScanSummary,
        baseline: CompleteCapture,
        expectedFileCounts: [String: Int]
    ) throws {
        XCTAssertEqual(summary.completionStatus, .complete)
        XCTAssertEqual(summary.fileCount, baseline.summary.fileCount)
        XCTAssertEqual(summary.directoryCount, baseline.summary.directoryCount)
        XCTAssertEqual(summary.totalAllocatedBytes, baseline.summary.totalAllocatedBytes)
        XCTAssertEqual(summary.totalLogicalBytes, baseline.summary.totalLogicalBytes)
        guard case .topLevel(let entries) = summary.projection else {
            return XCTFail("MultiRoot 每根 finished 必须保留 topLevel projection")
        }
        let actualFileCounts = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.path, $0.fileCount)
        })
        XCTAssertEqual(actualFileCounts, expectedFileCounts)
        let entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for bucketPath in expectedFileCounts.keys {
            let entry = try XCTUnwrap(entriesByPath[bucketPath])
            let bucketNodes = baseline.nodes.filter {
                $0.path == bucketPath || $0.path.hasPrefix(bucketPath + "/")
            }
            let files = bucketNodes.filter { !$0.isDirectory }
            XCTAssertEqual(entry.allocatedBytes,
                           files.reduce(Int64(0)) { $0 + $1.allocatedSize },
                           "bucket 物理容量必须与完整节点流精确一致：\(bucketPath)")
            XCTAssertEqual(entry.logicalBytes,
                           files.reduce(Int64(0)) { $0 + $1.logicalSize },
                           "bucket 逻辑容量必须与完整节点流精确一致：\(bucketPath)")
            XCTAssertEqual(entry.fileCount, files.count,
                           "bucket 文件数必须与完整节点流精确一致：\(bucketPath)")
            XCTAssertEqual(entry.isDirectory,
                           baseline.nodes.first { $0.path == bucketPath }?.isDirectory)
            XCTAssertEqual(entry.hasChildren,
                           bucketNodes.contains { $0.path != bucketPath })
        }
        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.allocatedBytes },
                       summary.totalAllocatedBytes,
                       "每根投影物理容量之和必须精确等于该根 summary")
        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.logicalBytes },
                       summary.totalLogicalBytes,
                       "每根投影逻辑容量之和必须精确等于该根 summary")
        XCTAssertEqual(entries.reduce(0) { $0 + $1.fileCount }, summary.fileCount,
                       "每根投影文件数之和必须精确等于该根 summary")
    }

    private func captureComplete(root: URL) async throws -> CompleteCapture {
        var nodes: [FSNode] = []
        var terminalSummary: ScanSummary?
        for await event in BulkScanner(options: deterministicOptions).scan(
            root: root,
            delivery: .complete
        ) {
            switch event {
            case .heartbeat, .progress:
                break
            case .node(let node):
                nodes.append(node)
            case .nodes(let batch):
                nodes.append(contentsOf: batch)
            case .finished(let summary):
                XCTAssertNil(terminalSummary, "完整基线扫描只能发布一个 finished")
                terminalSummary = summary
            case .failed(let error):
                XCTFail("完整基线扫描不应失败：\(error)")
            case .incomplete(let issue):
                XCTFail("完整基线扫描不应产生 incomplete：\(issue)")
            case .permissionDenied(let path):
                XCTFail("完整基线扫描不应权限失败：\(path)")
            case .tccProtectedSkipped(let path):
                XCTFail("完整基线扫描不应命中 TCC skip：\(path)")
            case .cacheDirTagged:
                break
            }
        }
        return CompleteCapture(summary: try XCTUnwrap(terminalSummary), nodes: nodes)
    }

    private func makeCancellationFixture(
        topLevelDirectoryCount: Int,
        depth: Int
    ) throws -> URL {
        let root = try makeRoot(prefix: "ProjectionCancellation")
        for index in 0..<topLevelDirectoryCount {
            var directory = root.appendingPathComponent(
                String(format: "branch-%04d", index),
                isDirectory: true
            )
            for level in 0..<depth {
                directory.appendPathComponent("level-\(level)", isDirectory: true)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writeFile(
                directory.appendingPathComponent("payload.bin"),
                byteCount: 1,
                seed: UInt8(truncatingIfNeeded: index)
            )
        }
        return root
    }

    private func makeRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(
        _ url: URL,
        byteCount: Int,
        seed: UInt8
    ) throws {
        let payload = Data(repeating: seed, count: byteCount)
        guard FileManager.default.createFile(atPath: url.path, contents: payload) else {
            throw FixtureError.couldNotCreateFile(url.path)
        }
    }
}

private actor CancellationOutcomeRecorder {
    private(set) var value: ScanProjectionIntegrationTests.CancellationOutcome?

    func store(_ outcome: ScanProjectionIntegrationTests.CancellationOutcome) {
        value = outcome
    }
}
