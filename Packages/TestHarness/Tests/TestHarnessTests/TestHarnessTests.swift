import XCTest
@testable import TestHarness

final class TestHarnessTests: XCTestCase {

    // MARK: - FixtureFS

    /// 验证 `FixtureFS` 能创建一个隔离根，并按相对路径正确落盘文件 + 报告文件大小。
    func test_fixtureFS_createsIsolatedRootAndFiles() async throws {
        let fs = try FixtureFS.create(prefix: "TH-Unit")
        defer { Task { await fs.cleanup() } }

        let root = await fs.temporaryRoot
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        try await fs.createFile("Caches/com.example/log.txt", bytes: 256)
        let exists = await fs.exists("Caches/com.example/log.txt")
        XCTAssertTrue(exists)
        let size = await fs.size("Caches/com.example/log.txt")
        XCTAssertEqual(size, 256)
    }

    /// `cleanup()` 应该把整个临时根目录递归删除，且重复调用安全。
    func test_fixtureFS_cleanupIsIdempotent() async throws {
        let fs = try FixtureFS.create()
        try await fs.createFile("a.bin", bytes: 4)
        let root = await fs.temporaryRoot

        await fs.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // 再次调用不应抛出或崩溃
        await fs.cleanup()
    }

    // MARK: - ScenarioBuilder

    /// DSL 应该按描述创建嵌套目录与指定大小文件，且 `Scenario` 释放后目录自动消失。
    func test_scenarioBuilder_buildsTreeAndAutoCleans() throws {
        var capturedRoot: URL?
        do {
            let scenario = ScenarioBuilder.build(prefix: "TH-Sc") { root in
                root.dir("Caches") { c in
                    c.file("a.log", size: 1024)
                    c.file("b.log", size: 2048)
                }
                root.dir("Logs") { l in
                    l.file("crash.bin", size: 16)
                }
            }
            capturedRoot = scenario.root

            let fm = FileManager.default
            let a = scenario.root.appendingPathComponent("Caches/a.log")
            let b = scenario.root.appendingPathComponent("Caches/b.log")
            let crash = scenario.root.appendingPathComponent("Logs/crash.bin")

            XCTAssertTrue(fm.fileExists(atPath: a.path))
            XCTAssertTrue(fm.fileExists(atPath: b.path))
            XCTAssertTrue(fm.fileExists(atPath: crash.path))

            let aAttr = try fm.attributesOfItem(atPath: a.path)
            let bAttr = try fm.attributesOfItem(atPath: b.path)
            XCTAssertEqual((aAttr[.size] as? NSNumber)?.intValue, 1024)
            XCTAssertEqual((bAttr[.size] as? NSNumber)?.intValue, 2048)
        }
        // scenario 已离开作用域，deinit 应已删除目录
        if let r = capturedRoot {
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.path),
                           "Scenario 释放后应自动清理临时目录")
        } else {
            XCTFail("未捕获到 root")
        }
    }

    /// DSL 也应支持 `contents:` 形式，从而能写入任意字节流。
    func test_scenarioBuilder_writesArbitraryContents() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let scenario = ScenarioBuilder.build { root in
            root.file("blob.bin", contents: payload)
        }
        let url = scenario.root.appendingPathComponent("blob.bin")
        let read = try Data(contentsOf: url)
        XCTAssertEqual(read, payload)
    }

    // MARK: - GoldenSnapshot

    /// 序列化必须**稳定**：行序按 `path` 排序，输入顺序变化不影响输出。
    func test_goldenSnapshot_serializeIsOrderStable() {
        let rowsA: [GoldenRow] = [
            .init(path: "/B/x", bytes: 1, verdict: "junk", vendor: "Adobe"),
            .init(path: "/A/y", bytes: 2, verdict: "keep", vendor: "system")
        ]
        let rowsB: [GoldenRow] = [
            .init(path: "/A/y", bytes: 2, verdict: "keep", vendor: "system"),
            .init(path: "/B/x", bytes: 1, verdict: "junk", vendor: "Adobe")
        ]
        let a = GoldenSnapshot.serialize(rowsA)
        let b = GoldenSnapshot.serialize(rowsB)
        XCTAssertEqual(a, b)
        // 头部 + 2 行 + 末尾换行
        let lines = a.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first.map(String.init), GoldenSnapshot.header)
        XCTAssertTrue(a.hasSuffix("\n"))
        // /A/y 应排在 /B/x 之前
        let idxA = a.range(of: "/A/y")!.lowerBound
        let idxB = a.range(of: "/B/x")!.lowerBound
        XCTAssertLessThan(idxA, idxB)
    }

    /// 缺失则写入；再次比对应 matched。
    func test_goldenSnapshot_createsThenMatches() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let golden = tmp.appendingPathComponent("simple.golden")
        let rows: [GoldenRow] = [
            .init(path: "/Caches/a.log", bytes: 1024, verdict: "junk", vendor: "Adobe"),
            .init(path: "/Caches/b.log", bytes: 2048, verdict: "junk", vendor: "Adobe")
        ]

        let first = try GoldenSnapshot.compare(rows: rows, goldenURL: golden)
        guard case .created(let writtenURL) = first else {
            return XCTFail("第一次应返回 .created，但得到 \(first)")
        }
        XCTAssertEqual(writtenURL.standardizedFileURL, golden.standardizedFileURL)

        let second = try GoldenSnapshot.compare(rows: rows, goldenURL: golden)
        XCTAssertEqual(second, .matched)
    }

    /// 内容不一致时应返回 `.mismatch` 并带可读 diff。
    func test_goldenSnapshot_detectsMismatch() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let golden = tmp.appendingPathComponent("mismatch.golden")
        let baseline: [GoldenRow] = [
            .init(path: "/x", bytes: 10, verdict: "junk", vendor: "v1")
        ]
        // 第一次写入 baseline
        _ = try GoldenSnapshot.compare(rows: baseline, goldenURL: golden)

        let drifted: [GoldenRow] = [
            .init(path: "/x", bytes: 11, verdict: "junk", vendor: "v1")  // bytes 由 10 -> 11
        ]
        let result = try GoldenSnapshot.compare(rows: drifted, goldenURL: golden)

        switch result {
        case .mismatch(let diff):
            XCTAssertTrue(diff.contains("--- expected"))
            XCTAssertTrue(diff.contains("+++ actual"))
            XCTAssertTrue(diff.contains("/x\t10"))
            XCTAssertTrue(diff.contains("/x\t11"))
        default:
            XCTFail("应返回 .mismatch，但得到 \(result)")
        }
    }

    /// `GoldenRow` 自身是 Codable，能通过 JSON 往返而不丢字段。
    func test_goldenRow_isCodableRoundTrip() throws {
        let row = GoldenRow(path: "/p", bytes: 42, verdict: "review", vendor: "JetBrains")
        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(GoldenRow.self, from: data)
        XCTAssertEqual(row, decoded)
    }
}
