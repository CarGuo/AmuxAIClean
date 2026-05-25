import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanKit
import SafetyKit
import XPCBridge

/// v1.3 review-fix B3：跨 target 的通知名常量。
/// App 层在主窗口已被销毁的情况下 post 这个通知，MainView 监听并调 `openWindow(id:)` 重建。
public extension Notification.Name {
    static let gsyOpenMainWindowRequested = Notification.Name("GSYCleanMac.openMainWindowRequested")
}

/// 三栏主界面 —— 侧边类目 / 中间结果 / 右侧详情 + 删除按钮。
/// 见 PITFALLS §5.5/§5.6/§5.7：默认勾选只勾 .safe；先聚合不展平；删除走 preview sheet。
public struct MainView: View {
    @StateObject private var coordinator: ScanCoordinator
    @State private var presetCategories: [ScanCategory] = ScanCategories.recommended()
    @State private var customCategories: [ScanCategory] = []
    @State private var selectedCategory: ScanCategory.ID?
    @State private var selection: Set<String> = []   // 勾选的 row.id
    /// v1.3.ab：原本是 `RowItem?`，但 `List(selection:)` 用整结构体当 key 会让 SwiftUI 在
    /// snapshot 高频 publish 时（点 Preferences 这种条目几千的目录）对每行做 `==` 比较 + diff，
    /// 主线程被刷爆 → 鼠标彩虹球。改为只押 row.id（String），detail 渲染时再反查。
    @State private var detail: String?
    @State private var showSheet: Bool = false
    @State private var deleteResult: String?
    @State private var isDropTargeted: Bool = false
    /// v1.0 T3：结果区视图模式（清单 vs 多层树）。
    @State private var viewMode: ResultsViewMode = .list
    /// v1.0 T4：大文件视图选中项。与 detail（RowItem）解耦，
    /// 因为大文件是叶子，没有聚合 RowItem 模型。
    @State private var largeFileSelection: LargeFileItem?
    /// 树形视图选中行。bug A：之前 TreeBrowserView 的 selectedPath 锁在自身内部，
    /// 外层 detailPane 永远拿不到，详情面板因此长期空白。现在通过 onSelect 回调
    /// 同步到这里，detailPane 优先用 treeSelection 渲染（语义上"看哪个就显哪个"）。
    @State private var treeSelection: TreeRow?
    /// v1.0 T4：大文件入口类目。固定一项，放在侧边"大文件"独立 section。
    private let largeFilesCategory: ScanCategory = .largeFiles()
    /// v1.0 T5：路径栏临时输入（"/" + Enter 扫整盘；任意已存在目录路径也可直扫）。
    @State private var pathBarInput: String = ""
    /// v1.3：toolbar 路径输入框聚焦态。
    /// 目的：在 `ToolbarItem(.principal)` 里 SwiftUI/AppKit 默认 focus ring 会被 toolbar 容器
    /// 上下裁掉一截（截图反复出现的灰边）；改为 `.textFieldStyle(.plain)` + 自绘 Capsule 背景，
    /// 聚焦时把 Capsule 描边加重 + 用 accentColor 强化，视觉上替代原生 focus ring 且不会被裁。
    /// 参考：tmp/competitors/Pearcleaner FileListView.swift L108-L131 同款做法。
    @FocusState private var pathBarFocused: Bool

    /// 结果区两种视图模式。
    public enum ResultsViewMode: String, CaseIterable, Identifiable {
        case list, tree
        public var id: String { rawValue }
        var label: String { self == .list ? "清单" : "树形" }
        var icon: String { self == .list ? "list.bullet" : "rectangle.grid.1x2" }
    }

    private let pipeline: any DeletionPipeline
    private let recorder: HeuristicRecorder
    private let settings: AppSettings
    private let pathStore: UserPathStore

    public init(pipeline: (any DeletionPipeline)? = nil,
                vendors: [VendorRule] = [],
                recorder: HeuristicRecorder = HeuristicRecorder(),
                settings: AppSettings? = nil,
                pathStore: UserPathStore? = nil,
                coordinator: ScanCoordinator? = nil) {
        // v0 默认走 NSWorkspace.recycle（PITFALLS §5.9）：不需要 root，不需要 99 美元 Apple Developer Program
        // 用户撤销可以走 Finder → 显示废纸篓 → 放回原位
        // M4-P0 修复：把 vendors 透传到 TrashPipeline，让最后闸门启用 vendor 路径树判定
        self.pipeline = pipeline ?? TrashPipeline(vendors: vendors)
        self.recorder = recorder
        self.settings = settings ?? AppSettings()
        self.pathStore = pathStore ?? UserPathStore()
        // v1.3：coordinator 允许从 App 层注入，让 [FloatingScanHUD](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
        // 与主窗口共享同一个 ScanCoordinator 实例（订阅同一份 snapshot/isScanning），避免双扫。
        _coordinator = StateObject(wrappedValue: coordinator ?? ScanCoordinator(vendors: vendors))
    }

    /// 全部类目（preset + custom + libraryBrowse + largeFiles + fullDisk）—— 用于 toolbar / scan 查找。
    /// 资源库浏览入口必须包含进来，否则 onChange selectedCategory 找不到对应 ScanCategory，
    /// 会直接 return 不触发扫描。
    private var allCategories: [ScanCategory] {
        presetCategories + customCategories + libraryBrowseCategories + [largeFilesCategory, ScanCategory.fullDisk]
    }

    /// 资源库浏览：5 个固定的 ~/Library 子目录入口。
    /// 走 ScanCategory.makeCustom(url:) 流程以复用扫描/UI 路径，但**不写入 pathStore**——
    /// 这是预置只读入口，不能污染用户「自定义路径」列表（也不应在退出后保留）。
    /// 故这里只在视图层即席构造，不调用 pathStore.add。
    private var libraryBrowseCategories: [ScanCategory] {
        let paths = [
            "~/Library",
            "~/Library/Application Support",
            "~/Library/Containers",
            "~/Library/Group Containers",
            "~/Library/Preferences",
        ]
        return paths.map { raw in
            let expanded = (raw as NSString).expandingTildeInPath
            return ScanCategory.makeCustom(url: URL(fileURLWithPath: expanded))
        }
    }

    /// v1.3 review-fix B3：拿到 SwiftUI 的"打开/重建窗口" action，让 App 层在主窗口被
    /// 用户 ⌘W 关闭并销毁后，仍能通过通知中心请求重建。配合 `WindowGroup(id: "main")` 使用。
    @Environment(\.openWindow) private var openWindow

