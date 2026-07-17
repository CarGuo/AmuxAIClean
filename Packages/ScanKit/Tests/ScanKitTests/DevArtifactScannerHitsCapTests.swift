import XCTest
@testable import ScanKit

/// v1.3 P0-D：DevArtifactScanner 命中上限截断 / 兄弟扩展名兜底 / 父路径后缀兜底 的端到端测试。
///
/// 三件事必须真实落地：
/// 1. 最多保留 `Options.maxHits` 条；只有真实观察到第 N+1 条时才证明发生截断并置位
///    `DiscoverResult.didTruncate=true`，恰好 N 条仍是完整结果；
/// 2. `py.pycache` 在没有 setup.py 等精确 marker、但同级有 `.py` 文件时仍能被命中（兄弟扩展名兜底）；
/// 3. `apple.xcuserdata` 在没有任何兄弟 marker、但父路径以 `.xcodeproj` 结尾时仍能被命中（父路径后缀兜底）。
final class DevArtifactScannerHitsCapTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DevArtifactHitsCap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @discardableResult
    private func mkdir(_ relPath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relPath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ relPath: String) throws {
        let url = tempRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    // MARK: - 用例 1：命中数硬上限截断

    /// 构造 50 个合法 node_modules 命中，把 maxHits 调到 10，断言：
    /// - hits.count == 10 严格等于上限
    /// - 因真实存在第 11 个候选，didTruncate == true
    /// - didTimeout == false（绝不能误把截断报成超时）
    func test_命中达硬上限_截断且didTruncate为真() async throws {
        // 50 个 fixture 项目，每个：proj_i/package.json + proj_i/node_modules/foo
        for i in 0..<50 {
            try mkdir("proj_\(i)/node_modules/foo")
            try touch("proj_\(i)/package.json")
        }

        let opts = DevArtifactScanner.Options(
            enabledRuleIDs: DevArtifactRules.allIDs,
            timeoutSeconds: 60,
            skipLibrary: true,
            staySingleVolume: false, // 跨卷限制对 tmp 路径无意义，关掉避免环境差异
            maxHits: 10
        )
        let scanner = DevArtifactScanner(options: opts)
        let result = await scanner.discoverWithMetadata(home: tempRoot)

        XCTAssertEqual(result.hits.count, 10, "命中应严格截断到 maxHits=10")
        XCTAssertTrue(result.didTruncate, "命中达上限必须置位 didTruncate")
        XCTAssertFalse(result.didTimeout, "纯命中截断不应被报成超时")
    }

    /// 命中数远低于上限时不应触发截断标志。
    func test_命中未达上限_didTruncate为假() async throws {
        for i in 0..<3 {
            try mkdir("p\(i)/node_modules/x")
            try touch("p\(i)/package.json")
        }

        let opts = DevArtifactScanner.Options(
            enabledRuleIDs: DevArtifactRules.allIDs,
            timeoutSeconds: 60,
            skipLibrary: true,
            staySingleVolume: false,
            maxHits: 200
        )
        let result = await DevArtifactScanner(options: opts).discoverWithMetadata(home: tempRoot)

        XCTAssertGreaterThanOrEqual(result.hits.count, 3)
        XCTAssertLessThan(result.hits.count, 200)
        XCTAssertFalse(result.didTruncate, "未到上限不能报截断")
    }

    // MARK: - 用例 2：兄弟扩展名兜底（__pycache__）

    /// `__pycache__` 的精确 markers 都不存在，但同级有 a.py → 兄弟扩展名兜底命中。
    func test_pycache兄弟扩展名兜底命中() async throws {
        try mkdir("pyproj/__pycache__")
        try touch("pyproj/a.py") // 唯一兜底：.py 兄弟
        // 不写 __init__.py / pyproject.toml / setup.py / requirements.txt / Pipfile

        let opts = DevArtifactScanner.Options(
            enabledRuleIDs: ["py.pycache"],
            timeoutSeconds: 60,
            skipLibrary: true,
            staySingleVolume: false,
            maxHits: 200
        )
        let result = await DevArtifactScanner(options: opts).discoverWithMetadata(home: tempRoot)

        XCTAssertTrue(result.hits.contains { $0.ruleID == "py.pycache"
                                              && $0.url.lastPathComponent == "__pycache__" },
                      "兄弟扩展名（.py）兜底应能命中 __pycache__")
    }

    /// `__pycache__` 同级既无 marker 文件也无任何 .py → 不命中（避免误伤）。
    func test_pycache同级无py也无marker_不命中() async throws {
        try mkdir("notpy/__pycache__")
        try touch("notpy/readme.md")

        let opts = DevArtifactScanner.Options(
            enabledRuleIDs: ["py.pycache"],
            timeoutSeconds: 60,
            skipLibrary: true,
            staySingleVolume: false,
            maxHits: 200
        )
        let result = await DevArtifactScanner(options: opts).discoverWithMetadata(home: tempRoot)

        XCTAssertFalse(result.hits.contains { $0.url.lastPathComponent == "__pycache__"
                                                && $0.url.path.hasPrefix(tempRoot.appendingPathComponent("notpy").path) },
                       "同级既无 marker 也无 .py 时不应命中 __pycache__")
    }

    // MARK: - 用例 3：父路径后缀兜底（xcuserdata）

    /// `xcuserdata` 父目录以 `.xcodeproj` 结尾 → 即便兄弟为空也命中。
    func test_xcuserdata父路径后缀兜底命中() async throws {
        try mkdir("MyApp.xcodeproj/xcuserdata")

        let opts = DevArtifactScanner.Options(
            enabledRuleIDs: ["apple.xcuserdata"],
            timeoutSeconds: 60,
            skipLibrary: true,
            staySingleVolume: false,
            maxHits: 200
        )
        let result = await DevArtifactScanner(options: opts).discoverWithMetadata(home: tempRoot)

        XCTAssertTrue(result.hits.contains { $0.ruleID == "apple.xcuserdata"
                                              && $0.url.lastPathComponent == "xcuserdata" },
                      "父路径 .xcodeproj 后缀应能兜底命中 xcuserdata")
    }

    /// `xcuserdata` 父目录不是 .xcodeproj/.xcworkspace → 不命中。
    func test_xcuserdata父路径非xcodeproj_不命中() async throws {
        try mkdir("RandomFolder/xcuserdata")

        let opts = DevArtifactScanner.Options(
            enabledRuleIDs: ["apple.xcuserdata"],
            timeoutSeconds: 60,
            skipLibrary: true,
            staySingleVolume: false,
            maxHits: 200
        )
        let result = await DevArtifactScanner(options: opts).discoverWithMetadata(home: tempRoot)

        XCTAssertFalse(result.hits.contains { $0.url.lastPathComponent == "xcuserdata"
                                                && $0.url.path.hasPrefix(tempRoot.appendingPathComponent("RandomFolder").path) },
                       "父路径不是 .xcodeproj/.xcworkspace 时不应命中 xcuserdata")
    }
}
