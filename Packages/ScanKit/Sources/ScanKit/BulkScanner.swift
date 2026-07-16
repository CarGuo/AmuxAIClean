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
    public enum EventDelivery: Sendable {
        case complete
        case summaryOnly

        fileprivate var includesIncrementalNodes: Bool {
            self == .complete
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
        delivery: EventDelivery = .complete
    ) -> AsyncStream<ScanEvent> {
        // v1.3 P0 修复：原 `.bufferingNewest(8192)` 在 195k+ 文件场景会静默丢事件
        //（消费者主线程慢于 worker yield 速度时，最旧的 .node 事件被 AsyncStream 主动丢弃，
        // 直接导致 Finder 18.86 GB / 195,979 items → 应用 552.6 MB / 1,209 items 的灾难性少算）。
        // 改为 .unbounded：worker 永远可以 yield，因此不会静默丢事件。AsyncStream 本身不提供
        // 背压；下方 `nodeBatchLimit` 只限制单事件大小，整体缓冲上限仍需另行设计无损握手机制。
        // 去重身份属于一次 scan transaction，不能挂在 BulkScanner 实例上再 reset：
        // `scan` 是 nonisolated，同一实例可能并发产生两个 stream；共享+reset 会让两轮互相
        // 清空或吞掉 inode。每轮独立集合同时解决复用污染与并发数据竞争。
        let inodeSet = InodeSet()
        let dirInodeSet = DirInodeSet()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let opts = options
            let inodes = inodeSet
            let dirInodes = dirInodeSet
            let task = Task.detached(priority: .userInitiated) {
                let start = Date()
                let stats = ScanStats()
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
                    continuation.yield(.finished(summary))
                    continuation.finish()
                    return
                }
                await queue.push(root.path)

                // 把根目录的 dev_t 取出来（lstat 一次），用于跨卷停下钻判断。
                // 用 let + 立即求值；Swift 6 严格并发不允许闭包捕获可变 var。
                // v1.3 P0-A：顺手把根目录的 (dev,ino) 登记进 dirInodes，避免后续遇到
                // 指向根的 firmlink（如 /System/Volumes/Data ↔ /）时回环重扫。
                let rootDev: UInt64 = {
                    var sb = stat()
                    guard lstat(root.path, &sb) == 0 else { return 0 }
                    let dev = UInt64(bitPattern: Int64(sb.st_dev))
                    let ino = UInt64(sb.st_ino)
                    _ = dirInodes.insertIfFirstSeen(device: dev, inode: ino)
                    return opts.staySingleVolume ? dev : 0
                }()

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
                                delivery: delivery
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
                    incompleteIssues: s.incompleteIssues
                )
                GSYLog.info(.scan, "scan 完成 root=\(root.path) files=\(summary.fileCount) dirs=\(summary.directoryCount) bytes=\(summary.totalAllocatedBytes) elapsed=\(String(format: "%.2f", summary.elapsed))s permissionDenied=\(summary.permissionDeniedCount) tccSkipped=\(summary.tccProtectedSkippedCount)")
                continuation.yield(.finished(summary))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
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
        delivery: EventDelivery
    ) async {
        while !Task.isCancelled {
            let nextOp = await queue.popOrFinish()
            switch nextOp {
            case .done:
                return
            case .work(let dirPath):
                await processDirectory(
                    rootPath: rootPath,
                    dirPath: dirPath,
                    queue: queue,
                    stats: stats,
                    inodes: inodes,
                    dirInodes: dirInodes,
                    options: options,
                    rootDev: rootDev,
                    continuation: continuation,
                    delivery: delivery
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
        dirPath: String,
        queue: DirQueue,
        stats: ScanStats,
        inodes: InodeSet,
        dirInodes: DirInodeSet,
        options: ScanOptions,
        rootDev: UInt64,
        continuation: AsyncStream<ScanEvent>.Continuation,
        delivery: EventDelivery
    ) async {
        guard !Task.isCancelled else { return }
        let openOutcome = BulkDirectoryOpener.open(
            path: dirPath,
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
        case .failed(let openError):
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .open,
                posixErrorCode: openError
            )
            await publishIncomplete(issue, stats: stats, continuation: continuation)
            let isRootFailure = shouldEmitTerminalFailure(
                rootPath: rootPath,
                directoryPath: dirPath,
                issue: issue
            )
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
        var localTCCSkipped = 0
        var localIncompleteIssues: [ScanIncompleteIssue] = []
        var newDirs: [String] = []
        // Step 13B micro-batch：同一父目录内按固定上限分块。
        // 逐 entry yield 会造成过多 continuation hop；整目录一次 yield 又会让超宽目录在
        // MainActor 上形成无界事务。256 是两者之间的固定内存/帧预算边界。
        var localNodes: [FSNode] = []
        if delivery.includesIncrementalNodes {
            localNodes.reserveCapacity(Self.nodeBatchLimit)
        }

        let enumerationOutcome = BulkEnumerate.enumerate(
            fd: fd,
            dirPath: dirPath,
            shouldCancel: { Task.isCancelled }
        ) { entry in
            if Task.isCancelled { return false }

            let absPath = "\(dirPath)/\(entry.name)"

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
                if entry.name != "." && entry.name != ".." {
                    // v1.1：TCC 雷区硬 skip，源头杜绝 Apple Music/Photos/Mail 弹窗
                    // v1.3：仅当 respectTCCSkipList=true 时才硬 skip。
                    // 已授予 FDA 时 ScanCoordinator 会把这个开关置 false，让用户原本就有权限的目录被正常下钻，
                    // 同时不再 yield .tccProtectedSkipped → 修 banner 误报。
                    if options.respectTCCSkipList && TCCSkipList.shouldSkip(absPath) {
                        localTCCSkipped += 1
                        let issue = ScanIncompleteIssue(
                            path: absPath,
                            reason: .tccProtectedSkipped
                        )
                        localIncompleteIssues.append(issue)
                        continuation.yield(.tccProtectedSkipped(path: absPath))
                        continuation.yield(.incomplete(issue))
                    } else if options.staySingleVolume && !options.followFirmlinks && rootDev != 0 && entry.device != rootDev {
                        // 跨卷停下钻：dev 不一致就不入队。followFirmlinks=true 时允许 macOS firmlink 跨 dev 下钻。
                    } else if entry.isSymlink && !options.followSymlinks {
                        // v1.3 P0-A：symlink-to-dir 必须在这里硬截断。
                        // 否则 pnpm/lerna `node_modules/.bin/* → ../foo`、`~/Library/Mobile Documents`
                        // 等场景会让 BFS 反复回环，Stream 永远不会 finish（20 分钟还在扫的根因之一）。
                    } else if dirInodes.insertIfFirstSeen(device: entry.device, inode: entry.inode) {
                        // 首次访问该 (dev,ino)：入队。
                        // dir hardlink（Time Machine）、firmlink（同 inode 不同路径）均在此被吸收。
                        newDirs.append(absPath)
                    }
                    // else：dirInodes 命中，目录回环被切断，直接跳过。
                }
            } else {
                localFileCount += 1
                if isFirstFile {
                    localAllocated += entry.allocatedSize
                    localLogical += entry.logicalSize
                } else {
                    localDeduped += entry.allocatedSize
                }
            }

            // FSNode 是给增量消费者的“可累计”事件，而不是原始 stat dump：
            // - 目录的 subtree bytes 由后代文件聚合，目录 inode 本身不能再加一次；
            // - 同 inode 的后续 hardlink 仍保留路径/fileCount，但字节归零。
            // 这样展平 node stream 的和与 ScanSummary 保持严格一致。
            if delivery.includesIncrementalNodes {
                let contributesBytes = !entry.isDirectory && isFirstFile
                let nodeAllocated = contributesBytes ? entry.allocatedSize : 0
                let nodeLogical = contributesBytes ? entry.logicalSize : 0

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
            if Task.isCancelled { return }
            let issue = ScanIncompleteIssue(
                path: dirPath,
                reason: .enumerationFailed,
                stage: .enumerate
            )
            await publishIncomplete(issue, stats: stats, continuation: continuation)
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

        guard !Task.isCancelled else { return }

        // Flush 尾批；单 entry 仍保留 `.node` 兼容路径。
        // AsyncStream.continuation.yield 是 thread-safe（Apple 文档保证）
        if delivery.includesIncrementalNodes {
            if localNodes.count == 1 {
                continuation.yield(.node(localNodes[0]))
            } else if localNodes.count >= 2 {
                continuation.yield(.nodes(localNodes))
            }
        }

        // 关键：先 push 新目录、再 merge stats，最后才 markCompleted（在 workerLoop 里）
        await queue.pushMany(newDirs)
        await stats.merge(
            files: localFileCount,
            dirs: localDirCount,
            allocated: localAllocated,
            logical: localLogical,
            deduped: localDeduped,
            tccSkipped: localTCCSkipped,
            incompleteIssues: localIncompleteIssues
        )
        if delivery == .complete, let prog = await stats.progressIfDue() {
            continuation.yield(.progress(scannedBytes: prog.bytes, fileCount: prog.files))
        }
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

/// `open(2)` directory acquisition with POSIX interruption semantics.
///
/// Signals may make `open` fail with `EINTR` before a descriptor is created. That is not
/// filesystem evidence and must never become a permission/incomplete event. The retry loop
/// is isolated here so production and deterministic tests share exactly the same behavior;
/// tests inject attempts instead of relying on signal timing.
enum BulkDirectoryOpener {
    enum Attempt: Equatable {
        case opened(Int32)
        case failed(Int32)
    }

    enum Outcome: Equatable {
        case opened(Int32)
        case failed(Int32)
        case cancelled
    }

    static func open(
        path: String,
        shouldCancel: () -> Bool
    ) -> Outcome {
        open(
            path: path,
            shouldCancel: shouldCancel,
            attempt: systemOpenAttempt
        )
    }

    static func open(
        path: String,
        shouldCancel: () -> Bool,
        attempt: (String) -> Attempt
    ) -> Outcome {
        while true {
            guard !shouldCancel() else { return .cancelled }

            switch attempt(path) {
            case .opened(let fileDescriptor):
                return .opened(fileDescriptor)
            case .failed(let errorCode):
                // Cancellation wins even when the syscall returned an error concurrently.
                // This keeps user cancellation distinct from filesystem incompleteness.
                guard !shouldCancel() else { return .cancelled }
                if errorCode == EINTR {
                    continue
                }
                return .failed(errorCode)
            }
        }
    }

    private static func systemOpenAttempt(path: String) -> Attempt {
        let fileDescriptor = Darwin.open(path, O_RDONLY, 0)
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
    enum PopResult {
        case work(String)
        case done
    }

    private var stack: [String] = []
    private var inFlight: Int = 0

    func push(_ path: String) {
        stack.append(path)
    }

    /// 一次推多个，省 N 次跨 actor hop（worker 完成一目录后会一次推所有子目录）。
    func pushMany(_ paths: [String]) {
        if paths.isEmpty { return }
        stack.append(contentsOf: paths)
    }

    /// 取一个工作单元；若没有但还有 worker 在处理则继续等（让出 actor）；
    /// 若 stack 空 + inFlight==0，告诉调用方"全干完了"。
    func popOrFinish() async -> PopResult {
        while true {
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
            try? await Task.sleep(nanoseconds: 500_000) // 0.5ms
        }
    }

    func markCompleted() {
        inFlight = max(0, inFlight - 1)
    }
}

/// 累计扫描统计的 actor。worker 把本地累计后一次性 merge 进来，省跨 actor 次数。
actor ScanStats {
    private var fileCount: Int = 0
    private var dirCount: Int = 0
    private var totalAllocated: Int64 = 0
    private var totalLogical: Int64 = 0
    private var dedupedBytes: Int64 = 0
    private var permissionDenied: Int = 0
    private var tccProtectedSkipped: Int = 0
    private var incompleteIssues: Set<ScanIncompleteIssue> = []
    private var lastProgressEmit: Date = .distantPast

    struct Snapshot {
        let fileCount: Int
        let dirCount: Int
        let totalAllocated: Int64
        let totalLogical: Int64
        let dedupedBytes: Int64
        let permissionDenied: Int
        let tccProtectedSkipped: Int
        let incompleteIssues: [ScanIncompleteIssue]
    }

    func merge(
        files: Int,
        dirs: Int,
        allocated: Int64,
        logical: Int64,
        deduped: Int64,
        tccSkipped: Int = 0,
        incompleteIssues: [ScanIncompleteIssue] = []
    ) {
        fileCount += files
        dirCount += dirs
        totalAllocated += allocated
        totalLogical += logical
        dedupedBytes += deduped
        tccProtectedSkipped += tccSkipped
        self.incompleteIssues.formUnion(incompleteIssues)
    }

    func recordPermissionDenied(issue: ScanIncompleteIssue) {
        permissionDenied += 1
        incompleteIssues.insert(issue)
    }

    func recordIncomplete(_ issue: ScanIncompleteIssue) {
        incompleteIssues.insert(issue)
    }

    func snapshot() -> Snapshot {
        Snapshot(
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
            }
        )
    }

    /// 距上次 progress 事件超 0.1s 才返回值（节流），否则 nil。
    func progressIfDue() -> (bytes: Int64, files: Int)? {
        let now = Date()
        if now.timeIntervalSince(lastProgressEmit) > 0.1 {
            lastProgressEmit = now
            return (totalAllocated, fileCount)
        }
        return nil
    }
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

        while true {
            if shouldCancel() { return .stoppedByConsumer }
            let retcount = getattrlistbulk(fd, &attrList, buffer, bufSize, 0)
            if shouldCancel() { return .stoppedByConsumer }
            if retcount == 0 { return .complete } // 0 = 真读完了
            if retcount < 0 {
                let err = errno
                if err == EINTR {
                    continue
                }
                let fallback = enumerateWithFileManagerFallbackResult(
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
                emittedNames.insert(name)
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
        enumerateWithFileManagerFallbackResult(
            dirPath: dirPath,
            skipping: emittedNames,
            upstreamErrno: nil,
            shouldCancel: shouldCancel,
            body
        ).count
    }

    private static func enumerateWithFileManagerFallbackResult(
        dirPath: String,
        skipping emittedNames: Set<String>,
        upstreamErrno: Int32?,
        shouldCancel: () -> Bool,
        _ body: (BulkEntry) -> Bool
    ) -> FallbackResult {
        if shouldCancel() {
            return FallbackResult(count: 0, outcome: .stoppedByConsumer)
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dirPath)
        } catch {
            let errorCode = ScanFailureClassifier.posixErrorCode(from: error) ?? upstreamErrno
            let issue = ScanFailureClassifier.issue(
                path: dirPath,
                stage: .enumerate,
                posixErrorCode: errorCode
            )
            GSYLog.warning(
                .scan,
                "FileManager fallback enumerate failed path=\(dirPath) stage=\(ScanIssueStage.enumerate.rawValue) errno=\(errorCode.map(String.init) ?? "nil") err=\(error.localizedDescription)"
            )
            return FallbackResult(count: 0, outcome: .failed(issue))
        }
        if shouldCancel() {
            return FallbackResult(count: 0, outcome: .stoppedByConsumer)
        }

        var emitted = 0
        var metadataIssues: [ScanIncompleteIssue] = []
        for name in names where !emittedNames.contains(name) {
            if shouldCancel() {
                return FallbackResult(count: emitted, outcome: .stoppedByConsumer)
            }
            if name == "." || name == ".." { continue }
            let path = "\(dirPath)/\(name)"
            var sb = stat()
            guard lstat(path, &sb) == 0 else {
                let metadataError = errno
                metadataIssues.append(ScanFailureClassifier.issue(
                    path: path,
                    stage: .metadata,
                    posixErrorCode: metadataError
                ))
                GSYLog.warning(
                    .scan,
                    "FileManager fallback metadata failed path=\(path) stage=\(ScanIssueStage.metadata.rawValue) errno=\(metadataError)"
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
        return FallbackResult(
            count: emitted,
            outcome: metadataIssues.isEmpty ? .complete : .completeWithIssues(metadataIssues)
        )
    }
}
