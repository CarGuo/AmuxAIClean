import SwiftUI
import Foundation
import Darwin
import ScanKit
import LogKit
import SafetyKit

/// 工作流扫描结果既可能携带真实名称，也可能携带 String Catalog key。
/// 保留语义到 View 投影，避免扫描时把启动语言固化进长生命周期结果。
enum WorkflowHitNamePresentation {
    static func descriptor(_ value: String) -> LocalizedTextDescriptor {
        let separator = " · "
        let range = value.range(of: separator)
        let base = range.map { String(value[..<$0.lowerBound]) } ?? value
        let suffix = range.map { String(value[$0.lowerBound...]) } ?? ""
        // ScanKit's semantic display keys live in explicit namespaces; simulator names,
        // project names and filesystem names are user/source data and must remain verbatim.
        let isCatalogKey = base.hasPrefix("versioned-root.")
            || base.hasPrefix("rule.")
            || base.hasPrefix("workflow.")
        let descriptor: LocalizedTextDescriptor = isCatalogKey ? .catalog(base) : .verbatim(base)
        return descriptor.appendingVerbatim(suffix)
    }

    static func string(_ value: String, locale: Locale) -> String {
        descriptor(value).localized(locale: locale)
    }
}

/// ScanKit 只传 simctl 状态语义；这里按当前 App locale 投影，切换语言不需重扫。
enum WorkflowHitNotePresentation {
    static func string(_ hit: WorkflowScanHit, locale: Locale) -> String? {
        guard let note = hit.semanticNote else { return hit.note }
        switch note {
        case .verbatim(let value):
            return value
        case .simulatorDevice(let state, let runtimeIdentifier):
            let stateKey: String
            switch state {
            case .shutdown: stateKey = "workflow.simulator.state.shutdown"
            case .booted: stateKey = "workflow.simulator.state.booted"
            case .transitioning: stateKey = "workflow.simulator.state.transitioning"
            case .unknown: stateKey = "workflow.simulator.state.unknown"
            }
            return "\(AppLocalization.string(stateKey, locale: locale)) · \(runtimeIdentifier)"
        case .simulatorRuntime(let runtimeIdentifier, let isAvailable, let management):
            var components = [runtimeIdentifier]
            if !isAvailable {
                components.append(AppLocalization.string(
                    "workflow.simulator.runtime.unavailable",
                    locale: locale
                ))
            }
            switch management {
            case .uninstallable:
                break
            case .legacyReadOnly:
                components.append(AppLocalization.string(
                    "workflow.simulator.runtime.legacy_read_only",
                    locale: locale
                ))
            case .notDeletable:
                components.append(AppLocalization.string(
                    "workflow.simulator.runtime.not_deletable",
                    locale: locale
                ))
            }
            return components.joined(separator: " · ")
        }
    }
}

/// v1.7 M1 PR-5：开发者工作流详情视图（Apple / Android / WebNode 共用）。
///
/// 设计动机：
/// - PR-1～PR-4 把 Workflow / Card / Scanner / Registry 全部落在 ScanKit；
///   PR-5 在 AppUI 侧把它们渲染成一个可勾选 + 可触发动态扫描 + 可走 TrashPipeline 删除的视图。
/// - **不复用 ScanCoordinator**：ScanCoordinator 设计目标是单一活跃扫描；
///   工作流是"按卡片各扫各的"，模型彻底不同——自带 @StateObject ViewModel 隔离。
/// - **不动 batch.developer sentinel**：保留向后兼容（原 `triggerDeveloperScan` 走 DevArtifactScanner），
///   PR-5 在 sidebar 新增 Section "Developer Workflows" 单独承载 3 个 workflow sentinel。
///
/// 行为契约：
/// 1. 静态卡（.literal / .versionedRoot / .vendor）：进视图时同步计算 size + render row；
/// 2. 动态卡（.dynamicScanner）：进视图时按需 await WorkflowRegistry.resolve，loading 期展示骨架；
/// 3. filesystem 与 managed uninstall 是两个独立事务，按钮、确认、receipt 不混用；
/// 4. 只有 filesystem + safe 默认勾选，managed resource 必须由用户显式选择；
/// 5. filesystem 只走 [DeletionPipeline] → `NSWorkspace.recycle`；Simulator 资源只走
///    封闭的 [ManagedUninstallRecipe]，并在单一 sheet 中展示准备、复核、进度与终态。
public struct WorkflowDetailView: View {
    @Environment(\.locale) private var locale
    @StateObject private var viewModel: WorkflowDetailViewModel
    private let workflow: any DeveloperWorkflow
    private let pipeline: any DeletionPipeline

