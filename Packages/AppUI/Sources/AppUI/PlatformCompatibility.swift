import AppKit
import SwiftUI

/// v2026.07.16 macOS 13.5 compatibility boundary.
///
/// Version-specific SwiftUI behavior belongs here instead of being scattered through feature
/// views. Keeping a single boundary also preserves the old/new value semantics used by scan and
/// deletion state machines when the app runs on Ventura.
public extension View {
    @ViewBuilder
    func onValueChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(
                LegacyValueChangeModifier(
                    value: value,
                    deliversInitialValue: initial,
                    action: action
                )
            )
        }
    }

    /// Ventura does not expose SwiftUI's focus-effect suppression modifier. The underlying
    /// AppKit tables already set `focusRingType = .none`; other SwiftUI containers retain the
    /// platform-default focus affordance on Ventura rather than relying on a private workaround.
    @ViewBuilder
    func suppressesFocusEffectWhenSupported() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }

    /// Symbol effects are decorative. Ventura keeps the same symbol and state transition while
    /// omitting only the Sonoma animation.
    @ViewBuilder
    func bouncingSymbolEffect<Value: Equatable>(value: Value) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func replacingSymbolTransitionWhenSupported() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    @ViewBuilder
    func pulsingSymbolEffect(repeats: Bool) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.pulse, options: repeats ? .repeating : .nonRepeating)
        } else {
            self
        }
    }
}

/// Shared animation availability boundary for the Ventura product floor.
///
/// v2026.07.17: `Animation.smooth` and `Animation.snappy` start at macOS 14. Keeping the
/// fallback here prevents decorative Smart Care motion from raising the deployment requirement
/// or scattering availability branches through feature views. Ventura preserves the same state
/// transitions with public pre-Sonoma animations; only the interpolation curve differs.
public enum PlatformAnimationCompatibility {
    public static func smooth(duration: TimeInterval) -> Animation {
        if #available(macOS 14.0, *) {
            return .smooth(duration: duration)
        }
        return .easeInOut(duration: duration)
    }

    public static func snappy(duration: TimeInterval) -> Animation {
        if #available(macOS 14.0, *) {
            return .snappy(duration: duration)
        }
        return .spring(response: duration, dampingFraction: 0.82)
    }
}

/// The one-parameter `onChange` overload is the native Ventura API. Marking this implementation
/// obsolete on Sonoma keeps the deprecated overload out of newer runtime paths while allowing the
/// public compatibility modifier to preserve `oldValue`, `newValue`, and `initial` semantics.
@available(macOS, introduced: 13.5, obsoleted: 14.0)
private struct LegacyValueChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let deliversInitialValue: Bool
    let action: (_ oldValue: Value, _ newValue: Value) -> Void

    @State private var previousValue: Value
    @State private var hasAppeared = false

    init(
        value: Value,
        deliversInitialValue: Bool,
        action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) {
        self.value = value
        self.deliversInitialValue = deliversInitialValue
        self.action = action
        _previousValue = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                previousValue = value
                if deliversInitialValue {
                    action(value, value)
                }
            }
            .onChange(of: value, perform: valueDidChange)
    }

    private func valueDidChange(_ newValue: Value) {
        let oldValue = previousValue
        previousValue = newValue
        action(oldValue, newValue)
    }
}

/// Opens the SwiftUI Settings scene through its public AppKit menu item contract.
///
/// `EnvironmentValues.openSettings` starts at macOS 14. Ventura still installs the standard
/// Command-, menu item for a `Settings` scene, so routing that existing item's action avoids a
/// private selector and keeps the system responsible for window creation and reuse.
@MainActor
public enum SettingsWindowCompatibility {
    @discardableResult
    public static func open() -> Bool {
        guard let mainMenu = NSApp.mainMenu,
              let item = settingsMenuItem(in: mainMenu),
              item.isEnabled,
              let action = item.action else {
            return false
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    static func settingsMenuItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == ",",
               item.keyEquivalentModifierMask.contains(.command),
               item.action != nil {
                return item
            }
            if let submenu = item.submenu,
               let match = settingsMenuItem(in: submenu) {
                return match
            }
        }
        return nil
    }
}

/// Shared AppKit focus boundary for table-backed SwiftUI views.
///
/// v2026.07.16: focus is requested only from a concrete mouse/context-menu interaction. Async
/// scan publication must never move focus on its own, because doing so interrupts path/search
/// field editing; conversely, custom row canvases consume mouse events and therefore must hand
/// focus to their owning table explicitly for Space/Delete/arrow commands to work.
@MainActor
enum UserInitiatedTableFocus {
    @discardableResult
    static func request(for table: NSTableView) -> Bool {
        guard let window = table.window else { return false }
        return window.makeFirstResponder(table)
    }
}
