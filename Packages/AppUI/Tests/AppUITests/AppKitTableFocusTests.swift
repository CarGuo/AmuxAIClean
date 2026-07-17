import AppKit
import XCTest
@testable import AppUI

@MainActor
final class AppKitTableFocusTests: XCTestCase {
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
}
