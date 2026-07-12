import XCTest
@testable import AppUI

final class SettingsNavigationTests: XCTestCase {
    @MainActor
    func test_aiConfigurationRouteSelectsAISettingsTab() {
        let navigation = SettingsNavigation()

        XCTAssertEqual(navigation.destination, .scan)

        navigation.select(.ai)

        XCTAssertEqual(navigation.destination, .ai)
    }
}
