import Foundation

/// 扫描配置项。所有可能影响"准确性"和"性能"的开关都在这里集中。
///
/// 与 [PITFALLS.md §2](../../../../PITFALLS.md) 的避坑条目逐一对应。
public struct ScanOptions: Sendable {
    /// 是否包含隐藏文件（`.` 开头）。**默认 true**——这是用户能看到 100G 但 Finder 显示 20G 的主要原因之一。
    public var includeHidden: Bool

    /// 是否进入 .app/.bundle 内部统计。
    public var includePackageContents: Bool

    /// 是否跟随符号链接（默认 false，避免循环）。
    public var followSymlinks: Bool

    /// 是否跟随 firmlinks（macOS Catalina+ 系统卷↔数据卷 双向虫洞）。
    /// 默认 false，扫描根选用 `/System/Volumes/Data` 时也无需跟随。详见 PITFALLS §2.1。
    public var followFirmlinks: Bool

    /// 是否按 (dev_t, ino_t) 去重——硬链接 / APFS clones 必须开启。
    public var dedupByInode: Bool

    /// 使用物理占用 (`totalFileAllocatedSize`) 而非逻辑大小 (`fileSize`)。
    /// 默认 true，避免 iCloud 占位文件、稀疏文件造成"幽灵 GB"。
    public var useAllocatedSize: Bool

    /// 并发度，默认随核心数（v1.0：BulkScanner 多 worker 并行下钻使用，cap 见下）。
    public var concurrency: Int

    /// 并发上限。SSD 实测 N=4~6 是甜点，N>6 IO 开始负收益（见 docs/PERFORMANCE.md）。
    /// 默认 6；`actualConcurrency` 取 `min(concurrency, maxConcurrency)`。
    public var maxConcurrency: Int

    /// 整盘扫描时是否只待在根目录所在卷（v1.0 默认 true）。
    /// 关掉它会让外接 USB / 网络挂载点也被吃进去，导致扫描时间不可控。
    public var staySingleVolume: Bool

    /// 实际生效的 worker 数量（cap 在 maxConcurrency）。
    public var actualConcurrency: Int { max(1, min(concurrency, maxConcurrency)) }

    public init(
        includeHidden: Bool = true,
        includePackageContents: Bool = true,
        followSymlinks: Bool = false,
        followFirmlinks: Bool = false,
        dedupByInode: Bool = true,
        useAllocatedSize: Bool = true,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        maxConcurrency: Int = 6,
        staySingleVolume: Bool = true
    ) {
        self.includeHidden = includeHidden
        self.includePackageContents = includePackageContents
        self.followSymlinks = followSymlinks
        self.followFirmlinks = followFirmlinks
        self.dedupByInode = dedupByInode
        self.useAllocatedSize = useAllocatedSize
        self.concurrency = concurrency
        self.maxConcurrency = maxConcurrency
        self.staySingleVolume = staySingleVolume
    }

    public static let `default` = ScanOptions()
}
