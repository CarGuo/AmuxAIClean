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

    @MainActor
    func test_aiConfigurationRouteSelectsAISettingsTab() {
        let navigation = SettingsNavigation()

        XCTAssertEqual(navigation.destination, .scan)

        navigation.select(.ai)

        XCTAssertEqual(navigation.destination, .ai)
    }
}
