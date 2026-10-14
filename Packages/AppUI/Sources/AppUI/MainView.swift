import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanKit
import SafetyKit
import AIKit
import LogKit

private enum SidebarMetrics {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 360
    static let maxWidth: CGFloat = 460
}

private struct MainDeletionAccounting: Sendable {
    let succeededPaths: Set<String>
    let remainingSelection: Set<String>
    let movedBytes: Int64
}

struct MainDeletionPresentationProjection: Sendable, Equatable {
    let snapshot: ScanSnapshot
    let remainingSelection: Set<String>
    let shouldCloseListDetail: Bool
}

struct MainDeletionPresentationSourceIdentity: Sendable, Equatable {
    let scanSessionID: UUID
    let sourceRevision: UInt64
    let sourceCategoryID: String
    let selectedCategoryID: String?
    let interfaceMode: String
}

enum MainDeletionPresentationCommitDecision: Equatable {
    case commit
    case retryLatestSource
    case discard
}

enum MainDeletionPresentationCommitPolicy {
    static func decision(
        frozen: MainDeletionPresentationSourceIdentity,
        current: MainDeletionPresentationSourceIdentity,
        requestRevisionMatches: Bool
    ) -> MainDeletionPresentationCommitDecision {
        guard requestRevisionMatches,
              frozen.scanSessionID == current.scanSessionID,
              frozen.sourceCategoryID == current.sourceCategoryID,
              frozen.selectedCategoryID == current.selectedCategoryID,
              frozen.interfaceMode == current.interfaceMode else {
            return .discard
        }
        return frozen.sourceRevision == current.sourceRevision
            ? .commit
            : .retryLatestSource
    }
}

/// Holds the old wide list snapshot across the MainActor COW swap, then releases it on the actor
/// executor. Receipt presentation must be fast even when the prior list contains tens of
/// thousands of rows; the last Array release cannot be charged to the UI frame.
private actor MainDeletionPresentationRetirement {
    private var snapshots: [ScanSnapshot]?

    init(snapshot: ScanSnapshot) {
        snapshots = [snapshot]
    }

    func retain(_ snapshot: ScanSnapshot) {
        snapshots?.append(snapshot)
    }

    func retire() {
        snapshots = nil
    }
}

enum MainDeletionModelSurface: String, Sendable, Equatable {
    case professional
    case smartCare = "smart_care"
}

struct MainDeletionModelSynchronizationPlan: Sendable, Equatable {
    let exactSurface: MainDeletionModelSurface
    let invalidatedSurface: MainDeletionModelSurface
}

enum MainDeletionModelSynchronizationPolicy {
    nonisolated static func plan(
        authoritativeSurface: MainDeletionModelSurface
    ) -> MainDeletionModelSynchronizationPlan {
        switch authoritativeSurface {
        case .professional:
            return MainDeletionModelSynchronizationPlan(
                exactSurface: .professional,
                invalidatedSurface: .smartCare
            )
        case .smartCare:
            return MainDeletionModelSynchronizationPlan(
                exactSurface: .smartCare,
                invalidatedSurface: .professional
            )
        }
    }
}

/// Follow-up UI is deliberately separate from Professional deletion execution. A fast recycle may
/// finish while the confirmation sheet is still animating out; its payload is retained here and
/// becomes eligible only from that sheet's `onDismiss` callback.
private enum ProfessionalDeleteDeferredPresentation: Sendable {
    case confirmation(DeleteSheetRequest)
    case preflightNotice(DeletionPreflightNotice)
    case result(OperationResultCompletion)
}

private struct ProfessionalDeleteTiming: Sendable {
    let traceID: UUID
    let confirmedAtUptime: TimeInterval
    let itemCount: Int

    static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int((max(0, end - start) * 1_000).rounded())
    }
}

/// Receipt-first result acknowledgement for MainView deletion flows.
///
/// v2026.07.20 regression fix: a real deletion of one developer artifact completed in 364 ms,
/// but the result sheet waited another 11.45 s for a 13,651-row / 11,872-cache Tree prune. A typed
/// recycle receipt is the result authority; scan/Tree reconciliation must continue afterwards and
/// cannot gate user feedback. The explicit yield gives SwiftUI a presentation turn before a wide
/// model worker is admitted.
@MainActor
enum DeletionResultAcknowledgementOrdering {
    static func acknowledgeThenReconcile<Payload>(
        makePayload: () -> Payload,
        present: (Payload) -> Void,
        reconcileModel: () async -> Void
    ) async {
        present(makePayload())
        await Task.yield()
        await reconcileModel()
    }
}

/// Smart Care 自己的互斥 sheet 路由。
/// AI 报告必须先 dismiss，才能进入既有清理预览，避免 macOS sheet 叠 sheet。
private enum SmartCareSheetRoute: Identifiable {
    case aiReview(SmartCareAIReviewReport)
    case cleanup(SmartCareCleanRequest)

    var id: String {
        switch self {
        case .aiReview(let report):
            return "ai-\(report.runID.uuidString)-\(report.status.rawValue)-\(report.observedSummaryRevision)"
        case .cleanup(let request): return "cleanup-\(request.id.uuidString)"
        }
    }
}

private enum StashDismissalAction: Sendable {
    case delete([StashStore.StashEntry])
    case askAI(RowItem)
}

/// AI Review 终态报告的自动呈现策略。
///
/// 新鲜报告可以自动打开；summary 变化产生的过期报告只允许更新一个已经可见的
/// AI Report，不能在清理成功后重新弹出。其它 modal 正在显示时保留报告，用户可从
/// Dashboard 的“查看报告”显式打开，避免多组 `.sheet` 竞争呈现。
enum SmartCareAIReviewAutoPresentationPolicy {
    enum Action: Equatable {
        case present
        case queue
        case dismiss
        case ignore
    }

    static func action(
        reportStatus: SmartCareAIReviewReportStatus?,
        isNormalInterface: Bool,
        isAIReportVisible: Bool,
        isCleanupVisible: Bool,
        hasOtherModalPresentation: Bool
    ) -> Action {
        guard let reportStatus else {
            return isAIReportVisible ? .dismiss : .ignore
        }
        if reportStatus == .stale {
            return isNormalInterface && isAIReportVisible ? .present : .ignore
        }
        guard !isCleanupVisible else { return .ignore }
        guard isNormalInterface, !hasOtherModalPresentation else { return .queue }
        return .present
    }
}

enum SmartCareAIReviewCleanupLinkPolicy {
    static func allowsPresentation(
        expectedSummaryRevision: UInt64,
        currentSummaryRevision: UInt64,
        requestSummaryRevision: UInt64?
    ) -> Bool {
        expectedSummaryRevision == currentSummaryRevision
            && requestSummaryRevision == expectedSummaryRevision
    }
}

enum SmartCareAIReviewDeferredActionPolicy {
    static func allows(
        expectedRunID: UUID,
        expectedSummaryRevision: UInt64,
        latestReport: SmartCareAIReviewReport?,
        currentSummaryRevision: UInt64,
        aiIsRunning: Bool
    ) -> Bool {
        !aiIsRunning
            && latestReport?.runID == expectedRunID
            && currentSummaryRevision == expectedSummaryRevision
    }
}

enum SmartCarePrimaryActionDispatch: Equatable {
    case startScan
    case returnToSetup
    case retry
    case continueScan
    case stopScan
    case presentCleanup
    case none

    /// v2026.07.20: keep the Dashboard action contract outside the View switch. In particular,
    /// `.scanAgain` is reset-only; it must never be wired back to an immediate scan start.
    static func resolve(_ action: SmartCarePrimaryAction) -> SmartCarePrimaryActionDispatch {
        switch action {
        case .startScan: return .startScan
        case .scanAgain: return .returnToSetup
        case .retry: return .retry
        case .continueScan: return .continueScan
        case .stopScan: return .stopScan
        case .cleanSafeItems, .confirmClean: return .presentCleanup
        case .cleaning: return .none
        }
    }
}

private struct SmartCareAIReportObserverModifier: ViewModifier {
    let latestReport: SmartCareAIReviewReport?
    let canPresentPendingReport: Bool
    let onLatestReportChange: (SmartCareAIReviewReport?) -> Void
    let onPendingAvailabilityChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onValueChange(of: latestReport) { _, report in
                onLatestReportChange(report)
            }
            .onValueChange(of: canPresentPendingReport) { _, canPresent in
                onPendingAvailabilityChange(canPresent)
            }
    }
}

private enum MainDeletionAccountingExecutor {
    static func run(rows: [RowItem],
                    succeededPaths: [String],
                    selection: Set<String>) async -> MainDeletionAccounting {
        await Task.detached(priority: .userInitiated) {
            let succeeded = Set(succeededPaths)
            var movedBytes: Int64 = 0
            for row in rows where succeeded.contains(row.url.path) {
                movedBytes &+= row.bytes
            }
            return MainDeletionAccounting(
                succeededPaths: succeeded,
                remainingSelection: selection.subtracting(succeeded),
                movedBytes: movedBytes
            )
        }.value
    }
}

/// v2026.07.20：receipt 后的可见清单窄投影。只过滤已成功路径及其后代，
/// 不改 total/count；权威统计仍由 ScanCoordinator 的完整 prune 一次性收敛。
/// 宽 Array/Set 工作必须离开 MainActor，UI 只交换 frozen snapshot。
enum MainDeletionPresentationExecutor {
    static func run(
        snapshot: ScanSnapshot,
        succeededPaths: [String],
        selection: Set<String>,
        listDetailPath: String?
    ) async -> MainDeletionPresentationProjection {
        await Task.detached(priority: .userInitiated) {
            let matcher = DeletionPresentationPathMatcher(paths: succeededPaths)
            let rows = snapshot.rows.filter { !matcher.contains($0.id) }
            let nextSnapshot = ScanSnapshot(
                categoryID: snapshot.categoryID,
                rows: rows,
                totalBytes: snapshot.totalBytes,
                scannedFileCount: snapshot.scannedFileCount,
                isFinished: snapshot.isFinished,
                elapsed: snapshot.elapsed,
                isComplete: snapshot.isComplete,
                bytesPerSecond: snapshot.bytesPerSecond,
                estimatedRemaining: snapshot.estimatedRemaining
            )
            return MainDeletionPresentationProjection(
                snapshot: nextSnapshot,
                remainingSelection: selection.filter { !matcher.contains($0) },
                shouldCloseListDetail: listDetailPath.map(matcher.contains) ?? false
            )
        }.value
    }
}

private struct SidebarTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// v2026.07.20 scan-progress isolation: this small subtree is the only main-window observer of
/// `ScanLiveProgressStore`. Progress frames must never invalidate `MainView` itself; doing so
/// re-runs the complete NavigationSplitView/sidebar graph while a full-disk scan is active.
private struct MainScanLiveProgressView: View {
    @ObservedObject var progress: ScanLiveProgressStore
    let expectedTotalBytes: Int64?
    let locale: Locale
    let multiRootMaxHeight: CGFloat

    var body: some View {
        let frame = progress.frame
        if frame.perRootRows.isEmpty {
            singleRoot(frame)
        } else {
            multiRoot(frame.perRootRows)
        }
    }

    @ViewBuilder
    private func singleRoot(_ frame: ScanLiveProgressFrame) -> some View {
        let scanned = frame.totalBytes
        let estimateOvershoot = expectedTotalBytes.map { scanned > $0 } ?? false
        let fraction: Double? = {
            guard let expectedTotalBytes,
                  expectedTotalBytes > 0,
                  !estimateOvershoot
            else { return nil }
            return max(0, Double(scanned) / Double(expectedTotalBytes))
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 180)
                }
                Text(AppLocalization.format(
                    "main.scan.progress.single",
                    locale: locale,
                    arguments: [frame.scannedFileCount, formattedBytes(scanned)]
                ))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if let fraction, let expectedTotalBytes {
                    Text(AppLocalization.format(
                        "main.scan.progress.percent",
                        locale: locale,
                        arguments: [
                            Int(fraction * 100),
                            formattedBytes(scanned),
                            formattedBytes(expectedTotalBytes),
                        ]
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(Text("main.scan.progress.percent.tooltip", bundle: .module))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AppLocalization.format(
                        "main.scan.progress.elapsed",
                        locale: locale,
                        arguments: [formatDuration(frame.elapsedForDisplay(referenceDate: context.date))]
                    ))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func multiRoot(_ rows: [ScanCoordinator.PerRootProgress]) -> some View {
        ProgressView().controlSize(.small)
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.rootPath) { row in
                    HStack(spacing: 4) {
                        let statusSymbol = row.isPartial ? "!" : (row.isFinished ? "✓" : "●")
                        let statusColor: Color = row.isPartial
                            ? .orange
                            : (row.isFinished ? .green : .accentColor)
                        Text(statusSymbol)
                            .font(.caption.bold())
                            .foregroundStyle(statusColor)
                        let bytesText = row.bytes <= 0 && row.fileCount <= 0
                            ? AppLocalization.string("progress.size.placeholder", locale: locale)
                            : formattedBytes(row.bytes)
                        Text(AppLocalization.format(
                            "main.scan.progress.multi.row",
                            locale: locale,
                            arguments: [row.displayTitle(locale: locale), bytesText, row.fileCount]
                        ))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxHeight: multiRootMaxHeight)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        AppLocalization.byteCount(bytes, locale: locale)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = max(1, Int(seconds.rounded(.up)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, remainder) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, remainder) }
        return String(format: "%ds", remainder)
    }
}

/// v2026.07.16 scan-performance regression guard: one main window has two scan
/// producers (Smart Care and Professional). A UI mode/category transition is an
/// ownership boundary, not merely a presentation change. Keeping the policy as
/// a pure value makes every transition path—including programmatic Sentinel
/// routing—use the same rule and keeps it regression-testable.
enum MainScanOwnershipPolicy {
    enum Producer: Equatable {
        case smartCare
        case professional
    }

    static func departingProducer(
        from oldMode: SmartCareInterfaceMode,
        to newMode: SmartCareInterfaceMode
    ) -> Producer? {
        guard oldMode != newMode else { return nil }
        switch oldMode {
        case .normal:
            return .smartCare
        case .professional:
            return .professional
        }
    }

    static func relinquishesProfessionalCategory(from oldID: String?, to newID: String?) -> Bool {
        oldID != newID
    }

    static func relinquishProfessionalCategory(
        from oldID: String?,
        to newID: String?,
        cancel: () -> Void
    ) {
        guard relinquishesProfessionalCategory(from: oldID, to: newID) else { return }
        cancel()
    }

    static func relinquishDepartingMode(
        from oldMode: SmartCareInterfaceMode,
        to newMode: SmartCareInterfaceMode,
        smartCareIsScanning: Bool,
        professionalHasActivePrimaryScan: Bool,
        cancelSmartCare: () -> Void,
        cancelProfessional: () -> Void,
        cancelProfessionalTransientWork: () -> Void
    ) {
        switch departingProducer(from: oldMode, to: newMode) {
        case .smartCare where smartCareIsScanning:
            cancelSmartCare()
        case .professional where professionalHasActivePrimaryScan:
            cancelProfessional()
        case .professional:
            // A completed Professional snapshot is preserved across mode switches,
            // but an on-demand Tree fetch is still active disk work and must stop.
            cancelProfessionalTransientWork()
        case .smartCare, nil:
            break
        }
    }
}

/// v1.3 review-fix B3：跨 target 的通知名常量。
/// App 层在主窗口已被销毁的情况下 post 这个通知，MainView 监听并调 `openWindow(id:)` 重建。
public extension Notification.Name {
    static let amuxOpenMainWindowRequested = Notification.Name("AmuxAIClean.openMainWindowRequested")
}

/// 三栏主界面 —— 侧边类目 / 中间结果 / 右侧详情 + 删除按钮。
/// 见 PITFALLS §5.5/§5.6/§5.7：默认勾选只勾 .safe；先聚合不展平；删除走统一模式化确认。
public struct MainView: View {
    public static let defaultInterfaceMode: SmartCareInterfaceMode = .normal

    @Environment(\.locale) private var locale
    @StateObject private var coordinator: ScanCoordinator
    @State private var interfaceMode: SmartCareInterfaceMode = MainView.defaultInterfaceMode
    @StateObject private var smartCareSession: SmartCareSession
    @StateObject private var storageAnalysis: StorageAnalysisStore
    @State private var normalSection: NormalWorkspaceSection = .analyze
    @State private var normalToolIsBusy = false
    @StateObject private var applicationPresentation: MainWindowPresentationCoordinator
    @State private var presentationHostID = UUID()
    @State private var isPresentationHostMounted = false
    @State private var applicationSheetID: UUID?
    @StateObject private var guideAnchors = ControlGuideAnchors()
    private let onTCCGuideDismiss: (Bool) -> Void
    @State private var smartCareSheetRoute: SmartCareSheetRoute?
    @State private var smartCareCleanupHandoff = SheetDismissalHandoff<UInt64>()
    /// v2026.07.20：仅普通模式首次启用开发缓存时占用。确认前不修改选择，
    /// 取消后仍保持未选中，避免提示状态与实际扫描计划分叉。
    @State private var showSmartCareDeveloperCacheWarning = false
    @State private var pendingSmartCareAIReport: SmartCareAIReviewReport? = nil
    /// Smart Care 删除 preview 的跨 await 单事务门。快速双击只能拿到一个 token；
    /// summary/selection 或 modal occupancy 变化后，旧投影绝不能覆盖新界面。
    @State private var smartCareDeletePreviewGate = SmartCareDeletePreviewGate()
    @State private var presetCategories: [ScanCategory] = ScanCategories.recommended()
    @State private var customCategories: [ScanCategory] = []
    @State private var isCustomPathImporterPresented = false
    /// v2026.07.16：保存导入结果语义而非本地化字符串，语言切换立即重投影；系统原始
    /// Error 只写日志，不进入 alert。
    @State private var customPathImportNotice: SettingsPathImportNotice?
    @State private var professionalColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedCategory: ScanCategory.ID?
    @State private var selection: Set<String> = []   // 勾选的 row.id
    /// v2026.06.21 perf：默认勾选已扫描过的 rows.count 上限，避免每次 publish
    /// 都对整个 snapshot.rows 做 O(N) filter + N 次 `selection.contains` 哈希。
    /// `onChange(rows.count)` 触发时只需检查 `[lastDefaultSelectedSeenCount...]`
    /// 的"末尾差量"（流式扫描 publishSnapshot 路径下 rows 只增不删，见
    /// [ScanCoordinator.publishSnapshot](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L2729)），
    /// dev 扫数千行场景下从每帧 O(N) 降为每帧 O(Δ)（Δ = 本帧新增行数，常 < 50）。
    /// 取消选中 / 切换分类时手工 reset 为 0，让下一次重新扫描全表。
    @State private var lastDefaultSelectedSeenCount: Int = 0
    /// v2026.06.22 perf：底部主列表（listResults）**扫描中**展示用快照。
    ///
    /// 用户反馈："开发者构建产物" dev 扫场景下底部 List 流式刷新太频繁，
    /// 哪怕 ScanCoordinator 已经 0.4s/帧 publishSnapshot，几百根 + node_modules
    /// 上万小文件的事件密度下 listResults 的 ForEach diff + RowView body
    /// 仍把整帧 layout 吃光，与 statusBar / footerBar 同 transaction 串行
    /// → 两个列表一起卡。
    ///
    /// 这里**只**冻结 listResults 的展示帧，**不**改 ScanCoordinator 的 publish
    /// 频率：statusBar / sidebar / footer 仍然按 0.4s 跟手。
    /// 冻结规则：
    /// - 扫描中（`coordinator.isScanning == true`）：仅从空列表补第一帧非空结果，
    ///   随后不再把 latest `coordinator.snapshot` 喂给 SwiftUI List。
    /// - 非扫描中（finished / idle / 切换分类清空）：立刻同步 latest，
    ///   保证扫描结束瞬间用户立刻看到完整列表。
    @State private var throttledListSnapshot: ScanSnapshot? = nil
    /// v1.3.ab：原本是 `RowItem?`，但 `List(selection:)` 用整结构体当 key 会让 SwiftUI 在
    /// snapshot 高频 publish 时（点 Preferences 这种条目几千的目录）对每行做 `==` 比较 + diff，
    /// 主线程被刷爆 → 鼠标彩虹球。改为只押 row.id（String），detail 渲染时再反查。
    @State private var detail: String?
    @State private var deleteSheetRequest: DeleteSheetRequest?
    @State private var deleteSubmissionHandoff = DeleteSubmissionHandoff()
    /// v2026.07.19 performance regression closure: Professional execution starts from the confirm
    /// callback, while only its follow-up presentation waits for the sheet dismissal animation.
    @State private var professionalDeletePresentationHandoff =
        ProfessionalDeletePresentationHandoff<ProfessionalDeleteDeferredPresentation>()
    /// v2026.06.21：切换 category 前若已有扫描结果，弹确认对话框。
    /// v2026.06.22 修订：确认必须发生在写入 `selectedCategory` 之前。
    /// SwiftUI `List(selection:)` 的默认 binding 会先切屏、后触发 `.onChange`，用户看到的就是
    /// "已经切到大文件了才问是否切换"。现在 sidebar 走自定义 binding setter，
    /// `pendingCategorySwitch` 只保存用户意图；确认通过后才真正写入 selectedCategory。
    @State private var pendingCategorySwitch: MainCategorySwitchIntent?
    @State private var confirmedCategorySwitch: MainCategorySwitchIntent?
    @State private var showSwitchCategoryConfirm: Bool = false
    /// 删除中的 UI guard。删除完成后仅按 TrashPipeline 返回的 movedPairs 更新 UI，
    /// 防止部分失败时把未移动的项误移除。
    @State private var isDeleting: Bool = false
    @State private var isPreparingDeletion: Bool = false
    /// Stash 本身是 sheet；删除意图先冻结，待 Stash 真正 dismiss 后再呈现统一
    /// DeleteSheet，避免 sibling sheet 竞争导致失败结果不可见。
    @State private var stashSheetHandoff = SheetDismissalHandoff<StashDismissalAction>()
    @State private var deleteResult: String?

    /// **v2026.06.16 修复 #4**：删除主路径 + 大文件 trash 的结构化结果 sheet。
    /// 取代旧 alert 拼接 `delete.result.success/failure %@ %lld %lld` 的纯文字弹窗。
    /// `deleteResult` 仍保留——`delete.result.path_invalid` 等纯路径校验提示仍走旧 alert。
    @State private var deleteResultCompletion: OperationResultCompletion?
    @State private var deleteSuccessFeedback: MainDeletionSuccessFeedback?
    @State private var deletePreflightNotice: DeletionPreflightNotice?
    @State private var isDropTargeted: Bool = false
    /// v1.0 T3：结果区视图模式（清单 vs 多层树）。
    ///
    /// **v1.3.zzzz Phase 4-A**：方案 C 落地——默认走树形（`.tree`），
    /// 与 [CleanMyMac Smart Scan](file:///Users/amuxuser/workspace/AmuxAIClean/docs/competitors/CleanMyMac.md)、
    /// [DaisyDisk sunburst](file:///Users/amuxuser/workspace/AmuxAIClean/docs/competitors/DaisyDisk.md) 同款"层次化主视图"对齐。
    /// 清单**降级为可切换二级视图**（保留入口，不删 [listResults](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift#L611)）：
    /// - 清单仍然挂载在 [viewModeBar](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift#L590) 的 segmented Picker 里随时切回
    /// - 但视觉默认强调"树形"是主路径，让用户首屏看到的是层次化容量分布
    /// - 批量勾选 / mtime 过滤等"清单专属能力"先不迁移到树（避免风险面爆炸）
    @State private var viewMode: ResultsViewMode = MainView.phase4ADefaultViewMode

    /// Phase 4-A 单一信源：方案 C 选定的默认视图模式。
    /// 把默认值从 @State inline literal 提到 static 常量，**让测试能稳定断言**——
    /// SwiftUI @State 的初始值不是 protocol 可见的，没法从外部反射；提一层就能 lock。
    /// 任何回滚到 `.list` 的改动都会让 [`testPhase4ADefaultIsTree`](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Tests/AppUITests/AppUITests.swift) 直接红。
    public static let phase4ADefaultViewMode: ResultsViewMode = .tree
    /// v1.0 T4：大文件视图选中项。与 detail（RowItem）解耦，
    /// 因为大文件是叶子，没有聚合 RowItem 模型。
    @State private var largeFileSelection: LargeFileItem?
    /// v2026.07 Q1：大文件视图的批量选择状态。
    ///
    /// **提升到 MainView 的原因**：底部 [footerBar](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift#L1671-L1730)
    /// 大文件分支必须与 LargeFilesView 头部三态 checkbox 共享**同一份 selection**，
    /// 否则会出现"复选框勾了 3 项但底部按钮 disabled"的错觉（用户反馈 Q1 根因）。
    /// `BatchSelection` 是 `ObservableObject`，由 `@StateObject` 持有唯一实例，
    /// `selected` 变更会同步驱动头部 checkbox 与 footer 按钮。
    @StateObject private var largeFilesBatch = BatchSelection()
    @State private var visibleLargeFileItems: [LargeFileItem] = []
    /// 树形视图选中行。bug A：之前 TreeBrowserView 的 selectedPath 锁在自身内部，
    /// 外层 detailPane 永远拿不到，详情面板因此长期空白。现在通过 onSelect 回调
    /// 同步到这里，detailPane 优先用 treeSelection 渲染（语义上"看哪个就显哪个"）。
    @State private var treeSelection: TreeRow?
    @State private var canDeleteSelectedTreeRow: Bool = false
    @State private var treeSelectionEligibilityTask: Task<Void, Never>?
    /// Parent-to-Tree selection reset channel. Tree owns its AppKit selection locally for
    /// performance, so clearing only `treeSelection` would hide detail while leaving the row
    /// highlighted and unable to reopen on the next identical click.
    @State private var treeSelectionResetRevision: UInt64 = 0
    @State private var deletionPresentationRequestRevision: UInt64 = 0
    /// v1.0 T4：大文件入口类目。固定一项，放在侧边"大文件"独立 section。
    private let largeFilesCategory: ScanCategory = .largeFiles()
    /// v1.0 T5：路径栏临时输入（"/" + Enter 扫整盘；任意已存在目录路径也可直扫）。
    @State private var pathBarInput: String = ""
    @State private var scanInputRequest = MainScanInputRequestState()
    @State private var scanInputTask: Task<Void, Never>?
    /// v1.3：toolbar 路径输入框聚焦态。
    /// 目的：在 `ToolbarItem(.principal)` 里 SwiftUI/AppKit 默认 focus ring 会被 toolbar 容器
    /// 上下裁掉一截（截图反复出现的灰边）；改为 `.textFieldStyle(.plain)` + 自绘 Capsule 背景，
    /// 聚焦时把 Capsule 描边加重 + 用 accentColor 强化，视觉上替代原生 focus ring 且不会被裁。
    /// 参考：tmp/competitors/Pearcleaner FileListView.swift L108-L131 同款做法。
    @FocusState private var pathBarFocused: Bool

    /// v1.5 review-fix #9：状态条多根 progress 列表的滚动区高度。
    /// caption 字号 ≈ 11pt × ~6 行 ≈ 120pt 是默认；用 @ScaledMetric 跟随
    /// Dynamic Type 缩放，避免大字号下能看到的行数减半。
    @ScaledMetric(relativeTo: .caption) private var multiRootProgressScrollMaxHeight: CGFloat = 120

    /// v1.6 Sentinel：用户态 Agent 通过 `amuxaiclean://action/scan/full` 唤起主 App 时，
    /// 不自动开扫（用户在 Step 6.4 决策中选了 C：避免突袭式 IO 抢占），而是弹一个引导 alert，
    /// 用户点「立即扫描」才走 ScanCoordinator.scanRecommended。
    @State private var sentinelScanInvitationVisible: Bool = false
    /// Sentinel 深链接可能在其它 sheet / alert / fileImporter 占用窗口时到达。
    /// 只冻结意图并 FIFO 延后，不能抢 presentation，也不能静默丢失。
    @State private var sentinelPresentationQueue = SentinelPresentationQueue()

    /// 结果区两种视图模式。
    public enum ResultsViewMode: String, CaseIterable, Identifiable {
        case list, tree
        public var id: String { rawValue }
        /// 非 SwiftUI / 旧调用方的进程默认文案；运行期界面用 `label(locale:)`。
        var label: String { label(locale: .current) }
        func label(locale: Locale) -> String {
            AppLocalization.string(
                self == .list ? "main.results.mode.list" : "main.results.mode.tree",
                locale: locale
            )
        }
        var icon: String { self == .list ? "list.bullet" : "rectangle.grid.1x2" }
    }

