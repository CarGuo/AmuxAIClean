import SwiftUI
import AppKit
import ScanKit

/// v1.2 P2-1 重复文件去重屏（**只读视图**）。
///
/// 与 [AppFootprintScreen.swift](AppFootprintScreen.swift) / [LaunchAgentScreen.swift] 同源约定：
/// - 这是「**查看 / 比对**」入口，**不带删除按钮**；右键菜单仅 "在 Finder 中显示" / "拷贝路径"。
/// - 没有 trash 调用、没有勾选 set、没有清单提交。
/// - 顶部 banner 醒目提示「重复检测可能漏报或误报」，引导用户用 Finder 自行处理。
public struct DuplicateScreen: View {
    /// 顶栏「最小尺寸」滑杆挡位。
    enum SizeStep: Int, CaseIterable, Identifiable {
        case mb1 = 0, mb10, mb100, gb1
        var id: Int { rawValue }
        var bytes: Int64 {
            switch self {
            case .mb1:  return 1 * 1024 * 1024
            case .mb10: return 10 * 1024 * 1024
            case .mb100: return 100 * 1024 * 1024
            case .gb1:  return 1024 * 1024 * 1024
            }
        }
        var label: String {
            switch self {
            case .mb1:  return "1 MB"
            case .mb10: return "10 MB"
            case .mb100: return "100 MB"
            case .gb1:  return "1 GB"
            }
        }
    }

    // MARK: - State

