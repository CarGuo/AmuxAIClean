import Foundation
import Darwin
import LogKit

/// 基于 `getattrlistbulk(2)` 的高性能扫描器（v1.0：多 worker 并行下钻）。
///
/// 比 `FileManager.enumerator` 快 3–8 倍的核心原因：
/// 1. **批量** —— 一次系统调用返回多个 entry 的全部 metadata，省掉 N 次 `lstat`
/// 2. **零拷贝** —— attribute buffer 直接由内核填充，Swift 这边按偏移解析
/// 3. **无 URL 创建** —— 拿到 C 字符串后才在需要时构造 URL
///
/// v1.0 起再叠一层 **多 worker 并行**（参考 Pearcleaner v5 / DaisyDisk）：
/// - 一个 actor `DirQueue` 充当 work-stealing 队列
/// - N 个 `Task.detached` worker 各自从 queue 取目录、`getattrlistbulk` 后把发现的
///   子目录回推到 queue
/// - `inFlight` 计数保证"队列空 + 没人在跑"才退出（经典 multi-consumer 饥饿问题解法）
/// - SSD 上 N=4~6 是甜点，N>6 IO 负收益（OmniDS 实测同款），cap 在 `maxConcurrency`
///
/// 并发安全清单（业界踩过的坑都列在这）：
/// 1. **InodeSet** 已经是 actor —— 多 worker 并发 insertIfFirstSeen 安全
/// 2. **counters**（fileCount/totalAllocated 等）放进 actor `Stats` 集中累计
/// 3. **AsyncStream.continuation.yield** Apple 文档保证 thread-safe，多 worker 直 yield
/// 4. **跨卷停下钻**：`staySingleVolume=true` 时新目录的 dev_t != root.dev 就不入队
/// 5. **取消传播**：每个 worker 自检 `Task.isCancelled`
/// 6. **死锁 / 饥饿**：DirQueue.popOrFinish() 在 inFlight==0 && stack.isEmpty 时返回
///    `.done`，所有 worker 同时收到才退出
/// 7. **目录回环防护**（v1.3 P0-A）：`DirInodeSet` 按 (dev,ino) 拦截重复目录入队，
///    覆盖 APFS firmlink、dir hardlink、pnpm symlink-to-dir 三类陷阱；
///    同时严格消费 `options.followSymlinks` —— 默认 false 时 symlink 指向的目录绝不下钻，
///    彻底切断 `~/Library/Mobile Documents/.../node_modules/.bin` 类回环导致的 Stream 永不 finish。
///
/// 失败回退：如果根目录无法 `open(O_RDONLY)`（典型于 TCC / Full Disk Access），
/// 调用方应回退到 `Scanner` 的 FileManager 路径。
public actor BulkScanner {
    /// Controls whether a consumer needs the full incremental tree or only capacity and
    /// completeness evidence.
    ///
    /// **v2026.07.16 root-cause fix:** Workflow cards used to subscribe to the complete
    /// stream and discard every node on the UI-owned task. A wide developer directory could
    /// therefore fill the unbounded lossless stream with hundreds of thousands of DTOs even
    /// though the card only needed the terminal summary. Summary-only delivery keeps typed
    /// incomplete/failed/finished events, while workers do not allocate or publish node,
    /// progress, or cache-tag events. Existing tree consumers retain the exact default
    /// contract through `.complete`.
    public enum EventDelivery: Sendable, Equatable {
        case complete
        case summaryOnly
        /// v2026.07.17 Workflow long-task contract: retain summary-only allocation/completeness
        /// memory behavior while publishing the existing throttled absolute byte/file progress.
        /// No node/cache DTO is allocated, so visibility does not reintroduce the old stream
        /// amplification regression.
        case summaryWithProgress
        /// 在 ScanKit worker 侧按扫描根一级子项聚合，终态通过
        /// `ScanSummary.projection` 一次性交付；扫描期间只发送节流后的绝对进度。
        case topLevel
        /// 在 ScanKit worker 侧过滤并保留固定上限的最大文件。`minimumAllocatedBytes <= 0`
        /// 表示只统计、不收集候选，保持 Large Files 旧合同。
        case largeFiles(minimumAllocatedBytes: Int64, maximumResults: Int)
        /// v2026.07.17 Duplicate 性能/安全回归根治：完整 node stream 会先在
        /// unbounded AsyncStream 堆积所有文件，而 Duplicate 最终只保留达到逻辑大小阈值的
        /// 普通文件。该模式在 worker 侧无损过滤，候选与 typed completeness 通过
        /// 同一个终态 summary 交付，不再把数百万 DTO 排队给消费者。
        case fileCandidates(minimumLogicalBytes: Int64)

        fileprivate var includesIncrementalNodes: Bool {
            self == .complete
        }

        var includesProgress: Bool {
            self != .summaryOnly
        }

        fileprivate var collectsTopLevelProjection: Bool {
            self == .topLevel
        }

        fileprivate var largeFilePolicy: (minimumBytes: Int64, maximumResults: Int)? {
            guard case .largeFiles(let minimumBytes, let maximumResults) = self else {
                return nil
            }
            return (max(0, minimumBytes), max(0, maximumResults))
        }

        fileprivate var fileCandidateMinimumLogicalBytes: Int64? {
            guard case .fileCandidates(let minimumBytes) = self else { return nil }
            return max(0, minimumBytes)
        }
    }

    /// Maximum number of entries carried by one `.nodes` event.
    ///
    /// The consumer currently ingests each batch on MainActor. Keeping this
    /// bound in ScanKit prevents a single very wide directory from becoming a
    /// tens-of-thousands-node main-thread transaction.
    public static let nodeBatchLimit = 256

    private let options: ScanOptions

    public init(options: ScanOptions = .default) {
        self.options = options
    }

    public nonisolated func scan(
        root: URL,
        delivery: EventDelivery = .complete,
        topLevelPathMappings: [ScanPathPrefixMapping] = [],
        topLevelProjectionRootPath: String? = nil
    ) -> AsyncStream<ScanEvent> {
        scan(
            root: root,
            delivery: delivery,
            topLevelPathMappings: topLevelPathMappings,
            topLevelProjectionRootPath: topLevelProjectionRootPath,
            allocationLedger: InodeSet()
        )
    }

    /// v2026.07.17 multi-root allocation contract: the public single-root entry always owns a
    /// fresh inode ledger, preserving concurrent/reused `BulkScanner` isolation. MultiRootScanner
    /// alone calls this module-internal overload with one transaction-scoped ledger so hardlinks
    /// crossing otherwise independent roots contribute physical bytes exactly once globally.
    /// Directory traversal identities remain per-root; sharing them would incorrectly suppress a
    /// root's enumeration and its scoped completeness evidence.
    nonisolated func scan(
        root: URL,
        delivery: EventDelivery,
        topLevelPathMappings: [ScanPathPrefixMapping],
        topLevelProjectionRootPath: String?,
        allocationLedger: InodeSet
    ) -> AsyncStream<ScanEvent> {
        // v1.3 P0 修复：原 `.bufferingNewest(8192)` 在 195k+ 文件场景会静默丢事件
        //（消费者主线程慢于 worker yield 速度时，最旧的 .node 事件被 AsyncStream 主动丢弃，
        // 直接导致 Finder 18.86 GB / 195,979 items → 应用 552.6 MB / 1,209 items 的灾难性少算）。
        // 改为 .unbounded：worker 永远可以 yield，因此不会静默丢事件。AsyncStream 本身不提供
        // 背压；下方 `nodeBatchLimit` 只限制单事件大小，整体缓冲上限仍需另行设计无损握手机制。
        // 去重身份属于一次 scan transaction，不能挂在 BulkScanner 实例上再 reset：
        // `scan` 是 nonisolated，同一实例可能并发产生两个 stream；共享+reset 会让两轮互相
        // 清空或吞掉 inode。每轮独立集合同时解决复用污染与并发数据竞争。
        let inodeSet = allocationLedger
        let dirInodeSet = DirInodeSet()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let opts = options
            let inodes = inodeSet
            let dirInodes = dirInodeSet
            // 最长前缀优先，避免 `/System/Volumes/Data` 抢先覆盖更具体的
            // `/System/Volumes/Data/private/var`。排序只做一次，不进入 entry hot path。
            let projectionMappings = topLevelPathMappings.sorted {
                $0.sourcePrefix.count > $1.sourcePrefix.count
            }
            let task = Task.detached(priority: .userInitiated) {
                let start = Date()
                // v2026.07.16：统计与投影共用一个 actor/一次目录 merge。独立 projection
                // actor 会让 60 万目录额外产生 60 万次串行 hop，反过来拖慢 producer。
                let stats = ScanStats(delivery: delivery)
                let queue = DirQueue()
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                // v1.1：根目录本身就是 TCC 雷区时直接退出（防御性，正常 UI 不会传入）
                if opts.respectTCCSkipList && TCCSkipList.shouldSkip(root.path) {
                    GSYLog.notice(.scan, "scan 根目录命中 TCC skip-list path=\(root.path)")
                    let issue = ScanIncompleteIssue(
                        path: root.path,
                        reason: .tccProtectedSkipped
                    )
                    continuation.yield(.tccProtectedSkipped(path: root.path))
                    continuation.yield(.incomplete(issue))
                    let summary = ScanSummary(
                        root: root,
                        totalAllocatedBytes: 0, totalLogicalBytes: 0,
                        fileCount: 0, directoryCount: 0,
                        dedupedHardlinkBytes: 0,
                        elapsed: Date().timeIntervalSince(start),
                        permissionDeniedCount: 0,
                        tccProtectedSkippedCount: 1,
                        incompleteIssues: [issue]
                    )
                    BulkScanner.publishTerminalSummary(
                        summary,
                        delivery: delivery,
                        continuation: continuation
                    )
                    continuation.finish()
                    return
                }
                // v2026.07.17 directory-identity closure: a pathname is not a directory proof.
                // Resolve the root once with lstat; `followSymlinks=false` rejects a symlink root,
                // while the explicit true branch freezes the final target identity before any
                // worker can open it. Every queued child carries the same typed proof below.
                let rootResolution = BulkDirectoryWorkResolver.resolveRoot(
                    path: root.path,
                    followSymlinks: opts.followSymlinks,
                    shouldCancel: { Task.isCancelled }
                )
                let rootWork: BulkDirectoryWork
                switch rootResolution {
                case .resolved(let work):
                    rootWork = work
                case .cancelled:
                    continuation.finish()
                    return
                case .notDirectory:
                    // Preserve the established public contract for a non-directory root:
                    // the descriptor can exist but cannot be enumerated as a directory.
                    let issue = ScanFailureClassifier.issue(
                        path: root.path,
                        stage: .enumerate,
                        posixErrorCode: ENOTDIR
                    )
                    await BulkScanner.publishIncomplete(
                        issue,
                        stats: stats,
                        continuation: continuation
                    )
                    continuation.yield(.failed(.cannotEnumerate(
                        path: root.path,
                        stage: .enumerate,
                        posixErrorCode: ENOTDIR
                    )))
                    let failedSnapshot = await stats.snapshot()
                    BulkScanner.publishTerminalSummary(ScanSummary(
                        root: root,
                        totalAllocatedBytes: 0,
                        totalLogicalBytes: 0,
                        fileCount: 0,
                        directoryCount: 0,
                        dedupedHardlinkBytes: 0,
                        elapsed: Date().timeIntervalSince(start),
                        permissionDeniedCount: failedSnapshot.permissionDenied,
                        tccProtectedSkippedCount: failedSnapshot.tccProtectedSkipped,
                        incompleteIssues: failedSnapshot.incompleteIssues,
                        projection: failedSnapshot.projection
                    ), delivery: delivery, continuation: continuation)
                    continuation.finish()
                    return
                case .failed(let errorCode):
                    // v2026.07.17 compatibility boundary: a root symlink rejected by the
                    // no-follow policy is metadata/identity evidence. Ordinary lookup failures
                    // keep the historical `.open` stage consumed by permission and retry UI.
                    let stage: ScanIssueStage = errorCode == ELOOP ? .metadata : .open
                    let issue = ScanFailureClassifier.issue(
                        path: root.path,
                        stage: stage,
                        posixErrorCode: errorCode
                    )
                    await BulkScanner.publishIncomplete(
                        issue,
                        stats: stats,
                        continuation: continuation
                    )
                    if issue.reason != .permissionDenied {
                        continuation.yield(.failed(.cannotEnumerate(
                            path: root.path,
                            stage: stage,
                            posixErrorCode: errorCode
                        )))
                    }
                    let failedSnapshot = await stats.snapshot()
                    BulkScanner.publishTerminalSummary(ScanSummary(
                        root: root,
                        totalAllocatedBytes: failedSnapshot.totalAllocated,
                        totalLogicalBytes: failedSnapshot.totalLogical,
                        fileCount: failedSnapshot.fileCount,
                        directoryCount: failedSnapshot.dirCount,
                        dedupedHardlinkBytes: failedSnapshot.dedupedBytes,
                        elapsed: Date().timeIntervalSince(start),
                        permissionDeniedCount: failedSnapshot.permissionDenied,
                        tccProtectedSkippedCount: failedSnapshot.tccProtectedSkipped,
                        incompleteIssues: failedSnapshot.incompleteIssues,
                        projection: failedSnapshot.projection
                    ), delivery: delivery, continuation: continuation)
                    continuation.finish()
                    return
                }
                _ = dirInodes.insertIfFirstSeen(
                    device: rootWork.identity.device,
                    inode: rootWork.identity.inode
                )
                await queue.push(rootWork)

                // 根卷身份必须来自实际将要枚举的目录对象；对显式允许的
                // symlink root，这是已冻结的 target dev，不是链接 inode 自身的 dev。
                let rootDev = opts.staySingleVolume ? rootWork.identity.device : 0

                // v1.3：mediaAware → 按介质类型自适应 worker 数。
                // SSD 提到 8、HDD 压到 2、网络盘压到 1；探测失败回退 actualConcurrency。
                // 关掉 mediaAware（如单测里）则保持 actualConcurrency 不变。
                let workerCount: Int
                if opts.mediaAware {
                    let media = MediaProbe.probe(path: root.path)
                    workerCount = MediaProbe.recommendedWorkerCount(
                        for: media,
                        fallback: opts.actualConcurrency,
                        maxCap: opts.maxConcurrency
                    )
                } else {
                    workerCount = opts.actualConcurrency
                }
                GSYLog.info(.scan, "scan 启动 root=\(root.path) workerCount=\(workerCount) staySingleVolume=\(opts.staySingleVolume)")
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount {
                        group.addTask {
                            await BulkScanner.workerLoop(
                                rootPath: root.path,
                                queue: queue,
                                stats: stats,
                                inodes: inodes,
                                dirInodes: dirInodes,
                                options: opts,
                                rootDev: rootDev,
                                continuation: continuation,
                                delivery: delivery,
                                topLevelPathMappings: projectionMappings,
                                topLevelProjectionRootPath: topLevelProjectionRootPath
                            )
                        }
                    }
                }

                // 取消是独立终态：consumer 已明确不要本轮结果，不得再伪造 partial issue
                // 或 finished summary。MultiRootScanner 若需要阶段性展示，会在它自己的
                // timeout/watchdog 边界合成 `.partial` summary。
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                let s = await stats.snapshot()
                let summary = ScanSummary(
                    root: root,
                    totalAllocatedBytes: s.totalAllocated,
                    totalLogicalBytes: s.totalLogical,
                    fileCount: s.fileCount,
                    directoryCount: s.dirCount,
                    dedupedHardlinkBytes: s.dedupedBytes,
                    elapsed: Date().timeIntervalSince(start),
                    permissionDeniedCount: s.permissionDenied,
                    tccProtectedSkippedCount: s.tccProtectedSkipped,
                    incompleteIssues: s.incompleteIssues,
                    projection: s.projection
                )
                GSYLog.info(.scan, "scan 完成 root=\(root.path) files=\(summary.fileCount) dirs=\(summary.directoryCount) bytes=\(summary.totalAllocatedBytes) elapsed=\(String(format: "%.2f", summary.elapsed))s permissionDenied=\(summary.permissionDeniedCount) tccSkipped=\(summary.tccProtectedSkippedCount)")
                BulkScanner.publishTerminalSummary(
                    summary,
                    delivery: delivery,
                    continuation: continuation
                )
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// v2026.07.17 progress-terminal contract: throttled worker updates may omit the final
    /// merge when it lands inside the 100 ms window. Every delivery mode that promises progress
    /// therefore publishes one authoritative absolute sample immediately before `.finished`.
    /// This is a single bounded event and does not restore incremental node delivery.
    private nonisolated static func publishTerminalSummary(
        _ summary: ScanSummary,
        delivery: EventDelivery,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) {
        if delivery.includesProgress {
            continuation.yield(.progress(
                scannedBytes: summary.totalAllocatedBytes,
                fileCount: summary.fileCount
            ))
        }
        continuation.yield(.finished(summary))
    }

    /// 单个 worker 的循环：popOrFinish → enumerate → 把子目录推回 queue → 直到 .done。
    /// `nonisolated static` 是为了 worker 内部不需要 actor self（避免 self 重入）。
    private static func workerLoop(
        rootPath: String,
        queue: DirQueue,
        stats: ScanStats,
        inodes: InodeSet,
        dirInodes: DirInodeSet,
        options: ScanOptions,
        rootDev: UInt64,
        continuation: AsyncStream<ScanEvent>.Continuation,
        delivery: EventDelivery,
        topLevelPathMappings: [ScanPathPrefixMapping],
        topLevelProjectionRootPath: String?
    ) async {
        while !Task.isCancelled {
            let nextOp = await queue.popOrFinish()
            switch nextOp {
            case .done:
                return
            case .cancelled:
                // 等待队列的 worker 被取消后必须退出，不能把已取消 sleep 的错误吞掉
                // 后在 actor 中 hot-spin；取消不生成任何 incomplete/finished 证据。
                return
            case .work(let work):
                await processDirectory(
                    rootPath: rootPath,
                    work: work,
                    queue: queue,
                    stats: stats,
                    inodes: inodes,
                    dirInodes: dirInodes,
                    options: options,
                    rootDev: rootDev,
                    continuation: continuation,
                    delivery: delivery,
                    topLevelPathMappings: topLevelPathMappings,
                    topLevelProjectionRootPath: topLevelProjectionRootPath
                )
                // 注意顺序：必须先把发现的子目录全部 push 完才 markCompleted，
                // 否则可能出现"queue 空 + inFlight==0"假象 → 其他 worker 提前退出 → 漏扫。
                await queue.markCompleted()
            }
        }
    }

    /// 处理一个目录：getattrlistbulk → 累计本地 → push 子目录 → merge stats。
    /// 改成 async：让"push 子目录"在 markCompleted **之前**真正完成（关键并发正确性）。
    private static func processDirectory(
        rootPath: String,
        work: BulkDirectoryWork,
        queue: DirQueue,
        stats: ScanStats,
        inodes: InodeSet,
        dirInodes: DirInodeSet,
        options: ScanOptions,
        rootDev: UInt64,
        continuation: AsyncStream<ScanEvent>.Continuation,
        delivery: EventDelivery,
        topLevelPathMappings: [ScanPathPrefixMapping],
        topLevelProjectionRootPath: String?
    ) async {
        guard !Task.isCancelled else { return }
        let dirPath = work.path
        let openOutcome = BulkDirectoryOpener.open(
            work: work,
            shouldCancel: { Task.isCancelled }
        )
        let fd: Int32
        switch openOutcome {
        case .opened(let openedFileDescriptor):
            // Cancellation can race with a successful open. Close the descriptor here
            // instead of entering enumeration, and do not manufacture incomplete evidence.
            guard !Task.isCancelled else {
                close(openedFileDescriptor)
                return
            }
            fd = openedFileDescriptor
        case .cancelled:
            return
        case .identityChanged(let identityError):
            // A queued pathname disappeared, changed inode/type, or became a symlink after its
            // parent was enumerated. This is scoped metadata incompleteness and never a reason to
            // follow the replacement object. Root work emits a terminal failure unless the typed
            // classifier proves this is the existing permission-interaction contract.
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .metadata,
                posixErrorCode: identityError
            )
            await publishIncomplete(issue, stats: stats, continuation: continuation)
            if work.isRoot, issue.reason != .permissionDenied {
                continuation.yield(.failed(.cannotEnumerate(
                    path: rootPath,
                    stage: .metadata,
                    posixErrorCode: identityError
                )))
            }
            // v2026.07.17: Format the optional errno before interpolation. Besides keeping the
            // diagnostic readable, this avoids nested string literals becoming a compile-time
            // failure in the scanner's safety-critical identity-change branch.
            let identityErrorDescription = identityError.map(String.init) ?? "nil"
            GSYLog.warning(
                .scan,
                "scan.directory.identity.changed path=\(dirPath) root=\(work.isRoot) errno=\(identityErrorDescription)"
            )
            return
        case .failed(let openError):
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .open,
                posixErrorCode: openError
            )
            await publishIncomplete(issue, stats: stats, continuation: continuation)
            let isRootFailure = work.isRoot && issue.reason != .permissionDenied
            GSYLog.warning(
                .scan,
                "scan.directory.open.failed path=\(dirPath) stage=\(ScanIssueStage.open.rawValue) errno=\(openError) root=\(isRootFailure)"
            )
            if isRootFailure {
                continuation.yield(.failed(.cannotEnumerate(
                    path: rootPath,
                    stage: .open,
                    posixErrorCode: openError
                )))
            }
            return
        }
        defer { close(fd) }

        // CACHEDIR.TAG（cache-directory-tagging.com 标准）是“内容可视为缓存”的分类信号，
        // 不是“清理工具可以不统计大小”的许可。备份工具可以据此跳过内容，但本应用必须继续
        // 下钻，才能给出真实的可释放字节数。事件仍保留给上层做 safe 分类提示。
        if delivery == .complete, CacheDirTag.isCacheDirectory(at: dirPath) {
            continuation.yield(.cacheDirTagged(path: dirPath))
            GSYLog.info(.scan, "BulkScanner 命中 CACHEDIR.TAG，保留缓存分类并继续统计 dir=\(dirPath)")
        }

        // 本地累计，最后一次性合并到 actor stats，减少跨 actor 次数（性能优化）。
        var localFileCount = 0
        var localDirCount = 0
        var localAllocated: Int64 = 0
        var localLogical: Int64 = 0
        var localDeduped: Int64 = 0
        var localPermissionDenied = 0
        var localTCCSkipped = 0
        var localIncompleteIssues: [ScanIncompleteIssue] = []
        var newDirs: [BulkDirectoryWork] = []
        // Step 13B micro-batch：同一父目录内按固定上限分块。
        // 逐 entry yield 会造成过多 continuation hop；整目录一次 yield 又会让超宽目录在
        // MainActor 上形成无界事务。256 是两者之间的固定内存/帧预算边界。
        var localNodes: [FSNode] = []
        if delivery.includesIncrementalNodes {
            localNodes.reserveCapacity(Self.nodeBatchLimit)
        }
        // v2026.07.16 性能回归根治：投影先在 worker 的目录局部变量中累计，目录结束后
        // 才跨 actor 合并一次。不能在 entry callback 内逐文件 await，否则只是把
        // “MainActor 每节点一次”换成“projection actor 每节点一次”。
        var localTopLevel: [String: LocalTopLevelEntry] = [:]
        // v2026.07.18：全盘扫描的物理根是 Data 卷，公开投影根是 `/`。两者不可
        // 再隐式假设相同，否则路径映射完成后会因不再位于物理根前缀下而整批丢弃。
        let projectionRootPath = topLevelProjectionRootPath ?? rootPath
        let fixedTopLevelBucketPath: String? = {
            guard delivery.collectsTopLevelProjection, dirPath != rootPath else { return nil }
            let projectedPath = projectedTopLevelPath(
                dirPath,
                mappings: topLevelPathMappings
            )
            return topLevelBucketPath(for: projectedPath, rootPath: projectionRootPath)
        }()
        var fixedTopLevelEntry = fixedTopLevelBucketPath.map {
            LocalTopLevelEntry(path: $0, isDirectory: true)
        }
        var localLargeFiles: [FSNode] = []
        var localFileCandidates: [FSNode] = []
        var entriesSinceHeartbeat = 0
        var lastHeartbeatAt = Date.timeIntervalSinceReferenceDate
        let largeFilePolicy = delivery.largeFilePolicy
        let fileCandidateMinimumLogicalBytes = delivery.fileCandidateMinimumLogicalBytes
        if let policy = largeFilePolicy, policy.maximumResults > 0 {
            localLargeFiles.reserveCapacity(min(policy.maximumResults, 64))
        }

        let enumerationOutcome = BulkEnumerate.enumerate(
            fd: fd,
            dirPath: dirPath,
            shouldCancel: { Task.isCancelled }
        ) { entry in
            if Task.isCancelled { return false }

            // 投影模式不再靠 `.nodes` 给 MultiRoot watchdog 证明“仍在工作”。每 256 个
            // 真实 entry 才读一次时钟，且最多 0.5 秒发一条，避免宽目录 >90 秒时被
            // 误判 hang，同时不会恢复逐节点事件风暴。
            if delivery != .complete, delivery != .summaryOnly {
                entriesSinceHeartbeat += 1
                if entriesSinceHeartbeat >= 256 {
                    entriesSinceHeartbeat = 0
                    let now = Date.timeIntervalSinceReferenceDate
                    if now - lastHeartbeatAt >= 0.5 {
                        lastHeartbeatAt = now
                        continuation.yield(.heartbeat)
                    }
                }
            }

            // v2026.07.16：POSIX 根目录不能用普通字符串拼接，否则会生成 `//System`。
            // 完整节点模式过去会把双斜杠泄漏给上层；top-level 投影还会因首段为空而
            // 直接丢掉整盘一级行。这里在唯一的 entry path 构造边界统一修正。
            let absPath = entryPath(directoryPath: dirPath, name: entry.name)

            // 隐藏文件
            if !options.includeHidden && entry.name.hasPrefix(".") {
                return true
            }

            // inode 去重只属于文件字节语义；目录回环由独立的 DirInodeSet 处理。
            let isFirstFile = entry.isDirectory
                || !options.dedupByInode
                || inodes.insertIfFirstSeen(device: entry.device, inode: entry.inode)

            if entry.isDirectory {
                localDirCount += 1
            } else {
                localFileCount += 1
                if isFirstFile {
                    localAllocated += entry.allocatedSize
                    localLogical += entry.logicalSize
                } else {
                    localDeduped += entry.allocatedSize
                }
            }

            // v2026.07.17: queue a directory only together with the identity observed before
            // enqueue. The normal path uses getattrlistbulk's dev/inode without another syscall;
            // the explicit `followSymlinks=true` path resolves only symlink entries, freezes the
            // final target identity, and remains bounded by the same volume/cycle gates.
            let mayRepresentDirectory = entry.isDirectory
                || (entry.isSymlink && options.followSymlinks)
            if mayRepresentDirectory {
                // v1.1：TCC 雷区硬 skip，源头杜绝 Apple Music/Photos/Mail 弹窗。
                if options.respectTCCSkipList && TCCSkipList.shouldSkip(absPath) {
                    localTCCSkipped += 1
                    let issue = ScanIncompleteIssue(
                        path: absPath,
                        reason: .tccProtectedSkipped
                    )
                    localIncompleteIssues.append(issue)
                    continuation.yield(.tccProtectedSkipped(path: absPath))
                    continuation.yield(.incomplete(issue))
                } else {
                    let resolution = BulkDirectoryWorkResolver.resolveDescendant(
                        path: absPath,
                        entry: entry,
                        followSymlinks: options.followSymlinks,
                        shouldCancel: { Task.isCancelled }
                    )
                    switch resolution {
                    case .resolved(let childWork):
                        if options.staySingleVolume,
                           !options.followFirmlinks,
                           rootDev != 0,
                           childWork.identity.device != rootDev {
                            // 跨卷停下钻；followFirmlinks=true 时才允许进入另一卷。
                        } else if dirInodes.insertIfFirstSeen(
                            device: childWork.identity.device,
                            inode: childWork.identity.inode
                        ) {
                            newDirs.append(childWork)
                        }
                    case .notDirectory:
                        // A symlink to a regular file remains a file entry; following symlinks
                        // does not turn it into directory work.
                        break
                    case .cancelled:
                        return false
                    case .failed(let errorCode):
                        let issue = ScanFailureClassifier.issue(
                            path: absPath,
                            stage: .metadata,
                            posixErrorCode: errorCode
                        )
                        if issue.reason == .permissionDenied {
                            localPermissionDenied += 1
                            continuation.yield(.permissionDenied(path: absPath))
                        }
                        localIncompleteIssues.append(issue)
                        continuation.yield(.incomplete(issue))
                    }
                }
            }

            let contributesBytes = !entry.isDirectory && isFirstFile
            let nodeAllocated = contributesBytes ? entry.allocatedSize : 0
            let nodeLogical = contributesBytes ? entry.logicalSize : 0

            if var aggregate = fixedTopLevelEntry {
                // 非根目录内的所有 entry 必然归属同一个一级 bucket；直接累计单值，
                // 避免为数百万后代重复做路径切片和 Dictionary 哈希。
                if !entry.isDirectory {
                    aggregate.allocatedBytes += nodeAllocated
                    aggregate.logicalBytes += nodeLogical
                    aggregate.fileCount += 1
                }
                aggregate.hasChildren = true
                fixedTopLevelEntry = aggregate
            } else if delivery.collectsTopLevelProjection {
                let projectedPath = projectedTopLevelPath(
                    absPath,
                    mappings: topLevelPathMappings
                )
                guard let bucketPath = topLevelBucketPath(
                    for: projectedPath,
                    rootPath: projectionRootPath
                ) else { return true }
                var aggregate = localTopLevel[bucketPath] ?? LocalTopLevelEntry(
                    path: bucketPath,
                    isDirectory: true
                )
                if !entry.isDirectory {
                    aggregate.allocatedBytes += nodeAllocated
                    aggregate.logicalBytes += nodeLogical
                    aggregate.fileCount += 1
                }
                if projectedPath != bucketPath {
                    aggregate.hasChildren = true
                }
                if projectedPath == bucketPath {
                    aggregate.sawTopLevelNode = true
                    aggregate.isDirectory = entry.isDirectory
                    if let modificationDate = entry.modificationDate {
                        aggregate.modificationDate = modificationDate
                    }
                }
                localTopLevel[bucketPath] = aggregate
            }

            if let policy = largeFilePolicy,
               policy.minimumBytes > 0,
               policy.maximumResults > 0,
               !entry.isDirectory,
               isFirstFile,
               nodeAllocated >= policy.minimumBytes {
                localLargeFiles.append(FSNode(
                    path: absPath,
                    isDirectory: false,
                    isSymlink: entry.isSymlink,
                    allocatedSize: nodeAllocated,
                    logicalSize: nodeLogical,
                    inode: entry.inode,
                    device: entry.device,
                    modificationDate: entry.modificationDate
                ))
                // 单个超宽目录也必须有硬上限。保留 2N 再裁到 N，避免每发现一个候选
                // 都重排，同时保证局部数组永远是 O(N) 而不是 O(目录项数)。
                // v2026.07.17 public-limit safety: `maximumResults` comes from the caller.
                // Multiplying an extreme positive value directly can trap before the scan has
                // a chance to return a typed terminal result. Saturate only the batching
                // threshold; the requested result limit itself keeps its original semantics.
                let localTrimThreshold = policy.maximumResults > Int.max / 2
                    ? Int.max
                    : policy.maximumResults * 2
                if localLargeFiles.count >= localTrimThreshold {
                    localLargeFiles = Array(
                        localLargeFiles.sorted(by: Self.largeFilePrecedes).prefix(policy.maximumResults)
                    )
                }
            }

            if let minimumLogicalBytes = fileCandidateMinimumLogicalBytes,
               !entry.isDirectory,
               isFirstFile,
               nodeLogical >= minimumLogicalBytes {
                localFileCandidates.append(FSNode(
                    path: absPath,
                    isDirectory: false,
                    isSymlink: entry.isSymlink,
                    allocatedSize: nodeAllocated,
                    logicalSize: nodeLogical,
                    inode: entry.inode,
                    device: entry.device,
                    modificationDate: entry.modificationDate
                ))
            }

            // FSNode 是给增量消费者的“可累计”事件，而不是原始 stat dump：
            // - 目录的 subtree bytes 由后代文件聚合，目录 inode 本身不能再加一次；
            // - 同 inode 的后续 hardlink 仍保留路径/fileCount，但字节归零。
            // 这样展平 node stream 的和与 ScanSummary 保持严格一致。
            if delivery.includesIncrementalNodes {
                // P0：直接 path 主路径，省掉 URL(fileURLWithPath:) 的 147 ms（trace 4.83s）。
                // 旧实现：每个 entry 都 URL.init → RFC3986Parser.parse + percentEncodePath
                // + String._decomposed Unicode 归一化，且所有消费方拿到后立刻 .url.path
                // 反向 bridge 回 String，纯白工。FSNode 已把 url 改成 computed，需要 URL
                // 的 cold path 自己付钱即可。
                let node = FSNode(
                    path: absPath,
                    isDirectory: entry.isDirectory,
                    isSymlink: entry.isSymlink,
                    allocatedSize: nodeAllocated,
                    logicalSize: nodeLogical,
                    inode: entry.inode,
                    device: entry.device,
                    modificationDate: entry.modificationDate
                )
                // 同一父目录内保持原枚举顺序；达到固定上限立即 flush，避免宽目录无界 batch。
                localNodes.append(node)
                if localNodes.count == Self.nodeBatchLimit {
                    continuation.yield(.nodes(localNodes))
                    localNodes.removeAll(keepingCapacity: true)
                }
            }
            return true
        }

        switch enumerationOutcome {
        case .complete:
            break
        case .completeWithIssues(let issues):
            for issue in issues {
                await publishIncomplete(issue, stats: stats, continuation: continuation)
            }
        case .stoppedByConsumer:
            // 当前 callback 唯一的主动停止条件就是 Task cancellation。取消不属于
            // 文件系统不完整，不能污染下一轮删除证据或权限 banner。
            if !Task.isCancelled {
                let issue = ScanIncompleteIssue(
                    path: dirPath,
                    reason: .enumerationFailed,
                    stage: .enumerate
                )
                await publishIncomplete(issue, stats: stats, continuation: continuation)
            }
        case .failed(let issue):
            await publishIncomplete(issue, stats: stats, continuation: continuation)
            let isRootFailure = shouldEmitTerminalFailure(
                rootPath: rootPath,
                directoryPath: dirPath,
                issue: issue
            )
            GSYLog.warning(
                .scan,
                "scan.directory.enumerate.failed path=\(issue.path) stage=\(issue.stage?.rawValue ?? "unknown") errno=\(issue.posixErrorCode.map(String.init) ?? "nil") root=\(isRootFailure)"
            )
            if isRootFailure {
                continuation.yield(.failed(.cannotEnumerate(
                    path: rootPath,
                    stage: issue.stage ?? .enumerate,
                    posixErrorCode: issue.posixErrorCode
                )))
            }
        }

        let wasCancelled = Task.isCancelled

        // Flush 尾批；单 entry 仍保留 `.node` 兼容路径。
        // AsyncStream.continuation.yield 是 thread-safe（Apple 文档保证）
        if !wasCancelled, delivery.includesIncrementalNodes {
            if localNodes.count == 1 {
                continuation.yield(.node(localNodes[0]))
            } else if localNodes.count >= 2 {
                continuation.yield(.nodes(localNodes))
            }
        }

        // 关键：先 push 新目录、再 merge stats，最后才 markCompleted（在 workerLoop 里）
        if !wasCancelled {
            await queue.pushMany(newDirs)
        }
        await stats.merge(
            files: localFileCount,
            dirs: localDirCount,
            allocated: localAllocated,
            logical: localLogical,
            deduped: localDeduped,
            permissionDenied: localPermissionDenied,
            tccSkipped: localTCCSkipped,
            incompleteIssues: localIncompleteIssues,
            topLevelSingle: fixedTopLevelEntry,
            topLevel: localTopLevel,
            largeFiles: localLargeFiles,
            fileCandidates: localFileCandidates,
            emitProgress: !wasCancelled,
            continuation: continuation
        )
        // v2026.07.16 取消正确性：枚举在目录中途观察到取消时，仍把已经读取的本地
        // stats/projection 合并进本轮私有 accumulator，再停止派发新目录和 UI 事件。
        // 这样 MultiRoot 的 timeout partial 能拿到可信下界；用户取消仍不会发布终态。
        guard !wasCancelled else { return }
    }

    /// 把绝对节点投影到扫描根的一级子项。这里只做 String slice，不构造 URL；它与
    /// ScanCoordinator.bucketProjection 的层级语义一致，但运行在后台 worker。
    /// 单元测试也复用的 POSIX join 边界，防止整盘根回归成双斜杠。
    static func entryPath(directoryPath: String, name: String) -> String {
        directoryPath == "/" ? "/\(name)" : "\(directoryPath)/\(name)"
    }

    static func topLevelBucketPath(for absolutePath: String, rootPath: String) -> String? {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard absolutePath.hasPrefix(prefix), absolutePath.count > prefix.count else { return nil }
        let tailStart = absolutePath.index(absolutePath.startIndex, offsetBy: prefix.count)
        let tail = absolutePath[tailStart...]
        let first = tail.firstIndex(of: "/").map { tail[..<$0] } ?? tail[...]
        guard !first.isEmpty else { return nil }
        return rootPath == "/" ? "/" + first : rootPath + "/" + first
    }

    /// 路径规范化必须发生在一级 bucket 被折叠之前；折叠后原始后代路径已不可恢复。
    /// 空规则走零分配 fast path，普通/推荐扫描不会为全盘 firmlink 合同付额外成本。
    static func projectedTopLevelPath(
        _ path: String,
        mappings: [ScanPathPrefixMapping]
    ) -> String {
        guard !mappings.isEmpty else { return path }
        for mapping in mappings {
            if let projected = mapping.project(path) {
                return projected
            }
        }
        return path
    }

    fileprivate static func largeFilePrecedes(_ lhs: FSNode, _ rhs: FSNode) -> Bool {
        if lhs.allocatedSize != rhs.allocatedSize {
            return lhs.allocatedSize > rhs.allocatedSize
        }
        return lhs.path < rhs.path
    }

    /// 单一 incomplete 发布入口：保证 reason、专用 permission event、summary 计数和
    /// 结构化 issue 始终同步。是否升级为根级 `.failed` 由调用点根据 rootPath 决定。
    private static func publishIncomplete(
        _ issue: ScanIncompleteIssue,
        stats: ScanStats,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        if issue.reason == .permissionDenied {
            await stats.recordPermissionDenied(issue: issue)
            continuation.yield(.permissionDenied(path: issue.path))
        } else {
            await stats.recordIncomplete(issue)
        }
        continuation.yield(.incomplete(issue))
    }

    /// `.failed` 是“本轮无法建立根结果”的终态，不是任意路径错误的别名。
    /// 权限拒绝即使发生在根也走 typed incomplete/permission 交互；后代路径无论 errno
    /// 是 EACCES、ENOENT 还是 ESTALE，都只能让 summary 变为 partial。
    static func shouldEmitTerminalFailure(
        rootPath: String,
        directoryPath: String,
        issue: ScanIncompleteIssue
    ) -> Bool {
        directoryPath == rootPath && issue.reason != .permissionDenied
    }
}

