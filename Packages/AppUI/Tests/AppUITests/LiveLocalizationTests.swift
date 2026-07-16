import XCTest
import AppKit
@testable import AppUI

final class LiveLocalizationTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private let simplifiedChinese = Locale(identifier: "zh-Hans")

    func test_explicitLocaleResolver_switchesCatalogLanguageWithinOneProcess() {
        XCTAssertEqual(
            AppLocalization.string("capacity.reclaimable.info.title", locale: english),
            "System-Reclaimable Space"
        )
        XCTAssertEqual(
            AppLocalization.string("capacity.reclaimable.info.title", locale: simplifiedChinese),
            "系统可能释放的空间"
        )
        XCTAssertEqual(
            AppLocalization.string("workflow.detail.managed_uninstall.review.title", locale: simplifiedChinese),
            "检查模拟器资源"
        )
        XCTAssertEqual(
            AppLocalization.string("workflow.detail.managed_uninstall.confirm.runtimes", locale: simplifiedChinese),
            "卸载运行时"
        )
    }

    func test_explicitLocaleFormatter_switchesFormatStringWithinOneProcess() {
        XCTAssertEqual(
            AppLocalization.format(
                "main.scan.progress.single",
                locale: english,
                arguments: [Int64(12), "3 GB"]
            ),
            "Scanning… 12 files · 3 GB"
        )
        XCTAssertEqual(
            AppLocalization.format(
                "main.scan.progress.single",
                locale: simplifiedChinese,
                arguments: [Int64(12), "3 GB"]
            ),
            "扫描中… 12 个文件 · 3 GB"
        )
    }

    func test_scanCategory_displayTitle_usesRequestedLiveLocale() {
        let category = ScanCategories.recommended().first {
            $0.title == "category.user_caches.title"
        }
        XCTAssertEqual(category?.displayTitle(locale: english), "User Caches")
        XCTAssertEqual(category?.displayTitle(locale: simplifiedChinese), "用户缓存")
    }

    func test_dynamicRuleText_localizesKnownKey_andPreservesRawDirectoryName() {
        XCTAssertEqual(
            AppLocalization.string("rule.zig.local_cache.subtitle", locale: english),
            "Zig local build cache beside build.zig."
        )
        XCTAssertEqual(
            AppLocalization.string("rule.zig.local_cache.subtitle", locale: simplifiedChinese),
            "build.zig 旁的 Zig 本地构建缓存。"
        )
        XCTAssertEqual(
            AppLocalization.string("node_modules", locale: simplifiedChinese),
            "node_modules"
        )
    }

    func test_treeBrowser_appKitProjection_switchesTooltipAndPartialStateWithinOneProcess() {
        let denied = TreeRow(
            path: "/Users/test/Library",
            title: "Library",
            bytes: 0,
            fileCount: 0,
            isDirectory: true,
            hasChildren: false,
            accessState: .permissionDenied
        )
        XCTAssertTrue(
            TreeBrowserLiveLocalization.accessHelp(for: denied, locale: english)?
                .contains("Full Disk Access") == true
        )
        XCTAssertTrue(
            TreeBrowserLiveLocalization.accessHelp(for: denied, locale: simplifiedChinese)?
                .contains("完整磁盘访问") == true
        )

        let partial = TreeRow(
            path: "/Users/test/Library/Caches",
            title: "Caches",
            bytes: 1_234_567,
            fileCount: 456,
            isDirectory: true,
            hasChildren: true,
            subtreeCompleteness: .containsIncompleteDescendant
        )
        XCTAssertEqual(
            TreeBrowserLiveLocalization.metricPresentation(row: partial, locale: english)
                .partialStatusText,
            "Partial"
        )
        XCTAssertEqual(
            TreeBrowserLiveLocalization.metricPresentation(row: partial, locale: simplifiedChinese)
                .partialStatusText,
            "部分"
        )
    }

    func test_treeAndListRow_projection_switchesHelpDatesAndVerdictWithinOneProcess() throws {
        XCTAssertEqual(
            RowViewLiveLocalization.verdictLabel(.safe, locale: english),
            "Safe to clean"
        )
        XCTAssertEqual(
            RowViewLiveLocalization.verdictLabel(.safe, locale: simplifiedChinese),
            "可放心清理"
        )
        XCTAssertTrue(
            RowViewLiveLocalization.protectedHelp(
                rejection: .hardForbidPrefix,
                locale: english
            ).hasPrefix("Protected:")
        )
        XCTAssertTrue(
            RowViewLiveLocalization.protectedHelp(
                rejection: .hardForbidPrefix,
                locale: simplifiedChinese
            ).hasPrefix("受保护：")
        )

        let date = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 7, day: 15, hour: 22, minute: 30)
            )
        )
        XCTAssertNotEqual(
            RowViewLiveLocalization.mtimeFull(date, locale: english),
            RowViewLiveLocalization.mtimeFull(date, locale: simplifiedChinese)
        )
        XCTAssertNotEqual(
            TreeBrowserLiveLocalization.mtimeFullHelp(date, locale: english),
            TreeBrowserLiveLocalization.mtimeFullHelp(date, locale: simplifiedChinese)
        )
        XCTAssertEqual(
            TreeBrowserLiveLocalization.mtimeFullHelp(nil, locale: simplifiedChinese),
            "聚合节点 — 该行没有自身的修改时间（例如虚拟根目录或分类汇总）。"
        )
    }

    func test_settingsPathNotice_reprojectsWithoutRepeatingImport() {
        let notice = SettingsPathImportNotice.duplicate(count: 2)
        XCTAssertEqual(notice.localized(locale: english), "Already in the list: 2.")
        XCTAssertEqual(notice.localized(locale: simplifiedChinese), "选中的 2 个路径已在列表中。")
    }

    func test_settingsLogNotice_reprojectsWhilePreservingOperationPayload() {
        let notice = SettingsLogActionNotice.exported(path: "/tmp/AmuxAIClean-Logs.txt")
        XCTAssertEqual(
            notice.localized(locale: english),
            "Exported to /tmp/AmuxAIClean-Logs.txt"
        )
        XCTAssertEqual(
            notice.localized(locale: simplifiedChinese),
            "已导出到 /tmp/AmuxAIClean-Logs.txt"
        )
    }

    func test_scanProgressTitle_reprojectsWithoutRescanning() {
        let progress = ScanCoordinator.PerRootProgress(
            rootPath: "/tmp/cache",
            title: "User Caches",
            titleLocalizationKey: "category.user_caches.title"
        )
        XCTAssertEqual(progress.displayTitle(locale: english), "User Caches")
        XCTAssertEqual(progress.displayTitle(locale: simplifiedChinese), "用户缓存")
    }

    @MainActor
    func test_floatingHUD_usesAttachedSettingsLocaleWithoutScanRebuild() {
        let suite = "LiveLocalizationTests.hud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let settings = AppSettings(testSuite: suite)
        settings.preferredLanguage = .en
        XCTAssertEqual(
            FloatingHUDLocalization.string("hud.scanning", locale: settings.effectiveLocale),
            "Scanning"
        )
        XCTAssertEqual(
            FloatingHUDLocalization.string("hud.help.open_main", locale: settings.effectiveLocale),
            "Open main window"
        )

        // 同一个 settings 实例切换语言；不创建或替换 ScanCoordinator。
        settings.preferredLanguage = .zhHans
        XCTAssertEqual(
            FloatingHUDLocalization.string("hud.scanning", locale: settings.effectiveLocale),
            "扫描中"
        )
        XCTAssertEqual(
            FloatingHUDLocalization.string("hud.help.open_main", locale: settings.effectiveLocale),
            "打开主窗口"
        )
        XCTAssertEqual(
            FloatingHUDLocalization.severityLabel(.critical, locale: settings.effectiveLocale),
            "需要清理"
        )
    }

    func test_workflowHitTitle_keepsSemanticKeyUntilViewProjection() {
        let stored = "versioned-root.apple.ios-device-support.displayName · 17.5"
        XCTAssertEqual(
            WorkflowHitNamePresentation.string(stored, locale: english),
            "iOS Device Support · 17.5"
        )
        XCTAssertEqual(
            WorkflowHitNamePresentation.string(stored, locale: simplifiedChinese),
            "iOS 设备支持文件 · 17.5"
        )
    }

    @MainActor
    func test_statusItemMenu_canRebuildInRequestedLocale() {
        let controller = StatusItemController()
        let englishMenu = controller._testMenuSnapshot(scanning: false, locale: english)
        let chineseMenu = controller._testMenuSnapshot(scanning: false, locale: simplifiedChinese)

        XCTAssertEqual(englishMenu.items.first?.title, "Open Main Window")
        XCTAssertEqual(chineseMenu.items.first?.title, "打开主窗口")
    }

    @MainActor
    func test_nativeApplicationMenu_localizesBySemanticIdentity_notTitleOrIndex() {
        func item(action: String, keyEquivalent: String = "") -> NSMenuItem {
            NSMenuItem(
                title: "stale",
                action: NSSelectorFromString(action),
                keyEquivalent: keyEquivalent
            )
        }
        func root(_ submenu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: "stale-root", action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }

        let services = NSMenu(title: "stale-services")
        let app = NSMenu(title: "stale-app")
        app.addItem(item(action: "thirdPartyCommand:"))
        app.addItem(item(action: "orderFrontStandardAboutPanel:"))
        app.addItem(item(action: "openSettings:", keyEquivalent: ","))
        let servicesItem = NSMenuItem(title: "stale", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        app.addItem(item(action: "hide:"))
        app.addItem(item(action: "hideOtherApplications:"))
        app.addItem(item(action: "unhideAllApplications:"))
        app.addItem(item(action: "terminate:"))

        let file = NSMenu(title: "stale-file")
        file.addItem(item(action: "performClose:"))
        let edit = NSMenu(title: "stale-edit")
        edit.addItem(item(action: "copy:"))
        let view = NSMenu(title: "stale-view")
        view.addItem(item(action: "toggleToolbarShown:"))
        let windows = NSMenu(title: "stale-window")
        windows.addItem(item(action: "performMiniaturize:"))
        let help = NSMenu(title: "stale-help")

        let main = NSMenu(title: "main")
        // 故意打乱标准顺序；合同必须靠 selector / NSApplication menu identity 识别。
        [help, edit, app, windows, file, view].forEach { main.addItem(root($0)) }

        ApplicationMenuLocalizer.apply(
            to: main,
            locale: simplifiedChinese,
            appName: "AmuxAIClean",
            servicesMenu: services,
            windowsMenu: windows,
            helpMenu: help
        )

        XCTAssertEqual(main.items[0].title, "帮助")
        XCTAssertEqual(main.items[1].title, "编辑")
        XCTAssertEqual(main.items[2].title, "AmuxAIClean")
        XCTAssertEqual(main.items[3].title, "窗口")
        XCTAssertEqual(main.items[4].title, "文件")
        XCTAssertEqual(main.items[5].title, "显示")
        XCTAssertEqual(app.items[0].title, "stale", "未知命令不能按位置误判为 About")
        XCTAssertEqual(app.items[1].title, "关于 AmuxAIClean")
        XCTAssertEqual(app.items[2].title, "设置…")
        XCTAssertEqual(app.items[3].title, "服务")
        XCTAssertEqual(app.items[4].title, "隐藏 AmuxAIClean")
        XCTAssertEqual(app.items[5].title, "隐藏其他")
        XCTAssertEqual(app.items[6].title, "全部显示")
        XCTAssertEqual(app.items[7].title, "退出 AmuxAIClean")
    }

    @MainActor
    func test_managedUninstallBlockedReason_usesSheetLocale() {
        let reason = WorkflowDetailViewModel.SimulatorUninstallBlockReason.invalidSelection
        XCTAssertNotEqual(
            reason.localizedMessage(locale: english),
            reason.localizedMessage(locale: simplifiedChinese)
        )
    }

    func test_longLivedToolResultStates_reprojectWithoutRepeatingOperation() {
        let undo = UndoHistoryAlertPresentation.partial(
            restored: 2,
            skipped: 1,
            failure: .moveFailed(systemDescription: "raw filesystem error")
        )
        XCTAssertNotEqual(undo.text(locale: english), undo.text(locale: simplifiedChinese))
        XCTAssertTrue(undo.text(locale: english).contains("raw filesystem error"))
        XCTAssertTrue(undo.text(locale: simplifiedChinese).contains("raw filesystem error"))

        XCTAssertEqual(
            PortCleanerKillTitle.selected.text(locale: english),
            "Quit Selected"
        )
        XCTAssertEqual(
            PortCleanerKillTitle.selected.text(locale: simplifiedChinese),
            "结束所选"
        )
        let killResult = PortCleanerKillResultPresentation(success: 2, failed: 1)
        XCTAssertNotEqual(
            killResult.text(locale: english),
            killResult.text(locale: simplifiedChinese)
        )
    }

    func test_destructiveSheetCopyAndSafetyReason_useCurrentSheetLocale() {
        let englishCopy = ToolTrashConfirmationCopyResolver.resolve(
            profile: .normal,
            itemCount: 2,
            totalBytes: 1_000,
            locale: english
        )
        let chineseCopy = ToolTrashConfirmationCopyResolver.resolve(
            profile: .normal,
            itemCount: 2,
            totalBytes: 1_000,
            locale: simplifiedChinese
        )
        XCTAssertNotEqual(englishCopy.title, chineseCopy.title)
        XCTAssertNotEqual(englishCopy.message, chineseCopy.message)
        XCTAssertNotEqual(
            DeletionSafetyReasonPresentation.text(for: "systemVolume", locale: english),
            DeletionSafetyReasonPresentation.text(for: "systemVolume", locale: simplifiedChinese)
        )
    }
}
