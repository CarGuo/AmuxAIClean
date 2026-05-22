import SwiftUI
import AppKit

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

    @State private var sortKey: TreeSortKey = .sizeDesc
    @State private var selectedPath: String?
    /// 各节点是否展开（path -> Bool）；放在父视图集中管理，
    /// 才能让 h/l 键盘事件去操控"当前选中节点"的展开状态。
    @State private var expanded: [String: Bool] = [:]
    @FocusState private var focused: Bool

    public init(coordinator: ScanCoordinator, rootPath: String) {
        self.coordinator = coordinator
        self.rootPath = rootPath
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
                                    expanded: $expanded
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
            // 与 TreeBrowserRow 的 icon + 三角占位对齐：12（三角）+ 6（间距）+ 16（icon）= 34
            Spacer().frame(width: 34)
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

    private var indent: CGFloat { CGFloat(depth) * 16 }
    private var canExpand: Bool { row.isDirectory && row.hasChildren }
    private var isExpanded: Bool { expanded[row.path] ?? false }
    private var isSelected: Bool { selectedPath == row.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // 披露三角（叶子用空白占位保持对齐）
                Group {
                    if canExpand {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expanded[row.path] = !isExpanded
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer().frame(width: 12, height: 12)
                    }
                }
                TreeBrowserRow(row: row, maxBytes: maxBytes)
            }
            .padding(.leading, indent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPath = row.path
            }
            .id(row.path)
            .contextMenu {
                if !row.isDirectory {
                    Button {
                        QuickLookController.shared.preview(urls: [URL(fileURLWithPath: row.path)])
                    } label: {
                        Label("快速预览（空格）", systemImage: "eye")
                    }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(row.path, forType: .string)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
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
                        expanded: $expanded
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