    public init(workflow: any DeveloperWorkflow,
                pipeline: any DeletionPipeline,
                undoHistoryStore: UndoHistoryStore,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.workflow = workflow
        self.pipeline = pipeline
        _viewModel = StateObject(wrappedValue: WorkflowDetailViewModel(
            workflow: workflow,
            home: home,
            // v2026.07.20 P0: the caller must provide the Undo owner together with its pipeline.
            // Production passes `.shared`; scripted callers must pass a temporary store, so a
            // compatibility pipeline can never commit synthetic moved pairs to user history.
            undoHistoryStore: undoHistoryStore
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.cards.isEmpty {
                emptyPlaceholder
            } else {
                cardList
            }
            Divider()
            footer
        }
        // v2026.07.20 P0: workflow cards and footer retain their layout and selection while the
        // shared non-modal callout explains why no Trash submission was created.
        .deletionPreflightNoticeOverlay(viewModel.preflightNotice) {
            viewModel.preflightNotice = nil
        }
        .task {
            await viewModel.bootstrap()
        }
        // v2026.07.16: SwiftUI owns the bootstrap `.task`, while button-triggered rescans
        // are owned by the ViewModel. Leaving this screen must cancel both lifetimes and
        // invalidate their revision before an old ViewModel can publish in the background.
        .onDisappear {
            viewModel.cancelVisibleScanWork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gsyTrashDidMove)) { notification in
            let source = notification.userInfo?["source"] as? String
            guard source != DeleteRequestOrigin.workflowFilesystem.historySource else { return }
            let paths = notification.userInfo?["paths"] as? [String] ?? []
            guard !paths.isEmpty else { return }
            viewModel.applyExternalDeletedPaths(paths)
        }
        .alert(viewModel.alertTitle ?? "",
               isPresented: Binding(get: { viewModel.alertMessage != nil },
                                    set: { if !$0 { viewModel.clearAlert() } })) {
            Button(AppLocalization.string("workflow.detail.alert.ok", locale: locale)) { viewModel.clearAlert() }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        // **v2026.07.15**：统一使用单一 ActiveSheet 路由。Trash 结果与 Simulator
        // managed uninstall 虽然共享 SwiftUI presentation slot，但状态与 receipt 完全分离；
        // managed 流程始终留在自己的 sheet 内，不会再先关闭后等待整页重扫。
        .sheet(
            item: $viewModel.activeSheet,
            onDismiss: runPendingDeleteAfterSheetDismissal
        ) { sheet in
            switch sheet {
            case .deleteConfirm(let confirmation):
                WorkflowDeleteConfirmSheetContent(
                    confirmation: confirmation,
                    onCancel: { viewModel.cancelDeleteConfirmation() },
                    onConfirm: { executionPlan in
                        viewModel.confirmDelete(
                            confirmation,
                            executionPlan: executionPlan
                        )
                    }
                )
            case .simulatorUninstall:
                simulatorUninstallSheet
                    // 系统管理卸载准备/执行期间必须保留进度和终态。执行开始后不能用
                    // Esc 丢掉状态；确认前和终态由 sheet 内显式按钮关闭。
                    .interactiveDismissDisabled(viewModel.isSimulatorUninstallDismissBlocked)
            case .result(let completion):
                OperationResultSheet(completion: completion) {
                    viewModel.activeSheet = nil
                }
            }
        }
    }

    @ViewBuilder
    private var simulatorUninstallSheet: some View {
        Group {
            if let state = viewModel.simulatorUninstallState {
                SimulatorManagedUninstallSheetContent(
                    state: state,
                    locale: locale,
                    onCancel: { viewModel.cancelSimulatorUninstall() },
                    onConfirm: { Task { await viewModel.executeSimulatorUninstall() } },
                    onStop: { Task { await viewModel.requestSimulatorUninstallStop() } },
                    onDone: { viewModel.finishSimulatorUninstallPresentation() }
                )
            } else {
                EmptyView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(workflow.displayName), bundle: .module)
                .font(.title2.bold())
            Text(LocalizedStringKey(workflow.subtitle), bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("workflow.detail.empty_placeholder", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardList: some View {
        List {
            ForEach(viewModel.cards) { card in
                workflowCardRow(card)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func workflowCardRow(_ card: DeveloperCard) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { viewModel.expanded.contains(card.id) },
            set: { isOpen in viewModel.toggleExpanded(cardID: card.id, open: isOpen) }
        )) {
            cardBody(card)
        } label: {
            cardLabel(card)
        }
    }

    private func cardLabel(_ card: DeveloperCard) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: card.risk))
                .foregroundStyle(color(for: card.risk))
                .frame(width: 18)
                // v2026.06 用户反馈 #3：三个橙色/绿色/红色 logo 此前没有任何提示，
                // 用户不知道 .safe / .confirm / .blocked 三档分别是什么意思。
                // 加 .help() tooltip，鼠标 hover 即可看到一句话解释每档清理风险。
                .help(Text(riskTooltipKey(for: card.risk), bundle: .module))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(card.title), bundle: .module)
                    .font(.system(.body, design: .rounded))
                Text(LocalizedStringKey(card.summary), bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            // **v2026.07.15 根因修复**：命中数、已知字节和完整性是三个独立维度。
            // 未知大小不能再 reduce 成 0 KB，simctl 失败也不能伪装成“暂未发现”。
            cardCapacityBadge(cardID: card.id)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cardBody(_ card: DeveloperCard) -> some View {
        let hits = viewModel.cardHits[card.id] ?? []
        if viewModel.cardScanPhase(for: card.id) == .pending {
            HStack {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                Text("workflow.detail.waiting_to_scan", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 28)
            .padding(.vertical, 6)
        } else if viewModel.cardScanPhase(for: card.id) == .scanning {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Group {
                    if let progress = viewModel.cardScanProgress[card.id] {
                        Text(AppLocalization.format(
                            "workflow.detail.scan_progress",
                            locale: locale,
                            arguments: [
                                Int64(progress.fileCount),
                                AppLocalization.byteCount(progress.scannedBytes, locale: locale)
                            ]
                        ))
                        .help(progress.currentPath ?? "")
                    } else {
                        Text("workflow.detail.scanning", bundle: .module)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 28)
            .padding(.vertical, 6)
        } else if viewModel.cardScanPhase(for: card.id) == .cancelled {
            HStack(spacing: 10) {
                Label {
                    Text("workflow.detail.scan_cancelled", bundle: .module)
                } icon: {
                    Image(systemName: "pause.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.startCardRefresh(cardID: card.id)
                } label: {
                    Text("workflow.detail.action.retry", bundle: .module)
                }
                .controlSize(.small)
            }
            .padding(.leading, 28)
            .padding(.vertical, 6)
        } else if viewModel.cardCapacityState(for: card.id) == .failed {
            HStack(spacing: 10) {
                Label {
                    Text("workflow.detail.scan_failed", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                Spacer()
                Button {
                    viewModel.startCardRefresh(cardID: card.id)
                } label: {
                    Text("workflow.detail.action.retry", bundle: .module)
                }
                .controlSize(.small)
            }
            .padding(.leading, 28)
            .padding(.vertical, 6)
        } else if hits.isEmpty {
            Text("workflow.detail.empty_card", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.vertical, 6)
        } else {
            if viewModel.cardHasIncompleteEvidence(cardID: card.id) {
                Label {
                    Text("workflow.detail.partial_scan", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.leading, 28)
                .padding(.vertical, 3)
            }
            ForEach(hits) { hit in
                hitRow(card: card, hit: hit)
            }
        }
    }

    private func hitRow(card: DeveloperCard, hit: WorkflowScanHit) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.selected.contains(hit.id) },
                set: { isOn in viewModel.toggleSelection(hitID: hit.id, on: isOn) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!viewModel.canSelect(card: card, hit: hit))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: WorkflowHitNamePresentation.string(hit.displayName, locale: locale))
                    .font(.system(.body))
                if let note = WorkflowHitNotePresentation.string(hit, locale: locale) {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let size = hit.sizeBytes {
                Text(WorkflowDetailViewModel.formatBytes(size, locale: locale))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 28)
        .padding(.vertical, 3)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(verbatim: viewModel.selectionSummary(locale: locale))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                viewModel.startFullRefresh()
            } label: {
                Label {
                    Text("workflow.detail.action.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isAnyLoading || viewModel.isDeletionTransactionActive)

            if viewModel.selectedFilesystemCount > 0 {
                Button(role: .destructive) {
                    Task { await viewModel.requestDeleteConfirmation(pipeline: pipeline) }
                } label: {
                    Label {
                        Text("workflow.detail.action.trash", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(
                    viewModel.isAnyLoading
                        || viewModel.isDeletionTransactionActive
                )
            }
            if viewModel.selectedManagedUninstallCount > 0 {
                Button(role: .destructive) {
                    Task { await viewModel.requestSimulatorUninstall() }
                } label: {
                    Label {
                        Text(viewModel.managedUninstallActionKey, bundle: .module)
                    } icon: {
                        Image(systemName: "externaldrive.badge.minus")
                    }
                }
                // 与 Trash 完全分离：其它无关卡仍在扫描时，已冻结的 managed hits
                // 仍可立即进入自己的进度 sheet，不再被全页 isAnyLoading 阻塞。
                .disabled(viewModel.isDeletionTransactionActive)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func cardCapacityBadge(cardID: String) -> some View {
        switch viewModel.cardCapacityState(for: cardID) {
        case .pending:
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .loading:
            ProgressView().controlSize(.small)
        case .cancelled:
            capacityChip(
                AppLocalization.string("workflow.card.scan_cancelled", locale: locale),
                color: .secondary
            )
        case .empty:
            capacityChip(
                AppLocalization.string("workflow.card.empty_chip", locale: locale),
                color: .secondary
            )
        case .known(let bytes):
            Text(WorkflowDetailViewModel.formatBytes(bytes, locale: locale))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        case .partialUnknown(let knownBytes):
            capacityChip(
                AppLocalization.format(
                    "workflow.card.partial_size %@",
                    locale: locale,
                    arguments: [WorkflowDetailViewModel.formatBytes(knownBytes, locale: locale)]
                ),
                color: .orange
            )
        case .allUnknown:
            capacityChip(
                AppLocalization.string("workflow.card.size_unknown", locale: locale),
                color: .orange
            )
        case .failed:
            capacityChip(
                AppLocalization.string("workflow.card.scan_failed", locale: locale),
                color: .orange
            )
        }
    }

    private func capacityChip(_ title: String, color: Color) -> some View {
        Text(verbatim: title)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.10))
            )
    }

    private func runPendingDeleteAfterSheetDismissal() {
        guard let intent = viewModel.takePendingConfirmedDeleteIntent() else { return }
        Task { await viewModel.performDelete(pipeline: pipeline, intent: intent) }
    }

    private func iconName(for risk: DeveloperCard.Risk) -> String {
        switch risk {
        case .safe:    return "checkmark.shield"
        case .confirm: return "exclamationmark.shield"
        case .blocked: return "lock.shield"
        }
    }

    private func color(for risk: DeveloperCard.Risk) -> Color {
        switch risk {
        case .safe:    return .green
        case .confirm: return .orange
        case .blocked: return .red
        }
    }

    /// v2026.06 用户反馈 #3：风险盾牌 logo tooltip 文案 key。
    /// 三档对应：
    /// - .safe（绿）：可放心一键清理；
    /// - .confirm（橙）：需用户确认，可能影响下次构建/启动；
    /// - .blocked（红）：禁止直接删除（如 Simulator 运行中、命令行通道要走 simctl）。
    private func riskTooltipKey(for risk: DeveloperCard.Risk) -> LocalizedStringKey {
        switch risk {
        case .safe:    return "workflow.risk.tooltip.safe"
        case .confirm: return "workflow.risk.tooltip.confirm"
        case .blocked: return "workflow.risk.tooltip.blocked"
        }
    }
}

/// Completeness evidence owned by one Workflow scan session.
///
/// `permissionDeniedPaths` and `partialPaths` remain UI projections. Deletion consumes
/// `incompleteIssues`, which preserves the typed reason and is scoped to selected targets;
/// one incomplete sibling must never become a global access-denied switch.
public struct WorkflowScanEvidence: Sendable, Equatable {
    public let revision: UInt64
    public let sessionID: UUID
    public let permissionDeniedPaths: Set<String>
    public let partialPaths: Set<String>
    public let incompleteIssues: [ScanIncompleteIssue]

    public init(revision: UInt64,
                sessionID: UUID = UUID(),
                permissionDeniedPaths: Set<String> = [],
                partialPaths: Set<String> = []) {
        self.revision = revision
        self.sessionID = sessionID
        let permission = Set(permissionDeniedPaths.map(Self.normalizePath))
        let partial = Set(partialPaths.map(Self.normalizePath)).union(permission)
        self.permissionDeniedPaths = permission
        self.partialPaths = partial
        self.incompleteIssues = permission.sorted().map {
            ScanIncompleteIssue(path: $0, reason: .permissionDenied)
        } + partial.subtracting(permission).sorted().map {
            ScanIncompleteIssue(path: $0, reason: .enumerationFailed)
        }
    }

    init(revision: UInt64,
         sessionID: UUID = UUID(),
         incompleteIssues: [ScanIncompleteIssue]) {
        self.revision = revision
        self.sessionID = sessionID
        var seen = Set<ScanIncompleteIssue>()
        self.incompleteIssues = incompleteIssues.compactMap { issue in
            let normalized = ScanIncompleteIssue(
                path: Self.normalizePath(issue.path),
                reason: issue.reason,
                stage: issue.stage,
                posixErrorCode: issue.posixErrorCode
            )
            return seen.insert(normalized).inserted ? normalized : nil
        }
        self.permissionDeniedPaths = Set(self.incompleteIssues.compactMap { issue in
            switch issue.reason {
            case .permissionDenied, .tccProtectedSkipped: issue.path
            case .enumerationFailed, .metadataUnavailable: nil
            }
        })
        self.partialPaths = Set(self.incompleteIssues.map(\.path))
    }

    func issues(overlappingAny paths: [String]) -> [ScanIncompleteIssue] {
        var seen = Set<ScanIncompleteIssue>()
        return paths.flatMap { path in
            DeletionTargetRevalidator.relevantIssues(for: path, from: incompleteIssues)
        }.filter { seen.insert($0).inserted }
    }

    func accessEvidence(for path: String) -> DeletionAccessEvidence {
        guard let issue = DeletionTargetRevalidator.relevantIssues(
            for: path,
            from: incompleteIssues
        ).first else {
            return .complete
        }
        return .incomplete(DeletionIncompleteReason(scanIncompleteReason: issue.reason))
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Immutable destructive intent produced from one Workflow scan revision.
///
/// Confirmation and execution consume this value instead of re-reading mutable
/// `cards`, `cardHits`, or `selected` state. The filesystem hit map is frozen so
/// successful recycle outcomes can be projected back to row IDs without consulting a
/// newer scan. System-managed Simulator resources use a separate typed intent below and
/// can never be appended to this Trash intent.
public struct WorkflowDeletionIntent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scanRevision: UInt64
    public let scanSessionID: UUID
    public let selectedHitIDs: Set<String>
    public let filesystemPaths: [String]
    public let filesystemHitIDsByPath: [String: Set<String>]
    public let filesystemCandidates: [RunningAppGuard.Candidate]
    public let accessDeniedPaths: Set<String>
    public let vendorOverrideRequest: VendorPathOverrideRequest?
    let preparedInteraction: DeletionPreparedInteraction?
    let authorizedInteraction: DeletionAuthorizedInteraction?
    public let runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    public let itemCount: Int
    public let totalBytes: Int64

    public init(id: UUID = UUID(),
                scanRevision: UInt64,
                scanSessionID: UUID = UUID(),
                selectedHitIDs: Set<String>,
                filesystemPaths: [String],
                filesystemHitIDsByPath: [String: Set<String>],
                filesystemCandidates: [RunningAppGuard.Candidate],
                accessDeniedPaths: Set<String>,
                vendorOverrideRequest: VendorPathOverrideRequest? = nil,
                runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem] = [],
                itemCount: Int,
                totalBytes: Int64) {
        self.id = id
        self.scanRevision = scanRevision
        self.scanSessionID = scanSessionID
        self.selectedHitIDs = selectedHitIDs
        self.filesystemPaths = filesystemPaths
        self.filesystemHitIDsByPath = filesystemHitIDsByPath
        self.filesystemCandidates = filesystemCandidates
        self.accessDeniedPaths = accessDeniedPaths
        self.vendorOverrideRequest = vendorOverrideRequest
        self.preparedInteraction = nil
        self.authorizedInteraction = nil
        self.runningAppSkipped = runningAppSkipped
        self.itemCount = itemCount
        self.totalBytes = totalBytes
    }

    init(id: UUID = UUID(),
         scanRevision: UInt64,
         scanSessionID: UUID,
         selectedHitIDs: Set<String>,
         filesystemPaths: [String],
         filesystemHitIDsByPath: [String: Set<String>],
         filesystemCandidates: [RunningAppGuard.Candidate],
         accessDeniedPaths: Set<String>,
         preparedInteraction: DeletionPreparedInteraction?,
         authorizedInteraction: DeletionAuthorizedInteraction?,
         runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem] = [],
         itemCount: Int,
         totalBytes: Int64) {
        self.id = id
        self.scanRevision = scanRevision
        self.scanSessionID = scanSessionID
        self.selectedHitIDs = selectedHitIDs
        self.filesystemPaths = filesystemPaths
        self.filesystemHitIDsByPath = filesystemHitIDsByPath
        self.filesystemCandidates = filesystemCandidates
        self.accessDeniedPaths = accessDeniedPaths
        self.vendorOverrideRequest = preparedInteraction?.vendorOverrideRequest
        self.preparedInteraction = preparedInteraction
        self.authorizedInteraction = authorizedInteraction
        self.runningAppSkipped = runningAppSkipped
        self.itemCount = itemCount
        self.totalBytes = totalBytes
    }
}

public struct WorkflowDeleteConfirmation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let intent: WorkflowDeletionIntent

    public var selectedIDs: Set<String> { intent.selectedHitIDs }
    public var itemCount: Int { intent.itemCount }
    public var totalBytes: Int64 { intent.totalBytes }

    public init(id: UUID = UUID(), intent: WorkflowDeletionIntent) {
        self.id = id
        self.intent = intent
    }
}

private struct WorkflowDeleteConfirmSheetContent: View {
    @Environment(\.locale) private var locale
    let confirmation: WorkflowDeleteConfirmation
    let onCancel: () -> Void
    let onConfirm: (ToolTrashExecutionPlan) -> Bool

    @ViewBuilder
    var body: some View {
        if confirmation.intent.filesystemPaths.isEmpty {
            commandOnlyConfirmation
        } else {
            ToolTrashConfirmationSheet(
                items: confirmation.intent.filesystemCandidates,
                totalBytes: confirmation.totalBytes,
                vendorOverrideRequest: confirmation.intent.preparedInteraction?.vendorOverrideRequest
                    ?? confirmation.intent.vendorOverrideRequest,
                scanIncompleteOverrideRequest: confirmation.intent.preparedInteraction?.scanIncompleteOverrideRequest,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        }
    }

    private var commandOnlyConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text("workflow.detail.delete_confirm.title", bundle: .module)
                    .font(.title3.bold())
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(.orange)
            }
            Text(String(
                format: AppLocalization.string("workflow.detail.delete_confirm.message %lld %@", locale: locale),
                confirmation.itemCount,
                WorkflowDetailViewModel.formatBytes(confirmation.totalBytes, locale: locale)
            ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(AppLocalization.string("delete.action.cancel", locale: locale), role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(AppLocalization.string("workflow.detail.delete_confirm.action", locale: locale), role: .destructive) {
                    _ = onConfirm(ToolTrashExecutionPlan(
                        paths: confirmation.intent.filesystemPaths,
                        runningAppSkipped: [],
                        vendorOverrideRequest: confirmation.intent.vendorOverrideRequest
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520)
    }
}

/// v2026.07.15：Simulator 系统管理卸载的单一状态 sheet。
///
/// 旧流程把 managed operation 混进“移到废纸篓”，随后关闭弹框、后台等待整页重扫，
/// 几分钟后才弹 raw simctl 二次确认。这里把准备、复核、不可撤销确认、逐项执行和终态
/// 收敛到一个稳定 sheet；用户在任何耗时阶段都能看到当前项与真实进度。
struct SimulatorManagedUninstallSheetContent: View {
    let state: WorkflowDetailViewModel.SimulatorUninstallState
    /// Sheet 是独立 AppKit presentation host。显式传入发起视图的 locale，避免
    /// presentation 创建时捕获进程默认语言后整张复核页都停留在旧语言。
    let locale: Locale
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onStop: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            content
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 620, height: 540)
    }

    @ViewBuilder
    private var header: some View {
        switch state {
        case .preparing:
            headerRow(
                icon: nil,
                color: .blue,
                titleKey: "workflow.detail.managed_uninstall.preparing.title",
                subtitleKey: "workflow.detail.managed_uninstall.preparing.subtitle",
                showsSpinner: true
            )
        case .review:
            headerRow(
                icon: "shippingbox",
                color: .orange,
                titleKey: "workflow.detail.managed_uninstall.review.title",
                subtitleKey: "workflow.detail.managed_uninstall.review.subtitle"
            )
        case .executing:
            headerRow(
                icon: nil,
                color: .blue,
                titleKey: "workflow.detail.managed_uninstall.executing.title",
                subtitleKey: "workflow.detail.managed_uninstall.executing.subtitle",
                showsSpinner: true
            )
        case .finished(_, let completion):
            let failed = completion.failedCount
            let succeeded = completion.succeededCount
            let unknown = completion.unknownCount
            let skipped = completion.skippedItems.count
            let isCompleteSuccess = failed == 0 && unknown == 0 && skipped == 0
            let isCompleteFailure = succeeded == 0 && failed > 0 && unknown == 0 && skipped == 0
            headerRow(
                icon: isCompleteSuccess ? "checkmark.circle.fill" : (isCompleteFailure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"),
                color: isCompleteSuccess ? .green : (isCompleteFailure ? .red : .orange),
                titleKey: isCompleteSuccess
                    ? "workflow.detail.managed_uninstall.finished.success.title"
                    : (isCompleteFailure
                       ? "workflow.detail.managed_uninstall.finished.failed.title"
                       : "workflow.detail.managed_uninstall.finished.partial.title"),
                subtitleKey: "workflow.detail.managed_uninstall.finished.subtitle"
            )
        case .blocked:
            headerRow(
                icon: "lock.shield.fill",
                color: .orange,
                titleKey: "workflow.detail.managed_uninstall.blocked.title",
                subtitleKey: "workflow.detail.managed_uninstall.blocked.subtitle"
            )
        }
    }

    private func headerRow(icon: String?,
                           color: Color,
                           titleKey: String,
                           subtitleKey: String,
                           showsSpinner: Bool = false) -> some View {
        HStack(spacing: 12) {
            if showsSpinner {
                ProgressView().controlSize(.regular)
            } else if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string(titleKey, locale: locale)).font(.title3.bold())
                Text(AppLocalization.string(subtitleKey, locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .preparing(_, let itemCount):
            VStack(alignment: .leading, spacing: 14) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(AppLocalization.format(
                    "workflow.detail.managed_uninstall.preparing.count %lld",
                    locale: locale,
                    arguments: [itemCount]
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        case .review(let intent):
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    consequenceText(for: intent)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                itemList(intent.items.map { .init(item: $0, status: .pending) })
            }
        case .executing(_, let progress):
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: Double(progress.completedCount), total: Double(max(1, progress.totalCount)))
                HStack {
                    Text(AppLocalization.format(
                        "workflow.detail.managed_uninstall.progress %lld %lld",
                        locale: locale,
                        arguments: [progress.currentIndex, progress.totalCount]
                    ))
                    .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(progress.completedCount) / \(progress.totalCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if progress.stopRequested {
                    Text(AppLocalization.string("workflow.detail.managed_uninstall.stop_pending", locale: locale))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                itemList(progress.rows)
            }
        case .finished(let intent, let completion):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    resultTile(
                        titleKey: "workflow.detail.managed_uninstall.result.succeeded",
                        count: completion.succeededCount,
                        color: .green
                    )
                    resultTile(
                        titleKey: "workflow.detail.managed_uninstall.result.failed",
                        count: completion.failedCount,
                        color: .red
                    )
                    resultTile(
                        titleKey: "workflow.detail.managed_uninstall.result.unknown",
                        count: completion.unknownCount,
                        color: .orange
                    )
                    resultTile(
                        titleKey: "workflow.detail.managed_uninstall.result.skipped",
                        count: completion.skippedItems.count,
                        color: .orange
                    )
                }
                let rows = intent.items.map { item -> WorkflowDetailViewModel.SimulatorUninstallItemProgress in
                    let outcome = completion.outcomes.first { $0.item.hitID == item.hitID }
                    let wasSkipped = completion.skippedItems.contains { $0.hitID == item.hitID }
                    return .init(
                        item: item,
                        status: WorkflowDetailViewModel.simulatorFinishedStatus(
                            outcome: outcome,
                            wasSkipped: wasSkipped,
                            interruptionReason: completion.interruptionReason
                        )
                    )
                }
                if let reason = completion.interruptionReason {
                    Label {
                        Text(interruptionMessage(reason))
                    } icon: {
                        Image(systemName: "info.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                itemList(rows)
            }
        case .blocked(_, let reason):
            VStack(alignment: .leading, spacing: 12) {
                Text(reason.localizedMessage(locale: locale))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if case .simulatorRunning(let names) = reason, !names.isEmpty {
                    Text(names.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func consequenceText(for intent: WorkflowDetailViewModel.SimulatorUninstallIntent) -> some View {
        Text(AppLocalization.string(intent.consequenceKey, locale: locale))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func itemList(_ rows: [WorkflowDetailViewModel.SimulatorUninstallItemProgress]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        statusIcon(for: row.status)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.item.displayName)
                                .font(.system(.callout, design: .rounded))
                            HStack(spacing: 6) {
                                Text(AppLocalization.string(
                                    row.item.kind == .simulatorRuntime
                                        ? "workflow.detail.managed_uninstall.kind.runtime"
                                        : "workflow.detail.managed_uninstall.kind.device",
                                    locale: locale
                                ))
                                if let size = row.item.sizeBytes {
                                    Text(verbatim: "· \(WorkflowDetailViewModel.formatBytes(size, locale: locale))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let detail = statusDetail(row.status), !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(statusDetailColor(row.status))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(minHeight: 150, maxHeight: 300)
    }

    @ViewBuilder
    private func statusIcon(for status: WorkflowDetailViewModel.SimulatorUninstallItemStatus) -> some View {
        switch status {
        case .pending:
            // v2026.07.15：空心圆外观等同 radio/checkbox，却不是可交互选择控件。
            // 使用等待图标并补齐说明，明确这是“已进入队列、尚未执行”的资源状态。
            Image(systemName: "hourglass")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(
                    Text(AppLocalization.string(
                        "workflow.detail.managed_uninstall.status.pending",
                        locale: locale
                    ))
                )
                .help(
                    Text(AppLocalization.string(
                        "workflow.detail.managed_uninstall.status.pending",
                        locale: locale
                    ))
                )
        case .validating:
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.blue)
                .help(Text(AppLocalization.string(
                    "workflow.detail.managed_uninstall.status.validating",
                    locale: locale
                )))
        case .submitted:
            Image(systemName: "paperplane.circle.fill")
                .foregroundStyle(.blue)
                .help(Text(AppLocalization.string(
                    "workflow.detail.managed_uninstall.status.submitted",
                    locale: locale
                )))
        case .running:
            ProgressView().controlSize(.small)
                .help(Text(AppLocalization.string(
                    "workflow.detail.managed_uninstall.status.running",
                    locale: locale
                )))
        case .stalled:
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .blockedSimulatorRunning:
            Image(systemName: "lock.circle.fill").foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        }
    }

    private func statusDetail(
        _ status: WorkflowDetailViewModel.SimulatorUninstallItemStatus
    ) -> String? {
        switch status {
        case .stalled(let elapsed):
            return AppLocalization.format(
                "workflow.detail.managed_uninstall.status.stalled %lld",
                locale: locale,
                arguments: [Int64(elapsed.rounded(.down))]
            )
        case .failed(let exitCode, let reason):
            return managedUninstallFailureDetail(
                reason: reason,
                exitCode: exitCode
            )
        case .unknown:
            return AppLocalization.string(
                "workflow.detail.managed_uninstall.status.unknown",
                locale: locale
            )
        case .blockedSimulatorRunning:
            return AppLocalization.string(
                "workflow.detail.managed_uninstall.status.blocked_simulator_running",
                locale: locale
            )
        case .pending, .validating, .submitted, .running, .succeeded, .skipped:
            return nil
        }
    }

    /// v2026.07.16：simctl 原始 stdout/stderr 只进日志。用户详情从 typed reason 在当前
    /// locale 下实时投影，切换语言不需要重启，也不会泄露 CLI/path/errno 文本。
    private func managedUninstallFailureDetail(
        reason: SimulatorDeleteCoordinator.Outcome.FailureReason?,
        exitCode: Int32
    ) -> String {
        let key: String
        switch reason {
        case .commandRejected:
            key = "workflow.detail.managed_uninstall.failure.command_rejected"
        case .processLaunchFailed:
            key = "workflow.detail.managed_uninstall.failure.launch_failed"
        case .commandFailed:
            return AppLocalization.format(
                "workflow.detail.managed_uninstall.failure.command_failed %lld",
                locale: locale,
                arguments: [Int64(exitCode)]
            )
        case .simulatorOrDeviceActive:
            key = "workflow.detail.managed_uninstall.status.blocked_simulator_running"
        case .safetyVerificationUnavailable:
            key = "workflow.detail.managed_uninstall.failure.safety_unavailable"
        case .duplicatePendingOperation:
            key = "workflow.detail.managed_uninstall.failure.pending_operation"
        case .persistentPendingOperation:
            key = "workflow.detail.managed_uninstall.failure.persistent_pending"
        case .resourceAlreadyAbsent:
            key = "workflow.detail.managed_uninstall.failure.resource_absent"
        case .observationEndedWithoutTerminal:
            key = "workflow.detail.managed_uninstall.status.unknown"
        case .none:
            key = "workflow.detail.managed_uninstall.failure.generic"
        }
        return AppLocalization.string(key, locale: locale)
    }

    private func statusDetailColor(
        _ status: WorkflowDetailViewModel.SimulatorUninstallItemStatus
    ) -> Color {
        if case .failed = status { return .red }
        return .orange
    }

    private func interruptionMessage(
        _ reason: SimulatorDeleteCoordinator.ManagedExecutionCompletion.InterruptionReason
    ) -> String {
        let key: String
        switch reason {
        case .stopRequested:
            key = "workflow.detail.managed_uninstall.interruption.stop_requested"
        case .simulatorStarted:
            key = "workflow.detail.managed_uninstall.interruption.simulator_started"
        case .currentItemStatusUnknown:
            key = "workflow.detail.managed_uninstall.interruption.status_unknown"
        }
        return AppLocalization.string(key, locale: locale)
    }

    private func resultTile(titleKey: String, count: Int, color: Color) -> some View {
        VStack(spacing: 5) {
            Text("\(count)").font(.title3.monospacedDigit().bold())
            Text(AppLocalization.string(titleKey, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(count > 0 ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch state {
            case .preparing, .review:
                Button(role: .cancel, action: onCancel) {
                    Text(AppLocalization.string("workflow.detail.managed_uninstall.cancel", locale: locale))
                }
                .keyboardShortcut(.cancelAction)
            case .executing(_, let progress):
                Button(action: onStop) {
                    Text(AppLocalization.string("workflow.detail.managed_uninstall.stop", locale: locale))
                }
                .disabled(progress.stopRequested || progress.currentIndex == 0)
            case .finished, .blocked:
                EmptyView()
            }
            Spacer()
            switch state {
            case .review(let intent):
                Button(role: .destructive, action: onConfirm) {
                    Text(AppLocalization.string(intent.confirmActionKey, locale: locale))
                }
                .keyboardShortcut(.defaultAction)
            case .finished, .blocked:
                Button(action: onDone) {
                    Text(AppLocalization.string("workflow.detail.managed_uninstall.done", locale: locale))
                }
                .keyboardShortcut(.defaultAction)
            case .preparing, .executing:
                EmptyView()
            }
        }
    }
}

/// PR-5：WorkflowDetailView 专用 ViewModel。
///
/// 与 ScanCoordinator 隔离的理由：
/// - 工作流的扫描模型是"按卡多源并发"，而 ScanCoordinator 是"单源 BulkScanner 串行"；
/// - 工作流的 row 是 WorkflowScanHit（DTO），ScanCoordinator 是 RowItem（带 SafetyVerdict 等繁复字段）；
/// - 强行复用反而把 ScanCoordinator 弄复杂，独立 VM 更清晰。
@MainActor
public final class WorkflowDetailViewModel: ObservableObject {
    /// 卡片容量的用户可见状态。`partialUnknown` 的字节只是已知下界；`allUnknown`
    /// 与完整空结果完全不同；`failed` 表示没有可信终态。
    public enum CardCapacityState: Sendable, Equatable {
        case pending
        case loading
        case empty
        case known(bytes: Int64)
        case partialUnknown(knownBytes: Int64)
        case allUnknown
        case failed
        case cancelled
    }

    /// One explicit state machine per card. Pending is intentionally distinct from an empty
    /// completed scan so queued work can never render as "nothing found".
    public enum CardScanPhase: Sendable, Equatable {
        case pending
        case scanning
        case completed
        case partial
        case failed
        case cancelled
    }

    /// Real absolute progress for one card's current scan owner. Counts come from ScanKit's
    /// allocation pass; there is no timer-derived percentage or guessed denominator.
    public struct CardScanProgress: Sendable, Equatable {
        public let scannedBytes: Int64
        public let fileCount: Int
        public let currentPath: String?

        public init(scannedBytes: Int64, fileCount: Int, currentPath: String?) {
            self.scannedBytes = max(0, scannedBytes)
            self.fileCount = max(0, fileCount)
            self.currentPath = currentPath
        }
    }

    public enum SelectionCapacityState: Sendable, Equatable {
        case known(itemCount: Int, bytes: Int64)
        case partialUnknown(itemCount: Int, knownBytes: Int64)
        case allUnknown(itemCount: Int)
    }

    @Published public private(set) var cards: [DeveloperCard] = []
    @Published public private(set) var cardHits: [String: [WorkflowScanHit]] = [:]
    @Published public private(set) var cardTotalBytes: [String: Int64] = [:]
    @Published public private(set) var cardIncompleteIssues: [String: [ScanIncompleteIssue]] = [:]
    @Published public private(set) var cardScanPhases: [String: CardScanPhase] = [:]
    @Published public private(set) var cardScanProgress: [String: CardScanProgress] = [:]
    @Published public var expanded: Set<String> = []
    @Published public private(set) var selected: Set<String> = []
    @Published public private(set) var scanEvidence = WorkflowScanEvidence(revision: 0)
    @Published public private(set) var isDeleting: Bool = false
    @Published public private(set) var isPreparingDeletion: Bool = false
    @Published public private(set) var alertTitle: String?
    @Published public private(set) var alertMessage: String?

    /// 单一 sheet 路由。Trash 与 managed uninstall 是两种独立事务，但共享一个
    /// SwiftUI presentation slot，避免多个 `.sheet` 竞争。
    @Published var activeSheet: ActiveSheet?
    /// v2026.07.20: rejected pre-submit evidence is non-modal page state and never
    /// participates in the active transaction/sheet route.
    @Published var preflightNotice: DeletionPreflightNotice?

    /// 当前正在显示的 sheet 类型。
    /// - `.simulatorUninstall`：Simulator 系统管理卸载的完整状态 sheet
    /// - `.result(payload)`：OperationResultSheet（trash 完成后展示结构化结果）
    enum ActiveSheet: Identifiable, Equatable {
        case deleteConfirm(WorkflowDeleteConfirmation)
        case simulatorUninstall
        case result(OperationResultCompletion)

        public var id: String {
            switch self {
            case .deleteConfirm(let confirmation):
                return "deleteConfirm-\(confirmation.id.uuidString)"
            case .simulatorUninstall: return "simulatorUninstall"
            case .result(let p): return "result-\(p.id.uuidString)"
            }
        }

        public static func == (lhs: ActiveSheet, rhs: ActiveSheet) -> Bool {
            lhs.id == rhs.id
        }
    }

    public struct SimulatorUninstallIntent: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let scanRevision: UInt64
        public let scanSessionID: UUID
        public let selectedHitIDs: Set<String>
        public let items: [SimulatorDeleteCoordinator.Item]
        public let totalBytes: Int64

        public init(id: UUID = UUID(),
                    scanRevision: UInt64,
                    scanSessionID: UUID,
                    selectedHitIDs: Set<String>,
                    items: [SimulatorDeleteCoordinator.Item],
                    totalBytes: Int64) {
            self.id = id
            self.scanRevision = scanRevision
            self.scanSessionID = scanSessionID
            self.selectedHitIDs = selectedHitIDs
            self.items = items
            self.totalBytes = totalBytes
        }

        private var kinds: Set<ManagedUninstallRecipe> { Set(items.map(\.kind)) }

        var consequenceKey: String {
            if kinds == [.simulatorRuntime] {
                return "workflow.detail.managed_uninstall.consequence.runtimes"
            }
            if kinds == [.simulatorDevice] {
                return "workflow.detail.managed_uninstall.consequence.devices"
            }
            return "workflow.detail.managed_uninstall.consequence.mixed"
        }

        var confirmActionKey: String {
            if kinds == [.simulatorRuntime] {
                return "workflow.detail.managed_uninstall.confirm.runtimes"
            }
            if kinds == [.simulatorDevice] {
                return "workflow.detail.managed_uninstall.confirm.devices"
            }
            return "workflow.detail.managed_uninstall.confirm.mixed"
        }
    }

    public enum SimulatorUninstallBlockReason: Sendable, Equatable {
        case simulatorRunning(names: [String])
        case invalidSelection
        case staleSnapshot

        func localizedMessage(locale: Locale) -> String {
            switch self {
            case .simulatorRunning:
                return AppLocalization.string(
                    "workflow.detail.managed_uninstall.blocked.simulator_running",
                    locale: locale
                )
            case .invalidSelection:
                return AppLocalization.string("workflow.detail.managed_uninstall.blocked.invalid", locale: locale)
            case .staleSnapshot:
                return AppLocalization.string("workflow.detail.managed_uninstall.blocked.stale", locale: locale)
            }
        }
    }

    public enum SimulatorUninstallItemStatus: Sendable, Equatable {
        case pending
        case validating
        case submitted
        case running
        case stalled(elapsed: TimeInterval)
        case succeeded
        case failed(exitCode: Int32, reason: SimulatorDeleteCoordinator.Outcome.FailureReason?)
        case unknown(detail: String)
        case blockedSimulatorRunning
        case skipped
    }

    /// v2026.07.16: one typed terminal projection shared by the sheet and tests. In
    /// particular, an already-submitted operation with no observed terminal status is
    /// `.unknown`, never failed; resources withheld because Simulator started retain the
    /// block reason instead of being flattened into a generic skipped row.
    static func simulatorFinishedStatus(
        outcome: SimulatorDeleteCoordinator.Outcome?,
        wasSkipped: Bool,
        interruptionReason: SimulatorDeleteCoordinator.ManagedExecutionCompletion.InterruptionReason?
    ) -> SimulatorUninstallItemStatus {
        if let outcome {
            switch outcome.status {
            case .confirmedTerminal(exitCode: 0):
                return .succeeded
            case .confirmedTerminal(let exitCode), .notSubmitted(let exitCode):
                if outcome.failureReason == .simulatorOrDeviceActive {
                    return .blockedSimulatorRunning
                }
                return .failed(exitCode: exitCode, reason: outcome.failureReason)
            case .unknownAfterStall:
                return .unknown(detail: "")
            }
        }
        if wasSkipped, interruptionReason == .simulatorStarted {
            return .blockedSimulatorRunning
        }
        return .skipped
    }

    public struct SimulatorUninstallItemProgress: Identifiable, Sendable, Equatable {
        public let item: SimulatorDeleteCoordinator.Item
        public var status: SimulatorUninstallItemStatus
        public var id: String { item.hitID }

        public init(item: SimulatorDeleteCoordinator.Item,
                    status: SimulatorUninstallItemStatus) {
            self.item = item
            self.status = status
        }
    }

    public struct SimulatorUninstallProgress: Sendable, Equatable {
        public var rows: [SimulatorUninstallItemProgress]
        public var currentIndex: Int
        public var completedCount: Int
        public var stopRequested: Bool
        public var totalCount: Int { rows.count }

        init(items: [SimulatorDeleteCoordinator.Item]) {
            self.rows = items.map { SimulatorUninstallItemProgress(item: $0, status: .pending) }
            self.currentIndex = 0
            self.completedCount = 0
            self.stopRequested = false
        }
    }

    public enum SimulatorUninstallState: Sendable, Equatable {
        case preparing(operationID: UUID, itemCount: Int)
        case review(SimulatorUninstallIntent)
        case executing(SimulatorUninstallIntent, SimulatorUninstallProgress)
        case finished(SimulatorUninstallIntent, SimulatorDeleteCoordinator.ManagedExecutionCompletion)
        case blocked(operationID: UUID, reason: SimulatorUninstallBlockReason)
    }

    /// v2026.07.15：managed operation 的唯一用户可见状态。准备、执行与终态都保留在
    /// 同一 sheet 内，不能再用全局 cardLoading 代替操作进度。
    @Published public private(set) var simulatorUninstallState: SimulatorUninstallState?

    /// 兼容旧调用方读取 lastDeleteResult 的入口（已弃用）。
    /// 这里故意只读；结果只能由本 ViewModel 在执行层返回后产生。
    public var lastDeleteResult: OperationResultPayload? {
        if case let .result(completion) = activeSheet { return completion.resultPayload }
        return nil
    }

    private let workflow: any DeveloperWorkflow
    private let home: URL
    private let simulatorCoordinator: SimulatorDeleteCoordinator
    /// **v2026.07.20**：UndoHistory 写入 owner 必须显式注入；生产 View 选择 `.shared`，
    /// 测试选择临时 store，禁止 compatibility moved-pair 结果污染用户历史。
    private let undoHistoryStore: UndoHistoryStore
    /// One immutable discovery result per Workflow scan revision. Tests inject this
    /// boundary to prove an empty hit list is not confused with an unreadable root.
    private let versionedRootDiscovery: @Sendable (URL) async -> KnownVersionedRoots.ScanResult
    /// Dynamic scanner hits and completeness evidence are likewise inseparable. Keeping
    /// the provider injectable lets tests prove AppUI does not project back to hits-only.
    private let dynamicDiscovery: @Sendable (
        String,
        URL,
        Bool
    ) async throws -> DiscoveryEvidence<WorkflowScanHit>
    /// Apple exposes the whole DerivedData root and per-project rows as two cards, but both
    /// must come from one filesystem transaction. Tests inject this immutable boundary to
    /// prove that the scheduler never performs a second recursive pass.
    private let derivedDataSnapshotDiscovery: @Sendable (
        URL,
        @escaping @Sendable (DerivedDataScanProgress) -> Void
    ) async throws -> DerivedDataScanSnapshot
    private var simulatorUninstallStopControl: SimulatorDeleteCoordinator.StopControl?
    private var pendingConfirmedDeleteIntent: WorkflowDeletionIntent?
    private var deletionInteractionCoordinator: DeletionInteractionCoordinator?
    private var didBootstrap: Bool = false
    private var scanRevision: UInt64 = 0
    /// Issues discovered once for the whole revision (currently KnownVersionedRoots), kept
    /// separate from per-card evidence so a card retry can replace only its own contribution.
    private var sharedScanIncompleteIssues: [ScanIncompleteIssue] = []
    /// The active full-scan body is explicitly owned here even when its caller is SwiftUI's
    /// structured `.task`. A new revision can therefore cancel the old body immediately,
    /// rather than relying only on late publication guards.
    private var activeScanTask: Task<Bool, Never>?
    private var activeScanOperationID: UUID?
    /// Revision checks protect publication; this chain separately joins cancelled filesystem
    /// producers before any replacement revision may acquire disk/CPU ownership.
    private let scanProducerSettlement = ScanProducerSettlementChain()
    private var scanReplacementRequestID = UUID()
    /// Button actions are synchronous UI events. Their async continuations must be registered
    /// before work starts so page disappearance can cancel every outstanding caller lifetime.
    private var scheduledFullRefreshTask: Task<Void, Never>?
    private var scheduledFullRefreshOperationID: UUID?
    private var scheduledCardRefreshTasks: [String: Task<Void, Never>] = [:]
    private var scheduledCardRefreshOperationIDs: [String: UUID] = [:]
    private var hasActiveViewScanLifetime = false
    private var cardRetryRevisions: [String: UInt64] = [:]
    private var cardRetryTasks: [String: Task<CardRetryOutput?, Never>] = [:]
    /// 本轮扫描中用户显式选择的 filesystem 路径。卡片是并发发布的；若较慢卡片
    /// 随后完成，其 safe 默认选择不得覆盖用户已经做出的父/子粒度选择。
    private var explicitFilesystemSelectionPaths: [String: String] = [:]
    private let maxConcurrentCardLoads = 2

    public init(workflow: any DeveloperWorkflow,
                home: URL,
                simulatorCoordinator: SimulatorDeleteCoordinator? = nil,
                undoHistoryStore: UndoHistoryStore,
                versionedRootDiscovery: (@Sendable (URL) async -> KnownVersionedRoots.ScanResult)? = nil,
                dynamicDiscovery: (@Sendable (
                    String,
                    URL,
                    Bool
                ) async throws -> DiscoveryEvidence<WorkflowScanHit>)? = nil,
                derivedDataSnapshotDiscovery: (@Sendable (URL) async throws -> DerivedDataScanSnapshot)? = nil) {
        self.workflow = workflow
        self.home = home
        // **v2026.07.15 根因修复**：CoreSimulator 托管卸载没有可证明安全的固定时限。
        // 默认协调器等待当前命令自然结束；停止请求只阻止下一项，绝不在 60s 后向正在
        // 提交的 runtime transaction 发送 TERM/SIGKILL。测试侧仍可注入 dryRun executor。
        self.simulatorCoordinator = simulatorCoordinator ?? SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                terminalWaitPolicy: .waitUntilExit,
                dryRun: false
            ),
            isSimulatorRunning: SimulatorDeleteCoordinator.defaultSimulatorRunning
        )
        self.undoHistoryStore = undoHistoryStore
        // **v2026.07.16 root-cause fix:** `loadAllCards` already owns the one detached,
        // revision-scoped discovery task. Nesting another detached task here severed
        // cancellation propagation, so leaving the page could keep the filesystem walk alive
        // while the visible cards remained stuck in `scanning`.
        self.versionedRootDiscovery = versionedRootDiscovery ?? { home in
            KnownVersionedRoots.scanAllWithEvidence(home: home)
        }
        self.dynamicDiscovery = dynamicDiscovery ?? { scannerID, home, includeFilesystemSizes in
            try await WorkflowRegistry.resolveWithEvidence(
                scannerID: scannerID,
                home: home,
                includeFilesystemSizes: includeFilesystemSizes
            )
        }
        if let derivedDataSnapshotDiscovery {
            // Test/injected providers retain their existing API and simply provide no partial
            // progress. Production uses the progress-aware one-pass scanner below.
            self.derivedDataSnapshotDiscovery = { home, _ in
                try await derivedDataSnapshotDiscovery(home)
            }
        } else {
            self.derivedDataSnapshotDiscovery = { home, progress in
                try await DerivedDataPerProjectScanner().discoverSnapshot(
                    home: home,
                    progress: progress
                )
            }
        }
    }

    deinit {
        activeScanTask?.cancel()
        scheduledFullRefreshTask?.cancel()
        scheduledCardRefreshTasks.values.forEach { $0.cancel() }
        cardRetryTasks.values.forEach { $0.cancel() }
    }

    /// Compatibility projection retained for existing callers/tests. Pending work is part of
    /// the transaction even though it has not begun filesystem I/O yet.
    public var cardLoading: Set<String> {
        Set(cardScanPhases.compactMap { cardID, phase in
            switch phase {
            case .pending, .scanning: cardID
            case .completed, .partial, .failed, .cancelled: nil
            }
        })
    }

    public var isAnyLoading: Bool { !cardLoading.isEmpty }

    public func cardScanPhase(for cardID: String) -> CardScanPhase {
        cardScanPhases[cardID] ?? .completed
    }

    public var isDeletionTransactionActive: Bool {
        if isPreparingDeletion || isDeleting || pendingConfirmedDeleteIntent != nil {
            return true
        }
        switch activeSheet {
        case .deleteConfirm, .simulatorUninstall:
            return true
        case .result, .none:
            return false
        }
    }

    public var isSimulatorUninstallDismissBlocked: Bool {
        simulatorUninstallState != nil
    }

    public var totalSelectedBytes: Int64 {
        Self.totalBytes(for: selected, cards: cards, cardHits: cardHits)
    }

    public func cardCapacityState(for cardID: String) -> CardCapacityState {
        switch cardScanPhase(for: cardID) {
        case .pending: return .pending
        case .scanning: return .loading
        case .cancelled: return .cancelled
        case .completed, .partial, .failed: break
        }
        let hits = cardHits[cardID] ?? []
        let hasIncompleteEvidence = !(cardIncompleteIssues[cardID] ?? []).isEmpty
        guard !hits.isEmpty else {
            return hasIncompleteEvidence ? .failed : .empty
        }
        let knownBytes = hits.compactMap(\.sizeBytes).reduce(Int64(0), &+)
        let unknownCount = hits.count(where: { $0.sizeBytes == nil })
        if unknownCount == hits.count { return .allUnknown }
        if unknownCount > 0 || hasIncompleteEvidence {
            return .partialUnknown(knownBytes: knownBytes)
        }
        return .known(bytes: knownBytes)
    }

    public func cardHasIncompleteEvidence(cardID: String) -> Bool {
        !(cardIncompleteIssues[cardID] ?? []).isEmpty
    }

    public var selectionCapacityState: SelectionCapacityState {
        let hits = Self.foldedSelectedHitsForDisplay(
            selection: selected,
            cards: cards,
            cardHits: cardHits
        )
        let itemCount = hits.count
        let known = hits.compactMap(\.sizeBytes)
        let knownBytes = known.reduce(Int64(0), &+)
        let unknownCount = itemCount - known.count
        if unknownCount == 0 {
            return .known(itemCount: itemCount, bytes: knownBytes)
        }
        if known.isEmpty {
            return .allUnknown(itemCount: itemCount)
        }
        return .partialUnknown(itemCount: itemCount, knownBytes: knownBytes)
    }

    public func selectionSummary(locale: Locale) -> String {
        switch selectionCapacityState {
        case .known(let itemCount, let bytes):
            return AppLocalization.format(
                "workflow.detail.footer.summary %lld %@",
                locale: locale,
                arguments: [itemCount, Self.formatBytes(bytes, locale: locale)]
            )
        case .partialUnknown(let itemCount, let knownBytes):
            return AppLocalization.format(
                "workflow.detail.footer.summary.partial %lld %@",
                locale: locale,
                arguments: [itemCount, Self.formatBytes(knownBytes, locale: locale)]
            )
        case .allUnknown(let itemCount):
            return AppLocalization.format(
                "workflow.detail.footer.summary.unknown %lld",
                locale: locale,
                arguments: [itemCount]
            )
        }
    }

    public var selectedFilesystemCount: Int {
        selectedHitIDs(forManagedUninstall: false).count
    }

    public var selectedManagedUninstallCount: Int {
        selectedHitIDs(forManagedUninstall: true).count
    }

    public var managedUninstallActionKey: LocalizedStringKey {
        let kinds = selectedManagedUninstallKinds()
        if kinds == [.simulatorRuntime] {
            return "workflow.detail.action.uninstall_runtimes"
        }
        if kinds == [.simulatorDevice] {
            return "workflow.detail.action.delete_devices"
        }
        return "workflow.detail.action.managed_uninstall"
    }

    public func canSelect(card: DeveloperCard, hit: WorkflowScanHit) -> Bool {
        guard !isDeletionTransactionActive, card.risk != .blocked else { return false }
        switch card.recipe {
        case .filesystem:
            return true
        case .managedUninstall:
            return hit.managedUninstallIdentifier != nil
        }
    }

    private func selectedHitIDs(forManagedUninstall managed: Bool) -> Set<String> {
        var ids: Set<String> = []
        for card in cards {
            let isManaged: Bool
            switch card.recipe {
            case .filesystem: isManaged = false
            case .managedUninstall: isManaged = true
            }
            guard isManaged == managed, let hits = cardHits[card.id] else { continue }
            for hit in hits where selected.contains(hit.id) {
                ids.insert(hit.id)
            }
        }
        return ids
    }

    private func selectedManagedUninstallKinds() -> Set<ManagedUninstallRecipe> {
        var kinds: Set<ManagedUninstallRecipe> = []
        for card in cards {
            guard case .managedUninstall(let kind) = card.recipe,
                  let hits = cardHits[card.id],
                  hits.contains(where: { selected.contains($0.id) }) else { continue }
            kinds.insert(kind)
        }
        return kinds
    }

    public func totalBytes(for selection: Set<String>) -> Int64 {
        Self.totalBytes(for: selection, cards: cards, cardHits: cardHits)
    }

    private static func totalBytes(for selection: Set<String>,
                                   cards: [DeveloperCard],
                                   cardHits: [String: [WorkflowScanHit]]) -> Int64 {
        var sum: Int64 = 0
        for hit in foldedSelectedHitsForDisplay(
            selection: selection,
            cards: cards,
            cardHits: cardHits
        ) {
            sum &+= hit.sizeBytes ?? 0
        }
        return sum
    }

    private static func filesystemProjection(
        for selection: Set<String>,
        cards: [DeveloperCard],
        cardHits: [String: [WorkflowScanHit]]
    ) -> (
        paths: [String],
        hitIDsByPath: [String: Set<String>],
        candidates: [RunningAppGuard.Candidate],
        bytesByPath: [String: Int64]
    ) {
        var paths: [String] = []
        var hitIDsByPath: [String: Set<String>] = [:]
        var candidateByPath: [String: RunningAppGuard.Candidate] = [:]
        var bytesByPath: [String: Int64] = [:]
        for card in cards {
            guard case .filesystem = card.recipe,
                  let hits = cardHits[card.id] else { continue }
            for hit in hits where selection.contains(hit.id) {
                let path = hit.url.standardizedFileURL.path
                paths.append(path)
                hitIDsByPath[path, default: []].insert(hit.id)
                bytesByPath[path] = max(0, hit.sizeBytes ?? 0)
                if candidateByPath[path] == nil {
                    candidateByPath[path] = RunningAppGuard.Candidate(
                        path: path,
                        title: hit.displayName,
                        bundleIDPrefix: card.runningBundleIDPrefix,
                        titlePresentation: WorkflowHitNamePresentation.descriptor(hit.displayName)
                    )
                }
            }
        }
        let folded = foldNestedPaths(paths)
        let kept = Set(folded)
        return (
            paths: folded,
            hitIDsByPath: hitIDsByPath.filter { kept.contains($0.key) },
            candidates: folded.compactMap { candidateByPath[$0] },
            bytesByPath: bytesByPath.filter { kept.contains($0.key) }
        )
    }

    private static func deletionRows(
        candidates: [RunningAppGuard.Candidate],
        bytesByPath: [String: Int64]
    ) -> [RowItem] {
        candidates.map { candidate in
            let bytes = max(0, bytesByPath[candidate.path] ?? 0)
            return RowItem(
                id: candidate.path,
                url: URL(fileURLWithPath: candidate.path),
                title: candidate.title,
                isDirectory: true,
                bytes: bytes,
                logicalBytes: bytes,
                fileCount: 1,
                verdict: .safe,
                rejection: .ok,
                runningBundleIDPrefix: candidate.bundleIDPrefix,
                titlePresentation: candidate.titlePresentation
            )
        }
    }

    private static func incompleteEvidencePaths(
        _ prepared: DeletionPreparedInteraction
    ) -> Set<String> {
        Set(prepared.scanIncompleteOverrideRequest?.entries
            .flatMap(\.incompleteIssues)
            .map(\.path) ?? [])
    }

    private static func incompleteEvidencePaths(
        _ authorized: DeletionAuthorizedInteraction
    ) -> Set<String> {
        Set(authorized.scanIncompleteOverrideRequest?.entries
            .flatMap(\.incompleteIssues)
            .map(\.path) ?? [])
    }

    public func bootstrap() async {
        hasActiveViewScanLifetime = true
        guard !didBootstrap else { return }
        _ = await runScan()
    }

    public func refreshAll() async {
        guard !isDeletionTransactionActive else { return }
        hasActiveViewScanLifetime = true
        _ = await runScan()
    }

    /// Starts a user-requested full refresh under a ViewModel-owned lifetime. The View no
    /// longer creates an anonymous `Task`, so navigation can deterministically stop it.
    public func startFullRefresh() {
        guard !isDeletionTransactionActive else { return }
        hasActiveViewScanLifetime = true
        scheduledFullRefreshTask?.cancel()
        let operationID = UUID()
        scheduledFullRefreshOperationID = operationID
        scheduledFullRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()
            guard self.scheduledFullRefreshOperationID == operationID else { return }
            self.scheduledFullRefreshTask = nil
            self.scheduledFullRefreshOperationID = nil
        }
    }

    /// Starts one card retry under a keyed, cancellable caller lifetime. `refreshCard` still
    /// owns its off-main worker; this outer handle closes the formerly unowned View Task.
    public func startCardRefresh(cardID: String) {
        guard !isDeletionTransactionActive,
              cards.contains(where: { $0.id == cardID }) else { return }
        hasActiveViewScanLifetime = true
        scheduledCardRefreshTasks[cardID]?.cancel()
        let operationID = UUID()
        scheduledCardRefreshOperationIDs[cardID] = operationID
        scheduledCardRefreshTasks[cardID] = Task { [weak self] in
            guard let self else { return }
            await self.refreshCard(cardID: cardID)
            guard self.scheduledCardRefreshOperationIDs[cardID] == operationID else { return }
            self.scheduledCardRefreshTasks.removeValue(forKey: cardID)
            self.scheduledCardRefreshOperationIDs.removeValue(forKey: cardID)
        }
    }

    /// Page-lifetime boundary for scan work only. It does not terminate a managed uninstall
    /// or Trash transaction, but it invalidates scan-derived selections and all scan workers.
    /// This method is idempotent because SwiftUI may cancel `.task` before or after disappear.
    public func cancelVisibleScanWork() {
        guard hasActiveViewScanLifetime else { return }
        hasActiveViewScanLifetime = false
        var settlementTasks: [Task<Void, Never>] = []
        if let activeScanTask {
            settlementTasks.append(Self.makeSettlementTask(activeScanTask))
        }
        for task in cardRetryTasks.values {
            settlementTasks.append(Self.makeSettlementTask(task))
        }
        scanProducerSettlement.retire(settlementTasks)
        activeScanTask = nil
        activeScanOperationID = nil
        scanReplacementRequestID = UUID()
        scheduledFullRefreshTask?.cancel()
        scheduledFullRefreshTask = nil
        scheduledFullRefreshOperationID = nil
        cancelScheduledCardRefreshes()
        cardRetryTasks.removeAll()
        convergeCancelledScan(
            revision: scanRevision,
            sessionID: scanEvidence.sessionID
        )

        // A cancelled page revision can no longer authorize a deletion after re-entry. Keep
        // already-rendered rows for a stable transition, but clear selections and rotate both
        // identity dimensions before any late provider resumes.
        didBootstrap = false
        selected.removeAll()
        explicitFilesystemSelectionPaths.removeAll()
        pendingConfirmedDeleteIntent = nil
        scanRevision &+= 1
        scanEvidence = WorkflowScanEvidence(
            revision: scanRevision,
            sessionID: UUID(),
            incompleteIssues: scanEvidence.incompleteIssues
        )
    }

    private func cancelScheduledCardRefreshes() {
        scheduledCardRefreshTasks.values.forEach { $0.cancel() }
        scheduledCardRefreshTasks.removeAll()
        scheduledCardRefreshOperationIDs.removeAll()
    }

    /// Retry one failed/cancelled card without invalidating trustworthy sibling results.
    ///
    /// **v2026.07.16 root-cause fix:** the row-level Retry button previously called
    /// `refreshAll()`, resetting every card to pending/loading and recreating the exact
    /// whole-page spinner reported by users. Each card now owns a monotonic retry token and
    /// one cancellable worker. A newer retry cancels and supersedes the older worker; both the
    /// token and full-scan session are revalidated before any result reaches `@Published` state.
    public func refreshCard(cardID: String) async {
        guard !isDeletionTransactionActive,
              let card = cards.first(where: { $0.id == cardID }) else { return }
        hasActiveViewScanLifetime = true

        let globalRevision = scanRevision
        let sessionID = scanEvidence.sessionID
        let retryRevision = (cardRetryRevisions[cardID] ?? 0) &+ 1
        cardRetryRevisions[cardID] = retryRevision
        if let predecessorTask = cardRetryTasks.removeValue(forKey: cardID) {
            scanProducerSettlement.retire([Self.makeSettlementTask(predecessorTask)])
        }
        let predecessor = scanProducerSettlement.barrier()
        guard await ScanProducerSettlementChain.waitForSettlement(predecessor),
              cardRetryRevisions[cardID] == retryRevision,
              scanRevision == globalRevision,
              scanEvidence.sessionID == sessionID else {
            return
        }

        clearCardForRetry(cardID: cardID, revision: globalRevision, sessionID: sessionID)
        let work: CardScanWork = card.sharedScanRole == nil
            ? .single(card)
            : .derivedData([card])
        let progressPair = AsyncStream<CardScanProgressEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        let progressContinuation = progressPair.continuation
        let progressConsumer = Task { @MainActor [weak self] in
            for await event in progressPair.stream {
                self?.publishCardScanProgress(
                    event,
                    revision: globalRevision,
                    sessionID: sessionID,
                    retryRevision: retryRevision
                )
            }
        }
        let retryTask = Task.detached(priority: .userInitiated) {
            [home, versionedRootDiscovery, dynamicDiscovery, derivedDataSnapshotDiscovery] in
            await Self.executeCardRetry(
                work,
                home: home,
                versionedRootDiscovery: versionedRootDiscovery,
                dynamicDiscovery: dynamicDiscovery,
                derivedDataSnapshotDiscovery: derivedDataSnapshotDiscovery,
                progress: { event in progressContinuation.yield(event) }
            )
        }
        cardRetryTasks[cardID] = retryTask

        let output = await withTaskCancellationHandler {
            await retryTask.value
        } onCancel: {
            retryTask.cancel()
        }
        progressContinuation.finish()
        await progressConsumer.value

        guard cardRetryRevisions[cardID] == retryRevision,
              scanRevision == globalRevision,
              scanEvidence.sessionID == sessionID else {
            return
        }
        cardRetryTasks.removeValue(forKey: cardID)
        guard !Task.isCancelled,
              let output,
              let result = output.workOutput.results[cardID] else {
            cardScanPhases[cardID] = .cancelled
            cardScanProgress.removeValue(forKey: cardID)
            return
        }
        if let sharedIssues = output.sharedIncompleteIssues {
            sharedScanIncompleteIssues = sharedIssues
        }
        publish(result, for: card, revision: globalRevision, sessionID: sessionID)
    }

    /// Convert a typed producer owner into the chain's `Void` join handle. Cancellation is
    /// forwarded before registration; the wrapper exists only to await true termination.
    private nonisolated static func makeSettlementTask<Success: Sendable>(
        _ task: Task<Success, Never>
    ) -> Task<Void, Never> {
        task.cancel()
        return Task.detached(priority: .userInitiated) {
            _ = await task.value
        }
    }

    public func toggleExpanded(cardID: String, open: Bool) {
        if open {
            expanded.insert(cardID)
        } else {
            expanded.remove(cardID)
        }
    }

    public func toggleSelection(hitID: String, on: Bool) {
        guard !isDeletionTransactionActive else { return }
        if on {
            // v2026.07.15：父子路径不能同时提交，但“保留谁”必须服从用户最后一次
            // 明确点击。旧实现每次都按最短路径折叠，导致已默认选中的 DerivedData
            // 整根永远吞掉用户随后点击的单项目 row，看起来就像 checkbox 坏了。
            // 这里先移除与目标重叠的已选 filesystem hit，再插入本次显式选择；
            // 不重叠的兄弟目录仍可多选。自动默认选择仍由批次发布后的折叠负责。
            if let hit = filesystemHit(withID: hitID) {
                preferExplicitFilesystemSelection(hit)
            } else {
                selected.insert(hitID)
            }
        } else {
            selected.remove(hitID)
            explicitFilesystemSelectionPaths.removeValue(forKey: hitID)
        }
    }

    private func filesystemHit(withID hitID: String) -> WorkflowScanHit? {
        for card in cards {
            guard case .filesystem = card.recipe,
                  let hit = cardHits[card.id]?.first(where: { $0.id == hitID }) else {
                continue
            }
            return hit
        }
        return nil
    }

    private func preferExplicitFilesystemSelection(_ target: WorkflowScanHit) {
        let targetPath = target.url.standardizedFileURL.path
        for card in cards {
            guard case .filesystem = card.recipe,
                  let hits = cardHits[card.id] else { continue }
            for hit in hits where selected.contains(hit.id) && hit.id != target.id {
                let selectedPath = hit.url.standardizedFileURL.path
                if Self.isAncestor(targetPath, of: selectedPath)
                    || Self.isAncestor(selectedPath, of: targetPath) {
                    selected.remove(hit.id)
                }
            }
        }
        let overlappingExplicitIDs = explicitFilesystemSelectionPaths.compactMap {
            hitID, path -> String? in
            Self.isAncestor(targetPath, of: path)
                || Self.isAncestor(path, of: targetPath) ? hitID : nil
        }
        for hitID in overlappingExplicitIDs {
            explicitFilesystemSelectionPaths.removeValue(forKey: hitID)
        }
        selected.insert(target.id)
        explicitFilesystemSelectionPaths[target.id] = targetPath
    }

    private func shouldApplyDefaultSelection(to hit: WorkflowScanHit) -> Bool {
        let path = hit.url.standardizedFileURL.path
        return !explicitFilesystemSelectionPaths.values.contains { explicitPath in
            Self.isAncestor(path, of: explicitPath)
                || Self.isAncestor(explicitPath, of: path)
        }
    }

    public func clearAlert() {
        alertTitle = nil
        alertMessage = nil
    }

    /// 工作流删除的唯一确认入口：先冻结 selection，再用实际 pipeline 做完整只读
    /// 预检。普通安全路径进入统一确认；vendorPathRule 与“所选目标相关的 typed
    /// incomplete”经目标级重验后进入严格覆盖确认；hard-forbid 等能力边界仍直接拒绝。
    public func requestDeleteConfirmation(pipeline: any DeletionPipeline) async {
        let selectionSnapshot = selectedHitIDs(forManagedUninstall: false)
        guard !selectionSnapshot.isEmpty,
              !isAnyLoading,
              !isDeleting,
              !isPreparingDeletion,
              pendingConfirmedDeleteIntent == nil,
              activeSheet == nil else { return }
        preflightNotice = nil
        let cardsSnapshot = cards
        let cardHitsSnapshot = cardHits
        let evidenceSnapshot = scanEvidence
        let filesystem = Self.filesystemProjection(
            for: selectionSnapshot,
            cards: cardsSnapshot,
            cardHits: cardHitsSnapshot
        )
        let relevantIssues = evidenceSnapshot.issues(overlappingAny: filesystem.paths)
        let totalBytes = Self.totalBytes(
            for: selectionSnapshot,
            cards: cardsSnapshot,
            cardHits: cardHitsSnapshot
        )

        isPreparingDeletion = true
        defer { isPreparingDeletion = false }
        let preparedInteraction: DeletionPreparedInteraction?
        if filesystem.paths.isEmpty {
            preparedInteraction = nil
            deletionInteractionCoordinator = nil
        } else {
            let identity = DeletionSnapshotIdentity(
                sessionID: evidenceSnapshot.sessionID,
                revision: evidenceSnapshot.revision,
                categoryID: "workflow"
            )
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
            do {
                let intent = try coordinator.makeIntent(
                    origin: .workflowFilesystem,
                    mode: .professional,
                    snapshotIdentity: identity,
                    candidates: filesystem.candidates.map { candidate in
                        DeletionInteractionCandidateSnapshot(
                            path: candidate.path,
                            title: candidate.title,
                            isDirectory: true,
                            bytes: filesystem.bytesByPath[candidate.path] ?? 0,
                            fileCount: 1,
                            runningBundleIDPrefix: candidate.bundleIDPrefix,
                            accessEvidence: evidenceSnapshot.accessEvidence(
                                for: candidate.path
                            ),
                            titlePresentation: candidate.titlePresentation
                        )
                    }
                )
                let preparation: DeletionInteractionPreparation
                if relevantIssues.isEmpty {
                    preparation = await coordinator.prepare(
                        intent: intent,
                        currentSnapshotIdentity: identity,
                        accessDeniedPaths: evidenceSnapshot.permissionDeniedPaths
                    )
                } else {
                    let rows = Self.deletionRows(
                        candidates: filesystem.candidates,
                        bytesByPath: filesystem.bytesByPath
                    )
                    let targetPreparation = await pipeline.prepareScanIncompleteOverride(
                        rows: rows,
                        scanIssues: relevantIssues,
                        scanSessionID: evidenceSnapshot.sessionID
                    )
                    preparation = coordinator.prepareRevalidatedScanIncomplete(
                        intent: intent,
                        currentSnapshotIdentity: identity,
                        preparation: targetPreparation
                    )
                }
                switch preparation {
                case .confirmation(let prepared):
                    preparedInteraction = prepared
                    deletionInteractionCoordinator = coordinator
                case .blocked(let block):
                    preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
                    return
                case .cancelled:
                    return
                }
            } catch {
                preflightNotice = DeletionPreflightNotice(
                    rejections: filesystem.paths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                )
                return
            }
        }
        guard activeSheet == nil,
              pendingConfirmedDeleteIntent == nil,
              scanEvidence.revision == evidenceSnapshot.revision,
              scanEvidence.sessionID == evidenceSnapshot.sessionID,
              selectedHitIDs(forManagedUninstall: false) == selectionSnapshot else {
            GSYLog.notice(.trash, "Workflow 删除预检完成时扫描或选择已变化，丢弃旧意图")
            preflightNotice = DeletionPreflightNotice(
                message: .scanChanged,
                rejections: []
            )
            return
        }

        let approvedPaths = preparedInteraction?.paths ?? []

        let allowedSet = Set(approvedPaths)
        let strictAccessEvidencePaths = preparedInteraction.map(
            Self.incompleteEvidencePaths
        ) ?? []
        let frozenAccessEvidencePaths = strictAccessEvidencePaths.isEmpty
            ? evidenceSnapshot.permissionDeniedPaths
            : strictAccessEvidencePaths
        let intent = WorkflowDeletionIntent(
            scanRevision: evidenceSnapshot.revision,
            scanSessionID: evidenceSnapshot.sessionID,
            selectedHitIDs: selectionSnapshot,
            filesystemPaths: approvedPaths,
            filesystemHitIDsByPath: filesystem.hitIDsByPath.filter {
                allowedSet.contains($0.key)
            },
            filesystemCandidates: filesystem.candidates.filter {
                allowedSet.contains($0.path)
            },
            accessDeniedPaths: frozenAccessEvidencePaths,
            preparedInteraction: preparedInteraction,
            authorizedInteraction: nil,
            itemCount: selectionSnapshot.count,
            totalBytes: totalBytes
        )
        activeSheet = .deleteConfirm(WorkflowDeleteConfirmation(
            intent: intent
        ))
    }

    @discardableResult
    public func confirmDelete(
        _ confirmation: WorkflowDeleteConfirmation,
        executionPlan: ToolTrashExecutionPlan
    ) -> Bool {
        guard case let .deleteConfirm(current) = activeSheet,
              current.id == confirmation.id else { return false }
        guard current.intent.scanRevision == scanEvidence.revision,
              current.intent.scanSessionID == scanEvidence.sessionID else {
            // v2026.07.20: stale confirmation is a non-modal pre-submit rejection.
            // Close the obsolete sheet, preserve fail-closed authorization, and let the
            // user continue with the current page instead of trapping them in a modal.
            deletionInteractionCoordinator = nil
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                message: .scanChanged,
                rejections: []
            )
            return false
        }
        guard pendingConfirmedDeleteIntent == nil else {
            deletionInteractionCoordinator = nil
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: current.intent.filesystemPaths.map {
                    .init(
                        path: $0,
                        reason: TrashPendingOperationRejection.Reason
                            .priorOperationPending.rawValue
                    )
                }
            )
            return false
        }

        let originalIntent = confirmation.intent
        let authorizedInteraction: DeletionAuthorizedInteraction?
        if originalIntent.filesystemPaths.isEmpty {
            authorizedInteraction = nil
        } else {
            guard let prepared = originalIntent.preparedInteraction,
                  let coordinator = deletionInteractionCoordinator else {
                GSYLog.error(.trash, "Workflow 删除确认缺少统一协调器快照")
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(
                    rejections: originalIntent.filesystemPaths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                )
                return false
            }
            switch coordinator.authorize(
                prepared: prepared,
                executionPlan: executionPlan
            ) {
            case .authorized(let authorized):
                authorizedInteraction = authorized
            case .cancelled:
                deletionInteractionCoordinator = nil
                activeSheet = nil
                return true
            case .blocked(let block):
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
                return false
            }
        }
        let originalPaths = Set(originalIntent.filesystemPaths)
        let submittedPaths = Set(executionPlan.paths)
        let skippedPaths = Set(executionPlan.runningAppSkipped.map(\.path))
        guard submittedPaths.count == executionPlan.paths.count,
              skippedPaths.count == executionPlan.runningAppSkipped.count,
              submittedPaths.isSubset(of: originalPaths),
              skippedPaths.isSubset(of: originalPaths),
              submittedPaths.isDisjoint(with: skippedPaths),
              submittedPaths.union(skippedPaths) == originalPaths else {
            GSYLog.error(.trash, "Workflow 删除确认计划未完整覆盖冻结路径，拒绝执行")
            deletionInteractionCoordinator = nil
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: originalIntent.filesystemPaths.map {
                    .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                }
            )
            return false
        }
        let strictAccessEvidencePaths = authorizedInteraction.map(
            Self.incompleteEvidencePaths
        ) ?? []
        let frozenAccessEvidencePaths: Set<String>
        if executionPlan.paths.isEmpty {
            frozenAccessEvidencePaths = []
        } else {
            frozenAccessEvidencePaths = strictAccessEvidencePaths.isEmpty
                ? originalIntent.accessDeniedPaths
                : strictAccessEvidencePaths
        }
        guard frozenAccessEvidencePaths.isSubset(of: originalIntent.accessDeniedPaths) else {
            GSYLog.error(.trash, "Workflow 删除确认丢失冻结的 typed incomplete evidence")
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: executionPlan.paths.map {
                    .init(
                        path: $0,
                        reason: ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
                    )
                }
            )
            return false
        }

        pendingConfirmedDeleteIntent = WorkflowDeletionIntent(
            id: originalIntent.id,
            scanRevision: originalIntent.scanRevision,
            scanSessionID: originalIntent.scanSessionID,
            selectedHitIDs: originalIntent.selectedHitIDs,
            filesystemPaths: executionPlan.paths,
            filesystemHitIDsByPath: originalIntent.filesystemHitIDsByPath.filter {
                submittedPaths.contains($0.key)
            },
            filesystemCandidates: originalIntent.filesystemCandidates.filter {
                submittedPaths.contains($0.path)
            },
            accessDeniedPaths: frozenAccessEvidencePaths,
            preparedInteraction: authorizedInteraction == nil
                ? nil
                : originalIntent.preparedInteraction,
            authorizedInteraction: authorizedInteraction,
            runningAppSkipped: authorizedInteraction?.runningAppSkipped
                ?? executionPlan.runningAppSkipped,
            itemCount: originalIntent.itemCount,
            totalBytes: originalIntent.totalBytes
        )
        deletionInteractionCoordinator = nil
        activeSheet = nil
        return true
    }

    public func cancelDeleteConfirmation() {
        guard case .deleteConfirm = activeSheet else { return }
        deletionInteractionCoordinator = nil
        activeSheet = nil
    }

    public func takePendingConfirmedDeleteIntent() -> WorkflowDeletionIntent? {
        defer { pendingConfirmedDeleteIntent = nil }
        return pendingConfirmedDeleteIntent
    }

    public func performDelete(pipeline: any DeletionPipeline,
                              intent: WorkflowDeletionIntent) async {
        guard !intent.selectedHitIDs.isEmpty,
              !isDeleting,
              intent.scanRevision == scanEvidence.revision,
              intent.scanSessionID == scanEvidence.sessionID else {
            GSYLog.notice(.trash, "Workflow 拒绝执行过期删除意图 revision=\(intent.scanRevision) current=\(scanEvidence.revision)")
            return
        }
        isDeleting = true
        defer { isDeleting = false }

        let fsPaths = intent.filesystemPaths

        // **v2026.06.22 (P0-1)**：与 [MainView.runTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
        // 对齐统一删除入口：accessDenied 注入 → TrashActionCoordinator.run → UndoHistory.addRecord
        // → 用 outcome.movedPairs 而非全部请求路径来回写 selected。原实现漏了前 3 步
        // 且 `for path in fsPaths { selected.remove(path) }` 会把"被 SafetyEngine 拦截
        // / recycle 失败"的项也从 selected 移除——用户重试时找不到原条目。
        var movedPairs: [(String, String)] = []
        var succeededFilesystemHitIDs: Set<String> = []
        var filesystemCompletion: DeletionCompletedInteraction?
        if !fsPaths.isEmpty {
            guard let authorized = intent.authorizedInteraction else {
                GSYLog.error(.trash, "Workflow 文件删除缺少统一授权")
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(
                    rejections: fsPaths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                )
                return
            }
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
            let disposition = await coordinator.submit(
                authorized,
                accessDeniedPaths: intent.accessDeniedPaths
            )
            let completed: DeletionCompletedInteraction
            switch disposition {
            case .completed(let value):
                completed = value
                filesystemCompletion = value

            case .requiresConfirmation(let prepared):
                // Final revalidation discovered a vendor-only risk after the simple
                // confirmation. Reopen a strict sheet from this immutable intent; never
                // consult newer cards/selection and never manufacture a cleanup result.
                let strictIntent = WorkflowDeletionIntent(
                    id: intent.id,
                    scanRevision: intent.scanRevision,
                    scanSessionID: intent.scanSessionID,
                    selectedHitIDs: intent.selectedHitIDs,
                    filesystemPaths: prepared.paths,
                    filesystemHitIDsByPath: intent.filesystemHitIDsByPath.filter {
                        Set(prepared.paths).contains($0.key)
                    },
                    filesystemCandidates: prepared.confirmationCandidates,
                    accessDeniedPaths: intent.accessDeniedPaths,
                    preparedInteraction: prepared,
                    authorizedInteraction: nil,
                    runningAppSkipped: intent.runningAppSkipped,
                    itemCount: intent.itemCount,
                    totalBytes: intent.totalBytes
                )
                deletionInteractionCoordinator = coordinator
                activeSheet = .deleteConfirm(WorkflowDeleteConfirmation(intent: strictIntent))
                return

            case .blocked(let block):
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
                return
            }
            let result = completed.result
            if let outcome = result.outcome {
                movedPairs = outcome.movedPairs.map { ($0.originalPath, $0.trashedPath) }
            } else {
                movedPairs = result.pairs
            }

            // 只消费确认前冻结的 path → hit 映射；同时同步父子重叠卡片（如 DerivedData 根与单项目卡）。
            let succeededPaths = movedPairs.map { $0.0 }
            for path in succeededPaths {
                succeededFilesystemHitIDs.formUnion(intent.filesystemHitIDsByPath[path] ?? [])
            }
            selected.subtract(succeededFilesystemHitIDs)
            removeHitsFromVisibleState(
                succeededFilesystemHitIDs,
                succeededFilesystemPaths: succeededPaths
            )
        }

        // v2026.07.15：Trash 完成后直接展示真实 receipt，并只从当前卡片投影中移除
        // 确认成功的 rows。旧实现为了接续 simctl 而 await 全页 runScan，导致结果与
        // managed 确认都被慢 Runtime 扫描阻塞数分钟。
        if let filesystemCompletion {
            activeSheet = .result(.deletion(filesystemCompletion))
        } else {
            GSYLog.notice(.trash, "Workflow Trash 未产生提交终态")
        }
    }

    /// v2026.07.15：Simulator managed operation 的独立入口。先同步挂出 preparing
    /// sheet，再 yield 后做计划验证，保证用户点击后第一帧就能看到状态。
    public func requestSimulatorUninstall() async {
        let selectionSnapshot = selectedHitIDs(forManagedUninstall: true)
        guard !selectionSnapshot.isEmpty,
              !isDeleting,
              simulatorUninstallState == nil,
              activeSheet == nil else { return }

        let operationID = UUID()
        let evidenceSnapshot = scanEvidence
        let cardsSnapshot = cards
        let hitsSnapshot = cardHits
        simulatorUninstallState = .preparing(
            operationID: operationID,
            itemCount: selectionSnapshot.count
        )
        activeSheet = .simulatorUninstall
        await Task.yield()

        guard case .preparing(let currentID, _) = simulatorUninstallState,
              currentID == operationID else { return }
        let plan = simulatorCoordinator.prepare(
            cards: cardsSnapshot,
            cardHits: hitsSnapshot,
            selected: selectionSnapshot
        )
        guard scanEvidence.revision == evidenceSnapshot.revision,
              scanEvidence.sessionID == evidenceSnapshot.sessionID else {
            simulatorUninstallState = .blocked(
                operationID: operationID,
                reason: .staleSnapshot
            )
            return
        }

        switch plan {
        case .ready(let items):
            simulatorUninstallState = .review(SimulatorUninstallIntent(
                id: operationID,
                scanRevision: evidenceSnapshot.revision,
                scanSessionID: evidenceSnapshot.sessionID,
                selectedHitIDs: selectionSnapshot,
                items: items,
                totalBytes: items.reduce(0) { $0 &+ max(0, $1.sizeBytes ?? 0) }
            ))
        case .blockedSimulatorRunning(let names):
            simulatorUninstallState = .blocked(
                operationID: operationID,
                reason: .simulatorRunning(names: names)
            )
        case .invalid, .empty:
            simulatorUninstallState = .blocked(
                operationID: operationID,
                reason: .invalidSelection
            )
        }
    }

    public func cancelSimulatorUninstall() {
        switch simulatorUninstallState {
        case .preparing, .review:
            simulatorUninstallState = nil
            simulatorUninstallStopControl = nil
            if case .simulatorUninstall = activeSheet { activeSheet = nil }
        case .executing, .finished, .blocked, .none:
            break
        }
    }

    public func requestSimulatorUninstallStop() async {
        guard case .executing(let intent, var progress) = simulatorUninstallState,
              !progress.stopRequested,
              let control = simulatorUninstallStopControl else { return }
        // 先把停止意图写进 actor，再更新 UI。这样当前项恰好结束时，执行循环不会在
        // stop token 尚未生效的竞态窗口中提交下一项。
        await control.requestStop()
        guard case .executing(let currentIntent, let currentProgress) = simulatorUninstallState,
              currentIntent.id == intent.id else { return }
        progress = currentProgress
        progress.stopRequested = true
        simulatorUninstallState = .executing(intent, progress)
    }

    public func executeSimulatorUninstall() async {
        guard case .review(let intent) = simulatorUninstallState,
              intent.scanRevision == scanEvidence.revision,
              intent.scanSessionID == scanEvidence.sessionID else {
            if case .review(let staleIntent) = simulatorUninstallState {
                simulatorUninstallState = .blocked(
                    operationID: staleIntent.id,
                    reason: .staleSnapshot
                )
            }
            return
        }

        let validatedItems: [SimulatorDeleteCoordinator.Item]
        switch simulatorCoordinator.revalidate(items: intent.items) {
        case .ready(let items):
            validatedItems = items
        case .blockedSimulatorRunning(let names):
            simulatorUninstallState = .blocked(
                operationID: intent.id,
                reason: .simulatorRunning(names: names)
            )
            return
        case .invalid, .empty:
            simulatorUninstallState = .blocked(
                operationID: intent.id,
                reason: .invalidSelection
            )
            return
        }

        isDeleting = true
        defer { isDeleting = false }
        let stopControl = SimulatorDeleteCoordinator.StopControl()
        simulatorUninstallStopControl = stopControl
        simulatorUninstallState = .executing(
            intent,
            SimulatorUninstallProgress(items: validatedItems)
        )

        let completion = await simulatorCoordinator.executeManaged(
            items: validatedItems,
            // **v2026.07.16 根因修复**：managed ledger 的复核代际必须取自用户实际
            // 审阅的冻结扫描证据，而不是 operationID（点击时随机 UUID）。这样跨重启
            // stale reservation 只允许由新 session 或同 session 更高 revision 清理。
            reviewIdentity: SimulatorManagedReviewIdentity(
                sessionID: intent.scanSessionID,
                revision: intent.scanRevision
            ),
            stopControl: stopControl
        ) { [weak self] event in
            await self?.applySimulatorUninstallEvent(event, sourceIntent: intent)
        }
        simulatorUninstallStopControl = nil
        guard case .executing(let currentIntent, _) = simulatorUninstallState,
              currentIntent == intent,
              scanEvidence.revision == intent.scanRevision,
              scanEvidence.sessionID == intent.scanSessionID else { return }

        let succeededIDs = Set(
            completion.outcomes.filter(\.isSuccess).map(\.item.hitID)
        )
        selected.subtract(succeededIDs)
        removeHitsFromVisibleState(succeededIDs)
        simulatorUninstallState = .finished(intent, completion)

        // 先落 initial `.finished`，再等待迟到终态，形成顺序屏障：终态绝不会先更新 UI
        // 又被含 unknown 的 completion 覆盖。duplicate-pending 也接入同一等待通道，
        // 支持页面重建后的 process-session 对账。
        let awaitingReconciliation = completion.outcomes.filter {
            ($0.isUnknown && $0.failureReason != .observationEndedWithoutTerminal)
                || $0.failureReason == .duplicatePendingOperation
        }
        let coordinator = simulatorCoordinator
        for pendingOutcome in awaitingReconciliation {
            Task { [weak self] in
                guard let reconciled = await coordinator.awaitReconciledOutcome(
                    for: pendingOutcome.item
                ) else { return }
                guard let self else { return }
                self.applySimulatorUninstallEvent(
                    .finished(index: 1, total: 1, outcome: reconciled),
                    sourceIntent: intent
                )
            }
        }
    }

    public func finishSimulatorUninstallPresentation() {
        switch simulatorUninstallState {
        case .finished, .blocked:
            simulatorUninstallState = nil
            simulatorUninstallStopControl = nil
            if case .simulatorUninstall = activeSheet { activeSheet = nil }
        case .preparing, .review, .executing, .none:
            break
        }
    }

    private func applySimulatorUninstallEvent(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        sourceIntent: SimulatorUninstallIntent
    ) {
        // **v2026.07.16 late-terminal reconciliation**：stall 后 coordinator 仍是流的唯一
        // 消费者；终态可能在 overall state 已 `.finished` 或 sheet 已关闭后到达。成功项
        // 只有在当前投影仍属于产生该命令的同一 scan session/revision，且 outcome 精确匹配
        // 冻结 item 时才能从可见/可选状态移除。旧实现只看稳定 hitID：用户在 unknown 后
        // 关闭 sheet、重扫并得到复用同一路径的替代资源时，旧命令的迟到 success 会误删
        // 新 revision 的 row。ledger/monitor 仍照常完成旧操作对账，但旧终态不得污染新投影。
        let projectsOntoCurrentScan =
            scanEvidence.revision == sourceIntent.scanRevision
            && scanEvidence.sessionID == sourceIntent.scanSessionID
        if case .finished(_, _, let lateOutcome) = event {
            let belongsToFrozenIntent = sourceIntent.items.contains(lateOutcome.item)
            if lateOutcome.isSuccess,
               projectsOntoCurrentScan,
               belongsToFrozenIntent {
                selected.remove(lateOutcome.item.hitID)
                removeHitsFromVisibleState([lateOutcome.item.hitID])
            }
            if case .finished(let intent, let completion) = simulatorUninstallState,
               intent == sourceIntent,
               belongsToFrozenIntent {
                simulatorUninstallState = .finished(
                    intent,
                    completion.reconciling(lateOutcome)
                )
                return
            }
        }

        guard case .executing(let intent, var progress) = simulatorUninstallState,
              intent == sourceIntent,
              projectsOntoCurrentScan else { return }
        switch event {
        case .started(let index, _, let item):
            progress.currentIndex = index
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == item.hitID }) {
                // v2026.07.16: started means the item entered per-item revalidation; no
                // subprocess has been submitted yet. Keep it distinct from actual running.
                progress.rows[rowIndex].status = .validating
            }
        case .submitted(let index, _, let item):
            progress.currentIndex = index
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == item.hitID }) {
                progress.rows[rowIndex].status = .submitted
            }
        case .running(let index, _, let item):
            progress.currentIndex = index
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == item.hitID }) {
                progress.rows[rowIndex].status = .running
            }
        case .stalled(let index, _, let item, let elapsed):
            progress.currentIndex = index
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == item.hitID }) {
                progress.rows[rowIndex].status = .stalled(elapsed: elapsed)
            }
        case .blockedSimulatorRunning(let index, _, let item):
            progress.currentIndex = index
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == item.hitID }) {
                progress.rows[rowIndex].status = .blockedSimulatorRunning
            }
        case .finished(_, _, let outcome):
            progress.completedCount += 1
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == outcome.item.hitID }) {
                switch outcome.status {
                case .confirmedTerminal(exitCode: 0):
                    progress.rows[rowIndex].status = .succeeded
                case .confirmedTerminal(let exitCode), .notSubmitted(let exitCode):
                    if outcome.failureReason == .simulatorOrDeviceActive {
                        progress.rows[rowIndex].status = .blockedSimulatorRunning
                        break
                    }
                    progress.rows[rowIndex].status = .failed(
                        exitCode: exitCode,
                        reason: outcome.failureReason
                    )
                case .unknownAfterStall:
                    progress.rows[rowIndex].status = .unknown(detail: "")
                }
            }
        }
        simulatorUninstallState = .executing(intent, progress)
    }

    public func applyExternalDeletedPaths(_ paths: [String]) {
        guard !paths.isEmpty, !isDeletionTransactionActive else { return }
        removeHitsFromVisibleState([], succeededFilesystemPaths: paths)
    }

    /// 从已发布卡片投影中只移除真实成功项，并同步重叠父子卡片（如 DerivedData 整根与分工程卡片）。
    /// 不触发全页 runScan，所以无关 Card 不会一起进入 loading。
    private func removeHitsFromVisibleState(
        _ hitIDs: Set<String>,
        succeededFilesystemPaths: [String] = []
    ) {
        guard !hitIDs.isEmpty || !succeededFilesystemPaths.isEmpty else { return }
        let pathMatcher = DeletionPresentationPathMatcher(paths: succeededFilesystemPaths)
        let foldedDeletedRoots = Self.foldNestedPaths(succeededFilesystemPaths)
        let filesystemCardIDs = Set(cards.compactMap { card -> String? in
            if case .filesystem = card.recipe { return card.id }
            return nil
        })

        // Record the size of deleted roots before removing hits so ancestor cards can subtract them.
        var deletedBytesByRoot: [String: Int64] = [:]
        if !foldedDeletedRoots.isEmpty {
            let deletedRootSet = Set(foldedDeletedRoots)
            for cardID in cardHits.keys where filesystemCardIDs.isEmpty || filesystemCardIDs.contains(cardID) {
                for hit in cardHits[cardID] ?? [] {
                    let stdPath = hit.url.standardizedFileURL.path
                    guard deletedRootSet.contains(stdPath),
                          let bytes = hit.sizeBytes, bytes > 0 else { continue }
                    deletedBytesByRoot[stdPath] = max(deletedBytesByRoot[stdPath] ?? 0, bytes)
                }
            }
        }

        var allRemovedHitIDs = hitIDs
        for cardID in Array(cardHits.keys) {
            let isFilesystemCard = filesystemCardIDs.isEmpty || filesystemCardIDs.contains(cardID)
            let currentHits = cardHits[cardID] ?? []
            var remaining: [WorkflowScanHit] = []
            remaining.reserveCapacity(currentHits.count)

            for hit in currentHits {
                let stdPath = hit.url.standardizedFileURL.path
                if hitIDs.contains(hit.id) || (isFilesystemCard && pathMatcher.contains(stdPath)) {
                    allRemovedHitIDs.insert(hit.id)
                    continue
                }
                if isFilesystemCard, let oldBytes = hit.sizeBytes {
                    var subtractedBytes: Int64 = 0
                    for (deletedRoot, rootBytes) in deletedBytesByRoot
                        where Self.isAncestor(stdPath, of: deletedRoot) && stdPath != deletedRoot {
                        subtractedBytes = Self.saturatingAdd(subtractedBytes, rootBytes)
                    }
                    if subtractedBytes > 0 {
                        let nextBytes = max(0, oldBytes - subtractedBytes)
                        if nextBytes == 0 {
                            let issues = cardIncompleteIssues[cardID] ?? []
                            let hasIncompleteEvidence = !DeletionTargetRevalidator.relevantIssues(
                                for: hit.url.path,
                                from: issues
                            ).isEmpty
                            if !hasIncompleteEvidence {
                                allRemovedHitIDs.insert(hit.id)
                                continue
                            }
                            remaining.append(WorkflowScanHit(
                                url: hit.url,
                                sizeBytes: nil,
                                displayName: hit.displayName,
                                note: hit.note,
                                semanticNote: hit.semanticNote,
                                managedUninstallIdentifier: hit.managedUninstallIdentifier
                            ))
                            continue
                        }
                        remaining.append(WorkflowScanHit(
                            url: hit.url,
                            sizeBytes: nextBytes,
                            displayName: hit.displayName,
                            note: hit.note,
                            semanticNote: hit.semanticNote,
                            managedUninstallIdentifier: hit.managedUninstallIdentifier
                        ))
                        continue
                    }
                }
                remaining.append(hit)
            }
            cardHits[cardID] = remaining
            cardTotalBytes[cardID] = remaining.reduce(0) { $0 &+ max(0, $1.sizeBytes ?? 0) }
        }

        selected.subtract(allRemovedHitIDs)
        for hitID in allRemovedHitIDs {
            explicitFilesystemSelectionPaths.removeValue(forKey: hitID)
        }
    }

    private struct CardScanResult: Sendable {
        var hits: [WorkflowScanHit]
        var incompleteIssues: [ScanIncompleteIssue] = []
        var terminalFailure: Bool = false

        mutating func merge(incompleteIssues: [ScanIncompleteIssue]) {
            self.incompleteIssues.append(contentsOf: incompleteIssues)
        }

        mutating func merge(filesystem: FilesystemScanResult) {
            incompleteIssues.append(contentsOf: filesystem.incompleteIssues)
            terminalFailure = terminalFailure || filesystem.terminalFailure
        }
    }

    private struct FilesystemScanResult: Sendable {
        let sizeBytes: Int64?
        let fileCount: Int
        let incompleteIssues: [ScanIncompleteIssue]
        let terminalFailure: Bool
    }

    private struct FilesystemScanProgress: Sendable, Equatable {
        let scannedBytes: Int64
        let fileCount: Int
        let currentPath: String
    }

    private struct CardScanProgressEvent: Sendable, Equatable {
        let cardID: String
        let progress: CardScanProgress
    }

    private struct PathExpansionResult: Sendable {
        let paths: [String]
        let incompleteIssues: [ScanIncompleteIssue]
    }

    private enum CardScanWork: Sendable {
        case single(DeveloperCard)
        case derivedData([DeveloperCard])

        var cards: [DeveloperCard] {
            switch self {
            case .single(let card): [card]
            case .derivedData(let cards): cards
            }
        }
    }

    private struct CardScanWorkOutput: Sendable {
        let results: [String: CardScanResult]
    }

    private struct CardRetryOutput: Sendable {
        let workOutput: CardScanWorkOutput
        /// Non-nil only when this card owns a versioned-root discovery transaction.
        let sharedIncompleteIssues: [ScanIncompleteIssue]?
    }

    /// **v2026.07.16 root-cause fix:** `didBootstrap` records a completed scan transaction,
    /// not merely an attempted one. SwiftUI cancels the view `.task` when the page leaves;
    /// marking bootstrap complete before that task reached a terminal state made re-entry a
    /// permanent no-op with cards still shown as loading.
    @discardableResult
    private func runScan() async -> Bool {
        didBootstrap = false
        // v2026.07.18 producer-ownership fix: generation checks stop stale UI writes, but they
        // do not stop detached walkers. Only the latest replacement request may proceed after
        // every cancelled full/card task (which transitively joins BulkScanner) has exited.
        let replacementRequestID = UUID()
        scanReplacementRequestID = replacementRequestID
        activeScanOperationID = replacementRequestID
        var settlementTasks: [Task<Void, Never>] = []
        if let activeScanTask {
            settlementTasks.append(Self.makeSettlementTask(activeScanTask))
        }
        for task in cardRetryTasks.values {
            settlementTasks.append(Self.makeSettlementTask(task))
        }
        scanProducerSettlement.retire(settlementTasks)
        activeScanTask = nil
        cancelScheduledCardRefreshes()
        cardRetryTasks.removeAll()
        cardRetryRevisions.removeAll()
        let predecessor = scanProducerSettlement.barrier()
        guard await ScanProducerSettlementChain.waitForSettlement(predecessor),
              scanReplacementRequestID == replacementRequestID,
              activeScanOperationID == replacementRequestID else {
            return false
        }
        sharedScanIncompleteIssues.removeAll()
        scanRevision &+= 1
        let revision = scanRevision
        let sessionID = UUID()
        cardHits.removeAll()
        cardTotalBytes.removeAll()
        cardScanProgress.removeAll()
        cardIncompleteIssues.removeAll()
        cardScanPhases.removeAll()
        selected.removeAll()
        explicitFilesystemSelectionPaths.removeAll()
        pendingConfirmedDeleteIntent = nil
        scanEvidence = WorkflowScanEvidence(revision: revision, sessionID: sessionID)
        cards = workflow.cards(home: home)
        cardScanPhases = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, .pending) })
        for card in cards where card.risk == .safe {
            expanded.insert(card.id)
        }
        let scanTask = Task { [weak self] in
            guard let self else { return false }
            return await self.loadAllCards(revision: revision, sessionID: sessionID)
        }
        activeScanTask = scanTask
        let completed = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        if activeScanOperationID == replacementRequestID {
            activeScanTask = nil
            activeScanOperationID = nil
        }
        guard revision == scanRevision,
              scanEvidence.sessionID == sessionID else {
            return false
        }
        guard completed, !Task.isCancelled else {
            convergeCancelledScan(revision: revision, sessionID: sessionID)
            return false
        }
        didBootstrap = true
        return true
    }

    @discardableResult
    private func loadAllCards(revision: UInt64, sessionID: UUID) async -> Bool {
        let cardsSnapshot = cards
        let progressPair = AsyncStream<CardScanProgressEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let progressContinuation = progressPair.continuation
        let progressConsumer = Task { @MainActor [weak self] in
            for await event in progressPair.stream {
                self?.publishCardScanProgress(
                    event,
                    revision: revision,
                    sessionID: sessionID,
                    retryRevision: nil
                )
            }
        }
        let progressEmitter: @Sendable (CardScanProgressEvent) -> Void = { event in
            progressContinuation.yield(event)
        }
        let needsVersionedRoots = cardsSnapshot.contains { card in
            if case .versionedRoot = card.source { return true }
            return false
        }
        let versionedTask: Task<KnownVersionedRoots.ScanResult, Never>? = needsVersionedRoots
            ? Task.detached(priority: .userInitiated) { [home, versionedRootDiscovery] in
                await versionedRootDiscovery(home)
            }
            : nil
        // The task is revision-owned. Every exit path, including parent cancellation and a
        // superseding refresh, must stop it; otherwise it outlives the screen transaction.
        defer { versionedTask?.cancel() }
        let workItems = Self.makeCardScanWork(cardsSnapshot)
        var nextWorkIndex = 0

        // **v2026.07.16 root-cause fix:** the old outer `while` submitted fixed batches of
        // two. A fast card finishing first could not release its slot until the slow sibling
        // also completed. This is a real bounded work queue: every completion immediately
        // starts the next pending unit, while MainActor only applies compact final DTOs.
        let completed = await withTaskCancellationHandler {
            await withTaskGroup(of: CardScanWorkOutput?.self) { group in
                guard !Task.isCancelled else { return false }
                while nextWorkIndex < min(maxConcurrentCardLoads, workItems.count) {
                    let work = workItems[nextWorkIndex]
                    nextWorkIndex += 1
                    for card in work.cards {
                        cardScanPhases[card.id] = .scanning
                        cardScanProgress[card.id] = CardScanProgress(
                            scannedBytes: 0,
                            fileCount: 0,
                            currentPath: nil
                        )
                    }
                    group.addTask { [home, dynamicDiscovery, derivedDataSnapshotDiscovery] in
                        await Self.executeScanWork(
                            work,
                            home: home,
                            versionedTask: versionedTask,
                            dynamicDiscovery: dynamicDiscovery,
                            derivedDataSnapshotDiscovery: derivedDataSnapshotDiscovery,
                            progress: progressEmitter
                        )
                    }
                }

                while let workOutput = await group.next() {
                    guard !Task.isCancelled,
                          revision == scanRevision,
                          scanEvidence.sessionID == sessionID,
                          let output = workOutput else {
                        group.cancelAll()
                        versionedTask?.cancel()
                        return false
                    }
                    for card in cardsSnapshot {
                        guard let result = output.results[card.id] else { continue }
                        publish(result, for: card, revision: revision, sessionID: sessionID)
                    }
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        versionedTask?.cancel()
                        return false
                    }
                    if nextWorkIndex < workItems.count {
                        let work = workItems[nextWorkIndex]
                        nextWorkIndex += 1
                        for card in work.cards {
                            cardScanPhases[card.id] = .scanning
                            cardScanProgress[card.id] = CardScanProgress(
                                scannedBytes: 0,
                                fileCount: 0,
                                currentPath: nil
                            )
                        }
                        group.addTask { [home, dynamicDiscovery, derivedDataSnapshotDiscovery] in
                            await Self.executeScanWork(
                                work,
                                home: home,
                                versionedTask: versionedTask,
                                dynamicDiscovery: dynamicDiscovery,
                                derivedDataSnapshotDiscovery: derivedDataSnapshotDiscovery,
                                progress: progressEmitter
                            )
                        }
                    }
                }
                return !Task.isCancelled
            }
        } onCancel: {
            // The shared task is unstructured by design so multiple versioned cards can await
            // one immutable result; cancellation therefore has to be forwarded explicitly.
            versionedTask?.cancel()
        }
        progressContinuation.finish()
        await progressConsumer.value

        guard completed, !Task.isCancelled,
              revision == scanRevision,
              scanEvidence.sessionID == sessionID else {
            return false
        }
        if let versionedTask {
            let versionedDiscovery = await versionedTask.value
            guard !Task.isCancelled,
                  !versionedDiscovery.wasCancelled,
                  revision == scanRevision,
                  scanEvidence.sessionID == sessionID else {
                return false
            }
            sharedScanIncompleteIssues = versionedDiscovery.incompleteIssues
            rebuildScanEvidence(revision: revision, sessionID: sessionID)
        }
        collapseNestedFilesystemSelections()
        return true
    }

    /// Cancellation is a real terminal state, not an empty result and not a scan failure.
    /// Preserve cards that already published a trustworthy result, while converging queued
    /// and in-flight cards so no spinner survives the revision that owned it.
    private func convergeCancelledScan(revision: UInt64, sessionID: UUID) {
        guard revision == scanRevision,
              scanEvidence.sessionID == sessionID else { return }
        for card in cards {
            switch cardScanPhases[card.id] {
            case .pending, .scanning:
                cardScanPhases[card.id] = .cancelled
                cardScanProgress.removeValue(forKey: card.id)
            case .completed, .partial, .failed, .cancelled, .none:
                break
            }
        }
    }

    private func clearCardForRetry(cardID: String, revision: UInt64, sessionID: UUID) {
        let oldHitIDs = Set((cardHits[cardID] ?? []).map(\.id))
        let siblingHitIDs = Set(cardHits
            .filter { $0.key != cardID }
            .values
            .flatMap { $0 }
            .map(\.id))
        for hitID in oldHitIDs.subtracting(siblingHitIDs) {
            selected.remove(hitID)
            explicitFilesystemSelectionPaths.removeValue(forKey: hitID)
        }
        cardHits[cardID] = []
        cardTotalBytes[cardID] = 0
        cardScanProgress[cardID] = CardScanProgress(
            scannedBytes: 0,
            fileCount: 0,
            currentPath: nil
        )
        cardIncompleteIssues[cardID] = []
        cardScanPhases[cardID] = .scanning
        rebuildScanEvidence(revision: revision, sessionID: sessionID)
    }

    /// Rebuild instead of append: a successful retry must remove the old card's incomplete
    /// evidence, while unrelated cards and revision-wide discovery evidence stay unchanged.
    private func rebuildScanEvidence(revision: UInt64, sessionID: UUID) {
        guard revision == scanRevision,
              scanEvidence.sessionID == sessionID else { return }
        scanEvidence = WorkflowScanEvidence(
            revision: revision,
            sessionID: sessionID,
            incompleteIssues: sharedScanIncompleteIssues
                + cardIncompleteIssues.values.flatMap { $0 }
        )
    }

    private func publish(
        _ result: CardScanResult,
        for card: DeveloperCard,
        revision: UInt64,
        sessionID: UUID
    ) {
        let published = Self.normalizedForPublication(result, card: card)
        cardHits[card.id] = published.hits
        cardTotalBytes[card.id] = published.hits.reduce(0) {
            $0 &+ max(0, $1.sizeBytes ?? 0)
        }
        cardIncompleteIssues[card.id] = published.incompleteIssues
        cardScanProgress.removeValue(forKey: card.id)
        if published.terminalFailure || (published.hits.isEmpty && !published.incompleteIssues.isEmpty) {
            cardScanPhases[card.id] = .failed
        } else if published.incompleteIssues.isEmpty {
            cardScanPhases[card.id] = .completed
        } else {
            cardScanPhases[card.id] = .partial
        }
        rebuildScanEvidence(revision: revision, sessionID: sessionID)
        if card.risk == .safe, case .filesystem = card.recipe {
            for hit in published.hits where shouldApplyDefaultSelection(to: hit) {
                selected.insert(hit.id)
            }
        }
        collapseNestedFilesystemSelections()
    }

    /// v2026.07.17 Workflow long-task owner gate. Worker progress is absolute and bounded, but
    /// still untrusted for publication until the exact card + scan session/revision (and retry
    /// revision when present) owns it. Monotonic checks prevent buffered late frames regressing
    /// a newer byte/file count.
    private func publishCardScanProgress(
        _ event: CardScanProgressEvent,
        revision: UInt64,
        sessionID: UUID,
        retryRevision: UInt64?
    ) {
        guard scanRevision == revision,
              scanEvidence.sessionID == sessionID,
              cardScanPhases[event.cardID] == .scanning else { return }
        if let retryRevision {
            guard cardRetryRevisions[event.cardID] == retryRevision else { return }
        }
        if let current = cardScanProgress[event.cardID],
           (event.progress.scannedBytes < current.scannedBytes
            || event.progress.fileCount < current.fileCount) {
            return
        }
        cardScanProgress[event.cardID] = event.progress
    }

    private static func makeCardScanWork(_ cards: [DeveloperCard]) -> [CardScanWork] {
        let sharedDerivedDataCards = cards.filter { $0.sharedScanRole != nil }
        var emittedSharedDerivedData = false
        var work: [CardScanWork] = []
        work.reserveCapacity(cards.count)
        for card in cards {
            if card.sharedScanRole != nil {
                guard !emittedSharedDerivedData else { continue }
                emittedSharedDerivedData = true
                work.append(.derivedData(sharedDerivedDataCards))
            } else {
                work.append(.single(card))
            }
        }
        return work
    }

    /// Runs entirely outside MainActor. Only `CardScanWorkOutput`, whose cardinality is the
    /// number of visible rows rather than filesystem entries, crosses back to the ViewModel.
    private nonisolated static func executeScanWork(
        _ work: CardScanWork,
        home: URL,
        versionedTask: Task<KnownVersionedRoots.ScanResult, Never>?,
        dynamicDiscovery: @Sendable (
            String,
            URL,
            Bool
        ) async throws -> DiscoveryEvidence<WorkflowScanHit>,
        derivedDataSnapshotDiscovery: @Sendable (
            URL,
            @escaping @Sendable (DerivedDataScanProgress) -> Void
        ) async throws -> DerivedDataScanSnapshot,
        progress: @escaping @Sendable (CardScanProgressEvent) -> Void
    ) async -> CardScanWorkOutput? {
        do {
            try Task.checkCancellation()
            switch work {
            case .single(let card):
                let versionedDiscovery: KnownVersionedRoots.ScanResult?
                if case .versionedRoot = card.source {
                    versionedDiscovery = await versionedTask?.value
                    try Task.checkCancellation()
                    guard versionedDiscovery?.wasCancelled != true else { return nil }
                } else {
                    versionedDiscovery = nil
                }
                let result = try await resolveCard(
                    card: card,
                    home: home,
                    versionedDiscovery: versionedDiscovery,
                    dynamicDiscovery: dynamicDiscovery,
                    progress: { snapshot in
                        progress(CardScanProgressEvent(cardID: card.id, progress: snapshot))
                    }
                )
                return CardScanWorkOutput(results: [card.id: result])
            case .derivedData(let cards):
                let snapshot = try await derivedDataSnapshotDiscovery(home) { scanProgress in
                    let cardProgress = CardScanProgress(
                        scannedBytes: scanProgress.scannedBytes,
                        fileCount: scanProgress.fileCount,
                        currentPath: scanProgress.currentPath
                    )
                    for card in cards {
                        progress(CardScanProgressEvent(
                            cardID: card.id,
                            progress: cardProgress
                        ))
                    }
                }
                try Task.checkCancellation()
                var results: [String: CardScanResult] = [:]
                for card in cards {
                    switch card.sharedScanRole {
                    case .derivedDataRoot:
                        let hit = WorkflowScanHit(
                            url: snapshot.rootURL,
                            sizeBytes: snapshot.rootSizeBytes,
                            displayName: snapshot.rootURL.lastPathComponent,
                            note: snapshot.rootURL.path
                        )
                        results[card.id] = CardScanResult(
                            hits: snapshot.rootExists ? [hit] : [],
                            incompleteIssues: snapshot.rootIncompleteIssues,
                            terminalFailure: snapshot.rootSizeBytes == nil
                                && snapshot.rootIncompleteIssues.isEmpty
                        )
                    case .derivedDataProjects:
                        results[card.id] = CardScanResult(
                            hits: snapshot.projects.hits.map { project in
                                WorkflowScanHit(
                                    url: project.url,
                                    sizeBytes: project.sizeBytes,
                                    displayName: project.projectName,
                                    note: project.url.lastPathComponent
                                )
                            },
                            incompleteIssues: snapshot.projects.incompleteIssues
                        )
                    case .none:
                        break
                    }
                }
                return CardScanWorkOutput(results: results)
            }
        } catch is CancellationError {
            return nil
        } catch {
            let diagnostic = ScanFailureDiagnostic(
                source: .workflow,
                stage: .cardResolution,
                reason: .unexpectedFailure,
                error: error
            )
            GSYLog.error(.scan, "workflow.failure \(diagnostic.logFields)")
            return CardScanWorkOutput(results: Dictionary(
                uniqueKeysWithValues: work.cards.map {
                    ($0.id, CardScanResult(hits: [], terminalFailure: true))
                }
            ))
        }
    }

    /// One off-main worker owned by a single card retry token. A versioned-root retry still
    /// uses exactly one shared discovery result for that worker, and its unstructured task is
    /// explicitly tied to the outer worker's cancellation lifetime.
    private nonisolated static func executeCardRetry(
        _ work: CardScanWork,
        home: URL,
        versionedRootDiscovery: @escaping @Sendable (URL) async -> KnownVersionedRoots.ScanResult,
        dynamicDiscovery: @Sendable (
            String,
            URL,
            Bool
        ) async throws -> DiscoveryEvidence<WorkflowScanHit>,
        derivedDataSnapshotDiscovery: @Sendable (
            URL,
            @escaping @Sendable (DerivedDataScanProgress) -> Void
        ) async throws -> DerivedDataScanSnapshot,
        progress: @escaping @Sendable (CardScanProgressEvent) -> Void
    ) async -> CardRetryOutput? {
        let needsVersionedRoots = work.cards.contains { card in
            if case .versionedRoot = card.source { return true }
            return false
        }
        let versionedTask: Task<KnownVersionedRoots.ScanResult, Never>? = needsVersionedRoots
            ? Task.detached(priority: .userInitiated) {
                await versionedRootDiscovery(home)
            }
            : nil
        defer { versionedTask?.cancel() }

        return await withTaskCancellationHandler {
            guard let workOutput = await executeScanWork(
                work,
                home: home,
                versionedTask: versionedTask,
                dynamicDiscovery: dynamicDiscovery,
                derivedDataSnapshotDiscovery: derivedDataSnapshotDiscovery,
                progress: progress
            ), !Task.isCancelled else {
                return nil
            }
            let sharedIncompleteIssues: [ScanIncompleteIssue]?
            if let versionedTask {
                let discovery = await versionedTask.value
                guard !Task.isCancelled else { return nil }
                sharedIncompleteIssues = discovery.incompleteIssues
            } else {
                sharedIncompleteIssues = nil
            }
            return CardRetryOutput(
                workOutput: workOutput,
                sharedIncompleteIssues: sharedIncompleteIssues
            )
        } onCancel: {
            versionedTask?.cancel()
        }
    }

    /// v2026.07.15：扫描结果进入 `@Published` 状态前的唯一 filesystem 空结果边界。
    /// 已完整扫描且物理占用为 0 的目标没有清理收益，不发布 row、也不进入默认选择；
    /// 若同一目标存在 typed incomplete evidence，则 0 只是“不可信的下界”，必须保留
    /// row 并把容量改成 nil，让 UI 显示未知而不是伪装成空目录。
    private static func normalizedForPublication(
        _ result: CardScanResult,
        card: DeveloperCard
    ) -> CardScanResult {
        guard case .filesystem = card.recipe else { return result }
        let hits = result.hits.compactMap { hit -> WorkflowScanHit? in
            guard hit.sizeBytes == 0 else { return hit }
            let hasIncompleteEvidence = !DeletionTargetRevalidator.relevantIssues(
                for: hit.url.path,
                from: result.incompleteIssues
            ).isEmpty
            guard hasIncompleteEvidence else { return nil }
            return WorkflowScanHit(
                url: hit.url,
                sizeBytes: nil,
                displayName: hit.displayName,
                note: hit.note,
                semanticNote: hit.semanticNote,
                managedUninstallIdentifier: hit.managedUninstallIdentifier
            )
        }
        return CardScanResult(
            hits: hits,
            incompleteIssues: result.incompleteIssues,
            terminalFailure: result.terminalFailure
        )
    }

    private static func foldedSelectedHitsForDisplay(
        selection: Set<String>,
        cards: [DeveloperCard],
        cardHits: [String: [WorkflowScanHit]]
    ) -> [WorkflowScanHit] {
        var filesystemHits: [WorkflowScanHit] = []
        var otherHits: [WorkflowScanHit] = []
        for card in cards {
            guard let hits = cardHits[card.id] else { continue }
            let chosen = hits.filter { selection.contains($0.id) }
            if case .filesystem = card.recipe {
                filesystemHits.append(contentsOf: chosen)
            } else {
                otherHits.append(contentsOf: chosen)
            }
        }
        let foldedPaths = Set(Self.foldNestedPaths(filesystemHits.map { $0.url.path }))
        var seenFilesystemPaths: Set<String> = []
        let uniqueFilesystemHits = filesystemHits.filter { hit in
            let path = hit.url.standardizedFileURL.path
            guard foldedPaths.contains(path) else { return false }
            return seenFilesystemPaths.insert(path).inserted
        }
        return uniqueFilesystemHits + otherHits
    }

    private func collapseNestedFilesystemSelections() {
        var selectedFilesystemHits: [WorkflowScanHit] = []
        for card in cards {
            guard case .filesystem = card.recipe,
                  let hits = cardHits[card.id] else { continue }
            selectedFilesystemHits.append(contentsOf: hits.filter { selected.contains($0.id) })
        }
        let kept = Set(Self.foldNestedPaths(selectedFilesystemHits.map { $0.url.path }))
        for hit in selectedFilesystemHits
            where !kept.contains(hit.url.standardizedFileURL.path) {
            selected.remove(hit.id)
        }
    }

    private nonisolated static func minimalNonOverlappingPaths(
        _ paths: [String],
        recipe: DeletionRecipe
    ) -> [String] {
        guard case .filesystem = recipe else { return paths }
        return foldNestedPaths(paths)
    }

    nonisolated static func foldNestedPaths(_ paths: [String]) -> [String] {
        var kept: [String] = []
        let sorted = Array(Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }))
            .sorted { lhs, rhs in
                let lc = lhs.split(separator: "/").count
                let rc = rhs.split(separator: "/").count
                if lc != rc { return lc < rc }
                return lhs < rhs
            }
        for path in sorted {
            if kept.contains(where: { isAncestor($0, of: path) }) { continue }
            kept.append(path)
        }
        return kept
    }

