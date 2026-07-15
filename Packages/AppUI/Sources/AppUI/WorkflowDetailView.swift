import SwiftUI
import Foundation
import Darwin
import ScanKit
import LogKit
import SafetyKit

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
/// 3. .commandLine recipe + risk == .blocked：删除按钮 disabled + 提示文案；
/// 4. 勾选默认：risk == .safe 全勾，risk == .confirm/.blocked 不勾；
/// 5. 删除走 [DeletionPipeline.moveToTrash]，与主路径同款（filesystem recipe）；
///    commandLine recipe 暂走 dryRun 提示（实际 simctl 删除在 PR-6 接入）。
public struct WorkflowDetailView: View {
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
            Button(String(localized: "workflow.detail.alert.ok", bundle: .module)) { viewModel.clearAlert() }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        // **v2026.06.22 (P0-1)**：旧实现并排挂了两个 `.sheet`——
        //   .sheet(isPresented: pendingSimctlStage != nil) { ... }
        //   .sheet(item: lastDeleteResult) { ... }
        // SwiftUI 同一 view 上多个 .sheet 互斥，只显示**第一个**，导致 simctl 弹完后
        // OperationResultSheet 永远不弹。改为单一 ActiveSheet enum + `.sheet(item:)`，
        // 让两种 sheet 在 ViewModel 层就先选好"当前展示哪一个"，避免渲染层互踩。
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
            case .simctlConfirm:
                simctlConfirmSheet
                    // 两轮破坏性命令确认必须通过显式取消/继续按钮收口。
                    // 禁止 Esc / 系统手势直接关闭，否则已完成的 filesystem 结果
                    // 会失去展示机会，pending 状态也无法原子清理。
                    .interactiveDismissDisabled()
            case .result(let completion):
                OperationResultSheet(completion: completion) {
                    viewModel.activeSheet = nil
                }
            }
        }
    }

    @ViewBuilder
    private var simctlConfirmSheet: some View {
        switch viewModel.pendingSimctlStage {
        case .firstReview(let items):
            SimctlConfirmSheetContent(
                items: items,
                stage: .firstReview,
                onCancel: { viewModel.cancelSimctlConfirm() },
                onPrimary: { viewModel.advanceSimctlConfirm() }
            )
        case .secondConfirm(let items):
            SimctlConfirmSheetContent(
                items: items,
                stage: .secondConfirm,
                onCancel: { viewModel.cancelSimctlConfirm() },
                onPrimary: { Task { await viewModel.executeConfirmedSimctl() } }
            )
        case .none:
            EmptyView()
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
            // v2026.06 用户反馈 #3：此前 0 字节卡片会显示"0 KB"，与"未扫到任何东西"无法区分，
            // 用户截图全屏 Zero KB 完全不知道是真扫不到还是 bug。改为：
            // - total == 0 且 hits 也空 → 显示"暂未发现"灰色小 chip；
            // - total > 0 → 正常显示字节；
            // - 加载中 → ProgressView（保留）。
            if viewModel.cardLoading.contains(card.id) {
                ProgressView()
                    .controlSize(.small)
            } else if let total = viewModel.cardTotalBytes[card.id], total > 0 {
                Text(WorkflowDetailViewModel.formatBytes(total))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("workflow.card.empty_chip", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
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
        } else if hits.isEmpty {
            Text("workflow.detail.empty_card", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.vertical, 6)
        } else {
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
            .disabled(card.risk == .blocked || viewModel.isDeletionTransactionActive)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hit.displayName)
                    .font(.system(.body))
                if let note = hit.note {
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
            Text(verbatim: String(format: String(localized: "workflow.detail.footer.summary %lld %@", bundle: .module),
                                  viewModel.selected.count,
                                  WorkflowDetailViewModel.formatBytes(viewModel.totalSelectedBytes)))
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
                viewModel.selected.isEmpty
                    || viewModel.isAnyLoading
                    || viewModel.isDeletionTransactionActive
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
/// newer scan. `commandPlan` similarly owns concrete validated simctl items.
public struct WorkflowDeletionIntent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scanRevision: UInt64
    public let scanSessionID: UUID
    public let selectedHitIDs: Set<String>
    public let filesystemPaths: [String]
    public let filesystemHitIDsByPath: [String: Set<String>]
    public let filesystemCandidates: [RunningAppGuard.Candidate]
    public let accessDeniedPaths: Set<String>
    public let commandPlan: SimulatorDeleteCoordinator.Plan
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
                commandPlan: SimulatorDeleteCoordinator.Plan,
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
        self.commandPlan = commandPlan
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
         commandPlan: SimulatorDeleteCoordinator.Plan,
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
        self.commandPlan = commandPlan
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
                format: String(localized: "workflow.detail.delete_confirm.message %lld %@", bundle: .module),
                confirmation.itemCount,
                WorkflowDetailViewModel.formatBytes(confirmation.totalBytes)
            ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "delete.action.cancel", bundle: .module), role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "workflow.detail.delete_confirm.action", bundle: .module), role: .destructive) {
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

/// v1.7 M1 PR-9：simctl 两轮确认 sheet 内容。
///
/// 与 [WorkflowDetailView] 拆分的理由：
/// - sheet 是独立交互单元（含自己的列表 / 警示 / Cancel + Primary 按钮），
///   单独成 struct 后样式调整不会污染主视图；
/// - 同一 view 复用于 firstReview / secondConfirm 两种 stage，仅文案与按钮 label 不同。
struct SimctlConfirmSheetContent: View {
    enum Stage { case firstReview, secondConfirm }

    let items: [SimulatorDeleteCoordinator.Item]
    let stage: Stage
    let onCancel: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶部标题 + 警示图标
            HStack(spacing: 10) {
                Image(systemName: stage == .secondConfirm ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(stage == .secondConfirm ? .red : .orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage == .firstReview
                         ? "workflow.detail.simctl.sheet.review_title"
                         : "workflow.detail.simctl.sheet.confirm_title", bundle: .module)
                        .font(.title3.bold())
                    Text(stage == .firstReview
                         ? "workflow.detail.simctl.sheet.review_subtitle"
                         : "workflow.detail.simctl.sheet.confirm_subtitle", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            // 待删项目清单
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.hitID) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.system(.callout, design: .rounded))
                            Text(verbatim: "\(item.executable) \(item.args.joined(separator: " "))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 280)

            // 第二轮提示一遍"不可撤销"
            if stage == .secondConfirm {
                Text("workflow.detail.simctl.sheet.confirm_irreversible", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(role: .cancel, action: onCancel) {
                    Text("workflow.detail.simctl.sheet.cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button(role: stage == .secondConfirm ? .destructive : nil, action: onPrimary) {
                    Text(stage == .firstReview
                         ? "workflow.detail.simctl.sheet.continue"
                         : "workflow.detail.simctl.sheet.confirm_delete", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560)
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
    @Published public private(set) var cards: [DeveloperCard] = []
    @Published public private(set) var cardHits: [String: [WorkflowScanHit]] = [:]
    @Published public private(set) var cardTotalBytes: [String: Int64] = [:]
    @Published public private(set) var cardLoading: Set<String> = []
    @Published public var expanded: Set<String> = []
    @Published public private(set) var selected: Set<String> = []
    @Published public private(set) var scanEvidence = WorkflowScanEvidence(revision: 0)
    @Published public private(set) var isDeleting: Bool = false
    @Published public private(set) var isPreparingDeletion: Bool = false
    @Published public private(set) var alertTitle: String?
    @Published public private(set) var alertMessage: String?

    /// **v2026.06.22 (P0-1)**：合并旧 `pendingSimctlStage` + `lastDeleteResult` 两条
    /// 独立 sheet 状态——SwiftUI 同一 view 多 `.sheet` 互斥导致 simctl 关闭后
    /// OperationResultSheet 永远不弹。改为单一 ActiveSheet enum，View 侧只挂一个
    /// `.sheet(item:)`，由 ViewModel 决定当前展示哪一种。
    @Published var activeSheet: ActiveSheet?

    /// 当前正在显示的 sheet 类型。
    /// - `.simctlConfirm`：simctl 两轮确认 sheet（具体阶段由 `pendingSimctlStage` 决定）
    /// - `.result(payload)`：OperationResultSheet（trash 完成后展示结构化结果）
    enum ActiveSheet: Identifiable, Equatable {
        case deleteConfirm(WorkflowDeleteConfirmation)
        case preflightNotice(id: UUID, rejections: [DeletionPreflight.Rejection])
        case simctlConfirm
        case result(OperationResultCompletion)

        public var id: String {
            switch self {
            case .deleteConfirm(let confirmation):
                return "deleteConfirm-\(confirmation.id.uuidString)"
            case .preflightNotice(let id, _):
                return "preflightNotice-\(id.uuidString)"
            case .simctlConfirm: return "simctlConfirm"
            case .result(let p): return "result-\(p.id.uuidString)"
            }
        }

        public static func == (lhs: ActiveSheet, rhs: ActiveSheet) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// v1.7 M1 PR-9：simctl 两轮确认 sheet 阶段。
    /// - `nil`：无 simctl 流程；
    /// - `.firstReview(items)`：第一轮弹列表预览；
    /// - `.secondConfirm(items)`：第二轮弹"输入确认"。
    /// **P0-1 后**：阶段切换由 [advanceSimctlConfirm](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift) /
    /// [cancelSimctlConfirm](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift) 内部维护，
    /// 同时同步刷新 `activeSheet`，让 View 侧只关心 `activeSheet`。
    @Published public private(set) var pendingSimctlStage: SimctlConfirmStage?

    /// 兼容旧调用方读取 lastDeleteResult 的入口（已弃用）。
    /// 这里故意只读；结果只能由本 ViewModel 在执行层返回后产生。
    public var lastDeleteResult: OperationResultPayload? {
        if case let .result(completion) = activeSheet { return completion.resultPayload }
        return nil
    }

    public enum SimctlConfirmStage: Equatable {
        case firstReview(items: [SimulatorDeleteCoordinator.Item])
        case secondConfirm(items: [SimulatorDeleteCoordinator.Item])
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
    /// Filesystem cleanup is executed before the destructive simctl confirmation flow.
    /// Keep that immutable result across both confirmation sheets so the final result
    /// represents the complete user action instead of only the last subprocess phase.
    private var pendingFilesystemResult: DeletionCompletedInteraction?
    /// Running-app skips are confirmation metadata, not proof that anything was submitted.
    /// Keep them outside `OperationResultPayload` until simctl actually executes; cancelling
    /// the command confirmation must simply discard them.
    private var pendingRunningAppSkipped: [OperationResultPayload.RunningAppSkippedItem] = []
    private var pendingConfirmedDeleteIntent: WorkflowDeletionIntent?
    private var deletionInteractionCoordinator: DeletionInteractionCoordinator?
    private var didBootstrap: Bool = false
    private var scanRevision: UInt64 = 0
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
        // 默认协调器：用 SubprocessExecutor 默认 allowlist + 60s timeout（simctl runtime delete 可能慢）+ 非 dryRun。
        // 测试侧可注入 dryRun=true 的协调器。
        self.simulatorCoordinator = simulatorCoordinator ?? SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 60, dryRun: false),
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
        case .deleteConfirm, .preflightNotice, .simctlConfirm:
            return true
        case .result, .none:
            return false
        }
    }

    public var totalSelectedBytes: Int64 {
        Self.totalBytes(for: selected, cards: cards, cardHits: cardHits)
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
            selected.insert(hitID)
            collapseNestedFilesystemSelections()
        } else {
            selected.remove(hitID)
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
        guard !selected.isEmpty,
              !isAnyLoading,
              !isDeleting,
              !isPreparingDeletion,
              pendingConfirmedDeleteIntent == nil,
              activeSheet == nil else { return }
        let selectionSnapshot = selected
        let cardsSnapshot = cards
        let cardHitsSnapshot = cardHits
        let evidenceSnapshot = scanEvidence
        let filesystem = Self.filesystemProjection(
            for: selectionSnapshot,
            cards: cardsSnapshot,
            cardHits: cardHitsSnapshot
        )
        let relevantIssues = evidenceSnapshot.issues(overlappingAny: filesystem.paths)
        let commandPlan = simulatorCoordinator.prepare(
            cards: cardsSnapshot,
            cardHits: cardHitsSnapshot,
            selected: selectionSnapshot
        )
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
              selected == selectionSnapshot else {
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
            commandPlan: commandPlan,
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
                // Skipping every running filesystem candidate cancels only the Trash subset.
                // A frozen command plan is an independent destructive operation and must still
                // reach its own two-step confirmation. Pure-filesystem all-skip remains a no-op
                // with no receipt and no result.
                guard originalIntent.commandPlan != .empty else {
                    deletionInteractionCoordinator = nil
                    activeSheet = nil
                    return true
                }
                authorizedInteraction = nil
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
            commandPlan: originalIntent.commandPlan,
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
        pendingFilesystemResult = nil
        pendingRunningAppSkipped = []
        isDeleting = true
        defer { isDeleting = false }

        let fsPaths = intent.filesystemPaths

        // **v2026.06.22 (P0-1)**：与 [MainView.runTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
        // 对齐统一删除入口：accessDenied 注入 → TrashActionCoordinator.run → UndoHistory.addRecord
        // → 用 outcome.movedPairs 而非全部请求路径来回写 selected。原实现漏了前 3 步
        // 且 `for path in fsPaths { selected.remove(path) }` 会把"被 SafetyEngine 拦截
        // / recycle 失败"的项也从 selected 移除——用户重试时找不到原条目。
        var movedPairs: [(String, String)] = []
        var safetyRejected: [(String, String)] = []
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
                    commandPlan: intent.commandPlan,
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
                safetyRejected = outcome.safetyRejected.map { ($0.path, $0.reason) }
            } else {
                movedPairs = result.pairs
            }

            // 只消费确认前冻结的 path → hit 映射；执行阶段不能回读新一轮 cardHits。
            for path in movedPairs.map({ $0.0 }) {
                succeededFilesystemHitIDs.formUnion(intent.filesystemHitIDsByPath[path] ?? [])
            }
            selected.subtract(succeededFilesystemHitIDs)
        }

        // SafetyEngine / access-denied 的拒绝是整次复合动作的一票否决。即使同一
        // intent 还冻结了 simctl items，也不能在 filesystem 安全闸门拒绝后继续
        // 执行不可恢复的命令行删除。
        if !safetyRejected.isEmpty {
            guard let filesystemCompletion else {
                presentCommandPreSubmissionBlock(
                    detail: safetyRejected.map { "\($0.0):\($0.1)" }.joined(separator: ", ")
                )
                return
            }
            activeSheet = .result(.deletion(filesystemCompletion))
            return
        }

        // v1.7 M1 PR-9：commandLine（simctl）真删走两轮确认 sheet。
        // prepare 阶段如发现"无选中 commandLine 项"则跳过；如 Simulator 运行中则在 payload 里记一条 blocked。
        let plan: SimulatorDeleteCoordinator.Plan
        switch intent.commandPlan {
        case .ready(let frozenItems):
            let remainingItems = frozenItems.filter {
                !succeededFilesystemHitIDs.contains($0.hitID)
            }
            plan = simulatorCoordinator.revalidate(items: remainingItems)
        case .empty:
            plan = .empty
        case .invalid(let reason):
            plan = .invalid(reason: reason)
        case .blockedSimulatorRunning(let names):
            plan = .blockedSimulatorRunning(displayNames: names)
        }
        var willShowSimctlSheet = false
        switch plan {
        case .empty:
            break
        case .invalid(let reason):
            // simctl item 缺 identifier：算 safetyRejected 一条，原因写明
            safetyRejected.append(("simctl-invalid", reason))
        case .blockedSimulatorRunning(let names):
            // Simulator 运行中：算 safetyRejected，原因列出阻断的名字
            safetyRejected.append(("simulator-running", names.joined(separator: ", ")))
        case .ready(let items):
            // 真删流程交给 sheet——这里只起 sheet，不直接执行
            pendingSimctlStage = .firstReview(items: items)
            willShowSimctlSheet = true
        }

        if !fsPaths.isEmpty {
            await runScan()
        }

        // **v2026.06.22 (P0-1)**：同帧不能同时设两个 sheet——SwiftUI 只显示先到的那个。
        // 优先级：simctl 确认 sheet > OperationResultSheet。simctl 走完后 executeConfirmedSimctl
        // 会再次设置 activeSheet=.result(...) 把汇总展示出来。
        if willShowSimctlSheet {
            // A pending result exists only when the filesystem pipeline was really called.
            // Running-app skips alone remain metadata until the command phase executes.
            pendingFilesystemResult = filesystemCompletion
            pendingRunningAppSkipped = intent.runningAppSkipped
            activeSheet = .simctlConfirm
        } else if let filesystemCompletion {
            activeSheet = .result(.deletion(filesystemCompletion))
        } else if !safetyRejected.isEmpty {
            presentCommandPreSubmissionBlock(
                detail: safetyRejected.map { "\($0.0):\($0.1)" }.joined(separator: ", ")
            )
        }
    }

    /// PR-9：第一轮确认 → 第二轮确认。仅做 sheet 状态推进，不真删。
    public func advanceSimctlConfirm() {
        guard case let .firstReview(items) = pendingSimctlStage else { return }
        pendingSimctlStage = .secondConfirm(items: items)
        // activeSheet 仍是 .simctlConfirm，stage 切换由 simctlConfirmSheet 内部读 pendingSimctlStage 渲染
    }

    /// PR-9：取消 sheet（无论第一/第二轮），恢复 nil 即关闭。
    public func cancelSimctlConfirm() {
        let skippedCommands: [SimulatorDeleteCoordinator.Item]
        switch pendingSimctlStage {
        case .firstReview(let items), .secondConfirm(let items):
            skippedCommands = items
        case .none:
            skippedCommands = []
        }
        pendingSimctlStage = nil
        pendingRunningAppSkipped = []
        if let pendingFilesystemResult {
            self.pendingFilesystemResult = nil
            if skippedCommands.isEmpty {
                activeSheet = .result(.deletion(pendingFilesystemResult))
            } else {
                activeSheet = .result(.deletionWithSkippedCommands(
                    deletion: pendingFilesystemResult,
                    skippedCommands: skippedCommands
                ))
            }
        } else if case .simctlConfirm = activeSheet {
            activeSheet = nil
        }
    }

    /// PR-9：第二轮"确认删除"按钮回调——真起 SubprocessExecutor。
    /// 跑完汇总成功/失败数 + 把成功项从 selected 移除 + 触发 refreshAll，再用 alert 兜底通知。
    public func executeConfirmedSimctl() async {
        guard case let .secondConfirm(items) = pendingSimctlStage, !items.isEmpty else { return }
        pendingSimctlStage = nil
        // 先收掉 simctl 确认 sheet，让出 slot 给后续 OperationResultSheet
        if case .simctlConfirm = activeSheet {
            activeSheet = nil
        }
        isDeleting = true
        defer { isDeleting = false }

        let filesystemResult = pendingFilesystemResult
        pendingFilesystemResult = nil
        let runningAppSkipped = filesystemResult?.runningAppSkipped ?? pendingRunningAppSkipped
        pendingRunningAppSkipped = []
        let validatedItems: [SimulatorDeleteCoordinator.Item]
        switch simulatorCoordinator.revalidate(items: items) {
        case .ready(let currentItems):
            validatedItems = currentItems
        case .blockedSimulatorRunning(let names):
            if let filesystemResult {
                recordCommandPreSubmissionBlock(
                    detail: "simulator-running:\(names.joined(separator: ", "))"
                )
                activeSheet = .result(.deletion(filesystemResult))
            } else {
                presentCommandPreSubmissionBlock(
                    detail: "simulator-running:\(names.joined(separator: ", "))"
                )
            }
            return
        case .invalid(let reason):
            if let filesystemResult {
                recordCommandPreSubmissionBlock(detail: "simctl-invalid:\(reason)")
                activeSheet = .result(.deletion(filesystemResult))
            } else {
                presentCommandPreSubmissionBlock(detail: "simctl-invalid:\(reason)")
            }
            return
        case .empty:
            if let filesystemResult {
                activeSheet = .result(.deletion(filesystemResult))
            } else {
                activeSheet = nil
                GSYLog.notice(.trash, "Workflow simctl 重验后没有可提交项，不展示执行结果")
            }
            return
        }

        let commandSubmission = await simulatorCoordinator.executeSubmitted(items: validatedItems)
        for outcome in commandSubmission.outcomes {
            if outcome.isSuccess {
                selected.remove(outcome.item.hitID)
            }
        }

        await runScan()

        // Present one structured result after both phases. Command-line outcomes remain
        // separate from filesystem paths because they were not moved to Trash, cannot be
        // revealed in Finder, and are not undoable.
        if let filesystemResult {
            activeSheet = .result(.combined(
                deletion: filesystemResult,
                command: commandSubmission
            ))
        } else {
            activeSheet = .result(.command(
                commandSubmission,
                runningAppSkipped: runningAppSkipped
            ))
        }
    }

    /// A command that becomes blocked before `SimulatorDeleteCoordinator.execute` has no
    /// operation receipt. Surface a localized warning, while keeping machine details in logs.
    private func presentCommandPreSubmissionBlock(detail: String) {
        recordCommandPreSubmissionBlock(detail: detail)
        activeSheet = nil
    }

    private func recordCommandPreSubmissionBlock(detail: String) {
        GSYLog.notice(.trash, "Workflow 命令删除在提交前被阻止: \(detail)")
        alertTitle = String(localized: "op.result.section.blocked", bundle: .module)
        alertMessage = String(localized: "op.result.reason.generic", bundle: .module)
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
        cardLoading.removeAll()
        selected.removeAll()
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

            let results = await withTaskGroup(of: (String, CardScanResult).self,
                                              returning: [(String, CardScanResult)].self) { group in
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
                var collected: [(String, CardScanResult)] = []
                collected.reserveCapacity(batch.count)
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            guard revision == scanRevision, scanEvidence.sessionID == sessionID else { return }
            var incompleteIssues = scanEvidence.incompleteIssues
            for (cardID, result) in results {
                cardHits[cardID] = result.hits
                cardTotalBytes[cardID] = result.hits.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) }
                cardLoading.remove(cardID)
                incompleteIssues.append(contentsOf: result.incompleteIssues)
                if let card = cards.first(where: { $0.id == cardID }), card.risk == .safe {
                    for hit in result.hits {
                        selected.insert(hit.id)
                    }
                }
            }
            scanEvidence = WorkflowScanEvidence(
                revision: revision,
                sessionID: sessionID,
                incompleteIssues: incompleteIssues
            )
        }
        collapseNestedFilesystemSelections()
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
                let localizedName = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
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
                    commandLineTailArg: hit.commandLineTailArg
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

    /// PR-9 测试 hook：注入 cards 用于单测，**仅在测试代码中调用**。
    internal func setTestCards(_ cards: [DeveloperCard]) {
        self.cards = cards
    }

    internal func setTestSelection(_ selection: Set<String>) {
        self.selected = selection
        collapseNestedFilesystemSelections()
    }

    internal func setTestScanEvidence(_ evidence: WorkflowScanEvidence) {
        scanRevision = evidence.revision
        scanEvidence = evidence
    }

    /// **v2026.06.22 (P0-5) 测试 hook**：把 private static [expandGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)
    /// 暴露给同模块测试，覆盖 fnmatch 末段 `*` 展开行为。生产路径不应调用。
    internal static func _testing_expandGlob(_ pattern: String) -> [String] {
        return expandGlob(pattern).paths
    }
}
