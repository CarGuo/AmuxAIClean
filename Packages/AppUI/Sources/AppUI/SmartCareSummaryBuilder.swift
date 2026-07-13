import Foundation
import SafetyKit

/// Smart Care 候选来自哪一种现有能力。来源只决定展示分桶优先级，
/// 最终能否选择和清理仍完全由 `SafetyVerdict` 决定。
public enum SmartCareCandidateSource: String, CaseIterable, Sendable, Hashable {
    case recommended
    case commonAppCache
    case developer
    case largeFiles
    case appLeftovers
    case duplicates
}

/// 各扫描器输出进入普通模式前的归一格式。
public struct SmartCareCandidate: Sendable, Hashable {
    public let source: SmartCareCandidateSource
    public let bucketID: SmartCareBucketID
    public let path: String
    public let title: String
    public let bytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    public let verdict: SafetyVerdict
    public let riskNote: String?
    public let runningBundleIDPrefix: String?

    public init(source: SmartCareCandidateSource,
                bucketID: SmartCareBucketID,
                path: String,
                title: String,
                bytes: Int64,
                logicalBytes: Int64? = nil,
                fileCount: Int = 0,
                isDirectory: Bool = true,
                verdict: SafetyVerdict,
                riskNote: String? = nil,
                runningBundleIDPrefix: String? = nil) {
        self.source = source
        self.bucketID = bucketID
        self.path = path
        self.title = title
        self.bytes = bytes
        self.logicalBytes = logicalBytes ?? bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.verdict = verdict
        self.riskNote = riskNote
        self.runningBundleIDPrefix = runningBundleIDPrefix
    }
}

/// 一次后台聚合事务的完整结果。
///
/// `candidates` 已完成路径标准化、同路径合并与父子折叠，可直接替换 checkpoint
/// 中的旧值；调用方不需要在 MainActor 上复制或 append 大数组。
struct SmartCareAggregationResult: Sendable {
    let candidates: [SmartCareCandidate]
    let summary: SmartCareSummary
}

/// 可协作取消的稳定排序。取消只发生在有界 merge 步骤之间，不会把可变状态
/// 塞进 comparator、破坏 strict weak ordering；相同元素保持输入顺序。
enum SmartCareCancellableAlgorithms {
    static func stableSorted<Element>(
        _ elements: [Element],
        by areInIncreasingOrder: (Element, Element) -> Bool,
        shouldCancel: () -> Bool
    ) -> [Element]? {
        guard !shouldCancel() else { return nil }
        guard elements.count > 1 else { return elements }

        var source = elements
        var destination = elements
        var width = 1
        var processed = 0

        while width < source.count {
            var lowerBound = 0
            while lowerBound < source.count {
                let middle = min(lowerBound + width, source.count)
                let upperBound = min(middle + width, source.count)
                var left = lowerBound
                var right = middle
                var output = lowerBound

                while output < upperBound {
                    if processed.isMultiple(of: SmartCareAggregationCancellation.checkStride),
                       shouldCancel() {
                        return nil
                    }
                    processed &+= 1

                    if left >= middle {
                        destination[output] = source[right]
                        right &+= 1
                    } else if right >= upperBound {
                        destination[output] = source[left]
                        left &+= 1
                    } else if areInIncreasingOrder(source[right], source[left]) {
                        destination[output] = source[right]
                        right &+= 1
                    } else {
                        destination[output] = source[left]
                        left &+= 1
                    }
                    output &+= 1
                }
                lowerBound = upperBound
            }

            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
        }
        return shouldCancel() ? nil : source
    }
}

/// 把推荐清理、常见应用缓存、开发缓存等现有结果收敛为普通模式摘要。
///
/// 同一路径可能被多个扫描源命中。合并遵循三个安全合同：
/// - 只计一次容量，避免普通模式夸大可释放空间；
/// - 容量取最大值，不把不同扫描口径相加；
/// - verdict 只会升级到更严格等级，绝不因另一个来源为 safe 而降级。
public enum SmartCareSummaryBuilder {
    private static let cancellationCheckStride = SmartCareAggregationCancellation.checkStride

