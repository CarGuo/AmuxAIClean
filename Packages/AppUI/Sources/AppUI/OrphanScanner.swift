import Foundation
import SafetyKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 协议：Bundle 反查

/// 对 LSCopyApplicationURLsForBundleIdentifier / NSWorkspace 这层的抽象，便于单测注入。
public protocol BundleResolving: Sendable {
    /// 系统里是否还有任何 .app 注册了这个 bundleID。
    /// 实际实现走 `NSWorkspace.urlForApplication(withBundleIdentifier:)`，找到即非 orphan。
    func isBundleIDRegistered(_ bundleID: String) -> Bool

    /// 已安装 app 的 appName 集合（用于不像 bundleID 的目录名做反查 fallback）。
    /// 实际实现一次性扫 `/Applications` + `/Applications/Utilities` + `~/Applications`。
    func installedAppNames() -> Set<String>
}

/// 真实实现 —— 走 NSWorkspace。
public struct DefaultBundleResolver: BundleResolving {
    public let applicationDirectories: [String]

    public init(applicationDirectories: [String] = ["/Applications", "/Applications/Utilities", "\(NSHomeDirectory())/Applications"]) {
        self.applicationDirectories = applicationDirectories
    }

    public func isBundleIDRegistered(_ bundleID: String) -> Bool {
        #if canImport(AppKit)
        // NSWorkspace 的现代 API：urlForApplication(withBundleIdentifier:)
        // 找不到返回 nil。注意：Sandbox 会限制可见性，本工程不进沙盒。
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    public func installedAppNames() -> Set<String> {
        var out = Set<String>()
        let fm = FileManager.default
        for dir in applicationDirectories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let stem = String(n.dropLast(".app".count))
                out.insert(stem)
                // 顺便读一下 Info.plist 拿 CFBundleName，stem 与 BundleName 二者命中即非 orphan
                let plistPath = "\(dir)/\(n)/Contents/Info.plist"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    if let bn = plist["CFBundleName"] as? String, !bn.isEmpty {
                        out.insert(bn)
                    }
                }
            }
        }
        return out
    }
}

// MARK: - 数据模型

/// 一条孤儿候选项 —— 反查"系统里没有任何 .app 还在用这条目录"后判定。
public struct OrphanCandidate: Hashable, Sendable {
    public let path: String
    public let name: String
    public let bytes: Int64
    public let fileCount: Int
    /// 距今最后修改天数（>=0），用来给用户判断"我多久没动它了"。
    public let lastModifiedDays: Int
    /// 反查依据：是按 bundleID 还是按 appName fallback 判定的孤儿。
    public let reason: OrphanReason

    public init(path: String, name: String, bytes: Int64, fileCount: Int,
                lastModifiedDays: Int, reason: OrphanReason) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.fileCount = fileCount
        self.lastModifiedDays = lastModifiedDays
        self.reason = reason
    }
}

public enum OrphanReason: Hashable, Sendable {
    /// 目录名形如 bundleID（含 dot），LSCopy 反查后无 .app 注册
    case bundleIDNotRegistered(String)
    /// 目录名是普通名字，扫 /Applications 后没有同名 .app
    case appNameNotInstalled(String)
}

// MARK: - 扫描器

/// 反向扫描 ~/Library 三大目录（Application Support / Caches / Preferences）找孤儿残留。
///
/// 设计准则（PITFALLS §5.4 §5.10）：
/// 1. **MinAge 阈值**：mtime 太近（< 30 天）的不当 orphan，避免新装 app 还没启动就被认 orphan
/// 2. **路径黑名单**：目录名命中 systemDirectoryNames 一律跳过，不报 orphan（com.apple.* 等）
/// 3. **路径过 SafetyEngine**：命中 forbid 直接丢；命中 vendor 根目录降为 .confirm（标在 OrphanCandidate 上）
/// 4. **bundleID 形式判定优先**：含 `.` 又不像普通文件名的（`com.foo.bar`）走 LSCopy 反查；
///    其余走 appName fallback（`Spotify`, `Code`）
public struct OrphanScanner: Sendable {
    public let homeDirectory: String
    public let resolver: BundleResolving
    public let safetyEngine: SafetyEngine
    public let fileManager: FileManagerSnapshotting
    /// 默认 30 天。最近修改过的目录，宁可漏报也不当 orphan。
    public let minAgeDays: Int
    /// 即便完全孤立也跳过的"系统路径白名单"——这些是 macOS 自身留下的，不是任何用户 app 的残留。
    public let systemDirectoryNames: Set<String>

    public init(
        homeDirectory: String = NSHomeDirectory(),
        resolver: BundleResolving = DefaultBundleResolver(),
        safetyEngine: SafetyEngine = SafetyEngine(),
        fileManager: FileManagerSnapshotting = DefaultFileManagerSnapshot(),
        minAgeDays: Int = 30,
        systemDirectoryNames: Set<String> = OrphanScanner.defaultSystemDirectoryNames
    ) {
        self.homeDirectory = homeDirectory
        self.resolver = resolver
        self.safetyEngine = safetyEngine
        self.fileManager = fileManager
        self.minAgeDays = minAgeDays
        self.systemDirectoryNames = systemDirectoryNames
    }

