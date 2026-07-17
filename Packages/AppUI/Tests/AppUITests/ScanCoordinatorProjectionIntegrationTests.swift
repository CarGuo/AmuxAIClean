import XCTest
@testable import AppUI
@testable import ScanKit

/// v2026.07.16 扫描投影链路的 AppUI 集成回归。
///
/// 性能事故的核心不是底层遍历错误，而是默认、推荐和 Large Files 把每个 FSNode
/// 重新送到 MainActor 聚合，导致 producer 已结束后 UI 仍消费积压数分钟。本套测试同时
/// 校验权威终态和消费边界：投影结果必须与完整扫描一致，但增量 node 交付必须为 0。
/// fixture 全部位于 NSTemporaryDirectory；测试只创建和清理自己的目录，不启动 App，
/// 不访问或删除真实 HOME 数据。
@MainActor
final class ScanCoordinatorProjectionIntegrationTests: XCTestCase {
    private struct CompleteBaseline {
        let summary: ScanSummary
        let nodes: [FSNode]
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case missingTerminalSummary(String)
        case unexpectedEvent(String)

        var description: String {
            switch self {
            case .missingTerminalSummary(let root):
                return "扫描未产生 finished summary：\(root)"
            case .unexpectedEvent(let message):
                return message
            }
        }
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

    // MARK: - Single root

    func test_默认单根投影保持完整终态且MainActor不接收逐节点() async throws {
        let root = try makeTemporaryRoot(prefix: "Single")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let alpha = root.appendingPathComponent("alpha/deep", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try writeFiles(count: 384, byteCount: 37, into: alpha, prefix: "alpha")
        try writeFiles(count: 96, byteCount: 91, into: beta, prefix: "beta")
        try Data(repeating: 0xA1, count: 517)
            .write(to: root.appendingPathComponent("root.bin"))

        let baseline = try await captureComplete(root: root)
        XCTAssertEqual(baseline.summary.fileCount, 481)

        let coordinator = ScanCoordinator(home: root.path)
        coordinator.scan(category: .makeCustom(url: root), includeHidden: true)
        try await waitForTerminal(coordinator)

        XCTAssertTrue(coordinator.snapshot.isComplete)
        XCTAssertEqual(coordinator.snapshot.totalBytes, baseline.summary.totalAllocatedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, baseline.summary.fileCount)
        XCTAssertEqual(coordinator.snapshot.rows.reduce(Int64(0)) { $0 + $1.bytes },
                       baseline.summary.totalAllocatedBytes)
        XCTAssertEqual(coordinator.snapshot.rows.reduce(0) { $0 + $1.fileCount },
                       baseline.summary.fileCount)
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.title)),
                       Set(["alpha", "beta", "empty", "root.bin"]))

