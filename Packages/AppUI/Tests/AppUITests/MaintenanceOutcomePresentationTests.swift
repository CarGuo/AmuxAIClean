import ScanKit
import XCTest
@testable import AppUI

@MainActor
final class MaintenanceOutcomePresentationTests: XCTestCase {
    func testUserPresentationUsesLocalizedTypedStatusInsteadOfDiagnosticOutput() {
        let english = MaintenanceOutcomePresentation.message(
            for: .exited(code: 7),
            locale: Locale(identifier: "en")
        )
        let chinese = MaintenanceOutcomePresentation.message(
            for: .exited(code: 7),
            locale: Locale(identifier: "zh-Hans")
        )

        XCTAssertTrue(english.contains("7"))
        XCTAssertTrue(chinese.contains("7"))
        XCTAssertFalse(english.contains("stderr"))
        XCTAssertFalse(chinese.contains("stderr"))
    }

    func testEveryTypedTerminalHasBothLocalizedPresentations() {
        let statuses: [MaintenanceTasks.Outcome.Status] = [
            .succeeded,
            .exited(code: 1),
            .timedOut,
            .cancelled,
            .ownershipLost,
            .launchFailed,
        ]

        for status in statuses {
            let english = MaintenanceOutcomePresentation.message(
                for: status,
                locale: Locale(identifier: "en")
            )
            let chinese = MaintenanceOutcomePresentation.message(
                for: status,
                locale: Locale(identifier: "zh-Hans")
            )
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(chinese.isEmpty)
            XCTAssertNotEqual(english, chinese)
        }
    }

    func testRunGateRejectsOldRevisionAndCancelledCurrentRun() {
        let old = MaintenanceRunIdentity(
            operationID: UUID(), revision: 1, tasks: [.flushQuickLookCache]
        )
        let current = MaintenanceRunIdentity(
            operationID: UUID(), revision: 2, tasks: [.flushDNSCache]
        )
        var gate = MaintenanceRunGate()
        gate.begin(old)
        gate.begin(current)

        XCTAssertNil(gate.finishIfCurrent(old, taskWasCancelled: false))
        XCTAssertEqual(gate.current, current)
        XCTAssertEqual(gate.finishIfCurrent(current, taskWasCancelled: true), false)
        XCTAssertNil(gate.current)
    }
}
