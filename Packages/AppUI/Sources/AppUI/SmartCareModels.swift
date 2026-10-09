import Foundation
import SafetyKit

enum SmartCareAggregationCancellation {
    static let checkStride = 256
}

/// Smart Care 普通模式的分桶。普通模式只消费这些桶级摘要；
/// 具体路径、命中规则和专业操作仍留在专业模式视图里。
public enum SmartCareBucketID: String, CaseIterable, Sendable, Hashable, Codable {
    case systemJunk
    case appCache
    case developerCache
    case largeFiles
    case appLeftovers
    case duplicates
}

/// 主窗口的普通 / 专业显示模式。新安装和每次新建主窗口都默认普通模式。
public enum SmartCareInterfaceMode: String, CaseIterable, Sendable, Hashable, Identifiable {
    case normal
    case professional

    public var id: String { rawValue }
}

/// Smart Care 中可展示 / 可选择的最小条目。
public struct SmartCareItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let bucketID: SmartCareBucketID
    public let path: String
    public let title: String
    public let titlePresentation: LocalizedTextDescriptor
    public let bytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    public let verdict: SafetyVerdict
    public let riskNote: String?
    public let riskNotePresentation: LocalizedTextDescriptor?
    public let runningBundleIDPrefix: String?

    public init(id: String,
                bucketID: SmartCareBucketID,
                path: String,
                title: String,
                bytes: Int64,
                logicalBytes: Int64? = nil,
                fileCount: Int = 0,
                isDirectory: Bool = true,
                verdict: SafetyVerdict,
                riskNote: String? = nil,
                runningBundleIDPrefix: String? = nil,
                titlePresentation: LocalizedTextDescriptor? = nil,
                riskNotePresentation: LocalizedTextDescriptor? = nil) {
        self.id = id
        self.bucketID = bucketID
        self.path = path
        self.title = title
        self.titlePresentation = titlePresentation ?? .verbatim(title)
        self.bytes = bytes
        self.logicalBytes = logicalBytes ?? bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.verdict = verdict
        self.riskNote = riskNote
        self.riskNotePresentation = riskNotePresentation
            ?? riskNote.map(LocalizedTextDescriptor.verbatim)
        self.runningBundleIDPrefix = runningBundleIDPrefix
    }

    public func displayTitle(locale: Locale) -> String {
        titlePresentation.localized(locale: locale)
    }

    public func displayRiskNote(locale: Locale) -> String? {
        riskNotePresentation?.localized(locale: locale)
    }

    public var isSelectable: Bool {
        verdict != .forbid
    }

    public var isDefaultSelected: Bool {
        verdict == .safe
    }
}

public struct SmartCareBucketSummary: Identifiable, Sendable, Hashable {
    public let id: SmartCareBucketID
    public let items: [SmartCareItem]
    public let safeItems: [SmartCareItem]
    public let confirmItems: [SmartCareItem]
    public let forbidItems: [SmartCareItem]
    public let safeItemIDs: Set<SmartCareItem.ID>
    public let safeBytes: Int64
    public let confirmBytes: Int64
    public let forbidBytes: Int64
    public let totalBytes: Int64
    public let safeCount: Int
    public let confirmCount: Int
    public let forbidCount: Int

    public init(id: SmartCareBucketID, items: [SmartCareItem]) {
        guard let partition = Self.partition(items: items, shouldCancel: { false }) else {
            preconditionFailure("Non-cancellable Smart Care bucket partition was cancelled")
        }
        self.init(id: id, items: items, partition: partition)
    }

    static func make(
        id: SmartCareBucketID,
        items: [SmartCareItem],
        shouldCancel: () -> Bool
    ) -> SmartCareBucketSummary? {
        guard let partition = partition(items: items, shouldCancel: shouldCancel) else {
            return nil
        }
        return SmartCareBucketSummary(id: id, items: items, partition: partition)
    }

