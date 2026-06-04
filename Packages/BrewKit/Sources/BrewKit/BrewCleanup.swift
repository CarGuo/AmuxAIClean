import Foundation

/// BrewKit Step 16-B3 —— `brew cleanup` 的 dryRun 等价物（纯文件枚举，不执行 brew）。
///
/// 设计来源（[docs/AUDIT_2026_06.md L114](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/AUDIT_2026_06.md#L114)）：
/// > Homebrew 主动 cleanup —— `brew cleanup --prune=30 + brew autoremove`，
/// > 7 天冷却 + 50MB 阈值。AppUI 加"一键操作"按钮（不在 ScanKit 落地）。
///
/// **dryRun 语义**（不实际删，只列）：
/// 1. 枚举 `{cache}/downloads/*` 所有文件
/// 2. 排除"被 cache 顶层 symlink 指向"的（仍是活跃 bottle，不算 stale）
/// 3. 剩下的按 mtime 早于 `pruneDate` 标 stale
///
/// **建议执行条件**（[shouldRun(...)]）：
/// - 距上次清理 ≥ 7 天
/// - 累计可清字节数 ≥ 50 MB
public struct BrewCleanupPlan: Sendable, Equatable {
    public let stalePaths: [URL]
    public let totalBytes: Int64

    public init(stalePaths: [URL], totalBytes: Int64) {
        self.stalePaths = stalePaths
        self.totalBytes = totalBytes
    }

    public var isEmpty: Bool { stalePaths.isEmpty }
}

public struct BrewCleanup: Sendable {

    /// 默认阈值：mtime ≥ 30 天前；冷却 7 天；建议执行 50 MB。
    public static let defaultPruneDays: Int = 30
    public static let defaultCooldownDays: Int = 7
    public static let defaultMinBytes: Int64 = 50 * 1024 * 1024

    /// brew cache 根（一般 `~/Library/Caches/Homebrew`）。
    public let cacheRoot: URL

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    /// 默认根 `~/Library/Caches/Homebrew`；目录缺失时返回 nil。
    public static func detectDefault() -> BrewCleanup? {
        let fm = FileManager.default
        guard let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let root = cache.appendingPathComponent("Homebrew", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return nil }
        return BrewCleanup(cacheRoot: root)
    }

    /// 计算可清理列表（dryRun）。
    /// - Parameters:
    ///   - now: 当前时间（测试可注入）
    ///   - pruneDays: 早于 `now - pruneDays` 视作 stale
    public func dryRun(now: Date = Date(),
                       pruneDays: Int = BrewCleanup.defaultPruneDays) -> BrewCleanupPlan {
        let downloads = cacheRoot.appendingPathComponent("downloads", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: downloads.path) else {
            return BrewCleanupPlan(stalePaths: [], totalBytes: 0)
        }

        let activeNames = collectActiveDownloadFilenames()
        let pruneBefore = now.addingTimeInterval(-Double(pruneDays) * 86400)

        var stale: [URL] = []
        var bytes: Int64 = 0
        guard let entries = try? fm.contentsOfDirectory(atPath: downloads.path) else {
            return BrewCleanupPlan(stalePaths: [], totalBytes: 0)
        }
        for name in entries where !name.hasPrefix(".") {
            if activeNames.contains(name) { continue }
            let url = downloads.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            guard mtime < pruneBefore else { continue }
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            stale.append(url)
            bytes += size
        }
        stale.sort { $0.lastPathComponent < $1.lastPathComponent }
        return BrewCleanupPlan(stalePaths: stale, totalBytes: bytes)
    }

    /// 建议是否执行 cleanup：
    /// - 距上次清理 ≥ cooldownDays
    /// - plan.totalBytes ≥ minBytes
    /// `lastCleanupAt == nil` 视作"从未清理"（满足冷却条件）。
    public static func shouldRun(plan: BrewCleanupPlan,
                                 lastCleanupAt: Date?,
                                 now: Date = Date(),
                                 cooldownDays: Int = defaultCooldownDays,
                                 minBytes: Int64 = defaultMinBytes) -> Bool {
        guard plan.totalBytes >= minBytes else { return false }
        guard let last = lastCleanupAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= Double(cooldownDays) * 86400
    }

    // MARK: - 内部

    /// 枚举 cacheRoot 顶层的 symlink，把 target 文件名（downloads/<name>）收集起来。
    /// 这些文件不算 stale，因为仍有"活跃 bottle 别名"指向。
    private func collectActiveDownloadFilenames() -> Set<String> {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cacheRoot.path) else {
            return []
        }
        var active = Set<String>()
        for name in names where !name.hasPrefix(".") {
            let entry = cacheRoot.appendingPathComponent(name)
            // 仅看 symlink；普通文件 / 目录不算 alias
            guard let attrs = try? fm.attributesOfItem(atPath: entry.path),
                  (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { continue }
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
            // dest 形如 "downloads/<hash>--xxx.tar.gz"
            let url = URL(fileURLWithPath: dest)
            let comp = url.pathComponents
            if comp.count >= 2 && comp[comp.count - 2] == "downloads" {
                active.insert(url.lastPathComponent)
            } else if comp.count == 1 {
                // 相对裸文件名 fallback
                active.insert(dest)
            }
        }
        return active
    }
}
