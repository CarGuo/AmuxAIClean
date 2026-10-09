import Foundation
import Darwin

/// v1.3.x：用户反馈"推荐扫描很久没 ETA"——给非整盘扫描提供"先估算总量、再正式扫"的能力。
///
/// 设计目标：**几百毫秒级**走完一个或多个根目录，只统计 on-disk allocated bytes，不分类、不
/// 去重 hardlink、不发 progress。失败/超时直接吞掉，调用方拿到 nil 即可。
///
/// 与 [BulkScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 的差异：
/// - 不并发：单 worker 串行 walk，避免与正式扫描抢 IO
/// - 不发事件：纯同步返回 Int64，方便 await 一次拿到结果
/// - 不读 hardlink dedup（接受**轻微高估**）：估总量分母用，3-5% 误差可接受
/// - **超时**：硬上限 timeoutSeconds（默认 4s），到时间立即返回当前累计值
///   —— 用户不应该为分母多等 1 秒钟正式扫描
///
/// 使用：
/// ```
/// let bytes = await TreeSizeEstimator.estimate(roots: [url1, url2], timeout: 3.0)
/// // bytes == nil 表示一个根都没估出来；非 nil 但可能比真值小（达到超时）
/// ```
public enum TreeSizeEstimator {

    /// 估算多个根的磁盘分配量（对应 `ATTR_FILE_ALLOCSIZE` / `du`）。
    /// - Parameters:
    ///   - roots: 要估算的根目录 URL 列表（推荐 5 个以内）
    ///   - timeout: 软超时秒数。任何根估算到一半到时间就提前返回累计值。默认 4s。
    /// - Returns: 累计字节数；任何根都没成功估出 0 字节时返回 nil（让 UI 知道完全没数据）。
    ///
    /// 实现要点：
    /// - 只读元数据，不打开文件，速度由 dirent 数量决定（M2 SSD 上 ~100k entries/s）
    /// - 跨卷停止：避免误吃 mounted volumes 把估算时间打爆
    /// - 符号链接不递归：iCloud / Application Support 里大量 symlink，递归会指数爆炸
    public static func estimate(roots: [URL], timeout: TimeInterval = 4.0) async -> Int64? {
        guard !roots.isEmpty else { return nil }
        let deadline = ScanDeadline.make(timeout: timeout)

        // Step 13A：5 根并发改造。每根独立 detached Task 跑 walkRoot，让总耗时趋近"最慢根"。
        //
        // 取舍：
        // - 不限并发上限（roots 列表本身已上限 5 个，再加 detached Task 启动开销可忽略）
        // - 共用同一个 deadline：超时由各 Task 自检；任何根超时只截断自己，不阻塞其他根
        // - 用 withTaskGroup 而非 [Task]+await，自动尊重外层 Task 的 cancellation
        // - 失败/0 字节根不计入 anyRootSucceeded；只要有一根估出非 nil 就视为成功
        return await Task.detached(priority: .utility) { () -> Int64? in
            await withTaskGroup(of: Int64?.self) { group in
                for root in roots {
                    group.addTask {
                        // 单根超时检查：早过期就直接返回 nil（不浪费一次 walk）
                        if Date() >= deadline { return nil }
                        return walkRoot(root, deadline: deadline)
                    }
                }
                var total: Int64 = 0
                var anyRootSucceeded = false
                for await bytes in group {
                    if let b = bytes {
                        total += b
                        anyRootSucceeded = true
                    }
                }
                return anyRootSucceeded ? total : nil
            }
        }.value
    }

