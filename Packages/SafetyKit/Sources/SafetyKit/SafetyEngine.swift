import Foundation

/// 安全评分结果。
public enum SafetyVerdict: String, Sendable {
    case safe       // 🟢 缓存、日志、DerivedData
    case confirm    // 🟡 需用户确认
    case forbid     // 🔴 SIP / 用户文档 / 共享厂商 / 硬编码黑名单
}

/// 拒绝原因（机器可读，便于审计 / 单测断言）。
public enum SafetyRejection: String, Sendable, Equatable {
    case relativePath           // 不是绝对路径
    case dotDotInPath           // 含 .. 段（路径穿越）
    case rootOrAboveHome        // / 或用户家目录本身
    case hardForbidPrefix       // 命中硬编码黑名单
    case userDocumentsRoot      // 用户文档/桌面/下载的根
    case systemVolume           // 系统卷
    case insideAppBundle        // 在 .app 内但不是 Caches
    case ok
}

/// 占位实现。完整规则引擎将基于 YAML 规则库驱动，详见 PITFALLS §3 与 PLAN.md。
///
/// **设计原则**（写死的红线）：
/// 1. 只接受**绝对路径**，且必须经过 `URL(fileURLWithPath:).standardizedFileURL` 标准化
/// 2. 任何 `..` 段一律 forbid（防穿越）
/// 3. 用户家目录本身、桌面、文档、下载的**根目录**禁删（只能删它们的*子节点*）
/// 4. 命中黑名单一律 forbid（不留 confirm 余地）
public struct SafetyEngine: Sendable {
    public init() {}