    public var body: some View {
        // v1.3.aa：三列 → 两列。原本 NavigationSplitView { sidebar / content / detail }
        // 在嵌套子屏（AppFootprintScreen / UninstallScreen / DuplicateScreen / LaunchAgentScreen）
        // 的内部分栏里出现「外层 detail 列被挤剩极窄一条 + 旋转 90° 占位文字」的视觉灾难
        // （问题 4 的截图）；同时切 tab 时外层 detail 也容易残留上一屏的内容（问题 2）。
        // 现在外层只有 sidebar + content，细节区由各底层屏自己负责（清单/树形复用 results 内的 inline 详情区）。
        NavigationSplitView {
            sidebar
        } detail: {
            results
        }
        .navigationTitle("GSY 清理管家")
        .toolbar { toolbar }
        .sheet(isPresented: $showSheet) {
            DeleteSheet(
                items: selectedRows,
                onCancel: { showSheet = false },
                onConfirm: { dryRun in
                    showSheet = false
                    Task { await performDelete(dryRun: dryRun) }
                }
            )
        }
        .alert("删除结果", isPresented: .constant(deleteResult != nil)) {
            Button("好") { deleteResult = nil }
        } message: {
            Text(deleteResult ?? "")
        }
        .onChange(of: selectedCategory) { _, new in
            // v1.3.aa：原版 `guard let cat = allCategories.first(where: ...) else { return }`
            // 在切到 sentinel（appFootprint/launchAgent/uninstall/duplicate）时直接 return，
            // 既不会 resetSelectionState 也不会清 detail/treeSelection——表现就是问题 2：
            // 上一屏的"启动项详情"残留在右侧栏没清掉。
            // 现在拆成两步：①只要 selection 变了就先清状态；②若是 ScanCategory 才起扫。
            resetSelectionState()
            guard let id = new, let cat = allCategories.first(where: { $0.id == id }) else { return }
            // v2：统一走 [runHeavyAfterCommit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeavyTask.swift)
            // 模板（detached + sleep 16ms + MainActor.run），让 SwiftUI 先把
            // 「sidebar 高亮 / 旧 detail 清空 / loading 状态」这一帧 commit 出去再开始扫。
            // 这样 Preferences 这种条目巨多的目录入扫时不再卡彩虹球。
            runHeavyAfterCommit {
                startScan(category: cat)
            }
        }
        .onChange(of: viewMode) { _, _ in
            // bug A：清单 ↔ 树形 切换时各清各的选中态，避免两条选中互相覆盖。
            detail = nil
            treeSelection = nil
        }
        .onChange(of: settings.minFileSizeMB) { _, _ in
            // v1.0 T4：阈值改变时，若当前正看大文件视图，自动重扫，
            // 让 ROADMAP 验收 3「改阈值到 500 → 重扫 → 列表变短」无需用户额外动作。
            // 注意：只有当扫描期阈值与新阈值差异显著（即更小阈值）时才需要重扫；
            // 若新阈值更大，largeFiles(...) 在视图层就能直接二次过滤，省一次 IO。
            guard let id = selectedCategory,
                  id == largeFilesCategory.id,
                  !coordinator.isScanning else { return }
            let newScanBytes = Int64(max(0, settings.minFileSizeMB)) * 1024 * 1024
            if newScanBytes < coordinator.largeFileScanThresholdBytes {
                startScan(category: largeFilesCategory)
            }
        }
        .onChange(of: settings.sizeAccountingMode) { _, newMode in
            // v1.3：用户在设置里切换字节口径（logical 系统设置口径 ↔ physical du 口径）。
            // 同步到 coordinator；如果当前有扫描结果，提示需要重扫才能让数字按新口径累计。
            // 不强制自动重扫——避免用户切错口径还要等 5 分钟，自己点"重新扫描"更可控。
            coordinator.accountingMode = newMode
        }
        .onChange(of: settings.mainListSortKey) { _, newKey in
            // v1.3：主列表排序键切换 → 同步到 coordinator。
            // coordinator 内部 didSet 会判断仅 finished 态 republish snapshot，
            // 扫描中切换不会扰乱视觉位置（扫描中强制 path 字典序保持稳定）。
            coordinator.mainListSortKey = newKey
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // v1.3：从系统设置勾完 FDA 切回本 App，立即重探权限状态 + 容量。
            // 修「我已经有了权限，为什么顶部还提示需要授权」的核心闭环——
            // 用户回来那一刻 banner 自动消失，不需要重新扫描或重启 App。
            coordinator.refreshFDAStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gsyOpenMainWindowRequested)) { _ in
            // v1.3 review-fix B3：托盘 / HUD 触发"打开主窗口"，但主窗口已被 ⌘W 销毁。
            // 走 SwiftUI 的 OpenWindow action 重建——这是 macOS 14+ 唯一可靠的方式，
            // 比直接 NSApp.windows 遍历 makeKeyAndOrderFront 更稳。
            // 注意：window id 必须与 GSYCleanMacApp 中 WindowGroup(id:) 一致（"main"）。
            openWindow(id: "main")
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .task {
            // v1.3：启动时把 settings 的字节口径同步到 coordinator，
            // 避免 ScanCoordinator 默认值与用户上次保存的偏好不一致。
            coordinator.accountingMode = settings.sizeAccountingMode
            // v1.3：主列表排序键同样在启动时同步，避免持久化值与 coordinator 默认值不一致。
            coordinator.mainListSortKey = settings.mainListSortKey
            await refreshCustomPaths()
        }
    }

    // MARK: - Sidebar

