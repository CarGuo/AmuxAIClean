import Foundation
import LogKit

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
/// 与 [SimctlRuntimeScanner] 的关系：
/// - 同样采用「`static detect(home:)` 同步入口 + `actor discover()` 异步入口」双形态；
/// - `estimateSize(at:)` 实现风格完全对齐 [SimctlRuntimeScanner.estimateSize]——
///   `FileManager.enumerator` 遍历，优先 `totalFileAllocatedSize`，回退 `fileAllocatedSize`。
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
            GSYLog.error(.scan, "DerivedData discovery unexpected error: \(error)")
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
            GSYLog.error(.scan, "DerivedData synchronous discovery unexpected error: \(error)")
            return DiscoveryEvidence(hits: [], incompleteIssues: [
                ScanIncompleteIssue(path: derivedDataRoot(home: home).path, reason: .enumerationFailed)
            ])
        }
    }

    /// 模块内注入入口，供 WorkflowRegistry 传播取消及测试精确制造 I/O 故障。
    nonisolated static func detectWithEvidence(
        home: URL,
        includeSizes: Bool,
        fileSystem: any DynamicDiscoveryFileSystem,
        cancellationCheck: () throws -> Void
    ) throws -> DiscoveryEvidence<ProjectHit> {
        let root = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)

        try cancellationCheck()
        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileSystem.attributesOfItem(atPath: root.path)
        } catch {
            if DiscoveryFileErrorClassifier.isMissing(error) {
                return DiscoveryEvidence(hits: [])
            }
            return incomplete(
                path: root.path,
                reason: DiscoveryFileErrorClassifier.incompleteReason(
                    for: error,
                    fallback: .metadataUnavailable
                )
            )
        }
        guard let rootType = rootAttributes[.type] as? FileAttributeType else {
            return incomplete(path: root.path, reason: .metadataUnavailable)
        }
        guard rootType == .typeDirectory || rootType == .typeSymbolicLink else {
            return DiscoveryEvidence(hits: [])
        }

        let childNames: [String]
        do {
            childNames = try fileSystem.contentsOfDirectory(atPath: root.path).sorted()
        } catch {
            return incomplete(
                path: root.path,
                reason: DiscoveryFileErrorClassifier.incompleteReason(
                    for: error,
                    fallback: .enumerationFailed
                )
            )
        }

        var hits: [ProjectHit] = []
        var incompleteIssues: [ScanIncompleteIssue] = []
        hits.reserveCapacity(childNames.count)
        for name in childNames {
            try cancellationCheck()
            if name.hasPrefix(".") || name == "ModuleCache.noindex" { continue }
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
            let modificationDate = attributes[.modificationDate] as? Date
            if modificationDate == nil {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
            }
            let sizeResult: DirectorySizeResult
            if includeSizes {
                sizeResult = try estimateSizeWithEvidence(
                    at: child,
                    cancellationCheck: cancellationCheck
                )
                incompleteIssues.append(contentsOf: sizeResult.incompleteIssues)
            } else {
                sizeResult = DirectorySizeResult(sizeBytes: nil, incompleteIssues: [])
            }
            hits.append(ProjectHit(
                url: child,
                projectName: parseProjectName(from: name),
                sizeBytes: sizeResult.sizeBytes,
                modificationDate: modificationDate
            ))
        }
        try cancellationCheck()
        return DiscoveryEvidence(hits: hits, incompleteIssues: incompleteIssues)
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

    // MARK: - sizeBytes 估算（对位 SimctlRuntimeScanner.estimateSize 风格）

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
            GSYLog.error(.scan, "DerivedData size estimation unexpected error path=\(path): \(error)")
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
