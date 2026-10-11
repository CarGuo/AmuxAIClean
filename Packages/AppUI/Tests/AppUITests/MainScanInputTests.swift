import XCTest
@testable import AppUI

final class MainScanInputTests: XCTestCase {
    func test_asyncInputIsSingleFlightAndOldCompletionCannotConsumeNewRequest() throws {
        let context = MainScanContextIdentity(interfaceMode: .professional, categoryID: "fixture", scanSessionID: UUID())
        var state = MainScanInputRequestState()
        let first = try XCTUnwrap(state.begin(in: context, input: "first"))
        XCTAssertNil(state.begin(in: context, input: "first"))
        XCTAssertFalse(state.matches(context, input: "edited"))
        state.invalidate()
        let second = try XCTUnwrap(state.begin(in: context, input: "edited"))
        XCTAssertFalse(state.take(first, in: context, input: "first", isAdmitted: true))
        XCTAssertEqual(state.requestID, second)
        XCTAssertTrue(state.take(second, in: context, input: "edited", isAdmitted: true))
        XCTAssertFalse(state.take(second, in: context, input: "edited", isAdmitted: true))
    }

    func test_inputAndConfirmedSwitchRejectChangedSessionModeOrAdmissionBeforeCommit() throws {
        let context = MainScanContextIdentity(interfaceMode: .professional, categoryID: "fixture", scanSessionID: UUID())
        let newerScan = MainScanContextIdentity(interfaceMode: .professional, categoryID: "fixture", scanSessionID: UUID())
        let normal = MainScanContextIdentity(interfaceMode: .normal, categoryID: "fixture", scanSessionID: context.scanSessionID)
        let intent = MainCategorySwitchIntent(source: context, destinationID: "next", fallbackCategory: nil, customPaths: [])
        XCTAssertTrue(intent.isCurrent(in: context))
        XCTAssertFalse(intent.isCurrent(in: newerScan))
        XCTAssertFalse(intent.isCurrent(in: normal))
        var state = MainScanInputRequestState()
        for (current, admitted) in [(newerScan, true), (normal, true), (context, false)] {
            let id = try XCTUnwrap(state.begin(in: context))
            XCTAssertFalse(state.take(id, in: current, isAdmitted: admitted))
            XCTAssertNil(state.requestID, "Rejected work ends before any persistence or category mutation")
        }
    }
}
