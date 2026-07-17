import Foundation
import XCTest
@testable import AppUI

final class SettingsNavigationTests: XCTestCase {
    func test_allSettingsDestinationsRemainReachable() {
        XCTAssertEqual(
            SettingsNavigation.Destination.allCases,
            [.scan, .largeFiles, .customPaths, .update, .developerScan,
             .storageAndLogs, .ai, .advanced]
        )
        XCTAssertEqual(
            Set(SettingsNavigation.Destination.allCases.map(\.id)).count,
            SettingsNavigation.Destination.allCases.count
        )
    }

    /// v2026.07.16: the Ventura NavigationSplitView sidebar must expose every
    /// deep-link destination with stable localized metadata. This catches a new
    /// route being added to the model but omitted from the visible navigation.
    func test_allSettingsDestinationsHaveStableSidebarMetadata() {
        let expectedTitleKeys: [SettingsNavigation.Destination: String] = [
            .scan: "settings.tab.scan",
            .largeFiles: "settings.tab.large_files",
            .customPaths: "settings.tab.custom_paths",
            .update: "settings.tab.update",
            .developerScan: "settings.tab.dev_scan",
            .storageAndLogs: "settings.tab.storage",
            .ai: "settings.tab.ai",
            .advanced: "settings.tab.advanced"
        ]
        let expectedSystemImages: [SettingsNavigation.Destination: String] = [
            .scan: "magnifyingglass",
            .largeFiles: "doc.richtext",
            .customPaths: "folder.badge.plus",
            .update: "arrow.down.circle",
            .developerScan: "hammer",
            .storageAndLogs: "internaldrive",
            .ai: "sparkles",
            .advanced: "shield"
        ]

        XCTAssertEqual(expectedTitleKeys.count, SettingsNavigation.Destination.allCases.count)
        XCTAssertEqual(expectedSystemImages.count, SettingsNavigation.Destination.allCases.count)

        for destination in SettingsNavigation.Destination.allCases {
            XCTAssertEqual(destination.settingsTitleKey, expectedTitleKeys[destination])
            XCTAssertEqual(destination.settingsSystemImage, expectedSystemImages[destination])
        }
    }

    @MainActor
    func test_aiConfigurationRouteSelectsAISettingsTab() {
        let navigation = SettingsNavigation()

        XCTAssertEqual(navigation.destination, .scan)

        navigation.select(.ai)

        XCTAssertEqual(navigation.destination, .ai)
    }

    /// v2026.07.16：侧栏 switch 会销毁未选中的 detail；AI 草稿必须由 SettingsScene
    /// 持有，而不是重新落回 AISettingsTab 的局部 State。
    func test_aiDraftStateIsOwnedBySettingsSceneAcrossRoutes() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/AppUI/SettingsScene.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@StateObject private var aiTabState: AISettingsTabState"))
        XCTAssertTrue(source.contains("AISettingsTab(settings: aiSettings, state: aiTabState)"))
    }
}