// MARK: - 并发支持类型

/// Directory identity frozen before a pathname enters the shared work queue.
///
/// v2026.07.17 root-cause record: queuing only a String allowed a directory to be replaced by a
/// same-volume symlink before `open`, so the scanner followed and counted a different subtree.
/// The queue now carries the exact directory object expected at the later descriptor boundary.
struct BulkDirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64

    init(metadata: stat) {
        self.device = UInt64(bitPattern: Int64(metadata.st_dev))
        self.inode = UInt64(metadata.st_ino)
    }

    init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

struct BulkDirectoryWork: Sendable, Equatable {
    let path: String
    let identity: BulkDirectoryIdentity
    /// True only for the explicit `ScanOptions.followSymlinks` branch. The final target identity
    /// was resolved and frozen before enqueue; `open` may follow only that final component and
    /// must still prove the resulting descriptor matches `identity`.
    let followsFinalSymlink: Bool
    let isRoot: Bool
}

enum BulkDirectoryWorkResolution: Sendable, Equatable {
    case resolved(BulkDirectoryWork)
    case notDirectory
    case failed(Int32)
    case cancelled
}

enum BulkDirectoryWorkResolver {
    static func resolveRoot(
        path: String,
        followSymlinks: Bool,
        shouldCancel: () -> Bool
    ) -> BulkDirectoryWorkResolution {
        guard !shouldCancel() else { return .cancelled }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            let errorCode = errno
            return shouldCancel() ? .cancelled : .failed(errorCode)
        }
        guard !shouldCancel() else { return .cancelled }
        let type = metadata.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFDIR) {
            return .resolved(BulkDirectoryWork(
                path: path,
                identity: BulkDirectoryIdentity(metadata: metadata),
                followsFinalSymlink: false,
                isRoot: true
            ))
        }
        if type == mode_t(S_IFLNK) {
            guard followSymlinks else { return .failed(ELOOP) }
            return resolveFollowedDirectory(
                path: path,
                isRoot: true,
                sourceIdentity: BulkDirectoryIdentity(metadata: metadata),
                shouldCancel: shouldCancel
            )
        }
        return .notDirectory
    }

    static func resolveDescendant(
        path: String,
        entry: BulkEntry,
        followSymlinks: Bool,
        shouldCancel: () -> Bool
    ) -> BulkDirectoryWorkResolution {
        guard !shouldCancel() else { return .cancelled }
        if entry.isSymlink {
            guard followSymlinks else { return .notDirectory }
            return resolveFollowedDirectory(
                path: path,
                isRoot: false,
                sourceIdentity: BulkDirectoryIdentity(
                    device: entry.device,
                    inode: entry.inode
                ),
                shouldCancel: shouldCancel
            )
        }
        guard entry.isDirectory else { return .notDirectory }
        return .resolved(BulkDirectoryWork(
            path: path,
            identity: BulkDirectoryIdentity(device: entry.device, inode: entry.inode),
            followsFinalSymlink: false,
            isRoot: false
        ))
    }

    private static func resolveFollowedDirectory(
        path: String,
        isRoot: Bool,
        sourceIdentity: BulkDirectoryIdentity,
        shouldCancel: () -> Bool
    ) -> BulkDirectoryWorkResolution {
        guard !shouldCancel() else { return .cancelled }
        if let errorCode = finalSymlinkIdentityError(
            at: path,
            expected: sourceIdentity
        ) {
            return shouldCancel() ? .cancelled : .failed(errorCode)
        }
        var target = stat()
        guard stat(path, &target) == 0 else {
            let errorCode = errno
            return shouldCancel() ? .cancelled : .failed(errorCode)
        }
        guard !shouldCancel() else { return .cancelled }
        // A child can be replaced between the descriptor-relative parent enumeration and this
        // explicit opt-in follow. Recheck the link object after resolving its target; otherwise a
        // replacement symlink could donate an unrelated target identity to the work queue.
        if let errorCode = finalSymlinkIdentityError(
            at: path,
            expected: sourceIdentity
        ) {
            return shouldCancel() ? .cancelled : .failed(errorCode)
        }
        guard (target.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            return .notDirectory
        }
        return .resolved(BulkDirectoryWork(
            path: path,
            identity: BulkDirectoryIdentity(metadata: target),
            followsFinalSymlink: true,
            isRoot: isRoot
        ))
    }

    private static func finalSymlinkIdentityError(
        at path: String,
        expected: BulkDirectoryIdentity
    ) -> Int32? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return errno
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK),
              BulkDirectoryIdentity(metadata: metadata) == expected else {
            return ESTALE
        }
        return nil
    }
}

