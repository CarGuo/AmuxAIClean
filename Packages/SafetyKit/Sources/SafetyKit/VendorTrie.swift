import Foundation

/// Vendor 路径前缀树节点。
///
/// 设计说明（PITFALLS §5.9 / 性能优化）：
/// - 朴素 evaluate 是 O(vendors × prefixes_per_vendor) 字符串前缀匹配，
///   每次还要对 prefix 做一次 `URL.standardizedFileURL.path`（系统调用级别开销）。
/// - 把所有 vendor 的 absolutePathPrefixes 预先 standardize + 拆段，
///   建一棵以 "/" 段为边、命中节点挂 VendorRule 的前缀树。
/// - 评估时按路径段下行，时间复杂度降到 O(路径深度)，且零字符串比较。
///
/// DEV_ARTIFACTS_RULES §2 path 级规则扩展：
/// - 节点除了挂 `VendorRule`（vendor 元数据），还可挂 `PathRule`（path 级 verdict 覆盖）。
/// - vendor 根节点（来自 `appSupportSubdir`/`cachesPath`）只挂 `rule`，不挂 `pathOverride`，
///   语义保持"vendor 根 confirm / 子目录继承 base verdict"。
/// - path 级节点（来自 `paths:` 列表）同时挂 `rule` + `pathOverride`，
///   命中后由 `pathOverride.verdict` 而非默认 confirm 决定 verdict，
///   且**继承到所有子目录**（如 `~/Library/Developer/Xcode/DerivedData` safe 后，
///   其下任何 `MyApp-abc123/Build/...` 都直接 safe）。
///
/// **生命周期契约（v1.5.7 显式化）**：
/// 1. **Build 阶段**：仅 `VendorTrie.build(vendors:)`（或其测试副本）可写入 `children` /
///    `rule` / `pathOverride` / `globRules`。建树是单线程串行的。
/// 2. **Read 阶段**：build 返回后，整棵 trie 通过 `@unchecked Sendable` 暴露给多个并发
///    评估线程（ScanCoordinator + SafetyEvaluator 等）。**Read 阶段任何写入都是
///    未定义行为（data race）**。
/// 3. 字段保持 `var` 是为了让建树代码可以增量挂接子节点；如果未来 Swift 引入 readonly
///    或 frozen 关键字，应替换为更强的编译期约束。当前以 doc + 单元测试守护契约。
public final class VendorTrieNode: @unchecked Sendable {
    /// **build-only mutable**；read 阶段视为 immutable。
    public var children: [String: VendorTrieNode] = [:]
    /// **build-only mutable**；read 阶段视为 immutable。
    public var rule: VendorRule? = nil
    /// **build-only mutable**；path 级 verdict 覆盖（DEV_ARTIFACTS_RULES §2.x 的 path 字段直接对应）。
    /// 命中此节点或其子节点时，verdict 由此覆盖决定，而非走默认 confirm。
    public var pathOverride: PathRule? = nil

    /// **build-only mutable**；仅在**根节点**有效：含 glob 元字符（`*` / `?`）的 path 规则副本。
    /// 这些规则不能插入 trie（trie 节点路径段是字面量），评估时退化为线性扫描。
    /// 数量级 < 50 条，性能可接受；详见 [PathGlob](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/PathGlob.swift)。
    public var globRules: [GlobEntry] = []

    public init() {}
}

/// 一条 glob path-rule 的展开形态：保留原始 rule + pathRule，
/// 同时缓存"已 expand `~` 后的绝对 pattern"避免每次评估重复展开。
public struct GlobEntry: Sendable {
    public let rule: VendorRule
    public let pathRule: PathRule
    public let absolutePattern: String

    public init(rule: VendorRule, pathRule: PathRule, absolutePattern: String) {
        self.rule = rule
        self.pathRule = pathRule
        self.absolutePattern = absolutePattern
    }
}

/// Trie 包装。`Sendable` 只在"建树后只读使用"的契约下成立 —— 不要在并发评估时变更。
public struct VendorTrie: @unchecked Sendable {
    public let root: VendorTrieNode

    public init(root: VendorTrieNode) {
        self.root = root
    }

    /// 把每条 vendor 的 `absolutePathPrefixes` + `absolutePathRules` 拆段插入 trie。
    /// 同一节点已有 rule 时不覆盖（保留**最先插入**的，等价于朴素遍历的"先命中即返回"语义）。
    /// path 级 override 也遵循相同的"先到先得"规则。
    ///
    /// glob path-rule（含 `*`/`?`）单独走 `root.globRules` 线性扫描分支，
    /// 不污染 trie 字面量索引。
    public static func build(vendors: [VendorRule], home: String) -> VendorTrieNode {
        let root = VendorTrieNode()
        for rule in vendors {
            // 1) 默认 vendor 根（appSupportSubdir / cachesPath）
            for raw in rule.absolutePathPrefixes(home: home) {
                let std = URL(fileURLWithPath: raw).standardizedFileURL.path
                let segments = Self.segments(of: std)
                guard !segments.isEmpty else { continue }
                let node = ensurePath(segments: segments, from: root)
                if node.rule == nil { node.rule = rule }
            }
            // 2) path 级 override（paths: 列表项）
            for (raw, pathRule) in rule.absolutePathRules(home: home) {
                if PathGlob.isGlob(raw) {
                    // glob 规则单独走线性扫描，不进 trie
                    root.globRules.append(GlobEntry(rule: rule,
                                                   pathRule: pathRule,
                                                   absolutePattern: raw))
                    continue
                }
                let std = URL(fileURLWithPath: raw).standardizedFileURL.path
                let segments = Self.segments(of: std)
                guard !segments.isEmpty else { continue }
                let node = ensurePath(segments: segments, from: root)
                if node.rule == nil { node.rule = rule }
                if node.pathOverride == nil { node.pathOverride = pathRule }
            }
        }
        return root
    }

