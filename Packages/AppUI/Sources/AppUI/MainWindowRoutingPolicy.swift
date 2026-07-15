import AppKit
import SwiftUI

/// 主窗口路由使用的不可变窗口快照。
///
/// 路由逻辑只消费值类型，因此可以在单测里精确覆盖“设置窗口排在主窗口前面”等场景，
/// 不需要启动真实 App 或依赖 AppKit 的全局窗口顺序。
public struct WindowRouteDescriptor: Equatable, Sendable {
    public let identifier: String?
    public let isPanel: Bool
    public let hasContentViewController: Bool
    public let isDisposed: Bool
    public let isVisible: Bool
    public let isMiniaturized: Bool

    public init(
        identifier: String?,
        isPanel: Bool,
        hasContentViewController: Bool,
        isDisposed: Bool,
        isVisible: Bool,
        isMiniaturized: Bool
    ) {
        self.identifier = identifier
        self.isPanel = isPanel
        self.hasContentViewController = hasContentViewController
        self.isDisposed = isDisposed
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }
}

public enum MainWindowRouteDecision: Equatable, Sendable {
    /// 精确聚焦窗口快照中对应下标的主窗口。
    case focusExisting(index: Int)
    /// 没有主窗口，但仍持有 SwiftUI `OpenWindowAction`，请求重建 main scene。
    case requestMainScene
    /// Scene opener 尚未注册时的启动期回退：让 LaunchServices 重新打开当前 App。
    case reopenApplication
}

/// “打开主窗口”的唯一识别与决策合同。
///
/// 设置窗口、帮助窗口与 SwiftUI 内部 host 都可能同时满足“非 NSPanel + 有
/// contentViewController”，因此绝不能靠 `NSApp.windows.first` 或窗口标题猜主窗口。
/// 主 WindowGroup 通过 [MainWindowIdentityMarker] 写入稳定 identifier，路由只认这个身份。
public enum MainWindowRoutingPolicy {
    public static let mainWindowIdentifierRawValue = "com.amux.ai.Clean.window.main"

    public static func decision(
        windows: [WindowRouteDescriptor],
        canRequestMainScene: Bool
    ) -> MainWindowRouteDecision {
        if let index = windows.firstIndex(where: isMainWindowCandidate) {
            return .focusExisting(index: index)
        }
        return canRequestMainScene ? .requestMainScene : .reopenApplication
    }

    public static func hasVisibleMainWindow(in windows: [WindowRouteDescriptor]) -> Bool {
        windows.contains { window in
            isMainWindowCandidate(window) && (window.isVisible || window.isMiniaturized)
        }
    }

    @MainActor
    public static func descriptors(for windows: [NSWindow]) -> [WindowRouteDescriptor] {
        windows.map { window in
            WindowRouteDescriptor(
                identifier: window.identifier?.rawValue,
                isPanel: window is NSPanel,
                hasContentViewController: window.contentViewController != nil,
                isDisposed: window.windowNumber <= 0,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized
            )
        }
    }

    private static func isMainWindowCandidate(_ window: WindowRouteDescriptor) -> Bool {
        window.identifier == mainWindowIdentifierRawValue
            && !window.isPanel
            && window.hasContentViewController
            && !window.isDisposed
    }
}

/// 挂在主 WindowGroup 根视图上的零尺寸 AppKit 探针，为真实 NSWindow 写入稳定身份。
/// Settings scene 不挂这个探针，因此不会再被“打开主窗口”误选。
@MainActor
public struct MainWindowIdentityMarker: NSViewRepresentable {
    private let onWindowIdentified: @MainActor () -> Void

    public init(onWindowIdentified: @escaping @MainActor () -> Void = {}) {
        self.onWindowIdentified = onWindowIdentified
    }

    public func makeNSView(context: Context) -> NSView {
        IdentityView(onWindowIdentified: onWindowIdentified)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let identityView = nsView as? IdentityView else { return }
        identityView.onWindowIdentified = onWindowIdentified
        identityView.markAttachedWindow()
    }

    private final class IdentityView: NSView {
        var onWindowIdentified: @MainActor () -> Void

        init(onWindowIdentified: @escaping @MainActor () -> Void) {
            self.onWindowIdentified = onWindowIdentified
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            markAttachedWindow()
        }

        func markAttachedWindow() {
            guard let window else { return }
            let identifier = NSUserInterfaceItemIdentifier(
                MainWindowRoutingPolicy.mainWindowIdentifierRawValue
            )
            guard window.identifier != identifier else { return }
            window.identifier = identifier
            onWindowIdentified()
        }
    }
}
