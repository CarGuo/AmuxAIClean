import Foundation

public struct ScanSessionID: Hashable, Sendable, Codable {
    public let raw: String
    public init(raw: String = UUID().uuidString) {
        self.raw = raw
    }
}

public struct ScanResultRecord: Sendable, Hashable, Codable {
    public let sessionID: ScanSessionID
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let inode: UInt64
    public let device: UInt64
    public let modificationDate: Date?
    public let parentPath: String?

    public init(
        sessionID: ScanSessionID,
        node: FSNode,
        parentPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.path = node.url.path
        self.isDirectory = node.isDirectory
        self.isSymlink = node.isSymlink
        self.allocatedSize = node.allocatedSize
        self.logicalSize = node.logicalSize
        self.inode = node.inode
        self.device = node.device
        self.modificationDate = node.modificationDate
        self.parentPath = parentPath
    }

    public init(
        sessionID: ScanSessionID,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool,
        allocatedSize: Int64,
        logicalSize: Int64,
        inode: UInt64,
        device: UInt64,
        modificationDate: Date?,
        parentPath: String?
    ) {
        self.sessionID = sessionID
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.inode = inode
        self.device = device
        self.modificationDate = modificationDate
        self.parentPath = parentPath
    }
}

public struct ScanResultQuery: Sendable {
    public enum Sort: Sendable {
        case allocatedSizeDescending
        case modificationDateDescending
        case pathAscending
    }

    public let sessionID: ScanSessionID
    public let parentPath: String?
    public let pathPrefix: String?
    public let onlyFiles: Bool
    public let limit: Int?
    public let offset: Int
    public let sort: Sort

    public init(
        sessionID: ScanSessionID,
        parentPath: String? = nil,
        pathPrefix: String? = nil,
        onlyFiles: Bool = false,
        limit: Int? = 200,
        offset: Int = 0,
        sort: Sort = .allocatedSizeDescending
    ) {
        self.sessionID = sessionID
        self.parentPath = parentPath
        self.pathPrefix = pathPrefix
        self.onlyFiles = onlyFiles
        self.limit = limit
        self.offset = offset
        self.sort = sort
    }
}

public struct ScanResultAggregate: Sendable, Equatable {
    public let totalCount: Int
    public let totalAllocatedBytes: Int64
    public let totalLogicalBytes: Int64

    public init(totalCount: Int, totalAllocatedBytes: Int64, totalLogicalBytes: Int64) {
        self.totalCount = totalCount
        self.totalAllocatedBytes = totalAllocatedBytes
        self.totalLogicalBytes = totalLogicalBytes
    }

    public static let empty = ScanResultAggregate(
        totalCount: 0,
        totalAllocatedBytes: 0,
        totalLogicalBytes: 0
    )
}

public protocol ScanResultStore: Sendable {
    func beginSession(_ id: ScanSessionID) async throws
    func insert(_ records: [ScanResultRecord]) async throws
    func finalizeSession(_ id: ScanSessionID) async throws
    func query(_ query: ScanResultQuery) async throws -> [ScanResultRecord]
    func aggregate(sessionID: ScanSessionID, parentPath: String?) async throws -> ScanResultAggregate
    /// v1.3.z：批量子树聚合。给一组目录 path 前缀，返回每个 prefix 对应的
    /// "path LIKE 'prefix/%'" 整个子树的 (totalCount, totalAllocatedBytes, totalLogicalBytes)。
    ///
    /// 用途：deepIndex=off + store-only 模式下，TreeBrowserView 列出 root 直接子项时，
    /// 单个目录 record 自身的 allocated_size 只是 inode 自己（~0 字节），无法反映该
    /// 目录下整个子树的总大小。需要这个 API 一次性把 22 个一级目录的子树聚合算出来，
    /// 避免每个目录单独发一次 SQL（22 次往返）。
    ///
    /// 实现要求：内部用单事务 / 单条带相关子查询的 SQL，确保 O(prefixes.count) 次
    /// 索引 range scan 而非 O(prefixes.count) 次往返；并发友好。
    /// 返回字典 key = 输入的 prefix（path），value = 该子树聚合；prefix 不存在记录时返回 .empty。
    func subtreeAggregates(
        sessionID: ScanSessionID,
        pathPrefixes: [String]
    ) async throws -> [String: ScanResultAggregate]
    func evictSession(_ id: ScanSessionID) async throws
    func clearAll() async throws
}
