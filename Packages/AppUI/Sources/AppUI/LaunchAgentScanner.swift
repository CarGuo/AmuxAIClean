import Darwin
import Foundation
import LogKit
import ScanKit

/// 传统 launchd plist 的只读扫描合同。
///
/// v2026.07.18：旧实现把目录/文件权限失败、竞态消失和解析失败都压成 nil/空数组，
/// UI 因而把“没有发现”与“没有读到”混为一谈。现在文件系统层返回类型化失败，扫描层
/// 聚合 `items + issues`，由界面明确呈现完整、部分和失败三种状态。

// MARK: - 展示模型

public enum LaunchAgentScope: String, Hashable, Sendable, CaseIterable {
    case user
    case system
    case daemon

    public func directoryPath(home: String) -> String {
        switch self {
        case .user: return "\(home)/Library/LaunchAgents"
        case .system: return "/Library/LaunchAgents"
        case .daemon: return "/Library/LaunchDaemons"
        }
    }

    public var localizationKey: String {
        switch self {
        case .user: return "launch_agent.scope.user"
        case .system: return "launch_agent.scope.system"
        case .daemon: return "launch_agent.scope.daemon"
        }
    }

    public func displayName(locale: Locale) -> String {
        AppLocalization.string(localizationKey, locale: locale)
    }

    /// 非界面兼容入口；用户可见 View 必须显式传当前 locale。
    public var displayName: String { displayName(locale: .current) }
}

public struct LaunchAgentItem: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let label: String
    public let programArguments: [String]
    public let runAtLoad: Bool
    public let fileSize: Int64
    public let scope: LaunchAgentScope

    public init(
        path: String,
        label: String,
        programArguments: [String],
        runAtLoad: Bool,
        fileSize: Int64,
        scope: LaunchAgentScope
    ) {
        self.path = path
        self.label = label
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.fileSize = fileSize
        self.scope = scope
    }
}

// MARK: - 类型化 IO 与完整性证据

public enum LaunchAgentIOOperation: String, Hashable, Sendable {
    case listDirectory
    case readFile
    case readMetadata
}

public enum LaunchAgentIOFailureReason: String, Hashable, Sendable {
    case permissionDenied
    case notFound
    case changedDuringRead
    case unsafeFileType
    case tooLarge
    case cancelled
    case other
}

public struct LaunchAgentIOFailure: Hashable, Sendable {
    public let path: String
    public let operation: LaunchAgentIOOperation
    public let reason: LaunchAgentIOFailureReason
    /// 仅供结构化日志和测试诊断；不得直接展示给用户。
    public let technicalDetail: String?

    public init(
        path: String,
        operation: LaunchAgentIOOperation,
        reason: LaunchAgentIOFailureReason,
        technicalDetail: String? = nil
    ) {
        self.path = path
        self.operation = operation
        self.reason = reason
        self.technicalDetail = technicalDetail
    }
}

public enum LaunchAgentIOResult<Value: Sendable>: Sendable {
    case value(Value)
    case failure(LaunchAgentIOFailure)
}

/// One plist payload plus the size that belongs to that payload generation.
///
/// `metadataFailure` exists only for the legacy/default protocol seam used by injected test file
/// systems: it preserves the previous “parsed item + metadata issue” behavior. Production
/// `DefaultLaunchAgentFS` overrides `readFileSnapshot` with one identity-validated bounded read, so
/// its size is always `data.count` and its metadata failure is nil.
public struct LaunchAgentFileSnapshot: Sendable {
    public let data: Data
    public let fileSize: Int64
    public let metadataFailure: LaunchAgentIOFailure?

    public init(
        data: Data,
        fileSize: Int64,
        metadataFailure: LaunchAgentIOFailure? = nil
    ) {
        self.data = data
        self.fileSize = fileSize
        self.metadataFailure = metadataFailure
    }
}

