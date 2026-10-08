import Foundation
import Darwin
import LogKit

/// Bounded, absolute progress from the one-pass DerivedData allocation traversal.
/// There is intentionally no percentage: the filesystem does not provide a trustworthy total.
public struct DerivedDataScanProgress: Sendable, Equatable {
    public let scannedBytes: Int64
    public let fileCount: Int
    public let currentPath: String?

    public init(scannedBytes: Int64, fileCount: Int, currentPath: String?) {
        self.scannedBytes = max(0, scannedBytes)
        self.fileCount = max(0, fileCount)
        self.currentPath = currentPath
    }
}

/// Apple 工作流配套：DerivedData 按工程粒度扫描器。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §Apple）：
/// - `~/Library/Developer/Xcode/DerivedData` 下每个一级子目录命名形如
///   `MyApp-abc123xyz`，其中 `abc123xyz` 是 Xcode 为工作区生成的稳定 hash。
/// - 单个工程的 DerivedData（Build/Index/Logs/ModuleCache）动辄 1~5 GB，
///   长期切分支后会堆积 N 个旧工程残留目录；用户需要按工程粒度看占用并清理。
/// - 与既有 [KnownVersionedRoots]（整目录粒度）互补：前者负责"DerivedData 这一级"，
///   本扫描器下钻一层，给 UI 渲染「按工程的 DerivedData 占用列表」。
///
/// 与其他专用扫描器一样，采用「`static detect(home:)` 同步入口 +
/// `actor discover()` 异步入口」双形态。`estimateSize(at:)` 用 `FileManager.enumerator`
/// 遍历，优先 `totalFileAllocatedSize`，回退 `fileAllocatedSize`。
///
/// 完整性红线：
/// - DerivedData 根不存在 / 不是目录 → 完整空结果；
/// - 根枚举或子目录 metadata 失败 → 结构化 `ScanIncompleteIssue`，不能伪装成完整空结果；
/// - 旧 hits-only API 保持兼容，需要安全删除证据的调用方必须消费 evidence API。
public actor DerivedDataPerProjectScanner {

    public init() {}

    /// 异步入口：扫描 `~/Library/Developer/Xcode/DerivedData` 下每个工程子目录。
    ///
    /// - Parameter home: 用户 home 目录（注入便于测试，生产传 `FileManager.default.homeDirectoryForCurrentUser`）。
    /// - Returns: 工程命中列表；兼容入口在取消时返回空，新增调用方应使用 [discoverWithEvidence]。
    public func discover(home: URL) async -> [ProjectHit] {
        do {
            return try await discoverWithEvidence(home: home).hits
        } catch is CancellationError {
            return []
        } catch {
            let diagnostic = ScanFailureDiagnostic(
                source: .derivedData,
                stage: .discovery,
                reason: .unexpectedFailure,
                error: error
            )
            GSYLog.error(
                .scan,
                "derived_data.failure \(diagnostic.logFields) "
                    + "root=\(Self.derivedDataRoot(home: home).path)"
            )
            return []
        }
    }

    /// 异步结构化入口。取消独立抛出，不写成扫描不完整证据。
    public func discoverWithEvidence(
        home: URL,
        includeSizes: Bool = true
    ) async throws -> DiscoveryEvidence<ProjectHit> {
        try Task.checkCancellation()
        return try Self.detectWithEvidence(
            home: home,
            includeSizes: includeSizes,
            fileSystem: FileManager.default,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    /// One immutable view of the DerivedData root and its real project children.
    ///
    /// **v2026.07.16 root-cause fix:** the Workflow previously scanned the entire root for
    /// the aggregate card and then recursively scanned every first-level directory again for
    /// the project card. The snapshot API performs one recursive allocation pass and returns
    /// both projections, so AppUI can share the evidence without sharing mutable state.
    public func discoverSnapshot(home: URL) async throws -> DerivedDataScanSnapshot {
        try Task.checkCancellation()
        return try Self.detectSnapshot(
            home: home,
            fileSystem: FileManager.default,
            cancellationCheck: { try Task.checkCancellation() },
            progress: nil
        )
    }

    /// v2026.07.17 Workflow visibility contract. The callback is emitted at most once per 256
    /// regular files and no more than 10 Hz, plus one terminal sample. It runs on the caller's
    /// scan worker and never changes snapshot accounting or cancellation semantics.
    public func discoverSnapshot(
        home: URL,
        progress: @escaping @Sendable (DerivedDataScanProgress) -> Void
    ) async throws -> DerivedDataScanSnapshot {
        try Task.checkCancellation()
        return try Self.detectSnapshot(
            home: home,
            fileSystem: FileManager.default,
            cancellationCheck: { try Task.checkCancellation() },
            progress: progress
        )
    }

    /// 同步入口：纯 FS 遍历，无 subprocess，供单测直接调用。
    ///
    /// 流程：
    /// 1. 计算 DerivedData 根路径 `<home>/Library/Developer/Xcode/DerivedData`；
    /// 2. 列一级子目录，跳过 `ModuleCache.noindex` / `Manifest.plist` 等非工程项（仅保留目录）；
    /// 3. 对每个目录：解析工程名 + 估算大小 + 取 mtime。
    public nonisolated static func detect(
        home: URL,
        includeSizes: Bool = true
    ) -> [ProjectHit] {
        detectWithEvidence(home: home, includeSizes: includeSizes).hits
    }

    /// 同步结构化入口。同步调用没有任务所有权，因此不会自行解释取消；异步入口负责取消传播。
    public nonisolated static func detectWithEvidence(
        home: URL,
        includeSizes: Bool = true
    ) -> DiscoveryEvidence<ProjectHit> {
        do {
            return try detectWithEvidence(
                home: home,
                includeSizes: includeSizes,
                fileSystem: FileManager.default,
                cancellationCheck: {}
            )
        } catch {
            // 空 cancellationCheck 不会抛；保留类型安全的不可达分支并留下诊断。
            let diagnostic = ScanFailureDiagnostic(
                source: .derivedData,
                stage: .discovery,
                reason: .unexpectedFailure,
                error: error
            )
            GSYLog.error(
                .scan,
                "derived_data.failure \(diagnostic.logFields) "
                    + "root=\(derivedDataRoot(home: home).path)"
            )
            return DiscoveryEvidence(hits: [], incompleteIssues: [
                ScanIncompleteIssue(path: derivedDataRoot(home: home).path, reason: .enumerationFailed)
            ])
        }
    }

    /// Synchronous snapshot entry used by tests and detached Workflow workers.
    public nonisolated static func detectSnapshot(home: URL) -> DerivedDataScanSnapshot {
        do {
            return try detectSnapshot(
                home: home,
                fileSystem: FileManager.default,
                cancellationCheck: {}
            )
        } catch {
            let root = derivedDataRoot(home: home)
            let diagnostic = ScanFailureDiagnostic(
                source: .derivedData,
                stage: .snapshot,
                reason: .unexpectedFailure,
                error: error
            )
            GSYLog.error(
                .scan,
                "derived_data.failure \(diagnostic.logFields) root=\(root.path)"
            )
            let issue = ScanIncompleteIssue(path: root.path, reason: .enumerationFailed)
            return DerivedDataScanSnapshot(
                rootURL: root,
                rootExists: true,
                rootSizeBytes: nil,
                projects: DiscoveryEvidence(hits: [], incompleteIssues: [issue]),
                rootIncompleteIssues: [issue],
                sharedDirectoryCount: 0
            )
        }
    }

    /// 模块内注入入口，供 WorkflowRegistry 传播取消及测试精确制造 I/O 故障。
    nonisolated static func detectWithEvidence(
        home: URL,
        includeSizes: Bool,
        fileSystem: any DynamicDiscoveryFileSystem,
        cancellationCheck: () throws -> Void
    ) throws -> DiscoveryEvidence<ProjectHit> {
        if includeSizes {
            return try detectSnapshot(
                home: home,
                fileSystem: fileSystem,
                cancellationCheck: cancellationCheck
            ).projects
        }

        return try discoverLayout(
            home: home,
            fileSystem: fileSystem,
            cancellationCheck: cancellationCheck
        ).projectEvidence()
    }

    /// Shared snapshot implementation. The shallow layout discovery and the recursive size
    /// traversal are deliberately separate: classification is based on Xcode structure and
    /// metadata, while byte accounting never needs to guess whether an entry is a project.
    nonisolated static func detectSnapshot(
        home: URL,
        fileSystem: any DynamicDiscoveryFileSystem,
        cancellationCheck: () throws -> Void,
        progress: (@Sendable (DerivedDataScanProgress) -> Void)? = nil
    ) throws -> DerivedDataScanSnapshot {
        let layout = try discoverLayout(
            home: home,
            fileSystem: fileSystem,
            cancellationCheck: cancellationCheck
        )
        guard layout.rootExists else {
            return DerivedDataScanSnapshot(
                rootURL: layout.root,
                rootExists: false,
                rootSizeBytes: 0,
                projects: layout.projectEvidence(),
                rootIncompleteIssues: layout.incompleteIssues,
                sharedDirectoryCount: layout.sharedDirectoryCount
            )
        }
        guard layout.incompleteIssues.isEmpty || !layout.projects.isEmpty else {
            return DerivedDataScanSnapshot(
                rootURL: layout.root,
                rootExists: true,
                rootSizeBytes: nil,
                projects: layout.projectEvidence(),
                rootIncompleteIssues: layout.incompleteIssues,
                sharedDirectoryCount: layout.sharedDirectoryCount
            )
        }

        let allocation = try measureRootOnce(
            layout: layout,
            fileSystem: fileSystem,
            cancellationCheck: cancellationCheck,
            progress: progress
        )
        let allIssues = layout.incompleteIssues + allocation.incompleteIssues
        let resolvedRoot = layout.root.resolvingSymlinksInPath()
        let hits = layout.projects.map { project -> ProjectHit in
            let resolvedProjectPath = project.url.resolvingSymlinksInPath().path
            let rebasedProjectPath = resolvedRoot
                .appendingPathComponent(project.url.lastPathComponent, isDirectory: true)
                .path
            let relevantIssues = allIssues.filter { issue in
                isSameOrDescendant(path: issue.path, root: project.url.path)
                    || isSameOrDescendant(path: issue.path, root: resolvedProjectPath)
                    || isSameOrDescendant(path: issue.path, root: rebasedProjectPath)
            }
            return ProjectHit(
                url: project.url,
                projectName: project.projectName,
                sizeBytes: relevantIssues.isEmpty
                    ? allocation.projectBytes[project.url.lastPathComponent, default: 0]
                    : nil,
                modificationDate: project.modificationDate
            )
        }
        return DerivedDataScanSnapshot(
            rootURL: layout.root,
            rootExists: true,
            rootSizeBytes: allIssues.isEmpty ? allocation.rootBytes : nil,
            projects: DiscoveryEvidence(hits: hits, incompleteIssues: allIssues),
            rootIncompleteIssues: allIssues,
            sharedDirectoryCount: layout.sharedDirectoryCount,
            retainedHardlinkIdentityCount: allocation.retainedHardlinkIdentityCount
        )
    }

    private struct LayoutProject {
        let url: URL
        let projectName: String
        let modificationDate: Date?
    }

    private struct DerivedDataLayout {
        let root: URL
        let rootExists: Bool
        let projects: [LayoutProject]
        let incompleteIssues: [ScanIncompleteIssue]
        let sharedDirectoryCount: Int

        func projectEvidence() -> DiscoveryEvidence<ProjectHit> {
            DiscoveryEvidence(
                hits: projects.map {
                    ProjectHit(
                        url: $0.url,
                        projectName: $0.projectName,
                        sizeBytes: nil,
                        modificationDate: $0.modificationDate
                    )
                },
                incompleteIssues: incompleteIssues
            )
        }
    }

    private struct RootAllocation {
        let rootBytes: Int64
        let projectBytes: [String: Int64]
        let incompleteIssues: [ScanIncompleteIssue]
        /// Only identities with more than one live pathname need cross-path attribution.
        /// Keeping every ordinary inode here makes memory O(all files) for no correctness gain.
        let retainedHardlinkIdentityCount: Int
    }

    /// Physical identity for hardlink accounting. APFS clones intentionally remain distinct:
    /// they have different inodes and neither `st_blocks` nor URL allocated-size metadata can
    /// prove exclusive/reclaimable extents.
    private struct PhysicalFileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct PhysicalFileMetadata {
        let identity: PhysicalFileIdentity
        let linkCount: UInt64
    }

    private struct PhysicalFileAttribution {
        let bytes: Int64
        var projectName: String?
    }

    private nonisolated static func discoverLayout(
        home: URL,
        fileSystem: any DynamicDiscoveryFileSystem,
        cancellationCheck: () throws -> Void
    ) throws -> DerivedDataLayout {
        let root = derivedDataRoot(home: home)

        try cancellationCheck()
        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileSystem.attributesOfItem(atPath: root.path)
        } catch {
            if DiscoveryFileErrorClassifier.isMissing(error) {
                return DerivedDataLayout(
                    root: root,
                    rootExists: false,
                    projects: [],
                    incompleteIssues: [],
                    sharedDirectoryCount: 0
                )
            }
            return DerivedDataLayout(
                root: root,
                rootExists: true,
                projects: [],
                incompleteIssues: [ScanIncompleteIssue(
                    path: root.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                    for: error,
                    fallback: .metadataUnavailable
                    )
                )],
                sharedDirectoryCount: 0
            )
        }
        guard let rootType = rootAttributes[.type] as? FileAttributeType else {
            return DerivedDataLayout(
                root: root,
                rootExists: true,
                projects: [],
                incompleteIssues: [ScanIncompleteIssue(path: root.path, reason: .metadataUnavailable)],
                sharedDirectoryCount: 0
            )
        }
        guard rootType == .typeDirectory || rootType == .typeSymbolicLink else {
            return DerivedDataLayout(
                root: root,
                rootExists: false,
                projects: [],
                incompleteIssues: [],
                sharedDirectoryCount: 0
            )
        }

        let childNames: [String]
        do {
            childNames = try fileSystem.contentsOfDirectory(atPath: root.path).sorted()
        } catch {
            return DerivedDataLayout(
                root: root,
                rootExists: true,
                projects: [],
                incompleteIssues: [ScanIncompleteIssue(
                    path: root.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .enumerationFailed
                    )
                )],
                sharedDirectoryCount: 0
            )
        }

        var projects: [LayoutProject] = []
        var incompleteIssues: [ScanIncompleteIssue] = []
        var sharedDirectoryCount = 0
        projects.reserveCapacity(childNames.count)
        for name in childNames {
            try cancellationCheck()
            if name.hasPrefix(".") { continue }
            let child = root.appendingPathComponent(name, isDirectory: true)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileSystem.attributesOfItem(atPath: child.path)
            } catch {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .metadataUnavailable
                    )
                ))
                continue
            }
            // 仅保留目录；非目录（如 Manifest.plist）忽略
            guard let type = attributes[.type] as? FileAttributeType else {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
                continue
            }
            guard type == .typeDirectory else { continue }
            let classification = try classifyProjectDirectory(
                name: name,
                at: child,
                fileSystem: fileSystem,
                shouldCancel: { Task.isCancelled }
            )
            if let issue = classification.incompleteIssue {
                incompleteIssues.append(issue)
            }
            guard classification.isProject else {
                if classification.incompleteIssue == nil {
                    sharedDirectoryCount += 1
                }
                continue
            }
            let modificationDate = attributes[.modificationDate] as? Date
            if modificationDate == nil {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
            }
            projects.append(LayoutProject(
                url: child,
                projectName: parseProjectName(from: name),
                modificationDate: modificationDate
            ))
        }
        try cancellationCheck()
        return DerivedDataLayout(
            root: root,
            rootExists: true,
            projects: projects,
            incompleteIssues: incompleteIssues,
            sharedDirectoryCount: sharedDirectoryCount
        )
    }

    /// Xcode project directories carry workspace metadata and use a stable hashed suffix.
    /// Shared caches use structural `.noindex` containers and do not satisfy that identity.
    /// This intentionally avoids a growing deny-list of cache product names: new shared
    /// caches are excluded by shape, including CompilationCache.noindex and
    /// SDKStatCaches.noindex, without adding either spelling to production logic.
    private struct ProjectDirectoryClassification {
        let isProject: Bool
        let incompleteIssue: ScanIncompleteIssue?
    }

    /// v2026.07.18：`info.plist` 缺失是正常布局；已有文件不可读/损坏不能再被静默当成
    /// “不是工程”。若目录名的 hash 形状已能独立证明工程身份，保留完整结果并仅写本地
    /// 诊断；否则通过现有 DiscoveryEvidence 暴露 typed incomplete。
    private nonisolated static func classifyProjectDirectory(
        name: String,
        at url: URL,
        fileSystem: any DynamicDiscoveryFileSystem,
        shouldCancel: @Sendable () -> Bool
    ) throws -> ProjectDirectoryClassification {
        if url.pathExtension.caseInsensitiveCompare("noindex") == .orderedSame {
            return ProjectDirectoryClassification(isProject: false, incompleteIssue: nil)
        }
        let hasHashedIdentity = hasProjectHashSuffix(name)
        let plistURL = url.appendingPathComponent("info.plist")

        let data: Data
        do {
            data = try fileSystem.dataContents(
                of: plistURL,
                maximumBytes: BoundedLocalFileReader.defaultMaximumBytes,
                shouldCancel: shouldCancel
            )
        } catch {
            if error as? BoundedLocalFileReadError == .cancelled {
                throw CancellationError()
            }
            if DiscoveryFileErrorClassifier.isMissing(error) {
                return ProjectDirectoryClassification(
                    isProject: hasHashedIdentity,
                    incompleteIssue: nil
                )
            }
            let boundedError = error as? BoundedLocalFileReadError
            let reason: ScanIncompleteReason = {
                guard let code = boundedError?.posixErrorCode else {
                    return DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .metadataUnavailable
                    )
                }
                return code == EACCES || code == EPERM
                    ? .permissionDenied
                    : .metadataUnavailable
            }()
            let issue = ScanIncompleteIssue(
                path: plistURL.path,
                reason: reason,
                stage: .metadata,
                posixErrorCode: boundedError?.posixErrorCode
                    ?? DiscoveryFileErrorClassifier.posixErrorCode(for: error)
            )
            logWorkspaceMarkerFailure(
                path: plistURL.path,
                kind: reason == .permissionDenied ? "permissionDenied" : "unreadable",
                fallbackAccepted: hasHashedIdentity,
                posixErrorCode: issue.posixErrorCode
            )
            return ProjectDirectoryClassification(
                isProject: hasHashedIdentity,
                incompleteIssue: hasHashedIdentity ? nil : issue
            )
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            let issue = ScanIncompleteIssue(
                path: plistURL.path,
                reason: .metadataUnavailable,
                stage: .metadata
            )
            logWorkspaceMarkerFailure(
                path: plistURL.path,
                kind: "malformed",
                fallbackAccepted: hasHashedIdentity,
                posixErrorCode: nil
            )
            return ProjectDirectoryClassification(
                isProject: hasHashedIdentity,
                incompleteIssue: hasHashedIdentity ? nil : issue
            )
        }
        guard let dictionary = propertyList as? [String: Any] else {
            let issue = ScanIncompleteIssue(
                path: plistURL.path,
                reason: .metadataUnavailable,
                stage: .metadata
            )
            logWorkspaceMarkerFailure(
                path: plistURL.path,
                kind: "invalidRoot",
                fallbackAccepted: hasHashedIdentity,
                posixErrorCode: nil
            )
            return ProjectDirectoryClassification(
                isProject: hasHashedIdentity,
                incompleteIssue: hasHashedIdentity ? nil : issue
            )
        }
        if dictionary["WorkspacePath"] is String || dictionary["ProjectPath"] is String {
            return ProjectDirectoryClassification(isProject: true, incompleteIssue: nil)
        }
        return ProjectDirectoryClassification(
            isProject: hasHashedIdentity,
            incompleteIssue: nil
        )
    }

    private nonisolated static func hasProjectHashSuffix(_ name: String) -> Bool {
        guard let dash = name.lastIndex(of: "-"), dash != name.startIndex else { return false }
        let suffix = name[name.index(after: dash)...]
        guard suffix.count >= 3 else { return false }
        return suffix.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 122)
        }
    }

    private nonisolated static func logWorkspaceMarkerFailure(
        path: String,
        kind: String,
        fallbackAccepted: Bool,
        posixErrorCode: Int32?
    ) {
        let errnoValue = posixErrorCode.map { String($0) } ?? "none"
        GSYLog.warning(
            .scan,
            "derived_data.workspace_marker_failure kind=\(kind) path=\(path) "
                + "hashed_fallback=\(fallbackAccepted) "
                + "errno=\(errnoValue)"
        )
    }

    /// One recursive enumeration for both aggregate bytes and all project buckets.
    ///
    /// **v2026.07.16 root-cause fix:** the former shared snapshot summed every pathname and
    /// therefore counted one physical hardlinked file multiple times, unlike BulkScanner's
    /// default `(device, inode)` contract. Root bytes now count each physical identity once.
    /// If one identity is linked into multiple project directories, exactly one deterministic
    /// owner receives it: the lexicographically smallest project child name. A link first seen
    /// in a shared cache can still be attributed later to a project, but never to two projects.
    private nonisolated static func measureRootOnce(
        layout: DerivedDataLayout,
        fileSystem: any DynamicDiscoveryFileSystem = FileManager.default,
        cancellationCheck: () throws -> Void,
        progress: (@Sendable (DerivedDataScanProgress) -> Void)?
    ) throws -> RootAllocation {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isRegularFileKey,
        ]
        let isTopLevelSymlink = ((try? fileSystem.attributesOfItem(atPath: layout.root.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
        let enumerationRoot = isTopLevelSymlink ? layout.root.resolvingSymlinksInPath() : layout.root
        var issues: [ScanIncompleteIssue] = []
        guard let enumerator = FileManager.default.enumerator(
            at: enumerationRoot,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { failedURL, error in
                issues.append(ScanIncompleteIssue(
                    path: failedURL.standardizedFileURL.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .enumerationFailed
                    )
                ))
                return true
            }
        ) else {
            return RootAllocation(
                rootBytes: 0,
                projectBytes: [:],
                incompleteIssues: [ScanIncompleteIssue(
                    path: layout.root.path,
                    reason: .enumerationFailed
                )],
                retainedHardlinkIdentityCount: 0
            )
        }

        let projectNames = Set(layout.projects.map { $0.url.lastPathComponent })
        let rootPrefix = enumerationRoot.standardizedFileURL.path + "/"
        var rootBytes: Int64 = 0
        var projectBytes: [String: Int64] = [:]
        var physicalFiles: [PhysicalFileIdentity: PhysicalFileAttribution] = [:]
        var scannedFiles = 0
        var lastProgressEmit = Date.distantPast
        var lastScannedPath: String?
        for case let fileURL as URL in enumerator {
            try cancellationCheck()
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: keys)
            } catch {
                issues.append(ScanIncompleteIssue(
                    path: fileURL.standardizedFileURL.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .metadataUnavailable
                    )
                ))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            scannedFiles += 1
            lastScannedPath = path
            defer {
                // Read the clock only once per bounded batch; this keeps progress visibility
                // out of the per-file hot path while preserving real absolute counters.
                if progress != nil, scannedFiles.isMultiple(of: 256) {
                    let now = Date()
                    if now.timeIntervalSince(lastProgressEmit) >= 0.1 {
                        lastProgressEmit = now
                        progress?(DerivedDataScanProgress(
                            scannedBytes: rootBytes,
                            fileCount: scannedFiles,
                            currentPath: path
                        ))
                    }
                }
            }
            let projectName: String? = {
                guard path.hasPrefix(rootPrefix) else { return nil }
                let relative = path.dropFirst(rootPrefix.count)
                guard let first = relative.split(separator: "/", maxSplits: 1).first else {
                    return nil
                }
                let childName = String(first)
                return projectNames.contains(childName) ? childName : nil
            }()
            let metadata: PhysicalFileMetadata
            do {
                metadata = try physicalFileMetadata(at: fileURL)
            } catch let error as POSIXIdentityError {
                issues.append(ScanIncompleteIssue(
                    path: path,
                    reason: .metadataUnavailable,
                    stage: .metadata,
                    posixErrorCode: error.code
                ))
                continue
            } catch {
                issues.append(ScanIncompleteIssue(
                    path: path,
                    reason: .metadataUnavailable,
                    stage: .metadata
                ))
                continue
            }

            let bytes = max(0, Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))

            // v2026.07.17 dynamic-link safety: consult the retained ledger before the
            // single-link fast path. A hardlink observed earlier can drop from nlink > 1 to
            // nlink == 1 while this live scan is running; its identity must still be de-duped.
            if var existing = physicalFiles[metadata.identity] {
                if let projectName {
                    if let currentOwner = existing.projectName {
                        if projectName < currentOwner {
                            projectBytes[currentOwner, default: 0] -= existing.bytes
                            projectBytes[projectName, default: 0] &+= existing.bytes
                            existing.projectName = projectName
                            physicalFiles[metadata.identity] = existing
                        }
                    } else {
                        projectBytes[projectName, default: 0] &+= existing.bytes
                        existing.projectName = projectName
                        physicalFiles[metadata.identity] = existing
                    }
                }
                continue
            }

            // v2026.07.17 memory root-cause fix: a file whose link count is one at first
            // observation is counted immediately instead of retaining one dictionary entry per
            // DerivedData file. Real hardlinks still use the exact (device, inode) ledger below,
            // so stable trees keep root de-duplication and deterministic cross-project
            // attribution. APFS clones have distinct inodes. A hardlink created only after this
            // first single-link observation cannot be correlated without retaining every inode;
            // live filesystem enumeration is therefore not a point-in-time namespace snapshot.
            if metadata.linkCount <= 1 {
                rootBytes &+= bytes
                if let projectName {
                    projectBytes[projectName, default: 0] &+= bytes
                }
                continue
            }

            rootBytes &+= bytes
            if let projectName {
                projectBytes[projectName, default: 0] &+= bytes
            }
            physicalFiles[metadata.identity] = PhysicalFileAttribution(
                bytes: bytes,
                projectName: projectName
            )
        }
        try cancellationCheck()
        progress?(DerivedDataScanProgress(
            scannedBytes: rootBytes,
            fileCount: scannedFiles,
            currentPath: lastScannedPath
        ))
        return RootAllocation(
            rootBytes: rootBytes,
            projectBytes: projectBytes,
            incompleteIssues: issues,
            retainedHardlinkIdentityCount: physicalFiles.count
        )
    }

    private struct POSIXIdentityError: Error {
        let code: Int32
    }

    private nonisolated static func physicalFileMetadata(
        at url: URL
    ) throws -> PhysicalFileMetadata {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            guard lstat(path, &metadata) == 0 else { return errno }
            return 0
        }
        guard result == 0 else { throw POSIXIdentityError(code: result) }
        return PhysicalFileMetadata(
            identity: PhysicalFileIdentity(
                device: UInt64(bitPattern: Int64(metadata.st_dev)),
                inode: UInt64(metadata.st_ino)
            ),
            linkCount: UInt64(metadata.st_nlink)
        )
    }

    private nonisolated static func normalizeIssuePath(_ path: String) -> String {
        let dataPrefix = Firmlinks.recommendedDataVolumeRoot.path
        let stripped: String
        if path == dataPrefix {
            stripped = "/"
        } else if path.hasPrefix(dataPrefix + "/") {
            stripped = String(path.dropFirst(dataPrefix.count))
        } else {
            stripped = path
        }
        return URL(fileURLWithPath: stripped).standardizedFileURL.path
    }

    private nonisolated static func isSameOrDescendant(path: String, root: String) -> Bool {
        let normalizedPath = normalizeIssuePath(path)
        let normalizedRoot = normalizeIssuePath(root)
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private nonisolated static func derivedDataRoot(home: URL) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
    }

    private nonisolated static func incomplete(
        path: String,
        reason: ScanIncompleteReason
    ) -> DiscoveryEvidence<ProjectHit> {
        let issue = ScanIncompleteIssue(path: path, reason: reason)
        GSYLog.warning(.scan, "DerivedData discovery incomplete path=\(path) reason=\(reason.rawValue)")
        return DiscoveryEvidence(hits: [], incompleteIssues: [issue])
    }

    // MARK: - 工程名解析

    /// 从形如 `MyApp-abc123xyz` 的子目录名中剥出 `MyApp`。
    ///
    /// 规则：
    /// - 截到**最后一个** `-` 之前；Xcode 的 hash 段不含 `-`，所以 rsplit 一次就够；
    /// - 若没有 `-`（异常命名）或剥完是空串，直接返回原名兜底。
    static func parseProjectName(from folderName: String) -> String {
        guard let dashIndex = folderName.lastIndex(of: "-") else {
            return folderName
        }
        let prefix = folderName[..<dashIndex]
        return prefix.isEmpty ? folderName : String(prefix)
    }

    // MARK: - sizeBytes 估算

    /// 遍历目录累加 totalFileAllocatedSize，回退 fileAllocatedSize。
    ///
    /// 失败语义：路径不存在 / 不是目录 / 无权限读 → 返回 `nil`（UI 侧显示 "—"）。
    static func estimateSize(at path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        do {
            return try estimateSizeWithEvidence(
                at: URL(fileURLWithPath: path, isDirectory: true),
                cancellationCheck: {}
            ).sizeBytes
        } catch {
            // 空 cancellationCheck 不会抛；保留不可达分支的诊断，兼容 API 仍以 nil 表示未知。
            let diagnostic = ScanFailureDiagnostic(
                source: .derivedData,
                stage: .sizeEstimation,
                reason: .unexpectedFailure,
                error: error
            )
            GSYLog.error(
                .scan,
                "derived_data.failure \(diagnostic.logFields) path=\(path)"
            )
            return nil
        }
    }

    private struct DirectorySizeResult {
        let sizeBytes: Int64?
        let incompleteIssues: [ScanIncompleteIssue]
    }

    private nonisolated static func estimateSizeWithEvidence(
        at url: URL,
        cancellationCheck: () throws -> Void
    ) throws -> DirectorySizeResult {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        var incompleteIssues: [ScanIncompleteIssue] = []
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { failedURL, error in
                incompleteIssues.append(ScanIncompleteIssue(
                    path: failedURL.standardizedFileURL.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .enumerationFailed
                    )
                ))
                return true
            }
        ) else {
            return DirectorySizeResult(
                sizeBytes: nil,
                incompleteIssues: [ScanIncompleteIssue(path: url.path, reason: .enumerationFailed)]
            )
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            try cancellationCheck()
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: keys)
            } catch {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: fileURL.standardizedFileURL.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .metadataUnavailable
                    )
                ))
                continue
            }
            if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        try cancellationCheck()
        return DirectorySizeResult(
            sizeBytes: incompleteIssues.isEmpty ? total : nil,
            incompleteIssues: incompleteIssues
        )
    }
}

