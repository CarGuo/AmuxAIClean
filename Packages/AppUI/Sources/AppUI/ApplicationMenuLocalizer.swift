import AppKit
import Foundation

/// v2026.07.15：运行期刷新 macOS 原生主菜单的集中边界。
///
/// SwiftUI 的 `environment(\.locale, ...)` 不会穿透到 AppKit 在进程启动时创建的
/// File / Edit / View / Window / Help 与 application menu。这里按公开的 menu/action
/// 语义识别标准项，只改 title，不替换 target/action/keyEquivalent，因此不会破坏系统
/// 菜单验证、快捷键或 responder chain。
@MainActor
public enum ApplicationMenuLocalizer {
    public static func apply(locale: Locale, application: NSApplication = NSApp) {
        guard let mainMenu = application.mainMenu else { return }
        apply(
            to: mainMenu,
            locale: locale,
            appName: AppLocalization.string("app.name", locale: locale),
            servicesMenu: application.servicesMenu,
            windowsMenu: application.windowsMenu,
            helpMenu: application.helpMenu
        )
    }

    /// 可注入 menu graph 的纯 UI mutation 核心，供单测锁住 standard role 识别。
    static func apply(
        to mainMenu: NSMenu,
        locale: Locale,
        appName: String,
        servicesMenu: NSMenu? = nil,
        windowsMenu: NSMenu? = nil,
        helpMenu: NSMenu? = nil
    ) {
        for rootItem in mainMenu.items {
            guard let submenu = rootItem.submenu else { continue }
            let role = role(
                for: submenu,
                windowsMenu: windowsMenu,
                helpMenu: helpMenu
            )

            switch role {
            case .application:
                // 顶层 application menu 使用产品名；只刷新其标准子项。
                setTitle(appName, for: rootItem)
                setTitle(appName, for: submenu)
                localizeApplicationMenu(
                    submenu,
                    locale: locale,
                    appName: appName,
                    servicesMenu: servicesMenu
                )
            case .file, .edit, .view, .window, .help:
                let key = role.titleKey
                let title = AppLocalization.string(key, locale: locale)
                setTitle(title, for: rootItem)
                setTitle(title, for: submenu)
                localizeStandardActions(in: submenu, locale: locale)
            case .unknown:
                break
            }
        }
        // v2026.10.08: this also runs after AppKit updates. Titles already invalidate their
        // display; recursively asking the SwiftUI-owned graph to validate/rebuild here can
        // overwrite the locale again. Targets, actions and validation remain system-owned.
    }

    private static func setTitle(_ title: String, for item: NSMenuItem) {
        guard item.title != title else { return }
        item.title = title
    }

    private static func setTitle(_ title: String, for menu: NSMenu) {
        guard menu.title != title else { return }
        menu.title = title
    }

    private enum MenuRole {
        case application, file, edit, view, window, help, unknown

        var titleKey: String {
            switch self {
            case .file: return "menu.native.file"
            case .edit: return "menu.native.edit"
            case .view: return "menu.native.view"
            case .window: return "menu.native.window"
            case .help: return "menu.native.help"
            case .application, .unknown: return ""
            }
        }
    }

    private static func role(
        for menu: NSMenu,
        windowsMenu: NSMenu?,
        helpMenu: NSMenu?
    ) -> MenuRole {
        if containsAction("terminate:", in: menu) { return .application }
        if menu === windowsMenu || containsAction("performMiniaturize:", in: menu) { return .window }
        if menu === helpMenu { return .help }
        if containsAnyAction(["undo:", "cut:", "copy:", "paste:"], in: menu) { return .edit }
        if containsAnyAction(["performClose:", "closeAll:"], in: menu) { return .file }
        if containsAnyAction(
            ["toggleFullScreen:", "toggleSidebar:", "toggleToolbarShown:"],
            in: menu
        ) { return .view }
        return .unknown
    }

    private static func localizeApplicationMenu(
        _ menu: NSMenu,
        locale: Locale,
        appName: String,
        servicesMenu: NSMenu?
    ) {
        for item in menu.items where !item.isSeparatorItem {
            if item.submenu === servicesMenu {
                setTitle(AppLocalization.string("menu.native.services", locale: locale), for: item)
                continue
            }
            let action = actionName(of: item)
            if [
                "openSettings:",
                "showSettingsWindow:",
                "showPreferencesWindow:",
                "orderFrontPreferencesPanel:",
            ].contains(action) || item.keyEquivalent == "," {
                setTitle(AppLocalization.string("menu.native.settings", locale: locale), for: item)
                continue
            }

            switch action {
            case "orderFrontStandardAboutPanel:":
                setTitle(AppLocalization.format(
                    "menu.native.about %@",
                    locale: locale,
                    arguments: [appName]
                ), for: item)
            case "hide:":
                setTitle(AppLocalization.format(
                    "menu.native.hide %@",
                    locale: locale,
                    arguments: [appName]
                ), for: item)
            case "hideOtherApplications:":
                setTitle(AppLocalization.string("menu.native.hide_others", locale: locale), for: item)
            case "unhideAllApplications:":
                setTitle(AppLocalization.string("menu.native.show_all", locale: locale), for: item)
            case "terminate:":
                setTitle(AppLocalization.format(
                    "menu.native.quit %@",
                    locale: locale,
                    arguments: [appName]
                ), for: item)
            default:
                // 未知系统/第三方命令保持原题；不按标题或位置猜测语义。
                break
            }
        }
    }

    private static let standardActionKeys: [String: String] = [
            "performClose:": "menu.native.close",
            "closeAll:": "menu.native.close_all",
            "undo:": "menu.native.undo",
            "redo:": "menu.native.redo",
            "cut:": "menu.native.cut",
            "copy:": "menu.native.copy",
            "paste:": "menu.native.paste",
            "delete:": "menu.native.delete",
            "selectAll:": "menu.native.select_all",
            "performMiniaturize:": "menu.native.minimize",
            "performZoom:": "menu.native.zoom",
            "arrangeInFront:": "menu.native.bring_all_to_front",
            // v2026.07.16：这三项早已用于识别 View 菜单，却没有进入动作映射，
            // 导致顶层已切中文、子项仍保留进程启动语言。使用不猜测当前显隐状态的
            // “切换”语义，避免把正在退出全屏误标成“进入全屏”。
            "toggleFullScreen:": "menu.native.toggle_full_screen",
            "toggleSidebar:": "menu.native.toggle_sidebar",
            "toggleToolbarShown:": "menu.native.toggle_toolbar",
    ]

    private static func localizeStandardActions(in menu: NSMenu, locale: Locale) {
        for item in menu.items {
            if let action = actionName(of: item), let key = standardActionKeys[action] {
                setTitle(AppLocalization.string(key, locale: locale), for: item)
            }
            if let submenu = item.submenu {
                localizeStandardActions(in: submenu, locale: locale)
            }
        }
    }

    private static func actionName(of item: NSMenuItem) -> String? {
        item.action.map(NSStringFromSelector)
    }

    private static func containsAnyAction(_ names: Set<String>, in menu: NSMenu) -> Bool {
        names.contains { containsAction($0, in: menu) }
    }

    private static func containsAction(_ name: String, in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            actionName(of: item) == name
                || item.submenu.map { containsAction(name, in: $0) } == true
        }
    }
}
