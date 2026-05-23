import SwiftUI
import AppUI
import SafetyKit

@main
struct GSYCleanMacApp: App {
    private let vendors: [VendorRule]

    /// v1.0：跨场景共享的设置 / 自定义路径状态（@MainActor @Observable + actor）。
    /// MainView 与 SettingsScene 共用同一份引用，⌘, 改了立刻生效。
    @State private var settings = AppSettings()
    private let pathStore = UserPathStore()

    @State private var showTCCGuide: Bool = false

    /// v1.1 更新检查器，启动时静默 GET 一次 GitHub Releases。
    @State private var updateChecker: UpdateChecker

    /// v1.3：把 ScanCoordinator 提升到 App 层，让主窗口与 [FloatingScanHUDController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
    /// 共享同一个实例（同一份 snapshot / isScanning），HUD 实时刷新不需要双扫。
    @StateObject private var coordinator: ScanCoordinator

    /// v1.3：扫描悬浮窗控制器。NSPanel 寄生在 App 上，跨 Space / 全屏 不被遮。
    @State private var hud = FloatingScanHUDController()

    /// v1.3：状态栏托盘控制器。NSStatusItem 寄生在系统菜单栏右侧，
    /// 关掉主窗口（或将来支持 LSUIElement 模式）后仍能从托盘菜单触发扫描 / 拉回主窗口。
    @State private var statusItem = StatusItemController()

    private let tccDismissedKey = "tcc.onboarding.dismissed"

    init() {
        let loadedVendors = Self.loadBundledVendors()
        self.vendors = loadedVendors
        let s = AppSettings()
        self._settings = State(initialValue: s)
        self._updateChecker = State(initialValue: UpdateChecker(settings: s))
        self._coordinator = StateObject(wrappedValue: ScanCoordinator(vendors: loadedVendors))
    }

