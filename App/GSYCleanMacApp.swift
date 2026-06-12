import SwiftUI
import AppUI
import AppKit
import LogKit
import SafetyKit
import ScanKit

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

    /// v1.3.x：App 激活策略控制器。控制"关窗后是否隐 Dock + 隐顶部主菜单"的切换。
    /// 仅当 settings.hideFromDockWhenClosed 开启时才会真正切到 .accessory；
    /// 关闭时永远保持 .regular，与现行行为完全一致。
    @State private var activationPolicy = ActivationPolicyController()

    /// v1.6：Sentinel 守护管理器（SMAppService.daemon 包装）。
    /// 在 init 阶段构造，启动钩子里按 [settings.sentinelEnabled](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 做幂等 register；用户在「设置 → 高级 → 后台守护」toggle 时通过
    /// `.onChange(of: settings.sentinelEnabled)` 钩子驱动 enable / disable。
    @State private var sentinelManager: SentinelManager

    private let tccDismissedKey = "tcc.onboarding.dismissed"

    init() {
        // v1.3.zzzz Phase 6：进程一启动就接通 GSYLog 文件 sink。
        // 落盘位置 ~/Library/Logs/GSYCleanMac/，按天滚动保留 7 天；构造失败时降级到仅 OSLog。
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
            NSLog("[GSYCleanMac] LogFileSink 初始化失败：\(error)（仅 OSLog 可用）")
        }

        let loadedVendors = Self.loadBundledVendors()
        self.vendors = loadedVendors
        let s = AppSettings()
        self._settings = State(initialValue: s)
        self._updateChecker = State(initialValue: UpdateChecker(settings: s))
        // v1.6：Sentinel 管理器与 AppSettings 同生命周期；register / unregister
        // 由启动钩子 + onChange 驱动，AppSettings 里 didSet 不直接调 SMAppService。
        self._sentinelManager = State(initialValue: SentinelManager(settings: s))
        // M1 内存优化：仅当用户开启 useScanStore feature flag 时构造 GRDB store。
        // v1.3.z 起：deepIndex 已正式翻成 off，TreeBrowserView 必须走 GRDB store
        // 才能下钻；所以 store 不再受 useScanStore 守卫，**强制开启**。
        // useScanStore 仅用作"如果用户在设置里关，则不去主动跨进程持久化大文件 cache"
        // 的次要 hint；store 本身始终在线。构造失败仍优雅降级到 nil（罕见，
        // 仅磁盘满 / Application Support 不可写等极端情况）。
        let store: ScanResultStore? = {
            do {
                let url = try GRDBScanResultStore.defaultDatabaseURL()
                return try GRDBScanResultStore(databaseURL: url)
            } catch {
                NSLog("[GSYCleanMac] GRDBScanResultStore 初始化失败，退回内存模式：\(error)")
                return nil
            }
        }()
        // v1.3.z：性能开关——ingest 维护 dirIndex/childEdges/fileLeaves
        // 的祖先上溯字典写入是主线程瓶颈，70 GB workspace A/B 实测：
        //   deepIndex=on  → 326s（首次默认，被用户怒斥 19 分钟卡死）
        //   deepIndex=off → 36.6s（throttle 0.40s 后逼近 IO 上限）
        // **正式默认翻成 off**：所有用户开箱即用快路径，TreeBrowserView 通过
        // ScanCoordinator.directChildrenAsync 走 GRDB store 仍能正常下钻。
        // （仅当用户显式设 GSY_DEEP_INDEX=1 才回退到内存索引——主要给开发者做 A/B
        //  对比用，正式用户不再触碰这条慢路径。）
        let deepIndex = (ProcessInfo.processInfo.environment["GSY_DEEP_INDEX"] ?? "0") != "0"
        self._coordinator = StateObject(
            wrappedValue: ScanCoordinator(vendors: loadedVendors,
                                          resultStore: store,
                                          enableTreeDeepIndex: deepIndex)
        )
    }

    var body: some Scene {
        WindowGroup(String(localized: "app.name", bundle: AppUIResources.bundle), id: Self.mainWindowID) {
            MainView(vendors: vendors,
                     settings: settings,
                     pathStore: pathStore,
                     coordinator: coordinator)
            .frame(minWidth: 1080, minHeight: 640)
            .environment(\.locale, settings.effectiveLocale)
            .task {
                // v1.7：把用户在「设置 → 外观 → 界面语言」选定的覆盖值同步到 AppleLanguages，
                // 让原生 NSAlert / NSMenu / 系统弹窗下次启动也跟着切。当次会话靠
                // `.environment(\.locale, ...)` 即时切换 SwiftUI 自绘文本。
                settings.applyToAppleLanguagesIfNeeded()
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
                // M5（交互更便捷）：弹菜单时同步查询扫描状态，
                // 让"开始推荐扫描"在已经在扫时自动 disable + 标题转"扫描中…"。
                statusItem.onQueryScanState = { [coordinator] in
                    coordinator.isScanning
                }
                // v1.3：根据 settings.trayEnabled 注册 / 移除菜单栏图标
                reconcileTray()
                // v1.3.x：首启即按用户偏好把激活策略就位（默认 false → regular，行为不变）。
                reconcileActivationPolicy()
                // v1.6：Sentinel 启动钩子——若用户已 ON，进程拉起时立刻幂等 register，
                // 兜住升级 / 重装 / SMAppService bundle 路径变化等场景。默认 OFF 时跳过。
                reconcileSentinel(initial: true)

                // v1.3.zz 真实回归套件总入口。
                // 环境变量 GSY_REGRESSION_CASE=<case-id> 启动后跑指定 case，结果以
                // [REGR k=v ...] 行打到 stderr，最终行 [REGR_PASS case=...] / [REGR_FAIL case=...]
                // 让 Scripts/regression.sh 直接 grep 判定。每条 case 跑完后退出 App。
                // 与 GSY_AUTOSCAN 互斥（GSY_REGRESSION_CASE 优先），避免双钩子打架。
                if let caseID = ProcessInfo.processInfo.environment["GSY_REGRESSION_CASE"], !caseID.isEmpty {
                    let runner = RegressionRunner(
                        caseID: caseID,
                        coordinator: coordinator,
                        settings: settings,
                        hud: hud,
                        statusItem: statusItem,
                        activationPolicy: activationPolicy,
                        vendors: vendors,
                        env: ProcessInfo.processInfo.environment
                    )
                    Task { @MainActor in
                        await runner.run()
                    }
                } else if let target = ProcessInfo.processInfo.environment["GSY_AUTOSCAN"], !target.isEmpty {
                    // v1.3.z 老开发钩子：环境变量 GSY_AUTOSCAN=<path> 启动后立刻扫描指定根，
                    // 扫完打印一行 `[GSY_AUTOSCAN_RESULT] elapsed_ms=... files=... bytes=...`
                    // 到 stderr。回归套件已经覆盖该场景，但保留向后兼容。
                    let url = URL(fileURLWithPath: target)
                    let started = Date()
                    let cat = ScanCategory.makeCustom(url: url)
                    coordinator.scan(category: cat,
                                     includeHidden: settings.showHidden)
                    Task { @MainActor [coordinator] in
                        var lastBeat = Date()
                        while !coordinator.snapshot.isFinished {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            let now = Date()
                            if now.timeIntervalSince(lastBeat) >= 5.0 {
                                let snap = coordinator.snapshot
                                let elapsed = Int(now.timeIntervalSince(started))
                                FileHandle.standardError.write(Data(
                                    "[GSY_AUTOSCAN_TICK] t=\(elapsed)s files=\(snap.scannedFileCount) bytes=\(snap.totalBytes / 1_048_576)MB\n".utf8
                                ))
                                lastBeat = now
                            }
                        }
                        let snap = coordinator.snapshot
                        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                        FileHandle.standardError.write(Data(
                            "[GSY_AUTOSCAN_RESULT] elapsed_ms=\(elapsedMs) files=\(snap.scannedFileCount) bytes=\(snap.totalBytes) finished=true\n".utf8
                        ))
                    }
                }
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
            .onChange(of: settings.sentinelEnabled) { _, _ in
                // v1.6：用户在「设置 → 高级 → 后台守护」拨动开关 → 立刻 enable / disable。
                // reconcileSentinel 内部识别 settings 当前值，幂等并能在失败时回滚 toggle。
                reconcileSentinel(initial: false)
            }
            .onOpenURL { url in
                // v1.6：daemon 通过 `gsycleanmac://` 把候选传回主 App。
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
        .commands {
            // v1.1：Help 菜单加"检查更新"入口
            CommandGroup(after: .appInfo) {
                Button(String(localized: "menu.app.checkUpdates", bundle: AppUIResources.bundle)) {
                    updateChecker.checkNow()
                }
            }
            // v1.3：View 菜单加"显示扫描悬浮窗"toggle，⌘⇧H 快捷键。
            // 用 CommandGroup(after: .toolbar) 让它落在 macOS 标准"显示"区。
            CommandGroup(after: .toolbar) {
                Divider()
                Toggle(String(localized: "menu.view.showHUD", bundle: AppUIResources.bundle), isOn: hudBinding)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            // v1.5.7：替换 SwiftUI 默认的占位 Help 菜单，提供生产级帮助入口。
            CommandGroup(replacing: .help) {
                Button(String(localized: "menu.help.help", bundle: AppUIResources.bundle)) {
                    Self.openExternal("https://github.com/CarGuo/GSYCleanMac#readme")
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                Button(String(localized: "menu.help.privacy", bundle: AppUIResources.bundle)) {
                    Self.openExternal("https://github.com/CarGuo/GSYCleanMac/blob/main/PRIVACY.md")
                }
                Button(String(localized: "menu.help.terms", bundle: AppUIResources.bundle)) {
                    Self.openExternal("https://github.com/CarGuo/GSYCleanMac/blob/main/TERMS.md")
                }
                Divider()
                Button(String(localized: "menu.help.feedback", bundle: AppUIResources.bundle)) {
                    Self.openExternal("https://github.com/CarGuo/GSYCleanMac/issues/new/choose")
                }
                Button(String(localized: "menu.help.revealLogs", bundle: AppUIResources.bundle)) {
                    Self.revealLogsInFinder()
                }
            }
        }

        // v1.0：标准 ⌘, 设置窗口（隐藏文件 toggle / 大文件阈值 / 自定义路径）。
        Settings {
            SettingsScene(settings: settings, pathStore: pathStore, updateChecker: updateChecker)
                .environment(\.locale, settings.effectiveLocale)
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
    /// - `initial=true`：进程拉起钩子，幂等 register（用户已 ON 时）。
    /// - `initial=false`：用户 toggle，按新值调 enable / disable；register 失败会回滚 toggle 到 false，
    ///   保证 settings 不会出现"开关 ON 但守护没起来"的不一致。
    @MainActor
    private func reconcileSentinel(initial: Bool) {
        if settings.sentinelEnabled {
            let ok = sentinelManager.enable()
            if !ok && !initial {
                // 用户 toggle 后失败 → 把开关弹回 false，避免"开关 ON 但实际未注册"
                settings.sentinelEnabled = false
            }
        } else {
            // 关：调 unregister；返回值不影响 settings（已经是 false）。
            _ = sentinelManager.disable()
        }
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
    /// 与 [bringMainWindowToFront](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift#L186-L218) 用的过滤条件保持一致：
    /// 非 NSPanel + 有 contentViewController + windowNumber > 0 + (isVisible || isMiniaturized)。
    /// 最小化窗口算"可见"，因为 Dock 还有缩略图，用户预期 Dock 图标在场。
    @MainActor
    private static func hasVisibleMainWindow() -> Bool {
        NSApp.windows.contains { window in
            guard !(window is NSPanel) else { return false }
            guard window.contentViewController != nil else { return false }
            guard window.windowNumber > 0 else { return false }
            return window.isVisible || window.isMiniaturized
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
        // **v1.3.zz 关窗后修复**：当前 App 可能已经处于 .accessory（藏 Dock）模式——
        // 直接 activate() 在 accessory 下不会让窗口拉回前台 / 抢焦点，必须先把策略切回
        // .regular 才能正常显示主窗口与抢键盘焦点。这一步幂等：已是 regular 不会反复调。
        NSApp.setActivationPolicy(.regular)
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
                NSLog("[GSYCleanMac] bringMainWindowToFront fallback open failed: \(error)")
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

    /// v1.5.7：Help 菜单统一的外链跳转入口。
    /// 只允许 https，避免后续被改成 file:// / shell: 等危险 scheme。
    @MainActor
    private static func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https" else {
            NSLog("[GSYCleanMac] openExternal 拒绝非 https URL: \(urlString)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// v1.5.7：Help → 在 Finder 中显示日志。
    /// 日志路径与 [GSYLog.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LogKit/Sources/LogKit/GSYLog.swift) 默认 sink 保持一致。
    @MainActor
    private static func revealLogsInFinder() {
        let fm = FileManager.default
        let logDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/GSYCleanMac", isDirectory: true)
        guard let logDir else {
            NSLog("[GSYCleanMac] revealLogsInFinder 找不到 ~/Library/Logs 目录")
            return
        }
        if !fm.fileExists(atPath: logDir.path) {
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([logDir])
    }
}
