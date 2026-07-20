import Foundation

/// Step 11A / 2026-06：Spotlight 残留补刀。
///
/// 背景：[AppUninstaller.candidatesAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
/// 走 11 个用户级 + 1 个系统级 search root 第一层目录扫描；
/// 但有些 app 的残留落在**非典型位置**（比如某厂商把数据写在
/// `~/Library/Mobile Documents/iCloud~xxx`、`~/Documents/<AppName>` 等），
/// 第一层 root 列表无法穷举。
///
/// 解决：扫完主路径后，用 macOS Spotlight（NSMetadataQuery）做一次
/// 严格谓词补刀，查 `kMDItemCFBundleIdentifier == bundleID` 与
/// `kMDItemDisplayName ==[c] appName` 命中的路径，与主路径去重后追加。
///
/// 设计要点：
/// 1. **协议抽象**：`SpotlightProbing` 让单测可以用 fake 注入固定路径，
///    避免依赖系统 mds 索引（CI 环境通常索引不全）。
/// 2. **严格谓词**：bundleID 用 `==` 严格相等（不前缀匹配，避免 `com.foo`
///    误带出 `com.foobar`）；appName 用 `==[c]`（case-insensitive 严格相等）
///    且要求长度 >= 4。
/// 3. **路径去重**：与已有 `seenPaths` 合并；新路径若不存在 / 0B / 无 entries 跳过。
/// 4. **Typed terminal evidence**：空结果是一次成功查询；启动失败、超时与取消分别保留，
///    调用方不能再把它们伪装成“完整且没有命中”。
///
/// 决策来源：[docs/AUDIT_2026_06.md L416-L417](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/AUDIT_2026_06.md#L416-L417)。

/// Spotlight 查询抽象层。生产实现走 NSMetadataQuery，测试实现走内存 fixture。
public enum SpotlightProbeFailure: Hashable, Sendable {
    case startFailed
    case timedOut
    case cancelled
    case resultCountLimitExceeded(limit: Int)
    case extractionTimeLimitExceeded(limitMilliseconds: Int64)
}

/// Pure budget/normalization pieces are separated from NSMetadataQuery so truncation semantics are
/// deterministic in tests. The MainActor only freezes a bounded set of path strings; canonical
/// validation and deduplication happen on a utility worker.
struct SpotlightResultBudget: Sendable, Equatable {
    let maximumResultCount: Int
    let maximumMainActorExtractionNanoseconds: UInt64

    static let production = SpotlightResultBudget(
        maximumResultCount: 4_096,
        maximumMainActorExtractionNanoseconds: 25_000_000
    )

    init(maximumResultCount: Int, maximumMainActorExtractionNanoseconds: UInt64) {
        self.maximumResultCount = max(1, maximumResultCount)
        self.maximumMainActorExtractionNanoseconds = maximumMainActorExtractionNanoseconds
    }

    func countFailure(totalResultCount: Int) -> SpotlightProbeFailure? {
        totalResultCount > maximumResultCount
            ? .resultCountLimitExceeded(limit: maximumResultCount)
            : nil
    }

    func timeFailureIfExceeded(
        startedAt: UInt64,
        now: UInt64
    ) -> SpotlightProbeFailure? {
        guard now &- startedAt >= maximumMainActorExtractionNanoseconds else { return nil }
        return .extractionTimeLimitExceeded(
            limitMilliseconds: Int64(maximumMainActorExtractionNanoseconds / 1_000_000)
        )
    }
}

enum SpotlightPathNormalizer {
    static func normalize(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { raw in
            guard raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
            let normalized = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard normalized.hasPrefix("/"), seen.insert(normalized).inserted else { return nil }
            return normalized
        }.sorted()
    }
}

struct SpotlightFrozenPathProjection: Sendable, Equatable {
    let paths: [String]
    let failure: SpotlightProbeFailure?
}

