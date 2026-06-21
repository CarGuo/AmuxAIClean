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
