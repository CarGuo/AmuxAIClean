import XCTest
@testable import AppUI
import SafetyKit

final class OrphanScannerTests: XCTestCase {

    // MARK: - 工具

    /// 假 BundleResolver：注入两个集合，测哪些 bundleID 算"已注册"，哪些 appName 算"已安装"
    struct StubResolver: BundleResolving {
        let registeredBundles: Set<String>
        let installedNames: Set<String>
        func isBundleIDRegistered(_ bundleID: String) -> Bool { registeredBundles.contains(bundleID) }
        func installedAppNames() -> Set<String> { installedNames }
    }

    /// 假 FS Snapshot —— 不动磁盘，给固定的 bytes/fileCount
    struct StubFM: FileManagerSnapshotting {
        let entriesByRoot: [String: [FSEntry]]
        let bytes: Int64
        let fileCount: Int
        func firstLevelEntries(at path: String) -> [FSEntry]? { entriesByRoot[path] }
        func snapshot(at path: String) -> FSSnapshot { .init(bytes: bytes, fileCount: fileCount) }
    }

    /// 用真实临时目录构造 mtime 老一点的子目录，以便 minAgeDays 判断
    func makeOldTempDir(name: String, ageDays: Int = 90) throws -> String {
        let tmp = NSTemporaryDirectory()
            + "OrphanScannerTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        let target = "\(tmp)/\(name)"
        try FileManager.default.createDirectory(
            atPath: target, withIntermediateDirectories: true)
        let oldDate = Date().addingTimeInterval(-Double(ageDays) * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: target)
        return tmp  // 返回 root
    }

    // MARK: - 1. bundleID 形式判定

    func test_isBundleIDLike_含dot则视为bundleID() {
        XCTAssertTrue(OrphanScanner.isBundleIDLike("com.foo.bar"))
        XCTAssertTrue(OrphanScanner.isBundleIDLike("dev.zed.Zed"))
        XCTAssertTrue(OrphanScanner.isBundleIDLike("notion.id"))
        XCTAssertFalse(OrphanScanner.isBundleIDLike("Spotify"))
        XCTAssertFalse(OrphanScanner.isBundleIDLike("Code"))
        XCTAssertFalse(OrphanScanner.isBundleIDLike(".hidden"))
    }

    // MARK: - 2. stem 提取（plist/savedState/lock）

    func test_stemOf_去掉plist等已知后缀但保留中间dot() {
        XCTAssertEqual(OrphanScanner.stemOf("com.foo.bar.plist"), "com.foo.bar")
        XCTAssertEqual(OrphanScanner.stemOf("com.foo.bar"), "com.foo.bar")
        XCTAssertEqual(OrphanScanner.stemOf("Spotify.savedState"), "Spotify")
        XCTAssertEqual(OrphanScanner.stemOf("foo.lock"), "foo")
    }

    // MARK: - 3. 注册过的 bundleID 不当 orphan

