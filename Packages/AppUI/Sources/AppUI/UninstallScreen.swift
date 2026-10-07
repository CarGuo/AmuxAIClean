import SwiftUI
import Foundation
import Dispatch
import Darwin
import LogKit
import SafetyKit
import ScanKit

// MARK: - 数据模型

/// 已安装的 .app 条目（在受限应用根内递归发现）。
/// A no-follow filesystem identity frozen while the installed-App root descriptor is open.
///
/// v2026.07.18: path + Bundle ID is not an object identity. The selected bundle can be replaced
/// by another directory (or a symlink) with the same identifier between list discovery and the
/// uninstall handoff. Production discovery carries this device/inode capability through every
/// later validation boundary; compatibility fixtures may omit it, but never gain that authority.
public struct InstalledAppFileIdentity: Hashable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }

    init(metadata: stat) {
        self.init(
            deviceID: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }

    func matches(_ objectIdentity: TrashObjectIdentity) -> Bool {
        deviceID == objectIdentity.device && inode == objectIdentity.inode
    }
}

public struct InstalledApp: Hashable, Sendable, Identifiable {
    public var id: String { appURL.path }
    public let appURL: URL
    public let metadata: AppMetadata
    public let fileIdentity: InstalledAppFileIdentity?

    public init(
        appURL: URL,
        metadata: AppMetadata,
        fileIdentity: InstalledAppFileIdentity? = nil
    ) {
        self.appURL = appURL
        self.metadata = metadata
        self.fileIdentity = fileIdentity
    }
}

/// 已安装 App 清单的发现缺口。`rootPath` 始终保留来源根；单个损坏/不可读 bundle
/// 使用 `path` 精确指向该 App，根枚举失败则两者相同。
public struct InstalledAppDiscoveryIssue: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case permissionDenied
        case enumerationFailed
        case metadataUnavailable
        case depthLimitExceeded
        case traversalBudgetExceeded
        case timeLimitExceeded
        case cancelled
    }

    public let rootPath: String
    public let path: String
    public let reason: Reason

    public init(rootPath: String, path: String, reason: Reason) {
        self.rootPath = rootPath
        self.path = path
        self.reason = reason
    }
}

public enum InstalledAppDiscoveryAuthority: String, Sendable, Equatable {
    case exact
    case lowerBound
}

/// `/Applications` 与 `~/Applications` 的一次联合快照。它保留路径身份不同的多份安装，
/// 只对同一个磁盘 bundle 身份（device + inode）去重。任何权限、metadata、预算、
/// 截止时间或取消缺口都会把计数权威降为 `lowerBound`；空 Apps 不能脱离
/// 该权威单独解释。
public struct InstalledAppDiscoveryResult: Sendable, Equatable, RandomAccessCollection {
    public typealias Element = InstalledApp
    public typealias Index = Int

    public let apps: [InstalledApp]
    public let incompleteIssues: [InstalledAppDiscoveryIssue]

    public var authority: InstalledAppDiscoveryAuthority {
        incompleteIssues.isEmpty ? .exact : .lowerBound
    }
    public var isComplete: Bool { authority == .exact }
    public var startIndex: Int { apps.startIndex }
    public var endIndex: Int { apps.endIndex }
    public subscript(position: Int) -> InstalledApp { apps[position] }

    public init(apps: [InstalledApp], incompleteIssues: [InstalledAppDiscoveryIssue] = []) {
        self.apps = apps
        self.incompleteIssues = Array(Set(incompleteIssues)).sorted {
            if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.reason.rawValue < $1.reason.rawValue
        }
    }
}

struct InstalledAppDiscoveryLimits: Sendable, Equatable {
    /// 根目录为 0；这个值限制可继续下沉的容器目录层数。
    let maxContainerDepth: Int
    let maxVisitedEntries: Int
    let maxDuration: TimeInterval

    init(
        maxContainerDepth: Int = 8,
        maxVisitedEntries: Int = 100_000,
        maxDuration: TimeInterval = 3
    ) {
        self.maxContainerDepth = max(0, maxContainerDepth)
        self.maxVisitedEntries = max(0, maxVisitedEntries)
        // NaN/negative durations must fail closed at the first traversal boundary. Positive
        // infinity is the one explicit representation of "no wall-clock deadline".
        self.maxDuration = maxDuration.isNaN || maxDuration <= 0 ? 0 : maxDuration
    }
}

/// GCD 上的同步文件系统扫描无法读取 Swift Task 取消上下文。
/// v2026.07.18：一轮应用发现共享这个显式 token；`@unchecked Sendable` 仅包含一个
/// 由 `NSLock` 保护的 Boolean，所有读写都在锁内。
final class InstalledAppDiscoveryCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum InstalledApplicationEntryKind: Sendable, Equatable {
    case directory
    case symbolicLink
    case other
}

/// v2026.07.18 root-cause record: canonicalizing a pathname before queueing it did not bind the
/// later `opendir` to that object. A rename-to-symlink between those calls could traverse a new
/// tree. Every queued directory now carries the device/inode obtained from no-follow fd metadata.
typealias InstalledApplicationDirectoryIdentity = InstalledAppFileIdentity

struct InstalledApplicationDirectoryEntry: Sendable, Equatable {
    let name: String
    let path: String
    let kind: InstalledApplicationEntryKind
    let directoryIdentity: InstalledApplicationDirectoryIdentity?
}

enum InstalledApplicationDirectoryTermination: Sendable, Equatable {
    case complete
    case entryLimit
    case timeLimit
    case cancelled
}

struct InstalledApplicationReaderIssue: Sendable, Equatable {
    let path: String
    let reason: InstalledAppDiscoveryIssue.Reason
}

struct InstalledApplicationDirectoryListing: Sendable, Equatable {
    let entries: [InstalledApplicationDirectoryEntry]
    let issues: [InstalledApplicationReaderIssue]
    let visitedEntryCount: Int
    let termination: InstalledApplicationDirectoryTermination
}

protocol InstalledApplicationRootReading: Sendable {
    /// nil 只表示明确的 ENOENT/非目录；权限、symlink 和 metadata 错误必须
    /// throw，不能折叠为空根。默认实现使用 no-follow open + fstat 冻结对象身份。
    func directoryIdentity(at path: String) throws -> InstalledApplicationDirectoryIdentity?
    /// 单层、逐项、有界枚举。读取器必须在每个 dirent 边界检查取消和截止时间。
    func directoryEntries(
        at path: String,
        expectedIdentity: InstalledApplicationDirectoryIdentity,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        cancellationToken: InstalledAppDiscoveryCancellationToken
    ) throws -> InstalledApplicationDirectoryListing
    func isPackageDirectory(at path: String) throws -> Bool
}

struct DefaultInstalledApplicationRootReader: InstalledApplicationRootReading {
    func directoryIdentity(at path: String) throws -> InstalledApplicationDirectoryIdentity? {
        var linkMetadata = stat()
        guard lstat(path, &linkMetadata) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let linkType = linkMetadata.st_mode & S_IFMT
        if linkType == S_IFLNK {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
        }
        guard linkType == S_IFDIR else { return nil }

        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (openedMetadata.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return InstalledApplicationDirectoryIdentity(metadata: openedMetadata)
    }

    func directoryEntries(
        at path: String,
        expectedIdentity: InstalledApplicationDirectoryIdentity,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        cancellationToken: InstalledAppDiscoveryCancellationToken
    ) throws -> InstalledApplicationDirectoryListing {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            return unavailableListing(
                path: path,
                error: error,
                metadataStage: true
            )
        }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            return unavailableListing(path: path, error: error, metadataStage: true)
        }
        guard (openedMetadata.st_mode & S_IFMT) == S_IFDIR,
              InstalledApplicationDirectoryIdentity(metadata: openedMetadata) == expectedIdentity else {
            close(descriptor)
            return InstalledApplicationDirectoryListing(
                entries: [],
                issues: [.init(path: path, reason: .metadataUnavailable)],
                visitedEntryCount: 0,
                termination: .complete
            )
        }
        guard let directory = fdopendir(descriptor) else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(descriptor)
            throw error
        }
        // fdopendir 成功后 DIR 拥有 descriptor；closedir 是唯一关闭边界。
        defer { closedir(directory) }
        let directoryDescriptor = dirfd(directory)
        guard directoryDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var entries: [InstalledApplicationDirectoryEntry] = []
        var issues: [InstalledApplicationReaderIssue] = []
        var visitedEntryCount = 0
        var termination: InstalledApplicationDirectoryTermination = .complete

        while true {
            if cancellationToken.isCancelled {
                termination = .cancelled
                break
            }
            if DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds {
                termination = .timeLimit
                break
            }

            errno = 0
            guard let rawEntry = readdir(directory) else {
                if errno != 0 {
                    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    issues.append(.init(
                        path: path,
                        reason: installedAppDiscoveryReason(for: error, metadataStage: false)
                    ))
                }
                break
            }

            var nameStorage = rawEntry.pointee.d_name
            let nameLength = Int(rawEntry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &nameStorage) { bytes in
                String(decoding: bytes.prefix(nameLength), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            guard visitedEntryCount < maximumEntries else {
                termination = .entryLimit
                break
            }
            visitedEntryCount += 1

            let childPath = (path as NSString).appendingPathComponent(name)
            var metadata = stat()
            let metadataResult = name.withCString { namePointer in
                fstatat(directoryDescriptor, namePointer, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard metadataResult == 0 else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                issues.append(.init(
                    path: childPath,
                    reason: installedAppDiscoveryReason(for: error, metadataStage: true)
                ))
                continue
            }
            let fileType = metadata.st_mode & S_IFMT
            let kind: InstalledApplicationEntryKind
            switch fileType {
            case S_IFDIR:
                kind = .directory
            case S_IFLNK:
                kind = .symbolicLink
            default:
                kind = .other
            }
            entries.append(.init(
                name: name,
                path: childPath,
                kind: kind,
                directoryIdentity: kind == .directory
                    ? InstalledApplicationDirectoryIdentity(metadata: metadata)
                    : nil
            ))
        }

        return InstalledApplicationDirectoryListing(
            entries: entries,
            issues: issues,
            visitedEntryCount: visitedEntryCount,
            termination: termination
        )
    }

    func isPackageDirectory(at path: String) throws -> Bool {
        // `.localized` 是 macOS 的本地化容器/标记语义，不是需要剪枝的 bundle。
        if URL(fileURLWithPath: path).lastPathComponent.caseInsensitiveCompare(".localized")
            == .orderedSame {
            return false
        }
        return try URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.isPackageKey])
            .isPackage ?? false
    }

    private func unavailableListing(
        path: String,
        error: Error,
        metadataStage: Bool
    ) -> InstalledApplicationDirectoryListing {
        InstalledApplicationDirectoryListing(
            entries: [],
            issues: [.init(
                path: path,
                reason: installedAppDiscoveryReason(for: error, metadataStage: metadataStage)
            )],
            visitedEntryCount: 0,
            termination: .complete
        )
    }
}

