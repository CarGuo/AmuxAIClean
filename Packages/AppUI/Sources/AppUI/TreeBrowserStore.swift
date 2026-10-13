import Foundation

/// Receipt-backed deletion presentation matcher shared by the Main list and Tree projection.
/// Paths are normalized and parent/child overlaps collapse to a minimal root set off the render
/// path; this is presentation-only. Authoritative byte/count reconciliation remains in
/// `ScanCoordinator.pruneDeleted`.
struct DeletionPresentationPathMatcher: Sendable, Equatable {
    let roots: [String]
    private let rootSet: Set<String>

    init<S: Sequence>(paths: S) where S.Element == String {
        let unique = Set(paths.lazy.map(Self.normalize).filter { !$0.isEmpty })
        let sorted = unique.sorted()
        var minimal: [String] = []
        var minimalSet: Set<String> = []
        minimal.reserveCapacity(sorted.count)
        minimalSet.reserveCapacity(sorted.count)
        for path in sorted where !Self.hasAncestor(of: path, in: minimalSet) {
            minimal.append(path)
            minimalSet.insert(path)
        }
        roots = minimal
        rootSet = minimalSet
    }

    func contains(_ candidate: String) -> Bool {
        // Empty is the dominant steady-state. Keep ordinary full/incremental Tree projection at
        // O(1) per matcher instead of walking every row's ancestor chain when no receipt exists.
        guard !rootSet.isEmpty, !candidate.isEmpty else { return false }
        if rootSet.contains("/"), candidate.hasPrefix("/") { return true }
        var cursor = Self.normalize(candidate)
        while !cursor.isEmpty {
            if rootSet.contains(cursor) { return true }
            if cursor == "/" { break }
            let parent = String._amuxParentPath(of: cursor)
            if parent == cursor { break }
            cursor = parent
        }
        return false
    }

    private static func normalize(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func hasAncestor(of candidate: String, in roots: Set<String>) -> Bool {
        if roots.contains("/"), candidate.hasPrefix("/") { return true }
        var cursor = candidate
        while !cursor.isEmpty {
            if roots.contains(cursor) { return true }
            if cursor == "/" { break }
            let parent = String._amuxParentPath(of: cursor)
            if parent == cursor { break }
            cursor = parent
        }
        return false
    }
}

/// v2026.10.08: carry the receipt matcher and its revision in one immutable event. @Published
/// emits from willSet, so a subscriber must consume this value instead of re-reading old state.
struct TreeDeletionPresentation: Sendable, Equatable {
    let revision: UInt64
    let matcher: DeletionPresentationPathMatcher
}

/// Step 10b / 2026-06：树形浏览状态 SSOT 接口外壳。
///
/// 把 [ScanCoordinator](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// 早期内嵌的树形浏览状态（cache / in-flight / 三层 revision 计数器）
/// 抽到独立 store。设计与 [SystemProbeStore](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SystemProbeStore.swift)
/// 平行 —— 让新代码 / 单测可以**单独**订阅 `coordinator.treeBrowser.structuralRevision`，
/// 而不需要订阅整个 ScanCoordinator。
///
/// 兼容策略（关键）：ScanCoordinator 上原有的 `treeRevision / structuralRevision /
/// tickRevision / childrenCacheVersion` 字段保留作 @Published mirror —— 老 view、
/// 老测试零改动。store 是 SSOT（写入唯一来源），写完之后 ScanCoordinator 端
/// 的 bumpStructuralRevision / bumpTickRevision / bumpChildrenCacheVersion
/// 会把 mirror 同步上来。
///
/// 字段语义详见各属性 doc。
@MainActor
public final class TreeBrowserStore: ObservableObject {
    /// TreeBrowserView 下钻时的子目录展开缓存。
    /// key = `"\(path)|\(sortKey.rawValue)"`，让不同排序各自缓存。
    /// **不**标 @Published —— 写入只 bump [childrenCacheVersion](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L47-L47)。
    public var treeChildrenCache: [String: [TreeRow]] = [:]

