import SafetyKit
import XCTest
@testable import AppUI

/// v2026.10.14 DB-08: path identity surviving a Tree projection does not imply its
/// selected metadata is current. Exercise the production worker/publication boundary.
@MainActor
final class TreeSelectedSnapshotRegressionTests: XCTestCase {
    func testPendingSelectionRefreshesAfterMeasurementWithoutReselectingOrReloading() async throws {
        let pending = makeRow(path: "/fixture/cache", bytes: 0, isSizePending: true)
        let complete = makeRow(path: pending.path, bytes: 4_096, isSizePending: false)
        let previous = FlatTreeRow(row: pending, depth: 0, verdict: .safe)
        var parentSelection = pending
        XCTAssertFalse(canDelete(parentSelection))

        let worker = TreeFlatProjectionWorker(
            input: .init(
                rootRows: [complete], childrenByParent: [:], expandedPaths: [],
                fetchingPaths: [], isFetchingRoot: false,
                evaluator: .init { _ in (.safe, .ok) }
            ),
            previous: .init(
                rows: [previous], rowIndexByPath: [pending.path: 0],
                parentIndexByRow: [nil], maxBytes: 0, isFetchingRoot: false
            )
        )
        let result = await worker.prepare()
        let prepared = try XCTUnwrap(result)
        let update = TreeSelectionProjectionPolicy.update(
            selectedPath: pending.path, previousSelectedRow: previous, prepared: prepared
        )
        if case .refresh(let row) = update { parentSelection = row }

        XCTAssertEqual(update, .refresh(complete))
        XCTAssertEqual(parentSelection, complete, "Detail/footer must receive the committed row without another click")
        XCTAssertTrue(canDelete(parentSelection), "Measurement completion must unblock the selected footer action")
        XCTAssertTrue(prepared.changed)
        XCTAssertFalse(prepared.tableIdentityChanged, "Refreshing metadata must not reload/reselect the Tree")
        XCTAssertFalse(prepared.ranOnMainThread)
        XCTAssertFalse(TreeSelectionViewportPolicy.shouldReveal(
            pendingUserNavigationPath: nil, selectedPath: parentSelection.path
        ))
        _ = await worker.retire()
    }

    func testSelectionPublicationPreservesNavigationAndRefreshesChangedAccessAndLoading() {
        let selected = makeRow(path: "/fixture/selected", bytes: 128, isSizePending: false)
        let other = makeRow(path: "/fixture/other", bytes: 64, isSizePending: false)
        let old = FlatTreeRow(row: selected, depth: 0, verdict: .safe)
        let otherFlat = FlatTreeRow(row: other, depth: 0, verdict: .safe)
        let inaccessible = TreeRow(
            path: selected.path, title: selected.title, bytes: selected.bytes,
            fileCount: selected.fileCount, isDirectory: true, hasChildren: true,
            accessState: .permissionDenied
        )
        let updated = FlatTreeRow(row: inaccessible, depth: 0, verdict: .safe)
        let reordered = prepared(rows: [otherFlat, updated])

        XCTAssertEqual(TreeSelectionProjectionPolicy.update(
            selectedPath: selected.path, previousSelectedRow: old, prepared: reordered
        ), .refresh(inaccessible), "The selected row must receive new access evidence even when its path survives sorting")
        XCTAssertFalse(TreeBrowserView.canInitiateDeletion(
            inaccessible, verdict: .safe, rejection: .ok, allowsVendorPathOverride: false
        ))
        XCTAssertEqual(TreeSelectionProjectionPolicy.update(
            selectedPath: other.path, previousSelectedRow: otherFlat, prepared: reordered
        ), .unchanged, "A refresh of another row must not disturb the current selection")
        XCTAssertEqual(TreeSelectionProjectionPolicy.update(
            selectedPath: nil, previousSelectedRow: old, prepared: reordered
        ), .unchanged, "Closing detail while a worker runs must not resurrect selection")
        XCTAssertEqual(TreeSelectionProjectionPolicy.update(
            selectedPath: selected.path, previousSelectedRow: old,
            prepared: prepared(rows: [otherFlat])
        ), .clear, "Deletion/collapse clears the removed selection without selecting the first row")

        let loading = FlatTreeRow(row: selected, depth: 0, verdict: .safe, isLoadingChildren: true)
        XCTAssertEqual(TreeSelectionProjectionPolicy.update(
            selectedPath: selected.path, previousSelectedRow: loading,
            prepared: prepared(rows: [old])
        ), .refresh(selected), "A loading-only completion must refresh the footer eligibility too")
    }

    func testEligibilityCompletionRejectsEarlierSamePathAndClearedSelectionRequests() {
        let pending = makeRow(path: "/fixture/cache", bytes: 0, isSizePending: true)
        let complete = makeRow(path: pending.path, bytes: 4_096, isSizePending: false)
        let pendingRequest = TreeSelectionEligibilityRequest(revision: 1, row: pending)
        let completeRequest = TreeSelectionEligibilityRequest(revision: 2, row: complete)

        XCTAssertFalse(pendingRequest.isCurrent(revision: 2, selectedRow: complete))
        XCTAssertTrue(completeRequest.isCurrent(revision: 2, selectedRow: complete))
        XCTAssertFalse(completeRequest.isCurrent(revision: 2, selectedRow: pending),
                       "Path equality cannot authorize a different selected snapshot")
        XCTAssertFalse(completeRequest.isCurrent(revision: 3, selectedRow: nil))
        XCTAssertFalse(completeRequest.isCurrent(revision: 4, selectedRow: complete),
                       "Clearing and reselecting the identical row must not revive an old queued completion")
    }

    private func prepared(rows: [FlatTreeRow]) -> PreparedTreeFlatProjection {
        PreparedTreeFlatProjection(
            rows: rows,
            rowIndexByPath: Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.row.path, $0.offset) }),
            parentIndexByRow: rows.map { _ in nil }, maxBytes: rows.map(\.row.bytes).max() ?? 0,
            isFetchingRoot: false, changed: true, tableIdentityChanged: true,
            ranOnMainThread: false, rowRemovalRanges: nil
        )
    }

    private func canDelete(_ row: TreeRow) -> Bool {
        TreeBrowserView.canInitiateDeletion(
            row, verdict: .safe, rejection: .ok, allowsVendorPathOverride: true
        )
    }

    private func makeRow(path: String, bytes: Int64, isSizePending: Bool) -> TreeRow {
        TreeRow(
            path: path, title: "cache", bytes: bytes, logicalBytes: bytes,
            fileCount: isSizePending ? 0 : 1, isDirectory: true, hasChildren: true,
            isSizePending: isSizePending
        )
    }
}
