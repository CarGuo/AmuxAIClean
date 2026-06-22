import Foundation

/// Step 10b / 2026-06：树形浏览状态 SSOT 接口外壳。
///
/// 把 [ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// 早期内嵌的树形浏览状态（cache / in-flight / 三层 revision 计数器）
/// 抽到独立 store。设计与 [SystemProbeStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SystemProbeStore.swift)
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
    /// **不**标 @Published —— 写入只 bump [childrenCacheVersion](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L47-L47)。
    public var treeChildrenCache: [String: [TreeRow]] = [:]

    /// 按需子树扫描期间正在飞的 cacheKey 集合（节流，避免重复并发）。
    /// **不**参与 @Published（无视图依赖它）。
    public var treeChildrenInFlight: Set<String> = []

    /// cache 写入计数器（monotonic UInt64）。任何 `treeChildrenCache` 写入 / 删除 /
    /// removeAll / patch-by-prune 都需要 bump。订阅者通常**不需要**直接订阅
    /// （由 [structuralRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L57-L57) 覆盖），保留它给单测 / 未来细粒度刷新留 hook。
    @Published public private(set) var childrenCacheVersion: UInt64 = 0

    /// 树形扁平化重算的"统一脏标"。任何可能改变 directChildren 输出的入口必须 bump。
    /// 老订阅者（外部代码 / 测试）继续读这个；新代码优先订阅 [structuralRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L57-L57)。
    @Published public private(set) var treeRevision: UInt64 = 0

    /// 结构性脏标：节点新增 / 节点删除 / 排序键变化 / cache 整轮失效。
    /// 订阅它的 view 必须重建 flatRows（一次 O(N) 拍平 + verdict 计算）。
    @Published public private(set) var structuralRevision: UInt64 = 0

    /// 数值脏标（非结构性）：已有节点的 bytes / fileCount 变了，节点拓扑没变。
    /// 订阅它的 view **不需要**重建 flatRows，仅 RowView 内部读最新值。
    @Published public private(set) var tickRevision: UInt64 = 0

    public init() {}

    /// 单点收敛：cache 写入 → version &+= 1。
    @inline(__always)
    public func bumpChildrenCacheVersion() {
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
}
