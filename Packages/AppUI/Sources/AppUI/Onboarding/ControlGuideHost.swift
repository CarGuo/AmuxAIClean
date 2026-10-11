import AppKit
import Combine
import SwiftUI

/// v2026.10.10: toolbar controls have a different hosting hierarchy from the main content.
/// Register real NSViews and convert through their owning window, rather than relying on
/// SwiftUI preferences crossing that boundary. Pattern reference: github.com/chriszielinski/Enlighten.
@MainActor
final class ControlGuideAnchors: ObservableObject {
    private struct Anchor {
        weak var view: NSView?
    }
    private struct Reveal {
        let owner: UUID
        let action: () -> Void
    }
    private var anchors: [ControlGuideTarget: [UUID: Anchor]] = [:]
    private var reveals: [ControlGuideTarget: Reveal] = [:]
    let changes = PassthroughSubject<Void, Never>()
    private(set) var layoutRevision: UInt64 = 0

    func layoutChanged() {
        layoutRevision &+= 1
        changes.send()
    }

    func register(_ target: ControlGuideTarget, token: UUID, view: NSView) {
        guard anchors[target]?.count != 1 || anchors[target]?[token] == nil else { return }
        anchors[target] = [token: Anchor(view: view)]
        layoutChanged()
    }

    /// v2026.10.11: a sidebar group spans several native List rows. Union real visible
    /// parts, rather than highlighting one arbitrary row or inventing a section rectangle.
    func registerPart(_ target: ControlGuideTarget, token: UUID, view: NSView) {
        guard anchors[target]?[token] == nil else { return }
        anchors[target, default: [:]][token] = Anchor(view: view)
        layoutChanged()
    }

    func unregister(_ target: ControlGuideTarget, token: UUID) {
        guard anchors[target]?.removeValue(forKey: token) != nil else { return }
        if anchors[target]?.isEmpty == true { anchors.removeValue(forKey: target) }
        layoutChanged()
    }

    func frame(for target: ControlGuideTarget, in window: NSWindow) -> CGRect? {
        let frames = (anchors[target] ?? [:]).values.compactMap { anchor in
            anchor.view.flatMap { frame(for: $0, in: window) }
        }
        return frames.reduce(nil) { result, frame in result.map { $0.union(frame) } ?? frame }
    }

    private func frame(for view: NSView, in window: NSWindow) -> CGRect? {
        guard view.window === window,
              !view.isHiddenOrHasHiddenAncestor else { return nil }
        // v2026.10.10: an unclipped NSView's visibleRect can include its entire ancestor
        // viewport. Spotlight only the control's own visible bounds, in either hosting tree.
        let visibleBounds = view.bounds.intersection(view.visibleRect)
        guard !visibleBounds.isEmpty, !visibleBounds.isNull else { return nil }
        let screen = window.convertToScreen(view.convert(visibleBounds, to: nil))
        let frame = CGRect(x: screen.minX - window.frame.minX, y: window.frame.maxY - screen.maxY,
                           width: screen.width, height: screen.height)
        let clipped = frame.intersection(CGRect(origin: .zero, size: window.frame.size))
        return clipped.isEmpty || clipped.isNull ? nil : clipped
    }

    func available(in window: NSWindow) -> Set<ControlGuideTarget> {
        ControlGuideAnchorPolicy.available(
            visible: Set(anchors.keys.filter { frame(for: $0, in: window) != nil }),
            registered: Set(reveals.keys))
    }

    func registerReveals(_ targets: [ControlGuideTarget], owner: UUID, action: @escaping (ControlGuideTarget) -> Void) {
        for target in targets { reveals[target] = Reveal(owner: owner, action: { action(target) }) }
        layoutChanged()
    }

    func unregisterReveals(owner: UUID) {
        reveals = reveals.filter { $0.value.owner != owner }
        layoutChanged()
    }