    func test_注册过的bundleID不被认为是orphan() throws {
        let root = try makeOldTempDir(name: "com.spotify.client")
        let entries: [FSEntry] = [
            .init(name: "com.spotify.client", path: "\(root)/com.spotify.client")
        ]
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(
                registeredBundles: ["com.spotify.client"],
                installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [root: entries], bytes: 100, fileCount: 1),
            minAgeDays: 30
        )
        let cands = scanner.scan().filter { _ in true }
        // 由于 searchRoots 不含我们的 root，scan() 不会扫到；这里直接验证 evaluate
        let cand = scanner.evaluate(
            entry: entries[0], root: root, now: Date())
        XCTAssertNil(cand, "已注册的 bundleID 应该不被认为是 orphan")
    }

    // MARK: - 4. 未注册 bundleID + 老目录 → 报 orphan

    func test_未注册bundleID且超过minAge_报orphan() throws {
        let root = try makeOldTempDir(name: "com.dead.app", ageDays: 90)
        let entry = FSEntry(name: "com.dead.app", path: "\(root)/com.dead.app")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(registeredBundles: [], installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 1024, fileCount: 3),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNotNil(cand)
        XCTAssertEqual(cand?.bytes, 1024)
        XCTAssertEqual(cand?.fileCount, 3)
        if case .bundleIDNotRegistered(let id) = cand?.reason {
            XCTAssertEqual(id, "com.dead.app")
        } else {
            XCTFail("expected .bundleIDNotRegistered")
        }
    }

    // MARK: - 5. 未注册但太新（< minAge）→ 不报

    func test_未注册bundleID但mtime太新_不报orphan() throws {
        let root = try makeOldTempDir(name: "com.fresh.app", ageDays: 5)
        let entry = FSEntry(name: "com.fresh.app", path: "\(root)/com.fresh.app")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(registeredBundles: [], installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 1024, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNil(cand, "新建不到 30 天的目录不该被认 orphan，避免误删新装 app")
    }

    // MARK: - 6. 普通名字 fallback：已安装 → 不报

    func test_普通appName已安装_不报orphan() throws {
        let root = try makeOldTempDir(name: "Spotify", ageDays: 90)
        let entry = FSEntry(name: "Spotify", path: "\(root)/Spotify")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(
                registeredBundles: [], installedNames: ["Spotify"]),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 100, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNil(cand)
    }

    // MARK: - 7. 普通名字大小写无关匹配

    func test_普通appName_大小写无关命中已安装() throws {
        let root = try makeOldTempDir(name: "spotify", ageDays: 90)
        let entry = FSEntry(name: "spotify", path: "\(root)/spotify")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(
                registeredBundles: [], installedNames: ["Spotify"]),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 100, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNil(cand, "spotify 应该 case-insensitive 命中 Spotify")
    }

    // MARK: - 8. 普通名字 fallback：未安装 → 报 orphan

    func test_普通appName未安装_报orphan_appNameNotInstalled() throws {
        let root = try makeOldTempDir(name: "GhostApp", ageDays: 90)
        let entry = FSEntry(name: "GhostApp", path: "\(root)/GhostApp")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(registeredBundles: [], installedNames: ["Spotify"]),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 100, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNotNil(cand)
        if case .appNameNotInstalled(let n) = cand?.reason {
            XCTAssertEqual(n, "GhostApp")
        } else {
            XCTFail("expected .appNameNotInstalled")
        }
    }

    // MARK: - 9. 隐藏文件、com.apple.* 系统名跳过

    func test_隐藏文件与系统目录跳过() throws {
        let root = try makeOldTempDir(name: ".DS_Store", ageDays: 90)
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(registeredBundles: [], installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 1, fileCount: 1),
            minAgeDays: 30
        )
        XCTAssertNil(scanner.evaluate(
            entry: FSEntry(name: ".DS_Store", path: "\(root)/.DS_Store"),
            root: root, now: Date()))
        XCTAssertNil(scanner.evaluate(
            entry: FSEntry(name: "com.apple.iCloud", path: "\(root)/com.apple.iCloud"),
            root: root, now: Date()),
            "com.apple.* 不应进入 orphan 候选")
        XCTAssertNil(scanner.evaluate(
            entry: FSEntry(name: "AddressBook", path: "\(root)/AddressBook"),
            root: root, now: Date()),
            "AddressBook 是 macOS 自身组件，不应当 orphan")
    }

    // MARK: - 10. plist 后缀走 stem 反查

    func test_plist后缀_取stem做bundleID反查命中已注册() throws {
        let root = try makeOldTempDir(name: "com.live.app.plist", ageDays: 90)
        let entry = FSEntry(name: "com.live.app.plist",
                            path: "\(root)/com.live.app.plist")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(
                registeredBundles: ["com.live.app"], installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 100, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNil(cand,
            "Preferences/com.live.app.plist 的 stem 应该被识别为 com.live.app 并命中已注册 bundle")
    }

    // MARK: - 11. SafetyEngine 闸门：相对路径 forbid 不入候选

    func test_SafetyEngine_forbid路径不入候选() {
        // 给一条相对路径的假 entry，触发 SafetyEngine 的 .relativePath forbid
        let entry = FSEntry(name: "com.foo.bar", path: "relative/com.foo.bar")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(registeredBundles: [], installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 1, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: "/anything", now: Date())
        XCTAssertNil(cand, "相对路径被 SafetyEngine 判 forbid，不应入 orphan 候选")
    }

    // MARK: - 12. searchRoots 三大根目录

    func test_searchRoots_三大根目录齐全() {
        let scanner = OrphanScanner(homeDirectory: "/Users/u")
        let roots = scanner.searchRoots()
        XCTAssertTrue(roots.contains("/Users/u/Library/Application Support"))
        XCTAssertTrue(roots.contains("/Users/u/Library/Caches"))
        XCTAssertTrue(roots.contains("/Users/u/Library/Preferences"))
        XCTAssertEqual(roots.count, 3)
    }

    // MARK: - 13. lastModifiedDays 字段确实算出值

    func test_lastModifiedDays_至少不小于minAgeDays() throws {
        let root = try makeOldTempDir(name: "com.dead.app", ageDays: 60)
        let entry = FSEntry(name: "com.dead.app", path: "\(root)/com.dead.app")
        let scanner = OrphanScanner(
            homeDirectory: "/H",
            resolver: StubResolver(registeredBundles: [], installedNames: []),
            safetyEngine: SafetyEngine(),
            fileManager: StubFM(entriesByRoot: [:], bytes: 1, fileCount: 1),
            minAgeDays: 30
        )
        let cand = scanner.evaluate(entry: entry, root: root, now: Date())
        XCTAssertNotNil(cand)
        XCTAssertGreaterThanOrEqual(cand?.lastModifiedDays ?? 0, 30,
            "lastModifiedDays 至少要超过 minAgeDays，否则该项一开始就不该进候选")
    }

    // MARK: - Step 14 静默失败修复：DefaultBundleResolver 错误分类

    /// 线程安全的 String 收集器（@Sendable closure 内安全 mutate）
    private final class PathCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    /// chmod 000 的 applicationDirectory 应触发 permissionDenied handler
    func test_DefaultBundleResolver_无权限app目录应上报permissionDenied() throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OS-Tests-EACCES-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let collector = PathCollector()
        let resolver = DefaultBundleResolver(
            applicationDirectories: [tmp.path],
            permissionDeniedHandler: { collector.append($0) }
        )

        // 列举失败 → 应上报；返回的 set 应为空
        let names = resolver.installedAppNames()
        XCTAssertTrue(names.isEmpty, "无权限目录应不产出任何 app 名")
        XCTAssertEqual(collector.snapshot, [tmp.path],
            "permissionDeniedHandler 必须被调用一次，参数是无权限的 application 目录路径")
    }

    /// 不存在的 applicationDirectory 静默不上报，且不影响其他目录
    func test_DefaultBundleResolver_不存在app目录静默不上报() {
        let nonexistent = "/Users/__nope__/NoSuchAppDir-\(UUID().uuidString)"
        let collector = PathCollector()
        let resolver = DefaultBundleResolver(
            applicationDirectories: [nonexistent],
            permissionDeniedHandler: { collector.append($0) }
        )

        let names = resolver.installedAppNames()
        XCTAssertTrue(names.isEmpty)
        XCTAssertTrue(collector.snapshot.isEmpty,
            "ENOENT 必须静默到 GSYLog.debug，不调用 permissionDeniedHandler")
    }

    /// 坏 plist 不应让 .app 名整个丢失，只在 GSYLog.debug 留痕
    func test_DefaultBundleResolver_坏plist不影响app名收集() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OS-Tests-BadPlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 构造 Foo.app/Contents/Info.plist 内容是损坏的二进制
        let appURL = tmp.appendingPathComponent("Foo.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x42]).write(to: appURL.appendingPathComponent("Info.plist"))

        let resolver = DefaultBundleResolver(applicationDirectories: [tmp.path])
        let names = resolver.installedAppNames()
        // stem "Foo" 必须收到（即便 plist 损坏，目录名是可信信号）；不期望 CFBundleName
        XCTAssertTrue(names.contains("Foo"),
            "坏 plist 不应让目录名 stem 丢失：\(names)")
    }
}
