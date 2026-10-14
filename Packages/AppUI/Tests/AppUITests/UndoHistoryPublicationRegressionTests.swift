import Foundation
import XCTest
@testable import AppUI

/// v2026.10.14: asynchronous persistence publication prepares wide recovery projections away
/// from MainActor. The extra suspension must not let an old projection erase a newer write.
@MainActor
final class UndoHistoryPublicationRegressionTests: XCTestCase {
    /// All mutable hook observations use lock. The semaphores hold only the utility worker,
    /// allowing MainActor to issue a newer mutation at the exact projection-preparation boundary.
    private final class PreparationGate: @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        private var enteredOnMain = false
        private var timedOut = false
        private var publicationRevisions: [UInt64] = []

        func observePublication(_ revision: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            publicationRevisions.append(revision)
        }

        func holdPreparation() {
            let isMain = Thread.isMainThread
            lock.lock()
            enteredOnMain = isMain
            lock.unlock()
            entered.signal()
            // A regression must fail its assertion instead of deadlocking the test's MainActor.
            guard !isMain else { return }
            let result = released.wait(timeout: .now() + 5)
            lock.lock()
            timedOut = result != .success
            lock.unlock()
        }

        func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
        func release() { released.signal() }

        var observations: (onMain: Bool, timedOut: Bool, revisions: [UInt64]) {
            lock.lock()
            defer { lock.unlock() }
            return (enteredOnMain, timedOut, publicationRevisions)
        }
    }

    func testBackgroundProjectionCannotOverwriteWriteIssuedDuringPreparation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoPublication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Temporary publication fixture cleanup failed: \(error)") }
        }
        let firstTrash = root.appendingPathComponent("first-trash.txt")
        let secondTrash = root.appendingPathComponent("second-trash.txt")
        try Data("first fixture".utf8).write(to: firstTrash)
        try Data("second fixture".utf8).write(to: secondTrash)
        let url = root.appendingPathComponent("UndoHistory.json")
        let store = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [root.path])
        store.addRecord(source: "first", filePairs: [.init(
            original: root.appendingPathComponent("first-original.txt").path,
            trashed: firstTrash.path
        )])
        XCTAssertEqual(store.storageState, .ready)
        let gate = PreparationGate()
        defer { gate.release() }
        store.setPersistencePublicationHookForTesting { gate.observePublication($0) }
        store.setPersistenceProjectionPreparationHookForTesting { gate.holdPreparation() }
        let preparation = Task { await store.prepareForDeletion() }
        let entered = await Task.detached(priority: .utility) { gate.waitUntilEntered() }.value
        XCTAssertTrue(entered, "The old projection must freeze its snapshot before the newer write")
        XCTAssertFalse(gate.observations.onMain, "Pair traversal and path normalization belong on the utility worker")
        let oldRevision = store.persistenceRevisionForTesting

        // Synchronous fixture semantics remain intact while the older asynchronous projection
        // is suspended: addRecord must return with the complete newer projection already visible.
        store.addRecord(source: "second", filePairs: [.init(
            original: root.appendingPathComponent("second-original.txt").path,
            trashed: secondTrash.path
        )])
        let latestRevision = store.persistenceRevisionForTesting
        XCTAssertGreaterThan(latestRevision, oldRevision)
        XCTAssertEqual(store.history.map(\.source), ["second", "first"])
        gate.release()
        let preparationSucceeded = await preparation.value
        XCTAssertTrue(preparationSucceeded, "The older durable prepare succeeded even though its UI projection became stale")
        XCTAssertFalse(gate.observations.timedOut)
        XCTAssertEqual(gate.observations.revisions, [oldRevision, latestRevision],
                       "Publication hooks remain MainActor attempts before guards and fire once per completion")
        XCTAssertEqual(store.history.map(\.source), ["second", "first"])
        XCTAssertEqual(store.storageState, .ready)
        let reopened = UndoHistoryStore(storeURL: url, allowedRestoreRoots: [root.path])
        XCTAssertEqual(reopened.storageState, .ready)
        XCTAssertEqual(reopened.history.map(\.source), ["second", "first"])
        XCTAssertEqual(reopened.history.flatMap(\.filePairs), store.history.flatMap(\.filePairs))
    }
}
