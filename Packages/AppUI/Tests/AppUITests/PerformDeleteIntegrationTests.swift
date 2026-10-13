import XCTest
@testable import AppUI
import SafetyKit

/// Step 15：补 [MainView.performDelete L1473-L1527](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift#L1473-L1527)
/// 4 步联动死角集成测。
///
/// 因 `performDelete` 是 MainView 的 SwiftUI private method，本测复刻它的 4 步顺序：
///   ① pipeline.setAccessDeniedPaths(deniedSet)
///   ② await TrashActionCoordinator.run(...)
///   ③ 非 dryRun 且 movedPairs 非空 → UndoHistoryStore.addRecord(source: "clean", pairs)
///   ④ 非 dryRun 且 movedPairs 非空 → coordinator.pruneDeleted(succeededPaths)
/// 用 FakeDeletionPipeline + 真 [ScanCoordinator](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// + 临时文件 UndoHistoryStore 驱动，断言 4 步全部按规约发生 + dryRun 不写 store / 不 prune /
/// 不写 UndoHistory。
///
/// 决策：AUDIT §3.6 "accessDenied 路径不被 prune" 这条**当前实现没有**——
/// [MainView L1521](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift#L1521)
/// v1.5.7 修复用户截图反馈后，本测锁定新契约：UI 删除状态更新只消费
/// `movedPairs.map(\.original)`，不能再用 `err == nil` 或原始提交 paths 做粗粒度判断。
@MainActor
final class PerformDeleteIntegrationTests: XCTestCase {

    // MARK: - Fakes

