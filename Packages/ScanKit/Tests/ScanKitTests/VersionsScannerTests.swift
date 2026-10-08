import XCTest
@testable import ScanKit

/// VersionsScanner（versions/* 旧版本识别）单元测试（Step 8-5）。
///
/// 模拟 rustup / pyenv / nvm 等工具链的 `current` → `versions/<X>` 软链布局，
/// 验证：
/// 1. 命中：current 落点正好在 versions/，旧版本 sibling 正确返回；
/// 2. current 缺失 → 整树不识别（保守）；
/// 3. current 落点不在 versions/ → 整树不识别（保守）；
/// 4. current 软链所指版本 **永远不**出现在 hits（防误删激活版本）。
final class VersionsScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VersionsScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// 在 root 下铺 versions/<names...> + current 软链 -> versions/<active>
    private func makeToolchain(
        root: URL,
        versionsDirName: String = "versions",
        currentName: String = "current",
        versions: [String],
        active: String,
        currentTargetIsRelative: Bool = true
    ) throws {
        let fm = FileManager.default
        let versionsDir = root.appendingPathComponent(versionsDirName, isDirectory: true)
        for v in versions {
            try fm.createDirectory(at: versionsDir.appendingPathComponent(v),
                                   withIntermediateDirectories: true)
        }
        let link = root.appendingPathComponent(currentName)
        let target: String
        if currentTargetIsRelative {
            target = "\(versionsDirName)/\(active)"
        } else {
            target = versionsDir.appendingPathComponent(active).path
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    }

    /// 1) 经典 happy path：rustup 风格 toolchains/<X> + current -> toolchains/1.78.0
    func testHappyPathRustupLikeLayout() throws {
        let root = tempRoot.appendingPathComponent("rustup", isDirectory: true)
        try makeToolchain(
            root: root,
            versionsDirName: "toolchains",
            currentName: "current",
            versions: ["1.76.0", "1.77.0", "1.78.0"],
            active: "1.78.0"
        )
        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertEqual(hits.count, 2, "应识别 1.76.0 与 1.77.0 共 2 个旧版本，得到 \(hits)")
        let names = Set(hits.map(\.versionName))
        XCTAssertEqual(names, ["1.76.0", "1.77.0"])
        XCTAssertTrue(hits.allSatisfy { $0.activeVersion == "1.78.0" })
        // active 永远不能在 hits
        XCTAssertFalse(hits.contains { $0.versionName == "1.78.0" },
                       "current 软链所指版本绝对不能出现在 hits")
    }

    /// 2) current 缺失：保守不识别整树。
    func testNoCurrentSymlinkReturnsEmpty() throws {
        let root = tempRoot.appendingPathComponent("noCurrent", isDirectory: true)
        let versions = root.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("1.0.0"),
                                                withIntermediateDirectories: true)
        // 故意不创建 current 软链
        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertTrue(hits.isEmpty, "缺 current 时必须保守不识别")
    }

    /// 3) current 落点不在 versions/ 内（落到 plugin 内部，asdf 风格）→ 保守不识别。
    func testCurrentTargetOutsideVersionsReturnsEmpty() throws {
        let root = tempRoot.appendingPathComponent("asdf", isDirectory: true)
        // 建 versions/foo + current -> ../external/foo
        let versions = root.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("foo"),
                                                withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external/foo")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "external/foo")

        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertTrue(hits.isEmpty, "current 落点不在 versions/ 内时必须保守不识别")
    }

    /// 4) 兼容 default 软链名 + 绝对路径软链。
    func testAlternativeNamesAndAbsoluteSymlink() throws {
        let root = tempRoot.appendingPathComponent("pyenv", isDirectory: true)
        try makeToolchain(
            root: root,
            versionsDirName: "versions",
            currentName: "default",
            versions: ["3.10.0", "3.11.0", "3.12.0"],
            active: "3.12.0",
            currentTargetIsRelative: false
        )
        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.versionName)), ["3.10.0", "3.11.0"])
    }

    /// 5) versions/ 下出现的软链子项不被识别为旧版本（防 versions/foo -> versions/active 等套娃）。
    func testSymlinkChildrenSkipped() throws {
        let root = tempRoot.appendingPathComponent("nvm", isDirectory: true)
        try makeToolchain(
            root: root,
            versionsDirName: "versions",
            currentName: "current",
            versions: ["v18.0.0", "v20.0.0"],
            active: "v20.0.0"
        )
        // 在 versions/ 下增加一个软链 alias-stable -> v20.0.0
        let alias = root.appendingPathComponent("versions/alias-stable")
        try FileManager.default.createSymbolicLink(atPath: alias.path,
                                                   withDestinationPath: "v20.0.0")

        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertEqual(hits.count, 1, "alias-stable 是软链不算旧版本，期望仅 v18.0.0 一项")
        XCTAssertEqual(hits.first?.versionName, "v18.0.0")
    }

    /// 6) actor 入口与同步入口语义一致。
    func testActorEntrypointMatchesSync() async throws {
        let root = tempRoot.appendingPathComponent("rustup-actor", isDirectory: true)
        try makeToolchain(
            root: root,
            versionsDirName: "toolchains",
            versions: ["1.0.0", "2.0.0"],
            active: "2.0.0"
        )
        let scanner = VersionsScanner()
        let actorHits = await scanner.discover(toolchainRoot: root)
        let syncHits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertEqual(Set(actorHits.map(\.versionName)),
                       Set(syncHits.map(\.versionName)))
    }

    /// 7) current 为悬空软链（指向不存在的版本）时，必须保守返回空，绝不能把所有真实版本都当旧版删光。
    func testDanglingCurrentSymlinkReturnsEmpty() throws {
        let root = tempRoot.appendingPathComponent("dangling", isDirectory: true)
        try makeToolchain(
            root: root,
            versionsDirName: "versions",
            currentName: "current",
            versions: ["1.0.0", "2.0.0"],
            active: "9.9.9-missing"
        )

        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertTrue(hits.isEmpty, "current 指向不存在的目标时必须返回空，防止全删真实版本")
    }

    /// 8) 多级软链（current -> versions/stable -> 2.0.0）应解析到最终真实版本目录并保护激活版本。
    func testChainedCurrentSymlinkResolvesActiveVersionAndProtectsAllChainMembers() throws {
        let root = tempRoot.appendingPathComponent("chained", isDirectory: true)
        let fm = FileManager.default
        let versionsDir = root.appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versionsDir.appendingPathComponent("1.0.0"), withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsDir.appendingPathComponent("2.0.0"), withIntermediateDirectories: true)
        let stableAlias = versionsDir.appendingPathComponent("stable")
        try fm.createSymbolicLink(atPath: stableAlias.path, withDestinationPath: "2.0.0")
        let currentLink = root.appendingPathComponent("current")
        try fm.createSymbolicLink(atPath: currentLink.path, withDestinationPath: "versions/stable")

        let hits = VersionsScanner.detect(toolchainRoot: root)
        XCTAssertEqual(hits.map(\.versionName), ["1.0.0"])
        XCTAssertEqual(hits.first?.activeVersion, "2.0.0")
    }
}
