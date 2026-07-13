import SwiftUI
import AppKit
import ScanKit

/// v1.2 P2-1 重复文件去重屏。
///
/// 与 [AppFootprintScreen.swift](AppFootprintScreen.swift) / [LaunchAgentScreen.swift] 同源约定：
/// - DuplicateScanner 只负责「查看 / 比对」，不暴露删除 API。
/// - UI 层提供每组处理入口，删除动作统一走 TrashPipeline 移到废纸篓。
/// - 顶部 banner 醒目提示「重复检测可能漏报或误报」，prefix-only 组建议手动核对。
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
    @State private var activeSheet: ActiveSheet?
    @State private var isDeletingDuplicates: Bool = false

    private let pipeline: any DeletionPipeline

    private enum ActiveSheet: Identifiable {
        case handle(DuplicateGroup)
        case result(OperationResultPayload)

        var id: String {
            switch self {
            case .handle(let group): return "handle-\(group.id)"
            case .result(let payload): return "result-\(payload.id)"
            }
        }
    }

    public init(pipeline: any DeletionPipeline) {
        self.pipeline = pipeline
    }

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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .handle(let group):
                DuplicateHandleSheet(
                    group: group,
                    isDeleting: isDeletingDuplicates,
                    onCancel: { activeSheet = nil },
                    onDefault: { deleteDuplicatePaths(group: group, paths: DuplicateHandlingPlan.defaultDeleteTargets(for: group)) },
                    onManual: { paths in deleteDuplicatePaths(group: group, paths: paths) }
                )
            case .result(let payload):
                OperationResultSheet(payload: payload) {
                    activeSheet = nil
                }
            }
        }
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
                Text("duplicate.banner.title", bundle: .module)
                    .font(.callout.bold())
                Text("duplicate.banner.detail", bundle: .module)
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
                Text(String(format: String(localized: "duplicate.topbar.roots", bundle: .module), roots.count)).font(.caption).foregroundStyle(.secondary)
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
                Text(String(format: String(localized: "duplicate.topbar.min_size", bundle: .module), minStep.label)).font(.caption).foregroundStyle(.secondary)
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
                    Label {
                        Text("duplicate.topbar.stop", bundle: .module)
                    } icon: {
                        Image(systemName: "stop.circle")
                    }
                }
            } else {
                Button {
                    startScan()
                } label: {
                    Label {
                        Text("duplicate.topbar.start", bundle: .module)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
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
                Text("duplicate.left.title", bundle: .module).font(.headline)
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
                placeholder(String(localized: "duplicate.placeholder.scanning", bundle: .module), systemImage: "hourglass")
            } else if groups.isEmpty {
                placeholder(String(localized: "duplicate.placeholder.no_results", bundle: .module), systemImage: "doc.on.doc")
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
                Text(String(format: String(localized: "duplicate.group.copies", bundle: .module), g.paths.count))
                    .font(.callout.bold())
                Spacer()
                Text(byteString(g.totalBytes))
                    .font(.callout.monospacedDigit())
                Button {
                    activeSheet = .handle(g)
                } label: {
                    Label(String(localized: "duplicate.action.handle", bundle: .module),
                          systemImage: "checklist")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "duplicate.action.handle", bundle: .module))
                .disabled(isDeletingDuplicates)
            }
            Text(String(format: String(localized: "duplicate.group.reclaim_per", bundle: .module), byteString(g.reclaimableBytes), byteString(g.bytes)))
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
                                Button {
                                    revealInFinder(path: p)
                                } label: {
                                    Text("duplicate.menu.reveal_in_finder", bundle: .module)
                                }
                                Button {
                                    copyToPasteboard(p)
                                } label: {
                                    Text("duplicate.menu.copy_path", bundle: .module)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            } else {
                placeholder(String(localized: "duplicate.placeholder.select_group", bundle: .module), systemImage: "sidebar.right")
            }
        }
    }

    private func detailHeader(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(g.reliability == .full
                     ? String(localized: "duplicate.detail.full_hash", bundle: .module)
                     : String(localized: "duplicate.detail.prefix_hash", bundle: .module))
                    .font(.callout.bold())
                    .foregroundStyle(g.reliability == .full ? .green : .orange)
                Spacer()
                Text(String(format: String(localized: "duplicate.detail.copies_size", bundle: .module), g.paths.count, byteString(g.bytes)))
                    .font(.callout.monospacedDigit())
                Button {
                    activeSheet = .handle(g)
                } label: {
                    Label(String(localized: "duplicate.action.handle", bundle: .module),
                          systemImage: "checklist")
                }
                .controlSize(.small)
                .disabled(isDeletingDuplicates)
            }
            Text(String(format: String(localized: "duplicate.detail.reclaimable", bundle: .module), byteString(g.reclaimableBytes)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("duplicate.detail.tip", bundle: .module)
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
                    Text(String(format: String(localized: "duplicate.footer.phase_progress", bundle: .module), phaseLabel, bucketsDone, bucketsTotal))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: String(localized: "duplicate.footer.phase_candidates", bundle: .module), phaseLabel, sizingFiles))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if !groups.isEmpty {
                let totalReclaim = groups.map(\.reclaimableBytes).reduce(0, +)
                Text(String(format: String(localized: "duplicate.footer.summary", bundle: .module), groups.count, byteString(totalReclaim)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !tccSkippedRoots.isEmpty {
                Text(String(format: String(localized: "duplicate.footer.tcc_skipped", bundle: .module), tccSkippedRoots.count))
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Spacer()
            Text("duplicate.footer.delete_hint", bundle: .module)
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
        panel.title = String(localized: "duplicate.panel.title", bundle: .module)
        panel.prompt = String(localized: "duplicate.panel.prompt", bundle: .module)
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

    private func deleteDuplicatePaths(group: DuplicateGroup, paths: [String]) {
        guard DuplicateHandlingPlan.isValidDeleteTargets(paths, for: group), !isDeletingDuplicates else { return }
        isDeletingDuplicates = true
        Task { @MainActor in
            let action = TrashActionCoordinator(pipeline: pipeline)
            let result = await action.run(TrashActionCoordinator.Request(
                paths: paths,
                dryRun: false,
                source: "duplicate",
                accessDeniedPaths: []
            ))
            isDeletingDuplicates = false
            let movedPairs = result.outcome?.movedPairs.map { ($0.originalPath, $0.trashedPath) } ?? result.pairs
            let succeededPaths = result.succeededPaths
            if !succeededPaths.isEmpty {
                pruneMovedDuplicatePaths(Set(succeededPaths))
            }
            if let outcome = result.outcome {
                activeSheet = .result(OperationResultPayload(outcome: outcome))
            } else {
                let succeeded = Set(succeededPaths)
                activeSheet = .result(OperationResultPayload(
                    movedPairs: movedPairs,
                    failedPaths: result.err == nil ? [] : paths.filter { !succeeded.contains($0) },
                    safetyRejected: []
                ))
            }
        }
    }

    private func pruneMovedDuplicatePaths(_ moved: Set<String>) {
        guard !moved.isEmpty else { return }
        groups = groups.compactMap { group in
            let remaining = group.paths.filter { !moved.contains($0) }
            guard remaining.count >= 2 else { return nil }
            return DuplicateGroup(hashKey: group.hashKey,
                                  bytes: group.bytes,
                                  paths: remaining,
                                  reliability: group.reliability)
        }
        if let selectedGroupID, !groups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = groups.first?.id
        }
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
        phaseLabel = String(localized: "duplicate.phase.enumerate", bundle: .module)
        isScanning = true

        let scanner = DuplicateScanner(roots: roots, minBytes: minStep.bytes)
        scanTask = Task { @MainActor in
            for await event in scanner.scan() {
                if Task.isCancelled { break }
                switch event {
                case .sizingProgress(let n):
                    phaseLabel = String(localized: "duplicate.phase.enumerate", bundle: .module)
                    sizingFiles = n
                case .hashingProgress(let done, let total):
                    phaseLabel = String(localized: "duplicate.phase.prefix_hash", bundle: .module)
                    bucketsDone = done
                    bucketsTotal = total
                case .fullHashingProgress(let done, let total):
                    phaseLabel = String(localized: "duplicate.phase.full_hash", bundle: .module)
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

private struct DuplicateHandleSheet: View {
    let group: DuplicateGroup
    let isDeleting: Bool
    let onCancel: () -> Void
    let onDefault: () -> Void
    let onManual: ([String]) -> Void

    @State private var manualTargets: Set<String>

    init(group: DuplicateGroup,
         isDeleting: Bool,
         onCancel: @escaping () -> Void,
         onDefault: @escaping () -> Void,
         onManual: @escaping ([String]) -> Void) {
        self.group = group
        self.isDeleting = isDeleting
        self.onCancel = onCancel
        self.onDefault = onDefault
        self.onManual = onManual
        _manualTargets = State(initialValue: Set(DuplicateHandlingPlan.defaultDeleteTargets(for: group)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                defaultSection
                Divider()
                manualSection
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: group.reliability == .full ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(group.reliability == .full ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("duplicate.handle.title", bundle: .module)
                    .font(.title2.bold())
                Text(String(format: String(localized: "duplicate.handle.subtitle %lld %@", bundle: .module),
                            group.paths.count,
                            ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var defaultSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "1.circle")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("duplicate.handle.default.title", bundle: .module)
                    .font(.headline)
                Text(String(format: String(localized: "duplicate.handle.default.detail %@", bundle: .module),
                            URL(fileURLWithPath: group.paths.first ?? "").lastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if group.reliability != .full {
                    Text("duplicate.handle.prefix.warning", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                onDefault()
            } label: {
                if isDeleting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("duplicate.handle.default.button", bundle: .module)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDeleting || group.paths.count < 2)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("duplicate.handle.manual.title", bundle: .module)
                .font(.headline)
            Text("duplicate.handle.manual.detail", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(group.paths, id: \.self) { path in
                    Toggle(isOn: binding(for: path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isDeleting)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 210)
        }
    }

    private var footer: some View {
        HStack {
            Text(String(format: String(localized: "duplicate.handle.selected %lld %@", bundle: .module),
                        manualTargets.count,
                        ByteCountFormatter.string(fromByteCount: group.bytes * Int64(manualTargets.count), countStyle: .file)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "delete.action.cancel", bundle: .module), role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "duplicate.handle.manual.button", bundle: .module), role: .destructive) {
                onManual(Array(manualTargets))
            }
            .disabled(isDeleting || !DuplicateHandlingPlan.isValidDeleteTargets(Array(manualTargets), for: group))
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { manualTargets.contains(path) },
            set: { newValue in
                if newValue {
                    manualTargets.insert(path)
                } else {
                    manualTargets.remove(path)
                }
            }
        )
    }
}

enum DuplicateHandlingPlan {
    static func defaultDeleteTargets(for group: DuplicateGroup) -> [String] {
        Array(group.paths.dropFirst())
    }

    static func isValidDeleteTargets(_ paths: [String], for group: DuplicateGroup) -> Bool {
        let uniqueTargets = Set(paths)
        guard !uniqueTargets.isEmpty,
              uniqueTargets.count == paths.count,
              uniqueTargets.count < group.paths.count else {
            return false
        }
        let allPaths = Set(group.paths)
        return uniqueTargets.isSubset(of: allPaths)
    }
}
