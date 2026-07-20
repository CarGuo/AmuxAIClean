import SafetyKit
import XCTest
@testable import AppUI

final class TreeDeletionIntentTests: XCTestCase {
    func test_inlineCommandsNeverTakeRowSelectionOrDetailOwnership() {
        // v2026.07.20: this is the whole inline operation area, not a delete-only exception.
        // CaseIterable makes every future operation join the same navigation contract by default.
        for action in InlineRowActionNavigationPolicy.Action.allCases {
            XCTAssertFalse(InlineRowActionNavigationPolicy.shouldSelectRow(for: action))
            XCTAssertTrue(InlineRowActionNavigationPolicy.shouldFocusTable(for: action))
        }
    }

    func test_externalDetailCloseClearsRealTreeSelection() {
        XCTAssertNil(TreeBrowserView.selectionAfterExternalReset(current: "/tmp/selected"))
    }

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
    func test_loadingParentPreviewCannotInitiateDeletionUntilAuthoritativeCommit() {
        let row = TreeRow(
            path: "/tmp/wide-parent",
            title: "wide-parent",
            bytes: 1_024,
            fileCount: 64,
            isDirectory: true,
            hasChildren: true
        )
        let loading = FlatTreeRow(
            row: row,
            depth: 0,
            verdict: .safe,
            isLoadingChildren: true
        )
        let complete = FlatTreeRow(
            row: row,
            depth: 0,
            verdict: .safe,
            isLoadingChildren: false
        )

        XCTAssertFalse(TreeBrowserView.canInitiateDeletion(
            loading,
            allowsVendorPathOverride: true
        ))
        XCTAssertTrue(TreeBrowserView.canInitiateDeletion(
            complete,
            allowsVendorPathOverride: true
        ))
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

    func test_projectionDoesNotInventASelectionWhenNothingWasSelected() {
        let result = TreeBrowserView.selectionAfterProjection(
            current: nil,
            rowIndexByPath: ["/A/first": 0, "/A/second": 1]
        )

        XCTAssertNil(result, "异步 Tree 刷新不得自动选中第一行并把视口带回顶部")
    }

    func test_projectionClearsOnlyASelectionThatDisappeared() {
        XCTAssertNil(TreeBrowserView.selectionAfterProjection(
            current: "/A/deleted",
            rowIndexByPath: ["/A/keep": 0]
        ))
        XCTAssertEqual(TreeBrowserView.selectionAfterProjection(
            current: "/A/keep",
            rowIndexByPath: ["/A/keep": 0]
        ), "/A/keep", "删除其他行时必须保留当前选择")
    }

    func test_passiveProjectionNeverRequestsViewportReveal() {
        XCTAssertFalse(TreeSelectionViewportPolicy.shouldReveal(
            pendingUserNavigationPath: nil,
            selectedPath: "/A/keep"
        ))
        XCTAssertFalse(TreeSelectionViewportPolicy.shouldReveal(
            pendingUserNavigationPath: "/A/old",
            selectedPath: "/A/keep"
        ))
        XCTAssertTrue(TreeSelectionViewportPolicy.shouldReveal(
            pendingUserNavigationPath: "/A/keep",
            selectedPath: "/A/keep"
        ), "只有显式键盘导航到当前行时才允许移动视口")
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