/// A single filesystem transaction projected as both the whole DerivedData root and the
/// subset of directories proven to be Xcode projects.
public struct DerivedDataScanSnapshot: Sendable {
    public let rootURL: URL
    public let rootExists: Bool
    public let rootSizeBytes: Int64?
    public let projects: DiscoveryEvidence<ProjectHit>
    public let rootIncompleteIssues: [ScanIncompleteIssue]
    public let sharedDirectoryCount: Int
    /// Internal performance evidence used by regression tests. Ordinary files are accounted
    /// immediately; only real multi-link identities may remain in the attribution ledger.
    let retainedHardlinkIdentityCount: Int

    public init(
        rootURL: URL,
        rootExists: Bool,
        rootSizeBytes: Int64?,
        projects: DiscoveryEvidence<ProjectHit>,
        rootIncompleteIssues: [ScanIncompleteIssue],
        sharedDirectoryCount: Int
    ) {
        self.init(
            rootURL: rootURL,
            rootExists: rootExists,
            rootSizeBytes: rootSizeBytes,
            projects: projects,
            rootIncompleteIssues: rootIncompleteIssues,
            sharedDirectoryCount: sharedDirectoryCount,
            retainedHardlinkIdentityCount: 0
        )
    }

    init(
        rootURL: URL,
        rootExists: Bool,
        rootSizeBytes: Int64?,
        projects: DiscoveryEvidence<ProjectHit>,
        rootIncompleteIssues: [ScanIncompleteIssue],
        sharedDirectoryCount: Int,
        retainedHardlinkIdentityCount: Int
    ) {
        self.rootURL = rootURL
        self.rootExists = rootExists
        self.rootSizeBytes = rootSizeBytes
        self.projects = projects
        self.rootIncompleteIssues = DiscoveryEvidence<ProjectHit>(
            hits: [],
            incompleteIssues: rootIncompleteIssues
        ).incompleteIssues
        self.sharedDirectoryCount = sharedDirectoryCount
        self.retainedHardlinkIdentityCount = max(0, retainedHardlinkIdentityCount)
    }
}

/// 单个 DerivedData 工程子目录的命中记录。
public struct ProjectHit: Sendable, Hashable, Identifiable {
    /// 子目录绝对 URL，如 `~/Library/Developer/Xcode/DerivedData/MyApp-abc123xyz`。
    public let url: URL
    /// 工程名（已剥掉 `-xxx` hash 后缀），如 `MyApp`。
    public let projectName: String
    /// 目录累计大小（字节）。`nil` 表示路径不存在或无权限读。
    public let sizeBytes: Int64?
    /// 目录 mtime。`nil` 表示 stat 失败。
    public let modificationDate: Date?

    public var id: URL { url }

    public init(url: URL,
                projectName: String,
                sizeBytes: Int64?,
                modificationDate: Date?) {
        self.url = url
        self.projectName = projectName
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
    }
}
