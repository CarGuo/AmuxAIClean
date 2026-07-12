import SwiftUI
import AppKit
import Combine
import ScanKit

/// v1.3：扫描悬浮窗（HUD），可作"扫描态浮窗" / "桌面挂件" / "灵动岛"。
///
/// 产品需求（用户原话）：
/// 「就是多少可用，多少可清理，比例多少 / 有颜色，能体现，能让我一目了然，还不会被遮挡」
/// 「不只是扫描，我希望我可以一直存在，甚至作为桌面小控件」
/// 「可以，就是类似他的，有动画，有小窗口和大小窗口效果」（参考 vibe-island）
///
/// **灵动岛模式实现要点**（参考 [open-vibe-island](https://github.com/Octane0411/open-vibe-island)）：
/// 1. **`screen.safeAreaInsets.top > 0`** 检测刘海屏；`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
///    一减就是真实刘海宽度（macOS 12+ 公开 API）。
/// 2. **`panel.level = .statusBar`** + **`screen.frame.maxY - height`**（不是 visibleFrame！）—
///    才能盖在菜单栏 / 刘海所在那一行像素之上。我们之前 `.floating` 永远做不到。
/// 3. **panel 始终用展开态最大尺寸**，收起态靠 SwiftUI 内部 `.frame(width:height:)` + spring 动画，
///    不反复 setFrame，避免闪烁、避免和 SwiftUI 动画时序打架。
/// 4. **凹角顶圆底**形状（`NotchShape`）：展开时和物理刘海无缝拼接，看上去像"刘海长出来"。
///    收起态用平顶圆底（`PillShape`），整个 HUD 视觉等同灵动岛。
/// 5. **hover 0.15s 展开 / 离开 0.3s 收起**，全局 + 本地双 NSEvent monitor，throttle 50ms。
@MainActor
public final class FloatingScanHUDController {

    private var panel: NSPanel?
    private weak var coordinator: ScanCoordinator?
    private weak var smartCareSession: SmartCareSession?
    private weak var settings: AppSettings?

    #if DEBUG
    /// 仅 DEBUG 暴露：HUD panel 是否当前可见（panel 存在且 isVisible=true）。
    /// 供 [App/RegressionRunner.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift)
    /// 等真实回归测试断言用，不影响生产路径。
    ///
    /// 注：原本只在 DEBUG 暴露，但 [RegressionRunner](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift)
    /// 在 Release 构建里也参与编译（它由 main App target 引入），导致 release.yml 的
    /// `xcodebuild -configuration Release` 会因找不到该成员而 BUILD FAILED。属性本身只读、
    /// 零副作用，所以撤掉 `#if DEBUG`，保留注释提醒生产代码勿依赖。
    public var isPanelVisibleForTesting: Bool { panel?.isVisible == true }
    #else
    /// Release 构建同样需要这个 stub（理由见 DEBUG 分支）；只读、零副作用，安全。
    public var isPanelVisibleForTesting: Bool { panel?.isVisible == true }
    #endif

    /// 当前 panel 创建时使用的 placement。变化时需要 rebuild panel（level 不能动态切，
    /// `kCGDesktopIconWindowLevel` 这种 raw level 在已有 panel 上 setLevel 偶发卡死）。
    private var lastPlacement: AppSettings.HUDPlacement?

    /// v1.3：灵动岛展开/收起状态。@Published 风格的简单 box，给 SwiftUI 用。
    private let islandState = IslandHoverState()

    /// 全局/本地 mouse-moved 事件监视器（仅在 dynamicIsland 模式下激活）。
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverOpenTimer: DispatchWorkItem?
    private var hoverCloseTimer: DispatchWorkItem?
    private var lastMouseMoveAt: TimeInterval = 0

    /// 收起态整条胶囊 hit-rect（屏幕坐标）——内容驱动宽度，居中对齐刘海，
    /// size 来自 islandState.leftPillSize（SwiftUI 测出整条 strip 的真实总尺寸）。
    private var closedStripHitRect: NSRect = .zero
    /// 展开态 hit-rect（屏幕坐标）——内容驱动高度，从 islandState.expandedSize 算出。
    private var expandedHitRect: NSRect = .zero

    /// v1.3：点击 HUD 的"打开主窗口"按钮会回调到这里。由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 注入：调 NSApp.activate + makeKeyAndOrderFront 把主窗口拉回前。
    public var onOpenMainWindow: (() -> Void)?

    /// v1.3：闲置态点击"立即扫描"回调。由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 注入：调 [ScanCoordinator.scanRecommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)。
    public var onStartScan: (() -> Void)?

    /// 强制显示（用户在 toolbar 点了"显示扫描悬浮窗"），与 isScanning / hudPersistent 是 OR 关系。
    public var forceVisible: Bool = false {
        didSet { reconcile() }
    }

    public init() {
        // SwiftUI 视图测量出新 size 后回写 islandState → Combine 触发 panel frame + hit-rect 重算。
        // panel 永远是展开尺寸（vibe-island 模式），所以这里只需重算 hit-rect 与 mouse-pass-through。
        islandStateSubs.append(islandState.$leftPillSize.sink { [weak self] _ in self?.refreshIslandHitRects() })
        islandStateSubs.append(islandState.$rightPillSize.sink { [weak self] _ in self?.refreshIslandHitRects() })
        islandStateSubs.append(islandState.$expandedSize.sink { [weak self] _ in self?.refreshIslandHitRects() })
        islandStateSubs.append(islandState.$expanded.sink { [weak self] expanded in
            // expanded 翻转 → 切 mouse-pass-through：收起态 panel 鼠标穿透，展开态可交互
            DispatchQueue.main.async {
                self?.refreshIslandHitRects()
                self?.applyIslandInteractive(expanded)
            }
        })
    }

    /// 切 panel 的 mouse-pass-through——收起态 panel 透传，展开态接管鼠标。
    /// 关键：不会再撕裂动画——panel 尺寸不变，只切 ignoresMouseEvents。
    private func applyIslandInteractive(_ interactive: Bool) {
        guard settings?.hudPlacement == .dynamicIsland, let panel else { return }
        panel.ignoresMouseEvents = !interactive
        panel.acceptsMouseMovedEvents = interactive
    }

    /// Combine 订阅持有；@MainActor class 不会泄漏。
    private var islandStateSubs: [AnyCancellable] = []

    /// SwiftUI 测量回调触发：**同时重画 panel frame 和 hit-rect**——
    /// panel 现在只占当前显示态实际区域（收起=strip 大小、展开=expanded 大小）。
    private func refreshIslandHitRects() {
        guard settings?.hudPlacement == .dynamicIsland,
              let panel,
              let screen = resolveTargetScreen(for: .dynamicIsland) else { return }
        let newSize = panelSize(for: .dynamicIsland)
        let newFrame = panelFrame(size: newSize, on: screen, placement: .dynamicIsland)
        if panel.frame != newFrame {
            panel.setFrame(newFrame, display: true)
        }
        updateIslandHitRects(panelFrame: newFrame, placement: .dynamicIsland, screen: screen)
    }

    public func attach(coordinator: ScanCoordinator,
                       settings: AppSettings,
                       smartCareSession: SmartCareSession? = nil) {
        self.coordinator = coordinator
        self.settings = settings
        self.smartCareSession = smartCareSession
        reconcile()
    }

