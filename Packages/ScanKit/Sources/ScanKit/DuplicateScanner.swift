import Foundation
import CryptoKit

/// 重复文件检测可靠度。
///
/// - `prefixOnly`：仅命中 size + 前 64KB SHA256 前缀，**未做全文件 hash**。
///   触发条件：文件 > `largeFileFullHashThreshold`（默认 256MB）；UI 必须提示
///   用户「建议人工核对」，不应作为删除依据。
/// - `full`：size + 前缀 + 全文件 SHA256 三段都一致，可信度高（但仍非「内容
///   字节级 100% 相等」——只是 SHA256 碰撞概率 ≈ 2^-128）。
public enum DuplicateReliability: String, Sendable, Codable {
    case prefixOnly
    case full
}

/// Identity frozen from the same open file descriptor that produced a duplicate hash.
///
/// `device + inode + fileType` detects path replacement; size and inode timestamps detect
/// in-place mutation between review and final verification. This is evidence, not a deletion
/// capability: the execution boundary must verify it again before moving any URL to Trash.
public struct DuplicateFileIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt16
    public let logicalBytes: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let statusChangeSeconds: Int64
    public let statusChangeNanoseconds: Int64

    /// v2026.07.17 Duplicate deletion evidence: keep the POSIX file-kind decision in ScanKit
    /// so every UI/execution consumer applies the same regular-file contract without copying
    /// Darwin constants into presentation code.
    public var isRegularFile: Bool { fileType == UInt16(S_IFREG) }

    public init(
        device: UInt64,
        inode: UInt64,
        fileType: UInt16,
        logicalBytes: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        statusChangeSeconds: Int64,
        statusChangeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.fileType = fileType
        self.logicalBytes = max(0, logicalBytes)
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
    }

    init(stat value: stat) {
        self.init(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino),
            fileType: UInt16(value.st_mode & mode_t(S_IFMT)),
            logicalBytes: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(value.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

/// Typed full-content evidence for one duplicate group. A `.full` label without this value is
/// intentionally insufficient for deletion; it remains usable only as read-only presentation.
public struct DuplicateContentFingerprint: Sendable, Hashable {
    public let sha256Hex: String
    public let logicalBytes: Int64

    public init?(sha256Hex: String, logicalBytes: Int64) {
        let normalized = sha256Hex.lowercased()
        guard logicalBytes >= 0,
              normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else { return nil }
        self.sha256Hex = normalized
        self.logicalBytes = logicalBytes
    }
}

/// 重复组中的单条文件记录。
public struct DuplicateFile: Sendable, Hashable {
    public let path: String
    /// 该路径当前在磁盘上的 allocated bytes。它来自枚举阶段同一个 `FSNode`，
    /// 不为展示大小额外 `stat`，也不参与内容相等判定。
    public let allocatedBytes: Int64
    /// Captured before and after hashing from the same descriptor, then matched against the
    /// pathname with `lstat`. Nil means this row has no executable deletion evidence.
    public let snapshotIdentity: DuplicateFileIdentity?

    public init(
        path: String,
        allocatedBytes: Int64,
        snapshotIdentity: DuplicateFileIdentity? = nil
    ) {
        self.path = path
        self.allocatedBytes = max(0, allocatedBytes)
        self.snapshotIdentity = snapshotIdentity
    }
}

/// 一组检测出来的重复文件。
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// `(size, prefixSHA256)` 或 `(size, prefixSHA256, fullSHA256)` 的字符串拼接，
    /// 用作 SwiftUI `Identifiable` 的 stable id。
    public let hashKey: String
    /// 单份内容的逻辑大小。只用于 size 分桶、hash 边界和详情说明，不能当作磁盘占用。
    public let logicalBytes: Int64
    /// 重复文件列表，至少 2 个。按路径字典序稳定排序，并保留每条路径各自的物理占用。
    public let files: [DuplicateFile]
    /// 该组当前磁盘占用：逐路径 allocated bytes 求和。
    public let totalBytes: Int64
    /// 默认处理（保留稳定排序后的第一份）预计可释放的 allocated bytes。
    public let reclaimableBytes: Int64
    /// 可靠度。
    public let reliability: DuplicateReliability
    /// Present only when every row was grouped by the same complete SHA256 digest.
    public let contentFingerprint: DuplicateContentFingerprint?

    public var id: String { hashKey }
    public var paths: [String] { files.map(\.path) }

    /// 手动选择路径对应的预计可释放空间。未知路径不计入。
    public func allocatedBytes(for paths: [String]) -> Int64 {
        let selected = Set(paths)
        return DuplicateGroup.saturatingSum(
            files.lazy.filter { selected.contains($0.path) }.map(\.allocatedBytes)
        )
    }

    private static func saturatingSum<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        values.reduce(into: 0) { total, value in
            let result = total.addingReportingOverflow(value)
            total = result.overflow ? .max : result.partialValue
        }
    }

    /// 删除成功后生成剩余重复组。`files` 在构造时已经按路径排序，过滤会保持相对顺序，
    /// 因此这里不能再调用公开 initializer 重排整个数组。未命中的组直接复用原值。
    public func removing(paths: Set<String>) -> DuplicateGroup? {
        guard !paths.isEmpty else { return self }
        var removedAny = false
        var remaining: [DuplicateFile] = []
        remaining.reserveCapacity(files.count)
        for file in files {
            if paths.contains(file.path) {
                removedAny = true
            } else {
                remaining.append(file)
            }
        }
        guard removedAny else { return self }
        guard remaining.count >= 2 else { return nil }
        return DuplicateGroup(
            hashKey: hashKey,
            logicalBytes: logicalBytes,
            sortedFiles: remaining,
            reliability: reliability,
            contentFingerprint: contentFingerprint
        )
    }

    public init(
        hashKey: String,
        logicalBytes: Int64,
        files: [DuplicateFile],
        reliability: DuplicateReliability,
        contentFingerprint: DuplicateContentFingerprint? = nil
    ) {
        self.init(
            hashKey: hashKey,
            logicalBytes: logicalBytes,
            sortedFiles: files.sorted { $0.path < $1.path },
            reliability: reliability,
            contentFingerprint: contentFingerprint
        )
    }

    private init(
        hashKey: String,
        logicalBytes: Int64,
        sortedFiles: [DuplicateFile],
        reliability: DuplicateReliability,
        contentFingerprint: DuplicateContentFingerprint?
    ) {
        self.hashKey = hashKey
        self.logicalBytes = max(0, logicalBytes)
        self.files = sortedFiles
        self.totalBytes = DuplicateGroup.saturatingSum(sortedFiles.lazy.map(\.allocatedBytes))
        self.reclaimableBytes = DuplicateGroup.saturatingSum(sortedFiles.dropFirst().lazy.map(\.allocatedBytes))
        self.reliability = reliability
        self.contentFingerprint = contentFingerprint
    }
}

