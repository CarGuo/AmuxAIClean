import XCTest
@testable import AppUI

/// 测试目的：覆盖 [ScanCoordinator.directChildren(of:sortedBy:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L890)
/// 的**排序逻辑**——即只关心给一组 TreeRow 按 [TreeSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L150)
/// 排出来的顺序对不对，与 deepIndex on/off 的 fetch 策略无关。
///
/// 为什么所有 `ScanCoordinator(enableTreeDeepIndex: true)`：
/// v2026.07.18 起 deepIndex on/off 都遵守同一后台 presentation 合同：cache miss 先返空，
/// actor 从冻结索引生成所有排序投影后再发布。测试等待该 cache 边界，只验证最终排序，
/// 不把主线程同步 materialize 当成前置条件。
///
/// deepIndex=on 从内存索引投影，off 从按需磁盘测量投影；二者最终都写入同一份全排序
/// Tree cache。按需扫描生产者回归另由 TreeDownDrillTests / FullDisk tests 保护。
@MainActor
final class TreeBrowserSortTests: XCTestCase {

    // MARK: - TreeSortKey 单元行为

    func test_TreeSortKey_column_isDescending_映射正确() {
        XCTAssertEqual(TreeSortKey.sizeDesc.column, .size)
        XCTAssertTrue(TreeSortKey.sizeDesc.isDescending)
        XCTAssertEqual(TreeSortKey.sizeAsc.column, .size)
        XCTAssertFalse(TreeSortKey.sizeAsc.isDescending)
        XCTAssertEqual(TreeSortKey.nameAsc.column, .name)
        XCTAssertFalse(TreeSortKey.nameAsc.isDescending)
        XCTAssertEqual(TreeSortKey.nameDesc.column, .name)
        XCTAssertTrue(TreeSortKey.nameDesc.isDescending)
        XCTAssertEqual(TreeSortKey.countDesc.column, .count)
        XCTAssertEqual(TreeSortKey.countAsc.column, .count)
    }

    func test_TreeSortKey_toggled_同列翻转方向() {
        XCTAssertEqual(TreeSortKey.sizeDesc.toggled(to: .size), .sizeAsc)
        XCTAssertEqual(TreeSortKey.sizeAsc.toggled(to: .size), .sizeDesc)
        XCTAssertEqual(TreeSortKey.nameAsc.toggled(to: .name), .nameDesc)
        XCTAssertEqual(TreeSortKey.nameDesc.toggled(to: .name), .nameAsc)
        XCTAssertEqual(TreeSortKey.countDesc.toggled(to: .count), .countAsc)
        XCTAssertEqual(TreeSortKey.countAsc.toggled(to: .count), .countDesc)
    }

    func test_TreeSortKey_toggled_切列采用Finder默认方向() {
        // 任意状态切到 size → sizeDesc；切到 name → nameAsc；切到 count → countDesc
        XCTAssertEqual(TreeSortKey.nameAsc.toggled(to: .size), .sizeDesc)
        XCTAssertEqual(TreeSortKey.sizeDesc.toggled(to: .name), .nameAsc)
        XCTAssertEqual(TreeSortKey.sizeAsc.toggled(to: .count), .countDesc)
        XCTAssertEqual(TreeSortKey.countAsc.toggled(to: .size), .sizeDesc)
    }

    // MARK: - ScanCoordinator.directChildren(of:sortedBy:)

    /// 三层 fixture：root/A(10K)/{big.bin 8K, small.bin 2K} + root/B(4K)/m.bin
    private func makeFixture() throws -> URL {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "GSYCleanTreeSort-\(UUID().uuidString)"
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
        sortedBy key: TreeSortKey,
        expectedCount: Int = 2,
        timeout: TimeInterval = 5
    ) async -> [TreeRow] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = coord.directChildren(of: path, sortedBy: key)
            if rows.count == expectedCount { return rows }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coord.directChildren(of: path, sortedBy: key)
    }

    func test_directChildren_sizeDesc_默认与显式一致() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let defaultKids = await waitChildren(
            coord,
            path: root.path,
            sortedBy: .sizeDesc
        )
        let descKids = coord.directChildren(of: root.path, sortedBy: .sizeDesc)
        XCTAssertEqual(defaultKids.map(\.path), descKids.map(\.path),
                       "directChildren(of:) 必须等价于 directChildren(of:sortedBy:.sizeDesc)")
        XCTAssertEqual(descKids.first?.title, "A")
    }

    func test_directChildren_sizeAsc_最小在前() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let kids = await waitChildren(coord, path: root.path, sortedBy: .sizeAsc)
        XCTAssertEqual(kids.map(\.title), ["B", "A"], "B(4K) < A(10K)，升序应 B 在前")
    }

    func test_directChildren_nameAsc_nameDesc() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let asc = await waitChildren(coord, path: root.path, sortedBy: .nameAsc)
        XCTAssertEqual(asc.map(\.title), ["A", "B"])

        let desc = coord.directChildren(of: root.path, sortedBy: .nameDesc)
        XCTAssertEqual(desc.map(\.title), ["B", "A"])
    }

    func test_directChildren_countDesc_目录子项数排序() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        // A 含 2 个文件，B 含 1 个文件
        let descByCount = await waitChildren(coord, path: root.path, sortedBy: .countDesc)
        XCTAssertEqual(descByCount.first?.title, "A")
        let ascByCount = coord.directChildren(of: root.path, sortedBy: .countAsc)
        XCTAssertEqual(ascByCount.first?.title, "B")
    }

    func test_directChildren_排序稳定_path升序兜底() async throws {
        // 主键相等（本例 size 相同的两个 dir）应按 path 升序
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "GSYCleanTreeSortTie-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        let z = root.appendingPathComponent("Z")
        let a = root.appendingPathComponent("A")
        try fm.createDirectory(at: z, withIntermediateDirectories: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 1024).write(to: z.appendingPathComponent("f.bin"))
        try Data(repeating: 0xAA, count: 1024).write(to: a.appendingPathComponent("f.bin"))
        defer { try? fm.removeItem(at: root) }

        let coord = ScanCoordinator(enableTreeDeepIndex: true)
        let cat = ScanCategory(id: "t", title: "", subtitle: "", rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitFinished(coord)

        let kids = await waitChildren(coord, path: root.path, sortedBy: .sizeDesc)
        XCTAssertEqual(kids.map(\.title), ["A", "Z"],
                       "size 相同时按 path 升序兜底，A 应排在 Z 前面")
    }
}
