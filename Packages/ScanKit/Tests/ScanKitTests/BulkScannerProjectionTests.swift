import XCTest
@testable import ScanKit

/// v2026.07.16 扫描性能回归合同。
///
/// 事故根因不是 `getattrlistbulk` 遍历慢，而是普通/推荐/大文件扫描把数百万个
/// `FSNode` 逐批交给 UI task，再在 MainActor 上做一级聚合或 Top-N 过滤。底层已经完成后，
/// 无界事件积压仍可能让界面继续“扫描中”数分钟。
///
/// 这组测试钉死新的 ScanKit 后台投影边界：
/// - `.topLevel` 和 `.largeFiles` 不发布逐节点事件；
/// - 投影与同一静态 fixture 的完整 node stream 在容量、文件数和排序上严格一致；
/// - 宽目录只产生常数级控制事件，不能退化成“文件数约等于事件数”。
final class BulkScannerProjectionTests: XCTestCase {
    private struct Capture {
        let summary: ScanSummary
        let nodes: [FSNode]
        let eventCount: Int
        let nodeEventCount: Int
        let progressEventCount: Int
        let finishedEventCount: Int
    }

    private struct ExpectedTopLevel {
        var allocatedBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var isDirectory = true
    }

    private enum FixtureError: Error {
        case couldNotCreateFile(String)
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

