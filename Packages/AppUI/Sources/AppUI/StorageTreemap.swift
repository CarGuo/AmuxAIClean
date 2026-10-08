import CoreGraphics
import Foundation

/// v2026.09.06: a treemap describes measured allocation, never cleanup eligibility.
/// Only positive, settled measurements receive area. Small items retain their exact
/// combined area in an explicit group; every item remains reachable through the list.
struct StorageMapItem: Identifiable, Sendable, Equatable {
    let id: String
    let row: TreeRow?
    let bytes: Int64
    let groupedCount: Int
    let colorIndex: Int
}

enum StorageDirectoryListScope: Sendable, Equatable {
    case all, smallerItems
}

struct StorageDirectoryProjection: Sendable, Equatable {
    let rows: [TreeRow]
    let mapItems: [StorageMapItem]
    let totalCount: Int
    let measuredBytes: Int64
    let incompleteCount: Int
    let pendingCount: Int
    let mapPresentation: StorageTreemapPresentation
    let listScope: StorageDirectoryListScope
    let listedCount: Int

    static func make(
        rows: [TreeRow], query: String, limit: Int, locale: Locale,
        viewportSize: CGSize = .zero, listScope: StorageDirectoryListScope = .all,
        receiptTombstones: DeletionPresentationPathMatcher = .init(paths: EmptyCollection<String>())
    ) throws -> Self {
        var inspected = 0
        let filtered = try rows.filter {
            inspected += 1
            if inspected.isMultiple(of: 256) { try Task.checkCancellation() }
            // v2026.10.08: use the same frozen receipt index as Tree, on this background worker.
            // Filtering before search/grouping keeps tiles, rows and totals on one visible set.
            guard !receiptTombstones.contains($0.path) else { return false }
            return query.isEmpty
                || $0.displayTitle(locale: locale).range(
                    of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale
                ) != nil
        }.sorted { lhs, rhs in
            inspected += 1
            if inspected.isMultiple(of: 256) { try Task.checkCancellation() }
            if lhs.isSizePending != rhs.isSizePending { return !lhs.isSizePending }
            return lhs.bytes == rhs.bytes ? lhs.path < rhs.path : lhs.bytes > rhs.bytes
        }
        try Task.checkCancellation()
        let measured = filtered.filter { !$0.isSizePending && $0.bytes > 0 }
        let visible = measured.prefix(40)
        var items = visible.map {
            StorageMapItem(
                id: $0.path, row: $0, bytes: $0.bytes,
                groupedCount: 0, colorIndex: colorIndex(for: $0.path))
        }
        let tail = measured.dropFirst(40)
        if !tail.isEmpty {
            items.append(
                StorageMapItem(
                    id: "group:remaining", row: nil,
                    bytes: sum(tail.map(\.bytes)),
                    groupedCount: tail.count, colorIndex: 5))
        }
        // v2026.09.06: grouping follows the available label geometry, not just the
        // 40-item rendering budget. The same projection owns group membership and
        // its paginated list, so a group never jumps to an arbitrary list offset.
        let presentation = StorageTreemapPresentation.make(items: items, size: viewportSize)
        let effectiveScope: StorageDirectoryListScope =
            listScope == .smallerItems && presentation.smallerItems != nil ? .smallerItems : .all
        let listed = effectiveScope == .smallerItems
            ? measured.filter { !presentation.individualPaths.contains($0.path) } : filtered
        return Self(
            rows: Array(listed.prefix(max(1, limit))), mapItems: items,
            totalCount: filtered.count, measuredBytes: sum(measured.map(\.bytes)),
            incompleteCount: filtered.filter { !$0.hasCompleteAccessEvidence }.count,
            pendingCount: filtered.filter(\.isSizePending).count,
            mapPresentation: presentation, listScope: effectiveScope, listedCount: listed.count)
    }

    fileprivate static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { result, value in
            let next = result.addingReportingOverflow(max(0, value))
            return next.overflow ? .max : next.partialValue
        }
    }

    /// Stable across launches, locale changes and sort orders (Swift Hasher is randomized).
    static func colorIndex(for path: String) -> Int {
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Int(hash % 6)
    }
}

struct StorageMapRect: Identifiable, Sendable, Equatable {
    let item: StorageMapItem
    let rect: CGRect
    var id: String { item.id }
}

/// v2026.09.06: a visible individual cell must fit BOTH its name and byte count.
/// Unreadable cells share one proportional region with an always-readable list
/// button outside the map. We never enlarge their areas or lose their membership.
/// This runs in the directory projection worker; resizing cannot sort on MainActor.
struct StorageTreemapPresentation: Sendable, Equatable {
    static let cellGap: CGFloat = 5
    static let cellPadding: CGFloat = 8
    // Two compact text lines, their spacing, insets, and the inter-cell gap.
    static let minimumSummarySize = CGSize(width: 104, height: 56)
    static let minimumGroupSummarySize = CGSize(width: 88, height: 56)
    static let groupButtonHeight: CGFloat = 44
    static let groupButtonSpacing: CGFloat = 8

