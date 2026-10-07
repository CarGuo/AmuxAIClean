import XCTest
import Darwin
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

    func test_dryRun_裸文件名相对symlink指向的文件被排除() throws {
        try writeFile(into: downloads, name: "bare--active.tar.gz",
                      bytes: 8192,
                      mtime: Date(timeIntervalSinceNow: -60 * 86400))
        let link = root.appendingPathComponent("bare--1.0")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "bare--active.tar.gz")

        let cleanup = BrewCleanup(cacheRoot: root)
        let plan = cleanup.dryRun()
        XCTAssertTrue(plan.isEmpty,
                      "裸文件名相对 symlink 同样应排除活跃 bottle；实际 stale: \(plan.stalePaths)")
    }

    // MARK: - 契约 4：downloads 缺失时返回空 plan

    func test_dryRun_缺downloads目录_空plan() throws {
        try FileManager.default.removeItem(at: downloads)
        let cleanup = BrewCleanup(cacheRoot: root)
        let result = cleanup.dryRunWithEvidence()
        XCTAssertTrue(result.plan.isEmpty)
        XCTAssertEqual(result.status, .missing)
        XCTAssertTrue(result.isAuthoritativeEmpty)
        XCTAssertEqual(result.diagnostics, [])
    }

    // MARK: - v2026.07.18 regression: absence and incomplete evidence are distinct

    func test_dryRun_cacheRoot权限拒绝_返回unavailable而不是权威空plan() {
        let rootPath = root.path
        let live = BrewCleanupFileSystem.live
        let fileSystem = BrewCleanupFileSystem(
            contentsOfDirectory: { url in
                if url.path == rootPath {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try live.contentsOfDirectory(url)
            },
            attributes: live.attributes,
            symlinkDestination: live.symlinkDestination
        )

        let result = BrewCleanup(cacheRoot: root, fileSystem: fileSystem)
            .dryRunWithEvidence()

        XCTAssertTrue(result.plan.isEmpty)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertFalse(result.isAuthoritativeEmpty)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.source, .cleanup)
        XCTAssertEqual(result.diagnostics.first?.stage, .enumerateRoot)
        XCTAssertEqual(result.diagnostics.first?.reason, .permissionDenied)
        XCTAssertEqual(result.diagnostics.first?.errorDomain, NSPOSIXErrorDomain)
        XCTAssertEqual(result.diagnostics.first?.errorCode, Int(EACCES))
    }

    func test_dryRun_downloads权限拒绝_返回unavailable而不是权威空plan() {
        let downloadsPath = downloads.path
        let live = BrewCleanupFileSystem.live
        let fileSystem = BrewCleanupFileSystem(
            contentsOfDirectory: { url in
                if url.path == downloadsPath {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try live.contentsOfDirectory(url)
            },
            attributes: live.attributes,
            symlinkDestination: live.symlinkDestination
        )

        let result = BrewCleanup(cacheRoot: root, fileSystem: fileSystem)
            .dryRunWithEvidence()

        XCTAssertTrue(result.plan.isEmpty)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertFalse(result.isAuthoritativeEmpty)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.stage, .enumerateDownloads)
        XCTAssertEqual(result.diagnostics.first?.reason, .permissionDenied)
    }

    func test_dryRun_symlink目标读取失败_不发布任何可能仍活跃的清理候选() throws {
        let old = try writeFile(
            into: downloads,
            name: "abc--active.tar.gz",
            bytes: 4_096,
            mtime: Date(timeIntervalSinceNow: -60 * 86400)
        )
        let link = root.appendingPathComponent("active--1.0")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "downloads/abc--active.tar.gz"
        )
        let linkPath = link.path
        let live = BrewCleanupFileSystem.live
        let fileSystem = BrewCleanupFileSystem(
            contentsOfDirectory: live.contentsOfDirectory,
            attributes: live.attributes,
            symlinkDestination: { url in
                if url.path == linkPath {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                return try live.symlinkDestination(url)
            }
        )

        let result = BrewCleanup(cacheRoot: root, fileSystem: fileSystem)
            .dryRunWithEvidence()

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.plan.stalePaths, [])
        XCTAssertFalse(result.plan.stalePaths.contains(old))
        XCTAssertEqual(result.bytesByPath, [:])
        XCTAssertEqual(result.diagnostics.first?.stage, .resolveSymlink)
        XCTAssertEqual(result.diagnostics.first?.reason, .unreadable)
    }

    func test_dryRun_条目mtime缺失_不会用1970误判为stale() throws {
        let old = try writeFile(
            into: downloads,
            name: "missing-mtime.tar.gz",
            bytes: 8_192,
            mtime: Date(timeIntervalSinceNow: -60 * 86400)
        )
        let oldPath = old.path
        let live = BrewCleanupFileSystem.live
        let fileSystem = BrewCleanupFileSystem(
            contentsOfDirectory: live.contentsOfDirectory,
            attributes: { url in
                if url.path == oldPath {
                    return BrewCleanupEntryAttributes(
                        isSymbolicLink: false,
                        modificationDate: nil,
                        size: 8_192
                    )
                }
                return try live.attributes(url)
            },
            symlinkDestination: live.symlinkDestination
        )

        let result = BrewCleanup(cacheRoot: root, fileSystem: fileSystem)
            .dryRunWithEvidence()

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.plan.stalePaths, [])
        XCTAssertEqual(result.plan.totalBytes, 0)
        XCTAssertEqual(result.bytesByPath, [:])
        XCTAssertEqual(result.diagnostics.first?.stage, .inspectEntry)
        XCTAssertEqual(result.diagnostics.first?.reason, .missingMetadata)
        XCTAssertEqual(result.diagnostics.first?.path, oldPath)
    }

    func test_dryRun_单条目属性权限失败_排除该条目但保留其它可信候选() throws {
        let denied = try writeFile(
            into: downloads,
            name: "denied.tar.gz",
            bytes: 1_024,
            mtime: Date(timeIntervalSinceNow: -60 * 86400)
        )
        let healthy = try writeFile(
            into: downloads,
            name: "healthy.tar.gz",
            bytes: 2_048,
            mtime: Date(timeIntervalSinceNow: -60 * 86400)
        )
        let deniedPath = denied.path
        let live = BrewCleanupFileSystem.live
        let fileSystem = BrewCleanupFileSystem(
            contentsOfDirectory: live.contentsOfDirectory,
            attributes: { url in
                if url.path == deniedPath {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                return try live.attributes(url)
            },
            symlinkDestination: live.symlinkDestination
        )

        let result = BrewCleanup(cacheRoot: root, fileSystem: fileSystem)
            .dryRunWithEvidence()

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.plan.stalePaths, [healthy])
        XCTAssertEqual(result.plan.totalBytes, 2_048)
        XCTAssertEqual(result.bytesByPath, [healthy.path: 2_048])
        XCTAssertFalse(result.plan.stalePaths.contains(denied))
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.reason, .permissionDenied)
        XCTAssertEqual(result.diagnostics.first?.path, deniedPath)
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
