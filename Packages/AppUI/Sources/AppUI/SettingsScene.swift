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

    /// 路径列表的 UI 镜像。actor 数据要在 SwiftUI 里显示必须先快照。
    @State private var pathsMirror: [URL] = []

    public init(settings: AppSettings, pathStore: UserPathStore) {
        self.settings = settings
        self.pathStore = pathStore
    }

    public var body: some View {
        TabView {
            scanTab
                .tabItem { Label("扫描", systemImage: "magnifyingglass") }
            largeFilesTab
                .tabItem { Label("大文件", systemImage: "doc.richtext") }
            pathsTab
                .tabItem { Label("自定义路径", systemImage: "folder.badge.plus") }
        }
        .frame(width: 520, height: 360)
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
