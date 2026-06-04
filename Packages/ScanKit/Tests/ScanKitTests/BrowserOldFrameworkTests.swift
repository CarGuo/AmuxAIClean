import XCTest
@testable import ScanKit

/// BrowserOldFrameworkScanner 单元测试（Step 12C / AUDIT §4.2 P1 / line 117 + 435）。
///
/// macOS Chrome / Edge / Brave / Chromium 系浏览器在 Framework bundle 里使用
/// **多版本并存 + Current 软链** 的标准布局：
///
/// ```
/// /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/
/// ├── Versions/
/// │   ├── 124.0.6367.207/      ← 旧版本（safe 候选）
/// │   ├── 125.0.6422.142/      ← 旧版本（safe 候选）
/// │   ├── 126.0.6478.127/      ← 当前版本（**不动**）
/// │   └── Current -> 126.0.6478.127
/// └── (Resources / Helpers / Libraries 顶层软链均指向 Current/...)
/// ```
///
/// 与 `VersionsScanner` 的 `versions/current` 小写布局相比，唯一差异是大小写：
/// 浏览器 Framework 用首字大写的 `Versions / Current`。本扫描器是 VersionsScanner
/// 面向浏览器场景的薄封装：注入 `Versions / Current` 大写默认值 + 多 framework 批量。
///
/// 安全护栏（继承 VersionsScanner）：
/// - Current 软链落点不在 Versions/ 内 → 整个 framework 不识别（保守）；
/// - Current 所指版本 → **永远跳过**（不会出现在 hits）；
/// - 跨卷不下钻；只识别目录版本（不动文件 / 软链本身）。
final class BrowserOldFrameworkTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrowserOldFrameworkTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Fixture helpers

    /// 在 `parent` 下铺一个完整的 Framework：
    /// ```
    /// <parent>/<frameworkName>.framework/
    ///   Versions/<v>...
    ///   Versions/Current -> <activeVersion>
    /// ```
    @discardableResult
    private func makeFramework(
        in parent: URL,
        name: String,
        versions: [String],
        active: String
    ) throws -> URL {
        let fm = FileManager.default
        let framework = parent.appendingPathComponent(name, isDirectory: true)
        let versionsDir = framework.appendingPathComponent("Versions", isDirectory: true)
        for v in versions {
            try fm.createDirectory(at: versionsDir.appendingPathComponent(v),
                                   withIntermediateDirectories: true)
        }
        let link = versionsDir.appendingPathComponent("Current")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: active)
        return framework
    }

    // MARK: - 1. happy path：单 Chrome Framework 识别 N-1 个旧版本

    func test_chrome_framework_returns_old_versions_only() throws {
        let frameworks = tempRoot
            .appendingPathComponent("Google Chrome.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let fw = try makeFramework(
            in: frameworks,
            name: "Google Chrome Framework.framework",
            versions: ["124.0.6367.207", "125.0.6422.142", "126.0.6478.127"],
            active: "126.0.6478.127"
        )

        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [fw])
        )
        XCTAssertEqual(hits.count, 2,
                       "应识别 2 个旧版本（不含 Current 所指 126），得到 \(hits)")
        let names = Set(hits.map(\.versionName))
        XCTAssertEqual(names, ["124.0.6367.207", "125.0.6422.142"])
        XCTAssertTrue(hits.allSatisfy { $0.activeVersion == "126.0.6478.127" })
        XCTAssertFalse(hits.contains { $0.versionName == "126.0.6478.127" },
                       "Current 所指版本绝对不能出现在 hits")
    }

    // MARK: - 2. 多浏览器并行（Chrome + Edge + Brave）

    func test_multiple_browser_frameworks_aggregated() throws {
        let chromeFW = try makeFramework(
            in: try chromeFrameworksDir(),
            name: "Google Chrome Framework.framework",
            versions: ["1.0", "2.0", "3.0"], active: "3.0")
        let edgeFW = try makeFramework(
            in: try edgeFrameworksDir(),
            name: "Microsoft Edge Framework.framework",
            versions: ["a.0", "b.0"], active: "b.0")
        let braveFW = try makeFramework(
            in: try braveFrameworksDir(),
            name: "Brave Browser Framework.framework",
            versions: ["x.0", "y.0", "z.0", "w.0"], active: "w.0")

        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(
                frameworkRoots: [chromeFW, edgeFW, braveFW]
            ))
        // chrome 2 + edge 1 + brave 3 = 6
        XCTAssertEqual(hits.count, 6, "得到 \(hits)")
        let byFramework = Dictionary(grouping: hits, by: { $0.frameworkRoot.lastPathComponent })
        XCTAssertEqual(byFramework["Google Chrome Framework.framework"]?.count, 2)
        XCTAssertEqual(byFramework["Microsoft Edge Framework.framework"]?.count, 1)
        XCTAssertEqual(byFramework["Brave Browser Framework.framework"]?.count, 3)
    }

    private func chromeFrameworksDir() throws -> URL {
        let url = tempRoot
            .appendingPathComponent("Google Chrome.app/Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func edgeFrameworksDir() throws -> URL {
        let url = tempRoot
            .appendingPathComponent("Microsoft Edge.app/Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func braveFrameworksDir() throws -> URL {
        let url = tempRoot
            .appendingPathComponent("Brave Browser.app/Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 3. Current 软链落点不在 Versions/ 内 → 保守不识别

    func test_current_pointing_outside_versions_returns_empty() throws {
        let frameworks = try chromeFrameworksDir()
        let framework = frameworks.appendingPathComponent(
            "Google Chrome Framework.framework", isDirectory: true)
        let versions = framework.appendingPathComponent("Versions", isDirectory: true)
        for v in ["1.0", "2.0", "3.0"] {
            try FileManager.default.createDirectory(at: versions.appendingPathComponent(v),
                                                    withIntermediateDirectories: true)
        }
        // Current 软链指到 Versions/ 之外的位置
        let bogus = framework.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        let link = versions.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "../Helpers")

        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [framework])
        )
        XCTAssertTrue(hits.isEmpty,
                      "Current 软链落点不在 Versions/ 内时整个 framework 不识别，得到 \(hits)")
    }

    // MARK: - 4. Current 软链缺失 → 保守不识别

    func test_no_current_symlink_returns_empty() throws {
        let frameworks = try chromeFrameworksDir()
        let framework = frameworks
            .appendingPathComponent("Google Chrome Framework.framework", isDirectory: true)
        let versions = framework.appendingPathComponent("Versions", isDirectory: true)
        for v in ["1.0", "2.0"] {
            try FileManager.default.createDirectory(at: versions.appendingPathComponent(v),
                                                    withIntermediateDirectories: true)
        }
        // 故意不创建 Current
        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [framework])
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 5. 真实场景：5 个旧版本（AUDIT line 437 验证基线）

    /// AUDIT line 437：装有 Chrome 多年的机器，扫 Chrome Framework 应识别 ~5 个旧版。
    func test_aged_chrome_with_5_old_versions() throws {
        let fw = try makeFramework(
            in: try chromeFrameworksDir(),
            name: "Google Chrome Framework.framework",
            versions: [
                "118.0.5993.117", "119.0.6045.199", "120.0.6099.234",
                "121.0.6167.184", "122.0.6261.94", "123.0.6312.122",
            ],
            active: "123.0.6312.122"
        )
        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [fw])
        )
        XCTAssertEqual(hits.count, 5,
                       "AUDIT line 437：~5 个旧版本（不含 active 共 6 个）")
        XCTAssertFalse(hits.contains { $0.versionName == "123.0.6312.122" })
    }

    // MARK: - 6. Edge Updater 同款布局也支持

    /// Edge Auto Updater 在 `~/Library/Microsoft/EdgeUpdater/.../`
    /// 也是同款 Versions/Current 布局，应被同一扫描器命中。
    func test_edge_updater_old_versions() throws {
        let updaterRoot = tempRoot
            .appendingPathComponent("Library/Microsoft/EdgeUpdater", isDirectory: true)
        try FileManager.default.createDirectory(at: updaterRoot, withIntermediateDirectories: true)
        let fw = try makeFramework(
            in: updaterRoot,
            name: "MicrosoftEdgeUpdater.framework",
            versions: ["1.3.131.27", "1.3.137.45", "1.3.143.7"],
            active: "1.3.143.7"
        )
        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [fw])
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.versionName)),
                       ["1.3.131.27", "1.3.137.45"])
    }

    // MARK: - 7. Hit 元数据完整性

    func test_hit_metadata_is_complete() throws {
        let fw = try makeFramework(
            in: try chromeFrameworksDir(),
            name: "Google Chrome Framework.framework",
            versions: ["10.0", "20.0"], active: "20.0"
        )
        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [fw])
        )
        XCTAssertEqual(hits.count, 1)
        let h = hits[0]
        XCTAssertEqual(h.versionName, "10.0")
        XCTAssertEqual(h.activeVersion, "20.0")
        XCTAssertEqual(h.frameworkRoot.standardizedFileURL.resolvingSymlinksInPath(),
                       fw.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(h.url.lastPathComponent, "10.0")
        XCTAssertEqual(h.id, h.url.path)
    }

    // MARK: - 8. 边界：framework 路径不存在

    func test_missing_framework_root_returns_empty() {
        let ghost = tempRoot
            .appendingPathComponent("Ghost.framework", isDirectory: true)
        let hits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [ghost])
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 9. async actor 形态与同步形态结果一致

    func test_async_discover_matches_sync_detect() async throws {
        let fw = try makeFramework(
            in: try chromeFrameworksDir(),
            name: "Google Chrome Framework.framework",
            versions: ["1.0", "2.0", "3.0"], active: "3.0"
        )
        let scanner = BrowserOldFrameworkScanner(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [fw])
        )
        let asyncHits = await scanner.discover()
        let syncHits = BrowserOldFrameworkScanner.detect(
            options: BrowserOldFrameworkScanner.Options(frameworkRoots: [fw])
        )
        XCTAssertEqual(Set(asyncHits.map(\.versionName)),
                       Set(syncHits.map(\.versionName)))
    }
}