    public static func candidates(from rows: [RowItem],
                                  source: SmartCareCandidateSource,
                                  home: String = NSHomeDirectory()) -> [SmartCareCandidate] {
        guard let candidates = candidatesImplementation(
            from: rows,
            source: source,
            home: home,
            shouldCancel: { false }
        ) else {
            preconditionFailure("Non-cancellable Smart Care candidate conversion was cancelled")
        }
        return candidates
    }

    /// 后台聚合入口。调用方把这个方法放进与父任务显式绑定的 detached task；
    /// 大结果集转换期间每批检查一次取消，避免用户停止扫描后旧轮次继续占用 CPU。
    public static func candidatesCheckingCancellation(
        from rows: [RowItem],
        source: SmartCareCandidateSource,
        home: String = NSHomeDirectory()
    ) throws -> [SmartCareCandidate] {
        guard let candidates = candidatesImplementation(
            from: rows,
            source: source,
            home: home,
            shouldCancel: { Task.isCancelled }
        ) else {
            throw CancellationError()
        }
        return candidates
    }

    private static func candidatesImplementation(
        from rows: [RowItem],
        source: SmartCareCandidateSource,
        home: String,
        shouldCancel: () -> Bool
    ) -> [SmartCareCandidate]? {
        var candidates: [SmartCareCandidate] = []
        candidates.reserveCapacity(rows.count)
        guard appendCandidates(
            from: rows,
            source: source,
            home: home,
            to: &candidates,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }
        return candidates
    }