private func installedAppDiscoveryReason(
    for error: Error,
    metadataStage: Bool
) -> InstalledAppDiscoveryIssue.Reason {
    func containsPermission(_ current: Error) -> Bool {
        if let bounded = current as? BoundedLocalFileReadError,
           let code = bounded.posixErrorCode {
            return code == EACCES || code == EPERM
        }
        let nsError = current as NSError
        if (nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)))
            || (nsError.domain == NSCocoaErrorDomain
                && nsError.code == CocoaError.fileReadNoPermission.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return containsPermission(underlying)
        }
        return false
    }
    if containsPermission(error) { return .permissionDenied }
    return metadataStage ? .metadataUnavailable : .enumerationFailed
}

private struct InstalledApplicationDiscoveryWorker: Sendable {
    private struct PendingDirectory: Sendable {
        let rootPath: String
        let path: String
        let depth: Int
        let identity: InstalledApplicationDirectoryIdentity
    }

    let applicationRoots: [String]
    let rootReader: any InstalledApplicationRootReading
    let limits: InstalledAppDiscoveryLimits

    func run(cancellationToken: InstalledAppDiscoveryCancellationToken) -> InstalledAppDiscoveryResult {
        let deadline = makeDeadline(maxDuration: limits.maxDuration)
        var apps: [InstalledApp] = []
        var issues: [InstalledAppDiscoveryIssue] = []
        var seenAppIdentities = Set<InstalledApplicationDirectoryIdentity>()
        var seenDirectoryIdentities = Set<InstalledApplicationDirectoryIdentity>()
        var visitedEntries = 0

        rootLoop: for root in applicationRoots {
            if cancellationToken.isCancelled {
                issues.append(.init(rootPath: root, path: root, reason: .cancelled))
                break
            }
            if hasReached(deadline) {
                issues.append(.init(rootPath: root, path: root, reason: .timeLimitExceeded))
                break
            }

            let rootIdentity: InstalledApplicationDirectoryIdentity
            do {
                guard let identity = try rootReader.directoryIdentity(at: root) else { continue }
                rootIdentity = identity
            } catch {
                issues.append(.init(
                    rootPath: root,
                    path: root,
                    reason: installedAppDiscoveryReason(for: error, metadataStage: false)
                ))
                continue
            }
            guard seenDirectoryIdentities.insert(rootIdentity).inserted else { continue }
            var pending = [PendingDirectory(
                rootPath: root,
                path: root,
                depth: 0,
                identity: rootIdentity
            )]

            while let directory = pending.popLast() {
                if cancellationToken.isCancelled {
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: .cancelled
                    ))
                    break rootLoop
                }
                if hasReached(deadline) {
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: .timeLimitExceeded
                    ))
                    break rootLoop
                }

                let remainingEntries = limits.maxVisitedEntries - visitedEntries
                guard remainingEntries > 0 else {
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: .traversalBudgetExceeded
                    ))
                    break rootLoop
                }

                let listing: InstalledApplicationDirectoryListing
                do {
                    listing = try rootReader.directoryEntries(
                        at: directory.path,
                        expectedIdentity: directory.identity,
                        maximumEntries: remainingEntries,
                        deadlineUptimeNanoseconds: deadline,
                        cancellationToken: cancellationToken
                    )
                } catch {
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: installedAppDiscoveryReason(for: error, metadataStage: false)
                    ))
                    continue
                }
                visitedEntries += listing.visitedEntryCount
                issues.append(contentsOf: listing.issues.map {
                    .init(rootPath: directory.rootPath, path: $0.path, reason: $0.reason)
                })

                var processingTermination: InstalledApplicationDirectoryTermination?
                for entry in listing.entries {
                    if cancellationToken.isCancelled {
                        processingTermination = .cancelled
                        break
                    }
                    if hasReached(deadline) {
                        processingTermination = .timeLimit
                        break
                    }
                    // Never follow a child symlink. This closes both root escape and loop paths;
                    // a configured symlink root is likewise reported as typed incomplete.
                    guard entry.kind != .symbolicLink else { continue }
                    let entryURL = URL(fileURLWithPath: entry.path, isDirectory: entry.kind == .directory)
                        .standardizedFileURL

                    if entry.name.lowercased().hasSuffix(".app") {
                        guard entry.kind == .directory,
                              let appIdentity = entry.directoryIdentity else {
                            issues.append(.init(
                                rootPath: directory.rootPath,
                                path: entry.path,
                                reason: .metadataUnavailable
                            ))
                            continue
                        }
                        guard verifyIdentity(
                            appIdentity,
                            at: entry.path,
                            rootPath: directory.rootPath,
                            issues: &issues
                        ) else {
                            continue
                        }
                        do {
                            let metadata = try AppMetadata.read(
                                appURL: entryURL,
                                shouldCancel: { cancellationToken.isCancelled }
                            )
                            // Re-open after metadata parsing. A rename/symlink replacement during
                            // the pathname-based Info.plist read invalidates the item; it is never
                            // returned as an installation from the replacement tree.
                            guard verifyIdentity(
                                appIdentity,
                                at: entry.path,
                                rootPath: directory.rootPath,
                                issues: &issues
                            ) else {
                                continue
                            }
                            guard seenAppIdentities.insert(appIdentity).inserted else { continue }
                            apps.append(InstalledApp(
                                appURL: entryURL,
                                metadata: metadata,
                                fileIdentity: appIdentity
                            ))
                        } catch {
                            issues.append(.init(
                                rootPath: directory.rootPath,
                                path: entry.path,
                                reason: installedAppDiscoveryReason(for: error, metadataStage: true)
                            ))
                        }
                        // `.app` is terminal even if metadata is unavailable: never discover
                        // helpers or nested app bundles as independent installations.
                        continue
                    }

                    guard entry.kind == .directory else { continue }
                    guard let childIdentity = entry.directoryIdentity,
                          verifyIdentity(
                            childIdentity,
                            at: entry.path,
                            rootPath: directory.rootPath,
                            issues: &issues
                          ) else {
                        if entry.directoryIdentity == nil {
                            issues.append(.init(
                                rootPath: directory.rootPath,
                                path: entry.path,
                                reason: .metadataUnavailable
                            ))
                        }
                        continue
                    }

                    let isPackage: Bool
                    do {
                        isPackage = try rootReader.isPackageDirectory(at: entry.path)
                    } catch {
                        issues.append(.init(
                            rootPath: directory.rootPath,
                            path: entry.path,
                            reason: installedAppDiscoveryReason(for: error, metadataStage: true)
                        ))
                        continue
                    }
                    // Package probing is pathname based. Re-open immediately afterwards so a
                    // replacement cannot turn that probe into admission for a different tree.
                    guard verifyIdentity(
                        childIdentity,
                        at: entry.path,
                        rootPath: directory.rootPath,
                        issues: &issues
                    ) else {
                        continue
                    }
                    if isPackage { continue }

                    guard directory.depth < limits.maxContainerDepth else {
                        issues.append(.init(
                            rootPath: directory.rootPath,
                            path: entry.path,
                            reason: .depthLimitExceeded
                        ))
                        continue
                    }
                    guard seenDirectoryIdentities.insert(childIdentity).inserted else { continue }
                    pending.append(.init(
                        rootPath: directory.rootPath,
                        path: entry.path,
                        depth: directory.depth + 1,
                        identity: childIdentity
                    ))
                }

                if let processingTermination {
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: processingTermination == .cancelled ? .cancelled : .timeLimitExceeded
                    ))
                    break rootLoop
                }

                switch listing.termination {
                case .complete:
                    break
                case .entryLimit:
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: .traversalBudgetExceeded
                    ))
                    break rootLoop
                case .timeLimit:
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: .timeLimitExceeded
                    ))
                    break rootLoop
                case .cancelled:
                    issues.append(.init(
                        rootPath: directory.rootPath,
                        path: directory.path,
                        reason: .cancelled
                    ))
                    break rootLoop
                }
            }
        }

        apps.sort {
            let comparison = $0.metadata.appName.localizedCaseInsensitiveCompare($1.metadata.appName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.appURL.path < $1.appURL.path
        }
        return InstalledAppDiscoveryResult(apps: apps, incompleteIssues: issues)
    }

    private func makeDeadline(maxDuration: TimeInterval) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard maxDuration > 0, !maxDuration.isNaN else { return now }
        if maxDuration == .infinity { return UInt64.max }
        let requested = maxDuration * 1_000_000_000
        guard requested.isFinite, requested < Double(UInt64.max - now) else {
            return UInt64.max
        }
        return now + UInt64(requested.rounded(.up))
    }

    private func hasReached(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private func verifyIdentity(
        _ expectedIdentity: InstalledApplicationDirectoryIdentity,
        at path: String,
        rootPath: String,
        issues: inout [InstalledAppDiscoveryIssue]
    ) -> Bool {
        do {
            guard try rootReader.directoryIdentity(at: path) == expectedIdentity else {
                issues.append(.init(
                    rootPath: rootPath,
                    path: path,
                    reason: .metadataUnavailable
                ))
                return false
            }
            return true
        } catch {
            issues.append(.init(
                rootPath: rootPath,
                path: path,
                reason: installedAppDiscoveryReason(for: error, metadataStage: true)
            ))
            return false
        }
    }
}

