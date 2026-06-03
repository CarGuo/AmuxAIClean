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

/// 一组检测出来的重复文件。
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// `(size, prefixSHA256)` 或 `(size, prefixSHA256, fullSHA256)` 的字符串拼接，
    /// 用作 SwiftUI `Identifiable` 的 stable id。
    public let hashKey: String
    /// 单文件大小（组内每份都是这个 size）。
    public let bytes: Int64
    /// 重复路径列表，至少 2 个。顺序按字符串字典序，方便 UI 稳定渲染。
    public let paths: [String]
    /// 可靠度。
    public let reliability: DuplicateReliability

    public var id: String { hashKey }

    /// 该组占用空间总和（bytes × paths.count）。
    /// 用 `multipliedReportingOverflow` 显式饱和到 `Int64.max`，
    /// 避免 `&*` 静默裹回得到负数（实际场景几乎不可达，但 UI 不应展示 -XXX MB）。
    public var totalBytes: Int64 { DuplicateGroup.saturatingMultiply(bytes, Int64(paths.count)) }

    /// 「可释放」字节数：保留 1 份、删除其余 N-1 份。
    public var reclaimableBytes: Int64 {
        DuplicateGroup.saturatingMultiply(bytes, Int64(max(0, paths.count - 1)))
    }

    /// Int64 饱和乘法：溢出时返回 `Int64.max` 而不是裹回。
    private static func saturatingMultiply(_ a: Int64, _ b: Int64) -> Int64 {
        let r = a.multipliedReportingOverflow(by: b)
        return r.overflow ? .max : r.partialValue
    }

    public init(hashKey: String, bytes: Int64, paths: [String], reliability: DuplicateReliability) {
        self.hashKey = hashKey
        self.bytes = bytes
        self.paths = paths
        self.reliability = reliability
    }
}

