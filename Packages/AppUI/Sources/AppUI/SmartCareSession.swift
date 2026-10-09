import Combine
import Foundation
import LogKit
import ScanKit

/// 一轮 Smart Care 扫描的可恢复 checkpoint。
/// 只在完整阶段结束后提交，因此取消发生在阶段中间时，继续会重跑该阶段而不会重复已完成阶段。
struct SmartCareScanCheckpoint: Sendable {
    let plannedStages: [SmartCareScanStage]
    var candidates: [SmartCareCandidate] = []
    var completedBytes: Int64 = 0
    var completedFileCount: Int = 0
    var completedSummary: SmartCareSummary = .empty
    var completedStages: Set<SmartCareScanStage> = []
    var deniedPaths: Set<String> = []

    var remainingStages: [SmartCareScanStage] {
        plannedStages.filter { !completedStages.contains($0) }
    }

    mutating func record(stage: SmartCareScanStage,
                         snapshot: ScanSnapshot,
                         aggregation: SmartCareAggregationResult,
                         deniedPaths: Set<String>) {
        // 聚合 worker 已经生成新的规范化候选数组；这里仅替换 Array storage，
        // 不在 MainActor 上逐项复制或 append。
        candidates = aggregation.candidates
        completedBytes &+= snapshot.totalBytes
        completedFileCount &+= snapshot.scannedFileCount
        completedSummary = aggregation.summary
        completedStages.insert(stage)
        self.deniedPaths.formUnion(deniedPaths)
    }

    mutating func applyDeletion(_ aggregation: SmartCareAggregationResult) {
        let retainedIDs = aggregation.summary.itemIDs
        let removedItems = completedSummary.items.filter { !retainedIDs.contains($0.id) }
        let removedBytes = removedItems.reduce(Int64(0)) { $0 &+ $1.bytes }
        let removedFiles = removedItems.reduce(0) { $0 &+ max(0, $1.fileCount) }
        completedBytes = max(0, completedBytes - removedBytes)
        completedFileCount = max(0, completedFileCount - removedFiles)
        candidates = aggregation.candidates
        completedSummary = aggregation.summary
    }
}

typealias SmartCareCandidateDeletionAggregator = @Sendable (
    _ paths: [String],
    _ candidates: [SmartCareCandidate]
) async -> SmartCareAggregationResult

/// Keeps the invalidated Smart Care generation alive until its wide COW storage can be released
/// on the worker actor. Resetting an inactive mode must be O(1) on MainActor even after a large
/// developer scan left candidates, summary projections and selection sets behind.
private actor SmartCareInvalidatedStateRetirementWorker {
    private var checkpoint: SmartCareScanCheckpoint?
    private var summary: SmartCareSummary?
    private var selection: SmartCareSelection?
    private var deletionDeniedPaths: Set<String>?
    private var phase: SmartCarePhase?

    init(
        checkpoint: SmartCareScanCheckpoint?,
        summary: SmartCareSummary,
        selection: SmartCareSelection,
        deletionDeniedPaths: Set<String>,
        phase: SmartCarePhase
    ) {
        self.checkpoint = checkpoint
        self.summary = summary
        self.selection = selection
        self.deletionDeniedPaths = deletionDeniedPaths
        self.phase = phase
    }

    func retire() {
        checkpoint = nil
        summary = nil
        selection = nil
        deletionDeniedPaths = nil
        phase = nil
    }
}

/// Smart Care 对 ScanCoordinator 终态的解释必须区分两类事实：
/// - `isFinished && !isComplete`：扫描器已产生可用的部分结果，并给出了精确的
///   incomplete paths；这些路径会进入删除硬拒绝，但其它结果仍应继续展示。
/// - `!isFinished && !isScanning` 或完整终态携带真实错误：没有可信终态，才是 fatal。
///
/// 把这条合同抽成纯策略，避免 Session 再把“软失败证据”误升级成整轮失败。
enum SmartCareSnapshotTerminalDecision: Sendable, Equatable {
    case wait
    case accept(isComplete: Bool)
    case fail(SmartCareFailureDetail)

    static func fail(_ message: String) -> SmartCareSnapshotTerminalDecision {
        // v2026.07.16：测试/兼容入口不能把 scanner 原文变成产品文案。
        _ = message
        return .fail(.unexpectedFailure)
    }
}

