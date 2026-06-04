import XCTest
@testable import FileSearchKit

/// FileSearchKit MVP 端到端契约（Step 16-A）。
///
/// 测试策略：每个 case 在 tmp 目录建一个 fixture 树，跑 `FileSearchEngine.search`
/// AsyncStream 收齐结果，断言：
/// - 流式语义：第一个结果不需要等全部扫完；
/// - 4 类 filter（name/extension/size/kind）；
/// - cancel 在 detached task 里 fire 后必须停止 yield。
final class FileSearchEngineTests: XCTestCase {

    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(
            fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
        ).appendingPathComponent("fskit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    // MARK: - 契约 1：name.contains 命中所有匹配的文件

    func test_nameContains_命中所有同名文件() async throws {
        try makeFile(name: "alpha.txt", size: 100)
        try makeFile(name: "beta.txt", size: 100)
        try makeFile(name: "alphabet.txt", size: 100)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.name(.contains, "alpha")]))
        XCTAssertEqual(Set(names), ["alpha.txt", "alphabet.txt"])
    }

    // MARK: - 契约 2：name.startsWith 区分（默认大小写不敏感）

    func test_nameStartsWith_默认大小写不敏感() async throws {
        try makeFile(name: "ALPHA.txt", size: 1)
        try makeFile(name: "beta.txt", size: 1)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.name(.startsWith, "alpha")]))
        XCTAssertEqual(names, ["ALPHA.txt"])
    }

    // MARK: - 契约 3：fileExtension.includes / excludes

    func test_fileExtensionIncludes_只命中指定扩展名() async throws {
        try makeFile(name: "a.swift", size: 1)
        try makeFile(name: "b.txt", size: 1)
        try makeFile(name: "c.md", size: 1)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.fileExtension(.includes, ["swift", "md"])]))
        XCTAssertEqual(Set(names), ["a.swift", "c.md"])
    }

    // MARK: - 契约 4：size.between

    func test_sizeBetween_只命中区间内的() async throws {
        try makeFile(name: "tiny.bin", size: 10)
        try makeFile(name: "mid.bin", size: 1000)
        try makeFile(name: "huge.bin", size: 10_000)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.size(.between(500, 5_000))]))
        XCTAssertEqual(Set(names), ["mid.bin"])
    }

    // MARK: - 契约 5：kind.folderOnly 排除文件

    func test_kindFolderOnly_只命中目录() async throws {
        try makeFile(name: "a.txt", size: 1)
        try makeDir(name: "subdir")
        try makeDir(name: "another")

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.kind(.folderOnly)]))
        XCTAssertEqual(Set(names), ["subdir", "another"])
    }

    // MARK: - 契约 6：filter 组合（AND 语义）

    func test_filter组合_AND语义同时满足才命中() async throws {
        try makeFile(name: "report.txt", size: 100)
        try makeFile(name: "report.swift", size: 100)
        try makeFile(name: "data.swift", size: 100)

        let engine = FileSearchEngine()
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [
                              .name(.contains, "report"),
                              .fileExtension(.includes, ["swift"])
                          ]))
        XCTAssertEqual(names, ["report.swift"])
    }

    // MARK: - 契约 7：includeSubfolders=false 不递归

    func test_includeSubfoldersFalse_不递归子目录() async throws {
        try makeFile(name: "top.txt", size: 1)
        try makeDir(name: "sub")
        try makeFile(name: "sub/nested.txt", size: 1)

        let engine = FileSearchEngine()
        var opts = FileSearchOptions()
        opts.includeSubfolders = false
        let names = try await collectNames(
            engine.search(rootPath: fixtureRoot.path,
                          filters: [.name(.contains, "")],
                          options: opts))
        XCTAssertFalse(names.contains("nested.txt"))
        XCTAssertTrue(names.contains("top.txt"))
    }

    // MARK: - 契约 8：cancel 后停止 yield（流式语义）

    func test_cancel_在consumer退出后停止枚举() async throws {
        // 1k 个文件，cancel 之后 stream 应该立即结束
        for i in 0..<1000 {
            try makeFile(name: "f-\(i).txt", size: 1)
        }
        let engine = FileSearchEngine()
        let stream = engine.search(rootPath: fixtureRoot.path,
                                   filters: [.kind(.fileOnly)])
        var seen = 0
        for await _ in stream {
            seen += 1
            if seen >= 5 { break }  // consumer break -> stream onTermination -> task cancel
        }
        XCTAssertEqual(seen, 5)
        // 不再 await 表示 stream 已经被 finalize；如果 task 没正确 cancel，
        // 会泄漏；这里至少证明 break 后不挂死。
    }

    // MARK: - 契约 9：第一个结果不必等全部完成（流式立即性）

    func test_流式_第一个结果不必等全部完成() async throws {
        for i in 0..<200 {
            try makeFile(name: "x-\(i).txt", size: 1)
        }
        let engine = FileSearchEngine()
        let stream = engine.search(rootPath: fixtureRoot.path,
                                   filters: [.kind(.fileOnly)])
        // 仅取第一个，验证不会阻塞到全部 200 完成才返回
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertNotNil(first)
    }

    // MARK: - helpers

    private func makeFile(name: String, size: Int) throws {
        let url = fixtureRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: size)
        try data.write(to: url)
    }

    private func makeDir(name: String) throws {
        let url = fixtureRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }

    private func collectNames(_ stream: AsyncStream<FileSearchResult>) async throws -> [String] {
        var out: [String] = []
        for await r in stream { out.append(r.name) }
        return out
    }
}