    /// 默认系统目录名跳过列表（不是穷举，只挡最常见的 macOS 自身组件）。
    /// 这些目录就算"无主"也不应该被建议删除。
    public static let defaultSystemDirectoryNames: Set<String> = [
        // Application Support 里 macOS 自带
        "App Store", "AddressBook", "Apple", "Mobile Documents",
        "iCloud", "FileProvider", "CloudDocs",
        "Knowledge", "CallHistoryDB", "CallHistoryTransactions",
        "MobileSync", "SyncServices", "CrashReporter",
        // Caches 里系统的（com.apple.* 走 hasPrefix 判定）
        // Preferences 里 com.apple.* 也走 hasPrefix
    ]

    /// 三大反扫根目录。
    public func searchRoots() -> [String] {
        [
            "\(homeDirectory)/Library/Application Support",
            "\(homeDirectory)/Library/Caches",
            "\(homeDirectory)/Library/Preferences"
        ]
    }

    /// 主入口 —— 列举三大根目录第一层，逐项判定 orphan。
    public func scan() -> [OrphanCandidate] {
        var out: [OrphanCandidate] = []
        let now = Date()
        for root in searchRoots() {
            guard let entries = fileManager.firstLevelEntries(at: root) else { continue }
            for entry in entries {
                if let cand = evaluate(entry: entry, root: root, now: now) {
                    out.append(cand)
                }
            }
        }
        return out
    }

    /// 暴露给单测的纯函数判定逻辑。
    func evaluate(entry: FSEntry, root: String, now: Date) -> OrphanCandidate? {
        let name = entry.name

        // 跳过隐藏（dotfile）和系统组件
        if name.hasPrefix(".") { return nil }
        if name.hasPrefix("com.apple.") { return nil }
        if systemDirectoryNames.contains(name) { return nil }

        // 取 stem（去 .plist / .savedState 等后缀）用于 bundleID 反查
        let stem = stemOf(name)

        // 反查
        let reason: OrphanReason?
        if isBundleIDLike(stem) {
            if resolver.isBundleIDRegistered(stem) {
                reason = nil   // 还有 .app 在用 → 非 orphan
            } else {
                reason = .bundleIDNotRegistered(stem)
            }
        } else {
            // 普通目录名：和已安装 app 的名字集合做 case-insensitive 匹配
            let installed = resolver.installedAppNames()
            let lowerName = stem.lowercased()
            if installed.contains(where: { $0.lowercased() == lowerName }) {
                reason = nil
            } else {
                reason = .appNameNotInstalled(stem)
            }
        }
        guard let resolvedReason = reason else { return nil }

        // 安全闸
        let (verdict, _) = safetyEngine.evaluate(path: entry.path, home: homeDirectory)
        if verdict == .forbid { return nil }

        // mtime 阈值
        let mtime = mtimeOf(path: entry.path) ?? now
        let days = Int(now.timeIntervalSince(mtime) / 86400)
        if days < minAgeDays { return nil }

        let snap = fileManager.snapshot(at: entry.path)
        return OrphanCandidate(
            path: entry.path,
            name: name,
            bytes: snap.bytes,
            fileCount: snap.fileCount,
            lastModifiedDays: days,
            reason: resolvedReason
        )
    }

    // MARK: - 纯工具

    /// 像 bundleID 吗？规则：包含至少一个 `.` 且去掉后缀后的 stem 至少有 1 个 dot。
    /// 不严格要求"反域名"形态（有些 app 用 `notion.id`、`dev.zed.Zed` 也算）。
    static func isBundleIDLike(_ stem: String) -> Bool {
        stem.contains(".") && !stem.hasPrefix(".")
    }

    func isBundleIDLike(_ stem: String) -> Bool {
        Self.isBundleIDLike(stem)
    }

    /// 去掉 `.plist` / `.savedState` 等后缀（取最后一个 dot 之前的部分）但保留中间 dot。
    /// `com.foo.bar.plist` → `com.foo.bar`
    /// `com.foo.bar` → `com.foo.bar`（无尾后缀）
    /// `Spotify` → `Spotify`
    static func stemOf(_ name: String) -> String {
        let knownSuffixes = [".plist", ".savedState", ".lock"]
        for s in knownSuffixes {
            if name.hasSuffix(s) {
                return String(name.dropLast(s.count))
            }
        }
        return name
    }

    func stemOf(_ name: String) -> String { Self.stemOf(name) }

    /// 取 mtime（lstat）。读不到返回 nil。
    func mtimeOf(path: String) -> Date? {
        var sb = stat()
        if lstat(path, &sb) == 0 {
            #if os(macOS)
            let ts = sb.st_mtimespec
            #else
            let ts = sb.st_mtim
            #endif
            let secs = TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9
            return Date(timeIntervalSince1970: secs)
        }
        return nil
    }
}
