import SafetyKit
import XCTest
@testable import AppUI

final class TreeDeletionIntentTests: XCTestCase {
    func test_lazyTreeRowSnapshotPreservesDisplayedFactsWithoutIndexFallback() throws {
        let modified = Date(timeIntervalSince1970: 1_720_000_000)
        let row = TreeRow(
            path: "/tmp/lazy/.cxx",
            title: ".cxx",
            bytes: 123_456_789,
            logicalBytes: 234_567_890,
            fileCount: 14_321,
            isDirectory: true,
            hasChildren: true,
            modificationDate: modified
        )

        let snapshot = try XCTUnwrap(DeletionRowSnapshotFactory.tree(
            row,
            verdict: .confirm,
            rejection: .ok,
            vendorName: "Example SDK",
            vendorNote: "Generated files",
            runningBundleIDPrefix: "com.example.ide"
        ))

        XCTAssertEqual(snapshot.id, row.path)
        XCTAssertEqual(snapshot.url.path, row.path)
        XCTAssertEqual(snapshot.title, row.title)
        XCTAssertEqual(snapshot.bytes, row.bytes)
        XCTAssertEqual(snapshot.logicalBytes, row.logicalBytes)
        XCTAssertEqual(snapshot.fileCount, row.fileCount)
        XCTAssertEqual(snapshot.isDirectory, row.isDirectory)
        XCTAssertEqual(snapshot.modificationDate, modified)
        XCTAssertEqual(snapshot.verdict, .confirm)
        XCTAssertEqual(snapshot.vendorName, "Example SDK")
        XCTAssertEqual(snapshot.runningBundleIDPrefix, "com.example.ide")
    }

    @MainActor
    func test_pendingLazyTreeRowCannotInitiateOrFreezeDeletion() {
        let pending = TreeRow(
            path: "/tmp/lazy/pending",
            title: "pending",
            bytes: 0,
            logicalBytes: 0,
            fileCount: 0,
            isDirectory: true,
            hasChildren: true,
            isSizePending: true
        )

        XCTAssertFalse(TreeBrowserView.canInitiateDeletion(
            pending,
            verdict: .safe,
            rejection: .ok,
            allowsVendorPathOverride: true
        ))
        XCTAssertNil(DeletionRowSnapshotFactory.tree(
            pending,
            verdict: .safe,
            rejection: .ok
        ), "pending means unknown metrics, not a zero-byte deletion target")
    }

    @MainActor
    func test_survivingSelectedAncestorUsesPostPruneAggregate() {
        let selected = TreeRow(
            path: "/tmp/root/parent",
            title: "parent",
            bytes: 1_000,
            logicalBytes: 2_000,
            fileCount: 10,
            isDirectory: true,
            hasChildren: true
        )
        let refreshed = TreeRow(
            path: selected.path,
            title: selected.title,
            bytes: 700,
            logicalBytes: 1_400,
            fileCount: 7,
            isDirectory: true,
            hasChildren: true
        )

        let result = TreeSelectionReconciler.afterSuccessfulDeletion(
            selected: selected,
            succeededPaths: [selected.path + "/child"],
            refreshedRow: { path in
                XCTAssertEqual(path, selected.path)
                return refreshed
            }
        )

        XCTAssertEqual(result, refreshed)
    }

    @MainActor
    func test_deletedTreeSelectionIsClearedWithoutRefreshing() {
        let selected = TreeRow(
            path: "/tmp/root/parent/child",
            title: "child",
            bytes: 100,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        var didRefresh = false

        let result = TreeSelectionReconciler.afterSuccessfulDeletion(
            selected: selected,
            succeededPaths: [selected.path],
            refreshedRow: { _ in
                didRefresh = true
                return selected
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(didRefresh)
    }

    @MainActor
    func test_treeTrashCallbackCarriesTheFrozenTreeRowRatherThanOnlyAURL() {
        let row = TreeRow(
            path: "/tmp/lazy/cache",
            title: "cache",
            bytes: 8_192,
            fileCount: 17,
            isDirectory: true,
            hasChildren: true
        )
        var received: TreeRow?
        let view = TreeBrowserView(
            coordinator: ScanCoordinator(),
            rootPath: "/tmp/lazy",
            onTrash: { received = $0 }
        )

        view.onTrash?(row)

        XCTAssertEqual(received, row)
    }
}
