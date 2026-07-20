import AppKit
import XCTest
@testable import AppUI

@MainActor
private final class CountingTreeTableView: NSTableView {
    private(set) var reloadCallCount = 0

    override func reloadData() {
        reloadCallCount += 1
        super.reloadData()
    }
}

@MainActor
private final class MutableTreeTableDataSource: NSObject, NSTableViewDataSource {
    var rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
}

@MainActor
final class AppKitTableFocusTests: XCTestCase {
    /// v2026.07.20: column geometry belongs to AppKit layout, not unrelated SwiftUI state updates
    /// such as deletion preflight/sheet presentation. The first real layout must converge from an
    /// arbitrary construction width; repeated same-viewport layouts are idempotent, and only a
    /// real viewport resize (including detail open/close) may move the entire operation area.
    func test_treeColumnWidthFollowsOnlyTheLaidOutViewport() {
        let scroll = TreeViewportScrollView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 240)
        )
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let table = NSTableView(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree.viewport"))
        column.width = 37
        table.addTableColumn(column)
        scroll.documentView = table

        scroll.layout()
        let firstViewportWidth = scroll.contentView.bounds.width
        XCTAssertGreaterThan(firstViewportWidth, 0)
        XCTAssertEqual(column.width, firstViewportWidth, accuracy: 0.001)

        let widthAfterFirstLayout = column.width
        scroll.needsDisplay = true // Models an unrelated business-state redraw without geometry.
        scroll.layout()
        XCTAssertEqual(column.width, widthAfterFirstLayout, accuracy: 0.001)

        // Models selecting a row and opening its real detail pane: the list viewport shrinks.
        scroll.frame.size.width = 480
        scroll.layout()
        let detailOpenViewportWidth = scroll.contentView.bounds.width
        XCTAssertLessThan(detailOpenViewportWidth, firstViewportWidth)
        XCTAssertEqual(column.width, detailOpenViewportWidth, accuracy: 0.001)

        // Models closing detail: the viewport and right-anchored operation area expand again.
        scroll.frame.size.width = 720
        scroll.layout()
        let detailClosedViewportWidth = scroll.contentView.bounds.width
        XCTAssertEqual(detailClosedViewportWidth, firstViewportWidth, accuracy: 0.001)
        XCTAssertEqual(column.width, detailClosedViewportWidth, accuracy: 0.001)
    }

    /// v2026.07.16：自绘 row 会消费 mouseDown；用户点击后必须显式把 first responder
    /// 交给 table，Space/Delete/方向键才走统一 AppKit 命令链。
    func test_userInitiatedFocusHandsKeyboardToTable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let textField = NSTextField(frame: NSRect(x: 0, y: 250, width: 200, height: 24))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test")))
        container.addSubview(textField)
        container.addSubview(table)
        window.contentView = container

        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertFalse(window.firstResponder === table)

        XCTAssertTrue(UserInitiatedTableFocus.request(for: table))
        XCTAssertTrue(window.firstResponder === table)
    }

    func test_receiptRowRemovalUpdatesRealNSTableViewWithoutFullReload() {
        let table = CountingTreeTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
        table.rowHeight = 30
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree")))
        let dataSource = MutableTreeTableDataSource(rowCount: 5)
        table.dataSource = dataSource

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        scroll.documentView = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
        let originalOrigin = scroll.contentView.bounds.origin
        let reloadsBeforeDelta = table.reloadCallCount

        dataSource.rowCount = 3
        TreeTableStructuralUpdateApplier.apply(
            .removeRows([1..<3]),
            to: table,
            in: scroll,
            redrawVisible: { XCTFail("a structural delta must not take the redraw-only path") }
        )

        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(table.reloadCallCount, reloadsBeforeDelta)
        XCTAssertEqual(table.selectedRow, 0, "an inline delete must not move selection")
        XCTAssertEqual(scroll.contentView.bounds.origin, originalOrigin)
    }
}
