import XCTest
@testable import ScanKit

/// DevArtifactScanner 在 fixture 目录上的命中 / 剪枝 / 兄弟兜底验证。
///
/// 构造：每个用例临时在 `tmp/<UUID>/home` 下铺真实目录树，传给 `discover(home:)`，
/// 比对返回的 `[Hit]`。`staySingleVolume` 默认为 true 不影响（同卷）。
/// `skipLibrary=true` 默认开启，所以不能把测试目录建在 home/Library 子树。
final class DevArtifactScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DevArtifactScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// 工具：在 fakeHome 下创建 dir，返回 URL。
    @discardableResult
    private func mkdir(_ relPath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relPath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 工具：写一个空文件。
    private func touch(_ relPath: String) throws {
        let url = tempRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    /// node_modules 兄弟里有 package.json → 命中。
    func testHitsNodeModulesWithSiblingPackageJson() async throws {
        try mkdir("project/node_modules/foo")
        try touch("project/package.json")

        let scanner = DevArtifactScanner()
        let hits = await scanner.discover(home: tempRoot)
        XCTAssertTrue(hits.contains { $0.url.lastPathComponent == "node_modules" },
                      "兄弟里有 package.json 时 node_modules 应被命中：\(hits)")
    }

    /// node_modules 兄弟里**没有** package.json → 不命中（兜底兜住误伤）。
    func testSkipsNodeModulesWithoutSiblingPackageJson() async throws {
        try mkdir("orphan/node_modules/anything")
        // 没建 package.json

        let scanner = DevArtifactScanner()
        let hits = await scanner.discover(home: tempRoot)
        XCTAssertFalse(hits.contains { $0.ruleID.hasPrefix("node_modules") &&
                                        $0.url.path.hasPrefix(tempRoot.appendingPathComponent("orphan").path) },
                       "兄弟里没有 package.json 不应命中孤立 node_modules：\(hits)")
    }

    /// 命中后整棵剪枝：node_modules 内若再有 node_modules（多套依赖嵌套），不应再返回。
    func testPrunesNestedAfterHit() async throws {
        try mkdir("project/node_modules/foo/node_modules/bar")
        try touch("project/package.json")
        // 内层 node_modules 没自己的 package.json 兜底也不该命中——更重要的是被剪枝跳过。

        let scanner = DevArtifactScanner()
        let hits = await scanner.discover(home: tempRoot)
        let nodeHits = hits.filter { $0.url.lastPathComponent == "node_modules" }
        XCTAssertEqual(nodeHits.count, 1,
                       "命中后应整棵剪枝，嵌套 node_modules 不应被重复收集：\(nodeHits.map(\.url.path))")
    }

    /// build/ 必须有兄弟里的 build.gradle / pubspec.yaml / pom.xml 才命中。
    func testBuildHitsOnlyWithGradleSibling() async throws {
        try mkdir("randomFolder/build/output")              // 无脚手架，不应命中
        try mkdir("androidApp/app/build/intermediates")
        try touch("androidApp/app/build.gradle")            // 有脚手架

        let scanner = DevArtifactScanner()
        let hits = await scanner.discover(home: tempRoot)
        let buildHits = hits.filter { $0.url.lastPathComponent == "build" }
        XCTAssertEqual(buildHits.count, 1,
                       "只有 androidApp 下的 build/ 应命中，randomFolder/build 不应命中：\(buildHits.map(\.url.path))")
        XCTAssertEqual(buildHits.first?.url.path,
                       tempRoot.appendingPathComponent("androidApp/app/build").path)
    }

    /// CMake 常见的 `build/` 必须由同级 CMakeLists.txt 兜底，不能误伤随机 build 目录。
    func testCMakeBuildHitsOnlyWithCMakeListsSibling() async throws {
        try mkdir("randomNative/build/output")
        try mkdir("cmakeProject/build/CMakeFiles")
        try touch("cmakeProject/CMakeLists.txt")

        let scanner = DevArtifactScanner(options: .init(enabledRuleIDs: ["native.cmake_build_dir"]))
        let hits = await scanner.discover(home: tempRoot)

        XCTAssertEqual(hits.map(\.ruleID), ["native.cmake_build_dir"])
        XCTAssertEqual(hits.first?.url.path,
                       tempRoot.appendingPathComponent("cmakeProject/build").path)
    }

    /// Meson 默认 `builddir/` 必须由同级 meson.build 兜底。
    func testMesonBuilddirHitsOnlyWithMesonBuildSibling() async throws {
        try mkdir("randomMeson/builddir/meson-private")
        try mkdir("mesonProject/builddir/meson-private")
        try touch("mesonProject/meson.build")

        let scanner = DevArtifactScanner(options: .init(enabledRuleIDs: ["native.meson_builddir"]))
        let hits = await scanner.discover(home: tempRoot)

        XCTAssertEqual(hits.map(\.ruleID), ["native.meson_builddir"])
        XCTAssertEqual(hits.first?.url.path,
                       tempRoot.appendingPathComponent("mesonProject/builddir").path)
    }

    /// 启用规则集合为空 → 直接返回 0 命中（短路）。
    func testEmptyRuleSetReturnsZero() async throws {
        try mkdir("project/node_modules/foo")
        try touch("project/package.json")

        let scanner = DevArtifactScanner(options: .init(enabledRuleIDs: []))
        let hits = await scanner.discover(home: tempRoot)
        XCTAssertTrue(hits.isEmpty, "enabledRuleIDs 为空应返回 0 命中，得到 \(hits.count)")
    }

    /// skipLibrary=true 时，~/Library 子树不应被命中。
    func testSkipsLibrary() async throws {
        try mkdir("Library/Caches/SomeApp/node_modules/foo")
        try touch("Library/Caches/SomeApp/package.json")

        let scanner = DevArtifactScanner(options: .init(skipLibrary: true))
        let hits = await scanner.discover(home: tempRoot)
        XCTAssertFalse(hits.contains { $0.url.path.contains("/Library/") },
                       "Library 子树应被跳过，得到：\(hits.map(\.url.path))")
    }

    /// 关闭 enabledRuleIDs 中某条规则后，对应目录不应命中（仍命中其他规则）。
    func testDisabledRuleNotHit() async throws {
        try mkdir("project/node_modules/foo")
        try touch("project/package.json")
        try mkdir("rust_project/target/debug")
        try touch("rust_project/Cargo.toml")

        // 仅启用 node_modules 相关规则，关闭 target 相关
        let nodeRuleIDs = Set(DevArtifactRules.rules(for: "node_modules").map(\.id))
        let scanner = DevArtifactScanner(options: .init(enabledRuleIDs: nodeRuleIDs))
        let hits = await scanner.discover(home: tempRoot)
        XCTAssertTrue(hits.contains { $0.url.lastPathComponent == "node_modules" })
        XCTAssertFalse(hits.contains { $0.url.lastPathComponent == "target" },
                       "target 规则被关闭，不应命中：\(hits.map(\.url.path))")
    }

    func testDefaultDiscoveryHasNoArbitraryTimeout() {
        XCTAssertNil(
            DevArtifactScanner.Options.default.timeoutSeconds,
            "默认勘察必须以完整结果或用户取消收敛，不能在固定秒数后把 partial 当成功"
        )
    }

    func testDetachedWalkReceivesCallerCancellation() async {
        let started = DispatchSemaphore(value: 0)
        let caller = Task {
            await DevArtifactScanner.runCancellableDetached {
                started.signal()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return Task.isCancelled
            }
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        caller.cancel()

        let callerWasCancelled = await caller.value
        XCTAssertTrue(
            callerWasCancelled,
            "取消 discover 调用方必须取消 detached 文件遍历，不能让后台继续占用 IO"
        )
    }

    func testDiscoveryEnumerationFailureProducesIncompleteEvidence() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevArtifactMissing-\(UUID().uuidString)", isDirectory: true)
        let scanner = DevArtifactScanner(options: .init(staySingleVolume: false))

        let result = await scanner.discoverWithMetadata(home: missingRoot)

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(result.didTimeout)
        XCTAssertFalse(result.didTruncate)
        XCTAssertEqual(
            result.incompleteIssues,
            [ScanIncompleteIssue(path: missingRoot.path, reason: .enumerationFailed)]
        )
        XCTAssertFalse(result.isComplete, "I/O 后的空结果不能伪装成完整的 0 命中")
    }

    func testIncompleteReasonRecognizesFoundationAndPOSIXPermissionErrors() {
        XCTAssertEqual(
            DevArtifactScanner.incompleteReason(
                for: CocoaError(.fileReadNoPermission),
                fallback: .enumerationFailed
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            DevArtifactScanner.incompleteReason(
                for: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                fallback: .metadataUnavailable
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            DevArtifactScanner.incompleteReason(
                for: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
                fallback: .metadataUnavailable
            ),
            .metadataUnavailable
        )
    }
}
