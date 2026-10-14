import XCTest
@testable import AppUI

final class ControlGuideTests: XCTestCase {
    // v2026.10.10: the user explicitly rejected the old brochure contract. These assertions
    // verify real-control eligibility, navigation and geometry instead of four pages/four cards.
    func test_sequenceUsesOnlyRealControlsInTheCurrentMode() throws {
        let available: Set<ControlGuideTarget> = [.interfaceMode, .analyze, .clean, .optimize, .status,
                                                .sidebarOperations, .diskCapacity, .scanCategory, .pathInput,
                                                .rescan, .rowActions, .stash, .deleteSelection, .reopenGuide]
        let normal = ControlGuideTarget.sequence(mode: .normal, available: available)
        XCTAssertEqual(normal, [.interfaceMode, .analyze, .clean, .optimize, .status, .reopenGuide])
        let pro = ControlGuideTarget.sequence(mode: .professional, available: available)
        XCTAssertEqual(pro, [.interfaceMode, .scanCategory, .diskCapacity, .pathInput,
                             .rescan, .rowActions, .deleteSelection, .stash, .reopenGuide])
        XCTAssertFalse(pro.contains(.resultsMode), "No invented result control before a scan")
        XCTAssertTrue(pro.contains(.stash), "The permanent empty Stash entrance must also be taught")
        XCTAssertNil(ControlGuideSession(presentationID: UUID(), mode: .normal, available: []))
        let id = UUID()
        var session = try XCTUnwrap(ControlGuideSession(presentationID: id, mode: .professional, available: available))
        for expected in pro.dropFirst() {
            XCTAssertTrue(session.advance())
            XCTAssertEqual(session.target, expected)
            XCTAssertEqual(session.presentationID, id)
        }
        XCTAssertTrue(session.isLastStep)
        XCTAssertFalse(session.advance())
        XCTAssertTrue(ControlGuideEnd.completed.acknowledgesOnboarding)
        XCTAssertTrue(ControlGuideEnd.skipped.acknowledgesOnboarding)
        XCTAssertFalse(ControlGuideEnd.contextChanged.acknowledgesOnboarding)
    }

