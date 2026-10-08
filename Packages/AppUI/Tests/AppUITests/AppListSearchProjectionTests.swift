import Foundation
import XCTest
import SafetyKit
@testable import AppUI

final class AppListSearchProjectionTests: XCTestCase {
    func test_visibleSelectionUsesRediscoveredBundleIdentityAndHiddenOwnerIsCleared() throws {
        let url = URL(fileURLWithPath: "/Applications/Example.app")
        let metadata = AppMetadata(bundleID: "com.example.app", bundleVendor: "com.example",
                                   appName: "Example", executableName: "Example")
        let previous = InstalledApp(appURL: url, metadata: metadata,
                                    fileIdentity: .init(deviceID: 1, inode: 10))
        let replacement = InstalledApp(appURL: url, metadata: metadata,
                                       fileIdentity: .init(deviceID: 1, inode: 20))
        let visible = AppListSearchProjection(items: [replacement], selection: previous,
                                              query: "  EXAMPLE \n") {
            $0.metadata.appName.localizedCaseInsensitiveContains($1)
        }
        let selected = try XCTUnwrap(visible.selection)
        XCTAssertEqual(try XCTUnwrap(UninstallSelectedAppIdentity(installedApp: selected)).expectedFileIdentity.inode, 20)
        let hidden = AppListSearchProjection(items: [replacement], selection: selected, query: "other") {
            $0.metadata.appName.localizedCaseInsensitiveContains($1)
        }
        XCTAssertTrue(hidden.items.isEmpty)
        XCTAssertNil(hidden.selection, "a hidden App cannot retain candidate/deletion ownership")
    }
}
