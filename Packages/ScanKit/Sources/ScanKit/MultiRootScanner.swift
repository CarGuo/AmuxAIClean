import Foundation
import LogKit

/// v1.3：多根并行扫描入口。
///
/// 解决用户反馈：「为什么我点击一个目录扫描，看起来还是只有一个目录在动？」
/// 根因：[BulkScanner.scan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift)
/// 单根内部用 6 worker work-steal —— 子树并行真实存在，但 UI 顶层行只显示一个根目录的累计，
/// 视觉上被聚合到一行，给人"单线程串联"的错觉。
///
/// 真正的"多目录并行"应该在 **根级别** 也并行：M 个根 × 每个 6 worker = M*6 个真正并行的工作单元。
///
/// 使用：
/// ```swift
/// let scanner = MultiRootScanner(options: .default)
/// for await ev in scanner.scan(roots: [url1, url2, url3]) {
///     switch ev.event {
///     case .node(let node): ingest(rootPath: ev.rootPath, node: node)
///     case .finished(_): markDone(rootPath: ev.rootPath)
///     ...
///     }
/// }
/// ```
///
/// 设计要点：
/// - **事务级 allocation ledger**（v2026.07.17）：同一轮所有根共享文件 inode 身份账本，
///   因此跨根 hardlink 的物理/逻辑字节只计一次；目录访问账本仍按根独立，避免一个根吞掉
///   另一个根的枚举与完整性证据。并发扫描下由最先观察到该 inode 的根承载其字节，单根
///   归属不保证稳定，但所有根合计是权威物理占用，不能在 UI 端事后相减猜测。
/// - **不共享 worker pool**：每个根独立 6 worker。这等于让"多根 + 子树深"两种工作负载形态
///   同时打满核心；调用方可通过 `ScanOptions.maxConcurrency` 自行收窄。
/// - **事件流加 `rootPath` 信封**：用 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
///   而非动 `ScanEvent`，避免现有所有调用点改 case；多 worker 同时 yield 安全。
/// - **finished 协议**：每个根扫完会 yield 自己的 `.finished`，全部根都 finish 后 stream 关闭。
public struct MultiRootEvent: Sendable {
    public let rootPath: String
    public let event: ScanEvent
    /// Absolute wall-clock instant frozen by the producer immediately before yielding a root
    /// terminal. The consumer subtracts its own scan-session origin, so discovery, task hops,
    /// root normalization and sliding-window queueing cannot disappear between two unrelated
    /// relative clocks. `ScanSummary.elapsed` still only covers one admitted root.
    public let producerCompletedAt: Date?

    public init(
        rootPath: String,
        event: ScanEvent,
        producerCompletedAt: Date? = nil
    ) {
        self.rootPath = rootPath
        self.event = event
        self.producerCompletedAt = producerCompletedAt
    }
}