enum SmartCareSnapshotCompletionPolicy {
    static func decision(
        snapshot: ScanSnapshot,
        isScanning: Bool,
        scanPhase: ScanCoordinator.ScanPhase,
        terminalFailure: ScanCoordinator.TerminalFailure?,
        hasDeletionDeniedEvidence: Bool,
        fallbackError: String?
    ) -> SmartCareSnapshotTerminalDecision {
        // v2026.07.19 settlement regression fix: a predecessor's finished snapshot deliberately
        // remains visible while ownership is handed to a replacement. It is not the new stage's
        // terminal result. Likewise, a terminal-looking frame published before the coordinator's
        // synchronous cleanup reaches `.idle` must not advance the Smart Care checkpoint.
        guard scanPhase == .idle, !isScanning else { return .wait }
        guard snapshot.isFinished else {
            return .fail(
                terminalFailure.map { _ in .unexpectedFailure }
                    ?? fallbackError.map { _ in SmartCareFailureDetail.unexpectedFailure }
                    ?? .scanIncomplete
            )
        }

        // Scanner 的显式 `.failed` 优先于 partial 外观；该阶段不得写入 completedStages，
        // 否则 Retry 会永久跳过真正失败的阶段。
        if let terminalFailure {
            _ = terminalFailure
            return .fail(.unexpectedFailure)
        }

        // Partial 只有在同时携带精确删除拒绝证据时才是可用终态。缺少证据意味着
        // producer 破坏了 fail-closed 合同，必须失败，不能把未知子树当可清理结果。
        guard snapshot.isComplete else {
            guard hasDeletionDeniedEvidence else {
                return .fail(
                    fallbackError.map { _ in SmartCareFailureDetail.unexpectedFailure }
                        ?? .scanIncomplete
                )
            }
            return .accept(isComplete: false)
        }

        if snapshot.rows.isEmpty, let fallbackError {
            _ = fallbackError
            return .fail(.unexpectedFailure)
        }
        return .accept(isComplete: true)
    }
}

private struct SmartCareScanCompletion: Sendable {
    let summary: SmartCareSummary
    let summaryRevision: UInt64
}

/// 普通模式的一键扫描会话。
///
/// 会话按顺序复用现有三个扫描入口，避免多个 `ScanCoordinator` 并发写同一份状态：
/// 推荐清理 -> 常见应用缓存 -> 开发缓存。每一段完成后只复制最终 rows，
/// 聚合与去重放到 detached task，主线程仅发布轻量进度和最终摘要。
/// v2026.07.16：会话自己的可见状态及 `care` 子对象变化统一转发给 Combine，兼容 macOS 13.5；
/// 扫描器、任务、checkpoint 与 revision 不作为发布状态。
@MainActor
public final class SmartCareSession: ObservableObject {
    public static let defaultSources: [SmartCareCandidateSource] = [
        .recommended,
        .commonAppCache,
        .developer
    ]
    /// v2026.07.20：普通模式默认只扫描常规范围。开发缓存仍保留在稳定展示/执行顺序中，
    /// 但必须由用户显式开启；不能再把“所有可用范围”与“默认选中范围”共用一个数组，
    /// 否则取消默认选中会连卡片和后续执行顺序一起删掉。
    public static let stageOrder = SmartCareScanStage.allCases
    public static let defaultStages: [SmartCareScanStage] = [.core, .appCaches]

    public let care: SmartCareCoordinator
    public let scanCoordinator: ScanCoordinator
    @Published public private(set) var selectedStages: Set<SmartCareScanStage>
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var finishedAt: Date?
    /// 本轮所有已启动阶段累计的 permissionDenied / TCC 路径。
    /// 删除请求必须使用它，而不是 Professional scanner 的状态。
    public private(set) var deletionDeniedPaths: Set<String> = []
    /// 由后台从 `deletionDeniedPaths` 生成的有界展示投影。View 不得重新排序完整集合。
    @Published private(set) var scanLimitationProjection: SmartCareScanLimitationProjection = .empty

    public var isBusy: Bool {
        switch care.phase {
        case .scanning, .cleaning:
            return true
        case .idle, .reviewing, .confirming, .completed, .failed, .cancelled:
            return false
        }
    }

    /// 当前 Smart Care 扫描会话的唯一标识。
    /// 注意：`applySuccessfulDeletion` 会通过 `scanCoordinator.cancel()` 释放底层 stage scanner 的大体积缓存，
    /// 因此删除确认门禁必须绑定 `SmartCareSession` 自身的会话世代，而非底层 ingestion `scanCoordinator`。
    public var currentScanSessionID: UUID {
        scanGeneration
    }

    /// 当前 Smart Care 摘要是否可用于发起清理或复核操作。
    public var canUseCurrentScanResultsForActions: Bool {
        guard scanTask == nil,
              scanCoordinator.scanPhase == .idle,
              !scanCoordinator.isScanning,
              !care.summary.items.isEmpty else {
            return false
        }
        switch care.phase {
        case .reviewing, .confirming, .completed, .failed(.cleanFailed):
            return true
        case .idle, .scanning, .cleaning, .cancelled, .failed(.scanFailed):
            return false
        }
    }

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var checkpoint: SmartCareScanCheckpoint?
    private var checkpointRevision: UInt64 = 0
    private var limitationProjectionGeneration = UUID()
    private let deletionAggregator: SmartCareCandidateDeletionAggregator
    private var careObservation: AnyCancellable?
    private var undoRestoreCancellable: AnyCancellable?