    private nonisolated static func isAncestor(_ ancestor: String, of child: String) -> Bool {
        child == ancestor || child.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    private nonisolated static func resolveCard(card: DeveloperCard,
                                    home: URL,
                                    versionedDiscovery: KnownVersionedRoots.ScanResult?,
                                    dynamicDiscovery: @Sendable (
                                        String,
                                        URL,
                                        Bool
                                    ) async throws -> DiscoveryEvidence<WorkflowScanHit>,
                                    progress: @escaping @Sendable (CardScanProgress) -> Void) async throws -> CardScanResult {
        try Task.checkCancellation()
        switch card.source {
        case .literal(let paths):
            // **v2026.06.22 (P0-5)**：`.literal` 分支历史只走 `FileManager.fileExists`，不展开 glob。
            // 但 [AndroidWorkflow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/AndroidWorkflow.swift) 等卡片实际声明了带 `*` 的路径
            // （如 `~/Library/Caches/Google/AndroidStudio*`），未展开就 `fileExists` 会全部落空，
            // 导致 JetBrains / AndroidStudio 整卡 0 命中。改为：含 `*` 走 parent + fnmatch 枚举。
            var result = CardScanResult(hits: [])
            var expandedPaths: [String] = []
            for raw in paths {
                try Task.checkCancellation()
                let expandedRaw = (raw as NSString).expandingTildeInPath
                let expansion = Self.expandGlob(expandedRaw)
                result.merge(incompleteIssues: expansion.incompleteIssues)
                expandedPaths.append(contentsOf: expansion.paths)
            }
            // v2026.07.16 性能/容量合同：filesystem 卡可能同时声明父根与子根
            // （历史 npm 卡为 ~/.npm + ~/.npm/_cacache）。逐 literal 扫描会把同一子树
            // 读两遍并把展示容量双计，而删除阶段又会 fold 成父根，前后语义不一致。
            // 在所有卡共享的扫描边界先折叠，禁止单卡硬编码修补。
            let pathsToScan = minimalNonOverlappingPaths(
                expandedPaths,
                recipe: card.recipe
            )
            var completedBytes: Int64 = 0
            var completedFiles = 0
            for matchedPath in pathsToScan {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: matchedPath)
                let filesystem = try await scanFilesystemIfNeeded(
                    url: url,
                    recipe: card.recipe,
                    accumulatedBytes: completedBytes,
                    accumulatedFiles: completedFiles,
                    progress: progress
                )
                result.merge(filesystem: filesystem)
                completedBytes = saturatingAdd(completedBytes, max(0, filesystem.sizeBytes ?? 0))
                completedFiles = saturatingAdd(completedFiles, max(0, filesystem.fileCount))
                result.hits.append(WorkflowScanHit(
                    url: url,
                    sizeBytes: filesystem.sizeBytes,
                    displayName: url.lastPathComponent,
                    note: url.path
                ))
            }
            return result
        case .versionedRoot(let ruleID):
            guard let versionedDiscovery else {
                assertionFailure("versionedRoot card resolved without its scan-session discovery result")
                // There is no trustworthy filesystem scope when the shared discovery result is
                // missing. Inventing HOME as a fallback would make one card's invariant failure
                // look like every selected sibling was incompletely scanned. Keep the failure in
                // diagnostics and fail this card closed as an empty result instead.
                return CardScanResult(hits: [])
            }
            let discoveredHits = versionedDiscovery.hits.filter { $0.ruleID == ruleID }
            let retainedPaths = Set(minimalNonOverlappingPaths(
                discoveredHits.map { $0.url.path },
                recipe: card.recipe
            ))
            var seenPaths = Set<String>()
            let hits = discoveredHits.filter { hit in
                let path = hit.url.standardizedFileURL.path
                return retainedPaths.contains(path) && seenPaths.insert(path).inserted
            }
            var result = CardScanResult(hits: [])
            var completedBytes: Int64 = 0
            var completedFiles = 0
            for hit in hits {
                try Task.checkCancellation()
                let filesystem = try await scanFilesystemIfNeeded(
                    url: hit.url,
                    recipe: card.recipe,
                    accumulatedBytes: completedBytes,
                    accumulatedFiles: completedFiles,
                    progress: progress
                )
                result.merge(filesystem: filesystem)
                completedBytes = saturatingAdd(completedBytes, max(0, filesystem.sizeBytes ?? 0))
                completedFiles = saturatingAdd(completedFiles, max(0, filesystem.fileCount))
                // 保留语义 key 到发布边界；View 依据当前环境 locale 投影，切语言无需重扫。
                let localizedName = hit.displayName
                let composedName: String
                if let groupKey = hit.groupKey, !groupKey.isEmpty {
                    composedName = "\(localizedName) · \(groupKey)"
                } else {
                    composedName = localizedName
                }
                result.hits.append(WorkflowScanHit(
                    url: hit.url,
                    sizeBytes: filesystem.sizeBytes,
                    displayName: composedName,
                    note: hit.versionName
                ))
            }
            return result
        case .vendor:
            // PR-5 阶段不接 vendor 源——卡片侧目前没人用，留位避免编译警告。
            return CardScanResult(hits: [])
        case .dynamicScanner(let scannerID):
            let isFilesystemRecipe: Bool
            if case .filesystem = card.recipe {
                isFilesystemRecipe = true
            } else {
                isFilesystemRecipe = false
            }
            let discovery: DiscoveryEvidence<WorkflowScanHit>
            do {
                discovery = try await dynamicDiscovery(
                    scannerID,
                    home,
                    !isFilesystemRecipe
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let diagnostic = ScanFailureDiagnostic(
                    source: .workflow,
                    stage: .dynamicDiscovery,
                    reason: .unexpectedFailure,
                    error: error
                )
                GSYLog.error(.scan, "workflow.failure \(diagnostic.logFields)")
                // `WorkflowRegistry.resolveWithEvidence` returns filesystem failures as scoped
                // ScanIncompleteIssue values and throws only for cancellation/unexpected provider
                // failures. A generic Error has no trustworthy path scope, so fabricating HOME
                // here would contaminate every sibling deletion. Preserve only typed evidence.
                return CardScanResult(hits: [], terminalFailure: true)
            }
            let resolved: [WorkflowScanHit]
            if isFilesystemRecipe {
                let retainedPaths = Set(minimalNonOverlappingPaths(
                    discovery.hits.map { $0.url.path },
                    recipe: card.recipe
                ))
                var seenPaths = Set<String>()
                resolved = discovery.hits.filter { hit in
                    let path = hit.url.standardizedFileURL.path
                    return retainedPaths.contains(path) && seenPaths.insert(path).inserted
                }
            } else {
                resolved = discovery.hits
            }
            guard isFilesystemRecipe else {
                return CardScanResult(
                    hits: resolved,
                    incompleteIssues: discovery.incompleteIssues
                )
            }
            var result = CardScanResult(
                hits: [],
                incompleteIssues: discovery.incompleteIssues
            )
            result.hits.reserveCapacity(resolved.count)
            var completedBytes: Int64 = 0
            var completedFiles = 0
            for hit in resolved {
                try Task.checkCancellation()
                let filesystem = try await scanFilesystemIfNeeded(
                    url: hit.url,
                    recipe: card.recipe,
                    accumulatedBytes: completedBytes,
                    accumulatedFiles: completedFiles,
                    progress: progress
                )
                result.merge(filesystem: filesystem)
                completedBytes = saturatingAdd(completedBytes, max(0, filesystem.sizeBytes ?? 0))
                completedFiles = saturatingAdd(completedFiles, max(0, filesystem.fileCount))
                result.hits.append(WorkflowScanHit(
                    url: hit.url,
                    sizeBytes: filesystem.sizeBytes,
                    displayName: hit.displayName,
                    note: hit.note,
                    semanticNote: hit.semanticNote,
                    managedUninstallIdentifier: hit.managedUninstallIdentifier
                ))
            }
            return result
        }
    }

    private nonisolated static func scanFilesystemIfNeeded(
        url: URL,
        recipe: DeletionRecipe,
        accumulatedBytes: Int64,
        accumulatedFiles: Int,
        progress: @escaping @Sendable (CardScanProgress) -> Void
    ) async throws -> FilesystemScanResult {
        guard case .filesystem = recipe else {
            return FilesystemScanResult(
                sizeBytes: nil,
                fileCount: 0,
                incompleteIssues: [],
                terminalFailure: false
            )
        }
        return try await scanFilesystem(at: url) { rootProgress in
            progress(CardScanProgress(
                scannedBytes: saturatingAdd(accumulatedBytes, rootProgress.scannedBytes),
                fileCount: saturatingAdd(accumulatedFiles, rootProgress.fileCount),
                currentPath: rootProgress.currentPath
            ))
        }
    }

    /// Workflow-owned filesystem scan. BulkScanner supplies physical allocated size and
    /// explicit permission/TCC/partial events in one pass, so deletion safety no longer
    /// borrows evidence from MainView's unrelated ScanCoordinator session.
    private nonisolated static func scanFilesystem(
        at url: URL,
        progress: @escaping @Sendable (FilesystemScanProgress) -> Void
    ) async throws -> FilesystemScanResult {
        try Task.checkCancellation()
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isDirectory != true {
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                progress(FilesystemScanProgress(
                    scannedBytes: max(0, bytes),
                    fileCount: 1,
                    currentPath: url.path
                ))
                return FilesystemScanResult(
                    sizeBytes: bytes,
                    fileCount: 1,
                    incompleteIssues: [],
                    terminalFailure: false
                )
            }
        } catch {
            let issue = scanIncompleteIssue(
                path: url.path,
                stage: .metadata,
                posixErrorCode: posixErrorCode(from: error)
            )
            let diagnostic = ScanFailureDiagnostic(
                source: .workflow,
                stage: .rootMetadata,
                reason: .init(issue.reason),
                error: error
            )
            GSYLog.warning(
                .scan,
                "workflow.failure \(diagnostic.logFields) path=\(url.path)"
            )
            return FilesystemScanResult(
                sizeBytes: nil,
                fileCount: 0,
                incompleteIssues: [issue],
                terminalFailure: true
            )
        }

        let scanner = BulkScanner(options: .default)
        var sizeBytes: Int64?
        var fileCount = 0
        var incompleteIssues: [ScanIncompleteIssue] = []
        var didFinish = false
        var terminalFailure = false
        let session = scanner.scanSession(root: url, delivery: .summaryWithProgress)
        do {
            for await event in session.events {
                try Task.checkCancellation()
                switch event {
                case .heartbeat:
                    continue
                case .progress(let scannedBytes, let enumeratedFiles):
                    progress(FilesystemScanProgress(
                        scannedBytes: max(0, scannedBytes),
                        fileCount: max(0, enumeratedFiles),
                        currentPath: url.path
                    ))
                case .permissionDenied(let path):
                    incompleteIssues.append(ScanIncompleteIssue(
                        path: path,
                        reason: .permissionDenied,
                        stage: .open
                    ))
                case .tccProtectedSkipped(let path):
                    incompleteIssues.append(ScanIncompleteIssue(
                        path: path,
                        reason: .tccProtectedSkipped,
                        stage: .open
                    ))
                case .failed(let error):
                    terminalFailure = true
                    let issue: ScanIncompleteIssue
                    let failurePath: String
                    let failureCode: Int32?
                    switch error {
                    case .cannotEnumerate(let path, let stage, let posixErrorCode):
                        failurePath = path
                        failureCode = posixErrorCode
                        issue = scanIncompleteIssue(
                            path: path,
                            stage: stage,
                            posixErrorCode: posixErrorCode
                        )
                    }
                    incompleteIssues.append(issue)
                    let diagnostic = ScanFailureDiagnostic(
                        source: .workflow,
                        stage: .bulkScan,
                        reason: .init(issue.reason),
                        posixErrorCode: failureCode
                    )
                    GSYLog.warning(
                        .scan,
                        "workflow.failure \(diagnostic.logFields) "
                            + "path=\(failurePath) root=\(url.path)"
                    )
                case .incomplete(let issue):
                    incompleteIssues.append(issue)
                case .finished(let summary):
                    didFinish = true
                    sizeBytes = summary.totalAllocatedBytes
                    fileCount = summary.fileCount
                    progress(FilesystemScanProgress(
                        scannedBytes: max(0, summary.totalAllocatedBytes),
                        fileCount: max(0, summary.fileCount),
                        currentPath: url.path
                    ))
                    incompleteIssues.append(contentsOf: summary.incompleteIssues)
                    if summary.completionStatus == .partial,
                       summary.incompleteIssues.isEmpty {
                        incompleteIssues.append(ScanIncompleteIssue(
                            path: url.path,
                            reason: .enumerationFailed,
                            stage: .enumerate
                        ))
                    }
                    if summary.permissionDeniedCount > 0,
                       !incompleteIssues.contains(where: { $0.reason == .permissionDenied }) {
                        incompleteIssues.append(ScanIncompleteIssue(
                            path: url.path,
                            reason: .permissionDenied,
                            stage: .open
                        ))
                    }
                    if summary.tccProtectedSkippedCount > 0,
                       !incompleteIssues.contains(where: { $0.reason == .tccProtectedSkipped }) {
                        incompleteIssues.append(ScanIncompleteIssue(
                            path: url.path,
                            reason: .tccProtectedSkipped,
                            stage: .open
                        ))
                    }
                case .node, .nodes, .cacheDirTagged:
                    break
                }
            }
        } catch {
            session.cancel()
            await session.waitForTermination()
            throw error
        }
        await session.waitForTermination()
        try Task.checkCancellation()
        if !didFinish {
            incompleteIssues.append(ScanIncompleteIssue(
                path: url.path,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
        }
        return FilesystemScanResult(
            sizeBytes: sizeBytes,
            fileCount: fileCount,
            incompleteIssues: incompleteIssues,
            terminalFailure: terminalFailure || !didFinish
        )
    }

    private nonisolated static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }

    private nonisolated static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }

