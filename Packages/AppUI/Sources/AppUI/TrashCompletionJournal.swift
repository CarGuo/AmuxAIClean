import Darwin
import CryptoKit
import Foundation
import LogKit

/// Shared crash-durable replacement primitive for every file participating in the Trash/Undo
/// acknowledgment protocol.
///
/// v2026.07.18 root-cause fix: `Data.write(.atomic)` only promises a same-filesystem rename. It
/// does not prove that either the new bytes or the parent directory entry survived sudden power
/// loss. A ledger claim must have the same durability as the callback journal and Undo receipt,
/// otherwise AppKit may receive a destructive request while restart observes the old `reserved`
/// envelope. Callers still provide their own stable flock around read-modify-write; this helper
/// supplies full-write + file fsync + atomic rename + parent fsync.
enum TrashDurableFileWriter {
    /// Descriptor-bound variant for stores whose lock protocol already owns the parent directory.
    /// It deliberately recognizes only legacy `.<prefix>.<UPPERCASE-UUID>.tmp` regular files;
    /// fixed WAL slots, malformed lookalikes, hard links and symlinks are never candidates.
    nonisolated static func removeAbandonedTemporaryFiles(
        inParentDescriptor parentDescriptor: Int32,
        temporaryPrefix: String,
        logContext: String
    ) {
        let enumerationDescriptor = Darwin.dup(parentDescriptor)
        guard enumerationDescriptor >= 0 else {
            AmuxLog.warning(.trash, "\(logContext) temp sweep dup failed errno=\(errno)")
            return
        }
        guard let directory = fdopendir(enumerationDescriptor) else {
            let code = errno
            Darwin.close(enumerationDescriptor)
            AmuxLog.warning(.trash, "\(logContext) temp sweep fdopendir failed errno=\(code)")
            return
        }
        defer { closedir(directory) }

        var removedAny = false
        while true {
            errno = 0
            guard let rawEntry = readdir(directory) else {
                if errno != 0 {
                    AmuxLog.warning(.trash, "\(logContext) temp sweep readdir failed errno=\(errno)")
                }
                break
            }
            var nameStorage = rawEntry.pointee.d_name
            let nameLength = Int(rawEntry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &nameStorage) { bytes in
                String(decoding: bytes.prefix(nameLength), as: UTF8.self)
            }
            guard isCanonicalTemporaryFilename(
                name,
                temporaryPrefix: temporaryPrefix
            ) else { continue }

            var metadata = stat()
            let status = name.withCString {
                fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                let code = errno
                if code != ENOENT {
                    AmuxLog.warning(
                        .trash,
                        "\(logContext) temp sweep metadata failed name=\(name) errno=\(code)"
                    )
                }
                continue
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_uid == geteuid() else { continue }
            let removed = name.withCString { unlinkat(parentDescriptor, $0, 0) }
            guard removed == 0 else {
                let code = errno
                if code != ENOENT {
                    AmuxLog.warning(
                        .trash,
                        "\(logContext) temp sweep unlink failed name=\(name) errno=\(code)"
                    )
                }
                continue
            }
            removedAny = true
        }

        // v2026.07.20 P1: the old atomic writer could leave a committed directory entry behind
        // after a crash. Sweep only while holding the store flock, then durably persist removal
        // through the already anchored parent descriptor before any recovery/read proceeds.
        if removedAny, Darwin.fsync(parentDescriptor) != 0 {
            AmuxLog.warning(.trash, "\(logContext) temp sweep parent fsync failed errno=\(errno)")
        }
    }

    /// Removes only crash leftovers created by `replace`. The caller must already hold the
    /// destination store's stable cross-process flock; putting this sweep inside `replace` would
    /// allow one writer to unlink another writer's still-open temporary file.
    ///
    /// v2026.07.18 P2 root-cause fix: a crash after `open(O_EXCL)` but before rename leaves a
    /// private JSON sibling behind forever. Match the writer's exact canonical
    /// `.<prefix>.<UUID>.tmp` grammar and a no-follow regular-file type; malformed lookalikes,
    /// directories and symlinks are user-owned namespace and are never removed.
    nonisolated static func removeAbandonedTemporaryFiles(
        nextTo destinationURL: URL,
        temporaryPrefix: String,
        logContext: String
    ) {
        let parent = destinationURL.deletingLastPathComponent()
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        } catch {
            AmuxLog.warning(.trash, "\(logContext) temp sweep enumerate failed error=\(error)")
            return
        }

        var removedAny = false
        for name in names where isCanonicalTemporaryFilename(
            name,
            temporaryPrefix: temporaryPrefix
        ) {
            let candidate = parent.appendingPathComponent(name, isDirectory: false)
            var metadata = stat()
            guard candidate.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
                let code = errno
                if code != ENOENT {
                    AmuxLog.warning(
                        .trash,
                        "\(logContext) temp sweep metadata failed name=\(name) errno=\(code)"
                    )
                }
                continue
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
            guard candidate.path.withCString({ Darwin.unlink($0) }) == 0 else {
                let code = errno
                if code != ENOENT {
                    AmuxLog.warning(
                        .trash,
                        "\(logContext) temp sweep unlink failed name=\(name) errno=\(code)"
                    )
                }
                continue
            }
            removedAny = true
        }

        // The stale rows are non-authoritative, so an fsync failure must not block the store RMW;
        // it is logged explicitly and the next flock owner can retry any directory entry that
        // survived a crash.
        guard removedAny else { return }
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            AmuxLog.warning(.trash, "\(logContext) temp sweep parent open failed errno=\(errno)")
            return
        }
        defer { Darwin.close(parentDescriptor) }
        if Darwin.fsync(parentDescriptor) != 0 {
            AmuxLog.warning(.trash, "\(logContext) temp sweep parent fsync failed errno=\(errno)")
        }
    }

    nonisolated private static func isCanonicalTemporaryFilename(
        _ name: String,
        temporaryPrefix: String
    ) -> Bool {
        let leading = ".\(temporaryPrefix)."
        let trailing = ".tmp"
        guard name.hasPrefix(leading), name.hasSuffix(trailing) else { return false }
        let tokenStart = name.index(name.startIndex, offsetBy: leading.count)
        let tokenEnd = name.index(name.endIndex, offsetBy: -trailing.count)
        let token = String(name[tokenStart..<tokenEnd])
        guard token.count == 36, let identifier = UUID(uuidString: token) else { return false }
        // `replace` writes UUID.uuidString, whose canonical spelling is uppercase with hyphens.
        // Requiring that exact spelling materially narrows deletion in a user-writable directory.
        return identifier.uuidString == token
    }

    nonisolated static func replace(
        _ data: Data,
        at url: URL,
        temporaryPrefix: String,
        logContext: String
    ) -> Bool {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            AmuxLog.error(.trash, "\(logContext) parent create failed error=\(error)")
            return false
        }
        let temporary = parent.appendingPathComponent(
            ".\(temporaryPrefix).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            AmuxLog.error(.trash, "\(logContext) temp open failed errno=\(errno)")
            return false
        }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed { temporary.path.withCString { _ = Darwin.unlink($0) } }
        }

        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0 else {
            AmuxLog.error(.trash, "\(logContext) write/fsync failed errno=\(errno)")
            return false
        }
        let renameResult = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renameResult == 0 else {
            AmuxLog.error(.trash, "\(logContext) atomic rename failed errno=\(errno)")
            return false
        }
        renamed = true

        let parentFD = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentFD >= 0 else {
            AmuxLog.error(.trash, "\(logContext) parent open failed errno=\(errno)")
            return false
        }
        defer { Darwin.close(parentFD) }
        guard fsync(parentFD) == 0 else {
            AmuxLog.error(.trash, "\(logContext) parent fsync failed errno=\(errno)")
            return false
        }
        return true
    }
}

