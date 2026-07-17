import Foundation
import Darwin

/// 文件系统节点（文件 / 目录）。
///
/// 性能历史（2024.xx，trace 4.83s）：
/// 旧实现把 `url: URL` 作为 stored let。BulkScanner.processDirectory 每个 entry 都
/// 调一次 `URL(fileURLWithPath: absPath)`，trace 显示这条链 147 ms：
///   - RFC3986Parser.parse 40 ms
///   - percentEncodePath 17 ms
///   - String._decomposed (Unicode 归一化) 35 ms
///   - _SwiftURL.__allocating_init 144 ms
/// 且所有热路径消费方（ScanCoordinator.ingest / DuplicateScanner）
/// 拿到 FSNode 后**立刻 `.url.path` 反向 bridge 回 String**，URL 这次构造完全是
/// 无用功——双向 bridge 都白花。
///
/// 现实现：`path: String` 改为 stored；`url: URL` 改为 computed（按需现造，cold
/// path 才会触发）。BulkScanner / ingest 全部直接用 `node.path`，
/// 一次 URL 构造也不会发生。
public struct FSNode: Sendable, Hashable {
    /// 绝对路径（POSIX）。BulkScanner 内部就是按 String 拼出来的，不走 URL bridge。
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// 本次扫描中应累计的物理占用（字节）。目录及重复 hardlink 为 0。
    /// 对普通文件来自 `ATTR_FILE_ALLOCSIZE`；它不是 APFS clone 的 exclusive extent 大小。
    public let allocatedSize: Int64
    /// 本次扫描中应累计的逻辑大小（字节）。目录及重复 hardlink 为 0；与
    /// allocatedSize 不同时常意味着 iCloud 占位或稀疏文件。
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

/// 扫描汇总的完整性状态。
///
/// `.partial` 表示根目录未被穷尽：可能来自权限/TCC/枚举缺口，也可能是超时或无进展
/// watchdog 合成的阶段性汇总。它可以展示已观察结果，但绝不能作为安全删除的完整证据。
public enum ScanCompletionStatus: Sendable, Equatable {
    case complete
    case partial
}

/// 扫描未能完整覆盖某条路径的结构化原因。
///
/// 这与“任务被用户取消”严格分离：取消不会生成 issue；只有扫描仍打算完成、但文件系统
/// 明确拒绝或无法完整枚举时才记录。删除链路可据此把祖先候选锁住，而 UI 仍能展示已经
/// 观察到的部分大小。
public enum ScanIncompleteReason: String, Sendable, Equatable, Hashable {
    /// `open(2)` / FileManager 明确返回无权限。
    case permissionDenied
    /// 为避免 TCC 弹窗而主动跳过受保护目录。
    case tccProtectedSkipped
    /// 目录已经打开，但 bulk 枚举与 FileManager fallback 都未完整读到 EOF。
    case enumerationFailed
    /// 枚举拿到了路径，但读取该节点 metadata 失败。
    case metadataUnavailable
}

/// 扫描缺口发生在哪个文件系统阶段。它是诊断字段，不承担用户文案职责；UI 应根据
/// `reason` 展示可操作说明，把 stage/errno 留给日志和“技术详情”。
public enum ScanIssueStage: String, Sendable, Equatable, Hashable {
    /// `open(2)` 无法取得目录描述符。
    case open
    /// 目录描述符已取得，但目录项没有完整读到 EOF。
    case enumerate
    /// 已拿到目录项名称，但读取该项 metadata 失败。
    case metadata
}

/// 一条扫描完整性缺口。path 始终为绝对 POSIX 路径。
public struct ScanIncompleteIssue: Sendable, Equatable, Hashable {
    public let path: String
    public let reason: ScanIncompleteReason
    /// 失败阶段；旧调用方未提供时为 nil，以保持来源不明确的证据仍可表达。
    public let stage: ScanIssueStage?
    /// 原始 POSIX errno。只保存数值，避免把平台错误字符串当用户文案跨层传递。
    public let posixErrorCode: Int32?