    private let pipeline: any DeletionPipeline
    /// 所有独立清理入口都必须使用与主删除链相同的 vendor 规则快照。
    /// 各入口保留独立 pipeline，避免并发操作通过可变 denied-path 快照互相污染。
    private let vendors: [VendorRule]
    private let duplicatePipeline: any DeletionPipeline
    private let brewPipeline: any DeletionPipeline
    private let uninstallPipeline: any DeletionPipeline
    /// v2026.07.20 P0: a scripted pipeline and its Undo owner form one persistence domain.
    /// Keeping the store beside the pipeline prevents Preview/tests from exercising an injected
    /// pipeline while silently committing its synthetic moved pairs to the user's shared history.
    private let undoHistoryStore: UndoHistoryStore
    private let recorder: HeuristicRecorder
    @ObservedObject private var settings: AppSettings
    private let pathStore: UserPathStore
    @ObservedObject private var settingsNavigation: SettingsNavigation
    /// M5 / 2026-06：AI 模块配置。**必须由 App 层注入**与 [SettingsScene](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SettingsScene.swift)
    /// 共享同一份 ObservableObject 实例：用户在 ⌘, 切 AI Enabled → RowView contextMenu
    /// 的"问 AI"项要立刻刷新可见性。若各自 new 两份独立实例，虽然底层 UserDefaults
    /// 一致，但 ObservableObject 的 in-process 通知不会跨实例传，会导致需重启 App 才生效
    /// （Review fix #2，2026-06-15）。为兼容旧测试构造保留可选参数；省略时仍 new
    /// 一份私有实例（同 process 内只有 MainView 自己用，无 drift 风险）。
    @StateObject private var aiSettings: AISettings
    /// 用户在 contextMenu 点过的最近一行 —— 非 nil 即弹 [AIAdviceSheet](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)。
    @State private var aiAskingRow: RowItem?
    /// v1.5 P2 / Q3：AI 未配置时点击"问 AI"会把这里置 true，弹 alert 引导用户前往设置。
    /// 旧实现是按钮直接隐藏 / disabled —— 用户根本不知道有这个能力。
    @State private var aiUnconfiguredAlert: Bool = false
    /// 普通模式 AI 复核拥有独立 session：保存完整建议、批次终态、取消与扫描世代。
    /// 它只记录用户开始复核时的选择快照，绝不自动回写 SafetyVerdict 或选择。
    @StateObject private var smartCareAIReviewSession: SmartCareAIReviewSession
    /// Keychain 是同步系统 API 的 actor 包装；读取期间同样属于一次 AI 运行。
    /// 独立 gate 防止快速连点创建两批任务，并让取消能覆盖“尚未发出首个请求”的阶段。
    /// v2026.07.16：gate 的 `isPreparing` 是用户可见 loading 状态；必须订阅其
    /// ObservableObject 发布，不能用只保存引用身份的 `@State`，否则预检期界面不刷新。
    @StateObject private var smartCareAIPreparationGate = SmartCareAIReviewPreparationGate()
    /// v2026.06.18 **稍后处理（购物车）**：跨视图共享的待处理集合。
    /// 来源：tree row contextMenu → onStash → 入库；
    /// 出口：toolbar 右侧"待处理(N)"按钮 → 打开 [StashScreen](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/StashScreen.swift)。
    /// 用 @StateObject 持 StashStore 实例，与 MainView 同生命周期；不持久化（参考购物车语义）。
    @StateObject private var stash: StashStore = StashStore()
    /// 控制 [StashScreen](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/StashScreen.swift)
    /// sheet 的开关；与 [stash](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 分开以便 sheet dismiss 时不会清空购物车数据。
    @State private var isStashScreenPresented: Bool = false
    /// v2026.06.19 **一键 AI 队列引擎**。与 [stash](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 同生命周期；sheet 关闭时不取消跑中的队列（用户可能想后台先跑着，回头再开）。
    /// 实际并不会在 sheet 关闭后继续可见进度——但已得到的 verdict 仍然写在 store
    /// 里，下次打开 sheet 依然能看到徽标。
    @StateObject private var stashAIQueue: StashAIQueue = StashAIQueue()

    public init(pipeline: (any DeletionPipeline)? = nil,
                vendors: [VendorRule],
                undoHistoryStore: UndoHistoryStore,
                recorder: HeuristicRecorder = .shared,
                settings: AppSettings? = nil,
                pathStore: UserPathStore? = nil,
                coordinator: ScanCoordinator? = nil,
                smartCareSession: SmartCareSession? = nil,
                smartCareAIReviewSession: SmartCareAIReviewSession? = nil,
                aiSettings: AISettings? = nil,
                settingsNavigation: SettingsNavigation? = nil,
                applicationPresentation: MainWindowPresentationCoordinator? = nil,
                onTCCGuideDismiss: @escaping (Bool) -> Void = { _ in }) {
        // v0 默认走 NSWorkspace.recycle（PITFALLS §5.9）：不需要 root，不需要 99 美元 Apple Developer Program
        // 用户撤销可以走 Finder → 显示废纸篓 → 放回原位
        // M4-P0 修复：把 vendors 透传到 TrashPipeline，让最后闸门启用 vendor 路径树判定
        self.vendors = vendors
        let primaryPipeline = pipeline ?? TrashPipeline.production(
            vendors: vendors,
            whitelistStore: .shared
        )
        self.pipeline = primaryPipeline
        // An injected pipeline is an isolated test/Preview domain. Reuse it for nested tools so
        // constructing MainView cannot prewarm production recovery stores behind the caller's
        // back. Production omits the injection and retains independent pipelines per surface.
        self.duplicatePipeline = pipeline ?? TrashPipeline.production(
            vendors: vendors,
            whitelistStore: .shared
        )
        self.brewPipeline = pipeline ?? TrashPipeline.production(
            vendors: vendors,
            whitelistStore: .shared
        )
        // v2026.07.20 P1: the uninstall surface belongs to the same explicit
        // pipeline + Undo persistence domain as its MainView owner. Reusing an
        // injected pipeline prevents tests/Previews from initializing production
        // recovery stores simply by navigating to the uninstall screen.
        self.uninstallPipeline = pipeline ?? TrashPipeline.production(
            vendors: vendors,
            whitelistStore: .shared
        )
        self.undoHistoryStore = undoHistoryStore
        self.recorder = recorder
        let resolvedSettings = settings ?? AppSettings()
        _settings = ObservedObject(wrappedValue: resolvedSettings)
        _applicationPresentation = StateObject(wrappedValue: applicationPresentation
            ?? MainWindowPresentationCoordinator(updateChecker: UpdateChecker(settings: resolvedSettings)))
        self.onTCCGuideDismiss = onTCCGuideDismiss
        self.pathStore = pathStore ?? UserPathStore()
        _settingsNavigation = ObservedObject(
            wrappedValue: settingsNavigation ?? SettingsNavigation()
        )
        // v1.3：coordinator 允许从 App 层注入，让 [FloatingScanHUD](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
        // 与主窗口共享同一个 ScanCoordinator 实例（订阅同一份 snapshot/isScanning），避免双扫。
        let sharedAdmissionRegistry = coordinator?.primaryScanAdmissionRegistry
            ?? smartCareSession?.scanCoordinator.primaryScanAdmissionRegistry
            ?? PrimaryScanAdmissionRegistry()
        // Preview/test fallback coordinators share physical admission but never share client
        // identity. Latest-wins invalidation can therefore distinguish a same-surface rescan from
        // a cross-mode replacement and revoke only the presentation that actually departed.
        let professionalAdmissionClientID = coordinator?.primaryScanAdmissionClientID
            ?? PrimaryScanAdmissionRegistry.ClientID()
        let smartCareAdmissionClientID = smartCareSession?.scanCoordinator.primaryScanAdmissionClientID
            ?? PrimaryScanAdmissionRegistry.ClientID()
        let professionalCoordinator = coordinator ?? ScanCoordinator(
            vendors: vendors,
            primaryScanAdmissionRegistry: sharedAdmissionRegistry,
            primaryScanAdmissionClientID: professionalAdmissionClientID
        )
        _coordinator = StateObject(wrappedValue: professionalCoordinator)
        _smartCareSession = StateObject(wrappedValue: smartCareSession ?? SmartCareSession(
            scanCoordinator: ScanCoordinator(
                vendors: vendors,
                primaryScanAdmissionRegistry: sharedAdmissionRegistry,
                primaryScanAdmissionClientID: smartCareAdmissionClientID
            )
        ))
        // v2026.09.06: the storage workspace has its own result identity but joins the
        // same physical scan admission domain, so switching tools never overlaps walkers.
        _storageAnalysis = StateObject(wrappedValue: StorageAnalysisStore(scanner: ScanCoordinator(
            vendors: vendors,
            primaryScanAdmissionRegistry: sharedAdmissionRegistry,
            systemProbeStore: professionalCoordinator.systemProbe
        )))
        _smartCareAIReviewSession = StateObject(
            wrappedValue: smartCareAIReviewSession ?? SmartCareAIReviewSession()
        )
        // M5 / Review fix #2：AISettings 必须 App 层注入。未注入时（老测试 / 预览）退回独立实例。
        _aiSettings = StateObject(wrappedValue: aiSettings ?? AISettings())
    }

    /// 全部类目（preset + custom + libraryBrowse + largeFiles + fullDisk）—— 用于 toolbar / scan 查找。
    /// 资源库浏览入口必须包含进来，否则 onChange selectedCategory 找不到对应 ScanCategory，
    /// 会直接 return 不触发扫描。
    private var allCategories: [ScanCategory] {
        presetCategories + customCategories + libraryBrowseCategories + [largeFilesCategory, ScanCategory.fullDisk]
    }

    /// 资源库浏览：5 个固定的 ~/Library 子目录入口。
    /// 走 ScanCategory.makeCustom(url:) 流程以复用扫描/UI 路径，但**不写入 pathStore**——
    /// 这是预置只读入口，不能污染用户「自定义路径」列表（也不应在退出后保留）。
    /// 故这里只在视图层即席构造，不调用 pathStore.add。
    private var libraryBrowseCategories: [ScanCategory] {
        let paths = [
            "~/Library",
            "~/Library/Application Support",
            "~/Library/Containers",
            "~/Library/Group Containers",
            "~/Library/Preferences",
        ]
        return paths.map { raw in
            let expanded = (raw as NSString).expandingTildeInPath
            return ScanCategory.makeCustom(url: URL(fileURLWithPath: expanded))
        }
    }

    /// v1.3 review-fix B3：拿到 SwiftUI 的"打开/重建窗口" action，让 App 层在主窗口被
    /// 用户 ⌘W 关闭并销毁后，仍能通过通知中心请求重建。配合 `WindowGroup(id: "main")` 使用。
    @Environment(\.openWindow) private var openWindow

    public var body: some View {
        applicationSceneContent
            .background {
                MainWindowActionsAccessory(content: permanentWindowActions,
                    layoutIdentity: MainWindowActionsLayoutIdentity(mode: interfaceMode,
                        isScanning: coordinator.hasActivePrimaryScanOwnership,
                        stashCount: min(stash.count, 100), localeIdentifier: locale.identifier))
                    .frame(width: 0, height: 0)
                MainWindowPresentationHost(coordinator: applicationPresentation, hostID: presentationHostID)
                    .frame(width: 0, height: 0)
                ControlGuideHost(
                    anchors: guideAnchors, presentationID: activeControlGuideID,
                    mode: interfaceMode,
                    requiredTargets: ControlGuideTarget.requiredTargets(mode: interfaceMode,
                        showsAnalysisControls: normalSection == .analyze),
                    locale: locale,
                    isFocusedHost: applicationPresentation.isFocusedHost(presentationHostID),
                    onFocus: { applicationPresentation.focusHost(presentationHostID) },
                    onEnd: finishControlGuide
                ).frame(width: 0, height: 0)
            }
            .environment(\.controlGuideAnchors, guideAnchors)
            .environment(\.mainWindowPresentationCoordinator, applicationPresentation)
            .environment(\.mainWindowPresentationHostID, presentationHostID)
            .onValueChange(of: activeControlGuideID) { _, id in
                // A full Professional tour teaches the sidebar even if the user had collapsed it.
                if id != nil, interfaceMode == .professional { professionalColumnVisibility = .all }
            }
    }

    // v2026.10.10: keep sheet composition and scene observers in distinct expressions;
    // the shared presentation lifecycle otherwise exceeds Swift's type-checking budget.
    private var mainBusinessPresentation: some View {
        // v1.3.aa：三列 → 两列。原本 NavigationSplitView { sidebar / content / detail }
        // 在嵌套子屏（AppFootprintScreen / UninstallScreen / DuplicateScreen / LaunchAgentScreen）
        // 的内部分栏里出现「外层 detail 列被挤剩极窄一条 + 旋转 90° 占位文字」的视觉灾难
        // （问题 4 的截图）；同时切 tab 时外层 detail 也容易残留上一屏的内容（问题 2）。
        // 现在外层只有 sidebar + content，细节区由各底层屏自己负责（清单/树形复用 results 内的 inline 详情区）。
        Group {
            switch interfaceMode {
            case .normal:
                normalWorkspace
            case .professional:
                NavigationSplitView(columnVisibility: $professionalColumnVisibility) {
                    sidebar
                } detail: {
                    // The example is a sibling of results, like the sidebar's fixed capacity
                    // area. It participates in normal column layout without a top safe-area owner.
                    VStack(spacing: 0) {
                        if activeControlGuideID != nil { professionalRowActionsGuide }
                        results
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbar { toolbar }
        // v2026.06.21：切换扫描目标前确认。`titleVisibility: .visible` 让 message 不被吃掉。
        // 设计：role:.destructive 暗示"放弃当前结果"是有损操作；cancel 同时复位 selection
        // 回到 old（用 isRevertingSelection 短路再次 onChange）。
        .confirmationDialog(
            AppLocalization.string("mainview.switch_category.confirm.title", locale: locale),
            isPresented: $showSwitchCategoryConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard let pending = pendingCategorySwitch else { return }
                pendingCategorySwitch = nil
                confirmedCategorySwitch = pending
                showSwitchCategoryConfirm = false
                consumeConfirmedCategorySwitchIfPossible()
            } label: {
                Text("mainview.switch_category.confirm.proceed", bundle: .module)
            }
            Button(role: .cancel) {
                pendingCategorySwitch = nil
            } label: {
                Text("mainview.switch_category.confirm.cancel", bundle: .module)
            }
        } message: {
            Text("mainview.switch_category.confirm.message", bundle: .module)
        }
        .alert(
            AppLocalization.string(
                "smart_care.developer_cache_warning.title",
                locale: locale
            ),
            isPresented: $showSmartCareDeveloperCacheWarning
        ) {
            Button(
                AppLocalization.string(
                    "smart_care.developer_cache_warning.enable",
                    locale: locale
                )
            ) {
                settings.smartCareDeveloperCacheWarningAcknowledged = true
                smartCareSession.setStage(.developerCaches, selected: true)
            }
            Button(
                AppLocalization.string(
                    "smart_care.developer_cache_warning.cancel",
                    locale: locale
                ),
                role: .cancel
            ) {}
        } message: {
            Text(
                AppLocalization.string(
                    "smart_care.developer_cache_warning.message",
                    locale: locale
                )
            )
        }
        .localizedSheet(
            item: $deleteSheetRequest,
            onDismiss: finishProfessionalDeleteSheetDismissal
        ) { request in
            ToolTrashConfirmationSheet(
                items: request.preparedInteraction.confirmationCandidates,
                totalBytes: request.totalBytes,
                vendorOverrideRequest: request.preparedInteraction.vendorOverrideRequest,
                scanIncompleteOverrideRequest: request.preparedInteraction.scanIncompleteOverrideRequest,
                onCancel: {
                    deleteSheetRequest = nil
                },
                onConfirm: { executionPlan in
                    let confirmedAt = ProcessInfo.processInfo.systemUptime
                    guard professionalDeletePresentationHandoff.canBeginSheetDismissal,
                          let submission = deleteSubmissionHandoff.beginProfessionalSubmission(
                            request: request,
                            executionPlan: executionPlan
                          ) else { return false }
                    guard professionalDeletePresentationHandoff.beginSheetDismissal() else {
                        _ = deleteSubmissionHandoff.finishProfessionalSubmission()
                        return false
                    }
                    let timing = ProfessionalDeleteTiming(
                        traceID: UUID(),
                        confirmedAtUptime: confirmedAt,
                        itemCount: executionPlan.paths.count
                    )
                    startProfessionalDeleteSubmission(submission, timing: timing)
                    deleteSheetRequest = nil
                    return true
                }
            )
        }
        .localizedSheet(
            item: $smartCareSheetRoute,
            onDismiss: finishSmartCareSheetDismissal
        ) { route in
            switch route {
            case .aiReview(let report):
                SmartCareAIReviewResultSheet(
                    report: report,
                    currentSelectedItemIDs: smartCareSession.care.selection.selectedIDs,
                    onClose: dismissSmartCareSheet,
                    onRetryFailed: retryFailedSmartCareAIReview,
                    onContinueRemaining: continueSmartCareAIReview,
                    onApplySelectionChanges: applySmartCareAISelectionChanges,
                    onReviewCleanup: transitionFromAIReportToCleanupPreview,
                    onOpenSettings: openSmartCareAISettings,
                    onRerun: rerunSmartCareAIReview
                )
            case .cleanup(let request):
                DeleteSheet(
                    items: request.previewRows,
                    onCancel: dismissSmartCareSheet,
                    onConfirm: { action in
                        guard deleteSubmissionHandoff.schedule(
                            .smartCare(
                                request: request,
                                action: action,
                                accessDeniedPaths: smartCareSession.deletionDeniedPaths
                            )
                        ) else { return }
                        smartCareSheetRoute = nil
                    }
                )
            }
        }
        // M5 / 2026-06：AI 询问 sheet —— item-based 触发，aiAskingRow 非 nil 即弹。
        .localizedSheet(item: $aiAskingRow) { row in
            AIAdviceSheet(row: row,
                          aiSettings: aiSettings,
                          onClose: { aiAskingRow = nil })
        }
        // v1.5 P2 / Q3：AI 未配置时点击"问 AI" → 弹"前往设置？"alert，
        // 用户确认则通过标准 Command-, 菜单项打开 Settings scene。
        // 取代旧的"按钮直接隐藏 / disabled"路径，让用户知道有这能力 + 怎么开。
        .alert(AppLocalization.string("ai.unconfigured.alert.title", locale: locale),
               isPresented: $aiUnconfiguredAlert) {
            Button(AppLocalization.string("ai.unconfigured.alert.open_settings", locale: locale)) {
                settingsNavigation.select(.ai)
                openSettingsWindow()
            }
            Button(AppLocalization.string("ai.unconfigured.alert.cancel", locale: locale),
                   role: .cancel) {}
        } message: {
            Text(AppLocalization.string("ai.unconfigured.alert.message", locale: locale))
        }
        // v2026.06.18 **稍后处理 sheet**。点 toolbar 的 `tray.full.fill` 按钮触发；
        // 在 sheet 内做"一键清理 / 一键 AI / 单独清理 / 单独 AI / 剔除"集中操作。
        // 复用现有 trigger / aiAskingRow 通道，不引入第二条删除/AI 链路。
        .localizedSheet(
            isPresented: $isStashScreenPresented,
            onDismiss: finishStashSheetDismissal
        ) {
            StashScreen(
                stash: stash,
                aiQueue: stashAIQueue,
                aiSettings: aiSettings,
                onClose: { isStashScreenPresented = false },
                onCleanOne: { entry in
                    scheduleStashDeletion([entry])
                },
                onCleanAll: { entries in
                    scheduleStashDeletion(entries)
                },
                onAskAIOne: { entry in
                    // v2026.10.10: keep this intent until native dismissal, just like Stash deletion.
                    guard stashSheetHandoff.schedule(.askAI(makeAIQueryRow(from: entry))) else { return }
                    isStashScreenPresented = false
                },
                onRunAIBatch: {
                    // v2026.06.19 一键 AI 队列入口：
                    // 把闭包推给 [StashAIQueue.start](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/StashAIQueue.swift)，
                    // 它内部串行循环 + 每条单独写回 stash 缓存。
                    // 重置上一轮的 verdict，避免新跑的 done 跟旧的 done 视觉上混淆——
                    // 用户期望"一键 AI"是一次干净的重新评估。
                    stash.clearAIVerdicts()
                    stashAIQueue.start(stash: stash, aiSettings: aiSettings)
                }
            )
        }
        // 删除结果提示：真删完成后按 movedPairs 更新列表；失败 / 拦截项留在原处并通过结果弹窗说明。
        .alert(
            AppLocalization.string("main.delete.result.title", locale: locale),
            isPresented: Binding(
                get: { deleteResult != nil },
                set: { if !$0 { deleteResult = nil } }
            )
        ) {
            Button(AppLocalization.string("main.delete.result.ok", locale: locale)) { deleteResult = nil }
        } message: {
            Text(deleteResult ?? "")
        }
        .alert(
            AppLocalization.string("custom_path.import.notice.title", locale: locale),
            isPresented: Binding(
                get: { customPathImportNotice != nil },
                set: { if !$0 { customPathImportNotice = nil } }
            )
        ) {
            Button(AppLocalization.string("main.delete.result.ok", locale: locale)) {
                customPathImportNotice = nil
            }
        } message: {
            Text(customPathImportNotice?.localized(locale: locale) ?? "")
        }
        // 删除结果只展示已经跨过 NSWorkspace.recycle 提交边界的真实尝试。
        // 最终重验发现的新风险会回到严格确认或 typed explanation，不会先进结果页。
        .localizedSheet(item: $deleteResultCompletion) { completion in
            OperationResultSheet(
                completion: completion,
                onDismiss: { deleteResultCompletion = nil }
            )
        }
    }

    private var applicationSceneContent: some View {
        mainBusinessPresentation
        // v2026.10.10: the control tour is an in-window overlay. TCC/update keep their native
        // sheets; all three retain the same per-window request/admission owner.
        .localizedSheet(item: Binding<MainWindowPresentationCoordinator.Presentation?>(
            get: { activeApplicationSheet },
            set: { if $0 == nil { applicationPresentation.dismiss(hostID: presentationHostID) } }
        ), onDismiss: finishApplicationSheetDismissal, tracksMainWindowOccupancy: false) { presentation in
            applicationSheetContent(presentation)
        }
        .operationSuccessFeedbackOverlay($deleteSuccessFeedback)
        // v2026.10.14: failures own a modal explanation; the success overlay remains success-only.
        .deletionPreflightNoticeSheet($deletePreflightNotice)
        .onValueChange(of: viewMode) { _, _ in
            // bug A：清单 ↔ 树形 切换时各清各的选中态，避免两条选中互相覆盖。
            detail = nil
            treeSelection = nil
        }
        .onValueChange(of: settings.minFileSizeMB) { _, _ in
            // v1.0 T4：阈值改变时，若当前正看大文件视图，自动重扫，
            // 让 ROADMAP 验收 3「改阈值到 500 → 重扫 → 列表变短」无需用户额外动作。
            // 注意：只有当扫描期阈值与新阈值差异显著（即更小阈值）时才需要重扫；
            // 若新阈值更大，largeFiles(...) 在视图层就能直接二次过滤，省一次 IO。
            guard let id = selectedCategory,
                  id == largeFilesCategory.id,
                  !coordinator.hasActivePrimaryScanOwnership else { return }
            let newScanBytes = Int64(max(0, settings.minFileSizeMB)) * 1024 * 1024
            if newScanBytes < coordinator.largeFileScanThresholdBytes {
                startScan(category: largeFilesCategory)
            }
        }
        .modifier(SmartCareAIReportObserverModifier(
            latestReport: smartCareAIReviewSession.latestReport,
            canPresentPendingReport: canPresentPendingSmartCareAIReport,
            onLatestReportChange: handleSmartCareAIReportChange,
            onPendingAvailabilityChange: presentPendingSmartCareAIReportIfPossible
        ))
        .onValueChange(of: settings.mainListSortKey) { _, newKey in
            // v1.3：主列表排序键切换 → 同步到 coordinator。
            // coordinator 内部 didSet 会判断仅 finished 态 republish snapshot，
            // 扫描中切换不会扰乱视觉位置（扫描中强制 path 字典序保持稳定）。
            coordinator.mainListSortKey = newKey
        }
        .onValueChange(of: locale.identifier, initial: true) { _, _ in
            // v2026.07.15：扫描协调器中的格式串/兼容标题也必须使用当前界面语言；
            // 只同步 locale，不重建扫描 frame、不重扫磁盘。
            coordinator.updatePresentationLocale(locale)
            smartCareSession.scanCoordinator.updatePresentationLocale(locale)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $isCustomPathImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true,
            onCompletion: handleCustomPathImport
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // v1.3：从系统设置勾完 FDA 切回本 App，立即重探权限状态 + 容量。
            // 修「我已经有了权限，为什么顶部还提示需要授权」的核心闭环——
            // 用户回来那一刻 banner 自动消失，不需要重新扫描或重启 App。
            coordinator.refreshFDAStatus()
            smartCareSession.scanCoordinator.refreshFDAStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxOpenMainWindowRequested)) { _ in
            ensureMainWindowFocused()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxTrashPendingLedgerDidInvalidate)) { _ in
            storageAnalysis.invalidateAfterExternalChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxTrashDidMove)) { notification in
            let source = notification.userInfo?["source"] as? String
            let paths = notification.userInfo?["paths"] as? [String] ?? []
            if !paths.isEmpty {
                stash.remove(paths: paths)
                largeFilesBatch.remove(paths: paths)
            }
            if source != DeleteRequestOrigin.storageAnalysis.historySource {
                storageAnalysis.applyExternalDeletedPaths(paths)
            }
            guard let source,
                  !["smart-care", "clean", "tree", "large-file", "stash"].contains(source),
                  !paths.isEmpty else { return }
            Task { @MainActor in
                await synchronizeSuccessfulDeletion(
                    paths: paths,
                    authoritativeSurface: interfaceMode == .normal ? .smartCare : .professional
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxSentinelStartFullScan)) { _ in
            // v1.6 Sentinel 场景 2：用户态 Agent 通过 `amuxaiclean://action/scan/full` 唤起。
            // 用户决策 C：不自动开扫，弹引导 alert，让用户主动确认。
            enqueueSentinelPresentation(.inviteFullScan)
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxSentinelOpenUninstall)) { note in
            // v1.6 Sentinel 场景 1：用户态 Agent 通过 `amuxaiclean://uninstall?path=...` 唤起卸载页。
            // path 已由 [SentinelURLRouter](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SentinelURLRouter.swift) 校验过；
            // 这里把侧栏定位到 uninstall sentinel row，让 UninstallScreen 显示。
            // 注：path 当前不直接 deep-link 到具体卸载条目（候选展示在 UninstallScreen 列表里），
            // 后续可通过 NotificationCenter 二次广播由 UninstallScreen 自己消费 path 实现高亮。
            enqueueSentinelPresentation(.openUninstall(
                path: note.userInfo?[SentinelURLRouter.uninstallPathKey] as? String
            ))
        }
        .onValueChange(of: hasConflictingMainModalPresentation) { _, isBusy in
            // 所有 modal 共用 occupancy 边沿；当前 presentation 真正消失后再继续消费
            // Sentinel FIFO。调度器内部还会 yield 一轮，避免和 AppKit dismiss 动画竞争。
            if !isBusy {
                schedulePendingApplicationPresentationIfPossible()
                schedulePendingSentinelPresentationIfPossible()
            }
        }
        .onValueChange(of: applicationPresentation.requestRevision) { _, _ in
            consumeConfirmedCategorySwitchIfPossible()
            schedulePendingApplicationPresentationIfPossible()
        }
        .onValueChange(of: applicationPresentation.businessModalCount(for: presentationHostID)) { _, count in
            if count == 0 {
                consumeConfirmedCategorySwitchIfPossible()
                schedulePendingApplicationPresentationIfPossible()
                schedulePendingSentinelPresentationIfPossible()
            }
        }
        .alert(
            AppLocalization.string("sentinel.alert.scan_invitation.title", locale: locale),
            isPresented: $sentinelScanInvitationVisible
        ) {
            Button(AppLocalization.string("sentinel.alert.scan_invitation.action_scan", locale: locale)) {
                transitionInterfaceMode(to: .normal)
                selectNormalSection(.clean)
                startSmartCareScan()
            }
            Button(AppLocalization.string("sentinel.alert.scan_invitation.action_dismiss", locale: locale), role: .cancel) {}
        } message: {
            Text("sentinel.alert.scan_invitation.message", bundle: .module)
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .task {
            // v1.3：主列表排序键同样在启动时同步，避免持久化值与 coordinator 默认值不一致。
            coordinator.mainListSortKey = settings.mainListSortKey
            isPresentationHostMounted = true
            applicationPresentation.attachHost(presentationHostID)
            requestFirstVisitUserGuideIfNeeded()
            let snapshots = await pathStore.snapshots()
            for await urls in snapshots {
                guard !Task.isCancelled else { return }
                customCategories = urls.map { ScanCategory.makeCustom(url: $0) }
            }
        }
        .onDisappear {
            invalidateScanInputRequest()
            confirmedCategorySwitch = nil
            isPresentationHostMounted = false
            applicationPresentation.detachHost(presentationHostID)
        }
        .onValueChange(of: scanContextIdentity) { _, _ in
            invalidateStaleScanInputRequest()
            consumeConfirmedCategorySwitchIfPossible()
        }
        .onValueChange(of: pathBarInput) { _, _ in invalidateStaleScanInputRequest() }
        .onValueChange(of: interfaceMode) { _, _ in requestFirstVisitUserGuideIfNeeded() }
        .onValueChange(of: settings.completedUserGuideModes) { _, _ in requestFirstVisitUserGuideIfNeeded() }
    }

    private func requestFirstVisitUserGuideIfNeeded() {
        guard isPresentationHostMounted else { return }
        applicationPresentation.requestFirstVisitUserGuideIfNeeded(
            hostID: presentationHostID, mode: interfaceMode,
            completedModes: settings.completedUserGuideModes, isRunningTests: Self.isRunningUnderTests
        )
        schedulePendingApplicationPresentationIfPossible()
    }

    // MARK: - Smart Care

    /// v2026.07.16 scan-performance regression fix: switching presentation modes
    /// must stop the departing *active* producer synchronously. Completed results
    /// remain available when the user switches back; deletion work is never
    /// interrupted by this control (the picker is disabled during deletion).
    private func transitionInterfaceMode(to newMode: SmartCareInterfaceMode) {
        // v2026.10.10: every route, including walkthrough completion, obeys the same transaction gate.
        guard interfaceMode != newMode, !hasActiveBusinessTransaction else { return }
        storageAnalysis.deactivate()
        let smartCareIsScanning: Bool
        if case .scanning = smartCareSession.care.phase {
            smartCareIsScanning = true
        } else {
            smartCareIsScanning = false
        }
        MainScanOwnershipPolicy.relinquishDepartingMode(
            from: interfaceMode,
            to: newMode,
            smartCareIsScanning: smartCareIsScanning,
            professionalHasActivePrimaryScan: coordinator.hasActivePrimaryScanOwnership,
            cancelSmartCare: { smartCareSession.cancelScan() },
            cancelProfessional: { coordinator.cancel() },
            cancelProfessionalTransientWork: {
                coordinator.cancelOnDemandTreeScansPreservingResults()
            }
        )
        interfaceMode = newMode
    }

    private var normalWorkspace: some View {
        NormalWorkspaceView(
            section: Binding(get: { normalSection }, set: { selectNormalSection($0) }),
            analysis: storageAnalysis,
            probe: coordinator.systemProbe,
            pipeline: uninstallPipeline,
            undoHistoryStore: undoHistoryStore,
            isBusy: hasConflictingMainModalPresentation,
            onToolBusyChange: { normalToolIsBusy = $0 },
            onClean: {
                selectNormalSection(.clean)
                if case .idle = smartCareSession.care.phase { startSmartCareScan() }
            },
            cleanContent: { smartCareHome }
        )
    }

    private func selectNormalSection(_ section: NormalWorkspaceSection) {
        guard section != normalSection else { return }
        let departingSection = normalSection
        // v2026.09.06: revoke visibility before cancellation can publish an AI terminal.
        // Normal mode now has multiple pages; late Smart Care reports belong to Clean only.
        normalSection = section
        if departingSection == .analyze { storageAnalysis.deactivate() }
        if departingSection == .clean {
            if case .scanning = smartCareSession.care.phase { smartCareSession.cancelScan() }
            cancelSmartCareAIReview()
        }
    }

    private var isSmartCareVisible: Bool {
        interfaceMode == .normal && normalSection == .clean
    }

    private var smartCareHome: some View {
        SmartCareHomeView(
            coordinator: smartCareSession.care,
            session: smartCareSession,
            aiIsConfigured: aiSettings.isReadyForUI,
            aiIsRunning: smartCareAIIsRunning,
            aiProcessed: smartCareAIProgress?.processedCount ?? 0,
            aiTotal: smartCareAIProgress?.totalCount ?? 0,
            aiError: smartCareAIErrorText,
            aiItemStates: smartCareAIItemStates,
            aiReportAvailable: smartCareAIReviewSession.latestReport != nil,
            onStageSelectionChange: handleSmartCareStageSelectionChange,
            onPrimaryAction: handleSmartCarePrimaryAction,
            onAIReview: runSmartCareAIReview,
            onAICancel: cancelSmartCareAIReview,
            onAIShowReport: showLatestSmartCareAIReport
        )
    }

    private var smartCareAIIsRunning: Bool {
        smartCareAIPreparationGate.isPreparing || smartCareAIReviewSession.phase.isRunning
    }

    private var smartCareAIProgress: SmartCareAIReviewProgress? {
        guard case .running(let progress) = smartCareAIReviewSession.phase else { return nil }
        return progress
    }

    private var smartCareAIItemStates: [String: SmartCareAIItemState] {
        var states: [String: SmartCareAIItemState] = [:]
        let outcomes: [SmartCareAIReviewItemOutcome]
        let currentItemID: SmartCareItem.ID?
        switch smartCareAIReviewSession.phase {
        case .idle:
            return states
        case .running(let progress):
            outcomes = progress.items
            currentItemID = progress.currentItemID
        case .result(let report):
            outcomes = report.items
            currentItemID = nil
        }
        states.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            switch outcome.result {
            case .notReviewed:
                states[outcome.path] = currentItemID == outcome.item.id ? .reviewing : .pending
            case .advice(let advice):
                states[outcome.path] = .advice(advice.canDelete, summary: advice.summary)
            case .failure(let failure):
                states[outcome.path] = .failed(failure.kind)
            }
        }
        return states
    }