        let rowsByName = Dictionary(uniqueKeysWithValues: coordinator.snapshot.rows.map {
            ($0.title, $0)
        })
        XCTAssertEqual(rowsByName["alpha"]?.fileCount, 384)
        XCTAssertEqual(rowsByName["beta"]?.fileCount, 96)
        XCTAssertEqual(rowsByName["empty"]?.fileCount, 0)
        XCTAssertEqual(rowsByName["root.bin"]?.fileCount, 1)
        XCTAssertEqual(rowsByName["root.bin"]?.isDirectory, false)
        XCTAssertEqual(rowsByName["alpha"]?.hasChildren, true)
        XCTAssertEqual(rowsByName["empty"]?.hasChildren, false)
        XCTAssertEqual(rowsByName["root.bin"]?.hasChildren, false)
        let rootFileTreeRow = try XCTUnwrap(
            coordinator.directChildren(of: root.path).first { $0.title == "root.bin" }
        )
        XCTAssertFalse(rootFileTreeRow.isDirectory)
        XCTAssertFalse(rootFileTreeRow.hasChildren)
        let producerElapsed = try XCTUnwrap(coordinator.lastProducerTerminalElapsed)
        let drainLag = try XCTUnwrap(coordinator.lastConsumerDrainLag)
        XCTAssertGreaterThanOrEqual(producerElapsed, 0)
        XCTAssertGreaterThanOrEqual(drainLag, 0)
        XCTAssertLessThanOrEqual(drainLag, max(3, producerElapsed * 0.2),
                                 "有界投影不得在 producer 结束后留下长 consumer backlog")
        XCTAssertEqual(coordinator._incrementalNodeDeliveryCountForTesting(), 0,
                       "默认扫描不得退回逐 FSNode 的 MainActor ingest")
    }

    // MARK: - Large Files

    func test_LargeFiles后台TopN保持容量与候选正确且MainActor不接收逐节点() async throws {
        let root = try makeTemporaryRoot(prefix: "LargeFiles")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<12 {
            let parent = index.isMultiple(of: 2) ? root : nested
            let bytes = 1_113 + (index * 8_197)
            try Data(repeating: UInt8(index), count: bytes)
                .write(to: parent.appendingPathComponent(String(format: "candidate-%02d.bin", index)))
        }

        let baseline = try await captureComplete(root: root)
        let files = baseline.nodes.filter { !$0.isDirectory }
        XCTAssertEqual(files.count, 12)
        let allocatedSizes = files.map(\.allocatedSize).sorted()
        let threshold = allocatedSizes[allocatedSizes.count / 2]
        let expected = files
            .filter { $0.allocatedSize >= threshold }
            .sorted {
                if $0.allocatedSize != $1.allocatedSize {
                    return $0.allocatedSize > $1.allocatedSize
                }
                return $0.path < $1.path
            }
        XCTAssertGreaterThan(expected.count, 1)

        let category = ScanCategory(
            id: "test.projection.large",
            title: "Large fixture",
            subtitle: root.path,
            rootPath: root.path,
            defaultVerdict: .confirm,
            kind: .largeFiles
        )
        let coordinator = ScanCoordinator(home: root.path)
        coordinator.scan(
            category: category,
            includeHidden: true,
            largeFileMinBytes: threshold
        )
        try await waitForTerminal(coordinator)

        XCTAssertTrue(coordinator.snapshot.isComplete)
        XCTAssertTrue(coordinator.snapshot.rows.isEmpty,
                      "Large Files 只维护后台 Top-N，不应构建通用主列表")
        XCTAssertEqual(coordinator.snapshot.totalBytes, baseline.summary.totalAllocatedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, baseline.summary.fileCount)
        XCTAssertEqual(coordinator.largeFileCollectedCount, expected.count)
        XCTAssertEqual(
            coordinator.largeFiles(minSizeMB: 0, sortKey: .sizeDesc).map(\.path),
            expected.map(\.path)
        )
        XCTAssertEqual(coordinator._incrementalNodeDeliveryCountForTesting(), 0,
                       "Large Files 不得在 MainActor 上逐节点筛阈值或维护 Top-N")
    }

    // MARK: - Recommended multi-root

    func test_推荐多根投影保持逐根与全局终态且MainActor不接收逐节点() async throws {
        let home = try makeTemporaryRoot(prefix: "Recommended")
        addTeardownBlock { try FileManager.default.removeItem(at: home) }

        let categories = ScanCategories.recommended(home: home.path)
        var expectedByRoot: [String: ScanSummary] = [:]
        for (rootIndex, category) in categories.enumerated() {
            let root = category.rootURL
            let nested = root.appendingPathComponent("bucket/deep", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try writeFiles(
                count: 32 + rootIndex,
                byteCount: 73 + rootIndex,
                into: nested,
                prefix: "root-\(rootIndex)"
            )
            try Data(repeating: UInt8(rootIndex), count: 601 + rootIndex)
                .write(to: root.appendingPathComponent("direct.bin"))
            expectedByRoot[root.path] = try await captureComplete(root: root).summary
        }

        let coordinator = ScanCoordinator(home: home.path)
        coordinator.scanRecommended(includeHidden: true)
        try await waitForTerminal(coordinator, timeout: 15)

        let expectedBytes = expectedByRoot.values.reduce(Int64(0)) {
            $0 + $1.totalAllocatedBytes
        }
        let expectedFiles = expectedByRoot.values.reduce(0) { $0 + $1.fileCount }
        XCTAssertTrue(coordinator.snapshot.isComplete)
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, expectedFiles)
        XCTAssertEqual(coordinator.perRootProgress.count, categories.count)
        XCTAssertTrue(coordinator.perRootProgress.values.allSatisfy(\.isFinished))

        for category in categories {
            let expected = try XCTUnwrap(expectedByRoot[category.rootPath])
            let actual = try XCTUnwrap(coordinator.perRootProgress[category.rootPath])
            XCTAssertEqual(actual.bytes, expected.totalAllocatedBytes,
                           "逐根容量漂移：\(category.rootPath)")
            XCTAssertEqual(actual.fileCount, expected.fileCount,
                           "逐根文件数漂移：\(category.rootPath)")
        }

        let rootRows = coordinator.directChildren(
            of: ScanCoordinator.multiRootSentinelPath,
            sortedBy: .sizeDesc
        )
        XCTAssertEqual(Set(rootRows.map(\.path)), Set(categories.map(\.rootPath)))
        XCTAssertEqual(rootRows.reduce(Int64(0)) { $0 + $1.bytes }, expectedBytes)
        XCTAssertEqual(rootRows.reduce(0) { $0 + $1.fileCount }, expectedFiles)
        XCTAssertEqual(coordinator._incrementalNodeDeliveryCountForTesting(), 0,
                       "推荐多根不得通过 MultiRootScanner 转发逐 FSNode 到 MainActor")
    }

    // MARK: - Tree on-demand cache

    func test_Tree首次测量后切换排序只做内存投影且不发起第二轮扫描() async throws {
        let root = try makeTemporaryRoot(prefix: "TreeSortCache")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let now = Date()
        let layout: [(name: String, byteCount: Int, age: TimeInterval)] = [
            ("zeta.bin", 48 * 1024, 10),
            ("alpha.bin", 2 * 1024, 300),
            ("middle.bin", 17 * 1024, 90)
        ]
        for entry in layout {
            let file = parent.appendingPathComponent(entry.name)
            try Data(repeating: 0x7B, count: entry.byteCount).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-entry.age)],
                ofItemAtPath: file.path
            )
        }

        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: false)
        coordinator.scan(category: .makeCustom(url: root), includeHidden: true)
        try await waitForTerminal(coordinator)

        let sizeDescKey = "\(parent.path)|\(TreeSortKey.sizeDesc.rawValue)"
        XCTAssertTrue(coordinator.directChildren(of: parent.path, sortedBy: .sizeDesc).isEmpty,
                      "首次 cache miss 应同步返回空，并只派发一轮后台测量")
        let sizeDesc = try await waitForTreeFetch(
            coordinator,
            path: parent.path,
            cacheKey: sizeDescKey
        )
        XCTAssertEqual(sizeDesc.map(\.title), ["zeta.bin", "middle.bin", "alpha.bin"])
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty)

        let cacheVersionAfterMeasurement = coordinator.childrenCacheVersion
        let measuredRows = Set(sizeDesc)

        // 首轮测量收敛后让原路径从文件系统消失。后续排序若仍试图重新测量，立即返回值、
        // in-flight 或 cache version 至少一项会暴露；正确实现只对已测量 rows 做内存排序。
        let movedParent = root.appendingPathComponent("Parent-moved", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: movedParent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))

        let nameAsc = coordinator.directChildren(of: parent.path, sortedBy: .nameAsc)
        let mtimeAsc = coordinator.directChildren(of: parent.path, sortedBy: .mtimeAsc)
        let sizeAsc = coordinator.directChildren(of: parent.path, sortedBy: .sizeAsc)

        XCTAssertEqual(Set(nameAsc), measuredRows)
        XCTAssertEqual(Set(mtimeAsc), measuredRows)
        XCTAssertEqual(Set(sizeAsc), measuredRows)
        XCTAssertEqual(nameAsc.map(\.title), ["alpha.bin", "middle.bin", "zeta.bin"])
        XCTAssertEqual(mtimeAsc.map(\.title), ["alpha.bin", "middle.bin", "zeta.bin"])
        XCTAssertEqual(sizeAsc.map(\.title), ["alpha.bin", "middle.bin", "zeta.bin"])
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty,
                      "排序切换不得为同一路径新增任何文件系统扫描任务")
        XCTAssertEqual(coordinator.childrenCacheVersion, cacheVersionAfterMeasurement,
                       "排序派生 cache 是同步内存投影，不应伪装成新测量并触发 revision")

        let cache = coordinator._treeChildrenCacheForTesting()
        for sortKey in [TreeSortKey.sizeDesc, .nameAsc, .mtimeAsc, .sizeAsc] {
            XCTAssertNotNil(cache["\(parent.path)|\(sortKey.rawValue)"])
        }
    }

    func test_终态snapshot根行为空时directChildren不隐式重扫文件系统() async throws {
        let root = try makeTemporaryRoot(prefix: "FinishedEmptyRoot")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        // 磁盘故意不为空，用来区分“权威终态就是空 rows”和“cache miss 后擅自重扫”。
        // Large Files 等模块的 finished snapshot 合法地不维护通用主列表；Tree 不能据此
        // 猜测结果缺失并开启第二轮递归 I/O。
        try Data(repeating: 0x4D, count: 8 * 1024)
            .write(to: root.appendingPathComponent("exists-on-disk.bin"))

        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: false)
        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "test.finished.empty",
                rows: [],
                totalBytes: 8 * 1024,
                scannedFileCount: 1,
                isFinished: true,
                elapsed: 0.1,
                isComplete: true
            ),
            currentRootPath: root.path,
            isScanning: false
        )
        let cacheVersionBefore = coordinator.childrenCacheVersion

        XCTAssertTrue(coordinator.directChildren(of: root.path, sortedBy: .sizeDesc).isEmpty)
        XCTAssertTrue(coordinator.directChildren(of: root.path, sortedBy: .nameAsc).isEmpty)
        XCTAssertTrue(coordinator.directChildren(of: root.path, sortedBy: .mtimeDesc).isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty,
                      "finished root 的空 rows 是权威终态，不能转成后台 cache-miss 扫描")
        XCTAssertTrue(coordinator._treeChildrenCacheForTesting().isEmpty,
                      "未请求真实子目录时不应建立任何 Tree 文件系统测量 cache")
        XCTAssertEqual(coordinator.childrenCacheVersion, cacheVersionBefore)
    }

    // MARK: - Root normalization

    func test_minimalNonOverlappingRoots去重标准化并折叠祖先覆盖() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ProjectionRoots-\(UUID().uuidString)", isDirectory: true)
        let alpha = base.appendingPathComponent("alpha", isDirectory: true)
        let alphaChild = alpha.appendingPathComponent("child", isDirectory: true)
        let alphabet = base.appendingPathComponent("alphabet", isDirectory: true)
        let beta = base.appendingPathComponent("group/../beta", isDirectory: true)

        let result = ScanCoordinator.minimalNonOverlappingRoots([
            alphaChild,
            alpha,
            URL(fileURLWithPath: alpha.path + "/", isDirectory: true),
            alphabet,
            beta,
            base.appendingPathComponent("beta", isDirectory: true)
        ])

        XCTAssertEqual(
            result.map { $0.standardizedFileURL.path },
            [alpha.path, alphabet.path, beta.standardizedFileURL.path],
            "祖先应替代后代；重复/尾斜杠/点段应合并；相似前缀不能误当祖先"
        )
    }

    func test_minimalNonOverlappingRoots遇到文件系统根时只保留根() {
        let result = ScanCoordinator.minimalNonOverlappingRoots([
            URL(fileURLWithPath: "/Users/example/Library", isDirectory: true),
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/", isDirectory: true)
        ])
        XCTAssertEqual(result.map(\.path), ["/"])
    }

    // MARK: - Helpers

    private func makeTemporaryRoot(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GSYClean-Projection-\(prefix)-\(UUID().uuidString)",
                                    isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFiles(
        count: Int,
        byteCount: Int,
        into directory: URL,
        prefix: String
    ) throws {
        let payload = Data(repeating: 0x5A, count: byteCount)
        for index in 0..<count {
            try payload.write(
                to: directory.appendingPathComponent("\(prefix)-\(index).bin")
            )
        }
    }

    private func captureComplete(root: URL) async throws -> CompleteBaseline {
        var terminalSummary: ScanSummary?
        var nodes: [FSNode] = []

        for await event in BulkScanner(options: deterministicOptions).scan(
            root: root,
            delivery: .complete
        ) {
            switch event {
            case .heartbeat, .progress, .cacheDirTagged:
                break
            case .node(let node):
                nodes.append(node)
            case .nodes(let batch):
                nodes.append(contentsOf: batch)
            case .finished(let summary):
                terminalSummary = summary
            case .failed(let error):
                throw FixtureError.unexpectedEvent("临时 fixture 根扫描失败：\(error)")
            case .incomplete(let issue):
                throw FixtureError.unexpectedEvent("临时 fixture 不应产生 incomplete：\(issue)")
            case .permissionDenied(let path):
                throw FixtureError.unexpectedEvent("临时 fixture 不应权限失败：\(path)")
            case .tccProtectedSkipped(let path):
                throw FixtureError.unexpectedEvent("临时 fixture 不应命中 TCC skip：\(path)")
            }
        }

        guard let terminalSummary else {
            throw FixtureError.missingTerminalSummary(root.path)
        }
        return CompleteBaseline(summary: terminalSummary, nodes: nodes)
    }

    private func waitForTerminal(
        _ coordinator: ScanCoordinator,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.isScanning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(coordinator.isScanning, "扫描在 \(timeout)s 内未收敛到终态")
        XCTAssertTrue(coordinator.snapshot.isFinished, "扫描结束后 snapshot 必须进入 finished")
    }

    private func waitForTreeFetch(
        _ coordinator: ScanCoordinator,
        path: String,
        cacheKey: String,
        timeout: TimeInterval = 5
    ) async throws -> [TreeRow] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = coordinator._treeChildrenCacheForTesting()[cacheKey]
            let pathPrefix = "\(path)|"
            let hasInFlight = coordinator._treeChildrenInFlightForTesting().contains {
                $0.hasPrefix(pathPrefix)
            }
            if let rows, !rows.isEmpty, !hasInFlight {
                return rows
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Tree 按需测量在 \(timeout)s 内未收敛：\(path)")
        return []
    }
}
