import SwiftUI
import Foundation
import Darwin
import ScanKit
import LogKit

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
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                accessDeniedPathsProvider: (@MainActor () -> Set<String>)? = nil) {
        self.workflow = workflow
        self.pipeline = pipeline
        _viewModel = StateObject(wrappedValue: WorkflowDetailViewModel(
            workflow: workflow,
            home: home,
            accessDeniedPathsProvider: accessDeniedPathsProvider
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
        .sheet(item: $viewModel.activeSheet) { sheet in
            switch sheet {
            case .simctlConfirm:
                simctlConfirmSheet
            case .result(let payload):
                OperationResultSheet(payload: payload) {
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
            .disabled(card.risk == .blocked)

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
            .disabled(viewModel.isAnyLoading)

            Button(role: .destructive) {
                Task { await viewModel.performDelete(pipeline: pipeline) }
            } label: {
                Label {
                    Text("workflow.detail.action.trash", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(viewModel.selected.isEmpty || viewModel.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    @Published public var selected: Set<String> = []
    @Published public private(set) var isDeleting: Bool = false
    @Published public private(set) var alertTitle: String?
    @Published public private(set) var alertMessage: String?

    /// **v2026.06.22 (P0-1)**：合并旧 `pendingSimctlStage` + `lastDeleteResult` 两条
    /// 独立 sheet 状态——SwiftUI 同一 view 多 `.sheet` 互斥导致 simctl 关闭后
    /// OperationResultSheet 永远不弹。改为单一 ActiveSheet enum，View 侧只挂一个
    /// `.sheet(item:)`，由 ViewModel 决定当前展示哪一种。
    @Published public var activeSheet: ActiveSheet?

    /// 当前正在显示的 sheet 类型。
    /// - `.simctlConfirm`：simctl 两轮确认 sheet（具体阶段由 `pendingSimctlStage` 决定）
    /// - `.result(payload)`：OperationResultSheet（trash 完成后展示结构化结果）
    public enum ActiveSheet: Identifiable, Equatable {
        case simctlConfirm
        case result(OperationResultPayload)

        public var id: String {
            switch self {
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
    /// 新代码请监听 [activeSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)。
    public var lastDeleteResult: OperationResultPayload? {
        get {
            if case let .result(p) = activeSheet { return p }
            return nil
        }
        set {
            if let value = newValue {
                activeSheet = .result(value)
            } else if case .result = activeSheet {
                activeSheet = nil
            }
        }
    }

    public enum SimctlConfirmStage: Equatable {
        case firstReview(items: [SimulatorDeleteCoordinator.Item])
        case secondConfirm(items: [SimulatorDeleteCoordinator.Item])
    }

    private let workflow: any DeveloperWorkflow
    private let home: URL
    private let simulatorCoordinator: SimulatorDeleteCoordinator
    /// **v2026.06.22 (P0-1)**：accessDenied 注入回调。生产由 MainView/Container
    /// 拿 `ScanCoordinator.permissionDeniedPaths ∪ tccProtectedSkippedPaths` 喂入；
    /// 测试可注入空 Set。nil 表示未注入（兼容旧 init 路径）——会按"无 accessDenied"处理。
    private let accessDeniedPathsProvider: (@MainActor () -> Set<String>)?
    /// **v2026.06.22 (P0-1)**：UndoHistory 写入入口。默认 `UndoHistoryStore.shared`，
    /// 测试可注入临时目录 store。
    private let undoHistoryStore: UndoHistoryStore
    private var didBootstrap: Bool = false
    private let maxConcurrentCardLoads = 2

    public init(workflow: any DeveloperWorkflow,
                home: URL,
                simulatorCoordinator: SimulatorDeleteCoordinator? = nil,
                accessDeniedPathsProvider: (@MainActor () -> Set<String>)? = nil,
                undoHistoryStore: UndoHistoryStore = .shared) {
        self.workflow = workflow
        self.home = home
        // 默认协调器：用 SubprocessExecutor 默认 allowlist + 60s timeout（simctl runtime delete 可能慢）+ 非 dryRun。
        // 测试侧可注入 dryRun=true 的协调器。
        self.simulatorCoordinator = simulatorCoordinator ?? SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 60, dryRun: false),
            isSimulatorRunning: SimulatorDeleteCoordinator.defaultSimulatorRunning
        )
        self.accessDeniedPathsProvider = accessDeniedPathsProvider
        self.undoHistoryStore = undoHistoryStore
    }

    public var isAnyLoading: Bool { !cardLoading.isEmpty }

    public var totalSelectedBytes: Int64 {
        var sum: Int64 = 0
        for hit in foldedSelectedHitsForDisplay() {
            sum &+= hit.sizeBytes ?? 0
        }
        return sum
    }

    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        cards = workflow.cards(home: home)
        for card in cards where card.risk == .safe {
            expanded.insert(card.id)
        }
        await loadAllCards()
    }

    public func refreshAll() async {
        cardHits.removeAll()
        cardTotalBytes.removeAll()
        selected.removeAll()
        cards = workflow.cards(home: home)
        await loadAllCards()
    }

    public func toggleExpanded(cardID: String, open: Bool) {
        if open {
            expanded.insert(cardID)
        } else {
            expanded.remove(cardID)
        }
    }

    public func toggleSelection(hitID: String, on: Bool) {
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

    public func performDelete(pipeline: any DeletionPipeline) async {
        guard !selected.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        var fsPaths: [String] = []
        for card in cards {
            guard let hits = cardHits[card.id] else { continue }
            let selectedHits = hits.filter { selected.contains($0.id) }
            guard !selectedHits.isEmpty else { continue }
            if case .filesystem = card.recipe {
                fsPaths.append(contentsOf: selectedHits.map { $0.url.path })
            }
        }
        fsPaths = Self.foldNestedPaths(fsPaths)

        // **v2026.06.22 (P0-1)**：与 [MainView.runTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
        // 对齐统一删除入口：accessDenied 注入 → TrashActionCoordinator.run → UndoHistory.addRecord
        // → 用 outcome.movedPairs 而非全部请求路径来回写 selected。原实现漏了前 3 步
        // 且 `for path in fsPaths { selected.remove(path) }` 会把"被 SafetyEngine 拦截
        // / recycle 失败"的项也从 selected 移除——用户重试时找不到原条目。
        var movedPairs: [(String, String)] = []
        var failedPaths: [String] = []
        var safetyRejected: [(String, String)] = []
        if !fsPaths.isEmpty {
            let denied = accessDeniedPathsProvider?() ?? []
            let action = TrashActionCoordinator(pipeline: pipeline, undoHistoryStore: undoHistoryStore)
            let result = await action.run(TrashActionCoordinator.Request(
                paths: fsPaths,
                dryRun: false,
                source: "workflow",
                accessDeniedPaths: denied
            ))
            if let outcome = result.outcome {
                movedPairs = outcome.movedPairs.map { ($0.originalPath, $0.trashedPath) }
                failedPaths = outcome.failedPaths
                safetyRejected = outcome.safetyRejected.map { ($0.path, $0.reason) }
            } else {
                movedPairs = result.pairs
                let succeeded = Set(result.succeededPaths)
                failedPaths = result.err == nil ? [] : fsPaths.filter { !succeeded.contains($0) }
            }

            // selected 用真实成功的 originalPath 反查 hit.id 后剔除
            //    （fsPaths 是 path，selected 是 hitID——必须通过 cardHits 反向映射）
            let successPathSet = Set(movedPairs.map { $0.0 })
            if !successPathSet.isEmpty {
                for (_, hits) in cardHits {
                    for hit in hits where successPathSet.contains(hit.url.path) {
                        selected.remove(hit.id)
                    }
                }
            }
        }

        // v1.7 M1 PR-9：commandLine（simctl）真删走两轮确认 sheet。
        // prepare 阶段如发现"无选中 commandLine 项"则跳过；如 Simulator 运行中则在 payload 里记一条 blocked。
        var commandLineSkipped = 0
        let plan = simulatorCoordinator.prepare(cards: cards, cardHits: cardHits, selected: selected)
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
            commandLineSkipped = items.count
            willShowSimctlSheet = true
        }

        if !fsPaths.isEmpty {
            await refreshAll()
        }

        // **v2026.06.22 (P0-1)**：同帧不能同时设两个 sheet——SwiftUI 只显示先到的那个。
        // 优先级：simctl 确认 sheet > OperationResultSheet。simctl 走完后 executeConfirmedSimctl
        // 会再次设置 activeSheet=.result(...) 把汇总展示出来。
        let hasAnything = !movedPairs.isEmpty || !failedPaths.isEmpty || !safetyRejected.isEmpty || commandLineSkipped > 0
        if willShowSimctlSheet {
            activeSheet = .simctlConfirm
        } else if hasAnything {
            activeSheet = .result(OperationResultPayload(
                movedPairs: movedPairs,
                failedPaths: failedPaths,
                safetyRejected: safetyRejected,
                commandLineSkipped: commandLineSkipped
            ))
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
        pendingSimctlStage = nil
        if case .simctlConfirm = activeSheet {
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

        let outcomes = await simulatorCoordinator.execute(items: items)
        var success = 0
        var failed: [String] = []
        for outcome in outcomes {
            if outcome.isSuccess {
                success &+= 1
                selected.remove(outcome.item.hitID)
            } else {
                failed.append("\(outcome.item.displayName) [exit=\(outcome.exitCode)]")
            }
        }

        var summaryLines: [String] = []
        summaryLines.append(String(format: String(localized: "workflow.detail.simctl.summary %lld %lld", bundle: .module),
                                   success, failed.count))
        if !failed.isEmpty {
            summaryLines.append(failed.joined(separator: "\n"))
        }
        alertTitle = String(localized: "workflow.detail.alert.title", bundle: .module)
        alertMessage = summaryLines.joined(separator: "\n")

        await refreshAll()
    }

    private func loadAllCards() async {
        let cardsSnapshot = cards
        let versionedHits = cardsSnapshot.contains { card in
            if case .versionedRoot = card.source { return true }
            return false
        } ? KnownVersionedRoots.scanAll(home: home) : []

        var startIndex = 0
        while startIndex < cardsSnapshot.count {
            let endIndex = min(startIndex + maxConcurrentCardLoads, cardsSnapshot.count)
            let batch = Array(cardsSnapshot[startIndex..<endIndex])
            startIndex = endIndex

            for card in batch {
                cardLoading.insert(card.id)
            }

            let results = await withTaskGroup(of: (String, [WorkflowScanHit]).self,
                                              returning: [(String, [WorkflowScanHit])].self) { group in
                for card in batch {
                    let cardID = card.id
                    let source = card.source
                    group.addTask { [home, versionedHits] in
                        let hits = await Self.resolveCard(source: source, home: home, versionedHits: versionedHits)
                        return (cardID, hits)
                    }
                }
                var collected: [(String, [WorkflowScanHit])] = []
                collected.reserveCapacity(batch.count)
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            for (cardID, hits) in results {
                cardHits[cardID] = hits
                cardTotalBytes[cardID] = hits.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) }
                cardLoading.remove(cardID)
                if let card = cards.first(where: { $0.id == cardID }), card.risk == .safe {
                    for hit in hits {
                        selected.insert(hit.id)
                    }
                }
            }
        }
        collapseNestedFilesystemSelections()
    }

    private func foldedSelectedHitsForDisplay() -> [WorkflowScanHit] {
        var filesystemHits: [WorkflowScanHit] = []
        var otherHits: [WorkflowScanHit] = []
        for card in cards {
            guard let hits = cardHits[card.id] else { continue }
            let chosen = hits.filter { selected.contains($0.id) }
            if case .filesystem = card.recipe {
                filesystemHits.append(contentsOf: chosen)
            } else {
                otherHits.append(contentsOf: chosen)
            }
        }
        let foldedPaths = Set(Self.foldNestedPaths(filesystemHits.map { $0.url.path }))
        var seenFilesystemPaths: Set<String> = []
        let uniqueFilesystemHits = filesystemHits.filter { hit in
            guard foldedPaths.contains(hit.url.path) else { return false }
            return seenFilesystemPaths.insert(hit.url.path).inserted
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
        for hit in selectedFilesystemHits where !kept.contains(hit.url.path) {
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

    private static func resolveCard(source: DeveloperCard.PathSource,
                                    home: URL,
                                    versionedHits: [KnownVersionedRoots.Hit] = []) async -> [WorkflowScanHit] {
        switch source {
        case .literal(let paths):
            // **v2026.06.22 (P0-5)**：`.literal` 分支历史只走 `FileManager.fileExists`，不展开 glob。
            // 但 [AndroidWorkflow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/AndroidWorkflow.swift) 等卡片实际声明了带 `*` 的路径
            // （如 `~/Library/Caches/Google/AndroidStudio*`），未展开就 `fileExists` 会全部落空，
            // 导致 JetBrains / AndroidStudio 整卡 0 命中。改为：含 `*` 走 parent + fnmatch 枚举。
            var results: [WorkflowScanHit] = []
            for raw in paths {
                let expandedRaw = (raw as NSString).expandingTildeInPath
                for matchedPath in Self.expandGlob(expandedRaw) {
                    let url = URL(fileURLWithPath: matchedPath)
                    let size = Self.directorySize(at: url)
                    results.append(WorkflowScanHit(url: url, sizeBytes: size, displayName: url.lastPathComponent, note: url.path))
                }
            }
            return results
        case .versionedRoot(let ruleID):
            let allHits = versionedHits.isEmpty ? KnownVersionedRoots.scanAll(home: home) : versionedHits
            let hits = allHits.filter { $0.ruleID == ruleID }
            return hits.map { hit in
                let size = Self.directorySize(at: hit.url)
                let localizedName = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                let composedName: String
                if let groupKey = hit.groupKey, !groupKey.isEmpty {
                    composedName = "\(localizedName) · \(groupKey)"
                } else {
                    composedName = localizedName
                }
                return WorkflowScanHit(url: hit.url, sizeBytes: size, displayName: composedName, note: hit.versionName)
            }
        case .vendor:
            // PR-5 阶段不接 vendor 源——卡片侧目前没人用，留位避免编译警告。
            return []
        case .dynamicScanner(let scannerID):
            return await WorkflowRegistry.resolve(scannerID: scannerID, home: home)
        }
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
    private static func expandGlob(_ pattern: String) -> [String] {
        guard pattern.contains("*") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        let url = URL(fileURLWithPath: pattern)
        let parent = url.deletingLastPathComponent().path
        let lastComponent = url.lastPathComponent
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: parent) else {
            return []
        }
        return entries.compactMap { name -> String? in
            let matched = name.withCString { nameCStr in
                lastComponent.withCString { patternCStr in
                    fnmatch(patternCStr, nameCStr, 0) == 0
                }
            }
            guard matched else { return nil }
            return (parent as NSString).appendingPathComponent(name)
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [], errorHandler: nil) else {
            return 0
        }
        var sum: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            sum &+= Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return sum
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

    /// **v2026.06.22 (P0-5) 测试 hook**：把 private static [expandGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)
    /// 暴露给同模块测试，覆盖 fnmatch 末段 `*` 展开行为。生产路径不应调用。
    internal static func _testing_expandGlob(_ pattern: String) -> [String] {
        return expandGlob(pattern)
    }
}