/// v2026.07.18: `NSMetadataQuery.result(at:)` is MainActor-only work. A numeric cap does not make
/// 4,096 synchronous calls responsive, so extraction is split into tiny RunLoop-cooperative
/// batches and checks cancellation/deadline before every item. Timeout/cancel can therefore run
/// between batches instead of waiting behind one long main-thread loop.
@MainActor
enum SpotlightBatchedPathExtractor {
    static func extract(
        totalResultCount: Int,
        budget: SpotlightResultBudget,
        batchSize: Int = 8,
        pathAtIndex: (Int) -> String?,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        cancellationRequested: () -> Bool = { Task.isCancelled },
        yieldBetweenBatches: () async -> Void = { await Task.yield() }
    ) async -> SpotlightFrozenPathProjection {
        let extractionLimit = min(totalResultCount, budget.maximumResultCount)
        let startedAt = now()
        var paths: [String] = []
        paths.reserveCapacity(extractionLimit)
        let failure = budget.countFailure(totalResultCount: totalResultCount)
        let boundedBatchSize = max(1, batchSize)
        var index = 0

        while index < extractionLimit {
            let end = min(index + boundedBatchSize, extractionLimit)
            while index < end {
                if cancellationRequested() {
                    return SpotlightFrozenPathProjection(paths: paths, failure: .cancelled)
                }
                if let timeFailure = budget.timeFailureIfExceeded(
                    startedAt: startedAt,
                    now: now()
                ) {
                    return SpotlightFrozenPathProjection(paths: paths, failure: timeFailure)
                }
                if let path = pathAtIndex(index) { paths.append(path) }
                index += 1
            }
            if index < extractionLimit {
                await yieldBetweenBatches()
            }
        }
        return SpotlightFrozenPathProjection(paths: paths, failure: failure)
    }
}

/// 一条 Spotlight 谓词的终态。`paths=[]` 只有在 `failure == nil` 时才表示索引完整返回空。
public struct SpotlightProbeResult: Hashable, Sendable {
    public let paths: [String]
    public let failure: SpotlightProbeFailure?

    public var isComplete: Bool { failure == nil }

    public init(paths: [String], failure: SpotlightProbeFailure? = nil) {
        self.paths = paths
        self.failure = failure
    }

    public static func failed(_ failure: SpotlightProbeFailure) -> SpotlightProbeResult {
        SpotlightProbeResult(paths: [], failure: failure)
    }
}

