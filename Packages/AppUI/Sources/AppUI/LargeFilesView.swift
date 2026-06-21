import SwiftUI
import AppKit

/// v1.0 T4：大文件视图。
///
/// 设计要点（参考 CleanMyMac / Sensei / Pearcleaner 大文件扫描器）：
/// 1. **扁平 Top N 列表**——大文件场景核心是"哪几个最大、最旧"，不需要再下钻；
///    Top N 默认 200（ROADMAP T4），避免一次性渲染数千行卡 UI。
/// 2. **列头点击切排序**——只有 size 与 mtime 两个维度（验收 2 明确）。
///    路径 / 文件名维度不参与排序：大文件页面的决策点是体积与活跃度。
/// 3. **阈值由 AppSettings 提供**——用户在 ⌘, 设置里改 minFileSizeMB，本视图实时反映。
///    若新阈值 < 扫描阈值，提示用户重扫（数据不在内存里就装不出来）。
/// 4. **不显示安全徽章 / 默认勾选**：大文件清理本来就要"用户确认才删"，
///    不能再叫 SafetyEngine 把 ~/Movies/big.mov 标成 .safe。
public struct LargeFilesView: View {
    @ObservedObject var coordinator: ScanCoordinator
    @Bindable var settings: AppSettings

    /// 行内当前选中（用于右侧详情，也作为 .delete 快捷键的锚）。
    @Binding var selection: LargeFileItem?

    /// 移到废纸篓回调；由 MainView 注入，复用主界面的 DeleteSheet 流程。
    let onTrash: ([URL]) -> Void

    /// Top N 截断。默认 200（ROADMAP）。可由调用方覆盖。
    let limit: Int

    /// v1.5 P2 / Q1：当前列表排序键。
    ///
    /// **历史**：之前用 `@State private var sortKey: LargeFileSortKey = .sizeDesc`，
    /// 注释解释是"不污染全局 settings.sortKey"——但实际造成用户在工具栏点全局排序图标
    /// 切到 nameAsc 后，大文件页面依然是 sizeDesc，体验割裂（Q1 根因）。
    ///
    /// **现在**：单向派生自 [AppSettings.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift#L339)
    /// （大文件只有 size+mtime 两列，nameAsc 等 → fallback 到 sizeDesc，见
    /// [LargeFileSortKey.from(global:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L354)）。
    /// 列头点击通过 [sortKeyBinding](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LargeFilesView.swift)
    /// 反向写回全局键，实现双向同步。
    private var sortKey: LargeFileSortKey {
        LargeFileSortKey.from(global: settings.mainListSortKey)
    }

    /// v1.5 P2 / Q1：列头点击使用的 binding —— 写入会回译到全局键。
    private var sortKeyBinding: Binding<LargeFileSortKey> {
        Binding(
            get: { LargeFileSortKey.from(global: settings.mainListSortKey) },
            set: { settings.mainListSortKey = $0.asGlobal }
        )
    }

    /// v1.2 P2-3：当前类型 chip 筛选；nil 表示"全部"。
    /// 与 mtimeFilter 不同的是，类型筛选**不持久化**——它是查看行为而非偏好。
    @State private var kindFilter: FileKind? = nil

    /// v1.2 P1-5：批量选择状态。@State 而非 @StateObject——@Observable 时代的写法。
    /// 跨视图刷新（如 mtime/kind 切换）不会被重建，保留用户的勾选意图。
    @State private var batch = BatchSelection()

    public init(coordinator: ScanCoordinator,
                settings: AppSettings,
                selection: Binding<LargeFileItem?>,
                limit: Int = 200,
                onTrash: @escaping ([URL]) -> Void) {
        self.coordinator = coordinator
        self.settings = settings
        self._selection = selection
        self.limit = limit
        self.onTrash = onTrash
    }

