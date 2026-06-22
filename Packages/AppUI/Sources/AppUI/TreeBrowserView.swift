import SwiftUI
import AppKit
import Combine
import SafetyKit
import AIKit
import LogKit

/// v1.0 T3 / T5：多层下钻浏览器 + 列排序 + 键盘导航。
///
/// **v1.5.3 重构（用户反馈"选中 child 底部 delete 不可点击"）**：
/// 之前用「左侧 checkbox 多选 + 顶部 batchActionBar 批量按钮」的双轨方案
/// （所谓 v1.3.zzzz Phase 4-B），但 checkedPaths 是 TreeBrowserView 内部 @State，
/// 与 MainView 的 selection（基于 RowItem.id）完全独立——结果用户在树里勾选 child，
/// 主界面底部 delete 按钮永远 disabled。
///
/// 新方案：**完全移除 checkbox 列与批量 toolbar**，每一行右侧直接挂一个红色
/// trash 行内按钮，单击 = 立刻调 `onTrash(URL)` 走 NSWorkspace.recycle 单删。
/// 所见即所删，与 Pearcleaner / DaisyDisk 行内删除手感一致；底部 delete 按钮
/// 改为只服务"清单视图"场景，不再与树形耦合。
///
/// 设计要点（参考 DaisyDisk / OmniDS / Pearcleaner）：
/// 1. 用递归 DisclosureGroup（而不是 OutlineGroup）—— OutlineGroup 在 Swift 6 严格并发
///    下要求 KeyPath 形式预先把整棵树构建好，而我们的数据是 lazy 按需取的。
/// 2. children 走 lazy 计算：DisclosureGroup 展开时才向 ScanCoordinator 询问下一层，
///    避免一开始就构建整棵树（PITFALLS §5.4 同款，4w 文件不能一次性 yield 给 List）。
/// 3. 数据来源是 `ScanCoordinator.directChildren(of:sortedBy:)`，按当前 `sortKey` 排序。
/// 4. 行内右键菜单：在 Finder 中显示 / 复制路径 / 移到废纸篓（与行内 trash 按钮共用 onTrash）。
/// 5. T5 新增：
///    - 列表头：大小 / 名称 / 数量 三列，点击切排序，再点切升降序
///    - 键盘导航：j/k 上下移动选中、h 折叠当前、l 展开当前、Enter 切展开、
///      Cmd+R 在 Finder 显示、Delete 删除当前选中（走 SafetyEngine forbid 闸门）
///    - 选中态：当前选中行用 selection 高亮 + accessibility focus
public struct TreeBrowserView: View {
    let coordinator: ScanCoordinator
    /// v2026.06.21 perf：单独订阅 `coordinator.treeBrowser`（独立 ObservableObject）。
    /// 旧版用 `coordinator.structuralRevision` / `coordinator.childrenCacheVersion`
    /// 作 @Published mirror，导致 ScanCoordinator 任一 @Published 变化也都触发
    /// MainView/sidebar/listResults 整体失效（dev 扫场景每秒 ≥5 次 body 重算）。
    /// 现在 4 个 revision 字段从 ScanCoordinator @Published 移除，
    /// TreeBrowserView 单独通过本字段订阅 store —— MainView body 不再因
    /// structural / tick / treeRevision / childrenCacheVersion 失效。
    let treeBrowser: TreeBrowserStore
    let rootPath: String
    /// 选中行变化时的回调；MainView 用它把 TreeRow 喂给右侧详情面板。
    /// 设计 bug A：之前 selectedPath 只活在 TreeBrowserView 内部，
    /// 外层 detailPane 永远拿不到，导致"选中一行没有详情"。
    let onSelect: ((TreeRow) -> Void)?
    /// 右键 / Delete / 行内 trash 按钮触发"移到废纸篓"时的回调。
    /// 走 NSWorkspace.recycle 通道（与大文件视图右键删共用 triggerLargeFileTrash）。
    /// 给 nil 时 TreeNodeView 的右键菜单与行内 trash 按钮都不会展示，便于在 readonly 场景复用。
    let onTrash: ((URL) -> Void)?
    /// v2026.06 用户反馈 #1：右键"刷新此目录"。点击时传 path 给上层，
    /// 上层调 [ScanCoordinator.rescanSubtree(at:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1529-L1545)
    /// 清掉按需子树缓存并 bump structuralRevision，本视图下一帧自动重拉。
    /// 给 nil 时菜单不展示该项（便于在 readonly 场景复用）。
    let onRefreshSubtree: ((String) -> Void)?
    /// v2026.06.18 **加入待处理**回调（购物车）。点击 contextMenu 的"加入待处理"项
    /// 把 (path, title, bytes, isDirectory) 透给上层，由上层调
    /// [StashStore.add](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift#L80-L82) 入库。
    /// 给 nil 时菜单不展示该项（保持向后兼容；readonly / 无 stash 场景仍可复用）。
    let onStash: ((TreeRow) -> Void)?
    /// v2026.06.18 **是否已加入待处理**查询。contextMenu 用它把"加入待处理"按钮置灰
    /// + 改文案"已在待处理列表"。给 nil 时按 `false` 处理（旧 callsite 不受影响）。
    let isStashed: ((String) -> Bool)?
    /// v2026.06.20 **AI 设置**——决定 tree 行的 sparkles AI 按钮是否真正"可点"。
    /// nil（旧 callsite）或 `!isReadyForUI` → 按钮以 disabled + 提示 "请先在设置中配置 AI"
    /// 的形式出现（与 List 视图行为对齐），让用户知道有这个功能但需要先去配。
    let aiSettings: AISettings?
    /// v2026.06.20 **AI 入口回调**。给 nil（旧 callsite）时按钮根本不出现；
    /// 给值后无论 aiSettings 是否就绪都会出现按钮，未就绪时按 disabled。
    let onAskAI: ((TreeRow) -> Void)?

    /// v1.5 P2 / Q1：可选的"全局排序键" binding。
    ///
    /// 设计动机（review-swarm Q1 根因）：
    /// 之前 TreeBrowserView 自己持 `@State private var sortKey: TreeSortKey = .sizeDesc`，
    /// 与 [AppSettings.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift#L339)
    /// 完全解耦。结果用户在工具栏点"全局排序图标"切到 nameAsc，主列表反应了，
    /// 但切到「树形视图」依然是初始 sizeDesc，体验严重不一致。
    ///
    /// 现在给一个**可选** binding：
    /// - 有值（MainView 的 callsite 已升级）→ 列头点击 / 全局菜单切换双向同步
    /// - nil（测试桩 / 其它复用场景）→ fallback 走本地 @State，保持向后兼容
    let globalSortKey: Binding<MainListSortKey>?

    /// SafetyEngine 静态共享：拦截 forbid 路径（家目录、`/`、SIP、`..` 等），
    /// 在弹菜单 / 行内 trash 按钮 hit-test 时就 disabled，并附 tooltip 解释为什么不能删。
    static let safety = SafetyEngine()

    /// v2026.06.22 perf：path → SafetyVerdict 进程内缓存（**Instruments Time Profiler 取证**）。
    ///
    /// 33334.md（commit 5fe7e91 后第二刀取证）显示 [rebuildFlatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L411-L451)
    /// 一次跑 139ms 中 124ms（89%）全部在 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L212)：
    ///   - evaluateStandardized 58.8ms
    ///   - resolvedSymlinkPath 31.7ms（含 realpath syscall）
    ///   - URL.init(fileURLWithPath:) 11.7ms
    ///   - URL.standardizedFileURL.getter 6.9ms
    /// 这些都是 path-only 输入 → 进程生命周期内**确定性输出**（SafetyEngine 规则
    /// 库是编译期常量 + home 也是常量），完美适合纯路径缓存。
    ///
    /// 命中场景：扫描结束统一 rebuildFlatRows，或用户展开/排序触发局部重建时，上万节点的
    /// 99%+ path 是上一帧出现过的；patch 路径（[applyChildrenPatch](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L561)）
    /// 同理；选中态 fallback（[handleKeyboardSelectionMove](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L368)）
    /// 也基本命中。理论上单 path 加速倍数 = 1000x（dict get vs URL standardize + realpath）。
    ///
    /// 并发：computeVerdicts 调用者都在 MainActor 上，但为安全起见仍用 NSLock 保护
    /// （后续可能从 BG queue 触发 [filterDeletableForbiddenPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L881)）。
    /// NSLock 在无竞争场景接近 0 开销，完全 amortize。
    ///
    /// 容量上限 50k：dev 扫几百根 + 上万节点，按目录数估算 5w 上限足够覆盖；
    /// 超过 50k 直接 reset（不做 LRU 是因为 dev 工具单次会话规模可控，简洁优先）。
    private enum VerdictCache {
        nonisolated(unsafe) private static var cache: [String: SafetyVerdict] = [:]
        nonisolated(unsafe) private static let lock = NSLock()
        private static let maxEntries = 50_000

        static func verdict(for path: String) -> SafetyVerdict {
            lock.lock()
            if let hit = cache[path] {
                lock.unlock()
                return hit
            }
            lock.unlock()
            // 真算放在锁外：SafetyEngine.evaluate 可能 100us+，
            // 锁内只做 dict 读写，避免阻塞并发评估。
            let v = safety.evaluate(path: path).0
            lock.lock()
            if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
            cache[path] = v
            lock.unlock()
            return v
        }
    }

    /// v1.5 P2 / Q1：本地 fallback @State —— 仅在 `globalSortKey == nil` 时生效。
    /// 有 globalSortKey 时通过 `effectiveSortKey` 的 getter 优先读外部 binding，
    /// 这个 @State 完全不参与 body 渲染（也就不会触发额外 invalidation）。
    @State private var sortKey: TreeSortKey = .sizeDesc
    @State private var selectedPath: String?
    /// 各节点是否展开（path -> Bool）；放在父视图集中管理，
    /// 才能让 h/l 键盘事件去操控"当前选中节点"的展开状态。
    @State private var expanded: [String: Bool] = [:]
    /// **v1.5.3**：行内 trash 按钮 / 键盘 Delete 触发时不立即调外部 onTrash，
    /// 而是把 url 暂存在这里弹 [confirmationDialog](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)；
    /// 用户点"移到废纸篓"才真正调上层 onTrash → triggerLargeFileTrash → 真删。
    @State private var pendingTrashURL: URL?
    @FocusState private var focused: Bool