public actor MultiRootScanner {
    public struct ScanSession: Sendable {
        public let events: AsyncStream<MultiRootEvent>
        private let producer: Task<Void, Never>

        fileprivate init(events: AsyncStream<MultiRootEvent>, producer: Task<Void, Never>) {
            self.events = events
            self.producer = producer
        }

        public func cancel() { producer.cancel() }
        public func waitForTermination() async { await producer.value }
    }

    typealias RootScanOperation = @Sendable (
        _ root: URL,
        _ options: ScanOptions,
        _ perRootTimeout: TimeInterval,
        _ noProgressTimeout: TimeInterval,
        _ delivery: BulkScanner.EventDelivery,
        _ allocationLedger: InodeSet,
        _ continuation: AsyncStream<MultiRootEvent>.Continuation
    ) async -> Void

    private let options: ScanOptions
    private let rootScanOperation: RootScanOperation

    public init(options: ScanOptions = .default) {
        self.options = options
        self.rootScanOperation = Self.scanOne
    }

    init(options: ScanOptions = .default,
         rootScanOperation: @escaping RootScanOperation) {
        self.options = options
        self.rootScanOperation = rootScanOperation
    }

    /// v1.3 P0-B：per-root 协作式超时，超过即请求 cancel + 合成 partial .finished 让上游收敛。
    /// v2026.07.17 全链路复核：Swift 结构化取消无法抢占正在进行的同步内核 I/O，
    /// 因此不得将这条边界对外表述为“硬超时”；异常挂载点仍可能延迟最终收敛。
    /// 默认 5 分钟；dev/fullDisk 实测正常 root < 60s 完成，5 分钟覆盖极端 USB 慢盘已绰绰有余。
    public static let defaultPerRootTimeout: TimeInterval = 300

    /// v1.3 P0-B：无进展 watchdog 阈值。
    /// 90 秒内未收到任何 .node/.nodes/.progress 则判定 hang，强制 cancel 该 root。
    /// 90s 是综合权衡：低于 60s 在网络盘首次 enumerate 会误杀；高于 120s 用户感知 UI 假死。
    public static let defaultNoProgressTimeout: TimeInterval = 90

    /// v1.3 P0-B：总扫描协作式 deadline。超过即向所有未完成 root 传播取消。
    /// 来自用户反馈"20 分钟都还没结束"——任何场景都不应突破这条线。
    public static let defaultTotalDeadline: TimeInterval = 20 * 60

    /// 多根并行扫描。返回的 stream 在所有根都扫完后自动 finish；
    /// 调用方 cancel 上层 Task 即可级联 cancel 所有子扫描（onTermination 兜底）。
    ///
    /// - parameter roots: 全部待扫根目录（保序）。
    /// - parameter maxConcurrentRoots: 同一时间最多并行跱踪的 root 数；超过的 root 排队等。
    ///   默认 4。理由：每个 root 内部自带 [BulkScanner.workerCount](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 默认 6 worker，
    ///   4 × 6 = 24 个并发文件枚举已经接近 Apple Silicon SSD 的 IO 甜点上限；
    ///   再放大整个 APFS metadata layer 进入 lock-step 串行化，反而更慢。
    ///   v1.5 性能修复：dev scan discover 命中 30+ root 直接 fan out 时整机
    ///   IO 子系统拥塞，App 与 Finder/浏览器一起卡。Sliding window 是最小修改面治本方案。
    /// - parameter perRootTimeout: 单根协作式超时，默认 5 分钟。超时合成 partial .finished 让上游收敛。
    /// - parameter noProgressTimeout: 单根无进展超时，默认 90 秒。
    /// - parameter totalDeadline: 整体扫描协作式 deadline，默认 20 分钟。超过即向所有未完成 root 传播取消。
    public func scan(
        roots: [URL],
        maxConcurrentRoots: Int = 4,
        perRootTimeout: TimeInterval = MultiRootScanner.defaultPerRootTimeout,
        noProgressTimeout: TimeInterval = MultiRootScanner.defaultNoProgressTimeout,
        totalDeadline: TimeInterval = MultiRootScanner.defaultTotalDeadline,
        delivery: BulkScanner.EventDelivery = .complete
    ) -> AsyncStream<MultiRootEvent> {
        scanSession(
            roots: roots,
            maxConcurrentRoots: maxConcurrentRoots,
            perRootTimeout: perRootTimeout,
            noProgressTimeout: noProgressTimeout,
            totalDeadline: totalDeadline,
            delivery: delivery
        ).events
    }

    public func scanSession(
        roots: [URL],
        maxConcurrentRoots: Int = 4,
        perRootTimeout: TimeInterval = MultiRootScanner.defaultPerRootTimeout,
        noProgressTimeout: TimeInterval = MultiRootScanner.defaultNoProgressTimeout,
        totalDeadline: TimeInterval = MultiRootScanner.defaultTotalDeadline,
        delivery: BulkScanner.EventDelivery = .complete
    ) -> ScanSession {
        let opts = self.options
        let rootScanOperation = self.rootScanOperation
        // v2026.07.17 public timeout hardening: TimeInterval accepts NaN, infinities and
        // negative/overflowing values. Converting those directly to UInt64 traps before the
        // scanner can emit a typed terminal state. Normalize once at the API boundary: invalid
        // or non-positive values mean an immediate cooperative timeout; +infinity saturates.
        let normalizedPerRootTimeout = Self.normalizedTimeoutSeconds(perRootTimeout)
        let normalizedNoProgressTimeout = Self.normalizedTimeoutSeconds(noProgressTimeout)
        let totalDeadlineNanoseconds = Self.normalizedTimeoutNanoseconds(totalDeadline)
        let normalizedTotalDeadline = Double(totalDeadlineNanoseconds) / 1_000_000_000
        // One ledger belongs to exactly one returned stream/transaction. It must not live on the
        // actor instance: callers may start a later scan using the same MultiRootScanner while an
        // earlier stream is still draining, and those transactions must never deduplicate each
        // other's files.
        let allocationLedger = InodeSet()
        let cap = max(1, maxConcurrentRoots)
        let streamPair = AsyncStream<MultiRootEvent>.makeStream(bufferingPolicy: .unbounded)
        let continuation = streamPair.continuation
        let parent = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: ParentRaceResult.self) { race in
                    // 结构化的扫描 child：deadline child 完成时 cancelAll 会真正向这里及
                    // 其内部 root task group 传播取消，不依赖读取另一个 Task 的状态。
                    race.addTask {
                        guard !Task.isCancelled else { return .scansFinished }
                        await withTaskGroup(of: Void.self) { group in
                            // Sliding window 调度：先放出前 cap 个 root，每完成一个再补一个；
                            // group.next() 会等到任意一个子任务完成再返回，这样并发度永远 ≤ cap。
                            var i = 0
                            let n = roots.count
                            while i < min(cap, n), !Task.isCancelled {
                                let root = roots[i]
                                group.addTask {
                                    await rootScanOperation(
                                        root,
                                        opts,
                                        normalizedPerRootTimeout,
                                        normalizedNoProgressTimeout,
                                        delivery,
                                        allocationLedger,
                                        continuation
                                    )
                                }
                                i += 1
                            }
                            while i < n, !Task.isCancelled {
                                await group.next()
                                guard !Task.isCancelled else { break }
                                let root = roots[i]
                                group.addTask {
                                    await rootScanOperation(
                                        root,
                                        opts,
                                        normalizedPerRootTimeout,
                                        normalizedNoProgressTimeout,
                                        delivery,
                                        allocationLedger,
                                        continuation
                                    )
                                }
                                i += 1
                            }
                            await group.waitForAll()
                        }
                        return .scansFinished
                    }

                    race.addTask {
                        do {
                            try await Task.sleep(
                                nanoseconds: totalDeadlineNanoseconds
                            )
                            return .deadlineReached
                        } catch is CancellationError {
                            return .scansFinished
                        } catch {
                            GSYLog.error(.scan, "MultiRootScanner deadline sleep 失败: \(error)")
                            return .deadlineReached
                        }
                    }

                    if let first = await race.next(), first == .deadlineReached {
                        GSYLog.warning(.scan, "MultiRootScanner 命中总扫描 deadline \(Self.timeoutLogLabel(normalizedTotalDeadline))，请求取消所有 root")
                    }
                    race.cancelAll()
                    await race.waitForAll()
                }
                continuation.finish()
        }
        continuation.onTermination = { _ in parent.cancel() }
        return ScanSession(events: streamPair.stream, producer: parent)
    }

    private enum ParentRaceResult: Sendable, Equatable {
        case scansFinished
        case deadlineReached
    }

    /// v1.5：抽出"扫单根"，给 sliding window 调度复用。
    /// v1.3 P0-B：包了 per-root 协作式 timeout + no-progress watchdog。
    /// 超时时主动合成 partial `.finished` summary 让上游 ingest 流程收敛，避免 UI 永远"扫描中"。
    private static func scanOne(
        root: URL,
        opts: ScanOptions,
        perRootTimeout: TimeInterval,
        noProgressTimeout: TimeInterval,
        delivery: BulkScanner.EventDelivery,
        allocationLedger: InodeSet,
        into continuation: AsyncStream<MultiRootEvent>.Continuation
    ) async {
        // 每个根一个独立 BulkScanner/worker pool，但文件物理分配身份由本轮所有根共享；
        // BulkScanner 内部的 DirInodeSet 仍属于单根，保证每根完整性证据独立收敛。
        // 共享同一个 outer continuation，多 worker yield Apple 文档保证 thread-safe。
        let scanner = BulkScanner(options: opts)
        let rootPath = root.path
        let started = Date()
        // 进度时钟：scanOne 主体每收到一个事件刷新，watchdog 通过 actor 读取判定 hang。
        let progressClock = MultiRootProgressClock()
        // timeout 哨兵 + noProgress watchdog 共用一个 cancellation 信号：通过 cancel
        // outer Task（withTimeoutSentinels 内）联动；这里直接捕获 Task.current 思路不通，
        // 改成包一层 child Task 拿到句柄。
        await withTaskGroup(of: Void.self) { group in
            // 子任务 1：真正消费 BulkScanner stream。
            group.addTask {
                let session = scanner.scanSession(
                    root: root,
                    delivery: delivery,
                    pathNamespace: nil,
                    topLevelProjectionRootPath: nil,
                    allocationLedger: allocationLedger
                )
                await withTaskCancellationHandler {
                    var iterator = session.events.makeAsyncIterator()
                    while !Task.isCancelled, let ev = await iterator.next() {
                        // 任何"实质事件"都刷新进度时钟。.tccProtectedSkipped/.cacheDirTagged 也算进展。
                        switch ev {
                        case .heartbeat:
                            await progressClock.touch()
                        case .node(let node):
                            await progressClock.record(node: node)
                        case .nodes(let nodes):
                            await progressClock.record(nodes: nodes)
                        case .progress(let scannedBytes, let fileCount):
                            await progressClock.recordProgress(scannedBytes: scannedBytes, fileCount: fileCount)
                        case .permissionDenied:
                            await progressClock.recordPermissionDenied()
                        case .tccProtectedSkipped:
                            await progressClock.recordTCCProtectedSkipped()
                        case .incomplete(let issue):
                            await progressClock.recordIncomplete(issue)
                        case .cacheDirTagged:
                            await progressClock.touch()
                        case .finished(let summary):
                            // 上游已经产出真实 summary，标记一下，scanOne 末尾就不补合成 .finished。
                            await progressClock.recordProgress(
                                scannedBytes: summary.totalAllocatedBytes,
                                fileCount: summary.fileCount,
                                logicalBytes: summary.totalLogicalBytes,
                                directoryCount: summary.directoryCount
                            )
                            await progressClock.markFinished()
                        case .failed:
                            break
                        }
                        // Only a root terminal contributes to the producer clock.
                        // Reading Date for every node/batch would put telemetry back on the hot
                        // path that this metric exists to diagnose.
                        let producerCompletedAt: Date?
                        if case .finished = ev {
                            producerCompletedAt = Date()
                        } else {
                            producerCompletedAt = nil
                        }
                        continuation.yield(MultiRootEvent(
                            rootPath: rootPath,
                            event: ev,
                            producerCompletedAt: producerCompletedAt
                        ))
                    }
                } onCancel: {
                    session.cancel()
                }
                // The root does not release its sliding-window permit until the detached
                // filesystem producer has actually stopped.
                await session.waitForTermination()
            }
            // 子任务 2：协作式 timeout 哨兵。到点 cancel 整组 → 子任务 1 在下一个可取消边界退出。
            group.addTask { [perRootTimeout] in
                try? await Task.sleep(
                    nanoseconds: Self.normalizedTimeoutNanoseconds(perRootTimeout)
                )
                if !Task.isCancelled {
                    GSYLog.warning(.scan, "MultiRootScanner per-root timeout requested cancellation root=\(rootPath) limit=\(Self.timeoutLogLabel(perRootTimeout))")
                }
            }
            // 子任务 3：no-progress watchdog。summaryOnly 的公开合同明确不发布 progress/
            // heartbeat；对它启用 idle watchdog 会把“正常但安静的长扫描”误杀为 hang。
            // summaryOnly 仍受 perRootTimeout/totalDeadline 协作式上限保护，其它 delivery 都有
            // node/progress/heartbeat 可作为 liveness 证据。
            if Self.usesNoProgressWatchdog(delivery: delivery) {
                group.addTask { [noProgressTimeout] in
                    let threshold = Self.normalizedTimeoutSeconds(noProgressTimeout)
                    let tickNanoseconds = Self.watchdogTickNanoseconds(
                        thresholdSeconds: threshold
                    )
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: tickNanoseconds)
                        if Task.isCancelled { return }
                        let idle = await progressClock.secondsSinceLastTouch()
                        if idle >= threshold {
                            GSYLog.warning(.scan, "MultiRootScanner no-progress watchdog root=\(rootPath) idle=\(Self.timeoutLogLabel(idle)) ≥ \(Self.timeoutLogLabel(threshold))")
                            return // 退出 → group.cancelAll 在 next() 处由外部判定
                        }
                    }
                }
            }
            // 任一子任务完成（消费 done / hardTimeout 到 / watchdog 判 hang）即 cancel 其余。
            _ = await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
        // 兜底：若上面任一超时触发，BulkScanner 那边可能还没机会 yield .finished。
        // 这里合成一条 partial .finished，让上层 ScanCoordinator 的 finished 计数能加一，整体收敛。
        // 通过 progressClock.didReceiveFinished 标志判断是否需要补。
        if await progressClock.didReceiveFinished == false {
            let synthetic = await progressClock.syntheticSummary(root: root, elapsed: Date().timeIntervalSince(started))
            // v2026.07.17 terminal progress contract: a timeout/watchdog summary is authoritative
            // for the observed lower bound just like BulkScanner's real terminal summary. Emit the
            // final absolute sample first for every progress-capable delivery; summaryOnly keeps
            // its intentionally quiet event contract.
            if delivery.includesProgress {
                continuation.yield(MultiRootEvent(
                    rootPath: rootPath,
                    event: .progress(
                        scannedBytes: synthetic.totalAllocatedBytes,
                        fileCount: synthetic.fileCount
                    )
                ))
            }
            continuation.yield(MultiRootEvent(
                rootPath: rootPath,
                event: .finished(synthetic),
                producerCompletedAt: Date()
            ))
            GSYLog.warning(.scan, "MultiRootScanner 合成 partial .finished 让上游收敛 root=\(rootPath) bytes=\(synthetic.totalAllocatedBytes) files=\(synthetic.fileCount) elapsed=\(String(format: "%.1f", synthetic.elapsed))s")
        }
    }

    static func usesNoProgressWatchdog(delivery: BulkScanner.EventDelivery) -> Bool {
        delivery != .summaryOnly
    }

    /// 将公开的 `TimeInterval` 收敛为 Task.sleep 可安全消费的纳秒值。
    /// - NaN、负数、-infinity、0：立即到期（0ns）。
    /// - +infinity 或超出 UInt64 纳秒上限：饱和到 UInt64.max。
    static func normalizedTimeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        guard seconds.isFinite else { return UInt64.max }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(nanoseconds)
    }

    static func normalizedTimeoutSeconds(_ seconds: TimeInterval) -> TimeInterval {
        Double(normalizedTimeoutNanoseconds(seconds)) / 1_000_000_000
    }

    private static func watchdogTickNanoseconds(
        thresholdSeconds: TimeInterval
    ) -> UInt64 {
        let threshold = normalizedTimeoutNanoseconds(thresholdSeconds)
        guard threshold > 0 else { return 0 }
        let fiveSeconds: UInt64 = 5_000_000_000
        return max(fiveSeconds, threshold / 6)
    }

    private static func timeoutLogLabel(_ seconds: TimeInterval) -> String {
        String(format: "%.3fs", normalizedTimeoutSeconds(seconds))
    }
}

