import Darwin
import Foundation
import LogKit
import SQLite3

/// v2026.10.14: Callback facts must not outgrow a smaller aggregate JSON history. The
/// database stores each pair independently; the recent-history limit remains a caller policy.
struct UndoHistoryDatabaseSnapshot: Codable, Equatable, Sendable {
    var records: [UndoHistoryStore.Record]
    var committedJournalIDs: [String: Date]
    var observedLegacyRecordIDs: Set<UUID>
    var observedLegacyReceiptIDs: Set<String>

    init(
        records: [UndoHistoryStore.Record] = [],
        committedJournalIDs: [String: Date] = [:],
        observedLegacyRecordIDs: Set<UUID> = [],
        observedLegacyReceiptIDs: Set<String> = []
    ) {
        self.records = records
        self.committedJournalIDs = committedJournalIDs
        self.observedLegacyRecordIDs = observedLegacyRecordIDs
        self.observedLegacyReceiptIDs = observedLegacyReceiptIDs
    }
}

enum UndoHistoryDatabaseError: Error, Equatable, Sendable {
    case unsafeFile(String)
    case fileSystem(stage: String, code: Int32)
    case sqlite(code: Int32, context: String)
    case incompatibleSchema(Int32)
    case invalidSnapshot(String)
}

/// The caller owns the stable history flock and invokes this synchronous adapter on its
/// persistence worker. A Transaction never leaves that closure or crosses an actor boundary.
/// SQLite owns crash recovery; no application code rewrites a partially committed database.
enum UndoHistoryDatabase {
    private static let applicationID: Int32 = 0x414D5548 // AMUH: Amux Undo History.
    private static let schemaVersion: Int32 = 1

    static func withTransaction<Value>(
        at databaseURL: URL,
        parentDescriptor: Int32,
        _ body: (Transaction) throws -> Value
    ) throws -> Value {
        let location = try Location(url: databaseURL, parentDescriptor: parentDescriptor)
        try location.prepareFile()
        let identity = try location.mainFileIdentity()
        try location.validateSidecars()

        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            location.url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard openCode == SQLITE_OK, let openedHandle = handle else {
            let extendedCode = handle.map(sqlite3_extended_errcode) ?? openCode
            let detail = handle.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "noHandle"
            let error = UndoHistoryDatabaseError.sqlite(
                code: openCode, context: "open extended=\(extendedCode) detail=\(detail)"
            )
            if let handle {
                let closeCode = sqlite3_close(handle)
                if closeCode != SQLITE_OK { logCleanup(stage: "closeAfterOpenFailure", code: closeCode) }
            }
            throw error
        }
        let transaction = Transaction(handle: openedHandle, location: location, identity: identity)
        do {
            try transaction.verifyNamespace()
            // DELETE avoids a separate checkpoint/shared-memory lifecycle on older system
            // SQLite versions. EXTRA also syncs the directory after deleting the commit journal.
            try transaction.execute("PRAGMA busy_timeout = 5000")
            try transaction.execute("PRAGMA foreign_keys = ON")
            try transaction.execute("PRAGMA trusted_schema = OFF")
            try transaction.validateDatabaseIdentity()
            let mode = try transaction.singleText("PRAGMA journal_mode = DELETE")
            guard mode.lowercased() == "delete" else {
                throw UndoHistoryDatabaseError.sqlite(code: SQLITE_ERROR, context: "journalMode")
            }
            try transaction.execute("PRAGMA synchronous = EXTRA")
            try transaction.execute("PRAGMA fullfsync = ON")
            try transaction.execute("BEGIN IMMEDIATE")
            try transaction.prepareSchema()
            let value = try body(transaction)
            try transaction.requireSuccessfulOperations()
            try transaction.verifyNamespace()
            try transaction.execute("COMMIT")
            try transaction.verifyNamespace()
            try transaction.close()
            return value
        } catch {
            // Preserve the primary operation error. Cleanup errors are separately logged so a
            // failed rollback/close is never silently represented as a successful transaction.
            transaction.rollbackAndCloseAfterFailure()
            throw error
        }
    }

