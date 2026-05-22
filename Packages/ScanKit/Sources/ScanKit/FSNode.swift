import Foundation

/// 文件系统节点（文件 / 目录）。
public struct FSNode: Sendable, Hashable {
    public let url: URL
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// 物理占用（字节）。
    public let allocatedSize: Int64
    /// 逻辑大小（字节）；与 allocatedSize 不同时常意味着 iCloud 占位 / 稀疏文件。
    public let logicalSize: Int64
    public let inode: UInt64
    public let device: UInt64
    public let modificationDate: Date?

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
        self.url = url
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.inode = inode
        self.device = device
        self.modificationDate = modificationDate
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
    case finished(ScanSummary)
    case failed(Error)
    case permissionDenied(path: String)
    /// TCC 雷区（Apple Music/Photos/Mail 等）被主动跳过；UI 用此事件统一展示而非弹窗。
    case tccProtectedSkipped(path: String)
}
