import Darwin
import Foundation
import ScanKit
import SafetyKit

/// Professional 模式为“扫描证据不完整”目标铸造的严格请求。
///
/// 这不是 force Bool，也不是越过 SafetyEngine 的 bearer token。它冻结确认前的稳定
/// 文件身份和本轮 typed scan issues；`TrashPipeline` 在调用 `NSWorkspace.recycle`
/// 之前必须对同一批路径重新完成身份、Safety、scope、whitelist 与父目录移动能力检查。
public struct ScanIncompleteOverrideRequest: Sendable, Hashable {
    struct FileIdentity: Sendable, Hashable {
        let device: UInt64
        let inode: UInt64
        let fileType: UInt16
        let resolvedPath: String
    }

    struct Entry: Sendable, Hashable {
        let candidateID: UUID
        let path: String
        let title: String
        let isDirectory: Bool
        let bytes: Int64
        let fileCount: Int
        let snapshotVerdict: SafetyVerdict
        let snapshotRejectionRawValue: String
        let identity: FileIdentity
        let incompleteIssues: [ScanIncompleteIssue]
    }

    public let id: UUID
    public let scanSessionID: UUID
    let entries: [Entry]

    public var paths: [String] { entries.map(\.path) }

    init(id: UUID = UUID(), scanSessionID: UUID, entries: [Entry]) {
        self.id = id
        self.scanSessionID = scanSessionID
        self.entries = entries
    }

    func restricting(to paths: [String]) -> ScanIncompleteOverrideRequest? {
        let wanted = Set(paths.map(DeletionIntentCandidate.pathIdentity))
        guard !wanted.isEmpty,
              wanted.count == paths.count,
              wanted.isSubset(of: Set(self.paths.map(DeletionIntentCandidate.pathIdentity))) else {
            return nil
        }
        let remaining = entries.filter {
            wanted.contains(DeletionIntentCandidate.pathIdentity($0.path))
        }
        // If the running-app choice removed every incomplete target, the remaining ordinary
        // candidates do not need this capability. Returning nil prevents an obsolete strict
        // request from being carried into another path set.
        guard remaining.contains(where: { !$0.incompleteIssues.isEmpty }) else { return nil }
        return ScanIncompleteOverrideRequest(
            id: id,
            scanSessionID: scanSessionID,
            entries: remaining
        )
    }
}

/// Target revalidation 的机器可读拒绝。用户文案由 AppUI String Catalog 映射，绝不把
/// errno、raw Error 或猜测的 TCC/FDA 原因直接显示给用户。
public enum ScanIncompleteTargetRejectionReason: String, Sendable, Hashable {
    case missingTypedEvidence = "targetRevalidation.missingTypedEvidence"
    case identityChanged = "targetRevalidation.identityChanged"
    case targetMissing = "targetRevalidation.targetMissing"
    case targetTypeChanged = "targetRevalidation.targetTypeChanged"
    case symlinkNotEligible = "targetRevalidation.symlinkNotEligible"
    case parentUnavailable = "targetRevalidation.parentUnavailable"
    case posixPermissionDenied = "targetRevalidation.posixPermissionDenied"
    case unclassifiedAccessFailure = "targetRevalidation.unclassifiedAccessFailure"
    case immutable = "targetRevalidation.immutable"
    case readOnlyVolume = "targetRevalidation.readOnlyVolume"
    case invalidStrictRequest = "targetRevalidation.invalidStrictRequest"
}

public enum ScanIncompleteOverridePreparation: Sendable, Equatable {
    case strictConfirmation(
        request: ScanIncompleteOverrideRequest,
        vendorOverrideRequest: VendorPathOverrideRequest?
    )
    case blocked([DeletionPreflight.Rejection])
}

/// Filesystem-only target probe. It deliberately never enumerates descendants: moving a directory
/// entry requires a stable target plus write/search capability on its parent, not read permission
/// for every child. The actual operation remains `NSWorkspace.recycle`.
enum DeletionTargetRevalidator {
    enum ProbeResult: Sendable, Equatable {
        case eligible(ScanIncompleteOverrideRequest.FileIdentity)
        case blocked(ScanIncompleteTargetRejectionReason)
    }

