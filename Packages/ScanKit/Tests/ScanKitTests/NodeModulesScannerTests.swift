import XCTest
@testable import ScanKit

/// NodeModulesScanner 行为契约。
///
/// 关注：
/// 1. 空 home（5 个 dev 根均不存在）→ `[]`，不抛；
/// 2. 单工程单 node_modules → 1 条 hit，projectName / sizeBytes / mtime 全部正确；
/// 3. 多根 / 多工程 → 全部命中；
/// 4. maxDepth 边界：超过深度的工程不被命中；
/// 5. 命中 node_modules 后不下钻：即便其内部还有 node_modules（嵌套依赖）也不重复命中；
/// 6. 隐藏目录（`.git` 等）必须跳过，不能误把 `.git/...` 当工程下钻。
final class NodeModulesScannerTests: XCTestCase {

    // MARK: - Helpers

    /// 建一个临时 home 目录。
    /// 5 个 dev 根（Developer / Projects / Code / workspace / src）**尚未创建**，
    /// 由各 case 按需 mkdir。
    private func makeTempHome() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NodeModulesScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        return tmp
    }

    /// 在 `parent` 下建一个 `<projectName>/node_modules` 子树，写入一个固定大小的占位文件。
    /// 返回 node_modules 的 URL。
    @discardableResult
    private func makeProjectWithNodeModules(_ projectName: String,
                                            in parent: URL,
                                            fileSize: Int = 256) throws -> URL {
        let fm = FileManager.default
        let proj = parent.appendingPathComponent(projectName, isDirectory: true)
        let nm = proj.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: nm, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: fileSize)
        try payload.write(to: nm.appendingPathComponent("lodash.js"))
        return nm
    }

    /// 直接 mkdir 一个绝对路径目录。
    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Cases

    func test_detect_空home_返回空数组不抛() throws {
        let home = try makeTempHome()
        // 5 个 dev 根均不存在
        let hits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(hits.count, 0, "空 home 应返回 []，不应抛")
    }

    func test_detect_单工程命中_projectName与sizeBytes正确() throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Developer", isDirectory: true)
        try mkdir(dev)
        let nm = try makeProjectWithNodeModules("my-react-app", in: dev, fileSize: 1024)

        let hits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(hits.count, 1, "单工程单 node_modules 应产 1 条 hit")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.url.standardizedFileURL, nm.standardizedFileURL)
        XCTAssertEqual(hit.projectName, "my-react-app",
                       "projectName 必须取 node_modules 的父目录名")
        XCTAssertNotNil(hit.sizeBytes)
        XCTAssertGreaterThanOrEqual(hit.sizeBytes ?? 0, 1024,
                                    "1KB 占位文件至少要被累加进去（block-aligned 后可能更大）")
        XCTAssertNotNil(hit.modificationDate)
    }

    func test_detect_多根多工程_全部命中() throws {
        let home = try makeTempHome()
        // 在 Developer / Projects / Code 三个根分别造一个工程
        for (rootName, projectName) in [
            ("Developer", "app-a"),
            ("Projects", "app-b"),
            ("Code", "app-c"),
            ("workspace", "app-d"),
            ("src", "app-e"),
        ] {
            let root = home.appendingPathComponent(rootName, isDirectory: true)
            try mkdir(root)
            try makeProjectWithNodeModules(projectName, in: root)
        }

        let hits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(hits.count, 5, "5 个根各 1 个工程，应得 5 条 hit")
        let names = Set(hits.map(\.projectName))
        XCTAssertEqual(names, ["app-a", "app-b", "app-c", "app-d", "app-e"])
    }

    func test_detect_maxDepth限制_超深度工程不被命中() throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Developer", isDirectory: true)
        try mkdir(dev)

        // 浅工程：Developer/shallow/node_modules（深度 2，根=0/shallow=1/node_modules=2）
        try makeProjectWithNodeModules("shallow", in: dev)

        // 深工程：Developer/a/b/c/d/deep/node_modules
        // 此时 node_modules 相对 Developer 根的深度 = 6
        let deepParent = dev
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
            .appendingPathComponent("d", isDirectory: true)
        try mkdir(deepParent)
        try makeProjectWithNodeModules("deep", in: deepParent)

        // 默认 maxDepth=4 → 只命中 shallow
        let defaultHits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(defaultHits.count, 1, "maxDepth=4 时 deep 应被深度限制裁掉")
        XCTAssertEqual(defaultHits.first?.projectName, "shallow")

        // 显式调大 maxDepth → deep 也能命中
        let deepHits = NodeModulesScanner.detect(home: home, maxDepth: 10)
        XCTAssertEqual(deepHits.count, 2, "maxDepth=10 时 shallow + deep 都应命中")
        let names = Set(deepHits.map(\.projectName))
        XCTAssertEqual(names, ["shallow", "deep"])
    }

    func test_detect_命中后不下钻_嵌套node_modules不重复命中() throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Developer", isDirectory: true)
        try mkdir(dev)
        let outer = try makeProjectWithNodeModules("outer-app", in: dev)
        // 在 node_modules 内部再造一个 nested-dep/node_modules，
        // 模拟 npm v6 风格的嵌套依赖。
        let nested = outer
            .appendingPathComponent("nested-dep", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
        try mkdir(nested)
        try Data(repeating: 0xCD, count: 64).write(to: nested.appendingPathComponent("x.js"))

        let hits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(hits.count, 1,
                       "命中 outer-app/node_modules 后必须停止下钻，不应再产 nested/node_modules")
        XCTAssertEqual(hits.first?.projectName, "outer-app")
    }

    func test_detect_隐藏目录被跳过_不进入_git_目录() throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Developer", isDirectory: true)
        try mkdir(dev)

        // 正常工程
        try makeProjectWithNodeModules("real-app", in: dev)

        // 在 .git/objects 下故意藏一个 node_modules，scanner 应跳过整个 .git 子树
        let gitNodeModules = dev
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
        try mkdir(gitNodeModules)
        try Data().write(to: gitNodeModules.appendingPathComponent("fake.js"))

        let hits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(hits.count, 1, "隐藏目录 .git 下的 node_modules 不应被命中")
        XCTAssertEqual(hits.first?.projectName, "real-app")
    }

    func test_discover_actor入口_与detect一致() async throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Projects", isDirectory: true)
        try mkdir(dev)
        try makeProjectWithNodeModules("async-app", in: dev)

        let scanner = NodeModulesScanner()
        let hits = await scanner.discover(home: home)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.projectName, "async-app")
    }

    // MARK: - Review fix-soon #5：symlink 防护

    /// 软链指向同 home 内已被扫到的真实 node_modules → 不应被重复计数。
    /// 旧实现会沿软链下钻并再产一条 hit，导致体积虚增。
    func test_detect_软链指向真实工程_不重复命中() throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Developer", isDirectory: true)
        try mkdir(dev)
        try makeProjectWithNodeModules("real-app", in: dev)

        // 在 Projects 根下做一个软链指向 Developer/real-app
        let projectsRoot = home.appendingPathComponent("Projects", isDirectory: true)
        try mkdir(projectsRoot)
        let linkURL = projectsRoot.appendingPathComponent("linked-app")
        let targetURL = dev.appendingPathComponent("real-app")
        try FileManager.default.createSymbolicLink(at: linkURL,
                                                    withDestinationURL: targetURL)

        let hits = NodeModulesScanner.detect(home: home)
        XCTAssertEqual(hits.count, 1,
                       "软链指向已被扫到的真实工程不应重复产 hit，实际 hits=\(hits.map(\.projectName))")
        XCTAssertEqual(hits.first?.projectName, "real-app")
    }

    /// 自指/循环软链不应导致 walk 卡死。给 detect 加一个总耗时上限做兜底。
    func test_detect_循环软链_不应卡死() throws {
        let home = try makeTempHome()
        let dev = home.appendingPathComponent("Developer", isDirectory: true)
        try mkdir(dev)

        // 造一个工程目录，并在其中放一个指回父目录的软链 loop -> ..
        let proj = dev.appendingPathComponent("looped-app", isDirectory: true)
        try mkdir(proj)
        let loop = proj.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop,
                                                    withDestinationURL: proj)
        // 真实 node_modules 也给一份，确保 hit 正常
        try makeProjectWithNodeModules("looped-app", in: dev)

        let start = Date()
        let hits = NodeModulesScanner.detect(home: home)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "循环软链应被 visited realpath 截断，5s 内必须返回")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.projectName, "looped-app")
    }
}