struct UninstallCandidateTerminalState: Equatable, Sendable {
    let candidates: [UninstallCandidate]
    let checked: Set<String>
    let apps: [InstalledApp]
    let selectedApp: InstalledApp?

    init(
        candidates: [UninstallCandidate],
        checked: Set<String>,
        apps: [InstalledApp] = [],
        selectedApp: InstalledApp? = nil
    ) {
        self.candidates = candidates
        self.checked = checked
        self.apps = apps
        self.selectedApp = selectedApp
    }
}

enum UninstallCandidateTerminalProjection {
    static func applying(
        succeededPaths: Set<String>,
        to state: UninstallCandidateTerminalState
    ) -> UninstallCandidateTerminalState {
        let matcher = DeletionPresentationPathMatcher(paths: Array(succeededPaths))
        let remainingCandidates = state.candidates.filter { !matcher.contains($0.path) }
        let remainingChecked = Set(state.checked.filter { !matcher.contains($0) })
        let remainingApps = state.apps.filter { !matcher.contains($0.appURL.path) }
        let nextSelectedApp: InstalledApp?
        if let selected = state.selectedApp {
            if matcher.contains(selected.appURL.path) {
                nextSelectedApp = remainingCandidates.isEmpty ? remainingApps.first : selected
            } else {
                nextSelectedApp = selected
            }
        } else {
            nextSelectedApp = nil
        }
        return UninstallCandidateTerminalState(
            candidates: remainingCandidates,
            checked: remainingChecked,
            apps: remainingApps,
            selectedApp: nextSelectedApp
        )
    }
}

/// v2026.07.17：卸载候选的展示值和删除资格必须消费同一份 typed snapshot。
/// 预算截断/枚举失败的 bytes 是下界，不能因为路径匹配正确就自动获得删除资格。
enum UninstallDeletionSelectionPolicy {
    static func isSelectable(_ candidate: UninstallCandidate) -> Bool {
        candidate.hasCompleteSnapshot && candidate.hasStableDeletionIdentity
    }

    static func selectablePaths(in candidates: [UninstallCandidate]) -> Set<String> {
        Set(candidates.lazy.filter(isSelectable).map(\.path))
    }

    static func canSubmit(
        _ candidates: [UninstallCandidate],
        discoveryIssues: [UninstallDiscoveryIssue] = []
    ) -> Bool {
        discoveryIssues.isEmpty && !candidates.isEmpty && candidates.allSatisfy(isSelectable)
    }

    static func interactionSnapshot(
        for candidate: UninstallCandidate,
        runningBundleIDPrefix: String
    ) -> DeletionInteractionCandidateSnapshot {
        DeletionInteractionCandidateSnapshot(
            path: candidate.path,
            title: URL(fileURLWithPath: candidate.path).lastPathComponent,
            isDirectory: candidate.isDirectory,
            bytes: candidate.bytes,
            fileCount: candidate.fileCount,
            runningBundleIDPrefix: runningBundleIDPrefix,
            accessEvidence: accessEvidence(for: candidate),
            sourceObjectIdentity: candidate.objectIdentity
        )
    }

    private static func accessEvidence(for candidate: UninstallCandidate) -> DeletionAccessEvidence {
        guard !candidate.hasCompleteSnapshot else { return .complete }
        let hasPermissionIssue = candidate.snapshotIssues.contains { issue in
            issue.reason == .permissionDenied
        }
        return .incomplete(hasPermissionIssue ? .permissionDenied : .incompleteEnumeration)
    }
}

/// UI and deletion consume this one authority projection. pkg receipts are only one source; a
/// primary-root permission failure, Spotlight timeout, identity mismatch, or partial snapshot must
/// produce the same visible lower-bound state and block ordinary deletion.
enum UninstallCandidateDiscoveryPresentation {
    enum EmptyState: Sendable, Equatable {
        case exactEmpty
        case incompleteEmpty
    }

    static func emptyState(
        candidates: [UninstallCandidate],
        issues: [UninstallDiscoveryIssue]
    ) -> EmptyState? {
        guard candidates.isEmpty else { return nil }
        return issues.isEmpty ? .exactEmpty : .incompleteEmpty
    }

    static func noticeCount(_ issues: [UninstallDiscoveryIssue]) -> Int {
        issues.count
    }

    static func allowsDeletion(
        candidates: [UninstallCandidate],
        issues: [UninstallDiscoveryIssue]
    ) -> Bool {
        UninstallDeletionSelectionPolicy.canSubmit(
            candidates,
            discoveryIssues: issues
        )
    }
}

/// A confirmed uninstall request is valid only for the exact app selection that produced it.
/// The View checks this boundary when the user confirms, after the sheet has dismissed, and
/// immediately before the typed authorization reaches the recycle submit boundary.
enum UninstallDeletionSubmissionGate {
    enum Decision: Sendable, Equatable {
        case current
        case cancelled([DeletionPreflight.Rejection])
    }

    static func evaluate(
        requestAppID: String,
        requestSelectionRevision: UInt64,
        boundSnapshotIdentity: DeletionSnapshotIdentity,
        currentAppID: String?,
        currentScanSessionID: UUID,
        currentSelectionRevision: UInt64,
        paths: [String]
    ) -> Decision {
        guard !requestAppID.isEmpty,
              boundSnapshotIdentity.categoryID == requestAppID,
              boundSnapshotIdentity.sessionID == currentScanSessionID,
              boundSnapshotIdentity.revision == requestSelectionRevision,
              currentAppID == requestAppID,
              currentSelectionRevision == requestSelectionRevision else {
            return .cancelled(paths.map {
                .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
            })
        }
        return .current
    }
}

/// Revision-owned publication gate for one selected App's candidate scan.
///
/// v2026.07.17 root-cause record: cancelling an old `Task` does not guarantee that its body
/// has already started. The old implementation published `isLoadingCandidates = true` and
/// cleared the visible rows *inside* that asynchronous body. A cancelled A task could therefore
/// start after B had been selected, erase B's rows, then return at its cancellation guard without
/// clearing the spinner. The selection callback now publishes the start state synchronously and
/// every terminal path must claim this exact App + session + revision before touching the UI.
struct UninstallCandidateLoadIdentity: Sendable, Equatable {
    let appID: String
    let scanSessionID: UUID
    let selectionRevision: UInt64
}

struct UninstallCandidateLoadGate: Sendable, Equatable {
    enum CurrentCompletion: Sendable, Equatable {
        case publishResult
        case cancelled
    }

    private(set) var current: UninstallCandidateLoadIdentity?

    mutating func begin(_ identity: UninstallCandidateLoadIdentity) {
        current = identity
    }

    mutating func invalidate() {
        current = nil
    }

