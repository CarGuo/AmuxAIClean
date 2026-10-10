import XCTest
@testable import AppUI

// v2026.10.10: exercise retained intents and the native dismissal boundary, not
// elapsed sleeps or notification timing. No app, permission probe, or network is started.
final class MainWindowPresentationCoordinatorTests: XCTestCase {
    @MainActor
    func test_helpSurvivesWindowRecreationAndRejectsOldDismissal() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        model.requestUserGuide()
        model.requestUserGuide()
        XCTAssertEqual(model.pendingCount, 1)
        let oldHost = UUID()
        XCTAssertTrue(model.attachHost(oldHost))
        let original = try take(model, host: oldHost, mode: .professional)
        guard case .userGuide(let page, let mode) = original.content else {
            return XCTFail("Help must produce a walkthrough")
        }
        XCTAssertEqual(page, .proNavigation)
        XCTAssertEqual(mode, .professional)
        model.dismiss(hostID: oldHost, targetMode: .normal)
        model.detachHost(oldHost)

        let newHost = UUID()
        XCTAssertTrue(model.attachHost(newHost))
        model.requestInitialUserGuideIfNeeded(userGuideCompleted: true, isRunningTests: false)
        let reopened = try take(model, host: newHost, mode: .professional)
        XCTAssertNotEqual(original.id, reopened.id)
        XCTAssertNil(model.finishDismissal(hostID: oldHost, presentationID: original.id))
        XCTAssertEqual(model.visiblePresentation(for: newHost)?.id, reopened.id)
        model.dismiss(hostID: newHost)
        let completion = try XCTUnwrap(model.finishDismissal(hostID: newHost, presentationID: reopened.id))
        XCTAssertNil(completion.targetMode, "Closing a window must discard its abandoned mode switch")
    }

    @MainActor
    func test_initialGuideAndTCCWaitForBusinessAndNativeDismissal() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let host = UUID()
        model.attachHost(host)
        model.requestInitialUserGuideIfNeeded(userGuideCompleted: false, isRunningTests: false)
        model.requestInitialUserGuideIfNeeded(userGuideCompleted: false, isRunningTests: false)
        let outerTool = UUID()
        let confirmation = UUID()
        model.beginBusinessModal(outerTool)
        model.beginBusinessModal(confirmation)
        model.beginBusinessModal(confirmation)
        XCTAssertEqual(model.businessModalCount, 2)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        model.endBusinessModal(outerTool)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        model.endBusinessModal(confirmation)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: true))
        let guide = try take(model, host: host, mode: .professional)
        guard case .userGuide(let page, _) = guide.content else { return XCTFail("Expected initial guide") }
        XCTAssertEqual(page, .normalMode)

        model.dismiss(hostID: host, targetMode: .normal)
        model.requestFullDiskAccessGuide()
        model.requestFullDiskAccessGuide()
        XCTAssertNil(model.visiblePresentation(for: host))
        XCTAssertTrue(model.isOccupied, "A false binding is not native dismissal completion")
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        let completion = try XCTUnwrap(model.finishDismissal(hostID: host, presentationID: guide.id))
        XCTAssertEqual(completion.targetMode, .normal)
        let tcc = try take(model, host: host, mode: .normal)
        guard case .fullDiskAccess = tcc.content else { return XCTFail("Expected queued TCC guide") }
        XCTAssertEqual(model.pendingCount, 0)
    }

    @MainActor
    func test_reservedDrainRechecksBusinessAdmissionAndWindowIdentity() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let host = UUID()
        model.attachHost(host)
        model.requestUserGuide()
        XCTAssertTrue(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        XCTAssertTrue(model.isOccupied, "Sentinel cannot overtake an already reserved application slot")
        let business = UUID()
        model.beginBusinessModal(business)
        XCTAssertNil(model.takeScheduledIfPossible(hostID: host, isBusinessModalBusy: false, interfaceMode: .normal))
        XCTAssertEqual(model.pendingCount, 1)
        model.endBusinessModal(business)
        XCTAssertTrue(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        model.detachHost(host)
        let replacement = UUID()
        XCTAssertTrue(model.attachHost(replacement))
        XCTAssertNil(model.takeScheduledIfPossible(hostID: host, isBusinessModalBusy: false, interfaceMode: .normal))
        let guide = try take(model, host: replacement, mode: .professional)
        guard case .userGuide(let page, _) = guide.content else { return XCTFail("Expected retained guide") }
        XCTAssertEqual(page, .proNavigation, "Resolve the mode when presenting, not when requesting")
    }

    @MainActor
    func test_sheetOccupancySurvivesFalseBindingAndPresenterRemovalUntilNativeDismissal() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let host = UUID()
        model.attachHost(host)
        model.requestUserGuide()
        var sheet = BusinessSheetPresentationLifecycle()
        sheet.requestChanged(true, coordinator: model)
        sheet.appeared(coordinator: model)
        sheet.requestChanged(false, coordinator: model)
        sheet.presenterDisappeared(coordinator: model)
        XCTAssertEqual(model.businessModalCount, 1)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        sheet.dismissed(coordinator: model)
        // Existing deletion handoffs run after native dismissal and must observe a free slot.
        XCTAssertEqual(model.businessModalCount, 0)
        sheet.requestChanged(true, coordinator: model)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        sheet.requestChanged(false, coordinator: model)
        XCTAssertNotNil(try take(model, host: host, mode: .normal))
    }

    @MainActor
    func test_closingOneWindowDoesNotReleaseAnotherWindowsBusinessSheet() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let firstHost = UUID()
        let secondHost = UUID()
        model.attachHost(firstHost)
        var secondWindowSheet = BusinessSheetPresentationLifecycle()
        secondWindowSheet.requestChanged(true, coordinator: model, hostID: secondHost)
        secondWindowSheet.appeared(coordinator: model, hostID: secondHost)
        model.requestUserGuide()
        _ = try take(model, host: firstHost, mode: .normal)
        XCTAssertFalse(model.isOccupied(for: secondHost), "Another window's sheet must stay presented")
        model.detachHost(firstHost)
        XCTAssertEqual(model.businessModalCount(for: secondHost), 1)
        XCTAssertTrue(model.attachHost(secondHost))
        XCTAssertFalse(model.requestDrainIfPossible(hostID: secondHost, isBusinessModalBusy: false))
        secondWindowSheet.dismissed(coordinator: model)
        XCTAssertNotNil(try take(model, host: secondHost, mode: .professional))
    }

    @MainActor
    func test_updateReplacementAndWithdrawalWhileGuideOrWindowIsAbsent() async throws {
        let checker = UpdateChecker()
        let model = MainWindowPresentationCoordinator(updateChecker: checker)
        model.requestUserGuide()
        checker.availableUpdate = release("v2.0.0")
        checker.availableUpdate = release("v2.0.1")
        XCTAssertEqual(model.pendingCount, 2)
        let host = UUID()
        model.attachHost(host)
        let guide = try take(model, host: host, mode: .normal)
        model.dismiss(hostID: host)
        _ = model.finishDismissal(hostID: host, presentationID: guide.id)
        let update = try take(model, host: host, mode: .normal)
        guard case .update(let shown) = update.content else { return XCTFail("Expected update after guide") }
        XCTAssertEqual(shown.tagName, "v2.0.1")
        checker.availableUpdate = release("v2.0.2")
        XCTAssertTrue(model.isDismissing)
        XCTAssertNil(model.visiblePresentation(for: host))
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        model.detachHost(host)
        let newHost = UUID()
        model.attachHost(newHost)
        XCTAssertNil(model.finishDismissal(hostID: host, presentationID: update.id))
        let latest = try take(model, host: newHost, mode: .normal)
        guard case .update(let shownLatest) = latest.content else { return XCTFail("Expected current update") }
        XCTAssertEqual(shownLatest.tagName, "v2.0.2")
        checker.availableUpdate = nil
        model.detachHost(newHost)
        XCTAssertEqual(model.pendingCount, 0, "Withdrawn updates cannot be resurrected on window recreation")
    }

    @MainActor
    private func take(_ model: MainWindowPresentationCoordinator, host: UUID,
                      mode: SmartCareInterfaceMode) throws -> MainWindowPresentationCoordinator.Presentation {
        XCTAssertTrue(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        return try XCTUnwrap(model.takeScheduledIfPossible(hostID: host,
            isBusinessModalBusy: false, interfaceMode: mode))
    }

    private func release(_ tag: String) -> ReleaseInfo {
        ReleaseInfo(tagName: tag, name: tag,
                    htmlURL: URL(string: "https://github.com/CarGuo/GSYCleanMac/releases/tag/\(tag)")!,
                    body: "", publishedAt: nil)
    }
}