    static func prepare(
        rows: [RowItem],
        scanIssues: [ScanIncompleteIssue],
        scanSessionID: UUID,
        safety: SafetyEngine,
        trie: VendorTrieNode?,
        whitelistPaths: Set<String>,
        home: String,
        externalDeletionRoots: [String]
    ) -> ScanIncompleteOverridePreparation {
        let uniqueRows = stableUniqueRows(rows)
        guard !uniqueRows.isEmpty else {
            return .blocked([])
        }

        var entries: [ScanIncompleteOverrideRequest.Entry] = []
        entries.reserveCapacity(uniqueRows.count)
        var sawTypedIncompleteEvidence = false

        for row in uniqueRows {
            if Task.isCancelled {
                return .blocked([.init(
                    path: row.url.path,
                    reason: SafetyRejection.preflightCancelled.rawValue
                )])
            }
            let path = row.url.path
            let relevantIssues = relevantIssues(for: path, from: scanIssues)
            sawTypedIncompleteEvidence = sawTypedIncompleteEvidence || !relevantIssues.isEmpty

            let safetyResult = currentSafety(
                path: path,
                safety: safety,
                trie: trie,
                whitelistPaths: whitelistPaths,
                home: home,
                externalDeletionRoots: externalDeletionRoots
            )
            if let rejection = safetyResult.nonBypassableRejection {
                return .blocked([.init(path: path, reason: rejection.rawValue)])
            }

            switch probe(path: path, expectedDirectory: row.isDirectory) {
            case .blocked(let reason):
                return .blocked([.init(path: path, reason: reason.rawValue)])
            case .eligible(let identity):
                let candidate = DeletionIntentCandidate(
                    path: path,
                    title: row.title,
                    isDirectory: row.isDirectory,
                    bytes: row.bytes,
                    fileCount: row.fileCount,
                    verdict: row.verdict,
                    rejection: row.rejection,
                    accessEvidence: accessEvidence(for: relevantIssues)
                )
                let decision = DeletionTargetRevalidationPolicy.decision(
                    for: candidate,
                    evidence: DeletionTargetRevalidationEvidence(
                        candidateID: candidate.id,
                        path: path,
                        identity: .matchesSnapshot,
                        currentVerdict: safetyResult.verdict,
                        currentRejection: safetyResult.rejection,
                        scanEvidence: scanEvidence(targetPath: path, issues: relevantIssues),
                        moveAttempt: .eligibleForAttempt
                    ),
                    mode: .professional
                )
                if case .prohibited(let reason) = decision {
                    return .blocked([rejection(path: path, block: reason)])
                }
                entries.append(.init(
                    candidateID: candidate.id,
                    path: DeletionIntentCandidate.pathIdentity(path),
                    title: row.title,
                    isDirectory: row.isDirectory,
                    bytes: row.bytes,
                    fileCount: row.fileCount,
                    snapshotVerdict: row.verdict,
                    snapshotRejectionRawValue: row.rejection.rawValue,
                    identity: identity,
                    incompleteIssues: relevantIssues
                ))
            }
        }

        guard sawTypedIncompleteEvidence else {
            return .blocked(uniqueRows.map {
                .init(
                    path: $0.url.path,
                    reason: ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
                )
            })
        }

        let request = ScanIncompleteOverrideRequest(
            scanSessionID: scanSessionID,
            entries: entries
        )
        let safetyPreflight = safetyOnlyPreflight(
            paths: request.paths,
            safety: safety,
            trie: trie,
            whitelistPaths: whitelistPaths,
            home: home,
            externalDeletionRoots: externalDeletionRoots
        )
        guard safetyPreflight.canProceed
                || VendorPathOverrideRequest(preflight: safetyPreflight) != nil else {
            return .blocked(safetyPreflight.rejections)
        }
        return .strictConfirmation(
            request: request,
            vendorOverrideRequest: VendorPathOverrideRequest(preflight: safetyPreflight)
        )
    }