    mutating func completeIfCurrent(
        _ identity: UninstallCandidateLoadIdentity,
        selectedAppID: String?,
        scanSessionID: UUID,
        selectionRevision: UInt64,
        taskWasCancelled: Bool
    ) -> CurrentCompletion? {
        guard current == identity,
              selectedAppID == identity.appID,
              scanSessionID == identity.scanSessionID,
              selectionRevision == identity.selectionRevision else {
            return nil
        }
        current = nil
        return taskWasCancelled ? .cancelled : .publishResult
    }
}

/// Revision owner for the installed-App list. This is separate from candidate selection because
/// refreshes can overlap selection changes and must not let an older `/Applications` snapshot
/// overwrite a newer one or close its spinner.
struct UninstallAppListLoadIdentity: Sendable, Equatable {
    let operationID: UUID
    let revision: UInt64
}

struct UninstallAppListLoadGate: Sendable, Equatable {
    private(set) var current: UninstallAppListLoadIdentity?

    mutating func begin(_ identity: UninstallAppListLoadIdentity) { current = identity }
    mutating func invalidate() { current = nil }

    mutating func finishIfCurrent(
        _ identity: UninstallAppListLoadIdentity,
        taskWasCancelled: Bool
    ) -> Bool? {
        guard current == identity else { return nil }
        current = nil
        return !taskWasCancelled
    }
}

struct UninstallExecutionOwner: Sendable, Equatable, Identifiable {
    let id: UUID
    let appID: String
    let scanSessionID: UUID
    let selectionRevision: UInt64
}

struct UninstallExecutionStatus: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing
        case finalValidation
        case submitting
        case diagnosingItems
        case finalizing

        func localizedTitle(locale: Locale) -> String {
            let key: String
            switch self {
            case .preparing: key = "uninstall.execution.preparing"
            case .finalValidation: key = "uninstall.execution.validating"
            case .submitting: key = "uninstall.execution.submitting"
            case .diagnosingItems: key = "uninstall.execution.diagnosing"
            case .finalizing: key = "uninstall.execution.finalizing"
            }
            return AppLocalization.string(key, locale: locale)
        }
    }

    let phase: Phase
    let completedItems: Int
    let totalItems: Int
    let currentPath: String?

    static func preparing(totalItems: Int) -> UninstallExecutionStatus {
        .init(
            phase: .preparing,
            completedItems: 0,
            totalItems: max(0, totalItems),
            currentPath: nil
        )
    }
}

enum UninstallExecutionProgressReducer {
    static func reduce(
        current: UninstallExecutionStatus,
        event: DeletionExecutionProgress,
        eventOwner: UninstallExecutionOwner,
        currentOwner: UninstallExecutionOwner?,
        currentAppID: String?,
        currentScanSessionID: UUID,
        currentSelectionRevision: UInt64
    ) -> UninstallExecutionStatus {
        guard currentOwner == eventOwner,
              currentAppID == eventOwner.appID,
              currentScanSessionID == eventOwner.scanSessionID,
              currentSelectionRevision == eventOwner.selectionRevision,
              case .trash(let progress) = event,
              progress.totalItems == current.totalItems,
              progress.completedItems >= current.completedItems else {
            return current
        }
        let phase: UninstallExecutionStatus.Phase
        switch progress.phase {
        case .finalValidation: phase = .finalValidation
        case .submitting: phase = .submitting
        case .diagnosingItems: phase = .diagnosingItems
        case .finalizing: phase = .finalizing
        }
        // v2026.07.17: batch execution may legitimately alternate
        // submitting -> diagnosing one failed item -> submitting the next batch. Treat only
        // final validation and finalizing as ordered boundaries; counts stay monotonic.
        let acceptsPhase: Bool = switch (current.phase, phase) {
        case (.finalizing, .finalizing): true
        case (.finalizing, _): false
        case (.preparing, _): true
        case (.finalValidation, .finalValidation),
             (.finalValidation, .submitting),
             (.finalValidation, .diagnosingItems),
             (.finalValidation, .finalizing): true
        case (.submitting, .submitting),
             (.submitting, .diagnosingItems),
             (.submitting, .finalizing): true
        case (.diagnosingItems, .submitting),
             (.diagnosingItems, .diagnosingItems),
             (.diagnosingItems, .finalizing): true
        case (_, .finalValidation): false
        case (_, .preparing): false
        }
        guard acceptsPhase else { return current }
        return .init(
            phase: phase,
            completedItems: progress.completedItems,
            totalItems: progress.totalItems,
            currentPath: progress.currentPath
        )
    }
}

private struct UninstallExecutionSheet: View {
    @Environment(\.locale) private var locale

    let status: UninstallExecutionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("uninstall.execution.title", bundle: .module)
                        .font(.title3.bold())
                    Text("uninstall.execution.subtitle", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                if status.totalItems > 0
                    && (status.phase == .submitting || status.phase == .diagnosingItems) {
                    ProgressView(
                        value: Double(status.completedItems),
                        total: Double(status.totalItems)
                    )
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(status.phase.localizedTitle(locale: locale))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if status.totalItems > 0 {
                        Text("\(status.completedItems) / \(status.totalItems)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let path = status.currentPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Text("uninstall.execution.safety_note", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        // v2026.07.17: Preserve the execution sheet geometry through SwiftUI's valid
        // flexible-frame overload instead of the nonexistent width/minHeight combination.
        .frame(minWidth: 540, maxWidth: 540, minHeight: 270)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uninstall.execution-sheet")
    }
}

// MARK: - Store

/// 卸载视图的状态 actor —— 把 IO/扫描搬出主线程，UI 只 await 它。
///
/// 设计要点：
/// - 在 `/Applications` 与 `~/Applications` 内做有深度/数量/时间上限的递归发现
/// - `.app` 立即收集并剪枝，其它 package/bundle 目录剪枝，子符号链接永不跟随
/// - 同一 device/inode bundle 去重，但保留同 Bundle ID 的不同安装路径
/// - 任何枚举、metadata、权限、预算、超时或取消保留 typed incomplete，不伪装精确数
/// - POSIX 遍历运行在 utility Dispatch worker，不占用 Swift cooperative executor
/// - 候选项委托给已有的 `AppUninstaller.candidatesAsync(for:)`，**不重复实现匹配规则**
/// - 孤儿残留独立扫描：`scanOrphans()` 走 [OrphanScanner](OrphanScanner.swift)，反查无主目录
public actor UninstallStore {
    private struct CandidateProducerSession {
        let revision: UInt64
        let task: Task<UninstallCandidateDiscoveryResult, Never>
    }

    private let applicationRoots: [String]
    private let uninstaller: AppUninstaller
    private let orphanScanner: OrphanScanner
    private let rootReader: any InstalledApplicationRootReading
    private let discoveryLimits: InstalledAppDiscoveryLimits
    /// v2026.07.18: one store owns exactly one residual producer. A new selection cancels and
    /// awaits the old producer's terminal return before starting filesystem work for the new App.
    private var candidateProducerRevision: UInt64 = 0
    private var activeCandidateProducer: CandidateProducerSession?

    public static func standardApplicationPaths(
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        ["/Applications", (homeDirectory as NSString).appendingPathComponent("Applications")]
    }

    public init(
        applicationPaths: [String] = UninstallStore.standardApplicationPaths(),
        uninstaller: AppUninstaller = AppUninstaller(),
        orphanScanner: OrphanScanner = OrphanScanner()
    ) {
        self.applicationRoots = Self.normalizedRoots(applicationPaths)
        self.uninstaller = uninstaller
        self.orphanScanner = orphanScanner
        self.rootReader = DefaultInstalledApplicationRootReader()
        self.discoveryLimits = InstalledAppDiscoveryLimits()
    }

    /// 单根注入只服务 fixture/显式调用；生产默认必须走两个标准根。
    public init(
        applicationsPath: String,
        uninstaller: AppUninstaller = AppUninstaller(),
        orphanScanner: OrphanScanner = OrphanScanner()
    ) {
        self.applicationRoots = Self.normalizedRoots([applicationsPath])
        self.uninstaller = uninstaller
        self.orphanScanner = orphanScanner
        self.rootReader = DefaultInstalledApplicationRootReader()
        self.discoveryLimits = InstalledAppDiscoveryLimits()
    }

    init(
        applicationPaths: [String],
        uninstaller: AppUninstaller = AppUninstaller(),
        orphanScanner: OrphanScanner = OrphanScanner(),
        rootReader: any InstalledApplicationRootReading,
        discoveryLimits: InstalledAppDiscoveryLimits = InstalledAppDiscoveryLimits()
    ) {
        self.applicationRoots = Self.normalizedRoots(applicationPaths)
        self.uninstaller = uninstaller
        self.orphanScanner = orphanScanner
        self.rootReader = rootReader
        self.discoveryLimits = discoveryLimits
    }

    /// v2026.07.18：只在 actor 内冻结不可变输入并 await 终态；stat/readdir/
    /// bundle metadata 全部在 utility worker 上完成。取消由共享 token 逐项收敛。
    public func listInstalledApps() async -> InstalledAppDiscoveryResult {
        let cancellationToken = InstalledAppDiscoveryCancellationToken()
        let worker = InstalledApplicationDiscoveryWorker(
            applicationRoots: applicationRoots,
            rootReader: rootReader,
            limits: discoveryLimits
        )
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: worker.run(
                        cancellationToken: cancellationToken
                    ))
                }
            }
        } onCancel: {
            cancellationToken.cancel()
        }

