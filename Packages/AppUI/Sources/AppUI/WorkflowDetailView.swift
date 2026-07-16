import SwiftUI
import Foundation
import Darwin
import ScanKit
import LogKit
import SafetyKit

/// 工作流扫描结果既可能携带真实名称，也可能携带 String Catalog key。
/// 保留语义到 View 投影，避免扫描时把启动语言固化进长生命周期结果。
enum WorkflowHitNamePresentation {
    static func string(_ value: String, locale: Locale) -> String {
        let separator = " · "
        guard let range = value.range(of: separator) else {
            return AppLocalization.string(value, locale: locale)
        }
        let base = String(value[..<range.lowerBound])
        let suffix = String(value[range.upperBound...])
        return "\(AppLocalization.string(base, locale: locale))\(separator)\(suffix)"
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
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.workflow = workflow
        self.pipeline = pipeline
        _viewModel = StateObject(wrappedValue: WorkflowDetailViewModel(
            workflow: workflow,
            home: home
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
        .task {
            await viewModel.bootstrap()
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
            case .preflightNotice(let id, let rejections):
                DeletionPreflightNoticeSheet(
                    notice: DeletionPreflightNotice(id: id, rejections: rejections)
                ) {
                    viewModel.activeSheet = nil
                }
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
        if viewModel.cardLoading.contains(card.id) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("workflow.detail.scanning", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Task { await viewModel.refreshAll() }
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
                Text(WorkflowDetailViewModel.formatBytes(size))
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
                Task { await viewModel.refreshAll() }
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
        case .loading:
            ProgressView().controlSize(.small)
        case .empty:
            capacityChip(
                AppLocalization.string("workflow.card.empty_chip", locale: locale),
                color: .secondary
            )
        case .known(let bytes):
            Text(WorkflowDetailViewModel.formatBytes(bytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        case .partialUnknown(let knownBytes):
            capacityChip(
                AppLocalization.format(
                    "workflow.card.partial_size %@",
                    locale: locale,
                    arguments: [WorkflowDetailViewModel.formatBytes(knownBytes)]
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
                WorkflowDetailViewModel.formatBytes(confirmation.totalBytes)
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
            let skipped = completion.skippedItems.count
            let isCompleteSuccess = failed == 0 && skipped == 0
            let isCompleteFailure = succeeded == 0 && failed > 0 && skipped == 0
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
                        titleKey: "workflow.detail.managed_uninstall.result.skipped",
                        count: completion.skippedItems.count,
                        color: .orange
                    )
                }
                let rows = intent.items.map { item -> WorkflowDetailViewModel.SimulatorUninstallItemProgress in
                    if let outcome = completion.outcomes.first(where: { $0.item.hitID == item.hitID }) {
                        return .init(
                            item: item,
                            status: outcome.isSuccess
                                ? .succeeded
                                : .failed(exitCode: outcome.exitCode, detail: outcome.truncatedOutput)
                        )
                    }
                    return .init(item: item, status: .skipped)
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
                                    Text(verbatim: "· \(WorkflowDetailViewModel.formatBytes(size))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if case .failed(_, let detail) = row.status, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.red)
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
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        }
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
        case loading
        case empty
        case known(bytes: Int64)
        case partialUnknown(knownBytes: Int64)
        case allUnknown
        case failed
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
    @Published public private(set) var cardLoading: Set<String> = []
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

    /// 当前正在显示的 sheet 类型。
    /// - `.simulatorUninstall`：Simulator 系统管理卸载的完整状态 sheet
    /// - `.result(payload)`：OperationResultSheet（trash 完成后展示结构化结果）
    enum ActiveSheet: Identifiable, Equatable {
        case deleteConfirm(WorkflowDeleteConfirmation)
        case preflightNotice(id: UUID, rejections: [DeletionPreflight.Rejection])
        case simulatorUninstall
        case result(OperationResultCompletion)

        public var id: String {
            switch self {
            case .deleteConfirm(let confirmation):
                return "deleteConfirm-\(confirmation.id.uuidString)"
            case .preflightNotice(let id, _):
                return "preflightNotice-\(id.uuidString)"
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
        case running
        case succeeded
        case failed(exitCode: Int32, detail: String)
        case skipped
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
    /// **v2026.06.22 (P0-1)**：UndoHistory 写入入口。默认 `UndoHistoryStore.shared`，
    /// 测试可注入临时目录 store。
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
    private var simulatorUninstallStopControl: SimulatorDeleteCoordinator.StopControl?
    private var pendingConfirmedDeleteIntent: WorkflowDeletionIntent?
    private var deletionInteractionCoordinator: DeletionInteractionCoordinator?
    private var didBootstrap: Bool = false
    private var scanRevision: UInt64 = 0
    /// 本轮扫描中用户显式选择的 filesystem 路径。卡片是并发发布的；若较慢卡片
    /// 随后完成，其 safe 默认选择不得覆盖用户已经做出的父/子粒度选择。
    private var explicitFilesystemSelectionPaths: [String: String] = [:]
    private let maxConcurrentCardLoads = 2

    public init(workflow: any DeveloperWorkflow,
                home: URL,
                simulatorCoordinator: SimulatorDeleteCoordinator? = nil,
                undoHistoryStore: UndoHistoryStore = .shared,
                versionedRootDiscovery: (@Sendable (URL) async -> KnownVersionedRoots.ScanResult)? = nil,
                dynamicDiscovery: (@Sendable (
                    String,
                    URL,
                    Bool
                ) async throws -> DiscoveryEvidence<WorkflowScanHit>)? = nil) {
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
        self.versionedRootDiscovery = versionedRootDiscovery ?? { home in
            await Task.detached(priority: .userInitiated) {
                KnownVersionedRoots.scanAllWithEvidence(home: home)
            }.value
        }
        self.dynamicDiscovery = dynamicDiscovery ?? { scannerID, home, includeFilesystemSizes in
            try await WorkflowRegistry.resolveWithEvidence(
                scannerID: scannerID,
                home: home,
                includeFilesystemSizes: includeFilesystemSizes
            )
        }
    }

    public var isAnyLoading: Bool { !cardLoading.isEmpty }

    public var isDeletionTransactionActive: Bool {
        if isPreparingDeletion || isDeleting || pendingConfirmedDeleteIntent != nil {
            return true
        }
        switch activeSheet {
        case .deleteConfirm, .preflightNotice, .simulatorUninstall:
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
        if cardLoading.contains(cardID) { return .loading }
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
                arguments: [itemCount, Self.formatBytes(bytes)]
            )
        case .partialUnknown(let itemCount, let knownBytes):
            return AppLocalization.format(
                "workflow.detail.footer.summary.partial %lld %@",
                locale: locale,
                arguments: [itemCount, Self.formatBytes(knownBytes)]
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
                        bundleIDPrefix: card.runningBundleIDPrefix
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
                runningBundleIDPrefix: candidate.bundleIDPrefix
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
        guard !didBootstrap else { return }
        didBootstrap = true
        await runScan()
    }

    public func refreshAll() async {
        guard !isDeletionTransactionActive else { return }
        await runScan()
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
                            )
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
                    activeSheet = .preflightNotice(id: UUID(), rejections: block.rejections)
                    return
                case .cancelled:
                    return
                }
            } catch {
                activeSheet = .preflightNotice(
                    id: UUID(),
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
              current.id == confirmation.id,
              current.intent.scanRevision == scanEvidence.revision,
              current.intent.scanSessionID == scanEvidence.sessionID,
              pendingConfirmedDeleteIntent == nil else { return false }

        let originalIntent = confirmation.intent
        let authorizedInteraction: DeletionAuthorizedInteraction?
        if originalIntent.filesystemPaths.isEmpty {
            authorizedInteraction = nil
        } else {
            guard let prepared = originalIntent.preparedInteraction,
                  let coordinator = deletionInteractionCoordinator else {
                GSYLog.error(.trash, "Workflow 删除确认缺少统一协调器快照")
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
                activeSheet = .preflightNotice(id: UUID(), rejections: block.rejections)
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
            activeSheet = .preflightNotice(
                id: UUID(),
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
                activeSheet = .preflightNotice(
                    id: UUID(),
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
                activeSheet = .preflightNotice(id: UUID(), rejections: block.rejections)
                return
            }
            let result = completed.result
            if let outcome = result.outcome {
                movedPairs = outcome.movedPairs.map { ($0.originalPath, $0.trashedPath) }
            } else {
                movedPairs = result.pairs
            }

            // 只消费确认前冻结的 path → hit 映射；执行阶段不能回读新一轮 cardHits。
            for path in movedPairs.map({ $0.0 }) {
                succeededFilesystemHitIDs.formUnion(intent.filesystemHitIDsByPath[path] ?? [])
            }
            selected.subtract(succeededFilesystemHitIDs)
            removeHitsFromVisibleState(succeededFilesystemHitIDs)
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
            stopControl: stopControl
        ) { [weak self] event in
            await self?.applySimulatorUninstallEvent(event, operationID: intent.id)
        }
        simulatorUninstallStopControl = nil
        guard case .executing(let currentIntent, _) = simulatorUninstallState,
              currentIntent.id == intent.id else { return }

        let succeededIDs = Set(
            completion.outcomes.filter(\.isSuccess).map(\.item.hitID)
        )
        selected.subtract(succeededIDs)
        removeHitsFromVisibleState(succeededIDs)
        simulatorUninstallState = .finished(intent, completion)
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
        operationID: UUID
    ) {
        guard case .executing(let intent, var progress) = simulatorUninstallState,
              intent.id == operationID else { return }
        switch event {
        case .started(let index, _, let item):
            progress.currentIndex = index
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == item.hitID }) {
                progress.rows[rowIndex].status = .running
            }
        case .finished(_, _, let outcome):
            progress.completedCount += 1
            if let rowIndex = progress.rows.firstIndex(where: { $0.item.hitID == outcome.item.hitID }) {
                progress.rows[rowIndex].status = outcome.isSuccess
                    ? .succeeded
                    : .failed(exitCode: outcome.exitCode, detail: outcome.truncatedOutput)
            }
        }
        simulatorUninstallState = .executing(intent, progress)
    }

    /// 从已发布卡片投影中只移除真实成功项，并重算受影响卡片容量。
    /// 不触发全页 runScan，所以无关 Card 不会一起进入 loading。
    private func removeHitsFromVisibleState(_ hitIDs: Set<String>) {
        guard !hitIDs.isEmpty else { return }
        for hitID in hitIDs {
            explicitFilesystemSelectionPaths.removeValue(forKey: hitID)
        }
        for cardID in Array(cardHits.keys) {
            let remaining = (cardHits[cardID] ?? []).filter { !hitIDs.contains($0.id) }
            cardHits[cardID] = remaining
            cardTotalBytes[cardID] = remaining.reduce(0) { $0 &+ max(0, $1.sizeBytes ?? 0) }
        }
    }

    private struct CardScanResult: Sendable {
        var hits: [WorkflowScanHit]
        var incompleteIssues: [ScanIncompleteIssue] = []

        mutating func merge(incompleteIssues: [ScanIncompleteIssue]) {
            self.incompleteIssues.append(contentsOf: incompleteIssues)
        }
    }

    private struct FilesystemScanResult: Sendable {
        let sizeBytes: Int64?
        let incompleteIssues: [ScanIncompleteIssue]
    }

    private struct PathExpansionResult: Sendable {
        let paths: [String]
        let incompleteIssues: [ScanIncompleteIssue]
    }

    private func runScan() async {
        scanRevision &+= 1
        let revision = scanRevision
        let sessionID = UUID()
        cardHits.removeAll()
        cardTotalBytes.removeAll()
        cardIncompleteIssues.removeAll()
        cardLoading.removeAll()
        selected.removeAll()
        explicitFilesystemSelectionPaths.removeAll()
        pendingConfirmedDeleteIntent = nil
        scanEvidence = WorkflowScanEvidence(revision: revision, sessionID: sessionID)
        cards = workflow.cards(home: home)
        for card in cards where card.risk == .safe {
            expanded.insert(card.id)
        }
        await loadAllCards(revision: revision, sessionID: sessionID)
    }

    private func loadAllCards(revision: UInt64, sessionID: UUID) async {
        let cardsSnapshot = cards
        let needsVersionedRoots = cardsSnapshot.contains { card in
            if case .versionedRoot = card.source { return true }
            return false
        }
        let versionedDiscovery: KnownVersionedRoots.ScanResult?
        if needsVersionedRoots {
            versionedDiscovery = await versionedRootDiscovery(home)
        } else {
            versionedDiscovery = nil
        }
        guard revision == scanRevision, scanEvidence.sessionID == sessionID else { return }

        if let versionedDiscovery {
            scanEvidence = WorkflowScanEvidence(
                revision: revision,
                sessionID: sessionID,
                incompleteIssues: scanEvidence.incompleteIssues
                    + versionedDiscovery.incompleteIssues
            )
        }

        var startIndex = 0
        while startIndex < cardsSnapshot.count {
            let endIndex = min(startIndex + maxConcurrentCardLoads, cardsSnapshot.count)
            let batch = Array(cardsSnapshot[startIndex..<endIndex])
            startIndex = endIndex

            for card in batch {
                cardLoading.insert(card.id)
            }

            // v2026.07.15：每张卡完成就立刻发布。旧实现先 collect 整个 batch，
            // Devices 的只读查询会被同批 Runtime 的递归容量扫描拖住，两张卡一起
            // loading 数分钟；这里消除 batch barrier，让慢卡只影响自己。
            await withTaskGroup(of: (String, CardScanResult).self) { group in
                for card in batch {
                    let cardID = card.id
                    group.addTask { [home, versionedDiscovery, dynamicDiscovery] in
                        let result = await Self.resolveCard(
                            card: card,
                            home: home,
                            versionedDiscovery: versionedDiscovery,
                            dynamicDiscovery: dynamicDiscovery
                        )
                        return (cardID, result)
                    }
                }
                for await (cardID, result) in group {
                    guard revision == scanRevision,
                          scanEvidence.sessionID == sessionID else {
                        group.cancelAll()
                        return
                    }
                    guard let card = cardsSnapshot.first(where: { $0.id == cardID }) else {
                        cardLoading.remove(cardID)
                        continue
                    }
                    let published = Self.normalizedForPublication(result, card: card)
                    cardHits[cardID] = published.hits
                    cardTotalBytes[cardID] = published.hits.reduce(0) {
                        $0 &+ max(0, $1.sizeBytes ?? 0)
                    }
                    cardIncompleteIssues[cardID] = published.incompleteIssues
                    cardLoading.remove(cardID)
                    scanEvidence = WorkflowScanEvidence(
                        revision: revision,
                        sessionID: sessionID,
                        incompleteIssues: scanEvidence.incompleteIssues
                            + published.incompleteIssues
                    )
                    if card.risk == .safe,
                       case .filesystem = card.recipe {
                        for hit in published.hits where shouldApplyDefaultSelection(to: hit) {
                            selected.insert(hit.id)
                        }
                    }
                    collapseNestedFilesystemSelections()
                }
            }
        }
        collapseNestedFilesystemSelections()
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
            incompleteIssues: result.incompleteIssues
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

    static func foldNestedPaths(_ paths: [String]) -> [String] {
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

    private static func isAncestor(_ ancestor: String, of child: String) -> Bool {
        child == ancestor || child.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    private static func resolveCard(card: DeveloperCard,
                                    home: URL,
                                    versionedDiscovery: KnownVersionedRoots.ScanResult?,
                                    dynamicDiscovery: @Sendable (
                                        String,
                                        URL,
                                        Bool
                                    ) async throws -> DiscoveryEvidence<WorkflowScanHit>) async -> CardScanResult {
        switch card.source {
        case .literal(let paths):
            // **v2026.06.22 (P0-5)**：`.literal` 分支历史只走 `FileManager.fileExists`，不展开 glob。
            // 但 [AndroidWorkflow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/AndroidWorkflow.swift) 等卡片实际声明了带 `*` 的路径
            // （如 `~/Library/Caches/Google/AndroidStudio*`），未展开就 `fileExists` 会全部落空，
            // 导致 JetBrains / AndroidStudio 整卡 0 命中。改为：含 `*` 走 parent + fnmatch 枚举。
            var result = CardScanResult(hits: [])
            for raw in paths {
                let expandedRaw = (raw as NSString).expandingTildeInPath
                let expansion = Self.expandGlob(expandedRaw)
                result.merge(incompleteIssues: expansion.incompleteIssues)
                for matchedPath in expansion.paths {
                    let url = URL(fileURLWithPath: matchedPath)
                    let filesystem = await scanFilesystemIfNeeded(url: url, recipe: card.recipe)
                    result.merge(incompleteIssues: filesystem.incompleteIssues)
                    result.hits.append(WorkflowScanHit(
                        url: url,
                        sizeBytes: filesystem.sizeBytes,
                        displayName: url.lastPathComponent,
                        note: url.path
                    ))
                }
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
            let hits = versionedDiscovery.hits.filter { $0.ruleID == ruleID }
            var result = CardScanResult(hits: [])
            for hit in hits {
                let filesystem = await scanFilesystemIfNeeded(url: hit.url, recipe: card.recipe)
                result.merge(incompleteIssues: filesystem.incompleteIssues)
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
                return CardScanResult(hits: [])
            } catch {
                GSYLog.error(.scan, "Workflow 动态发现异常 scannerID=\(scannerID) error=\(error)")
                // `WorkflowRegistry.resolveWithEvidence` returns filesystem failures as scoped
                // ScanIncompleteIssue values and throws only for cancellation/unexpected provider
                // failures. A generic Error has no trustworthy path scope, so fabricating HOME
                // here would contaminate every sibling deletion. Preserve only typed evidence.
                return CardScanResult(hits: [])
            }
            let resolved = discovery.hits
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
            for hit in resolved {
                let filesystem = await scanFilesystemIfNeeded(url: hit.url, recipe: card.recipe)
                result.merge(incompleteIssues: filesystem.incompleteIssues)
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

    private static func scanFilesystemIfNeeded(
        url: URL,
        recipe: DeletionRecipe
    ) async -> FilesystemScanResult {
        guard case .filesystem = recipe else {
            return FilesystemScanResult(
                sizeBytes: nil,
                incompleteIssues: []
            )
        }
        return await scanFilesystem(at: url)
    }

    /// Workflow-owned filesystem scan. BulkScanner supplies physical allocated size and
    /// explicit permission/TCC/partial events in one pass, so deletion safety no longer
    /// borrows evidence from MainView's unrelated ScanCoordinator session.
    private static func scanFilesystem(at url: URL) async -> FilesystemScanResult {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isDirectory != true {
                return FilesystemScanResult(
                    sizeBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                    incompleteIssues: []
                )
            }
        } catch {
            let issue = scanIncompleteIssue(
                path: url.path,
                stage: .metadata,
                posixErrorCode: posixErrorCode(from: error)
            )
            GSYLog.warning(.scan, "Workflow 根路径 metadata 读取失败 path=\(url.path) error=\(error)")
            return FilesystemScanResult(
                sizeBytes: nil,
                incompleteIssues: [issue]
            )
        }

        let scanner = BulkScanner(options: .default)
        var sizeBytes: Int64?
        var incompleteIssues: [ScanIncompleteIssue] = []
        var didFinish = false
        for await event in scanner.scan(root: url) {
            switch event {
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
                let issue: ScanIncompleteIssue
                switch error {
                case .cannotEnumerate(let path, let stage, let posixErrorCode):
                    issue = scanIncompleteIssue(
                        path: path,
                        stage: stage,
                        posixErrorCode: posixErrorCode
                    )
                }
                incompleteIssues.append(issue)
                GSYLog.warning(.scan, "Workflow BulkScanner 失败 root=\(url.path) error=\(error)")
            case .incomplete(let issue):
                incompleteIssues.append(issue)
            case .finished(let summary):
                didFinish = true
                sizeBytes = summary.totalAllocatedBytes
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
            case .node, .nodes, .progress, .cacheDirTagged:
                break
            }
        }
        if !didFinish {
            incompleteIssues.append(ScanIncompleteIssue(
                path: url.path,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
        }
        return FilesystemScanResult(
            sizeBytes: sizeBytes,
            incompleteIssues: incompleteIssues
        )
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
    private static func expandGlob(_ pattern: String) -> PathExpansionResult {
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
            GSYLog.warning(.scan, "Workflow glob 展开失败 parent=\(parent) error=\(error)")
            return PathExpansionResult(
                paths: [],
                incompleteIssues: [scanIncompleteIssue(
                    path: parent,
                    stage: .enumerate,
                    posixErrorCode: posixErrorCode(from: error)
                )]
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

    private static func scanIncompleteIssue(
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

    private static func posixErrorCode(from error: Error) -> Int32? {
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

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// PR-9 测试 hook：注入 cardHits 用于单测，**仅在测试代码中调用**。
    internal func setTestHits(_ hits: [String: [WorkflowScanHit]]) {
        self.cardHits = hits
        for (cardID, hitList) in hits {
            cardTotalBytes[cardID] = hitList.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) }
        }
    }

    internal func setTestCardIncompleteIssues(_ issues: [String: [ScanIncompleteIssue]]) {
        cardIncompleteIssues = issues
    }

    /// PR-9 测试 hook：注入 cards 用于单测，**仅在测试代码中调用**。
    internal func setTestCards(_ cards: [DeveloperCard]) {
        self.cards = cards
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
