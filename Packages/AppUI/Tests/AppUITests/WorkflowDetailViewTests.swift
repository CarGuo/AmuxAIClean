import XCTest
import Foundation
import Darwin
import ScanKit
import SafetyKit
@testable import AppUI

/// v1.7 M1 PR-5：WorkflowDetailView 关键 ViewModel 单测。
///
/// 验证目标：
/// 1. 空 home 不发出任何 card → cards == []，bootstrap 后 cardLoading 清空；
/// 2. AppleWorkflow 默认实例在临时 fake home 下 cards 数稳定；
/// 3. 一次性 bootstrap 幂等（重复 await 不重复加载）；
/// 4. Trash 与 Simulator managed uninstall 是两个独立事务，不共享意图或结果；
/// 5. formatBytes 处理 0 / 1KB / 1GB / Int64.max 不崩。
@MainActor
final class WorkflowDetailViewTests: XCTestCase {

    /// PR-5：空 home（既无 ~/Library/Developer/Xcode 也无 CoreSimulator） → AppleWorkflow 返回 []。
    /// bootstrap 后 cards / cardHits / cardLoading 都必须收敛到稳定空态。
    func test_PR5_bootstrap_空home_cards为空_loading清空_v17() async throws {
        let emptyHome = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: emptyHome)) }

        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: emptyHome)
        XCTAssertTrue(vm.cards.isEmpty, "未 bootstrap 前 cards 必须为空")
        XCTAssertFalse(vm.isAnyLoading)

        await vm.bootstrap()

        XCTAssertTrue(vm.cards.isEmpty, "空 home 下 AppleWorkflow 不应输出任何卡")
        XCTAssertTrue(vm.cardHits.isEmpty)
        XCTAssertTrue(vm.cardLoading.isEmpty, "bootstrap 完成后所有 card 必须从 loading 集合中移除")
        XCTAssertTrue(vm.selected.isEmpty)
    }

    /// PR-5：模拟有 DerivedData 的 home → AppleWorkflow 至少出 1 张卡（derived-data），
    /// 且 cards 中的 .safe 卡默认进入 expanded 集合。
    func test_PR5_bootstrap_有DerivedData_至少1卡_safe卡默认展开_v17() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let xcode = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: xcode, withIntermediateDirectories: true)

        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        await vm.bootstrap()

        XCTAssertFalse(vm.cards.isEmpty, "造了 DerivedData 后必有 derived-data 卡")
        let safeCards = vm.cards.filter { $0.risk == .safe }
        XCTAssertFalse(safeCards.isEmpty)
        for card in safeCards {
            XCTAssertTrue(vm.expanded.contains(card.id), "safe 卡 \(card.id) 应默认 expanded")
        }
    }

    /// PR-5：bootstrap 幂等性——重复 await 不应触发第二轮 loadAllCards。
    /// 通过观察 didBootstrap 后再次 bootstrap 时 cards 引用是否复用判断。
    func test_PR5_bootstrap_幂等_重复调用不重复加载_v17() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        await vm.bootstrap()
        let snapshot1 = vm.cardLoading
        await vm.bootstrap()
        XCTAssertEqual(vm.cardLoading, snapshot1, "二次 bootstrap 不应改变 loading 状态")
    }

    /// PR-5：toggleSelection / clearAlert 这些纯函数路径不依赖磁盘，独立验证。
    func test_PR5_toggleSelection_clearAlert_纯逻辑_v17() async {
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: makeTempHome())
        vm.toggleSelection(hitID: "a", on: true)
        vm.toggleSelection(hitID: "b", on: true)
        XCTAssertEqual(vm.selected, ["a", "b"])
        vm.toggleSelection(hitID: "a", on: false)
        XCTAssertEqual(vm.selected, ["b"])
        vm.toggleExpanded(cardID: "c1", open: true)
        XCTAssertTrue(vm.expanded.contains("c1"))
        vm.toggleExpanded(cardID: "c1", open: false)
        XCTAssertFalse(vm.expanded.contains("c1"))
    }

    /// v2026.07.15：整根 DerivedData 默认选中后，用户仍必须能改选具体项目。
    /// 父子互斥由“最后一次显式选择”决定；两个不重叠项目可以同时选择。
    func test_toggleSelection_父子重叠时最后显式选择优先_兄弟可多选() {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let rootCard = makeFilesystemCard(id: "card.derived-data.root")
        let projectCard = makeFilesystemCard(id: "card.derived-data.projects")
        let parent = WorkflowScanHit(
            url: URL(fileURLWithPath: "/DerivedData"),
            sizeBytes: 300,
            displayName: "DerivedData",
            note: nil
        )
        let projectA = WorkflowScanHit(
            url: URL(fileURLWithPath: "/DerivedData/ProjectA-hash"),
            sizeBytes: 100,
            displayName: "ProjectA",
            note: nil
        )
        let projectB = WorkflowScanHit(
            url: URL(fileURLWithPath: "/DerivedData/ProjectB-hash"),
            sizeBytes: 200,
            displayName: "ProjectB",
            note: nil
        )
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([rootCard, projectCard])
        vm.setTestHits([
            rootCard.id: [parent],
            projectCard.id: [projectA, projectB],
        ])

        vm.toggleSelection(hitID: parent.id, on: true)
        XCTAssertEqual(vm.selected, [parent.id])

        vm.toggleSelection(hitID: projectA.id, on: true)
        XCTAssertEqual(vm.selected, [projectA.id],
                       "显式选择子项必须取消已选父项")

        vm.toggleSelection(hitID: projectB.id, on: true)
        XCTAssertEqual(vm.selected, [projectA.id, projectB.id],
                       "不重叠的兄弟项目必须允许多选")

        vm.toggleSelection(hitID: parent.id, on: true)
        XCTAssertEqual(vm.selected, [parent.id],
                       "随后显式选择父项必须取消其所有已选后代")
    }

    /// 并发卡片可能在用户点击后才完成。晚到的 safe 默认选择不能把显式子项
    /// 又折回父根，否则真实 UI 会出现“点中后过一会儿自己跳回去”。
    func test_toggleSelection_显式子项不被晚到父卡默认选择覆盖() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let parentURL = home.appendingPathComponent("DerivedData", isDirectory: true)
        let childURL = parentURL.appendingPathComponent("ProjectA-hash", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 4_096)
            .write(to: childURL.appendingPathComponent("payload.bin"))
        let releaseParent = LockedFlag(false)
        let parentHit = WorkflowScanHit(
            url: parentURL,
            sizeBytes: nil,
            displayName: "DerivedData",
            note: nil
        )
        let childHit = WorkflowScanHit(
            url: childURL,
            sizeBytes: nil,
            displayName: "ProjectA",
            note: nil
        )
        let vm = WorkflowDetailViewModel(
            workflow: ParentChildDynamicWorkflow(),
            home: home,
            dynamicDiscovery: { scannerID, _, _ in
                if scannerID == "scanner.test.parent" {
                    while !releaseParent.read() {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    return DiscoveryEvidence(hits: [parentHit], incompleteIssues: [])
                }
                return DiscoveryEvidence(hits: [childHit], incompleteIssues: [])
            }
        )

        let bootstrap = Task { await vm.bootstrap() }
        for _ in 0..<500 where vm.cardHits["card.test.child"] == nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard vm.cardHits["card.test.child"]?.first != nil else {
            releaseParent.set(true)
            await bootstrap.value
            return XCTFail("子卡应先发布，才能复现用户扫描中途点击")
        }

        vm.toggleSelection(hitID: childHit.id, on: true)
        releaseParent.set(true)
        await bootstrap.value

        XCTAssertEqual(vm.selected, [childHit.id],
                       "晚到父卡的 safe 默认选择不得覆盖更早的用户显式子项")
    }

    /// PR-5：formatBytes 不应对极值崩溃。
    func test_PR5_formatBytes_边界值_不崩_v17() {
        _ = WorkflowDetailViewModel.formatBytes(0)
        _ = WorkflowDetailViewModel.formatBytes(1024)
        _ = WorkflowDetailViewModel.formatBytes(1_073_741_824)
        _ = WorkflowDetailViewModel.formatBytes(Int64.max)
    }

    /// PR-5：MainView workflow sentinel ID 不能重名也不能与既有 sentinel 冲突。
    /// 这是 sidebar 的硬约束——重名会让 List(selection:) 高亮串台。
    func test_PR5_sentinel_workflow_ID_全局唯一_v17() {
        let workflowIDs = MainView.workflowSentinelIDs
        XCTAssertEqual(workflowIDs, [
            MainView.workflowAppleSentinelID,
            MainView.workflowAndroidSentinelID,
            MainView.workflowWebNodeSentinelID,
            MainView.workflowBackendSentinelID,
        ], "workflow sentinel 必须覆盖当前四个工作流入口")

        let allSentinels: [String] = [
            MainView.appFootprintSentinelID,
            MainView.launchAgentSentinelID,
            MainView.uninstallSentinelID,
            MainView.duplicateSentinelID,
            MainView.undoHistorySentinelID,
            MainView.maintenanceSentinelID,
            MainView.brewSentinelID,
            MainView.devVersionedSentinelID,
            MainView.workflowAppleSentinelID,
            MainView.workflowAndroidSentinelID,
            MainView.workflowWebNodeSentinelID,
            MainView.workflowBackendSentinelID,
        ]
        XCTAssertEqual(Set(allSentinels).count, allSentinels.count, "sentinel ID 必须全局唯一")
    }

    // MARK: helpers

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowDetailViewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - v2026.06.22 (P0-1) performDelete 4 步握手

    /// 测试用 stub DeletionPipeline，记录调用并按预设返回 outcome。
    private final class StubDeletionPipeline: DeletionPipeline, @unchecked Sendable {
        var deniedReceived: Set<String> = []
        var movedPathsReceived: [String] = []
        var preflightPathsReceived: [String] = []
        var preflightDeniedReceived: Set<String> = []
        var vendorOverrideReceived: VendorPathOverrideRequest?
        var stubPreflight: DeletionPreflight?
        var stubSubmissionRejection: TrashPreSubmitRejection?
        var stubOutcome: TrashOutcome = TrashOutcome(movedPairs: [], failedPaths: [],
                                                     safetyRejected: [], missingPaths: [])
        var stubLegacyErr: String?

        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            preflightPathsReceived = paths
            preflightDeniedReceived = accessDeniedPaths
            return stubPreflight ?? DeletionPreflight(allowedPaths: paths, rejections: [])
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {
            deniedReceived = paths
        }
        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            // 通过 moveToTrashReturningOutcome 调到的话本方法不会被走，
            // 但保留实现以满足 protocol。
            movedPathsReceived = paths
            return (stubOutcome.movedPairs.count,
                    stubOutcome.failedPaths.count + stubOutcome.safetyRejected.count,
                    stubLegacyErr,
                    stubOutcome.movedPairs.map { ($0.originalPath, $0.trashedPath) })
        }
        func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            movedPathsReceived = paths
            let legacy: (Int, Int, String?, [(String, String)]) = (
                stubOutcome.movedPairs.count,
                stubOutcome.failedPaths.count + stubOutcome.safetyRejected.count,
                stubLegacyErr,
                stubOutcome.movedPairs.map { ($0.originalPath, $0.trashedPath) }
            )
            return (legacy, stubOutcome)
        }

        func moveToTrashVendorPathOverride(
            request: VendorPathOverrideRequest,
            dryRun: Bool,
            accessDeniedPaths: Set<String>
        ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            vendorOverrideReceived = request
            deniedReceived = accessDeniedPaths
            return await moveToTrashReturningOutcome(
                paths: request.paths,
                dryRun: dryRun
            )
        }

        func submitToTrashReturningDisposition(
            paths: [String],
            accessDeniedPaths: Set<String>,
            vendorOverrideRequest: VendorPathOverrideRequest?
        ) async -> TrashSubmissionDisposition {
            movedPathsReceived = paths
            deniedReceived = accessDeniedPaths
            vendorOverrideReceived = vendorOverrideRequest
            if let stubSubmissionRejection {
                return .preSubmitRejected(stubSubmissionRejection)
            }
            let legacy: (Int, Int, String?, [(String, String)]) = (
                stubOutcome.movedPairs.count,
                stubOutcome.failedPaths.count,
                stubLegacyErr,
                stubOutcome.movedPairs.map { ($0.originalPath, $0.trashedPath) }
            )
            return .recycleCompleted(TrashRecycleCompletion(
                attemptedPaths: paths,
                legacy: legacy,
                outcome: stubOutcome
            ))
        }
    }

    private func makeFilesystemCard(
        id: String,
        runningBundleIDPrefix: String? = nil
    ) -> DeveloperCard {
        DeveloperCard(id: id, title: id, summary: "",
                      source: .literal(paths: []),
                      recipe: .filesystem, risk: .safe,
                      runningBundleIDPrefix: runningBundleIDPrefix)
    }

    private func makeManagedCard(
        id: String,
        kind: ManagedUninstallRecipe = .simulatorDevice,
        risk: DeveloperCard.Risk = .confirm
    ) -> DeveloperCard {
        DeveloperCard(
            id: id,
            title: id,
            summary: "",
            source: .dynamicScanner(scannerID: "scanner.simctl-devices"),
            recipe: .managedUninstall(kind),
            risk: risk
        )
    }

    private func makeManagedHit(
        path: String,
        displayName: String,
        identifier: String?,
        sizeBytes: Int64 = 0
    ) -> WorkflowScanHit {
        WorkflowScanHit(
            url: URL(fileURLWithPath: path),
            sizeBytes: sizeBytes,
            displayName: displayName,
            note: nil,
            managedUninstallIdentifier: identifier
        )
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Bool

        init(_ initialValue: Bool) {
            storage = initialValue
        }

        func read() -> Bool {
            lock.withLock { storage }
        }

        func set(_ value: Bool) {
            lock.withLock { storage = value }
        }
    }

    private struct LiteralFilesystemWorkflow: DeveloperWorkflow {
        let path: String
        let id = "workflow.test.literal"
        let displayName = "workflow.test.literal"
        let subtitle = "workflow.test.literal"

        func cards(home: URL) -> [DeveloperCard] {
            [DeveloperCard(
                id: "card.test.literal",
                title: "card.test.literal",
                summary: "",
                source: .literal(paths: [path]),
                recipe: .filesystem,
                risk: .safe
            )]
        }
    }

    private struct VersionedOnlyWorkflow: DeveloperWorkflow {
        let ruleID: String
        let id = "workflow.test.versioned"
        let displayName = "workflow.test.versioned"
        let subtitle = "workflow.test.versioned"

        func cards(home: URL) -> [DeveloperCard] {
            [DeveloperCard(
                id: "card.test.versioned",
                title: "card.test.versioned",
                summary: "",
                source: .versionedRoot(ruleID: ruleID),
                recipe: .filesystem,
                risk: .safe
            )]
        }
    }

    private struct DynamicOnlyWorkflow: DeveloperWorkflow {
        let id = "workflow.test.dynamic"
        let displayName = "workflow.test.dynamic"
        let subtitle = "workflow.test.dynamic"

        func cards(home: URL) -> [DeveloperCard] {
            [DeveloperCard(
                id: "card.test.dynamic",
                title: "card.test.dynamic",
                summary: "",
                source: .dynamicScanner(scannerID: "scanner.test.dynamic"),
                recipe: .filesystem,
                risk: .safe
            )]
        }
    }

    private struct ParentChildDynamicWorkflow: DeveloperWorkflow {
        let id = "workflow.test.parent-child-dynamic"
        let displayName = "workflow.test.parent-child-dynamic"
        let subtitle = "workflow.test.parent-child-dynamic"

        func cards(home: URL) -> [DeveloperCard] {
            [
                DeveloperCard(
                    id: "card.test.parent",
                    title: "card.test.parent",
                    summary: "",
                    source: .dynamicScanner(scannerID: "scanner.test.parent"),
                    recipe: .filesystem,
                    risk: .safe
                ),
                DeveloperCard(
                    id: "card.test.child",
                    title: "card.test.child",
                    summary: "",
                    source: .dynamicScanner(scannerID: "scanner.test.child"),
                    recipe: .filesystem,
                    risk: .safe
                ),
            ]
        }
    }

    private enum InjectedDynamicDiscoveryError: Error {
        case failedWithoutScopedPath
    }

    private actor VersionedDiscoveryProbe {
        let result: KnownVersionedRoots.ScanResult
        private var calls = 0

        init(result: KnownVersionedRoots.ScanResult) {
            self.result = result
        }

        func discover(home: URL) -> KnownVersionedRoots.ScanResult {
            calls &+= 1
            return result
        }

        func callCount() -> Int { calls }
    }

    private func makeUndoStore() throws -> (UndoHistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WFDVT-\(UUID().uuidString).json")
        return (UndoHistoryStore(storeURL: url, maxHistoryCount: 10), url)
    }

    private func confirmedIntent(
        from vm: WorkflowDetailViewModel,
        pipeline: StubDeletionPipeline
    ) async throws -> WorkflowDeletionIntent {
        await vm.requestDeleteConfirmation(pipeline: pipeline)
        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            throw NSError(
                domain: "WorkflowDetailViewTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected Workflow delete confirmation"]
            )
        }
        vm.confirmDelete(
            confirmation,
            executionPlan: executionPlan(for: confirmation)
        )
        return try XCTUnwrap(vm.takePendingConfirmedDeleteIntent())
    }

    private func executionPlan(
        for confirmation: WorkflowDeleteConfirmation
    ) -> ToolTrashExecutionPlan {
        ToolTrashExecutionPlan(
            paths: confirmation.intent.filesystemPaths,
            runningAppSkipped: [],
            vendorOverrideRequest: confirmation.intent.vendorOverrideRequest
        )
    }

    func test_requestDeleteConfirmation_先完整预检_拒绝时展示typedNotice而非执行结果() async {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/Android/sdk/system-images"),
            sizeBytes: 200,
            displayName: "system-images",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.android")
        let denied: Set<String> = ["/Denied"]
        let vm = WorkflowDetailViewModel(
            workflow: AndroidWorkflow(),
            home: home
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(
            revision: 7,
            permissionDeniedPaths: denied
        ))

        let pipe = StubDeletionPipeline()
        pipe.stubPreflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [.init(path: hit.url.path, reason: "vendorPathRule")]
        )

        await vm.requestDeleteConfirmation(pipeline: pipe)

        XCTAssertEqual(pipe.preflightPathsReceived, [hit.url.path])
        XCTAssertEqual(pipe.preflightDeniedReceived, denied)
        guard case let .preflightNotice(_, rejections) = vm.activeSheet else {
            return XCTFail("尚未提交的安全拒绝必须进入 typed notice，而不是伪造执行结果")
        }
        XCTAssertEqual(rejections.first?.path, hit.url.path)
        XCTAssertNil(vm.lastDeleteResult)
        XCTAssertNil(vm.takePendingConfirmedDeleteIntent())
    }

    func test_vendorPathRule_专业模式进入严格确认并用类型化override执行() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let path = "/Android/sdk/system-images"
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: path),
            sizeBytes: 200,
            displayName: "system-images",
            note: nil
        )
        let card = makeFilesystemCard(
            id: "card.android.vendor",
            runningBundleIDPrefix: AndroidWorkflow.studioBundleIDPrefix
        )
        let vm = WorkflowDetailViewModel(workflow: AndroidWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])

        let pipeline = StubDeletionPipeline()
        pipeline.stubPreflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [.init(path: path, reason: "vendorPathRule")],
            vendorOverrideEligiblePaths: [path]
        )
        pipeline.stubOutcome = TrashOutcome(
            movedPairs: [(path, "/Trash/system-images")],
            failedPaths: [],
            safetyRejected: [],
            missingPaths: []
        )

        await vm.requestDeleteConfirmation(pipeline: pipeline)

        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("纯 vendorPathRule 应进入专业模式严格确认，而不是被完全封死")
        }
        let request = try XCTUnwrap(confirmation.intent.vendorOverrideRequest)
        XCTAssertEqual(request.paths, [path])
        XCTAssertEqual(confirmation.intent.filesystemCandidates.map(\.path), [path])
        XCTAssertEqual(
            confirmation.intent.filesystemCandidates.first?.bundleIDPrefix,
            AndroidWorkflow.studioBundleIDPrefix
        )

        vm.confirmDelete(
            confirmation,
            executionPlan: ToolTrashExecutionPlan(
                paths: [path],
                runningAppSkipped: [],
                vendorOverrideRequest: request,
                strictConfirmationToken: String(
                    localized: "delete.vendor_override.token",
                    bundle: .module
                )
            )
        )
        let intent = try XCTUnwrap(vm.takePendingConfirmedDeleteIntent())
        await vm.performDelete(pipeline: pipeline, intent: intent)

        XCTAssertEqual(pipeline.vendorOverrideReceived, request)
        XCTAssertEqual(pipeline.movedPathsReceived, [path])
    }

    func test_最终重验新发现vendor风险_用冻结剩余路径重开严格确认且不展示结果() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let path = "/Android/sdk/system-images"
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: path),
            sizeBytes: 200,
            displayName: "system-images",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.android.vendor.final")
        let vm = WorkflowDetailViewModel(workflow: AndroidWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        let pipeline = StubDeletionPipeline()
        let intent = try await confirmedIntent(from: vm, pipeline: pipeline)
        XCTAssertNil(intent.vendorOverrideRequest)

        let finalPreflight = DeletionPreflight(
            allowedPaths: [],
            rejections: [
                .init(path: path, reason: SafetyRejection.vendorPathRule.rawValue)
            ],
            vendorOverrideEligiblePaths: [path]
        )
        pipeline.stubSubmissionRejection = .safety(finalPreflight)

        await vm.performDelete(pipeline: pipeline, intent: intent)

        guard case let .deleteConfirm(strictConfirmation) = vm.activeSheet else {
            return XCTFail("Final vendor-only rejection must reopen strict confirmation")
        }
        let strictIntent = strictConfirmation.intent
        XCTAssertEqual(strictIntent.filesystemPaths, intent.filesystemPaths)
        XCTAssertEqual(strictIntent.filesystemHitIDsByPath, intent.filesystemHitIDsByPath)
        XCTAssertEqual(strictIntent.filesystemCandidates, intent.filesystemCandidates)
        XCTAssertEqual(strictIntent.vendorOverrideRequest?.paths, [path])
        XCTAssertEqual(vm.selected, [hit.id])
        XCTAssertNil(vm.lastDeleteResult)
        XCTAssertNil(vm.simulatorUninstallState,
                     "Trash 最终重验不得偷偷启动托管卸载事务")
    }

    func test_runningApp选择全部跳过_不调用删除也不伪造执行结果() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let path = "/A/running-cache"
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: path),
            sizeBytes: 123,
            displayName: "Running Cache",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.running")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        let pipeline = StubDeletionPipeline()

        await vm.requestDeleteConfirmation(pipeline: pipeline)
        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("预检通过后应展示确认")
        }
        let skipped = OperationResultPayload.RunningAppSkippedItem(
            path: path,
            itemTitle: hit.displayName,
            appName: "Example IDE"
        )
        let accepted = vm.confirmDelete(
            confirmation,
            executionPlan: ToolTrashExecutionPlan(
                paths: [],
                runningAppSkipped: [skipped]
            )
        )
        XCTAssertTrue(accepted)
        XCTAssertNil(vm.takePendingConfirmedDeleteIntent(),
                     "全部跳过是确认阶段取消，不得排队任何提交")
        XCTAssertNil(vm.activeSheet, "纯文件系统全跳过应直接关闭确认页")

        XCTAssertTrue(pipeline.movedPathsReceived.isEmpty)
        XCTAssertNil(vm.lastDeleteResult,
                     "所有项都跳过时没有跨过提交边界，不能显示成功或失败")
        XCTAssertEqual(vm.selected, [hit.id], "跳过项必须保留选择，便于用户关闭应用后重试")
    }

    func test_runningApp文件项全跳过_managed卸载仍必须由独立请求启动() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let filesystemPath = "/A/running-cache"
        let filesystemHit = WorkflowScanHit(
            url: URL(fileURLWithPath: filesystemPath),
            sizeBytes: 123,
            displayName: "Running Cache",
            note: nil
        )
        let managedHit = makeManagedHit(
            path: "/simulator/frozen",
            displayName: "Frozen Simulator",
            identifier: "11111111-2222-3333-4444-555555555555"
        )
        let filesystemCard = makeFilesystemCard(id: "card.running")
        let managedCard = makeManagedCard(id: "card.managed")
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([filesystemCard, managedCard])
        vm.setTestHits([
            filesystemCard.id: [filesystemHit],
            managedCard.id: [managedHit],
        ])
        vm.setTestSelection([filesystemHit.id, managedHit.id])
        let pipeline = StubDeletionPipeline()

        await vm.requestDeleteConfirmation(pipeline: pipeline)
        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("Trash 应只为文件子集展示确认")
        }
        XCTAssertEqual(confirmation.intent.selectedHitIDs, [filesystemHit.id])
        XCTAssertEqual(confirmation.intent.filesystemPaths, [filesystemPath])
        let skipped = OperationResultPayload.RunningAppSkippedItem(
            path: filesystemPath,
            itemTitle: filesystemHit.displayName,
            appName: "Example IDE"
        )
        let accepted = vm.confirmDelete(
            confirmation,
            executionPlan: ToolTrashExecutionPlan(
                paths: [],
                runningAppSkipped: [skipped]
            )
        )
        XCTAssertTrue(accepted)
        XCTAssertNil(vm.takePendingConfirmedDeleteIntent(),
                     "Trash 文件全跳过时不得用 managed 项伪造 Trash 意图")
        XCTAssertTrue(pipeline.movedPathsReceived.isEmpty)
        XCTAssertNil(vm.simulatorUninstallState,
                     "Trash 确认结束不能自动跳到 managed 卸载")
        XCTAssertEqual(vm.selected, [filesystemHit.id, managedHit.id])

        await vm.requestSimulatorUninstall()

        guard case let .review(intent) = vm.simulatorUninstallState else {
            return XCTFail("managed 卸载必须经独立请求后才进入 review")
        }
        XCTAssertEqual(intent.selectedHitIDs, [managedHit.id])
        XCTAssertEqual(intent.items.map(\.hitID), [managedHit.id])
        XCTAssertEqual(intent.items.map(\.kind), [.simulatorDevice])
        guard case .simulatorUninstall = vm.activeSheet else {
            return XCTFail("managed 卸载必须使用自己的单一状态 sheet")
        }
    }

    func test_requestDeleteConfirmation_允许时冻结选择_等sheet关闭后才能执行() async {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/A/cache"),
            sizeBytes: 123,
            displayName: "cache",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.cache")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        let pipe = StubDeletionPipeline()

        await vm.requestDeleteConfirmation(pipeline: pipe)

        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("预检通过后应展示统一确认 sheet")
        }
        XCTAssertEqual(confirmation.selectedIDs, [hit.id])
        XCTAssertNil(vm.takePendingConfirmedDeleteIntent(), "用户确认前不能排队执行")
        vm.confirmDelete(
            confirmation,
            executionPlan: executionPlan(for: confirmation)
        )
        XCTAssertNil(vm.activeSheet)
        XCTAssertEqual(vm.takePendingConfirmedDeleteIntent()?.selectedHitIDs, [hit.id])
        XCTAssertNil(vm.takePendingConfirmedDeleteIntent(), "handoff 只能消费一次")
    }

    func test_workflow扫描会话_自行收集permissionDenied与partial证据() async throws {
        let home = makeTempHome()
        let target = home.appendingPathComponent("target", isDirectory: true)
        let locked = target.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([0x01]).write(to: locked.appendingPathComponent("payload.bin"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        addTeardownBlock {
            _ = chmod(locked.path, S_IRWXU)
            do {
                try FileManager.default.removeItem(at: home)
            } catch {
                XCTFail("cleanup failed: \(error)")
            }
        }

        let vm = WorkflowDetailViewModel(
            workflow: LiteralFilesystemWorkflow(path: target.path),
            home: home
        )
        await vm.bootstrap()

        XCTAssertGreaterThan(vm.scanEvidence.revision, 0)
        XCTAssertTrue(
            vm.scanEvidence.permissionDeniedPaths.contains(locked.path)
                || vm.scanEvidence.permissionDeniedPaths.contains(target.path),
            "Workflow 的 BulkScanner 必须把本会话无权限子树记录下来"
        )
        XCTAssertTrue(
            vm.scanEvidence.partialPaths.contains(locked.path)
                || vm.scanEvidence.partialPaths.contains(target.path),
            "无权限子树同时意味着本轮统计不完整"
        )
    }

    func test_versionedRoot_空命中与发现失败共用一次扫描会话证据() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let deniedPath = home.appendingPathComponent("Library/Android/sdk/platforms").path
        let partialPath = home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport").path
        let probe = VersionedDiscoveryProbe(result: KnownVersionedRoots.ScanResult(
            hits: [],
            incompleteIssues: [
                ScanIncompleteIssue(path: deniedPath, reason: .permissionDenied),
                ScanIncompleteIssue(path: partialPath, reason: .enumerationFailed),
            ]
        ))
        let vm = WorkflowDetailViewModel(
            workflow: VersionedOnlyWorkflow(ruleID: "android.sdk-platforms.versioned"),
            home: home,
            versionedRootDiscovery: { home in
                await probe.discover(home: home)
            }
        )

        await vm.bootstrap()
        await vm.bootstrap()

        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 1, "同一 Workflow revision 只能发现一次全部版本化根")
        XCTAssertEqual(vm.cardHits["card.test.versioned"], [])
        XCTAssertTrue(vm.scanEvidence.permissionDeniedPaths.contains(deniedPath))
        XCTAssertTrue(vm.scanEvidence.partialPaths.isSuperset(of: [deniedPath, partialPath]))
    }

    func test_dynamicScanner_部分命中不能丢失同会话发现证据() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let target = home.appendingPathComponent("Projects/App/node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0x01]).write(to: target.appendingPathComponent("package.bin"))
        let metadataPath = target.appendingPathComponent("private-cache").path
        let tccPath = target.appendingPathComponent("tcc-cache").path
        let metadataIssue = ScanIncompleteIssue(
            path: metadataPath,
            reason: .metadataUnavailable,
            stage: .metadata,
            posixErrorCode: EIO
        )
        let tccIssue = ScanIncompleteIssue(
            path: tccPath,
            reason: .tccProtectedSkipped,
            stage: .open,
            posixErrorCode: EPERM
        )
        let hit = WorkflowScanHit(
            url: target,
            sizeBytes: nil,
            displayName: "App",
            note: target.path
        )
        let vm = WorkflowDetailViewModel(
            workflow: DynamicOnlyWorkflow(),
            home: home,
            dynamicDiscovery: { _, _, _ in
                DiscoveryEvidence(
                    hits: [hit],
                    incompleteIssues: [metadataIssue, tccIssue]
                )
            }
        )

        await vm.bootstrap()

        XCTAssertEqual(vm.cardHits["card.test.dynamic"]?.map(\.url), [target])
        XCTAssertTrue(vm.scanEvidence.incompleteIssues.contains(metadataIssue),
                      "动态发现的 metadata stage/errno 必须穿过中间 DTO 原样保留")
        XCTAssertTrue(vm.scanEvidence.incompleteIssues.contains(tccIssue),
                      "TCC reason/stage/errno 不得被压平或重建")
        XCTAssertTrue(vm.scanEvidence.partialPaths.isSuperset(of: [metadataPath, tccPath]))
        XCTAssertFalse(vm.scanEvidence.permissionDeniedPaths.contains(metadataPath))
        XCTAssertTrue(vm.scanEvidence.permissionDeniedPaths.contains(tccPath))
    }

    /// v2026.07.15：完整扫描的 0-byte filesystem 目标没有清理收益，不能发布成
    /// “Zero KB” row，也不能因为 safe 卡默认选择而制造一个无效果操作。
    func test_filesystem完整零占用_发布边界过滤row且不默认选择() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let emptyArchives = home.appendingPathComponent("Archives", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyArchives,
            withIntermediateDirectories: true
        )
        let vm = WorkflowDetailViewModel(
            workflow: LiteralFilesystemWorkflow(path: emptyArchives.path),
            home: home
        )

        await vm.bootstrap()

        XCTAssertEqual(vm.cardHits["card.test.literal"], [])
        XCTAssertEqual(vm.cardTotalBytes["card.test.literal"], 0)
        XCTAssertTrue(vm.selected.isEmpty,
                      "完整 0-byte hit 不得进入 safe 卡默认选择")
        XCTAssertTrue(vm.scanEvidence.incompleteIssues.isEmpty)
    }

    /// v2026.07.15：若 0 伴随目标级 incomplete evidence，它只能表示未知下界。
    /// 必须保留 row 与证据，并把容量发布为 nil，不能与真正空目录合并。
    func test_filesystem零占用但扫描不完整_保留row并发布未知容量() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let target = home.appendingPathComponent("uncertain-cache")
        try Data().write(to: target)
        let issue = ScanIncompleteIssue(
            path: target.path,
            reason: .metadataUnavailable,
            stage: .metadata,
            posixErrorCode: EIO
        )
        let sourceHit = WorkflowScanHit(
            url: target,
            sizeBytes: 0,
            displayName: "uncertain-cache",
            note: target.path
        )
        let vm = WorkflowDetailViewModel(
            workflow: DynamicOnlyWorkflow(),
            home: home,
            dynamicDiscovery: { _, _, _ in
                DiscoveryEvidence(hits: [sourceHit], incompleteIssues: [issue])
            }
        )

        await vm.bootstrap()

        let published = try XCTUnwrap(vm.cardHits["card.test.dynamic"]?.first)
        XCTAssertEqual(published.id, sourceHit.id)
        XCTAssertNil(published.sizeBytes,
                     "不完整扫描的 0 只是未知下界，UI 必须显示未知容量")
        XCTAssertTrue(vm.selected.contains(published.id))
        XCTAssertTrue(vm.scanEvidence.incompleteIssues.contains(issue))
    }

    func test_dynamicScanner_无路径的通用异常不伪造HOME根不完整证据() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let vm = WorkflowDetailViewModel(
            workflow: DynamicOnlyWorkflow(),
            home: home,
            dynamicDiscovery: { _, _, _ in
                throw InjectedDynamicDiscoveryError.failedWithoutScopedPath
            }
        )

        await vm.bootstrap()

        XCTAssertEqual(vm.cardHits["card.test.dynamic"], [])
        XCTAssertFalse(vm.scanEvidence.partialPaths.contains(home.path))
        XCTAssertFalse(vm.scanEvidence.permissionDeniedPaths.contains(home.path))
        XCTAssertFalse(
            vm.scanEvidence.incompleteIssues.contains { $0.path == home.path },
            "没有可信绝对路径的 provider Error 只能进日志，不得污染 HOME 下所有删除候选"
        )
    }

    func test_workflowTypedEvidence_权限与纯partial保留不同reason() {
        let denied = "/tmp/workflow-denied"
        let partial = "/tmp/workflow-partial"
        let evidence = WorkflowScanEvidence(
            revision: 9,
            permissionDeniedPaths: [denied],
            partialPaths: [denied, partial]
        )

        XCTAssertEqual(
            Set(evidence.incompleteIssues),
            Set([
                ScanIncompleteIssue(path: denied, reason: .permissionDenied),
                ScanIncompleteIssue(path: partial, reason: .enumerationFailed),
            ])
        )
    }

    func test_workflowSiblingIncomplete_所选普通目标仍走简单确认() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let target = home.appendingPathComponent("selected-cache", isDirectory: true)
        let sibling = home.appendingPathComponent("unreadable-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let hit = WorkflowScanHit(
            url: target,
            sizeBytes: 128,
            displayName: "selected-cache",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.sibling-incomplete")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(
            revision: 10,
            partialPaths: [sibling.path]
        ))

        await vm.requestDeleteConfirmation(pipeline: TrashPipeline(home: home.path))

        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("Unrelated sibling evidence must not block the selected target")
        }
        XCTAssertNil(confirmation.intent.preparedInteraction?.scanIncompleteOverrideRequest)
        XCTAssertTrue(confirmation.intent.accessDeniedPaths.isEmpty)
        XCTAssertEqual(
            confirmation.intent.preparedInteraction?.plan.intent.candidates.first?.accessEvidence,
            .complete
        )
    }

    func test_workflowSelectedIncomplete_目标重验后严格确认并冻结同一证据() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let target = home.appendingPathComponent("selected-partial", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let issue = ScanIncompleteIssue(
            path: target.appendingPathComponent("unreadable-child").path,
            reason: .enumerationFailed,
            stage: .enumerate,
            posixErrorCode: EIO
        )
        let hit = WorkflowScanHit(
            url: target,
            sizeBytes: 256,
            displayName: "selected-partial",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.selected-incomplete")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(
            revision: 11,
            incompleteIssues: [issue]
        ))

        await vm.requestDeleteConfirmation(pipeline: TrashPipeline(home: home.path))

        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("Selected incomplete target should reach strict confirmation")
        }
        let request = try XCTUnwrap(
            confirmation.intent.preparedInteraction?.scanIncompleteOverrideRequest
        )
        XCTAssertEqual(request.paths, [target.path])
        XCTAssertEqual(request.entries.flatMap(\.incompleteIssues), [issue])
        XCTAssertEqual(confirmation.intent.accessDeniedPaths, [issue.path])
        guard case .incomplete = confirmation.intent.preparedInteraction?
            .plan.intent.candidates.first?.accessEvidence else {
            return XCTFail("The frozen intent must retain typed incomplete access evidence")
        }

        let accepted = vm.confirmDelete(
            confirmation,
            executionPlan: ToolTrashExecutionPlan(
                paths: [target.path],
                runningAppSkipped: [],
                scanIncompleteOverrideRequest: request,
                strictConfirmationToken: String(
                    localized: "delete.vendor_override.token",
                    bundle: .module
                )
            )
        )
        XCTAssertTrue(accepted)
        let intent = try XCTUnwrap(vm.takePendingConfirmedDeleteIntent())
        XCTAssertEqual(intent.accessDeniedPaths, [issue.path])
        XCTAssertEqual(intent.authorizedInteraction?.scanIncompleteOverrideRequest, request)
    }

    func test_workflowSelectedIncomplete_目标父目录不可移动时直接typed阻断() async throws {
        let home = makeTempHome()
        let parent = home.appendingPathComponent("read-only-parent", isDirectory: true)
        let target = parent.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, S_IRUSR | S_IXUSR), 0)
        addTeardownBlock {
            _ = chmod(parent.path, S_IRWXU)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: home))
        }
        let hit = WorkflowScanHit(
            url: target,
            sizeBytes: nil,
            displayName: "selected",
            note: nil
        )
        let card = makeFilesystemCard(id: "card.direct-target-block")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(
            revision: 12,
            incompleteIssues: [ScanIncompleteIssue(
                path: target.path,
                reason: .permissionDenied,
                stage: .open,
                posixErrorCode: EACCES
            )]
        ))

        await vm.requestDeleteConfirmation(pipeline: TrashPipeline(home: home.path))

        guard case let .preflightNotice(_, rejections) = vm.activeSheet else {
            return XCTFail("A target whose parent cannot mutate must be blocked before confirmation")
        }
        XCTAssertEqual(
            rejections.first?.reason,
            ScanIncompleteTargetRejectionReason.posixPermissionDenied.rawValue
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func test_Trash意图只冻结filesystem_不携带managed且确认后不回读可变cards() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let filesystemCard = makeFilesystemCard(id: "card.filesystem")
        let managedCard = makeManagedCard(id: "card.managed")
        let oldFile = WorkflowScanHit(
            url: URL(fileURLWithPath: "/old/cache"),
            sizeBytes: 10,
            displayName: "old cache",
            note: nil
        )
        let oldManaged = makeManagedHit(
            path: "/old/simulator",
            displayName: "old simulator",
            identifier: "11111111-2222-3333-4444-555555555555"
        )
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([filesystemCard, managedCard])
        vm.setTestHits([
            filesystemCard.id: [oldFile],
            managedCard.id: [oldManaged],
        ])
        vm.setTestSelection([oldFile.id, oldManaged.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 42))
        let pipeline = StubDeletionPipeline()
        pipeline.stubOutcome = TrashOutcome(
            movedPairs: [(oldFile.url.path, "/Trash/cache")],
            failedPaths: [],
            safetyRejected: [],
            missingPaths: []
        )

        await vm.requestDeleteConfirmation(pipeline: pipeline)
        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("应生成独立 Trash 冻结意图")
        }
        XCTAssertEqual(confirmation.intent.selectedHitIDs, [oldFile.id])
        XCTAssertEqual(confirmation.intent.filesystemPaths, [oldFile.url.path])
        XCTAssertEqual(confirmation.intent.itemCount, 1)
        let revisionBefore = vm.scanEvidence.revision
        vm.toggleSelection(hitID: oldManaged.id, on: false)
        await vm.refreshAll()
        XCTAssertEqual(vm.selected, [oldFile.id, oldManaged.id], "Trash 确认期间选择必须冻结")
        XCTAssertEqual(vm.scanEvidence.revision, revisionBefore, "确认事务期间重扫必须禁用")

        let newFile = WorkflowScanHit(
            url: URL(fileURLWithPath: "/new/cache"),
            sizeBytes: 20,
            displayName: "new cache",
            note: nil
        )
        vm.setTestCards([filesystemCard])
        vm.setTestHits([filesystemCard.id: [newFile]])
        vm.confirmDelete(
            confirmation,
            executionPlan: executionPlan(for: confirmation)
        )
        let intent = try XCTUnwrap(vm.takePendingConfirmedDeleteIntent())
        await vm.performDelete(pipeline: pipeline, intent: intent)

        XCTAssertEqual(pipeline.movedPathsReceived, [oldFile.url.path])
        XCTAssertNil(vm.simulatorUninstallState,
                     "Trash 执行完成不得自动复用选中集启动 managed 事务")
        XCTAssertEqual(vm.selected, [oldManaged.id],
                       "Trash 成功只能消费 filesystem row，managed row 保留")
    }

    func test_filesystem最终安全拒绝_不启动独立managed事务() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let filesystemCard = makeFilesystemCard(id: "card.filesystem")
        let managedCard = makeManagedCard(id: "card.managed")
        let file = WorkflowScanHit(
            url: URL(fileURLWithPath: "/blocked/cache"),
            sizeBytes: 10,
            displayName: "cache",
            note: nil
        )
        let managed = makeManagedHit(
            path: "/simulator",
            displayName: "simulator",
            identifier: "11111111-2222-3333-4444-555555555555"
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([filesystemCard, managedCard])
        vm.setTestHits([
            filesystemCard.id: [file],
            managedCard.id: [managed],
        ])
        vm.setTestSelection([file.id, managed.id])
        let pipeline = StubDeletionPipeline()
        let intent = try await confirmedIntent(from: vm, pipeline: pipeline)
        XCTAssertEqual(intent.selectedHitIDs, [file.id])
        let rejection = DeletionPreflight.Rejection(
            path: file.url.path,
            reason: SafetyRejection.rootOrAboveHome.rawValue
        )
        pipeline.stubSubmissionRejection = .safety(DeletionPreflight(
            allowedPaths: [],
            rejections: [rejection]
        ))

        await vm.performDelete(pipeline: pipeline, intent: intent)

        XCTAssertNil(vm.simulatorUninstallState,
                     "filesystem 安全拒绝后不能偷偷开始 managed 卸载")
        guard case let .preflightNotice(_, rejections) = vm.activeSheet else {
            return XCTFail("最终重验拒绝必须回 typed notice，不能伪造成执行结果")
        }
        XCTAssertEqual(rejections, [rejection])
        XCTAssertNil(vm.lastDeleteResult)
        XCTAssertEqual(vm.selected, [file.id, managed.id])
        XCTAssertEqual(vm.cardHits[managedCard.id], [managed])
    }

    func test_managedUninstall_request_review_executing_finished_成功仅局部移除() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let managedCard = makeManagedCard(
            id: "card.managed.runtimes",
            kind: .simulatorRuntime
        )
        let unrelatedCard = makeFilesystemCard(id: "card.unrelated")
        let managedHits = (0..<8).map { index in
            makeManagedHit(
                path: "/simulator/runtime/\(index)",
                displayName: "Runtime \(index)",
                identifier: "11111111-2222-3333-4444-\(String(format: "%012llX", UInt64(index + 1)))",
                sizeBytes: 1_024
            )
        }
        let unrelatedHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/unrelated/cache"),
            sizeBytes: 9_999,
            displayName: "Unrelated Cache",
            note: nil
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([managedCard, unrelatedCard])
        vm.setTestHits([
            managedCard.id: managedHits,
            unrelatedCard.id: [unrelatedHit],
        ])
        vm.setTestSelection(Set(managedHits.map(\.id)).union([unrelatedHit.id]))
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 7))
        let unrelatedLoadingSnapshot = vm.cardLoading

        await vm.requestSimulatorUninstall()

        guard case let .review(reviewIntent) = vm.simulatorUninstallState else {
            return XCTFail("managed request 必须收敛到 review")
        }
        XCTAssertEqual(reviewIntent.selectedHitIDs, Set(managedHits.map(\.id)))
        XCTAssertEqual(reviewIntent.items.map(\.kind), Array(repeating: .simulatorRuntime, count: 8))
        XCTAssertEqual(reviewIntent.totalBytes, 8_192)
        guard case .simulatorUninstall = vm.activeSheet else {
            return XCTFail("review 必须留在 managed uninstall 独立 sheet")
        }

        let executionTask = Task { @MainActor in
            await vm.executeSimulatorUninstall()
        }
        var observedExecuting: WorkflowDetailViewModel.SimulatorUninstallProgress?
        for _ in 0..<200 {
            if case let .executing(intent, progress) = vm.simulatorUninstallState {
                XCTAssertEqual(intent.id, reviewIntent.id)
                observedExecuting = progress
                break
            }
            if case .finished = vm.simulatorUninstallState { break }
            await Task.yield()
        }
        await executionTask.value

        XCTAssertNotNil(observedExecuting,
                        "执行必须发布独立 executing 状态，不能用全局 card loading 代替")
        guard case let .finished(finishedIntent, completion) = vm.simulatorUninstallState else {
            return XCTFail("所有托管提交完成后必须保留 finished 终态")
        }
        XCTAssertEqual(finishedIntent, reviewIntent)
        XCTAssertEqual(completion.receipt?.submittedItemIDs, managedHits.map(\.id))
        XCTAssertEqual(completion.succeededCount, managedHits.count)
        XCTAssertEqual(completion.failedCount, 0)
        XCTAssertTrue(completion.skippedItems.isEmpty)
        XCTAssertEqual(vm.cardHits[managedCard.id], [])
        XCTAssertEqual(vm.cardTotalBytes[managedCard.id], 0)
        XCTAssertEqual(vm.cardHits[unrelatedCard.id], [unrelatedHit])
        XCTAssertEqual(vm.cardTotalBytes[unrelatedCard.id], unrelatedHit.sizeBytes)
        XCTAssertEqual(vm.selected, [unrelatedHit.id])
        XCTAssertEqual(vm.cardLoading, unrelatedLoadingSnapshot,
                       "managed 成功只局部移除 row，不得让无关卡进入 loading")
        guard case .simulatorUninstall = vm.activeSheet else {
            return XCTFail("finished 结果必须仍在同一 managed sheet 中可见")
        }

        vm.finishSimulatorUninstallPresentation()
        XCTAssertNil(vm.simulatorUninstallState)
        XCTAssertNil(vm.activeSheet)
    }

    func test_managedUninstall_review冻结计划_执行不回读可变cards与hits() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let card = makeManagedCard(id: "card.managed.freeze")
        let oldHit = makeManagedHit(
            path: "/simulator/old",
            displayName: "Old Simulator",
            identifier: "11111111-2222-3333-4444-555555555555"
        )
        let newHit = makeManagedHit(
            path: "/simulator/new",
            displayName: "New Simulator",
            identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [oldHit]])
        vm.setTestSelection([oldHit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 21))

        await vm.requestSimulatorUninstall()
        guard case let .review(frozenIntent) = vm.simulatorUninstallState else {
            return XCTFail("请求应冻结 old hit 计划")
        }
        XCTAssertEqual(frozenIntent.items.map(\.hitID), [oldHit.id])
        XCTAssertEqual(frozenIntent.items.map(\.args), [[
            "simctl", "delete", "11111111-2222-3333-4444-555555555555",
        ]])

        vm.setTestHits([card.id: [newHit]])
        vm.setTestSelection([newHit.id])
        await vm.executeSimulatorUninstall()

        guard case let .finished(intent, completion) = vm.simulatorUninstallState else {
            return XCTFail("执行必须消费 review 时冻结的 intent")
        }
        XCTAssertEqual(intent, frozenIntent)
        XCTAssertEqual(completion.outcomes.map(\.item.hitID), [oldHit.id])
        XCTAssertEqual(completion.outcomes.map(\.item.args), frozenIntent.items.map(\.args))
        XCTAssertEqual(vm.cardHits[card.id], [newHit],
                       "旧操作成功只移除旧 hitID，不得覆盖新扫描 row")
        XCTAssertEqual(vm.selected, [newHit.id])
    }

    func test_managedUninstall_不可卸载hit不可选_强制注入也会被深层预检阻断() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let card = makeManagedCard(
            id: "card.managed.read-only",
            kind: .simulatorRuntime
        )
        let hit = makeManagedHit(
            path: "/simulator/legacy-runtime",
            displayName: "Legacy Runtime",
            identifier: nil,
            sizeBytes: 8_000
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])

        XCTAssertFalse(vm.canSelect(card: card, hit: hit),
                       "legacy/deletable=false runtime 没有 UUID，UI 必须禁止选择")

        vm.setTestSelection([hit.id])
        await vm.requestSimulatorUninstall()

        guard case let .blocked(_, reason) = vm.simulatorUninstallState else {
            return XCTFail("即使测试强制注入选择，深层 prepare 也必须 fail closed")
        }
        XCTAssertEqual(reason, .invalidSelection)
        XCTAssertEqual(vm.cardHits[card.id], [hit])
        XCTAssertEqual(vm.selected, [hit.id])
    }

    func test_managedUninstall_review期间Simulator启动_执行前revalidate阻断() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let running = LockedFlag(false)
        let card = makeManagedCard(id: "card.managed.running")
        let hit = makeManagedHit(
            path: "/simulator/running",
            displayName: "Running Simulator",
            identifier: "11111111-2222-3333-4444-555555555555"
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(
                    allowlist: [],
                    terminalWaitPolicy: .waitUntilExit,
                    dryRun: false
                ),
                isSimulatorRunning: { running.read() }
            )
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 31))

        await vm.requestSimulatorUninstall()
        guard case .review = vm.simulatorUninstallState else {
            return XCTFail("Simulator 未运行时应允许 review")
        }
        running.set(true)
        await vm.executeSimulatorUninstall()

        guard case let .blocked(_, reason) = vm.simulatorUninstallState else {
            return XCTFail("执行前发现 Simulator 启动必须进入 blocked")
        }
        XCTAssertEqual(reason, .simulatorRunning(names: [hit.displayName]))
        XCTAssertEqual(vm.selected, [hit.id])
        XCTAssertEqual(vm.cardHits[card.id], [hit])
        XCTAssertFalse(vm.isDeleting)
    }

    func test_managedUninstall_review意图过期_执行前staleBlocked且零提交() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let card = makeManagedCard(id: "card.managed.stale")
        let hit = makeManagedHit(
            path: "/simulator/stale",
            displayName: "Stale Simulator",
            identifier: "11111111-2222-3333-4444-555555555555"
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(
                    allowlist: [],
                    terminalWaitPolicy: .waitUntilExit,
                    dryRun: false
                ),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 41))

        await vm.requestSimulatorUninstall()
        guard case .review = vm.simulatorUninstallState else {
            return XCTFail("应先生成与 revision 41 绑定的 review intent")
        }
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 42))
        await vm.executeSimulatorUninstall()

        guard case let .blocked(_, reason) = vm.simulatorUninstallState else {
            return XCTFail("旧 review 不得跨扫描 revision 提交")
        }
        XCTAssertEqual(reason, .staleSnapshot)
        XCTAssertEqual(vm.selected, [hit.id])
        XCTAssertEqual(vm.cardHits[card.id], [hit])
        XCTAssertFalse(vm.isDeleting)
    }

    func test_scanRevision变化后_旧intent不能执行() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let card = makeFilesystemCard(id: "card.cache")
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/old/cache"),
            sizeBytes: 10,
            displayName: "cache",
            note: nil
        )
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 3))
        let pipeline = StubDeletionPipeline()
        let intent = try await confirmedIntent(from: vm, pipeline: pipeline)
        vm.setTestScanEvidence(WorkflowScanEvidence(revision: 4))

        await vm.performDelete(pipeline: pipeline, intent: intent)

        XCTAssertTrue(pipeline.movedPathsReceived.isEmpty)
    }

    /// **P0-1**：performDelete 必须把 accessDenied 注入 pipeline，写 UndoHistory，
    /// 且**仅成功的 originalPath 反查 hit.id** 调 `selected.remove`（而不是把请求的全部 fsPaths
    /// 一并移出 selected）。这是 review 指出的核心契约：用 success 而非 request 来收敛 selected。
    ///
    /// 实现细节：performDelete 末尾会 `await refreshAll()`，refreshAll 会 `selected.removeAll()` +
    /// 重扫 cards——所以最终 selected 一定为空。本测试关注的是 review 指出的契约——
    /// **accessDenied 注入 + UndoHistory 只写真删的 pair**——这两点不依赖 refreshAll。
    func test_P0_1_performDelete_注入accessDenied_UndoHistory只写真删项() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let (undo, undoURL) = try makeUndoStore()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: undoURL)) }

        // 三个 hit：success / failed / safetyRejected 各一
        let hitOK = WorkflowScanHit(url: URL(fileURLWithPath: "/A/ok"),
                                    sizeBytes: 100, displayName: "ok", note: nil)
        let hitFail = WorkflowScanHit(url: URL(fileURLWithPath: "/A/fail"),
                                      sizeBytes: 100, displayName: "fail", note: nil)
        let hitReject = WorkflowScanHit(url: URL(fileURLWithPath: "/A/reject"),
                                        sizeBytes: 100, displayName: "reject", note: nil)
        let card = makeFilesystemCard(id: "card.test")

        let denied: Set<String> = ["/Forbidden/secret"]
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(), home: home,
            undoHistoryStore: undo
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hitOK, hitFail, hitReject]])
        vm.setTestSelection([hitOK.id, hitFail.id, hitReject.id])
        vm.setTestScanEvidence(WorkflowScanEvidence(
            revision: 11,
            permissionDeniedPaths: denied
        ))

        let pipe = StubDeletionPipeline()
        pipe.stubOutcome = TrashOutcome(
            movedPairs: [("/A/ok", "/Trash/ok")],
            failedPaths: ["/A/fail"],
            safetyRejected: [("/A/reject", "accessDenied")],
            missingPaths: [],
            failureReasons: ["/A/fail": "The item is in use."]
        )

        let intent = try await confirmedIntent(from: vm, pipeline: pipe)
        await vm.performDelete(pipeline: pipe, intent: intent)

        // ① accessDenied 注入到 pipeline——必须在 moveToTrash 之前调到
        XCTAssertEqual(pipe.deniedReceived, denied,
                       "performDelete 必须把 intent 冻结的 Workflow 扫描证据传给删除 pipeline")
        // ② pipeline 收到全部 3 条 fs path
        XCTAssertEqual(Set(pipe.movedPathsReceived), Set(["/A/ok", "/A/fail", "/A/reject"]))
        // ③ UndoHistory 仅写成功的 1 条 pair——不能把 fail/reject 也算进恢复链
        XCTAssertEqual(undo.history.count, 1, "performDelete 成功才写 UndoHistory，且只写真删的 pair")
        XCTAssertEqual(undo.history.first?.source, "workflow")
        XCTAssertEqual(undo.history.first?.filePairs.count, 1,
                       "filePairs 必须等于 outcome.movedPairs，不能把 failedPaths/safetyRejected 算进去")
        XCTAssertEqual(undo.history.first?.filePairs.first?.original, "/A/ok")
        XCTAssertEqual(vm.lastDeleteResult?.failureReasons["/A/fail"], "The item is in use.",
                       "开发者工作流重组结果 payload 时不能丢失逐路径 recycle 原因")
    }

    /// **P0-1**：performDelete 全部失败时绝不写 UndoHistory（避免出现"没真删却能恢复"的鬼记录）。
    func test_P0_1_performDelete_全部失败_不写UndoHistory() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let (undo, undoURL) = try makeUndoStore()
        defer {
            // 本用例验证“全失败不写 Undo”，因此存储文件本来就可能从未创建。
            if FileManager.default.fileExists(atPath: undoURL.path) {
                XCTAssertNoThrow(try FileManager.default.removeItem(at: undoURL))
            }
        }

        let hit = WorkflowScanHit(url: URL(fileURLWithPath: "/A/x"),
                                  sizeBytes: 0, displayName: "x", note: nil)
        let card = makeFilesystemCard(id: "card.test")
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(), home: home,
            undoHistoryStore: undo
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])

        let pipe = StubDeletionPipeline()
        pipe.stubOutcome = TrashOutcome(movedPairs: [],
                                        failedPaths: ["/A/x"],
                                        safetyRejected: [], missingPaths: [])

        let intent = try await confirmedIntent(from: vm, pipeline: pipe)
        await vm.performDelete(pipeline: pipe, intent: intent)
        XCTAssertEqual(undo.history.count, 0, "全失败不应写 UndoHistory")
    }

    func test_P0_1_performDelete_父子路径只提交父路径() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let (undo, undoURL) = try makeUndoStore()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: undoURL)) }

        let parent = WorkflowScanHit(url: URL(fileURLWithPath: "/A"),
                                     sizeBytes: 300, displayName: "A", note: nil)
        let child = WorkflowScanHit(url: URL(fileURLWithPath: "/A/build"),
                                    sizeBytes: 100, displayName: "build", note: nil)
        let sibling = WorkflowScanHit(url: URL(fileURLWithPath: "/B/cache"),
                                      sizeBytes: 200, displayName: "cache", note: nil)
        let card = makeFilesystemCard(id: "card.test")
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(), home: home,
            undoHistoryStore: undo
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [parent, child, sibling]])
        vm.setTestSelection([parent.id, child.id, sibling.id])

        let pipe = StubDeletionPipeline()
        pipe.stubOutcome = TrashOutcome(
            movedPairs: [("/A", "/Trash/A"), ("/B/cache", "/Trash/cache")],
            failedPaths: [], safetyRejected: [], missingPaths: []
        )

        let intent = try await confirmedIntent(from: vm, pipeline: pipe)
        await vm.performDelete(pipeline: pipe, intent: intent)

        XCTAssertEqual(pipe.movedPathsReceived, ["/A", "/B/cache"])
        XCTAssertEqual(undo.history.first?.filePairs.map(\.original), ["/A", "/B/cache"])
    }

    func test_totalSelectedBytes_同路径跨卡只统计一次() {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let hit1 = WorkflowScanHit(url: URL(fileURLWithPath: "/A/cache"),
                                   sizeBytes: 100, displayName: "cache", note: nil)
        let hit2 = WorkflowScanHit(url: URL(fileURLWithPath: "/A/cache"),
                                   sizeBytes: 100, displayName: "cache duplicate", note: nil)
        let card1 = makeFilesystemCard(id: "card.one")
        let card2 = makeFilesystemCard(id: "card.two")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card1, card2])
        vm.setTestHits([card1.id: [hit1], card2.id: [hit2]])
        vm.setTestSelection([hit1.id])

        XCTAssertEqual(vm.totalSelectedBytes, 100,
                       "同一路径被多张 filesystem card 命中时，footer 总量不能重复计数")
    }

    func test_cardCapacityState_区分empty_known_partial_allUnknown_failed() {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let card = makeFilesystemCard(id: "card.capacity.contract")
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])

        vm.setTestHits([card.id: []])
        XCTAssertEqual(vm.cardCapacityState(for: card.id), .empty)

        let known = WorkflowScanHit(
            url: URL(fileURLWithPath: "/known"),
            sizeBytes: 2_048,
            displayName: "known",
            note: nil
        )
        let unknown = WorkflowScanHit(
            url: URL(fileURLWithPath: "/unknown"),
            sizeBytes: nil,
            displayName: "unknown",
            note: nil
        )
        vm.setTestHits([card.id: [known]])
        XCTAssertEqual(vm.cardCapacityState(for: card.id), .known(bytes: 2_048))

        vm.setTestHits([card.id: [known, unknown]])
        XCTAssertEqual(vm.cardCapacityState(for: card.id), .partialUnknown(knownBytes: 2_048))

        vm.setTestHits([card.id: [unknown]])
        XCTAssertEqual(vm.cardCapacityState(for: card.id), .allUnknown)

        vm.setTestHits([card.id: []])
        vm.setTestCardIncompleteIssues([
            card.id: [ScanIncompleteIssue(path: "/usr/bin/xcrun", reason: .enumerationFailed)],
        ])
        XCTAssertEqual(vm.cardCapacityState(for: card.id), .failed)
    }

    func test_footer_选中未知大小时不再显示0KB_且中英文实时投影() {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let card = makeFilesystemCard(id: "card.footer.unknown")
        let hit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/unknown"),
            sizeBytes: nil,
            displayName: "unknown",
            note: nil
        )
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.setTestSelection([hit.id])

        XCTAssertEqual(vm.selectionCapacityState, .allUnknown(itemCount: 1))
        let en = vm.selectionSummary(locale: Locale(identifier: "en"))
        let zh = vm.selectionSummary(locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(en.contains("Size unknown"), "actual=\(en)")
        XCTAssertTrue(zh.contains("大小未知"), "actual=\(zh)")
        XCTAssertFalse(en.contains("0 KB"))
        XCTAssertFalse(zh.contains("0 KB"))
    }

    func test_simctlSemanticNote_状态不泄露rawEnglish并随locale切换() {
        let device = WorkflowScanHit(
            url: URL(fileURLWithPath: "/device"),
            sizeBytes: nil,
            displayName: "iPhone",
            note: nil,
            semanticNote: .simulatorDevice(
                state: .shutdown,
                runtimeIdentifier: "runtime-id"
            )
        )
        let unavailable = WorkflowScanHit(
            url: URL(fileURLWithPath: "/runtime"),
            sizeBytes: nil,
            displayName: "iOS",
            note: nil,
            semanticNote: .simulatorRuntime(
                runtimeIdentifier: "runtime-id",
                isAvailable: false,
                management: .legacyReadOnly
            )
        )

        let enDevice = WorkflowHitNotePresentation.string(device, locale: Locale(identifier: "en"))
        let zhDevice = WorkflowHitNotePresentation.string(device, locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(enDevice, "Shut Down · runtime-id")
        XCTAssertEqual(zhDevice, "已关机 · runtime-id")
        XCTAssertFalse(zhDevice?.contains("Shutdown") == true)
        XCTAssertEqual(
            WorkflowHitNotePresentation.string(unavailable, locale: Locale(identifier: "zh-Hans")),
            "runtime-id · 当前不可用 · 旧版 Xcode 只读结果，请在 Xcode 中管理"
        )
    }

    func test_默认managedExecutor_等待系统事务自然终态而非固定timeout() {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let vm = WorkflowDetailViewModel(workflow: AppleWorkflow(), home: home)
        XCTAssertEqual(vm.testingSimulatorTerminalWaitPolicy, .waitUntilExit)
    }

    // MARK: - v2026.06.22 (P0-5) expandGlob

    /// **P0-5**：`.literal` 路径含 `*` 时必须用 fnmatch 末段展开命中。
    /// 现有 Android / WebNode workflow 卡声明的 glob 全是末段形态（`IntelliJIdea*`）。
    func test_P0_5_expandGlob_末段星号_命中匹配项_忽略不匹配() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpandGlob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

        let names = ["IntelliJIdea2024.1", "IntelliJIdea2024.2", "PyCharm2024.1", "README"]
        for n in names {
            try Data().write(to: tmp.appendingPathComponent(n))
        }

        let pattern = tmp.appendingPathComponent("IntelliJIdea*").path
        let matched = Set(WorkflowDetailViewModel._testing_expandGlob(pattern))
        let expect = Set(["IntelliJIdea2024.1", "IntelliJIdea2024.2"]
            .map { tmp.appendingPathComponent($0).path })
        XCTAssertEqual(matched, expect,
                       "fnmatch 应只命中末段匹配的两条，实际:\n\(matched)\n期望:\n\(expect)")
    }

    /// **P0-5**：不含 `*` 时退化为单条 fileExists 判断——与历史行为完全等价。
    func test_P0_5_expandGlob_无星号_退化为单条fileExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpandGlob-Lit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }

        let exists = tmp.appendingPathComponent("here.txt")
        try Data().write(to: exists)
        let missing = tmp.appendingPathComponent("nope.txt")

        XCTAssertEqual(WorkflowDetailViewModel._testing_expandGlob(exists.path), [exists.path])
        XCTAssertEqual(WorkflowDetailViewModel._testing_expandGlob(missing.path), [])
    }

    /// **P0-5**：parent 目录不存在时返回空，绝不抛错。
    func test_P0_5_expandGlob_parent不存在_返回空不崩() {
        let bad = "/no/such/parent/dir/Foo*"
        XCTAssertEqual(WorkflowDetailViewModel._testing_expandGlob(bad), [])
    }
}
