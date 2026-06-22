import SwiftUI
import AppKit
import LogKit
import ScanKit
import AIKit
import UniformTypeIdentifiers

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

    /// 当前 SwiftUI 环境的 locale —— 给语言 Picker 选项做"按当前界面语言展示"用。
    /// [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 已经在两个 Scene 上挂 `.environment(\.locale, settings.effectiveLocale)`，
    /// 这里读出来再透传给 [LanguageOverride.label(in:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 即可让 Picker 选项跟随。
    @Environment(\.locale) private var currentEnvironmentLocale

    /// 路径列表的 UI 镜像。actor 数据要在 SwiftUI 里显示必须先快照。
    @State private var pathsMirror: [URL] = []
    @State private var logActionMessage: String?
    @State private var confirmClearLogs = false

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
        }
    }

    // MARK: - Tabs

    /// **v2026.06.18**：让用户在改完语言后自助"立即重启 App"，把原生主菜单/系统弹窗
    /// 也带到新语言。`relaunch` 走标准 macOS pattern：
    /// `/usr/bin/open -n` 异步打开自身一份新进程 → 当前进程 `terminate`。
    /// 不强制——也不在每次切语言时自动调用，避免破坏用户当前操作流。
    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            // 启动失败就什么都不做——保持当前进程存活，用户至少不会"两边都没了"。
            return
        }
        // 给新进程一点点起跑时间再退当前进程，避免极少数情况下 launchd 还没接到新实例。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private var scanTab: some View {
        Form {
            Section {
                Picker(selection: $settings.preferredLanguage) {
                    ForEach(AppSettings.LanguageOverride.allCases, id: \.self) { lang in
                        // **v2026.06.18 修复**：原来用 `lang.label` 走 `String(localized:)`，
                        // 该重载不读 SwiftUI 环境 locale，只读 process Bundle.main.preferredLocalizations，
                        // 导致中文界面下 Picker 选项仍显示 "Simplified Chinese / English / Follow System"。
                        // 现在显式透传环境 locale，让选项文本与界面其它文本同语言。
                        Text(lang.label(in: currentEnvironmentLocale)).tag(lang)
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
                    HStack(alignment: .top, spacing: 8) {
                        Text("settings.language.restart_hint", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            restartApp()
                        } label: {
                            Text("settings.language.restart_now", bundle: .module)
                        }
                        .controlSize(.small)
                    }
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

// MARK: - 日志 Tab

extension SettingsScene {
    /// 「日志」Tab：扫描结果不再落持久库，这里只保留诊断日志入口。
    fileprivate var storageTab: some View {
        Form {
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
                HStack {
                    Button {
                        exportLogs()
                    } label: {
                        Label {
                            Text("settings.storage.log.export", bundle: .module)
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(GSYLog.currentLogFiles().isEmpty)
                    Spacer()
                    Button(role: .destructive) {
                        confirmClearLogs = true
                    } label: {
                        Label {
                            Text("settings.storage.log.clear", bundle: .module)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(GSYLog.currentLogDirectory == nil)
                }
                if let logActionMessage {
                    Text(logActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
        .confirmationDialog(
            String(localized: "settings.storage.log.clear.confirm.title", bundle: .module),
            isPresented: $confirmClearLogs,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.storage.log.clear.confirm.action", bundle: .module),
                   role: .destructive) {
                clearLogs()
            }
            Button(String(localized: "settings.storage.log.clear.confirm.cancel", bundle: .module),
                   role: .cancel) {}
        } message: {
            Text("settings.storage.log.clear.confirm.message", bundle: .module)
        }
    }

    // MARK: 日志行为

    fileprivate func openLogDirectory() {
        guard let dir = GSYLog.currentLogDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        GSYLog.notice(.operation, "settings.log.open_directory path=\(dir.path)")
        NSWorkspace.shared.open(dir)
    }

    fileprivate func openTodayLogFile() {
        guard let url = GSYLog.currentLogFileURL() else { return }
        GSYLog.notice(.operation, "settings.log.open_today path=\(url.path)")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // 没有今日日志（启动后从未写过）：退到目录。
            openLogDirectory()
        }
    }

    fileprivate func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GSYCleanMac-Logs.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GSYLog.exportLogs(to: url)
            GSYLog.notice(.operation, "settings.log.export path=\(url.path) files=\(GSYLog.currentLogFiles().count)")
            logActionMessage = String(format: String(localized: "settings.storage.log.export.done %@", bundle: .module), url.path)
        } catch {
            GSYLog.error(.operation, "settings.log.export_failed path=\(url.path) error=\(error)")
            logActionMessage = String(format: String(localized: "settings.storage.log.export.failed %@", bundle: .module), "\(error)")
        }
    }

    fileprivate func clearLogs() {
        do {
            let count = try GSYLog.clearLogs()
            GSYLog.notice(.operation, "settings.log.clear count=\(count)")
            logActionMessage = String(format: String(localized: "settings.storage.log.clear.done %d", bundle: .module), count)
        } catch {
            GSYLog.error(.operation, "settings.log.clear_failed error=\(error)")
            logActionMessage = String(format: String(localized: "settings.storage.log.clear.failed %@", bundle: .module), "\(error)")
        }
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