    private var smartCareAIErrorText: String? {
        guard let failure = smartCareAIReviewSession.latestReport?.globalFailure else {
            return nil
        }
        // v2026.07.16：AI 终态属于先物化为 String 的动态文案，必须显式消费当前
        // SwiftUI locale；否则 App 内切换语言后仍会沿用进程启动语言。
        return AppLocalization.string(
            SmartCarePresentation.aiFailureSummaryKey(for: failure.kind),
            locale: locale
        )
    }

    private var smartCareAIReviewItems: [SmartCareItem] {
        let supported: [SmartCareBucketID] = [.systemJunk, .appCache, .developerCache]
        var result: [SmartCareItem] = []
        var seen: Set<String> = []
        for bucketID in supported {
            guard let bucket = smartCareSession.care.summary.buckets.first(where: { $0.id == bucketID }) else {
                continue
            }
            for item in bucket.safeItems.prefix(4) where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        for item in smartCareSession.care.summary.confirmItems.prefix(6)
        where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    private func runSmartCareAIReview() {
        guard !smartCareAIIsRunning else { return }
        let items = smartCareAIReviewItems
        let selectedItemIDs = smartCareSession.care.selection.selectedIDs
        let revision = smartCareSession.care.summaryRevision
        guard !items.isEmpty else {
            _ = smartCareAIReviewSession.finishEmpty(summaryRevision: revision)
            return
        }
        _ = smartCareAIPreparationGate.start { @MainActor in
            do {
                let worker = try await SmartCareAIReviewWorker.makeOpenAI(
                    settings: aiSettings,
                    locale: locale
                )
                try Task.checkCancellation()
                guard smartCareSession.care.summaryRevision == revision,
                      !smartCareAIReviewSession.phase.isRunning else {
                    return
                }
                _ = smartCareAIReviewSession.start(
                    items: items,
                    selectedItemIDs: selectedItemIDs,
                    summaryRevision: revision,
                    using: worker
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      smartCareSession.care.summaryRevision == revision,
                      !smartCareAIReviewSession.phase.isRunning else {
                    return
                }
                _ = smartCareAIReviewSession.failPreflight(
                    items: items,
                    selectedItemIDs: selectedItemIDs,
                    summaryRevision: revision,
                    failure: SmartCareAIReviewFailure(error: error)
                )
            }
        }
    }

    private func cancelSmartCareAIReview() {
        smartCareAIPreparationGate.cancel()
        smartCareAIReviewSession.cancel()
    }

    private func showLatestSmartCareAIReport() {
        guard let report = smartCareAIReviewSession.latestReport else { return }
        pendingSmartCareAIReport = nil
        smartCareSheetRoute = .aiReview(report)
    }

    private var hasConflictingMainModalPresentation: Bool {
        hasBusinessMainModalPresentation || applicationPresentation.isOccupied(for: presentationHostID)
            || applicationPresentation.businessModalCount(for: presentationHostID) > 0
    }

    private var hasBusinessMainModalPresentation: Bool {
        confirmedCategorySwitch != nil || hasOtherBusinessMainModalPresentation
            || deleteSheetRequest != nil
            || deleteSubmissionHandoff.blocksNewSubmission
            || smartCareDeletePreviewGate.isInFlight
            || isPreparingDeletion
            || isDeleting
            || stashSheetHandoff.hasPending
            || smartCareCleanupHandoff.hasPending
    }

    private var hasActiveBusinessTransaction: Bool {
        isPreparingDeletion || isDeleting || normalToolIsBusy
            || deleteSubmissionHandoff.blocksNewSubmission
            || smartCareDeletePreviewGate.isInFlight
            || stashSheetHandoff.hasPending || smartCareCleanupHandoff.hasPending
            || applicationPresentation.businessTransactionCount(for: presentationHostID) > 0
    }

    // v2026.10.11 review: every scan producer must check the live transaction at the
    // mutation boundary, including delayed settings/category actions and batch sentinels.
    // Disabled controls alone cannot protect asynchronous or programmatic entry points.
    private var canReplaceScanContext: Bool {
        confirmedCategorySwitch == nil
            && applicationPresentation.canReplaceScanContext(for: presentationHostID,
                                                      hasLocalTransaction: hasActiveBusinessTransaction)
    }

    private var scanContextIdentity: MainScanContextIdentity {
        MainScanContextIdentity(interfaceMode: interfaceMode, categoryID: selectedCategory,
                                scanSessionID: coordinator.currentScanSessionID)
    }

    /// Main 的所有系统 presentation 共享这一道互斥判定。异步 Safety preflight
    /// 返回时如果 fileImporter / AI / Stash / Smart Care 已占用窗口，就不能再竞争
    /// 同一个 presentation slot。
    private var hasOtherMainModalPresentation: Bool {
        confirmedCategorySwitch != nil || hasOtherBusinessMainModalPresentation
            || applicationPresentation.isOccupied(for: presentationHostID)
            || applicationPresentation.businessModalCount(for: presentationHostID) > 0
    }

    private var hasOtherBusinessMainModalPresentation: Bool {
        let smartCareIsPresented: Bool
        if case nil = smartCareSheetRoute {
            smartCareIsPresented = false
        } else {
            smartCareIsPresented = true
        }
        return smartCareIsPresented
            || normalToolIsBusy
            || professionalDeletePresentationHandoff.isAwaitingSheetDismissal
            || aiAskingRow != nil
            || isStashScreenPresented
            || deleteResultCompletion != nil
            || deletePreflightNotice != nil
            || aiUnconfiguredAlert
            || deleteResult != nil
            || customPathImportNotice != nil
            || isCustomPathImporterPresented
            || sentinelScanInvitationVisible
            || showSwitchCategoryConfirm
            || showSmartCareDeveloperCacheWarning
    }

    private static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @ViewBuilder
    private func applicationSheetContent(
        _ presentation: MainWindowPresentationCoordinator.Presentation
    ) -> some View {
        switch presentation.content {
        case .userGuide:
            EmptyView() // ControlGuideHost owns the overlay; this route never enters a native sheet.
        case .fullDiskAccess:
            TCCGuideView { openedSettings in
                onTCCGuideDismiss(openedSettings)
                applicationPresentation.dismiss(hostID: presentationHostID)
            }
        case .update(let release):
            UpdatePromptView(checker: applicationPresentation.updateChecker, release: release)
        }
    }

    private func finishApplicationSheetDismissal() {
        guard let id = applicationSheetID,
              let dismissal = applicationPresentation.finishDismissal(
                hostID: presentationHostID, presentationID: id
              ) else { return }
        applicationSheetID = nil
        switch dismissal.presentation.content {
        case .userGuide:
            break
        case .fullDiskAccess:
            break
        case .update(let release):
            // Only acknowledge the revision that actually closed. A newer release may
            // have replaced the visible prompt while its native dismissal was in flight.
            if applicationPresentation.updateChecker.availableUpdate?.tagName == release.tagName {
                applicationPresentation.updateChecker.dismissUntilNextLaunch()
            }
        }
        schedulePendingApplicationPresentationIfPossible()
        schedulePendingSentinelPresentationIfPossible()
    }

    private var activeControlGuideID: UUID? {
        guard let presentation = applicationPresentation.visiblePresentation(for: presentationHostID),
              case .userGuide = presentation.content else { return nil }
        return presentation.id
    }

    private var activeApplicationSheet: MainWindowPresentationCoordinator.Presentation? {
        guard let presentation = applicationPresentation.visiblePresentation(for: presentationHostID) else { return nil }
        if case .userGuide = presentation.content { return nil }
        return presentation
    }

    private func finishControlGuide(_ id: UUID, _ reason: ControlGuideEnd) {
        // The child overlay is already removed. A stale/window-detached callback cannot finish
        // another window's tour, acknowledge onboarding, or change its mode.
        guard activeControlGuideID == id else { return }
        applicationPresentation.dismiss(hostID: presentationHostID)
        guard let dismissal = applicationPresentation.finishDismissal(hostID: presentationHostID, presentationID: id),
              case .userGuide(let presentedMode) = dismissal.presentation.content else { return }
        applicationSheetID = nil
        // v1.6.9: acknowledge the immutable presented mode, even if the window's mode changed.
        if reason.acknowledgesOnboarding { settings.acknowledgeUserGuide(in: presentedMode) }
        if presentedMode != interfaceMode { requestFirstVisitUserGuideIfNeeded() }
        schedulePendingApplicationPresentationIfPossible()
        schedulePendingSentinelPresentationIfPossible()
    }

    private func schedulePendingApplicationPresentationIfPossible() {
        guard isPresentationHostMounted, applicationPresentation.attachHost(presentationHostID),
              applicationPresentation.requestDrainIfPossible(
                hostID: presentationHostID, isBusinessModalBusy: hasBusinessMainModalPresentation
              ) else { return }
        Task { @MainActor in
            await Task.yield()
            guard let presentation = applicationPresentation.takeScheduledIfPossible(
                hostID: presentationHostID,
                isBusinessModalBusy: hasBusinessMainModalPresentation,
                interfaceMode: interfaceMode
            ) else { return }
            applicationSheetID = presentation.id
        }
    }

    /// Sentinel 事件只入队，并在窗口真正空闲后的下一次 MainActor 调度机会消费。这样既不会在
    /// SwiftUI presentation dismiss 动画尚未结束时抢占同一个 slot，也不会丢掉事件。
    private func enqueueSentinelPresentation(_ intent: SentinelPresentationIntent) {
        sentinelPresentationQueue.enqueue(intent)
        schedulePendingSentinelPresentationIfPossible()
    }

    private func schedulePendingSentinelPresentationIfPossible() {
        guard sentinelPresentationQueue.requestDrainIfPossible(
            isModalBusy: hasConflictingMainModalPresentation
        ) else { return }

        Task { @MainActor in
            // 即使 occupancy 已经变成 false，AppKit 的 sheet dismiss 动画也可能尚未
            // 释放 presentation slot；至少跨过当前 SwiftUI update transaction。
            await Task.yield()
            guard let intent = sentinelPresentationQueue.takeScheduledIfPossible(
                isModalBusy: hasConflictingMainModalPresentation
            ) else { return }

            switch intent {
            case .inviteFullScan:
                ensureMainWindowFocused()
                sentinelScanInvitationVisible = true

            case .openUninstall(let path):
                ensureMainWindowFocused()
                transitionInterfaceMode(to: .professional)
                requestCategorySwitch(to: MainView.uninstallSentinelID)
                // 当前 UninstallScreen 还没有按路径高亮的输入口；路径仍被完整排队，
                // 后续接通高亮时无需改变 Sentinel 的可靠投递契约。
                _ = path
            }

            // openUninstall 在无需切换确认时不占 modal；继续按一事件/一次调度排空。
            schedulePendingSentinelPresentationIfPossible()
        }
    }

    private func ensureMainWindowFocused() {
        let windows = NSApp.windows
        let decision = MainWindowRoutingPolicy.decision(
            windows: MainWindowRoutingPolicy.descriptors(for: windows),
            canRequestMainScene: true
        )
        switch decision {
        case .focusExisting(let index) where windows.indices.contains(index):
            let window = windows[index]
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        case .focusExisting, .requestMainScene, .reopenApplication:
            openWindow(id: "main")
        }
    }

    private var canPresentPendingSmartCareAIReport: Bool {
        guard pendingSmartCareAIReport != nil,
              isSmartCareVisible,
              !hasConflictingMainModalPresentation else {
            return false
        }
        if case nil = smartCareSheetRoute { return true }
        return false
    }

    private func handleSmartCareAIReportChange(_ report: SmartCareAIReviewReport?) {
        let isAIReportVisible: Bool
        let isCleanupVisible: Bool
        switch smartCareSheetRoute {
        case .aiReview:
            isAIReportVisible = true
            isCleanupVisible = false
        case .cleanup:
            isAIReportVisible = false
            isCleanupVisible = true
        case nil:
            isAIReportVisible = false
            isCleanupVisible = false
        }
        let action = SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: report?.status,
            isNormalInterface: isSmartCareVisible,
            isAIReportVisible: isAIReportVisible,
            isCleanupVisible: isCleanupVisible,
            hasOtherModalPresentation: hasConflictingMainModalPresentation
        )
        switch action {
        case .present:
            guard let report else { return }
            pendingSmartCareAIReport = nil
            smartCareSheetRoute = .aiReview(report)
        case .queue:
            pendingSmartCareAIReport = report
        case .dismiss:
            pendingSmartCareAIReport = nil
            smartCareSheetRoute = nil
        case .ignore:
            if report == nil || report?.status == .stale {
                pendingSmartCareAIReport = nil
            }
        }
    }

    private func presentPendingSmartCareAIReportIfPossible(canPresent: Bool) {
        guard canPresent, let pendingSmartCareAIReport else { return }
        guard let latestReport = smartCareAIReviewSession.latestReport,
              latestReport.runID == pendingSmartCareAIReport.runID,
              latestReport.status != .stale else {
            self.pendingSmartCareAIReport = nil
            return
        }
        self.pendingSmartCareAIReport = nil
        smartCareSheetRoute = .aiReview(latestReport)
    }

    private func dismissSmartCareSheet() {
        smartCareSheetRoute = nil
    }

    private func retryFailedSmartCareAIReview() {
        startSmartCareAIContinuation(.retryFailed)
    }

    private func continueSmartCareAIReview() {
        startSmartCareAIContinuation(.continueUnreviewed)
    }

    private func rerunSmartCareAIReview() {
        guard case .aiReview(let report) = smartCareSheetRoute,
              smartCareAIReviewSession.latestReport?.runID == report.runID else {
            return
        }
        let expectedRunID = report.runID
        // stale 报告的 source revision 本来就旧；“重新复核当前结果”应锁定点击
        // 瞬间的当前 revision，防止 yield 后跨到 HUD/托盘刚启动的新扫描。
        let expectedSummaryRevision = smartCareSession.care.summaryRevision
        smartCareSheetRoute = nil
        Task { @MainActor in
            await Task.yield()
            guard SmartCareAIReviewDeferredActionPolicy.allows(
                expectedRunID: expectedRunID,
                expectedSummaryRevision: expectedSummaryRevision,
                latestReport: smartCareAIReviewSession.latestReport,
                currentSummaryRevision: smartCareSession.care.summaryRevision,
                aiIsRunning: smartCareAIReviewSession.phase.isRunning
            ) else { return }
            runSmartCareAIReview()
        }
    }

    private enum SmartCareAIContinuationKind: Sendable {
        case retryFailed
        case continueUnreviewed
    }

    private func startSmartCareAIContinuation(_ kind: SmartCareAIContinuationKind) {
        guard case .aiReview(let report) = smartCareSheetRoute,
              report.isCurrent,
              report.sourceSummaryRevision == smartCareSession.care.summaryRevision,
              smartCareAIReviewSession.latestReport?.runID == report.runID,
              !smartCareAIIsRunning else {
            return
        }
        let expectedRunID = report.runID
        let expectedSummaryRevision = report.sourceSummaryRevision
        let didStart = smartCareAIPreparationGate.start { @MainActor in
            do {
                let worker = try await SmartCareAIReviewWorker.makeOpenAI(
                    settings: aiSettings,
                    locale: locale
                )
                try Task.checkCancellation()
                guard SmartCareAIReviewDeferredActionPolicy.allows(
                    expectedRunID: expectedRunID,
                    expectedSummaryRevision: expectedSummaryRevision,
                    latestReport: smartCareAIReviewSession.latestReport,
                    currentSummaryRevision: smartCareSession.care.summaryRevision,
                    aiIsRunning: smartCareAIReviewSession.phase.isRunning
                ) else { return }
                switch kind {
                case .retryFailed:
                    _ = smartCareAIReviewSession.retryFailed(using: worker)
                case .continueUnreviewed:
                    _ = smartCareAIReviewSession.continueUnreviewed(using: worker)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = SmartCareAIReviewFailure(error: error)
                guard SmartCareAIReviewDeferredActionPolicy.allows(
                    expectedRunID: expectedRunID,
                    expectedSummaryRevision: expectedSummaryRevision,
                    latestReport: smartCareAIReviewSession.latestReport,
                    currentSummaryRevision: smartCareSession.care.summaryRevision,
                    aiIsRunning: smartCareAIReviewSession.phase.isRunning
                ) else { return }
                _ = smartCareAIReviewSession.failContinuationPreflight(failure: failure)
            }
        }
        if didStart {
            smartCareSheetRoute = nil
        }
    }

    private func applySmartCareAISelectionChanges(_ changesByPath: [String: Bool]) {
        guard case .aiReview(let report) = smartCareSheetRoute,
              report.isCurrent,
              report.sourceSummaryRevision == smartCareSession.care.summaryRevision else {
            return
        }

        let changes = SmartCareAIReviewSelectionPolicy.validatedChanges(
            report: report,
            currentSummaryRevision: smartCareSession.care.summaryRevision,
            currentItemIDs: smartCareSession.care.summary.itemIDs,
            proposedByPath: changesByPath
        )
        for change in changes {
            _ = smartCareSession.care.setSelected(change.selected, item: change.item)
        }
    }

    private func transitionFromAIReportToCleanupPreview() {
        guard case .aiReview(let report) = smartCareSheetRoute,
              report.isCurrent,
              report.sourceSummaryRevision == smartCareSession.care.summaryRevision else {
            return
        }
        guard smartCareCleanupHandoff.schedule(report.sourceSummaryRevision) else { return }
        smartCareSheetRoute = nil
    }

    private func finishSmartCareSheetDismissal() {
        // Keep the handoff pending until its task starts, so queued application sheets cannot
        // reserve the window between native dismissal and Smart Care's preflight gate acquisition.
        if smartCareCleanupHandoff.hasPending {
            Task { @MainActor in
                guard let revision = smartCareCleanupHandoff.takeAfterSheetDismissal() else { return }
                await presentSmartCareDeleteRequest(expectedSummaryRevision: revision)
            }
        }
        runPendingDeleteSubmissionAfterSheetDismissal()
    }

    private func openSmartCareAISettings() {
        smartCareSheetRoute = nil
        settingsNavigation.select(.ai)
        openSettingsWindow()
    }

    /// v2026.07.16：`EnvironmentValues.openSettings` 仅支持 macOS 14+。
    /// Ventura 通过 SwiftUI Settings scene 已安装的标准 Command-, 菜单项路由，既不依赖
    /// 本地化标题，也不调用私有 selector；失败时保留结构化证据并给出系统提示音。
    private func openSettingsWindow() {
        guard SettingsWindowCompatibility.open() else {
            AmuxLog.error(.settings, "Unable to route the standard Settings menu item")
            NSSound.beep()
            return
        }
    }

    private func handleSmartCarePrimaryAction(_ action: SmartCarePrimaryAction) {
        switch SmartCarePrimaryActionDispatch.resolve(action) {
        case .startScan:
            startSmartCareScan()
        case .returnToSetup:
            smartCareSession.prepareForRescan()
        case .retry:
            retrySmartCareFailure()
        case .continueScan:
            prepareSmartCareScannerConfiguration()
            smartCareSession.continueScan(
                includeHidden: settings.showHidden,
                enabledDeveloperRuleIDs: settings.enabledDevArtifactRuleIDs
            )
        case .stopScan:
            smartCareSession.cancelScan()
        case .presentCleanup:
            Task { @MainActor in
                await presentSmartCareDeleteRequest()
            }
        case .none:
            break
        }
    }

    private func handleSmartCareStageSelectionChange(
        _ stage: SmartCareScanStage,
        selected: Bool
    ) {
        switch SmartCareStageSelectionPolicy.decision(
            stage: stage,
            selected: selected,
            developerWarningAcknowledged:
                settings.smartCareDeveloperCacheWarningAcknowledged
        ) {
        case .apply:
            smartCareSession.setStage(stage, selected: selected)
        case .confirmDeveloperCacheDuration:
            showSmartCareDeveloperCacheWarning = true
        }
    }

    private func retrySmartCareFailure() {
        guard case .failed(let failure) = smartCareSession.care.phase else { return }
        switch failure.recovery {
        case .retryScan:
            smartCareAIReviewSession.reset()
            pendingSmartCareAIReport = nil
            smartCareSheetRoute = nil
            prepareSmartCareScannerConfiguration()
            smartCareSession.retryFailedScan(
                includeHidden: settings.showHidden,
                enabledDeveloperRuleIDs: settings.enabledDevArtifactRuleIDs
            )
        case .reviewCleanup:
            Task { @MainActor in
                await presentSmartCareDeleteRequest()
            }
        }
    }

    @MainActor
    private func presentSmartCareDeleteRequest(expectedSummaryRevision: UInt64? = nil) async {
        guard isSmartCareVisible,
              smartCareSession.canUseCurrentScanResultsForActions,
              !hasConflictingMainModalPresentation else { return }

        let frozenSummaryRevision = smartCareSession.care.summaryRevision
        let frozenSelectionRevision = smartCareSession.care.selectionRevision
        let frozenScanSessionID = smartCareSession.currentScanSessionID
        if let expectedSummaryRevision,
           expectedSummaryRevision != frozenSummaryRevision {
            return
        }
        guard let token = smartCareDeletePreviewGate.begin(
            summaryRevision: frozenSummaryRevision,
            selectionRevision: frozenSelectionRevision
        ) else { return }
        defer {
            if smartCareDeletePreviewGate.finish(token) {
                schedulePendingSentinelPresentationIfPossible()
            }
        }

        do {
            let projectedRequest = try await smartCareSession.care.makeCleanRequest()
            let snapshotRequest = projectedRequest.bindingDeletionSnapshot(
                DeletionSnapshotIdentity(
                    sessionID: frozenScanSessionID,
                    revision: frozenSummaryRevision,
                    categoryID: "smart-care"
                )
            )
            guard !snapshotRequest.items.isEmpty,
                  smartCareSession.canUseCurrentScanResultsForActions,
                  smartCareSession.currentScanSessionID == frozenScanSessionID else {
                return
            }
            let objectPreparation = await pipeline.prepareReviewedObjects(
                paths: snapshotRequest.paths, expectedIdentities: [:]
            )
            guard !Task.isCancelled,
                  smartCareSession.currentScanSessionID == frozenScanSessionID else { return }
            let modalAvailable = isSmartCareVisible
                && !hasOtherMainModalPresentation
                && deleteSheetRequest == nil
                && !deleteSubmissionHandoff.blocksNewSubmission
                && !isPreparingDeletion
                && !isDeleting
                && !stashSheetHandoff.hasPending
            guard smartCareDeletePreviewGate.allowsCompletion(
                token: token,
                currentSummaryRevision: smartCareSession.care.summaryRevision,
                currentSelectionRevision: smartCareSession.care.selectionRevision,
                requestSummaryRevision: snapshotRequest.sourceSummaryRevision,
                requestSelectionRevision: snapshotRequest.sourceSelectionRevision,
                modalAvailable: modalAvailable
            ) else { return }
            switch objectPreparation {
            case .blocked(let rejections):
                deletePreflightNotice = DeletionPreflightNotice(rejections: rejections)
            case .ready(let objects):
                guard let request = snapshotRequest.bindingReviewedObjects(objects) else {
                    deletePreflightNotice = DeletionPreflightNotice(rejections: snapshotRequest.paths.map {
                        .init(path: $0, reason: TrashPendingOperationRejection.Reason.freshReviewRequired.rawValue)
                    })
                    return
                }
                smartCareSheetRoute = .cleanup(request)
            }
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected Smart Care request projection error: \(error)")
        }
    }

    private func startSmartCareScan() {
        guard canReplaceScanContext else { return }
        smartCareAIReviewSession.reset()
        pendingSmartCareAIReport = nil
        smartCareSheetRoute = nil
        prepareSmartCareScannerConfiguration()
        smartCareSession.startScan(
            includeHidden: settings.showHidden,
            enabledDeveloperRuleIDs: settings.enabledDevArtifactRuleIDs
        )
    }

    private func prepareSmartCareScannerConfiguration() {
        smartCareSession.scanCoordinator.refreshFDAStatus()
    }

    private func performSmartCareDelete(request: SmartCareCleanRequest,
                                        action: DeleteSheetAction,
                                        accessDeniedPaths: Set<String>) async {
        // 从提交开始而不是从真正 recycle 才加锁：后台投影也是同一删除事务的一部分，
        // 快速重复确认不能让两份相同 frozen request 同时越过第一个 await。
        guard !isDeleting,
              smartCareSession.canUseCurrentScanResultsForActions else { return }
        isDeleting = true
        defer { isDeleting = false }

        let projection: DeleteExecutionPlanner.SmartCarePlan
        do {
            projection = try await DeleteExecutionPlanner.makeSmartCarePlanAsync(
                request: request,
                action: action
            )
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected Smart Care deletion projection error: \(error)")
            return
        }
        guard smartCareSession.canUseCurrentScanResultsForActions else { return }
        let execution = projection.execution
        let finalDeniedPaths = DeletionDeniedPathPolicy.final(
            frozen: accessDeniedPaths,
            current: smartCareSession.deletionDeniedPaths
        )

        if execution.dryRun {
#if DEBUG
            let result = await runTrashPreview(
                paths: request.paths,
                source: "smart-care",
                accessDeniedPaths: finalDeniedPaths
            )
            presentTrashPreviewOutcome(
                moved: result.moved,
                skipped: result.skipped,
                failureSummary: result.outcome?.failureSummary,
                legacyError: result.err
            )
#else
            assertionFailure("Release Smart Care cannot submit a preview action")
#endif
            return
        }

        guard let reviewIdentity = request.sourceDeletionSnapshotIdentity,
              smartCareSession.canUseCurrentScanResultsForActions,
              reviewIdentity.sessionID == smartCareSession.currentScanSessionID,
              reviewIdentity.revision == request.sourceSummaryRevision,
              reviewIdentity.categoryID == "smart-care",
              smartCareSession.care.confirmClean(request) else {
            // sheet 展示期间选择发生变化：旧请求不能静默扩张为最新选择。
            // 先让上一张 item sheet 完成 dismiss，再用最新 revision 重建预览。
            await Task.yield()
            await presentSmartCareDeleteRequest()
            return
        }

        let runningAppSkippedCount = execution.runningAppSkippedResultItems.count
        smartCareSession.care.updateCleaningProgress(SmartCareCleanProgress(
            completedCount: 0,
            totalCount: execution.rows.count
        ))
        guard !execution.rows.isEmpty else {
            smartCareSession.care.completeCleaning(SmartCareResult(
                movedCount: 0,
                skippedCount: runningAppSkippedCount,
                releasedBytes: 0
            ))
            // 用户选择跳过全部运行中项目时没有提交文件系统操作；确认流程已经
            // 给出反馈，这里不能再伪造一张 OperationResultSheet。
            return
        }

        guard let reviewedObjects = request.reviewedObjects?.restricting(to: execution.paths) else {
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            deletePreflightNotice = DeletionPreflightNotice(rejections: execution.paths.map {
                .init(path: $0, reason: TrashPendingOperationRejection.Reason.freshReviewRequired.rawValue)
            })
            return
        }

        let submission = await TrashActionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: undoHistoryStore
        ).submitConfirmed(
            paths: execution.paths,
            source: "smart-care",
            accessDeniedPaths: finalDeniedPaths,
            // v2026.07.16: this is the identity frozen before the preview sheet appeared, not a
            // new token minted by the confirmation click.
            reviewIdentity: reviewIdentity,
            executionVerification: .reviewedObjects(reviewedObjects)
        )
        let result: TrashRunResult
        let completedSubmission: TrashActionCoordinator.CompletedSubmission
        switch submission {
        case .recycleCompleted(let submitted):
            completedSubmission = submitted
            result = TrashRunResult(
                moved: submitted.moved,
                skipped: submitted.skipped,
                err: submitted.err,
                pairs: submitted.pairs,
                outcome: submitted.outcome,
                succeededPaths: submitted.succeededPaths
            )

        case .preSubmitRejected(.emptyRequest):
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            // v2026.07.20: even an empty typed submission is a pre-submit terminal. Keep Smart
            // Care usable, but do not silently swallow the reason or manufacture a result sheet.
            deletePreflightNotice = DeletionPreflightNotice(rejections: [])
            return

        case .preSubmitRejected(.safety(let preflight)),
             .preSubmitRejected(.invalidVendorOverride(let preflight)):
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            deletePreflightNotice = DeletionPreflightNotice(rejections: preflight.rejections)
            return

        case .preSubmitRejected(.invalidScanIncompleteOverride(let rejections)),
             .preSubmitRejected(.invalidDuplicateVerification(let rejections)):
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            deletePreflightNotice = DeletionPreflightNotice(rejections: rejections)
            return

        case .preSubmitRejected(.pendingOperation(let rejection)):
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            deletePreflightNotice = DeletionPreflightNotice(
                rejections: rejection.preflightRejections
            )
            return

        case .preSubmitRejected(.unsupportedPipeline):
            assertionFailure("Smart Care deletion requires the typed recycle boundary")
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            deletePreflightNotice = DeletionPreflightNotice(
                rejections: execution.paths.map {
                    .init(path: $0, reason: "unsupportedPipeline")
                }
            )
            return
        }
        let succeededPaths = result.succeededPaths
        let accounting = await SmartCareDeletionAccountingExecutor.run(
            items: projection.submittedItems,
            succeededPaths: succeededPaths,
            professionalSelection: selection
        )

        if !succeededPaths.isEmpty {
            await recorder.recordTrashed(paths: succeededPaths)
            // Set 差集已在 accounting worker 完成；MainActor 只替换 storage。
            selection = accounting.remainingProfessionalSelection
            await synchronizeSuccessfulDeletion(
                paths: succeededPaths,
                authoritativeSurface: .smartCare
            )
        }

        let movedBytes = accounting.movedBytes
        let releasedBytes = accounting.releasedBytes
        if movedBytes > 0 || releasedBytes > 0 {
            Task.detached { [movedBytes, releasedBytes] in
                await CleanStatsStore.shared.recordTrashed(
                    bytesTrashed: movedBytes,
                    bytesReclaimed: releasedBytes,
                    category: "smart-care"
                )
            }
        }

        if let outcome = result.outcome,
           (!outcome.pendingPaths.isEmpty
            || !outcome.submissionUnknownPaths.isEmpty
            || !outcome.notSubmittedPaths.isEmpty) {
            // v2026.07.16：系统终态未知时既不是 cleanup failed，也不是 completed。
            // 已确认 moved 的项目已在上方同步，其余选择保持不变并回到 review，等待用户
            // 查看结果页后重新扫描对账；禁止用失败按钮诱导立即重复提交。
            smartCareSession.care.resumeReviewAfterUnsubmittedClean()
            presentDeletionCompletion(.trash(
                completedSubmission,
                runningAppSkipped: execution.runningAppSkippedResultItems
            ))
            return
        }

        let cleanFailureDetail = result.outcome?.failureSummary.map(SmartCareFailureDetail.trash)
            ?? result.err.map { _ in SmartCareFailureDetail.unexpectedFailure }
        if succeededPaths.isEmpty, let cleanFailureDetail {
            smartCareSession.care.fail(.cleanFailed(cleanFailureDetail))
            presentDeletionCompletion(.trash(
                completedSubmission,
                runningAppSkipped: execution.runningAppSkippedResultItems
            ))
            return
        }

        // synchronizeSuccessfulDeletion 已在 SmartCareSession 的后台事务中完成
        // summary 移除 + selection reconcile + metrics；这里只做 O(1) 相位提交，
        // 避免在 MainActor 对同一份 20k+ 结果再构建一遍。
        smartCareSession.care.completeCleaning(
            SmartCareResult(
                movedCount: result.moved,
                skippedCount: result.skipped + runningAppSkippedCount,
                movedBytes: movedBytes,
                releasedBytes: releasedBytes
            )
        )
        presentDeletionCompletion(.trash(
            completedSubmission,
            runningAppSkipped: execution.runningAppSkippedResultItems
        ))
    }

    /// v2026.07.19: accept and enqueue Professional deletion before changing sheet state. The
    /// one-shot handoff remains active until the async transaction ends, closing the synchronous
    /// double-confirm window before `isDeleting` can be set by the new task.
    private func startProfessionalDeleteSubmission(
        _ submission: ProfessionalDeleteSubmission,
        timing: ProfessionalDeleteTiming
    ) {
        AmuxLog.info(
            .trash,
            "professional_delete stage=confirmation_accepted trace_id=\(timing.traceID.uuidString) item_count=\(timing.itemCount)"
        )
        Task { [submission, timing] in
            defer {
                if !deleteSubmissionHandoff.finishProfessionalSubmission() {
                    AmuxLog.error(
                        .trash,
                        "professional_delete stage=handoff_finish_failed trace_id=\(timing.traceID.uuidString)"
                    )
                }
            }
            await performProfessionalDelete(
                request: submission.request,
                executionPlan: submission.executionPlan,
                timing: timing
            )
        }
    }

    /// Only follow-up UI waits for `onDismiss`; filesystem execution never does. This preserves
    /// reliable result-sheet presentation without making Tree/layout work a deletion dependency.
    private func finishProfessionalDeleteSheetDismissal() {
        guard let presentation = professionalDeletePresentationHandoff.finishSheetDismissal() else {
            return
        }
        applyProfessionalDeletePresentation(presentation)
    }

    /// Returns true when the payload is retained until the confirmation sheet finishes dismissing.
    @discardableResult
    private func routeProfessionalDeletePresentation(
        _ presentation: ProfessionalDeleteDeferredPresentation
    ) -> Bool {
        switch professionalDeletePresentationHandoff.routeNextPresentation(presentation) {
        case .presentNow:
            applyProfessionalDeletePresentation(presentation)
            return false
        case .deferUntilSheetDismissal:
            return true
        case .rejectDuplicate:
            AmuxLog.error(.trash, "professional_delete stage=duplicate_terminal_presentation_rejected")
            return true
        }
    }

    private func applyProfessionalDeletePresentation(
        _ presentation: ProfessionalDeleteDeferredPresentation
    ) {
        switch presentation {
        case .confirmation(let request):
            deleteSheetRequest = request
        case .preflightNotice(let notice):
            deletePreflightNotice = notice
        case .result(let completion):
            presentDeletionCompletion(completion)
        }
    }

    private func presentDeletionCompletion(_ completion: OperationResultCompletion) {
        let presentation = OperationCompletionPresentation(completion)
        deleteSuccessFeedback = presentation.successFeedback.map(MainDeletionSuccessFeedback.deletion)
        deleteResultCompletion = presentation.details
    }

    /// Smart Care keeps its existing sheet-to-execution handoff. Professional submissions are
    /// intentionally absent from `DeleteSubmission`, so they cannot regress back to this callback.
    private func runPendingDeleteSubmissionAfterSheetDismissal() {
        guard deleteSubmissionHandoff.hasPending else { return }
        // v2026.10.10: just like Workflow, retain pending ownership until the Task enters
        // execution. The native callback must never expose an idle window before isDeleting.
        Task { @MainActor in
            guard let submission = deleteSubmissionHandoff.takeAfterSheetDismissal() else { return }
            switch submission {
            case .smartCare(let request, let action, let accessDeniedPaths):
                await performSmartCareDelete(
                    request: request,
                    action: action,
                    accessDeniedPaths: accessDeniedPaths
                )
            }
        }
    }

    /// v1.6.9: first-visit teaching cannot depend on a scan producing a row. This labelled
    /// example uses the actual native row action renderer, without a file identity or callbacks.
    private var professionalRowActionsGuide: some View {
        HStack(spacing: 12) {
            Text("user_guide.control.row_actions.example", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
            TreeRowActionsGuideSample()
                .controlGuideTarget(.rowActions)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("user_guide.row_actions.example")
    }

    // MARK: - Sidebar

    /// v1.3.zz UI 修复：原本结构是 `List { ... }.safeAreaInset(.bottom) { VolumeCapacityCard }`，
    /// 但扫描期间 [coordinator.snapshot.totalBytes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 高频变化会让 capacity card 反复重渲染，进而扰动 List 的 safeAreaInset 计算与滚动位置——
    /// 表现就是"点了用户缓存 → sidebar 整段莫名滚到中间，底部容量条仿佛消失"。
    /// 改成显式 VStack（List + 固定底部 capacity card）后，两者是兄弟视图，
    /// card 高度变化不会再传染到 List 的滚动位置。
    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarList
            Divider()
            LiveVolumeCapacityCard(
                systemProbe: coordinator.systemProbe,
                // v1.6 / 2026-06：**口径修复**——以前这里灌的是 `coordinator.snapshot.totalBytes`，
                // 即"已扫到的全部字节"，导致 sidebar 出现"扫多少就 Cleanable 多少"的离谱口径（
                // 用户截图: Scanning 133.49 GB ↔ Cleanable 133.49 GB）。
                // 现在统一走 [ScanSnapshot.safeBytes / .confirmBytes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L375-L387)
                // ——仅 `SafetyVerdict.safe` 行求和算入"可清"段、`SafetyVerdict.confirm`
                // 行单独成"需要确认"段，与业界（CleanMyMac / DaisyDisk）四段分层对齐。
                safeBytes: coordinator.snapshot.safeBytes,
                confirmBytes: coordinator.snapshot.confirmBytes,
                // v1.3 review-fix Must1：snapshot 探测失败时让卡片提供"重试"按钮，回调到 coordinator.refreshVolumeCapacity()。
                onRetry: { coordinator.refreshVolumeCapacity() }
            )
            .controlGuideTarget(.diskCapacity)
        }
        .navigationSplitViewColumnWidth(
            min: SidebarMetrics.minWidth,
            ideal: SidebarMetrics.idealWidth,
            max: SidebarMetrics.maxWidth
        )
        // 侧栏本身就是 NavigationSplitView 的列根，不能再用 GeometryReader 沙箱包裹。
        // 否则列宽 preference 会藏在 flexible child 内，首次切到 Professional 时
        // 分栏无法稳定拿到明确宽度。长标题由 SidebarTitleStyle 自己截断。
    }

    private var sidebarList: some View {
        ScrollViewReader { proxy in
            List(selection: sidebarSelectionBinding) {
                // v1.5: Batch Scans —— sidebar 与 toolbar 三大扫描入口的镜像。
                // 解决用户截图反馈：点 toolbar 锤子 / 推荐 / 全盘后，左侧 sidebar
                // 没有任何选中态，感知不到"我现在在跑哪条"。
                // 这里的 .tag 用 ScanCategory.batchXxxID sentinel；
                // onChange(selectedCategory) 看见这三 id 时不走 startScan(category:)
                // 而是分发到对应 trigger* helper（toolbar 同款）。
                Section {
                    batchScanRow(icon: "rectangle.3.group",
                                 titleKey: "batch.recommended.title")
                        .tag(ScanCategory.batchRecommendedID)
                        .controlGuideGroupPart(.scanCategory)
                        .accessibilityIdentifier("sidebar.batch.recommended")

                    batchScanRow(icon: "hammer",
                                 titleKey: "batch.developer.title",
                                 helpKey: "batch.developer.help")
                        .tag(ScanCategory.batchDeveloperID)
                        .controlGuideGroupPart(.scanCategory)

                    batchScanRow(icon: "internaldrive",
                                 titleKey: "batch.fulldisk.title")
                        .tag(ScanCategory.batchFullDiskID)
                        .controlGuideGroupPart(.scanCategory)

                    batchScanRow(icon: "sparkles",
                                 titleKey: "batch.common_app_cache.title")
                        .tag(ScanCategory.batchCommonAppCacheID)
                        .controlGuideGroupPart(.scanCategory)
                } header: {
                    Text("sidebar.section.batch", bundle: .module)
                    .controlGuideGroupPart(.scanCategory)
                }
                .id(ControlGuideTarget.scanCategory)

                Section {
                    sidebarRow(largeFilesCategory)
                        .tag(largeFilesCategory.id)
                        .controlGuideGroupPart(.scanCategory)
                        .accessibilityIdentifier("sidebar.large_files")
                } header: {
                    Text("sidebar.section.large_files", bundle: .module)
                        .controlGuideGroupPart(.scanCategory)
                }

                Section {
                    ForEach(presetCategories) { cat in
                        sidebarRow(cat)
                            .tag(cat.id)
                            .controlGuideGroupPart(.scanCategory)
                    }
                } header: {
                    Text("sidebar.section.recommended", bundle: .module)
                    .controlGuideGroupPart(.scanCategory)
                }

                Section {
                    ForEach(customCategories) { cat in
                        sidebarRow(cat)
                            .tag(cat.id)
                            .controlGuideGroupPart(.customPaths)
                            .contextMenu {
                                Button {
                                    Task { await removeCustomPath(cat) }
                                } label: {
                                    Label {
                                        Text("menu.path.remove", bundle: .module)
                                    } icon: {
                                        Image(systemName: "minus.circle")
                                    }
                                }
                            }
                    }
                    Button {
                        guard !hasConflictingMainModalPresentation else { return }
                        isCustomPathImporterPresented = true
                    } label: {
                        Label {
                            localizedSidebarTitle("menu.path.add")
                        } icon: {
                            Image(systemName: "plus")
                        }
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .disabled(hasConflictingMainModalPresentation)
                    .controlGuideGroupPart(.customPaths)
                } header: {
                    HStack {
                        Text("sidebar.section.custom", bundle: .module)
                        if !customCategories.isEmpty {
                            Text("· \(customCategories.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .controlGuideGroupPart(.customPaths)
                }
                .id(ControlGuideTarget.customPaths)

                Section {
                    ForEach(libraryBrowseCategories) { cat in
                        sidebarRow(cat, iconOverride: "folder.badge.gearshape")
                            .tag(cat.id)
                            .controlGuideGroupPart(.customPaths)
                    }
                } header: {
                    Text("sidebar.section.library", bundle: .module)
                    .controlGuideGroupPart(.customPaths)
                }

                Section {
                    sidebarRow(ScanCategory.fullDisk)
                        .tag(ScanCategory.fullDisk.id)
                        .controlGuideGroupPart(.customPaths)
                } header: {
                    Text("sidebar.section.full_disk", bundle: .module)
                        .controlGuideGroupPart(.customPaths)
                }

                Section {
                    appFootprintSidebarRow
                        .tag(MainView.appFootprintSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                        .accessibilityIdentifier("sidebar.app_footprint")
                    launchAgentSidebarRow
                        .tag(MainView.launchAgentSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                    portCleanerSidebarRow
                        .tag(MainView.portCleanerSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                    dartRadarSidebarRow
                        .tag(MainView.dartRadarSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                    uninstallSidebarRow
                        .tag(MainView.uninstallSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                        .accessibilityIdentifier("sidebar.uninstaller")
                    devVersionedSidebarRow
                        .tag(MainView.devVersionedSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                } header: {
                    Text("sidebar.section.apps", bundle: .module)
                    .controlGuideGroupPart(.professionalTools)
                }
                .id(ControlGuideTarget.professionalTools)

                Section {
                    duplicateSidebarRow
                        .tag(MainView.duplicateSentinelID)
                        .controlGuideGroupPart(.professionalTools)
                        .accessibilityIdentifier("sidebar.duplicates")
                } header: {
                    Text("sidebar.section.duplicates", bundle: .module)
                        .controlGuideGroupPart(.professionalTools)
                }

                // Step 7：UndoHistory section —— 给"最近清理 / 恢复"一个独立入口。
                // 单 row 设计避免污染 ScanCategory 体系（与 uninstall / duplicate 同款 sentinel ID 模式）。
                Section {
                    undoHistorySidebarRow
                        .tag(MainView.undoHistorySentinelID)
                        .controlGuideGroupPart(.workflows)
                } header: {
                    Text("sidebar.section.undo_history", bundle: .module)
                        .controlGuideGroupPart(.workflows)
                }

                .id(ControlGuideTarget.workflows)

                // M4-T4 / 2026-06：系统维护 section —— flushQuickLookCache /
                // flushDNSCache 两个 user-space 任务，
                // 走 [MaintenanceScreen](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MaintenanceScreen.swift)
                // 自包含 UI，不复用扫描状态栏。
                Section {
                    maintenanceSidebarRow
                        .tag(MainView.maintenanceSentinelID)
                        .controlGuideGroupPart(.workflows)
                } header: {
                    Text("sidebar.section.maintenance", bundle: .module)
                        .controlGuideGroupPart(.workflows)
                }

                // F-2-4 / 2026-06：dev 工具集 section —— Homebrew 包管理。
                // 走 sentinel 旁路 + 独立 Screen，与 maintenance 同款不复用扫描状态栏。
                // 字面量直接英文不进 xcstrings（dev 工具，不强求 i18n）。
                Section {
                    brewSidebarRow
                        .tag(MainView.brewSentinelID)
                        .controlGuideGroupPart(.workflows)
                } header: {
                    Text("main.section.dev_tools", bundle: .module)
                        .controlGuideGroupPart(.workflows)
                }

                // v1.7 M1 PR-5 / 2026-06：Developer Workflows section ——
                // Apple / Android / Web-Node 三大生态按"工作流"分组的一键清理入口。
                // 与 `batch.developer` sentinel（DevArtifactScanner 散点）共存，但
                // 这三行走 [WorkflowDetailView](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)
                // 渲染卡片化 + 可勾选 + 动态扫描 + 回收站删除 全链路。
                // 字面量改走 xcstrings（workflow.sidebar.* 前缀），中英双语。
                Section {
                    workflowAppleSidebarRow
                        .tag(MainView.workflowAppleSentinelID)
                        .controlGuideGroupPart(.workflows)
                        .accessibilityIdentifier("sidebar.workflow.apple")
                    workflowAndroidSidebarRow
                        .tag(MainView.workflowAndroidSentinelID)
                        .controlGuideGroupPart(.workflows)
                    workflowWebNodeSidebarRow
                        .tag(MainView.workflowWebNodeSentinelID)
                        .controlGuideGroupPart(.workflows)
                    workflowBackendSidebarRow
                        .tag(MainView.workflowBackendSentinelID)
                        .controlGuideGroupPart(.workflows)
                } header: {
                    Text("workflow.sidebar.section", bundle: .module)
                    .controlGuideGroupPart(.workflows)
                }
            }
            // bug1：sidebar List 默认会在获得 keyboard focus 时画一圈蓝色焦点环
            // （包住整个 list 容器，看起来像"鼠标进入 sidebar 才出现的蓝框"）。
            // 我们已经有 row selection 的蓝色背景做选中反馈，再叠焦点环纯属冗余且割裂。
            // 关掉容器级焦点环，单行 selection 不受影响。
            .suppressesFocusEffectWhenSupported()
            // v2026.07.17 C4 contract: stable AX identifiers let a single long-running
            // accessibility session select semantic destinations without hard-coded row indexes.
            .accessibilityIdentifier("main.sidebar")
            .controlGuideTarget(.sidebarOperations)
            .onAppear {
                // v1.6.9: aggregate adjacent sections into four useful blocks. Geometry still
                // comes from the real headings/rows, and scrolling never selects or scans.
                guideAnchors.registerReveals([.scanCategory, .customPaths, .professionalTools, .workflows], owner: presentationHostID) { target in
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            .onDisappear { guideAnchors.unregisterReveals(owner: presentationHostID) }
        }
    }

    /// v1.2 P1-6：「应用占用排行榜」侧边项。用 sentinel ID 走旁路，避免污染
    /// ScanCategory（它的语义是"扫描类目 + 默认 verdict"，不适合一个只读视图）。
    static let appFootprintSentinelID: String = "app.footprint"

    /// v1.2 P1-7：「启动项」侧边项。同样走 sentinel ID 旁路 —— 它是只读视图，
    /// 没有勾选/删除动作，不该污染 ScanCategory 体系。
    static let launchAgentSentinelID: String = "launchagent.list"

    /// v1.8：「清理端口」侧边项。端口占用是运行时进程资源，和磁盘扫描模型不同，
    /// 使用独立屏幕 + 后台 lsof scanner，不进入 ScanCategory。
    static let portCleanerSentinelID: String = "port.cleaner"

    /// Dart 雷达：运行时 Dart/Flutter 进程观测工具，与端口清理同属进程类旁路屏幕。
    static let dartRadarSentinelID: String = "dart.radar"

    /// v1.2 P1-8：「卸载残留」侧边项。UninstallScreen 自带 SafetyEngine + dryRun
    /// + 二次确认 sheet，外层 MainView 不应再叠加扫描/删除 UI，故走 sentinel ID 旁路。
    static let uninstallSentinelID: String = "uninstall.screen"

    /// v1.2 P2-1：「重复文件」侧边项。DuplicateScreen 是只读视图（无勾选 / 无删除按钮），
    /// 与 ScanCategory（默认勾选 + verdict）的语义不兼容，走 sentinel ID 旁路。
    static let duplicateSentinelID: String = "duplicate.scan"

    /// Step 7：「最近清理」侧边项。UndoHistoryScreen 渲染最近 N 次 trash 批次 + 恢复按钮，
    /// 完全是一个事后管理面板，与扫描语义无关，故走 sentinel ID 旁路。
    static let undoHistorySentinelID: String = "undo.history"

    /// M4-T4 / 2026-06：「系统维护」侧边项。MaintenanceScreen 是 2 个 user-space 任务
    /// 的执行面板（flushQuickLookCache / flushDNSCache），
    /// 与扫描 / 删除语义无关，沿 uninstall / undoHistory 同款 sentinel 旁路。
    static let maintenanceSentinelID: String = "maintenance.screen"

    /// F-2-4 / 2026-06：「Homebrew」侧边项。BrewScreen 三 tab（installed / outdated /
    /// cleanup）直接读 Cellar / Caskroom + ~/Library/Caches/Homebrew，不执行 brew，
    /// 也不复用扫描状态栏，走 sentinel 旁路。
    static let brewSentinelID: String = "brew.screen"

    /// M4-T2 / 2026-06：「开发者旧版本」侧边项。点击触发
    /// [ScanCoordinator.scanKnownVersionedRoots(home:)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L710)，
    /// 同步派发 Xcode DeviceSupport / JetBrains Toolbox 旧版本命中为 `developer.versioned`
    /// snapshot。沿用主路径的 statusBar / listResults，因此走 onChange 显式 case 而非
    /// "allCategories.first 自然 return"。
    static let devVersionedSentinelID: String = "developer.versioned.scan"

    /// v1.7 M1 PR-5：「Apple 开发者工作流」侧边项。沿用 maintenance / brew 同款 sentinel 旁路，
    /// results 区渲染 [WorkflowDetailView](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/WorkflowDetailView.swift)，
    /// 数据源 [AppleWorkflow](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DeveloperWorkflow.swift)。
    /// 与既有 `batch.developer` sentinel 共存——后者是"按类目散点扫"，本 sentinel 是"按 Apple 工作流分组扫"。
    static let workflowAppleSentinelID: String = "workflow.apple"

    /// v1.7 M1 PR-5：「Android 开发者工作流」侧边项。
    static let workflowAndroidSentinelID: String = "workflow.android"

    /// v1.7 M1 PR-5：「Web / Node 开发者工作流」侧边项。
    static let workflowWebNodeSentinelID: String = "workflow.webnode"

    /// v1.9：「后端开发者工作流」侧边项（JVM / Go / Rust / Zig / Bazel / CMake）。
    static let workflowBackendSentinelID: String = "workflow.backend"

    /// 工作流 sentinel 集合。onChange 命中其一即清空状态，不再走 startScan 路径。
    static let workflowSentinelIDs: Set<String> = [
        workflowAppleSentinelID,
        workflowAndroidSentinelID,
        workflowWebNodeSentinelID,
        workflowBackendSentinelID,
    ]

    /// v1.5：sidebar Batch Scans section 的 row。结构与 sidebarRow / appFootprintSidebarRow
    /// 对齐：图标 + 标题。row 自身不带 tap handler，selection 切换由
    /// onChange(selectedCategory) 统一调度到对应 trigger* helper。
    ///
    /// v2026.07 Q3：**副标题去除**（用户反馈"左侧操作台冗余，只显示栏目标题"）；
    /// 同时把 dead 形参 `subtitleKey` 及配套 xcstrings key 一并清理，避免 i18n orphan。
    /// v1.5 review-fix #13：去掉 dead `id` 参数（外部 .tag(...) 使用，本函数不需要）。
    private func batchScanRow(icon: String,
                              titleKey: String,
                              helpKey: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle(titleKey)
        }
        .padding(.vertical, 2)
        .modifier(OptionalHelpModifier(helpText: helpText(helpKey)))
    }

    private var appFootprintSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.app_footprint")
        }
        .padding(.vertical, 2)
    }

    private var launchAgentSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.square.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.launch_agents")
        }
        .padding(.vertical, 2)
    }

    private var portCleanerSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.port_cleaner")
        }
        .padding(.vertical, 2)
    }

    private var dartRadarSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.dart_radar")
        }
        .padding(.vertical, 2)
    }

    private var uninstallSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.slash")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.uninstall")
        }
        .padding(.vertical, 2)
    }

    private var duplicateSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.duplicate")
        }
        .padding(.vertical, 2)
    }

