import AppKit
import SwiftUI

/// v2026.10.08: SwiftUI's system Settings title retains the process launch language.
/// Bind the owning window title to the same locale as its content, including late attachment.
struct LocalizedWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView {
        let view = TitleView()
        view.localizedTitle = title
        return view
    }

    func updateNSView(_ view: TitleView, context: Context) {
        view.localizedTitle = title
    }

    final class TitleView: NSView {
        var localizedTitle = "" {
            didSet { reconcileTitle() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reconcileTitle()
        }

        private func reconcileTitle() {
            guard let window, window.title != localizedTitle else { return }
            window.title = localizedTitle
        }
    }
}