    func test_bubbleStaysInsideWindowWithoutCoveringItsControl() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        for target in [CGRect(x: 400, y: 15, width: 220, height: 28),
                       CGRect(x: 12, y: 160, width: 160, height: 25),
                       CGRect(x: 675, y: 550, width: 100, height: 30),
                       CGRect(x: 690, y: 200, width: 70, height: 30)] {
            for height: CGFloat in [130, 210] {
                let frame = ControlGuideLayout.bubbleFrame(target: target, size: CGSize(width: 320, height: height), bounds: bounds)
                XCTAssertTrue(bounds.contains(frame), "Translated text must remain in the resized viewport")
                XCTAssertFalse(frame.intersects(target), "Instructions must not cover the highlighted control")
            }
        }
    }

    func test_zeroAndSmallLayoutProposalsProduceFiniteNonnegativeGeometry() {
        for size in [CGSize.zero, CGSize(width: 8, height: 12), CGSize(width: 31, height: 400)] {
            let frame = ControlGuideLayout.bubbleFrame(target: CGRect(x: 0, y: 0, width: 10, height: 10),
                size: CGSize(width: 320, height: 200), bounds: CGRect(origin: .zero, size: size))
            XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
            XCTAssertGreaterThanOrEqual(frame.width, 0); XCTAssertGreaterThanOrEqual(frame.height, 0)
        }
    }

    func test_firstVisitPolicyUsesOnlyThatModesAcknowledgementAndSuppressesTestLaunches() {
        // Business/native presentation admission is tested in the production coordinator;
        // a busy window must retain this eligible request rather than consume a launch flag.
        for mode in SmartCareInterfaceMode.allCases {
            XCTAssertTrue(UserGuidePresentationPolicy.shouldAutoPresentOnVisit(mode: mode, completedModes: []))
            XCTAssertFalse(UserGuidePresentationPolicy.shouldAutoPresentOnVisit(mode: mode, completedModes: [mode]))
            let other = mode == .normal ? SmartCareInterfaceMode.professional : .normal
            XCTAssertTrue(UserGuidePresentationPolicy.shouldAutoPresentOnVisit(mode: mode, completedModes: [other]))
            XCTAssertFalse(UserGuidePresentationPolicy.shouldAutoPresentOnVisit(mode: mode,
                completedModes: [], isRunningTests: true))
        }
    }

    func test_realControlTextIsLocalizedInBothLanguages() {
        let keys = ControlGuideTarget.allCases.flatMap { [$0.titleKey, $0.bodyKey] }
            + ["user_guide.window.title", "user_guide.action.skip", "user_guide.action.next", "user_guide.action.finish",
               "user_guide.control.preparing", "user_guide.control.row_actions.example",
               "user_guide.control.row_actions.sample_file", "user_guide.control.row_actions.ai",
               "user_guide.control.row_actions.stash", "user_guide.control.row_actions.trash"]
        for locale in [Locale(identifier: "zh-Hans"), Locale(identifier: "en")] {
            for key in keys {
                let text = AppLocalization.string(key, locale: locale)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, key, "Missing \(locale.identifier): \(key)")
            }
        }
    }

    func test_firstFrameWaitsForPermanentControlsAndIncludesLaterContextUntilFirstNext() throws {
        let required = ControlGuideTarget.requiredTargets(mode: .normal)
        XCTAssertNil(ControlGuideSession(presentationID: UUID(), mode: .normal,
                                        available: [.interfaceMode], required: required))
        let id = UUID()
        var session = try XCTUnwrap(ControlGuideSession(presentationID: id, mode: .normal,
                                                       available: required, required: required))
        XCTAssertEqual(session.steps.count, 9)
        let navigationOnly = ControlGuideTarget.requiredTargets(mode: .normal, showsAnalysisControls: false)
        XCTAssertEqual(navigationOnly.count, 7, "Clean/Optimize/Status must not wait for unmounted Analyze controls")
        let proRequired = ControlGuideTarget.requiredTargets(mode: .professional)
        XCTAssertTrue(proRequired.contains(.rowActions), "AI / Stash / Trash must be taught before users have scanned anything")
        XCTAssertNil(ControlGuideSession(presentationID: id, mode: .professional,
                                        available: proRequired.subtracting([.rowActions]), required: proRequired))
        session = try XCTUnwrap(ControlGuideSession(presentationID: id, mode: .professional,
                                                   available: proRequired, required: proRequired))
        XCTAssertEqual(session.steps.filter { [.scanCategory, .customPaths, .professionalTools, .workflows].contains($0) }.count, 4,
                       "Adjacent sidebar sections are introduced together, not one tiny step per entry")
        XCTAssertEqual(session.steps.count, 11, "Empty-result guide still includes the item action example")
        session.updateInitialAvailability(proRequired.union([.resultsMode, .deleteSelection]))
        XCTAssertEqual(session.steps.count, 13)
        XCTAssertTrue(session.advance())
        session.updateInitialAvailability(proRequired)
        XCTAssertEqual(session.steps.count, 13, "The running tour is frozen after the first user advance")
    }

    func test_productionProgressIgnoresNextUntilReadyAndRejectsFoldedSidebarReveal() throws {
        var state = ControlGuideProgressState()
        let id = UUID()
        state.prepare(presentationID: id, mode: .professional, available: [], required: [.interfaceMode])
        XCTAssertNil(state.session)
        XCTAssertEqual(state.advance(), .ignored)
        state.prepare(presentationID: id, mode: .professional,
                      available: [.interfaceMode, .scanCategory, .customPaths], required: [.interfaceMode])
        XCTAssertEqual(state.locate(isVisible: true, canReveal: false), .ready)
        XCTAssertEqual(state.advance(), .advanced)
        XCTAssertEqual(state.advance(), .ignored, "A second Return cannot skip an unlocated next target")
        XCTAssertEqual(try XCTUnwrap(state.session).target, .scanCategory)
        let registered: Set<ControlGuideTarget> = [.scanCategory]
        XCTAssertTrue(ControlGuideAnchorPolicy.canReveal(.scanCategory, registered: registered, sidebarIsVisible: true))
        let canReveal = ControlGuideAnchorPolicy.canReveal(.scanCategory, registered: registered, sidebarIsVisible: false)
        XCTAssertFalse(canReveal)
        XCTAssertFalse(ControlGuideAnchorPolicy.available(visible: [.interfaceMode], registered: registered).contains(.scanCategory))
        XCTAssertEqual(state.locate(isVisible: false, canReveal: canReveal), .contextChanged)
        XCTAssertEqual(state.advance(), .ignored)
    }

    func test_productionRevealRetriesOnlyAfterActualLayoutChangesIncludingResize() throws {
        var state = ControlGuideProgressState()
        state.prepare(presentationID: UUID(), mode: .professional,
                      available: [.interfaceMode, .scanCategory], required: [])
        _ = state.locate(isVisible: true, canReveal: false)
        XCTAssertEqual(state.advance(), .advanced)
        XCTAssertTrue(state.shouldReveal(isVisible: false, canReveal: true, layoutRevision: 1))
        XCTAssertEqual(state.locate(isVisible: false, canReveal: true), .waiting)
        XCTAssertEqual(state.advance(), .ignored)
        XCTAssertFalse(state.shouldReveal(isVisible: false, canReveal: true, layoutRevision: 1), "No polling of an unchanged no-op scroll")
        XCTAssertTrue(state.shouldReveal(isVisible: false, canReveal: true, layoutRevision: 2), "Mounted/expanded layout revokes the old attempt")
        XCTAssertEqual(state.locate(isVisible: true, canReveal: true), .ready)
        XCTAssertFalse(state.shouldReveal(isVisible: true, canReveal: true, layoutRevision: 3), "Visible controls must not be scrolled on unrelated changes")
        XCTAssertTrue(state.shouldReveal(isVisible: false, canReveal: true, layoutRevision: 4), "Resize can clip the same target again")
        XCTAssertEqual(state.locate(isVisible: false, canReveal: true), .waiting)
        _ = state.locate(isVisible: true, canReveal: true)
        XCTAssertEqual(state.advance(), .completed)
    }
}