private struct DuplicateCandidate: Sendable {
    let path: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let snapshotIdentity: DuplicateFileIdentity?

    var publicValue: DuplicateFile {
        DuplicateFile(
            path: path,
            allocatedBytes: allocatedBytes,
            snapshotIdentity: snapshotIdentity
        )
    }

    func frozen(to identity: DuplicateFileIdentity) -> DuplicateCandidate {
        DuplicateCandidate(
            path: path,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            snapshotIdentity: identity
        )
    }
}

private enum DuplicateFileHashOutcome: Sendable {
    case digest(String, DuplicateFileIdentity)
    case readFailed
    case cancelled
}

private struct DuplicateHashBatch: Sendable {
    let values: [(DuplicateCandidate, String, DuplicateFileIdentity)]
    let failedPaths: [String]
    let wasCancelled: Bool
}

/// 重复文件扫描进度事件。
public enum DuplicateScanEvent: Sendable {
    /// 阶段 1：按 size 分桶进行中（已枚举 N 个文件）。
    case sizingProgress(filesScanned: Int)
    /// 阶段 2：按前缀 hash 分桶进行中（已处理 N / total 个 size 桶）。
    case hashingProgress(bucketsDone: Int, bucketsTotal: Int)
    /// 阶段 3：全文件 hash 进行中（已处理 N / total 个候选桶）。
    case fullHashingProgress(bucketsDone: Int, bucketsTotal: Int)
    /// 全部完成，返回结果（按 totalBytes 倒序）。
    case finished(groups: [DuplicateGroup])
    /// 用户/上游 cancel：UI 应保留已展示的 groups（不要清空），仅退出 isScanning 状态。
    /// 设计原则：cancel 不破坏已经看到的内容，与「停止仅终止扫描、保留已有结果」UX 一致。
    case cancelled
    /// 扫描根因 TCC 雷区被整体跳过。
    case tccProtectedSkipped(path: String)
    /// 扫描仍然完成了可展示的部分结果，但该路径没有被完整覆盖。
    /// 调用方不得把本轮重复文件结果当作完整磁盘视图。
    case incomplete(ScanIncompleteIssue)
}