    private init(id: SmartCareBucketID, items: [SmartCareItem], partition: Partition) {
        self.id = id
        self.items = items
        self.safeItems = partition.safeItems
        self.confirmItems = partition.confirmItems
        self.forbidItems = partition.forbidItems
        self.safeItemIDs = partition.safeItemIDs
        self.safeBytes = partition.safeBytes
        self.confirmBytes = partition.confirmBytes
        self.forbidBytes = partition.forbidBytes
        self.totalBytes = partition.safeBytes + partition.confirmBytes + partition.forbidBytes
        self.safeCount = partition.safeCount
        self.confirmCount = partition.confirmCount
        self.forbidCount = partition.forbidCount
    }

    private static func partition(
        items: [SmartCareItem],
        shouldCancel: () -> Bool
    ) -> Partition? {
        var safeItems: [SmartCareItem] = []
        var confirmItems: [SmartCareItem] = []
        var forbidItems: [SmartCareItem] = []
        safeItems.reserveCapacity(items.count)
        confirmItems.reserveCapacity(items.count)
        forbidItems.reserveCapacity(items.count)
        var safeIDs: Set<SmartCareItem.ID> = []
        safeIDs.reserveCapacity(items.count)
        var safeBytes: Int64 = 0
        var confirmBytes: Int64 = 0
        var forbidBytes: Int64 = 0
        var safeCount = 0
        var confirmCount = 0
        var forbidCount = 0
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: SmartCareAggregationCancellation.checkStride),
               shouldCancel() {
                return nil
            }
            switch item.verdict {
            case .safe:
                safeItems.append(item)
                safeIDs.insert(item.id)
                safeBytes &+= item.bytes
                safeCount &+= 1
            case .confirm:
                confirmItems.append(item)
                confirmBytes &+= item.bytes
                confirmCount &+= 1
            case .forbid:
                forbidItems.append(item)
                forbidBytes &+= item.bytes
                forbidCount &+= 1
            }
        }
        guard !shouldCancel() else { return nil }
        return Partition(
            safeItems: safeItems,
            confirmItems: confirmItems,
            forbidItems: forbidItems,
            safeItemIDs: safeIDs,
            safeBytes: safeBytes,
            confirmBytes: confirmBytes,
            forbidBytes: forbidBytes,
            safeCount: safeCount,
            confirmCount: confirmCount,
            forbidCount: forbidCount
        )
    }

    private struct Partition {
        let safeItems: [SmartCareItem]
        let confirmItems: [SmartCareItem]
        let forbidItems: [SmartCareItem]
        let safeItemIDs: Set<SmartCareItem.ID>
        let safeBytes: Int64
        let confirmBytes: Int64
        let forbidBytes: Int64
        let safeCount: Int
        let confirmCount: Int
        let forbidCount: Int
    }
}

public struct SmartCareBucketSelectionStats: Sendable, Hashable {
    public let count: Int
    public let bytes: Int64

    public init(count: Int = 0, bytes: Int64 = 0) {
        self.count = count
        self.bytes = bytes
    }
}

public struct SmartCareSummary: Sendable, Hashable {
    public let buckets: [SmartCareBucketSummary]
    public let items: [SmartCareItem]
    public let safeItems: [SmartCareItem]
    public let confirmItems: [SmartCareItem]
    public let forbidItems: [SmartCareItem]
    public let itemIDs: Set<SmartCareItem.ID>
    public let safeBytes: Int64
    public let confirmBytes: Int64
    public let forbidBytes: Int64
    public let totalBytes: Int64
    public let forbiddenCount: Int

    public init(buckets: [SmartCareBucketSummary]) {
        guard let components = Self.components(buckets: buckets, shouldCancel: { false }) else {
            preconditionFailure("Non-cancellable Smart Care summary construction was cancelled")
        }
        self.init(buckets: buckets, components: components)
    }