public protocol SpotlightProbing: Sendable {
    /// 按 bundleID 严格相等查路径。返回的路径**未必存在**或**未必属于该 app 残留**，
    /// 调用方负责后续过滤。
    /// - timeout: 查询超时（秒）。NSMetadataQuery 真实实现需要这个上限避免 UI 卡死；
    ///   fake 实现可忽略。
    func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String]

    /// 按 appName 严格相等（忽略大小写）查路径。
    func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String]

    /// Typed variants are the production completeness boundary. The defaults keep existing
    /// in-memory probes source-compatible and interpret their returned array as a successful query.
    func probeByBundleIDEvidence(
        _ bundleID: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult
    func probeByAppNameEvidence(
        _ appName: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult
}

public extension SpotlightProbing {
    func probeByBundleIDEvidence(
        _ bundleID: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult {
        SpotlightProbeResult(paths: await probeByBundleID(bundleID, timeout: timeout))
    }

    func probeByAppNameEvidence(
        _ appName: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult {
        SpotlightProbeResult(paths: await probeByAppName(appName, timeout: timeout))
    }
}

/// 默认实现：NSMetadataQuery（全用户域 + 本地索引）。
///
/// 仅在 macOS sandbox=false 时能查到 user-domain 完整结果；sandbox=true 时
/// 受限于 entitlements。本 App 当前 sandbox=false（详见 GSYCleanMac.entitlements）。
public final class DefaultSpotlightProbe: SpotlightProbing, @unchecked Sendable {
    public init() {}

    public func probeByBundleID(
        _ bundleID: String,
        timeout: TimeInterval
    ) async -> [String] {
        await probeByBundleIDEvidence(bundleID, timeout: timeout).paths
    }

    public func probeByBundleIDEvidence(
        _ bundleID: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult {
        // 谓词：kMDItemCFBundleIdentifier == "<bundleID>"
        await runQuery(
            predicateFormat: "kMDItemCFBundleIdentifier == %@",
            argument: bundleID,
            timeout: timeout
        )
    }

    public func probeByAppName(
        _ appName: String,
        timeout: TimeInterval
    ) async -> [String] {
        await probeByAppNameEvidence(appName, timeout: timeout).paths
    }

    public func probeByAppNameEvidence(
        _ appName: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult {
        // 严格相等（忽略大小写）：kMDItemDisplayName ==[c] "<appName>"
        await runQuery(
            predicateFormat: "kMDItemDisplayName ==[c] %@",
            argument: appName,
            timeout: timeout
        )
    }

    private func runQuery(
        predicateFormat: String,
        argument: String,
        timeout: TimeInterval
    ) async -> SpotlightProbeResult {
        // NSMetadataQuery 必须在主线程启动并由 RunLoop 驱动。State 在 continuation 安装前
        // 也能记录取消终态，消除“Task 已取消但 query 仍等满 timeout”的竞态。
        let state = await MainActor.run { SpotlightQueryState() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    state.begin(
                        predicateFormat: predicateFormat,
                        argument: argument,
                        timeout: Self.normalizedTimeout(timeout),
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor in
                state.cancel()
            }
        }
    }

    /// A caller-provided NaN/infinity must not turn a bounded metadata query into an immortal one.
    /// Production uses 1.5 s; 30 s is only a defensive API ceiling.
    private static func normalizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite, timeout > 0 else { return 0 }
        return min(timeout, 30)
    }
}

/// NSMetadataQuery + observer + resumed 标志的 main-actor isolated holder。
/// 单一职责：把分散的 capture 收拢成一个对象引用，绕开 @Sendable 闭包对值类型的捕获限制。
@MainActor
private final class SpotlightQueryState {
    let query = NSMetadataQuery()
    var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<SpotlightProbeResult, Never>?
    private var terminalResult: SpotlightProbeResult?
    private var timeoutWorkItem: DispatchWorkItem?
    private var extractionTask: Task<Void, Never>?
    private var normalizationTask: Task<Void, Never>?

    func begin(
        predicateFormat: String,
        argument: String,
        timeout: TimeInterval,
        continuation: CheckedContinuation<SpotlightProbeResult, Never>
    ) {
        precondition(self.continuation == nil)
        self.continuation = continuation
        if let terminalResult {
            self.continuation = nil
            continuation.resume(returning: terminalResult)
            return
        }

        query.predicate = NSPredicate(format: predicateFormat, argument)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.freezeFinishedQueryResults()
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.finish(with: .failed(.timedOut))
            }
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)

        guard query.start() else {
            finish(with: .failed(.startFailed))
            return
        }
    }

    func cancel() {
        finish(with: .failed(.cancelled))
    }

    /// NSMetadataQuery is MainActor/RunLoop-bound, but result interpretation is not. Freeze only a
    /// bounded path-string projection while updates are disabled, then normalize/deduplicate it on
    /// a utility executor. Count/time truncation returns partial paths plus typed incomplete proof.
    private func freezeFinishedQueryResults() {
        guard terminalResult == nil,
              extractionTask == nil,
              normalizationTask == nil else { return }
        query.disableUpdates()
        let budget = SpotlightResultBudget.production
        let totalResultCount = query.resultCount
        extractionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let projection = await SpotlightBatchedPathExtractor.extract(
                totalResultCount: totalResultCount,
                budget: budget,
                pathAtIndex: { [query] index in
                    guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
                    return item.value(forAttribute: NSMetadataItemPathKey) as? String
                }
            )
            guard !Task.isCancelled else { return }
            self.completeExtraction(projection)
        }
    }

    private func completeExtraction(_ projection: SpotlightFrozenPathProjection) {
        guard terminalResult == nil else { return }
        extractionTask = nil
        query.stop()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        let frozenPaths = projection.paths
        let frozenFailure = projection.failure
        let task = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let normalized = SpotlightPathNormalizer.normalize(frozenPaths)
            guard !Task.isCancelled else { return }
            await self?.completeNormalization(paths: normalized, failure: frozenFailure)
        }
        normalizationTask = task
    }

    private func completeNormalization(
        paths: [String],
        failure: SpotlightProbeFailure?
    ) {
        normalizationTask = nil
        finish(with: SpotlightProbeResult(paths: paths, failure: failure))
    }

    private func finish(with result: SpotlightProbeResult) {
        guard terminalResult == nil else { return }
        terminalResult = result
        query.stop()
        extractionTask?.cancel()
        extractionTask = nil
        normalizationTask?.cancel()
        normalizationTask = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
            observer = nil
        }
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }
}

/// Noop 实现：所有查询返空。给单元测试当默认 stub，避免触发系统 mds。
public struct NoopSpotlightProbe: SpotlightProbing {
    public init() {}
    public func probeByBundleID(
        _ bundleID: String,
        timeout: TimeInterval
    ) async -> [String] { [] }
    public func probeByAppName(
        _ appName: String,
        timeout: TimeInterval
    ) async -> [String] { [] }
}