    /// 视图层"实时计算"出的当前列表。
    /// 类型筛选在协调器返回的 LargeFileItem 列表上做最后一道过滤；
    /// 不下放到 ScanCoordinator 是因为类型筛选属于纯 UI 行为，
    /// 没必要让它污染数据层 API。
    private var items: [LargeFileItem] {
        let base = coordinator.largeFiles(
            minSizeMB: settings.minFileSizeMB,
            sortKey: sortKey,
            limit: limit,
            mtimeFilter: settings.mtimeFilter
        )
        guard let kindFilter else { return base }
        return base.filter { $0.kind == kindFilter }
    }

    /// 类型 chip 行需要展示的桶 + 该桶在"类型未筛选时"的命中数。
    /// 数量取自 mtime 已过滤的全集而不是 kind 筛选后的子集，
    /// 否则点了某个 kind 后其他 chip 数字会变成 0，体验差。
    private var kindCounts: [(FileKind, Int)] {
        let base = coordinator.largeFiles(
            minSizeMB: settings.minFileSizeMB,
            sortKey: .sizeDesc,
            limit: limit,
            mtimeFilter: settings.mtimeFilter
        )
        var counts: [FileKind: Int] = [:]
        for item in base { counts[item.kind, default: 0] += 1 }
        // 只展示**有命中**的桶，避免一排空 chip。
        return FileKind.allCases.compactMap { k in
            guard let n = counts[k], n > 0 else { return nil }
            return (k, n)
        }
    }

    /// 视图阈值（B）—— 与扫描期阈值对比，判断是否需要提示重扫。
    private var viewThresholdBytes: Int64 {
        Int64(max(0, settings.minFileSizeMB)) * 1024 * 1024
    }

