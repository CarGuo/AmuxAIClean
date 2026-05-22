import Foundation

/// Golden snapshot 中的一行记录。
///
/// 字段：
/// - `path`: 文件相对路径或标识，作为稳定排序键。
/// - `bytes`: 文件物理大小。
/// - `verdict`: 判定结果（如 "junk" / "keep" / "review"），由调用方约定取值集合。
/// - `vendor`: 归属厂商或分类标签（如 "Adobe" / "JetBrains" / "system"）。
public struct GoldenRow: Codable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let verdict: String
    public let vendor: String

    public init(path: String, bytes: Int64, verdict: String, vendor: String) {
        self.path = path
        self.bytes = bytes
        self.verdict = verdict
        self.vendor = vendor
    }
}

/// `GoldenSnapshot` 的比对结果。
public enum GoldenSnapshotResult: Sendable, Equatable {
    /// Golden 文件不存在；当前内容已被写入到给定 URL，下次运行将进入严格比对。
    case created(URL)
    /// Golden 文件存在，且与当前内容**逐字节一致**。
    case matched
    /// Golden 文件存在但内容不一致；附带统一 diff 文本。
    case mismatch(diff: String)
}

/// Golden 快照工具：
/// - 把一组 `GoldenRow` 序列化为**稳定的**纯文本（顺序固定、字段顺序固定、行尾固定）；
/// - 缺失则写入 golden 文件（首跑），存在则严格 diff 比对。
///
/// 之所以不用 JSONEncoder：
/// - JSON 字段顺序在不同平台/版本可能不稳定；
/// - 文本 diff 在 PR review 时人眼可读性远好于 JSON。
public enum GoldenSnapshot {
    /// 列名行（用于 self-describing），保持与 `serialize` 一致。
    public static let header = "path\tbytes\tverdict\tvendor"

    /// 把 rows 序列化为稳定文本。
    ///
    /// 规则：
    /// 1. 行序：先按 `path` 字典序，再按 `vendor`、`verdict`、`bytes`（防止 path 重复时仍不稳定）。
    /// 2. 字段顺序：path \t bytes \t verdict \t vendor。
    /// 3. 行尾固定 "\n"，文件末尾保留一个空行（POSIX 友好）。
    public static func serialize(_ rows: [GoldenRow]) -> String {
        let sorted = rows.sorted { lhs, rhs in
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.vendor != rhs.vendor { return lhs.vendor < rhs.vendor }
            if lhs.verdict != rhs.verdict { return lhs.verdict < rhs.verdict }
            return lhs.bytes < rhs.bytes
        }
        var lines: [String] = [header]
        for row in sorted {
            lines.append("\(row.path)\t\(row.bytes)\t\(row.verdict)\t\(row.vendor)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 把当前内容与 `goldenURL` 比对。
    ///
    /// - 若文件不存在：把当前内容写入并返回 `.created`；
    /// - 若文件存在且**严格相等**：返回 `.matched`；
    /// - 若文件存在但不等：返回 `.mismatch(diff:)`，diff 为简单的逐行差异文本。
    @discardableResult
    public static func compare(
        rows: [GoldenRow],
        goldenURL: URL
    ) throws -> GoldenSnapshotResult {
        let current = serialize(rows)
        let fm = FileManager.default

        if !fm.fileExists(atPath: goldenURL.path) {
            try fm.createDirectory(
                at: goldenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try current.data(using: .utf8)!.write(to: goldenURL, options: .atomic)
            return .created(goldenURL)
        }

        let expectedData = try Data(contentsOf: goldenURL)
        let expected = String(data: expectedData, encoding: .utf8) ?? ""
        if expected == current {
            return .matched
        }
        return .mismatch(diff: lineDiff(expected: expected, actual: current))
    }

    /// 极简逐行 diff（没引入 LCS——足够 PR review 时定位问题；不追求最小编辑距离）。
    static func lineDiff(expected: String, actual: String) -> String {
        let exp = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let act = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLen = max(exp.count, act.count)
        var out: [String] = ["--- expected", "+++ actual"]
        for i in 0..<maxLen {
            let e: String? = i < exp.count ? String(exp[i]) : nil
            let a: String? = i < act.count ? String(act[i]) : nil
            if e == a { continue }
            if let e { out.append("- \(e)") }
            if let a { out.append("+ \(a)") }
        }
        return out.joined(separator: "\n")
    }
}
