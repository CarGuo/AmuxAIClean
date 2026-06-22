import AppKit
import AppUI
import Foundation
import SafetyKit
import ScanKit
import TestHarness

/// v1.3.zz 真实回归套件——通过环境变量 `GSY_REGRESSION_CASE=<case-id>` 在 App 启动钩子里被
/// [GSYCleanMacApp.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift#L113-L131)
/// 拉起。每条 case 真实地用 ScanCoordinator / TrashPipeline / StatusItemController 等业务对象走完
/// 一次端到端流程，**不是单元测试 mock**。
///
/// 输出契约（让 [Scripts/regression.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/regression.sh) 能直接 grep）：
/// 1. 每条 key=value 行用 `[REGR ...]` 前缀；
/// 2. 通过条件断言用 `assertEqual` / `assertGreater` / `assertTrue` 包装，失败立即写
///    `[REGR_FAIL case=<id> reason=<...>]` 并退出码 1；
/// 3. 全部断言通过后写 `[REGR_PASS case=<id> elapsed_ms=...]` 并退出码 0。
///
/// **不会真删任何用户数据**——所有删除路径都走 `dryRun=true`；所有 fixture 都搭在 `/tmp` 子目录下，
/// runner 自身负责 cleanup（Scenario.deinit 自动 rm -rf）。
@MainActor
final class RegressionRunner {
    private let caseID: String
    private let coordinator: ScanCoordinator
    private let settings: AppSettings
    private let hud: FloatingScanHUDController
    private let statusItem: StatusItemController
    private let activationPolicy: ActivationPolicyController
    private let vendors: [VendorRule]
    private let env: [String: String]
    private var failed: Bool = false
    private var firstFailReason: String?
    private let started: Date = Date()
    private var fixtureScenarios: [Scenario] = []

    init(caseID: String,
         coordinator: ScanCoordinator,
         settings: AppSettings,
         hud: FloatingScanHUDController,
         statusItem: StatusItemController,
         activationPolicy: ActivationPolicyController,
         vendors: [VendorRule],
         env: [String: String]) {
        self.caseID = caseID
        self.coordinator = coordinator
        self.settings = settings
        self.hud = hud
        self.statusItem = statusItem
        self.activationPolicy = activationPolicy
        self.vendors = vendors
        self.env = env
        // **崩溃自愈**：上一次 runner 进程若被 SIGKILL（超时被脚本杀掉、断言后强退、Xcode 中断等），
        // 内存里的 restore 不会跑，但磁盘 backup 文件还在；这里 init 时先消化掉，把用户偏好恢复回去，
        // 再开始这一轮新的 snapshot。详见 [consumeStaleBackupIfAny](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift)。
        Self.consumeStaleBackupIfAny()
    }

    /// 主入口：根据 caseID 路由到对应 method，捕获 throw 并统一打印结尾行后退出。
    ///
    /// **UserDefaults 隔离契约（v1.3.zz+）**：
    /// 回归 runner 跑在真实 App 进程里，settings 改动会写到用户磁盘上的 `com.guoshuyu.cleanmac.GSYCleanMac`。
    /// 为了不污染用户偏好，run() 进入时先把所有 `v1.*` key 全量 snapshot 到内存 + 落盘 backup 文件，
    /// 任何 case（不光 hud-toggle）跑完都自动 restore；进程被 kill / crash 时下次启动会消化残留 backup。
    /// 详见 [snapshotAndPersistDefaults](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift) 与 [restoreDefaultsFromSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift)。
    func run() async {
        let snapshot = snapshotAndPersistDefaults()
        log("[REGR_BEGIN] case=\(caseID)")
        do {
            switch caseID {
            // 扫描核心
            case "scan-custom-fixture":     try await scanCustomFixture()
            case "scan-recommended":        try await scanRecommended()
            case "tree-drilldown":          try await treeDrilldown()
            case "scan-cancel-restart":     try await scanCancelRestart()
            case "large-files-threshold":   try await largeFilesThreshold()
            // 结果加工 / 导出
            case "duplicate-scan":          try await duplicateScan()
            case "orphan-scan":             try await orphanScan()
            case "appfootprint-scan":       try await appFootprintScan()
            case "uninstaller-dryrun":      try await uninstallerDryRun()
            case "launchagent-scan":        try await launchAgentScan()
            case "exporter-csv":            try exporterCSV()
            // UI / HUD / 托盘 / 激活策略
            case "hud-toggle":              try await hudToggle()
            case "tray-install-uninstall":  try await trayInstallUninstall()
            case "activation-policy":       try await activationPolicyCase()
            case "quicklook-controller":    try quicklookController()
            // 安全 / 删除（v1.3.zzzz 路线 B：Helper / HelperClient / XPCBridge 整段下线，
            // 原 helper-bridge-stub / deletion-token-roundtrip 两条 case 一并删除）
            case "trash-pipeline-dryrun":   try await trashPipelineDryRun()
            case "safety-engine-veto":      try safetyEngineVeto()
            case "undo-history-restore":    try await undoHistoryRestore()
            // 真实场景诊断（图 4/5、图 2/3 反推、扫描慢）
            case "trash-real-scan":         try await trashRealScan()
            case "fda-banner-diagnose":     try await fdaBannerDiagnose()
            case "scan-perf-diagnose":      try await scanPerfDiagnose()
            // v1.6 Sentinel
            case "sentinel-default-off":    try sentinelDefaultOff()
            default:
                fail("unknown case id: \(caseID)")
            }
        } catch {
            fail("threw error: \(error)")
        }
        // 清场 fixture（runner 拥有所有权；Scenario.deinit 自动 rm -rf）
        fixtureScenarios.removeAll()
        // **在 exit 前显式 restore**——`exit()` 不会触发 Swift defer，必须手动调。
        // 进程被 SIGKILL / 崩溃时下次 init 也会消化磁盘 backup 自愈。
        restoreDefaultsFromSnapshot(snapshot)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if failed {
            log("[REGR_FAIL] case=\(caseID) elapsed_ms=\(elapsedMs) reason=\(firstFailReason ?? "unknown")")
            exit(1)
        } else {
            log("[REGR_PASS] case=\(caseID) elapsed_ms=\(elapsedMs)")
            exit(0)
        }
    }

    // MARK: - 扫描核心

    /// 用 ScenarioBuilder 搭一棵已知确定数字的树（10 文件 / 100KB / 嵌套 5 层），
    /// 走 ScanCoordinator.scan 真实扫描，断言 totalBytes / scannedFileCount 精确等于。
    private func scanCustomFixture() async throws {
        let scen = makeStandardFixture()
        let url = scen.root
        let category = ScanCategory.makeCustom(url: url)
        coordinator.scan(category: category, includeHidden: true)
        try await waitFinished(timeout: 30)
        let snap = coordinator.snapshot
        // standard fixture：10 个 102_400 字节文件 + 5 层嵌套每层 1 个 5_120 字节文件
        // = 共 15 个文件，bytes = 10 * 102_400 + 5 * 5_120 = 1_024_000 + 25_600 = 1_049_600
        log("[REGR] case=\(caseID) files=\(snap.scannedFileCount) bytes=\(snap.totalBytes) rows=\(snap.rows.count)")
        assertEqual(snap.scannedFileCount, 15, "scannedFileCount")
        assertEqual(Int(snap.totalBytes), 1_049_600, "totalBytes")
        assertTrue(snap.isFinished, "isFinished")
        assertGreater(snap.rows.count, 0, "rows count")
    }

