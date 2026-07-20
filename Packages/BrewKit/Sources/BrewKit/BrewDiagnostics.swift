import Foundation

/// Brew 本地结构化文件的解析诊断。缺失文件是 Homebrew 未生成缓存或旧安装布局的正常状态，
/// 因此不会生成 diagnostic；只有不可读、权限拒绝或已有文件格式损坏才进入这里。
///
/// v2026.07.18：把 receipt/JWS 的失败从静默 `try?` 提升到共享数据边界，调用方可以写入
/// 本地日志，同时保持 BrewKit 无网络、无删除、无 LogKit 依赖。
public struct BrewDiagnostic: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case formulaInstallations
        case caskInstallations
        case installReceipt
        case formulaRegistry
        case caskRegistry
        case cleanup
    }

    public enum Stage: String, Sendable, Equatable {
        case enumerateRoot
        case enumerateVersions
        case enumeratePackageSize
        case inspectPackageSize
        case read
        case decodeDocument
        case decodePayload
        case decodeEntry
        case enumerateDownloads
        case inspectEntry
        case resolveSymlink
    }

    public enum Reason: String, Sendable, Equatable {
        case permissionDenied
        case unreadable
        case malformed
        case missingMetadata
        case tooLarge
        case unsafeType
        case changed
        case cancelled
    }

    public let source: Source
    public let stage: Stage
    public let reason: Reason
    public let path: String
    /// 只保留稳定错误标识，不跨层传递可能包含路径或原文的 localizedDescription。
    public let errorDomain: String?
    public let errorCode: Int?
    /// registry payload 可部分成功；该字段记录被拒绝的条目数。
    public let rejectedEntryCount: Int?

    public init(
        source: Source,
        stage: Stage,
        reason: Reason,
        path: String,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        rejectedEntryCount: Int? = nil
    ) {
        self.source = source
        self.stage = stage
        self.reason = reason
        self.path = path
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.rejectedEntryCount = rejectedEntryCount
    }
}

/// v2026.07.18 P2 shared evidence contract. An empty array is only authoritative when the
/// producer explicitly reports `.complete` or an optional Homebrew root is genuinely `.missing`.
/// `.partial` may still carry individually trusted rows/candidates; `.unavailable` carries none.
public enum BrewEvidenceStatus: String, Sendable, Equatable {
    case missing
    case complete
    case partial
    case unavailable

    public var isAuthoritative: Bool {
        self == .missing || self == .complete
    }

    public var isIncomplete: Bool {
        self == .partial || self == .unavailable
    }

    /// Combines independent Homebrew roots without allowing one trustworthy empty source to hide
    /// another unreadable source. `hasValues` distinguishes useful partial evidence from a result
    /// for which no package/candidate could be established at all.
    public static func combining(
        _ statuses: [BrewEvidenceStatus],
        hasValues: Bool
    ) -> BrewEvidenceStatus {
        guard !statuses.isEmpty else { return .complete }
        if statuses.contains(.unavailable) {
            return hasValues ? .partial : .unavailable
        }
        if statuses.contains(.partial) {
            return .partial
        }
        if statuses.allSatisfy({ $0 == .missing }) {
            return .missing
        }
        return .complete
    }
}

public struct BrewPackageListResult: Sendable, Equatable {
    public let packages: [BrewPackage]
    public let diagnostics: [BrewDiagnostic]
    public let status: BrewEvidenceStatus

    /// The optional status keeps the existing source API compatible. Legacy/test callers that do
    /// not provide one receive a conservative derivation from diagnostics instead of having an
    /// empty value silently treated as complete.
    public init(
        packages: [BrewPackage],
        diagnostics: [BrewDiagnostic] = [],
        status: BrewEvidenceStatus? = nil
    ) {
        self.packages = packages
        self.diagnostics = diagnostics
        self.status = status ?? (
            diagnostics.isEmpty
                ? .complete
                : packages.isEmpty ? .unavailable : .partial
        )
    }

    public var isAuthoritativeEmpty: Bool {
        packages.isEmpty && status.isAuthoritative
    }
}

/// 可注入读取边界让测试精确制造权限错误，而不依赖 chmod、当前用户或 TCC 状态。
struct BrewFileReader: Sendable {
    let boundedRead: @Sendable (
        URL,
        Int,
        @Sendable () -> Bool
    ) throws -> Data
    let contentsOfDirectory: @Sendable (URL) throws -> [String]

