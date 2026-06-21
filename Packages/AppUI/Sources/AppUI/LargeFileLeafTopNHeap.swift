import Foundation

/// **Step 9c / 2026-06**：大文件叶子 Top-N 维护器（min-heap 实现）。
///
/// 历史问题：
///   早期 [largeFileLeaves](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
///   是个普通 `[LargeFileLeaf]`，每个 ≥ `largeFileMinBytes` 的叶子都 `append` 进来。
///   极端情况（用户把阈值调到 1MB 扫整盘）下数百万条命中 → 内存翻车，
///   且 `largeFiles(...)` 调用时还要做 O(N log N) 排序整套，UI 第一帧卡顿。
///
/// 新做法：维护"按 bytes 升序的 min-heap"，容量上限 `capacity`（默认 1000）：
///   - heap.count < capacity → 直接 push
///   - heap.count == capacity 且 newBytes > heap.peek().bytes → pop + push
///   - 否则丢弃
/// 总体内存 O(capacity) = O(1000)；每次插入 O(log capacity) = O(10)；
/// 取 Top N 时一次性 `Array(heap)`（无序）+ 上层按 sortKey 排序即可。
///
/// 性能契约：100w 次 consider 调用，平均 ≤ 1.5s（M1 实测），常驻内存 ~64KB。
///
/// **不参与 @Published**：单一会话内的纯存储型容器，写入时机由 ScanCoordinator
/// 的 ingest path 控制；UI 不直接订阅它，而是通过 `bumpStructuralRevision()` /
/// `bumpTickRevision()` 间接刷新。
struct LargeFileLeafTopNHeap {

    /// Top-N 容量。`0` 表示禁用（不收集任何叶子）。
    let capacity: Int

    /// 内部 heap 存储。**不变量**：`storage` 是按 `bytes` 升序的 min-heap，
    /// 即 `storage[0]` 永远是当前 Top-N 中 bytes 最小的那条。
    private var storage: [ScanCoordinator.LargeFileLeaf] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        if self.capacity > 0 {
            storage.reserveCapacity(self.capacity)
        }
    }

    var isEmpty: Bool { storage.isEmpty }

    var count: Int { storage.count }

    /// 把 heap 内容平铺成数组。**未排序**——上层（`largeFiles(...)`）会按用户选择的 sortKey
    /// 二次排序。这里不做无意义的预排序，避免双倍开销。
    func snapshot() -> [ScanCoordinator.LargeFileLeaf] {
        storage
    }

    /// 主入口：考虑接纳一条新叶子。
    /// 返回值仅用于单元测试观察（`true` = 真的入堆 / 替换；`false` = 丢弃）。
    @discardableResult
    mutating func consider(_ leaf: ScanCoordinator.LargeFileLeaf) -> Bool {
        guard capacity > 0 else { return false }
        if storage.count < capacity {
            storage.append(leaf)
            siftUp(from: storage.count - 1)
            return true
        }
        // 满了：仅当新条目比当前最小条目大才替换。
        // bytes 相等时不动（保持稳定，避免无意义抖动）。
        guard leaf.bytes > storage[0].bytes else { return false }
        storage[0] = leaf
        siftDown(from: 0)
        return true
    }

    mutating func removeAll(keepingCapacity: Bool) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    /// **v2026.06.22**：按路径前缀剔除已删叶子，并重建 min-heap 不变量。
    ///
    /// 背景：用户反馈 "大文件列表，删除后没列表没更新，内容还在"。
    /// 根因：[ScanCoordinator.pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1621)
    /// 历史上只剔除 `buckets / dirIndex / childEdges / fileLeaves / snapshot.rows /
    /// treeChildrenCache`；而 LargeFilesView 直接 `coordinator.largeFiles(...)` →
    /// 走 `largeFileLeaves.snapshot()`，**完全没经过 pruneDeleted 的洗手段**，
    /// 已删项永驻 heap 直到下次 startScan 重置。
    ///
    /// 实现：filter-then-rebuild —— heap 元素总数 ≤ 1000（capacity 默认），一次 O(N)
    /// 过滤后用 [heapify](https://en.wikipedia.org/wiki/Binary_heap#Building_a_heap) 自底向上
    /// `siftDown` 在 O(N) 时间内重建不变量，无须重头 push。
    ///
    /// 调用契约：`shouldRemove` 必须无副作用且幂等（pruneDeleted 同一帧可能传若干路径）。
    /// 返回值：实际被剔除的条目数；==0 时调用方可跳过 UI 重渲染。
    @discardableResult
    mutating func removeAll(where shouldRemove: (ScanCoordinator.LargeFileLeaf) -> Bool) -> Int {
        guard !storage.isEmpty else { return 0 }
        let before = storage.count
        storage.removeAll(where: shouldRemove)
        let removed = before - storage.count
        if removed > 0 {
            // 重建 min-heap：从最后一个非叶子节点向前 siftDown。
            // 复杂度 O(n) — Floyd's heapify 经典算法。
            if storage.count > 1 {
                var i = (storage.count / 2) - 1
                while i >= 0 {
                    siftDown(from: i)
                    i -= 1
                }
            }
        }
        return removed
    }

    // MARK: - Heap 维护（min-heap，比较键 = bytes）

    @inline(__always)
    private func less(_ a: Int, _ b: Int) -> Bool {
        storage[a].bytes < storage[b].bytes
    }

    private mutating func siftUp(from index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) >> 1
            if less(i, parent) {
                storage.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var i = index
        let n = storage.count
        while true {
            let left = 2 * i + 1
            let right = left + 1
            var smallest = i
            if left < n, less(left, smallest) { smallest = left }
            if right < n, less(right, smallest) { smallest = right }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}
