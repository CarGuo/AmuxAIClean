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
    private let options: ScanOptions
    private let inodeSet = InodeSet()
    /// v1.3 P0-A：与 `inodeSet`（文件字节去重）分离的目录入队去重表。详见 DirInodeSet。
    private let dirInodeSet = DirInodeSet()

    public init(options: ScanOptions = .default) {
        self.options = options
    }

    public nonisolated func scan(root: URL) -> AsyncStream<ScanEvent> {
        // v1.3 P0 修复：原 `.bufferingNewest(8192)` 在 195k+ 文件场景会静默丢事件
        //（消费者主线程慢于 worker yield 速度时，最旧的 .node 事件被 AsyncStream 主动丢弃，
        // 直接导致 Finder 18.86 GB / 195,979 items → 应用 552.6 MB / 1,209 items 的灾难性少算）。
        // 改为 .unbounded：worker 永远可以 yield，消费方背压由 actor await 自然形成；不会丢事件。
        // 同时显式 reset inodeSet，防止 BulkScanner 实例被复用时跨次污染（dedupe 把字节归零）。
        inodeSet.reset()
        // v1.3 P0-A：目录入队去重表也必须跨次清空，否则第二次扫描时所有目录都被判"已访问"
        // → 整棵树被跳过，summary 直接 fileCount=0。
        dirInodeSet.reset()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let opts = options
            let inodes = inodeSet
            let dirInodes = dirInodeSet
            let task = Task.detached(priority: .userInitiated) {
                let start = Date()
                let stats = ScanStats()
                let queue = DirQueue()
                // v1.1：根目录本身就是 TCC 雷区时直接退出（防御性，正常 UI 不会传入）
                if TCCSkipList.shouldSkip(root.path) {
                    GSYLog.notice(.scan, "scan 根目录命中 TCC skip-list path=\(root.path)")
                    continuation.yield(.tccProtectedSkipped(path: root.path))
                    let summary = ScanSummary(
                        root: root,
                        totalAllocatedBytes: 0, totalLogicalBytes: 0,
                        fileCount: 0, directoryCount: 0,
                        dedupedHardlinkBytes: 0,
                        elapsed: Date().timeIntervalSince(start),
                        permissionDeniedCount: 0,
                        tccProtectedSkippedCount: 1
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
                                queue: queue,
                                stats: stats,
                                inodes: inodes,
                                dirInodes: dirInodes,
                                options: opts,
                                rootDev: rootDev,
                                continuation: continuation
                            )
                        }
                    }
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
                    tccProtectedSkippedCount: s.tccProtectedSkipped
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
        queue: DirQueue,
        stats: ScanStats,
        inodes: InodeSet,
        dirInodes: DirInodeSet,
        options: ScanOptions,
        rootDev: UInt64,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        while !Task.isCancelled {
            let nextOp = await queue.popOrFinish()
            switch nextOp {
            case .done:
                return
            case .work(let dirPath):
                await processDirectory(
                    dirPath: dirPath,
                    queue: queue,
                    stats: stats,
                    inodes: inodes,
                    dirInodes: dirInodes,
                    options: options,
                    rootDev: rootDev,
                    continuation: continuation
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
        dirPath: String,
        queue: DirQueue,
        stats: ScanStats,
        inodes: InodeSet,
        dirInodes: DirInodeSet,
        options: ScanOptions,
        rootDev: UInt64,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        let fd = open(dirPath, O_RDONLY, 0)
        guard fd >= 0 else {
            await stats.incPermissionDenied()
            continuation.yield(.permissionDenied(path: dirPath))
            return
        }
        defer { close(fd) }

        // CACHEDIR.TAG（cache-directory-tagging.com 标准）：进入目录的实际枚举前先做一次
        // 极轻 stat+read 探测，命中即不下钻。理由：
        // 1. 标准明确允许「整棵子树视为纯缓存」，省下 cargo target / build 这种典型几万到
        //    几十万 entry 的子树；
        // 2. 检测代价仅 1 次 open + 43 字节 read，相对一次目录 enumerate 是几十倍便宜；
        // 3. 业界备份工具（restic / Time Machine / borg）都默认尊重此 tag，对齐用户预期；
        // 4. 命中点本身**不**作为 .node yield —— 我们只 yield 一条 .cacheDirTagged 让 UI
        //    按 safe 候选展示；具体大小由 TreeSizeEstimator 异步算（如有需要）。
        if CacheDirTag.isCacheDirectory(at: dirPath) {
            continuation.yield(.cacheDirTagged(path: dirPath))
            GSYLog.info(.scan, "BulkScanner 命中 CACHEDIR.TAG，整棵子目录跳过下钻 dir=\(dirPath)")
            return
        }

        // 本地累计，最后一次性合并到 actor stats，减少跨 actor 次数（性能优化）。
        var localFileCount = 0
        var localDirCount = 0
        var localAllocated: Int64 = 0
        var localLogical: Int64 = 0
        var localDeduped: Int64 = 0
        var localTCCSkipped = 0
        var newDirs: [String] = []
        // Step 13B micro-batch：把当前目录的 entry 全部攒到 localNodes，结尾一次性 yield。
        // 这样把"逐 entry 跨 continuation hop"折成"每目录一次"，在 195k+ 文件场景下 yield
        // 次数从 ~195k 直降到 ~目录数（典型 < 4000）。AUDIT line 449-451。
        var localNodes: [FSNode] = []
        // Reserve：典型目录 100~300 entry，先给 64 起步避免反复 realloc。
        localNodes.reserveCapacity(64)

        BulkEnumerate.enumerate(fd: fd, dirPath: dirPath) { entry in
            if Task.isCancelled { return false }

            let absPath = "\(dirPath)/\(entry.name)"

            // 隐藏文件
            if !options.includeHidden && entry.name.hasPrefix(".") {
                return true
            }

            // inode 去重（actor 内部 unfair-lock 同步，可在 sync 上下文调）
            let isFirst = !options.dedupByInode
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
                        continuation.yield(.tccProtectedSkipped(path: absPath))
                    } else if options.staySingleVolume && rootDev != 0 && entry.device != rootDev {
                        // 跨卷停下钻：dev 不一致就不入队（注意 firmlink 跨 dev，由 followFirmlinks 单独拦）
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
                if isFirst {
                    localAllocated += entry.allocatedSize
                    localLogical += entry.logicalSize
                } else {
                    localDeduped += entry.allocatedSize
                }
            }

            // P0：直接 path 主路径，省掉 URL(fileURLWithPath:) 的 147 ms（trace 4.83s）。
            // 旧实现：每个 entry 都 URL.init → RFC3986Parser.parse + percentEncodePath
            // + String._decomposed Unicode 归一化，且所有消费方拿到后立刻 .url.path
            // 反向 bridge 回 String，纯白工。FSNode 已把 url 改成 computed，需要 URL
            // 的 cold path 自己付钱即可。
            let node = FSNode(
                path: absPath,
                isDirectory: entry.isDirectory,
                isSymlink: entry.isSymlink,
                allocatedSize: entry.allocatedSize,
                logicalSize: entry.logicalSize,
                inode: entry.inode,
                device: entry.device,
                modificationDate: entry.modificationDate
            )
            // 累积到 batch；不在 entry 回调里直接 yield。
            localNodes.append(node)
            return true
        }

        // 一次性 yield 当前目录所有 entry：
        // - 0 个：不发（极端情况：全是隐藏 + 取消等）
        // - 1 个：发 .node 单 case 兼容旧路径，避免 array 包装的开销
        // - ≥2 个：发 .nodes 批量 case，micro-batch 主张所在
        // AsyncStream.continuation.yield 是 thread-safe（Apple 文档保证）
        if localNodes.count == 1 {
            continuation.yield(.node(localNodes[0]))
        } else if localNodes.count >= 2 {
            continuation.yield(.nodes(localNodes))
        }

        // 关键：先 push 新目录、再 merge stats，最后才 markCompleted（在 workerLoop 里）
        await queue.pushMany(newDirs)
        await stats.merge(
            files: localFileCount,
            dirs: localDirCount,
            allocated: localAllocated,
            logical: localLogical,
            deduped: localDeduped,
            tccSkipped: localTCCSkipped
        )
        if let prog = await stats.progressIfDue() {
            continuation.yield(.progress(scannedBytes: prog.bytes, fileCount: prog.files))
        }
    }
}

// MARK: - 并发支持类型

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
    private var lastProgressEmit: Date = .distantPast

    struct Snapshot {
        let fileCount: Int
        let dirCount: Int
        let totalAllocated: Int64
        let totalLogical: Int64
        let dedupedBytes: Int64
        let permissionDenied: Int
        let tccProtectedSkipped: Int
    }

    func merge(files: Int, dirs: Int, allocated: Int64, logical: Int64, deduped: Int64, tccSkipped: Int = 0) {
        fileCount += files
        dirCount += dirs
        totalAllocated += allocated
        totalLogical += logical
        dedupedBytes += deduped
        tccProtectedSkipped += tccSkipped
    }

    func incPermissionDenied() {
        permissionDenied += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            fileCount: fileCount,
            dirCount: dirCount,
            totalAllocated: totalAllocated,
            totalLogical: totalLogical,
            dedupedBytes: dedupedBytes,
            permissionDenied: permissionDenied,
            tccProtectedSkipped: tccProtectedSkipped
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
    /// 调用 callback 直到 `false` 或目录读完。
    static func enumerate(fd: Int32, dirPath: String, _ body: (BulkEntry) -> Bool) {
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

        while true {
            let retcount = getattrlistbulk(fd, &attrList, buffer, bufSize, 0)
            if retcount == 0 { break } // 0 = 真读完了
            if retcount < 0 {
                // v1.3 P0 修复：原本 retcount<0 与 retcount==0 一起静默 break，
                // 一个 195k entry 的目录中途任意一次 getattrlistbulk 出错（EIO/ENOTSUP/EINTR/权限）
                // 都会让剩余成千上万条 entry 全部丢失（这正是 ijkplayer 漏算的主因之一）。
                // 现在：把 errno 抓出来记录到 stderr，便于诊断；继续保持向上 break，避免无限循环。
                let err = errno
                FileHandle.standardError.write(Data("[ScanKit] getattrlistbulk EIO: errno=\(err) at \(dirPath)\n".utf8))
                GSYLog.warning(.scan, "getattrlistbulk EIO errno=\(err) dir=\(dirPath)")
                break
            }

            var cursor = buffer
            for _ in 0..<retcount {
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
                if !body(entry) { return }

                cursor = nextCursor
            }
        }
    }
}