    /// 写死的"绝对禁删"路径前缀（与 PITFALLS §3.5 黑名单一致）。
    /// 注意：所有前缀都是 standardizedFileURL **之后**的形式
    /// （即 `/private/var/db` 会被标准化为 `/var/db`，所以这里写两份覆盖）。
    public static let hardForbidPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin", "/sbin",
        "/Library/Apple",
        "/private/var/db", "/var/db",
        "/private/var/protected", "/var/protected",
        "/private/etc", "/etc",
        "/Volumes/Macintosh HD",
        "/Applications" // 不允许通过本工具删 App，让用户走 Finder
    ]

    /// 用户家目录下"根级别"禁删（防止用户拖进整个文件夹被一键带走）。
    public static func userRootForbidden(home: String) -> [String] {
        [
            home,
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Library",
            "\(home)/Library/Mobile Documents", // iCloud Drive 根
            "\(home)/Library/Containers",       // 沙盒容器根
            "\(home)/Library/Group Containers"
        ]
    }

    /// 已知"系统语义就是给清理工具刷的"路径前缀 —— 默认 `safe`，UI 可默认勾选。
    /// 见 PITFALLS §3 / §5.5：必须是**严格匹配的子节点**，不允许整删根本身。
    public static func safeCachePrefixes(home: String) -> [String] {
        let dataPrefix = "/System/Volumes/Data" // firmlink 等价镜像
        let primary = [
            "\(home)/Library/Caches/",
            "\(home)/Library/Logs/",
            "\(home)/Library/Developer/Xcode/DerivedData/",
            "\(home)/Library/Developer/Xcode/Archives/",
            "\(home)/Library/Developer/CoreSimulator/Caches/"
        ]
        // 系统级（任何用户共享的 per-user 临时区）
        let system = [
            "/private/var/folders/",
            "/var/folders/"
        ]
        return primary + primary.map { "\(dataPrefix)\($0)" } + system
    }

    /// 严格判定。返回 (verdict, rejection)。
    /// - 任何不确定都向 `forbid` 倾斜，宁可误拒不可误删。
    public func evaluate(path: String, home: String = NSHomeDirectory()) -> (SafetyVerdict, SafetyRejection) {
        // 1. 必须绝对路径
        guard path.hasPrefix("/") else {
            return (.forbid, .relativePath)
        }
        // 2. 不能含 ..
        if path.contains("/../") || path.hasSuffix("/..") || path == ".." {
            return (.forbid, .dotDotInPath)
        }
        // 3. 标准化后再比较
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return evaluateStandardized(standardized: standardized, home: home)
    }

    /// 已 standardize 路径的内部判定。trie 重载会复用这个入口，避免重复 standardize。
    /// 调用者必须保证 `standardized` 已经过 `URL.standardizedFileURL.path`。
    private func evaluateStandardized(standardized: String, home: String) -> (SafetyVerdict, SafetyRejection) {
        // 4. 根目录、`/` 本身
        if standardized == "/" || standardized.isEmpty {
            return (.forbid, .rootOrAboveHome)
        }
        // 5. 硬编码黑名单
        //    例外：/System/Volumes/Data/... 是数据卷穿透，需要单独放过
        let isDataVolumePassthrough = standardized.hasPrefix("/System/Volumes/Data/")
            && standardized != "/System/Volumes/Data"
        if !isDataVolumePassthrough {
            for prefix in Self.hardForbidPrefixes {
                if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                    return (.forbid, .hardForbidPrefix)
                }
            }
        }
        // 6. 用户根级目录不允许整删
        for forbidden in Self.userRootForbidden(home: home) {
            if standardized == forbidden {
                return (.forbid, .userDocumentsRoot)
            }
        }
        // 7. 不允许触碰其他卷的系统区
        if standardized.hasPrefix("/System/Volumes/")
            && !standardized.hasPrefix("/System/Volumes/Data/") {
            return (.forbid, .systemVolume)
        }
        // 8. 已知缓存路径升级为 safe（UI 可默认勾选）
        for safePrefix in Self.safeCachePrefixes(home: home) {
            if standardized.hasPrefix(safePrefix) {
                return (.safe, .ok)
            }
        }

        return (.confirm, .ok)
    }

    /// 简单语义包装：是否被禁。
    public func isForbidden(path: String, home: String = NSHomeDirectory()) -> Bool {
        evaluate(path: path, home: home).0 == .forbid
    }

    /// 带 vendor 规则的评估（PITFALLS §5.9）。
    /// 命中 vendor 规则的根目录会被强制降到 `.confirm`，UI 不默认勾选 + 显示提示
    /// （即使该路径在 safeCachePrefixes 里也不行 —— 比如 ~/Library/Caches/com.adobe 这种）。
    /// vendor 子目录（即非根目录）依然走 evaluate 原有逻辑。
    ///
    /// 外部 API 保持不变；内部委托给基于 `VendorTrie` 的高性能重载。
    /// 若同一组 vendors 会被反复评估，**强烈建议**外部自行 `VendorTrie.build(...)` 一次后
    /// 调用 `evaluate(path:trie:home:)`，避免每次评估都重建 trie。
    public func evaluate(path: String, vendors: [VendorRule],
                         home: String = NSHomeDirectory()) -> (SafetyVerdict, SafetyRejection, VendorRule?) {
        let trie = VendorTrie.build(vendors: vendors, home: home)
        return evaluate(path: path, trie: trie, home: home)
    }

    /// Trie 版评估：与 `evaluate(path:vendors:home:)` 语义等价，但匹配复杂度从
    /// O(vendors × prefixes) 降到 O(路径深度)。`trie` 由 `VendorTrie.build(...)` 预构建。
    public func evaluate(path: String, trie: VendorTrieNode,
                         home: String = NSHomeDirectory()) -> (SafetyVerdict, SafetyRejection, VendorRule?) {
        // 1. 基础前置校验（与 evaluate(path:home:) 前两步一致）
        guard path.hasPrefix("/") else {
            return (.forbid, .relativePath, nil)
        }
        if path.contains("/../") || path.hasSuffix("/..") || path == ".." {
            return (.forbid, .dotDotInPath, nil)
        }
        // 2. 只 standardize 一次，复用给 base 判定 + trie 匹配
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let (baseVerdict, rejection) = evaluateStandardized(standardized: standardized, home: home)
        if baseVerdict == .forbid { return (baseVerdict, rejection, nil) }

        guard let hit = VendorTrie.match(standardizedPath: standardized, in: trie) else {
            return (baseVerdict, rejection, nil)
        }
        if hit.isExactRoot {
            // 命中 vendor 根 —— 强制 confirm
            return (.confirm, .ok, hit.rule)
        } else {
            // 命中 vendor 子目录 —— 用 baseVerdict（safe / confirm）
            return (baseVerdict, rejection, hit.rule)
        }
    }
}
