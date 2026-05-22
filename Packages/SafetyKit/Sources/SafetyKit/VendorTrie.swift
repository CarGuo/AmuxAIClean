import Foundation

/// Vendor 路径前缀树节点。
///
/// 设计说明（PITFALLS §5.9 / 性能优化）：
/// - 朴素 evaluate 是 O(vendors × prefixes_per_vendor) 字符串前缀匹配，
///   每次还要对 prefix 做一次 `URL.standardizedFileURL.path`（系统调用级别开销）。
/// - 把所有 vendor 的 absolutePathPrefixes 预先 standardize + 拆段，
///   建一棵以 "/" 段为边、命中节点挂 VendorRule 的前缀树。
/// - 评估时按路径段下行，时间复杂度降到 O(路径深度)，且零字符串比较。
public final class VendorTrieNode: @unchecked Sendable {
    public var children: [String: VendorTrieNode] = [:]
    public var rule: VendorRule? = nil

    public init() {}
}

/// Trie 包装。`Sendable` 只在"建树后只读使用"的契约下成立 —— 不要在并发评估时变更。
public struct VendorTrie: @unchecked Sendable {
    public let root: VendorTrieNode

    public init(root: VendorTrieNode) {
        self.root = root
    }

    /// 把每条 vendor 的 `absolutePathPrefixes` 拆段插入 trie。
    /// 同一节点已有 rule 时不覆盖（保留**最先插入**的，等价于朴素遍历的"先命中即返回"语义）。
    public static func build(vendors: [VendorRule], home: String) -> VendorTrieNode {
        let root = VendorTrieNode()
        for rule in vendors {
            for raw in rule.absolutePathPrefixes(home: home) {
                let std = URL(fileURLWithPath: raw).standardizedFileURL.path
                let segments = Self.segments(of: std)
                guard !segments.isEmpty else { continue }
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
                if node.rule == nil {
                    node.rule = rule
                }
            }
        }
        return root
    }

    /// 沿 standardizedPath 的段下行，返回第一个挂 rule 的节点对应的命中结果。
    /// - `isExactRoot == true`：路径恰好等于 vendor 根
    /// - `isExactRoot == false`：路径是 vendor 根的子目录
    public static func match(standardizedPath: String, in trie: VendorTrieNode)
    -> (rule: VendorRule, isExactRoot: Bool)?
    {
        let segments = Self.segments(of: standardizedPath)
        var node = trie
        var depth = 0
        for seg in segments {
            guard let next = node.children[seg] else { return nil }
            node = next
            depth += 1
            if let rule = node.rule {
                let isExactRoot = (depth == segments.count)
                return (rule, isExactRoot)
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