/// `open(2)` directory acquisition with POSIX interruption and frozen-identity semantics.
///
/// Signals may make `open` fail with `EINTR` before a descriptor is created. That is not
/// filesystem evidence and must never become a permission/incomplete event. Production opens
/// are directory-only, close-on-exec and no-follow unless the typed work was explicitly resolved
/// from `followSymlinks=true`; every successful descriptor is then checked with `fstat`.
enum BulkDirectoryOpener {
    enum Attempt: Equatable {
        case opened(Int32)
        case failed(Int32)
    }

    enum Outcome: Equatable {
        case opened(Int32)
        case failed(Int32)
        case identityChanged(Int32?)
        case cancelled
    }

    static func open(
        work: BulkDirectoryWork,
        shouldCancel: () -> Bool
    ) -> Outcome {
        open(
            path: work.path,
            expectedIdentity: work.identity,
            followsFinalSymlink: work.followsFinalSymlink,
            shouldCancel: shouldCancel,
            attempt: {
                systemOpenAttempt(
                    path: $0,
                    followsFinalSymlink: work.followsFinalSymlink
                )
            }
        )
    }

    static func open(
        path: String,
        shouldCancel: () -> Bool
    ) -> Outcome {
        open(
            path: path,
            expectedIdentity: nil,
            followsFinalSymlink: false,
            shouldCancel: shouldCancel,
            attempt: {
                systemOpenAttempt(path: $0, followsFinalSymlink: false)
            }
        )
    }

