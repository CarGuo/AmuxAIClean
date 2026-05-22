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
}
