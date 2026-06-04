import XCTest
@testable import BrewKit

/// Step 16-B3 —— BrewCleanup dryRun + shouldRun（7d 冷却 + 50MB 阈值）契约。
final class BrewCleanupTests: XCTestCase {

    private var root: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("brewkit-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 契约 1：超过 pruneDays 的孤儿文件被列出

    func test_dryRun_30天前的孤儿bottle被标记stale() throws {
        let old = try writeFile(into: downloads, name: "hash--old.tar.gz",
                                bytes: 5 * 1024 * 1024,
                                mtime: Date(timeIntervalSinceNow: -45 * 86400))
        _ = old
        let cleanup = BrewCleanup(cacheRoot: root)
        let plan = cleanup.dryRun(now: Date(), pruneDays: 30)
        XCTAssertEqual(plan.stalePaths.map(\.lastPathComponent), ["hash--old.tar.gz"])
        XCTAssertEqual(plan.totalBytes, 5 * 1024 * 1024)
    }

    // MARK: - 契约 2：30 天内的新文件不算 stale

    func test_dryRun_新文件不算stale() throws {
        try writeFile(into: downloads, name: "hash--fresh.tar.gz",
                      bytes: 1024,
                      mtime: Date(timeIntervalSinceNow: -2 * 86400))
        let cleanup = BrewCleanup(cacheRoot: root)
        let plan = cleanup.dryRun()
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.totalBytes, 0)
    }

    // MARK: - 契约 3：被顶层 symlink 指向的活跃 bottle 不算 stale（即使很旧）

    func test_dryRun_活跃symlink指向的文件被排除() throws {
        // 30 天前的文件
        try writeFile(into: downloads, name: "abc--active.tar.gz",
                      bytes: 9999,
                      mtime: Date(timeIntervalSinceNow: -60 * 86400))
        // root 上建 symlink 指向它（典型 Homebrew 别名结构）
        let link = root.appendingPathComponent("active--1.0")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "downloads/abc--active.tar.gz")

        let cleanup = BrewCleanup(cacheRoot: root)
        let plan = cleanup.dryRun()
        XCTAssertTrue(plan.isEmpty,
                      "活跃 bottle 应被 symlink 别名挡住；实际 stale: \(plan.stalePaths)")
    }

    // MARK: - 契约 4：downloads 缺失时返回空 plan

    func test_dryRun_缺downloads目录_空plan() throws {
        try FileManager.default.removeItem(at: downloads)
        let cleanup = BrewCleanup(cacheRoot: root)
        let plan = cleanup.dryRun()
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - 契约 5：混合多文件 — 活跃 + stale + 新文件并存

    func test_dryRun_混合场景_只命中孤儿且超龄() throws {
        // 1) 活跃 + 老 → 跳过
        try writeFile(into: downloads, name: "k1--keep.tar.gz",
                      bytes: 100,
                      mtime: Date(timeIntervalSinceNow: -60 * 86400))
        let l1 = root.appendingPathComponent("keep--1.0")
        try FileManager.default.createSymbolicLink(
            atPath: l1.path, withDestinationPath: "downloads/k1--keep.tar.gz")

        // 2) 孤儿 + 老 → 命中（10 MB）
        try writeFile(into: downloads, name: "k2--stale1.tar.gz",
                      bytes: 10 * 1024 * 1024,
                      mtime: Date(timeIntervalSinceNow: -60 * 86400))

        // 3) 孤儿 + 新 → 跳过
        try writeFile(into: downloads, name: "k3--newish.tar.gz",
                      bytes: 200,
                      mtime: Date(timeIntervalSinceNow: -3 * 86400))

        // 4) 孤儿 + 老 → 命中（20 MB）
        try writeFile(into: downloads, name: "k4--stale2.tar.gz",
                      bytes: 20 * 1024 * 1024,
                      mtime: Date(timeIntervalSinceNow: -100 * 86400))

        let plan = BrewCleanup(cacheRoot: root).dryRun()
        XCTAssertEqual(plan.stalePaths.map(\.lastPathComponent),
                       ["k2--stale1.tar.gz", "k4--stale2.tar.gz"])
        XCTAssertEqual(plan.totalBytes, 30 * 1024 * 1024)
    }

    // MARK: - 契约 6：shouldRun —— bytes < 50MB 直接 false

    func test_shouldRun_未达50MB阈值_拒绝执行() {
        let plan = BrewCleanupPlan(stalePaths: [], totalBytes: 49 * 1024 * 1024)
        XCTAssertFalse(BrewCleanup.shouldRun(plan: plan, lastCleanupAt: nil))
    }

    // MARK: - 契约 7：shouldRun —— bytes ≥ 50MB + 从未清理 → true

    func test_shouldRun_50MB且从未清理_允许执行() {
        let plan = BrewCleanupPlan(stalePaths: [], totalBytes: 51 * 1024 * 1024)
        XCTAssertTrue(BrewCleanup.shouldRun(plan: plan, lastCleanupAt: nil))
    }

    // MARK: - 契约 8：shouldRun —— 上次清理在 7 天冷却内 → false

    func test_shouldRun_7天冷却内_拒绝执行() {
        let plan = BrewCleanupPlan(stalePaths: [], totalBytes: 100 * 1024 * 1024)
        let now = Date()
        let last = now.addingTimeInterval(-3 * 86400)
        XCTAssertFalse(BrewCleanup.shouldRun(plan: plan, lastCleanupAt: last, now: now))
    }

    // MARK: - 契约 9：shouldRun —— 上次清理超过 7 天 → true

    func test_shouldRun_冷却已过_允许执行() {
        let plan = BrewCleanupPlan(stalePaths: [], totalBytes: 100 * 1024 * 1024)
        let now = Date()
        let last = now.addingTimeInterval(-8 * 86400)
        XCTAssertTrue(BrewCleanup.shouldRun(plan: plan, lastCleanupAt: last, now: now))
    }

    // MARK: - 契约 10：阈值边界 —— 恰好 50MB 算允许（>=）

    func test_shouldRun_恰好50MB边界算通过() {
        let plan = BrewCleanupPlan(stalePaths: [], totalBytes: 50 * 1024 * 1024)
        XCTAssertTrue(BrewCleanup.shouldRun(plan: plan, lastCleanupAt: nil))
    }

    // MARK: - helpers

    @discardableResult
    private func writeFile(into dir: URL, name: String, bytes: Int, mtime: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        var values = URLResourceValues()
        values.contentModificationDate = mtime
        var mutable = url
        try mutable.setResourceValues(values)
        return url
    }
}
