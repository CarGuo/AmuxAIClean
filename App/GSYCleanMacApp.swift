import SwiftUI
import AppUI
import AppKit
import LogKit
import SafetyKit
import ScanKit
import AIKit

private enum MainWindowMetrics {
    static let minWidth: CGFloat = 1280
    static let minHeight: CGFloat = 760
    static let defaultWidth: CGFloat = 1360
    static let defaultHeight: CGFloat = 820
}

/// App 退出前排空 UndoHistory 的后台串行写队列，并把最新内存快照再原子落盘一次。
/// 该同步只发生在进程终止阶段，不占用正常交互帧；避免最后一次清理刚完成就退出时丢失恢复记录。
@MainActor
private final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    private typealias MainWindowSceneOpener = @MainActor () -> Void
    private var mainWindowSceneOpeners: [UUID: MainWindowSceneOpener] = [:]

    func applicationWillTerminate(_ notification: Notification) {
        UndoHistoryStore.shared.saveHistorySync()
    }

    var canRequestMainWindowScene: Bool {
        !mainWindowSceneOpeners.isEmpty
    }

    func installMainWindowSceneOpener(
        id: UUID,
        _ opener: @escaping @MainActor () -> Void
    ) {
        mainWindowSceneOpeners[id] = opener
    }

    func removeMainWindowSceneOpener(id: UUID) {
        mainWindowSceneOpeners.removeValue(forKey: id)
    }

    @discardableResult
    func requestMainWindowScene() -> Bool {
        guard let mainWindowSceneOpener = mainWindowSceneOpeners.values.first else {
            return false
        }
        mainWindowSceneOpener()
        return true
    }
}

/// 把 SwiftUI 的 `OpenWindowAction` 提升到 App delegate 生命周期。
/// 主窗口关闭后其 View 已销毁，但托盘仍需能够精确重建 `main` scene；设置窗口也挂载
/// 同一个桥，确保“只剩设置窗口”时不会退回模糊的 AppKit 窗口遍历。
@MainActor
private struct MainWindowOpenActionBridge: View {
    @Environment(\.openWindow) private var openWindow
    @State private var registrationID = UUID()

    let sceneID: String
    let delegate: ApplicationLifecycleDelegate

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                let action = openWindow
                delegate.installMainWindowSceneOpener(id: registrationID) {
                    action(id: sceneID)
                }
            }
            .onDisappear {
                delegate.removeMainWindowSceneOpener(id: registrationID)
            }
    }
}

