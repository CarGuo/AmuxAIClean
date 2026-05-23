import SwiftUI
import AppKit
import SafetyKit

/// v1.0 T3 / T5：多层下钻浏览器 + 列排序 + 键盘导航。
///
/// 设计要点（参考 DaisyDisk / OmniDS / Pearcleaner）：
/// 1. 用递归 DisclosureGroup（而不是 OutlineGroup）—— OutlineGroup 在 Swift 6 严格并发
///    下要求 KeyPath 形式预先把整棵树构建好，而我们的数据是 lazy 按需取的。
/// 2. children 走 lazy 计算：DisclosureGroup 展开时才向 ScanCoordinator 询问下一层，
///    避免一开始就构建整棵树（PITFALLS §5.4 同款，4w 文件不能一次性 yield 给 List）。
/// 3. 数据来源是 `ScanCoordinator.directChildren(of:sortedBy:)`，按当前 `sortKey` 排序。
/// 4. 行内右键菜单：在 Finder 中显示 / 复制路径（删除走主界面已有的 sheet）。
/// 5. T5 新增：
///    - 列表头：大小 / 名称 / 数量 三列，点击切排序，再点切升降序
///    - 键盘导航：j/k 上下移动选中、h 折叠当前、l 展开当前、Enter 切展开、
///      Cmd+R 在 Finder 显示、Delete 暂未参与勾选（保持"树视图只浏览"的产品策略）
///    - 选中态：当前选中行用 selection 高亮 + accessibility focus
public struct TreeBrowserView: View {
    @ObservedObject var coordinator: ScanCoordinator
    let rootPath: String
    /// 选中行变化时的回调；MainView 用它把 TreeRow 喂给右侧详情面板。
    /// 设计 bug A：之前 selectedPath 只活在 TreeBrowserView 内部，
    /// 外层 detailPane 永远拿不到，导致"选中一行没有详情"。
    let onSelect: ((TreeRow) -> Void)?
    /// 右键 / Delete 触发"移到废纸篓"时的回调（v1.3 bug "树形怎么扔废纸篓"）。
    /// 走 NSWorkspace.recycle 通道（与大文件视图右键删共用 triggerLargeFileTrash）。
    /// 给 nil 时 TreeNodeView 不会展示该菜单项，便于在 readonly 场景复用。
    let onTrash: ((URL) -> Void)?

    /// SafetyEngine 静态共享：拦截 forbid 路径（家目录、`/`、SIP、`..` 等），
    /// 在弹菜单时就 disabled 那条「移到废纸篓…」并附 tooltip 解释为什么不能删，
    /// 避免用户点了之后 NSWorkspace.recycle 才报错那种"晚反馈"。
    static let safety = SafetyEngine()

    @State private var sortKey: TreeSortKey = .sizeDesc
    @State private var selectedPath: String?
    /// 各节点是否展开（path -> Bool）；放在父视图集中管理，
    /// 才能让 h/l 键盘事件去操控"当前选中节点"的展开状态。
    @State private var expanded: [String: Bool] = [:]
    @FocusState private var focused: Bool

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
        let topLevel = coordinator.directChildren(of: rootPath, sortedBy: sortKey)
        let maxBytes = topLevel.map(\.bytes).max() ?? 0
        VStack(spacing: 0) {
            TreeColumnHeader(sortKey: $sortKey)
            Divider()
            if topLevel.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tree")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("还没有可展开的子节点")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(topLevel) { row in
                                TreeNodeView(
                                    row: row,
                                    maxBytes: maxBytes,
                                    depth: 0,
                                    coordinator: coordinator,
                                    sortKey: sortKey,
                                    selectedPath: $selectedPath,
                                    expanded: $expanded,
                                    onTrash: onTrash
                                )
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
        // bug B：.focusable() 让本视图能接收键盘事件（j/k/h/l/Space 必备），
        // 但 macOS SwiftUI 默认会给可获焦容器画一圈蓝色 focus ring，
        // 在我们这种"整段表格被框住"的场景里非常显眼且割裂。
        // 选中态我们已经用 row 自身 background 实现，不需要外层焦点环。
        .focusEffectDisabled()
        .onAppear {
            // 扫描完成后自动聚焦第一行（ROADMAP T5 验收点）
            if selectedPath == nil, let first = topLevel.first {
                selectedPath = first.path
            }
            focused = true
        }
        .onChange(of: topLevel.map(\.path)) { _, new in
            // 切排序 / 切扫描根 → 回弹到第一行，避免选中飞走
            if let cur = selectedPath, !visiblePaths(rootKids: new).contains(cur) {
                selectedPath = new.first
            } else if selectedPath == nil {
                selectedPath = new.first
            }
        }
        .onChange(of: selectedPath) { _, new in
            // bug A：把选中行回调给 MainView，让右侧详情面板能跟上。
            // 单击 row、键盘 j/k 移动、自动聚焦首行 三种来源都会经过这里。
            //
            // bug 1 性能修复：之前用 visibleRows.first(where:) 等于把整棵展开树
            // 重新拍平递归一遍（O(N)，4w 节点级几百毫秒卡顿），改为 coordinator
            // 字典 O(1) 反查。
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
               let row = visibleRows.first(where: { $0.path == cur }),
               !row.isDirectory {
                QuickLookController.shared.preview(urls: [URL(fileURLWithPath: cur)])
                return .handled
            }
            toggleExpansion()
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("r")]) { press in
            // Cmd+R：在 Finder 中显示当前选中
            if press.modifiers.contains(.command) {
                revealInFinder(); return .handled
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            // Finder 风格：选中行按 Delete = 移到废纸篓。
            // 必须先过 SafetyEngine forbid 闸门，避免误把家目录 / `/` 这种扔进废纸篓。
            guard let cur = selectedPath, let onTrash else { return .ignored }
            let (verdict, _) = Self.safety.evaluate(path: cur)
            guard verdict != .forbid else {
                NSSound.beep()
                return .handled
            }
            onTrash(URL(fileURLWithPath: cur))
            return .handled
        }
    }