    /// v1.3.zz UI 修复：原本结构是 `List { ... }.safeAreaInset(.bottom) { VolumeCapacityCard }`，
    /// 但扫描期间 [coordinator.snapshot.totalBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 高频变化会让 capacity card 反复重渲染，进而扰动 List 的 safeAreaInset 计算与滚动位置——
    /// 表现就是"点了用户缓存 → sidebar 整段莫名滚到中间，底部容量条仿佛消失"。
    /// 改成显式 VStack（List + 固定底部 capacity card）后，两者是兄弟视图，
    /// card 高度变化不会再传染到 List 的滚动位置。
    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarList
            Divider()
            VolumeCapacityCard(
                snapshot: coordinator.volumeSnapshot,
                cleanableBytes: coordinator.snapshot.totalBytes,
                swap: coordinator.swapSnapshot,
                // v1.3 review-fix Must1：snapshot 探测失败时让卡片提供"重试"按钮，回调到 coordinator.refreshVolumeCapacity()。
                onRetry: { coordinator.refreshVolumeCapacity() }
            )
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        // v2：sidebar 整体套布局沙箱——切断 sidebarList 内部任何一行长 title 反推
        // 外层 NavigationSplitView，避免「sidebar 被压成 1px 竖线」复发。
        .layoutSandbox()
    }

    private var sidebarList: some View {
        List(selection: $selectedCategory) {
            Section("推荐清理") {
                ForEach(presetCategories) { cat in
                    sidebarRow(cat)
                        .tag(cat.id)
                }
            }

            Section {
                ForEach(customCategories) { cat in
                    sidebarRow(cat)
                        .tag(cat.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await removeCustomPath(cat) }
                            } label: {
                                Label("移除该路径", systemImage: "trash")
                            }
                        }
                }
                Button {
                    addCustomPathViaPanel()
                } label: {
                    Label("添加路径…", systemImage: "plus")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            } header: {
                HStack {
                    Text("自定义路径")
                    if !customCategories.isEmpty {
                        Text("· \(customCategories.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("资源库浏览") {
                ForEach(libraryBrowseCategories) { cat in
                    sidebarRow(cat, iconOverride: "folder.badge.gearshape")
                        .tag(cat.id)
                }
            }

            Section("大文件") {
                sidebarRow(largeFilesCategory)
                    .tag(largeFilesCategory.id)
            }

            Section("整盘") {
                sidebarRow(ScanCategory.fullDisk)
                    .tag(ScanCategory.fullDisk.id)
            }

            Section("应用") {
                appFootprintSidebarRow
                    .tag(MainView.appFootprintSentinelID)
                launchAgentSidebarRow
                    .tag(MainView.launchAgentSentinelID)
                uninstallSidebarRow
                    .tag(MainView.uninstallSentinelID)
            }

            Section("去重") {
                duplicateSidebarRow
                    .tag(MainView.duplicateSentinelID)
            }
        }
        // bug1：sidebar List 默认会在获得 keyboard focus 时画一圈蓝色焦点环
        // （包住整个 list 容器，看起来像"鼠标进入 sidebar 才出现的蓝框"）。
        // 我们已经有 row selection 的蓝色背景做选中反馈，再叠焦点环纯属冗余且割裂。
        // 关掉容器级焦点环，单行 selection 不受影响。
        .focusEffectDisabled()
    }

    /// v1.2 P1-6：「应用占用排行榜」侧边项。用 sentinel ID 走旁路，避免污染
    /// ScanCategory（它的语义是"扫描类目 + 默认 verdict"，不适合一个只读视图）。
    static let appFootprintSentinelID: String = "app.footprint"

    /// v1.2 P1-7：「启动项」侧边项。同样走 sentinel ID 旁路 —— 它是只读视图，
    /// 没有勾选/删除动作，不该污染 ScanCategory 体系。
    static let launchAgentSentinelID: String = "launchagent.list"

    /// v1.2 P1-8：「卸载残留」侧边项。UninstallScreen 自带 SafetyEngine + dryRun
    /// + 二次确认 sheet，外层 MainView 不应再叠加扫描/删除 UI，故走 sentinel ID 旁路。
    static let uninstallSentinelID: String = "uninstall.screen"

    /// v1.2 P2-1：「重复文件」侧边项。DuplicateScreen 是只读视图（无勾选 / 无删除按钮），
    /// 与 ScanCategory（默认勾选 + verdict）的语义不兼容，走 sentinel ID 旁路。
    static let duplicateSentinelID: String = "duplicate.scan"

    private var appFootprintSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("应用占用")
                    .font(.system(.body, design: .rounded))
                Text("查看哪些 App 在吃磁盘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var launchAgentSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.square.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("启动项")
                    .font(.system(.body, design: .rounded))
                Text("查看登录/开机自启的 plist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var uninstallSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.slash")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("卸载残留")
                    .font(.system(.body, design: .rounded))
                Text("挑一个 App 清掉它的残留")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var duplicateSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("重复文件")
                    .font(.system(.body, design: .rounded))
                Text("只读视图，请用 Finder 自行处理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sidebarRow(_ cat: ScanCategory, iconOverride: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconOverride ?? iconName(for: cat.kind))
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.title)
                    .font(.system(.body, design: .rounded))
                Text(cat.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for kind: ScanCategory.Kind) -> String {
        switch kind {
        case .preset:     return "sparkles"
        case .custom:     return "folder"
        case .fullDisk:   return "internaldrive"
        case .largeFiles: return "doc.richtext"
        }
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("松开以加入扫描")
                    .font(.title3.bold())
                    .foregroundStyle(.tint)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Results

    /// v1.0 T4：当前是否在大文件模式（侧边选了 "🐘 大文件" 类目）。
    private var isLargeFilesMode: Bool {
        selectedCategory == largeFilesCategory.id
    }

    /// v1.2 P1-6：当前是否在应用占用排行榜模式。
    private var isAppFootprintMode: Bool {
        selectedCategory == MainView.appFootprintSentinelID
    }

    /// v1.2 P1-7：当前是否在启动项查看模式。
    private var isLaunchAgentMode: Bool {
        selectedCategory == MainView.launchAgentSentinelID
    }

    /// v1.2 P1-8：当前是否在卸载残留模式。
    private var isUninstallMode: Bool {
        selectedCategory == MainView.uninstallSentinelID
    }

    /// v1.2 P2-1：当前是否在重复文件模式。
    private var isDuplicateMode: Bool {
        selectedCategory == MainView.duplicateSentinelID
    }

    private var results: some View {
        VStack(spacing: 0) {
            if isAppFootprintMode {
                // 「应用占用排行榜」整段独立：不渲染 statusBar / footerBar 等扫描相关 UI。
                AppFootprintScreen()
            } else if isLaunchAgentMode {
                // 「启动项」同样整段独立 —— 只读视图，无扫描进度 / 勾选 / 删除按钮。
                LaunchAgentScreen()
            } else if isUninstallMode {
                // 「卸载残留」整段独立：UninstallScreen 自带 SafetyEngine + dryRun + 二次确认，
                // 外层不能再叠 statusBar / footerBar / 删除按钮，避免重复或绕过安全契约。
                UninstallScreen(vendors: [])
            } else if isDuplicateMode {
                // 「重复文件」整段独立：只读视图，没有勾选 / 删除按钮，
                // 也不复用 statusBar / footerBar（它有自己的 banner + 进度 + footer）。
                DuplicateScreen()
            } else {
                statusBar
                Divider()
                if isLargeFilesMode {
                    // 大文件视图整段独立：不复用 viewModeBar / listResults / placeholder，
                    // 因为它的列模型、空态文案、选中模型都不一样。
                    LargeFilesView(
                        coordinator: coordinator,
                        settings: settings,
                        selection: $largeFileSelection,
                        onTrash: { urls in
                            triggerLargeFileTrash(urls: urls)
                        }
                    )
                } else if coordinator.snapshot.rows.isEmpty {
                    placeholder(for: placeholderState)
                } else {
                    viewModeBar
                    Divider()
                    // v1.3.aa：原本 detail 是外层 NavigationSplitView 的第三列；现在两列后
                    // 改成清单/树视图与 inline 详情区横排。详情区在没选中时折叠为 0 宽。
                    // v1.3.ab：清单/树视图区强制 maxWidth: .infinity + minWidth: 320 + layoutPriority(1)，
                    // 防止某行内容（如 10 GB+ 长路径）反向把 List ideal width 抬高 →
                    // 挤压外层 NavigationSplitView 的 sidebar，从根本上消除"动不动 UI 错乱"。
                    HStack(spacing: 0) {
                        Group {
                            switch viewMode {
                            case .list:
                                listResults
                            case .tree:
                                if let root = coordinator.currentRootPath {
                                    TreeBrowserView(
                                        coordinator: coordinator,
                                        rootPath: root,
                                        onSelect: { row in
                                            // bug A：树形选中 → 详情面板。同时清掉清单视图的 detail，
                                            // 避免两条选中态打架（detailPane 先看 treeSelection）。
                                            treeSelection = row
                                            detail = nil
                                        },
                                        onTrash: { url in
                                            // v1.3：树形右键 / Delete 走废纸篓。
                                            triggerLargeFileTrash(urls: [url])
                                        }
                                    )
                                    // v2 修：TreeBrowserView 内部用 @State 缓存了
                                    // selectedPath / expanded / sortKey；如果换了扫描根
                                    // 但 SwiftUI 把同一个 view instance 复用，旧 root 下的
                                    // 子路径 key 会残留在 expanded 字典里，新 root 自己的
                                    // 节点反而展不开 / 选不中——表现就是用户截图里
                                    // 「切到别的目录后树形一直不出来」。
                                    // 用 .id(root) 把 view identity 绑到 rootPath 上，
                                    // root 一变 SwiftUI 强制销毁旧 view + 重建新 view，
                                    // 所有 @State 自然清零。
                                    .id(root)
                                } else {
                                    Text("暂无可展开的扫描根")
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                        .frame(minWidth: 320, maxWidth: .infinity)
                        .layoutPriority(1)
                        if detail != nil || treeSelection != nil {
                            Divider()
                            inlineDetailPane
                                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                        }
                    }
                }
                Divider()
                footerBar
            }
        }
        .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        // v2：detail 列整体套布局沙箱——这是修「Library 一来数据 sidebar 变成竖线」、
        // 「重复文件左右栏掉到窗外」、「卸载残留把外层 sidebar 挤掉」一系列灾难的根因。
        //
        // GeometryReader 把外层 NavigationSplitView detail 列分给 results 的
        // proposed width 物理钉死成 results 内容的 frame width，
        // 内部 List/HStack/HSplitView 任何子视图的 ideal width 都不再向外反推，
        // 反挤 sidebar 的链条被切断。
        .layoutSandbox()
        .onChange(of: coordinator.snapshot.rows.count) { _, _ in
            // 默认勾选：仅勾 .safe（PITFALLS §5.5）
            // 用 union：用户已经手动改过的不要被覆盖
            let safeIDs = coordinator.snapshot.rows.filter { $0.defaultSelected }.map(\.id)
            for id in safeIDs where !selection.contains(id) {
                selection.insert(id)
            }
        }
    }

    /// 视图模式切换条（清单 / 树形）。
    private var viewModeBar: some View {
        HStack {
            Picker("视图", selection: $viewMode) {
                ForEach(ResultsViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
            if viewMode == .tree {
                Text("树视图：右键或 Delete 键单条移到废纸篓；批量勾选请切回清单")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var listResults: some View {
        List(selection: $detail) {
            ForEach(coordinator.snapshot.rows) { row in
                let isOn = Binding<Bool>(
                    get: { selection.contains(row.id) },
                    set: { newValue in
                        if newValue { selection.insert(row.id) }
                        else { selection.remove(row.id) }
                    }
                )
                RowView(row: row, selected: isOn,
                        maxBytes: coordinator.snapshot.rows.first?.bytes ?? 0)
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
        // bug B：清单视图的 List(selection:) 同样会画容器级焦点环，关掉。
        // 单行选中蓝条不受影响。
        .focusEffectDisabled()
        // v1.3.ab：把 List 的本征宽度上限钉死在父容器宽度，禁止某条特别宽的 RowView
        // （比如 10 GB+ 路径很长的行）反向把 ideal width 抬高 → 把整个外层 sidebar 挤掉。
        .frame(minWidth: 320, maxWidth: .infinity)
        .layoutPriority(1)
    }

    /// v1.3：是否应显示顶部权限 banner。
    ///
    /// 旧逻辑只看"是否有任意 skipped 或 denied 路径"——但 [TCCSkipList](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TCCSkipList.swift)
    /// 是硬编码列表，**用户已授予 FDA 后这些路径本来就该被正常下钻**，banner 此时是误报。
    ///
    /// 现在分两档：
    /// - **FDA 已授权**：ScanCoordinator 把 `respectTCCSkipList` 关掉，BulkScanner 不再 yield
    ///   `.tccProtectedSkipped`，所以 `tccProtectedSkippedPaths` 应当为空；只在
    ///   `permissionDeniedPaths` 真的非空时显示（root 自身 EACCES 等罕见情况）
    /// - **FDA 未授权 / 未知**：保持原行为，任一非空都显示
    private var shouldShowPermissionBanner: Bool {
        if coordinator.fdaStatus == .granted {
            return !coordinator.permissionDeniedPaths.isEmpty
        }
        return !coordinator.permissionDeniedPaths.isEmpty
            || !coordinator.tccProtectedSkippedPaths.isEmpty
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            // v1.3 修 banner 误报：FDA 已授权时，硬 skip 已被 ScanCoordinator 关闭，
            if shouldShowPermissionBanner {
                PermissionStatusBanner(
                    fdaDeniedPaths: coordinator.permissionDeniedPaths,
                    tccSkippedPaths: coordinator.tccProtectedSkippedPaths,
                    fdaStatus: coordinator.fdaStatus,
                    onOpenSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    onRescan: {
                        // v1.3：跳系统设置 + 立即重扫当前 category。
                        // 用户回到 App 时本就能看到"扫描中"，
                        // 等他在系统设置勾完 GSYCleanMac 那一刻起，
                        // 后续 BulkScanner 拿到的就是含原 TCC 跳过路径的完整树。
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                        if let id = selectedCategory,
                           let cat = allCategories.first(where: { $0.id == id }) {
                            startScan(category: cat)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            HStack {
                if coordinator.isScanning {
                    ProgressView().controlSize(.small)
                    if coordinator.perRootProgress.isEmpty {
                        // 单根扫描：保留原有"扫描中… N 个文件 · X MB"单行行为。
                        Text("扫描中… \(coordinator.snapshot.scannedFileCount) 个文件 · \(formattedBytes(coordinator.snapshot.totalBytes))")
                            .font(.callout)
                    } else {
                        // v1.3：多根并行扫描——按 rootPath 字典序输出多行（每根一条），
                        // 已 finished 的根用 ✓ 替代 ●，文案"{title} · {bytes} · {fileCount} 文件"。
                        // 字典序稳定排序：避免 dict 遍历顺序导致行序抖动。
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(coordinator.perRootProgress.values.sorted(by: { $0.rootPath < $1.rootPath }), id: \.rootPath) { p in
                                HStack(spacing: 4) {
                                    Text(p.isFinished ? "✓" : "●")
                                        .font(.caption.bold())
                                        .foregroundStyle(p.isFinished ? Color.green : Color.accentColor)
                                    Text("\(p.title) · \(formattedBytes(p.bytes)) · \(p.fileCount) 文件")
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                } else if coordinator.snapshot.isFinished {
                    Text("完成 · \(coordinator.snapshot.scannedFileCount) 文件 · \(formattedBytes(coordinator.snapshot.totalBytes)) · \(String(format: "%.2fs", coordinator.snapshot.elapsed))")
                        .font(.callout)
                } else if coordinator.wasCancelled {
                    // v1.3：cancel 后区分"已停止"与"还未扫描"两态，避免用户以为停止键失灵
                    Text("已停止 · 按右上「重新扫描」继续")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    // v1.3：未扫描态显式文案，避免空 snapshot 渲染成 "0 KB · 0 个文件" 误导用户。
                    // 区分两种 pristine：已选类目但未点扫 / 完全没选类目。
                    if selectedCategory != nil {
                        Text("还未扫描 · 按右上「重新扫描」或「整盘扫描」开始")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        Text("还未扫描 · 选择左侧类目开始")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                Spacer()
                if let err = coordinator.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 三态占位 —— 见 PITFALLS §5.6（OnyX 教训：空态要给"下一步动作"）。
    enum PlaceholderState: Equatable {
        case notStarted
        case scanning
        case finishedEmpty(rootPath: String)
    }

    /// 由 coordinator 派生当前应该显示的占位态。
    /// - 正在扫描 → `.scanning`
    /// - 已扫完且行为空 → `.finishedEmpty`（携带刚扫的目录路径）
    /// - 否则（含初始态、用户切类目还没开始）→ `.notStarted`
    var placeholderState: PlaceholderState {
        if coordinator.isScanning {
            return .scanning
        }
        if coordinator.isFinished, let root = coordinator.currentRootPath {
            return .finishedEmpty(rootPath: root)
        }
        return .notStarted
    }

    @ViewBuilder
    private func placeholder(for state: PlaceholderState) -> some View {
        switch state {
        case .notStarted:
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("还没有结果")
                    .foregroundStyle(.secondary)
                Text("从左侧选择一个类目即可开始扫描")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .scanning:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("正在扫描…")
                    .foregroundStyle(.secondary)
                Text("首次扫描可能较慢，可在右上角随时停止")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .finishedEmpty(let rootPath):
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("没有可清理的内容")
                    .foregroundStyle(.secondary)
                Text(rootPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
                Button {
                    // v1.3 review-fix：仅清 selectedCategory 并不会清 placeholder（coordinator
                    // 仍保留 isFinished=true + currentRootPath），用户视觉上"无反馈"。
                    // 主动 cancel() 把 snapshot/currentRootPath 清回 .notStarted 态。
                    coordinator.cancel()
                    selectedCategory = nil
                } label: {
                    Label("换个目录", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footerBar: some View {
        HStack {
            if isLargeFilesMode {
                Text(largeFileSelection.map {
                    "已选 \($0.title) · \(formattedBytes($0.bytes))"
                } ?? "未选中任何项")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    if let item = largeFileSelection {
                        triggerLargeFileTrash(urls: [item.url])
                    }
                } label: {
                    Label("移到废纸篓…", systemImage: "trash")
                }
                .disabled(largeFileSelection == nil)
                .keyboardShortcut(.delete, modifiers: .command)
            } else {
                Text(selectionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showSheet = !selectedRows.isEmpty
                } label: {
                    Label("移到废纸篓…", systemImage: "trash")
                }
                .disabled(selectedRows.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(16)
    }

    // MARK: - Detail (inline)

    /// v1.3.aa：从外层 NavigationSplitView 的 detail 列拿下来后，
    /// 详情区只在「清单选中行」或「树形选中行」时才挂载（条件渲染在 results 里）。
    /// 不再有"未选中显示占位"的态——空态本来就该是 0 宽，让清单/树视图占满。
    /// v1.3.ab：detail 现在是 row.id（String），渲染时即席从 snapshot.rows 里反查。
    @ViewBuilder
    private var inlineDetailPane: some View {
        if let id = detail,
           let item = coordinator.snapshot.rows.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VerdictBadge(verdict: item.verdict)
                        .frame(width: 14, height: 14)
                    Text(item.title)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.url.path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .longPathStyle()
                Divider()
                LabeledContent("大小（占用）", value: formattedBytes(item.bytes))
                LabeledContent("大小（逻辑）", value: formattedBytes(item.logicalBytes))
                LabeledContent("文件数", value: "\(item.fileCount)")
                LabeledContent("是目录", value: item.isDirectory ? "是" : "否")
                LabeledContent("安全等级", value: verdictLabel(item.verdict))
                if item.verdict == .forbid {
                    Text("拒绝原因：\(item.rejection.rawValue)")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            // v2：统一详情面板样式（padding + maxWidth.infinity + leading 对齐）。
            .detailPaneStyle()
        } else if let row = treeSelection {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(.tint)
                    Text(row.title)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(row.path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .longPathStyle()
                Divider()
                LabeledContent("大小", value: formattedBytes(row.bytes))
                LabeledContent("文件数", value: "\(row.fileCount)")
                LabeledContent("是目录", value: row.isDirectory ? "是" : "否")
                if row.isDirectory && row.hasChildren {
                    LabeledContent("可展开", value: "是")
                }
                Divider()
                Text("提示：树视图只读浏览。要清理请切回「清单」视图勾选。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .detailPaneStyle()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            pathBar
        }
        ToolbarItem(placement: .primaryAction) {
            sortMenu
        }
        ToolbarItem(placement: .primaryAction) {
            recommendedAllButton
        }
        ToolbarItem(placement: .primaryAction) {
            fullDiskButton
        }
        ToolbarItem(placement: .primaryAction) {
            scanControlButton
        }
    }

    /// v1.3：主列表排序选择器。
    /// - 默认 `.sizeDesc`（按字节大小从大到小），最常用，所以放默认。
    /// - 扫描中切换不会打乱视觉位置：[ScanCoordinator.publishSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    ///   在 finished=false 时强制 path 字典序，仅 finished=true 才用此键排序。
    /// - 用 Menu 而不是 segmented Picker：6 个 case 横排太挤；Menu 更紧凑且 macOS 原生。
    /// - `@Bindable` 局部 wrap：MainView 把 settings 持成 `private let`，本地需要 binding 时
    ///   按 Apple 推荐用 `@Bindable var x = settings` 即席包一层，不需要把整个视图改成 @Bindable。
    private var sortMenu: some View {
        @Bindable var settings = settings
        return Menu {
            Picker("排序", selection: $settings.mainListSortKey) {
                ForEach(MainListSortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(settings.mainListSortKey.label, systemImage: "arrow.up.arrow.down")
        }
        .help("主列表排序方式（扫描中保持固定顺序，扫描完成后按所选键排序）")
    }

    /// v1.3：「全部推荐扫描」—— 一键并行扫描 ScanCategories.recommended() 5 个根。
    /// 解决用户反馈"看起来还是只有一个目录在动"——多根并行 + statusBar 多行进度让"打满核"可见。
    private var recommendedAllButton: some View {
        Button {
            resetSelectionState()
            // 并行扫描会清掉 selectedCategory 的隐含语义（5 根没有"当前选中类目"），
            // 显式置 nil 让"重新扫描"按钮在多根模式下不渲染（其逻辑依赖单 selectedCategory）。
            selectedCategory = nil
            coordinator.scanRecommended(includeHidden: settings.showHidden)
        } label: {
            Label("全部推荐扫描", systemImage: "rectangle.3.group")
        }
        .help("并行扫描 5 个推荐目录（缓存 / 日志 / DerivedData / 下载 / 废纸篓）")
        .disabled(coordinator.isScanning)
    }

    /// v1.0 T5：路径栏 —— 输 `/` 回车扫整盘；输任意已存在目录回车直接扫。
    ///
    /// v1.3 修复：原 `.textFieldStyle(.roundedBorder)` 在 `ToolbarItem(.principal)` 里聚焦时
    /// 蓝色 focus ring 会被 toolbar 容器裁切（截图证据）。改为 `.plain` + 自绘 Capsule 胶囊：
    /// - 平时：`Color.secondary.opacity(0.10)` 底 + 0.5pt 灰描边；
    /// - 聚焦：底色不变，描边换 `accentColor` 1.5pt，效果接近 Spotlight/Finder 搜索栏。
    /// Capsule 完全在 SwiftUI 视图层内，永远不会越过 toolbar 边界 → 不会被裁。
    private var pathBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("输入路径或 / 回车扫整盘", text: $pathBarInput)
                .textFieldStyle(.plain)
                .focused($pathBarFocused)
                .frame(minWidth: 220, idealWidth: 320)
                .onSubmit { submitPathBar() }
                .help("输 / 回车扫整盘；输已存在目录回车开始扫该目录")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    pathBarFocused ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: pathBarFocused ? 1.5 : 0.5
                )
        )
        .contentShape(Capsule(style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: pathBarFocused)
    }

    /// v1.0 T5：整盘扫描快捷按钮。
    private var fullDiskButton: some View {
        Button {
            triggerFullDiskScan()
        } label: {
            Label("整盘扫描", systemImage: "internaldrive")
        }
        .help("扫描根目录 /（首次需开启系统设置 → 隐私 → 完全磁盘访问权限）")
        .disabled(coordinator.isScanning)
    }

    /// 现有的"停止 / 重新扫描"按钮，按当前状态二选一。
    @ViewBuilder
    private var scanControlButton: some View {
        if coordinator.isScanning {
            Button(role: .cancel) {
                coordinator.cancel()
            } label: { Label("停止", systemImage: "stop.circle") }
        } else if let id = selectedCategory, let cat = allCategories.first(where: { $0.id == id }) {
            Button {
                // v1.3：统一走 resetSelectionState()，避免重新扫描后 detail/treeSelection 残留
                resetSelectionState()
                startScan(category: cat)
            } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
        }
    }

    /// 路径栏回车：分两条路径
    /// 1. 输入 `/`（裸斜杠）→ 整盘扫描
    /// 2. 输入任意"已存在目录"绝对路径 → 加到 customCategories 并选中扫描
    private func submitPathBar() {
        let raw = pathBarInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // 整盘
        if raw == "/" {
            triggerFullDiskScan()
            pathBarInput = ""
            return
        }
        // 普通目录
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            // 简单提示：路径不存在/不是目录
            deleteResult = "路径不存在或不是目录：\(url.path)"
            return
        }
        Task {
            _ = await pathStore.add(url)
            await refreshCustomPaths()
            await MainActor.run {
                let cat = ScanCategory.makeCustom(url: url)
                selectedCategory = cat.id
                pathBarInput = ""
            }
        }
    }

    /// 整盘扫描入口：统一从这里发起，方便后续接 TCC 引导。
    /// 走 `selectedCategory` 赋值 → 命中已有 onChange 流程，避免双扫；
    /// 单测路径请直接调 `coordinator.scanFullDisk(...)`。
    private func triggerFullDiskScan() {
        // v1.3：统一走 resetSelectionState()，避免整盘扫描后旧详情/树选中残留
        resetSelectionState()
        if selectedCategory == ScanCategory.fullDisk.id {
            // 已经选中整盘 → onChange 不会再触发，主动重扫
            coordinator.scanFullDisk(includeHidden: settings.showHidden)
        } else {
            selectedCategory = ScanCategory.fullDisk.id
        }
    }

    // MARK: - Helpers

    /// v1.3：统一清空所有选中态（勾选 / 大文件 / 详情 / 树选中）。
    /// 三处入口（切类目 / 重新扫描 / triggerFullDiskScan）共享，
    /// 防止旧详情面板残留显示到新扫描结果上。
    private func resetSelectionState() {
        selection.removeAll()
        largeFileSelection = nil
        detail = nil
        treeSelection = nil
    }

    private var selectedRows: [RowItem] {
        coordinator.snapshot.rows.filter { selection.contains($0.id) && $0.isSelectable }
    }

    private var selectionSummary: String {
        let rows = selectedRows
        if rows.isEmpty { return "未选中任何项" }
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        return "已选 \(rows.count) 项 · \(formattedBytes(total))"
    }

    /// v1.3.zzzz：从 ScanCoordinator 拉一份"上层一票否决"路径快照。
    /// 合并 [permissionDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L18)
    /// 与 [tccProtectedSkippedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L21)
    /// —— 这两类路径里实质没有数据，扔给 NSWorkspace.recycle 也无意义。
    private func accessDeniedPathsSnapshot() -> Set<String> {
        var s = Set<String>()
        s.formUnion(coordinator.permissionDeniedPaths)
        s.formUnion(coordinator.tccProtectedSkippedPaths)
        return s
    }

    private func formattedBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func verdictLabel(_ v: SafetyVerdict) -> String {
        switch v {
        case .safe: return "🟢 安全"
        case .confirm: return "🟡 需确认"
        case .forbid: return "🔴 受保护"
        }
    }

    private func performDelete(dryRun: Bool) async {
        let paths = selectedRows.map(\.url.path)
        // v1.3.zzzz：在调 pipeline 前把上层一票否决集合（accessDenied）推给 TrashPipeline，
        // 让 partitionByForbid 把这类路径以 SafetyRejection.accessDenied 拒掉，不进 dryRun present
        // 计数、也不真 recycle。HelperClient/mock 不实现 setAccessDeniedPaths，跳过即可。
        if let trash = pipeline as? TrashPipeline {
            trash.setAccessDeniedPaths(accessDeniedPathsSnapshot())
        }
        let (moved, skipped, err) = await pipeline.moveToTrash(paths: paths, dryRun: dryRun)
        let mode = dryRun ? "（预览）" : ""
        if let err {
            deleteResult = "失败\(mode)：\(err)\n已处理 \(moved) 项，跳过 \(skipped) 项"
        } else {
            deleteResult = "已处理 \(moved) 项\(mode)，跳过 \(skipped) 项"
            if !dryRun {
                // HL 行为采集：真删之后才上报，dryRun 不污染统计
                await recorder.recordTrashed(paths: paths)
                selection.removeAll()
                // v1.3：删除完成后立即重探卷容量，sidebar 容量条会跟随变化（"清理后空闲变多"反馈）。
                coordinator.refreshVolumeCapacity()
            }
        }
    }

    // MARK: - v1.0 T4 大文件辅助

    /// 统一扫描入口：根据类目 kind 决定是否传 largeFileMinBytes。
    /// 这一层抽象避免在 onChange / toolbar / settings.onChange 三处重复"判 kind 决定参数"。
    private func startScan(category: ScanCategory) {
        // v1.3.zzzz Phase 2-F-B：开新一轮扫描前先清掉 pipeline 上的 accessDenied 旧快照。
        // ScanCoordinator 在 scan(...) 入口会重置 permissionDeniedPaths / tccProtectedSkippedPaths
        // （见 [ScanCoordinator.swift L356-L361 / L410-L412 / L509-L511]
        // (file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L356)），
        // 但 pipeline 是 MainView 实例字段，跨扫描复用——若不主动清空，旧 deniedPaths 会一直
        // 残留到下次 performDelete 重新注入前的窗口期，造成"本来已可写的路径被误以 accessDenied 拒"。
        if let trash = pipeline as? TrashPipeline {
            trash.setAccessDeniedPaths([])
        }
        if category.kind == .largeFiles {
            let minBytes = Int64(max(0, settings.minFileSizeMB)) * 1024 * 1024
            coordinator.scan(category: category,
                             includeHidden: settings.showHidden,
                             largeFileMinBytes: minBytes)
        } else {
            coordinator.scan(category: category, includeHidden: settings.showHidden)
        }
    }

    /// 大文件视图右键"移到废纸篓…"回调。
    /// 直接走 pipeline.moveToTrash + DeleteSheet 简化版（一次只对一个 url，
    /// 不复用主清单的 selection sheet——大文件场景没有 SafetyEngine 默认勾选语义）。
    private func triggerLargeFileTrash(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let paths = urls.map(\.path)
            // 与 performDelete 保持一致的 accessDenied pre-flight。
            if let trash = pipeline as? TrashPipeline {
                trash.setAccessDeniedPaths(accessDeniedPathsSnapshot())
            }
            let (moved, skipped, err) = await pipeline.moveToTrash(paths: paths, dryRun: false)
            await MainActor.run {
                if let err {
                    deleteResult = "失败：\(err)\n已处理 \(moved) 项，跳过 \(skipped) 项"
                } else {
                    deleteResult = "已处理 \(moved) 项，跳过 \(skipped) 项"
                    largeFileSelection = nil
                }
            }
            if err == nil {
                await recorder.recordTrashed(paths: paths)
            }
        }
    }

    // MARK: - 自定义路径（添加 / 删除 / 拖拽）

    /// NSOpenPanel 选目录添加到 UserPathStore。
    /// 见 PITFALLS §5.6：默认 canChooseFiles=false 防误选单文件；多选避免反复弹窗。
    private func addCustomPathViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "选择要加入扫描的目录"
        panel.prompt = "添加"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task {
                for url in urls {
                    _ = await pathStore.add(url)
                }
                await refreshCustomPaths()
            }
        }
    }

    /// 侧边自定义路径行的 contextMenu「移除」。
    private func removeCustomPath(_ cat: ScanCategory) async {
        _ = await pathStore.remove(URL(fileURLWithPath: cat.rootPath))
        await refreshCustomPaths()
    }

    /// 把 actor 里的路径列表镜像到 SwiftUI 的 customCategories（@State 在主线程）。
    private func refreshCustomPaths() async {
        let urls = await pathStore.list()
        await MainActor.run {
            customCategories = urls.map { ScanCategory.makeCustom(url: $0) }
        }
    }

    /// onDrop 回调：从拖入的 NSItemProvider 解 fileURL，目录才入库。
    /// 见 PITFALLS §5.7：拖入文件不应被当作扫描根，避免对单文件做整盘扫描。
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard exists, isDir.boolValue else { return }
                Task {
                    _ = await pathStore.add(url)
                    await refreshCustomPaths()
                }
            }
        }
        return accepted
    }
}

private struct PermissionStatusBanner: View {
    /// FDA（完全磁盘访问）受阻的路径——open(2) 失败。
    let fdaDeniedPaths: [String]
    /// TCC 雷区被主动 skip 的路径——根本没尝试 open，避免弹窗。
    let tccSkippedPaths: [String]
    /// 当前进程的 FDA 探测状态。`.granted` 仍出现 denied 路径 = 多半是
    /// `~/.Trash` 之类**独立 TCC**项（不属于 FDA），需要单独引导用户。
    let fdaStatus: FDAProbe.Status
    let onOpenSettings: () -> Void
    /// v1.3：用户在 banner 上点「授权后扫描这些目录」——
    /// 跳系统设置 + 触发当前 category 重扫。MainView 在 onRescan 里串起来。
    /// 给 nil 视为兼容路径（按钮不显示），但本仓库目前 MainView 一定传非 nil。
    var onRescan: (() -> Void)? = nil
    @State private var expanded = false

    private var fdaCount: Int { fdaDeniedPaths.count }
    private var tccCount: Int { tccSkippedPaths.count }

    private var headlineText: String {
        switch (fdaCount, tccCount) {
        case (0, 0): return ""
        case (let f, 0): return "\(f) 个目录因权限受阻未扫描，结果可能偏小"
        case (0, let t): return "\(t) 个隐私目录已自动跳过（避免系统弹窗）"
        case (let f, let t): return "权限受阻 \(f) 项 · 隐私跳过 \(t) 项"
        }
    }

    private var iconName: String {
        fdaCount > 0 ? "lock.shield" : "hand.raised.circle"
    }

    private var tintColor: Color {
        fdaCount > 0 ? .orange : .blue
    }

    /// 主行动按钮文案：FDA 受阻强调"打开权限"；纯 TCC 跳过强调"授权后重扫"。
    private var actionLabel: String {
        fdaCount > 0 ? "打开完全磁盘访问权限" : "授权后扫描这些目录"
    }

    /// v1.3.zz：检测"明明 FDA 已开却仍 denied"——多半 = 用户授权的是 .app，
    /// 但当前进程是 Debug build 或路径不一样的产物，TCC 按 codesign hash 索引匹不上。
    /// 或者 = denied 路径里全是 ~/.Trash 之类**独立 TCC**项（不属于 FDA 范畴）。
    private var diagnosticHint: String? {
        let trashDenied = fdaDeniedPaths.contains { $0.hasSuffix("/.Trash") }
        if fdaStatus == .granted && trashDenied {
            return "提示：~/.Trash 不属于「完全磁盘访问」范畴——它是 macOS 14+ 单独的隐私项，需要在 系统设置 → 隐私与安全 → 自动化 / 文件与文件夹 里单独允许；或者改用 Finder 自带的「清空废纸篓」。"
        }
        if fdaStatus == .denied && fdaCount > 0 {
            return "提示：当前进程探测到 FDA = 未授权。如果你刚刚在系统设置里给 GSYCleanMac 打了勾，请尝试：① 退出本 App 完全重启；② 确认你打勾的 .app 路径就是当前正在运行的这一个（开发版 Debug build 与正式 .app 的 TCC 授权是分开的）。"
        }
        if fdaStatus == .unknown && fdaCount > 0 {
            return "提示：未能探测到 FDA 状态（用户从未用过 Mail/Safari/Messages，没有探针文件）。请直接到 系统设置 → 隐私与安全 → 完全磁盘访问 中确认授权。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(tintColor)
                Text(headlineText)
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Button(expanded ? "收起" : "查看路径") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption)
                // v1.3：tcc-only 场景之前没有任何"主动授权"入口，
                // 现在两种场景都露出主行动按钮，文案因情境而异。
                if fdaCount > 0 || tccCount > 0 {
                    Button(actionLabel) {
                        if let onRescan {
                            onRescan()
                        } else {
                            onOpenSettings()
                        }
                    }
                    .controlSize(.small)
                }
            }
            // v1.3.zz：诊断提示——比纯 banner 多一行解释，让用户在不展开"查看路径"
            // 的前提下也能直接看到"为什么明明授权了还提示"。
            if let hint = diagnosticHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if fdaCount > 0 {
                            Text("权限受阻 (\(fdaCount))").font(.caption).foregroundStyle(.orange)
                            ForEach(fdaDeniedPaths.prefix(50), id: \.self) { p in
                                Text(p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if fdaCount > 50 {
                                Text("…还有 \(fdaCount - 50) 条未显示").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if tccCount > 0 {
                            if fdaCount > 0 { Divider().padding(.vertical, 2) }
                            Text("隐私目录跳过 (\(tccCount))").font(.caption).foregroundStyle(.blue)
                            ForEach(tccSkippedPaths.prefix(50), id: \.self) { p in
                                Text(p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if tccCount > 50 {
                                Text("…还有 \(tccCount - 50) 条未显示").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text("说明：Apple Music / Photos / Mail 等敏感库已主动跳过，避免系统反复弹权限框；这些目录与本 App 的清理目标（缓存/重复文件/卸载残留）无关。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(10)
        .background(tintColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tintColor.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