        if let firstIssue = result.incompleteIssues.first {
            GSYLog.warning(
                .app,
                "installed app discovery incomplete count=\(result.incompleteIssues.count) firstRoot=\(firstIssue.rootPath) firstPath=\(firstIssue.path) firstReason=\(firstIssue.reason.rawValue)"
            )
        }
        return result
    }

    /// 给定一个已选 App，返回卸载残留候选项。
    public func selectApp(_ app: InstalledApp) async -> UninstallCandidateDiscoveryResult {
        guard let selectedIdentity = UninstallSelectedAppIdentity(installedApp: app) else {
            return Self.candidateIdentityUnavailable(path: app.appURL.path)
        }
        candidateProducerRevision &+= 1
        let revision = candidateProducerRevision
        if let previous = activeCandidateProducer {
            previous.task.cancel()
            _ = await previous.task.value
        }
        guard candidateProducerRevision == revision, !Task.isCancelled else {
            return Self.cancelledCandidateDiscovery(path: app.appURL.path)
        }

        let uninstaller = self.uninstaller
        let task = Task.detached(priority: .utility) {
            // 首屏保留 pkg receipt 完整性，但不等待 Spotlight 索引；后者属于低确定性补充源。
            await uninstaller.candidatesAsync(
                for: selectedIdentity,
                fallbacks: [.pkgReceipts]
            )
        }
        activeCandidateProducer = CandidateProducerSession(revision: revision, task: task)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if activeCandidateProducer?.revision == revision {
            activeCandidateProducer = nil
        }
        guard candidateProducerRevision == revision, !Task.isCancelled else {
            return Self.cancelledCandidateDiscovery(path: app.appURL.path)
        }
        return result
    }

    private nonisolated static func candidateIdentityUnavailable(
        path: String
    ) -> UninstallCandidateDiscoveryResult {
        UninstallCandidateDiscoveryResult(
            candidates: [],
            incompleteIssues: [.init(
                source: .selectedAppIdentity,
                stage: .identityValidation,
                path: path,
                reason: .identityUnavailable
            )]
        )
    }

    private nonisolated static func cancelledCandidateDiscovery(
        path: String
    ) -> UninstallCandidateDiscoveryResult {
        UninstallCandidateDiscoveryResult(
            candidates: [],
            incompleteIssues: [.init(
                source: .primaryRoot,
                stage: .cancellation,
                path: path,
                reason: .cancelled
            )]
        )
    }

    /// Identity-only check used by the destructive handoff. It runs on a utility queue because the
    /// production validator performs no-follow open/fstat and bounded plist I/O.
    public func validationIssue(for identity: UninstallSelectedAppIdentity) async
        -> UninstallDiscoveryIssue? {
        let uninstaller = self.uninstaller
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: uninstaller.selectedAppValidationIssue(for: identity))
            }
        }
    }

    /// 反向扫描三大用户库目录，列出"无主"残留候选。
    public func scanOrphans() async -> [OrphanCandidate] {
        orphanScanner.scan()
    }

    private nonisolated static func normalizedRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.compactMap { path in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

}

// MARK: - SwiftUI 屏幕

/// 卸载残留扫描的独立屏幕：左 App 列表 / 右候选项 + 删除按钮。
///
/// 安全契约：
/// - Professional 只展示不可变候选 + 删除确认，不提供 Preview/dry-run 分支
/// - 用户确认后的执行固定为 `dryRun = false`
public struct UninstallScreen: View {
    /// v2026.07.15：占位、汇总、按钮和匹配原因都在当前 View locale 下解析；
    /// 不再经由进程级字符串解析锁定 App 启动时的语言。
    @Environment(\.locale) private var locale

    private let store: UninstallStore
    private let pipeline: any DeletionPipeline
    /// v2026.07.20 P0: pipeline and Undo owner are one explicit persistence domain.
    private let undoHistoryStore: UndoHistoryStore
    // v2026.09.06: workspace embedding keeps normal review authority and reports
    // transaction occupancy to the enclosing navigation until its terminal.
    private let userMode: DeletionUserMode
    private let onTransactionActiveChange: (Bool) -> Void

    @State private var apps: [InstalledApp] = []
    @State private var appListIncompleteIssues: [InstalledAppDiscoveryIssue] = []
    @State private var selectedApp: InstalledApp?
    @State private var candidates: [UninstallCandidate] = []
    @State private var candidateDiscoveryIssues: [UninstallDiscoveryIssue] = []
    @State private var checked: Set<String> = []
    @State private var isLoadingApps: Bool = false
    @State private var appListTask: Task<Void, Never>?
    @State private var appListRevision: UInt64 = 0
    @State private var appListLoadGate = UninstallAppListLoadGate()
    @State private var isLoadingCandidates: Bool = false
    @State private var isDeleting: Bool = false
    @State private var candidateTask: Task<Void, Never>?
    @State private var candidateLoadGate = UninstallCandidateLoadGate()
    @State private var activeSheet: ActiveSheet?
    @State private var preflightNotice: DeletionPreflightNotice?
    @State private var uninstallDeletionHandoff = ToolDeletionHandoff<UninstallExecutionRequest>()
    @State private var uninstallPreflightTask: Task<Void, Never>?
    @State private var uninstallPreflightGate = ToolDeletionPreflightRequestGate<UninstallPreflightContext>()
    @State private var uninstallExecutionTask: Task<Void, Never>?
    @State private var uninstallExecutionOwner: UninstallExecutionOwner?
    @State private var uninstallExecutionStatus: UninstallExecutionStatus?
    @State private var selectedAppRevision: UInt64 = 0
    @StateObject private var iconCache = AppFootprintIconCache()
    @State private var searchQuery: String = ""
    /// v2026.07.16: identifies the candidate scan, not the confirmation click. This closes the
    /// path where a random UUID made every retry look like a fresh review after restart.
    @State private var selectedAppScanSessionID = UUID()

