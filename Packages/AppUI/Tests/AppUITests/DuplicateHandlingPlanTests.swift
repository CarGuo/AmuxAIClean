import XCTest
import ScanKit
@testable import AppUI

final class DuplicateHandlingPlanTests: XCTestCase {
    private func makeGroup() -> DuplicateGroup {
        DuplicateGroup(
            hashKey: "g",
            logicalBytes: 100,
            files: [
                DuplicateFile(path: "/a", allocatedBytes: 80),
                DuplicateFile(path: "/b", allocatedBytes: 40),
                DuplicateFile(path: "/c", allocatedBytes: 20)
            ],
            reliability: .full
        )
    }

    func test_defaultDeleteTargets_keepsFirstCopy() {
        let group = makeGroup()

        XCTAssertEqual(DuplicateHandlingPlan.defaultDeleteTargets(for: group), ["/b", "/c"])
        XCTAssertEqual(group.reclaimableBytes, 60,
                       "默认可释放必须精确对应默认删除路径的 allocated bytes")
    }

    func test_isValidDeleteTargets_requiresAtLeastOneRemainingCopy() {
        let group = makeGroup()

        XCTAssertTrue(DuplicateHandlingPlan.isValidDeleteTargets(["/b", "/c"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets([], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/a", "/b", "/c"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/b", "/b"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/outside"], for: group))
    }

    func test_manualSelectionUsesPerPathAllocatedBytes() {
        let group = makeGroup()

        XCTAssertEqual(group.allocatedBytes(for: ["/a", "/c"]), 100)
        XCTAssertEqual(group.allocatedBytes(for: ["/outside"]), 0)
    }

    func test_pruningReusesUnaffectedGroupsAndRecomputesOnlyAffectedAllocatedTotals() {
        let affected = makeGroup()
        let unaffected = DuplicateGroup(
            hashKey: "other",
            logicalBytes: 200,
            files: [
                DuplicateFile(path: "/x", allocatedBytes: 70),
                DuplicateFile(path: "/y", allocatedBytes: 30)
            ],
            reliability: .full
        )

        let result = DuplicateHandlingPlan.pruning(
            [affected, unaffected],
            movedPaths: ["/b"]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].paths, ["/a", "/c"])
        XCTAssertEqual(result[0].totalBytes, 100)
        XCTAssertEqual(result[0].reclaimableBytes, 20)
        XCTAssertEqual(result[1], unaffected)
    }
}
