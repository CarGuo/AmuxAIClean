import AppKit
import SwiftUI

/// v2026.10.11: required actions must never participate in NSToolbar's overflow layout.
/// A native right titlebar accessory reserves their measured width, including fullscreen,
/// while SwiftUI keeps the existing actions, accessibility and guide anchors.
/// https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller
@MainActor
struct MainWindowActionsAccessory<Content: View, LayoutIdentity: Equatable>: NSViewRepresentable {
    let content: Content
    let layoutIdentity: LayoutIdentity

    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ view: HostView, context: Context) {
        view.actions.configure(content: content, layoutIdentity: layoutIdentity)
        view.actions.attach(to: view.window)
    }
    static func dismantleNSView(_ view: HostView, coordinator: ()) { view.actions.detach() }

    final class HostView: NSView {
        let actions: Controller
        init() { actions = Controller(); super.init(frame: .zero) }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            actions.attach(to: window)
        }
    }

    @MainActor
    final class Controller {
        let accessory = NSTitlebarAccessoryViewController()
        private(set) var hosting: NSHostingView<Content>?
        private var measuredIdentity: LayoutIdentity?
        private(set) var measurementCount = 0
        private weak var window: NSWindow?

        init() {
            accessory.layoutAttribute = .right
        }

        func configure(content: Content, layoutIdentity: LayoutIdentity) {
            let hosting: NSHostingView<Content>
            if let existing = self.hosting { hosting = existing }
            else {
                hosting = NSHostingView(rootView: content)
                // Only the natural content size is needed, not min/max SwiftUI probes.
                hosting.sizingOptions = [.intrinsicContentSize]
                self.hosting = hosting
                accessory.view = hosting
            }
            hosting.rootView = content
            // v2026.10.11 review: closures and enabled state must stay live, but scan ticks,
            // selections and path keystrokes do not change titlebar geometry. Only an explicit
            // content layout identity invalidates measurement, never MainView.body itself.
            guard measuredIdentity != layoutIdentity else { return }
            measuredIdentity = layoutIdentity
            measurementCount += 1
            let size = hosting.fittingSize
            if hosting.frame.size != size { hosting.setFrameSize(size) }
            accessory.fullScreenMinHeight = size.height
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            detach()
            guard let newWindow else { return }
            window = newWindow
            newWindow.addTitlebarAccessoryViewController(accessory)
        }

        func detach() {
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            window = nil
        }
    }
}

struct MainWindowActionsLayoutIdentity: Equatable {
    let mode: SmartCareInterfaceMode
    let isScanning: Bool
    let stashCount: Int
    let localeIdentifier: String
}