    final class Transaction {
        private var handle: OpaquePointer?
        private let location: Location
        private let identity: FileIdentity
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()
        private var operationFailure: (any Error)?

        fileprivate init(handle: OpaquePointer, location: Location, identity: FileIdentity) {
            self.handle = handle
            self.location = location
            self.identity = identity
            encoder.outputFormatting = [.sortedKeys]
        }

        /// nil means migration/initialization has not committed, not an empty healthy history.
        func loadSnapshot() throws -> UndoHistoryDatabaseSnapshot? {
            do { return try loadSnapshotRows() }
            catch { operationFailure = error; throw error }
        }

        private func loadSnapshotRows() throws -> UndoHistoryDatabaseSnapshot? {
            guard try singleInteger("SELECT COUNT(*) FROM history_state WHERE initialized = 1") == 1 else {
                return nil
            }
            struct Metadata {
                let id: UUID
                let timestamp: Date
                let source: String
                let operationID: UUID?
                let count: Int64
            }
            var metadata: [Metadata] = []
            try query("SELECT id, ordinal, timestamp, source, operation_id, pair_count FROM history_records ORDER BY ordinal") { row in
                guard let id = UUID(uuidString: try text(row, 0)),
                      sqlite3_column_int64(row, 1) == Int64(metadata.count) else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("recordIdentityOrOrder")
                }
                let timestamp = sqlite3_column_double(row, 2)
                guard timestamp.isFinite else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("timestamp")
                }
                let operationText = try optionalText(row, 4)
                let operationID = operationText.flatMap(UUID.init(uuidString:))
                guard operationText == nil || operationID != nil else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("operationIdentity")
                }
                metadata.append(Metadata(
                    id: id, timestamp: Date(timeIntervalSinceReferenceDate: timestamp),
                    source: try text(row, 3), operationID: operationID,
                    count: sqlite3_column_int64(row, 5)
                ))
            }
            var records: [UndoHistoryStore.Record] = []
            for record in metadata {
                var pairs: [UndoHistoryStore.Record.FilePair] = []
                var states: [UndoHistoryStore.Record.RecoveryState] = []
                try query(
                    "SELECT ordinal, pair, recovery FROM history_pairs WHERE record_id = ? ORDER BY ordinal",
                    bindings: [.text(record.id.uuidString)]
                ) { row in
                    guard sqlite3_column_int64(row, 0) == Int64(pairs.count) else {
                        throw UndoHistoryDatabaseError.invalidSnapshot("pairOrder")
                    }
                    do {
                        pairs.append(try decoder.decode(UndoHistoryStore.Record.FilePair.self, from: blob(row, 1)))
                        states.append(try decoder.decode(UndoHistoryStore.Record.RecoveryState.self, from: blob(row, 2)))
                    } catch let error as UndoHistoryDatabaseError {
                        throw error
                    } catch {
                        throw UndoHistoryDatabaseError.invalidSnapshot("pairDecode")
                    }
                }
                guard record.count >= 0, record.count == Int64(pairs.count) else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("pairCount")
                }
                records.append(UndoHistoryStore.Record(
                    id: record.id, timestamp: record.timestamp, source: record.source,
                    filePairs: pairs, recoveryStates: states, journalOperationID: record.operationID
                ))
            }
            var receipts: [String: Date] = [:]
            try query("SELECT id, timestamp FROM history_receipts") { row in
                let timestamp = sqlite3_column_double(row, 1)
                guard timestamp.isFinite else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("receiptTimestamp")
                }
                receipts[try text(row, 0)] = Date(timeIntervalSinceReferenceDate: timestamp)
            }
            var observedRecords = Set<UUID>()
            var observedReceipts = Set<String>()
            try query("SELECT kind, id FROM history_legacy_observations") { row in
                let kind = sqlite3_column_int(row, 0)
                let id = try text(row, 1)
                if kind == 0, let uuid = UUID(uuidString: id) {
                    observedRecords.insert(uuid)
                } else if kind == 1 {
                    observedReceipts.insert(id)
                } else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("legacyObservation")
                }
            }
            return UndoHistoryDatabaseSnapshot(
                records: records, committedJournalIDs: receipts,
                observedLegacyRecordIDs: observedRecords,
                observedLegacyReceiptIDs: observedReceipts
            )
        }

        /// Applies the complete caller-validated projection atomically. Unchanged pair rows are
        /// not rewritten, so one more callback batch does not rewrite all earlier pair payloads.
        func replaceSnapshot(_ snapshot: UndoHistoryDatabaseSnapshot) throws {
            do { try replaceSnapshotRows(snapshot) }
            catch { operationFailure = error; throw error }
        }

        private func replaceSnapshotRows(_ snapshot: UndoHistoryDatabaseSnapshot) throws {
            let ids = snapshot.records.map(\.id)
            guard Set(ids).count == ids.count else {
                throw UndoHistoryDatabaseError.invalidSnapshot("duplicateRecordIdentity")
            }
            for (ordinal, record) in snapshot.records.enumerated() {
                guard record.fileCount == record.filePairs.count,
                      record.filePairs.count == record.recoveryStates.count,
                      record.timestamp.timeIntervalSinceReferenceDate.isFinite else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("recordShape")
                }
                try execute("""
                    INSERT INTO history_records(id, ordinal, timestamp, source, operation_id, pair_count)
                    VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal,
                    timestamp=excluded.timestamp, source=excluded.source,
                    operation_id=excluded.operation_id, pair_count=excluded.pair_count
                    WHERE ordinal IS NOT excluded.ordinal OR timestamp IS NOT excluded.timestamp
                    OR source IS NOT excluded.source OR operation_id IS NOT excluded.operation_id
                    OR pair_count IS NOT excluded.pair_count
                    """, bindings: [
                        .text(record.id.uuidString), .integer(Int64(ordinal)),
                        .real(record.timestamp.timeIntervalSinceReferenceDate), .text(record.source),
                        record.journalOperationID.map { .text($0.uuidString) } ?? .null,
                        .integer(Int64(record.filePairs.count))
                    ])
                try withStatement("""
                    INSERT INTO history_pairs(record_id, ordinal, pair, recovery) VALUES(?, ?, ?, ?)
                    ON CONFLICT(record_id, ordinal) DO UPDATE SET pair=excluded.pair, recovery=excluded.recovery
                    WHERE pair IS NOT excluded.pair OR recovery IS NOT excluded.recovery
                    """) { statement in
                    for index in record.filePairs.indices {
                        let pair: Data
                        let recovery: Data
                        do {
                            pair = try encoder.encode(record.filePairs[index])
                            recovery = try encoder.encode(record.recoveryStates[index])
                        } catch {
                            throw UndoHistoryDatabaseError.invalidSnapshot("pairEncode")
                        }
                        try bind([
                            .text(record.id.uuidString), .integer(Int64(index)),
                            .blob(pair), .blob(recovery)
                        ], to: statement)
                        try requireDone(statement)
                        try check(sqlite3_reset(statement), stage: "resetPairWriter")
                        try check(sqlite3_clear_bindings(statement), stage: "clearPairBindings")
                    }
                }
                try execute("DELETE FROM history_pairs WHERE record_id = ? AND ordinal >= ?", bindings: [
                    .text(record.id.uuidString), .integer(Int64(record.filePairs.count))
                ])
            }
            let retainedRecordIDs = Set(ids.map(\.uuidString))
            var removedRecords: [String] = []
            try query("SELECT id FROM history_records") { row in
                let id = try text(row, 0)
                if !retainedRecordIDs.contains(id) { removedRecords.append(id) }
            }
            for id in removedRecords {
                try execute("DELETE FROM history_records WHERE id = ?", bindings: [.text(id)])
            }
            for (id, date) in snapshot.committedJournalIDs {
                guard date.timeIntervalSinceReferenceDate.isFinite else {
                    throw UndoHistoryDatabaseError.invalidSnapshot("receiptTimestamp")
                }
                try execute("""
                    INSERT INTO history_receipts(id, timestamp) VALUES(?, ?)
                    ON CONFLICT(id) DO UPDATE SET timestamp=excluded.timestamp
                    WHERE timestamp IS NOT excluded.timestamp
                    """, bindings: [.text(id), .real(date.timeIntervalSinceReferenceDate)])
            }
            var removedReceipts: [String] = []
            try query("SELECT id FROM history_receipts") { row in
                let id = try text(row, 0)
                if snapshot.committedJournalIDs[id] == nil { removedReceipts.append(id) }
            }
            for id in removedReceipts {
                try execute("DELETE FROM history_receipts WHERE id = ?", bindings: [.text(id)])
            }
            try replaceObservations(kind: 0, ids: Set(snapshot.observedLegacyRecordIDs.map(\.uuidString)))
            try replaceObservations(kind: 1, ids: snapshot.observedLegacyReceiptIDs)
            try execute("INSERT INTO history_state(singleton, initialized) VALUES(1, 1) ON CONFLICT(singleton) DO UPDATE SET initialized=1")
        }

        func metadata(name: String) throws -> Data? {
            var value: Data?
            try query("SELECT value FROM history_metadata WHERE name = ?", bindings: [.text(name)]) {
                value = try blob($0, 0)
            }
            return value
        }

        func setMetadata(name: String, value: Data) throws {
            try execute("""
                INSERT INTO history_metadata(name, value) VALUES(?, ?)
                ON CONFLICT(name) DO UPDATE SET value=excluded.value
                WHERE value IS NOT excluded.value
                """, bindings: [.text(name), .blob(value)])
        }

        fileprivate func prepareSchema() throws {
            let version = try singleInteger("PRAGMA user_version")
            let appID = try singleInteger("PRAGMA application_id")
            if version == 0, appID == 0 {
                guard try singleInteger("SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'") == 0 else {
                    throw UndoHistoryDatabaseError.unsafeFile("unrecognizedDatabase")
                }
                for sql in [
                    "CREATE TABLE history_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), initialized INTEGER NOT NULL CHECK(initialized=1))",
                    "CREATE TABLE history_records(id TEXT PRIMARY KEY NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), timestamp REAL NOT NULL, source TEXT NOT NULL, operation_id TEXT, pair_count INTEGER NOT NULL CHECK(pair_count>=0))",
                    "CREATE TABLE history_pairs(record_id TEXT NOT NULL REFERENCES history_records(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL CHECK(ordinal>=0), pair BLOB NOT NULL, recovery BLOB NOT NULL, PRIMARY KEY(record_id, ordinal)) WITHOUT ROWID",
                    "CREATE TABLE history_receipts(id TEXT PRIMARY KEY NOT NULL, timestamp REAL NOT NULL) WITHOUT ROWID",
                    "CREATE TABLE history_legacy_observations(kind INTEGER NOT NULL CHECK(kind IN (0,1)), id TEXT NOT NULL, PRIMARY KEY(kind, id)) WITHOUT ROWID",
                    "CREATE TABLE history_metadata(name TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID",
                    "PRAGMA application_id = \(UndoHistoryDatabase.applicationID)",
                    "PRAGMA user_version = \(UndoHistoryDatabase.schemaVersion)"
                ] { try execute(sql) }
            } else {
                guard appID == Int64(UndoHistoryDatabase.applicationID) else {
                    throw UndoHistoryDatabaseError.unsafeFile("applicationIdentity")
                }
                guard version == Int64(UndoHistoryDatabase.schemaVersion) else {
                    throw UndoHistoryDatabaseError.incompatibleSchema(Int32(clamping: version))
                }
            }
        }

        /// journal_mode can change the file outside a SQL transaction. Identify an existing
        /// database before configuring it, so a private but unrelated SQLite file is preserved.
        fileprivate func validateDatabaseIdentity() throws {
            let version = try singleInteger("PRAGMA user_version")
            let appID = try singleInteger("PRAGMA application_id")
            if version == 0, appID == 0 {
                guard try singleInteger("SELECT COUNT(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'") == 0 else {
                    throw UndoHistoryDatabaseError.unsafeFile("unrecognizedDatabase")
                }
                return
            }
            guard appID == Int64(UndoHistoryDatabase.applicationID) else {
                throw UndoHistoryDatabaseError.unsafeFile("applicationIdentity")
            }
            guard version == Int64(UndoHistoryDatabase.schemaVersion) else {
                throw UndoHistoryDatabaseError.incompatibleSchema(Int32(clamping: version))
            }
        }

        fileprivate func verifyNamespace() throws {
            try location.validateParent()
            guard try location.mainFileIdentity() == identity else {
                throw UndoHistoryDatabaseError.unsafeFile("databasePathChanged")
            }
            try location.validateSidecars()
            guard let handle else { throw UndoHistoryDatabaseError.unsafeFile("closedTransaction") }
            var moved: Int32 = 0
            let code = sqlite3_file_control(handle, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
            try check(code, stage: "openedDatabaseIdentity")
            guard moved == 0 else { throw UndoHistoryDatabaseError.unsafeFile("openedDatabaseMoved") }
        }

        /// Callers may translate an operation failure into a UI state inside the closure. Such
        /// translation must never accidentally commit the statements preceding that failure.
        fileprivate func requireSuccessfulOperations() throws {
            if let operationFailure { throw operationFailure }
        }

        fileprivate func close() throws {
            guard let handle else { return }
            let code = sqlite3_close(handle)
            guard code == SQLITE_OK else {
                throw UndoHistoryDatabaseError.sqlite(code: code, context: "close")
            }
            self.handle = nil
        }

        fileprivate func rollbackAndCloseAfterFailure() {
            if let handle, sqlite3_get_autocommit(handle) == 0 {
                do { try execute("ROLLBACK") }
                catch { AmuxLog.error(.trash, "Undo SQLite cleanup rollback failed: \(error)") }
            }
            do { try close() }
            catch { AmuxLog.error(.trash, "Undo SQLite cleanup close failed: \(error)") }
        }

        private func replaceObservations(kind: Int64, ids: Set<String>) throws {
            for id in ids {
                try execute("INSERT INTO history_legacy_observations(kind, id) VALUES(?, ?) ON CONFLICT(kind,id) DO NOTHING", bindings: [.integer(kind), .text(id)])
            }
            var removed: [String] = []
            try query("SELECT id FROM history_legacy_observations WHERE kind = ?", bindings: [.integer(kind)]) {
                let id = try text($0, 0)
                if !ids.contains(id) { removed.append(id) }
            }
            for id in removed {
                try execute("DELETE FROM history_legacy_observations WHERE kind = ? AND id = ?", bindings: [.integer(kind), .text(id)])
            }
        }

        private enum Binding {
            case text(String), integer(Int64), real(Double), blob(Data), null
        }

        private func check(_ code: Int32, stage: String) throws {
            guard code == SQLITE_OK else {
                let error = UndoHistoryDatabaseError.sqlite(code: code, context: stage)
                operationFailure = error
                throw error
            }
        }

        private func withStatement<Value>(_ sql: String, _ body: (OpaquePointer) throws -> Value) throws -> Value {
            guard let handle else { throw UndoHistoryDatabaseError.unsafeFile("closedTransaction") }
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), stage: "prepare")
            guard let statement else { throw UndoHistoryDatabaseError.sqlite(code: SQLITE_ERROR, context: "missingStatement") }
            let value: Value
            do { value = try body(statement) }
            catch {
                operationFailure = error
                let finalCode = sqlite3_finalize(statement)
                if finalCode != SQLITE_OK { UndoHistoryDatabase.logCleanup(stage: "finalizeAfterFailure", code: finalCode) }
                throw error
            }
            try check(sqlite3_finalize(statement), stage: "finalize")
            return value
        }

        private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let code: Int32
                switch binding {
                case .text(let value):
                    code = value.withCString {
                        sqlite3_bind_text64(statement, index, $0, UInt64(value.utf8.count), transient, UInt8(SQLITE_UTF8))
                    }
                case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
                case .real(let value): code = sqlite3_bind_double(statement, index, value)
                case .blob(let value):
                    code = value.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : value.withUnsafeBytes {
                        sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), transient)
                    }
                case .null: code = sqlite3_bind_null(statement, index)
                }
                try check(code, stage: "bind")
            }
        }

        private func requireDone(_ statement: OpaquePointer) throws {
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else {
                throw UndoHistoryDatabaseError.sqlite(code: code, context: "writeStep")
            }
        }

        fileprivate func execute(_ sql: String) throws { try execute(sql, bindings: []) }

        private func execute(_ sql: String, bindings: [Binding]) throws {
            try withStatement(sql) { statement in
                try bind(bindings, to: statement)
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { return }
                    guard code == SQLITE_ROW else {
                        throw UndoHistoryDatabaseError.sqlite(code: code, context: "execute")
                    }
                }
            }
        }

        private func query(_ sql: String, bindings: [Binding] = [], _ row: (OpaquePointer) throws -> Void) throws {
            try withStatement(sql) { statement in
                try bind(bindings, to: statement)
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { return }
                    guard code == SQLITE_ROW else {
                        throw UndoHistoryDatabaseError.sqlite(code: code, context: "readStep")
                    }
                    try row(statement)
                }
            }
        }

        private func singleInteger(_ sql: String) throws -> Int64 {
            var result: Int64?
            try query(sql) { result = sqlite3_column_int64($0, 0) }
            guard let result else { throw UndoHistoryDatabaseError.invalidSnapshot("missingInteger") }
            return result
        }

        fileprivate func singleText(_ sql: String) throws -> String {
            var result: String?
            try query(sql) { result = try text($0, 0) }
            guard let result else { throw UndoHistoryDatabaseError.invalidSnapshot("missingText") }
            return result
        }

        private func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
            guard sqlite3_column_type(row, column) == SQLITE_TEXT,
                  let value = sqlite3_column_text(row, column) else {
                throw UndoHistoryDatabaseError.invalidSnapshot("textColumn")
            }
            let count = Int(sqlite3_column_bytes(row, column))
            guard let value = String(bytes: UnsafeBufferPointer(start: value, count: count), encoding: .utf8) else {
                throw UndoHistoryDatabaseError.invalidSnapshot("textEncoding")
            }
            return value
        }

        private func optionalText(_ row: OpaquePointer, _ column: Int32) throws -> String? {
            sqlite3_column_type(row, column) == SQLITE_NULL ? nil : try text(row, column)
        }

        private func blob(_ row: OpaquePointer, _ column: Int32) throws -> Data {
            guard sqlite3_column_type(row, column) == SQLITE_BLOB else {
                throw UndoHistoryDatabaseError.invalidSnapshot("blobColumn")
            }
            let count = Int(sqlite3_column_bytes(row, column))
            if count == 0 { return Data() }
            guard let bytes = sqlite3_column_blob(row, column) else {
                throw UndoHistoryDatabaseError.invalidSnapshot("blobBytes")
            }
            return Data(bytes: bytes, count: count)
        }
    }

    fileprivate struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    fileprivate struct Location {
        let url: URL
        let parentDescriptor: Int32
        let leaf: String

        init(url: URL, parentDescriptor: Int32) throws {
            let requested = url.standardizedFileURL
            // v2026.10.14: SQLite NOFOLLOW also rejects symlinks in parent components, including
            // Darwin's normal /var -> /private/var alias. Foundation's resolvingSymlinksInPath
            // standardizes that physical path back to /var, so use realpath on ONLY the parent.
            // Then prove it is the directory authorized by the borrowed fd. Never resolve the
            // leaf: a substituted database symlink must remain unsafe, not become a target.
            guard url.isFileURL else { throw UndoHistoryDatabaseError.unsafeFile("databaseName") }
            guard let resolvedParent = realpath(requested.deletingLastPathComponent().path, nil) else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "resolveParent", code: errno)
            }
            let parentPath = String(cString: resolvedParent)
            free(resolvedParent)
            self.url = URL(fileURLWithPath: parentPath, isDirectory: true)
                .appendingPathComponent(requested.lastPathComponent, isDirectory: false)
            self.parentDescriptor = parentDescriptor
            self.leaf = requested.lastPathComponent
            guard url.isFileURL, self.url.path.hasPrefix("/"), !leaf.isEmpty,
                  leaf != ".", leaf != "..", !leaf.contains("/"),
                  leaf.utf8.count <= Int(NAME_MAX) else {
                throw UndoHistoryDatabaseError.unsafeFile("databaseName")
            }
            try validateParent()
        }

        func validateParent() throws {
            var anchored = stat()
            var named = stat()
            guard fstat(parentDescriptor, &anchored) == 0 else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "parentDescriptor", code: errno)
            }
            guard lstat(url.deletingLastPathComponent().path, &named) == 0 else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "parentPath", code: errno)
            }
            guard anchored.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
                  anchored.st_dev == named.st_dev, anchored.st_ino == named.st_ino,
                  anchored.st_uid == geteuid() else {
                throw UndoHistoryDatabaseError.unsafeFile("parentIdentity")
            }
        }

        func prepareFile() throws {
            var metadata = stat()
            let probe = leaf.withCString { fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
            if probe == 0 { _ = try mainFileIdentity(); return }
            guard errno == ENOENT else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "databaseProbe", code: errno)
            }
            let descriptor = leaf.withCString {
                openat(parentDescriptor, $0, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "databaseCreate", code: errno)
            }
            if fsync(descriptor) != 0 {
                let code = errno
                if Darwin.close(descriptor) != 0 {
                    AmuxLog.error(.trash, "Undo SQLite cleanup created-file close failed errno=\(errno)")
                }
                throw UndoHistoryDatabaseError.fileSystem(stage: "databaseCreateSync", code: code)
            }
            guard Darwin.close(descriptor) == 0 else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "databaseCreateClose", code: errno)
            }
            guard fsync(parentDescriptor) == 0 else {
                throw UndoHistoryDatabaseError.fileSystem(stage: "databaseParentSync", code: errno)
            }
        }

        func mainFileIdentity() throws -> FileIdentity {
            guard let metadata = try secureMetadata(name: leaf) else {
                throw UndoHistoryDatabaseError.unsafeFile("missingDatabase")
            }
            return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
        }

        func validateSidecars() throws {
            for suffix in ["-journal", "-wal", "-shm"] {
                _ = try secureMetadata(name: leaf + suffix)
            }
        }

        private func secureMetadata(name: String) throws -> stat? {
            var metadata = stat()
            let probe = name.withCString { fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }
            if probe != 0 {
                if errno == ENOENT { return nil }
                throw UndoHistoryDatabaseError.fileSystem(stage: "fileMetadata", code: errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600 else {
                throw UndoHistoryDatabaseError.unsafeFile("notPrivateOwnedRegularSingleLink")
            }
            return metadata
        }
    }

    private static func logCleanup(stage: String, code: Int32) {
        AmuxLog.error(.trash, "Undo SQLite cleanup failed stage=\(stage) sqlite=\(code)")
    }
}
