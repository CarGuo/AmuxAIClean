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
///    - 开始推荐扫描（onStartRecommendedScan）—— **M5：扫描中自动 disable**
///    - 显示 / 隐藏悬浮窗（onToggleHUD）
///    - 退出（onQuit）
///    NSStatusItem 的 button.action 会被 menu 接管，无需自己处理点击事件。
///
/// 4. **生命周期**：`install()` 注册到 NSStatusBar；`uninstall()` 调
///    `removeStatusItem(_:)` 干净移除。AppSettings.trayEnabled toggle 时调用对应方法。
///
/// 5. **MainActor 隔离**：NSStatusItem 必须在主线程操作（AppKit 约束），
///    类标注 @MainActor 由编译器强制。
///
/// 6. **M5（交互更便捷）**：每个菜单项都带 keyEquivalent，键盘一开菜单即可
///    秒选；同时通过 `onQueryScanState` 闭包让"开始推荐扫描"在扫描进行中
///    自动变 disabled，防止并发点击导致 ScanCoordinator 会话覆盖。
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {

    private var item: NSStatusItem?
    /// 缓存最近一次构建的 menu，便于 install() 之外的二次刷新。
    private var menu: NSMenu?
    /// v2026.07.15：App 内语言覆盖的当前 locale。NSMenu 不读取 SwiftUI Environment，
    /// 所以托盘菜单必须由控制器显式重建，不能等下次进程启动。
    private var locale: Locale = .current

    /// 点击"打开主窗口"，由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 注入：调 NSApp.activate + 主窗口 makeKeyAndOrderFront。
    public var onOpenMainWindow: (() -> Void)?

    /// 点击"开始推荐扫描"。注入方调 [ScanCoordinator.scanRecommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)。
    public var onStartRecommendedScan: (() -> Void)?

    /// 点击"显示 / 隐藏悬浮窗"。注入方调 [FloatingScanHUDController.toggleForceVisible](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)。
    public var onToggleHUD: (() -> Void)?

    /// **M5 注入点**：每次菜单将要打开（menuWillOpen）时同步调用，返回当前是否在扫描中。
    /// 用于动态 disable "开始推荐扫描"——nil 时按 false 处理（兼容老调用者）。
    public var onQueryScanState: (() -> Bool)?

    public override init() { super.init() }

    /// 运行期切换托盘菜单语言。只重建四个轻量 NSMenuItem，不触发扫描或其它业务状态。
    public func updateLocale(_ locale: Locale) {
        self.locale = locale
        guard let item else { return }
        if let button = item.button {
            let appName = AppLocalization.string("app.name", locale: locale)
            button.toolTip = appName
            button.image?.accessibilityDescription = appName
        }
        let updatedMenu = makeMenu(locale: locale)
        updatedMenu.delegate = self
        item.menu = updatedMenu
        menu = updatedMenu
    }

    /// 把图标挂到 NSStatusBar。重复调用安全 —— 已挂载则直接返回。
    public func install() {
        if item != nil { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // 用 SF Symbol 模板图，系统会自动按 menubar 明暗主题反色。
            // accessibilityDescription 给 VoiceOver / 系统辅助技术读屏用。
            let image = NSImage(
                systemSymbolName: "trash.fill",
                accessibilityDescription: AppLocalization.string("app.name", locale: locale)
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppLocalization.string("app.name", locale: locale)
        }
        let m = makeMenu(locale: locale)
        m.delegate = self
        statusItem.menu = m
        self.menu = m
        self.item = statusItem
    }

    /// 从 NSStatusBar 拆掉图标。`StatusBar.removeStatusItem` 是公开 API，
    /// 调完后 item 就 nil 了，下次 install 会新建。
    public func uninstall() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.item = nil
        self.menu = nil
    }

    // MARK: - 内部菜单构建（同时供 _testMenuSnapshot 使用）

    /// 单测专用：构建一份"未挂载"的菜单快照（不依赖 NSStatusBar），
    /// 调用方可断言 keyEquivalent / enabled 状态而无需启 UI 测试。
    /// `scanning` 模拟 onQueryScanState 的返回值。
    func _testMenuSnapshot(scanning: Bool, locale: Locale = .current) -> NSMenu {
        let m = makeMenu(locale: locale)
        applyDynamicState(to: m, scanning: scanning, locale: locale)
        return m
    }

    /// **M5 核心**：menu 即将弹出时刷新 disabled 状态。
    public func menuWillOpen(_ menu: NSMenu) {
        let scanning = onQueryScanState?() ?? false
        applyDynamicState(to: menu, scanning: scanning, locale: locale)
    }

    private func applyDynamicState(to menu: NSMenu, scanning: Bool, locale: Locale) {
        // 用 tag 锚定"开始推荐扫描"那项；不依赖位置（防未来插入新项）
        if let scanItem = menu.item(withTag: MenuTag.startScan.rawValue) {
            scanItem.isEnabled = !scanning
            scanItem.title = scanning
                ? AppLocalization.string("tray.scanning", locale: locale)
                : AppLocalization.string("tray.start_recommended", locale: locale)
        }
    }

    private enum MenuTag: Int {
        case openMainWindow = 1001
        case startScan      = 1002
        case toggleHUD      = 1003
        case quit           = 1004
    }

    private func makeMenu(locale: Locale) -> NSMenu {
        let menu = NSMenu()
        // M5：autoenablesItems = false 避免 AppKit 自动校验 target/action 把
        // 我们手动设置的 isEnabled 覆盖回去（AppKit 会顺着 first responder
        // 链找 validateMenuItem，菜单弹出时 first responder 不一定是 self）。
        menu.autoenablesItems = false

        let openItem = NSMenuItem(
            title: AppLocalization.string("tray.menu.open_main", locale: locale),
            action: #selector(handleOpenMainWindow),
            keyEquivalent: "o" // ⌘O：与 Finder 系列一致的"打开"语义
        )
        openItem.target = self
        openItem.tag = MenuTag.openMainWindow.rawValue
        menu.addItem(openItem)

        menu.addItem(.separator())

        let scanItem = NSMenuItem(
            title: AppLocalization.string("tray.menu.start_recommended", locale: locale),
            action: #selector(handleStartRecommendedScan),
            keyEquivalent: "r" // ⌘R：与浏览器/Xcode 的"刷新/构建"语义对齐
        )
        scanItem.target = self
        scanItem.tag = MenuTag.startScan.rawValue
        menu.addItem(scanItem)

        let hudItem = NSMenuItem(
            title: AppLocalization.string("tray.menu.toggle_hud", locale: locale),
            action: #selector(handleToggleHUD),
            keyEquivalent: "h" // ⌘H：与系统 hide 习惯保持类似的字母
        )
        hudItem.target = self
        hudItem.tag = MenuTag.toggleHUD.rawValue
        menu.addItem(hudItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: AppLocalization.string("tray.menu.quit", locale: locale),
            action: #selector(handleQuit),
            keyEquivalent: "q" // ⌘Q：标准退出
        )
        quitItem.target = self
        quitItem.tag = MenuTag.quit.rawValue
        menu.addItem(quitItem)

        return menu
    }

    @objc private func handleOpenMainWindow() {
        onOpenMainWindow?()
    }

    @objc private func handleStartRecommendedScan() {
        // M5：再做一次防御 —— 如果 reopen 之间已经开扫，直接忽略点击
        if onQueryScanState?() == true { return }
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