    static func make(
        buckets: [SmartCareBucketSummary],
        shouldCancel: () -> Bool
    ) -> SmartCareSummary? {
        guard let components = components(buckets: buckets, shouldCancel: shouldCancel) else {
            return nil
        }
        return SmartCareSummary(buckets: buckets, components: components)
    }

    private init(buckets: [SmartCareBucketSummary], components: Components) {
        self.buckets = buckets
        self.items = components.items
        self.safeItems = components.safeItems
        self.confirmItems = components.confirmItems
        self.forbidItems = components.forbidItems
        self.itemIDs = components.itemIDs
        self.safeBytes = components.safeBytes
        self.confirmBytes = components.confirmBytes
        self.forbidBytes = components.forbidBytes
        self.totalBytes = components.totalBytes
        self.forbiddenCount = components.forbiddenCount
    }

    public static let empty = SmartCareSummary(buckets: [])

    private static func components(
        buckets: [SmartCareBucketSummary],
        shouldCancel: () -> Bool
    ) -> Components? {
        var itemCapacity = 0
        var safeCapacity = 0
        var confirmCapacity = 0
        var forbidCapacity = 0
        for bucket in buckets {
            itemCapacity += bucket.items.count
            safeCapacity += bucket.safeCount
            confirmCapacity += bucket.confirmCount
            forbidCapacity += bucket.forbidCount
        }

        var items: [SmartCareItem] = []
        var safeItems: [SmartCareItem] = []
        var confirmItems: [SmartCareItem] = []
        var forbidItems: [SmartCareItem] = []
        var itemIDs: Set<SmartCareItem.ID> = []
        items.reserveCapacity(itemCapacity)
        safeItems.reserveCapacity(safeCapacity)
        confirmItems.reserveCapacity(confirmCapacity)
        forbidItems.reserveCapacity(forbidCapacity)
        itemIDs.reserveCapacity(itemCapacity)

        var processed = 0
        for bucket in buckets {
            for item in bucket.items {
                if processed.isMultiple(of: SmartCareAggregationCancellation.checkStride),
                   shouldCancel() {
                    return nil
                }
                processed &+= 1
                items.append(item)
                itemIDs.insert(item.id)
                switch item.verdict {
                case .safe: safeItems.append(item)
                case .confirm: confirmItems.append(item)
                case .forbid: forbidItems.append(item)
                }
            }
        }

        guard let sortedConfirmItems = SmartCareCancellableAlgorithms.stableSorted(
            confirmItems,
            by: priorityOrder,
            shouldCancel: shouldCancel
        ), let sortedForbidItems = SmartCareCancellableAlgorithms.stableSorted(
            forbidItems,
            by: priorityOrder,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        guard !shouldCancel() else { return nil }
        return Components(
            items: items,
            safeItems: safeItems,
            confirmItems: sortedConfirmItems,
            forbidItems: sortedForbidItems,
            itemIDs: itemIDs,
            safeBytes: buckets.reduce(0) { $0 + $1.safeBytes },
            confirmBytes: buckets.reduce(0) { $0 + $1.confirmBytes },
            forbidBytes: buckets.reduce(0) { $0 + $1.forbidBytes },
            totalBytes: buckets.reduce(0) { $0 + $1.totalBytes },
            forbiddenCount: buckets.reduce(0) { $0 + $1.forbidCount }
        )
    }

    private struct Components {
        let items: [SmartCareItem]
        let safeItems: [SmartCareItem]
        let confirmItems: [SmartCareItem]
        let forbidItems: [SmartCareItem]
        let itemIDs: Set<SmartCareItem.ID>
        let safeBytes: Int64
        let confirmBytes: Int64
        let forbidBytes: Int64
        let totalBytes: Int64
        let forbiddenCount: Int
    }

    private static func priorityOrder(_ lhs: SmartCareItem, _ rhs: SmartCareItem) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.path < rhs.path
    }
}

