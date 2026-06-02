import SwiftUI
import AppKit
import SafetyKit

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

    /// SafetyEngine 静态共享：拦截 forbid 路径（家目录、`/`、SIP、`..` 等），
    /// 在弹菜单 / 行内 trash 按钮 hit-test 时就 disabled，并附 tooltip 解释为什么不能删。
    static let safety = SafetyEngine()

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
                onTrash: ((URL) -> Void)? = nil) {
        self.coordinator = coordinator
        self.rootPath = rootPath
        self.onSelect = onSelect
        self.onTrash = onTrash
    }

    public var body: some View {
        // v1.5.4：body 不再调 directChildren / isFetchingChildren——所有可见行的源数据
        // 都收口在 [flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
        // 这一份扁平 @State 里。view 重算只读 state，重建在 onChange / onAppear 里发生，
        // 不会被 SwiftUI 的 diff 频繁触发递归。
        VStack(spacing: 0) {
            TreeColumnHeader(sortKey: $sortKey)
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // v1.5.4：顶层 ForEach 平铺所有可见行（root 子项 + 所有展开后代）。
                            // 每行通过 [TreeNodeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
                            // 渲染（不再递归自身）。SwiftUI diff 走数组 id（path）一次比对完成。
                            ForEach(flatRows) { flat in
                                TreeNodeRow(
                                    flat: flat,
                                    maxBytes: maxBytes,
                                    isExpanded: expanded[flat.row.path] ?? false,
                                    isSelected: selectedPath == flat.row.path,
                                    onToggleExpand: { toggleExpansionFor(path: flat.row.path) },
                                    onSelect: { selectedPath = flat.row.path },
                                    onTrash: onTrash.map { _ in requestTrash(_:) }
                                )
                                .id(flat.row.path)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
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
        .onChange(of: expanded) { _, _ in rebuildFlatRows() }
        .onChange(of: sortKey) { _, _ in rebuildFlatRows() }
        .onChange(of: rootPath) { _, _ in
            // 切扫描根：清掉旧 expanded 防止脏 path 残留撑起 flatRows
            expanded.removeAll(keepingCapacity: true)
            rebuildFlatRows()
        }
        // coordinator.treeRevision：聚合了 publishSnapshot / cache 写回 / pruneDeleted / cancel
        // / invalidate 等所有上游变更（详见 ScanCoordinator.treeRevision 注释）。
        .onChange(of: coordinator.treeRevision) { _, _ in rebuildFlatRows() }
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
            guard let new, let row = coordinator.row(for: new) else { return }
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
        let topLevel = coordinator.directChildren(of: rootPath, sortedBy: sortKey)
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
        flatRows = Self.computeVerdicts(for: pairs) { Self.safety.evaluate(path: $0).0 }
        maxBytes = topLevel.map(\.bytes).max() ?? 0
        // 顶层空 + isFetchingChildren 才算"拉取中"；否则维持 false 让 view 走 isScanning / 真空两态。
        isFetchingRoot = topLevel.isEmpty
            && coordinator.isFetchingChildren(of: rootPath, sortedBy: sortKey)
    }

    private func appendDescendantPairs(parent: String, depth: Int,
                                       into out: inout [(TreeRow, Int)]) {
        let kids = coordinator.directChildren(of: parent, sortedBy: sortKey)
        for k in kids {
            out.append((k, depth))
            if k.isDirectory && (expanded[k.path] ?? false) {
                appendDescendantPairs(parent: k.path, depth: depth + 1, into: &out)
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
            // **v1.5.3**：行内 trash 按钮列宽（28pt），跟 TreeNodeView 对齐——
            // 表头本身不画按钮，只占位让标题列宽与下方一致。
            Spacer().frame(width: 28)
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
    var id: String { row.path }
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
    /// - 缺失 / accessDenied → "—"
    /// - 当年 → "MM-dd"
    /// - 跨年 → "yyyy-MM-dd"
    /// 用 cached formatter 避免每行重新建（SwiftUI body 高频重算）。
    static func mtimeDisplay(_ date: Date?, denied: Bool) -> String {
        guard !denied, let date = date else { return "—" }
        let cal = Calendar.current
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.shortFormatter.string(from: date)
        }
        return Self.fullFormatter.string(from: date)
    }

    /// 鼠标悬停时显示完整时间——窄列里的省略不丢精度。
    static func mtimeFullHelp(_ date: Date?) -> String {
        guard let date = date else { return "" }
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
