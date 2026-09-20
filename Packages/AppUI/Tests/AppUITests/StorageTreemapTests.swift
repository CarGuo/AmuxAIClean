import XCTest

@testable import AppUI

final class StorageTreemapTests: XCTestCase {
    private func row(
        _ name: String, bytes: Int64, pending: Bool = false,
        access: TreeRow.AccessState = .normal,
        completeness: TreeRow.SubtreeCompleteness = .complete
    ) -> TreeRow {
        TreeRow(
            path: "/fixture/\(name)", title: name, bytes: bytes, fileCount: 1,
            isDirectory: true, hasChildren: true, accessState: access,
            subtreeCompleteness: completeness, isSizePending: pending)
    }

    func testMapAreaConservesMeasuredBytesWithoutOverlapsAtDifferentAspectRatios() throws {
        let projection = try StorageDirectoryProjection.make(
            rows: (1...80).map { row("item-\($0)", bytes: Int64($0 * $0)) },
            query: "", limit: 100, locale: Locale(identifier: "en"))
        for size in [
            CGSize(width: 900, height: 390), CGSize(width: 270, height: 800), CGSize(width: 1, height: 1),
        ] {
            let cells = StorageTreemapLayout.rectangles(items: projection.mapItems, size: size)
            XCTAssertEqual(cells.count, 41)
            let area = size.width * size.height
            XCTAssertEqual(
                cells.reduce(0) { $0 + $1.rect.width * $1.rect.height }, area, accuracy: area * 1e-10)
            for (index, cell) in cells.enumerated() {
                XCTAssertGreaterThanOrEqual(cell.rect.minX, -0.000001)
                XCTAssertGreaterThanOrEqual(cell.rect.minY, -0.000001)
                XCTAssertLessThanOrEqual(cell.rect.maxX, size.width + 0.000001)
                XCTAssertLessThanOrEqual(cell.rect.maxY, size.height + 0.000001)
                XCTAssertEqual(
                    cell.rect.width * cell.rect.height / area,
                    Double(cell.item.bytes) / Double(projection.measuredBytes), accuracy: 1e-10)
                for other in cells.dropFirst(index + 1) {
                    let overlap = cell.rect.intersection(other.rect)
                    XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < area * 1e-10)
                }
            }
        }
    }

    func testUnknownAndZeroSizesStayInListAndNeverAcquireFakeArea() throws {
        let projection = try StorageDirectoryProjection.make(
            rows: [
                row("measured", bytes: 400), row("empty", bytes: 0),
                row("pending", bytes: 999, pending: true),
                row("protected", bytes: 0, access: .tccProtected),
                row("partial", bytes: 200, completeness: .containsIncompleteDescendant),
            ], query: "", limit: 100, locale: Locale(identifier: "en"))
        XCTAssertEqual(projection.totalCount, 5)
        XCTAssertEqual(projection.rows.count, 5)
        XCTAssertEqual(projection.mapItems.map(\.bytes), [400, 200])
        XCTAssertEqual(projection.measuredBytes, 600)
        XCTAssertEqual(projection.pendingCount, 1)
        XCTAssertEqual(projection.incompleteCount, 2)
    }

    func testOtherGroupPreservesAllBytesAndPaginationDoesNotChangeMap() throws {
        let rows = (1...240).map { row("item-\($0)", bytes: Int64($0)) }
        let first = try StorageDirectoryProjection.make(rows: rows, query: "", limit: 100, locale: .current)
        let more = try StorageDirectoryProjection.make(rows: rows, query: "", limit: 200, locale: .current)
        XCTAssertEqual(first.rows.count, 100)
        XCTAssertEqual(more.rows.count, 200)
        XCTAssertEqual(first.mapItems, more.mapItems)
        XCTAssertEqual(first.totalCount, 240)
        XCTAssertEqual(first.mapItems.last?.groupedCount, 200)
        XCTAssertEqual(first.mapItems.reduce(0) { $0 + $1.bytes }, 240 * 241 / 2)
    }

    func testSearchAndColorsDoNotDependOnInputOrdering() throws {
        let rows = [row("Café", bytes: 100), row("cache", bytes: 200)]
        let a = try StorageDirectoryProjection.make(
            rows: rows, query: "CAFE", limit: 100, locale: Locale(identifier: "en"))
        let b = try StorageDirectoryProjection.make(
            rows: rows.reversed(), query: "cafe", limit: 100, locale: Locale(identifier: "en"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.rows.first?.title, "Café")
        XCTAssertEqual(a.totalCount, 1)
    }

    func testEmptyInvalidAndExtremeInputsDoNotCreateInvalidGeometry() throws {
        XCTAssertTrue(
            StorageTreemapLayout.rectangles(items: [], size: CGSize(width: 100, height: 100)).isEmpty)
        let projection = try StorageDirectoryProjection.make(
            rows: [row("a", bytes: .max), row("b", bytes: .max)],
            query: "", limit: 100, locale: .current)
        XCTAssertEqual(projection.measuredBytes, .max)
        XCTAssertTrue(StorageTreemapLayout.rectangles(items: projection.mapItems, size: .zero).isEmpty)
        let cells = StorageTreemapLayout.rectangles(
            items: projection.mapItems, size: CGSize(width: 100, height: 100))
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].rect.width * cells[0].rect.height, 5_000, accuracy: 1e-8)
    }

    func testSkewedMapGroupsUnreadableCellsWithoutChangingProportions() throws {
        // Reproduces the user's distribution, not production path-specific rules.
        let rows = [304_390, 33_100, 25_310, 7_490, 5_900, 2_900, 1_130].enumerated().map {
            row("directory-\($0.offset)", bytes: Int64($0.element))
        }
        for size in [CGSize(width: 1150, height: 400), CGSize(width: 750, height: 280)] {
            let projection = try StorageDirectoryProjection.make(
                rows: rows, query: "", limit: 100, locale: .current, viewportSize: size)
            let presentation = projection.mapPresentation
            let group = try XCTUnwrap(presentation.smallerItems)
            XCTAssertGreaterThan(group.groupedCount, 0)
            XCTAssertTrue(presentation.individualPaths.contains("/fixture/directory-0"))
            XCTAssertEqual(presentation.cells.reduce(0) { $0 + $1.item.bytes }, projection.measuredBytes)
            let area = presentation.chartSize.width * presentation.chartSize.height
            for cell in presentation.cells {
                XCTAssertTrue(cell.item.row == nil || StorageTreemapPresentation.fitsSummary(cell.rect))
                XCTAssertEqual(
                    cell.rect.width * cell.rect.height / area,
                    Double(cell.item.bytes) / Double(projection.measuredBytes), accuracy: 1e-10)
            }
            let groupedRows = rows.filter { !presentation.individualPaths.contains($0.path) }
            XCTAssertEqual(group.bytes, groupedRows.reduce(0) { $0 + $1.bytes })
            XCTAssertEqual(group.groupedCount, groupedRows.count)
        }
    }

    func testGroupedListIsExactReachableAndIndependentOfPagination() throws {
        let rows = [row("dominant", bytes: 100_000_000)]
            + (1...240).map { row("tiny-\($0)", bytes: Int64($0)) }
            + [row("pending", bytes: 20, pending: true), row("zero", bytes: 0)]
        let size = CGSize(width: 900, height: 390)
        let all = try StorageDirectoryProjection.make(
            rows: rows, query: "", limit: 100, locale: .current, viewportSize: size)
        let small = try StorageDirectoryProjection.make(
            rows: rows, query: "", limit: 100, locale: .current,
            viewportSize: size, listScope: .smallerItems)
        let more = try StorageDirectoryProjection.make(
            rows: rows, query: "", limit: 300, locale: .current,
            viewportSize: size, listScope: .smallerItems)
        XCTAssertEqual(all.mapPresentation, small.mapPresentation)
        XCTAssertEqual(small.mapPresentation, more.mapPresentation)
        XCTAssertEqual(small.rows.count, 100)
        XCTAssertEqual(small.listedCount, 240)
        XCTAssertEqual(more.rows.count, 240)
        XCTAssertEqual(more.listScope, .smallerItems)
        XCTAssertEqual(Set(more.rows.map(\.path)), Set(rows.filter { $0.title.hasPrefix("tiny-") }.map(\.path)))
        XCTAssertEqual(more.rows.reduce(0) { $0 + $1.bytes }, more.mapPresentation.smallerItems?.bytes)
        XCTAssertEqual(all.measuredBytes, more.measuredBytes)
        XCTAssertEqual(all.totalCount, more.totalCount)
    }

    func testReadableCellsNeedNoGroupAndResizingCannotLeaveAnEmptyFocus() throws {
        let rows = (0..<4).map { row("item-\($0)", bytes: 1_000) }
        let large = try StorageDirectoryProjection.make(
            rows: rows, query: "", limit: 100, locale: .current,
            viewportSize: CGSize(width: 1000, height: 600), listScope: .smallerItems)
        XCTAssertNil(large.mapPresentation.smallerItems)
        XCTAssertEqual(large.listScope, .all)
        XCTAssertEqual(large.listedCount, 4)
        XCTAssertEqual(large.mapPresentation.cells.count, 4)
        XCTAssertEqual(large.mapPresentation.chartSize, CGSize(width: 1000, height: 600))
        let tiny = try StorageDirectoryProjection.make(
            rows: rows, query: "", limit: 100, locale: .current,
            viewportSize: CGSize(width: 90, height: 70), listScope: .smallerItems)
        XCTAssertEqual(tiny.mapPresentation.smallerItems?.groupedCount, 4)
        XCTAssertEqual(tiny.rows.count, 4)
        XCTAssertTrue(tiny.mapPresentation.cells.allSatisfy { $0.item.row == nil })
        XCTAssertTrue(StorageTreemapPresentation.make(items: large.mapItems, size: .zero).cells.isEmpty)
    }
}
