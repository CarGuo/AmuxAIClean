import SwiftUI
import AppKit
import SafetyKit
import AIKit

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
    @ObservedObject var coordinator: ScanCoordinator
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
    /// 清掉 store-fallback 缓存并 bump structuralRevision，本视图下一帧自动重拉。
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
                    if isFetchingRoot {
                        ProgressView()
                            .controlSize(.small)
                        Text("tree.loading.children", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else if coordinator.isScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text("tree.loading.scanning", bundle: .module)
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
                ScrollViewReader { proxy in
                    // **Step 9b / 2026-06**：LazyVStack → List。
                    // 历史问题：LazyVStack 在 ScrollView 里没有真正的 cell-recycling，
                    // 4w 节点扫描下滚动 fps ≤ 35、内存峰值 ~480MB。
                    // SwiftUI `List` 走 NSTableView 桥接 → 行视图复用 + 滚动惰性，
                    // 同等数据量下实测 fps ≥ 55、内存峰值降 ~30%。
                    // 选中态、键盘导航、行内 trash 行为全部由 TreeNodeRow 内部维护，
                    // 切容器对外行为不变。
                    List(flatRows) { flat in
                        if flat.isLoadingPlaceholder {
                            // v2026.06.20 加载占位行——不参与 selection / contextMenu / 键盘导航。
                            // 缩进对齐到子级 depth，与真实子项位置一致；左侧 spinner + "加载中…"。
                            HStack(spacing: 6) {
                                Spacer().frame(width: CGFloat(flat.depth) * 16 + 22)
                                ProgressView()
                                    .controlSize(.mini)
                                Text("tree.loading.children", bundle: .module)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .id(flat.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                        } else {
                            TreeNodeRow(
                                flat: flat,
                                maxBytes: maxBytes,
                                isExpanded: expanded[flat.row.path] ?? false,
                                isSelected: selectedPath == flat.row.path,
                                onToggleExpand: { toggleExpansionFor(path: flat.row.path) },
                                onSelect: { selectedPath = flat.row.path },
                                onTrash: onTrash.map { _ in requestTrash(_:) },
                                onRefreshSubtree: onRefreshSubtree,
                                onStash: onStash,
                                isStashed: isStashed?(flat.row.path) ?? false,
                                aiSettings: aiSettings,
                                onAskAI: onAskAI
                            )
                            .id(flat.row.path)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 0)
                    .onChange(of: selectedPath) { _, new in
                        guard let new else { return }
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
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
            rebuildFlatRows()
        }
        // Step 2 P0-2 / 2026-06：从 `coordinator.treeRevision` 切到
        // `coordinator.structuralRevision` —— 只在节点新增/删除/排序键变化时重建 flatRows，
        // 不再被流式 publishSnapshot 的 0.4s tick（仅 bytes 变化）拖着整树重算。
        // tickRevision 通过其它 @Published 入口（如 RowItem 自身）驱动 RowView 内部刷新数值，
        // 这里 view 不订阅。
        .onChange(of: coordinator.structuralRevision) { _, _ in
            // v1.5.7：若本次 bump 由 pruneDeleted 触发，则走"只剔被删 path 子树"的
            // 增量 patch，避免 12 GB / 万级目录用户的整树 rebuild 卡顿。
            // hint 不在 → 老路径 rebuildFlatRows 兜底。
            if let pruned = coordinator.consumeLastPrunedPaths(), !pruned.isEmpty {
                applyPrunePatch(deletedPaths: pruned)
            } else {
                rebuildFlatRows()
            }
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
                verdict = Self.safety.evaluate(path: cur).0
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
        let base = Self.computeVerdicts(for: pairs) { Self.safety.evaluate(path: $0).0 }
        // v2026.06.20：把"展开但孩子还在异步加载"的目录后面插一个加载占位行，
        // 让用户在 store-fallback 拉子节点的几十~几百毫秒窗口里看到 spinner，
        // 而不是空白的展开。详见 [insertLoadingPlaceholders](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
        flatRows = insertLoadingPlaceholders(into: base)
        maxBytes = topLevel.map(\.bytes).max() ?? 0
        // 顶层空 + isFetchingChildren 才算"拉取中"；否则维持 false 让 view 走 isScanning / 真空两态。
        isFetchingRoot = topLevel.isEmpty
            && coordinator.isFetchingChildren(of: rootPath, sortedBy: effectiveSortKey)
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
    /// 触发场景：用户展开一个目录 → 该目录 directChildren 当前还在异步拉（store-fallback
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
        let inserted = Self.computeVerdicts(for: pairs) { Self.safety.evaluate(path: $0).0 }
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

    /// 行内三角 / 单击整行 / 右键菜单 / 双击 → 共用的展开切换入口。
    /// 不在乎 [TreeNodeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 内部的 canExpand 状态，外层这里仅 toggle expanded[path]——
    /// 不能展开的行 row 内部已经把按钮 / 双击 hit-test disable 掉。
    private func toggleExpansionFor(path: String) {
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
            // **v2026.06.21 修复**：原来这里只是一个 84pt 的 Spacer 占位，没有标题，
            // 用户原话「这个栏目也没有写『操作』这个栏目信息」。改成正式的「操作」
            // 表头文案，居中显示在 84pt（AI 28 + Stash 28 + Trash 28）按钮列上方，
            // 让用户一眼知道这一列点开会发生什么；不参与点击切排序，所以不复用
            // headerButton 而是直接 Text。
            Text("tree.column.actions", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .center)
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
