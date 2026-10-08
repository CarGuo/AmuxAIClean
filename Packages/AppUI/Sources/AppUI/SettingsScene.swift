import SwiftUI
import AppKit
import LogKit
import ScanKit
import AIKit
import UniformTypeIdentifiers

/// v2026.07.15：设置页瞬态反馈只保存语义和不可翻译参数，显示时再按当前 locale 投影。
///
/// 过去在操作完成时直接把本地化后的 `String` 写进 `@State`，切换语言后该字符串不会
/// 重新计算，造成同一设置窗口内中英文混排。保留 error detail/path 等原始参数，避免
/// 为刷新语言重新执行导入、导出或清理操作。
enum SettingsPathImportNotice: Equatable {
    case duplicate(count: Int)
    /// v2026.07.16：系统选择器错误只进入日志；UI 保存稳定语义，避免 raw NSError、
    /// percent-encoded 路径或启动语言快照直接泄漏到用户界面。
    case failed

    func localized(locale: Locale) -> String {
        switch self {
        case .duplicate(let count):
            return AppLocalization.format(
                "custom_path.import.duplicate %lld",
                locale: locale,
                arguments: [count]
            )
        case .failed:
            return AppLocalization.string("custom_path.import.failed", locale: locale)
        }
    }
}

enum SettingsLogActionNotice: Equatable {
    case exported(path: String)
    case cleared(count: Int)

    func localized(locale: Locale) -> String {
        switch self {
        case .exported(let path):
            return AppLocalization.format(
                "settings.storage.log.export.done %@",
                locale: locale,
                arguments: [path]
            )
        case .cleared(let count):
            return AppLocalization.format(
                "settings.storage.log.clear.done %d",
                locale: locale,
                arguments: [count]
            )
        }
    }
}

/// v2026.07.18 P2 diagnostics contract: every sink stage has a localized semantic name while the
/// stable domain/code remain selectable technical detail. Raw Error text and paths never cross
/// into the user-facing warning.
public enum SettingsLogFailurePresentation {
    public static func title(locale: Locale) -> String {
        AppLocalization.string("log.failure.title", locale: locale)
    }

    public static func localized(
        _ failure: LogFileSinkFailure,
        locale: Locale
    ) -> String {
        AppLocalization.format(
            "log.failure.detail %@ %@ %lld",
            locale: locale,
            arguments: [
                AppLocalization.string(stageKey(failure.stage), locale: locale),
                failure.errorDomain,
                Int64(failure.errorCode)
            ]
        )
    }

    private static func stageKey(_ stage: LogFileSinkFailure.Stage) -> String {
        switch stage {
        case .initialization: "log.failure.stage.initialization"
        case .open: "log.failure.stage.open"
        case .write: "log.failure.stage.write"
        case .prepareAccess: "log.failure.stage.prepare_access"
        case .enumerate: "log.failure.stage.enumerate"
        case .export: "log.failure.stage.export"
        case .clear: "log.failure.stage.clear"
        case .retention: "log.failure.stage.retention"
        case .disabled: "log.failure.stage.disabled"
        }
    }
}

/// Directory copy is a projection of the typed lifecycle, not a nil/non-nil guess. In particular,
/// background initialization must never be described as an explicit user/test disable.
public enum SettingsLogDirectoryPresentation {
    public static func localized(
        health: LogFileSinkHealth,
        directory: URL?,
        locale: Locale
    ) -> String {
        switch health {
        case .initializing:
            return AppLocalization.string("settings.storage.log.initializing", locale: locale)
        case .ready:
            return directory?.path
                ?? AppLocalization.string("settings.storage.log.unavailable", locale: locale)
        case .unavailable:
            return AppLocalization.string("settings.storage.log.unavailable", locale: locale)
        case .disabled:
            return AppLocalization.string("settings.storage.log.no_file_sink", locale: locale)
        }
    }
}

/// v2026.07.16: one complete, testable mapping drives the Ventura-compatible
/// settings sidebar. Keeping title and icon metadata on every destination prevents
/// a newly added route from silently becoming unreachable or unlabeled.
extension SettingsNavigation.Destination {
    var settingsTitleKey: String {
        switch self {
        case .scan: "settings.tab.scan"
        case .largeFiles: "settings.tab.large_files"
        case .customPaths: "settings.tab.custom_paths"
        case .update: "settings.tab.update"
        case .developerScan: "settings.tab.dev_scan"
        case .storageAndLogs: "settings.tab.storage"
        case .ai: "settings.tab.ai"
        case .advanced: "settings.tab.advanced"
        }
    }