    private static func appendCandidates(
        from rows: [RowItem],
        source: SmartCareCandidateSource,
        home: String,
        to candidates: inout [SmartCareCandidate],
        shouldCancel: () -> Bool
    ) -> Bool {
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return false
            }
            candidates.append(SmartCareCandidate(
                source: source,
                bucketID: bucketID(for: row.url.path, source: source, home: home),
                path: row.url.path,
                title: row.title,
                bytes: row.bytes,
                logicalBytes: row.logicalBytes,
                fileCount: row.fileCount,
                isDirectory: row.isDirectory,
                verdict: row.verdict,
                riskNote: row.vendorNote,
                runningBundleIDPrefix: row.runningBundleIDPrefix
            ))
        }
        return !shouldCancel()
    }

    public static func build(candidates: [SmartCareCandidate]) -> SmartCareSummary {
        guard let result = aggregateImplementation(candidates: candidates, shouldCancel: { false }) else {
            preconditionFailure("Non-cancellable Smart Care summary build was cancelled")
        }
        return result.summary
    }

    /// 可取消的摘要构建入口。去重、层级折叠、分桶和桶内排序之间都会检查取消，
    /// 让新扫描不必等待旧轮次的大集合聚合自然结束。
    public static func buildCheckingCancellation(
        candidates: [SmartCareCandidate]
    ) throws -> SmartCareSummary {
        guard let result = aggregateImplementation(
            candidates: candidates,
            shouldCancel: { Task.isCancelled }
        ) else {
            throw CancellationError()
        }
        return result.summary
    }

    /// 把一阶段的最终 rows 与上一个 checkpoint 合并为新的完整 checkpoint。
    /// 所有数组扩容、路径归一、去重、层级折叠和排序都在调用方的 detached worker 内完成。
    static func aggregateCheckingCancellation(
        existingCandidates: [SmartCareCandidate],
        rows: [RowItem],
        source: SmartCareCandidateSource,
        home: String = NSHomeDirectory()
    ) throws -> SmartCareAggregationResult {
        var combined = existingCandidates
        combined.reserveCapacity(existingCandidates.count + rows.count)
        guard appendCandidates(
            from: rows,
            source: source,
            home: home,
            to: &combined,
            shouldCancel: { Task.isCancelled }
        ), let result = aggregateImplementation(
            candidates: combined,
            shouldCancel: { Task.isCancelled }
        ) else {
            throw CancellationError()
        }
        return result
    }

    private static func aggregateImplementation(
        candidates: [SmartCareCandidate],
        shouldCancel: () -> Bool
    ) -> SmartCareAggregationResult? {
        var mergedByPath: [String: SmartCareCandidate] = [:]
        mergedByPath.reserveCapacity(candidates.count)

        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return nil
            }
            let normalized = normalizedCandidate(candidate)
            guard !normalized.path.isEmpty else { continue }
            if let existing = mergedByPath[normalized.path] {
                mergedByPath[normalized.path] = merge(existing, normalized)
            } else {
                mergedByPath[normalized.path] = normalized
            }
        }

        // 目录扫描源可能同时返回父目录与其子目录（例如 Google 与
        // Google/Chrome）。父子同时计数会夸大容量，提交删除时也会重复授权。
        // 这里按路径树折叠：保留父路径，并把任一后代的更严格 verdict 上卷。
        guard !shouldCancel(),
              let mergedCandidates = materializeValues(
                mergedByPath.values,
                expectedCount: mergedByPath.count,
                shouldCancel: shouldCancel
              ),
              let collapsedCandidates = collapseHierarchy(
                mergedCandidates,
                shouldCancel: shouldCancel
              ) else {
            return nil
        }

        var grouped: [SmartCareBucketID: [SmartCareItem]] = [:]
        grouped.reserveCapacity(SmartCareBucketID.allCases.count)
        for (index, candidate) in collapsedCandidates.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return nil
            }
            grouped[candidate.bucketID, default: []].append(
                SmartCareItem(
                    id: candidate.path,
                    bucketID: candidate.bucketID,
                    path: candidate.path,
                    title: candidate.title,
                    bytes: candidate.bytes,
                    logicalBytes: candidate.logicalBytes,
                    fileCount: candidate.fileCount,
                    isDirectory: candidate.isDirectory,
                    verdict: candidate.verdict,
                    riskNote: candidate.riskNote,
                    runningBundleIDPrefix: candidate.runningBundleIDPrefix
                )
            )
        }

        var buckets: [SmartCareBucketSummary] = []
        buckets.reserveCapacity(SmartCareBucketID.allCases.count)
        for bucketID in SmartCareBucketID.allCases {
            guard !shouldCancel() else { return nil }
            guard let items = SmartCareCancellableAlgorithms.stableSorted(
                grouped[bucketID] ?? [],
                by: itemPriorityOrder,
                shouldCancel: shouldCancel
            ) else { return nil }
            guard let bucket = SmartCareBucketSummary.make(
                id: bucketID,
                items: items,
                shouldCancel: shouldCancel
            ) else { return nil }
            buckets.append(bucket)
        }
        guard !shouldCancel(),
              let summary = SmartCareSummary.make(
                buckets: buckets,
                shouldCancel: shouldCancel
              ) else { return nil }
        return SmartCareAggregationResult(
            candidates: collapsedCandidates,
            summary: summary
        )
    }

    public static func removing(paths: [String], from summary: SmartCareSummary) -> SmartCareSummary {
        guard let removed = RemovalPathIndex(paths: paths, shouldCancel: { false }) else {
            preconditionFailure("Non-cancellable Smart Care removal index was cancelled")
        }
        guard !removed.isEmpty else { return summary }
        return SmartCareSummary(
            buckets: summary.buckets.map { bucket in
                SmartCareBucketSummary(
                    id: bucket.id,
                    items: bucket.items.filter {
                        !removed.overlaps(normalizePath($0.path))
                    }
                )
            }
        )
    }

    /// 从 checkpoint 的 canonical candidates 移除与真实成功路径重叠的条目并重建摘要。
    /// 删除了候选的子项时也移除其祖先候选，因为旧聚合大小已经失真，继续展示会诱导重复清理。
    static func removingCandidatesCheckingCancellation(
        paths: [String],
        from candidates: [SmartCareCandidate]
    ) throws -> SmartCareAggregationResult {
        guard let removalIndex = RemovalPathIndex(
            paths: paths,
            shouldCancel: { Task.isCancelled }
        ) else {
            throw CancellationError()
        }
        guard !removalIndex.isEmpty else {
            guard let result = aggregateImplementation(
                candidates: candidates,
                shouldCancel: { Task.isCancelled }
            ) else { throw CancellationError() }
            return result
        }

        var retained: [SmartCareCandidate] = []
        retained.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), Task.isCancelled {
                throw CancellationError()
            }
            let path = normalizePath(candidate.path)
            if !removalIndex.overlaps(path) {
                retained.append(candidate)
            }
        }
        guard !Task.isCancelled,
              let result = aggregateImplementation(
                candidates: retained,
                shouldCancel: { Task.isCancelled }
              ) else {
            throw CancellationError()
        }
        return result
    }

    static func removingCandidates(
        paths: [String],
        from candidates: [SmartCareCandidate]
    ) -> SmartCareAggregationResult {
        do {
            return try removingCandidatesCheckingCancellation(paths: paths, from: candidates)
        } catch {
            preconditionFailure("Non-cancellable Smart Care deletion reconciliation was cancelled")
        }
    }

    public static func bucketID(for path: String,
                                source: SmartCareCandidateSource,
                                home: String = NSHomeDirectory()) -> SmartCareBucketID {
        switch source {
        case .commonAppCache:
            return .appCache
        case .developer:
            return .developerCache
        case .largeFiles:
            return .largeFiles
        case .appLeftovers:
            return .appLeftovers
        case .duplicates:
            return .duplicates
        case .recommended:
            return recommendedBucketID(for: path, home: home)
        }
    }

    private static func recommendedBucketID(for path: String, home: String) -> SmartCareBucketID {
        let normalized = normalizePath(path)
        let normalizedHome = normalizePath(home)
        let developerPrefixes = [
            "\(normalizedHome)/Library/Developer",
            "\(normalizedHome)/.gradle",
            "\(normalizedHome)/.m2",
            "\(normalizedHome)/.cargo",
            "\(normalizedHome)/.cache/pip",
            "\(normalizedHome)/go/pkg/mod"
        ]
        if developerPrefixes.contains(where: { isPath(normalized, inside: $0) }) {
            return .developerCache
        }

        let cachePrefixes = [
            "\(normalizedHome)/Library/Caches",
            "\(normalizedHome)/Library/HTTPStorages"
        ]
        if cachePrefixes.contains(where: { isPath(normalized, inside: $0) })
            || normalized.contains("/Data/Library/Caches/")
            || normalized.hasSuffix("/Data/Library/Caches") {
            return .appCache
        }

        let logPrefix = "\(normalizedHome)/Library/Logs"
        if isPath(normalized, inside: logPrefix) {
            return .systemJunk
        }

        // 推荐扫描还包含 Downloads 与 .Trash。它们是用户个人文件，不是
        // “系统垃圾”；归入仅供复核的内部桶，普通模式不会把它们展示成安全类别。
        return .largeFiles
    }

    private static func merge(_ existing: SmartCareCandidate,
                              _ incoming: SmartCareCandidate) -> SmartCareCandidate {
        let preferred = sourcePriority(incoming.source) > sourcePriority(existing.source)
            ? incoming
            : existing
        let stricter = verdictPriority(incoming.verdict) > verdictPriority(existing.verdict)
            ? incoming
            : existing
        let verdict = verdictPriority(incoming.verdict) > verdictPriority(existing.verdict)
            ? incoming.verdict
            : existing.verdict
        let title = firstNonEmpty(preferred.title, existing.title, incoming.title)
            ?? (preferred.path as NSString).lastPathComponent
        let riskNote = firstNonEmpty(stricter.riskNote,
                                     preferred.riskNote,
                                     existing.riskNote,
                                     incoming.riskNote)

        return SmartCareCandidate(
            source: preferred.source,
            bucketID: preferred.bucketID,
            path: existing.path,
            title: title,
            bytes: max(existing.bytes, incoming.bytes),
            logicalBytes: max(existing.logicalBytes, incoming.logicalBytes),
            fileCount: max(existing.fileCount, incoming.fileCount),
            isDirectory: preferred.isDirectory,
            verdict: verdict,
            riskNote: riskNote,
            runningBundleIDPrefix: firstNonEmpty(
                stricter.runningBundleIDPrefix,
                preferred.runningBundleIDPrefix,
                existing.runningBundleIDPrefix,
                incoming.runningBundleIDPrefix
            )
        )
    }

    private static func collapseHierarchy(
        _ candidates: [SmartCareCandidate],
        shouldCancel: () -> Bool
    ) -> [SmartCareCandidate]? {
        guard !shouldCancel() else { return nil }
        // 深度只计算一次；若在 sort comparator 内反复拆 pathComponents，
        // 2 万候选会放大成 O(n log n) 次 URL 规范化，实测超过 3 秒。
        var depthEntries: [(candidate: SmartCareCandidate, depth: Int)] = []
        depthEntries.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return nil
            }
            depthEntries.append((candidate, pathDepth(candidate.path)))
        }
        guard let sorted = SmartCareCancellableAlgorithms.stableSorted(
            depthEntries,
            by: { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.candidate.path < rhs.candidate.path
            },
            shouldCancel: shouldCancel
        ) else { return nil }

        var retainedByPath: [String: SmartCareCandidate] = [:]
        retainedByPath.reserveCapacity(sorted.count)
        var retainedPaths: [String] = []
        retainedPaths.reserveCapacity(sorted.count)
        for (index, entry) in sorted.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return nil
            }
            let candidate = entry.candidate
            if let ancestorPath = nearestRetainedAncestor(of: candidate.path,
                                                          retainedByPath: retainedByPath),
               let ancestor = retainedByPath[ancestorPath] {
                retainedByPath[ancestorPath] = mergeContained(ancestor: ancestor,
                                                               descendant: candidate)
            } else {
                retainedByPath[candidate.path] = candidate
                retainedPaths.append(candidate.path)
            }
        }
        guard !shouldCancel() else { return nil }
        var retained: [SmartCareCandidate] = []
        retained.reserveCapacity(retainedPaths.count)
        for (index, path) in retainedPaths.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return nil
            }
            guard let candidate = retainedByPath[path] else {
                preconditionFailure("Retained Smart Care path must have a candidate")
            }
            retained.append(candidate)
        }
        return shouldCancel() ? nil : retained
    }

    private static func materializeValues<Values: Collection>(
        _ values: Values,
        expectedCount: Int,
        shouldCancel: () -> Bool
    ) -> [Values.Element]? {
        var result: [Values.Element] = []
        result.reserveCapacity(expectedCount)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: cancellationCheckStride), shouldCancel() {
                return nil
            }
            result.append(value)
        }
        return shouldCancel() ? nil : result
    }

    private static func itemPriorityOrder(_ lhs: SmartCareItem, _ rhs: SmartCareItem) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.path < rhs.path
    }

    private static func nearestRetainedAncestor(
        of path: String,
        retainedByPath: [String: SmartCareCandidate]
    ) -> String? {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "/" {
            if retainedByPath[parent] != nil { return parent }
            let next = (parent as NSString).deletingLastPathComponent
            if next == parent { break }
            parent = next
        }
        return retainedByPath["/"] == nil ? nil : "/"
    }

    private static func mergeContained(ancestor: SmartCareCandidate,
                                       descendant: SmartCareCandidate) -> SmartCareCandidate {
        let descendantIsStricter = verdictPriority(descendant.verdict) > verdictPriority(ancestor.verdict)
        let verdict = descendantIsStricter ? descendant.verdict : ancestor.verdict
        return SmartCareCandidate(
            source: ancestor.source,
            bucketID: ancestor.bucketID,
            path: ancestor.path,
            title: ancestor.title,
            bytes: max(ancestor.bytes, descendant.bytes),
            logicalBytes: max(ancestor.logicalBytes, descendant.logicalBytes),
            fileCount: max(ancestor.fileCount, descendant.fileCount),
            isDirectory: ancestor.isDirectory,
            verdict: verdict,
            riskNote: descendantIsStricter
                ? firstNonEmpty(descendant.riskNote, ancestor.riskNote)
                : firstNonEmpty(ancestor.riskNote, descendant.riskNote),
            runningBundleIDPrefix: descendantIsStricter
                ? firstNonEmpty(descendant.runningBundleIDPrefix, ancestor.runningBundleIDPrefix)
                : firstNonEmpty(ancestor.runningBundleIDPrefix, descendant.runningBundleIDPrefix)
        )
    }

    private static func pathDepth(_ path: String) -> Int {
        path.utf8.reduce(into: 0) { depth, byte in
            if byte == 47 { depth += 1 }
        }
    }

    private static func normalizedCandidate(_ candidate: SmartCareCandidate) -> SmartCareCandidate {
        let path = normalizePath(candidate.path)
        let title = firstNonEmpty(candidate.title) ?? (path as NSString).lastPathComponent
        return SmartCareCandidate(
            source: candidate.source,
            bucketID: candidate.bucketID,
            path: path,
            title: title,
            bytes: max(0, candidate.bytes),
            logicalBytes: max(0, candidate.logicalBytes),
            fileCount: max(0, candidate.fileCount),
            isDirectory: candidate.isDirectory,
            verdict: candidate.verdict,
            riskNote: firstNonEmpty(candidate.riskNote),
            runningBundleIDPrefix: firstNonEmpty(candidate.runningBundleIDPrefix)
        )
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 对称的组件边界 overlap 索引：
    /// - candidate 在 removal root 下：沿祖先 Set 查询，O(depth)
    /// - candidate 是 removal root 祖先：排序 lowerBound 查询首个后代，O(log n)
    /// 构建时先去重并折叠已被祖先覆盖的 roots，避免批量删除 N×N 扫描。
    private struct RemovalPathIndex {
        let roots: [String]
        let rootSet: Set<String>

        init?(paths: [String], shouldCancel: () -> Bool) {
            var normalized: Set<String> = []
            normalized.reserveCapacity(paths.count)
            for (index, path) in paths.enumerated() {
                if index.isMultiple(of: SmartCareAggregationCancellation.checkStride),
                   shouldCancel() {
                    return nil
                }
                let normalizedPath = normalizePath(path)
                if !normalizedPath.isEmpty { normalized.insert(normalizedPath) }
            }
            guard let sortedRoots = SmartCareCancellableAlgorithms.stableSorted(
                Array(normalized),
                by: (<),
                shouldCancel: shouldCancel
            ) else { return nil }
            var minimalRoots: [String] = []
            var minimalRootSet: Set<String> = []
            minimalRoots.reserveCapacity(normalized.count)
            minimalRootSet.reserveCapacity(normalized.count)
            for (index, root) in sortedRoots.enumerated() {
                if index.isMultiple(of: SmartCareAggregationCancellation.checkStride),
                   shouldCancel() {
                    return nil
                }
                if Self.hasAncestor(of: root, in: minimalRootSet) { continue }
                minimalRoots.append(root)
                minimalRootSet.insert(root)
            }
            guard !shouldCancel() else { return nil }
            self.roots = minimalRoots
            self.rootSet = minimalRootSet
        }

        var isEmpty: Bool { roots.isEmpty }

        func overlaps(_ path: String) -> Bool {
            guard !path.isEmpty, !roots.isEmpty else { return false }
            if Self.hasAncestor(of: path, in: rootSet) { return true }
            if path == "/" { return true }
            let descendantPrefix = path + "/"
            let index = lowerBound(of: descendantPrefix)
            return index < roots.count && roots[index].hasPrefix(descendantPrefix)
        }

        private func lowerBound(of value: String) -> Int {
            var lower = 0
            var upper = roots.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if roots[middle] < value {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private static func hasAncestor(of path: String, in roots: Set<String>) -> Bool {
            var cursor = path
            while !cursor.isEmpty {
                if roots.contains(cursor) { return true }
                if cursor == "/" { return false }
                cursor = parentPath(of: cursor)
            }
            return false
        }

        private static func parentPath(of path: String) -> String {
            guard let slash = path.lastIndex(of: "/") else { return "" }
            if slash == path.startIndex { return "/" }
            return String(path[..<slash])
        }
    }

    private static func isPath(_ path: String, inside prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func sourcePriority(_ source: SmartCareCandidateSource) -> Int {
        switch source {
        case .recommended: return 0
        case .duplicates: return 1
        case .largeFiles: return 2
        case .commonAppCache: return 3
        case .developer: return 4
        case .appLeftovers: return 5
        }
    }

    private static func verdictPriority(_ verdict: SafetyVerdict) -> Int {
        switch verdict {
        case .safe: return 0
        case .confirm: return 1
        case .forbid: return 2
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
