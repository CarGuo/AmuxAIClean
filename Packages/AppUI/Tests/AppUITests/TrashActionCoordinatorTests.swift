import XCTest
@testable import AppUI

@MainActor
final class TrashActionCoordinatorTests: XCTestCase {

    private final class StubPipeline: DeletionPipeline, @unchecked Sendable {
        var deniedReceived: Set<String> = []
        var normalCalls: [(paths: [String], dryRun: Bool)] = []
        var forceCalls: [(paths: [String], dryRun: Bool)] = []

        var normalReturn: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
            = ((0, 0, nil, []), nil)
        var forceReturn: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
            = ((0, 0, nil, []), nil)

        func setAccessDeniedPaths(_ paths: Set<String>) {
            deniedReceived = paths
        }

        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            normalCalls.append((paths, dryRun))
            return normalReturn.legacy
        }

        func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            normalCalls.append((paths, dryRun))
            return normalReturn
        }

        func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
            forceCalls.append((paths, dryRun))
            return forceReturn
        }
    }

    private func makeUndoStore() -> (UndoHistoryStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrashActionCoordinatorTests-\(UUID().uuidString).json")
        return (UndoHistoryStore(storeURL: url, maxHistoryCount: 10), url)
    }

    func test_run_部分成功即使err非空也写Undo并暴露成功路径() async throws {
        let pipe = StubPipeline()
        pipe.normalReturn = (
            legacy: (
                1,
                1,
                "partial failure",
                [("/tmp/moved", "/Users/me/.Trash/moved")]
            ),
            outcome: TrashOutcome(
                movedPairs: [("/tmp/moved", "/Users/me/.Trash/moved")],
                failedPaths: ["/tmp/failed"],
                safetyRejected: [],
                missingPaths: []
            )
        )
        let (undo, undoURL) = makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        let result = await action.run(TrashActionCoordinator.Request(
            paths: ["/tmp/moved", "/tmp/failed"],
            dryRun: false,
            source: "clean",
            accessDeniedPaths: ["/tmp/denied"]
        ))

        XCTAssertEqual(pipe.deniedReceived, ["/tmp/denied"])
        XCTAssertEqual(pipe.normalCalls.count, 1)
        XCTAssertEqual(pipe.normalCalls.first?.paths, ["/tmp/moved", "/tmp/failed"])
        XCTAssertFalse(pipe.normalCalls.first?.dryRun ?? true)
        XCTAssertEqual(result.err, "partial failure")
        XCTAssertEqual(result.succeededPaths, ["/tmp/moved"])
        XCTAssertEqual(undo.history.count, 1,
                       "部分成功时 err 可能非空，但 movedPairs 代表真实进废纸篓的项，必须可恢复")
        XCTAssertEqual(undo.history.first?.source, "clean")
        XCTAssertEqual(undo.history.first?.filePairs.map(\.original), ["/tmp/moved"])
    }

    func test_run_dryRun不写UndoHistory() async throws {
        let pipe = StubPipeline()
        pipe.normalReturn = (
            legacy: (1, 0, nil, [("/tmp/would-move", "/Users/me/.Trash/would-move")]),
            outcome: nil
        )
        let (undo, undoURL) = makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        _ = await action.run(TrashActionCoordinator.Request(
            paths: ["/tmp/would-move"],
            dryRun: true,
            source: "clean",
            accessDeniedPaths: []
        ))

        XCTAssertEqual(undo.history.count, 0,
                       "dryRun 即使 stub 错返 pairs，也不能污染恢复历史")
    }

    func test_run_force模式走moveToTrashForce() async throws {
        let pipe = StubPipeline()
        pipe.forceReturn = (
            legacy: (1, 0, nil, [("/tmp/forced", "/Users/me/.Trash/forced")]),
            outcome: nil
        )
        let (undo, undoURL) = makeUndoStore()
        defer { try? FileManager.default.removeItem(at: undoURL) }

        let action = TrashActionCoordinator(pipeline: pipe, undoHistoryStore: undo)
        let result = await action.run(TrashActionCoordinator.Request(
            paths: ["/tmp/forced"],
            dryRun: false,
            source: "force",
            accessDeniedPaths: [],
            mode: .force
        ))

        XCTAssertEqual(pipe.normalCalls.count, 0)
        XCTAssertEqual(pipe.forceCalls.count, 1)
        XCTAssertEqual(result.succeededPaths, ["/tmp/forced"])
        XCTAssertEqual(undo.history.first?.source, "force")
    }
}