    func canReveal(_ target: ControlGuideTarget, in window: NSWindow) -> Bool {
        ControlGuideAnchorPolicy.canReveal(target, registered: Set(reveals.keys),
            sidebarIsVisible: frame(for: .sidebarOperations, in: window) != nil)
    }
    func reveal(_ target: ControlGuideTarget) {
        reveals[target]?.action()
    }
}

private struct ControlGuideAnchorsKey: EnvironmentKey {
    static let defaultValue: ControlGuideAnchors? = nil
}

extension EnvironmentValues {
    var controlGuideAnchors: ControlGuideAnchors? {
        get { self[ControlGuideAnchorsKey.self] }
        set { self[ControlGuideAnchorsKey.self] = newValue }
    }
}

extension View {
    func controlGuideTarget(_ target: ControlGuideTarget) -> some View {
        modifier(ControlGuideTargetModifier(target: target, isGroupPart: false))
    }
    func controlGuideGroupPart(_ target: ControlGuideTarget) -> some View {
        modifier(ControlGuideTargetModifier(target: target, isGroupPart: true))
    }
}

private struct ControlGuideTargetModifier: ViewModifier {
    @Environment(\.controlGuideAnchors) private var anchors
    let target: ControlGuideTarget
    let isGroupPart: Bool
    func body(content: Content) -> some View {
        content.background {
            if let anchors { ControlGuideAnchor(anchors: anchors, target: target, isGroupPart: isGroupPart).allowsHitTesting(false) }
        }
    }
}

private struct ControlGuideAnchor: NSViewRepresentable {
    let anchors: ControlGuideAnchors
    let target: ControlGuideTarget
    let isGroupPart: Bool
    func makeNSView(context: Context) -> AnchorView { AnchorView(anchors: anchors, target: target, isGroupPart: isGroupPart) }
    func updateNSView(_ view: AnchorView, context: Context) { view.register() }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.unregister() }

    final class AnchorView: NSView {
        let anchors: ControlGuideAnchors
        let target: ControlGuideTarget
        let isGroupPart: Bool
        let token = UUID()
        private weak var observedClipView: NSClipView?
        init(anchors: ControlGuideAnchors, target: ControlGuideTarget, isGroupPart: Bool) {
            self.anchors = anchors
            self.target = target
            self.isGroupPart = isGroupPart
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { register() } else { unregister() }
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeScrolling()
        }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            if changed { anchors.layoutChanged() }
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            let changed = newOrigin != frame.origin
            super.setFrameOrigin(newOrigin)
            if changed { anchors.layoutChanged() }
        }
        func register() {
            guard window != nil else { return }
            observeScrolling()
            if isGroupPart { anchors.registerPart(target, token: token, view: self) }
            else { anchors.register(target, token: token, view: self) }
        }
        func unregister() {
            if let observedClipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                          object: observedClipView)
            }
            observedClipView = nil
            anchors.unregister(target, token: token)
        }
        private func observeScrolling() {
            // v2026.10.11: List scrolling moves its clipping bounds while row frames stay
            // fixed. Track the native visibility boundary, including reparenting/unmounting.
            // https://developer.apple.com/documentation/appkit/nsview/boundsdidchangenotification
            let clip = window == nil ? nil : enclosingScrollView?.contentView
            guard observedClipView !== clip else { return }
            if let observedClipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                          object: observedClipView)
            }
            observedClipView = clip
            if let clip {
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        @objc private func scrolled(_ notification: Notification) { anchors.layoutChanged() }
    }
}

/// A transparent child panel covers the owner's content AND native toolbar. It is not a sheet;
/// the App's retained presentation remains the sole occupancy owner. All geometry comes from views.
struct ControlGuideHost: NSViewRepresentable {
    let anchors: ControlGuideAnchors
    let presentationID: UUID?
    let mode: SmartCareInterfaceMode
    let requiredTargets: Set<ControlGuideTarget>
    let locale: Locale
    let isFocusedHost: Bool
    let onFocus: () -> Void
    let onEnd: (UUID, ControlGuideEnd) -> Void

