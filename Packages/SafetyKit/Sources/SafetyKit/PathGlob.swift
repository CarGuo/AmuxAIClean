import Foundation

/// 极简 glob 匹配 —— DEV_ARTIFACTS_RULES.md §2.2 / §2.3 / §2.5 等"按版本号分目录"
/// 场景的最小可行实现，零外部依赖。
///
/// 设计参考（业界共识，[BleachBit CleanerML](https://docs.bleachbit.org/cml/cleanerml.html)
/// + Python `fnmatch` + macOS 圈手工命令）：
/// - `*` 匹配同一级目录段内 0..N 个非 `/` 字符（**不跨 `/`**）
/// - `?` 匹配同一级目录段内**恰好 1 个**非 `/` 字符
/// - 其它字符按字面量比较
///
/// **不**支持 `**` / `[...]` / 大括号展开 —— 这些在 §2.x 全部规则中都不需要，
/// 上 glob 也是为了避免引入复杂度（恶意作者可能用 `**` 吞掉整个 home）。
///
/// 安全约束：本类型**只回答 yes/no 是否匹配**，不做文件系统枚举。
/// VendorTrie 接入时，匹配通过后仍走 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
/// 的 hardForbid 红线检查，glob 永远无法绕过 §2.7 黄金禁区。
public enum PathGlob {

    /// `pattern` 是否含 glob 元字符。无元字符时调用方应走更高效的 `hasPrefix` 比较。
    @inlinable
    public static func isGlob(_ pattern: String) -> Bool {
        for ch in pattern.utf8 where ch == 0x2A /* * */ || ch == 0x3F /* ? */ {
            return true
        }
        return false
    }

    /// 严格 fnmatch：`pattern` 必须**完整**匹配 `path` 的全部字符（APFS 默认大小写不敏感）。
    /// 用于"path 等同于 vendor 根的精确匹配"语义（VendorTrie isExactRoot 场景）。
    public static func match(pattern: String, path: String, caseSensitive: Bool = false) -> Bool {
        matchUTF8(Array((caseSensitive ? pattern : pattern.lowercased()).utf8),
                  Array((caseSensitive ? path : path.lowercased()).utf8))
    }

    /// 前缀 fnmatch：`pattern` 是否匹配 `path` 的某个前缀，且分界点必须落在 `/` 上
    /// 或 `path` 末尾。用于"path 是 vendor 子路径"语义（继承 verdict）。
    ///
    /// 例：`pattern="~/Library/Caches/JetBrains/*"`，对
    /// `path="~/Library/Caches/JetBrains/IntelliJIdea2024.3/log.txt"`，
    /// 截 path 的前 5 段（与 pattern 段数相同）= `~/Library/Caches/JetBrains/IntelliJIdea2024.3`，
    /// 完整 fnmatch 通过，返回 true。
    public static func matchPrefix(pattern: String, path: String, caseSensitive: Bool = false) -> Bool {
        if pattern.contains("**") {
            let pBytes = Array((caseSensitive ? pattern : pattern.lowercased()).utf8)
            let tBytes = Array((caseSensitive ? path : path.lowercased()).utf8)
            if matchUTF8(pBytes, tBytes) {
                return true
            }
            for i in 1..<tBytes.count where tBytes[i] == 0x2F /* / */ {
                if matchUTF8(pBytes, Array(tBytes[..<i])) {
                    return true
                }
            }
            return false
        }
        let segNeeded = countSegments(pattern)
        let prefix = takeSegments(path, count: segNeeded)
        return match(pattern: pattern, path: prefix, caseSensitive: caseSensitive)
    }

    /// 数路径里的非空段个数。
    /// - 绝对路径 `/a/b/c` → 3
    /// - 相对路径 `a/b/c`  → 3
    /// - 单段 `a` 或 `/a`  → 1
    /// - 空串             → 0
    @usableFromInline
    static func countSegments(_ s: String) -> Int {
        var n = 0
        var inSeg = false
        for b in s.utf8 {
            if b == 0x2F /* / */ {
                inSeg = false
            } else if !inSeg {
                inSeg = true
                n += 1
            }
        }
        return n
    }

    // MARK: - 内部实现

    /// 截取 path 的前 N 个 `/`-分隔段。例：takeSegments("a/b/c/d", 2) => "a/b"。
    /// 段数不足时返回原 path。
    static func takeSegments(_ path: String, count: Int) -> String {
        if count <= 0 { return "" }
        var seen = 0
        var idx = path.startIndex
        // path 第一段开头允许是 `/`（绝对路径），把根 `/` 也算进段 1
        if path.first == "/" { idx = path.index(after: idx) }
        while idx < path.endIndex {
            if path[idx] == "/" {
                seen += 1
                if seen == count { return String(path[..<idx]) }
            }
            idx = path.index(after: idx)
        }
        return path
    }

    /// 工作在 utf8 字节流的 glob 匹配：
    /// - 单个 `*` 仅匹配同段内 0..N 个非 `/` 字节（遇 `/` 停止）
    /// - 连续 `**` 支持跨 `/` 匹配 0..N 个路径段（含 `/**/` 匹配 0 个中间段）
    @usableFromInline
    static func matchUTF8(_ pattern: [UInt8], _ path: [UInt8]) -> Bool {
        var memo: [Int: Bool] = [:]
        let stride = path.count + 1

        func dfs(_ pi: Int, _ ti: Int) -> Bool {
            let key = pi * stride + ti
            if let cached = memo[key] { return cached }

            let result: Bool
            if pi == pattern.count {
                result = (ti == path.count)
            } else if pattern[pi] == 0x2A /* * */ {
                var nextPi = pi + 1
                while nextPi < pattern.count && pattern[nextPi] == 0x2A {
                    nextPi += 1
                }
                let isGlobstar = (nextPi - pi) >= 2
                if isGlobstar {
                    // 若形如 `/**/`（或开头的 `**/`），允许匹配 0 个中间段
                    if nextPi < pattern.count && pattern[nextPi] == 0x2F /* / */
                        && (pi == 0 || pattern[pi - 1] == 0x2F) {
                        if dfs(nextPi + 1, ti) {
                            memo[key] = true
                            return true
                        }
                    }
                    // `**` 匹配 0..N 个任意字符（可跨 `/`）
                    var matched = false
                    var k = ti
                    while k <= path.count {
                        if dfs(nextPi, k) {
                            matched = true
                            break
                        }
                        k += 1
                    }
                    result = matched
                } else {
                    // 单个 `*`：匹配 0..N 个非 `/` 字符
                    var matched = false
                    var k = ti
                    while true {
                        if dfs(nextPi, k) {
                            matched = true
                            break
                        }
                        if k == path.count || path[k] == 0x2F /* / */ {
                            break
                        }
                        k += 1
                    }
                    result = matched
                }
            } else if pattern[pi] == 0x3F /* ? */ {
                if ti < path.count && path[ti] != 0x2F /* / */ {
                    result = dfs(pi + 1, ti + 1)
                } else {
                    result = false
                }
            } else {
                if ti < path.count && pattern[pi] == path[ti] {
                    result = dfs(pi + 1, ti + 1)
                } else {
                    result = false
                }
            }

            memo[key] = result
            return result
        }

        return dfs(0, 0)
    }
}
