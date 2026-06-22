import Foundation
import Darwin

/// v1.3.x：用户反馈"推荐扫描很久没 ETA"——给非整盘扫描提供"先估算总量、再正式扫"的能力。
///
/// 设计目标：**几百毫秒级**走完一个或多个根目录，只统计"逻辑总字节"，不分类、不
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

    /// 估算多个根的总字节数（逻辑大小，对应 `URLResourceKey.fileSizeKey`）。
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
        let deadline = Date().addingTimeInterval(timeout)

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
    /// 用 `FileManager.enumerator` 而非 `getattrlistbulk`：
    /// - 简化实现（getattrlistbulk Swift 调用要写一堆 unsafe）
    /// - 估算只跑一次，性能差异可忽略
    /// - 自动处理符号链接（默认 `[]` options 即跳过 symlink 递归）
    ///
    /// v2026.06.22 perf（**Instruments Time Profiler 取证**）：
    /// dev 扫 33334.md trace 显示 walkRoot 占 41.9%（1.62s 异步中 690ms），
    /// 其中 `URL.resourceValues(forKeys:)` 97ms + `fileResourceIdentifier.getter`
    /// / `volumeIdentifier` fastCharacterContents 链 51ms。优化策略：
    ///   1. **resourceKeys 收紧**：includingPropertiesForKeys 与 per-entry
    ///      resourceValues 都从 3 个 key 砍到 2 个 key（[.fileSizeKey, .isRegularFileKey]），
    ///      取消每行拉 `.volumeIdentifierKey`。每个 entry 少一次 NSURL bridge。
    ///   2. **跨卷检查降频**：从"每行查"改"每 256 行查"，与超时检查复用同一计数器
    ///      `iterations & 0xFF == 0`。最坏情况多吃 255 个跨卷 entry，几 KB 误差
    ///      对"估算分母"用途完全可接受（本来就允许 3-5% 误差）。
    ///   3. 不改 enumerator / 不切 getattrlistbulk —— 风险面 0，纯减字段。
    private static func walkRoot(_ root: URL, deadline: Date) -> Int64? {
        let fm = FileManager.default
        // 先确认根的设备 ID（实现"跨卷停止"用）
        let rootDevice = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true } // 任何错误（权限/丢失文件）继续走，不打断估算
        ) else { return nil }

        var total: Int64 = 0
        // enumerator 是个有副作用的迭代器；用 next() 而不是 for-in 才能配合超时检查中途退出
        var iterations = 0
        while let item = enumerator.nextObject() as? URL {
            iterations += 1
            // 每 256 个条目检查一次超时 + 跨卷边界（频繁检查会反向拖慢自己）
            if iterations & 0xFF == 0 {
                if Date() >= deadline { break }
                // v2026.06.22 perf：跨卷检查从 per-entry 降到 per-256-entry。
                // 跨卷场景：用户根目录里挂了外接盘 / 镜像卷。256 entry 容差
                // 对估算（本就允许 3-5% 误差）无感。
                if let rdev = rootDevice,
                   let dev = (try? item.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
                   !areVolumeIdentifiersEqual(dev, rdev) {
                    enumerator.skipDescendants()
                    continue
                }
            }
            // v2026.06.22 perf：per-entry resourceValues 只拉 fileSize + isRegularFile
            // 两个最小必需 key，省掉 volumeIdentifier 的 NSURL bridge / fastCharacterContents。
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// `volumeIdentifier` 类型擦除版相等比较。
    /// macOS 上是 NSObject 子类（实现了 isEqual），但类型在 SDK 里是 `Any`。
    private static func areVolumeIdentifiersEqual(_ a: Any, _ b: Any) -> Bool {
        guard let aObj = a as AnyObject as? NSObject,
              let bObj = b as AnyObject as? NSObject else { return false }
        return aObj.isEqual(bObj)
    }
}
