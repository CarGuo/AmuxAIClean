import Darwin
import Foundation
import XCTest
@testable import AppUI

/// v2026.10.14 deletion-blocker audit: durable history is part of the submission domain.
/// These fixtures exercise that boundary without starting an App or calling recycle. A callback
/// journal fixture represents an already-completed move; all of its paths remain temporary.
@MainActor
final class PersistenceReadinessRegressionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let target: URL
        let historyURL: URL
        let journal: PersistentTrashCompletionJournal
        let ledger: PersistentTrashPendingOperationLedger
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceReadinessRegressionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("unrelated-request.txt")
        try Data("unchanged".utf8).write(to: target)
        addTeardownBlock {
            // Only this test-owned temporary persistence domain is removed.
            try FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            target: target,
            historyURL: root.appendingPathComponent("UndoHistory.json"),
            journal: PersistentTrashCompletionJournal(
                fileURL: root.appendingPathComponent("completion.json")
            ),
            ledger: PersistentTrashPendingOperationLedger(
                fileURL: root.appendingPathComponent("pending.json"),
                activeOperationRegistry: TrashActiveOperationRegistry()
            )
        )
    }

    func testEmptyJournalDoesNotAuthorizeTrashWithAlreadyCorruptUndoHistory() async throws {
        let fixture = try makeFixture()
        try Data("not-json".utf8).write(to: fixture.historyURL)
        let store = UndoHistoryStore(
            storeURL: fixture.historyURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        XCTAssertEqual(store.storageState, .corrupt)
        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: fixture.ledger,
            completionJournal: fixture.journal,
            undoHistoryStore: store
        )
        let operationID = UUID()

        let reservation = await TrashPipeline.reserveAfterRecovery(
            paths: [fixture.target.path],
            operationID: operationID,
            reviewIdentity: nil,
            recoveryDependencyDomain: domain
        )

        XCTAssertEqual(
            reservation, .recoveryBlocked,
            "An empty callback journal cannot prove that already-corrupt Undo storage can accept the next move"
        )
        // The unfixed implementation reserves the target. Release that test-only reservation
        // even when the assertion fails, so no live registry owner escapes this fixture.
        if case .ledger(.reserved) = reservation {
            XCTAssertTrue(fixture.ledger.finish(
                operationID: operationID, retainingPendingPaths: []
            ))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.target), Data("unchanged".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), Data("not-json".utf8))
    }

    func testValidCompletedBatchBelowItemLimitCanSettleAndUnblockNextRequest() async throws {
        let fixture = try makeFixture()
        let store = UndoHistoryStore(
            storeURL: fixture.historyURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let entryCount = 8_000
        XCTAssertLessThan(entryCount, UndoHistoryStore.maximumPairsPerRecord)
        let root = fixture.root
        let entries = await Task.detached(priority: .utility) {
            let operationID = UUID()
            let attemptID = UUID()
            // Each component and complete pathname is legal on the supported local filesystem.
            // The batch is within both existing item limits and the journal's byte limit, while
            // its complete history fact exceeds the unrelated 8 MiB aggregate Undo limit.
            let originalRoot = (0..<5).reduce(root.appendingPathComponent("original")) {
                $0.appendingPathComponent("level-\($1)-" + String(repeating: "a", count: 64))
            }
            let trashedRoot = root.appendingPathComponent("trash")
            return (0..<entryCount).map { index in
                let filename = "item-\(index)-" + String(repeating: "b", count: 180)
                return TrashUndoJournalEntry(
                    operationID: operationID,
                    attemptID: attemptID,
                    originalPath: originalRoot.appendingPathComponent(filename).path,
                    trashedPath: trashedRoot.appendingPathComponent(filename).path,
                    originalIdentity: TrashObjectIdentity(
                        device: 1, inode: UInt64(index + 1), fileType: UInt16(S_IFREG),
                        birthTimeSeconds: 100, birthTimeNanoseconds: 0, generation: 0
                    ),
                    restoreScopeRoot: root.path,
                    recordedAt: Date(timeIntervalSince1970: 100)
                )
            }
        }.value
        let journal = fixture.journal
        let appended = await Task.detached(priority: .utility) {
            journal.append(entries)
        }.value
        XCTAssertTrue(appended, "The existing durable callback journal accepts this valid batch")

        let terminal = await TrashPipeline.recoverDurableTrashState(
            journal: fixture.journal, ledger: fixture.ledger, undoHistoryStore: store
        )

        XCTAssertEqual(
            terminal, .ready,
            "Already-completed valid callbacks must settle instead of permanently blocking every later deletion; historyState=\(store.storageState)"
        )
        XCTAssertEqual(
            store.history.reduce(0) { $0 + $1.filePairs.count }, entryCount,
            "Settling a completed batch must preserve its full history fact"
        )
        XCTAssertEqual(fixture.journal.pendingEntries()?.count, 0)
        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: fixture.ledger,
            completionJournal: fixture.journal,
            undoHistoryStore: store
        )
        let operationID = UUID()
        let reservation = await TrashPipeline.reserveAfterRecovery(
            paths: [fixture.target.path], operationID: operationID,
            reviewIdentity: nil, recoveryDependencyDomain: domain
        )
        if case .ledger(.reserved) = reservation {
            XCTAssertTrue(fixture.ledger.finish(
                operationID: operationID, retainingPendingPaths: []
            ))
        } else {
            XCTFail("A valid completed batch must not permanently reject an unrelated next request")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.target), Data("unchanged".utf8))
    }

    func testCompletedBatchesInOneOperationCanExceedLegacyPairLimitAndUnblockNextRequest() async throws {
        let fixture = try makeFixture()
        let store = UndoHistoryStore(
            storeURL: fixture.historyURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let operationID = UUID()
        let batchSizes = [5_000, 5_001]
        let totalCount = batchSizes.reduce(0, +)
        XCTAssertGreaterThan(totalCount, UndoHistoryStore.maximumPairsPerRecord)
        XCTAssertTrue(batchSizes.allSatisfy { $0 <= UndoHistoryStore.maximumPairsPerRecord })
        let root = fixture.root
        let journal = fixture.journal
        var nextIndex = 0
        var expectedJournalIDs = Set<String>()

        for (batchIndex, batchSize) in batchSizes.enumerated() {
            let startIndex = nextIndex
            let entries = await Task.detached(priority: .utility) {
                let attemptID = UUID()
                // v2026.10.14: a user operation can complete in several legal AppKit batches.
                // Once moved, every callback fact must survive; a legacy per-record JSON cap
                // must neither drop the later batch nor keep all subsequent deletion blocked.
                return (startIndex..<(startIndex + batchSize)).map { index in
                    TrashUndoJournalEntry(
                        operationID: operationID,
                        attemptID: attemptID,
                        originalPath: root.appendingPathComponent("original/item-\(index).txt").path,
                        trashedPath: root.appendingPathComponent("trash/item-\(index).txt").path,
                        originalIdentity: TrashObjectIdentity(
                            device: 1, inode: UInt64(index + 1), fileType: UInt16(S_IFREG),
                            birthTimeSeconds: 100, birthTimeNanoseconds: 0, generation: 0
                        ),
                        restoreScopeRoot: root.path,
                        recordedAt: Date(timeIntervalSince1970: Double(100 + batchIndex))
                    )
                }
            }.value
            expectedJournalIDs.formUnion(entries.map(\.id))
            let appended = await Task.detached(priority: .utility) { journal.append(entries) }.value
            XCTAssertTrue(appended, "Each fixture batch is accepted by the durable callback journal")
            let terminal = await TrashPipeline.recoverDurableTrashState(
                journal: journal, ledger: fixture.ledger, undoHistoryStore: store
            )
            XCTAssertEqual(terminal, .ready, "Every completed batch must settle; batch=\(batchIndex), state=\(store.storageState)")
            nextIndex += batchSize
            XCTAssertEqual(store.history.count, 1, "Separate callback batches retain their shared operation identity")
            XCTAssertEqual(store.history.first?.journalOperationID, operationID)
            XCTAssertEqual(store.history.first?.filePairs.count, nextIndex)
            XCTAssertEqual(Set(store.history.flatMap(\.filePairs).compactMap(\.journalID)), expectedJournalIDs)
            XCTAssertEqual(journal.pendingEntries(), [])
        }

        let reopened = UndoHistoryStore(
            storeURL: fixture.historyURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        XCTAssertEqual(reopened.storageState, .ready)
        XCTAssertEqual(reopened.history.count, 1)
        XCTAssertEqual(reopened.history.first?.filePairs.count, totalCount)
        XCTAssertEqual(Set(reopened.history.flatMap(\.filePairs).compactMap(\.journalID)), expectedJournalIDs)
        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: fixture.ledger,
            completionJournal: journal,
            undoHistoryStore: reopened
        )
        let nextOperationID = UUID()
        let reservation = await TrashPipeline.reserveAfterRecovery(
            paths: [fixture.target.path], operationID: nextOperationID,
            reviewIdentity: nil, recoveryDependencyDomain: domain
        )
        if case .ledger(.reserved) = reservation {
            XCTAssertTrue(fixture.ledger.finish(operationID: nextOperationID, retainingPendingPaths: []))
        } else {
            XCTFail("A completely settled operation with more than 10,000 pairs must not block an unrelated request")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.target), Data("unchanged".utf8))
    }

    func testEmptyJournalRechecksWriterFailureAndRecoversWithoutRestart() async throws {
        let fixture = try makeFixture()
        let store = UndoHistoryStore(
            storeURL: fixture.historyURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        XCTAssertEqual(store.storageState, .ready)
        XCTAssertEqual(fixture.journal.pendingEntries(), [])
        let databaseURL = fixture.historyURL.appendingPathExtension("sqlite")
        var metadata = stat()
        XCTAssertEqual(Darwin.lstat(databaseURL.path, &metadata), 0)
        let originalMode = metadata.st_mode & mode_t(0o777)
        XCTAssertEqual(originalMode, 0o600)
        let originalIdentity = TrashObjectIdentity(metadata: metadata)
        // v2026.10.14: the UI's last successful bootstrap is not a current write capability.
        // Make only this fixture database read-only, retaining its inode, bytes and parent.
        XCTAssertEqual(Darwin.chmod(databaseURL.path, 0o400), 0)
        defer { XCTAssertEqual(Darwin.chmod(databaseURL.path, originalMode), 0) }
        XCTAssertEqual(store.storageState, .ready, "The fault occurs after the healthy UI projection")
        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: fixture.ledger,
            completionJournal: fixture.journal,
            undoHistoryStore: store
        )
        let firstOperationID = UUID()
        let refused = await TrashPipeline.reserveAfterRecovery(
            paths: [fixture.target.path], operationID: firstOperationID,
            reviewIdentity: nil, recoveryDependencyDomain: domain
        )
        XCTAssertEqual(refused, .recoveryBlocked, "An empty journal cannot bypass a real writer failure")
        if case .ledger(.reserved) = refused {
            // A failing old implementation must not leave a live test owner after its assertion.
            XCTAssertTrue(fixture.ledger.finish(operationID: firstOperationID, retainingPendingPaths: []))
        }
        XCTAssertNotEqual(store.storageState, .ready)
        XCTAssertEqual(fixture.journal.pendingEntries(), [])
        XCTAssertEqual(try Data(contentsOf: fixture.target), Data("unchanged".utf8))

        XCTAssertEqual(Darwin.chmod(databaseURL.path, originalMode), 0)
        XCTAssertEqual(Darwin.lstat(databaseURL.path, &metadata), 0)
        XCTAssertEqual(TrashObjectIdentity(metadata: metadata), originalIdentity)
        let retryOperationID = UUID()
        let retried = await TrashPipeline.reserveAfterRecovery(
            paths: [fixture.target.path], operationID: retryOperationID,
            reviewIdentity: nil, recoveryDependencyDomain: domain
        )
        if case .ledger(.reserved) = retried {
            XCTAssertTrue(fixture.ledger.finish(operationID: retryOperationID, retainingPendingPaths: []))
        } else {
            XCTFail("Restoring the same writer must permit a new request in the same App process")
        }
        XCTAssertEqual(store.storageState, .ready)
        XCTAssertEqual(store.completionJournalState, .ready)
        XCTAssertEqual(try Data(contentsOf: fixture.target), Data("unchanged".utf8))
    }
}
