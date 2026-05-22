import XCTest
@testable import AppUI

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

    func test_顶层directChildren按size降序排好() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator()
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let kids = coord.directChildren(of: root.path)
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

        let coord = ScanCoordinator()
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let aPath = root.path + "/A"
        let aKids = coord.directChildren(of: aPath)
        XCTAssertEqual(aKids.count, 2, "A 下应有 big.bin / small.bin")
        XCTAssertEqual(aKids[0].title, "big.bin", "big.bin (8K) 应排第一")
        XCTAssertFalse(aKids[0].isDirectory)
        XCTAssertFalse(aKids[0].hasChildren)
        XCTAssertEqual(aKids[1].title, "small.bin")
    }

    func test_未扫描目录directChildren返回空() async throws {
        let coord = ScanCoordinator()
        XCTAssertTrue(coord.directChildren(of: "/nonexistent/never/scanned").isEmpty)
    }
}
