import XCTest
import ScanKit
@testable import AppUI

final class DuplicateHandlingPlanTests: XCTestCase {
    func test_defaultDeleteTargets_keepsFirstCopy() {
        let group = DuplicateGroup(hashKey: "g", bytes: 100, paths: ["/a", "/b", "/c"], reliability: .full)

        XCTAssertEqual(DuplicateHandlingPlan.defaultDeleteTargets(for: group), ["/b", "/c"])
    }

    func test_isValidDeleteTargets_requiresAtLeastOneRemainingCopy() {
        let group = DuplicateGroup(hashKey: "g", bytes: 100, paths: ["/a", "/b", "/c"], reliability: .full)

        XCTAssertTrue(DuplicateHandlingPlan.isValidDeleteTargets(["/b", "/c"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets([], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/a", "/b", "/c"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/b", "/b"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/outside"], for: group))
    }
}
