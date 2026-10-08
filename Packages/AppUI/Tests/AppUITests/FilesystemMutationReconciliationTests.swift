import Darwin
import XCTest
import ScanKit
@testable import AppUI

/// v2026.10.08: exercise actual regular-file identities and a full prune before Undo.
/// Fixtures stay under NSTemporaryDirectory; these tests never invoke real Trash or HOME data.
@MainActor
final class FilesystemMutationReconciliationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mutation-reconciliation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seed(_ coordinator: ScanCoordinator, root: URL) async throws -> [FSNode] {
        let ledger = InodeSet(tracksPaths: true)
        let scanner = BulkScanner(options: .init(respectTCCSkipList: false))
        let session = scanner.scanSession(root: root, delivery: .complete, pathNamespace: nil,
                                         topLevelProjectionRootPath: nil, allocationLedger: ledger)
        var nodes: [FSNode] = []
        var summary: ScanSummary?
        for await event in session.events {
            switch event {
            case .node(let node): nodes.append(node)
            case .nodes(let batch): nodes.append(contentsOf: batch)
            case .finished(let result): summary = result
            default: break
            }
        }
        await session.waitForTermination()
        let result = try XCTUnwrap(summary)
        var aggregates: [String: (bytes: Int64, fileCount: Int)] = [root.path: (0, 0)]
        var edges: [String: Set<String>] = [:]
        var leaves: [String: Int64] = [:]
        for node in nodes {
            let parent = node.url.deletingLastPathComponent().path
            edges[parent, default: []].insert(node.path)
            if node.isDirectory {
                if aggregates[node.path] == nil { aggregates[node.path] = (0, 0) }
            } else if node.isRegularFile {
                leaves[node.path] = node.allocatedSize
                var cursor = parent
                while cursor == root.path || cursor.hasPrefix(root.path + "/") {
                    let old = aggregates[cursor] ?? (0, 0)
                    aggregates[cursor] = (old.bytes + node.allocatedSize, old.fileCount + 1)
                    if cursor == root.path { break }
                    cursor = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
                }
            }
        }
        let rows = nodes.filter { $0.url.deletingLastPathComponent().path == root.path }.map { node in
            RowItem(id: node.path, url: node.url, title: node.url.lastPathComponent,
                isDirectory: node.isDirectory, bytes: aggregates[node.path]?.bytes ?? node.allocatedSize,
                logicalBytes: aggregates[node.path]?.bytes ?? node.logicalSize,
                fileCount: aggregates[node.path]?.fileCount ?? (node.isRegularFile ? 1 : 0),
                verdict: .confirm, rejection: .ok, hasChildren: !(edges[node.path]?.isEmpty ?? true))
        }
        coordinator._seedForTesting(snapshot: .init(categoryID: "fixture", rows: rows,
            totalBytes: result.totalAllocatedBytes, scannedFileCount: result.fileCount,
            isFinished: true, elapsed: 1), currentRootPath: root.path, isScanning: false,
            buckets: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.bytes) }),
            dirIndexFull: aggregates, fileLeavesFull: leaves, childEdges: edges,
            totalBytes: result.totalAllocatedBytes, scannedFiles: result.fileCount,
            allocationSnapshot: ledger.allocationSnapshot(), largeFileMinBytes: 1_048_576)
        coordinator._seedLargeFileLeavesForTesting(nodes.filter { $0.isRegularFile && $0.allocatedSize >= 1_048_576 }
            .map { (path: $0.path, bytes: $0.allocatedSize) })
        return nodes
    }

    func testFullPruneThenRestoreRebuildsEveryResultSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let restored = root.appendingPathComponent("restored.bin")
        let kept = root.appendingPathComponent("keep.bin")
        try Data(repeating: 0x51, count: 2_097_152).write(to: restored)
        try Data(repeating: 0x52, count: 2_097_152).write(to: kept)
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        _ = try await seed(coordinator, root: root)
        let expectedBytes = coordinator.snapshot.totalBytes
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [restored.path])
        await coordinator.pruneDeleted(paths: [restored.path])
        XCTAssertFalse(coordinator.snapshot.rows.contains { $0.id == restored.path })
        XCTAssertFalse(coordinator._fileLeavesKeysForTesting().contains(restored.path))
        XCTAssertEqual(coordinator.largeFiles(minSizeMB: 1, sortKey: .sizeDesc).map(\.path), [kept.path])

        // The fixture already occupies the restored destination; no filesystem delete or
        // Trash bypass is needed to reproduce the post-restore producer/consumer boundary.
        await coordinator.reconcileRestoredPaths([restored.path])
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [restored.path, kept.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        XCTAssertEqual(coordinator._dirIndexAggForTesting(root.path)?.fileCount, 2)
        XCTAssertEqual(coordinator._childEdgesForTesting()[root.path], [restored.path, kept.path])
        XCTAssertTrue(coordinator._fileLeavesKeysForTesting().contains(restored.path))
        XCTAssertEqual(Set(coordinator.largeFiles(minSizeMB: 1, sortKey: .sizeDesc).map(\.path)), [restored.path, kept.path])
        for sort in TreeSortKey.allCases {
            XCTAssertEqual(Set(coordinator.directChildren(of: root.path, sortedBy: sort).map(\.path)), [restored.path, kept.path])
        }
    }

    func testRenamedRestoreReintroducesActualDestinationAndKeepsOriginalTombstone() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let original = root.appendingPathComponent("item.bin")
        let renamed = root.appendingPathComponent("item (restored).bin")
        try Data(repeating: 0x61, count: 8192).write(to: original)
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        _ = try await seed(coordinator, root: root)
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [original.path])
        await coordinator.pruneDeleted(paths: [original.path])
        try FileManager.default.moveItem(at: original, to: renamed)
        await coordinator.reconcileRestoredPaths([renamed.path])
        XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [renamed.path])
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        XCTAssertEqual(coordinator._childEdgesForTesting()[root.path], [renamed.path])
        XCTAssertFalse(coordinator._isDeletedTombstonedForTesting(renamed.path))
        XCTAssertTrue(coordinator._isDeletedTombstonedForTesting(original.path))
    }

    func testRestoreNotificationAliasMapsIntoTheCurrentScanNamespace() async throws {
        let root = try fixture()
        let alias = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-alias")
        defer {
            try? FileManager.default.removeItem(at: alias) // best-effort fixture cleanup
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("item.bin")
        try Data(repeating: 0x63, count: 8192).write(to: file)
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        _ = try await seed(coordinator, root: root)
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [file.path])
        await coordinator.pruneDeleted(paths: [file.path])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        await coordinator.reconcileRestoredPaths([alias.appendingPathComponent("item.bin").path])
        XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [file.path])
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        XCTAssertFalse(coordinator._isDeletedTombstonedForTesting(file.path))
    }

    func testPruningTheHardlinkOwnerTransfersAllocationWithoutARefreshFirst() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = a.appendingPathComponent("item.bin")
        try Data(repeating: 0x72, count: 8192).write(to: file)
        try FileManager.default.linkItem(at: file, to: b.appendingPathComponent("alias.bin"))
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        let nodes = try await seed(coordinator, root: root)
        let bytes = coordinator.snapshot.totalBytes
        let owner = try XCTUnwrap(nodes.first { $0.isRegularFile && $0.allocatedSize > 0 })
        try FileManager.default.removeItem(atPath: owner.path) // owned temporary fixture only
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [owner.path])
        await coordinator.pruneDeleted(paths: [owner.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, bytes)
        XCTAssertEqual(coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes }, bytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(coordinator.snapshot.totalBytes, bytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
    }

    func testHardlinkRefreshAndOwnerRemovalPreserveGlobalAllocation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let source = a.appendingPathComponent("file.bin")
        let alias = b.appendingPathComponent("link.bin")
        try Data(repeating: 0x71, count: 8192).write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        let nodes = try await seed(coordinator, root: root)
        let expectedBytes = coordinator.snapshot.totalBytes
        let owner = try XCTUnwrap(nodes.first { $0.isRegularFile && $0.allocatedSize > 0 })
        for directory in [a, b, a, b] {
            await coordinator.rescanSubtree(at: directory.path)
            XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
            XCTAssertEqual(coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes }, expectedBytes)
            XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        }
        try FileManager.default.removeItem(atPath: owner.path) // owned temporary fixture only
        await coordinator.rescanSubtree(at: owner.url.deletingLastPathComponent().path)
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [owner.path])
        await coordinator.pruneDeleted(paths: [owner.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes }, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        let remainingDirectory = owner.path.hasPrefix(a.path + "/") ? b : a
        await coordinator.rescanSubtree(at: remainingDirectory.path)
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
    }

    func testNewHardlinkInvalidatesSparseBaselineInsteadOfDoubleCounting() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = a.appendingPathComponent("file.bin")
        try Data(repeating: 0x55, count: 8192).write(to: file)
        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: session)
        let originalBytes = coordinator.snapshot.totalBytes
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        try FileManager.default.linkItem(at: file, to: b.appendingPathComponent("new-link.bin"))
        let completedSession = coordinator.currentScanSessionID
        await coordinator.rescanSubtree(at: b.path)
        try await waitForPrimaryScan(coordinator, replacing: completedSession)
        XCTAssertEqual(coordinator.snapshot.totalBytes, originalBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
    }

    private func waitForPrimaryScan(_ coordinator: ScanCoordinator, replacing session: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if coordinator.currentScanSessionID != session,
               coordinator.snapshot.isFinished, !coordinator.isScanning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The authoritative primary scan did not settle")
    }

    func testUndoRestoresAnEntirePrunedMultiRootResult() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let file = root.appendingPathComponent("item.bin")
        try Data(repeating: 0x41, count: 8192).write(to: file)
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        _ = try await seed(coordinator, root: root)
        let bytes = coordinator.snapshot.totalBytes
        coordinator._seedForTesting(currentRootPath: ScanCoordinator.multiRootSentinelPath,
            perRootStaging: [root.path: .init(rootPath: root.path, title: root.lastPathComponent,
                bytes: bytes, fileCount: 1, isFinished: true)])
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [root.path])
        await coordinator.pruneDeleted(paths: [root.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, 0)
        XCTAssertTrue(coordinator._perRootTreeRowsForTesting(.sizeDesc).isEmpty)
        await coordinator.reconcileRestoredPaths([root.path])
        // v2026.10.08 review: Tree/totals passing does not prove the List source recovered.
        XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [file.path])
        XCTAssertEqual(coordinator._bucketsKeysForTesting(), [file.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, bytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        XCTAssertEqual(coordinator._perRootTreeRowsForTesting(.sizeDesc).map(\.path), [root.path])
        XCTAssertEqual(coordinator._childEdgesForTesting()[root.path], [file.path])
    }

    func testMultiRootRestoreMergesChildrenWithoutReplacingAnUnaffectedRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let restored = a.appendingPathComponent("restored.bin")
        let kept = b.appendingPathComponent("kept.bin")
        try Data(repeating: 0x51, count: 8192).write(to: restored)
        try Data(repeating: 0x52, count: 16384).write(to: kept)
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        let nodes = try await seed(coordinator, root: root)
        let rows = nodes.filter(\.isRegularFile).map { node in
            RowItem(id: node.path, url: node.url, title: node.url.lastPathComponent,
                    isDirectory: false, bytes: node.allocatedSize, logicalBytes: node.logicalSize,
                    fileCount: 1, verdict: .confirm, rejection: .ok)
        }
        let bytes = coordinator.snapshot.totalBytes
        let staging = try Dictionary(uniqueKeysWithValues: [a, b].map { url in
            let row = try XCTUnwrap(rows.first { $0.url.deletingLastPathComponent().path == url.path })
            return (url.path, ScanCoordinator.PerRootProgress(rootPath: url.path, title: url.lastPathComponent,
                bytes: row.bytes, fileCount: 1, isFinished: true))
        })
        coordinator._seedForTesting(snapshot: .init(categoryID: "fixture.multi", rows: rows,
            totalBytes: bytes, scannedFileCount: 2, isFinished: true, elapsed: 1),
            currentRootPath: ScanCoordinator.multiRootSentinelPath,
            buckets: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.bytes) }),
            snapshotTreeRows: [:], perRootStaging: staging)

        for deleted in [restored.path, a.path] {
            await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [deleted])
            await coordinator.pruneDeleted(paths: [deleted])
            XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [kept.path])
            await coordinator.reconcileRestoredPaths([deleted])
            XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [restored.path, kept.path])
            XCTAssertEqual(Set(coordinator._bucketsKeysForTesting()), [restored.path, kept.path])
            XCTAssertEqual(coordinator.snapshot.totalBytes, bytes)
            XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
            XCTAssertEqual(Set(coordinator._perRootTreeRowsForTesting(.sizeDesc).map(\.path)), [a.path, b.path])
        }
    }

    func testRefreshBuildsSnapshotTreeWhenThePreviousProjectionWasEmpty() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        _ = try await seed(coordinator, root: root)
        // An interrupted empty scan can have no terminal Tree projection yet. Availability
        // must follow the scan mode and new rows, rather than whether a cache existed before.
        coordinator._seedForTesting(snapshot: .init(categoryID: "fixture", rows: [], totalBytes: 0,
            scannedFileCount: 0, isFinished: false, elapsed: 1), snapshotTreeRows: [:])
        let file = root.appendingPathComponent("arrived.bin")
        try Data(repeating: 0x61, count: 8192).write(to: file)
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [file.path])
        for sort in TreeSortKey.allCases {
            XCTAssertEqual(coordinator._snapshotTreeRowsForTesting(sort).map(\.path), [file.path])
        }
    }

    func testSpecialEntriesStayVisibleWithoutBecomingRegularFilesDuringRefresh() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let file = root.appendingPathComponent("regular.bin")
        let fifo = root.appendingPathComponent("pipe")
        let symlink = root.appendingPathComponent("alias")
        try Data(repeating: 0x42, count: 8192).write(to: file)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("missing-target"))
        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        let nodes = try await seed(coordinator, root: root)
        XCTAssertEqual(nodes.filter(\.isRegularFile).count, 1)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        XCTAssertEqual(coordinator._dirIndexAggForTesting(root.path)?.fileCount, 1)
        let children = coordinator.directChildren(of: root.path, sortedBy: .sizeDesc)
        XCTAssertEqual(Set(children.map(\.path)), [file.path, fifo.path, symlink.path])
        XCTAssertEqual(children.reduce(0) { $0 + $1.fileCount }, 1)
        await coordinator.pruneDeleted(paths: [fifo.path, symlink.path])
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        await coordinator.reconcileRestoredPaths([fifo.path, symlink.path])
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
        XCTAssertEqual(Set(coordinator.directChildren(of: root.path, sortedBy: .sizeDesc).map(\.path)),
                       [file.path, fifo.path, symlink.path])
    }
}
