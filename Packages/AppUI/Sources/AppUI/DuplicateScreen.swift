import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanKit
import LogKit
import SafetyKit

/// Pure routing boundary for Duplicate deletion. Keeping target-scope selection outside the
/// SwiftUI state machine makes the sibling-vs-selected incomplete contract behavior-testable.
enum DuplicateDeletionPreparationPolicy {
    static func relevantIssues(
        overlappingAny paths: [String],
        in issues: [ScanIncompleteIssue]
    ) -> [ScanIncompleteIssue] {
        var seen = Set<ScanIncompleteIssue>()
        return paths.flatMap { path in
            DeletionTargetRevalidator.relevantIssues(for: path, from: issues)
        }.filter { seen.insert($0).inserted }
    }

    static func accessEvidence(
        for path: String,
        issues: [ScanIncompleteIssue]
    ) -> DeletionAccessEvidence {
        guard let issue = DeletionTargetRevalidator.relevantIssues(
            for: path,
            from: issues
        ).first else {
            return .complete
        }
        return .incomplete(DeletionIncompleteReason(scanIncompleteReason: issue.reason))
    }

    @MainActor
    static func prepare(
        pipeline: any DeletionPipeline,
        coordinator: DeletionInteractionCoordinator,
        intent: DeletionIntent,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        rows: [RowItem],
        relevantIssues: [ScanIncompleteIssue]
    ) async -> DeletionInteractionPreparation {
        guard !relevantIssues.isEmpty else {
            return await coordinator.prepare(
                intent: intent,
                currentSnapshotIdentity: currentSnapshotIdentity
            )
        }
        let targetPreparation = await pipeline.prepareScanIncompleteOverride(
            rows: rows,
            scanIssues: relevantIssues,
            scanSessionID: currentSnapshotIdentity.sessionID
        )
        return coordinator.prepareRevalidatedScanIncomplete(
            intent: intent,
            currentSnapshotIdentity: currentSnapshotIdentity,
            preparation: targetPreparation
        )
    }
}

/// Final Duplicate authorization is valid only for the exact scan snapshot that produced it.
/// The View evaluates this boundary both after sheet dismissal and immediately before submit,
/// so a newer scan can never reuse an older confirmation even when the path text is unchanged.
enum DuplicateDeletionSubmissionGate {
    enum Decision: Sendable, Equatable {
        case current
        case cancelled([DeletionPreflight.Rejection])
    }

