import XCTest
@testable import AppUI

// v2026.10.10: exercise retained intents and the native dismissal boundary, not
// elapsed sleeps or notification timing. No app, permission probe, or network is started.
final class MainWindowPresentationCoordinatorTests: XCTestCase {
    @MainActor
    func test_secondMainWindowCanOwnItsGuideWithoutClosingFirstWindow() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(model.attachHost(first))
        XCTAssertTrue(model.attachHost(second), "Cmd-N must register a second presentation host")
        let firstWindowTransaction = UUID()
        model.beginBusinessModal(firstWindowTransaction, hostID: first)
        model.requestUserGuide(hostID: second)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: first, isBusinessModalBusy: false))
        let guide = try take(model, host: second, mode: .professional)
        XCTAssertEqual(guide.hostID, second)
        guard case .userGuide(let mode) = guide.content else { return XCTFail("Expected guide") }
        XCTAssertEqual(mode, .professional)
        model.dismiss(hostID: second)
        XCTAssertEqual(model.finishDismissal(hostID: second, presentationID: guide.id)?.presentation.id, guide.id)
        XCTAssertEqual(model.businessModalCount(for: first), 1)
        model.endBusinessModal(firstWindowTransaction)
        model.focusHost(second)
        model.requestUserGuide() // Help menu uses focus; it never binds permanently to first.
        XCTAssertFalse(model.requestDrainIfPossible(hostID: first, isBusinessModalBusy: false))
        XCTAssertEqual(try take(model, host: second, mode: .normal).hostID, second)
    }

    @MainActor
    func test_toolbarRequestSelectsItsWindowForHelpBeforeNativeActivationCompletes() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let first = UUID(), second = UUID()
        var focusRequests: [UUID] = []
        model.attachHost(first, focusWindow: { focusRequests.append(first) })
        model.attachHost(second, focusWindow: { focusRequests.append(second) })
        model.focusHost(first)

        // The B control is the user's explicit intent, even if didBecomeKey has not arrived.
        model.requestUserGuide(hostID: second)
        let guide = try take(model, host: second, mode: .professional)
        model.dismiss(hostID: second)
        _ = model.finishDismissal(hostID: second, presentationID: guide.id)
        model.requestUserGuide()

        XCTAssertEqual(focusRequests, [second], "Help must retain the selected window, not the last native key event")
        XCTAssertFalse(model.requestDrainIfPossible(hostID: first, isBusinessModalBusy: false))
        XCTAssertEqual(try take(model, host: second, mode: .professional).hostID, second)
    }

    @MainActor
    func test_removedPresenterReleasesItsReservationWithoutDependingOnMissingDismissal() async {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let host = UUID()
        model.attachHost(host)
        var sheet = BusinessSheetPresentationLifecycle()
        sheet.requestChanged(true, coordinator: model, hostID: host)
        sheet.appeared(coordinator: model, hostID: host)
        sheet.presenterDisappeared(coordinator: model)
        XCTAssertEqual(model.businessModalCount(for: host), 0,
                       "A removed presenter cannot leave a lifetime-long reservation")
        XCTAssertFalse(sheet.hasPresentedSheet)
    }

    @MainActor
    func test_helpSurvivesWindowRecreationAndRejectsOldDismissal() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        model.requestUserGuide()
        model.requestUserGuide()
        XCTAssertEqual(model.pendingCount, 1)
        let oldHost = UUID()
        XCTAssertTrue(model.attachHost(oldHost))
        let original = try take(model, host: oldHost, mode: .professional)
        guard case .userGuide(let mode) = original.content else {
            return XCTFail("Help must produce a walkthrough")
        }
        XCTAssertEqual(mode, .professional)
        model.dismiss(hostID: oldHost)
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
        XCTAssertEqual(completion.presentation.id, reopened.id, "Only the recreated window may complete its tour")
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
        guard case .userGuide(let mode) = guide.content else { return XCTFail("Expected initial guide") }
        XCTAssertEqual(mode, .professional, "A control tour must use the actual displayed mode")

        model.dismiss(hostID: host)
        model.requestFullDiskAccessGuide()
        model.requestFullDiskAccessGuide()
        XCTAssertNil(model.visiblePresentation(for: host))
        XCTAssertTrue(model.isOccupied, "A false binding is not native dismissal completion")
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        let completion = try XCTUnwrap(model.finishDismissal(hostID: host, presentationID: guide.id))
        XCTAssertEqual(completion.presentation.id, guide.id)
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
        guard case .userGuide(let mode) = guide.content else { return XCTFail("Expected retained guide") }
        XCTAssertEqual(mode, .professional, "Resolve the mode when presenting, not when requesting")
    }

    @MainActor
    func test_falseBindingRetainsPresentationAndRemovalReleasesOnlyPresenterReservation() async throws {
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let host = UUID()
        model.attachHost(host)
        model.requestUserGuide()
        var sheet = BusinessSheetPresentationLifecycle()
        sheet.requestChanged(true, coordinator: model)
        sheet.appeared(coordinator: model)
        sheet.requestChanged(false, coordinator: model)
        XCTAssertEqual(model.businessModalCount, 1)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        // v2026.10.10: the old test incorrectly made a removed presenter authoritative for
        // native animation. Keep the animation barrier in the window, and release this owner.
        model.nativeSheetChanged(isPresented: true, hostID: host)
        sheet.presenterDisappeared(coordinator: model)
        XCTAssertEqual(model.businessModalCount, 1)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        model.nativeSheetChanged(isPresented: false, hostID: host)
        sheet.dismissed(coordinator: model)
        // Existing deletion handoffs run after native dismissal and must observe a free slot.
        XCTAssertEqual(model.businessModalCount, 0)
        sheet.requestChanged(true, coordinator: model)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: host, isBusinessModalBusy: false))
        sheet.requestChanged(false, coordinator: model)
        XCTAssertNotNil(try take(model, host: host, mode: .normal))
    }

    @MainActor
    func test_fullDiskAccessIsEvaluatedOnceAcrossLaterAndRecreatedWindows() async throws {
        actor ProbeCounter {
            var count = 0
            func probe() -> Bool { count += 1; return true }
        }
        let counter = ProbeCounter()
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let first = UUID()
        model.attachHost(first)
        model.evaluateFullDiskAccessOnboardingIfNeeded(isPermanentlyDismissed: false) { await counter.probe() }
        let evaluation = try XCTUnwrap(model.fullDiskAccessEvaluationTask)
        model.evaluateFullDiskAccessOnboardingIfNeeded(isPermanentlyDismissed: false) { await counter.probe() }
        await evaluation.value
        let guide = try take(model, host: first, mode: .normal)
        guard case .fullDiskAccess = guide.content else { return XCTFail("Expected permission guide") }
        model.dismiss(hostID: first) // "Later": no persistent preference is changed.
        XCTAssertNotNil(model.finishDismissal(hostID: first, presentationID: guide.id))
        model.detachHost(first)
        model.attachHost(UUID())
        model.evaluateFullDiskAccessOnboardingIfNeeded(isPermanentlyDismissed: false) { await counter.probe() }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.pendingCount, 0)
        let nextLaunch = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        nextLaunch.evaluateFullDiskAccessOnboardingIfNeeded(isPermanentlyDismissed: false) { await counter.probe() }
        await nextLaunch.fullDiskAccessEvaluationTask?.value
        let nextCount = await counter.count
        XCTAssertEqual(nextCount, 2, "Later must not permanently disable permission guidance")
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
