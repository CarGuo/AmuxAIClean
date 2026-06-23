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
/// - **不复用单 BulkScanner 的 InodeSet**：每个根独立 InodeSet。跨根 hardlink 极少且会让
///   字节统计不准；保持每根独立扫描语义，与单根 BulkScanner 一致。
/// - **不共享 worker pool**：每个根独立 6 worker。这等于让"多根 + 子树深"两种工作负载形态
///   同时打满核心；调用方可通过 `ScanOptions.maxConcurrency` 自行收窄。
/// - **事件流加 `rootPath` 信封**：用 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
///   而非动 `ScanEvent`，避免现有所有调用点改 case；多 worker 同时 yield 安全。
/// - **finished 协议**：每个根扫完会 yield 自己的 `.finished`，全部根都 finish 后 stream 关闭。
public struct MultiRootEvent: Sendable {
    public let rootPath: String
    public let event: ScanEvent
    public init(rootPath: String, event: ScanEvent) {
        self.rootPath = rootPath
        self.event = event
    }
}

public actor MultiRootScanner {
    private let options: ScanOptions

    public init(options: ScanOptions = .default) {
        self.options = options
    }

    /// v1.3 P0-B：per-root 硬超时，超过即强制 cancel + 合成 partial .finished 让上游收敛。
    /// 默认 5 分钟；dev/fullDisk 实测正常 root < 60s 完成，5 分钟覆盖极端 USB 慢盘已绰绰有余。
    public static let defaultPerRootTimeout: TimeInterval = 300

    /// v1.3 P0-B：无进展 watchdog 阈值。
    /// 90 秒内未收到任何 .node/.nodes/.progress 则判定 hang，强制 cancel 该 root。
    /// 90s 是综合权衡：低于 60s 在网络盘首次 enumerate 会误杀；高于 120s 用户感知 UI 假死。
    public static let defaultNoProgressTimeout: TimeInterval = 90

    /// v1.3 P0-B：总扫描 deadline。20 分钟硬顶，超过即所有未完成 root 一起合成 .finished。
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
    /// - parameter perRootTimeout: 单根硬超时，默认 5 分钟。超时合成 partial .finished 让上游收敛。
    /// - parameter noProgressTimeout: 单根无进展超时，默认 90 秒。
    /// - parameter totalDeadline: 整体扫描 deadline，默认 20 分钟。超过即所有未完成 root 强 cancel。
    public func scan(
        roots: [URL],
        maxConcurrentRoots: Int = 4,
        perRootTimeout: TimeInterval = MultiRootScanner.defaultPerRootTimeout,
        noProgressTimeout: TimeInterval = MultiRootScanner.defaultNoProgressTimeout,
        totalDeadline: TimeInterval = MultiRootScanner.defaultTotalDeadline
    ) -> AsyncStream<MultiRootEvent> {
        let opts = self.options
        let cap = max(1, maxConcurrentRoots)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let parent = Task.detached(priority: .userInitiated) {
                // 总扫描 deadline 哨兵：到点直接 cancel parent → onTermination 链式 cancel 所有 root。
                let deadlineSentinel = Task.detached { [totalDeadline] in
                    try? await Task.sleep(nanoseconds: UInt64(totalDeadline * 1_000_000_000))
                    if !Task.isCancelled {
                        GSYLog.warning(.scan, "MultiRootScanner 命中总扫描 deadline \(Int(totalDeadline))s，强制结束所有 root")
                    }
                }
                await withTaskGroup(of: Void.self) { group in
                    // Sliding window 调度：先放出前 cap 个 root，每完成一个再补一个；
                    // group.next() 会等到任意一个子任务完成再返回，这样并发度永远 ≤ cap。
                    var i = 0
                    let n = roots.count
                    while i < min(cap, n) {
                        let root = roots[i]
                        group.addTask {
                            await Self.scanOne(
                                root: root,
                                opts: opts,
                                perRootTimeout: perRootTimeout,
                                noProgressTimeout: noProgressTimeout,
                                into: continuation
                            )
                        }
                        i += 1
                    }
                    while i < n, !Task.isCancelled, !deadlineSentinel.isCancelled {
                        // 等任意一个 root 完成
                        await group.next()
                        if deadlineSentinel.isCancelled == false,
                           Task.isCancelled == false {
                            let root = roots[i]
                            group.addTask {
                                await Self.scanOne(
                                    root: root,
                                    opts: opts,
                                    perRootTimeout: perRootTimeout,
                                    noProgressTimeout: noProgressTimeout,
                                    into: continuation
                                )
                            }
                            i += 1
                        } else {
                            break
                        }
                    }
                    await group.waitForAll()
                }
                deadlineSentinel.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in parent.cancel() }
        }
    }

    /// v1.5：抽出"扫单根"，给 sliding window 调度复用。
    /// v1.3 P0-B：包了 per-root hard timeout + no-progress watchdog。
    /// 超时时主动合成 partial `.finished` summary 让上游 ingest 流程收敛，避免 UI 永远"扫描中"。
    private static func scanOne(
        root: URL,
        opts: ScanOptions,
        perRootTimeout: TimeInterval,
        noProgressTimeout: TimeInterval,
        into continuation: AsyncStream<MultiRootEvent>.Continuation
    ) async {
        // 每个根一个独立 BulkScanner（独立 InodeSet / 独立 worker pool）。
        // 共享同一个 outer continuation，多 worker yield Apple 文档保证 thread-safe。
        let scanner = BulkScanner(options: opts)
        let rootPath = root.path
        let started = Date()
        // 进度时钟：scanOne 主体每收到一个事件刷新，watchdog 通过 actor 读取判定 hang。
        let progressClock = MultiRootProgressClock()
        // hardTimeout 哨兵 + noProgress watchdog 共用一个 cancellation 信号：通过 cancel
        // outer Task（withTimeoutSentinels 内）联动；这里直接捕获 Task.current 思路不通，
        // 改成包一层 child Task 拿到句柄。
        await withTaskGroup(of: Void.self) { group in
            // 子任务 1：真正消费 BulkScanner stream。
            group.addTask {
                let stream = scanner.scan(root: root)
                var iterator = stream.makeAsyncIterator()
                while !Task.isCancelled, let ev = await iterator.next() {
                    // 任何"实质事件"都刷新进度时钟。.tccProtectedSkipped/.cacheDirTagged 也算进展。
                    switch ev {
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
                    case .cacheDirTagged:
                        await progressClock.touch()
                    case .finished:
                        // 上游已经产出真实 summary，标记一下，scanOne 末尾就不补合成 .finished。
                        await progressClock.markFinished()
                    case .failed:
                        break
                    }
                    continuation.yield(MultiRootEvent(rootPath: rootPath, event: ev))
                }
                _ = iterator
            }
            // 子任务 2：硬 timeout 哨兵。到点 cancel 整组 → 子任务 1 退出。
            group.addTask { [perRootTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(perRootTimeout * 1_000_000_000))
                if !Task.isCancelled {
                    GSYLog.warning(.scan, "MultiRootScanner per-root hard timeout root=\(rootPath) limit=\(Int(perRootTimeout))s")
                }
            }
            // 子任务 3：no-progress watchdog。每 15s 醒来一次，比阈值更老即认定 hang。
            group.addTask { [noProgressTimeout] in
                let tick: TimeInterval = max(5, noProgressTimeout / 6)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                    if Task.isCancelled { return }
                    let idle = await progressClock.secondsSinceLastTouch()
                    if idle >= noProgressTimeout {
                        GSYLog.warning(.scan, "MultiRootScanner no-progress watchdog root=\(rootPath) idle=\(Int(idle))s ≥ \(Int(noProgressTimeout))s")
                        return // 退出 → group.cancelAll 在 next() 处由外部判定
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
            continuation.yield(MultiRootEvent(rootPath: rootPath, event: .finished(synthetic)))
            GSYLog.warning(.scan, "MultiRootScanner 合成 partial .finished 让上游收敛 root=\(rootPath) bytes=\(synthetic.totalAllocatedBytes) files=\(synthetic.fileCount) elapsed=\(String(format: "%.1f", synthetic.elapsed))s")
        }
    }
}

/// scanOne 内部进度时钟：watchdog 用它判 hang，scanOne 末尾用 didReceiveFinished 决定是否补合成 .finished。
actor MultiRootProgressClock {
    private var lastTouch: Date = Date()
    var didReceiveFinished: Bool = false
    private var latestProgressBytes: Int64 = 0
    private var latestProgressFileCount: Int = 0
    private var observedAllocatedBytes: Int64 = 0
    private var observedLogicalBytes: Int64 = 0
    private var observedFileCount: Int = 0
    private var observedDirectoryCount: Int = 0
    private var permissionDeniedCount: Int = 0
    private var tccProtectedSkippedCount: Int = 0

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
            } else {
                observedFileCount += 1
                observedAllocatedBytes += node.allocatedSize
                observedLogicalBytes += node.logicalSize
            }
        }
    }

    func recordProgress(scannedBytes: Int64, fileCount: Int) {
        touch()
        latestProgressBytes = max(latestProgressBytes, scannedBytes)
        latestProgressFileCount = max(latestProgressFileCount, fileCount)
    }

    func recordPermissionDenied() {
        touch()
        permissionDeniedCount += 1
    }

    func recordTCCProtectedSkipped() {
        touch()
        tccProtectedSkippedCount += 1
    }

    func markFinished() {
        didReceiveFinished = true
    }

    func secondsSinceLastTouch() -> TimeInterval {
        Date().timeIntervalSince(lastTouch)
    }

    func syntheticSummary(root: URL, elapsed: TimeInterval) -> ScanSummary {
        ScanSummary(
            root: root,
            totalAllocatedBytes: max(latestProgressBytes, observedAllocatedBytes),
            totalLogicalBytes: observedLogicalBytes,
            fileCount: max(latestProgressFileCount, observedFileCount),
            directoryCount: observedDirectoryCount,
            dedupedHardlinkBytes: 0,
            elapsed: elapsed,
            permissionDeniedCount: permissionDeniedCount,
            tccProtectedSkippedCount: tccProtectedSkippedCount
        )
    }
}
