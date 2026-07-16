import XCTest
@testable import ScanKit

/// v1.7 M1 PR-4：WorkflowRegistry 路由表行为契约。
///
/// 覆盖六类核心契约：
/// 1. 未知 scannerID → 空数组（不抛、不崩）；
/// 2. derived-data-per-project 路由命中（当前为占位实现，应返回 []）；
/// 3. simctl typed failure 在 hits-only 兼容入口仍为空，但 evidence 入口必须标记 incomplete；
/// 5. 默认 executor 路径（executor 参数为 nil）应能编译并运行不崩；
/// 6. WorkflowScanHit 的 Hashable / Identifiable 契约。
final class WorkflowRegistryTests: XCTestCase {

    // MARK: - case 1: 未知 ID

    func test_resolve_未知ID_返回空数组不崩() async {
        let home = FileManager.default.temporaryDirectory
        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.does-not-exist-\(UUID().uuidString)",
            home: home
        )
        XCTAssertEqual(hits.count, 0,
                       "PITFALL：未知 scannerID 必须兜底为空数组，避免单张错卡片把整个工作流卡死")
    }

    // MARK: - case 2: derived-data-per-project 路由（占位）

    func test_resolve_derivedDataPerProject_空home_返回空_v17_PR4() async {
        // PR-4 实接 DerivedDataPerProjectScanner.detect 后，空 home 不应有 DerivedData 根
        // → detect 返回 []，路由表透传 []。
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WRTests-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.derived-data-per-project",
            home: home
        )
        XCTAssertEqual(hits.count, 0, "空 home 无 DerivedData 根，应返回 []")
    }

    func test_resolve_derivedDataPerProject_有2工程_产出2条hit_v17_PR4() async throws {
        // 真实接线后，造 ~/Library/Developer/Xcode/DerivedData/MyApp-abc / WebApp-xyz
        // 应产出 2 条 WorkflowScanHit，displayName=工程名、note=带 hash 的目录名。
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WRTests-DD-\(UUID().uuidString)", isDirectory: true)
        let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in ["MyApp-abc123xyz", "WebApp-def456uvw"] {
            try FileManager.default.createDirectory(
                at: dd.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.derived-data-per-project",
            home: home
        )
        XCTAssertEqual(hits.count, 2, "2 工程应产 2 条 hit")
        let names = Set(hits.map(\.displayName))
        XCTAssertEqual(names, ["MyApp", "WebApp"],
                       "displayName 应是去 hash 后缀的工程名")
        let notes = Set(hits.compactMap(\.note))
        XCTAssertEqual(notes, ["MyApp-abc123xyz", "WebApp-def456uvw"],
                       "note 应带 hash 后缀，UI 据此 disambiguate 同名工程")
    }

    func test_resolve_filesystemMetadataMode_发现hit但不重复估算size() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WRTests-Metadata-\(UUID().uuidString)", isDirectory: true)
        let project = home
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
            .appendingPathComponent("MyApp-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: home)
            } catch {
                XCTFail("fixture cleanup failed: \(error)")
            }
        }

        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.derived-data-per-project",
            home: home,
            includeFilesystemSizes: false
        )

        XCTAssertEqual(hits.map(\.url), [project])
        XCTAssertNil(hits.first?.sizeBytes,
                     "AppUI Workflow 会在同一 BulkScanner 会话统计大小与完整性，registry 不应重复遍历")
    }

    // MARK: - case 3: simctl-devices 路由（dryRun executor）

    func test_resolve_simctlDevices_dryRunExecutor_返回空不崩() async {
        // dryRun=true → SubprocessExecutor 不真起子进程，输出 "<dryRun> /usr/bin/xcrun simctl ..." 非合法 JSON，
        // SimctlDevicesScanner.detect 会兜底为 []，路由表透传。
        let executor = SubprocessExecutor(timeout: 0.01, dryRun: true)
        let home = FileManager.default.temporaryDirectory

        let start = Date()
        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.simctl-devices",
            home: home,
            executor: executor
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(hits.count, 0, "dryRun 输出非合法 JSON，应兜底为空")
        XCTAssertLessThan(elapsed, 1.0,
                          "dryRun 不应真起 Process；若起了子进程会被 timeout 拖到秒级")
    }

    func test_resolveWithEvidence_simctlDevices非法payload_不是完整空结果() async throws {
        let evidence = try await WorkflowRegistry.resolveWithEvidence(
            scannerID: "scanner.simctl-devices",
            home: FileManager.default.temporaryDirectory,
            executor: SubprocessExecutor(dryRun: true)
        )
        XCTAssertTrue(evidence.hits.isEmpty)
        XCTAssertFalse(evidence.isComplete)
        XCTAssertEqual(evidence.incompleteIssues.map(\.path), ["/usr/bin/xcrun"])
        XCTAssertEqual(evidence.incompleteIssues.map(\.reason), [.enumerationFailed])
    }

    // MARK: - case 4: simctl-runtimes 路由（空 allowlist 模拟拒绝）

    func test_resolve_simctlRuntimes_空allowlist_返回空不抛() async {
        // 空 allowlist → SubprocessExecutor 抛 .notAllowed → SimctlRuntimeScanner.discover 内部吞掉返回 []。
        // 路由表必须透传 []，不应让错误冒泡。
        let executor = SubprocessExecutor(allowlist: [], dryRun: true)
        let home = FileManager.default.temporaryDirectory
        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.simctl-runtimes",
            home: home,
            executor: executor
        )
        XCTAssertEqual(hits.count, 0,
                       "allowlist 拒绝时应兜底为空，对位 macOS 未装 Xcode 的真实场景")
    }

    func test_resolveWithEvidence_simctlRuntimes命令拒绝_不是完整空结果() async throws {
        let evidence = try await WorkflowRegistry.resolveWithEvidence(
            scannerID: "scanner.simctl-runtimes",
            home: FileManager.default.temporaryDirectory,
            executor: SubprocessExecutor(allowlist: [], dryRun: true)
        )
        XCTAssertTrue(evidence.hits.isEmpty)
        XCTAssertFalse(evidence.isComplete)
        XCTAssertEqual(evidence.incompleteIssues.map(\.path), ["/usr/bin/xcrun"])
    }

    // MARK: - case 5: 默认 executor（executor 参数为 nil）

    func test_resolve_默认executor_可用且不崩() async {
        // 不传 executor → 路由表内部应构造默认 SubprocessExecutor。
        // 不论是否真有 simctl，结果都必须是 [WorkflowScanHit]，且不应抛。
        // 注意：CI 上可能真起 xcrun，此处不断言数量，仅断言"调用本身不崩"。
        let home = FileManager.default.temporaryDirectory
        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.simctl-runtimes",
            home: home,
            executor: nil
        )
        XCTAssertNotNil(hits, "默认 executor 路径必须可用")
        // 显式 type-check：保证返回类型确为 [WorkflowScanHit]
        let _: [WorkflowScanHit] = hits
    }

    // MARK: - case 6: WorkflowScanHit 契约

    func test_WorkflowScanHit_Identifiable_id等于urlPath() {
        let url = URL(fileURLWithPath: "/tmp/sample/path/with space")
        let hit = WorkflowScanHit(
            url: url,
            sizeBytes: 1024,
            displayName: "Sample",
            note: "note"
        )
        XCTAssertEqual(hit.id, "/tmp/sample/path/with space",
                       "PITFALL：id 必须直接复用 url.path，跨扫描器主键统一")
        XCTAssertEqual(hit.id, hit.url.path)
    }

    func test_WorkflowScanHit_Hashable_相同字段哈希一致_不同字段哈希不同() {
        let url = URL(fileURLWithPath: "/tmp/a")
        let a1 = WorkflowScanHit(url: url, sizeBytes: 100, displayName: "A", note: nil)
        let a2 = WorkflowScanHit(url: url, sizeBytes: 100, displayName: "A", note: nil)
        let b = WorkflowScanHit(url: url, sizeBytes: 200, displayName: "A", note: nil)
        let c = WorkflowScanHit(url: URL(fileURLWithPath: "/tmp/b"),
                                sizeBytes: 100, displayName: "A", note: nil)

        XCTAssertEqual(a1, a2, "同字段必须相等")
        XCTAssertEqual(a1.hashValue, a2.hashValue, "Hashable: 同字段哈希必须一致")
        XCTAssertNotEqual(a1, b, "sizeBytes 不同必须不等")
        XCTAssertNotEqual(a1, c, "url 不同必须不等")

        // 放进 Set 验证 Hashable 实际可用
        let set: Set<WorkflowScanHit> = [a1, a2, b, c]
        XCTAssertEqual(set.count, 3, "a1 与 a2 全等应被 Set 去重为 1 条")
    }

    func test_WorkflowScanHit_可选字段nil_可正常构造与比较() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let hit = WorkflowScanHit(url: url, sizeBytes: nil, displayName: "X", note: nil)
        XCTAssertNil(hit.sizeBytes)
        XCTAssertNil(hit.note)
        XCTAssertNil(hit.managedUninstallIdentifier)
        XCTAssertEqual(hit.id, "/tmp/x")
    }

    func test_WorkflowScanHit_托管卸载ID参与Hashable契约() {
        let url = URL(fileURLWithPath: "/tmp/runtime")
        let uuid = "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7"
        let managed = WorkflowScanHit(url: url,
                                      sizeBytes: 1024,
                                      displayName: "iOS 18.0",
                                      note: nil,
                                      managedUninstallIdentifier: uuid)
        let readOnly = WorkflowScanHit(url: url,
                                       sizeBytes: 1024,
                                       displayName: "iOS 18.0",
                                       note: nil)
        XCTAssertEqual(managed.managedUninstallIdentifier, uuid)
        XCTAssertNotEqual(managed, readOnly,
                          "可卸载命中与 legacy 只读命中必须是不同状态")
    }

    func test_WorkflowScanHit_simctlNote保留类型语义而非rawEnglish() {
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/device"),
            sizeBytes: nil,
            displayName: "iPhone",
            note: nil,
            semanticNote: .simulatorDevice(
                state: .shutdown,
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            )
        )
        XCTAssertNil(hit.note, "Shutdown 不得再固化为 raw note")
        XCTAssertEqual(
            hit.semanticNote,
            .simulatorDevice(
                state: .shutdown,
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            )
        )
    }

    // MARK: - case 7: node-modules-scattered 路由（WebNode 工作流）

    func test_resolve_nodeModulesScattered_空home_返回空() async {
        // 5 个 dev 根均不存在 → NodeModulesScanner.detect 返回 []，路由表透传。
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WRTests-NM-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.node-modules-scattered",
            home: home
        )
        XCTAssertEqual(hits.count, 0, "空 home 无任何 dev 根，应返回 []")
    }

    func test_resolve_nodeModulesScattered_有2工程_产出2条hit_并正确填充字段() async throws {
        // 真实造 ~/Developer/foo/node_modules + ~/Projects/bar/node_modules
        // 应产 2 条 WorkflowScanHit，displayName=工程名，note=node_modules 完整路径。
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WRTests-NM-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let fm = FileManager.default
        let fooNM = home
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("foo", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
        let barNM = home
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("bar", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: fooNM, withIntermediateDirectories: true)
        try fm.createDirectory(at: barNM, withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 128).write(to: fooNM.appendingPathComponent("a.js"))
        try Data(repeating: 0xFF, count: 256).write(to: barNM.appendingPathComponent("b.js"))

        let hits = await WorkflowRegistry.resolve(
            scannerID: "scanner.node-modules-scattered",
            home: home
        )
        XCTAssertEqual(hits.count, 2, "2 个工程应产 2 条 hit")
        let names = Set(hits.map(\.displayName))
        XCTAssertEqual(names, ["foo", "bar"],
                       "displayName 应是工程名（node_modules 的父目录名）")
        let notes = Set(hits.compactMap(\.note))
        XCTAssertTrue(notes.contains(where: { $0.hasSuffix("/Developer/foo/node_modules") }),
                      "note 应承载完整路径，UI 据此 disambiguate 跨根同名工程")
        XCTAssertTrue(notes.contains(where: { $0.hasSuffix("/Projects/bar/node_modules") }))
        // 每条 hit 的 url 必须能 round-trip 回路径
        for hit in hits {
            XCTAssertEqual(hit.id, hit.url.path,
                           "PITFALL：node-modules-scattered 路由必须把 hit.url 原样透传，id=url.path")
        }
    }
}