    /// 由 SwiftUI onChange 在 isScanning / hudEnabled / hudPersistent / hudPlacement 变化时调用。
    public func reconcile() {
        guard let coordinator, let settings else { return }
        let baseVisible = settings.hudEnabled && (
            coordinator.isScanning
                || smartCareSession?.isBusy == true
                || forceVisible
                || settings.hudPersistent
        )

        // placement 改了 → rebuild panel（level / collectionBehavior 都需要重设）
        if let panel, lastPlacement != settings.hudPlacement {
            stopMouseMonitors()
            panel.orderOut(nil)
            self.panel = nil
        }

        if baseVisible {
            ensurePanel()
            // 桌面层级不要 orderFrontRegardless（会短暂遮挡前台 App），用 orderBack
            // —— 它其实是 set level 之后排在该 level 内的"前面"，对桌面级足够了
            if settings.hudPlacement.isDesktopLevel {
                panel?.orderBack(nil)
            } else {
                panel?.orderFrontRegardless()
            }
            // 灵动岛模式：每次 reconcile 都重新对齐到当前刘海屏，
            // 处理多屏插拔 / 屏分辨率变化 / 用户把 Mac 合上换外接屏 等场景。
            if settings.hudPlacement == .dynamicIsland, let panel = self.panel {
                if let screen = resolveTargetScreen(for: .dynamicIsland) {
                    let size = panelSize(for: .dynamicIsland)
                    let frame = panelFrame(size: size, on: screen, placement: .dynamicIsland)
                    if panel.frame != frame {
                        panel.setFrame(frame, display: false)
                    }
                    updateIslandHitRects(panelFrame: frame, placement: .dynamicIsland, screen: screen)
                }
                // 二次保险：再设一次 level，防止 SwiftUI host 创建过程中被某些路径打回 .floating
                panel.level = .statusBar
            }
            // 灵动岛模式启动鼠标监听以 hover 展开
            if settings.hudPlacement == .dynamicIsland {
                startMouseMonitors()
            } else {
                stopMouseMonitors()
            }
        } else {
            stopMouseMonitors()
            // 扫描结束延后 0.8s 关闭，给用户时间看到"可清理 +X GB"的最终态
            let panel = self.panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                guard let coord = self.coordinator, let s = self.settings else { return }
                let stillVisible = s.hudEnabled && (
                    coord.isScanning
                        || self.smartCareSession?.isBusy == true
                        || self.forceVisible
                        || s.hudPersistent
                )
                if !stillVisible {
                    panel?.orderOut(nil)
                }
            }
        }
    }

    public func toggleForceVisible() {
        forceVisible.toggle()
    }

    // MARK: - Panel 创建

    private func ensurePanel() {
        if panel != nil { return }
        guard let coordinator, let settings else { return }

        let placement = settings.hudPlacement
        let panelSize = panelSize(for: placement)

        let view = FloatingScanHUDView(
            coordinator: coordinator,
            smartCareSession: smartCareSession,
            settings: settings,
            islandState: islandState,
            placement: placement,
            onOpen: { [weak self] in
                self?.onOpenMainWindow?()
            },
            onStartScan: { [weak self] in
                self?.onStartScan?()
            },
            onClose: { [weak self] in
                guard let self else { return }
                // 常驻模式下"X"按钮的语义是"关掉常驻"，否则会立刻被 reconcile 重新弹回
                self.settings?.hudPersistent = false
                self.forceVisible = false
                self.panel?.orderOut(nil)
            }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // isFloatingPanel=true 在 macOS 14+ 上会把 level 强制夹回 .floating，
        // 灵动岛模式必须设为 false 才能保住 .statusBar level。
        panel.isFloatingPanel = (placement != .dynamicIsland)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = (placement != .dynamicIsland)
        panel.hasShadow = (placement != .dynamicIsland)   // 灵动岛自己画 shadow，避免 panel shadow 把刘海映出来
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.contentView = host

        // 根据 placement 决定 level / collectionBehavior。
        if placement.isDesktopLevel {
            // 桌面级：在桌面图标之上、所有 App 窗口之下。kCGDesktopIconWindowLevel + 1
            // 是 GeekTool / Übersicht / iStat Menus 桌面挂件用的层级。
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else if placement.isStatusBarLevel {
            // 灵动岛：用 statusBar 级，能盖在菜单栏 / 刘海行像素之上。
            // open-vibe-island / Vibe Island / NotchNook / NotchDrop 都是这个级。
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            // panel 永远是展开态最大尺寸（vibe-island 同款），但**默认 mouse-pass-through**，
            // 由 NSEvent 全局监视器识别 hover 进入 closedStripHitRect → 展开后再翻为可交互。
            // 这样既不拦截屏幕其它区域的点击，又能让形变动画连续不撕裂。
            panel.ignoresMouseEvents = true
            panel.acceptsMouseMovedEvents = false
        } else {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }

        // 计算 frame。
        if let screen = resolveTargetScreen(for: placement) {
            let frame = panelFrame(size: panelSize, on: screen, placement: placement)
            panel.setFrame(frame, display: false)
            updateIslandHitRects(panelFrame: frame, placement: placement, screen: screen)
        }
        self.panel = panel
        self.lastPlacement = placement
    }

    /// 根据 placement 选目标屏：灵动岛优先选刘海屏，找不到走 main 屏。
    private func resolveTargetScreen(for placement: AppSettings.HUDPlacement) -> NSScreen? {
        if placement == .dynamicIsland {
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return notched
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// panel 尺寸——灵动岛 panel **永远等于展开态最大尺寸**（vibe-island 同款做法）。
    /// 关键：panel 不跟随 isExpanded 变 → SwiftUI 内部 spring 期间 panel 不会"先到位裁掉视图"，
    /// 形变看起来才是连续的"一团黑色呼吸"，而不是两块 view 在不同尺寸 panel 里硬切。
    /// 收起态视觉小胶囊靠**内容形状自己**收成 strip 大小，panel 多出来的区域由透明 host 接住，
    /// 鼠标命中由 [closedStripHitRect](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift#L46) / [expandedHitRect](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift#L48) 单独控（不靠 panel.frame）。
    private func panelSize(for placement: AppSettings.HUDPlacement) -> NSSize {
        switch placement {
        case .dynamicIsland:
            let screen = resolveTargetScreen(for: .dynamicIsland) ?? NSScreen.main
            let notchH = (screen?.notchSize.height ?? 32)
            // panel 永远是展开态尺寸（含一些 margin 容纳 shadow）
            let expSize = islandState.expandedSize
            let w: CGFloat = expSize.width > 0 ? expSize.width : 540
            let h: CGFloat = expSize.height > 0 ? expSize.height : (notchH + 260)
            // 横向 +24 留 shadow 余量，纵向 +12 同理
            return NSSize(width: w + 24, height: h + 12)
        default:
            return NSSize(width: 320, height: 112)
        }
    }

    /// panel 屏幕位置。灵动岛居中对齐 `screen.midX`（与物理刘海几何中心对齐），贴 `frame.maxY`。
    private func panelFrame(size: NSSize, on screen: NSScreen, placement: AppSettings.HUDPlacement) -> NSRect {
        switch placement {
        case .dynamicIsland:
            return NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .notchUnder:
            let visible = screen.visibleFrame
            return NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 8,
                width: size.width,
                height: size.height
            )
        case .desktopTopRight:
            let visible = screen.visibleFrame
            let m: CGFloat = 16
            return NSRect(x: visible.maxX - size.width - m, y: visible.maxY - size.height - m,
                          width: size.width, height: size.height)
        case .desktopBottomRight:
            let visible = screen.visibleFrame
            let m: CGFloat = 16
            return NSRect(x: visible.maxX - size.width - m, y: visible.minY + m,
                          width: size.width, height: size.height)
        case .desktopBottomLeft:
            let visible = screen.visibleFrame
            let m: CGFloat = 16
            return NSRect(x: visible.minX + m, y: visible.minY + m,
                          width: size.width, height: size.height)
        }
    }

    // MARK: - 灵动岛 hover 监控

    private func updateIslandHitRects(panelFrame: NSRect, placement: AppSettings.HUDPlacement, screen: NSScreen) {
        guard placement == .dynamicIsland else {
            closedStripHitRect = .zero
            expandedHitRect = .zero
            return
        }
        // panel 现在永远是展开尺寸；hit-rect 必须基于"形状实际占用的屏幕区域"算，
        // 而不是 panel.frame——否则鼠标移到 panel 内但形状外（收起态左右下方空白）会误触发 hover。
        let notchH = screen.notchSize.height
        let notchW = screen.notchSize.width

        // 收起 strip 实际占用的区域
        let stripSize = islandState.leftPillSize
        let stripW: CGFloat = stripSize.width > 0 ? stripSize.width : (notchW + 280)
        let stripH: CGFloat = max(stripSize.height, max(notchH, 28))
        closedStripHitRect = NSRect(
            x: screen.frame.midX - stripW / 2,
            y: screen.frame.maxY - stripH,
            width: stripW,
            height: stripH
        )

        // 展开 island 实际占用的区域
        let expSize = islandState.expandedSize
        let expW: CGFloat = expSize.width > 0 ? expSize.width : 540
        let expH: CGFloat = expSize.height > 0 ? expSize.height : (notchH + 260)
        expandedHitRect = NSRect(
            x: screen.frame.midX - expW / 2,
            y: screen.frame.maxY - expH,
            width: expW,
            height: expH
        )
    }

    private func startMouseMonitors() {
        if globalMouseMonitor != nil { return }

        // global：监听其它 App 内的鼠标移动
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(location)
            }
        }
        // local：监听 panel 自己内部的 mouse-moved
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(location)
            }
            return event
        }
    }

    private func stopMouseMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        hoverOpenTimer?.cancel(); hoverOpenTimer = nil
        hoverCloseTimer?.cancel(); hoverCloseTimer = nil
        islandState.expanded = false
    }

    private func handleMouseMoved(_ location: NSPoint) {
        guard settings?.hudPlacement == .dynamicIsland else { return }

        let inClosed = closedStripHitRect.contains(location)
        let inExpanded = expandedHitRect.contains(location)

        // 50ms throttle 控 hover open/close timer（避免高频更新）
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMouseMoveAt < 0.05 { return }
        lastMouseMoveAt = now

        if islandState.expanded {
            // 已展开：鼠标离开展开区 → 0.3s 后收起
            if !inExpanded {
                scheduleClose()
            } else {
                cancelClose()
            }
        } else {
            // 已收起：鼠标进入收起区 → 0.15s 后展开
            if inClosed {
                scheduleOpen()
            } else {
                cancelOpen()
            }
        }
    }

    private func scheduleOpen() {
        if hoverOpenTimer != nil { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 注意：spring transaction 由 SwiftUI 视图层 onChange(of:) 里的 withAnimation 负责
            // 包裹（@State 改值才能正确捕获 transaction），controller 这里只是触发 publisher
            self.islandState.expanded = true
            self.hoverOpenTimer = nil
        }
        hoverOpenTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
    private func cancelOpen() {
        hoverOpenTimer?.cancel(); hoverOpenTimer = nil
    }
    private func scheduleClose() {
        if hoverCloseTimer != nil { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.islandState.expanded = false
            self.hoverCloseTimer = nil
        }
        hoverCloseTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    private func cancelClose() {
        hoverCloseTimer?.cancel(); hoverCloseTimer = nil
    }

}

// MARK: - IslandHoverState

/// 调试开关——慢动作 + 自动循环 + 帧抓取触发。
/// 用环境变量启用：`GSY_ISLAND_DEBUG=1` 慢速；`GSY_ISLAND_AUTOLOOP=1` 周期性自动展开/收起。
enum IslandDebug {
    static let slowMotion: Bool = {
        ProcessInfo.processInfo.environment["GSY_ISLAND_DEBUG"] == "1"
    }()
    static let autoLoop: Bool = {
        ProcessInfo.processInfo.environment["GSY_ISLAND_AUTOLOOP"] == "1"
    }()
}

/// 灵动岛展开/收起状态的 ObservableObject。
/// Controller 改它，SwiftUI 视图 @ObservedObject 订阅，动画自动跑。
@MainActor
final class IslandHoverState: ObservableObject {
    @Published var expanded: Bool = false
    /// SwiftUI 测量出的左胶囊实际 size（内容驱动宽度 → Controller 用来算 hit-rect）
    @Published var leftPillSize: CGSize = .zero
    /// SwiftUI 测量出的右胶囊实际 size
    @Published var rightPillSize: CGSize = .zero
    /// SwiftUI 测量出的展开态卡片实际 size（内容驱动高度）
    @Published var expandedSize: CGSize = .zero
    /// v1.3 review-fix（对称化）：左/右两个 hero 簇的"较长一侧"自然宽度。
    /// `closedStripLayout` 把短簇 frame 到这个宽度，让左右严格对称且整体宽度随长簇 ×2 动态变化。
    /// 0 时表示尚未测量到，layout 退回 `.fixedSize` 自然布局，避免首帧塌缩。
    @Published var clusterMaxWidth: CGFloat = 0
}

/// SwiftUI PreferenceKey：把子视图实际渲染出的 size 报到父级。
/// Swift 6 严格并发：`defaultValue` 用 `let` 不可变（每次返回都是新的空字典字面量是常数 immutable）。
struct IslandSizePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

/// v1.3 review-fix（对称化）：上报左/右 hero 簇的自然宽度。
/// reduce 取 max——左右一起喂同一个 key，最终 value 就是两簇较长那个的宽度。
struct IslandClusterWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - NSScreen 刘海几何（参考 open-vibe-island）

extension NSScreen {
    /// 没刘海时模拟用的"假刘海"宽 / 高，让灵动岛在外接屏 / 老 Mac 上也有同样视觉。
    static let externalDisplayNotchWidth: CGFloat = 190
    static let externalDisplayNotchHeight: CGFloat = 38

    /// 当前屏幕的刘海尺寸（macOS 12+ 公开 API）。
    /// - 有刘海：宽 = `frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width + 4`
    ///            高 = `safeAreaInsets.top`
    /// - 无刘海：fallback 到 190×38（视觉上像 MacBook Pro 14/16 的刘海）
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else {
            return CGSize(
                width: Self.externalDisplayNotchWidth,
                height: Self.externalDisplayNotchHeight
            )
        }
        let notchHeight = safeAreaInsets.top
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        // +4 让胶囊比真实刘海宽一点，覆盖刘海描边走样
        let notchWidth = max(180, frame.width - leftPadding - rightPadding + 4)
        return CGSize(width: notchWidth, height: notchHeight)
    }

    /// 是否物理刘海屏。
    var hasPhysicalNotch: Bool { safeAreaInsets.top > 0 }
}