    static func evaluate(
        requestSessionID: UUID,
        requestRevision: UInt64,
        boundSnapshotIdentity: DeletionSnapshotIdentity,
        currentSessionID: UUID,
        currentRevision: UInt64,
        paths: [String]
    ) -> Decision {
        let requestIdentity = DeletionSnapshotIdentity(
            sessionID: requestSessionID,
            revision: requestRevision,
            categoryID: "duplicate"
        )
        guard boundSnapshotIdentity == requestIdentity,
              currentSessionID == requestSessionID,
              currentRevision == requestRevision else {
            return .cancelled(paths.map {
                .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
            })
        }
        return .current
    }
}

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
    /// Typed completeness evidence belongs to one DuplicateScanner session. It is kept
    /// separately from the footer projection so an unrelated unreadable sibling cannot
    /// disable every deletion action in the screen.
    @State private var scanIncompleteIssues: [ScanIncompleteIssue] = []
    @State private var scanSessionID = UUID()
    @State private var scanRevision: UInt64 = 0
    @State private var activeSheet: ActiveSheet?
    @State private var isDeletingDuplicates: Bool = false
    @State private var isRootImporterPresented = false
    @State private var duplicateDeletionHandoff = ToolDeletionHandoff<DuplicateConfirmedDeletion>()
    @State private var duplicatePreflightTask: Task<Void, Never>?
    @State private var duplicatePreflightGate = ToolDeletionPreflightRequestGate<DuplicatePreflightContext>()

    private let pipeline: any DeletionPipeline

    private struct DuplicateDeleteRequest: Identifiable, Sendable {
        let id = UUID()
        let scanSessionID: UUID
        let scanRevision: UInt64
        let items: [RunningAppGuard.Candidate]
        let totalBytes: Int64
        let bytesByPath: [String: Int64]
        let accessEvidencePaths: Set<String>
        let prepared: DeletionPreparedInteraction

        var paths: [String] { items.map(\.path) }
    }

    private struct DuplicateConfirmedDeletion: Sendable {
        let request: DuplicateDeleteRequest
        let executionPlan: ToolTrashExecutionPlan
    }

    private struct DuplicatePreflightContext: Sendable, Equatable {
        let groupID: String
        let paths: [String]
        let scanSessionID: UUID
        let scanRevision: UInt64
    }

    private enum ActiveSheet: Identifiable {
        case handle(DuplicateGroup)
        case confirm(DuplicateDeleteRequest)
        case preflightNotice(DeletionPreflightNotice)
        case result(OperationResultCompletion)

        var id: String {
            switch self {
            case .handle(let group): return "handle-\(group.id)"
            case .confirm(let request): return "confirm-\(request.id)"
            case .preflightNotice(let notice): return "preflightNotice-\(notice.id)"
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
        .onDisappear {
            scanTask?.cancel()
            cancelDuplicatePreflight()
        }
        .sheet(
            isPresented: Binding(
                get: { activeSheet != nil },
                set: {
                    if !$0 {
                        cancelDuplicatePreflight()
                        activeSheet = nil
                    }
                }
            ),
            onDismiss: completeDuplicateSheetDismissal
        ) {
            if let sheet = activeSheet {
                switch sheet {
                case .handle(let group):
                    DuplicateHandleSheet(
                        group: group,
                        isDeleting: isDeletingDuplicates,
                        onCancel: {
                            cancelDuplicatePreflight()
                            activeSheet = nil
                        },
                        onDefault: {
                            prepareDuplicateDeletion(
                                group: group,
                                paths: DuplicateHandlingPlan.defaultDeleteTargets(for: group)
                            )
                        },
                        onManual: { paths in
                            prepareDuplicateDeletion(group: group, paths: paths)
                        }
                    )
                case .confirm(let request):
                    ToolTrashConfirmationSheet(
                        items: request.items,
                        totalBytes: request.totalBytes,
                        vendorOverrideRequest: request.prepared.vendorOverrideRequest,
                        scanIncompleteOverrideRequest: request.prepared.scanIncompleteOverrideRequest,
                        onCancel: { activeSheet = nil },
                        onConfirm: { executionPlan in
                            guard requireCurrentDuplicateRequest(request) else { return false }
                            guard duplicateDeletionHandoff.schedule(DuplicateConfirmedDeletion(
                                request: request,
                                executionPlan: executionPlan
                            )) else { return false }
                            activeSheet = nil
                            return true
                        }
                    )
                case .preflightNotice(let notice):
                    DeletionPreflightNoticeSheet(notice: notice) {
                        activeSheet = nil
                    }
                case .result(let completion):
                    OperationResultSheet(completion: completion) {
                        activeSheet = nil
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isRootImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true,
            onCompletion: handleRootImport
        )
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
                            isRootImporterPresented = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isScanning || isDeletionTransactionActive)
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
                .disabled(isScanning || isDeletionTransactionActive)
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
                .disabled(roots.isEmpty || isDeletionTransactionActive)
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
            .disabled(isScanning || isDeletionTransactionActive)
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
                Text(String(format: String(localized: "duplicate.group.copies", bundle: .module), g.files.count))
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
            Text(String(format: String(localized: "duplicate.group.reclaim_per", bundle: .module), byteString(g.reclaimableBytes), byteString(g.logicalBytes)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(g.files.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "")
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
                    ForEach(g.files, id: \.path) { file in
                        pathRow(file)
                            .contextMenu {
                                Button {
                                    revealInFinder(path: file.path)
                                } label: {
                                    Text("duplicate.menu.reveal_in_finder", bundle: .module)
                                }
                                Button {
                                    copyToPasteboard(file.path)
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
                Text(String(format: String(localized: "duplicate.detail.copies_size", bundle: .module), g.files.count, byteString(g.logicalBytes)))
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

    private func pathRow(_ file: DuplicateFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(file.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Text(byteString(file.allocatedBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
            if !scanIncompleteIssues.isEmpty {
                Text("main.scan.incomplete", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
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

    /// A scan revision must remain immutable from deletion preflight through final submit.
    /// The visible scan controls use this projection, while `startScan()` repeats the guard so
    /// programmatic or future entry points cannot bypass the UI-disabled state.
    private var isDeletionTransactionActive: Bool {
        if isDeletingDuplicates
            || duplicatePreflightTask != nil
            || duplicatePreflightGate.hasCurrentRequest
            || duplicateDeletionHandoff.hasPending {
            return true
        }
        switch activeSheet {
        case .handle, .confirm, .preflightNotice:
            return true
        case .result, .none:
            return false
        }
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

    private func handleRootImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            for raw in urls {
                let url = raw.standardizedFileURL
                if !roots.contains(url) {
                    roots.append(url)
                }
            }
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            GSYLog.error(.settings, "duplicate root importer failed: \(error.localizedDescription)")
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

    private func prepareDuplicateDeletion(group: DuplicateGroup, paths: [String]) {
        guard DuplicateHandlingPlan.isValidDeleteTargets(paths, for: group),
              !isDeletingDuplicates,
              !duplicateDeletionHandoff.hasPending else { return }
        let sessionID = scanSessionID
        let revision = scanRevision
        let relevantIssues = incompleteIssues(overlappingAny: paths)
        let context = DuplicatePreflightContext(
            groupID: group.id,
            paths: paths,
            scanSessionID: sessionID,
            scanRevision: revision
        )
        duplicatePreflightTask?.cancel()
        let token = duplicatePreflightGate.begin(context: context)
        isDeletingDuplicates = true
        duplicatePreflightTask = Task { @MainActor in
            let identity = DeletionSnapshotIdentity(
                sessionID: sessionID,
                revision: revision,
                categoryID: "duplicate"
            )
            let coordinator = DeletionInteractionCoordinator(pipeline: pipeline)
            let decision: DeletionInteractionPreparation
            do {
                let bytesByPath = duplicateBytesByPath(paths: paths, in: group)
                let rows = duplicateDeletionRows(
                    paths: paths,
                    bytesByPath: bytesByPath
                )
                let intent = try coordinator.makeIntent(
                    origin: .duplicate,
                    mode: .professional,
                    snapshotIdentity: identity,
                    candidates: paths.map { path in
                        DeletionInteractionCandidateSnapshot(
                            path: path,
                            title: URL(fileURLWithPath: path).lastPathComponent,
                            isDirectory: false,
                            bytes: bytesByPath[path] ?? 0,
                            fileCount: 1,
                            accessEvidence: deletionAccessEvidence(
                                for: path,
                                issues: relevantIssues
                            )
                        )
                    }
                )
                decision = await DuplicateDeletionPreparationPolicy.prepare(
                    pipeline: pipeline,
                    coordinator: coordinator,
                    intent: intent,
                    currentSnapshotIdentity: identity,
                    rows: rows,
                    relevantIssues: relevantIssues
                )
            } catch {
                decision = .blocked(DeletionInteractionBlock(
                    intentID: UUID(),
                    rejections: paths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                ))
            }
            guard duplicatePreflightGate.finishIfCurrent(token, context: context) else { return }
            duplicatePreflightTask = nil
            isDeletingDuplicates = false
            guard !Task.isCancelled,
                  scanSessionID == sessionID,
                  scanRevision == revision,
                  !duplicateDeletionHandoff.hasPending else { return }
            switch decision {
            case .confirmation(let prepared):
                activeSheet = .confirm(DuplicateDeleteRequest(
                    scanSessionID: sessionID,
                    scanRevision: revision,
                    items: prepared.confirmationCandidates,
                    totalBytes: selectedBytes(paths: prepared.paths, in: group),
                    bytesByPath: duplicateBytesByPath(paths: prepared.paths, in: group),
                    accessEvidencePaths: incompleteEvidencePaths(in: prepared),
                    prepared: prepared
                ))
            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
            case .cancelled:
                return
            }
        }
    }

    private func completeDuplicateSheetDismissal() {
        guard let submission = duplicateDeletionHandoff.takeAfterSheetDismissal() else { return }
        guard requireCurrentDuplicateRequest(submission.request) else { return }
        executeDuplicateDeletion(submission)
    }

    @discardableResult
    private func requireCurrentDuplicateRequest(
        _ request: DuplicateDeleteRequest,
        boundSnapshotIdentity: DeletionSnapshotIdentity? = nil
    ) -> Bool {
        let identity = boundSnapshotIdentity
            ?? request.prepared.plan.intent.snapshotIdentity
        switch DuplicateDeletionSubmissionGate.evaluate(
            requestSessionID: request.scanSessionID,
            requestRevision: request.scanRevision,
            boundSnapshotIdentity: identity,
            currentSessionID: scanSessionID,
            currentRevision: scanRevision,
            paths: request.paths
        ) {
        case .current:
            return true
        case .cancelled(let rejections):
            GSYLog.notice(
                .trash,
                "Duplicate rejected stale deletion intent revision=\(request.scanRevision) current=\(scanRevision)"
            )
            activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: rejections))
            return false
        }
    }

    private func cancelDuplicatePreflight() {
        duplicatePreflightTask?.cancel()
        duplicatePreflightTask = nil
        if duplicatePreflightGate.cancel() {
            isDeletingDuplicates = false
        }
    }

    private func executeDuplicateDeletion(_ submission: DuplicateConfirmedDeletion) {
        guard !isDeletingDuplicates,
              requireCurrentDuplicateRequest(submission.request) else { return }
        isDeletingDuplicates = true
        Task { @MainActor in
            defer { isDeletingDuplicates = false }
            guard requireCurrentDuplicateRequest(submission.request) else { return }
            let executionPlan = submission.executionPlan
            let coordinator = DeletionInteractionCoordinator(pipeline: pipeline)
            let authorization: DeletionAuthorizedInteraction
            switch coordinator.authorize(
                prepared: submission.request.prepared,
                executionPlan: executionPlan
            ) {
            case .authorized(let value):
                authorization = value
            case .cancelled:
                return
            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(
                    rejections: block.rejections
                ))
                return
            }
            guard requireCurrentDuplicateRequest(
                submission.request,
                boundSnapshotIdentity: authorization.authorization.snapshotIdentity
            ) else { return }
            let frozenEvidencePaths = incompleteEvidencePaths(in: authorization)
            guard frozenEvidencePaths.isSubset(of: submission.request.accessEvidencePaths) else {
                activeSheet = .preflightNotice(DeletionPreflightNotice(
                    rejections: authorization.authorization.paths.map {
                        .init(
                            path: $0,
                            reason: ScanIncompleteTargetRejectionReason
                                .missingTypedEvidence.rawValue
                        )
                    }
                ))
                return
            }
            let disposition = await coordinator.submit(
                authorization,
                accessDeniedPaths: frozenEvidencePaths
            )
            let completed: DeletionCompletedInteraction
            switch disposition {
            case .completed(let value):
                completed = value

            case .requiresConfirmation(let prepared):
                let strictPaths = Set(prepared.paths)
                let totalBytes = prepared.paths.reduce(Int64(0)) { partial, path in
                    let value = max(0, submission.request.bytesByPath[path] ?? 0)
                    let sum = partial.addingReportingOverflow(value)
                    return sum.overflow ? .max : sum.partialValue
                }
                activeSheet = .confirm(DuplicateDeleteRequest(
                    scanSessionID: submission.request.scanSessionID,
                    scanRevision: submission.request.scanRevision,
                    items: prepared.confirmationCandidates,
                    totalBytes: totalBytes,
                    bytesByPath: submission.request.bytesByPath.filter {
                        strictPaths.contains($0.key)
                    },
                    accessEvidencePaths: incompleteEvidencePaths(in: prepared),
                    prepared: prepared
                ))
                return

            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
                return
            }
            let result = completed.result
            let succeededPaths = result.succeededPaths
            if !succeededPaths.isEmpty {
                await pruneMovedDuplicatePaths(Set(succeededPaths))
            }
            activeSheet = .result(.deletion(completed))
        }
    }

    private func selectedBytes(paths: [String], in group: DuplicateGroup) -> Int64 {
        let selected = Set(paths)
        var total: Int64 = 0
        for file in group.files where selected.contains(file.path) {
            let sum = total.addingReportingOverflow(file.allocatedBytes)
            total = sum.overflow ? .max : sum.partialValue
        }
        return total
    }

    private func duplicateBytesByPath(
        paths: [String],
        in group: DuplicateGroup
    ) -> [String: Int64] {
        let selected = Set(paths)
        return Dictionary(uniqueKeysWithValues: group.files.lazy
            .filter { selected.contains($0.path) }
            .map { ($0.path, max(0, $0.allocatedBytes)) })
    }

    private func duplicateDeletionRows(
        paths: [String],
        bytesByPath: [String: Int64]
    ) -> [RowItem] {
        paths.map { path in
            RowItem(
                id: path,
                url: URL(fileURLWithPath: path),
                title: URL(fileURLWithPath: path).lastPathComponent,
                isDirectory: false,
                bytes: max(0, bytesByPath[path] ?? 0),
                logicalBytes: max(0, bytesByPath[path] ?? 0),
                fileCount: 1,
                verdict: .safe,
                rejection: .ok
            )
        }
    }

    private func incompleteIssues(overlappingAny paths: [String]) -> [ScanIncompleteIssue] {
        DuplicateDeletionPreparationPolicy.relevantIssues(
            overlappingAny: paths,
            in: scanIncompleteIssues
        )
    }

    private func deletionAccessEvidence(
        for path: String,
        issues: [ScanIncompleteIssue]
    ) -> DeletionAccessEvidence {
        DuplicateDeletionPreparationPolicy.accessEvidence(for: path, issues: issues)
    }

    private func incompleteEvidencePaths(
        in prepared: DeletionPreparedInteraction
    ) -> Set<String> {
        Set(prepared.scanIncompleteOverrideRequest?.entries
            .flatMap(\.incompleteIssues)
            .map(\.path) ?? [])
    }

    private func incompleteEvidencePaths(
        in authorized: DeletionAuthorizedInteraction
    ) -> Set<String> {
        Set(authorized.scanIncompleteOverrideRequest?.entries
            .flatMap(\.incompleteIssues)
            .map(\.path) ?? [])
    }

    private func recordIncompleteIssue(_ issue: ScanIncompleteIssue) {
        let normalized = ScanIncompleteIssue(
            path: URL(fileURLWithPath: issue.path).standardizedFileURL.path,
            reason: issue.reason,
            stage: issue.stage,
            posixErrorCode: issue.posixErrorCode
        )
        guard !scanIncompleteIssues.contains(normalized) else { return }
        scanIncompleteIssues.append(normalized)
    }

    @MainActor
    private func pruneMovedDuplicatePaths(_ moved: Set<String>) async {
        guard !moved.isEmpty else { return }
        let sourceGroups = groups
        let prunedGroups = await Task.detached(priority: .utility) {
            DuplicateHandlingPlan.pruning(sourceGroups, movedPaths: moved)
        }.value
        guard !Task.isCancelled else { return }
        groups = prunedGroups
        if let selectedGroupID, !prunedGroups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = prunedGroups.first?.id
        }
    }

    // MARK: - Scan driver

    private func startScan() {
        guard !isScanning,
              !roots.isEmpty,
              !isDeletionTransactionActive else { return }
        scanTask?.cancel()
        groups = []
        selectedGroupID = nil
        tccSkippedRoots = []
        scanIncompleteIssues = []
        scanRevision &+= 1
        let revision = scanRevision
        let sessionID = UUID()
        scanSessionID = sessionID
        bucketsDone = 0
        bucketsTotal = 0
        sizingFiles = 0
        phaseLabel = String(localized: "duplicate.phase.enumerate", bundle: .module)
        isScanning = true

        let scanner = DuplicateScanner(roots: roots, minBytes: minStep.bytes)
        scanTask = Task { @MainActor in
            for await event in scanner.scan() {
                if Task.isCancelled { break }
                guard scanSessionID == sessionID, scanRevision == revision else { break }
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
                    if !tccSkippedRoots.contains(path) {
                        tccSkippedRoots.append(path)
                    }
                    recordIncompleteIssue(ScanIncompleteIssue(
                        path: path,
                        reason: .tccProtectedSkipped
                    ))
                case .incomplete(let issue):
                    recordIncompleteIssue(issue)
                }
            }
            // 无论正常 finished 还是 cancel，退出循环时一并复位进度计数与标签，
            // 避免下次启动前 footer 闪显旧进度数字。
            if scanSessionID == sessionID, scanRevision == revision {
                isScanning = false
                phaseLabel = ""
                bucketsDone = 0
                bucketsTotal = 0
                sizingFiles = 0
            }
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
    @State private var manualSelectedBytes: Int64
    private let allocatedBytesByPath: [String: Int64]

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
        let defaultTargets = DuplicateHandlingPlan.defaultDeleteTargets(for: group)
        _manualTargets = State(initialValue: Set(defaultTargets))
        _manualSelectedBytes = State(initialValue: group.reclaimableBytes)
        var bytesByPath: [String: Int64] = [:]
        bytesByPath.reserveCapacity(group.files.count)
        for file in group.files {
            bytesByPath[file.path] = file.allocatedBytes
        }
        allocatedBytesByPath = bytesByPath
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
                            group.files.count,
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
                            URL(fileURLWithPath: group.files.first?.path ?? "").lastPathComponent))
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
            .disabled(isDeleting || group.files.count < 2)
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
                ForEach(group.files, id: \.path) { file in
                    Toggle(isOn: binding(for: file.path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(file.path)
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
                        ByteCountFormatter.string(
                            fromByteCount: manualSelectedBytes,
                            countStyle: .file
                        )))
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
            .disabled(isDeleting || manualTargets.isEmpty || manualTargets.count >= group.files.count)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { manualTargets.contains(path) },
            set: { newValue in
                if newValue {
                    if manualTargets.insert(path).inserted {
                        let bytes = allocatedBytesByPath[path] ?? 0
                        let sum = manualSelectedBytes.addingReportingOverflow(bytes)
                        manualSelectedBytes = sum.overflow ? .max : sum.partialValue
                    }
                } else if manualTargets.remove(path) != nil {
                    manualSelectedBytes = max(0, manualSelectedBytes - (allocatedBytesByPath[path] ?? 0))
                }
            }
        )
    }
}

enum DuplicateHandlingPlan {
    static func defaultDeleteTargets(for group: DuplicateGroup) -> [String] {
        group.files.dropFirst().map(\.path)
    }

    static func isValidDeleteTargets(_ paths: [String], for group: DuplicateGroup) -> Bool {
        let uniqueTargets = Set(paths)
        guard !uniqueTargets.isEmpty,
              uniqueTargets.count == paths.count,
              uniqueTargets.count < group.files.count else {
            return false
        }
        let allPaths = Set(group.files.map(\.path))
        return uniqueTargets.isSubset(of: allPaths)
    }

    /// 纯数据投影，调用方可安全放到 detached utility task，避免大重复集在主线程重聚合。
    static func pruning(_ groups: [DuplicateGroup], movedPaths: Set<String>) -> [DuplicateGroup] {
        guard !movedPaths.isEmpty else { return groups }
        return groups.compactMap { $0.removing(paths: movedPaths) }
    }
}
