import Darwin
import XCTest
@testable import AppUI
import SafetyKit
import ScanKit

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

    func test_UninstallCandidateLoadGate_旧取消任务不能结束或清空新轮() {
        let appA = UninstallCandidateLoadIdentity(
            appID: "/Applications/A.app",
            scanSessionID: UUID(),
            selectionRevision: 1
        )
        let appB = UninstallCandidateLoadIdentity(
            appID: "/Applications/B.app",
            scanSessionID: UUID(),
            selectionRevision: 2
        )
        var gate = UninstallCandidateLoadGate()
        gate.begin(appA)
        gate.begin(appB)

        XCTAssertNil(gate.completeIfCurrent(
            appA,
            selectedAppID: appB.appID,
            scanSessionID: appB.scanSessionID,
            selectionRevision: appB.selectionRevision,
            taskWasCancelled: true
        ))
        XCTAssertEqual(gate.current, appB, "旧任务迟到收尾不能清除新轮 owner 或关闭新轮 spinner")

        XCTAssertEqual(gate.completeIfCurrent(
            appB,
            selectedAppID: appB.appID,
            scanSessionID: appB.scanSessionID,
            selectionRevision: appB.selectionRevision,
            taskWasCancelled: false
        ), .publishResult)
        XCTAssertNil(gate.current)
    }

    func test_UninstallCandidateLoadGate_取消与离页都收敛且拒绝迟到结果() {
        let identity = UninstallCandidateLoadIdentity(
            appID: "/Applications/A.app",
            scanSessionID: UUID(),
            selectionRevision: 7
        )
        var gate = UninstallCandidateLoadGate()
        gate.begin(identity)

        XCTAssertEqual(gate.completeIfCurrent(
            identity,
            selectedAppID: identity.appID,
            scanSessionID: identity.scanSessionID,
            selectionRevision: identity.selectionRevision,
            taskWasCancelled: true
        ), .cancelled)
        XCTAssertNil(gate.current)

        gate.begin(identity)
        gate.invalidate()
        XCTAssertNil(gate.completeIfCurrent(
            identity,
            selectedAppID: identity.appID,
            scanSessionID: identity.scanSessionID,
            selectionRevision: identity.selectionRevision,
            taskWasCancelled: false
        ), "离页失效后，同一磁盘任务即使迟到返回也不得重新发布")
    }

    func test_UninstallAppListLoadGate_旧刷新不能结束新轮() {
        let old = UninstallAppListLoadIdentity(operationID: UUID(), revision: 1)
        let current = UninstallAppListLoadIdentity(operationID: UUID(), revision: 2)
        var gate = UninstallAppListLoadGate()
        gate.begin(old)
        gate.begin(current)

        XCTAssertNil(gate.finishIfCurrent(old, taskWasCancelled: true))
        XCTAssertEqual(gate.current, current)
        XCTAssertEqual(gate.finishIfCurrent(current, taskWasCancelled: false), true)
        XCTAssertNil(gate.current)
    }

    func test_UninstallExecutionProgressReducer_严格绑定App会话版本且单调() {
        let session = UUID()
        let owner = UninstallExecutionOwner(
            id: UUID(),
            appID: "/Applications/Demo.app",
            scanSessionID: session,
            selectionRevision: 5
        )
        let start = UninstallExecutionStatus.preparing(totalItems: 3)
        let submitting = UninstallExecutionProgressReducer.reduce(
            current: start,
            event: .trash(.init(
                phase: .submitting,
                completedItems: 1,
                totalItems: 3,
                currentPath: "/tmp/a"
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentAppID: owner.appID,
            currentScanSessionID: session,
            currentSelectionRevision: 5
        )
        XCTAssertEqual(submitting.phase, .submitting)
        XCTAssertEqual(submitting.completedItems, 1)

        let stale = UninstallExecutionProgressReducer.reduce(
            current: submitting,
            event: .trash(.init(
                phase: .finalizing,
                completedItems: 3,
                totalItems: 3,
                currentPath: nil
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentAppID: owner.appID,
            currentScanSessionID: session,
            currentSelectionRevision: 6
        )
        XCTAssertEqual(stale, submitting)

        let regressed = UninstallExecutionProgressReducer.reduce(
            current: submitting,
            event: .trash(.init(
                phase: .finalValidation,
                completedItems: 0,
                totalItems: 3,
                currentPath: nil
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentAppID: owner.appID,
            currentScanSessionID: session,
            currentSelectionRevision: 5
        )
        XCTAssertEqual(regressed, submitting)

        let diagnosing = UninstallExecutionProgressReducer.reduce(
            current: submitting,
            event: .trash(.init(
                phase: .diagnosingItems,
                completedItems: 1,
                totalItems: 3,
                currentPath: "/tmp/b"
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentAppID: owner.appID,
            currentScanSessionID: session,
            currentSelectionRevision: 5
        )
        let nextBatch = UninstallExecutionProgressReducer.reduce(
            current: diagnosing,
            event: .trash(.init(
                phase: .submitting,
                completedItems: 2,
                totalItems: 3,
                currentPath: "/tmp/c"
            )),
            eventOwner: owner,
            currentOwner: owner,
            currentAppID: owner.appID,
            currentScanSessionID: session,
            currentSelectionRevision: 5
        )
        XCTAssertEqual(nextBatch.phase, .submitting,
                       "分批回收可在逐项诊断后进入下一批提交，不能用伪线性 rank 卡住状态")
        XCTAssertEqual(nextBatch.completedItems, 2)
    }

    func test_DefaultFileManagerSnapshot_大目录应受文件数预算限制() throws {
        let tmp = try makeTempDir("bounded-snapshot")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

        for idx in 0..<8 {
            try Data(repeating: UInt8(idx), count: 4)
                .write(to: tmp.appendingPathComponent("file-\(idx).bin"))
        }

        let snapshot = DefaultFileManagerSnapshot(maxDescendantFiles: 3)
            .snapshot(at: tmp.path)
        XCTAssertLessThanOrEqual(snapshot.fileCount, 3, "真实磁盘 snapshot 需要有预算，避免大型容器把 UI 等死")
        XCTAssertTrue(snapshot.isDirectory)
        XCTAssertEqual(snapshot.completion, .partial,
                       "预算截断只能发布 partial 下界，不能伪装成完整容量")
        XCTAssertTrue(snapshot.issues.contains { issue in
            if case .fileBudgetExceeded(limit: 3) = issue.reason { return true }
            return false
        })
    }

    /// v2026.07.17 regression: NaN must not disable the public duration budget because every
    /// `elapsed >= .nan` comparison is false.
    func test_DefaultFileManagerSnapshot_非法时长预算必须收敛() {
        XCTAssertEqual(DefaultFileManagerSnapshot.normalizedSnapshotDuration(.nan), 0)
        XCTAssertEqual(DefaultFileManagerSnapshot.normalizedSnapshotDuration(-1), 0)
        XCTAssertEqual(DefaultFileManagerSnapshot.normalizedSnapshotDuration(0), 0)
        XCTAssertEqual(DefaultFileManagerSnapshot.normalizedSnapshotDuration(2.5), 2.5)
        XCTAssertEqual(DefaultFileManagerSnapshot.normalizedSnapshotDuration(.infinity), .infinity)
        XCTAssertNil(DefaultFileManagerSnapshot.normalizedSnapshotDuration(nil))
    }

    func test_DefaultFileManagerSnapshot_单文件目录仍保留真实目录类型() throws {
        let tmp = try makeTempDir("single-file-directory")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        try Data([0x1]).write(to: tmp.appendingPathComponent("only.bin"))

        let snapshot = DefaultFileManagerSnapshot().snapshot(at: tmp.path)

        XCTAssertEqual(snapshot.fileCount, 1)
        XCTAssertTrue(snapshot.isDirectory,
                      "目录里恰好一个文件时不能被 fileCount == 1 误判成普通文件")
        XCTAssertEqual(snapshot.completion, .complete)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func test_DefaultFileManagerSnapshot_逐项取消返回cancelled而非partial终态() throws {
        let tmp = try makeTempDir("cooperative-cancellation")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        for idx in 0..<4 {
            try Data([UInt8(idx)]).write(to: tmp.appendingPathComponent("\(idx).bin"))
        }

        let probe = CancellationProbe(cancelAtCheck: 2)
        let snapshot = DefaultFileManagerSnapshot(
            isCancellationRequested: { probe.shouldCancel() }
        ).snapshot(at: tmp.path)

        XCTAssertEqual(snapshot.completion, .cancelled)
        XCTAssertTrue(snapshot.isDirectory)
        XCTAssertTrue(snapshot.issues.contains { $0.reason == .cancelled })
        XCTAssertLessThan(snapshot.fileCount, 4,
                          "取消必须在逐项边界停住，不能继续遍历完整目录")
    }

    func test_DefaultFileManagerSnapshot_ENOENT是确认不存在而非metadata缺口() {
        let missing = "/tmp/AppUninstaller-missing-\(UUID().uuidString)"

        let snapshot = DefaultFileManagerSnapshot().snapshot(at: missing)

        XCTAssertFalse(snapshot.exists)
        XCTAssertEqual(snapshot.completion, .complete)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func test_vendor推测路径不存在不阻断真实primary候选() throws {
        let fixture = try makeTempDir("vendor-missing-is-clean")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        let systemLibrary = fixture.appendingPathComponent("SystemLibrary", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let realCandidate = caches.appendingPathComponent("com.acme.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: realCandidate, withIntermediateDirectories: true)
        try Data([0x1]).write(to: realCandidate.appendingPathComponent("state.bin"))

        let meta = AppMetadata(
            bundleID: "com.acme.demo",
            bundleVendor: "com.acme",
            appName: "AcmeDemo",
            executableName: nil
        )
        let result = AppUninstaller(
            homeDirectory: home.path,
            systemLibrary: systemLibrary.path,
            fileManager: DefaultFileManagerSnapshot(),
            vendorRules: [VendorRule(
                name: "Acme",
                bundleIDPrefix: "com.acme",
                appSupportSubdir: "Definitely-Missing-Acme"
            )]
        ).candidates(for: meta)

        XCTAssertEqual(result.candidates.map(\.path), [realCandidate.path])
        XCTAssertTrue(result.incompleteIssues.isEmpty)
        XCTAssertTrue(result.isDiscoveryComplete)
        XCTAssertTrue(UninstallCandidateDiscoveryPresentation.allowsDeletion(
            candidates: result.candidates,
            issues: result.incompleteIssues
        ))
    }

    func test_firstLevel身份快照拒绝排队root替换且不遍历symlink目标() throws {
        let fixture = try makeTempDir("first-level-root-replacement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Caches", isDirectory: true)
        let displaced = fixture.appendingPathComponent("Caches-Original", isDirectory: true)
        let outside = fixture.appendingPathComponent("Outside", isDirectory: true)
        let child = root.appendingPathComponent("com.acme.demo", isDirectory: true)
        let outsideChild = outside.appendingPathComponent("com.acme.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
        try Data([0x1]).write(to: child.appendingPathComponent("small.bin"))
        try Data(repeating: 0xA5, count: 256 * 1_024)
            .write(to: outsideChild.appendingPathComponent("outside.bin"))

        let snapshotter = DefaultFileManagerSnapshot()
        guard case .entries(let entries) = snapshotter.firstLevelDiscovery(at: root.path),
              let entry = entries.first(where: { $0.name == "com.acme.demo" }) else {
            return XCTFail("expected identity-bound first-level entry")
        }
        XCTAssertNotNil(entry.identityProof)
        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        let snapshot = snapshotter.snapshot(
            entry: entry,
            cancellationToken: FSSnapshotCancellationToken()
        )

        XCTAssertNotEqual(snapshot.completion, .complete)
        XCTAssertEqual(snapshot.bytes, 0, "replacement target must never be traversed")
        XCTAssertTrue(snapshot.issues.contains { $0.reason == .metadataUnavailable })
    }

    func test_DefaultFileManagerSnapshot_稀疏文件主值应对齐系统磁盘占用() throws {
        let tmp = try makeTempDir("sparse-snapshot")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let sparse = tmp.appendingPathComponent("Docker.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data([0x1])))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try handle.close()

        let snapshot = DefaultFileManagerSnapshot().snapshot(at: tmp.path)

        XCTAssertLessThan(snapshot.bytes, 64 * 1_024 * 1_024,
                          "应用占用/卸载残留不能把 sparse 虚拟容量当成磁盘占用")
        XCTAssertGreaterThan(snapshot.logicalBytes, 1 * 1_024 * 1_024 * 1_024,
                             "共享快照仍需保留 Finder 式逻辑容量供详情诊断")
    }

    func test_DefaultFileManagerSnapshot_hardlink只计一次磁盘占用与逻辑大小() throws {
        let tmp = try makeTempDir("hardlink-snapshot")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let original = tmp.appendingPathComponent("original.bin")
        let linked = tmp.appendingPathComponent("linked.bin")
        try Data(repeating: 0xA5, count: 32 * 1_024).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)

        var metadata = stat()
        XCTAssertEqual(lstat(original.path, &metadata), 0)
        XCTAssertGreaterThanOrEqual(metadata.st_nlink, 2)

        let snapshot = DefaultFileManagerSnapshot().snapshot(at: tmp.path)

        XCTAssertEqual(snapshot.bytes, Int64(metadata.st_blocks) * 512)
        XCTAssertEqual(snapshot.logicalBytes, Int64(metadata.st_size))
        XCTAssertEqual(snapshot.fileCount, 2, "文件数仍表示两个目录项，只有字节需要 inode 去重")
    }

    /// v2026.07.17 regression: after the first multi-link pathname is counted, a concurrent
    /// unlink can make the next pathname report `st_nlink == 1`. The retained identity must be
    /// consulted before the single-link fast path or the same allocation is counted twice.
    func test_FSSnapshotHardlinkLedger_linkCount下降后仍不能重复计量() {
        var ledger = FSSnapshotHardlinkLedger()

        XCTAssertTrue(ledger.shouldCount(device: 7, inode: 42, linkCount: 2))
        XCTAssertFalse(ledger.shouldCount(device: 7, inode: 42, linkCount: 1))
        XCTAssertTrue(ledger.shouldCount(device: 7, inode: 43, linkCount: 1))
        XCTAssertEqual(ledger.retainedIdentityCount, 1,
                       "普通单链接 inode 不应为正确性修复重新全部常驻内存")
    }

    // MARK: - 1. Info.plist 解析

    func test_AppMetadata_readsInfoPlist() throws {
        let tmp = try makeTempDir("plist-parse")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

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
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

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

    func test_AppMetadata_oversizeInfoPlistUsesSharedBoundedReader() throws {
        let tmp = try makeTempDir("plist-oversize")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let appURL = tmp.appendingPathComponent("Huge.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: plist.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: plist)
        try handle.truncate(atOffset: UInt64(BoundedLocalFileReader.defaultMaximumBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try AppMetadata.read(appURL: appURL)) {
            XCTAssertEqual(
                $0 as? BoundedLocalFileReadError,
                .tooLarge(
                    limit: BoundedLocalFileReader.defaultMaximumBytes,
                    observedSize: Int64(BoundedLocalFileReader.defaultMaximumBytes + 1)
                )
            )
        }
    }

    func test_AppMetadata_finalInfoPlistSymlinkIsRejected() throws {
        let tmp = try makeTempDir("plist-symlink")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let appURL = tmp.appendingPathComponent("Linked.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let target = tmp.appendingPathComponent("outside.plist")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.linked"],
            format: .xml,
            options: 0
        )
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: contents.appendingPathComponent("Info.plist"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try AppMetadata.read(appURL: appURL)) {
            XCTAssertEqual($0 as? BoundedLocalFileReadError, .unsafeType(.symbolicLink))
        }
    }

    func test_AppMetadata_fallsBackToFilenameStem() throws {
        let tmp = try makeTempDir("plist-fallback-name")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

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
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
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
        let dataFile = asDir.appendingPathComponent("data.bin")
        let moreFile = asDir.appendingPathComponent("more.bin")
        try payload.write(to: dataFile)
        try payload.write(to: moreFile)

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

        // bytes/fileCount —— 主值按系统磁盘分配量统计，不把 2 KB logical 当作占用。
        let appSupportCand = candidates.first { $0.path == asDir.path }
        XCTAssertEqual(appSupportCand?.fileCount, 2)
        XCTAssertEqual(appSupportCand?.bytes,
                       try allocatedBytes(of: dataFile) + allocatedBytes(of: moreFile))

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

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let cancelAtCheck: Int
        private var checks = 0

        init(cancelAtCheck: Int) {
            self.cancelAtCheck = cancelAtCheck
        }

        func shouldCancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            return checks >= cancelAtCheck
        }
    }

    private final class AsyncSnapshotCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func markStarted() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var started: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct CooperativelyBlockingFM: FileManagerSnapshotting {
        let root: String
        let entries: [FSEntry]
        let counter: AsyncSnapshotCounter

        func firstLevelEntries(at path: String) -> [FSEntry]? {
            path == root ? entries : nil
        }

        func snapshot(at path: String) -> FSSnapshot {
            blockingSnapshot(at: path) {
                withUnsafeCurrentTask(body: { $0?.isCancelled ?? false })
            }
        }

        func snapshot(
            at path: String,
            cancellationToken: FSSnapshotCancellationToken
        ) -> FSSnapshot {
            blockingSnapshot(at: path) { cancellationToken.isCancelled }
        }

        private func blockingSnapshot(
            at path: String,
            cancellationRequested: () -> Bool
        ) -> FSSnapshot {
            counter.markStarted()
            while !cancellationRequested() {
                usleep(500)
            }
            return FSSnapshot(
                bytes: 0,
                fileCount: 0,
                exists: true,
                isDirectory: true,
                completion: .cancelled,
                issues: [.init(path: path, reason: .cancelled, stage: .cancellation)]
            )
        }
    }

    func test_candidatesAsync_取消后停止补任务并丢弃整轮候选() async {
        let root = "/H/Library/Caches"
        let entries = (0..<40).map { index in
            FSEntry(name: "com.acme.demo.\(index)", path: "\(root)/com.acme.demo.\(index)")
        }
        let counter = AsyncSnapshotCounter()
        let uninstaller = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: CooperativelyBlockingFM(root: root, entries: entries, counter: counter)
        )
        let metadata = AppMetadata(
            bundleID: "com.acme.demo",
            bundleVendor: "com.acme",
            appName: "DemoApp",
            executableName: nil
        )

        let task = Task {
            await uninstaller.candidatesAsync(for: metadata, includeFallbacks: false)
        }
        while counter.started == 0 { await Task.yield() }
        task.cancel()
        let candidates = await task.value

        XCTAssertTrue(candidates.isEmpty,
                      "取消轮没有可信终态，不能发布抢先完成或 partial 候选")
        XCTAssertLessThanOrEqual(counter.started, 8,
                                 "滑动窗口取消后不得继续从 iterator 补任务")
    }

    func test_Uninstall删除策略_partial不可提交_完整单文件目录类型不丢失() {
        let issue = FSSnapshotIssue(
            path: "/H/Library/Caches/com.acme.demo",
            reason: .fileBudgetExceeded(limit: 3),
            stage: .budget
        )
        let partial = UninstallCandidate(
            path: issue.path,
            bytes: 100,
            fileCount: 3,
            isDirectory: true,
            snapshotCompletion: .partial,
            snapshotIssues: [issue],
            matchReason: .bundleID("com.acme.demo")
        )
        XCTAssertFalse(UninstallDeletionSelectionPolicy.isSelectable(partial))
        XCTAssertFalse(UninstallDeletionSelectionPolicy.canSubmit([partial]))
        let partialInteraction = UninstallDeletionSelectionPolicy.interactionSnapshot(
            for: partial,
            runningBundleIDPrefix: "com.acme.demo"
        )
        XCTAssertEqual(partialInteraction.accessEvidence, .incomplete(.incompleteEnumeration))

        let completeDirectory = UninstallCandidate(
            path: "/H/Library/Caches/com.acme.complete",
            bytes: 10,
            fileCount: 1,
            isDirectory: true,
            objectIdentity: TrashObjectIdentity(
                device: 1,
                inode: 2,
                fileType: UInt16(S_IFDIR)
            ),
            matchReason: .bundleID("com.acme.demo")
        )
        XCTAssertTrue(UninstallDeletionSelectionPolicy.canSubmit([completeDirectory]))
        let completeInteraction = UninstallDeletionSelectionPolicy.interactionSnapshot(
            for: completeDirectory,
            runningBundleIDPrefix: "com.acme.demo"
        )
        XCTAssertTrue(completeInteraction.isDirectory,
                      "删除 intent 必须使用真实类型，不能再用 fileCount != 1 猜目录")
        XCTAssertEqual(completeInteraction.accessEvidence, .complete)
    }

    func test_统一发现权威_identity根失败与partial都显示缺口并阻断删除() {
        let completeCandidate = UninstallCandidate(
            path: "/H/Library/Caches/com.acme.demo",
            bytes: 10,
            fileCount: 1,
            isDirectory: true,
            matchReason: .bundleID("com.acme.demo")
        )
        let identityIssue = UninstallDiscoveryIssue(
            source: .selectedAppIdentity,
            stage: .identityValidation,
            path: "/Applications/Demo.app",
            reason: .identityMismatch(
                claimedBundleID: "com.acme.demo",
                actualBundleID: "com.other.app"
            )
        )
        let primaryIssue = UninstallDiscoveryIssue(
            source: .primaryRoot,
            stage: .rootEnumeration,
            path: "/H/Library/Containers",
            reason: .permissionDenied
        )

        for issue in [identityIssue, primaryIssue] {
            let result = UninstallCandidateDiscoveryResult(
                candidates: [],
                incompleteIssues: [issue]
            )
            XCTAssertEqual(
                UninstallCandidateDiscoveryPresentation.emptyState(
                    candidates: result.candidates,
                    issues: result.incompleteIssues
                ),
                .incompleteEmpty
            )
            XCTAssertEqual(
                UninstallCandidateDiscoveryPresentation.noticeCount(result.incompleteIssues),
                1
            )
            XCTAssertFalse(UninstallCandidateDiscoveryPresentation.allowsDeletion(
                candidates: [completeCandidate],
                issues: result.incompleteIssues
            ))
        }

        let snapshotIssue = FSSnapshotIssue(
            path: completeCandidate.path,
            reason: .timeBudgetExceeded(limitMilliseconds: 10),
            stage: .budget
        )
        let partialCandidate = UninstallCandidate(
            path: completeCandidate.path,
            bytes: 10,
            fileCount: 1,
            isDirectory: true,
            snapshotCompletion: .partial,
            snapshotIssues: [snapshotIssue],
            matchReason: .bundleID("com.acme.demo")
        )
        let partialResult = UninstallCandidateDiscoveryResult(candidates: [partialCandidate])
        XCTAssertFalse(partialResult.isDiscoveryComplete)
        XCTAssertEqual(
            UninstallCandidateDiscoveryPresentation.noticeCount(partialResult.incompleteIssues),
            1,
            "candidate snapshot 缺口必须进入统一 notice，而非只在行内静默显示"
        )
        XCTAssertFalse(UninstallCandidateDiscoveryPresentation.allowsDeletion(
            candidates: partialResult.candidates,
            issues: partialResult.incompleteIssues
        ))
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

    // MARK: - Step 14 静默失败修复：DefaultFileManagerSnapshot 错误分类

    /// 线程安全的 String 收集器
    private final class PathCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func allocatedBytes(of url: URL) throws -> Int64 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int64(metadata.st_blocks) * 512
    }

    /// chmod 000 的目录调 firstLevelEntries 应触发 permissionDenied handler
    func test_DefaultSnapshot_无权限目录firstLevelEntries应上报permissionDenied() throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AU-Tests-EACCES-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let collector = PathCollector()
        let snap = DefaultFileManagerSnapshot(permissionDeniedHandler: { collector.append($0) })

        let entries = snap.firstLevelEntries(at: tmp.path)
        XCTAssertNil(entries, "无权限目录 firstLevelEntries 必须返回 nil")
        XCTAssertEqual(collector.snapshot, [tmp.path],
            "permissionDeniedHandler 必须被调用一次")

        let snapshot = snap.snapshot(at: tmp.path)
        XCTAssertEqual(snapshot.completion, .partial)
        XCTAssertTrue(snapshot.issues.contains { $0.reason == .permissionDenied },
                      "snapshot 不能只写日志；权限错误必须进入 typed issues")
    }

    func test_primary第一层readdir使用整轮entry预算并保留typedIncomplete() throws {
        let fixture = try makeTempDir("primary-entry-budget")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let caches = fixture.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: caches.appendingPathComponent("com.acme.demo.one", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: caches.appendingPathComponent("com.acme.demo.two", isDirectory: true),
            withIntermediateDirectories: true
        )
        let uninstaller = AppUninstaller(
            homeDirectory: fixture.path,
            systemLibrary: fixture.appendingPathComponent("SystemLibrary").path,
            primaryDiscoveryLimits: .init(maxVisitedEntries: 1, maxDuration: 2)
        )

        let result = uninstaller.candidates(for: AppMetadata(
            bundleID: "com.acme.demo",
            bundleVendor: "com.acme",
            appName: "AcmeDemo",
            executableName: "AcmeDemo"
        ))

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.incompleteIssues.first?.source, .primaryRoot)
        XCTAssertEqual(result.incompleteIssues.first?.reason, .fileBudgetExceeded(limit: 1))
    }

    /// 不存在的目录静默不上报
    func test_DefaultSnapshot_不存在目录firstLevelEntries静默不上报() {
        let nonexistent = "/Users/__nope__/NoDir-\(UUID().uuidString)"
        let collector = PathCollector()
        let snap = DefaultFileManagerSnapshot(permissionDeniedHandler: { collector.append($0) })

        let entries = snap.firstLevelEntries(at: nonexistent)
        XCTAssertNil(entries)
        XCTAssertTrue(collector.snapshot.isEmpty,
            "ENOENT 必须静默，不调用 permissionDeniedHandler")
    }

    func test_GroupContainers_匹配group前缀与签名TeamID前缀并拒绝伪造TeamID() throws {
        let fixture = try makeTempDir("group-containers-teamid")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let groupContainers = fixture.appendingPathComponent("Library/Group Containers", isDirectory: true)
        try FileManager.default.createDirectory(at: groupContainers, withIntermediateDirectories: true)

        let standardGroup = groupContainers.appendingPathComponent("group.com.acme.demo.shared", isDirectory: true)
        let teamDirect = groupContainers.appendingPathComponent("ABCDE12345.com.acme.demo", isDirectory: true)
        let teamGroup = groupContainers.appendingPathComponent("ABCDE12345.group.com.acme.demo.sync", isDirectory: true)
        let wrongTeam = groupContainers.appendingPathComponent("ZZZZZ99999.com.acme.demo", isDirectory: true)
        for dir in [standardGroup, teamDirect, teamGroup, wrongTeam] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let uninstaller = AppUninstaller(
            homeDirectory: fixture.path,
            systemLibrary: fixture.appendingPathComponent("SystemLibrary").path
        )

        let withTeamResult = uninstaller.candidates(for: AppMetadata(
            bundleID: "com.acme.demo",
            bundleVendor: "com.acme",
            appName: "AcmeDemo",
            executableName: "AcmeDemo",
            teamID: "ABCDE12345"
        ))
        let matchedPaths = Set(withTeamResult.candidates.map(\.path))
        XCTAssertTrue(matchedPaths.contains(standardGroup.path), "应命中 group.<bundleID> 子前缀")
        XCTAssertTrue(matchedPaths.contains(teamDirect.path), "应命中签名匹配的 <TeamID>.<bundleID>")
        XCTAssertTrue(matchedPaths.contains(teamGroup.path), "应命中签名匹配的 <TeamID>.group.<bundleID>")
        XCTAssertFalse(matchedPaths.contains(wrongTeam.path), "不应命中其他 TeamID 的容器")

        let withoutTeamResult = uninstaller.candidates(for: AppMetadata(
            bundleID: "com.acme.demo",
            bundleVendor: "com.acme",
            appName: "AcmeDemo",
            executableName: "AcmeDemo",
            teamID: nil
        ))
        let withoutTeamPaths = Set(withoutTeamResult.candidates.map(\.path))
        XCTAssertTrue(withoutTeamPaths.contains(standardGroup.path))
        XCTAssertFalse(withoutTeamPaths.contains(teamDirect.path), "无签名 TeamID 时不得仅凭 10 位前缀形状盲目匹配")
        XCTAssertFalse(withoutTeamPaths.contains(teamGroup.path))
    }

    func test_UninstallStore_默认将vendorRules传递给OrphanScanner() async throws {
        let fixture = try makeTempDir("uninstall-store-orphan-vendors")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let appsDir = fixture.appendingPathComponent("Applications", isDirectory: true)
        let appSupport = fixture.appendingPathComponent("Library/Application Support", isDirectory: true)
        let protectedOrphan = appSupport.appendingPathComponent("ProtectedVendorData", isDirectory: true)
        let unprotectedOrphan = appSupport.appendingPathComponent("UnprotectedLegacyApp", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protectedOrphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unprotectedOrphan, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: protectedOrphan.appendingPathComponent("token.db"))
        try Data("cache".utf8).write(to: unprotectedOrphan.appendingPathComponent("old.db"))

        let oldDate = Date(timeIntervalSinceNow: -60 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: protectedOrphan.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unprotectedOrphan.path)

        let vendorRule = VendorRule(
            name: "Protected Vendor",
            appSupportSubdir: "ProtectedVendorData",
            paths: [
                PathRule(path: "~/Library/Application Support/ProtectedVendorData", verdict: .forbid)
            ]
        )
        let uninstaller = AppUninstaller(
            homeDirectory: fixture.path,
            systemLibrary: fixture.appendingPathComponent("SystemLibrary").path,
            vendorRules: [vendorRule]
        )
        let store = UninstallStore(
            applicationsPath: appsDir.path,
            uninstaller: uninstaller
        )
        let orphans = await store.scanOrphans()
        let orphanPaths = Set(orphans.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        XCTAssertTrue(
            orphanPaths.contains(unprotectedOrphan.standardizedFileURL.path),
            "未受厂商规则保护的陈旧无主目录应被识别为孤儿"
        )
        XCTAssertFalse(
            orphanPaths.contains(protectedOrphan.standardizedFileURL.path),
            "UninstallStore 默认继承 vendorRules 后，命中 .forbid 的厂商目录不得作为孤儿返回"
        )
    }

    func test_revalidateSelectedAppForDeletion_App已移除但不在待删列表时返回appAlreadyRemoved() throws {
        let fixture = try makeTempDir("revalidate-app-removed")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let appURL = fixture.appendingPathComponent("Demo.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.demo",
            "CFBundleName": "Demo",
            "CFBundleExecutable": "Demo"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let metadata = try AppMetadata.read(appURL: appURL)
        var appStat = stat()
        XCTAssertEqual(lstat(appURL.path, &appStat), 0)
        let fileIdentity = InstalledAppFileIdentity(metadata: appStat)
        let identity = UninstallSelectedAppIdentity(
            appURL: appURL,
            metadata: metadata,
            expectedFileIdentity: fileIdentity
        )
        let uninstaller = AppUninstaller(
            homeDirectory: fixture.path,
            systemLibrary: fixture.appendingPathComponent("SystemLibrary").path
        )

        let validDisposition = uninstaller.revalidateSelectedAppForDeletion(
            identity: identity,
            deletingPaths: [appURL.path]
        )
        XCTAssertEqual(validDisposition, .valid)

        try FileManager.default.removeItem(at: appURL)
        let leftoverPath = fixture.appendingPathComponent("Library/Caches/com.acme.demo").path
        let removedDisposition = uninstaller.revalidateSelectedAppForDeletion(
            identity: identity,
            deletingPaths: [leftoverPath]
        )
        XCTAssertEqual(removedDisposition, .appAlreadyRemoved,
                       "App 已被移除且本次仅清理剩余残留时应返回 .appAlreadyRemoved")

        let stillSelectedAppDisposition = uninstaller.revalidateSelectedAppForDeletion(
            identity: identity,
            deletingPaths: [appURL.path, leftoverPath]
        )
        if case .invalid = stillSelectedAppDisposition {
            // expected: .app仍在待删列表中但磁盘上已消失，必须报错拦截
        } else {
            XCTFail("待删列表仍包含 .app 但磁盘已不存在时应返回 .invalid，实际: \(stillSelectedAppDisposition)")
        }
    }
}

