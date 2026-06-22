import Foundation

/// 文件系统节点（文件 / 目录）。
///
/// 性能历史（2024.xx，trace 4.83s）：
/// 旧实现把 `url: URL` 作为 stored let。BulkScanner.processDirectory 每个 entry 都
/// 调一次 `URL(fileURLWithPath: absPath)`，trace 显示这条链 147 ms：
///   - RFC3986Parser.parse 40 ms
///   - percentEncodePath 17 ms
///   - String._decomposed (Unicode 归一化) 35 ms
///   - _SwiftURL.__allocating_init 144 ms
/// 且所有热路径消费方（ScanResultStore / ScanCoordinator.ingest / DuplicateScanner）
/// 拿到 FSNode 后**立刻 `.url.path` 反向 bridge 回 String**，URL 这次构造完全是
/// 无用功——双向 bridge 都白花。
///
/// 现实现：`path: String` 改为 stored；`url: URL` 改为 computed（按需现造，cold
/// path 才会触发）。BulkScanner / ScanResultStore / ingest 全部直接用 `node.path`，
/// 一次 URL 构造也不会发生。
public struct FSNode: Sendable, Hashable {
    /// 绝对路径（POSIX）。BulkScanner 内部就是按 String 拼出来的，不走 URL bridge。
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// 物理占用（字节）。
    public let allocatedSize: Int64
    /// 逻辑大小（字节）；与 allocatedSize 不同时常意味着 iCloud 占位 / 稀疏文件。
    public let logicalSize: Int64
    public let inode: UInt64
    public let device: UInt64
    public let modificationDate: Date?

    /// 旧字段兼容：computed property。优先用 `path` 字段；只在调用方真的需要
    /// `URL` 能力（标准化 / scheme 判断等）时才付出 RFC3986Parser 这笔账。
    @inlinable
    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    /// 主初始化器：BulkScanner / 其他热路径用这个，零 URL 构造。
    public init(
        path: String,
        isDirectory: Bool,
        isSymlink: Bool,
        allocatedSize: Int64,
        logicalSize: Int64,
        inode: UInt64,
        device: UInt64,
        modificationDate: Date?
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.inode = inode
        self.device = device
        self.modificationDate = modificationDate
    }

    /// 兼容旧调用点（外部 / 测试可能仍按 URL 构造）。内部把 URL 拍成 path 存。
    /// 注意：这条路径会触发一次 `url.path` bridge，比新的 `init(path:...)` 慢，
    /// 不要在热路径用。
    public init(
        url: URL,
        isDirectory: Bool,
        isSymlink: Bool,
        allocatedSize: Int64,
        logicalSize: Int64,
        inode: UInt64,
        device: UInt64,
        modificationDate: Date?
    ) {
        self.init(
            path: url.path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            allocatedSize: allocatedSize,
            logicalSize: logicalSize,
            inode: inode,
            device: device,
            modificationDate: modificationDate
        )
    }
}

/// 扫描汇总。
public struct ScanSummary: Sendable {
    public let root: URL
    public let totalAllocatedBytes: Int64
    public let totalLogicalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let dedupedHardlinkBytes: Int64
    public let elapsed: TimeInterval
    public let permissionDeniedCount: Int
    /// 因 TCC 雷区（Music/Photos/Mail 等）主动 skip 的目录数（v1.1 加入）。
    public let tccProtectedSkippedCount: Int

    public init(
        root: URL,
        totalAllocatedBytes: Int64,
        totalLogicalBytes: Int64,
        fileCount: Int,
        directoryCount: Int,
        dedupedHardlinkBytes: Int64,
        elapsed: TimeInterval,
        permissionDeniedCount: Int = 0,
        tccProtectedSkippedCount: Int = 0
    ) {
        self.root = root
        self.totalAllocatedBytes = totalAllocatedBytes
        self.totalLogicalBytes = totalLogicalBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.dedupedHardlinkBytes = dedupedHardlinkBytes
        self.elapsed = elapsed
        self.permissionDeniedCount = permissionDeniedCount
        self.tccProtectedSkippedCount = tccProtectedSkippedCount
    }
}

/// 增量事件，UI 用 AsyncStream 实时消费——避免"扫完再展示"的假死。
public enum ScanEvent: Sendable {
    case progress(scannedBytes: Int64, fileCount: Int)
    case node(FSNode)
    /// Step 13B micro-batch：把"逐 entry yield .node"折叠成"按目录批量 yield 数组"。
    /// 一个 .nodes 批次的所有元素来自**同一父目录**（worker 在 processDirectory 末尾一次性 yield）。
    /// 消费方处理：逐项 ingest（与 .node 等价），减少跨 actor / continuation hop 频次。
    case nodes([FSNode])
    case finished(ScanSummary)
    case failed(Error)
    case permissionDenied(path: String)
    /// TCC 雷区（Apple Music/Photos/Mail 等）被主动跳过；UI 用此事件统一展示而非弹窗。
    case tccProtectedSkipped(path: String)
    /// 命中 CACHEDIR.TAG 标记，整棵子目录被视为「纯缓存」跳过下钻；
    /// UI 可把命中目录作为 safe 候选高亮。
    case cacheDirTagged(path: String)
}
