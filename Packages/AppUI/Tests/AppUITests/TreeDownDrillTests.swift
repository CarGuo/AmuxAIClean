import XCTest
@testable import AppUI

/// 测试目的：覆盖 [ScanCoordinator.directChildren](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L880)
/// 多层下钻能力——顶层 → 一级目录 → 文件叶子，每一层 hasChildren / isDirectory / bytes
/// 都要正确。
///
/// 为什么所有 `ScanCoordinator(enableTreeDeepIndex: true)`：
/// v1.3.z 起 `enableTreeDeepIndex` 默认 false，同步 directChildren 内存索引未命中时
/// **返空 + 派后台 task 按需扫描当前目录**。本测试只关心"按内存索引下钻形态"是否正确。
/// v2026.07.18 起内存索引本身也由后台 worker 生成 presentation cache；测试等待发布，
/// 不再要求宽 `kids.map + sort` 同步发生在 MainActor。
@MainActor
final class TreeDownDrillTests: XCTestCase {

    /// 临时 fixture：root/A/big.bin (8KB) + root/A/small.bin (2KB) + root/B/m.bin (4KB)
    /// 三层结构（root → A/B → 文件），便于断言聚合 size 与 children。
    private func makeFixture() throws -> URL {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "GSYCleanTreeDrill-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 8 * 1024).write(to: a.appendingPathComponent("big.bin"))
        try Data(repeating: 0xBB, count: 2 * 1024).write(to: a.appendingPathComponent("small.bin"))
        try Data(repeating: 0xCC, count: 4 * 1024).write(to: b.appendingPathComponent("m.bin"))
        return root
    }

    private func waitFinished(_ coord: ScanCoordinator, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !coord.snapshot.isFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitChildren(
        _ coord: ScanCoordinator,
        path: String,
        expectedCount: Int,
        timeout: TimeInterval = 5
    ) async -> [TreeRow] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = coord.directChildren(of: path)
            if rows.count == expectedCount { return rows }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coord.directChildren(of: path)
    }

    func test_顶层directChildren按size降序排好() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let kids = await waitChildren(coord, path: root.path, expectedCount: 2)
        XCTAssertEqual(kids.count, 2, "顶层应只有 A / B 两个目录")
        XCTAssertEqual(kids[0].title, "A", "A 总和 10KB > B 4KB，应排第一")
        XCTAssertEqual(kids[1].title, "B")
        XCTAssertTrue(kids[0].isDirectory)
        XCTAssertTrue(kids[0].hasChildren)
        XCTAssertGreaterThanOrEqual(kids[0].bytes, 10 * 1024) // 8K + 2K，可能加 inode 开销
    }

    func test_二层directChildren能展开到具体文件() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let aPath = root.path + "/A"
        let aKids = await waitChildren(coord, path: aPath, expectedCount: 2)
        XCTAssertEqual(aKids.count, 2, "A 下应有 big.bin / small.bin")
        XCTAssertEqual(aKids[0].title, "big.bin", "big.bin (8K) 应排第一")
        XCTAssertFalse(aKids[0].isDirectory)
        XCTAssertFalse(aKids[0].hasChildren)
        XCTAssertEqual(aKids[1].title, "small.bin")
    }

    func test_未扫描目录directChildren返回空() async throws {
        // 这一条不开 deepIndex 也对——内存索引和按需扫描缓存都没数据，必返空。
        let coord = ScanCoordinator()
        XCTAssertTrue(coord.directChildren(of: "/nonexistent/never/scanned").isEmpty)
    }
}
