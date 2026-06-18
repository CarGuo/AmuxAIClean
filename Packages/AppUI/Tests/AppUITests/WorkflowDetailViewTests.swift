import XCTest
import Foundation
import ScanKit
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
        defer { try? FileManager.default.removeItem(at: emptyHome) }

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
        defer { try? FileManager.default.removeItem(at: home) }

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
        defer { try? FileManager.default.removeItem(at: home) }

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

    /// PR-5：MainView sentinel 3 个 ID 不能重名也不能与既有 sentinel 冲突。
    /// 这是 sidebar 的硬约束——重名会让 List(selection:) 高亮串台。
    func test_PR5_sentinel_workflow_三ID_全局唯一_v17() {
        let workflowIDs: Set<String> = MainView.workflowSentinelIDs
        XCTAssertEqual(workflowIDs.count, 3, "workflow sentinel 必须恰好 3 个")

        let allSentinels: [String] = [
            MainView.appFootprintSentinelID,
            MainView.launchAgentSentinelID,
            MainView.uninstallSentinelID,
            MainView.duplicateSentinelID,
            MainView.undoHistorySentinelID,
            MainView.maintenanceSentinelID,
            MainView.lipoSentinelID,
            MainView.brewSentinelID,
            MainView.devVersionedSentinelID,
            MainView.workflowAppleSentinelID,
            MainView.workflowAndroidSentinelID,
            MainView.workflowWebNodeSentinelID,
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
        var stubOutcome: TrashOutcome = TrashOutcome(movedPairs: [], failedPaths: [],
                                                     safetyRejected: [], missingPaths: [])
        var stubLegacyErr: String?

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
    }

    private func makeFilesystemCard(id: String) -> DeveloperCard {
        DeveloperCard(id: id, title: id, summary: "",
                      source: .literal(paths: []),
                      recipe: .filesystem, risk: .safe)
    }

    private func makeUndoStore() throws -> (UndoHistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WFDVT-\(UUID().uuidString).json")
        return (UndoHistoryStore(storeURL: url, maxHistoryCount: 10), url)
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
        defer { try? FileManager.default.removeItem(at: home) }
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

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
            accessDeniedPathsProvider: { denied },
            undoHistoryStore: undo
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hitOK, hitFail, hitReject]])
        vm.selected = [hitOK.id, hitFail.id, hitReject.id]

        let pipe = StubDeletionPipeline()
        pipe.stubOutcome = TrashOutcome(
            movedPairs: [("/A/ok", "/Trash/ok")],
            failedPaths: ["/A/fail"],
            safetyRejected: [("/A/reject", "accessDenied")],
            missingPaths: []
        )

        await vm.performDelete(pipeline: pipe)

        // ① accessDenied 注入到 pipeline——必须在 moveToTrash 之前调到
        XCTAssertEqual(pipe.deniedReceived, denied,
                       "performDelete 必须把 accessDeniedPathsProvider 的值传给 pipeline.setAccessDeniedPaths")
        // ② pipeline 收到全部 3 条 fs path
        XCTAssertEqual(Set(pipe.movedPathsReceived), Set(["/A/ok", "/A/fail", "/A/reject"]))
        // ③ UndoHistory 仅写成功的 1 条 pair——不能把 fail/reject 也算进恢复链
        XCTAssertEqual(undo.history.count, 1, "performDelete 成功才写 UndoHistory，且只写真删的 pair")
        XCTAssertEqual(undo.history.first?.source, "workflow")
        XCTAssertEqual(undo.history.first?.filePairs.count, 1,
                       "filePairs 必须等于 outcome.movedPairs，不能把 failedPaths/safetyRejected 算进去")
        XCTAssertEqual(undo.history.first?.filePairs.first?.original, "/A/ok")
    }

    /// **P0-1**：performDelete 全部失败时绝不写 UndoHistory（避免出现"没真删却能恢复"的鬼记录）。
    func test_P0_1_performDelete_全部失败_不写UndoHistory() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let hit = WorkflowScanHit(url: URL(fileURLWithPath: "/A/x"),
                                  sizeBytes: 0, displayName: "x", note: nil)
        let card = makeFilesystemCard(id: "card.test")
        let vm = WorkflowDetailViewModel(
            workflow: AppleWorkflow(), home: home,
            accessDeniedPathsProvider: { [] },
            undoHistoryStore: undo
        )
        vm.setTestCards([card])
        vm.setTestHits([card.id: [hit]])
        vm.selected = [hit.id]

        let pipe = StubDeletionPipeline()
        pipe.stubOutcome = TrashOutcome(movedPairs: [],
                                        failedPaths: ["/A/x"],
                                        safetyRejected: [], missingPaths: [])

        await vm.performDelete(pipeline: pipe)
        XCTAssertEqual(undo.history.count, 0, "全失败不应写 UndoHistory")
    }

    // MARK: - v2026.06.22 (P0-5) expandGlob

    /// **P0-5**：`.literal` 路径含 `*` 时必须用 fnmatch 末段展开命中。
    /// 现有 Android / WebNode workflow 卡声明的 glob 全是末段形态（`IntelliJIdea*`）。
    func test_P0_5_expandGlob_末段星号_命中匹配项_忽略不匹配() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpandGlob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

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
        defer { try? FileManager.default.removeItem(at: tmp) }

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
