import Darwin
import Foundation
import SQLite3
import XCTest
@testable import AppUI

/// v2026.10.14: These tests exercise the SQLite authority itself, using only fresh temporary
/// storage. Integration and migration tests remain at the UndoHistoryStore/Pipeline boundary.
final class UndoHistoryDatabaseTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let database: URL
        let parentDescriptor: Int32

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("UndoDatabase-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = directory.appendingPathComponent("UndoHistory.json.sqlite")
            parentDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        func cleanUp() {
            XCTAssertEqual(Darwin.close(parentDescriptor), 0)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Temporary database fixture cleanup failed: \(error)") }
        }

        func transaction<Value>(_ body: (UndoHistoryDatabase.Transaction) throws -> Value) throws -> Value {
            try UndoHistoryDatabase.withTransaction(at: database, parentDescriptor: parentDescriptor, body)
        }
    }

    private enum Interrupted: Error { case beforeCommit }

    private func record(in fixture: Fixture, index: Int = 0) -> UndoHistoryStore.Record {
        UndoHistoryStore.Record(
            timestamp: Date(timeIntervalSinceReferenceDate: 12345.125 + Double(index)),
            source: "database-test-\(index)",
            filePairs: [.init(
                original: fixture.directory.appendingPathComponent("original-\(index)").path,
                trashed: fixture.directory.appendingPathComponent("trash-\(index)").path
            )]
        )
    }

    func testNewDatabaseRemainsUninitializedUntilSnapshotCommits() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.transaction { transaction in
            XCTAssertNil(try transaction.loadSnapshot())
            try transaction.setMetadata(name: "migrationEvidence", value: Data())
        }
        try fixture.transaction { transaction in
            XCTAssertNil(try transaction.loadSnapshot(), "Metadata alone is not initialized Undo authority")
            XCTAssertEqual(try transaction.metadata(name: "migrationEvidence"), Data())
            try transaction.replaceSnapshot(.init())
        }
        try fixture.transaction { transaction in
            XCTAssertEqual(try transaction.loadSnapshot(), .init())
        }
        var metadata = stat()
        XCTAssertEqual(lstat(fixture.database.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }

    func testParentAliasIsResolvedOnlyWhenItMatchesAuthorizedDirectoryDescriptor() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let alias = fixture.directory.appendingPathComponent("directory-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        let aliasedDatabase = alias.appendingPathComponent(fixture.database.lastPathComponent)
        try UndoHistoryDatabase.withTransaction(at: aliasedDatabase, parentDescriptor: fixture.parentDescriptor) {
            try $0.replaceSnapshot(.init())
        }
        try fixture.transaction { XCTAssertEqual(try $0.loadSnapshot(), .init()) }

        let different = try Fixture()
        defer { different.cleanUp() }
        XCTAssertThrowsError(try UndoHistoryDatabase.withTransaction(
            at: aliasedDatabase, parentDescriptor: different.parentDescriptor
        ) { try $0.loadSnapshot() }) { error in
            XCTAssertEqual(error as? UndoHistoryDatabaseError, .unsafeFile("parentIdentity"))
        }
    }

    func testSnapshotRowsAndMigrationMetadataRoundTripInOneTransaction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = record(in: fixture)
        let observedID = UUID()
        let snapshot = UndoHistoryDatabaseSnapshot(
            records: [first],
            committedJournalIDs: ["receipt": Date(timeIntervalSinceReferenceDate: 42.25)],
            observedLegacyRecordIDs: [observedID],
            observedLegacyReceiptIDs: ["legacy-receipt"]
        )

        try fixture.transaction { transaction in
            try transaction.replaceSnapshot(snapshot)
            try transaction.setMetadata(name: "cutover", value: Data([0, 1, 0, 255]))
        }
        try fixture.transaction { transaction in
            XCTAssertEqual(try transaction.loadSnapshot(), snapshot)
            XCTAssertEqual(try transaction.metadata(name: "cutover"), Data([0, 1, 0, 255]))
            XCTAssertNil(try transaction.metadata(name: "absent"))
            let restored = UndoHistoryStore.Record(
                id: first.id, timestamp: first.timestamp, source: first.source,
                filePairs: first.filePairs,
                recoveryStates: [.init(status: .restored, restoredDestination: first.filePairs[0].original)]
            )
            try transaction.replaceSnapshot(.init(records: [restored]))
        }
        try fixture.transaction { transaction in
            let loaded = try XCTUnwrap(transaction.loadSnapshot())
            XCTAssertEqual(loaded.records.first?.recoveryStates.first?.status, .restored)
            XCTAssertEqual(loaded.records.first?.filePairs, first.filePairs)
            XCTAssertTrue(loaded.committedJournalIDs.isEmpty)
            XCTAssertTrue(loaded.observedLegacyRecordIDs.isEmpty)
            XCTAssertTrue(loaded.observedLegacyReceiptIDs.isEmpty)
            XCTAssertEqual(try transaction.metadata(name: "cutover"), Data([0, 1, 0, 255]))
        }
    }

    func testThrownInterruptionRollsBackSnapshotAndMetadataTogether() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = UndoHistoryDatabaseSnapshot(records: [record(in: fixture)])
        try fixture.transaction { transaction in
            try transaction.replaceSnapshot(original)
            try transaction.setMetadata(name: "generation", value: Data([1]))
        }

        XCTAssertThrowsError(try fixture.transaction { transaction in
            try transaction.replaceSnapshot(.init(records: [record(in: fixture, index: 1)]))
            try transaction.setMetadata(name: "generation", value: Data([2]))
            throw Interrupted.beforeCommit
        })
        try fixture.transaction { transaction in
            XCTAssertEqual(try transaction.loadSnapshot(), original)
            XCTAssertEqual(try transaction.metadata(name: "generation"), Data([1]))
        }
    }

    func testCaughtStorageErrorCannotCommitAnEarlierPartialMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let originalRecord = record(in: fixture)
        let original = UndoHistoryDatabaseSnapshot(records: [originalRecord])
        try fixture.transaction { try $0.replaceSnapshot(original) }

        XCTAssertThrowsError(try fixture.transaction { transaction in
            try transaction.setMetadata(name: "mustRollback", value: Data([99]))
            do {
                try transaction.replaceSnapshot(.init(records: [originalRecord, originalRecord]))
                XCTFail("Duplicate record identities must fail")
            } catch UndoHistoryDatabaseError.invalidSnapshot {
                // The Store can translate this into a typed UI failure. That must not convert
                // the surrounding transaction into success or commit mustRollback metadata.
            }
        })
        try fixture.transaction { transaction in
            XCTAssertEqual(try transaction.loadSnapshot(), original)
            XCTAssertNil(try transaction.metadata(name: "mustRollback"))
        }
    }

    func testHistoryLargerThanOldAggregateLimitKeepsEveryPairAndAcceptsNextWrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let components = Array(repeating: String(repeating: "a", count: 100), count: 6).joined(separator: "/")
        let base = fixture.directory.appendingPathComponent(components).path
        let pairs = (0..<8_000).map { index in
            UndoHistoryStore.Record.FilePair(original: base + "/original-\(index)", trashed: base + "/trash-\(index)")
        }
        let wide = UndoHistoryStore.Record(source: "wide-operation", filePairs: pairs)
        let snapshot = UndoHistoryDatabaseSnapshot(records: [wide])
        XCTAssertGreaterThan(try JSONEncoder().encode(snapshot).count, 8 * 1_024 * 1_024)

        try fixture.transaction { try $0.replaceSnapshot(snapshot) }
        try fixture.transaction { transaction in
            XCTAssertEqual(try transaction.loadSnapshot(), snapshot)
            var next = snapshot
            next.records.insert(record(in: fixture, index: 1), at: 0)
            try transaction.replaceSnapshot(next)
        }
        try fixture.transaction { transaction in
            let loaded = try XCTUnwrap(transaction.loadSnapshot())
            XCTAssertEqual(loaded.records.count, 2)
            XCTAssertEqual(loaded.records.last?.filePairs, pairs)
        }
    }

    func testUnsafeDatabaseAndJournalObjectsArePreservedAndRejected() throws {
        for kind in ["symlink", "hardlink", "permissions", "journal-symlink"] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let foreign = fixture.directory.appendingPathComponent("foreign")
            let bytes = Data("foreign content".utf8)
            try bytes.write(to: foreign)
            XCTAssertEqual(chmod(foreign.path, 0o600), 0)
            switch kind {
            case "symlink":
                try FileManager.default.createSymbolicLink(at: fixture.database, withDestinationURL: foreign)
            case "hardlink":
                XCTAssertEqual(link(foreign.path, fixture.database.path), 0)
            case "permissions":
                try bytes.write(to: fixture.database)
                XCTAssertEqual(chmod(fixture.database.path, 0o644), 0)
            default:
                try fixture.transaction { try $0.replaceSnapshot(.init()) }
                try FileManager.default.createSymbolicLink(
                    at: URL(fileURLWithPath: fixture.database.path + "-journal"),
                    withDestinationURL: foreign
                )
            }
            XCTAssertThrowsError(try fixture.transaction { try $0.loadSnapshot() }) { error in
                guard case UndoHistoryDatabaseError.unsafeFile = error else {
                    return XCTFail("Expected unsafe file, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        }
    }

    func testUnrelatedSQLiteDatabaseIsRejectedBeforeChangingItsJournalMode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Establish the secure-file precondition before SQLite creates its sidecars; otherwise
        // this fixture only exercises permission rejection, not unrelated schema rejection.
        let descriptor = open(fixture.database.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(close(descriptor), 0)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.database.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let opened = try XCTUnwrap(handle)
        // '_' is literal in SQLite's reserved prefix; LIKE 'sqlite_%' would hide sqlitex.
        XCTAssertEqual(sqlite3_exec(opened, "PRAGMA journal_mode=WAL; CREATE TABLE sqlitex(value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(opened), SQLITE_OK)
        XCTAssertEqual(chmod(fixture.database.path, 0o600), 0)
        let originalBytes = try Data(contentsOf: fixture.database)

        XCTAssertThrowsError(try fixture.transaction { try $0.loadSnapshot() }) { error in
            XCTAssertEqual(error as? UndoHistoryDatabaseError, .unsafeFile("unrecognizedDatabase"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.database), originalBytes)
    }

    func testDatabasePathReplacementBeforeCommitDoesNotOverwriteReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = UndoHistoryDatabaseSnapshot(records: [record(in: fixture)])
        try fixture.transaction { try $0.replaceSnapshot(original) }
        let heldDatabase = fixture.directory.appendingPathComponent("held.sqlite")
        let replacement = Data("external replacement".utf8)

        XCTAssertThrowsError(try fixture.transaction { transaction in
            try transaction.setMetadata(name: "uncommitted", value: Data([1]))
            try FileManager.default.moveItem(at: fixture.database, to: heldDatabase)
            try replacement.write(to: fixture.database)
            XCTAssertEqual(chmod(fixture.database.path, 0o600), 0)
        }) { error in
            guard case UndoHistoryDatabaseError.unsafeFile = error else {
                return XCTFail("Expected replaced path rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.database), replacement)
        try FileManager.default.removeItem(at: fixture.database)
        try FileManager.default.moveItem(at: heldDatabase, to: fixture.database)
        try fixture.transaction { transaction in
            XCTAssertEqual(try transaction.loadSnapshot(), original)
            XCTAssertNil(try transaction.metadata(name: "uncommitted"))
        }
    }
}