    /// 收所有调用记录的假 pipeline。
    final class FakePipeline: DeletionPipeline, @unchecked Sendable {
        var deniedReceived: Set<String> = []
        var movedPathsReceived: [String] = []
        var dryRunReceived: Bool = false
        var returnPairs: [(String, String)] = []
        var returnError: String?

        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            DeletionPreflight(allowedPaths: paths, rejections: [])
        }

        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            movedPathsReceived = paths
            dryRunReceived = dryRun
            return (returnPairs.count, max(0, paths.count - returnPairs.count), returnError, returnPairs)
        }

        func setAccessDeniedPaths(_ paths: Set<String>) {
            deniedReceived = paths
        }
    }

    // MARK: - 工具

    private func makeRow(_ path: String, bytes: Int64 = 100) -> RowItem {
        RowItem(
            id: path, url: URL(fileURLWithPath: path),
            title: (path as NSString).lastPathComponent,
            isDirectory: false, bytes: bytes, logicalBytes: bytes, fileCount: 1,
            verdict: .safe, rejection: .ok
        )
    }

    private func makeUndoStore() throws -> (UndoHistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PDIT-\(UUID().uuidString).json")
        let store = UndoHistoryStore(storeURL: url, maxHistoryCount: 10)
        return (store, url)
    }

    /// 复刻 performDelete 4 步联动到测试上下文。
    ///
    /// - Parameter denied: accessDenied snapshot 注入
    /// - Parameter dryRun: 与 performDelete 同语义
    @discardableResult
    private func runPerformDeleteLike(
        coordinator: ScanCoordinator,
        pipeline: FakePipeline,
        undo: UndoHistoryStore,
        paths: [String],
        denied: Set<String>,
        dryRun: Bool
    ) async -> (moved: Int, skipped: Int, err: String?) {
        let action = TrashActionCoordinator(pipeline: pipeline, undoHistoryStore: undo)
        let result = await action.run(TrashActionCoordinator.Request(
            paths: paths,
            dryRun: dryRun,
            source: "clean",
            accessDeniedPaths: denied
        ))
        if !dryRun, !result.succeededPaths.isEmpty {
            await coordinator.pruneDeleted(paths: result.succeededPaths)
        }
        return (result.moved, result.skipped, result.err)
    }

    // MARK: - 用例 1：4 步全成（!dryRun + 无 error + 非空 pairs）

    func test_performDelete_4步联动全成功() async throws {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t",
                                   rows: [makeRow("/A/x", bytes: 100), makeRow("/A/y", bytes: 200)],
                                   totalBytes: 300, scannedFileCount: 2,
                                   isFinished: true, elapsed: 0)
        )
        let pipe = FakePipeline()
        pipe.returnPairs = [("/A/x", "/Trash/x"), ("/A/y", "/Trash/y")]
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        await runPerformDeleteLike(
            coordinator: coord, pipeline: pipe, undo: undo,
            paths: ["/A/x", "/A/y"],
            denied: ["/Forbidden/secret"],
            dryRun: false
        )

        // ① 注入了 accessDenied
        XCTAssertEqual(pipe.deniedReceived, ["/Forbidden/secret"],
            "accessDenied snapshot 必须传给 pipeline.setAccessDeniedPaths")
        // ② pipeline 收到正确 paths + dryRun=false
        XCTAssertEqual(pipe.movedPathsReceived, ["/A/x", "/A/y"])
        XCTAssertFalse(pipe.dryRunReceived)
        // ③ UndoHistory 写了一条
        XCTAssertEqual(undo.history.count, 1)
        XCTAssertEqual(undo.history.first?.source, "clean")
        XCTAssertEqual(undo.history.first?.filePairs.count, 2)
        // ④ snapshot.rows 被 prune
        XCTAssertTrue(coord.snapshot.rows.isEmpty,
            "performDelete 完成后 pruneDeleted 应清空已删行")
    }

    // MARK: - 用例 2：dryRun 不动 store / 不 prune / 不写 UndoHistory

    func test_performDelete_dryRun只查询不落库不修改() async throws {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t",
                                   rows: [makeRow("/A/x")],
                                   totalBytes: 100, scannedFileCount: 1,
                                   isFinished: true, elapsed: 0)
        )
        let pipe = FakePipeline()
        // dryRun 时 pipeline 通常不返 pairs，但即便返了我们也不应该写 UndoHistory
        pipe.returnPairs = [("/A/x", "/Trash/x")]
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        await runPerformDeleteLike(
            coordinator: coord, pipeline: pipe, undo: undo,
            paths: ["/A/x"], denied: [], dryRun: true
        )

        XCTAssertTrue(pipe.dryRunReceived, "pipeline 必须收到 dryRun=true")
        XCTAssertEqual(undo.history.count, 0,
            "dryRun 路径绝不写 UndoHistory（保守不污染恢复链）")
        XCTAssertEqual(coord.snapshot.rows.count, 1,
            "dryRun 不应触发 pruneDeleted，UI 行仍在")
    }

    // MARK: - 用例 3：部分成功且 err 非空 → 只写/只 prune 真成功项

    func test_performDelete_部分成功但err非空_只Undo和Prune成功项() async throws {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t",
                                   rows: [makeRow("/A/x"), makeRow("/A/y")],
                                   totalBytes: 200, scannedFileCount: 2,
                                   isFinished: true, elapsed: 0)
        )
        let pipe = FakePipeline()
        pipe.returnPairs = [("/A/x", "/Trash/x")]
        pipe.returnError = "partial recycle failed"
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let result = await runPerformDeleteLike(
            coordinator: coord, pipeline: pipe, undo: undo,
            paths: ["/A/x", "/A/y"], denied: [], dryRun: false
        )

        XCTAssertEqual(result.err, "partial recycle failed")
        XCTAssertEqual(undo.history.count, 1,
            "部分成功时 err 非空也必须写入真实 movedPairs，否则用户无法恢复已移动项")
        XCTAssertEqual(undo.history.first?.filePairs.map(\.original), ["/A/x"])
        XCTAssertEqual(coord.snapshot.rows.map(\.id), ["/A/y"],
            "部分成功时只能 prune 真成功项，失败项继续留在 UI 中供重试")
    }

    func test_performDelete_全部失败则不Undo不Prune() async throws {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t",
                                   rows: [makeRow("/A/x")],
                                   totalBytes: 100, scannedFileCount: 1,
                                   isFinished: true, elapsed: 0)
        )
        let pipe = FakePipeline()
        pipe.returnError = "trash recycle failed"
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let result = await runPerformDeleteLike(
            coordinator: coord, pipeline: pipe, undo: undo,
            paths: ["/A/x"], denied: [], dryRun: false
        )

        XCTAssertEqual(result.err, "trash recycle failed")
        XCTAssertEqual(undo.history.count, 0,
            "全部失败时没有 movedPairs，绝不写 UndoHistory")
        XCTAssertEqual(coord.snapshot.rows.map(\.id), ["/A/x"],
            "全部失败时不应 prune，UI 留行让用户重试")
    }

    // MARK: - 用例 4：accessDenied snapshot 必须被注入到 pipeline

    func test_performDelete_accessDenied注入到pipeline() async throws {
        let coord = ScanCoordinator()
        coord._seedForTesting(
            snapshot: ScanSnapshot(categoryID: "t", rows: [makeRow("/A/x")],
                                   totalBytes: 100, scannedFileCount: 1,
                                   isFinished: true, elapsed: 0)
        )
        let pipe = FakePipeline()
        let (undo, undoURL) = try makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let denied: Set<String> = [
            "/System/Volumes/Data/Library",
            "/private/var/db/sudo"
        ]
        await runPerformDeleteLike(
            coordinator: coord, pipeline: pipe, undo: undo,
            paths: ["/A/x"], denied: denied, dryRun: false
        )

        XCTAssertEqual(pipe.deniedReceived, denied,
            "accessDeniedPathsSnapshot 必须先于 moveToTrash 调用 setAccessDeniedPaths")
    }
}
