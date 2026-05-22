import Foundation

/// 文件扫描引擎（v0 朴素版本）。
///
/// 目标：**正确性优先**。
/// - 物理占用 (`totalFileAllocatedSize`) 而非逻辑大小（解决 iCloud 占位 / 稀疏文件）
/// - 按 inode 去重（解决硬链接 / APFS clone）
/// - 默认包含隐藏文件
/// - 增量 AsyncStream 输出
///
/// 性能优化（getattrlistbulk + C bridging）放 v1 再做，先把正确性做扎实。
public actor Scanner {
    private let options: ScanOptions
    private let inodeSet = InodeSet()

    public init(options: ScanOptions = .default) {
        self.options = options
    }

    /// 扫描指定根目录，返回事件流。
    public nonisolated func scan(root: URL) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [options, inodeSet] in
                let start = Date()
                var fileCount = 0
                var dirCount = 0
                var totalAllocated: Int64 = 0
                var totalLogical: Int64 = 0
                var dedupedBytes: Int64 = 0

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

                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: enumOptions
                ) else {
                    continuation.yield(.failed(ScanError.cannotEnumerate(root)))
                    continuation.finish()
                    return
                }

                var lastProgressEmit = Date()

                while let next = enumerator.nextObject() {
                    guard let url = next as? URL else { continue }
                    if Task.isCancelled { break }

                    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

                    let isDir = values.isDirectory ?? false
                    let isSymlink = values.isSymbolicLink ?? false
                    let allocated = Int64(values.totalFileAllocatedSize ?? 0)
                    let logical = Int64(values.fileSize ?? 0)
                    let modDate = values.contentModificationDate

                    // 提取 inode + device（fileResourceIdentifier 在 macOS 上是 NSData 形式）
                    var inode: UInt64 = 0
                    var device: UInt64 = 0
                    extractInodeAndDevice(for: url, inode: &inode, device: &device)

                    // 硬链接 / clone 去重——只计第一次出现的字节
                    let isFirst = !options.dedupByInode || inodeSet.insertIfFirstSeen(device: device, inode: inode)

                    if isDir {
                        dirCount += 1
                    } else {
                        fileCount += 1
                        if isFirst {
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
                        allocatedSize: allocated,
                        logicalSize: logical,
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

                let summary = ScanSummary(
                    root: root,
                    totalAllocatedBytes: totalAllocated,
                    totalLogicalBytes: totalLogical,
                    fileCount: fileCount,
                    directoryCount: dirCount,
                    dedupedHardlinkBytes: dedupedBytes,
                    elapsed: Date().timeIntervalSince(start)
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

public enum ScanError: Error, Sendable {
    case cannotEnumerate(URL)
}

/// 通过 `lstat` 取 inode + device。
/// `URLResourceKey.fileResourceIdentifier` 也行，但跨卷比较麻烦，先走 POSIX。
private func extractInodeAndDevice(for url: URL, inode: inout UInt64, device: inout UInt64) {
    var st = stat()
    let path = url.withUnsafeFileSystemRepresentation { ptr -> [CChar] in
        guard let ptr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: strlen(ptr) + 1))
    }
    guard !path.isEmpty else { return }
    if path.withUnsafeBufferPointer({ lstat($0.baseAddress, &st) }) == 0 {
        inode = UInt64(st.st_ino)
        device = UInt64(st.st_dev)
    }
}
