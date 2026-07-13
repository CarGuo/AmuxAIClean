import Darwin
import Foundation
import LogKit
import SafetyKit

/// Common app cache discovery built on top of the audited vendors.yaml path rules.
///
/// This scanner intentionally does not infer paths from app names. It only consumes
/// `VendorRule.category == "common_app_cache"` rules and expands their explicit paths.
/// That keeps consumer-app cleanup separate from uninstall leftovers and avoids
/// deleting neighboring databases, profile roots, sync folders, or chat media.
public actor CommonAppCacheScanner {

    public struct Options: Sendable {
        public var category: String
        public var includedVerdicts: Set<SafetyVerdict>
        public var timeoutSeconds: TimeInterval
        public var maxGlobExpansionsPerRule: Int
        public var maxEntriesPerPath: Int

        public init(
            category: String = "common_app_cache",
            includedVerdicts: Set<SafetyVerdict> = [.safe, .confirm],
            timeoutSeconds: TimeInterval = 12,
            maxGlobExpansionsPerRule: Int = 128,
            maxEntriesPerPath: Int = 200_000
        ) {
            self.category = category
            self.includedVerdicts = includedVerdicts
            self.timeoutSeconds = timeoutSeconds
            self.maxGlobExpansionsPerRule = max(1, maxGlobExpansionsPerRule)
            self.maxEntriesPerPath = max(1, maxEntriesPerPath)
        }

        public static let `default` = Options()
    }

    public struct Hit: Sendable, Hashable, Identifiable {
        public let ruleName: String
        public let bundleIDPrefix: String?
        public let source: String?
        public let url: URL
        public let isDirectory: Bool
        public let verdict: SafetyVerdict
        public let reason: String?
        public let sizeBytes: Int64
        public let entryCount: Int

        public var id: String { "\(ruleName)|\(url.path)" }

        public init(
            ruleName: String,
            bundleIDPrefix: String?,
            source: String?,
            url: URL,
            isDirectory: Bool,
            verdict: SafetyVerdict,
            reason: String?,
            sizeBytes: Int64,
            entryCount: Int
        ) {
            self.ruleName = ruleName
            self.bundleIDPrefix = bundleIDPrefix
            self.source = source
            self.url = url
            self.isDirectory = isDirectory
            self.verdict = verdict
            self.reason = reason
            self.sizeBytes = sizeBytes
            self.entryCount = entryCount
        }
    }

    /// 扫描无法证明完整的路径。任何 issue 都意味着对应路径（或其祖先）不能仅凭
    /// 本轮统计结果进入删除请求；`partial bytes` 只可用于展示，不能作为安全证明。
    public struct IncompletePath: Sendable, Hashable {
        public enum Reason: String, Sendable, Hashable {
            case metadataUnavailable
            case directoryOpenFailed
            case enumerationFailed
            case deadlineExceeded
            case entryLimitReached
            case globExpansionLimitReached
        }

        public let path: String
        public let reason: Reason

        public init(path: String, reason: Reason) {
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
            self.reason = reason
        }
    }

    /// Common-app-cache scanner 的完整结果。调用方必须同时消费 `hits` 与
    /// `incompletePaths`；后者是删除链路的一票否决上下文，而不是普通诊断日志。
    public struct ScanResult: Sendable {
        public let hits: [Hit]
        public let incompletePaths: [IncompletePath]
        /// 取消不是一种“可展示的部分扫描结果”。调用方看到该标记后必须丢弃整轮，
        /// 不能把空 hits 当成真实的“没有缓存”，也不能提交其中间统计。
        public let wasCancelled: Bool

        public var isComplete: Bool { !wasCancelled && incompletePaths.isEmpty }
        public var deletionProtectedPaths: Set<String> {
            Set(incompletePaths.map(\.path))
        }

        public init(
            hits: [Hit],
            incompletePaths: [IncompletePath],
            wasCancelled: Bool = false
        ) {
            self.hits = hits
            self.incompletePaths = incompletePaths
            self.wasCancelled = wasCancelled
        }
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func discover(
        vendors: [VendorRule],
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) async -> ScanResult {
        let opts = options
        let worker = Task.detached(priority: .utility) {
            Self.detect(vendors: vendors, home: home, options: opts)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            // detached task 不继承等待方后续发生的取消，必须显式传播。
            worker.cancel()
        }
    }

    public nonisolated static func detect(
        vendors: [VendorRule],
        home: URL,
        options: Options = .default,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> ScanResult {
        if shouldCancel() {
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let homePath = home.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(options.timeoutSeconds)
        let fm = FileManager.default
        var hits: [Hit] = []
        var incompletePaths: [IncompletePath] = []

        let rules = vendors.filter { $0.category == options.category }
        GSYLog.info(.scan, "CommonAppCache scan start rules=\(rules.count) timeout=\(options.timeoutSeconds)s")

        let resolution = prioritizedCandidateResolution(
            rules: rules,
            includedVerdicts: options.includedVerdicts,
            homePath: homePath,
            fileManager: fm,
            maxGlobExpansionsPerRule: options.maxGlobExpansionsPerRule,
            shouldCancel: shouldCancel
        )
        if resolution.wasCancelled || shouldCancel() {
            GSYLog.info(.scan, "CommonAppCache scan cancelled during candidate resolution")
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let candidates = resolution.candidates
        incompletePaths.append(contentsOf: resolution.incompletePaths)

        for (index, candidate) in candidates.enumerated() {
            if shouldCancel() {
                GSYLog.info(.scan, "CommonAppCache scan cancelled before sizing candidate index=\(index)")
                return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
            }
            if Date() >= deadline {
                incompletePaths.append(contentsOf: candidates[index...].map {
                    IncompletePath(path: $0.path, reason: .deadlineExceeded)
                })
                break
            }
            let size = sizeOfPath(
                candidate.path,
                isDirectory: candidate.isDirectory,
                deadline: deadline,
                maxEntries: options.maxEntriesPerPath,
                shouldCancel: shouldCancel
            )
            if size.wasCancelled || shouldCancel() {
                GSYLog.info(.scan, "CommonAppCache scan cancelled while sizing path=\(candidate.path)")
                return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
            }
            incompletePaths.append(contentsOf: size.incompletePaths)
            let bytes = size.bytes
            guard bytes > 0 else { continue }
            hits.append(Hit(
                ruleName: candidate.rule.name,
                bundleIDPrefix: candidate.rule.bundleIDPrefix,
                source: candidate.rule.source,
                url: URL(fileURLWithPath: candidate.path),
                isDirectory: candidate.isDirectory,
                verdict: candidate.pathRule.verdict,
                reason: candidate.pathRule.reason,
                sizeBytes: bytes,
                entryCount: size.entryCount
            ))
        }

        if shouldCancel() {
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let sortedHits = hits.sorted {
            if $0.sizeBytes == $1.sizeBytes { return $0.url.path < $1.url.path }
            return $0.sizeBytes > $1.sizeBytes
        }
        if shouldCancel() {
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let uniqueIncompletePaths = deduplicatedIncompletePaths(incompletePaths)
        GSYLog.info(.scan, "CommonAppCache scan finished hits=\(sortedHits.count) complete=\(uniqueIncompletePaths.isEmpty) incompletePaths=\(uniqueIncompletePaths.count)")
        return ScanResult(hits: sortedHits, incompletePaths: uniqueIncompletePaths)
    }

    struct Candidate {
        let rule: VendorRule
        let pathRule: PathRule
        let path: String
        let isDirectory: Bool
        let originalRuleIndex: Int
        let originalPathIndex: Int
    }

    private struct CandidateResolution {
        let candidates: [Candidate]
        let incompletePaths: [IncompletePath]
        let wasCancelled: Bool
    }

    static func prioritizedCandidates(
        rules: [VendorRule],
        includedVerdicts: Set<SafetyVerdict>,
        homePath: String,
        fileManager: FileManager,
        maxGlobExpansionsPerRule: Int,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> [Candidate] {
        prioritizedCandidateResolution(
            rules: rules,
            includedVerdicts: includedVerdicts,
            homePath: homePath,
            fileManager: fileManager,
            maxGlobExpansionsPerRule: maxGlobExpansionsPerRule,
            shouldCancel: shouldCancel
        ).candidates
    }

    private static func prioritizedCandidateResolution(
        rules: [VendorRule],
        includedVerdicts: Set<SafetyVerdict>,
        homePath: String,
        fileManager: FileManager,
        maxGlobExpansionsPerRule: Int,
        shouldCancel: () -> Bool
    ) -> CandidateResolution {
        var candidates: [Candidate] = []
        var incompletePaths: [IncompletePath] = []
        for (ruleIndex, rule) in rules.enumerated() {
            if shouldCancel() {
                return CandidateResolution(
                    candidates: [],
                    incompletePaths: [],
                    wasCancelled: true
                )
            }
            for (pathIndex, pathRule) in rule.paths.enumerated()
                where includedVerdicts.contains(pathRule.verdict) {
                if shouldCancel() {
                    return CandidateResolution(
                        candidates: [],
                        incompletePaths: [],
                        wasCancelled: true
                    )
                }
                let expansion = expandPatternWithReport(
                    pathRule.path,
                    home: homePath,
                    fileManager: fileManager,
                    maxResults: maxGlobExpansionsPerRule,
                    shouldCancel: shouldCancel
                )
                if expansion.wasCancelled {
                    return CandidateResolution(
                        candidates: [],
                        incompletePaths: [],
                        wasCancelled: true
                    )
                }
                incompletePaths.append(contentsOf: expansion.incompletePaths)
                for path in expansion.paths {
                    if shouldCancel() {
                        return CandidateResolution(
                            candidates: [],
                            incompletePaths: [],
                            wasCancelled: true
                        )
                    }
                    var pathStat = stat()
                    guard stat(path, &pathStat) == 0 else {
                        if errno != ENOENT {
                            incompletePaths.append(IncompletePath(
                                path: path,
                                reason: .metadataUnavailable
                            ))
                        }
                        continue
                    }
                    candidates.append(Candidate(
                        rule: rule,
                        pathRule: pathRule,
                        path: path,
                        isDirectory: (pathStat.st_mode & S_IFMT) == S_IFDIR,
                        originalRuleIndex: ruleIndex,
                        originalPathIndex: pathIndex
                    ))
                }
            }
        }
        if shouldCancel() {
            return CandidateResolution(
                candidates: [],
                incompletePaths: [],
                wasCancelled: true
            )
        }
        let sorted = candidates.sorted { lhs, rhs in
            let lhsRank = verdictPriority(lhs.pathRule.verdict)
            let rhsRank = verdictPriority(rhs.pathRule.verdict)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.originalRuleIndex != rhs.originalRuleIndex {
                return lhs.originalRuleIndex < rhs.originalRuleIndex
            }
            if lhs.originalPathIndex != rhs.originalPathIndex {
                return lhs.originalPathIndex < rhs.originalPathIndex
            }
            return lhs.path < rhs.path
        }
        return CandidateResolution(
            candidates: sorted,
            incompletePaths: incompletePaths,
            wasCancelled: shouldCancel()
        )
    }

    private static func verdictPriority(_ verdict: SafetyVerdict) -> Int {
        switch verdict {
        case .safe: return 0
        case .confirm: return 1
        case .forbid: return 2
        }
    }

    static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    static func expandPattern(
        _ rawPattern: String,
        home: String,
        fileManager: FileManager,
        maxResults: Int,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> [String] {
        expandPatternWithReport(
            rawPattern,
            home: home,
            fileManager: fileManager,
            maxResults: maxResults,
            shouldCancel: shouldCancel
        ).paths
    }

    private struct PatternExpansion {
        let paths: [String]
        let incompletePaths: [IncompletePath]
        let wasCancelled: Bool
    }

    private static func expandPatternWithReport(
        _ rawPattern: String,
        home: String,
        fileManager: FileManager,
        maxResults: Int,
        shouldCancel: () -> Bool
    ) -> PatternExpansion {
        if shouldCancel() {
            return PatternExpansion(paths: [], incompletePaths: [], wasCancelled: true)
        }
        let pattern = URL(fileURLWithPath: expandHome(rawPattern, home: home)).standardizedFileURL.path
        guard PathGlob.isGlob(pattern) else {
            let wasCancelled = shouldCancel()
            return PatternExpansion(
                paths: wasCancelled ? [] : [pattern],
                incompletePaths: [],
                wasCancelled: wasCancelled
            )
        }

        var results: [String] = []
        var incompletePaths: [IncompletePath] = []
        var didTruncate = false
        var wasCancelled = false
        expandGlobComponents(
            NSString(string: pattern).pathComponents,
            fileManager: fileManager,
            maxResults: maxResults,
            output: &results,
            incompletePaths: &incompletePaths,
            didTruncate: &didTruncate,
            wasCancelled: &wasCancelled,
            shouldCancel: shouldCancel
        )
        if wasCancelled || shouldCancel() {
            return PatternExpansion(paths: [], incompletePaths: [], wasCancelled: true)
        }
        if didTruncate {
            let components = NSString(string: pattern).pathComponents
            let globIndex = components.firstIndex(where: { PathGlob.isGlob($0) }) ?? components.endIndex
            let staticComponents = Array(components[..<globIndex])
            let staticRoot = NSString.path(withComponents: staticComponents.isEmpty ? ["/"] : staticComponents)
            incompletePaths.append(IncompletePath(
                path: staticRoot,
                reason: .globExpansionLimitReached
            ))
        }
        return PatternExpansion(
            paths: results,
            incompletePaths: incompletePaths,
            wasCancelled: false
        )
    }

    private static func expandGlobComponents(
        _ components: [String],
        fileManager: FileManager,
        maxResults: Int,
        output: inout [String],
        incompletePaths: inout [IncompletePath],
        didTruncate: inout Bool,
        wasCancelled: inout Bool,
        shouldCancel: () -> Bool
    ) {
        if shouldCancel() {
            wasCancelled = true
            return
        }
        guard let globIndex = components.firstIndex(where: { PathGlob.isGlob($0) }) else {
            if output.count >= maxResults {
                didTruncate = true
                return
            }
            output.append(NSString.path(withComponents: components))
            return
        }

        let baseComponents = Array(components[..<globIndex])
        let glob = components[globIndex]
        let rest = Array(components[(globIndex + 1)...])
        let base = NSString.path(withComponents: baseComponents.isEmpty ? ["/"] : baseComponents)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: base)
        } catch {
            if !isMissingPathError(error) {
                incompletePaths.append(IncompletePath(path: base, reason: .directoryOpenFailed))
            }
            return
        }
        if shouldCancel() {
            wasCancelled = true
            return
        }

        let sortedNames = names.sorted()
        if shouldCancel() {
            wasCancelled = true
            return
        }
        for name in sortedNames {
            if shouldCancel() {
                wasCancelled = true
                return
            }
            guard PathGlob.match(pattern: glob, path: name) else { continue }
            if output.count >= maxResults {
                didTruncate = true
                return
            }
            expandGlobComponents(
                baseComponents + [name] + rest,
                fileManager: fileManager,
                maxResults: maxResults,
                output: &output,
                incompletePaths: &incompletePaths,
                didTruncate: &didTruncate,
                wasCancelled: &wasCancelled,
                shouldCancel: shouldCancel
            )
            if didTruncate || wasCancelled { return }
        }
    }

    private static func isMissingPathError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           CocoaError.Code(rawValue: nsError.code) == .fileNoSuchFile {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    struct SizeStat {
        let bytes: Int64
        let entryCount: Int
        let incompletePaths: [IncompletePath]
        let wasCancelled: Bool
    }

    static func sizeOfPath(
        _ path: String,
        isDirectory: Bool,
        deadline: Date,
        maxEntries: Int,
        shouldCancel: () -> Bool = { Task.isCancelled },
        openDirectory: (String) -> Int32 = { Darwin.open($0, O_RDONLY) }
    ) -> SizeStat {
        if shouldCancel() {
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [],
                wasCancelled: true
            )
        }
        if !isDirectory {
            var st = stat()
            guard lstat(path, &st) == 0 else {
                let issues = errno == ENOENT
                    ? []
                    : [IncompletePath(path: path, reason: .metadataUnavailable)]
                return SizeStat(
                    bytes: 0,
                    entryCount: 0,
                    incompletePaths: issues,
                    wasCancelled: false
                )
            }
            if shouldCancel() {
                return SizeStat(
                    bytes: 0,
                    entryCount: 0,
                    incompletePaths: [],
                    wasCancelled: true
                )
            }
            return SizeStat(
                bytes: Int64(st.st_size),
                entryCount: 1,
                incompletePaths: [],
                wasCancelled: false
            )
        }
        return sizeOfDirectory(
            path,
            deadline: deadline,
            maxEntries: maxEntries,
            shouldCancel: shouldCancel,
            openDirectory: openDirectory
        )
    }

    private static func sizeOfDirectory(
        _ rootPath: String,
        deadline: Date,
        maxEntries: Int,
        shouldCancel: () -> Bool,
        openDirectory: (String) -> Int32
    ) -> SizeStat {
        if shouldCancel() {
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [],
                wasCancelled: true
            )
        }
        var rootStat = stat()
        guard stat(rootPath, &rootStat) == 0 else {
            let issues = errno == ENOENT
                ? []
                : [IncompletePath(path: rootPath, reason: .metadataUnavailable)]
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: issues,
                wasCancelled: false
            )
        }
        if shouldCancel() {
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [],
                wasCancelled: true
            )
        }
        let rootDevice = UInt64(bitPattern: Int64(rootStat.st_dev))

        var stack = [rootPath]
        var total: Int64 = 0
        var entries = 0
        var incompletePaths: [IncompletePath] = []
        var wasCancelled = false

        while let dir = stack.popLast() {
            if shouldCancel() {
                wasCancelled = true
                break
            }
            if Date() >= deadline {
                incompletePaths.append(IncompletePath(path: rootPath, reason: .deadlineExceeded))
                break
            }
            if entries >= maxEntries {
                incompletePaths.append(IncompletePath(path: rootPath, reason: .entryLimitReached))
                break
            }
            let fd = openDirectory(dir)
            if fd < 0 {
                if errno != ENOENT {
                    incompletePaths.append(IncompletePath(path: dir, reason: .directoryOpenFailed))
                }
                continue
            }
            var consumerStopReason: IncompletePath.Reason?
            let outcome = BulkEnumerate.enumerate(
                fd: fd,
                dirPath: dir,
                shouldCancel: shouldCancel
            ) { entry in
                if shouldCancel() {
                    wasCancelled = true
                    return false
                }
                if entries & 0xFF == 0, Date() >= deadline {
                    consumerStopReason = .deadlineExceeded
                    return false
                }
                if entries >= maxEntries {
                    consumerStopReason = .entryLimitReached
                    return false
                }
                entries += 1
                if entry.isSymlink || entry.device != rootDevice { return true }
                if entry.isDirectory {
                    stack.append("\(dir)/\(entry.name)")
                } else {
                    total += entry.logicalSize
                }
                return true
            }
            Darwin.close(fd)

            if shouldCancel() {
                wasCancelled = true
            }
            if wasCancelled { break }

            switch outcome {
            case .complete:
                break
            case .stoppedByConsumer:
                incompletePaths.append(IncompletePath(
                    path: rootPath,
                    reason: consumerStopReason ?? .enumerationFailed
                ))
            case .failed:
                incompletePaths.append(IncompletePath(path: dir, reason: .enumerationFailed))
            }
            if consumerStopReason != nil { break }
        }
        return SizeStat(
            bytes: wasCancelled ? 0 : total,
            entryCount: wasCancelled ? 0 : entries,
            incompletePaths: wasCancelled ? [] : deduplicatedIncompletePaths(incompletePaths),
            wasCancelled: wasCancelled
        )
    }

    private static func deduplicatedIncompletePaths(
        _ incompletePaths: [IncompletePath]
    ) -> [IncompletePath] {
        var seen = Set<IncompletePath>()
        return incompletePaths.filter { seen.insert($0).inserted }
    }
}
