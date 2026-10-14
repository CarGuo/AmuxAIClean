import Foundation
import Darwin
import XCTest
@testable import AppUI

/// Opt-in integration evidence: the real confirmation coordinator, NSWorkspace recycle,
/// durable callback journal, Undo commit and subsequent request all participate. Only UUID
/// fixture files created below NSTemporaryDirectory are moved, then restored through Undo.
@MainActor
final class ConfirmedRecycleIntegrationTests: XCTestCase {
    func testConsecutiveConfirmedRequestsPersistUndoAndRestoreOwnFixtures() async throws {
        guard ProcessInfo.processInfo.environment["AMUXCLEAN_TEST_REAL_RECYCLE"] == "1" else {
            throw XCTSkip("Set AMUXCLEAN_TEST_REAL_RECYCLE=1 to recycle only generated temporary fixtures")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfirmedRecycle-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("state/UndoHistory.json")
        // Match the pipeline's frozen Darwin temporary scope, not the narrower fixture folder.
        // Restore requires the original scope root itself to remain authorized.
        let store = UndoHistoryStore(storeURL: historyURL)
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: root.appendingPathComponent("state/pending.json"),
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let journal = PersistentTrashCompletionJournal(fileURL: root.appendingPathComponent("state/completion.json"))
        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: ledger, completionJournal: journal, undoHistoryStore: store
        )
        let pipeline = TrashPipeline(recoveryDependencyDomain: domain)
        let coordinator = DeletionInteractionCoordinator(pipeline: pipeline, undoHistoryStore: store)
        let requests: [(DeleteRequestOrigin, String)] = [(.tree, "example.apk"), (.stash, "example.pkg")]
        var fixtures: [(URL, Data)] = []
        for (index, request) in requests.enumerated() {
            let target = root.appendingPathComponent(request.1)
            let data = Data("Generated recycle fixture \(index)".utf8)
            try data.write(to: target)
            fixtures.append((target, data))
            let revision = DeletionSnapshotIdentity(sessionID: UUID(), revision: 1)
            let intent = try coordinator.makeIntent(
                origin: request.0, mode: .professional, snapshotIdentity: revision,
                candidates: [.init(path: target.path, title: request.1, isDirectory: false,
                                   bytes: Int64(data.count), fileCount: 1)]
            )
            guard case .confirmation(let prepared) = await coordinator.prepare(
                intent: intent, currentSnapshotIdentity: revision
            ), case .authorized(let authorized) = coordinator.authorize(
                prepared: prepared, executionPlan: .init(paths: [target.path], runningAppSkipped: [])
            ) else { return XCTFail("Fixture must reach confirmed authorization") }
            guard case .completed(let completed) = await coordinator.submit(authorized, accessDeniedPaths: []) else {
                return XCTFail("Consecutive confirmed fixture request failed to reach a real completion")
            }
            XCTAssertEqual(completed.receipt.submittedPaths, [target.path])
            XCTAssertEqual(completed.result.moved, 1)
            XCTAssertEqual(completed.result.skipped, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(store.storageState, .ready)
            XCTAssertEqual(store.completionJournalState, .ready)
            XCTAssertEqual(journal.pendingEntries(), [])
            let persistedCount = UndoHistoryStore(storeURL: historyURL).history.count
            XCTAssertEqual(persistedCount, index + 1)
            guard completed.receipt.submittedPaths == [target.path],
                  completed.result.moved == 1, completed.result.skipped == 0,
                  !FileManager.default.fileExists(atPath: target.path),
                  store.storageState == .ready, store.completionJournalState == .ready,
                  journal.pendingEntries() == [], persistedCount == index + 1 else {
                // Preserve the fixture domain and exact Undo paths if any preceding assertion
                // failed; do not print a successful integration summary or remove its evidence.
                return
            }
        }
        for record in store.history {
            let restored = await store.restoreRecord(record, conflictPolicy: .skipExisting,
                                                     locale: Locale(identifier: "en"))
            guard restored.restoredCount == 1, restored.firstFailure == nil else {
                let probes = record.filePairs.map { pair in
                    let parent = URL(fileURLWithPath: pair.trashed).deletingLastPathComponent().path
                    let descriptor = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    let openError = descriptor >= 0 ? 0 : errno
                    if descriptor >= 0 { Darwin.close(descriptor) }
                    return "\(pair.trashed): \(TrashObjectIdentity.probe(path: pair.trashed)); parentOpenErrno=\(openError)"
                }
                return XCTFail("Fixture restore failed; preserve domain at \(root.path): \(String(describing: restored.firstFailure)); probes=\(probes)")
            }
        }
        for (target, expected) in fixtures {
            guard try Data(contentsOf: target) == expected else {
                return XCTFail("Restored fixture differs; preserve domain at \(root.path)")
            }
        }
        print("Confirmed recycle integration: 2 real receipts, 2 durable Undo records, 2 restored fixtures; domain=\(root.path)")
        // Every original fixture has been restored and verified; only this generated temp tree remains.
        try FileManager.default.removeItem(at: root)
    }
}