// MARK: - 灵动岛形状与小部件

/// 持续呼吸的小圆点（扫描中状态指示器）。
/// 参考 open-vibe-island 的 waiting 态 0.35 ↔ 1 opacity 脉冲。
struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var pulsing: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing ? 1.0 : 0.45)
            .scaleEffect(pulsing ? 1.0 : 0.85)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// 收起态：平顶半圆底（V6ClosedPillShape 同款）。
/// 顶边贴屏幕物理顶（盖在刘海行那 38pt 上），底部圆弧让胶囊和刘海无缝拼接。
struct IslandClosedShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// 展开态：凹角顶 + 圆底（NotchShape 同款，参考 open-vibe-island）。
/// 顶部两个角向内凹（concave 二次贝塞尔曲线），让胶囊和物理刘海拼接处看起来"长出来"。
struct IslandExpandedShape: Shape {
    var topRadius: CGFloat = 12
    var bottomRadius: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let topR = min(topRadius, rect.width / 4, rect.height / 4)
        let botR = min(bottomRadius, rect.width / 4, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// 单一连续形变体——灵动岛"呼吸"形状（收起↔展开同一块形状插值）。
///
/// **真机刘海的几何参考**（用户实拍特写）：
/// 屏幕顶部 menu bar 黑色横条 → 刘海中央向下凸出，
/// 刘海**两侧顶部**与 menu bar 衔接处有**反向凹弧**：
///   - 屏幕顶部水平边碰到刘海竖直边时，**不是直角**衔接
///   - 而是用一段反向凹弧（凹向刘海外侧）切入：水平顶边 → 凹弧 → 进入竖直边
///   - 凹弧让"刘海"看起来像是从顶部 menu bar **柔和地延伸**出来，而不是硬切
///
/// 由于灵动岛 panel 是浮窗（不是真正的屏幕物理刘海），
/// 我们**模拟**这个效果：让 path **顶部贴满整个 rect 宽度**（与屏幕顶部齐平），
/// 然后从顶沿两端用**反向凹弧**切入到稍窄的"主体"竖直边，
/// 主体下方用**普通外凸圆角**收尾（柔和的圆角底）。
///
/// 形状走向（视觉顺时针）：
///   顶沿全宽 → 右上反向凹弧（外凸切入）→ 右侧主体竖直边 → 右下外凸圆角 →
///   底沿水平 → 左下外凸圆角 → 左侧主体竖直边 → 左上反向凹弧 → 闭合
struct IslandUnifiedShape: Shape {
    /// 形状主体（凹弧之下）的圆角半径（即下沿两端外凸圆角）
    var bottomCornerRadius: CGFloat
    /// 顶部两端反向凹弧（concave）的半径——让胶囊和顶部 menu bar 衔接处呈现"刘海长出来"的拼接感
    var topConcaveRadius: CGFloat = 10

    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // 底部两端外凸圆角半径
        let br: CGFloat = max(0, min(bottomCornerRadius, rect.width / 2, rect.height / 2))
        // 顶部两端反向凹弧半径——不能超过主体高度的一半，也不能让两侧凹弧相撞
        let tr: CGFloat = max(0, min(topConcaveRadius, rect.height / 2, (rect.width - 2 * br) / 2))

        var path = Path()

        // 顶沿：从左上凹弧的"凹入起点"开始，水平到右上凹弧的"凹入起点"
        // 顶沿与屏幕顶部 menu bar 齐平（rect.minY），整段顶沿宽度 = rect.width - 2 * tr 的两端凹弧外侧
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // 右上反向凹弧：从顶沿水平方向"凹入"切到主体右侧竖直边
        // 控制点放在 (maxX, minY + tr) —— 让弧线先"水平延伸"再"竖直进入"，呈现 concave 拼接
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        // 右侧主体竖直边
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br))

