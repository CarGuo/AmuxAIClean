import Foundation

/// 跨卷的硬链接 / APFS clone 去重表。
///
/// 见 [PITFALLS §2.3](../../../../PITFALLS.md)：Time Machine 的 `Backups.backupdb` 全是硬链接，
/// 朴素 `du` 算出 5TB 实际只有 500GB。我们必须按 (dev_t, ino_t) 去重。
public final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private let lock = NSLock()
    private var seen: Set<Key> = []

    public init() {}

    /// 返回 true 表示是首次出现（应该计入大小），false 表示已经计过。
    public func insertIfFirstSeen(device: UInt64, inode: UInt64) -> Bool {
        let key = Key(device: device, inode: inode)
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(key).inserted
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }

    /// v1.3 P0 修复：跨次扫描必须显式 reset。
    /// `BulkScanner` 单例的 `inodeSet` 属性生命周期等于 actor，
    /// 同一个 BulkScanner 跑第二次 scan 时若不清空，几乎所有文件都会被判 "isFirst==false"
    /// → 字节累加到 dedupedBytes 而非 totalAllocated，体积归零（计数仍正常）。
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        seen.removeAll(keepingCapacity: true)
    }
}
