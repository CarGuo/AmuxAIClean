import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanKit
import SafetyKit
import XPCBridge

/// 三栏主界面 —— 侧边类目 / 中间结果 / 右侧详情 + 删除按钮。
/// 见 PITFALLS §5.5/§5.6/§5.7：默认勾选只勾 .safe；先聚合不展平；删除走 preview sheet。
public struct MainView: View {
    @StateObject private var coordinator: ScanCoordinator
    @State private var presetCategories: [ScanCategory] = ScanCategories.recommended()
    @State private var customCategories: [ScanCategory] = []
    @State private var selectedCategory: ScanCategory.ID?
    @State private var selection: Set<String> = []   // 勾选的 row.id
    @State private var detail: RowItem?
    @State private var showSheet: Bool = false
    @State private var deleteResult: String?
    @State private var isDropTargeted: Bool = false
    /// v1.0 T3：结果区视图模式（清单 vs 多层树）。
    @State private var viewMode: ResultsViewMode = .list
    /// v1.0 T4：大文件视图选中项。与 detail（RowItem）解耦，
    /// 因为大文件是叶子，没有聚合 RowItem 模型。
    @State private var largeFileSelection: LargeFileItem?
    /// v1.0 T4：大文件入口类目。固定一项，放在侧边"大文件"独立 section。
    private let largeFilesCategory: ScanCategory = .largeFiles()
    /// v1.0 T5：路径栏临时输入（"/" + Enter 扫整盘；任意已存在目录路径也可直扫）。
    @State private var pathBarInput: String = ""

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
                pathStore: UserPathStore? = nil) {
        // v0 默认走 NSWorkspace.recycle（PITFALLS §5.9）：不需要 root，不需要 99 美元 Apple Developer Program
        // 用户撤销可以走 Finder → 显示废纸篓 → 放回原位
        self.pipeline = pipeline ?? TrashPipeline()
        self.recorder = recorder
        self.settings = settings ?? AppSettings()
        self.pathStore = pathStore ?? UserPathStore()
        _coordinator = StateObject(wrappedValue: ScanCoordinator(vendors: vendors))
    }

    /// 全部类目（preset + custom + largeFiles + fullDisk）—— 用于 toolbar / scan 查找。
    private var allCategories: [ScanCategory] {
        presetCategories + customCategories + [largeFilesCategory, ScanCategory.fullDisk]
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            results
        } detail: {
            detailPane
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
            guard let id = new, let cat = allCategories.first(where: { $0.id == id }) else { return }
            selection.removeAll()
            largeFileSelection = nil
            startScan(category: cat)
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .task {
            await refreshCustomPaths()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
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
    private func sidebarRow(_ cat: ScanCategory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: cat.kind))
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
                    switch viewMode {
                    case .list:
                        listResults
                    case .tree:
                        if let root = coordinator.currentRootPath {
                            TreeBrowserView(coordinator: coordinator, rootPath: root)
                        } else {
                            Text("暂无可展开的扫描根")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                Divider()
                footerBar
            }
        }
        .navigationSplitViewColumnWidth(min: 420, ideal: 520)
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
                Text("树视图只用于浏览；勾选清理仍请切回清单")
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
                    .tag(row)
            }
        }
        .listStyle(.inset)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            if !coordinator.permissionDeniedPaths.isEmpty || !coordinator.tccProtectedSkippedPaths.isEmpty {
                PermissionStatusBanner(
                    fdaDeniedPaths: coordinator.permissionDeniedPaths,
                    tccSkippedPaths: coordinator.tccProtectedSkippedPaths,
                    onOpenSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            HStack {
                if coordinator.isScanning {
                    ProgressView().controlSize(.small)
                    Text("扫描中… \(coordinator.snapshot.scannedFileCount) 个文件 · \(formattedBytes(coordinator.snapshot.totalBytes))")
                        .font(.callout)
                } else if coordinator.snapshot.isFinished {
                    Text("完成 · \(coordinator.snapshot.scannedFileCount) 文件 · \(formattedBytes(coordinator.snapshot.totalBytes)) · \(String(format: "%.2fs", coordinator.snapshot.elapsed))")
                        .font(.callout)
                } else {
                    Text("选择左侧类目开始扫描")
                        .foregroundStyle(.secondary)
                        .font(.callout)
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

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let item = detail {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VerdictBadge(verdict: item.verdict)
                        .frame(width: 14, height: 14)
                    Text(item.title)
                        .font(.title2.bold())
                }
                Text(item.url.path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("选中一行查看详情")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            pathBar
        }
        ToolbarItem(placement: .primaryAction) {
            fullDiskButton
        }
        ToolbarItem(placement: .primaryAction) {
            scanControlButton
        }
    }

    /// v1.0 T5：路径栏 —— 输 `/` 回车扫整盘；输任意已存在目录回车直接扫。
    private var pathBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("输入路径或 / 回车扫整盘", text: $pathBarInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 320)
                .onSubmit { submitPathBar() }
                .help("输 / 回车扫整盘；输已存在目录回车开始扫该目录")
        }
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
                selection.removeAll()
                largeFileSelection = nil
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
        selection.removeAll()
        if selectedCategory == ScanCategory.fullDisk.id {
            // 已经选中整盘 → onChange 不会再触发，主动重扫
            coordinator.scanFullDisk(includeHidden: settings.showHidden)
        } else {
            selectedCategory = ScanCategory.fullDisk.id
        }
    }

    // MARK: - Helpers

    private var selectedRows: [RowItem] {
        coordinator.snapshot.rows.filter { selection.contains($0.id) && $0.isSelectable }
    }

    private var selectionSummary: String {
        let rows = selectedRows
        if rows.isEmpty { return "未选中任何项" }
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        return "已选 \(rows.count) 项 · \(formattedBytes(total))"
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
            }
        }
    }

    // MARK: - v1.0 T4 大文件辅助

    /// 统一扫描入口：根据类目 kind 决定是否传 largeFileMinBytes。
    /// 这一层抽象避免在 onChange / toolbar / settings.onChange 三处重复"判 kind 决定参数"。
    private func startScan(category: ScanCategory) {
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
    let onOpenSettings: () -> Void
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
                if fdaCount > 0 {
                    Button("打开完全磁盘访问权限") { onOpenSettings() }
                        .controlSize(.small)
                }
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