@main
struct GSYCleanMacApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var lifecycleDelegate

    private let vendors: [VendorRule]

    /// v1.0：跨场景共享的设置 / 自定义路径状态（@MainActor @Observable + actor）。
    /// MainView 与 SettingsScene 共用同一份引用，⌘, 改了立刻生效。
    @State private var settings = AppSettings()
    private let pathStore = UserPathStore()

    /// M5 / 2026-06：AI 模块配置——**必须由 App 层统一持有**并同时注入
    /// [MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 与 [SettingsScene](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SettingsScene.swift)，
    /// 否则两个场景各自 new 一份 [AISettings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/AISettings.swift)
    /// 实例：底层 UserDefaults 仍一致，但 @Observable 的 in-process 通知不会跨实例传递，
    /// 用户在 ⌘, 改了 AI Enabled / baseURL 后，RowView contextMenu 不会立刻刷新
    /// （需重启 App 才生效）。详见 Review fix #2，2026-06-15。
    @State private var aiSettings = AISettings()
    @State private var settingsNavigation = SettingsNavigation()

    @State private var showTCCGuide: Bool = false

    /// v1.1 更新检查器，启动时静默 GET 一次 GitHub Releases。
    @State private var updateChecker: UpdateChecker

    /// v1.3：把 ScanCoordinator 提升到 App 层，让主窗口与 [FloatingScanHUDController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
    /// 共享同一个实例（同一份 snapshot / isScanning），HUD 实时刷新不需要双扫。
    @StateObject private var coordinator: ScanCoordinator

    /// Smart Care 普通模式会话提升到 App 层，确保主窗口、HUD 和托盘入口共享
    /// 同一份 phase / summary / selection，不会出现后台已扫描而首页仍显示 idle。
    @State private var smartCareSession: SmartCareSession

    /// Normal AI Review 与 Smart Care 扫描会话同样提升到 App 生命周期：
    /// 主窗口关闭时请求继续，完成后不抢前台；重新打开可查看最新终态报告。
    @State private var smartCareAIReviewSession: SmartCareAIReviewSession

    /// v1.3：扫描悬浮窗控制器。NSPanel 寄生在 App 上，跨 Space / 全屏 不被遮。
    @State private var hud = FloatingScanHUDController()

    /// v1.3：状态栏托盘控制器。NSStatusItem 寄生在系统菜单栏右侧，
    /// 关掉主窗口（或将来支持 LSUIElement 模式）后仍能从托盘菜单触发扫描 / 拉回主窗口。
    @State private var statusItem = StatusItemController()

    /// v1.3.x：App 激活策略控制器。控制"关窗后是否隐 Dock + 隐顶部主菜单"的切换。
    /// 仅当 settings.hideFromDockWhenClosed 开启时才会真正切到 .accessory；
    /// 关闭时永远保持 .regular，与现行行为完全一致。
    @State private var activationPolicy = ActivationPolicyController()

    /// v1.6：Sentinel 守护管理器（SMAppService.daemon 包装）。
    /// 在 init 阶段构造，启动钩子里按 [settings.sentinelEnabled](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 做幂等 register；v2026.07.16 起用户 toggle 先经过 typed change-source 边界，
    /// 程序性失败回滚不会再由 `.onChange` 重复驱动 enable / disable。
    @State private var sentinelManager: SentinelManager

    private let tccDismissedKey = "tcc.onboarding.dismissed"

    init() {
        // v1.3.zzzz Phase 6：进程一启动就接通 GSYLog 文件 sink。
        // 落盘位置 ~/Library/Logs/AmuxAIClean/，按天滚动保留 7 天；构造失败时降级到仅 OSLog。
        // Debug 默认 .debug 阈值（最详细），Release 默认 .info；不再额外区分。
        do {
            let logDir = try LogFileSink.defaultDirectory()
            let sink = try LogFileSink(directory: logDir)
            #if DEBUG
            GSYLog.configure(minimumLevel: .debug, fileSink: sink)
            #else
            GSYLog.configure(minimumLevel: .info, fileSink: sink)
            #endif
            GSYLog.notice(.app, "App 启动 logDir=\(sink.directory.path)")
        } catch {
            NSLog("[AmuxAIClean] LogFileSink 初始化失败：\(error)（仅 OSLog 可用）")
        }

        let loadedVendors = Self.loadBundledVendors()
        self.vendors = loadedVendors
        let s = AppSettings()
        self._settings = State(initialValue: s)
        self._updateChecker = State(initialValue: UpdateChecker(settings: s))
        // v1.6：Sentinel 管理器与 AppSettings 同生命周期；register / unregister
        // 由启动钩子 + onChange 驱动，AppSettings 里 didSet 不直接调 SMAppService。
        self._sentinelManager = State(initialValue: SentinelManager(settings: s))
        // v2026.06.22：产品路径不再打开/写入扫描数据库。
        // 扫描结果每次来自实时扫描；树形下钻由 ScanCoordinator.directChildrenAsync
        // 后台按需扫描当前目录并聚合直接子项，避免扫描结果数据库与扫描收尾落盘等待。
        //
        // 深索引仍默认关闭：祖先字典维护是扫描期主线程卡顿的历史根因。开发者可用
        // GSY_DEEP_INDEX=1 做 A/B，但正式用户走无数据库、按需后台下钻方案。
        let deepIndex = (ProcessInfo.processInfo.environment["GSY_DEEP_INDEX"] ?? "0") != "0"
        let professionalCoordinator = ScanCoordinator(
            vendors: loadedVendors,
            enableTreeDeepIndex: deepIndex
        )
        self._coordinator = StateObject(wrappedValue: professionalCoordinator)
        let smartCareScanner = ScanCoordinator(
            vendors: loadedVendors,
            enableTreeDeepIndex: false
        )
        self._smartCareSession = State(initialValue: SmartCareSession(
            scanCoordinator: smartCareScanner
        ))
        self._smartCareAIReviewSession = State(initialValue: SmartCareAIReviewSession())
    }

    var body: some Scene {
        // v2026.07.15：WindowGroup 标题也属于先落成 String 的 AppKit 边界；显式按
        // 当前设置语言解析，避免主界面已切换而窗口标题仍冻结在进程启动语言。
        WindowGroup(
            AppLocalization.string("app.name", locale: settings.effectiveLocale),
            id: Self.mainWindowID
        ) {
            MainView(vendors: vendors,
                     settings: settings,
                     pathStore: pathStore,
                     coordinator: coordinator,
                     smartCareSession: smartCareSession,
                     smartCareAIReviewSession: smartCareAIReviewSession,
                     aiSettings: aiSettings,
                     settingsNavigation: settingsNavigation)
            .frame(minWidth: MainWindowMetrics.minWidth,
                   minHeight: MainWindowMetrics.minHeight)
            .environment(\.locale, settings.effectiveLocale)
            .background {
                MainWindowIdentityMarker {
                    reconcileActivationPolicy()
                }
                    .frame(width: 0, height: 0)
                MainWindowOpenActionBridge(
                    sceneID: Self.mainWindowID,
                    delegate: lifecycleDelegate
                )
            }
            .task {
                // v1.7：AppleLanguages 保持跨进程一致；当前会话的 SwiftUI、String 型
                // tooltip、托盘与主菜单分别由 environment + applyLiveLocale 即时刷新。
                settings.applyToAppleLanguagesIfNeeded()
                applyLiveLocale()
                await evaluateTCCOnboarding()
                // v1.1：尊重 settings.updateCheckEnabled 决定是否联网；用户可在设置里关
                updateChecker.checkOnLaunch()
                // v1.3：把 coordinator + settings 注入 HUD，订阅 isScanning 自动开关 panel
                hud.attach(
                    coordinator: coordinator,
                    settings: settings,
                    smartCareSession: smartCareSession
                )
                // v1.3：HUD 上点击"打开主窗口"按钮 → 拉主窗口回前台
                hud.onOpenMainWindow = { Self.bringMainWindowToFront() }
                // HUD / 托盘都走同一份 Smart Care 会话：即使主窗口关闭，扫描状态和
                // 最终摘要也会保留，重新打开窗口后普通模式可直接继续展示。
                hud.onStartScan = { [smartCareSession, smartCareAIReviewSession] in
                    // 主窗口可能已经被 ⌘W 销毁；扫描配置必须在真正的 App 级入口
                    // 重新同步，不能依赖 MainView.task/onChange 仍然存活。
                    smartCareAIReviewSession.reset()
                    smartCareSession.scanCoordinator.refreshFDAStatus()
                    smartCareSession.startScan(
                        includeHidden: settings.showHidden,
                        enabledDeveloperRuleIDs: settings.enabledDevArtifactRuleIDs
                    )
                }
                // v1.3：托盘菜单回调注入
                statusItem.onOpenMainWindow = { Self.bringMainWindowToFront() }
                statusItem.onStartRecommendedScan = { [smartCareSession, smartCareAIReviewSession] in
                    smartCareAIReviewSession.reset()
                    smartCareSession.scanCoordinator.refreshFDAStatus()
                    smartCareSession.startScan(
                        includeHidden: settings.showHidden,
                        enabledDeveloperRuleIDs: settings.enabledDevArtifactRuleIDs
                    )
                }
                statusItem.onToggleHUD = { [hud] in
                    hud.toggleForceVisible()
                }
                // M5（交互更便捷）：弹菜单时同步查询扫描状态，
                // 让"开始推荐扫描"在已经在扫时自动 disable + 标题转"扫描中…"。
                statusItem.onQueryScanState = { [coordinator, smartCareSession] in
                    coordinator.isScanning || smartCareSession.isBusy
                }
                // v1.3：根据 settings.trayEnabled 注册 / 移除菜单栏图标
                reconcileTray()
                // v1.3.x：首启即按用户偏好把激活策略就位（默认 false → regular，行为不变）。
                reconcileActivationPolicy()
                // v1.6：Sentinel 启动钩子——若用户已 ON，进程拉起时立刻幂等 register，
                // 兜住升级 / 重装 / SMAppService bundle 路径变化等场景。默认 OFF 时跳过。
                reconcileSentinelAtStartup()

                // v2026.07.16：移除所有环境变量驱动的 App 内测试/自动扫盘入口。
                // 反复启动并 exit 不能验证 UI；未授权的启动时自动扫描也不应进入 Release。
                // 逻辑回归使用 package tests，性能使用 ScanKit CLI，真实交互只做持续 C4。
            }
            .onChange(of: coordinator.isScanning) { _, _ in
                // v1.3：扫描开始 → HUD 弹出；扫描结束 → 非常驻模式下 0.8s 后渐隐
                hud.reconcile()
            }
            .onChange(of: smartCareSession.isBusy) { _, _ in
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
                // 关托盘可能联动关掉 hideFromDockWhenClosed（互斥兜底），重新核对一次激活策略。
                reconcileActivationPolicy()
            }
            .onChange(of: settings.hideFromDockWhenClosed) { _, _ in
                // 用户 toggle"关窗藏 Dock"开关 → 立即 reconcile：
                // 开 + 当前没有可见主窗口 → 直接进 accessory；
                // 开 + 有可见主窗口 → 保持 regular（关窗时再切）；
                // 关 → 立刻回 regular，不会让用户因为 Dock 没了而困惑。
                reconcileActivationPolicy()
            }
            .onChange(of: settings.sentinelEnabled) { oldValue, newValue in
                // v2026.07.16：所有 Sentinel setting 变化先过 MainActor 类型化事务边界。
                // 真实用户手势才 reconcile；失败回滚产生的第二轮 onChange 只消费事务，
                // 不重复 register/unregister、不重复弹错，也不靠异步延时猜事件来源。
                _ = sentinelManager.handleObservedToggleChange(
                    from: oldValue,
                    to: newValue
                )
            }
            .onChange(of: settings.preferredLanguage) { _, _ in
                // v2026.07.15：String 型 tooltip / tray NSMenu / application main menu
                // 不读取 SwiftUI environment；统一刷新其显式 locale 边界。
                applyLiveLocale()
            }
            .onOpenURL { url in
                // v1.6：daemon 通过 `amuxaiclean://` 把候选传回主 App。
                // 拉主窗口 + 路由分发由 SentinelURLRouter 完成（NotificationCenter 广播）。
                Self.bringMainWindowToFront()
                _ = SentinelURLRouter.handle(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                // v1.3.x：监听任意 NSWindow 关闭。延后到下一 runloop 再判断"是否还有可见主窗口"——
                // willClose 触发时窗口尚未 isVisible=false，立即判断会误以为还在。
                handleWindowVisibilityChange(note: note, isClosing: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                // 主窗口被打开 / 拉回前台 → 立刻同步策略（accessory→regular）。
                reconcileActivationPolicy()
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
        .defaultSize(width: MainWindowMetrics.defaultWidth,
                     height: MainWindowMetrics.defaultHeight)
        .commands {
            // v2026.06.22 perf：把 .commands 内容拆到独立 Commands struct。
            //
            // 根因（Instruments Hangs 模板取证）：dev 扫场景下每 0.4s 一次
            // publishSnapshot → Scene body invalidate → SwiftUI 重跑这个
            // `.commands { }` 闭包 → AppKit 调
            // `AppDelegate.makeMainMenuUpdateImmediately` 整张 NSMenu 拆建 →
            // 7 个 NSMenuItem 全部重新走进程级 bundle 查表（NSCache.objectForKey /
            // NSPathStore2.fastCharacterContents / NSAttributedString.init）
            // → 主线程 100~600ms microhang 连成串。
            //
            // 修复双管齐下：
            //  ① 拆为 [GSYCleanCommands](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
            //     独立 Commands struct，参数（class ref + Binding + locale）等价时
            //     SwiftUI 跳过菜单重建。
            //  ② 7 个标题显式按 locale 解析；只有语言变化才改变 Commands 依赖，
            //     扫描 snapshot publish 不会触发本地化查表。
            GSYCleanCommands(
                updateChecker: updateChecker,
                hudShown: hudBinding,
                locale: settings.effectiveLocale
            )
        }

        // v1.0：标准 ⌘, 设置窗口（隐藏文件 toggle / 大文件阈值 / 自定义路径）。
        Settings {
            SettingsScene(settings: settings,
                          pathStore: pathStore,
                          updateChecker: updateChecker,
                          aiSettings: aiSettings,
                          navigation: settingsNavigation,
                          sentinelManager: sentinelManager)
                .environment(\.locale, settings.effectiveLocale)
                .onChange(of: settings.preferredLanguage, initial: true) { _, _ in
                    // 主窗口可能已关闭，只剩 Settings scene；这里同样刷新原生菜单。
                    applyLiveLocale()
                }
                .background {
                    MainWindowOpenActionBridge(
                        sceneID: Self.mainWindowID,
                        delegate: lifecycleDelegate
                    )
                }
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
            statusItem.updateLocale(settings.effectiveLocale)
        } else {
            statusItem.uninstall()
        }
    }

    /// v2026.07.15：把同一份语言状态同步到所有非 SwiftUI locale 消费者。
    /// v2026.07.16：两个扫描协调器属于 App 生命周期，必须在这里一起同步；
    /// 这样主窗口销毁、只剩 Settings scene 时切语言，托盘/HUD 后续发起的扫描也不会
    /// 继续生成旧语言文案。fanout 只写展示 locale，不重扫、不替换或重建 snapshot。
    /// 延后一轮再刷新 main menu，是为了让本次 SwiftUI Commands diff 先完成，
    /// 避免刚改好的原生标题被随后发生的 command rebuild 覆盖回启动语言。
    private func applyLiveLocale() {
        let locale = settings.effectiveLocale
        ScanPresentationLocaleFanout.apply(
            locale,
            professionalCoordinator: coordinator,
            smartCareCoordinator: smartCareSession.scanCoordinator
        )
        statusItem.updateLocale(locale)
        ApplicationMenuLocalizer.apply(locale: locale)
        DispatchQueue.main.async {
            ApplicationMenuLocalizer.apply(locale: locale)
        }
    }

    /// v1.3.x：根据当前主窗口可见性 + settings.hideFromDockWhenClosed 决定 NSApp 激活策略。
    ///
    /// 调用时机：
    /// - App 启动 task 内 → 让首启即按用户偏好就位
    /// - settings.hideFromDockWhenClosed onChange
    /// - settings.trayEnabled onChange（互斥兜底可能反向关掉 hideFromDockWhenClosed）
    /// - NSWindow.willCloseNotification（窗口被关）
    /// - NSWindow.didBecomeKeyNotification（窗口被打开/激活）
    @MainActor
    private func reconcileActivationPolicy() {
        let hasVisible = Self.hasVisibleMainWindow()
        activationPolicy.reconcile(
            hideEnabled: settings.hideFromDockWhenClosed,
            hasVisibleMainWindow: hasVisible
        )
    }

    /// v1.6：把 [settings.sentinelEnabled](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 与 SMAppService 的实际 register 状态对齐。
    ///
    /// v2026.07.16：启动对账与用户手势使用不同入口。用户变化只允许从
    /// `handleObservedToggleChange` 进入；这里不能再接收 Bool 参数，否则程序性回滚很容易
    /// 被误标成 `.user` 并重复执行系统动作。
    @MainActor
    private func reconcileSentinelAtStartup() {
        _ = sentinelManager.reconcile(trigger: .startup)
    }

    /// v1.3.x：响应 NSWindow.willCloseNotification —— willClose 时窗口本身仍 isVisible=true，
    /// 必须把判断 push 到下一 runloop 再做，否则永远以为"还有可见主窗口"，accessory 切换不发生。
    @MainActor
    private func handleWindowVisibilityChange(note: Notification, isClosing: Bool) {
        guard isClosing else { return }
        // 仅在主窗口（非 NSPanel、非 settings 窗、非辅助 host）关闭时才需要重核策略。
        // 这里直接放行所有 NSWindow 通知，让 hasVisibleMainWindow 用统一过滤兜底——
        // 误触发的代价是多调一次 setActivationPolicy（applyIfChanged 会幂等吞掉）。
        DispatchQueue.main.async {
            self.reconcileActivationPolicy()
        }
    }

    /// v1.3.x：判断当前是否至少有一个"可见主窗口"——即用户视觉上能看到 / 点亮的主窗口。
    /// 与 [bringMainWindowToFront](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift) 共用
    /// [MainWindowRoutingPolicy](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainWindowRoutingPolicy.swift)：
    /// 只认主 WindowGroup 写入的稳定 identifier，再判断 (isVisible || isMiniaturized)。
    /// 最小化窗口算"可见"，因为 Dock 还有缩略图，用户预期 Dock 图标在场。
    @MainActor
    private static func hasVisibleMainWindow() -> Bool {
        MainWindowRoutingPolicy.hasVisibleMainWindow(
            in: MainWindowRoutingPolicy.descriptors(for: NSApp.windows)
        )
    }

    /// v1.3：把主窗口拉回前台并激活进程。
    /// - 给 HUD 的"打开主窗口"按钮 / 托盘"打开主窗口"菜单调用。
    ///
    /// **v1.3 review-fix B1+B2+B3**：原实现存在三个真问题：
    /// 1. `NSApp.activate(ignoringOtherApps: true)` 在 macOS 14+ 已 deprecated，且
    ///    Apple 论坛 thread/739075 明确指出 Sonoma 起 ~15% 概率不激活 App，导致用户点
    ///    托盘 / HUD"打开主窗口"明显"没反应"。改用新 API `NSApp.activate()`。
    /// 2. `NSApp.windows where !(window is NSPanel)` 会命中 Settings 和 SwiftUI 辅助窗口；
    ///    主窗口必须由稳定 identifier 精确识别，不能依赖数组顺序或本地化标题。
    /// 3. 用户 ⌘W 关掉主窗口后，SwiftUI WindowGroup 默认实例被销毁；调 `makeKeyAndOrderFront`
    ///    在 NSApp.windows 里根本找不到主窗口。修复：把 `OpenWindowAction` 提升到 App delegate
    ///    生命周期，由托盘直接请求 `main` scene；通知 + LaunchServices 仅保留为启动期回退。
    @MainActor
    fileprivate static let mainWindowID = "main"

    @MainActor
    private static func bringMainWindowToFront() {
        // v1.3 review-fix B1：新 API（macOS 14+），不再用 deprecated 的 ignoringOtherApps 形式。
        // **v1.3.zz 关窗后修复**：当前 App 可能已经处于 .accessory（藏 Dock）模式——
        // 直接 activate() 在 accessory 下不会让窗口拉回前台 / 抢焦点，必须先把策略切回
        // .regular 才能正常显示主窗口与抢键盘焦点。这一步幂等：已是 regular 不会反复调。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let windows = NSApp.windows
        let lifecycleDelegate = NSApp.delegate as? ApplicationLifecycleDelegate
        let decision = MainWindowRoutingPolicy.decision(
            windows: MainWindowRoutingPolicy.descriptors(for: windows),
            canRequestMainScene: lifecycleDelegate?.canRequestMainWindowScene == true
        )

        switch decision {
        case let .focusExisting(index):
            guard windows.indices.contains(index) else { break }
            let window = windows[index]
            // 主窗口被最小化时，先 deminiaturize 再 makeKey
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return

        case .requestMainScene:
            if lifecycleDelegate?.requestMainWindowScene() == true {
                return
            }

        case .reopenApplication:
            break
        }

        // v1.3 review-fix B3 + v1.3.zz 强化：找不到主窗口（用户 ⌘W 关掉后 WindowGroup 实例已销毁）。
        //
        // 老路径：post Notification → MainView.onReceive → openWindow(id:)。
        // 但 MainView 已随 WindowGroup 销毁一同消失，监听器**已失效**——通知发出后无人接收，
        // 主窗口永远开不回来（即图 2 的"托盘 / HUD 打开主窗口按钮无效"）。
        //
        // 新路径：用 NSWorkspace.open(Bundle.main.bundleURL) 让 LaunchServices 把"已运行的 App"
        // 重新激活；这等价于用户从 Dock / Launchpad 再次点 App 图标，会触发 SwiftUI WindowGroup
        // 的默认 reopen 行为（automatically reopen the main window）。这是 macOS 上"已运行 App
        // 重开主窗口"业内通用做法，Mail / 微信 / Bartender 都用这套。
        //
        // 通知仍然 post——万一 MainView 还活着（罕见的 phantom 状态），它接到能立刻 openWindow，
        // 比等 LaunchServices reopen 快几十 ms。
        NotificationCenter.default.post(name: .gsyOpenMainWindowRequested, object: nil)

        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // createsNewApplicationInstance 默认 false，会触发已运行实例的 reopen 而不是双开。
        NSWorkspace.shared.open(bundleURL, configuration: config) { _, error in
            if let error {
                // 兜底诊断日志（极罕见：只有 Bundle 被 ad-hoc 签或权限被剥夺时才会失败）。
                NSLog("[AmuxAIClean] bringMainWindowToFront fallback open failed: \(error)")
            }
        }
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
            NSLog("[AmuxAIClean] vendors.yaml 未找到，跳过 vendor 规则加载")
            return []
        }
        do {
            let rules = try RuleLoader.loadVendors(from: url)
            NSLog("[AmuxAIClean] 已加载 \(rules.count) 条 vendor 规则")
            return rules
        } catch {
            NSLog("[AmuxAIClean] vendor 规则加载失败：\(error)")
            return []
        }
    }

    /// v1.5.7：Help 菜单统一的外链跳转入口。
    /// 只允许 https，避免后续被改成 file:// / shell: 等危险 scheme。
    ///
    /// v2026.06.22 perf：从 `private` 放宽到 `fileprivate`，让同文件的
    /// [GSYCleanCommands](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 可以复用，避免把整个 helper 在 Commands struct 内再写一份。
    @MainActor
    fileprivate static func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https" else {
            NSLog("[AmuxAIClean] openExternal 拒绝非 https URL: \(urlString)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// v1.5.7：Help → 在 Finder 中显示日志。
    /// 日志路径与 [GSYLog.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LogKit/Sources/LogKit/GSYLog.swift) 默认 sink 保持一致。
    ///
    /// v2026.06.22 perf：从 `private` 放宽到 `fileprivate`，让同文件的
    /// [GSYCleanCommands](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 可以复用（理由同 [openExternal](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)）。
    @MainActor
    fileprivate static func revealLogsInFinder() {
        let fm = FileManager.default
        let logDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/AmuxAIClean", isDirectory: true)
        guard let logDir else {
            NSLog("[AmuxAIClean] revealLogsInFinder 找不到 ~/Library/Logs 目录")
            return
        }
        if !fm.fileExists(atPath: logDir.path) {
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([logDir])
    }
}

/// v2026.06.22 perf：从 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
/// 的 `.commands { }` 拆出，让 dev 扫 publish 风暴下 Scene body invalidate
/// **不再**让 AppKit 重建整张 NSMenu。
///
/// 关键设计：
/// - 菜单只持有轻量的 locale 值；扫描 snapshot 不进入依赖面，所以扫描帧不会重建菜单。
/// - 语言变化时 Commands identity 才变化，7 个标题通过 AppLocalization 按新 locale
///   解析一次，兼顾运行期切换与原有性能边界。
/// - **不持有 AppSettings**：dev 扫期间 settings 不会变，但 AppSettings
///   是 `@Observable`，作为 stored prop 会让本 struct 被 SwiftUI 视为
///   会变化的依赖；改成只传 `Binding<Bool>` 后依赖面收紧到 hudEnabled 一项。
private struct GSYCleanCommands: Commands {
    let updateChecker: UpdateChecker
    @Binding var hudShown: Bool
    let locale: Locale

    var body: some Commands {
        // v1.1：Help 菜单加"检查更新"入口（实际落在 appInfo 后面，约定俗成）
        CommandGroup(after: .appInfo) {
            Button(AppLocalization.string("menu.app.checkUpdates", locale: locale)) {
                updateChecker.checkNow()
            }
        }
        // v1.3：View 菜单加"显示扫描悬浮窗"toggle，⌘⇧H 快捷键。
        // 用 CommandGroup(after: .toolbar) 让它落在 macOS 标准"显示"区。
        CommandGroup(after: .toolbar) {
            Divider()
            Toggle(AppLocalization.string("menu.view.showHUD", locale: locale), isOn: $hudShown)
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }
        // v1.5.7：替换 SwiftUI 默认的占位 Help 菜单，提供生产级帮助入口。
        CommandGroup(replacing: .help) {
            Button(AppLocalization.string("menu.help.help", locale: locale)) {
                GSYCleanMacApp.openExternal("https://github.com/CarGuo/GSYCleanMac#readme")
            }
            .keyboardShortcut("?", modifiers: [.command])
            Divider()
            Button(AppLocalization.string("menu.help.privacy", locale: locale)) {
                GSYCleanMacApp.openExternal("https://github.com/CarGuo/GSYCleanMac/blob/main/PRIVACY.md")
            }
            Button(AppLocalization.string("menu.help.terms", locale: locale)) {
                GSYCleanMacApp.openExternal("https://github.com/CarGuo/GSYCleanMac/blob/main/TERMS.md")
            }
            Divider()
            Button(AppLocalization.string("menu.help.feedback", locale: locale)) {
                GSYCleanMacApp.openExternal("https://github.com/CarGuo/GSYCleanMac/issues/new/choose")
            }
            Button(AppLocalization.string("menu.help.revealLogs", locale: locale)) {
                GSYCleanMacApp.revealLogsInFinder()
            }
        }
    }
}
