import Darwin
import Foundation
import XCTest
@testable import AppUI

/// Regression coverage for the callback -> durable journal -> Undo handoff. All paths are
/// temporary fixtures and every recycle call is scripted; no test invokes NSWorkspace.recycle.
final class TrashCompletionJournalTests: XCTestCase {
    private final class LockedOrdinal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class RecycleCallbackBox: @unchecked Sendable {
        typealias Callback = @Sendable ([(String, String)], String?) -> Void
        private let lock = NSLock()
        private var callback: Callback?

        func store(_ callback: @escaping Callback) {
            lock.lock()
            self.callback = callback
            lock.unlock()
        }

        func invoke(pairs: [(String, String)], error: String? = nil) {
            lock.lock()
            let callback = callback
            lock.unlock()
            callback?(pairs, error)
        }
    }

    private final class FailFirstRemoveJournal: TrashCompletionJournaling, @unchecked Sendable {
        private let base: PersistentTrashCompletionJournal
        private let lock = NSLock()
        private var shouldFail = true

        init(base: PersistentTrashCompletionJournal) { self.base = base }
        func append(_ entries: [TrashUndoJournalEntry]) -> Bool { base.append(entries) }
        func pendingEntries() -> [TrashUndoJournalEntry]? { base.pendingEntries() }
        func snapshot() -> TrashCompletionJournalSnapshot? { base.snapshot() }
        func markReceiptPrunePending(ids: Set<String>) -> Bool {
            base.markReceiptPrunePending(ids: ids)
        }
        func remove(ids: Set<String>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if shouldFail {
                shouldFail = false
                return false
            }
            return base.remove(ids: ids)
        }
    }

    private final class FailMarkJournal: TrashCompletionJournaling, @unchecked Sendable {
        private let base: PersistentTrashCompletionJournal

