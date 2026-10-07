import SwiftUI
import AppKit
import Combine
import SafetyKit
import AIKit
import LogKit

/// v2026.07.20：行内命令不拥有导航权。AI、暂存和删除只执行命令，只有正文/
/// disclosure 点击才允许改变当前 selection；Tree AppKit、Tree SwiftUI 与 Large Files
/// 共用这条规则，避免新增按钮时再次顺手打开右侧详情。
enum InlineRowActionNavigationPolicy {
    enum Action: Equatable, CaseIterable {
        case askAI
        case stash
        case trash
    }

    static func shouldSelectRow(for action: Action) -> Bool {
        switch action {
        case .askAI, .stash, .trash:
            return false
        }
    }

    /// Inline actions keep keyboard routing on the Tree without taking navigation ownership.
    static func shouldFocusTable(for action: Action) -> Bool { true }
}

/// Sendable rule-evaluation boundary used by the Tree projection worker. Production captures an
/// immutable ScanCoordinator safety snapshot; tests can inject a deterministic evaluator without
/// touching the filesystem.
struct TreeFlatProjectionEvaluator: Sendable {
    let evaluate: @Sendable (String) -> (verdict: SafetyVerdict, rejection: SafetyRejection)
}

struct TreeFlatProjectionWorkerInput: Sendable {
    let rootRows: [TreeRow]
    let childrenByParent: [String: [TreeRow]]
    let expandedPaths: Set<String>
    let fetchingPaths: Set<String>
    let isFetchingRoot: Bool
    let receiptTombstones: DeletionPresentationPathMatcher
    let evaluator: TreeFlatProjectionEvaluator

    init(
        rootRows: [TreeRow],
        childrenByParent: [String: [TreeRow]],
        expandedPaths: Set<String>,
        fetchingPaths: Set<String>,
        isFetchingRoot: Bool,
        receiptTombstones: DeletionPresentationPathMatcher = .init(
            paths: EmptyCollection<String>()
        ),
        evaluator: TreeFlatProjectionEvaluator
    ) {
        self.rootRows = rootRows
        self.childrenByParent = childrenByParent
        self.expandedPaths = expandedPaths
        self.fetchingPaths = fetchingPaths
        self.isFetchingRoot = isFetchingRoot
        self.receiptTombstones = receiptTombstones
        self.evaluator = evaluator
    }
}

struct TreeFlatProjectionPreviousSnapshot: Sendable {
    let rows: [FlatTreeRow]
    let rowIndexByPath: [String: Int]
    let parentIndexByRow: [Int?]
    let maxBytes: Int64
    let isFetchingRoot: Bool
}

struct PreparedTreeFlatProjection: Sendable {
    let rows: [FlatTreeRow]
    let rowIndexByPath: [String: Int]
    let parentIndexByRow: [Int?]
    let maxBytes: Int64
    let isFetchingRoot: Bool
    let changed: Bool
    let tableIdentityChanged: Bool
    let ranOnMainThread: Bool
    /// v2026.07.20: receipt-only Tree updates carry the exact old-table ranges that disappeared.
    /// AppKit can then remove those rows without a full `reloadData()`; ordinary rebuilds leave
    /// this nil and retain the existing full-reload contract.
    let rowRemovalRanges: [Range<Int>]?
}

struct TreeTableRowRemovalDelta: Sendable, Equatable {
    let baseIdentityRevision: UInt64
    let nextIdentityRevision: UInt64
    let baseRowCount: Int
    let nextRowCount: Int
    let ranges: [Range<Int>]
}

enum TreeTableStructuralUpdate: Equatable {
    case reload
    case removeRows([Range<Int>])
    case redrawVisible
}

/// v2026.07.20: structural identity changes normally require a full reload, except for a
/// receipt-backed deletion whose base revision and row counts still match the table on screen.
/// Keeping this decision pure prevents a stale async delta from being applied to a newer Tree.
enum TreeTableStructuralUpdatePolicy {
    static func update(
        renderedIdentityRevision: UInt64?,
        renderedRowCount: Int,
        nextIdentityRevision: UInt64,
        nextRowCount: Int,
        removalDelta: TreeTableRowRemovalDelta?
    ) -> TreeTableStructuralUpdate {
        guard renderedIdentityRevision != nextIdentityRevision else {
            return .redrawVisible
        }
        guard let removalDelta,
              renderedIdentityRevision == removalDelta.baseIdentityRevision,
              nextIdentityRevision == removalDelta.nextIdentityRevision,
              renderedRowCount == removalDelta.baseRowCount,
              nextRowCount == removalDelta.nextRowCount,
              !removalDelta.ranges.isEmpty,
              removalDelta.ranges.allSatisfy({
                  $0.lowerBound >= 0
                      && $0.lowerBound < $0.upperBound
                      && $0.upperBound <= removalDelta.baseRowCount
              }) else {
            return .reload
        }
        for index in removalDelta.ranges.indices.dropFirst() {
            let previous = removalDelta.ranges[index - 1]
            let current = removalDelta.ranges[index]
            guard previous.upperBound <= current.lowerBound else { return .reload }
        }
        let removedCount = removalDelta.ranges.reduce(0) { $0 + $1.count }
        guard removalDelta.baseRowCount - removedCount == removalDelta.nextRowCount else {
            return .reload
        }
        return .removeRows(removalDelta.ranges)
    }
}

@MainActor
enum TreeTableStructuralUpdateApplier {
    static func apply(
        _ update: TreeTableStructuralUpdate,
        to table: NSTableView,
        in scrollView: NSScrollView,
        redrawVisible: () -> Void
    ) {
        switch update {
        case .reload:
            table.reloadData()
        case .removeRows(let ranges):
            var indexes = IndexSet()
            for range in ranges { indexes.insert(integersIn: range) }
            let visibleOrigin = scrollView.contentView.bounds.origin
            table.beginUpdates()
            table.removeRows(at: indexes, withAnimation: [])
            table.endUpdates()
            scrollView.contentView.scroll(to: visibleOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        case .redrawVisible:
            redrawVisible()
        }
    }
}

enum TreeSelectionViewportPolicy {
    nonisolated static func shouldReveal(
        pendingUserNavigationPath: String?,
        selectedPath: String?
    ) -> Bool {
        guard let pendingUserNavigationPath else { return false }
        return pendingUserNavigationPath == selectedPath
    }
}

/// v2026.07.18 P1 root-cause fix: DFS flattening, wide array/Set materialization, loading-state
/// projection and every SafetyEngine evaluation are one generic-executor transaction. The worker
/// retains both the previous and next COW generations until MainActor has completed its O(1)
/// publish, so replacing a 40k-row frame cannot synchronously tear it down on the UI thread.
actor TreeFlatProjectionWorker {
    private var input: TreeFlatProjectionWorkerInput?
    private var previous: TreeFlatProjectionPreviousSnapshot?
    private var prepared: PreparedTreeFlatProjection?

    init(
        input: TreeFlatProjectionWorkerInput,
        previous: TreeFlatProjectionPreviousSnapshot
    ) {
        self.input = input
        self.previous = previous
    }

    func prepare() -> PreparedTreeFlatProjection? {
        guard let input, let previous, !Task.isCancelled else { return nil }
        let ranOnMainThread = Thread.isMainThread
        var rows: [FlatTreeRow] = []
        rows.reserveCapacity(max(input.rootRows.count, previous.rows.count))
        var rowIndexByPath: [String: Int] = [:]
        rowIndexByPath.reserveCapacity(max(input.rootRows.count, previous.rowIndexByPath.count))
        var parentIndexByRow: [Int?] = []
        parentIndexByRow.reserveCapacity(max(input.rootRows.count, previous.parentIndexByRow.count))
        var stack: [(row: TreeRow, depth: Int, parentIndex: Int?)] = []
        stack.reserveCapacity(input.rootRows.count)
        var maxBytes: Int64 = 0
        for row in input.rootRows.reversed() {
            stack.append((row, 0, nil))
        }

        while let entry = stack.popLast() {
            if rows.count & 0xFF == 0, Task.isCancelled { return nil }
            // v2026.07.20 production regression fix: the raw snapshot/cache can legitimately
            // predate a successful recycle receipt while the authoritative prune is still
            // calculating. Visibility follows the receipt tombstone, never the stale cache.
            guard !input.receiptTombstones.contains(entry.row.path) else { continue }
            // A filesystem tree must have one visible identity per public path. Treat a corrupt
            // cycle/duplicate edge as non-present instead of recursing forever on a worker.
            guard rowIndexByPath[entry.row.path] == nil else { continue }
            let currentIndex = rows.count
            if entry.depth == 0 { maxBytes = max(maxBytes, entry.row.bytes) }
            rowIndexByPath[entry.row.path] = currentIndex
            parentIndexByRow.append(entry.parentIndex)
            let evaluation = input.evaluator.evaluate(entry.row.path)
            let shouldTraverse = input.expandedPaths.contains(entry.row.path)
                && entry.row.isDirectory
                && entry.row.hasChildren
                && entry.row.accessState == .normal
            rows.append(FlatTreeRow(
                row: entry.row,
                depth: entry.depth,
                verdict: evaluation.verdict,
                rejection: evaluation.rejection,
                isLoadingChildren: shouldTraverse
                    && input.fetchingPaths.contains(entry.row.path)
            ))
            guard shouldTraverse,
                  let children = input.childrenByParent[entry.row.path]
            else { continue }
            for child in children.reversed() {
                stack.append((child, entry.depth + 1, currentIndex))
            }
        }

        guard !Task.isCancelled else { return nil }
        let tableIdentityChanged: Bool
        if rows.count != previous.rows.count {
            tableIdentityChanged = true
        } else {
            tableIdentityChanged = rows.indices.contains { index in
                rows[index].id != previous.rows[index].id
                    || rows[index].depth != previous.rows[index].depth
            }
        }
        let output = PreparedTreeFlatProjection(
            rows: rows,
            rowIndexByPath: rowIndexByPath,
            parentIndexByRow: parentIndexByRow,
            maxBytes: maxBytes,
            isFetchingRoot: input.rootRows.isEmpty && input.isFetchingRoot,
            changed: rows != previous.rows
                || rowIndexByPath != previous.rowIndexByPath
                || parentIndexByRow != previous.parentIndexByRow
                || maxBytes != previous.maxBytes
                || (input.rootRows.isEmpty && input.isFetchingRoot) != previous.isFetchingRoot,
            tableIdentityChanged: tableIdentityChanged,
            ranOnMainThread: ranOnMainThread,
            rowRemovalRanges: nil
        )
        prepared = output
        return output
    }

    func retire() -> Bool {
        let ranOnMainThread = Thread.isMainThread
        prepared = nil
        previous = nil
        input = nil
        return ranOnMainThread
    }
}

struct TreeIncrementalProjectionWorkerInput: Sendable {
    let togglePath: String
    let isExpanding: Bool
    let childrenByParent: [String: [TreeRow]]
    let expandedPaths: Set<String>
    let fetchingPaths: Set<String>
    let receiptTombstones: DeletionPresentationPathMatcher
    let evaluator: TreeFlatProjectionEvaluator