/// v2026.07.18: one filesystem object identity shared by the pre-submit ledger,
/// durable Undo journal, and restore executor. A path is never an object capability.
public struct TrashObjectIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt16
    /// Optional for schema-2 pending-ledger rows written before this shared identity existed.
    public let birthTimeSeconds: Int64?
    public let birthTimeNanoseconds: Int64?
    public let generation: UInt32?

    public init(
        device: UInt64,
        inode: UInt64,
        fileType: UInt16,
        birthTimeSeconds: Int64? = nil,
        birthTimeNanoseconds: Int64? = nil,
        generation: UInt32? = nil
    ) {
        self.device = device
        self.inode = inode
        self.fileType = fileType
        self.birthTimeSeconds = birthTimeSeconds
        self.birthTimeNanoseconds = birthTimeNanoseconds
        self.generation = generation
    }

    init(metadata: stat) {
        self.init(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            fileType: UInt16(metadata.st_mode & mode_t(S_IFMT)),
            birthTimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
            birthTimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec),
            generation: UInt32(metadata.st_gen)
        )
    }

    /// New identities compare every available kernel discriminator. A migrated identity that
    /// predates birthtime/generation remains compatible with its original three-field contract,
    /// but it is never promoted into a stronger Undo capability.
    func matches(_ current: TrashObjectIdentity) -> Bool {
        guard device == current.device,
              inode == current.inode,
              fileType == current.fileType else { return false }
        if let birthTimeSeconds, birthTimeSeconds != current.birthTimeSeconds { return false }
        if let birthTimeNanoseconds, birthTimeNanoseconds != current.birthTimeNanoseconds {
            return false
        }
        if let generation, generation != current.generation { return false }
        return true
    }

    /// Cross-reboot APFS mount instances may receive a new `st_dev` while the underlying volume
    /// object (`inode`, `fileType`, `birthTimeSeconds`, `birthTimeNanoseconds`, `generation`) is
    /// unchanged. Legacy three-field identities without birthtime/generation still require exact
    /// `device` equality.
    func matchesAllowingMountDeviceRebase(_ current: TrashObjectIdentity) -> Bool {
        if matches(current) { return true }
        guard let birthTimeSeconds,
              let birthTimeNanoseconds,
              let generation else { return false }
        return inode == current.inode
            && fileType == current.fileType
            && birthTimeSeconds == current.birthTimeSeconds
            && birthTimeNanoseconds == current.birthTimeNanoseconds
            && generation == current.generation
    }

    enum Probe: Sendable, Equatable {
        case present(TrashObjectIdentity)
        case missing
        case unavailable(errno: Int32)
    }

    static func probe(path: String) -> Probe {
        var metadata = stat()
        errno = 0
        guard lstat(path, &metadata) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR
                ? .missing
                : .unavailable(errno: code)
        }
        return .present(TrashObjectIdentity(metadata: metadata))
    }
}

