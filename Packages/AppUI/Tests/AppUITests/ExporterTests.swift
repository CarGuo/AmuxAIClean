import XCTest
@testable import AppUI

/// v1.2 P2-6：Exporter（JSON / TSV）单测。
final class ExporterTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    private func sampleRows() -> [Exporter.Row] {
        [
            Exporter.Row(path: "/Users/me/big.mp4", bytes: 5_000_000_000, modificationDate: fixedDate, kind: "video"),
            Exporter.Row(path: "/Users/me/no-mtime.zip", bytes: 100, modificationDate: nil, kind: "archive"),
        ]
    }

    // MARK: - JSON

    func test_JSON_有效UTF8且能解析回数组() throws {
        let data = Exporter.toJSON(sampleRows())
        XCTAssertFalse(data.isEmpty)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["path"] as? String, "/Users/me/big.mp4")
        XCTAssertEqual(parsed?[0]["bytes"] as? Int64, 5_000_000_000)
        XCTAssertEqual(parsed?[0]["kind"] as? String, "video")
    }

    func test_JSON_缺失mtime也合法_第二条不带modificationDate键() throws {
        // JSONEncoder 默认对 nil Optional 跳过键；这里只需验证：
        // 1. 第一条带 modificationDate 字段
        // 2. 第二条不会破坏整体合法性（能解析）
        let data = Exporter.toJSON(sampleRows())
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertNotNil(parsed?[0]["modificationDate"])
        // 第二条 mtime 为 nil → 字段缺失或为 NSNull 都接受
        let second = parsed?[1]
        if let v = second?["modificationDate"] {
            XCTAssertTrue(v is NSNull, "若编码出 mtime 字段则必须是 null")
        }
    }

    func test_JSON_空清单返回空数组() throws {
        let data = Exporter.toJSON([])
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 0)
    }

    // MARK: - TSV

    func test_TSV_首行是表头() {
        let s = Exporter.toTSV(sampleRows())
        XCTAssertTrue(s.hasPrefix("path\tbytes\tmodificationDate\tkind\n"))
    }

    func test_TSV_数据行对齐表头列数() {
        let s = Exporter.toTSV(sampleRows())
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "1 表头 + 2 数据 = 3 行")
        for line in lines {
            XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false).count, 4)
        }
    }

    func test_TSV_缺失mtime为空字段不破坏列数() {
        let s = Exporter.toTSV(sampleRows())
        // 第二条数据 mtime 为 nil，对应字段应是空（连续两个 \t）
        XCTAssertTrue(s.contains("/Users/me/no-mtime.zip\t100\t\tarchive"))
    }

    func test_TSV_字段中的tab换行被替换为空格() {
        let row = Exporter.Row(
            path: "/Users/me/wei\trd\nname.mp4",
            bytes: 1,
            modificationDate: nil,
            kind: "video"
        )
        let s = Exporter.toTSV([row])
        // 数据行不能再含 \t / \n 之外的破坏列
        let dataLine = s.split(separator: "\n")[1]
        XCTAssertEqual(dataLine.split(separator: "\t", omittingEmptySubsequences: false).count, 4,
                       "字段内 tab/换行必须转义，否则列会破")
    }

    // MARK: - LargeFileItem 桥接

    func test_Row_from_LargeFileItem() {
        let item = LargeFileItem(path: "/tmp/x.png", bytes: 42, modificationDate: fixedDate)
        let row = Exporter.Row(item)
        XCTAssertEqual(row.path, "/tmp/x.png")
        XCTAssertEqual(row.bytes, 42)
        XCTAssertEqual(row.modificationDate, fixedDate)
        XCTAssertEqual(row.kind, "image")
    }
}