/// 重复文件扫描进度事件。
public enum DuplicateScanEvent: Sendable {
    /// 阶段 1：按 size 分桶进行中（已收集 N 个候选文件）。
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
        self.roots = roots
        self.minBytes = max(0, minBytes)
        self.scanOptions = scanOptions
    }

    // MARK: - Public API

    /// 启动扫描，返回 AsyncStream 事件流。
    ///
    /// 调用方 `for await` 直到收到 `.finished(groups:)`；提前 break 会通过
    /// `onTermination` cancel 内部 `Task.detached`。
    public nonisolated func scan() -> AsyncStream<DuplicateScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
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

    // MARK: - Pipeline

    private static func runScan(
        roots: [URL],
        minBytes: Int64,
        scanOptions: ScanOptions,
        continuation: AsyncStream<DuplicateScanEvent>.Continuation
    ) async {
        // ===== 阶段 1：枚举所有文件，按 size 分桶 =====
        let inodes = InodeSet()
        var sizeBuckets: [Int64: [String]] = [:]
        var fileScannedCount = 0
        var lastEmit = Date.distantPast

        for root in roots {
            if Task.isCancelled { break }
            if TCCSkipList.shouldSkip(root.path) {
                continuation.yield(.tccProtectedSkipped(path: root.path))
                continue
            }
            let scanner = BulkScanner(options: scanOptions)
            for await event in scanner.scan(root: root) {
                if Task.isCancelled { break }
                switch event {
                case .node(let node):
                    // 只看普通文件；目录/符号链接跳过
                    if node.isDirectory || node.isSymlink { continue }
                    // 用逻辑大小（fileSize），与按内容 hash 的语义一致；
                    // 物理占用（allocatedSize）会受 APFS clone / 块对齐影响。
                    let size = node.logicalSize
                    if size < minBytes { continue }
                    // hardlink / clone 同 inode 跳过——它们「内容相同」是文件系统层面
                    // 已经做了去重，再列出来反而误导用户「我有 2 份」。
                    if !inodes.insertIfFirstSeen(device: node.device, inode: node.inode) {
                        continue
                    }
                    sizeBuckets[size, default: []].append(node.url.path)
                    fileScannedCount += 1
                    let now = Date()
                    if now.timeIntervalSince(lastEmit) > 0.1 {
                        lastEmit = now
                        continuation.yield(.sizingProgress(filesScanned: fileScannedCount))
                    }
                case .tccProtectedSkipped(let path):
                    continuation.yield(.tccProtectedSkipped(path: path))
                case .progress, .permissionDenied, .finished, .failed, .cacheDirTagged:
                    continue
                }
            }
        }

        // 淘汰只有 1 个的 size 桶
        let candidateSizeBuckets: [(size: Int64, paths: [String])] = sizeBuckets
            .filter { $0.value.count >= 2 }
            .map { (size: $0.key, paths: $0.value) }

        if Task.isCancelled {
            // 不发 .finished(groups: [])——那会让 UI 把已展示的旧结果清空。
            // 改发 .cancelled，UI 端 case 中只复位 isScanning，保留 groups。
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        // ===== 阶段 2：每个 size 桶内做前缀 hash =====
        var prefixGroups: [(size: Int64, prefixHex: String, paths: [String])] = []
        let totalBuckets = candidateSizeBuckets.count
        var bucketsDone = 0
        continuation.yield(.hashingProgress(bucketsDone: 0, bucketsTotal: totalBuckets))

        for bucket in candidateSizeBuckets {
            if Task.isCancelled { break }
            let hashed = await hashPathsConcurrently(
                paths: bucket.paths,
                fullFile: false
            )
            // 按 prefixHex 分组
            var byHash: [String: [String]] = [:]
            for (path, hex) in hashed {
                guard let hex else { continue }
                byHash[hex, default: []].append(path)
            }
            for (hex, paths) in byHash where paths.count >= 2 {
                prefixGroups.append((size: bucket.size, prefixHex: hex, paths: paths))
            }
            bucketsDone += 1
            continuation.yield(.hashingProgress(bucketsDone: bucketsDone, bucketsTotal: totalBuckets))
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
                bytes: b.size,
                paths: b.paths.sorted(),
                reliability: .prefixOnly
            )
            finalGroups.append(group)
        }

        // 小文件桶做全文件 hash 二次确认
        let smallFileBuckets = prefixGroups.filter { $0.size <= threshold }
        let totalFullBuckets = smallFileBuckets.count
        var fullDone = 0
        if totalFullBuckets > 0 {
            continuation.yield(.fullHashingProgress(bucketsDone: 0, bucketsTotal: totalFullBuckets))
        }

        for bucket in smallFileBuckets {
            if Task.isCancelled { break }
            let hashed = await hashPathsConcurrently(
                paths: bucket.paths,
                fullFile: true
            )
            var byHash: [String: [String]] = [:]
            for (path, hex) in hashed {
                guard let hex else { continue }
                byHash[hex, default: []].append(path)
            }
            for (fullHex, paths) in byHash where paths.count >= 2 {
                let group = DuplicateGroup(
                    hashKey: "size=\(bucket.size)|prefix=\(bucket.prefixHex)|full=\(fullHex)",
                    bytes: bucket.size,
                    paths: paths.sorted(),
                    reliability: .full
                )
                finalGroups.append(group)
            }
            fullDone += 1
            continuation.yield(.fullHashingProgress(bucketsDone: fullDone, bucketsTotal: totalFullBuckets))
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
    /// 返回 `(path, hexOrNil)` 数组——hex 为 nil 表示该文件读失败（权限 / 已删除），
    /// 调用方应直接忽略该文件，**不要**让它误入任何 hash 桶。
    ///
    /// 注意：调用方按 hex 重新分桶（见 runScan），**不依赖 paths 输入顺序**，
    /// 因此这里直接收集任务完成顺序即可，无需按 index 还原。
    private static func hashPathsConcurrently(
        paths: [String],
        fullFile: Bool
    ) async -> [(String, String?)] {
        if paths.isEmpty { return [] }
        let limit = DuplicateScanner.inBucketConcurrency

        return await withTaskGroup(of: (String, String?).self) { group in
            var nextIndex = 0

            // 启动初始窗口
            while nextIndex < paths.count && nextIndex < limit {
                let p = paths[nextIndex]
                group.addTask {
                    let hex = fullFile
                        ? DuplicateScanner.fullSHA256Hex(path: p)
                        : DuplicateScanner.prefixSHA256Hex(path: p, maxBytes: DuplicateScanner.prefixHashBytes)
                    return (p, hex)
                }
                nextIndex += 1
            }

            // 收一个 → 发一个，保持窗口
            var collected: [(String, String?)] = []
            collected.reserveCapacity(paths.count)
            while let r = await group.next() {
                collected.append(r)
                if nextIndex < paths.count {
                    let p = paths[nextIndex]
                    group.addTask {
                        let hex = fullFile
                            ? DuplicateScanner.fullSHA256Hex(path: p)
                            : DuplicateScanner.prefixSHA256Hex(path: p, maxBytes: DuplicateScanner.prefixHashBytes)
                        return (p, hex)
                    }
                    nextIndex += 1
                }
            }
            return collected
        }
    }

    /// 读文件前 N 字节做 SHA256，返回 hex。读失败返回 nil。
    /// 用 POSIX read 而非 Data(contentsOf:)，避免对 1MB 文件也整文件读入内存。
    /// EINTR（被信号打断）会自动重试，避免可恢复中断被当成读失败丢弃文件。
    nonisolated static func prefixSHA256Hex(path: String, maxBytes: Int) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let bufSize = min(maxBytes, 64 * 1024)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buffer.deallocate() }
        var remaining = maxBytes
        while remaining > 0 {
            let want = min(remaining, bufSize)
            let n = read(fd, buffer, want)
            if n < 0 {
                if errno == EINTR { continue }   // 信号打断，重试
                return nil
            }
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(start: buffer, count: n)
            hasher.update(bufferPointer: chunk)
            remaining -= n
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 全文件 SHA256，返回 hex。读失败返回 nil。
    /// EINTR（被信号打断）会自动重试。
    nonisolated static func fullSHA256Hex(path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let bufSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer, bufSize)
            if n < 0 {
                if errno == EINTR { continue }   // 信号打断，重试
                return nil
            }
            if n == 0 { break }
            let chunk = UnsafeRawBufferPointer(start: buffer, count: n)
            hasher.update(bufferPointer: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