    @State private var roots: [URL] = DuplicateScreen.defaultRoots()
    @State private var minStep: SizeStep = .mb10
    @State private var groups: [DuplicateGroup] = []
    @State private var selectedGroupID: String?
    @State private var isScanning: Bool = false
    @State private var phaseLabel: String = ""
    @State private var bucketsDone: Int = 0
    @State private var bucketsTotal: Int = 0
    @State private var sizingFiles: Int = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var tccSkippedRoots: [String] = []

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            topBar
            Divider()
            HSplitView {
                leftList
                    .frame(minWidth: 320, idealWidth: 420)
                rightDetail
                    .frame(minWidth: 320)
            }
            Divider()
            footer
        }
        .navigationTitle("重复文件")
        .onDisappear { scanTask?.cancel() }
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("重复文件检测可能漏报或误报")
                    .font(.callout.bold())
                Text("hardlink / clonefile / 仅前缀一致 都可能影响判定，删除前请人工核对。本视图为只读模式，不会删除任何文件，请用 Finder 自行处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.orange.opacity(0.4)),
                 alignment: .bottom)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // 扫描根（固定默认 + 可加）
            VStack(alignment: .leading, spacing: 2) {
                Text("扫描根 · \(roots.count)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(roots, id: \.self) { url in
                        rootChip(url)
                    }
                    Button {
                        addRootViaPanel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isScanning)
                }
            }
            Spacer(minLength: 12)
            // 最小尺寸滑杆
            VStack(alignment: .leading, spacing: 2) {
                Text("最小尺寸 · \(minStep.label)").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $minStep) {
                    ForEach(SizeStep.allCases) { step in
                        Text(step.label).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .disabled(isScanning)
            }
            // 开始 / 停止
            if isScanning {
                Button(role: .cancel) {
                    scanTask?.cancel()
                } label: {
                    Label("停止", systemImage: "stop.circle")
                }
            } else {
                Button {
                    startScan()
                } label: {
                    Label("开始扫描", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func rootChip(_ url: URL) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(displayName(for: url))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                roots.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Left list

    private var leftList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("重复组").font(.headline)
                if !groups.isEmpty {
                    Text("· \(groups.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if isScanning && groups.isEmpty {
                placeholder("正在扫描…", systemImage: "hourglass")
            } else if groups.isEmpty {
                placeholder("还没有结果，点上方「开始扫描」", systemImage: "doc.on.doc")
            } else {
                List(selection: $selectedGroupID) {
                    ForEach(groups) { g in
                        groupRow(g).tag(g.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func groupRow(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: g.reliability == .full ? "checkmark.seal.fill" : "questionmark.circle.fill")
                    .foregroundStyle(g.reliability == .full ? .green : .orange)
                    .font(.caption)
                Text("\(g.paths.count) 份")
                    .font(.callout.bold())
                Spacer()
                Text(byteString(g.totalBytes))
                    .font(.callout.monospacedDigit())
            }
            Text("可释放 \(byteString(g.reclaimableBytes)) · 单份 \(byteString(g.bytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(g.paths.first.map { (URL(fileURLWithPath: $0)).lastPathComponent } ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Right detail

    private var rightDetail: some View {
        VStack(spacing: 0) {
            if let g = selectedGroup {
                detailHeader(g)
                Divider()
                List {
                    ForEach(g.paths, id: \.self) { p in
                        pathRow(p)
                            .contextMenu {
                                Button("在 Finder 中显示") { revealInFinder(path: p) }
                                Button("拷贝路径") { copyToPasteboard(p) }
                            }
                    }
                }
                .listStyle(.inset)
            } else {
                placeholder("从左侧选择一组查看详情", systemImage: "sidebar.right")
            }
        }
    }

    private func detailHeader(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(g.reliability == .full ? "全文件 hash 一致" : "仅前缀 hash 一致（建议人工核对）")
                    .font(.callout.bold())
                    .foregroundStyle(g.reliability == .full ? .green : .orange)
                Spacer()
                Text("\(g.paths.count) 份 · \(byteString(g.bytes))")
                    .font(.callout.monospacedDigit())
            }
            Text("可释放空间 \(byteString(g.reclaimableBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("提示：本视图不会删除任何文件，请在 Finder 中确认后自行处理。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pathRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if isScanning {
                ProgressView().controlSize(.small)
                if bucketsTotal > 0 {
                    Text("\(phaseLabel) \(bucketsDone) / \(bucketsTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(phaseLabel) · \(sizingFiles) 个候选文件")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if !groups.isEmpty {
                let totalReclaim = groups.map(\.reclaimableBytes).reduce(0, +)
                Text("共 \(groups.count) 组 · 总可释放 \(byteString(totalReclaim))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !tccSkippedRoots.isEmpty {
                Text("· \(tccSkippedRoots.count) 个隐私目录已跳过")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Spacer()
            Text("只读视图，不会删除任何文件")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var selectedGroup: DuplicateGroup? {
        guard let id = selectedGroupID else { return nil }
        return groups.first { $0.id == id }
    }

    private static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true)
        ]
    }

    private func displayName(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        if p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    @ViewBuilder
    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addRootViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "选择要扫描的目录"
        panel.prompt = "添加"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where !roots.contains(url) {
                roots.append(url)
            }
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - Scan driver

    private func startScan() {
        scanTask?.cancel()
        groups = []
        selectedGroupID = nil
        tccSkippedRoots = []
        bucketsDone = 0
        bucketsTotal = 0
        sizingFiles = 0
        phaseLabel = "枚举文件"
        isScanning = true

        let scanner = DuplicateScanner(roots: roots, minBytes: minStep.bytes)
        scanTask = Task { @MainActor in
            for await event in scanner.scan() {
                if Task.isCancelled { break }
                switch event {
                case .sizingProgress(let n):
                    phaseLabel = "枚举文件"
                    sizingFiles = n
                case .hashingProgress(let done, let total):
                    phaseLabel = "前缀 hash"
                    bucketsDone = done
                    bucketsTotal = total
                case .fullHashingProgress(let done, let total):
                    phaseLabel = "全文件 hash"
                    bucketsDone = done
                    bucketsTotal = total
                case .finished(let g):
                    groups = g
                case .tccProtectedSkipped(let path):
                    tccSkippedRoots.append(path)
                }
            }
            isScanning = false
        }
    }
}
