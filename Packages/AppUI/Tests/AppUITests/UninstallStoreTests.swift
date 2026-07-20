import XCTest
import Foundation
import Dispatch
@testable import AppUI
@testable import ScanKit

/// UninstallStore —— 卸载视图的状态 actor 测试
///
/// 三大用例（中文测试名）：
/// 1. `test_listInstalledApps在空Applications返回空()`
///    —— 当 /Applications（在测试里替换为临时空目录）里没有任何 .app 时返回空数组
/// 2. `test_selectApp返回非空候选()`
///    —— 给定一个 fixture .app + 伪 home 里撒残留，selectApp 应返回非空候选
/// 3. `test_TrashPipeline诊断dryRun不会真动文件()`
///    —— 只验证底层诊断能力；UninstallScreen 生产交互不暴露或调用 dry-run
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

    private func installedIdentity(at url: URL) throws -> InstalledAppFileIdentity {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return InstalledAppFileIdentity(metadata: metadata)
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
        XCTAssertTrue(apps.isComplete, "不存在的可选 Applications 根是可信空，不应伪造权限缺口")
    }

    func test_listInstalledApps合并系统与用户根_按canonical路径去重但保留独立安装() async throws {
        let root = try makeTempDir("multi-root-apps")
        defer { try? FileManager.default.removeItem(at: root) }
        let systemApps = root.appendingPathComponent("SystemApplications", isDirectory: true)
        let userApps = root.appendingPathComponent("UserApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: systemApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)

        let systemApp = try makeFixtureApp(
            parent: systemApps,
            name: "Acme",
            bundleID: "com.acme.same",
            bundleName: "Acme"
        )
        let userCopy = try makeFixtureApp(
            parent: userApps,
            name: "Acme Copy",
            bundleID: "com.acme.same",
            bundleName: "Acme"
        )
        try FileManager.default.createSymbolicLink(
            at: userApps.appendingPathComponent("Acme Alias.app"),
            withDestinationURL: systemApp
        )

        let store = UninstallStore(applicationPaths: [systemApps.path, userApps.path, systemApps.path + "/"])
        let result = await store.listInstalledApps()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(Set(result.apps.map(\.appURL.path)), Set([systemApp.path, userCopy.path]))
        XCTAssertTrue(result.apps.allSatisfy { $0.fileIdentity != nil })
        XCTAssertEqual(result.apps.map(\.metadata.bundleID), ["com.acme.same", "com.acme.same"],
                       "相同 Bundle ID 的两份真实安装必须保留；只去重同一 canonical bundle")
    }

    func test_listInstalledApps单根失败_保留其它根命中并返回逐根缺口() async throws {
        let root = try makeTempDir("partial-root-apps")
        defer { try? FileManager.default.removeItem(at: root) }
        let readableRoot = root.appendingPathComponent("Readable", isDirectory: true)
        let deniedRoot = root.appendingPathComponent("Denied", isDirectory: true)
        try FileManager.default.createDirectory(at: readableRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deniedRoot, withIntermediateDirectories: true)
        let app = try makeFixtureApp(
            parent: readableRoot,
            name: "Readable",
            bundleID: "com.acme.readable",
            bundleName: "Readable"
        )
        let reader = FixtureInstalledRootReader(
            directories: [readableRoot.path, deniedRoot.path],
            namesByRoot: [readableRoot.path: [app.lastPathComponent]],
            deniedRoots: [deniedRoot.path]
        )
        let store = UninstallStore(
            applicationPaths: [readableRoot.path, deniedRoot.path],
            rootReader: reader
        )

        let result = await store.listInstalledApps()

        XCTAssertEqual(result.apps.map(\.id), [app.path])
        XCTAssertEqual(result.incompleteIssues, [
            .init(rootPath: deniedRoot.path, path: deniedRoot.path, reason: .permissionDenied)
        ])
        XCTAssertFalse(result.isComplete, "一个根失败时不能把另一根命中误报为全量结果")
    }

    func test_listInstalledApps递归普通容器_且localized目录不被误剪枝() async throws {
        let root = try makeTempDir("nested-apps")
        defer { try? FileManager.default.removeItem(at: root) }
        let localizedContainer = root
            .appendingPathComponent(".localized", isDirectory: true)
            .appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localizedContainer,
            withIntermediateDirectories: true
        )
        let nestedApp = try makeFixtureApp(
            parent: localizedContainer,
            name: "Nested",
            bundleID: "com.acme.nested",
            bundleName: "Nested"
        )

        let result = await UninstallStore(applicationsPath: root.path).listInstalledApps()

        XCTAssertEqual(result.apps.map(\.appURL.path), [nestedApp.path])
        XCTAssertEqual(result.authority, .exact)
    }

    func test_listInstalledApps在app和其它package边界剪枝_不误收集内嵌App() async throws {
        let root = try makeTempDir("embedded-app-prune")
        defer { try? FileManager.default.removeItem(at: root) }
        let hostApp = try makeFixtureApp(
            parent: root,
            name: "Host",
            bundleID: "com.acme.host",
            bundleName: "Host"
        )
        let helperParent = hostApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helperParent, withIntermediateDirectories: true)
        _ = try makeFixtureApp(
            parent: helperParent,
            name: "Embedded Helper",
            bundleID: "com.acme.host.helper",
            bundleName: "Embedded Helper"
        )

        let pluginBundle = root.appendingPathComponent("Extension.bundle", isDirectory: true)
        let pluginContents = pluginBundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginContents, withIntermediateDirectories: true)
        let bundleInfo: [String: Any] = [
            "CFBundleIdentifier": "com.acme.extension",
            "CFBundlePackageType": "BNDL"
        ]
        let bundleInfoData = try PropertyListSerialization.data(
            fromPropertyList: bundleInfo,
            format: .xml,
            options: 0
        )
        try bundleInfoData.write(to: pluginContents.appendingPathComponent("Info.plist"))
        _ = try makeFixtureApp(
            parent: pluginContents,
            name: "Bundled Helper",
            bundleID: "com.acme.extension.helper",
            bundleName: "Bundled Helper"
        )

        let result = await UninstallStore(applicationsPath: root.path).listInstalledApps()

        XCTAssertEqual(result.apps.map(\.appURL.path), [hostApp.path])
        XCTAssertTrue(result.isComplete)
    }

    func test_listInstalledApps不跟随符号链接_防止越界与环路() async throws {
        let fixture = try makeTempDir("symlink-boundary")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Applications", isDirectory: true)
        let outside = fixture.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let insideApp = try makeFixtureApp(
            parent: root,
            name: "Inside",
            bundleID: "com.acme.inside",
            bundleName: "Inside"
        )
        let outsideApp = try makeFixtureApp(
            parent: outside,
            name: "Outside",
            bundleID: "com.acme.outside",
            bundleName: "Outside"
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Escape", isDirectory: true),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Loop", isDirectory: true),
            withDestinationURL: root
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Outside Alias.app", isDirectory: true),
            withDestinationURL: outsideApp
        )

        let result = await UninstallStore(applicationsPath: root.path).listInstalledApps()

        XCTAssertEqual(result.apps.map(\.appURL.path), [insideApp.path])
        XCTAssertTrue(result.isComplete, "不跟随子 symlink 是明确边界，不是扫描缺口")
    }

    func test_listInstalledApps排队目录被替换为越界symlink_只记缺口不遍历替换树() async throws {
        let fixture = try makeTempDir("queued-directory-replacement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Applications", isDirectory: true)
        let queuedContainer = root.appendingPathComponent("Queued", isDirectory: true)
        let displacedContainer = fixture.appendingPathComponent("Queued-Original", isDirectory: true)
        let outside = fixture.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: queuedContainer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = try makeFixtureApp(
            parent: queuedContainer,
            name: "Original Nested",
            bundleID: "com.acme.original-nested",
            bundleName: "Original Nested"
        )
        _ = try makeFixtureApp(
            parent: outside,
            name: "Escaped",
            bundleID: "com.acme.escaped",
            bundleName: "Escaped"
        )
        let reader = QueueReplacingInstalledRootReader(
            queuedPath: queuedContainer.path,
            displacedPath: displacedContainer.path,
            replacementTarget: outside
        )
        let store = UninstallStore(applicationPaths: [root.path], rootReader: reader)

        let result = await store.listInstalledApps()

        XCTAssertTrue(result.apps.isEmpty, "旧对象已移走，替换 symlink 的越界 App 也绝不能被发现")
        XCTAssertEqual(result.authority, .lowerBound)
        XCTAssertTrue(result.incompleteIssues.contains {
            $0.rootPath == root.path
                && $0.path == queuedContainer.path
                && $0.reason == .metadataUnavailable
        })
    }

    func test_listInstalledApps条目预算达上限_计数只能是下限() async throws {
        let root = try makeTempDir("entry-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Container-\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let reader = FixtureInstalledRootReader(
            directories: [root.path],
            namesByRoot: [root.path: ["Container-0", "Container-1", "Container-2"]],
            deniedRoots: []
        )
        let store = UninstallStore(
            applicationPaths: [root.path],
            rootReader: reader,
            discoveryLimits: .init(maxVisitedEntries: 1)
        )

        let result = await store.listInstalledApps()

        XCTAssertEqual(result.authority, .lowerBound)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.incompleteIssues.contains {
            $0.rootPath == root.path && $0.reason == .traversalBudgetExceeded
        })
        XCTAssertFalse(AppFootprintMetricProjection.isComplete(
            items: [],
            discoveryIssues: result.incompleteIssues
        ), "条目预算缺口必须继续投影为 App Footprint 下限，不得显示精确总量")
    }

    func test_listInstalledApps截止时间达上限_保留超时缺口() async {
        let root = "/Fixture/Applications"
        let reader = FixtureInstalledRootReader(
            directories: [root],
            namesByRoot: [:],
            deniedRoots: []
        )
        let store = UninstallStore(
            applicationPaths: [root],
            rootReader: reader,
            discoveryLimits: .init(maxDuration: 0)
        )

        let result = await store.listInstalledApps()

        XCTAssertEqual(result.authority, .lowerBound)
        XCTAssertEqual(result.incompleteIssues, [
            .init(rootPath: root, path: root, reason: .timeLimitExceeded)
        ])
    }

    func test_listInstalledAppsNaN截止时间不能退化为无界扫描() async {
        let root = "/Fixture/NaNDeadlineApplications"
        let reader = FixtureInstalledRootReader(
            directories: [root],
            namesByRoot: [:],
            deniedRoots: []
        )
        let store = UninstallStore(
            applicationPaths: [root],
            rootReader: reader,
            discoveryLimits: .init(maxDuration: .nan)
        )

        let result = await store.listInstalledApps()

        XCTAssertEqual(result.incompleteIssues, [
            .init(rootPath: root, path: root, reason: .timeLimitExceeded)
        ])
    }

    func test_listInstalledApps正无穷截止时间是显式无deadline() async {
        let root = "/Fixture/InfiniteDeadlineApplications"
        let reader = FixtureInstalledRootReader(
            directories: [root],
            namesByRoot: [:],
            deniedRoots: []
        )
        let store = UninstallStore(
            applicationPaths: [root],
            rootReader: reader,
            discoveryLimits: .init(maxDuration: .infinity)
        )

        let result = await store.listInstalledApps()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.authority, .exact)
    }

    func test_listInstalledApps取消通过显式token收敛_不等待默认超时() async throws {
        let root = "/Fixture/BlockingApplications"
        let store = UninstallStore(
            applicationPaths: [root],
            rootReader: CancellableInstalledRootReader()
        )
        let task = Task { await store.listInstalledApps() }
        try await Task.sleep(for: .milliseconds(40))

        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = cancelledAt.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertEqual(result.authority, .lowerBound)
        XCTAssertTrue(result.incompleteIssues.contains {
            $0.rootPath == root && $0.reason == .cancelled
        })
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

    func test_selectApp应走异步候选扫描避免多个残留目录串行等待() async throws {
        let fixture = try makeTempDir("slow-selected-app")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let appURL = try makeFixtureApp(
            parent: fixture,
            name: "Slow",
            bundleID: "com.slow.demo",
            bundleName: "Slow"
        )
        let app = InstalledApp(
            appURL: appURL,
            metadata: AppMetadata(
                bundleID: "com.slow.demo",
                bundleVendor: "com.slow",
                appName: "Slow",
                executableName: nil
            ),
            fileIdentity: try installedIdentity(at: appURL)
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

    func test_selectApp不等待Spotlight兜底_但保留pkgReceipt完整性() async throws {
        let fixture = try makeTempDir("fast-selected-app")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let appURL = try makeFixtureApp(
            parent: fixture,
            name: "Fast",
            bundleID: "com.fast.demo",
            bundleName: "FastDemo"
        )
        let app = InstalledApp(
            appURL: appURL,
            metadata: AppMetadata(
                bundleID: "com.fast.demo",
                bundleVendor: "com.fast",
                appName: "FastDemo",
                executableName: nil
            ),
            fileIdentity: try installedIdentity(at: appURL)
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

    func test_selectApp不存在的选中bundle必须failClosed并保留身份缺口() async {
        let missingPath = "/Applications/Missing-\(UUID().uuidString).app"
        let app = InstalledApp(
            appURL: URL(fileURLWithPath: missingPath),
            metadata: AppMetadata(
                bundleID: "com.acme.missing",
                bundleVendor: "com.acme",
                appName: "Missing",
                executableName: nil
            )
        )

        let result = await UninstallStore(applicationsPath: "/Applications").selectApp(app)

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.incompleteIssues, [
            UninstallDiscoveryIssue(
                source: .selectedAppIdentity,
                stage: .identityValidation,
                path: missingPath,
                reason: .identityUnavailable
            )
        ])
    }

    func test_selectApp同BundleID不同inode替换必须failClosed() async throws {
        let fixture = try makeTempDir("same-bundle-id-replacement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let original = try makeFixtureApp(
            parent: fixture,
            name: "Acme",
            bundleID: "com.acme.same",
            bundleName: "Acme"
        )
        let frozen = InstalledApp(
            appURL: original,
            metadata: try AppMetadata.read(appURL: original),
            fileIdentity: try installedIdentity(at: original)
        )
        let displaced = fixture.appendingPathComponent("Acme-Original.app", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: displaced)
        _ = try makeFixtureApp(
            parent: fixture,
            name: "Acme",
            bundleID: "com.acme.same",
            bundleName: "Acme Replacement"
        )
        let store = UninstallStore(
            applicationsPath: fixture.path,
            uninstaller: AppUninstaller(homeDirectory: fixture.path, systemLibrary: "/Library")
        )

        let result = await store.selectApp(frozen)
        let frozenIdentity = try XCTUnwrap(UninstallSelectedAppIdentity(installedApp: frozen))
        let handoffIssue = await store.validationIssue(
            for: frozenIdentity
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.incompleteIssues.first?.source, .selectedAppIdentity)
        XCTAssertEqual(result.incompleteIssues.first?.reason, .identityUnavailable)
        XCTAssertEqual(handoffIssue?.reason, .identityUnavailable)
    }

    func test_selectApp路径替换为指向原inode的symlink仍必须failClosed() async throws {
        let fixture = try makeTempDir("selected-app-symlink-replacement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let original = try makeFixtureApp(
            parent: fixture,
            name: "Acme",
            bundleID: "com.acme.same",
            bundleName: "Acme"
        )
        let frozen = InstalledApp(
            appURL: original,
            metadata: try AppMetadata.read(appURL: original),
            fileIdentity: try installedIdentity(at: original)
        )
        let displaced = fixture.appendingPathComponent("Acme-Original.app", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: displaced)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: displaced)
        let store = UninstallStore(
            applicationsPath: fixture.path,
            uninstaller: AppUninstaller(homeDirectory: fixture.path, systemLibrary: "/Library")
        )

        let result = await store.selectApp(frozen)

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.incompleteIssues.first?.source, .selectedAppIdentity)
        XCTAssertEqual(result.incompleteIssues.first?.reason, .identityUnavailable)
    }

    func test_selectApp新轮等待旧残留producer真正退出后才启动() async throws {
        let fixture = try makeTempDir("residual-producer-settlement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let firstURL = try makeFixtureApp(
            parent: fixture,
            name: "First",
            bundleID: "com.acme.first",
            bundleName: "First"
        )
        let secondURL = try makeFixtureApp(
            parent: fixture,
            name: "Second",
            bundleID: "com.acme.second",
            bundleName: "Second"
        )
        let first = InstalledApp(
            appURL: firstURL,
            metadata: try AppMetadata.read(appURL: firstURL),
            fileIdentity: try installedIdentity(at: firstURL)
        )
        let second = InstalledApp(
            appURL: secondURL,
            metadata: try AppMetadata.read(appURL: secondURL),
            fileIdentity: try installedIdentity(at: secondURL)
        )
        let producerProbe = SettlingResidualSnapshot()
        let store = UninstallStore(
            applicationsPath: fixture.path,
            uninstaller: AppUninstaller(
                homeDirectory: fixture.path,
                systemLibrary: "/Library",
                fileManager: producerProbe,
                primaryDiscoveryLimits: .init(maxVisitedEntries: 100, maxDuration: 2)
            )
        )

        let firstTask = Task { await store.selectApp(first) }
        for _ in 0..<500 where producerProbe.startedCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(producerProbe.startedCount, 1)
        let secondTask = Task { await store.selectApp(second) }
        let firstResult = await firstTask.value
        let secondResult = await secondTask.value

        XCTAssertEqual(producerProbe.maximumActiveCount, 1,
                       "新选择不能与尚未结算的旧 readdir producer 重叠")
        XCTAssertEqual(firstResult.incompleteIssues.first?.reason, .cancelled)
        XCTAssertTrue(secondResult.isDiscoveryComplete)
    }

    // MARK: - 3. 底层诊断 dryRun 不会真动文件

    func test_TrashPipeline诊断dryRun不会真动文件() async throws {
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

        // 直接验证 TrashPipeline 的诊断 dryRun；这不是 UninstallScreen 的按钮链路。
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

private struct FixtureInstalledRootReader: InstalledApplicationRootReading {
    let directories: Set<String>
    let namesByRoot: [String: [String]]
    let deniedRoots: Set<String>

    func directoryIdentity(at path: String) throws -> InstalledApplicationDirectoryIdentity? {
        let isListedChild = namesByRoot.contains { entry in
            entry.value.contains {
                (entry.key as NSString).appendingPathComponent($0) == path
            }
        }
        guard directories.contains(path) || isListedChild else { return nil }
        return fixtureDirectoryIdentity(for: path)
    }

    func directoryEntries(
        at path: String,
        expectedIdentity: InstalledApplicationDirectoryIdentity,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        cancellationToken: InstalledAppDiscoveryCancellationToken
    ) throws -> InstalledApplicationDirectoryListing {
        if deniedRoots.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        if cancellationToken.isCancelled {
            return .init(entries: [], issues: [], visitedEntryCount: 0, termination: .cancelled)
        }
        if DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds {
            return .init(entries: [], issues: [], visitedEntryCount: 0, termination: .timeLimit)
        }
        guard expectedIdentity == fixtureDirectoryIdentity(for: path) else {
            return .init(
                entries: [],
                issues: [.init(path: path, reason: .metadataUnavailable)],
                visitedEntryCount: 0,
                termination: .complete
            )
        }
        let names = namesByRoot[path] ?? []
        let acceptedNames = Array(names.prefix(maximumEntries))
        return .init(
            entries: acceptedNames.map { name in
                let childPath = (path as NSString).appendingPathComponent(name)
                return .init(
                    name: name,
                    path: childPath,
                    kind: .directory,
                    directoryIdentity: fixtureDirectoryIdentity(for: childPath)
                )
            },
            issues: [],
            visitedEntryCount: acceptedNames.count,
            termination: names.count > acceptedNames.count ? .entryLimit : .complete
        )
    }

    func isPackageDirectory(at path: String) throws -> Bool {
        false
    }
}

private struct CancellableInstalledRootReader: InstalledApplicationRootReading {
    func directoryIdentity(at path: String) throws -> InstalledApplicationDirectoryIdentity? {
        fixtureDirectoryIdentity(for: path)
    }

    func directoryEntries(
        at path: String,
        expectedIdentity: InstalledApplicationDirectoryIdentity,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        cancellationToken: InstalledAppDiscoveryCancellationToken
    ) throws -> InstalledApplicationDirectoryListing {
        while !cancellationToken.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return .init(
            entries: [],
            issues: [],
            visitedEntryCount: 0,
            termination: cancellationToken.isCancelled ? .cancelled : .timeLimit
        )
    }

    func isPackageDirectory(at path: String) throws -> Bool { false }
}

private struct QueueReplacingInstalledRootReader: InstalledApplicationRootReading {
    let queuedPath: String
    let displacedPath: String
    let replacementTarget: URL
    private let base = DefaultInstalledApplicationRootReader()

    func directoryIdentity(at path: String) throws -> InstalledApplicationDirectoryIdentity? {
        try base.directoryIdentity(at: path)
    }

    func directoryEntries(
        at path: String,
        expectedIdentity: InstalledApplicationDirectoryIdentity,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        cancellationToken: InstalledAppDiscoveryCancellationToken
    ) throws -> InstalledApplicationDirectoryListing {
        if path == queuedPath {
            try FileManager.default.moveItem(atPath: queuedPath, toPath: displacedPath)
            try FileManager.default.createSymbolicLink(
                at: URL(fileURLWithPath: queuedPath, isDirectory: true),
                withDestinationURL: replacementTarget
            )
        }
        return try base.directoryEntries(
            at: path,
            expectedIdentity: expectedIdentity,
            maximumEntries: maximumEntries,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            cancellationToken: cancellationToken
        )
    }

    func isPackageDirectory(at path: String) throws -> Bool {
        try base.isPackageDirectory(at: path)
    }
}

private func fixtureDirectoryIdentity(for path: String) -> InstalledApplicationDirectoryIdentity {
    // Stable FNV-1a identity for protocol fixtures; production identities always come from fstat.
    let inode = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
        (partial ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return .init(deviceID: 1, inode: inode)
}

/// The first bounded root enumeration stays alive until cancellation and then deliberately takes
/// a short settlement tail. If `UninstallStore` merely invalidates a token and starts the new
/// selection, `maximumActiveCount` becomes 2 deterministically.
private final class SettlingResidualSnapshot: FileManagerSnapshotting, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var active = 0
    private var maximumActive = 0

    var startedCount: Int { withLock { starts } }
    var maximumActiveCount: Int { withLock { maximumActive } }

    func firstLevelEntries(at path: String) -> [FSEntry]? { [] }

    func firstLevelDiscovery(
        at path: String,
        maximumEntries: Int,
        deadlineUptimeNanoseconds: UInt64,
        timeLimitMilliseconds: Int64,
        cancellationToken: FSSnapshotCancellationToken
    ) -> FSFirstLevelDiscoveryResult {
        let invocation = withLock { () -> Int in
            starts += 1
            active += 1
            maximumActive = max(maximumActive, active)
            return starts
        }
        defer { withLock { active -= 1 } }
        guard invocation == 1 else { return .missing }
        while !cancellationToken.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        Thread.sleep(forTimeInterval: 0.02)
        return .incomplete(stage: .cancellation, reason: .cancelled)
    }

    func snapshot(at path: String) -> FSSnapshot {
        FSSnapshot(bytes: 0, fileCount: 0, exists: false)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