/// 用户在普通模式里的选择意图。
///
/// 规则：
/// - safe 默认选中；
/// - confirm 默认不选中，但用户可以主动选中；
/// - forbid 永远不可选；
/// - 重新聚合时保留用户手动取消 / 勾选过的选择。
public struct SmartCareSelection: Sendable, Hashable {
    public private(set) var selectedIDs: Set<SmartCareItem.ID>
    public private(set) var userOverriddenIDs: Set<SmartCareItem.ID>

    public init(items: [SmartCareItem] = []) {
        self.selectedIDs = Set(items.filter(\.isDefaultSelected).map(\.id))
        self.userOverriddenIDs = []
    }

    public func isSelected(_ item: SmartCareItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    @discardableResult
    public mutating func setSelected(_ selected: Bool, item: SmartCareItem) -> Bool {
        guard item.isSelectable else {
            selectedIDs.remove(item.id)
            userOverriddenIDs.remove(item.id)
            return false
        }

        if selected {
            selectedIDs.insert(item.id)
        } else {
            selectedIDs.remove(item.id)
        }
        userOverriddenIDs.insert(item.id)
        return true
    }

    public mutating func reconcile(with items: [SmartCareItem]) {
        guard reconcile(items: items, shouldCancel: { false }) else {
            preconditionFailure("Non-cancellable Smart Care selection reconcile was cancelled")
        }
    }

    /// checkpoint 发布时的大集合版本。调用方应在后台 worker 内执行，
    /// 以便新一轮扫描取消时不必等待旧 selection 全量重建。
    mutating func reconcileCheckingCancellation(with items: [SmartCareItem]) throws {
        guard reconcile(items: items, shouldCancel: { Task.isCancelled }) else {
            throw CancellationError()
        }
    }

    private mutating func reconcile(items: [SmartCareItem],
                                    shouldCancel: () -> Bool) -> Bool {
        var currentIDs: Set<SmartCareItem.ID> = []
        currentIDs.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: SmartCareAggregationCancellation.checkStride),
               shouldCancel() {
                return false
            }
            currentIDs.insert(item.id)
        }

        guard !shouldCancel() else { return false }

        selectedIDs = selectedIDs.intersection(currentIDs)
        userOverriddenIDs = userOverriddenIDs.intersection(currentIDs)

        for (index, item) in items.enumerated() {
            if index.isMultiple(of: SmartCareAggregationCancellation.checkStride),
               shouldCancel() {
                return false
            }
            if !item.isSelectable {
                selectedIDs.remove(item.id)
                userOverriddenIDs.remove(item.id)
                continue
            }
            guard !userOverriddenIDs.contains(item.id) else { continue }
            if item.isDefaultSelected {
                selectedIDs.insert(item.id)
            } else {
                selectedIDs.remove(item.id)
            }
        }
        return !shouldCancel()
    }

    public mutating func setSafeItemIDsSelected(_ selected: Bool,
                                                safeIDs: Set<SmartCareItem.ID>) {
        guard !safeIDs.isEmpty else { return }
        if selected {
            selectedIDs.formUnion(safeIDs)
        } else {
            selectedIDs.subtract(safeIDs)
        }
        userOverriddenIDs.formUnion(safeIDs)
    }

    public func selectedItems(in items: [SmartCareItem]) -> [SmartCareItem] {
        items.filter { selectedIDs.contains($0.id) && $0.isSelectable }
    }

    public func selectedBytes(in items: [SmartCareItem]) -> Int64 {
        selectedItems(in: items).reduce(0) { $0 + $1.bytes }
    }

    public func selectedConfirmCount(in items: [SmartCareItem]) -> Int {
        selectedItems(in: items).filter { $0.verdict == .confirm }.count
    }
}

public enum SmartCareScanStage: String, CaseIterable, Sendable, Hashable {
    case core
    case appCaches
    case developerCaches

