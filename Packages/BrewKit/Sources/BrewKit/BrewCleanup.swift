import Darwin
import Foundation

/// BrewKit Step 16-B3 —— `brew cleanup` 的 dryRun 等价物（纯文件枚举，不执行 brew）。
///
/// 设计来源（[docs/AUDIT_2026_06.md L114](file:///Users/amuxuser/workspace/AmuxAIClean/docs/AUDIT_2026_06.md#L114)）：
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

/// v2026.07.18 P2 evidence-bearing cleanup result. `dryRun()` remains as the compatibility value
/// API, while production UI consumes this result so an unreadable cache can never be presented as
/// an authoritative empty plan. `bytesByPath` is captured in the same filesystem pass as the plan;
/// AppUI must not re-read attributes and silently invent zero-byte metadata later.
public struct BrewCleanupResult: Sendable, Equatable {
    public let plan: BrewCleanupPlan
    public let bytesByPath: [String: Int64]
    public let status: BrewEvidenceStatus
    public let diagnostics: [BrewDiagnostic]

    public init(
        plan: BrewCleanupPlan,
        bytesByPath: [String: Int64],
        status: BrewEvidenceStatus,
        diagnostics: [BrewDiagnostic] = []
    ) {
        self.plan = plan
        self.bytesByPath = bytesByPath
        self.status = status
        self.diagnostics = diagnostics
    }

    public var isAuthoritativeEmpty: Bool {
        plan.isEmpty && status.isAuthoritative
    }
}

/// Injectable filesystem facts keep permission, malformed-attribute and symlink failures
/// deterministic in tests without chmod/TCC assumptions. The live adapter converts Foundation's
/// `[FileAttributeKey: Any]` at the boundary and never sends that non-Sendable dictionary across
/// concurrency domains.
struct BrewCleanupEntryAttributes: Sendable, Equatable {
    let isSymbolicLink: Bool?
    let modificationDate: Date?
    let size: Int64?
}

struct BrewCleanupFileSystem: Sendable {
    let contentsOfDirectory: @Sendable (URL) throws -> [String]
    let attributes: @Sendable (URL) throws -> BrewCleanupEntryAttributes
    let symlinkDestination: @Sendable (URL) throws -> String

    static let live = BrewCleanupFileSystem(
        contentsOfDirectory: { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        attributes: { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return BrewCleanupEntryAttributes(
                isSymbolicLink: (attributes[.type] as? FileAttributeType).map {
                    $0 == .typeSymbolicLink
                },
                modificationDate: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.int64Value
            )
        },
        symlinkDestination: { url in
            try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        }
    )
}

public struct BrewCleanup: Sendable {

    /// 默认阈值：mtime ≥ 30 天前；冷却 7 天；建议执行 50 MB。
    public static let defaultPruneDays: Int = 30
    public static let defaultCooldownDays: Int = 7
    public static let defaultMinBytes: Int64 = 50 * 1024 * 1024

    /// brew cache 根（一般 `~/Library/Caches/Homebrew`）。
    public let cacheRoot: URL
    private let fileSystem: BrewCleanupFileSystem

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        self.fileSystem = .live
    }

    init(cacheRoot: URL, fileSystem: BrewCleanupFileSystem) {
        self.cacheRoot = cacheRoot
        self.fileSystem = fileSystem
    }

    /// v2026.07.18 P2: returns the deterministic user cache location without claiming the root is
    /// readable or even present. Production UI uses this candidate and lets `dryRunWithEvidence`
    /// distinguish missing from unreadable instead of collapsing both into a nil controller.
    public static func defaultCacheCandidate() -> BrewCleanup? {
        let fm = FileManager.default
        guard let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let root = cache.appendingPathComponent("Homebrew", isDirectory: true)
        return BrewCleanup(cacheRoot: root)
    }

    /// Compatibility API: detects an existing default root as before. New production consumers
    /// that need typed absence/failure evidence should use `defaultCacheCandidate()` and scan it.
    public static func detectDefault() -> BrewCleanup? {
        guard let candidate = defaultCacheCandidate() else { return nil }
        let root = candidate.cacheRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return candidate
    }

