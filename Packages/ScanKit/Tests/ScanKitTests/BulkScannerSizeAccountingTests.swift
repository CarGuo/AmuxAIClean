import XCTest
import Darwin
@testable import ScanKit

/// Size-accounting contracts consumed by AppUI.
///
/// `ScanSummary` and the flattened `.node` / `.nodes` stream must describe the
/// same unique bytes. Otherwise a coordinator that aggregates nodes can show a
/// value very different from the scanner's final summary.
final class BulkScannerSizeAccountingTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BulkScannerSizeAccounting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func collect(
        root: URL,
        options: ScanOptions = ScanOptions(mediaAware: false),
        delivery: BulkScanner.EventDelivery = .complete
    ) async -> (nodes: [FSNode], summary: ScanSummary?) {
        var nodes: [FSNode] = []
        var summary: ScanSummary?
        for await event in BulkScanner(options: options).scan(root: root, delivery: delivery) {
            switch event {
            case .node(let node):
                nodes.append(node)
            case .nodes(let batch):
                nodes.append(contentsOf: batch)
            case .finished(let value):
                summary = value
            default:
                break
            }
        }
        return (nodes, summary)
    }

    private func collectLegacy(scanner: ScanKit.Scanner, root: URL) async
        -> (nodes: [FSNode], summary: ScanSummary?) {
        var nodes: [FSNode] = []
        var summary: ScanSummary?
        for await event in scanner.scan(root: root) {
            switch event {
            case .node(let node):
                nodes.append(node)
            case .nodes(let batch):
                nodes.append(contentsOf: batch)
            case .finished(let value):
                summary = value
            default:
                break
            }
        }
        return (nodes, summary)
    }

    func test_sparseFileKeepsLogicalAndAllocatedBytesSeparate() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeFixture(root) }

        let sparse = root.appendingPathComponent("Docker.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        let logicalSize: UInt64 = 2 * 1_024 * 1_024 * 1_024 * 1_024
        try handle.truncate(atOffset: logicalSize)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 4_096))
        try handle.synchronize()
        try handle.close()

        let result = await collect(root: root)
        let node = try XCTUnwrap(result.nodes.first { $0.path == sparse.path })
        let summary = try XCTUnwrap(result.summary)

        XCTAssertEqual(node.logicalSize, Int64(logicalSize),
                       "Sparse image logical capacity must remain truthful; do not cap it to volume size")
        XCTAssertGreaterThan(node.allocatedSize, 0)
        XCTAssertLessThan(node.allocatedSize, node.logicalSize / 1_024,
                          "A sparse image must expose its much smaller on-disk allocation separately")
        XCTAssertEqual(summary.totalLogicalBytes, node.logicalSize)
        XCTAssertEqual(summary.totalAllocatedBytes, node.allocatedSize)
    }

    func test_hardlinkDedupAppliesToNodeStreamAndSummary() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeFixture(root) }

        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 0x3C, count: 16_384).write(to: original)
        let alias = root.appendingPathComponent("alias.bin")
        XCTAssertEqual(link(original.path, alias.path), 0, "link(2) failed errno=\(errno)")

        let result = await collect(root: root)
        let summary = try XCTUnwrap(result.summary)
        let files = result.nodes.filter { !$0.isDirectory }

        XCTAssertEqual(files.count, 2, "Both directory entries remain visible")
        XCTAssertEqual(files.map(\.allocatedSize).reduce(0, +), summary.totalAllocatedBytes,
                       "Node consumers and ScanSummary must use the same inode-deduplicated physical total")
        XCTAssertEqual(files.map(\.logicalSize).reduce(0, +), summary.totalLogicalBytes,
                       "Node consumers and ScanSummary must use the same inode-deduplicated logical total")
        XCTAssertEqual(files.filter { $0.allocatedSize > 0 }.count, 1,
                       "Only one directory entry may contribute bytes for a shared inode")
        XCTAssertGreaterThan(summary.dedupedHardlinkBytes, 0)
    }

    func test_legacyScannerHardlinkNodeStreamMatchesSummary() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeFixture(root) }

        let original = root.appendingPathComponent("legacy-original.bin")
        try Data(repeating: 0x29, count: 16_384).write(to: original)
        let alias = root.appendingPathComponent("legacy-alias.bin")
        XCTAssertEqual(link(original.path, alias.path), 0, "link(2) failed errno=\(errno)")

        let result = await collectLegacy(scanner: ScanKit.Scanner(), root: root)
        let summary = try XCTUnwrap(result.summary)
        let files = result.nodes.filter { !$0.isDirectory }
        XCTAssertEqual(files.map(\.allocatedSize).reduce(0, +), summary.totalAllocatedBytes)
        XCTAssertEqual(files.map(\.logicalSize).reduce(0, +), summary.totalLogicalBytes)
        XCTAssertEqual(files.filter { $0.allocatedSize > 0 }.count, 1)
    }

    func test_legacyScannerReuseStartsWithFreshInodeIdentitySet() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeFixture(root) }
        try Data(repeating: 0x61, count: 8_192).write(to: root.appendingPathComponent("payload.bin"))

        let scanner = ScanKit.Scanner()
        let firstResult = await collectLegacy(scanner: scanner, root: root)
        let secondResult = await collectLegacy(scanner: scanner, root: root)
        let first = try XCTUnwrap(firstResult.summary)
        let second = try XCTUnwrap(secondResult.summary)
        XCTAssertGreaterThan(first.totalAllocatedBytes, 0)
        XCTAssertEqual(second.totalAllocatedBytes, first.totalAllocatedBytes,
                       "Reusing Scanner must not treat the second scan as duplicate data from the first scan")
        XCTAssertEqual(second.totalLogicalBytes, first.totalLogicalBytes)
    }

    func test_directoryNodesDoNotContributeRawMetadataBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeFixture(root) }

        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 0x7A, count: 8_192).write(to: child.appendingPathComponent("payload.bin"))

        let result = await collect(root: root)
        let directories = result.nodes.filter(\.isDirectory)
        XCTAssertFalse(directories.isEmpty)
        XCTAssertTrue(directories.allSatisfy { $0.allocatedSize == 0 && $0.logicalSize == 0 },
                      "Directory subtree totals come from descendant files; raw directory inode bytes must not be added again")
    }

    func test_unknownInodeIsNeverDeduplicatedAsARealIdentity() {
        let set = InodeSet()
        XCTAssertTrue(set.insertIfFirstSeen(device: 0, inode: 0))
        XCTAssertTrue(set.insertIfFirstSeen(device: 0, inode: 0),
                      "Missing metadata must not collapse unrelated files into the same synthetic inode")
    }

    func test_specialFileEntriesLikeFIFODoNotCountAsRegularFilesOrCandidates() async throws {
        let root = try makeTemporaryDirectory()
        defer { removeFixture(root) }

        let regular = root.appendingPathComponent("regular.bin")
        try Data(repeating: 0x42, count: 4_096).write(to: regular)
        let fifo = root.appendingPathComponent("pipe.fifo")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0, "mkfifo failed errno=\(errno)")

        let completeResult = await collect(root: root)
        let completeSummary = try XCTUnwrap(completeResult.summary)
        XCTAssertEqual(completeSummary.fileCount, 1, "FIFO special files must not be counted in regular fileCount")
        XCTAssertEqual(completeSummary.totalLogicalBytes, 4_096)

        let candidatesResult = await collect(
            root: root,
            options: ScanOptions(mediaAware: false),
            delivery: .fileCandidates(minimumLogicalBytes: 0)
        )
        let candidateSummary = try XCTUnwrap(candidatesResult.summary)
        guard case .fileCandidates(let candidates) = candidateSummary.projection else {
            return XCTFail("Expected .fileCandidates projection")
        }
        XCTAssertEqual(candidates.map(\.path), [regular.path], "FIFO must never enter duplicate/file candidates")

        let largeResult = await collect(
            root: root,
            options: ScanOptions(mediaAware: false),
            delivery: .largeFiles(minimumAllocatedBytes: 1, maximumResults: 10)
        )
        let largeSummary = try XCTUnwrap(largeResult.summary)
        guard case .largeFiles(let largeFiles) = largeSummary.projection else {
            return XCTFail("Expected .largeFiles projection")
        }
        XCTAssertEqual(largeFiles.map(\.path), [regular.path], "FIFO must never enter largeFiles projection")
    }

    func test_followSymlinksTopLevelDirectorySymlinkMarksProjectionRowAsDirectory() async throws {
        let outer = try makeTemporaryDirectory()
        defer { removeFixture(outer) }

        let scanRoot = outer.appendingPathComponent("scan-root", isDirectory: true)
        let targetDir = outer.appendingPathComponent("external-target", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 8_192).write(to: targetDir.appendingPathComponent("nested.bin"))

        let linkInRoot = scanRoot.appendingPathComponent("linked-dir")
        try FileManager.default.createSymbolicLink(at: linkInRoot, withDestinationURL: targetDir)

        let result = await collect(
            root: scanRoot,
            options: ScanOptions(
                followSymlinks: true,
                mediaAware: false
            ),
            delivery: .topLevel
        )
        let summary = try XCTUnwrap(result.summary)
        guard case .topLevel(let rows) = summary.projection else {
            return XCTFail("Expected .topLevel projection")
        }
        let row = try XCTUnwrap(rows.first { $0.path == linkInRoot.path })
        XCTAssertTrue(row.isDirectory, "Top-level symlink resolved to a directory under followSymlinks must be marked isDirectory")
        XCTAssertEqual(row.logicalBytes, 8_192)
        XCTAssertEqual(row.fileCount, 1)
    }

    private func removeFixture(_ url: URL,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("Failed to remove scan fixture \(url.path): \(error)", file: file, line: line)
        }
    }
}