    /// **v2026.06.22 (P0-5)**：展开 `.literal` 路径中的 `*` 通配符（仅展开最末段，不递归）。
    ///
    /// 设计取舍：
    /// - 不引第三方 glob 库，直接走 `fnmatch(3)` —— macOS 自带、零依赖、与 shell 语义一致；
    /// - **仅展开 last component** 的 `*`（如 `~/Library/Caches/JetBrains/IntelliJIdea*`），
    ///   不支持 `**` / 中间段 glob —— 现有 [AndroidWorkflow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/AndroidWorkflow.swift) 与
    ///   [WebNodeWorkflow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/WebNodeWorkflow.swift)
    ///   声明的 glob 全是末段形态，扩大支持面会增加误命中风险，按需再加；
    /// - 不含 `*` 时退化为单条 `fileExists` 判断，与历史行为完全等价。
    private nonisolated static func expandGlob(_ pattern: String) -> PathExpansionResult {
        guard pattern.contains("*") else {
            return PathExpansionResult(
                paths: FileManager.default.fileExists(atPath: pattern) ? [pattern] : [],
                incompleteIssues: []
            )
        }
        let url = URL(fileURLWithPath: pattern)
        let parent = url.deletingLastPathComponent().path
        let lastComponent = url.lastPathComponent
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: parent)
        } catch {
            let issue = scanIncompleteIssue(
                path: parent,
                stage: .enumerate,
                posixErrorCode: posixErrorCode(from: error)
            )
            let diagnostic = ScanFailureDiagnostic(
                source: .workflow,
                stage: .globExpansion,
                reason: .init(issue.reason),
                error: error
            )
            GSYLog.warning(
                .scan,
                "workflow.failure \(diagnostic.logFields) parent=\(parent)"
            )
            return PathExpansionResult(
                paths: [],
                incompleteIssues: [issue]
            )
        }
        let paths = entries.compactMap { name -> String? in
            let matched = name.withCString { nameCStr in
                lastComponent.withCString { patternCStr in
                    fnmatch(patternCStr, nameCStr, 0) == 0
                }
            }
            guard matched else { return nil }
            return (parent as NSString).appendingPathComponent(name)
        }
        return PathExpansionResult(
            paths: paths,
            incompleteIssues: []
        )
    }

    private nonisolated static func scanIncompleteIssue(
        path: String,
        stage: ScanIssueStage,
        posixErrorCode: Int32?
    ) -> ScanIncompleteIssue {
        let reason: ScanIncompleteReason
        if let posixErrorCode,
           posixErrorCode == EACCES || posixErrorCode == EPERM {
            reason = .permissionDenied
        } else if stage == .metadata {
            reason = .metadataUnavailable
        } else {
            reason = .enumerationFailed
        }
        return ScanIncompleteIssue(
            path: path,
            reason: reason,
            stage: stage,
            posixErrorCode: posixErrorCode
        )
    }

    private nonisolated static func posixErrorCode(from error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(exactly: nsError.code)
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return EACCES
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return posixErrorCode(from: underlying)
        }
        return nil
    }

    public static func formatBytes(_ bytes: Int64, locale: Locale) -> String {
        AppLocalization.byteCount(bytes, locale: locale)
    }

    /// PR-9 测试 hook：注入 cardHits 用于单测，**仅在测试代码中调用**。
    internal func setTestHits(_ hits: [String: [WorkflowScanHit]]) {
        self.cardHits = hits
        for (cardID, hitList) in hits {
            cardTotalBytes[cardID] = hitList.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) }
            if cardScanPhases[cardID] == nil {
                cardScanPhases[cardID] = .completed
            }
        }
    }

    internal func setTestCardIncompleteIssues(_ issues: [String: [ScanIncompleteIssue]]) {
        cardIncompleteIssues = issues
        for (cardID, cardIssues) in issues where !cardIssues.isEmpty {
            cardScanPhases[cardID] = (cardHits[cardID] ?? []).isEmpty ? .failed : .partial
        }
    }

    /// PR-9 测试 hook：注入 cards 用于单测，**仅在测试代码中调用**。
    internal func setTestCards(_ cards: [DeveloperCard]) {
        self.cards = cards
        for card in cards where cardScanPhases[card.id] == nil {
            cardScanPhases[card.id] = .completed
        }
    }

    internal func setTestSelection(_ selection: Set<String>) {
        self.selected = selection
        explicitFilesystemSelectionPaths.removeAll()
        collapseNestedFilesystemSelections()
    }

    internal func setTestScanEvidence(_ evidence: WorkflowScanEvidence) {
        scanRevision = evidence.revision
        scanEvidence = evidence
    }

    /// v2026.07.16 回归 hook：只把确定性虚拟 lifecycle event 送入与生产相同的
    /// revision/identity 投影边界；测试不会启动 `simctl` 或改动真实 Simulator 资源。
    internal func applyTestSimulatorUninstallEvent(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        sourceIntent: SimulatorUninstallIntent
    ) {
        applySimulatorUninstallEvent(event, sourceIntent: sourceIntent)
    }

    /// 回归锁：生产默认 managed executor 必须等待系统事务自然终止，不能退回固定 timeout。
    internal var testingSimulatorTerminalWaitPolicy: SubprocessExecutor.TerminalWaitPolicy {
        simulatorCoordinator.terminalWaitPolicy
    }

    /// **v2026.06.22 (P0-5) 测试 hook**：把 private static [expandGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)
    /// 暴露给同模块测试，覆盖 fnmatch 末段 `*` 展开行为。生产路径不应调用。
    internal static func _testing_expandGlob(_ pattern: String) -> [String] {
        return expandGlob(pattern).paths
    }
}
