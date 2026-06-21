import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanKit
import SafetyKit
import AIKit

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
    /// v2026.06.21：切换 category 前若已有扫描结果，弹确认对话框。
    /// `pendingCategoryChange` 暂存"用户想切到的 new"，`isRevertingSelection`
    /// 用于在取消时把 selectedCategory 还原回 old 而不再次走确认分支
    /// （SwiftUI 的 binding 改值会再次触发 onChange，必须用 flag 短路一次）。
    @State private var pendingCategorySwitch: (old: String?, new: String?)?
    @State private var isRevertingSelection: Bool = false
    @State private var showSwitchCategoryConfirm: Bool = false
    /// **v1.5.3 修订**：删除走乐观更新——前端 pruneDeleted 立即生效，
    /// 后台 pipeline.moveToTrash 异步执行，仅在结束后用 deleteResult alert 报结果。
    /// 这个 flag 仍保留（未来如有"批量删除大数据集"场景可重新挂 progress UI），
    /// 当前版本仅用于内部 guard"删除中不要重复触发"。
    @State private var isDeleting: Bool = false
    @State private var deleteResult: String?

    /// **v2026.06.16 修复 #4**：删除主路径 + 大文件 trash 的结构化结果 sheet。
    /// 取代旧 alert 拼接 `delete.result.success/failure %@ %lld %lld` 的纯文字弹窗。
    /// `deleteResult` 仍保留——`delete.result.path_invalid` 等纯路径校验提示仍走旧 alert。
    @State private var deleteResultPayload: OperationResultPayload?
    @State private var isDropTargeted: Bool = false
    /// v1.0 T3：结果区视图模式（清单 vs 多层树）。
    ///
    /// **v1.3.zzzz Phase 4-A**：方案 C 落地——默认走树形（`.tree`），
    /// 与 [CleanMyMac Smart Scan](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/CleanMyMac.md)、
    /// [DaisyDisk sunburst](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/competitors/DaisyDisk.md) 同款"层次化主视图"对齐。
    /// 清单**降级为可切换二级视图**（保留入口，不删 [listResults](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L611)）：
    /// - 清单仍然挂载在 [viewModeBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L590) 的 segmented Picker 里随时切回
    /// - 但视觉默认强调"树形"是主路径，让用户首屏看到的是层次化容量分布
    /// - 批量勾选 / mtime 过滤等"清单专属能力"先不迁移到树（避免风险面爆炸）
    @State private var viewMode: ResultsViewMode = MainView.phase4ADefaultViewMode

    /// Phase 4-A 单一信源：方案 C 选定的默认视图模式。
    /// 把默认值从 @State inline literal 提到 static 常量，**让测试能稳定断言**——
    /// SwiftUI @State 的初始值不是 protocol 可见的，没法从外部反射；提一层就能 lock。
    /// 任何回滚到 `.list` 的改动都会让 [`testPhase4ADefaultIsTree`](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/AppUITests.swift) 直接红。
    public static let phase4ADefaultViewMode: ResultsViewMode = .tree
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

    /// v1.5 review-fix #9：状态条多根 progress 列表的滚动区高度。
    /// caption 字号 ≈ 11pt × ~6 行 ≈ 120pt 是默认；用 @ScaledMetric 跟随
    /// Dynamic Type 缩放，避免大字号下能看到的行数减半。
    @ScaledMetric(relativeTo: .caption) private var multiRootProgressScrollMaxHeight: CGFloat = 120

    /// v1.6 Sentinel：daemon 通过 `gsycleanmac://action/scan/full` 唤起主 App 时，
    /// 不自动开扫（用户在 Step 6.4 决策中选了 C：避免突袭式 IO 抢占），而是弹一个引导 alert，
    /// 用户点「立即扫描」才走 ScanCoordinator.scanRecommended。
    @State private var sentinelScanInvitationVisible: Bool = false

    /// 结果区两种视图模式。
    public enum ResultsViewMode: String, CaseIterable, Identifiable {
        case list, tree
        public var id: String { rawValue }
        var label: String { self == .list ? String(localized: "main.results.mode.list", bundle: .module) : String(localized: "main.results.mode.tree", bundle: .module) }
        var icon: String { self == .list ? "list.bullet" : "rectangle.grid.1x2" }
    }

    private let pipeline: any DeletionPipeline
    private let recorder: HeuristicRecorder
    private let settings: AppSettings
    private let pathStore: UserPathStore
    /// M5 / 2026-06：AI 模块配置。**必须由 App 层注入**与 [SettingsScene](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SettingsScene.swift)
    /// 共享同一份 @Observable 实例：用户在 ⌘, 切 AI Enabled → RowView contextMenu
    /// 的"问 AI"项要立刻刷新可见性。若各自 new 两份独立实例，虽然底层 UserDefaults
    /// 一致，但 @Observable 的 in-process 通知不会跨实例传，会导致需重启 App 才生效
    /// （Review fix #2，2026-06-15）。为兼容旧测试构造保留可选参数；省略时仍 new
    /// 一份私有实例（同 process 内只有 MainView 自己用，无 drift 风险）。
    @State private var aiSettings: AISettings
    /// 用户在 contextMenu 点过的最近一行 —— 非 nil 即弹 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)。
    @State private var aiAskingRow: RowItem?
    /// v1.5 P2 / Q3：AI 未配置时点击"问 AI"会把这里置 true，弹 alert 引导用户前往设置。
    /// 旧实现是按钮直接隐藏 / disabled —— 用户根本不知道有这个能力。
    @State private var aiUnconfiguredAlert: Bool = false
    /// macOS 14+：通过环境拿到打开"设置..."窗口的标准 action。
    /// Q3 alert 的"前往设置"按钮会调用它，免去手写 NSApp.sendAction 私有 selector。
    @Environment(\.openSettings) private var openSettings

    /// v2026.06.18 **稍后处理（购物车）**：跨视图共享的待处理集合。
    /// 来源：tree row contextMenu → onStash → 入库；
    /// 出口：toolbar 右侧"待处理(N)"按钮 → 打开 [StashScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashScreen.swift)。
    /// 用 @State 持 StashStore 实例，与 MainView 同生命周期；不持久化（参考购物车语义）。
    @State private var stash: StashStore = StashStore()
    /// 控制 [StashScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashScreen.swift)
    /// sheet 的开关；与 [stash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 分开以便 sheet dismiss 时不会清空购物车数据。
    @State private var isStashScreenPresented: Bool = false
    /// v2026.06.19 **一键 AI 队列引擎**。与 [stash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 同生命周期；sheet 关闭时不取消跑中的队列（用户可能想后台先跑着，回头再开）。
    /// 实际并不会在 sheet 关闭后继续可见进度——但已得到的 verdict 仍然写在 store
    /// 里，下次打开 sheet 依然能看到徽标。
    @State private var stashAIQueue: StashAIQueue = StashAIQueue()

    public init(pipeline: (any DeletionPipeline)? = nil,
                vendors: [VendorRule] = [],
                recorder: HeuristicRecorder = HeuristicRecorder(),
                settings: AppSettings? = nil,
                pathStore: UserPathStore? = nil,
                coordinator: ScanCoordinator? = nil,
                aiSettings: AISettings? = nil) {
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
        // M5 / Review fix #2：AISettings 必须 App 层注入。未注入时（老测试 / 预览）退回独立实例。
        _aiSettings = State(initialValue: aiSettings ?? AISettings())
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
        .navigationTitle(Text("main.nav.title", bundle: .module))
        .toolbar { toolbar }
        // v2026.06.21：切换扫描目标前确认。`titleVisibility: .visible` 让 message 不被吃掉。
        // 设计：role:.destructive 暗示"放弃当前结果"是有损操作；cancel 同时复位 selection
        // 回到 old（用 isRevertingSelection 短路再次 onChange）。
        .confirmationDialog(
            String(localized: "mainview.switch_category.confirm.title", bundle: .module),
            isPresented: $showSwitchCategoryConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard let pending = pendingCategorySwitch else { return }
                pendingCategorySwitch = nil
                applyCategorySwitch(from: pending.old, to: pending.new)
            } label: {
                Text("mainview.switch_category.confirm.proceed", bundle: .module)
            }
            Button(role: .cancel) {
                // 还原 selection 回 old；isRevertingSelection 让随后的 onChange 自然 return。
                guard let pending = pendingCategorySwitch else { return }
                pendingCategorySwitch = nil
                isRevertingSelection = true
                selectedCategory = pending.old
            } label: {
                Text("mainview.switch_category.confirm.cancel", bundle: .module)
            }
        } message: {
            Text("mainview.switch_category.confirm.message", bundle: .module)
        }
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
        // M5 / 2026-06：AI 询问 sheet —— item-based 触发，aiAskingRow 非 nil 即弹。
        .sheet(item: $aiAskingRow) { row in
            AIAdviceSheet(row: row,
                          aiSettings: aiSettings,
                          onClose: { aiAskingRow = nil })
        }
        // v1.5 P2 / Q3：AI 未配置时点击"问 AI" → 弹"前往设置？"alert，
        // 用户确认则调 openSettings()（macOS 14+ 标准 action）。
        // 取代旧的"按钮直接隐藏 / disabled"路径，让用户知道有这能力 + 怎么开。
        .alert(String(localized: "ai.unconfigured.alert.title", bundle: .module),
               isPresented: $aiUnconfiguredAlert) {
            Button(String(localized: "ai.unconfigured.alert.open_settings", bundle: .module)) {
                openSettings()
            }
            Button(String(localized: "ai.unconfigured.alert.cancel", bundle: .module),
                   role: .cancel) {}
        } message: {
            Text(String(localized: "ai.unconfigured.alert.message",
                        bundle: .module))
        }
        // v2026.06.18 **稍后处理 sheet**。点 toolbar 的 `tray.full.fill` 按钮触发；
        // 在 sheet 内做"一键清理 / 一键 AI / 单独清理 / 单独 AI / 剔除"集中操作。
        // 复用现有 trigger / aiAskingRow 通道，不引入第二条删除/AI 链路。
        .sheet(isPresented: $isStashScreenPresented) {
            StashScreen(
                stash: stash,
                aiQueue: stashAIQueue,
                aiSettings: aiSettings,
                onClose: { isStashScreenPresented = false },
                onCleanOne: { entry in
                    // 单独清理：复用 triggerLargeFileTrash（已含乐观更新 + 历史写入）。
                    // 删除发起后再把对应 path 从待处理摘掉，避免 sheet 行残留。
                    // v2026.06.21 修复 #3：suppressSuccessSheet=true。stash 路径已经通过
                    // 「item 从列表消失」反馈成功，纯成功不再叠 OperationResultSheet——
                    // 否则用户关闭 stash sheet 后会被一个多余的"清理完成"弹窗困住。
                    // 失败 / 拦截项仍会弹（用户必须看见）。
                    triggerLargeFileTrash(urls: [URL(fileURLWithPath: entry.path)],
                                          suppressSuccessSheet: true)
                    stash.remove(entry.path)
                },
                onCleanAll: { entries in
                    let urls = entries.map { URL(fileURLWithPath: $0.path) }
                    triggerLargeFileTrash(urls: urls, suppressSuccessSheet: true)
                    stash.remove(paths: entries.map(\.path))
                },
                onAskAIOne: { entry in
                    // 单独 AI：复用 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
                    // 通道（item-based sheet），不在 StashScreen 内再造一份 AI 渲染。
                    // 先把 stash sheet 收掉再弹 AI，避免 macOS sheet 叠层 (不支持 sheet 之上 sheet)。
                    //
                    // v1.5 P2 / Q3：走 requestAI 收敛 —— 未配置弹"前往设置"alert。
                    let row = makeAIQueryRow(from: entry)
                    isStashScreenPresented = false
                    DispatchQueue.main.async { requestAI(row: row) }
                },
                onRunAIBatch: {
                    // v2026.06.19 一键 AI 队列入口：
                    // 把闭包推给 [StashAIQueue.start](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashAIQueue.swift)，
                    // 它内部串行循环 + 每条单独写回 stash 缓存。
                    // 重置上一轮的 verdict，避免新跑的 done 跟旧的 done 视觉上混淆——
                    // 用户期望"一键 AI"是一次干净的重新评估。
                    stash.clearAIVerdicts()
                    stashAIQueue.start(stash: stash, aiSettings: aiSettings)
                }
            )
        }
        // **v1.5.3 修订**：之前这里挂了一个 ProgressView sheet 拦在主页面前面，
        // 视觉上变成"整页消失只剩 loading"，且 sheet dismiss 触发的重渲染 + store-fallback
        // 还会把已删项再从 GRDB 拉回来。现在删除走"乐观更新"：
        //   1. 点删 → 立即 pruneDeleted（snapshot.rows + childEdges + treeChildrenCache + store）
        //   2. 用户视觉上节点立刻消失，无 modal sheet
        //   3. 后台 pipeline.moveToTrash 异步执行，完成后只弹结果 alert（成功/失败）
        // 真删失败时通过 deleteResult alert 提示，pruneDeleted 已扣除的 row 由下一次扫描重新补齐。
        .alert(String(localized: "main.delete.result.title", bundle: .module), isPresented: .constant(deleteResult != nil)) {
            Button(String(localized: "main.delete.result.ok", bundle: .module)) { deleteResult = nil }
        } message: {
            Text(deleteResult ?? "")
        }
        // **v2026.06.16 修复 #4**：删除主路径 / 大文件 trash 结构化结果 sheet。
        // **v2026.06.22 (#11)**：注入 `onForceDelete` 回调——当 sheet 列出 vendor 规则拦下的项时，
        // 用户可点「强制删除」走 [performForceDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
        // 路径（绕 vendor trie 但保留所有 SafetyEngine 硬安全网）。
        .sheet(item: $deleteResultPayload) { payload in
            OperationResultSheet(
                payload: payload,
                onDismiss: { deleteResultPayload = nil },
                onForceDelete: { paths in
                    Task { @MainActor in
                        await performForceDelete(paths: paths)
                    }
                }
            )
        }
        .onChange(of: selectedCategory) { old, new in
            // v1.3.aa：原版 `guard let cat = allCategories.first(where: ...) else { return }`
            // 在切到 sentinel（appFootprint/launchAgent/uninstall/duplicate）时直接 return，
            // 既不会 resetSelectionState 也不会清 detail/treeSelection——表现就是问题 2：
            // 上一屏的"启动项详情"残留在右侧栏没清掉。
            // 现在拆成两步：①只要 selection 变了就先清状态；②若是 ScanCategory 才起扫。
            //
            // v1.5：再加一支 batch.* sentinel 分发——sidebar 顶部 Batch Scans 三行。
            // 用户从 sidebar 选中其中一条 = 等价点 toolbar 对应按钮。
            //
            // v1.5 review-fix #2：batch.* 分支的 reset 由 trigger* helper 自己负责，
            // 这里不再重复 reset——因为 toolbar 直接调 helper 时（如重复点同一按钮）
            // selectedCategory 没变化 onChange 不触发，reset 必须由 helper 兜底。
            // 非 batch 分支（普通 ScanCategory / appFootprint 等 sentinel）仍由 onChange 顶部 reset。
            //
            // v1.5 review-fix #3：batchFullDisk 也走 triggerFullDiskScan()，与另两个
            // batch sentinel 分支风格统一——helper 是后续维护扩展点。
            //
            // v2026.06.21：切换前若已有扫描结果，弹确认对话框，避免用户误触切走重扫。
            // 用户反馈："切了就要重新扫描了，应该问一下"。
            guard old != new else { return }
            // 走回滚分支（用户点了"留在当前"）→ 不再走业务，flag 复位即可。
            if isRevertingSelection {
                isRevertingSelection = false
                return
            }
            // 已有结果（任意一种形态：snapshot.rows / perRoot 进度 / 仍在扫描）→ 拦确认。
            if shouldConfirmCategorySwitch {
                pendingCategorySwitch = (old, new)
                showSwitchCategoryConfirm = true
                return
            }
            applyCategorySwitch(from: old, to: new)
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
        .onReceive(NotificationCenter.default.publisher(for: .gsySentinelStartFullScan)) { _ in
            // v1.6 Sentinel 场景 2：daemon 通过 `gsycleanmac://action/scan/full` 唤起。
            // 用户决策 C：不自动开扫，弹引导 alert，让用户主动确认。
            openWindow(id: "main")
            sentinelScanInvitationVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .gsySentinelOpenUninstall)) { note in
            // v1.6 Sentinel 场景 1：daemon 通过 `gsycleanmac://uninstall?path=...` 唤起卸载页。
            // path 已由 [SentinelURLRouter](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelURLRouter.swift) 校验过；
            // 这里把侧栏定位到 uninstall sentinel row，让 UninstallScreen 显示。
            // 注：path 当前不直接 deep-link 到具体卸载条目（候选展示在 UninstallScreen 列表里），
            // 后续可通过 NotificationCenter 二次广播由 UninstallScreen 自己消费 path 实现高亮。
            openWindow(id: "main")
            selectedCategory = MainView.uninstallSentinelID
            _ = note
        }
        .alert(
            String(localized: "sentinel.alert.scan_invitation.title", bundle: .module),
            isPresented: $sentinelScanInvitationVisible
        ) {
            Button(String(localized: "sentinel.alert.scan_invitation.action_scan", bundle: .module)) {
                coordinator.scanRecommended(includeHidden: settings.showHidden)
            }
            Button(String(localized: "sentinel.alert.scan_invitation.action_dismiss", bundle: .module), role: .cancel) {}
        } message: {
            Text("sentinel.alert.scan_invitation.message", bundle: .module)
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
                // v1.6 / 2026-06：**口径修复**——以前这里灌的是 `coordinator.snapshot.totalBytes`，
                // 即"已扫到的全部字节"，导致 sidebar 出现"扫多少就 Cleanable 多少"的离谱口径（
                // 用户截图: Scanning 133.49 GB ↔ Cleanable 133.49 GB）。
                // 现在统一走 [ScanSnapshot.safeBytes / .confirmBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L375-L387)
                // ——仅 `SafetyVerdict.safe` 行求和算入"可清"段、`SafetyVerdict.confirm`
                // 行单独成"需要确认"段，与业界（CleanMyMac / DaisyDisk）四段分层对齐。
                safeBytes: coordinator.snapshot.safeBytes,
                confirmBytes: coordinator.snapshot.confirmBytes,
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
            // v1.5: Batch Scans —— sidebar 与 toolbar 三大扫描入口的镜像。
            // 解决用户截图反馈：点 toolbar 锤子 / 推荐 / 全盘后，左侧 sidebar
            // 没有任何选中态，感知不到"我现在在跑哪条"。
            // 这里 3 行的 .tag 用 ScanCategory.batchXxxID 三个 sentinel；
            // onChange(selectedCategory) 看见这三 id 时不走 startScan(category:)
            // 而是分发到对应 trigger* helper（toolbar 同款）。
            Section {
                batchScanRow(icon: "rectangle.3.group",
                             titleKey: LocalizedStringKey("batch.recommended.title"),
                             subtitleKey: LocalizedStringKey("batch.recommended.subtitle"))
                    .tag(ScanCategory.batchRecommendedID)

                batchScanRow(icon: "hammer",
                             titleKey: LocalizedStringKey("batch.developer.title"),
                             subtitleKey: LocalizedStringKey("batch.developer.subtitle"))
                    .tag(ScanCategory.batchDeveloperID)

                batchScanRow(icon: "internaldrive",
                             titleKey: LocalizedStringKey("batch.fulldisk.title"),
                             subtitleKey: LocalizedStringKey("batch.fulldisk.subtitle"))
                    .tag(ScanCategory.batchFullDiskID)
            } header: {
                Text("sidebar.section.batch", bundle: .module)
            }

            Section {
                ForEach(presetCategories) { cat in
                    sidebarRow(cat)
                        .tag(cat.id)
                }
            } header: {
                Text("sidebar.section.recommended", bundle: .module)
            }

            Section {
                ForEach(customCategories) { cat in
                    sidebarRow(cat)
                        .tag(cat.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await removeCustomPath(cat) }
                            } label: {
                                Label {
                                    Text("menu.path.remove", bundle: .module)
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                }
                Button {
                    addCustomPathViaPanel()
                } label: {
                    Label {
                        Text("menu.path.add", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            } header: {
                HStack {
                    Text("sidebar.section.custom", bundle: .module)
                    if !customCategories.isEmpty {
                        Text("· \(customCategories.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(libraryBrowseCategories) { cat in
                    sidebarRow(cat, iconOverride: "folder.badge.gearshape")
                        .tag(cat.id)
                }
            } header: {
                Text("sidebar.section.library", bundle: .module)
            }

            Section {
                sidebarRow(largeFilesCategory)
                    .tag(largeFilesCategory.id)
            } header: {
                Text("sidebar.section.large_files", bundle: .module)
            }

            Section {
                sidebarRow(ScanCategory.fullDisk)
                    .tag(ScanCategory.fullDisk.id)
            } header: {
                Text("sidebar.section.full_disk", bundle: .module)
            }

            Section {
                appFootprintSidebarRow
                    .tag(MainView.appFootprintSentinelID)
                launchAgentSidebarRow
                    .tag(MainView.launchAgentSentinelID)
                uninstallSidebarRow
                    .tag(MainView.uninstallSentinelID)
                devVersionedSidebarRow
                    .tag(MainView.devVersionedSentinelID)
            } header: {
                Text("sidebar.section.apps", bundle: .module)
            }

            Section {
                duplicateSidebarRow
                    .tag(MainView.duplicateSentinelID)
            } header: {
                Text("sidebar.section.duplicates", bundle: .module)
            }

            // Step 7：UndoHistory section —— 给"最近清理 / 恢复"一个独立入口。
            // 单 row 设计避免污染 ScanCategory 体系（与 uninstall / duplicate 同款 sentinel ID 模式）。
            Section {
                undoHistorySidebarRow
                    .tag(MainView.undoHistorySentinelID)
            } header: {
                Text("sidebar.section.undo_history", bundle: .module)
            }

            // M4-T4 / 2026-06：系统维护 section —— rebuildLaunchServices /
            // flushQuickLookCache / flushDNSCache 三个 user-space 任务，
            // 走 [MaintenanceScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MaintenanceScreen.swift)
            // 自包含 UI，不复用扫描状态栏。
            Section {
                maintenanceSidebarRow
                    .tag(MainView.maintenanceSentinelID)
            } header: {
                Text("sidebar.section.maintenance", bundle: .module)
            }

            // F-2-3 / F-2-4 / 2026-06：dev 工具集 section —— Lipo（通用二进制瘦身）+
            // Brew（Homebrew 包管理）。两个 Kit（[LipoKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/LipoKit) /
            // [BrewKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit)）很早就完成了，但一直没接 sidebar。
            // 走 sentinel 旁路 + 独立 Screen，与 maintenance 同款不复用扫描状态栏。
            // 字面量直接英文不进 xcstrings（dev 工具，不强求 i18n）。
            Section {
                lipoSidebarRow
                    .tag(MainView.lipoSentinelID)
                brewSidebarRow
                    .tag(MainView.brewSentinelID)
            } header: {
                Text("main.section.dev_tools", bundle: .module)
            }

            // v1.7 M1 PR-5 / 2026-06：Developer Workflows section ——
            // Apple / Android / Web-Node 三大生态按"工作流"分组的一键清理入口。
            // 与 `batch.developer` sentinel（DevArtifactScanner 散点）共存，但
            // 这三行走 [WorkflowDetailView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)
            // 渲染卡片化 + 可勾选 + 动态扫描 + 回收站删除 全链路。
            // 字面量改走 xcstrings（workflow.sidebar.* 前缀），中英双语。
            Section {
                workflowAppleSidebarRow
                    .tag(MainView.workflowAppleSentinelID)
                workflowAndroidSidebarRow
                    .tag(MainView.workflowAndroidSentinelID)
                workflowWebNodeSidebarRow
                    .tag(MainView.workflowWebNodeSentinelID)
            } header: {
                Text("workflow.sidebar.section", bundle: .module)
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

    /// Step 7：「最近清理」侧边项。UndoHistoryScreen 渲染最近 N 次 trash 批次 + 恢复按钮，
    /// 完全是一个事后管理面板，与扫描语义无关，故走 sentinel ID 旁路。
    static let undoHistorySentinelID: String = "undo.history"

    /// M4-T4 / 2026-06：「系统维护」侧边项。MaintenanceScreen 是 3 个 user-space 任务
    /// 的执行面板（rebuildLaunchServices / flushQuickLookCache / flushDNSCache），
    /// 与扫描 / 删除语义无关，沿 uninstall / undoHistory 同款 sentinel 旁路。
    static let maintenanceSentinelID: String = "maintenance.screen"

    /// F-2-3 / 2026-06：「Lipo 通用二进制瘦身」侧边项。LipoScreen 自带 .app 拾取 /
    /// dryRun 列表 / extract 按钮，不复用扫描状态栏，走 sentinel 旁路。
    static let lipoSentinelID: String = "lipo.screen"

    /// F-2-4 / 2026-06：「Homebrew」侧边项。BrewScreen 三 tab（installed / outdated /
    /// cleanup）直接读 Cellar / Caskroom + ~/Library/Caches/Homebrew，不执行 brew，
    /// 也不复用扫描状态栏，走 sentinel 旁路。
    static let brewSentinelID: String = "brew.screen"

    /// M4-T2 / 2026-06：「开发者旧版本」侧边项。点击触发
    /// [ScanCoordinator.scanKnownVersionedRoots(home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L710)，
    /// 同步派发 Xcode DeviceSupport / JetBrains Toolbox 旧版本命中为 `developer.versioned`
    /// snapshot。沿用主路径的 statusBar / listResults，因此走 onChange 显式 case 而非
    /// "allCategories.first 自然 return"。
    static let devVersionedSentinelID: String = "developer.versioned.scan"

    /// v1.7 M1 PR-5：「Apple 开发者工作流」侧边项。沿用 maintenance / lipo / brew 同款 sentinel 旁路，
    /// results 区渲染 [WorkflowDetailView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)，
    /// 数据源 [AppleWorkflow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/DeveloperWorkflow.swift)。
    /// 与既有 `batch.developer` sentinel 共存——后者是"按类目散点扫"，本 sentinel 是"按 Apple 工作流分组扫"。
    static let workflowAppleSentinelID: String = "workflow.apple"

    /// v1.7 M1 PR-5：「Android 开发者工作流」侧边项。
    static let workflowAndroidSentinelID: String = "workflow.android"

    /// v1.7 M1 PR-5：「Web / Node 开发者工作流」侧边项。
    static let workflowWebNodeSentinelID: String = "workflow.webnode"

    /// v1.7 M1 PR-5：三个工作流 sentinel 集合。onChange 命中其一即清空状态，不再走 startScan 路径。
    static let workflowSentinelIDs: Set<String> = [
        workflowAppleSentinelID,
        workflowAndroidSentinelID,
        workflowWebNodeSentinelID,
    ]

    /// v1.5：sidebar Batch Scans section 的 row。结构与 sidebarRow / appFootprintSidebarRow
    /// 对齐：图标 + 标题 + 副标题。row 自身不带 tap handler，selection 切换由
    /// onChange(selectedCategory) 统一调度到对应 trigger* helper。
    /// v1.5 review-fix #13：去掉 dead `id` 参数（外部 .tag(...) 使用，本函数不需要）。
    private func batchScanRow(icon: String,
                              titleKey: LocalizedStringKey,
                              subtitleKey: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey, bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text(subtitleKey, bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var appFootprintSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("sidebar.row.app_footprint", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.app_footprint", bundle: .module)
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
                Text("sidebar.row.launch_agents", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.launch_agents", bundle: .module)
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
                Text("sidebar.row.uninstall", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.uninstall", bundle: .module)
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
                Text("sidebar.row.duplicate", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.duplicate", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// Step 7：「最近清理」侧边 row —— 与 uninstall / duplicate 同结构，图标用 arrow.uturn.backward。
    private var undoHistorySidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("sidebar.row.undo_history", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.undo_history", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// M4-T4 / 2026-06：「系统维护」侧边 row —— 与 undoHistory / uninstall 同结构，
    /// 图标用 wrench.and.screwdriver 表达"工具集合"。
    private var maintenanceSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("sidebar.row.maintenance", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.maintenance", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// F-2-3 / 2026-06：「Lipo」侧边 row —— 图标用 cpu 表达 "CPU 架构切片"。
    /// 字面量直接 verbatim 英文，不进 xcstrings（dev 工具）。
    private var lipoSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("main.devtool.lipo.title", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("main.devtool.lipo.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// F-2-4 / 2026-06：「Homebrew」侧边 row —— 图标用 mug 借喻 brew。
    private var brewSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mug")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("main.devtool.brew.title", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("main.devtool.brew.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// v1.7 M1 PR-5：「Apple 工作流」侧边 row —— apple.logo 图标，副标题点明覆盖范围。
    private var workflowAppleSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "applelogo")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("workflow.sidebar.apple.title", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("workflow.sidebar.apple.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// v1.7 M1 PR-5：「Android 工作流」侧边 row —— cube.box 借喻"包/构建产物"。
    /// （SF Symbol 没有 Android 专属图标，cube.box 与 "AAR / APK / build artifacts" 语义对齐。）
    private var workflowAndroidSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.box")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("workflow.sidebar.android.title", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("workflow.sidebar.android.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// v1.7 M1 PR-5：「Web / Node 工作流」侧边 row —— globe 图标。
    private var workflowWebNodeSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("workflow.sidebar.webnode.title", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("workflow.sidebar.webnode.subtitle", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// M4-T2 / 2026-06：「开发者旧版本」侧边 row —— 与 uninstall / launchAgent 同结构，
    /// 图标用 hammer 表达"开发工具产物"。点击触发 ScanCoordinator.scanKnownVersionedRoots。
    private var devVersionedSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("sidebar.row.dev_versioned", bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text("sidebar.subtitle.dev_versioned", bundle: .module)
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
                Text(cat.displayTitle)
                    .font(.system(.body, design: .rounded))
                Text(cat.displaySubtitle)
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
                                    Text("drop.hint.release_to_add", bundle: .module)
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

    /// Step 7：当前是否在「最近清理」模式。
    private var isUndoHistoryMode: Bool {
        selectedCategory == MainView.undoHistorySentinelID
    }

    /// M4-T4 / 2026-06：当前是否在「系统维护」模式。
    private var isMaintenanceMode: Bool {
        selectedCategory == MainView.maintenanceSentinelID
    }

    /// F-2-3 / 2026-06：当前是否在「Lipo」模式。
    private var isLipoMode: Bool {
        selectedCategory == MainView.lipoSentinelID
    }

    /// F-2-4 / 2026-06：当前是否在「Homebrew」模式。
    private var isBrewMode: Bool {
        selectedCategory == MainView.brewSentinelID
    }

    /// v1.7 M1 PR-5：当前是否在「Apple 工作流」模式。
    private var isWorkflowAppleMode: Bool {
        selectedCategory == MainView.workflowAppleSentinelID
    }

    /// v1.7 M1 PR-5：当前是否在「Android 工作流」模式。
    private var isWorkflowAndroidMode: Bool {
        selectedCategory == MainView.workflowAndroidSentinelID
    }

    /// v1.7 M1 PR-5：当前是否在「Web / Node 工作流」模式。
    private var isWorkflowWebNodeMode: Bool {
        selectedCategory == MainView.workflowWebNodeSentinelID
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
            } else if isUndoHistoryMode {
                // Step 7：「最近清理」整段独立 —— 只读+恢复按钮，不复用扫描状态栏。
                UndoHistoryScreen()
            } else if isMaintenanceMode {
                // M4-T4 / 2026-06：「系统维护」整段独立 —— 三按钮 + outcome list，
                // 自带 detached Task 执行 / 状态指示，不复用扫描进度 / 删除 UI。
                MaintenanceScreen()
            } else if isLipoMode {
                // F-2-3 / 2026-06：Lipo 通用二进制瘦身 —— 自带 audit / extract，
                // 完全脱离 ScanCoordinator / SafetyEngine 链路。
                LipoScreen()
            } else if isBrewMode {
                // F-2-4 / 2026-06：Homebrew 包管理 —— 直接读 Cellar / Caskroom，不执行 brew。
                BrewScreen()
            } else if isWorkflowAppleMode {
                // v1.7 M1 PR-5：Apple 工作流（Xcode / Simulator / DerivedData per-project / DeviceSupport）
                // 复用 WorkflowDetailView 通用渲染壳，数据源 AppleWorkflow.cards + WorkflowRegistry.resolve。
                // pipeline 透传 MainView 持有的 TrashPipeline 实例，删除走 NSWorkspace.recycle。
                WorkflowDetailView(workflow: AppleWorkflow(),
                                   pipeline: pipeline,
                                   accessDeniedPathsProvider: { accessDeniedPathsSnapshot() })
            } else if isWorkflowAndroidMode {
                // v1.7 M1 PR-5：Android 工作流（gradle / .android / AVD / SDK / Android Studio）。
                WorkflowDetailView(workflow: AndroidWorkflow(),
                                   pipeline: pipeline,
                                   accessDeniedPathsProvider: { accessDeniedPathsSnapshot() })
            } else if isWorkflowWebNodeMode {
                // v1.7 M1 PR-5：Web / Node 工作流（pnpm-store / yarn / npm / electron / node-gyp / scattered node_modules）。
                WorkflowDetailView(workflow: WebNodeWorkflow(),
                                   pipeline: pipeline,
                                   accessDeniedPathsProvider: { accessDeniedPathsSnapshot() })
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
                                            // **v1.5.3**：行内 trash 按钮 / 右键菜单 / Delete 键
                                            // 都走这一条单删通道（取代 v1.3.zzzz Phase 4-B 的批量入口）。
                                            triggerLargeFileTrash(urls: [url])
                                        },
                                        onRefreshSubtree: { path in
                                            // v2026.06 #1：右键"刷新此目录"。仅清 store-fallback 缓存，
                                            // 不重启 BulkScanner（成本太高），详见 ScanCoordinator.rescanSubtree。
                                            coordinator.rescanSubtree(at: path)
                                        },
                                        onStash: { row in
                                            // v2026.06.18：把 TreeRow 装进购物车。
                                            // 入口在 tree row contextMenu / "加入待处理"。
                                            stash.add(path: row.path,
                                                      title: row.title,
                                                      bytes: row.bytes,
                                                      isDirectory: row.isDirectory)
                                        },
                                        isStashed: { path in stash.contains(path) },
                                        aiSettings: aiSettings,
                                        onAskAI: { row in
                                            // v2026.06.20：tree 行 sparkles 按钮 → 复用 List 视图
                                            // 同一个 sheet 入口（aiAskingRow）。先把 TreeRow 映射成
                                            // RowItem 喂给 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)。
                                            // SafetyEngine.evaluate 与 List 路径一致，让 AI 在拒删时
                                            // 看到同样的 verdict / rejection 上下文。
                                            //
                                            // v1.5 P2 / Q3：走 requestAI 收敛 —— 未配置时弹 alert。
                                            let (v, rj) = TreeBrowserView.safety.evaluate(path: row.path)
                                            requestAI(row: RowItem(
                                                id: row.path,
                                                url: URL(fileURLWithPath: row.path),
                                                title: row.title,
                                                isDirectory: row.isDirectory,
                                                bytes: row.bytes,
                                                logicalBytes: row.bytes,
                                                fileCount: row.fileCount,
                                                verdict: v,
                                                rejection: rj,
                                                modificationDate: row.modificationDate
                                            ))
                                        },
                                        // v1.5 P2 / Q1：把全局排序键 binding 喂给树视图，
                                        // 工具栏排序图标切换或列头点击 → 全局键同步 →
                                        // 主列表 / 树形 / 大文件视图都按同一序展示。
                                        globalSortKey: Binding(
                                            get: { settings.mainListSortKey },
                                            set: { settings.mainListSortKey = $0 }
                                        )
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
                                    Text("tree.empty.no_roots", bundle: .module)
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

    /// 视图模式切换条（**v1.3.zzzz Phase 4-A 起：树形为主、清单降级**）。
    ///
    /// 设计与方案 C 对齐：
    /// - 左侧仍保留 segmented Picker 让两种视图可一键切换（兼顾 v1.0 - v1.2 老用户的肌肉记忆）
    /// - 但 segmented 宽度从 220 收到 180，并在右侧补一行"主视图"角标，让用户**首屏理解**"树是默认"
    /// - 提示文案从原来的"批量勾选请切回清单"改成中性说明，
    ///   避免暗示"清单才是干活视图"。批量删除能力沿用 [大文件批量页 (P1-5)](file:///Users/guoshuyu/workspace/GSYCleanMac) 与
    ///   清单视图，不强迫所有人切回清单
    private var viewModeBar: some View {
        HStack(spacing: 12) {
            Picker(selection: $viewMode) {
                ForEach(ResultsViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            } label: {
                Text("view_mode.picker.label", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)

            // 当前视图角标——告诉用户"你在看树形（主视图）"或"清单是二级 fallback"
            switch viewMode {
            case .tree:
                Label {
                    Text("view_mode.tree.tag", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.grid.1x2")
                }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .list:
                Label {
                    Text("view_mode.list.tag", bundle: .module)
                } icon: {
                    Image(systemName: "list.bullet")
                }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // 视图特定提示——中性说明操作方式，不再暗示"另一个视图才是正经的"
            switch viewMode {
            case .tree:
                Text("view_mode.tree.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .list:
                Text("view_mode.list.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var listResults: some View {
        // v1.5 P2 滑动卡顿修复：把 maxBytes 提到 ForEach 外，并量化到下一个 2 的幂次。
        //
        // 旧实现：`maxBytes: coordinator.snapshot.rows.first?.bytes ?? 0`
        //   1) 在 ForEach 闭包里每行都访问一次 snapshot.rows（每行都建立一次 observation）
        //   2) 扫描期主列表流式按 path 字典序排，首行 bytes 几乎每帧都在涨 →
        //      `maxBytes` 参与 RowContentView 的 Equatable 比较 → 每行都被判不相等 →
        //      Equatable 短路完全失效。
        // 现在：① 取最大 bytes（实际上扫描期已按 path 序，不再是按 size 序的首行——
        //   改用 `lazy.map(\.bytes).max()`，仍 O(N) 但只算一次；
        //   ② 量化到下一个 2 的幂次，让相邻帧大概率相等（10MB → 16MB，11MB 仍 16MB），
        //   命中 Equatable 短路 → 千行场景 body 调用数从"每帧 × N"降到接近 0。
        let maxBytesRaw = coordinator.snapshot.rows.lazy.map(\.bytes).max() ?? 0
        let maxBytes = Self.quantizeToPow2(maxBytesRaw)
        return List(selection: $detail) {
            ForEach(coordinator.snapshot.rows) { row in
                let isOn = Binding<Bool>(
                    get: { selection.contains(row.id) },
                    set: { newValue in
                        if newValue { selection.insert(row.id) }
                        else { selection.remove(row.id) }
                    }
                )
                RowView(row: row, selected: isOn,
                        maxBytes: maxBytes,
                        aiSettings: aiSettings,
                        // v1.5 P2 / Q3：走 requestAI 收敛 —— 未配置时弹 alert 引导设置。
                        onAskAI: { picked in requestAI(row: picked) })
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

    /// v1.5 P2：把任意正整数量化到下一个 2 的幂次（≤0 直接返回 0）。
    /// 让 maxBytes 在扫描流式帧之间保持"阶梯式增长"——相邻帧大概率相等，
    /// 配合 RowContentView 的 Equatable 比较实现真正的 body 短路。
    static func quantizeToPow2(_ x: Int64) -> Int64 {
        guard x > 0 else { return 0 }
        // bit_length(x) = 64 - leadingZeroBitCount；2^(bit_length) 即"≥x 的最小 2 的幂"。
        let lz = x.leadingZeroBitCount
        let bits = 64 - lz
        if bits >= 63 { return Int64.max }
        return Int64(1) << bits
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
                    onOpenFilesAndFolders: {
                        // v2026.06 #1：跳「文件与文件夹」面板（Files & Folders 类目）。
                        // 这是 macOS 14+ Downloads/Documents/Desktop 的实际授权开关，
                        // 与 FDA 无关。anchor ID 不同——`Privacy_FilesAndFolders`。
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
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
            // v2026.06.21：原"勘察超时 / 结果已截断" banner 已整体移除。
            // 用户明确反馈：进入这种状态本身就是异常，不应该让用户看到内部限流状态。
            // 配合 [DevArtifactScanner.Options.maxHits](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/DevArtifactScanner.swift)
            // 默认值改为 .max（实际永远不截断），devArtifactDidTruncate /
            // devArtifactDidTimeout 字段仅保留作内部诊断，UI 不再读。
            HStack {
                if coordinator.isScanning {
                    // v2026.06.21 perf F2：`coordinator.perRootProgress` 是 computed property，
                    // 内部 merging O(N) 两个字典，原本在同一 body 帧里被 L1440（isEmpty 判断）
                    // 和 L1468（values.sorted）各访问一次 → 重复算两次 merge，N=几百根时
                    // 是肉眼可见的滑动卡顿。在 HStack 顶端提一个 local let，body 帧内只算一次。
                    let perRoot = coordinator.perRootProgress
                    if perRoot.isEmpty {
                        // v2026.06.18：单根扫描信息显著增强。
                        // 用户反馈："正在扫描能不能加个进度？扫了百分之多少，预计还剩多少时间"。
                        // 数据源：
                        //   - 百分比 / 进度条 ← `expectedTotalBytes` 已估出 → snapshot.totalBytes / expected
                        //   - ETA ← snapshot.estimatedRemaining（由 publishSnapshot 基于 EWMA 速率算）
                        //   - 已用时间 ← snapshot.elapsed
                        // 三者都没估出来时退化回最原始的"扫描中… N 文件 · X MB"，与旧版完全一致，
                        // 不会出现"进度条挂在 0% 不动"的误导。
                        singleRootProgress
                    } else {
                        ProgressView().controlSize(.small)
                        // v1.3：多根并行扫描——按 rootPath 字典序输出多行（每根一条），
                        // 已 finished 的根用 ✓ 替代 ●，文案"{title} · {bytes} · {fileCount} 文件"。
                        // 字典序稳定排序：避免 dict 遍历顺序导致行序抖动。
                        //
                        // v1.5：dev scan discover 阶段命中几十/几百根时这里直接平铺会把
                        // toolbar 下窄区撑爆（用户截图 2/3 反馈"很丑很奇怪 / 不能滑动"）。
                        // 用 ScrollView + frame(maxHeight:) 限到 ~120pt（约 6 行），让
                        // 多余的根在内部滚动而非把整个 statusBar 顶高。
                        // 同时 0 字节期间用 `--` 占位避免"Zero KB · 0 文件"持续闪烁。
                        //
                        // v1.5 性能修复：之前用裸 `VStack { ForEach }` 平铺 → 几百行时
                        // 即便外层 ScrollView 限高，SwiftUI 仍然会一次性 measure/layout 所有
                        // 子 view，再加上每 0.4s publishSnapshot + 多次 .finished 立即 publish
                        // 触发的整体重 diff，整个列表/sidebar 滑动都会卡。
                        // 改 `LazyVStack` 让只有窗口内的 ~6 行真正参与 measure/layout，
                        // 几百行时主线程 frame budget 立刻回归 60fps。
                        let rows = perRoot.values.sorted(by: { $0.rootPath < $1.rootPath })
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(rows, id: \.rootPath) { p in
                                    HStack(spacing: 4) {
                                        Text(p.isFinished ? "✓" : "●")
                                            .font(.caption.bold())
                                            .foregroundStyle(p.isFinished ? Color.green : Color.accentColor)
                                        let bytesText: String = (p.bytes <= 0 && p.fileCount <= 0)
                                            ? String(localized: "progress.size.placeholder", bundle: .module)
                                            : formattedBytes(p.bytes)
                                        Text(String(format: String(localized: "main.scan.progress.multi.row", bundle: .module), p.title, bytesText, p.fileCount))
                                            .font(.callout)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: multiRootProgressScrollMaxHeight)
                    }
                } else if coordinator.snapshot.isFinished {
                    Text(String(format: String(localized: "main.scan.finished", bundle: .module), coordinator.snapshot.scannedFileCount, formattedBytes(coordinator.snapshot.totalBytes), String(format: "%.2fs", coordinator.snapshot.elapsed)))
                        .font(.callout)
                } else if coordinator.wasCancelled {
                    // v1.3：cancel 后区分"已停止"与"还未扫描"两态，避免用户以为停止键失灵
                    Text("main.scan.cancelled", bundle: .module)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    // v1.3：未扫描态显式文案，避免空 snapshot 渲染成 "0 KB · 0 个文件" 误导用户。
                    // 区分两种 pristine：已选类目但未点扫 / 完全没选类目。
                    if selectedCategory != nil {
                        Text("results.empty.idle.with_top_buttons", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        Text("results.empty.idle.with_left_picker", bundle: .module)
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
                Text("results.empty.title", bundle: .module)
                    .foregroundStyle(.secondary)
                Text("results.empty.no_results.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .scanning:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("results.scanning", bundle: .module)
                    .foregroundStyle(.secondary)
                Text("main.scan.first.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .finishedEmpty(let rootPath):
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("results.empty.nothing_to_clean", bundle: .module)
                    .foregroundStyle(.secondary)
                sentinelAwareRootPathText(rootPath)
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
                    Label {
                        Text("results.empty.try_other_dir", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// v2026.06.21：placeholder 的 `.finishedEmpty(rootPath)` 分支会拿 `currentRootPath`
    /// 直接渲染。当多根/开发者构建产物/开发者旧版本扫描走伪根时，
    /// rootPath 是 [ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L185)
    /// 里定义的英文 sentinel ID，不该当作真实路径展示——这里映射到对应
    /// `path.sentinel.*` xcstrings key 走本地化显示；非 sentinel 仍按原路径打印。
    @ViewBuilder
    private func sentinelAwareRootPathText(_ rootPath: String) -> some View {
        switch rootPath {
        case ScanCoordinator.multiRootSentinelPath:
            Text("path.sentinel.multi_root", bundle: .module)
        case ScanCoordinator.developerSentinelPath:
            Text("path.sentinel.dev_artifact", bundle: .module)
        case ScanCoordinator.versionedRootSentinelPath:
            Text("path.sentinel.versioned_root", bundle: .module)
        default:
            Text(rootPath)
        }
    }

    private var footerBar: some View {
        HStack {
            if isLargeFilesMode {
                Text(largeFileSelection.map {
                    String(format: String(localized: "footer.selection.large_file %@ %@", bundle: .module), $0.title, formattedBytes($0.bytes))
                } ?? String(localized: "selection.empty", bundle: .module))
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
                    Label {
                        Text("toolbar.delete.move_to_trash", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
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
                    Label {
                        Text("toolbar.delete.move_to_trash", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
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
                LabeledContent(String(localized: "detail.size.physical", bundle: .module), value: formattedBytes(item.bytes))
                LabeledContent(String(localized: "detail.size.logical", bundle: .module), value: formattedBytes(item.logicalBytes))
                LabeledContent(String(localized: "detail.file.count", bundle: .module), value: "\(item.fileCount)")
                LabeledContent(String(localized: "detail.is.directory", bundle: .module), value: item.isDirectory ? String(localized: "detail.bool.yes", bundle: .module) : String(localized: "detail.bool.no", bundle: .module))
                LabeledContent(String(localized: "detail.safety.level", bundle: .module), value: verdictLabel(item.verdict))
                if item.verdict == .forbid {
                    Text(String(format: String(localized: "detail.rejection.reason", bundle: .module), item.rejection.rawValue))
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
                LabeledContent(String(localized: "detail.size", bundle: .module), value: formattedBytes(row.bytes))
                LabeledContent(String(localized: "detail.file.count", bundle: .module), value: "\(row.fileCount)")
                LabeledContent(String(localized: "detail.is.directory", bundle: .module), value: row.isDirectory ? String(localized: "detail.bool.yes", bundle: .module) : String(localized: "detail.bool.no", bundle: .module))
                if row.isDirectory && row.hasChildren {
                    LabeledContent(String(localized: "detail.expandable", bundle: .module), value: String(localized: "detail.bool.yes", bundle: .module))
                }
                Divider()
                Text("detail.tree.hint", bundle: .module)
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
        // v2026.06.21：原右上角「推荐 / 开发者 / 整盘」三个 logo 按钮直接移除——
        // 用户反馈这三个入口长期占位制造视觉噪音；功能可达性由 sidebar 的
        // 「批量扫描」分组完整承担，toolbar 右侧只保留：全局排序 + 购物车 + 单一
        // [scanControlButton](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1762)
        // （重新扫描 / 扫描中）。helpers triggerRecommendedScan / triggerDeveloperScan /
        // triggerFullDiskScan 保留，sidebar onChange 仍在用。
        // v2026.06.18 购物车入口。count==0 时整项隐藏（避免 toolbar 永远多出
        // 一个"空购物车"按钮造成视觉噪音）。SwiftUI ToolbarItem 内 if 分支会让
        // 该 item 在 layout 阶段被剔除，无需特殊处理。
        ToolbarItem(placement: .primaryAction) {
            stashToolbarButton
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
            Picker(selection: $settings.mainListSortKey) {
                ForEach(MainListSortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            } label: {
                Text("sort.menu.label", bundle: .module)
            }
            .pickerStyle(.inline)
        } label: {
            Label(settings.mainListSortKey.label, systemImage: "arrow.up.arrow.down")
        }
        .help(String(localized: "sort.menu.help", bundle: .module))
    }

    /// v2026.06.21：是否需要在切换 category 前弹确认。
    /// 判定口径："用户切走后会丢失"的状态都算——任一为真即弹：
    ///   - 当前在扫描（无论哪类入口）
    ///   - 主 snapshot 有 row（普通 category / batch 完成后留存）
    ///   - perRoot 还有 active 行（batch 扫描中间态）
    ///   - perRoot 有 finished 行（batch 完成后留存）
    /// 不能光靠 `coordinator.snapshot.isFinished` 判定：batch 扫描在 sidebar
    /// 留存的不是 snapshot.rows，而是 perRootFinishedSlim。
    private var shouldConfirmCategorySwitch: Bool {
        if coordinator.isScanning { return true }
        if !coordinator.snapshot.rows.isEmpty { return true }
        if !coordinator.perRootProgressActive.isEmpty { return true }
        if coordinator.perRootFinishedCount > 0 { return true }
        return false
    }

    /// v2026.06.21：原 onChange(selectedCategory) 的 body 抽出来，供"无须确认"与
    /// "已确认" 两条路径共用，避免把"分发到 trigger* / runHeavyAfterCommit"逻辑
    /// 复制到 confirmationDialog 的回调里去（一旦后续加 sentinel 又得改两处）。
    private func applyCategorySwitch(from old: String?, to new: String?) {
        if let id = new, ScanCategory.batchScanIDs.contains(id) {
            switch id {
            case ScanCategory.batchRecommendedID:
                triggerRecommendedScan()
            case ScanCategory.batchDeveloperID:
                triggerDeveloperScan()
            case ScanCategory.batchFullDiskID:
                triggerFullDiskScan()
            default:
                // v1.5 review-fix #1：batchScanIDs 已穷尽 3 个 case；future 加 sentinel
                // 必须同步加 case，否则 selection 切到新 sentinel 会被静默吞掉。
                assertionFailure("Unhandled batch scan sentinel id: \(id) — add case to MainView.applyCategorySwitch switch.")
            }
            return
        }
        resetSelectionState()
        // M4-T2 / 2026-06：开发者版本化收集根扫描 sentinel —— 不在 allCategories 里，
        // 由 ScanCoordinator.scanKnownVersionedRoots(home:) 同步派发命中。
        // 必须在 allCategories.first 之前拦截，否则会走 startScan(category:) 找不到 cat 直接 return。
        if let id = new, id == MainView.devVersionedSentinelID {
            runHeavyAfterCommit {
                coordinator.scanKnownVersionedRoots(
                    home: FileManager.default.homeDirectoryForCurrentUser)
            }
            return
        }
        guard let id = new, let cat = allCategories.first(where: { $0.id == id }) else { return }
        // v2：统一走 [runHeavyAfterCommit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeavyTask.swift)
        // 模板（detached + sleep 16ms + MainActor.run），让 SwiftUI 先把
        // 「sidebar 高亮 / 旧 detail 清空 / loading 状态」这一帧 commit 出去再开始扫。
        // 这样 Preferences 这种条目巨多的目录入扫时不再卡彩虹球。
        runHeavyAfterCommit {
            startScan(category: cat)
        }
    }

    /// v1.5：把 toolbar「全部推荐扫描」按钮的逻辑抽成 helper，供 sidebar Batch Scans
    /// 入口复用。除了起扫还把 selectedCategory 同步到 batch sentinel，让 sidebar
    /// 蓝条高亮跟手——没有这一步用户感知不到自己当前在跑哪条。
    ///
    /// v1.5 review-fix #2：reset 由 helper 唯一负责（onChange 在 batch.* 分支不再 reset）。
    /// 这是因为 toolbar 重复点同一按钮时 selection 没变 onChange 不触发，必须 helper 兜底。
    /// review-fix #12：可见性收紧到 private，与 triggerFullDiskScan 一致。
    private func triggerRecommendedScan() {
        resetSelectionState()
        selectedCategory = ScanCategory.batchRecommendedID
        coordinator.scanRecommended(includeHidden: settings.showHidden)
    }

    /// v1.5：开发者扫描的统一入口，理由同上。
    private func triggerDeveloperScan() {
        resetSelectionState()
        selectedCategory = ScanCategory.batchDeveloperID
        coordinator.scanDeveloper(includeHidden: settings.showHidden,
                                  enabledRuleIDs: settings.enabledDevArtifactRuleIDs)
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
            TextField(String(localized: "pathbar.placeholder", bundle: .module), text: $pathBarInput)
                .textFieldStyle(.plain)
                .focused($pathBarFocused)
                .frame(minWidth: 220, idealWidth: 320)
                .onSubmit { submitPathBar() }
                .help(String(localized: "pathbar.help", bundle: .module))
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

    /// v2026.06.18 **稍后处理（待处理）**入口。
    ///
    /// 行为：
    /// - `stash.count == 0` → 整按钮 `.hidden`（toolbar 视觉收敛，没东西不暴露入口）
    /// - `stash.count > 0`  → 显示 `tray.full.fill` 工作托盘图标 + 右上角红色数字徽标
    /// - 点击：把 [isStashScreenPresented](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) 翻 true，
    ///   主体的 `.sheet` 监听该 flag 弹 [StashScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashScreen.swift)
    ///
    /// v2026.06.20 用户反馈：之前用 `cart.fill` 图标 + Label 文本里夹一个 `(N)`，
    /// 既看着像电商购物车（语义不对——这是"工作待处理"，不是"购物清单"），数字也
    /// 被混在 toolbar Label 文本里，远不如直接把数量做成"角标"那样一眼可见。
    /// 改成：自定义 label = Image(`tray.full.fill`) + `.overlay` 一个胶囊红角标显示
    /// 实时 `stash.count`；超过 99 显示 `99+` 避免角标过宽撑爆 toolbar 槽位。
    @ViewBuilder
    private var stashToolbarButton: some View {
        if stash.count > 0 {
            Button {
                isStashScreenPresented = true
            } label: {
                Label {
                    Text("toolbar.stash.title", bundle: .module)
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "tray.full.fill")
                        stashCountBadge
                            .alignmentGuide(.top) { d in d[.top] + 2 }
                            .alignmentGuide(.trailing) { d in d[.trailing] - 2 }
                    }
                }
            }
            .help(String(format: String(localized: "toolbar.stash.help_with_count", bundle: .module),
                         stash.count))
        }
    }

    /// 待处理数量徽标（红底白字胶囊），独立成 ViewBuilder 便于阅读 + 复用样式。
    /// 1~99 显示真实数；≥100 显示 `99+`，避免 toolbar 角标过宽。
    @ViewBuilder
    private var stashCountBadge: some View {
        let display = stash.count > 99 ? "99+" : "\(stash.count)"
        Text(display)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
            )
            .offset(x: 6, y: -4)
            .accessibilityHidden(true)
    }

    /// 现有的"停止 / 重新扫描"按钮，按当前状态二选一。
    @ViewBuilder
    private var scanControlButton: some View {
        if coordinator.isScanning {
            Button(role: .cancel) {
                coordinator.cancel()
            } label: {
                Label {
                    Text("toolbar.scan.stop", bundle: .module)
                } icon: {
                    Image(systemName: "stop.circle")
                }
            }
                .help(String(localized: "toolbar.help.stop", bundle: .module))
        } else if let id = selectedCategory, let cat = allCategories.first(where: { $0.id == id }) {
            Button {
                // v1.3：统一走 resetSelectionState()，避免重新扫描后 detail/treeSelection 残留
                resetSelectionState()
                startScan(category: cat)
            } label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .help(String(localized: "toolbar.help.rescan", bundle: .module))
        } else if selectedCategory == MainView.devVersionedSentinelID {
            // v2026.06.21：开发者旧版本扫描 sentinel 不在 allCategories 里，
            // 上面 `allCategories.first` 永远拿不到 cat，重新扫描按钮就没了
            // （用户截图反馈"那个常驻重新扫描按键哪里去了"）。这里专门走一支。
            Button {
                resetSelectionState()
                coordinator.scanKnownVersionedRoots(
                    home: FileManager.default.homeDirectoryForCurrentUser)
            } label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .help(String(localized: "toolbar.help.rescan", bundle: .module))
        } else if let id = selectedCategory, ScanCategory.batchScanIDs.contains(id) {
            // v2026.06.21：批量扫描三条（推荐 / 开发者 / 整盘）sentinel 也走 trigger* helper，
            // 之前 scanControlButton 仅在 allCategories.first(cat) 命中时才出现，
            // 这三个 sentinel 不在 allCategories 里 → 用户反馈"推荐扫描右上角没有重新扫描按键"。
            // 这里按 sentinel id 分发到 helper（helper 自己负责 resetSelectionState 与起扫）。
            Button {
                switch id {
                case ScanCategory.batchRecommendedID:
                    triggerRecommendedScan()
                case ScanCategory.batchDeveloperID:
                    triggerDeveloperScan()
                case ScanCategory.batchFullDiskID:
                    triggerFullDiskScan()
                default:
                    assertionFailure("Unhandled batch scan sentinel id: \(id) — add case to MainView.scanControlButton switch.")
                }
            } label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .help(String(localized: "toolbar.help.rescan", bundle: .module))
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
            deleteResult = String(format: String(localized: "delete.result.path_invalid %@", bundle: .module), url.path)
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
    /// v1.5：与 triggerRecommendedScan / triggerDeveloperScan 对齐——sidebar 高亮
    /// 落在 batch.fulldisk sentinel 上（而不是单根 fullDisk.id 类目），让"批量扫描"
    /// 三条入口在视觉上是平等的一组。直接调 coordinator API，不再走 selectedCategory →
    /// onChange → startScan(category:) 的旧链路（避免高亮被绕回 fullDisk.id）。
    /// v1.5 review-fix #2：reset 由 helper 唯一负责（onChange 在 batch.* 分支不再 reset）。
    private func triggerFullDiskScan() {
        resetSelectionState()
        selectedCategory = ScanCategory.batchFullDiskID
        coordinator.scanFullDisk(includeHidden: settings.showHidden)
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

    /// v1.5 P2 / Q3：统一的"用户请求问 AI"入口。
    ///
    /// 行为：
    /// - AI 已就绪（`aiSettings.isReadyForUI`）→ 把 row 喂给 `aiAskingRow` 弹
    ///   [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
    /// - 未就绪 → 翻 `aiUnconfiguredAlert`，弹"前往设置？"alert，用户确认走 openSettings()
    ///
    /// 这是 Q3 修复的核心收敛点：所有 onAskAI callsite（List / Tree / Stash）
    /// 都走这里，避免散落判断 isReadyForUI 又散落 alert，将来语义有变只改一处。
    private func requestAI(row: RowItem) {
        if aiSettings.isReadyForUI {
            aiAskingRow = row
        } else {
            aiUnconfiguredAlert = true
        }
    }

    private var selectedRows: [RowItem] {
        coordinator.snapshot.rows.filter { selection.contains($0.id) && $0.isSelectable }
    }

    private var selectionSummary: String {
        let rows = selectedRows
        if rows.isEmpty { return String(localized: "selection.empty", bundle: .module) }
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        return String(format: String(localized: "selection.summary %lld %@", bundle: .module), rows.count, formattedBytes(total))
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

    /// v2026.06.18 把购物车里的 [StashEntry](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift#L35-L51)
    /// 转成 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
    /// 需要的 [RowItem](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L6-L60)。
    /// 因为 AIAdviceSheet 只读 title / url / bytes / verdict 等基础字段做请求拼装，
    /// 不需要 logicalBytes / vendor 等填值——这里全部走兜底常量 0/.nil 即可。
    /// `verdict` 现场调一次 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L212)
    /// 拿语义，让 AI sheet 也能看到本地三档闸的初判。
    private func makeAIQueryRow(from entry: StashStore.StashEntry) -> RowItem {
        let (verdict, rejection) = TreeBrowserView.safety.evaluate(path: entry.path)
        return RowItem(
            id: entry.path,
            url: URL(fileURLWithPath: entry.path),
            title: entry.title,
            isDirectory: entry.isDirectory,
            bytes: entry.bytes,
            logicalBytes: entry.bytes,
            fileCount: 0,
            verdict: verdict,
            rejection: rejection
        )
    }

    /// **v2026.06.18**：把 TimeInterval 渲染成"1h 23m 04s / 5m 12s / 47s"等紧凑文案。
    /// 与 [FloatingScanHUD.durationString](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
    /// 风格保持一致——状态栏和悬浮窗看到的剩余时间口径同源，避免割裂。
    /// 负数 / NaN / +inf 一律按 0 处理（防呆，UI 永远不会出现 "-3s"）。
    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    /// **v2026.06.18**：单根扫描态信息区。
    /// 三段式：
    ///   行1（顶部）：进度条（有分母 → 真比例条；无分母 → 不确定 ProgressView）
    ///   行2（主行）：扫描中… N 个文件 · X MB（与旧版完全一致，保证不回归）
    ///   行3（副行）：百分比 + 已扫/预计 + 已用/剩余时间（按数据可用程度逐步显示）
    /// 没有 expectedTotalBytes 时 行1 / 行3 仍然展示，给出"已用时间 · 估算中…"，
    /// 让用户看得到"系统还在算"，不会以为程序卡了。
    ///
    /// v2026.06.20 修：用户反馈"扫 workspace 进度条直接 100%，但后续还要扫好久"。
    /// 根因：[TreeSizeEstimator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TreeSizeEstimator.swift)
    /// 4s 软超时；走完不了的根（含 `~/workspace` / `~/Library/Caches` 这种几十万 inode 的根）
    /// 拿到一个**严重低估**的 expectedTotalBytes。BulkScanner 真实 ingest 字节很快就把这个数顶穿，
    /// 旧版用 `min(1.0, ...)` 把 fraction 钳在 1.0，UI 表现为"100% 卡很久"。
    ///
    /// 新策略：把"已扫 > 估算分母"识别为"估算不可靠"，分两层处理：
    /// 1. 比率层：当 `scanned > expected` 时，**抛弃** expected 退化成不确定进度条
    ///    （ProgressView() 的 spinner），而不是钉在 100%。
    /// 2. 文案层：仍然显示 `已扫 X · 已用 T`，但不再骗用户"还有 N MB"，
    ///    改为"估算偏小，仍在扫描…"提示，鼓励用户耐心等待。
    /// 同时 ETA 在 ScanCoordinator [publishSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 那侧也加了同样的"denom > scanned"卫语：分母穿透时本帧不出 ETA（旧版 ETA 必然算成负值再被钳成 0，
    /// UI 上"剩余 0s"持续闪烁，体验同样误导）。
    @ViewBuilder
    private var singleRootProgress: some View {
        let scanned = coordinator.snapshot.totalBytes
        let expected = coordinator.expectedTotalBytes
        let elapsed = coordinator.snapshot.elapsed
        let eta = coordinator.snapshot.estimatedRemaining

        // 0~1 比例。expected 缺失 / scanned > expected（估算偏小）时退化为 nil → 不确定进度。
        // **v2026.06.20**：去掉旧的 `min(1.0, ...)` 钳位——分母被穿透就直接 nil，
        // 让 UI 切回 indeterminate ProgressView，不再让用户误以为快完成了。
        let estimateOvershoot = (expected.map { scanned > $0 } ?? false)
        let fraction: Double? = {
            guard let exp = expected, exp > 0, !estimateOvershoot else { return nil }
            return max(0.0, Double(scanned) / Double(exp))
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let f = fraction {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 180)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(String(format: String(localized: "main.scan.progress.single", bundle: .module),
                            coordinator.snapshot.scannedFileCount,
                            formattedBytes(scanned)))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if let f = fraction, let exp = expected {
                    Text(String(format: String(localized: "main.scan.progress.percent", bundle: .module),
                                Int(f * 100),
                                formattedBytes(scanned),
                                formattedBytes(exp)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // v2026.06.22：用户反馈"144G/13.75G 那个 13.75G 是什么意思？"
                        // 文案已经从 "/ ~%@" 改成 "· 预估约 %@"，再叠一层 tooltip 把口径讲清，
                        // 杜绝"被误读为磁盘总容量"的歧义（TreeSizeEstimator 4s 软估算可能严重偏小）。
                        .help(Text("main.scan.progress.percent.tooltip", bundle: .module))
                } else if estimateOvershoot {
                    // **v2026.06.20**：分母被穿透——明确告诉用户"估算偏小，还在扫"，
                    // 避免老 UI"100% / -0s 剩余"造成的"是不是卡死了"误判。
                    Text("main.scan.progress.estimate_low", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let eta {
                    Text(String(format: String(localized: "main.scan.progress.eta", bundle: .module),
                                formatDuration(eta),
                                formatDuration(elapsed)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: String(localized: "main.scan.progress.elapsed", bundle: .module),
                                formatDuration(elapsed)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // FIXME: emoji removed 2026-05-25
    private func verdictLabel(_ v: SafetyVerdict) -> String {
        switch v {
        case .safe: return String(localized: "main.delete.safety.safe", bundle: .module)
        case .confirm: return String(localized: "main.delete.safety.confirm", bundle: .module)
        case .forbid: return String(localized: "main.delete.safety.forbid", bundle: .module)
        }
    }

    /// v2026.06.17 (AUDIT A4)：`performDelete` 与 `triggerLargeFileTrash` 共用的
    /// pipeline 调用结果，callsite 自行处理 pruneDeleted / bytes 统计 / 关 sheet 等场景化逻辑。
    @MainActor
    private struct TrashRunResult {
        let moved: Int
        let skipped: Int
        let err: String?
        let pairs: [(String, String)]
    }

    /// v2026.06.17 (AUDIT A4)：抽出 `performDelete` 与 `triggerLargeFileTrash` 重复的
    /// **pipeline 4 步握手** ——
    /// (1) accessDenied 注入；(2) moveToTrashReturningOutcome；(3) UndoHistory 写入；(4) outcome → sheet/alert。
    ///
    /// 抽这步是因为两条链路任何一处忘了 setAccessDeniedPaths 或忘了消费结构化 outcome
    /// 都会让"上层防护漏失 / 结构化 sheet 退化为文本 alert"的回归在 PR review 时几乎不可能被发现——
    /// 既然只剩一份真实现就把契约集中在一个方法里，强制单点维护。
    ///
    /// **不抽**的部分（特意保留在 callsite）：isDeleting sheet 控制、bytes 统计、
    /// pruneDeleted（performDelete 在删后；triggerLargeFileTrash 在删前做乐观更新）、
    /// selection.removeAll / largeFileSelection=nil、refreshVolumeCapacity——
    /// 这些是两条链路的语义差异点（dryRun vs 强制真删 / 阻塞 sheet vs 乐观更新 / 主清单 vs 大文件单点），
    /// 强行融合会让 runTrash 变成"5 个回调参数"的胖方法，掩盖差异反而更危险。
    ///
    /// - Parameter source: UndoHistory 的 `source` 字段（"clean" / "large-file"），便于侧栏未来分类。
    /// - Parameter suppressSuccessSheet: 仅当 outcome 完全成功（无 failed/blocked/commandLine）时
    ///   抑制 OperationResultSheet 弹出。专为 stash 路径设计——见 v2026.06.21 修复 #3：
    ///   stash sheet 已经通过"item 消失"反馈成功，叠加一个全屏 sheet 体验割裂；但失败 / 拦截
    ///   仍要弹（用户在 stash 里只看到 item 消失，看不到"被 vendor 拦"，必须有显式入口）。
    @MainActor
    private func runTrash(paths: [String], dryRun: Bool, source: String,
                          suppressSuccessSheet: Bool = false) async -> TrashRunResult {
        // ① accessDenied 注入（防止历史 cast 被悄悄改丢、重新引入"漏调=误拒"）。
        // 见 [DeletionPipeline.setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift#L37)
        // 自 v2026.06.17 (AUDIT A2) 起取消 protocol extension 默认 no-op，每个实现都必须显式提供。
        pipeline.setAccessDeniedPaths(accessDeniedPathsSnapshot())
        // ② 真正调 pipeline，并用返回值里的 outcome 作为本轮权威结果。
        let result = await pipeline.moveToTrashReturningOutcome(paths: paths, dryRun: dryRun)
        let (moved, skipped, err, pairs) = result.legacy
        // ③ Step 7 UndoHistory：dryRun / 全 forbid / recycle err 时 pairs 都是空数组，addRecord 会 no-op 跳过。
        if !dryRun, err == nil, !pairs.isEmpty {
            UndoHistoryStore.shared.addRecord(
                source: source,
                filePairs: pairs.map { UndoHistoryStore.Record.FilePair(original: $0.0, trashed: $0.1) }
            )
        }
        // ④ 结构化 sheet / 旧 alert 二选一（v2026.06.16 修复 #4）。
        //
        // v2026.06.21 修复 #3：stash 路径开 suppressSuccessSheet——纯成功时不再叠 sheet。
        // 仅当 outcome 有 failed/blocked/commandLineSkipped 时才弹（用户需要看到非成功项）。
        let shouldSuppress: Bool = {
            guard suppressSuccessSheet, let outcome = result.outcome else { return false }
            let hasIssue = !outcome.failedPaths.isEmpty
                || !outcome.safetyRejected.isEmpty
            return !hasIssue
        }()
        if !shouldSuppress {
            presentTrashOutcome(moved: moved, skipped: skipped, err: err, dryRun: dryRun, outcome: result.outcome)
        }
        return TrashRunResult(moved: moved, skipped: skipped, err: err, pairs: pairs)
    }

    /// v2026.06.17 (AUDIT A4)：runTrash 的"结果呈现"子步骤——
    /// 真删（!dryRun）走结构化 sheet（`OperationResultPayload`），dryRun 仍走旧 alert
    /// （dryRun 不报失败明细，只看总数即可）。
    @MainActor
    private func presentTrashOutcome(moved: Int, skipped: Int, err: String?, dryRun: Bool, outcome: TrashOutcome?) {
        if !dryRun {
            if let outcome {
                deleteResultPayload = OperationResultPayload(outcome: outcome)
            } else if let err {
                // pipeline 没暴露结构化结果（如 stub 实现）→ 回退到旧 alert
                deleteResult = String(format: String(localized: "delete.result.failure %@ %lld %lld", bundle: .module), err, moved, skipped)
            } else {
                deleteResult = String(format: String(localized: "delete.result.success %lld %lld", bundle: .module), moved, skipped)
            }
        } else if let err {
            deleteResult = String(format: String(localized: "delete.result.failure.dryrun %@ %lld %lld", bundle: .module), err, moved, skipped)
        } else {
            deleteResult = String(format: String(localized: "delete.result.success.dryrun %lld %lld", bundle: .module), moved, skipped)
        }
    }

    private func performDelete(dryRun: Bool) async {
        let paths = selectedRows.map(\.url.path)
        // **v1.5.3**：真删（!dryRun）期间立刻拉起 ProgressView sheet。
        // dryRun 不动 isDeleting——预览不需要"正在删除"动画。
        if !dryRun {
            isDeleting = true
        }
        defer {
            if !dryRun {
                isDeleting = false
            }
        }
        // v2026.06.17 (AUDIT A4)：pipeline 4 步握手（accessDenied 注入 / moveToTrash / UndoHistory
        // 写入 / snapshotLastOutcome → sheet）统一收口到 [runTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)，
        // 与 [triggerLargeFileTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
        // 共用，避免两处独立维护"漏一步就放行"的脆弱契约。
        let result = await runTrash(paths: paths, dryRun: dryRun, source: "clean")
        if result.err == nil {
            if !dryRun {
                // HL 行为采集：真删之后才上报，dryRun 不污染统计
                await recorder.recordTrashed(paths: paths)
                // M4-T5：把这次成功移入废纸篓的字节数 / 类目记入 CleanStatsStore。
                // bytes 取自 selectedRows 与 pairs 的交集（pairs 是 NSWorkspace.recycle 真正成功的项），
                // 避免把"被 SafetyEngine 拦截"或"recycle 失败"的项也算进累计统计。
                let succeededPaths = Set(result.pairs.map(\.0))
                let movedBytes = selectedRows
                    .filter { succeededPaths.contains($0.url.path) }
                    .reduce(Int64(0)) { $0 + $1.bytes }
                if movedBytes > 0 {
                    let categoryID = coordinator.snapshot.categoryID
                    Task.detached { [movedBytes, categoryID] in
                        await CleanStatsStore.shared.record(
                            bytesReclaimed: movedBytes,
                            category: categoryID.isEmpty ? "unknown" : categoryID)
                    }
                }
                selection.removeAll()
                // **v2026.06.22 修复 #11**：把 `pruneDeleted` 从"删前/删后全候选"改成"删后只剔成功项"，
                // 杜绝旧实现"删除失败（被 vendor 规则 / accessDenied / recycle 异常拦下）也从 item 消失"的 bug。
                // 失败/拦截项保留在列表里，用户可在 [OperationResultSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/OperationResultSheet.swift)
                // 看到原因，并点「强制删除」走 [performForceDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)。
                let succeededOnly = result.pairs.map { $0.0 }
                if !succeededOnly.isEmpty {
                    coordinator.pruneDeleted(paths: succeededOnly)
                }
                // v1.3：删除完成后立即重探卷容量，sidebar 容量条会跟随变化（"清理后空闲变多"反馈）。
                // pruneDeleted 内部已调 refreshVolumeCapacity，这里保留 explicit 调用作为兜底。
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
        // Phase 3-A 协议化后：v1.3.zzzz 路线 B 之后 pipeline 只有 TrashPipeline 一份实现，走真清空。
        pipeline.setAccessDeniedPaths([])
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
    private func triggerLargeFileTrash(urls: [URL], suppressSuccessSheet: Bool = false) {
        guard !urls.isEmpty else { return }
        guard !isDeleting else { return } // 防重入：删除中不接受新点击
        let paths = urls.map(\.path)
        // **v2026.06.22 修复 #11/#12**：旧实现在删除「前」就 `pruneDeleted(paths)`（乐观更新），
        // 导致被 SafetyEngine / vendor 规则拦下的项也从大文件列表消失，用户看到"清理失败"但
        // item 已不见，找不到入口再点「强制删除」。新逻辑：删完后只 prune `result.pairs.map { $0.0 }`
        // （NSWorkspace.recycle 真成功的项），失败/拦截项继续留在列表里给用户重试。
        largeFileSelection = nil
        isDeleting = true
        Task { @MainActor in
            // v2026.06.17 (AUDIT A4)：与 performDelete 共享 [runTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
            // 的 pipeline 4 步握手：accessDenied 注入 / moveToTrash / UndoHistory 写入 /
            // snapshotLastOutcome → sheet。任何一步漏掉都会让"上层防护漏失 / 结构化 sheet
            // 退化为文本 alert"成为静默回归——统一收口后从语言层杜绝。
            //
            // v2026.06.21 修复 #3：把 stash 路径传入的 suppressSuccessSheet 透传——
            // 纯成功时不弹 OperationResultSheet，仅当真有失败 / 拦截才弹（避免 stash sheet
            // 关闭后用户被"多余的成功弹窗"困扰）。
            let result = await runTrash(paths: paths, dryRun: false, source: "large-file",
                                        suppressSuccessSheet: suppressSuccessSheet)
            isDeleting = false
            if result.err == nil {
                await recorder.recordTrashed(paths: paths)
            }
            // v2026.06.22：删完后只剔真成功的 paths——失败/拦截项继续留在大文件列表里。
            let succeededOnly = result.pairs.map { $0.0 }
            if !succeededOnly.isEmpty {
                coordinator.pruneDeleted(paths: succeededOnly)
            }
            coordinator.refreshVolumeCapacity()
        }
    }

    /// **v2026.06.22 新增（修复 #11 强制删除入口）**：从 [OperationResultSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/OperationResultSheet.swift)
    /// 「强制删除」按钮触发——把被 vendor 规则拦下的 paths 再次提交，走 [TrashPipeline.moveToTrashForce](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
    /// 路径绕过 vendor trie，但仍保留 SafetyEngine 所有硬安全网（hardForbidPrefixes / userRootForbidden /
    /// sensitiveCredential / systemVolume / hardForbidSuffixes）与 `accessDeniedPaths` 一票否决——
    /// 即真的"操作系统不允许"或"凭据 / 系统卷"绝不会被这条通道放行。
    ///
    /// 与 performDelete 不同的是：
    /// - 不再次进入 selection / dryRun 流程，直接拿调用方传入的 paths 走真删；
    /// - 不写 isDeleting sheet（用户已经在 OperationResultSheet 里，关闭后才看到结果）；
    /// - pruneDeleted 同样只剔真成功的 pairs；
    /// - 走独立 `source: "force"` 进 UndoHistory 便于侧栏识别。
    @MainActor
    private func performForceDelete(paths: [String]) async {
        guard !paths.isEmpty else { return }
        pipeline.setAccessDeniedPaths(accessDeniedPathsSnapshot())
        let result = await pipeline.moveToTrashForce(paths: paths, dryRun: false)
        let (moved, skipped, err, pairs) = result.legacy
        if err == nil, !pairs.isEmpty {
            UndoHistoryStore.shared.addRecord(
                source: "force",
                filePairs: pairs.map { UndoHistoryStore.Record.FilePair(original: $0.0, trashed: $0.1) }
            )
        }
        presentTrashOutcome(moved: moved, skipped: skipped, err: err, dryRun: false, outcome: result.outcome)
        let succeededOnly = pairs.map { $0.0 }
        if !succeededOnly.isEmpty {
            coordinator.pruneDeleted(paths: succeededOnly)
        }
        coordinator.refreshVolumeCapacity()
    }

    // MARK: - 自定义路径（添加 / 删除 / 拖拽）

    /// NSOpenPanel 选目录添加到 UserPathStore。
    /// 见 PITFALLS §5.6：默认 canChooseFiles=false 防误选单文件；多选避免反复弹窗。
    ///
    /// v2026.06 用户反馈 #2：原实现用 `panel.begin { ... }` modeless 弹窗，在某些场景下
    /// 会"卡死"——根因：SwiftUI menu/popover 收起时主窗口可能短暂失去 keyWindow 状态，
    /// `panel.begin` 内部 attach 不到 owner window，AppKit 转 fallback 走 modal mainloop
    /// 但 SwiftUI 同时还持有事件焦点 → 两边互等 → UI 假死。
    ///
    /// **修复**：优先 `beginSheetModal(for:)` 走 sheet（必有 owner），找不到主窗口才退回
    /// `runModal()`（同步阻塞但 NSOpenPanel 自己有事件循环，能正常返回）。
    /// 关键差异：`begin` 是 modeless（无 owner），后两者都有明确 owner 或独立 modal loop。
    private func addCustomPathViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "panel.choose_dir.title", bundle: .module)
        panel.prompt = String(localized: "panel.add", bundle: .module)

        let handleURLs: ([URL]) -> Void = { urls in
            guard !urls.isEmpty else { return }
            Task {
                for url in urls {
                    _ = await pathStore.add(url)
                }
                await refreshCustomPaths()
            }
        }

        // 优先 sheet：找一个仍在场上的 window 作为 owner。
        // NSApp.keyWindow 失活时 fallback 到 mainWindow / windows.first。
        let owner = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        if let owner {
            panel.beginSheetModal(for: owner) { response in
                guard response == .OK else { return }
                handleURLs(panel.urls)
            }
            return
        }

        // 无任何可用 window：退到独立 modal loop。runModal 是同步的，
        // 但 NSOpenPanel 自带 event loop，不会让主线程死锁——只会阻塞 ~人选完目录的时间。
        let response = panel.runModal()
        guard response == .OK else { return }
        handleURLs(panel.urls)
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
    /// v2026.06 #1：用户在 banner 上点「打开文件与文件夹访问设置」时跳的 URL。
    /// 与 FDA 是**两个独立类目**——开了 FDA 不会自动开它，必须各开各的。
    var onOpenFilesAndFolders: (() -> Void)? = nil
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
        case (let f, 0): return String(format: String(localized: "permission.banner.fda_only %lld", bundle: .module), f)
        case (0, let t): return String(format: String(localized: "permission.banner.tcc_only %lld", bundle: .module), t)
        case (let f, let t): return String(format: String(localized: "permission.banner.fda_and_tcc %lld %lld", bundle: .module), f, t)
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
        // v2026.06 用户反馈 #1：已开 FDA 但 denied 列表里全是 ~/Downloads / ~/Documents /
        // ~/Desktop 等"独立 TCC 类目"时，提示"打开 FDA"是错的——这些目录不归 FDA 管，
        // 用户开了 FDA 也不会解开。改为引导到 Files & Folders 类目。
        if needsFilesAndFolders {
            return String(localized: "permission.banner.action.open_files_and_folders", bundle: .module)
        }
        return fdaCount > 0
            ? String(localized: "permission.banner.action.open_fda", bundle: .module)
            : String(localized: "permission.banner.action.open_and_rescan", bundle: .module)
    }

    /// v2026.06 用户反馈 #1：判断"denied 列表是否需要 Files & Folders 类目"。
    ///
    /// macOS 14+ 把 Downloads / Documents / Desktop / Trash / 可移动卷 等抠出 FDA 范围，
    /// 单独走 [Files & Folders](https://support.apple.com/guide/security/sec29c19a25b/web)
    /// 类目（细粒度，逐 App 逐目录授权）。开关在
    /// 「系统设置 → 隐私与安全性 → 文件与文件夹」。
    ///
    /// 触发条件：
    /// - FDA 已 granted（或 unknown，"FDA 没开"那条路径更优先）；
    /// - denied 列表里至少有一条命中独立 TCC 类目的目录。
    private var needsFilesAndFolders: Bool {
        guard fdaStatus != .denied else { return false }
        return fdaDeniedPaths.contains(where: Self.isIndependentTCCCategory)
    }

    /// v2026.06 用户反馈 #1：判断一个路径是否属于"独立 TCC 类目"——
    /// 即开了 FDA **也**不会自动解开、必须单独授权的目录。
    /// 命中列表参考 Apple TCC 源码（`tccd` 的 `kTCCService*`）。
    static func isIndependentTCCCategory(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let hits = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/.Trash"
        ]
        for h in hits {
            if path == h || path.hasPrefix("\(h)/") { return true }
        }
        // 可移动卷 / 网络卷：单独 TCC 类目（kTCCServiceSystemPolicyRemovableVolumes /
        // NetworkVolumes），完全不在 FDA 范畴。
        if path.hasPrefix("/Volumes/") { return true }
        return false
    }

    /// v1.3.zz：检测"明明 FDA 已开却仍 denied"——多半 = 用户授权的是 .app，
    /// 但当前进程是 Debug build 或路径不一样的产物，TCC 按 codesign hash 索引匹不上。
    /// 或者 = denied 路径里全是 ~/.Trash 之类**独立 TCC**项（不属于 FDA 范畴）。
    ///
    /// v2026.06 #1：新增 Files & Folders 提示——已开 FDA 但 denied 列表里有
    /// ~/Downloads / ~/Documents / ~/Desktop 这种"独立 TCC 类目"，必须单独授权。
    private var diagnosticHint: String? {
        if needsFilesAndFolders {
            return String(localized: "permission.hint.files_and_folders", bundle: .module)
        }
        let trashDenied = fdaDeniedPaths.contains { $0.hasSuffix("/.Trash") }
        if fdaStatus == .granted && trashDenied {
            return String(localized: "permission.hint.trash_not_fda", bundle: .module)
        }
        if fdaStatus == .denied && fdaCount > 0 {
            return String(localized: "permission.hint.fda_denied", bundle: .module)
        }
        if fdaStatus == .unknown && fdaCount > 0 {
            return String(localized: "permission.hint.fda_unknown", bundle: .module)
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
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? LocalizedStringKey("mainview.path_chip.collapse")
                                  : LocalizedStringKey("mainview.path_chip.expand"),
                         bundle: .module)
                }
                    .buttonStyle(.plain)
                    .font(.caption)
                // v1.3：tcc-only 场景之前没有任何"主动授权"入口，
                // 现在两种场景都露出主行动按钮，文案因情境而异。
                if fdaCount > 0 || tccCount > 0 {
                    Button(actionLabel) {
                        if needsFilesAndFolders, let onOpenFilesAndFolders {
                            // v2026.06 #1：独立 TCC 类目 → 跳「文件与文件夹」面板，
                            // 与 FDA 是两个不同的开关，开了 FDA 也不会自动开它。
                            onOpenFilesAndFolders()
                        } else if let onRescan {
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
                            Text(String(format: String(localized: "banner.fda.denied.title", bundle: .module), fdaCount)).font(.caption).foregroundStyle(.orange)
                            ForEach(fdaDeniedPaths.prefix(50), id: \.self) { p in
                                Text(p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if fdaCount > 50 {
                                Text(String(format: String(localized: "banner.fda.denied.more", bundle: .module), fdaCount - 50)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if tccCount > 0 {
                            if fdaCount > 0 { Divider().padding(.vertical, 2) }
                            Text(String(format: String(localized: "banner.fda.tcc.title", bundle: .module), tccCount)).font(.caption).foregroundStyle(.blue)
                            ForEach(tccSkippedPaths.prefix(50), id: \.self) { p in
                                Text(p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if tccCount > 50 {
                                Text(String(format: String(localized: "banner.fda.tcc.more", bundle: .module), tccCount - 50)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text("banner.fda.tcc.privacy_note", bundle: .module)
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
