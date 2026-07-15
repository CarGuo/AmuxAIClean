import Foundation

/// Smart Care 清理预览的单事务门。
///
/// 生成 preview 会跨 actor 做大列表投影；这段 await 期间必须冻结“点击瞬间”的
/// summary/selection revision，且同一时间只允许一个 token。返回主线程后，只有 token、
/// revision 与 modal 空闲状态全部仍匹配，结果才能成为用户看到的 sheet。
struct SmartCareDeletePreviewGate: Sendable {
    struct Token: Equatable, Sendable {
        let id: UUID
        let summaryRevision: UInt64
        let selectionRevision: UInt64
    }

    private(set) var activeToken: Token?

    var isInFlight: Bool { activeToken != nil }

    mutating func begin(
        summaryRevision: UInt64,
        selectionRevision: UInt64,
        id: UUID = UUID()
    ) -> Token? {
        guard activeToken == nil else { return nil }
        let token = Token(
            id: id,
            summaryRevision: summaryRevision,
            selectionRevision: selectionRevision
        )
        activeToken = token
        return token
    }

    func allowsCompletion(
        token: Token,
        currentSummaryRevision: UInt64,
        currentSelectionRevision: UInt64,
        requestSummaryRevision: UInt64?,
        requestSelectionRevision: UInt64?,
        modalAvailable: Bool
    ) -> Bool {
        activeToken == token
            && currentSummaryRevision == token.summaryRevision
            && currentSelectionRevision == token.selectionRevision
            && requestSummaryRevision == token.summaryRevision
            && requestSelectionRevision == token.selectionRevision
            && modalAvailable
    }

    /// 只有持有当前 token 的任务能释放门；过期任务不能误清掉更新的事务。
    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }
}

/// Sentinel 深链接触发的 UI 意图。路径即使当前版本尚未用于高亮具体卸载项，也要随
/// 事件冻结并排队，避免 modal 冲突时把用户原始动作丢掉。
enum SentinelPresentationIntent: Equatable, Sendable {
    case inviteFullScan
    case openUninstall(path: String?)
}

/// Sentinel presentation 的 FIFO 状态机。
///
/// 事件到达时只入队；窗口当前没有 modal 时，最多调度一个“下一 runloop drain”。如果
/// drain 真正执行前又出现 modal，意图仍留在队首，等 occupancy 重新空闲后继续。
struct SentinelPresentationQueue: Sendable {
    private var pending: [SentinelPresentationIntent] = []
    private(set) var isDrainScheduled = false

    var pendingCount: Int { pending.count }

    mutating func enqueue(_ intent: SentinelPresentationIntent) {
        pending.append(intent)
    }

    mutating func requestDrainIfPossible(isModalBusy: Bool) -> Bool {
        guard !isModalBusy, !pending.isEmpty, !isDrainScheduled else { return false }
        isDrainScheduled = true
        return true
    }

    mutating func takeScheduledIfPossible(isModalBusy: Bool) -> SentinelPresentationIntent? {
        guard isDrainScheduled else { return nil }
        isDrainScheduled = false
        guard !isModalBusy, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
