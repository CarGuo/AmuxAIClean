import Foundation
import Observation

/// Smart Care 普通模式的状态编排层。
///
/// 这个类型不直接扫描磁盘、不执行删除；它只维护普通模式首页需要的
/// phase / summary / selection，并把当前 selection 转成清理请求。
@MainActor
@Observable
public final class SmartCareCoordinator {
    public private(set) var phase: SmartCarePhase
    public private(set) var summary: SmartCareSummary
    public private(set) var selection: SmartCareSelection
    public private(set) var selectedBytes: Int64
    public private(set) var selectedConfirmCount: Int
    public private(set) var selectedBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]
    public private(set) var selectedSafeBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]

    public init(summary: SmartCareSummary = .empty) {
        self.phase = .idle
        self.summary = summary
        let selection = SmartCareSelection(items: summary.items)
        self.selection = selection
        let metrics = Self.selectionMetrics(selection: selection, items: summary.items)
        self.selectedBytes = metrics.bytes
        self.selectedConfirmCount = metrics.confirmCount
        self.selectedBucketStats = metrics.bucketStats
        self.selectedSafeBucketStats = metrics.safeBucketStats
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
        phase = .scanning(progress: SmartCareProgress())
    }

    public func updateProgress(_ progress: SmartCareProgress) {
        phase = .scanning(progress: progress)
    }

    public func finishScan(_ newSummary: SmartCareSummary) {
        summary = newSummary
        selection = SmartCareSelection(items: newSummary.items)
        refreshSelectionMetrics()
        phase = .reviewing(summary: newSummary)
    }

    public func replaceSummaryPreservingSelection(_ newSummary: SmartCareSummary) {
        summary = newSummary
        selection.reconcile(with: newSummary.items)
        refreshSelectionMetrics()
        phase = .reviewing(summary: newSummary)
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
        return true
    }

    public func setSafeItemsSelected(_ selected: Bool, bucketID: SmartCareBucketID) {
        guard let bucket = summary.buckets.first(where: { $0.id == bucketID }) else { return }
        selection.setSafeItemIDsSelected(selected, safeIDs: bucket.safeItemIDs)
        refreshSelectionMetrics()
    }

    public func makeCleanRequest() -> SmartCareCleanRequest {
        SmartCareCleanRequest(items: selectedItems)
    }

    /// 用户点击主按钮后先进入这里。
    /// - 返回 `nil`：当前包含 confirm 项，需要 UI 先展示确认。
    /// - 返回 request：可以直接进入清理执行层。
    public func prepareClean() -> SmartCareCleanRequest? {
        let request = makeCleanRequest()
        guard !request.items.isEmpty else { return nil }
        if request.requiresConfirmation {
            phase = .confirming(selection: selection)
            return nil
        }
        phase = .cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: request.items.count))
        return request
    }

    public func confirmClean() -> SmartCareCleanRequest? {
        let request = makeCleanRequest()
        guard !request.items.isEmpty else { return nil }
        phase = .cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: request.items.count))
        return request
    }

    public func updateCleaningProgress(_ progress: SmartCareCleanProgress) {
        phase = .cleaning(progress: progress)
    }

    public func completeCleaning(_ result: SmartCareResult, remainingSummary: SmartCareSummary? = nil) {
        if let remainingSummary {
            summary = remainingSummary
            selection.reconcile(with: remainingSummary.items)
            refreshSelectionMetrics()
        }
        phase = .completed(result: result)
    }

    public func fail(_ error: SmartCareError) {
        phase = .failed(error)
    }

    public func cancel() {
        phase = .cancelled(partial: summary.items.isEmpty ? nil : summary)
    }

    public func reset() {
        summary = .empty
        selection = SmartCareSelection()
        selectedBytes = 0
        selectedConfirmCount = 0
        selectedBucketStats = [:]
        selectedSafeBucketStats = [:]
        phase = .idle
    }

    private func refreshSelectionMetrics() {
        let metrics = Self.selectionMetrics(selection: selection, items: summary.items)
        selectedBytes = metrics.bytes
        selectedConfirmCount = metrics.confirmCount
        selectedBucketStats = metrics.bucketStats
        selectedSafeBucketStats = metrics.safeBucketStats
    }

    private static func selectionMetrics(selection: SmartCareSelection,
                                         items: [SmartCareItem]) -> (
                                             bytes: Int64,
                                             confirmCount: Int,
                                             bucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats],
                                             safeBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats]
                                         ) {
        var bytes: Int64 = 0
        var confirmCount = 0
        var bucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats] = [:]
        var safeBucketStats: [SmartCareBucketID: SmartCareBucketSelectionStats] = [:]
        for item in items where selection.selectedIDs.contains(item.id) && item.isSelectable {
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
        return (bytes, confirmCount, bucketStats, safeBucketStats)
    }
}
