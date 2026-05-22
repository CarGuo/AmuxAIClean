import SwiftUI
import AppKit

/// v1.0 设置窗口（⌘, 自动可用）。
///
/// 三个分区：
/// 1. 扫描行为：显示隐藏文件 toggle（默认 OFF）
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
                        Text("打开后扫描会包含 .cursor / .npm / .cache 等以 . 开头的目录。默认 OFF，与 Finder 一致。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("扫描行为")
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
