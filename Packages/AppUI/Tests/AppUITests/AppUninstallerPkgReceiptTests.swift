import XCTest
import Darwin
@testable import AppUI
@testable import ScanKit
import SafetyKit

/// v2026.07.18 regression contract for product-owned pkg receipt discovery.
///
/// A reverse-DNS namespace narrows the query but never proves ownership. Every accepted receipt
/// must anchor the selected `.app`, own no second external `.app`, and project only a path component
/// carrying product-specific evidence. All fixtures are synthetic and no test invokes pkgutil.
final class AppUninstallerPkgReceiptTests: XCTestCase {
    private struct FakeFM: FileManagerSnapshotting {
        let snapshots: [String: FSSnapshot]

        func firstLevelEntries(at path: String) -> [FSEntry]? { nil }

        func snapshot(at path: String) -> FSSnapshot {
            snapshots[path] ?? .init(bytes: 0, fileCount: 0, exists: false)
        }
    }

    private struct FakePkgRunner: PkgutilRunning {
        let pkgs: [String]
        let infoByPkg: [String: PkgutilPackageInfo]
        let filesByPkg: [String: [String]]
        let filesFailurePkgID: String?

        init(
            pkgs: [String],
            infoByPkg: [String: PkgutilPackageInfo],
            filesByPkg: [String: [String]],
            filesFailurePkgID: String? = nil
        ) {
            self.pkgs = pkgs
            self.infoByPkg = infoByPkg
            self.filesByPkg = filesByPkg
            self.filesFailurePkgID = filesFailurePkgID
        }

        /// Deliberately ignores the regex. ScanKit's second strict namespace check is part of the
        /// trust boundary and must reject out-of-product IDs even with a non-conforming runner.
        func listPackages(matchingRegex: String?) throws -> [String] { pkgs }

        func packageInfo(pkgID: String) throws -> PkgutilPackageInfo {
            guard let info = infoByPkg[pkgID] else {
                throw PkgutilCommandFailure.unexpectedFailure
            }
            return info
        }

        func files(pkgID: String) throws -> [String] {
            if filesFailurePkgID == pkgID { throw PkgutilCommandFailure.timedOut }
            guard let files = filesByPkg[pkgID] else {
                throw PkgutilCommandFailure.unexpectedFailure
            }
            return files
        }
    }

    private let meta = AppMetadata(
        bundleID: "com.acme.demo",
        bundleVendor: "com.acme",
        appName: "AcmeEditor",
        executableName: "AcmeEditor"
    )