    public var bucketID: SmartCareBucketID {
        switch self {
        case .core: return .systemJunk
        case .appCaches: return .appCache
        case .developerCaches: return .developerCache
        }
    }

    public static func stage(for bucketID: SmartCareBucketID) -> SmartCareScanStage {
        switch bucketID {
        case .systemJunk, .largeFiles, .appLeftovers, .duplicates: return .core
        case .appCache: return .appCaches
        case .developerCache: return .developerCaches
        }
    }
}

public enum SmartCareScanActivity: Sendable, Hashable {
    case scanning(SmartCareScanStage)
    case organizing(SmartCareScanStage)
    case finalizing

    public var bucketID: SmartCareBucketID? {
        switch self {
        case .scanning(let stage), .organizing(let stage): return stage.bucketID
        case .finalizing: return nil
        }
    }

    public var stage: SmartCareScanStage? {
        switch self {
        case .scanning(let stage), .organizing(let stage): return stage
        case .finalizing: return nil
        }
    }
}

public struct SmartCareProgress: Sendable, Hashable {
    public let scannedBytes: Int64
    public let safeBytes: Int64
    public let scannedItemCount: Int
    public let activity: SmartCareScanActivity
    public let completedStages: Set<SmartCareScanStage>
    public let plannedStages: [SmartCareScanStage]
    public let bucketSafeBytes: [SmartCareBucketID: Int64]

    public var activeBucketID: SmartCareBucketID? { activity.bucketID }

    public init(scannedBytes: Int64 = 0,
                safeBytes: Int64 = 0,
                scannedItemCount: Int = 0,
                activeBucketID: SmartCareBucketID? = nil,
                activity: SmartCareScanActivity? = nil,
                completedStages: Set<SmartCareScanStage> = [],
                plannedStages: [SmartCareScanStage] = SmartCareScanStage.allCases,
                bucketSafeBytes: [SmartCareBucketID: Int64] = [:]) {
        self.scannedBytes = scannedBytes
        self.safeBytes = safeBytes
        self.scannedItemCount = scannedItemCount
        self.activity = activity
            ?? activeBucketID.map { .scanning(SmartCareScanStage.stage(for: $0)) }
            ?? .finalizing
        self.completedStages = completedStages
        self.plannedStages = plannedStages
        self.bucketSafeBytes = bucketSafeBytes
    }
}

public struct SmartCareCleanProgress: Sendable, Hashable {
    public let completedCount: Int
    public let totalCount: Int

    public init(completedCount: Int, totalCount: Int) {
        self.completedCount = completedCount
        self.totalCount = totalCount
    }
}

public enum SmartCareResultCompletion: Sendable, Hashable {
    case complete
    case partial
}

public struct SmartCareResult: Sendable, Hashable {
    public let movedCount: Int
    public let skippedCount: Int
    public let movedBytes: Int64
    public let releasedBytes: Int64

    public init(
        movedCount: Int,
        skippedCount: Int,
        movedBytes: Int64? = nil,
        releasedBytes: Int64 = 0
    ) {
        self.movedCount = movedCount
        self.skippedCount = skippedCount
        self.movedBytes = movedBytes ?? releasedBytes
        self.releasedBytes = releasedBytes
    }

    /// “完成”只表示删除事务已经结束；只要仍有跳过项，就不能向用户呈现为完整成功。
    public var completion: SmartCareResultCompletion {
        skippedCount > 0 ? .partial : .complete
    }
}

struct SmartCareDeletionAccounting: Sendable, Hashable {
    let succeededPaths: Set<String>
    let remainingProfessionalSelection: Set<String>
    let movedBytes: Int64
    let releasedBytes: Int64

    init(
        succeededPaths: Set<String>,
        remainingProfessionalSelection: Set<String>,
        movedBytes: Int64 = 0,
        releasedBytes: Int64 = 0
    ) {
        self.succeededPaths = succeededPaths
        self.remainingProfessionalSelection = remainingProfessionalSelection
        self.movedBytes = movedBytes
        self.releasedBytes = releasedBytes
    }
}

