import Foundation
import ScanKit
import XCTest
@testable import AppUI

@MainActor
final class DuplicateResultsStoreTests: XCTestCase {
    /// Pause each receipt's first projection after it has frozen its source. Retries run freely.
    private actor PruneGate {
        private var started = 0
        private var seen: Set<Set<String>> = []
        private var pending: [Set<String>: CheckedContinuation<Void, Never>] = [:]
        private var waiter: (Int, CheckedContinuation<Void, Never>)?

        func prune(_ groups: [DuplicateGroup], paths: Set<String>) async -> [DuplicateGroup] {
            if seen.insert(paths).inserted {
                await withCheckedContinuation { continuation in
                    pending[paths] = continuation
                    started += 1
                    if let (count, continuation) = waiter, started >= count {
                        waiter = nil
                        continuation.resume()
                    }
                }
            }
            return DuplicateHandlingPlan.pruning(groups, movedPaths: paths)
        }

        func waitForStarted(_ count: Int) async {
            guard started < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }

        func release(_ paths: Set<String>) {
            pending.removeValue(forKey: paths)?.resume()
        }
    }

    private func group(_ key: String, paths: [String]) -> DuplicateGroup {
        DuplicateGroup(
            hashKey: key, logicalBytes: 100,
            files: paths.map { DuplicateFile(path: $0, allocatedBytes: 100) },
            reliability: .full
        )
    }

    func testEmptyScanHasATypedTerminalWithoutLettingOldSessionsReplaceIt() {
        let store = DuplicateResultsStore()
        XCTAssertEqual(store.emptyMessage(hasIncompleteEvidence: false),
                       .catalog("duplicate.placeholder.no_results"))
        let oldSession = UUID()
        store.beginScan(sessionID: oldSession)
        let currentSession = UUID()
        store.beginScan(sessionID: currentSession)
        store.finishScan(.cancelled, sessionID: oldSession)
        XCTAssertEqual(store.scanState, .scanning)
        store.replaceGroups([], sessionID: currentSession)
        store.finishScan(.completed, sessionID: currentSession)
        XCTAssertEqual(store.emptyMessage(hasIncompleteEvidence: false),
                       .catalog("duplicate.placeholder.completed_empty"))
        XCTAssertEqual(store.emptyMessage(hasIncompleteEvidence: true),
                       .catalog("duplicate.placeholder.incomplete_empty"))
        store.finishScan(.cancelled, sessionID: currentSession)
        XCTAssertEqual(store.scanState, .finished(.completed), "a terminal cannot be overwritten")

        store.resetForConfiguration(sessionID: UUID())
        store.replaceGroups([group("late", paths: ["/old/a", "/old/b"])], sessionID: currentSession)
        store.finishScan(.completed, sessionID: currentSession)
        XCTAssertTrue(store.groups.isEmpty, "old inputs must not repopulate the edited scan")
        XCTAssertEqual(store.scanState, .idle)

        for (completion, message) in [
            (DuplicateResultsStore.Completion.cancelled, "duplicate.placeholder.cancelled_empty"),
            (.interrupted, "duplicate.placeholder.interrupted_empty")
        ] {
            let nextSession = UUID()
            store.beginScan(sessionID: nextSession)
            store.finishScan(completion, sessionID: nextSession)
            XCTAssertEqual(store.emptyMessage(hasIncompleteEvidence: false), .catalog(message))
        }
    }

    func testOldDeletionProjectionCannotOverwriteReplacementScanResults() async {
        let gate = PruneGate()
        let store = DuplicateResultsStore { await gate.prune($0, paths: $1) }
        let oldSession = UUID()
        store.beginScan(sessionID: oldSession)
        store.replaceGroups([group("old", paths: ["/old/a", "/old/b", "/old/c"])], sessionID: oldSession)
        let pruning = Task { await store.pruneMovedPaths(["/old/b"], expectedSessionID: oldSession) }
        await gate.waitForStarted(1)

        let newSession = UUID()
        let replacement = group("new", paths: ["/new/a", "/new/b"])
        store.beginScan(sessionID: newSession)
        store.replaceGroups([replacement], sessionID: newSession)
        await gate.release(["/old/b"])

        let committed = await pruning.value
        XCTAssertFalse(committed)
        XCTAssertEqual(store.groups, [replacement])
    }

    func testConcurrentDeletionReceiptsCannotResurrectEachOthersPaths() async {
        let gate = PruneGate()
        let store = DuplicateResultsStore { await gate.prune($0, paths: $1) }
        let session = UUID()
        store.beginScan(sessionID: session)
        store.replaceGroups([group("same", paths: ["/a", "/b", "/c", "/d"])], sessionID: session)
        let first = Task { await store.pruneMovedPaths(["/b"], expectedSessionID: session) }
        let second = Task { await store.pruneMovedPaths(["/c"], expectedSessionID: session) }
        await gate.waitForStarted(2)

        await gate.release(["/b"])
        let firstCommitted = await first.value
        XCTAssertTrue(firstCommitted)
        await gate.release(["/c"])
        let secondCommitted = await second.value
        XCTAssertTrue(secondCommitted)

        XCTAssertEqual(store.groups.first?.paths, ["/a", "/d"])
        XCTAssertEqual(store.groups.first?.totalBytes, 200)
    }
}