    /// "扫描期采集了 X 条 ≥ 扫描阈值的文件，但视图阈值 < 扫描阈值"——这种情况下
    /// 视图能展示的就只是已采集子集，比 ground truth 偏小，需要重扫。
    private var needsRescanForLowerThreshold: Bool {
        coordinator.largeFileScanThresholdBytes > 0
            && viewThresholdBytes < coordinator.largeFileScanThresholdBytes
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            kindBar
            Divider()
            content
        }
        // v1.2 P2-4：Spacebar 触发 Quick Look 预览当前选中。
        // 注意 onKeyPress 必须挂在最外层 VStack，否则 LazyVStack 内部的 row 拿不到焦点。
        .focusable()
        // bug B：.focusable() 会让 macOS 画蓝色焦点环包整张大文件视图，关掉。
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if let item = selection {
                QuickLookController.shared.preview(urls: [item.url])
                return .handled
            }
            return .ignored
        }
        // compactAfterScanPreservingCache 只缓存 size-desc Top N；在 Large Files 支持
        // store-backed 异步排序/过滤前，不在视图层自动 compact，避免返回错误子集。
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // v1.2 P1-5：三态全选 checkbox。
            // 设计点：visible 列表受 mtime + kind 双重过滤，
            // 全选只动"看得见"的，不会偷偷把隐藏项扫进选区。
            Button {
                let paths = items.map { $0.path }
                switch batch.headerState(visible: paths) {
                case .all:
                    batch.deselectAll(visible: paths)
                case .none, .partial:
                    batch.selectAll(visible: paths)
                }
            } label: {
                Image(systemName: headerCheckboxImage)
                    .foregroundStyle(.tint)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty)
            .help(Text("largefiles.help.toggle_select_all", bundle: .module))

            Image(systemName: "doc.richtext")
                .foregroundStyle(.tint)
            Text(String(format: String(localized: "largefiles.threshold.badge %lld %lld", bundle: .module),
                        settings.minFileSizeMB, limit))
                .font(.callout)
            Spacer()
            if needsRescanForLowerThreshold {
                Label(String(localized: "largefiles.banner.threshold_lowered", bundle: .module), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // v1.2 P1-5：批量删除按钮。仅"可见且勾选"的项参与，避免误删隐藏选区。
            let visiblePaths = items.map { $0.path }
            let pickedCount = batch.selectedCount(in: visiblePaths)
            if pickedCount > 0 {
                Button(role: .destructive) {
                    let urls = batch.selectedItemsIntersecting(visible: visiblePaths)
                        .map { URL(fileURLWithPath: $0) }
                    onTrash(urls)
                    batch.clear()
                } label: {
                    Label(String(format: String(localized: "largefiles.action.trash %lld", bundle: .module), pickedCount), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text(String(format: String(localized: "largefiles.toolbar.count %lld", bundle: .module), items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // v1.2 P2-6：导出当前筛选后清单。disabled 在空表时；不导出"完整数据库"，
            // 而是导出用户眼下看到的视图——所见即所得。
            Menu {
                Button {
                    exportCurrent(format: .json)
                } label: { Label(String(localized: "largefiles.export.json", bundle: .module), systemImage: "curlybraces") }
                Button {
                    exportCurrent(format: .tsv)
                } label: { Label(String(localized: "largefiles.export.tsv", bundle: .module), systemImage: "tablecells") }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(items.isEmpty)
            .help(Text("largefiles.help.export", bundle: .module))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 三态 checkbox 图标。
    private var headerCheckboxImage: String {
        switch batch.headerState(visible: items.map { $0.path }) {
        case .all:     return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .none:    return "square"
        }
    }

    // MARK: - Filter bar (v1.2 P1-4 修改日期过滤)

    /// 三个 chip 二选一：全部 / ≤30 天 / ≤1 年。
    /// 设计点：
    /// - chip 而不是 Picker —— 大文件页面是"决策密集型"，chip 一眼能看完所有选项；
    /// - 选中态用 accentColor 实色，未选中态用 secondary capsule 描边；
    /// - mtime 缺失的项按"全部"通过（详见 [MtimeFilter.passes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)）。
    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("largefiles.filter.mtime", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(AppSettings.MtimeFilter.allCases, id: \.self) { filter in
                mtimeChip(for: filter)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func mtimeChip(for filter: AppSettings.MtimeFilter) -> some View {
        let isOn = (settings.mtimeFilter == filter)
        Button {
            settings.mtimeFilter = filter
        } label: {
            Text(filter.label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.85) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1)
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(Text(String(format: String(localized: "largefiles.help.filter_by_age %@", bundle: .module), filter.label)))
    }

    // MARK: - Kind bar (v1.2 P2-3 类型分桶染色)

    /// 类型 chip 行：左侧"全部"，右侧按命中数从大到小排列各桶 chip。
    /// 设计点：
    /// - 用各桶自带 `tint` 染色 chip 圆点，让用户一眼能"按颜色找类型"；
    /// - 圆点小色块 + 数字徽标的视觉密度低于实色 capsule，避免抢 mtime chip 的焦点；
    /// - chip 的"全部"独立处理，不复用 [FileKind](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FileKind.swift)，
    ///   避免给 FileKind 多塞一个语义含糊的 case。
    @ViewBuilder
    private var kindBar: some View {
        let counts = kindCounts
        if counts.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.grid.2x2")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("largefiles.filter.kind", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    allKindChip
                    ForEach(counts, id: \.0) { (kind, n) in
                        kindChip(kind: kind, count: n)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var allKindChip: some View {
        let isOn = (kindFilter == nil)
        return Button {
            kindFilter = nil
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text("largefiles.filter.kind.all", bundle: .module)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? Color.secondary.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(Text("largefiles.help.kind_all", bundle: .module))
    }

    private func kindChip(kind: FileKind, count: Int) -> some View {
        let isOn = (kindFilter == kind)
        return Button {
            kindFilter = isOn ? nil : kind
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(kind.tint)
                    .frame(width: 7, height: 7)
                Text(kind.label)
                    .font(.caption)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? kind.tint.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(isOn ? kind.tint : Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(Text(String(format: String(localized: "largefiles.help.filter_by_kind %@ %lld", bundle: .module), kind.label, count)))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(for: item)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            if coordinator.isScanning {
                Text("largefiles.empty.scanning", bundle: .module)
                    .foregroundStyle(.secondary)
            } else if coordinator.isFinished {
                Text(String(format: String(localized: "largefiles.empty.no_results %lld", bundle: .module), settings.minFileSizeMB))
                    .foregroundStyle(.secondary)
                Text("largefiles.empty.tip_lower_threshold", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("largefiles.empty.click_sidebar", bundle: .module)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Columns

    private var columnHeader: some View {
        HStack(spacing: 10) {
            // 图标占位（与行内对齐）
            Spacer().frame(width: 20)
            Text("largefiles.column.name_path", bundle: .module)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnButton(title: String(localized: "largefiles.column.size", bundle: .module), column: .size)
                .frame(width: 110, alignment: .trailing)
            columnButton(title: String(localized: "largefiles.column.mtime", bundle: .module), column: .mtime)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }

    private func columnButton(title: String, column: LargeFileSortKey.Column) -> some View {
        Button {
            // v1.5 P2 / Q1：列头点击 → 写 sortKeyBinding → 回译到 settings.mainListSortKey，
            // 同帧通知主列表 / 树视图重排。
            sortKeyBinding.wrappedValue = sortKey.toggled(to: column)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.bold())
                if sortKey.column == column {
                    Image(systemName: sortKey.isDescending ? "chevron.down" : "chevron.up")
                        .font(.caption2.bold())
                }
            }
            .foregroundStyle(sortKey.column == column ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(Text(String(format: String(localized: "largefiles.help.sort_toggle %@", bundle: .module), title)))
    }

    // MARK: - Row

    private static let mtimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = .current
        return f
    }()

    @ViewBuilder
    private func row(for item: LargeFileItem) -> some View {
        let isSelected = (selection?.path == item.path)
        let kind = item.kind
        let isPicked = batch.isSelected(item.path)
        HStack(spacing: 10) {
            // v1.2 P1-5：行级勾选 checkbox。点击只 toggle 不影响 row 选中（selection），
            // 这样用户能一边选中看详情，一边批量勾选要删的。
            Button {
                batch.toggle(item.path)
            } label: {
                Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .frame(width: 22)

            Image(systemName: kind.systemImageName)
                .foregroundStyle(kind.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            Text(item.modificationDate.map { Self.mtimeFormatter.string(from: $0) } ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = item }
        .help(item.path)
        .contextMenu {
            Button {
                batch.toggle(item.path)
            } label: {
                Label {
                    Text(isPicked ? LocalizedStringKey("largefiles.menu.unpick")
                                  : LocalizedStringKey("largefiles.menu.pick"),
                         bundle: .module)
                } icon: {
                    Image(systemName: isPicked ? "square" : "checkmark.square")
                }
            }
            Divider()
            Button {
                QuickLookController.shared.preview(urls: [item.url])
            } label: { Label(String(localized: "largefiles.context.quicklook", bundle: .module), systemImage: "eye") }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Label(String(localized: "largefiles.context.reveal_finder", bundle: .module), systemImage: "folder") }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(item.path, forType: .string)
            } label: { Label(String(localized: "largefiles.context.copy_path", bundle: .module), systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) {
                onTrash([item.url])
            } label: { Label(String(localized: "largefiles.context.move_to_trash", bundle: .module), systemImage: "trash") }
        }
    }

    // MARK: - 导出（v1.2 P2-6）

    private enum ExportFormat { case json, tsv }

    /// 弹 NSSavePanel 写到磁盘。
    /// 这里把"业务转换 → 序列化 → 写盘"分三步，方便日后接 sheet/loading。
    private func exportCurrent(format: ExportFormat) {
        let rows = items.map { Exporter.Row($0) }
        let data: Data
        let suggested: String
        switch format {
        case .json:
            data = Exporter.toJSON(rows)
            suggested = "GSYCleanMac-LargeFiles.json"
        case .tsv:
            data = Exporter.toTSV(rows).data(using: .utf8) ?? Data()
            suggested = "GSYCleanMac-LargeFiles.tsv"
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "largefiles.export.panel_title", bundle: .module)
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "largefiles.export.failed.title", bundle: .module)
                alert.informativeText = String(format: String(localized: "largefiles.export.failed.body", bundle: .module), error.localizedDescription)
                alert.runModal()
            }
        }
    }
}
