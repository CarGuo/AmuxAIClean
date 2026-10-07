import Combine
import Foundation

/// v1.2 P1-5：大文件清单的批量选择状态。
///
/// 设计要点：
/// 1. **以 path 字符串为 key**——LargeFileItem 是值类型，重排/筛选会重建实例；
///    用 Set<String> 而非 Set<LargeFileItem> 才能跨重排稳定。
/// 2. **与 visible 列表解耦**——批量选中是用户意图记录；当某条因筛选被隐藏，
///    我们不主动剔除它（用户切回筛选还想看到自己的勾），而是在 trash 时按 visible 求交集。
/// 3. **Combine 状态发布**——v2026.07.16 起与 AppSettings 统一，兼容 macOS 13.5。
/// 4. **isAllSelected / isPartiallySelected** 提供给 header checkbox 三态展示。
@MainActor
public final class BatchSelection: ObservableObject {
    /// 已勾选的 path 集合。空集 = 完全未选。
    @Published public private(set) var selected: Set<String> = []

    public init() {}

    // MARK: - 单条 toggle / set

    public func isSelected(_ path: String) -> Bool {
        selected.contains(path)
    }

    public func toggle(_ path: String) {
        if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
        }
    }

    public func setSelected(_ path: String, _ on: Bool) {
        if on {
            selected.insert(path)
        } else {
            selected.remove(path)
        }
    }

    public func clear() {
        selected.removeAll()
    }

    public func remove(paths: [String]) {
        guard !paths.isEmpty, !selected.isEmpty else { return }
        let matcher = DeletionPresentationPathMatcher(paths: paths)
        selected = selected.filter { !matcher.contains($0) }
    }

    // MARK: - 与可见列表的交互

    /// 全选当前可见集。**注意**：visible 通常是 mtime + kind 过滤后的列表，
    /// 全选只对"用户眼下能看到的"生效；不显示的不会被波及。
    public func selectAll(visible: [String]) {
        selected.formUnion(visible)
    }

    /// 取消可见集中的勾选。配合 header 三态切换。
    public func deselectAll(visible: [String]) {
        selected.subtract(visible)
    }

    /// 当前 visible 中已勾选数量。用于 header "已选 N / 共 M"。
    public func selectedCount(in visible: [String]) -> Int {
        var n = 0
        for p in visible where selected.contains(p) { n += 1 }
        return n
    }

    /// header checkbox 状态：none / partial / all。
    public func headerState(visible: [String]) -> HeaderState {
        if visible.isEmpty { return .none }
        let n = selectedCount(in: visible)
        if n == 0 { return .none }
        if n == visible.count { return .all }
        return .partial
    }

    public enum HeaderState: Equatable, Sendable {
        case none, partial, all
    }

    /// 求交集：visible ∩ selected，按 visible 顺序保持稳定。
    /// 这是 trash 调用前的最终入参——只删用户眼下勾着且看得见的。
    public func selectedItemsIntersecting(visible: [String]) -> [String] {
        visible.filter { selected.contains($0) }
    }
}
