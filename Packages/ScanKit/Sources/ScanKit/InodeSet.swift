import Foundation

/// 跨卷的 hardlink inode 去重表。
///
/// 见 [PITFALLS §2.3](../../../../PITFALLS.md)：Time Machine 的 `Backups.backupdb` 全是硬链接，
/// 朴素 `du` 算出 5TB 实际只有 500GB。我们必须按 (dev_t, ino_t) 去重。
public final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// v2026.07.17 transaction-ledger regression guard:
    /// `MultiRootScanner` shares one allocation identity ledger across all root workers so a
    /// physical hardlink allocation is counted once per multi-root transaction. A single lock
    /// would serialize every file across as many as 24 workers and could reintroduce the scan
    /// performance regression this ledger is meant to fix. Power-of-two striping keeps the
    /// atomic "first observer wins" contract while unrelated inode identities proceed in
    /// parallel. The key never escapes its shard, so count/reset remain exact.
    private final class Shard: @unchecked Sendable {
        let lock = NSLock()
        var seen: Set<Key> = []
    }

    private static let shardCount = 64
    private let shards: [Shard]

    public init() {
        shards = (0..<Self.shardCount).map { _ in Shard() }
    }

    /// 返回 true 表示是首次出现（应该计入大小），false 表示已经计过。
    public func insertIfFirstSeen(device: UInt64, inode: UInt64) -> Bool {
        // 0 表示底层 metadata 没有提供稳定 inode。把多个 (0, 0) 当同一文件会让
        // fallback/权限异常下除第一项之外全部归零；未知身份只能保守地各自计入。
        guard inode != 0 else { return true }
        let key = Key(device: device, inode: inode)
        let shard = shards[shardIndex(device: device, inode: inode)]
        shard.lock.lock()
        defer { shard.lock.unlock() }
        return shard.seen.insert(key).inserted
    }

    public var count: Int {
        var total = 0
        // Each shard is locked and released independently. `count` is diagnostic/test-only;
        // scan accounting never samples it while workers are mutating the ledger.
        for shard in shards {
            shard.lock.lock()
            total += shard.seen.count
            shard.lock.unlock()
        }
        return total
    }

    /// 仅供明确拥有单次 transaction 的调用方复用；Scanner/BulkScanner 为每个 stream
    /// 创建独立集合，不通过 reset 协调并发扫描。
    public func reset() {
        for shard in shards {
            shard.lock.lock()
            shard.seen.removeAll(keepingCapacity: true)
            shard.lock.unlock()
        }
    }

    @inline(__always)
    private func shardIndex(device: UInt64, inode: UInt64) -> Int {
        // Stable integer mixing avoids invoking Swift's randomized Hasher on the hot path.
        // shardCount is deliberately a power of two so masking is cheaper than modulo.
        let mixed = (device &* 0x9E37_79B9_7F4A_7C15)
            ^ (inode &* 0xC2B2_AE3D_27D4_EB4F)
        return Int(truncatingIfNeeded: mixed) & (Self.shardCount - 1)
    }
}

/// 目录级 (dev_t, ino_t) 去重表，专门防"无限下钻"。
///
/// v1.3 P0-A 修复：与 `InodeSet`（字节/硬链接去重）刻意分离，避免语义耦合。
/// 必要性来源：
/// 1. **APFS firmlink** —— `/System/Volumes/Data/Users` 与 `/Users` 共享同一 (dev,ino)，
///    任何一头被同次扫描登记后另一头必须被跳过，否则整棵家目录被算两次 + Stream 永不收敛。
/// 2. **dir hardlink** —— Time Machine `Backups.backupdb` 大量使用 directory hardlink，
///    朴素 BFS 会反复访问同一物理目录。
/// 3. **pnpm/lerna 风格 symlink-to-dir** —— `node_modules/.bin` 与 `node_modules/foo` 通过
///    符号链接互指，若 followSymlinks 没真正消费，processDirectory 会无限回环。
///
/// 与 InodeSet 的差异：InodeSet 跟踪"文件 inode 是否已计入字节"，DirInodeSet 跟踪
/// "目录 inode 是否已被入队下钻"；两者命中后行为不同（前者归 deduped 字节，后者直接 skip）。
public final class DirInodeSet: @unchecked Sendable {
    private struct Key: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private let lock = NSLock()
    private var seen: Set<Key> = []

    public init() {}

    /// 返回 true 表示首次出现（应入队下钻），false 表示已访问（跳过）。
    /// 注意：inode==0 视为"内核未提供"，保守允许通过（不去重），由调用方决定是否额外校验。
    public func insertIfFirstSeen(device: UInt64, inode: UInt64) -> Bool {
        guard inode != 0 else { return true }
        let key = Key(device: device, inode: inode)
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(key).inserted
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        seen.removeAll(keepingCapacity: true)
    }
}
