import Foundation

/// 动态发现器的一次结构化结果。
///
/// `hits` 与 `incompleteIssues` 必须由同一次发现会话产生，调用方不能把空 `hits`
/// 单独解释为“完整且没有结果”。任务取消不写入 `incompleteIssues`，异步 evidence API
/// 会独立抛出 `CancellationError`，避免把用户主动取消误报成磁盘或权限故障。
public struct DiscoveryEvidence<Hit: Sendable>: Sendable {
    public let hits: [Hit]
    public let incompleteIssues: [ScanIncompleteIssue]

    public var isComplete: Bool { incompleteIssues.isEmpty }

    public init(hits: [Hit], incompleteIssues: [ScanIncompleteIssue] = []) {
        self.hits = hits
        self.incompleteIssues = Set(incompleteIssues).sorted {
            if $0.path == $1.path {
                return $0.reason.rawValue < $1.reason.rawValue
            }
            return $0.path < $1.path
        }
    }

    public func mapHits<Mapped: Sendable>(
        _ transform: (Hit) -> Mapped
    ) -> DiscoveryEvidence<Mapped> {
        DiscoveryEvidence<Mapped>(
            hits: hits.map(transform),
            incompleteIssues: incompleteIssues
        )
    }
}

extension DiscoveryEvidence: Equatable where Hit: Equatable {}

/// 动态文件系统发现器共用的最小可注入表面。
///
/// 产品入口使用 `FileManager.default`；测试通过 fault-injecting 实现精确制造根属性、
/// 目录枚举和子节点 metadata 失败，不依赖 chmod、TCC 状态或时序竞争。
protocol DynamicDiscoveryFileSystem {
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func canonicalPath(for url: URL) -> String
}

extension FileManager: DynamicDiscoveryFileSystem {
    func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum DiscoveryFileErrorClassifier {
    static func isMissing(_ error: Error) -> Bool {
        contains(error) { domain, code in
            (domain == NSCocoaErrorDomain && code == CocoaError.fileNoSuchFile.rawValue)
                || (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
        }
    }

    static func incompleteReason(
        for error: Error,
        fallback: ScanIncompleteReason
    ) -> ScanIncompleteReason {
        contains(error) { domain, code in
            (domain == NSCocoaErrorDomain && code == CocoaError.fileReadNoPermission.rawValue)
                || (domain == NSPOSIXErrorDomain && (code == Int(EACCES) || code == Int(EPERM)))
        } ? .permissionDenied : fallback
    }

    private static func contains(
        _ error: Error,
        matching predicate: (String, Int) -> Bool
    ) -> Bool {
        let nsError = error as NSError
        if predicate(nsError.domain, nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return contains(underlying, matching: predicate)
        }
        return false
    }
}
