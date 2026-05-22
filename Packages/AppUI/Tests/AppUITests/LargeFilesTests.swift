import XCTest
@testable import AppUI

/// v1.0 T4 大文件视图后端逻辑单测。
///
/// 覆盖点：
/// - 扫描期阈值过滤 —— 小于 `largeFileMinBytes` 的文件不进结果
/// - 视图期阈值二次过滤 —— `minSizeMB` ≥ 扫描期阈值时返回正确子集
/// - 排序键 —— size↓ / size↑ / mtime↓ / mtime↑ 四档
/// - Top N 截断 —— `limit` 生效，且优先保留排序后最前的 N 条
/// - 默认参数 0 不收集大文件 —— 普通扫描不应额外占内存
/// - largeFiles 工厂返回的 ScanCategory 字段正确
@MainActor
final class LargeFilesTests: XCTestCase {

    // MARK: - Fixture

    /// 构造 4 个文件大小不同的 fixture：
    ///   tiny.bin   = 1 KB   （远小于阈值）
    ///   small.mov  = 200 KB （小于阈值）
    ///   medium.iso = 1.5 MB （略大于 1MB 阈值）
    ///   large.mp4  = 3 MB   （明显大于阈值）
    /// 此外把 mtime 主动错开（每个文件 setattr）以验证 mtime 排序。
    private func makeFixture() throws -> URL {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "GSYCleanLargeFiles-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let layout: [(String, Int, TimeInterval)] = [
            ("tiny.bin",    1 * 1024,            -3600 * 24 * 30), // 30 天前
            ("small.mov",   200 * 1024,          -3600 * 24 * 7),  // 7 天前
            ("medium.iso",  1_500 * 1024,        -3600 * 24),      // 1 天前
            ("large.mp4",   3 * 1024 * 1024,     -60)              // 1 分钟前
        ]
        let now = Date()
        for (name, size, dt) in layout {
            let url = root.appendingPathComponent(name)
            try Data(repeating: 0xAB, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(dt)],
                                 ofItemAtPath: url.path)
        }
        return root
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func waitFinished(_ coord: ScanCoordinator, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !coord.snapshot.isFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func makeCategory(rootPath: String) -> ScanCategory {
        ScanCategory(
            id: "test.large",
            title: "test",
            subtitle: "",
            rootPath: rootPath,
            defaultVerdict: .confirm,
            kind: .largeFiles
        )
    }

    // MARK: - 工厂

    func test_largeFiles工厂_字段符合v1拍板() {
        let cat = ScanCategory.largeFiles(home: "/Users/test")
        XCTAssertEqual(cat.kind, .largeFiles)
        XCTAssertEqual(cat.id, "largefiles.home")
        XCTAssertEqual(cat.rootPath, "/Users/test")
        XCTAssertEqual(cat.defaultVerdict, .confirm,
                       "大文件入口默认 verdict 不能是 .safe，避免被自动勾选")
    }

    // MARK: - 阈值

    func test_默认scan不传largeFileMinBytes时不收集大文件() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path))
        await waitFinished(coord)
        XCTAssertEqual(coord.largeFileCollectedCount, 0,
                       "未传 largeFileMinBytes 时不应填充 largeFileLeaves")
        XCTAssertEqual(coord.largeFiles(minSizeMB: 1, sortKey: .sizeDesc).count, 0)
    }

    func test_扫描期阈值1MB_只收集ge1MB的两个文件() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path),
                   largeFileMinBytes: 1 * 1024 * 1024)
        await waitFinished(coord)
        // medium.iso (1.5MB) + large.mp4 (3MB) 两个
        XCTAssertEqual(coord.largeFileCollectedCount, 2)
        let items = coord.largeFiles(minSizeMB: 1, sortKey: .sizeDesc)
        let names = items.map(\.title).sorted()
        XCTAssertEqual(names, ["large.mp4", "medium.iso"].sorted())
    }

    func test_视图期阈值上调_可以二次过滤() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        // 扫描期阈值很低（1KB），应收集 4 个
        coord.scan(category: makeCategory(rootPath: root.path),
                   largeFileMinBytes: 1024)
        await waitFinished(coord)
        XCTAssertEqual(coord.largeFileCollectedCount, 4)
        // 视图期阈值 2MB，期望只剩 large.mp4 (3MB)
        let items = coord.largeFiles(minSizeMB: 2, sortKey: .sizeDesc)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "large.mp4")
    }

    // MARK: - 排序

    func test_sizeDesc_最大的在前() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path), largeFileMinBytes: 1)
        await waitFinished(coord)
        let items = coord.largeFiles(minSizeMB: 0, sortKey: .sizeDesc)
        XCTAssertEqual(items.map(\.title), ["large.mp4", "medium.iso", "small.mov", "tiny.bin"])
    }

    func test_sizeAsc_最小的在前() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path), largeFileMinBytes: 1)
        await waitFinished(coord)
        let items = coord.largeFiles(minSizeMB: 0, sortKey: .sizeAsc)
        XCTAssertEqual(items.map(\.title), ["tiny.bin", "small.mov", "medium.iso", "large.mp4"])
    }

    func test_mtimeDesc_最近修改的在前() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path), largeFileMinBytes: 1)
        await waitFinished(coord)
        let items = coord.largeFiles(minSizeMB: 0, sortKey: .mtimeDesc)
        XCTAssertEqual(items.first?.title, "large.mp4", "1 分钟前修改的应排第一")
        XCTAssertEqual(items.last?.title, "tiny.bin", "30 天前修改的应排最后")
    }

    func test_mtimeAsc_最旧的在前() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path), largeFileMinBytes: 1)
        await waitFinished(coord)
        let items = coord.largeFiles(minSizeMB: 0, sortKey: .mtimeAsc)
        XCTAssertEqual(items.first?.title, "tiny.bin")
        XCTAssertEqual(items.last?.title, "large.mp4")
    }

    // MARK: - Top N

    func test_limit截断_保留排序后前N条() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path), largeFileMinBytes: 1)
        await waitFinished(coord)
        let items = coord.largeFiles(minSizeMB: 0, sortKey: .sizeDesc, limit: 2)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.title), ["large.mp4", "medium.iso"],
                       "Top 2 应是最大的两个")
    }

    func test_limit为0返回空数组() async throws {
        let root = try makeFixture()
        defer { cleanup(root) }
        let coord = ScanCoordinator()
        coord.scan(category: makeCategory(rootPath: root.path), largeFileMinBytes: 1)
        await waitFinished(coord)
        XCTAssertTrue(coord.largeFiles(minSizeMB: 0, sortKey: .sizeDesc, limit: 0).isEmpty)
    }

    // MARK: - sortKey toggled

    func test_sortKey_toggled_同列翻转() {
        XCTAssertEqual(LargeFileSortKey.sizeDesc.toggled(to: .size), .sizeAsc)
        XCTAssertEqual(LargeFileSortKey.sizeAsc.toggled(to: .size), .sizeDesc)
        XCTAssertEqual(LargeFileSortKey.mtimeDesc.toggled(to: .mtime), .mtimeAsc)
        XCTAssertEqual(LargeFileSortKey.mtimeAsc.toggled(to: .mtime), .mtimeDesc)
    }

    func test_sortKey_toggled_异列默认降序() {
        XCTAssertEqual(LargeFileSortKey.sizeDesc.toggled(to: .mtime), .mtimeDesc)
        XCTAssertEqual(LargeFileSortKey.mtimeAsc.toggled(to: .size), .sizeDesc)
    }

    // MARK: - LargeFileItem.fileExtension

    func test_LargeFileItem_扩展名小写() {
        let item = LargeFileItem(path: "/tmp/x.MOV", bytes: 1, modificationDate: nil)
        XCTAssertEqual(item.fileExtension, "mov")
    }

    func test_LargeFileItem_无扩展名给空串() {
        let item = LargeFileItem(path: "/tmp/Makefile", bytes: 1, modificationDate: nil)
        XCTAssertEqual(item.fileExtension, "")
    }
}
