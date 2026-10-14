import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AppUI

/// v2026.10.14: SQLite cutover must retain real legacy facts and their source bytes while
/// retiring the old writer. A verified PREPARED snapshot may be imported into the new database;
/// that does not grant the legacy WAL permission to overwrite an ambiguous canonical inode.
@MainActor
final class UndoHistoryDatabaseMigrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let historyURL: URL
        let legacyURL: URL
    }

    private struct LegacyDocument: Decodable {
        let schemaVersion: Int
        let records: [UndoHistoryStore.Record]
    }

    private struct PreparedFixture {
        let fixture: Fixture
        let stageURL: URL
        let stagedBytes: Data
        let tornBytes: Data
        let expectedRecords: [UndoHistoryStore.Record]
    }

    private enum ForeignChange: CaseIterable {
        case completeDocumentOnSameInode
        case replacementInodeWithSamePrefix
        case tamperedPreparedStage
    }

    /// Hooks execute inside the storage worker; every mutable observation is guarded by lock.
    private final class CutoverHookEvidence: @unchecked Sendable {
        private let lock = NSLock()
        private var hitCount = 0
        private var failures: [String] = []

        func recordHit() {
            lock.lock()
            defer { lock.unlock() }
            hitCount += 1
        }

        func recordFailure(_ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            failures.append(String(describing: error))
        }

        var observation: (hits: Int, failures: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (hitCount, failures)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UndoDatabaseMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            // Only this test's isolated storage and fake Trash fixtures are removed.
            try FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            historyURL: root.appendingPathComponent("current/UndoHistory.json"),
            legacyURL: root.appendingPathComponent("legacy/UndoHistory.json")
        )
    }

    private func pair(named name: String, in fixture: Fixture) throws -> UndoHistoryStore.Record.FilePair {
        let trashed = fixture.root.appendingPathComponent("trashed-\(name).txt")
        try Data("identity fixture \(name)".utf8).write(to: trashed)
        let pair = UndoHistoryStore.Record.FilePair(
            original: fixture.root.appendingPathComponent("original-\(name).txt").path,
            trashed: trashed.path
        )
        XCTAssertNotNil(pair.trashedIdentity, "The migration fixture must carry an actual filesystem identity")
        return pair
    }

    private func legacyStore(at url: URL, in fixture: Fixture) -> UndoHistoryStore {
        UndoHistoryStore(
            storeURL: url, allowedRestoreRoots: [fixture.root.path], persistenceFormat: .legacyJSON
        )
    }

    private func decodeLegacy(_ bytes: Data) throws -> LegacyDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LegacyDocument.self, from: bytes)
    }

    private func assertManifest(at historyURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any],
            file: file, line: line
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 5, file: file, line: line)
        XCTAssertEqual(object["storage"] as? String, "sqlite", file: file, line: line)
        XCTAssertEqual(
            object["database"] as? String, historyURL.appendingPathExtension("sqlite").lastPathComponent,
            file: file, line: line
        )
    }

    private func databaseTransaction<Value>(
        at historyURL: URL,
        _ body: (UndoHistoryDatabase.Transaction) throws -> Value
    ) throws -> Value {
        let parent = historyURL.deletingLastPathComponent()
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        // The fixture has no concurrent writers; inspect the same adapter used by the store.
        return try UndoHistoryDatabase.withTransaction(
            at: historyURL.appendingPathExtension("sqlite"), parentDescriptor: descriptor, body
        )
    }

    private func archiveKey(for bytes: Data) -> String {
        "migration.archive." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func assertArchived(_ bytes: Data, at historyURL: URL) throws {
        try databaseTransaction(at: historyURL) { database in
            XCTAssertEqual(try database.metadata(name: archiveKey(for: bytes)), bytes)
            XCTAssertNotNil(try database.metadata(name: "migration.complete"))
        }
    }

    private func objectIdentity(at url: URL) throws -> TrashObjectIdentity {
        let probe = TrashObjectIdentity.probe(path: url.path)
        guard case .present(let identity) = probe else {
            throw CocoaError(.fileReadUnknown)
        }
        return identity
    }

    private func controlURLs(nextTo historyURL: URL) -> [URL] {
        let parent = historyURL.deletingLastPathComponent()
        return [
            ".UndoHistory.schema4-cas.stage-0", ".UndoHistory.schema4-cas.stage-1",
            ".UndoHistory.schema4-cas.marker-0", ".UndoHistory.schema4-cas.marker-1"
        ].map { parent.appendingPathComponent($0) }
    }

    private func preparedStage(nextTo historyURL: URL) throws -> URL {
        let markers = try controlURLs(nextTo: historyURL).suffix(2).map { url -> (UInt64, [String: Any]) in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])
            let generation = try XCTUnwrap(payload["generation"] as? NSNumber).uint64Value
            return (generation, payload)
        }
        let newest = try XCTUnwrap(markers.max { $0.0 < $1.0 })
        XCTAssertEqual(newest.1["phase"] as? String, "prepared")
        let name = try XCTUnwrap(newest.1["stageName"] as? String)
        return historyURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func makePreparedFixture(interruption: String) throws -> PreparedFixture {
        let fixture = try makeFixture()
        let incoming = legacyStore(at: fixture.legacyURL, in: fixture)
        incoming.addRecord(source: "incoming", filePairs: [try pair(named: "incoming", in: fixture)])
        let current = legacyStore(at: fixture.historyURL, in: fixture)
        current.addRecord(source: "current", filePairs: [try pair(named: "current", in: fixture)])
        XCTAssertEqual(incoming.storageState, .ready)
        XCTAssertEqual(current.storageState, .ready)
        let identity = try objectIdentity(at: fixture.historyURL)

        XCTAssertEqual(
            UndoHistoryStore.migrateLegacyStoreIfNeeded(
                from: fixture.legacyURL, to: fixture.historyURL,
                transactionInterruptionHookForTesting: { $0 == interruption }
            ),
            .rejected(.writeFailed), interruption
        )
        XCTAssertEqual(try objectIdentity(at: fixture.historyURL), identity)
        let stage = try preparedStage(nextTo: fixture.historyURL)
        let stagedBytes = try Data(contentsOf: stage)
        let tornBytes = try Data(contentsOf: fixture.historyURL)
        XCTAssertLessThan(tornBytes.count, stagedBytes.count)
        XCTAssertTrue(stagedBytes.starts(with: tornBytes))
        let records = try decodeLegacy(stagedBytes).records
        XCTAssertEqual(Set(records.map(\.source)), ["incoming", "current"])
        XCTAssertTrue(records.flatMap(\.filePairs).allSatisfy { $0.trashedIdentity != nil })
        return PreparedFixture(
            fixture: fixture, stageURL: stage, stagedBytes: stagedBytes,
            tornBytes: tornBytes, expectedRecords: records
        )
    }

    /// Change bytes without replacing the fixture inode, so the negative cases isolate content
    /// authority from object identity. Every path supplied here belongs to a temporary fixture.
    private func rewriteInPlace(_ bytes: Data, at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func testLegacyFactsAndBytesSurviveCutoverAndOldWriterCannotForkHistory() throws {
        let fixture = try makeFixture()
        let oldWriter = legacyStore(at: fixture.historyURL, in: fixture)
        let originalPair = try pair(named: "original", in: fixture)
        oldWriter.addRecord(source: "before-cutover", filePairs: [originalPair])
        XCTAssertEqual(oldWriter.storageState, .ready)
        let originalBytes = try Data(contentsOf: fixture.historyURL)
        let originalDocument = try decodeLegacy(originalBytes)
        XCTAssertEqual(originalDocument.schemaVersion, 4)

        let upgraded = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
        XCTAssertEqual(upgraded.storageState, .ready)
        XCTAssertEqual(upgraded.history, originalDocument.records)
        XCTAssertEqual(upgraded.history.first?.filePairs, [originalPair])
        try assertManifest(at: fixture.historyURL)
        try assertArchived(originalBytes, at: fixture.historyURL)
        let manifest = try Data(contentsOf: fixture.historyURL)

        let oldReader = legacyStore(at: fixture.historyURL, in: fixture)
        XCTAssertNotEqual(oldReader.storageState, .ready)
        oldWriter.addRecord(source: "stale-old-write", filePairs: [try pair(named: "stale", in: fixture)])
        XCTAssertNotEqual(oldWriter.storageState, .ready, "An old in-memory writer must not fork JSON history after cutover")
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), manifest)
        try databaseTransaction(at: fixture.historyURL) { database in
            XCTAssertEqual(try database.loadSnapshot()?.records, originalDocument.records)
        }

        let nextPair = try pair(named: "next", in: fixture)
        upgraded.addRecord(source: "after-cutover", filePairs: [nextPair])
        XCTAssertEqual(upgraded.storageState, .ready)
        XCTAssertEqual(upgraded.history.map(\.source), ["after-cutover", "before-cutover"])
        let reopened = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
        XCTAssertEqual(reopened.storageState, .ready)
        // v2026.10.14: persisted facts round-trip exactly, but an old process's availability
        // observation never grants restore authority in a new one. Both fixtures need re-probing.
        let expectedReopened = upgraded.history.map { record in
            UndoHistoryStore.Record(
                id: record.id, timestamp: record.timestamp, source: record.source,
                filePairs: record.filePairs, recoveryStates: [.init(status: .checking)],
                journalOperationID: record.journalOperationID
            )
        }
        XCTAssertEqual(reopened.history, expectedReopened)
        XCTAssertEqual(reopened.history.last?.id, originalDocument.records.first?.id)
        XCTAssertEqual(reopened.history.flatMap(\.filePairs), [nextPair, originalPair])
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), manifest)
        try assertArchived(originalBytes, at: fixture.historyURL)
    }

    func testVerifiedPreparedSnapshotImportsBothTornBoundariesWithoutWeakeningLegacyWAL() throws {
        for interruption in ["afterDestinationTruncate", "afterDestinationPartialWrite"] {
            let prepared = try makePreparedFixture(interruption: interruption)
            let fixture = prepared.fixture
            XCTAssertEqual(
                UndoHistoryStore.migrateLegacyStoreIfNeeded(from: fixture.legacyURL, to: fixture.historyURL),
                .rejected(.writeFailed),
                "The legacy WAL still cannot overwrite ambiguous canonical bytes"
            )
            XCTAssertEqual(legacyStore(at: fixture.historyURL, in: fixture).storageState, .writeFailed)
            XCTAssertEqual(try Data(contentsOf: fixture.historyURL), prepared.tornBytes)
            XCTAssertEqual(try Data(contentsOf: prepared.stageURL), prepared.stagedBytes)

            let upgraded = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
            XCTAssertEqual(upgraded.storageState, .ready, interruption)
            XCTAssertEqual(upgraded.history, prepared.expectedRecords, interruption)
            try assertManifest(at: fixture.historyURL)
            try assertArchived(prepared.tornBytes, at: fixture.historyURL)
            let reopened = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
            XCTAssertEqual(reopened.storageState, .ready)
            XCTAssertEqual(reopened.history, prepared.expectedRecords)
        }
    }

    func testPreparedImportRejectsForeignCanonicalAndTamperedStageWithoutChangingEvidence() throws {
        for change in ForeignChange.allCases {
            let prepared = try makePreparedFixture(interruption: "afterDestinationPartialWrite")
            let fixture = prepared.fixture
            let canonicalIdentity = try objectIdentity(at: fixture.historyURL)
            switch change {
            case .completeDocumentOnSameInode:
                let foreignURL = fixture.root.appendingPathComponent("foreign/UndoHistory.json")
                let foreign = legacyStore(at: foreignURL, in: fixture)
                foreign.addRecord(source: "foreign", filePairs: [try pair(named: "foreign", in: fixture)])
                XCTAssertEqual(foreign.storageState, .ready)
                let foreignBytes = try Data(contentsOf: foreignURL)
                XCTAssertEqual(try decodeLegacy(foreignBytes).records.map(\.source), ["foreign"])
                try rewriteInPlace(foreignBytes, at: fixture.historyURL)
                XCTAssertEqual(try objectIdentity(at: fixture.historyURL), canonicalIdentity)

            case .replacementInodeWithSamePrefix:
                let held = fixture.root.appendingPathComponent("held-torn-inode.json")
                try FileManager.default.moveItem(at: fixture.historyURL, to: held)
                try prepared.tornBytes.write(to: fixture.historyURL)
                XCTAssertEqual(Darwin.chmod(fixture.historyURL.path, 0o600), 0)
                XCTAssertNotEqual(try objectIdentity(at: fixture.historyURL), canonicalIdentity)
                XCTAssertEqual(try Data(contentsOf: held), prepared.tornBytes)

            case .tamperedPreparedStage:
                let stageIdentity = try objectIdentity(at: prepared.stageURL)
                var modified = prepared.stagedBytes
                modified.append(contentsOf: [0x20])
                // Trailing whitespace keeps a complete valid JSON document, while changing the
                // checksum committed by PREPARED. Decodability alone must not authorize import.
                XCTAssertEqual(try decodeLegacy(modified).records, prepared.expectedRecords)
                try rewriteInPlace(modified, at: prepared.stageURL)
                XCTAssertEqual(try objectIdentity(at: prepared.stageURL), stageIdentity)
            }
            let canonicalBefore = try Data(contentsOf: fixture.historyURL)
            let controls = try controlURLs(nextTo: fixture.historyURL).map { ($0, try Data(contentsOf: $0)) }

            let upgraded = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
            XCTAssertNotEqual(upgraded.storageState, .ready, "Foreign evidence must not be accepted: \(change)")
            XCTAssertTrue(upgraded.history.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.historyURL), canonicalBefore)
            for (url, bytes) in controls {
                XCTAssertEqual(try Data(contentsOf: url), bytes, "Rejected import must preserve WAL evidence")
            }
            try databaseTransaction(at: fixture.historyURL) { database in
                XCTAssertNil(try database.loadSnapshot())
                XCTAssertNil(try database.metadata(name: "migration.complete"))
                XCTAssertNil(try database.metadata(name: archiveKey(for: canonicalBefore)))
            }
        }
    }

    func testOldWriterExtensionBetweenImportAndCutoverIsMergedWithoutForking() throws {
        let fixture = try makeFixture()
        let oldWriter = legacyStore(at: fixture.historyURL, in: fixture)
        oldWriter.addRecord(source: "before-import", filePairs: [try pair(named: "first", in: fixture)])
        let originalBytes = try Data(contentsOf: fixture.historyURL)
        let originalIdentity = try objectIdentity(at: fixture.historyURL)
        XCTAssertEqual(UndoHistoryStore.migrateDatabaseForTesting(at: fixture.historyURL) {
            $0 == "beforeDescriptorOpen"
        }, .writeFailed)

        oldWriter.addRecord(source: "while-upgrade-interrupted", filePairs: [try pair(named: "later", in: fixture)])
        XCTAssertEqual(oldWriter.storageState, .ready)
        XCTAssertEqual(try objectIdentity(at: fixture.historyURL), originalIdentity)
        let extendedBytes = try Data(contentsOf: fixture.historyURL)
        let expected = try decodeLegacy(extendedBytes).records
        let upgraded = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
        XCTAssertEqual(upgraded.storageState, .ready)
        XCTAssertEqual(upgraded.history, expected)
        XCTAssertEqual(upgraded.history.count, 2)
        try assertManifest(at: fixture.historyURL)
        try assertArchived(originalBytes, at: fixture.historyURL)
        try assertArchived(extendedBytes, at: fixture.historyURL)
    }

    func testFileAppearingBetweenPendingSourceCheckAndReloadIsNotAdopted() throws {
        let fixture = try makeFixture()
        let foreignWriter = legacyStore(at: fixture.legacyURL, in: fixture)
        foreignWriter.addRecord(source: "external", filePairs: [try pair(named: "external", in: fixture)])
        let foreignBytes = try Data(contentsOf: fixture.legacyURL)
        XCTAssertEqual(UndoHistoryStore.migrateDatabaseForTesting(at: fixture.historyURL) {
            $0 == "beforeFirstPublish"
        }, .writeFailed)
        let evidence = CutoverHookEvidence()
        let destination = fixture.historyURL
        XCTAssertEqual(UndoHistoryStore.migrateDatabaseForTesting(at: fixture.historyURL) { boundary in
            guard boundary == "beforePendingSourceReload" else { return false }
            evidence.recordHit()
            do { try foreignBytes.write(to: destination) }
            catch { evidence.recordFailure(error) }
            return false
        }, .writeFailed)
        XCTAssertEqual(evidence.observation.hits, 1)
        XCTAssertTrue(evidence.observation.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), foreignBytes)
        let reopened = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
        XCTAssertNotEqual(reopened.storageState, .ready)
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), foreignBytes)
        try databaseTransaction(at: fixture.historyURL) { database in
            XCTAssertEqual(try database.loadSnapshot()?.records, [])
            XCTAssertNil(try database.metadata(name: "migration.complete"))
            XCTAssertNil(try database.metadata(name: archiveKey(for: foreignBytes)))
        }
    }

    func testInterruptedDatabaseCutoverResumesWithoutLosingImportedFactsOrArchive() throws {
        for interruption in [
            "beforeFirstPublish", "beforeDescriptorOpen", "afterDescriptorOpen",
            "afterManifestTruncate", "afterManifestPartialWrite", "afterManifestWrite"
        ] {
            let fixture = try makeFixture()
            let originalBytes: Data?
            let expectedRecords: [UndoHistoryStore.Record]
            if interruption == "beforeFirstPublish" {
                // Exclusive first publication only applies when there is no legacy pathname.
                // The complete fact here is an empty initialized history, with no source archive.
                originalBytes = nil
                expectedRecords = []
            } else {
                let seed = legacyStore(at: fixture.historyURL, in: fixture)
                seed.addRecord(source: "before-manifest", filePairs: [try pair(named: "manifest", in: fixture)])
                XCTAssertEqual(seed.storageState, .ready)
                let bytes = try Data(contentsOf: fixture.historyURL)
                originalBytes = bytes
                expectedRecords = try decodeLegacy(bytes).records
            }
            let evidence = CutoverHookEvidence()
            XCTAssertEqual(
                UndoHistoryStore.migrateDatabaseForTesting(at: fixture.historyURL) { boundary in
                    guard boundary == interruption else { return false }
                    evidence.recordHit()
                    return true
                },
                .writeFailed, interruption
            )
            XCTAssertEqual(evidence.observation.hits, 1, "The requested cutover boundary must actually run")
            try databaseTransaction(at: fixture.historyURL) { database in
                XCTAssertEqual(try database.loadSnapshot()?.records, expectedRecords)
                XCTAssertNil(try database.metadata(name: "migration.complete"))
                if let originalBytes {
                    XCTAssertEqual(try database.metadata(name: archiveKey(for: originalBytes)), originalBytes)
                }
                if interruption == "afterManifestTruncate" || interruption == "afterManifestPartialWrite" {
                    let manifest = try XCTUnwrap(try database.metadata(name: "migration.manifest"))
                    let current = try Data(contentsOf: fixture.historyURL)
                    XCTAssertLessThan(current.count, manifest.count)
                    XCTAssertTrue(manifest.starts(with: current))
                    if interruption == "afterManifestTruncate" { XCTAssertTrue(current.isEmpty) }
                    else { XCTAssertFalse(current.isEmpty) }
                }
            }

            let reopened = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
            XCTAssertEqual(reopened.storageState, .ready, interruption)
            XCTAssertEqual(reopened.history, expectedRecords, interruption)
            try assertManifest(at: fixture.historyURL)
            if let originalBytes {
                try assertArchived(originalBytes, at: fixture.historyURL)
            } else {
                try databaseTransaction(at: fixture.historyURL) { database in
                    XCTAssertNotNil(try database.metadata(name: "migration.complete"))
                    XCTAssertNil(try database.metadata(name: archiveKey(for: Data())))
                }
            }
            let secondOpen = UndoHistoryStore(storeURL: fixture.historyURL, allowedRestoreRoots: [fixture.root.path])
            XCTAssertEqual(secondOpen.storageState, .ready)
            XCTAssertEqual(secondOpen.history, expectedRecords)
        }
    }

    func testCanonicalReplacementAroundCutoverDescriptorOpenPreservesBothObjects() throws {
        for boundary in ["beforeDescriptorOpen", "afterDescriptorOpen"] {
            let fixture = try makeFixture()
            let seed = legacyStore(at: fixture.historyURL, in: fixture)
            seed.addRecord(source: "original-object", filePairs: [try pair(named: "held-original", in: fixture)])
            XCTAssertEqual(seed.storageState, .ready)
            let originalBytes = try Data(contentsOf: fixture.historyURL)
            let originalRecords = try decodeLegacy(originalBytes).records
            let originalIdentity = try objectIdentity(at: fixture.historyURL)
            let foreignURL = fixture.root.appendingPathComponent("foreign/UndoHistory.json")
            let foreign = legacyStore(at: foreignURL, in: fixture)
            foreign.addRecord(source: "external-object", filePairs: [try pair(named: "external-object", in: fixture)])
            XCTAssertEqual(foreign.storageState, .ready)
            let externalBytes = try Data(contentsOf: foreignURL)
            let historyURL = fixture.historyURL
            let heldURL = fixture.root.appendingPathComponent("held-original.json")
            let evidence = CutoverHookEvidence()

            XCTAssertEqual(
                UndoHistoryStore.migrateDatabaseForTesting(at: historyURL) { observed in
                    guard observed == boundary else { return false }
                    evidence.recordHit()
                    do {
                        try FileManager.default.moveItem(at: historyURL, to: heldURL)
                        try externalBytes.write(to: historyURL)
                        guard Darwin.chmod(historyURL.path, 0o600) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        // Continue the real cutover: its descriptor and namespace checks must
                        // reject the replacement, independently of hook cancellation semantics.
                        return false
                    } catch {
                        evidence.recordFailure(error)
                        return true
                    }
                },
                .writeFailed, boundary
            )
            XCTAssertEqual(evidence.observation.hits, 1)
            XCTAssertEqual(evidence.observation.failures, [])
            XCTAssertEqual(try Data(contentsOf: historyURL), externalBytes)
            XCTAssertEqual(try Data(contentsOf: heldURL), originalBytes)
            XCTAssertEqual(try objectIdentity(at: heldURL), originalIdentity)
            let externalIdentity = try objectIdentity(at: historyURL)
            XCTAssertNotEqual(externalIdentity, originalIdentity)
            try databaseTransaction(at: historyURL) { database in
                XCTAssertEqual(try database.loadSnapshot()?.records, originalRecords)
                XCTAssertEqual(try database.metadata(name: archiveKey(for: originalBytes)), originalBytes)
                XCTAssertNil(try database.metadata(name: "migration.complete"))
            }

            let reopened = UndoHistoryStore(storeURL: historyURL, allowedRestoreRoots: [fixture.root.path])
            XCTAssertNotEqual(reopened.storageState, .ready, "A restart must not adopt an unrelated replacement")
            XCTAssertEqual(try Data(contentsOf: historyURL), externalBytes)
            XCTAssertEqual(try objectIdentity(at: historyURL), externalIdentity)
            XCTAssertEqual(try Data(contentsOf: heldURL), originalBytes)
            XCTAssertEqual(try objectIdentity(at: heldURL), originalIdentity)
        }
    }
}
