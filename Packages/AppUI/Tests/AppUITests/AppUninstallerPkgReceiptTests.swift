import XCTest
@testable import AppUI
@testable import ScanKit

/// M4-T3 集成测试：[AppUninstaller.pkgReceiptCandidates](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift#L254-L280)
///
/// 覆盖：
/// 1. FakePkgutilRunner 喂入 1 个 receipt + 2 个相对路径 → 真实存在的 1 条入候选、matchReason=.pkgReceipt(pkgID)
/// 2. fileExists 过滤：receipt 列了一条不存在的路径 → 不入候选
/// 3. dedup：seenPaths 已含 receipt 路径 → 不重复添加
/// 4. pkgutilScanner=nil（in-memory home 默认决策）→ 整路完全跳过、无副作用
final class AppUninstallerPkgReceiptTests: XCTestCase {

    private struct FakeFM: FileManagerSnapshotting {
        let snapshots: [String: FSSnapshot]
        func firstLevelEntries(at path: String) -> [FSEntry]? { nil }
        func snapshot(at path: String) -> FSSnapshot {
            snapshots[path] ?? .init(bytes: 0, fileCount: 0)
        }
    }

    private struct FakePkgRunner: PkgutilRunning {
        let pkgs: [String]
        let infoByPkg: [String: PkgutilPackageInfo]
        let filesByPkg: [String: [String]]
        func listPackages(matchingRegex: String?) -> [String]? { pkgs }
        func packageInfo(pkgID: String) -> PkgutilPackageInfo? { infoByPkg[pkgID] }
        func files(pkgID: String) -> [String]? { filesByPkg[pkgID] }
    }

    private let meta = AppMetadata(
        bundleID: "com.acme.demo",
        bundleVendor: "com.acme",
        appName: "Demo",
        executableName: nil
    )

    // MARK: - 1 + 2 真实路径 + fileExists 过滤

    func test_pkgReceipt命中真实路径入候选_且过滤掉不存在的路径() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 真实文件
        let realFile = tmp.appendingPathComponent("real.txt")
        try Data("hi".utf8).write(to: realFile)
        // 构造 receipt：把 root 设为 tmp 路径，relativePaths 含 1 真 1 假
        let info = PkgutilPackageInfo(pkgID: "com.acme.demo.pkg",
                                      volume: "/", location: String(tmp.path.dropFirst()),
                                      installTime: nil)
        let runner = FakePkgRunner(
            pkgs: ["com.acme.demo.pkg"],
            infoByPkg: ["com.acme.demo.pkg": info],
            filesByPkg: ["com.acme.demo.pkg": ["real.txt", "ghost.txt"]]
        )
        let scanner = PkgutilReceiptsScanner(runner: runner)
        let unins = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: FakeFM(snapshots: [realFile.path: .init(bytes: 2, fileCount: 1)]),
            pkgutilScanner: scanner
        )

        var seen: Set<String> = []
        let cands = unins.pkgReceiptCandidates(for: meta, seenPaths: &seen)
        XCTAssertEqual(cands.count, 1, "只应有真实存在的 1 条候选")
        XCTAssertEqual(cands[0].path, realFile.path)
        XCTAssertEqual(cands[0].bytes, 2)
        if case .pkgReceipt(let pkgID) = cands[0].matchReason {
            XCTAssertEqual(pkgID, "com.acme.demo.pkg")
        } else {
            XCTFail("matchReason 应为 .pkgReceipt")
        }
        XCTAssertTrue(seen.contains(realFile.path))
        XCTAssertTrue(seen.contains((tmp.appendingPathComponent("ghost.txt")).path),
                      "ghost 路径应也被 insert 进 seen，避免后续路径重复尝试")
    }

    // MARK: - 3 dedup

    func test_pkgReceipt路径已在seenPaths_不重复添加() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let realFile = tmp.appendingPathComponent("real.txt")
        try Data("hi".utf8).write(to: realFile)
        let info = PkgutilPackageInfo(pkgID: "com.acme.demo.pkg",
                                      volume: "/", location: String(tmp.path.dropFirst()),
                                      installTime: nil)
        let runner = FakePkgRunner(
            pkgs: ["com.acme.demo.pkg"],
            infoByPkg: ["com.acme.demo.pkg": info],
            filesByPkg: ["com.acme.demo.pkg": ["real.txt"]]
        )
        let scanner = PkgutilReceiptsScanner(runner: runner)
        let unins = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: FakeFM(snapshots: [realFile.path: .init(bytes: 2, fileCount: 1)]),
            pkgutilScanner: scanner
        )

        var seen: Set<String> = [realFile.path]
        let cands = unins.pkgReceiptCandidates(for: meta, seenPaths: &seen)
        XCTAssertTrue(cands.isEmpty, "已存在于 seen 的路径不应再入候选")
    }

    // MARK: - 4 nil scanner（默认 in-memory home 决策）

    func test_pkgutilScanner为nil_跳过整路_无候选无崩溃() {
        let unins = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: FakeFM(snapshots: [:])
            // pkgutilScanner 默认 nil（因为 home != NSHomeDirectory()）
        )
        var seen: Set<String> = []
        XCTAssertNil(unins.pkgutilScanner)
        XCTAssertTrue(unins.pkgReceiptCandidates(for: meta, seenPaths: &seen).isEmpty)
        XCTAssertTrue(seen.isEmpty)
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-receipt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