        // 右下外凸圆角
        path.addArc(
            center: CGPoint(x: rect.maxX - tr - br, y: rect.maxY - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // 底沿
        path.addLine(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY))

        // 左下外凸圆角
        path.addArc(
            center: CGPoint(x: rect.minX + tr + br, y: rect.maxY - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // 左侧主体竖直边
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr))

        // 左上反向凹弧：从主体左侧竖直边"凹出"切回顶沿水平方向
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - 主视图

/// HUD 视图：根据 placement / islandState 在 4 种形态间切换。
/// - 普通模式（notchUnder / desktop*）：原 v1.3 卡片
/// - 灵动岛模式（dynamicIsland）：收起 = 贴刘海胶囊；展开 = 凹顶大窗
struct FloatingScanHUDView: View {
    @ObservedObject var coordinator: ScanCoordinator
    let smartCareSession: SmartCareSession?
    @Bindable var settings: AppSettings
    @ObservedObject var islandState: IslandHoverState
    let placement: AppSettings.HUDPlacement
    let onOpen: () -> Void
    let onStartScan: () -> Void
    let onClose: () -> Void

    /// 状态切档时的"啵"一下脉冲动画（扫描态切换、severity 跳档触发）。
    @State private var isPopping: Bool = false

    /// **本地化**的展开状态——镜像 `islandState.expanded`，但通过 view 内 @State + withAnimation
    /// 才能让 SwiftUI 在 body 重新求值时携带 spring transaction，让 frame / matchedGeometryEffect /
    /// 字号 / addon transition 真正进入插值（@ObservedObject 自动触发的 invalidation **不带** transaction）。
    @State private var isExpandedState: Bool = false

    /// Hero 动画 namespace——让收起态/展开态里的相同元素（图标、主标题、关键数字）
    /// 在切换时**飞越**到新位置，而不是淡入淡出。
    /// 这就是 SwiftUI 等价于 Flutter Hero / AnimatedContainer 的实现。
    @Namespace private var islandHeroNS
    /// probe 测量层独立 namespace——避免 probe 的 matchedGeometryEffect 和主层冲突。
    /// 收起态/展开态 probe 也必须拆开，否则同一个 probe namespace 内会同时插入两套
    /// `isSource: true` 的 hero 元素，SwiftUI 会报 multiple inserted views。
    @Namespace private var islandStripProbeNS
    @Namespace private var islandExpandedProbeNS

    init(coordinator: ScanCoordinator,
         smartCareSession: SmartCareSession? = nil,
         settings: AppSettings,
         islandState: IslandHoverState,
         placement: AppSettings.HUDPlacement,
         onOpen: @escaping () -> Void,
         onStartScan: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.smartCareSession = smartCareSession
        self.settings = settings
        self.islandState = islandState
        self.placement = placement
        self.onOpen = onOpen
        self.onStartScan = onStartScan
        self.onClose = onClose
    }

    /// 总容量；优先用 coordinator.volumeSnapshot（系统真实磁盘），缺失时按已扫总和兜底（避免 0 除）。
    private var totalBytes: Int64 {
        coordinator.volumeSnapshot?.totalBytes ?? max(coordinator.snapshot.totalBytes, 1)
    }

    private var availableBytes: Int64 {
        coordinator.volumeSnapshot?.availableBytes ?? 0
    }

    /// 可清理 = 当前 snapshot 中 verdict==.safe 的字节合计。
    ///
    /// v1.6 / 2026-06：本地 reduce 已下沉到 [ScanSnapshot.cleanableBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L389-L394)
    /// 作为**全项目可清理口径单一源**，与 sidebar 的 [VolumeCapacityCard](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/VolumeCapacityCard.swift) 同源，
    /// 杜绝主窗 / HUD 两条口径漂移。
    private var cleanableBytes: Int64 {
        if let smartCareSession {
            switch smartCareSession.care.phase {
            case .scanning(let progress):
                return progress.safeBytes
            case .cleaning:
                return smartCareSession.care.selectedBytes
            case .reviewing, .confirming, .completed:
                if !coordinator.isScanning {
                    return smartCareSession.care.selectedBytes
                }
            case .idle, .failed, .cancelled:
                break
            }
        }
        return coordinator.snapshot.cleanableBytes
    }

    private var smartCareIsActive: Bool {
        guard let smartCareSession else { return false }
        switch smartCareSession.care.phase {
        case .scanning, .cleaning: return true
        case .idle, .reviewing, .confirming, .completed, .failed, .cancelled: return false
        }
    }

    private var smartCareIsCleaning: Bool {
        guard let smartCareSession else { return false }
        if case .cleaning = smartCareSession.care.phase { return true }
        return false
    }

    /// v1.3：HUD 当前的语义状态。
    enum HUDPhase {
        case scanning
        case finished
        case idle
    }
    private var phase: HUDPhase {
        if smartCareIsActive { return .scanning }
        if coordinator.isScanning { return .scanning }
        if let smartCareSession,
           !smartCareSession.care.summary.items.isEmpty {
            switch smartCareSession.care.phase {
            case .reviewing, .confirming, .completed: return .finished
            case .idle, .scanning, .cleaning, .failed, .cancelled: break
            }
        }
        // v1.3.aa：扫描完成后如果"可清理"已经低到 .idle 档（< 50 MB），
        // 用户原话：「没任务和不用操作，应该回归常态默认那个显示」——
        // 不再显示"无需清理"这种 finished 文案，整体退化成 idle，
        // 与 App 启动未扫描时的初始磁盘状态显示一致（左：磁盘紧张/空闲；右：可用空间）。
        if coordinator.snapshot.isFinished {
            if CleanableSeverity.forCleanableBytes(cleanableBytes) == .idle {
                return .idle
            }
            return .finished
        }
        return .idle
    }

    // MARK: - v1.3.x：派生数据 / 严重度

    /// 卷"已用"字节（系统真实）。volumeSnapshot 缺失时按已扫总和兜底。
    private var usedBytes: Int64 {
        if let s = coordinator.volumeSnapshot {
            return max(0, s.totalBytes - s.availableBytes)
        }
        return coordinator.snapshot.totalBytes
    }
    /// "其它已用" = 已用 - 可清理（钳到 [0, used]，避免极端跨卷文件 cleanable > used）。
    private var otherUsedBytes: Int64 {
        let cleanable = max(0, min(cleanableBytes, usedBytes))
        return max(0, usedBytes - cleanable)
    }
    /// 已用占比 [0, 1]。
    private var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(usedBytes) / Double(totalBytes))
    }
    /// 可清理严重度——按 10G/3G/500M 阈值梯度，主 App 与灵动岛共用。
    private var cleanableSeverity: CleanableSeverity {
        CleanableSeverity.forCleanableBytes(cleanableBytes)
    }
    /// 磁盘已用占比严重度——闲置态用来提示"磁盘紧张"。
    private var diskSeverity: CleanableSeverity {
        CleanableSeverity.forDiskUsedRatio(usedRatio)
    }
    /// 可用空间严重度——主 App 与 HUD 的"可用"段着色（绿/黄/橙/红）。
    private var availableSeverity: CleanableSeverity {
        CleanableSeverity.forAvailableBytes(availableBytes)
    }
    /// 卷名（"Macintosh HD" 等），缺失时显示"本机磁盘"。
    private var volumeName: String {
        coordinator.volumeSnapshot?.volumeName ?? String(localized: "hud.volume.default", bundle: .module)
    }
    /// 速度文案——"2.4 MB/s"，速率不足时显示"估算中…"。
    private var speedText: String {
        let bps = coordinator.snapshot.bytesPerSecond
        if bps > 1024 {
            let mbps = bps / 1_000_000
            if mbps >= 10 {
                return String(format: "%.0f MB/s", mbps)
            }
            return String(format: "%.1f MB/s", mbps)
        }
        return String(localized: "hud.speed.estimating", bundle: .module)
    }
    /// 扫描态时间标签——v2026.06.23 起仅显示已用时长（"已 0:14"）。
    /// 剩余时间不可信，已统一停用，避免"~ 4:00:00"这类误导文案。
    private func scanTimerText(at date: Date = Date()) -> String {
        if smartCareIsActive, let smartCareSession {
            return String(format: String(localized: "hud.time.elapsed %@", bundle: .module),
                          durationString(smartCareSession.elapsedForDisplay(referenceDate: date)))
        }
        return String(format: String(localized: "hud.time.elapsed %@", bundle: .module),
                      durationString(coordinator.elapsedForDisplay(referenceDate: date)))
    }
    /// 同上，紧凑版（给灵动岛展开态用，节省横向空间）。
    private func scanTimerShortText(at date: Date = Date()) -> String {
        if smartCareIsActive, let smartCareSession {
            return String(format: String(localized: "hud.time.elapsed %@", bundle: .module),
                          durationShort(smartCareSession.elapsedForDisplay(referenceDate: date)))
        }
        return String(format: String(localized: "hud.time.elapsed %@", bundle: .module),
                      durationShort(coordinator.elapsedForDisplay(referenceDate: date)))
    }

