import Darwin
import Foundation
import LogKit

/// Stable `lstat(2)` identity frozen before a request may enter `NSWorkspace.recycle`.
///
/// **v2026.07.16 root-cause record**: a recycle completion can arrive after the UI wait
/// window or even after the App restarts. A path string alone is therefore not a safe
/// duplicate-submission key: the same path may now name a different inode. The persistent
/// ledger always binds a normalized path to `(device, inode, file type)`.
struct TrashPendingPathIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt16
}

/// Kernel-stable owner identity for one App process.
///
/// PID alone is not an ownership capability because macOS may reuse it after a process exits.
/// The start timestamp comes from `proc_bsdinfo` and makes an old ledger owner distinguishable
/// from a later process that happens to receive the same PID (v2026.07.16 cross-process fix).
struct TrashLedgerProcessIdentity: Codable, Hashable, Sendable {
    let pid: Int32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

enum TrashLedgerProcessLiveness: Sendable, Equatable {
    case active
    case inactive
    case unavailable
}

enum TrashPendingOperationStage: String, Codable, Hashable, Sendable {
    /// Reserved atomically with every sibling before any system call is queued.
    case reserved
    /// The submission queue obtained its claim and is inside the synchronous AppKit API.
    case submissionUnknown
    /// The synchronous AppKit call returned, but its completion callback has not arrived.
    case callbackPending
    /// An authoritative callback arrived for the exact active attempt.
    case callbackObserved
    /// The normal callback has resumed its caller, so that caller may start one diagnostic
    /// retry. Keeping the prior attempt ID closes the ABA window until the new claim replaces it.
    case retryReady
    /// The old path identity disappeared or was replaced after an unresolved operation. This
    /// tombstone is durable and can only be cleared by a future typed fresh-review capability.
    case needsFreshReview
}

enum TrashPendingInvalidationReason: String, Codable, Hashable, Sendable {
    case targetMissing
    case identityChanged
    /// The App exited after reserving but before any attempt claimed the AppKit boundary.
    case interruptedBeforeSubmission
}

/// Typed, pre-submit reason returned to every deletion surface. Nothing in this value is an
/// execution result and none of its paths may be promoted into a deletion receipt.
public struct TrashPendingOperationRejection: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case priorOperationPending = "trashPendingOperation"
        case identityChanged = "trashPendingIdentityChanged"
        case targetMissing = "trashPendingTargetMissing"
        case ledgerUnavailable = "trashPendingLedgerUnavailable"
        case submissionQueueExpired = "trashSubmissionQueueExpired"
        case freshReviewRequired = "trashPendingFreshReviewRequired"
    }

    public let reasonsByPath: [String: Reason]

    public init(reasonsByPath: [String: Reason]) {
        self.reasonsByPath = reasonsByPath
    }

    public var paths: [String] { reasonsByPath.keys.sorted() }

    var preflightRejections: [DeletionPreflight.Rejection] {
        reasonsByPath.keys.sorted().compactMap { path in
            reasonsByPath[path].map {
                DeletionPreflight.Rejection(path: path, reason: $0.rawValue)
            }
        }
    }
}

enum TrashPendingLedgerReservation: Sendable, Equatable {
    case reserved(normalizedPaths: [String], invalidatedPaths: [String])
    case rejected(TrashPendingOperationRejection, invalidatedPaths: [String])
}

enum TrashPendingLedgerClaim: Sendable, Equatable {
    case claimed
    case rejected(TrashPendingOperationRejection, invalidatedPaths: [String])
}

struct TrashPendingLedgerReconciliation: Sendable, Equatable {
    let invalidatedPaths: [String]
}

protocol TrashPendingOperationLedger: Sendable {
    func reserve(
        paths: [String],
        operationID: UUID,
        reviewIdentity: DeletionSnapshotIdentity?
    ) -> TrashPendingLedgerReservation
    func claim(paths: [String], operationID: UUID, attemptID: UUID) -> TrashPendingLedgerClaim
    @discardableResult
    func markAPIReturned(paths: [String], operationID: UUID, attemptID: UUID) -> Bool
    @discardableResult
    func markCallbackObserved(paths: [String], operationID: UUID, attemptID: UUID) -> Bool
    @discardableResult
    func markRetryReady(paths: [String], operationID: UUID, attemptID: UUID) -> Bool
    @discardableResult
    func finish(operationID: UUID, retainingPendingPaths: Set<String>) -> Bool
    @discardableResult
    func finish(paths: [String], operationID: UUID, attemptID: UUID) -> Bool
    func reconcilePersistedRecords() -> TrashPendingLedgerReconciliation
}

