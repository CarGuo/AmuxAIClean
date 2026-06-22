import Foundation
import Observation
import SafetyKit

/// v2026.06.18 **稍后处理（购物车）**：跨视图共享的"待处理路径集合"。
///
/// 用户在 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// / [LargeFilesView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LargeFilesView.swift)
/// 等任意结果视图的行 contextMenu 点"加入待处理"，把当前 path 暂存到这里；
/// [MainView toolbar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
/// 的入口按钮显示 badge 数字，点击打开 [StashScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashScreen.swift)
/// 集中"一键清理 / 一键 AI / 单独清理 / 单独 AI / 剔除"。
///
/// 设计要点：
/// 1. **去重 by 绝对路径**：同一路径 add 多次只保留一份；判断 key 一律走 path 原文，
///    不做 standardizingPath 二次规范化——保留用户实际看到的入口字符串（比如
///    `~/Library/Developer` 真实展开后的绝对路径在 ScanCoordinator 里已经统一过了）。
/// 2. **顺序保留**：用 `OrderedSet`（这里用 `[StashEntry]` + Set 校验）以保持"先加先在前"，
///    用户从树里依次勾时能在购物车看到一致的视觉顺序——纯 `Set` 不行。
/// 3. **不持久化**：参考真实购物车交互，待处理本来就是"当前会话内的筹划态"，
///    退出 App 就清空；持久化反而会导致下次启动残留陈旧路径（用户可能已通过其他途径删了）。
///    将来如果用户反馈"想跨会话保留"，再加 `UserDefaults` 兜底，不影响当前 API。
/// 4. **不主动校验存在性**：add 时只信入口给的 metadata（size / isDirectory），
///    不做额外 stat —— 频繁 stat 在万级路径下会卡 UI；
///    [StashScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashScreen.swift)
///    展示时如有需要再懒校验。
/// 5. **@Observable + @MainActor**：所有 mutation 都在主线程发生（contextMenu 回调 / toolbar 点击），
///    @MainActor 把多线程访问拒之门外；@Observable 让 SwiftUI 自动订阅 `entries`。
@MainActor
@Observable
public final class StashStore {

    /// 单条待处理。`id == path` 保证 List 复用 + diff 稳定。
    /// 把 size / isDirectory / addedAt 一并存下来：StashScreen 渲染时无需回查
    /// ScanCoordinator（解耦 + 即使树视图已切走也能继续展示）。
    public struct StashEntry: Identifiable, Hashable, Sendable {
        public let id: String        // == path
        public let path: String
        public let title: String     // lastPathComponent，缓存避免每次重算
        public let bytes: Int64
        public let isDirectory: Bool
        public let addedAt: Date
        /// v2026.06.19 **一键 AI 队列**结果缓存。
        /// `.pending` 是初值；由 [StashAIQueue.start](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashAIQueue.swift)
        /// 在每条询问完成后调 [setAIVerdict](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift)
        /// 翻成 `.done(...)` 或 `.error(...)`。
        /// StashScreen 行内据此渲染 ✓ / ✕ / ? 徽标 + tooltip。
        public var aiVerdict: AIVerdictCache

        public init(path: String, title: String, bytes: Int64, isDirectory: Bool,
                    addedAt: Date = Date(),
                    aiVerdict: AIVerdictCache = .pending) {
            self.id = path
            self.path = path
            self.title = title
            self.bytes = bytes
            self.isDirectory = isDirectory
            self.addedAt = addedAt
            self.aiVerdict = aiVerdict
        }
    }

    /// AI 一键判断的逐条结果状态机。
    /// - `.pending`：尚未进队列 / 队列尚未跑到这条 / 队列取消时未到这条
    /// - `.done(verdict, summary)`：AI 返回了 canDelete + 一句话摘要
    /// - `.error(message)`：单条调用失败（http / 解析失败 / 取消等）
    public enum AIVerdictCache: Hashable, Sendable {
        case pending
        case done(SafetyVerdict, summary: String)
        case error(message: String)
    }

    /// 当前所有待处理条目（按加入顺序排列）。
    /// SwiftUI 视图直接读这个数组拿 count / iterate；不要在外部再持一个 cached count，
    /// 同步 mutation 自动通过 @Observable 触发刷新。
    public private(set) var entries: [StashEntry] = []

