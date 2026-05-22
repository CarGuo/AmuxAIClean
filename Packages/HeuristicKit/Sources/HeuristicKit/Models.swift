import Foundation

/// 用户行为事件。
///
/// HL（Heuristic Learning）只关心三类信号：
/// - `keptPath`：用户在 UI 里**主动取消勾选**或**确认保留** —— 弱负向（让我们将来不要默认勾选这个前缀）
/// - `trashedPath`：用户**确认丢入废纸篓** —— 强正向（鼓励将来更主动建议删除该前缀）
/// - `restoredPath`：用户**从废纸篓还原**了一个我们建议删除的文件 —— 强负向（这是最关键的"反悔"信号）
public enum UserAction: Sendable, Codable, Equatable {
    case keptPath(String, timestamp: Date)
    case trashedPath(String, timestamp: Date)
    case restoredPath(String, timestamp: Date)

    public var path: String {
        switch self {
        case .keptPath(let p, _), .trashedPath(let p, _), .restoredPath(let p, _):
            return p
        }
    }

    public var timestamp: Date {
        switch self {
        case .keptPath(_, let t), .trashedPath(_, let t), .restoredPath(_, let t):
            return t
        }
    }
}

/// 单个路径前缀的累积计数。
///
/// 注意：`deletedCount` 即"用户确认丢入废纸篓的次数"，
/// `restoredCount` 即"用户从废纸篓还原的次数"，
/// `keptCount` 即"用户主动保留 / 取消勾选的次数"。
public struct PathScore: Sendable, Codable, Equatable {
    public var deletedCount: Int
    public var restoredCount: Int
    public var keptCount: Int
    public var lastUpdated: Date

    public init(deletedCount: Int = 0,
                restoredCount: Int = 0,
                keptCount: Int = 0,
                lastUpdated: Date = .distantPast) {
        self.deletedCount = deletedCount
        self.restoredCount = restoredCount
        self.keptCount = keptCount
        self.lastUpdated = lastUpdated
    }
}

/// 持久化快照（JSON 友好）。
public struct HeuristicSnapshot: Sendable, Codable, Equatable {
    public var version: Int
    public var scores: [String: PathScore]

    public init(version: Int = 1, scores: [String: PathScore] = [:]) {
        self.version = version
        self.scores = scores
    }
}