    public init(
        path: String,
        reason: ScanIncompleteReason,
        stage: ScanIssueStage? = nil,
        posixErrorCode: Int32? = nil
    ) {
        self.path = path
        self.reason = reason
        self.stage = stage
        self.posixErrorCode = posixErrorCode
    }
}

/// 只有扫描根本身无法建立可用结果时才允许进入 `ScanEvent.failed`。
/// 后代目录的失败必须留在 `ScanIncompleteIssue`，从而保留已扫描结果而不误报整轮失败。
public enum ScanError: Error, Sendable, Equatable {
    case cannotEnumerate(path: String, stage: ScanIssueStage, posixErrorCode: Int32?)
}

extension ScanError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cannotEnumerate(let path, let stage, let posixErrorCode):
            let errnoText = posixErrorCode.map(String.init) ?? "nil"
            return "cannotEnumerate(path=\(path), stage=\(stage.rawValue), errno=\(errnoText))"
        }
    }
}

/// FileManager/Cocoa 与 POSIX 两条扫描路径共用同一错误分类，避免同一目录在 fallback
/// 前后从 permissionDenied 漂移成 generic enumerationFailed。
enum ScanFailureClassifier {
    static func issue(
        path: String,
        stage: ScanIssueStage,
        posixErrorCode: Int32?
    ) -> ScanIncompleteIssue {
        let reason: ScanIncompleteReason
        if let posixErrorCode,
           posixErrorCode == EACCES || posixErrorCode == EPERM {
            reason = .permissionDenied
        } else if stage == .metadata {
            reason = .metadataUnavailable
        } else {
            reason = .enumerationFailed
        }
        return ScanIncompleteIssue(
            path: path,
            reason: reason,
            stage: stage,
            posixErrorCode: posixErrorCode
        )
    }

    static func posixErrorCode(from error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(exactly: nsError.code)
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return EACCES
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return posixErrorCode(from: underlying)
        }
        return nil
    }
}

/// 扫描器在后台完成的一级容量投影。
///
/// **v2026.07.16 性能回归根治：** UI 默认只展示扫描根的一级子项，更深层级本来就由
/// TreeBrowser 按需加载。把每个 `FSNode` 先送到 MainActor、再在那里聚合，既不增加结果
/// 信息量，又会在百万节点场景形成数分钟积压。该类型让 ScanKit 在 worker 侧完成同一份
/// 无损聚合，MainActor 最终只接收“实际会显示的一级行”。物理/逻辑大小、文件数与 inode
/// 去重后的 `ScanSummary` 使用同一轮枚举数据，不能用额外 `du`/估算值补齐。
public struct ScanTopLevelEntry: Sendable, Equatable {
    public let path: String
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    /// 该一级目录下面是否实际发现过后代节点。不能只用 `fileCount > 0` 推断，
    /// 因为空目录层级同样需要在 Tree 中保留可展开提示。
    public let hasChildren: Bool
    public let modificationDate: Date?

    public init(
        path: String,
        allocatedBytes: Int64,
        logicalBytes: Int64,
        fileCount: Int,
        isDirectory: Bool,
        hasChildren: Bool,
        modificationDate: Date?
    ) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.hasChildren = hasChildren
        self.modificationDate = modificationDate
    }
}

/// 一级投影前使用的路径前缀规范化规则。
///
/// **v2026.07.16 全盘投影正确性修复：** macOS Data 卷上的真实路径（例如
/// `/System/Volumes/Data/Users/...`）需要先映射回公开 firmlink 路径（`/Users/...`），
/// 再决定根目录下的一级 bucket。若等 ScanKit 已经聚合成 `/System` 后才在 UI 映射，
/// 原始后代路径已经丢失，无法恢复 `/Users`、`/Library` 等真实顶层分布。
///
/// 该类型只表达通用、边界安全的前缀替换；具体 firmlink 规则仍由 AppUI 从系统
/// `/usr/share/firmlinks` 读取并传入，ScanKit 不硬编码 macOS 目录知识。
public struct ScanPathPrefixMapping: Sendable, Equatable {
    public let sourcePrefix: String
    public let destinationPrefix: String