/// A system-confirmed move that has crossed the durable boundary but may not yet have been
/// merged into UndoHistory. `id` is deterministic per exact ledger attempt/path, so duplicate
/// AppKit callbacks cannot append a second logical transaction.
struct TrashUndoJournalEntry: Codable, Equatable, Sendable {
    let id: String
    let operationID: UUID
    let attemptID: UUID
    let originalPath: String
    let trashedPath: String
    let originalIdentity: TrashObjectIdentity
    /// Scope root frozen by the same deletion preflight that authorized `originalPath`.
    let restoreScopeRoot: String
    let recordedAt: Date

    init(
        operationID: UUID,
        attemptID: UUID,
        originalPath: String,
        trashedPath: String,
        originalIdentity: TrashObjectIdentity,
        restoreScopeRoot: String,
        recordedAt: Date = Date()
    ) {
        let normalizedOriginal = TrashPipeline.normalizePath(originalPath)
        let normalizedTrashed = TrashPipeline.normalizePath(trashedPath)
        self.id = Self.opaqueID(
            operationID: operationID,
            attemptID: attemptID,
            normalizedOriginalPath: normalizedOriginal,
            normalizedTrashedPath: normalizedTrashed
        )
        self.operationID = operationID
        self.attemptID = attemptID
        self.originalPath = normalizedOriginal
        self.trashedPath = normalizedTrashed
        self.originalIdentity = originalIdentity
        self.restoreScopeRoot = TrashPipeline.normalizePath(restoreScopeRoot)
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, operationID, attemptID, originalPath, trashedPath
        case originalIdentity, restoreScopeRoot, recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operationID = try container.decode(UUID.self, forKey: .operationID)
        let attemptID = try container.decode(UUID.self, forKey: .attemptID)
        let originalPath = TrashPipeline.normalizePath(
            try container.decode(String.self, forKey: .originalPath)
        )
        let trashedPath = TrashPipeline.normalizePath(
            try container.decode(String.self, forKey: .trashedPath)
        )
        let persistedID = try container.decode(String.self, forKey: .id)
        let opaqueID = Self.opaqueID(
            operationID: operationID,
            attemptID: attemptID,
            normalizedOriginalPath: originalPath,
            normalizedTrashedPath: trashedPath
        )
        let legacyOpaqueID = Self.legacyOpaqueID(
            operationID: operationID,
            attemptID: attemptID,
            normalizedOriginalPath: originalPath
        )
        let legacyID = Self.legacyPlaintextID(
            operationID: operationID,
            attemptID: attemptID,
            normalizedOriginalPath: originalPath
        )
        guard persistedID == opaqueID
                || persistedID == legacyOpaqueID
                || persistedID == legacyID else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Journal ID does not bind to the persisted operation and path"
            )
        }

        self.id = opaqueID
        self.operationID = operationID
        self.attemptID = attemptID
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.originalIdentity = try container.decode(
            TrashObjectIdentity.self,
            forKey: .originalIdentity
        )
        self.restoreScopeRoot = TrashPipeline.normalizePath(
            try container.decode(String.self, forKey: .restoreScopeRoot)
        )
        self.recordedAt = try container.decode(Date.self, forKey: .recordedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(originalPath, forKey: .originalPath)
        try container.encode(trashedPath, forKey: .trashedPath)
        try container.encode(originalIdentity, forKey: .originalIdentity)
        try container.encode(restoreScopeRoot, forKey: .restoreScopeRoot)
        try container.encode(recordedAt, forKey: .recordedAt)
    }

    /// v2026.07.18 transaction identity: a receipt is useful only if it binds the exact callback
    /// pair as well as operation/attempt. UUIDs plus NUL separators make the SHA-256 input
    /// unambiguous because POSIX paths cannot contain NUL; no absolute path survives in the key.
    static func opaqueID(
        operationID: UUID,
        attemptID: UUID,
        normalizedOriginalPath: String,
        normalizedTrashedPath: String
    ) -> String {
        let payload = Data(
            "v2\0\(operationID.uuidString)\0\(attemptID.uuidString)\0\(normalizedOriginalPath)\0\(normalizedTrashedPath)".utf8
        )
        let digest = SHA256.hash(data: payload)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyOpaqueID(
        operationID: UUID,
        attemptID: UUID,
        normalizedOriginalPath: String
    ) -> String {
        let payload = Data(
            "v1\0\(operationID.uuidString)\0\(attemptID.uuidString)\0\(normalizedOriginalPath)".utf8
        )
        let digest = SHA256.hash(data: payload)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyPlaintextID(
        operationID: UUID,
        attemptID: UUID,
        normalizedOriginalPath: String
    ) -> String {
        "\(operationID.uuidString):\(attemptID.uuidString):\(normalizedOriginalPath)"
    }

    var legacyPlaintextID: String {
        Self.legacyPlaintextID(
            operationID: operationID,
            attemptID: attemptID,
            normalizedOriginalPath: originalPath
        )
    }

    static func isOpaqueID(_ candidate: String) -> Bool {
        let bytes = Array(candidate.utf8)
        guard bytes.count == 71,
              Array(bytes.prefix(7)) == Array("sha256:".utf8) else { return false }
        return bytes.dropFirst(7).allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Migrates a schema-2 Undo pair without retaining its old path-bearing receipt key.
    /// The legacy layout has two fixed-width UUIDs, so the path suffix may safely contain `:`.
    static func migratePersistedID(
        _ persistedID: String,
        originalPath: String,
        trashedPath: String,
        persistedAttemptID: UUID?,
        expectedOperationID: UUID?
    ) -> (id: String, attemptID: UUID)? {
        let normalizedOriginal = TrashPipeline.normalizePath(originalPath)
        let normalizedTrashed = TrashPipeline.normalizePath(trashedPath)
        if !isOpaqueID(persistedID) {
            let characters = Array(persistedID)
            guard characters.count >= 74,
                  characters[36] == ":",
                  characters[73] == ":",
                  let operationID = UUID(uuidString: String(characters[0..<36])),
                  let attemptID = UUID(uuidString: String(characters[37..<73])),
                  expectedOperationID == nil || expectedOperationID == operationID,
                  persistedAttemptID == nil || persistedAttemptID == attemptID else {
                return nil
            }
            let persistedPath = TrashPipeline.normalizePath(String(characters.dropFirst(74)))
            guard persistedPath == normalizedOriginal else { return nil }
            return (opaqueID(
                operationID: operationID,
                attemptID: attemptID,
                normalizedOriginalPath: normalizedOriginal,
                normalizedTrashedPath: normalizedTrashed
            ), attemptID)
        }
        if let operationID = expectedOperationID,
           let attemptID = persistedAttemptID {
            let current = opaqueID(
                operationID: operationID,
                attemptID: attemptID,
                normalizedOriginalPath: normalizedOriginal,
                normalizedTrashedPath: normalizedTrashed
            )
            let legacy = legacyOpaqueID(
                operationID: operationID,
                attemptID: attemptID,
                normalizedOriginalPath: normalizedOriginal
            )
            guard persistedID == current || persistedID == legacy else { return nil }
            return (current, attemptID)
        }
        // An old opaque digest without a persisted attempt is intentionally not guessed. The
        // caller may retain the visible history fact without a receipt and later upgrade it from
        // an exact pending journal row.
        return nil
    }

    static func validatesOpaqueID(
        _ persistedID: String,
        operationID: UUID,
        attemptID: UUID,
        originalPath: String,
        trashedPath: String
    ) -> Bool {
        persistedID == opaqueID(
            operationID: operationID,
            attemptID: attemptID,
            normalizedOriginalPath: TrashPipeline.normalizePath(originalPath),
            normalizedTrashedPath: TrashPipeline.normalizePath(trashedPath)
        )
    }

    static func == (lhs: TrashUndoJournalEntry, rhs: TrashUndoJournalEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.operationID == rhs.operationID
            && lhs.attemptID == rhs.attemptID
            && lhs.originalPath == rhs.originalPath
            && lhs.trashedPath == rhs.trashedPath
            && lhs.originalIdentity == rhs.originalIdentity
            && lhs.restoreScopeRoot == rhs.restoreScopeRoot
        // `recordedAt` is observation metadata, not part of the deterministic callback fact.
        // A duplicate AppKit callback must remain an idempotent append instead of a collision.
    }
}

/// One durable view of the completion journal. `receiptPrunePendingIDs` is a subset of `entries`:
/// those callback facts have already crossed Undo + exact-ledger acknowledgement, so recovery must
/// prune the Undo receipt before it removes the last journal evidence.
struct TrashCompletionJournalSnapshot: Sendable, Equatable {
    let entries: [TrashUndoJournalEntry]
    let receiptPrunePendingIDs: Set<String>
}

/// A stable recovery lock may intentionally outlive the synchronous method that acquired it: the
/// protected replay includes an async Undo RMW. Release is idempotent so every terminal branch can
/// close the cross-process lease explicitly while `deinit` remains a final safety net.
final class TrashCompletionRecoveryLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(releaseAction: @escaping @Sendable () -> Void = {}) {
        self.releaseAction = releaseAction
    }

    func release() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit { release() }
}

protocol TrashCompletionJournaling: AnyObject, Sendable {
    /// Idempotent append. An existing ID with different contents is corruption and fails closed.
    func append(_ entries: [TrashUndoJournalEntry]) -> Bool
    func pendingEntries() -> [TrashUndoJournalEntry]?
    func snapshot() -> TrashCompletionJournalSnapshot?
    /// Durable phase transition. The entries remain present until their Undo receipts are gone.
    func markReceiptPrunePending(ids: Set<String>) -> Bool
    func remove(ids: Set<String>) -> Bool
    /// Same-process single-flight identity. Persistent journals override this with their path.
    var recoveryCoordinationKey: String { get }
    /// Cross-process serialization for the entire replay transaction, not just one JSON RMW.
    func acquireRecoveryLease() -> TrashCompletionRecoveryLease?
}

extension TrashCompletionJournaling {
    func snapshot() -> TrashCompletionJournalSnapshot? {
        pendingEntries().map {
            TrashCompletionJournalSnapshot(entries: $0, receiptPrunePendingIDs: [])
        }
    }

    func markReceiptPrunePending(ids: Set<String>) -> Bool { false }

    var recoveryCoordinationKey: String {
        "ephemeral:\(ObjectIdentifier(self).hashValue)"
    }

    func acquireRecoveryLease() -> TrashCompletionRecoveryLease? {
        TrashCompletionRecoveryLease()
    }
}

/// Cross-process durable handoff between `NSWorkspace.recycle` and UndoHistory. The JSON payload
/// is fsynced and atomically replaced, while a separate stable lock inode serializes every RMW.
///
/// `@unchecked Sendable` synchronization basis: all mutable encoder/decoder/file state is reached
/// only while `processLock` and the cross-process `<journal>.lock` flock are both held; URLs and
/// the injected writer closure are immutable Sendable values configured before publication.
final class PersistentTrashCompletionJournal: TrashCompletionJournaling, @unchecked Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        var entries: [String: TrashUndoJournalEntry]
        var receiptPrunePendingIDs: Set<String>

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, entries, receiptPrunePendingIDs
        }

        init(
            schemaVersion: Int,
            entries: [String: TrashUndoJournalEntry],
            receiptPrunePendingIDs: Set<String>
        ) {
            self.schemaVersion = schemaVersion
            self.entries = entries
            self.receiptPrunePendingIDs = receiptPrunePendingIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            entries = try container.decode(
                [String: TrashUndoJournalEntry].self,
                forKey: .entries
            )
            receiptPrunePendingIDs = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .receiptPrunePendingIDs
            ) ?? []
        }
    }

    static let shared = PersistentTrashCompletionJournal()

    private let fileURL: URL
    private let lockURL: URL
    private let recoveryLockURL: URL
    private let processLock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let durableWriter: @Sendable (Data, URL) -> Bool

    /// v2026.07.20 P0: production storage is reachable only through `shared` or the explicit
    /// Trash recovery domain. Tests must name a temporary URL instead of inheriting user state.
    private convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(fileURL: support
            .appendingPathComponent("AmuxAIClean", isDirectory: true)
            .appendingPathComponent("trash-completion-journal.json"))
    }

    init(
        fileURL: URL,
        durableWriter: @escaping @Sendable (Data, URL) -> Bool = PersistentTrashCompletionJournal.durableAtomicWrite
    ) {
        self.fileURL = fileURL
        self.lockURL = fileURL.appendingPathExtension("lock")
        self.recoveryLockURL = fileURL.appendingPathExtension("recovery.lock")
        self.durableWriter = durableWriter
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ entries: [TrashUndoJournalEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        guard entries.count == Set(entries.map(\.id)).count else {
            AmuxLog.error(.trash, "Trash completion journal duplicate IDs in one append")
            return false
        }
        return transaction { envelope in
            var changed = false
            for entry in entries {
                if let existing = envelope.entries[entry.id], existing != entry {
                    AmuxLog.error(.trash, "Trash completion journal ID collision id=\(entry.id)")
                    return false
                }
                if envelope.entries[entry.id] == nil {
                    envelope.entries[entry.id] = entry
                    changed = true
                }
            }
            return !changed || persist(envelope)
        } ?? false
    }

    func pendingEntries() -> [TrashUndoJournalEntry]? {
        snapshot()?.entries
    }

    func snapshot() -> TrashCompletionJournalSnapshot? {
        transaction { envelope in
            TrashCompletionJournalSnapshot(
                entries: Self.sortedEntries(envelope.entries.values),
                receiptPrunePendingIDs: envelope.receiptPrunePendingIDs
            )
        }
    }

    func markReceiptPrunePending(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return true }
        return transaction { envelope in
            guard ids.isSubset(of: Set(envelope.entries.keys)) else {
                AmuxLog.error(.trash, "Trash completion journal prune phase lost callback rows")
                return false
            }
            let priorCount = envelope.receiptPrunePendingIDs.count
            envelope.receiptPrunePendingIDs.formUnion(ids)
            return envelope.receiptPrunePendingIDs.count == priorCount || persist(envelope)
        } ?? false
    }

    func remove(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return true }
        return transaction { envelope in
            var changed = false
            for id in ids where envelope.entries.removeValue(forKey: id) != nil {
                envelope.receiptPrunePendingIDs.remove(id)
                changed = true
            }
            return !changed || persist(envelope)
        } ?? false
    }

    private func transaction<T>(_ body: (inout Envelope) -> T) -> T? {
        processLock.lock()
        defer { processLock.unlock() }
        var result: T?
        let completed = withLock {
            guard var envelope = load() else { return false }
            result = body(&envelope)
            return true
        }
        guard completed == true else { return nil }
        return result
    }

    private func load() -> Envelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Envelope(schemaVersion: 2, entries: [:], receiptPrunePendingIDs: [])
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 32 * 1_024 * 1_024 else {
                AmuxLog.error(.trash, "Trash completion journal exceeds 32 MiB path=\(fileURL.path)")
                return nil
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decoded = try decoder.decode(Envelope.self, from: data)
            guard decoded.schemaVersion == 1 || decoded.schemaVersion == 2 else {
                AmuxLog.error(.trash, "Trash completion journal schema is invalid")
                return nil
            }
            var migratedEntries: [String: TrashUndoJournalEntry] = [:]
            var needsOpaqueIDMigration = false
            for (persistedKey, entry) in decoded.entries {
                guard persistedKey == entry.id || persistedKey == entry.legacyPlaintextID else {
                    AmuxLog.error(.trash, "Trash completion journal key does not match entry")
                    return nil
                }
                if migratedEntries[entry.id] != nil {
                    AmuxLog.error(.trash, "Trash completion journal migrated ID collision")
                    return nil
                }
                migratedEntries[entry.id] = entry
                needsOpaqueIDMigration = needsOpaqueIDMigration || persistedKey != entry.id
            }
            guard decoded.receiptPrunePendingIDs.isSubset(of: Set(decoded.entries.keys)) else {
                AmuxLog.error(.trash, "Trash completion journal prune phase references missing rows")
                return nil
            }
            let migratedPruneIDs = Set(decoded.receiptPrunePendingIDs.compactMap { persistedID in
                decoded.entries[persistedID]?.id
            })
            guard migratedPruneIDs.count == decoded.receiptPrunePendingIDs.count else {
                AmuxLog.error(.trash, "Trash completion journal prune phase migration failed")
                return nil
            }
            let envelope = Envelope(
                schemaVersion: 2,
                entries: migratedEntries,
                receiptPrunePendingIDs: migratedPruneIDs
            )
            if (decoded.schemaVersion != 2 || needsOpaqueIDMigration), !persist(envelope) {
                AmuxLog.error(.trash, "Trash completion journal schema migration failed")
                return nil
            }
            return envelope
        } catch {
            AmuxLog.error(.trash, "Trash completion journal read failed path=\(fileURL.path) error=\(error)")
            return nil
        }
    }

    private func persist(_ envelope: Envelope) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(envelope)
            guard data.count <= 32 * 1_024 * 1_024 else {
                AmuxLog.error(.trash, "Trash completion journal encode exceeds 32 MiB")
                return false
            }
            guard durableWriter(data, fileURL) else {
                AmuxLog.error(.trash, "Trash completion journal durable write failed path=\(fileURL.path)")
                return false
            }
            return true
        } catch {
            AmuxLog.error(.trash, "Trash completion journal write failed path=\(fileURL.path) error=\(error)")
            return false
        }
    }

    private func withLock<T>(_ body: () -> T) -> T? {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            AmuxLog.error(.trash, "Trash completion journal lock directory failed error=\(error)")
            return nil
        }
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            AmuxLog.error(.trash, "Trash completion journal lock open failed errno=\(errno)")
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            AmuxLog.error(.trash, "Trash completion journal flock failed errno=\(errno)")
            return nil
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        TrashDurableFileWriter.removeAbandonedTemporaryFiles(
            nextTo: fileURL,
            temporaryPrefix: "trash-completion",
            logContext: "Trash completion journal"
        )
        return body()
    }

    /// Callback facts are not durable until both the replacement file and the containing
    /// directory entry have crossed fsync. Returning false after rename is conservative: the
    /// caller keeps the ledger generation, and startup replay may still discover the new file.
    nonisolated static func durableAtomicWrite(_ data: Data, to url: URL) -> Bool {
        TrashDurableFileWriter.replace(
            data,
            at: url,
            temporaryPrefix: "trash-completion",
            logContext: "Trash completion journal"
        )
    }

    var fileURLForTesting: URL { fileURL }

    var recoveryCoordinationKey: String {
        fileURL.standardizedFileURL.path
    }

    /// v2026.07.18 P1/P2 cross-process replay fix: the ordinary journal flock protects one JSON
    /// mutation only. Recovery must keep a second stable inode locked across journal inspection,
    /// async Undo merge, ledger acknowledgement, receipt prune and final empty proof; otherwise
    /// two App processes can both observe `replayable` and the late process can recreate a receipt.
    func acquireRecoveryLease() -> TrashCompletionRecoveryLease? {
        do {
            try FileManager.default.createDirectory(
                at: recoveryLockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            AmuxLog.error(.trash, "Trash recovery lock directory failed error=\(error)")
            return nil
        }
        let descriptor = recoveryLockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            AmuxLog.error(.trash, "Trash recovery lock open failed errno=\(errno)")
            return nil
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            AmuxLog.error(.trash, "Trash recovery flock failed errno=\(errno)")
            Darwin.close(descriptor)
            return nil
        }
        return TrashCompletionRecoveryLease {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    private static func sortedEntries<S: Sequence>(
        _ entries: S
    ) -> [TrashUndoJournalEntry] where S.Element == TrashUndoJournalEntry {
        entries.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.id < $1.id
        }
    }
}

