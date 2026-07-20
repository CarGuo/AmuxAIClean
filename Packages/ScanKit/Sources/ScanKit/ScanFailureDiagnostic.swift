import Foundation

/// 扫描链路写入本地用户日志的闭集错误事实。
///
/// 路径不属于这个值：调用方只能用 `path=` / `root=` / `parent=` 等明确字段把已知的
/// 本地文件系统范围写入用户自有日志。`Error` 的 description、localizedDescription、
/// userInfo 与自定义 domain 都不能跨过这条边界。
///
/// v2026.07.18 P2 隐私根因修复：Swift Error 桥接后的文字与 domain 均可由 provider
/// 自定义并夹带路径或正文；因此只保留闭集 source/stage/reason/domain 与数值 code。
public struct ScanFailureDiagnostic: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case derivedData = "derived-data"
        case workflow
    }

    public enum Stage: String, Sendable, Equatable {
        case discovery
        case snapshot
        case sizeEstimation = "size-estimation"
        case cardResolution = "card-resolution"
        case dynamicDiscovery = "dynamic-discovery"
        case rootMetadata = "root-metadata"
        case bulkScan = "bulk-scan"
        case globExpansion = "glob-expansion"
    }

    public enum Reason: String, Sendable, Equatable {
        case unexpectedFailure = "unexpected-failure"
        case permissionDenied = "permission-denied"
        case tccProtectedSkipped = "tcc-protected-skipped"
        case enumerationFailed = "enumeration-failed"
        case metadataUnavailable = "metadata-unavailable"

        public init(_ incompleteReason: ScanIncompleteReason) {
            switch incompleteReason {
            case .permissionDenied:
                self = .permissionDenied
            case .tccProtectedSkipped:
                self = .tccProtectedSkipped
            case .enumerationFailed:
                self = .enumerationFailed
            case .metadataUnavailable:
                self = .metadataUnavailable
            }
        }
    }

    public enum Domain: String, Sendable, Equatable {
        case cocoa = "NSCocoaErrorDomain"
        case posix = "NSPOSIXErrorDomain"
        case osStatus = "NSOSStatusErrorDomain"
        case mach = "NSMachErrorDomain"
        case url = "NSURLErrorDomain"
        case unknown = "UnknownErrorDomain"

        fileprivate init(rawErrorDomain: String) {
            switch rawErrorDomain {
            case NSCocoaErrorDomain:
                self = .cocoa
            case NSPOSIXErrorDomain:
                self = .posix
            case NSOSStatusErrorDomain:
                self = .osStatus
            case NSMachErrorDomain:
                self = .mach
            case NSURLErrorDomain:
                self = .url
            default:
                self = .unknown
            }
        }
    }

    public let source: Source
    public let stage: Stage
    public let reason: Reason
    public let domain: Domain
    public let code: Int?

    public init(
        source: Source,
        stage: Stage,
        reason: Reason,
        domain: Domain,
        code: Int?
    ) {
        self.source = source
        self.stage = stage
        self.reason = reason
        self.domain = domain
        self.code = code
    }

    public init(
        source: Source,
        stage: Stage,
        reason: Reason,
        error: any Error
    ) {
        let bridged = error as NSError
        self.init(
            source: source,
            stage: stage,
            reason: reason,
            domain: Domain(rawErrorDomain: bridged.domain),
            code: bridged.code
        )
    }

    public init(
        source: Source,
        stage: Stage,
        reason: Reason,
        posixErrorCode: Int32?
    ) {
        self.init(
            source: source,
            stage: stage,
            reason: reason,
            domain: posixErrorCode == nil ? .unknown : .posix,
            code: posixErrorCode.map(Int.init)
        )
    }

    /// 只由枚举 rawValue 与整数组成，允许直接写入本地用户日志。
    public var logFields: String {
        let codeValue = code.map(String.init) ?? "none"
        return "source=\(source.rawValue) stage=\(stage.rawValue) reason=\(reason.rawValue) "
            + "domain=\(domain.rawValue) code=\(codeValue)"
    }
}
