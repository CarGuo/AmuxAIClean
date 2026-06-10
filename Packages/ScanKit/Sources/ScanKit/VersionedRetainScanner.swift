import Foundation
import LogKit

/// 「保留最新 N 个版本」识别器（Mole `clean_xcode_device_support` / `clean_dev_jetbrains_toolbox`
/// / `clean_versioned_agent_root` 系列函数的 Swift 等价物）。
///
/// 适用场景：根目录下每个子目录都是「同一软件的不同版本」，需要保留最新 N 个，
/// 把更旧的标 safe（候选删除）。典型布局：
/// ```
/// ~/Library/Developer/Xcode/iOS DeviceSupport/
///   ├── 17.5 (21F79)/                  ← 旧版本（safe）
///   ├── 17.6 (21G80)/                  ← 旧版本（safe）
///   ├── 18.0 (22A3354)/                ← 保留
///   └── 18.1 (22B5054e)/               ← 保留（active）
///
/// ~/Library/Application Support/JetBrains/Toolbox/apps/IDEA-U/
///   ├── ch-0/241.18034.62/             ← 旧
///   └── ch-0/242.20224.155/            ← 保留
///
/// ~/.claude/local/                     ← Anthropic Claude Code
///   ├── 0.5.1/
///   ├── 0.6.0/
///   └── 0.7.2/                         ← 保留
/// ```
///
/// 与 [VersionsScanner] 的差异：
/// - `VersionsScanner` 走「current 软链反查」语义（rustup / asdf 等工具链管理器）；
/// - `VersionedRetainScanner` 走「按版本号排序 + 保留最新 N」语义，没有 current 指针。
///
/// 安全护栏：
/// - 只识别**目录**版本（软链 / 文件全跳过）；
/// - 版本号比较器可注入（语义化 / 字典序 / mtime 倒排）；
/// - 子目录数 ≤ keepLatest → 返回空（永不让用户在「只剩 N 个」时删任何一个）；
/// - 根不存在 / 不可读 → 返回空（保守）。
public actor VersionedRetainScanner {

    /// 一条命中：某个旧版本目录。
    public struct Hit: Sendable, Hashable, Identifiable {
        /// 旧版本目录绝对路径。
        public let url: URL
        /// 版本集合所在根，如 `~/Library/Developer/Xcode/iOS DeviceSupport`。
        public let collectionRoot: URL
        /// 排序后该子目录的"版本名"（即 lastPathComponent）。
        public let versionName: String
        /// 该集合内被保留的最新版本名（最大者）。
        public let retainedLatest: String

        public var id: String { url.path }

        public init(url: URL, collectionRoot: URL, versionName: String, retainedLatest: String) {
            self.url = url
            self.collectionRoot = collectionRoot
            self.versionName = versionName
            self.retainedLatest = retainedLatest
        }
    }

    /// 排序策略：决定"哪些算更新的版本"。
    public enum Ordering: Sendable {
        /// 语义化版本号优先（提取首段连续 `[0-9.]+` 切片做 `compareNumeric`），
        /// 解析失败 fallback 到字典序。覆盖 `17.5 (21F79)` / `0.6.0` / `242.20224.155` 等。
        case semverPreferred
        /// 纯字典序（`String.compare`，case-insensitive 否定）。
        case lexicographic
        /// 文件 mtime 倒排（最新修改优先保留）。
        case modificationDateDescending
    }

    /// 勘察配置。
    public struct Options: Sendable {
        /// 保留最近 N 个版本（按 [Ordering] 排序后的尾 N 个）。≤ 0 视为 1。
        public var keepLatest: Int
        /// 排序策略。
        public var ordering: Ordering
        /// 是否跳过隐藏目录（`.` 前缀）。
        public var skipHiddenDirectories: Bool
        /// 是否跳过子目录是软链的项（防把别处链接误算入版本数）。
        public var skipSymlinks: Bool

        public init(
            keepLatest: Int = 2,
            ordering: Ordering = .semverPreferred,
            skipHiddenDirectories: Bool = true,
            skipSymlinks: Bool = true
        ) {
            self.keepLatest = max(1, keepLatest)
            self.ordering = ordering
            self.skipHiddenDirectories = skipHiddenDirectories
            self.skipSymlinks = skipSymlinks
        }

        public static let `default` = Options()
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    /// 异步入口。
    public func discover(collectionRoot: URL) async -> [Hit] {
        let opts = options
        return await Task.detached(priority: .userInitiated) {
            VersionedRetainScanner.detect(collectionRoot: collectionRoot, options: opts)
        }.value
    }

    /// 同步识别（便于测试 + 并行批处理）。
    public nonisolated static func detect(
        collectionRoot: URL,
        options: Options = .default
    ) -> [Hit] {
        let fm = FileManager.default
        let rootPath = collectionRoot.path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { return [] }

        var candidates: [(name: String, url: URL)] = []
        for name in entries {
            if options.skipHiddenDirectories && name.hasPrefix(".") { continue }
            let child = collectionRoot.appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &childIsDir),
                  childIsDir.boolValue
            else { continue }
            if options.skipSymlinks,
               let attrs = try? fm.attributesOfItem(atPath: child.path),
               let t = attrs[.type] as? FileAttributeType,
               t == .typeSymbolicLink {
                continue
            }
            candidates.append((name, child))
        }

        // 版本数 ≤ keepLatest → 安全起见整个集合不识别
        guard candidates.count > options.keepLatest else {
            return []
        }

        // 排序：升序排列后，尾 N 个为保留版本，前面的都是旧版本
        let sorted = sort(candidates: candidates, ordering: options.ordering)
        let retainCount = options.keepLatest
        let oldCount = sorted.count - retainCount
        let retainedLatest = sorted.last?.name ?? ""

        var hits: [Hit] = []
        hits.reserveCapacity(oldCount)
        for i in 0..<oldCount {
            let entry = sorted[i]
            hits.append(Hit(
                url: entry.url,
                collectionRoot: collectionRoot,
                versionName: entry.name,
                retainedLatest: retainedLatest
            ))
        }

        if !hits.isEmpty {
            GSYLog.info(
                .scan,
                "VersionedRetainScanner root=\(rootPath) keep=\(retainCount) old=\(hits.count) latest=\(retainedLatest)"
            )
        }
        return hits
    }

    /// 升序排序（最旧→最新）。**internal** 暴露用于测试。
    nonisolated static func sort(
        candidates: [(name: String, url: URL)],
        ordering: Ordering
    ) -> [(name: String, url: URL)] {
        switch ordering {
        case .lexicographic:
            return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modificationDateDescending:
            return candidates.sorted { lhs, rhs in
                let lDate = modificationDate(of: lhs.url) ?? .distantPast
                let rDate = modificationDate(of: rhs.url) ?? .distantPast
                return lDate < rDate  // 升序：最旧在前
            }
        case .semverPreferred:
            return candidates.sorted { lhs, rhs in
                compareSemver(lhs.name, rhs.name) == .orderedAscending
            }
        }
    }

    /// 提取版本名首段连续的 `[0-9.]+` 做数值比较；解析失败 → 字典序兜底。
    ///
    /// 用例：
    /// - `"17.5 (21F79)"` vs `"18.0 (22A3354)"` → 比较 `17.5` vs `18.0` → asc
    /// - `"242.20224.155"` vs `"241.18034.62"` → desc
    /// - `"0.7.2"` vs `"0.6.0"` → desc
    nonisolated static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsVersion = extractLeadingVersion(lhs)
        let rhsVersion = extractLeadingVersion(rhs)
        if let l = lhsVersion, let r = rhsVersion {
            let cmp = l.compare(r, options: .numeric)
            if cmp != .orderedSame { return cmp }
        }
        return lhs.localizedStandardCompare(rhs)
    }

    nonisolated static func extractLeadingVersion(_ s: String) -> String? {
        var buf = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                buf.append(ch)
            } else {
                break
            }
        }
        guard !buf.isEmpty, buf.contains(where: { $0.isNumber }) else { return nil }
        return buf
    }

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}
