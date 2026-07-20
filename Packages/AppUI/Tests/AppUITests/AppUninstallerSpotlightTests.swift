import XCTest
@testable import AppUI

/// AppUninstaller —— Spotlight 兜底补刀测试（Step 11A / 2026-06）
///
/// 验证：[AppUninstaller.spotlightFallback](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
///
/// 测试主题：
/// 1. Spotlight 命中非典型路径 → 加入候选 + matchReason=.spotlight("bundleID")
/// 2. Spotlight 返回的路径已存在主路径中 → dedup 不重复添加
/// 3. Spotlight 返空 → candidatesAsync 正常返回主路径结果（fail-soft）
/// 4. Spotlight 命中的路径在 home/systemLibrary 之外 → 拒绝（防穿透 /System）
/// 5. appName 长度 < 4 / 命中常见噪音词 → 跳过 appName 谓词查询
final class AppUninstallerSpotlightTests: XCTestCase {

    // MARK: - Helpers

    /// In-memory FakeFM（与 [AppUninstallerTests.FakeFM](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/AppUninstallerTests.swift)
    /// 同款思路）。
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

    /// FakeSpotlight：根据预设字典返回固定路径。
    private struct FakeSpotlight: SpotlightProbing {
        let byBundleID: [String: [String]]
        let byAppName: [String: [String]]
        func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] {
            byBundleID[bundleID] ?? []
        }
        func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] {
            byAppName[appName] ?? []
        }
    }

    private struct SlowSpotlight: SpotlightProbing {
        let delay: TimeInterval

        func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return []
        }

        func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return []
        }
    }

    private struct FailedSpotlight: SpotlightProbing {
        let paths: [String]
        let failure: SpotlightProbeFailure

        init(paths: [String] = [], failure: SpotlightProbeFailure) {
            self.paths = paths
            self.failure = failure
        }

        func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] { [] }
        func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] { [] }
        func probeByBundleIDEvidence(
            _ bundleID: String,
            timeout: TimeInterval
        ) async -> SpotlightProbeResult {
            SpotlightProbeResult(paths: paths, failure: failure)
        }
        func probeByAppNameEvidence(
            _ appName: String,
            timeout: TimeInterval
        ) async -> SpotlightProbeResult {
            SpotlightProbeResult(paths: paths, failure: failure)
        }
    }

    private struct TypedRootFM: FileManagerSnapshotting {
        let incompleteRoot: String?

        func firstLevelEntries(at path: String) -> [FSEntry]? { nil }
        func firstLevelDiscovery(at path: String) -> FSFirstLevelDiscoveryResult {
            if path == incompleteRoot {
                return .incomplete(stage: .enumeration, reason: .permissionDenied)
            }
            return .missing
        }
        func snapshot(at path: String) -> FSSnapshot {
            .init(bytes: 0, fileCount: 0, exists: false)
        }
    }

    private let demoMeta = AppMetadata(
        bundleID: "com.acme.demo",
        bundleVendor: "com.acme",
        appName: "Demo",
        executableName: nil
    )

    // 长一点 + 非噪音词的 appName，用于 appName 谓词分支测试
    private let longNameMeta = AppMetadata(
        bundleID: "com.acme.unique",
        bundleVendor: "com.acme",
        appName: "AcmeUniqueApp",
        executableName: nil
    )

    // MARK: - 1. Spotlight 命中非典型路径

    func test_Spotlight命中非典型路径_补刀加入候选_matchReason为spotlight() async {
        let home = "/H"
        // 主路径所有 root 返空
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            // Spotlight 命中的非典型路径（不在主 12 root 第一层）
            "/H/Documents/AcmeData": .init(bytes: 9999, fileCount: 12)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: ["com.acme.demo": ["/H/Documents/AcmeData"]],
            byAppName: [:]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 1, "Spotlight 应补刀产出 1 条候选")
        let cand = result[0]
        XCTAssertEqual(cand.path, "/H/Documents/AcmeData")
        XCTAssertEqual(cand.bytes, 9999)
        XCTAssertEqual(cand.fileCount, 12)
        if case .spotlight(let kind) = cand.matchReason {
            XCTAssertEqual(kind, "bundleID", "matchReason 应携带谓词类别")
        } else {
            XCTFail("matchReason 应为 .spotlight(\"bundleID\")")
        }
    }

    // MARK: - 2. dedup 与主路径

    func test_Spotlight返回的路径已在主路径_dedup不重复添加() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        // 主路径下放一个 bundleID 严格相等命中（matchReason=.bundleID）
        let mainEntry = FSEntry(name: "com.acme.demo", path: "\(cachesPath)/com.acme.demo")
        let fake = FakeFM(
            entriesByRoot: [cachesPath: [mainEntry]],
            snapshots: [
                mainEntry.path: .init(bytes: 1000, fileCount: 5)
            ]
        )
        // Spotlight 返回**同一个**路径
        let spotlight = FakeSpotlight(
            byBundleID: ["com.acme.demo": [mainEntry.path]],
            byAppName: [:]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 1, "重复路径应去重")
        // 保留主路径的 matchReason，不被 spotlight 覆盖
        if case .bundleID = result[0].matchReason { } else {
            XCTFail("dedup 应保留主路径的 matchReason=.bundleID，而非被 spotlight 覆盖")
        }
    }

    // MARK: - 3. Spotlight 返空 fail-soft

    func test_Spotlight返空_candidatesAsync正常返回主路径结果() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        let mainEntry = FSEntry(name: "com.acme.demo", path: "\(cachesPath)/com.acme.demo")
        let fake = FakeFM(
            entriesByRoot: [cachesPath: [mainEntry]],
            snapshots: [mainEntry.path: .init(bytes: 100, fileCount: 1)]
        )
        let spotlight = FakeSpotlight(byBundleID: [:], byAppName: [:]) // 全返空
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 1, "Spotlight 返空不应影响主路径产出")
        XCTAssertEqual(result[0].path, mainEntry.path)
    }

    func test_includeFallbacksFalse_不等待Spotlight兜底() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        let mainEntry = FSEntry(name: "com.acme.demo", path: "\(cachesPath)/com.acme.demo")
        let fake = FakeFM(
            entriesByRoot: [cachesPath: [mainEntry]],
            snapshots: [mainEntry.path: .init(bytes: 100, fileCount: 1)]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: SlowSpotlight(delay: 0.3)
        )

        let start = Date()
        let result = await unins.candidatesAsync(for: demoMeta, includeFallbacks: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].path, mainEntry.path)
        XCTAssertLessThan(elapsed, 0.15, "卸载页首屏不应等待 Spotlight/pkgutil 兜底")
    }

    // MARK: - 4. 防穿透 /System 等无关路径

    func test_Spotlight命中home之外路径_拒绝加入候选() async {
        let home = "/H"
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            // 即便 fileManager 返非空，路径在 /System 也应被拒
            "/System/Library/Foo": .init(bytes: 1, fileCount: 1)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: ["com.acme.demo": ["/System/Library/Foo"]],
            byAppName: [:]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 0, "home/systemLibrary 之外的 spotlight 路径应被拒")
    }

    // MARK: - 5. appName 谓词分支：跳过短 / 噪音词

    func test_appName为常见噪音词_不发起appName谓词查询() async {
        // appName="Demo"（长度 4，但 lowercased 命中 noise list 里的 "demo"）→ 应跳过 appName 谓词
        let home = "/H"
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            "/H/Library/AppNameHit": .init(bytes: 1000, fileCount: 1)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: [:], // bundleID 不返
            byAppName: ["Demo": ["/H/Library/AppNameHit"]]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta) // appName="Demo"
        XCTAssertEqual(result.count, 0, "噪音词 appName 应不触发 spotlight appName 谓词查询")
    }

    func test_appName长度足够且非噪音_发起appName谓词查询并补刀() async {
        let home = "/H"
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            "/H/Documents/AcmeUniqueAppData": .init(bytes: 5000, fileCount: 8)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: [:], // bundleID 不返
            byAppName: ["AcmeUniqueApp": ["/H/Documents/AcmeUniqueAppData"]]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: longNameMeta)
        XCTAssertEqual(result.count, 1, "长且非噪音 appName 应触发 appName 谓词补刀")
        if case .spotlight(let kind) = result[0].matchReason {
            XCTAssertEqual(kind, "appName")
        } else {
            XCTFail("matchReason 应为 .spotlight(\"appName\")")
        }
    }

    func test_主根不存在是完整零结果_权限失败是typedIncomplete() async {
        let missing = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: TypedRootFM(incompleteRoot: nil)
        )
        let missingResult = await missing.candidatesAsync(for: demoMeta, fallbacks: [])
        XCTAssertTrue(missingResult.candidates.isEmpty)
        XCTAssertTrue(missingResult.isDiscoveryComplete)

        let deniedRoot = "/H/Library/Containers"
        let denied = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: TypedRootFM(incompleteRoot: deniedRoot)
        )
        let deniedResult = await denied.candidatesAsync(for: demoMeta, fallbacks: [])
        XCTAssertTrue(deniedResult.candidates.isEmpty)
        XCTAssertFalse(deniedResult.isDiscoveryComplete)
        XCTAssertEqual(deniedResult.incompleteIssues, [UninstallDiscoveryIssue(
            source: .primaryRoot,
            stage: .rootEnumeration,
            path: deniedRoot,
            reason: .permissionDenied
        )])
    }

    func test_Spotlight启动失败与超时不是成功空结果() async {
        for (failure, expectedStage, expectedReason) in [
            (SpotlightProbeFailure.startFailed,
             UninstallDiscoveryIssue.Stage.queryStart,
             UninstallDiscoveryIssue.Reason.queryStartFailed),
            (.timedOut, .queryGathering, .timedOut),
            (.resultCountLimitExceeded(limit: 4_096),
             .queryGathering,
             .resultCountLimitExceeded(limit: 4_096)),
            (.extractionTimeLimitExceeded(limitMilliseconds: 25),
             .queryGathering,
             .extractionTimeLimitExceeded(limitMilliseconds: 25)),
            (.cancelled, .cancellation, .cancelled),
        ] {
            let uninstaller = AppUninstaller(
                homeDirectory: "/H",
                systemLibrary: "/Library",
                fileManager: TypedRootFM(incompleteRoot: nil),
                spotlight: FailedSpotlight(failure: failure)
            )
            let result = await uninstaller.candidatesAsync(
                for: demoMeta,
                fallbacks: [.spotlight]
            )
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertFalse(result.isDiscoveryComplete)
            XCTAssertEqual(result.incompleteIssues, [UninstallDiscoveryIssue(
                source: .spotlightBundleID,
                stage: expectedStage,
                reason: expectedReason
            )])
        }
    }

    func test_Spotlight结果预算与后台路径规范化保持确定合同() {
        let budget = SpotlightResultBudget(
            maximumResultCount: 2,
            maximumMainActorExtractionNanoseconds: 1_000_000
        )

        XCTAssertNil(budget.countFailure(totalResultCount: 2))
        XCTAssertEqual(
            budget.countFailure(totalResultCount: 3),
            .resultCountLimitExceeded(limit: 2)
        )
        XCTAssertNil(budget.timeFailureIfExceeded(startedAt: 10, now: 1_000_009))
        XCTAssertEqual(
            budget.timeFailureIfExceeded(startedAt: 10, now: 1_000_010),
            .extractionTimeLimitExceeded(limitMilliseconds: 1)
        )
        XCTAssertEqual(
            SpotlightPathNormalizer.normalize([
                "/H/B",
                "/H/./A",
                "/H/A",
                "relative/path",
                "/H/invalid\0path",
            ]),
            ["/H/A", "/H/B"]
        )
    }

    @MainActor
    func test_SpotlightMainActor提取逐项检查deadline而非每32项一次() async {
        let budget = SpotlightResultBudget(
            maximumResultCount: 100,
            maximumMainActorExtractionNanoseconds: 10
        )
        var clock: UInt64 = 0
        var accessed: [Int] = []
        let projection = await SpotlightBatchedPathExtractor.extract(
            totalResultCount: 50,
            budget: budget,
            batchSize: 8,
            pathAtIndex: { index in
                accessed.append(index)
                return "/H/\(index)"
            },
            now: {
                defer { clock += 4 }
                return clock
            },
            cancellationRequested: { false },
            yieldBetweenBatches: {}
        )

        XCTAssertEqual(accessed, [0, 1])
        XCTAssertEqual(projection.paths, ["/H/0", "/H/1"])
        XCTAssertEqual(
            projection.failure,
            .extractionTimeLimitExceeded(limitMilliseconds: 0)
        )
    }

    @MainActor
    func test_SpotlightMainActor提取小批量yield后可立即取消() async {
        let budget = SpotlightResultBudget(
            maximumResultCount: 100,
            maximumMainActorExtractionNanoseconds: .max
        )
        var cancelled = false
        var yields = 0
        var accessed: [Int] = []
        let projection = await SpotlightBatchedPathExtractor.extract(
            totalResultCount: 10,
            budget: budget,
            batchSize: 2,
            pathAtIndex: { index in
                accessed.append(index)
                return "/H/\(index)"
            },
            now: { 0 },
            cancellationRequested: { cancelled },
            yieldBetweenBatches: {
                yields += 1
                cancelled = true
                await Task.yield()
            }
        )

        XCTAssertEqual(yields, 1)
        XCTAssertEqual(accessed, [0, 1])
        XCTAssertEqual(projection.failure, .cancelled)
    }

    func test_Spotlight预算截断保留已冻结路径并贯穿typedIncomplete() async {
        let path = "/H/Documents/AcmeData"
        let uninstaller = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: FakeFM(
                entriesByRoot: [:],
                snapshots: [path: .init(bytes: 321, fileCount: 2)]
            ),
            spotlight: FailedSpotlight(
                paths: [path],
                failure: .resultCountLimitExceeded(limit: 4_096)
            )
        )

        let result = await uninstaller.candidatesAsync(
            for: demoMeta,
            fallbacks: [.spotlight]
        )

        XCTAssertEqual(result.candidates.map(\.path), [path])
        XCTAssertFalse(result.isDiscoveryComplete)
        XCTAssertEqual(result.incompleteIssues, [UninstallDiscoveryIssue(
            source: .spotlightBundleID,
            stage: .queryGathering,
            reason: .resultCountLimitExceeded(limit: 4_096)
        )])
    }

    func test_primary父路径与Spotlight子路径按组件边界去重且容量不重叠() async {
        let home = "/H"
        let caches = "\(home)/Library/Caches"
        let parent = "\(caches)/com.acme.demo"
        let child = "\(parent)/profile"
        let fileManager = FakeFM(
            entriesByRoot: [caches: [FSEntry(name: "com.acme.demo", path: parent)]],
            snapshots: [
                parent: .init(bytes: 1_000, fileCount: 10, exists: true, isDirectory: true),
                child: .init(bytes: 20, fileCount: 2, exists: true, isDirectory: true),
            ]
        )
        let spotlight = FakeSpotlight(
            byBundleID: [demoMeta.bundleID: [child]],
            byAppName: [:]
        )
        let uninstaller = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fileManager,
            spotlight: spotlight
        )

        let result = await uninstaller.candidatesAsync(
            for: demoMeta,
            fallbacks: [.spotlight]
        )

        XCTAssertEqual(result.candidates.map(\.path), [child])
        XCTAssertEqual(result.candidates.reduce(Int64(0)) { $0 + $1.bytes }, 20)
    }
}