    var settingsSystemImage: String {
        switch self {
        case .scan: "magnifyingglass"
        case .largeFiles: "doc.richtext"
        case .customPaths: "folder.badge.plus"
        case .update: "arrow.down.circle"
        case .developerScan: "hammer"
        case .storageAndLogs: "internaldrive"
        case .ai: "sparkles"
        case .advanced: "shield"
        }
    }
}

/// v1.0 设置窗口（⌘, 自动可用）。
///
/// 三个分区：
/// 1. 扫描行为：显示隐藏文件 toggle（默认 ON，v1.3 修订）
/// 2. 大文件模块：阈值 Stepper（默认 100MB）
/// 3. 自定义扫描路径：列出 UserPathStore 已存路径，可移除
///
/// 决策来源：[docs/ROADMAP_V1.md](../../../../docs/ROADMAP_V1.md) §1 T2。
public struct SettingsScene: View {
    @ObservedObject private var settings: AppSettings
    private let pathStore: UserPathStore
    @ObservedObject private var updateChecker: UpdateChecker
    @StateObject private var navigation: SettingsNavigation
    /// M5 / 2026-06：AI 模块配置。
    /// **必须**由 App 层（[GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)）
    /// 注入与 [MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 共享同一份 ObservableObject 实例：⌘, 改了 AI Enabled / baseURL，RowView contextMenu
    /// 的"问 AI"按钮要立刻刷新可见性。若两端各自 `AISettings()`，UserDefaults 持久化
    /// 一致但对象通知不跨实例 → 需重启 App 才生效（Review fix #2，2026-06-15）。
    /// 为兼容旧测试 / Preview，参数允许省略，省略时仍 new 一份私有实例（仅 settings 窗口自用）。
    @StateObject private var aiSettings: AISettings
    /// v2026.07.16：NavigationSplitView 只挂载当前 detail；把未保存的 Key 草稿与
    /// Keychain 反馈提升到场景生命周期，切换侧栏不会销毁输入或重复触发初始读取。
    @StateObject private var aiTabState: AISettingsTabState
    @ObservedObject private var sentinelManager: SentinelManager

    /// 当前 SwiftUI 环境的 locale —— 给语言 Picker 选项做"按当前界面语言展示"用。
    /// [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 已经在两个 Scene 上挂 `.environment(\.locale, settings.effectiveLocale)`，
    /// 这里读出来再透传给 [LanguageOverride.label(in:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 即可让 Picker 选项跟随。
    @Environment(\.locale) private var currentEnvironmentLocale

    /// 路径列表的 UI 镜像。actor 数据要在 SwiftUI 里显示必须先快照。
    @State private var pathsMirror: [URL] = []
    @State private var logActionNotice: SettingsLogActionNotice?
    /// v2026.07.18 P2 diagnostics fix: a computed GSYLog snapshot does not invalidate SwiftUI
    /// when a later write/open fails. Keep the stream projection at scene lifetime so the warning
    /// appears while the page is already open and disappears only after a verified reopen.
    @State private var logSinkHealth = GSYLog.fileSinkHealth
    /// Writer availability and maintenance outcomes are independent: retention/export failure
    /// must stay visible even while appends remain healthy.
    @State private var logSinkIssues = GSYLog.fileSinkIssues
    @State private var logFilesSnapshot: [URL] = []
    @State private var isLogOperationInProgress = false
    @State private var confirmClearLogs = false
    @State private var isPathImporterPresented = false
    @State private var pathImportNotice: SettingsPathImportNotice?

    public init(settings: AppSettings,
                pathStore: UserPathStore,
                updateChecker: UpdateChecker,
                aiSettings: AISettings? = nil,
                navigation: SettingsNavigation? = nil,
                sentinelManager: SentinelManager) {
        self._settings = ObservedObject(wrappedValue: settings)
        self.pathStore = pathStore
        self._updateChecker = ObservedObject(wrappedValue: updateChecker)
        self._aiSettings = StateObject(wrappedValue: aiSettings ?? AISettings())
        self._aiTabState = StateObject(wrappedValue: AISettingsTabState())
        self._navigation = StateObject(wrappedValue: navigation ?? SettingsNavigation())
        self._sentinelManager = ObservedObject(wrappedValue: sentinelManager)
    }

