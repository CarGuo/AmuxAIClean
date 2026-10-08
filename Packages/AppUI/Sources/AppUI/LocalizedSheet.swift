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
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(LocalizedItemSheet(item: item, onDismiss: onDismiss, sheet: content))
    }

    func localizedSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(LocalizedBooleanSheet(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }
}

private struct LocalizedItemSheet<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Environment(\.locale) private var locale
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheet: (Item) -> SheetContent

    func body(content: Content) -> some View {
        content.sheet(item: $item, onDismiss: onDismiss) { item in
            sheet(item).environment(\.locale, locale)
        }
    }
}

private struct LocalizedBooleanSheet<SheetContent: View>: ViewModifier {
    @Environment(\.locale) private var locale
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheet: () -> SheetContent

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
            sheet().environment(\.locale, locale)
        }
    }
}