public enum LaunchAgentScanIssueReason: String, Hashable, Sendable {
    case permissionDenied
    case changedDuringScan
    case readFailed
    case invalidPropertyList
    case missingLabel
    case metadataUnavailable
}

public struct LaunchAgentScanIssue: Hashable, Sendable, Identifiable {
    public var id: String { "\(scope.rawValue)|\(path)|\(reason.rawValue)" }
    public let scope: LaunchAgentScope
    public let path: String
    public let reason: LaunchAgentScanIssueReason

    public init(scope: LaunchAgentScope, path: String, reason: LaunchAgentScanIssueReason) {
        self.scope = scope
        self.path = path
        self.reason = reason
    }
}

public struct LaunchAgentScanResult: Equatable, Sendable {
    public let items: [LaunchAgentItem]
    public let issues: [LaunchAgentScanIssue]
    /// Cancellation is caller control flow, not a synthetic filesystem issue. Keeping it separate
    /// prevents logs/UI from presenting an intentional reload cancellation as a read failure.
    public let wasCancelled: Bool

    public init(
        items: [LaunchAgentItem],
        issues: [LaunchAgentScanIssue],
        wasCancelled: Bool = false
    ) {
        self.items = items
        self.issues = issues
        self.wasCancelled = wasCancelled
    }

    public var isComplete: Bool { issues.isEmpty && !wasCancelled }
}

/// Collection conformance keeps item-centric consumers concise while the enclosing value still
/// carries mandatory completeness evidence. User-facing callers must inspect `issues` as well.
extension LaunchAgentScanResult: RandomAccessCollection {
    public typealias Index = Array<LaunchAgentItem>.Index

    public var startIndex: Index { items.startIndex }
    public var endIndex: Index { items.endIndex }
    public subscript(position: Index) -> LaunchAgentItem { items[position] }
    public func index(after index: Index) -> Index { items.index(after: index) }
    public func index(before index: Index) -> Index { items.index(before: index) }
}

/// 只读文件系统边界。调用方不能通过本协议写入、删除或切换 launchd 服务。
public protocol LaunchAgentFS: Sendable {
    func listDirectory(_ path: String) -> LaunchAgentIOResult<[String]>
    func readFile(_ path: String) -> LaunchAgentIOResult<Data>
    func fileSize(_ path: String) -> LaunchAgentIOResult<Int64>
    func readFileSnapshot(_ path: String) -> LaunchAgentIOResult<LaunchAgentFileSnapshot>
}

public extension LaunchAgentFS {
    /// Compatibility/test-injection seam. It intentionally preserves the old two-call behavior so
    /// existing fake filesystems do not need production fd semantics. This default is not an inode
    /// identity guarantee; production must override it with one bounded snapshot transaction.
    func readFileSnapshot(_ path: String) -> LaunchAgentIOResult<LaunchAgentFileSnapshot> {
        let data: Data
        switch readFile(path) {
        case .value(let value): data = value
        case .failure(let failure): return .failure(failure)
        }
        switch fileSize(path) {
        case .value(let size):
            return .value(LaunchAgentFileSnapshot(data: data, fileSize: size))
        case .failure(let failure):
            return .value(LaunchAgentFileSnapshot(
                data: data,
                fileSize: 0,
                metadataFailure: failure
            ))
        }
    }
}

public struct DefaultLaunchAgentFS: LaunchAgentFS {
    typealias BoundedReader = @Sendable (
        URL,
        Int,
        @Sendable () -> Bool
    ) throws -> Data

    /// `launchd.plist(5)` defines a declarative job dictionary (Label, executable/arguments,
    /// scheduling and resource keys), not a payload container. One MiB leaves ample room for very
    /// large argument/trigger arrays while placing a hard bound far above ordinary KiB-scale job
    /// definitions. ScanKit's generic 16 MiB ceiling is intentionally broader than this format.
    static let maximumPropertyListBytes = 1 * 1_024 * 1_024

    private let shouldCancel: @Sendable () -> Bool
    private let boundedReader: BoundedReader

