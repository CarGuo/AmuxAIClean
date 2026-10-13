import XCTest
@testable import AppUI
import SafetyKit
import Darwin

@MainActor
final class ScanCoordinatorVendorTests: XCTestCase {

    // MARK: - Fixture

    /// 构造一个临时 fake-home，里头有：
    ///   {home}/Library/Caches/com.adobe.Photoshop/(file.bin x N)
    ///   {home}/Library/Caches/com.unrelated.tool/(file.bin x N)
    /// 返回 (home, cachesRoot)；home 已 standardize，避免 /var/folders ↔ /private/var/folders 错位。
    private func makeFixture() throws -> (home: String, cachesRoot: URL) {
        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "AmuxAICleanScanCoordVendor-\(UUID().uuidString)"
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        let caches = home + "/Library/Caches"
        let adobe = caches + "/com.adobe.Photoshop"
        let other = caches + "/com.unrelated.tool"
        try fm.createDirectory(atPath: adobe, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 4096).write(to: URL(fileURLWithPath: adobe + "/cache1.bin"))
        try Data(repeating: 0xBB, count: 4096).write(to: URL(fileURLWithPath: adobe + "/cache2.bin"))
        try Data(repeating: 0xCC, count: 2048).write(to: URL(fileURLWithPath: other + "/log.bin"))
        return (home, URL(fileURLWithPath: caches, isDirectory: true))
    }

    private func cleanup(home: String) {
        try? FileManager.default.removeItem(atPath: home)
    }

    /// 等扫描完成（最长 5s）。
    private func waitFinished(_ coord: ScanCoordinator, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !coord.snapshot.isFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    private func runScan(vendors: [VendorRule], home: String, cachesRoot: URL) async -> ScanSnapshot {
        let coord = ScanCoordinator(vendors: vendors, home: home)
        let category = ScanCategory(
            id: "test.caches",
            title: "test",
            subtitle: "",
            rootPath: cachesRoot.path,
            defaultVerdict: .safe
        )
        coord.scan(category: category)
        await waitFinished(coord)
        return coord.snapshot
    }

    private static let adobeRule = VendorRule(
        name: "Adobe",
        bundleIDPrefix: "com.adobe",
        appSupportSubdir: nil,
        cachesPath: "~/Library/Caches/com.adobe.Photoshop",
        note: "Photoshop 工程缓存，删了下次启动会重建"
    )

    // MARK: - Tests

    /// 命中 vendor 规则的行：vendorName/vendorNote 非空，且名字与规则一致。
    func testVendorHitRowCarriesVendorName() async throws {
        let (home, root) = try makeFixture()
        defer { cleanup(home: home) }

        let snap = await runScan(vendors: [Self.adobeRule], home: home, cachesRoot: root)
        let adobePath = home + "/Library/Caches/com.adobe.Photoshop"

        guard let row = snap.rows.first(where: { $0.id == adobePath }) else {
            XCTFail("未在 snapshot 中找到 vendor 命中行：\(snap.rows.map(\.id))")
            return
        }
        XCTAssertEqual(row.vendorName, "Adobe")
        XCTAssertEqual(row.vendorNote, "Photoshop 工程缓存，删了下次启动会重建")
    }

    /// 未命中 vendor 的行：vendorName/vendorNote 都为 nil。
    func testNonVendorRowHasNilVendorFields() async throws {
        let (home, root) = try makeFixture()
        defer { cleanup(home: home) }

        let snap = await runScan(vendors: [Self.adobeRule], home: home, cachesRoot: root)
        let otherPath = home + "/Library/Caches/com.unrelated.tool"

        guard let row = snap.rows.first(where: { $0.id == otherPath }) else {
            XCTFail("未在 snapshot 中找到未命中行：\(snap.rows.map(\.id))")
            return
        }
        XCTAssertNil(row.vendorName)
        XCTAssertNil(row.vendorNote)
    }

    /// vendor 根目录被 SafetyEngine 强制降级到 .confirm（即使原本走 safeCachePrefixes 该是 .safe）。
    func testVendorRootDowngradedToConfirm() async throws {
        let (home, root) = try makeFixture()
        defer { cleanup(home: home) }

        let snap = await runScan(vendors: [Self.adobeRule], home: home, cachesRoot: root)
        let adobePath = home + "/Library/Caches/com.adobe.Photoshop"
        let otherPath = home + "/Library/Caches/com.unrelated.tool"

        let adobeRow = snap.rows.first { $0.id == adobePath }
        let otherRow = snap.rows.first { $0.id == otherPath }

        XCTAssertEqual(adobeRow?.verdict, .confirm,
                       "命中 vendor 的根目录必须被降级到 confirm（不可默认勾选）")
        // 反向对照：未命中的同级目录在 safeCachePrefixes 之下，依然是 safe
        XCTAssertEqual(otherRow?.verdict, .safe,
                       "未命中 vendor 的兄弟目录应保持 safe，证明降级仅作用于命中行")
        XCTAssertEqual(adobeRow?.defaultSelected, false,
                       "降级后 UI 默认不勾选")
    }

    /// Tree / Large Files 的删除按钮必须读取 ScanCoordinator 当前会话的完整 vendor trie，
    /// 不能只用裸 SafetyEngine 后到执行阶段才被 TrashPipeline 打回。
    func testDeletionSafetyEvaluationUsesSessionVendorTrieForDescendants() {
        let home = "/Users/tester"
        let androidRule = VendorRule(
            name: "Android SDK",
            paths: [
                PathRule(
                    path: "~/Library/Android/sdk",
                    verdict: .forbid,
                    reason: "SDK toolchain root"
                )
            ]
        )
        let coordinator = ScanCoordinator(vendors: [androidRule], home: home)

        let evaluation = coordinator.deletionSafetyEvaluation(
            for: "\(home)/Library/Android/sdk/system-images"
        )

        XCTAssertEqual(evaluation.verdict, .forbid)
        XCTAssertEqual(evaluation.rejection, .vendorPathRule)
        XCTAssertEqual(evaluation.vendor?.name, "Android SDK")
    }

    // MARK: - permissionDeniedPaths（列表收集，不再覆盖 lastError）

    /// 制造两个 chmod 0000 的一级子目录跑扫描，断言：
    ///  - permissionDeniedPaths 累加到 2 条（原来 lastError 单字符串覆盖会只剩 1 条）
    ///  - lastError 仍为 nil（权限被拒不再污染真错误通道）
    func test_权限被拒目录会累加到列表() async throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let fm = FileManager.default
        let raw = NSTemporaryDirectory() + "AmuxAICleanScanCoordPermDenied-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let denied1 = root.appendingPathComponent("denied-A", isDirectory: true)
        let denied2 = root.appendingPathComponent("denied-B", isDirectory: true)
        try fm.createDirectory(at: denied1, withIntermediateDirectories: true)
        try fm.createDirectory(at: denied2, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied1.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied2.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied1.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied2.path)
            try? fm.removeItem(at: root)
        }