    public convenience init(care: SmartCareCoordinator = SmartCareCoordinator(),
                            scanCoordinator: ScanCoordinator = ScanCoordinator()) {
        self.init(
            care: care,
            scanCoordinator: scanCoordinator,
            checkpoint: nil,
            deletionAggregator: { paths, candidates in
                await Task.detached(priority: .userInitiated) {
                    SmartCareSummaryBuilder.removingCandidates(paths: paths, from: candidates)
                }.value
            }
        )
    }

    init(care: SmartCareCoordinator,
         scanCoordinator: ScanCoordinator,
         checkpoint: SmartCareScanCheckpoint?,
         deletionAggregator: @escaping SmartCareCandidateDeletionAggregator) {
        self.care = care
        self.scanCoordinator = scanCoordinator
        self.selectedStages = Set(Self.defaultStages)
        self.checkpoint = checkpoint
        self.deletionAggregator = deletionAggregator
        // Combine 不会自动沿引用链观察子对象；把固定 `care` 的变化转发给 session，
        // 保持 HUD 等只持有 session 的消费者与原 Observation 行为一致。
        self.careObservation = care.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.undoRestoreCancellable = NotificationCenter.default
            .publisher(for: .gsyUndoDidRestore)
            .sink { [weak self] notification in
                guard let paths = notification.userInfo?["paths"] as? [String],
                      !paths.isEmpty else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.handleUndoRestore() }
                } else {
                    Task { @MainActor [weak self] in self?.handleUndoRestore() }
                }
            }
    }

    private func handleUndoRestore() {
        if care.phase != .idle || checkpoint != nil || !care.summary.items.isEmpty {
            invalidateAfterExternalDeletion()
        }
        scanCoordinator.refreshVolumeCapacity()
    }

    public var orderedSelectedStages: [SmartCareScanStage] {
        Self.stageOrder.filter(selectedStages.contains)
    }

    public func setStage(_ stage: SmartCareScanStage, selected: Bool) {
        guard !isBusy else { return }
        if selected {
            selectedStages.insert(stage)
        } else {
            selectedStages.remove(stage)
        }
    }

    public func prepareForRescan() {
        guard !isBusy else { return }
        // v2026.07.20: "Scan Again" starts a fresh setup, not a repeat of the previous plan.
        // Restore the Normal defaults (developer cache off) and retire the prior wide developer
        // result away from MainActor so returning to the start page remains immediate.
        // The dedicated ScanCoordinator owns another wide snapshot/Tree/index generation; reset
        // it through its established cancellation/retirement transaction before hiding the result.
        scanCoordinator.cancel()
        resetPresentationForFreshSetup(resetSelectedStages: true)
    }

    /// v2026.07.19 deletion performance regression: a Professional cleanup must not run an exact
    /// O(N) prune over this hidden mode's previous developer scan. The disk changed outside Smart
    /// Care, so its old scan/checkpoint is no longer authoritative; invalidate it atomically and
    /// require a rescan when the user returns to Normal mode.
    public func invalidateAfterExternalDeletion() {
        let retirementWorker = SmartCareInvalidatedStateRetirementWorker(
            checkpoint: checkpoint,
            summary: care.summary,
            selection: care.selection,
            deletionDeniedPaths: deletionDeniedPaths,
            phase: care.phase
        )
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanCoordinator.cancel()
        resetPresentationForFreshSetup(
            resetSelectedStages: false,
            retirementWorker: retirementWorker
        )
    }

    private func resetPresentationForFreshSetup(
        resetSelectedStages: Bool,
        retirementWorker suppliedRetirementWorker: SmartCareInvalidatedStateRetirementWorker? = nil
    ) {
        let retirementWorker = suppliedRetirementWorker
            ?? SmartCareInvalidatedStateRetirementWorker(
                checkpoint: checkpoint,
                summary: care.summary,
                selection: care.selection,
                deletionDeniedPaths: deletionDeniedPaths,
                phase: care.phase
            )
        scanGeneration = UUID()
        startedAt = nil
        finishedAt = nil
        setCheckpoint(nil)
        deletionDeniedPaths = []
        resetScanLimitationProjection()
        care.reset()
        if resetSelectedStages {
            selectedStages = Set(Self.defaultStages)
        }

        Task { @MainActor in
            await Task.yield()
            await retirementWorker.retire()
        }
    }

    public func elapsedForDisplay(referenceDate: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? referenceDate).timeIntervalSince(startedAt))
    }

    public func startScan(includeHidden: Bool,
                          enabledDeveloperRuleIDs: Set<String>,
                          home: String = NSHomeDirectory()) {
        if case .cleaning = care.phase { return }
        let plannedStages = orderedSelectedStages
        guard !plannedStages.isEmpty else { return }
        cancelActiveWork()
        startedAt = Date()
        finishedAt = nil
        deletionDeniedPaths = []
        resetScanLimitationProjection()
        setCheckpoint(SmartCareScanCheckpoint(plannedStages: plannedStages))
        care.beginScan()

        launchScan(
            stagesToRun: plannedStages,
            includeHidden: includeHidden,
            enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
            home: home
        )
    }

    /// 从取消点继续同一轮扫描。完整阶段已经写入 checkpoint，只重跑尚未完成的阶段。
    public func continueScan(includeHidden: Bool,
                             enabledDeveloperRuleIDs: Set<String>,
                             home: String = NSHomeDirectory()) {
        guard case .cancelled = care.phase, let checkpoint else { return }
        let remainingStages = checkpoint.remainingStages
        guard !remainingStages.isEmpty else {
            cancelActiveWork()
            finishedAt = nil
            care.resumeScan(
                SmartCareProgress(
                    scannedBytes: checkpoint.completedBytes,
                    safeBytes: checkpoint.completedSummary.safeBytes,
                    scannedItemCount: checkpoint.completedFileCount,
                    activity: .finalizing,
                    completedStages: checkpoint.completedStages,
                    plannedStages: checkpoint.plannedStages,
                    bucketSafeBytes: Self.bucketSafeBytes(from: checkpoint.completedSummary)
                )
            )
            launchScan(
                stagesToRun: [],
                includeHidden: includeHidden,
                enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
                home: home
            )
            return
        }

        cancelActiveWork()
        finishedAt = nil
        care.resumeScan(progress(for: remainingStages[0], checkpoint: checkpoint))
        launchScan(
            stagesToRun: remainingStages,
            includeHidden: includeHidden,
            enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
            home: home
        )
    }

    /// 真正的扫描失败从最后一个完整 checkpoint 继续，不把已经完成的阶段和选择清空。
    /// Partial snapshot 不会进入这里；它会作为受限结果正常完成。
    public func retryFailedScan(includeHidden: Bool,
                                enabledDeveloperRuleIDs: Set<String>,
                                home: String = NSHomeDirectory()) {
        guard case .failed(.scanFailed(_)) = care.phase else { return }
        guard let checkpoint else {
            startScan(
                includeHidden: includeHidden,
                enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
                home: home
            )
            return
        }

        let remainingStages = checkpoint.remainingStages
        guard let nextStage = remainingStages.first else {
            startScan(
                includeHidden: includeHidden,
                enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
                home: home
            )
            return
        }

        cancelActiveWork()
        if startedAt == nil { startedAt = Date() }
        finishedAt = nil
        care.resumeScan(progress(for: nextStage, checkpoint: checkpoint))
        launchScan(
            stagesToRun: remainingStages,
            includeHidden: includeHidden,
            enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
            home: home
        )
    }

    private func launchScan(stagesToRun: [SmartCareScanStage],
                            includeHidden: Bool,
                            enabledDeveloperRuleIDs: Set<String>,
                            home: String) {
        let generation = UUID()
        scanGeneration = generation

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let completion = try await self.runScan(
                    using: self.scanCoordinator,
                    generation: generation,
                    stagesToRun: stagesToRun,
                    includeHidden: includeHidden,
                    enabledDeveloperRuleIDs: enabledDeveloperRuleIDs,
                    home: home
                )
                try Task.checkCancellation()
                guard self.scanGeneration == generation else { return }
                if stagesToRun.isEmpty {
                    // “已完成所有阶段后取消→继续”可能在 cancelled 页改过选择，
                    // 为保持 finishScan 的默认选择契约，只在这个罕见分支后台重投影。
                    try await self.care.finishScanOffMainActor(completion.summary)
                } else {
                    // 最后阶段已用默认 selection 生成完整 projection；
                    // 最终只切 phase，不第二次遍历 20k+ summary/metrics。
                    guard self.care.finishPublishedScan(
                        expectedSummaryRevision: completion.summaryRevision
                    ) else { throw CancellationError() }
                }
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
            } catch is CancellationError {
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
                self.captureCurrentDeniedPaths()
                // 完整阶段的 coordinator/checkpoint 是同一 MainActor 事务提交；
                // 直接使用已发布 summary，避免取消时再做一次 20k 结构比较/重投影。
                self.care.cancel()
            } catch let failure as SmartCareScanFailure {
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
                GSYLog.error(.scan, "Smart Care scan failed: \(failure.diagnosticDescription)")
                self.care.fail(.scanFailed(failure.detail))
            } catch {
                guard self.scanGeneration == generation else { return }
                self.finishedAt = Date()
                GSYLog.error(.scan, "Smart Care scan failed: \(error.localizedDescription)")
                self.care.fail(.scanFailed(.unexpectedFailure))
            }

            if self.scanGeneration == generation {
                self.scanTask = nil
            }
        }
    }

    public func cancelScan() {
        captureCurrentDeniedPaths()
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanCoordinator.cancel()
        finishedAt = Date()
        care.cancel()
    }

    /// 任一功能入口真正在废纸篓移动成功后，统一收敛 Smart Care 的 scanner、
    /// checkpoint 与可见摘要。若 Smart Care 正在扫描，先取消并保留完整阶段 checkpoint，
    /// 避免晚到事件把已经移走的路径重新发布。
    public func applySuccessfulDeletion(paths: [String]) async {
        guard !paths.isEmpty else { return }
        cancelActiveScanForDeletionIfNeeded()
        // The checkpoint + care summary are the Normal-mode authority. The stage scanner is only
        // an ingestion backing store and becomes stale after a filesystem mutation; rotating it
        // to empty is exact and O(1), while pruning its 10k+ Tree sort cache duplicated the summary
        // reconciliation and delayed the result sheet by 15–18 seconds in real-App traces.
        scanCoordinator.cancel()

        // MainActor 只提供状态读取/提交边界，CPU 重聚合在 worker 执行。
        // await 期间其它功能的删除或新扫描可以先提交；世代不一致时
        // 必须从最新 checkpoint/summary 重算，使每次成功删除的结果可线性化。
        while true {
            // prune/reconcile 的 await 窗口内用户可能点了“继续/重新扫描”。
            // 真删已发生，新 scan 不能继续发布含旧路径的结果；先取消，
            // 再以它已提交的最新 checkpoint 重算。
            cancelActiveScanForDeletionIfNeeded()
            let baseScanGeneration = scanGeneration
            let baseCheckpointRevision = checkpointRevision
            let baseSummaryRevision = care.summaryRevision
            let baseSelectionRevision = care.selectionRevision
            let baseSelection = care.selection

            if let current = checkpoint {
                let update = await deletionAggregator(paths, current.candidates)
                let revised = await Task.detached(priority: .userInitiated) {
                    var revised = current
                    revised.applyDeletion(update)
                    return revised
                }.value
                let projection = await care.buildDeletionProjectionOffMainActor(
                    selection: baseSelection,
                    items: update.summary.items
                )
                guard deletionTransactionIsCurrent(
                    scanGeneration: baseScanGeneration,
                    checkpointRevision: baseCheckpointRevision,
                    summaryRevision: baseSummaryRevision,
                    selectionRevision: baseSelectionRevision
                ) else {
                    continue
                }

                guard care.commitExternalSummary(
                    update.summary,
                    projection: projection,
                    expectedSummaryRevision: baseSummaryRevision,
                    expectedSelectionRevision: baseSelectionRevision
                ) else { continue }
                setCheckpoint(revised)
                break
            }

            let currentSummary = care.summary
            let revisedSummary = await Task.detached(priority: .userInitiated) {
                SmartCareSummaryBuilder.removing(paths: paths, from: currentSummary)
            }.value
            let projection = await care.buildDeletionProjectionOffMainActor(
                selection: baseSelection,
                items: revisedSummary.items
            )
            guard deletionTransactionIsCurrent(
                scanGeneration: baseScanGeneration,
                checkpointRevision: baseCheckpointRevision,
                summaryRevision: baseSummaryRevision,
                selectionRevision: baseSelectionRevision
            ) else {
                continue
            }
            guard care.commitExternalSummary(
                revisedSummary,
                projection: projection,
                expectedSummaryRevision: baseSummaryRevision,
                expectedSelectionRevision: baseSelectionRevision
            ) else { continue }
            break
        }
        scanCoordinator.refreshVolumeCapacity()
    }

    private func deletionTransactionIsCurrent(
        scanGeneration expectedScanGeneration: UUID,
        checkpointRevision expectedCheckpointRevision: UInt64,
        summaryRevision expectedSummaryRevision: UInt64,
        selectionRevision expectedSelectionRevision: UInt64
    ) -> Bool {
        guard scanGeneration == expectedScanGeneration,
              checkpointRevision == expectedCheckpointRevision,
              care.summaryRevision == expectedSummaryRevision,
              care.selectionRevision == expectedSelectionRevision else {
            cancelActiveScanForDeletionIfNeeded()
            return false
        }
        if case .scanning = care.phase {
            cancelScan()
            return false
        }
        return true
    }

    private func cancelActiveScanForDeletionIfNeeded() {
        guard case .scanning = care.phase else { return }
        cancelScan()
    }

    private func setCheckpoint(_ newCheckpoint: SmartCareScanCheckpoint?) {
        checkpoint = newCheckpoint
        checkpointRevision &+= 1
    }

    private func cancelActiveWork() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanCoordinator.cancel()
    }

    private func captureCurrentDeniedPaths() {
        var denied = Set(scanCoordinator.permissionDeniedPaths)
        denied.formUnion(scanCoordinator.incompleteScanPaths)
        denied.formUnion(scanCoordinator.tccProtectedSkippedPaths)
        recordDeniedPaths(denied)
    }

    /// deniedPaths 也是 checkpoint 事务的一部分，不允许绕过 revision
    /// 直接原地改数组。否则已经 await 的删除 worker 会将新 denied 集合覆盖。
    func recordDeniedPaths(_ denied: Set<String>) {
        guard !denied.isEmpty else { return }
        deletionDeniedPaths.formUnion(denied)
        guard var revised = checkpoint else { return }
        let missing = denied.subtracting(revised.deniedPaths)
        guard !missing.isEmpty else { return }
        revised.deniedPaths.formUnion(missing)
        setCheckpoint(revised)
        scheduleScanLimitationProjection(for: deletionDeniedPaths)
    }

    private func runScan(using scanCoordinator: ScanCoordinator,
                         generation: UUID,
                         stagesToRun: [SmartCareScanStage],
                         includeHidden: Bool,
                         enabledDeveloperRuleIDs: Set<String>,
                         home: String) async throws -> SmartCareScanCompletion {
        guard var checkpoint else { throw CancellationError() }
        var committedCheckpointRevision = checkpointRevision

        for stage in stagesToRun {
            try validateScanTransaction(
                generation: generation,
                checkpointRevision: committedCheckpointRevision
            )
            let snapshot = try await collectStage(
                using: scanCoordinator,
                expectedCategoryID: expectedCategoryID(for: stage),
                stage: stage,
                plannedStages: checkpoint.plannedStages,
                completedBytes: checkpoint.completedBytes,
                completedFileCount: checkpoint.completedFileCount,
                completedSummary: checkpoint.completedSummary,
                completedStages: checkpoint.completedStages
            ) {
                startStage(
                    stage,
                    using: scanCoordinator,
                    includeHidden: includeHidden,
                    enabledDeveloperRuleIDs: enabledDeveloperRuleIDs
                )
            }
            try validateScanTransaction(
                generation: generation,
                checkpointRevision: committedCheckpointRevision
            )

            // Array 传值只保留 storage；实际扩容、rows 转换、合并和排序全部发生在 detached worker。
            let existingCandidates = checkpoint.candidates
            let finalRows = snapshot.rows
            let source = source(for: stage)
            let aggregation = try await SmartCareAggregationExecutor.run {
                try SmartCareSummaryBuilder.aggregateCheckingCancellation(
                    existingCandidates: existingCandidates,
                    rows: finalRows,
                    source: source,
                    home: home
                )
            }
            try validateScanTransaction(
                generation: generation,
                checkpointRevision: committedCheckpointRevision
            )

            var denied = Set(scanCoordinator.permissionDeniedPaths)
            denied.formUnion(scanCoordinator.incompleteScanPaths)
            denied.formUnion(scanCoordinator.tccProtectedSkippedPaths)
            let projectedDeniedPaths = checkpoint.deniedPaths.union(denied)
            let limitationProjection = try await SmartCareAggregationExecutor.run {
                SmartCareScanLimitationProjection(paths: projectedDeniedPaths)
            }
            try validateScanTransaction(
                generation: generation,
                checkpointRevision: committedCheckpointRevision
            )
            checkpoint.record(
                stage: stage,
                snapshot: snapshot,
                aggregation: aggregation,
                deniedPaths: denied
            )
            let progress = progressAfterCompletedStage(checkpoint)
            while true {
                let baseSummaryRevision = care.summaryRevision
                let baseSelectionRevision = care.selectionRevision
                // 最后阶段直接生成 finishScan 需要的默认 selection projection，
                // 让后续 reviewing 相位提交只是 O(1)。
                let baseSelection = checkpoint.remainingStages.isEmpty
                    ? SmartCareSelection()
                    : care.selection
                let projection = try await care.buildProjectionOffMainActor(
                    selection: baseSelection,
                    items: aggregation.summary.items
                )
                try validateScanTransaction(
                    generation: generation,
                    checkpointRevision: committedCheckpointRevision
                )
                guard care.summaryRevision == baseSummaryRevision else {
                    throw CancellationError()
                }
                guard care.commitScanCheckpoint(
                    aggregation.summary,
                    progress: progress,
                    projection: projection,
                    expectedSummaryRevision: baseSummaryRevision,
                    expectedSelectionRevision: baseSelectionRevision
                ) else {
                    // 用户只在 projection await 期间改了勾选：保留新意图并重算。
                    // summary 变更则不属于同一扫描事务，上面已终止。
                    continue
                }
                // coordinator/checkpoint 均在 MainActor 上且中间无 await，
                // 对取消/外部删除是一个完整阶段提交。
                setCheckpoint(checkpoint)
                committedCheckpointRevision = checkpointRevision
                break
            }
            deletionDeniedPaths = checkpoint.deniedPaths
            commitScanLimitationProjection(limitationProjection)
        }

        try validateScanTransaction(
            generation: generation,
            checkpointRevision: committedCheckpointRevision
        )
        care.updateProgress(
            SmartCareProgress(
                scannedBytes: checkpoint.completedBytes,
                safeBytes: checkpoint.completedSummary.safeBytes,
                scannedItemCount: checkpoint.completedFileCount,
                activity: .finalizing,
                completedStages: checkpoint.completedStages,
                plannedStages: checkpoint.plannedStages,
                bucketSafeBytes: Self.bucketSafeBytes(from: checkpoint.completedSummary)
            )
        )
        return SmartCareScanCompletion(
            summary: checkpoint.completedSummary,
            summaryRevision: care.summaryRevision
        )
    }

    private func validateScanTransaction(generation expectedGeneration: UUID,
                                         checkpointRevision expectedRevision: UInt64) throws {
        try Task.checkCancellation()
        guard scanGeneration == expectedGeneration,
              checkpointRevision == expectedRevision else {
            throw CancellationError()
        }
    }

    private func collectStage(using scanCoordinator: ScanCoordinator,
                              expectedCategoryID: String,
                              stage: SmartCareScanStage,
                              plannedStages: [SmartCareScanStage],
                              completedBytes: Int64,
                              completedFileCount: Int,
                              completedSummary: SmartCareSummary,
                              completedStages: Set<SmartCareScanStage>,
                              start: () -> Void) async throws -> ScanSnapshot {
        care.updateProgress(
            SmartCareProgress(
                scannedBytes: completedBytes,
                safeBytes: completedSummary.safeBytes,
                scannedItemCount: completedFileCount,
                activity: .scanning(stage),
                completedStages: completedStages,
                plannedStages: plannedStages,
                bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
            )
        )
        start()

        let snapshot = try await waitForFinishedSnapshot(
            using: scanCoordinator,
            expectedCategoryID: expectedCategoryID,
            stage: stage,
            plannedStages: plannedStages,
            completedBytes: completedBytes,
            completedFileCount: completedFileCount,
            completedSummary: completedSummary,
            completedStages: completedStages
        )
        care.updateProgress(
            SmartCareProgress(
                scannedBytes: completedBytes + snapshot.totalBytes,
                safeBytes: completedSummary.safeBytes + snapshot.safeBytes,
                scannedItemCount: completedFileCount + snapshot.scannedFileCount,
                activity: .organizing(stage),
                completedStages: completedStages,
                plannedStages: plannedStages,
                bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
            )
        )
        return snapshot
    }

    private func waitForFinishedSnapshot(using scanCoordinator: ScanCoordinator,
                                         expectedCategoryID: String,
                                         stage: SmartCareScanStage,
                                         plannedStages: [SmartCareScanStage],
                                         completedBytes: Int64,
                                         completedFileCount: Int,
                                         completedSummary: SmartCareSummary,
                                         completedStages: Set<SmartCareScanStage>) async throws -> ScanSnapshot {
        // v2026.07.19 Smart Care terminal-settlement regression fix:
        // `snapshot`, `isScanning` and `scanPhase` are three separate @Published writes in one
        // MainActor terminal transaction. AsyncPublisher is not a lossless transaction log, so a
        // captured combineLatest tuple can remain at `(finished, false, .scanning)` after the
        // subsequent `.idle` emission was coalesced. Observe the authoritative payload only, then
        // read the two ownership fields live after the coordinator's actor turn has completed.
        // A predecessor frame is still rejected because its live phase remains `.settling`.
        let snapshotStream = scanCoordinator.$snapshot.values
        for await snapshot in snapshotStream {
            try Task.checkCancellation()
            guard snapshot.categoryID == expectedCategoryID else { continue }

            care.updateProgress(
                SmartCareProgress(
                    scannedBytes: completedBytes + snapshot.totalBytes,
                    safeBytes: completedSummary.safeBytes + snapshot.safeBytes,
                    scannedItemCount: completedFileCount + snapshot.scannedFileCount,
                    activity: .scanning(stage),
                    completedStages: completedStages,
                    plannedStages: plannedStages,
                    bucketSafeBytes: Self.bucketSafeBytes(from: completedSummary)
                )
            )

            switch SmartCareSnapshotCompletionPolicy.decision(
                snapshot: snapshot,
                isScanning: scanCoordinator.isScanning,
                scanPhase: scanCoordinator.scanPhase,
                terminalFailure: scanCoordinator.terminalFailure,
                hasDeletionDeniedEvidence: !scanCoordinator.permissionDeniedPaths.isEmpty
                    || !scanCoordinator.incompleteScanPaths.isEmpty
                    || !scanCoordinator.tccProtectedSkippedPaths.isEmpty,
                fallbackError: scanCoordinator.lastError
            ) {
            case .wait:
                continue
            case .accept(let isComplete):
                if !isComplete {
                    GSYLog.notice(
                        .scan,
                        "Smart Care accepts partial stage category=\(snapshot.categoryID) incompletePaths=\(scanCoordinator.incompleteScanPaths.count)"
                    )
                }
                return snapshot
            case .fail(let detail):
                throw SmartCareScanFailure.detail(detail)
            }
        }
        throw CancellationError()
    }

    private func source(for stage: SmartCareScanStage) -> SmartCareCandidateSource {
        switch stage {
        case .core: return .recommended
        case .appCaches: return .commonAppCache
        case .developerCaches: return .developer
        }
    }

    private func expectedCategoryID(for stage: SmartCareScanStage) -> String {
        switch stage {
        case .core: return ScanCoordinator.smartCareCoreCategoryID
        case .appCaches: return ScanCoordinator.commonAppCacheCategoryID
        case .developerCaches: return ScanCoordinator.developerCategoryID
        }
    }

    private func startStage(_ stage: SmartCareScanStage,
                            using scanCoordinator: ScanCoordinator,
                            includeHidden: Bool,
                            enabledDeveloperRuleIDs: Set<String>) {
        switch stage {
        case .core:
            scanCoordinator.scanSmartCareCore(includeHidden: includeHidden)
        case .appCaches:
            scanCoordinator.scanCommonAppCaches(includeConfirm: true)
        case .developerCaches:
            scanCoordinator.scanDeveloper(
                includeHidden: includeHidden,
                enabledRuleIDs: enabledDeveloperRuleIDs
            )
        }
    }

    private func progress(for nextStage: SmartCareScanStage,
                          checkpoint: SmartCareScanCheckpoint) -> SmartCareProgress {
        SmartCareProgress(
            scannedBytes: checkpoint.completedBytes,
            safeBytes: checkpoint.completedSummary.safeBytes,
            scannedItemCount: checkpoint.completedFileCount,
            activity: .scanning(nextStage),
            completedStages: checkpoint.completedStages,
            plannedStages: checkpoint.plannedStages,
            bucketSafeBytes: Self.bucketSafeBytes(from: checkpoint.completedSummary)
        )
    }

    private func progressAfterCompletedStage(_ checkpoint: SmartCareScanCheckpoint) -> SmartCareProgress {
        let remaining = checkpoint.remainingStages
        return SmartCareProgress(
            scannedBytes: checkpoint.completedBytes,
            safeBytes: checkpoint.completedSummary.safeBytes,
            scannedItemCount: checkpoint.completedFileCount,
            activity: remaining.first.map { .scanning($0) } ?? .finalizing,
            completedStages: checkpoint.completedStages,
            plannedStages: checkpoint.plannedStages,
            bucketSafeBytes: Self.bucketSafeBytes(from: checkpoint.completedSummary)
        )
    }

    private static func bucketSafeBytes(from summary: SmartCareSummary) -> [SmartCareBucketID: Int64] {
        Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.id, $0.safeBytes) })
    }

    private func resetScanLimitationProjection() {
        limitationProjectionGeneration = UUID()
        scanLimitationProjection = .empty
    }

    private func commitScanLimitationProjection(_ projection: SmartCareScanLimitationProjection) {
        limitationProjectionGeneration = UUID()
        scanLimitationProjection = projection
    }

    /// 取消边沿可能在最后一个阶段 checkpoint 之后补到新的 denied 证据。排序仍放后台，
    /// generation 只做 O(1) 提交校验，避免旧 worker 覆盖更新后的投影。
    private func scheduleScanLimitationProjection(for paths: Set<String>) {
        let generation = UUID()
        limitationProjectionGeneration = generation
        Task { @MainActor [weak self] in
            let projection = await Task.detached(priority: .userInitiated) {
                SmartCareScanLimitationProjection(paths: paths)
            }.value
            guard let self,
                  self.limitationProjectionGeneration == generation else { return }
            self.scanLimitationProjection = projection
        }
    }
}

/// 把同步 CPU 聚合绑定到调用它的父任务。
///
/// `Task.detached` 不会自动继承父任务取消，因此必须显式 cancel worker；worker
/// 即使与取消同时完成，返回前也会再次检查父任务状态，避免旧扫描结果越线发布。
enum SmartCareAggregationExecutor {
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            do {
                let value = try await worker.value
                try Task.checkCancellation()
                return value
            } catch {
                // 若 worker 错误与父取消竞态，父取消拥有优先语义。
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }
}

private enum SmartCareScanFailure: Error {
    case detail(SmartCareFailureDetail)

    var detail: SmartCareFailureDetail {
        switch self {
        case .detail(let detail): return detail
        }
    }

    var diagnosticDescription: String {
        switch detail {
        case .scanIncomplete: return "scanIncomplete"
        case .trash(let failure): return "trashFailure(\(failure.legacyDiagnostic))"
        case .unexpectedFailure: return "unexpectedFailure"
        case .verbatim(let message): return message
        }
    }
}