    static func validateFinal(
        request: ScanIncompleteOverrideRequest,
        paths: [String],
        accessDeniedPaths: Set<String>,
        safety: SafetyEngine,
        trie: VendorTrieNode?,
        whitelistPaths: Set<String>,
        home: String,
        externalDeletionRoots: [String]
    ) -> [DeletionPreflight.Rejection] {
        let normalizedPaths = paths.map(DeletionIntentCandidate.pathIdentity)
        guard normalizedPaths == request.paths,
              Set(normalizedPaths).count == normalizedPaths.count else {
            return paths.map {
                .init(path: $0, reason: ScanIncompleteTargetRejectionReason.invalidStrictRequest.rawValue)
            }
        }

        let recordedIssuePaths = Set(request.entries.flatMap(\.incompleteIssues).map {
            TrashPipeline.normalizePath($0.path)
        })
        for deniedPath in accessDeniedPaths.map(TrashPipeline.normalizePath) {
            guard request.paths.contains(where: { pathsOverlap($0, deniedPath) }) else { continue }
            guard recordedIssuePaths.contains(deniedPath) else {
                return [.init(
                    path: deniedPath,
                    reason: ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
                )]
            }
        }

        for entry in request.entries {
            if Task.isCancelled {
                return [.init(path: entry.path, reason: SafetyRejection.preflightCancelled.rawValue)]
            }
            // Complete siblings may be part of an atomic batch, but at least one request entry
            // must carry the strict risk. Their own identity and safety are still rechecked below.
            if entry.incompleteIssues.isEmpty,
               !request.entries.contains(where: { !$0.incompleteIssues.isEmpty }) {
                return [.init(
                    path: entry.path,
                    reason: ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
                )]
            }

            let safetyResult = currentSafety(
                path: entry.path,
                safety: safety,
                trie: trie,
                whitelistPaths: whitelistPaths,
                home: home,
                externalDeletionRoots: externalDeletionRoots
            )
            if let rejection = safetyResult.nonBypassableRejection {
                return [.init(path: entry.path, reason: rejection.rawValue)]
            }

            switch probe(path: entry.path, expectedDirectory: entry.isDirectory) {
            case .blocked(let reason):
                return [.init(path: entry.path, reason: reason.rawValue)]
            case .eligible(let currentIdentity):
                guard currentIdentity == entry.identity else {
                    return [.init(
                        path: entry.path,
                        reason: ScanIncompleteTargetRejectionReason.identityChanged.rawValue
                    )]
                }
                guard let snapshotRejection = SafetyRejection(
                    rawValue: entry.snapshotRejectionRawValue
                ) else {
                    return [.init(
                        path: entry.path,
                        reason: ScanIncompleteTargetRejectionReason.invalidStrictRequest.rawValue
                    )]
                }
                let candidate = DeletionIntentCandidate(
                    id: entry.candidateID,
                    path: entry.path,
                    title: entry.title,
                    isDirectory: entry.isDirectory,
                    bytes: entry.bytes,
                    fileCount: entry.fileCount,
                    verdict: entry.snapshotVerdict,
                    rejection: snapshotRejection,
                    accessEvidence: accessEvidence(for: entry.incompleteIssues)
                )
                let decision = DeletionTargetRevalidationPolicy.decision(
                    for: candidate,
                    evidence: DeletionTargetRevalidationEvidence(
                        candidateID: candidate.id,
                        path: entry.path,
                        identity: .matchesSnapshot,
                        currentVerdict: safetyResult.verdict,
                        currentRejection: safetyResult.rejection,
                        scanEvidence: scanEvidence(
                            targetPath: entry.path,
                            issues: entry.incompleteIssues
                        ),
                        moveAttempt: .eligibleForAttempt
                    ),
                    mode: .professional
                )
                if case .prohibited(let block) = decision {
                    return [rejection(path: entry.path, block: block)]
                }
            }
        }
        return []
    }

    struct CurrentSafety {
        let verdict: SafetyVerdict
        let rejection: SafetyRejection

        var nonBypassableRejection: SafetyRejection? {
            guard verdict == .forbid, rejection != .vendorPathRule else { return nil }
            return rejection
        }
    }

    private static func currentSafety(
        path: String,
        safety: SafetyEngine,
        trie: VendorTrieNode?,
        whitelistPaths: Set<String>,
        home: String,
        externalDeletionRoots: [String]
    ) -> CurrentSafety {
        let partition = TrashPipeline.partitionByForbid(
            paths: [path],
            safety: safety,
            trie: trie,
            accessDeniedPaths: [],
            whitelistPaths: whitelistPaths,
            home: home,
            externalDeletionRoots: externalDeletionRoots
        )
        if let rejected = partition.rejected.first {
            return CurrentSafety(verdict: .forbid, rejection: rejected.reason)
        }
        if let trie {
            let (verdict, rejection, _) = safety.evaluate(path: path, trie: trie, home: home)
            return CurrentSafety(verdict: verdict, rejection: rejection)
        }
        let (verdict, rejection) = safety.evaluate(path: path, home: home)
        return CurrentSafety(verdict: verdict, rejection: rejection)
    }

