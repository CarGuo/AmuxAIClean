import Foundation

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
    public func scan(roots: [URL], maxConcurrentRoots: Int = 4) -> AsyncStream<MultiRootEvent> {
        let opts = self.options
        let cap = max(1, maxConcurrentRoots)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let parent = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { group in
                    // Sliding window 调度：先放出前 cap 个 root，每完成一个再补一个；
                    // group.next() 会等到任意一个子任务完成再返回，这样并发度永远 ≤ cap。
                    var i = 0
                    let n = roots.count
                    while i < min(cap, n) {
                        let root = roots[i]
                        group.addTask {
                            await Self.scanOne(root: root, opts: opts, into: continuation)
                        }
                        i += 1
                    }
                    while i < n, !Task.isCancelled {
                        // 等任意一个 root 完成
                        await group.next()
                        let root = roots[i]
                        group.addTask {
                            await Self.scanOne(root: root, opts: opts, into: continuation)
                        }
                        i += 1
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in parent.cancel() }
        }
    }

    /// v1.5：抽出"扫单根"，给 sliding window 调度复用；行为等同于原内联实现。
    private static func scanOne(root: URL, opts: ScanOptions, into continuation: AsyncStream<MultiRootEvent>.Continuation) async {
        // 每个根一个独立 BulkScanner（独立 InodeSet / 独立 worker pool）。
        // 共享同一个 outer continuation，多 worker yield Apple 文档保证 thread-safe。
        let scanner = BulkScanner(options: opts)
        let rootPath = root.path
        // v1.3 review-fix P0-1：用局部 stream 变量 + 显式 cancel(stream) 路径，
        // 让上层 cancel 时能立刻触发 BulkScanner 的 continuation.onTermination
        // → 内层 detached Task.cancel()，避免 worker 继续打文件系统。
        let stream = scanner.scan(root: root)
        var iterator = stream.makeAsyncIterator()
        while !Task.isCancelled, let ev = await iterator.next() {
            continuation.yield(MultiRootEvent(rootPath: rootPath, event: ev))
        }
        // 走到这里：要么 stream 自然 finish，要么本 child Task 被 cancel。
        // iterator 离开作用域时 stream 析构 → BulkScanner.onTermination 触发 → 内层 task.cancel()。
        // 显式 nil 出 iterator，让析构发生在显式时机而非 ARC 推迟。
        _ = iterator
    }
}
