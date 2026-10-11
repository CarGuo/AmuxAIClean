import XCTest
@testable import AppUI

final class ControlGuideTests: XCTestCase {
    // v2026.10.10: the user explicitly rejected the old brochure contract. These assertions
    // verify real-control eligibility, navigation and geometry instead of four pages/four cards.
    func test_sequenceUsesOnlyRealControlsInTheCurrentMode() throws {
        let available: Set<ControlGuideTarget> = [.interfaceMode, .analyze, .clean, .optimize, .status,
                                                .sidebarOperations, .diskCapacity, .scanCategory, .pathInput,
                                                .rescan, .stash, .fullDisk, .deleteSelection, .reopenGuide]
        let normal = ControlGuideTarget.sequence(mode: .normal, available: available)
        XCTAssertEqual(normal, [.interfaceMode, .analyze, .clean, .optimize, .status, .reopenGuide])
        let pro = ControlGuideTarget.sequence(mode: .professional, available: available)
        XCTAssertEqual(pro, [.interfaceMode, .sidebarOperations, .scanCategory, .fullDisk, .diskCapacity, .pathInput,
                             .rescan, .deleteSelection, .stash, .reopenGuide])
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

    func test_firstLaunchPolicyRetainsCompletionSessionAndBusinessGuards() {
        XCTAssertTrue(UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(userGuideCompleted: false,
            hasEvaluatedInitialUserGuide: false, hasConflictingModal: false))
        XCTAssertFalse(UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(userGuideCompleted: true,
            hasEvaluatedInitialUserGuide: false, hasConflictingModal: false))
        XCTAssertFalse(UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(userGuideCompleted: false,
            hasEvaluatedInitialUserGuide: true, hasConflictingModal: false))
        XCTAssertFalse(UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(userGuideCompleted: false,
            hasEvaluatedInitialUserGuide: false, hasConflictingModal: true))
        XCTAssertFalse(UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(userGuideCompleted: false,
            hasEvaluatedInitialUserGuide: false, hasConflictingModal: false, isRunningTests: true))
    }

    func test_realControlTextIsLocalizedInBothLanguages() {
        let keys = ControlGuideTarget.allCases.flatMap { [$0.titleKey, $0.bodyKey] }
            + ["user_guide.window.title", "user_guide.action.skip", "user_guide.action.next", "user_guide.action.finish"]
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
        session = try XCTUnwrap(ControlGuideSession(presentationID: id, mode: .professional,
                                                   available: proRequired, required: proRequired))
        session.updateInitialAvailability(proRequired.union([.resultsMode, .deleteSelection]))
        XCTAssertEqual(session.steps.count, 21)
        XCTAssertTrue(session.advance())
        session.updateInitialAvailability(proRequired)
        XCTAssertEqual(session.steps.count, 21, "The running tour is frozen after the first user advance")
    }

}