    /// 单个根的字节估算。
    ///
    /// v2026.06.23 perf（**Instruments Time Profiler 第三次取证**）：
    /// 上一刀"收紧 resourceKeys + 跨卷降频"只把 walkRoot 从 690ms 降到 333ms（35.2%
    /// 仍是最大头）。继续抓栈发现真凶不是 resourceKeys 数量，而是
    /// `FileManager.enumerator` 内部整条 Foundation/CoreFoundation/LaunchServices 链：
    ///   - `_FSURLCreateWithPathAndExtendedAttributes` 34ms
    ///   - `_FSURLCacheResourcePropertiesForKeys` 28ms
    ///   - `_FileCacheSetPropertyValueForKey` 9.6ms
    ///   - `LaunchServices::URLPropertyProvider::prepareIsPackageValue` 13ms
    /// 即使 includingPropertiesForKeys 收紧到最小，`.skipsPackageDescendants`
    /// 仍会强制触发 LaunchServices Database 查询判定 isPackage，无法绕过。
    ///
    /// 优化策略：彻底放弃 `FileManager.enumerator`，改用项目里已封装好的
    /// [BulkEnumerate.enumerate(fd:dirPath:_:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L443-L573)
    /// （getattrlistbulk + attrlist 直读 dirent + inode metadata，64KB 缓冲）+ 手动 DFS：
    ///   - 跳过 NSURL bridge / FileCache / LaunchServices isPackage 全部开销
    ///   - 直接从 attrlist 拿 `allocatedSize`，免去 per-entry resourceValues 调用
    ///   - 跨卷用 `entry.device`（已经从 attrlist 解析好）vs root `stat.st_dev`，
    ///     省去 `.volumeIdentifierKey` 的 NSURL bridge
    ///   - 隐藏文件按名字前缀 `.` 跳过（对齐原 `.skipsHiddenFiles` 行为）
    ///   - 符号链接不递归（对齐原默认 `[]` options 行为）
    ///   - 不做 isPackage 判定（estimator 本来就允许 3-5% 误差，bundle 内文件被吃掉
    ///     轻微高估，对"估算分母"用途无感）
    /// 预期：单根 333ms → ~50ms（5-10x 提升）。
    private static func walkRoot(_ root: URL, deadline: Date) -> Int64? {
        let rootPath = ScanPathIdentity.lexicallyNormalizedPath(root.path)
        if TCCSkipList.shouldSkip(rootPath) { return nil }

        // 拿根目录的 device id 作为跨卷判定基准（一次 stat 调用，省去 NSURL.volumeIdentifierKey）
        // 注意 BulkEntry.device 是 UInt64（来自 attrlist ATTR_CMN_DEVID），stat.st_dev 是 dev_t（Int32），
        // 这里统一转 UInt64 比较。
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0,
              (rootStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            return nil
        }
        let rootDevice = UInt64(bitPattern: Int64(rootStat.st_dev))

        var stack: [String] = [rootPath]
        let inodes = InodeSet()
        var total: Int64 = 0
        var iterations = 0
        // 软上限：估算不接受走太多目录（防御性，正常根 ~10k 目录以内）
        var anyEntry = false
        var openedAnyDirectory = false

        while let dirPath = stack.popLast() {
            if Task.isCancelled || Date() >= deadline { break }
            if TCCSkipList.shouldSkip(dirPath) { continue }
            let fd = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0)
            if fd < 0 { continue }
            defer { Darwin.close(fd) }
            openedAnyDirectory = true

            BulkEnumerate.enumerate(
                fd: fd,
                dirPath: dirPath,
                shouldCancel: { Task.isCancelled },
                { entry in
                    iterations += 1
                    // 每 256 个条目检查一次超时（getattrlistbulk 本身已批量，避免每次回调 Date()）
                    if Task.isCancelled { return false }
                    if iterations & 0xFF == 0, Date() >= deadline { return false }

                    // 对齐原 .skipsHiddenFiles：名字前缀 . 跳过
                    if entry.name.hasPrefix(".") { return true }
                    // 符号链接不递归、也不计大小（避免 iCloud / Application Support 里 symlink 爆炸）
                    if entry.isSymlink { return true }
                    // 跨卷停止：device 来自 attrlist，无需 NSURL bridge
                    if entry.device != rootDevice { return true }
                    // 硬链接与目录环路去重：与正式 BulkScanner 的 (device, inode) 口径一致
                    guard inodes.insertIfFirstSeen(device: entry.device, inode: entry.inode) else {
                        return true
                    }

                    let childPath = dirPath == "/" ? "/\(entry.name)" : "\(dirPath)/\(entry.name)"
                    if TCCSkipList.shouldSkip(childPath) { return true }

                    anyEntry = true
                    if entry.isDirectory {
                        stack.append(childPath)
                    } else if entry.isRegularFile {
                        // 与正式 BulkScanner、System Settings 储存空间使用同一 allocated 语义。
                        total += entry.allocatedSize
                    }
                    return true
                }
            )
        }

        // 空目录是合法估算结果：stat/open 都成功但没有任何 entry，应返回 0。
        // 只有根本没打开过任何目录（例如权限/类型问题）才表示没有估算数据。
        return anyEntry ? total : (openedAnyDirectory ? 0 : nil)
    }
}
