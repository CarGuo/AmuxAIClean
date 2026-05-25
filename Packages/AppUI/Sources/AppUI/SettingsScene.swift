import SwiftUI
import AppKit
import LogKit
import ScanKit

/// v1.0 设置窗口（⌘, 自动可用）。
///
/// 三个分区：
/// 1. 扫描行为：显示隐藏文件 toggle（默认 ON，v1.3 修订）
/// 2. 大文件模块：阈值 Stepper（默认 100MB）
/// 3. 自定义扫描路径：列出 UserPathStore 已存路径，可移除
///
/// 决策来源：[docs/ROADMAP_V1.md](../../../../docs/ROADMAP_V1.md) §1 T2。
public struct SettingsScene: View {
    @Bindable private var settings: AppSettings
    private let pathStore: UserPathStore
    @Bindable private var updateChecker: UpdateChecker

    /// 路径列表的 UI 镜像。actor 数据要在 SwiftUI 里显示必须先快照。
    @State private var pathsMirror: [URL] = []

    /// v1.3.zzzz Phase 6：「存储与日志」Tab 的 DB 体积/计数快照。
    @State private var storageDescription: ScanStoreDescription?
    @State private var storageBusy: Bool = false
    @State private var storageMessage: String?
    @State private var pendingStorageAction: StorageAction?

    /// 三级清理动作 + 对应二次确认文案。
    fileprivate enum StorageAction: Identifiable {
        case vacuum
        case clearAll
        case deleteFiles
        var id: String {
            switch self {
            case .vacuum: return "vacuum"
            case .clearAll: return "clearAll"
            case .deleteFiles: return "deleteFiles"
            }
        }
        var title: String {
            switch self {
            case .vacuum: return "压缩数据库"
            case .clearAll: return "清空扫描结果"
            case .deleteFiles: return "删除数据库文件"
            }
        }
        var message: String {
            switch self {
            case .vacuum:
                return "对 SQLite 执行 VACUUM，仅紧凑空间不删除任何业务数据。下次扫描后体积可能再次回升。"
            case .clearAll:
                return "清空 scan_session / scan_result 全表后再 VACUUM。所有历史扫描记录将不可恢复。"
            case .deleteFiles:
                return "直接从磁盘删除 .sqlite + -wal + -shm 三个文件（破坏性最强）。下次启动会重新建库。"
            }
        }
    }

    public init(settings: AppSettings, pathStore: UserPathStore, updateChecker: UpdateChecker) {
        self.settings = settings
        self.pathStore = pathStore
        self.updateChecker = updateChecker
    }