extension TrashPendingOperationLedger {
    /// v2026.07.16 compatibility for legacy/debug callers. A missing review identity may create
    /// an initial reservation, but by contract it can never clear `needsFreshReview`; production
    /// confirmed interactions use the typed overload through TrashPipeline.
    func reserve(paths: [String], operationID: UUID) -> TrashPendingLedgerReservation {
        reserve(paths: paths, operationID: operationID, reviewIdentity: nil)
    }
}

/// Process-wide ownership for operations that may still receive an AppKit callback.
///
/// **v2026.07.16 active-operation race fix**: a new `TrashPipeline` can be created while an
/// older pipeline is between `NSWorkspace.recycle` moving the source and delivering its
/// callback. At that instant `lstat` reports the source as absent, but clearing the persisted
/// tombstone would reopen the duplicate-submission boundary. Registration happens before the
/// reservation transaction begins and removal happens only after the last owned ledger record
/// reaches a terminal clear. A process restart naturally starts with an empty registry, so the
/// persisted identity reconciliation remains the cross-restart authority.
final class TrashActiveOperationRegistry: @unchecked Sendable {
    static let shared = TrashActiveOperationRegistry()

    private let lock = NSLock()
    private var operationIDs: Set<UUID> = []
    private var unregisterTransitions: [UUID: Int] = [:]

    @discardableResult
    func register(_ operationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return operationIDs.insert(operationID).inserted
    }

    @discardableResult
    func unregister(_ operationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard operationIDs.remove(operationID) != nil else { return false }
        unregisterTransitions[operationID, default: 0] += 1
        return true
    }

    func contains(_ operationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return operationIDs.contains(operationID)
    }

    /// Test-only evidence that terminal convergence removes process ownership exactly once.
    func unregisterTransitionCountForTesting(_ operationID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return unregisterTransitions[operationID, default: 0]
    }
}