    static func open(
        path: String,
        shouldCancel: () -> Bool,
        attempt: (String) -> Attempt
    ) -> Outcome {
        open(
            path: path,
            expectedIdentity: nil,
            followsFinalSymlink: false,
            shouldCancel: shouldCancel,
            attempt: attempt
        )
    }

    static func open(
        path: String,
        expectedIdentity: BulkDirectoryIdentity,
        followsFinalSymlink: Bool,
        shouldCancel: () -> Bool,
        attempt: (String) -> Attempt
    ) -> Outcome {
        open(
            path: path,
            expectedIdentity: Optional(expectedIdentity),
            followsFinalSymlink: followsFinalSymlink,
            shouldCancel: shouldCancel,
            attempt: attempt
        )
    }

    private static func open(
        path: String,
        expectedIdentity: BulkDirectoryIdentity?,
        followsFinalSymlink: Bool,
        shouldCancel: () -> Bool,
        attempt: (String) -> Attempt
    ) -> Outcome {
        while true {
            guard !shouldCancel() else { return .cancelled }

            switch attempt(path) {
            case .opened(let fileDescriptor):
                guard !shouldCancel() else {
                    Darwin.close(fileDescriptor)
                    return .cancelled
                }
                guard let expectedIdentity else { return .opened(fileDescriptor) }
                var openedMetadata = stat()
                guard fstat(fileDescriptor, &openedMetadata) == 0 else {
                    let errorCode = errno
                    Darwin.close(fileDescriptor)
                    return .identityChanged(errorCode)
                }
                let openedType = openedMetadata.st_mode & mode_t(S_IFMT)
                let openedIdentity = BulkDirectoryIdentity(metadata: openedMetadata)
                guard openedType == mode_t(S_IFDIR), openedIdentity == expectedIdentity else {
                    Darwin.close(fileDescriptor)
                    return .identityChanged(nil)
                }
                return .opened(fileDescriptor)
            case .failed(let errorCode):
                // Cancellation wins even when the syscall returned an error concurrently.
                // This keeps user cancellation distinct from filesystem incompleteness.
                guard !shouldCancel() else { return .cancelled }
                if errorCode == EINTR {
                    continue
                }
                if expectedIdentity != nil,
                   isPathIdentityChange(errorCode) {
                    return .identityChanged(errorCode)
                }
                return .failed(errorCode)
            }
        }
    }

