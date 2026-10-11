import AppKit
import SwiftUI
import XCTest
@testable import AppUI

final class MainWindowActionsAccessoryTests: XCTestCase {
    @MainActor
    func test_threeActionsKeepRealNativeFramesAcrossResizeAndContentChanges() async throws {
        // v2026.10.11: native priority only determines which item overflows first and
        // SwiftUI reconfigures it during scans. The requirement forbids overflow entirely,
        // so retain the visibility assertion on the production window accessory instead.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1512, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "WindowActions.C2")
        window.toolbar = toolbar
        let anchors = ControlGuideAnchors()
        let actions = MainWindowActionsAccessory.Controller()
        let targets: [ControlGuideTarget] = [.stash, .rescan, .reopenGuide]
        defer { actions.detach(); window.close() }
        actions.configure(content: content(targets: targets, anchors: anchors))
        actions.attach(to: window)
        window.orderFront(nil)
        for width: CGFloat in [1512, 1280, 1360, 1280] {
            window.setContentSize(NSSize(width: width, height: 820))
            // Replacing SwiftUI content represents a count/scan-state update. These changes
            // previously recreated native toolbar items and sent the actions to overflow.
            actions.configure(content: content(targets: targets, anchors: anchors))
            for _ in 0..<100 where targets.contains(where: { anchors.frame(for: $0, in: window) == nil }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let frames = try targets.map { try XCTUnwrap(anchors.frame(for: $0, in: window)) }
            let bounds = CGRect(origin: .zero, size: window.frame.size)
            XCTAssertTrue(frames.allSatisfy { bounds.contains($0) && !$0.isEmpty }, "All three real controls stay inside the window")
            XCTAssertLessThan(frames[0].maxX, frames[1].minX)
            XCTAssertLessThan(frames[1].maxX, frames[2].minX)
            XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
            XCTAssertTrue(toolbar.items.isEmpty, "The required actions never enter NSToolbar's overflow collection")
        }
        actions.detach()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty, "Remove only this window's accessory on teardown")
    }

    @MainActor
    private func content(targets: [ControlGuideTarget], anchors: ControlGuideAnchors) -> AnyView {
        AnyView(HStack(spacing: 12) {
            ForEach(targets, id: \.self) { target in
                Button {} label: { Image(systemName: "circle") }
                    .controlGuideTarget(target)
            }
        }.font(.system(size: 17)).padding(12).fixedSize().environment(\.controlGuideAnchors, anchors))
    }
}