    /// 按需子树扫描期间正在飞的 cacheKey 集合（节流，避免重复并发）。
    /// **不**参与 @Published（无视图依赖它）。
    public var treeChildrenInFlight: Set<String> = []

    /// cache 写入计数器（monotonic UInt64）。任何 `treeChildrenCache` 写入 / 删除 /
    /// removeAll / patch-by-prune 都需要 bump。订阅者通常**不需要**直接订阅
    /// （由 [structuralRevision](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L57-L57) 覆盖），保留它给单测 / 未来细粒度刷新留 hook。
    @Published public private(set) var childrenCacheVersion: UInt64 = 0
    /// Exact parent whose direct-child projection changed. Set before publishing the version so
    /// TreeBrowserView can patch only that contiguous expanded segment. `nil` means a session-wide
    /// invalidation/locale/prune transaction and therefore requires a complete projection.
    public private(set) var lastChildrenCacheChangedPath: String?

    /// 树形扁平化重算的"统一脏标"。任何可能改变 directChildren 输出的入口必须 bump。
    /// 老订阅者（外部代码 / 测试）继续读这个；新代码优先订阅 [structuralRevision](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L57-L57)。
    @Published public private(set) var treeRevision: UInt64 = 0

    /// 结构性脏标：节点新增 / 节点删除 / 排序键变化 / cache 整轮失效。
    /// 订阅它的 view 必须重建 flatRows（一次 O(N) 拍平 + verdict 计算）。
    @Published public private(set) var structuralRevision: UInt64 = 0

    /// 数值脏标（非结构性）：已有节点的 bytes / fileCount 变了，节点拓扑没变。
    /// 订阅它的 view **不需要**重建 flatRows，仅 RowView 内部读最新值。
    @Published public private(set) var tickRevision: UInt64 = 0

    /// v2026.07.20：successful recycle receipt 的窄展示信号。完整 roots 留在 store，
    /// revision 仅负责唤醒 Tree；每个订阅者都可读取，不能用单消费者 consume 语义。
    @Published private(set) var deletionPresentation = TreeDeletionPresentation(
        revision: 0,
        matcher: DeletionPresentationPathMatcher(paths: EmptyCollection<String>())
    )
    public var deletionPresentationRevision: UInt64 { deletionPresentation.revision }
    public var deletionPresentationPaths: [String] { deletionPresentation.matcher.roots }

    public init() {}

    /// 单点收敛：cache 写入 → version &+= 1。
    @inline(__always)
    public func bumpChildrenCacheVersion(changedPath: String? = nil) {
        lastChildrenCacheChangedPath = changedPath
        childrenCacheVersion &+= 1
    }

    /// 单点收敛：推进结构脏标。
    /// 同时推 treeRevision（兼容老订阅者）+ structuralRevision；tickRevision 也 +1
    /// （任何 structural 都隐含一次 tick，一致性保证）。
    @inline(__always)
    public func bumpStructuralRevision() {
        structuralRevision &+= 1
        tickRevision &+= 1
        treeRevision &+= 1
    }

    /// 单点收敛：推进数值脏标。treeRevision 也跟着走（兼容订阅者不死寂）；
    /// structuralRevision 不动。
    @inline(__always)
    public func bumpTickRevision() {
        tickRevision &+= 1
        treeRevision &+= 1
    }

    /// v2026.07.20: the coordinator's background tombstone worker owns normalization. Publishing
    /// the frozen matcher keeps sheet remounts and receipt patches O(1) on MainActor.
    func publishDeletionPresentation(matcher: DeletionPresentationPathMatcher) {
        deletionPresentation = TreeDeletionPresentation(
            revision: deletionPresentation.revision &+ 1, matcher: matcher
        )
    }

    public func resetDeletionPresentation() {
        guard !deletionPresentationPaths.isEmpty else { return }
        publishDeletionPresentation(
            matcher: DeletionPresentationPathMatcher(paths: EmptyCollection<String>())
        )
    }
}