    private static func isPathIdentityChange(_ errorCode: Int32) -> Bool {
        errorCode == ELOOP
            || errorCode == ENOTDIR
            || errorCode == ENOENT
            || errorCode == ESTALE
    }

    private static func systemOpenAttempt(
        path: String,
        followsFinalSymlink: Bool
    ) -> Attempt {
        let noFollowFlag = followsFinalSymlink ? 0 : O_NOFOLLOW
        let fileDescriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | noFollowFlag,
            0
        )
        guard fileDescriptor >= 0 else {
            // Capture errno immediately; any later Swift/Foundation work may overwrite it.
            return .failed(errno)
        }
        return .opened(fileDescriptor)
    }
}

/// 多 worker 共享的目录队列。
/// 关键设计：用 `inFlight` 计数 + `stack` 一起判定终止 —— 当 stack 空 **且** inFlight==0
/// 时才让所有 worker 一起退出，避免"一个 worker 看到 stack 空就退、另一个 worker 又
/// 推进新目录但没人来取"的饥饿。
actor DirQueue {
    enum PopResult: Sendable {
        case work(BulkDirectoryWork)
        case done
        case cancelled
    }

    private var stack: [BulkDirectoryWork] = []
    private var inFlight: Int = 0

    func push(_ work: BulkDirectoryWork) {
        stack.append(work)
    }

    /// 一次推多个，省 N 次跨 actor hop（worker 完成一目录后会一次推所有子目录）。
    func pushMany(_ work: [BulkDirectoryWork]) {
        if work.isEmpty { return }
        stack.append(contentsOf: work)
    }

    /// 取一个工作单元；若没有但还有 worker 在处理则继续等（让出 actor）；
    /// 若 stack 空 + inFlight==0，告诉调用方"全干完了"。
    func popOrFinish() async -> PopResult {
        while true {
            if Task.isCancelled {
                return .cancelled
            }
            if let p = stack.popLast() {
                inFlight += 1
                return .work(p)
            }
            if inFlight == 0 {
                return .done
            }
            // 让出 actor 一会儿，等其他 worker 推进
            await Task.yield()
            // 防止 100% spin
            do {
                try await Task.sleep(nanoseconds: 500_000) // 0.5ms
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .cancelled
            }
        }
    }

    func markCompleted() {
        inFlight = max(0, inFlight - 1)
    }
}