    // MARK: - 键盘导航辅助

    /// 当前可见行（按展开状态拍平，顺序遵从当前 sortKey）。
    /// j/k 按这个数组找 prev/next；h/l 操作 expanded[selectedPath]。
    private var visibleRows: [TreeRow] {
        var out: [TreeRow] = []
        appendRows(parentPath: rootPath, into: &out)
        return out
    }

    private func appendRows(parentPath: String, into out: inout [TreeRow]) {
        let kids = coordinator.directChildren(of: parentPath, sortedBy: sortKey)
        for k in kids {
            out.append(k)
            if k.isDirectory && (expanded[k.path] ?? false) {
                appendRows(parentPath: k.path, into: &out)
            }
        }
    }

    private func visiblePaths(rootKids: [String]) -> Set<String> {
        Set(visibleRows.map(\.path)).union(rootKids)
    }

    private func moveSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        if let cur = selectedPath, let idx = rows.firstIndex(where: { $0.path == cur }) {
            let next = max(0, min(rows.count - 1, idx + delta))
            selectedPath = rows[next].path
        } else {
            selectedPath = rows.first?.path
        }
    }

    private func setExpansion(_ open: Bool) {
        guard let cur = selectedPath else { return }
        // 只对目录有意义；文件忽略
        let rows = visibleRows
        if let row = rows.first(where: { $0.path == cur }), row.isDirectory && row.hasChildren {
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
        let rows = visibleRows
        guard let row = rows.first(where: { $0.path == cur }), row.isDirectory && row.hasChildren else { return }
        expanded[cur] = !(expanded[cur] ?? false)
    }

    /// 在已"可见"的行中找当前 path 的父节点路径（不在可见集合时返回 nil）。
    /// 之所以限定可见，是因为 h 操作要"跳回当前可见的父"，跳到一个被折起来的父没意义。
    private func parentVisible(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == rootPath { return nil }
        return visibleRows.first(where: { $0.path == parent })?.path
    }

    private func revealInFinder() {
        guard let cur = selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cur)])
    }
}

/// 列表头：三列可点击切排序。
struct TreeColumnHeader: View {
    @Binding var sortKey: TreeSortKey