    func test_topLevel不发布逐节点事件且一级聚合与完整流精确一致() async throws {
        let root = try makeProjectionFixture()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        // fixture 在两轮扫描之间保持只读；complete 是原始、无损节点合同，作为投影基线。
        let complete = await capture(root: root, delivery: .complete)
        let projected = await capture(root: root, delivery: .topLevel)

        XCTAssertEqual(projected.nodeEventCount, 0,
                       ".topLevel 不得把任何 node/nodes 事件交给上层重新聚合")
        XCTAssertEqual(projected.finishedEventCount, 1)
        XCTAssertEqual(projected.summary.fileCount, complete.summary.fileCount)
        XCTAssertEqual(projected.summary.directoryCount, complete.summary.directoryCount)
        XCTAssertEqual(projected.summary.totalAllocatedBytes,
                       complete.summary.totalAllocatedBytes)
        XCTAssertEqual(projected.summary.totalLogicalBytes,
                       complete.summary.totalLogicalBytes)

        let expected = expectedTopLevel(nodes: complete.nodes, rootPath: root.path)
        let entries: [ScanTopLevelEntry]
        guard case .topLevel(let value) = projected.summary.projection else {
            return XCTFail(".topLevel 扫描终态必须携带 ScanProjectionResult.topLevel")
        }
        entries = value

        XCTAssertEqual(entries.map(\.path), expected.keys.sorted(),
                       "一级投影必须稳定按路径排序，且不能漏掉根下直接文件或空目录")
        XCTAssertEqual(entries.count, 4)

        let byName = Dictionary(uniqueKeysWithValues: entries.map {
            (URL(fileURLWithPath: $0.path).lastPathComponent, $0)
        })
        XCTAssertEqual(byName["alpha"]?.fileCount, 2)
        XCTAssertEqual(byName["beta"]?.fileCount, 1)
        XCTAssertEqual(byName["empty"]?.fileCount, 0)
        XCTAssertEqual(byName["root.bin"]?.fileCount, 1)
        XCTAssertEqual(byName["alpha"]?.isDirectory, true)
        XCTAssertEqual(byName["beta"]?.isDirectory, true)
        XCTAssertEqual(byName["empty"]?.isDirectory, true)
        XCTAssertEqual(byName["root.bin"]?.isDirectory, false)
        XCTAssertEqual(byName["alpha"]?.hasChildren, true)
        XCTAssertEqual(byName["beta"]?.hasChildren, true)
        XCTAssertEqual(byName["empty"]?.hasChildren, false)
        XCTAssertEqual(byName["root.bin"]?.hasChildren, false)

        for entry in entries {
            let baseline = try XCTUnwrap(expected[entry.path])
            XCTAssertEqual(entry.allocatedBytes, baseline.allocatedBytes,
                           "allocated 聚合漂移 path=\(entry.path)")
            XCTAssertEqual(entry.logicalBytes, baseline.logicalBytes,
                           "logical 聚合漂移 path=\(entry.path)")
            XCTAssertEqual(entry.fileCount, baseline.fileCount,
                           "fileCount 聚合漂移 path=\(entry.path)")
            XCTAssertEqual(entry.isDirectory, baseline.isDirectory,
                           "一级节点类型漂移 path=\(entry.path)")
        }

        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.allocatedBytes },
                       projected.summary.totalAllocatedBytes,
                       "一级投影物理容量之和必须等于权威 summary")
        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.logicalBytes },
                       projected.summary.totalLogicalBytes,
                       "一级投影逻辑容量之和必须等于权威 summary")
        XCTAssertEqual(entries.reduce(0) { $0 + $1.fileCount },
                       projected.summary.fileCount,
                       "一级投影文件数之和必须等于权威 summary")
    }

    func test_POSIX根路径拼接与一级投影不会产生双斜杠或空结果() {
        let system = BulkScanner.entryPath(directoryPath: "/", name: "System")
        XCTAssertEqual(system, "/System")
        XCTAssertEqual(BulkScanner.topLevelBucketPath(for: system, rootPath: "/"), "/System")
        XCTAssertEqual(
            BulkScanner.topLevelBucketPath(for: "/System/Library/CoreServices", rootPath: "/"),
            "/System"
        )
        XCTAssertEqual(
            BulkScanner.entryPath(directoryPath: "/Users/example", name: "Library"),
            "/Users/example/Library"
        )
    }

    func test_largeFiles阈值TopN排序与结果硬上限精确() async throws {
        let root = try makeLargeFilesFixture()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let complete = await capture(root: root, delivery: .complete)
        let allFiles = complete.nodes.filter { !$0.isDirectory }
        XCTAssertEqual(allFiles.count, 9)

        // 按实际文件系统返回的 allocated size 选中位阈值，避免把 APFS block rounding
        // 或透明压缩假设硬编码进测试。fixture 不再变化，所以第二轮应得到相同 inode/容量。
        let ascendingSizes = allFiles.map(\.allocatedSize).sorted()
        let threshold = ascendingSizes[ascendingSizes.count / 2]
        let limit = 3
        let expected = allFiles
            .filter { $0.allocatedSize >= threshold }
            .sorted(by: largeFilePrecedes)
        XCTAssertGreaterThan(expected.count, limit,
                             "fixture 必须同时覆盖 threshold 过滤和 Top-N 截断")

        let projected = await capture(
            root: root,
            delivery: .largeFiles(
                minimumAllocatedBytes: threshold,
                maximumResults: limit
            )
        )

        XCTAssertEqual(projected.nodeEventCount, 0,
                       ".largeFiles 不得把未命中或未入选 Top-N 的节点发给 UI")
        XCTAssertEqual(projected.finishedEventCount, 1)
        XCTAssertEqual(projected.summary.fileCount, complete.summary.fileCount,
                       "候选过滤不能改变权威扫描文件总数")
        XCTAssertEqual(projected.summary.totalAllocatedBytes,
                       complete.summary.totalAllocatedBytes,
                       "候选过滤不能改变权威扫描容量")

        let results: [FSNode]
        guard case .largeFiles(let value) = projected.summary.projection else {
            return XCTFail(".largeFiles 扫描终态必须携带 ScanProjectionResult.largeFiles")
        }
        results = value

        XCTAssertEqual(results.count, limit, "结果数量必须硬顶 maximumResults")
        XCTAssertTrue(results.allSatisfy { !$0.isDirectory })
        XCTAssertTrue(results.allSatisfy { $0.allocatedSize >= threshold },
                      "低于阈值的文件不得进入候选")
        XCTAssertEqual(results.map(\.path), expected.prefix(limit).map(\.path),
                       "Top-N 必须按 allocated 降序、同大小按 path 升序稳定选择")
        XCTAssertEqual(results.map(\.allocatedSize),
                       expected.prefix(limit).map(\.allocatedSize))
        XCTAssertEqual(results.map(\.logicalSize),
                       expected.prefix(limit).map(\.logicalSize))
    }

    /// v2026.07.17 regression: the pruning threshold used to evaluate `maximumResults * 2`
    /// directly. `Int.max` is a valid public limit and must not trap before scanning one file.
    func test_largeFilesIntMaxLimitDoesNotOverflowPruningThreshold() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BulkProjection-IntMax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("one.bin").path
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(repeating: 0xA5, count: 4_096)
        ) else {
            throw FixtureError.couldNotCreateFile(path)
        }

        let projected = await capture(
            root: root,
            delivery: .largeFiles(
                minimumAllocatedBytes: 1,
                maximumResults: .max
            )
        )

        XCTAssertEqual(projected.finishedEventCount, 1)
        guard case .largeFiles(let rows) = projected.summary.projection else {
            return XCTFail("Int.max large-files scan must publish its terminal projection")
        }
        XCTAssertEqual(rows.map(\.path), [path])
    }

    func test_topLevel宽目录事件数量保持常数级而不随文件数线性增长() async throws {
        let fileCount = 2_048
        let root = try makeWideFixture(fileCount: fileCount)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let capture = await capture(root: root, delivery: .topLevel)

        XCTAssertEqual(capture.summary.fileCount, fileCount)
        XCTAssertEqual(capture.nodeEventCount, 0,
                       "宽目录投影若重新产生 nodes，百万节点仍会回到 MainActor 积压")
        XCTAssertEqual(capture.finishedEventCount, 1)
        XCTAssertLessThanOrEqual(capture.eventCount, 16,
                                 "两级目录只应产生少量 progress + 一个 finished，实际 \(capture.eventCount)")
        XCTAssertLessThan(capture.eventCount, fileCount / 64,
                          "控制事件数必须远低于文件数，不能随每个文件线性增长")

        guard case .topLevel(let entries) = capture.summary.projection else {
            return XCTFail("宽目录 .topLevel 终态缺少投影")
        }
        XCTAssertEqual(entries.count, 1,
                       "fixture 只有一个一级 bucket，投影大小应与可见行数而非文件数相关")
        XCTAssertEqual(entries.first?.path, root.appendingPathComponent("bucket").path)
        XCTAssertEqual(entries.first?.fileCount, fileCount)
        XCTAssertEqual(entries.first?.allocatedBytes, capture.summary.totalAllocatedBytes)
        XCTAssertEqual(entries.first?.logicalBytes, capture.summary.totalLogicalBytes)
        XCTAssertLessThanOrEqual(capture.progressEventCount, 2,
                                 "一个根目录和一个子目录最多各触发一次节流进度")
    }

    /// v2026.07.17 超宽一级目录合同：`.topLevel` 的内存与全部后代 inode 解耦，但其
    /// 权威结果仍必须包含每个真实一级可见行。当前 `ScanSummary.topLevel([row])` 是完整数组，
    /// 所以固定内存需要上层先引入分页/窗口化产品合同；ScanKit 不能用静默截断来“优化”。
    func test_topLevel超宽根不静默截断任何一级可见行() async throws {
        let directChildCount = 1_024
        let root = try makeDirectWideFixture(fileCount: directChildCount)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let capture = await capture(root: root, delivery: .topLevel)

        guard case .topLevel(let entries) = capture.summary.projection else {
            return XCTFail("超宽根 .topLevel 终态缺少投影")
        }
        XCTAssertEqual(capture.nodeEventCount, 0)
        XCTAssertEqual(capture.summary.fileCount, directChildCount)
        XCTAssertEqual(entries.count, directChildCount,
                       "未建立分页合同前，一级可见行必须完整交付，禁止用 Top-N/截断伪装固定内存")
        XCTAssertEqual(Set(entries.map(\.path)).count, directChildCount)
        XCTAssertEqual(entries.reduce(Int64(0)) { $0 + $1.allocatedBytes },
                       capture.summary.totalAllocatedBytes)
    }

    // MARK: - Capture

    private func capture(
        root: URL,
        delivery: BulkScanner.EventDelivery
    ) async -> Capture {
        var terminalSummary: ScanSummary?
        var nodes: [FSNode] = []
        var eventCount = 0
        var nodeEventCount = 0
        var progressEventCount = 0
        var finishedEventCount = 0

        for await event in BulkScanner(options: deterministicOptions).scan(
            root: root,
            delivery: delivery
        ) {
            eventCount += 1
            switch event {
            case .heartbeat:
                break
            case .node(let node):
                nodeEventCount += 1
                nodes.append(node)
            case .nodes(let batch):
                nodeEventCount += 1
                nodes.append(contentsOf: batch)
            case .progress:
                progressEventCount += 1
            case .finished(let summary):
                finishedEventCount += 1
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

        guard let terminalSummary else {
            XCTFail("扫描流必须产生唯一 finished summary")
            return Capture(
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
                eventCount: eventCount,
                nodeEventCount: nodeEventCount,
                progressEventCount: progressEventCount,
                finishedEventCount: finishedEventCount
            )
        }

        return Capture(
            summary: terminalSummary,
            nodes: nodes,
            eventCount: eventCount,
            nodeEventCount: nodeEventCount,
            progressEventCount: progressEventCount,
            finishedEventCount: finishedEventCount
        )
    }

    // MARK: - Expected projection

    private func expectedTopLevel(
        nodes: [FSNode],
        rootPath: String
    ) -> [String: ExpectedTopLevel] {
        var result: [String: ExpectedTopLevel] = [:]
        for node in nodes {
            guard let bucketPath = topLevelPath(for: node.path, rootPath: rootPath) else {
                continue
            }
            var aggregate = result[bucketPath] ?? ExpectedTopLevel()
            if !node.isDirectory {
                aggregate.allocatedBytes += node.allocatedSize
                aggregate.logicalBytes += node.logicalSize
                aggregate.fileCount += 1
            }
            if node.path == bucketPath {
                aggregate.isDirectory = node.isDirectory
            }
            result[bucketPath] = aggregate
        }
        return result
    }

    private func topLevelPath(for absolutePath: String, rootPath: String) -> String? {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard absolutePath.hasPrefix(prefix), absolutePath.count > prefix.count else {
            return nil
        }
        let relative = absolutePath.dropFirst(prefix.count)
        guard let first = relative.split(separator: "/", maxSplits: 1).first else {
            return nil
        }
        return rootPath == "/" ? "/" + first : rootPath + "/" + first
    }

    private func largeFilePrecedes(_ lhs: FSNode, _ rhs: FSNode) -> Bool {
        if lhs.allocatedSize != rhs.allocatedSize {
            return lhs.allocatedSize > rhs.allocatedSize
        }
        return lhs.path < rhs.path
    }

    // MARK: - Fixtures

    private func makeProjectionFixture() throws -> URL {
        let root = try makeRoot(prefix: "BulkProjection-TopLevel")
        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        let alphaDeep = alpha.appendingPathComponent("deep", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        for directory in [alphaDeep, beta, empty] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try writeDeterministicFile(alpha.appendingPathComponent("a.bin"), size: 4 * 1_024, seed: 1)
        try writeDeterministicFile(alphaDeep.appendingPathComponent("deep.bin"), size: 8 * 1_024, seed: 2)
        try writeDeterministicFile(beta.appendingPathComponent("b.bin"), size: 12 * 1_024, seed: 3)
        try writeDeterministicFile(root.appendingPathComponent("root.bin"), size: 16 * 1_024, seed: 4)
        return root
    }

    private func makeLargeFilesFixture() throws -> URL {
        let root = try makeRoot(prefix: "BulkProjection-LargeFiles")
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)

        // 两个 128 KiB 文件同时覆盖同大小时的 path 稳定排序。
        let sizes = [16, 32, 48, 64, 96, 128, 128, 160, 192].map { $0 * 1_024 }
        for (index, size) in sizes.enumerated() {
            let parent = index.isMultiple(of: 2) ? left : right
            try writeDeterministicFile(
                parent.appendingPathComponent(String(format: "candidate-%02d.bin", index)),
                size: size,
                seed: UInt8(index + 1)
            )
        }
        return root
    }

    private func makeWideFixture(fileCount: Int) throws -> URL {
        let root = try makeRoot(prefix: "BulkProjection-Wide")
        let bucket = root.appendingPathComponent("bucket", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let payload = Data([0xA5])
        for index in 0..<fileCount {
            let path = bucket.appendingPathComponent(String(format: "entry-%05d.bin", index)).path
            guard FileManager.default.createFile(atPath: path, contents: payload) else {
                throw FixtureError.couldNotCreateFile(path)
            }
        }
        return root
    }

    private func makeDirectWideFixture(fileCount: Int) throws -> URL {
        let root = try makeRoot(prefix: "BulkProjection-DirectWide")
        let payload = Data([0x5A])
        for index in 0..<fileCount {
            let path = root.appendingPathComponent(String(format: "entry-%05d.bin", index)).path
            guard FileManager.default.createFile(atPath: path, contents: payload) else {
                throw FixtureError.couldNotCreateFile(path)
            }
        }
        return root
    }

    private func makeRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeDeterministicFile(
        _ url: URL,
        size: Int,
        seed: UInt8
    ) throws {
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<size {
                base[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed))
            }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: bytes) else {
            throw FixtureError.couldNotCreateFile(url.path)
        }
    }
}
