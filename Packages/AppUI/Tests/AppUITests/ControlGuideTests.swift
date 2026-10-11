import AppKit
import Combine
import SwiftUI
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

    @MainActor
    func test_nativeToolbarAndContentAnchorsShareWindowCoordinatesAndResizeWithIt() async throws {
        _ = NSApplication.shared
        let anchors = ControlGuideAnchors()
        let window = NSWindow(contentRect: NSRect(x: -100, y: 100, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            VStack { Button("Scan fixture") {}.controlGuideTarget(.analysisScan); Spacer() }
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.controlGuideAnchors, anchors))
        let delegate = ToolbarFixture(anchors: anchors)
        let toolbar = NSToolbar(identifier: "ControlGuide.C2.Toolbar")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        let controller = ControlGuideController(anchors: anchors)
        var endings: [ControlGuideEnd] = []
        controller.configure(presentationID: UUID(), mode: .normal, locale: Locale(identifier: "en")) { _, reason in endings.append(reason) }
        controller.attach(to: window)
        defer { controller.detach(); window.close() }
        window.orderFront(nil)
        for _ in 0..<200 where controller.session == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.session?.target, .interfaceMode)
        XCTAssertNil(window.attachedSheet, "Onboarding is an overlay, never a brochure sheet")
        XCTAssertEqual(window.childWindows?.count, 1)
        let modeFrame = try XCTUnwrap(anchors.frame(for: .interfaceMode, in: window))
        let scanFrame = try XCTUnwrap(anchors.frame(for: .analysisScan, in: window))
        XCTAssertLessThan(modeFrame.maxY, scanFrame.minY, "Native toolbar and content use the same top-left coordinates")
        XCTAssertEqual(modeFrame.size, CGSize(width: 180, height: 28),
                       "An unclipped anchor's visibleRect must not expand the spotlight to its ancestor viewport")
        XCTAssertEqual(window.childWindows?.first?.frame, window.frame)
        window.setFrame(NSRect(x: -280, y: 60, width: 1000, height: 720), display: true)
        for _ in 0..<100 where window.childWindows?.first?.frame != window.frame {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.childWindows?.first?.frame, window.frame)
        controller.next()
        XCTAssertEqual(controller.session?.target, .analysisScan)
        controller.next()
        XCTAssertEqual(endings, [.completed])
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertNil(controller.session)
        withExtendedLifetime(delegate) {}
    }

    @MainActor
    func test_hiddenOwnerDoesNotPresentOrStealFocusBeforeItsWindowIsShown() {
        _ = NSApplication.shared
        let anchors = ControlGuideAnchors()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let mode = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 28))
        window.contentView?.addSubview(mode)
        anchors.register(.interfaceMode, token: UUID(), view: mode)
        let controller = ControlGuideController(anchors: anchors)
        controller.configure(presentationID: UUID(), mode: .normal, locale: Locale(identifier: "en")) { _, _ in }
        controller.attach(to: window)
        defer { controller.detach(); window.close() }
        controller.refresh()
        XCTAssertNil(controller.session)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true,
                      "An attached WindowGroup view is not necessarily a shown window; its guide must not become key first")
        window.orderFront(nil)
        controller.refresh()
        XCTAssertEqual(controller.session?.target, .interfaceMode)
        XCTAssertEqual(window.childWindows?.count, 1)
    }

    @MainActor
    func test_scrollRevealResumesWhenClipBoundsChangeWithoutMovingTheRow() async throws {
        // v2026.10.11: an actual List scroll changes NSClipView.bounds, not the row's
        // frame. Missing this notification stranded the tour after Help opened it mid-list.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let anchors = ControlGuideAnchors()
        let mode = NSView(frame: NSRect(x: 340, y: 550, width: 180, height: 28))
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 20, width: 240, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 1200))
        let row = NSHostingView(rootView: Button("Batch scan fixture") {}
            .frame(width: 220, height: 28).controlGuideGroupPart(.scanCategory)
            .environment(\.controlGuideAnchors, anchors))
        row.frame = NSRect(x: 10, y: 1050, width: 220, height: 28)
        document.addSubview(row)
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(mode)
        anchors.register(.interfaceMode, token: UUID(), view: mode)
        anchors.register(.sidebarOperations, token: UUID(), view: scroll)
        anchors.registerReveals([.scanCategory], owner: UUID()) { _ in }
        window.orderFront(nil)
        row.layoutSubtreeIfNeeded()
        let controller = ControlGuideController(anchors: anchors)
        controller.configure(presentationID: UUID(), mode: .professional, locale: Locale(identifier: "en")) { _, _ in }
        controller.attach(to: window)
        defer { controller.detach(); window.close() }
        controller.refresh()
        XCTAssertEqual(controller.session?.target, .interfaceMode)
        let panel = try XCTUnwrap(window.childWindows?.first)
        XCTAssertNil(anchors.frame(for: .scanCategory, in: window))
        controller.next(); controller.next()
        controller.refresh()
        XCTAssertFalse(panel.isVisible, "Wait for the actual scroll, without a guessed highlight")
        let originalRowFrame = row.frame
        var geometryChanges = 0
        let subscription = anchors.changes.sink { geometryChanges += 1 }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(geometryChanges, 0, "A clipping change must notify the real anchor registry, even when no row moves")
        for _ in 0..<100 where !panel.isVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(row.frame, originalRowFrame, "Only the clipping ancestor changes during scrolling")
        XCTAssertEqual(controller.session?.target, .scanCategory)
        XCTAssertNotNil(anchors.frame(for: .scanCategory, in: window))
        XCTAssertTrue(panel.isVisible, "Native scroll notification must resume the stranded guide")
        XCTAssertTrue(panel.parent === window, "A resumed guide remains attached to its real owner")
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func test_bottomControlTourKeepsActualLocalizedBubbleInsideResizedNativeWindow() async throws {
        // v2026.10.11: sustained production interaction exposed a clipped footer bubble.
        // Measure the rendered production text AND action row; do not supply an assumed height.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 1360, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = hosting
        defer { window.close() }
        window.orderFront(nil)
        var session = try XCTUnwrap(ControlGuideSession(presentationID: UUID(), mode: .professional,
                                                       available: [.interfaceMode, .deleteSelection]))
        XCTAssertTrue(session.advance())
        let probe = NSView(frame: .zero)
        for locale in [Locale(identifier: "zh-Hans"), Locale(identifier: "en")] {
            for size in [NSSize(width: 1360, height: 820), NSSize(width: 800, height: 600)] {
                window.setContentSize(size)
                let focus = CGRect(x: size.width - 160, y: size.height - 48, width: 140, height: 28)
                hosting.rootView = AnyView(ControlGuideSpotlight(focus: focus) {
                    ControlGuideBubble(session: session, onNext: {}, onSkip: {})
                        .background(BubbleGeometryProbe(view: probe))
                }.environment(\.locale, locale))
                for _ in 0..<20 {
                    hosting.layoutSubtreeIfNeeded()
                    if probe.window != nil, !probe.bounds.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                // Give preference-driven layout its normal update opportunity as well.
                for _ in 0..<5 { await Task.yield(); hosting.layoutSubtreeIfNeeded() }
                XCTAssertGreaterThan(probe.bounds.height, 100, "Include the complete localized action row")
                let bubble = hosting.convert(probe.bounds, from: probe)
                XCTAssertTrue(hosting.bounds.contains(bubble),
                              "\(locale.identifier), \(size): rendered \(bubble) must fit \(hosting.bounds)")
            }
        }
    }

    private struct BubbleGeometryProbe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @MainActor
    func test_sidebarGroupsUseRealRowUnionAndRevealHiddenGroupsBeforeSpotlighting() throws {
        // v2026.10.11: teaching one recommended row missed the rest of the sidebar and
        // filtering off-screen rows silently omitted tools. Reveal only scrolls real groups.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let anchors = ControlGuideAnchors()
        let mode = NSView(frame: NSRect(x: 340, y: 550, width: 180, height: 28))
        let sidebar = NSView(frame: NSRect(x: 10, y: 50, width: 240, height: 450))
        let first = NSView(frame: NSRect(x: 10, y: 350, width: 220, height: 28))
        let last = NSView(frame: NSRect(x: 10, y: 390, width: 220, height: 28))
        let custom = NSView(frame: NSRect(x: 10, y: 100, width: 220, height: 80))
        window.contentView?.addSubview(mode); window.contentView?.addSubview(sidebar)
        sidebar.addSubview(first); sidebar.addSubview(last)
        anchors.register(.interfaceMode, token: UUID(), view: mode)
        anchors.register(.sidebarOperations, token: UUID(), view: sidebar)
        let firstToken = UUID(), lastToken = UUID()
        anchors.registerPart(.scanCategory, token: firstToken, view: first)
        anchors.registerPart(.scanCategory, token: lastToken, view: last)
        window.orderFront(nil)
        let frame = try XCTUnwrap(anchors.frame(for: .scanCategory, in: window))
        XCTAssertEqual(frame.height, 68, "The entire real group is highlighted, not a single arbitrary row")
        var reveals = 0
        let oldOwner = UUID(), owner = UUID()
        anchors.registerReveals([.customPaths], owner: oldOwner) { _ in XCTFail("Stale scroll owner") }
        anchors.registerReveals([.customPaths], owner: owner) { target in
            reveals += 1
            sidebar.addSubview(custom)
            anchors.registerPart(target, token: UUID(), view: custom)
        }
        anchors.unregisterReveals(owner: oldOwner)
        let controller = ControlGuideController(anchors: anchors)
        controller.configure(presentationID: UUID(), mode: .professional, locale: Locale(identifier: "en")) { _, _ in }
        controller.attach(to: window)
        defer { controller.detach(); window.close() }
        controller.refresh()
        controller.next(); controller.next(); controller.next(); controller.refresh()
        XCTAssertEqual(controller.session?.target, .customPaths)
        XCTAssertEqual(reveals, 1)
        XCTAssertNotNil(anchors.frame(for: .customPaths, in: window))
        anchors.unregister(.scanCategory, token: firstToken)
        XCTAssertEqual(anchors.frame(for: .scanCategory, in: window)?.height, 28,
                       "Unmounting one row must retain the rest of its group")
        anchors.unregisterReveals(owner: owner)
        XCTAssertFalse(anchors.canReveal(.customPaths))
    }

    @MainActor
    func test_anchorReplacementRejectsLateRemovalAndOtherWindowGeometry() {
        let registry = ControlGuideAnchors()
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        let old = NSView(frame: CGRect(x: 10, y: 10, width: 30, height: 25))
        let replacement = NSView(frame: CGRect(x: 20, y: 20, width: 40, height: 25))
        first.contentView?.addSubview(old); first.contentView?.addSubview(replacement)
        defer { first.close(); second.close() }
        let oldToken = UUID(), newToken = UUID()
        registry.register(.interfaceMode, token: oldToken, view: old)
        registry.register(.interfaceMode, token: newToken, view: replacement)
        registry.unregister(.interfaceMode, token: oldToken)
        XCTAssertNotNil(registry.frame(for: .interfaceMode, in: first))
        XCTAssertNil(registry.frame(for: .interfaceMode, in: second))
        registry.unregister(.interfaceMode, token: newToken)
        XCTAssertNil(registry.frame(for: .interfaceMode, in: first))
    }

    @MainActor
    private final class ToolbarFixture: NSObject, NSToolbarDelegate {
        let anchors: ControlGuideAnchors
        init(anchors: ControlGuideAnchors) { self.anchors = anchors }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("mode")] }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("mode")] }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = NSHostingView(rootView: Button("Mode fixture") {}.frame(width: 180, height: 28)
                .controlGuideTarget(.interfaceMode).environment(\.controlGuideAnchors, anchors))
            return item
        }
    }
}
