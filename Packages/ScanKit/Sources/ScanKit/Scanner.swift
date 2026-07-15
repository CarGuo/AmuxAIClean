import Foundation
import Darwin

/// 文件扫描引擎（v0 朴素版本）。
///
/// 目标：**正确性优先**。
/// - 物理占用 (`totalFileAllocatedSize`) 而非逻辑大小（解决 iCloud 占位 / 稀疏文件）
/// - 按 inode 去重（解决 hardlink；APFS clone 使用不同 inode，不能据此识别共享 extent）
/// - 默认包含隐藏文件
/// - 增量 AsyncStream 输出
///
/// 性能优化（getattrlistbulk + C bridging）放 v1 再做，先把正确性做扎实。
public actor Scanner {
    private let options: ScanOptions

    public init(options: ScanOptions = .default) {
        self.options = options
    }

    /// 扫描指定根目录，返回事件流。
    public nonisolated func scan(root: URL) -> AsyncStream<ScanEvent> {
        // 去重表必须属于本次 stream。`scan` 是 nonisolated；实例级共享集合在并发/复用时
        // 会让一轮扫描把另一轮文件误判为 hardlink。
        let inodeSet = InodeSet()
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [options, inodeSet] in
                let start = Date()
                let completeness = ScannerCompletenessAccumulator()
                var fileCount = 0
                var dirCount = 0
                var totalAllocated: Int64 = 0
                var totalLogical: Int64 = 0
                var dedupedBytes: Int64 = 0
                // FileManager may canonicalize `/var/...` descendants to `/private/var/...`.
                // TCC policy must be evaluated in the caller's root namespace, otherwise the
                // fallback scanner skips explicit `/var/folders/...` roots while BulkScanner
                // scans the same root, producing engine-dependent results.
                let policyRootPath = root.path
                let resolvedPolicyRootPath = root.resolvingSymlinksInPath().path

                @discardableResult
                @Sendable func reportIncomplete(_ issue: ScanIncompleteIssue) -> Bool {
                    guard completeness.insert(issue) else { return false }
                    continuation.yield(.incomplete(issue))
                    switch issue.reason {
                    case .permissionDenied:
                        continuation.yield(.permissionDenied(path: issue.path))
                    case .tccProtectedSkipped:
                        continuation.yield(.tccProtectedSkipped(path: issue.path))
                    case .enumerationFailed, .metadataUnavailable:
                        break
                    }
                    return true
                }

                let keys: [URLResourceKey] = [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey,
                    .fileResourceIdentifierKey,
                    .contentModificationDateKey,
                    .isHiddenKey
                ]

                var enumOptions: FileManager.DirectoryEnumerationOptions = []
                if !options.includeHidden {
                    enumOptions.insert(.skipsHiddenFiles)
                }
                if !options.includePackageContents {
                    enumOptions.insert(.skipsPackageDescendants)
                }

                if options.respectTCCSkipList && TCCSkipList.shouldSkip(root.path) {
                    let issue = ScanIncompleteIssue(path: root.path, reason: .tccProtectedSkipped)
                    reportIncomplete(issue)
                    let summary = ScanSummary(
                        root: root,
                        totalAllocatedBytes: 0,
                        totalLogicalBytes: 0,
                        fileCount: 0,
                        directoryCount: 0,
                        dedupedHardlinkBytes: 0,
                        elapsed: Date().timeIntervalSince(start),
                        permissionDeniedCount: 0,
                        tccProtectedSkippedCount: 1,
                        incompleteIssues: [issue]
                    )
                    continuation.yield(.finished(summary))
                    continuation.finish()
                    return
                }

                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: enumOptions,
                    errorHandler: { url, error in
                        guard !Task.isCancelled else { return false }
                        let posixErrorCode = ScanFailureClassifier.posixErrorCode(from: error)
                        let issue = ScanFailureClassifier.issue(
                            path: url.path,
                            stage: .enumerate,
                            posixErrorCode: posixErrorCode
                        )
                        let isNewIssue = reportIncomplete(issue)
                        if isNewIssue,
                           url.standardizedFileURL == root.standardizedFileURL,
                           issue.reason == .enumerationFailed {
                            continuation.yield(.failed(.cannotEnumerate(
                                path: root.path,
                                stage: .enumerate,
                                posixErrorCode: posixErrorCode
                            )))
                        }
                        return !Task.isCancelled
                    }
                ) else {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    let issue = ScanIncompleteIssue(
                        path: root.path,
                        reason: .enumerationFailed,
                        stage: .enumerate
                    )
                    reportIncomplete(issue)
                    continuation.yield(.failed(.cannotEnumerate(
                        path: root.path,
                        stage: .enumerate,
                        posixErrorCode: nil
                    )))
                    let counts = completeness.snapshot()
                    continuation.yield(.finished(ScanSummary(
                        root: root,
                        totalAllocatedBytes: 0,
                        totalLogicalBytes: 0,
                        fileCount: 0,
                        directoryCount: 0,
                        dedupedHardlinkBytes: 0,
                        elapsed: Date().timeIntervalSince(start),
                        permissionDeniedCount: counts.permissionDeniedCount,
                        tccProtectedSkippedCount: counts.tccProtectedSkippedCount,
                        incompleteIssues: counts.issues
                    )))
                    continuation.finish()
                    return
                }

                var lastProgressEmit = Date()

                while let next = enumerator.nextObject() {
                    guard let url = next as? URL else { continue }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    let policyPath = Self.policyPath(
                        forEnumeratedPath: url.path,
                        rootPath: policyRootPath,
                        resolvedRootPath: resolvedPolicyRootPath
                    )
                    if options.respectTCCSkipList && TCCSkipList.shouldSkip(policyPath) {
                        enumerator.skipDescendants()
                        reportIncomplete(ScanIncompleteIssue(
                            path: policyPath,
                            reason: .tccProtectedSkipped
                        ))
                        continue
                    }

                    let values: URLResourceValues
                    do {
                        values = try url.resourceValues(forKeys: Set(keys))
                    } catch {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        reportIncomplete(ScanFailureClassifier.issue(
                            path: url.path,
                            stage: .metadata,
                            posixErrorCode: ScanFailureClassifier.posixErrorCode(from: error)
                        ))
                        continue
                    }

                    let isDir = values.isDirectory ?? false
                    let isSymlink = values.isSymbolicLink ?? false
                    let allocated = Int64(values.totalFileAllocatedSize ?? 0)
                    let logical = Int64(values.fileSize ?? 0)
                    let modDate = values.contentModificationDate

                    // 提取 inode + device（fileResourceIdentifier 在 macOS 上是 NSData 形式）
                    var inode: UInt64 = 0
                    var device: UInt64 = 0
                    if let metadataError = extractInodeAndDevice(
                        for: url,
                        inode: &inode,
                        device: &device
                    ) {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        reportIncomplete(ScanFailureClassifier.issue(
                            path: url.path,
                            stage: .metadata,
                            posixErrorCode: metadataError
                        ))
                        continue
                    }

                    // hardlink 去重——只计第一次出现的字节。APFS clone 是不同 inode，
                    // ATTR_FILE_ALLOCSIZE 也不是 exclusive/reclaimable extent 统计，不能在这里伪装成可去重。
                    let isFirstFile = isDir
                        || !options.dedupByInode
                        || inodeSet.insertIfFirstSeen(device: device, inode: inode)

                    if isDir {
                        dirCount += 1
                    } else {
                        fileCount += 1
                        if isFirstFile {
                            totalAllocated += allocated
                            totalLogical += logical
                        } else {
                            dedupedBytes += allocated
                        }
                    }

                    let node = FSNode(
                        url: url,
                        isDirectory: isDir,
                        isSymlink: isSymlink,
                        allocatedSize: !isDir && isFirstFile ? allocated : 0,
                        logicalSize: !isDir && isFirstFile ? logical : 0,
                        inode: inode,
                        device: device,
                        modificationDate: modDate
                    )
                    continuation.yield(.node(node))

                    // 100ms 节流的进度事件
                    if Date().timeIntervalSince(lastProgressEmit) > 0.1 {
                        continuation.yield(.progress(scannedBytes: totalAllocated, fileCount: fileCount))
                        lastProgressEmit = Date()
                    }
                }

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                let counts = completeness.snapshot()

                let summary = ScanSummary(
                    root: root,
                    totalAllocatedBytes: totalAllocated,
                    totalLogicalBytes: totalLogical,
                    fileCount: fileCount,
                    directoryCount: dirCount,
                    dedupedHardlinkBytes: dedupedBytes,
                    elapsed: Date().timeIntervalSince(start),
                    permissionDeniedCount: counts.permissionDeniedCount,
                    tccProtectedSkippedCount: counts.tccProtectedSkippedCount,
                    incompleteIssues: counts.issues
                )
                continuation.yield(.finished(summary))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private extension Scanner {
    nonisolated static func policyPath(
        forEnumeratedPath path: String,
        rootPath: String,
        resolvedRootPath: String
    ) -> String {
        // `/var`, `/tmp` and `/etc` are firmlink/symlink aliases into `/private` on macOS.
        // `resolvingSymlinksInPath()` does not consistently expose that mapping for the
        // root URL, while FileManager's enumerator does canonicalize returned children.
        let privateRootPath = "/private" + rootPath
        if path == privateRootPath { return rootPath }
        let privateRootPrefix = privateRootPath + "/"
        if path.hasPrefix(privateRootPrefix) {
            return rootPath + "/" + path.dropFirst(privateRootPrefix.count)
        }
        guard resolvedRootPath != rootPath else { return path }
        if path == resolvedRootPath { return rootPath }
        let resolvedPrefix = resolvedRootPath + "/"
        guard path.hasPrefix(resolvedPrefix) else { return path }
        return rootPath + "/" + path.dropFirst(resolvedPrefix.count)
    }

}

/// FileManager 的同步 errorHandler 不能 `await` actor；用锁箱在同一扫描任务与回调之间
/// 汇总少量 issue。所有可变状态都只经 NSLock 访问，因此该引用跨 Sendable 回调是安全的。
private final class ScannerCompletenessAccumulator: @unchecked Sendable {
    struct Snapshot: Sendable {
        let issues: [ScanIncompleteIssue]
        let permissionDeniedCount: Int
        let tccProtectedSkippedCount: Int
    }

    private let lock = NSLock()
    private var issues: Set<ScanIncompleteIssue> = []

    @discardableResult
    func insert(_ issue: ScanIncompleteIssue) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return issues.insert(issue).inserted
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let sorted = issues.sorted {
            if $0.path == $1.path { return $0.reason.rawValue < $1.reason.rawValue }
            return $0.path < $1.path
        }
        return Snapshot(
            issues: sorted,
            permissionDeniedCount: sorted.count { $0.reason == .permissionDenied },
            tccProtectedSkippedCount: sorted.count { $0.reason == .tccProtectedSkipped }
        )
    }
}

/// 通过 `lstat` 取 inode + device。
/// `URLResourceKey.fileResourceIdentifier` 也行，但跨卷比较麻烦，先走 POSIX。
/// 成功返回 nil；失败返回原始 POSIX errno，供完整性证据和日志保留具体原因。
private func extractInodeAndDevice(
    for url: URL,
    inode: inout UInt64,
    device: inout UInt64
) -> Int32? {
    var st = stat()
    let result = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
        guard let ptr else { return EINVAL }
        guard lstat(ptr, &st) == 0 else { return errno }
        return 0
    }
    guard result == 0 else { return result }
    inode = UInt64(st.st_ino)
    device = UInt64(st.st_dev)
    return nil
}