typealias SmartCareDeletionAccountingOperation = @Sendable (
    _ items: [SmartCareItem],
    _ succeededPaths: [String],
    _ professionalSelection: Set<String>
) -> SmartCareDeletionAccounting

/// 真删完成后的纯 CPU 统计 worker。成功路径建 Set、从 20k+ items
/// 累加已移入废纸篓容量、专业模式 selection subtract 都不在 MainActor 执行。
enum SmartCareDeletionAccountingExecutor {
    static func run(items: [SmartCareItem],
                    succeededPaths: [String],
                    professionalSelection: Set<String>) async -> SmartCareDeletionAccounting {
        await run(
            items: items,
            succeededPaths: succeededPaths,
            professionalSelection: professionalSelection,
            operation: compute
        )
    }

    static func run(items: [SmartCareItem],
                    succeededPaths: [String],
                    professionalSelection: Set<String>,
                    operation: @escaping SmartCareDeletionAccountingOperation) async
        -> SmartCareDeletionAccounting {
        await Task.detached(priority: .userInitiated) {
            operation(items, succeededPaths, professionalSelection)
        }.value
    }

    nonisolated static func compute(items: [SmartCareItem],
                                    succeededPaths: [String],
                                    professionalSelection: Set<String>)
        -> SmartCareDeletionAccounting {
        let succeeded = Set(succeededPaths)
        var movedBytes: Int64 = 0
        for item in items where succeeded.contains(item.path) {
            movedBytes &+= item.bytes
        }
        return SmartCareDeletionAccounting(
            succeededPaths: succeeded,
            remainingProfessionalSelection: professionalSelection.subtracting(succeeded),
            movedBytes: movedBytes,
            releasedBytes: 0
        )
    }
}

/// AI 只提供附加建议，不改写本地 SafetyVerdict，也不自动改变勾选状态。
public enum SmartCareAIItemState: Sendable, Hashable {
    case pending
    case reviewing
    case advice(SafetyVerdict, summary: String)
    case failed(SmartCareAIReviewFailure.Kind)
}

/// 扫描受限路径的不可变展示投影。构造包含去重/排序，必须在后台完成；SwiftUI
/// 只读取 `totalCount` 与已截断的稳定路径，不能在 body 热路径重排完整集合。
struct SmartCareScanLimitationProjection: Equatable, Sendable {
    static let defaultDisplayLimit = 20
    static let empty = SmartCareScanLimitationProjection(
        totalCount: 0,
        displayedPaths: []
    )

    let totalCount: Int
    let displayedPaths: [String]

    init(paths: Set<String>, displayLimit: Int = defaultDisplayLimit) {
        let sortedPaths = paths.sorted()
        let boundedLimit = max(0, displayLimit)
        totalCount = sortedPaths.count
        displayedPaths = Array(sortedPaths.prefix(boundedLimit))
    }

    private init(totalCount: Int, displayedPaths: [String]) {
        self.totalCount = totalCount
        self.displayedPaths = displayedPaths
    }

    var remainingCount: Int {
        max(0, totalCount - displayedPaths.count)
    }

    var isEmpty: Bool { totalCount == 0 }
}

/// v2026.07.15：Smart Care 终态只保存错误语义。产品错误在 Dashboard 渲染时按
/// 当前 App locale 投影，运行中切换语言不会留下启动语言快照。
public enum SmartCareFailureDetail: Sendable, Hashable {
    case scanIncomplete
    case trash(TrashFailureSummary)
    /// v2026.07.16：未知 scanner/FileManager 错误的用户安全投影。原始 Error 只进日志；
    /// UI 不暴露 errno、枚举名、percent encoding 或未本地化的系统字符串。
    case unexpectedFailure
    /// 仅供产品已经验证为用户文案的兼容调用；禁止传入 raw Error。
    case verbatim(String)

