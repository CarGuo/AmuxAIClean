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

    func test_topLevel真实遍历先投影Data物理根再生成公开一级bucket() async throws {
        let root = try makeRoot(prefix: "ProjectionPathMapping")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let dataRoot = root
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Volumes", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        let dataUsers = dataRoot.appendingPathComponent("Users", isDirectory: true)
        let dataLibrary = dataRoot.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataUsers.appendingPathComponent("alice", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dataLibrary.appendingPathComponent("Caches", isDirectory: true),
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
        let pathNamespace = ScanPathNamespace(
            physicalRoot: dataRoot.path,
            publicRoot: root.path
        )

        // 同一只读 fixture 的完整流是无损基线；不能把 APFS allocated block rounding
        // 或透明压缩假设硬编码进测试。
        let baseline = try await captureComplete(root: dataRoot)

        var nodeEventCount = 0
        var terminalSummary: ScanSummary?
        for await event in BulkScanner(options: deterministicOptions).scan(
            root: dataRoot,
            delivery: .topLevel,
            pathNamespace: pathNamespace
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
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.completionStatus, .complete)
        XCTAssertEqual(summary.totalAllocatedBytes, baseline.summary.totalAllocatedBytes)
        XCTAssertEqual(summary.totalLogicalBytes, baseline.summary.totalLogicalBytes)

        guard case .topLevel(let entries) = summary.projection else {
            return XCTFail("映射扫描终态必须携带 topLevel projection")
        }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let usersPath = root.appendingPathComponent("Users").path
        let libraryPath = root.appendingPathComponent("Library").path

        XCTAssertEqual(Set(byPath.keys), Set([usersPath, libraryPath]),
                       "若先折叠物理 bucket 再投影，Data 前缀会泄漏到公开一级行")
        XCTAssertEqual(byPath[usersPath]?.fileCount, 1)
        XCTAssertEqual(byPath[libraryPath]?.fileCount, 1)
        let baselineByPath = Dictionary(uniqueKeysWithValues: baseline.nodes.map { ($0.path, $0) })
        let userFile = try XCTUnwrap(baselineByPath[dataUsers.appendingPathComponent("alice/user.bin").path])
        let libraryFile = try XCTUnwrap(baselineByPath[dataLibrary.appendingPathComponent("Caches/cache.bin").path])
        XCTAssertEqual(byPath[usersPath]?.allocatedBytes, userFile.allocatedSize)
        XCTAssertEqual(byPath[usersPath]?.logicalBytes, userFile.logicalSize)
        XCTAssertEqual(byPath[libraryPath]?.allocatedBytes, libraryFile.allocatedSize)
        XCTAssertEqual(byPath[libraryPath]?.logicalBytes, libraryFile.logicalSize)
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
            pathNamespace: ScanPathNamespace(
                physicalRoot: physicalRoot.path,
                publicRoot: publicRoot
            ),
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

    /// v2026.07.18 regression: the Data-root fallback used to concatenate `/` with an already
    /// slash-prefixed suffix, yielding `//System`. Top-level bucketing then observed an empty first
    /// component and silently dropped every non-firmlink Data directory.
    func test_pathNamespaceRootFallbackIsBidirectionalAndNeverCreatesDoubleSlash() {
        let namespace = ScanPathNamespace(
            physicalRoot: "/System/Volumes/Data",
            publicRoot: "/",
            mappings: [
                ScanPathPrefixMapping(
                    sourcePrefix: "/System/Volumes/Data/usr/local",
                    destinationPrefix: "/usr/local"
                )
            ]
        )

        XCTAssertEqual(namespace.publicPath(forPhysicalPath: "/System/Volumes/Data"), "/")
        XCTAssertEqual(
            namespace.publicPath(forPhysicalPath: "/System/Volumes/Data/System/Library"),
            "/System/Library"
        )
        XCTAssertEqual(
            namespace.physicalPath(forPublicPath: "/System/Library"),
            "/System/Volumes/Data/System/Library"
        )
        XCTAssertEqual(
            namespace.physicalPath(forPublicPath: "/usr/local/bin"),
            "/System/Volumes/Data/usr/local/bin",
            "longest public prefix must beat the root fallback"
        )
        XCTAssertEqual(
            BulkScanner.topLevelBucketPath(
                for: namespace.publicPath(
                    forPhysicalPath: "/System/Volumes/Data/MobileSoftwareUpdate/a.pkg"
                ),
                rootPath: "/"
            ),
            "/MobileSoftwareUpdate"
        )
    }

    func test_pathNamespaceRejectsNonRootRelativeAliasInsteadOfGuessingReverseIdentity() {
        let ambiguous = ScanPathPrefixMapping(
            sourcePrefix: "/Data/A",
            destinationPrefix: "/X"
        )
        let namespace = ScanPathNamespace(
            physicalRoot: "/Data",
            publicRoot: "/",
            mappings: [ambiguous]
        )

        XCTAssertEqual(namespace.rejectedMappings, [ambiguous])
        XCTAssertEqual(namespace.publicPath(forPhysicalPath: "/Data/A/file"), "/A/file")
        XCTAssertEqual(namespace.physicalPath(forPublicPath: "/X/file"), "/Data/X/file")
        XCTAssertEqual(
            namespace.physicalPath(
                forPublicPath: namespace.publicPath(forPhysicalPath: "/Data/A/file")
            ),
            "/Data/A/file",
            "fail-closed 后必须保留唯一可逆的物理 identity"
        )
    }

    func test_pathNamespaceRejectsConflictingPublicAliasesButAcceptsRedundantFirmlinkRule() {
        let first = ScanPathPrefixMapping(
            sourcePrefix: "/Data/A",
            destinationPrefix: "/Shared"
        )
        let second = ScanPathPrefixMapping(
            sourcePrefix: "/Data/B",
            destinationPrefix: "/Shared"
        )
        let firmlink = ScanPathPrefixMapping(
            sourcePrefix: "/Data/usr/local",
            destinationPrefix: "/usr/local"
        )
        let namespace = ScanPathNamespace(
            physicalRoot: "/Data",
            publicRoot: "/",
            mappings: [first, second, firmlink]
        )

        XCTAssertEqual(namespace.rejectedMappings, [first, second])
        XCTAssertTrue(namespace.mappings.contains(firmlink))
        XCTAssertEqual(namespace.publicPath(forPhysicalPath: "/Data/usr/local/bin"), "/usr/local/bin")
        XCTAssertEqual(namespace.physicalPath(forPublicPath: "/usr/local/bin"), "/Data/usr/local/bin")
    }

    func test_physicalDataStylePathUsesPublicNamespaceForTCCSkipAndEvidence() async throws {
        let physicalRoot = try makeRoot(prefix: "ProjectionTCCPhysicalRoot")
        addTeardownBlock { try FileManager.default.removeItem(at: physicalRoot) }
        let mail = physicalRoot.appendingPathComponent("Library/Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        try writeFile(mail.appendingPathComponent("message.emlx"), byteCount: 1_024, seed: 0x61)

        let publicRoot = NSHomeDirectory()
        let namespace = ScanPathNamespace(
            physicalRoot: physicalRoot.path,
            publicRoot: publicRoot
        )
        let options = ScanOptions(
            includeHidden: true,
            concurrency: 1,
            maxConcurrency: 1,
            mediaAware: false,
            respectTCCSkipList: true
        )

        var summary: ScanSummary?
        var tccPaths: [String] = []
        for await event in BulkScanner(options: options).scan(
            root: physicalRoot,
            delivery: .topLevel,
            pathNamespace: namespace,
            topLevelProjectionRootPath: publicRoot
        ) {
            if case .tccProtectedSkipped(let path) = event { tccPaths.append(path) }
            if case .finished(let value) = event { summary = value }
        }

        let terminal = try XCTUnwrap(summary)
        XCTAssertEqual(tccPaths, [publicRoot + "/Library/Mail"])
        XCTAssertEqual(terminal.tccProtectedSkippedCount, 1)
        XCTAssertEqual(terminal.fileCount, 0, "TCC subtree must be skipped before reading its file")
        XCTAssertEqual(terminal.incompleteIssues.map(\.path), [publicRoot + "/Library/Mail"])
    }

    func test_rootFailureIsPublishedInPublicNamespace() async throws {
        let fixture = try makeRoot(prefix: "ProjectionMissingPhysicalRoot")
        addTeardownBlock { try FileManager.default.removeItem(at: fixture) }
        let missingPhysicalRoot = fixture.appendingPathComponent("missing", isDirectory: true)
        let publicRoot = "/public-test-root"
        let namespace = ScanPathNamespace(
            physicalRoot: missingPhysicalRoot.path,
            publicRoot: publicRoot
        )

        var failedPaths: [String] = []
        var summary: ScanSummary?
        for await event in BulkScanner(options: deterministicOptions).scan(
            root: missingPhysicalRoot,
            delivery: .topLevel,
            pathNamespace: namespace,
            topLevelProjectionRootPath: publicRoot
        ) {
            if case .failed(.cannotEnumerate(let path, _, _)) = event {
                failedPaths.append(path)
            }
            if case .finished(let value) = event { summary = value }
        }

        XCTAssertEqual(failedPaths, [publicRoot])
        XCTAssertEqual(summary?.incompleteIssues.map(\.path), [publicRoot])
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

        let session = BulkScanner(options: deterministicOptions).scanSession(
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
            await withTaskCancellationHandler {
                for await event in session.events {
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
            } onCancel: {
                session.cancel()
            }
            await session.waitForTermination()
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
