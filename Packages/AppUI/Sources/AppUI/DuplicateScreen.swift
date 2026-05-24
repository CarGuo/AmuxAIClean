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
            // v1.3.aa：原本 HSplitView { left minWidth:320 + right minWidth:320 }，
            // 总和 640 远超外层 NavigationSplitView 的 detail 列容纳，会反向把
            // 外层 sidebar 挤掉一半（图 2 的"sidebar 推到右、内容溢出"）。
            // 改成 HStack + Divider 后约束传播正常，不再挤外层。
            // v1.3.ab：进一步——给左右栏都加 maxWidth: .infinity，强制平分剩余宽度，
            // 不让某栏内的长路径 ideal width 反向把整个 HStack 撑出窗口外（图2 第二轮根因）。
            HStack(spacing: 0) {
                leftList
                    .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity)
                    .layoutPriority(1)
                Divider()
                rightDetail
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .layoutPriority(1)
            }
            // v1.3.ab：HStack 本身也兜底 maxWidth，让 SwiftUI 把外层窗口宽度作为权威 proposed。
            .frame(maxWidth: .infinity)
            Divider()
            footer
        }
        // v1.3.ab：整个 VStack 也强制 maxWidth: .infinity，
        // 让 banner / topBar 内的 chip / 滑杆 即使 ideal width 较大也不会反推外层。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { scanTask?.cancel() }
        // v2：套布局沙箱——切断左右两栏（leftList / rightDetail）任何一行 path
        // 反向把 detail 列宽推大、再反挤外层 NavigationSplitView sidebar 的链条。
        .layoutSandbox()
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
        // v1.3.ab：banner 强制 maxWidth: .infinity，避免标题文本 ideal width 反推。
        .frame(maxWidth: .infinity)
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
                // v1.3.ab：扫描根 chip 横排——根多了之后 ideal width 会爆窗口，
                // 包一层 ScrollView(.horizontal) 让它在窗口窄时滚动，不再反推父容器。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(roots, id: \.self) { url in
                            rootChip(url)
                                // 单个 chip 内长路径已有 truncation，再硬限上限避免 chip 自己撑爆
                                .frame(maxWidth: 220)
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
            }
            // v1.3.ab：左侧 chip 区允许伸缩，但优先级低于右侧控件——
            // 让滑杆/按钮始终可见，多余宽度被 ScrollView 滚动吸收。
            .layoutPriority(0)
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
                // v1.3.ab：原本 `.frame(width: 280)` 死宽度，窗口窄时会反推父级。
                // 改成 minWidth/idealWidth/maxWidth，给 SwiftUI 空间在窄窗口下压缩。
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 320)
                .disabled(isScanning)
            }
            .layoutPriority(1)
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
        // v1.3.ab：topBar 整段强制 maxWidth: .infinity，与外层 VStack 一致，
        // 防止内部子视图本征宽度反推。
        .frame(maxWidth: .infinity)
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
            home.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL,
            home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL,
            home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL
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
            // panel.begin 回调线程契约未保证；显式跳回 MainActor 修改 @State，
            // 避免 Swift 6 严格并发告警 + SwiftUI 跨线程更新警告。
            // 同时把每个 url 归一化（standardizedFileURL）后再判重，
            // 避免 trailing slash / file:// scheme 差异导致同一目录被加两次。
            Task { @MainActor in
                guard response == .OK else { return }
                for raw in panel.urls {
                    let url = raw.standardizedFileURL
                    if !roots.contains(url) {
                        roots.append(url)
                    }
                }
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
                case .cancelled:
                    // 用户/上游 cancel：保留 groups 不动，仅退出 isScanning 状态。
                    // 与「停止仅终止扫描、保留已有结果」UX 一致。
                    break
                case .tccProtectedSkipped(let path):
                    tccSkippedRoots.append(path)
                }
            }
            // 无论正常 finished 还是 cancel，退出循环时一并复位进度计数与标签，
            // 避免下次启动前 footer 闪显旧进度数字。
            isScanning = false
            phaseLabel = ""
            bucketsDone = 0
            bucketsTotal = 0
            sizingFiles = 0
        }
    }
}