    public init() {
        shouldCancel = { Task.isCancelled }
        boundedReader = { url, maximumBytes, shouldCancel in
            try BoundedLocalFileReader.read(
                at: url,
                maximumBytes: maximumBytes,
                shouldCancel: shouldCancel
            )
        }
    }

    /// Deterministic seam for proving cancellation/error mapping and exactly-one snapshot read.
    init(
        shouldCancel: @escaping @Sendable () -> Bool,
        boundedReader: @escaping BoundedReader
    ) {
        self.shouldCancel = shouldCancel
        self.boundedReader = boundedReader
    }

    public func listDirectory(_ path: String) -> LaunchAgentIOResult<[String]> {
        do {
            // v2026.07.18: call the authoritative read directly. A fileExists preflight can return
            // false for TCC/EACCES and would collapse “denied” back into “missing”; it also creates
            // a needless TOCTOU window between the probe and the real directory read.
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            return .value(names.map { (path as NSString).appendingPathComponent($0) })
        } catch {
            return classifiedFailure(error, path: path, operation: .listDirectory)
        }
    }

    public func readFile(_ path: String) -> LaunchAgentIOResult<Data> {
        switch readFileSnapshot(path) {
        case .value(let snapshot): return .value(snapshot.data)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// v2026.07.18 P1 root fix: the shared reader lstat/open/fstat checks one regular-file
    /// generation, rejects a final symlink/FIFO, enforces the plist-specific cap, checks
    /// cancellation between chunks, and validates the path again before returning. `Data.count`
    /// therefore belongs to exactly the bytes parsed by the scanner; no second path stat follows.
    public func readFileSnapshot(
        _ path: String
    ) -> LaunchAgentIOResult<LaunchAgentFileSnapshot> {
        do {
            let data = try boundedReader(
                URL(fileURLWithPath: path),
                Self.maximumPropertyListBytes,
                shouldCancel
            )
            return .value(LaunchAgentFileSnapshot(
                data: data,
                fileSize: Int64(data.count)
            ))
        } catch let error as BoundedLocalFileReadError {
            return .failure(boundedFailure(error, path: path))
        } catch {
            return classifiedFailure(error, path: path, operation: .readFile)
        }
    }

    public func fileSize(_ path: String) -> LaunchAgentIOResult<Int64> {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let number = attributes[.size] as? NSNumber else {
                return .failure(.init(
                    path: path,
                    operation: .readMetadata,
                    reason: .other,
                    technicalDetail: "size attribute missing"
                ))
            }
            return .value(number.int64Value)
        } catch {
            return classifiedFailure(error, path: path, operation: .readMetadata)
        }
    }

    private func classifiedFailure<Value: Sendable>(
        _ error: Error,
        path: String,
        operation: LaunchAgentIOOperation
    ) -> LaunchAgentIOResult<Value> {
        let reason: LaunchAgentIOFailureReason
        switch IOErrorClassifier.classify(error) {
        case .permissionDenied:
            reason = .permissionDenied
            GSYLog.debug(.scan, "LaunchAgentFS \(operation.rawValue) permission denied: \(path)")
        case .notFound:
            reason = .notFound
            GSYLog.debug(.scan, "LaunchAgentFS \(operation.rawValue) not found: \(path)")
        case .other:
            reason = .other
            GSYLog.warning(
                .scan,
                "LaunchAgentFS \(operation.rawValue) failed at \(path): \(error.localizedDescription)"
            )
        }
        return .failure(.init(
            path: path,
            operation: operation,
            reason: reason,
            technicalDetail: String(describing: error)
        ))
    }

    private func boundedFailure(
        _ error: BoundedLocalFileReadError,
        path: String
    ) -> LaunchAgentIOFailure {
        let reason: LaunchAgentIOFailureReason
        switch error {
        case .invalidFileURL:
            reason = .other
        case .metadataUnavailable(let stage, let code):
            if Self.isPermissionError(code) {
                reason = .permissionDenied
            } else if code == ENOENT, stage == .initialPath {
                reason = .notFound
            } else if code == ENOENT {
                reason = .changedDuringRead
            } else {
                reason = .other
            }
        case .openFailed(let code):
            if Self.isPermissionError(code) {
                reason = .permissionDenied
            } else if code == ENOENT || code == ELOOP {
                // Initial lstat already succeeded, so disappearance/symlink replacement before
                // open is a generation change rather than an originally missing file.
                reason = .changedDuringRead
            } else {
                reason = .other
            }
        case .readFailed(let code):
            reason = Self.isPermissionError(code) ? .permissionDenied : .other
        case .tooLarge:
            reason = .tooLarge
        case .unsafeType:
            reason = .unsafeFileType
        case .changed:
            reason = .changedDuringRead
        case .cancelled:
            reason = .cancelled
        }
        // v2026.07.18: cancellation is an expected reload control-flow outcome, not a filesystem
        // fault. The scanner carries it as `wasCancelled`; do not emit a misleading warning.
        if reason != .cancelled {
            GSYLog.warning(
                .scan,
                "LaunchAgentFS bounded read rejected path=\(path) reason=\(reason.rawValue) "
                    + "detail=\(String(describing: error))"
            )
        }
        return LaunchAgentIOFailure(
            path: path,
            operation: .readFile,
            reason: reason,
            technicalDetail: String(describing: error)
        )
    }

    private static func isPermissionError(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM
    }
}

// MARK: - 扫描器

public actor LaunchAgentScanner {
    private let fs: any LaunchAgentFS
    private let homeDirectory: String

    public init(
        fs: any LaunchAgentFS = DefaultLaunchAgentFS(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.fs = fs
        self.homeDirectory = homeDirectory
    }

    /// 扫描三个传统 launchd plist 目录。现代 Login & Background Items 不在公开可枚举
    /// 合同内，UI 必须始终披露该覆盖边界，不得把本结果称为“全部启动项”。
    public func scanAll() -> LaunchAgentScanResult {
        var items: [LaunchAgentItem] = []
        var issues: [LaunchAgentScanIssue] = []
        var wasCancelled = false
        for scope in LaunchAgentScope.allCases {
            // v2026.07.18: revision gating normally discards a cancelled result, but the scanner's
            // own value must still be truthful when consumed directly or during a late race.
            // Cancellation before the next scope is incomplete evidence, never a complete empty.
            guard !Task.isCancelled else {
                wasCancelled = true
                break
            }
            let scoped = scan(scope: scope)
            items.append(contentsOf: scoped.items)
            issues.append(contentsOf: scoped.issues)
            if scoped.wasCancelled || Task.isCancelled {
                wasCancelled = true
                break
            }
        }
        items.sort { $0.path < $1.path }
        issues.sort {
            if $0.path == $1.path { return $0.reason.rawValue < $1.reason.rawValue }
            return $0.path < $1.path
        }
        return LaunchAgentScanResult(
            items: items,
            issues: issues,
            wasCancelled: wasCancelled
        )
    }

    func scan(scope: LaunchAgentScope) -> LaunchAgentScanResult {
        let directory = scope.directoryPath(home: homeDirectory)
        guard !Task.isCancelled else {
            return LaunchAgentScanResult(items: [], issues: [], wasCancelled: true)
        }
        let children: [String]
        switch fs.listDirectory(directory) {
        case .value(let values):
            children = values
        case .failure(let failure):
            guard let issueReason = issueReason(for: failure) else {
                return LaunchAgentScanResult(items: [], issues: [], wasCancelled: true)
            }
            // A missing standard directory is a valid empty scope. Every other failure is evidence
            // that the scope is incomplete and must survive to presentation.
            guard failure.reason != .notFound else {
                return LaunchAgentScanResult(items: [], issues: [])
            }
            return LaunchAgentScanResult(
                items: [],
                issues: [.init(
                    scope: scope,
                    path: directory,
                    reason: issueReason
                )]
            )
        }

        var items: [LaunchAgentItem] = []
        var issues: [LaunchAgentScanIssue] = []
        items.reserveCapacity(children.count)
        for path in children where path.hasSuffix(".plist") {
            guard !Task.isCancelled else {
                return LaunchAgentScanResult(
                    items: items,
                    issues: issues,
                    wasCancelled: true
                )
            }
            let parsed = parsePlist(at: path, scope: scope)
            if let item = parsed.item { items.append(item) }
            issues.append(contentsOf: parsed.issues)
            if parsed.wasCancelled || Task.isCancelled {
                return LaunchAgentScanResult(
                    items: items,
                    issues: issues,
                    wasCancelled: true
                )
            }
        }
        return LaunchAgentScanResult(items: items, issues: issues)
    }

    private func parsePlist(
        at path: String,
        scope: LaunchAgentScope
    ) -> (
        item: LaunchAgentItem?,
        issues: [LaunchAgentScanIssue],
        wasCancelled: Bool
    ) {
        let snapshot: LaunchAgentFileSnapshot
        switch fs.readFileSnapshot(path) {
        case .value(let value):
            snapshot = value
        case .failure(let failure):
            guard let issueReason = issueReason(for: failure) else {
                return (nil, [], true)
            }
            return (
                nil,
                [.init(scope: scope, path: path, reason: issueReason)],
                false
            )
        }

        let dictionary: [String: Any]
        do {
            let raw = try PropertyListSerialization.propertyList(
                from: snapshot.data,
                options: [],
                format: nil
            )
            guard let parsed = raw as? [String: Any] else {
                GSYLog.warning(.scan, "LaunchAgent plist root is not a dictionary: \(path)")
                return (
                    nil,
                    [.init(scope: scope, path: path, reason: .invalidPropertyList)],
                    false
                )
            }
            dictionary = parsed
        } catch {
            GSYLog.warning(.scan, "LaunchAgent plist decode failed at \(path): \(error.localizedDescription)")
            return (
                nil,
                [.init(scope: scope, path: path, reason: .invalidPropertyList)],
                false
            )
        }

        guard let label = dictionary["Label"] as? String, !label.isEmpty else {
            return (nil, [.init(scope: scope, path: path, reason: .missingLabel)], false)
        }

        var issues: [LaunchAgentScanIssue] = []
        var wasCancelled = false
        if let failure = snapshot.metadataFailure {
            if let issueReason = issueReason(for: failure) {
                issues.append(.init(
                    scope: scope,
                    path: path,
                    // v2026.07.18：metadata 与 directory/readFile 必须保留同一套权限来源；
                    // 旧分支把 permissionDenied 压成 metadataUnavailable，UI 无法给出正确引导。
                    reason: issueReason
                ))
            } else {
                wasCancelled = true
            }
        }

        return (
            LaunchAgentItem(
                path: path,
                label: label,
                programArguments: Self.extractProgramArguments(from: dictionary),
                runAtLoad: (dictionary["RunAtLoad"] as? Bool) ?? false,
                fileSize: snapshot.fileSize,
                scope: scope
            ),
            issues,
            wasCancelled
        )
    }

    /// `nil` is deliberate caller control flow for cancellation; it must never be projected into
    /// the issue collection that drives read-failure logging and UI.
    private func issueReason(
        for failure: LaunchAgentIOFailure
    ) -> LaunchAgentScanIssueReason? {
        switch failure.reason {
        case .permissionDenied: return .permissionDenied
        case .notFound, .changedDuringRead: return .changedDuringScan
        case .unsafeFileType, .tooLarge, .other: return .readFailed
        case .cancelled: return nil
        }
    }

    static func extractProgramArguments(from dictionary: [String: Any]) -> [String] {
        if let arguments = dictionary["ProgramArguments"] as? [String] {
            return arguments
        }
        if let program = dictionary["Program"] as? String, !program.isEmpty {
            return [program]
        }
        return []
    }
}