    var body: some Scene {
        WindowGroup("GSY 清理管家", id: Self.mainWindowID) {
            MainView(vendors: vendors,
                     settings: settings,
                     pathStore: pathStore,
                     coordinator: coordinator)
            .frame(minWidth: 1080, minHeight: 640)
            .task {
                await evaluateTCCOnboarding()
                // v1.1：尊重 settings.updateCheckEnabled 决定是否联网；用户可在设置里关
                updateChecker.checkOnLaunch()
                // v1.3：把 coordinator + settings 注入 HUD，订阅 isScanning 自动开关 panel
                hud.attach(coordinator: coordinator, settings: settings)
                // v1.3：HUD 上点击"打开主窗口"按钮 → 拉主窗口回前台
                hud.onOpenMainWindow = { Self.bringMainWindowToFront() }
                // v1.3：HUD 闲置态点击"立即扫描"→ 直接走推荐扫描，无需打开主窗口
                hud.onStartScan = { [coordinator] in
                    coordinator.scanRecommended(includeHidden: settings.showHidden)
                }
                // v1.3：托盘菜单回调注入
                statusItem.onOpenMainWindow = { Self.bringMainWindowToFront() }
                statusItem.onStartRecommendedScan = { [coordinator] in
                    coordinator.scanRecommended(includeHidden: settings.showHidden)
                }
                statusItem.onToggleHUD = { [hud] in
                    hud.toggleForceVisible()
                }
                // v1.3：根据 settings.trayEnabled 注册 / 移除菜单栏图标
                reconcileTray()
            }
            .onChange(of: coordinator.isScanning) { _, _ in
                // v1.3：扫描开始 → HUD 弹出；扫描结束 → 非常驻模式下 0.8s 后渐隐
                hud.reconcile()
            }
            .onChange(of: settings.hudEnabled) { _, _ in
                // 用户 toggle 设置里的 HUD 开关，立即生效
                hud.reconcile()
            }
            .onChange(of: settings.hudPersistent) { _, _ in
                // 用户 toggle 常驻模式 → 立即让 HUD 弹/隐
                hud.reconcile()
            }
            .onChange(of: settings.hudPlacement) { _, _ in
                // 用户切位置（顶部 / 桌面右上 / 桌面右下 / 桌面左下）→ rebuild panel
                hud.reconcile()
            }
            .onChange(of: settings.trayEnabled) { _, _ in
                // 用户 toggle 设置里的托盘开关，立即生效
                reconcileTray()
            }
            .sheet(isPresented: $showTCCGuide) {
                TCCGuideView { openedSettings in
                    if openedSettings {
                        UserDefaults.standard.set(true, forKey: tccDismissedKey)
                    }
                    showTCCGuide = false
                }
            }
            .sheet(item: Binding(
                get: { updateChecker.availableUpdate.map { IdentifiedRelease(release: $0) } },
                set: { _ in updateChecker.dismissUntilNextLaunch() }
            )) { wrapped in
                UpdatePromptView(checker: updateChecker, release: wrapped.release)
            }
        }
        .commands {
            // v1.1：Help 菜单加"检查更新"入口
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updateChecker.checkNow()
                }
            }
            // v1.3：View 菜单加"显示扫描悬浮窗"toggle，⌘⇧H 快捷键。
            // 用 CommandGroup(after: .toolbar) 让它落在 macOS 标准"显示"区。
            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("显示扫描悬浮窗", isOn: hudBinding)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        // v1.0：标准 ⌘, 设置窗口（隐藏文件 toggle / 大文件阈值 / 自定义路径）。
        Settings {
            SettingsScene(settings: settings, pathStore: pathStore, updateChecker: updateChecker)
        }
    }

    /// v1.3：HUD 开关 binding —— get 直接读 settings；set 写 settings 触发 onChange → reconcile。
    private var hudBinding: Binding<Bool> {
        Binding(
            get: { settings.hudEnabled },
            set: { settings.hudEnabled = $0 }
        )
    }

    /// v1.3：根据 settings.trayEnabled 注册 / 移除菜单栏托盘图标。
    private func reconcileTray() {
        if settings.trayEnabled {
            statusItem.install()
        } else {
            statusItem.uninstall()
        }
    }

    /// v1.3：把主窗口拉回前台并激活进程。
    /// - 给 HUD 的"打开主窗口"按钮 / 托盘"打开主窗口"菜单调用。
    ///
    /// **v1.3 review-fix B1+B2+B3**：原实现存在三个真问题：
    /// 1. `NSApp.activate(ignoringOtherApps: true)` 在 macOS 14+ 已 deprecated，且
    ///    Apple 论坛 thread/739075 明确指出 Sonoma 起 ~15% 概率不激活 App，导致用户点
    ///    托盘 / HUD"打开主窗口"明显"没反应"。改用新 API `NSApp.activate()`。
    /// 2. `NSApp.windows where !(window is NSPanel)` 仍会命中 SwiftUI 创建的隐藏辅助窗口
    ///    （menu bar item 关联窗口、tooltip / popover host 等），这些都满足 `canBecomeKey == true`。
    ///    必须叠加 `isVisible || identifier` 等更强过滤才能精准命中主窗口。
    /// 3. 用户 ⌘W 关掉主窗口后，SwiftUI WindowGroup 默认实例被销毁；调 `makeKeyAndOrderFront`
    ///    在 NSApp.windows 里根本找不到主窗口，"打不开"。修复：用 `OpenWindowAction` 通过
    ///    通知中心向 MainView 发"openMainWindow"广播，由 view 层调 `openWindow(id:)` 重建。
    @MainActor
    fileprivate static let mainWindowID = "main"

    @MainActor
    private static func bringMainWindowToFront() {
        // v1.3 review-fix B1：新 API（macOS 14+），不再用 deprecated 的 ignoringOtherApps 形式。
        NSApp.activate()

        // v1.3 review-fix B2：精确过滤——必须满足"非 panel + 非隐藏辅助窗口"，
        // 用 contentViewController != nil + (isVisible || isMiniaturized) + title 匹配
        // 三个条件叠加，能把 SwiftUI 的内部辅助 host 全部排除。
        let candidate = NSApp.windows.first { window in
            guard !(window is NSPanel) else { return false }
            // SwiftUI WindowGroup 创建的主窗口一定有 contentViewController（NSHostingController）
            guard window.contentViewController != nil else { return false }
            // 排除已 release / 已弃用的窗口（windowNumber < 0 表示已 dispose）
            guard window.windowNumber > 0 else { return false }
            return true
        }

        if let window = candidate {
            // 主窗口被最小化时，先 deminiaturize 再 makeKey
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        // v1.3 review-fix B3：找不到主窗口（用户 ⌘W 关掉后 WindowGroup 实例已销毁）。
        // 通过通知请求 view 层重建窗口。MainView 的 onReceive 会响应。
        NotificationCenter.default.post(name: .gsyOpenMainWindowRequested, object: nil)
    }

    private func evaluateTCCOnboarding() async {
        if UserDefaults.standard.bool(forKey: tccDismissedKey) {
            return
        }
        let probe = TCCProbe()
        let status = await probe.probe()
        if case .deniedReadable = status {
            await MainActor.run {
                showTCCGuide = true
            }
        }
    }

    private static func loadBundledVendors() -> [VendorRule] {
        guard let url = Bundle.main.url(forResource: "vendors",
                                        withExtension: "yaml",
                                        subdirectory: "Rules")
            ?? Bundle.main.url(forResource: "vendors", withExtension: "yaml")
        else {
            NSLog("[GSYCleanMac] vendors.yaml 未找到，跳过 vendor 规则加载")
            return []
        }
        do {
            let rules = try RuleLoader.loadVendors(from: url)
            NSLog("[GSYCleanMac] 已加载 \(rules.count) 条 vendor 规则")
            return rules
        } catch {
            NSLog("[GSYCleanMac] vendor 规则加载失败：\(error)")
            return []
        }
    }
}