/// Opaque exact-attempt finalizer. Undo must be durably merged before this capability is consumed.
/// `@unchecked Sendable` synchronization basis: `entries`, journal and ledger are immutable
/// Sendable references; the sole mutable flag is read/written only while `lock` is held.
final class TrashUndoCommitCapability: @unchecked Sendable {
    let entries: [TrashUndoJournalEntry]
    private let journal: any TrashCompletionJournaling
    private let ledger: any TrashPendingOperationLedger
    private let lock = NSLock()
    private var receiptPrunePendingGroupKeys: Set<String> = []
    private var finishedGroupKeys: Set<String> = []

    init(
        entries: [TrashUndoJournalEntry],
        journal: any TrashCompletionJournaling,
        ledger: any TrashPendingOperationLedger
    ) {
        self.entries = entries
        self.journal = journal
        self.ledger = ledger
    }

    /// v2026.07.18 P2 receipt-leak fix. A group advances only through durable monotonic phases:
    /// Undo record+receipt -> exact ledger ack -> journal prune-pending marker. The callback row
    /// stays present, so a crash can still prove which receipt must be removed.
    func prepareReceiptPruneAfterUndoPersisted() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let groups = Dictionary(grouping: entries) { entry in
            "\(entry.operationID.uuidString):\(entry.attemptID.uuidString)"
        }
        for key in groups.keys.sorted() {
            guard !receiptPrunePendingGroupKeys.contains(key),
                  !finishedGroupKeys.contains(key),
                  let group = groups[key],
                  let first = group.first else { continue }
            switch ledger.acknowledgeExactAttempt(
                paths: group.map(\.originalPath),
                operationID: first.operationID,
                attemptID: first.attemptID
            ) {
            case .applied, .alreadyAbsent:
                break
            case .conflict, .storageUnavailable:
                continue
            }
            let ids = Set(group.map(\.id))
            guard journal.markReceiptPrunePending(ids: ids) else { continue }
            receiptPrunePendingGroupKeys.insert(key)
        }
        return Set(receiptPrunePendingGroupKeys.flatMap { key in
            groups[key]?.map(\.id) ?? []
        })
    }

    /// Receipt pruning is idempotent and must cross its own durable Undo RMW before journal rows
    /// disappear. A failed remove leaves the prune-pending marker for startup replay.
    func finishAfterReceiptPruned(ids: Set<String>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let groups = Dictionary(grouping: entries) { entry in
            "\(entry.operationID.uuidString):\(entry.attemptID.uuidString)"
        }
        for key in receiptPrunePendingGroupKeys.sorted() {
            guard !finishedGroupKeys.contains(key), let group = groups[key] else { continue }
            let groupIDs = Set(group.map(\.id))
            guard groupIDs.isSubset(of: ids), journal.remove(ids: groupIDs) else { continue }
            finishedGroupKeys.insert(key)
        }
        return finishedGroupKeys.count == groups.count
    }

    var isFullyFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        let groupCount = Set(entries.map {
            "\($0.operationID.uuidString):\($0.attemptID.uuidString)"
        }).count
        return finishedGroupKeys.count == groupCount
    }

    var attemptIdentities: Set<TrashPendingAttemptIdentity> {
        Set(entries.map {
            TrashPendingAttemptIdentity(
                operationID: $0.operationID,
                attemptID: $0.attemptID
            )
        })
    }

    /// v2026.10.14: a live App is not a live finalizer. Once this exact owner has stopped,
    /// recovery may retry its durable callback facts in the same process. Unrelated active
    /// attempts and unknown AppKit submissions retain their ownership and evidence.
    @MainActor
    func persistAndFinish(source: String, in undoHistoryStore: UndoHistoryStore) async -> Bool {
        let persisted = await undoHistoryStore.addJournalEntriesDurably(source: source, entries: entries)
        let settled: Bool
        if persisted {
            settled = await finishDurablyAfterUndoPersisted(pruningReceiptsIn: undoHistoryStore)
        } else {
            settled = false
        }
        await Task.detached(priority: .utility) { [self] in
            let groups = Dictionary(grouping: entries) {
                TrashPendingAttemptIdentity(operationID: $0.operationID, attemptID: $0.attemptID)
            }
            for (attempt, group) in groups {
                ledger.releaseCompletedAttempt(
                    paths: group.map(\.originalPath), operationID: attempt.operationID,
                    attemptID: attempt.attemptID
                )
            }
        }.value
        return settled
    }

    private var finishedAttemptIdentities: Set<TrashPendingAttemptIdentity> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.compactMap { entry in
            let key = "\(entry.operationID.uuidString):\(entry.attemptID.uuidString)"
            guard finishedGroupKeys.contains(key) else { return nil }
            return TrashPendingAttemptIdentity(
                operationID: entry.operationID,
                attemptID: entry.attemptID
            )
        })
    }

    /// One owner for all live finalize call sites. Health becomes pending before the async receipt
    /// prune and remains exact-attempt blocked across mark/prune/remove failure. Successful groups
    /// resolve independently, so operation B can never clear operation A.
    @MainActor
    func finishDurablyAfterUndoPersisted(
        pruningReceiptsIn undoHistoryStore: UndoHistoryStore
    ) async -> Bool {
        // Drain callback/retry projections before touching their revisions. The FIFO predecessor
        // chain is the proof that no older pending event can arrive after terminal eviction.
        await TrashCompletionHealthTransitionQueue.shared.flush()
        let allAttempts = attemptIdentities
        undoHistoryStore.reportCompletionJournalSettlementPending(
            attempts: allAttempts,
            revision: Int.max - 1
        )
        let pruneIDs = prepareReceiptPruneAfterUndoPersisted()
        if !pruneIDs.isEmpty {
            let receiptsPruned = await undoHistoryStore.acknowledgeCompletionJournal(
                ids: pruneIDs
            )
            if receiptsPruned {
                _ = finishAfterReceiptPruned(ids: pruneIDs)
            }
        }

        let finished = finishedAttemptIdentities
        if !finished.isEmpty {
            undoHistoryStore.resolveCompletionJournalSettlement(
                attempts: finished,
                durablyBlocked: false,
                revision: .max
            )
            undoHistoryStore.retireCompletionJournalSettlementRevisions(
                attempts: finished
            )
        }
        let unfinished = allAttempts.subtracting(finished)
        if !unfinished.isEmpty {
            undoHistoryStore.reportCompletionJournalSettlementPending(
                attempts: unfinished,
                revision: Int.max - 1
            )
        }
        return unfinished.isEmpty
    }
}