    func makeNSView(context: Context) -> HostView { HostView(anchors: anchors) }
    func updateNSView(_ view: HostView, context: Context) {
        view.controller.configure(presentationID: presentationID, mode: mode, locale: locale,
                                  requiredTargets: requiredTargets,
                                  isFocusedHost: isFocusedHost, onFocus: onFocus, onEnd: onEnd)
        view.attach()
    }
    static func dismantleNSView(_ view: HostView, coordinator: ()) { view.controller.detach() }

    final class HostView: NSView {
        let controller: ControlGuideController
        init(anchors: ControlGuideAnchors) {
            controller = ControlGuideController(anchors: anchors)
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() { controller.attach(to: window) }
    }
}

@MainActor
final class ControlGuideController: NSObject {
    private let anchors: ControlGuideAnchors
    private weak var window: NSWindow?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var progress = ControlGuideProgressState()
    var session: ControlGuideSession? { progress.session }
    private var presentationID: UUID?
    private var mode: SmartCareInterfaceMode = .normal
    private var locale = Locale(identifier: "en")
    private var onEnd: ((UUID, ControlGuideEnd) -> Void)?
    private var onFocus: (() -> Void)?
    private var anchorSubscription: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var isFocusedHost = false
    private var needsKeyboardFocus = false
    private var requiredTargets: Set<ControlGuideTarget> = []

    init(anchors: ControlGuideAnchors) {
        self.anchors = anchors
        super.init()
        anchorSubscription = anchors.changes.sink { [weak self] in self?.scheduleRefresh() }
    }

    func configure(presentationID: UUID?, mode: SmartCareInterfaceMode, locale: Locale,
                   requiredTargets: Set<ControlGuideTarget> = [],
                   isFocusedHost: Bool = true,
                   onFocus: @escaping () -> Void = {}, onEnd: @escaping (UUID, ControlGuideEnd) -> Void) {
        // v2026.10.11 C4: native key/main flags disappear while App activation is pending.
        // Retain the requested owner's keyboard handoff until AppKit actually makes it key.
        if !isFocusedHost { needsKeyboardFocus = false }
        else if self.presentationID != presentationID || !self.isFocusedHost {
            needsKeyboardFocus = presentationID != nil
        }
        self.isFocusedHost = isFocusedHost
        if self.presentationID != presentationID || self.mode != mode { progress = ControlGuideProgressState() }
        self.presentationID = presentationID
        self.mode = mode
        self.locale = locale
        self.requiredTargets = requiredTargets
        self.onEnd = onEnd
        self.onFocus = onFocus
        scheduleRefresh()
    }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        detach()
        guard let window else { return }
        self.window = window
        needsKeyboardFocus = presentationID != nil && isFocusedHost
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        center.addObserver(self, selector: #selector(windowChanged), name: NSApplication.didBecomeActiveNotification, object: NSApp)
        scheduleRefresh()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        refreshTask?.cancel()
        refreshTask = nil
        hide()
        progress = ControlGuideProgressState()
        window = nil
    }

