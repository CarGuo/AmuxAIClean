import SwiftUI
import AppKit
import LogKit
import ScanKit
import AIKit

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
    /// M5 / 2026-06：AI 模块配置。
    /// **必须**由 App 层（[GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)）
    /// 注入与 [MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 共享同一份 @Observable 实例：⌘, 改了 AI Enabled / baseURL，RowView contextMenu
    /// 的"问 AI"按钮要立刻刷新可见性。若两端各自 `AISettings()`，UserDefaults 持久化
    /// 一致但 @Observable 通知不跨实例 → 需重启 App 才生效（Review fix #2，2026-06-15）。
    /// 为兼容旧测试 / Preview，参数允许省略，省略时仍 new 一份私有实例（仅 settings 窗口自用）。
    @Bindable private var aiSettings: AISettings

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
        var titleKey: String {
            switch self {
            case .vacuum: return "settings.storage.alert.vacuum.title"
            case .clearAll: return "settings.storage.alert.clear_all.title"
            case .deleteFiles: return "settings.storage.alert.delete_files.title"
            }
        }
        var messageKey: String {
            switch self {
            case .vacuum: return "settings.storage.alert.vacuum.message"
            case .clearAll: return "settings.storage.alert.clear_all.message"
            case .deleteFiles: return "settings.storage.alert.delete_files.message"
            }
        }
    }

    public init(settings: AppSettings,
                pathStore: UserPathStore,
                updateChecker: UpdateChecker,
                aiSettings: AISettings? = nil) {
        self.settings = settings
        self.pathStore = pathStore
        self.updateChecker = updateChecker
        self.aiSettings = aiSettings ?? AISettings()
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
            AISettingsTab(settings: aiSettings)
                .tabItem {
                    Label {
                        Text("settings.tab.ai", bundle: .module)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
            advancedTab
                .tabItem {
                    Label {
                        Text("settings.tab.advanced", bundle: .module)
                    } icon: {
                        Image(systemName: "shield")
                    }
                }
        }
        .frame(width: 520, height: 460)
        .task {
            await refreshPaths()
            await refreshStorage()
        }
    }

    // MARK: - Tabs

    private var scanTab: some View {
        Form {
            Section {
                Picker(selection: $settings.preferredLanguage) {
                    ForEach(AppSettings.LanguageOverride.allCases, id: \.self) { lang in
                        Text(lang.label).tag(lang)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.language.title", bundle: .module)
                        Text("settings.language.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
                if settings.preferredLanguage != .system {
                    Text("settings.language.restart_hint", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("settings.section.appearance", bundle: .module)
            }
            Section {
                Toggle(isOn: $settings.showHidden) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.scan.show_hidden.title", bundle: .module)
                        Text("settings.scan.show_hidden.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings.scan.section.behavior", bundle: .module)
            }
            Section {
                Picker(selection: $settings.sizeAccountingMode) {
                    ForEach(AppSettings.SizeAccountingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.scan.size_mode.title", bundle: .module)
                        Text("settings.scan.size_mode.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("settings.scan.section.size_mode", bundle: .module)
            }
            Section {
                Toggle(isOn: $settings.hudEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.scan.hud.title", bundle: .module)
                        Text("settings.scan.hud.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $settings.hudPersistent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.scan.hud_persistent.title", bundle: .module)
                        Text("settings.scan.hud_persistent.detail", bundle: .module)
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
                        Text("settings.scan.hud_placement.title", bundle: .module)
                        Text("settings.scan.hud_placement.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!settings.hudEnabled)
                Toggle(isOn: $settings.trayEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.scan.tray.title", bundle: .module)
                        Text("settings.scan.tray.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $settings.hideFromDockWhenClosed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.scan.hide_dock.title", bundle: .module)
                        Text("settings.scan.hide_dock.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.trayEnabled)
            } header: {
                Text("settings.scan.section.interface", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var largeFilesTab: some View {
        Form {
            Section {
                HStack {
                    Text("settings.large.min_threshold", bundle: .module)
                    Spacer()
                    Stepper(String(format: String(localized: "settings.large.value.format", bundle: .module), settings.minFileSizeMB),
                            value: $settings.minFileSizeMB,
                            in: 10...10240,
                            step: 10)
                        .labelsHidden()
                    Text(String(format: String(localized: "settings.large.value.format", bundle: .module), settings.minFileSizeMB))
                        .monospacedDigit()
                        .frame(minWidth: 70, alignment: .trailing)
                }
                Text("settings.large.detail", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("settings.large.section.title", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var pathsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.paths.title", bundle: .module)
                    .font(.headline)
                Spacer()
                Button {
                    addPathViaPanel()
                } label: {
                    Label {
                        Text("settings.paths.add", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)

            if pathsMirror.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("settings.paths.empty.title", bundle: .module)
                        .foregroundStyle(.secondary)
                    Text("settings.paths.empty.hint", bundle: .module)
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
                        Text("settings.update.auto.title", bundle: .module)
                        Text("settings.update.auto.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings.update.section.auto", bundle: .module)
            }
            Section {
                HStack {
                    Text("settings.update.current_version", bundle: .module)
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
                            Text("settings.update.checking", bundle: .module)
                        } else {
                            Text("settings.update.check_now", bundle: .module)
                        }
                    }
                    .disabled(updateChecker.isChecking)
                    Spacer()
                    statusLabel
                }
                if let skipped = settings.skippedUpdateTag {
                    HStack {
                        Text(String(format: String(localized: "settings.update.skipped.format", bundle: .module), skipped))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            settings.skippedUpdateTag = nil
                        } label: {
                            Text("settings.update.clear_skip", bundle: .module)
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("settings.update.section.version", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch updateChecker.lastResult {
        case .upToDate:
            Label {
                Text("settings.update.status.up_to_date", bundle: .module)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green).font(.caption)
        case .newer(let r):
            Label {
                Text(String(format: String(localized: "settings.update.status.newer.format", bundle: .module), r.tagName))
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .foregroundStyle(.tint).font(.caption)
        case .skippedByUser(let r):
            Label {
                Text(String(format: String(localized: "settings.update.status.skipped.format", bundle: .module), r.tagName))
            } icon: {
                Image(systemName: "minus.circle")
            }
            .foregroundStyle(.secondary).font(.caption)
        case .failed(let msg):
            Label {
                Text(String(format: String(localized: "settings.update.status.failed.format", bundle: .module), msg))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
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
        panel.title = String(localized: "settings.paths.panel.title", bundle: .module)
        panel.prompt = String(localized: "settings.paths.panel.prompt", bundle: .module)
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
                Text("settings.dev.footer", bundle: .module)
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
                                            Text("settings.dev.verdict.confirm", bundle: .module)
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(rule.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !rule.siblingMarkers.isEmpty {
                                        Text(String(format: String(localized: "settings.dev.sibling_markers.format", bundle: .module), rule.siblingMarkers.joined(separator: " / ")))
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
                    LabeledContent {
                        Text(desc.databaseURL.path)
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } label: {
                        Text("settings.storage.db_path", bundle: .module)
                    }
                    LabeledContent {
                        Text(Self.formatBytes(desc.totalSizeBytes))
                            .monospacedDigit()
                    } label: {
                        Text("settings.storage.total_size", bundle: .module)
                    }
                    LabeledContent {
                        Text(String(format: String(localized: "settings.storage.session_rows.format", bundle: .module), desc.sessionCount, desc.resultRowCount))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("settings.storage.session_results", bundle: .module)
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("settings.storage.loading", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        Task { await refreshStorage() }
                    } label: {
                        Label {
                            Text("settings.storage.refresh", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(storageBusy)
                    Spacer()
                    Button {
                        revealDatabaseInFinder()
                    } label: {
                        Label {
                            Text("settings.storage.reveal_finder", bundle: .module)
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                }
            } header: {
                Text("settings.storage.section.db", bundle: .module)
            } footer: {
                Text("settings.storage.section.db.footer", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        pendingStorageAction = .vacuum
                    } label: {
                        Label {
                            Text("settings.storage.action.vacuum", bundle: .module)
                        } icon: {
                            Image(systemName: "rectangle.compress.vertical")
                        }
                    }
                    .disabled(storageBusy)
                    Spacer()
                }
                HStack {
                    Button {
                        pendingStorageAction = .clearAll
                    } label: {
                        Label {
                            Text("settings.storage.action.clear_all", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(storageBusy)
                    Spacer()
                }
                HStack {
                    Button(role: .destructive) {
                        pendingStorageAction = .deleteFiles
                    } label: {
                        Label {
                            Text("settings.storage.action.delete_files", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
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
                        Text("settings.storage.processing", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings.storage.section.cleanup", bundle: .module)
            } footer: {
                Text("settings.storage.section.cleanup.footer", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Text(GSYLog.currentLogDirectory?.path ?? String(localized: "settings.storage.log.no_file_sink", bundle: .module))
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } label: {
                    Text("settings.storage.log.dir", bundle: .module)
                }
                HStack {
                    Button {
                        openLogDirectory()
                    } label: {
                        Label {
                            Text("settings.storage.log.open_dir", bundle: .module)
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                    .disabled(GSYLog.currentLogDirectory == nil)
                    Spacer()
                    Button {
                        openTodayLogFile()
                    } label: {
                        Label {
                            Text("settings.storage.log.open_today", bundle: .module)
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                    .disabled(GSYLog.currentLogFileURL() == nil)
                }
            } header: {
                Text("settings.storage.section.log", bundle: .module)
            } footer: {
                Text("settings.storage.section.log.footer", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert(item: $pendingStorageAction) { action in
            Alert(
                title: Text(String(localized: String.LocalizationValue(action.titleKey), bundle: .module)),
                message: Text(String(localized: String.LocalizationValue(action.messageKey), bundle: .module)),
                primaryButton: .destructive(Text("settings.storage.alert.confirm", bundle: .module)) {
                    Task { await performStorageAction(action) }
                },
                secondaryButton: .cancel(Text("settings.storage.alert.cancel", bundle: .module))
            )
        }
    }

    // MARK: 存储行为

    /// 拉一次 DB 描述快照刷新 UI。
    fileprivate func refreshStorage() async {
        guard let url = try? GRDBScanResultStore.defaultDatabaseURL() else {
            await MainActor.run {
                storageDescription = nil
                storageMessage = String(localized: "settings.storage.error.app_support", bundle: .module)
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
                storageMessage = String(format: String(localized: "settings.storage.error.read.format", bundle: .module), error.localizedDescription)
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
            await MainActor.run { storageMessage = String(localized: "settings.storage.error.db_path", bundle: .module) }
            return
        }
        GSYLog.notice(.settings, "执行存储清理 action=\(action.id) path=\(url.path)")
        do {
            switch action {
            case .vacuum:
                let store = try GRDBScanResultStore(databaseURL: url)
                try await store.vacuum()
                await MainActor.run { storageMessage = String(localized: "settings.storage.result.vacuum_done", bundle: .module) }
            case .clearAll:
                let store = try GRDBScanResultStore(databaseURL: url)
                try await store.clearAll()
                await MainActor.run { storageMessage = String(localized: "settings.storage.result.clear_all_done", bundle: .module) }
            case .deleteFiles:
                // 文件级删除前提：当前进程内没有 store 持有句柄。Settings 窗口里
                // 即便用户正在主窗口扫描也很难命中（Settings 是独立 Scene），
                // 这里用 nonisolated 静态删，下次构造 store 时 migration 会重建。
                try GRDBScanResultStore.deleteDatabaseFiles(at: url)
                await MainActor.run { storageMessage = String(localized: "settings.storage.result.delete_files_done", bundle: .module) }
            }
        } catch {
            GSYLog.error(.settings, "存储清理失败 action=\(action.id) err=\(error)")
            await MainActor.run { storageMessage = String(format: String(localized: "settings.storage.result.failed.format", bundle: .module), error.localizedDescription) }
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

// MARK: - 高级 / 后台守护 Tab（v1.6 Sentinel）

extension SettingsScene {
    /// v1.6「高级」Tab：仅一项—— Sentinel 后台守护开关 + 状态展示 + 文档链接。
    /// 详细行为见 [docs/SENTINEL_DESIGN.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/SENTINEL_DESIGN.md)。
    fileprivate var advancedTab: some View {
        Form {
            Section {
                Toggle(isOn: $settings.sentinelEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.advanced.sentinel.title", bundle: .module)
                        Text("settings.advanced.sentinel.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let last = settings.sentinelLastEnabled {
                    LabeledContent {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("settings.advanced.sentinel.last_enabled", bundle: .module)
                    }
                }
            } header: {
                Text("settings.advanced.sentinel.section", bundle: .module)
            } footer: {
                Text("settings.advanced.sentinel.footer", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}
