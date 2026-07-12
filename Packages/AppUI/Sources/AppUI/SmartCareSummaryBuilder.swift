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

/// 把推荐清理、常见应用缓存、开发缓存等现有结果收敛为普通模式摘要。
///
/// 同一路径可能被多个扫描源命中。合并遵循三个安全合同：
/// - 只计一次容量，避免普通模式夸大可释放空间；
/// - 容量取最大值，不把不同扫描口径相加；
/// - verdict 只会升级到更严格等级，绝不因另一个来源为 safe 而降级。
public enum SmartCareSummaryBuilder {
    public static func candidates(from rows: [RowItem],
                                  source: SmartCareCandidateSource,
                                  home: String = NSHomeDirectory()) -> [SmartCareCandidate] {
        rows.map { row in
            SmartCareCandidate(
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
            )
        }
    }

    public static func build(candidates: [SmartCareCandidate]) -> SmartCareSummary {
        var mergedByPath: [String: SmartCareCandidate] = [:]
        mergedByPath.reserveCapacity(candidates.count)

        for candidate in candidates {
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
        let collapsedCandidates = collapseHierarchy(Array(mergedByPath.values))

        var grouped: [SmartCareBucketID: [SmartCareItem]] = [:]
        grouped.reserveCapacity(SmartCareBucketID.allCases.count)
        for candidate in collapsedCandidates {
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

        let buckets = SmartCareBucketID.allCases.map { bucketID in
            let items = (grouped[bucketID] ?? []).sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.path < rhs.path
            }
            return SmartCareBucketSummary(id: bucketID, items: items)
        }
        return SmartCareSummary(buckets: buckets)
    }

    public static func removing(paths: [String], from summary: SmartCareSummary) -> SmartCareSummary {
        let removed = Set(paths.map(normalizePath))
        guard !removed.isEmpty else { return summary }
        return SmartCareSummary(
            buckets: summary.buckets.map { bucket in
                SmartCareBucketSummary(
                    id: bucket.id,
                    items: bucket.items.filter { !removed.contains(normalizePath($0.path)) }
                )
            }
        )
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

    private static func collapseHierarchy(_ candidates: [SmartCareCandidate]) -> [SmartCareCandidate] {
        // 深度只计算一次；若在 sort comparator 内反复拆 pathComponents，
        // 2 万候选会放大成 O(n log n) 次 URL 规范化，实测超过 3 秒。
        let sorted = candidates.map { (candidate: $0, depth: pathDepth($0.path)) }.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.candidate.path < rhs.candidate.path
        }

        var retainedByPath: [String: SmartCareCandidate] = [:]
        retainedByPath.reserveCapacity(sorted.count)
        for entry in sorted {
            let candidate = entry.candidate
            if let ancestorPath = nearestRetainedAncestor(of: candidate.path,
                                                          retainedByPath: retainedByPath),
               let ancestor = retainedByPath[ancestorPath] {
                retainedByPath[ancestorPath] = mergeContained(ancestor: ancestor,
                                                               descendant: candidate)
            } else {
                retainedByPath[candidate.path] = candidate
            }
        }
        return Array(retainedByPath.values)
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