        init(base: PersistentTrashCompletionJournal) { self.base = base }
        func append(_ entries: [TrashUndoJournalEntry]) -> Bool { base.append(entries) }
        func pendingEntries() -> [TrashUndoJournalEntry]? { base.pendingEntries() }
        func snapshot() -> TrashCompletionJournalSnapshot? { base.snapshot() }
        func markReceiptPrunePending(ids: Set<String>) -> Bool { false }
        func remove(ids: Set<String>) -> Bool { base.remove(ids: ids) }
    }
    private struct Fixture {
        let root: URL
        let target: URL
        let trashed: URL
        let journalURL: URL
        let ledgerURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashCompletionJournalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        try Data("recorded".utf8).write(to: target)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            target: target,
            trashed: root.appendingPathComponent("trash/target"),
            journalURL: root.appendingPathComponent("completion.json"),
            ledgerURL: root.appendingPathComponent("pending.json")
        )
    }

    private func identity(at url: URL) throws -> TrashObjectIdentity {
        switch TrashObjectIdentity.probe(path: url.path) {
        case .present(let identity): return identity
        case .missing: throw NSError(domain: "fixture", code: 1)
        case .unavailable(let code): throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// v2026.10.14: UndoHistory.json is now a retirement manifest, so receipt assertions must
    /// inspect the production SQLite authority. Call only after awaited fixture writes/recovery
    /// have finished; these isolated fixtures have no concurrent writer during this transaction.
    private func durableUndoSnapshot(at historyURL: URL) throws -> UndoHistoryDatabaseSnapshot {
        let parent = historyURL.deletingLastPathComponent()
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        return try UndoHistoryDatabase.withTransaction(
            at: historyURL.appendingPathExtension("sqlite"), parentDescriptor: descriptor
        ) { database in
            try XCTUnwrap(database.loadSnapshot())
        }
    }

    private func entry(
        fixture: Fixture,
        operationID: UUID = UUID(),
        attemptID: UUID = UUID(),
        recordedAt: Date = Date(timeIntervalSince1970: 100)
    ) throws -> TrashUndoJournalEntry {
        TrashUndoJournalEntry(
            operationID: operationID,
            attemptID: attemptID,
            originalPath: fixture.target.path,
            trashedPath: fixture.trashed.path,
            originalIdentity: try identity(at: fixture.target),
            restoreScopeRoot: fixture.root.path,
            recordedAt: recordedAt
        )
    }

    private func observedCapability(
        fixture: Fixture,
        journal: any TrashCompletionJournaling
    ) throws -> (
        capability: TrashUndoCommitCapability,
        entry: TrashUndoJournalEntry,
        ledger: PersistentTrashPendingOperationLedger
    ) {
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = ledger.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), ledger.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) == .applied else {
            throw NSError(domain: "TrashCompletionJournalTests.fixture", code: 2)
        }
        let row = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: attemptID
        )
        guard journal.append([row]) else {
            throw NSError(domain: "TrashCompletionJournalTests.fixture", code: 3)
        }
        return (
            TrashUndoCommitCapability(entries: [row], journal: journal, ledger: ledger),
            row,
            ledger
        )
    }

    func testAppendReloadAndRemoveUseStableDurablePayload() throws {
        let fixture = try makeFixture()
        let first = try entry(fixture: fixture)
        let writer = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)

        XCTAssertTrue(writer.append([first]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.journalURL.appendingPathExtension("lock").path
        ))

        let reloaded = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        XCTAssertEqual(reloaded.pendingEntries(), [first])
        XCTAssertTrue(reloaded.remove(ids: [first.id]))
        XCTAssertEqual(reloaded.pendingEntries(), [])
    }

    func testJournalIDIsOpaqueAndDoesNotEmbedOriginalPath() throws {
        let fixture = try makeFixture()
        let row = try entry(fixture: fixture)

        XCTAssertTrue(TrashUndoJournalEntry.isOpaqueID(row.id))
        XCTAssertFalse(row.id.contains(fixture.target.path))
        XCTAssertNotEqual(row.id, row.legacyPlaintextID)
        XCTAssertFalse(TrashUndoJournalEntry.isOpaqueID(
            "sha256:" + String(repeating: "١", count: 64)
        ), "Canonical receipt IDs accept ASCII lowercase hex only")
    }

    func testJournalIDBindsAttemptAndBothCallbackPaths() throws {
        let fixture = try makeFixture()
        let operationID = UUID()
        let attemptID = UUID()
        let baseline = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: attemptID
        )
        let differentAttempt = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: UUID()
        )
        let differentTrash = TrashUndoJournalEntry(
            operationID: operationID,
            attemptID: attemptID,
            originalPath: fixture.target.path,
            trashedPath: fixture.trashed.deletingLastPathComponent()
                .appendingPathComponent("other").path,
            originalIdentity: try identity(at: fixture.target),
            restoreScopeRoot: fixture.root.path
        )

        XCTAssertNotEqual(baseline.id, differentAttempt.id)
        XCTAssertNotEqual(baseline.id, differentTrash.id)
    }

    func testLegacyPlaintextJournalKeyMigratesDurablyToOpaqueID() throws {
        let fixture = try makeFixture()
        let row = try entry(fixture: fixture)
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        XCTAssertTrue(journal.append([row]))

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journalURL))
                as? [String: Any]
        )
        var entries = try XCTUnwrap(object["entries"] as? [String: Any])
        var encodedRow = try XCTUnwrap(entries.removeValue(forKey: row.id) as? [String: Any])
        encodedRow["id"] = row.legacyPlaintextID
        entries[row.legacyPlaintextID] = encodedRow
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.journalURL)

        let restarted = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        XCTAssertEqual(restarted.pendingEntries(), [row])
        let migratedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journalURL))
                as? [String: Any]
        )
        let migratedEntries = try XCTUnwrap(migratedObject["entries"] as? [String: Any])
        XCTAssertEqual(Set(migratedEntries.keys), [row.id])
        XCTAssertEqual(
            (migratedEntries[row.id] as? [String: Any])?["id"] as? String,
            row.id
        )
    }

    func testDuplicateCallbackTimestampDoesNotCreateCollisionOrReplaceFact() throws {
        let fixture = try makeFixture()
        let operationID = UUID()
        let attemptID = UUID()
        let first = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: attemptID,
            recordedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicate = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: attemptID,
            recordedAt: Date(timeIntervalSince1970: 200)
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)

        XCTAssertTrue(journal.append([first]))
        XCTAssertTrue(journal.append([duplicate]))
        XCTAssertEqual(journal.pendingEntries(), [first])
    }

    func testDurableWriterFailureDoesNotAcknowledgeOrReplacePriorPayload() throws {
        let fixture = try makeFixture()
        let first = try entry(fixture: fixture)
        let real = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        XCTAssertTrue(real.append([first]))
        let originalBytes = try Data(contentsOf: fixture.journalURL)

        let second = try entry(fixture: fixture, operationID: UUID(), attemptID: UUID())
        let failing = PersistentTrashCompletionJournal(
            fileURL: fixture.journalURL,
            durableWriter: { _, _ in false }
        )
        XCTAssertFalse(failing.append([second]))
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), originalBytes)
        XCTAssertEqual(real.pendingEntries(), [first])
    }

    func testCallbackLedgerWriteFailureRetainsDurableJournalForReplay() async throws {
        let fixture = try makeFixture()
        let owner = TrashLedgerProcessIdentity(
            pid: 88_777,
            startTimeSeconds: 777,
            startTimeMicroseconds: 1
        )
        let writes = LockedOrdinal()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive },
            durableWriter: { data, url in
                guard writes.next() <= 2 else { return false }
                return TrashDurableFileWriter.replace(
                    data,
                    at: url,
                    temporaryPrefix: "callback-ledger-test",
                    logContext: "Callback ledger test"
                )
            }
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID) else {
            return XCTFail("Fixture reserve must succeed")
        }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 0.08,
            ledger: ledger,
            completionJournal: journal,
            frozenIdentities: frozen,
            frozenRestoreRoots: [
                TrashPipeline.normalizePath(fixture.target.path): fixture.root.path
            ],
            submissionQueue: DispatchQueue(label: "callback-ledger-storage-failure"),
            workspaceRecycle: { _, callback in
                try! FileManager.default.createDirectory(
                    at: fixture.trashed.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try! FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                callback([(fixture.target.path, fixture.trashed.path)], nil)
            },
            lateHandler: { _, _ in },
            callbackSettlementRetryDelays: []
        )

        guard case .submissionUnknown = result.state else {
            return XCTFail("Unacknowledged callback must remain submission-unknown")
        }
        XCTAssertEqual(journal.pendingEntries()?.count, 1)
        XCTAssertEqual(journal.pendingEntries()?.first?.attemptID, attemptID)
    }

    func testTransientCallbackLedgerFailureSettlesInSameProcessWithoutSecondRecycle() async throws {
        let fixture = try makeFixture()
        let owner = TrashLedgerProcessIdentity(
            pid: 88_776,
            startTimeSeconds: 776,
            startTimeMicroseconds: 1
        )
        let writes = LockedOrdinal()
        let workspaceCalls = LockedOrdinal()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive },
            durableWriter: { data, url in
                let ordinal = writes.next()
                guard ordinal != 3 else { return false }
                return TrashDurableFileWriter.replace(
                    data,
                    at: url,
                    temporaryPrefix: "callback-ledger-transient-test",
                    logContext: "Transient callback ledger test"
                )
            }
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else { return XCTFail("Fixture reserve must succeed") }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 1,
            ledger: ledger,
            completionJournal: journal,
            frozenIdentities: frozen,
            frozenRestoreRoots: [
                TrashPipeline.normalizePath(fixture.target.path): fixture.root.path
            ],
            submissionQueue: DispatchQueue(label: "callback-ledger-transient-retry"),
            workspaceRecycle: { _, callback in
                _ = workspaceCalls.next()
                try! FileManager.default.createDirectory(
                    at: fixture.trashed.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try! FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                callback([(fixture.target.path, fixture.trashed.path)], nil)
            },
            lateHandler: { _, _ in },
            callbackSettlementRetryDelays: [0.01, 0.02]
        )

        XCTAssertEqual(result.state, .callbackCompleted)
        XCTAssertEqual(result.moved.map(\.0), [fixture.target.path])
        XCTAssertEqual(result.undoJournalEntries.count, 1)
        XCTAssertTrue(result.undoJournalBlockedAttempts.isEmpty)
        XCTAssertEqual(workspaceCalls.current, 1, "Settlement retry must never resubmit recycle")
        XCTAssertGreaterThanOrEqual(writes.current, 4)
        XCTAssertTrue(ledger.ownsExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertTrue(ledger.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertTrue(journal.remove(ids: Set(result.undoJournalEntries.map(\.id))))
    }

    @MainActor
    func testDuplicateCallbackAfterJournalRemoveCannotRecreateDurableFact() async throws {
        let fixture = try makeFixture()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else { return XCTFail("Fixture reserve must succeed") }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))
        let box = RecycleCallbackBox()
        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 1,
            ledger: ledger,
            completionJournal: journal,
            frozenIdentities: frozen,
            frozenRestoreRoots: [
                TrashPipeline.normalizePath(fixture.target.path): fixture.root.path
            ],
            submissionQueue: DispatchQueue(label: "duplicate-after-remove"),
            workspaceRecycle: { _, callback in
                box.store(callback)
                try! FileManager.default.createDirectory(
                    at: fixture.trashed.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try! FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                callback([(fixture.target.path, fixture.trashed.path)], nil)
            },
            lateHandler: { _, _ in }
        )
        let row = try XCTUnwrap(result.undoJournalEntries.first)
        let store = UndoHistoryStore(
            storeURL: fixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [fixture.root.path]
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        let persisted = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [row]
        )
        XCTAssertTrue(persisted)
        let capability = TrashUndoCommitCapability(
            entries: [row],
            journal: journal,
            ledger: ledger
        )
        let finalized = await capability.finishDurablyAfterUndoPersisted(
            pruningReceiptsIn: store
        )
        XCTAssertTrue(finalized)
        XCTAssertEqual(journal.pendingEntries(), [])

        // The adapter violates its callback contract after finalization. Admission must reject it
        // before append/ledger projection, even though the deterministic ID is no longer present.
        box.invoke(pairs: [(fixture.target.path, fixture.trashed.path)])
        await TrashCompletionHealthTransitionQueue.shared.flush()

        XCTAssertEqual(journal.pendingEntries(), [])
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history[0].filePairs.map(\.journalID), [row.id])
        XCTAssertEqual(store.completionJournalState, .ready)
        XCTAssertEqual(ledger.acknowledgeExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .alreadyAbsent)
    }

    func testCommitCapabilityRetriesFinalJournalRemoveAfterReceiptPhaseIsDurable() throws {
        let fixture = try makeFixture()
        let owner = TrashLedgerProcessIdentity(
            pid: 88_778,
            startTimeSeconds: 778,
            startTimeMicroseconds: 1
        )
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { owner },
            processLivenessProbe: { $0 == owner ? .active : .inactive }
        )
        let baseJournal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let journal = FailFirstRemoveJournal(base: baseJournal)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(paths: [fixture.target.path], operationID: operationID),
              case .claimed = ledger.claim(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: attemptID
              ),
              ledger.markCallbackObserved(
                paths: [fixture.target.path],
                operationID: operationID,
                attemptID: attemptID
              ) == .applied else { return XCTFail("Fixture exact attempt must be observed") }
        let row = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: attemptID
        )
        XCTAssertTrue(journal.append([row]))
        let capability = TrashUndoCommitCapability(
            entries: [row],
            journal: journal,
            ledger: ledger
        )

        let pruneIDs = capability.prepareReceiptPruneAfterUndoPersisted()
        XCTAssertEqual(pruneIDs, [row.id])
        XCTAssertEqual(ledger.acknowledgeExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .alreadyAbsent)
        XCTAssertEqual(baseJournal.snapshot()?.receiptPrunePendingIDs, [row.id])
        XCTAssertFalse(capability.finishAfterReceiptPruned(ids: pruneIDs))
        XCTAssertEqual(baseJournal.pendingEntries(), [row])
        XCTAssertTrue(capability.finishAfterReceiptPruned(ids: pruneIDs))
        XCTAssertEqual(baseJournal.pendingEntries(), [])
    }

    @MainActor
    func testMarkPrunePhaseFailureKeepsExactAttemptHealthBlocked() async throws {
        let fixture = try makeFixture()
        let base = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let failing = FailMarkJournal(base: base)
        let observed = try observedCapability(fixture: fixture, journal: failing)
        let store = UndoHistoryStore(
            storeURL: fixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [fixture.root.path]
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        let persisted = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [observed.entry]
        )
        XCTAssertTrue(persisted)

        let finished = await observed.capability.finishDurablyAfterUndoPersisted(
            pruningReceiptsIn: store
        )
        XCTAssertFalse(finished)
        XCTAssertEqual(store.completionJournalState, .blocked)
        XCTAssertEqual(base.pendingEntries(), [observed.entry])
        XCTAssertEqual(base.snapshot()?.receiptPrunePendingIDs, [])
    }

    @MainActor
    func testReceiptPruneFailureKeepsJournalEvidenceAndHealthBlocked() async throws {
        let fixture = try makeFixture()
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let observed = try observedCapability(fixture: fixture, journal: journal)
        let undoURL = fixture.root.appendingPathComponent("UndoHistory.json")
        let store = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        let persisted = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [observed.entry]
        )
        XCTAssertTrue(persisted)
        // v2026.10.14: inject failure into the real SQLite authority after Undo commit, not the
        // retired JSON manifest. Corrupt storage must preserve the journal replay capability.
        try Data("not-sqlite".utf8).write(to: undoURL.appendingPathExtension("sqlite"))

        let finished = await observed.capability.finishDurablyAfterUndoPersisted(
            pruningReceiptsIn: store
        )
        XCTAssertFalse(finished)
        XCTAssertEqual(store.completionJournalState, .blocked)
        XCTAssertEqual(journal.pendingEntries(), [observed.entry])
        XCTAssertEqual(journal.snapshot()?.receiptPrunePendingIDs, [observed.entry.id])
    }

    @MainActor
    func testJournalRemoveFailureRetainsPruneReplayAndRetryClearsHealth() async throws {
        let fixture = try makeFixture()
        let base = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let failing = FailFirstRemoveJournal(base: base)
        let observed = try observedCapability(fixture: fixture, journal: failing)
        let undoURL = fixture.root.appendingPathComponent("UndoHistory.json")
        let store = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        let persisted = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [observed.entry]
        )
        XCTAssertTrue(persisted)

        let firstFinished = await observed.capability.finishDurablyAfterUndoPersisted(
            pruningReceiptsIn: store
        )
        XCTAssertFalse(firstFinished)
        XCTAssertEqual(store.completionJournalState, .blocked)
        XCTAssertEqual(base.snapshot()?.receiptPrunePendingIDs, [observed.entry.id])
        let afterFailedRemove = try durableUndoSnapshot(at: undoURL)
        XCTAssertEqual(
            afterFailedRemove.committedJournalIDs.count,
            0,
            "Receipt is gone, while prune-pending journal evidence remains replayable"
        )

        let retryFinished = await observed.capability.finishDurablyAfterUndoPersisted(
            pruningReceiptsIn: store
        )
        XCTAssertTrue(retryFinished)
        XCTAssertEqual(base.pendingEntries(), [])
        XCTAssertEqual(store.completionJournalState, .ready)
    }

    func testJournalRejectsDuplicateRowsWithinOneAppend() throws {
        let fixture = try makeFixture()
        let row = try entry(fixture: fixture)
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)

        XCTAssertFalse(journal.append([row, row]))
        XCTAssertEqual(journal.pendingEntries(), [])
    }

    func testCorruptOrUnreadableJournalIsNeverDecodedAsEmpty() throws {
        let fixture = try makeFixture()
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fixture.journalURL)
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)

        XCTAssertNil(journal.pendingEntries())
        XCTAssertFalse(journal.append([try entry(fixture: fixture)]))
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), corrupt)
    }

    func testPermissionFailureIsNeverDecodedAsEmptyOrOverwritten() throws {
        let fixture = try makeFixture()
        let bytes = Data("protected".utf8)
        try bytes.write(to: fixture.journalURL)
        XCTAssertEqual(chmod(fixture.journalURL.path, 0), 0)
        defer { _ = chmod(fixture.journalURL.path, S_IRUSR | S_IWUSR) }
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)

        XCTAssertNil(journal.pendingEntries())
        XCTAssertFalse(journal.append([try entry(fixture: fixture)]))
        XCTAssertEqual(chmod(fixture.journalURL.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), bytes)
    }

    @MainActor
    func testCrashAfterUndoFsyncBeforeJournalAckReplaysIdempotently() async throws {
        let fixture = try makeFixture()
        let row = try entry(fixture: fixture)
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        XCTAssertTrue(journal.append([row]))
        let undoURL = fixture.root.appendingPathComponent("UndoHistory.json")
        let firstStore = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let firstCommit = await firstStore.addJournalEntriesDurably(
            source: "clean",
            entries: [row]
        )
        XCTAssertTrue(firstCommit)
        // Simulated process death: neither ledger nor completion journal is acknowledged.

        let restartedJournal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let restartedStore = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let pending = try XCTUnwrap(restartedJournal.pendingEntries())
        let replayed = await restartedStore.addJournalEntriesDurably(
            source: "NSWorkspace",
            entries: pending
        )

        XCTAssertTrue(replayed)
        XCTAssertEqual(restartedStore.history.count, 1)
        XCTAssertEqual(restartedStore.history[0].filePairs.map(\.journalID), [row.id])
        XCTAssertTrue(restartedJournal.remove(ids: [row.id]))
    }

    @MainActor
    func testCrashAfterPrunePhaseBeforeReceiptPruneReplaysWithoutReceiptLeak() async throws {
        let fixture = try makeFixture()
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let observed = try observedCapability(fixture: fixture, journal: journal)
        let undoURL = fixture.root.appendingPathComponent("UndoHistory.json")
        let store = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let persisted = await store.addJournalEntriesDurably(
            source: "clean",
            entries: [observed.entry]
        )
        XCTAssertTrue(persisted)
        let pruneIDs = observed.capability.prepareReceiptPruneAfterUndoPersisted()
        XCTAssertEqual(pruneIDs, [observed.entry.id])
        XCTAssertEqual(journal.snapshot()?.receiptPrunePendingIDs, pruneIDs)

        // Simulated process death: exact ledger rows are gone and the journal phase is durable,
        // but receipt prune and journal removal did not run.
        let restartedStore = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let restartedJournal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let restartedLedger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let terminal = await TrashPipeline.recoverDurableTrashState(
            journal: restartedJournal,
            ledger: restartedLedger,
            undoHistoryStore: restartedStore
        )

        XCTAssertEqual(terminal, .ready)
        XCTAssertEqual(restartedJournal.pendingEntries(), [])
        XCTAssertEqual(restartedStore.history.count, 1)
        XCTAssertEqual(
            restartedStore.history[0].filePairs.map(\.journalID),
            [observed.entry.id]
        )
        let receipts = try durableUndoSnapshot(at: undoURL).committedJournalIDs
        XCTAssertTrue(receipts.isEmpty)
    }

    func testIndependentInstanceBlocksOnStableLockInode() throws {
        let fixture = try makeFixture()
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let row = try entry(fixture: fixture)
        let lockURL = fixture.journalURL.appendingPathExtension("lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = journal.append([row])
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.10), .timedOut)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(journal.pendingEntries(), [row])
    }

    func testCrashTempSweepWaitsForStableFlockAndPreservesLookalikes() throws {
        let fixture = try makeFixture()
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let stale = fixture.root.appendingPathComponent(
            ".trash-completion.\(UUID().uuidString).tmp"
        )
        let malformed = fixture.root.appendingPathComponent(
            ".trash-completion.not-a-uuid.tmp"
        )
        let extraSuffix = fixture.root.appendingPathComponent(
            ".trash-completion.\(UUID().uuidString).tmp.keep"
        )
        let protectedTarget = fixture.root.appendingPathComponent("user-owned.json")
        let exactLookingSymlink = fixture.root.appendingPathComponent(
            ".trash-completion.\(UUID().uuidString).tmp"
        )
        try Data("stale".utf8).write(to: stale)
        try Data("malformed".utf8).write(to: malformed)
        try Data("keep".utf8).write(to: extraSuffix)
        try Data("user".utf8).write(to: protectedTarget)
        try FileManager.default.createSymbolicLink(
            at: exactLookingSymlink,
            withDestinationURL: protectedTarget
        )

        let lockURL = fixture.journalURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = journal.snapshot()
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.10), .timedOut)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stale.path),
            "A store waiting for flock cannot sweep an active writer's temporary namespace"
        )

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactLookingSymlink.path))
        XCTAssertEqual(try String(contentsOf: protectedTarget, encoding: .utf8), "user")
    }

    @MainActor
    func testTwoRecoveryInstancesSerializeWholeReplayAndLeaveNoReceipt() async throws {
        let fixture = try makeFixture()
        let deadOwner = TrashLedgerProcessIdentity(
            pid: 88_990,
            startTimeSeconds: 990,
            startTimeMicroseconds: 1
        )
        let setupLedger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { deadOwner },
            processLivenessProbe: { $0 == deadOwner ? .active : .inactive }
        )
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = setupLedger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ), case .claimed = setupLedger.claim(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), setupLedger.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ) == .applied else {
            return XCTFail("Fixture dead-owner callback must be durable")
        }
        let row = try entry(
            fixture: fixture,
            operationID: operationID,
            attemptID: attemptID
        )
        let setupJournal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        XCTAssertTrue(setupJournal.append([row]))

        func restartedLedger(pid: Int32) -> PersistentTrashPendingOperationLedger {
            let current = TrashLedgerProcessIdentity(
                pid: pid,
                startTimeSeconds: UInt64(pid),
                startTimeMicroseconds: 1
            )
            return PersistentTrashPendingOperationLedger(
                fileURL: fixture.ledgerURL,
                activeOperationRegistry: TrashActiveOperationRegistry(),
                processIdentityProvider: { current },
                processLivenessProbe: { expected in
                    expected == current ? .active : .inactive
                }
            )
        }
        let journalA = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let journalB = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let ledgerA = restartedLedger(pid: 88_991)
        let ledgerB = restartedLedger(pid: 88_992)
        let undoURL = fixture.root.appendingPathComponent("UndoHistory.json")
        let storeA = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let storeB = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let firstMergeEntered = LockedOrdinal()
        let allowFirstMerge = DispatchSemaphore(value: 0)
        let secondFinished = LockedOrdinal()
        storeA.setPersistenceMutationHookForTesting { kind in
            guard kind == "journal" else { return }
            _ = firstMergeEntered.next()
            _ = allowFirstMerge.wait(timeout: .now() + 2)
        }

        let first = Task.detached {
            await TrashPipeline.recoverDurableTrashState(
                journal: journalA,
                ledger: ledgerA,
                undoHistoryStore: storeA
            )
        }
        for _ in 0..<200 where firstMergeEntered.current == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(firstMergeEntered.current, 1)
        let second = Task.detached {
            let result = await TrashPipeline.recoverDurableTrashState(
                journal: journalB,
                ledger: ledgerB,
                undoHistoryStore: storeB
            )
            _ = secondFinished.next()
            return result
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            secondFinished.current,
            0,
            "Second instance must wait on the whole-recovery flock, not only one JSON RMW"
        )
        allowFirstMerge.signal()

        let firstTerminal = await first.value
        let secondTerminal = await second.value
        XCTAssertEqual(firstTerminal, .ready)
        XCTAssertEqual(secondTerminal, .ready)
        XCTAssertEqual(journalA.pendingEntries(), [])
        let restartedStore = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        XCTAssertEqual(restartedStore.history.count, 1)
        XCTAssertEqual(restartedStore.history[0].filePairs.count, 1)
        XCTAssertEqual(restartedStore.history[0].filePairs.map(\.journalID), [row.id])
        XCTAssertEqual(ledgerA.acknowledgeExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ), .alreadyAbsent)
        XCTAssertTrue(try durableUndoSnapshot(at: undoURL).committedJournalIDs.isEmpty)
    }

    @MainActor
    func testProductionReserveBoundaryWaitsForRecoveryWhileDryRunDoesNot() async throws {
        let fixture = try makeFixture()
        let holder = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let workerJournal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let deadOwner = TrashLedgerProcessIdentity(
            pid: 88_980,
            startTimeSeconds: 980,
            startTimeMicroseconds: 1
        )
        let setupLedger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { deadOwner },
            processLivenessProbe: { $0 == deadOwner ? .active : .inactive }
        )
        let oldOperationID = UUID()
        let oldAttemptID = UUID()
        guard case .reserved = setupLedger.reserve(
            paths: [fixture.target.path],
            operationID: oldOperationID
        ), case .claimed = setupLedger.claim(
            paths: [fixture.target.path],
            operationID: oldOperationID,
            attemptID: oldAttemptID
        ), setupLedger.markCallbackObserved(
            paths: [fixture.target.path],
            operationID: oldOperationID,
            attemptID: oldAttemptID
        ) == .applied else {
            return XCTFail("Fixture old callback must be durable")
        }
        let oldEntry = try entry(
            fixture: fixture,
            operationID: oldOperationID,
            attemptID: oldAttemptID
        )
        XCTAssertTrue(holder.append([oldEntry]))
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        // v2026.10.14: the real regression has an old callback waiting on an IDLE WAL whose
        // extended attributes changed. Seed that old format explicitly BEFORE opening the
        // production SQLite store; the new default cannot manufacture a legacy WAL fixture.
        // Recovery must preserve earlier records, replay once, and release the production
        // reservation barrier without any recycle operation.
        let undoURL = fixture.root.appendingPathComponent("UndoHistory.json")
        let legacyStore = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path],
            persistenceFormat: .legacyJSON
        )
        for index in 0..<2 {
            legacyStore.addRecord(source: "previous-\(index)", filePairs: [
                .init(original: fixture.root.appendingPathComponent("previous-\(index)").path,
                      trashed: fixture.root.appendingPathComponent("trash/previous-\(index)").path)
            ])
            legacyStore.saveHistorySync()
        }
        let controls = try FileManager.default.contentsOfDirectory(at: fixture.root,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".schema4-cas.stage-") }
        XCTAssertEqual(controls.count, 2)
        for stage in controls {
            let value = Data("metadata-only".utf8)
            XCTAssertEqual(value.withUnsafeBytes {
                setxattr(stage.path, "com.amux.test.recovery", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }, 0)
        }
        let store = UndoHistoryStore(
            storeURL: undoURL,
            allowedRestoreRoots: [fixture.root.path]
        )
        let recoveryDomain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: ledger,
            completionJournal: workerJournal,
            undoHistoryStore: store
        )
        let lease = try XCTUnwrap(holder.acquireRecoveryLease())
        let operationID = UUID()
        let reservationTask = Task.detached {
            await TrashPipeline.reserveAfterRecovery(
                paths: [fixture.target.path],
                operationID: operationID,
                reviewIdentity: nil,
                recoveryDependencyDomain: recoveryDomain
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(
            ledger.frozenIdentities(
                paths: [fixture.target.path],
                operationID: operationID
            ),
            "New reserve must not retire the dead owner's callback before journal replay"
        )
        lease.release()
        guard case .ledger(.reserved) = await reservationTask.value else {
            return XCTFail("Reserve should proceed after recovery lock is released")
        }
        // The callback was recorded in 1970; the two seeded records are newer. Replay must
        // keep that timestamp/order and add exactly one journal-backed pair, not become newest.
        XCTAssertEqual(store.history.last?.filePairs.map(\.journalID), [oldEntry.id])
        XCTAssertEqual(store.history.flatMap(\.filePairs).compactMap(\.journalID), [oldEntry.id])
        XCTAssertEqual(store.history.count, 3)
        XCTAssertEqual(store.storageState, .ready)
        XCTAssertEqual(store.completionJournalState, .ready)
        XCTAssertEqual(workerJournal.pendingEntries(), [])

        let dryFixture = try makeFixture()
        let dryHolder = PersistentTrashCompletionJournal(fileURL: dryFixture.journalURL)
        let dryLease = try XCTUnwrap(dryHolder.acquireRecoveryLease())
        let dryRecoveryDomain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: PersistentTrashPendingOperationLedger(
                fileURL: dryFixture.ledgerURL,
                activeOperationRegistry: TrashActiveOperationRegistry()
            ),
            completionJournal: PersistentTrashCompletionJournal(
                fileURL: dryFixture.journalURL
            ),
            undoHistoryStore: UndoHistoryStore(
                storeURL: dryFixture.root.appendingPathComponent("UndoHistory.json"),
                allowedRestoreRoots: [dryFixture.root.path]
            )
        )
        let dryPipeline = TrashPipeline(
            home: dryFixture.root.path,
            externalDeletionRoots: [],
            recoveryDependencyDomain: dryRecoveryDomain
        )
        let dryFinished = LockedOrdinal()
        let dryTask = Task.detached {
            let result = await dryPipeline.moveToTrash(
                paths: [dryFixture.target.path],
                dryRun: true
            )
            _ = dryFinished.next()
            return result
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            dryFinished.current,
            1,
            "Diagnostic dry-run must not join the destructive recovery barrier"
        )
        dryLease.release()
        let dryResult = await dryTask.value
        XCTAssertEqual(dryResult.0, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dryFixture.ledgerURL.path))
    }

    /// v2026.07.18 recovery-domain regression: two independently assembled durable owners may
    /// recover in parallel, but a blocked journal in one owner must neither make the healthy owner
    /// fail nor have its blocked Undo health overwritten by the healthy terminal.
    @MainActor
    func testParallelRecoveryDomainsKeepSingleFlightAndUndoHealthIsolated() async throws {
        let blockedFixture = try makeFixture()
        let healthyFixture = try makeFixture()
        try Data("not-json".utf8).write(to: blockedFixture.journalURL)

        let blockedLedger = PersistentTrashPendingOperationLedger(
            fileURL: blockedFixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let healthyLedger = PersistentTrashPendingOperationLedger(
            fileURL: healthyFixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let blockedStore = UndoHistoryStore(
            storeURL: blockedFixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [blockedFixture.root.path]
        )
        let healthyStore = UndoHistoryStore(
            storeURL: healthyFixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [healthyFixture.root.path]
        )
        let blockedDomain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: blockedLedger,
            completionJournal: PersistentTrashCompletionJournal(
                fileURL: blockedFixture.journalURL
            ),
            undoHistoryStore: blockedStore
        )
        let healthyDomain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: healthyLedger,
            completionJournal: PersistentTrashCompletionJournal(
                fileURL: healthyFixture.journalURL
            ),
            undoHistoryStore: healthyStore
        )
        let blockedOperationID = UUID()
        let healthyOperationID = UUID()

        async let blockedResult = TrashPipeline.reserveAfterRecovery(
            paths: [blockedFixture.target.path],
            operationID: blockedOperationID,
            reviewIdentity: nil,
            recoveryDependencyDomain: blockedDomain
        )
        async let healthyResult = TrashPipeline.reserveAfterRecovery(
            paths: [healthyFixture.target.path],
            operationID: healthyOperationID,
            reviewIdentity: nil,
            recoveryDependencyDomain: healthyDomain
        )
        let (blocked, healthy) = await (blockedResult, healthyResult)

        XCTAssertEqual(blocked, .recoveryBlocked)
        guard case .ledger(.reserved(let paths, _)) = healthy else {
            return XCTFail("Independent healthy recovery must still reach its own ledger")
        }
        XCTAssertEqual(paths, [TrashPipeline.normalizePath(healthyFixture.target.path)])
        XCTAssertEqual(blockedStore.completionJournalState, .blocked)
        XCTAssertEqual(healthyStore.completionJournalState, .ready)
        XCTAssertTrue(healthyLedger.finish(
            operationID: healthyOperationID,
            retainingPendingPaths: []
        ))
    }

    @MainActor
    func testRecoveryBlockDoesNotPublishAPreSubmitRejectionAsExecutionOutcome() async throws {
        let fixture = try makeFixture()
        try Data("not-json".utf8).write(to: fixture.journalURL)
        let store = UndoHistoryStore(
            storeURL: fixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [fixture.root.path]
        )
        let domain = TrashRecoveryDependencyDomain(
            pendingOperationLedger: PersistentTrashPendingOperationLedger(
                fileURL: fixture.ledgerURL,
                activeOperationRegistry: TrashActiveOperationRegistry()
            ),
            completionJournal: PersistentTrashCompletionJournal(fileURL: fixture.journalURL),
            undoHistoryStore: store
        )
        let pipeline = TrashPipeline(
            home: fixture.root.path,
            externalDeletionRoots: [],
            recoveryDependencyDomain: domain
        )

        // v2026.09.06 SR-01: satisfy the review-object gate so this test still reaches the
        // corrupt journal. Its original ledgerUnavailable / no-outcome assertions stay intact.
        guard case .ready(let objects) = await pipeline.prepareReviewedObjects(
            paths: [fixture.target.path], expectedIdentities: [:]
        ) else { return XCTFail("The owned fixture must be reviewable before testing recovery") }
        let disposition = await pipeline.submitToTrashReturningDisposition(
            paths: [fixture.target.path],
            accessDeniedPaths: [],
            vendorOverrideRequest: nil,
            scanIncompleteOverrideRequest: nil,
            reviewIdentity: DeletionSnapshotIdentity(sessionID: UUID(), revision: 1),
            executionVerification: .reviewedObjects(objects)
        )

        guard case .preSubmitRejected(.pendingOperation(let rejection)) = disposition else {
            return XCTFail("Blocked recovery must remain a typed zero-submission rejection")
        }
        XCTAssertEqual(
            rejection.reasonsByPath[fixture.target.path],
            .ledgerUnavailable
        )
        XCTAssertNil(
            pipeline.snapshotLastOutcome(),
            "v2026.07.20: zero-submission recovery blocks cannot enter the result outcome slot"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @MainActor
    func testUnreadableLedgerAuthorityCannotProduceReadyRecoveryTerminal() async throws {
        let fixture = try makeFixture()
        try Data("not-json".utf8).write(to: fixture.ledgerURL)
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry()
        )
        let store = UndoHistoryStore(
            storeURL: fixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [fixture.root.path]
        )
        store.synchronizeCompletionJournalAuthority(blockedAttempts: [])
        XCTAssertEqual(store.completionJournalState, .ready)

        let terminal = await TrashPipeline.recoverDurableTrashState(
            journal: journal,
            ledger: ledger,
            undoHistoryStore: store
        )

        XCTAssertEqual(terminal, .blocked)
        XCTAssertEqual(store.completionJournalState, .blocked)
        XCTAssertEqual(journal.pendingEntries(), [])
    }

    func testCallbackUsesPreSubmitIdentityEvenWhenOriginalPathIsReoccupied() async throws {
        let fixture = try makeFixture()
        let processIdentity = TrashLedgerProcessIdentity(
            pid: 88_001,
            startTimeSeconds: 500,
            startTimeMicroseconds: 1
        )
        let registry = TrashActiveOperationRegistry()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: registry,
            processIdentityProvider: { processIdentity },
            processLivenessProbe: { $0 == processIdentity ? .active : .inactive }
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else { return XCTFail("Fixture reservation must succeed") }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 1,
            ledger: ledger,
            completionJournal: journal,
            frozenIdentities: frozen,
            frozenRestoreRoots: [
                TrashPipeline.normalizePath(fixture.target.path): fixture.root.path
            ],
            submissionQueue: DispatchQueue(label: "TrashCompletionJournalTests.callback-aba"),
            workspaceRecycle: { _, callback in
                try! FileManager.default.createDirectory(
                    at: fixture.trashed.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try! FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                try! Data("replacement".utf8).write(to: fixture.target)
                callback([(fixture.target.path, fixture.trashed.path)], nil)
            },
            lateHandler: { _, _ in }
        )

        XCTAssertEqual(result.undoJournalEntries.count, 1)
        let committed = try XCTUnwrap(result.undoJournalEntries.first)
        XCTAssertTrue(committed.originalIdentity.matches(try identity(at: fixture.trashed)))
        XCTAssertFalse(committed.originalIdentity.matches(try identity(at: fixture.target)))
        XCTAssertEqual(journal.pendingEntries(), [committed])
        XCTAssertTrue(ledger.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertTrue(journal.remove(ids: [committed.id]))
    }

    func testCallbackCannotInjectPairOutsideExactLedgerAttempt() async throws {
        let fixture = try makeFixture()
        let processIdentity = TrashLedgerProcessIdentity(
            pid: 88_051,
            startTimeSeconds: 550,
            startTimeMicroseconds: 1
        )
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { processIdentity },
            processLivenessProbe: { $0 == processIdentity ? .active : .inactive }
        )
        let journal = PersistentTrashCompletionJournal(fileURL: fixture.journalURL)
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else { return XCTFail("Fixture reservation must succeed") }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))
        let injectedOriginal = fixture.root.appendingPathComponent("not-requested")
        let injectedTrash = fixture.root.appendingPathComponent("trash/not-requested")

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 1,
            ledger: ledger,
            completionJournal: journal,
            frozenIdentities: frozen,
            frozenRestoreRoots: [
                TrashPipeline.normalizePath(fixture.target.path): fixture.root.path
            ],
            submissionQueue: DispatchQueue(label: "TrashCompletionJournalTests.scope-fence"),
            workspaceRecycle: { _, callback in
                try! FileManager.default.createDirectory(
                    at: fixture.trashed.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try! FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                callback([
                    (fixture.target.path, fixture.trashed.path),
                    (injectedOriginal.path, injectedTrash.path)
                ], nil)
            },
            lateHandler: { _, _ in }
        )

        XCTAssertEqual(result.moved.map(\.0), [fixture.target.path])
        XCTAssertEqual(result.undoJournalFailedPaths, [])
        XCTAssertEqual(result.undoJournalEntries.map(\.originalPath), [fixture.target.path])
        XCTAssertEqual(journal.pendingEntries()?.map(\.originalPath), [fixture.target.path])
        XCTAssertTrue(ledger.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertTrue(journal.remove(ids: Set(result.undoJournalEntries.map(\.id))))
    }

    @MainActor
    func testJournalDurabilityFailureAtomicallyPersistsBlockedLedgerAcrossRestart() async throws {
        let fixture = try makeFixture()
        let firstProcess = TrashLedgerProcessIdentity(
            pid: 88_101,
            startTimeSeconds: 600,
            startTimeMicroseconds: 1
        )
        let writes = LockedOrdinal()
        let ledger = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { firstProcess },
            processLivenessProbe: { $0 == firstProcess ? .active : .inactive },
            durableWriter: { data, url in
                // reserve + claim + the atomic callback/block transition are the only writes.
                // An old two-step implementation attempted a fourth write here and lost the
                // block across restart when that write failed.
                guard writes.next() <= 3 else { return false }
                return TrashDurableFileWriter.replace(
                    data,
                    at: url,
                    temporaryPrefix: "atomic-undo-block-test",
                    logContext: "Atomic Undo block ledger test"
                )
            }
        )
        let failingJournal = PersistentTrashCompletionJournal(
            fileURL: fixture.journalURL,
            durableWriter: { _, _ in false }
        )
        let operationID = UUID()
        let attemptID = UUID()
        guard case .reserved = ledger.reserve(
            paths: [fixture.target.path],
            operationID: operationID
        ) else { return XCTFail("Fixture reservation must succeed") }
        let frozen = try XCTUnwrap(ledger.frozenIdentities(
            paths: [fixture.target.path],
            operationID: operationID
        ))

        let result = await TrashPipeline.executeRecycleOnce(
            urls: [fixture.target],
            operationID: operationID,
            attemptID: attemptID,
            timeoutSeconds: 1,
            ledger: ledger,
            completionJournal: failingJournal,
            frozenIdentities: frozen,
            frozenRestoreRoots: [
                TrashPipeline.normalizePath(fixture.target.path): fixture.root.path
            ],
            submissionQueue: DispatchQueue(label: "TrashCompletionJournalTests.failed-durable"),
            workspaceRecycle: { _, callback in
                try! FileManager.default.createDirectory(
                    at: fixture.trashed.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try! FileManager.default.moveItem(at: fixture.target, to: fixture.trashed)
                callback([(fixture.target.path, fixture.trashed.path)], nil)
            },
            lateHandler: { _, _ in }
        )
        XCTAssertEqual(result.undoJournalEntries, [])
        XCTAssertEqual(result.undoJournalFailedPaths, [fixture.target.path])
        let blockedAttempt = TrashPendingAttemptIdentity(
            operationID: operationID,
            attemptID: attemptID
        )
        XCTAssertEqual(result.undoJournalBlockedAttempts, [blockedAttempt])
        XCTAssertEqual(
            writes.current,
            3,
            "Callback observation and Undo block must cross one durable ledger replace"
        )

        let restartedProcess = TrashLedgerProcessIdentity(
            pid: 88_102,
            startTimeSeconds: 700,
            startTimeMicroseconds: 1
        )
        let restarted = PersistentTrashPendingOperationLedger(
            fileURL: fixture.ledgerURL,
            activeOperationRegistry: TrashActiveOperationRegistry(),
            processIdentityProvider: { restartedProcess },
            processLivenessProbe: { expected in
                expected == restartedProcess ? .active : .inactive
            }
        )
        let reconciliation = restarted.reconcilePersistedRecords()
        XCTAssertEqual(reconciliation.undoJournalBlockedPaths, [fixture.target.path])
        XCTAssertEqual(reconciliation.undoJournalBlockedAttempts, [blockedAttempt])
        let restartedStore = UndoHistoryStore(
            storeURL: fixture.root.appendingPathComponent("UndoHistory.json"),
            allowedRestoreRoots: [fixture.root.path]
        )
        restartedStore.synchronizeCompletionJournalAuthority(
            blockedAttempts: reconciliation.undoJournalBlockedAttempts
        )
        XCTAssertEqual(restartedStore.completionJournalState, .blocked)
        XCTAssertTrue(restarted.ownsExactAttempt(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        XCTAssertTrue(restarted.finish(
            paths: [fixture.target.path],
            operationID: operationID,
            attemptID: attemptID
        ))
        restartedStore.synchronizeCompletionJournalAuthority(
            blockedAttempts: restarted.undoJournalBlockedAttempts()
        )
        XCTAssertEqual(restartedStore.completionJournalState, .ready)
    }
}
