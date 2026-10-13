import Foundation
import LogKit

/// WebNode 工作流配套：散落 `node_modules` 扫描器。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §WebNode）：
/// - 前端工程的 `node_modules` 体积通常 200 MB ~ 2 GB，且会散落在用户的多个 dev 根
///   （`~/Developer` / `~/Projects` / `~/Code` / `~/workspace` / `~/src`）；
/// - 用户切到新工程后旧工程的 `node_modules` 长期不清理，是 macOS 磁盘头号黑洞之一；
/// - 与 pnpm-store / yarn-cache 等「全局可重建缓存」不同，单个工程的 `node_modules`
///   是工程本地的"半瞬态产物"，删除后 `npm install` / `pnpm install` 可重建。
///
/// 与 [DerivedDataPerProjectScanner] 的关系：
/// - 同样采用「`static detect(home:)` 同步入口 + `actor discover()` 异步入口」双形态；
/// - `estimateSize(at:)` 实现风格对齐 [DerivedDataPerProjectScanner.estimateSize]：
///   `FileManager.enumerator` 遍历，
///   优先 `totalFileAllocatedSize`，回退 `fileAllocatedSize`；
/// - 命中 `node_modules` 后**不再下钻**——node_modules 内部可能藏 5 万+ 文件，
///   下钻会让单次扫描爆栈到分钟级，违背"快速列清单"目标。
///
/// 完整性红线：
/// - dev 根不存在 / 非目录 → 完整地跳过该根；
/// - 根属性、目录枚举或子节点 metadata 失败 → 保留其它 hits 并输出 `ScanIncompleteIssue`；
/// - 单个 `node_modules` 大小估算失败 → `sizeBytes` 为 `nil`，但仍纳入结果；
/// - 旧 hits-only API 保持兼容，需要安全删除证据的调用方必须消费 evidence API。
public actor NodeModulesScanner {

    public init() {}

    /// 异步入口：扫描 5 个常见 dev 根下的所有 `node_modules` 子目录。
    ///
    /// - Parameter home: 用户 home URL（注入便于测试，生产传 `FileManager.default.homeDirectoryForCurrentUser`）。
    /// - Returns: 命中列表；兼容入口在取消时返回空，新增调用方应使用 [discoverWithEvidence]。
    public func discover(home: URL) async -> [NodeModulesHit] {
        do {
            return try await discoverWithEvidence(home: home).hits
        } catch is CancellationError {
            return []
        } catch {
            AmuxLog.error(.scan, "NodeModules discovery unexpected error: \(error)")
            return []
        }
    }

    /// 异步结构化入口。取消独立抛出，不写成扫描不完整证据。
    public func discoverWithEvidence(
        home: URL,
        maxDepth: Int = 4,
        includeSizes: Bool = true
    ) async throws -> DiscoveryEvidence<NodeModulesHit> {
        try Task.checkCancellation()
        return try Self.detectWithEvidence(
            home: home,
            maxDepth: maxDepth,
            includeSizes: includeSizes,
            fileSystem: FileManager.default,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    /// 同步入口：纯 FS 遍历，无 subprocess，供单测直接调用。
    ///
    /// 流程：
    /// 1. 拼出 5 个常见 dev 根（不存在的根直接跳过）；
    /// 2. 对每个根做 BFS/DFS 递归（深度 ≤ `maxDepth`，根 = 深度 0）；
    /// 3. 命中 `node_modules` 后**不下钻**，把 hit 收集到结果；
    /// 4. 跳过隐藏目录（`.git` / `.DS_Store` / 以 `.` 开头的任何项）。
    ///
    /// - Parameters:
    ///   - home: 用户 home URL。
    ///   - maxDepth: 相对每个根的最大递归深度，根 = 深度 0，默认 4。
    /// - Returns: 命中列表；任何根失败一律跳过，整体不抛。
    public nonisolated static func detect(
        home: URL,
        maxDepth: Int = 4,
        includeSizes: Bool = true
    ) -> [NodeModulesHit] {
        detectWithEvidence(
            home: home,
            maxDepth: maxDepth,
            includeSizes: includeSizes
        ).hits
    }

    /// 同步结构化入口。同步调用没有任务所有权，因此不会自行解释取消；异步入口负责取消传播。
    public nonisolated static func detectWithEvidence(
        home: URL,
        maxDepth: Int = 4,
        includeSizes: Bool = true
    ) -> DiscoveryEvidence<NodeModulesHit> {
        do {
            return try detectWithEvidence(
                home: home,
                maxDepth: maxDepth,
                includeSizes: includeSizes,
                fileSystem: FileManager.default,
                cancellationCheck: {}
            )
        } catch {
            // 空 cancellationCheck 不会抛；保留类型安全的不可达分支并留下诊断。
            AmuxLog.error(.scan, "NodeModules synchronous discovery unexpected error: \(error)")
            return DiscoveryEvidence(hits: [], incompleteIssues: [
                ScanIncompleteIssue(path: home.path, reason: .enumerationFailed)
            ])
        }
    }

    /// 模块内注入入口，供 WorkflowRegistry 传播取消及测试精确制造 I/O 故障。
    nonisolated static func detectWithEvidence(
        home: URL,
        maxDepth: Int,
        includeSizes: Bool,
        fileSystem: any DynamicDiscoveryFileSystem,
        cancellationCheck: () throws -> Void
    ) throws -> DiscoveryEvidence<NodeModulesHit> {
        let devRootNames = ["Developer", "Projects", "Code", "workspace", "src"]
        var results: [NodeModulesHit] = []
        var incompleteIssues: [ScanIncompleteIssue] = []
        // visited 跨所有 dev 根共享，确保用户在 ~/Projects ↔ ~/Developer 互链时不重复 walk。
        var visited: Set<String> = []
        // 整次扫描共享 size 估算预算，避免大量工程各自触发 5000 entries 枚举。
        var sizeEntryBudget = 20_000
        for rootName in devRootNames {
            try cancellationCheck()
            let root = home.appendingPathComponent(rootName, isDirectory: true)
            let rootAttributes: [FileAttributeKey: Any]
            do {
                rootAttributes = try fileSystem.attributesOfItem(atPath: root.path)
            } catch {
                if DiscoveryFileErrorClassifier.isMissing(error) { continue }
                incompleteIssues.append(ScanIncompleteIssue(
                    path: root.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .metadataUnavailable
                    )
                ))
                continue
            }
            guard let rootType = rootAttributes[.type] as? FileAttributeType else {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: root.path,
                    reason: .metadataUnavailable
                ))
                continue
            }
            // v2026.07.17 global scan hardening: the walk below intentionally never follows
            // child symlinks, but the old root gate still accepted a symlink such as
            // `~/workspace -> /Volumes/External`. `contentsOfDirectory` would then traverse the
            // target before TrashPipeline eventually rejected the out-of-scope candidate. That
            // wasted a potentially huge scan and presented an item the fixed HOME-owned workflow
            // could never safely submit. Fixed discovery roots obey the same no-follow contract
            // at depth zero; users who explicitly want another volume can use Custom Path.
            guard rootType == .typeDirectory else { continue }
            try walk(
                root: root,
                maxDepth: max(0, maxDepth),
                visited: &visited,
                sizeEntryBudget: &sizeEntryBudget,
                includeSizes: includeSizes,
                fileSystem: fileSystem,
                cancellationCheck: cancellationCheck,
                into: &results,
                incompleteIssues: &incompleteIssues
            )
        }
        results.sort { $0.url.path < $1.url.path }
        return DiscoveryEvidence(hits: results, incompleteIssues: incompleteIssues)
    }

    // MARK: - 递归遍历

    /// 对单个 dev 根递归查找 `node_modules`。
    ///
    /// 关键约束：
    /// - 命中 `node_modules` 后**不下钻进入它内部**——避免遍历 5 万+ 个 npm 包文件；
    /// - 跳过隐藏目录（以 `.` 开头）——`.git` / `.DS_Store` / `.vscode` 等不可能藏工程目录；
    /// - `maxDepth` 是相对根的深度，根 = 深度 0；超出深度直接停止下钻；
    /// - **不跟随符号链接**（Review fix-soon #5，2026-06-15）：用户家目录里软链
    ///   极常见（如 `~/Code/foo -> ../Projects/foo`），若跟随会导致：
    ///     (a) 同一物理 `node_modules` 在结果里出现两次；
    ///     (b) `realpath` 形成环路时 DFS 栈打满到 `maxDepth` 才停（多个根之间互链）；
    ///     (c) 软链指向 `/private/var` 系统目录时被误扫。
    ///   通过 `.isSymbolicLinkKey` 直接过滤掉所有软链子项 + `visitedRealPaths`
    ///   用 canonical path 去重（`URL.resolvingSymlinksInPath` 物理化后比较）双保险。
    /// - `visitedRealPaths` 跨 dev 根共享：用户即便手动从 `~/Projects` 软链到
    ///   `~/Developer`，同一 realpath 也只会被走一次。
    /// - **传入 `&visited`**：让外层 detect() 在所有根之间复用同一份 visited set。
    private static func walk(root: URL,
                             maxDepth: Int,
                             visited: inout Set<String>,
                             sizeEntryBudget: inout Int,
                             includeSizes: Bool,
                             fileSystem: any DynamicDiscoveryFileSystem,
                             cancellationCheck: () throws -> Void,
                             into results: inout [NodeModulesHit],
                             incompleteIssues: inout [ScanIncompleteIssue]) throws {
        // 用显式栈实现 DFS，便于精确控制深度与"命中后不下钻"。
        var stack: [(url: URL, depth: Int, modificationDate: Date?)] = [(root, 0, nil)]
        while let (current, depth, modificationDate) = stack.popLast() {
            try cancellationCheck()
            // 物理化（resolve symlink）后去重——防止互链 / 自指 / 多根共享造成的重复 walk。
            let realPath = fileSystem.canonicalPath(for: current)
            if !visited.insert(realPath).inserted {
                continue
            }

            // 当前目录是 node_modules → 收集 hit，但**不再下钻**
            if current.lastPathComponent == "node_modules" {
                let hitResult = try makeHit(
                    at: current,
                    sizeEntryBudget: &sizeEntryBudget,
                    includeSize: includeSizes,
                    modificationDate: modificationDate,
                    cancellationCheck: cancellationCheck
                )
                results.append(hitResult.hit)
                incompleteIssues.append(contentsOf: hitResult.incompleteIssues)
                if modificationDate == nil {
                    incompleteIssues.append(ScanIncompleteIssue(
                        path: current.path,
                        reason: .metadataUnavailable
                    ))
                }
                continue
            }
            // 已到最大深度 → 不再下钻
            guard depth < maxDepth else { continue }

            let childNames: [String]
            do {
                childNames = try fileSystem.contentsOfDirectory(atPath: current.path)
            } catch {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: current.path,
                    reason: DiscoveryFileErrorClassifier.incompleteReason(
                        for: error,
                        fallback: .enumerationFailed
                    )
                ))
                continue
            }
            for name in childNames {
                try cancellationCheck()
                // 双保险：即便 skipsHiddenFiles 漏过，也手动滤一遍以 `.` 开头的项
                if name.hasPrefix(".") { continue }
                let child = current.appendingPathComponent(name, isDirectory: true)
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
                guard let type = attributes[.type] as? FileAttributeType else {
                    incompleteIssues.append(ScanIncompleteIssue(
                        path: child.path,
                        reason: .metadataUnavailable
                    ))
                    continue
                }
                // Review fix-soon #5：显式跳过符号链接（无论指向什么），防软链循环 / 重复计数 / 越界扫描
                if type == .typeSymbolicLink { continue }
                guard type == .typeDirectory else { continue }
                stack.append((
                    child,
                    depth + 1,
                    attributes[.modificationDate] as? Date
                ))
            }
        }
        try cancellationCheck()
    }

    /// 把一个 `node_modules` URL 转成 [NodeModulesHit]。
    /// 父目录名 = 工程名；估算大小 + 取 mtime。
    private static func makeHit(at nodeModulesURL: URL,
                                sizeEntryBudget: inout Int,
                                includeSize: Bool,
                                modificationDate: Date?,
                                cancellationCheck: () throws -> Void) throws -> HitResult {
        let parent = nodeModulesURL.deletingLastPathComponent()
        let projectName = parent.lastPathComponent
        let sizeResult: DirectorySizeResult
        if includeSize {
            sizeResult = try estimateSizeWithEvidence(
                at: nodeModulesURL,
                remainingGlobalEntries: &sizeEntryBudget,
                cancellationCheck: cancellationCheck
            )
        } else {
            sizeResult = DirectorySizeResult(sizeBytes: nil, incompleteIssues: [])
        }
        return HitResult(hit: NodeModulesHit(
            url: nodeModulesURL,
            projectName: projectName,
            sizeBytes: sizeResult.sizeBytes,
            modificationDate: modificationDate
        ), incompleteIssues: sizeResult.incompleteIssues)
    }

    // MARK: - sizeBytes 估算

    /// 遍历目录累加 totalFileAllocatedSize，回退 fileAllocatedSize。
    ///
    /// 失败语义：路径不存在 / 不是目录 / 无权限读 → 返回 `nil`（UI 侧显示 "—"）。
    static func estimateSize(at path: String, maxEntries: Int = 5_000) -> Int64? {
        var unlimited = Int.max
        return estimateSize(
            at: path,
            maxEntries: maxEntries,
            remainingGlobalEntries: &unlimited
        )
    }

    static func estimateSize(at path: String,
                             maxEntries: Int = 5_000,
                             remainingGlobalEntries: inout Int) -> Int64? {
        guard !path.isEmpty else { return nil }
        do {
            return try estimateSizeWithEvidence(
                at: URL(fileURLWithPath: path, isDirectory: true),
                maxEntries: maxEntries,
                remainingGlobalEntries: &remainingGlobalEntries,
                cancellationCheck: {}
            ).sizeBytes
        } catch {
            // 空 cancellationCheck 不会抛；兼容 API 仍以 nil 表示未知。
            AmuxLog.error(.scan, "NodeModules size estimation unexpected error path=\(path): \(error)")
            return nil
        }
    }

    private struct HitResult {
        let hit: NodeModulesHit
        let incompleteIssues: [ScanIncompleteIssue]
    }

    private struct DirectorySizeResult {
        let sizeBytes: Int64?
        let incompleteIssues: [ScanIncompleteIssue]
    }

    private nonisolated static func estimateSizeWithEvidence(
        at url: URL,
        maxEntries: Int = 5_000,
        remainingGlobalEntries: inout Int,
        cancellationCheck: () throws -> Void
    ) throws -> DirectorySizeResult {
        guard remainingGlobalEntries > 0 else {
            return DirectorySizeResult(sizeBytes: nil, incompleteIssues: [])
        }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isRegularFileKey,
            .fileResourceIdentifierKey
        ]
        var incompleteIssues: [ScanIncompleteIssue] = []
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
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
        var visitedEntries = 0
        var seenInodes: Set<Data> = []
        for case let fileURL as URL in enumerator {
            try cancellationCheck()
            if fileURL.lastPathComponent == ".DS_Store" { continue }
            visitedEntries += 1
            remainingGlobalEntries -= 1
            if visitedEntries > maxEntries || remainingGlobalEntries < 0 {
                return DirectorySizeResult(sizeBytes: nil, incompleteIssues: incompleteIssues)
            }
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
                if let resourceID = values.fileResourceIdentifier as? Data {
                    if !seenInodes.insert(resourceID).inserted {
                        continue
                    }
                }
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

/// 单个 `node_modules` 命中记录。
public struct NodeModulesHit: Sendable, Hashable, Identifiable {
    /// `node_modules` 目录绝对 URL，如
    /// `~/Developer/my-app/node_modules`。
    public let url: URL
    /// 工程名（即 `node_modules` 的父目录名），如 `my-app`。
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