    /// 跑一次"推荐扫描"。这是真实多根 ScanCoordinator.scanRecommended 入口，
    /// 数字会因用户机器变化——只断言完成、有 perRootProgress、未崩溃。
    private func scanRecommended() async throws {
        coordinator.scanRecommended(includeHidden: false)
        try await waitFinished(timeout: 600)
        let snap = coordinator.snapshot
        let perRoot = coordinator.perRootProgress
        log("[REGR] case=\(caseID) files=\(snap.scannedFileCount) bytes=\(snap.totalBytes) roots=\(perRoot.count)")
        assertTrue(snap.isFinished, "isFinished")
        // 推荐至少要登记到 perRootProgress 里
        assertGreater(perRoot.count, 0, "perRootProgress count")
        assertGreater(snap.scannedFileCount + 1, 0, "scannedFileCount nonneg")
        assertEqual(coordinator.lastError, nil, "lastError")
    }

    /// 树视图下钻：先扫 fixture，挑一个一级子目录调 directChildrenAsync，
    /// 断言目录条目 bytes > 0 且与清单视图主行 bytes 一致（v1.3.z 的 0 KB / 1 bug 回归）。
    /// v1.3.zz：enableTreeDeepIndex 默认 false 起，必须显式找 nest1（不能用 snap.rows.first，
    /// 因为单根 bucket 模型下顶层文件 f-i.bin 也是"bucket"且 isDirectory=true 但实际是文件叶子）。
    private func treeDrilldown() async throws {
        let scen = makeStandardFixture()
        let url = scen.root
        let category = ScanCategory.makeCustom(url: url)
        coordinator.scan(category: category, includeHidden: true)
        try await waitFinished(timeout: 30)
        let snap = coordinator.snapshot
        // v1.6 Step 6.6-1：fixture root 来自 FileManager.temporaryDirectory，
        // 在 macOS 上字面值是 /var/folders/.../T/...；但 BulkScanner 内部
        // 经过 URL.resolvingSymlinksInPath / FSEvents resolve 后会变成
        // /private/var/folders/.../T/...（/var → /private/var 是系统软链）。
        // 直接 == 比较 path 字符串必然 mismatch，导致 first(where:) 找不到 nest1。
        // 修复：先把两边都 standardize+resolve 到同一形态再比较；
        // 双重兜底用 lastPathComponent + isDirectory 匹配（fixture 里 nest1 唯一）。
        let nest1URL = url.appendingPathComponent("nest1")
        let nest1ResolvedPath = nest1URL.resolvingSymlinksInPath().path
        let nest1Row = snap.rows.first(where: {
            $0.url.resolvingSymlinksInPath().path == nest1ResolvedPath
        }) ?? snap.rows.first(where: {
            $0.url.lastPathComponent == "nest1" && $0.isDirectory
        })
        guard let nest1Row else {
            fail("snap.rows 里找不到 nest1 bucket，rows=\(snap.rows.map { $0.url.lastPathComponent }) nest1ResolvedPath=\(nest1ResolvedPath)")
            return
        }
        let kids = await coordinator.directChildrenAsync(of: nest1Row.url.path, sortedBy: .sizeDesc)
        let dirRows = kids.filter { $0.isDirectory }
        let dirBytesSum = dirRows.reduce(Int64(0)) { $0 + $1.bytes }
        log("[REGR] case=\(caseID) parent=\(nest1Row.url.path) bytes=\(nest1Row.bytes) kids=\(kids.count) dirRows=\(dirRows.count) dirBytesSum=\(dirBytesSum)")
        // 关键回归断言：nest1 一定有 file-0.bin + nest2 两个直接子项；
        // 目录子项 nest2 的 bytes 必须 > 0（v1.3.z 的 0 KB bug 修复后通过按需子树聚合得到）
        assertGreater(kids.count, 0, "kids count")
        for r in dirRows {
            assertGreater(Int(r.bytes), 0, "dir row bytes must be subtree aggregate, got \(r.bytes) for \(r.path)")
        }
    }