    var body: some View {
        HStack(spacing: 10) {
            // 与 TreeBrowserRow 的 icon + 三角占位对齐：22（三角 hit area）+ 6（间距）+ 16（icon）= 44
            Spacer().frame(width: 44)
            headerButton(label: "名称", column: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerButton(label: "大小", column: .size)
                .frame(width: 90, alignment: .trailing)
            headerButton(label: "数量", column: .count)
                .frame(width: 56, alignment: .trailing)
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
        .help("按\(label)排序（再次点击切换升降序）")
    }
}

/// 单层树节点视图：自递归 —— 展开时取下一层 directChildren 再实例化自己。
struct TreeNodeView: View {
    let row: TreeRow
    let maxBytes: Int64
    let depth: Int
    @ObservedObject var coordinator: ScanCoordinator
    let sortKey: TreeSortKey
    @Binding var selectedPath: String?
    @Binding var expanded: [String: Bool]
    /// 上层透传的"移到废纸篓"通道。nil 时菜单项不展示。
    let onTrash: ((URL) -> Void)?

    private var indent: CGFloat { CGFloat(depth) * 16 }
    private var canExpand: Bool { row.isDirectory && row.hasChildren }
    private var isExpanded: Bool { expanded[row.path] ?? false }
    private var isSelected: Bool { selectedPath == row.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // v1.3 bug fix：把选中高亮拉到整行宽度（不被 indent 切片）；
            // 单击 = 选中、双击 = 展开/折叠（与 Finder/DaisyDisk 一致）。
            HStack(spacing: 6) {
                // 缩进占位放进 HStack 内部，让外层 background 占满整行
                Spacer().frame(width: indent, height: 1)
                // 披露三角（叶子用空白占位保持对齐）
                Group {
                    if canExpand {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expanded[row.path] = !isExpanded
                            }
                        } label: {
                            // bug 1：chevron 之前是 12x12 hit area 太小，鼠标得精准点中三角才生效；
                            // Finder/DaisyDisk 的披露三角约 20x20。这里画 10pt 字号但用
                            // 22x22 .contentShape 把可点区域扩到整个 chevron 槽位。
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "折叠" : "展开")
                    } else {
                        Spacer().frame(width: 22, height: 22)
                    }
                }
                TreeBrowserRow(row: row, maxBytes: maxBytes)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // bug 2：选中态之前 0.18 透明度太弱看不清；改 0.30 + 加 1pt 描边，
                // 保证浅色 / 深色模式下都能一眼看到当前选中行。
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
                // 双击：仅对可展开的目录有效，触发展开/折叠
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded[row.path] = !isExpanded
                }
            }
            .onTapGesture(count: 1) {
                selectedPath = row.path
            }
            .id(row.path)
            .contextMenu {
                // bug 2：右键菜单（之前其实已存在，但选中框太弱让用户以为没右键）。
                // 这一轮补齐：
                //   - 任意类型节点都能"快速预览"（Finder 风格 Quick Look）
                //   - 加"复制名称"
                //   - 目录单独有"展开/折叠"快捷
                //   - 顶部加「移到废纸篓…」（v1.3，受 onTrash 控制；
                //     SafetyEngine 拦截家目录 / `/` / SIP / `..`）
                if let onTrash {
                    let (verdict, _) = TreeBrowserView.safety.evaluate(path: row.path)
                    let isForbidden = (verdict == .forbid)
                    Button(role: .destructive) {
                        guard !isForbidden else { return }
                        selectedPath = row.path
                        onTrash(URL(fileURLWithPath: row.path))
                    } label: {
                        Label(isForbidden ? "无法移除（系统保护路径）" : "移到废纸篓…",
                              systemImage: "trash")
                    }
                    .disabled(isForbidden)
                    .keyboardShortcut(.delete, modifiers: [])
                    Divider()
                }
                Button {
                    selectedPath = row.path
                    QuickLookController.shared.preview(urls: [URL(fileURLWithPath: row.path)])
                } label: {
                    Label("快速预览（空格）", systemImage: "eye")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                Divider()
                if canExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expanded[row.path] = !isExpanded
                        }
                    } label: {
                        Label(isExpanded ? "折叠" : "展开", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    Divider()
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(row.path, forType: .string)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString((row.path as NSString).lastPathComponent, forType: .string)
                } label: {
                    Label("复制名称", systemImage: "textformat")
                }
            }

            if isExpanded && canExpand {
                let kids = coordinator.directChildren(of: row.path, sortedBy: sortKey)
                ForEach(kids) { kid in
                    TreeNodeView(
                        row: kid,
                        maxBytes: maxBytes,
                        depth: depth + 1,
                        coordinator: coordinator,
                        sortKey: sortKey,
                        selectedPath: $selectedPath,
                        expanded: $expanded,
                        onTrash: onTrash
                    )
                }
            }
        }
    }
}

/// 树行视图：图标 + 名称 + size + 体积条。复用 RowView 的视觉语言。
struct TreeBrowserRow: View {
    let row: TreeRow
    let maxBytes: Int64

    private var ratio: CGFloat {
        guard maxBytes > 0 else { return 0 }
        return CGFloat(Double(row.bytes) / Double(maxBytes))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(row.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title.isEmpty ? row.path : row.title)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(row.isDirectory ? 0.7 : 0.4))
                            .frame(width: geo.size.width * ratio, height: 3)
                    }
                }
                .frame(height: 3)
            }
            Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text("\(row.fileCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help(row.path)
    }
}
