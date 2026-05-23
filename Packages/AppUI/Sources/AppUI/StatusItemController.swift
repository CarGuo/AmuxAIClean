import AppKit
import SwiftUI

/// v1.3：状态栏（菜单栏右侧）托盘图标控制器。
///
/// 设计要点（踩坑预防）：
///
/// 1. **API 选择**：使用 `NSStatusBar.system.statusItem(withLength:)` —— 这是
///    macOS 唯一公开稳定的"菜单栏挂件"API。比起摄像头刘海（Apple 不允许 App
///    在硬件凹槽中央绘制，WindowServer 强制裁切）或灵动岛（macOS 根本没有这个 API），
///    状态栏是最稳的选择，也是 NotchNook / DynamicLake 等"刘海挂件"app 在
///    "刘海挂件失败"时的兜底渲染位置。
///
/// 2. **图标用纯色 SF Symbol 模板（isTemplate = true）**：
///    系统会自动按当前菜单栏明 / 暗主题反色，永远清晰。绝不要用彩色 PNG，
///    在浅色 menubar 下会糊掉。
///    我们选 `trash.fill`（清理工具的视觉对应），与 App 主图标语义一致。
///
/// 3. **菜单**：左 / 右键统一弹同一份 NSMenu，包含：
///    - 打开主窗口（onOpenMainWindow）
///    - 开始推荐扫描（onStartRecommendedScan）
///    - 显示 / 隐藏悬浮窗（onToggleHUD）
///    - 退出（onQuit）
///    NSStatusItem 的 button.action 会被 menu 接管，无需自己处理点击事件。
///
/// 4. **生命周期**：`install()` 注册到 NSStatusBar；`uninstall()` 调
///    `removeStatusItem(_:)` 干净移除。AppSettings.trayEnabled toggle 时调用对应方法。
///
/// 5. **MainActor 隔离**：NSStatusItem 必须在主线程操作（AppKit 约束），
///    类标注 @MainActor 由编译器强制。
@MainActor
public final class StatusItemController {

    private var item: NSStatusItem?

    /// 点击"打开主窗口"，由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 注入：调 NSApp.activate + 主窗口 makeKeyAndOrderFront。
    public var onOpenMainWindow: (() -> Void)?

    /// 点击"开始推荐扫描"。注入方调 [ScanCoordinator.scanRecommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)。
    public var onStartRecommendedScan: (() -> Void)?

    /// 点击"显示 / 隐藏悬浮窗"。注入方调 [FloatingScanHUDController.toggleForceVisible](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)。
    public var onToggleHUD: (() -> Void)?

    public init() {}

    /// 把图标挂到 NSStatusBar。重复调用安全 —— 已挂载则直接返回。
    public func install() {
        if item != nil { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // 用 SF Symbol 模板图，系统会自动按 menubar 明暗主题反色。
            // accessibilityDescription 给 VoiceOver / 系统辅助技术读屏用。
            let image = NSImage(
                systemSymbolName: "trash.fill",
                accessibilityDescription: "GSY 清理管家"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "GSY 清理管家"
        }
        statusItem.menu = makeMenu()
        self.item = statusItem
    }

    /// 从 NSStatusBar 拆掉图标。`StatusBar.removeStatusItem` 是公开 API，
    /// 调完后 item 就 nil 了，下次 install 会新建。
    public func uninstall() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.item = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "打开主窗口",
            action: #selector(handleOpenMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let scanItem = NSMenuItem(
            title: "开始推荐扫描",
            action: #selector(handleStartRecommendedScan),
            keyEquivalent: ""
        )
        scanItem.target = self
        menu.addItem(scanItem)

        let hudItem = NSMenuItem(
            title: "显示 / 隐藏悬浮窗",
            action: #selector(handleToggleHUD),
            keyEquivalent: ""
        )
        hudItem.target = self
        menu.addItem(hudItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 GSY 清理管家",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func handleOpenMainWindow() {
        onOpenMainWindow?()
    }

    @objc private func handleStartRecommendedScan() {
        // 顺手把主窗口拉到前台，让用户能看到扫描进度
        onOpenMainWindow?()
        onStartRecommendedScan?()
    }

    @objc private func handleToggleHUD() {
        onToggleHUD?()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
