import AppKit
import SwiftUI
import XCTest
@testable import AppUI

/// C2: real NSWindow sheet notifications, without launching the production App or touching
/// user data. This verifies the native boundary; it is not a production UI acceptance run.
@MainActor
final class NativeSheetOccupancyTests: XCTestCase {
    private enum Route: String, Identifiable {
        case source, destination
        var id: String { rawValue }
    }

    private final class Flow: ObservableObject {
        @Published var route: Route?
        @Published var handoff = SheetDismissalHandoff<Route>()
        var countAtDismissal: Int?
    }

    private struct Fixture: View {
        @ObservedObject var flow: Flow
        let model: MainWindowPresentationCoordinator
        let hostID: UUID

        var body: some View {
            Text("Sheet lifecycle fixture")
                .mainWindowBusinessTransaction(isActive: flow.route != nil || flow.handoff.hasPending)
                .localizedSheet(item: $flow.route, onDismiss: {
                    flow.countAtDismissal = model.businessModalCount(for: hostID)
                    if let next = flow.handoff.takeAfterSheetDismissal() { flow.route = next }
                }) { route in
                    Text(route.rawValue).frame(width: 240, height: 120)
                }
                .background(MainWindowPresentationHost(coordinator: model, hostID: hostID))
                .environment(\.mainWindowPresentationCoordinator, model)
                .environment(\.mainWindowPresentationHostID, hostID)
        }
    }

    // Native SwiftUI integration verifies onDismiss ordering and the actual shared modifier,
    // not just manually setting coordinator counts. No network or filesystem operation occurs.
    func test_localizedSheetHandoffKeepsTransactionAndShowsDestinationAfterActualDismissal() async throws {
        _ = NSApplication.shared
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let hostID = UUID()
        let flow = Flow()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Fixture(flow: flow, model: model, hostID: hostID))
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            model.detachHost(hostID)
            window.close()
        }
        window.orderFront(nil)
        flow.route = .source
        for _ in 0..<200 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let source = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(model.businessTransactionCount(for: hostID), 1)
        model.requestUserGuide(hostID: hostID)
        XCTAssertTrue(flow.handoff.schedule(.destination))
        flow.route = nil
        XCTAssertFalse(model.requestDrainIfPossible(hostID: hostID, isBusinessModalBusy: false))
        for _ in 0..<200 {
            if flow.route == .destination, let attached = window.attachedSheet, attached !== source { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(flow.route, .destination)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertFalse(window.attachedSheet === source)
        XCTAssertEqual(flow.countAtDismissal, 1,
                       "Native closing barrier and source lease ended; only the pending transaction remains")
        XCTAssertFalse(model.requestDrainIfPossible(hostID: hostID, isBusinessModalBusy: false))
        flow.route = nil
        for _ in 0..<200 where model.businessModalCount(for: hostID) > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.businessModalCount(for: hostID), 0)
        XCTAssertTrue(model.requestDrainIfPossible(hostID: hostID, isBusinessModalBusy: false))
    }

    func test_nativeSheetRetainsBarrierAfterPresenterRemovalAndReleasesOnActualEnd() async throws {
        _ = NSApplication.shared
        let model = MainWindowPresentationCoordinator(updateChecker: UpdateChecker())
        let id = UUID()
        let host = MainWindowPresentationHost.HostView(coordinator: model, hostID: id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        sheetWindow.isReleasedWhenClosed = false
        defer {
            host.detach()
            sheetWindow.close()
            window.close()
        }
        var presenter = BusinessSheetPresentationLifecycle()
        presenter.requestChanged(true, coordinator: model, hostID: id)
        window.orderFront(nil)
        window.beginSheet(sheetWindow, completionHandler: { _ in })
        for _ in 0..<100 where window.attachedSheet !== sheetWindow {
            try await Task.sleep(for: .milliseconds(10))
        }
        presenter.appeared(coordinator: model, hostID: id)
        XCTAssertTrue(window.attachedSheet === sheetWindow)
        presenter.presenterDisappeared(coordinator: model)
        XCTAssertEqual(model.businessModalCount(for: id), 1, "Only the physical sheet remains")
        model.requestUserGuide(hostID: id)
        XCTAssertFalse(model.requestDrainIfPossible(hostID: id, isBusinessModalBusy: false))
        window.endSheet(sheetWindow)
        for _ in 0..<100 where model.businessModalCount(for: id) > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.businessModalCount(for: id), 0)
        presenter.dismissed(coordinator: model) // Late/missing SwiftUI callback is harmless.
        XCTAssertEqual(model.businessModalCount(for: id), 0)
        XCTAssertTrue(model.requestDrainIfPossible(hostID: id, isBusinessModalBusy: false))
    }
}