/// scanOne 内部进度时钟：watchdog 用它判 hang，scanOne 末尾用 didReceiveFinished 决定是否补合成 .finished。
actor MultiRootProgressClock {
    private var lastTouch: Date = Date()
    var didReceiveFinished: Bool = false
    private var latestProgressBytes: Int64 = 0
    private var latestProgressLogicalBytes: Int64 = 0
    private var latestProgressFileCount: Int = 0
    private var latestProgressDirectoryCount: Int = 0
    private var observedAllocatedBytes: Int64 = 0
    private var observedLogicalBytes: Int64 = 0
    private var observedFileCount: Int = 0
    private var observedDirectoryCount: Int = 0
    private var permissionDeniedCount: Int = 0
    private var tccProtectedSkippedCount: Int = 0
    private var incompleteIssues: Set<ScanIncompleteIssue> = []

    func touch() {
        lastTouch = Date()
    }

    func record(node: FSNode) {
        record(nodes: [node])
    }

    func record(nodes: [FSNode]) {
        touch()
        for node in nodes {
            if node.isDirectory {
                observedDirectoryCount += 1
            } else if !node.isSymlink {
                observedFileCount += 1
                observedAllocatedBytes += node.allocatedSize
                observedLogicalBytes += node.logicalSize
            }
        }
    }

    func recordProgress(
        scannedBytes: Int64,
        fileCount: Int,
        logicalBytes: Int64 = 0,
        directoryCount: Int = 0
    ) {
        touch()
        latestProgressBytes = max(latestProgressBytes, scannedBytes)
        latestProgressLogicalBytes = max(latestProgressLogicalBytes, logicalBytes)
        latestProgressFileCount = max(latestProgressFileCount, fileCount)
        latestProgressDirectoryCount = max(latestProgressDirectoryCount, directoryCount)
    }

    func recordPermissionDenied() {
        touch()
        permissionDeniedCount += 1
    }

    func recordTCCProtectedSkipped() {
        touch()
        tccProtectedSkippedCount += 1
    }

    func recordIncomplete(_ issue: ScanIncompleteIssue) {
        touch()
        incompleteIssues.insert(issue)
    }

    func markFinished() {
        didReceiveFinished = true
    }

    func secondsSinceLastTouch() -> TimeInterval {
        Date().timeIntervalSince(lastTouch)
    }

    func syntheticSummary(root: URL, elapsed: TimeInterval) -> ScanSummary {
        let sortedIssues = incompleteIssues.sorted {
            if $0.path == $1.path { return $0.reason.rawValue < $1.reason.rawValue }
            return $0.path < $1.path
        }
        return ScanSummary(
            root: root,
            totalAllocatedBytes: max(latestProgressBytes, observedAllocatedBytes),
            totalLogicalBytes: max(latestProgressLogicalBytes, observedLogicalBytes),
            fileCount: max(latestProgressFileCount, observedFileCount),
            directoryCount: max(latestProgressDirectoryCount, observedDirectoryCount),
            dedupedHardlinkBytes: 0,
            elapsed: elapsed,
            permissionDeniedCount: permissionDeniedCount,
            tccProtectedSkippedCount: tccProtectedSkippedCount,
            completionStatus: .partial,
            incompleteIssues: sortedIssues
        )
    }
}