    init(
        togglePath: String,
        isExpanding: Bool,
        childrenByParent: [String: [TreeRow]],
        expandedPaths: Set<String>,
        fetchingPaths: Set<String>,
        receiptTombstones: DeletionPresentationPathMatcher = .init(
            paths: EmptyCollection<String>()
        ),
        evaluator: TreeFlatProjectionEvaluator
    ) {
        self.togglePath = togglePath
        self.isExpanding = isExpanding
        self.childrenByParent = childrenByParent
        self.expandedPaths = expandedPaths
        self.fetchingPaths = fetchingPaths
        self.receiptTombstones = receiptTombstones
        self.evaluator = evaluator
    }
}

/// v2026.07.19 regression fix: one disclosure click patches only the affected contiguous segment.
/// Array COW, descendant DFS, index rebuilding and new-row verdict evaluation all stay on this
/// actor; a newer click cancels this worker and starts immediately instead of joining stale work.
actor TreeIncrementalProjectionWorker {
    private var input: TreeIncrementalProjectionWorkerInput?
    private var previous: TreeFlatProjectionPreviousSnapshot?
    private var prepared: PreparedTreeFlatProjection?

    init(
        input: TreeIncrementalProjectionWorkerInput,
        previous: TreeFlatProjectionPreviousSnapshot
    ) {
        self.input = input
        self.previous = previous
    }

    func prepare() -> PreparedTreeFlatProjection? {
        guard let input, let previous, !Task.isCancelled else { return nil }

        // A disclosure projection may start after the receipt patch or after a sheet has remounted
        // the Tree from an older frame. Normalize that frame with the same receipt authority before
        // touching the requested segment; this work remains on the worker actor.
        let baselineRows: [FlatTreeRow]
        let baselineIndexByPath: [String: Int]
        if input.receiptTombstones.roots.isEmpty {
            // Preserve the ordinary disclosure fast path: without any successful receipt there
            // is nothing to normalize, so reuse both frozen COW roots instead of scanning the
            // entire visible Tree for one expand/collapse click.
            baselineRows = previous.rows
            baselineIndexByPath = previous.rowIndexByPath
        } else {
            baselineRows = previous.rows.filter {
                !input.receiptTombstones.contains($0.row.path)
            }
            var rebuiltIndex: [String: Int] = [:]
            rebuiltIndex.reserveCapacity(baselineRows.count)
            for (index, item) in baselineRows.enumerated() {
                rebuiltIndex[item.row.path] = index
            }
            baselineIndexByPath = rebuiltIndex
        }
        guard let parentIndex = baselineIndexByPath[input.togglePath],
              baselineRows.indices.contains(parentIndex) else {
            return makeOutput(
                rows: baselineRows,
                previous: previous,
                ranOnMainThread: Thread.isMainThread
            )
        }

        let ranOnMainThread = Thread.isMainThread
        let parentDepth = baselineRows[parentIndex].depth
        var oldSegmentEnd = parentIndex + 1
        while oldSegmentEnd < baselineRows.count,
              baselineRows[oldSegmentEnd].depth > parentDepth {
            oldSegmentEnd += 1
            if oldSegmentEnd & 0xFF == 0, Task.isCancelled { return nil }
        }

        var rows = baselineRows
        if oldSegmentEnd > parentIndex + 1 {
            rows.removeSubrange((parentIndex + 1)..<oldSegmentEnd)
        }
        rows[parentIndex].isLoadingChildren = input.isExpanding
            && input.fetchingPaths.contains(input.togglePath)

        if input.isExpanding {
            let parentRow = rows[parentIndex].row
            guard parentRow.isDirectory,
                  parentRow.hasChildren,
                  parentRow.accessState == .normal
            else {
                return makeOutput(
                    rows: rows,
                    previous: previous,
                    ranOnMainThread: ranOnMainThread
                )
            }

            var inserted: [FlatTreeRow] = []
            var insertedPaths = Set<String>()
            let rootChildren = input.childrenByParent[input.togglePath] ?? []
            var stack: [(row: TreeRow, depth: Int)] = []
            stack.reserveCapacity(rootChildren.count)
            for row in rootChildren.reversed() {
                stack.append((row, parentDepth + 1))
            }

            while let entry = stack.popLast() {
                if inserted.count & 0xFF == 0, Task.isCancelled { return nil }
                guard !input.receiptTombstones.contains(entry.row.path) else { continue }
                let oldIndex = baselineIndexByPath[entry.row.path]
                let belongedToRemovedSegment = oldIndex.map {
                    $0 > parentIndex && $0 < oldSegmentEnd
                } ?? false
                guard (oldIndex == nil || belongedToRemovedSegment),
                      insertedPaths.insert(entry.row.path).inserted
                else { continue }

                let evaluation = input.evaluator.evaluate(entry.row.path)
                let shouldTraverse = input.expandedPaths.contains(entry.row.path)
                    && entry.row.isDirectory
                    && entry.row.hasChildren
                    && entry.row.accessState == .normal
                inserted.append(FlatTreeRow(
                    row: entry.row,
                    depth: entry.depth,
                    verdict: evaluation.verdict,
                    rejection: evaluation.rejection,
                    isLoadingChildren: shouldTraverse
                        && input.fetchingPaths.contains(entry.row.path)
                ))
                guard shouldTraverse,
                      let children = input.childrenByParent[entry.row.path]
                else { continue }
                for child in children.reversed() {
                    stack.append((child, entry.depth + 1))
                }
            }
            if !inserted.isEmpty {
                rows.insert(contentsOf: inserted, at: parentIndex + 1)
            }
        }

        guard !Task.isCancelled else { return nil }
        return makeOutput(
            rows: rows,
            previous: previous,
            ranOnMainThread: ranOnMainThread
        )
    }

    private func makeOutput(
        rows: [FlatTreeRow],
        previous: TreeFlatProjectionPreviousSnapshot,
        ranOnMainThread: Bool
    ) -> PreparedTreeFlatProjection {
        var rowIndexByPath: [String: Int] = [:]
        rowIndexByPath.reserveCapacity(rows.count)
        var parentIndexByRow: [Int?] = []
        parentIndexByRow.reserveCapacity(rows.count)
        var ancestorStack: [(depth: Int, index: Int)] = []
        ancestorStack.reserveCapacity(32)

        for (index, item) in rows.enumerated() {
            while let last = ancestorStack.last, last.depth >= item.depth {
                ancestorStack.removeLast()
            }
            rowIndexByPath[item.row.path] = index
            parentIndexByRow.append(ancestorStack.last?.index)
            ancestorStack.append((item.depth, index))
        }

        let sameRowIdentities = rows.count == previous.rows.count
            && zip(rows, previous.rows).allSatisfy { $0.id == $1.id && $0.depth == $1.depth }
        let output = PreparedTreeFlatProjection(
            rows: rows,
            rowIndexByPath: rowIndexByPath,
            parentIndexByRow: parentIndexByRow,
            maxBytes: previous.maxBytes,
            isFetchingRoot: previous.isFetchingRoot,
            changed: rows != previous.rows
                || rowIndexByPath != previous.rowIndexByPath
                || parentIndexByRow != previous.parentIndexByRow,
            tableIdentityChanged: !sameRowIdentities,
            ranOnMainThread: ranOnMainThread,
            rowRemovalRanges: nil
        )
        prepared = output
        return output
    }

    func retire() -> Bool {
        let ranOnMainThread = Thread.isMainThread
        prepared = nil
        previous = nil
        input = nil
        return ranOnMainThread
    }
}

/// Receipt presentation patch: remove only already-visible deleted identities and descendants.
/// It never re-DFSes the coordinator or re-evaluates Safety; wide array filtering/index rebuild
/// stay on this actor while the authoritative prune continues independently.
actor TreeDeletionPresentationWorker {
    private var matcher: DeletionPresentationPathMatcher?
    private var rootPath: String?
    private var previous: TreeFlatProjectionPreviousSnapshot?
    private var prepared: PreparedTreeFlatProjection?

    init(
        matcher: DeletionPresentationPathMatcher,
        rootPath: String,
        previous: TreeFlatProjectionPreviousSnapshot
    ) {
        self.matcher = matcher
        self.rootPath = rootPath
        self.previous = previous
    }

    func prepare() -> PreparedTreeFlatProjection? {
        guard let matcher, let rootPath, let previous, !Task.isCancelled else { return nil }
        let ranOnMainThread = Thread.isMainThread
        let removalRanges: [Range<Int>]
        if matcher.contains(rootPath) {
            removalRanges = previous.rows.isEmpty ? [] : [0..<previous.rows.count]
        } else {
            // v2026.07.20: every visible descendant has its visible parent before it in the flat
            // Tree. Therefore a receipt root either has one exact visible index followed by one
            // contiguous descendant segment, or has no visible rows at all. Do not scan/match all
            // 40k paths merely to discover those ranges.
            var candidates: [Range<Int>] = []
            candidates.reserveCapacity(matcher.roots.count)
            for path in matcher.roots {
                guard let start = previous.rowIndexByPath[path],
                      previous.rows.indices.contains(start) else { continue }
                let depth = previous.rows[start].depth
                var end = start + 1
                while end < previous.rows.count, previous.rows[end].depth > depth {
                    end += 1
                }
                candidates.append(start..<end)
            }
            candidates.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            merged.reserveCapacity(candidates.count)
            for range in candidates {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            removalRanges = merged
        }

        guard !removalRanges.isEmpty, !Task.isCancelled else {
            return PreparedTreeFlatProjection(
                rows: previous.rows,
                rowIndexByPath: previous.rowIndexByPath,
                parentIndexByRow: previous.parentIndexByRow,
                maxBytes: previous.maxBytes,
                isFetchingRoot: previous.isFetchingRoot,
                changed: false,
                tableIdentityChanged: false,
                ranOnMainThread: ranOnMainThread,
                rowRemovalRanges: nil
            )
        }

        var rows: [FlatTreeRow] = []
        let removedCount = removalRanges.reduce(0) { $0 + $1.count }
        rows.reserveCapacity(max(0, previous.rows.count - removedCount))
        var rangeIndex = 0
        for (index, row) in previous.rows.enumerated() {
            if index & 0xFF == 0, Task.isCancelled { return nil }
            while rangeIndex < removalRanges.count,
                  index >= removalRanges[rangeIndex].upperBound {
                rangeIndex += 1
            }
            let isRemoved = rangeIndex < removalRanges.count
                && removalRanges[rangeIndex].contains(index)
            if !isRemoved { rows.append(row) }
        }

        var rowIndexByPath: [String: Int] = [:]
        rowIndexByPath.reserveCapacity(rows.count)
        var parentIndexByRow: [Int?] = []
        parentIndexByRow.reserveCapacity(rows.count)
        var ancestorStack: [(depth: Int, index: Int)] = []
        ancestorStack.reserveCapacity(32)
        for (index, item) in rows.enumerated() {
            while let last = ancestorStack.last, last.depth >= item.depth {
                ancestorStack.removeLast()
            }
            rowIndexByPath[item.row.path] = index
            parentIndexByRow.append(ancestorStack.last?.index)
            ancestorStack.append((item.depth, index))
        }

        let output = PreparedTreeFlatProjection(
            rows: rows,
            rowIndexByPath: rowIndexByPath,
            parentIndexByRow: parentIndexByRow,
            maxBytes: previous.maxBytes,
            isFetchingRoot: previous.isFetchingRoot,
            changed: true,
            tableIdentityChanged: true,
            ranOnMainThread: ranOnMainThread,
            rowRemovalRanges: removalRanges
        )
        prepared = output
        return output
    }

    func retire() {
        prepared = nil
        previous = nil
        rootPath = nil
        matcher = nil
    }
}

/// A full NSTableView reload is required only when frozen row identity/order/depth changes.
/// Value-only updates (bytes, loading, verdict), selection, expansion, locale and hover redraw the
/// bounded visible row range instead of discarding the complete table on every SwiftUI update.
enum TreeTableReloadPolicy {
    static func requiresFullReload(previous: UInt64?, next: UInt64) -> Bool {
        previous != next
    }
}

/// Holds the prior NSTableView row generation until AppKit has swapped its parent snapshot, then
/// drops the potentially wide COW buffer on a non-main actor. This closes the second half of the
/// P1 boundary: background construction alone is insufficient if `updateNSView` releases the last
/// 40k-row owner synchronously on MainActor.
actor TreeFlatRowsRetirement {
    private var rows: [FlatTreeRow]?
    private var rowIndexByPath: [String: Int]?
    private var parentIndexByRow: [Int?]?

    init(
        rows: [FlatTreeRow],
        rowIndexByPath: [String: Int],
        parentIndexByRow: [Int?]
    ) {
        self.rows = rows
        self.rowIndexByPath = rowIndexByPath
        self.parentIndexByRow = parentIndexByRow
    }

    func retire() -> Bool {
        let ranOnMainThread = Thread.isMainThread
        rows = nil
        rowIndexByPath = nil
        parentIndexByRow = nil
        return ranOnMainThread
    }
}

/// v1.0 T3 / T5：多层下钻浏览器 + 列排序 + 键盘导航。
///
/// **v1.5.3 重构（用户反馈"选中 child 底部 delete 不可点击"）**：
/// 之前用「左侧 checkbox 多选 + 顶部 batchActionBar 批量按钮」的双轨方案
/// （所谓 v1.3.zzzz Phase 4-B），但 checkedPaths 是 TreeBrowserView 内部 @State，
/// 与 MainView 的 selection（基于 RowItem.id）完全独立——结果用户在树里勾选 child，
/// 主界面底部 delete 按钮永远 disabled。
///
    /// 新方案：**完全移除 checkbox 列与批量 toolbar**，每一行右侧直接挂一个红色
/// trash 行内按钮，单击 = 调 `onTrash(TreeRow)` 交给上层统一删除链路。
/// 所见即所删，与 Pearcleaner / DaisyDisk 行内删除手感一致；底部 delete 按钮
/// 改为只服务"清单视图"场景，不再与树形耦合。
///
/// 设计要点（参考 DaisyDisk / OmniDS / Pearcleaner）：
/// 1. 用递归 DisclosureGroup（而不是 OutlineGroup）—— OutlineGroup 在 Swift 6 严格并发
///    下要求 KeyPath 形式预先把整棵树构建好，而我们的数据是 lazy 按需取的。
/// 2. children 走 lazy 计算：DisclosureGroup 展开时才向 ScanCoordinator 询问下一层，
///    避免一开始就构建整棵树（PITFALLS §5.4 同款，4w 文件不能一次性 yield 给 List）。
/// 3. 数据来源是 `ScanCoordinator.directChildren(of:sortedBy:)`，按当前 `sortKey` 排序。
/// 4. 行内右键菜单：在 Finder 中显示 / 复制路径 / 移到废纸篓（与行内 trash 按钮共用 onTrash）。
/// 5. T5 新增：
///    - 列表头：大小 / 名称 / 数量 三列，点击切排序，再点切升降序
///    - 键盘导航：j/k 上下移动选中、h 折叠当前、l 展开当前、Enter 切展开、
///      Cmd+R 在 Finder 显示、Delete 删除当前选中（走 SafetyEngine forbid 闸门）
///    - 选中态：当前选中行用 selection 高亮 + accessibility focus
public struct TreeBrowserView: View {
    let coordinator: ScanCoordinator
    /// v2026.06.21 perf：单独订阅 `coordinator.treeBrowser`（独立 ObservableObject）。
    /// 旧版用 `coordinator.structuralRevision` / `coordinator.childrenCacheVersion`
    /// 作 @Published mirror，导致 ScanCoordinator 任一 @Published 变化也都触发
    /// MainView/sidebar/listResults 整体失效（dev 扫场景每秒 ≥5 次 body 重算）。
    /// 现在 4 个 revision 字段从 ScanCoordinator @Published 移除，
    /// TreeBrowserView 单独通过本字段订阅 store —— MainView body 不再因
    /// structural / tick / treeRevision / childrenCacheVersion 失效。
    let treeBrowser: TreeBrowserStore
    let rootPath: String
    /// Parent-owned reset channel. Tree keeps its selection local for AppKit performance, but a
    /// closed detail pane must still clear that real selection/highlight and allow the same row to
    /// be selected again immediately.
    let selectionResetRevision: UInt64
    /// 选中行变化时的回调；MainView 用它把 TreeRow 喂给右侧详情面板。
    /// 设计 bug A：之前 selectedPath 只活在 TreeBrowserView 内部，
    /// 外层 detailPane 永远拿不到，导致"选中一行没有详情"。
    let onSelect: ((TreeRow) -> Void)?
    let onSelectionCleared: (() -> Void)?
    /// 右键 / Delete / 行内 trash 按钮触发"移到废纸篓"时的回调。
    /// 上层必须先进入统一 DeleteSheet，再由 TrashPipeline 走 NSWorkspace.recycle。
    /// 给 nil 时 TreeNodeView 的右键菜单与行内 trash 按钮都不会展示，便于在 readonly 场景复用。
    let onTrash: ((TreeRow) -> Void)?
    /// 专业模式只允许 vendorPathRule 风险项发起严格 override 预检；默认 false 让其它复用场景
    /// 继续把所有 forbid 当作不可操作。
    let allowsVendorPathOverride: Bool
    /// v2026.06 用户反馈 #1：右键"刷新此目录"。点击时传 path 给上层，
    /// 上层调 [ScanCoordinator.rescanSubtree(at:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1529-L1545)
    /// 清掉按需子树缓存并 bump structuralRevision，本视图下一帧自动重拉。
    /// 给 nil 时菜单不展示该项（便于在 readonly 场景复用）。
    let onRefreshSubtree: ((String) -> Void)?
    /// v2026.06.18 **加入待处理**回调（购物车）。点击 contextMenu 的"加入待处理"项
    /// 把 (path, title, bytes, isDirectory) 透给上层，由上层调
    /// [StashStore.add](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift#L80-L82) 入库。
    /// 给 nil 时菜单不展示该项（保持向后兼容；readonly / 无 stash 场景仍可复用）。
    let onStash: ((TreeRow) -> Void)?
    /// v2026.06.18 **是否已加入待处理**查询。contextMenu 用它把"加入待处理"按钮置灰
    /// + 改文案"已在待处理列表"。给 nil 时按 `false` 处理（旧 callsite 不受影响）。
    let isStashed: ((String) -> Bool)?
    /// v2026.06.20 **AI 设置**——决定 tree 行的 sparkles AI 按钮是否真正"可点"。
    /// nil（旧 callsite）或 `!isReadyForUI` → 按钮以 disabled + 提示 "请先在设置中配置 AI"
    /// 的形式出现（与 List 视图行为对齐），让用户知道有这个功能但需要先去配。
    let aiSettings: AISettings?
    /// v2026.06.20 **AI 入口回调**。给 nil（旧 callsite）时按钮根本不出现；
    /// 给值后无论 aiSettings 是否就绪都会出现按钮，未就绪时按 disabled。
    let onAskAI: ((TreeRow) -> Void)?

    /// v1.5 P2 / Q1：可选的"全局排序键" binding。
    ///
    /// 设计动机（review-swarm Q1 根因）：
    /// 之前 TreeBrowserView 自己持 `@State private var sortKey: TreeSortKey = .sizeDesc`，
    /// 与 [AppSettings.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift#L339)
    /// 完全解耦。结果用户在工具栏点"全局排序图标"切到 nameAsc，主列表反应了，
    /// 但切到「树形视图」依然是初始 sizeDesc，体验严重不一致。
    ///
    /// 现在给一个**可选** binding：
    /// - 有值（MainView 的 callsite 已升级）→ 列头点击 / 全局菜单切换双向同步
    /// - nil（测试桩 / 其它复用场景）→ fallback 走本地 @State，保持向后兼容
    let globalSortKey: Binding<MainListSortKey>?

    /// SafetyEngine 静态共享：为测试用的普通模式 sanitize 提供硬边界过滤。
    nonisolated static let safety = SafetyEngine()

    /// Tree 的唯一展开资格合同。子树存在未完整后代不影响下钻；只有当前节点自身
    /// 不可访问时才停止展开。AppKit、SwiftUI、后台投影和测试 helper 必须共用本方法，
    /// 避免再次出现“父行被锁但旧子项仍显示”的分裂状态。
    static func canExpand(_ row: TreeRow) -> Bool {
        row.isDirectory && row.hasChildren && row.accessState == .normal
    }

    /// Tree deletion eligibility shared by keyboard, context menu, AppKit canvas and SwiftUI row.
    /// A lazy pending row is not a zero-byte row: its metrics are unknown until measurement ends,
    /// so no entry point may form a deletion intent from it.
    static func canInitiateDeletion(
        _ row: TreeRow,
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        allowsVendorPathOverride: Bool
    ) -> Bool {
        !row.isSizePending && DeletionEntryPolicy.canInitiate(
            verdict: verdict,
            rejection: rejection,
            hasCompleteAccessEvidence: row.hasCompleteAccessEvidence,
            // This Tree instance is the Professional surface. An incomplete row may only
            // initiate the typed target-revalidation path; MainView still cannot submit it
            // without a `ScanIncompleteOverrideRequest` minted by TrashPipeline.
            allowsTargetRevalidation: allowsVendorPathOverride,
            allowsVendorPathOverride: allowsVendorPathOverride
        )
    }

    /// Flat-row authority gate. v2026.07.20 contract: direct-child identities may be selected and
    /// revealed immediately, but `isLoadingChildren` remains true until exact subtree metrics and
    /// the requested ordering commit. Destructive actions must wait for that same terminal.
    static func canInitiateDeletion(
        _ flat: FlatTreeRow,
        allowsVendorPathOverride: Bool
    ) -> Bool {
        !flat.isLoadingChildren && canInitiateDeletion(
            flat.row,
            verdict: flat.verdict,
            rejection: flat.rejection,
            allowsVendorPathOverride: allowsVendorPathOverride
        )
    }

    static func shouldTraverseDescendants(of row: TreeRow, expanded: Bool) -> Bool {
        expanded && canExpand(row)
    }

    /// v2026.06.22 perf：path → (SafetyVerdict, SafetyRejection) 进程内缓存
    /// （**Instruments Time Profiler 取证**）。
    ///
    /// 33334.md（commit 5fe7e91 后第二刀取证）显示 [rebuildFlatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L411-L451)
    /// 一次跑 139ms 中 124ms（89%）全部在 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L212)：
    ///   - evaluateStandardized 58.8ms
    ///   - resolvedSymlinkPath 31.7ms（含 realpath syscall）
    ///   - URL.init(fileURLWithPath:) 11.7ms
    ///   - URL.standardizedFileURL.getter 6.9ms
    /// 这些都是 path-only 输入 → 进程生命周期内**确定性输出**（SafetyEngine 规则
    /// 库是编译期常量 + home 也是常量），完美适合纯路径缓存。
    ///
    /// 命中场景：扫描结束、展开或排序产生下一份后台 projection 时，上万节点的 99%+
    /// path 已在上一帧出现。理论上单 path 加速倍数 = 1000x（dict get vs URL
    /// standardize + realpath）。
    ///
    /// 并发：生产调用者是 TreeFlatProjectionWorker，明确不在 MainActor；NSLock 只保护
    /// 全局缓存字典，真正的 SafetyEngine 计算始终放在锁外。
    ///
    /// 容量上限 50k：dev 扫几百根 + 上万节点，按目录数估算 5w 上限足够覆盖；
    /// 超过 50k 直接 reset（不做 LRU 是因为 dev 工具单次会话规模可控，简洁优先）。
    fileprivate enum VerdictCache {
        private struct Key: Hashable {
            let cacheNamespace: UUID
            let path: String
        }

        private struct Value: Sendable {
            let verdict: SafetyVerdict
            let rejection: SafetyRejection
        }

        nonisolated(unsafe) private static var cache: [Key: Value] = [:]
        private static let lock = NSLock()
        private static let maxEntries = 50_000

        static func evaluation(
            for path: String,
            snapshot: TreeDeletionEvaluationSnapshot
        ) -> (verdict: SafetyVerdict, rejection: SafetyRejection) {
            let key = Key(cacheNamespace: snapshot.cacheNamespace, path: path)
            lock.lock()
            if let hit = cache[key] {
                lock.unlock()
                return (hit.verdict, hit.rejection)
            }
            lock.unlock()
            // 真算放在锁外：SafetyEngine.evaluate 可能 100us+，
            // 锁内只做 dict 读写，避免阻塞并发评估。
            let current = snapshot.evaluate(path: path)
            let value = Value(verdict: current.verdict, rejection: current.rejection)
            lock.lock()
            if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
            cache[key] = value
            lock.unlock()
            return (value.verdict, value.rejection)
        }
    }

    /// v1.5 P2 / Q1：本地 fallback @State —— 仅在 `globalSortKey == nil` 时生效。
    /// 有 globalSortKey 时通过 `effectiveSortKey` 的 getter 优先读外部 binding，
    /// 这个 @State 完全不参与 body 渲染（也就不会触发额外 invalidation）。
    @Environment(\.locale) private var locale
    @State private var sortKey: TreeSortKey = .sizeDesc
    @State private var selectedPath: String?
    /// 各节点是否展开（path -> Bool）；放在父视图集中管理，
    /// 才能让 h/l 键盘事件去操控"当前选中节点"的展开状态。
    @State private var expanded: [String: Bool] = [:]

    /// **v1.5.4 性能修复**：扁平化的可见行数组（包含 root 直接孩子 + 所有展开节点的子项）。
    /// 每行附带 [depth](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 决定缩进，还有 [maxBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 用来归一化体积条。
    ///
    /// 旧版 [TreeNodeView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 在每个节点 body 内递归调 `coordinator.directChildren(...)` + 嵌套自身，
    /// 一次操作（含键盘的 4 次 visibleRows）等于把整棵展开树重新拍平多次，
    /// 4w 节点级 200~500ms 卡顿。改为冻结 flatRows + 原生 NSTableView 后：
    /// - 重算只发生在 expanded / sortKey / rootPath / coordinator.treeRevision 变化时
    /// - SwiftUI 只交换 COW 根，AppKit 仅在 snapshot revision 变化时 reload
    @State private var flatRows: [FlatTreeRow] = []
    /// Worker materializes the identity/index map together with flatRows. Selection reconciliation
    /// and AppKit keyboard/focus updates must never linearly rescan a 40k-row snapshot on MainActor.
    @State private var flatRowIndexByPath: [String: Int] = [:]
    @State private var flatRowParentIndexByRow: [Int?] = []
    /// Content revision owns COW retirement; identity revision alone decides whether NSTableView
    /// needs a structural reload. Size/verdict/loading-only changes redraw the bounded viewport.
    @State private var flatRowsContentRevision: UInt64 = 0
    @State private var flatRowsIdentityRevision: UInt64 = 0
    @State private var pendingRowRemovalDelta: TreeTableRowRemovalDelta?
    /// MainActor request ownership. A newer root/sort/expanded/cache revision cancels the previous
    /// worker and starts immediately; source CAS below prevents a completed stale snapshot from
    /// publishing. User interaction must never await obsolete presentation work.
    @State private var flatProjectionRequestRevision: UInt64 = 0
    @State private var flatProjectionTask: Task<Void, Never>? = nil
    /// 顶层根孩子的 maxBytes（决定体积条长度的归一化分母）。
    /// 只跟随 root 直接孩子最大值变化，与 expanded 解耦避免每次展开重算。
    @State private var maxBytes: Int64 = 0
    /// **v1.5.4**：是否处于"首次拉 root 子项"的等待态。
    /// 替代旧版 `coordinator.isFetchingChildren(of: rootPath, sortedBy:)` 的实时调用——
    /// flatRows 重建时同步推断，view body 只读 state，少一次 coordinator 调用。
    @State private var isFetchingRoot: Bool = false
    /// 只订阅 `ScanCoordinator.$isScanning`，避免 `ScanCoordinator.objectWillChange`
    /// 的高频 snapshot/progress 发布把整棵 SwiftUI List 拖进刷新。
    @State private var isScanningSnapshot: Bool = false
    /// Typed primary ownership snapshot. `isScanning` alone is false during settlement, so using
    /// it for disclosure admission reintroduced Tree I/O/projection work while the predecessor was
    /// still retiring. This narrow state is refreshed only by the two ownership publishers below.
    @State private var hasActivePrimaryScanOwnershipSnapshot: Bool = false
    /// v2026.07.19 settlement regression fix: the old finished Tree stays visible while a
    /// cancelled primary producer settles, but it is disclosure-only. Cache the coordinator's
    /// central action authority through narrow publishers so Tree does not subscribe to all scan
    /// progress merely to hide destructive callbacks during that ownership gap.
    @State private var resultActionsAuthorizedSnapshot: Bool = false
    public init(coordinator: ScanCoordinator,
                rootPath: String,
                selectionResetRevision: UInt64 = 0,
                onSelect: ((TreeRow) -> Void)? = nil,
                onSelectionCleared: (() -> Void)? = nil,
                onTrash: ((TreeRow) -> Void)? = nil,
                allowsVendorPathOverride: Bool = false,
                onRefreshSubtree: ((String) -> Void)? = nil,
                onStash: ((TreeRow) -> Void)? = nil,
                isStashed: ((String) -> Bool)? = nil,
                aiSettings: AISettings? = nil,
                onAskAI: ((TreeRow) -> Void)? = nil,
                globalSortKey: Binding<MainListSortKey>? = nil) {
        self.coordinator = coordinator
        // 直接从 coordinator 取嵌套的 store 作 @ObservedObject 订阅。
        // ScanCoordinator.treeBrowser 是 `public let`，跨实例稳定，符合 ObservedObject 契约。
        self.treeBrowser = coordinator.treeBrowser
        self.rootPath = rootPath
        self.selectionResetRevision = selectionResetRevision
        self.onSelect = onSelect
        self.onSelectionCleared = onSelectionCleared
        self.onTrash = onTrash
        self.allowsVendorPathOverride = allowsVendorPathOverride
        self.onRefreshSubtree = onRefreshSubtree
        self.onStash = onStash
        self.isStashed = isStashed
        self.aiSettings = aiSettings
        self.onAskAI = onAskAI
        self.globalSortKey = globalSortKey
    }

    /// v1.5 P2 / Q1：当前生效的 [TreeSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L191)。
    /// 优先读 `globalSortKey`，没传才用本地 @State。
    private var effectiveSortKey: TreeSortKey {
        if let g = globalSortKey { return .from(global: g.wrappedValue) }
        return sortKey
    }

    /// v1.5 P2 / Q1：给 TreeColumnHeader 用的 binding。
    /// 列头点击 → set 自动按 `globalSortKey != nil` 选择写入通道。
    /// 写全局通道时通过 `TreeSortKey.asGlobal` 回译，主列表 / 大文件视图同帧感知。
    private var headerSortBinding: Binding<TreeSortKey> {
        Binding(
            get: { effectiveSortKey },
            set: { newKey in
                if let g = globalSortKey {
                    g.wrappedValue = newKey.asGlobal
                } else {
                    sortKey = newKey
                }
            }
        )
    }

    public var body: some View {
        // v1.5.4：body 不再调 directChildren / isFetchingChildren——所有可见行的源数据
        // 都收口在 [flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
        // 这一份扁平 @State 里。view 重算只读 state，重建在 onChange / onAppear 里发生，
        // 不会被 SwiftUI 的 diff 频繁触发递归。
        VStack(spacing: 0) {
            TreeColumnHeader(sortKey: headerSortBinding)
            Divider()
            if flatRows.isEmpty {
                VStack(spacing: 8) {
                    if hasActivePrimaryScanOwnershipSnapshot {
                        ProgressView()
                            .controlSize(.small)
                        Text("tree.loading.scanning", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else if isFetchingRoot {
                        ProgressView()
                            .controlSize(.small)
                        Text("tree.loading.children", bundle: .module)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        Image(systemName: "tree")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("tree.empty.no_expandable", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Instruments 55555.trace：订阅隔离后仍有 55 次主线程 hang / 449 次 hitch，
                // SwiftUI updates 表为空，热区基本落在系统 AppKit/SwiftUI 地址。
                // 结论：这里不能再让 SwiftUI List 通过 NSHostingView 承载万级滚动行。
                // 改为原生 NSTableView + 自绘行，固定 rowHeight、复用 row view，
                // 保留现有 flatRows / selection / action 回调边界。
                AppKitFlatTreeTable(
                    rows: flatRows,
                    rowIndexByPath: flatRowIndexByPath,
                    parentIndexByRow: flatRowParentIndexByRow,
                    contentRevision: flatRowsContentRevision,
                    identityRevision: flatRowsIdentityRevision,
                    removalDelta: pendingRowRemovalDelta,
                    maxBytes: maxBytes,
                    locale: locale,
                    selectedPath: $selectedPath,
                    expanded: expanded,
                    onToggleExpand: { path in toggleExpansionFor(path: path) },
                    onTrash: resultActionsAuthorizedSnapshot
                        ? onTrash.map { _ in requestTrash(_:) }
                        : nil,
                    allowsVendorPathOverride: allowsVendorPathOverride,
                    onRefreshSubtree: onRefreshSubtree,
                    onStash: resultActionsAuthorizedSnapshot
                        ? onStash.map { _ in requestStash(_:) }
                        : nil,
                    isStashed: { path in isStashed?(path) ?? false },
                    aiSettings: aiSettings,
                    onAskAI: onAskAI
                )
            }
        }
        .onAppear {
            isScanningSnapshot = coordinator.isScanning
            hasActivePrimaryScanOwnershipSnapshot = coordinator.hasActivePrimaryScanOwnership
            resultActionsAuthorizedSnapshot = coordinator.canUseCurrentScanResultsForActions
            rebuildFlatRows()
        }
        // v1.5.4：四个触发器覆盖所有可能改变 flatRows 内容的事件。
        // 缺一个就会出现"展开后没出现"或"删除后还在"。
        //
        // v2026.07.18 P1：expanded 是最高频触发源，但不能再走旧的 MainActor 增量
        // patch。旧 patch 仍会递归 DFS、构造宽数组并逐行算 Safety verdict，只是缩小了
        // 输入规模，无法保证 UI 线程边界。所有展开变化现在统一生成不可变 source，交给
        // TreeFlatProjectionWorker；请求 revision + coordinator source CAS 防止旧结果覆盖。
        .onValueChange(of: expanded) { oldExp, newExp in
            applyExpandedChange(old: oldExp, new: newExp)
        }
        // v1.5 P2 / Q1：监听"生效排序键"——它内部已根据 globalSortKey/本地 @State 合流，
        // 两边任意一侧切换都会触发 rebuildFlatRows，保证树视图与全局排序图标同步。
        .onValueChange(of: effectiveSortKey) { _, _ in rebuildFlatRows() }
        .onValueChange(of: rootPath) { _, _ in
            // 切扫描根：清掉旧 expanded 防止脏 path 残留撑起 flatRows
            expanded.removeAll(keepingCapacity: true)
            rebuildFlatRows()
        }
        .onValueChange(of: selectionResetRevision) { _, _ in
            // v2026.07.20: closing/resetting the parent detail pane is a real selection reset,
            // not a cosmetic hide. Clearing the binding also deselects NSTableView on its next
            // representable update, so the same row can immediately reopen detail.
            guard selectedPath != nil else { return }
            selectedPath = Self.selectionAfterExternalReset(current: selectedPath)
            onSelectionCleared?()
        }
        // Step 2 P0-2 / 2026-06：从 `coordinator.treeRevision` 切到
        // `coordinator.structuralRevision` —— 只在节点新增/删除/排序键变化时重建 flatRows，
        // 不再被流式 publishSnapshot 的 0.4s tick（仅 bytes 变化）拖着整树重算。
        // tickRevision 通过其它 @Published 入口（如 RowItem 自身）驱动 RowView 内部刷新数值，
        // 这里 view 不订阅。
        //
        // 三个 onReceive 走同一组工具方法——之前直接在 body 里堆 3 个 onChange 闭包让
        // SwiftUI ViewBuilder 类型推断超时（"unable to type-check this expression"）。
        // 这里只挂一个 onChange，其它两个走 modifier 链上下方继续，避免类型膨胀。
        .onReceive(treeBrowser.$structuralRevision.removeDuplicates()) { _ in
            handleStructuralBump()
        }
        .onReceive(treeBrowser.$deletionPresentationRevision.removeDuplicates()) { _ in
            applyDeletionPresentation()
        }
        .onReceive(treeBrowser.$childrenCacheVersion.removeDuplicates()) { _ in
            handleChildrenCacheBump()
        }
        .onReceive(coordinator.$isScanning.removeDuplicates()) { nowScanning in
            isScanningSnapshot = nowScanning
            hasActivePrimaryScanOwnershipSnapshot = coordinator.hasActivePrimaryScanOwnership
            resultActionsAuthorizedSnapshot = coordinator.canUseCurrentScanResultsForActions
            handleScanningToggle(nowScanning: nowScanning)
        }
        .onReceive(coordinator.$scanPhase.removeDuplicates()) { _ in
            hasActivePrimaryScanOwnershipSnapshot = coordinator.hasActivePrimaryScanOwnership
            resultActionsAuthorizedSnapshot = coordinator.canUseCurrentScanResultsForActions
            if coordinator.scanPhase == .idle, !coordinator.isScanning {
                rebuildFlatRows()
            }
        }
        .onReceive(coordinator.$snapshot.map(\.isFinished).removeDuplicates()) { _ in
            // `cancel()` can clear an already-idle snapshot without changing scanPhase or
            // isScanning. Keep destructive affordances in sync through this narrow Bool stream;
            // event-time guards remain the final authority.
            resultActionsAuthorizedSnapshot = coordinator.canUseCurrentScanResultsForActions
        }
        .onValueChange(of: selectedPath) { _, new in
            guard let new else { return }
            let row = flatRowIndexByPath[new]
                .flatMap { flatRows.indices.contains($0) ? flatRows[$0].row : nil }
                ?? coordinator.row(for: new)
            guard let row else { return }
            onSelect?(row)
        }
        .onDisappear {
            // v2026.07.17 scan-ownership fix: Tree fetches belong to the visible
            // Tree surface, not to the completed primary snapshot. Leaving the
            // tab/window must stop shallow/deep disk work while preserving cached
            // rows and the finished scan result for a later return.
            cancelFlatProjection()
            coordinator.cancelOnDemandTreeScansPreservingResults()
        }
        // v2026.07.16：键盘命令统一由下方原生 NSTableView.keyDown 处理。旧的
        // SwiftUI onKeyPress（macOS 14+）与 AppKit 处理器重复，既阻断 Ventura，
        // 又可能让同一按键经过两套状态路径。
    }

    /// Tree 只产生删除意图；确认、运行中 App 决策和最终执行统一由 MainView 的
    /// DeleteSheet 路由负责，避免 Tree 自己先弹一次、Large Files 又完全不弹。
    private func requestTrash(_ row: TreeRow) {
        // The narrow published snapshot controls presentation, but a queued AppKit menu/keyboard
        // event can arrive before SwiftUI replaces an old callback. Re-check the same central
        // authority at event time so a predecessor Tree can never act during settlement.
        guard coordinator.canUseCurrentScanResultsForActions else { return }
        onTrash?(row)
    }

    private func requestStash(_ row: TreeRow) {
        guard coordinator.canUseCurrentScanResultsForActions else { return }
        onStash?(row)
    }

    // MARK: - flatRows 重建（v1.5.4 性能修复）

    /// 把 root 直接孩子 + 所有展开节点的子项按 DFS 顺序拍平到 [flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
    /// 由 onChange / onAppear 显式触发；body 不再做这件事。
    /// v2026.07.18 P1：本方法只冻结每个 expanded parent 的 COW child array 和 request
    /// revision。DFS、FlatTreeRow/Set 构造、SafetyEngine verdict 以及宽快照比较全部由
    /// TreeFlatProjectionWorker 完成；MainActor 最终只做 revision/CAS 与 O(1) storage swap。
    private func rebuildFlatRows() {
        // v2026.07.19: settlement keeps the predecessor presentation frozen. Never launch a wide
        // DFS/verdict projection just because isScanning flipped false; the idle edge below will
        // rebuild once the replacement owns a real frame.
        if case .settling = coordinator.scanPhase { return }
        flatProjectionRequestRevision &+= 1
        let requestRevision = flatProjectionRequestRevision
        flatProjectionTask?.cancel()
        let expandedPaths = Set(expanded.lazy.compactMap { $0.value ? $0.key : nil })
        let source = coordinator.makeTreeFlatProjectionSource(
            rootPath: rootPath,
            sortedBy: effectiveSortKey,
            expandedPaths: expandedPaths
        )
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        GSYLog.info(
            .scan,
            "tree.projection stage=request kind=full request_revision=\(requestRevision) "
                + "source_revision=\(source.revision.sourceRevision) root_rows=\(source.rootRows.count) "
                + "expanded_count=\(expandedPaths.count) fetching_count=\(source.fetchingPaths.count)"
        )
        let previous = TreeFlatProjectionPreviousSnapshot(
            rows: flatRows,
            rowIndexByPath: flatRowIndexByPath,
            parentIndexByRow: flatRowParentIndexByRow,
            maxBytes: maxBytes,
            isFetchingRoot: isFetchingRoot
        )
        let deletionSnapshot = source.deletionEvaluation
        let input = TreeFlatProjectionWorkerInput(
            rootRows: source.rootRows,
            childrenByParent: source.childrenByParent,
            expandedPaths: expandedPaths,
            fetchingPaths: source.fetchingPaths,
            isFetchingRoot: source.isFetchingRoot,
            receiptTombstones: source.receiptTombstones,
            evaluator: TreeFlatProjectionEvaluator { path in
                Self.VerdictCache.evaluation(for: path, snapshot: deletionSnapshot)
            }
        )
        let worker = TreeFlatProjectionWorker(input: input, previous: previous)
        let task = Task { @MainActor in
            guard requestRevision == flatProjectionRequestRevision, !Task.isCancelled else {
                GSYLog.notice(
                    .scan,
                    "tree.projection stage=drop kind=full reason=superseded_before_prepare "
                        + "request_revision=\(requestRevision) current_revision=\(flatProjectionRequestRevision)"
                )
                _ = await worker.retire()
                return
            }
            var prepared = await worker.prepare()
            let sourceIsCurrent = coordinator.treeFlatProjectionSourceIsCurrent(source.revision)
            guard requestRevision == flatProjectionRequestRevision,
                  !Task.isCancelled,
                  sourceIsCurrent else {
                GSYLog.notice(
                    .scan,
                    "tree.projection stage=drop kind=full reason=stale_after_prepare "
                        + "request_revision=\(requestRevision) current_revision=\(flatProjectionRequestRevision) "
                        + "source_current=\(sourceIsCurrent) cancelled=\(Task.isCancelled)"
                )
                prepared = nil
                _ = await worker.retire()
                return
            }
            guard let prepared else {
                GSYLog.warning(
                    .scan,
                    "tree.projection stage=drop kind=full reason=worker_no_output request_revision=\(requestRevision)"
                )
                _ = await worker.retire()
                if requestRevision == flatProjectionRequestRevision {
                    flatProjectionTask = nil
                }
                return
            }

            publishPreparedFlatProjection(prepared)
            let elapsedMilliseconds = Int(
                (max(0, ProcessInfo.processInfo.systemUptime - requestStartedAt) * 1_000).rounded()
            )
            GSYLog.info(
                .scan,
                "tree.projection stage=commit kind=full request_revision=\(requestRevision) "
                    + "row_count=\(prepared.rows.count) changed=\(prepared.changed) "
                    + "identity_changed=\(prepared.tableIdentityChanged) elapsed_ms=\(elapsedMilliseconds)"
            )
            flatProjectionTask = nil
            Task { @MainActor in
                // Let SwiftUI/AppKit consume the new COW roots before the worker drops the old
                // generation on its generic executor.
                await Task.yield()
                _ = await worker.retire()
            }
        }
        flatProjectionTask = task
    }

    /// v2026.07.19：单点 disclosure 恢复基线的增量语义，但宽数组 patch、DFS 和新增行
    /// verdict 全部移到 worker。多点变化或不可见 path 才回退到完整后台 projection。
    private func applyExpandedChange(old: [String: Bool], new: [String: Bool]) {
        if case .settling = coordinator.scanPhase { return }
        let oldOpen = Set(old.compactMap { $1 ? $0 : nil })
        let newOpen = Set(new.compactMap { $1 ? $0 : nil })
        let added = newOpen.subtracting(oldOpen)
        let removed = oldOpen.subtracting(newOpen)
        guard added.count + removed.count == 1 else {
            rebuildFlatRows()
            return
        }
        let path = added.first ?? removed.first!
        guard flatRowIndexByPath[path] != nil else {
            rebuildFlatRows()
            return
        }
        startIncrementalProjection(
            path: path,
            isExpanding: added.first != nil,
            expandedPaths: newOpen
        )
    }

    private func startIncrementalProjection(
        path: String,
        isExpanding: Bool,
        expandedPaths: Set<String>
    ) {
        flatProjectionRequestRevision &+= 1
        let requestRevision = flatProjectionRequestRevision
        flatProjectionTask?.cancel()

        let subtreePrefix = path == "/" ? "/" : path + "/"
        let relevantExpandedPaths = Set(expandedPaths.filter {
            $0 == path || $0.hasPrefix(subtreePrefix)
        })
        let source = coordinator.makeTreeFlatProjectionSource(
            rootPath: path,
            sortedBy: effectiveSortKey,
            expandedPaths: relevantExpandedPaths
        )
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        GSYLog.info(
            .scan,
            "tree.projection stage=request kind=incremental request_revision=\(requestRevision) "
                + "source_revision=\(source.revision.sourceRevision) expanding=\(isExpanding) "
                + "root_rows=\(source.rootRows.count) expanded_count=\(relevantExpandedPaths.count)"
        )
        var childrenByParent = source.childrenByParent
        childrenByParent[path] = source.rootRows
        var fetchingPaths = source.fetchingPaths
        if source.isFetchingRoot { fetchingPaths.insert(path) }

        let previous = TreeFlatProjectionPreviousSnapshot(
            rows: flatRows,
            rowIndexByPath: flatRowIndexByPath,
            parentIndexByRow: flatRowParentIndexByRow,
            maxBytes: maxBytes,
            isFetchingRoot: isFetchingRoot
        )
        let deletionSnapshot = source.deletionEvaluation
        let worker = TreeIncrementalProjectionWorker(
            input: TreeIncrementalProjectionWorkerInput(
                togglePath: path,
                isExpanding: isExpanding,
                childrenByParent: childrenByParent,
                expandedPaths: relevantExpandedPaths,
                fetchingPaths: fetchingPaths,
                receiptTombstones: source.receiptTombstones,
                evaluator: TreeFlatProjectionEvaluator { candidatePath in
                    Self.VerdictCache.evaluation(
                        for: candidatePath,
                        snapshot: deletionSnapshot
                    )
                }
            ),
            previous: previous
        )
        let task = Task { @MainActor in
            guard requestRevision == flatProjectionRequestRevision, !Task.isCancelled else {
                GSYLog.notice(
                    .scan,
                    "tree.projection stage=drop kind=incremental reason=superseded_before_prepare "
                        + "request_revision=\(requestRevision) current_revision=\(flatProjectionRequestRevision)"
                )
                _ = await worker.retire()
                return
            }
            var prepared = await worker.prepare()
            let sourceIsCurrent = coordinator.treeFlatProjectionSourceIsCurrent(source.revision)
            guard requestRevision == flatProjectionRequestRevision,
                  !Task.isCancelled,
                  sourceIsCurrent else {
                GSYLog.notice(
                    .scan,
                    "tree.projection stage=drop kind=incremental reason=stale_after_prepare "
                        + "request_revision=\(requestRevision) current_revision=\(flatProjectionRequestRevision) "
                        + "source_current=\(sourceIsCurrent) cancelled=\(Task.isCancelled)"
                )
                prepared = nil
                _ = await worker.retire()
                return
            }
            guard let prepared else {
                GSYLog.warning(
                    .scan,
                    "tree.projection stage=drop kind=incremental reason=worker_no_output "
                        + "request_revision=\(requestRevision)"
                )
                _ = await worker.retire()
                if requestRevision == flatProjectionRequestRevision {
                    flatProjectionTask = nil
                    rebuildFlatRows()
                }
                return
            }

            publishPreparedFlatProjection(prepared)
            let elapsedMilliseconds = Int(
                (max(0, ProcessInfo.processInfo.systemUptime - requestStartedAt) * 1_000).rounded()
            )
            GSYLog.info(
                .scan,
                "tree.projection stage=commit kind=incremental request_revision=\(requestRevision) "
                    + "row_count=\(prepared.rows.count) changed=\(prepared.changed) "
                    + "identity_changed=\(prepared.tableIdentityChanged) elapsed_ms=\(elapsedMilliseconds)"
            )
            flatProjectionTask = nil
            Task { @MainActor in
                await Task.yield()
                _ = await worker.retire()
            }
        }
        flatProjectionTask = task
    }

    private func publishPreparedFlatProjection(_ prepared: PreparedTreeFlatProjection) {
        guard prepared.changed else { return }
        let previousRowCount = flatRows.count
        let previousIdentityRevision = flatRowsIdentityRevision
        flatRows = prepared.rows
        flatRowIndexByPath = prepared.rowIndexByPath
        flatRowParentIndexByRow = prepared.parentIndexByRow
        maxBytes = prepared.maxBytes
        isFetchingRoot = prepared.isFetchingRoot
        flatRowsContentRevision &+= 1
        if prepared.tableIdentityChanged {
            let nextIdentityRevision = previousIdentityRevision &+ 1
            if let ranges = prepared.rowRemovalRanges, !ranges.isEmpty {
                pendingRowRemovalDelta = TreeTableRowRemovalDelta(
                    baseIdentityRevision: previousIdentityRevision,
                    nextIdentityRevision: nextIdentityRevision,
                    baseRowCount: previousRowCount,
                    nextRowCount: prepared.rows.count,
                    ranges: ranges
                )
            } else {
                pendingRowRemovalDelta = nil
            }
            flatRowsIdentityRevision = nextIdentityRevision
        } else {
            pendingRowRemovalDelta = nil
        }

        // v2026.07.19 deletion/viewport regression: projection publication must never invent a
        // selection. If the selected row disappeared, clear it; otherwise retain it verbatim.
        // Auto-selecting the first row coupled an async data refresh to table scrolling and made a
        // successful deletion jump back to the top of a large Tree.
        let reconciledSelection = Self.selectionAfterProjection(
            current: selectedPath,
            rowIndexByPath: prepared.rowIndexByPath
        )
        if selectedPath != nil, reconciledSelection == nil {
            selectedPath = nil
            onSelectionCleared?()
        }
    }

    nonisolated static func selectionAfterProjection(
        current: String?,
        rowIndexByPath: [String: Int]
    ) -> String? {
        guard let current, rowIndexByPath[current] != nil else { return nil }
        return current
    }

    nonisolated static func selectionAfterExternalReset(current: String?) -> String? {
        _ = current
        return nil
    }

    private func cancelFlatProjection() {
        flatProjectionRequestRevision &+= 1
        flatProjectionTask?.cancel()
        flatProjectionTask = nil
    }

    /// **可测的 pure helper**：把"老 flatRows + 单点 expand/collapse"映射成"新 flatRows"。
    ///
    /// 单测用它保留旧“增量结果 vs 整树结果”的等价性样本；生产已在 v2026.07.18
    /// 统一迁到 TreeFlatProjectionWorker，禁止把此递归 helper 重新接回 MainActor。
    ///
    /// - parameters:
    ///   - old: 老 flatRows
    ///   - togglePath: 被翻转的 path（必须能在 old 里找到）
    ///   - isExpanding: true=展开 / false=折叠
    ///   - childrenProvider: (parentPath, sortKey) -> 直接子项，按 sortKey 排好序
    ///   - expandedAfter: 翻转后的 expanded 状态（用于决定新子树里哪些孙子也要拍平）
    ///   - sortKey: 当前排序键（透传给 childrenProvider）
    ///   - evaluator: SafetyEngine 评估函数，与 [computeVerdicts](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L330)
    ///     共用
    /// - returns: 若 togglePath 不在 old → nil（caller fallback 整树重建），否则新 flatRows
    static func applyExpansionPatch(
        old: [FlatTreeRow],
        togglePath: String,
        isExpanding: Bool,
        sortKey: TreeSortKey,
        expandedAfter: [String: Bool],
        childrenProvider: (String, TreeSortKey) -> [TreeRow],
        evaluator: (String) -> SafetyVerdict
    ) -> [FlatTreeRow]? {
        guard let idx = old.firstIndex(where: { $0.row.path == togglePath }) else {
            return nil
        }
        let parentDepth = old[idx].depth
        if isExpanding {
            guard Self.canExpand(old[idx].row) else { return old }
            var pairs: [(TreeRow, Int)] = []
            collectDescendantPairs(
                parent: togglePath, depth: parentDepth + 1,
                sortKey: sortKey, expanded: expandedAfter,
                childrenProvider: childrenProvider, into: &pairs
            )
            var out = old
            out.insert(contentsOf: computeVerdicts(for: pairs, using: evaluator),
                       at: idx + 1)
            return out
        } else {
            var end = idx + 1
            while end < old.count && old[end].depth > parentDepth { end += 1 }
            var out = old
            if end > idx + 1 { out.removeSubrange((idx + 1)..<end) }
            return out
        }
    }

    /// 仅供上方等价性测试 helper：递归收集子树 (row, depth)，不依赖 coordinator。
    /// 生产 DFS 只能使用可取消的 TreeFlatProjectionWorker 迭代栈。
    private static func collectDescendantPairs(
        parent: String, depth: Int,
        sortKey: TreeSortKey,
        expanded: [String: Bool],
        childrenProvider: (String, TreeSortKey) -> [TreeRow],
        into out: inout [(TreeRow, Int)]
    ) {
        let kids = childrenProvider(parent, sortKey)
        for k in kids {
            out.append((k, depth))
            if shouldTraverseDescendants(of: k, expanded: expanded[k.path] == true) {
                collectDescendantPairs(
                    parent: k.path, depth: depth + 1,
                    sortKey: sortKey, expanded: expanded,
                    childrenProvider: childrenProvider, into: &out
                )
            }
        }
    }

    /// **v2026.06 Step 1【P0-1 verdict 缓存】**：把 (row, depth) 序列一次性映射成
    /// 带 verdict 的 [FlatTreeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
    ///
    /// 关键点 1：evaluator 是注入的——生产代码传 `Self.safety.evaluate(path:).0`，
    /// 测试 [FlatTreeRowVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)
    /// 传 [CountingEvaluator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)
    /// 计调用次数。这是把 SafetyEngine 从 SwiftUI hot path 拆下来的契约接缝。
    ///
    /// 关键点 2：每行 evaluator 只调一次。生产的 4w 行计算现在由 worker 后台完成；
    /// 后续 AppKit/SwiftUI 重绘只读冻结 verdict，不再回 SafetyEngine。
    static func computeVerdicts(
        for pairs: [(TreeRow, Int)],
        using evaluator: (String) -> SafetyVerdict
    ) -> [FlatTreeRow] {
        computeDeletionEvaluations(for: pairs) {
            (evaluator($0), SafetyRejection.ok)
        }
    }

    /// 生产树行同时冻结 verdict + rejection。只存 verdict 会让 UI 无法区分
    /// “专业模式可严格确认的 vendorPathRule”与系统/凭据等真正硬禁区，最终在预检前
    /// 把两者一并锁死。
    static func computeDeletionEvaluations(
        for pairs: [(TreeRow, Int)],
        using evaluator: (String) -> (verdict: SafetyVerdict, rejection: SafetyRejection)
    ) -> [FlatTreeRow] {
        var out: [FlatTreeRow] = []
        out.reserveCapacity(pairs.count)
        for (row, depth) in pairs {
            let evaluation = evaluator(row.path)
            out.append(FlatTreeRow(
                row: row,
                depth: depth,
                verdict: evaluation.verdict,
                rejection: evaluation.rejection
            ))
        }
        return out
    }

    /// v2026.07.18 P1：structural bump 只消费 prune hint，不再在 MainActor 做 O(N)
    /// removeAll/max/selection 扫描。非扫描态统一交给 worker 生成新冻结快照；扫描中仍冻结，
    /// 结束边沿再收敛到终态。
    private func handleStructuralBump() {
        _ = coordinator.consumeLastPrunedPaths()
        // v2026.07.19 regression fix: `.settling` intentionally exposes
        // `isScanning == false` while the old producer is still retiring.  Treating that Boolean
        // edge as idle launched a terminal-width DFS/verdict projection on MainActor handoff.
        // Only the typed idle phase may converge the frozen Tree presentation.
        guard coordinator.scanPhase == .idle, !isScanningSnapshot else {
            // 扫描中不要让树形 List 持续 diffRows/endUpdates。用户此时主要在看
            // statusBar 进度和滚动已有结果；最终结构在扫描结束边沿统一刷新。
            return
        }
        rebuildFlatRows()
    }

    /// v2026.07.20：receipt 到达后先对当前 frozen rows 做窄删除 patch，
    /// 不等待全量 prune，也不重新读取 Tree/Safety。新 revision 会拒绝旧 patch，
    /// 新扫描清空 paths 后旧 worker 无权发布到新会话。
    private func applyDeletionPresentation() {
        let presentationRevision = treeBrowser.deletionPresentationRevision
        let paths = treeBrowser.deletionPresentationPaths
        guard !paths.isEmpty else { return }

        flatProjectionRequestRevision &+= 1
        let requestRevision = flatProjectionRequestRevision
        flatProjectionTask?.cancel()
        let previous = TreeFlatProjectionPreviousSnapshot(
            rows: flatRows,
            rowIndexByPath: flatRowIndexByPath,
            parentIndexByRow: flatRowParentIndexByRow,
            maxBytes: maxBytes,
            isFetchingRoot: isFetchingRoot
        )
        let worker = TreeDeletionPresentationWorker(
            matcher: treeBrowser.deletionPresentationMatcher,
            rootPath: rootPath,
            previous: previous
        )
        let task = Task { @MainActor in
            var prepared = await worker.prepare()
            guard requestRevision == flatProjectionRequestRevision,
                  presentationRevision == treeBrowser.deletionPresentationRevision,
                  !Task.isCancelled else {
                prepared = nil
                await worker.retire()
                return
            }
            guard let prepared else {
                await worker.retire()
                return
            }
            publishPreparedFlatProjection(prepared)
            flatProjectionTask = nil
            Task { @MainActor in
                await Task.yield()
                await worker.retire()
            }
        }
        flatProjectionTask = task
    }

    /// v2026.06.21：扫描结束边沿——把扫描期间合并的 rebuild 立刻 fire 拿到终态。
    /// 也兼容 isScanning 切回 true 的回边沿：进入扫描态不主动 rebuild（等 structural bump）。
    private func handleScanningToggle(nowScanning: Bool) {
        guard !nowScanning, coordinator.scanPhase == .idle else { return }
        rebuildFlatRows()
    }

    /// v2026.06.21：directChildren 异步写回路径只 bump childrenCacheVersion（不再 bump
    /// structuralRevision），这里独立监听；扫描中同样冻结，扫描结束统一刷新。
    private func handleChildrenCacheBump() {
        guard coordinator.scanPhase == .idle, !isScanningSnapshot else { return }
        let expandedPaths = Set(expanded.lazy.compactMap { $0.value ? $0.key : nil })
        if let path = Self.incrementalCachePatchPath(
            changedPath: treeBrowser.lastChildrenCacheChangedPath,
            expandedPaths: expandedPaths,
            visibleRowIndexByPath: flatRowIndexByPath
        ) {
            // v2026.07.19 first-frame contract: shallow identity rows are already authoritative.
            // Patch only this disclosure segment immediately; a full-root DFS would re-evaluate
            // every professional result row and can hide a 20–77 ms shallow terminal behind
            // seconds of unrelated projection work. The same path handles the later deep-metric
            // replacement without clearing the identities already on screen.
            startIncrementalProjection(
                path: path,
                isExpanding: true,
                expandedPaths: expandedPaths
            )
            return
        }
        rebuildFlatRows()
    }

    static func incrementalCachePatchPath(
        changedPath: String?,
        expandedPaths: Set<String>,
        visibleRowIndexByPath: [String: Int]
    ) -> String? {
        guard let changedPath,
              expandedPaths.contains(changedPath),
              visibleRowIndexByPath[changedPath] != nil
        else { return nil }
        return changedPath
    }

    /// 行内三角 / 单击整行 / 右键菜单 / 双击 → 共用的展开切换入口。
    /// 不在乎 [TreeNodeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 内部的 canExpand 状态，外层这里仅 toggle expanded[path]——
    /// 不能展开的行 row 内部已经把按钮 / 双击 hit-test disable 掉。
    ///
    /// v2026.06.21：扫描进行中**禁止展开切换**。
    /// 用户反馈：dev 扫描进行中点击 chevron 展开会触发按需子树扫描，
    /// 大量并发 IO + MainActor 上的 dirIndex 重建会和 ingest burst 互相挤占主线程，
    /// 体感卡顿急剧放大。扫描中保留 row 显示但拦截 expansion，等扫完再让用户展开。
    /// 已展开状态不主动收起（保留用户当前视图），仅拒绝**新的展开请求**与折叠请求。
    private func toggleExpansionFor(path: String) {
        // v2026.07.19 regression fix: settlement owns the primary filesystem handoff even though
        // its legacy `isScanning` flag is false. Do not admit disclosure I/O from that gap.
        if hasActivePrimaryScanOwnershipSnapshot { return }
        expanded[path] = !(expanded[path] ?? false)
    }

    // MARK: - SafetyEngine forbid 兜底（v1.5.3 仍保留为可测的 pure helper）

    /// **可测的 pure helper**：从任意路径集合里剔除 SafetyEngine forbid 路径。
    /// v1.5.3 多选 UI 已撤掉，但本静态方法仍被
    /// [TreeBrowserMultiSelectTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/TreeBrowserMultiSelectTests.swift)
    /// 锁住，作为"任意未来批量入口接进 SafetyEngine 的契约"——避免有人加了
    /// 别的批量删入口绕过 forbid 拦截。
    public static func sanitize(paths: Set<String>) -> Set<String> {
        paths.filter { safety.evaluate(path: $0).0 != .forbid }
    }
}

/// v2026.07.15：Tree 主浏览界面的运行期本地化投影边界。
///
/// AppKit 自绘行、右键菜单和 tooltip 都必须先得到 `String`，无法依赖 SwiftUI
/// 的 `Text` 在环境 locale 变化时重新解析。把这些投影统一收口后，切换语言只会
/// 重绘当前表格，不会重扫目录，也不会继续沿用进程启动语言。
enum TreeBrowserLiveLocalization {
    static func metricPresentation(row: TreeRow, locale: Locale) -> TreeMetricPresentation {
        let localization: TreeMetricPresentation.Localization?
        if row.accessState == .normal,
           !row.isSizePending,
           row.subtreeCompleteness == .containsIncompleteDescendant {
            localization = .init(
                lowerBoundFormat: AppLocalization.string("tree.metric.lower_bound", locale: locale),
                partialStatus: AppLocalization.string("tree.subtree.partial.badge", locale: locale),
                partialHelpFormat: AppLocalization.string("tree.subtree.partial.help", locale: locale)
            )
        } else {
            // Exact/pending/unavailable rows do not consume localized metric templates.
            localization = nil
        }
        return TreeMetricPresentation(row: row, locale: locale, localization: localization)
    }

    static func accessHelp(for row: TreeRow, locale: Locale) -> String? {
        let key: String
        switch row.accessState {
        case .normal:
            return nil
        case .permissionDenied:
            key = "tree.access.permission_denied"
        case .tccProtected:
            key = "tree.access.tcc_protected"
        case .incomplete:
            key = "tree.access.incomplete"
        }
        return AppLocalization.format(key, locale: locale, arguments: [row.path])
    }

    private static let currentYearFormatTemplate = Date.FormatStyle()
        .month(.twoDigits)
        .day(.twoDigits)
    private static let crossYearFormatTemplate = Date.FormatStyle()
        .year(.defaultDigits)
        .month(.twoDigits)
        .day(.twoDigits)
    private static let fullHelpFormatTemplate = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func mtimeDisplay(
        _ date: Date?,
        denied: Bool,
        locale: Locale,
        now: Date = Date()
    ) -> String {
        if denied { return "—" }
        guard let date else { return "·" }
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(currentYearFormatTemplate.locale(locale))
        }
        return date.formatted(crossYearFormatTemplate.locale(locale))
    }

    static func mtimeFullHelp(_ date: Date?, locale: Locale) -> String {
        guard let date else {
            return AppLocalization.string("tree.column.mtime.aggregate_help", locale: locale)
        }
        return date.formatted(fullHelpFormatTemplate.locale(locale))
    }
}

private struct AppKitFlatTreeTable: NSViewRepresentable {
    let rows: [FlatTreeRow]
    let rowIndexByPath: [String: Int]
    let parentIndexByRow: [Int?]
    let contentRevision: UInt64
    let identityRevision: UInt64
    let removalDelta: TreeTableRowRemovalDelta?
    let maxBytes: Int64
    let locale: Locale
    @Binding var selectedPath: String?
    let expanded: [String: Bool]
    let onToggleExpand: (String) -> Void
    let onTrash: ((TreeRow) -> Void)?
    let allowsVendorPathOverride: Bool
    let onRefreshSubtree: ((String) -> Void)?
    let onStash: ((TreeRow) -> Void)?
    let isStashed: (String) -> Bool
    let aiSettings: AISettings?
    let onAskAI: ((TreeRow) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TreeNSTableView()
        table.headerView = nil
        table.rowHeight = TreeTableMetrics.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.keyHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.handleKey(event) ?? false
        }

        let column = NSTableColumn(identifier: TreeTableMetrics.columnIdentifier)
        // v2026.07.20: TreeViewportScrollView is the sole geometry owner. Leaving AppKit's
        // independent autoresizer enabled recreates two competing width writers.
        column.resizingMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.addTableColumn(column)

        let scroll = TreeViewportScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let contentChanged = context.coordinator.parent.contentRevision != contentRevision
        let previousRows = contentChanged
            ? context.coordinator.parent.rows
            : nil
        let previousRowIndex = contentChanged
            ? context.coordinator.parent.rowIndexByPath
            : nil
        let previousParentIndex = contentChanged
            ? context.coordinator.parent.parentIndexByRow
            : nil
        context.coordinator.parent = self
        if let previousRows, let previousRowIndex, let previousParentIndex {
            context.coordinator.retirePreviousRows(
                previousRows,
                rowIndexByPath: previousRowIndex,
                parentIndexByRow: previousParentIndex
            )
        }
        guard let table = scrollView.documentView as? NSTableView else { return }
        let structuralUpdate = TreeTableStructuralUpdatePolicy.update(
            renderedIdentityRevision: context.coordinator.renderedIdentityRevision,
            // v2026.07.20: use AppKit's actual cached row count as the final invalid-update gate.
            // A SwiftUI re-mount/coalesced update may invalidate any manually mirrored count.
            renderedRowCount: table.numberOfRows,
            nextIdentityRevision: identityRevision,
            nextRowCount: rows.count,
            removalDelta: removalDelta
        )
        // v2026.07.20: a successful recycle receipt already identifies the exact vanished rows.
        // Apply that delta instead of a 40k-row reload while authoritative accounting continues.
        TreeTableStructuralUpdateApplier.apply(
            structuralUpdate,
            to: table,
            in: scrollView,
            redrawVisible: {
                context.coordinator.reloadVisibleRows(in: table)
            }
        )
        context.coordinator.renderedIdentityRevision = identityRevision
        context.coordinator.syncSelection(in: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AppKitFlatTreeTable
        var renderedIdentityRevision: UInt64?
        private var isSyncingSelection = false
        /// Only explicit keyboard navigation may move the viewport. Async projection publication,
        /// deletion pruning and passive selection re-indexing must preserve the user's scroll.
        private var pendingUserNavigationRevealPath: String?

        init(parent: AppKitFlatTreeTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        /// Non-structural SwiftUI updates (selection, locale, expansion icon, AI/stash state)
        /// only invalidate the bounded viewport. `reloadData()` is reserved for a new frozen row
        /// generation so AppKit retains row identity and scroll/selection state between updates.
        func reloadVisibleRows(in table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            let rowIndexes = IndexSet(integersIn: visible.location..<(visible.location + visible.length))
            let columnIndexes = IndexSet(integersIn: 0..<table.numberOfColumns)
            table.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        }

        func retirePreviousRows(
            _ rows: [FlatTreeRow],
            rowIndexByPath: [String: Int],
            parentIndexByRow: [Int?]
        ) {
            let retirement = TreeFlatRowsRetirement(
                rows: rows,
                rowIndexByPath: rowIndexByPath,
                parentIndexByRow: parentIndexByRow
            )
            Task {
                // `parent` above already points at the new generation. Yield once so AppKit can
                // finish the current representable update, then make the actor the last owner.
                await Task.yield()
                _ = await retirement.retire()
            }
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row rowIndex: Int) -> NSView? {
            guard rowIndex >= 0, rowIndex < parent.rows.count else { return nil }
            let identifier = TreeTableMetrics.cellIdentifier
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TreeTableCellView)
                ?? TreeTableCellView(identifier: identifier)
            let flat = parent.rows[rowIndex]
            cell.configure(
                flat: flat,
                maxBytes: parent.maxBytes,
                locale: parent.locale,
                isExpanded: parent.expanded[flat.row.path] ?? false,
                isSelected: !flat.isLoadingPlaceholder && parent.selectedPath == flat.row.path,
                isStashed: parent.isStashed(flat.row.path),
                hasTrash: parent.onTrash != nil,
                allowsVendorPathOverride: parent.allowsVendorPathOverride,
                hasStash: parent.onStash != nil,
                hasAI: parent.onAskAI != nil,
                aiReady: parent.aiSettings?.isReadyForUI == true,
                actions: TreeTableRowActions(
                    focus: { [weak tableView] in
                        guard let tableView else { return }
                        tableView.window?.makeFirstResponder(tableView)
                    },
                    select: { [weak self, weak tableView] in
                        guard let tableView else { return }
                        self?.select(flat.row.path, in: tableView)
                    },
                    toggle: { [weak self] in self?.parent.onToggleExpand(flat.row.path) },
                    trash: { [weak self] in self?.parent.onTrash?(flat.row) },
                    stash: { [weak self] in self?.parent.onStash?(flat.row) },
                    askAI: { [weak self] in self?.parent.onAskAI?(flat.row) },
                    refresh: { [weak self] in self?.parent.onRefreshSubtree?(flat.row.path) }
                )
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let table = notification.object as? NSTableView else { return }
            let rowIndex = table.selectedRow
            guard rowIndex >= 0, rowIndex < parent.rows.count else {
                parent.selectedPath = nil
                return
            }
            let flat = parent.rows[rowIndex]
            guard !flat.isLoadingPlaceholder else { return }
            parent.selectedPath = flat.row.path
        }

        func syncSelection(in table: NSTableView) {
            let pendingRevealPath = pendingUserNavigationRevealPath
            pendingUserNavigationRevealPath = nil
            guard let selectedPath = parent.selectedPath,
                  let idx = parent.rowIndexByPath[selectedPath],
                  parent.rows.indices.contains(idx) else {
                if table.selectedRow >= 0 {
                    isSyncingSelection = true
                    table.deselectAll(nil)
                    isSyncingSelection = false
                }
                return
            }
            if table.selectedRow != idx {
                isSyncingSelection = true
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                isSyncingSelection = false
            }
            if TreeSelectionViewportPolicy.shouldReveal(
                pendingUserNavigationPath: pendingRevealPath,
                selectedPath: selectedPath
            ) {
                table.scrollRowToVisible(idx)
            }
        }

        func select(_ path: String, in table: NSTableView) {
            // v2026.07.16: custom canvas clicks bypass NSTableView's default mouse handling.
            // Focus here (a user gesture), never from async row publication.
            UserInitiatedTableFocus.request(for: table)
            parent.selectedPath = path
            if let idx = parent.rowIndexByPath[path], parent.rows.indices.contains(idx) {
                isSyncingSelection = true
                table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                isSyncingSelection = false
            }
        }

        func handleKey(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 126:
                moveSelection(delta: -1); return true
            case 125:
                moveSelection(delta: 1); return true
            case 123:
                setExpansion(open: false); return true
            case 124:
                setExpansion(open: true); return true
            case 51:
                trashSelected(); return true
            default:
                break
            }
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
            switch scalar {
            case "\r":
                toggleSelectedExpansion(); return true
            case " ":
                previewOrToggleSelected(); return true
            default:
                if event.modifierFlags.contains(.command), scalar == "r" {
                    revealSelected(); return true
                }
                if scalar == "j" {
                    moveSelection(delta: 1); return true
                }
                if scalar == "k" {
                    moveSelection(delta: -1); return true
                }
                if scalar == "h" {
                    setExpansion(open: false); return true
                }
                if scalar == "l" {
                    setExpansion(open: true); return true
                }
                return false
            }
        }

        private func moveSelection(delta: Int) {
            guard !parent.rows.isEmpty else { return }
            let current = parent.selectedPath
                .flatMap { parent.rowIndexByPath[$0] }
                ?? -1
            let next = max(0, min(parent.rows.count - 1, current + delta))
            let flat = parent.rows[next]
            guard !flat.isLoadingPlaceholder else { return }
            parent.selectedPath = flat.row.path
            pendingUserNavigationRevealPath = flat.row.path
        }

        private func setExpansion(open: Bool) {
            guard let flat = selectedFlat() else { return }
            guard TreeBrowserView.canExpand(flat.row) else {
                if !open {
                    selectVisibleParent(of: flat)
                }
                return
            }
            let isOpen = parent.expanded[flat.row.path] ?? false
            guard isOpen != open else { return }
            parent.onToggleExpand(flat.row.path)
        }

        /// Preserves the original Vim-style H behavior without a second SwiftUI key path:
        /// pressing H/Left on a leaf selects its nearest visible parent.
        private func selectVisibleParent(of flat: FlatTreeRow) {
            guard flat.depth > 0,
                  let index = parent.rowIndexByPath[flat.row.path],
                  parent.parentIndexByRow.indices.contains(index),
                  let parentIndex = parent.parentIndexByRow[index],
                  parent.rows.indices.contains(parentIndex) else {
                return
            }
            let candidate = parent.rows[parentIndex]
            guard !candidate.isLoadingPlaceholder else { return }
            parent.selectedPath = candidate.row.path
            pendingUserNavigationRevealPath = candidate.row.path
        }

        private func toggleSelectedExpansion() {
            guard let flat = selectedFlat(),
                  TreeBrowserView.canExpand(flat.row) else { return }
            parent.onToggleExpand(flat.row.path)
        }

        private func previewOrToggleSelected() {
            guard let flat = selectedFlat() else { return }
            if flat.row.isDirectory {
                toggleSelectedExpansion()
            } else {
                QuickLookController.shared.preview(
                    urls: [URL(fileURLWithPath: flat.row.path)]
                )
            }
        }

        private func revealSelected() {
            guard let flat = selectedFlat() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: flat.row.path)])
        }

        private func trashSelected() {
            guard let flat = selectedFlat(), parent.onTrash != nil else { return }
            guard TreeBrowserView.canInitiateDeletion(
                flat,
                allowsVendorPathOverride: parent.allowsVendorPathOverride
            ) else {
                NSSound.beep()
                return
            }
            parent.onTrash?(flat.row)
        }

        private func selectedFlat() -> FlatTreeRow? {
            guard let selectedPath = parent.selectedPath,
                  let index = parent.rowIndexByPath[selectedPath],
                  parent.rows.indices.contains(index),
                  !parent.rows[index].isLoadingPlaceholder else { return nil }
            return parent.rows[index]
        }
    }
}

private final class TreeNSTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// v2026.07.20: the Tree's sole column follows the real AppKit clip viewport after layout.
/// SwiftUI business-state updates can arrive before or after geometry settles, so `updateNSView`
/// must not own column width; otherwise AI/stash/trash state can suddenly apply a stale/new width
/// and move the whole right-anchored operation area. A real viewport change (including opening or
/// closing the selected row's detail pane) still updates the column through this layout owner.
@MainActor
final class TreeViewportScrollView: NSScrollView {
    override func layout() {
        super.layout()
        synchronizeSingleColumnWidthToViewport()
    }

    func synchronizeSingleColumnWidthToViewport() {
        guard let table = documentView as? NSTableView,
              table.tableColumns.count == 1 else { return }
        let viewportWidth = contentView.bounds.width
        guard viewportWidth.isFinite,
              viewportWidth > 0,
              table.tableColumns[0].width != viewportWidth else { return }
        table.tableColumns[0].width = viewportWidth
    }
}

private enum TreeTableMetrics {
    static let rowHeight: CGFloat = 30
    static let leftPadding: CGFloat = 8
    static let indentation: CGFloat = 18
    static let chevronWidth: CGFloat = 24
    static let iconWidth: CGFloat = 24
    static let iconHeight: CGFloat = 20
    static let folderPointSize: CGFloat = 20
    static let disclosurePointSize: CGFloat = folderPointSize - 3
    static let inlineProgressSide: CGFloat = 12
    static let inlineProgressGap: CGFloat = 6
    static let horizontalGap: CGFloat = 8
    static let sizeWidth: CGFloat = 90
    static let countWidth: CGFloat = 56
    static let mtimeWidth: CGFloat = 98
    static let actionGap: CGFloat = 12
    static let actionWidth: CGFloat = 28
    static let actionAreaWidth: CGFloat = 84
    static let actionTrailingPadding: CGFloat = 16
    static let columnIdentifier = NSUserInterfaceItemIdentifier("TreeTableColumn")
    static let cellIdentifier = NSUserInterfaceItemIdentifier("TreeTableCell")
}

private struct TreeTableRowActions {
    let focus: () -> Void
    let select: () -> Void
    let toggle: () -> Void
    let trash: () -> Void
    let stash: () -> Void
    let askAI: () -> Void
    let refresh: () -> Void
}

private final class TreeTableCellView: NSTableCellView {
    private let canvas = TreeTableRowCanvas()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
    }

    func configure(flat: FlatTreeRow,
                   maxBytes: Int64,
                   locale: Locale,
                   isExpanded: Bool,
                   isSelected: Bool,
                   isStashed: Bool,
                   hasTrash: Bool,
                   allowsVendorPathOverride: Bool,
                   hasStash: Bool,
                   hasAI: Bool,
                   aiReady: Bool,
                   actions: TreeTableRowActions) {
        canvas.configure(
            flat: flat,
            maxBytes: maxBytes,
            locale: locale,
            isExpanded: isExpanded,
            isSelected: isSelected,
            isStashed: isStashed,
            hasTrash: hasTrash,
            allowsVendorPathOverride: allowsVendorPathOverride,
            hasStash: hasStash,
            hasAI: hasAI,
            aiReady: aiReady,
            actions: actions
        )
    }
}

private final class TreeTableRowCanvas: NSView {
    private struct SymbolCacheKey: Hashable {
        let name: String
        let colorDescription: String
        let pointSizeTenths: Int
        let weightRawValue: CGFloat
    }

    @MainActor
    private static var symbolCache: [SymbolCacheKey: NSImage] = [:]

    private let inlineProgress = NSProgressIndicator()
    private var flat: FlatTreeRow?
    private var maxBytes: Int64 = 0
    /// `configure` 在首帧绘制前总会覆盖；固定占位值避免误用进程级 locale。
    private var locale = Locale(identifier: "en")
    private var isExpanded = false
    private var isSelected = false
    private var isStashed = false
    private var hasTrash = false
    private var allowsVendorPathOverride = false
    private var hasStash = false
    private var hasAI = false
    private var aiReady = false
    private var actions: TreeTableRowActions?
    private var cachedMetrics: TreeMetricPresentation?
    private var cachedMtimeText: String = "·"

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inlineProgress.style = .spinning
        inlineProgress.controlSize = .mini
        inlineProgress.isIndeterminate = true
        inlineProgress.isDisplayedWhenStopped = false
        inlineProgress.isHidden = true
        inlineProgress.usesThreadedAnimation = true
        addSubview(inlineProgress)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateInlineProgress()
    }

    func configure(flat: FlatTreeRow,
                   maxBytes: Int64,
                   locale: Locale,
                   isExpanded: Bool,
                   isSelected: Bool,
                   isStashed: Bool,
                   hasTrash: Bool,
                   allowsVendorPathOverride: Bool,
                   hasStash: Bool,
                   hasAI: Bool,
                   aiReady: Bool,
                   actions: TreeTableRowActions) {
        self.flat = flat
        self.maxBytes = maxBytes
        self.locale = locale
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.isStashed = isStashed
        self.hasTrash = hasTrash
        self.allowsVendorPathOverride = allowsVendorPathOverride
        self.hasStash = hasStash
        self.hasAI = hasAI
        self.aiReady = aiReady
        self.actions = actions
        let metrics = TreeBrowserLiveLocalization.metricPresentation(row: flat.row, locale: locale)
        self.cachedMetrics = metrics
        let denied = flat.row.accessState != .normal
        self.cachedMtimeText = TreeBrowserLiveLocalization.mtimeDisplay(
            flat.row.modificationDate,
            denied: denied,
            locale: locale
        )
        if let accessHelp = TreeBrowserLiveLocalization.accessHelp(for: flat.row, locale: locale) {
            toolTip = accessHelp
        } else if let helpText = metrics.helpText {
            toolTip = flat.row.path + "\n\n" + helpText
        } else {
            toolTip = flat.row.path
        }
        updateInlineProgress()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let flat else { return }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        if flat.isLoadingPlaceholder {
            drawLoading(flat)
            return
        }
        drawRow(flat)
    }

    override func mouseDown(with event: NSEvent) {
        guard let flat, !flat.isLoadingPlaceholder, let actions else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hitTestAction(point) == .ai {
            if InlineRowActionNavigationPolicy.shouldFocusTable(for: .askAI) {
                actions.focus()
            }
            if InlineRowActionNavigationPolicy.shouldSelectRow(for: .askAI) {
                actions.select()
            }
            GSYLog.notice(.operation, "tree.row.ai path=\(flat.row.path)")
            actions.askAI(); return
        }
        if hitTestAction(point) == .stash {
            if InlineRowActionNavigationPolicy.shouldFocusTable(for: .stash) {
                actions.focus()
            }
            guard !isStashed else { NSSound.beep(); return }
            if InlineRowActionNavigationPolicy.shouldSelectRow(for: .stash) {
                actions.select()
            }
            GSYLog.notice(.operation, "tree.row.stash path=\(flat.row.path)")
            actions.stash(); return
        }
        if hitTestAction(point) == .trash {
            if InlineRowActionNavigationPolicy.shouldFocusTable(for: .trash) {
                actions.focus()
            }
            guard isTrashable(flat) else { NSSound.beep(); return }
            if InlineRowActionNavigationPolicy.shouldSelectRow(for: .trash) {
                actions.select()
            }
            GSYLog.notice(.operation, "tree.row.trash path=\(flat.row.path)")
            actions.trash(); return
        }
        actions.focus()
        actions.select()
        if disclosureRect(for: flat).contains(point) {
            if canExpand(flat) {
                GSYLog.notice(.operation, "tree.row.toggle path=\(flat.row.path) expanded=\(!isExpanded)")
                actions.toggle()
            }
            return
        }
        if event.clickCount >= 2, canExpand(flat) {
            GSYLog.notice(.operation, "tree.row.toggle path=\(flat.row.path) expanded=\(!isExpanded)")
            actions.toggle()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let flat, !flat.isLoadingPlaceholder, let actions else { return nil }
        actions.select()
        let row = flat.row
        let menu = NSMenu()
        if hasTrash {
            let requiresOverride = DeletionEntryPolicy.requiresVendorPathOverride(
                verdict: flat.verdict,
                rejection: flat.rejection,
                allowsVendorPathOverride: allowsVendorPathOverride
            )
            let item = ClosureMenuItem(
                title: AppLocalization.string(
                    requiresOverride
                        ? "delete.vendor_override.action"
                        : (isTrashable(flat) ? "tree.menu.trash" : "tree.menu.trash_forbidden"),
                    locale: locale
                ),
                action: { if self.isTrashable(flat) { actions.trash() } }
            )
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            item.isEnabled = isTrashable(flat)
            menu.addItem(item)
        }
        if hasStash {
            let item = ClosureMenuItem(
                title: AppLocalization.string(
                    isStashed ? "tree.menu.stash_already" : "tree.menu.stash",
                    locale: locale
                ),
                action: { if !self.isStashed { actions.stash() } }
            )
            item.image = NSImage(systemSymbolName: isStashed ? "tray.full.fill" : "tray.and.arrow.down",
                                 accessibilityDescription: nil)
            item.isEnabled = !isStashed
            menu.addItem(item)
        }
        if hasTrash || hasStash { menu.addItem(.separator()) }
        if hasAI {
            let item = ClosureMenuItem(
                title: AppLocalization.string("tree.menu.ask_ai", locale: locale),
                action: actions.askAI
            )
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let quickLook = ClosureMenuItem(
            title: AppLocalization.string("tree.menu.quick_look", locale: locale),
            action: { QuickLookController.shared.preview(urls: [URL(fileURLWithPath: row.path)]) }
        )
        quickLook.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        menu.addItem(quickLook)
        let reveal = ClosureMenuItem(
            title: AppLocalization.string("tree.menu.reveal_in_finder", locale: locale),
            action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
        )
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(reveal)
        menu.addItem(.separator())
        if row.isDirectory {
            let refresh = ClosureMenuItem(
                title: AppLocalization.string("tree.menu.refresh", locale: locale),
                action: {
                    GSYLog.notice(.operation, "tree.menu.refresh path=\(row.path)")
                    actions.refresh()
                }
            )
            refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            menu.addItem(refresh)
        }
        if canExpand(flat) {
            let disclose = ClosureMenuItem(
                title: AppLocalization.string(
                    isExpanded ? "tree.disclose.collapse" : "tree.disclose.expand",
                    locale: locale
                ),
                action: actions.toggle
            )
            disclose.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                                     accessibilityDescription: nil)
            menu.addItem(disclose)
        }
        menu.addItem(.separator())
        let copyPath = ClosureMenuItem(
            title: AppLocalization.string("tree.menu.copy_path", locale: locale),
            action: { Self.copy(row.path) }
        )
        copyPath.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyPath)
        let copyName = ClosureMenuItem(
            title: AppLocalization.string("tree.menu.copy_name", locale: locale),
            action: { Self.copy((row.path as NSString).lastPathComponent) }
        )
        copyName.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        menu.addItem(copyName)
        return menu
    }

    private func drawLoading(_ flat: FlatTreeRow) {
        let x = TreeTableMetrics.leftPadding
            + CGFloat(flat.depth) * TreeTableMetrics.indentation
            + TreeTableMetrics.chevronWidth
        drawText(AppLocalization.string("tree.loading.children", locale: locale),
                 in: CGRect(x: x, y: 5, width: bounds.width - x - 8, height: 18),
                 font: .systemFont(ofSize: NSFont.systemFontSize),
                 color: .secondaryLabelColor)
    }

    private func drawRow(_ flat: FlatTreeRow) {
        let row = flat.row
        let metrics = cachedMetrics ?? TreeBrowserLiveLocalization.metricPresentation(row: row, locale: locale)
        let denied = row.accessState != .normal
        let chevronRect = disclosureRect(for: flat)
        if canExpand(flat) {
            drawDisclosureTriangle(in: chevronRect,
                                   expanded: isExpanded,
                                   color: .secondaryLabelColor)
        }
        let iconRect = CGRect(x: chevronRect.maxX + TreeTableMetrics.horizontalGap,
                              y: 5,
                              width: TreeTableMetrics.iconWidth,
                              height: TreeTableMetrics.iconHeight)
        drawSymbol(row.isDirectory ? "folder.fill" : "doc",
                   in: iconRect,
                   color: denied ? .tertiaryLabelColor : (row.isDirectory ? .controlAccentColor : .secondaryLabelColor),
                   pointSize: row.isDirectory ? TreeTableMetrics.folderPointSize : 18,
                   weight: .regular)
        if denied {
            drawSymbol("lock.fill",
                       in: CGRect(x: iconRect.maxX - 5, y: iconRect.maxY - 7, width: 8, height: 8),
                       color: .systemOrange)
        } else if metrics.state == .lowerBound {
            // Partial 与“当前目录不可访问”是正交状态，使用信息徽章而不是 lock。
            // 数值列保持纯数字，完整的 lower-bound 语义放在共享 tooltip / detail 文本中。
            drawSymbol("exclamationmark.circle.fill",
                       in: CGRect(x: iconRect.maxX - 6, y: iconRect.maxY - 8, width: 10, height: 10),
                       color: .systemOrange)
        }
        let nameX = iconRect.maxX + TreeTableMetrics.horizontalGap
        let actionStart = bounds.width
            - TreeTableMetrics.actionTrailingPadding
            - TreeTableMetrics.actionAreaWidth
        let mtimeX = actionStart - TreeTableMetrics.actionGap - TreeTableMetrics.mtimeWidth
        let countX = mtimeX - TreeTableMetrics.countWidth
        let sizeX = countX - TreeTableMetrics.sizeWidth
        let nameWidth = max(20, sizeX - nameX - 8)
        let nameFont = NSFont.systemFont(ofSize: 13)
        let nameTextRect = self.nameTextRect(x: nameX,
                                             width: nameWidth,
                                             loadingChildren: flat.isLoadingChildren)
        drawText(row.title.isEmpty ? row.path : row.displayTitle(locale: locale),
                 in: nameTextRect,
                 font: nameFont,
                 color: denied ? .tertiaryLabelColor : .labelColor,
                 lineBreak: .byTruncatingMiddle)
        drawBar(row: row,
                denied: denied,
                rect: CGRect(x: nameX, y: 24, width: nameWidth, height: 2))
        let pendingSize = metrics.state == .pending
        drawText(metrics.size.compactText,
                 in: CGRect(x: sizeX, y: 6, width: TreeTableMetrics.sizeWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
                 color: (denied || pendingSize) ? .tertiaryLabelColor : .secondaryLabelColor,
                 alignment: .right)
        drawText(metrics.count.compactText,
                 in: CGRect(x: countX, y: 6, width: TreeTableMetrics.countWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
                 color: .tertiaryLabelColor,
                 alignment: .right)
        drawText(cachedMtimeText,
                 in: CGRect(x: mtimeX, y: 6, width: TreeTableMetrics.mtimeWidth - 8, height: 17),
                 font: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
                 color: .tertiaryLabelColor,
                 alignment: .right)
        drawActions(flat)
    }

    private func drawBar(row: TreeRow, denied: Bool, rect: CGRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        guard maxBytes > 0, !denied, !row.isSizePending else { return }
        let ratio = max(0, min(1, Double(row.bytes) / Double(maxBytes)))
        let fill = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(ratio), height: rect.height)
        (row.isDirectory ? NSColor.controlAccentColor.withAlphaComponent(0.56) : NSColor.controlAccentColor.withAlphaComponent(0.30)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawActions(_ flat: FlatTreeRow) {
        if hasAI {
            drawSymbol("sparkles",
                       in: symbolRect(in: actionRect(.ai), side: 16),
                       color: aiReady ? .controlAccentColor : .secondaryLabelColor.withAlphaComponent(0.45),
                       pointSize: 14,
                       weight: .regular)
        }
        if hasStash {
            drawSymbol(isStashed ? "tray.full.fill" : "tray.and.arrow.down",
                       in: symbolRect(in: actionRect(.stash), side: 16),
                       color: isStashed ? .controlAccentColor : .secondaryLabelColor,
                       pointSize: 14,
                       weight: .regular)
        }
        if hasTrash {
            drawSymbol("trash",
                       in: symbolRect(in: actionRect(.trash), side: 16),
                       color: isTrashable(flat) ? .systemRed : .secondaryLabelColor.withAlphaComponent(0.35),
                       pointSize: 14,
                       weight: .regular)
        }
    }

    private func drawDisclosureTriangle(in rect: CGRect,
                                        expanded: Bool,
                                        color: NSColor) {
        drawSymbol(expanded ? "chevron.down" : "chevron.right",
                   in: symbolRect(in: rect, side: TreeTableMetrics.disclosurePointSize),
                   color: color,
                   pointSize: TreeTableMetrics.disclosurePointSize,
                   weight: .medium)
    }

    private func disclosureRect(for flat: FlatTreeRow) -> CGRect {
        CGRect(
            x: TreeTableMetrics.leftPadding + CGFloat(flat.depth) * TreeTableMetrics.indentation,
            y: 4,
            width: TreeTableMetrics.chevronWidth,
            height: 22
        )
    }

    private enum ActionHit {
        case none
        case ai
        case stash
        case trash
    }

    private func hitTestAction(_ point: CGPoint) -> ActionHit {
        if hasAI, actionRect(.ai).contains(point) { return .ai }
        if hasStash, actionRect(.stash).contains(point) { return .stash }
        if hasTrash, actionRect(.trash).contains(point) { return .trash }
        return .none
    }

    private func actionRect(_ action: ActionHit) -> CGRect {
        let right = bounds.width - TreeTableMetrics.actionTrailingPadding
        let trash = CGRect(x: right - TreeTableMetrics.actionWidth, y: 4,
                           width: TreeTableMetrics.actionWidth, height: 22)
        let stash = trash.offsetBy(dx: -TreeTableMetrics.actionWidth, dy: 0)
        let ai = stash.offsetBy(dx: -TreeTableMetrics.actionWidth, dy: 0)
        switch action {
        case .ai: return ai
        case .stash: return stash
        case .trash: return trash
        case .none: return .zero
        }
    }

    private func nameTextRect(x: CGFloat, width: CGFloat, loadingChildren: Bool) -> CGRect {
        let reserved = loadingChildren
            ? TreeTableMetrics.inlineProgressSide + TreeTableMetrics.inlineProgressGap
            : 0
        return CGRect(x: x,
                      y: 3,
                      width: max(20, width - reserved),
                      height: 19)
    }

    private func inlineProgressRect(for flat: FlatTreeRow) -> CGRect? {
        guard flat.isLoadingChildren,
              !flat.isLoadingPlaceholder,
              bounds.width > 0 else { return nil }

        let chevronRect = disclosureRect(for: flat)
        let iconRect = CGRect(x: chevronRect.maxX + TreeTableMetrics.horizontalGap,
                              y: 5,
                              width: TreeTableMetrics.iconWidth,
                              height: TreeTableMetrics.iconHeight)
        let nameX = iconRect.maxX + TreeTableMetrics.horizontalGap
        let actionStart = bounds.width
            - TreeTableMetrics.actionTrailingPadding
            - TreeTableMetrics.actionAreaWidth
        let mtimeX = actionStart - TreeTableMetrics.actionGap - TreeTableMetrics.mtimeWidth
        let countX = mtimeX - TreeTableMetrics.countWidth
        let sizeX = countX - TreeTableMetrics.sizeWidth
        let nameWidth = max(20, sizeX - nameX - 8)
        guard nameWidth > TreeTableMetrics.inlineProgressSide else { return nil }

        let font = NSFont.systemFont(ofSize: 13)
        let text = flat.row.title.isEmpty ? flat.row.path : flat.row.displayTitle(locale: locale)
        let textRect = nameTextRect(x: nameX, width: nameWidth, loadingChildren: true)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let side = TreeTableMetrics.inlineProgressSide
        let preferredX = textRect.minX + measured + TreeTableMetrics.inlineProgressGap
        let maxX = nameX + nameWidth - side
        let x = min(max(preferredX, textRect.minX), maxX)
        return CGRect(x: x,
                      y: floor((bounds.height - side) / 2),
                      width: side,
                      height: side)
    }

    private func updateInlineProgress() {
        guard let flat,
              let rect = inlineProgressRect(for: flat)
        else {
            inlineProgress.stopAnimation(nil)
            inlineProgress.isHidden = true
            return
        }
        inlineProgress.frame = rect
        inlineProgress.isHidden = false
        inlineProgress.startAnimation(nil)
    }

    private func symbolRect(in rect: CGRect, side: CGFloat? = nil) -> CGRect {
        let resolvedSide = min(side ?? min(rect.width, rect.height), rect.width, rect.height)
        return CGRect(
            x: rect.midX - resolvedSide / 2,
            y: rect.midY - resolvedSide / 2,
            width: resolvedSide,
            height: resolvedSide
        )
    }

    private func canExpand(_ flat: FlatTreeRow) -> Bool {
        TreeBrowserView.canExpand(flat.row)
    }

    private func isTrashable(_ flat: FlatTreeRow) -> Bool {
        // v2026.07.20: shallow identity publication never authorizes deletion. Keep it disabled
        // through deep exact-capacity enrichment and the requested-sort terminal.
        hasTrash && TreeBrowserView.canInitiateDeletion(
            flat,
            allowsVendorPathOverride: allowsVendorPathOverride
        )
    }

    private func drawText(_ text: String,
                          in rect: CGRect,
                          font: NSFont?,
                          color: NSColor?,
                          alignment: NSTextAlignment = .left,
                          lineBreak: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        var attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph
        ]
        if let font {
            attributes[.font] = font
        }
        if let color {
            attributes[.foregroundColor] = color
        }
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawSymbol(_ name: String,
                            in rect: CGRect,
                            color: NSColor,
                            pointSize: CGFloat? = nil,
                            weight: NSFont.Weight = .regular) {
        let cacheKey = SymbolCacheKey(
            name: name,
            colorDescription: color.description,
            pointSizeTenths: Int(((pointSize ?? 0) * 10).rounded()),
            weightRawValue: weight.rawValue
        )
        let image: NSImage
        if let cached = Self.symbolCache[cacheKey] {
            image = cached
        } else {
            guard var loaded = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
            let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: color)
            if let pointSize {
                let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                    .applying(colorConfig)
                loaded = loaded.withSymbolConfiguration(config) ?? loaded
            } else {
                loaded = loaded.withSymbolConfiguration(colorConfig) ?? loaded
            }
            if Self.symbolCache.count >= 128 {
                Self.symbolCache.removeAll(keepingCapacity: true)
            }
            Self.symbolCache[cacheKey] = loaded
            image = loaded
        }
        image.draw(in: aspectFitRect(for: image, in: rect),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1,
                   respectFlipped: true,
                   hints: nil)
    }

    private func aspectFitRect(for image: NSImage, in rect: CGRect) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0,
              rect.width > 0, rect.height > 0
        else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, action closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runClosure() {
        closure()
    }
}

/// 列表头：可点击切排序。
///
/// v1.5.4：新增"修改时间"列（98pt 宽），与 [TreeBrowserRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L622)
/// 的 mtime 单元宽度对齐。点击切 desc/asc，与 size/name/count 一致。
struct TreeColumnHeader: View {
    @Binding var sortKey: TreeSortKey
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 0) {
            // 与 TreeTableRowCanvas depth=0 的 chevron (24) + gap (8) + icon (24) + gap (8) = 64 对齐
            Spacer().frame(
                width: TreeTableMetrics.chevronWidth
                    + TreeTableMetrics.horizontalGap
                    + TreeTableMetrics.iconWidth
                    + TreeTableMetrics.horizontalGap
            )
            headerButton(key: "tree.column.name", column: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerButton(key: "tree.column.size", column: .size)
                .frame(width: TreeTableMetrics.sizeWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
            headerButton(key: "tree.column.count", column: .count)
                .frame(width: TreeTableMetrics.countWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
            // v1.5.4：mtime 列。98pt 给"yyyy-MM-dd"或"3 天前"宽度足够。
            headerButton(key: "tree.column.mtime", column: .mtime)
                .frame(width: TreeTableMetrics.mtimeWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
            Spacer().frame(width: TreeTableMetrics.actionGap)
            Text("tree.column.actions", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: TreeTableMetrics.actionAreaWidth, alignment: .center)
        }
        .padding(.leading, TreeTableMetrics.leftPadding)
        .padding(.trailing, TreeTableMetrics.actionTrailingPadding)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func headerButton(key: String, column: TreeSortKey.Column) -> some View {
        let label = AppLocalization.string(key, locale: locale)
        Button {
            sortKey = sortKey.toggled(to: column)
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if sortKey.column == column {
                    Image(systemName: sortKey.isDescending ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(AppLocalization.format("tree.column.sort_help", locale: locale, arguments: [label]))
    }
}

/// **v1.5.4 性能修复**：扁平树行的轻量数据载体。
/// `row` 走 [TreeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L139)
/// 自身的 path 当 SwiftUI 的 `id`，`depth` 决定 indent 缩进。
/// `Hashable` 由 TreeRow / Int 自动合成，让 onChange/diff 能用值比较。
///
/// **v2026.06 Step 1【P0-1 verdict 缓存】**：新增 stored `verdict`。
/// 旧版 [TreeNodeRow.isTrashable](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// 在 SwiftUI 重绘 hot path 上每帧调 `safety.evaluate(path:)` →
/// 4w 节点 60fps 主线程压垮。
/// 改为 [rebuildFlatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// 一次性算好塞到这里，body 只读字段，evaluator 调用次数 == 行数（不再随重绘倍增）。
/// 回归契约见 [FlatTreeRowVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)。
struct FlatTreeRow: Identifiable, Hashable, Sendable {
    let row: TreeRow
    let depth: Int
    let verdict: SafetyVerdict
    /// 与 verdict 在同一次 SafetyEngine 评估中冻结，供专业模式只识别 vendorPathRule。
    /// 默认 `.ok` 保持测试 fixture / 普通模式构造兼容。
    let rejection: SafetyRejection
    /// v2026.06.20 当本行是"加载占位行"时为 true。占位行 id 用父路径 + "::__loading__"
    /// 后缀，避免与真实 path 冲突；UI 端只渲染一个 ProgressView + "加载中…" 文案，
    /// 不响应点击 / 不算入选中态 / 不进入键盘导航候选集。
    var isLoadingPlaceholder: Bool = false
    /// 已展开目录的子节点深度聚合还在后台进行时为 true。
    /// AppKit 行会在名称后显示一个 mini spinner；v2026.07.20 起浅层 identity 出现后仍
    /// 保持为 true，直到 deep 精确容量、文件数和当前排序原子提交。selection 只表达
    /// path identity，destructive action 必须等它变回 false。
    var isLoadingChildren: Bool = false

    init(
        row: TreeRow,
        depth: Int,
        verdict: SafetyVerdict,
        rejection: SafetyRejection = .ok,
        isLoadingPlaceholder: Bool = false,
        isLoadingChildren: Bool = false
    ) {
        self.row = row
        self.depth = depth
        self.verdict = verdict
        self.rejection = rejection
        self.isLoadingPlaceholder = isLoadingPlaceholder
        self.isLoadingChildren = isLoadingChildren
    }

    /// v2026.06.20：占位行的 id 不能用 `row.path`（会与真实 path 冲突 / 影响 selectedPath
    /// 等键盘导航逻辑），改用 `row.path + "::__loading__"`。普通行保持原行为。
    var id: String {
        isLoadingPlaceholder ? "\(row.path)::__loading__" : row.path
    }
}

/// **v1.5.4 重构**：单行树节点视图（不再递归自身）。
/// 旧版 `TreeNodeView` 在 body 内部嵌套 `ForEach(directChildren)` + 自递归，
/// 4w 节点级一次重绘要重新拍平整棵展开树几次，导致点击展开 200~500ms 卡顿。
/// 新版只渲染**一行**，子项由外层 [TreeBrowserView.flatRows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
/// 在 onChange 时一次性扁平化好，顶层 ForEach 平铺渲染。
struct TreeNodeRow: View {
    let flat: FlatTreeRow
    let maxBytes: Int64
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    /// 上层透传的"移到废纸篓"通道（已包含二次确认 wrapper）。nil 时菜单项与行内 trash 按钮都不展示。
    let onTrash: ((TreeRow) -> Void)?
    /// 普通复用默认锁住所有 forbid；Professional callsite 才会显式开放 vendorPathRule。
    let allowsVendorPathOverride: Bool = false
    /// v2026.06 #1：右键"刷新此目录"回调。nil 或本行非 directory 时菜单不展示。
    let onRefreshSubtree: ((String) -> Void)?
    /// v2026.06.18 **加入待处理**回调（购物车）。nil 时 contextMenu 不展示该项。
    let onStash: ((TreeRow) -> Void)?
    /// v2026.06.18 当前行是否已加入待处理。true 时按钮置灰 + 改文案。
    let isStashed: Bool
    /// v2026.06.20 AI 设置（决定 sparkles 按钮可点 / 灰）。nil 时同 readonly：按钮根本不出现。
    let aiSettings: AISettings?
    /// v2026.06.20 AI 入口回调。给 nil 时按钮不出现；给值后未配置 → disabled + 提示去设置。
    let onAskAI: ((TreeRow) -> Void)?
    @Environment(\.locale) private var locale

    private var row: TreeRow { flat.row }
    private var indent: CGFloat { CGFloat(flat.depth) * 16 }
    /// v1.3.zzzz：accessDenied 目录不允许展开（即便 hasChildren=true 也只是 SQL 边角）。
    private var canExpand: Bool {
        TreeBrowserView.canExpand(row)
    }
    /// **v1.5.3**：本行能否被行内 trash 按钮删除。
    ///
    /// **v2026.06 Step 1**：不再每帧调 `safety.evaluate(path:)`——
    /// verdict 已由 [TreeBrowserView.computeVerdicts](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 在 rebuildFlatRows 阶段一次性算好塞进 [FlatTreeRow.verdict](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
    /// 这里仅做 O(1) 字段读取，让 SwiftUI 重绘 hot path 完全不碰 SafetyEngine。
    private var isTrashable: Bool {
        guard onTrash != nil else { return false }
        return TreeBrowserView.canInitiateDeletion(
            flat,
            allowsVendorPathOverride: allowsVendorPathOverride
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: indent, height: 1)
            // 披露三角（叶子用空白占位保持对齐）
            Group {
                if canExpand {
                    Button {
                        // v2026.07.20: Disclosure is navigation, unlike the adjacent inline
                        // commands. Keep the SwiftUI fallback aligned with AppKit: select the row,
                        // then expand it.
                        onSelect()
                        onToggleExpand()
                    } label: {
                        // bug 1：22x22 hit area，与 Finder/DaisyDisk 看齐。
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded
                          ? AppLocalization.string("tree.disclose.collapse", locale: locale)
                          : AppLocalization.string("tree.disclose.expand", locale: locale))
                } else {
                    Spacer().frame(width: 22, height: 22)
                }
            }
            TreeBrowserRow(row: row, maxBytes: maxBytes)
                // v2026.07.20: only the content region owns navigation. Keeping gestures off the
                // parent HStack makes the adjacent AI/stash/trash Buttons mutually exclusive with
                // row selection even in this SwiftUI fallback implementation.
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard canExpand else { return }
                    onToggleExpand()
                }
                .onTapGesture(count: 1) {
                    onSelect()
                }
            // v2026.06.21 反馈修复：在数据 Row 与「操作」按钮组之间也插入与表头
            // 一致的 12pt 间隙（表头 mtime 与 actions 同样间隔 12pt），避免行内
            // mtime 数字与三枚按钮贴在一起，跟表头列宽完全对齐。
            // 注意：HStack 自身 spacing=6 已贡献了 6pt，再加 6pt 凑到 12pt。
            Spacer().frame(width: 6, height: 1)
            // v2026.06.20 **行内"问 AI"按钮**——抽到独立 helper 减轻 body 的 type-check 负担。
            // 详细注释见 [aiActionButton](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)。
            aiActionButton
            // v2026.06.20 **行内"加入待处理"按钮**——放在 trash 之前，作为"非破坏性
            // 暂存"的快速通道，与右键菜单完全等价。状态可视：未加入时显示空托盘
            // 图标（`tray.and.arrow.down`），已加入显示满托盘（`tray.full.fill`）
            // + 置灰 + 鼠标悬停文案改成"已在待处理"。
            //
            // 设计要点：
            // 1. 用 `isStashed` 字段（外层 `TreeBrowserView` 把 `stash.contains(path)`
            //    映射进来，O(1) Set 查询）决定 icon / 文案 / disabled，不在 row body
            //    重算时回查 StashStore，避免 SwiftUI hot path 多一次跨 Observable 订阅。
            // 2. 行内按钮永远存在（只要 onStash 非 nil），不依赖 `onTrash`——
            //    待处理本身不是破坏性操作，readonly 视图同样应允许暂存。
            // 3. `.buttonStyle(.plain)` + 22pt hit area，与三角披露 / trash 按钮一致，
            //    Finder 风手感。
            if let onStash {
                Button {
                    guard !isStashed else { NSSound.beep(); return }
                    if InlineRowActionNavigationPolicy.shouldSelectRow(for: .stash) {
                        onSelect()
                    }
                    onStash(row)
                } label: {
                    Image(systemName: isStashed ? "tray.full.fill" : "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isStashed ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isStashed)
                .help(isStashed
                      ? AppLocalization.string("tree.row.stash.already", locale: locale)
                      : AppLocalization.string("tree.row.stash", locale: locale))
            }
            // **v1.5.3**：行内 trash 按钮——单击 = 立刻调 onTrash（已经过外层二次确认 wrapper）。
            if let onTrash {
                Button {
                    guard isTrashable else { NSSound.beep(); return }
                    if InlineRowActionNavigationPolicy.shouldSelectRow(for: .trash) {
                        onSelect()
                    }
                    onTrash(row)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isTrashable ? Color.red : Color.secondary.opacity(0.35))
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isTrashable)
                .help(isTrashable
                      ? AppLocalization.string("tree.row.trash", locale: locale)
                      : AppLocalization.string("tree.row.trash.locked", locale: locale))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v2026.06.23 perf v2（Instruments 第五次取证 33334.md 14.23s）：
        // 上一刀 .frame(height: 26) 无效——栈里 NSTableRowData._doAutomaticRowHeightForRowView
        // 5.40s + _uncachedAutomaticRowHeight 5.39s 仍走 auto row height。
        // SwiftUI .frame(height:) 等价于 (minHeight:idealHeight:maxHeight: nil)，
        // NSHostingView 仍会 sizeThatFits 内部 child 来定 ideal。
        // 改用 (minHeight: maxHeight:) 把上下界都钉死成 26，NSHostingView 拿到的就是
        // 刚性 26pt 约束，跳过整条 _FlexFrameLayout → _AlignmentLayout → _PaddingLayout
        // → StackLayout 嵌套 sizeThatFits 链。
        // 26 = 行内最大元素（22pt chevron/icon） + 上下 padding(.vertical, 1) × 2。
        .frame(minHeight: 26, maxHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.65) : Color.clear,
                                      lineWidth: 1)
                )
        )
        .contextMenu {
            if let onTrash {
                // v2026.06 Step 1：contextMenu 也走 verdict 缓存。
                // contextMenu 在右键弹出时才求值（不算最 hot path），但既然已经算好就一起复用，
                // 一致性比微优化重要：后续维护者看到一处就知道全局都不再调 evaluate。
                let canInitiate = TreeBrowserView.canInitiateDeletion(
                    flat,
                    allowsVendorPathOverride: allowsVendorPathOverride
                )
                let requiresOverride = DeletionEntryPolicy.requiresVendorPathOverride(
                    verdict: flat.verdict,
                    rejection: flat.rejection,
                    allowsVendorPathOverride: allowsVendorPathOverride
                )
                Button(role: .destructive) {
                    guard canInitiate else { return }
                    onSelect()
                    onTrash(row)
                } label: {
                    Label {
                        Text(requiresOverride
                             ? "delete.vendor_override.action"
                             : (canInitiate ? "tree.menu.trash" : "tree.menu.trash_forbidden"),
                             bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(!canInitiate)
                .keyboardShortcut(.delete, modifiers: [])
                // v2026.06.18 **加入待处理**入口紧邻"移到废纸篓"，与"清空-vs-囤起来"
                // 是同一动作面的两种处置方式，放在一起手感更对。
                if let onStash {
                    Button {
                        onSelect()
                        onStash(row)
                    } label: {
                        Label {
                            Text(isStashed
                                 ? "tree.menu.stash_already"
                                 : "tree.menu.stash",
                                 bundle: .module)
                        } icon: {
                            Image(systemName: isStashed ? "tray.full.fill" : "tray.and.arrow.down")
                        }
                    }
                    .disabled(isStashed)
                }
                Divider()
            } else if let onStash {
                // 即使 onTrash 缺席（只读视图复用本组件）也允许"加入待处理"
                // —— 待处理本身不是破坏性操作，无需依赖删除链路。
                Button {
                    onSelect()
                    onStash(row)
                } label: {
                    Label {
                        Text(isStashed
                             ? "tree.menu.stash_already"
                             : "tree.menu.stash",
                             bundle: .module)
                    } icon: {
                        Image(systemName: isStashed ? "tray.full.fill" : "tray.and.arrow.down")
                    }
                }
                .disabled(isStashed)
                Divider()
            }
            // v2026.06.20 contextMenu 也提供"问 AI"项，与行内 sparkles 按钮等价。
            //
            // v1.5 P2 / Q3 修复：旧实现"未配置则不显示"——用户根本不知道有 AI 入口
            // 也不会被引导去设置。改为"只要 onAskAI 不为 nil 就显示"：未就绪时同样
            // 回调上层，由 MainView 在 callback 内弹"AI 未配置，前往设置？"alert，
            // 跟 List 视图保持一致行为。
            if let onAskAI {
                Button {
                    onSelect()
                    onAskAI(row)
                } label: {
                    Label {
                        Text("tree.menu.ask_ai", bundle: .module)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                }
                Divider()
            }
            Button {
                onSelect()
                QuickLookController.shared.preview(urls: [URL(fileURLWithPath: row.path)])
            } label: {
                Label {
                    Text("tree.menu.quick_look", bundle: .module)
                } icon: {
                    Image(systemName: "eye")
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            } label: {
                Label {
                    Text("tree.menu.reveal_in_finder", bundle: .module)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            Divider()
            if row.isDirectory, let onRefreshSubtree {
                Button {
                    onSelect()
                    onRefreshSubtree(row.path)
                } label: {
                    Label {
                        Text("tree.menu.refresh", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
            }
            if canExpand {
                Button {
                    onToggleExpand()
                } label: {
                    Label {
                        Text(isExpanded
                             ? "tree.disclose.collapse"
                             : "tree.disclose.expand",
                             bundle: .module)
                    } icon: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                }
                Divider()
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(row.path, forType: .string)
            } label: {
                Label {
                    Text("tree.menu.copy_path", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString((row.path as NSString).lastPathComponent, forType: .string)
            } label: {
                Label {
                    Text("tree.menu.copy_name", bundle: .module)
                } icon: {
                    Image(systemName: "textformat")
                }
            }
        }
    }

    /// v2026.06.20 行内"问 AI"按钮（sparkles）。抽到独立 ViewBuilder 以
    /// 防止 TreeNodeRow.body 过长触发 SwiftUI 编译器 "unable to type-check
    /// in reasonable time"。语义与 RowView 的 AI 入口对齐：
    /// - `onAskAI == nil` → 不出现（readonly / 无 AI 入口的视图）
    /// - `onAskAI != nil` 但 `aiSettings == nil || !isReadyForUI` →
    ///   出现，**淡 sparkles + tooltip 提示 "AI 未配置，点击前往设置"**，
    ///   点击仍回调 `onAskAI(row)`，由上层弹"前往设置？"alert（Q3 修复）
    /// - 都满足 → accentColor sparkles + 可点击，回调上层弹 AIAdviceSheet
    @ViewBuilder
    private var aiActionButton: some View {
        if let onAskAI {
            let aiReady = (aiSettings?.isReadyForUI == true)
            Button {
                // v1.5 P2 / Q3：未就绪时不再 beep（用户无感知）——直接回调上层，
                // MainView 负责弹"AI 未配置，前往设置？"alert，给用户明确引导。
                if InlineRowActionNavigationPolicy.shouldSelectRow(for: .askAI) {
                    onSelect()
                }
                onAskAI(row)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(aiReady ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(aiReady
                  ? AppLocalization.string("tree.row.ai", locale: locale)
                  : AppLocalization.string("tree.row.ai.not_configured", locale: locale))
        }
    }
}

/// 树行视图：图标 + 名称 + size + 体积条。复用 RowView 的视觉语言。
///
/// v1.3.zzzz：当 [row.accessState](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L116)
/// 不是 .normal 时，整行降级渲染：
/// - 文件夹图标后挂一个 lock.fill 小徽章
/// - 文字 / 体积 / 体积条全部走 .tertiary 灰阶
/// - .help() 改成"无访问权限"文案，鼠标 hover 提示用户去开 Full Disk Access
///
/// 这是为了治"我的 [Library/Safari](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L172)
/// 显示 0 KB 是不是 bug？"这一类用户疑惑——根因是
/// open(O_RDONLY) silent-deny，UI 必须把"被拒"和"真 0KB"区分开。
struct TreeBrowserRow: View {
    let row: TreeRow
    let maxBytes: Int64
    @Environment(\.locale) private var locale

    private var ratio: CGFloat {
        guard maxBytes > 0 else { return 0 }
        return CGFloat(Double(row.bytes) / Double(maxBytes))
    }

    /// 是否被权限拦掉（permissionDenied / tccProtected 都算）
    private var isAccessDenied: Bool { row.accessState != .normal }

    /// 文案分两档：tccProtected 是用户层"sandbox 整段拒"，
    /// permissionDenied 是运行时 open 失败；都建议用户去开 FDA 但措辞不同。
    private var deniedHelp: String {
        TreeBrowserLiveLocalization.accessHelp(for: row, locale: locale) ?? row.path
    }

    private func rowHelp(for metrics: TreeMetricPresentation) -> String {
        if isAccessDenied { return deniedHelp }
        guard let helpText = metrics.helpText else { return row.path }
        return row.path + "\n\n" + helpText
    }

    var body: some View {
        let metrics = TreeBrowserLiveLocalization.metricPresentation(row: row, locale: locale)
        HStack(spacing: 10) {
            // 图标 + 锁定叠加徽章（仅 accessDenied 时显示）
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(
                        isAccessDenied
                            ? Color.secondary.opacity(0.5)
                            : (row.isDirectory ? Color.accentColor : Color.secondary)
                    )
                    .frame(width: 16)
                if isAccessDenied {
                    // 右下角 8pt 锁徽章；用 capsule 衬底防止跟文件夹尖角混在一起
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Color.orange))
                        .offset(x: 4, y: 3)
                } else if metrics.state == .lowerBound {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .offset(x: 4, y: 3)
                        .accessibilityLabel(Text(metrics.partialStatusText ?? ""))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.title.isEmpty ? row.path : row.displayTitle(locale: locale))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(isAccessDenied ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                isAccessDenied
                                    ? Color.secondary.opacity(0.25)
                                    : Color.accentColor.opacity(row.isDirectory ? 0.7 : 0.4)
                            )
                            .frame(width: geo.size.width * ratio, height: 3)
                    }
                }
                .frame(height: 3)
            }
            // accessDenied 时把 size 改成"—"，避免"0 KB"的误导性显示
            Text(metrics.size.compactText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isAccessDenied ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)
            Text(metrics.count.compactText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
            // v1.5.4：mtime 列——与 LargeFilesView 文案风格一致，省"x天前"等本地化偏差。
            // accessDenied 行直接画"—"避免误导；mtime 缺失（极早期 publish 帧或 root 顶层）也画"—"。
            Text(TreeBrowserRow.mtimeDisplay(
                row.modificationDate,
                denied: isAccessDenied,
                locale: locale
            ))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 98, alignment: .trailing)
                .help(TreeBrowserRow.mtimeFullHelp(row.modificationDate, locale: locale))
        }
        .padding(.vertical, 2)
        .opacity(isAccessDenied ? 0.7 : 1.0)
        .help(rowHelp(for: metrics))
    }

    /// v1.5.4：列内 mtime 短文案。
    /// - accessDenied → "—"（语义："无法访问"）
    /// - 目录/文件存在但无 mtime（聚合根 / 虚拟节点 / 首帧 publish）→ "·"
    ///   v2026.06.18：用户反馈"为什么 Modified 没有了"——根行（如"Xcode Build Artifacts"）
    ///   是聚合虚拟节点，没有自身 inode，所以拿不到 mtime。把"—"和"·"区分开能让
    ///   用户一眼看出"这不是 bug，是这一行本来就没有自己的修改时间"。
    /// - 当年 → "MM-dd"
    /// - 跨年 → "yyyy-MM-dd"
    /// 用 cached formatter 避免每行重新建（SwiftUI body 高频重算）。
    static func mtimeDisplay(_ date: Date?, denied: Bool, locale: Locale) -> String {
        TreeBrowserLiveLocalization.mtimeDisplay(date, denied: denied, locale: locale)
    }

    /// 鼠标悬停时显示完整时间——窄列里的省略不丢精度。
    /// v2026.06.18：mtime 缺失时给出明确的解释，避免被误解为"bug 没读到"。
    static func mtimeFullHelp(_ date: Date?, locale: Locale) -> String {
        TreeBrowserLiveLocalization.mtimeFullHelp(date, locale: locale)
    }
}
