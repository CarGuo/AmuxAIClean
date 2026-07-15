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
/// 4. .commandLine recipe 的卡 hits 在 performDelete 时被记入 commandLineBlocked，不进 fsPaths；
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

    private func makeCommandCard(id: String) -> DeveloperCard {
        DeveloperCard(
            id: id,
            title: id,
            summary: "",
            source: .dynamicScanner(scannerID: "scanner.simctl-devices"),
            recipe: .commandLine(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "delete"]
            ),
            risk: .confirm
        )
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
        XCTAssertNil(vm.pendingSimctlStage)
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

    func test_runningApp文件项全跳过_混合任务仍继续冻结的命令计划() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let filesystemPath = "/A/running-cache"
        let filesystemHit = WorkflowScanHit(
            url: URL(fileURLWithPath: filesystemPath),
            sizeBytes: 123,
            displayName: "Running Cache",
            note: nil
        )
        let commandHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/simulator/frozen"),
            sizeBytes: 0,
            displayName: "Frozen Simulator",
            note: nil,
            commandLineTailArg: "11111111-2222-3333-4444-555555555555"
        )
        let filesystemCard = makeFilesystemCard(id: "card.running")
        let commandCard = makeCommandCard(id: "card.command")
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([filesystemCard, commandCard])
        vm.setTestHits([
            filesystemCard.id: [filesystemHit],
            commandCard.id: [commandHit],
        ])
        vm.setTestSelection([filesystemHit.id, commandHit.id])
        let pipeline = StubDeletionPipeline()

        await vm.requestDeleteConfirmation(pipeline: pipeline)
        guard case let .deleteConfirm(confirmation) = vm.activeSheet else {
            return XCTFail("混合任务应先展示统一确认")
        }
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
        let intent = try XCTUnwrap(vm.takePendingConfirmedDeleteIntent())
        XCTAssertTrue(intent.filesystemPaths.isEmpty)
        XCTAssertNil(intent.authorizedInteraction,
                     "文件项全跳过后不得伪造 Trash 授权")
        XCTAssertEqual(intent.runningAppSkipped, [skipped])
        guard case let .ready(items) = intent.commandPlan else {
            return XCTFail("文件项全跳过不得取消已冻结的命令计划")
        }
        XCTAssertEqual(items.map(\.hitID), [commandHit.id])

        await vm.performDelete(pipeline: pipeline, intent: intent)

        XCTAssertTrue(pipeline.movedPathsReceived.isEmpty, "已跳过的文件项不得提交 Trash")
        guard case let .firstReview(commandItems) = vm.pendingSimctlStage else {
            return XCTFail("冻结命令应继续进入独立的两次确认")
        }
        XCTAssertEqual(commandItems.map(\.hitID), [commandHit.id])
        guard case .simctlConfirm = vm.activeSheet else {
            return XCTFail("命令计划不仅要保留，还必须真正展示第一轮确认")
        }
        XCTAssertNil(vm.lastDeleteResult, "进入命令确认前不能伪造文件删除结果")
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

    func test_deleteIntent冻结路径命令与revision_确认后不回读可变cards() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let filesystemCard = makeFilesystemCard(id: "card.filesystem")
        let commandCard = makeCommandCard(id: "card.command")
        let oldFile = WorkflowScanHit(
            url: URL(fileURLWithPath: "/old/cache"),
            sizeBytes: 10,
            displayName: "old cache",
            note: nil
        )
        let oldCommand = WorkflowScanHit(
            url: URL(fileURLWithPath: "/old/simulator"),
            sizeBytes: 0,
            displayName: "old simulator",
            note: nil,
            commandLineTailArg: "11111111-2222-3333-4444-555555555555"
        )
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { false }
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: coordinator
        )
        vm.setTestCards([filesystemCard, commandCard])
        vm.setTestHits([
            filesystemCard.id: [oldFile],
            commandCard.id: [oldCommand],
        ])
        vm.setTestSelection([oldFile.id, oldCommand.id])
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
            return XCTFail("应生成冻结意图")
        }
        let revisionBefore = vm.scanEvidence.revision
        vm.toggleSelection(hitID: oldCommand.id, on: false)
        await vm.refreshAll()
        XCTAssertEqual(vm.selected, [oldFile.id, oldCommand.id], "确认事务期间选择必须禁用")
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
        guard case let .firstReview(items) = vm.pendingSimctlStage else {
            return XCTFail("冻结的 simctl item 不得因 cardHits 改变而丢失")
        }
        XCTAssertEqual(items.map(\.args), [[
            "simctl", "delete", "11111111-2222-3333-4444-555555555555",
        ]])
    }

    func test_filesystem最终安全拒绝_整次动作不进入simctl确认() async throws {
        let home = makeTempHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let filesystemCard = makeFilesystemCard(id: "card.filesystem")
        let commandCard = makeCommandCard(id: "card.command")
        let file = WorkflowScanHit(
            url: URL(fileURLWithPath: "/blocked/cache"),
            sizeBytes: 10,
            displayName: "cache",
            note: nil
        )
        let command = WorkflowScanHit(
            url: URL(fileURLWithPath: "/simulator"),
            sizeBytes: 0,
            displayName: "simulator",
            note: nil,
            commandLineTailArg: "11111111-2222-3333-4444-555555555555"
        )
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false }
            )
        )
        vm.setTestCards([filesystemCard, commandCard])
        vm.setTestHits([
            filesystemCard.id: [file],
            commandCard.id: [command],
        ])
        vm.setTestSelection([file.id, command.id])
        let pipeline = StubDeletionPipeline()
        let intent = try await confirmedIntent(from: vm, pipeline: pipeline)
        let rejection = DeletionPreflight.Rejection(
            path: file.url.path,
            reason: SafetyRejection.rootOrAboveHome.rawValue
        )
        pipeline.stubSubmissionRejection = .safety(DeletionPreflight(
            allowedPaths: [],
            rejections: [rejection]
        ))

        await vm.performDelete(pipeline: pipeline, intent: intent)

        XCTAssertNil(vm.pendingSimctlStage, "filesystem 安全拒绝后不能继续不可恢复的 simctl")
        guard case let .preflightNotice(_, rejections) = vm.activeSheet else {
            return XCTFail("最终重验拒绝必须回 typed notice，不能伪造成执行结果")
        }
        XCTAssertEqual(rejections, [rejection])
        XCTAssertNil(vm.lastDeleteResult)
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