        let coord = ScanCoordinator(vendors: [], home: NSHomeDirectory())
        let category = ScanCategory(
            id: "test.permdenied",
            title: "permdenied",
            subtitle: "",
            rootPath: root.path,
            defaultVerdict: .safe
        )
        coord.scan(category: category)
        await waitFinished(coord)

        XCTAssertEqual(coord.permissionDeniedPaths.count, 2,
                       "两个 chmod 0000 的子目录应分别累加，得到 2 条；当前=\(coord.permissionDeniedPaths)")
        XCTAssertTrue(coord.permissionDeniedPaths.contains(denied1.path))
        XCTAssertTrue(coord.permissionDeniedPaths.contains(denied2.path))
        XCTAssertFalse(coord.snapshot.isComplete,
                       "权限被拒必须发布部分终态，不能伪装成完整成功")
        XCTAssertNil(coord.lastError,
                     "精确权限缺口必须走统一 limitations presentation，不能重新画 fatal 红字")
        XCTAssertNil(coord.terminalFailure)
        XCTAssertEqual(
            ScanIssuePresentation.make(
                hasTerminalFailure: coord.terminalFailure != nil,
                permissionDeniedPaths: coord.permissionDeniedPaths,
                tccSkippedPaths: coord.tccProtectedSkippedPaths,
                incompletePaths: coord.incompleteScanPaths
            ).kind,
            .limitations
        )
    }

    /// 多次推入同一 path 不应重复累加（去重 + 保序）。
    /// 通过 internal 注入接口直接驱动同一条去重路径，避开 BulkScanner 真实调度的不确定性。
    func test_重复路径不会重复累加() async throws {
        let coord = ScanCoordinator(vendors: [], home: NSHomeDirectory())
        let path = "/tmp/fake-denied-once"

        coord._testInjectPermissionDenied(path: path)
        coord._testInjectPermissionDenied(path: path)
        coord._testInjectPermissionDenied(path: path)

        XCTAssertEqual(coord.permissionDeniedPaths, [path],
                       "重复 path 必须去重，仅保留首条；当前=\(coord.permissionDeniedPaths)")
        XCTAssertEqual(coord.permissionDeniedPaths.count, 1)
    }
}