/// Read-only result used by the final Duplicate execution gate. It deliberately exposes no
/// filesystem mutation API and never treats an unreadable or changing file as a match.
public enum DuplicateContentVerificationResult: Sendable, Equatable {
    case verified
    case identityChangedOrUnavailable
    case contentChanged
    case cancelled
}

/// 重复文件扫描器（**只读**，无任何删除/移动 API）。
///
/// 算法分三阶段（业界经典做法，见 fdupes / rmlint）：
///
/// 1. **size 分桶**：唯一 size 直接淘汰（不可能与任何文件重复）。
/// 2. **前缀 hash**：同 size 桶内对每个文件读前 64KB 算 SHA256，按
///    `(size, prefixHash)` 分桶；唯一桶淘汰。
/// 3. **全文件 hash**：仍冲突的桶若 size ≤ 256MB，则做全文件 SHA256；
///    > 256MB 直接以 `prefixOnly` 标记返回，避免对几 GB 文件做几秒级 hash。
///
/// 并发策略：
/// - 阶段 1 串行（fs walking 已经多 worker，这里只做收集）
/// - 阶段 2/3 size 桶串行处理，**桶内** 最多 4 个文件并发 hash（withTaskGroup
///   配合 semaphore-style in-flight 计数）。
///
/// 安全契约（**不要破坏**）：
/// - 没有任何文件破坏性 syscall（无 fs unlink、无 NSWorkspace 废纸篓、无 helper XPC 删）
/// - 公开 API 只返回 `[DuplicateGroup]`，UI 引导用户「用 Finder 自行处理」
public actor DuplicateScanner {
    /// 大于该阈值的文件不做全文件 hash，只比 size + 前缀（reliability = prefixOnly）。
    public static let largeFileFullHashThreshold: Int64 = 256 * 1024 * 1024

    /// 前缀 hash 读取的字节数。
    public static let prefixHashBytes: Int = 64 * 1024

    /// 桶内并发 hash 上限。
    public static let inBucketConcurrency: Int = 4

    private let roots: [URL]
    private let minBytes: Int64
    private let scanOptions: ScanOptions

    public init(
        roots: [URL],
        minBytes: Int64 = 1 * 1024 * 1024,
        scanOptions: ScanOptions = .default
    ) {
        // v2026.07.17 全链路性能回归：`/A` 与 `/A/B` 同时入参时，全局
        // InodeSet 只能防结果重复，防不了子树被读两次。在唯一 root 规划边界
        // 做组件安全的祖先折叠，保持扫描范围不变且每棵子树只枚举一次。
        self.roots = Self.minimalNonOverlappingRoots(roots)
        self.minBytes = max(0, minBytes)
        self.scanOptions = scanOptions
    }

    // MARK: - Public API

    /// 启动扫描，返回 AsyncStream 事件流。
    ///
    /// 调用方 `for await` 直到收到 `.finished(groups:)`；提前 break 会通过
    /// `onTermination` cancel 内部 `Task.detached`。
    public nonisolated func scan() -> AsyncStream<DuplicateScanEvent> {
        // v2026.07.17 安全回归：`.incomplete` 与可合并 progress 共用
        // bufferingNewest 会在消费者稍慢时静默淘汰权限证据。生产者现已是低频
        // progress + 终态候选投影，lossless stream 不再堆积逐文件事件。
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) { [roots, minBytes, scanOptions] in
                await DuplicateScanner.runScan(
                    roots: roots,
                    minBytes: minBytes,
                    scanOptions: scanOptions,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 阻塞式便捷 API：返回最终结果（仅供测试用）。
    public nonisolated func scanToCompletion() async -> [DuplicateGroup] {
        for await event in scan() {
            if case let .finished(groups) = event {
                return groups
            }
        }
        return []
    }

    /// 路径层去重必须在启动任何 scanner 前完成；事后的 inode 去重无法挽回
    /// 已经发生的重复 I/O。只折叠标准化后的字符串祖先，不解析 symlink，避免 root
    /// 规划本身引入慢 I/O/TCC 副作用。
    nonisolated static func minimalNonOverlappingRoots(_ roots: [URL]) -> [URL] {
        let normalized = roots.map { $0.standardizedFileURL }
        let sorted = normalized.sorted {
            if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
            return $0.path < $1.path
        }
        var retained: [URL] = []
        var retainedPaths = Set<String>()
        for root in sorted {
            let path = root.path
            guard retainedPaths.insert(path).inserted else { continue }
            let isCovered = retained.contains { ancestor in
                let ancestorPath = ancestor.path
                if ancestorPath == "/" { return path.hasPrefix("/") }
                return path.hasPrefix(ancestorPath + "/")
            }
            if !isCovered { retained.append(root) }
        }
        return retained
    }

    // MARK: - Pipeline

    private static func runScan(
        roots: [URL],
        minBytes: Int64,
        scanOptions: ScanOptions,
        continuation: AsyncStream<DuplicateScanEvent>.Continuation
    ) async {
        // ===== 阶段 1：枚举所有文件，按 size 分桶 =====
        let inodes = InodeSet()
        // logical size 仍是内容分桶键；allocated 只随候选元数据同行，不触发二次 stat。
        var sizeBuckets: [Int64: [DuplicateCandidate]] = [:]
        var enumeratedBeforeCurrentRoot = 0

        for root in roots {
            if Task.isCancelled { break }
            if scanOptions.respectTCCSkipList && TCCSkipList.shouldSkip(root.path) {
                let issue = ScanIncompleteIssue(
                    path: root.path,
                    reason: .tccProtectedSkipped
                )
                continuation.yield(.tccProtectedSkipped(path: root.path))
                continuation.yield(.incomplete(issue))
                continue
            }
            let scanner = BulkScanner(options: scanOptions)
            var rootSummary: ScanSummary?
            for await event in scanner.scan(
                root: root,
                delivery: .fileCandidates(minimumLogicalBytes: minBytes)
            ) {
                if Task.isCancelled { break }
                switch event {
                case .heartbeat:
                    continue
                case .progress(_, let enumeratedFiles):
                    continuation.yield(.sizingProgress(
                        filesScanned: enumeratedBeforeCurrentRoot + enumeratedFiles
                    ))
                case .finished(let summary):
                    rootSummary = summary
                case .node, .nodes:
                    assertionFailure("fileCandidates delivery emitted incremental nodes")
                case .tccProtectedSkipped, .incomplete, .permissionDenied, .failed, .cacheDirTagged:
                    // 中间 evidence 可能重复；权威、去重的证据随 finished summary
                    // 一次性交付，避免 progress 和安全证据在外层流里竞争。
                    continue
                }
            }

            guard !Task.isCancelled, let rootSummary else { break }
            for issue in rootSummary.incompleteIssues {
                if issue.reason == .tccProtectedSkipped {
                    continuation.yield(.tccProtectedSkipped(path: issue.path))
                }
                continuation.yield(.incomplete(issue))
            }
            guard case .fileCandidates(let candidates) = rootSummary.projection else {
                continuation.yield(.incomplete(ScanIncompleteIssue(
                    path: root.path,
                    reason: .enumerationFailed,
                    stage: .enumerate
                )))
                continue
            }
            for node in candidates where !node.isSymlink {
                // 每个 BulkScanner 根有自己的 inode 表；这层共享集合继续防止多根
                // hardlink 重复进入 hash 桶。APFS clone 为不同 inode，不会被误去重。
                guard inodes.insertIfFirstSeen(device: node.device, inode: node.inode) else {
                    continue
                }
                sizeBuckets[node.logicalSize, default: []].append(DuplicateCandidate(
                    path: node.path,
                    logicalBytes: node.logicalSize,
                    allocatedBytes: node.allocatedSize,
                    snapshotIdentity: nil
                ))
            }
            enumeratedBeforeCurrentRoot += rootSummary.fileCount
            continuation.yield(.sizingProgress(filesScanned: enumeratedBeforeCurrentRoot))
        }

        // 淘汰只有 1 个的 size 桶
        let candidateSizeBuckets: [(size: Int64, files: [DuplicateCandidate])] = sizeBuckets
            .filter { $0.value.count >= 2 }
            .map { (size: $0.key, files: $0.value) }

        if Task.isCancelled {
            // 不发 .finished(groups: [])——那会让 UI 把已展示的旧结果清空。
            // 改发 .cancelled，UI 端 case 中只复位 isScanning，保留 groups。
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        // ===== 阶段 2：每个 size 桶内做前缀 hash =====
        var prefixGroups: [(size: Int64, prefixHex: String, files: [DuplicateCandidate])] = []
        let totalBuckets = candidateSizeBuckets.count
        var bucketsDone = 0
        var lastHashProgressEmit = Date.distantPast
        var reportedReadFailures = Set<String>()
        continuation.yield(.hashingProgress(bucketsDone: 0, bucketsTotal: totalBuckets))

        for bucket in candidateSizeBuckets {
            if Task.isCancelled { break }
            let hashed = await hashCandidatesConcurrently(
                candidates: bucket.files,
                fullFile: false
            )
            for path in hashed.failedPaths where reportedReadFailures.insert(path).inserted {
                continuation.yield(.incomplete(ScanIncompleteIssue(
                    path: path,
                    reason: .metadataUnavailable,
                    stage: .metadata
                )))
            }
            if hashed.wasCancelled { break }
            // 按 prefixHex 分组
            var byHash: [String: [DuplicateCandidate]] = [:]
            for (candidate, hex, identity) in hashed.values {
                byHash[hex, default: []].append(candidate.frozen(to: identity))
            }
            for (hex, files) in byHash where files.count >= 2 {
                prefixGroups.append((size: bucket.size, prefixHex: hex, files: files))
            }
            bucketsDone += 1
            let now = Date()
            if bucketsDone == totalBuckets || now.timeIntervalSince(lastHashProgressEmit) >= 0.1 {
                lastHashProgressEmit = now
                continuation.yield(.hashingProgress(
                    bucketsDone: bucketsDone,
                    bucketsTotal: totalBuckets
                ))
            }
        }

        if Task.isCancelled {
            // 同上：cancel 不清空 UI 已展示的内容
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        // ===== 阶段 3：对 size <= 阈值 的桶做全文件 hash；> 阈值 直接 prefixOnly =====
        var finalGroups: [DuplicateGroup] = []
        let threshold = DuplicateScanner.largeFileFullHashThreshold

        // 大文件桶直接 promote 成 prefixOnly group
        let largeFileBuckets = prefixGroups.filter { $0.size > threshold }
        for b in largeFileBuckets {
            let group = DuplicateGroup(
                hashKey: "size=\(b.size)|prefix=\(b.prefixHex)",
                logicalBytes: b.size,
                files: b.files.map(\.publicValue),
                reliability: .prefixOnly,
                contentFingerprint: nil
            )
            finalGroups.append(group)
        }

        // 小文件桶做全文件 hash 二次确认
        let smallFileBuckets = prefixGroups.filter { $0.size <= threshold }
        let totalFullBuckets = smallFileBuckets.count
        var fullDone = 0
        var lastFullHashProgressEmit = Date.distantPast
        if totalFullBuckets > 0 {
            continuation.yield(.fullHashingProgress(bucketsDone: 0, bucketsTotal: totalFullBuckets))
        }

        for bucket in smallFileBuckets {
            if Task.isCancelled { break }
            let hashed = await hashCandidatesConcurrently(
                candidates: bucket.files,
                fullFile: true
            )
            for path in hashed.failedPaths where reportedReadFailures.insert(path).inserted {
                continuation.yield(.incomplete(ScanIncompleteIssue(
                    path: path,
                    reason: .metadataUnavailable,
                    stage: .metadata
                )))
            }
            if hashed.wasCancelled { break }
            var byHash: [String: [DuplicateCandidate]] = [:]
            for (candidate, hex, identity) in hashed.values {
                byHash[hex, default: []].append(candidate.frozen(to: identity))
            }
            for (fullHex, files) in byHash where files.count >= 2 {
                guard let fingerprint = DuplicateContentFingerprint(
                    sha256Hex: fullHex,
                    logicalBytes: bucket.size
                ) else {
                    assertionFailure("SHA256 producer returned an invalid digest")
                    continue
                }
                let group = DuplicateGroup(
                    hashKey: "size=\(bucket.size)|prefix=\(bucket.prefixHex)|full=\(fullHex)",
                    logicalBytes: bucket.size,
                    files: files.map(\.publicValue),
                    reliability: .full,
                    contentFingerprint: fingerprint
                )
                finalGroups.append(group)
            }
            fullDone += 1
            let now = Date()
            if fullDone == totalFullBuckets || now.timeIntervalSince(lastFullHashProgressEmit) >= 0.1 {
                lastFullHashProgressEmit = now
                continuation.yield(.fullHashingProgress(
                    bucketsDone: fullDone,
                    bucketsTotal: totalFullBuckets
                ))
            }
        }

        if Task.isCancelled {
            // 阶段 3 中途被 cancel：finalGroups 里可能已有「大文件 prefixOnly」组以及部分全文件 hash 组，
            // 但顺序未稳定（还没排序）。简单起见：发 .cancelled，UI 保留前次已展示的内容；
            // 不发 .finished(finalGroups) 以免给用户「这就是全部」的错觉。
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        // 按总占用倒序
        finalGroups.sort { $0.totalBytes > $1.totalBytes }
        continuation.yield(.finished(groups: finalGroups))
        continuation.finish()
    }

    // MARK: - Hashing

    /// 桶内并发 hash：用 TaskGroup + 滑动窗口控制 in-flight 数量。
    /// 读失败和用户取消是两个独立终态：前者返回 typed incomplete path，后者
    /// 立即停止补充滑动窗口，绝不把取消伪装成文件损坏。
    ///
    /// 注意：调用方按 hex 重新分桶（见 runScan），**不依赖 candidates 输入顺序**，
    /// 因此这里直接收集任务完成顺序即可，无需按 index 还原。
    private static func hashCandidatesConcurrently(
        candidates: [DuplicateCandidate],
        fullFile: Bool
    ) async -> DuplicateHashBatch {
        if candidates.isEmpty {
            return DuplicateHashBatch(values: [], failedPaths: [], wasCancelled: false)
        }
        let limit = DuplicateScanner.inBucketConcurrency

        return await withTaskGroup(of: (DuplicateCandidate, DuplicateFileHashOutcome).self) { group in
            var nextIndex = 0

            func addTask(for candidate: DuplicateCandidate) {
                group.addTask {
                    let outcome = DuplicateScanner.hashFile(
                        path: candidate.path,
                        maximumBytes: fullFile ? nil : DuplicateScanner.prefixHashBytes
                    )
                    return (candidate, outcome)
                }
            }

            // 启动初始窗口
            while nextIndex < candidates.count && nextIndex < limit {
                let candidate = candidates[nextIndex]
                addTask(for: candidate)
                nextIndex += 1
            }

            // 收一个 → 发一个，保持窗口
            var collected: [(DuplicateCandidate, String, DuplicateFileIdentity)] = []
            collected.reserveCapacity(candidates.count)
            var failedPaths: [String] = []
            var wasCancelled = false
            while let r = await group.next() {
                switch r.1 {
                case .digest(let hex, let identity):
                    // v2026.07.17 identity provenance: a file resized after enumeration cannot
                    // remain in the old size bucket even if its current prefix/full digest
                    // matches another candidate. Treat it as typed incomplete and require a
                    // new scan rather than publishing mismatched deletion evidence.
                    if identity.logicalBytes == r.0.logicalBytes {
                        collected.append((r.0, hex, identity))
                    } else {
                        failedPaths.append(r.0.path)
                    }
                case .readFailed:
                    failedPaths.append(r.0.path)
                case .cancelled:
                    wasCancelled = true
                }

                if Task.isCancelled || wasCancelled {
                    wasCancelled = true
                    group.cancelAll()
                    continue
                }
                if nextIndex < candidates.count {
                    let candidate = candidates[nextIndex]
                    addTask(for: candidate)
                    nextIndex += 1
                }
            }
            return DuplicateHashBatch(
                values: collected,
                failedPaths: failedPaths,
                wasCancelled: wasCancelled || Task.isCancelled
            )
        }
    }

    /// 读文件前 N 字节做 SHA256，返回 hex。读失败返回 nil。
    /// 用 POSIX read 而非 Data(contentsOf:)，避免对 1MB 文件也整文件读入内存。
    /// EINTR（被信号打断）会自动重试，避免可恢复中断被当成读失败丢弃文件。
    nonisolated static func prefixSHA256Hex(path: String, maxBytes: Int) -> String? {
        guard case .digest(let hex, _) = hashFile(path: path, maximumBytes: maxBytes) else {
            return nil
        }
        return hex
    }

    /// 全文件 SHA256，返回 hex。读失败返回 nil。
    /// EINTR（被信号打断）会自动重试。
    nonisolated static func fullSHA256Hex(path: String) -> String? {
        guard case .digest(let hex, _) = hashFile(path: path, maximumBytes: nil) else {
            return nil
        }
        return hex
    }

    /// v2026.07.17 Duplicate deletion proof: re-open and hash the complete current file using
    /// the same hardened descriptor routine as scanning. Callers must run this off MainActor.
    /// Both the selected target and an explicitly retained reference copy must return `.verified`
    /// before a real Trash request is allowed to cross the AppKit boundary.
    public nonisolated static func verifyFullContent(
        path: String,
        expectedIdentity: DuplicateFileIdentity,
        expectedFingerprint: DuplicateContentFingerprint,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> DuplicateContentVerificationResult {
        guard !isCancelled() else { return .cancelled }
        switch hashFile(
            path: path,
            maximumBytes: nil,
            isCancelled: isCancelled
        ) {
        case .cancelled:
            return .cancelled
        case .readFailed:
            return .identityChangedOrUnavailable
        case .digest(let digest, let identity):
            guard identity == expectedIdentity,
                  identity.logicalBytes == expectedFingerprint.logicalBytes else {
                return .identityChangedOrUnavailable
            }
            return digest == expectedFingerprint.sha256Hex ? .verified : .contentChanged
        }
    }

    /// v2026.07.17 post-hash claim fence: cheaply prove that a pathname still names the exact
    /// regular-file identity frozen by the full hash. This does not replace content hashing;
    /// it only closes ordinary replacement/in-place-write drift between that hash and each
    /// workspace recycling claim by comparing size, mtime and ctime as well as inode/type.
    public nonisolated static func matchesCurrentPathIdentity(
        path: String,
        expectedIdentity: DuplicateFileIdentity
    ) -> Bool {
        var current = stat()
        guard lstat(path, &current) == 0 else { return false }
        return DuplicateFileIdentity(stat: current) == expectedIdentity
            && expectedIdentity.isRegularFile
    }

    /// v2026.07.17 取消尾延迟根治：hash 任务不能只在文件之间检查取消。
    /// 每个 read batch 前后都检查，因此用户停止后最多等待当前一次内核 read 返回；
    /// 同步 syscall 执行途中仍无法被 Swift Task 强制抢占，这是明确的系统边界。
    nonisolated private static func hashFile(
        path: String,
        maximumBytes: Int?,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) -> DuplicateFileHashOutcome {
        guard !isCancelled() else { return .cancelled }
        // Apple Secure Coding's pathname-race guidance: never follow a last-component symlink,
        // inspect the opened descriptor with fstat, then prove the pathname still identifies
        // that descriptor after the read. This closes scan-time path replacement rather than
        // trusting metadata collected by the earlier directory enumeration.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return isCancelled() ? .cancelled : .readFailed }
        defer { close(fd) }
        guard !isCancelled() else { return .cancelled }

        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size >= 0 else { return .readFailed }
        let identity = DuplicateFileIdentity(stat: before)

        var hasher = SHA256()
        let bufSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buffer.deallocate() }
        var remaining = maximumBytes
        var totalBytesRead: Int64 = 0
        while true {
            guard !isCancelled() else { return .cancelled }
            let requested = remaining.map { min($0, bufSize) } ?? bufSize
            if requested <= 0 { break }
            let n = read(fd, buffer, requested)
            guard !isCancelled() else { return .cancelled }
            if n < 0 {
                if errno == EINTR { continue }   // 信号打断，重试
                return .readFailed
            }
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(start: buffer, count: n)
            hasher.update(bufferPointer: chunk)
            totalBytesRead += Int64(n)
            if remaining != nil { remaining! -= n }
        }

        var after = stat()
        var pathAfter = stat()
        guard fstat(fd, &after) == 0,
              DuplicateFileIdentity(stat: after) == identity,
              lstat(path, &pathAfter) == 0,
              DuplicateFileIdentity(stat: pathAfter) == identity,
              maximumBytes != nil || totalBytesRead == identity.logicalBytes else {
            return .readFailed
        }
        let digest = hasher.finalize()
        return .digest(
            digest.map { String(format: "%02x", $0) }.joined(),
            identity
        )
    }
}
