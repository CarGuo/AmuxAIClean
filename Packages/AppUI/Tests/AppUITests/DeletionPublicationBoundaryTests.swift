import Combine
import AppKit
import SwiftUI
import XCTest
import ScanKit
@testable import AppUI

/// v2026.10.08: observe the synchronous notification boundary, not only post-prune data.
/// A correct model is insufficient when its notification starts a projection with a stale CAS.
@MainActor
final class DeletionPublicationBoundaryTests: XCTestCase {
    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }

    /// Opt-in native view integration, C2 only: no application launch, recycle, or HOME writes.
    func test_receiptRemovesRowsFromTheMountedNativeTreeBeforeAccountingPrune() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AMUXCLEAN_DELETION_VIEW_TESTS"] == "1",
            "Set AMUXCLEAN_DELETION_VIEW_TESTS=1 for native Tree subscription integration."
        )
        let coordinator = ScanCoordinator()
        let rows = ["/A/drop", "/A/keep"].map { path in
            RowItem(
                id: path, url: URL(fileURLWithPath: path), title: path,
                isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
                verdict: .safe, rejection: .ok
            )
        }
        coordinator._seedForTesting(
            snapshot: .init(categoryID: "test", rows: rows, totalBytes: 200,
                            scannedFileCount: 2, isFinished: true, elapsed: 1),
            currentRootPath: "/A", isScanning: false
        )
        let host = NSHostingView(rootView: TreeBrowserView(coordinator: coordinator, rootPath: "/A"))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        host.layoutSubtreeIfNeeded()
        var deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while table(in: host)?.numberOfRows != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(table(in: host)?.numberOfRows, 2, "production Tree must first mount both rows")
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: ["/A/drop"])
        deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while table(in: host)?.numberOfRows != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(table(in: host)?.numberOfRows, 1,
                       "receipt must update the actual table without another click or a sheet remount")
        XCTAssertEqual(coordinator.snapshot.rows.count, 2, "receipt presentation precedes accounting")
        withExtendedLifetime(host) {}
    }

    func test_receiptUpdatesTheMountedLargeFilesTableWithoutPrune() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMUXCLEAN_DELETION_VIEW_TESTS"] == "1")
        let coordinator = ScanCoordinator()
        coordinator._seedForTesting(
            snapshot: .init(categoryID: "test", rows: [], totalBytes: 400 * 1_048_576,
                            scannedFileCount: 2, isFinished: true, elapsed: 1),
            currentRootPath: "/A", isScanning: false
        )
        coordinator._seedLargeFileLeavesForTesting([
            (path: "/A/drop.bin", bytes: 200 * 1_048_576),
            (path: "/A/keep.bin", bytes: 200 * 1_048_576)
        ])
        let suite = "DeletionPublicationBoundaryTests-\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(testSuite: suite)
        settings.minFileSizeMB = 1
        let host = NSHostingView(rootView: LargeFilesView(
            coordinator: coordinator, settings: settings, selection: .constant(nil),
            batch: BatchSelection(), onTrash: { _ in }, onStash: { _ in },
            isStashed: { _ in false }, aiSettings: nil, onAskAI: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        host.layoutSubtreeIfNeeded()
        var deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while table(in: host)?.numberOfRows != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(table(in: host)?.numberOfRows, 2)
        let snapshot = coordinator.snapshot
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: ["/A/drop.bin"])
        deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while table(in: host)?.numberOfRows != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(table(in: host)?.numberOfRows, 1,
                       "a receipt must invalidate the frozen Large Files table, not only its getter")
        XCTAssertEqual(coordinator.snapshot, snapshot)
        withExtendedLifetime(host) {}
    }

    func test_pruneNotificationProducesAnAuthoritativePublishableTreeProjection() async throws {
        let coordinator = ScanCoordinator()
        let rows = ["/A/drop", "/A/keep"].map { path in
            RowItem(
                id: path, url: URL(fileURLWithPath: path), title: path,
                isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
                verdict: .safe, rejection: .ok
            )
        }
        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "test", rows: rows, totalBytes: 200,
                scannedFileCount: 2, isFinished: true, elapsed: 1
            ),
            currentRootPath: "/A", isScanning: false
        )

        var notifiedSource: TreeFlatProjectionSource?
        let subscription = coordinator.treeBrowser.$structuralRevision.dropFirst()
            .sink { @MainActor _ in
                // Production Tree freezes this source synchronously from onReceive.
                notifiedSource = coordinator.makeTreeFlatProjectionSource(
                    rootPath: "/A", sortedBy: .sizeDesc, expandedPaths: []
                )
            }
        await coordinator.pruneDeleted(paths: ["/A/drop"])
        withExtendedLifetime(subscription) {}

        let source = try XCTUnwrap(notifiedSource, "prune must notify the visible Tree")
        XCTAssertTrue(
            coordinator.treeFlatProjectionSourceIsCurrent(source.revision),
            "the final notification must not invalidate the projection it just requested"
        )
        let worker = TreeFlatProjectionWorker(
            input: .init(
                rootRows: source.rootRows, childrenByParent: source.childrenByParent,
                expandedPaths: [], fetchingPaths: source.fetchingPaths,
                isFetchingRoot: source.isFetchingRoot,
                receiptTombstones: source.receiptTombstones,
                evaluator: .init { _ in (.safe, .ok) }
            ),
            previous: .init(rows: [], rowIndexByPath: [:], parentIndexByRow: [],
                            maxBytes: 0, isFetchingRoot: false)
        )
        let prepared = await worker.prepare()
        XCTAssertEqual(prepared?.rows.map(\.row.path), ["/A/keep"])
        XCTAssertTrue(coordinator.treeFlatProjectionSourceIsCurrent(source.revision))
        _ = await worker.retire()
    }

    func test_numericTickNotificationAlsoUsesTheCommittedSourceIdentity() throws {
        let coordinator = ScanCoordinator()
        coordinator._seedForTesting(currentRootPath: "/A", isScanning: false,
                                    buckets: ["/A/keep": 100])
        // Establish the topology; the following publication changes only the numeric channel.
        coordinator.forcePublishSnapshotForTesting()
        var notifiedSource: TreeFlatProjectionSource?
        let subscription = coordinator.treeBrowser.$tickRevision.dropFirst()
            .sink { @MainActor _ in
                notifiedSource = coordinator.makeTreeFlatProjectionSource(
                    rootPath: "/A", sortedBy: .sizeDesc, expandedPaths: []
                )
            }
        coordinator.forcePublishSnapshotForTesting()
        withExtendedLifetime(subscription) {}
        let source = try XCTUnwrap(notifiedSource)
        XCTAssertTrue(coordinator.treeFlatProjectionSourceIsCurrent(source.revision),
                      "all Tree notification channels must commit their identity before notifying")
    }

    /// v2026.10.08: the real App kept a directory spinner after its indexed refresh finished.
    /// Observing only isFetchingChildren after await missed the busy bit frozen by Tree's sink.
    func test_subtreeRefreshPublishesSettledOwnershipWithItsFinalTreeRows() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("refresh-publication-\(UUID())", isDirectory: true)
        let target = root.appendingPathComponent("Cache", isDirectory: true)
        let leaf = target.appendingPathComponent("fresh.bin")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4_096).write(to: leaf)
        defer { try? FileManager.default.removeItem(at: root) } // best-effort test fixture cleanup

        let coordinator = ScanCoordinator(home: root.path, enableTreeDeepIndex: true)
        let targetRow = TreeRow(path: target.path, title: "Cache", bytes: 1,
                                fileCount: 1, isDirectory: true, hasChildren: true)
        coordinator._seedForTesting(
            currentRootPath: root.path, isScanning: false,
            dirIndexFull: [root.path: (1, 1), target.path: (1, 1)],
            childEdges: [root.path: [target.path], target.path: []],
            treeChildrenCache: ["\(root.path)|\(TreeSortKey.sizeDesc.rawValue)": [targetRow]]
        )
        var notifiedSource: TreeFlatProjectionSource?
        let subscription = coordinator.treeBrowser.$childrenCacheVersion.dropFirst()
            .sink { @MainActor _ in
                notifiedSource = coordinator.makeTreeFlatProjectionSource(
                    rootPath: root.path, sortedBy: .sizeDesc, expandedPaths: [target.path]
                )
            }

        await coordinator.rescanSubtree(at: target.path)
        withExtendedLifetime(subscription) {}

        let source = try XCTUnwrap(notifiedSource)
        XCTAssertFalse(coordinator.isFetchingChildren(of: target.path, sortedBy: .sizeDesc))
        XCTAssertFalse(source.fetchingPaths.contains(target.path),
                       "the terminal notification must freeze settled ownership, not a permanent spinner")
        XCTAssertTrue(coordinator.treeFlatProjectionSourceIsCurrent(source.revision))
        let worker = TreeFlatProjectionWorker(
            input: .init(rootRows: source.rootRows, childrenByParent: source.childrenByParent,
                         expandedPaths: [target.path], fetchingPaths: source.fetchingPaths,
                         isFetchingRoot: source.isFetchingRoot,
                         evaluator: .init { _ in (.safe, .ok) }),
            previous: .init(rows: [], rowIndexByPath: [:], parentIndexByRow: [],
                            maxBytes: 0, isFetchingRoot: false)
        )
        let result = await worker.prepare()
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(Set(prepared.rows.map(\.row.path)), [target.path, leaf.path])
        XCTAssertFalse(try XCTUnwrap(prepared.rows.first { $0.row.path == target.path })
            .isLoadingChildren)
        _ = await worker.retire()
    }

    func test_childrenCacheVersionNotificationIsNotInvalidatedBySubsequentStructuralBumpInPrune() async throws {
        let coordinator = ScanCoordinator()
        let rows = ["/A/drop", "/A/keep"].map { path in
            RowItem(
                id: path, url: URL(fileURLWithPath: path), title: path,
                isDirectory: true, bytes: 100, logicalBytes: 100, fileCount: 1,
                verdict: .safe, rejection: .ok
            )
        }
        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "test", rows: rows, totalBytes: 200,
                scannedFileCount: 2, isFinished: true, elapsed: 1
            ),
            currentRootPath: "/A", isScanning: false
        )

        var cacheNotifiedSource: TreeFlatProjectionSource?
        let subscription = coordinator.treeBrowser.$childrenCacheVersion.dropFirst()
            .sink { @MainActor _ in
                cacheNotifiedSource = coordinator.makeTreeFlatProjectionSource(
                    rootPath: "/A", sortedBy: .sizeDesc, expandedPaths: []
                )
            }
        await coordinator.pruneDeleted(paths: ["/A/drop"])
        withExtendedLifetime(subscription) {}

        let source = try XCTUnwrap(cacheNotifiedSource)
        XCTAssertTrue(
            coordinator.treeFlatProjectionSourceIsCurrent(source.revision),
            "bumpStructuralRevision after bumpChildrenCacheVersion must not advance pruneSourceRevision a second time"
        )
    }

    func test_undoDidRestoreNotificationClearsSameSessionDeletionTombstones() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("undo-notification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // best-effort fixture cleanup
        let restored = root.appendingPathComponent("restored.bin")
        let kept = root.appendingPathComponent("keep.bin")
        try Data(repeating: 0x31, count: 2 * 1_048_576).write(to: restored)
        try Data(repeating: 0x32, count: 2 * 1_048_576).write(to: kept)
        let coordinator = ScanCoordinator(home: root.path)
        coordinator._seedForTesting(
            snapshot: .init(categoryID: "test", rows: [], totalBytes: 4 * 1_048_576,
                            scannedFileCount: 2, isFinished: true, elapsed: 1),
            currentRootPath: root.path, isScanning: false, largeFileMinBytes: 1_048_576
        )
        coordinator._seedLargeFileLeavesForTesting([
            (path: restored.path, bytes: 2 * 1_048_576),
            (path: kept.path, bytes: 2 * 1_048_576)
        ])
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [restored.path])
        // v2026.10.08: the actual UI awaits full prune before Undo is available. Testing
        // acknowledgement alone left the old heap intact and concealed lost source models.
        await coordinator.pruneDeleted(paths: [restored.path])
        XCTAssertEqual(coordinator.largeFiles(minSizeMB: 1, sortKey: .sizeDesc).map(\.path), [kept.path])
        NotificationCenter.default.post(name: .amuxUndoDidRestore, object: nil,
                                        userInfo: ["paths": [restored.path]])
        await coordinator._waitForUndoReconciliationForTesting()
        XCTAssertEqual(Set(coordinator.largeFiles(minSizeMB: 1, sortKey: .sizeDesc).map(\.path)),
                       [restored.path, kept.path])
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        XCTAssertFalse(coordinator._isDeletedTombstonedForTesting(restored.path))
    }
}