    init(
        read: @escaping @Sendable (URL) throws -> Data,
        contentsOfDirectory: @escaping @Sendable (URL) throws -> [String] = { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
    ) {
        self.boundedRead = { url, _, shouldCancel in
            if shouldCancel() { throw BrewBoundedLocalFileReadError.cancelled }
            return try read(url)
        }
        self.contentsOfDirectory = contentsOfDirectory
    }

    private init(
        boundedRead: @escaping @Sendable (
            URL,
            Int,
            @Sendable () -> Bool
        ) throws -> Data,
        contentsOfDirectory: @escaping @Sendable (URL) throws -> [String]
    ) {
        self.boundedRead = boundedRead
        self.contentsOfDirectory = contentsOfDirectory
    }

    static let live = BrewFileReader(
        boundedRead: { url, maximumBytes, shouldCancel in
            try BrewBoundedLocalFileReader.read(
                at: url,
                maximumBytes: maximumBytes,
                shouldCancel: shouldCancel
            )
        },
        contentsOfDirectory: { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
    )
}

enum BrewLocalFileReadResult {
    case missing
    case contents(Data)
    case failure(BrewDiagnostic)
}

func readBrewLocalFile(
    at url: URL,
    source: BrewDiagnostic.Source,
    reader: BrewFileReader,
    shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
) -> BrewLocalFileReadResult {
    do {
        return .contents(try reader.boundedRead(
            url,
            BrewLocalFileLimits.maximumBytes(for: source),
            shouldCancel
        ))
    } catch {
        guard let diagnostic = brewLocalFileFailureDiagnostic(
            error,
            source: source,
            stage: .read,
            path: url.path
        ) else {
            return .missing
        }
        return .failure(diagnostic)
    }
}

func brewLocalFileFailureDiagnostic(
    _ error: Error,
    source: BrewDiagnostic.Source,
    stage: BrewDiagnostic.Stage,
    path: String
) -> BrewDiagnostic? {
    if BrewFileErrorClassifier.isMissing(error) {
        return nil
    }
    if let bounded = error as? BrewBoundedLocalFileReadError {
        let reason: BrewDiagnostic.Reason
        switch bounded {
        case .tooLarge: reason = .tooLarge
        case .unsafeType: reason = .unsafeType
        case .changed: reason = .changed
        case .cancelled: reason = .cancelled
        case .metadataUnavailable(let stage, let code)
            where stage != .initialPath && code == ENOENT:
            reason = .changed
        case .openFailed(let code) where code == ENOENT:
            reason = .changed
        case .invalidFileURL, .metadataUnavailable, .openFailed, .readFailed:
            reason = BrewFileErrorClassifier.isPermissionDenied(bounded)
                ? .permissionDenied
                : .unreadable
        }
        return BrewDiagnostic(
            source: source,
            stage: stage,
            reason: reason,
            path: path,
            errorDomain: bounded.posixErrorCode == nil ? nil : NSPOSIXErrorDomain,
            errorCode: bounded.posixErrorCode.map(Int.init)
        )
    }
    let nsError = error as NSError
    return BrewDiagnostic(
        source: source,
        stage: stage,
        reason: BrewFileErrorClassifier.isPermissionDenied(error)
            ? .permissionDenied
            : .unreadable,
        path: path,
        errorDomain: nsError.domain,
        errorCode: nsError.code
    )
}

enum BrewFileErrorClassifier {
    static func isMissing(_ error: Error) -> Bool {
        if let bounded = error as? BrewBoundedLocalFileReadError {
            // v2026.07.18: only absence before the reader has observed any object is normal.
            // ENOENT after initial lstat is a pathname-generation change and must stay diagnostic.
            if case .metadataUnavailable(stage: .initialPath, posixErrorCode: ENOENT) = bounded {
                return true
            }
            return false
        }
        return contains(error) { domain, code in
            // v2026.07.18 regression：FileManager 的读取/枚举 API 通常返回 Cocoa 260
            // (`fileReadNoSuchFile`)，而不是 Cocoa 4 (`fileNoSuchFile`)；二者都代表当前
            // 文件系统快照中的正常 absence，不能被误报成 unreadable。
            (domain == NSCocoaErrorDomain
                && (code == CocoaError.fileNoSuchFile.rawValue
                    || code == CocoaError.fileReadNoSuchFile.rawValue))
                || (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        if let bounded = error as? BrewBoundedLocalFileReadError,
           let code = bounded.posixErrorCode {
            return code == EACCES || code == EPERM
        }
        return contains(error) { domain, code in
            (domain == NSCocoaErrorDomain && code == CocoaError.fileReadNoPermission.rawValue)
                || (domain == NSPOSIXErrorDomain && (code == Int(EACCES) || code == Int(EPERM)))
        }
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

/// v2026.07.18: production limits are source-specific and fixed. Homebrew's signed formula cache
/// is legitimately tens of MiB, while an individual install receipt should remain tiny.
enum BrewLocalFileLimits {
    static func maximumBytes(for source: BrewDiagnostic.Source) -> Int {
        switch source {
        case .formulaRegistry, .caskRegistry:
            return 128 * 1_024 * 1_024
        case .installReceipt:
            return 4 * 1_024 * 1_024
        case .formulaInstallations, .caskInstallations, .cleanup:
            return 16 * 1_024 * 1_024
        }
    }
}