    /// 计算可清理列表（dryRun）。
    /// - Parameters:
    ///   - now: 当前时间（测试可注入）
    ///   - pruneDays: 早于 `now - pruneDays` 视作 stale
    public func dryRun(now: Date = Date(),
                       pruneDays: Int = BrewCleanup.defaultPruneDays) -> BrewCleanupPlan {
        dryRunWithEvidence(now: now, pruneDays: pruneDays).plan
    }

    /// v2026.07.18 P2 root fix: every failure remains typed. Cache/download roots that are truly
    /// absent are a normal authoritative empty state; unreadable roots are unavailable; per-entry
    /// failures yield partial evidence and the affected entry is never admitted to the plan.
    public func dryRunWithEvidence(
        now: Date = Date(),
        pruneDays: Int = BrewCleanup.defaultPruneDays
    ) -> BrewCleanupResult {
        let downloads = cacheRoot.appendingPathComponent("downloads", isDirectory: true)
        let rootEntries: [String]
        do {
            rootEntries = try fileSystem.contentsOfDirectory(cacheRoot)
        } catch {
            guard let diagnostic = brewLocalFileFailureDiagnostic(
                error,
                source: .cleanup,
                stage: .enumerateRoot,
                path: cacheRoot.path
            ) else {
                return emptyResult(status: .missing)
            }
            return emptyResult(status: .unavailable, diagnostics: [diagnostic])
        }

        let aliases = collectActiveDownloadFilenames(rootEntries: rootEntries)
        guard aliases.diagnostics.isEmpty else {
            // A root entry whose type/target cannot be inspected may alias any download. No
            // candidate is trustworthy until the active-reference set is complete.
            return emptyResult(status: .unavailable, diagnostics: aliases.diagnostics)
        }

        var downloadsStat = stat()
        if lstat(downloads.path, &downloadsStat) == 0 {
            guard (downloadsStat.st_mode & S_IFMT) == S_IFDIR else {
                return emptyResult(status: .missing)
            }
        }
        if (try? fileSystem.attributes(downloads).isSymbolicLink) == true {
            return emptyResult(status: .missing)
        }

        let entries: [String]
        do {
            entries = try fileSystem.contentsOfDirectory(downloads)
        } catch {
            guard let diagnostic = brewLocalFileFailureDiagnostic(
                error,
                source: .cleanup,
                stage: .enumerateDownloads,
                path: downloads.path
            ) else {
                return emptyResult(status: .missing)
            }
            return emptyResult(status: .unavailable, diagnostics: [diagnostic])
        }

        let pruneBefore = now.addingTimeInterval(-Double(pruneDays) * 86400)

        var stale: [URL] = []
        var bytesByPath: [String: Int64] = [:]
        var diagnostics: [BrewDiagnostic] = []
        var bytes: Int64 = 0
        for name in entries where !name.hasPrefix(".") {
            if aliases.names.contains(name) { continue }
            let url = downloads.appendingPathComponent(name)
            let attributes: BrewCleanupEntryAttributes
            do {
                attributes = try fileSystem.attributes(url)
            } catch {
                if let diagnostic = brewLocalFileFailureDiagnostic(
                    error,
                    source: .cleanup,
                    stage: .inspectEntry,
                    path: url.path
                ) {
                    diagnostics.append(diagnostic)
                }
                // A disappeared entry no longer needs cleanup; every other failure is partial.
                continue
            }

            guard let mtime = attributes.modificationDate,
                  let size = attributes.size,
                  size >= 0 else {
                diagnostics.append(BrewDiagnostic(
                    source: .cleanup,
                    stage: .inspectEntry,
                    reason: .missingMetadata,
                    path: url.path
                ))
                continue
            }
            guard mtime < pruneBefore else { continue }

            let total = bytes.addingReportingOverflow(size)
            guard !total.overflow else {
                diagnostics.append(BrewDiagnostic(
                    source: .cleanup,
                    stage: .inspectEntry,
                    reason: .malformed,
                    path: url.path
                ))
                continue
            }
            stale.append(url)
            bytesByPath[url.path] = size
            bytes = total.partialValue
        }
        stale.sort { $0.lastPathComponent < $1.lastPathComponent }
        return BrewCleanupResult(
            plan: BrewCleanupPlan(stalePaths: stale, totalBytes: bytes),
            bytesByPath: bytesByPath,
            status: diagnostics.isEmpty ? .complete : .partial,
            diagnostics: diagnostics
        )
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

    /// 枚举 cacheRoot 顶层以及 `Cask/` 子目录的 symlink，把 target 文件名（downloads/<name>）收集起来。
    /// 这些文件不算 stale，因为仍有"活跃 bottle / cask 别名"指向。
    private func collectActiveDownloadFilenames(
        rootEntries: [String]
    ) -> (names: Set<String>, diagnostics: [BrewDiagnostic]) {
        var active = Set<String>()
        var diagnostics: [BrewDiagnostic] = []

        func inspectSymlinkEntry(_ entry: URL, checkCaskDirectory: Bool) {
            let attributes: BrewCleanupEntryAttributes
            do {
                attributes = try fileSystem.attributes(entry)
            } catch {
                if let diagnostic = brewLocalFileFailureDiagnostic(
                    error,
                    source: .cleanup,
                    stage: .inspectEntry,
                    path: entry.path
                ) {
                    diagnostics.append(diagnostic)
                }
                return
            }
            guard let isSymbolicLink = attributes.isSymbolicLink else {
                diagnostics.append(BrewDiagnostic(
                    source: .cleanup,
                    stage: .inspectEntry,
                    reason: .missingMetadata,
                    path: entry.path
                ))
                return
            }
            if !isSymbolicLink {
                if checkCaskDirectory,
                   entry.lastPathComponent == "Cask" {
                    // v2026.10.07: aliases under Cask are part of the active-reference proof.
                    // An unreadable directory invalidates that proof just like a root alias;
                    // silently treating it as empty could admit a still-active download.
                    do {
                        let caskEntries = try fileSystem.contentsOfDirectory(entry)
                        for caskName in caskEntries where !caskName.hasPrefix(".") {
                            inspectSymlinkEntry(
                                entry.appendingPathComponent(caskName),
                                checkCaskDirectory: false
                            )
                        }
                    } catch {
                        if let diagnostic = brewLocalFileFailureDiagnostic(
                            error, source: .cleanup, stage: .inspectEntry, path: entry.path
                        ) {
                            diagnostics.append(diagnostic)
                        }
                    }
                }
                return
            }

            let dest: String
            do {
                dest = try fileSystem.symlinkDestination(entry)
            } catch {
                if let diagnostic = brewLocalFileFailureDiagnostic(
                    error,
                    source: .cleanup,
                    stage: .resolveSymlink,
                    path: entry.path
                ) {
                    diagnostics.append(diagnostic)
                }
                return
            }
            // dest 形如 "downloads/<hash>--xxx.tar.gz"、"../downloads/<hash>--xxx.dmg" 或相对裸文件名 "<hash>--xxx.tar.gz"
            let comp = (dest as NSString).pathComponents.filter { $0 != "/" && $0 != "." && $0 != ".." }
            if comp.count >= 2 && comp[comp.count - 2] == "downloads" {
                active.insert(comp[comp.count - 1])
            } else if comp.count == 1 {
                // 相对裸文件名 fallback
                active.insert(comp[0])
            }
        }

        for name in rootEntries where !name.hasPrefix(".") {
            let entry = cacheRoot.appendingPathComponent(name)
            inspectSymlinkEntry(entry, checkCaskDirectory: true)
        }
        return (active, diagnostics)
    }

    private func emptyResult(
        status: BrewEvidenceStatus,
        diagnostics: [BrewDiagnostic] = []
    ) -> BrewCleanupResult {
        BrewCleanupResult(
            plan: BrewCleanupPlan(stalePaths: [], totalBytes: 0),
            bytesByPath: [:],
            status: status,
            diagnostics: diagnostics
        )
    }
}