    func test_selectedAppAnchor只投影产品特异root并过滤不存在payload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let productRoot = fixture.root
            .appendingPathComponent("Library/Application Support/Acme/AcmeEditor")
        let ghost = fixture.root
            .appendingPathComponent("Library/Preferences/com.acme.demo.ghost.plist")
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.pkg": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(productRoot, under: fixture.root) + "/Database/state.db",
                    relative(ghost, under: fixture.root),
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [
                productRoot.path: .init(bytes: 42, fileCount: 3, exists: true, isDirectory: true),
            ]
        )

        var seen: Set<String> = []
        let result = uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        )

        XCTAssertEqual(result.candidates.map(\.path), [productRoot.path])
        XCTAssertEqual(result.candidates.first?.bytes, 42)
        XCTAssertEqual(result.candidates.first?.matchReason, .pkgReceipt("com.acme.demo.pkg"))
        XCTAssertEqual(seen, [productRoot.path])
        XCTAssertFalse(seen.contains(ghost.path), "nonexistent payload must not reserve a dedup key")
    }

    func test_sameVendorOtherAppReceipt因exactBundleNamespace被拒绝() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selectedPayload = fixture.root
            .appendingPathComponent("Library/Preferences/com.acme.demo.plist")
        let otherPayload = fixture.root
            .appendingPathComponent("Library/Preferences/com.acme.other.plist")
        let otherApp = fixture.root.appendingPathComponent("Applications/Other.app")
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.pkg": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(selectedPayload, under: fixture.root),
                ],
                "com.acme.other.pkg": [
                    relative(otherApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(otherPayload, under: fixture.root),
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [
                selectedPayload.path: .init(bytes: 1, fileCount: 1, exists: true),
                otherPayload.path: .init(bytes: 1, fileCount: 1, exists: true),
            ]
        )

        var seen: Set<String> = []
        let result = uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        )

        XCTAssertEqual(result.candidates.map(\.path), [selectedPayload.path])
        XCTAssertFalse(seen.contains(otherPayload.path))
    }

    func test_umbrellaReceipt包含selected外另一App时整条拒绝且sharedAncestor不泄漏() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherApp = fixture.root.appendingPathComponent("Applications/Other.app")
        let sharedAncestor = fixture.root
            .appendingPathComponent("Library/Application Support/Acme")
        let seeminglySpecific = sharedAncestor.appendingPathComponent("AcmeEditor")
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.suite": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(otherApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(sharedAncestor, under: fixture.root),
                    relative(seeminglySpecific, under: fixture.root) + "/state.db",
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [
                sharedAncestor.path: .init(bytes: 100, fileCount: 10, exists: true, isDirectory: true),
                seeminglySpecific.path: .init(bytes: 10, fileCount: 2, exists: true, isDirectory: true),
            ]
        )

        var seen: Set<String> = []
        let result = uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(seen.isEmpty)
        XCTAssertFalse(result.isDiscoveryComplete)
        XCTAssertEqual(result.incompleteIssues, [UninstallDiscoveryIssue(
            source: .pkgReceipt,
            stage: .receiptValidation,
            pkgID: "com.acme.demo.suite",
            reason: .receiptOwnershipAmbiguous
        )])

        // The focused helper and both production aggregation paths must preserve the same typed
        // terminal evidence. This specifically guards against dropping `ProposalCollection.issues`
        // while merging receipt proposals into the primary discovery collection.
        let sync = uninstaller.candidates(
            for: try selectedIdentity(at: fixture.selectedApp, metadata: meta)
        )
        let async = await uninstaller.candidatesAsync(
            for: try selectedIdentity(at: fixture.selectedApp, metadata: meta),
            fallbacks: [.pkgReceipts]
        )
        for productionResult in [sync, async] {
            XCTAssertTrue(productionResult.candidates.isEmpty)
            XCTAssertFalse(productionResult.isDiscoveryComplete)
            XCTAssertEqual(productionResult.incompleteIssues, result.incompleteIssues)
        }
    }

    func test_没有selectedAppAnchor即使bundleID与payload都匹配也不归属() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = fixture.root
            .appendingPathComponent("Library/Preferences/com.acme.demo.plist")
        let runner = makeRunner(
            root: fixture.root,
            packages: ["com.acme.demo.pkg": [relative(payload, under: fixture.root)]]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [payload.path: .init(bytes: 1, fileCount: 1, exists: true)]
        )

        var seen: Set<String> = []
        XCTAssertTrue(uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        ).isEmpty)
        XCTAssertTrue(seen.isEmpty)
    }

    func test_selectedBundle内嵌helper只作anchor内容忽略且payload后代折叠去重() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selectedRelative = relative(fixture.selectedApp, under: fixture.root)
        let payloadRoot = fixture.root
            .appendingPathComponent("Library/Application Support/com.acme.demo")
        let payloadRelative = relative(payloadRoot, under: fixture.root)
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.pkg": [
                    selectedRelative + "/Contents/Info.plist",
                    selectedRelative + "/Contents/Library/LoginItems/AcmeHelper.app/Contents/Info.plist",
                    selectedRelative + "/Contents/Resources/state.json",
                    payloadRelative + "/one.db",
                    payloadRelative + "/nested/two.db",
                    payloadRelative + "/nested/two.db",
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [
                payloadRoot.path: .init(bytes: 8, fileCount: 2, exists: true, isDirectory: true),
            ]
        )

        var seen: Set<String> = []
        let result = uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        )

        XCTAssertEqual(result.candidates.map(\.path), [payloadRoot.path])
        XCTAssertFalse(result.candidates.contains(where: {
            $0.path.hasPrefix(fixture.selectedApp.path + "/")
        }))
    }

    func test_sync与async生产入口都传递selectedApp身份() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = fixture.root
            .appendingPathComponent("Library/Preferences/com.acme.demo.plist")
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.pkg": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(payload, under: fixture.root),
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [payload.path: .init(bytes: 1, fileCount: 1, exists: true)]
        )

        let sync = uninstaller.candidates(for: meta, selectedAppURL: fixture.selectedApp)
        let async = await uninstaller.candidatesAsync(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            fallbacks: [.pkgReceipts]
        )
        let noIdentity = await uninstaller.candidatesAsync(
            for: meta,
            fallbacks: [.pkgReceipts]
        )

        XCTAssertEqual(sync.candidates.map(\.path), [payload.path])
        XCTAssertEqual(async.candidates.map(\.path), [payload.path])
        XCTAssertTrue(noIdentity.candidates.isEmpty)
    }

    func test_seenPath去重与nilScanner保持failClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payload = fixture.root
            .appendingPathComponent("Library/Preferences/com.acme.demo.plist")
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.pkg": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(payload, under: fixture.root),
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [payload.path: .init(bytes: 1, fileCount: 1, exists: true)]
        )
        var seen: Set<String> = [payload.path]
        XCTAssertTrue(uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        ).isEmpty)

        let nilScanner = AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: FakeFM(snapshots: [:])
        )
        var emptySeen: Set<String> = []
        XCTAssertNil(nilScanner.pkgutilScanner)
        XCTAssertTrue(nilScanner.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &emptySeen
        ).isEmpty)
        XCTAssertTrue(emptySeen.isEmpty)
    }

    func test_pkgReceipt命令失败候选failClosed且typed缺口贯穿AppUninstaller() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pkgID = "com.acme.demo.pkg"
        let runner = FakePkgRunner(
            pkgs: [pkgID],
            infoByPkg: [
                pkgID: .init(
                    pkgID: pkgID,
                    volume: "/",
                    location: String(fixture.root.path.dropFirst()),
                    installTime: nil
                ),
            ],
            filesByPkg: [:],
            filesFailurePkgID: pkgID
        )
        let uninstaller = makeUninstaller(runner: runner, snapshots: [:])

        var seen: Set<String> = []
        let result = uninstaller.pkgReceiptCandidates(
            for: meta,
            selectedAppURL: fixture.selectedApp,
            seenPaths: &seen
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.isDiscoveryComplete)
        XCTAssertEqual(result.pkgReceiptIncompleteIssues, [
            PkgutilReceiptsScanner.IncompleteIssue(
                stage: .files,
                pkgID: pkgID,
                reason: .timedOut
            ),
        ])
        XCTAssertTrue(seen.isEmpty)
    }

    func test_通用App名称不能把共享结构根铸成候选_强bundleID证据优先() throws {
        let structures = ["Application Support", "Caches", "Logs", "Preferences"]
        for structure in structures {
            let genericMeta = AppMetadata(
                bundleID: "com.acme.demo",
                bundleVendor: "com.acme",
                appName: structure,
                executableName: structure
            )
            let fixture = try makeFixture(metadata: genericMeta, appFileName: structure)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let sharedRoot = fixture.root.appendingPathComponent("Users/u/Library/\(structure)")
            let strongRoot = sharedRoot.appendingPathComponent(genericMeta.bundleID)
            let runner = makeRunner(
                root: fixture.root,
                packages: [
                    "com.acme.demo.pkg": [
                        relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                        relative(sharedRoot, under: fixture.root) + "/shared.db",
                        relative(strongRoot, under: fixture.root) + "/state.db",
                    ],
                ]
            )
            let uninstaller = makeUninstaller(
                runner: runner,
                snapshots: [
                    sharedRoot.path: .init(bytes: 1_000, fileCount: 20, exists: true, isDirectory: true),
                    strongRoot.path: .init(bytes: 40, fileCount: 2, exists: true, isDirectory: true),
                ]
            )

            var seen: Set<String> = []
            let result = uninstaller.pkgReceiptCandidates(
                for: genericMeta,
                selectedAppURL: fixture.selectedApp,
                seenPaths: &seen
            )

            XCTAssertEqual(result.candidates.map(\.path), [strongRoot.path], structure)
            XCTAssertFalse(result.candidates.map(\.path).contains(sharedRoot.path), structure)
        }
    }

    func test_vendor父根与receipt产品子根跨来源只保留更具体证据() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let vendorRoot = fixture.root.appendingPathComponent("Library/Application Support/Acme")
        let productRoot = vendorRoot.appendingPathComponent(meta.appName)
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.demo.pkg": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(productRoot, under: fixture.root) + "/state.db",
                ],
            ]
        )
        let fileManager = FakeFM(snapshots: [
            vendorRoot.path: .init(bytes: 1_000, fileCount: 20, exists: true, isDirectory: true),
            productRoot.path: .init(bytes: 40, fileCount: 2, exists: true, isDirectory: true),
        ])
        let uninstaller = AppUninstaller(
            homeDirectory: fixture.root.path,
            systemLibrary: fixture.root.appendingPathComponent("SystemLibrary").path,
            fileManager: fileManager,
            vendorRules: [VendorRule(
                name: "Acme",
                bundleIDPrefix: "com.acme",
                appSupportSubdir: "Acme"
            )],
            pkgutilScanner: PkgutilReceiptsScanner(runner: runner)
        )

        let result = uninstaller.candidates(
            for: try selectedIdentity(at: fixture.selectedApp, metadata: meta)
        )

        XCTAssertEqual(result.candidates.map(\.path), [productRoot.path])
        XCTAssertEqual(result.candidates.reduce(Int64(0)) { $0 + $1.bytes }, 40)
        XCTAssertFalse(result.candidates.contains(where: { $0.path == vendorRoot.path }))
    }

    func test_selectedApp声明与磁盘bundleID不一致时整轮failClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claimed = AppMetadata(
            bundleID: "com.acme.other",
            bundleVendor: "com.acme",
            appName: "Other",
            executableName: "Other"
        )
        let payload = fixture.root.appendingPathComponent(
            "Library/Preferences/com.acme.other.plist"
        )
        let runner = makeRunner(
            root: fixture.root,
            packages: [
                "com.acme.other.pkg": [
                    relative(fixture.selectedApp, under: fixture.root) + "/Contents/Info.plist",
                    relative(payload, under: fixture.root),
                ],
            ]
        )
        let uninstaller = makeUninstaller(
            runner: runner,
            snapshots: [payload.path: .init(bytes: 10, fileCount: 1, exists: true)]
        )

        let result = await uninstaller.candidatesAsync(
            for: try selectedIdentity(at: fixture.selectedApp, metadata: claimed),
            fallbacks: [.pkgReceipts]
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertFalse(result.isDiscoveryComplete)
        XCTAssertEqual(result.incompleteIssues.count, 1)
        XCTAssertEqual(result.incompleteIssues.first?.source, .selectedAppIdentity)
        XCTAssertEqual(result.incompleteIssues.first?.stage, .identityValidation)
        XCTAssertEqual(
            result.incompleteIssues.first?.reason,
            .identityMismatch(
                claimedBundleID: claimed.bundleID,
                actualBundleID: meta.bundleID
            )
        )
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let selectedApp: URL
    }

    private func makeFixture(
        metadata: AppMetadata? = nil,
        appFileName: String = "AcmeEditor"
    ) throws -> Fixture {
        let metadata = metadata ?? meta
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-receipt-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let selectedApp = root.appendingPathComponent(
            "Applications/\(appFileName).app",
            isDirectory: true
        )
        let contents = selectedApp.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": metadata.bundleID,
            "CFBundleName": metadata.appName,
            "CFBundleExecutable": metadata.executableName ?? metadata.appName,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return Fixture(root: root, selectedApp: selectedApp)
    }

    private func makeRunner(
        root: URL,
        packages: [String: [String]]
    ) -> FakePkgRunner {
        let infos = Dictionary(uniqueKeysWithValues: packages.keys.map { pkgID in
            (
                pkgID,
                PkgutilPackageInfo(
                    pkgID: pkgID,
                    volume: "/",
                    location: String(root.path.dropFirst()),
                    installTime: nil
                )
            )
        })
        return FakePkgRunner(
            pkgs: packages.keys.sorted(),
            infoByPkg: infos,
            filesByPkg: packages
        )
    }

    private func makeUninstaller(
        runner: FakePkgRunner,
        snapshots: [String: FSSnapshot]
    ) -> AppUninstaller {
        AppUninstaller(
            homeDirectory: "/H",
            systemLibrary: "/Library",
            fileManager: FakeFM(snapshots: snapshots),
            pkgutilScanner: PkgutilReceiptsScanner(runner: runner)
        )
    }

    private func relative(_ url: URL, under root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func selectedIdentity(
        at appURL: URL,
        metadata: AppMetadata
    ) throws -> UninstallSelectedAppIdentity {
        var diskMetadata = stat()
        guard lstat(appURL.path, &diskMetadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return UninstallSelectedAppIdentity(
            appURL: appURL,
            metadata: metadata,
            expectedFileIdentity: InstalledAppFileIdentity(metadata: diskMetadata)
        )
    }
}