    private static func safetyOnlyPreflight(
        paths: [String],
        safety: SafetyEngine,
        trie: VendorTrieNode?,
        whitelistPaths: Set<String>,
        home: String,
        externalDeletionRoots: [String]
    ) -> DeletionPreflight {
        let partition = TrashPipeline.partitionByForbid(
            paths: paths,
            safety: safety,
            trie: trie,
            accessDeniedPaths: [],
            whitelistPaths: whitelistPaths,
            home: home,
            externalDeletionRoots: externalDeletionRoots
        )
        guard !partition.rejected.isEmpty else {
            return DeletionPreflight(allowedPaths: partition.allowed, rejections: [])
        }
        let direct = partition.rejected.map {
            DeletionPreflight.Rejection(path: $0.path, reason: $0.reason.rawValue)
        }
        let atomic = partition.allowed.map {
            DeletionPreflight.Rejection(
                path: $0,
                reason: SafetyRejection.batchContainsForbidden.rawValue
            )
        }
        let overrideEligiblePaths = TrashPipeline.vendorOverrideEligiblePaths(
            paths: paths,
            partition: partition,
            safety: safety,
            trie: trie,
            home: home,
            externalDeletionRoots: externalDeletionRoots
        )
        return DeletionPreflight(
            allowedPaths: [],
            rejections: direct + atomic,
            vendorOverrideEligiblePaths: overrideEligiblePaths
        )
    }