    public func text(locale: Locale) -> String {
        switch self {
        case .scanIncomplete:
            return AppLocalization.string("main.scan.incomplete", locale: locale)
        case .trash(let failure):
            return failure.message(locale: locale)
        case .unexpectedFailure:
            return AppLocalization.string("smart_care.failure.unexpected", locale: locale)
        case .verbatim(let message):
            return message
        }
    }
}

public enum SmartCareError: Sendable, Hashable {
    case scanFailed(SmartCareFailureDetail)
    case cleanFailed(SmartCareFailureDetail)

    /// v2026.07.16：String overload 仅保留源码兼容，不再把任意字符串带到 UI。
    /// 生产调用方应先把原始错误写日志，再使用类型化 detail。
    public static func scanFailed(_ message: String) -> SmartCareError {
        _ = message
        return .scanFailed(.unexpectedFailure)
    }

    public static func cleanFailed(_ message: String) -> SmartCareError {
        _ = message
        return .cleanFailed(.unexpectedFailure)
    }

    var recovery: SmartCareFailureRecovery {
        switch self {
        case .scanFailed:
            return .retryScan
        case .cleanFailed:
            return .reviewCleanup
        }
    }
}

enum SmartCareFailureRecovery: Sendable, Hashable {
    /// 从最后一个完整扫描 checkpoint 重试失败阶段，不清空已完成结果。
    case retryScan
    /// 清理失败时回到同一份选择的清理预览，不把它错误地变成一次全量重扫。
    case reviewCleanup
}

public enum SmartCarePrimaryAction: Sendable, Hashable {
    case startScan
    case stopScan
    case cleanSafeItems
    case confirmClean
    case cleaning
    case scanAgain
    case retry
    case continueScan
}