/// Application Support JSON ledger protected by a separate, stable lock inode.
///
/// `.atomic` protects one file replacement but does not serialize two App processes. Every
/// read-modify-write therefore holds `flock(LOCK_EX)` on `<ledger>.lock`; the lock file is never
/// replaced with the JSON payload. Corrupt or unreadable state fails closed rather than being
/// overwritten and silently permitting a duplicate recycle request.
final class PersistentTrashPendingOperationLedger: TrashPendingOperationLedger,
                                                   @unchecked Sendable {
    private struct Record: Codable, Sendable, Equatable {
        let normalizedPath: String
        /// Parent request shared by the batch and its at-most-once diagnostic retries.
        let operationID: UUID
        /// Cross-process authority. The process-local registry cannot tell whether a second
        /// `open -n` App instance still owns an AppKit callback, so every new record persists
        /// PID + kernel start time. Nil is accepted only for schema-1 migration and remains
        /// unavailable/fail-closed until an exact terminal callback clears that generation.
        let owner: TrashLedgerProcessIdentity?
        /// v2026.07.16 ABA guard: each `recycleOnce` invocation owns a distinct generation.
        /// A callback/API return from an older generation can never mutate or clear a retry.
        var activeAttemptID: UUID?
        let identity: TrashPendingPathIdentity
        /// Exact scan/review snapshot that authorized this parent operation. A durable
        /// invalidation may be replaced only by a strictly newer typed identity.
        let reviewIdentity: DeletionSnapshotIdentity?
        var stage: TrashPendingOperationStage
        /// Non-nil only for the durable `needsFreshReview` state. This field is optional so
        /// v2026.07.16 can decode schema-1 ledgers created before the invalidation state existed.
        var invalidationReason: TrashPendingInvalidationReason?
        var updatedAt: Date
    }

    private struct Envelope: Codable, Sendable, Equatable {
        let schemaVersion: Int
        var records: [String: Record]
    }

    private enum IdentityProbe {
        case present(TrashPendingPathIdentity)
        case absent
        case unavailable
    }

    typealias ProcessIdentityProvider = @Sendable () -> TrashLedgerProcessIdentity?
    typealias ProcessLivenessProbe = @Sendable (
        TrashLedgerProcessIdentity
    ) -> TrashLedgerProcessLiveness

    static let shared = PersistentTrashPendingOperationLedger()

    private let fileURL: URL
    private let lockFileURL: URL
    private let processLock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let activeOperationRegistry: TrashActiveOperationRegistry
    private let processIdentityProvider: ProcessIdentityProvider
    private let processLivenessProbe: ProcessLivenessProbe

    convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(fileURL: support
            .appendingPathComponent("AmuxAIClean", isDirectory: true)
            .appendingPathComponent("trash-pending-operations.json", isDirectory: false))
    }

    /// Injectable only for isolated tests; production uses the Application Support location.
    convenience init(
        fileURL: URL,
        activeOperationRegistry: TrashActiveOperationRegistry = .shared
    ) {
        self.init(
            fileURL: fileURL,
            activeOperationRegistry: activeOperationRegistry,
            processIdentityProvider: {
                Self.lookupProcessIdentity(pid: Int32(Darwin.getpid())).identity
            },
            processLivenessProbe: { expected in
                switch Self.lookupProcessIdentity(pid: expected.pid) {
                case .found(let actual):
                    return actual == expected ? .active : .inactive
                case .notRunning:
                    return .inactive
                case .unavailable:
                    return .unavailable
                }
            }
        )
    }

    /// Owner probes are injectable only for deterministic multi-process ledger tests. Production
    /// always uses `proc_pidinfo`; no test path invokes `NSWorkspace.recycle`.
    init(
        fileURL: URL,
        activeOperationRegistry: TrashActiveOperationRegistry,
        processIdentityProvider: @escaping ProcessIdentityProvider,
        processLivenessProbe: @escaping ProcessLivenessProbe
    ) {
        self.fileURL = fileURL
        self.lockFileURL = fileURL.appendingPathExtension("lock")
        self.activeOperationRegistry = activeOperationRegistry
        self.processIdentityProvider = processIdentityProvider
        self.processLivenessProbe = processLivenessProbe
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func reserve(
        paths: [String],
        operationID: UUID,
        reviewIdentity: DeletionSnapshotIdentity?
    ) -> TrashPendingLedgerReservation {
        let normalizedInput = Self.stableUnique(paths.map(Self.normalize))
        guard let owner = processIdentityProvider() else {
            return .rejected(
                .init(reasonsByPath: Self.reasonMap(
                    normalizedInput,
                    reason: .ledgerUnavailable
                )),
                invalidatedPaths: []
            )
        }
        guard activeOperationRegistry.register(operationID) else {
            return .rejected(
                .init(reasonsByPath: Self.reasonMap(
                    normalizedInput,
                    reason: .ledgerUnavailable
                )),
                invalidatedPaths: []
            )
        }

        let result: TrashPendingLedgerReservation = withTransaction(fallback: .rejected(
            .init(reasonsByPath: Self.reasonMap(paths, reason: .ledgerUnavailable)),
            invalidatedPaths: []
        )) { envelope in
            let normalized = normalizedInput
            guard normalized.count == paths.count else {
                return .value(.rejected(
                    .init(reasonsByPath: Self.reasonMap(normalized, reason: .ledgerUnavailable)),
                    invalidatedPaths: []
                ))
            }

            var reasons: [String: TrashPendingOperationRejection.Reason] = [:]
            var identities: [String: TrashPendingPathIdentity] = [:]
            var invalidated: [String] = []
            var ledgerChanged = false

            for path in normalized {
                if var existing = envelope.records[path] {
                    // An absent source can be the expected intermediate state after AppKit moved
                    // it but before the callback. Never let another surface steal that active
                    // operation's tombstone, even if the path now resolves differently.
                    // v2026.07.16: query the registry while holding the ledger transaction,
                    // rather than using a pre-flock snapshot. Otherwise operation B can register
                    // after A snapshots, win the flock and persist `.reserved`, then A can wake
                    // and misclassify B as an inactive/restarted record.
                    switch ownerLiveness(for: existing) {
                    case .active:
                        reasons[path] = .priorOperationPending
                        continue
                    case .unavailable:
                        // A failed proc query cannot be interpreted as process death. Keeping the
                        // exact record blocks both duplicate submission and a late callback from
                        // losing its Undo/notification side effects.
                        reasons[path] = .ledgerUnavailable
                        continue
                    case .inactive:
                        break
                    }
                    let hasFreshReview = Self.isFreshReview(
                        reviewIdentity,
                        comparedWith: existing.reviewIdentity
                    )
                    switch existing.stage {
                    case .needsFreshReview:
                        // **v2026.07.16 durable invalidation**: only a typed scan/review identity
                        // that is newer than the operation which created the tombstone may replace
                        // it. Raw path retries and the exact stale token remain fail-closed.
                        guard hasFreshReview else {
                            reasons[path] = .freshReviewRequired
                            continue
                        }
                        switch Self.probe(path) {
                        case .present(let current):
                            identities[path] = current
                        case .absent:
                            reasons[path] = .targetMissing
                        case .unavailable:
                            reasons[path] = .ledgerUnavailable
                        }

                    case .reserved:
                        // An inactive reservation proves the App exited before `claim`; no
                        // system call is pending, but the old review cannot be silently revived.
                        guard hasFreshReview else {
                            Self.invalidate(
                                record: &existing,
                                reason: .interruptedBeforeSubmission
                            )
                            envelope.records[path] = existing
                            invalidated.append(path)
                            reasons[path] = .freshReviewRequired
                            ledgerChanged = true
                            continue
                        }
                        switch Self.probe(path) {
                        case .present(let current):
                            identities[path] = current
                            invalidated.append(path)
                        case .absent:
                            Self.invalidate(record: &existing, reason: .targetMissing)
                            envelope.records[path] = existing
                            invalidated.append(path)
                            reasons[path] = .targetMissing
                            ledgerChanged = true
                        case .unavailable:
                            reasons[path] = .ledgerUnavailable
                        }

                    case .submissionUnknown, .callbackPending:
                        // Once `claim` crossed into the synchronous AppKit boundary, neither
                        // owner death nor a changed/absent path proves that the file operation
                        // cannot still deliver a callback. A second App instance therefore never
                        // rewrites or replaces claimed-unknown state. This may retain a conservative
                        // tombstone after a crash, but it cannot duplicate a destructive request.
                        reasons[path] = .priorOperationPending

                    case .callbackObserved, .retryReady:
                        // The exact attempt already has an authoritative terminal callback. It
                        // cannot act on a future occupant, so clear it and evaluate this request
                        // as an ordinary current-path reservation.
                        envelope.records.removeValue(forKey: path)
                        ledgerChanged = true
                        switch Self.probe(path) {
                        case .present(let current):
                            identities[path] = current
                        case .absent:
                            invalidated.append(path)
                            reasons[path] = .targetMissing
                        case .unavailable:
                            reasons[path] = .ledgerUnavailable
                        }
                    }
                }

                guard reasons[path] == nil else { continue }
                switch Self.probe(path) {
                case .present(let identity):
                    identities[path] = identity
                case .absent:
                    reasons[path] = .targetMissing
                case .unavailable:
                    reasons[path] = .ledgerUnavailable
                }
            }

            if !reasons.isEmpty {
                let rejection = TrashPendingLedgerReservation.rejected(
                    .init(reasonsByPath: reasons),
                    invalidatedPaths: Self.stableUnique(invalidated)
                )
                return ledgerChanged ? .persistThen(rejection) : .value(rejection)
            }

            let now = Date()
            for path in normalized {
                guard let identity = identities[path] else {
                    return .value(.rejected(
                        .init(reasonsByPath: [path: .ledgerUnavailable]),
                        invalidatedPaths: Self.stableUnique(invalidated)
                    ))
                }
                envelope.records[path] = Record(
                    normalizedPath: path,
                    operationID: operationID,
                    owner: owner,
                    activeAttemptID: nil,
                    identity: identity,
                    reviewIdentity: reviewIdentity,
                    stage: .reserved,
                    invalidationReason: nil,
                    updatedAt: now
                )
            }
            return .persistThen(.reserved(
                normalizedPaths: normalized,
                invalidatedPaths: Self.stableUnique(invalidated)
            ))
        }
        if case .rejected = result {
            _ = activeOperationRegistry.unregister(operationID)
        }
        return result
    }

    func claim(
        paths: [String],
        operationID: UUID,
        attemptID: UUID
    ) -> TrashPendingLedgerClaim {
        struct ClaimMutation {
            let result: TrashPendingLedgerClaim
            let shouldUnregister: Bool
            let transactionSucceeded: Bool
        }

        let normalized = Self.stableUnique(paths.map(Self.normalize))
        let mutation = withTransaction(fallback: ClaimMutation(
            result: .rejected(
                .init(reasonsByPath: Self.reasonMap(normalized, reason: .ledgerUnavailable)),
                invalidatedPaths: []
            ),
            shouldUnregister: false,
            transactionSucceeded: false
        )) { envelope in
            guard let currentOwner = processIdentityProvider(),
                  activeOperationRegistry.contains(operationID) else {
                return .value(ClaimMutation(
                    result: .rejected(
                        .init(reasonsByPath: Self.reasonMap(
                            normalized,
                            reason: .ledgerUnavailable
                        )),
                        invalidatedPaths: []
                    ),
                    shouldUnregister: false,
                    transactionSucceeded: true
                ))
            }
            var reasons: [String: TrashPendingOperationRejection.Reason] = [:]
            var invalidated: [String] = []
            var ledgerChanged = false
            for path in normalized {
                guard var record = envelope.records[path],
                      record.operationID == operationID,
                      record.owner == currentOwner else {
                    reasons[path] = .priorOperationPending
                    continue
                }
                guard record.stage != .needsFreshReview else {
                    reasons[path] = .freshReviewRequired
                    continue
                }
                switch Self.probe(path) {
                case .absent:
                    Self.invalidate(record: &record, reason: .targetMissing)
                    envelope.records[path] = record
                    reasons[path] = .freshReviewRequired
                    invalidated.append(path)
                    ledgerChanged = true
                case .present(let current) where current != record.identity:
                    Self.invalidate(record: &record, reason: .identityChanged)
                    envelope.records[path] = record
                    reasons[path] = .freshReviewRequired
                    invalidated.append(path)
                    ledgerChanged = true
                case .present:
                    // A retry may replace only a generation that the authoritative normal
                    // callback explicitly released. `callbackObserved` itself is not claimable,
                    // closing the callback-vs-retry ABA window.
                    guard record.stage == .reserved || record.stage == .retryReady else {
                        reasons[path] = .priorOperationPending
                        continue
                    }
                case .unavailable:
                    reasons[path] = .ledgerUnavailable
                }
            }

            if !reasons.isEmpty {
                // Once one sibling loses its frozen identity, the old authorization is invalid
                // for the whole still-unsubmitted operation. Confirmed earlier callbacks are
                // already terminal; unknown siblings remain protected by their own operation.
                let operationPaths = envelope.records.compactMap { path, record in
                    record.operationID == operationID ? path : nil
                }
                for path in operationPaths {
                    guard let record = envelope.records[path] else { continue }
                    if record.stage != .submissionUnknown,
                       record.stage != .callbackPending,
                       record.stage != .callbackObserved,
                       record.stage != .needsFreshReview {
                        envelope.records.removeValue(forKey: path)
                        ledgerChanged = true
                    }
                }
                let hasActiveRecords = envelope.records.values.contains {
                    $0.operationID == operationID && $0.stage != .needsFreshReview
                }
                let result = ClaimMutation(
                    result: .rejected(
                        .init(reasonsByPath: reasons),
                        invalidatedPaths: Self.stableUnique(invalidated)
                    ),
                    shouldUnregister: !hasActiveRecords,
                    transactionSucceeded: true
                )
                return ledgerChanged ? .persistThen(result) : .value(result)
            }

            let now = Date()
            for path in normalized {
                guard var record = envelope.records[path] else { continue }
                record.stage = .submissionUnknown
                record.activeAttemptID = attemptID
                record.invalidationReason = nil
                record.updatedAt = now
                envelope.records[path] = record
            }
            return .persistThen(ClaimMutation(
                result: .claimed,
                shouldUnregister: false,
                transactionSucceeded: true
            ))
        }
        if mutation.transactionSucceeded, mutation.shouldUnregister {
            _ = activeOperationRegistry.unregister(operationID)
        }
        return mutation.result
    }

    func markAPIReturned(paths: [String], operationID: UUID, attemptID: UUID) -> Bool {
        let normalized = Self.stableUnique(paths.map(Self.normalize))
        return withTransaction(fallback: false) { envelope in
            guard normalized.allSatisfy({ path in
                guard let record = envelope.records[path] else { return false }
                return record.operationID == operationID
                    && record.activeAttemptID == attemptID
                    && [.submissionUnknown, .callbackObserved, .retryReady].contains(record.stage)
            }) else {
                return .value(false)
            }

            // A synchronous callback may be observed before the AppKit function returns. The
            // return event is authoritative for this generation but must not move callback or
            // retry state backwards.
            let pathsToTransition = normalized.filter {
                envelope.records[$0]?.stage == .submissionUnknown
            }
            guard !pathsToTransition.isEmpty else { return .value(true) }
            let now = Date()
            for path in pathsToTransition {
                guard var record = envelope.records[path] else { continue }
                record.stage = .callbackPending
                record.updatedAt = now
                envelope.records[path] = record
            }
            return .persistThen(true)
        }
    }

    func markCallbackObserved(paths: [String], operationID: UUID, attemptID: UUID) -> Bool {
        transition(
            paths: paths,
            operationID: operationID,
            attemptID: attemptID,
            allowedStages: [.submissionUnknown, .callbackPending],
            to: .callbackObserved
        )
    }

    func markRetryReady(paths: [String], operationID: UUID, attemptID: UUID) -> Bool {
        transition(
            paths: paths,
            operationID: operationID,
            attemptID: attemptID,
            allowedStages: [.callbackObserved],
            to: .retryReady
        )
    }

    func finish(operationID: UUID, retainingPendingPaths: Set<String>) -> Bool {
        struct FinishMutation {
            let succeeded: Bool
            let shouldUnregister: Bool
        }

        let retained = Set(retainingPendingPaths.map(Self.normalize))
        let mutation = withTransaction(fallback: FinishMutation(
            succeeded: false,
            shouldUnregister: false
        )) { envelope in
            var changed = false
            let operationPaths = envelope.records.compactMap { path, record in
                record.operationID == operationID ? path : nil
            }
            for path in operationPaths {
                guard let record = envelope.records[path] else { continue }
                // Retain by the outer typed outcome, not by a racy stage snapshot. A late
                // callback can already be `callbackObserved` while the outer timeout result is
                // finalizing; removing it here would suppress the exact-attempt late reconcile.
                if retained.contains(path) || record.stage == .needsFreshReview {
                    continue
                }
                envelope.records.removeValue(forKey: path)
                changed = true
            }
            let hasActiveRecords = envelope.records.values.contains {
                $0.operationID == operationID && $0.stage != .needsFreshReview
            }
            let result = FinishMutation(
                succeeded: true,
                shouldUnregister: !hasActiveRecords
            )
            return changed ? .persistThen(result) : .value(result)
        }
        if mutation.succeeded, mutation.shouldUnregister {
            _ = activeOperationRegistry.unregister(operationID)
        }
        return mutation.succeeded
    }

    func finish(paths: [String], operationID: UUID, attemptID: UUID) -> Bool {
        struct FinishMutation {
            let succeeded: Bool
            let shouldUnregister: Bool
        }

        let normalized = Set(paths.map(Self.normalize))
        let mutation = withTransaction(fallback: FinishMutation(
            succeeded: false,
            shouldUnregister: false
        )) { envelope in
            var changed = false
            var removedOwnedRecord = false
            for path in normalized {
                guard let record = envelope.records[path],
                      record.operationID == operationID,
                      record.activeAttemptID == attemptID else { continue }
                envelope.records.removeValue(forKey: path)
                changed = true
                removedOwnedRecord = true
            }
            let hasActiveRecords = envelope.records.values.contains {
                $0.operationID == operationID && $0.stage != .needsFreshReview
            }
            let result = FinishMutation(
                succeeded: removedOwnedRecord,
                shouldUnregister: removedOwnedRecord && !hasActiveRecords
            )
            return changed ? .persistThen(result) : .value(result)
        }
        if mutation.succeeded, mutation.shouldUnregister {
            _ = activeOperationRegistry.unregister(operationID)
        }
        return mutation.succeeded
    }

    func reconcilePersistedRecords() -> TrashPendingLedgerReconciliation {
        return withTransaction(fallback: .init(invalidatedPaths: [])) { envelope in
            var invalidated: [String] = []
            var changed = false
            for path in Array(envelope.records.keys) {
                guard var record = envelope.records[path] else { continue }
                // v2026.07.16 cross-process root-cause fix: classification happens while this
                // exact envelope is protected by flock. The local registry closes the tiny
                // register->persist window; persisted PID + kernel start time is the authority
                // for another App instance. Active *and unavailable* probes remain untouched.
                // Treating query failure as process death would reopen the duplicate boundary.
                guard ownerLiveness(for: record) == .inactive else { continue }
                guard record.stage != .needsFreshReview else { continue }
                switch record.stage {
                case .reserved:
                    // `claim` is the durable proof that an AppKit call may have started. A
                    // persisted reservation without a claim therefore cannot be an unknown
                    // submission after restart. It still requires a new user review instead of
                    // silently reviving the old authorization.
                    Self.invalidate(record: &record, reason: .interruptedBeforeSubmission)
                    envelope.records[path] = record
                    invalidated.append(path)
                    changed = true

                case .callbackObserved, .retryReady:
                    // The exact generation already produced an authoritative callback. No
                    // AppKit work remains that can act on a future path occupant, so finish the
                    // tombstone. If the source identity is gone, invalidate only the view model;
                    // do not retain a false "pending" operation forever.
                    switch Self.probe(path) {
                    case .absent:
                        invalidated.append(path)
                    case .present(let current) where current != record.identity:
                        invalidated.append(path)
                    case .present, .unavailable:
                        break
                    }
                    envelope.records.removeValue(forKey: path)
                    changed = true

                case .submissionUnknown, .callbackPending:
                    // Owner death does not prove whether AppKit accepted the URL before the App
                    // exited. In particular, source absence may be the successful move awaiting
                    // its callback. Claimed generations therefore remain durable pending instead
                    // of being rewritten merely because another App instance started.
                    break

                case .needsFreshReview:
                    break
                }
            }
            let result = TrashPendingLedgerReconciliation(
                invalidatedPaths: Self.stableUnique(invalidated)
            )
            return changed ? .persistThen(result) : .value(result)
        }
    }

    private func transition(
        paths: [String],
        operationID: UUID,
        attemptID: UUID,
        allowedStages: Set<TrashPendingOperationStage>,
        to stage: TrashPendingOperationStage
    ) -> Bool {
        let normalized = Self.stableUnique(paths.map(Self.normalize))
        return withTransaction(fallback: false) { envelope in
            guard normalized.allSatisfy({ path in
                guard let record = envelope.records[path] else { return false }
                return record.operationID == operationID
                    && record.activeAttemptID == attemptID
                    && allowedStages.contains(record.stage)
            }) else {
                return .value(false)
            }
            let now = Date()
            for path in normalized {
                guard var record = envelope.records[path] else { continue }
                record.stage = stage
                record.updatedAt = now
                envelope.records[path] = record
            }
            return .persistThen(true)
        }
    }

    private enum TransactionResult<T> {
        case value(T)
        case persistThen(T)
    }

    private func withTransaction<T>(
        fallback: T,
        _ body: (inout Envelope) -> TransactionResult<T>
    ) -> T {
        processLock.lock()
        defer { processLock.unlock() }
        guard let value = withCrossProcessLock({
            guard var envelope = loadEnvelope() else { return fallback }
            switch body(&envelope) {
            case .value(let result):
                return result
            case .persistThen(let result):
                return persist(envelope) ? result : fallback
            }
        }) else {
            return fallback
        }
        return value
    }

    private func loadEnvelope() -> Envelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Envelope(schemaVersion: 2, records: [:])
        }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let decoded = try decoder.decode(Envelope.self, from: data)
            guard (decoded.schemaVersion == 1 || decoded.schemaVersion == 2),
                  decoded.records.allSatisfy({ key, record in
                      key == record.normalizedPath && Self.isStructurallyValid(record)
                  }) else {
                GSYLog.error(.trash, "Trash pending ledger schema or key identity is invalid")
                return nil
            }
            // Schema 1 predates cross-process owner identity. Optional decoding preserves those
            // records with owner=nil; they remain unavailable/fail-closed rather than being
            // guessed inactive. Any later atomic write upgrades the envelope without weakening
            // the unresolved generation.
            return Envelope(schemaVersion: 2, records: decoded.records)
        } catch {
            GSYLog.error(.trash, "Trash pending ledger read failed path=\(fileURL.path) error=\(error)")
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
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            GSYLog.error(.trash, "Trash pending ledger atomic write failed path=\(fileURL.path) error=\(error)")
            return false
        }
    }

    private func withCrossProcessLock<T>(_ body: () -> T) -> T? {
        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            GSYLog.error(.trash, "Trash pending ledger lock directory failed error=\(error)")
            return nil
        }
        let descriptor = lockFileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            GSYLog.error(.trash, "Trash pending ledger lock open failed errno=\(errno)")
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            GSYLog.error(.trash, "Trash pending ledger flock failed errno=\(errno)")
            return nil
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return body()
    }

    /// Must be called only while the ledger flock is held. The local registry protects the
    /// register-before-persist window in this process; the persisted kernel identity is what
    /// makes another App instance's active callback visible. Query failure is not process death.
    private func ownerLiveness(for record: Record) -> TrashLedgerProcessLiveness {
        if activeOperationRegistry.contains(record.operationID) {
            return .active
        }
        guard let owner = record.owner else { return .unavailable }
        return processLivenessProbe(owner)
    }

    private enum ProcessIdentityLookup {
        case found(TrashLedgerProcessIdentity)
        case notRunning
        case unavailable

        var identity: TrashLedgerProcessIdentity? {
            guard case .found(let identity) = self else { return nil }
            return identity
        }
    }

    private static func lookupProcessIdentity(pid: Int32) -> ProcessIdentityLookup {
        guard pid > 0 else { return .notRunning }
        var info = proc_bsdinfo()
        errno = 0
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
        }
        guard byteCount == Int32(expectedSize) else {
            return errno == ESRCH ? .notRunning : .unavailable
        }
        return .found(TrashLedgerProcessIdentity(
            pid: pid,
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        ))
    }

    private static func probe(_ path: String) -> IdentityProbe {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unavailable
        }
        return .present(.init(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            fileType: UInt16(metadata.st_mode & mode_t(S_IFMT))
        ))
    }

    private static func invalidate(
        record: inout Record,
        reason: TrashPendingInvalidationReason
    ) {
        record.stage = .needsFreshReview
        record.activeAttemptID = nil
        record.invalidationReason = reason
        record.updatedAt = Date()
    }

    private static func isStructurallyValid(_ record: Record) -> Bool {
        // A malformed persisted owner must remain an unreadable/fail-closed ledger. Treating a
        // negative PID or impossible timeval as an inactive process would let corrupted state
        // cross the same destructive duplicate-submission boundary this owner protects.
        if let owner = record.owner,
           (owner.pid <= 0
            || owner.startTimeSeconds == 0
            || owner.startTimeMicroseconds >= 1_000_000) {
            return false
        }
        switch record.stage {
        case .reserved:
            return record.activeAttemptID == nil && record.invalidationReason == nil
        case .submissionUnknown, .callbackPending, .callbackObserved, .retryReady:
            return record.activeAttemptID != nil && record.invalidationReason == nil
        case .needsFreshReview:
            return record.activeAttemptID == nil && record.invalidationReason != nil
        }
    }

    /// A review capability is monotonic within one scan session and starts a new lineage only
    /// when the producer explicitly creates a new scan session. Random per-click UUIDs are not
    /// valid producers; every production surface keeps its session stable for one result set.
    private static func isFreshReview(
        _ candidate: DeletionSnapshotIdentity?,
        comparedWith previous: DeletionSnapshotIdentity?
    ) -> Bool {
        guard let candidate else { return false }
        // A schema-1/legacy record has no capability lineage to compare. Treat it as
        // permanently fail-closed; guessing that an arbitrary later token is "newer" would
        // recreate the exact stale-authorization hole this ledger exists to close.
        guard let previous else { return false }
        if candidate.sessionID == previous.sessionID {
            return candidate.revision > previous.revision
        }
        return true
    }

    private static func normalize(_ path: String) -> String {
        TrashPipeline.normalizePath(path)
    }

    private static func stableUnique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func reasonMap(
        _ paths: [String],
        reason: TrashPendingOperationRejection.Reason
    ) -> [String: TrashPendingOperationRejection.Reason] {
        var result: [String: TrashPendingOperationRejection.Reason] = [:]
        for path in paths {
            result[normalize(path)] = reason
        }
        return result
    }

    /// Test-only visibility proving callers lock a stable inode rather than the atomically
    /// replaced JSON file.
    var lockURLForTesting: URL { lockFileURL }
}
