import Foundation

/// v1.2 P2-6：大文件清单导出（JSON / TSV）。
///
/// 设计要点：
/// 1. **纯函数 + 静态方法**——导出器本身无状态，所有输入显式传入；便于单测。
/// 2. **不依赖 NSSavePanel**——保存窗在 UI 层调，Exporter 只生产 bytes / 字符串。
/// 3. **TSV 字段统一转义**——制表符、换行、回车都替换成空格；防止破坏列。
/// 4. **JSON 用 ISO8601 + sortedKeys + prettyPrinted**——给人看友好，diff 友好。
public enum Exporter {

    /// 一行可导出记录。源头是 LargeFileItem，但解耦成 plain DTO，方便日后改清单结构。
    public struct Row: Sendable, Equatable {
        public let path: String
        public let bytes: Int64
        public let modificationDate: Date?
        public let kind: String

        public init(path: String, bytes: Int64, modificationDate: Date?, kind: String) {
            self.path = path
            self.bytes = bytes
            self.modificationDate = modificationDate
            self.kind = kind
        }
    }

    // MARK: - JSON

    /// 输出 UTF-8 JSON Data。失败时返回空 Data（理论上不会失败，因为字段类型都安全）。
    public static func toJSON(_ rows: [Row]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        struct Wire: Encodable {
            let path: String
            let bytes: Int64
            let modificationDate: Date?
            let kind: String
        }
        let wire = rows.map { Wire(path: $0.path, bytes: $0.bytes, modificationDate: $0.modificationDate, kind: $0.kind) }
        return (try? encoder.encode(wire)) ?? Data()
    }

    // MARK: - TSV

    /// 输出 TSV 字符串。
    /// 表头：path / bytes / modificationDate (ISO8601) / kind。
    /// 字段内的 tab/换行被替换为空格，避免破列。
    public static func toTSV(_ rows: [Row]) -> String {
        let header = ["path", "bytes", "modificationDate", "kind"].joined(separator: "\t")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let body = rows.map { r -> String in
            let dateStr = r.modificationDate.map { iso.string(from: $0) } ?? ""
            return [
                escapeTSV(r.path),
                String(r.bytes),
                escapeTSV(dateStr),
                escapeTSV(r.kind),
            ].joined(separator: "\t")
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    /// TSV 字段转义：制表符/换行/回车 → 空格。
    public static func escapeTSV(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\t", with: " ")
        out = out.replacingOccurrences(of: "\r\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\r", with: " ")
        return out
    }
}

// MARK: - 便捷桥接

public extension Exporter.Row {
    /// 从 LargeFileItem 转出口 Row。
    init(_ item: LargeFileItem) {
        self.init(
            path: item.path,
            bytes: item.bytes,
            modificationDate: item.modificationDate,
            kind: item.kind.rawValue
        )
    }
}
