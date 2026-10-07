import Foundation
import SafetyKit

/// HL（Heuristic Learning）启发式迭代引擎。
///
/// **目标**：根据用户的"删除 / 还原 / 保留"行为，给任意路径打一个 [-1.0, 1.0] 的偏好分。
///   - **正分**：鼓励删除（用户曾经多次主动删过此前缀下的东西）
///   - **负分**：警惕（用户曾经从废纸篓还原过此前缀，或主动保留过）
///   - **零分**：中立 / 没有任何信号
///
/// **核心红线**：`score` 永远不会越过 `SafetyEngine.evaluate` 的 `forbid` —— 即使学习到一万次"用户删过这里"，
/// 只要 SafetyEngine 判它 forbid，score 必返回 ≤ 0；这条规则由 `sanityCheck` 内部强制。
///
/// **前缀累积**：每条 action 都会让 `path` **及其所有祖先目录前缀**计数 +1，
/// 这样高层目录（如 `~/Library/Caches/com.acme/`）天然继承子节点的统计。
public actor HeuristicEngine {

    // MARK: - 内部状态

    /// path → 累积计数（key 是 standardized 后的绝对路径）。
    private var scores: [String: PathScore]

    /// 注入用于安全兜底的 SafetyEngine（默认是默认实例）。
    private let safety: SafetyEngine

    /// home 目录（仅用于把 SafetyEngine 的 evaluate 路径上下文锁定到测试环境）。
    private let home: String

    // MARK: - 初始化

    public init(safety: SafetyEngine = SafetyEngine(),
                home: String = NSHomeDirectory(),
                initialScores: [String: PathScore] = [:]) {
        self.safety = safety
        self.home = home
        self.scores = initialScores
    }

    // MARK: - 行为录入

    /// 录入一条用户行为。
    ///
    /// 会把 `action.path` 标准化后，对它**自身**以及所有**祖先目录前缀**各 +1。
    /// 例如 trashed `/A/B/c.log` 会让 `/A/B/c.log`、`/A/B`、`/A` 各自的 deletedCount +1。
    public func record(action: UserAction) {
        let standardized = Self.standardize(action.path)
        guard !standardized.isEmpty, standardized.hasPrefix("/") else { return }

        for prefix in Self.ancestorPrefixes(of: standardized) {
            if prefix != standardized && isSharedContainerRoot(prefix) {
                continue
            }
            var entry = scores[prefix] ?? PathScore()
            switch action {
            case .trashedPath:
                entry.deletedCount += 1
            case .restoredPath:
                entry.restoredCount += 1
            case .keptPath:
                entry.keptCount += 1
            }
            entry.lastUpdated = action.timestamp
            scores[prefix] = entry
        }
    }

    /// 批量录入。
    public func record(actions: [UserAction]) {
        for a in actions { record(action: a) }
    }

    // MARK: - 评分

    /// 返回某路径的启发式分数 ∈ [-1.0, 1.0]。
    ///
    /// **公式**（朴素 Laplace 平滑 + 值域压缩）：
    ///   raw = (deleted - α·restored - β·kept) / (deleted + α·restored + β·kept + γ)
    ///   - α = 3.0  ：还原是最强的负向信号（用户后悔了）
    ///   - β = 1.0  ：保留只是温和的负向（也许只是这次不想删）
    ///   - γ = 2.0  ：先验平滑，避免少量样本剧烈震荡
    ///
    /// **sanity rules**（按顺序）：
    ///   1. forbid 路径 → max(score, 0) 之前先 clamp 到 ≤ 0；任何正分一律抹平为 0
    ///   2. 只要该路径**或任意祖先前缀** restoredCount > 0 → 强制 ≤ 0（"用户曾经反悔过这条线"）
    ///   3. 最终 clamp 到 [-1, 1]
    public func score(path: String) -> Double {
        let standardized = Self.standardize(path)
        guard !standardized.isEmpty else { return 0 }

        // 取该路径自身的累积值（不向下汇总——record 时已经向上累加过）
        let entry = scores[standardized] ?? PathScore()

        let alpha = 3.0
        let beta  = 1.0
        let gamma = 2.0

        let pos = Double(entry.deletedCount)
        let neg = alpha * Double(entry.restoredCount) + beta * Double(entry.keptCount)
        let denom = pos + neg + gamma
        var raw = (pos - neg) / denom

        // sanityCheck —— 见 doc 中的规则
        raw = sanityCheck(rawScore: raw, path: standardized)

        // clamp
        if raw > 1.0 { raw = 1.0 }
        if raw < -1.0 { raw = -1.0 }
        return raw
    }

    /// 取出某路径的原始计数（主要用于测试 / 诊断）。
    public func snapshotEntry(for path: String) -> PathScore? {
        scores[Self.standardize(path)]
    }

    /// 取出整体快照。
    public func snapshot() -> HeuristicSnapshot {
        HeuristicSnapshot(version: 1, scores: scores)
    }

    // MARK: - 持久化

    /// 写入 JSON。原子写入。
    public func persist(to url: URL) throws {
        let snap = HeuristicSnapshot(version: 1, scores: scores)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        try data.write(to: url, options: [.atomic])
    }

    /// 从 JSON 读入并替换内部状态。
    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(HeuristicSnapshot.self, from: data)
        self.scores = snap.scores
    }

    // MARK: - 安全兜底

    /// 强保证：对任何路径，最终分数都不会越过 SafetyEngine 的 forbid 红线。
    ///
    /// 规则：
    ///   1. SafetyEngine 判 `forbid` → 任何正分压成 0（保留负分以体现"更警惕"语义）
    ///   2. 该路径自身或任意祖先曾被 `restoredPath` 标记 → 强制 ≤ 0
    private func sanityCheck(rawScore: Double, path: String) -> Double {
        var s = rawScore

        // 规则 1：forbid 永远不许输出正分
        let verdict = safety.evaluate(path: path, home: home).0
        if verdict == .forbid && s > 0 {
            s = 0
        }

        // 规则 2：祖先链上有 restore 历史 → 全线警惕，强制严格负分
        if hasRestoreInLineage(of: path) {
            let restorePenalty = 0.1
            if s > 0 {
                s = -max(min(1.0, s), restorePenalty) // 翻成至少 -0.1 的负分
            } else {
                s = min(s, -restorePenalty) // 已是 ≤0，也要保证严格 < 0
            }
        }

        return s
    }

    /// 检查该路径自身或任一应用级祖先前缀是否曾经发生过 restore。
    /// 共享容器根（如 `/Users`、`$HOME`、`~/Library/Caches`）不跨应用传染 restore 惩罚。
    private func hasRestoreInLineage(of path: String) -> Bool {
        for prefix in Self.ancestorPrefixes(of: path) {
            if prefix != path && isSharedContainerRoot(prefix) {
                continue
            }
            if let entry = scores[prefix], entry.restoredCount > 0 { return true }
        }
        return false
    }

    /// 判断路径是否为多应用共用的顶层容器目录（不应用于跨应用向上聚合或传染）。
    private func isSharedContainerRoot(_ prefix: String) -> Bool {
        let stdHome = Self.standardize(home)
        if !stdHome.isEmpty {
            if prefix == stdHome || stdHome.hasPrefix(prefix + "/") {
                return true
            }
            let sharedHomeContainers: Set<String> = [
                "\(stdHome)/Library",
                "\(stdHome)/Library/Caches",
                "\(stdHome)/Library/Logs",
                "\(stdHome)/Library/Application Support",
                "\(stdHome)/Library/Containers",
                "\(stdHome)/Library/Group Containers",
                "\(stdHome)/Library/Saved Application State",
                "\(stdHome)/Library/Preferences",
                "\(stdHome)/Library/Developer",
                "\(stdHome)/Downloads",
                "\(stdHome)/Documents",
                "\(stdHome)/Desktop",
            ]
            if sharedHomeContainers.contains(prefix) {
                return true
            }
        }
        let systemContainers: Set<String> = [
            "/Users", "/var", "/private", "/private/var", "/tmp", "/private/tmp",
            "/System", "/Library", "/Applications"
        ]
        return systemContainers.contains(prefix)
    }

    // MARK: - 工具

    /// 标准化绝对路径（去 trailing slash，去 ..）。
    nonisolated static func standardize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return "" }
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        // URL.path 在根 "/" 也保留 "/"，其他末尾不带 "/"
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 返回 path 自身 + 所有祖先目录前缀（不含 "/"）。
    /// 例如 `/A/B/c.log` → ["/A/B/c.log", "/A/B", "/A"]。
    nonisolated static func ancestorPrefixes(of path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        var result: [String] = []
        var current = path
        while current.count > 1 {
            result.append(current)
            // 砍掉最后一段
            if let slash = current.lastIndex(of: "/") {
                if slash == current.startIndex {
                    break // 已到根 "/"
                }
                current = String(current[..<slash])
            } else {
                break
            }
        }
        return result
    }
}
