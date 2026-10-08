import AppKit
import XCTest
@testable import AppUI

/// v2026.10.08: language must survive native title attachment and later menu rebuilds.
@MainActor
final class NativeLocaleLifecycleTests: XCTestCase {
    func test_windowTitleTracksLocaleBeforeAndAfterNativeAttachment() {
        let view = LocalizedWindowTitle.TitleView()
        let title = LocalizedTextDescriptor.catalog("settings.window.title %@", arguments: [.string("AmuxAIClean")])
        view.localizedTitle = title.localized(locale: Locale(identifier: "en"))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        XCTAssertEqual(window.title, "AmuxAIClean Settings")
        view.localizedTitle = title.localized(locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(window.title, "AmuxAIClean 设置")
    }

    func test_rebuiltMenuIsLocalizedWithoutChangingItsResponderActions() {
        let root = NSMenu(title: "root")
        func installFileMenu() -> NSMenuItem {
            root.removeAllItems()
            let submenu = NSMenu(title: "文件")
            let close = NSMenuItem(title: "关闭", action: NSSelectorFromString("performClose:"), keyEquivalent: "w")
            close.keyEquivalentModifierMask = [.command]
            submenu.addItem(close)
            submenu.addItem(NSMenuItem(title: "全部关闭", action: NSSelectorFromString("closeAll:"), keyEquivalent: ""))
            let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
            file.submenu = submenu
            root.addItem(file)
            return close
        }
        let locale = Locale(identifier: "en")
        _ = installFileMenu()
        ApplicationMenuLocalizer.apply(to: root, locale: locale, appName: "AmuxAIClean")
        let rebuiltClose = installFileMenu()
        ApplicationMenuLocalizer.apply(to: root, locale: locale, appName: "AmuxAIClean")
        ApplicationMenuLocalizer.apply(to: root, locale: locale, appName: "AmuxAIClean")
        XCTAssertEqual(root.items.first?.title, "File")
        XCTAssertEqual(rebuiltClose.title, "Close")
        XCTAssertEqual(rebuiltClose.action, NSSelectorFromString("performClose:"))
        XCTAssertEqual(rebuiltClose.keyEquivalent, "w")
        XCTAssertEqual(rebuiltClose.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(root.items.first?.submenu?.items.last?.title, "Close All")
    }
}