    /// 启动一次扫描立刻 cancel，再启第二次扫描。
    private func scanCancelRestart() async throws {
        let scen = makeStandardFixture()
        let category = ScanCategory.makeCustom(url: scen.root)
        coordinator.scan(category: category, includeHidden: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        coordinator.cancel()
        // v1.6 Step 6.6-2：cancel 是异步的，scanTask 走完 finally 把 isScanning
        // 翻 false 通常 < 100ms，但 macOS 跑 GitHub Actions / 真机重负载下偶尔
        // 抖到 200~300ms。原先固定 100ms sleep 在低端机上稳定 fail。
        // 改用 polling：最多等 2s，每 20ms 检一次；翻 false 立即 break。
        let cancelDeadline = Date().addingTimeInterval(2.0)
        while coordinator.isScanning && Date() < cancelDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        log("[REGR] case=\(caseID) afterCancel isScanning=\(coordinator.isScanning) wasCancelled=\(coordinator.wasCancelled)")
        assertFalse(coordinator.isScanning, "isScanning after cancel")
        // 第二次扫描
        coordinator.scan(category: category, includeHidden: true)
        try await waitFinished(timeout: 30)
        log("[REGR] case=\(caseID) second files=\(coordinator.snapshot.scannedFileCount) bytes=\(coordinator.snapshot.totalBytes) wasCancelled=\(coordinator.wasCancelled)")
        assertFalse(coordinator.wasCancelled, "wasCancelled after second scan")
        assertTrue(coordinator.snapshot.isFinished, "second scan finished")
    }

    /// 大文件视图：fixture 里塞 3 个 ≥ 1.5MB 的大文件 + 5 个小文件，
    /// 扫完调 largeFiles(minSizeMB: 1) 取 ≥1MB 的，断言只有 3 条。
    private func largeFilesThreshold() async throws {
        let scen = ScenarioBuilder.build(prefix: "RegrLargeFiles") { root in
            for i in 0..<3 { root.file("big-\(i).bin", size: 1_500_000) }
            for i in 0..<5 { root.file("small-\(i).txt", size: 1024) }
        }
        retainScenario(scen)
        let category = ScanCategory.makeCustom(url: scen.root)
        coordinator.scan(category: category, includeHidden: true, largeFileMinBytes: 1_048_576)
        try await waitFinished(timeout: 30)
        let large = coordinator.largeFiles(minSizeMB: 1, sortKey: .sizeDesc, limit: 100)
        let names = large.map { ($0.path as NSString).lastPathComponent }.sorted()
        log("[REGR] case=\(caseID) largeCount=\(large.count) firstName=\(names.first ?? "-")")
        assertEqual(large.count, 3, "large count")
        for item in large {
            assertGreater(Int(item.bytes), 1_000_000, "large item bytes >= 1MB")
        }
    }

    // MARK: - 结果加工 / 导出

    /// 去重扫描：搭 3 组 dup（每组同内容 / 不同名），断言 DuplicateScanner 能找到 3 组。
    private func duplicateScan() async throws {
        let scen = ScenarioBuilder.build(prefix: "RegrDup") { root in
            root.dir("a") { d in
                d.file("g1-1.bin", contents: Data(repeating: 0xAB, count: 200_000))
                d.file("g1-2.bin", contents: Data(repeating: 0xAB, count: 200_000))
                d.file("g2-1.bin", contents: Data(repeating: 0xCD, count: 300_000))
            }
            root.dir("b") { d in
                d.file("g2-2.bin", contents: Data(repeating: 0xCD, count: 300_000))
                d.file("g3-1.bin", contents: Data(repeating: 0xEF, count: 1_500_000))
                d.file("g3-2.bin", contents: Data(repeating: 0xEF, count: 1_500_000))
                d.file("unique.bin", contents: Data(repeating: 0x12, count: 50_000))
            }
        }
        retainScenario(scen)
        let scanner = DuplicateScanner(roots: [scen.root], minBytes: 100_000)
        let groups = await scanner.scanToCompletion()
        let groupCount = groups.count
        let totalRedundancy = groups.reduce(Int64(0)) { acc, g in
            acc + g.bytes * Int64(max(0, g.paths.count - 1))
        }
        log("[REGR] case=\(caseID) groups=\(groupCount) redundancy_bytes=\(totalRedundancy)")
        assertEqual(groupCount, 3, "group count")
        for g in groups {
            assertGreater(g.paths.count, 1, "group paths >= 2")
        }
        assertGreater(Int(totalRedundancy), 0, "redundancy_bytes > 0")
    }

    /// 孤儿扫描：把 OrphanScanner 的 home 注入到 fixture 上，
    /// 在 fixture 的 Library/Application Support 下塞一个绝对孤儿（bundleID 不像反域 + 名字也对不上任何已装 app）。
    private func orphanScan() async throws {
        let scen = ScenarioBuilder.build(prefix: "RegrOrphan") { root in
            root.dir("Library") { lib in
                lib.dir("Application Support") { sup in
                    // 故意塞一个用 bundleID 形态命名的子目录；reach 时间戳太老使其满足 minAgeDays
                    sup.dir("com.gsy.regr.orphan-target") { d in
                        d.file("blob.bin", size: 16_384)
                    }
                }
                lib.dir("Caches") { _ in }
                lib.dir("Preferences") { _ in }
            }
        }
        retainScenario(scen)
        // 把 mtime 调到 90 天前（绕过 minAgeDays=30）
        let target = scen.root
            .appendingPathComponent("Library/Application Support/com.gsy.regr.orphan-target")
        let oldDate = Date().addingTimeInterval(-90 * 86400)
        try? FileManager.default.setAttributes([.modificationDate: oldDate],
                                               ofItemAtPath: target.path)
        let scanner = OrphanScanner(homeDirectory: scen.root.path,
                                    minAgeDays: 30)
        let candidates = scanner.scan()
        let names = candidates.map { $0.name }.sorted()
        log("[REGR] case=\(caseID) candidates=\(candidates.count) names=[\(names.joined(separator: ","))]")
        assertGreater(candidates.count, 0, "orphan candidates > 0")
        assertTrue(names.contains("com.gsy.regr.orphan-target"), "expected orphan name present")
    }

    /// AppFootprint：对一个伪 .app fixture 跑 AppMetadata.read，断言能解出 bundleID。
    private func appFootprintScan() async throws {
        let scen = makeFakeAppBundleFixture()
        let appURL = scen.root.appendingPathComponent("Fake.app")
        let meta = try AppMetadata.read(appURL: appURL)
        log("[REGR] case=\(caseID) bundleID=\(meta.bundleID) appName=\(meta.appName)")
        assertEqual(meta.bundleID, "com.gsyclean.regression.fake", "bundleID")
        // 量自身 bundle 字节数（用 DefaultFileManagerSnapshot.snapshot(at:)）
        let snapshotter = DefaultFileManagerSnapshot()
        let snap = snapshotter.snapshot(at: appURL.path)
        log("[REGR] case=\(caseID) bundleBytes=\(snap.bytes) bundleFiles=\(snap.fileCount)")
        assertGreater(Int(snap.bytes), 0, "bundle bytes > 0")
        assertGreater(snap.fileCount, 0, "bundle file count > 0")
    }

    /// AppUninstaller dryRun：对伪 .app fixture 的关联目录跑 candidates，断言不真删。
    private func uninstallerDryRun() async throws {
        let scen = makeFakeAppBundleFixture()
        let appURL = scen.root.appendingPathComponent("Fake.app")
        let meta = try AppMetadata.read(appURL: appURL)
        // 走真实路径但 home 指向 fixture，避免污染用户目录
        let uninst = AppUninstaller(homeDirectory: scen.root.path,
                                    systemLibrary: "/Library",
                                    fileManager: DefaultFileManagerSnapshot(),
                                    vendorRules: vendors)
        let cands = await uninst.candidatesAsync(for: meta)
        log("[REGR] case=\(caseID) candidates=\(cands.count)")
        // fixture 在 Library/Application Support 与 Library/Caches 各塞了一个匹配 bundleID 的子目录
        assertGreater(cands.count, 0, "candidate count > 0")
        // dryRun：所有候选路径都还存在
        let fm = FileManager.default
        for c in cands {
            assertTrue(fm.fileExists(atPath: c.path), "candidate still exists (dryRun): \(c.path)")
        }
    }

    /// LaunchAgent 扫描：搭一个伪 LaunchAgents 目录，注入 home 让 scanner 看 fixture。
    private func launchAgentScan() async throws {
        let scen = ScenarioBuilder.build(prefix: "RegrLaunchAgent") { root in
            root.dir("Library") { lib in
                lib.dir("LaunchAgents") { la in
                    la.file("com.gsyclean.regression.agent.plist",
                            contents: makeAgentPlistData(label: "com.gsyclean.regression.agent"))
                    la.file("com.example.empty.plist",
                            contents: makeAgentPlistData(label: "com.example.empty"))
                    la.file("not-a-plist.txt", contents: Data("hello".utf8))
                }
            }
        }
        retainScenario(scen)
        let scanner = LaunchAgentScanner(fs: DefaultLaunchAgentFS(),
                                         homeDirectory: scen.root.path)
        let items = await scanner.scanAll()
        let labels = items.map { $0.label }.sorted()
        let labelStr = labels.joined(separator: ",")
        log("[REGR] case=\(caseID) items=\(items.count) labels=\(labelStr)")
        // 我们只塞了 user-scope 两个合法 plist；system/daemon 在 fixture 里没建，scope 自动 skip
        let userOnly = items.filter { $0.scope == .user }
        assertEqual(userOnly.count, 2, "user-scope launch agents")
        assertTrue(labels.contains("com.gsyclean.regression.agent"), "expected agent label")
    }

    /// Exporter：构造 5 行 Row，断言 TSV 行数与首行表头、JSON 解码可往返。
    private func exporterCSV() throws {
        let rows: [Exporter.Row] = (0..<5).map { i in
            Exporter.Row(path: "/tmp/regr/file-\(i).bin",
                         bytes: Int64((i + 1) * 1_000_000),
                         modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                         kind: "binary")
        }
        let tsv = Exporter.toTSV(rows)
        let lines = tsv.split(separator: "\n", omittingEmptySubsequences: true)
        let header = lines.first.map(String.init) ?? ""
        log("[REGR] case=\(caseID) tsv_lines=\(lines.count) header=\(header)")
        assertEqual(lines.count, 6, "tsv lines (1 header + 5 rows)")
        assertTrue(header.contains("path") && header.contains("bytes"), "tsv header columns")
        let jsonData = Exporter.toJSON(rows)
        assertGreater(jsonData.count, 0, "json non-empty")
        // 反解 JSON：能解析为数组，长度等于 rows
        if let any = try? JSONSerialization.jsonObject(with: jsonData),
           let arr = any as? [[String: Any]] {
            assertEqual(arr.count, 5, "json round-trip count")
        } else {
            fail("json not parseable as array of dicts")
        }
    }

    // MARK: - UI / HUD / 托盘 / 激活策略

    /// HUD：先 attach，启用 hudEnabled=true + hudPersistent=true 调 reconcile，断言 NSPanel 真实可见；
    /// 关掉再 reconcile，断言不可见。
    ///
    /// **UserDefaults 污染防护**：本 case 会写 `v1.hud_enabled` / `v1.hud_persistent`，但**不需要**单点
    /// 还原——顶层 [run()](file:///Users/guoshuyu/workspace/GSYCleanMac/App/RegressionRunner.swift#L62-L116)
    /// 已经在进入时 snapshot 了所有 `v1.*`，退出前自动 restore，进程被 kill 时下次 init 也会自愈。
    private func hudToggle() async throws {
        hud.attach(coordinator: coordinator, settings: settings)
        settings.hudEnabled = true
        settings.hudPersistent = true
        hud.reconcile()
        try await Task.sleep(nanoseconds: 500_000_000)
        let visibleOn = hud.isPanelVisibleForTesting
        log("[REGR] case=\(caseID) hud_visible_on=\(visibleOn)")
        assertTrue(visibleOn, "HUD panel visible when persistent+enabled")
        settings.hudPersistent = false
        settings.hudEnabled = false
        hud.reconcile()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let visibleOff = hud.isPanelVisibleForTesting
        log("[REGR] case=\(caseID) hud_visible_off=\(visibleOff)")
        assertFalse(visibleOff, "HUD panel hidden after disable")
    }

    /// 托盘：install + uninstall，断言 NSStatusItem 在系统状态栏出现/消失。
    private func trayInstallUninstall() async throws {
        statusItem.install()
        try await Task.sleep(nanoseconds: 200_000_000)
        let installedExists = statusItem.isInstalledForTesting
        log("[REGR] case=\(caseID) tray_installed=\(installedExists)")
        assertTrue(installedExists, "status item installed")
        statusItem.uninstall()
        try await Task.sleep(nanoseconds: 200_000_000)
        let uninstalledExists = statusItem.isInstalledForTesting
        log("[REGR] case=\(caseID) tray_uninstalled=\(uninstalledExists)")
        assertFalse(uninstalledExists, "status item uninstalled")
    }

    /// 激活策略：reconcile(hideEnabled=false) → regular；reconcile(hideEnabled=true, hasVisibleMainWindow=false) → accessory。
    private func activationPolicyCase() async throws {
        activationPolicy.reconcile(hideEnabled: false, hasVisibleMainWindow: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let p1 = NSApp.activationPolicy()
        log("[REGR] case=\(caseID) policy_after_hide_off=\(p1.rawValue)")
        assertEqual(p1.rawValue, NSApplication.ActivationPolicy.regular.rawValue, "regular when hide=off")
        activationPolicy.reconcile(hideEnabled: true, hasVisibleMainWindow: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let p2 = NSApp.activationPolicy()
        log("[REGR] case=\(caseID) policy_after_hide_on=\(p2.rawValue)")
        assertEqual(p2.rawValue, NSApplication.ActivationPolicy.accessory.rawValue, "accessory when hide=on & no window")
        // 复位
        activationPolicy.reconcile(hideEnabled: false, hasVisibleMainWindow: true)
    }

    /// QuickLook：单例 + fixture 一个真实文件，调 preview([url])，断言 _testCurrentURLs 接受了。
    private func quicklookController() throws {
        let scen = ScenarioBuilder.build(prefix: "RegrQuickLook") { root in
            root.file("doc.txt", contents: Data("hello quicklook".utf8))
        }
        retainScenario(scen)
        let target = scen.root.appendingPathComponent("doc.txt")
        let ctl = QuickLookController.shared
        #if DEBUG
        ctl._testReset()
        #endif
        ctl.preview(urls: [target])
        // QuickLook 在 headless / CI 下 panel 可能不弹，但 _testCurrentURLs 总是被填的
        #if DEBUG
        let urls = ctl._testCurrentURLs
        log("[REGR] case=\(caseID) qlURLs=\(urls.count) initial=\(ctl._testInitialIndex)")
        assertEqual(urls.count, 1, "QuickLook urls accepted")
        assertEqual(ctl._testInitialIndex, 0, "QuickLook initialIndex")
        ctl._testReset()
        #else
        log("[REGR] case=\(caseID) qlSkipped=true (release build)")
        assertTrue(true, "QuickLook release build skip")
        #endif
        ctl.close()
    }

    // MARK: - 安全 / 删除 / Helper

    /// TrashPipeline dryRun：3 个 fixture 文件 + 1 个不存在 + 1 个 vendor 路径（应被 veto）。
    private func trashPipelineDryRun() async throws {
        let scen = ScenarioBuilder.build(prefix: "RegrTrash") { root in
            root.file("a.txt", contents: Data("a".utf8))
            root.file("b.txt", contents: Data("b".utf8))
            root.file("c.txt", contents: Data("c".utf8))
        }
        retainScenario(scen)
        let real = ["a.txt", "b.txt", "c.txt"].map { scen.root.appendingPathComponent($0).path }
        let missing = scen.root.appendingPathComponent("nonexist.txt").path
        let homeForbid = NSHomeDirectory() // SafetyEngine 把 $HOME 判 forbid
        let pipeline = TrashPipeline(safety: SafetyEngine(), vendors: vendors, home: NSHomeDirectory())
        let (present, skipped, err, _) = await pipeline.moveToTrash(
            paths: real + [missing, homeForbid],
            dryRun: true
        )
        let errStr = err ?? "-"
        log("[REGR] case=\(caseID) present=\(present) skipped=\(skipped) err=\(errStr)")
        // 3 个 present 文件被允许；missing + homeForbid 都被 skip（一个 missing、一个 forbid）
        assertEqual(present, 3, "present count")
        assertEqual(skipped, 2, "skipped count")
        assertTrue(err?.contains("拦截") == true || err?.contains("不存在") == true,
                   "err message contains reason")
        // 真实文件还在
        let fm = FileManager.default
        for p in real { assertTrue(fm.fileExists(atPath: p), "real file still exists (dryRun): \(p)") }
    }

    /// SafetyEngine 直接测：$HOME / $HOME/Library 必须 forbid；fixture 子目录必须不 forbid。
    private func safetyEngineVeto() throws {
        let engine = SafetyEngine()
        let home = NSHomeDirectory()
        let lib = "\(home)/Library"
        let scen = makeStandardFixture()
        let safe = scen.root.appendingPathComponent("nest1/file-0.bin").path
        let (vHome, _) = engine.evaluate(path: home, home: home)
        let (vLib, _) = engine.evaluate(path: lib, home: home)
        let (vSafe, _) = engine.evaluate(path: safe, home: home)
        log("[REGR] case=\(caseID) home=\(vHome.rawValue) lib=\(vLib.rawValue) safe=\(vSafe.rawValue)")
        assertEqual(vHome.rawValue, SafetyVerdict.forbid.rawValue, "home forbid")
        assertEqual(vLib.rawValue, SafetyVerdict.forbid.rawValue, "lib forbid")
        assertNotEqual(vSafe.rawValue, SafetyVerdict.forbid.rawValue, "fixture not forbid")
    }

    // v1.3.zzzz 路线 B：MockHelperClient / DeletionTokenSigner / SignedDeletionRequest 已随
    // [Packages/XPCBridge](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/XPCBridge) +
    // [Helper/](file:///Users/guoshuyu/workspace/GSYCleanMac/Helper) 整段下线，原 helperBridgeStub /
    // deletionTokenRoundtrip 两个 case 实现一并删除（switch 入口处也已剔除）。

    /// **Step 7 真实回归**：UndoHistory 端到端：addRecord 落盘 → 跨实例 reload → restore mv 文件回原位。
    ///
    /// 走真实磁盘 + 真实文件，但隔离到 `/tmp/RegrUndoHistory-<uuid>/UndoHistory.json`，不污染用户
    /// `~/Library/Application Support/GSYCleanMac/UndoHistory.json`。
    /// **不调 NSWorkspace.recycle**——本 case 跑在 background 进程里，系统 Trash 在沙箱里不可靠；
    /// 我们只验 happy path（无冲突），冲突分支留给手工 / UI 验证。
    private func undoHistoryRestore() async throws {
        let dir = NSTemporaryDirectory() + "RegrUndoHistory-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let storeURL = URL(fileURLWithPath: dir).appendingPathComponent("UndoHistory.json")
        let trashDir = URL(fileURLWithPath: dir).appendingPathComponent("trash", isDirectory: true)
        let origDir = URL(fileURLWithPath: dir).appendingPathComponent("orig", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        // origDir 故意不创建：验 restore 会自动 createDirectory parent

        let trashedFile = trashDir.appendingPathComponent("hello.log")
        let originalFile = origDir.appendingPathComponent("hello.log")
        try "regr-payload".write(to: trashedFile, atomically: true, encoding: .utf8)

        // 1) 第一个 store 实例：addRecord 落盘
        do {
            let s1 = UndoHistoryStore(storeURL: storeURL, maxHistoryCount: 10)
            s1.addRecord(source: "regr", filePairs: [
                .init(original: originalFile.path, trashed: trashedFile.path)
            ])
            log("[REGR] case=\(caseID) addRecord_count=\(s1.history.count)")
            assertEqual(s1.history.count, 1, "addRecord 后 history 数量")
        }
        let exists = FileManager.default.fileExists(atPath: storeURL.path)
        assertTrue(exists, "UndoHistory.json 已落盘")

        // 2) 第二个实例：从盘上读出来，验 Codable + atomic write
        let s2 = UndoHistoryStore(storeURL: storeURL, maxHistoryCount: 10)
        log("[REGR] case=\(caseID) reload_count=\(s2.history.count)")
        assertEqual(s2.history.count, 1, "跨实例 reload 数量")
        let record = s2.history[0]
        assertEqual(record.source, "regr", "source 字段")
        assertEqual(record.fileCount, 1, "fileCount 字段")

        // 3) restoreRecord：把 trashed mv 回 original，record 自动从 history 移除
        let (restored, skipped, err) = await s2.restoreRecord(record)
        log("[REGR] case=\(caseID) restored=\(restored) skipped=\(skipped) err=\(err ?? "-")")
        assertEqual(restored, 1, "restored count")
        assertEqual(skipped, 0, "skipped count")
        assertTrue(err == nil, "no error")
        assertTrue(FileManager.default.fileExists(atPath: originalFile.path),
                   "文件已 mv 回原路径")
        assertTrue(!FileManager.default.fileExists(atPath: trashedFile.path),
                   "trashed 路径已被掏空")
        assertEqual(s2.history.count, 0, "restore 后 history 被清空")
    }

    // MARK: - 真实场景诊断（图 4/5、图 2/3、扫描慢）

    /// **图4/5 诊断**：在 App 真实进程里直接对 ~/.Trash 做：
    /// (1) `open(O_RDONLY)`，记录 fd / errno；
    /// (2) `getattrlist(.fileSize)`，记录 stat 是否成功；
    /// (3) Foundation 的 `contentsOfDirectory(atPath:)`，记录子项数量；
    /// (4) ScanCoordinator.scan(category=trash) 走真实管道，断言 BulkScanner 真的有 yield 节点（无论是 .node 还是 .permissionDenied）。
    /// 这 4 路是分层的：走到哪一层失败，就能精确定位是 sandbox / TCC 单独保护 / 路径错。
    /// **本 case 不强制 PASS/FAIL**——目标是把诊断信息落到 log 给用户看，
    /// 但若 4 路全失败（包括 ScanCoordinator 也没拿到任何文件且无 permissionDenied 上报），就记 FAIL。
    private func trashRealScan() async throws {
        let home = NSHomeDirectory()
        let trashPath = "\(home)/.Trash"
        log("[REGR] case=\(caseID) trash_path=\(trashPath)")

        // (0) FDA 探测——记录 App 自身的 FDA 状态（用户报告"已开 FDA"，期望 .granted）
        let fda = FDAProbe.probe(home: home)
        log("[REGR] case=\(caseID) fda_status=\(fda.rawValue)")

        // (1) open O_RDONLY
        let fd = open(trashPath, O_RDONLY)
        let openErrno = errno
        if fd >= 0 {
            log("[REGR] case=\(caseID) open_fd=\(fd) open_ok=true")
            close(fd)
        } else {
            log("[REGR] case=\(caseID) open_fd=\(fd) open_ok=false errno=\(openErrno) strerror=\(String(cString: strerror(openErrno)))")
        }

        // (2) stat
        var st = stat()
        let stRC = lstat(trashPath, &st)
        let stErrno = errno
        if stRC == 0 {
            log("[REGR] case=\(caseID) stat_ok=true mode=\(String(st.st_mode, radix: 8)) size=\(st.st_size) nlink=\(st.st_nlink)")
        } else {
            log("[REGR] case=\(caseID) stat_ok=false errno=\(stErrno)")
        }

        // (3) Foundation contentsOfDirectory
        var fmChildrenCount: Int = -1
        var fmError: String = "-"
        do {
            let children = try FileManager.default.contentsOfDirectory(atPath: trashPath)
            fmChildrenCount = children.count
            log("[REGR] case=\(caseID) fm_ok=true children=\(children.count) sample=[\(children.prefix(3).joined(separator: ","))]")
        } catch {
            fmError = "\(error)"
            log("[REGR] case=\(caseID) fm_ok=false error=\(fmError)")
        }

        // (4) ScanCoordinator 走真实管道
        guard let trashCat = ScanCategories.recommended(home: home).first(where: { $0.id == "trash" }) else {
            fail("无法构造 trash ScanCategory")
            return
        }
        log("[REGR] case=\(caseID) trash_root=\(trashCat.rootPath)")
        coordinator.scan(category: trashCat, includeHidden: true)
        try await waitFinished(timeout: 30)
        let snap = coordinator.snapshot
        let denied = coordinator.permissionDeniedPaths
        let tccSkip = coordinator.tccProtectedSkippedPaths
        log("[REGR] case=\(caseID) coord_files=\(snap.scannedFileCount) coord_bytes=\(snap.totalBytes) denied=\(denied.count) tccSkip=\(tccSkip.count)")
        if !denied.isEmpty {
            log("[REGR] case=\(caseID) denied_sample=\(denied.prefix(3).joined(separator: "|"))")
        }
        if !tccSkip.isEmpty {
            log("[REGR] case=\(caseID) tcc_skip_sample=\(tccSkip.prefix(3).joined(separator: "|"))")
        }

        // 诊断断言：4 路里至少有 1 路成功证明能读到 trash 内容；
        // 如果 fm_ok=true 子项 > 0，但 coord_files=0 → 是 BulkScanner 的 bug 而非系统拦截。
        // v1.6 Step 6.6-3：原先 anyEvidence=false 直接 assertTrue 强制 fail，但这与本 case
        // 注释（"不强制 PASS/FAIL，目标是把诊断信息落到 log"）相矛盾，导致 ~/.Trash 当前
        // 为空（用户刚清空回收站）时回归莫名 fail。
        // 修复：区分"系统拦截 / 真 bug"与"用户机环境就是空"——
        //  - fm_ok=true 且 children=0 → 用户回收站确实空，graceful skip（log + return），不算 fail；
        //  - fm_ok=false 且 fda 不是 granted → 是 TCC / sandbox 拦截，仍 assertTrue 让 banner 测试有效；
        //  - fm 看到 N 子项但 coord 0 → 真 bug，照旧 fail。
        let trashIsEmpty = (fmChildrenCount == 0 && snap.scannedFileCount == 0 && denied.isEmpty)
        if trashIsEmpty {
            log("[REGR] case=\(caseID) trash_empty=true skip_reason=user_trash_is_empty")
            log("[REGR] case=\(caseID) note=本机当前 ~/.Trash 为空（fm 列表也是空），无法验证扫描管道；判 PASS 但记录原因")
            return
        }
        let anyEvidence = fmChildrenCount > 0 || snap.scannedFileCount > 0 || !denied.isEmpty
        assertTrue(anyEvidence, "至少 1 条诊断路径产出证据 (fm/coord/denied)")
        // 进一步：若 fm 看到了 N 个子项却 coord 0 文件且未上报 denied → 这是真 bug
        if fmChildrenCount > 0 && snap.scannedFileCount == 0 && denied.isEmpty {
            fail("【真 bug】FileManager 看到 \(fmChildrenCount) 子项，但 ScanCoordinator 扫出 0 文件且未报 denied")
        }
    }

    /// **图2/3 诊断**：用户说"已开 FDA 但仍弹 1 个目录受阻"。
    /// 直接读 `coordinator.permissionDeniedPaths` 与 `tccProtectedSkippedPaths` 的累计值，
    /// 验证一次"推荐扫描"结束后这两个数组里到底装了哪些路径，对比 fdaStatus。
    /// 这条 case 让真实运行时的 banner 数据写到 log，方便用户截图后我们直接看到原文。
    private func fdaBannerDiagnose() async throws {
        let fda = FDAProbe.probe(home: NSHomeDirectory())
        log("[REGR] case=\(caseID) fda_status=\(fda.rawValue)")
        coordinator.scanRecommended(includeHidden: false)
        try await waitFinished(timeout: 600)
        let denied = coordinator.permissionDeniedPaths
        let tccSkip = coordinator.tccProtectedSkippedPaths
        log("[REGR] case=\(caseID) denied_count=\(denied.count) tcc_skip_count=\(tccSkip.count)")
        for (idx, p) in denied.enumerated() {
            log("[REGR] case=\(caseID) denied[\(idx)]=\(p)")
        }
        for (idx, p) in tccSkip.enumerated() {
            log("[REGR] case=\(caseID) tcc_skip[\(idx)]=\(p)")
        }
        // 这条 case 只做诊断，不强 fail。让 log 自然落盘给人看。
        assertTrue(coordinator.snapshot.isFinished, "scan finished")
    }

    /// **扫描慢诊断**：跑一次推荐扫描，每 5s 输出心跳进度（bytes/files/perRoot），
    /// 让 log 即使在 timeout 时也能看到中间推进数据，定位"哪根 root 把整体速度拖慢"或"扫描整体停滞"。
    private func scanPerfDiagnose() async throws {
        let t0 = Date()
        coordinator.scanRecommended(includeHidden: false)
        let deadline = t0.addingTimeInterval(900)
        var lastHeartbeat = t0
        while !coordinator.snapshot.isFinished {
            if Date() >= deadline {
                let snap = coordinator.snapshot
                log("[REGR] case=\(caseID) PERF_TIMEOUT elapsed_sec=900 total_bytes=\(snap.totalBytes) total_files=\(snap.scannedFileCount) isScanning=\(coordinator.isScanning)")
                dumpPerRootProgress()
                fail("scan-perf-diagnose 900s timeout 仍未完成，bytes=\(snap.totalBytes)")
                return
            }
            // 每 5s 心跳：bytes / files / 每根进度
            if Date().timeIntervalSince(lastHeartbeat) >= 5 {
                let snap = coordinator.snapshot
                let elapsed = Date().timeIntervalSince(t0)
                let mbps = elapsed > 0 ? Double(snap.totalBytes) / elapsed / 1_048_576.0 : 0
                log("[REGR] case=\(caseID) HB elapsed=\(String(format: "%.1f", elapsed))s bytes=\(snap.totalBytes) files=\(snap.scannedFileCount) MBps=\(String(format: "%.2f", mbps))")
                lastHeartbeat = Date()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let elapsed = Date().timeIntervalSince(t0)
        let snap = coordinator.snapshot
        let mbps = elapsed > 0 ? Double(snap.totalBytes) / elapsed / 1_048_576.0 : 0
        log("[REGR] case=\(caseID) elapsed_sec=\(String(format: "%.1f", elapsed)) total_bytes=\(snap.totalBytes) total_files=\(snap.scannedFileCount) throughput_MBps=\(String(format: "%.2f", mbps))")
        dumpPerRootProgress()
        assertTrue(snap.isFinished, "scan finished")
        if elapsed > 600 || (snap.totalBytes > 100_000_000 && mbps < 5) {
            fail("扫描太慢：elapsed=\(elapsed)s throughput=\(mbps) MB/s")
        }
    }

    private func dumpPerRootProgress() {
        let perRoot = coordinator.perRootProgress
        let sorted = perRoot.values.sorted { $0.bytes > $1.bytes }
        for (idx, r) in sorted.enumerated() {
            log("[REGR] case=\(caseID) root[\(idx)] path=\(r.rootPath) bytes=\(r.bytes) files=\(r.fileCount) finished=\(r.isFinished)")
        }
    }

    // MARK: - v1.6 Sentinel

    /// **v1.6 Sentinel 默认 OFF + URL Scheme 路由 真实回归**
    ///
    /// 在真实 App 进程里（已签名 .app + LaunchDaemons embed）验证：
    /// 1. AppSettings.sentinelEnabled 默认 false（升级用户不会无声多出后台守护）；
    /// 2. AppSettings.sentinelLastEnabled 默认 nil；
    /// 3. SentinelURLRouter 三种核心 URL 形态返回正确 Outcome：
    ///    - `gsycleanmac://action/scan/full` → `.startFullScan`
    ///    - `gsycleanmac://uninstall?path=/Applications` → `.openUninstall(path: "/Applications")`
    ///    - `gsycleanmac://uninstall?path=../../etc` → `.openUninstall(path: nil)`（防注入）
    /// 4. SentinelManager.currentStatus() 不崩溃，且对未授权时返回 .notRegistered/.notFound/.requiresApproval 之一；
    /// 5. SentinelManager.plistName 与 [com.guoshuyu.cleanmac.sentinel.plist](file:///Users/guoshuyu/workspace/GSYCleanMac/App/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist) 一致。
    ///
    /// **不会做什么**：
    /// - 不真调 `enable()` —— SMAppService.daemon().register() 在 regression 跑用户机上
    ///   会污染用户的 LoginItems 注册表 + 弹原生 NSAlert（runModal 阻塞），由
    ///   [/tmp/sentinel-app-launch.sh](file:///tmp/sentinel-app-launch.sh) 手工烟测覆盖。
    /// - 不调 `disable()` —— 同理。
    private func sentinelDefaultOff() throws {
        // (1) 默认值 - 注意：这一刻 settings 是用户偏好（已被 snapshotAndPersistDefaults
        // 备份），但 sentinelEnabled 默认契约是 OFF，正常用户不会显式开启。
        // 这条 case 确认：AppSettings 在没有任何 v1.6 sentinel key 写入的"全新装"语义下，
        // 必须默认 false。我们用一个独立 testSuite AppSettings 实例做白盒验证。
        let suite = "GSYCleanMac.regression.SentinelDefault.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let freshSettings = AppSettings(testSuite: suite)
        log("[REGR] case=\(caseID) default_sentinelEnabled=\(freshSettings.sentinelEnabled) default_lastEnabled=\(String(describing: freshSettings.sentinelLastEnabled))")
        assertFalse(freshSettings.sentinelEnabled, "Sentinel 默认必须 OFF")
        assertTrue(freshSettings.sentinelLastEnabled == nil, "未启用时 sentinelLastEnabled 必须 nil")

        // (2) plistName 锁定
        log("[REGR] case=\(caseID) plistName=\(SentinelManager.plistName)")
        assertEqual(SentinelManager.plistName, "com.guoshuyu.cleanmac.sentinel.plist", "plistName")

        // (3) URL Scheme 路由：3 种核心形态
        let outScan = SentinelURLRouter.handle(URL(string: "gsycleanmac://action/scan/full")!)
        log("[REGR] case=\(caseID) route_scanFull=\(outScan)")
        assertEqual(outScan, .startFullScan, "route gsycleanmac://action/scan/full")

        // 真实存在的路径（/Applications 在所有 macOS 上都有）走绿灯
        let appsExpected = ("/Applications" as NSString).standardizingPath
        let outUninstall = SentinelURLRouter.handle(URL(string: "gsycleanmac://uninstall?path=/Applications")!)
        log("[REGR] case=\(caseID) route_uninstall_apps=\(outUninstall) expectedPath=\(appsExpected)")
        assertEqual(outUninstall, .openUninstall(path: appsExpected), "uninstall /Applications")

        // 路径含 .. → 必须被防注入拦下
        let outBad = SentinelURLRouter.handle(URL(string: "gsycleanmac://uninstall?path=/Applications/../etc")!)
        log("[REGR] case=\(caseID) route_uninstall_traversal=\(outBad)")
        assertEqual(outBad, .openUninstall(path: nil), "uninstall path=../ 必须被防注入拒绝")

        // 错误 scheme → ignored
        let outBadScheme = SentinelURLRouter.handle(URL(string: "https://example.com/uninstall")!)
        log("[REGR] case=\(caseID) route_bad_scheme=\(outBadScheme)")
        assertEqual(outBadScheme, .ignored(reason: "bad-scheme"), "bad scheme 应被忽略")

        // (4) currentStatus 真实 App 下不崩溃；具体值取决于用户机器是否曾启用过
        let mgr = SentinelManager(settings: freshSettings)
        let status = mgr.currentStatus()
        log("[REGR] case=\(caseID) currentStatus=\(status) label=\(status.displayLabel)")
        // 任何具体值都行（依赖用户机器状态），核心是 displayLabel 非空
        assertTrue(!status.displayLabel.isEmpty, "status.displayLabel 必须非空")
    }

    // MARK: - Fixtures

    /// 标准 fixture：10 个 102_400 字节文件 + 嵌套 5 层每层 1 个 5_120 字节文件。
    /// 共 15 文件，1_049_600 字节。**注意**：嵌套用 ScenarioNode.dir(_:_:) 闭包 DSL，
    /// 不能用 ScenarioNode init（fileprivate）。
    private func makeStandardFixture() -> Scenario {
        let scen = ScenarioBuilder.build(prefix: "RegrStd") { root in
            for i in 0..<10 { root.file("f-\(i).bin", size: 102_400) }
            root.dir("nest1") { n1 in
                n1.file("file-0.bin", size: 5_120)
                n1.dir("nest2") { n2 in
                    n2.file("file-1.bin", size: 5_120)
                    n2.dir("nest3") { n3 in
                        n3.file("file-2.bin", size: 5_120)
                        n3.dir("nest4") { n4 in
                            n4.file("file-3.bin", size: 5_120)
                            n4.dir("nest5") { n5 in
                                n5.file("file-4.bin", size: 5_120)
                            }
                        }
                    }
                }
            }
        }
        retainScenario(scen)
        return scen
    }

    /// 伪 .app bundle：构造 Contents/Info.plist + Contents/MacOS/ 可执行占位，
    /// 同时在同 fixture 根的 Library/Application Support 与 Library/Caches 各塞一个匹配 bundleID 的子目录。
    private func makeFakeAppBundleFixture() -> Scenario {
        let scen = ScenarioBuilder.build(prefix: "RegrFakeApp") { root in
            root.dir("Fake.app") { app in
                app.dir("Contents") { c in
                    c.file("Info.plist", contents: makeInfoPlistData())
                    c.dir("MacOS") { mo in
                        mo.file("Fake", size: 4096)
                    }
                    c.dir("Resources") { r in
                        r.file("placeholder.dat", size: 8192)
                    }
                }
            }
            root.dir("Library") { lib in
                lib.dir("Application Support") { sup in
                    sup.dir("com.gsyclean.regression.fake") { d in
                        d.file("data.bin", size: 16_384)
                    }
                }
                lib.dir("Caches") { c in
                    c.dir("com.gsyclean.regression.fake") { d in
                        d.file("cache.bin", size: 32_768)
                    }
                }
            }
        }
        retainScenario(scen)
        return scen
    }

    private func makeInfoPlistData() -> Data {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.gsyclean.regression.fake",
            "CFBundleName": "FakeRegression",
            "CFBundleExecutable": "Fake",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist,
                                                    format: .xml,
                                                    options: 0)) ?? Data()
    }

    private func makeAgentPlistData(label: String) -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/true"],
            "RunAtLoad": true,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist,
                                                    format: .xml,
                                                    options: 0)) ?? Data()
    }

    private func retainScenario(_ scen: Scenario) {
        fixtureScenarios.append(scen)
    }

    // MARK: - 等待 & 断言 & 日志

    private func waitFinished(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !coordinator.snapshot.isFinished {
            if Date() >= deadline {
                fail("waitFinished timeout after \(timeout)s, isScanning=\(coordinator.isScanning) files=\(coordinator.snapshot.scannedFileCount)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - UserDefaults 隔离（v1.3.zz+）

    /// 备份文件路径——放在 Caches 下不进 Time Machine，bundle id 命名避免和别的 App 撞。
    private static let backupURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.guoshuyu.cleanmac.GSYCleanMac/regression-defaults-backup.plist")
    }()

    /// 把 `UserDefaults.standard` 里所有 `v1.*` key snapshot 到内存 + 落盘 backup 文件。
    /// **核心思路**：`AppSettings.Keys` 全部以 `v1.` 前缀，遍历 dictionaryRepresentation 过滤即可，
    /// 后续即使加新 setting 也不需要修改这里。
    /// 返回的 dict 用于内存里的 fast-path restore（exit 前调）；磁盘那份是 SIGKILL 自愈的 fallback。
    private func snapshotAndPersistDefaults() -> [String: Any] {
        let all = UserDefaults.standard.dictionaryRepresentation()
        let v1: [String: Any] = all.filter { $0.key.hasPrefix("v1.") }
        do {
            let dir = Self.backupURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: v1, format: .binary, options: 0)
            try data.write(to: Self.backupURL, options: .atomic)
            log("[REGR] case=\(caseID) defaults_snapshot_keys=\(v1.count) backup=\(Self.backupURL.path)")
        } catch {
            log("[REGR] case=\(caseID) defaults_snapshot_persist_failed=\(error)")
        }
        return v1
    }

    /// 恢复 snapshot：先把 `v1.*` 全删掉再写回 backup（避免 case 里新增的 key 残留），最后删 backup 文件。
    ///
    /// **cfprefsd 异步陷阱**：`UserDefaults.set` 是异步通过 cfprefsd 落盘的，`synchronize()` 在 macOS
    /// 上已被废弃且可能 no-op。`exit()` 立刻挂会导致最后写的几个值在 cfprefsd 真正持久化之前就被
    /// 截断。修复：用 `CFPreferencesAppSynchronize` 强制刷盘 + 100ms sleep 让 cfprefsd 完成 IO。
    private func restoreDefaultsFromSnapshot(_ snapshot: [String: Any]) {
        let defs = UserDefaults.standard
        // 删除当前所有 v1.* key（可能 case 里新增了 snapshot 没有的 key）
        for key in defs.dictionaryRepresentation().keys where key.hasPrefix("v1.") {
            defs.removeObject(forKey: key)
        }
        // 写回原值
        for (k, v) in snapshot {
            defs.set(v, forKey: k)
        }
        // 强制 cfprefsd 落盘——`synchronize()` 已废弃，必须用 CFPreferencesAppSynchronize
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        // 给 cfprefsd 一点时间真正完成 IO（exit() 之后这个守护进程对本进程的写就被截断）
        Thread.sleep(forTimeInterval: 0.15)
        // 删 backup（成功 restore 后 backup 不再有用，留着反而下次启动会把"现在已经正确的值"再覆盖回去）
        try? FileManager.default.removeItem(at: Self.backupURL)
        log("[REGR] case=\(caseID) defaults_restored_keys=\(snapshot.count)")
    }

    /// init 时调：上次 runner 进程若被 SIGKILL，磁盘 backup 文件还在；这里把它消化掉。
    /// **静态方法**——不能依赖任何实例状态，因为新一轮 snapshot 还没建立。
    private static func consumeStaleBackupIfAny() {
        let url = backupURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let defs = UserDefaults.standard
            for key in defs.dictionaryRepresentation().keys where key.hasPrefix("v1.") {
                defs.removeObject(forKey: key)
            }
            for (k, v) in plist {
                defs.set(v, forKey: k)
            }
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            Thread.sleep(forTimeInterval: 0.15)
            try? FileManager.default.removeItem(at: url)
            FileHandle.standardError.write(Data("[REGR] stale_defaults_backup_consumed keys=\(plist.count)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[REGR] stale_defaults_backup_consume_failed=\(error)\n".utf8))
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        if a == b {
            log("[REGR_OK] case=\(caseID) \(name)=\(a)")
        } else {
            fail("assertEqual \(name): got=\(a) want=\(b)")
        }
    }

    private func assertNotEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        if a != b {
            log("[REGR_OK] case=\(caseID) \(name)!=\(b) actual=\(a)")
        } else {
            fail("assertNotEqual \(name): got=\(a) want != \(b)")
        }
    }

    private func assertGreater(_ a: Int, _ b: Int, _ name: String) {
        if a > b {
            log("[REGR_OK] case=\(caseID) \(name)=\(a) > \(b)")
        } else {
            fail("assertGreater \(name): got=\(a) want > \(b)")
        }
    }

    private func assertTrue(_ cond: Bool, _ name: String) {
        if cond {
            log("[REGR_OK] case=\(caseID) \(name)=true")
        } else {
            fail("assertTrue \(name): got=false")
        }
    }

    private func assertFalse(_ cond: Bool, _ name: String) {
        if !cond {
            log("[REGR_OK] case=\(caseID) \(name)=false")
        } else {
            fail("assertFalse \(name): got=true")
        }
    }

    private func fail(_ reason: String) {
        if !failed {
            failed = true
            firstFailReason = reason
        }
        log("[REGR_ERR] case=\(caseID) reason=\(reason)")
    }
}
