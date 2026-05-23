import SwiftUI
import AppKit

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

    public init(settings: AppSettings, pathStore: UserPathStore, updateChecker: UpdateChecker) {
        self.settings = settings
        self.pathStore = pathStore
        self.updateChecker = updateChecker
    }

    public var body: some View {
        TabView {
            scanTab
                .tabItem { Label("扫描", systemImage: "magnifyingglass") }
            largeFilesTab
                .tabItem { Label("大文件", systemImage: "doc.richtext") }
            pathsTab
                .tabItem { Label("自定义路径", systemImage: "folder.badge.plus") }
            updateTab
                .tabItem { Label("更新", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520, height: 380)
        .task {
            await refreshPaths()
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
