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

/// v1.3.zzzz：树形 Tab 展开一个目录时，一条 SQL 一次性拿出"该 prefix 下所有
/// 直接子项段 + 每段子树聚合"。代替 ScanCoordinator 旧版"拉所有子孙回 Swift +
/// Dictionary GROUP BY"的 ~100ms 慢路径，目标 ~10ms。
///
/// segment 含义：在 parentPath="/Users/x/Library" 下，path=
/// "/Users/x/Library/Caches/Google/abc.bin" 的 segment = "Caches"。
/// 即 parentPath 之后第一段路径。
///
/// hasInode：该 segment 在 GRDB 里是否有自己的 inode record（即 path == prefix+seg）。
/// vendor bucket / 沙盒被拒情况下可能 false，但只要子孙非空仍可作为目录展开。
///
/// isDirectory：用 segment 自己的 inode 上的 is_directory；hasInode=false 时
/// 由 ScanCoordinator 兜底（descendantCount > 1 即视为目录）。
public struct DirectChildAggregate: Sendable, Equatable {
    public let segment: String
    public let isDirectory: Bool
    public let hasInode: Bool
    public let descendantCount: Int
    public let descendantBytes: Int64
    public let descendantLogicalBytes: Int64
    /// 仅是文件 record 的累加（用于"叶子直接孩子"判定）。
    public let fileDescendantCount: Int
    public let fileDescendantBytes: Int64

    public init(segment: String, isDirectory: Bool, hasInode: Bool,
                descendantCount: Int, descendantBytes: Int64, descendantLogicalBytes: Int64,
                fileDescendantCount: Int, fileDescendantBytes: Int64) {
        self.segment = segment
        self.isDirectory = isDirectory
        self.hasInode = hasInode
        self.descendantCount = descendantCount
        self.descendantBytes = descendantBytes
        self.descendantLogicalBytes = descendantLogicalBytes
        self.fileDescendantCount = fileDescendantCount
        self.fileDescendantBytes = fileDescendantBytes
    }
}

public protocol ScanResultStore: Sendable {
    func beginSession(_ id: ScanSessionID) async throws
    func insert(_ records: [ScanResultRecord]) async throws
    func finalizeSession(_ id: ScanSessionID) async throws
    func query(_ query: ScanResultQuery) async throws -> [ScanResultRecord]
    func aggregate(sessionID: ScanSessionID, parentPath: String?) async throws -> ScanResultAggregate
    /// v1.3.zzzz：树形 Tab 展开 prefix 时一条 SQL 拿出所有直接子项 + 每段子树聚合。
    /// 默认实现走 query+Swift 聚合慢路径作为兜底；GRDBScanResultStore 覆盖为单条 SQL GROUP BY。
    func directChildrenAggregated(
        sessionID: ScanSessionID,
        parentPath: String
    ) async throws -> [DirectChildAggregate]
    func evictSession(_ id: ScanSessionID) async throws
    func clearAll() async throws
    /// **v1.5.3**：在指定 session 中按路径前缀（精确匹配 + `prefix + "/"` 前缀）剧除记录。
    ///
    /// 用于 [ScanCoordinator.pruneDeleted(paths:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 把删除动作落到 GRDB 层；不这样做的话 store-fallback 会把已删项重新拉回 cache，
    /// 用户视觉上"删了又冒出来"。默认实现 throws unsupported——具体 store 各自实现。
    func deletePaths(sessionID: ScanSessionID, paths: [String]) async throws
}

/// [ScanResultStore.directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/ScanResultStore.swift)
/// 默认实现内部用的累加器。声明在 fileprivate 顶层而非局部嵌套，
/// 是因为 Swift 不允许在泛型 protocol-extension 函数里嵌套类型（泛型上下文限制）。
fileprivate struct _DirectChildrenAcc {
    var bytes: Int64 = 0
    var logical: Int64 = 0
    var count: Int = 0
    var fileBytes: Int64 = 0
    var fileCount: Int = 0
    var hasInode: Bool = false
    var inodeIsDir: Bool = false
}

public extension ScanResultStore {
    /// **v1.5.3** 默认实现：no-op。具体 store（GRDBScanResultStore）按需覆写。
    /// 这样做是为了不强制要求每个 ScanResultStore 实现都立刻提供 deletePaths——
    /// 内存 stub 等 test double 走默认空实现就够用。
    func deletePaths(sessionID: ScanSessionID, paths: [String]) async throws {
        // no-op
    }

    /// 默认实现：拉所有子孙 record 回内存做 Swift Dictionary GROUP BY。
    /// 仅作向后兼容兜底；高性能实现请覆盖。
    func directChildrenAggregated(
        sessionID: ScanSessionID,
        parentPath: String
    ) async throws -> [DirectChildAggregate] {
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let descendants = try await query(ScanResultQuery(
            sessionID: sessionID,
            parentPath: nil,
            pathPrefix: prefix,
            onlyFiles: false,
            limit: nil,
            offset: 0,
            sort: .pathAscending
        ))
        var accs: [String: _DirectChildrenAcc] = [:]
        let prefixLen = prefix.count
        for rec in descendants {
            guard rec.path.count > prefixLen else { continue }
            let suffix = rec.path.dropFirst(prefixLen)
            let firstSlash = suffix.firstIndex(of: "/")
            let seg = firstSlash.map { String(suffix[..<$0]) } ?? String(suffix)
            var a = accs[seg] ?? _DirectChildrenAcc()
            a.bytes &+= rec.allocatedSize
            a.logical &+= rec.logicalSize
            a.count &+= 1
            if !rec.isDirectory {
                a.fileBytes &+= rec.allocatedSize
                a.fileCount &+= 1
            }
            if rec.path == prefix + seg {
                a.hasInode = true
                a.inodeIsDir = rec.isDirectory
            }
            accs[seg] = a
        }
        return accs.map { (seg, a) in
            DirectChildAggregate(
                segment: seg,
                isDirectory: a.hasInode ? a.inodeIsDir : (a.count > 1 || a.fileCount == 0),
                hasInode: a.hasInode,
                descendantCount: a.count,
                descendantBytes: a.bytes,
                descendantLogicalBytes: a.logical,
                fileDescendantCount: a.fileCount,
                fileDescendantBytes: a.fileBytes
            )
        }
    }
}
