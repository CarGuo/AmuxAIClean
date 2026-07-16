import SwiftUI
import AppKit
import Combine
import AIKit

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
    /// v2026.07.15：SwiftUI 格式串、AppKit 面板和自绘表右键菜单共享同一个
    /// View locale；否则 AppKit 子树会继续显示进程启动语言。
    @Environment(\.locale) private var locale

    let coordinator: ScanCoordinator
    @Bindable var settings: AppSettings

    /// 行内当前选中（用于右侧详情，也作为 .delete 快捷键的锚）。
    @Binding var selection: LargeFileItem?

    /// 移到废纸篓回调；由 MainView 注入，复用主界面的 DeleteSheet 流程。
    let onTrash: ([LargeFileItem]) -> Void
    let onVisibleItemsChange: ([LargeFileItem]) -> Void
    let onStash: (LargeFileItem) -> Void
    let isStashed: (String) -> Bool
    let aiSettings: AISettings?
    let onAskAI: (LargeFileItem) -> Void

    /// Top N 截断。默认 200（ROADMAP）。可由调用方覆盖。
    let limit: Int

    /// v2026.07 Q1：批量选择状态由 MainView 持有并注入。
    ///
    /// **历史**：以前 `@State private var batch = BatchSelection()`——LargeFilesView 自己 own。
    /// 后果是 [MainView.footerBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1671-L1730)
    /// 的底部"移到废纸篓"按钮读不到这份 selection，被迫另立一份 `largeFileSelection`
    /// （单击行同步的单选项），造成"复选框勾了但底部按钮 disabled"的错觉，
    /// 以及 LargeFilesView 头部要额外画一个"移到废纸篓(N)"按钮兜底 → **两个批量入口共存**。
    ///
    /// **现在**：`BatchSelection` 是 `@Observable class`，由 MainView 以 `@State` 持有
    /// 单例引用；LargeFilesView 与 footerBar 共享同一实例。SwiftUI 通过 Observation 自动
    /// 追踪 `selected` 变更 → 双端都能实时响应。删除入口统一到 footerBar 唯一按钮。
    let batch: BatchSelection

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

    @State private var displayedItems: [LargeFileItem] = []
    @State private var displayedKindCounts: [(FileKind, Int)] = []

    public init(coordinator: ScanCoordinator,
                settings: AppSettings,
                selection: Binding<LargeFileItem?>,
                batch: BatchSelection,
                limit: Int = 200,
                onTrash: @escaping ([LargeFileItem]) -> Void,
                onVisibleItemsChange: @escaping ([LargeFileItem]) -> Void = { _ in },
                onStash: @escaping (LargeFileItem) -> Void,
                isStashed: @escaping (String) -> Bool,
                aiSettings: AISettings?,
                onAskAI: @escaping (LargeFileItem) -> Void) {
        self.coordinator = coordinator
        self.settings = settings
        self._selection = selection
        self.batch = batch
        self.limit = limit
        self.onTrash = onTrash
        self.onVisibleItemsChange = onVisibleItemsChange
        self.onStash = onStash
        self.isStashed = isStashed
        self.aiSettings = aiSettings
        self.onAskAI = onAskAI
    }

    /// 视图层"实时计算"出的当前列表。
    /// 类型筛选在协调器返回的 LargeFileItem 列表上做最后一道过滤；
    /// 不下放到 ScanCoordinator 是因为类型筛选属于纯 UI 行为，
    /// 没必要让它污染数据层 API。
    private var currentItems: [LargeFileItem] {
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
    private var currentKindCounts: [(FileKind, Int)] {
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

    private func syncDisplayedLargeFiles(force: Bool) {
        let latest = currentItems
        let latestCounts = currentKindCounts
        if force || !coordinator.isScanning || latest.isEmpty {
            publishDisplayedLargeFiles(items: latest, kindCounts: latestCounts)
            return
        }
        if displayedItems.isEmpty, !latest.isEmpty {
            publishDisplayedLargeFiles(items: latest, kindCounts: latestCounts)
        }
    }

    private func publishDisplayedLargeFiles(items: [LargeFileItem],
                                            kindCounts: [(FileKind, Int)]) {
        if displayedItems != items {
            displayedItems = items
        }
        onVisibleItemsChange(items)
        if !Self.kindCountsEqual(displayedKindCounts, kindCounts) {
            displayedKindCounts = kindCounts
        }
    }

    private static func kindCountsEqual(_ lhs: [(FileKind, Int)],
                                        _ rhs: [(FileKind, Int)]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.0 != right.0 || left.1 != right.1 {
            return false
        }
        return true
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            kindBar
            Divider()
            content
        }
        .onAppear {
            syncDisplayedLargeFiles(force: true)
        }
        .onReceive(coordinator.$snapshot) { _ in
            syncDisplayedLargeFiles(force: false)
        }
        .onReceive(coordinator.$isScanning.removeDuplicates()) { scanning in
            if !scanning {
                syncDisplayedLargeFiles(force: true)
            }
        }
        // v2026.07 Q2 修复：`pruneDeleted` 会剔掉 `largeFileLeaves`，但只 bump 了
        // non-@Published 的 `structuralRevision`——本视图订阅不到，导致"成功移到
        // 废纸篓但列表还在"的用户反馈。订阅 [storeRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
        // 后强同步一次，无需重扫。
        .onReceive(coordinator.$storeRevision) { _ in
            syncDisplayedLargeFiles(force: true)
        }
        .onChange(of: settings.minFileSizeMB) { _, _ in syncDisplayedLargeFiles(force: true) }
        .onChange(of: settings.mtimeFilter) { _, _ in syncDisplayedLargeFiles(force: true) }
        .onChange(of: settings.mainListSortKey) { _, _ in syncDisplayedLargeFiles(force: true) }
        .onChange(of: kindFilter) { _, _ in syncDisplayedLargeFiles(force: true) }
        // v1.2 P2-4：Spacebar 触发 Quick Look 预览当前选中。
        // 注意 onKeyPress 必须挂在最外层 VStack，否则 AppKit table 焦点路径会吞掉外层快捷键。
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
                let paths = displayedItems.map { $0.path }
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
            .disabled(displayedItems.isEmpty)
            .help(Text("largefiles.help.toggle_select_all", bundle: .module))

            Image(systemName: "doc.richtext")
                .foregroundStyle(.tint)
            Text(AppLocalization.format(
                "largefiles.threshold.badge %lld %lld",
                locale: locale,
                arguments: [Int64(settings.minFileSizeMB), Int64(limit)]
            ))
                .font(.callout)
            Spacer()
            if needsRescanForLowerThreshold {
                Label(
                    AppLocalization.string("largefiles.banner.threshold_lowered", locale: locale),
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // v2026.07 Q1：批量删除按钮已由 [MainView.footerBar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1671-L1730)
            // 唯一承载——本处不再画独立按钮，避免"多入口 + 状态不同步"的用户反馈。
            // 头部依然提供三态全选 checkbox（勾选/取消可见项）与阈值展示。

            Text(AppLocalization.format(
                "largefiles.toolbar.count %lld",
                locale: locale,
                arguments: [Int64(displayedItems.count)]
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // v1.2 P2-6：导出当前筛选后清单。disabled 在空表时；不导出"完整数据库"，
            // 而是导出用户眼下看到的视图——所见即所得。
            Menu {
                Button {
                    exportCurrent(format: .json)
                } label: {
                    Label(
                        AppLocalization.string("largefiles.export.json", locale: locale),
                        systemImage: "curlybraces"
                    )
                }
                Button {
                    exportCurrent(format: .tsv)
                } label: {
                    Label(
                        AppLocalization.string("largefiles.export.tsv", locale: locale),
                        systemImage: "tablecells"
                    )
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(displayedItems.isEmpty)
            .help(Text("largefiles.help.export", bundle: .module))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 三态 checkbox 图标。
    private var headerCheckboxImage: String {
        switch batch.headerState(visible: displayedItems.map { $0.path }) {
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
            Text(filter.label(in: locale))
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
        .help(Text(AppLocalization.format(
            "largefiles.help.filter_by_age %@",
            locale: locale,
            arguments: [filter.label(in: locale)]
        )))
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
        let counts = displayedKindCounts
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
                Text(kind.label(locale: locale))
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
        .help(Text(AppLocalization.format(
            "largefiles.help.filter_by_kind %@ %lld",
            locale: locale,
            arguments: [kind.label(locale: locale), Int64(count)]
        )))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if displayedItems.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                columnHeader
                Divider()
                AppKitLargeFilesTable(
                    items: displayedItems,
                    selectedItem: $selection,
                    selectedPaths: batch.selected,
                    aiReady: aiSettings?.isReadyForUI == true,
                    locale: locale,
                    isStashed: isStashed,
                    onTogglePick: { batch.toggle($0) },
                    onAskAI: { item in onAskAI(item) },
                    onStash: { item in
                        guard !isStashed(item.path) else { NSSound.beep(); return }
                        onStash(item)
                    },
                    onTrash: { item in onTrash([item]) }
                )
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
            } else if coordinator.isFinished && !coordinator.snapshot.isComplete {
                Text("main.scan.incomplete", bundle: .module)
                    .foregroundStyle(.orange)
            } else if coordinator.isFinished {
                Text(AppLocalization.format(
                    "largefiles.empty.no_results %lld",
                    locale: locale,
                    arguments: [Int64(settings.minFileSizeMB)]
                ))
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
            columnButton(
                title: AppLocalization.string("largefiles.column.size", locale: locale),
                column: .size
            )
                .frame(width: 110, alignment: .trailing)
            columnButton(
                title: AppLocalization.string("largefiles.column.mtime", locale: locale),
                column: .mtime
            )
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
        .help(Text(AppLocalization.format(
            "largefiles.help.sort_toggle %@",
            locale: locale,
            arguments: [title]
        )))
    }

    // MARK: - 导出（v1.2 P2-6）

    private enum ExportFormat { case json, tsv }

    /// 弹 NSSavePanel 写到磁盘。
    /// 这里把"业务转换 → 序列化 → 写盘"分三步，方便日后接 sheet/loading。
    private func exportCurrent(format: ExportFormat) {
        let rows = displayedItems.map { Exporter.Row($0) }
        let data: Data
        let suggested: String
        switch format {
        case .json:
            data = Exporter.toJSON(rows)
            suggested = "AmuxAIClean-LargeFiles.json"
        case .tsv:
            data = Exporter.toTSV(rows).data(using: .utf8) ?? Data()
            suggested = "AmuxAIClean-LargeFiles.tsv"
        }

        let panel = NSSavePanel()
        panel.title = AppLocalization.string("largefiles.export.panel_title", locale: locale)
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = AppLocalization.string(
                    "largefiles.export.failed.title",
                    locale: locale
                )
                alert.informativeText = AppLocalization.format(
                    "largefiles.export.failed.body",
                    locale: locale,
                    arguments: [error.localizedDescription]
                )
                alert.runModal()
            }
        }
    }
}

private struct AppKitLargeFilesTable: NSViewRepresentable {
    let items: [LargeFileItem]
    @Binding var selectedItem: LargeFileItem?
    let selectedPaths: Set<String>
    let aiReady: Bool
    let locale: Locale
    let isStashed: (String) -> Bool
    let onTogglePick: (String) -> Void
    let onAskAI: (LargeFileItem) -> Void
    let onStash: (LargeFileItem) -> Void
    let onTrash: (LargeFileItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LargeFilesNSTableView()
        table.headerView = nil
        table.rowHeight = LargeFilesTableMetrics.rowHeight
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

        let column = NSTableColumn(identifier: LargeFilesTableMetrics.columnIdentifier)
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
        var parent: AppKitLargeFilesTable
        private var isSyncingSelection = false

        init(parent: AppKitLargeFilesTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row rowIndex: Int) -> NSView? {
            guard rowIndex >= 0, rowIndex < parent.items.count else { return nil }
            let identifier = LargeFilesTableMetrics.cellIdentifier
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? LargeFilesTableCellView)
                ?? LargeFilesTableCellView(identifier: identifier)
            let item = parent.items[rowIndex]
            cell.configure(
                item: item,
                isSelected: parent.selectedItem?.path == item.path,
                isPicked: parent.selectedPaths.contains(item.path),
                isStashed: parent.isStashed(item.path),
                aiReady: parent.aiReady,
                locale: parent.locale,
                actions: LargeFilesRowActions(
                    select: { [weak self] in self?.select(item, in: tableView) },
                    togglePick: { [weak self] in self?.parent.onTogglePick(item.path) },
                    askAI: { [weak self] in self?.parent.onAskAI(item) },
                    stash: { [weak self] in self?.parent.onStash(item) },
                    trash: { [weak self] in self?.parent.onTrash(item) }
                )
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let table = notification.object as? NSTableView else { return }
            let rowIndex = table.selectedRow
            guard rowIndex >= 0, rowIndex < parent.items.count else {
                parent.selectedItem = nil
                return
            }
            parent.selectedItem = parent.items[rowIndex]
        }

        func syncSelection(in table: NSTableView) {
            let target: Int
            if let selectedPath = parent.selectedItem?.path,
               let idx = parent.items.firstIndex(where: { $0.path == selectedPath }) {
                target = idx
            } else {
                target = -1
            }
            guard table.selectedRow != target else { return }
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            if target >= 0 {
                table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }

        private func select(_ item: LargeFileItem, in table: NSTableView) {
            parent.selectedItem = item
            if let idx = parent.items.firstIndex(where: { $0.path == item.path }) {
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 126: moveSelection(by: -1); return true
            case 125: moveSelection(by: 1); return true
            case 49:
                guard let selected = parent.selectedItem else { return false }
                QuickLookController.shared.preview(urls: [selected.url])
                return true
            case 51:
                guard let selected = parent.selectedItem else { return false }
                parent.onTrash(selected)
                return true
            default:
                return false
            }
        }

        private func moveSelection(by delta: Int) {
            guard !parent.items.isEmpty else { return }
            let current: Int
            if let selectedPath = parent.selectedItem?.path,
               let idx = parent.items.firstIndex(where: { $0.path == selectedPath }) {
                current = idx
            } else {
                current = -1
            }
            let next = max(0, min(parent.items.count - 1, current + delta))
            parent.selectedItem = parent.items[next]
        }
    }
}

private final class LargeFilesNSTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

private enum LargeFilesTableMetrics {
    static let rowHeight: CGFloat = 42
    static let leftPadding: CGFloat = 16
    static let checkboxWidth: CGFloat = 22
    static let iconWidth: CGFloat = 20
    static let horizontalGap: CGFloat = 10
    static let sizeWidth: CGFloat = 110
    static let mtimeWidth: CGFloat = 130
    static let actionGap: CGFloat = 12
    static let actionWidth: CGFloat = 28
    static let actionAreaWidth: CGFloat = 84
    static let actionTrailingPadding: CGFloat = 18
    static let columnIdentifier = NSUserInterfaceItemIdentifier("LargeFilesTableColumn")
    static let cellIdentifier = NSUserInterfaceItemIdentifier("LargeFilesTableCell")
}

private struct LargeFilesRowActions {
    let select: () -> Void
    let togglePick: () -> Void
    let askAI: () -> Void
    let stash: () -> Void
    let trash: () -> Void
}

private final class LargeFilesTableCellView: NSTableCellView {
    private let canvas = LargeFilesRowCanvas()

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

    func configure(item: LargeFileItem,
                   isSelected: Bool,
                   isPicked: Bool,
                   isStashed: Bool,
                   aiReady: Bool,
                   locale: Locale,
                   actions: LargeFilesRowActions) {
        canvas.configure(item: item,
                         isSelected: isSelected,
                         isPicked: isPicked,
                         isStashed: isStashed,
                         aiReady: aiReady,
                         locale: locale,
                         actions: actions)
    }
}

private final class LargeFilesRowCanvas: NSView {
    private var item: LargeFileItem?
    private var isSelected = false
    private var isPicked = false
    private var isStashed = false
    private var aiReady = false
    // v2026.07.15：configure 会在首帧绘制前覆盖为 App 当前语言；默认仅用于尚未配置、
    // 因而没有可见内容的 NSView 生命周期窗口，且不冻结一次性的进程 locale。
    private var locale = Locale.autoupdatingCurrent
    private var actions: LargeFilesRowActions?

    override var isFlipped: Bool { true }

    func configure(item: LargeFileItem,
                   isSelected: Bool,
                   isPicked: Bool,
                   isStashed: Bool,
                   aiReady: Bool,
                   locale: Locale,
                   actions: LargeFilesRowActions) {
        self.item = item
        self.isSelected = isSelected
        self.isPicked = isPicked
        self.isStashed = isStashed
        self.aiReady = aiReady
        self.locale = locale
        self.actions = actions
        toolTip = item.path
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let item else { return }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        drawRow(item)
    }

    override func mouseDown(with event: NSEvent) {
        guard let item, let actions else { return }
        let point = convert(event.locationInWindow, from: nil)
        if checkboxRect.contains(point) {
            actions.togglePick()
            return
        }
        actions.select()
        switch hitTestAction(point) {
        case .ai:
            actions.askAI()
        case .stash:
            guard !isStashed else { NSSound.beep(); return }
            actions.stash()
        case .trash:
            actions.trash()
        case .none:
            if event.clickCount >= 2 {
                QuickLookController.shared.preview(urls: [item.url])
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let actions else { return nil }
        actions.select()
        let menu = NSMenu()
        let pick = LargeFilesClosureMenuItem(
            title: AppLocalization.string(
                isPicked ? "largefiles.menu.unpick" : "largefiles.menu.pick",
                locale: locale
            ),
            action: actions.togglePick
        )
        pick.image = NSImage(systemSymbolName: isPicked ? "square" : "checkmark.square",
                             accessibilityDescription: nil)
        menu.addItem(pick)
        menu.addItem(.separator())
        let ask = LargeFilesClosureMenuItem(
            title: AppLocalization.string("tree.menu.ask_ai", locale: locale),
            action: actions.askAI
        )
        ask.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(ask)
        let stash = LargeFilesClosureMenuItem(
            title: AppLocalization.string(
                isStashed ? "tree.menu.stash_already" : "tree.menu.stash",
                locale: locale
            ),
            action: { if !self.isStashed { actions.stash() } }
        )
        stash.image = NSImage(systemSymbolName: isStashed ? "tray.full.fill" : "tray.and.arrow.down",
                              accessibilityDescription: nil)
        stash.isEnabled = !isStashed
        menu.addItem(stash)
        menu.addItem(.separator())
        let quickLook = LargeFilesClosureMenuItem(
            title: AppLocalization.string("largefiles.context.quicklook", locale: locale),
            action: { QuickLookController.shared.preview(urls: [item.url]) }
        )
        quickLook.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        menu.addItem(quickLook)
        let reveal = LargeFilesClosureMenuItem(
            title: AppLocalization.string("largefiles.context.reveal_finder", locale: locale),
            action: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        )
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(reveal)
        let copyPath = LargeFilesClosureMenuItem(
            title: AppLocalization.string("largefiles.context.copy_path", locale: locale),
            action: { Self.copy(item.path) }
        )
        copyPath.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyPath)
        menu.addItem(.separator())
        let trash = LargeFilesClosureMenuItem(
            title: AppLocalization.string("largefiles.context.move_to_trash", locale: locale),
            action: actions.trash
        )
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(trash)
        return menu
    }

    private func drawRow(_ item: LargeFileItem) {
        let kind = item.kind
        drawCheckbox(in: checkboxRect, checked: isPicked)
        let iconRect = CGRect(x: checkboxRect.maxX + LargeFilesTableMetrics.horizontalGap,
                              y: 11,
                              width: LargeFilesTableMetrics.iconWidth,
                              height: 18)
        drawSymbol(kind.systemImageName,
                   in: iconRect,
                   color: kind.tableColor,
                   pointSize: 15,
                   weight: .regular)
        let nameX = iconRect.maxX + LargeFilesTableMetrics.horizontalGap
        let actionStart = bounds.width
            - LargeFilesTableMetrics.actionTrailingPadding
            - LargeFilesTableMetrics.actionAreaWidth
        let mtimeX = actionStart - LargeFilesTableMetrics.actionGap - LargeFilesTableMetrics.mtimeWidth
        let sizeX = mtimeX - LargeFilesTableMetrics.sizeWidth
        let nameWidth = max(30, sizeX - nameX - 8)
        drawText(item.title,
                 in: CGRect(x: nameX, y: 6, width: nameWidth, height: 17),
                 font: .systemFont(ofSize: NSFont.systemFontSize),
                 color: .labelColor,
                 lineBreak: .byTruncatingMiddle)
        drawText((item.path as NSString).deletingLastPathComponent,
                 in: CGRect(x: nameX, y: 23, width: nameWidth, height: 14),
                 font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                 color: .secondaryLabelColor,
                 lineBreak: .byTruncatingMiddle)
        drawText(item.bytes.formatted(.byteCount(style: .file).locale(locale)),
                 in: CGRect(x: sizeX, y: 12, width: LargeFilesTableMetrics.sizeWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                 color: .labelColor,
                 alignment: .right)
        drawText(item.modificationDate.map {
            $0.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(locale))
        } ?? "—",
                 in: CGRect(x: mtimeX, y: 13, width: LargeFilesTableMetrics.mtimeWidth - 8, height: 16),
                 font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                 color: .secondaryLabelColor,
                 alignment: .right)
        drawActions()
    }

    private var checkboxRect: CGRect {
        CGRect(x: LargeFilesTableMetrics.leftPadding, y: 0,
               width: LargeFilesTableMetrics.checkboxWidth,
               height: LargeFilesTableMetrics.rowHeight)
    }

    private func drawCheckbox(in rect: CGRect, checked: Bool) {
        let side: CGFloat = 16
        let box = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.8
        if checked {
            NSColor.controlAccentColor.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.stroke()

            let mark = NSBezierPath()
            mark.lineWidth = 2.2
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.move(to: CGPoint(x: box.minX + 3.8, y: box.minY + 8.6))
            mark.line(to: CGPoint(x: box.minX + 6.9, y: box.minY + 11.4))
            mark.line(to: CGPoint(x: box.minX + 12.4, y: box.minY + 4.9))
            NSColor.white.setStroke()
            mark.stroke()
        } else {
            NSColor.clear.setFill()
            path.fill()
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        }
    }

    private enum ActionHit {
        case none
        case ai
        case stash
        case trash
    }

    private func hitTestAction(_ point: CGPoint) -> ActionHit {
        if actionRect(.ai).contains(point) { return .ai }
        if actionRect(.stash).contains(point) { return .stash }
        if actionRect(.trash).contains(point) { return .trash }
        return .none
    }

    private func drawActions() {
        drawSymbol("sparkles",
                   in: symbolRect(in: actionRect(.ai), side: 16),
                   color: aiReady ? .controlAccentColor : .secondaryLabelColor.withAlphaComponent(0.45),
                   pointSize: 12,
                   weight: .semibold)
        drawSymbol(isStashed ? "tray.full.fill" : "tray.and.arrow.down",
                   in: symbolRect(in: actionRect(.stash), side: 16),
                   color: isStashed ? .controlAccentColor : .secondaryLabelColor,
                   pointSize: 12,
                   weight: .semibold)
        drawSymbol("trash",
                   in: symbolRect(in: actionRect(.trash), side: 16),
                   color: .systemRed,
                   pointSize: 12,
                   weight: .semibold)
    }

    private func actionRect(_ action: ActionHit) -> CGRect {
        let right = bounds.width - LargeFilesTableMetrics.actionTrailingPadding
        let trash = CGRect(x: right - LargeFilesTableMetrics.actionWidth, y: 3,
                           width: LargeFilesTableMetrics.actionWidth, height: 36)
        let stash = trash.offsetBy(dx: -LargeFilesTableMetrics.actionWidth, dy: 0)
        let ai = stash.offsetBy(dx: -LargeFilesTableMetrics.actionWidth, dy: 0)
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
                            pointSize: CGFloat,
                            weight: NSFont.Weight) {
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        image = image.withSymbolConfiguration(config) ?? image
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

private final class LargeFilesClosureMenuItem: NSMenuItem {
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

private extension FileKind {
    var tableColor: NSColor {
        switch self {
        case .video: return NSColor(red: 0.86, green: 0.31, blue: 0.34, alpha: 1)
        case .image: return NSColor(red: 0.20, green: 0.65, blue: 0.78, alpha: 1)
        case .audio: return NSColor(red: 0.55, green: 0.40, blue: 0.85, alpha: 1)
        case .archive: return NSColor(red: 0.92, green: 0.58, blue: 0.20, alpha: 1)
        case .disk: return NSColor(red: 0.40, green: 0.30, blue: 0.70, alpha: 1)
        case .installer: return NSColor(red: 0.30, green: 0.70, blue: 0.40, alpha: 1)
        case .design: return NSColor(red: 0.88, green: 0.42, blue: 0.66, alpha: 1)
        case .document: return NSColor(red: 0.45, green: 0.55, blue: 0.65, alpha: 1)
        case .code: return NSColor(red: 0.20, green: 0.55, blue: 0.65, alpha: 1)
        case .other: return .secondaryLabelColor
        }
    }
}
