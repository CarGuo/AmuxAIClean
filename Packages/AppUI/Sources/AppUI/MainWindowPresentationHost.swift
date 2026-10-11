import AppKit
import SwiftUI

/// v2026.10.10: the native window owns sheet animation and focus, independent of a
/// SwiftUI presenter being removed. This also routes Help to the currently focused main window.
/// NSWindow.didEndSheetNotification documents the actual closing boundary:
/// https://developer.apple.com/documentation/appkit/nswindow/didendsheetnotification
@MainActor
struct MainWindowPresentationHost: NSViewRepresentable {
    let coordinator: MainWindowPresentationCoordinator
    let hostID: UUID

    func makeNSView(context: Context) -> HostView {
        HostView(coordinator: coordinator, hostID: hostID)
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        nsView.observeAttachedWindow()
    }

    static func dismantleNSView(_ nsView: HostView, coordinator: ()) {
        nsView.detach()
    }

    final class HostView: NSView {
        let presentation: MainWindowPresentationCoordinator
        let hostID: UUID
        private weak var observedWindow: NSWindow?

        init(coordinator: MainWindowPresentationCoordinator, hostID: UUID) {
            presentation = coordinator
            self.hostID = hostID
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeAttachedWindow()
        }

        func observeAttachedWindow() {
            guard observedWindow !== window else { return }
            detach()
            guard let window else { return }
            observedWindow = window
            presentation.attachHost(hostID, focusWindow: { [weak window] in
                guard let window else { return }
                if window.isMiniaturized { window.deminiaturize(nil) }
                NSApp.setActivationPolicy(.regular)
                ApplicationActivationCompatibility.requestForegroundActivation()
                window.makeKeyAndOrderFront(nil)
            })
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(becameKey),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(sheetBegan),
                               name: NSWindow.willBeginSheetNotification, object: window)
            center.addObserver(self, selector: #selector(sheetEnded),
                               name: NSWindow.didEndSheetNotification, object: window)
            center.addObserver(self, selector: #selector(windowClosed),
                               name: NSWindow.willCloseNotification, object: window)
            presentation.nativeSheetChanged(isPresented: window.attachedSheet != nil, hostID: hostID)
            if window.isKeyWindow || window.isMainWindow { presentation.focusHost(hostID) }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if observedWindow != nil { presentation.detachHost(hostID) }
            observedWindow = nil
        }

        @objc private func becameKey(_ notification: Notification) {
            presentation.focusHost(hostID)
        }

        @objc private func sheetBegan(_ notification: Notification) {
            presentation.nativeSheetChanged(isPresented: true, hostID: hostID)
        }

        @objc private func sheetEnded(_ notification: Notification) {
            presentation.nativeSheetChanged(isPresented: false, hostID: hostID)
        }

        @objc private func windowClosed(_ notification: Notification) { detach() }

    }
}

/// A tool's existing transaction projection spans preflight, confirmation handoff and
/// execution. The common boundary registers it separately from native sheet visibility.
extension View {
    func mainWindowBusinessTransaction(isActive: @escaping @autoclosure @MainActor () -> Bool) -> some View {
        modifier(MainWindowBusinessTransaction(isActive: isActive))
    }
}

private struct MainWindowBusinessTransaction: ViewModifier {
    @Environment(\.mainWindowPresentationCoordinator) private var coordinator
    @Environment(\.mainWindowPresentationHostID) private var hostID
    @State private var occupancyID = UUID()
    let isActive: @MainActor () -> Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                coordinator?.registerBusinessTransaction(occupancyID, hostID: hostID, isActive: isActive)
            }
            .onValueChange(of: isActive()) { _, _ in coordinator?.businessTransactionChanged() }
            .onDisappear { coordinator?.endBusinessModal(occupancyID) }
    }
}