/// 累计扫描统计的 actor。worker 把本地累计后一次性 merge 进来，省跨 actor 次数。
private actor ScanStats {
    private enum ProjectionMode: Sendable {
        case none
        case topLevel
        case largeFiles(limit: Int)
        case fileCandidates
    }

    private let projectionMode: ProjectionMode
    private let emitsProgress: Bool
    private var fileCount: Int = 0
    private var dirCount: Int = 0
    private var totalAllocated: Int64 = 0
    private var totalLogical: Int64 = 0
    private var dedupedBytes: Int64 = 0
    private var permissionDenied: Int = 0
    private var tccProtectedSkipped: Int = 0
    private var incompleteIssues: Set<ScanIncompleteIssue> = []
    private var lastProgressEmit: Date = .distantPast
    private var topLevelProjection: [String: LocalTopLevelEntry] = [:]
    private var largeFileProjection: [FSNode] = []
    private var fileCandidateProjection: [FSNode] = []

    init(delivery: BulkScanner.EventDelivery = .complete) {
        emitsProgress = delivery.includesProgress
        switch delivery {
        case .topLevel:
            projectionMode = .topLevel
        case .largeFiles(_, let maximumResults):
            projectionMode = .largeFiles(limit: max(0, maximumResults))
        case .fileCandidates:
            projectionMode = .fileCandidates
        case .complete, .summaryOnly, .summaryWithProgress:
            projectionMode = .none
        }
    }

    struct Snapshot {
        let fileCount: Int
        let dirCount: Int
        let totalAllocated: Int64
        let totalLogical: Int64
        let dedupedBytes: Int64
        let permissionDenied: Int
        let tccProtectedSkipped: Int
        let incompleteIssues: [ScanIncompleteIssue]
        let projection: ScanProjectionResult
    }

    func merge(
        files: Int,
        dirs: Int,
        allocated: Int64,
        logical: Int64,
        deduped: Int64,
        permissionDenied: Int = 0,
        tccSkipped: Int = 0,
        incompleteIssues: [ScanIncompleteIssue] = [],
        topLevelSingle: LocalTopLevelEntry? = nil,
        topLevel: [String: LocalTopLevelEntry] = [:],
        largeFiles: [FSNode] = [],
        fileCandidates: [FSNode] = [],
        emitProgress: Bool,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) {
        fileCount += files
        dirCount += dirs
        totalAllocated += allocated
        totalLogical += logical
        dedupedBytes += deduped
        self.permissionDenied += permissionDenied
        tccProtectedSkipped += tccSkipped
        self.incompleteIssues.formUnion(incompleteIssues)

        switch projectionMode {
        case .none:
            break
        case .topLevel:
            // 非根目录走 single fast path，避免百万目录工作负载为每个目录创建
            // 一个“一元素 Dictionary”；只有扫描根自身的直接子项需要 many。
            if let topLevelSingle {
                mergeTopLevel(topLevelSingle)
            }
            for incoming in topLevel.values {
                mergeTopLevel(incoming)
            }
        case .largeFiles(let limit):
            guard limit > 0, !largeFiles.isEmpty else { break }
            largeFileProjection.append(contentsOf: largeFiles)
            if largeFileProjection.count > limit {
                largeFileProjection = Array(
                    largeFileProjection.sorted(by: BulkScanner.largeFilePrecedes).prefix(limit)
                )
            }
        case .fileCandidates:
            fileCandidateProjection.append(contentsOf: fileCandidates)
        }

        guard emitsProgress, emitProgress else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressEmit) > 0.1 else { return }
        lastProgressEmit = now
        // v2026.07.17 absolute-progress ordering closure: returning a sample to concurrent
        // workers allowed an earlier actor merge to resume and yield after a later merge. Publish
        // synchronously inside this actor turn so the public stream is monotonic by construction;
        // the terminal authoritative sample is still emitted after the task group drains.
        continuation.yield(.progress(
            scannedBytes: totalAllocated,
            fileCount: fileCount
        ))
    }

    private func mergeTopLevel(_ incoming: LocalTopLevelEntry) {
        let path = incoming.path
        var aggregate = topLevelProjection[path] ?? LocalTopLevelEntry(
            path: path,
            isDirectory: incoming.isDirectory
        )
        aggregate.allocatedBytes += incoming.allocatedBytes
        aggregate.logicalBytes += incoming.logicalBytes
        aggregate.fileCount += incoming.fileCount
        aggregate.hasChildren = aggregate.hasChildren || incoming.hasChildren
        if incoming.sawTopLevelNode {
            aggregate.sawTopLevelNode = true
            aggregate.isDirectory = incoming.isDirectory
            if let modificationDate = incoming.modificationDate {
                aggregate.modificationDate = modificationDate
            }
        }
        topLevelProjection[path] = aggregate
    }

    func recordPermissionDenied(issue: ScanIncompleteIssue) {
        permissionDenied += 1
        incompleteIssues.insert(issue)
    }

    func recordIncomplete(_ issue: ScanIncompleteIssue) {
        incompleteIssues.insert(issue)
    }

    func snapshot() -> Snapshot {
        let projection: ScanProjectionResult
        switch projectionMode {
        case .none:
            projection = .none
        case .topLevel:
            projection = .topLevel(topLevelProjection.values.map {
                ScanTopLevelEntry(
                    path: $0.path,
                    allocatedBytes: $0.allocatedBytes,
                    logicalBytes: $0.logicalBytes,
                    fileCount: $0.fileCount,
                    isDirectory: $0.isDirectory,
                    hasChildren: $0.hasChildren,
                    modificationDate: $0.modificationDate
                )
            }.sorted { $0.path < $1.path })
        case .largeFiles(let limit):
            projection = .largeFiles(Array(
                largeFileProjection.sorted(by: BulkScanner.largeFilePrecedes).prefix(limit)
            ))
        case .fileCandidates:
            projection = .fileCandidates(fileCandidateProjection)
        }
        return Snapshot(
            fileCount: fileCount,
            dirCount: dirCount,
            totalAllocated: totalAllocated,
            totalLogical: totalLogical,
            dedupedBytes: dedupedBytes,
            permissionDenied: permissionDenied,
            tccProtectedSkipped: tccProtectedSkipped,
            incompleteIssues: incompleteIssues.sorted {
                if $0.path == $1.path { return $0.reason.rawValue < $1.reason.rawValue }
                return $0.path < $1.path
            },
            projection: projection
        )
    }

}