    var body: some View {
        if placement == .dynamicIsland {
            islandBody
        } else {
            cardBody
        }
    }

    // MARK: - 灵动岛形态

    /// 灵动岛——**Hero 飞越动画**架构（SwiftUI matchedGeometryEffect，等价于 Flutter Hero / AnimatedContainer）：
    /// - 收起态（strip）：图标 / 主标题 / 关键数字 直接挂在胶囊里、贴刘海两侧
    /// - 展开态（card）：同样的图标 / 主标题 / 数字布局到大卡片左上 / 顶部，下方追加比例条 / 按钮
    /// - 通过 `matchedGeometryEffect(id:in:)` 让相同 ID 的元素在两种态切换时**飞越** + 同步插值字号
    /// - 黑色背景 `IslandUnifiedShape` 也参与插值（size 变 + 圆角变）
    /// - 单一 spring 同时驱动 background 形变 + hero 元素飞越——这才是"联动"
    @ViewBuilder
    private var islandBody: some View {
        let notchSize = islandNotchSize
        let pillH: CGFloat = max(notchSize.height, 28)
        let isExpanded = isExpandedState

        // 当前态目标尺寸：用 islandState 测量值；首帧兜底
        // 收起态宽度 = probe 测出的自然宽度 + 8pt 余量（防止 phase 切换瞬间内容长出而宽度还没追上导致裁切）
        let stripW = (islandState.leftPillSize.width > 0 ? islandState.leftPillSize.width : (notchSize.width + 280)) + 8
        let stripH = max(islandState.leftPillSize.height, pillH)
        let expW = islandState.expandedSize.width > 0 ? islandState.expandedSize.width : 540
        let expH = islandState.expandedSize.height > 0 ? islandState.expandedSize.height : 220
        let targetW: CGFloat = isExpanded ? expW : stripW
        let targetH: CGFloat = isExpanded ? expH : stripH
        let bottomCornerRadius: CGFloat = isExpanded ? 24 : pillH / 2

        // 整体上对齐——从屏幕顶部往下生长
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 黑色背景形状——size 跟外层 frame 撑满，圆角随 isExpanded 插值
                IslandUnifiedShape(bottomCornerRadius: bottomCornerRadius)
                    .fill(Color.black)
                    .shadow(
                        color: Color.black.opacity(isExpanded ? 0.45 : 0.32),
                        radius: isExpanded ? 18 : 5,
                        x: 0,
                        y: isExpanded ? 8 : 2
                    )

                // 内容层——**两套布局始终共存**（hero 飞越的前提），matchedGeometryEffect 需要 source 和
                // mirror 同时存在才能完成 frame 测量 → spring 期间元素 frame 在两位置间插值
                //
                // **重影修复（关键）**：hero 元素（标题/数字）在两套布局里字号不同，spring 期间如果两套
                // 都半透明可见，会出现"小字 + 大字重叠"的重影。
                // 解决：在 heroLeftCluster / heroRightCluster 内部用 .opacity(isSource ? 1 : 0) +
                // .animation(.linear(duration: ~0)) 让 hero 元素瞬间切换可见性（不影响 frame 飞越，
                // 因为 matchedGeometryEffect 在 frame 测量时不依赖 opacity）。
                //
                // **addon 平滑修复**：expandedHeroLayout 整层不再切 opacity，只 hero 子簇切；
                // addon 直接跟随外层 islandViewSpring 的 opacity + offset 平滑渐隐——避免收起时突然空。
                ZStack(alignment: .top) {
                    closedStripLayout(pillH: pillH, notchWidth: notchSize.width, isSource: !isExpanded, namespace: islandHeroNS)
                        .allowsHitTesting(!isExpanded)

                    expandedHeroLayout(pillH: pillH, isSource: isExpanded, namespace: islandHeroNS)
                        .allowsHitTesting(isExpanded)
                }
            }
            .frame(width: targetW, height: targetH, alignment: .top)
            .clipShape(IslandUnifiedShape(bottomCornerRadius: bottomCornerRadius))
            // 单一 spring 同时驱动：frame、clipShape 圆角、hero 元素飞越、字号插值——所有"一团"动起来
            // 慢动作调试：环境变量 GSY_ISLAND_DEBUG=1 时 speed(0.2) → 5x 慢放
            .animation(islandViewSpring, value: isExpanded)
            .scaleEffect(isPopping ? 1.028 : 1.0, anchor: .top)
            .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isPopping)
            .compositingGroup()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // **独立测量层**：不参与 spring，永远渲染两种态测自然尺寸
        .background(islandSizeProbe(pillH: pillH, notchWidth: notchSize.width).hidden())
        .onPreferenceChange(IslandSizePreferenceKey.self) { sizes in
            if let s = sizes["strip"] { islandState.leftPillSize = s }
            if let e = sizes["expanded"] { islandState.expandedSize = e }
        }
        .onPreferenceChange(IslandClusterWidthPreferenceKey.self) { width in
            // v1.3 review-fix（对称化）：左右两簇较长那侧的自然宽度。
            // 写回 islandState 后，下一帧 closedStripLayout 把短簇也填齐到这个宽度，左右对称。
            // 仅在变化超过 0.5pt 时写入，避免微小浮动触发 spring 抖动。
            if abs(islandState.clusterMaxWidth - width) > 0.5 {
                islandState.clusterMaxWidth = width
            }
        }
        .onChange(of: phase) { _, _ in
            triggerPop()
        }
        .onChange(of: islandState.expanded) { _, newValue in
            // 关键：从 ObservedObject 流入 view 时，用 withAnimation 显式包裹 @State 改值，
            // 才能让 spring transaction 穿透到 body 求值，驱动 frame / matchedGeometry / addon transition
            withAnimation(islandViewSpring) {
                isExpandedState = newValue
            }
        }
        .onAppear {
            isExpandedState = islandState.expanded
            // 调试：自动循环展开/收起，便于录制 + 抓帧
            if IslandDebug.autoLoop {
                startIslandAutoLoop()
            }
        }
    }

    /// SwiftUI 视图层 spring——慢动作调试时变慢 5x。
    private var islandViewSpring: Animation {
        let base = Animation.spring(response: 0.55, dampingFraction: 0.78)
        return IslandDebug.slowMotion ? base.speed(0.2) : base
    }

    /// 自动展开/收起循环——调试用。每 3 秒翻转一次，配合 GSY_ISLAND_AUTOLOOP=1 启用。
    private func startIslandAutoLoop() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(islandViewSpring) {
                    islandState.expanded.toggle()
                }
            }
        }
    }

    /// **收起态布局**——胶囊 strip：左侧图标+主标题贴刘海左边、右侧数字贴刘海右边、中央留刘海占位。
    /// `isSource` 控制 matchedGeometryEffect 是否以本布局的 frame 为锚点：
    /// - 当本布局可见时（收起态），isSource=true，提供真实的胶囊位置 frame
    /// - 当不可见时（展开态），isSource=false，元素的视觉 frame 跟随展开布局
    ///
    /// **v1.3 review-fix（对称化 + 安全距离）**：
    /// 1. 左右内侧 padding 从 10 → 16pt：用户实测右侧"已 5..."字符贴脸物理刘海被截断；
    ///    16pt 与外侧 padding 对齐，左右内外四角余量一致，视觉对称。
    /// 2. 左右簇上报自然宽度到 IslandClusterWidthPreferenceKey；外层取 max 写回 islandState；
    ///    本函数把两簇都 frame 到 max 宽度（短侧 alignment 朝向胶囊外缘 leading/trailing），
    ///    让"扫描中" vs "已 5,432 项" 这种长度差被填齐为对称形态——左右一起变大变小。
    /// 3. 整体宽度 = clusterMaxWidth × 2 + bridgeWidth + outerPadding × 2，由内容长侧驱动。
    @ViewBuilder
    private func closedStripLayout(pillH: CGFloat, notchWidth: CGFloat, isSource: Bool, namespace: Namespace.ID) -> some View {
        let screen = islandScreen
        let hasNotch = (screen?.safeAreaInsets.top ?? 0) > 0
        let bridgeWidth: CGFloat = hasNotch ? notchWidth : 4

        // v1.3 review-fix：刘海两侧的安全距离常量。值 = 16 与外侧 padding 对齐。
        // 想日后微调可以改这一处；之前 10pt 实测会让右簇"已 5"贴脸刘海被截断/重影。
        let notchSafePadding: CGFloat = 16

        // 对称宽度——尚未测到时为 0，触发 cluster 内部 .fixedSize 自然布局；
        // 一旦 probe 测出真值，左右两簇都 frame 到此宽度（alignment 锚向胶囊外缘）。
        let clusterW = islandState.clusterMaxWidth

        HStack(spacing: 0) {
            heroLeftCluster(isExpanded: false, isSource: isSource, namespace: namespace)
                .fixedSize(horizontal: true, vertical: false)
                .background(clusterWidthReporter)
                .frame(
                    width: clusterW > 0 ? clusterW : nil,
                    alignment: .leading // 左簇填齐时内容贴左（远离刘海）
                )
                .padding(.leading, notchSafePadding)
                .padding(.trailing, notchSafePadding)

            // 中央刘海占位
            Color.clear
                .frame(width: bridgeWidth, height: pillH)

            heroRightCluster(isExpanded: false, isSource: isSource, namespace: namespace)
                .fixedSize(horizontal: true, vertical: false)
                .background(clusterWidthReporter)
                .frame(
                    width: clusterW > 0 ? clusterW : nil,
                    alignment: .trailing // 右簇填齐时内容贴右（远离刘海）
                )
                .padding(.leading, notchSafePadding)
                .padding(.trailing, notchSafePadding)
        }
        .frame(height: pillH)
    }

    /// 把 cluster 自然宽度报到 IslandClusterWidthPreferenceKey。
    /// 配合外层 `.onPreferenceChange` 收集 max → 写回 islandState.clusterMaxWidth。
    /// 用 background + GeometryReader 是 SwiftUI 推荐写法（不撑大父视图、不抢 hit-test）。
    private var clusterWidthReporter: some View {
        GeometryReader { geo in
            Color.clear.preference(key: IslandClusterWidthPreferenceKey.self, value: geo.size.width)
        }
    }

    /// **展开态布局**——大卡片：hero 行（图标+主标题在左 / 数字在右）在顶部，下方堆叠附加内容。
    /// hero 元素 ID 与收起态相同 → SwiftUI 自动做"飞越 + 缩放"动画（matchedGeometry）。
    @ViewBuilder
    private func expandedHeroLayout(pillH: CGFloat, isSource: Bool, namespace: Namespace.ID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // hero 行——同 ID 的元素从胶囊位置飞到这里，同时字号自动插值
            HStack(spacing: 0) {
                heroLeftCluster(isExpanded: true, isSource: isSource, namespace: namespace)
                Spacer(minLength: 12)
                heroRightCluster(isExpanded: true, isSource: isSource, namespace: namespace)
            }
            .frame(height: pillH)

            // 附加内容——**始终挂载**，用 opacity + offset 跟随外层 islandViewSpring 的 spring 平滑过渡。
            // 收起时：opacity 从 1 渐隐到 0、Y 从 0 滑回 -8，连续过渡而不是瞬间消失
            // 展开时：从隐藏态平滑长出
            // 注意：这里**不能**用 if isSource + .transition，因为外层 expandedHeroLayout 的 opacity 也在
            // 切换，spring 期间整层不可见时 addon 的 transition 也看不到——会显得突兀
            islandExpandedAddon
                .opacity(isSource ? 1 : 0)
                .offset(y: isSource ? 0 : -8)
                .allowsHitTesting(isSource)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// hero 左侧簇——图标 + 主标题 + 副标。**每个原子元素挂独立 matchedGeometryEffect ID**，
    /// 让它们各自从收起位置飞到展开位置，字号也跟着 spring 插值。
    /// `isSource` 决定本元素是否提供真实 frame：可见侧 true，隐藏侧 false（跟随对侧 frame）。
    @ViewBuilder
    private func heroLeftCluster(isExpanded: Bool, isSource: Bool, namespace: Namespace.ID) -> some View {
        let mainSize: CGFloat = isExpanded ? 16 : islandClosedMainFontSize
        let subSize: CGFloat = isExpanded ? 12 : islandClosedSecondaryFontSize
        let iconSize: CGFloat = isExpanded ? 18 : islandClosedSecondaryFontSize + 2
        let mainFont = Font.system(size: mainSize, weight: .semibold, design: .rounded)
        let subFont = Font.system(size: subSize, design: .monospaced)

        HStack(spacing: isExpanded ? 10 : 6) {
            // === 图标 / 脉冲点（hero ID: "leadingMark"）===
            // anchor: .leading——让飞越/字号缩放以"左边缘"为锚点：
            // 左边缘贴原位置不动、右边缘往外扩展，视觉上是"在原位置放大"
            Group {
                switch phase {
                case .scanning:
                    PulsingDot(color: .green, size: isExpanded ? 10 : 7)
                case .finished:
                    Image(systemName: cleanableSeverity.symbolName)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(cleanableSeverity.color)
                case .idle:
                    Image(systemName: diskSeverity.symbolName)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(diskSeverity.color)
                }
            }
            .matchedGeometryEffect(id: "leadingMark", in: namespace, properties: .frame, anchor: .leading, isSource: isSource)

            // === 主标题（hero ID: "mainTitle"）===
            // .fixedSize(horizontal:) 让 Text 永远按自然宽度渲染——
            // 否则 spring 期间父容器宽度插值会导致文本被截断成 "..."（动画过程中出现省略号）
            // anchor: .leading——主标题左对齐飞越（字号变大时左边缘锚定）
            Text(heroMainTitle)
                .font(mainFont)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .matchedGeometryEffect(id: "mainTitle", in: namespace, properties: .frame, anchor: .leading, isSource: isSource)

            // === 副标（hero ID: "subTitle"，可能不存在则不挂）===
            if let sub = heroLeftSub {
                Text(sub)
                    .font(subFont)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .matchedGeometryEffect(id: "subTitle", in: namespace, properties: .frame, anchor: .leading, isSource: isSource)
            }
        }
        // 重影修复：仅 hero 簇可见性瞬间切换（mirror 侧不画），avoid 小字 + 大字叠影
        // matchedGeometryEffect 的 frame 测量与 opacity 无关——飞越照常进行
        .opacity(isSource ? 1 : 0)
        .animation(.linear(duration: 0.0001), value: isSource)
    }

    /// hero 右侧簇——关键数字 + 百分比。同样每个元素带独立 hero ID。
    @ViewBuilder
    private func heroRightCluster(isExpanded: Bool, isSource: Bool, namespace: Namespace.ID) -> some View {
        let valueSize: CGFloat = isExpanded ? 22 : islandClosedMainFontSize
        let subSize: CGFloat = isExpanded ? 13 : islandClosedSecondaryFontSize
        let valueFont = Font.system(size: valueSize, weight: .bold, design: .rounded)
        let subFont = Font.system(size: subSize, design: .monospaced)

        HStack(spacing: 4) {
            // anchor: .trailing——右侧文字右对齐飞越：
            // 字号变大时右边缘贴原位置不动、左边缘往左扩展，
            // 视觉上是"在原位置朝左放大"（而不是"从右侧滑入"）
            Text(heroRightValueText)
                .font(valueFont)
                .monospacedDigit()
                .foregroundStyle(heroRightValueColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .matchedGeometryEffect(id: "primaryValue", in: namespace, properties: .frame, anchor: .trailing, isSource: isSource)

            if let percent = heroRightPercentText {
                Text(percent)
                    .font(subFont)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .matchedGeometryEffect(id: "primaryPercent", in: namespace, properties: .frame, anchor: .trailing, isSource: isSource)
            }
        }
        // 重影修复：仅 hero 簇可见性瞬间切换（mirror 侧不画）
        .opacity(isSource ? 1 : 0)
        .animation(.linear(duration: 0.0001), value: isSource)
    }

    // MARK: - hero 文本/颜色派生

    private var heroMainTitle: String {
        switch phase {
        case .scanning:
            return smartCareActivityTitle ?? String(localized: "hud.scanning", bundle: .module)
        case .finished: return cleanableSeverity.label
        case .idle: return idleLeadingText
        }
    }

    private var heroLeftSub: String? {
        if case .scanning = phase { return islandClosedScanTimerText() }
        return nil
    }

    private var heroRightValueText: String {
        switch phase {
        case .scanning:
            return bytesString(smartCareIsActive ? cleanableBytes : coordinator.snapshot.totalBytes)
        case .finished: return bytesString(cleanableBytes)
        case .idle: return bytesString(availableBytes)
        }
    }

    private var smartCareActivityTitle: String? {
        guard let smartCareSession else { return nil }
        switch smartCareSession.care.phase {
        case .scanning(let progress):
            return String(
                localized: String.LocalizationValue(
                    SmartCarePresentation.activityTitleKey(for: progress.activity)
                ),
                bundle: .module
            )
        case .cleaning:
            return String(localized: "smart_care.activity.cleaning", bundle: .module)
        case .idle, .reviewing, .confirming, .completed, .failed, .cancelled:
            return nil
        }
    }

    private var heroRightValueColor: Color {
        switch phase {
        case .scanning: return .white
        case .finished: return cleanableSeverity.color
        case .idle: return availableSeverity.color
        }
    }

    private var heroRightPercentText: String? {
        if case .idle = phase { return "· \(percentString(usedRatio))" }
        return nil
    }

    /// **独立尺寸探测层**——在主视图之外，永远渲染两种态的内容，测量它们的自然尺寸。
    /// 这层不参与 spring 动画，写回 islandState 的值始终是稳态目标，不会因 spring 中间帧污染。
    /// **关键**：probe 用独立 namespace，避免 hero ID 和主层冲突；两种 probe
    /// 再各用一个 namespace，避免同组内出现多个 `isSource: true`。
    @ViewBuilder
    private func islandSizeProbe(pillH: CGFloat, notchWidth: CGFloat) -> some View {
        ZStack {
            closedStripLayout(pillH: pillH, notchWidth: notchWidth, isSource: true, namespace: islandStripProbeNS)
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: IslandSizePreferenceKey.self,
                            value: ["strip": geo.size]
                        )
                    }
                )

            expandedHeroLayout(pillH: pillH, isSource: true, namespace: islandExpandedProbeNS)
                .frame(width: 540)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: IslandSizePreferenceKey.self,
                            value: ["expanded": geo.size]
                        )
                    }
                )
        }
        .allowsHitTesting(false)
    }

    /// 展开态 hero 行的顶部 padding——让 hero 不要压在物理刘海上。
    private var notchSizeAdjustedTop: CGFloat {
        islandNotchSize.height > 0 ? 4 : 8
    }

    /// 展开附加行——比例条 + 三色图例 + 操作按钮。
    /// 仅展开时长出来，由 SwiftUI transition 控制"从顶部下推/上收"的形变效果。
    @ViewBuilder
    private var islandExpandedAddon: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 三色比例条
            islandRatioBar
                .frame(height: 8)

            // 三行图例
            islandLegendRows

            // v1.3.x：虚拟内存占盘信息（用户原话"在 HUD 的大窗口上加上这个显示"）
            islandSwapRow

            // 操作按钮行
            HStack(spacing: 8) {
                Button {
                    onOpen()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.expand.vertical")
                        Text("hud.button.open_main", bundle: .module)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)

                if phase == .idle {
                    Button {
                        onStartScan()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("hud.button.scan_now", bundle: .module)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.green.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// 展开态的三色比例条（已用 / 可清理 / 可用）。
    @ViewBuilder
    private var islandRatioBar: some View {
        let total = max(totalBytes, 1)
        let usedRatio = Double(coordinator.volumeSnapshot?.usedBytes ?? 0) / Double(total)
        let cleanRatio = Double(cleanableBytes) / Double(total)
        let availRatio = max(0, 1 - usedRatio)

        GeometryReader { geo in
            HStack(spacing: 1.5) {
                Capsule()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: max(0, geo.size.width * usedRatio - geo.size.width * cleanRatio))
                Capsule()
                    .fill(cleanableSeverity.color.opacity(0.85))
                    .frame(width: geo.size.width * cleanRatio)
                Capsule()
                    .fill(availableSeverity.color.opacity(0.85))
                    .frame(width: geo.size.width * availRatio)
            }
        }
    }

    /// 展开态的三行图例（已用 / 可清理 / 可用）。
    @ViewBuilder
    private var islandLegendRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            islandLegendRow(color: .white.opacity(0.45), label: String(localized: "hud.legend.used", bundle: .module),
                            value: bytesString(coordinator.volumeSnapshot?.usedBytes ?? 0))
            islandLegendRow(color: cleanableSeverity.color, label: String(localized: "hud.legend.cleanable", bundle: .module),
                            value: bytesString(cleanableBytes))
            islandLegendRow(color: availableSeverity.color, label: String(localized: "hud.legend.free", bundle: .module),
                            value: bytesString(availableBytes))
        }
    }

    @ViewBuilder
    private func islandLegendRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    /// "状态变更" 时的 0.18s pop 动画（扫描开始/结束、severity 跳档时触发）。
    private func triggerPop() {
        isPopping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            isPopping = false
        }
    }

    /// 收起态左胶囊扫描中文案：v2026.06.23 起仅显示已用时长（剩余时间不可信，统一不再展示）。
    private func islandClosedScanTimerText(at date: Date = Date()) -> String {
        return scanTimerShortText(at: date)
    }

    private var islandClosedMainFontSize: CGFloat {
        max(11, islandNotchSize.height * 0.32)
    }


    private var islandClosedSecondaryFontSize: CGFloat {
        max(9, islandNotchSize.height * 0.28)
    }
    private var idleLeadingText: String {
        switch diskSeverity {
        case .critical: return String(localized: "hud.idle.disk_tight", bundle: .module)
        case .warning:  return String(localized: "hud.idle.disk_full", bundle: .module)
        case .caution:  return String(localized: "hud.idle.attention", bundle: .module)
        default:        return String(localized: "hud.idle.idle", bundle: .module)
        }
    }

    /// 屏幕刘海尺寸（无刘海 fallback 190×38）。
    private var islandNotchSize: CGSize {
        let screen = islandScreen
        return screen?.notchSize ?? CGSize(width: 190, height: 38)
    }

    /// 灵动岛挂载的目标屏幕（优先刘海屏，没有则主屏）。
    private var islandScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    // MARK: - 普通卡片形态

    /// v1.3.x：参考主 App `VolumeCapacityCard` 重做的紧凑卡片。
    ///
    /// 顺序：
    /// 1. 顶行：磁盘 icon + 卷名 + 已用/总容量（右侧灰字）+ 操作按钮
    /// 2. 扫描中插一行：状态点 + "扫描中…" + 速度 + ETA
    /// 3. 三色堆叠条：可清理（severity 色）/ 其它已用（中灰）/ 可用（极浅灰）
    /// 4. 三行图例：可清理 / 其它已用 / 可用
    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitleRow
            if phase == .scanning {
                cardScanningRow
            }
            cardStackedBar
            cardLegend
            cardSwapInfoRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 340, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private var cardTitleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(volumeName)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(bytesString(usedBytes)) / \(bytesString(totalBytes))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if phase == .idle {
                Button(action: onStartScan) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("hud.help.start_scan", bundle: .module))
            }
            Button(action: onOpen) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("hud.help.open_main", bundle: .module))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(closeButtonHelp)
        }
    }

    @ViewBuilder
    private var cardScanningRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(verbatim: smartCareActivityTitle
                 ?? String(localized: "hud.scanning_dot", bundle: .module))
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            if !smartCareIsActive {
                Text(speedText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("·")
                .foregroundStyle(.tertiary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(scanTimerText(at: context.date))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(Text(LocalizedStringKey("hud.eta.help.elapsed"), bundle: .module))
            }
            Spacer(minLength: 0)
        }
    }

    /// 三色堆叠条：可清理（severity 主色）/ 其它已用（中灰）/ 可用（极浅）
    @ViewBuilder
    private var cardStackedBar: some View {
        let total = max(1, totalBytes)
        let cleanable = max(0, min(cleanableBytes, usedBytes))
        let other = max(0, otherUsedBytes)
        GeometryReader { geo in
            let w = geo.size.width
            let cleanW = cleanable > 0 ? max(2, CGFloat(Double(cleanable) / Double(total)) * w) : 0
            let otherW = other > 0 ? max(2, CGFloat(Double(other) / Double(total)) * w) : 0
            let availW = max(0, w - cleanW - otherW)
            HStack(spacing: 0) {
                if cleanW > 0 {
                    Rectangle().fill(cleanableSeverity.color).frame(width: cleanW)
                }
                if otherW > 0 {
                    Rectangle().fill(Color.gray.opacity(0.55)).frame(width: otherW)
                }
                if availW > 0 {
                    Rectangle().fill(Color.gray.opacity(0.18)).frame(width: availW)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 8)
    }

    @ViewBuilder
    private var cardLegend: some View {
        VStack(spacing: 3) {
            cardLegendRow(
                color: cleanableSeverity.color,
                label: String(localized: "hud.legend.cleanable", bundle: .module),
                bytes: cleanableBytes,
                valueColor: cleanableSeverity.color,
                bold: cleanableBytes > 0
            )
            cardLegendRow(
                color: Color.gray.opacity(0.55),
                label: String(localized: "hud.legend.other_used", bundle: .module),
                bytes: otherUsedBytes,
                valueColor: nil,
                bold: false
            )
            cardLegendRow(
                color: availableSeverity.color,
                label: String(localized: "hud.legend.free", bundle: .module),
                bytes: availableBytes,
                valueColor: availableSeverity.color,
                bold: availableSeverity == .critical || availableSeverity == .warning
            )
        }
        .font(.caption2)
    }

    /// 单行图例。`valueColor != nil` 时数值上色，`bold=true` 时加粗。
    @ViewBuilder
    private func cardLegendRow(
        color: Color,
        label: String,
        bytes: Int64,
        valueColor: Color?,
        bold: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(bytesString(bytes))
                .font(.system(.caption2, design: .rounded).weight(bold ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? .secondary)
        }
    }

    // MARK: - 共享 helpers

    private var closeButtonHelp: String {
        if settings.hudPersistent {
            return String(localized: "hud.help.close.persistent", bundle: .module)
        }
        return String(localized: "hud.help.close.floating", bundle: .module)
    }

    private func durationString(_ s: TimeInterval) -> String {
        let total = displayDurationSeconds(s)
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let m = total / 60
            let sec = total % 60
            return "\(m)m \(sec)s"
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h \(m)m"
    }

    /// 紧凑时长格式化，给灵动岛收起态左胶囊用——"45s" / "1:23" / "1:02:03"。
    private func durationShort(_ s: TimeInterval) -> String {
        let total = displayDurationSeconds(s)
        if total < 60 { return "\(total)s" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    private func displayDurationSeconds(_ s: TimeInterval) -> Int {
        guard s.isFinite, s > 0 else { return 0 }
        return max(1, Int(s.rounded(.up)))
    }

    private func bytesString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func percentString(_ r: Double) -> String {
        let pct = (r * 100).rounded()
        return "\(Int(pct))%"
    }

    // MARK: - v1.3.x：虚拟内存占盘（swap + sleepimage）行

    /// 主展示口径——swap **已用** + sleepimage，与 macOS 活动监视器 "Swap Used" 对齐。
    /// v1.3.x review-fix：原来用 `totalDiskFootprintBytes`（swap total + sleepimage），
    /// 但 swap total 是"已分配的 swap 文件容量"（含未写入的预留位），
    /// 会让用户对照活动监视器时疑惑"我看到 34 G，你显示 36 G"。
    private var swapPrimaryBytes: Int64 {
        guard let s = coordinator.swapSnapshot else { return 0 }
        if s.swapUsedBytes > 0 { return s.swapUsedBytes + s.sleepImageBytes }
        return s.totalDiskFootprintBytes
    }

    /// 鼠标悬停 tooltip——把 swapfile 个数 / sysctl 内核口径 / sleepimage 提示一次性给到。
    private var swapHintText: String {
        guard let s = coordinator.swapSnapshot else { return "" }
        var parts: [String] = []
        if s.swapFileSizeMeasured {
            parts.append("\(s.swapFileCount) 个 swapfile = \(bytesString(s.swapFileBytesOnDisk))")
        } else if s.swapTotalBytes > 0 {
            parts.append("swap 文件估算 \(bytesString(s.swapTotalBytes))（系统保护下无法直接列文件，回退用 sysctl total）")
        }
        if s.sleepImageBytes > 0 {
            parts.append("休眠镜像 = \(bytesString(s.sleepImageBytes))")
        }
        if s.swapTotalBytes > 0 {
            parts.append("内核已用 \(bytesString(s.swapUsedBytes)) / \(bytesString(s.swapTotalBytes))")
        }
        if s.sleepImageBytes > 0 {
            parts.append("如不使用休眠：终端 `sudo pmset -a hibernatemode 0` 后可手动删 sleepimage")
        }
        return parts.joined(separator: "\n")
    }

    /// 普通卡片形态（cardBody）末尾的紧凑 swap 行。
    @ViewBuilder
    private var cardSwapInfoRow: some View {
        if let s = coordinator.swapSnapshot, s.totalDiskFootprintBytes > 0 || s.swapTotalBytes > 0 {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("capacity.virtual_memory.title", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(bytesString(swapPrimaryBytes))
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .help(swapHintText)
        }
    }

    /// 灵动岛展开态（大窗）里的 swap 行——配色对齐 white-on-black 主题。
    @ViewBuilder
    private var islandSwapRow: some View {
        if let s = coordinator.swapSnapshot, s.totalDiskFootprintBytes > 0 || s.swapTotalBytes > 0 {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Text("capacity.virtual_memory.title", bundle: .module)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                Text(bytesString(swapPrimaryBytes))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .help(swapHintText)
        }
    }
}
