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

    public struct Options: Sendable, Codable {
        public var category: String
        public var includedVerdicts: Set<SafetyVerdict>
        public var timeoutSeconds: TimeInterval
        public var maxGlobExpansionsPerRule: Int
        public var maxEntriesPerPath: Int
        /// Whether candidate resolution may touch another developer's sandbox/App Group
        /// containers. macOS Sonoma and later can synchronously present an App Data consent
        /// prompt as soon as glob expansion, `lstat`, or `open` reaches these roots.
        ///
        /// v2026.07.17 C4 regression record: Smart Care used to enter protected container
        /// paths without an explicit user interaction. The isolated worker then blocked in
        /// TCC until its 12-second hard deadline, while the system sheet obscured the App UI.
        /// Defaulting to false keeps discovery non-interruptive; the App enables this only
        /// after its FDA probe has positively established access.
        public var allowsProtectedAppDataAccess: Bool
        /// 在候选解析阶段排除这些路径及其后代。调用方可把同一轮冻结的白名单快照
        /// 传进来，使 `ScanResult` 的路径并集 totals 与最终可见 rows 保持同一边界。
        public var excludedCandidatePathPrefixes: Set<String>

        public init(
            category: String = "common_app_cache",
            includedVerdicts: Set<SafetyVerdict> = [.safe, .confirm],
            timeoutSeconds: TimeInterval = 12,
            maxGlobExpansionsPerRule: Int = 128,
            maxEntriesPerPath: Int = 200_000,
            allowsProtectedAppDataAccess: Bool = false,
            excludedCandidatePathPrefixes: Set<String> = []
        ) {
            self.category = category
            self.includedVerdicts = includedVerdicts
            self.timeoutSeconds = timeoutSeconds
            self.maxGlobExpansionsPerRule = max(1, maxGlobExpansionsPerRule)
            self.maxEntriesPerPath = max(1, maxEntriesPerPath)
            self.allowsProtectedAppDataAccess = allowsProtectedAppDataAccess
            self.excludedCandidatePathPrefixes = Set(
                excludedCandidatePathPrefixes.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                }
            )
        }

        public static let `default` = Options()
    }

    /// Common-app-cache 扫描的有界进度快照。候选总数不是可信的工作量分母：同 verdict
    /// 的父子候选会共享一次森林遍历，因此 UI 应展示这里的 group 进度，而不是自行按路径
    /// 猜测进度。回调在扫描 worker 上同步触发，调用方只应冻结数据后再切回 MainActor。
    ///
    /// v2026.07.17：补上逐组进度与显式终态，避免同步目录访问较慢时界面只剩无期限 spinner。
    public struct Progress: Sendable, Codable, Hashable {
        public enum Phase: String, Sendable, Codable, Hashable {
            case resolvingCandidates
            case measuringGroups
            case terminal
        }

        public enum TerminalOutcome: String, Sendable, Codable, Hashable {
            case complete
            case partial
            case cancelled
        }

        public let phase: Phase
        public let completedGroups: Int
        public let totalGroups: Int
        public let currentVerdict: SafetyVerdict?
        public let currentPath: String?
        public let terminalOutcome: TerminalOutcome?
        /// 最近一个已经收敛到组边界的可信快照。正在访问当前 group 时不会改写它；
        /// 即使外层因不可中断 syscall 终止 worker，也能只发布这里的已完成结果。
        public let checkpoint: Checkpoint?
        /// 尚未进入可信 checkpoint 的候选路径。外层硬超时后必须把这些路径标成
        /// typed deadlineExceeded，而不能把它们误报为“不存在”或完整空结果。
        public let pendingPaths: [String]

        public var isTerminal: Bool { phase == .terminal }

        public init(
            phase: Phase,
            completedGroups: Int,
            totalGroups: Int,
            currentVerdict: SafetyVerdict? = nil,
            currentPath: String? = nil,
            terminalOutcome: TerminalOutcome? = nil,
            checkpoint: Checkpoint? = nil,
            pendingPaths: [String] = []
        ) {
            self.phase = phase
            self.completedGroups = max(0, completedGroups)
            self.totalGroups = max(0, totalGroups)
            self.currentVerdict = currentVerdict
            self.currentPath = currentPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            self.terminalOutcome = terminalOutcome
            self.checkpoint = checkpoint
            self.pendingPaths = pendingPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        }
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    public struct Hit: Sendable, Codable, Hashable, Identifiable {
        public let ruleName: String
        public let bundleIDPrefix: String?
        public let source: String?
        public let url: URL
        public let isDirectory: Bool
        public let verdict: SafetyVerdict
        public let reason: String?
        /// 与 System Settings「储存空间」一致的磁盘分配量；清理列表主值使用它。
        public let sizeBytes: Int64
        /// Finder 式详情副值；sparse 文件的虚拟容量可能远大于 `sizeBytes`。
        public let logicalSizeBytes: Int64
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
            logicalSizeBytes: Int64? = nil,
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
            self.logicalSizeBytes = logicalSizeBytes ?? sizeBytes
            self.entryCount = entryCount
        }
    }

    /// 扫描无法证明完整的路径。任何 issue 都意味着对应路径（或其祖先）不能仅凭
    /// 本轮统计结果进入删除请求；`partial bytes` 只可用于展示，不能作为安全证明。
    public struct IncompletePath: Sendable, Codable, Hashable {
        public enum Reason: String, Sendable, Codable, Hashable {
            case metadataUnavailable
            case pathIdentityChanged
            case directoryOpenFailed
            case enumerationFailed
            case deadlineExceeded
            case entryLimitReached
            case globExpansionLimitReached
            /// Candidate resolution deliberately stopped before touching another developer's
            /// Container/App Group because the caller had not established FDA. This is typed
            /// TCC scope evidence, not a missing path and not a generic I/O failure.
            case protectedAppDataSkipped
            /// Isolated worker could not be started. Parent must publish typed partial evidence;
            /// silently falling back to the same in-process syscall path would restore the hang.
            case workerLaunchFailed
            /// Worker output/checkpoint could not be decoded or violated the protocol contract.
            case workerProtocolFailed
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
    public struct ScanResult: Sendable, Codable {
        public let hits: [Hit]
        public let incompletePaths: [IncompletePath]
        /// 所有候选路径的物理并集容量。`Hit.sizeBytes` 刻意保持 inclusive subtree
        /// 语义，所以父/子规则同时存在时不能再把 rows 相加作为扫描总量。
        public let uniqueTotalBytes: Int64
        public let uniqueLogicalBytes: Int64
        /// 路径并集内实际计量到的唯一目录项数量；hardlink 的不同路径仍是不同 entry，
        /// 但 `uniqueTotalBytes` 按 `(device, inode)` 只计一次物理容量。partial 扫描时该值
        /// 是不会重复计数的可信下界，不会为精确进度额外常驻每个完整路径。
        public let uniqueEntryCount: Int
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
            wasCancelled: Bool = false,
            uniqueTotalBytes: Int64? = nil,
            uniqueLogicalBytes: Int64? = nil,
            uniqueEntryCount: Int? = nil
        ) {
            self.hits = hits
            self.incompletePaths = incompletePaths
            self.wasCancelled = wasCancelled
            // 依赖注入测试与旧调用方通常只构造互不重叠的 hit；未显式传并集值时
            // 保持源兼容。生产 detect 始终传入一次共享遍历得到的权威 totals。
            var seenPaths = Set<String>()
            let uniqueHits = hits.filter {
                seenPaths.insert($0.url.standardizedFileURL.path).inserted
            }
            self.uniqueTotalBytes = uniqueTotalBytes
                ?? uniqueHits.reduce(0) { $0 &+ $1.sizeBytes }
            self.uniqueLogicalBytes = uniqueLogicalBytes
                ?? uniqueHits.reduce(0) { $0 &+ $1.logicalSizeBytes }
            self.uniqueEntryCount = uniqueEntryCount
                ?? uniqueHits.reduce(0) { $0 &+ $1.entryCount }
        }
    }

    /// 逐 group 交付的 worker checkpoint。它只包含已完成 group，不包含当前正在打开或
    /// 枚举的路径，因此可以安全跨进程持久化；`pendingPaths` 由相邻 Progress 明确给出。
    public struct Checkpoint: Sendable, Codable, Hashable {
        public let hits: [Hit]
        public let incompletePaths: [IncompletePath]
        public let uniqueTotalBytes: Int64
        public let uniqueLogicalBytes: Int64
        public let uniqueEntryCount: Int
        public let completedGroupCount: Int

        public init(
            hits: [Hit],
            incompletePaths: [IncompletePath],
            uniqueTotalBytes: Int64,
            uniqueLogicalBytes: Int64,
            uniqueEntryCount: Int,
            completedGroupCount: Int
        ) {
            self.hits = hits
            self.incompletePaths = incompletePaths
            self.uniqueTotalBytes = uniqueTotalBytes
            self.uniqueLogicalBytes = uniqueLogicalBytes
            self.uniqueEntryCount = uniqueEntryCount
            self.completedGroupCount = max(0, completedGroupCount)
        }

        public var scanResult: ScanResult {
            ScanResult(
                hits: hits,
                incompletePaths: incompletePaths,
                uniqueTotalBytes: uniqueTotalBytes,
                uniqueLogicalBytes: uniqueLogicalBytes,
                uniqueEntryCount: uniqueEntryCount
            )
        }
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func discover(
        vendors: [VendorRule],
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        onProgress: @escaping ProgressHandler = { _ in }
    ) async -> ScanResult {
        let opts = options
        let worker = Task.detached(priority: .utility) {
            Self.detect(
                vendors: vendors,
                home: home,
                options: opts,
                onProgress: onProgress
            )
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
        shouldCancel: () -> Bool = { Task.isCancelled },
        onProgress: ProgressHandler = { _ in }
    ) -> ScanResult {
        detect(
            vendors: vendors,
            home: home,
            options: options,
            shouldCancel: shouldCancel,
            openDirectory: nil,
            onProgress: onProgress
        )
    }

    /// 同步 I/O 依赖边界。生产入口使用 `Darwin.open`；ScanKit 回归可统计每个目录
    /// 的打开次数，锁住“父/子候选只能共享一次遍历”这一性能合同。
    nonisolated static func detect(
        vendors: [VendorRule],
        home: URL,
        options: Options,
        shouldCancel: () -> Bool,
        openDirectory: ((String) -> Int32)?,
        onProgress: ProgressHandler = { _ in }
    ) -> ScanResult {
        if shouldCancel() {
            onProgress(Progress(
                phase: .terminal,
                completedGroups: 0,
                totalGroups: 0,
                terminalOutcome: .cancelled
            ))
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let homePath = home.standardizedFileURL.path
        guard let pathResolver = CommonAppCacheRootedPathResolver(logicalRoot: homePath) else {
            let issue = IncompletePath(path: homePath, reason: .directoryOpenFailed)
            onProgress(Progress(
                phase: .terminal,
                completedGroups: 0,
                totalGroups: 0,
                terminalOutcome: .partial,
                checkpoint: Checkpoint(
                    hits: [],
                    incompletePaths: [issue],
                    uniqueTotalBytes: 0,
                    uniqueLogicalBytes: 0,
                    uniqueEntryCount: 0,
                    completedGroupCount: 0
                )
            ))
            return ScanResult(hits: [], incompletePaths: [issue])
        }
        let effectiveOpenDirectory: (String) -> Int32 = openDirectory ?? {
            pathResolver.openDirectory($0)
        }
        let deadline = ScanDeadline.make(timeout: options.timeoutSeconds)
        let fm = FileManager.default
        var incompletePaths: [IncompletePath] = []

        let rules = vendors.filter { $0.category == options.category }
        AmuxLog.info(.scan, "CommonAppCache scan start rules=\(rules.count) timeout=\(options.timeoutSeconds)s")
        onProgress(Progress(
            phase: .resolvingCandidates,
            completedGroups: 0,
            totalGroups: 0
        ))

        let resolution = prioritizedCandidateResolution(
            rules: rules,
            includedVerdicts: options.includedVerdicts,
            homePath: homePath,
            fileManager: fm,
            maxGlobExpansionsPerRule: options.maxGlobExpansionsPerRule,
            allowsProtectedAppDataAccess: options.allowsProtectedAppDataAccess,
            excludedCandidatePathPrefixes: options.excludedCandidatePathPrefixes,
            pathResolver: pathResolver,
            shouldCancel: shouldCancel
        )
        if resolution.wasCancelled || shouldCancel() {
            AmuxLog.info(.scan, "CommonAppCache scan cancelled during candidate resolution")
            onProgress(Progress(
                phase: .terminal,
                completedGroups: 0,
                totalGroups: 0,
                terminalOutcome: .cancelled
            ))
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let candidates = resolution.candidates
        incompletePaths.append(contentsOf: resolution.incompletePaths)

        // v2026.07.17：同 verdict 的父子候选按最外层候选组成共享森林，避免逐 candidate
        // 重复递归。不同 verdict 必须严格按 safe → confirm 访问，不能让宽泛的 confirm
        // 父目录抢在 safe 子目录之前阻塞；跨 verdict 的重叠遍历由全轮 inode/path 并集
        // 去重。rows 继续是 inclusive subtree，ScanResult 单独发布路径并集唯一 totals。
        let measurement = measureCandidates(
            candidates,
            deadline: deadline,
            maxEntriesPerPath: options.maxEntriesPerPath,
            initialIncompletePaths: incompletePaths,
            lstatPath: { path, metadata in
                pathResolver.lstat(path, metadata: &metadata)
            },
            shouldCancel: shouldCancel,
            openDirectory: effectiveOpenDirectory,
            onProgress: onProgress
        )
        if measurement.wasCancelled || shouldCancel() {
            AmuxLog.info(.scan, "CommonAppCache scan cancelled while measuring candidate forest")
            onProgress(Progress(
                phase: .terminal,
                completedGroups: measurement.completedGroupCount,
                totalGroups: measurement.totalGroupCount,
                terminalOutcome: .cancelled,
                checkpoint: measurement.checkpoint,
                pendingPaths: measurement.pendingPaths
            ))
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        incompletePaths.append(contentsOf: measurement.incompletePaths)

        var hits: [Hit] = []
        hits.reserveCapacity(candidates.count)
        for (candidate, size) in zip(candidates, measurement.candidateStats) {
            guard size.bytes > 0 else { continue }
            hits.append(Hit(
                ruleName: candidate.rule.name,
                bundleIDPrefix: candidate.rule.bundleIDPrefix,
                source: candidate.rule.source,
                url: URL(fileURLWithPath: candidate.path),
                isDirectory: candidate.isDirectory,
                verdict: candidate.pathRule.verdict,
                reason: candidate.pathRule.reason,
                sizeBytes: size.bytes,
                logicalSizeBytes: size.logicalBytes,
                entryCount: size.entryCount
            ))
        }

        if shouldCancel() {
            onProgress(Progress(
                phase: .terminal,
                completedGroups: measurement.completedGroupCount,
                totalGroups: measurement.totalGroupCount,
                terminalOutcome: .cancelled,
                checkpoint: measurement.checkpoint,
                pendingPaths: measurement.pendingPaths
            ))
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let sortedHits = hits.sorted {
            if $0.sizeBytes == $1.sizeBytes { return $0.url.path < $1.url.path }
            return $0.sizeBytes > $1.sizeBytes
        }
        if shouldCancel() {
            onProgress(Progress(
                phase: .terminal,
                completedGroups: measurement.completedGroupCount,
                totalGroups: measurement.totalGroupCount,
                terminalOutcome: .cancelled,
                checkpoint: measurement.checkpoint,
                pendingPaths: measurement.pendingPaths
            ))
            return ScanResult(hits: [], incompletePaths: [], wasCancelled: true)
        }
        let uniqueIncompletePaths = deduplicatedIncompletePaths(incompletePaths)
        AmuxLog.info(.scan, "CommonAppCache scan finished hits=\(sortedHits.count) complete=\(uniqueIncompletePaths.isEmpty) incompletePaths=\(uniqueIncompletePaths.count)")
        onProgress(Progress(
            phase: .terminal,
            completedGroups: measurement.completedGroupCount,
            totalGroups: measurement.totalGroupCount,
            terminalOutcome: uniqueIncompletePaths.isEmpty ? .complete : .partial,
            checkpoint: measurement.checkpoint,
            pendingPaths: measurement.pendingPaths
        ))
        return ScanResult(
            hits: sortedHits,
            incompletePaths: uniqueIncompletePaths,
            uniqueTotalBytes: measurement.uniqueTotalBytes,
            uniqueLogicalBytes: measurement.uniqueLogicalBytes,
            uniqueEntryCount: measurement.uniqueEntryCount
        )
    }

    struct PathIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let fileType: UInt16

        init(_ metadata: stat) {
            self.device = UInt64(bitPattern: Int64(metadata.st_dev))
            self.inode = UInt64(metadata.st_ino)
            self.fileType = UInt16(metadata.st_mode & mode_t(S_IFMT))
        }

        var isDirectory: Bool { fileType == UInt16(S_IFDIR) }
    }

    struct Candidate {
        let rule: VendorRule
        let pathRule: PathRule
        let path: String
        /// v2026.07.17：候选解析与实际计量之间必须绑定同一个目录项身份；否则路径被
        /// symlink/rename 换件后，扫描可能计算另一个对象，却把原路径交给删除链路。
        let identity: PathIdentity
        var isDirectory: Bool { identity.isDirectory }
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
        allowsProtectedAppDataAccess: Bool = false,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> [Candidate] {
        guard let pathResolver = CommonAppCacheRootedPathResolver(
            logicalRoot: homePath
        ) else { return [] }
        return prioritizedCandidateResolution(
            rules: rules,
            includedVerdicts: includedVerdicts,
            homePath: homePath,
            fileManager: fileManager,
            maxGlobExpansionsPerRule: maxGlobExpansionsPerRule,
            allowsProtectedAppDataAccess: allowsProtectedAppDataAccess,
            excludedCandidatePathPrefixes: [],
            pathResolver: pathResolver,
            shouldCancel: shouldCancel
        ).candidates
    }

    private static func prioritizedCandidateResolution(
        rules: [VendorRule],
        includedVerdicts: Set<SafetyVerdict>,
        homePath: String,
        fileManager: FileManager,
        maxGlobExpansionsPerRule: Int,
        allowsProtectedAppDataAccess: Bool,
        excludedCandidatePathPrefixes: Set<String>,
        pathResolver: CommonAppCacheRootedPathResolver,
        shouldCancel: () -> Bool
    ) -> CandidateResolution {
        var candidates: [Candidate] = []
        var incompletePaths: [IncompletePath] = []
        // v2026.07.17 App Data prompt regression: sorting candidates only after resolution was
        // too late. Glob expansion and lstat are themselves protected filesystem access, so a
        // confirm rule in YAML order could block before the first safe candidate was measured.
        // Resolve the same rule set in explicit verdict bands; original indices remain attached
        // so the established deterministic order inside each band is unchanged.
        let prioritizedRules = rules.enumerated().flatMap { ruleIndex, rule in
            rule.paths.enumerated().compactMap { pathIndex, pathRule in
                includedVerdicts.contains(pathRule.verdict)
                    ? (ruleIndex, pathIndex, rule, pathRule)
                    : nil
            }
        }.sorted { lhs, rhs in
            let lhsRank = verdictPriority(lhs.3.verdict)
            let rhsRank = verdictPriority(rhs.3.verdict)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        for (ruleIndex, pathIndex, rule, pathRule) in prioritizedRules {
            if shouldCancel() {
                return CandidateResolution(
                    candidates: [],
                    incompletePaths: [],
                    wasCancelled: true
                )
            }
            // The boundary check happens on the normalized pattern before glob expansion.
            // Therefore a wildcard under Containers cannot trigger TCC merely while resolving
            // candidate names. We report the stable container boundary rather than a fake path
            // containing `*`, so deletion overlap checks remain valid POSIX path comparisons.
            let normalizedPattern = URL(
                fileURLWithPath: expandHome(pathRule.path, home: homePath)
            ).standardizedFileURL.path
            // v2026.07.17 static-review correction: an explicitly excluded/whitelisted pattern
            // must disappear before either the protected-boundary check or filesystem access.
            // Otherwise a whitelisted Container still emits a synthetic TCC partial for the
            // whole Containers root even though this scan was never going to resolve it.
            guard !isExcludedCandidatePath(
                normalizedPattern,
                prefixes: excludedCandidatePathPrefixes
            ) else { continue }
            if !allowsProtectedAppDataAccess,
               let protectedBoundary = protectedAppDataBoundary(
                   for: normalizedPattern,
                   homePath: homePath
               ) {
                incompletePaths.append(IncompletePath(
                    path: protectedBoundary,
                    reason: .protectedAppDataSkipped
                ))
                continue
            }
            let expansion = expandPatternWithReport(
                pathRule.path,
                home: homePath,
                fileManager: fileManager,
                maxResults: maxGlobExpansionsPerRule,
                pathResolver: pathResolver,
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
                guard !isExcludedCandidatePath(
                    path,
                    prefixes: excludedCandidatePathPrefixes
                ) else { continue }
                var pathStat = stat()
                // v2026.07.17 candidate-root symlink safety: `stat` followed a cache alias
                // and classified its target directory as the deletable candidate. The
                // traversal then counted the target subtree even though Trash would move
                // only the symlink pathname, severely overstating reclaimable bytes. Root
                // identity must use `lstat`, matching both descendant no-follow traversal
                // and the final path-based Trash operation. A symlink is therefore measured
                // as one non-directory entry (and commonly omitted when it occupies 0 B).
                guard pathResolver.lstat(path, metadata: &pathStat) == 0 else {
                    let metadataError = errno
                    if metadataError != ENOENT {
                        incompletePaths.append(IncompletePath(
                            path: path,
                            reason: metadataFailureReason(metadataError)
                        ))
                    }
                    continue
                }
                candidates.append(Candidate(
                    rule: rule,
                    pathRule: pathRule,
                    path: path,
                    identity: PathIdentity(pathStat),
                    originalRuleIndex: ruleIndex,
                    originalPathIndex: pathIndex
                ))
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
        var seenPaths = Set<String>()
        let unique = sorted.filter { seenPaths.insert($0.path).inserted }
        return CandidateResolution(
            candidates: unique,
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

    /// Returns the stable TCC App Data boundary containing a candidate pattern.
    ///
    /// This is intentionally a structural boundary, not a vendor/app-name list: every other
    /// developer container is protected by the same OS contract, including future apps that
    /// are not present in vendors.yaml today. Prefix matching is component-delimited so a path
    /// such as `Library/ContainersBackup` is never misclassified.
    nonisolated static func protectedAppDataBoundary(
        for normalizedPattern: String,
        homePath: String
    ) -> String? {
        let roots = [
            URL(fileURLWithPath: homePath)
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .standardizedFileURL.path,
            URL(fileURLWithPath: homePath)
                .appendingPathComponent("Library/Group Containers", isDirectory: true)
                .standardizedFileURL.path
        ]
        return roots.first { root in
            normalizedPattern == root || normalizedPattern.hasPrefix(root + "/")
        }
    }

    private static func isExcludedCandidatePath(
        _ path: String,
        prefixes: Set<String>
    ) -> Bool {
        for prefix in prefixes {
            if path == prefix { return true }
            if prefix == "/" || path.hasPrefix(prefix + "/") { return true }
        }
        return false
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
        guard let pathResolver = CommonAppCacheRootedPathResolver(
            logicalRoot: home
        ) else { return [] }
        return expandPatternWithReport(
            rawPattern,
            home: home,
            fileManager: fileManager,
            maxResults: maxResults,
            pathResolver: pathResolver,
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
        pathResolver: CommonAppCacheRootedPathResolver,
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
            maxResults: maxResults,
            pathResolver: pathResolver,
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
        maxResults: Int,
        pathResolver: CommonAppCacheRootedPathResolver,
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
        let fd = pathResolver.openDirectory(base)
        guard fd >= 0 else {
            let openError = errno
            if openError != ENOENT {
                incompletePaths.append(IncompletePath(
                    path: base,
                    reason: openError == ELOOP || openError == ENOTDIR
                        ? .pathIdentityChanged
                        : .directoryOpenFailed
                ))
            }
            return
        }
        defer { Darwin.close(fd) }
        var names: [String] = []
        let enumerationOutcome = BulkEnumerate.enumerate(
            fd: fd,
            dirPath: base,
            shouldCancel: shouldCancel,
            fallbackPolicy: .boundedMemory
        ) { entry in
            names.append(entry.name)
            return true
        }
        switch enumerationOutcome {
        case .complete:
            break
        case .completeWithIssues(let issues):
            incompletePaths.append(contentsOf: issues.map {
                IncompletePath(path: $0.path, reason: .metadataUnavailable)
            })
        case .failed(let issue):
            incompletePaths.append(IncompletePath(
                path: issue.path,
                reason: .enumerationFailed
            ))
            return
        case .stoppedByConsumer:
            if shouldCancel() {
                wasCancelled = true
            } else {
                incompletePaths.append(IncompletePath(
                    path: base,
                    reason: .enumerationFailed
                ))
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
                maxResults: maxResults,
                pathResolver: pathResolver,
                output: &output,
                incompletePaths: &incompletePaths,
                didTruncate: &didTruncate,
                wasCancelled: &wasCancelled,
                shouldCancel: shouldCancel
            )
            if didTruncate || wasCancelled { return }
        }
    }

    // MARK: - Shared candidate forest measurement

    private struct CandidateAccumulator {
        let inodes = InodeSet()
        var allocatedBytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var entryCount: Int = 0
        var entryLimitReached = false
    }

    private struct CandidateGroup {
        let ownerIndex: Int
        let indices: [Int]
    }

    private struct CandidateCoverageHierarchy {
        let parentByIndex: [Int?]
    }

    private struct DirectoryWork {
        let path: String
        let rootDevice: UInt64
        let expectedDevice: UInt64
        let expectedInode: UInt64
        let activeCandidateIndices: [Int]
    }

    private struct UnionAccumulator {
        let inodes = InodeSet()
        var allocatedBytes: Int64 = 0
        var logicalBytes: Int64 = 0
    }

    private struct CandidateForestMeasurement {
        let candidateStats: [SizeStat]
        let uniqueTotalBytes: Int64
        let uniqueLogicalBytes: Int64
        let uniqueEntryCount: Int
        let incompletePaths: [IncompletePath]
        let wasCancelled: Bool
        let completedGroupCount: Int
        let totalGroupCount: Int
        let checkpoint: Checkpoint
        let pendingPaths: [String]
    }

    private struct TraversalOutcome {
        let timedOut: Bool
        let wasCancelled: Bool
    }

    private static func measureCandidates(
        _ candidates: [Candidate],
        deadline: Date,
        maxEntriesPerPath: Int,
        initialIncompletePaths: [IncompletePath],
        lstatPath: (String, inout stat) -> Int32,
        shouldCancel: () -> Bool,
        openDirectory: (String) -> Int32,
        onProgress: ProgressHandler
    ) -> CandidateForestMeasurement {
        let initialCheckpoint = Checkpoint(
            hits: [],
            incompletePaths: deduplicatedIncompletePaths(initialIncompletePaths),
            uniqueTotalBytes: 0,
            uniqueLogicalBytes: 0,
            uniqueEntryCount: 0,
            completedGroupCount: 0
        )
        guard !candidates.isEmpty else {
            onProgress(Progress(
                phase: .measuringGroups,
                completedGroups: 0,
                totalGroups: 0,
                checkpoint: initialCheckpoint,
                pendingPaths: []
            ))
            return CandidateForestMeasurement(
                candidateStats: [],
                uniqueTotalBytes: 0,
                uniqueLogicalBytes: 0,
                uniqueEntryCount: 0,
                incompletePaths: [],
                wasCancelled: shouldCancel(),
                completedGroupCount: 0,
                totalGroupCount: 0,
                checkpoint: initialCheckpoint,
                pendingPaths: []
            )
        }

        var accumulators = candidates.map { _ in CandidateAccumulator() }
        var union = UnionAccumulator()
        var incompletePaths: [IncompletePath] = []
        let indexByPath = Dictionary(
            uniqueKeysWithValues: candidates.indices.map { (candidates[$0].path, $0) }
        )
        let groups = candidateGroups(candidates)
        let coverageHierarchy = candidateCoverageHierarchy(
            candidates: candidates,
            indexByPath: indexByPath
        )
        var completedGroupCount = 0
        var completedCandidateIndices = Set<Int>()
        var checkpoint = initialCheckpoint
        var pendingPaths = candidatePaths(
            in: groups[...],
            candidates: candidates
        )

        for (groupPosition, group) in groups.enumerated() {
            pendingPaths = candidatePaths(
                in: groups[groupPosition...],
                candidates: candidates
            )
            onProgress(Progress(
                phase: .measuringGroups,
                completedGroups: completedGroupCount,
                totalGroups: groups.count,
                currentVerdict: candidates[group.ownerIndex].pathRule.verdict,
                currentPath: candidates[group.ownerIndex].path,
                checkpoint: checkpoint,
                pendingPaths: pendingPaths
            ))
            if shouldCancel() {
                return cancelledForestMeasurement(
                    candidateCount: candidates.count,
                    completedGroupCount: completedGroupCount,
                    totalGroupCount: groups.count,
                    checkpoint: checkpoint,
                    pendingPaths: pendingPaths
                )
            }
            if Date() >= deadline {
                for remainingGroup in groups[groupPosition...] {
                    incompletePaths.append(contentsOf: remainingGroup.indices.map {
                        IncompletePath(path: candidates[$0].path, reason: .deadlineExceeded)
                    })
                }
                checkpoint = makeCheckpoint(
                    candidates: candidates,
                    accumulators: accumulators,
                    completedCandidateIndices: completedCandidateIndices,
                    incompletePaths: initialIncompletePaths + incompletePaths,
                    union: union,
                    coverageHierarchy: coverageHierarchy,
                    completedGroupCount: completedGroupCount
                )
                break
            }

            var started = Set<Int>()
            var completedPathsInCurrentGroup = Set<String>()
            let groupSet = Set(group.indices)
            let traversalOrder = [group.ownerIndex] + group.indices
                .filter { $0 != group.ownerIndex }
                .sorted {
                    let lhsDepth = NSString(string: candidates[$0].path).pathComponents.count
                    let rhsDepth = NSString(string: candidates[$1].path).pathComponents.count
                    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                    return $0 < $1
                }

            for candidateIndex in traversalOrder where !started.contains(candidateIndex) {
                let startedBefore = started
                let outcome = traverseCandidateRoot(
                    candidateIndex,
                    candidates: candidates,
                    groupIndices: groupSet,
                    indexByPath: indexByPath,
                    deadline: deadline,
                    maxEntriesPerPath: maxEntriesPerPath,
                    lstatPath: lstatPath,
                    shouldCancel: shouldCancel,
                    openDirectory: openDirectory,
                    started: &started,
                    accumulators: &accumulators,
                    union: &union,
                    incompletePaths: &incompletePaths
                )
                if outcome.wasCancelled || shouldCancel() {
                    return cancelledForestMeasurement(
                        candidateCount: candidates.count,
                        completedGroupCount: completedGroupCount,
                        totalGroupCount: groups.count,
                        checkpoint: checkpoint,
                        pendingPaths: pendingPaths
                    )
                }
                if outcome.timedOut {
                    incompletePaths.append(contentsOf: group.indices.compactMap { index in
                        let path = candidates[index].path
                        return completedPathsInCurrentGroup.contains(path)
                            ? nil
                            : IncompletePath(path: path, reason: .deadlineExceeded)
                    })
                    if groupPosition + 1 < groups.count {
                        for remainingGroup in groups[(groupPosition + 1)...] {
                            incompletePaths.append(contentsOf: remainingGroup.indices.map {
                                IncompletePath(path: candidates[$0].path, reason: .deadlineExceeded)
                            })
                        }
                    }
                    checkpoint = makeCheckpoint(
                        candidates: candidates,
                        accumulators: accumulators,
                        completedCandidateIndices: completedCandidateIndices,
                        incompletePaths: initialIncompletePaths + incompletePaths,
                        union: union,
                        coverageHierarchy: coverageHierarchy,
                        completedGroupCount: completedGroupCount
                    )
                    pendingPaths = candidatePaths(
                        in: groups[groupPosition...],
                        candidates: candidates
                    ).filter { !completedPathsInCurrentGroup.contains($0) }
                    let stats = makeCandidateStats(accumulators)
                    return CandidateForestMeasurement(
                        candidateStats: stats,
                        uniqueTotalBytes: union.allocatedBytes,
                        uniqueLogicalBytes: union.logicalBytes,
                        uniqueEntryCount: uniqueEntryCount(
                            candidates: candidates,
                            accumulators: accumulators,
                            hierarchy: coverageHierarchy
                        ),
                        incompletePaths: deduplicatedIncompletePaths(incompletePaths),
                        wasCancelled: false,
                        completedGroupCount: completedGroupCount,
                        totalGroupCount: groups.count,
                        checkpoint: checkpoint,
                        pendingPaths: pendingPaths
                    )
                }
                let newlyCompletedIndices = started.subtracting(startedBefore)
                completedCandidateIndices.formUnion(newlyCompletedIndices)
                for completedIndex in newlyCompletedIndices {
                    completedPathsInCurrentGroup.insert(candidates[completedIndex].path)
                }
            }
            completedGroupCount &+= 1
            completedCandidateIndices.formUnion(group.indices)
            checkpoint = makeCheckpoint(
                candidates: candidates,
                accumulators: accumulators,
                completedCandidateIndices: completedCandidateIndices,
                incompletePaths: initialIncompletePaths + incompletePaths,
                union: union,
                coverageHierarchy: coverageHierarchy,
                completedGroupCount: completedGroupCount
            )
            pendingPaths = groupPosition + 1 < groups.count
                ? candidatePaths(
                    in: groups[(groupPosition + 1)...],
                    candidates: candidates
                )
                : []
            onProgress(Progress(
                phase: .measuringGroups,
                completedGroups: completedGroupCount,
                totalGroups: groups.count,
                currentVerdict: candidates[group.ownerIndex].pathRule.verdict,
                currentPath: candidates[group.ownerIndex].path,
                checkpoint: checkpoint,
                pendingPaths: pendingPaths
            ))
        }

        if shouldCancel() {
            return cancelledForestMeasurement(
                candidateCount: candidates.count,
                completedGroupCount: completedGroupCount,
                totalGroupCount: groups.count,
                checkpoint: checkpoint,
                pendingPaths: pendingPaths
            )
        }
        return CandidateForestMeasurement(
            candidateStats: makeCandidateStats(accumulators),
            uniqueTotalBytes: union.allocatedBytes,
            uniqueLogicalBytes: union.logicalBytes,
            uniqueEntryCount: uniqueEntryCount(
                candidates: candidates,
                accumulators: accumulators,
                hierarchy: coverageHierarchy
            ),
            incompletePaths: deduplicatedIncompletePaths(incompletePaths),
            wasCancelled: false,
            completedGroupCount: completedGroupCount,
            totalGroupCount: groups.count,
            checkpoint: checkpoint,
            pendingPaths: pendingPaths
        )
    }

    private static func candidateGroups(_ candidates: [Candidate]) -> [CandidateGroup] {
        // v2026.07.17 regression guard: candidate resolution already prioritizes safe paths,
        // but the old forest owner selection ignored verdict. A confirm parent could therefore
        // become the owner of a safe child and block the safe scan before its first open. Forest
        // sharing is now deliberately scoped to one verdict; groups remain shared/deduplicated
        // within that verdict and are then ordered safe → confirm → forbid.
        let indexByPath = Dictionary(
            uniqueKeysWithValues: candidates.indices.map { (candidates[$0].path, $0) }
        )
        var membersByOwner: [Int: [Int]] = [:]
        for candidateIndex in candidates.indices {
            var ownerIndex = candidateIndex
            for ancestorIndex in ancestorCandidateIndices(
                of: candidates[candidateIndex].path,
                indexByPath: indexByPath
            ) where candidates[ancestorIndex].isDirectory
                && candidates[ancestorIndex].pathRule.verdict
                    == candidates[candidateIndex].pathRule.verdict {
                // Ancestors are yielded nearest-first; continuing to the root leaves the
                // outermost same-verdict candidate as the one shared traversal owner.
                ownerIndex = ancestorIndex
            }
            membersByOwner[ownerIndex, default: []].append(candidateIndex)
        }
        return membersByOwner.map { ownerIndex, members in
            CandidateGroup(ownerIndex: ownerIndex, indices: members.sorted())
        }.sorted { lhs, rhs in
            let lhsVerdictPriority = verdictPriority(
                candidates[lhs.ownerIndex].pathRule.verdict
            )
            let rhsVerdictPriority = verdictPriority(
                candidates[rhs.ownerIndex].pathRule.verdict
            )
            if lhsVerdictPriority != rhsVerdictPriority {
                return lhsVerdictPriority < rhsVerdictPriority
            }
            let lhsPriority = lhs.indices.min() ?? lhs.ownerIndex
            let rhsPriority = rhs.indices.min() ?? rhs.ownerIndex
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return candidates[lhs.ownerIndex].path < candidates[rhs.ownerIndex].path
        }
    }

    private static func candidateCoverageHierarchy(
        candidates: [Candidate],
        indexByPath: [String: Int]
    ) -> CandidateCoverageHierarchy {
        let parentByIndex = candidates.indices.map { candidateIndex -> Int? in
            ancestorCandidateIndices(
                of: candidates[candidateIndex].path,
                indexByPath: indexByPath
            ).first(where: { candidates[$0].isDirectory })
        }
        return CandidateCoverageHierarchy(parentByIndex: parentByIndex)
    }

    /// Returns existing candidate ancestors nearest-first without scanning the candidate array.
    /// Path depth is small and bounded by the filesystem path, so group construction stays
    /// O(candidate count × path depth) rather than O(candidate count²).
    private static func ancestorCandidateIndices(
        of path: String,
        indexByPath: [String: Int]
    ) -> [Int] {
        var result: [Int] = []
        var current = NSString(string: path).deletingLastPathComponent
        while !current.isEmpty, current != path {
            if let index = indexByPath[current] {
                result.append(index)
            }
            if current == "/" { break }
            let parent = NSString(string: current).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return result
    }

    private static func candidatePaths(
        in groups: ArraySlice<CandidateGroup>,
        candidates: [Candidate]
    ) -> [String] {
        groups.flatMap { group in
            group.indices.sorted().map { candidates[$0].path }
        }
    }

    private static func traverseCandidateRoot(
        _ rootIndex: Int,
        candidates: [Candidate],
        groupIndices: Set<Int>,
        indexByPath: [String: Int],
        deadline: Date,
        maxEntriesPerPath: Int,
        lstatPath: (String, inout stat) -> Int32,
        shouldCancel: () -> Bool,
        openDirectory: (String) -> Int32,
        started: inout Set<Int>,
        accumulators: inout [CandidateAccumulator],
        union: inout UnionAccumulator,
        incompletePaths: inout [IncompletePath]
    ) -> TraversalOutcome {
        guard started.insert(rootIndex).inserted else {
            return TraversalOutcome(timedOut: false, wasCancelled: false)
        }
        if shouldCancel() {
            return TraversalOutcome(timedOut: false, wasCancelled: true)
        }
        if Date() >= deadline {
            return TraversalOutcome(timedOut: true, wasCancelled: false)
        }

        let rootCandidate = candidates[rootIndex]
        guard rootCandidate.isDirectory else {
            var metadata = stat()
            guard lstatPath(rootCandidate.path, &metadata) == 0 else {
                let metadataError = errno
                if metadataError != ENOENT {
                    incompletePaths.append(IncompletePath(
                        path: rootCandidate.path,
                        reason: metadataFailureReason(metadataError)
                    ))
                }
                return TraversalOutcome(timedOut: false, wasCancelled: false)
            }
            guard PathIdentity(metadata) == rootCandidate.identity else {
                incompletePaths.append(IncompletePath(
                    path: rootCandidate.path,
                    reason: .pathIdentityChanged
                ))
                return TraversalOutcome(timedOut: false, wasCancelled: false)
            }
            if shouldCancel() {
                return TraversalOutcome(timedOut: false, wasCancelled: true)
            }
            let accepted = acceptEntry(
                for: [rootIndex],
                candidates: candidates,
                maxEntriesPerPath: maxEntriesPerPath,
                accumulators: &accumulators,
                incompletePaths: &incompletePaths
            )
            if !accepted.isEmpty {
                recordFileBytes(
                    allocated: Int64(metadata.st_blocks) * 512,
                    logical: Int64(metadata.st_size),
                    device: UInt64(bitPattern: Int64(metadata.st_dev)),
                    inode: UInt64(metadata.st_ino),
                    acceptedCandidateIndices: accepted,
                    accumulators: &accumulators,
                    union: &union
                )
            }
            return TraversalOutcome(timedOut: false, wasCancelled: false)
        }

        var rootStat = stat()
        guard lstatPath(rootCandidate.path, &rootStat) == 0 else {
            let metadataError = errno
            if metadataError != ENOENT {
                incompletePaths.append(IncompletePath(
                    path: rootCandidate.path,
                    reason: metadataFailureReason(metadataError)
                ))
            }
            return TraversalOutcome(timedOut: false, wasCancelled: false)
        }
        let currentRootIdentity = PathIdentity(rootStat)
        guard currentRootIdentity == rootCandidate.identity,
              currentRootIdentity.isDirectory else {
            incompletePaths.append(IncompletePath(
                path: rootCandidate.path,
                reason: .pathIdentityChanged
            ))
            return TraversalOutcome(timedOut: false, wasCancelled: false)
        }
        let rootDevice = currentRootIdentity.device
        var stack = [DirectoryWork(
            path: rootCandidate.path,
            rootDevice: rootDevice,
            expectedDevice: currentRootIdentity.device,
            expectedInode: currentRootIdentity.inode,
            activeCandidateIndices: [rootIndex]
        )]
        var entryClock = 0

        while let work = stack.popLast() {
            if shouldCancel() {
                return TraversalOutcome(timedOut: false, wasCancelled: true)
            }
            if Date() >= deadline {
                return TraversalOutcome(timedOut: true, wasCancelled: false)
            }
            let active = work.activeCandidateIndices.filter {
                !accumulators[$0].entryLimitReached
            }
            guard !active.isEmpty else { continue }

            let fd = openDirectory(work.path)
            if fd < 0 {
                if errno != ENOENT {
                    incompletePaths.append(IncompletePath(
                        path: work.path,
                        reason: .directoryOpenFailed
                    ))
                }
                continue
            }
            var openedMetadata = stat()
            guard fstat(fd, &openedMetadata) == 0,
                  (openedMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  UInt64(bitPattern: Int64(openedMetadata.st_dev)) == work.expectedDevice,
                  UInt64(openedMetadata.st_ino) == work.expectedInode else {
                Darwin.close(fd)
                incompletePaths.append(IncompletePath(
                    path: work.path,
                    reason: .pathIdentityChanged
                ))
                continue
            }

            var queuedDirectories: [DirectoryWork] = []
            var timedOut = false
            var cancelled = false
            var stoppedAfterEntryLimit = false
            let outcome = BulkEnumerate.enumerate(
                fd: fd,
                dirPath: work.path,
                shouldCancel: shouldCancel
            ) { entry in
                if shouldCancel() {
                    cancelled = true
                    return false
                }
                entryClock &+= 1
                if entryClock & 0xFF == 0, Date() >= deadline {
                    timedOut = true
                    return false
                }

                let entryPath = appendPathComponent(entry.name, to: work.path)
                let anyExactCandidateIndex = indexByPath[entryPath]
                let exactCandidateIndex = anyExactCandidateIndex.flatMap {
                    groupIndices.contains($0) ? $0 : nil
                }
                var accepted = acceptEntry(
                    for: active,
                    candidates: candidates,
                    maxEntriesPerPath: maxEntriesPerPath,
                    accumulators: &accumulators,
                    incompletePaths: &incompletePaths
                )

                let traversableFromThisRoot = !entry.isSymlink
                    && entry.device == work.rootDevice
                if let anyExactCandidateIndex,
                   !groupIndices.contains(anyExactCandidateIndex),
                   !candidateIdentity(
                       candidates[anyExactCandidateIndex].identity,
                       matches: entry
                   ) {
                    // A higher-priority verdict may already have measured this candidate before
                    // the broader group reached it. If the directory entry changed in between,
                    // keep the earlier lower-bound row but fail the whole path closed for delete.
                    incompletePaths.append(IncompletePath(
                        path: entryPath,
                        reason: .pathIdentityChanged
                    ))
                }
                if entry.isDirectory {
                    var childActive = active.filter {
                        !accumulators[$0].entryLimitReached
                    }
                    if traversableFromThisRoot,
                       let exactCandidateIndex,
                       candidates[exactCandidateIndex].isDirectory,
                       !started.contains(exactCandidateIndex) {
                        started.insert(exactCandidateIndex)
                        if candidateIdentity(
                            candidates[exactCandidateIndex].identity,
                            matches: entry
                        ) {
                            childActive.append(exactCandidateIndex)
                        } else {
                            // The parent row still owns the actual descendant it enumerated, but
                            // the nested rule was reviewed against a different object and must
                            // fail closed rather than inheriting the replacement's identity.
                            incompletePaths.append(IncompletePath(
                                path: entryPath,
                                reason: .pathIdentityChanged
                            ))
                        }
                    }
                    if traversableFromThisRoot, !childActive.isEmpty {
                        queuedDirectories.append(DirectoryWork(
                            path: entryPath,
                            rootDevice: work.rootDevice,
                            expectedDevice: entry.device,
                            expectedInode: entry.inode,
                            activeCandidateIndices: childActive
                        ))
                    }
                } else if traversableFromThisRoot {
                    if let exactCandidateIndex,
                       !candidates[exactCandidateIndex].isDirectory,
                       !started.contains(exactCandidateIndex) {
                        started.insert(exactCandidateIndex)
                        if candidateIdentity(
                            candidates[exactCandidateIndex].identity,
                            matches: entry
                        ) {
                            accepted.append(contentsOf: acceptEntry(
                                for: [exactCandidateIndex],
                                candidates: candidates,
                                maxEntriesPerPath: maxEntriesPerPath,
                                accumulators: &accumulators,
                                incompletePaths: &incompletePaths
                            ))
                        } else {
                            incompletePaths.append(IncompletePath(
                                path: entryPath,
                                reason: .pathIdentityChanged
                            ))
                        }
                    }
                    if !accepted.isEmpty {
                        recordFileBytes(
                            allocated: entry.allocatedSize,
                            logical: entry.logicalSize,
                            device: entry.device,
                            inode: entry.inode,
                            acceptedCandidateIndices: accepted,
                            accumulators: &accumulators,
                            union: &union
                        )
                    }
                }
                // 所有当前祖先都触发独立 entry limit 后，继续枚举同一目录只会浪费
                // I/O。尚未遇到的嵌套候选会在本 group 的后续 root traversal 中完成。
                if active.allSatisfy({ accumulators[$0].entryLimitReached }) {
                    stoppedAfterEntryLimit = true
                    return false
                }
                return true
            }
            Darwin.close(fd)

            if shouldCancel() || cancelled {
                return TraversalOutcome(timedOut: false, wasCancelled: true)
            }
            if timedOut {
                return TraversalOutcome(timedOut: true, wasCancelled: false)
            }

            switch outcome {
            case .complete:
                break
            case .completeWithIssues(let issues):
                incompletePaths.append(contentsOf: issues.map {
                    IncompletePath(path: $0.path, reason: .enumerationFailed)
                })
            case .stoppedByConsumer:
                if !stoppedAfterEntryLimit {
                    incompletePaths.append(IncompletePath(
                        path: work.path,
                        reason: .enumerationFailed
                    ))
                }
            case .failed:
                incompletePaths.append(IncompletePath(
                    path: work.path,
                    reason: .enumerationFailed
                ))
            }
            stack.append(contentsOf: queuedDirectories)
        }
        return TraversalOutcome(timedOut: false, wasCancelled: false)
    }

    private static func acceptEntry(
        for candidateIndices: [Int],
        candidates: [Candidate],
        maxEntriesPerPath: Int,
        accumulators: inout [CandidateAccumulator],
        incompletePaths: inout [IncompletePath]
    ) -> [Int] {
        var accepted: [Int] = []
        accepted.reserveCapacity(candidateIndices.count)
        var seen = Set<Int>()
        for index in candidateIndices where seen.insert(index).inserted {
            if accumulators[index].entryLimitReached { continue }
            if accumulators[index].entryCount >= maxEntriesPerPath {
                accumulators[index].entryLimitReached = true
                incompletePaths.append(IncompletePath(
                    path: candidates[index].path,
                    reason: .entryLimitReached
                ))
                continue
            }
            accumulators[index].entryCount &+= 1
            accepted.append(index)
        }
        return accepted
    }

    private static func recordFileBytes(
        allocated: Int64,
        logical: Int64,
        device: UInt64,
        inode: UInt64,
        acceptedCandidateIndices: [Int],
        accumulators: inout [CandidateAccumulator],
        union: inout UnionAccumulator
    ) {
        for index in acceptedCandidateIndices {
            if accumulators[index].inodes.insertIfFirstSeen(device: device, inode: inode) {
                accumulators[index].allocatedBytes &+= allocated
                accumulators[index].logicalBytes &+= logical
            }
        }
        if union.inodes.insertIfFirstSeen(device: device, inode: inode) {
            union.allocatedBytes &+= allocated
            union.logicalBytes &+= logical
        }
    }

    private static func appendPathComponent(_ component: String, to directory: String) -> String {
        directory == "/" ? "/\(component)" : "\(directory)/\(component)"
    }

    private static func candidateIdentity(
        _ identity: PathIdentity,
        matches entry: BulkEntry
    ) -> Bool {
        identity.device == entry.device
            && identity.inode == entry.inode
            && identity.isDirectory == entry.isDirectory
    }

    private static func makeCandidateStats(
        _ accumulators: [CandidateAccumulator]
    ) -> [SizeStat] {
        accumulators.map {
            SizeStat(
                bytes: $0.allocatedBytes,
                logicalBytes: $0.logicalBytes,
                entryCount: $0.entryCount,
                incompletePaths: [],
                wasCancelled: false
            )
        }
    }

    /// Derives the entry union from candidate coverage rather than retaining every traversed
    /// pathname. Complete outermost candidates are exact because their inclusive entryCount
    /// covers all nested rules. On a partial traversal, overlapping parent/child lower bounds use
    /// max while disjoint candidate branches sum, so the published value never double-counts and
    /// memory remains O(candidate count), independent of millions of cache entries.
    private static func uniqueEntryCount(
        candidates: [Candidate],
        accumulators: [CandidateAccumulator],
        hierarchy: CandidateCoverageHierarchy,
        includedCandidateIndices: Set<Int>? = nil
    ) -> Int {
        let included = includedCandidateIndices ?? Set(candidates.indices)
        guard !included.isEmpty else { return 0 }

        var children = Array(repeating: [Int](), count: candidates.count)
        var roots: [Int] = []
        for candidateIndex in included.sorted() {
            var nearestIncludedParent = hierarchy.parentByIndex[candidateIndex]
            while let parent = nearestIncludedParent, !included.contains(parent) {
                nearestIncludedParent = hierarchy.parentByIndex[parent]
            }
            if let nearestIncludedParent {
                children[nearestIncludedParent].append(candidateIndex)
            } else {
                roots.append(candidateIndex)
            }
        }

        func coverage(_ candidateIndex: Int, isNested: Bool) -> Int {
            let candidate = candidates[candidateIndex]
            let measured = accumulators[candidateIndex].entryCount
            guard candidate.isDirectory else {
                // A nested file root is itself one directory entry. For an outermost file,
                // retain the scanner's measured state so an unstarted deadline path stays 0.
                return isNested ? max(1, measured) : measured
            }
            let nestedCoverage = children[candidateIndex].reduce(into: 0) { total, child in
                total &+= coverage(child, isNested: true)
            }
            let descendantLowerBound = max(measured, nestedCoverage)
            return isNested ? descendantLowerBound &+ 1 : descendantLowerBound
        }

        return roots.reduce(into: 0) { total, root in
            total &+= coverage(root, isNested: false)
        }
    }

    private static func makeCheckpoint(
        candidates: [Candidate],
        accumulators: [CandidateAccumulator],
        completedCandidateIndices: Set<Int>,
        incompletePaths: [IncompletePath],
        union: UnionAccumulator,
        coverageHierarchy: CandidateCoverageHierarchy,
        completedGroupCount: Int
    ) -> Checkpoint {
        var hits: [Hit] = []
        hits.reserveCapacity(completedCandidateIndices.count)
        for index in completedCandidateIndices.sorted() {
            let candidate = candidates[index]
            let accumulator = accumulators[index]
            guard accumulator.allocatedBytes > 0 else { continue }
            hits.append(Hit(
                ruleName: candidate.rule.name,
                bundleIDPrefix: candidate.rule.bundleIDPrefix,
                source: candidate.rule.source,
                url: URL(fileURLWithPath: candidate.path),
                isDirectory: candidate.isDirectory,
                verdict: candidate.pathRule.verdict,
                reason: candidate.pathRule.reason,
                sizeBytes: accumulator.allocatedBytes,
                logicalSizeBytes: accumulator.logicalBytes,
                entryCount: accumulator.entryCount
            ))
        }
        hits.sort {
            if $0.sizeBytes == $1.sizeBytes { return $0.url.path < $1.url.path }
            return $0.sizeBytes > $1.sizeBytes
        }
        return Checkpoint(
            hits: hits,
            incompletePaths: deduplicatedIncompletePaths(incompletePaths),
            uniqueTotalBytes: union.allocatedBytes,
            uniqueLogicalBytes: union.logicalBytes,
            uniqueEntryCount: uniqueEntryCount(
                candidates: candidates,
                accumulators: accumulators,
                hierarchy: coverageHierarchy,
                includedCandidateIndices: completedCandidateIndices
            ),
            completedGroupCount: completedGroupCount
        )
    }

    private static func cancelledForestMeasurement(
        candidateCount: Int,
        completedGroupCount: Int,
        totalGroupCount: Int,
        checkpoint: Checkpoint,
        pendingPaths: [String]
    ) -> CandidateForestMeasurement {
        CandidateForestMeasurement(
            candidateStats: Array(repeating: SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [],
                wasCancelled: true
            ), count: candidateCount),
            uniqueTotalBytes: 0,
            uniqueLogicalBytes: 0,
            uniqueEntryCount: 0,
            incompletePaths: [],
            wasCancelled: true,
            completedGroupCount: completedGroupCount,
            totalGroupCount: totalGroupCount,
            checkpoint: checkpoint,
            pendingPaths: pendingPaths
        )
    }

    struct SizeStat {
        /// on-disk allocated bytes；`bytes` 保留现有调用名，但语义固定为磁盘占用。
        let bytes: Int64
        let logicalBytes: Int64
        let entryCount: Int
        let incompletePaths: [IncompletePath]
        let wasCancelled: Bool

        init(bytes: Int64,
             logicalBytes: Int64? = nil,
             entryCount: Int,
             incompletePaths: [IncompletePath],
             wasCancelled: Bool) {
            self.bytes = bytes
            self.logicalBytes = logicalBytes ?? bytes
            self.entryCount = entryCount
            self.incompletePaths = incompletePaths
            self.wasCancelled = wasCancelled
        }
    }

    static func sizeOfPath(
        _ path: String,
        isDirectory: Bool,
        deadline: Date,
        maxEntries: Int,
        shouldCancel: () -> Bool = { Task.isCancelled },
        openDirectory: ((String) -> Int32)? = nil
    ) -> SizeStat {
        if shouldCancel() {
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [],
                wasCancelled: true
            )
        }
        let resolverRoot = isDirectory
            ? path
            : NSString(string: path).deletingLastPathComponent
        guard let pathResolver = CommonAppCacheRootedPathResolver(
            logicalRoot: resolverRoot.isEmpty ? "/" : resolverRoot
        ) else {
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [IncompletePath(
                    path: path,
                    reason: .directoryOpenFailed
                )],
                wasCancelled: false
            )
        }
        let effectiveOpenDirectory: (String) -> Int32 = openDirectory ?? {
            pathResolver.openDirectory($0)
        }
        if !isDirectory {
            var st = stat()
            guard pathResolver.lstat(path, metadata: &st) == 0 else {
                let metadataError = errno
                let issues = metadataError == ENOENT
                    ? []
                    : [IncompletePath(
                        path: path,
                        reason: metadataFailureReason(metadataError)
                    )]
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
                bytes: Int64(st.st_blocks) * 512,
                logicalBytes: Int64(st.st_size),
                entryCount: 1,
                incompletePaths: [],
                wasCancelled: false
            )
        }
        return sizeOfDirectory(
            path,
            deadline: deadline,
            maxEntries: maxEntries,
            lstatPath: { candidatePath, metadata in
                pathResolver.lstat(candidatePath, metadata: &metadata)
            },
            shouldCancel: shouldCancel,
            openDirectory: effectiveOpenDirectory
        )
    }

    private static func sizeOfDirectory(
        _ rootPath: String,
        deadline: Date,
        maxEntries: Int,
        lstatPath: (String, inout stat) -> Int32,
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
        guard lstatPath(rootPath, &rootStat) == 0 else {
            let metadataError = errno
            let issues = metadataError == ENOENT
                ? []
                : [IncompletePath(
                    path: rootPath,
                    reason: metadataFailureReason(metadataError)
                )]
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: issues,
                wasCancelled: false
            )
        }
        let rootIdentity = PathIdentity(rootStat)
        guard rootIdentity.isDirectory else {
            return SizeStat(
                bytes: 0,
                entryCount: 0,
                incompletePaths: [IncompletePath(path: rootPath, reason: .pathIdentityChanged)],
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
        let rootDevice = rootIdentity.device

        var stack = [DirectoryWork(
            path: rootPath,
            rootDevice: rootDevice,
            expectedDevice: rootIdentity.device,
            expectedInode: rootIdentity.inode,
            activeCandidateIndices: []
        )]
        var allocatedTotal: Int64 = 0
        var logicalTotal: Int64 = 0
        var entries = 0
        // 单个候选目录就是一个独立计量会话：与 `du <directory>` 相同，目录内
        // hardlink 只计一次；不跨候选共享，避免并发扫描时结果取决于完成顺序。
        let inodes = InodeSet()
        var incompletePaths: [IncompletePath] = []
        var wasCancelled = false

        while let work = stack.popLast() {
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
            let fd = openDirectory(work.path)
            if fd < 0 {
                if errno != ENOENT {
                    incompletePaths.append(IncompletePath(path: work.path, reason: .directoryOpenFailed))
                }
                continue
            }
            var openedMetadata = stat()
            guard fstat(fd, &openedMetadata) == 0,
                  (openedMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  UInt64(bitPattern: Int64(openedMetadata.st_dev)) == work.expectedDevice,
                  UInt64(openedMetadata.st_ino) == work.expectedInode else {
                Darwin.close(fd)
                incompletePaths.append(IncompletePath(
                    path: work.path,
                    reason: .pathIdentityChanged
                ))
                continue
            }
            var consumerStopReason: IncompletePath.Reason?
            let outcome = BulkEnumerate.enumerate(
                fd: fd,
                dirPath: work.path,
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
                    stack.append(DirectoryWork(
                        path: appendPathComponent(entry.name, to: work.path),
                        rootDevice: rootDevice,
                        expectedDevice: entry.device,
                        expectedInode: entry.inode,
                        activeCandidateIndices: []
                    ))
                } else {
                    let isFirstLink = inodes.insertIfFirstSeen(
                        device: entry.device,
                        inode: entry.inode
                    )
                    if isFirstLink {
                        allocatedTotal &+= entry.allocatedSize
                        logicalTotal &+= entry.logicalSize
                    }
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
            case .completeWithIssues(let issues):
                incompletePaths.append(contentsOf: issues.map {
                    IncompletePath(path: $0.path, reason: .enumerationFailed)
                })
            case .stoppedByConsumer:
                incompletePaths.append(IncompletePath(
                    path: rootPath,
                    reason: consumerStopReason ?? .enumerationFailed
                ))
            case .failed:
                incompletePaths.append(IncompletePath(path: work.path, reason: .enumerationFailed))
            }
            if consumerStopReason != nil { break }
        }
        return SizeStat(
            bytes: wasCancelled ? 0 : allocatedTotal,
            logicalBytes: wasCancelled ? 0 : logicalTotal,
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

    private static func metadataFailureReason(_ errorCode: Int32) -> IncompletePath.Reason {
        errorCode == ELOOP || errorCode == ENOTDIR
            ? .pathIdentityChanged
            : .metadataUnavailable
    }
}

/// A scan HOME is the trusted boundary; only descendants below its frozen descriptor are opened
/// component-by-component with no-follow semantics. The root itself is opened once as a complete
/// path so macOS-managed aliases above (or at) HOME remain usable; after that, every in-HOME
/// component is resolved relative to the frozen descriptor and cannot become a symlink escape.
///
/// v2026.07.17: Foundation does not consistently expose `/var -> /private/var` through
/// `resolvingSymlinksInPath()`. Re-opening its returned string component-by-component with
/// `O_NOFOLLOW` therefore rejected normal `NSTemporaryDirectory()` roots. Freezing the trusted
/// root in one `open(2)` call keeps that system alias valid without weakening descendant checks.
private final class CommonAppCacheRootedPathResolver {
    private let logicalRoot: String
    private let rootFD: Int32
    private let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    init?(logicalRoot: String) {
        let normalizedLogicalRoot = URL(fileURLWithPath: logicalRoot)
            .standardizedFileURL
            .path
        let descriptor = Darwin.open(
            normalizedLogicalRoot,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            Darwin.close(descriptor)
            return nil
        }
        self.logicalRoot = normalizedLogicalRoot
        self.rootFD = descriptor
    }

    deinit {
        Darwin.close(rootFD)
    }

    func openDirectory(_ path: String) -> Int32 {
        guard let components = relativeComponents(for: path) else {
            errno = EPERM
            return -1
        }
        var currentFD = Darwin.openat(rootFD, ".", flags, 0)
        guard currentFD >= 0 else { return -1 }
        for component in components {
            let nextFD = Darwin.openat(currentFD, component, flags, 0)
            if nextFD < 0 {
                let openError = errno
                Darwin.close(currentFD)
                errno = openError
                return -1
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    func lstat(_ path: String, metadata: inout stat) -> Int32 {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == logicalRoot {
            return fstat(rootFD, &metadata)
        }
        let parent = NSString(string: normalized).deletingLastPathComponent
        let name = NSString(string: normalized).lastPathComponent
        let parentFD = openDirectory(parent.isEmpty ? logicalRoot : parent)
        guard parentFD >= 0 else { return -1 }
        let result = Darwin.fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW)
        let metadataError = errno
        Darwin.close(parentFD)
        if result != 0 { errno = metadataError }
        return result
    }

    private func relativeComponents(for path: String) -> [String]? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == logicalRoot { return [] }
        let relative: String
        if logicalRoot == "/" {
            guard normalized.hasPrefix("/") else { return nil }
            relative = String(normalized.dropFirst())
        } else {
            guard normalized.hasPrefix(logicalRoot + "/") else { return nil }
            relative = String(normalized.dropFirst(logicalRoot.count + 1))
        }
        return NSString(string: relative).pathComponents.filter {
            !$0.isEmpty && $0 != "/"
        }
    }

}
