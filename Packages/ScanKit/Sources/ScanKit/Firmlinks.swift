import Foundation

/// macOS firmlinks 工具。
///
/// firmlinks 是 macOS Catalina+ 系统卷↔数据卷之间的"双向虫洞"。
/// 朴素遍历会重复计数或漏计；详见 [PITFALLS §2.1](../../../../PITFALLS.md)。
///
/// 系统的 firmlinks 列表通常位于 `/usr/share/firmlinks`，每行格式：
///   `<source path>\t<target on data volume>`
public enum Firmlinks {
    public static func load(from path: String = "/usr/share/firmlinks") -> [(source: String, target: String)] {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var result: [(String, String)] = []
        for line in data.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            result.append((String(parts[0]).trimmingCharacters(in: .whitespaces),
                           String(parts[1]).trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// 推荐用作"全盘扫描"的根，避免 firmlinks 双向计数。
    public static let recommendedDataVolumeRoot = URL(fileURLWithPath: "/System/Volumes/Data")
}