    static func relevantIssues(
        for targetPath: String,
        from issues: [ScanIncompleteIssue]
    ) -> [ScanIncompleteIssue] {
        let target = DeletionIntentCandidate.pathIdentity(targetPath)
        var seen = Set<ScanIncompleteIssue>()
        return issues.compactMap { issue in
            let normalized = ScanIncompleteIssue(
                path: DeletionIntentCandidate.pathIdentity(issue.path),
                reason: issue.reason,
                stage: issue.stage,
                posixErrorCode: issue.posixErrorCode
            )
            guard pathsOverlap(target, normalized.path), seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = TrashPipeline.normalizePath(lhs)
        let right = TrashPipeline.normalizePath(rhs)
        if left == right { return true }
        if left == "/" || right == "/" { return true }
        return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func stableUniqueRows(_ rows: [RowItem]) -> [RowItem] {
        var seen = Set<String>()
        return rows.filter {
            seen.insert(DeletionIntentCandidate.pathIdentity($0.url.path)).inserted
        }
    }

    private static func accessEvidence(
        for issues: [ScanIncompleteIssue]
    ) -> DeletionAccessEvidence {
        guard let first = issues.first else { return .complete }
        return .incomplete(incompleteReason(first.reason))
    }

    private static func scanEvidence(
        targetPath: String,
        issues: [ScanIncompleteIssue]
    ) -> DeletionTargetScanEvidence {
        guard !issues.isEmpty else { return .complete }
        let target = DeletionIntentCandidate.pathIdentity(targetPath)
        return .incomplete(issues.map { issue in
            let issuePath = DeletionIntentCandidate.pathIdentity(issue.path)
            let scope: DeletionIncompleteEvidenceScope = issuePath == target
                || target.hasPrefix(issuePath + "/")
                ? .selectedTarget
                : .descendant
            return DeletionScopedIncompleteEvidence(
                reason: incompleteReason(issue.reason),
                scope: scope
            )
        })
    }

    private static func incompleteReason(
        _ reason: ScanIncompleteReason
    ) -> DeletionIncompleteReason {
        switch reason {
        case .permissionDenied:
            return .permissionDenied
        case .tccProtectedSkipped:
            return .tccProtected
        case .enumerationFailed, .metadataUnavailable:
            return .incompleteEnumeration
        }
    }

    private static func rejection(
        path: String,
        block: DeletionTargetRevalidationBlockReason
    ) -> DeletionPreflight.Rejection {
        let raw: String
        switch block {
        case .safety(let reason):
            raw = reason.rawValue
        case .identityChanged, .evidenceBoundToDifferentCandidate,
             .evidenceBoundToDifferentPath:
            raw = ScanIncompleteTargetRejectionReason.identityChanged.rawValue
        case .targetMissing:
            raw = ScanIncompleteTargetRejectionReason.targetMissing.rawValue
        case .moveDenied(let denial):
            switch denial {
            case .posixPermissionDenied:
                raw = ScanIncompleteTargetRejectionReason.posixPermissionDenied.rawValue
            case .immutable:
                raw = ScanIncompleteTargetRejectionReason.immutable.rawValue
            case .readOnlyVolume:
                raw = ScanIncompleteTargetRejectionReason.readOnlyVolume.rawValue
            case .parentUnavailable:
                raw = ScanIncompleteTargetRejectionReason.parentUnavailable.rawValue
            case .targetUnavailable, .tccDenied, .aclDenied, .unclassifiedAccessFailure:
                raw = ScanIncompleteTargetRejectionReason.unclassifiedAccessFailure.rawValue
            }
        case .identityUnavailable, .scanEvidenceUnavailable, .moveCapabilityUnavailable,
             .inconsistentSafetyEvidence:
            raw = ScanIncompleteTargetRejectionReason.unclassifiedAccessFailure.rawValue
        case .incompleteEvidenceNotCarriedForward, .emptyIncompleteEvidence,
             .unresolvedIncompleteReason, .requiresProfessionalMode:
            raw = ScanIncompleteTargetRejectionReason.missingTypedEvidence.rawValue
        }
        return .init(path: path, reason: raw)
    }

    static func probe(path: String, expectedDirectory: Bool) -> ProbeResult {
        var target = stat()
        guard lstat(path, &target) == 0 else {
            return .blocked(
                errno == ENOENT || errno == ENOTDIR ? .targetMissing : .unclassifiedAccessFailure
            )
        }

        let fileType = target.st_mode & mode_t(S_IFMT)
        guard fileType != mode_t(S_IFLNK) else { return .blocked(.symlinkNotEligible) }
        guard (fileType == mode_t(S_IFDIR)) == expectedDirectory else {
            return .blocked(.targetTypeChanged)
        }

        let immutableMask = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK)
        guard target.st_flags & immutableMask == 0 else { return .blocked(.immutable) }

        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parent = stat()
        guard lstat(parentPath, &parent) == 0,
              parent.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return .blocked(.parentUnavailable)
        }
        guard parent.st_flags & immutableMask == 0 else { return .blocked(.immutable) }

        var fileSystem = statfs()
        guard statfs(parentPath, &fileSystem) == 0 else {
            return .blocked(.unclassifiedAccessFailure)
        }
        guard fileSystem.f_flags & UInt32(MNT_RDONLY) == 0 else {
            return .blocked(.readOnlyVolume)
        }

        guard posixModeAllowsParentMutation(parent) else {
            return .blocked(.posixPermissionDenied)
        }
        let effectiveUID = geteuid()
        if parent.st_mode & mode_t(S_ISVTX) != 0,
           effectiveUID != 0,
           effectiveUID != target.st_uid,
           effectiveUID != parent.st_uid {
            return .blocked(.posixPermissionDenied)
        }
        // `faccessat(..., AT_EACCESS)` includes effective IDs and ACL evaluation. A failure is
        // intentionally kept unclassified: public APIs cannot reliably distinguish ACL from TCC.
        guard faccessat(AT_FDCWD, parentPath, W_OK | X_OK, AT_EACCESS) == 0 else {
            return .blocked(.unclassifiedAccessFailure)
        }

        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return .eligible(.init(
            device: UInt64(target.st_dev),
            inode: UInt64(target.st_ino),
            fileType: UInt16(fileType),
            resolvedPath: resolvedPath
        ))
    }

    private static func posixModeAllowsParentMutation(_ parent: stat) -> Bool {
        let uid = geteuid()
        if uid == 0 { return true }
        let mode = parent.st_mode
        if uid == parent.st_uid {
            return mode & mode_t(S_IWUSR | S_IXUSR) == mode_t(S_IWUSR | S_IXUSR)
        }

        var groupCount = getgroups(0, nil)
        var groups: [gid_t] = []
        if groupCount > 0 {
            groups = [gid_t](repeating: 0, count: Int(groupCount))
            groupCount = getgroups(groupCount, &groups)
            if groupCount < 0 { groups = [] }
        }
        groups.append(getegid())
        if groups.contains(parent.st_gid) {
            return mode & mode_t(S_IWGRP | S_IXGRP) == mode_t(S_IWGRP | S_IXGRP)
        }
        return mode & mode_t(S_IWOTH | S_IXOTH) == mode_t(S_IWOTH | S_IXOTH)
    }
}