    /// **v1.5.4 性能修复**：扁平化的可见行数组（包含 root 直接孩子 + 所有展开节点的子项）。
    /// 每行附带 [depth](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 决定缩进，还有 [maxBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 用来归一化体积条。
    ///
    /// 旧版 [TreeNodeView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 在每个节点 body 内递归调 `coordinator.directChildren(...)` + 嵌套自身，
    /// 一次操作（含键盘的 4 次 visibleRows）等于把整棵展开树重新拍平多次，
    /// 4w 节点级 200~500ms 卡顿。改为 ForEach(flatRows) 顶层平铺后：
    /// - 重算只发生在 expanded / sortKey / rootPath / coordinator.treeRevision 变化时
    /// - SwiftUI diff 平铺数组比嵌套 view tree 快一个量级
    @State private var flatRows: [FlatTreeRow] = []
    /// 顶层根孩子的 maxBytes（决定体积条长度的归一化分母）。
    /// 只跟随 root 直接孩子最大值变化，与 expanded 解耦避免每次展开重算。
    @State private var maxBytes: Int64 = 0
    /// **v1.5.4**：是否处于"首次拉 root 子项"的等待态。
    /// 替代旧版 `coordinator.isFetchingChildren(of: rootPath, sortedBy:)` 的实时调用——
    /// flatRows 重建时同步推断，view body 只读 state，少一次 coordinator 调用。
    @State private var isFetchingRoot: Bool = false
    /// 只订阅 `ScanCoordinator.$isScanning`，避免 `ScanCoordinator.objectWillChange`
    /// 的高频 snapshot/progress 发布把整棵 SwiftUI List 拖进刷新。
    @State private var isScanningSnapshot: Bool = false
    /// 按需子树扫描首帧同步返回空时，`directChildren` 会在后台扫描当前目录。
    /// AppKit 表格不再依赖 SwiftUI row body 自发重算，所以展开后看到 loading
    /// 占位时补一个很短的 trailing rebuild，作为 childrenCacheVersion 回调之外的兜底。
    @State private var pendingAsyncChildrenRebuild: DispatchWorkItem? = nil
    /// 扫描完成后对顶层目录做一次限量预热，减少首次展开 `/Users` / `/Applications`
    /// 这类大目录时的空等。key = `path|sortKey`，避免排序切换后误认为已预热。
    @State private var prefetchedChildCacheKeys: Set<String> = []

    public init(coordinator: ScanCoordinator,
                rootPath: String,
                onSelect: ((TreeRow) -> Void)? = nil,
                onTrash: ((URL) -> Void)? = nil,
                onRefreshSubtree: ((String) -> Void)? = nil,
                onStash: ((TreeRow) -> Void)? = nil,
                isStashed: ((String) -> Bool)? = nil,
                aiSettings: AISettings? = nil,
                onAskAI: ((TreeRow) -> Void)? = nil,
                globalSortKey: Binding<MainListSortKey>? = nil) {
        self.coordinator = coordinator
        // 直接从 coordinator 取嵌套的 store 作 @ObservedObject 订阅。
        // ScanCoordinator.treeBrowser 是 `public let`，跨实例稳定，符合 ObservedObject 契约。
        self.treeBrowser = coordinator.treeBrowser
        self.rootPath = rootPath
        self.onSelect = onSelect
        self.onTrash = onTrash
        self.onRefreshSubtree = onRefreshSubtree
        self.onStash = onStash
        self.isStashed = isStashed
        self.aiSettings = aiSettings
        self.onAskAI = onAskAI
        self.globalSortKey = globalSortKey
    }

    /// v1.5 P2 / Q1：当前生效的 [TreeSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L191)。
    /// 优先读 `globalSortKey`，没传才用本地 @State。
    private var effectiveSortKey: TreeSortKey {
        if let g = globalSortKey { return .from(global: g.wrappedValue) }
        return sortKey
    }

    /// v1.5 P2 / Q1：给 TreeColumnHeader 用的 binding。
    /// 列头点击 → set 自动按 `globalSortKey != nil` 选择写入通道。
    /// 写全局通道时通过 `TreeSortKey.asGlobal` 回译，主列表 / 大文件视图同帧感知。
    private var headerSortBinding: Binding<TreeSortKey> {
        Binding(
            get: { effectiveSortKey },
            set: { newKey in
                if let g = globalSortKey {
                    g.wrappedValue = newKey.asGlobal
                } else {
                    sortKey = newKey
                }
            }
        )
    }

