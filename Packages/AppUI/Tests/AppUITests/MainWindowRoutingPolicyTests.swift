import XCTest
@testable import AppUI

final class MainWindowRoutingPolicyTests: XCTestCase {
    func test_settingsWindowBeforeMainWindowStillRoutesToMainWindow() {
        let windows = [
            descriptor(identifier: "com.apple.SwiftUI.Settings"),
            descriptor(identifier: MainWindowRoutingPolicy.mainWindowIdentifierRawValue)
        ]

        XCTAssertEqual(
            MainWindowRoutingPolicy.decision(windows: windows, canRequestMainScene: true),
            .focusExisting(index: 1)
        )
    }

    func test_settingsWindowAloneRequestsMainSceneInsteadOfFocusingSettings() {
        let windows = [descriptor(identifier: "com.apple.SwiftUI.Settings")]

        XCTAssertEqual(
            MainWindowRoutingPolicy.decision(windows: windows, canRequestMainScene: true),
            .requestMainScene
        )
    }

    func test_missingMainWindowAndSceneOpenerFallsBackToApplicationReopen() {
        XCTAssertEqual(
            MainWindowRoutingPolicy.decision(
                windows: [descriptor(identifier: "com.apple.SwiftUI.Settings")],
                canRequestMainScene: false
            ),
            .reopenApplication
        )
    }

    func test_settingsWindowDoesNotCountAsVisibleMainWindow() {
        let settings = descriptor(
            identifier: "com.apple.SwiftUI.Settings",
            isVisible: true
        )
        let main = descriptor(
            identifier: MainWindowRoutingPolicy.mainWindowIdentifierRawValue,
            isVisible: false,
            isMiniaturized: true
        )

        XCTAssertFalse(MainWindowRoutingPolicy.hasVisibleMainWindow(in: [settings]))
        XCTAssertTrue(MainWindowRoutingPolicy.hasVisibleMainWindow(in: [settings, main]))
    }

    func test_invalidWindowWithMainIdentifierIsNotSelected() {
        let panel = descriptor(
            identifier: MainWindowRoutingPolicy.mainWindowIdentifierRawValue,
            isPanel: true
        )
        let disposed = descriptor(
            identifier: MainWindowRoutingPolicy.mainWindowIdentifierRawValue,
            isDisposed: true
        )

        XCTAssertEqual(
            MainWindowRoutingPolicy.decision(
                windows: [panel, disposed],
                canRequestMainScene: true
            ),
            .requestMainScene
        )
    }

    private func descriptor(
        identifier: String?,
        isPanel: Bool = false,
        hasContentViewController: Bool = true,
        isDisposed: Bool = false,
        isVisible: Bool = true,
        isMiniaturized: Bool = false
    ) -> WindowRouteDescriptor {
        WindowRouteDescriptor(
            identifier: identifier,
            isPanel: isPanel,
            hasContentViewController: hasContentViewController,
            isDisposed: isDisposed,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized
        )
    }
}