    private var filteredApps: [InstalledApp] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return apps }
        return apps.filter { app in
            app.metadata.appName.localizedCaseInsensitiveContains(q)
                || app.metadata.bundleID.localizedCaseInsensitiveContains(q)
                || app.appURL.path.localizedCaseInsensitiveContains(q)
        }
    }

    private var isDeletionTransactionActive: Bool {
        isDeleting
            || uninstallPreflightGate.hasCurrentRequest
            || uninstallDeletionHandoff.hasPending
            || activeSheet != nil
    }

    private struct UninstallDeleteRequest: Identifiable, Sendable {
        let id = UUID()
        let items: [RunningAppGuard.Candidate]
        let totalBytes: Int64
        let bytesByPath: [String: Int64]
        let prepared: DeletionPreparedInteraction
        let appID: String
        let selectionRevision: UInt64
        let selectedAppIdentity: UninstallSelectedAppIdentity

        var paths: [String] { items.map(\.path) }
    }

    private struct UninstallExecutionRequest: Sendable {
        let plan: ToolTrashExecutionPlan
        let request: UninstallDeleteRequest
        let appID: String
        let selectionRevision: UInt64
    }

    private struct UninstallPreflightContext: Sendable, Equatable {
        let appID: String
        let selectionRevision: UInt64
        let paths: [String]
        let selectedAppIdentity: UninstallSelectedAppIdentity
    }

    private enum ActiveSheet: Identifiable {
        case confirm(UninstallDeleteRequest)
        case execution(UninstallExecutionOwner)
        case result(OperationResultCompletion)

        var id: String {
            switch self {
            case .confirm(let request): return "confirm-\(request.id)"
            case .execution(let owner): return "execution-\(owner.id.uuidString)"
            case .result(let payload): return "result-\(payload.id)"
            }
        }
    }

    public init(
        store: UninstallStore? = nil,
        pipeline: (any DeletionPipeline)? = nil,
        vendors: [VendorRule],
        undoHistoryStore: UndoHistoryStore,
        userMode: DeletionUserMode = .professional,
        onTransactionActiveChange: @escaping (Bool) -> Void = { _ in }
    ) {
        // 若没传 store，用注入的 vendors 现场装一个 AppUninstaller
        if let store {
            self.store = store
        } else {
            let unins = AppUninstaller(vendorRules: vendors)
            self.store = UninstallStore(uninstaller: unins)
        }
        self.pipeline = pipeline ?? TrashPipeline.production(
            vendors: vendors,
            whitelistStore: .shared
        )
        self.undoHistoryStore = undoHistoryStore
        self.userMode = userMode
        self.onTransactionActiveChange = onTransactionActiveChange
    }

    public var body: some View {
        // bug2：之前用 HSplitView 是 NSSplitView 桥接，会向外抢宽度预算，导致
        // 嵌在 MainView 的 NavigationSplitView content 栏时，外层 sidebar 被
        // 强制压到几十像素宽，文字截断到只剩首字母。
        // 改成 HStack + Divider + maxWidth=.infinity，让两栏在 content 栏内部
        // 弹性平分，外层 sidebar 不再受到挤压。代价：失去拖拽分栏宽度的能力，
        // 但卸载残留是只读 + 二次确认流程，列宽固定 1:2 已足够。
        HStack(spacing: 0) {
            appsPane
                .frame(minWidth: 240, maxWidth: 360)
            Divider()
            candidatesPane
                .frame(maxWidth: .infinity)
        }
        // v2026.07.20 P0: keep app/candidate selection stable; the rejection is a floating,
        // dismissible explanation and never a new split-view row or blocking presentation.
        .deletionPreflightNoticeOverlay(preflightNotice) {
            preflightNotice = nil
        }
        .onAppear { startAppListReload() }
        // 确认与结果共用一个 ActiveSheet。真删只在确认 sheet 的 onDismiss
        // 之后从 handoff 取出，避免两张 sibling sheet 争抢呈现。
        .sheet(item: $activeSheet, onDismiss: completeUninstallSheetDismissal) { sheet in
            switch sheet {
            case .confirm(let request):
                ToolTrashConfirmationSheet(
                    items: request.items,
                    totalBytes: request.totalBytes,
                    vendorOverrideRequest: request.prepared.vendorOverrideRequest,
                    scanIncompleteOverrideRequest: request.prepared.scanIncompleteOverrideRequest,
                    reviewPlan: userMode == .normal ? request.prepared.plan : nil,
                    onCancel: { activeSheet = nil },
                    onConfirm: { executionPlan in
                        guard requireCurrentUninstallRequest(request) else { return false }
                        guard uninstallDeletionHandoff.schedule(UninstallExecutionRequest(
                            plan: executionPlan,
                            request: request,
                            appID: request.appID,
                            selectionRevision: request.selectionRevision
                        )) else { return false }
                        activeSheet = nil
                        return true
                    }
                )
            case .execution:
                UninstallExecutionSheet(
                    status: uninstallExecutionStatus ?? .preparing(totalItems: 0)
                )
                .interactiveDismissDisabled(true)
            case .result(let completion):
                OperationResultSheet(completion: completion) {
                    activeSheet = nil
                }
            }
        }
        .onValueChange(of: isDeletionTransactionActive) { _, active in
            onTransactionActiveChange(active)
        }
        .onDisappear {
            onTransactionActiveChange(false)
            iconCache.removeAll()
            cancelAppListReloadForDeparture()
            cancelCandidateLoadForDeparture()
            cancelUninstallPreflight()
            // A confirmed recycle transaction is intentionally not cancelled on navigation or
            // window lifecycle. The execution sheet blocks normal navigation; if AppKit removes
            // the view externally, the owned Task and durable ledger still converge its typed
            // terminal instead of silently abandoning an already-submitted operation.
        }
    }

    // MARK: - 左栏

    private var appsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("uninstall.apps.title", bundle: .module).font(.headline)
                Spacer()
                if isLoadingApps { ProgressView().controlSize(.small) }
                Button {
                    iconCache.removeAll()
                    startAppListReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingApps || isDeletionTransactionActive)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            TextField(AppLocalization.string("appfootprint.header.search_placeholder", locale: locale), text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            if !appListIncompleteIssues.isEmpty {
                discoveryNotice(
                    key: "uninstall.apps.partial",
                    count: appListIncompleteIssues.count
                )
                Divider()
            }
            List(selection: $selectedApp) {
                ForEach(filteredApps) { app in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = iconCache.image(for: app.appURL) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                            } else {
                                Image(systemName: "app.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .padding(4)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.metadata.appName)
                                .font(.system(.body, design: .rounded))
                                .lineLimit(1)
                            Text(app.metadata.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(app)
                }
            }
            .listStyle(.inset)
            .disabled(isDeletionTransactionActive)
            .onValueChange(of: selectedApp) { _, new in
                selectedAppRevision &+= 1
                selectedAppScanSessionID = UUID()
                let scanSessionID = selectedAppScanSessionID
                cancelUninstallPreflight()
                candidateTask?.cancel()
                candidateTask = nil
                candidateLoadGate.invalidate()
                guard let app = new else {
                    candidates = []
                    candidateDiscoveryIssues = []
                    checked = []
                    isLoadingCandidates = false
                    return
                }
                let identity = UninstallCandidateLoadIdentity(
                    appID: app.id,
                    scanSessionID: scanSessionID,
                    selectionRevision: selectedAppRevision
                )
                // Start-state publication is synchronous with the selection revision. The
                // asynchronous body below is never allowed to clear a newer result on startup.
                candidateLoadGate.begin(identity)
                isLoadingCandidates = true
                candidates = []
                candidateDiscoveryIssues = []
                checked = []
                candidateTask = Task {
                    await reloadCandidates(for: app, identity: identity)
                }
            }
        }
    }

    // MARK: - 右栏

    private var candidatesPane: some View {
        VStack(spacing: 0) {
            candidatesHeader
            Divider()
            if !candidateDiscoveryIssues.isEmpty {
                discoveryNotice(
                    key: "uninstall.discovery.partial",
                    count: candidateDiscoveryIssues.count
                )
                Divider()
            }
            if selectedApp == nil {
                placeholder(
                    AppLocalization.string("uninstall.placeholder.select.app", locale: locale),
                    icon: "app.dashed"
                )
            } else if isLoadingCandidates {
                loadingPlaceholder(
                    AppLocalization.string("uninstall.placeholder.scanning", locale: locale)
                )
            } else if candidates.isEmpty {
                placeholder(
                    AppLocalization.string(
                        candidateDiscoveryIssues.isEmpty
                            ? "uninstall.placeholder.empty"
                            : "uninstall.placeholder.partial.empty",
                        locale: locale
                    ),
                    icon: candidateDiscoveryIssues.isEmpty ? "sparkles" : "exclamationmark.triangle"
                )
            } else {
                List {
                    ForEach(candidates, id: \.path) { cand in
                        candidateRow(cand)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footerBar
        }
    }

    private var candidatesHeader: some View {
        HStack {
            if let app = selectedApp {
                Text(app.metadata.appName).font(.headline)
                Text(app.metadata.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("uninstall.candidates.title", bundle: .module).font(.headline)
            }
            Spacer()
            Text(AppLocalization.format(
                "uninstall.candidates.summary",
                locale: locale,
                arguments: [Int64(candidates.count), formattedBytes(totalCheckedBytes)]
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func discoveryNotice(key: String, count: Int) -> some View {
        Label {
            Text(verbatim: AppLocalization.format(
                key,
                locale: locale,
                arguments: [Int64(count)]
            ))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07))
    }

    private func candidateRow(_ cand: UninstallCandidate) -> some View {
        let isOn = Binding<Bool>(
            get: { checked.contains(cand.path) },
            set: { newValue in
                if newValue, UninstallDeletionSelectionPolicy.isSelectable(cand) {
                    checked.insert(cand.path)
                }
                else { checked.remove(cand.path) }
            }
        )
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .disabled(
                    isDeletionTransactionActive
                        || !candidateDiscoveryIssues.isEmpty
                        || !UninstallDeletionSelectionPolicy.isSelectable(cand)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(cand.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(reasonLabel(cand.matchReason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !UninstallDeletionSelectionPolicy.isSelectable(cand) {
                    Text("uninstall.row.snapshot.partial", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedBytes(cand.bytes))
                    .font(.callout.monospacedDigit())
                Text(AppLocalization.format(
                    "uninstall.row.file.count",
                    locale: locale,
                    arguments: [Int64(cand.fileCount)]
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(cand.path)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cand.path)])
            } label: {
                Label {
                    Text("tree.menu.reveal_in_finder", bundle: .module)
                } icon: {
                    Image(systemName: "folder")
                }
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(cand.path, forType: .string)
            } label: {
                Label {
                    Text("tree.menu.copy_path", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button(AppLocalization.string(
                allChecked ? "uninstall.toggle.deselect.all" : "uninstall.toggle.select.all",
                locale: locale
            )) {
                toggleAll()
            }
            .disabled(
                candidates.isEmpty
                    || !candidateDiscoveryIssues.isEmpty
                    || isDeletionTransactionActive
            )

            Spacer()

            Text(AppLocalization.format(
                "uninstall.footer.selected",
                locale: locale,
                arguments: [Int64(checked.count), formattedBytes(totalCheckedBytes)]
            ))
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                prepareRealDelete()
            } label: {
                Label(
                    AppLocalization.string("uninstall.button.trash", locale: locale),
                    systemImage: "trash"
                )
            }
            .disabled(
                checkedPaths.isEmpty
                    || !candidateDiscoveryIssues.isEmpty
                    || isDeletionTransactionActive
            )
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var allChecked: Bool {
        let selectable = UninstallDeletionSelectionPolicy.selectablePaths(in: candidates)
        return !selectable.isEmpty && checked.intersection(selectable) == selectable
    }

    private var checkedPaths: [String] {
        candidates
            .filter { checked.contains($0.path) && UninstallDeletionSelectionPolicy.isSelectable($0) }
            .map(\.path)
    }

    private var totalCheckedBytes: Int64 {
        candidates.reduce(Int64(0)) { acc, c in
            checked.contains(c.path) && UninstallDeletionSelectionPolicy.isSelectable(c)
                ? acc + c.bytes
                : acc
        }
    }

    private func toggleAll() {
        guard candidateDiscoveryIssues.isEmpty else {
            checked.removeAll()
            return
        }
        if allChecked {
            checked.removeAll()
        } else {
            checked = UninstallDeletionSelectionPolicy.selectablePaths(in: candidates)
        }
    }

    /// v2026.07.17 root-cause fix: refresh-button Tasks used to be anonymous and could overlap.
    /// An older `/Applications` result could publish after a newer refresh and close its spinner.
    /// Start state is now synchronous; every result must claim the exact reload revision.
    private func startAppListReload() {
        guard !isDeletionTransactionActive else { return }
        appListTask?.cancel()
        appListRevision &+= 1
        let identity = UninstallAppListLoadIdentity(
            operationID: UUID(),
            revision: appListRevision
        )
        appListLoadGate.begin(identity)
        isLoadingApps = true
        appListTask = Task {
            await reloadApps(identity: identity)
        }
    }

    private func reloadApps(identity: UninstallAppListLoadIdentity) async {
        let result = await store.listInstalledApps()
        let taskWasCancelled = Task.isCancelled
        await MainActor.run {
            guard let shouldPublish = self.appListLoadGate.finishIfCurrent(
                identity,
                taskWasCancelled: taskWasCancelled
            ) else { return }
            self.appListTask = nil
            self.isLoadingApps = false
            guard shouldPublish else { return }
            self.apps = result.apps
            self.appListIncompleteIssues = result.incompleteIssues
            if let current = self.selectedApp, !result.apps.contains(current) {
                self.selectedApp = result.apps.first
            } else if self.selectedApp == nil {
                self.selectedApp = result.apps.first
            }
        }
    }

    private func cancelAppListReloadForDeparture() {
        appListLoadGate.invalidate()
        appListTask?.cancel()
        appListTask = nil
        isLoadingApps = false
    }

    private func reloadCandidates(
        for app: InstalledApp,
        identity: UninstallCandidateLoadIdentity
    ) async {
        let result = await store.selectApp(app)
        let taskWasCancelled = Task.isCancelled
        await MainActor.run {
            guard let completion = self.candidateLoadGate.completeIfCurrent(
                identity,
                selectedAppID: self.selectedApp?.id,
                scanSessionID: self.selectedAppScanSessionID,
                selectionRevision: self.selectedAppRevision,
                taskWasCancelled: taskWasCancelled
            ) else { return }
            self.candidateTask = nil
            self.isLoadingCandidates = false
            guard completion == .publishResult else { return }
            self.candidates = result.candidates
            self.candidateDiscoveryIssues = result.incompleteIssues
            if !result.incompleteIssues.isEmpty {
                self.checked.removeAll()
            }
        }
    }

    /// Leaving the page is a terminal owner transition for candidate discovery. Invalidate the
    /// gate before cancellation so a late synchronous filesystem return cannot publish even if
    /// the task has not observed cancellation yet. Existing rows are left untouched only to keep
    /// the disappearing frame stable; a future page instance creates a fresh scan identity.
    private func cancelCandidateLoadForDeparture() {
        candidateLoadGate.invalidate()
        candidateTask?.cancel()
        candidateTask = nil
        isLoadingCandidates = false
    }

    /// 冻结当前选择，先走与最终执行相同的 Safety / vendor / whitelist 预检。
    /// 只有完整通过才展示可执行确认；任意拒绝直接显示结构化结果，绝不调用 move。
    private func prepareRealDelete() {
        let selectedPaths = checkedPaths
        guard let selectedApp,
              !selectedPaths.isEmpty,
              !isDeleting,
              !uninstallDeletionHandoff.hasPending,
              activeSheet == nil else { return }
        // v2026.07.20: previous pre-submit evidence is not a modal transaction owner.
        preflightNotice = nil
        guard let selectedIdentity = UninstallSelectedAppIdentity(installedApp: selectedApp) else {
            candidateDiscoveryIssues = Array(Set(candidateDiscoveryIssues + [.init(
                source: .selectedAppIdentity,
                stage: .identityValidation,
                path: selectedApp.appURL.path,
                reason: .identityUnavailable
            )]))
            // v2026.07.20: identity construction failed before any Trash submission. Explain it
            // through the shared non-modal preflight channel instead of silently clearing rows.
            preflightNotice = DeletionPreflightNotice(
                rejections: selectedPaths.map {
                    .init(
                        path: $0,
                        reason: ScanIncompleteTargetRejectionReason.identityChanged.rawValue
                    )
                }
            )
            checked.removeAll()
            return
        }
        let context = UninstallPreflightContext(
            appID: selectedApp.id,
            selectionRevision: selectedAppRevision,
            paths: selectedPaths,
            selectedAppIdentity: selectedIdentity
        )
        let selectedPathSet = Set(selectedPaths)
        let selectedCandidates = candidates.filter { selectedPathSet.contains($0.path) }
        // UI 已禁选 partial；这里仍在提交边界 fail closed，防止未来状态恢复/批量选择
        // 把旧的部分快照重新塞回 checked。
        guard UninstallDeletionSelectionPolicy.canSubmit(
            selectedCandidates,
            discoveryIssues: candidateDiscoveryIssues
        ), let candidateVerification = UninstallCandidateVerificationRequest(
            candidates: selectedCandidates
        ) else {
            preflightNotice = DeletionPreflightNotice(
                rejections: selectedPaths.map {
                    .init(
                        path: $0,
                        reason: ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
                    )
                }
            )
            return
        }
        let selectedBytes = selectedCandidates.reduce(Int64(0)) { partial, candidate in
            let sum = partial.addingReportingOverflow(candidate.bytes)
            return sum.overflow ? .max : sum.partialValue
        }
        let bytesByPath = Dictionary(uniqueKeysWithValues: selectedCandidates.map {
            ($0.path, max(0, $0.bytes))
        })
        uninstallPreflightTask?.cancel()
        let token = uninstallPreflightGate.begin(context: context)
        let identity = DeletionSnapshotIdentity(
            sessionID: selectedAppScanSessionID,
            revision: selectedAppRevision,
            categoryID: selectedApp.id
        )
        isDeleting = true
        uninstallPreflightTask = Task { @MainActor in
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
            let decision: DeletionInteractionPreparation
            let identityIssue = await store.validationIssue(for: selectedIdentity)
            if identityIssue != nil {
                decision = .blocked(DeletionInteractionBlock(
                    intentID: UUID(),
                    rejections: selectedPaths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                ))
            } else {
                do {
                    let intent = try coordinator.makeIntent(
                        origin: .uninstall,
                        mode: userMode,
                        snapshotIdentity: identity,
                        candidates: selectedCandidates.map { candidate in
                            UninstallDeletionSelectionPolicy.interactionSnapshot(
                                for: candidate,
                                runningBundleIDPrefix: selectedApp.metadata.bundleID
                            )
                        },
                        executionVerification: .uninstall(candidateVerification)
                    )
                    decision = await coordinator.prepare(
                        intent: intent,
                        currentSnapshotIdentity: identity
                    )
                } catch {
                    decision = .blocked(DeletionInteractionBlock(
                        intentID: UUID(),
                        rejections: selectedPaths.map {
                            .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                        }
                    ))
                }
            }
            let currentContext = UninstallPreflightContext(
                appID: self.selectedApp?.id ?? "",
                selectionRevision: selectedAppRevision,
                paths: selectedPaths,
                selectedAppIdentity: self.selectedApp.flatMap {
                    UninstallSelectedAppIdentity(installedApp: $0)
                } ?? selectedIdentity
            )
            guard uninstallPreflightGate.finishIfCurrent(token, context: currentContext) else { return }
            uninstallPreflightTask = nil
            isDeleting = false
            guard !Task.isCancelled,
                  !uninstallDeletionHandoff.hasPending,
                  activeSheet == nil else { return }
            if let identityIssue {
                candidateDiscoveryIssues = Array(Set(candidateDiscoveryIssues + [identityIssue]))
                checked.removeAll()
            }
            switch decision {
            case .confirmation(let prepared):
                activeSheet = .confirm(UninstallDeleteRequest(
                    items: prepared.confirmationCandidates,
                    totalBytes: selectedBytes,
                    bytesByPath: bytesByPath,
                    prepared: prepared,
                    appID: selectedApp.id,
                    selectionRevision: selectedAppRevision,
                    selectedAppIdentity: selectedIdentity
                ))
            case .blocked(let block):
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
            case .cancelled:
                return
            }
        }
    }

    private func completeUninstallSheetDismissal() {
        guard let request = uninstallDeletionHandoff.takeAfterSheetDismissal() else { return }
        guard requireCurrentUninstallExecutionRequest(request) else { return }
        startUninstallExecution(request: request)
    }

    @discardableResult
    private func requireCurrentUninstallRequest(
        _ request: UninstallDeleteRequest,
        boundSnapshotIdentity: DeletionSnapshotIdentity? = nil
    ) -> Bool {
        guard selectedApp.flatMap({ UninstallSelectedAppIdentity(installedApp: $0) })
                == request.selectedAppIdentity else {
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: request.paths.map {
                    .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                }
            )
            return false
        }
        let identity = boundSnapshotIdentity
            ?? request.prepared.plan.intent.snapshotIdentity
        switch UninstallDeletionSubmissionGate.evaluate(
            requestAppID: request.appID,
            requestSelectionRevision: request.selectionRevision,
            boundSnapshotIdentity: identity,
            currentAppID: selectedApp?.id,
            currentScanSessionID: selectedAppScanSessionID,
            currentSelectionRevision: selectedAppRevision,
            paths: request.paths
        ) {
        case .current:
            return true
        case .cancelled(let rejections):
            GSYLog.notice(
                .trash,
                "Uninstall rejected stale deletion intent app=\(request.appID) revision=\(request.selectionRevision) currentApp=\(selectedApp?.id ?? "nil") currentRevision=\(selectedAppRevision)"
            )
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(rejections: rejections)
            return false
        }
    }

    @discardableResult
    private func requireCurrentUninstallExecutionRequest(
        _ execution: UninstallExecutionRequest,
        boundSnapshotIdentity: DeletionSnapshotIdentity? = nil
    ) -> Bool {
        guard execution.appID == execution.request.appID,
              execution.selectionRevision == execution.request.selectionRevision else {
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: execution.request.paths.map {
                    .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                }
            )
            return false
        }
        return requireCurrentUninstallRequest(
            execution.request,
            boundSnapshotIdentity: boundSnapshotIdentity
        )
    }

    private func cancelUninstallPreflight() {
        uninstallPreflightTask?.cancel()
        uninstallPreflightTask = nil
        if uninstallPreflightGate.cancel() {
            isDeleting = false
        }
    }

    /// 只由确认 sheet 的确定性交接触发；先同步建立 owner/status/sheet，再启动异步工作，
    /// 因而不存在确认消失后数秒到数十秒的无反馈窗口。
    private func startUninstallExecution(request: UninstallExecutionRequest) {
        guard !isDeleting,
              requireCurrentUninstallExecutionRequest(request) else { return }
        let snapshot = request.request.prepared.plan.intent.snapshotIdentity
        let owner = UninstallExecutionOwner(
            id: request.request.id,
            appID: request.appID,
            scanSessionID: snapshot.sessionID,
            selectionRevision: request.selectionRevision
        )
        isDeleting = true
        uninstallExecutionOwner = owner
        uninstallExecutionStatus = .preparing(totalItems: request.request.paths.count)
        activeSheet = .execution(owner)
        uninstallExecutionTask = Task { @MainActor in
            await performDelete(request: request, owner: owner)
        }
    }

    /// v2026.07.17 revision-owned real recycle transaction. Progress is a typed side channel;
    /// only the coordinator's terminal disposition may replace the execution sheet with result.
    private func performDelete(
        request: UninstallExecutionRequest,
        owner: UninstallExecutionOwner
    ) async {
        defer {
            isDeleting = false
            uninstallExecutionTask = nil
            if uninstallExecutionOwner == owner {
                uninstallExecutionOwner = nil
                uninstallExecutionStatus = nil
            }
        }
        guard uninstallExecutionOwner == owner,
              requireCurrentUninstallExecutionRequest(request) else { return }
        let executionPlan = request.plan
        // v1.3.zzzz Phase 3-A 对称防御：UninstallScreen 没接 BulkScanner 的
        // permissionDenied 数据源（候选来自 [UninstallStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UninstallStore.swift)
        // 的 NSMetadataQuery + AppCandidate），但 pipeline 是注入进来的、
        // 可能跨视图复用 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
        // 实例。若 MainView 上一轮扫描遗留了 accessDeniedPaths 没清，
        // 切到 UninstallScreen 走 trash 时就会"莫名 accessDenied 拒了某个 ~/Library/.. 路径"。
        // 主动清空一次是 O(1) 锁开销，零误伤；实际执行与 UndoHistory 写入走统一删除入口。
        let coordinator = DeletionInteractionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: undoHistoryStore
        )
        let authorization: DeletionAuthorizedInteraction
        switch coordinator.authorize(
            prepared: request.request.prepared,
            executionPlan: executionPlan
        ) {
        case .authorized(let value):
            authorization = value
        case .cancelled:
            activeSheet = nil
            return
        case .blocked(let block):
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: block.rejections
            )
            return
        }
        guard requireCurrentUninstallExecutionRequest(
            request,
            boundSnapshotIdentity: authorization.authorization.snapshotIdentity
        ) else { return }
        if let identityIssue = await store.validationIssue(
            for: request.request.selectedAppIdentity
        ) {
            candidateDiscoveryIssues = Array(Set(candidateDiscoveryIssues + [identityIssue]))
            checked.removeAll()
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(
                rejections: request.request.paths.map {
                    .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                }
            )
            return
        }
        uninstallExecutionStatus = .preparing(
            totalItems: authorization.authorization.paths.count
        )
        let progressPair = AsyncStream<DeletionExecutionProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let progressContinuation = progressPair.continuation
        let progressConsumer = Task { @MainActor in
            for await event in progressPair.stream {
                guard let current = uninstallExecutionStatus else { continue }
                uninstallExecutionStatus = UninstallExecutionProgressReducer.reduce(
                    current: current,
                    event: event,
                    eventOwner: owner,
                    currentOwner: uninstallExecutionOwner,
                    currentAppID: selectedApp?.id,
                    currentScanSessionID: selectedAppScanSessionID,
                    currentSelectionRevision: selectedAppRevision
                )
            }
        }
        let disposition = await coordinator.submit(
            authorization,
            accessDeniedPaths: [],
            executionProgressObserver: { event in
                progressContinuation.yield(event)
            }
        )
        progressContinuation.finish()
        await progressConsumer.value
        guard uninstallExecutionOwner == owner else { return }
        let completed: DeletionCompletedInteraction
        switch disposition {
        case .completed(let value):
            completed = value
        case .requiresConfirmation(let prepared):
            guard requireCurrentUninstallExecutionRequest(request) else { return }
            let totalBytes = prepared.paths.reduce(Int64(0)) { partial, path in
                let value = request.request.bytesByPath[path] ?? 0
                let sum = partial.addingReportingOverflow(value)
                return sum.overflow ? .max : sum.partialValue
            }
            activeSheet = .confirm(UninstallDeleteRequest(
                items: prepared.confirmationCandidates,
                totalBytes: totalBytes,
                bytesByPath: request.request.bytesByPath,
                prepared: prepared,
                appID: request.appID,
                selectionRevision: request.selectionRevision,
                selectedAppIdentity: request.request.selectedAppIdentity
            ))
            return
        case .blocked(let block):
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
            return
        }
        let result = completed.result
        await ToolDeletionResultOrdering.finish(
            updateModelToTerminalState: {
                // Submit succeeded for these exact paths. Project them out even if a future
                // non-UI state change advanced the selection during the await; silently
                // keeping a path that has actually moved would leave the visible model false.
                let terminal = UninstallCandidateTerminalProjection.applying(
                    succeededPaths: Set(result.succeededPaths),
                    to: UninstallCandidateTerminalState(
                        candidates: self.candidates,
                        checked: self.checked,
                        apps: self.apps,
                        selectedApp: self.selectedApp
                    )
                )
                self.candidates = terminal.candidates
                self.checked = terminal.checked
                self.apps = terminal.apps
                if self.selectedApp != terminal.selectedApp {
                    self.selectedApp = terminal.selectedApp
                }
            },
            makePayload: { OperationResultCompletion.deletion(completed) },
            present: { completion in
                self.activeSheet = .result(completion)
            }
        )
    }

    private func formattedBytes(_ b: Int64) -> String {
        AppLocalization.byteCount(b, locale: locale)
    }

    private func reasonLabel(_ r: MatchReason) -> String {
        switch r {
        case .bundleID(let s): return "bundleID · \(s)"
        case .bundleVendor(let s): return "vendor · \(s)"
        case .appName(let s): return "appName · \(s)"
        case .vendorRule(let s):
            return AppLocalization.format(
                "uninstall.reason.vendor.rule",
                locale: locale,
                arguments: [s]
            )
        case .spotlight(let kind): return "spotlight · \(kind)"
        case .pkgReceipt(let pkgID):
            return AppLocalization.format(
                "uninstall.reason.pkg_receipt",
                locale: locale,
                arguments: [pkgID]
            )
        }
    }

    @ViewBuilder
    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingPlaceholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeInOut(duration: 0.18), value: isLoadingCandidates)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
