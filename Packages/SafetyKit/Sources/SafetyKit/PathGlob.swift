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

    /// 严格 fnmatch：`pattern` 必须**完整**匹配 `path` 的全部字符。
    /// 用于"path 等同于 vendor 根的精确匹配"语义（VendorTrie isExactRoot 场景）。
    public static func match(pattern: String, path: String) -> Bool {
        matchUTF8(Array(pattern.utf8), Array(path.utf8))
    }

    /// 前缀 fnmatch：`pattern` 是否匹配 `path` 的某个前缀，且分界点必须落在 `/` 上
    /// 或 `path` 末尾。用于"path 是 vendor 子路径"语义（继承 verdict）。
    ///
    /// 例：`pattern="~/Library/Caches/JetBrains/*"`，对
    /// `path="~/Library/Caches/JetBrains/IntelliJIdea2024.3/log.txt"`，
    /// 截 path 的前 5 段（与 pattern 段数相同）= `~/Library/Caches/JetBrains/IntelliJIdea2024.3`，
    /// 完整 fnmatch 通过，返回 true。
    public static func matchPrefix(pattern: String, path: String) -> Bool {
        let segNeeded = countSegments(pattern)
        let prefix = takeSegments(path, count: segNeeded)
        return match(pattern: pattern, path: prefix)
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

    /// 经典 iterative fnmatch with backtracking，工作在 utf8 字节流。
    /// `*` 贪婪匹配同段内非 `/` 字节，遇 `/` 强制停回溯。
    @usableFromInline
    static func matchUTF8(_ pattern: [UInt8], _ path: [UInt8]) -> Bool {
        var pi = 0       // pattern 游标
        var ti = 0       // path 游标
        var starPi = -1  // 最近一个 `*` 在 pattern 中的位置
        var starTi = -1  // 当时 path 的位置（回溯起点）

        while ti < path.count {
            let tc = path[ti]
            if pi < pattern.count {
                let pc = pattern[pi]
                if pc == 0x2A /* * */ {
                    starPi = pi
                    starTi = ti
                    pi += 1
                    continue
                }
                if pc == 0x3F /* ? */ && tc != 0x2F /* / */ {
                    pi += 1; ti += 1
                    continue
                }
                if pc == tc {
                    pi += 1; ti += 1
                    continue
                }
            }
            // 字面量不匹配 —— 尝试在最近的 `*` 上多吃一个字符
            if starPi >= 0 {
                // `*` 不能跨越 `/` —— 如果当前要吃掉的字符是 `/`，回溯失败
                if path[starTi] == 0x2F { return false }
                starTi += 1
                pi = starPi + 1
                ti = starTi
                continue
            }
            return false
        }
        // path 已耗尽，pattern 剩余只能是 0..N 个 `*`
        while pi < pattern.count {
            if pattern[pi] != 0x2A { return false }
            pi += 1
        }
        return true
    }
}
