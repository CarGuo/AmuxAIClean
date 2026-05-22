import XCTest
@testable import AppUI
import SafetyKit

/// AppUninstaller —— 残留扫描器测试
///
/// 五大测试主题（与任务对应）：
/// 1. Info.plist 解析（XML 文本写入临时 .app）
/// 2. bundleID 严格相等命中
/// 3. 严格按前缀避免误杀（`com.foo.bar` 不命中 `com.foo.barbarian`）
/// 4. 临时目录构造测试 fixture .app（端到端：候选项含 path/bytes/fileCount/matchReason）
/// 5. LaunchAgents 的 vendor 级匹配 + appName 模糊匹配的边界
final class AppUninstallerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppUninstallerTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 在 `parent` 下面构造一个最小可解析的 `<name>.app`。
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

    // MARK: - 1. Info.plist 解析

    func test_AppMetadata_readsInfoPlist() throws {
        let tmp = try makeTempDir("plist-parse")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appURL = try makeFixtureApp(
            parent: tmp,
            name: "Foo",
            bundleID: "com.example.foo",
            bundleName: "FooApp",
            executable: "FooHelper"
        )

        let meta = try AppMetadata.read(appURL: appURL)
        XCTAssertEqual(meta.bundleID, "com.example.foo")
        XCTAssertEqual(meta.bundleVendor, "com.example")
        XCTAssertEqual(meta.appName, "FooApp")
        XCTAssertEqual(meta.executableName, "FooHelper")
    }

    func test_AppMetadata_throwsOnMissingBundleID() throws {
        let tmp = try makeTempDir("plist-missing-id")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appURL = tmp.appendingPathComponent("Bad.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Bad"] as [String: Any],
            format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try AppMetadata.read(appURL: appURL))
    }

    func test_AppMetadata_fallsBackToFilenameStem() throws {
        let tmp = try makeTempDir("plist-fallback-name")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 不写 CFBundleName/Executable，只写 bundleID
        let appURL = try makeFixtureApp(parent: tmp, name: "MyTool", bundleID: "io.tool.my")
        let meta = try AppMetadata.read(appURL: appURL)
        XCTAssertEqual(meta.appName, "MyTool", "缺少 CFBundleName 时应回退到 .app 文件名 stem")
        XCTAssertNil(meta.executableName)
    }

    // MARK: - 2. bundleID 匹配

    func test_matchReason_bundleIDExactAndDottedSuffix() {
        let unins = AppUninstaller(homeDirectory: "/tmp/fakehome")
        let meta = AppMetadata(
            bundleID: "com.example.foo",
            bundleVendor: "com.example",
            appName: "Foo",
            executableName: nil
        )
        // 严格相等 —— Containers/Application Support 里典型形态
        XCTAssertEqual(
            unins.matchReason(name: "com.example.foo", scope: .user, meta: meta),
            .bundleID("com.example.foo")
        )
        // dot 后缀 —— Preferences/Saved Application State 里典型形态
        XCTAssertEqual(
            unins.matchReason(name: "com.example.foo.plist", scope: .user, meta: meta),
            .bundleID("com.example.foo")
        )
        XCTAssertEqual(
            unins.matchReason(name: "com.example.foo.savedState", scope: .user, meta: meta),
            .bundleID("com.example.foo")
        )
    }

    // MARK: - 3. 严格按前缀避免误杀（核心安全测试）

    func test_matchReason_strictPrefix_doesNotMisfireOnLongerSibling() {
        let unins = AppUninstaller(homeDirectory: "/tmp/fakehome")
        let meta = AppMetadata(
            bundleID: "com.example.bar",
            bundleVendor: "com.example",
            appName: "Bar",
            executableName: nil
        )
        // 假阳性必须为 nil —— 不允许 com.example.bar 命中 com.example.barbarian
        XCTAssertNil(
            unins.matchReason(name: "com.example.barbarian", scope: .user, meta: meta),
            "禁止前缀字符串误命中：com.example.bar 不应吃掉 com.example.barbarian"
        )
        XCTAssertNil(
            unins.matchReason(name: "com.example.barbarian.plist", scope: .user, meta: meta)
        )
        // 反向兜底：合法的 dotted suffix 仍要命中
        XCTAssertEqual(
            unins.matchReason(name: "com.example.bar.plist", scope: .user, meta: meta),
            .bundleID("com.example.bar")
        )
    }

    func test_matchesStrictPrefix_unitTable() {
        // 真值表
        XCTAssertTrue(AppUninstaller.matchesStrictPrefix(name: "com.foo.bar", prefix: "com.foo.bar"))
        XCTAssertTrue(AppUninstaller.matchesStrictPrefix(name: "com.foo.bar.plist", prefix: "com.foo.bar"))
        XCTAssertTrue(AppUninstaller.matchesStrictPrefix(name: "com.foo.bar.savedState", prefix: "com.foo.bar"))
        // 误杀情况
        XCTAssertFalse(AppUninstaller.matchesStrictPrefix(name: "com.foo.barbarian", prefix: "com.foo.bar"))
        XCTAssertFalse(AppUninstaller.matchesStrictPrefix(name: "com.foo.barX", prefix: "com.foo.bar"))
        XCTAssertFalse(AppUninstaller.matchesStrictPrefix(name: "com.foo", prefix: "com.foo.bar"))
        XCTAssertFalse(AppUninstaller.matchesStrictPrefix(name: "", prefix: "com.foo.bar"))
    }

    // MARK: - 4. 临时目录构造端到端 —— 主集成测试

    func test_candidates_endToEnd_withFakeHome() throws {
        // 构造伪 home：H/Library/<11 dirs>，再单独构造 fakeSystem/Library/LaunchDaemons
        let root = try makeTempDir("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let sysLibrary = root.appendingPathComponent("sys/Library")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sysLibrary, withIntermediateDirectories: true)

        // 准备 11 个用户级目录
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

        // 构造 fixture .app（位置无所谓，仅供 Info.plist 解析）
        let appURL = try makeFixtureApp(
            parent: root,
            name: "Acme",
            bundleID: "com.acme.demo",
            bundleName: "Acme",
            executable: "AcmeHelper"
        )

        // 撒残留：
        // a) Application Support/com.acme.demo/data.bin (应命中 .bundleID)
        let asDir = home.appendingPathComponent("Library/Application Support/com.acme.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: asDir, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: 1024)
        try payload.write(to: asDir.appendingPathComponent("data.bin"))
        try payload.write(to: asDir.appendingPathComponent("more.bin"))

        // b) Preferences/com.acme.demo.plist (应命中 .bundleID)
        try Data("a".utf8).write(
            to: home.appendingPathComponent("Library/Preferences/com.acme.demo.plist")
        )

        // c) Caches/Acme  (应命中 .appName)
        let acmeCache = home.appendingPathComponent("Library/Caches/Acme", isDirectory: true)
        try FileManager.default.createDirectory(at: acmeCache, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: acmeCache.appendingPathComponent("c1.txt"))

        // d) LaunchAgents/com.acme.updater.plist (vendor 级命中 .bundleVendor("com.acme"))
        try Data("d".utf8).write(
            to: home.appendingPathComponent("Library/LaunchAgents/com.acme.updater.plist")
        )

        // e) /Library/LaunchDaemons/com.acme.demo.helper.plist (.bundleID dotted suffix)
        try Data("e".utf8).write(
            to: sysLibrary.appendingPathComponent("LaunchDaemons/com.acme.demo.helper.plist")
        )

        // 干扰项 —— 以下都不能命中
        // f) Application Support/com.acme.demonic (前缀字符串相似但非合法 dot suffix)
        let dirNoise = home.appendingPathComponent("Library/Application Support/com.acme.demonic", isDirectory: true)
        try FileManager.default.createDirectory(at: dirNoise, withIntermediateDirectories: true)
        try Data("f".utf8).write(to: dirNoise.appendingPathComponent("x.bin"))

        // g) Caches/Spotify （明显不相关）
        let dirSpotify = home.appendingPathComponent("Library/Caches/Spotify", isDirectory: true)
        try FileManager.default.createDirectory(at: dirSpotify, withIntermediateDirectories: true)

        // h) Application Support/com.acme（vendor 级，但 user scope 不应启用 vendor）
        let dirVendorOnly = home.appendingPathComponent("Library/Application Support/com.acme", isDirectory: true)
        try FileManager.default.createDirectory(at: dirVendorOnly, withIntermediateDirectories: true)

        let unins = AppUninstaller(
            homeDirectory: home.path,
            systemLibrary: sysLibrary.path
        )
        let candidates = try unins.candidates(forAppAt: appURL)

        // 期望命中 5 项（a/b/c/d/e）
        let paths = candidates.map(\.path).sorted()
        XCTAssertEqual(candidates.count, 5, "命中数错误。实际命中：\(paths)")

        // 必含
        XCTAssertTrue(paths.contains(asDir.path))
        XCTAssertTrue(paths.contains(home.appendingPathComponent("Library/Preferences/com.acme.demo.plist").path))
        XCTAssertTrue(paths.contains(acmeCache.path))
        XCTAssertTrue(paths.contains(home.appendingPathComponent("Library/LaunchAgents/com.acme.updater.plist").path))
        XCTAssertTrue(paths.contains(sysLibrary.appendingPathComponent("LaunchDaemons/com.acme.demo.helper.plist").path))

        // 必不含
        XCTAssertFalse(paths.contains(dirNoise.path), "误杀检测：com.acme.demonic 不应被收割")
        XCTAssertFalse(paths.contains(dirSpotify.path))
        XCTAssertFalse(paths.contains(dirVendorOnly.path), "user scope 不应启用 vendor 级匹配")

        // bytes/fileCount —— Application Support/com.acme.demo 是目录，含 2 个 1024 字节文件
        let appSupportCand = candidates.first { $0.path == asDir.path }
        XCTAssertEqual(appSupportCand?.fileCount, 2)
        XCTAssertEqual(appSupportCand?.bytes, 2048)

        // matchReason 类型分类
        let reasons = Set(candidates.map(\.matchReason))
        XCTAssertTrue(reasons.contains(.bundleID("com.acme.demo")))
        XCTAssertTrue(reasons.contains(.bundleVendor("com.acme")))
        XCTAssertTrue(reasons.contains(.appName("Acme")))
    }

    // MARK: - 5. 边界

    func test_appNameTooShort_isNotMatchable() {
        // appName 只有 3 个字符 —— 太常见，不参与
        let unins = AppUninstaller(homeDirectory: "/tmp/fakehome")
        let meta = AppMetadata(
            bundleID: "com.x.app",
            bundleVendor: "com.x",
            appName: "App",
            executableName: nil
        )
        XCTAssertNil(unins.matchReason(name: "App", scope: .user, meta: meta))
        XCTAssertNil(unins.matchReason(name: "App", scope: .launch, meta: meta))
    }

    func test_searchRoots_includesAllTwelvePaths() {
        let unins = AppUninstaller(homeDirectory: "/H", systemLibrary: "/Library")
        let roots = unins.searchRoots().map(\.path)
        XCTAssertEqual(roots.count, 12)
        XCTAssertTrue(roots.contains("/H/Library/Application Support"))
        XCTAssertTrue(roots.contains("/H/Library/Caches"))
        XCTAssertTrue(roots.contains("/H/Library/Logs"))
        XCTAssertTrue(roots.contains("/H/Library/Preferences"))
        XCTAssertTrue(roots.contains("/H/Library/Saved Application State"))
        XCTAssertTrue(roots.contains("/H/Library/Containers"))
        XCTAssertTrue(roots.contains("/H/Library/Group Containers"))
        XCTAssertTrue(roots.contains("/H/Library/LaunchAgents"))
        XCTAssertTrue(roots.contains("/H/Library/Cookies"))
        XCTAssertTrue(roots.contains("/H/Library/WebKit"))
        XCTAssertTrue(roots.contains("/H/Library/HTTPStorages"))
        XCTAssertTrue(roots.contains("/Library/LaunchDaemons"))
    }

    func test_vendorPrefix_extraction() {
        XCTAssertEqual(AppMetadata.vendorPrefix(of: "com.foo.bar.baz"), "com.foo")
        XCTAssertEqual(AppMetadata.vendorPrefix(of: "com.foo"), "com.foo")
        XCTAssertNil(AppMetadata.vendorPrefix(of: "single"))
    }

    // MARK: - 6. 异步版本与同步版本一致性（修问题 #6）

    /// 用一个完全 in-memory 的假 FileManagerSnapshotting，避免真实磁盘抖动。
    /// 每个 entry 对应一个事先约定好的 (bytes, fileCount)。
    private struct FakeFM: FileManagerSnapshotting {
        let entriesByRoot: [String: [FSEntry]]
        let snapshots: [String: FSSnapshot]

        func firstLevelEntries(at path: String) -> [FSEntry]? {
            entriesByRoot[path]
        }
        func snapshot(at path: String) -> FSSnapshot {
            snapshots[path] ?? .init(bytes: 0, fileCount: 0)
        }
    }

    func test_candidatesAsync与同步版本结果集相同() async {
        // 在 ~/Library/Caches 下放 20 个匹配候选 + 几个无关项，
        // 验证两版本对相同输入产生相同结果集（顺序无关）。
        let home = "/H"
        let sysLib = "/Library"

        // 12 个 search root；其余 root 返回 nil 即可
        let cachesPath = "\(home)/Library/Caches"
        let prefsPath = "\(home)/Library/Preferences"

        var entries: [FSEntry] = []
        var snaps: [String: FSSnapshot] = [:]
        // 20 个匹配（bundleID 严格相等 / dotted suffix）
        for i in 0..<20 {
            let name = "com.acme.demo.\(i)"
            let p = "\(cachesPath)/\(name)"
            entries.append(.init(name: name, path: p))
            snaps[p] = .init(bytes: Int64(1000 + i), fileCount: i + 1)
        }
        // 几个无关
        entries.append(.init(name: "Spotify", path: "\(cachesPath)/Spotify"))
        entries.append(.init(name: "com.acme.demonic", path: "\(cachesPath)/com.acme.demonic"))

        // Preferences 再放 1 个 dotted suffix
        let prefsEntry = FSEntry(name: "com.acme.demo.plist", path: "\(prefsPath)/com.acme.demo.plist")
        snaps[prefsEntry.path] = .init(bytes: 42, fileCount: 1)

        let fake = FakeFM(
            entriesByRoot: [
                cachesPath: entries,
                prefsPath: [prefsEntry]
            ],
            snapshots: snaps
        )
        let unins = AppUninstaller(homeDirectory: home, systemLibrary: sysLib, fileManager: fake)
        let meta = AppMetadata(
            bundleID: "com.acme.demo",
            bundleVendor: "com.acme",
            appName: "Demo",
            executableName: nil
        )

        let sync = unins.candidates(for: meta)
        let async_ = await unins.candidatesAsync(for: meta)

        // 至少 21 项（20 个 caches + 1 个 prefs）
        XCTAssertEqual(sync.count, 21)
        XCTAssertEqual(async_.count, sync.count, "异步版本候选数应等于同步版本")

        // path 集合相同（顺序无关）
        XCTAssertEqual(Set(sync.map(\.path)), Set(async_.map(\.path)))

        // 总 bytes 相同
        let syncBytes = sync.reduce(Int64(0)) { $0 + $1.bytes }
        let asyncBytes = async_.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(syncBytes, asyncBytes)

        // 逐 path 校验 bytes/fileCount 一致
        let syncByPath = Dictionary(uniqueKeysWithValues: sync.map { ($0.path, $0) })
        let asyncByPath = Dictionary(uniqueKeysWithValues: async_.map { ($0.path, $0) })
        for (path, s) in syncByPath {
            let a = asyncByPath[path]
            XCTAssertEqual(a?.bytes, s.bytes, "bytes 不一致 @ \(path)")
            XCTAssertEqual(a?.fileCount, s.fileCount, "fileCount 不一致 @ \(path)")
            XCTAssertEqual(a?.matchReason, s.matchReason, "matchReason 不一致 @ \(path)")
        }
    }

    // MARK: - 7. VendorRule 路（T3.5a）

    /// 当 app.bundleID 严格命中某 vendor 的 bundleIDPrefix 时，
    /// 该 vendor 的 appSupportSubdir 应作为 .vendorRule 候选额外加入。
    func test_vendorRule_命中bundleIDPrefix后追加appSupportSubdir候选() {
        let home = "/H"
        let sysLib = "/Library"
        let asPath = "\(home)/Library/Application Support"
        let vendorPath = "\(asPath)/JetBrains"

        // 模拟磁盘：
        // - Application Support 的第一层 entries 不包含 "JetBrains" 目录名（不会被 (a)/(c) 命中）
        //   但磁盘上确实有 ~/Library/Application Support/JetBrains 这个目录
        // - 关键：firstLevelEntries 返回 nil 表示 "查不到子条目（不当目录扫）"，
        //   但 snapshot 返回非零 bytes 表示该路径真实存在且有内容
        let fake = FakeFM(
            entriesByRoot: [asPath: []],
            snapshots: [vendorPath: .init(bytes: Int64(1024 * 1024), fileCount: 42)]
        )
        let vendorRule = VendorRule(
            name: "JetBrains",
            bundleIDPrefix: "com.jetbrains",
            appSupportSubdir: "JetBrains"
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: sysLib,
            fileManager: fake,
            vendorRules: [vendorRule]
        )
        let meta = AppMetadata(
            bundleID: "com.jetbrains.intellij",
            bundleVendor: "com.jetbrains",
            appName: "IntelliJ IDEA",
            executableName: "idea"
        )

        let cands = unins.candidates(for: meta)
        let paths: [String] = cands.map { $0.path }
        XCTAssertTrue(paths.contains(vendorPath),
                      "JetBrains app_support_subdir 应作为 .vendorRule 候选；实际：\(paths)")
        let vendorCand = cands.first { $0.path == vendorPath }
        XCTAssertEqual(vendorCand?.matchReason, .vendorRule("JetBrains"))
        XCTAssertEqual(vendorCand?.bytes, Int64(1024 * 1024))
        XCTAssertEqual(vendorCand?.fileCount, 42)
    }

    func test_vendorRule_不同vendor的bundleID不会触发() {
        let home = "/H"
        let asPath = "\(home)/Library/Application Support"
        let jbPath = "\(asPath)/JetBrains"

        let fake = FakeFM(
            entriesByRoot: [asPath: []],
            snapshots: [jbPath: .init(bytes: 999, fileCount: 9)]
        )
        let jbRule = VendorRule(
            name: "JetBrains",
            bundleIDPrefix: "com.jetbrains",
            appSupportSubdir: "JetBrains"
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            vendorRules: [jbRule]
        )
        // 用一个跟 com.jetbrains 完全无关的 app
        let meta = AppMetadata(
            bundleID: "com.tencent.xinWeChat",
            bundleVendor: "com.tencent",
            appName: "WeChat",
            executableName: nil
        )
        let cands = unins.candidates(for: meta)
        let cPaths: [String] = cands.map { $0.path }
        XCTAssertFalse(cPaths.contains(jbPath),
                       "WeChat 卸载不应触发 JetBrains vendor 路径，否则会误删")
    }

    func test_vendorRule_严格前缀_不会被相似vendorIDPrefix误命中() {
        // 构造 com.jetbrains（合法）+ com.jetbrainsoft（陷阱）
        let home = "/H"
        let asPath = "\(home)/Library/Application Support"
        let trapPath = "\(asPath)/Trap"

        let fake = FakeFM(
            entriesByRoot: [asPath: []],
            snapshots: [trapPath: .init(bytes: 1, fileCount: 1)]
        )
        let trap = VendorRule(
            name: "Trap",
            bundleIDPrefix: "com.jetbrainsoft",  // 注意：不是 com.jetbrains
            appSupportSubdir: "Trap"
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            vendorRules: [trap]
        )
        let meta = AppMetadata(
            bundleID: "com.jetbrains.intellij",
            bundleVendor: "com.jetbrains",
            appName: "IntelliJ",
            executableName: nil
        )
        let cands = unins.candidates(for: meta)
        let trapPaths: [String] = cands.map { $0.path }
        XCTAssertFalse(trapPaths.contains(trapPath),
                       "com.jetbrains 不应被 com.jetbrainsoft 误命中（前缀字符相似但 dot 边界不同）")
    }

    func test_vendorRule_路径不存在则不入候选() {
        let home = "/H"
        let asPath = "\(home)/Library/Application Support"
        // 不放任何 snapshot，路径"不存在"
        let fake = FakeFM(entriesByRoot: [asPath: []], snapshots: [:])
        let rule = VendorRule(
            name: "Ghost",
            bundleIDPrefix: "com.ghost",
            appSupportSubdir: "GhostDir"
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            vendorRules: [rule]
        )
        let meta = AppMetadata(
            bundleID: "com.ghost.app",
            bundleVendor: "com.ghost",
            appName: "Ghost",
            executableName: nil
        )
        XCTAssertTrue(unins.candidates(for: meta).isEmpty,
                      "vendor 路径不存在时不应产生 .vendorRule 候选")
    }

    func test_vendorRule_与bundleID命中路径去重_不重复加() {
        let home = "/H"
        let asPath = "\(home)/Library/Application Support"
        // bundleID 命中：Application Support 第一层就有 "com.foo.app" 目录
        let entry = FSEntry(name: "com.foo.app", path: "\(asPath)/com.foo.app")
        // vendor 规则碰巧 appSupportSubdir 也指向同一路径
        let snap = FSSnapshot(bytes: 100, fileCount: 5)
        let fake = FakeFM(
            entriesByRoot: [asPath: [entry]],
            snapshots: [entry.path: snap]
        )
        let rule = VendorRule(
            name: "Foo",
            bundleIDPrefix: "com.foo",
            appSupportSubdir: "com.foo.app"   // 与 bundleID 命中路径相同
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            vendorRules: [rule]
        )
        let meta = AppMetadata(
            bundleID: "com.foo.app",
            bundleVendor: "com.foo",
            appName: "Foo",
            executableName: nil
        )
        let cands = unins.candidates(for: meta)
        let pathHits = cands.filter { $0.path == entry.path }
        XCTAssertEqual(pathHits.count, 1, "同一路径不应同时挂 bundleID 和 vendorRule 两条候选")
        // 第一路（bundleID）应优先于 vendorRule
        XCTAssertEqual(pathHits.first?.matchReason, .bundleID("com.foo.app"))
    }

    func test_vendorRule_async版本与sync结果一致() async {
        let home = "/H"
        let asPath = "\(home)/Library/Application Support"
        let cachesPath = "\(home)/Library/Caches/Homebrew"
        let jbPath = "\(asPath)/JetBrains"

        let fake = FakeFM(
            entriesByRoot: [asPath: []],
            snapshots: [
                jbPath: .init(bytes: 1000, fileCount: 10),
                cachesPath: .init(bytes: 2000, fileCount: 20)
            ]
        )
        let rule1 = VendorRule(
            name: "JetBrains",
            bundleIDPrefix: "com.jetbrains",
            appSupportSubdir: "JetBrains"
        )
        let rule2 = VendorRule(
            name: "Homebrew",
            bundleIDPrefix: "com.jetbrains",   // 假装也被 jetbrains app 触发
            cachesPath: "~/Library/Caches/Homebrew"
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            vendorRules: [rule1, rule2]
        )
        let meta = AppMetadata(
            bundleID: "com.jetbrains.intellij",
            bundleVendor: "com.jetbrains",
            appName: "IntelliJ",
            executableName: nil
        )
        let sync = unins.candidates(for: meta)
        let asyncCands = await unins.candidatesAsync(for: meta)
        let syncPaths: Set<String> = Set(sync.map { $0.path })
        let asyncPaths: Set<String> = Set(asyncCands.map { $0.path })
        XCTAssertEqual(syncPaths, asyncPaths,
                       "vendor 路 sync/async path 集合应一致")
        XCTAssertEqual(
            sync.reduce(Int64(0)) { $0 + $1.bytes },
            asyncCands.reduce(Int64(0)) { $0 + $1.bytes }
        )
    }
}