/// 单个 worker 在一个目录内生成的一级聚合增量。
/// `sawTopLevelNode` 区分“从后代推断它是目录”与“确实读到了一级节点自身”，保证
/// 目录 mtime 和根下直接文件的类型不会被其它 worker 的后代增量覆盖。
private struct LocalTopLevelEntry: Sendable {
    let path: String
    var allocatedBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var fileCount: Int = 0
    var isDirectory: Bool
    var hasChildren: Bool = false
    var modificationDate: Date?
    var sawTopLevelNode: Bool = false
}

// MARK: - getattrlistbulk 解析

/// 单个目录项的 metadata。
struct BulkEntry {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let allocatedSize: Int64
    let logicalSize: Int64
    let inode: UInt64
    let device: UInt64
    let modificationDate: Date?
}

/// 调用 `getattrlistbulk` 并按偏移解析返回缓冲区。
///
/// 关键参考：Apple `man getattrlistbulk(2)` + `<sys/attr.h>`。
/// 注意 attribute 的"返回顺序"必须严格按 `attrgroup_t` bit 升序排列，
/// 这一点没有任何 Swift wrapper 能帮你校验，错一位就全乱。
enum BulkEnumerate {
    /// 目录枚举是否真正读到了 EOF。调用方若用枚举结果决定“可删除”，必须区分
    /// 完整结束、主动截断和底层读取失败；不能把三者都折叠成一个 Void 返回值。
    enum Outcome: Sendable, Equatable {
        case complete
        /// 目录项读到了 EOF，但一个或多个 entry 的 metadata 无法读取。
        case completeWithIssues([ScanIncompleteIssue])
        case stoppedByConsumer
        /// 目录本身没有完整枚举。是否为根级致命失败由 BulkScanner 决定。
        case failed(ScanIncompleteIssue)
    }

    /// Exact fallback needs every previously emitted name so descriptor re-enumeration can skip
    /// duplicates. Discovery-only callers that may encounter extremely wide directories can
    /// instead bound memory: if the bulk syscall fails after any record was observed, publish a
    /// typed incomplete result rather than retaining O(all entries) names for a rare fallback.
    enum FallbackPolicy: Sendable, Equatable {
        case exactDeduplication
        case boundedMemory
    }