    /// v2026.06.23 perf（Instruments 第六次取证 33334.md 703.80ms）：
    /// `contains(_:)` 是 row body 求值热路径（[MainView L1213](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1213)
    /// `isStashed: { path in stash.contains(path) }` 每行调一次），
    /// 旧实现 `entries.contains(where: { $0.id == path })` 是 O(N) 全扫 +
    /// 每次还要 `ObservationRegistrar.access(\.entries)` 注册依赖
    /// （trace 显示 closure #5 in MainView.results.getter → StashStore.contains
    /// 2.5ms 在 hot path）。100 行可视 × 60fps × 50 条 stash = 每秒 30 万次
    /// 字符串相等比较 → 滚动卡顿。
    ///
    /// 修复：维护一个 `pathIndex: Set<String>` 镜像，跟 entries 在每个 mutation
    /// 点同步。`contains` 改读这个 set → O(1) hash 查找 + 单次 Observation
    /// 依赖注册（依赖 pathIndex 而非 entries，stash 内部条目顺序变化不再
    /// invalidate 所有 row）。
    ///
    /// 注意 `@ObservationIgnored` **不能**用——这里恰恰要 Observation：
    /// stash 增删时 `isStashed` 闭包需要重新求值翻转徽标。但订阅源从
    /// `entries` 数组改成 `pathIndex` set，set mutation 与 row count
    /// 无关，避免任何小变化都让所有 row body 重跑。
    public private(set) var pathIndex: Set<String> = []

    public init() {}

    /// 待处理总数。`Toolbar` badge 直接读这个值，==0 时按钮整体隐藏。
    public var count: Int { entries.count }

    /// 待处理总字节数。`StashScreen` 状态栏 / 删除确认对话框需要给"将释放多少空间"提示。
    public var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    /// 加入待处理。已存在（同 path）则**忽略**（即语义为 set 而非 multiset）。
    /// 返回值：是否真的新增了一条；false 表示已存在被去重。
    /// 这个返回值给 UI 用——加入时可顺手 toast / 蜂鸣区分"成功 vs 重复加入"。
    @discardableResult
    public func add(_ entry: StashEntry) -> Bool {
        // v2026.06.23 perf：先查 O(1) pathIndex 而不是 O(N) entries.contains。
        if pathIndex.contains(entry.id) { return false }
        entries.append(entry)
        pathIndex.insert(entry.id)
        return true
    }

    /// 便捷重载：从原始字段构造再 add。tree row contextMenu 调它最方便。
    @discardableResult
    public func add(path: String, title: String, bytes: Int64, isDirectory: Bool) -> Bool {
        add(StashEntry(path: path, title: title, bytes: bytes, isDirectory: isDirectory))
    }

    /// 是否已加入待处理。tree row contextMenu 用它来"已加入则禁用按钮 + 改文案"。
    /// v2026.06.23 perf：O(N) entries.contains → O(1) Set.contains（详见 [pathIndex](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift#L96) 文档）。
    public func contains(_ path: String) -> Bool {
        pathIndex.contains(path)
    }

    /// 移除单条。用户在 StashScreen 点 ✕ 或右键"剔除"。
    public func remove(_ path: String) {
        entries.removeAll { $0.id == path }
        pathIndex.remove(path)
    }

    /// 批量移除。一键清理 / 单独清理走真删通道之前，先把对应路径从待处理里摘掉，
    /// 避免删完了图标还残留在购物车。
    public func remove(paths: [String]) {
        let set = Set(paths)
        entries.removeAll { set.contains($0.id) }
        pathIndex.subtract(set)
    }

    /// 清空待处理。用户主动点"清空"或一键清理全部成功后调用。
    public func clear() {
        entries.removeAll()
        pathIndex.removeAll()
    }

    /// v2026.06.19 写入单条 AI 判断结果。由 [StashAIQueue](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashAIQueue.swift)
    /// 在每条 ask 完成后调用。`@Observable` 自动驱动 StashScreen 刷新对应行徽标。
    /// 若 path 已被用户在 sheet 内剔除，写入会 no-op（不复活已删条目）。
    public func setAIVerdict(path: String, verdict: AIVerdictCache) {
        guard let i = entries.firstIndex(where: { $0.id == path }) else { return }
        entries[i].aiVerdict = verdict
    }

    /// 重置所有条目的 AI 判定为 `.pending`。用户在 StashScreen 想"重新跑一次"时调用。
    public func clearAIVerdicts() {
        for i in entries.indices {
            entries[i].aiVerdict = .pending
        }
    }
}
