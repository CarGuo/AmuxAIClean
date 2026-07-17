import XCTest
import Darwin
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

    func testImmediateAndNaNTimeoutStopBeforeRootIO() async {
        for timeout in [TimeInterval.zero, TimeInterval.nan] {
            let missingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevArtifactDeadline-\(UUID().uuidString)")
            let result = await DevArtifactScanner(options: .init(
                enabledRuleIDs: ["web.node_modules"],
                timeoutSeconds: timeout
            )).discoverWithMetadata(home: missingRoot)

            XCTAssertTrue(result.hits.isEmpty)
            XCTAssertTrue(result.didTimeout)
            XCTAssertFalse(result.didTruncate)
            XCTAssertTrue(
                result.incompleteIssues.isEmpty,
                "立即 deadline 不得先触碰缺失 root 再伪造 I/O partial"
            )
            XCTAssertEqual(result.scannedEntryCount, 0)
        }
    }

    func testSharedTruncationStopsWorkerBeforeStartingNextDirectoryIO() {
        let stopState = DevArtifactStopState(deadline: nil)
        stopState.markTruncated()

        XCTAssertFalse(
            DevArtifactScanner.shouldBeginDirectoryIO(stopState: stopState),
            "另一 worker 已证明截断后，已 pop 的目录也不得再发起一次 open"
        )
    }

    func testDetachedWalkReceivesCallerCancellation() async {
        let started = DevArtifactStartProbe()
        let caller = Task {
            await DevArtifactScanner.runCancellableDetached {
                await started.markStarted()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return Task.isCancelled
            }
        }

        await started.waitUntilStarted()
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
            [ScanIncompleteIssue(
                path: missingRoot.path,
                reason: .enumerationFailed,
                stage: .open,
                posixErrorCode: ENOENT
            )]
        )
        XCTAssertFalse(result.isComplete, "I/O 后的空结果不能伪装成完整的 0 命中")
    }

    /// v2026.07.17 性能证据不能再拿 hits.count 冒充工作量。fixture 的 descriptor
    /// 枚举会观察 project、node_modules 与 package.json 三个 entry，命中后不进入产物树。
    func testDiscoveryReportsDescriptorEntryCountAndElapsed() async throws {
        try mkdir("project/node_modules/dependency")
        try touch("project/package.json")

        let scanOptions = ScanOptions(
            concurrency: 4,
            maxConcurrency: 4,
            staySingleVolume: false,
            mediaAware: false,
            respectTCCSkipList: true
        )
        let scanner = DevArtifactScanner(options: .init(
            enabledRuleIDs: ["web.node_modules"],
            staySingleVolume: false,
            scanOptions: scanOptions
        ))

        let result = await scanner.discoverWithMetadata(home: tempRoot)

        XCTAssertEqual(result.hits.map(\.ruleID), ["web.node_modules"])
        XCTAssertEqual(
            result.scannedEntryCount,
            3,
            "命中 node_modules 后必须剪枝，不能把 dependency 伪计为已扫描"
        )
        XCTAssertGreaterThanOrEqual(result.elapsed, 0)
    }

    /// TCC 媒体库 package 必须在打开其 descriptor 前剪枝；它与 ~/Library 一样属于
    /// 开发者产物勘察的业务范围外目录，不应触发权限弹窗，也不应把结果误报成 I/O partial。
    func testPrunesTCCMediaPackageBeforeEntering() async throws {
        let package = try mkdir("Pictures.photoslibrary/project/node_modules/dependency")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try touch("Pictures.photoslibrary/project/package.json")
        let packagePath = tempRoot.appendingPathComponent(
            "Pictures.photoslibrary",
            isDirectory: true
        ).path
        XCTAssertEqual(package.path, packagePath)

        let scanOptions = ScanOptions(
            concurrency: 4,
            maxConcurrency: 4,
            staySingleVolume: false,
            mediaAware: false,
            respectTCCSkipList: true
        )
        let result = await DevArtifactScanner(options: .init(
            enabledRuleIDs: ["web.node_modules"],
            skipLibrary: false,
            staySingleVolume: false,
            scanOptions: scanOptions
        )).discoverWithMetadata(home: tempRoot)

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.incompleteIssues.isEmpty)
        XCTAssertEqual(
            result.scannedEntryCount,
            1,
            "媒体库包的后代不能被 descriptor walker 打开或计入已扫描 entry"
        )
        XCTAssertTrue(result.isComplete)
    }

    /// 恰好 N 个命中不代表发生截断；只有真实观察到第 N+1 个候选后才可置位。
    func testExactHitCapDoesNotInventTruncation() async throws {
        for index in 0..<3 {
            try mkdir("exact-\(index)/node_modules/dependency")
            try touch("exact-\(index)/package.json")
        }
        let result = await DevArtifactScanner(options: .init(
            enabledRuleIDs: ["web.node_modules"],
            staySingleVolume: false,
            maxHits: 3,
            scanOptions: ScanOptions(
                concurrency: 4,
                maxConcurrency: 4,
                staySingleVolume: false,
                mediaAware: false,
                respectTCCSkipList: true
            )
        )).discoverWithMetadata(home: tempRoot)

        XCTAssertEqual(result.hits.count, 3)
        XCTAssertFalse(result.didTruncate)
        XCTAssertTrue(result.isComplete)
    }

    /// descriptor walker 的默认合同不跟随 symlink；目标即便是合法开发项目，也不能
    /// 绕过 frozen identity / no-follow 边界被扫描进来。
    func testDoesNotFollowSymlinkedDirectory() async throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevArtifactExternal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("node_modules/dependency", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: external.appendingPathComponent("package.json").path,
            contents: Data()
        )
        try FileManager.default.createSymbolicLink(
            at: tempRoot.appendingPathComponent("linked-project"),
            withDestinationURL: external
        )

        let result = await DevArtifactScanner(options: .init(
            enabledRuleIDs: ["web.node_modules"],
            staySingleVolume: false,
            scanOptions: ScanOptions(
                concurrency: 4,
                maxConcurrency: 4,
                staySingleVolume: false,
                mediaAware: false,
                respectTCCSkipList: true
            )
        )).discoverWithMetadata(home: tempRoot)

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.scannedEntryCount, 1, "只能观察 symlink 本身，不能进入目标")
    }

    /// 多 descriptor worker 可以同时发现命中，但 streamed callback 必须由 accumulator
    /// 串行交付；每条 hit 只出现一次，最终残余 batch 也必须 flush。
    func testStreamedPartialDeliveryIsSerializedAndLossless() async throws {
        for index in 0..<24 {
            try mkdir("project-\(index)/node_modules/dependency")
            try touch("project-\(index)/package.json")
        }
        let recorder = DevArtifactPartialRecorder()
        let scanner = DevArtifactScanner(options: .init(
            enabledRuleIDs: ["web.node_modules"],
            staySingleVolume: false,
            scanOptions: ScanOptions(
                concurrency: 8,
                maxConcurrency: 8,
                staySingleVolume: false,
                mediaAware: false,
                respectTCCSkipList: true
            )
        ))

        let result = await scanner.discoverWithMetadataStreamed(
            home: tempRoot,
            flushEvery: 3
        ) { batch in
            recorder.record(batch)
        }
        let delivered = recorder.snapshot()

        XCTAssertEqual(delivered.maximumConcurrentCallbacks, 1)
        XCTAssertEqual(delivered.paths.count, 24)
        XCTAssertEqual(Set(delivered.paths).count, delivered.paths.count)
        XCTAssertEqual(Set(delivered.paths), Set(result.hits.map(\.url.path)))
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

private actor DevArtifactStartProbe {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !didStart else { return }
        didStart = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// 测试回调可能运行在任意 descriptor worker；显式加锁使测试本身不引入数据竞争。
private final class DevArtifactPartialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCallbacks = 0
    private var maximumConcurrentCallbacks = 0
    private var paths: [String] = []

    func record(_ hits: [DevArtifactScanner.Hit]) {
        lock.lock()
        activeCallbacks += 1
        maximumConcurrentCallbacks = max(maximumConcurrentCallbacks, activeCallbacks)
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.001)

        lock.lock()
        paths.append(contentsOf: hits.map(\.url.path))
        activeCallbacks -= 1
        lock.unlock()
    }

    func snapshot() -> (maximumConcurrentCallbacks: Int, paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (maximumConcurrentCallbacks, paths)
    }
}
