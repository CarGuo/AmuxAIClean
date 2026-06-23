import XCTest
import Foundation
@testable import AppUI

/// UninstallStore —— 卸载视图的状态 actor 测试
///
/// 三大用例（中文测试名）：
/// 1. `test_listInstalledApps在空Applications返回空()`
///    —— 当 /Applications（在测试里替换为临时空目录）里没有任何 .app 时返回空数组
/// 2. `test_selectApp返回非空候选()`
///    —— 给定一个 fixture .app + 伪 home 里撒残留，selectApp 应返回非空候选
/// 3. `test_删除走dryRun不会真动文件()`
///    —— 通过 TrashPipeline.dryRun 走完一次"删除候选"链路，磁盘文件原封不动
final class UninstallStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UninstallStoreTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFixtureApp(
        parent: URL,
        name: String,
        bundleID: String,
        bundleName: String? = nil,
        executable: String? = nil
    ) throws -> URL {
        let appURL = parent.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var dict: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let bn = bundleName { dict["CFBundleName"] = bn }
        if let ex = executable { dict["CFBundleExecutable"] = ex }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }

    /// 准备 11 个用户级目录 + 1 个系统级 LaunchDaemons —— 与 AppUninstaller 的 12 个 searchRoots 对齐。
    private func prepareLibrarySkeleton(home: URL, sysLibrary: URL) throws {
        let userDirs = [
            "Library/Application Support",
            "Library/Caches",
            "Library/Logs",
            "Library/Preferences",
            "Library/Saved Application State",
            "Library/Containers",
            "Library/Group Containers",
            "Library/LaunchAgents",
            "Library/Cookies",
            "Library/WebKit",
            "Library/HTTPStorages"
        ]
        for d in userDirs {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(d),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: sysLibrary.appendingPathComponent("LaunchDaemons"),
            withIntermediateDirectories: true
        )
    }

    private struct SlowSnapshotFM: FileManagerSnapshotting {
        let delay: TimeInterval

        func firstLevelEntries(at path: String) -> [FSEntry]? {
            guard path.hasSuffix("Library/Application Support") else { return [] }
            return (0..<4).map { index in
                FSEntry(
                    name: "com.slow.demo.\(index)",
                    path: "\(path)/com.slow.demo.\(index)"
                )
            }
        }

        func snapshot(at path: String) -> FSSnapshot {
            Thread.sleep(forTimeInterval: delay)
            return FSSnapshot(bytes: 1, fileCount: 1)
        }
    }

    private struct SlowSpotlight: SpotlightProbing {
        let delay: TimeInterval

        func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return []
        }

        func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return []
        }
    }

    // MARK: - 1. 空 /Applications 返回空

    func test_listInstalledApps在空Applications返回空() async throws {
        let tmp = try makeTempDir("empty-apps")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // tmp 是空目录，里面没有任何 .app
        let store = UninstallStore(applicationsPath: tmp.path)
        let apps = await store.listInstalledApps()
        XCTAssertEqual(apps.count, 0, "空 /Applications 应返回空数组，实际：\(apps)")
    }

    /// 边界补充：路径不存在时同样返回空（不应 throw）。
    func test_listInstalledApps在路径不存在时返回空() async {
        let nowhere = "/tmp/UninstallStoreTests-nonexistent-\(UUID().uuidString)"
        let store = UninstallStore(applicationsPath: nowhere)
        let apps = await store.listInstalledApps()
        XCTAssertEqual(apps.count, 0)
    }

    // MARK: - 2. selectApp 返回非空候选

    func test_selectApp返回非空候选() async throws {
        let root = try makeTempDir("select-non-empty")
        defer { try? FileManager.default.removeItem(at: root) }

        let appsDir = root.appendingPathComponent("Applications")
        let home = root.appendingPathComponent("home")
        let sysLibrary = root.appendingPathComponent("sys/Library")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sysLibrary, withIntermediateDirectories: true)
        try prepareLibrarySkeleton(home: home, sysLibrary: sysLibrary)

        // 在伪 /Applications 下放一个 fixture .app
        try makeFixtureApp(
            parent: appsDir,
            name: "Acme",
            bundleID: "com.acme.demo",
            bundleName: "Acme",
            executable: "AcmeHelper"
        )

        // 在伪 home 下撒一些命中 com.acme.demo 的残留
        let asDir = home.appendingPathComponent("Library/Application Support/com.acme.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: asDir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 256).write(to: asDir.appendingPathComponent("data.bin"))
        try Data("p".utf8).write(
            to: home.appendingPathComponent("Library/Preferences/com.acme.demo.plist")
        )

        let uninstaller = AppUninstaller(homeDirectory: home.path, systemLibrary: sysLibrary.path)
        let store = UninstallStore(applicationsPath: appsDir.path, uninstaller: uninstaller)

        // 先列出 .app
        let apps = await store.listInstalledApps()
        XCTAssertEqual(apps.count, 1, "应只发现 1 个 fixture .app，实际：\(apps.map(\.metadata.bundleID))")
        let acme = try XCTUnwrap(apps.first)
        XCTAssertEqual(acme.metadata.bundleID, "com.acme.demo")

        // 再查它的卸载候选
        let cands = await store.selectApp(acme)
        XCTAssertFalse(cands.isEmpty, "应返回非空候选项")
        let paths = Set(cands.map(\.path))
        XCTAssertTrue(paths.contains(asDir.path), "Application Support 残留应命中")
        XCTAssertTrue(
            paths.contains(home.appendingPathComponent("Library/Preferences/com.acme.demo.plist").path),
            "Preferences/com.acme.demo.plist 应命中"
        )
    }

    func test_selectApp应走异步候选扫描避免多个残留目录串行等待() async {
        let app = InstalledApp(
            appURL: URL(fileURLWithPath: "/Applications/Slow.app"),
            metadata: AppMetadata(
                bundleID: "com.slow.demo",
                bundleVendor: "com.slow",
                appName: "Slow",
                executableName: nil
            )
        )
        let uninstaller = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: SlowSnapshotFM(delay: 0.15)
        )
        let store = UninstallStore(applicationsPath: "/Applications", uninstaller: uninstaller)

        let start = Date()
        let cands = await store.selectApp(app)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(cands.count, 4)
        XCTAssertLessThan(
            elapsed,
            0.45,
            "selectApp 不能退回同步 candidates(for:)；4 个 150ms snapshot 串行会接近 600ms"
        )
    }

    func test_selectApp不等待SpotlightPkgutil兜底_避免普通App切换长时间loading() async {
        let app = InstalledApp(
            appURL: URL(fileURLWithPath: "/Applications/Fast.app"),
            metadata: AppMetadata(
                bundleID: "com.fast.demo",
                bundleVendor: "com.fast",
                appName: "FastDemo",
                executableName: nil
            )
        )
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        let path = "\(cachesPath)/com.fast.demo"
        struct FM: FileManagerSnapshotting {
            let cachesPath: String
            let path: String
            func firstLevelEntries(at p: String) -> [FSEntry]? {
                p == cachesPath ? [FSEntry(name: "com.fast.demo", path: path)] : []
            }
            func snapshot(at p: String) -> FSSnapshot {
                FSSnapshot(bytes: 10, fileCount: 1)
            }
        }
        let uninstaller = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: FM(cachesPath: cachesPath, path: path),
            spotlight: SlowSpotlight(delay: 0.3)
        )
        let store = UninstallStore(applicationsPath: "/Applications", uninstaller: uninstaller)

        let start = Date()
        let cands = await store.selectApp(app)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(cands.map(\.path), [path])
        XCTAssertLessThan(elapsed, 0.15, "UninstallStore.selectApp 首屏必须只走主路径快速候选")
    }

    // MARK: - 3. 删除走 dryRun 不会真动文件

    func test_删除走dryRun不会真动文件() async throws {
        let root = try makeTempDir("dry-run")
        defer { try? FileManager.default.removeItem(at: root) }

        let appsDir = root.appendingPathComponent("Applications")
        let home = root.appendingPathComponent("home")
        let sysLibrary = root.appendingPathComponent("sys/Library")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try prepareLibrarySkeleton(home: home, sysLibrary: sysLibrary)

        try makeFixtureApp(
            parent: appsDir,
            name: "DryFoo",
            bundleID: "com.dry.foo",
            bundleName: "DryFoo"
        )

        // 撒一份"会被命中并被点选"的残留
        let prefsPlist = home.appendingPathComponent("Library/Preferences/com.dry.foo.plist")
        try Data("hello-dry-run".utf8).write(to: prefsPlist)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefsPlist.path), "前置：残留必须存在")

        let uninstaller = AppUninstaller(homeDirectory: home.path, systemLibrary: sysLibrary.path)
        let store = UninstallStore(applicationsPath: appsDir.path, uninstaller: uninstaller)
        let apps = await store.listInstalledApps()
        let dryFoo = try XCTUnwrap(apps.first)
        let cands = await store.selectApp(dryFoo)
        XCTAssertFalse(cands.isEmpty, "前置：应有候选项")

        // 走 TrashPipeline 的 dryRun 路径 —— 这是 UninstallScreen 默认按钮链路
        let pipeline = TrashPipeline()
        let paths = cands.map(\.path)
        let (moved, skipped, err, _) = await pipeline.moveToTrash(paths: paths, dryRun: true)

        XCTAssertNil(err, "dryRun 不应产生错误")
        XCTAssertEqual(moved, paths.count, "dryRun 应报告 \(paths.count) 项 moved（仅是预览计数）")
        XCTAssertEqual(skipped, 0)

        // 关键断言：dryRun **必须**不动磁盘
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: prefsPlist.path),
            "dryRun=true 之后，原残留文件必须仍然存在"
        )
        // 并且 .app 本体也应不被动
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dryFoo.appURL.path),
            ".app 本体不属于候选项，dryRun 之后必然存在"
        )
    }
}