public struct SmartCareCleanRequest: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let items: [SmartCareItem]
    public let requiresConfirmation: Bool
    public let paths: [String]
    public let totalBytes: Int64
    public let confirmCount: Int
    public let previewRows: [RowItem]
    let sourceSummaryRevision: UInt64?
    let sourceSelectionRevision: UInt64?
    /// v2026.07.16: frozen by MainView when the preview becomes presentable. SmartCare's model
    /// owns the revisions while its ScanCoordinator owns the scan session, so the request binds
    /// both before the sheet is shown and carries them unchanged through dismissal.
    let sourceDeletionSnapshotIdentity: DeletionSnapshotIdentity?
    /// v2026.09.06 SR-01: frozen before the detailed cleanup sheet; a matching summary revision
    /// must never authorize a replacement object at one of these paths.
    let reviewedObjects: ReviewedDeletionObjects?

    public init(items: [SmartCareItem]) {
        var selectedItems: [SmartCareItem] = []
        var selectedPaths: [String] = []
        var rows: [RowItem] = []
        var bytes: Int64 = 0
        var confirmations = 0
        selectedItems.reserveCapacity(items.count)
        selectedPaths.reserveCapacity(items.count)
        rows.reserveCapacity(items.count)
        for item in items where item.isSelectable {
            selectedItems.append(item)
            selectedPaths.append(item.path)
            rows.append(RowItem(
                id: item.id,
                url: URL(fileURLWithPath: item.path),
                title: item.title,
                isDirectory: item.isDirectory,
                bytes: item.bytes,
                logicalBytes: item.logicalBytes,
                fileCount: item.fileCount,
                verdict: item.verdict,
                rejection: .ok,
                vendorNote: item.riskNote,
                runningBundleIDPrefix: item.runningBundleIDPrefix,
                titlePresentation: item.titlePresentation,
                vendorNotePresentation: item.riskNotePresentation
            ))
            bytes &+= item.bytes
            if item.verdict == .confirm { confirmations &+= 1 }
        }
        self.init(
            id: UUID(),
            items: selectedItems,
            requiresConfirmation: confirmations > 0,
            paths: selectedPaths,
            totalBytes: bytes,
            confirmCount: confirmations,
            previewRows: rows,
            sourceSummaryRevision: nil,
            sourceSelectionRevision: nil,
            sourceDeletionSnapshotIdentity: nil
        )
    }

    func stamped(summaryRevision: UInt64, selectionRevision: UInt64) -> Self {
        Self(
            id: id,
            items: items,
            requiresConfirmation: requiresConfirmation,
            paths: paths,
            totalBytes: totalBytes,
            confirmCount: confirmCount,
            previewRows: previewRows,
            sourceSummaryRevision: summaryRevision,
            sourceSelectionRevision: selectionRevision,
            sourceDeletionSnapshotIdentity: sourceDeletionSnapshotIdentity,
            reviewedObjects: reviewedObjects
        )
    }

    func bindingDeletionSnapshot(_ identity: DeletionSnapshotIdentity) -> Self {
        Self(
            id: id,
            items: items,
            requiresConfirmation: requiresConfirmation,
            paths: paths,
            totalBytes: totalBytes,
            confirmCount: confirmCount,
            previewRows: previewRows,
            sourceSummaryRevision: sourceSummaryRevision,
            sourceSelectionRevision: sourceSelectionRevision,
            sourceDeletionSnapshotIdentity: identity,
            reviewedObjects: reviewedObjects
        )
    }

    func bindingReviewedObjects(_ objects: ReviewedDeletionObjects) -> Self? {
        guard objects.matchesExactTargets(paths) else { return nil }
        return Self(
            id: id, items: items, requiresConfirmation: requiresConfirmation,
            paths: paths, totalBytes: totalBytes, confirmCount: confirmCount,
            previewRows: previewRows, sourceSummaryRevision: sourceSummaryRevision,
            sourceSelectionRevision: sourceSelectionRevision,
            sourceDeletionSnapshotIdentity: sourceDeletionSnapshotIdentity,
            reviewedObjects: objects
        )
    }

    private init(id: UUID,
                 items: [SmartCareItem],
                 requiresConfirmation: Bool,
                 paths: [String],
                 totalBytes: Int64,
                 confirmCount: Int,
                 previewRows: [RowItem],
                 sourceSummaryRevision: UInt64?,
                 sourceSelectionRevision: UInt64?,
                 sourceDeletionSnapshotIdentity: DeletionSnapshotIdentity?,
                 reviewedObjects: ReviewedDeletionObjects? = nil) {
        self.id = id
        self.items = items
        self.requiresConfirmation = requiresConfirmation
        self.paths = paths
        self.totalBytes = totalBytes
        self.confirmCount = confirmCount
        self.previewRows = previewRows
        self.sourceSummaryRevision = sourceSummaryRevision
        self.sourceSelectionRevision = sourceSelectionRevision
        self.sourceDeletionSnapshotIdentity = sourceDeletionSnapshotIdentity
        self.reviewedObjects = reviewedObjects
    }
}

public enum SmartCarePhase: Sendable, Hashable {
    case idle
    case scanning(progress: SmartCareProgress)
    case reviewing(summary: SmartCareSummary)
    case confirming(selection: SmartCareSelection)
    case cleaning(progress: SmartCareCleanProgress)
    case completed(result: SmartCareResult)
    case failed(SmartCareError)
    case cancelled(partial: SmartCareSummary?)

    public var primaryAction: SmartCarePrimaryAction {
        switch self {
        case .idle:
            return .startScan
        case .scanning:
            return .stopScan
        case .reviewing:
            return .cleanSafeItems
        case .confirming:
            return .confirmClean
        case .cleaning:
            return .cleaning
        case .completed(let result):
            return result.completion == .partial ? .cleanSafeItems : .scanAgain
        case .failed:
            return .retry
        case .cancelled:
            return .continueScan
        }
    }
}
