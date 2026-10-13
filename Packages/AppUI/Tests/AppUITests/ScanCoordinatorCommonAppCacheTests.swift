import Darwin
import Dispatch
import SafetyKit
import ScanKit
import XCTest
@testable import AppUI

@MainActor
final class ScanCoordinatorCommonAppCacheTests: XCTestCase {

    func test_standardInstalledAppCacheRuleDiscovery_normalResultCarriesRulesWithoutIssues() async {
        let applicationsRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let fileSystem = StandardInstalledAppCacheRuleFileSystem(
            contentsOfDirectory: { _ in ["Notes.txt", "Demo.app"] },
            readMetadata: { _, shouldCancel in
                XCTAssertFalse(shouldCancel())
                return AppMetadata(
                    bundleID: "com.example.Demo",
                    bundleVendor: "com.example",
                    appName: "Demo",
                    executableName: "Demo"
                )
            }
        )

        let result = await ScanCoordinator.discoverStandardInstalledAppCacheRules(
            applicationsRoot: applicationsRoot,
            fileSystem: fileSystem
        )

        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules.first?.name, "Demo")
        XCTAssertEqual(result.rules.first?.bundleIDPrefix, "com.example.Demo")
        XCTAssertEqual(result.rules.first?.source, "standard-macos-cache")
        XCTAssertEqual(result.rules.first?.paths.map(\.path), [
            "~/Library/Caches/com.example.Demo",
            "~/Library/Containers/com.example.Demo/Data/Library/Caches",
            "~/Library/HTTPStorages/com.example.Demo",
        ])
    }

    func test_standardInstalledAppCacheRuleDiscovery_rootFailuresHaveStableEvidence() async {
        let deniedRoot = URL(fileURLWithPath: "/Applications-Denied", isDirectory: true)
        let failedRoot = URL(fileURLWithPath: "/Applications-Failed", isDirectory: true)
        let fileSystem = StandardInstalledAppCacheRuleFileSystem(
            contentsOfDirectory: { url in
                let code = url == deniedRoot ? EACCES : EIO
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            },
            readMetadata: { _, _ in
                XCTFail("root enumeration failure must not attempt app metadata")
                return AppMetadata(
                    bundleID: "unused",
                    bundleVendor: nil,
                    appName: "unused",
                    executableName: nil
                )
            }
        )

        let denied = await ScanCoordinator.discoverStandardInstalledAppCacheRules(
            applicationsRoot: deniedRoot,
            fileSystem: fileSystem
        )
        let failed = await ScanCoordinator.discoverStandardInstalledAppCacheRules(
            applicationsRoot: failedRoot,
            fileSystem: fileSystem
        )

        XCTAssertEqual(denied.issues, [StandardInstalledAppCacheRuleDiscoveryIssue(
            path: deniedRoot.path,
            stage: .rootEnumeration,
            reason: .permissionDenied,
            posixErrorCode: EACCES
        )])
        XCTAssertEqual(failed.issues, [StandardInstalledAppCacheRuleDiscoveryIssue(
            path: failedRoot.path,
            stage: .rootEnumeration,
            reason: .enumerationFailed,
            posixErrorCode: EIO
        )])
        XCTAssertEqual(denied.issues.first?.scanIncompleteIssue, ScanIncompleteIssue(
            path: deniedRoot.path,
            reason: .permissionDenied,
            stage: .enumerate,
            posixErrorCode: EACCES
        ))
    }

    func test_standardInstalledAppCacheRuleDiscovery_metadataFailuresAreTypedAndKeepHealthyRules() async {
        let applicationsRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let fileSystem = StandardInstalledAppCacheRuleFileSystem(
            contentsOfDirectory: { _ in [
                "Permission.app",
                "Oversize.app",
                "Unsafe.app",
                "Changed.app",
                "Malformed.app",
                "Healthy.app",
            ] },
            readMetadata: { appURL, _ in
                switch appURL.deletingPathExtension().lastPathComponent {
                case "Permission":
                    throw BoundedLocalFileReadError.metadataUnavailable(
                        stage: .initialPath,
                        posixErrorCode: EACCES
                    )
                case "Oversize":
                    throw BoundedLocalFileReadError.tooLarge(
                        limit: 16,
                        observedSize: 17
                    )
                case "Unsafe":
                    throw BoundedLocalFileReadError.unsafeType(.symbolicLink)
                case "Changed":
                    throw BoundedLocalFileReadError.changed
                case "Malformed":
                    throw AppMetadataReadError.missingBundleIdentifier
                case "Healthy":
                    return AppMetadata(
                        bundleID: "com.example.Healthy",
                        bundleVendor: "com.example",
                        appName: "Healthy",
                        executableName: nil
                    )
                default:
                    throw AppMetadataReadError.propertyListIsNotDictionary
                }
            }
        )

        let result = await ScanCoordinator.discoverStandardInstalledAppCacheRules(
            applicationsRoot: applicationsRoot,
            fileSystem: fileSystem
        )

        XCTAssertEqual(result.rules.map(\.bundleIDPrefix), ["com.example.Healthy"])
        XCTAssertEqual(result.issues.count, 5)
        func issue(for appName: String) -> StandardInstalledAppCacheRuleDiscoveryIssue? {
            result.issues.first { $0.path.contains("/\(appName).app/") }
        }
        XCTAssertEqual(issue(for: "Permission")?.stage, .metadataRead)
        XCTAssertEqual(issue(for: "Permission")?.reason, .permissionDenied)
        XCTAssertEqual(issue(for: "Permission")?.posixErrorCode, EACCES)
        XCTAssertEqual(issue(for: "Oversize")?.reason, .tooLarge)
        XCTAssertEqual(issue(for: "Unsafe")?.reason, .unsafeType)
        XCTAssertEqual(issue(for: "Changed")?.reason, .changed)
        XCTAssertEqual(issue(for: "Malformed")?.stage, .metadataDecode)
        XCTAssertEqual(issue(for: "Malformed")?.reason, .malformedMetadata)
        XCTAssertEqual(issue(for: "Oversize")?.scanIncompleteIssue.reason, .metadataUnavailable)
        XCTAssertEqual(issue(for: "Oversize")?.scanIncompleteIssue.stage, .metadata)
        XCTAssertEqual(
            issue(for: "Permission")?.logFields,
            "stage=metadata-read reason=permission-denied "
                + "domain=NSPOSIXErrorDomain code=13 "
                + "path=/Applications/Permission.app/Contents/Info.plist"
        )
    }

    func test_commonAppCacheProtectedAccessPolicy_preservesVenturaAndRequiresFDAOnSonoma() {
        XCTAssertTrue(ScanCoordinator.commonAppCacheAllowsProtectedAppDataAccess(
            fdaStatus: .denied,
            scanHome: "/Users/fixture",
            currentUserHome: "/Users/fixture",
            macOSMajorVersion: 13
        ))
        XCTAssertFalse(ScanCoordinator.commonAppCacheAllowsProtectedAppDataAccess(
            fdaStatus: .unknown,
            scanHome: "/Users/fixture",
            currentUserHome: "/Users/fixture",
            macOSMajorVersion: 14
        ))
        XCTAssertFalse(ScanCoordinator.commonAppCacheAllowsProtectedAppDataAccess(
            fdaStatus: .denied,
            scanHome: "/Users/fixture",
            currentUserHome: "/Users/fixture",
            macOSMajorVersion: 14
        ))
        XCTAssertTrue(ScanCoordinator.commonAppCacheAllowsProtectedAppDataAccess(
            fdaStatus: .granted,
            scanHome: "/Users/fixture",
            currentUserHome: "/Users/fixture",
            macOSMajorVersion: 14
        ))
    }

    func test_commonAppCacheProtectedAccessPolicy_doesNotMisclassifyCustomHomeAsTCC() {
        XCTAssertTrue(ScanCoordinator.commonAppCacheAllowsProtectedAppDataAccess(
            fdaStatus: .denied,
            scanHome: "/tmp/custom-home",
            currentUserHome: "/Users/fixture",
            macOSMajorVersion: 14
        ))
    }

    /// v2026.07.17 C4 regression: ScanKit proves that candidate resolution stops before protected
    /// access; this integration test injects that typed result and locks the AppUI projection.
    /// A temp HOME must not impersonate the OS-protected current HOME merely to exercise TCC.
    func test_scanCommonAppCaches_projectsProtectedAppDataEvidenceAsTCCPartial() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let boundary = home.appendingPathComponent(
            "Library/Containers",
            isDirectory: true
        ).standardizedFileURL.path
        let coordinator = ScanCoordinator(home: home.path)
        coordinator.commonAppCacheDetector = { _, _, _ in
            CommonAppCacheScanner.ScanResult(
                hits: [],
                incompletePaths: [
                    .init(path: boundary, reason: .protectedAppDataSkipped)
                ]
            )
        }

        isolateLiveStandardAppDiscovery(coordinator)
        coordinator.scanCommonAppCaches()
        await waitScanFinished(coordinator)

        XCTAssertTrue(coordinator.snapshot.rows.isEmpty)
        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.snapshot.isComplete)
        XCTAssertEqual(coordinator.tccProtectedSkippedPaths, [boundary])
        XCTAssertEqual(coordinator.commonAppCacheProgress?.phase, .terminal)
        XCTAssertEqual(coordinator.commonAppCacheProgress?.terminalOutcome, .partial)
    }

    func test_scanCommonAppCaches_standardRootFailureMakesTerminalPartialAndProjectsEvidence() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let applicationsRoot = "/Applications"
        let discovery = StandardInstalledAppCacheRuleDiscoveryResult(
            rules: [],
            issues: [StandardInstalledAppCacheRuleDiscoveryIssue(
                path: applicationsRoot,
                stage: .rootEnumeration,
                reason: .permissionDenied,
                posixErrorCode: EACCES
            )]
        )
        let coordinator = ScanCoordinator(home: home.path)
        coordinator.standardInstalledAppCacheRuleDiscovery = { discovery }
        coordinator.commonAppCacheDetector = { _, _, _ in
            CommonAppCacheScanner.ScanResult(hits: [], incompletePaths: [])
        }

        isolateLiveStandardAppDiscovery(coordinator)
        coordinator.scanCommonAppCaches()
        await waitScanFinished(coordinator)

        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.snapshot.isComplete)
        XCTAssertEqual(coordinator.commonAppCacheProgress?.terminalOutcome, .partial)
        XCTAssertEqual(coordinator.incompleteScanIssues, [ScanIncompleteIssue(
            path: applicationsRoot,
            reason: .permissionDenied,
            stage: .enumerate,
            posixErrorCode: EACCES
        )])
        XCTAssertEqual(coordinator._testAccessState(for: applicationsRoot), .permissionDenied)
        XCTAssertEqual(
            coordinator.incompleteIssues(overlappingAny: [applicationsRoot]),
            coordinator.incompleteScanIssues
        )
    }

    func test_scanCommonAppCaches_metadataIssueMakesRoundPartialWithoutBlockingUnrelatedCacheRow() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(
            "Library/Caches/com.example.Healthy",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let metadataPath = "/Applications/Broken.app/Contents/Info.plist"
        let discovery = StandardInstalledAppCacheRuleDiscoveryResult(
            rules: [],
            issues: [StandardInstalledAppCacheRuleDiscoveryIssue(
                path: metadataPath,
                stage: .metadataRead,
                reason: .tooLarge,
                posixErrorCode: nil
            )]
        )
        let coordinator = ScanCoordinator(vendors: [VendorRule(
            name: "Healthy Cache",
            category: "common_app_cache",
            paths: [PathRule(
                path: "~/Library/Caches/com.example.Healthy",
                verdict: .safe
            )]
        )], home: home.path)
        coordinator.standardInstalledAppCacheRuleDiscovery = { discovery }
        coordinator.commonAppCacheDetector = { _, _, _ in
            CommonAppCacheScanner.ScanResult(
                hits: [CommonAppCacheScanner.Hit(
                    ruleName: "Healthy Cache",
                    bundleIDPrefix: "com.example.Healthy",
                    source: "fixture",
                    url: cache,
                    isDirectory: true,
                    verdict: .safe,
                    reason: "fixture",
                    sizeBytes: 4_096,
                    logicalSizeBytes: 128,
                    entryCount: 1
                )],
                incompletePaths: []
            )
        }

        isolateLiveStandardAppDiscovery(coordinator)
        coordinator.scanCommonAppCaches()
        await waitScanFinished(coordinator)

        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.snapshot.isComplete)
        XCTAssertEqual(coordinator.commonAppCacheProgress?.terminalOutcome, .partial)
        XCTAssertEqual(coordinator.snapshot.rows.map(\.verdict), [.safe],
                       "metadata discovery gap is not an overlap with the measured cache row")
        XCTAssertEqual(coordinator.incompleteScanIssues, [ScanIncompleteIssue(
            path: metadataPath,
            reason: .metadataUnavailable,
            stage: .metadata
        )])
        XCTAssertEqual(coordinator._testAccessState(for: metadataPath), .incomplete)
        XCTAssertTrue(coordinator.incompleteIssues(overlappingAny: [cache.path]).isEmpty,
                      "request-scoped deletion evidence must use path overlap, not global partial")
        XCTAssertEqual(
            coordinator.incompleteIssues(overlappingAny: [metadataPath]),
            coordinator.incompleteScanIssues
        )
    }

    func test_scanCommonAppCaches_cancelDuringStandardDiscoveryDoesNotRunDetectorOrPublishTerminal() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let discoveryStarted = DispatchSemaphore(value: 0)
        let detectorStarted = DispatchSemaphore(value: 0)
        let coordinator = ScanCoordinator(home: home.path)
        coordinator.standardInstalledAppCacheRuleDiscovery = {
            discoveryStarted.signal()
            while !Task.isCancelled {
                await Task.yield()
            }
            return .cancelled
        }
        coordinator.commonAppCacheDetector = { _, _, _ in
            detectorStarted.signal()
            return CommonAppCacheScanner.ScanResult(hits: [], incompletePaths: [])
        }

        isolateLiveStandardAppDiscovery(coordinator)
        coordinator.scanCommonAppCaches()
        let didStartDiscovery = await waitForSignal(discoveryStarted, timeout: 2)
        XCTAssertTrue(didStartDiscovery)
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(50))

        let didStartDetector = await waitForSignal(detectorStarted, timeout: 0.05)
        XCTAssertFalse(didStartDetector)
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertFalse(coordinator.snapshot.isFinished)
        XCTAssertTrue(coordinator.incompleteScanIssues.isEmpty)
        XCTAssertNil(coordinator.commonAppCacheProgress)
    }

    func test_scanCommonAppCaches_publishesOnlyExistingNonEmptyRuleHits() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let wechat = home.appendingPathComponent("Library/Caches/com.tencent.xinWeChat",
                                                 isDirectory: true)
        let empty = home.appendingPathComponent("Library/Caches/com.empty.App",
                                                isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Application Support/Zoom/data/VirtualBkgnd_Custom",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: wechat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        let wechatFile = wechat.appendingPathComponent("cache.bin")
        let confirmFile = confirm.appendingPathComponent("background.bin")
        try Data(repeating: 0xAB, count: 128).write(to: wechatFile)
        try Data(repeating: 0xCD, count: 256).write(to: confirmFile)
        let wechatAllocated = try allocatedBytes(of: wechatFile)
        let confirmAllocated = try allocatedBytes(of: confirmFile)

        let vendors = [
            VendorRule(
                name: "WeChat Cache",
                bundleIDPrefix: "com.tencent.xinWeChat",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .safe,
                             reason: "cache")
                ]
            ),
            VendorRule(
                name: "Empty Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.empty.App",
                             verdict: .safe,
                             reason: "empty")
                ]
            ),
            VendorRule(
                name: "Zoom Virtual Backgrounds",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Application Support/Zoom/data/VirtualBkgnd_Custom",
                             verdict: .confirm,
                             reason: "user-selected backgrounds")
                ]
            ),
            VendorRule(
                name: "Blocked Neighbor",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/com.tencent.xinWeChat",
                             verdict: .forbid,
                             reason: "blocked")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.categoryID, ScanCoordinator.commonAppCacheCategoryID)
        XCTAssertEqual(coord.currentRootPath, ScanCoordinator.commonAppCacheSentinelPath)
        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertFalse(coord.isScanning)
        XCTAssertNil(coord.activeCategoryID)
        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Zoom Virtual Backgrounds", "WeChat Cache"])
        let weChatRow = try XCTUnwrap(coord.snapshot.rows.first { $0.title == "WeChat Cache" })
        XCTAssertEqual(weChatRow.displayTitle(locale: Locale(identifier: "en")), "WeChat Cache")
        XCTAssertEqual(weChatRow.displayTitle(locale: Locale(identifier: "zh-Hans")), "WeChat Cache")
        XCTAssertEqual(weChatRow.displayVendorNote(locale: Locale(identifier: "en")), "cache")
        XCTAssertEqual(weChatRow.displayVendorNote(locale: Locale(identifier: "zh-Hans")), "cache")
        XCTAssertEqual(coord.snapshot.totalBytes, wechatAllocated + confirmAllocated)
        XCTAssertEqual(coord.snapshot.scannedFileCount, 2)

        let verdicts = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.verdict) })
        XCTAssertEqual(verdicts["WeChat Cache"], .safe)
        XCTAssertEqual(verdicts["Zoom Virtual Backgrounds"], .confirm)
        let prefixes = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.runningBundleIDPrefix) })
        XCTAssertEqual(prefixes["WeChat Cache"]!, "com.tencent.xinWeChat")
        XCTAssertEqual(coord.snapshot.safeBytes, wechatAllocated)
        XCTAssertEqual(coord.snapshot.confirmBytes, confirmAllocated)
        let logicalByTitle = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0.logicalBytes) })
        XCTAssertEqual(logicalByTitle["WeChat Cache"], 128)
        XCTAssertEqual(logicalByTitle["Zoom Virtual Backgrounds"], 256)
    }

    func test_scanCommonAppCaches_treeRootShowsSnapshotRows() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = home.appendingPathComponent("Library/Caches/com.demo.App",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cacheFile = cache.appendingPathComponent("cache.bin")
        try Data(repeating: 0xAB, count: 64).write(to: cacheFile)
        let allocated = try allocatedBytes(of: cacheFile)

        let vendors = [
            VendorRule(
                name: "Demo Cache",
                bundleIDPrefix: "com.demo.App",
                category: "common_app_cache",
                source: "fixture",
                paths: [
                    PathRule(path: "~/Library/Caches/com.demo.App",
                             verdict: .safe,
                             reason: "cache")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        let children = coord.directChildren(of: ScanCoordinator.commonAppCacheSentinelPath,
                                            sortedBy: .sizeDesc)
        XCTAssertEqual(children.map(\.title), ["Demo Cache"])
        XCTAssertEqual(children.first?.bytes, allocated)
        XCTAssertEqual(children.first?.logicalBytes, 64)
        XCTAssertEqual(children.first?.hasChildren, true)
    }

    func test_scanCommonAppCaches_canExcludeConfirmRules() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let safe = home.appendingPathComponent("Library/Caches/safe", isDirectory: true)
        let confirm = home.appendingPathComponent("Library/Caches/confirm", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: confirm, withIntermediateDirectories: true)
        let safeFile = safe.appendingPathComponent("a.bin")
        try Data(repeating: 0xAA, count: 11).write(to: safeFile)
        try Data(repeating: 0xBB, count: 22).write(to: confirm.appendingPathComponent("b.bin"))
        let safeAllocated = try allocatedBytes(of: safeFile)

        let vendors = [
            VendorRule(
                name: "Safe Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/safe", verdict: .safe, reason: "safe")
                ]
            ),
            VendorRule(
                name: "Confirm Cache",
                category: "common_app_cache",
                paths: [
                    PathRule(path: "~/Library/Caches/confirm", verdict: .confirm, reason: "confirm")
                ]
            )
        ]

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches(includeConfirm: false)
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Safe Cache"])
        XCTAssertEqual(coord.snapshot.totalBytes, safeAllocated)
        XCTAssertEqual(coord.snapshot.rows.first?.logicalBytes, 11)
        XCTAssertEqual(coord.snapshot.confirmBytes, 0)
    }

    func test_scanCommonAppCaches_incompleteRootFlowsIntoParentDeletionHardDeny() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let cachesRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let cache = cachesRoot.appendingPathComponent("com.example.Partial", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 19).write(to: cache.appendingPathComponent("a.bin"))
        try Data(repeating: 0xBB, count: 23).write(to: cache.appendingPathComponent("b.bin"))

        let vendors = [VendorRule(
            name: "Partial Cache",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Partial", verdict: .safe)]
        )]
        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches(
            scannerOptions: CommonAppCacheScanner.Options(maxEntriesPerPath: 1)
        )
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.map(\.url.standardizedFileURL.path),
                       [cache.standardizedFileURL.path],
                       "partial bytes 可以展示，但必须同时携带删除保护上下文")
        XCTAssertEqual(coord.permissionDeniedPaths, [],
                       "entry limit 是通用扫描不完整，不能被误报成 FDA 权限拒绝")
        XCTAssertEqual(coord.incompleteScanPaths, [cache.standardizedFileURL.path])
        XCTAssertTrue(coord.snapshot.isFinished,
                      "部分结果仍是终态，不能让 UI/Smart Care 永久等待")
        XCTAssertFalse(coord.snapshot.isComplete,
                       "带不完整证据的终态不能发布为成功完成")
        let rowsBeforeSort = coord.snapshot.rows
        coord.mainListSortKey = .nameAsc
        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertFalse(coord.snapshot.isComplete,
                       "排序重发布只能改变展示顺序，不能把 partial 终态提升为成功")
        XCTAssertEqual(Set(coord.snapshot.rows), Set(rowsBeforeSort),
                       "专用扫描结果没有通用 buckets，排序不能把已发布 rows 清空")
        XCTAssertEqual(coord.snapshot.rows.first?.verdict, .forbid,
                       "不完整统计只能展示为不可选项，不能先作为 safe 再等删除时失败")
        XCTAssertEqual(coord.snapshot.rows.first?.rejection, .accessDenied)

        let partition = TrashPipeline.partitionByForbid(
            paths: [cachesRoot.path],
            safety: SafetyEngine(),
            accessDeniedPaths: Set(coord.permissionDeniedPaths)
                .union(coord.incompleteScanPaths),
            home: home.path
        )
        XCTAssertTrue(partition.allowed.isEmpty)
        XCTAssertEqual(partition.rejected.first?.reason, .accessDenied,
                       "不完整子树必须阻止 Smart Care/统一删除入口移除其父根")
    }

    func test_scanCommonAppCaches_取消旧轮后新轮等待Producer退出且旧结果不能覆盖() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.Generation",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 73)
            .write(to: cache.appendingPathComponent("current.bin"))

        let vendors = [VendorRule(
            name: "Current Generation",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.Generation", verdict: .safe)]
        )]
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let newStarted = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        var releasedOld = false
        var releasedNew = false
        defer {
            if !releasedOld { releaseOld.signal() }
            if !releasedNew { releaseNew.signal() }
        }

        let coord = ScanCoordinator(vendors: vendors, home: home.path)
        coord.commonAppCacheDetector = { _, _, options in
            if options.timeoutSeconds == 101 {
                oldStarted.signal()
                releaseOld.wait()
                // 故意模拟不协作 Task cancellation 的同步旧 detector：空结果若能提交，
                // 会把正在运行的新一轮覆盖成“扫描完成但无结果”。
                return CommonAppCacheScanner.ScanResult(hits: [], incompletePaths: [])
            }
            newStarted.signal()
            releaseNew.wait()
            return CommonAppCacheScanner.ScanResult(
                hits: [CommonAppCacheScanner.Hit(
                    ruleName: "Current Generation",
                    bundleIDPrefix: nil,
                    source: "generation-test",
                    url: cache,
                    isDirectory: true,
                    verdict: .safe,
                    reason: "current",
                    sizeBytes: 73,
                    logicalSizeBytes: 2 * 1_024 * 1_024 * 1_024,
                    entryCount: 1
                )],
                incompletePaths: []
            )
        }

        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches(
            scannerOptions: CommonAppCacheScanner.Options(timeoutSeconds: 101)
        )
        let didStartOld = await waitForSignal(oldStarted, timeout: 2)
        XCTAssertTrue(didStartOld)

        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches(
            scannerOptions: CommonAppCacheScanner.Options(timeoutSeconds: 202)
        )
        // v2026.07.20：同类别续扫必须先等待不协作取消的旧 producer 真正退出；等待期
        // 是 typed `.settling`，不是伪造中的扫描。旧稳定 frame 可继续显示，但不再拥有
        // active category 或删除授权；只有 admission 完成后新 intent 才进入 `.scanning`。
        let didStartNewTooSoon = await waitForSignal(newStarted, timeout: 0.15)
        XCTAssertFalse(didStartNewTooSoon, "旧 producer 未退出前不得启动新一轮重扫描")
        XCTAssertFalse(coord.isScanning)
        XCTAssertFalse(coord.snapshot.isFinished)
        XCTAssertNil(coord.activeCategoryID)
        guard case .settling(let settlement) = coord.scanPhase else {
            return XCTFail("等待旧 producer 退出时必须暴露 typed settlement")
        }
        XCTAssertEqual(settlement.intent, .commonAppCaches)

        releaseOld.signal()
        releasedOld = true
        let didStartNew = await waitForSignal(newStarted, timeout: 2)
        XCTAssertTrue(didStartNew, "旧 producer 退出后，新 generation 必须继续启动")
        XCTAssertTrue(coord.isScanning,
                      "旧轮返回时，新 generation 仍必须保有扫描状态与最终提交权")
        XCTAssertFalse(coord.snapshot.isFinished)
        XCTAssertEqual(coord.activeCategoryID, ScanCoordinator.commonAppCacheCategoryID)

        releaseNew.signal()
        releasedNew = true
        await waitScanFinished(coord)

        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Current Generation"])
        XCTAssertEqual(coord.snapshot.totalBytes, 73)
        XCTAssertEqual(coord.snapshot.rows.first?.logicalBytes, 2 * 1_024 * 1_024 * 1_024)
    }

    func test_scanCommonAppCaches_parentAndChildRowsAreInclusiveButSnapshotTotalsAreUnique() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parent = home.appendingPathComponent("Library/Caches/Browser", isDirectory: true)
        let child = parent.appendingPathComponent("GPUCache", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let parentFile = parent.appendingPathComponent("parent.bin")
        let childFile = child.appendingPathComponent("child.bin")
        try Data(repeating: 0xA1, count: 5_000).write(to: parentFile)
        try Data(repeating: 0xB2, count: 7_000).write(to: childFile)
        let parentAllocated = try allocatedBytes(of: parentFile)
        let childAllocated = try allocatedBytes(of: childFile)

        let coord = ScanCoordinator(vendors: [
            VendorRule(
                name: "Browser Review Root",
                category: "common_app_cache",
                paths: [PathRule(
                    path: "~/Library/Caches/Browser",
                    verdict: .confirm,
                    reason: "review parent"
                )]
            ),
            VendorRule(
                name: "Browser Safe GPU Cache",
                category: "common_app_cache",
                paths: [PathRule(
                    path: "~/Library/Caches/Browser/GPUCache",
                    verdict: .safe,
                    reason: "safe child"
                )]
            ),
        ], home: home.path)
        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertTrue(coord.snapshot.isComplete)
        let byTitle = Dictionary(uniqueKeysWithValues: coord.snapshot.rows.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Browser Review Root"]?.bytes,
                       parentAllocated + childAllocated,
                       "父风险行仍需展示完整 subtree 容量")
        XCTAssertEqual(byTitle["Browser Safe GPU Cache"]?.bytes,
                       childAllocated,
                       "子风险行仍需展示自己的完整 subtree 容量")
        XCTAssertEqual(byTitle["Browser Review Root"]?.verdict, .confirm)
        XCTAssertEqual(byTitle["Browser Safe GPU Cache"]?.verdict, .safe)
        XCTAssertEqual(coord.snapshot.totalBytes, parentAllocated + childAllocated,
                       "snapshot total 必须来自候选路径并集，不能把 inclusive rows 相加")
        XCTAssertEqual(coord.snapshot.scannedFileCount, 3,
                       "父根下的子目录和两个文件在路径并集里各计一次")
        XCTAssertGreaterThan(coord.snapshot.rows.reduce(0) { $0 &+ $1.bytes },
                             coord.snapshot.totalBytes,
                             "本用例必须真实覆盖重叠行，而不是偶然退化成互斥行")
    }

    func test_scanCommonAppCaches_whitelistIsAppliedBeforeUniqueTotalsAreMeasured() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let hidden = home.appendingPathComponent("Library/Caches/Hidden", isDirectory: true)
        let visible = home.appendingPathComponent("Library/Caches/Visible", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        let hiddenFile = hidden.appendingPathComponent("hidden.bin")
        let visibleFile = visible.appendingPathComponent("visible.bin")
        try Data(repeating: 0xAA, count: 9_000).write(to: hiddenFile)
        try Data(repeating: 0xBB, count: 5_000).write(to: visibleFile)
        let visibleAllocated = try allocatedBytes(of: visibleFile)

        let whitelist = WhitelistStore(storageURL: nil)
        await whitelist.add(path: hidden.path, reason: "fixture")
        let coord = ScanCoordinator(vendors: [
            VendorRule(
                name: "Hidden Cache",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Hidden", verdict: .safe)]
            ),
            VendorRule(
                name: "Visible Cache",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Visible", verdict: .safe)]
            ),
        ], home: home.path, whitelistStore: whitelist)
        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        XCTAssertEqual(coord.snapshot.rows.map(\.title), ["Visible Cache"])
        XCTAssertEqual(coord.snapshot.totalBytes, visibleAllocated,
                       "白名单必须在 ScanKit 形成并集前冻结，不能只隐藏 row 却保留其 total")
        XCTAssertEqual(coord.snapshot.scannedFileCount, 1)
    }

    func test_scanCommonAppCaches_isolatedWorkerUnavailableFailsClosedWithoutFallback() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let coord = ScanCoordinator(
            vendors: [],
            home: home.path,
            commonAppCacheExecution: .isolated(executableURL: nil)
        )

        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)

        XCTAssertFalse(coord.isScanning)
        XCTAssertTrue(coord.snapshot.isFinished)
        XCTAssertFalse(coord.snapshot.isComplete)
        XCTAssertTrue(coord.snapshot.rows.isEmpty)
        XCTAssertEqual(coord.incompleteScanIssues.count, 1)
        XCTAssertEqual(
            coord.incompleteScanIssues.first?.path,
            home.appendingPathComponent("Library", isDirectory: true).path
        )
        XCTAssertEqual(coord.incompleteScanIssues.first?.stage, .open)
    }

    func test_scanCommonAppCaches_inProcessPublishesTypedTerminalProgress() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/Progress", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0xCC, count: 64).write(
            to: cache.appendingPathComponent("cache.bin")
        )
        let coord = ScanCoordinator(vendors: [
            VendorRule(
                name: "Progress Cache",
                category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/Progress", verdict: .safe)]
            )
        ], home: home.path)

        isolateLiveStandardAppDiscovery(coord)
        coord.scanCommonAppCaches()
        await waitScanFinished(coord)
        await Task.yield()

        let progress = try XCTUnwrap(coord.commonAppCacheProgress)
        XCTAssertTrue(progress.isTerminal)
        XCTAssertEqual(progress.terminalOutcome, .complete)
        XCTAssertEqual(progress.completedGroups, 1)
        XCTAssertEqual(progress.totalGroups, 1)
        XCTAssertTrue(progress.pendingPaths.isEmpty)
        XCTAssertEqual(progress.checkpoint?.completedGroupCount, 1)
    }

    /// v2026.07.18：这些 fixture 验证 Common App Cache 状态机，不应被测试宿主机
    /// `/Applications` 中碰巧存在的损坏 App 元数据改变终态；显式 discovery 用例会先注入自己的证据。
    private func isolateLiveStandardAppDiscovery(_ coordinator: ScanCoordinator) {
        guard coordinator.standardInstalledAppCacheRuleDiscovery == nil else { return }
        coordinator.standardInstalledAppCacheRuleDiscovery = {
            StandardInstalledAppCacheRuleDiscoveryResult(rules: [])
        }
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorCommonAppCache-\(UUID().uuidString)",
                                    isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUndoRediscoveryRestoresCacheCandidatesWithOriginalScanOptions() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.Cache")
        let added = home.appendingPathComponent("Library/Caches/com.example.Added")
        let excluded = home.appendingPathComponent("Library/Caches/com.example.Excluded")
        let confirm = home.appendingPathComponent("Library/Application Support/Example/Backgrounds")
        for url in [cache, excluded, confirm] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 8192).write(to: url.appendingPathComponent("payload.bin"))
        }
        let vendors = [
            VendorRule(name: "Cache", bundleIDPrefix: "com.example.Cache", category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/com.example.Cache", verdict: .safe)]),
            VendorRule(name: "Added", category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/com.example.Added", verdict: .safe)]),
            VendorRule(name: "Excluded", category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Caches/com.example.Excluded", verdict: .safe)]),
            VendorRule(name: "Confirm", category: "common_app_cache",
                paths: [PathRule(path: "~/Library/Application Support/Example/Backgrounds", verdict: .confirm)])
        ]
        let coordinator = ScanCoordinator(vendors: vendors, home: home.path)
        isolateLiveStandardAppDiscovery(coordinator)
        coordinator.scanCommonAppCaches(includeConfirm: false, scannerOptions: .init(
            excludedCandidatePathPrefixes: [excluded.path]))
        await waitScanFinished(coordinator)
        XCTAssertEqual(coordinator.snapshot.rows.map(\.id), [cache.path])
        let session = coordinator.currentScanSessionID
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [cache.path])
        await coordinator.pruneDeleted(paths: [cache.path])
        XCTAssertTrue(coordinator.snapshot.rows.isEmpty)

        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data(repeating: 0x62, count: 16384).write(to: added.appendingPathComponent("payload.bin"))
        await coordinator.reconcileRestoredPaths([cache.path])
        await waitScanFinished(coordinator)
        XCTAssertNotEqual(coordinator.currentScanSessionID, session)
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [cache.path, added.path])
        XCTAssertFalse(coordinator.snapshot.rows.contains { $0.id == confirm.path }, "Undo must keep includeConfirm=false")
        XCTAssertFalse(coordinator.snapshot.rows.contains { $0.id == excluded.path }, "Undo must preserve scanner exclusions")
        XCTAssertFalse(coordinator._isDeletedTombstonedForTesting(cache.path))
        XCTAssertFalse(coordinator.treeBrowser.deletionPresentation.matcher.contains(cache.path))
        let restored = try XCTUnwrap(coordinator.snapshot.rows.first { $0.id == cache.path })
        XCTAssertEqual(restored.title, "Cache")
        XCTAssertEqual(restored.runningBundleIDPrefix, "com.example.Cache")
        XCTAssertEqual(coordinator.snapshot.totalBytes, coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        XCTAssertEqual(Set(coordinator.directChildren(of: ScanCoordinator.commonAppCacheSentinelPath, sortedBy: .sizeDesc).map(\.path)), [cache.path, added.path])

        await coordinator.rescanSubtree(at: cache.path)
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), [cache.path, added.path],
                       "An explicit candidate refresh must keep semantic roots, not replace them with child files")
        XCTAssertEqual(Set(coordinator.directChildren(of: ScanCoordinator.commonAppCacheSentinelPath, sortedBy: .sizeDesc).map(\.path)),
                       [cache.path, added.path], "Candidate refresh must retain the snapshot Tree projection")

        // Undo reports only the actual destination when the old name is occupied. The sibling
        // must invalidate discovery, but may not bypass the exact cache rule into a new row.
        let renamed = cache.deletingLastPathComponent().appendingPathComponent("com.example.Cache (restored)")
        try FileManager.default.moveItem(at: cache, to: renamed)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x64, count: 32768).write(to: cache.appendingPathComponent("new-occupant.bin"))
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: [cache.path])
        await coordinator.pruneDeleted(paths: [cache.path])
        let previousSession = coordinator.currentScanSessionID
        await coordinator.reconcileRestoredPaths([renamed.path])
        await waitScanFinished(coordinator)
        XCTAssertNotEqual(coordinator.currentScanSessionID, previousSession)
        let occupied = try XCTUnwrap(coordinator.snapshot.rows.first { $0.id == cache.path })
        XCTAssertEqual(occupied.bytes, try allocatedBytes(of: cache.appendingPathComponent("new-occupant.bin")))
        XCTAssertFalse(coordinator.snapshot.rows.contains { $0.id == renamed.path }, "Restore is not a cache-rule grant")
    }

    /// v2026.10.08: a second restore must survive a still-running recovery producer; after
    /// cancellation the same notification must not resurrect the discarded scan owner.
    func testConsecutiveUndoRediscoveryWaitsForProducerAndDoesNotRestartACancelledScan() async throws {
        let home = try makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let caches = ["First", "Second"].map { home.appendingPathComponent("Library/Caches/com.example.\($0)") }
        for cache in caches {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(repeating: 0x63, count: 8192).write(to: cache.appendingPathComponent("payload.bin"))
        }
        let vendors = [VendorRule(name: "Recovery", category: "common_app_cache", paths: [
            PathRule(path: "~/Library/Caches/com.example.First", verdict: .safe),
            PathRule(path: "~/Library/Caches/com.example.Second", verdict: .safe)
        ])]
        let coordinator = ScanCoordinator(vendors: vendors, home: home.path)
        isolateLiveStandardAppDiscovery(coordinator)
        coordinator.scanCommonAppCaches(includeConfirm: false, scannerOptions: .init(timeoutSeconds: 19))
        await waitScanFinished(coordinator)
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), Set(caches.map(\.path)))
        await coordinator.acknowledgeSuccessfulDeletionForPresentation(paths: caches.map(\.path))
        await coordinator.pruneDeleted(paths: caches.map(\.path))

        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let latestStarted = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        coordinator.commonAppCacheDetector = { _, _, options in
            XCTAssertEqual(options.timeoutSeconds, 19)
            XCTAssertEqual(options.includedVerdicts, [.safe])
            firstStarted.signal()
            releaseFirst.wait() // Deliberately non-cooperative filesystem producer.
            return .init(hits: [], incompletePaths: [])
        }
        await coordinator.reconcileRestoredPaths([caches[0].path])
        let didStartFirst = await waitForSignal(firstStarted, timeout: 2)
        XCTAssertTrue(didStartFirst)
        let firstSession = coordinator.currentScanSessionID

        coordinator.commonAppCacheDetector = { rules, home, options in
            XCTAssertEqual(options.timeoutSeconds, 19)
            XCTAssertEqual(options.includedVerdicts, [.safe])
            latestStarted.signal()
            return CommonAppCacheScanner.detect(vendors: rules, home: home, options: options)
        }
        NotificationCenter.default.post(name: .amuxUndoDidRestore, object: nil,
                                        userInfo: ["paths": [caches[1].path]])
        await coordinator._waitForUndoReconciliationForTesting()
        guard case .settling = coordinator.scanPhase else {
            return XCTFail("The second restore must retain its scope and wait for true producer termination")
        }
        let didOverlap = await waitForSignal(latestStarted, timeout: 0.05)
        XCTAssertFalse(didOverlap)
        releaseFirst.signal()
        await waitScanFinished(coordinator)
        let didStartLatest = await waitForSignal(latestStarted, timeout: 1)
        XCTAssertTrue(didStartLatest)
        XCTAssertNotEqual(coordinator.currentScanSessionID, firstSession)
        XCTAssertEqual(Set(coordinator.snapshot.rows.map(\.id)), Set(caches.map(\.path)))
        XCTAssertEqual(coordinator.snapshot.scannedFileCount, 2)
        XCTAssertEqual(coordinator.snapshot.totalBytes, coordinator.snapshot.rows.reduce(0) { $0 + $1.bytes })

        coordinator.cancel()
        let cancelledSession = coordinator.currentScanSessionID
        NotificationCenter.default.post(name: .amuxUndoDidRestore, object: nil,
                                        userInfo: ["paths": [caches[0].path]])
        await coordinator._waitForUndoReconciliationForTesting()
        XCTAssertEqual(coordinator.currentScanSessionID, cancelledSession)
        XCTAssertEqual(coordinator.scanPhase, .idle)
        XCTAssertTrue(coordinator.snapshot.rows.isEmpty)
        coordinator.cancel()
    }

    private func allocatedBytes(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private func waitScanFinished(_ coord: ScanCoordinator,
                                  timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        // A queued replacement exposes isScanning=false while its old producer settles.
        // Wait for the typed phase as well, never accept the predecessor's finished frame.
        while (coord.scanPhase != .idle || !coord.snapshot.isFinished) && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                XCTFail("Scan wait was cancelled: \(error)")
                return
            }
        }
        XCTAssertEqual(coord.scanPhase, .idle, "扫描应在测试超时前结算")
        XCTAssertFalse(coord.isScanning)
        XCTAssertTrue(coord.snapshot.isFinished, "扫描应发布 finished snapshot")
    }

    /// 让出 MainActor 等待后台 producer 信号，避免测试自己的 semaphore wait
    /// 阻断扫描状态机完成取消收敛和下一代启动。
    private func waitForSignal(_ semaphore: DispatchSemaphore,
                               timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if consumeSignalIfAvailable(semaphore) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return consumeSignalIfAvailable(semaphore)
    }

    private nonisolated func consumeSignalIfAvailable(
        _ semaphore: DispatchSemaphore
    ) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }
}