    private func scheduleRefresh() {
        // AppKit layout/SwiftUI updates may invoke this reentrantly. No state publication or
        // NSHostingView replacement occurs inside that update stack.
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    func refresh() {
        guard let presentationID, let window else { hide(); return }
        // v2026.10.10: WindowGroup attaches views before showing its native window. A child
        // panel must never appear or take key focus ahead of that owner; resume on visibility.
        guard window.isVisible, !window.isMiniaturized else {
            progress.suspend()
            needsKeyboardFocus = needsKeyboardFocus || panel?.isKeyWindow == true
            panel?.orderOut(nil)
            return
        }
        let mounted = anchors.available(in: window)
        let available = requiredTargets.isEmpty ? mounted
            : mounted.intersection(requiredTargets.union([.resultsMode, .deleteSelection]))
        progress.prepare(presentationID: presentationID, mode: mode,
                         available: available, required: requiredTargets)
        guard let session else {
            show(AnyView(ControlGuidePreparingOverlay(onSkip: { [weak self] in self?.end(.skipped) })), in: window)
            return
        }
        let canReveal = anchors.canReveal(session.target, in: window)
        if progress.shouldReveal(isVisible: anchors.frame(for: session.target, in: window) != nil,
                                 canReveal: canReveal, layoutRevision: anchors.layoutRevision) {
            anchors.reveal(session.target)
            scheduleRefresh()
        }
        let frame = anchors.frame(for: session.target, in: window)
        if progress.locate(isVisible: frame != nil, canReveal: canReveal) == .contextChanged {
            end(.contextChanged)
            return
        }
        // v2026.10.11 review: native scrolling is asynchronous. Keep a visible, cancelable
        // key panel throughout it; Return must never fall through to the owner's path field.
        // A folded sidebar invalidates reveal eligibility, rather than retaining a hidden lease.
        let overlay = ControlGuideOverlay(session: session, focus: frame,
            onNext: { [weak self] in self?.next() }, onSkip: { [weak self] in self?.end(.skipped) })
        show(AnyView(overlay), in: window)
    }

    private func show(_ content: AnyView, in window: NSWindow) {
        let overlay = content.environment(\.locale, locale)
        if panel == nil {
            // This is an interactive modal tour, not a nonactivating HUD/tool palette.
            let panel = GuidePanel(contentRect: window.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.title = AppLocalization.string("user_guide.window.title", locale: locale)
            panel.onClose = { [weak self] in self?.end(.skipped) }
            panel.onBecomeKey = { [weak self] in self?.onFocus?() }
            let hosting = NSHostingView(rootView: AnyView(overlay))
            panel.contentView = hosting
            hostingView = hosting
            self.panel = panel
        } else {
            hostingView?.rootView = AnyView(overlay)
        }
        // Miniaturization can remove the native child relationship; restore the same owner.
        if let panel, panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel?.setFrame(window.frame, display: true)
        if needsKeyboardFocus || window.isKeyWindow {
            panel?.makeKeyAndOrderFront(nil)
            needsKeyboardFocus = panel?.isKeyWindow != true
        }
        else if let panel, !panel.isVisible { panel.orderFront(nil) }
    }

    func next() {
        switch progress.advance() {
        case .ignored: break
        case .advanced: refresh()
        case .completed: end(.completed)
        }
    }

    func end(_ reason: ControlGuideEnd) {
        guard let id = presentationID else { return }
        presentationID = nil
        progress = ControlGuideProgressState()
        hide()
        onEnd?(id, reason)
    }

    private func hide() {
        guard let panel else { return }
        (panel as? GuidePanel)?.onClose = nil
        // Return input only if this tour owns it; closing a background tour must not
        // pull focus away from another window. Restore before severing the child relation.
        if panel.isKeyWindow, let window, window.isVisible, !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        hostingView = nil
        needsKeyboardFocus = false
    }

    @objc private func windowChanged(_ notification: Notification) {
        // Real viewport changes invalidate a previous scroll attempt, including a target
        // that became clipped after resize. An ordinary activation/refresh does not.
        if notification.name == NSWindow.didResizeNotification
            || notification.name == NSWindow.didDeminiaturizeNotification {
            anchors.layoutChanged()
        }
        if notification.name == NSWindow.willMiniaturizeNotification {
            needsKeyboardFocus = needsKeyboardFocus || panel?.isKeyWindow == true
        }
        if presentationID != nil, notification.name == NSWindow.didBecomeKeyNotification {
            needsKeyboardFocus = true
        }
        scheduleRefresh()
    }
    @objc private func windowClosed(_ notification: Notification) { detach() }

    private final class GuidePanel: NSPanel {
        var onClose: (() -> Void)?
        var onBecomeKey: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func becomeKey() { super.becomeKey(); onBecomeKey?() }
        override func close() { let callback = onClose; onClose = nil; super.close(); callback?() }
    }
}