    public init(sourcePrefix: String, destinationPrefix: String) {
        self.sourcePrefix = Self.normalizedPrefix(sourcePrefix)
        self.destinationPrefix = Self.normalizedPrefix(destinationPrefix)
    }

    func project(_ path: String) -> String? {
        if path == sourcePrefix {
            return destinationPrefix
        }
        guard path.hasPrefix(sourcePrefix + "/") else { return nil }
        return destinationPrefix + String(path.dropFirst(sourcePrefix.count))
    }

    private static func normalizedPrefix(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

/// 可选的后台投影结果。
///
/// `.none` 保持传统完整 node stream / summary-only 合同；`.topLevel` 服务普通、推荐和
/// 整盘结果页；`.largeFiles` 只携带固定上限 Top-N；`.fileCandidates` 服务
/// 必须拿到全部达标文件才能做后续内容分析的后台消费者。投影结果永远附着在
/// 权威终态 summary 上，因此 UI 丢掉任意中间 progress 帧都不会丢容量、候选或
/// 完整性证据。
public enum ScanProjectionResult: Sendable, Equatable {
    case none
    case topLevel([ScanTopLevelEntry])
    case largeFiles([FSNode])
    /// 无上限但先在 worker 侧过滤的文件候选。它不是 UI 列表投影；调用方本来
    /// 就需要保留所有达标项（例如 DuplicateScanner 的 size bucket）。
    case fileCandidates([FSNode])
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
    /// `.complete` 只用于扫描器自然遍历完根目录的汇总；超时合成汇总必须为 `.partial`。
    public let completionStatus: ScanCompletionStatus
    /// 本次扫描未完整覆盖的路径。非空时 completionStatus 强制为 `.partial`。
    public let incompleteIssues: [ScanIncompleteIssue]
    /// ScanKit 后台生成的有界/预聚合 UI 投影。默认 `.none` 保持旧调用方语义。
    public let projection: ScanProjectionResult

    public init(
        root: URL,
        totalAllocatedBytes: Int64,
        totalLogicalBytes: Int64,
        fileCount: Int,
        directoryCount: Int,
        dedupedHardlinkBytes: Int64,
        elapsed: TimeInterval,
        permissionDeniedCount: Int = 0,
        tccProtectedSkippedCount: Int = 0,
        completionStatus: ScanCompletionStatus = .complete,
        incompleteIssues: [ScanIncompleteIssue] = [],
        projection: ScanProjectionResult = .none
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
        self.incompleteIssues = incompleteIssues
        self.completionStatus = incompleteIssues.isEmpty ? completionStatus : .partial
        self.projection = projection
    }
}

/// 增量事件，UI 用 AsyncStream 实时消费——避免"扫完再展示"的假死。
public enum ScanEvent: Sendable {
    /// 低频“仍有真实枚举进展”信号，不携带容量数据。
    ///
    /// v2026.07.16：投影模式不会发送逐节点事件；超宽单目录在结束前也无法合并出
    /// 权威绝对 progress。该事件只供 watchdog/UI 保活，禁止拿它累计文件数或字节数。
    case heartbeat
    case progress(scannedBytes: Int64, fileCount: Int)
    case node(FSNode)
    /// Step 13B micro-batch：把"逐 entry yield .node"折叠成"按目录、有界批量 yield 数组"。
    /// 一个 .nodes 批次的所有元素来自**同一父目录**，数量不超过
    /// `BulkScanner.nodeBatchLimit`。
    /// 消费方处理：逐项 ingest（与 .node 等价），减少跨 actor / continuation hop 频次。
    case nodes([FSNode])
    case finished(ScanSummary)
    /// 扫描根级致命失败。后代目录读取失败不得进入此 case。
    case failed(ScanError)
    case permissionDenied(path: String)
    /// TCC 雷区（Apple Music/Photos/Mail 等）被主动跳过；UI 用此事件统一展示而非弹窗。
    case tccProtectedSkipped(path: String)
    /// 目录/节点未被完整枚举。取消不会产生此事件。
    case incomplete(ScanIncompleteIssue)
    /// 命中 CACHEDIR.TAG 标记。该事件是分类提示；扫描仍会下钻并统计真实大小。
    case cacheDirTagged(path: String)
}