    public var body: some View {
        // v1.5.4：body 不再调 directChildren / isFetchingChildren——所有可见行的源数据
        // 都收口在 [flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
        // 这一份扁平 @State 里。view 重算只读 state，重建在 onChange / onAppear 里发生，
        // 不会被 SwiftUI 的 diff 频繁触发递归。
        VStack(spacing: 0) {
            TreeColumnHeader(sortKey: headerSortBinding)
            Divider()
            if flatRows.isEmpty {
                VStack(spacing: 8) {
                    if isScanningSnapshot {
                        ProgressView()
                            .controlSize(.small)
                        Text("tree.loading.scanning", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else if isFetchingRoot {
                        ProgressView()
                            .controlSize(.small)
                        Text("tree.loading.children", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        Image(systemName: "tree")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("tree.empty.no_expandable", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Instruments 55555.trace：订阅隔离后仍有 55 次主线程 hang / 449 次 hitch，
                // SwiftUI updates 表为空，热区基本落在系统 AppKit/SwiftUI 地址。
                // 结论：这里不能再让 SwiftUI List 通过 NSHostingView 承载万级滚动行。
                // 改为原生 NSTableView + 自绘行，固定 rowHeight、复用 row view，
                // 保留现有 flatRows / selection / action 回调边界。
                AppKitFlatTreeTable(
                    rows: flatRows,
                    maxBytes: maxBytes,
                    selectedPath: $selectedPath,
                    expanded: expanded,
                    onToggleExpand: { path in toggleExpansionFor(path: path) },
                    onTrash: onTrash.map { _ in requestTrash(_:) },
                    onRefreshSubtree: onRefreshSubtree,
                    onStash: onStash,
                    isStashed: { path in isStashed?(path) ?? false },
                    aiSettings: aiSettings,
                    onAskAI: onAskAI
                )
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            isScanningSnapshot = coordinator.isScanning
            rebuildFlatRows()
            if selectedPath == nil, let first = flatRows.first {
                selectedPath = first.row.path
            }
            focused = true
        }
        // v1.5.4：四个触发器覆盖所有可能改变 flatRows 内容的事件。
        // 缺一个就会出现"展开后没出现"或"删除后还在"。
        //
        // **v1.5.6 性能优化**（用户反馈"tree 展开还是好卡"）：
        // expanded 变化是**最高频**的 flatRows 重建触发源（每点一次 chevron / 单击行 / l 键
        // 都会 bump）。旧实现走 [rebuildFlatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L296)
        // 整树重算——已展开 200 个目录、每个 50 子项的场景下，每次单点切换都要
        // 重新跑 200 次 directChildren + 200 次 sort + N 次 verdict 计算。
        //
        // 新实现走 diff：把 oldValue/newValue 用 SwiftUI 6 的双参 onChange 拿到，
        // 单点切换（最常见）→ [applyExpansionDiff](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L382)
        // 只插/删受影响的那一段；多点变化 → fallback 走整树重建。
        // 增量路径下展开/折叠的成本从 O(N total) 降到 O(N new subtree)，
        // 90% 的卡感来源就在这里。
        .onChange(of: expanded) { oldExp, newExp in
            applyExpandedChange(old: oldExp, new: newExp)
        }
        // v1.5 P2 / Q1：监听"生效排序键"——它内部已根据 globalSortKey/本地 @State 合流，
        // 两边任意一侧切换都会触发 rebuildFlatRows，保证树视图与全局排序图标同步。
        .onChange(of: effectiveSortKey) { _, _ in rebuildFlatRows() }
        .onChange(of: rootPath) { _, _ in
            // 切扫描根：清掉旧 expanded 防止脏 path 残留撑起 flatRows
            expanded.removeAll(keepingCapacity: true)
            prefetchedChildCacheKeys.removeAll(keepingCapacity: true)
            rebuildFlatRows()
        }
        // Step 2 P0-2 / 2026-06：从 `coordinator.treeRevision` 切到
        // `coordinator.structuralRevision` —— 只在节点新增/删除/排序键变化时重建 flatRows，
        // 不再被流式 publishSnapshot 的 0.4s tick（仅 bytes 变化）拖着整树重算。
        // tickRevision 通过其它 @Published 入口（如 RowItem 自身）驱动 RowView 内部刷新数值，
        // 这里 view 不订阅。
        //
        // 三个 onReceive 走同一组工具方法——之前直接在 body 里堆 3 个 onChange 闭包让
        // SwiftUI ViewBuilder 类型推断超时（"unable to type-check this expression"）。
        // 这里只挂一个 onChange，其它两个走 modifier 链上下方继续，避免类型膨胀。
        .onReceive(treeBrowser.$structuralRevision.removeDuplicates()) { _ in
            handleStructuralBump()
        }
        .onReceive(treeBrowser.$childrenCacheVersion.removeDuplicates()) { _ in
            handleChildrenCacheBump()
        }
        .onReceive(coordinator.$isScanning.removeDuplicates()) { nowScanning in
            isScanningSnapshot = nowScanning
            handleScanningToggle(nowScanning: nowScanning)
        }
        .onChange(of: flatRows.first?.row.path) { _, _ in
            // 切排序 / 切扫描根 → 顶层第一行变化时把选中态拉回首行，避免选中飞走
            let visiblePathSet = Set(flatRows.map(\.row.path))
            if let cur = selectedPath, !visiblePathSet.contains(cur) {
                selectedPath = flatRows.first?.row.path
            } else if selectedPath == nil {
                selectedPath = flatRows.first?.row.path
            }
        }
        .onChange(of: selectedPath) { _, new in
            guard let new else { return }
            let row = flatRows.first(where: { $0.row.path == new })?.row
                ?? coordinator.row(for: new)
            guard let row else { return }
            onSelect?(row)
        }
        .onKeyPress(keys: [KeyEquivalent("j"), .downArrow]) { _ in
            moveSelection(by: 1); return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("k"), .upArrow]) { _ in
            moveSelection(by: -1); return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("l"), .rightArrow]) { _ in
            setExpansion(true); return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("h"), .leftArrow]) { _ in
            setExpansion(false); return .handled
        }
        .onKeyPress(.return) {
            toggleExpansion(); return .handled
        }
        .onKeyPress(.space) {
            // v1.2 P2-4：当前选中是叶子文件 → Quick Look 预览；
            // 是目录 → 维持原行为（切展开/折叠）。
            if let cur = selectedPath,
               let flat = flatRows.first(where: { $0.row.path == cur }),
               !flat.row.isDirectory {
                QuickLookController.shared.preview(urls: [URL(fileURLWithPath: cur)])
                return .handled
            }
            toggleExpansion()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("r")]) { press in
            if press.modifiers.contains(.command) {
                revealInFinder(); return .handled
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            guard let cur = selectedPath, onTrash != nil else { return .ignored }
            // v2026.06 Step 1：键盘 Delete 也走 verdict 缓存。如果当前选中行
            // 在 flatRows 里能找到（应当总是能），直接读 verdict；找不到才 fallback
            // 调一次 evaluate 兜底（极少数 race：选中态滞后于 flatRows 重建）。
            let verdict: SafetyVerdict
            if let flat = flatRows.first(where: { $0.row.path == cur }) {
                verdict = flat.verdict
            } else {
                verdict = Self.VerdictCache.verdict(for: cur)
            }
            guard verdict != .forbid else {
                NSSound.beep()
                return .handled
            }
            requestTrash(URL(fileURLWithPath: cur))
            return .handled
        }
        .confirmationDialog(
            String(localized: "tree.confirm.trash.title", bundle: .module),
            isPresented: Binding(
                get: { pendingTrashURL != nil },
                set: { if !$0 { pendingTrashURL = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTrashURL
        ) { url in
            Button(String(localized: "tree.confirm.trash.confirm", bundle: .module), role: .destructive) {
                pendingTrashURL = nil
                onTrash?(url)
            }
            Button(String(localized: "tree.confirm.trash.cancel", bundle: .module), role: .cancel) {
                pendingTrashURL = nil
            }
        } message: { url in
            Text(String(format: String(localized: "tree.confirm.trash.message %@", bundle: .module), url.lastPathComponent))
        }
    }

    /// **v1.5.3**：行内 trash 按钮 / Delete 键的二次确认入口。
    /// 不直接调上层 onTrash，先把 url 暂存到 pendingTrashURL → confirmationDialog 弹出，
    /// 用户确认后才真正调 onTrash。
    private func requestTrash(_ url: URL) {
        pendingTrashURL = url
    }

    // MARK: - flatRows 重建（v1.5.4 性能修复）

    /// 把 root 直接孩子 + 所有展开节点的子项按 DFS 顺序拍平到 [flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
    /// 由 onChange / onAppear 显式触发；body 不再做这件事。
    /// 4w 节点级一次重建 < 10ms（实测，主 bottleneck 是 `directChildren` 内部 sort，
    /// 但每个 path 只调 1 次而不是 N 次）。
    private func rebuildFlatRows() {
        let topLevel = coordinator.directChildren(of: rootPath, sortedBy: effectiveSortKey)
        // v2026.06 Step 1：先把 (row, depth) 拍扁，再走 computeVerdicts
        // 一次性把 verdict 算好——SafetyEngine.evaluate 只在这里调，每行 1 次。
        var pairs: [(TreeRow, Int)] = []
        pairs.reserveCapacity(topLevel.count * 2)
        for kid in topLevel {
            pairs.append((kid, 0))
            if kid.isDirectory && (expanded[kid.path] ?? false) {
                appendDescendantPairs(parent: kid.path, depth: 1, into: &pairs)
            }
        }
        let base = Self.computeVerdicts(for: pairs) { Self.VerdictCache.verdict(for: $0) }
        // v2026.06.20：把"展开但孩子还在异步加载"的目录后面插一个加载占位行，
        // 让用户在按需子树扫描的等待窗口里看到 spinner，
        // 而不是空白的展开。详见 [insertLoadingPlaceholders](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
        let newFlatRows = insertLoadingPlaceholders(into: base)
        // v2026.06.22 perf：等值短路。
        //
        // 为什么需要：rebuildFlatRows 仍会被多处调用（onAppear / sortKey change /
        // scanning false 边沿 / childrenCacheBump 等）。如果 newFlatRows 与
        // 上一次完全相等却仍然 `flatRows = newFlatRows` 赋值，SwiftUI 会因为
        // @State 被写入而让 body invalidate → List diff → OutlineListCoordinator
        // 166ms 跟着跑（Instruments Hangs 实测）。FlatTreeRow 是 Hashable
        // （隐式 Equatable），先比 == 拒绝等价帧。
        //
        // 复杂度：N 几万时 == 也是 O(N)，但内部是简单值 hash 比较，比 SwiftUI
        // 全树 diff + RowView body 重 render 便宜一个量级；并且多数重复 rebuild
        // 内容真就不变，命中率高。
        let newMax = topLevel.map(\.bytes).max() ?? 0
        let newIsFetching = topLevel.isEmpty
            && coordinator.isFetchingChildren(of: rootPath, sortedBy: effectiveSortKey)
        if flatRows == newFlatRows && maxBytes == newMax && isFetchingRoot == newIsFetching {
            prefetchVisibleTopLevelChildrenIfNeeded()
            return
        }
        flatRows = newFlatRows
        maxBytes = newMax
        // 顶层空 + isFetchingChildren 才算"拉取中"；否则维持 false 让 view 走 isScanning / 真空两态。
        isFetchingRoot = newIsFetching
        if newFlatRows.contains(where: \.isLoadingPlaceholder) || newIsFetching {
            scheduleAsyncChildrenRebuild()
        } else {
            cancelAsyncChildrenRebuild()
        }
        prefetchVisibleTopLevelChildrenIfNeeded()
    }

    private func appendDescendantPairs(parent: String, depth: Int,
                                       into out: inout [(TreeRow, Int)]) {
        let kids = coordinator.directChildren(of: parent, sortedBy: effectiveSortKey)
        for k in kids {
            out.append((k, depth))
            if k.isDirectory && (expanded[k.path] ?? false) {
                appendDescendantPairs(parent: k.path, depth: depth + 1, into: &out)
            }
        }
    }

    /// v2026.06.20 **子节点加载占位插入**。
    ///
    /// 触发场景：用户展开一个目录 → 该目录 directChildren 当前还在异步拉（按需子树扫描
    /// 在 BG queue 起的 Task 没回写 [treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L283-L283)）
    /// → directChildren 暂时返回 []。旧版表现：chevron 已经翻成"↓"但下面什么都没有，
    /// 用户以为"展开了空目录"，几百 ms 后突然出来一堆子项，体验割裂。
    ///
    /// 新策略：对 base 数组按顺序扫一遍，每个"isDirectory + 展开"的行后面看下一行是否真是它的子项
    /// （depth = 父+1）；若不是 + ScanCoordinator 报告 isFetching → 插一个 `isLoadingPlaceholder` 行，
    /// 单独的 ProgressView 渲染。
    ///
    /// 性能：base 数组遍历 1 次，每行 O(1) 字典查询，不 O(N²)。占位行不参与 verdict 评估。
    private func insertLoadingPlaceholders(into base: [FlatTreeRow]) -> [FlatTreeRow] {
        var out: [FlatTreeRow] = []
        out.reserveCapacity(base.count + 4)
        for (i, item) in base.enumerated() {
            out.append(item)
            // 仅对"可展开 + 已展开 + 实际可访问"的目录考虑插占位
            guard item.row.isDirectory,
                  expanded[item.row.path] == true,
                  item.row.accessState == .normal else { continue }
            // 已经有真实子项跟在后面？next.depth 严格大于父 depth 即说明 SwiftUI 看得到子项，
            // 这种情况就不再插占位（避免"加载中…"与真实子项同框）。
            let next = (i + 1 < base.count) ? base[i + 1] : nil
            if let next, next.depth > item.depth { continue }
            // 此时父展开 + 紧邻无真实子项；仅当 ScanCoordinator 报告还在拉时才插
            guard coordinator.isFetchingChildren(of: item.row.path, sortedBy: effectiveSortKey)
            else { continue }
            let placeholderRow = TreeRow(
                path: item.row.path,
                title: "",
                bytes: 0,
                fileCount: 0,
                isDirectory: false,
                hasChildren: false,
                modificationDate: nil
            )
            out.append(FlatTreeRow(
                row: placeholderRow,
                depth: item.depth + 1,
                verdict: .safe,
                isLoadingPlaceholder: true
            ))
        }
        return out
    }

    // MARK: - flatRows 增量 patch（v1.5.6 性能优化）

    /// expanded 字典变化时的 dispatcher：
    /// - 单 key 翻转（最常见：点击 chevron / l / h / 单击行）→ 走增量 patch
    /// - 多 key 变化 / 出现新 key（极少：测试代码 / 未来批量展开）→ fallback 整树重建
    ///
    /// 这里有意**不**碰 maxBytes 与 isFetchingRoot：增量是"子树插入/删除"层面，
    /// 顶层第一行没动 → 顶层 maxBytes 也没动；isFetchingRoot 只在顶层为空时有意义，
    /// 而增量场景一定是 flatRows 非空（至少有 root 直接孩子）。
    ///
    /// 安全网：若 patch 路径上发现 `path` 不在当前 flatRows（例如 path 来自折叠态以下的
    /// 一层、用户在折叠的子目录里点击展开），就 fallback 整树重建。这种"看不见的展开"
    /// 在 keyboard 导航里偶尔出现，正确性优先于性能。
    private func applyExpandedChange(old: [String: Bool], new: [String: Bool]) {
        // 用 truthy（== true）集合做 diff——key 存在但值为 false 等价于"未展开"。
        let oldOpen = Set(old.compactMap { $1 ? $0 : nil })
        let newOpen = Set(new.compactMap { $1 ? $0 : nil })
        let added = newOpen.subtracting(oldOpen)
        let removed = oldOpen.subtracting(newOpen)

        // 只支持单点切换走增量；多点 / 同时增删 → 整树重建。
        guard added.count + removed.count == 1 else {
            rebuildFlatRows()
            return
        }
        if let path = added.first {
            incrementalExpand(path: path)
        } else if let path = removed.first {
            incrementalCollapse(path: path)
        }
    }

    /// 单点展开：在 flatRows 里找到 `path` 那一行，把它的子树（按当前 expanded
    /// 状态递归）插到它后面。若 path 不在当前 flatRows（罕见）→ fallback 整树重建。
    ///
    /// 复杂度：O(N find + M new subtree)，N=当前 flatRows 行数，M=新展开子树行数。
    /// 旧实现是 O(N total + 整树 directChildren 调用)。
    ///
    /// v2026.06.20：插入完真实子项后，若该 path 子项空但 `isFetchingChildren==true`，
    /// 单独插一个加载占位 row，给用户"我点了 → 正在拉"的及时反馈，避免几百 ms 的空白窗口。
    /// 真实子项一旦到位，下次 publishSnapshot 触发 structuralRevision bump → 走整树
    /// [rebuildFlatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L323-L344)
    /// 自然把占位行替换掉，无需手工维护"占位行 lifetime"。
    private func incrementalExpand(path: String) {
        guard let idx = flatRows.firstIndex(where: { $0.row.path == path }) else {
            rebuildFlatRows(); return
        }
        let parentDepth = flatRows[idx].depth
        var pairs: [(TreeRow, Int)] = []
        appendDescendantPairs(parent: path, depth: parentDepth + 1, into: &pairs)
        let inserted = Self.computeVerdicts(for: pairs) { Self.VerdictCache.verdict(for: $0) }
        if !inserted.isEmpty {
            flatRows.insert(contentsOf: inserted, at: idx + 1)
            return
        }
        // pairs.isEmpty → 父展开但暂时没真实子项；仅当 ScanCoordinator 报告还在异步拉时插占位
        let parentRow = flatRows[idx].row
        guard parentRow.accessState == .normal,
              coordinator.isFetchingChildren(of: path, sortedBy: effectiveSortKey)
        else { return }
        let placeholderRow = TreeRow(
            path: path,
            title: "",
            bytes: 0,
            fileCount: 0,
            isDirectory: false,
            hasChildren: false,
            modificationDate: nil
        )
        flatRows.insert(FlatTreeRow(
            row: placeholderRow,
            depth: parentDepth + 1,
            verdict: .safe,
            isLoadingPlaceholder: true
        ), at: idx + 1)
        scheduleAsyncChildrenRebuild()
    }

    /// 单点折叠：在 flatRows 里找到 `path`，删掉它**之后**所有 depth > path.depth 的
    /// 连续行（用 depth 边界扫描，遇到 depth <= path.depth 即停）。
    ///
    /// 与 incrementalExpand 对称，复杂度 O(N find + K removed subtree)。
    private func incrementalCollapse(path: String) {
        guard let idx = flatRows.firstIndex(where: { $0.row.path == path }) else {
            rebuildFlatRows(); return
        }
        let parentDepth = flatRows[idx].depth
        var end = idx + 1
        while end < flatRows.count && flatRows[end].depth > parentDepth {
            end += 1
        }
        if end > idx + 1 {
            flatRows.removeSubrange((idx + 1)..<end)
        }
    }

    /// v1.5.7：prune 增量 patch —— 只从当前 flatRows 移除被删 path 自身及其子孙行，
    /// 不重新调 [directChildren](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1054)
    /// 也不重新跑 SafetyEngine.evaluate。复杂度 O(flatRows.count) 一遍扫，
    /// 对万级目录场景下，从老路径 O(N total + safety) → O(N flat) 直降一档。
    ///
    /// 兜底：若移除后某个被删 path 的祖先目录（flatRows 里仍存在）原本是叶子
    /// 节点已不再有可见孩子，view 行内 chevron 自然反映为 0；bytes/fileCount 由
    /// ScanCoordinator [prune 祖先减法](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1422-L1497)
    /// + RowView 重新读保证。
    ///
    /// 安全网：若 flatRows 为空（理论不会，prune 不会从 0 行走到这里），fallback 整树重建。
    private func applyPrunePatch(deletedPaths: [String]) {
        if flatRows.isEmpty { rebuildFlatRows(); return }
        // 把 deletedPaths 拍成"前缀匹配集"：path 自身或子孙都算命中。
        // 用 dropLast("/") 归一，与 ScanCoordinator.pruneDeleted 的 normalized 对齐。
        let normalized: [String] = deletedPaths.map {
            ($0.hasSuffix("/") && $0.count > 1) ? String($0.dropLast()) : $0
        }
        let prunedSet = Set(normalized)
        func isUnderDeleted(_ p: String) -> Bool {
            if prunedSet.contains(p) { return true }
            for d in normalized {
                if p.hasPrefix(d + "/") { return true }
            }
            return false
        }
        let before = flatRows.count
        flatRows.removeAll { isUnderDeleted($0.row.path) }
        // maxBytes 重算：删的可能是顶层最大行，重新取一遍 max 保进度条比例正确。
        let topLevel = flatRows.filter { $0.depth == 0 }
        if !topLevel.isEmpty {
            maxBytes = topLevel.map(\.row.bytes).max() ?? 0
        }
        // 选中态若指向已删 path，由 onChange(flatRows.first) 兜底拉回首行；这里不动。
        _ = before
    }

    /// **可测的 pure helper**：把"老 flatRows + 单点 expand/collapse"映射成"新 flatRows"。
    ///
    /// 单测用它对比"增量结果" vs "整树重建结果"，钉死等价性契约——
    /// 任何未来对 incrementalExpand / incrementalCollapse 的优化只要不破等价就能落地。
    ///
    /// - parameters:
    ///   - old: 老 flatRows
    ///   - togglePath: 被翻转的 path（必须能在 old 里找到）
    ///   - isExpanding: true=展开 / false=折叠
    ///   - childrenProvider: (parentPath, sortKey) -> 直接子项，按 sortKey 排好序
    ///   - expandedAfter: 翻转后的 expanded 状态（用于决定新子树里哪些孙子也要拍平）
    ///   - sortKey: 当前排序键（透传给 childrenProvider）
    ///   - evaluator: SafetyEngine 评估函数，与 [computeVerdicts](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L330)
    ///     共用
    /// - returns: 若 togglePath 不在 old → nil（caller fallback 整树重建），否则新 flatRows
    static func applyExpansionPatch(
        old: [FlatTreeRow],
        togglePath: String,
        isExpanding: Bool,
        sortKey: TreeSortKey,
        expandedAfter: [String: Bool],
        childrenProvider: (String, TreeSortKey) -> [TreeRow],
        evaluator: (String) -> SafetyVerdict
    ) -> [FlatTreeRow]? {
        guard let idx = old.firstIndex(where: { $0.row.path == togglePath }) else {
            return nil
        }
        let parentDepth = old[idx].depth
        if isExpanding {
            var pairs: [(TreeRow, Int)] = []
            collectDescendantPairs(
                parent: togglePath, depth: parentDepth + 1,
                sortKey: sortKey, expanded: expandedAfter,
                childrenProvider: childrenProvider, into: &pairs
            )
            var out = old
            out.insert(contentsOf: computeVerdicts(for: pairs, using: evaluator),
                       at: idx + 1)
            return out
        } else {
            var end = idx + 1
            while end < old.count && old[end].depth > parentDepth { end += 1 }
            var out = old
            if end > idx + 1 { out.removeSubrange((idx + 1)..<end) }
            return out
        }
    }

    /// pure helper：递归收集子树 (row, depth)，与 [appendDescendantPairs](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L308)
    /// 对应但不依赖 `coordinator`，让单测能用 mock provider。
    private static func collectDescendantPairs(
        parent: String, depth: Int,
        sortKey: TreeSortKey,
        expanded: [String: Bool],
        childrenProvider: (String, TreeSortKey) -> [TreeRow],
        into out: inout [(TreeRow, Int)]
    ) {
        let kids = childrenProvider(parent, sortKey)
        for k in kids {
            out.append((k, depth))
            if k.isDirectory && (expanded[k.path] ?? false) {
                collectDescendantPairs(
                    parent: k.path, depth: depth + 1,
                    sortKey: sortKey, expanded: expanded,
                    childrenProvider: childrenProvider, into: &out
                )
            }
        }
    }

    /// **v2026.06 Step 1【P0-1 verdict 缓存】**：把 (row, depth) 序列一次性映射成
    /// 带 verdict 的 [FlatTreeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
    ///
    /// 关键点 1：evaluator 是注入的——生产代码传 `Self.safety.evaluate(path:).0`，
    /// 测试 [FlatTreeRowVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)
    /// 传 [CountingEvaluator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)
    /// 计调用次数。这是把 SafetyEngine 从 SwiftUI hot path 拆下来的契约接缝。
    ///
    /// 关键点 2：每行 evaluator 只调一次。后续 SwiftUI 重绘读 `flat.verdict` 不再回 SafetyEngine。
    /// 4w 行从"重绘×4w 次 trie 查找"降到"rebuild×4w 次"，rebuild 仅在
    /// expanded/sortKey/rootPath/treeRevision 变更时发生（4 个事件总和）。
    static func computeVerdicts(
        for pairs: [(TreeRow, Int)],
        using evaluator: (String) -> SafetyVerdict
    ) -> [FlatTreeRow] {
        var out: [FlatTreeRow] = []
        out.reserveCapacity(pairs.count)
        for (row, depth) in pairs {
            out.append(FlatTreeRow(row: row, depth: depth, verdict: evaluator(row.path)))
        }
        return out
    }

    /// v2026.06.21：structuralRevision bump 入口（从 body onChange 抽出来避免类型推断超时）。
    /// 流程：
    ///   1. 优先消费 pruneDeleted hint → 走"只剔被删 path 子树"的 patch（避免大树整 rebuild）。
    ///   2. 扫描中：冻结 flatRows，不让 List 持续 diffRows/endUpdates。
    ///   3. 扫描外：立刻 rebuild 拿到最新视图。
    private func handleStructuralBump() {
        if let pruned = coordinator.consumeLastPrunedPaths(), !pruned.isEmpty {
            applyPrunePatch(deletedPaths: pruned)
            return
        }
        if isScanningSnapshot {
            // 扫描中不要让树形 List 持续 diffRows/endUpdates。用户此时主要在看
            // statusBar 进度和滚动已有结果；最终结构在扫描结束边沿统一刷新。
            return
        }
        rebuildFlatRows()
    }

    /// v2026.06.21：扫描结束边沿——把扫描期间合并的 rebuild 立刻 fire 拿到终态。
    /// 也兼容 isScanning 切回 true 的回边沿：进入扫描态不主动 rebuild（等 structural bump）。
    private func handleScanningToggle(nowScanning: Bool) {
        if nowScanning {
            prefetchedChildCacheKeys.removeAll(keepingCapacity: true)
        } else {
            rebuildFlatRows()
        }
    }

    /// v2026.06.21：directChildren 异步写回路径只 bump childrenCacheVersion（不再 bump
    /// structuralRevision），这里独立监听；扫描中同样冻结，扫描结束统一刷新。
    private func handleChildrenCacheBump() {
        guard !isScanningSnapshot else { return }
        cancelAsyncChildrenRebuild()
        rebuildFlatRows()
    }

    private func scheduleAsyncChildrenRebuild() {
        guard !isScanningSnapshot else { return }
        pendingAsyncChildrenRebuild?.cancel()
        let work = DispatchWorkItem {
            pendingAsyncChildrenRebuild = nil
            rebuildFlatRows()
        }
        pendingAsyncChildrenRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func cancelAsyncChildrenRebuild() {
        pendingAsyncChildrenRebuild?.cancel()
        pendingAsyncChildrenRebuild = nil
    }

    private func prefetchVisibleTopLevelChildrenIfNeeded() {
        guard !isScanningSnapshot else { return }
        let candidates = flatRows
            .filter {
                $0.depth == 0
                    && $0.row.isDirectory
                    && $0.row.hasChildren
                    && $0.row.accessState == .normal
            }
            .prefix(4)
        var paths: [String] = []
        var keys: [String] = []
        for flat in candidates {
            let cacheKey = "\(flat.row.path)|\(effectiveSortKey.rawValue)"
            guard !prefetchedChildCacheKeys.contains(cacheKey) else { continue }
            paths.append(flat.row.path)
            keys.append(cacheKey)
        }
        guard !paths.isEmpty else { return }
        prefetchedChildCacheKeys.formUnion(keys)
        coordinator.prefetchTreeChildren(paths: paths, sortedBy: effectiveSortKey, limit: 4)
    }

    /// 行内三角 / 单击整行 / 右键菜单 / 双击 → 共用的展开切换入口。
    /// 不在乎 [TreeNodeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 内部的 canExpand 状态，外层这里仅 toggle expanded[path]——
    /// 不能展开的行 row 内部已经把按钮 / 双击 hit-test disable 掉。
    ///
    /// v2026.06.21：扫描进行中**禁止展开切换**。
    /// 用户反馈：dev 扫描进行中点击 chevron 展开会触发按需子树扫描，
    /// 大量并发 IO + MainActor 上的 dirIndex 重建会和 ingest burst 互相挤占主线程，
    /// 体感卡顿急剧放大。扫描中保留 row 显示但拦截 expansion，等扫完再让用户展开。
    /// 已展开状态不主动收起（保留用户当前视图），仅拒绝**新的展开请求**与折叠请求。
    private func toggleExpansionFor(path: String) {
        if isScanningSnapshot { return }
        expanded[path] = !(expanded[path] ?? false)
    }

    // MARK: - 键盘导航辅助（v1.5.4：全部读 flatRows，O(1) 索引）

    private func moveSelection(by delta: Int) {
        guard !flatRows.isEmpty else { return }
        if let cur = selectedPath, let idx = flatRows.firstIndex(where: { $0.row.path == cur }) {
            let next = max(0, min(flatRows.count - 1, idx + delta))
            selectedPath = flatRows[next].row.path
        } else {
            selectedPath = flatRows.first?.row.path
        }
    }

    private func setExpansion(_ open: Bool) {
        guard let cur = selectedPath else { return }
        // v2026.06.21：见 toggleExpansionFor 同名注释——扫描中拦截展开，仅允许选中移动。
        if isScanningSnapshot {
            // 但 h 在叶子上跳到父节点的"导航"语义保留（不改 expanded 状态，只移动选中）。
            if !open, let flat = flatRows.first(where: { $0.row.path == cur }),
               !(flat.row.isDirectory && flat.row.hasChildren),
               let parent = parentVisible(of: cur) {
                selectedPath = parent
            }
            return
        }
        if let flat = flatRows.first(where: { $0.row.path == cur }),
           flat.row.isDirectory && flat.row.hasChildren {
            expanded[cur] = open
        } else if !open {
            // h 在叶子上 → 跳到父节点（vim 风格"折叠到父"）
            if let parent = parentVisible(of: cur) {
                selectedPath = parent
            }
        }
    }

    private func toggleExpansion() {
        guard let cur = selectedPath else { return }
        // v2026.06.21：见 toggleExpansionFor 同名注释。
        if isScanningSnapshot { return }
        guard let flat = flatRows.first(where: { $0.row.path == cur }),
              flat.row.isDirectory && flat.row.hasChildren else { return }
        expanded[cur] = !(expanded[cur] ?? false)
    }

    /// 在已"可见"的行中找当前 path 的父节点路径（不在可见集合时返回 nil）。
    /// 之所以限定可见，是因为 h 操作要"跳回当前可见的父"，跳到一个被折起来的父没意义。
    private func parentVisible(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == rootPath { return nil }
        return flatRows.first(where: { $0.row.path == parent })?.row.path
    }

    private func revealInFinder() {
        guard let cur = selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cur)])
    }

    // MARK: - SafetyEngine forbid 兜底（v1.5.3 仍保留为可测的 pure helper）

    /// **可测的 pure helper**：从任意路径集合里剔除 SafetyEngine forbid 路径。
    /// v1.5.3 多选 UI 已撤掉，但本静态方法仍被
    /// [TreeBrowserMultiSelectTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/TreeBrowserMultiSelectTests.swift)
    /// 锁住，作为"任意未来批量入口接进 SafetyEngine 的契约"——避免有人加了
    /// 别的批量删入口绕过 forbid 拦截。
    public static func sanitize(paths: Set<String>) -> Set<String> {
        paths.filter { safety.evaluate(path: $0).0 != .forbid }
    }
}

private struct AppKitFlatTreeTable: NSViewRepresentable {
    let rows: [FlatTreeRow]
    let maxBytes: Int64
    @Binding var selectedPath: String?
    let expanded: [String: Bool]
    let onToggleExpand: (String) -> Void
    let onTrash: ((URL) -> Void)?
    let onRefreshSubtree: ((String) -> Void)?
    let onStash: ((TreeRow) -> Void)?
    let isStashed: (String) -> Bool
    let aiSettings: AISettings?
    let onAskAI: ((TreeRow) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TreeNSTableView()
        table.headerView = nil
        table.rowHeight = TreeTableMetrics.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKey(event) ?? false
        }

        let column = NSTableColumn(identifier: TreeTableMetrics.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scrollView.documentView as? NSTableView else { return }
        if let column = table.tableColumns.first {
            column.width = max(scrollView.contentSize.width, 100)
        }
        table.reloadData()
        context.coordinator.syncSelection(in: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AppKitFlatTreeTable
        private var isSyncingSelection = false

        init(parent: AppKitFlatTreeTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row rowIndex: Int) -> NSView? {
            guard rowIndex >= 0, rowIndex < parent.rows.count else { return nil }
            let identifier = TreeTableMetrics.cellIdentifier
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TreeTableCellView)
                ?? TreeTableCellView(identifier: identifier)
            let flat = parent.rows[rowIndex]
            cell.configure(
                flat: flat,
                maxBytes: parent.maxBytes,
                isExpanded: parent.expanded[flat.row.path] ?? false,
                isSelected: !flat.isLoadingPlaceholder && parent.selectedPath == flat.row.path,
                isStashed: parent.isStashed(flat.row.path),
                hasTrash: parent.onTrash != nil,
                hasStash: parent.onStash != nil,
                hasAI: parent.onAskAI != nil,
                aiReady: parent.aiSettings?.isReadyForUI == true,
                actions: TreeTableRowActions(
                    select: { [weak self] in self?.select(flat.row.path, in: tableView) },
                    toggle: { [weak self] in self?.parent.onToggleExpand(flat.row.path) },
                    trash: { [weak self] in self?.parent.onTrash?(URL(fileURLWithPath: flat.row.path)) },
                    stash: { [weak self] in self?.parent.onStash?(flat.row) },
                    askAI: { [weak self] in self?.parent.onAskAI?(flat.row) },
                    refresh: { [weak self] in self?.parent.onRefreshSubtree?(flat.row.path) }
                )
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let table = notification.object as? NSTableView else { return }
            let rowIndex = table.selectedRow
            guard rowIndex >= 0, rowIndex < parent.rows.count else {
                parent.selectedPath = nil
                return
            }
            let flat = parent.rows[rowIndex]
            guard !flat.isLoadingPlaceholder else { return }
            parent.selectedPath = flat.row.path
        }

        func syncSelection(in table: NSTableView) {
            guard let selectedPath = parent.selectedPath,
                  let idx = parent.rows.firstIndex(where: { $0.row.path == selectedPath }) else {
                if table.selectedRow >= 0 {
                    isSyncingSelection = true
                    table.deselectAll(nil)
                    isSyncingSelection = false
                }
                return
            }
            if table.selectedRow != idx {
                isSyncingSelection = true
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                table.scrollRowToVisible(idx)
                isSyncingSelection = false
            }
        }

        func select(_ path: String, in table: NSTableView) {
            parent.selectedPath = path
            if let idx = parent.rows.firstIndex(where: { $0.row.path == path }) {
                isSyncingSelection = true
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                isSyncingSelection = false
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 126:
                moveSelection(delta: -1); return true
            case 125:
                moveSelection(delta: 1); return true
            case 123:
                setExpansion(open: false); return true
            case 124:
                setExpansion(open: true); return true
            default:
                break
            }
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
            switch scalar {
            case "\r", " ":
                toggleSelectedExpansion(); return true
            default:
                if event.modifierFlags.contains(.command), scalar == "r" {
                    revealSelected(); return true
                }
                if scalar == "j" {
                    moveSelection(delta: 1); return true
                }
                if scalar == "k" {
                    moveSelection(delta: -1); return true
                }
                return false
            }
        }

        private func moveSelection(delta: Int) {
            guard !parent.rows.isEmpty else { return }
            let current = parent.selectedPath
                .flatMap { selected in parent.rows.firstIndex { $0.row.path == selected } }
                ?? -1
            let next = max(0, min(parent.rows.count - 1, current + delta))
            let flat = parent.rows[next]
            guard !flat.isLoadingPlaceholder else { return }
            parent.selectedPath = flat.row.path
        }

        private func setExpansion(open: Bool) {
            guard let flat = selectedFlat(),
                  flat.row.isDirectory,
                  flat.row.hasChildren,
                  flat.row.accessState == .normal else { return }
            let isOpen = parent.expanded[flat.row.path] ?? false
            guard isOpen != open else { return }
            parent.onToggleExpand(flat.row.path)
        }

        private func toggleSelectedExpansion() {
            guard let flat = selectedFlat(),
                  flat.row.isDirectory,
                  flat.row.hasChildren,
                  flat.row.accessState == .normal else { return }
            parent.onToggleExpand(flat.row.path)
        }

        private func revealSelected() {
            guard let flat = selectedFlat() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: flat.row.path)])
        }

        private func selectedFlat() -> FlatTreeRow? {
            guard let selectedPath = parent.selectedPath else { return nil }
            return parent.rows.first { $0.row.path == selectedPath && !$0.isLoadingPlaceholder }
        }
    }
}

private final class TreeNSTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

private enum TreeTableMetrics {
    static let rowHeight: CGFloat = 30
    static let leftPadding: CGFloat = 8
    static let indentation: CGFloat = 18
    static let chevronWidth: CGFloat = 24
    static let iconWidth: CGFloat = 24
    static let iconHeight: CGFloat = 20
    static let horizontalGap: CGFloat = 8
    static let sizeWidth: CGFloat = 90
    static let countWidth: CGFloat = 56
    static let mtimeWidth: CGFloat = 98
    static let actionGap: CGFloat = 12
    static let actionWidth: CGFloat = 28
    static let actionAreaWidth: CGFloat = 84
    static let actionTrailingPadding: CGFloat = 16
    static let columnIdentifier = NSUserInterfaceItemIdentifier("TreeTableColumn")
    static let cellIdentifier = NSUserInterfaceItemIdentifier("TreeTableCell")
}

private struct TreeTableRowActions {
    let select: () -> Void
    let toggle: () -> Void
    let trash: () -> Void
    let stash: () -> Void
    let askAI: () -> Void
    let refresh: () -> Void
}

private final class TreeTableCellView: NSTableCellView {
    private let canvas = TreeTableRowCanvas()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
    }

    func configure(flat: FlatTreeRow,
                   maxBytes: Int64,
                   isExpanded: Bool,
                   isSelected: Bool,
                   isStashed: Bool,
                   hasTrash: Bool,
                   hasStash: Bool,
                   hasAI: Bool,
                   aiReady: Bool,
                   actions: TreeTableRowActions) {
        canvas.configure(
            flat: flat,
            maxBytes: maxBytes,
            isExpanded: isExpanded,
            isSelected: isSelected,
            isStashed: isStashed,
            hasTrash: hasTrash,
            hasStash: hasStash,
            hasAI: hasAI,
            aiReady: aiReady,
            actions: actions
        )
    }
}

private final class TreeTableRowCanvas: NSView {
    private var flat: FlatTreeRow?
    private var maxBytes: Int64 = 0
    private var isExpanded = false
    private var isSelected = false
    private var isStashed = false
    private var hasTrash = false
    private var hasStash = false
    private var hasAI = false
    private var aiReady = false
    private var actions: TreeTableRowActions?

    override var isFlipped: Bool { true }

    func configure(flat: FlatTreeRow,
                   maxBytes: Int64,
                   isExpanded: Bool,
                   isSelected: Bool,
                   isStashed: Bool,
                   hasTrash: Bool,
                   hasStash: Bool,
                   hasAI: Bool,
                   aiReady: Bool,
                   actions: TreeTableRowActions) {
        self.flat = flat
        self.maxBytes = maxBytes
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.isStashed = isStashed
        self.hasTrash = hasTrash
        self.hasStash = hasStash
        self.hasAI = hasAI
        self.aiReady = aiReady
        self.actions = actions
        toolTip = flat.row.path
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let flat else { return }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        if flat.isLoadingPlaceholder {
            drawLoading(flat)
            return
        }
        drawRow(flat)
    }

    override func mouseDown(with event: NSEvent) {
        guard let flat, !flat.isLoadingPlaceholder, let actions else { return }
        let point = convert(event.locationInWindow, from: nil)
        actions.select()
        if hitTestAction(point) == .ai {
            GSYLog.notice(.operation, "tree.row.ai path=\(flat.row.path)")
            actions.askAI(); return
        }
        if hitTestAction(point) == .stash {
            guard !isStashed else { NSSound.beep(); return }
            GSYLog.notice(.operation, "tree.row.stash path=\(flat.row.path)")
            actions.stash(); return
        }
        if hitTestAction(point) == .trash {
            guard isTrashable(flat) else { NSSound.beep(); return }
            GSYLog.notice(.operation, "tree.row.trash path=\(flat.row.path)")
            actions.trash(); return
        }
        if disclosureRect(for: flat).contains(point) {
            if canExpand(flat) {
                GSYLog.notice(.operation, "tree.row.toggle path=\(flat.row.path) expanded=\(!isExpanded)")
                actions.toggle()
            }
            return
        }
        if event.clickCount >= 2 || canExpand(flat) {
            GSYLog.notice(.operation, "tree.row.toggle path=\(flat.row.path) expanded=\(!isExpanded)")
            actions.toggle()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let flat, !flat.isLoadingPlaceholder, let actions else { return nil }
        actions.select()
        let row = flat.row
        let menu = NSMenu()
        if hasTrash {
            let item = ClosureMenuItem(
                title: String(localized: flat.verdict == .forbid ? "tree.menu.trash_forbidden" : "tree.menu.trash",
                              bundle: .module),
                action: { if self.isTrashable(flat) { actions.trash() } }
            )
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            item.isEnabled = isTrashable(flat)
            menu.addItem(item)
        }
        if hasStash {
            let item = ClosureMenuItem(
                title: String(localized: isStashed ? "tree.menu.stash_already" : "tree.menu.stash",
                              bundle: .module),
                action: { if !self.isStashed { actions.stash() } }
            )
            item.image = NSImage(systemSymbolName: isStashed ? "tray.full.fill" : "tray.and.arrow.down",
                                 accessibilityDescription: nil)
            item.isEnabled = !isStashed
            menu.addItem(item)
        }
        if hasTrash || hasStash { menu.addItem(.separator()) }
        if hasAI {
            let item = ClosureMenuItem(
                title: String(localized: "tree.menu.ask_ai", bundle: .module),
                action: actions.askAI
            )
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let quickLook = ClosureMenuItem(
            title: String(localized: "tree.menu.quick_look", bundle: .module),
            action: { QuickLookController.shared.preview(urls: [URL(fileURLWithPath: row.path)]) }
        )
        quickLook.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        menu.addItem(quickLook)
        let reveal = ClosureMenuItem(
            title: String(localized: "tree.menu.reveal_in_finder", bundle: .module),
            action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
        )
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(reveal)
        menu.addItem(.separator())
        if row.isDirectory {
            let refresh = ClosureMenuItem(
                title: String(localized: "tree.menu.refresh", bundle: .module),
                action: {
                    GSYLog.notice(.operation, "tree.menu.refresh path=\(row.path)")
                    actions.refresh()
                }
            )
            refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            menu.addItem(refresh)
        }
        if canExpand(flat) {
            let disclose = ClosureMenuItem(
                title: String(localized: isExpanded ? "tree.disclose.collapse" : "tree.disclose.expand",
                              bundle: .module),
                action: actions.toggle
            )
            disclose.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                                     accessibilityDescription: nil)
            menu.addItem(disclose)
        }
        menu.addItem(.separator())
        let copyPath = ClosureMenuItem(
            title: String(localized: "tree.menu.copy_path", bundle: .module),
            action: { Self.copy(row.path) }
        )
        copyPath.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyPath)
        let copyName = ClosureMenuItem(
            title: String(localized: "tree.menu.copy_name", bundle: .module),
            action: { Self.copy((row.path as NSString).lastPathComponent) }
        )
        copyName.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        menu.addItem(copyName)
        return menu
    }

    private func drawLoading(_ flat: FlatTreeRow) {
        let x = TreeTableMetrics.leftPadding
            + CGFloat(flat.depth) * TreeTableMetrics.indentation
            + TreeTableMetrics.chevronWidth
        drawText(String(localized: "tree.loading.children", bundle: .module),
                 in: CGRect(x: x, y: 5, width: bounds.width - x - 8, height: 18),
                 font: .systemFont(ofSize: NSFont.systemFontSize),
                 color: .secondaryLabelColor)
    }

    private func drawRow(_ flat: FlatTreeRow) {
        let row = flat.row
        let denied = row.accessState != .normal
        let chevronRect = disclosureRect(for: flat)
        if canExpand(flat) {
            drawDisclosureTriangle(in: chevronRect,
                                   expanded: isExpanded,
                                   color: .secondaryLabelColor)
        }
        let iconRect = CGRect(x: chevronRect.maxX + TreeTableMetrics.horizontalGap,
                              y: 5,
                              width: TreeTableMetrics.iconWidth,
                              height: TreeTableMetrics.iconHeight)
        drawSymbol(row.isDirectory ? "folder.fill" : "doc",
                   in: iconRect,
                   color: denied ? .tertiaryLabelColor : (row.isDirectory ? .controlAccentColor : .secondaryLabelColor),
                   pointSize: row.isDirectory ? 20 : 18,
                   weight: .regular)
        if denied {
            drawSymbol("lock.fill",
                       in: CGRect(x: iconRect.maxX - 5, y: iconRect.maxY - 7, width: 8, height: 8),
                       color: .systemOrange)
        }
        let nameX = iconRect.maxX + TreeTableMetrics.horizontalGap
        let actionStart = bounds.width
            - TreeTableMetrics.actionTrailingPadding
            - TreeTableMetrics.actionAreaWidth
        let mtimeX = actionStart - TreeTableMetrics.actionGap - TreeTableMetrics.mtimeWidth
        let countX = mtimeX - TreeTableMetrics.countWidth
        let sizeX = countX - TreeTableMetrics.sizeWidth
        let nameWidth = max(20, sizeX - nameX - 8)
        drawText(row.title.isEmpty ? row.path : row.title,
                 in: CGRect(x: nameX, y: 3, width: nameWidth, height: 19),
                 font: .systemFont(ofSize: 15),
                 color: denied ? .tertiaryLabelColor : .labelColor,
                 lineBreak: .byTruncatingMiddle)
        drawBar(row: row,
                denied: denied,
                rect: CGRect(x: nameX, y: 24, width: nameWidth, height: 2))
        let pendingSize = row.isSizePending && !denied
        let size = (denied || pendingSize) ? "—" : ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)
        drawText(size,
                 in: CGRect(x: sizeX, y: 6, width: TreeTableMetrics.sizeWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
                 color: (denied || pendingSize) ? .tertiaryLabelColor : .secondaryLabelColor,
                 alignment: .right)
        drawText((denied || pendingSize) ? "—" : "\(row.fileCount)",
                 in: CGRect(x: countX, y: 6, width: TreeTableMetrics.countWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
                 color: .tertiaryLabelColor,
                 alignment: .right)
        drawText(TreeBrowserRow.mtimeDisplay(row.modificationDate, denied: denied),
                 in: CGRect(x: mtimeX, y: 6, width: TreeTableMetrics.mtimeWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
                 color: .tertiaryLabelColor,
                 alignment: .right)
        drawActions(flat)
    }

    private func drawBar(row: TreeRow, denied: Bool, rect: CGRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        guard maxBytes > 0, !denied, !row.isSizePending else { return }
        let ratio = max(0, min(1, Double(row.bytes) / Double(maxBytes)))
        let fill = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(ratio), height: rect.height)
        (row.isDirectory ? NSColor.controlAccentColor.withAlphaComponent(0.56) : NSColor.controlAccentColor.withAlphaComponent(0.30)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawActions(_ flat: FlatTreeRow) {
        if hasAI {
            drawSymbol("sparkles",
                       in: symbolRect(in: actionRect(.ai), side: 16),
                       color: aiReady ? .controlAccentColor : .secondaryLabelColor.withAlphaComponent(0.45),
                       pointSize: 14,
                       weight: .regular)
        }
        if hasStash {
            drawSymbol(isStashed ? "tray.full.fill" : "tray.and.arrow.down",
                       in: symbolRect(in: actionRect(.stash), side: 16),
                       color: isStashed ? .controlAccentColor : .secondaryLabelColor,
                       pointSize: 14,
                       weight: .regular)
        }
        if hasTrash {
            drawSymbol("trash",
                       in: symbolRect(in: actionRect(.trash), side: 16),
                       color: isTrashable(flat) ? .systemRed : .secondaryLabelColor.withAlphaComponent(0.35),
                       pointSize: 14,
                       weight: .regular)
        }
    }

    private func drawDisclosureTriangle(in rect: CGRect,
                                        expanded: Bool,
                                        color: NSColor) {
        drawSymbol(expanded ? "chevron.down" : "chevron.right",
                   in: symbolRect(in: rect, side: 18),
                   color: color,
                   pointSize: 17,
                   weight: .medium)
    }

    private func disclosureRect(for flat: FlatTreeRow) -> CGRect {
        CGRect(
            x: TreeTableMetrics.leftPadding + CGFloat(flat.depth) * TreeTableMetrics.indentation,
            y: 4,
            width: TreeTableMetrics.chevronWidth,
            height: 22
        )
    }

    private enum ActionHit {
        case none
        case ai
        case stash
        case trash
    }

    private func hitTestAction(_ point: CGPoint) -> ActionHit {
        if hasAI, actionRect(.ai).contains(point) { return .ai }
        if hasStash, actionRect(.stash).contains(point) { return .stash }
        if hasTrash, actionRect(.trash).contains(point) { return .trash }
        return .none
    }

    private func actionRect(_ action: ActionHit) -> CGRect {
        let right = bounds.width - TreeTableMetrics.actionTrailingPadding
        let trash = CGRect(x: right - TreeTableMetrics.actionWidth, y: 4,
                           width: TreeTableMetrics.actionWidth, height: 22)
        let stash = trash.offsetBy(dx: -TreeTableMetrics.actionWidth, dy: 0)
        let ai = stash.offsetBy(dx: -TreeTableMetrics.actionWidth, dy: 0)
        switch action {
        case .ai: return ai
        case .stash: return stash
        case .trash: return trash
        case .none: return .zero
        }
    }

    private func symbolRect(in rect: CGRect, side: CGFloat? = nil) -> CGRect {
        let resolvedSide = min(side ?? min(rect.width, rect.height), rect.width, rect.height)
        return CGRect(
            x: rect.midX - resolvedSide / 2,
            y: rect.midY - resolvedSide / 2,
            width: resolvedSide,
            height: resolvedSide
        )
    }

    private func canExpand(_ flat: FlatTreeRow) -> Bool {
        flat.row.isDirectory && flat.row.hasChildren && flat.row.accessState == .normal
    }

    private func isTrashable(_ flat: FlatTreeRow) -> Bool {
        hasTrash && flat.row.accessState == .normal && flat.verdict != .forbid
    }

    private func drawText(_ text: String,
                          in rect: CGRect,
                          font: NSFont?,
                          color: NSColor?,
                          alignment: NSTextAlignment = .left,
                          lineBreak: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        var attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph
        ]
        if let font {
            attributes[.font] = font
        }
        if let color {
            attributes[.foregroundColor] = color
        }
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawSymbol(_ name: String,
                            in rect: CGRect,
                            color: NSColor,
                            pointSize: CGFloat? = nil,
                            weight: NSFont.Weight = .regular) {
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: color)
        if let pointSize {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(colorConfig)
            image = image.withSymbolConfiguration(config) ?? image
        } else {
            image = image.withSymbolConfiguration(colorConfig) ?? image
        }
        image.draw(in: aspectFitRect(for: image, in: rect),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1,
                   respectFlipped: true,
                   hints: nil)
    }

    private func aspectFitRect(for image: NSImage, in rect: CGRect) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0,
              rect.width > 0, rect.height > 0
        else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, action closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runClosure() {
        closure()
    }
}

/// 列表头：可点击切排序。
///
/// v1.5.4：新增"修改时间"列（98pt 宽），与 [TreeBrowserRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L622)
/// 的 mtime 单元宽度对齐。点击切 desc/asc，与 size/name/count 一致。
struct TreeColumnHeader: View {
    @Binding var sortKey: TreeSortKey

    var body: some View {
        HStack(spacing: 10) {
            // 与 TreeBrowserRow 的 icon + 三角占位对齐：22（三角 hit area）+ 6（间距）+ 16（icon）= 44
            Spacer().frame(width: 44)
            headerButton(label: String(localized: "tree.column.name", bundle: .module), column: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerButton(label: String(localized: "tree.column.size", bundle: .module), column: .size)
                .frame(width: 90, alignment: .trailing)
            headerButton(label: String(localized: "tree.column.count", bundle: .module), column: .count)
                .frame(width: 56, alignment: .trailing)
            // v1.5.4：mtime 列。98pt 给"yyyy-MM-dd"或"3 天前"宽度足够。
            headerButton(label: String(localized: "tree.column.mtime", bundle: .module), column: .mtime)
                .frame(width: 98, alignment: .trailing)
            // v2026.06.21 反馈修复：之前 mtime 与按钮列贴边，视觉上像"挤在一起"。
            // 加一个 12pt gap，让 mtime 文案与「操作」列有清晰的视觉分隔。
            Spacer().frame(width: 12)
            // **v2026.06.21 修复**：原来这里只是一个固定 Spacer 占位，没有标题，
            // 用户原话「这个栏目也没有写『操作』这个栏目信息」。改成正式的「操作」
            // 表头文案，居中显示在按钮列上方，
            // 让用户一眼知道这一列点开会发生什么；不参与点击切排序，所以不复用
            // headerButton 而是直接 Text。
            Text("tree.column.actions", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: TreeTableMetrics.actionAreaWidth, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func headerButton(label: String, column: TreeSortKey.Column) -> some View {
        Button {
            sortKey = sortKey.toggled(to: column)
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if sortKey.column == column {
                    Image(systemName: sortKey.isDescending ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(String(format: String(localized: "tree.column.sort_help", bundle: .module), label))
    }
}

/// **v1.5.4 性能修复**：扁平树行的轻量数据载体。
/// `row` 走 [TreeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L139)
/// 自身的 path 当 SwiftUI 的 `id`，`depth` 决定 indent 缩进。
/// `Hashable` 由 TreeRow / Int 自动合成，让 onChange/diff 能用值比较。
///
/// **v2026.06 Step 1【P0-1 verdict 缓存】**：新增 stored `verdict`。
/// 旧版 [TreeNodeRow.isTrashable](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// 在 SwiftUI 重绘 hot path 上每帧调 `safety.evaluate(path:)` →
/// 4w 节点 60fps 主线程压垮。
/// 改为 [rebuildFlatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// 一次性算好塞到这里，body 只读字段，evaluator 调用次数 == 行数（不再随重绘倍增）。
/// 回归契约见 [FlatTreeRowVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)。
struct FlatTreeRow: Identifiable, Hashable {
    let row: TreeRow
    let depth: Int
    let verdict: SafetyVerdict
    /// v2026.06.20 当本行是"加载占位行"时为 true。占位行 id 用父路径 + "::__loading__"
    /// 后缀，避免与真实 path 冲突；UI 端只渲染一个 ProgressView + "加载中…" 文案，
    /// 不响应点击 / 不算入选中态 / 不进入键盘导航候选集。
    var isLoadingPlaceholder: Bool = false
    /// v2026.06.20：占位行的 id 不能用 `row.path`（会与真实 path 冲突 / 影响 selectedPath
    /// 等键盘导航逻辑），改用 `row.path + "::__loading__"`。普通行保持原行为。
    var id: String {
        isLoadingPlaceholder ? "\(row.path)::__loading__" : row.path
    }
}

/// **v1.5.4 重构**：单行树节点视图（不再递归自身）。
/// 旧版 `TreeNodeView` 在 body 内部嵌套 `ForEach(directChildren)` + 自递归，
/// 4w 节点级一次重绘要重新拍平整棵展开树几次，导致点击展开 200~500ms 卡顿。
/// 新版只渲染**一行**，子项由外层 [TreeBrowserView.flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// 在 onChange 时一次性扁平化好，顶层 ForEach 平铺渲染。
struct TreeNodeRow: View {
    let flat: FlatTreeRow
    let maxBytes: Int64
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    /// 上层透传的"移到废纸篓"通道（已包含二次确认 wrapper）。nil 时菜单项与行内 trash 按钮都不展示。
    let onTrash: ((URL) -> Void)?
    /// v2026.06 #1：右键"刷新此目录"回调。nil 或本行非 directory 时菜单不展示。
    let onRefreshSubtree: ((String) -> Void)?
    /// v2026.06.18 **加入待处理**回调（购物车）。nil 时 contextMenu 不展示该项。
    let onStash: ((TreeRow) -> Void)?
    /// v2026.06.18 当前行是否已加入待处理。true 时按钮置灰 + 改文案。
    let isStashed: Bool
    /// v2026.06.20 AI 设置（决定 sparkles 按钮可点 / 灰）。nil 时同 readonly：按钮根本不出现。
    let aiSettings: AISettings?
    /// v2026.06.20 AI 入口回调。给 nil 时按钮不出现；给值后未配置 → disabled + 提示去设置。
    let onAskAI: ((TreeRow) -> Void)?

    private var row: TreeRow { flat.row }
    private var indent: CGFloat { CGFloat(flat.depth) * 16 }
    /// v1.3.zzzz：accessDenied 目录不允许展开（即便 hasChildren=true 也只是 SQL 边角）。
    private var canExpand: Bool {
        row.isDirectory && row.hasChildren && row.accessState == .normal
    }
    /// **v1.5.3**：本行能否被行内 trash 按钮删除。
    ///
    /// **v2026.06 Step 1**：不再每帧调 `safety.evaluate(path:)`——
    /// verdict 已由 [TreeBrowserView.computeVerdicts](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 在 rebuildFlatRows 阶段一次性算好塞进 [FlatTreeRow.verdict](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
    /// 这里仅做 O(1) 字段读取，让 SwiftUI 重绘 hot path 完全不碰 SafetyEngine。
    private var isTrashable: Bool {
        guard onTrash != nil else { return false }
        if row.accessState != .normal { return false }
        return flat.verdict != .forbid
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: indent, height: 1)
            // 披露三角（叶子用空白占位保持对齐）
            Group {
                if canExpand {
                    Button {
                        onToggleExpand()
                    } label: {
                        // bug 1：22x22 hit area，与 Finder/DaisyDisk 看齐。
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded
                          ? String(localized: "tree.disclose.collapse", bundle: .module)
                          : String(localized: "tree.disclose.expand", bundle: .module))
                } else {
                    Spacer().frame(width: 22, height: 22)
                }
            }
            TreeBrowserRow(row: row, maxBytes: maxBytes)
            // v2026.06.21 反馈修复：在数据 Row 与「操作」按钮组之间也插入与表头
            // 一致的 12pt 间隙（表头 mtime 与 actions 同样间隔 12pt），避免行内
            // mtime 数字与三枚按钮贴在一起，跟表头列宽完全对齐。
            // 注意：HStack 自身 spacing=6 已贡献了 6pt，再加 6pt 凑到 12pt。
            Spacer().frame(width: 6, height: 1)
            // v2026.06.20 **行内"问 AI"按钮**——抽到独立 helper 减轻 body 的 type-check 负担。
            // 详细注释见 [aiActionButton](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
            aiActionButton
            // v2026.06.20 **行内"加入待处理"按钮**——放在 trash 之前，作为"非破坏性
            // 暂存"的快速通道，与右键菜单完全等价。状态可视：未加入时显示空托盘
            // 图标（`tray.and.arrow.down`），已加入显示满托盘（`tray.full.fill`）
            // + 置灰 + 鼠标悬停文案改成"已在待处理"。
            //
            // 设计要点：
            // 1. 用 `isStashed` 字段（外层 `TreeBrowserView` 把 `stash.contains(path)`
            //    映射进来，O(1) Set 查询）决定 icon / 文案 / disabled，不在 row body
            //    重算时回查 StashStore，避免 SwiftUI hot path 多一次跨 Observable 订阅。
            // 2. 行内按钮永远存在（只要 onStash 非 nil），不依赖 `onTrash`——
            //    待处理本身不是破坏性操作，readonly 视图同样应允许暂存。
            // 3. `.buttonStyle(.plain)` + 22pt hit area，与三角披露 / trash 按钮一致，
            //    Finder 风手感。
            if let onStash {
                Button {
                    guard !isStashed else { NSSound.beep(); return }
                    onSelect()
                    onStash(row)
                } label: {
                    Image(systemName: isStashed ? "tray.full.fill" : "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isStashed ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isStashed)
                .help(isStashed
                      ? String(localized: "tree.row.stash.already", bundle: .module)
                      : String(localized: "tree.row.stash", bundle: .module))
            }
            // **v1.5.3**：行内 trash 按钮——单击 = 立刻调 onTrash（已经过外层二次确认 wrapper）。
            if let onTrash {
                Button {
                    guard isTrashable else { NSSound.beep(); return }
                    onSelect()
                    onTrash(URL(fileURLWithPath: row.path))
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isTrashable ? Color.red : Color.secondary.opacity(0.35))
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isTrashable)
                .help(isTrashable
                      ? String(localized: "tree.row.trash", bundle: .module)
                      : String(localized: "tree.row.trash.locked", bundle: .module))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v2026.06.23 perf v2（Instruments 第五次取证 33334.md 14.23s）：
        // 上一刀 .frame(height: 26) 无效——栈里 NSTableRowData._doAutomaticRowHeightForRowView
        // 5.40s + _uncachedAutomaticRowHeight 5.39s 仍走 auto row height。
        // SwiftUI .frame(height:) 等价于 (minHeight:idealHeight:maxHeight: nil)，
        // NSHostingView 仍会 sizeThatFits 内部 child 来定 ideal。
        // 改用 (minHeight: maxHeight:) 把上下界都钉死成 26，NSHostingView 拿到的就是
        // 刚性 26pt 约束，跳过整条 _FlexFrameLayout → _AlignmentLayout → _PaddingLayout
        // → StackLayout 嵌套 sizeThatFits 链。
        // 26 = 行内最大元素（22pt chevron/icon） + 上下 padding(.vertical, 1) × 2。
        .frame(minHeight: 26, maxHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.65) : Color.clear,
                                      lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard canExpand else { return }
            onToggleExpand()
        }
        .onTapGesture(count: 1) {
            // 单击整行：选中 + 切展开（仅可展开行）；与旧版行为一致。
            onSelect()
            if canExpand {
                onToggleExpand()
            }
        }
        .contextMenu {
            if let onTrash {
                // v2026.06 Step 1：contextMenu 也走 verdict 缓存。
                // contextMenu 在右键弹出时才求值（不算最 hot path），但既然已经算好就一起复用，
                // 一致性比微优化重要：后续维护者看到一处就知道全局都不再调 evaluate。
                let isForbidden = (flat.verdict == .forbid)
                Button(role: .destructive) {
                    guard !isForbidden else { return }
                    onSelect()
                    onTrash(URL(fileURLWithPath: row.path))
                } label: {
                    Label {
                        Text(isForbidden
                             ? "tree.menu.trash_forbidden"
                             : "tree.menu.trash",
                             bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isForbidden)
                .keyboardShortcut(.delete, modifiers: [])
                // v2026.06.18 **加入待处理**入口紧邻"移到废纸篓"，与"清空-vs-囤起来"
                // 是同一动作面的两种处置方式，放在一起手感更对。
                if let onStash {
                    Button {
                        onSelect()
                        onStash(row)
                    } label: {
                        Label {
                            Text(isStashed
                                 ? "tree.menu.stash_already"
                                 : "tree.menu.stash",
                                 bundle: .module)
                        } icon: {
                            Image(systemName: isStashed ? "tray.full.fill" : "tray.and.arrow.down")
                        }
                    }
                    .disabled(isStashed)
                }
                Divider()
            } else if let onStash {
                // 即使 onTrash 缺席（只读视图复用本组件）也允许"加入待处理"
                // —— 待处理本身不是破坏性操作，无需依赖删除链路。
                Button {
                    onSelect()
                    onStash(row)
                } label: {
                    Label {
                        Text(isStashed
                             ? "tree.menu.stash_already"
                             : "tree.menu.stash",
                             bundle: .module)
                    } icon: {
                        Image(systemName: isStashed ? "tray.full.fill" : "tray.and.arrow.down")
                    }
                }
                .disabled(isStashed)
                Divider()
            }
            // v2026.06.20 contextMenu 也提供"问 AI"项，与行内 sparkles 按钮等价。
            //
            // v1.5 P2 / Q3 修复：旧实现"未配置则不显示"——用户根本不知道有 AI 入口
            // 也不会被引导去设置。改为"只要 onAskAI 不为 nil 就显示"：未就绪时同样
            // 回调上层，由 MainView 在 callback 内弹"AI 未配置，前往设置？"alert，
            // 跟 List 视图保持一致行为。
            if let onAskAI {
                Button {
                    onSelect()
                    onAskAI(row)
                } label: {
                    Label {
                        Text("tree.menu.ask_ai", bundle: .module)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                Divider()
            }
            Button {
                onSelect()
                QuickLookController.shared.preview(urls: [URL(fileURLWithPath: row.path)])
            } label: {
                Label {
                    Text("tree.menu.quick_look", bundle: .module)
                } icon: {
                    Image(systemName: "eye")
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            } label: {
                Label {
                    Text("tree.menu.reveal_in_finder", bundle: .module)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            Divider()
            if row.isDirectory, let onRefreshSubtree {
                Button {
                    onSelect()
                    onRefreshSubtree(row.path)
                } label: {
                    Label {
                        Text("tree.menu.refresh", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
            }
            if canExpand {
                Button {
                    onToggleExpand()
                } label: {
                    Label {
                        Text(isExpanded
                             ? "tree.disclose.collapse"
                             : "tree.disclose.expand",
                             bundle: .module)
                    } icon: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                }
                Divider()
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(row.path, forType: .string)
            } label: {
                Label {
                    Text("tree.menu.copy_path", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString((row.path as NSString).lastPathComponent, forType: .string)
            } label: {
                Label {
                    Text("tree.menu.copy_name", bundle: .module)
                } icon: {
                    Image(systemName: "textformat")
                }
            }
        }
    }

    /// v2026.06.20 行内"问 AI"按钮（sparkles）。抽到独立 ViewBuilder 以
    /// 防止 TreeNodeRow.body 过长触发 SwiftUI 编译器 "unable to type-check
    /// in reasonable time"。语义与 RowView 的 AI 入口对齐：
    /// - `onAskAI == nil` → 不出现（readonly / 无 AI 入口的视图）
    /// - `onAskAI != nil` 但 `aiSettings == nil || !isReadyForUI` →
    ///   出现，**淡 sparkles + tooltip 提示 "AI 未配置，点击前往设置"**，
    ///   点击仍回调 `onAskAI(row)`，由上层弹"前往设置？"alert（Q3 修复）
    /// - 都满足 → accentColor sparkles + 可点击，回调上层弹 AIAdviceSheet
    @ViewBuilder
    private var aiActionButton: some View {
        if let onAskAI {
            let aiReady = (aiSettings?.isReadyForUI == true)
            Button {
                // v1.5 P2 / Q3：未就绪时不再 beep（用户无感知）——直接回调上层，
                // MainView 负责弹"AI 未配置，前往设置？"alert，给用户明确引导。
                onSelect()
                onAskAI(row)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(aiReady ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(aiReady
                  ? String(localized: "tree.row.ai", bundle: .module)
                  : String(localized: "tree.row.ai.not_configured", bundle: .module))
        }
    }
}

/// 树行视图：图标 + 名称 + size + 体积条。复用 RowView 的视觉语言。
///
/// v1.3.zzzz：当 [row.accessState](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L116)
/// 不是 .normal 时，整行降级渲染：
/// - 文件夹图标后挂一个 lock.fill 小徽章
/// - 文字 / 体积 / 体积条全部走 .tertiary 灰阶
/// - .help() 改成"无访问权限"文案，鼠标 hover 提示用户去开 Full Disk Access
///
/// 这是为了治"我的 [Library/Safari](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L172)
/// 显示 0 KB 是不是 bug？"这一类用户疑惑——根因是
/// open(O_RDONLY) silent-deny，UI 必须把"被拒"和"真 0KB"区分开。
struct TreeBrowserRow: View {
    let row: TreeRow
    let maxBytes: Int64

    private var ratio: CGFloat {
        guard maxBytes > 0 else { return 0 }
        return CGFloat(Double(row.bytes) / Double(maxBytes))
    }

    /// 是否被权限拦掉（permissionDenied / tccProtected 都算）
    private var isAccessDenied: Bool { row.accessState != .normal }

    /// 文案分两档：tccProtected 是用户层"sandbox 整段拒"，
    /// permissionDenied 是运行时 open 失败；都建议用户去开 FDA 但措辞不同。
    private var deniedHelp: String {
        switch row.accessState {
        case .normal: return row.path
        case .permissionDenied:
            return String(format: String(localized: "tree.access.permission_denied", bundle: .module), row.path)
        case .tccProtected:
            return String(format: String(localized: "tree.access.tcc_protected", bundle: .module), row.path)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // 图标 + 锁定叠加徽章（仅 accessDenied 时显示）
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(
                        isAccessDenied
                            ? Color.secondary.opacity(0.5)
                            : (row.isDirectory ? Color.accentColor : Color.secondary)
                    )
                    .frame(width: 16)
                if isAccessDenied {
                    // 右下角 8pt 锁徽章；用 capsule 衬底防止跟文件夹尖角混在一起
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Color.orange))
                        .offset(x: 4, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title.isEmpty ? row.path : row.title)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(isAccessDenied ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                isAccessDenied
                                    ? Color.secondary.opacity(0.25)
                                    : Color.accentColor.opacity(row.isDirectory ? 0.7 : 0.4)
                            )
                            .frame(width: geo.size.width * ratio, height: 3)
                    }
                }
                .frame(height: 3)
            }
            // accessDenied 时把 size 改成"—"，避免"0 KB"的误导性显示
            Text(isAccessDenied
                 ? "—"
                 : ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isAccessDenied ? .tertiary : .secondary)
                .frame(width: 90, alignment: .trailing)
            Text(isAccessDenied ? "—" : "\(row.fileCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
            // v1.5.4：mtime 列——与 LargeFilesView 文案风格一致，省"x天前"等本地化偏差。
            // accessDenied 行直接画"—"避免误导；mtime 缺失（极早期 publish 帧或 root 顶层）也画"—"。
            Text(TreeBrowserRow.mtimeDisplay(row.modificationDate, denied: isAccessDenied))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 98, alignment: .trailing)
                .help(TreeBrowserRow.mtimeFullHelp(row.modificationDate))
        }
        .padding(.vertical, 2)
        .opacity(isAccessDenied ? 0.7 : 1.0)
        .help(deniedHelp)
    }

    /// v1.5.4：列内 mtime 短文案。
    /// - accessDenied → "—"（语义："无法访问"）
    /// - 目录/文件存在但无 mtime（聚合根 / 虚拟节点 / 首帧 publish）→ "·"
    ///   v2026.06.18：用户反馈"为什么 Modified 没有了"——根行（如"Xcode Build Artifacts"）
    ///   是聚合虚拟节点，没有自身 inode，所以拿不到 mtime。把"—"和"·"区分开能让
    ///   用户一眼看出"这不是 bug，是这一行本来就没有自己的修改时间"。
    /// - 当年 → "MM-dd"
    /// - 跨年 → "yyyy-MM-dd"
    /// 用 cached formatter 避免每行重新建（SwiftUI body 高频重算）。
    static func mtimeDisplay(_ date: Date?, denied: Bool) -> String {
        if denied { return "—" }
        guard let date else { return "·" }
        let cal = Calendar.current
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.shortFormatter.string(from: date)
        }
        return Self.fullFormatter.string(from: date)
    }

    /// 鼠标悬停时显示完整时间——窄列里的省略不丢精度。
    /// v2026.06.18：mtime 缺失时给出明确的解释，避免被误解为"bug 没读到"。
    static func mtimeFullHelp(_ date: Date?) -> String {
        guard let date = date else {
            return String(localized: "tree.column.mtime.aggregate_help", bundle: .module)
        }
        return Self.fullDateTimeFormatter.string(from: date)
    }

    /// 列内默认值：MM-dd（同年）。
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        f.locale = Locale.current
        return f
    }()

    /// 列内：跨年改 yyyy-MM-dd。
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale.current
        return f
    }()

    /// help/tooltip：完整本地化日期+时间。
    private static let fullDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale.current
        return f
    }()
}
