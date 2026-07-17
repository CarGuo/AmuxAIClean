import Combine
import Foundation

struct SmartCareSelectionMetrics: Sendable {
    let bytes: Int64
    let confirmCount: Int
    let bucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]
    let safeBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]
}

struct SmartCareSelectionProjection: Sendable {
    let selection: SmartCareSelection
    let metrics: SmartCareSelectionMetrics
}

typealias SmartCareSelectionProjectionBuilder = @Sendable (
    _ selection: SmartCareSelection,
    _ items: [SmartCareItem]
) throws -> SmartCareSelectionProjection

typealias SmartCareCleanRequestBuilder = @Sendable (
    _ selection: SmartCareSelection,
    _ items: [SmartCareItem]
) throws -> SmartCareCleanRequest

/// Smart Care 普通模式的状态编排层。
///
/// 这个类型不直接扫描磁盘、不执行删除；它只维护普通模式首页需要的
/// phase / summary / selection，并把当前 selection 转成清理请求。
/// v2026.07.16：用户可见状态统一由 Combine 发布；revision、builder 和请求令牌仍是内部状态，
/// 从而兼容 macOS 13.5 且不为非 UI 变化制造额外刷新。
@MainActor
public final class SmartCareCoordinator: ObservableObject {
    @Published public private(set) var phase: SmartCarePhase
    @Published public private(set) var summary: SmartCareSummary
    @Published public private(set) var selection: SmartCareSelection
    @Published public private(set) var selectedBytes: Int64
    @Published public private(set) var selectedConfirmCount: Int
    @Published public private(set) var selectedBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]
    @Published public private(set) var selectedSafeBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]
    /// 供跨 await 的后台重聚合检测读取后状态是否已变更。
    /// 摘要与选择分开计世代，避免单纯勾选导致删除摘要无意义重算。
    private(set) var summaryRevision: UInt64
    private(set) var selectionRevision: UInt64
    private let projectionBuilder: SmartCareSelectionProjectionBuilder
    private let cleanRequestBuilder: SmartCareCleanRequestBuilder
    private var bucketSelectionRequestRevision: [SmartCareBucketID: UInt64] = [:]

    public convenience init(summary: SmartCareSummary = .empty) {
        self.init(
            summary: summary,
            projectionBuilder: { selection, items in
                try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )
    }

    init(summary: SmartCareSummary,
         projectionBuilder: @escaping SmartCareSelectionProjectionBuilder,
         cleanRequestBuilder: @escaping SmartCareCleanRequestBuilder = {
             selection, items in
             try SmartCareCoordinator.cleanRequestCheckingCancellation(
                 selection: selection,
                 items: items
             )
         }) {
        self.phase = .idle
        self.summary = summary
        let selection = SmartCareSelection(items: summary.items)
        self.selection = selection
        let metrics = Self.selectionMetrics(selection: selection, items: summary.items)
        self.selectedBytes = metrics.bytes
        self.selectedConfirmCount = metrics.confirmCount
        self.selectedBucketStats = metrics.bucketStats
        self.selectedSafeBucketStats = metrics.safeBucketStats
        self.summaryRevision = 0
        self.selectionRevision = 0
        self.projectionBuilder = projectionBuilder
        self.cleanRequestBuilder = cleanRequestBuilder
        if !summary.items.isEmpty {
            self.phase = .reviewing(summary: summary)
        }
    }

    public var selectedItems: [SmartCareItem] {
        selection.selectedItems(in: summary.items)
    }

    public var hasSelection: Bool {
        !selection.selectedIDs.isEmpty
    }

    public func beginScan() {
        summary = .empty
        selection = SmartCareSelection()
        selectedBytes = 0
        selectedConfirmCount = 0
        selectedBucketStats = [:]
        selectedSafeBucketStats = [:]
        markSummaryAndSelectionChanged()
        phase = .scanning(progress: SmartCareProgress())
    }

    /// 取消后继续同一轮扫描。已完成阶段的 summary/selection 是 checkpoint，
    /// 不能像新扫描一样清空；否则“继续”会退化为从头开始。
    public func resumeScan(_ progress: SmartCareProgress) {
        phase = .scanning(progress: progress)
    }

    public func updateProgress(_ progress: SmartCareProgress) {
        phase = .scanning(progress: progress)
    }

    /// 每个完整阶段结束后原子发布摘要与进度。
    /// 取消发生时 `cancel()` 直接从这份 checkpoint 生成 partial，避免只保留局部变量。
    public func publishScanCheckpoint(_ newSummary: SmartCareSummary,
                                      progress: SmartCareProgress) {
        summary = newSummary
        selection.reconcile(with: newSummary.items)
        refreshSelectionMetrics()
        markSummaryAndSelectionChanged()
        phase = .scanning(progress: progress)
    }

    /// Smart Care 会话使用的 checkpoint 发布路径。公开同步契约保持不变；
    /// 只把 selection reconcile 和 metrics 全量遍历移到可取消的后台 worker。
    /// 若用户在 await 期间改变选择，按新世代重算，不会用旧 projection 覆盖。
    func publishScanCheckpointOffMainActor(_ newSummary: SmartCareSummary,
                                           progress: SmartCareProgress) async throws {
        while true {
            try Task.checkCancellation()
            let baseSelection = selection
            let baseSummaryRevision = summaryRevision
            let baseRevision = selectionRevision
            let projection = try await buildProjectionOffMainActor(
                selection: baseSelection,
                items: newSummary.items
            )
            try Task.checkCancellation()
            if commitScanCheckpoint(
                newSummary,
                progress: progress,
                projection: projection,
                expectedSummaryRevision: baseSummaryRevision,
                expectedSelectionRevision: baseRevision
            ) {
                return
            }
        }
    }

    func buildProjectionOffMainActor(selection: SmartCareSelection,
                                     items: [SmartCareItem]) async throws -> SmartCareSelectionProjection {
        let builder = projectionBuilder
        return try await SmartCareAggregationExecutor.run {
            try builder(selection, items)
        }
    }

    /// 真实删除已发生后，即使调用方 Task 取消也必须完成状态收敛。
    /// detached worker 不继承调用方取消，但仍把全量 reconcile/metrics 留在主线外。
    func buildDeletionProjectionOffMainActor(
        selection: SmartCareSelection,
        items: [SmartCareItem]
    ) async -> SmartCareSelectionProjection {
        let builder = projectionBuilder
        return await Task.detached(priority: .userInitiated) {
            do {
                return try builder(selection, items)
            } catch {
                preconditionFailure("Non-cancellable Smart Care deletion projection was cancelled")
            }
        }.value
    }

    @discardableResult
    func commitScanCheckpoint(
        _ newSummary: SmartCareSummary,
        progress: SmartCareProgress,
        projection: SmartCareSelectionProjection,
        expectedSummaryRevision: UInt64,
        expectedSelectionRevision: UInt64
    ) -> Bool {
        guard summaryRevision == expectedSummaryRevision,
              selectionRevision == expectedSelectionRevision else {
            return false
        }
        summary = newSummary
        apply(projection)
        markSummaryAndSelectionChanged()
        phase = .scanning(progress: progress)
        return true
    }

    public func finishScan(_ newSummary: SmartCareSummary) {
        summary = newSummary
        selection = SmartCareSelection(items: newSummary.items)
        refreshSelectionMetrics()
        markSummaryAndSelectionChanged()
        phase = .reviewing(summary: newSummary)
    }

    /// Session 的最终发布路径：保持 `finishScan` 的“新扫描重置默认选择”
    /// 契约，但不在 MainActor 上遍历整份结果。
    func finishScanOffMainActor(_ newSummary: SmartCareSummary) async throws {
        let projection = try await buildProjectionOffMainActor(
            selection: SmartCareSelection(),
            items: newSummary.items
        )
        try Task.checkCancellation()
        summary = newSummary
        apply(projection)
        markSummaryAndSelectionChanged()
        phase = .reviewing(summary: newSummary)
    }

    /// 最后一个阶段已原子发布 summary + 默认 selection projection 时，
    /// finish 只需切换 phase。revision 防止 await 边界后用旧 summary 收尾。
    @discardableResult
    func finishPublishedScan(expectedSummaryRevision: UInt64) -> Bool {
        guard summaryRevision == expectedSummaryRevision else { return false }
        phase = .reviewing(summary: summary)
        return true
    }

    public func replaceSummaryPreservingSelection(_ newSummary: SmartCareSummary) {
        summary = newSummary
        selection.reconcile(with: newSummary.items)
        refreshSelectionMetrics()
        markSummaryAndSelectionChanged()
        phase = .reviewing(summary: newSummary)
    }

    private func applyExternalPhase(for newSummary: SmartCareSummary) {
        switch phase {
        case .reviewing:
            phase = newSummary.items.isEmpty ? .idle : .reviewing(summary: newSummary)
        case .confirming:
            phase = newSummary.items.isEmpty ? .idle : .reviewing(summary: newSummary)
        case .cancelled:
            phase = .cancelled(partial: newSummary.items.isEmpty ? nil : newSummary)
        case .idle, .scanning, .cleaning, .completed, .failed:
            break
        }
    }

    /// 后台已完成 selection projection 时的 O(1) MainActor 提交。
    /// revision 是提交令牌：await 期间任一摘要/选择改变都会使旧结果失效。
    @discardableResult
    func commitExternalSummary(
        _ newSummary: SmartCareSummary,
        projection: SmartCareSelectionProjection,
        expectedSummaryRevision: UInt64,
        expectedSelectionRevision: UInt64
    ) -> Bool {
        guard summaryRevision == expectedSummaryRevision,
              selectionRevision == expectedSelectionRevision else {
            return false
        }
        summary = newSummary
        apply(projection)
        markSummaryAndSelectionChanged()
        applyExternalPhase(for: newSummary)
        return true
    }

    @discardableResult
    public func setSelected(_ selected: Bool, itemID: SmartCareItem.ID) -> Bool {
        guard let item = summary.items.first(where: { $0.id == itemID }) else {
            return false
        }
        return setSelected(selected, item: item)
    }

    @discardableResult
    public func setSelected(_ selected: Bool, item: SmartCareItem) -> Bool {
        guard summary.itemIDs.contains(item.id) else { return false }
        let wasSelected = selection.isSelected(item)
        let accepted = selection.setSelected(selected, item: item)
        guard accepted, wasSelected != selected else { return accepted }
        selectedBytes += selected ? item.bytes : -item.bytes
        if item.verdict == .confirm {
            selectedConfirmCount += selected ? 1 : -1
        }
        let currentStats = selectedBucketStats[item.bucketID] ?? SmartCareBucketSelectionStats()
        selectedBucketStats[item.bucketID] = SmartCareBucketSelectionStats(
            count: currentStats.count + (selected ? 1 : -1),
            bytes: currentStats.bytes + (selected ? item.bytes : -item.bytes)
        )
        if item.verdict == .safe {
            let currentSafeStats = selectedSafeBucketStats[item.bucketID]
                ?? SmartCareBucketSelectionStats()
            selectedSafeBucketStats[item.bucketID] = SmartCareBucketSelectionStats(
                count: currentSafeStats.count + (selected ? 1 : -1),
                bytes: currentSafeStats.bytes + (selected ? item.bytes : -item.bytes)
            )
        }
        selectionRevision &+= 1
        return true
    }

    public func setSafeItemsSelected(_ selected: Bool,
                                     bucketID: SmartCareBucketID) async {
        let requestRevision = (bucketSelectionRequestRevision[bucketID] ?? 0) &+ 1
        bucketSelectionRequestRevision[bucketID] = requestRevision

        while bucketSelectionRequestRevision[bucketID] == requestRevision {
            guard let bucket = summary.buckets.first(where: { $0.id == bucketID }),
                  !bucket.safeItemIDs.isEmpty else { return }
            let baseSummaryRevision = summaryRevision
            let baseSelectionRevision = selectionRevision
            let baseSelection = selection
            let items = summary.items
            let safeItemIDs = bucket.safeItemIDs
            let builder = projectionBuilder
            let projection: SmartCareSelectionProjection
            do {
                projection = try await SmartCareAggregationExecutor.run {
                    var revised = baseSelection
                    revised.setSafeItemIDsSelected(selected, safeIDs: safeItemIDs)
                    return try builder(revised, items)
                }
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected Smart Care bucket projection error: \(error)")
                return
            }

            // 快速连点时只允许最新命令提交；旧 worker 即使后返回也必须丢弃。
            guard bucketSelectionRequestRevision[bucketID] == requestRevision else { return }
            guard summaryRevision == baseSummaryRevision,
                  selectionRevision == baseSelectionRevision else {
                continue
            }
            // 不在 MainActor 上用 Set == 检查“是否真变化”：整桶 20k 项时
            // 这个看似无害的优化本身就是 O(n)。projection 的 storage 替换为 O(1)。
            apply(projection)
            selectionRevision &+= 1
            return
        }
    }

    /// 从当前选择生成不可变清理请求。20k+ 项的过滤、路径投影和统计全部在
    /// cancellable worker 完成；revision CAS 保证跨 await 期间若用户改了选择，
    /// 返回的一定是重算后的最新意图。
    public func makeCleanRequest() async throws -> SmartCareCleanRequest {
        while true {
            let baseSummaryRevision = summaryRevision
            let baseSelectionRevision = selectionRevision
            let baseSelection = selection
            let items = summary.items
            let builder = cleanRequestBuilder
            let request = try await SmartCareAggregationExecutor.run {
                try builder(baseSelection, items)
            }
            guard summaryRevision == baseSummaryRevision,
                  selectionRevision == baseSelectionRevision else {
                continue
            }
            return request.stamped(
                summaryRevision: baseSummaryRevision,
                selectionRevision: baseSelectionRevision
            )
        }
    }

    /// 用户点击主按钮后先进入这里。
    /// - 返回 `nil`：当前包含 confirm 项，需要 UI 先展示确认。
    /// - 返回 request：可以直接进入清理执行层。
    public func prepareClean() async throws -> SmartCareCleanRequest? {
        let request = try await makeCleanRequest()
        guard !request.items.isEmpty else { return nil }
        if request.requiresConfirmation {
            phase = .confirming(selection: selection)
            return nil
        }
        phase = .cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: request.items.count))
        return request
    }

    /// 确认只接受 sheet 实际展示过的不可变请求。选择或摘要在展示期间变化时
    /// revision 必须不匹配，由 UI 重建预览；绝不静默换成“当前最新选择”扩大删除集。
    public func confirmClean(_ request: SmartCareCleanRequest) -> Bool {
        guard !request.items.isEmpty,
              request.sourceSummaryRevision == summaryRevision,
              request.sourceSelectionRevision == selectionRevision else {
            return false
        }
        phase = .cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: request.items.count))
        return true
    }

    public func updateCleaningProgress(_ progress: SmartCareCleanProgress) {
        phase = .cleaning(progress: progress)
    }

    /// A confirmed request may still be rejected by the final safety check
    /// before `NSWorkspace.recycle` is called.  No cleanup result exists in
    /// that state, so restore the existing review instead of leaving the UI in
    /// an endless cleaning phase or manufacturing a failed operation.
    public func resumeReviewAfterUnsubmittedClean() {
        switch phase {
        case .confirming, .cleaning:
            phase = summary.items.isEmpty ? .idle : .reviewing(summary: summary)
        case .idle, .scanning, .reviewing, .completed, .failed, .cancelled:
            break
        }
    }

    public func completeCleaning(_ result: SmartCareResult) {
        phase = .completed(result: result)
    }

    /// 仍需在完成时替换 summary 的调用方必须走 async 路径：
    /// reconcile/metrics 在 detached worker 完成，MainActor 只提交 projection 和 phase。
    public func completeCleaning(_ result: SmartCareResult,
                                 remainingSummary: SmartCareSummary) async {
        while true {
            let baseSummaryRevision = summaryRevision
            let baseSelectionRevision = selectionRevision
            let baseSelection = selection
            let projection = await buildDeletionProjectionOffMainActor(
                selection: baseSelection,
                items: remainingSummary.items
            )
            guard commitExternalSummary(
                remainingSummary,
                projection: projection,
                expectedSummaryRevision: baseSummaryRevision,
                expectedSelectionRevision: baseSelectionRevision
            ) else { continue }
            phase = .completed(result: result)
            return
        }
    }

    public func fail(_ error: SmartCareError) {
        phase = .failed(error)
    }

    public func cancel(partial: SmartCareSummary? = nil) {
        if let partial, partial != summary {
            summary = partial
            selection.reconcile(with: partial.items)
            refreshSelectionMetrics()
            markSummaryAndSelectionChanged()
        }
        phase = .cancelled(partial: summary.items.isEmpty ? nil : summary)
    }

    public func reset() {
        summary = .empty
        selection = SmartCareSelection()
        selectedBytes = 0
        selectedConfirmCount = 0
        selectedBucketStats = [:]
        selectedSafeBucketStats = [:]
        markSummaryAndSelectionChanged()
        phase = .idle
    }

    private func refreshSelectionMetrics() {
        let metrics = Self.selectionMetrics(selection: selection, items: summary.items)
        selectedBytes = metrics.bytes
        selectedConfirmCount = metrics.confirmCount
        selectedBucketStats = metrics.bucketStats
        selectedSafeBucketStats = metrics.safeBucketStats
    }

    private func apply(_ projection: SmartCareSelectionProjection) {
        selection = projection.selection
        selectedBytes = projection.metrics.bytes
        selectedConfirmCount = projection.metrics.confirmCount
        selectedBucketStats = projection.metrics.bucketStats
        selectedSafeBucketStats = projection.metrics.safeBucketStats
    }

    private func markSummaryAndSelectionChanged() {
        summaryRevision &+= 1
        selectionRevision &+= 1
    }

    private nonisolated static func selectionMetrics(
        selection: SmartCareSelection,
        items: [SmartCareItem]
    ) -> SmartCareSelectionMetrics {
        guard let metrics = selectionMetrics(
            selection: selection,
            items: items,
            shouldCancel: { false }
        ) else {
            preconditionFailure("Non-cancellable Smart Care selection metrics were cancelled")
        }
        return metrics
    }

    nonisolated static func reconciledProjectionCheckingCancellation(
        selection: SmartCareSelection,
        items: [SmartCareItem]
    ) throws -> SmartCareSelectionProjection {
        var reconciled = selection
        try reconciled.reconcileCheckingCancellation(with: items)
        guard let metrics = selectionMetrics(
            selection: reconciled,
            items: items,
            shouldCancel: { Task.isCancelled }
        ) else {
            throw CancellationError()
        }
        return SmartCareSelectionProjection(selection: reconciled, metrics: metrics)
    }

    nonisolated static func cleanRequestCheckingCancellation(
        selection: SmartCareSelection,
        items: [SmartCareItem]
    ) throws -> SmartCareCleanRequest {
        var selectedItems: [SmartCareItem] = []
        selectedItems.reserveCapacity(min(items.count, selection.selectedIDs.count))
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: SmartCareAggregationCancellation.checkStride) {
                try Task.checkCancellation()
            }
            if selection.selectedIDs.contains(item.id), item.isSelectable {
                selectedItems.append(item)
            }
        }
        try Task.checkCancellation()
        return SmartCareCleanRequest(items: selectedItems)
    }

    private nonisolated static func selectionMetrics(
        selection: SmartCareSelection,
        items: [SmartCareItem],
        shouldCancel: () -> Bool
    ) -> SmartCareSelectionMetrics? {
        var bytes: Int64 = 0
        var confirmCount = 0
        var bucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats] = [:]
        var safeBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats] = [:]
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: SmartCareAggregationCancellation.checkStride),
               shouldCancel() {
                return nil
            }
            guard selection.selectedIDs.contains(item.id), item.isSelectable else { continue }
            bytes &+= item.bytes
            if item.verdict == .confirm { confirmCount &+= 1 }
            let currentStats = bucketStats[item.bucketID] ?? SmartCareBucketSelectionStats()
            bucketStats[item.bucketID] = SmartCareBucketSelectionStats(
                count: currentStats.count + 1,
                bytes: currentStats.bytes + item.bytes
            )
            if item.verdict == .safe {
                let currentSafeStats = safeBucketStats[item.bucketID]
                    ?? SmartCareBucketSelectionStats()
                safeBucketStats[item.bucketID] = SmartCareBucketSelectionStats(
                    count: currentSafeStats.count + 1,
                    bytes: currentSafeStats.bytes + item.bytes
                )
            }
        }
        guard !shouldCancel() else { return nil }
        return SmartCareSelectionMetrics(
            bytes: bytes,
            confirmCount: confirmCount,
            bucketStats: bucketStats,
            safeBucketStats: safeBucketStats
        )
    }
}