    /// 沿 `segments` 在 trie 中创建/复用路径，返回叶子节点。
    private static func ensurePath(segments: [String], from root: VendorTrieNode)
    -> VendorTrieNode {
        var node = root
        for seg in segments {
            if let next = node.children[seg] {
                node = next
            } else {
                let next = VendorTrieNode()
                node.children[seg] = next
                node = next
            }
        }
        return node
    }

    /// 沿 standardizedPath 的段下行，返回第一个挂 rule 的节点对应的命中结果。
    /// - `isExactRoot == true`：路径恰好等于 vendor 根（或 path-rule 根）
    /// - `isExactRoot == false`：路径是 vendor 根（或 path-rule 根）的子目录
    /// - `pathOverride`：若命中节点挂着 path 级 verdict 覆盖，会一并返回；
    ///   path 级 override 沿子树继承（即在祖先节点声明的 override 会传递到所有后代）。
    ///
    /// trie miss 时回退到 [globRules](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L30-L30) 线性扫描，
    /// 用 [PathGlob.matchPrefix](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/PathGlob.swift#L42-L48)
    /// 判断 path 是否落在某条 glob pattern 的前缀（含完整匹配）。
    public static func match(standardizedPath: String, in trie: VendorTrieNode)
    -> (rule: VendorRule, isExactRoot: Bool, pathOverride: PathRule?)?
    {
        let segments = Self.segments(of: standardizedPath)
        var node = trie
        var depth = 0
        // 跟踪沿途遇到的最深 path-override（祖先 override 也对子节点生效）。
        var inheritedOverride: PathRule? = nil
        var firstRuleHit: (VendorRule, Int)? = nil
        for seg in segments {
            guard let next = node.children[seg] else { break }
            node = next
            depth += 1
            if let ovr = node.pathOverride {
                inheritedOverride = ovr
            }
            if firstRuleHit == nil, let rule = node.rule {
                firstRuleHit = (rule, depth)
            }
        }
        if let (rule, hitDepth) = firstRuleHit {
            let isExactRoot = (hitDepth == segments.count)
            // 即便 trie 命中了 vendor 根，也再看一眼 globRules：
            // 如果某条 glob 也命中（且更具体地附了 pathOverride），则用 glob 的 override 覆盖
            // vendor 根的默认 confirm。这是 §2.2 / §2.3 "Google 根 + AndroidStudio<version>* glob"
            // 这类"vendor 根 + 通配 path-rule"组合能正确生效的关键。
            //
            // 正确性修复（review 高危 #1）：globHit 命中时，必须把 rule **一并**替换为
            // globHit 的 rule，不能只换 override。否则当 trie 命中 vendor A 而 glob 属于
            // vendor B 时，返回 `(rule: A, override: B.pathOverride)` 元数据来源不一致 ——
            // UI 显示的 vendorName 会是 A，但 verdict/reason/recipe 来自 B，造成误导。
            // 取 globHit.rule 与 isExactRoot=globHit.isExactRoot 让 (rule, override) 同源。
            if inheritedOverride == nil,
               let globHit = matchGlob(standardizedPath: standardizedPath, in: trie) {
                return (globHit.rule, globHit.isExactRoot, globHit.pathOverride)
            }
            return (rule, isExactRoot, inheritedOverride)
        }
        // trie miss：扫描 globRules
        return matchGlob(standardizedPath: standardizedPath, in: trie)
    }

    /// 把 standardizedPath 喂给 root.globRules 做 fnmatch 前缀检查。
    /// 多条命中时取**最先声明**的（与 trie 的"先到先得"语义一致）。
    static func matchGlob(standardizedPath: String, in root: VendorTrieNode)
    -> (rule: VendorRule, isExactRoot: Bool, pathOverride: PathRule?)?
    {
        for entry in root.globRules {
            if PathGlob.match(pattern: entry.absolutePattern, path: standardizedPath) {
                return (entry.rule, true, entry.pathRule)
            }
            if PathGlob.matchPrefix(pattern: entry.absolutePattern, path: standardizedPath) {
                return (entry.rule, false, entry.pathRule)
            }
        }
        return nil
    }

    /// 把绝对路径按 "/" 切成非空段序列。
    /// 例：`/Users/foo/Library` → `["Users", "foo", "Library"]`
    @inline(__always)
    private static func segments(of absolutePath: String) -> [String] {
        absolutePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