    /// 调用 callback 直到 `false`、任务请求取消或目录读完。
    ///
    /// `getattrlistbulk` 本身是同步系统调用，无法在 syscall 执行途中抢占；这里在每次
    /// syscall 前后、以及解析每个 entry 前检查取消，使调用方最多只需等待当前一次
    /// 64KB batch 返回。取消与业务 callback 主动停止统一返回 `.stoppedByConsumer`，
    /// 具体停止原因由持有取消上下文的调用方判定。
    @discardableResult
    static func enumerate(
        fd: Int32,
        dirPath: String,
        shouldCancel: () -> Bool = { false },
        fallbackPolicy: FallbackPolicy = .exactDeduplication,
        _ body: (BulkEntry) -> Bool
    ) -> Outcome {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS)
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_MODTIME)
            | UInt32(ATTR_CMN_FILEID)
            | UInt32(ATTR_CMN_DEVID)
        )
        attrList.fileattr = attrgroup_t(
            UInt32(ATTR_FILE_TOTALSIZE)
            | UInt32(ATTR_FILE_ALLOCSIZE)
        )

        // 64KB 缓冲区：典型一次能拿 ~200 个 entry
        let bufSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buffer.deallocate() }
        var emittedNames: Set<String> = []
        var observedAnyRecord = false
        var metadataIssues: [ScanIncompleteIssue] = []

        while true {
            if shouldCancel() { return .stoppedByConsumer }
            let retcount = getattrlistbulk(fd, &attrList, buffer, bufSize, 0)
            if shouldCancel() { return .stoppedByConsumer }
            if retcount == 0 {
                return metadataIssues.isEmpty
                    ? .complete
                    : .completeWithIssues(metadataIssues)
            } // 0 = 真读完了
            if retcount < 0 {
                let err = errno
                if err == EINTR {
                    continue
                }
                if fallbackPolicy == .boundedMemory, observedAnyRecord {
                    let issue = ScanFailureClassifier.issue(
                        path: dirPath,
                        stage: .enumerate,
                        posixErrorCode: err
                    )
                    GSYLog.warning(.scan, "getattrlistbulk errno=\(err) dir=\(dirPath) bounded-memory caller stopped after partial records")
                    return .failed(issue)
                }
                // v2026.07.17 identity closure: fallback must stay anchored to the descriptor
                // already opened and fstat-verified by BulkDirectoryOpener. Re-enumerating the
                // pathname with FileManager could follow a replacement symlink and count a
                // different subtree after the safety fence had succeeded.
                let fallback = enumerateWithDescriptorFallbackResult(
                    fd: fd,
                    dirPath: dirPath,
                    skipping: emittedNames,
                    upstreamErrno: err,
                    shouldCancel: shouldCancel,
                    body
                )
                GSYLog.warning(.scan, "getattrlistbulk errno=\(err) dir=\(dirPath) fallbackEntries=\(fallback.count) outcome=\(String(describing: fallback.outcome))")
                return fallback.outcome
            }

            var cursor = buffer
            for _ in 0..<retcount {
                if shouldCancel() { return .stoppedByConsumer }
                let entryStart = cursor
                let entryLen = entryStart.loadUnaligned(as: UInt32.self)
                guard entryLen > 0 else { break }
                let nextCursor = entryStart.advanced(by: Int(entryLen))
                cursor = entryStart.advanced(by: MemoryLayout<UInt32>.size)

                // 第一个字段必须是 returned_attrs（说明哪些字段真的填了）
                let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)
                let returnedDevice = returned.commonattr
                    & attrgroup_t(UInt32(ATTR_CMN_DEVID)) != 0
                let returnedObjectType = returned.commonattr
                    & attrgroup_t(UInt32(ATTR_CMN_OBJTYPE)) != 0
                let returnedFileID = returned.commonattr
                    & attrgroup_t(UInt32(ATTR_CMN_FILEID)) != 0
                let returnedLogicalSize = returned.fileattr
                    & attrgroup_t(UInt32(ATTR_FILE_TOTALSIZE)) != 0
                let returnedAllocatedSize = returned.fileattr
                    & attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE)) != 0

                // —— 关键：之后的字段严格按 attrgroup_t 的 **bit 升序** 排列 ——
                // commonattr：NAME(bit0) → DEVID(bit1) → OBJTYPE(bit3) → MODTIME(bit10) → FILEID(bit25)
                // fileattr  ：TOTALSIZE(bit1) → ALLOCSIZE(bit2)

                // ATTR_CMN_NAME：attrreference_t（offset + length），name 字符串放在 buffer 末尾
                var name = ""
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_NAME)) != 0 {
                    let nameRef = cursor.loadUnaligned(as: attrreference_t.self)
                    let nameStart = cursor.advanced(by: Int(nameRef.attr_dataoffset))
                    name = String(cString: nameStart.assumingMemoryBound(to: CChar.self))
                    cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
                }

                // ATTR_CMN_DEVID：dev_t (Int32)
                var device: UInt64 = 0
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_DEVID)) != 0 {
                    let dev = cursor.loadUnaligned(as: dev_t.self)
                    device = UInt64(bitPattern: Int64(dev))
                    cursor = cursor.advanced(by: MemoryLayout<dev_t>.size)
                }

                // ATTR_CMN_OBJTYPE：fsobj_type_t (UInt32)；VDIR/VLNK 是 vtype enum
                var isDir = false
                var isSymlink = false
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                    let objType = cursor.loadUnaligned(as: fsobj_type_t.self)
                    isDir = (objType == fsobj_type_t(VDIR.rawValue))
                    isSymlink = (objType == fsobj_type_t(VLNK.rawValue))
                    cursor = cursor.advanced(by: MemoryLayout<fsobj_type_t>.size)
                }

                // ATTR_CMN_MODTIME：timespec
                var modDate: Date?
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_MODTIME)) != 0 {
                    let ts = cursor.loadUnaligned(as: timespec.self)
                    modDate = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
                    cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
                }

                // ATTR_CMN_FILEID：UInt64
                var inode: UInt64 = 0
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_FILEID)) != 0 {
                    inode = cursor.loadUnaligned(as: UInt64.self)
                    cursor = cursor.advanced(by: MemoryLayout<UInt64>.size)
                }

                // ATTR_FILE_TOTALSIZE：off_t (Int64)
                var logical: Int64 = 0
                if returned.fileattr & attrgroup_t(UInt32(ATTR_FILE_TOTALSIZE)) != 0 {
                    logical = cursor.loadUnaligned(as: off_t.self)
                    cursor = cursor.advanced(by: MemoryLayout<off_t>.size)
                }

                // ATTR_FILE_ALLOCSIZE：off_t
                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                    allocated = cursor.loadUnaligned(as: off_t.self)
                    cursor = cursor.advanced(by: MemoryLayout<off_t>.size)
                }

                // 跳过 . 与 ..（getattrlistbulk 实测不返回，但保险）
                if name == "." || name == ".." {
                    cursor = nextCursor
                    continue
                }
                observedAnyRecord = true

                // v2026.07.17 uncommon-filesystem contract: the bulk API may legally omit a
                // requested attribute. Directory identity/type and regular-file capacity cannot
                // then be represented as zero. Recover only that cold branch with
                // descriptor-relative fstatat; APFS and symlink-heavy trees keep the
                // zero-extra-syscall hot path.
                let needsDescriptorMetadata = !returnedDevice
                    || !returnedObjectType
                    || !returnedFileID
                    || (!isDir && !isSymlink
                        && (!returnedLogicalSize || !returnedAllocatedSize))
                if needsDescriptorMetadata {
                    var descriptorMetadata = stat()
                    guard fstatat(
                        fd,
                        name,
                        &descriptorMetadata,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0 else {
                        let metadataError = errno
                        let path = BulkScanner.entryPath(
                            directoryPath: dirPath,
                            name: name
                        )
                        metadataIssues.append(ScanFailureClassifier.issue(
                            path: path,
                            stage: .metadata,
                            posixErrorCode: metadataError
                        ))
                        cursor = nextCursor
                        continue
                    }
                    let descriptorType = descriptorMetadata.st_mode & mode_t(S_IFMT)
                    isDir = descriptorType == mode_t(S_IFDIR)
                    isSymlink = descriptorType == mode_t(S_IFLNK)
                    device = UInt64(bitPattern: Int64(descriptorMetadata.st_dev))
                    inode = UInt64(descriptorMetadata.st_ino)
                    logical = Int64(descriptorMetadata.st_size)
                    allocated = Int64(descriptorMetadata.st_blocks) * 512
                }

                let entry = BulkEntry(
                    name: name,
                    isDirectory: isDir,
                    isSymlink: isSymlink,
                    allocatedSize: allocated,
                    logicalSize: logical,
                    inode: inode,
                    device: device,
                    modificationDate: modDate
                )
                if fallbackPolicy == .exactDeduplication {
                    emittedNames.insert(name)
                }
                if !body(entry) { return .stoppedByConsumer }

                cursor = nextCursor
            }
        }
    }

    private struct FallbackResult {
        let count: Int
        let outcome: Outcome
    }

    @discardableResult
    static func enumerateWithFileManagerFallback(
        dirPath: String,
        skipping emittedNames: Set<String>,
        shouldCancel: () -> Bool = { false },
        _ body: (BulkEntry) -> Bool
    ) -> Int {
        // Compatibility adapter retained for focused parser tests. Production fallback enters
        // through `enumerate(fd:...)` and never reacquires a directory by pathname.
        let fd = Darwin.open(
            dirPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard fd >= 0 else { return 0 }
        defer { Darwin.close(fd) }
        return enumerateWithDescriptorFallbackResult(
            fd: fd,
            dirPath: dirPath,
            skipping: emittedNames,
            upstreamErrno: nil,
            shouldCancel: shouldCancel,
            body
        ).count
    }

    /// Testable descriptor-relative fallback entry. `openat(fd, ".")` creates an independent
    /// directory stream at offset zero without resolving `dirPath` again.
    @discardableResult
    static func enumerateWithDescriptorFallback(
        fd: Int32,
        dirPath: String,
        skipping emittedNames: Set<String>,
        shouldCancel: () -> Bool = { false },
        _ body: (BulkEntry) -> Bool
    ) -> Int {
        enumerateWithDescriptorFallbackResult(
            fd: fd,
            dirPath: dirPath,
            skipping: emittedNames,
            upstreamErrno: nil,
            shouldCancel: shouldCancel,
            body
        ).count
    }

    private static func enumerateWithDescriptorFallbackResult(
        fd: Int32,
        dirPath: String,
        skipping emittedNames: Set<String>,
        upstreamErrno: Int32?,
        shouldCancel: () -> Bool,
        _ body: (BulkEntry) -> Bool
    ) -> FallbackResult {
        if shouldCancel() {
            return FallbackResult(count: 0, outcome: .stoppedByConsumer)
        }
        let fallbackFD = Darwin.openat(
            fd,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard fallbackFD >= 0 else {
            let errorCode = errno
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .enumerate,
                posixErrorCode: errorCode
            )
            GSYLog.warning(
                .scan,
                "descriptor fallback openat failed path=\(dirPath) stage=\(ScanIssueStage.enumerate.rawValue) errno=\(errorCode) upstreamErrno=\(upstreamErrno.map(String.init) ?? "nil")"
            )
            return FallbackResult(count: 0, outcome: .failed(issue))
        }
        guard let directory = fdopendir(fallbackFD) else {
            let errorCode = errno
            Darwin.close(fallbackFD)
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .enumerate,
                posixErrorCode: errorCode
            )
            GSYLog.warning(
                .scan,
                "descriptor fallback fdopendir failed path=\(dirPath) stage=\(ScanIssueStage.enumerate.rawValue) errno=\(errorCode) upstreamErrno=\(upstreamErrno.map(String.init) ?? "nil")"
            )
            return FallbackResult(count: 0, outcome: .failed(issue))
        }
        defer { _ = closedir(directory) }
        let directoryFD = dirfd(directory)
        guard directoryFD >= 0 else {
            let errorCode = errno
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .enumerate,
                posixErrorCode: errorCode
            )
            return FallbackResult(count: 0, outcome: .failed(issue))
        }

        var emitted = 0
        var metadataIssues: [ScanIncompleteIssue] = []
        while true {
            if shouldCancel() {
                return FallbackResult(count: emitted, outcome: .stoppedByConsumer)
            }
            errno = 0
            guard let directoryEntry = readdir(directory) else {
                let readError = errno
                if readError != 0 {
                    let issue = ScanFailureClassifier.issue(
                        path: dirPath,
                        stage: .enumerate,
                        posixErrorCode: readError
                    )
                    GSYLog.warning(
                        .scan,
                        "descriptor fallback readdir failed path=\(dirPath) stage=\(ScanIssueStage.enumerate.rawValue) errno=\(readError) upstreamErrno=\(upstreamErrno.map(String.init) ?? "nil")"
                    )
                    return FallbackResult(count: emitted, outcome: .failed(issue))
                }
                return FallbackResult(
                    count: emitted,
                    outcome: metadataIssues.isEmpty
                        ? .complete
                        : .completeWithIssues(metadataIssues)
                )
            }
            let name = directoryEntryName(directoryEntry)
            if name == "." || name == ".." { continue }
            if emittedNames.contains(name) { continue }
            let path = BulkScanner.entryPath(directoryPath: dirPath, name: name)
            var sb = stat()
            guard fstatat(directoryFD, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else {
                let metadataError = errno
                metadataIssues.append(ScanFailureClassifier.issue(
                    path: path,
                    stage: .metadata,
                    posixErrorCode: metadataError
                ))
                GSYLog.warning(
                    .scan,
                    "descriptor fallback metadata failed path=\(path) stage=\(ScanIssueStage.metadata.rawValue) errno=\(metadataError)"
                )
                continue
            }
            let mode = sb.st_mode & S_IFMT
            let entry = BulkEntry(
                name: name,
                isDirectory: mode == S_IFDIR,
                isSymlink: mode == S_IFLNK,
                allocatedSize: Int64(sb.st_blocks) * 512,
                logicalSize: Int64(sb.st_size),
                inode: UInt64(sb.st_ino),
                device: UInt64(bitPattern: Int64(sb.st_dev)),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(sb.st_mtimespec.tv_sec) + TimeInterval(sb.st_mtimespec.tv_nsec) / 1e9)
            )
            emitted += 1
            if !body(entry) {
                return FallbackResult(count: emitted, outcome: .stoppedByConsumer)
            }
        }
    }

    private static func directoryEntryName(
        _ pointer: UnsafeMutablePointer<dirent>
    ) -> String {
        var record = pointer.pointee
        return withUnsafeBytes(of: &record.d_name) { bytes in
            guard let baseAddress = bytes.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }
}
