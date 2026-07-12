import Foundation
import SafetyKit

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
    public let bytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    public let verdict: SafetyVerdict
    public let riskNote: String?
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
                runningBundleIDPrefix: String? = nil) {
        self.id = id
        self.bucketID = bucketID
        self.path = path
        self.title = title
        self.bytes = bytes
        self.logicalBytes = logicalBytes ?? bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.verdict = verdict
        self.riskNote = riskNote
        self.runningBundleIDPrefix = runningBundleIDPrefix
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
        self.id = id
        self.items = items
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
        for item in items {
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
        self.safeItems = safeItems
        self.confirmItems = confirmItems
        self.forbidItems = forbidItems
        self.safeItemIDs = safeIDs
        self.safeBytes = safeBytes
        self.confirmBytes = confirmBytes
        self.forbidBytes = forbidBytes
        self.totalBytes = safeBytes + confirmBytes + forbidBytes
        self.safeCount = safeCount
        self.confirmCount = confirmCount
        self.forbidCount = forbidCount
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
        self.buckets = buckets
        self.items = buckets.flatMap(\.items)
        self.safeItems = buckets.flatMap(\.safeItems)
        self.confirmItems = buckets.flatMap(\.confirmItems).sorted(by: Self.priorityOrder)
        self.forbidItems = buckets.flatMap(\.forbidItems).sorted(by: Self.priorityOrder)
        self.itemIDs = Set(items.map(\.id))
        self.safeBytes = buckets.reduce(0) { $0 + $1.safeBytes }
        self.confirmBytes = buckets.reduce(0) { $0 + $1.confirmBytes }
        self.forbidBytes = buckets.reduce(0) { $0 + $1.forbidBytes }
        self.totalBytes = buckets.reduce(0) { $0 + $1.totalBytes }
        self.forbiddenCount = buckets.reduce(0) { $0 + $1.forbidCount }
    }

    public static let empty = SmartCareSummary(buckets: [])

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
        let currentIDs = Set(items.map(\.id))

        selectedIDs = selectedIDs.intersection(currentIDs)
        userOverriddenIDs = userOverriddenIDs.intersection(currentIDs)

        for item in items {
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

public struct SmartCareResult: Sendable, Hashable {
    public let movedCount: Int
    public let skippedCount: Int
    public let releasedBytes: Int64

    public init(movedCount: Int, skippedCount: Int, releasedBytes: Int64) {
        self.movedCount = movedCount
        self.skippedCount = skippedCount
        self.releasedBytes = releasedBytes
    }
}

/// AI 只提供附加建议，不改写本地 SafetyVerdict，也不自动改变勾选状态。
public enum SmartCareAIItemState: Sendable, Hashable {
    case pending
    case reviewing
    case advice(SafetyVerdict, summary: String)
    case failed(String)
}

public enum SmartCareError: Sendable, Hashable {
    case scanFailed(String)
    case cleanFailed(String)
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

    public init(items: [SmartCareItem]) {
        self.id = UUID()
        self.items = items.filter(\.isSelectable)
        self.requiresConfirmation = self.items.contains { $0.verdict == .confirm }
    }

    public var paths: [String] {
        items.map(\.path)
    }

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var confirmCount: Int {
        items.filter { $0.verdict == .confirm }.count
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
        case .completed:
            return .scanAgain
        case .failed:
            return .retry
        case .cancelled:
            return .continueScan
        }
    }
}