    public var body: some View {
        TabView {
            scanTab
                .tabItem {
                    Label {
                        Text("settings.tab.scan", bundle: .module)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            largeFilesTab
                .tabItem {
                    Label {
                        Text("settings.tab.large_files", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.richtext")
                    }
                }
            pathsTab
                .tabItem {
                    Label {
                        Text("settings.tab.custom_paths", bundle: .module)
                    } icon: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            updateTab
                .tabItem {
                    Label {
                        Text("settings.tab.update", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
            developerArtifactsTab
                .tabItem {
                    Label {
                        Text("settings.tab.dev_scan", bundle: .module)
                    } icon: {
                        Image(systemName: "hammer")
                    }
                }
            storageTab
                .tabItem {
                    Label {
                        Text("settings.tab.storage", bundle: .module)
                    } icon: {
                        Image(systemName: "internaldrive")
                    }
                }
        }
        .frame(width: 520, height: 420)
        .task {
            await refreshPaths()
            await refreshStorage()
        }
    }

    // MARK: - Tabs

    private var scanTab: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showHidden) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示隐藏文件 / 文件夹")
                        Text("默认 ON：扫描会包含 .cursor / .npm / .cache 等以 . 开头的目录，体积才能与 Finder/du 对齐。关掉后只看可见文件，结果会显著小于 Finder。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("扫描行为")
            }
            Section {
                Picker(selection: $settings.sizeAccountingMode) {
                    ForEach(AppSettings.SizeAccountingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("字节口径")
                        Text("logical（默认）：与系统设置 / Finder / 「显示简介」完全一致；APFS clone / hardlink 不去重，每个文件按完整 size 算。\nphysical：与 du / df 一致；按实际占用磁盘 block 算，sparse / hardlink 文件更小，反映「删了真能释放多少」。\n切换后需要重新扫描才能让总数按新口径累计。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("体积统计口径")
            }
            Section {
                Toggle(isOn: $settings.hudEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("扫描悬浮窗（HUD）")
                        Text("默认 ON。扫描时在屏幕顶部刘海下方居中显示一个胶囊：可清理 / 可用 / 比例条 / 预计剩余时间。可随时通过 ⌘⇧H 或工具栏按钮切换。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $settings.hudPersistent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HUD 常驻挂件模式")
                        Text("打开后即使未在扫描，HUD 也持续显示，作为桌面 / 顶部小挂件。闲置态显示磁盘已用比例 + 一键开始扫描。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.hudEnabled)
                Picker(selection: $settings.hudPlacement) {
                    ForEach(AppSettings.HUDPlacement.allCases, id: \.self) { placement in
                        Text(placement.label).tag(placement)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HUD 位置")
                        Text("顶部居中（刘海下方）= floating 级，永远在所有 App 窗口之上；桌面三档 = 桌面图标之上、App 窗口之下，模拟桌面小控件，不抢前台焦点。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!settings.hudEnabled)
                Toggle(isOn: $settings.trayEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("菜单栏托盘图标")
                        Text("默认 ON。在系统菜单栏右侧显示一个图标，点击可快速打开主窗口、开始推荐扫描、显示/隐藏悬浮窗。关掉后图标立即移除。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $settings.hideFromDockWhenClosed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关闭主窗口后从 Dock 隐藏")
                        Text("默认 OFF。开启后，关掉主窗口 = App 隐入菜单栏托盘（Dock 图标 + 顶部主菜单一起消失）；点托盘 \"打开主窗口\" 即可拉回。需要保留菜单栏托盘开启，否则 App 关窗后将完全没有入口。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.trayEnabled)
            } header: {
                Text("界面")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var largeFilesTab: some View {
        Form {
            Section {
                HStack {
                    Text("最小阈值")
                    Spacer()
                    Stepper("\(settings.minFileSizeMB) MB",
                            value: $settings.minFileSizeMB,
                            in: 10...10240,
                            step: 10)
                        .labelsHidden()
                    Text("\(settings.minFileSizeMB) MB")
                        .monospacedDigit()
                        .frame(minWidth: 70, alignment: .trailing)
                }
                Text("仅显示文件大小 ≥ 该阈值的项。建议 100MB ~ 500MB。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("大文件模块")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var pathsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("自定义扫描路径")
                    .font(.headline)
                Spacer()
                Button {
                    addPathViaPanel()
                } label: {
                    Label("添加路径…", systemImage: "plus")
                }
            }
            .padding(.horizontal)
            .padding(.top)

            if pathsMirror.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("还没有自定义路径")
                        .foregroundStyle(.secondary)
                    Text("点击右上 + 添加任意目录，或把文件夹拖进主窗口")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(pathsMirror, id: \.self) { url in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await removePath(url) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.bottom)
    }

    private var updateTab: some View {
        Form {
            Section {
                Toggle(isOn: $settings.updateCheckEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时检查更新")
                        Text("打开后 App 启动会向 GitHub Releases 发一次 GET 请求（约 2 KB，不携带任何身份信息）。关掉后仅『立即检查』按钮可联网。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("自动更新")
            }
            Section {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text(UpdateChecker.currentVersion)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        updateChecker.checkNow()
                    } label: {
                        if updateChecker.isChecking {
                            ProgressView().controlSize(.small)
                            Text("检查中…")
                        } else {
                            Text("立即检查")
                        }
                    }
                    .disabled(updateChecker.isChecking)
                    Spacer()
                    statusLabel
                }
                if let skipped = settings.skippedUpdateTag {
                    HStack {
                        Text("已跳过版本：\(skipped)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清除跳过记录") {
                            settings.skippedUpdateTag = nil
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("版本")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch updateChecker.lastResult {
        case .upToDate:
            Label("已是最新", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .newer(let r):
            Label("新版本：\(r.tagName)", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint).font(.caption)
        case .skippedByUser(let r):
            Label("已跳过 \(r.tagName)", systemImage: "minus.circle")
                .foregroundStyle(.secondary).font(.caption)
        case .failed(let msg):
            Label("检查失败：\(msg)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption).lineLimit(1)
        case .none:
            EmptyView()
        }
    }

    // MARK: - 行为

    private func addPathViaPanel() {
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
                await refreshPaths()
            }
        }
    }

    private func removePath(_ url: URL) async {
        _ = await pathStore.remove(url)
        await refreshPaths()
    }

    private func refreshPaths() async {
        let list = await pathStore.list()
        await MainActor.run {
            pathsMirror = list
        }
    }
}

// MARK: - 开发者扫描 Tab（v1.4）

extension SettingsScene {
    /// 「开发者扫描」Tab：列出 30 条开发者构建产物规则，按生态分组逐项 Toggle。
    ///
    /// 设计要点：
    /// 1. **Source of truth = settings.enabledDevArtifactRuleIDs**：每个 Toggle 绑定到
    ///    `Set<String>.contains(rule.id)`，flip 后立刻写入 UserDefaults。下次扫描自动生效。
    /// 2. **按 [DevArtifactRules.grouped](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/DevArtifactRules.swift) 渲染**：
    ///    `Ecosystem.allCases` 顺序，每个生态一个 `Section`，Section header 用 `displayName`。
    /// 3. **副标题展示规则元信息**：`directoryName` + `subtitle` + 兄弟兜底标记 + `Verdict`，
    ///    用户能看清「关掉这条规则会少扫什么」。
    /// 4. **顶部全选 / 全关 / 仅安全**三个快捷操作：高频运维场景下批量切换比逐条点效率高。
    fileprivate var developerArtifactsTab: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Button {
                        settings.enabledDevArtifactRuleIDs = DevArtifactRules.allIDs
                    } label: {
                        Text("settings.dev.enable_all", bundle: .module)
                    }
                    Button {
                        settings.enabledDevArtifactRuleIDs = []
                    } label: {
                        Text("settings.dev.disable_all", bundle: .module)
                    }
                    Button {
                        settings.enabledDevArtifactRuleIDs = Set(
                            DevArtifactRules.all
                                .filter { $0.verdict == .safe }
                                .map(\.id)
                        )
                    } label: {
                        Text("settings.dev.safe_only", bundle: .module)
                    }
                    Spacer()
                    Text(String(
                        format: String(localized: "settings.dev.enabled_count.format", bundle: .module),
                        settings.enabledDevArtifactRuleIDs.count,
                        DevArtifactRules.all.count
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.dev.batch_actions", bundle: .module)
            } footer: {
                Text("开发者扫描会从 ~ 整个家目录 BFS 查找命中目录（如 node_modules / build / Pods / target / __pycache__ 等），并要求兄弟里有对应脚手架文件（如 package.json / pubspec.yaml / Cargo.toml）以避免误命中。命中后整棵剪枝不再下钻。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(DevArtifactRules.grouped(), id: \.0) { (ecosystem, rules) in
                if !rules.isEmpty {
                    Section {
                        ForEach(rules) { rule in
                            Toggle(isOn: bindingForRule(rule.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(rule.displayName)
                                        Text(rule.directoryName)
                                            .font(.caption.monospaced())
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.12),
                                                        in: RoundedRectangle(cornerRadius: 4))
                                        if rule.verdict == .confirm {
                                            Text("需确认")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(rule.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !rule.siblingMarkers.isEmpty {
                                        Text("兄弟兜底：\(rule.siblingMarkers.joined(separator: " / "))")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(String(localized: String.LocalizationValue(ecosystem.localizationKey), bundle: .module))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 把 `Set<String>.contains(id)` 桥成 SwiftUI `Toggle` 用的 `Binding<Bool>`。
    /// 写入 true → 插入 id；写入 false → 移除 id；didSet 自然触发 UserDefaults 持久化。
    private func bindingForRule(_ ruleID: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledDevArtifactRuleIDs.contains(ruleID) },
            set: { isOn in
                if isOn {
                    settings.enabledDevArtifactRuleIDs.insert(ruleID)
                } else {
                    settings.enabledDevArtifactRuleIDs.remove(ruleID)
                }
            }
        )
    }
}

// MARK: - 存储与日志 Tab（v1.3.zzzz Phase 6）

extension SettingsScene {
    /// 「存储与日志」Tab：DB 体积展示 + 三级清理 + 日志目录入口。
    fileprivate var storageTab: some View {
        Form {
            Section {
                if let desc = storageDescription {
                    LabeledContent("数据库路径") {
                        Text(desc.databaseURL.path)
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    LabeledContent("总体积") {
                        Text(Self.formatBytes(desc.totalSizeBytes))
                            .monospacedDigit()
                    }
                    LabeledContent("会话 / 结果") {
                        Text("\(desc.sessionCount) 会话 · \(desc.resultRowCount) 行")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取数据库信息…")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        Task { await refreshStorage() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(storageBusy)
                    Spacer()
                    Button {
                        revealDatabaseInFinder()
                    } label: {
                        Label("在 Finder 显示", systemImage: "folder")
                    }
                }
            } header: {
                Text("扫描数据库（SQLite）")
            } footer: {
                Text("总体积 = .sqlite + -wal + -shm 三个文件合计。WAL 模式下 -wal 可能临时较大，VACUUM 后会回收。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        pendingStorageAction = .vacuum
                    } label: {
                        Label("压缩数据库（VACUUM）", systemImage: "rectangle.compress.vertical")
                    }
                    .disabled(storageBusy)
                    Spacer()
                }
                HStack {
                    Button {
                        pendingStorageAction = .clearAll
                    } label: {
                        Label("清空扫描结果", systemImage: "trash")
                    }
                    .disabled(storageBusy)
                    Spacer()
                }
                HStack {
                    Button(role: .destructive) {
                        pendingStorageAction = .deleteFiles
                    } label: {
                        Label("删除数据库文件", systemImage: "exclamationmark.triangle")
                    }
                    .disabled(storageBusy)
                    Spacer()
                }
                if let msg = storageMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if storageBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("处理中…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("清理操作")
            } footer: {
                Text("由轻到重：VACUUM 仅紧凑空间；清空表丢扫描历史保留 schema；删文件最彻底，下次启动重建。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("日志目录") {
                    Text(GSYLog.currentLogDirectory?.path ?? "（未启用文件落盘）")
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button {
                        openLogDirectory()
                    } label: {
                        Label("打开日志目录", systemImage: "folder")
                    }
                    .disabled(GSYLog.currentLogDirectory == nil)
                    Spacer()
                    Button {
                        openTodayLogFile()
                    } label: {
                        Label("查看今日日志", systemImage: "doc.text")
                    }
                    .disabled(GSYLog.currentLogFileURL() == nil)
                }
            } header: {
                Text("运行日志")
            } footer: {
                Text("按天滚动，保留最近 7 天。Debug 构建默认含 debug 级，Release 构建仅 info 及以上。遇到问题可把日志附给开发者。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert(item: $pendingStorageAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text("确认")) {
                    Task { await performStorageAction(action) }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: 存储行为

    /// 拉一次 DB 描述快照刷新 UI。
    fileprivate func refreshStorage() async {
        guard let url = try? GRDBScanResultStore.defaultDatabaseURL() else {
            await MainActor.run {
                storageDescription = nil
                storageMessage = "无法解析 Application Support 目录"
            }
            return
        }
        // 文件不存在（首次启动 / 已删除）：直接给一个零计数的描述，避免阻塞 UI。
        if !FileManager.default.fileExists(atPath: url.path) {
            await MainActor.run {
                storageDescription = ScanStoreDescription(
                    databaseURL: url,
                    totalSizeBytes: 0,
                    sessionCount: 0,
                    resultRowCount: 0
                )
            }
            return
        }
        do {
            let store = try GRDBScanResultStore(databaseURL: url)
            let desc = try await store.describeStorage()
            await MainActor.run {
                storageDescription = desc
            }
        } catch {
            GSYLog.error(.settings, "refreshStorage 失败 err=\(error)")
            await MainActor.run {
                storageMessage = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    fileprivate func performStorageAction(_ action: StorageAction) async {
        await MainActor.run {
            storageBusy = true
            storageMessage = nil
        }
        defer {
            Task { @MainActor in storageBusy = false }
        }
        guard let url = try? GRDBScanResultStore.defaultDatabaseURL() else {
            await MainActor.run { storageMessage = "无法解析数据库路径" }
            return
        }
        GSYLog.notice(.settings, "执行存储清理 action=\(action.id) path=\(url.path)")
        do {
            switch action {
            case .vacuum:
                let store = try GRDBScanResultStore(databaseURL: url)
                try await store.vacuum()
                await MainActor.run { storageMessage = "VACUUM 已完成。" }
            case .clearAll:
                let store = try GRDBScanResultStore(databaseURL: url)
                try await store.clearAll()
                await MainActor.run { storageMessage = "已清空全部扫描结果。" }
            case .deleteFiles:
                // 文件级删除前提：当前进程内没有 store 持有句柄。Settings 窗口里
                // 即便用户正在主窗口扫描也很难命中（Settings 是独立 Scene），
                // 这里用 nonisolated 静态删，下次构造 store 时 migration 会重建。
                try GRDBScanResultStore.deleteDatabaseFiles(at: url)
                await MainActor.run { storageMessage = "已删除 .sqlite / -wal / -shm 文件。" }
            }
        } catch {
            GSYLog.error(.settings, "存储清理失败 action=\(action.id) err=\(error)")
            await MainActor.run { storageMessage = "失败：\(error.localizedDescription)" }
        }
        await refreshStorage()
    }

    fileprivate func revealDatabaseInFinder() {
        guard let url = try? GRDBScanResultStore.defaultDatabaseURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // 文件还没建：退一级展示父目录。
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: 日志行为

    fileprivate func openLogDirectory() {
        guard let dir = GSYLog.currentLogDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    fileprivate func openTodayLogFile() {
        guard let url = GSYLog.currentLogFileURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // 没有今日日志（启动后从未写过）：退到目录。
            openLogDirectory()
        }
    }

    // MARK: 工具

    fileprivate static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}