    /// Step 7：「最近清理」侧边 row —— 与 uninstall / duplicate 同结构，图标用 arrow.uturn.backward。
    private var undoHistorySidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.undo_history")
        }
        .padding(.vertical, 2)
    }

    /// M4-T4 / 2026-06：「系统维护」侧边 row —— 与 undoHistory / uninstall 同结构，
    /// 图标用 wrench.and.screwdriver 表达"工具集合"。
    private var maintenanceSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.maintenance")
        }
        .padding(.vertical, 2)
    }

    /// F-2-4 / 2026-06：「Homebrew」侧边 row —— 图标用 mug 借喻 brew。
    private var brewSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mug")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("main.devtool.brew.title")
        }
        .padding(.vertical, 2)
    }

    /// v1.7 M1 PR-5：「Apple 工作流」侧边 row —— apple.logo 图标。
    private var workflowAppleSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "applelogo")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("workflow.sidebar.apple.title")
        }
        .padding(.vertical, 2)
    }

    /// v1.7 M1 PR-5：「Android 工作流」侧边 row —— cube.box 借喻"包/构建产物"。
    /// （SF Symbol 没有 Android 专属图标，cube.box 与 "AAR / APK / build artifacts" 语义对齐。）
    private var workflowAndroidSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.box")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("workflow.sidebar.android.title")
        }
        .padding(.vertical, 2)
    }

    /// v1.7 M1 PR-5：「Web / Node 工作流」侧边 row —— globe 图标。
    private var workflowWebNodeSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("workflow.sidebar.webnode.title")
        }
        .padding(.vertical, 2)
    }

    /// v1.9：「Backend 工作流」侧边 row —— server.rack 表达后端/服务端工具链。
    private var workflowBackendSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("workflow.sidebar.backend.title")
        }
        .padding(.vertical, 2)
    }

    /// M4-T2 / 2026-06：「开发者旧版本」侧边 row —— 与 uninstall / launchAgent 同结构，
    /// 图标用 hammer 表达"开发工具产物"。点击触发 ScanCoordinator.scanKnownVersionedRoots。
    private var devVersionedSidebarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer")
                .foregroundStyle(.tint)
                .frame(width: 16)
            localizedSidebarTitle("sidebar.row.dev_versioned")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sidebarRow(_ cat: ScanCategory, iconOverride: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconOverride ?? iconName(for: cat.kind))
                .foregroundStyle(.tint)
                .frame(width: 16)
            sidebarTitle(cat.displayTitle(locale: locale))
        }
        .padding(.vertical, 2)
        .modifier(OptionalHelpModifier(helpText: cat.displayHelpIfConfigured(locale: locale)))
    }

    private func localizedSidebarTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key), bundle: .module)
            .modifier(SidebarTitleStyle())
    }

    private func sidebarTitle(_ title: String) -> some View {
        Text(title)
            .modifier(SidebarTitleStyle())
    }

    private func helpText(_ helpKey: String?) -> String? {
        guard let helpKey else { return nil }
        return AppLocalization.string(helpKey, locale: locale)
    }

    private func iconName(for kind: ScanCategory.Kind) -> String {
        switch kind {
        case .preset:     return "sparkles"
        case .custom:     return "folder"
        case .fullDisk:   return "internaldrive"
        case .largeFiles: return "doc.richtext"
        }
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                                    Text("drop.hint.release_to_add", bundle: .module)
                    .font(.title3.bold())
                    .foregroundStyle(.tint)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
    }

    // MARK: - Results

    /// v1.0 T4：当前是否在大文件模式（侧边选了 "🐘 大文件" 类目）。
    private var isLargeFilesMode: Bool {
        selectedCategory == largeFilesCategory.id
    }

    /// v1.2 P1-6：当前是否在应用占用排行榜模式。
    private var isAppFootprintMode: Bool {
        selectedCategory == MainView.appFootprintSentinelID
    }

    /// v1.2 P1-7：当前是否在启动项查看模式。
    private var isLaunchAgentMode: Bool {
        selectedCategory == MainView.launchAgentSentinelID
    }

    /// v1.8：当前是否在「清理端口」模式。
    private var isPortCleanerMode: Bool {
        selectedCategory == MainView.portCleanerSentinelID
    }

    /// 当前是否在「Dart 雷达」模式。
    private var isDartRadarMode: Bool {
        selectedCategory == MainView.dartRadarSentinelID
    }

    /// v1.2 P1-8：当前是否在卸载残留模式。
    private var isUninstallMode: Bool {
        selectedCategory == MainView.uninstallSentinelID
    }

    /// v1.2 P2-1：当前是否在重复文件模式。
    private var isDuplicateMode: Bool {
        selectedCategory == MainView.duplicateSentinelID
    }

    /// Step 7：当前是否在「最近清理」模式。
    private var isUndoHistoryMode: Bool {
        selectedCategory == MainView.undoHistorySentinelID
    }

    /// M4-T4 / 2026-06：当前是否在「系统维护」模式。
    private var isMaintenanceMode: Bool {
        selectedCategory == MainView.maintenanceSentinelID
    }

    /// F-2-4 / 2026-06：当前是否在「Homebrew」模式。
    private var isBrewMode: Bool {
        selectedCategory == MainView.brewSentinelID
    }

    /// v1.7 M1 PR-5：当前是否在「Apple 工作流」模式。
    private var isWorkflowAppleMode: Bool {
        selectedCategory == MainView.workflowAppleSentinelID
    }

    /// v1.7 M1 PR-5：当前是否在「Android 工作流」模式。
    private var isWorkflowAndroidMode: Bool {
        selectedCategory == MainView.workflowAndroidSentinelID
    }

    /// v1.7 M1 PR-5：当前是否在「Web / Node 工作流」模式。
    private var isWorkflowWebNodeMode: Bool {
        selectedCategory == MainView.workflowWebNodeSentinelID
    }

    /// v1.9：当前是否在「Backend 工作流」模式。
    private var isWorkflowBackendMode: Bool {
        selectedCategory == MainView.workflowBackendSentinelID
    }

    private var isStandaloneProfessionalToolMode: Bool {
        isAppFootprintMode
            || isLaunchAgentMode
            || isPortCleanerMode
            || isDartRadarMode
            || isUninstallMode
            || isDuplicateMode
            || isUndoHistoryMode
            || isMaintenanceMode
            || isBrewMode
            || isWorkflowAppleMode
            || isWorkflowAndroidMode
            || isWorkflowWebNodeMode
            || isWorkflowBackendMode
    }

    private var results: some View {
        VStack(spacing: 0) {
            if isAppFootprintMode {
                // 「应用占用排行榜」整段独立：不渲染 statusBar / footerBar 等扫描相关 UI。
                AppFootprintScreen()
            } else if isLaunchAgentMode {
                // 「启动项」同样整段独立 —— 只读视图，无扫描进度 / 勾选 / 删除按钮。
                LaunchAgentScreen()
            } else if isPortCleanerMode {
                // 「清理端口」是运行时进程工具：后台 lsof 扫描，kill 前二次确认，不复用磁盘扫描 UI。
                PortCleanerScreen()
            } else if isDartRadarMode {
                // 「Dart 雷达」整段独立：后台 ps 扫描 Dart/Flutter 进程，冻结身份后二次确认结束。
                DartRadarScreen()
            } else if isUninstallMode {
                // 「卸载残留」整段独立：UninstallScreen 自带 SafetyEngine + dryRun + 二次确认，
                // 外层不能再叠 statusBar / footerBar / 删除按钮，避免重复或绕过安全契约。
                UninstallScreen(
                    pipeline: uninstallPipeline,
                    vendors: vendors,
                    undoHistoryStore: undoHistoryStore
                )
            } else if isDuplicateMode {
                // 「重复文件」整段独立：只读视图，没有勾选 / 删除按钮，
                // 也不复用 statusBar / footerBar（它有自己的 banner + 进度 + footer）。
                DuplicateScreen(
                    pipeline: duplicatePipeline,
                    undoHistoryStore: undoHistoryStore
                )
            } else if isUndoHistoryMode {
                // Step 7：「最近清理」整段独立 —— 只读+恢复按钮，不复用扫描状态栏。
                UndoHistoryScreen(store: undoHistoryStore)
            } else if isMaintenanceMode {
                // M4-T4 / 2026-06：「系统维护」整段独立 —— 三按钮 + outcome list，
                // 自带 detached Task 执行 / 状态指示，不复用扫描进度 / 删除 UI。
                MaintenanceScreen()
            } else if isBrewMode {
                // F-2-4 / 2026-06：Homebrew 包管理 —— 直接读 Cellar / Caskroom，不执行 brew。
                BrewScreen(
                    pipeline: brewPipeline,
                    undoHistoryStore: undoHistoryStore
                )
            } else if isWorkflowAppleMode {
                // v1.7 M1 PR-5：Apple 工作流（Xcode / Simulator / DerivedData per-project / DeviceSupport）
                // 复用 WorkflowDetailView 通用渲染壳，数据源 AppleWorkflow.cards + WorkflowRegistry.resolve。
                // pipeline 透传 MainView 持有的 TrashPipeline 实例，删除走 NSWorkspace.recycle。
                WorkflowDetailView(workflow: AppleWorkflow(),
                                   pipeline: pipeline,
                                   undoHistoryStore: undoHistoryStore)
            } else if isWorkflowAndroidMode {
                // v1.7 M1 PR-5：Android 工作流（gradle / .android / AVD / SDK / Android Studio）。
                WorkflowDetailView(workflow: AndroidWorkflow(),
                                   pipeline: pipeline,
                                   undoHistoryStore: undoHistoryStore)
            } else if isWorkflowWebNodeMode {
                // v1.7 M1 PR-5：Web / Node 工作流（pnpm-store / yarn / npm / electron / node-gyp / scattered node_modules）。
                WorkflowDetailView(workflow: WebNodeWorkflow(),
                                   pipeline: pipeline,
                                   undoHistoryStore: undoHistoryStore)
            } else if isWorkflowBackendMode {
                // v1.9：Backend 工作流（JVM / Go / Rust / Zig / Bazel / CMake）。
                WorkflowDetailView(workflow: BackendWorkflow(),
                                   pipeline: pipeline,
                                   undoHistoryStore: undoHistoryStore)
            } else {
                statusBar
                Divider()
                if isLargeFilesMode {
                    // 大文件视图整段独立：不复用 viewModeBar / listResults / placeholder，
                    // 因为它的列模型、空态文案、选中模型都不一样。
                    LargeFilesView(
                        coordinator: coordinator,
                        settings: settings,
                        selection: $largeFileSelection,
                        batch: largeFilesBatch,
                        onTrash: { items in
                            presentDeleteConfirmation(
                                rows: items.map(makeDeletionRow),
                                origin: .largeFiles
                            )
                        },
                        onVisibleItemsChange: { items in
                            visibleLargeFileItems = items
                        },
                        onStash: { item in
                            addToStash(
                                path: item.path,
                                title: item.title,
                                bytes: item.bytes,
                                isDirectory: false,
                                fileCount: 1
                            )
                        },
                        isStashed: { path in stash.contains(path) },
                        aiSettings: aiSettings,
                        onAskAI: { item in
                            let evaluation = coordinator.deletionSafetyEvaluation(for: item.path)
                            requestAI(row: RowItem(
                                id: item.path,
                                url: item.url,
                                title: item.title,
                                isDirectory: false,
                                bytes: item.bytes,
                                logicalBytes: item.logicalBytes,
                                fileCount: 1,
                                verdict: evaluation.verdict,
                                rejection: evaluation.rejection,
                                vendorName: evaluation.vendor?.name,
                                vendorNote: evaluation.vendor?.note,
                                runningBundleIDPrefix: evaluation.vendor?.bundleIDPrefix,
                                modificationDate: item.modificationDate
                            ))
                        }
                    )
                } else if coordinator.snapshot.rows.isEmpty {
                    placeholder(for: placeholderState)
                } else {
                    viewModeBar
                    Divider()
                    // v1.3.aa：原本 detail 是外层 NavigationSplitView 的第三列；现在两列后
                    // 改成清单/树视图与 inline 详情区横排。详情区在没选中时折叠为 0 宽。
                    // v1.3.ab：清单/树视图区强制 maxWidth: .infinity + minWidth: 320 + layoutPriority(1)，
                    // 防止某行内容（如 10 GB+ 长路径）反向把 List ideal width 抬高 →
                    // 挤压外层 NavigationSplitView 的 sidebar，从根本上消除"动不动 UI 错乱"。
                    HStack(spacing: 0) {
                        Group {
                            switch viewMode {
                            case .list:
                                listResults
                            case .tree:
                                if let root = coordinator.currentRootPath {
                                    TreeBrowserView(
                                        coordinator: coordinator,
                                        rootPath: root,
                                        selectionResetRevision: treeSelectionResetRevision,
                                        onSelect: { row in
                                            // bug A：树形选中 → 详情面板。同时清掉清单视图的 detail，
                                            // 避免两条选中态打架（detailPane 先看 treeSelection）。
                                            treeSelection = row
                                            detail = nil
                                            refreshSelectedTreeRowDeletionEligibility()
                                        },
                                        onSelectionCleared: {
                                            treeSelection = nil
                                            refreshSelectedTreeRowDeletionEligibility()
                                        },
                                        onTrash: { treeRow in
                                            // Tree 直接冻结用户看到的那一行。不能退化成 URL 后再去
                                            // coordinator 的可选 index 回查，否则按需展开行会丢失
                                            // size/count/isDirectory，确认页就会错误显示 Zero KB。
                                            guard let deletionRow = makeDeletionRow(treeRow) else {
                                                NSSound.beep()
                                                return
                                            }
                                            presentDeleteConfirmation(
                                                rows: [deletionRow],
                                                origin: .tree
                                            )
                                        },
                                        allowsVendorPathOverride: true,
                                        onRefreshSubtree: { path in
                                            // v2026.07.18 Tree P2：右键刷新拥有独立的后台子树
                                            // BulkScanner，会原子替换索引/证据；View 不自行清 cache，
                                            // 也不在 MainActor 枚举目录。
                                            guard interfaceMode == .professional, canReplaceScanContext,
                                                  !hasConflictingMainModalPresentation else { return }
                                            let source = scanContextIdentity
                                            Task { @MainActor in
                                                guard source == scanContextIdentity,
                                                      interfaceMode == .professional, canReplaceScanContext,
                                                      !hasConflictingMainModalPresentation else { return }
                                                await coordinator.rescanSubtree(at: path)
                                            }
                                        },
                                        onStash: { row in
                                            // v2026.06.18：把 TreeRow 装进购物车。
                                            // 入口在 tree row contextMenu / "加入待处理"。
                                            addToStash(
                                                path: row.path,
                                                title: row.title,
                                                bytes: row.bytes,
                                                isDirectory: row.isDirectory,
                                                fileCount: row.fileCount,
                                                titlePresentation: row.titlePresentation
                                            )
                                        },
                                        isStashed: { path in stash.contains(path) },
                                        aiSettings: aiSettings,
                                        onAskAI: { row in
                                            // v2026.06.20：tree 行 sparkles 按钮 → 复用 List 视图
                                            // 同一个 sheet 入口（aiAskingRow）。先把 TreeRow 映射成
                                            // RowItem 喂给 [AIAdviceSheet](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)。
                                            // SafetyEngine.evaluate 与 List 路径一致，让 AI 在拒删时
                                            // 看到同样的 verdict / rejection 上下文。
                                            //
                                            // v1.5 P2 / Q3：走 requestAI 收敛 —— 未配置时弹 alert。
                                            let evaluation = coordinator.deletionSafetyEvaluation(for: row.path)
                                            let snapshotItem = coordinator.snapshot.rows.first {
                                                $0.id == row.path
                                            }
                                            requestAI(row: RowItem(
                                                id: row.path,
                                                url: URL(fileURLWithPath: row.path),
                                                title: row.title,
                                                isDirectory: row.isDirectory,
                                                bytes: row.bytes,
                                                logicalBytes: row.logicalBytes,
                                                fileCount: row.fileCount,
                                                verdict: evaluation.verdict,
                                                rejection: evaluation.rejection,
                                                vendorName: snapshotItem?.vendorName ?? evaluation.vendor?.name,
                                                vendorNote: snapshotItem?.vendorNote ?? evaluation.vendor?.note,
                                                runningBundleIDPrefix: snapshotItem?.runningBundleIDPrefix
                                                    ?? evaluation.vendor?.bundleIDPrefix,
                                                modificationDate: row.modificationDate,
                                                titlePresentation: row.titlePresentation,
                                                vendorNamePresentation: snapshotItem?.vendorNamePresentation,
                                                vendorNotePresentation: snapshotItem?.vendorNotePresentation
                                            ))
                                        },
                                        // v1.5 P2 / Q1：把全局排序键 binding 喂给树视图，
                                        // 工具栏排序图标切换或列头点击 → 全局键同步 →
                                        // 主列表 / 树形 / 大文件视图都按同一序展示。
                                        globalSortKey: Binding(
                                            get: { settings.mainListSortKey },
                                            set: { settings.mainListSortKey = $0 }
                                        )
                                    )
                                    // v2 修：TreeBrowserView 内部用 @State 缓存了
                                    // selectedPath / expanded / sortKey；如果换了扫描根
                                    // 但 SwiftUI 把同一个 view instance 复用，旧 root 下的
                                    // 子路径 key 会残留在 expanded 字典里，新 root 自己的
                                    // 节点反而展不开 / 选不中——表现就是用户截图里
                                    // 「切到别的目录后树形一直不出来」。
                                    // 用 .id(root) 把 view identity 绑到 rootPath 上，
                                    // root 一变 SwiftUI 强制销毁旧 view + 重建新 view，
                                    // 所有 @State 自然清零。
                                    .id(root)
                                } else {
                                    Text("tree.empty.no_roots", bundle: .module)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                        .frame(minWidth: 320, maxWidth: .infinity)
                        .layoutPriority(1)
                        if detail != nil || treeSelection != nil {
                            Divider()
                            inlineDetailPane
                                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                        }
                    }
                }
                Divider()
                footerBar
            }
        }
        // Professional detail 入口只允许这一层 WidthSandbox。各子屏不得再嵌套
        // GeometryReader，否则会触发 AppKit 约束多轮更新；列宽 preference 放在
        // sandbox 外面，确保 NavigationSplitView 可以稳定读取。
        .layoutSandbox()
        .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        .onValueChange(of: coordinator.snapshot.rows.count) { _, newCount in
            if newCount == 0 {
                lastDefaultSelectedSeenCount = 0
                return
            }
            // v2026.07.19 regression fix: the predecessor frame remains visible while a producer
            // settles, but it is disclosure-only. Never bind its rows to the incoming selection
            // session merely because the legacy Boolean is already false.
            guard coordinator.canUseCurrentScanResultsForActions else { return }
            // 默认勾选：仅勾 .safe（PITFALLS §5.5）
            // 用 union：用户已经手动改过的不要被覆盖
            //
            // v2026.06.21 perf：原来每次 publish 都对整个 `rows` 做 O(N) filter
            // + N 次 `selection.contains`（dev 扫几千行场景下是 listResults +
            // statusBar 同帧卡顿的元凶 P0-2）。流式 publishSnapshot 路径下 rows
            // 只 append 不删，所以只需扫描 `[seen ..< newCount]` 末尾差量。
            // 当 newCount < seen（外部 pruneDeleted / 切分类 / 重扫）时回退到
            // 全表扫描，并把 seen 重置——保持语义不变。
            let rows = coordinator.snapshot.rows
            let seen = lastDefaultSelectedSeenCount
            let startIdx = (newCount >= seen && rows.count == newCount) ? seen : 0
            if startIdx == 0 { lastDefaultSelectedSeenCount = 0 }
            // 仅遍历末尾差量（含 startIdx == 0 时的全量回退）
            var idx = startIdx
            let end = rows.count
            while idx < end {
                let r = rows[idx]
                if r.defaultSelected, !selection.contains(r.id) {
                    selection.insert(r.id)
                }
                idx &+= 1
            }
            lastDefaultSelectedSeenCount = end
        }
        // v2026.06.22 perf：listResults 扫描中冻结。
        // 设计要点：
        //  - onAppear：首次出现立刻同步一份（让用户切到 List 视图时不会看到空白）。
        //  - onChange(snapshot)：扫描中只补第一帧非空数据；非扫描中立刻同步。
        //  - onChange(isScanning)：从 true→false 时立即把 latest 补齐，
        //    避免"扫描刚结束但列表停在旧帧"的视觉残影。
        .onAppear {
            syncThrottledListSnapshotIfNeeded(force: true)
        }
        .onValueChange(of: coordinator.snapshot) { _, _ in
            syncThrottledListSnapshotIfNeeded(force: false)
        }
        .onValueChange(of: coordinator.scanPhase) { _, phase in
            // v2026.07.19: `.settling` also has isScanning=false but still discloses the old
            // frozen frame. Only authoritative idle may materialize/select the terminal list.
            if phase == .idle, !coordinator.isScanning {
                syncThrottledListSnapshotIfNeeded(force: true)
                applyDefaultSelectionForCurrentSnapshot()
            }
        }
    }

    /// 视图模式切换条（**v1.3.zzzz Phase 4-A 起：树形为主、清单降级**）。
    ///
    /// 设计与方案 C 对齐：
    /// - 左侧仍保留 segmented Picker 让两种视图可一键切换（兼顾 v1.0 - v1.2 老用户的肌肉记忆）
    /// - 但 segmented 宽度从 220 收到 180，并在右侧补一行"主视图"角标，让用户**首屏理解**"树是默认"
    /// - 提示文案从原来的"批量勾选请切回清单"改成中性说明，
    ///   避免暗示"清单才是干活视图"。批量删除能力沿用 [大文件批量页 (P1-5)](file:///Users/amuxuser/workspace/AmuxAIClean) 与
    ///   清单视图，不强迫所有人切回清单
    private var viewModeBar: some View {
        HStack(spacing: 12) {
            Picker(selection: $viewMode) {
                ForEach(ResultsViewMode.allCases) { mode in
                    Label(mode.label(locale: locale), systemImage: mode.icon).tag(mode)
                }
            } label: {
                Text("view_mode.picker.label", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)
            .accessibilityIdentifier("main.results-view-mode")
            .controlGuideTarget(.resultsMode)

            // 当前视图角标——告诉用户"你在看树形（主视图）"或"清单是二级 fallback"
            switch viewMode {
            case .tree:
                Label {
                    Text("view_mode.tree.tag", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.grid.1x2")
                }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .list:
                Label {
                    Text("view_mode.list.tag", bundle: .module)
                } icon: {
                    Image(systemName: "list.bullet")
                }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // 视图特定提示——中性说明操作方式，不再暗示"另一个视图才是正经的"
            switch viewMode {
            case .tree:
                Text("view_mode.tree.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .list:
                Text("view_mode.list.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var listResults: some View {
        // v1.5 P2 滑动卡顿修复：把 maxBytes 提到 ForEach 外，并量化到下一个 2 的幂次。
        //
        // 旧实现：`maxBytes: coordinator.snapshot.rows.first?.bytes ?? 0`
        //   1) 在 ForEach 闭包里每行都访问一次 snapshot.rows（每行都建立一次 observation）
        //   2) 扫描期主列表流式按 path 字典序排，首行 bytes 几乎每帧都在涨 →
        //      `maxBytes` 参与 RowContentView 的 Equatable 比较 → 每行都被判不相等 →
        //      Equatable 短路完全失效。
        // 现在：① v2026.06.21 改读 `coordinator.snapshot.maxRowBytes`（stored let，
        //   由 publishSnapshot 一次性预算好），body 帧不再 O(N) 扫；
        //   ② 量化到下一个 2 的幂次，让相邻帧大概率相等（10MB → 16MB，11MB 仍 16MB），
        //   命中 Equatable 短路 → 千行场景 body 调用数从"每帧 × N"降到接近 0。
        //
        // v2026.06.22 perf：扫描中底部 List 冻结。
        // 改读 [throttledListSnapshot](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift#L45)
        // —— 由 syncThrottledListSnapshotIfNeeded 维护，扫描中只补第一帧非空数据、
        // 非扫描中或扫描结束瞬间立刻同步 latest。这条只对底部 List 生效，
        // statusBar / sidebar / footerBar 仍按 0.4s 跟手。
        // 首次渲染 throttled 还为 nil 时回退到 coordinator.snapshot 兜底。
        let snap = throttledListSnapshot ?? coordinator.snapshot
        let maxBytes = Self.quantizeToPow2(snap.maxRowBytes)
        return List(selection: $detail) {
            ForEach(snap.rows) { row in
                let isOn = Binding<Bool>(
                    get: { selection.contains(row.id) },
                    set: { newValue in
                        if newValue { selection.insert(row.id) }
                        else { selection.remove(row.id) }
                    }
                )
                RowView(row: row, selected: isOn,
                        maxBytes: maxBytes,
                        allowsVendorPathOverride: true,
                        aiSettings: aiSettings,
                        // v1.5 P2 / Q3：走 requestAI 收敛 —— 未配置时弹 alert 引导设置。
                        onAskAI: { picked in requestAI(row: picked) })
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
        // bug B：清单视图的 List(selection:) 同样会画容器级焦点环，关掉。
        // 单行选中蓝条不受影响。
        .suppressesFocusEffectWhenSupported()
        // v1.3.ab：把 List 的本征宽度上限钉死在父容器宽度，禁止某条特别宽的 RowView
        // （比如 10 GB+ 路径很长的行）反向把 ideal width 抬高 → 把整个外层 sidebar 挤掉。
        .frame(minWidth: 320, maxWidth: .infinity)
        .layoutPriority(1)
    }

    /// v1.5 P2：把任意正整数量化到下一个 2 的幂次（≤0 直接返回 0）。
    /// 让 maxBytes 在扫描流式帧之间保持"阶梯式增长"——相邻帧大概率相等，
    /// 配合 RowContentView 的 Equatable 比较实现真正的 body 短路。
    static func quantizeToPow2(_ x: Int64) -> Int64 {
        guard x > 0 else { return 0 }
        // bit_length(x) = 64 - leadingZeroBitCount；2^(bit_length) 即"≥x 的最小 2 的幂"。
        let lz = x.leadingZeroBitCount
        let bits = 64 - lz
        if bits >= 63 { return Int64.max }
        return Int64(1) << bits
    }

    /// 扫描问题只能投影成一个互斥主状态，避免 permission banner、partial 文案和
    /// raw lastError 同时抢占页面。兼容数组先在模型层去重；UI 不再直接渲染错误对象。
    private var scanIssuePresentation: ScanIssuePresentation {
        ScanIssuePresentation.make(
            hasTerminalFailure: coordinator.terminalFailure != nil,
            permissionDeniedPaths: coordinator.permissionDeniedPaths,
            tccSkippedPaths: coordinator.tccProtectedSkippedPaths,
            incompletePaths: coordinator.incompleteScanPaths
        )
    }

    private var statusBar: some View {
        let issuePresentation = scanIssuePresentation
        return VStack(spacing: 0) {
            if issuePresentation.kind == .fatal {
                ScanFailureBanner(
                    onRetry: {
                        rescanCurrentCategory()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if issuePresentation.kind == .limitations {
                PermissionStatusBanner(
                    fdaDeniedPaths: issuePresentation.permissionDeniedPaths,
                    tccSkippedPaths: issuePresentation.tccSkippedPaths,
                    otherIncompletePaths: issuePresentation.otherIncompletePaths,
                    fdaStatus: coordinator.fdaStatus,
                    onOpenSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    onOpenFilesAndFolders: {
                        // v2026.06 #1：跳「文件与文件夹」面板（Files & Folders 类目）。
                        // 这是 macOS 14+ Downloads/Documents/Desktop 的实际授权开关，
                        // 与 FDA 无关。anchor ID 不同——`Privacy_FilesAndFolders`。
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    onRescan: {
                        // v1.3：跳系统设置 + 立即重扫当前 category。
                        // 用户回到 App 时本就能看到"扫描中"，
                        // 等他在系统设置勾完 AmuxAIClean 那一刻起，
                        // 后续 BulkScanner 拿到的就是含原 TCC 跳过路径的完整树。
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                        rescanCurrentCategory()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            // v2026.06.21：原"勘察超时 / 结果已截断" banner 已整体移除。
            // 用户明确反馈：进入这种状态本身就是异常，不应该让用户看到内部限流状态。
            // 配合 [DevArtifactScanner.Options.maxHits](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DevArtifactScanner.swift)
            // 默认值改为 .max（实际永远不截断），devArtifactDidTruncate /
            // devArtifactDidTimeout 字段仅保留作内部诊断，UI 不再读。
            HStack {
                if let settlement = coordinator.scanPhase.settlementStatusPresentation {
                    ProgressView()
                        .controlSize(.small)
                    Text(settlement.localized(locale: locale))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if coordinator.isScanning {
                    if coordinator.activeCategoryID == ScanCoordinator.commonAppCacheCategoryID,
                       let progress = coordinator.commonAppCacheProgress {
                        commonAppCacheGroupProgress(progress)
                    } else {
                        // Only this small child observes the 0.4-second progress channel. MainView
                        // remains stable while the sidebar is being scrolled during full-disk IO.
                        MainScanLiveProgressView(
                            progress: coordinator.liveProgress,
                            expectedTotalBytes: coordinator.expectedTotalBytes,
                            locale: locale,
                            multiRootMaxHeight: multiRootProgressScrollMaxHeight
                        )
                    }
                } else if coordinator.snapshot.isFinished {
                    if coordinator.snapshot.isComplete {
                        Text(AppLocalization.format(
                            "main.scan.finished",
                            locale: locale,
                            arguments: [
                                coordinator.snapshot.scannedFileCount,
                                formattedBytes(coordinator.snapshot.totalBytes),
                                String(format: "%.2fs", coordinator.snapshot.elapsed),
                            ]
                        ))
                            .font(.callout)
                    } else {
                        Text(AppLocalization.format(
                            "main.scan.incomplete.summary %lld %@ %@",
                            locale: locale,
                            arguments: [
                                Int64(coordinator.snapshot.scannedFileCount),
                                formattedBytes(coordinator.snapshot.totalBytes),
                                String(format: "%.2fs", coordinator.snapshot.elapsed),
                            ]
                        ))
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } else if coordinator.wasCancelled {
                    // v1.3：cancel 后区分"已停止"与"还未扫描"两态，避免用户以为停止键失灵
                    Text("main.scan.cancelled", bundle: .module)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    // v1.3：未扫描态显式文案，避免空 snapshot 渲染成 "0 KB · 0 个文件" 误导用户。
                    // 区分两种 pristine：已选类目但未点扫 / 完全没选类目。
                    if selectedCategory != nil {
                        Text("results.empty.idle.with_top_buttons", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        Text("results.empty.idle.with_left_picker", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                Spacer()
            }
            .accessibilityIdentifier("main.scan-status")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 三态占位 —— 见 PITFALLS §5.6（OnyX 教训：空态要给"下一步动作"）。
    enum PlaceholderState: Equatable {
        case notStarted
        case scanning
        case finishedEmpty(rootPath: String)
    }

    /// 由 coordinator 派生当前应该显示的占位态。
    /// - 正在扫描 → `.scanning`
    /// - 已扫完且行为空 → `.finishedEmpty`（携带刚扫的目录路径）
    /// - 否则（含初始态、用户切类目还没开始）→ `.notStarted`
    var placeholderState: PlaceholderState {
        // `.settling` still owns an incoming scan. Showing the predecessor's empty terminal frame
        // as "finished empty" makes the replacement look complete before admission.
        if coordinator.hasActivePrimaryScanOwnership {
            return .scanning
        }
        if coordinator.isFinished, let root = coordinator.currentRootPath {
            return .finishedEmpty(rootPath: root)
        }
        return .notStarted
    }

    @ViewBuilder
    private func placeholder(for state: PlaceholderState) -> some View {
        switch state {
        case .notStarted:
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("results.empty.title", bundle: .module)
                    .foregroundStyle(.secondary)
                Text("results.empty.no_results.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .scanning:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("results.scanning", bundle: .module)
                    .foregroundStyle(.secondary)
                Text("main.scan.first.hint", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .finishedEmpty(let rootPath):
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("results.empty.nothing_to_clean", bundle: .module)
                    .foregroundStyle(.secondary)
                sentinelAwareRootPathText(rootPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
                Button {
                    // v1.3 review-fix：仅清 selectedCategory 并不会清 placeholder（coordinator
                    // 仍保留 isFinished=true + currentRootPath），用户视觉上"无反馈"。
                    // 主动 cancel() 把 snapshot/currentRootPath 清回 .notStarted 态。
                    coordinator.cancel()
                    selectedCategory = nil
                } label: {
                    Label {
                        Text("results.empty.try_other_dir", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// v2026.06.21：placeholder 的 `.finishedEmpty(rootPath)` 分支会拿 `currentRootPath`
    /// 直接渲染。当多根/开发者构建产物/开发者旧版本扫描走伪根时，
    /// rootPath 是 [ScanCoordinator](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L185)
    /// 里定义的英文 sentinel ID，不该当作真实路径展示——这里映射到对应
    /// `path.sentinel.*` xcstrings key 走本地化显示；非 sentinel 仍按原路径打印。
    @ViewBuilder
    private func sentinelAwareRootPathText(_ rootPath: String) -> some View {
        switch rootPath {
        case ScanCoordinator.multiRootSentinelPath:
            Text("path.sentinel.multi_root", bundle: .module)
        case ScanCoordinator.developerSentinelPath:
            Text("path.sentinel.dev_artifact", bundle: .module)
        case ScanCoordinator.versionedRootSentinelPath:
            Text("path.sentinel.versioned_root", bundle: .module)
        case ScanCoordinator.commonAppCacheSentinelPath:
            Text("path.sentinel.common_app_cache", bundle: .module)
        default:
            Text(rootPath)
        }
    }

    private func rescanCurrentCategory() {
        guard canReplaceScanContext else { return }
        guard let id = selectedCategory else { return }
        switch id {
        case ScanCategory.batchRecommendedID:
            triggerRecommendedScan()
        case ScanCategory.batchDeveloperID:
            triggerDeveloperScan()
        case ScanCategory.batchFullDiskID:
            triggerFullDiskScan()
        case ScanCategory.batchCommonAppCacheID:
            triggerCommonAppCacheScan()
        case MainView.devVersionedSentinelID:
            triggerKnownVersionedScan()
        default:
            guard let cat = allCategories.first(where: { $0.id == id }) else { return }
            startScan(category: cat)
        }
    }

    private var footerBar: some View {
        // v2026.06.21 perf：listResults 出现后两个列表同时卡的核心证据 ——
        // footerBar 一帧内 `selectedRows` 被读 3+ 次（selectionSummary、isEmpty
        // 用于 .disabled、Button action 中的 !isEmpty），每次都是
        // `coordinator.snapshot.rows.filter { ... }` 整表 O(N) filter。
        // dev 扫场景下 snapshot 每 0.4s publish + listResults ForEach 抬高 body
        // 失效频率 → 整帧主线程 footerBar 这段就吃掉数毫秒，statusBar 同
        // transaction 被一并拖卡（与 listResults / inlineDetailPane 串行 layout）。
        // 改为 body 顶端一次 let 计算 selectedRows + 预算 summary 文本，
        // 后续三处复用同一个 `selectedRowsEmpty` / `summaryText`。
        let isTreeMode = !isLargeFilesMode && viewMode == .tree
        let listSelectionRows = (isLargeFilesMode || isTreeMode) ? [] : selectedRows
        let activeTreeRow: TreeRow? = isTreeMode ? treeSelection : nil
        let canDeleteActiveTreeRow: Bool = {
            guard let activeTreeRow,
                  canDeleteSelectedTreeRow,
                  coordinator.canUseCurrentScanResultsForActions,
                  !coordinator.isFetchingChildren(
                      of: activeTreeRow.path,
                      sortedBy: .from(global: settings.mainListSortKey)
                  ) else { return false }
            return true
        }()
        let selectedRowsEmpty = isTreeMode ? !canDeleteActiveTreeRow : listSelectionRows.isEmpty
        let summaryText: String = {
            if isTreeMode {
                guard let activeTreeRow else {
                    return AppLocalization.string("selection.empty", locale: locale)
                }
                return String(
                    format: AppLocalization.string("selection.summary %lld %@", locale: locale),
                    1,
                    formattedBytes(activeTreeRow.bytes)
                )
            }
            if selectedRowsEmpty { return AppLocalization.string("selection.empty", locale: locale) }
            let total = listSelectionRows.reduce(Int64(0)) { $0 + $1.bytes }
            return String(format: AppLocalization.string("selection.summary %lld %@", locale: locale), listSelectionRows.count, formattedBytes(total))
        }()
        return HStack {
            if isLargeFilesMode {
                // v2026.07 Q1：底部条改为**唯一**批量删除入口。
                //
                // 摘要文本口径：
                //   - 有勾选 → "已选 N 项（合计 X）"（复用 selection.summary %lld %@）
                //   - 无勾选但有单击行焦点 → 显示行摘要（footer.selection.large_file）
                //   - 都没有 → selection.empty
                //
                // 删除按钮口径：
                //   - 有勾选 → 走 batch，删掉所有勾选项（用户明确意图，即便被 kindFilter 隐藏也算）
                //   - 无勾选但有 largeFileSelection → 退化为单行删（Cmd+Delete 沿用原有快捷键语义）
                //   - 两者都无 → disabled
                let visibleLargeFilePaths = visibleLargeFileItems.map(\.path)
                let pickedPaths = largeFilesBatch.selectedItemsIntersecting(visible: visibleLargeFilePaths)
                let pickedCount = pickedPaths.count
                let hasPicked = pickedCount > 0
                let pickedBytes: Int64 = {
                    guard hasPicked else { return 0 }
                    let pickedSet = Set(pickedPaths)
                    var sum: Int64 = 0
                    for item in visibleLargeFileItems where pickedSet.contains(item.path) {
                        sum &+= item.bytes
                    }
                    return sum
                }()
                let summary: String = {
                    if hasPicked {
                        return String(format: AppLocalization.string("selection.summary %lld %@", locale: locale),
                                      pickedCount, formattedBytes(pickedBytes))
                    }
                    if let sel = largeFileSelection {
                        return String(format: AppLocalization.string("footer.selection.large_file %@ %@", locale: locale),
                                      sel.title, formattedBytes(sel.bytes))
                    }
                    return AppLocalization.string("selection.empty", locale: locale)
                }()
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    if hasPicked {
                        let pickedSet = Set(pickedPaths)
                        let rows = visibleLargeFileItems
                            .filter { pickedSet.contains($0.path) }
                            .map(makeDeletionRow)
                        presentDeleteConfirmation(rows: rows, origin: .largeFiles)
                    } else if let item = largeFileSelection {
                        presentDeleteConfirmation(
                            rows: [makeDeletionRow(item)],
                            origin: .largeFiles
                        )
                    }
                } label: {
                    Label {
                        Text("toolbar.delete.move_to_trash", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(
                    (!hasPicked && largeFileSelection == nil)
                        || isDeleting
                        || isPreparingDeletion
                        || !coordinator.canUseCurrentScanResultsForActions
                )
                .keyboardShortcut(.delete, modifiers: .command)
                .controlGuideTarget(.deleteSelection)
            } else {
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if isTreeMode {
                        if canDeleteActiveTreeRow,
                           let activeTreeRow,
                           let deletionRow = makeDeletionRow(activeTreeRow) {
                            presentDeleteConfirmation(
                                rows: [deletionRow],
                                origin: .tree
                            )
                        }
                    } else if !selectedRowsEmpty {
                        presentDeleteConfirmation(
                            rows: listSelectionRows,
                            origin: .scanSelection
                        )
                    }
                } label: {
                    Label {
                        Text("toolbar.delete.move_to_trash", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(
                    selectedRowsEmpty
                        || isDeleting
                        || isPreparingDeletion
                        || !coordinator.canUseCurrentScanResultsForActions
                )
                .keyboardShortcut(.delete, modifiers: .command)
                .controlGuideTarget(.deleteSelection)
            }
        }
        .padding(16)
    }

    // MARK: - Detail (inline)

    /// v1.3.aa：从外层 NavigationSplitView 的 detail 列拿下来后，
    /// 详情区只在「清单选中行」或「树形选中行」时才挂载（条件渲染在 results 里）。
    /// 不再有"未选中显示占位"的态——空态本来就该是 0 宽，让清单/树视图占满。
    /// v1.3.ab：detail 现在是 row.id（String），渲染时即席从 snapshot.rows 里反查。
    @ViewBuilder
    private var inlineDetailPane: some View {
        if let id = detail,
           let item = coordinator.snapshot.rows.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VerdictBadge(verdict: item.verdict)
                            .frame(width: 14, height: 14)
                        Text(verbatim: item.displayTitle(locale: locale))
                            .font(.title2.bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        closeInlineDetailButton
                    }
                    Text(item.url.path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .longPathStyle()
                    Divider()
                    LabeledContent(AppLocalization.string("detail.size.physical", locale: locale), value: formattedBytes(item.bytes))
                    LabeledContent(AppLocalization.string("detail.size.logical", locale: locale), value: formattedBytes(item.logicalBytes))
                    LabeledContent(AppLocalization.string("detail.file.count", locale: locale), value: "\(item.fileCount)")
                    LabeledContent(AppLocalization.string("detail.is.directory", locale: locale), value: item.isDirectory ? AppLocalization.string("detail.bool.yes", locale: locale) : AppLocalization.string("detail.bool.no", locale: locale))
                    LabeledContent(AppLocalization.string("detail.safety.level", locale: locale), value: verdictLabel(item.verdict))
                    if item.verdict == .forbid {
                        Text(String(
                            format: AppLocalization.string("detail.rejection.reason", locale: locale),
                            DeletionSafetyReasonPresentation.text(for: item.rejection.rawValue, locale: locale)
                        ))
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
                // v2：统一详情面板样式（padding + maxWidth.infinity + leading 对齐）。
                .detailPaneStyle()
            }
        } else if let row = treeSelection {
            let metrics = TreeMetricPresentation(row: row, locale: locale)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(.tint)
                        Text(verbatim: row.displayTitle(locale: locale))
                            .font(.title2.bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        closeInlineDetailButton
                    }
                    Text(row.path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .longPathStyle()
                    Divider()
                    if let partialStatus = metrics.partialStatusText {
                        Label(partialStatus, systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .help(metrics.helpText ?? partialStatus)
                    }
                    LabeledContent(
                        AppLocalization.string("detail.size.physical", locale: locale),
                        value: metrics.size.detailText
                    )
                    LabeledContent(
                        AppLocalization.string("detail.size.logical", locale: locale),
                        value: metrics.logicalSize.detailText
                    )
                    LabeledContent(
                        AppLocalization.string("detail.file.count", locale: locale),
                        value: metrics.count.detailText
                    )
                    LabeledContent(AppLocalization.string("detail.is.directory", locale: locale), value: row.isDirectory ? AppLocalization.string("detail.bool.yes", locale: locale) : AppLocalization.string("detail.bool.no", locale: locale))
                    if row.isDirectory && row.hasChildren {
                        LabeledContent(AppLocalization.string("detail.expandable", locale: locale), value: AppLocalization.string("detail.bool.yes", locale: locale))
                    }
                    Divider()
                    Text("detail.tree.hint", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .detailPaneStyle()
            }
        }
    }

    private var closeInlineDetailButton: some View {
        Button {
            closeInlineDetail()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AppLocalization.string("detail.action.close", locale: locale))
        .accessibilityLabel(Text("detail.action.close", bundle: .module))
    }

    /// v2026.07.20：详情列有两个互斥 owner。关闭必须在同一事务清空二者，
    /// 不能只清当前分支，否则下一帧会立刻显示另一份陈旧详情。
    private func closeInlineDetail() {
        detail = nil
        treeSelection = nil
        treeSelectionResetRevision &+= 1
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // macOS 26 会自动给 ToolbarItemGroup 添加共享 Liquid Glass 背景。品牌标题不是
        // 操作控件，不应被画成可点击胶囊；使用系统提供的 modifier 明确关闭该背景。
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                mainToolbarBrand
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                mainToolbarBrand
            }
        }
        ToolbarItem(placement: .navigation) {
            interfaceModePicker
        }
        if interfaceMode == .professional {
            ToolbarItem(placement: .navigation) {
                pathBar
            }
            if !isStandaloneProfessionalToolMode && !isLargeFilesMode {
                ToolbarItem(placement: .primaryAction) {
                    sortMenu.labelStyle(.iconOnly)
                }
            }
        }
    }

    /// v2026.10.11: these buttons belong to the window's permanent right accessory,
    /// outside NSToolbar's overflow contract. Counts and scan phases update existing controls.
    private var permanentWindowActions: some View {
        HStack(spacing: 12) {
            if interfaceMode == .professional {
                stashToolbarButton
                scanControlButton
                    .disabled(!canReplaceScanContext || hasConflictingMainModalPresentation)
                    .accessibilityIdentifier("main.scan-control")
                    .controlGuideTarget(.rescan)
            }
            userGuideToolbarButton
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 17))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 8)
        .fixedSize()
        .environment(\.locale, locale)
        .environment(\.controlGuideAnchors, guideAnchors)
    }

    private var userGuideToolbarButton: some View {
        Button {
            applicationPresentation.requestUserGuide(hostID: presentationHostID)
        } label: {
            Label {
                Text("toolbar.user_guide.title", bundle: .module)
            } icon: {
                Image(systemName: "questionmark.circle")
            }
        }
        .help(AppLocalization.string("toolbar.user_guide.help", locale: locale))
        .disabled(hasConflictingMainModalPresentation)
        .accessibilityIdentifier("main.user-guide")
        .controlGuideTarget(.reopenGuide)
    }

    private var mainToolbarBrand: some View {
        HStack(spacing: 6) {
            Text("main.nav.title", bundle: .module)
                .font(.headline)
                .lineLimit(1)
            appVersionBadge
        }
    }

    private var interfaceModePicker: some View {
        Picker(
            AppLocalization.string("smart_care.mode.label", locale: locale),
            selection: Binding(
                get: { interfaceMode },
                set: { transitionInterfaceMode(to: $0) }
            )
        ) {
            Text("smart_care.mode.normal", bundle: .module)
                .tag(SmartCareInterfaceMode.normal)
            Text("smart_care.mode.professional", bundle: .module)
                .tag(SmartCareInterfaceMode.professional)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .help(Text("smart_care.mode.label", bundle: .module))
        .disabled(hasActiveBusinessTransaction)
        // Stable semantic hook for accessibility and the single-session C4 matrix.
        .accessibilityIdentifier("main.interface-mode")
        .controlGuideTarget(.interfaceMode)
    }

    /// 主窗口始终展示最终 App Bundle 的真实营销版本，便于截图、反馈和发版验收时
    /// 直接确认正在运行的二进制。版本来源与「设置 → 更新」共用
    /// [UpdateChecker.currentVersion]，禁止在 UI 里写死发布版本。
    private var appVersionBadge: some View {
        let version = UpdateChecker.currentVersion
        let accessibleLabel = String(
            format: AppLocalization.string("updater.prompt.current_version %@", locale: locale),
            version
        )
        return Text(verbatim: version)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .accessibilityLabel(accessibleLabel)
            .help(accessibleLabel)
    }

    /// v1.3：主列表排序选择器。
    /// - 默认 `.sizeDesc`（按字节大小从大到小），最常用，所以放默认。
    /// - 扫描中切换不会打乱视觉位置：[ScanCoordinator.publishSnapshot](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    ///   在 finished=false 时强制 path 字典序，仅 finished=true 才用此键排序。
    /// - 用 Menu 而不是 segmented Picker：6 个 case 横排太挤；Menu 更紧凑且 macOS 原生。
    /// - AppSettings 由 MainView 以 `@ObservedObject` 持有，Picker 直接使用 projected binding。
    private var sortMenu: some View {
        return Menu {
            Picker(selection: $settings.mainListSortKey) {
                ForEach(MainListSortKey.allCases) { key in
                    Text(key.label(locale: locale)).tag(key)
                }
            } label: {
                Text("sort.menu.label", bundle: .module)
            }
            .pickerStyle(.inline)
        } label: {
            Label(settings.mainListSortKey.label(locale: locale), systemImage: "arrow.up.arrow.down")
        }
        .help(AppLocalization.string("sort.menu.help", locale: locale))
    }

    /// v2026.06.21：是否需要在切换 category 前弹确认。
    /// 判定口径："用户切走后会丢失"的状态都算——任一为真即弹：
    ///   - 当前在扫描（无论哪类入口）
    ///   - 主 snapshot 有 row（普通 category / batch 完成后留存）
    ///   - perRoot 还有 active 行（batch 扫描中间态）
    ///   - perRoot 有 finished 行（batch 完成后留存）
    /// 不能光靠 `coordinator.snapshot.isFinished` 判定：batch 扫描在 sidebar
    /// 留存的不是 snapshot.rows，而是 perRootFinishedSlim。
    private var shouldConfirmCategorySwitch: Bool {
        if coordinator.hasActivePrimaryScanOwnership { return true }
        if !coordinator.snapshot.rows.isEmpty { return true }
        if !coordinator.perRootProgressActive.isEmpty { return true }
        if coordinator.perRootFinishedCount > 0 { return true }
        return false
    }

    private var sidebarSelectionBinding: Binding<String?> {
        Binding(
            get: { selectedCategory },
            set: { requestCategorySwitch(to: $0) }
        )
    }

    @discardableResult
    private func requestCategorySwitch(to new: String?, fallbackCategory: ScanCategory? = nil,
                                       customPaths: [URL] = []) -> Bool {
        guard interfaceMode == .professional, canReplaceScanContext,
              !hasConflictingMainModalPresentation else { return false }
        let old = selectedCategory
        let intent = MainCategorySwitchIntent(source: scanContextIdentity, destinationID: new,
                                             fallbackCategory: fallbackCategory, customPaths: customPaths)
        guard old != new else {
            // 重复添加当前正在查看的路径仍然是一个明确的“扫描这里”意图。
            // 直接使用冻结类目，不等待跨 Scene 的 AsyncStream 镜像刷新。
            if let fallbackCategory, fallbackCategory.id == new {
                startScan(category: fallbackCategory)
                persistCommittedCustomPaths(customPaths)
                return true
            }
            return false
        }
        if shouldConfirmCategorySwitch {
            pendingCategorySwitch = intent
            showSwitchCategoryConfirm = true
            return true
        }
        return applyCategorySwitch(intent)
    }

    private func consumeConfirmedCategorySwitchIfPossible() {
        guard let intent = confirmedCategorySwitch else { return }
        guard isPresentationHostMounted, intent.isCurrent(in: scanContextIdentity) else {
            confirmedCategorySwitch = nil
            return
        }
        // The accepted intent retains priority until the native confirmation really closes.
        // App hints cannot occupy the gap, and a stale callback cannot switch a newer context.
        guard !hasOtherBusinessMainModalPresentation,
              applicationPresentation.canReplaceScanContext(for: presentationHostID,
                  hasLocalTransaction: hasActiveBusinessTransaction) else { return }
        confirmedCategorySwitch = nil
        _ = applyCategorySwitch(intent)
    }

    /// v2026.10.11 review: category, selection and scan admission are one synchronous commit.
    /// ScanCoordinator already owns async producer settlement and background preparation;
    /// delaying only the start by 16ms left a half-switched page and revived stale requests.
    @discardableResult
    private func applyCategorySwitch(_ intent: MainCategorySwitchIntent) -> Bool {
        guard intent.isCurrent(in: scanContextIdentity), canReplaceScanContext,
              !hasConflictingMainModalPresentation else { return false }
        let old = intent.source.categoryID
        let new = intent.destinationID
        guard old != new else { return false }
        let category = new.flatMap { id in
            allCategories.first(where: { $0.id == id })
                ?? intent.fallbackCategory.flatMap { $0.id == id ? $0 : nil }
        }
        let batchAction: (() -> Void)?
        if let id = new, ScanCategory.batchScanIDs.contains(id) {
            switch id {
            case ScanCategory.batchRecommendedID:
                batchAction = triggerRecommendedScan
            case ScanCategory.batchDeveloperID:
                batchAction = triggerDeveloperScan
            case ScanCategory.batchFullDiskID:
                batchAction = triggerFullDiskScan
            case ScanCategory.batchCommonAppCacheID:
                batchAction = triggerCommonAppCacheScan
            default:
                // v1.5 review-fix #1：batchScanIDs 已穷尽当前 case；future 加 sentinel
                // 必须同步加 case，否则 selection 切到新 sentinel 会被静默吞掉。
                assertionFailure("Unhandled batch scan sentinel id: \(id) — add case to MainView.applyCategorySwitch switch.")
                return false
            }
        } else {
            batchAction = nil
        }
        // v2026.07.16 scan-performance regression fix: specialized destinations
        // do not call ScanCoordinator.scan(...), so relying on the next scan to
        // cancel the old producer left a full-disk/recommended scan running behind
        // the newly selected screen. Resolve the destination before relinquishing
        // ownership; then commit selection and dispatch without an intervening await.
        MainScanOwnershipPolicy.relinquishProfessionalCategory(from: old, to: new) {
            coordinator.cancel()
        }
        if let batchAction {
            batchAction()
            persistCommittedCustomPaths(intent.customPaths)
            return true
        }
        selectedCategory = new
        // M4-T2 / 2026-06：开发者版本化收集根扫描 sentinel —— 不在 allCategories 里，
        // 由 ScanCoordinator.scanKnownVersionedRoots(home:) 同步派发命中。
        // 必须在 allCategories.first 之前拦截，否则会走 startScan(category:) 找不到 cat 直接 return。
        if let id = new, id == MainView.devVersionedSentinelID {
            triggerKnownVersionedScan()
        } else if let cat = category {
            startScan(category: cat)
        } else {
            resetSelectionState()
        }
        persistCommittedCustomPaths(intent.customPaths)
        return true
    }

    private func persistCommittedCustomPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Persistence records an already accepted UI commit. No awaited write can precede
        // the admission decision or resurrect a rejected/abandoned path submission.
        let store = pathStore
        Task {
            for url in urls { _ = await store.add(url) }
        }
    }

    /// v1.5：把 toolbar「全部推荐扫描」按钮的逻辑抽成 helper，供 sidebar Batch Scans
    /// 入口复用。除了起扫还把 selectedCategory 同步到 batch sentinel，让 sidebar
    /// 蓝条高亮跟手——没有这一步用户感知不到自己当前在跑哪条。
    ///
    /// v1.5 review-fix #2：reset 由 helper 唯一负责（onChange 在 batch.* 分支不再 reset）。
    /// 这是因为 toolbar 重复点同一按钮时 selection 没变 onChange 不触发，必须 helper 兜底。
    /// review-fix #12：可见性收紧到 private，与 triggerFullDiskScan 一致。
    private func triggerRecommendedScan() {
        guard canReplaceScanContext else { return }
        resetSelectionState()
        selectedCategory = ScanCategory.batchRecommendedID
        coordinator.scanRecommended(includeHidden: settings.showHidden)
    }

    /// v1.5：开发者扫描的统一入口，理由同上。
    private func triggerDeveloperScan() {
        guard canReplaceScanContext else { return }
        resetSelectionState()
        selectedCategory = ScanCategory.batchDeveloperID
        coordinator.scanDeveloper(includeHidden: settings.showHidden,
                                  enabledRuleIDs: settings.enabledDevArtifactRuleIDs)
    }

    /// 常见应用缓存扫描入口：规则命中列表，不做大根递归。
    private func triggerCommonAppCacheScan() {
        guard canReplaceScanContext else { return }
        resetSelectionState()
        selectedCategory = ScanCategory.batchCommonAppCacheID
        coordinator.scanCommonAppCaches()
    }

    private func triggerKnownVersionedScan() {
        guard canReplaceScanContext else { return }
        resetSelectionState()
        coordinator.scanKnownVersionedRoots(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// v1.0 T5：路径栏 —— 输 `/` 回车扫整盘；输任意已存在目录回车直接扫。
    ///
    /// v1.3 修复：原 `.textFieldStyle(.roundedBorder)` 在 `ToolbarItem(.principal)` 里聚焦时
    /// 蓝色 focus ring 会被 toolbar 容器裁切（截图证据）。改为 `.plain` + 自绘 Capsule 胶囊：
    /// - 平时：`Color.secondary.opacity(0.10)` 底 + 0.5pt 灰描边；
    /// - 聚焦：底色不变，描边换 `accentColor` 1.5pt，效果接近 Spotlight/Finder 搜索栏。
    /// Capsule 完全在 SwiftUI 视图层内，永远不会越过 toolbar 边界 → 不会被裁。
    private var pathBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(AppLocalization.string("pathbar.placeholder", locale: locale), text: $pathBarInput)
                .textFieldStyle(.plain)
                .focused($pathBarFocused)
                .onSubmit { submitPathBar() }
                .help(AppLocalization.string("pathbar.help", locale: locale))
                .controlGuideTarget(.pathInput)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 220, idealWidth: 320, maxWidth: 320)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    pathBarFocused ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: pathBarFocused ? 1.5 : 0.5
                )
        )
        .contentShape(Capsule(style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: pathBarFocused)
        .disabled(!canReplaceScanContext || hasConflictingMainModalPresentation)
    }

    /// v2026.10.11: keep the Stash entrance even when empty; count changes only update
    /// its badge. Removing the item hid a required action and destabilized native layout.
    private var stashToolbarButton: some View {
        Button {
            guard !hasConflictingMainModalPresentation else { return }
            isStashScreenPresented = true
        } label: {
            Label {
                Text("toolbar.stash.title", bundle: .module)
            } icon: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "tray.full.fill")
                    if stash.count > 0 {
                        stashCountBadge
                            .alignmentGuide(.top) { d in d[.top] + 2 }
                            .alignmentGuide(.trailing) { d in d[.trailing] - 2 }
                    }
                }
            }
        }
        .help(String(format: AppLocalization.string("toolbar.stash.help_with_count", locale: locale),
                     stash.count))
        .disabled(hasConflictingMainModalPresentation)
        .accessibilityIdentifier("main.stash")
        .controlGuideTarget(.stash)
    }

    /// 待处理数量徽标（红底白字胶囊），独立成 ViewBuilder 便于阅读 + 复用样式。
    /// 1~99 显示真实数；≥100 显示 `99+`，避免 toolbar 角标过宽。
    @ViewBuilder
    private var stashCountBadge: some View {
        let display = stash.count > 99 ? "99+" : "\(stash.count)"
        Text(display)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
            )
            .offset(x: 6, y: -4)
            .accessibilityHidden(true)
    }

    /// 现有的"停止 / 重新扫描"按钮，按当前状态二选一。
    @ViewBuilder
    private var scanControlButton: some View {
        if coordinator.hasActivePrimaryScanOwnership {
            Button(role: .cancel) {
                coordinator.cancel()
            } label: {
                Label {
                    Text("toolbar.scan.stop", bundle: .module)
                } icon: {
                    Image(systemName: "stop.circle")
                }
            }
                .help(AppLocalization.string("toolbar.help.stop", locale: locale))
        } else if let id = selectedCategory, let cat = allCategories.first(where: { $0.id == id }) {
            Button {
                startScan(category: cat)
            } label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .help(AppLocalization.string("toolbar.help.rescan", locale: locale))
        } else if selectedCategory == MainView.devVersionedSentinelID {
            // v2026.06.21：开发者旧版本扫描 sentinel 不在 allCategories 里，
            // 上面 `allCategories.first` 永远拿不到 cat，重新扫描按钮就没了
            // （用户截图反馈"那个常驻重新扫描按键哪里去了"）。这里专门走一支。
            Button {
                triggerKnownVersionedScan()
            } label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .help(AppLocalization.string("toolbar.help.rescan", locale: locale))
        } else if let id = selectedCategory, ScanCategory.batchScanIDs.contains(id) {
            // v2026.06.21：批量扫描 sentinel 也走 trigger* helper，
            // 之前 scanControlButton 仅在 allCategories.first(cat) 命中时才出现，
            // 这三个 sentinel 不在 allCategories 里 → 用户反馈"推荐扫描右上角没有重新扫描按键"。
            // 这里按 sentinel id 分发到 helper（helper 自己负责 resetSelectionState 与起扫）。
            Button {
                switch id {
                case ScanCategory.batchRecommendedID:
                    triggerRecommendedScan()
                case ScanCategory.batchDeveloperID:
                    triggerDeveloperScan()
                case ScanCategory.batchFullDiskID:
                    triggerFullDiskScan()
                case ScanCategory.batchCommonAppCacheID:
                    triggerCommonAppCacheScan()
                default:
                    assertionFailure("Unhandled batch scan sentinel id: \(id) — add case to MainView.scanControlButton switch.")
                }
            } label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
                .help(AppLocalization.string("toolbar.help.rescan", locale: locale))
        } else {
            Button {} label: {
                Label {
                    Text("toolbar.scan.rescan", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(true)
            .help(AppLocalization.string("toolbar.help.rescan", locale: locale))
        }
    }

    /// 路径栏回车：分两条路径
    /// 1. 输入 `/`（裸斜杠）→ 整盘扫描
    /// 2. 输入任意"已存在目录"绝对路径 → 加到 customCategories 并选中扫描
    private func submitPathBar() {
        guard interfaceMode == .professional, canReplaceScanContext,
              !hasConflictingMainModalPresentation else { return }
        let raw = pathBarInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // 整盘
        if raw == "/" {
            triggerFullDiskScan()
            pathBarInput = ""
            return
        }
        _ = submitDirectoryInput(.path(raw))
    }

    /// Path and drop share one request identity, off-main validation and atomic admission.
    /// A request cannot persist anything until its category transition actually commits.
    @discardableResult
    private func submitDirectoryInput(_ source: MainDirectoryInputSource) -> Bool {
        guard interfaceMode == .professional, canReplaceScanContext,
              !hasConflictingMainModalPresentation else { return false }
        let pathInput: String?
        if case .path(let raw) = source { pathInput = raw } else { pathInput = nil }
        guard let id = scanInputRequest.begin(in: scanContextIdentity, input: pathInput) else { return false }
        scanInputTask = Task { @MainActor in
            let validation: MainDirectoryInput.Validation
            var hadLoadFailure = false
            switch source {
            case .path(let raw):
                validation = await MainDirectoryInput.validate(.path(raw))
            case .drop(let providers):
                var urls: [URL] = []
                // Keep provider order: only the first valid folder starts a scan. The rest
                // are recorded by the same accepted commit, never by independent callbacks.
                for provider in providers {
                    guard !Task.isCancelled else { return }
                    do {
                        if let url = try await MainDirectoryInput.loadURL(from: provider) { urls.append(url) }
                    } catch {
                        hadLoadFailure = true
                        AmuxLog.error(.settings, "dropped directory URL loading failed: \(error.localizedDescription)")
                    }
                }
                validation = await MainDirectoryInput.validate(.urls(urls))
            }
            guard scanInputRequest.requestID == id else { return }
            scanInputTask = nil
            guard scanInputRequest.take(id, in: scanContextIdentity,
                input: pathBarInput.trimmingCharacters(in: .whitespacesAndNewlines),
                isAdmitted: !Task.isCancelled && isPresentationHostMounted
                    && interfaceMode == .professional && canReplaceScanContext
                    && !hasConflictingMainModalPresentation) else { return }
            guard let first = validation.directories.first else {
                if pathInput != nil, let url = validation.candidates.first {
                    deleteResult = String(format: AppLocalization.string("delete.result.path_invalid %@", locale: locale), url.path)
                } else if hadLoadFailure { customPathImportNotice = .failed }
                return
            }
            let category = ScanCategory.makeCustom(url: first)
            if requestCategorySwitch(to: category.id, fallbackCategory: category,
                                     customPaths: validation.directories), pathInput != nil {
                pathBarInput = ""
            }
        }
        return true
    }

    private func invalidateStaleScanInputRequest() {
        guard scanInputRequest.requestID != nil,
              !scanInputRequest.matches(scanContextIdentity,
                  input: pathBarInput.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        invalidateScanInputRequest()
    }

    private func invalidateScanInputRequest() {
        scanInputTask?.cancel()
        scanInputTask = nil
        scanInputRequest.invalidate()
    }

    /// 整盘扫描入口：统一从这里发起，方便后续接 TCC 引导。
    /// v1.5：与 triggerRecommendedScan / triggerDeveloperScan 对齐——sidebar 高亮
    /// 落在 batch.fulldisk sentinel 上（而不是单根 fullDisk.id 类目），让"批量扫描"
    /// 三条入口在视觉上是平等的一组。直接调 coordinator API，不再走 selectedCategory →
    /// onChange → startScan(category:) 的旧链路（避免高亮被绕回 fullDisk.id）。
    /// v1.5 review-fix #2：reset 由 helper 唯一负责（onChange 在 batch.* 分支不再 reset）。
    private func triggerFullDiskScan() {
        guard canReplaceScanContext else { return }
        resetSelectionState()
        selectedCategory = ScanCategory.batchFullDiskID
        coordinator.scanFullDisk(includeHidden: settings.showHidden)
    }

    // MARK: - Helpers

    /// v1.3：统一清空所有选中态（勾选 / 大文件 / 详情 / 树选中）。
    /// 三处入口（切类目 / 重新扫描 / triggerFullDiskScan）共享，
    /// 防止旧详情面板残留显示到新扫描结果上。
    private func resetSelectionState() {
        selection.removeAll()
        lastDefaultSelectedSeenCount = 0
        largeFilesBatch.clear()
        largeFileSelection = nil
        detail = nil
        treeSelection = nil
        refreshSelectedTreeRowDeletionEligibility()
        treeSelectionResetRevision &+= 1
    }

    /// 树选中行变化时更新可删状态：优先走进程内无 I/O 缓存字典命中（Tree 列表在后台构建
    /// projection 时已预热 VerdictCache）；极少数未命中时派发到后台 utility/userInitiated
    /// 计算，确保 footerBar 在 MainActor 渲染时零对象分配、零同步磁盘 I/O（PITFALLS §2.9）。
    private func refreshSelectedTreeRowDeletionEligibility() {
        treeSelectionEligibilityTask?.cancel()
        treeSelectionEligibilityTask = nil
        guard let row = treeSelection else {
            canDeleteSelectedTreeRow = false
            return
        }
        if let cached = TreeBrowserView.cachedCanInitiateDeletionIfPresent(
            row,
            cacheNamespace: coordinator.treeDeletionEvaluationCacheNamespace
        ) {
            canDeleteSelectedTreeRow = cached
            return
        }
        canDeleteSelectedTreeRow = false
        let expectedPath = row.path
        let snapshot = coordinator.treeDeletionEvaluationSnapshot
        treeSelectionEligibilityTask = Task.detached(priority: .userInitiated) {
            let eligible = TreeBrowserView.cachedCanInitiateDeletion(
                row,
                snapshot: snapshot
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.treeSelection?.path == expectedPath else { return }
                self.canDeleteSelectedTreeRow = eligible
            }
        }
    }

    /// v1.5 P2 / Q3：统一的"用户请求问 AI"入口。
    ///
    /// 行为：
    /// - AI 已就绪（`aiSettings.isReadyForUI`）→ 把 row 喂给 `aiAskingRow` 弹
    ///   [AIAdviceSheet](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
    /// - 未就绪 → 翻 `aiUnconfiguredAlert`，弹"前往设置？"alert，用户确认走 openSettings()
    ///
    /// 这是 Q3 修复的核心收敛点：所有 onAskAI callsite（List / Tree / Stash）
    /// 都走这里，避免散落判断 isReadyForUI 又散落 alert，将来语义有变只改一处。
    private func requestAI(row: RowItem) {
        guard !hasConflictingMainModalPresentation else { return }
        if aiSettings.isReadyForUI {
            aiAskingRow = row
        } else {
            aiUnconfiguredAlert = true
        }
    }

    /// v2026.06.22 perf：listResults 节流闸（扫描中冻结，立刻 during idle）。
    ///
    /// `force=true` 绕过冻结（onAppear / 扫描结束兜底用）。
    /// `force=false`：
    ///   - 不在扫描中（finished/idle）：立刻同步；
    ///   - 在扫描中：只允许空快照 → 第一帧非空快照，随后冻结到扫描结束；
    ///
    /// 只读 listResults 一处使用，不会影响 statusBar / TreeBrowserView /
    /// footerBar / sidebar 任一其他面（它们继续按 0.4s/帧 跟手）。
    private func syncThrottledListSnapshotIfNeeded(force: Bool) {
        // The predecessor snapshot is intentionally frozen while a replacement settles. Treating
        // `isScanning == false` as idle here would force a wide list/materialization pass exactly
        // when the user reported the rainbow cursor.
        if case .settling = coordinator.scanPhase { return }
        let latest = coordinator.snapshot
        // 切到新分类 / 重扫导致 rows 清空时：throttle 闸毫无意义，立刻同步
        let isEmptyReset = latest.rows.isEmpty
        if force || isEmptyReset || !coordinator.isScanning {
            throttledListSnapshot = latest
            return
        }
        // 扫描中冻结列表数据源：滚动稳定优先，进度由 statusBar 表达。
        let currentRows = throttledListSnapshot?.rows ?? []
        if currentRows.isEmpty, !latest.rows.isEmpty {
            throttledListSnapshot = latest
        }
    }

    private func applyDefaultSelectionForCurrentSnapshot() {
        let rows = coordinator.snapshot.rows
        var idx = lastDefaultSelectedSeenCount
        if idx > rows.count {
            idx = 0
            lastDefaultSelectedSeenCount = 0
        }
        while idx < rows.count {
            let r = rows[idx]
            if r.defaultSelected, !selection.contains(r.id) {
                selection.insert(r.id)
            }
            idx &+= 1
        }
        lastDefaultSelectedSeenCount = rows.count
    }

    private var selectedRows: [RowItem] {
        coordinator.snapshot.rows.filter {
            selection.contains($0.id)
                && DeletionEntryPolicy.canInitiate(
                    verdict: $0.verdict,
                    rejection: $0.rejection,
                    allowsVendorPathOverride: true
                )
        }
    }

    private var selectionSummary: String {
        let rows = selectedRows
        if rows.isEmpty { return AppLocalization.string("selection.empty", locale: locale) }
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        return String(format: AppLocalization.string("selection.summary %lld %@", locale: locale), rows.count, formattedBytes(total))
    }

    /// v1.3.zzzz：从 ScanCoordinator 拉一份"上层一票否决"路径快照。
    /// 合并 [permissionDeniedPaths](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L18)
    /// 与 [tccProtectedSkippedPaths](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L21)
    /// 及扫描器明确报告的 incomplete 路径。三类路径都缺少完整可删证据，不能交给
    /// NSWorkspace.recycle。
    private func accessDeniedPathsSnapshot() -> Set<String> {
        var s = Set<String>()
        s.formUnion(coordinator.permissionDeniedPaths)
        s.formUnion(coordinator.incompleteScanPaths)
        s.formUnion(coordinator.tccProtectedSkippedPaths)
        return s
    }

    private func formattedBytes(_ b: Int64) -> String {
        AppLocalization.byteCount(b, locale: locale)
    }

    /// v2026.06.18 把购物车里的 [StashEntry](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/StashStore.swift#L35-L51)
    /// 转成 [AIAdviceSheet](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
    /// 需要的 [RowItem](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L6-L60)。
    /// 因为 AIAdviceSheet 只读 title / url / bytes / verdict 等基础字段做请求拼装，
    /// 不需要 logicalBytes / vendor 等填值——这里全部走兜底常量 0/.nil 即可。
    /// `verdict` 现场调一次 [SafetyEngine.evaluate](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L212)
    /// 拿语义，让 AI sheet 也能看到本地三档闸的初判。
    private func makeAIQueryRow(from entry: StashStore.StashEntry) -> RowItem {
        let (verdict, rejection) = TreeBrowserView.safety.evaluate(path: entry.path)
        return RowItem(
            id: entry.path,
            url: URL(fileURLWithPath: entry.path),
            title: entry.title,
            isDirectory: entry.isDirectory,
            bytes: entry.bytes,
            logicalBytes: entry.bytes,
            fileCount: 0,
            verdict: verdict,
            rejection: rejection,
            titlePresentation: entry.titlePresentation
        )
    }

    /// **v2026.06.18**：把 TimeInterval 渲染成"1h 23m 04s / 5m 12s / 47s"等紧凑文案。
    /// 与 [FloatingScanHUD.durationString](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
    /// 风格保持一致——状态栏和悬浮窗看到的剩余时间口径同源，避免割裂。
    /// 负数 / NaN / +inf 一律按 0 处理（防呆，UI 永远不会出现 "-3s"）。
    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = max(1, Int(seconds.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    /// v2026.07.17 Common App Cache does not have a trustworthy byte denominator. Its scanner
    /// publishes completed forest groups and the exact current path instead; this view reports
    /// those facts and elapsed time without fabricating ETA or treating an indeterminate spinner
    /// as proof of liveness. A blocked group is ultimately terminated by the isolated worker.
    @ViewBuilder
    private func commonAppCacheGroupProgress(
        _ progress: CommonAppCacheScanner.Progress
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if progress.totalGroups > 0 {
                    ProgressView(
                        value: Double(progress.completedGroups),
                        total: Double(progress.totalGroups)
                    )
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
                    Text(AppLocalization.format(
                        "main.scan.progress.common_cache.groups %lld %lld",
                        locale: locale,
                        arguments: [Int64(progress.completedGroups), Int64(progress.totalGroups)]
                    ))
                } else {
                    Text("main.scan.progress.common_cache.resolving", bundle: .module)
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                if let currentPath = progress.currentPath {
                    Text(AppLocalization.format(
                        "main.scan.progress.common_cache.current %@",
                        locale: locale,
                        arguments: [currentPath]
                    ))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AppLocalization.format(
                        "main.scan.progress.elapsed",
                        locale: locale,
                        arguments: [formatDuration(coordinator.elapsedForDisplay(referenceDate: context.date))]
                    ))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    // 注：2026-05-25 移除原本拼接的 emoji，保留 SF Symbol + 文本，避免不同语言下 emoji 渲染不一致。
    private func verdictLabel(_ v: SafetyVerdict) -> String {
        switch v {
        case .safe: return AppLocalization.string("main.delete.safety.safe", locale: locale)
        case .confirm: return AppLocalization.string("main.delete.safety.confirm", locale: locale)
        case .forbid: return AppLocalization.string("main.delete.safety.forbid", locale: locale)
        }
    }

    /// v2026.06.17 (AUDIT A4)：专业模式与已确认 Stash 操作共用的
    /// pipeline 调用结果，callsite 自行处理 pruneDeleted / bytes 统计 / 关 sheet 等场景化逻辑。
    @MainActor
    private struct TrashRunResult {
        let moved: Int
        let skipped: Int
        let err: String?
        let pairs: [(String, String)]
        let outcome: TrashOutcome?
        let succeededPaths: [String]
    }

    /// Debug-only preview adapter.  It intentionally has no `dryRun` argument:
    /// every real confirmation must use `submitConfirmed`, whose typed return
    /// proves whether `NSWorkspace.recycle` was actually attempted.
#if DEBUG
    @MainActor
    private func runTrashPreview(
        paths: [String],
        source: String,
        accessDeniedPaths: Set<String>
    ) async -> TrashRunResult {
        let action = TrashActionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: undoHistoryStore
        )
        let result = await action.run(TrashActionCoordinator.Request(
            paths: paths,
            dryRun: true,
            source: source,
            accessDeniedPaths: accessDeniedPaths,
            mode: .normal
        ))
        let moved = result.moved
        let skipped = result.skipped
        let err = result.err
        let pairs = result.pairs
        return TrashRunResult(
            moved: moved,
            skipped: skipped,
            err: err,
            pairs: pairs,
            outcome: result.outcome,
            succeededPaths: result.succeededPaths
        )
    }
#endif

    /// 所有真实删除入口的统一状态提交。当前界面做精确 reconcile；非当前界面的扫描
    /// 已因磁盘变化而失去权威性，O(1) 失效并要求重扫，禁止对两份宽状态串行全量 prune。
    @MainActor
    private func synchronizeSuccessfulDeletion(
        paths: [String],
        authoritativeSurface: MainDeletionModelSurface,
        traceID: UUID? = nil
    ) async {
        guard !paths.isEmpty else { return }
        let plan = MainDeletionModelSynchronizationPolicy.plan(
            authoritativeSurface: authoritativeSurface
        )
        let trace = traceID.map { " trace_id=\($0.uuidString)" } ?? ""
        let exactStartedAt = ProcessInfo.processInfo.systemUptime
        AmuxLog.info(
            .trash,
            "deletion_model_sync stage=exact_start surface=\(plan.exactSurface.rawValue) item_count=\(paths.count)\(trace)"
        )
        switch plan.exactSurface {
        case .professional:
            await coordinator.pruneDeleted(paths: paths)
        case .smartCare:
            await smartCareSession.applySuccessfulDeletion(paths: paths)
        }
        AmuxLog.info(
            .trash,
            "deletion_model_sync stage=exact_complete surface=\(plan.exactSurface.rawValue) elapsed_ms=\(ProfessionalDeleteTiming.milliseconds(from: exactStartedAt, to: ProcessInfo.processInfo.systemUptime))\(trace)"
        )

        let invalidationStartedAt = ProcessInfo.processInfo.systemUptime
        switch plan.invalidatedSurface {
        case .professional:
            coordinator.cancel()
        case .smartCare:
            smartCareSession.invalidateAfterExternalDeletion()
        }
        AmuxLog.info(
            .trash,
            "deletion_model_sync stage=inactive_invalidated surface=\(plan.invalidatedSurface.rawValue) elapsed_ms=\(ProfessionalDeleteTiming.milliseconds(from: invalidationStartedAt, to: ProcessInfo.processInfo.systemUptime))\(trace)"
        )
        smartCareAIReviewSession.synchronizeSummaryRevision(
            smartCareSession.care.summaryRevision
        )
        coordinator.refreshVolumeCapacity()
    }

    /// v2026.10.10: preview success uses the same nonmodal acknowledgement as real
    /// cleanup, with an explicit preview descriptor; only errors open a diagnostic alert.
    @MainActor
    private func presentTrashPreviewOutcome(moved: Int,
                                            skipped: Int,
                                            failureSummary: TrashFailureSummary?,
                                            legacyError: String?) {
        let error = failureSummary?.message(locale: locale) ?? legacyError
        if let error {
            deleteSuccessFeedback = nil
            deleteResult = String(format: AppLocalization.string("delete.result.failure.dryrun %@ %lld %lld", locale: locale), error, moved, skipped)
        } else {
            deleteResult = nil
            deleteSuccessFeedback = .preview(id: UUID(), processedCount: moved, skippedCount: skipped)
        }
    }

    private func canExecuteProfessionalDelete(origin: DeleteRequestOrigin) -> Bool {
        if origin == .stash {
            switch coordinator.scanPhase {
            case .idle:
                return !coordinator.isScanning
            case .scanning, .settling:
                return false
            }
        }
        return coordinator.canUseCurrentScanResultsForActions
    }

    private func performProfessionalDelete(
        request: DeleteSheetRequest,
        executionPlan: ToolTrashExecutionPlan,
        timing: ProfessionalDeleteTiming
    ) async {
        guard !isDeleting else {
            AmuxLog.warning(
                .trash,
                "professional_delete stage=execution_rejected trace_id=\(timing.traceID.uuidString) reason=deletion_active"
            )
            return
        }
        let origin = request.preparedInteraction.plan.intent.origin
        guard canExecuteProfessionalDelete(origin: origin),
              coordinator.snapshot.categoryID == request.sourceCategoryID,
              coordinator.currentScanSessionID == request.scanSessionID,
              coordinator.storeRevision == request.preparedInteraction.plan.intent.snapshotIdentity.revision else {
            let now = ProcessInfo.processInfo.systemUptime
            let presentationDeferred = routeProfessionalDeletePresentation(
                .preflightNotice(DeletionPreflightNotice(
                    message: .scanChanged,
                    rejections: []
                ))
            )
            AmuxLog.notice(
                .trash,
                "professional_delete stage=execution_aborted trace_id=\(timing.traceID.uuidString) reason=scan_changed confirm_to_abort_ms=\(ProfessionalDeleteTiming.milliseconds(from: timing.confirmedAtUptime, to: now)) presentation_deferred=\(presentationDeferred)"
            )
            return
        }
        isDeleting = true
        defer { isDeleting = false }

        let interactionCoordinator = DeletionInteractionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: undoHistoryStore
        )
        let authorization: DeletionAuthorizedInteraction
        switch interactionCoordinator.authorize(
            prepared: request.preparedInteraction,
            executionPlan: executionPlan
        ) {
        case .authorized(let value):
            authorization = value
        case .cancelled:
            // 用户跳过了全部运行中项：未跨过 recycle 提交边界，不生成结果页。
            AmuxLog.info(
                .trash,
                "professional_delete stage=authorization_cancelled trace_id=\(timing.traceID.uuidString)"
            )
            return
        case .blocked(let block):
            let presentationDeferred = routeProfessionalDeletePresentation(
                .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
            )
            AmuxLog.notice(
                .trash,
                "professional_delete stage=authorization_blocked trace_id=\(timing.traceID.uuidString) rejection_count=\(block.rejections.count) presentation_deferred=\(presentationDeferred)"
            )
            return
        }

        let finalDeniedPaths = DeletionDeniedPathPolicy.final(
            frozen: request.accessDeniedPaths,
            current: accessDeniedPathsSnapshot()
        )
        let submitStartedAt = ProcessInfo.processInfo.systemUptime
        AmuxLog.info(
            .trash,
            "professional_delete stage=submit_start trace_id=\(timing.traceID.uuidString) confirm_to_submit_ms=\(ProfessionalDeleteTiming.milliseconds(from: timing.confirmedAtUptime, to: submitStartedAt)) item_count=\(timing.itemCount)"
        )
        let disposition = await interactionCoordinator.submit(
            authorization,
            accessDeniedPaths: finalDeniedPaths
        )
        let submitReturnedAt = ProcessInfo.processInfo.systemUptime
        let submitDuration = ProfessionalDeleteTiming.milliseconds(
            from: submitStartedAt,
            to: submitReturnedAt
        )
        switch disposition {
        case .requiresConfirmation(let prepared):
            // 最终重验发现新的专业风险时，回到同一张严格确认页；不伪装成执行失败。
            let presentationDeferred = routeProfessionalDeletePresentation(
                .confirmation(DeleteSheetRequest(
                    items: request.items,
                    accessDeniedPaths: finalDeniedPaths,
                    preparedInteraction: prepared
                ))
            )
            AmuxLog.notice(
                .trash,
                "professional_delete stage=submit_terminal trace_id=\(timing.traceID.uuidString) disposition=requires_confirmation submit_ms=\(submitDuration) presentation_deferred=\(presentationDeferred)"
            )
            return

        case .blocked(let block):
            let presentationDeferred = routeProfessionalDeletePresentation(
                .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
            )
            AmuxLog.notice(
                .trash,
                "professional_delete stage=submit_terminal trace_id=\(timing.traceID.uuidString) disposition=blocked submit_ms=\(submitDuration) rejection_count=\(block.rejections.count) presentation_deferred=\(presentationDeferred)"
            )
            return

        case .completed(let completed):
            let recycleCompletedAt = submitReturnedAt
            let result = completed.result
            AmuxLog.info(
                .trash,
                "professional_delete stage=recycle_completed trace_id=\(timing.traceID.uuidString) submit_ms=\(submitDuration) moved_count=\(result.moved) skipped_count=\(result.skipped)"
            )
            let submittedPaths = Set(completed.receipt.submittedPaths)
            let submittedRows = request.items.filter {
                submittedPaths.contains($0.url.path)
            }
            var modelSyncStartedAt = recycleCompletedAt
            var modelSyncCompletedAt = recycleCompletedAt
            await DeletionResultAcknowledgementOrdering.acknowledgeThenReconcile(
                makePayload: { OperationResultCompletion.deletion(completed) },
                present: { completion in
                    let resultEligibleAt = ProcessInfo.processInfo.systemUptime
                    let presentationDeferred = routeProfessionalDeletePresentation(
                        .result(completion)
                    )
                    AmuxLog.info(
                        .trash,
                        "professional_delete stage=result_eligible trace_id=\(timing.traceID.uuidString) recycle_to_result_eligible_ms=\(ProfessionalDeleteTiming.milliseconds(from: recycleCompletedAt, to: resultEligibleAt)) presentation_deferred=\(presentationDeferred) model_sync_pending=true"
                    )
                },
                reconcileModel: {
                    modelSyncStartedAt = ProcessInfo.processInfo.systemUptime
                    await applyProfessionalDeletionPresentation(
                        succeededPaths: result.succeededPaths,
                        expectedScanSessionID: request.scanSessionID
                    )
                    await applyProfessionalDeletionSuccess(
                        request: request,
                        rows: submittedRows,
                        succeededPaths: result.succeededPaths,
                        traceID: timing.traceID
                    )
                    modelSyncCompletedAt = ProcessInfo.processInfo.systemUptime
                }
            )
            AmuxLog.info(
                .trash,
                "professional_delete stage=model_sync_completed trace_id=\(timing.traceID.uuidString) recycle_to_model_sync_complete_ms=\(ProfessionalDeleteTiming.milliseconds(from: recycleCompletedAt, to: modelSyncCompletedAt)) model_sync_ms=\(ProfessionalDeleteTiming.milliseconds(from: modelSyncStartedAt, to: modelSyncCompletedAt)) result_already_eligible=true"
            )
        }
    }

    /// Receipt-backed visibility commit. The result is already eligible at this point; publish a
    /// narrow list/tree tombstone before admitting the expensive authoritative prune so moved
    /// items cannot remain actionable for another 10+ seconds.
    private func applyProfessionalDeletionPresentation(
        succeededPaths: [String],
        expectedScanSessionID: UUID
    ) async {
        guard !succeededPaths.isEmpty,
              coordinator.currentScanSessionID == expectedScanSessionID else { return }
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(
            paths: succeededPaths
        )
        guard coordinator.currentScanSessionID == expectedScanSessionID else { return }
        deletionPresentationRequestRevision &+= 1
        let requestRevision = deletionPresentationRequestRevision
        while requestRevision == deletionPresentationRequestRevision {
            guard coordinator.currentScanSessionID == expectedScanSessionID else { return }
            let source = throttledListSnapshot ?? coordinator.snapshot
            let frozenIdentity = currentDeletionPresentationSourceIdentity(source: source)
            let retirement = MainDeletionPresentationRetirement(snapshot: source)
            let projection = await MainDeletionPresentationExecutor.run(
                snapshot: source,
                succeededPaths: succeededPaths,
                selection: selection,
                listDetailPath: detail
            )
            await retirement.retain(projection.snapshot)
            let currentSource = throttledListSnapshot ?? coordinator.snapshot
            let currentIdentity = currentDeletionPresentationSourceIdentity(source: currentSource)
            let decision = MainDeletionPresentationCommitPolicy.decision(
                frozen: frozenIdentity,
                current: currentIdentity,
                requestRevisionMatches: requestRevision == deletionPresentationRequestRevision
            )
            switch decision {
            case .discard:
                scheduleMainDeletionPresentationRetirement(retirement)
                return
            case .retryLatestSource:
                // v2026.07.20: a same-session Tree/cache publication is not a reason to abandon
                // receipt visibility. Retire this attempt and recompute from the latest frozen
                // source; only an identity/page change may discard the request.
                scheduleMainDeletionPresentationRetirement(retirement)
                continue
            case .commit:
                throttledListSnapshot = projection.snapshot
                selection = projection.remainingSelection
                if projection.shouldCloseListDetail {
                    detail = nil
                }

                let matcher = DeletionPresentationPathMatcher(paths: succeededPaths)
                if let selected = treeSelection, matcher.contains(selected.path) {
                    treeSelection = nil
                    refreshSelectedTreeRowDeletionEligibility()
                }
                if let selected = largeFileSelection, matcher.contains(selected.path) {
                    largeFileSelection = nil
                }
                scheduleMainDeletionPresentationRetirement(retirement)
                return
            }
        }
    }

    private func scheduleMainDeletionPresentationRetirement(
        _ retirement: MainDeletionPresentationRetirement
    ) {
        // Do not await retirement from the publishing stack. The Task cannot run until this
        // MainActor turn yields/returns, so old/prepared wide arrays never lose their final owner
        // on the UI executor even on CAS retry/discard paths.
        Task { @MainActor in
            await Task.yield()
            await retirement.retire()
        }
    }

    private func currentDeletionPresentationSourceIdentity(
        source: ScanSnapshot
    ) -> MainDeletionPresentationSourceIdentity {
        MainDeletionPresentationSourceIdentity(
            scanSessionID: coordinator.currentScanSessionID,
            sourceRevision: coordinator.deletionPresentationSourceRevision,
            sourceCategoryID: source.categoryID,
            selectedCategoryID: selectedCategory,
            interfaceMode: interfaceMode.rawValue
        )
    }

    private func applyProfessionalDeletionSuccess(
        request: DeleteSheetRequest,
        rows: [RowItem],
        succeededPaths: [String],
        traceID: UUID
    ) async {
        guard !succeededPaths.isEmpty else { return }
        let accounting = await MainDeletionAccountingExecutor.run(
            rows: rows,
            succeededPaths: succeededPaths,
            selection: selection
        )
        await recorder.recordTrashed(paths: succeededPaths)
        let movedBytes = accounting.movedBytes
        if movedBytes > 0 {
            let categoryID = request.sourceCategoryID
            Task.detached { [movedBytes, categoryID] in
                await CleanStatsStore.shared.recordTrashed(
                    bytesTrashed: movedBytes,
                    category: categoryID.isEmpty ? "unknown" : categoryID
                )
            }
        }
        selection = accounting.remainingSelection
        largeFilesBatch.remove(paths: succeededPaths)
        let matcher = DeletionPresentationPathMatcher(paths: succeededPaths)
        if let selected = largeFileSelection,
           matcher.contains(selected.path) {
            largeFileSelection = nil
        }
        stash.remove(paths: succeededPaths)
        await synchronizeSuccessfulDeletion(
            paths: succeededPaths,
            authoritativeSurface: .professional,
            traceID: traceID
        )
        treeSelection = TreeSelectionReconciler.afterSuccessfulDeletion(
            selected: treeSelection,
            succeededPaths: succeededPaths,
            refreshedRow: { coordinator.refreshedTreeRow(for: $0) }
        )
        refreshSelectedTreeRowDeletionEligibility()
    }

    /// 专业模式真实文件删除的统一入口。所有页面先冻结相同的 RowItem + Safety
    /// 快照，再呈现同一张专业模式简单/严格确认页；普通硬 `.forbid` 在用户点击后立即解释，
    /// vendorPathRule 则明确转入专业模式严格确认，不会伪装成普通可删项。
    private func presentDeleteConfirmation(
        rows: [RowItem],
        origin: DeleteRequestOrigin,
        accessDeniedPaths suppliedDeniedPaths: Set<String>? = nil,
        incompleteIssues suppliedIncompleteIssues: [ScanIncompleteIssue]? = nil
    ) {
        guard canExecuteProfessionalDelete(origin: origin) else {
            // v2026.07.20: this is a zero-submission state, not an operation result. Keep the
            // page interactive while the current scan becomes action-authoritative.
            deletePreflightNotice = DeletionPreflightNotice(
                message: .scanInProgress,
                rejections: []
            )
            return
        }
        guard !rows.isEmpty,
              !isDeleting,
              !isPreparingDeletion,
              !deleteSubmissionHandoff.blocksNewSubmission,
              deleteSheetRequest == nil,
              deleteResultCompletion == nil,
              !hasOtherMainModalPresentation else { return }
        deletePreflightNotice = nil
        let deniedSnapshot = suppliedDeniedPaths ?? accessDeniedPathsSnapshot()
        let categoryID = coordinator.snapshot.categoryID
        let scanSessionID = coordinator.currentScanSessionID
        let targetPaths = rows.map(\.url.path)
        let currentIssues = coordinator.incompleteIssues(overlappingAny: targetPaths)
        let typedIncompleteIssues = suppliedIncompleteIssues.map {
            Array(Set($0 + currentIssues))
        } ?? currentIssues
        let snapshotIdentity = DeletionSnapshotIdentity(
            sessionID: scanSessionID,
            revision: coordinator.storeRevision,
            categoryID: categoryID
        )
        isPreparingDeletion = true
        Task { @MainActor in
            defer { isPreparingDeletion = false }
            let interactionCoordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
            let intent: DeletionIntent
            do {
                intent = try interactionCoordinator.makeIntent(
                    origin: origin,
                    mode: .professional,
                    snapshotIdentity: snapshotIdentity,
                    candidates: rows.map { row in
                        DeletionInteractionCandidateSnapshot(
                            path: row.url.path,
                            title: row.title,
                            isDirectory: row.isDirectory,
                            bytes: row.bytes,
                            fileCount: row.fileCount,
                            runningBundleIDPrefix: row.runningBundleIDPrefix,
                            accessEvidence: deletionAccessEvidence(
                                for: row.url.path,
                                issues: typedIncompleteIssues
                            ),
                            titlePresentation: row.titlePresentation
                        )
                    }
                )
            } catch {
                deletePreflightNotice = DeletionPreflightNotice(
                    rejections: targetPaths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                )
                return
            }

            let decision: DeletionInteractionPreparation
            if typedIncompleteIssues.isEmpty {
                decision = await interactionCoordinator.prepare(
                    intent: intent,
                    currentSnapshotIdentity: snapshotIdentity,
                    accessDeniedPaths: deniedSnapshot
                )
            } else {
                let targetPreparation = await pipeline.prepareScanIncompleteOverride(
                    rows: rows,
                    scanIssues: typedIncompleteIssues,
                    scanSessionID: scanSessionID
                )
                decision = interactionCoordinator.prepareRevalidatedScanIncomplete(
                    intent: intent,
                    currentSnapshotIdentity: snapshotIdentity,
                    preparation: targetPreparation
                )
            }
            guard canExecuteProfessionalDelete(origin: origin),
                  coordinator.snapshot.categoryID == categoryID,
                  coordinator.currentScanSessionID == scanSessionID,
                  coordinator.storeRevision == snapshotIdentity.revision else {
                deletePreflightNotice = DeletionPreflightNotice(
                    message: .scanChanged,
                    rejections: []
                )
                return
            }
            guard deleteSheetRequest == nil,
                  !deleteSubmissionHandoff.blocksNewSubmission,
                  deleteResultCompletion == nil,
                  !hasOtherMainModalPresentation else { return }
            switch decision {
            case .confirmation(let prepared):
                deleteSheetRequest = DeleteSheetRequest(
                    items: rows,
                    accessDeniedPaths: deniedSnapshot,
                    preparedInteraction: prepared
                )
            case .blocked(let block):
                deletePreflightNotice = DeletionPreflightNotice(rejections: block.rejections)
            case .cancelled:
                return
            }
        }
    }

    private func deletionAccessEvidence(
        for path: String,
        issues: [ScanIncompleteIssue]
    ) -> DeletionAccessEvidence {
        guard let issue = issues.first(where: { deletionPathsOverlap(path, $0.path) }) else {
            return .complete
        }
        return .incomplete(DeletionIncompleteReason(scanIncompleteReason: issue.reason))
    }

    private func deletionPathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = TrashPipeline.normalizePath(lhs)
        let right = TrashPipeline.normalizePath(rhs)
        if left == right { return true }
        if left == "/" || right == "/" { return true }
        return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// Tree 选中行转成删除确认快照。用户点击时必须直接冻结这份行数据；按需展开行
    /// 不保证存在于 coordinator 的全局 index，退化为 URL 再回查会丢失真实大小与类型。
    /// Safety/vendor 仍在意图创建时重新评估，执行前 TrashPipeline 还会最终重验。
    private func makeDeletionRow(_ treeRow: TreeRow) -> RowItem? {
        let evaluation = coordinator.deletionSafetyEvaluation(for: treeRow.path)
        return DeletionRowSnapshotFactory.tree(
            treeRow,
            verdict: evaluation.verdict,
            rejection: evaluation.rejection,
            vendorName: evaluation.vendor?.name,
            vendorNote: evaluation.vendor?.note,
            runningBundleIDPrefix: evaluation.vendor?.bundleIDPrefix
        )
    }

    /// Large Files 已经在扫描期冻结了大小与 mtime；这里只补齐相同的删除安全上下文，
    /// 不重新 stat/遍历文件系统，因此批量确认不会卡 UI。
    private func makeDeletionRow(_ item: LargeFileItem) -> RowItem {
        let evaluation = coordinator.deletionSafetyEvaluation(for: item.path)
        return RowItem(
            id: item.path,
            url: item.url,
            title: item.title,
            isDirectory: false,
            bytes: item.bytes,
            logicalBytes: item.logicalBytes,
            fileCount: 1,
            verdict: evaluation.verdict,
            rejection: evaluation.rejection,
            vendorName: evaluation.vendor?.name,
            vendorNote: evaluation.vendor?.note,
            runningBundleIDPrefix: evaluation.vendor?.bundleIDPrefix,
            modificationDate: item.modificationDate
        )
    }

    private func makeDeletionRow(_ entry: StashStore.StashEntry) -> RowItem {
        let evaluation = coordinator.deletionSafetyEvaluation(for: entry.path)
        return RowItem(
            id: entry.path,
            url: URL(fileURLWithPath: entry.path),
            title: entry.title,
            isDirectory: entry.isDirectory,
            bytes: entry.bytes,
            logicalBytes: entry.bytes,
            fileCount: entry.fileCount,
            verdict: evaluation.verdict,
            rejection: evaluation.rejection,
            vendorName: evaluation.vendor?.name,
            vendorNote: evaluation.vendor?.note,
            runningBundleIDPrefix: evaluation.vendor?.bundleIDPrefix,
            titlePresentation: entry.titlePresentation
        )
    }

    // MARK: - v1.0 T4 大文件辅助

    /// 统一扫描入口：根据类目 kind 决定是否传 largeFileMinBytes。
    /// 这一层抽象避免在 onChange / toolbar / settings.onChange 三处重复"判 kind 决定参数"。
    private func startScan(category: ScanCategory) {
        guard canReplaceScanContext else { return }
        resetSelectionState()
        // v1.3.zzzz Phase 2-F-B：开新一轮扫描前先清掉 pipeline 上的 accessDenied 旧快照。
        // ScanCoordinator 在 scan(...) 入口会重置 permissionDeniedPaths / tccProtectedSkippedPaths
        // （见 [ScanCoordinator.swift L356-L361 / L410-L412 / L509-L511]
        // (file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L356)），
        // 但 pipeline 是 MainView 实例字段，跨扫描复用——若不主动清空，旧 deniedPaths 会一直
        // 残留到下次 performDelete 重新注入前的窗口期，造成"本来已可写的路径被误以 accessDenied 拒"。
        // Phase 3-A 协议化后：v1.3.zzzz 路线 B 之后 pipeline 只有 TrashPipeline 一份实现，走真清空。
        pipeline.setAccessDeniedPaths([])
        if category.kind == .largeFiles {
            let minBytes = Int64(max(0, settings.minFileSizeMB)) * 1024 * 1024
            coordinator.scan(category: category,
                             includeHidden: settings.showHidden,
                             largeFileMinBytes: minBytes)
        } else {
            coordinator.scan(category: category, includeHidden: settings.showHidden)
        }
    }

    private func scheduleStashDeletion(_ entries: [StashStore.StashEntry]) {
        guard !entries.isEmpty, !isDeleting, stashSheetHandoff.schedule(.delete(entries)) else { return }
        isStashScreenPresented = false
    }

    private func finishStashSheetDismissal() {
        guard let action = stashSheetHandoff.takeAfterSheetDismissal() else { return }
        switch action {
        case .askAI(let row): requestAI(row: row)
        case .delete(let entries): presentStashDeletion(entries)
        }
    }

    private func presentStashDeletion(_ entries: [StashStore.StashEntry]) {
        let deniedSnapshot = entries.reduce(into: Set<String>()) { partial, entry in
            partial.formUnion(entry.accessDeniedPaths)
        }
        let incompleteSnapshot = Array(Set(entries.flatMap(\.incompleteIssues)))
        presentDeleteConfirmation(
            rows: entries.map(makeDeletionRow),
            origin: .stash,
            accessDeniedPaths: deniedSnapshot,
            incompleteIssues: incompleteSnapshot
        )
    }

    /// Stash 只能接收完整扫描结果。每条目录项同时冻结本轮扫描的 denied 证据，
    /// 稍后清理不会借用另一个 category 的权限快照。
    private func addToStash(
        path: String,
        title: String,
        bytes: Int64,
        isDirectory: Bool,
        fileCount: Int,
        titlePresentation: LocalizedTextDescriptor? = nil
    ) {
        guard coordinator.canUseCurrentScanResultsForActions else {
            deletePreflightNotice = DeletionPreflightNotice(
                message: .scanInProgress,
                rejections: []
            )
            return
        }
        stash.add(
            path: path,
            title: title,
            bytes: bytes,
            isDirectory: isDirectory,
            fileCount: fileCount,
            accessDeniedPaths: accessDeniedPathsSnapshot(),
            incompleteIssues: coordinator.incompleteIssues(overlappingAny: [path]),
            titlePresentation: titlePresentation
        )
    }

    // MARK: - 自定义路径（添加 / 删除 / 拖拽）

    /// 场景绑定的 SwiftUI 目录导入器回调。选择器由当前 MainView 自己呈现，
    /// 不再猜 `keyWindow/mainWindow/windows.first`，也绝不进入同步 `runModal()`。
    private func handleCustomPathImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                var duplicateCount = 0
                for url in urls {
                    if !(await pathStore.add(url)) {
                        duplicateCount &+= 1
                    }
                }
                if duplicateCount == urls.count {
                    customPathImportNotice = .duplicate(count: duplicateCount)
                }
            }
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            AmuxLog.error(.settings, "main directory importer failed: \(error.localizedDescription)")
            customPathImportNotice = .failed
        }
    }

    /// 侧边自定义路径行的 contextMenu「移除」。
    private func removeCustomPath(_ cat: ScanCategory) async {
        _ = await pathStore.remove(URL(fileURLWithPath: cat.rootPath))
    }

    /// onDrop 回调：从拖入的 NSItemProvider 解 fileURL，目录才入库。
    /// 见 PITFALLS §5.7：拖入文件不应被当作扫描根，避免对单文件做整盘扫描。
    ///
    /// v2026.06.23 行为升级：拖入文件夹后**自动加入自定义路径 + 立刻开始扫描**。
    /// - 若该路径已存在于 [UserPathStore](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/UserPathStore.swift)，
    ///   `add` 内部去重不会重复持久化；这里仍然会切到对应类目并触发扫描（"已存在就直接扫描"）。
    /// - 多文件夹同时拖入时，只对**第一个**有效目录开扫——
    ///   ScanCoordinator 同时只支持单个 active scan，多根并发会互相打架；
    ///   其余目录已写入 customCategories，用户可在侧栏自行点击逐个扫。
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard interfaceMode == .professional, canReplaceScanContext,
              !hasConflictingMainModalPresentation else { return false }
        let loadable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loadable.isEmpty else { return false }
        return submitDirectoryInput(.drop(loadable))
    }
}

private struct PermissionStatusBanner: View {
    @Environment(\.locale) private var locale
    /// 扫描器真实 open/readdir 失败的路径。显示前会再分成：
    /// - FDA/TCC 仍可由隐私授权解决；
    /// - FDA 已 granted 但 POSIX owner/mode 不允许当前用户进入。
    let fdaDeniedPaths: [String]
    /// TCC 雷区被主动 skip 的路径——根本没尝试 open，避免弹窗。
    let tccSkippedPaths: [String]
    /// 非 permission/TCC 的扫描完整性缺口，例如目录在扫描期间被移动、metadata
    /// 读取失败或枚举无法完整到 EOF。它们只表示结果受限，不等同 FDA。
    let otherIncompletePaths: [String]
    /// 当前进程的 FDA 探测状态。`.granted` 仍出现 denied 路径 = 多半是
    /// `~/.Trash` 之类**独立 TCC**项（不属于 FDA），需要单独引导用户。
    let fdaStatus: FDAProbe.Status
    let onOpenSettings: () -> Void
    /// v2026.06 #1：用户在 banner 上点「打开文件与文件夹访问设置」时跳的 URL。
    /// 与 FDA 是**两个独立类目**——开了 FDA 不会自动开它，必须各开各的。
    var onOpenFilesAndFolders: (() -> Void)? = nil
    /// v1.3：用户在 banner 上点「授权后扫描这些目录」——
    /// 跳系统设置 + 触发当前 category 重扫。MainView 在 onRescan 里串起来。
    /// 给 nil 视为兼容路径（按钮不显示），但本仓库目前 MainView 一定传非 nil。
    var onRescan: (() -> Void)? = nil
    @State private var expanded = false

    private var filesystemBlockedPaths: [String] {
        PermissionDenialClassifier.filesystemBlockedPaths(in: fdaDeniedPaths,
                                                          fdaStatus: fdaStatus)
    }

    private var privacyDeniedPaths: [String] {
        let blocked = Set(filesystemBlockedPaths)
        return fdaDeniedPaths.filter { !blocked.contains($0) }
    }

    private var fdaCount: Int { privacyDeniedPaths.count }
    private var tccCount: Int { tccSkippedPaths.count }
    private var filesystemCount: Int { filesystemBlockedPaths.count }
    private var incompleteCount: Int { otherIncompletePaths.count }
    private var totalLimitedCount: Int {
        Set(fdaDeniedPaths + tccSkippedPaths + otherIncompletePaths).count
    }

    private var headlineText: String {
        if incompleteCount > 0 {
            return String(
                format: AppLocalization.string("scan.limitations.title %lld", locale: locale),
                Int64(totalLimitedCount)
            )
        }
        let privacyCount = fdaCount + tccCount
        switch (privacyCount, filesystemCount) {
        case (0, 0):
            return ""
        case (0, let fs):
            return String(format: AppLocalization.string("permission.banner.filesystem_only %lld", locale: locale), fs)
        case (let p, let fs) where fs > 0:
            return String(format: AppLocalization.string("permission.banner.privacy_and_filesystem %lld %lld", locale: locale), p, fs)
        default:
            switch (fdaCount, tccCount) {
            case (let f, 0): return String(format: AppLocalization.string("permission.banner.fda_only %lld", locale: locale), f)
            case (0, let t): return String(format: AppLocalization.string("permission.banner.tcc_only %lld", locale: locale), t)
            case (let f, let t): return String(format: AppLocalization.string("permission.banner.fda_and_tcc %lld %lld", locale: locale), f, t)
            }
        }
    }

    private var iconName: String {
        if incompleteCount > 0 { return "exclamationmark.shield" }
        return fdaCount > 0 ? "lock.shield" : (filesystemCount > 0 ? "folder.badge.questionmark" : "hand.raised.circle")
    }

    private var tintColor: Color {
        if incompleteCount > 0 { return .orange }
        return fdaCount > 0 ? .orange : (filesystemCount > 0 ? .secondary : .blue)
    }

    /// 主行动按钮文案：FDA 受阻强调"打开权限"；纯 TCC 跳过强调"授权后重扫"。
    private var actionLabel: String {
        // v2026.06 用户反馈 #1：已开 FDA 但 denied 列表里全是 ~/Downloads / ~/Documents /
        // ~/Desktop 等"独立 TCC 类目"时，提示"打开 FDA"是错的——这些目录不归 FDA 管，
        // 用户开了 FDA 也不会解开。改为引导到 Files & Folders 类目。
        if needsFilesAndFolders {
            return AppLocalization.string("permission.banner.action.open_files_and_folders", locale: locale)
        }
        return fdaCount > 0
            ? AppLocalization.string("permission.banner.action.open_fda", locale: locale)
            : AppLocalization.string("permission.banner.action.open_and_rescan", locale: locale)
    }

    /// v2026.06 用户反馈 #1：判断"denied 列表是否需要 Files & Folders 类目"。
    ///
    /// macOS 14+ 把 Downloads / Documents / Desktop / Trash / 可移动卷 等抠出 FDA 范围，
    /// 单独走 [Files & Folders](https://support.apple.com/guide/security/sec29c19a25b/web)
    /// 类目（细粒度，逐 App 逐目录授权）。开关在
    /// 「系统设置 → 隐私与安全性 → 文件与文件夹」。
    ///
    /// 触发条件：
    /// - FDA 已 granted（或 unknown，"FDA 没开"那条路径更优先）；
    /// - denied 列表里至少有一条命中独立 TCC 类目的目录。
    private var needsFilesAndFolders: Bool {
        guard fdaStatus != .denied else { return false }
        return privacyDeniedPaths.contains(where: Self.isIndependentTCCCategory)
    }

    /// v2026.06 用户反馈 #1：判断一个路径是否属于"独立 TCC 类目"——
    /// 即开了 FDA **也**不会自动解开、必须单独授权的目录。
    /// 命中列表参考 Apple TCC 源码（`tccd` 的 `kTCCService*`）。
    static func isIndependentTCCCategory(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let hits = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/.Trash"
        ]
        for h in hits {
            if path == h || path.hasPrefix("\(h)/") { return true }
        }
        // 可移动卷 / 网络卷：单独 TCC 类目（kTCCServiceSystemPolicyRemovableVolumes /
        // NetworkVolumes），完全不在 FDA 范畴。
        if path.hasPrefix("/Volumes/") { return true }
        return false
    }

    /// v1.3.zz：检测"明明 FDA 已开却仍 denied"——多半 = 用户授权的是 .app，
    /// 但当前进程是 Debug build / 另一个路径的产物，或 automatic signing 选到的
    /// code requirement 与 TCC 记录不一致。
    /// 或者 = denied 路径里全是 ~/.Trash 之类**独立 TCC**项（不属于 FDA 范畴）。
    ///
    /// v2026.06 #1：新增 Files & Folders 提示——已开 FDA 但 denied 列表里有
    /// ~/Downloads / ~/Documents / ~/Desktop 这种"独立 TCC 类目"，必须单独授权。
    private var diagnosticHint: String? {
        if incompleteCount > 0 {
            return AppLocalization.string("scan.limitations.detail", locale: locale)
        }
        if fdaCount == 0, tccCount == 0, filesystemCount > 0 {
            return AppLocalization.string("permission.hint.filesystem_blocked", locale: locale)
        }
        if needsFilesAndFolders {
            return AppLocalization.string("permission.hint.files_and_folders", locale: locale)
        }
        let trashDenied = privacyDeniedPaths.contains { $0.hasSuffix("/.Trash") }
        if fdaStatus == .granted && trashDenied {
            return AppLocalization.string("permission.hint.trash_not_fda", locale: locale)
        }
        if fdaStatus == .denied && fdaCount > 0 {
            return AppLocalization.string("permission.hint.fda_denied", locale: locale)
        }
        if fdaStatus == .unknown && fdaCount > 0 {
            return AppLocalization.string("permission.hint.fda_unknown", locale: locale)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(tintColor)
                Text(headlineText)
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? LocalizedStringKey("mainview.path_chip.collapse")
                                  : LocalizedStringKey("mainview.path_chip.expand"),
                         bundle: .module)
                }
                    .buttonStyle(.plain)
                    .font(.caption)
                // v1.3：tcc-only 场景之前没有任何"主动授权"入口，
                // 现在两种场景都露出主行动按钮，文案因情境而异。
                if fdaCount > 0 || tccCount > 0 {
                    Button(actionLabel) {
                        if needsFilesAndFolders, let onOpenFilesAndFolders {
                            // v2026.06 #1：独立 TCC 类目 → 跳「文件与文件夹」面板，
                            // 与 FDA 是两个不同的开关，开了 FDA 也不会自动开它。
                            onOpenFilesAndFolders()
                        } else if let onRescan {
                            onRescan()
                        } else {
                            onOpenSettings()
                        }
                    }
                    .controlSize(.small)
                }
            }
            // v1.3.zz：诊断提示——比纯 banner 多一行解释，让用户在不展开"查看路径"
            // 的前提下也能直接看到"为什么明明授权了还提示"。
            if let hint = diagnosticHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if fdaCount > 0 {
                            Text(String(format: AppLocalization.string("banner.fda.denied.title", locale: locale), fdaCount)).font(.caption).foregroundStyle(.orange)
                            ForEach(privacyDeniedPaths.prefix(50), id: \.self) { p in
                                Text(verbatim: p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if fdaCount > 50 {
                                Text(String(format: AppLocalization.string("banner.fda.denied.more", locale: locale), fdaCount - 50)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if tccCount > 0 {
                            if fdaCount > 0 { Divider().padding(.vertical, 2) }
                            Text(String(format: AppLocalization.string("banner.fda.tcc.title", locale: locale), tccCount)).font(.caption).foregroundStyle(.blue)
                            ForEach(tccSkippedPaths.prefix(50), id: \.self) { p in
                                Text(verbatim: p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if tccCount > 50 {
                                Text(String(format: AppLocalization.string("banner.fda.tcc.more", locale: locale), tccCount - 50)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text("banner.fda.tcc.privacy_note", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        if filesystemCount > 0 {
                            if fdaCount > 0 || tccCount > 0 { Divider().padding(.vertical, 2) }
                            Text(String(format: AppLocalization.string("banner.filesystem.denied.title", locale: locale), filesystemCount)).font(.caption).foregroundStyle(.secondary)
                            ForEach(filesystemBlockedPaths.prefix(50), id: \.self) { p in
                                Text(verbatim: p).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if filesystemCount > 50 {
                                Text(String(format: AppLocalization.string("banner.filesystem.denied.more", locale: locale), filesystemCount - 50)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if incompleteCount > 0 {
                            if fdaCount > 0 || tccCount > 0 || filesystemCount > 0 {
                                Divider().padding(.vertical, 2)
                            }
                            Text(String(
                                format: AppLocalization.string("scan.limitations.other.title %lld", locale: locale),
                                Int64(incompleteCount)
                            ))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            ForEach(otherIncompletePaths.prefix(50), id: \.self) { path in
                                Text(verbatim: path)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if incompleteCount > 50 {
                                Text(String(
                                    format: AppLocalization.string("banner.filesystem.denied.more", locale: locale),
                                    incompleteCount - 50
                                ))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(10)
        .background(tintColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tintColor.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 真正根级失败的唯一主呈现。技术错误只进日志；主界面使用稳定本地化文案，
/// 避免 `cannotEnumerate(file:///...)`、errno 或 Swift enum 名泄漏给用户。
private struct ScanFailureBanner: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("scan.failure.title", bundle: .module)
                    .font(.callout.weight(.semibold))
                Text("scan.failure.detail", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onRetry) {
                Text("scan.failure.retry", bundle: .module)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct OptionalHelpModifier: ViewModifier {
    let helpText: String?

    func body(content: Content) -> some View {
        if let helpText {
            content.help(helpText)
        } else {
            content
        }
    }
}