    public var body: some View {
        // v2026.07.16 macOS 13 compatibility root fix:
        // macOS 15's new Tab/TabContent + sidebarAdaptable API made the entire settings
        // scene unavailable on Ventura. Settings navigation is structurally a master/detail
        // relationship, so model it once with NavigationSplitView instead of maintaining a
        // newer Tab implementation plus scattered availability branches. The shared
        // SettingsNavigation remains the source of truth, preserving external deep links.
        NavigationSplitView {
            List(SettingsNavigation.Destination.allCases, selection: $navigation.destination) { destination in
                Label {
                    Text(LocalizedStringKey(destination.settingsTitleKey), bundle: .module)
                } icon: {
                    Image(systemName: destination.settingsSystemImage)
                }
                .tag(destination)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            settingsDetail(for: navigation.destination)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 520)
        .background {
            LocalizedWindowTitle(title: AppLocalization.format(
                "settings.window.title %@",
                locale: currentEnvironmentLocale,
                arguments: [AppLocalization.string("app.name", locale: currentEnvironmentLocale)]
            ))
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .fileImporter(
            isPresented: $isPathImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true,
            onCompletion: handlePathImport
        )
        .alert(
            AppLocalization.string("custom_path.import.notice.title", locale: currentEnvironmentLocale),
            isPresented: Binding(
                get: { pathImportNotice != nil },
                set: { if !$0 { pathImportNotice = nil } }
            )
        ) {
            Button(AppLocalization.string("main.delete.result.ok", locale: currentEnvironmentLocale)) {
                pathImportNotice = nil
            }
        } message: {
            Text(pathImportNotice?.localized(locale: currentEnvironmentLocale) ?? "")
        }
        .task {
            let snapshots = await pathStore.snapshots()
            for await paths in snapshots {
                guard !Task.isCancelled else { return }
                pathsMirror = paths
            }
        }
        .task {
            for await health in GSYLog.fileSinkHealthUpdates() {
                guard !Task.isCancelled else { return }
                logSinkHealth = health
                // v2026.07.18: Settings may be opened while the background bootstrap is still
                // initializing. The ready transition must populate inventory in this same scene;
                // otherwise Open Today/Export remain disabled until the user closes and reopens it.
                if case .ready = health {
                    await refreshLogInventory()
                }
            }
        }
        .task {
            for await issues in GSYLog.fileSinkIssueUpdates() {
                guard !Task.isCancelled else { return }
                logSinkIssues = issues
            }
        }
    }

    @ViewBuilder
    private func settingsDetail(for destination: SettingsNavigation.Destination) -> some View {
        switch destination {
        case .scan:
            scanTab
        case .largeFiles:
            largeFilesTab
        case .customPaths:
            pathsTab
        case .update:
            updateTab
        case .developerScan:
            developerArtifactsTab
        case .storageAndLogs:
            storageTab
        case .ai:
            AISettingsTab(settings: aiSettings, state: aiTabState)
        case .advanced:
            advancedTab
        }
    }

    // MARK: - Tabs

    private var scanTab: some View {
        Form {
            Section {
                Picker(selection: $settings.preferredLanguage) {
                    ForEach(AppSettings.LanguageOverride.allCases, id: \.self) { lang in
                        // **v2026.06.18 修复**：原来用 `lang.label` 走进程级字符串解析，
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
                // v2026.07.17 C4 contract: language switching must be addressable by
                // semantic AX identity so the same App process can prove live relocalization.
                .accessibilityIdentifier("settings.language")
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
                        Text(placement.label(in: currentEnvironmentLocale)).tag(placement)
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
                    Stepper(AppLocalization.format(
                        "settings.large.value.format",
                        locale: currentEnvironmentLocale,
                        arguments: [settings.minFileSizeMB]
                    ),
                            value: $settings.minFileSizeMB,
                            in: AppSettings.allowedMinFileSizeMB...AppSettings.allowedMaxFileSizeMB,
                            step: 10)
                        .labelsHidden()
                    Text(AppLocalization.format(
                        "settings.large.value.format",
                        locale: currentEnvironmentLocale,
                        arguments: [settings.minFileSizeMB]
                    ))
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
                    isPathImporterPresented = true
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
                            Button {
                                Task { await removePath(url) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(AppLocalization.string("menu.path.remove", locale: currentEnvironmentLocale))
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
                        Text(AppLocalization.format(
                            "settings.update.skipped.format",
                            locale: currentEnvironmentLocale,
                            arguments: [skipped]
                        ))
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
                Text(AppLocalization.format(
                    "settings.update.status.newer.format",
                    locale: currentEnvironmentLocale,
                    arguments: [r.tagName]
                ))
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .foregroundStyle(.tint).font(.caption)
        case .skippedByUser(let r):
            Label {
                Text(AppLocalization.format(
                    "settings.update.status.skipped.format",
                    locale: currentEnvironmentLocale,
                    arguments: [r.tagName]
                ))
            } icon: {
                Image(systemName: "minus.circle")
            }
            .foregroundStyle(.secondary).font(.caption)
        case .failed(let failure):
            Label {
                Text(AppLocalization.format(
                    "settings.update.status.failed.format",
                    locale: currentEnvironmentLocale,
                    arguments: [failure.message(locale: currentEnvironmentLocale)]
                ))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange).font(.caption).lineLimit(1)
        case .none:
            EmptyView()
        }
    }

    // MARK: - 行为

    private func handlePathImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                var duplicateCount = 0
                for url in urls {
                    if !(await pathStore.add(url.standardizedFileURL)) {
                        duplicateCount &+= 1
                    }
                }
                if duplicateCount == urls.count {
                    pathImportNotice = .duplicate(count: duplicateCount)
                }
            }
        case .failure(let error):
            // 取消由系统 fileImporter 自己消化；其它错误必须留诊断证据，不能 try? 吞掉。
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            GSYLog.error(.settings, "settings directory importer failed: \(error.localizedDescription)")
            pathImportNotice = .failed
        }
    }

    private func removePath(_ url: URL) async {
        _ = await pathStore.remove(url)
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
                    Text(AppLocalization.format(
                        "settings.dev.enabled_count.format",
                        locale: currentEnvironmentLocale,
                        arguments: [settings.enabledDevArtifactRuleIDs.count, DevArtifactRules.all.count]
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
                                        Text(AppLocalization.string(
                                            rule.displayName,
                                            locale: currentEnvironmentLocale
                                        ))
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
                                    Text(AppLocalization.string(
                                        rule.subtitle,
                                        locale: currentEnvironmentLocale
                                    ))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !rule.siblingMarkers.isEmpty {
                                        Text(AppLocalization.format(
                                            "settings.dev.sibling_markers.format",
                                            locale: currentEnvironmentLocale,
                                            arguments: [rule.siblingMarkers.joined(separator: " / ")]
                                        ))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(AppLocalization.string(ecosystem.localizationKey, locale: currentEnvironmentLocale))
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
                    Text(
                        SettingsLogDirectoryPresentation.localized(
                            health: logSinkHealth,
                            directory: GSYLog.currentLogDirectory,
                            locale: currentEnvironmentLocale
                        )
                    )
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
                    // Keep the revalidation/retry entry available when a configured writer became
                    // unavailable. Initialization failure/explicit disable have no directory.
                    .disabled(GSYLog.currentLogDirectory == nil || isLogOperationInProgress)
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
                    .disabled(!isLogSinkReady || logFilesSnapshot.isEmpty || isLogOperationInProgress)
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
                    .disabled(!isLogSinkReady || logFilesSnapshot.isEmpty || isLogOperationInProgress)
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
                    .disabled(!isLogSinkReady || isLogOperationInProgress)
                }
                if let logActionNotice {
                    Text(logActionNotice.localized(locale: currentEnvironmentLocale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if case .unavailable(let failure) = logSinkHealth {
                    Text(SettingsLogFailurePresentation.localized(
                        failure,
                        locale: currentEnvironmentLocale
                    ))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                ForEach(visibleLogIssues, id: \.stage) { failure in
                    Text(SettingsLogFailurePresentation.localized(
                        failure,
                        locale: currentEnvironmentLocale
                    ))
                        .font(.caption)
                        .foregroundStyle(.orange)
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
        .task {
            await refreshLogInventory()
        }
        .confirmationDialog(
            AppLocalization.string("settings.storage.log.clear.confirm.title", locale: currentEnvironmentLocale),
            isPresented: $confirmClearLogs,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("settings.storage.log.clear.confirm.action", locale: currentEnvironmentLocale),
                   role: .destructive) {
                clearLogs()
            }
            Button(AppLocalization.string("settings.storage.log.clear.confirm.cancel", locale: currentEnvironmentLocale),
                   role: .cancel) {}
        } message: {
            Text("settings.storage.log.clear.confirm.message", bundle: .module)
        }
    }

    // MARK: 日志行为

    private var isLogSinkReady: Bool {
        if case .ready = logSinkHealth { return true }
        return false
    }

    private var visibleLogIssues: [LogFileSinkFailure] {
        guard case .unavailable(let writerFailure) = logSinkHealth else {
            return logSinkIssues.failures
        }
        return logSinkIssues.failures.filter { $0 != writerFailure }
    }

    fileprivate func openLogDirectory() {
        // File-system validation and fsync run on LogFileSink's utility queue. This Task only
        // resumes on the UI actor to open Finder or publish the typed result.
        Task { @MainActor in
            guard !isLogOperationInProgress else { return }
            isLogOperationInProgress = true
            defer { isLogOperationInProgress = false }
            switch await GSYLog.prepareLogDirectoryForAccess() {
            case .success(let dir):
                GSYLog.notice(.operation, "settings.log.open_directory path=\(dir.path)")
                NSWorkspace.shared.open(dir)
                logActionNotice = nil
                await refreshLogInventory()
            case .failure(let failure):
                GSYLog.error(
                    .operation,
                    "settings.log.open_directory_failed stage=\(failure.stage.rawValue) "
                        + "domain=\(failure.errorDomain) code=\(failure.errorCode)"
                )
                logActionNotice = nil
                synchronizeLogDiagnostics()
            }
        }
    }

    fileprivate func openTodayLogFile() {
        Task { @MainActor in
            guard !isLogOperationInProgress else { return }
            isLogOperationInProgress = true
            defer { isLogOperationInProgress = false }
            switch await GSYLog.prepareLogDirectoryForAccess() {
            case .success(let directory):
                guard let url = await GSYLog.currentLogFileURL() else {
                    NSWorkspace.shared.open(directory)
                    return
                }
                GSYLog.notice(.operation, "settings.log.open_today path=\(url.path)")
                NSWorkspace.shared.open(url)
                logActionNotice = nil
                await refreshLogInventory()
            case .failure(let failure):
                GSYLog.error(
                    .operation,
                    "settings.log.open_today_failed stage=\(failure.stage.rawValue) "
                        + "domain=\(failure.errorDomain) code=\(failure.errorCode)"
                )
                logActionNotice = nil
                synchronizeLogDiagnostics()
            }
        }
    }

    fileprivate func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AmuxAIClean-Logs.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            guard !isLogOperationInProgress else { return }
            isLogOperationInProgress = true
            defer { isLogOperationInProgress = false }
            switch await GSYLog.exportLogs(to: url) {
            case .success(let count):
                GSYLog.notice(.operation, "settings.log.export path=\(url.path) files=\(count)")
                logActionNotice = .exported(path: url.path)
                synchronizeLogDiagnostics()
            case .failure(let failure):
                GSYLog.error(
                    .operation,
                    "settings.log.export_failed stage=\(failure.stage.rawValue) "
                        + "domain=\(failure.errorDomain) code=\(failure.errorCode)"
                )
                logActionNotice = nil
                synchronizeLogDiagnostics()
            }
        }
    }

    fileprivate func clearLogs() {
        Task { @MainActor in
            guard !isLogOperationInProgress else { return }
            isLogOperationInProgress = true
            defer { isLogOperationInProgress = false }
            switch await GSYLog.clearLogs() {
            case .success(let count):
                GSYLog.notice(.operation, "settings.log.clear count=\(count)")
                logActionNotice = .cleared(count: count)
                await refreshLogInventory()
            case .failure(let failure):
                GSYLog.error(
                    .operation,
                    "settings.log.clear_failed stage=\(failure.stage.rawValue) "
                        + "domain=\(failure.errorDomain) code=\(failure.errorCode)"
                )
                logActionNotice = nil
                synchronizeLogDiagnostics()
            }
        }
    }

    @MainActor
    private func refreshLogInventory() async {
        switch await GSYLog.currentLogFiles() {
        case .success(let files):
            logFilesSnapshot = files
        case .failure:
            logFilesSnapshot = []
        }
        synchronizeLogDiagnostics()
    }

    @MainActor
    private func synchronizeLogDiagnostics() {
        logSinkHealth = GSYLog.fileSinkHealth
        logSinkIssues = GSYLog.fileSinkIssues
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
                        // v2026.07.16：该 String 必须显式绑定设置页当前语言；便利重载
                        // 只读取进程 locale，会让 Sentinel 状态卡在切换后继续显示英文日期。
                        Text(last.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened)
                                .locale(currentEnvironmentLocale)
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("settings.advanced.sentinel.last_enabled", bundle: .module)
                    }
                }
                LabeledContent {
                    Text(verbatim: sentinelManager.presentationState.localized(
                        locale: currentEnvironmentLocale
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("settings.advanced.sentinel.status", bundle: .module)
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
        .onAppear {
            // v2026.07.16：设置页每次出现都重新读取 SMAppService 权威状态；Toggle
            // 只表达用户意图，不能被当成“后台 Agent 已启用”的事实来源。
            sentinelManager.refreshPresentation()
        }
    }
}