    let cells: [StorageMapRect]
    let smallerItems: StorageMapItem?
    let chartSize: CGSize
    let individualPaths: Set<String>

    static func fitsSummary(_ rect: CGRect) -> Bool {
        rect.width >= minimumSummarySize.width && rect.height >= minimumSummarySize.height
    }

    static func make(items: [StorageMapItem], size: CGSize) -> Self {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            (size.width * size.height).isFinite
        else {
            return Self(cells: [], smallerItems: nil, chartSize: .zero, individualPaths: [])
        }
        let full = groupedLayout(items: items, size: size)
        guard full.smallerItems != nil else { return full }
        // Reserve the list button before the final layout, avoiding an on/off
        // geometry feedback loop when a group sits exactly at the readable limit.
        return groupedLayout(
            items: items,
            size: CGSize(
                width: size.width,
                height: max(0, size.height - groupButtonHeight - groupButtonSpacing)))
    }

    private static func groupedLayout(items: [StorageMapItem], size: CGSize) -> Self {
        var individuals = items.filter { $0.row != nil && $0.bytes > 0 }
        var grouped = items.filter { $0.row == nil && $0.bytes > 0 }
        while true {
            let group: StorageMapItem? = grouped.isEmpty ? nil : StorageMapItem(
                id: "group:smaller-items", row: nil,
                bytes: StorageDirectoryProjection.sum(grouped.map(\.bytes)),
                groupedCount: grouped.reduce(0) { $0 + ($1.row == nil ? $1.groupedCount : 1) },
                colorIndex: 5)
            let candidates = (individuals + (group.map { [$0] } ?? [])).sorted {
                $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
            }
            let cells = StorageTreemapLayout.rectangles(items: candidates, size: size)
            let readable = Set(cells.filter { $0.item.row != nil && fitsSummary($0.rect) }.map(\.id))
            let unreadable = individuals.filter { !readable.contains($0.id) }
            if unreadable.isEmpty {
                return Self(cells: cells, smallerItems: group, chartSize: size, individualPaths: readable)
            }
            // Every iteration removes at least one of the <= 40 individual cells.
            // Re-layout can change other cells' aspect ratios, so recheck all of them.
            grouped.append(contentsOf: unreadable)
            individuals.removeAll { !readable.contains($0.id) }
        }
    }
}

/// Squarified treemaps (Bruls, Huizing, van Wijk, 2000), implemented from the
/// published area/aspect-ratio method. This bounded UI layout has at most 41 cells;
/// filesystem traversal, sorting and aggregation happen before it reaches the View.
enum StorageTreemapLayout {
    static func rectangles(items: [StorageMapItem], size: CGSize) -> [StorageMapRect] {
        guard size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return [] }
        let valid = items.filter { $0.bytes > 0 }
        let total = valid.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return [] }
        let scale = size.width * size.height / total
        let areas = valid.map { Double($0.bytes) * scale }
        var remaining = CGRect(origin: .zero, size: size)
        var result: [StorageMapRect] = []
        var start = 0
        while start < valid.count {
            let side = min(remaining.width, remaining.height)
            guard side > 0 else { break }
            var end = start + 1
            var sum = areas[start]
            var smallest = areas[start]
            var largest = areas[start]
            var ratio = worst(sum: sum, min: smallest, max: largest, side: side)
            while end < valid.count {
                let nextSum = sum + areas[end]
                let nextMin = min(smallest, areas[end])
                let nextMax = max(largest, areas[end])
                let nextRatio = worst(sum: nextSum, min: nextMin, max: nextMax, side: side)
                if nextRatio > ratio { break }
                sum = nextSum
                smallest = nextMin
                largest = nextMax
                ratio = nextRatio
                end += 1
            }
            let vertical = remaining.width >= remaining.height
            let thickness = sum / side
            var offset = vertical ? remaining.minY : remaining.minX
            for index in start..<end {
                let length = areas[index] / thickness
                let rect =
                    vertical
                    ? CGRect(x: remaining.minX, y: offset, width: thickness, height: length)
                    : CGRect(x: offset, y: remaining.minY, width: length, height: thickness)
                result.append(StorageMapRect(item: valid[index], rect: rect))
                offset += length
            }
            if vertical {
                remaining.origin.x += thickness
                remaining.size.width = max(0, remaining.width - thickness)
            } else {
                remaining.origin.y += thickness
                remaining.size.height = max(0, remaining.height - thickness)
            }
            start = end
        }
        return result
    }

    private static func worst(sum: Double, min: Double, max: Double, side: Double) -> Double {
        Swift.max(side * side * max / (sum * sum), sum * sum / (side * side * min))
    }
}
