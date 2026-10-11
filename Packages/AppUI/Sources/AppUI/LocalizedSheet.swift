import SwiftUI

// v2026.10.07 C4: macOS sheets are independently hosted presentations. In the running App,
// their locale reverted to the process default even when the presenting page used zh-Hans.
// Forward the presenter's live locale at the common presentation boundary, so every sheet
// (including routed confirmation/progress/result content) has the same language contract.
@MainActor
public extension View {
    func localizedSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        tracksMainWindowOccupancy: Bool = true,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(LocalizedItemSheet(item: item, onDismiss: onDismiss,
                                    tracksMainWindowOccupancy: tracksMainWindowOccupancy, sheet: content))
    }

    func localizedSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        tracksMainWindowOccupancy: Bool = true,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(LocalizedBooleanSheet(isPresented: isPresented, onDismiss: onDismiss,
                                       tracksMainWindowOccupancy: tracksMainWindowOccupancy, sheet: content))
    }
}

private struct LocalizedItemSheet<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Environment(\.locale) private var locale
    @Environment(\.mainWindowPresentationCoordinator) private var coordinator
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let tracksMainWindowOccupancy: Bool
    let sheet: (Item) -> SheetContent

    @ViewBuilder func body(content: Content) -> some View {
        if let coordinator {
            content.modifier(CoordinatedItemSheet(
                coordinator: coordinator, item: $item, onDismiss: onDismiss,
                tracksMainWindowOccupancy: tracksMainWindowOccupancy,
                sheet: { sheet($0).environment(\.locale, locale) }
            ))
        } else {
            content.sheet(item: $item, onDismiss: onDismiss) { item in
                sheet(item).environment(\.locale, locale)
            }
        }
    }
}

private struct LocalizedBooleanSheet<SheetContent: View>: ViewModifier {
    @Environment(\.locale) private var locale
    @Environment(\.mainWindowPresentationCoordinator) private var coordinator
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let tracksMainWindowOccupancy: Bool
    let sheet: () -> SheetContent

    @ViewBuilder func body(content: Content) -> some View {
        if let coordinator {
            content.modifier(CoordinatedBooleanSheet(
                coordinator: coordinator, isPresented: $isPresented, onDismiss: onDismiss,
                tracksMainWindowOccupancy: tracksMainWindowOccupancy,
                sheet: { sheet().environment(\.locale, locale) }
            ))
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                sheet().environment(\.locale, locale)
            }
        }
    }
}

// v2026.10.10: nested tool sheets participate at the common boundary too. Requested
// content stays in its source binding while an application sheet owns the window. Once
// shown, occupancy lasts through native onDismiss, including the closing animation.
@MainActor
struct BusinessSheetPresentationLifecycle {
    private let occupancyID = UUID()
    private(set) var hasPresentedSheet = false
    private(set) var isAwaitingNativeEnd = false

    func requestChanged(_ requested: Bool, coordinator: MainWindowPresentationCoordinator,
                        hostID: UUID? = nil, tracksOccupancy: Bool = true) {
        guard tracksOccupancy else { return }
        if requested { coordinator.beginBusinessModal(occupancyID, hostID: hostID) }
        else if !hasPresentedSheet { coordinator.endBusinessModal(occupancyID) }
    }

    mutating func appeared(coordinator: MainWindowPresentationCoordinator,
                          hostID: UUID? = nil, tracksOccupancy: Bool = true) {
        hasPresentedSheet = true
        if tracksOccupancy { coordinator.beginBusinessModal(occupancyID, hostID: hostID) }
    }

    mutating func dismissalCallbackReceived() {
        isAwaitingNativeEnd = true
    }

    mutating func dismissed(coordinator: MainWindowPresentationCoordinator) {
        hasPresentedSheet = false
        isAwaitingNativeEnd = false
        coordinator.endBusinessModal(occupancyID)
    }

    mutating func presenterDisappeared(coordinator: MainWindowPresentationCoordinator) {
        // v2026.10.10 review correction: removed presenters may never receive onDismiss.
        // Native window observation keeps the closing barrier without leaking this reservation.
        hasPresentedSheet = false
        isAwaitingNativeEnd = false
        coordinator.endBusinessModal(occupancyID)
    }
}

