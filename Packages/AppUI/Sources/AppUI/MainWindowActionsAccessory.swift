import AppKit
import SwiftUI

/// v2026.10.11: required actions must never participate in NSToolbar's overflow layout.
/// A native right titlebar accessory reserves their measured width, including fullscreen,
/// while SwiftUI keeps the existing actions, accessibility and guide anchors.
/// https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller
struct MainWindowActionsAccessory: NSViewRepresentable {
    let content: AnyView

    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ view: HostView, context: Context) {
        view.actions.configure(content: content)
        view.actions.attach(to: view.window)
    }
    static func dismantleNSView(_ view: HostView, coordinator: ()) { view.actions.detach() }

    final class HostView: NSView {
        let actions = Controller()
        init() { super.init(frame: .zero) }
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
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        private weak var window: NSWindow?

        init() {
            accessory.layoutAttribute = .right
            accessory.view = hosting
        }

        func configure(content: AnyView) {
            hosting.rootView = content
            // Measure only when content changes; native accessory layout owns resize.
            // No window-update observer, guessed width or toolbar-item mutation is needed.
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
