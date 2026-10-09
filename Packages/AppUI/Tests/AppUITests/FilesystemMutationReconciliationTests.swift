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

    // v2026.10.09: use the production shallow primary scan, whose allocation catalog survives
    // without a deep index. Partial absence must preserve published members and one baseline.
    func testPartialShallowRefreshPreservesRowsAndAllocationThroughRecovery() async throws {
        if geteuid() == 0 { throw XCTSkip("Root bypasses the fixture's POSIX permissions") }
        let root = try fixture()
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        defer {
            chmod(root.path, 0o700)
            chmod(blocked.path, 0o700)
            try? FileManager.default.removeItem(at: root) // best-effort owned fixture cleanup
        }
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let visible = root.appendingPathComponent("visible.bin")
        let kept = blocked.appendingPathComponent("kept.bin")
        try Data(repeating: 0x51, count: 8192).write(to: visible)
        try Data(repeating: 0x52, count: 16384).write(to: kept)
        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: session)
        let originalBytes = coordinator.snapshot.totalBytes
        let blockedBytes = try XCTUnwrap(coordinator.snapshot.rows.first { $0.id == blocked.path }).bytes
        XCTAssertNil(coordinator._dirIndexAggForTesting(root.path))
        // The async enumeration API returns values without publishing a cache. Exercise the
        // actual View getter and wait for its owned producer/projection before denying access.
        let expansionDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < expansionDeadline {
            let rows = coordinator.directChildren(of: blocked.path, sortedBy: .sizeDesc)
            if rows.map(\.path) == [kept.path],
               !coordinator.isFetchingChildren(of: blocked.path, sortedBy: .sizeDesc) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.directChildren(of: blocked.path).map(\.path), [kept.path])
        XCTAssertFalse(coordinator.isFetchingChildren(of: blocked.path, sortedBy: .sizeDesc))

        XCTAssertEqual(chmod(root.path, 0o000), 0)
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [visible.path, blocked.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, originalBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        XCTAssertTrue(coordinator.incompleteScanIssues.contains { $0.reason == .permissionDenied })
        for sort in TreeSortKey.allCases {
            XCTAssertEqual(Set(coordinator._snapshotTreeRowsForTesting(sort).map(\.path)), [visible.path, blocked.path])
            XCTAssertEqual(Set(coordinator.directChildren(of: root.path, sortedBy: sort).map(\.path)), [visible.path, blocked.path])
            XCTAssertEqual(coordinator.directChildren(of: blocked.path, sortedBy: sort).map(\.path), [kept.path])
        }

        XCTAssertEqual(chmod(root.path, 0o700), 0)
        try Data(repeating: 0x53, count: 32768).write(to: visible)
        var metadata = stat()
        XCTAssertEqual(lstat(visible.path, &metadata), 0)
        let visibleBytes = Int64(metadata.st_blocks) * 512
        XCTAssertEqual(chmod(blocked.path, 0o000), 0)
        // A readable sibling can grow while an old subtree remains unobservable. The merged
        // directory ledger, not max(old root, incoming root), owns this positive delta.
        for _ in 0..<2 {
            await coordinator.rescanSubtree(at: root.path)
            XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [visible.path, blocked.path])
            XCTAssertEqual(coordinator.snapshot.totalBytes, visibleBytes + blockedBytes)
            XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
            XCTAssertEqual(coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes }, coordinator.snapshot.totalBytes)
            XCTAssertEqual(coordinator._dirIndexAggForTesting(root.path)?.bytes, coordinator.snapshot.totalBytes)
        }
        XCTAssertEqual(chmod(blocked.path, 0o700), 0)
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(coordinator.snapshot.totalBytes, visibleBytes + blockedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        XCTAssertTrue(coordinator.incompleteScanIssues.isEmpty)
        try FileManager.default.removeItem(at: visible) // owned temporary fixture only
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [blocked.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, blockedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 1)
    }

    func testPartialRefreshChargesAnUnobservedHardlinkOwnerCorrectionOnce() async throws {
        if geteuid() == 0 { throw XCTSkip("Root bypasses the fixture's POSIX permissions") }
        let root = try fixture()
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        defer {
            chmod(a.path, 0o700)
            chmod(b.path, 0o700)
            try? FileManager.default.removeItem(at: root) // best-effort owned fixture cleanup
        }
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let source = a.appendingPathComponent("linked.bin")
        let alias = b.appendingPathComponent("linked.bin")
        try Data(repeating: 0x54, count: 8192).write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: session)
        let owner = try XCTUnwrap(coordinator.snapshot.rows.first { $0.bytes > 0 }).url
        let readableAlias = owner.path == a.path ? alias : source
        try Data(repeating: 0x55, count: 32768).write(to: readableAlias)
        var metadata = stat()
        XCTAssertEqual(lstat(readableAlias.path, &metadata), 0)
        let expectedBytes = Int64(metadata.st_blocks) * 512
        XCTAssertEqual(chmod(owner.path, 0o000), 0)
        for _ in 0..<2 {
            await coordinator.rescanSubtree(at: root.path)
            XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
            XCTAssertEqual(coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes }, expectedBytes)
            XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
            XCTAssertEqual(coordinator._dirIndexAggForTesting(root.path)?.bytes, expectedBytes)
        }
        XCTAssertEqual(chmod(owner.path, 0o700), 0)
        await coordinator.rescanSubtree(at: root.path)
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
    }

    // v2026.10.09: Undo and explicit refresh must replay the original enumeration options,
    // including after a later primary scan installs a different configuration.
    func testUndoAndRefreshRetainHiddenFileOptionsAcrossPrimarySessions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let visible = root.appendingPathComponent("visible.bin")
        let hidden = root.appendingPathComponent(".excluded.bin")
        let hiddenDirectory = root.appendingPathComponent(".excluded-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 8192).write(to: visible)
        try Data(repeating: 0x62, count: 16384).write(to: hidden)
        try Data(repeating: 0x63, count: 32768).write(to: hiddenDirectory.appendingPathComponent("nested.bin"))
        let coordinator = ScanCoordinator(home: root.path)
        for includeHidden in [false, true, false] {
            let session = coordinator.currentScanSessionID
            coordinator.scan(category: .makeCustom(url: root), includeHidden: includeHidden)
            try await waitForPrimaryScan(coordinator, replacing: session)
            let expectedRows: Set<String> = includeHidden ? [visible.path, hidden.path, hiddenDirectory.path] : [visible.path]
            let expectedBytes = coordinator.snapshot.totalBytes
            let expectedFiles = coordinator.snapshot.scannedFileCount
            XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), expectedRows)
            await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [visible.path])
            await coordinator.pruneDeleted(paths: [visible.path])
            await coordinator.reconcileRestoredPaths([visible.path])
            XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), expectedRows)
            XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
            XCTAssertEqual(coordinator.snapshot.scannedFileCount, expectedFiles)
            XCTAssertFalse(coordinator._isDeletedTombstonedForTesting(visible.path))
            await coordinator.rescanSubtree(at: root.path)
            XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), expectedRows)
            XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
            XCTAssertEqual(coordinator.snapshot.scannedFileCount, expectedFiles)
        }
    }

    func testMultiRootUndoRetainsPrimaryHiddenFileOptions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let categories = ScanCategories.recommended(home: root.path)
        for category in categories {
            try FileManager.default.createDirectory(at: category.rootURL, withIntermediateDirectories: true)
            try Data(repeating: 0x71, count: 8192).write(to: category.rootURL.appendingPathComponent("visible.bin"))
            try Data(repeating: 0x72, count: 16384).write(to: category.rootURL.appendingPathComponent(".excluded.bin"))
        }
        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scanRecommended(includeHidden: false)
        try await waitForPrimaryScan(coordinator, replacing: session)
        let expectedRows = Set(coordinator.snapshot.rows.map(\.id))
        let expectedBytes = coordinator.snapshot.totalBytes
        let expectedFiles = coordinator.snapshot.scannedFileCount
        let restored = categories[0].rootURL.appendingPathComponent("visible.bin")
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [restored.path])
        await coordinator.pruneDeleted(paths: [restored.path])
        await coordinator.reconcileRestoredPaths([restored.path])
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), expectedRows)
        XCTAssertEqual(coordinator.snapshot.totalBytes, expectedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, expectedFiles)
        XCTAssertFalse(coordinator.snapshot.rows.contains { $0.url.lastPathComponent.hasPrefix(".") })
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

    func testPrunedHardlinkRestoreReconcilesWithoutFullRebaseline() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let linkA = a.appendingPathComponent("shared.bin")
        let linkB = b.appendingPathComponent("shared.bin")
        let unrelatedDeleted = root.appendingPathComponent("deleted.bin")
        try Data(repeating: 0x41, count: 16384).write(to: linkA)
        try FileManager.default.linkItem(at: linkA, to: linkB)
        try Data(repeating: 0x42, count: 8192).write(to: unrelatedDeleted)

        let coordinator = ScanCoordinator(home: root.path)
        let initialSession = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: initialSession)
        let activeSession = coordinator.currentScanSessionID

        var st = stat()
        XCTAssertEqual(lstat(linkA.path, &st), 0)
        let sharedBytes = Int64(st.st_blocks) * 512

        // Prune both hardlinks and an unrelated file; remove linkB and unrelatedDeleted from disk,
        // leaving linkA in place to simulate Undo restoring linkA while linkB remains in Trash.
        try FileManager.default.removeItem(at: unrelatedDeleted) // owned temporary fixture only
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(
            paths: [linkA.path, linkB.path, unrelatedDeleted.path]
        )
        await coordinator.pruneDeleted(
            paths: [linkA.path, linkB.path, unrelatedDeleted.path]
        )
        XCTAssertEqual(coordinator.snapshot.totalBytes, 0)
        XCTAssertTrue(coordinator._isDeletedTombstonedForTesting(unrelatedDeleted.path))

        await coordinator.reconcileRestoredPaths([linkA.path])
        XCTAssertEqual(
            coordinator.currentScanSessionID,
            activeSession,
            "Restoring a previously scanned hardlink must not trigger a full rebaseline scan"
        )
        XCTAssertEqual(coordinator.snapshot.totalBytes, sharedBytes)
        XCTAssertTrue(
            coordinator._isDeletedTombstonedForTesting(unrelatedDeleted.path),
            "Incremental restore reconciliation must preserve unrelated deletion tombstones"
        )
    }

    func testPartialShallowRefreshReflectsDeletedAndShrunkReadableSiblingsWhilePreservingBlockedSubtree() async throws {
        if geteuid() == 0 { throw XCTSkip("Root bypasses the fixture's POSIX permissions") }
        let root = try fixture()
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        defer {
            chmod(blocked.path, 0o700)
            try? FileManager.default.removeItem(at: root) // best-effort owned fixture cleanup
        }
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let shrinkable = root.appendingPathComponent("shrink.bin")
        let removable = root.appendingPathComponent("remove.bin")
        let keptInBlocked = blocked.appendingPathComponent("kept.bin")
        try Data(repeating: 0x61, count: 65536).write(to: shrinkable)
        try Data(repeating: 0x62, count: 32768).write(to: removable)
        try Data(repeating: 0x63, count: 16384).write(to: keptInBlocked)

        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: session)
        let blockedBytes = try XCTUnwrap(coordinator.snapshot.rows.first { $0.id == blocked.path }).bytes

        // Shrink one readable root child and delete the other while `blocked` is unreadable.
        try Data(repeating: 0x61, count: 4096).write(to: shrinkable)
        try FileManager.default.removeItem(at: removable) // owned temporary fixture only
        var shrunkStat = stat()
        XCTAssertEqual(lstat(shrinkable.path, &shrunkStat), 0)
        let shrunkBytes = Int64(shrunkStat.st_blocks) * 512

        XCTAssertEqual(chmod(blocked.path, 0o000), 0)
        await coordinator.rescanSubtree(at: root.path)

        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [shrinkable.path, blocked.path])
        XCTAssertEqual(coordinator.snapshot.totalBytes, shrunkBytes + blockedBytes)
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        for sort in TreeSortKey.allCases {
            XCTAssertEqual(
                Set(coordinator.directChildren(of: root.path, sortedBy: sort).map(\.path)),
                [shrinkable.path, blocked.path]
            )
        }
    }

    func testOnDemandTreeDisclosureRespectsRetainedHiddenFilePolicyAndHardlinkAllocation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let linkA = a.appendingPathComponent("shared.bin")
        let linkB = b.appendingPathComponent("shared.bin")
        let hiddenInA = a.appendingPathComponent(".hidden.bin")
        try Data(repeating: 0x71, count: 16384).write(to: linkA)
        try FileManager.default.linkItem(at: linkA, to: linkB)
        try Data(repeating: 0x72, count: 32768).write(to: hiddenInA)

        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root), includeHidden: false)
        try await waitForPrimaryScan(coordinator, replacing: session)

        let childrenA = await coordinator.directChildrenAsync(of: a.path, sortedBy: .sizeDesc)
        let childrenB = await coordinator.directChildrenAsync(of: b.path, sortedBy: .sizeDesc)
        XCTAssertEqual(childrenA.map(\.path), [linkA.path], "On-demand Tree expansion must honor includeHidden: false")
        XCTAssertEqual(childrenB.map(\.path), [linkB.path])

        let totalChildBytes = childrenA.reduce(0) { $0 + $1.bytes } + childrenB.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(
            totalChildBytes,
            coordinator.snapshot.totalBytes,
            "On-demand Tree expansion must deduplicate non-owner hardlinks against the primary allocation catalog"
        )
    }

    func testRescanSubtreeRebaselinesWhenMovedSingleLinkBecomesMultiLinkInsideRefreshedDirectory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let soloInA = a.appendingPathComponent("solo.bin")
        try Data(repeating: 0x51, count: 16384).write(to: soloInA)

        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: session)
        let initialBytes = coordinator.snapshot.totalBytes
        XCTAssertGreaterThan(initialBytes, 0)

        let movedInB = b.appendingPathComponent("moved.bin")
        let secondLinkInB = b.appendingPathComponent("second.bin")
        try FileManager.default.moveItem(at: soloInA, to: movedInB)
        try FileManager.default.linkItem(at: movedInB, to: secondLinkInB)

        let completedSession = coordinator.currentScanSessionID
        await coordinator.rescanSubtree(at: b.path)
        try await waitForPrimaryScan(coordinator, replacing: completedSession)

        let rowsByPath = Dictionary(uniqueKeysWithValues: coordinator.snapshot.rows.map { ($0.id, $0) })
        XCTAssertEqual(rowsByPath[a.path]?.bytes, 0)
        XCTAssertEqual(rowsByPath[b.path]?.bytes, initialBytes)
        XCTAssertEqual(
            coordinator.snapshot.totalBytes,
            initialBytes,
            "Moving a single-link file from A to B and linking it inside B must not double-count A's stale allocation"
        )
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
    }

    func testPruneDeletedNonOwnerHardlinkAliasInsideUnexpandedDirectoryPreservesSiblingLogicalSize() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let linkA = a.appendingPathComponent("shared.bin")
        let linkB = b.appendingPathComponent("shared.bin")
        try Data(repeating: 0x61, count: 4096).write(to: linkA)
        try FileManager.default.linkItem(at: linkA, to: linkB)
        try Data(repeating: 0x62, count: 8192).write(to: a.appendingPathComponent("other.bin"))
        try Data(repeating: 0x63, count: 8192).write(to: b.appendingPathComponent("other.bin"))

        let coordinator = ScanCoordinator(home: root.path)
        let session = coordinator.currentScanSessionID
        coordinator.scan(category: .makeCustom(url: root))
        try await waitForPrimaryScan(coordinator, replacing: session)

        // Whichever directory was visited second holds the non-owner alias (0 logical bytes for shared.bin + 8192 for other.bin).
        let aliasDirectoryRow = try XCTUnwrap(
            coordinator.snapshot.rows.first { ($0.id == a.path || $0.id == b.path) && $0.logicalBytes == 8192 }
        )
        XCTAssertEqual(aliasDirectoryRow.fileCount, 2)
        let aliasFile = URL(fileURLWithPath: aliasDirectoryRow.id).appendingPathComponent("shared.bin")

        try FileManager.default.removeItem(at: aliasFile) // owned temporary fixture only
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [aliasFile.path])
        await coordinator.pruneDeleted(paths: [aliasFile.path])

        let afterAliasDirectoryRow = try XCTUnwrap(
            coordinator.snapshot.rows.first { $0.id == aliasDirectoryRow.id }
        )
        XCTAssertEqual(
            afterAliasDirectoryRow.logicalBytes,
            8192,
            "Pruning a non-owner hardlink alias inside an unexpanded directory must not subtract logical bytes from sibling files"
        )
        XCTAssertEqual(afterAliasDirectoryRow.bytes, aliasDirectoryRow.bytes)
        XCTAssertEqual(afterAliasDirectoryRow.fileCount, 1)
    }
}