private struct CoordinatedItemSheet<Item: Identifiable, SheetContent: View>: ViewModifier {
    @ObservedObject var coordinator: MainWindowPresentationCoordinator
    @Environment(\.mainWindowPresentationHostID) private var hostID
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let tracksMainWindowOccupancy: Bool
    let sheet: (Item) -> SheetContent
    @State private var lifecycle = BusinessSheetPresentationLifecycle()

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { tracksMainWindowOccupancy && coordinator.isOccupied(for: hostID) ? nil : item },
            set: { if !tracksMainWindowOccupancy || !coordinator.isOccupied(for: hostID) { item = $0 } }
        ), onDismiss: {
            lifecycle.dismissalCallbackReceived()
            finishNativeDismissalIfPossible()
        }) { item in
            sheet(item)
                .environment(\.mainWindowPresentationCoordinator, coordinator)
                .environment(\.mainWindowPresentationHostID, hostID)
                .onAppear {
                    lifecycle.appeared(coordinator: coordinator, hostID: hostID,
                                       tracksOccupancy: tracksMainWindowOccupancy)
                }
        }
        .onValueChange(of: item != nil, initial: true) { _, requested in
            lifecycle.requestChanged(requested, coordinator: coordinator, hostID: hostID,
                                     tracksOccupancy: tracksMainWindowOccupancy)
        }
        .onValueChange(of: coordinator.requestRevision) { _, _ in finishNativeDismissalIfPossible() }
        .onDisappear { lifecycle.presenterDisappeared(coordinator: coordinator) }
    }

    private func finishNativeDismissalIfPossible() {
        // v2026.10.10: actual SwiftUI onDismiss precedes NSWindow.didEndSheet in native tests.
        // All business and application handoffs wait for both signals at this common boundary.
        guard lifecycle.isAwaitingNativeEnd, !coordinator.hasNativeSheet(for: hostID) else { return }
        lifecycle.dismissed(coordinator: coordinator)
        onDismiss?()
        lifecycle.requestChanged(item != nil, coordinator: coordinator, hostID: hostID,
                                 tracksOccupancy: tracksMainWindowOccupancy)
    }
}

private struct CoordinatedBooleanSheet<SheetContent: View>: ViewModifier {
    @ObservedObject var coordinator: MainWindowPresentationCoordinator
    @Environment(\.mainWindowPresentationHostID) private var hostID
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let tracksMainWindowOccupancy: Bool
    let sheet: () -> SheetContent
    @State private var lifecycle = BusinessSheetPresentationLifecycle()

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { (!tracksMainWindowOccupancy || !coordinator.isOccupied(for: hostID)) && isPresented },
            set: { if !tracksMainWindowOccupancy || !coordinator.isOccupied(for: hostID) { isPresented = $0 } }
        ), onDismiss: {
            lifecycle.dismissalCallbackReceived()
            finishNativeDismissalIfPossible()
        }) {
            sheet()
                .environment(\.mainWindowPresentationCoordinator, coordinator)
                .environment(\.mainWindowPresentationHostID, hostID)
                .onAppear {
                    lifecycle.appeared(coordinator: coordinator, hostID: hostID,
                                       tracksOccupancy: tracksMainWindowOccupancy)
                }
        }
        .onValueChange(of: isPresented, initial: true) { _, requested in
            lifecycle.requestChanged(requested, coordinator: coordinator, hostID: hostID,
                                     tracksOccupancy: tracksMainWindowOccupancy)
        }
        .onValueChange(of: coordinator.requestRevision) { _, _ in finishNativeDismissalIfPossible() }
        .onDisappear { lifecycle.presenterDisappeared(coordinator: coordinator) }
    }

    private func finishNativeDismissalIfPossible() {
        guard lifecycle.isAwaitingNativeEnd, !coordinator.hasNativeSheet(for: hostID) else { return }
        lifecycle.dismissed(coordinator: coordinator)
        onDismiss?()
        lifecycle.requestChanged(isPresented, coordinator: coordinator, hostID: hostID,
                                 tracksOccupancy: tracksMainWindowOccupancy)
    }
}
