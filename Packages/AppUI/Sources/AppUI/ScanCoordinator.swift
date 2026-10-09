import Combine
import Darwin
import Foundation
import LogKit
import ScanKit
import SafetyKit

/// Narrow, UI-facing progress state for active scans.
///
/// v2026.07.20 performance-regression fix: production `.topLevel` scans have no visible result
/// rows before their terminal projection, yet the old path replaced `ScanCoordinator.snapshot`
/// every 0.4 seconds. Because the main window and HUD observe the whole coordinator, an elapsed-
/// time-only change invalidated the complete NavigationSplitView and made sidebar scrolling hitch.
/// Live counters now have their own observable root; the authoritative result snapshot remains a
/// session/terminal publication boundary.
public struct ScanLiveProgressFrame: Sendable, Equatable {
    public let categoryID: String?
    public let totalBytes: Int64
    public let scannedFileCount: Int
    public let elapsed: TimeInterval
    public let bytesPerSecond: Double
    public let startedAt: Date?
    public let perRootRows: [ScanCoordinator.PerRootProgress]

    public static let idle = ScanLiveProgressFrame(
        categoryID: nil,
        totalBytes: 0,
        scannedFileCount: 0,
        elapsed: 0,
        bytesPerSecond: 0,
        startedAt: nil,
        perRootRows: []
    )

    public func elapsedForDisplay(referenceDate: Date = Date()) -> TimeInterval {
        guard let startedAt else { return max(0, elapsed) }
        return max(0, max(elapsed, referenceDate.timeIntervalSince(startedAt)))
    }
}

@MainActor
public final class ScanLiveProgressStore: ObservableObject {
    @Published public private(set) var frame: ScanLiveProgressFrame = .idle

    public init() {}

    fileprivate func reset(categoryID: String, startedAt: Date) {
        publish(ScanLiveProgressFrame(
            categoryID: categoryID,
            totalBytes: 0,
            scannedFileCount: 0,
            elapsed: 0,
            bytesPerSecond: 0,
            startedAt: startedAt,
            perRootRows: []
        ))
    }

    fileprivate func updateTotals(
        categoryID: String,
        totalBytes: Int64,
        scannedFileCount: Int,
        elapsed: TimeInterval,
        bytesPerSecond: Double
    ) {
        publish(ScanLiveProgressFrame(
            categoryID: categoryID,
            totalBytes: totalBytes,
            scannedFileCount: scannedFileCount,
            elapsed: elapsed,
            bytesPerSecond: bytesPerSecond,
            startedAt: frame.startedAt,
            perRootRows: frame.perRootRows
        ))
    }

    fileprivate func updatePerRootRows(_ rows: [ScanCoordinator.PerRootProgress]) {
        publish(ScanLiveProgressFrame(
            categoryID: frame.categoryID,
            totalBytes: frame.totalBytes,
            scannedFileCount: frame.scannedFileCount,
            elapsed: frame.elapsed,
            bytesPerSecond: frame.bytesPerSecond,
            startedAt: frame.startedAt,
            perRootRows: rows
        ))
    }

    fileprivate func finish(with snapshot: ScanSnapshot) {
        publish(ScanLiveProgressFrame(
            categoryID: snapshot.categoryID,
            totalBytes: snapshot.totalBytes,
            scannedFileCount: snapshot.scannedFileCount,
            elapsed: snapshot.elapsed,
            bytesPerSecond: snapshot.bytesPerSecond,
            startedAt: nil,
            perRootRows: frame.perRootRows
        ))
    }

    private func publish(_ next: ScanLiveProgressFrame) {
        guard frame != next else { return }
        frame = next
    }
}

/// Serializes the *settlement boundary* between heavyweight scan producers.
///
/// v2026.07.18 root-cause fix: generation tokens prevent stale UI writes, but cancellation is
/// cooperative and does not prove the old filesystem walk has stopped. Every replacement scan
/// snapshots this chain and waits for all cancelled primary/Tree producers to actually return
/// before starting new primary-scan I/O. During that ownership handoff the last stable snapshot
/// remains visible and the UI reports a typed settling phase; it must not publish an empty frame
/// that falsely claims the replacement scan has started. Tree-to-Tree requests do not await this
/// global chain: `TreeFilesystemLeaseDomain` waits only for overlapping physical/public paths,
/// while token/generation CAS independently rejects stale presentation commits.
@MainActor
public final class ScanProducerSettlementChain {
    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var tail: Tail?

    public init() {}

    func retire(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        for task in tasks { task.cancel() }
        enqueueSettlement(tasks)
    }

    /// Subtree retirement performs the potentially wide key match and cancellation on its worker
    /// actor. MainActor only transfers the already-cancelled task handles into this settlement
    /// chain; iteration and waiting remain on the detached retirement task.
    func retireAlreadyCancelled(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        enqueueSettlement(tasks)
    }

    private func enqueueSettlement(_ tasks: [Task<Void, Never>]) {
        let predecessor = tail?.task
        let id = UUID()
        let retirement = Task.detached(priority: .userInitiated) {
            if let predecessor { await predecessor.value }
            for task in tasks { await task.value }
        }
        tail = Tail(id: id, task: retirement)
        Task { @MainActor [weak self] in
            await retirement.value
            guard self?.tail?.id == id else { return }
            self?.tail = nil
        }
    }

    func barrier() -> Task<Void, Never>? { tail?.task }

    nonisolated static func waitForSettlement(
        _ barrier: Task<Void, Never>?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let barrier { await barrier.value }
        return !Task.isCancelled
    }
}

/// Bounded, process-wide admission authority for the two primary-scan coordinators.
///
/// v2026.07.19 regression fix: the previous `ScanProducerSettlementChain` only learned about a
/// producer *after* one coordinator cancelled its broad orchestration task.  An active producer in
/// the other coordinator was therefore invisible, and the broad task also kept admission blocked
/// during terminal sorting/presentation after filesystem ownership had already ended.
///
/// This registry has exactly one current reservation and one latest-wins pending request.  Only
/// real filesystem producers are leases.  A lease is registered in `.launching` before a scanner
/// or detached producer can be constructed, then activated with its cancellation and termination
/// handles.  Presentation work never enters this state machine.
@MainActor
public final class PrimaryScanAdmissionRegistry {
    public struct ClientID: Hashable, Sendable {
        fileprivate let rawValue: UUID

        public init() { rawValue = UUID() }
    }

    struct RequestToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    struct ReservationToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    struct ProducerLaunchToken: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    struct ProducerLeaseID: Hashable, Sendable {
        fileprivate let rawValue: UUID
    }

    enum ProducerKind: String, Sendable {
        case singleRoot
        case multiRoot
        case developerDiscovery
        case versionedRoots
        case commonAppCaches
        case treeTransient
    }

    struct InvalidationContext: Sendable {
        let replacementClientID: ClientID?
        let replacementIntent: String?

        func preservesPresentation(for clientID: ClientID) -> Bool {
            replacementClientID == clientID
        }
    }

    enum RequestDecision: Sendable {
        case admitted(ReservationToken)
        case queued(RequestToken, blockers: [String])
    }

    private enum LeaseState {
        case launching(kind: ProducerKind, startedAt: UInt64)
        case active(
            kind: ProducerKind,
            startedAt: UInt64,
            cancel: @Sendable () -> Void,
            termination: Task<Void, Never>,
            requiresPayloadHandoff: Bool,
            producerTerminated: Bool
        )

        var kind: ProducerKind {
            switch self {
            case .launching(let kind, _), .active(let kind, _, _, _, _, _): return kind
            }
        }
    }

    private struct Reservation {
        let token: ReservationToken
        let clientID: ClientID
        let intent: String
        let onInvalidated: @MainActor @Sendable (InvalidationContext) -> [Task<Void, Never>]
        var invalidated: Bool
        var leases: [ProducerLeaseID: LeaseState]
    }

    private struct PendingRequest {
        let token: RequestToken
        let clientID: ClientID
        let intent: String
        let onInvalidated: @MainActor @Sendable (InvalidationContext) -> [Task<Void, Never>]
        let onAdmitted: @MainActor @Sendable (ReservationToken) -> Void
        let onDiscarded: @MainActor @Sendable () -> [Task<Void, Never>]
        let queuedAt: UInt64
    }

    private struct ExternalSettlement {
        let kind: ProducerKind
        let startedAt: UInt64
        let task: Task<Void, Never>
    }

    private var current: Reservation?
    private var pendingLatest: PendingRequest?
    private var externalSettlements: [ProducerLeaseID: ExternalSettlement] = [:]

    public init() {}

    /// Requests the sole primary-filesystem reservation. The pending cardinality is hard-bounded
    /// to one; replacing it invokes `onDiscarded` synchronously instead of retaining another
    /// waiter task. A new request invalidates the current reservation and cancels only its real
    /// producer leases. If no lease exists, terminal presentation is cancelled by the callback but
    /// never delays immediate admission.
    func request(
        clientID: ClientID,
        intent: String,
        onInvalidated: @escaping @MainActor @Sendable (InvalidationContext) -> [Task<Void, Never>],
        onAdmitted: @escaping @MainActor @Sendable (ReservationToken) -> Void,
        onDiscarded: @escaping @MainActor @Sendable () -> [Task<Void, Never>]
    ) -> RequestDecision {
        let now = DispatchTime.now().uptimeNanoseconds
        guard current != nil || !externalSettlements.isEmpty else {
            let token = ReservationToken(rawValue: UUID())
            current = Reservation(
                token: token,
                clientID: clientID,
                intent: intent,
                onInvalidated: onInvalidated,
                invalidated: false,
                leases: [:]
            )
            GSYLog.notice(
                .scan,
                "scan.admission.admit reservation=\(token.rawValue.uuidString) "
                    + "client=\(clientID.rawValue.uuidString) intent=\(intent) wait_ms=0.00"
            )
            return .admitted(token)
        }

        if let discarded = pendingLatest {
            pendingLatest = nil
            registerExternalSettlements(
                discarded.onDiscarded(),
                kind: .treeTransient,
                reason: "pending_replaced"
            )
            GSYLog.info(
                .scan,
                "scan.admission.pending.discard request=\(discarded.token.rawValue.uuidString) "
                    + "client=\(discarded.clientID.rawValue.uuidString) intent=\(discarded.intent)"
            )
        }

        let request = PendingRequest(
            token: RequestToken(rawValue: UUID()),
            clientID: clientID,
            intent: intent,
            onInvalidated: onInvalidated,
            onAdmitted: onAdmitted,
            onDiscarded: onDiscarded,
            queuedAt: now
        )
        pendingLatest = request
        invalidateCurrent(
            replacementClientID: clientID,
            replacementIntent: intent,
            promotePending: false
        )

        // Invalidation with no filesystem lease admits synchronously, but deliberately does not
        // invoke `onAdmitted` reentrantly from inside `request`. The caller has not yet installed
        // its generation/pending state; it consumes this return value in the same MainActor turn.
        if let old = current,
           old.invalidated,
           old.leases.isEmpty,
           externalSettlements.isEmpty {
            self.current = nil
            pendingLatest = nil
            let token = ReservationToken(rawValue: UUID())
            current = Reservation(
                token: token,
                clientID: clientID,
                intent: intent,
                onInvalidated: onInvalidated,
                invalidated: false,
                leases: [:]
            )
            GSYLog.notice(
                .scan,
                "scan.admission.admit reservation=\(token.rawValue.uuidString) "
                    + "client=\(clientID.rawValue.uuidString) intent=\(intent) wait_ms=0.00"
            )
            return .admitted(token)
        }

        let blockers = (
            (current?.leases.values.map { $0.kind.rawValue } ?? [])
                + externalSettlements.values.map { $0.kind.rawValue }
        ).sorted()
        GSYLog.notice(
            .scan,
            "scan.admission.queue request=\(request.token.rawValue.uuidString) "
                + "client=\(clientID.rawValue.uuidString) intent=\(intent) "
                + "blocking_leases=\(blockers.count) kinds=\(blockers.joined(separator: ","))"
        )
        return .queued(request.token, blockers: blockers)
    }

    /// Atomically reserves a producer launch before any filesystem task/session is constructed.
    /// If a replacement lands during an actor hop needed to create the producer, activation below
    /// observes the invalidated reservation and cancels the producer immediately.
    func reserveProducerLaunch(
        reservation token: ReservationToken,
        kind: ProducerKind
    ) -> ProducerLaunchToken? {
        guard var current else {
            GSYLog.warning(
                .scan,
                "scan.producer.launch.rejected reservation=\(token.rawValue.uuidString) "
                    + "kind=\(kind.rawValue) reason=no_current_reservation"
            )
            return nil
        }
        guard current.token == token else {
            GSYLog.info(
                .scan,
                "scan.producer.launch.rejected reservation=\(token.rawValue.uuidString) "
                    + "kind=\(kind.rawValue) reason=stale_reservation "
                    + "current=\(current.token.rawValue.uuidString)"
            )
            return nil
        }
        guard !current.invalidated else {
            GSYLog.info(
                .scan,
                "scan.producer.launch.rejected reservation=\(token.rawValue.uuidString) "
                    + "kind=\(kind.rawValue) reason=reservation_invalidated"
            )
            return nil
        }
        let launch = ProducerLaunchToken(rawValue: UUID())
        let leaseID = ProducerLeaseID(rawValue: launch.rawValue)
        current.leases[leaseID] = .launching(
            kind: kind,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        self.current = current
        GSYLog.info(
            .scan,
            "scan.producer.launch.reserve reservation=\(token.rawValue.uuidString) "
                + "lease=\(leaseID.rawValue.uuidString) kind=\(kind.rawValue)"
        )
        return launch
    }

    /// Activates a launch reservation with the exact producer cancellation/termination handles.
    /// `requiresPayloadHandoff` keeps a terminated lease blocking until the consumer has moved any
    /// wide raw terminal payload to an off-MainActor owner.
    func activateProducer(
        launch: ProducerLaunchToken,
        reservation token: ReservationToken,
        cancel: @escaping @Sendable () -> Void,
        termination: Task<Void, Never>,
        requiresPayloadHandoff: Bool = true
    ) -> ProducerLeaseID? {
        let leaseID = ProducerLeaseID(rawValue: launch.rawValue)
        guard var current else {
            GSYLog.warning(
                .scan,
                "scan.producer.start.rejected reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=no_current_reservation"
            )
            cancel()
            return nil
        }
        guard current.token == token else {
            GSYLog.info(
                .scan,
                "scan.producer.start.rejected reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=stale_reservation "
                    + "current=\(current.token.rawValue.uuidString)"
            )
            cancel()
            return nil
        }
        guard case .launching(let kind, let startedAt) = current.leases[leaseID] else {
            GSYLog.error(
                .scan,
                "scan.producer.start.rejected reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=launch_lease_missing"
            )
            cancel()
            return nil
        }
        let invalidated = current.invalidated
        current.leases[leaseID] = .active(
            kind: kind,
            startedAt: startedAt,
            cancel: cancel,
            termination: termination,
            requiresPayloadHandoff: requiresPayloadHandoff,
            producerTerminated: false
        )
        self.current = current
        GSYLog.notice(
            .scan,
            "scan.producer.start reservation=\(token.rawValue.uuidString) "
                + "lease=\(leaseID.rawValue.uuidString) kind=\(kind.rawValue)"
        )
        if invalidated { cancel() }
        Task { @MainActor [weak self] in
            await termination.value
            self?.producerTerminationObserved(leaseID, reservation: token)
        }
        return leaseID
    }

    /// Registers already-cancelled filesystem settlements which are not owned by a primary
    /// reservation (currently Tree transient producers). They remain a process-wide admission
    /// barrier even when no primary reservation exists, closing the completed-snapshot Tree ->
    /// cross-mode primary launch gap. Presentation tasks must never enter this collection.
    func registerExternalSettlements(
        _ tasks: [Task<Void, Never>],
        kind: ProducerKind = .treeTransient,
        reason: String
    ) {
        guard !tasks.isEmpty else { return }
        for task in tasks {
            let leaseID = ProducerLeaseID(rawValue: UUID())
            externalSettlements[leaseID] = ExternalSettlement(
                kind: kind,
                startedAt: DispatchTime.now().uptimeNanoseconds,
                task: task
            )
            Task { @MainActor [weak self] in
                await task.value
                self?.externalSettlementObserved(leaseID)
            }
        }
        GSYLog.notice(
            .scan,
            "scan.external_settlement.register reason=\(reason) kind=\(kind.rawValue) "
                + "count=\(tasks.count) active=\(externalSettlements.count)"
        )
    }

    func abandonProducerLaunch(
        _ launch: ProducerLaunchToken,
        reservation token: ReservationToken
    ) {
        let leaseID = ProducerLeaseID(rawValue: launch.rawValue)
        guard var current, current.token == token else {
            GSYLog.info(
                .scan,
                "scan.producer.launch.abandon.ignored reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=stale_reservation"
            )
            return
        }
        guard current.leases.removeValue(forKey: leaseID) != nil else {
            GSYLog.error(
                .scan,
                "scan.producer.launch.abandon.ignored reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=launch_lease_missing"
            )
            return
        }
        self.current = current
        GSYLog.info(
            .scan,
            "scan.producer.launch.abandon reservation=\(token.rawValue.uuidString) "
                + "lease=\(leaseID.rawValue.uuidString)"
        )
        promoteIfReady()
    }

    /// Explicit raw-payload handoff boundary. Session termination alone is insufficient because a
    /// cancelled MainActor consumer may still be the final owner of a wide terminal projection.
    func finishProducerAfterPayloadHandoff(
        _ leaseID: ProducerLeaseID,
        reservation token: ReservationToken
    ) {
        guard var current else {
            GSYLog.info(
                .scan,
                "scan.producer.handoff.ignored reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=no_current_reservation"
            )
            return
        }
        guard current.token == token else {
            GSYLog.info(
                .scan,
                "scan.producer.handoff.ignored reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=stale_reservation "
                    + "current=\(current.token.rawValue.uuidString)"
            )
            return
        }
        guard case .active(
                let kind,
                let startedAt,
                _,
                _,
                let requiresPayloadHandoff,
                _
              ) = current.leases[leaseID]
        else {
            GSYLog.error(
                .scan,
                "scan.producer.handoff.ignored reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) reason=active_lease_missing"
            )
            return
        }
        // The caller reaches this API only after awaiting the exact registered termination task
        // and transferring raw payload ownership. The registry monitor records diagnostics and is
        // a cancellation fallback, but MainActor resume ordering must not make handoff wait for a
        // second observer of the same completed task.
        _ = requiresPayloadHandoff
        current.leases.removeValue(forKey: leaseID)
        self.current = current
        logProducerFinish(
            leaseID,
            reservation: token,
            kind: kind,
            startedAt: startedAt
        )
        promoteIfReady()
    }

    /// Ends a multi-stage filesystem pipeline after its last lease and payload handoff. Calling
    /// this with an active/launching lease is a contract violation and fails closed.
    @discardableResult
    func finishPipeline(reservation token: ReservationToken) -> Bool {
        guard let current else {
            GSYLog.info(
                .scan,
                "scan.admission.finish.ignored reservation=\(token.rawValue.uuidString) "
                    + "reason=no_current_reservation"
            )
            return false
        }
        guard current.token == token else {
            GSYLog.info(
                .scan,
                "scan.admission.finish.ignored reservation=\(token.rawValue.uuidString) "
                    + "reason=stale_reservation current=\(current.token.rawValue.uuidString)"
            )
            return false
        }
        guard current.leases.isEmpty else {
            GSYLog.error(
                .scan,
                "scan.admission.finish.rejected reservation=\(token.rawValue.uuidString) "
                    + "active_leases=\(current.leases.count)"
            )
            return false
        }
        self.current = nil
        promotePendingIfPossible()
        return true
    }

    func cancelRequest(_ token: RequestToken) {
        guard let pendingLatest, pendingLatest.token == token else { return }
        self.pendingLatest = nil
        registerExternalSettlements(
            pendingLatest.onDiscarded(),
            kind: .treeTransient,
            reason: "pending_cancelled"
        )
    }

    func cancelReservation(_ token: ReservationToken) {
        guard current?.token == token else { return }
        invalidateCurrent(replacementClientID: nil, replacementIntent: nil)
    }

    func isCurrent(_ token: ReservationToken) -> Bool {
        current?.token == token && current?.invalidated == false
    }

    func diagnostics() -> (hasCurrent: Bool, activeLeaseCount: Int, pendingCount: Int) {
        (
            current != nil,
            (current?.leases.count ?? 0) + externalSettlements.count,
            pendingLatest == nil ? 0 : 1
        )
    }

    private func invalidateCurrent(
        replacementClientID: ClientID?,
        replacementIntent: String?,
        promotePending: Bool = true
    ) {
        guard var reservation = current else { return }
        if !reservation.invalidated {
            reservation.invalidated = true
            current = reservation
            let settlements = reservation.onInvalidated(InvalidationContext(
                replacementClientID: replacementClientID,
                replacementIntent: replacementIntent
            ))
            registerExternalSettlements(
                settlements,
                kind: .treeTransient,
                reason: "primary_invalidated"
            )
        }
        guard let latest = current, latest.token == reservation.token else { return }
        for lease in latest.leases.values {
            if case .active(_, _, let cancel, _, _, _) = lease { cancel() }
        }
        if promotePending { promoteIfReady() }
    }

    private func producerTerminationObserved(
        _ leaseID: ProducerLeaseID,
        reservation token: ReservationToken
    ) {
        guard var current,
              current.token == token,
              case .active(
                let kind,
                let startedAt,
                let cancel,
                let termination,
                let requiresPayloadHandoff,
                _
              ) = current.leases[leaseID]
        else { return }
        if requiresPayloadHandoff {
            current.leases[leaseID] = .active(
                kind: kind,
                startedAt: startedAt,
                cancel: cancel,
                termination: termination,
                requiresPayloadHandoff: true,
                producerTerminated: true
            )
            self.current = current
            GSYLog.info(
                .scan,
                "scan.producer.terminated.awaiting_handoff "
                    + "reservation=\(token.rawValue.uuidString) "
                    + "lease=\(leaseID.rawValue.uuidString) kind=\(kind.rawValue)"
            )
            return
        }
        current.leases.removeValue(forKey: leaseID)
        self.current = current
        logProducerFinish(leaseID, reservation: token, kind: kind, startedAt: startedAt)
        promoteIfReady()
    }

    private func logProducerFinish(
        _ leaseID: ProducerLeaseID,
        reservation token: ReservationToken,
        kind explicitKind: ProducerKind? = nil,
        startedAt explicitStartedAt: UInt64? = nil
    ) {
        let kind = explicitKind?.rawValue ?? "unknown"
        let elapsed: Double
        if let explicitStartedAt {
            elapsed = Double(DispatchTime.now().uptimeNanoseconds - explicitStartedAt) / 1_000_000
        } else {
            elapsed = 0
        }
        GSYLog.notice(
            .scan,
            "scan.producer.finish reservation=\(token.rawValue.uuidString) "
                + "lease=\(leaseID.rawValue.uuidString) kind=\(kind) "
                + "duration_ms=\(String(format: "%.2f", elapsed))"
        )
    }

    private func externalSettlementObserved(_ leaseID: ProducerLeaseID) {
        guard let settlement = externalSettlements.removeValue(forKey: leaseID) else { return }
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - settlement.startedAt
        ) / 1_000_000
        GSYLog.notice(
            .scan,
            "scan.external_settlement.finish lease=\(leaseID.rawValue.uuidString) "
                + "kind=\(settlement.kind.rawValue) "
                + "duration_ms=\(String(format: "%.2f", elapsed)) "
                + "remaining=\(externalSettlements.count)"
        )
        promoteIfReady()
        promotePendingIfPossible()
    }

    private func promoteIfReady() {
        guard let current, current.invalidated, current.leases.isEmpty else { return }
        self.current = nil
        promotePendingIfPossible()
    }

    private func promotePendingIfPossible() {
        guard current == nil,
              externalSettlements.isEmpty,
              let pending = pendingLatest else { return }
        pendingLatest = nil
        let reservationToken = ReservationToken(rawValue: UUID())
        current = Reservation(
            token: reservationToken,
            clientID: pending.clientID,
            intent: pending.intent,
            onInvalidated: pending.onInvalidated,
            invalidated: false,
            leases: [:]
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - pending.queuedAt) / 1_000_000
        GSYLog.notice(
            .scan,
            "scan.admission.admit reservation=\(reservationToken.rawValue.uuidString) "
                + "client=\(pending.clientID.rawValue.uuidString) intent=\(pending.intent) "
                + "wait_ms=\(String(format: "%.2f", elapsed))"
        )
        pending.onAdmitted(reservationToken)
    }
}

/// Immutable deletion-rule input for Tree presentation workers.
///
/// v2026.07.18 P1 root-cause fix: Tree row materialization used to call back into the
/// MainActor-isolated coordinator once per visible path. Freezing the immutable SafetyEngine,
/// vendor trie and HOME boundary lets the complete verdict pass run on a generic executor while
/// preserving exactly the same rule set as the final deletion preflight.
struct TreeDeletionEvaluationSnapshot: Sendable {
    let cacheNamespace: UUID
    fileprivate let engine: SafetyEngine
    fileprivate let trie: VendorTrieNode
    fileprivate let home: String

    nonisolated func evaluate(
        path: String
    ) -> (verdict: SafetyVerdict, rejection: SafetyRejection) {
        let result = engine.evaluate(path: path, trie: trie, home: home)
        return (result.0, result.1)
    }
}

/// Compare-and-swap identity for one off-main Tree presentation snapshot.
///
/// v2026.07.19: task ownership is deliberately absent. Loading ownership is published through the
/// same children-cache revision as its terminal rows; an unrelated directory starting or finishing
/// a producer must not invalidate a projection whose immutable row sources did not change.
struct TreeFlatProjectionSourceRevision: Sendable, Equatable {
    let sourceRevision: UInt64
    let generation: UUID
    let isScanning: Bool
}

/// O(1)-per-expanded-parent handoff from ScanCoordinator to the Tree presentation worker. Arrays
/// remain copy-on-write roots; DFS flattening, wide Set construction and verdict evaluation happen
/// only after this value leaves MainActor.
struct TreeFlatProjectionSource: Sendable {
    let revision: TreeFlatProjectionSourceRevision
    let rootRows: [TreeRow]
    let childrenByParent: [String: [TreeRow]]
    let fetchingPaths: Set<String>
    let isFetchingRoot: Bool
    /// v2026.07.20 production regression fix: a successful recycle receipt is already the
    /// visibility authority for the current scan generation. Cached/snapshot rows remain useful
    /// while the expensive accounting prune runs, but every full or incremental Tree projection
    /// must subtract these paths off-main so a sheet re-mount cannot resurrect a moved item.
    let receiptTombstones: DeletionPresentationPathMatcher
    let deletionEvaluation: TreeDeletionEvaluationSnapshot
}

/// 扫描完整性证据到 Tree UI 的唯一投影。
///
/// Tree 有两个不能合并的维度：
/// - issue 与当前行相等，或 issue 是当前行的祖先：当前节点自身不可完整读取，画锁；
/// - 当前行是 issue 的严格祖先：当前节点仍可浏览，只标记“子树含未完整后代”。
///
/// 删除父目录时的安全预检仍需要祖先/后代双向重叠，但那是删除覆盖关系，不能反过来
/// 污染 Tree 的视觉访问状态。所有 TreeRow 合成入口都必须复用这个双轴投影。
private struct TreeScanEvidenceProjection: Sendable {
    struct ProjectedState: Sendable, Equatable {
        let accessState: TreeRow.AccessState
        let subtreeCompleteness: TreeRow.SubtreeCompleteness
    }

    /// v2026.07.17 performance-regression fix: Tree rows are projected many times per
    /// frame. Keeping issue paths in arrays made every row scan every issue three to six
    /// times. Exact/ancestor lookup is now hash based and bounded by path depth, while
    /// strict ancestors are materialized once when a throttled evidence snapshot commits.
    private let permissionDeniedPaths: Set<String>
    private let tccProtectedPaths: Set<String>
    private let incompletePaths: Set<String>
    private let incompleteDescendantAncestors: Set<String>

    init(issues: [ScanIncompleteIssue] = []) {
        var permissionDenied = Set<String>()
        var tccProtected = Set<String>()
        var incomplete = Set<String>()
        var descendantAncestors = Set<String>()
        for issue in issues {
            let path = Self.normalize(issue.path)
            guard !path.isEmpty else { continue }
            switch issue.reason {
            case .permissionDenied:
                permissionDenied.insert(path)
            case .tccProtectedSkipped:
                tccProtected.insert(path)
            case .enumerationFailed, .metadataUnavailable:
                incomplete.insert(path)
            }
            Self.insertStrictAncestors(of: path, into: &descendantAncestors)
        }
        permissionDeniedPaths = permissionDenied
        tccProtectedPaths = tccProtected
        incompletePaths = incomplete
        incompleteDescendantAncestors = descendantAncestors
    }

    func projectedState(
        for path: String,
        fallbackAccessState: TreeRow.AccessState = .normal,
        fallbackSubtreeCompleteness: TreeRow.SubtreeCompleteness = .complete
    ) -> ProjectedState {
        let normalized = Self.normalize(path)
        let accessState: TreeRow.AccessState
        if Self.containsSameOrAncestor(in: tccProtectedPaths, of: normalized) {
            accessState = .tccProtected
        } else if Self.containsSameOrAncestor(in: permissionDeniedPaths, of: normalized) {
            accessState = .permissionDenied
        } else if Self.containsSameOrAncestor(in: incompletePaths, of: normalized) {
            accessState = .incomplete
        } else {
            accessState = fallbackAccessState
        }

        let containsIncompleteDescendant = incompleteDescendantAncestors.contains(normalized)

        return ProjectedState(
            accessState: accessState,
            subtreeCompleteness: containsIncompleteDescendant
                ? .containsIncompleteDescendant
                : fallbackSubtreeCompleteness
        )
    }

    private static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func containsSameOrAncestor(
        in paths: Set<String>,
        of candidate: String
    ) -> Bool {
        guard !candidate.isEmpty else { return false }
        var cursor = candidate
        while true {
            if paths.contains(cursor) { return true }
            guard let parent = parentPath(of: cursor) else { return false }
            cursor = parent
        }
    }

    private static func insertStrictAncestors(
        of path: String,
        into ancestors: inout Set<String>
    ) {
        var cursor = path
        while let parent = parentPath(of: cursor) {
            ancestors.insert(parent)
            cursor = parent
        }
    }

    private static func parentPath(of path: String) -> String? {
        guard !path.isEmpty, path != "/", let slash = path.lastIndex(of: "/") else {
            return nil
        }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}

/// 扫描完整性证据的有序哈希索引。
///
/// 公开投影需要稳定发现顺序，删除详情又必须保留同 scope 下 stage/errno 不同的 rich
/// evidence；因此不能简单改成一个 `Set`。本索引把有序数组只作为最终输出，所有热路径
/// 去重/companion 替换都通过 O(1) 哈希表完成：
/// - exact duplicate 忽略；
/// - generic companion（stage == nil）在同 path/reason 已有任意证据时忽略；
/// - richer typed evidence 到达后原位替换 generic，保留 UI 顺序；
/// - 不同 stage/errno 的 richer evidence 均保留，不能为性能丢安全证据。
private struct ScanIncompleteEvidenceIndex: Sendable {
    private struct ScopeKey: Sendable, Hashable {
        let path: String
        let reason: ScanIncompleteReason
    }

    private(set) var orderedIssues: [ScanIncompleteIssue] = []
    private var exactIndices: [ScanIncompleteIssue: Int] = [:]
    private var genericIndicesByScope: [ScopeKey: Int] = [:]
    private var scopeCounts: [ScopeKey: Int] = [:]

    init(issues: [ScanIncompleteIssue] = []) {
        orderedIssues.reserveCapacity(issues.count)
        exactIndices.reserveCapacity(issues.count)
        genericIndicesByScope.reserveCapacity(issues.count)
        scopeCounts.reserveCapacity(issues.count)
        for issue in issues {
            record(issue)
        }
    }

    var isEmpty: Bool { orderedIssues.isEmpty }

    @discardableResult
    mutating func record(_ issue: ScanIncompleteIssue) -> Bool {
        guard exactIndices[issue] == nil else { return false }

        let scope = ScopeKey(path: issue.path, reason: issue.reason)
        if issue.stage == nil {
            guard scopeCounts[scope, default: 0] == 0 else { return false }
        } else if let genericIndex = genericIndicesByScope.removeValue(forKey: scope) {
            let generic = orderedIssues[genericIndex]
            exactIndices.removeValue(forKey: generic)
            orderedIssues[genericIndex] = issue
            exactIndices[issue] = genericIndex
            return true
        }

        let index = orderedIssues.endIndex
        orderedIssues.append(issue)
        exactIndices[issue] = index
        scopeCounts[scope, default: 0] += 1
        if issue.stage == nil {
            genericIndicesByScope[scope] = index
        }
        return true
    }
}

/// “旧版本残留”每个候选目录的一次完整扫描会话结果。
///
/// 大小、文件数和删除拒绝证据必须来自同一次 BulkScanner 遍历；否则 UI 可能展示
/// 一个不完整大小，却把整个父目录交给删除管线。`deletionDeniedPaths` 包含权限拒绝、
/// TCC 跳过和任何未完整结束的根，供 TrashPipeline 做祖先/后代一票否决。
private struct VersionedRootScanMeasurement: Sendable {
    let allocatedBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int
    let incompleteIssues: Set<ScanIncompleteIssue>

    var deletionDeniedPaths: Set<String> {
        Set(incompleteIssues.map(\.path))
    }
}

private struct VersionedRootMeasuredHit: Sendable {
    let hit: KnownVersionedRoots.Hit
    let measurement: VersionedRootScanMeasurement
}

private struct VersionedRootsProducerOutput: Sendable {
    let entries: [VersionedRootMeasuredHit]
    let discoveryIssues: [ScanIncompleteIssue]
    let wasCancelled: Bool
    let elapsed: TimeInterval
}

/// Crosses the synchronous ScanKit progress callback into the MainActor without making terminal
/// correctness depend on unstructured-task scheduling order. The UI receives live best-effort
/// updates, while scan completion reads this locked latest value and publishes it authoritatively.
/// v2026.07.17: required by the isolated Common App Cache worker checkpoint protocol.
private final class CommonAppCacheProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CommonAppCacheScanner.Progress?

    func store(_ progress: CommonAppCacheScanner.Progress) {
        lock.lock()
        latest = progress
        lock.unlock()
    }

    var snapshot: CommonAppCacheScanner.Progress? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// One typed gap from discovering standard cache rules through `/Applications` metadata.
///
/// v2026.07.18: this source used to be `try?`-based, so an unreadable Applications directory or
/// malformed app bundle silently removed rules while the outer cache scan still claimed complete.
/// Keep stable stage/reason/errno fields only; raw `Error` values and localized descriptions never
/// cross the producer boundary or enter long-lived scan state.
struct StandardInstalledAppCacheRuleDiscoveryIssue: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case rootEnumeration = "root-enumeration"
        case metadataRead = "metadata-read"
        case metadataDecode = "metadata-decode"
    }

    enum Reason: String, Sendable, Equatable {
        case permissionDenied = "permission-denied"
        case enumerationFailed = "enumeration-failed"
        case metadataUnavailable = "metadata-unavailable"
        case tooLarge = "too-large"
        case unsafeType = "unsafe-type"
        case changed
        case malformedMetadata = "malformed-metadata"
    }

    let path: String
    let stage: Stage
    let reason: Reason
    let posixErrorCode: Int32?

    var scanIncompleteIssue: ScanIncompleteIssue {
        let scanReason: ScanIncompleteReason
        switch reason {
        case .permissionDenied:
            scanReason = .permissionDenied
        case .enumerationFailed:
            scanReason = .enumerationFailed
        case .metadataUnavailable, .tooLarge, .unsafeType, .changed, .malformedMetadata:
            scanReason = .metadataUnavailable
        }
        let scanStage: ScanIssueStage = stage == .rootEnumeration ? .enumerate : .metadata
        return ScanIncompleteIssue(
            path: path,
            reason: scanReason,
            stage: scanStage,
            posixErrorCode: posixErrorCode
        )
    }

    var logFields: String {
        let codeValue = posixErrorCode.map(String.init) ?? "none"
        let domain = posixErrorCode == nil ? "none" : NSPOSIXErrorDomain
        return "stage=\(stage.rawValue) reason=\(reason.rawValue) "
            + "domain=\(domain) code=\(codeValue) path=\(path)"
    }
}

struct StandardInstalledAppCacheRuleDiscoveryResult: Sendable {
    let rules: [VendorRule]
    let issues: [StandardInstalledAppCacheRuleDiscoveryIssue]
    let wasCancelled: Bool

    init(
        rules: [VendorRule],
        issues: [StandardInstalledAppCacheRuleDiscoveryIssue] = [],
        wasCancelled: Bool = false
    ) {
        self.rules = rules
        self.issues = issues
        self.wasCancelled = wasCancelled
    }

    static let cancelled = StandardInstalledAppCacheRuleDiscoveryResult(
        rules: [],
        issues: [],
        wasCancelled: true
    )
}

/// Injectable filesystem/metadata surface for deterministic discovery evidence tests.
struct StandardInstalledAppCacheRuleFileSystem: Sendable {
    let contentsOfDirectory: @Sendable (URL) throws -> [String]
    let readMetadata: @Sendable (
        URL,
        @Sendable () -> Bool
    ) throws -> AppMetadata

    static let live = StandardInstalledAppCacheRuleFileSystem(
        contentsOfDirectory: { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        readMetadata: { appURL, shouldCancel in
            try AppMetadata.read(appURL: appURL, shouldCancel: shouldCancel)
        }
    )
}

/// 扫描协调器 —— UI 与 BulkScanner 之间的"减压阀"。
///
/// 设计目标（每条都来自 PITFALLS §5）：
/// - **聚合到一级子目录**：4 万文件 yield 进 SwiftUI List 主线程必崩
/// - **节流 commit**：≥150ms 才发一次 snapshot；每条 .node 直接更新 state 是错的
/// - **按 size 实时排名**：每次 commit 重排，但发现期不动 row identity
/// - **SafetyEngine 内嵌**：每个一级子目录拿到 verdict，UI 直接渲染徽章
/// - **节流期总字节优先稳定**：UI 上的"已扫 X MB"不能跳变
@MainActor
public final class ScanCoordinator: ObservableObject {
    private actor TreeChildrenFetchGate {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Bool, Never>
        }

        private let limit: Int
        private var active = 0
        private var waiters: [Waiter] = []

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        func acquire() async -> Bool {
            if Task.isCancelled { return false }
            if active < limit {
                active += 1
                return true
            }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else {
                        waiters.append(Waiter(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id) }
            }
        }

        private func cancelWaiter(id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        }

        func release() {
            if waiters.isEmpty {
                active = max(0, active - 1)
            } else {
                waiters.removeFirst().continuation.resume(returning: true)
            }
        }

        func diagnostics() -> (active: Int, waiting: Int) {
            (active, waiters.count)
        }
    }

    private nonisolated static let treeChildrenFetchGate = TreeChildrenFetchGate(limit: 2)

    /// The filesystem identity of a Tree measurement. Presentation ordering is deliberately not
    /// part of this value: size/name/date projections all consume the same physical measurement.
    /// Public and physical paths are both frozen because full-disk firmlink projection can make
    /// different public spellings address the same Data-volume subtree.
    ///
    /// v2026.07.19 regression fix: generation/CAS only rejected stale writes; it did not prevent
    /// an old cancelled Tree walk from overlapping its replacement on disk. Every real Tree
    /// producer now enters this component-aware ownership domain before touching the filesystem.
    private struct TreeFilesystemMeasurementIdentity: Sendable, Hashable {
        let publicPath: String
        let physicalPath: String

        init(publicPath: String, physicalPath: String) {
            self.publicPath = Self.standardize(publicPath)
            self.physicalPath = Self.standardize(physicalPath)
        }

        nonisolated private static func standardize(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }

        nonisolated func overlaps(_ other: Self) -> Bool {
            Self.pathsOverlap(publicPath, other.publicPath)
                || Self.pathsOverlap(physicalPath, other.physicalPath)
        }

        nonisolated static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
            path(lhs, belongsTo: rhs) || path(rhs, belongsTo: lhs)
        }

        nonisolated private static func path(_ candidate: String, belongsTo root: String) -> Bool {
            if candidate == root { return true }
            if root == "/" { return candidate.hasPrefix("/") }
            return candidate.hasPrefix(root + "/")
        }
    }

    private enum TreeFilesystemProducerStage: String, Sendable {
        case shallow
        case deep
        case indexedSubtree = "indexed_subtree"
    }

    private enum TreeFilesystemLeaseResult<Value: Sendable>: Sendable {
        case produced(Value)
        case dropped
    }

    /// Path-scoped admission and retirement for *real* Tree filesystem producers.
    ///
    /// A reservation is installed before a producer Task is created, closing the reentrancy gap
    /// where a primary cancellation could otherwise miss a just-admitted Tree walk. Overlapping
    /// paths wait FIFO; unrelated paths are admitted together. Pending cancellation removes the
    /// reservation/waiter without consuming a Tree gate permit. Cache projection, sorting,
    /// `storeFetchedChildren`, and worker retirement never enter this actor.
    private actor TreeFilesystemLeaseDomain {
        private struct Waiter {
            let id: UUID
            let identity: TreeFilesystemMeasurementIdentity
            let stage: TreeFilesystemProducerStage
            let intentID: UUID
            let enqueuedAt: UInt64
            let continuation: CheckedContinuation<Bool, Never>
        }

        private struct ActiveLease {
            let identity: TreeFilesystemMeasurementIdentity
            let stage: TreeFilesystemProducerStage
            let intentID: UUID
            let cancel: @Sendable () -> Void
            let termination: Task<Void, Never>
        }

        private var waiters: [Waiter] = []
        private var reservations: [UUID: TreeFilesystemMeasurementIdentity] = [:]
        private var active: [UUID: ActiveLease] = [:]
        private var externallyCancelledLeaseIDs = Set<UUID>()
        private var cancelAllEpoch: UInt64 = 0
        private var activeCancelAllEpoch: UInt64?

        func run<Value: Sendable>(
            identity: TreeFilesystemMeasurementIdentity,
            stage: TreeFilesystemProducerStage,
            intentID: UUID,
            operation: @escaping @Sendable () async -> Value
        ) async -> TreeFilesystemLeaseResult<Value> {
            guard activeCancelAllEpoch == nil else {
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.drop stage=\(stage.rawValue) intent=\(intentID) "
                        + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                        + "reason=cancel_all_in_progress"
                )
                return .dropped
            }
            let leaseID = UUID()
            guard await acquire(
                id: leaseID,
                identity: identity,
                stage: stage,
                intentID: intentID
            ) else {
                return .dropped
            }
            guard !Task.isCancelled,
                  reservations.removeValue(forKey: leaseID) != nil
            else {
                reservations.removeValue(forKey: leaseID)
                resumeEligibleWaiters()
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.drop stage=\(stage.rawValue) intent=\(intentID) "
                        + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                        + "reason=cancelled_before_start"
                )
                return .dropped
            }

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let producer = Task.detached(priority: .userInitiated) {
                await operation()
            }
            let termination = Task.detached(priority: .utility) {
                _ = await producer.value
            }
            active[leaseID] = ActiveLease(
                identity: identity,
                stage: stage,
                intentID: intentID,
                cancel: { producer.cancel() },
                termination: termination
            )
            GSYLog.info(
                .flow,
                "tree.fs_lease.start stage=\(stage.rawValue) intent=\(intentID) "
                    + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath)"
            )

            let value = await withTaskCancellationHandler {
                await producer.value
            } onCancel: {
                producer.cancel()
            }
            let wasCancelled = Task.isCancelled
                || externallyCancelledLeaseIDs.remove(leaseID) != nil
            active.removeValue(forKey: leaseID)
            resumeEligibleWaiters()
            let elapsedMs = Double(
                DispatchTime.now().uptimeNanoseconds - startedAt
            ) / 1_000_000
            GSYLog.info(
                .flow,
                "tree.fs_lease.finish stage=\(stage.rawValue) intent=\(intentID) "
                    + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                    + "cancelled=\(wasCancelled) elapsed_ms=\(String(format: "%.2f", elapsedMs))"
            )
            return wasCancelled ? .dropped : .produced(value)
        }

        /// Primary scan admission calls this through one settlement Task. The returned async
        /// boundary does not finish until every producer that had actually started has returned;
        /// presentation owners are absent by construction.
        func cancelAllAndWait(reason: String) async {
            cancelAllEpoch &+= 1
            let epoch = cancelAllEpoch
            activeCancelAllEpoch = epoch
            let pending = waiters
            waiters = []
            reservations.removeAll(keepingCapacity: true)
            for waiter in pending {
                waiter.continuation.resume(returning: false)
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.drop stage=\(waiter.stage.rawValue) intent=\(waiter.intentID) "
                        + "public_path=\(waiter.identity.publicPath) "
                        + "physical_path=\(waiter.identity.physicalPath) "
                        + "reason=cancel_all_pending"
                )
            }

            let leases = Array(active.values)
            let activePathCount = Set(leases.map(\.identity)).count
            guard !leases.isEmpty else {
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.cancel_all.finish reason=\(reason) active=0 paths=0 "
                        + "pending=\(pending.count)"
                )
                if activeCancelAllEpoch == epoch { activeCancelAllEpoch = nil }
                return
            }
            GSYLog.notice(
                .flow,
                "tree.fs_lease.cancel_all.start reason=\(reason) active=\(leases.count) "
                    + "paths=\(activePathCount) "
                    + "pending=\(pending.count)"
            )
            externallyCancelledLeaseIDs.formUnion(active.keys)
            for lease in leases { lease.cancel() }
            for lease in leases { await lease.termination.value }
            GSYLog.notice(
                .flow,
                "tree.fs_lease.cancel_all.finish reason=\(reason) active=\(leases.count) "
                    + "paths=\(activePathCount) "
                    + "pending=\(pending.count)"
            )
            if activeCancelAllEpoch == epoch { activeCancelAllEpoch = nil }
        }

        func diagnostics() -> (active: Int, waiting: Int, reserved: Int) {
            (active.count, waiters.count, reservations.count)
        }

        private func acquire(
            id: UUID,
            identity: TreeFilesystemMeasurementIdentity,
            stage: TreeFilesystemProducerStage,
            intentID: UUID
        ) async -> Bool {
            // v2026.07.19 regression guard: `run` can yield while entering this actor method.
            // Recheck the drain epoch at the reservation boundary so a Tree producer cannot slip
            // into the filesystem domain after primary cancellation has taken its snapshot.
            guard activeCancelAllEpoch == nil else {
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.drop stage=\(stage.rawValue) intent=\(intentID) "
                        + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                        + "reason=cancel_all_in_progress"
                )
                return false
            }
            guard !Task.isCancelled else {
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.drop stage=\(stage.rawValue) intent=\(intentID) "
                        + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                        + "reason=cancelled_before_wait"
                )
                return false
            }
            if canAdmitImmediately(identity) {
                reservations[id] = identity
                return true
            }

            let enqueuedAt = DispatchTime.now().uptimeNanoseconds
            let blockers = conflictingClaimCount(for: identity)
            GSYLog.info(
                .flow,
                "tree.fs_lease.wait.start stage=\(stage.rawValue) intent=\(intentID) "
                    + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                    + "blockers=\(blockers)"
            )
            let admitted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else {
                        waiters.append(Waiter(
                            id: id,
                            identity: identity,
                            stage: stage,
                            intentID: intentID,
                            enqueuedAt: enqueuedAt,
                            continuation: continuation
                        ))
                    }
                }
            } onCancel: {
                Task { await self.cancelAdmission(id: id) }
            }
            let elapsedMs = Double(
                DispatchTime.now().uptimeNanoseconds - enqueuedAt
            ) / 1_000_000
            GSYLog.info(
                .flow,
                "tree.fs_lease.wait.finish stage=\(stage.rawValue) intent=\(intentID) "
                    + "public_path=\(identity.publicPath) physical_path=\(identity.physicalPath) "
                    + "admitted=\(admitted) elapsed_ms=\(String(format: "%.2f", elapsedMs))"
            )
            return admitted
        }

        private func canAdmitImmediately(
            _ identity: TreeFilesystemMeasurementIdentity
        ) -> Bool {
            !active.values.contains(where: { $0.identity.overlaps(identity) })
                && !reservations.values.contains(where: { $0.overlaps(identity) })
                && !waiters.contains(where: { $0.identity.overlaps(identity) })
        }

        private func conflictingClaimCount(
            for identity: TreeFilesystemMeasurementIdentity
        ) -> Int {
            active.values.lazy.filter { $0.identity.overlaps(identity) }.count
                + reservations.values.lazy.filter { $0.overlaps(identity) }.count
                + waiters.lazy.filter { $0.identity.overlaps(identity) }.count
        }

        private func cancelAdmission(id: UUID) {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(returning: false)
                resumeEligibleWaiters()
                GSYLog.info(
                    .flow,
                    "tree.fs_lease.drop stage=\(waiter.stage.rawValue) intent=\(waiter.intentID) "
                        + "public_path=\(waiter.identity.publicPath) "
                        + "physical_path=\(waiter.identity.physicalPath) reason=cancelled_pending"
                )
                return
            }
            if reservations.removeValue(forKey: id) != nil {
                resumeEligibleWaiters()
            }
        }

        /// Preserve FIFO for overlapping identities while admitting all unrelated identities in
        /// the same actor turn. Blocked earlier waiters become claims for later overlap checks, so
        /// a hot stream of descendants cannot starve an already queued ancestor.
        private func resumeEligibleWaiters() {
            guard !waiters.isEmpty else { return }
            var claims = active.values.map(\.identity) + Array(reservations.values)
            var remaining: [Waiter] = []
            remaining.reserveCapacity(waiters.count)
            for waiter in waiters {
                if claims.contains(where: { $0.overlaps(waiter.identity) }) {
                    remaining.append(waiter)
                    claims.append(waiter.identity)
                } else {
                    reservations[waiter.id] = waiter.identity
                    claims.append(waiter.identity)
                    waiter.continuation.resume(returning: true)
                }
            }
            waiters = remaining
        }
    }

    private let treeFilesystemLeaseDomain = TreeFilesystemLeaseDomain()

    /// Typed identity for a primary scan request. A replacement may spend an unbounded amount of
    /// time waiting for the cancelled filesystem producer to release ownership, so callers and
    /// diagnostics must be able to distinguish that settlement from real scanning.
    public enum PrimaryScanIntent: Sendable, Equatable {
        case category(String)
        case versionedRoots
        case commonAppCaches
        case multiRoot(String)
        case developerArtifacts

        fileprivate var logValue: String {
            switch self {
            case .category(let categoryID): return "category:\(categoryID)"
            case .versionedRoots: return "versioned_roots"
            case .commonAppCaches: return "common_app_caches"
            case .multiRoot(let name): return "multi_root:\(name)"
            case .developerArtifacts: return "developer_artifacts"
            }
        }
    }

    public struct ScanSettlementState: Sendable, Equatable {
        public let intent: PrimaryScanIntent
        public let predecessorGeneration: UUID
        public let intentID: UUID

        public init(
            intent: PrimaryScanIntent,
            predecessorGeneration: UUID,
            intentID: UUID
        ) {
            self.intent = intent
            self.predecessorGeneration = predecessorGeneration
            self.intentID = intentID
        }
    }

    public enum ScanPhase: Sendable, Equatable {
        case idle
        /// v2026.07.19 performance-regression contract: the old producer is cancelled but has not
        /// yet returned. `isScanning` remains false and the previous stable snapshot stays visible;
        /// only the latest intent may transition from this state into `.scanning`.
        case settling(ScanSettlementState)
        case scanning

        /// User-facing ownership handoff is derived from the typed phase, never inferred from
        /// `isScanning == false`. That distinction prevents the UI from presenting a stalled old
        /// producer as either an idle screen or a replacement scan that has already begun.
        public var settlementStatusPresentation: LocalizedTextDescriptor? {
            guard case .settling = self else { return nil }
            return .catalog("main.scan.settling")
        }
    }

    /// 扫描器明确发出的致命终态。它与权限拒绝、TCC 跳过、deadline/max-entry
    /// 等“带精确拒绝路径的受限结果”分开保存，消费者不得通过比较本地化错误文案
    /// 来猜测终态类型。
    public struct TerminalFailure: Sendable, Equatable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    @Published public private(set) var snapshot: ScanSnapshot = .empty
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var scanPhase: ScanPhase = .idle
    /// v2026.07.17 Common-app-cache progress is group based, not inode based. Keeping it typed
    /// prevents the UI from inventing a fake byte denominator while still exposing the current
    /// path and the last process-safe checkpoint during an isolated worker scan.
    @Published public private(set) var commonAppCacheProgress: CommonAppCacheScanner.Progress?
    @Published public private(set) var lastError: String?
    public private(set) var terminalFailure: TerminalFailure?
    /// v2026.07.17 performance evidence: producer and UI/coordinator terminal clocks must be
    /// observable separately. A scanner-side time alone cannot reveal an unbounded consumer
    /// backlog, which was the root cause of the multi-minute UI regression.
    public private(set) var lastProducerTerminalElapsed: TimeInterval?
    public private(set) var lastConsumerDrainLag: TimeInterval?
    /// Duration of the latest authoritative primary-producer settlement. This is kept separate
    /// from scan elapsed so field reports can distinguish ownership handoff from filesystem work.
    public private(set) var lastScanSettlementDuration: TimeInterval?
    /// 当前扫描会话的权威完整性证据。路径、原因、失败阶段和 errno 必须在这里保留；
    /// 下面三个 path 数组仅用于兼容现有 UI / 删除调用方，统一由本数组投影，禁止单独写入。
    @Published public private(set) var incompleteScanIssues: [ScanIncompleteIssue] = []
    /// v2026.07.17 Tree 完整性证据链路修复：主扫描与按需 Tree 扫描是
    /// 两个独立证据来源。旧实现只把 Tree localIssues 画在 row 上，却没有
    /// 进入 `incompleteScanIssues`，删除预检因此看不到用户展开后新发现的缺口。
    /// 这里保留来源索引：主扫描按会话替换，Tree 按 fetch root 替换，
    /// 再统一投影到公共数组；不允许只追加从而留下已恢复的陈旧拒绝。
    private var primaryIncompleteEvidence = ScanIncompleteEvidenceIndex()
    private var treeIncompleteEvidenceByRoot: [String: ScanIncompleteEvidenceIndex] = [:]
    /// v2026.07.17 performance-regression fix: ScanKit can legitimately emit a generic
    /// companion plus rich typed evidence for many paths. The old implementation rebuilt
    /// four complete projections after every event, making ingestion O(n²) on issue-heavy
    /// trees. Mutations now only dirty the projection; the existing scan snapshot throttle,
    /// authoritative batch replacement, or a safety read commits it once.
    private var incompleteEvidenceProjectionDirty = false
    private var incompleteEvidenceProjectionRebuildCount = 0
    /// Source-only CAS revision for off-main terminal evidence preparation. Publishing a prepared
    /// projection does not advance it; only primary/Tree evidence mutations do.
    private var incompleteEvidenceSourceRevision: UInt64 = 0
    @Published public private(set) var permissionDeniedPaths: [String] = []
    /// 扫描器明确报告“未完整遍历”的路径。它与权限拒绝/TCC 跳过分开保存，
    /// 避免把通用枚举错误误导成 FDA 问题；删除预检仍会把三类证据取并集，一票否决。
    @Published public private(set) var incompleteScanPaths: [String] = []
    /// v2026.07 修复：`pruneDeleted` 完成后的公共广播信号。
    ///
    /// **根因**：非 tree/list 走 `snapshot.rows` 的视图（如 [LargeFilesView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/LargeFilesView.swift)）
    /// 用 `coordinator.largeFiles(...)` 读 `largeFileLeaves`；`pruneDeleted` 会正确剔掉叶子，
    /// 但它只 bump 了 non-@Published 的 `structuralRevision`——SwiftUI 视图订阅不到，
    /// 表现为"点了移到废纸篓成功，但列表还在"（用户反馈 Q2）。
    /// 现在 `pruneDeleted` 尾部再 `storeRevision &+= 1`，任何依赖 store 派生数据的视图
    /// `.onReceive(coordinator.$storeRevision)` 即可强同步。
    /// 只在 `pruneDeleted` 里 bump（非"每次 snapshot 都推"），避免扫描期 UI churn。
    @Published public private(set) var storeRevision: UInt64 = 0
    /// v1.1：因 TCC 雷区（Music / Photos / Mail 等）被主动 skip 的路径列表。
    /// 与 permissionDeniedPaths 合并展示在统一 banner，**不会触发系统弹窗**。
    @Published public private(set) var tccProtectedSkippedPaths: [String] = []
    private var treeScanEvidenceProjection = TreeScanEvidenceProjection()

    /// v1.3 P0-D：开发者构建产物勘察是否触发了截断（命中数达上限 或 walk 超时）。
    /// UI 在 dev 扫描结果区可读此标志展示 banner："命中过多，仅展示前 N 项"。
    /// 仅在 scanDeveloper 路径上有意义；其他扫描入口启动时会被清零。
    @Published public private(set) var devArtifactDidTruncate: Bool = false
    @Published public private(set) var devArtifactDidTimeout: Bool = false

    /// M4-T1：本轮扫描启动时从 [WhitelistStore.shared](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift)
    /// 拉一份的内存快照（normalized 后的 path Set）。publishSnapshot 是同步函数，
    /// 不能在 hot path 里 `await` 一个 actor —— 因此扫描入口拉一次快照，全程同步命中。
    /// 命中判定与 WhitelistStore.isWhitelisted 一致：完全相等 或 entry+"/" 作为 path prefix。
    private var whitelistSnapshot: Set<String> = []

    /// 白名单是用户显式表达的“永不展示/永不清理”边界，优先级高于 SafetyEngine。
    /// 这里保持与 `WhitelistStore.isWhitelisted` 完全相同的目录边界语义，供扫描热路径
    /// 使用一次性快照同步判断，避免逐 node 跨 actor。
    private nonisolated static func isWhitelisted(_ path: String,
                                                   in snapshot: Set<String>) -> Bool {
        guard !snapshot.isEmpty else { return false }
        var normalized = SafetyEngine.stripDataVolumePrefix(path)
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if snapshot.contains(normalized) { return true }
        let lowerNormalized = normalized.lowercased()
        for entry in snapshot {
            if normalized.hasPrefix(entry + "/") {
                return true
            }
            let lowerEntry = entry.lowercased()
            if lowerNormalized == lowerEntry || lowerNormalized.hasPrefix(lowerEntry + "/") {
                return true
            }
        }
        return false
    }

    private func isWhitelisted(_ path: String) -> Bool {
        Self.isWhitelisted(path, in: whitelistSnapshot)
    }

    /// TCCSkipList is a product privacy boundary, not an authorization fallback. Full Disk
    /// Access changes what macOS would permit, but it must never expand what this app chooses to
    /// enumerate. Keeping the FDA argument makes every call site state the distinction explicitly
    /// and gives regression tests a stable contract for granted/unknown/denied.
    private nonisolated static func shouldRespectTCCSkipList(
        fdaStatus _: FDAProbe.Status
    ) -> Bool {
        true
    }

    private nonisolated static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.count > 1 && lhs.hasSuffix("/") ? String(lhs.dropLast()) : lhs
        let right = rhs.count > 1 && rhs.hasSuffix("/") ? String(rhs.dropLast()) : rhs
        if left == right { return true }
        if left == "/" || right == "/" { return true }
        return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// 当前完成会话中与删除目标存在祖先/后代关系的 typed incomplete evidence。
    /// Professional target revalidator 只接受本结果；旧的聚合 path Set 不能反推 reason。
    public func incompleteIssues(overlappingAny paths: [String]) -> [ScanIncompleteIssue] {
        // 删除预检是安全读边界，不能等待下一次 UI throttle；即使扫描事件刚到达，
        // 这里也必须先提交 buffered typed evidence 再计算 overlap。
        commitIncompleteEvidenceProjectionsIfNeeded()
        let normalizedTargets = paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard !normalizedTargets.isEmpty else { return [] }
        return incompleteScanIssues.filter { issue in
            normalizedTargets.contains { Self.pathsOverlap($0, issue.path) }
        }
    }

    /// 主扫描与按需 Tree 证据在这里合并成唯一公开投影；旧 path 数组和
    /// Tree 行状态也在这里一次性同步。消费方不得绕过来源索引单独写入。
    /// 每个字段只在值真的变化时写入，避免同一 ScanKit issue 的兼容事件
    /// (`permissionDenied` + `incomplete`) 造成多轮无意义 SwiftUI invalidation。
    private func commitIncompleteEvidenceProjectionsIfNeeded() {
        guard incompleteEvidenceProjectionDirty else { return }
        let prepared = Self.buildIncompleteEvidenceProjection(
            primaryEvidence: primaryIncompleteEvidence,
            treeEvidenceByRoot: treeIncompleteEvidenceByRoot,
            previousIssues: incompleteScanIssues,
            previousPermissionPaths: permissionDeniedPaths,
            previousTCCPaths: tccProtectedSkippedPaths,
            previousAllPaths: incompleteScanPaths
        )
        applyPreparedIncompleteEvidenceProjection(prepared)
    }

    /// Pure evidence merge used both by synchronous fail-closed safety reads and by the terminal
    /// background worker. The terminal path calls this only on a generic executor.
    nonisolated private static func buildIncompleteEvidenceProjection(
        primaryEvidence: ScanIncompleteEvidenceIndex,
        treeEvidenceByRoot: [String: ScanIncompleteEvidenceIndex],
        previousIssues: [ScanIncompleteIssue],
        previousPermissionPaths: [String],
        previousTCCPaths: [String],
        previousAllPaths: [String]
    ) -> PreparedIncompleteEvidenceProjection {
        var combinedEvidence = ScanIncompleteEvidenceIndex()
        for issue in primaryEvidence.orderedIssues {
            combinedEvidence.record(issue)
        }
        // Dictionary 遍历顺序不稳定；公开 @Published 值必须稳定，否则每次
        // Tree 写回都可能因为纯顺序变化无意义地 invalidating SwiftUI。
        for root in treeEvidenceByRoot.keys.sorted() {
            guard let evidence = treeEvidenceByRoot[root] else { continue }
            for issue in evidence.orderedIssues {
                combinedEvidence.record(issue)
            }
        }
        let combinedIssues = combinedEvidence.orderedIssues
        let nextTreeProjection = TreeScanEvidenceProjection(issues: combinedIssues)
        let permissionPaths = Self.stableUniquePaths(
            combinedIssues.lazy
                .filter { $0.reason == .permissionDenied }
                .map(\.path)
        )
        let tccPaths = Self.stableUniquePaths(
            combinedIssues.lazy
                .filter { $0.reason == .tccProtectedSkipped }
                .map(\.path)
        )
        let allPaths = Self.stableUniquePaths(combinedIssues.lazy.map(\.path))

        return PreparedIncompleteEvidenceProjection(
            combinedIssues: combinedIssues,
            treeProjection: nextTreeProjection,
            permissionPaths: permissionPaths,
            tccPaths: tccPaths,
            allPaths: allPaths,
            issuesChanged: previousIssues != combinedIssues,
            permissionPathsChanged: previousPermissionPaths != permissionPaths,
            tccPathsChanged: previousTCCPaths != tccPaths,
            allPathsChanged: previousAllPaths != allPaths,
            ranOnMainThread: Thread.isMainThread
        )
    }

    private func applyPreparedIncompleteEvidenceProjection(
        _ prepared: PreparedIncompleteEvidenceProjection
    ) {
        // Clear before @Published sends synchronously. A re-entrant safety read sees a fully built
        // tree projection rather than rebuilding the same sources again.
        treeScanEvidenceProjection = prepared.treeProjection
        incompleteEvidenceProjectionDirty = false
        incompleteEvidenceProjectionRebuildCount &+= 1
        if prepared.issuesChanged {
            incompleteScanIssues = prepared.combinedIssues
        }
        if prepared.permissionPathsChanged {
            permissionDeniedPaths = prepared.permissionPaths
        }
        if prepared.tccPathsChanged {
            tccProtectedSkippedPaths = prepared.tccPaths
        }
        if prepared.allPathsChanged {
            incompleteScanPaths = prepared.allPaths
        }
    }

    private nonisolated static func stableUniquePaths<S: Sequence>(_ paths: S) -> [String]
    where S.Element == String {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private func resetIncompleteEvidence() {
        // Reset is a revision boundary, not an ordinary event. Discard any uncommitted old
        // generation first, then publish the empty projection once so it cannot leak into the
        // next page even when the old stream closes without a terminal snapshot.
        primaryIncompleteEvidence = ScanIncompleteEvidenceIndex()
        treeIncompleteEvidenceByRoot.removeAll(keepingCapacity: true)
        incompleteEvidenceProjectionDirty = true
        incompleteEvidenceSourceRevision &+= 1
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    private func replaceIncompleteEvidence(with issues: [ScanIncompleteIssue]) {
        let replacement = ScanIncompleteEvidenceIndex(
            issues: issues.map(Self.normalizedIncompleteIssue)
        )
        if primaryIncompleteEvidence.orderedIssues != replacement.orderedIssues {
            primaryIncompleteEvidence = replacement
            incompleteEvidenceProjectionDirty = true
            incompleteEvidenceSourceRevision &+= 1
        }
        // Batch scanners already crossed an authoritative terminal boundary; publish their
        // complete evidence atomically rather than waiting for an unrelated snapshot tick.
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    /// 按需 Tree 每个 fetch root 的证据是替换语义。完整重扫传入空数组会
    /// 清掉该 root 上一轮的缺口；取消不调用本方法，仍保留旧证据 fail-closed。
    private func replaceTreeIncompleteEvidence(
        rootPath: String,
        with issues: [ScanIncompleteIssue]
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let normalizedCandidates = issues
            .map(Self.normalizedIncompleteIssue)
            .sorted(by: Self.incompleteIssueComesBefore)
        // ScanKit 为兼容旧消费方会先发一条无 stage 的 companion event，
        // 再发带 stage/errno 的 typed incomplete。同路径/原因存在丰富证据时
        // 只保留丰富版，避免 Tree 一次缺口在 banner/删除详情里重复两次。
        let replacement = ScanIncompleteEvidenceIndex(issues: normalizedCandidates)
        let previousIssues = treeIncompleteEvidenceByRoot[root]?.orderedIssues ?? []
        if replacement.isEmpty {
            if treeIncompleteEvidenceByRoot.removeValue(forKey: root) != nil {
                incompleteEvidenceProjectionDirty = true
                incompleteEvidenceSourceRevision &+= 1
            }
        } else if previousIssues != replacement.orderedIssues {
            treeIncompleteEvidenceByRoot[root] = replacement
            incompleteEvidenceProjectionDirty = true
            incompleteEvidenceSourceRevision &+= 1
        }
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    private func recordIncompleteIssue(
        _ issue: ScanIncompleteIssue,
        displayRootPath: String? = nil
    ) {
        // v2026.07.17 整盘安全证据命名空间修复：容量投影已把 Data 卷
        // `/System/Volumes/Data/Users/...` 映射为公开 `/Users/...`，但旧的
        // incomplete/permission 仍保留 raw path。Tree 和删除预检都按公开行路径做
        // ancestor overlap，两个命名空间不一致会漏掉子树一票否决。证据现在与
        // 同轮 projection 共用映射边界；raw path 仍由 ScanKit 结构化日志保留。
        let displayPath = displayRootPath.map {
            displayPathForScanNode(issue.path, rootPath: $0)
        } ?? issue.path
        let normalized = URL(fileURLWithPath: displayPath).standardizedFileURL.path
        let normalizedIssue = ScanIncompleteIssue(
            path: normalized,
            reason: issue.reason,
            stage: issue.stage,
            posixErrorCode: issue.posixErrorCode
        )
        if primaryIncompleteEvidence.record(normalizedIssue) {
            incompleteEvidenceProjectionDirty = true
            incompleteEvidenceSourceRevision &+= 1
        }
    }

    private func projectedTreeState(
        for path: String,
        fallbackAccessState: TreeRow.AccessState = .normal,
        fallbackSubtreeCompleteness: TreeRow.SubtreeCompleteness = .complete
    ) -> TreeScanEvidenceProjection.ProjectedState {
        // 这里只读取最近一次提交的快照。禁止从 SwiftUI row synthesis 中触发
        // @Published 写入；scan snapshot / per-root sync / Tree batch / safety read
        // 都会在各自明确边界提前 commit。
        treeScanEvidenceProjection.projectedState(
            for: path,
            fallbackAccessState: fallbackAccessState,
            fallbackSubtreeCompleteness: fallbackSubtreeCompleteness
        )
    }

    /// v2026.10.07 C4: a directory can have no child rows because it was deliberately skipped
    /// or could not be read. Normal analysis consumes the same typed node-access projection as
    /// Tree; child-row emptiness is never evidence that the directory itself was measured empty.
    func directoryAccessState(for path: String) -> TreeRow.AccessState {
        projectedTreeState(for: path).accessState
    }

    private nonisolated static func normalizedIncompleteIssue(
        _ issue: ScanIncompleteIssue
    ) -> ScanIncompleteIssue {
        let path = issue.path.isEmpty
            ? ""
            : URL(fileURLWithPath: issue.path).standardizedFileURL.path
        return ScanIncompleteIssue(
            path: path,
            reason: issue.reason,
            stage: issue.stage,
            posixErrorCode: issue.posixErrorCode
        )
    }

    private nonisolated static func incompleteIssueComesBefore(
        _ lhs: ScanIncompleteIssue,
        _ rhs: ScanIncompleteIssue
    ) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.reason != rhs.reason { return lhs.reason.rawValue < rhs.reason.rawValue }
        let lhsStage = lhs.stage?.rawValue ?? ""
        let rhsStage = rhs.stage?.rawValue ?? ""
        if lhsStage != rhsStage { return lhsStage < rhsStage }
        return (lhs.posixErrorCode ?? .min) < (rhs.posixErrorCode ?? .min)
    }

    private enum ScanFailureScope {
        case root(ScanIncompleteIssue)
        case descendant(ScanIncompleteIssue)
    }

    /// 兼容旧 ScanKit 生产者可能把 descendant failure 发成 `.failed` 的情况；新合同下
    /// `.failed` 只应指向 root。消费者仍根据 error 自带 path 校验 scope，避免一次生产者
    /// 回归再次把精确 child 缺口扩大成整个扫描根失败。
    private nonisolated static func scanFailureScope(
        _ error: any Error,
        rootPath: String
    ) -> ScanFailureScope {
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard let scanError = error as? ScanError else {
            return .root(ScanIncompleteIssue(
                path: standardizedRoot,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
        }

        let failedPath: String
        let stage: ScanIssueStage
        let posixErrorCode: Int32?
        switch scanError {
        case .cannotEnumerate(let path, let errorStage, let errorCode):
            failedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            stage = errorStage
            posixErrorCode = errorCode
        }
        let reason: ScanIncompleteReason
        if posixErrorCode == EACCES || posixErrorCode == EPERM {
            reason = .permissionDenied
        } else if stage == .metadata {
            reason = .metadataUnavailable
        } else {
            reason = .enumerationFailed
        }
        let issue = ScanIncompleteIssue(
            path: failedPath,
            reason: reason,
            stage: stage,
            posixErrorCode: posixErrorCode
        )
        if failedPath != standardizedRoot,
           failedPath.hasPrefix(standardizedRoot == "/" ? "/" : standardizedRoot + "/") {
            return .descendant(issue)
        }
        return .root(issue)
    }

    /// 记录 `.failed` 并返回它是否真的是 root 级致命失败。descendant 只进入结构化
    /// incomplete evidence，绝不写 terminalFailure / lastError。
    @discardableResult
    private func consumeScanFailure(
        _ error: any Error,
        rootPath: String,
        messagePrefix: String? = nil,
        displayRootPath: String? = nil,
        publishPresentationImmediately: Bool = true
    ) -> Bool {
        switch Self.scanFailureScope(error, rootPath: rootPath) {
        case .descendant(let issue):
            recordIncompleteIssue(issue, displayRootPath: displayRootPath)
            return false
        case .root(let issue):
            recordIncompleteIssue(issue, displayRootPath: displayRootPath)
            // v2026.07.17 root-cause fix: scanner errors may contain errno, raw paths, enum
            // formatting, or percent-encoded implementation detail. Keep that evidence in the
            // structured diagnostic channel only; the long-lived UI state must never make a raw
            // Error available for accidental presentation by a future consumer.
            let diagnosticLabel = messagePrefix ?? rootPath
            GSYLog.error(
                .scan,
                "scan.root.failed root=\(rootPath) label=\(diagnosticLabel) error=\(String(describing: error))"
            )
            if publishPresentationImmediately {
                // Non-projection callers preserve the established immediate error contract. A
                // projection scan can have thousands of buffered issues, so its root failure is
                // published by the terminal background transaction instead of rebuilding the
                // complete evidence/Tree projection here on MainActor.
                commitIncompleteEvidenceProjectionsIfNeeded()
                let message = AppLocalization.string(
                    "main.scan.incomplete",
                    locale: presentationLocale
                )
                terminalFailure = TerminalFailure(message: message)
                lastError = message
            }
            return true
        }
    }

    /// v1.3：主列表（推荐清理 / 自定义路径）排序键。默认 `.sizeDesc`（按大小从大到小）。
    ///
    /// - 切换时立刻重发当前 snapshot，UI 列表实时按新排序刷新（不需要重扫）。
    /// - **仅作用于扫描完成态（finished=true）**；扫描进行中 publishSnapshot 强制按 path 字典序，
    ///   避免最大 bucket 永远霸占第一行造成"只一行在动"错觉（v1.3 publishSnapshot 注释有详细背景）。
    /// - 由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    ///   在启动时与 onChange 时从 [AppSettings.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    ///   同步过来。
    @Published public var mainListSortKey: MainListSortKey = .sizeDesc {
        didSet {
            guard oldValue != mainListSortKey else { return }
            // 排序只投影当前已发布 rows，不能重新从 buckets 物化。versioned/common
            // 等专用入口没有 buckets，旧做法会在切换排序时把真实结果清空；同时
            // partial 的可信度也必须原样保留，绝不能被 UI 重排提升成完整成功。
            guard snapshot.isFinished else { return }
            // v2026.07.18 P2 root-cause fix: a finished projection can still contain thousands
            // of rows. Reuse the revision-checked presentation worker instead of sorting them
            // synchronously in a Settings/UI property observer.
            scheduleLocaleReprojection(locale: presentationLocale)
        }
    }
    /// 当前界面的 presentation locale。扫描任务只保存语义描述；这里仅负责完成态名称
    /// 排序与 AppKit/SwiftUI 投影，不再参与文件遍历或把启动语言写回扫描结果。
    /// v2026.07.17：App 级 fanout 在语言变化时同步长期存活的 Professional / Smart Care
    /// 实例；MainView 仍可幂等同步，语言切换绝不触发重扫。
    private var presentationLocale: Locale = .current

    public func updatePresentationLocale(_ locale: Locale) {
        guard presentationLocale.identifier != locale.identifier else { return }
        presentationLocale = locale
        // Locale changes are presentation transactions, never scan triggers. Name comparisons can
        // touch every expanded/root row, so the complete reprojection is actor-owned and committed
        // by revision instead of running synchronously in Settings/UI callbacks.
        scheduleLocaleReprojection(locale: locale)
    }

    /// 仅供 AppUI 行为测试确认 App 级 fanout 同时覆盖两个协调器。
    /// 读取 locale 本身不触发 objectWillChange；只有完成态“按名称排序”需要重发同一批
    /// 语义 rows 的轻量排序投影，路径/容量/安全证据均不变。
    var _presentationLocaleIdentifierForTesting: String {
        presentationLocale.identifier
    }
    private var lastFinishedCategoryID: String?

    /// 当前/最近一次扫描的根路径；`nil` 表示尚未发起任何扫描（notStarted 态）。
    /// UI 用它在 `finishedEmpty(rootPath:)` 三态里显示具体目录，避免硬编码 `~/Library/Caches`。
    @Published public private(set) var currentRootPath: String?

    /// v1.3：FDA（完全磁盘访问）探测结果。
    /// - `granted`：系统访问已授权，但产品隐私合同仍然硬 skip TCCSkipList
    /// - `denied` / `unknown`：用于权限错误展示，不改变扫描范围
    /// 启动时探测一次；`refreshFDAStatus()` 让 UI（如从设置回到 App）能手动重探。
    @Published public private(set) var fdaStatus: FDAProbe.Status

    /// v1.3：磁盘卷容量信息（"482.95 GB of 494.38 GB used"）。
    /// 启动时探一次，每次扫描完成 / 删除完成后再探一次（容量是系统数据，需要重新读）。
    @Published public private(set) var volumeSnapshot: VolumeCapacity.Snapshot?

    /// v1.3.x：macOS 用了多少**硬盘空间**当虚拟内存（swap）+ 休眠镜像（sleepimage）。
    /// 与 [volumeSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L55-L55)
    /// 共用同一刷新时机：启动 / 扫描完成 / 删除完成。
    /// 仅供 UI 只读展示——swap 与 sleepimage 由内核管理，App 不应清理。
    @Published public private(set) var swapSnapshot: SwapProbe.Snapshot?

    /// v1.3：上一次扫描是否被用户主动 cancel 而中断。
    /// statusBar 借此把"已停止"与"还未扫描"区分开——
    /// 不区分会让用户以为按下停止后什么都没干。
    /// 任何新 scan 入口启动时清回 false。
    @Published public private(set) var wasCancelled: Bool = false

    /// v1.3：多根并行扫描时每根的进度信息。key=rootPath。
    /// - 单根扫描入口（scan/scanFullDisk）保持空 dict —— UI 据此回退到老的"扫描中… N 个文件 · X MB"单行；
    /// - 多根扫描入口（scanRecommended）会预填 5 条（每根一条）isFinished=false，
    ///   每收到一条 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
    ///   按 rootPath 累加 bytes / fileCount；该根 .finished 事件到达时翻 isFinished=true。
    /// v1.3.zz 性能修复：每文件不再直接写 @Published（每写都触发 SwiftUI 全 view 重算），改成
    /// 写到 perRootStaging（普通字典），由 publishSnapshot（throttle 0.4s）批量同步到这里。
    ///
    /// v1.5 P1-B 性能修复：旧实现是整个 dict 替换 → SwiftUI 把 statusBar / 多根 ScrollView
    /// 大面积重 diff。dev scan 几十/几百根时极其卡。改为拆分为两份 @Published：
    /// - [perRootProgressActive](#)：仅 in-flight（isFinished==false）的根，体量小、变化频繁；
    /// - [perRootFinishedSlim](#)：已 finished 的根的轻量快照，体量随完成数增长但每个根只 push 一次；
    /// - [perRootFinishedCount](#)：finished 数量，方便 UI 只看个数变化触发刷新。
    /// 本字段保留为只读计算属性合并两者，让现有读取者（树形顶层合成 / status banner）无须改动。
    public var perRootProgress: [String: PerRootProgress] {
        if perRootFinishedSlim.isEmpty { return perRootProgressActive }
        if perRootProgressActive.isEmpty { return perRootFinishedSlim }
        return perRootProgressActive.merging(perRootFinishedSlim) { active, _ in active }
    }

    /// v2026.07.20: live progress is intentionally not published by the broad coordinator.
    /// `liveProgress` owns UI notifications, while these mirrors remain the authoritative input
    /// for terminal projection, prune accounting and compatibility reads.
    public private(set) var perRootProgressActive: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：已 finished 根的轻量快照（保留 bytes/fileCount/title 用于树形顶层），
    /// 每根 finish 时一次性 push，之后不再变化 —— SwiftUI 对该字典的子树渲染会稳定下来。
    public private(set) var perRootFinishedSlim: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：已 finished 根的数量。便于 UI 只关心数量变化（例如显示 "3/5 已完成"）时，
    /// 避免依赖整 dict 触发重 diff。
    public private(set) var perRootFinishedCount: Int = 0

    /// v2026.06.22 perf：UI 展示用的「已按 rootPath 字典序预排序」的数组形态。
    ///
    /// 背景（trace 6.67 s，主线程 NSHostingView.layout 778 ms）：
    /// 旧实现在 [statusBar L1549](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1549)
    /// 每帧 body 重 eval 都跑一次 `perRootProgress.values.sorted(by: { $0.rootPath < $1.rootPath })`：
    ///   - sort 几百根 String 字典序比较：~10 ms（_stringCompare 链）
    ///   - sort 闭包带 MainActor 上下文：每对比较都触发 `swift_task_isCurrentExecutor` ~6 ms
    ///   - 总计 statusBar.getter 单帧 44.3 ms，60fps 滚动直接吃光 frame budget。
    ///
    /// 现在：在 syncPerRootPublished 同步点一次性排序好，UI 直接读，零 sort。
    /// Publication is routed through `ScanLiveProgressStore`; keeping this mirror non-published
    /// prevents a progress-only frame from invalidating every coordinator observer.
    public private(set) var perRootProgressSorted: [PerRootProgress] = []
    private var perRootTreeRowsBySort: [TreeSortKey: [TreeRow]] = [:]

    /// v1.3.zz 性能修复用：staging 累计区，每 .node 事件直接累计这里，避开 @Published 触发 SwiftUI invalidation。
    /// publishSnapshot 节流点会把它同步到 perRootProgress（0.4s 一次）。
    private var perRootStaging: [String: PerRootProgress] = [:]

    /// v2026.07.19 performance-regression closure: developer discovery can enqueue another
    /// throttled progress publication while the previous off-main projection is still sorting.
    /// One MainActor-owned drain is the only worker producer; later callers replace this pending
    /// value and return instead of starting independent CAS retry loops.
    private struct LivePerRootProjectionRequest {
        let staging: [String: PerRootProgress]
        let sourceRevision: UInt64
        let scanGeneration: UUID
        let tombstones: PrunedPathMatcher
        let beforeCommitForTesting: (@MainActor () -> Void)?
        let preparationDelayNanosecondsForTesting: UInt64
    }

    private var pendingLivePerRootProjection: LivePerRootProjectionRequest?
    private var livePerRootProjectionOwnerIsRunning = false
    private var livePerRootProjectionDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var livePerRootProjectionActiveWorkerCount = 0
    private var livePerRootProjectionMaxActiveWorkerCount = 0
    private var livePerRootProjectionBuildCount: UInt64 = 0
    private var livePerRootProjectionCommitCount: UInt64 = 0
    private var livePerRootProjectionStaleDropCount: UInt64 = 0
    private var livePerRootProjectionCoalescedRequestCount: UInt64 = 0

    /// v1.5 P1-B：把 staging 字典拆分同步到 active / finishedSlim / finishedCount。
    /// - 仅当 active / finishedSlim 真的变化时才 assign，避免无谓 willChange。
    /// - 删除成功后的乐观 prune 可能让 finished root 的 bytes/fileCount 变小，甚至移除整根；
    ///   因此 finishedSlim 不能再假设 key set 单调增。
    private func syncPerRootPublished(
        from staging: [String: PerRootProgress],
        commitEvidence: Bool = true
    ) {
        // per-root progress 与 ScanSnapshot 都是 UI 发布边界。先提交同批完整性证据，
        // 避免 progress 已显示“该根完成”而 banner/删除闸门仍停在上一批。
        if commitEvidence {
            commitIncompleteEvidenceProjectionsIfNeeded()
        }
        let prepared = Self.buildLivePerRootProjection(
            staging: staging,
            tombstones: deletedPathTombstones.matcher,
            previousActive: perRootProgressActive,
            previousFinished: perRootFinishedSlim,
            previousFinishedCount: perRootFinishedCount,
            previousSorted: perRootProgressSorted
        )
        applyPreparedPerRootProjection(prepared)
    }

    /// v2026.07.19 developer-scan performance regression fix:
    /// keep the known-good `70fce59e` publication ownership for discovery progress.
    ///
    /// Discovery grows `perRootStaging` on MainActor every 20 hits. Passing that Dictionary to an
    /// async presentation worker retains its COW storage across `await`; the next hit batch then
    /// clones the entire growing Dictionary on MainActor. The 0.4-second throttle already bounds
    /// publication frequency, so one synchronous root ordering at that boundary is cheaper and,
    /// critically, does not retain the staging storage into the next mutation window.
    private func publishDeveloperDiscoveryProgress() {
        syncPerRootPublished(from: perRootStaging)
    }

    /// Live progress projection used by the 0.4 s producer throttle.
    ///
    /// `70fce59e` performed one root-path ordering per publication. A later off-main refactor made
    /// every overlapping caller own a `while revision changed -> rebuild` loop and also generated
    /// every Tree sort. Developer discovery mutates staging every 20 hits, so those callers could
    /// invalidate one another and amplify into quadratic rebuild work. The single drain below
    /// restores the baseline work shape while keeping that one ordering off MainActor:
    /// - at most one `PerRootPresentationWorker` exists at a time;
    /// - a later caller replaces `pendingLivePerRootProjection` (latest snapshot wins);
    /// - a stale result is dropped, never retried unless a real later request is already pending;
    /// - Tree rows/sorts remain a terminal projection, when the Tree can actually be disclosed.
    private func syncPerRootPublishedOffMain(
        from staging: [String: PerRootProgress],
        commitEvidence: Bool = true,
        beforeCommitForTesting: (@MainActor () -> Void)? = nil,
        preparationDelayNanosecondsForTesting: UInt64 = 0,
        waitForDrain: Bool = true
    ) async {
        if commitEvidence {
            commitIncompleteEvidenceProjectionsIfNeeded()
        }
        let request = LivePerRootProjectionRequest(
            staging: staging,
            sourceRevision: pruneSourceRevision,
            scanGeneration: scanGeneration,
            tombstones: deletedPathTombstones.matcher,
            beforeCommitForTesting: beforeCommitForTesting,
            preparationDelayNanosecondsForTesting: preparationDelayNanosecondsForTesting
        )
        if livePerRootProjectionOwnerIsRunning {
            livePerRootProjectionCoalescedRequestCount &+= 1
        }
        pendingLivePerRootProjection = request
        if livePerRootProjectionOwnerIsRunning {
            guard waitForDrain else { return }
            await withCheckedContinuation { continuation in
                livePerRootProjectionDrainWaiters.append(continuation)
            }
            return
        }

        let drainStartedAt = DispatchTime.now().uptimeNanoseconds
        let initialBuildCount = livePerRootProjectionBuildCount
        let initialCommitCount = livePerRootProjectionCommitCount
        let initialStaleDropCount = livePerRootProjectionStaleDropCount
        let initialCoalescedRequestCount = livePerRootProjectionCoalescedRequestCount
        var latestRootCount = request.staging.count
        var latestGeneration = request.scanGeneration
        livePerRootProjectionOwnerIsRunning = true
        defer {
            livePerRootProjectionOwnerIsRunning = false
            let drainWaiters = livePerRootProjectionDrainWaiters
            livePerRootProjectionDrainWaiters.removeAll(keepingCapacity: false)
            for waiter in drainWaiters { waiter.resume() }
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - drainStartedAt
            let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000
            let builds = livePerRootProjectionBuildCount - initialBuildCount
            let commits = livePerRootProjectionCommitCount - initialCommitCount
            let staleDrops = livePerRootProjectionStaleDropCount - initialStaleDropCount
            let coalesced = livePerRootProjectionCoalescedRequestCount
                - initialCoalescedRequestCount
            if Self.shouldEmitLivePerRootProjectionDrainLog(
                elapsedMilliseconds: elapsedMilliseconds,
                coalescedRequests: coalesced,
                staleDrops: staleDrops
            ) {
                // One drain summary replaces per-request logging. It exposes amplification without
                // putting formatting or file-sink work back on the discovery callback hot path.
                GSYLog.notice(
                    .flow,
                    "scan.live_per_root_projection.drain "
                        + "elapsed_ms=\(String(format: "%.2f", elapsedMilliseconds)) "
                        + "builds=\(builds) commits=\(commits) coalesced=\(coalesced) "
                        + "stale_drops=\(staleDrops) latest_root_count=\(latestRootCount) "
                        + "generation=\(latestGeneration.uuidString)"
                )
            }
        }

        while let request = pendingLivePerRootProjection {
            pendingLivePerRootProjection = nil
            latestRootCount = request.staging.count
            latestGeneration = request.scanGeneration
            let worker = PerRootPresentationWorker(
                retainedState: PerRootRetainedState(
                    staging: request.staging,
                    previousActive: perRootProgressActive,
                    previousFinished: perRootFinishedSlim,
                    previousFinishedCount: perRootFinishedCount,
                    previousSorted: perRootProgressSorted
                ),
                tombstones: request.tombstones,
                preparationDelayNanosecondsForTesting:
                    request.preparationDelayNanosecondsForTesting
            )
            livePerRootProjectionActiveWorkerCount &+= 1
            livePerRootProjectionMaxActiveWorkerCount = max(
                livePerRootProjectionMaxActiveWorkerCount,
                livePerRootProjectionActiveWorkerCount
            )
            livePerRootProjectionBuildCount &+= 1
            var prepared = await worker.prepare()
            livePerRootProjectionActiveWorkerCount -= 1
            if let hook = request.beforeCommitForTesting {
                hook()
            }
            guard request.scanGeneration == scanGeneration,
                  request.sourceRevision == pruneSourceRevision else {
                prepared = nil
                _ = await worker.retire()
                livePerRootProjectionStaleDropCount &+= 1
                continue
            }
            guard let prepared else {
                _ = await worker.retire()
                continue
            }
            lastPerRootPreparationRanOnMainThread = prepared.ranOnMainThread
            applyPreparedPerRootProjection(prepared)
            livePerRootProjectionCommitCount &+= 1
            Task { @MainActor in
                await Task.yield()
                _ = await worker.retire()
            }
        }
    }

    nonisolated private static func shouldEmitLivePerRootProjectionDrainLog(
        elapsedMilliseconds: Double,
        coalescedRequests: UInt64,
        staleDrops: UInt64
    ) -> Bool {
        coalescedRequests > 0 || staleDrops > 0 || elapsedMilliseconds >= 100
    }

    nonisolated private static func buildLivePerRootProjection(
        staging: [String: PerRootProgress],
        tombstones: PrunedPathMatcher,
        previousActive: [String: PerRootProgress],
        previousFinished: [String: PerRootProgress],
        previousFinishedCount: Int,
        previousSorted: [PerRootProgress]
    ) -> PreparedPerRootProjection {
        var nextActive: [String: PerRootProgress] = [:]
        nextActive.reserveCapacity(staging.count)
        var nextFinishedCount = 0
        var nextFinishedSlim: [String: PerRootProgress] = [:]
        for (k, v) in staging {
            if tombstones.contains(k) { continue }
            if v.isFinished {
                nextFinishedCount += 1
                nextFinishedSlim[k] = v
            } else {
                nextActive[k] = v
            }
        }
        // v2026.06.22 perf：同步维护 sorted 数组（UI 直接读，零 sort）。
        // staging 是合并后的最终态；这里就一次性按 rootPath 字典序排好。
        // 仅当真的变化才 assign，避免无谓 willChange / SwiftUI 重 diff。
        // `active` / `finished` and the sorted UI projection must describe the same tombstone-
        // filtered state. Sorting `staging.values` directly could otherwise resurrect a deleted
        // root only in the status list after the dictionaries had already removed it.
        var nextSorted = Array(nextActive.values)
        nextSorted.append(contentsOf: nextFinishedSlim.values)
        nextSorted.sort(by: { $0.rootPath < $1.rootPath })
        return PreparedPerRootProjection(
            active: nextActive,
            finished: nextFinishedSlim,
            finishedCount: nextFinishedCount,
            sorted: nextSorted,
            treeRowsBySort: [:],
            replacesTreeRows: false,
            activeChanged: previousActive != nextActive,
            finishedChanged: previousFinished != nextFinishedSlim,
            finishedCountChanged: previousFinishedCount != nextFinishedCount,
            sortedChanged: previousSorted != nextSorted,
            ranOnMainThread: Thread.isMainThread
        )
    }

    /// Complete per-root Tree projection. This is intentionally terminal/prune-only: live
    /// progress needs the baseline root-path ordering above, while Tree disclosure begins only
    /// after the scan has reached an authoritative terminal snapshot.
    nonisolated private static func buildPerRootProjection(
        staging: [String: PerRootProgress],
        tombstones: PrunedPathMatcher,
        previousActive: [String: PerRootProgress],
        previousFinished: [String: PerRootProgress],
        previousFinishedCount: Int,
        previousSorted: [PerRootProgress],
        evidence: TreeScanEvidenceProjection,
        locale: Locale,
        sessionIsScanning: Bool
    ) -> PreparedPerRootProjection {
        let live = buildLivePerRootProjection(
            staging: staging,
            tombstones: tombstones,
            previousActive: previousActive,
            previousFinished: previousFinished,
            previousFinishedCount: previousFinishedCount,
            previousSorted: previousSorted
        )
        let semanticTreeRows = live.sorted.map { progress -> TreeRow in
            let fallbackCompleteness: TreeRow.SubtreeCompleteness =
                progress.isPartial || (!sessionIsScanning && !progress.isFinished)
                ? .containsIncompleteDescendant
                : .complete
            let state = evidence.projectedState(
                for: progress.rootPath,
                fallbackSubtreeCompleteness: fallbackCompleteness
            )
            return TreeRow(
                path: progress.rootPath,
                title: progress.title,
                bytes: progress.bytes,
                logicalBytes: progress.logicalBytes,
                fileCount: progress.fileCount,
                isDirectory: true,
                hasChildren: progress.fileCount > 0,
                accessState: state.accessState,
                subtreeCompleteness: state.subtreeCompleteness,
                titlePresentation: progress.titlePresentation
            )
        }
        var treeRowsBySort: [TreeSortKey: [TreeRow]] = [:]
        treeRowsBySort.reserveCapacity(TreeSortKey.allCases.count)
        for sortKey in TreeSortKey.allCases {
            treeRowsBySort[sortKey] = semanticTreeRows.sorted {
                sortTreeRow($0, before: $1, by: sortKey, locale: locale)
            }
        }
        return PreparedPerRootProjection(
            active: live.active,
            finished: live.finished,
            finishedCount: live.finishedCount,
            sorted: live.sorted,
            treeRowsBySort: treeRowsBySort,
            replacesTreeRows: true,
            activeChanged: live.activeChanged,
            finishedChanged: live.finishedChanged,
            finishedCountChanged: live.finishedCountChanged,
            sortedChanged: live.sortedChanged,
            ranOnMainThread: live.ranOnMainThread
        )
    }

    private func applyPreparedPerRootProjection(_ prepared: PreparedPerRootProjection) {
        if prepared.activeChanged {
            perRootProgressActive = prepared.active
        }
        if prepared.finishedChanged {
            perRootFinishedSlim = prepared.finished
        }
        if prepared.finishedCountChanged {
            perRootFinishedCount = prepared.finishedCount
        }
        if prepared.sortedChanged {
            perRootProgressSorted = prepared.sorted
        }
        if prepared.replacesTreeRows {
            perRootTreeRowsBySort = prepared.treeRowsBySort
        }
        if prepared.sortedChanged {
            liveProgress.updatePerRootRows(perRootProgressSorted)
        }
    }

    /// 完整重置 per-root mirrors 与窄进度发布（用于 cancel / 重新预填）。
    private func resetPerRootPublished() {
        if !perRootProgressActive.isEmpty { perRootProgressActive = [:] }
        if !perRootFinishedSlim.isEmpty { perRootFinishedSlim = [:] }
        if perRootFinishedCount != 0 { perRootFinishedCount = 0 }
        if !perRootProgressSorted.isEmpty { perRootProgressSorted = [] }
        if !perRootTreeRowsBySort.isEmpty { perRootTreeRowsBySort = [:] }
        liveProgress.updatePerRootRows([])
        notePruneSourceMutation()
    }

    /// 单根的实时进度快照。
    /// - title：仅为旧调用方/日志保留的 fallback；UI 必须通过 titlePresentation 投影；
    /// - bytes / fileCount：该根累计已扫到的字节与文件数；
    /// - isFinished：该根的 BulkScanner 是否已 yield 过 .finished。多根全部 isFinished=true 时
    ///   stream 关闭，runMultiRootScan 自身把 isScanning 翻 false。
    public struct PerRootProgress: Sendable, Equatable {
        public let rootPath: String
        /// 兼容旧调用方/日志的启动语言快照。SwiftUI 不得直接展示这个字段；
        /// 应调用 `displayTitle(locale:)`，由语义 key 在当前界面 locale 下投影。
        public let title: String
        public let titleLocalizationKey: String?
        public let titleSuffix: String?
        public let titlePresentation: LocalizedTextDescriptor
        public var bytes: Int64
        public var logicalBytes: Int64
        public var fileCount: Int
        public var isFinished: Bool
        /// 根扫描已终止但未完整遍历（例如 per-root timeout / no-progress watchdog）。
        /// 这种终态可以展示已观察结果，但 UI 不能画成绿色完成勾。
        public var isPartial: Bool
        public init(rootPath: String, title: String,
                    titleLocalizationKey: String? = nil,
                    titleSuffix: String? = nil,
                    titlePresentation: LocalizedTextDescriptor? = nil,
                    bytes: Int64 = 0, logicalBytes: Int64? = nil, fileCount: Int = 0,
                    isFinished: Bool = false, isPartial: Bool = false) {
            self.rootPath = rootPath
            self.title = title
            self.titleLocalizationKey = titleLocalizationKey
            self.titleSuffix = titleSuffix
            if let titlePresentation {
                self.titlePresentation = titlePresentation
            } else if let titleLocalizationKey {
                self.titlePresentation = LocalizedTextDescriptor
                    .catalog(titleLocalizationKey)
                    .appendingVerbatim(titleSuffix ?? "")
            } else {
                self.titlePresentation = .verbatim(title)
            }
            self.bytes = bytes
            self.logicalBytes = logicalBytes ?? bytes
            self.fileCount = fileCount
            self.isFinished = isFinished
            self.isPartial = isPartial
        }

        public func displayTitle(locale: Locale) -> String {
            titlePresentation.localized(locale: locale)
        }
    }

    /// v1.3：多根并行扫描的特殊 categoryID 哨兵，与 ScanCategory.id 解耦。
    /// runScan 的 activeCategoryID 校验沿用此值；UI 不应依赖它做业务判断（用 perRootProgress 判更可靠）。
    public static let multiRootCategoryID: String = "recommended.multi"

    /// Smart Care “系统与日志”专用多根扫描。它刻意不包含应用缓存与开发缓存，
    /// 防止普通模式三个范围在真实文件系统根上互相重叠。
    public static let smartCareCoreCategoryID: String = "smart_care.core.multi"

    /// v1.4：开发者构建产物多根并行扫描的 categoryID 哨兵。与 multiRootCategoryID 区分，
    /// 让 UI 可以渲染不同标题（"开发者构建产物" vs "全部推荐扫描"），但底层 runMultiRootScan 共用。
    public static let developerCategoryID: String = "developer.multi"

    /// 常见应用缓存规则扫描的 categoryID。
    ///
    /// 该入口只消费 `vendors.yaml` 中 `category=common_app_cache` 的显式规则，结果是
    /// "命中路径列表"，不是普通文件系统目录树，因此不走 BulkScanner 流式 ingest。
    public static let commonAppCacheCategoryID: String = "common_app_cache"

    /// v1.5：多根扫描时 [currentRootPath](#) 设为这两个伪路径之一，给 UI 占位
    /// （树形/finishedEmpty 等场景需要一个非 nil 值）。这两个值不是真实目录，
    /// 也不会有"以它们为父"的真实文件系统子项；树形视图遇到它们时要走「合成多根顶层」分支
    /// （见 [directChildren(of:sortedBy:)](#)），把 perRootProgress 的真实根升级成顶层 TreeRow。
    ///
    /// v2026.06.21：原值为中文字面（"(多目录)" / "(开发者构建产物)" / "(开发者旧版本)"），
    /// 由于 [placeholder(for:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1572)
    /// 的 `.finishedEmpty(rootPath)` 分支会直接 `Text(rootPath)` 给英文用户看，
    /// 那相当于英文 UI 露出三个中文 token。统一改成纯英文 sentinel ID（带双下划线前后缀，
    /// 不会与任何真实文件路径冲突），UI 侧检测到 sentinel 后走 `path.sentinel.*`
    /// xcstrings key 走本地化显示。
    public static let multiRootSentinelPath: String = "__sentinel_multi_root__"
    public static let smartCareCoreSentinelPath: String = "__sentinel_smart_care_core__"
    public static let developerSentinelPath: String = "__sentinel_dev_artifact__"
    public static let versionedRootSentinelPath: String = "__sentinel_versioned_root__"
    public static let commonAppCacheSentinelPath: String = "__sentinel_common_app_cache__"
    public static let multiRootSentinelPaths: Set<String> = [
        multiRootSentinelPath,
        smartCareCoreSentinelPath,
        developerSentinelPath,
        versionedRootSentinelPath,
        commonAppCacheSentinelPath
    ]

    /// 便利属性 —— 转发自 `snapshot.isFinished`，表示事件流已进入终态；成功与否再看
    /// `snapshot.isComplete`。这样部分结果可以展示并按精确证据预检，不会伪装成成功。
    public var isFinished: Bool { snapshot.isFinished }

    /// The single authority for actions derived from the current scan result.
    ///
    /// v2026.07.19 settlement regression fix: while a cancelled producer is releasing ownership,
    /// the last stable snapshot deliberately remains visible. That frame is disclosure-only: its
    /// session/revision must never be rebound to the incoming intent for deletion or stash work.
    /// Every result action must use this contract instead of inferring readiness from
    /// `isScanning == false` or `snapshot.isFinished` independently.
    public var canUseCurrentScanResultsForActions: Bool {
        guard case .idle = scanPhase else { return false }
        return !isScanning && snapshot.isFinished
    }

    /// Whether this coordinator still owns an admitted or pending primary scan transaction.
    ///
    /// v2026.07.19 settlement regression fix: `isScanning` is intentionally false while a
    /// replacement waits for its predecessor to return. Mode/category ownership must still cancel
    /// that pending intent; otherwise a scan starts after the user has already left its surface.
    /// The internal checks are fail-safe consistency guards for any future phase-transition bug.
    public var hasActivePrimaryScanOwnership: Bool {
        switch scanPhase {
        case .settling, .scanning:
            return true
        case .idle:
            return isScanning
                || scanTask != nil
                || pendingPrimaryScanIntent != nil
                || activePrimaryReservation != nil
        }
    }

    private let engine = SafetyEngine()
    /// Stable namespace for the process-local Tree verdict cache. Different coordinator instances
    /// may freeze different HOME/vendor inputs, so path alone can never be the cache identity.
    let treeDeletionEvaluationCacheNamespace = UUID()
    private let vendors: [VendorRule]
    private let home: String
    private let whitelistStore: WhitelistStore
    /// 预构建的 VendorTrie —— 性能关键：
    /// `publishSnapshot` 每帧（≥150ms）会对 N 个 bucket 调 `engine.evaluate`。
    /// 朴素 `evaluate(path:vendors:home:)` 内部**每次都重建 trie**（含 ~42 条 path-rule
    /// 的 `URL.standardizedFileURL` —— 系统调用级开销），整盘扫 buckets ~100+ 时
    /// 实测每秒重建上百次 trie，把主线程 publishSnapshot 拖到 50–200ms 一帧。
    /// unbounded stream 不会给 producer 背压，但 UI-owned consumer 与终态会在积压事件
    /// 后面排队，表现为 worker 已扫完、界面仍长时间“扫描中”。
    /// 这里一次构建、扫描期间复用，evaluate 走 trie 版 O(路径深度) 路径。
    /// vendors 在 init 时就锁定，扫描期不会动；用 lazy + `let` 等价的 stored property 即可。
    private let trie: VendorTrieNode
    /// Primary orchestration/presentation owner. It is deliberately never used as a filesystem
    /// lease: scanner producers register their exact termination handles below.
    private var scanTask: Task<Void, Never>?
    private struct PendingPrimaryScanIntent {
        let state: ScanSettlementState
        let startedUptimeNanoseconds: UInt64
        var requestToken: PrimaryScanAdmissionRegistry.RequestToken?
    }
    private var pendingPrimaryScanIntent: PendingPrimaryScanIntent?
    private var activePrimaryReservation: PrimaryScanAdmissionRegistry.ReservationToken?
    /// Main primary-scan admission authority. Professional and Smart Care share one registry but
    /// retain distinct client identities, allowing same-client replacement to freeze its prior
    /// presentation while a cross-mode replacement clears the hidden predecessor.
    public let primaryScanAdmissionRegistry: PrimaryScanAdmissionRegistry
    public let primaryScanAdmissionClientID: PrimaryScanAdmissionRegistry.ClientID

    /// 每次扫描会话的不可复用代际 token。
    ///
    /// categoryID 只能区分“扫什么”，不能区分“同一分类的前后两次扫描”。旧任务的
    /// cooperative cancellation 可能晚于新任务启动；若只比较 categoryID，旧任务仍能
    /// 发布收尾结果。所有异步回写必须同时持有 categoryID 与本 token。
    private var scanGeneration: UUID

    /// Session identity of the snapshot currently disclosed to consumers. Producer generation
    /// rotates as soon as a replacement intent is admitted so stale writers are invalidated, but
    /// this identity advances only when that replacement actually starts and replaces the frame.
    /// Keeping the two clocks distinct prevents a retained predecessor snapshot from ever being
    /// described as belonging to the incoming intent.
    private var publishedScanSessionID: UUID

    /// 当前扫描会话的稳定身份。Professional 删除确认会冻结它，并在真正提交前复核，
    /// 避免同一 category 取消后重扫时把上一轮 rows 提交到下一轮状态。
    public var currentScanSessionID: UUID { publishedScanSessionID }
    /// Main presentation workers freeze this revision together with the scan session. It exposes
    /// no mutable state; callers use it only as a CAS token so a stale receipt projection cannot
    /// overwrite a later scan/prune publication.
    var deletionPresentationSourceRevision: UInt64 { pruneSourceRevision }

    /// 同步 detector 的依赖边界。internal 可替换性用于
    /// 构造“旧 detector 不协作取消且晚返回”的确定性并发测试，验证 generation 本身，
    /// 而不是依赖文件系统规模或时序碰运气。nil 时才走构造期冻结的生产 execution mode；
    /// shipped App 显式选择 isolated，package tests 默认 in-process。
    typealias CommonAppCacheDetector = @Sendable (
        _ vendors: [VendorRule],
        _ home: URL,
        _ options: CommonAppCacheScanner.Options
    ) -> CommonAppCacheScanner.ScanResult
    var commonAppCacheDetector: CommonAppCacheDetector?
    typealias StandardInstalledAppCacheRuleDiscovery = @Sendable () async ->
        StandardInstalledAppCacheRuleDiscoveryResult
    /// Test seam for the independently fallible `/Applications` metadata producer. A nil value is
    /// the shipped live implementation; the result still travels through the production terminal
    /// evidence and generation checks.
    var standardInstalledAppCacheRuleDiscovery: StandardInstalledAppCacheRuleDiscovery?
    private let commonAppCacheExecution: CommonAppCacheExecutionMode

    /// 树形后台展开的代际 token。每次新扫描 / 取消都会刷新，防止旧展开任务写回新扫描缓存。
    private var treeFetchGeneration = UUID()

    /// v1.3：当前"活跃"的 categoryID。
    /// 防 [坑 1]：旧 scan 被 cancel 后，AsyncStream 缓冲里残留的 .node 事件仍可能被旧 for-await
    /// 循环消费一两轮（cancel 的传播是协作式，不是抢占式）。如果不带本次 token，
    /// 旧 ingest 会把数据写到刚被新 scan 重置过的 buckets/dirIndex 上，污染新 categoryID 的 snapshot。
    /// runScan 的每次事件处理之前先校验 `myCategoryID == activeCategoryID`，不一致直接 break。
    /// v1.3 P0-D：暴露 read-only 给 UI 用于判断 banner 上下文（仍是内部更新）。
    public private(set) var activeCategoryID: String?

    private func ownsScan(categoryID: String, generation: UUID) -> Bool {
        activeCategoryID == categoryID && scanGeneration == generation
    }

    /// 一级子目录 -> 累计统计；用 path 作 key 保证稳定。
    private struct Bucket: Sendable {
        var url: URL
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var isDirectory: Bool
        var hasChildren: Bool = false
        /// v1.5.4：bucket（一级聚合行 = 一级子目录或单个顶层文件）自身 inode 的 mtime。
        ///
        /// 仅在 isTopLevelBucket=true 时写入——即 BulkScanner 真的 yield 出该 bucket 自己的
        /// node entry（首次 ingest 一定会触发），所以扫完一定有值，无需额外探测。
        /// 为什么不维护"max(子孙 mtime)"：见 [RowItem.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L33) 文档——
        /// Finder 风格目录 mtime = 目录 inode 自身 mtime（在该目录里增删文件即由内核更新）。
        var modificationDate: Date? = nil

        /// Step 3 P0-3 / 2026-06：bucket 节点的 SafetyEngine.evaluate 结果缓存。
        ///
        /// 为什么这里能 cache：bucket 的 key 是 `path: String`，永久不变；`engine` 自身、
        /// vendor `trie` 与 `home` 在 ScanCoordinator 的生命周期里都是 `let` immutable —— 
        /// 所以同一 path 的 evaluate 结果**永远相同**。
        ///
        /// 旧 publishSnapshot 每帧（流式扫描 0.4s/帧）都对全部 N 个 bucket 调一次
        /// evaluate(trie:)。一次扫描扫到 K=数百~数千 bucket，× 数十帧，多出几千~几十万次
        /// 主线程纯函数调用 —— 对 Tree View 就是直接的卡顿源。
        ///
        /// 缓存策略：首次 publishSnapshot 看到该 bucket 时算一次写回；之后命中直接读。
        /// `nil` = 还没算过；非 nil = 已经算过且永远有效（因 cache 失效条件不存在 ——
        /// startScan/rescan/cancel 会整个 buckets.removeAll()，cache 字段自然消失）。
        var cachedVerdict: SafetyVerdict? = nil
        var cachedRejection: SafetyRejection? = nil
        var cachedVendor: VendorRule? = nil

        /// v1.3.z 性能优化：把 ingest hot path 的 read-modify-write 收敛进 Bucket 自身。
        /// 配合 `buckets[k, default: ...].applyIngest(...)` 让 hit 路径只走一次哈希查找，
        /// 且 hit 时不构造 default 值（autoclosure 不求值）。
        mutating func applyIngest(
            isFileNode: Bool,
            isTopLevelBucket: Bool,
            isDirEffective: Bool,
            bytes nodeBytes: Int64,
            logicalBytes nodeLogical: Int64,
            nodeMTime: Date? = nil
        ) {
            if isFileNode {
                bytes += nodeBytes
                logicalBytes += nodeLogical
                fileCount += 1
            }
            if !isTopLevelBucket {
                hasChildren = true
            }
            // 顶层 bucket 自身可能是文件（极少见），保留 isDirectory 信息
            if isTopLevelBucket {
                isDirectory = isDirEffective
                // The regular-file contribution was already applied above. Special
                // entries retain their identity while contributing zero bytes/files.
                if !isDirEffective {
                    fileCount = isFileNode ? 1 : 0
                }
                // 仅在确实拿到 mtime 时覆盖；保留已有值避免被空帧清零
                if let m = nodeMTime {
                    modificationDate = m
                }
            }
        }
    }

    /// A terminal projection is immutable producer output. Keeping the public display root next
    /// to it lets the background preparation worker perform namespace projection without reading
    /// mutable coordinator state.
    private struct TerminalProjectionEnvelope: Sendable {
        let projection: ScanProjectionResult
        let rootPath: String
    }

    /// The caller's local projection array can be the final owner when a scan is cancelled after
    /// producer settlement or when terminal CAS rejects the DTO. Handing that storage to this
    /// actor before clearing the MainActor local closes the same lifecycle boundary as the main
    /// terminal worker, including failure paths.
    private actor TerminalProjectionRetirementWorker {
        private var projections: [TerminalProjectionEnvelope]?

        init(projections: [TerminalProjectionEnvelope]) {
            self.projections = projections
        }

        func snapshot() -> [TerminalProjectionEnvelope] {
            projections ?? []
        }

        func retire() {
            projections = nil
        }
    }

    /// Keeps wide producer output off MainActor across the exact filesystem-lease release point.
    /// A presentation task may borrow the COW payload afterward, but cancellation cannot make its
    /// MainActor stack the final owner and destruct a large result while the UI is trying to draw.
    private actor ProducerPayloadOwner<Payload: Sendable> {
        private var payload: Payload?

        init(_ payload: Payload) {
            self.payload = payload
        }

        func snapshot() -> Payload? { payload }

        func retire() { payload = nil }
    }

    private struct DeveloperDiscoveryProducerOutput: Sendable {
        let knownRoots: [ScanCategory]
        let discovery: DevArtifactScanner.DiscoverResult
        let elapsed: TimeInterval
    }

    private struct DeveloperDiscoveryPresentation: Sendable {
        let staging: [String: PerRootProgress]
        let roots: [URL]
        let didTruncate: Bool
        let didTimeout: Bool
        let incompleteIssues: [ScanIncompleteIssue]
        let producerElapsed: TimeInterval
    }

    /// Consumes the discovery payload on the generic executor. The previous implementation ran
    /// hit filtering, duplicate suppression and thousands of PerRootProgress constructions on
    /// MainActor immediately before the multi-root scan, recreating the visible pause reported by
    /// the user. The payload owner is retired here so its final raw hit storage is never destroyed
    /// by the UI executor.
    nonisolated private static func prepareDeveloperDiscoveryPresentation(
        owner: ProducerPayloadOwner<DeveloperDiscoveryProducerOutput>,
        whitelist: Set<String>,
        baseStaging: [String: PerRootProgress],
        tombstones: PrunedPathMatcher,
        home: String
    ) async -> DeveloperDiscoveryPresentation? {
        guard let output = await owner.snapshot() else { return nil }
        let result = output.discovery
        var finalStaging = baseStaging
        var finalRoots: [URL] = []
        finalRoots.reserveCapacity(result.hits.count + output.knownRoots.count)
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(result.hits.count + output.knownRoots.count)

        for hit in result.hits {
            guard !Task.isCancelled else {
                await owner.retire()
                return nil
            }
            let path = hit.url.path
            if isWhitelisted(path, in: whitelist) || tombstones.contains(path) { continue }
            guard seenPaths.insert(path).inserted else { continue }
            finalRoots.append(hit.url)
            if finalStaging[path] == nil {
                let shortPath = path == home
                    ? "~"
                    : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
                let suffix = " · \(shortPath)"
                let titleBase: LocalizedTextDescriptor = hit.displayName.hasPrefix("rule.")
                    ? .catalog(hit.displayName)
                    : .verbatim(hit.displayName)
                finalStaging[path] = PerRootProgress(
                    rootPath: path,
                    title: hit.displayName + suffix,
                    titleLocalizationKey: hit.displayName,
                    titleSuffix: suffix,
                    titlePresentation: titleBase.appendingVerbatim(suffix)
                )
            }
        }
        for category in output.knownRoots {
            guard !Task.isCancelled else {
                await owner.retire()
                return nil
            }
            let path = category.rootPath
            if isWhitelisted(path, in: whitelist) || tombstones.contains(path) { continue }
            guard seenPaths.insert(path).inserted else { continue }
            finalRoots.append(category.rootURL)
            if finalStaging[path] == nil {
                let shortPath = path == home
                    ? "~"
                    : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
                let suffix = " · \(shortPath)"
                finalStaging[path] = PerRootProgress(
                    rootPath: path,
                    title: category.title + suffix,
                    titleLocalizationKey: category.titleIsLocalizationKey ? category.title : nil,
                    titleSuffix: suffix,
                    titlePresentation: category.titlePresentation.appendingVerbatim(suffix)
                )
            }
        }
        let presentation = DeveloperDiscoveryPresentation(
            staging: finalStaging,
            roots: finalRoots,
            didTruncate: result.didTruncate,
            didTimeout: result.didTimeout,
            incompleteIssues: result.incompleteIssues,
            producerElapsed: output.elapsed
        )
        await owner.retire()
        return presentation
    }

    private struct VersionedRootsPresentation: Sendable {
        let rootPaths: [String]
        let rows: [RowItem]
        let treeRowsBySort: [TreeSortKey: [TreeRow]]
        let incompleteIssues: [ScanIncompleteIssue]
        let totalBytes: Int64
        let fileCount: Int
        let discoveryIssueCount: Int
        let producerElapsed: TimeInterval
    }

    nonisolated private static func prepareVersionedRootsPresentation(
        owner: ProducerPayloadOwner<VersionedRootsProducerOutput>,
        engine: SafetyEngine,
        trie: VendorTrieNode,
        home: String,
        locale: Locale,
        reconciliationRoots: [String]
    ) async -> VersionedRootsPresentation? {
        guard let output = await owner.snapshot(), !output.wasCancelled else {
            await owner.retire()
            return nil
        }
        var rows: [RowItem] = []
        rows.reserveCapacity(output.entries.count)
        var totalBytes: Int64 = 0
        var fileCount = 0
        var issues = Set(output.discoveryIssues)

        for entry in output.entries {
            guard !Task.isCancelled else {
                await owner.retire()
                return nil
            }
            let hit = entry.hit
            let measurement = entry.measurement
            let (verdict, rejection, vendor) = engine.evaluate(
                path: hit.url.path,
                trie: trie,
                home: home
            )
            issues.formUnion(measurement.incompleteIssues)
            totalBytes &+= measurement.allocatedBytes
            fileCount &+= measurement.fileCount
            let titleSuffix = hit.groupKey.flatMap { $0.isEmpty ? nil : $0 }
                .map { " · \($0) · \(hit.versionName)" }
                ?? " · \(hit.versionName)"
            let scanWasIncomplete = !measurement.deletionDeniedPaths.isEmpty
            rows.append(RowItem(
                id: hit.url.path,
                url: hit.url,
                title: hit.displayName + titleSuffix,
                isDirectory: true,
                bytes: measurement.allocatedBytes,
                logicalBytes: measurement.logicalBytes,
                fileCount: measurement.fileCount,
                verdict: scanWasIncomplete && verdict != .forbid ? .forbid : verdict,
                rejection: scanWasIncomplete && verdict != .forbid ? .accessDenied : rejection,
                vendorName: vendor?.name,
                vendorNote: "retain: \(hit.retainedLatest)",
                runningBundleIDPrefix: vendor?.bundleIDPrefix,
                isActive: false,
                hasChildren: false,
                modificationDate: nil,
                titlePresentation: LocalizedTextDescriptor
                    .catalog(hit.displayName)
                    .appendingVerbatim(titleSuffix),
                vendorNotePresentation: .catalog(
                    "versioned-root.retained_version %@",
                    arguments: [.string(hit.retainedLatest)]
                )
            ))
        }
        rows.sort { $0.bytes > $1.bytes }
        let sortedIssues = issues.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.reason != $1.reason { return $0.reason.rawValue < $1.reason.rawValue }
            return ($0.stage?.rawValue ?? "") < ($1.stage?.rawValue ?? "")
        }
        guard let treeRowsBySort = buildSnapshotTreeRows(
            rows: rows,
            evidence: TreeScanEvidenceProjection(issues: sortedIssues),
            locale: locale,
            forceLeafPresentation: true
        ) else {
            await owner.retire()
            return nil
        }
        let presentation = VersionedRootsPresentation(
            rootPaths: Array(Set(reconciliationRoots + rows.map(\.id))).sorted(),
            rows: rows,
            treeRowsBySort: treeRowsBySort,
            incompleteIssues: sortedIssues,
            totalBytes: totalBytes,
            fileCount: fileCount,
            discoveryIssueCount: output.discoveryIssues.count,
            producerElapsed: output.elapsed
        )
        await owner.retire()
        return presentation
    }

    private struct CommonAppCacheProducerOutput: Sendable {
        let standardDiscovery: StandardInstalledAppCacheRuleDiscoveryResult
        let scanResult: CommonAppCacheScanner.ScanResult
        let modificationDates: [String: Date]
        let latestProgress: CommonAppCacheScanner.Progress?
        let elapsed: TimeInterval
    }

    private struct CommonAppCachePresentation: Sendable {
        let rootPaths: [String]
        let rows: [RowItem]
        let treeRowsBySort: [TreeSortKey: [TreeRow]]
        let issues: [ScanIncompleteIssue]
        let terminalProgress: CommonAppCacheScanner.Progress
        let totalBytes: Int64
        let fileCount: Int
        let scanIssueCount: Int
        let discoveryIssueCount: Int
        let isComplete: Bool
        let producerElapsed: TimeInterval
    }

    nonisolated private static func prepareCommonAppCachePresentation(
        owner: ProducerPayloadOwner<CommonAppCacheProducerOutput>,
        whitelist: Set<String>,
        engine: SafetyEngine,
        trie: VendorTrieNode,
        home: String,
        locale: Locale,
        reconciliationRoots: [String]
    ) async -> CommonAppCachePresentation? {
        guard let output = await owner.snapshot() else { return nil }
        let scanResult = output.scanResult
        let incompletePaths = scanResult.deletionProtectedPaths
        var rows: [RowItem] = []
        rows.reserveCapacity(scanResult.hits.count)
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(scanResult.hits.count)

        for hit in scanResult.hits {
            guard !Task.isCancelled else {
                await owner.retire()
                return nil
            }
            let path = hit.url.standardizedFileURL.path
            guard !isWhitelisted(path, in: whitelist),
                  seenPaths.insert(path).inserted else { continue }
            let (verdict, rejection, vendor) = engine.evaluate(
                path: hit.url.path,
                trie: trie,
                home: home
            )
            let isIncomplete = incompletePaths.contains { pathsOverlap(path, $0) }
            let isStandardRule = hit.source == "standard-macos-cache"
            let titlePresentation: LocalizedTextDescriptor = isStandardRule
                ? .catalog(
                    "common_app_cache.standard.title %@",
                    arguments: [.string(hit.ruleName)]
                )
                : .verbatim(hit.ruleName)
            let notePresentation: LocalizedTextDescriptor? = hit.reason.map {
                isStandardRule ? .catalog($0) : .verbatim($0)
            } ?? hit.source.map(LocalizedTextDescriptor.verbatim)
            rows.append(RowItem(
                id: hit.url.path,
                url: hit.url,
                title: hit.ruleName,
                isDirectory: hit.isDirectory,
                bytes: hit.sizeBytes,
                logicalBytes: hit.logicalSizeBytes,
                fileCount: hit.entryCount,
                verdict: isIncomplete ? .forbid : verdict,
                rejection: isIncomplete ? .accessDenied : rejection,
                vendorName: vendor?.name ?? hit.ruleName,
                vendorNote: hit.reason ?? hit.source,
                runningBundleIDPrefix: hit.bundleIDPrefix,
                isActive: false,
                modificationDate: output.modificationDates[path],
                titlePresentation: titlePresentation,
                vendorNamePresentation: vendor.map {
                    LocalizedTextDescriptor.verbatim($0.name)
                } ?? titlePresentation,
                vendorNotePresentation: notePresentation
            ))
        }
        rows.sort {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
        let latestProgress = output.latestProgress
        let checkpoint = latestProgress?.checkpoint
            ?? CommonAppCacheScanner.Checkpoint(
                hits: scanResult.hits,
                incompletePaths: scanResult.incompletePaths,
                uniqueTotalBytes: scanResult.uniqueTotalBytes,
                uniqueLogicalBytes: scanResult.uniqueLogicalBytes,
                uniqueEntryCount: scanResult.uniqueEntryCount,
                completedGroupCount: latestProgress?.completedGroups ?? 0
            )
        let discoveryIssues = output.standardDiscovery.issues.map(\.scanIncompleteIssue)
        var evidence = ScanIncompleteEvidenceIndex(
            issues: scanResult.incompletePaths.map(commonAppCacheIncompleteIssue)
        )
        for issue in discoveryIssues { evidence.record(issue) }
        let issues = evidence.orderedIssues
        let isComplete = scanResult.isComplete && discoveryIssues.isEmpty
        let terminalProgress = CommonAppCacheScanner.Progress(
            phase: .terminal,
            completedGroups: latestProgress?.completedGroups ?? 0,
            totalGroups: latestProgress?.totalGroups ?? 0,
            terminalOutcome: isComplete ? .complete : .partial,
            checkpoint: checkpoint,
            pendingPaths: latestProgress?.pendingPaths ?? []
        )
        guard let treeRowsBySort = buildSnapshotTreeRows(
            rows: rows,
            evidence: TreeScanEvidenceProjection(issues: issues),
            locale: locale
        ) else {
            await owner.retire()
            return nil
        }
        let presentation = CommonAppCachePresentation(
            rootPaths: Array(Set(reconciliationRoots + rows.map(\.id))).sorted(),
            rows: rows,
            treeRowsBySort: treeRowsBySort,
            issues: issues,
            terminalProgress: terminalProgress,
            totalBytes: scanResult.uniqueTotalBytes,
            fileCount: scanResult.uniqueEntryCount,
            scanIssueCount: scanResult.incompletePaths.count,
            discoveryIssueCount: output.standardDiscovery.issues.count,
            isComplete: isComplete,
            producerElapsed: output.elapsed
        )
        await owner.retire()
        return presentation
    }

    private struct PreparedTerminalPresentation: Sendable {
        let buckets: [String: Bucket]
        let rows: [RowItem]
        /// Every root Tree sort is prepared beside the terminal flat rows on the generic
        /// executor. `TreeBrowserView.body` must never rematerialize and sort a wide snapshot.
        let treeRowsBySort: [TreeSortKey: [TreeRow]]
        let rowRollup: ScanSnapshotRowRollup
        let verdictCacheHits: Int
        let verdictCacheMisses: Int
        /// v2026.07.19 professional Tree regression fix: developer multi-root scans already
        /// measured every artifact root and produced its complete top-level projection. Preserve
        /// those direct children as the authoritative Tree cache so disclosure cannot start a
        /// second filesystem scan after the primary scan has reached terminal state.
        let developerTreeChildrenProjection: PreparedDeveloperTreeChildrenProjection?
        let diagnostics: TerminalProjectionDiagnostics
        let ranOnMainThread: Bool
    }

    /// Phase-level, path-free evidence for the terminal tail. Counts and timings are intentionally
    /// retained in the DTO so the real App log can distinguish filesystem production from safety,
    /// sorting and developer-cache projection without leaking user paths.
    private struct TerminalProjectionDiagnostics: Sendable {
        let projectionCount: Int
        let rowCount: Int
        let safetyEvaluationCount: Int
        let safetyWorkerCount: Int
        let safetyWorkerObservedMainThread: Bool
        let projectionMergeNanoseconds: UInt64
        let safetyEvaluationNanoseconds: UInt64
        let rowMaterializationNanoseconds: UInt64
        let mainRowSortNanoseconds: UInt64
        let treeProjectionNanoseconds: UInt64
        let developerCacheGroupingNanoseconds: UInt64
        let totalNanoseconds: UInt64
    }

    private struct TerminalSafetyEvaluation: Sendable {
        let path: String
        let verdict: SafetyVerdict
        let rejection: SafetyRejection
        let vendor: VendorRule?
    }

    private struct TerminalSafetyChunk: Sendable {
        let evaluations: [TerminalSafetyEvaluation]
        let observedMainThread: Bool
    }

    private struct PreparedTerminalSafetyEvaluations: Sendable {
        let evaluations: [TerminalSafetyEvaluation]
        let workerCount: Int
        let observedMainThread: Bool
    }

    private struct PreparedDeveloperTreeChildrenProjection: Sendable {
        let cache: [String: [TreeRow]]
        let rootCount: Int
        let directChildCount: Int
        let ranOnMainThread: Bool
    }

    /// Scan-end cache ownership is derived from the terminal DTO that actually committed, not
    /// guessed again from a category string after publication. A developer `.topLevel` DTO owns
    /// an authoritative root -> direct-children cache; every other terminal still invalidates the
    /// scan-period cache exactly as before.
    private enum TerminalTreeCacheFinalization: Sendable {
        case invalidateScanPeriodCache
        case preserveCommittedDeveloperProjection
    }

    private struct TreeCacheRetainedState: Sendable {
        let cache: [String: [TreeRow]]
        let primaryEvidence: ScanIncompleteEvidenceIndex
        let treeEvidenceByRoot: [String: ScanIncompleteEvidenceIndex]
        let previousIssues: [ScanIncompleteIssue]
        let previousPermissionPaths: [String]
        let previousTCCPaths: [String]
        let previousAllPaths: [String]
        let previousTreeProjection: TreeScanEvidenceProjection
        let inputRows: [TreeRow]
    }

    private struct PreparedTreeCacheTransaction: Sendable {
        let cache: [String: [TreeRow]]
        let treeEvidenceByRoot: [String: ScanIncompleteEvidenceIndex]
        let evidence: PreparedIncompleteEvidenceProjection?
        let ranOnMainThread: Bool
    }

    /// Owns both sides of a wide on-demand Tree transaction. The worker performs filtering,
    /// every derived sort projection, parent-row reconciliation and evidence rebuilding away
    /// from MainActor. Keeping the old and new COW roots until after commit also moves their
    /// final teardown off the UI executor.
    private actor TreeCachePresentationWorker {
        private var retainedState: TreeCacheRetainedState?
        private var preparedOutput: PreparedTreeCacheTransaction?
        private let path: String
        private let requestedSort: TreeSortKey
        private let authority: TreeChildrenMeasurementAuthority
        private let measuredParentState: TreeScanEvidenceProjection.ProjectedState?
        private let incompleteIssues: [ScanIncompleteIssue]?
        private let tombstones: PrunedPathMatcher
        private let whitelist: Set<String>
        private let locale: Locale
        private let reconcileParent: Bool

        init(
            retainedState: TreeCacheRetainedState,
            path: String,
            requestedSort: TreeSortKey,
            authority: TreeChildrenMeasurementAuthority,
            measuredParentState: TreeScanEvidenceProjection.ProjectedState?,
            incompleteIssues: [ScanIncompleteIssue]?,
            tombstones: PrunedPathMatcher,
            whitelist: Set<String> = [],
            locale: Locale,
            reconcileParent: Bool
        ) {
            self.retainedState = retainedState
            self.path = path
            self.requestedSort = requestedSort
            self.authority = authority
            self.measuredParentState = measuredParentState
            self.incompleteIssues = incompleteIssues
            self.tombstones = tombstones
            self.whitelist = whitelist
            self.locale = locale
            self.reconcileParent = reconcileParent
        }

        func prepare() -> PreparedTreeCacheTransaction? {
            guard let retainedState else { return nil }
            guard let output = ScanCoordinator.buildTreeCacheTransaction(
                retainedState: retainedState,
                path: path,
                requestedSort: requestedSort,
                authority: authority,
                measuredParentState: measuredParentState,
                incompleteIssues: incompleteIssues,
                tombstones: tombstones,
                whitelist: whitelist,
                locale: locale,
                reconcileParent: reconcileParent
            ) else { return nil }
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private struct MemoryTreeRetainedState: Sendable {
        let cache: [String: [TreeRow]]
        let kids: Set<String>
        let dirIndex: [String: DirAgg]
        let childEdges: [String: Set<String>]
        let fileLeaves: [String: IndexedFileLeaf]
        let evidence: TreeScanEvidenceProjection
        let mtimeCache: [String: MtimeFallbackResult]
    }

    private struct PreparedMemoryTreeProjection: Sendable {
        let cache: [String: [TreeRow]]
        let missingMtimePaths: [String]
        let hasMoreMtimePaths: Bool
        let ranOnMainThread: Bool
    }

    /// Deep-index rows are still a presentation projection. A wide `childEdges[parent]` must not
    /// turn one Tree rebuild into MainActor `kids.map + sort`; this worker materializes semantic
    /// rows and every ordering from immutable index snapshots, then retains both COW generations
    /// through the commit turn.
    private actor MemoryTreePresentationWorker {
        private var retainedState: MemoryTreeRetainedState?
        private var preparedOutput: PreparedMemoryTreeProjection?
        private let parentPath: String
        private let tombstones: PrunedPathMatcher
        private let whitelist: Set<String>
        private let locale: Locale

        init(
            retainedState: MemoryTreeRetainedState,
            parentPath: String,
            tombstones: PrunedPathMatcher,
            whitelist: Set<String> = [],
            locale: Locale
        ) {
            self.retainedState = retainedState
            self.parentPath = parentPath
            self.tombstones = tombstones
            self.whitelist = whitelist
            self.locale = locale
        }

        func prepare() -> PreparedMemoryTreeProjection? {
            guard let retainedState else { return nil }
            guard let output = ScanCoordinator.buildMemoryTreeProjection(
                retainedState: retainedState,
                parentPath: parentPath,
                tombstones: tombstones,
                whitelist: whitelist,
                locale: locale
            ) else { return nil }
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private struct TreeLocaleRetainedState: Sendable {
        let cache: [String: [TreeRow]]
        let snapshotTreeRows: [TreeSortKey: [TreeRow]]
        let perRootTreeRows: [TreeSortKey: [TreeRow]]
        let snapshotRows: [RowItem]
    }

    private struct PreparedTreeLocaleProjection: Sendable {
        let cache: [String: [TreeRow]]
        let snapshotTreeRows: [TreeSortKey: [TreeRow]]
        let perRootTreeRows: [TreeSortKey: [TreeRow]]
        let snapshotRows: [RowItem]
        let snapshotRowRollup: ScanSnapshotRowRollup
        let ranOnMainThread: Bool
    }

    private actor TreeLocalePresentationWorker {
        private var retainedState: TreeLocaleRetainedState?
        private var preparedOutput: PreparedTreeLocaleProjection?
        private let locale: Locale
        private let mainSortKey: MainListSortKey

        init(
            retainedState: TreeLocaleRetainedState,
            locale: Locale,
            mainSortKey: MainListSortKey
        ) {
            self.retainedState = retainedState
            self.locale = locale
            self.mainSortKey = mainSortKey
        }

        func prepare() -> PreparedTreeLocaleProjection? {
            guard let retainedState else { return nil }
            var cache = retainedState.cache
            // Freeze keys before replacing values. Besides avoiding mutation-during-iteration
            // hazards, the temporary key storage is actor-owned and retired off MainActor.
            let cacheKeys = Array(cache.keys)
            for cacheKey in cacheKeys {
                guard !Task.isCancelled else { return nil }
                guard let sortKey = ScanCoordinator.sortKeyFromCacheKey(cacheKey),
                      sortKey == .nameAsc || sortKey == .nameDesc,
                      let rows = cache[cacheKey]
                else { continue }
                cache[cacheKey] = rows.sorted {
                    ScanCoordinator.sortTreeRow($0, before: $1, by: sortKey, locale: locale)
                }
            }

            var snapshotTreeRows = retainedState.snapshotTreeRows
            for sortKey in [TreeSortKey.nameAsc, .nameDesc] {
                guard !Task.isCancelled else { return nil }
                guard let rows = snapshotTreeRows[sortKey] else { continue }
                snapshotTreeRows[sortKey] = rows.sorted {
                    ScanCoordinator.sortTreeRow($0, before: $1, by: sortKey, locale: locale)
                }
            }

            var perRootTreeRows = retainedState.perRootTreeRows
            for sortKey in [TreeSortKey.nameAsc, .nameDesc] {
                guard !Task.isCancelled else { return nil }
                guard let rows = perRootTreeRows[sortKey] else { continue }
                perRootTreeRows[sortKey] = rows.sorted {
                    ScanCoordinator.sortTreeRow($0, before: $1, by: sortKey, locale: locale)
                }
            }

            var snapshotRows = retainedState.snapshotRows
            snapshotRows.sort { mainSortKey.lessThan($0, $1, locale: locale) }
            var snapshotRowRollup = ScanSnapshotRowRollup()
            for row in snapshotRows {
                guard !Task.isCancelled else { return nil }
                snapshotRowRollup.record(verdict: row.verdict, bytes: row.bytes)
            }
            let output = PreparedTreeLocaleProjection(
                cache: cache,
                snapshotTreeRows: snapshotTreeRows,
                perRootTreeRows: perRootTreeRows,
                snapshotRows: snapshotRows,
                snapshotRowRollup: snapshotRowRollup,
                ranOnMainThread: currentThreadIsMainForDiagnostics()
            )
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private struct PreparedMtimeFallbackProjection: Sendable {
        let cache: [String: MtimeFallbackResult]
        let treeCache: [String: [TreeRow]]
        let treeSortCount: Int
        let ranOnMainThread: Bool
    }

    /// v2026.07.19 ownership split: the pure metadata producer terminates before this presentation
    /// worker begins. The worker owns old cache roots and applies immutable measurements/sorts on
    /// its actor, so neither projection nor COW retirement extends primary filesystem settlement.
    private actor MtimeFallbackPresentationWorker {
        private var cache: [String: MtimeFallbackResult]?
        private var treeCache: [String: [TreeRow]]?
        private var preparedOutput: PreparedMtimeFallbackProjection?
        private let paths: [String]
        private let measurements: [String: MtimeFallbackResult]
        private let locale: Locale

        init(
            cache: [String: MtimeFallbackResult],
            treeCache: [String: [TreeRow]],
            paths: [String],
            measurements: [String: MtimeFallbackResult],
            locale: Locale
        ) {
            self.cache = cache
            self.treeCache = treeCache
            self.paths = paths
            self.measurements = measurements
            self.locale = locale
        }

        func prepare() -> PreparedMtimeFallbackProjection? {
            guard var nextCache = cache,
                  var nextTreeCache = treeCache
            else { return nil }
            for path in paths where nextCache[path] == nil {
                guard !Task.isCancelled else { return nil }
                nextCache[path] = measurements[path] ?? .failure
            }

            // Memory Tree rows may have been published with nil mtime while this bounded producer
            // was running. Patch their direct-parent projections off-main so the cache revision
            // refresh renders the new date instead of returning a permanently stale TreeRow.
            var datesByParent: [String: [String: Date]] = [:]
            for path in paths {
                guard !Task.isCancelled else { return nil }
                guard let result = nextCache[path],
                      case .found(let date) = result
                else { continue }
                let parent = String._gsyParentPath(of: path)
                datesByParent[parent, default: [:]][path] = date
            }

            // Patch each parent projection once. Only the two mtime orderings can change order;
            // size/name/count variants receive one linear value patch and keep their stable order.
            var treeSortCount = 0
            for (parent, datesByPath) in datesByParent {
                guard !Task.isCancelled else { return nil }
                for sortKey in TreeSortKey.allCases {
                    let cacheKey = "\(parent)|\(sortKey.rawValue)"
                    guard var rows = nextTreeCache[cacheKey] else { continue }
                    var changed = false
                    for index in rows.indices {
                        let old = rows[index]
                        guard let date = datesByPath[old.path],
                              old.modificationDate != date
                        else { continue }
                        rows[index] = TreeRow(
                            path: old.path,
                            title: old.title,
                            bytes: old.bytes,
                            logicalBytes: old.logicalBytes,
                            fileCount: old.fileCount,
                            isDirectory: old.isDirectory,
                            hasChildren: old.hasChildren,
                            accessState: old.accessState,
                            subtreeCompleteness: old.subtreeCompleteness,
                            modificationDate: date,
                            isSizePending: old.isSizePending,
                            titlePresentation: old.titlePresentation
                        )
                        changed = true
                    }
                    guard changed else { continue }
                    if sortKey == .mtimeAsc || sortKey == .mtimeDesc {
                        rows.sort {
                            ScanCoordinator.sortTreeRow(
                                $0,
                                before: $1,
                                by: sortKey,
                                locale: locale
                            )
                        }
                        treeSortCount &+= 1
                    }
                    nextTreeCache[cacheKey] = rows
                }
            }
            let output = PreparedMtimeFallbackProjection(
                cache: nextCache,
                treeCache: nextTreeCache,
                treeSortCount: treeSortCount,
                ranOnMainThread: currentThreadIsMainForDiagnostics()
            )
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            cache = nil
            treeCache = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private actor MtimePendingRetirementWorker {
        private var paths: Set<String>?
        private var parentCounts: [String: Int]?
        private var continuationParents: Set<String>?

        init(
            paths: Set<String>,
            parentCounts: [String: Int],
            continuationParents: Set<String>
        ) {
            self.paths = paths
            self.parentCounts = parentCounts
            self.continuationParents = continuationParents
        }

        func retire() {
            paths = nil
            parentCounts = nil
            continuationParents = nil
        }
    }

    /// Resetting a scan is a storage-ownership transition, not an in-place `removeAll`. This
    /// actor keeps every potentially wide coordinator-owned COW root alive while MainActor swaps
    /// in fresh empty values, and only then performs element teardown on its own executor.
    private actor ScanSessionRetirementWorker {
        private var snapshotRows: [RowItem]?
        private var buckets: [String: Bucket]?
        private var lastIngestAt: [String: TimeInterval]?
        private var streamSortedIDs: [String]?
        private var dirIndex: [String: DirAgg]?
        private var childEdges: [String: Set<String>]?
        private var fileLeaves: [String: IndexedFileLeaf]?
        private var treeCache: [String: [TreeRow]]?
        private var treePreviewCache: [String: IndexedTreePreviewCacheEntry]?
        private var mtimeCache: [String: MtimeFallbackResult]?
        private var primaryEvidence: ScanIncompleteEvidenceIndex?
        private var treeEvidence: [String: ScanIncompleteEvidenceIndex]?
        private var issues: [ScanIncompleteIssue]?
        private var permissionPaths: [String]?
        private var tccPaths: [String]?
        private var allIncompletePaths: [String]?
        private var treeEvidenceProjection: TreeScanEvidenceProjection?
        private var perRootStaging: [String: PerRootProgress]?
        private var perRootActive: [String: PerRootProgress]?
        private var perRootFinished: [String: PerRootProgress]?
        private var perRootSorted: [PerRootProgress]?
        private var perRootTreeRows: [TreeSortKey: [TreeRow]]?
        private var snapshotTreeRows: [TreeSortKey: [TreeRow]]?
        private var largeFileLeaves: LargeFileLeafTopNHeap?
        private var compactedLargeFileTopN: [LargeFileLeaf]?

        init(
            snapshotRows: [RowItem],
            buckets: [String: Bucket],
            lastIngestAt: [String: TimeInterval],
            streamSortedIDs: [String],
            dirIndex: [String: DirAgg],
            childEdges: [String: Set<String>],
            fileLeaves: [String: IndexedFileLeaf],
            treeCache: [String: [TreeRow]],
            treePreviewCache: [String: IndexedTreePreviewCacheEntry],
            mtimeCache: [String: MtimeFallbackResult],
            primaryEvidence: ScanIncompleteEvidenceIndex,
            treeEvidence: [String: ScanIncompleteEvidenceIndex],
            issues: [ScanIncompleteIssue],
            permissionPaths: [String],
            tccPaths: [String],
            allIncompletePaths: [String],
            treeEvidenceProjection: TreeScanEvidenceProjection,
            perRootStaging: [String: PerRootProgress],
            perRootActive: [String: PerRootProgress],
            perRootFinished: [String: PerRootProgress],
            perRootSorted: [PerRootProgress],
            perRootTreeRows: [TreeSortKey: [TreeRow]],
            snapshotTreeRows: [TreeSortKey: [TreeRow]],
            largeFileLeaves: LargeFileLeafTopNHeap,
            compactedLargeFileTopN: [LargeFileLeaf]?
        ) {
            self.snapshotRows = snapshotRows
            self.buckets = buckets
            self.lastIngestAt = lastIngestAt
            self.streamSortedIDs = streamSortedIDs
            self.dirIndex = dirIndex
            self.childEdges = childEdges
            self.fileLeaves = fileLeaves
            self.treeCache = treeCache
            self.treePreviewCache = treePreviewCache
            self.mtimeCache = mtimeCache
            self.primaryEvidence = primaryEvidence
            self.treeEvidence = treeEvidence
            self.issues = issues
            self.permissionPaths = permissionPaths
            self.tccPaths = tccPaths
            self.allIncompletePaths = allIncompletePaths
            self.treeEvidenceProjection = treeEvidenceProjection
            self.perRootStaging = perRootStaging
            self.perRootActive = perRootActive
            self.perRootFinished = perRootFinished
            self.perRootSorted = perRootSorted
            self.perRootTreeRows = perRootTreeRows
            self.snapshotTreeRows = snapshotTreeRows
            self.largeFileLeaves = largeFileLeaves
            self.compactedLargeFileTopN = compactedLargeFileTopN
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            snapshotRows = nil
            buckets = nil
            lastIngestAt = nil
            streamSortedIDs = nil
            dirIndex = nil
            childEdges = nil
            fileLeaves = nil
            treeCache = nil
            treePreviewCache = nil
            mtimeCache = nil
            primaryEvidence = nil
            treeEvidence = nil
            issues = nil
            permissionPaths = nil
            tccPaths = nil
            allIncompletePaths = nil
            treeEvidenceProjection = nil
            perRootStaging = nil
            perRootActive = nil
            perRootFinished = nil
            perRootSorted = nil
            perRootTreeRows = nil
            snapshotTreeRows = nil
            largeFileLeaves = nil
            compactedLargeFileTopN = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private actor TreeCacheRetirementWorker {
        private var cache: [String: [TreeRow]]?
        private var previewCache: [String: IndexedTreePreviewCacheEntry]?

        init(
            cache: [String: [TreeRow]],
            previewCache: [String: IndexedTreePreviewCacheEntry]
        ) {
            self.cache = cache
            self.previewCache = previewCache
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            cache = nil
            previewCache = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private struct SubtreeRescanRetainedState: Sendable {
        let cache: [String: [TreeRow]]
        let tasks: [String: TreeChildrenTaskState]
        let inFlight: Set<String>
    }

    private struct PreparedSubtreeRescanTransaction: Sendable {
        let cache: [String: [TreeRow]]
        let tasks: [String: TreeChildrenTaskState]
        let inFlight: Set<String>
        let cancelledTasks: [Task<Void, Never>]
        let cancelledTaskTokens: [UUID]
        let removedCacheKeyCount: Int
        let removedTaskKeyCount: Int
        let removedInFlightKeyCount: Int
        let shouldCommit: Bool
        let ranOnMainThread: Bool
    }

    /// v2026.07.18 Tree P2 root-cause fix. Subtree refresh is a COW transaction: every key match,
    /// dictionary/set rebuild, task cancellation and old TreeRow ownership stays on this actor.
    /// MainActor only compares revisions and swaps the three prepared storage roots.
    private actor SubtreeRescanWorker {
        private var retainedState: SubtreeRescanRetainedState?
        private var preparedOutput: PreparedSubtreeRescanTransaction?
        private let path: String
        private let hasIndexedChildren: Bool
        private let removeCache: Bool
        private let forceRefresh: Bool
        private let previouslyCancelledTokens: Set<UUID>

        init(
            retainedState: SubtreeRescanRetainedState,
            path: String,
            hasIndexedChildren: Bool,
            removeCache: Bool,
            forceRefresh: Bool,
            previouslyCancelledTokens: Set<UUID>
        ) {
            self.retainedState = retainedState
            self.path = path
            self.hasIndexedChildren = hasIndexedChildren
            self.removeCache = removeCache
            self.forceRefresh = forceRefresh
            self.previouslyCancelledTokens = previouslyCancelledTokens
        }

        func prepare() -> PreparedSubtreeRescanTransaction? {
            guard let retainedState else { return nil }

            var nextCache = removeCache ? [:] : retainedState.cache
            if removeCache { nextCache.reserveCapacity(retainedState.cache.count) }
            var removedCacheKeyCount = 0
            if removeCache {
                for (key, rows) in retainedState.cache {
                    if ScanCoordinator.subtreeCacheKey(key, belongsTo: path) {
                        removedCacheKeyCount += 1
                    } else {
                        nextCache[key] = rows
                    }
                }
            }

            var nextTasks: [String: TreeChildrenTaskState] = [:]
            nextTasks.reserveCapacity(retainedState.tasks.count)
            var cancelledTasks: [Task<Void, Never>] = []
            var cancelledTaskTokens: [UUID] = []
            var removedTaskKeys = Set<String>()
            var removedTaskKeyCount = 0
            for (key, state) in retainedState.tasks {
                if ScanCoordinator.subtreeCacheKey(key, belongsTo: path) {
                    removedTaskKeyCount += 1
                    removedTaskKeys.insert(key)
                    if !previouslyCancelledTokens.contains(state.token) {
                        state.task.cancel()
                        cancelledTasks.append(state.task)
                        cancelledTaskTokens.append(state.token)
                    }
                } else {
                    nextTasks[key] = state
                }
            }

            var nextInFlight = Set<String>()
            nextInFlight.reserveCapacity(retainedState.inFlight.count)
            var removedInFlightKeyCount = 0
            for key in retainedState.inFlight {
                // Preserve the established refresh contract exactly: in-flight ownership is
                // cleared for the task keys selected above. An impossible orphan key is not
                // silently reinterpreted as refreshable state by this performance refactor.
                if removedTaskKeys.contains(key) {
                    removedInFlightKeyCount += 1
                } else {
                    nextInFlight.insert(key)
                }
            }

            let output = PreparedSubtreeRescanTransaction(
                cache: nextCache,
                tasks: nextTasks,
                inFlight: nextInFlight,
                cancelledTasks: cancelledTasks,
                cancelledTaskTokens: cancelledTaskTokens,
                removedCacheKeyCount: removedCacheKeyCount,
                removedTaskKeyCount: removedTaskKeyCount,
                removedInFlightKeyCount: removedInFlightKeyCount,
                shouldCommit: forceRefresh
                    || removedCacheKeyCount > 0
                    || removedTaskKeyCount > 0
                    || removedInFlightKeyCount > 0
                    || (removeCache && !hasIndexedChildren),
                ranOnMainThread: ScanCoordinator.currentThreadIsMainForDiagnostics()
            )
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    /// One explicit "refresh this directory" measurement. Unlike the ordinary top-level Tree
    /// projection this carries the complete descendant index, so an already indexed directory
    /// cannot republish stale `childEdges` after its presentation cache is invalidated.
    /// v2026.07.18: cancellation has no measurement value and therefore never reaches commit.
    private struct IndexedSubtreeMeasurement: Sendable {
        var rootPath: String
        var dirIndex: [String: DirAgg]
        var childEdges: [String: Set<String>]
        var fileLeaves: [String: IndexedFileLeaf]
        var incompleteIssues: [ScanIncompleteIssue]
        var completionStatus: ScanCompletionStatus
        var ranOnMainThread: Bool
        var allocations: FileAllocationSnapshot = .init()

        var isComplete: Bool {
            completionStatus == .complete && incompleteIssues.isEmpty
        }
    }

    private struct IndexedSubtreeRetainedState: Sendable {
        var snapshot: ScanSnapshot
        var totalBytes: Int64
        var scannedFiles: Int
        var buckets: [String: Bucket]
        var snapshotTreeRows: [TreeSortKey: [TreeRow]]
        var perRootStaging: [String: PerRootProgress]
        var perRootActive: [String: PerRootProgress]
        var perRootFinished: [String: PerRootProgress]
        var perRootSorted: [PerRootProgress]
        var perRootTreeRows: [TreeSortKey: [TreeRow]]
        var mainListSortKey: MainListSortKey
        var dirIndex: [String: DirAgg]
        var childEdges: [String: Set<String>]
        var fileLeaves: [String: IndexedFileLeaf]
        var treeCache: [String: [TreeRow]]
        var mtimeCache: [String: MtimeFallbackResult]
        var primaryEvidence: ScanIncompleteEvidenceIndex
        var treeEvidenceByRoot: [String: ScanIncompleteEvidenceIndex]
        var previousIssues: [ScanIncompleteIssue]
        var previousPermissionPaths: [String]
        var previousTCCPaths: [String]
        var previousAllPaths: [String]
        var previousTreeProjection: TreeScanEvidenceProjection
        var allocationCatalog: AllocationCatalog?
        var largeFileLeaves: LargeFileLeafTopNHeap
        var compactedLargeFileTopN: [LargeFileLeaf]?
        var largeFileMinBytes: Int64
        var scanResultRoots: [String]
        var usesPerRootPresentation: Bool
        var forceSnapshotTreeLeafPresentation: Bool
        var usesLargeFileTopNOnly: Bool
        var engine: SafetyEngine
        var trie: VendorTrieNode
        var home: String
    }

    private struct PreparedIndexedSubtreeTransaction: Sendable {
        var snapshot: ScanSnapshot
        var totalBytes: Int64
        var scannedFiles: Int
        var buckets: [String: Bucket]
        var snapshotTreeRows: [TreeSortKey: [TreeRow]]
        var perRootStaging: [String: PerRootProgress]
        var perRootActive: [String: PerRootProgress]
        var perRootFinished: [String: PerRootProgress]
        var perRootFinishedCount: Int
        var perRootSorted: [PerRootProgress]
        var perRootTreeRows: [TreeSortKey: [TreeRow]]
        var dirIndex: [String: DirAgg]
        var childEdges: [String: Set<String>]
        var fileLeaves: [String: IndexedFileLeaf]
        var treeCache: [String: [TreeRow]]
        var mtimeCache: [String: MtimeFallbackResult]
        var treeEvidenceByRoot: [String: ScanIncompleteEvidenceIndex]
        var evidence: PreparedIncompleteEvidenceProjection
        var allocationCatalog: AllocationCatalog?
        var largeFileLeaves: LargeFileLeafTopNHeap
        var compactedLargeFileTopN: [LargeFileLeaf]?
        var restoredTombstones: DeletedPathIndex? = nil
        var requiresAllocationRebaseline: Bool = false
        var ranOnMainThread: Bool
    }

    /// v2026.07.18 Tree P2 root-cause fix: rebuilding descendant dictionaries, all visible sort
    /// projections, and releasing the superseded COW generation are generic-executor work. The
    /// coordinator only checks revisions and swaps prepared storage roots on MainActor.
    private actor IndexedSubtreeTransactionWorker {
        private var retainedState: IndexedSubtreeRetainedState?
        private var preparedOutput: PreparedIndexedSubtreeTransaction?
        private var measurement: IndexedSubtreeMeasurement?
        private let tombstones: PrunedPathMatcher
        private let whitelist: Set<String>
        private let locale: Locale
        private let restoredPaths: [String]

        init(
            retainedState: IndexedSubtreeRetainedState,
            measurement: IndexedSubtreeMeasurement,
            tombstones: PrunedPathMatcher,
            whitelist: Set<String> = [],
            locale: Locale,
            restoredPaths: [String] = []
        ) {
            self.retainedState = retainedState
            self.measurement = measurement
            self.tombstones = tombstones
            self.whitelist = whitelist
            self.locale = locale
            self.restoredPaths = restoredPaths
        }

        func prepare() -> PreparedIndexedSubtreeTransaction? {
            guard let retainedState, let measurement else { return nil }
            let observedRestores = restoredPaths.filter {
                measurement.dirIndex[$0] != nil || measurement.fileLeaves[$0] != nil
                    || measurement.dirIndex[measurement.rootPath] != nil
                        && ScanCoordinator.pathBelongsToSubtree(measurement.rootPath, rootPath: $0)
            }
            let effectiveTombstones = PrunedPathMatcher(paths: tombstones.roots.filter { root in
                !observedRestores.contains { ScanCoordinator.pathBelongsToSubtree(root, rootPath: $0) }
            })
            guard var output = ScanCoordinator.buildIndexedSubtreeTransaction(
                retainedState: retainedState,
                measurement: measurement,
                tombstones: effectiveTombstones,
                whitelist: whitelist,
                locale: locale
            ) else { return nil }
            if !observedRestores.isEmpty {
                output.restoredTombstones = DeletedPathIndex(matcher: effectiveTombstones)
            }
            if let previous = retainedState.allocationCatalog?.snapshot(),
               previous.covers(directory: measurement.rootPath) {
                output.requiresAllocationRebaseline = measurement.allocations.introducesLinkedIdentity(comparedTo: previous)
            }
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            measurement = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private struct PreparedIncompleteEvidenceProjection: Sendable {
        let combinedIssues: [ScanIncompleteIssue]
        let treeProjection: TreeScanEvidenceProjection
        let permissionPaths: [String]
        let tccPaths: [String]
        let allPaths: [String]
        let issuesChanged: Bool
        let permissionPathsChanged: Bool
        let tccPathsChanged: Bool
        let allPathsChanged: Bool
        let ranOnMainThread: Bool
    }

    private struct PreparedPerRootProjection: Sendable {
        let active: [String: PerRootProgress]
        let finished: [String: PerRootProgress]
        let finishedCount: Int
        let sorted: [PerRootProgress]
        let treeRowsBySort: [TreeSortKey: [TreeRow]]
        let replacesTreeRows: Bool
        let activeChanged: Bool
        let finishedChanged: Bool
        let finishedCountChanged: Bool
        let sortedChanged: Bool
        let ranOnMainThread: Bool
    }

    private struct PerRootRetainedState: Sendable {
        let staging: [String: PerRootProgress]
        let previousActive: [String: PerRootProgress]
        let previousFinished: [String: PerRootProgress]
        let previousFinishedCount: Int
        let previousSorted: [PerRootProgress]
    }

    private actor PerRootPresentationWorker {
        private var retainedState: PerRootRetainedState?
        private var preparedOutput: PreparedPerRootProjection?
        private let tombstones: PrunedPathMatcher
        private let preparationDelayNanosecondsForTesting: UInt64

        init(
            retainedState: PerRootRetainedState,
            tombstones: PrunedPathMatcher,
            preparationDelayNanosecondsForTesting: UInt64
        ) {
            self.retainedState = retainedState
            self.tombstones = tombstones
            self.preparationDelayNanosecondsForTesting = preparationDelayNanosecondsForTesting
        }

        func prepare() async -> PreparedPerRootProjection? {
            if preparationDelayNanosecondsForTesting > 0 {
                try? await Task.sleep(
                    nanoseconds: preparationDelayNanosecondsForTesting
                )
            }
            guard let retainedState else { return nil }
            let output = ScanCoordinator.buildLivePerRootProjection(
                staging: retainedState.staging,
                tombstones: tombstones,
                previousActive: retainedState.previousActive,
                previousFinished: retainedState.previousFinished,
                previousFinishedCount: retainedState.previousFinishedCount,
                previousSorted: retainedState.previousSorted
            )
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    private struct TerminalRetainedState: Sendable {
        let baseBuckets: [String: Bucket]
        let projections: [TerminalProjectionEnvelope]
        /// Non-nil only for the developer terminal transaction. Keeping the replaced cache in
        /// the worker moves its final COW release off MainActor together with the other terminal
        /// containers; an empty dictionary still intentionally enables developer cache seeding.
        let replacedDeveloperTreeChildrenCache: [String: [TreeRow]]?
        let previousSnapshotRows: [RowItem]
        let previousSnapshotTreeRows: [TreeSortKey: [TreeRow]]
        let previousLastIngestAt: [String: TimeInterval]
        let previousStreamSortedIDs: [String]
        let primaryEvidence: ScanIncompleteEvidenceIndex
        let treeEvidenceByRoot: [String: ScanIncompleteEvidenceIndex]
        let previousIssues: [ScanIncompleteIssue]
        let previousPermissionPaths: [String]
        let previousTCCPaths: [String]
        let previousAllPaths: [String]
        let previousTreeProjection: TreeScanEvidenceProjection
        let perRootStaging: [String: PerRootProgress]
        let previousPerRootActive: [String: PerRootProgress]
        let previousPerRootFinished: [String: PerRootProgress]
        let previousPerRootFinishedCount: Int
        let previousPerRootSorted: [PerRootProgress]
        let previousPerRootTreeRows: [TreeSortKey: [TreeRow]]
    }

    private struct PreparedTerminalTransaction: Sendable {
        let presentation: PreparedTerminalPresentation
        let evidence: PreparedIncompleteEvidenceProjection?
        let perRoot: PreparedPerRootProjection
        let worker: TerminalPresentationWorker
        let attemptCount: Int
    }

    private struct PreparedTerminalWorkerOutput: Sendable {
        let presentation: PreparedTerminalPresentation
        let evidence: PreparedIncompleteEvidenceProjection?
        let perRoot: PreparedPerRootProjection
    }

    private struct TerminalRetirementDiagnostics: Sendable {
        let ranOnMainThread: Bool
        let durationNanoseconds: UInt64
    }

    /// Owns every wide old/new COW boundary until MainActor has completed its storage swaps.
    /// Releasing the retained state inside this actor prevents Array/Dictionary element teardown
    /// from becoming an otherwise invisible terminal UI stall.
    private actor TerminalPresentationWorker {
        private var retainedState: TerminalRetainedState?
        /// Keep the newly prepared COW storage actor-owned as well. On a CAS rejection the
        /// MainActor drops its copy first, then `retire()` performs the final release here.
        private var preparedOutput: PreparedTerminalWorkerOutput?
        private let evidenceWasDirty: Bool
        private let fullDiskPathNamespace: ScanPathNamespace
        private let tombstones: PrunedPathMatcher
        private let engine: SafetyEngine
        private let trie: VendorTrieNode
        private let home: String
        private let whitelist: Set<String>
        private let sortKey: MainListSortKey
        private let locale: Locale

        init(
            retainedState: TerminalRetainedState,
            evidenceWasDirty: Bool,
            fullDiskPathNamespace: ScanPathNamespace,
            tombstones: PrunedPathMatcher,
            engine: SafetyEngine,
            trie: VendorTrieNode,
            home: String,
            whitelist: Set<String>,
            sortKey: MainListSortKey,
            locale: Locale
        ) {
            self.retainedState = retainedState
            self.evidenceWasDirty = evidenceWasDirty
            self.fullDiskPathNamespace = fullDiskPathNamespace
            self.tombstones = tombstones
            self.engine = engine
            self.trie = trie
            self.home = home
            self.whitelist = whitelist
            self.sortKey = sortKey
            self.locale = locale
        }

        func prepare() async -> PreparedTerminalWorkerOutput? {
            guard let retainedState else { return nil }
            let evidence = evidenceWasDirty
                ? ScanCoordinator.buildIncompleteEvidenceProjection(
                    primaryEvidence: retainedState.primaryEvidence,
                    treeEvidenceByRoot: retainedState.treeEvidenceByRoot,
                    previousIssues: retainedState.previousIssues,
                    previousPermissionPaths: retainedState.previousPermissionPaths,
                    previousTCCPaths: retainedState.previousTCCPaths,
                    previousAllPaths: retainedState.previousAllPaths
                )
                : nil
            guard let presentation = await ScanCoordinator.buildTerminalPresentation(
                baseBuckets: retainedState.baseBuckets,
                projections: retainedState.projections,
                seedDeveloperTreeChildrenCache:
                    retainedState.replacedDeveloperTreeChildrenCache != nil,
                fullDiskPathNamespace: fullDiskPathNamespace,
                tombstones: tombstones,
                engine: engine,
                trie: trie,
                home: home,
                whitelist: whitelist,
                sortKey: sortKey,
                locale: locale,
                treeEvidence: evidence?.treeProjection ?? retainedState.previousTreeProjection
            ) else { return nil }
            let perRoot = ScanCoordinator.buildPerRootProjection(
                staging: retainedState.perRootStaging,
                tombstones: tombstones,
                previousActive: retainedState.previousPerRootActive,
                previousFinished: retainedState.previousPerRootFinished,
                previousFinishedCount: retainedState.previousPerRootFinishedCount,
                previousSorted: retainedState.previousPerRootSorted,
                evidence: evidence?.treeProjection ?? retainedState.previousTreeProjection,
                locale: locale,
                sessionIsScanning: false
            )
            let output = PreparedTerminalWorkerOutput(
                presentation: presentation,
                evidence: evidence,
                perRoot: perRoot
            )
            preparedOutput = output
            return output
        }

        func retire() -> TerminalRetirementDiagnostics {
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            return TerminalRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }
    private var buckets: [String: Bucket] = [:]

    /// v1.3：每个 bucket 最近一次有 ingest 写入的时间戳（reference time interval）。
    ///
    /// 用法：publishSnapshot 时计算 `now - lastIngestAt[bucketPath] < activityWindow` 即视为 active，
    /// 写到 [RowItem.isActive](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L24)；
    /// UI（[ScanRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanRow.swift)）
    /// 据此给 bytes 数字上色 + 脉动。
    ///
    /// 为什么这样设计：BulkScanner 的 6 worker 在不同子树并发枚举时，每个 worker yield .node 进 ingest
    /// 都会落到对应 bucketPath（一级祖先），所以"哪些 bucket 最近有数据进来"= "哪些子树正在被扫"。
    /// 不需要额外的 worker → bucket 通知通道，零侵入到 ScanKit。
    private var lastIngestAt: [String: TimeInterval] = [:]

    /// v1.3：active 判定窗口。最近 N 秒内有 ingest 即视为正在扫描。
    /// 800ms 是经验值——大于 BulkScanner 默认 progress 节流（150ms）的若干倍，能容忍小的 ingest 间隙；
    /// 又显著小于"扫一个普通子目录的耗时"（通常 1~10s），不会让停掉的 bucket 持续假亮。
    private let activityWindow: TimeInterval = 0.8

    /// v1.0 T3：任意目录子树聚合索引，支撑 TreeBrowserView 多层下钻。
    /// key = 任意目录全路径，value = 该目录"整个子树"累计的 bytes / fileCount。
    /// 还额外维护 parent->Set<directChildPath> 边，让 OutlineGroup 能 O(1) 取子。
    ///
    /// v1.5.4：新增 `modificationDate` —— 仅在该目录"作为节点本身被 ingest"时写入，
    /// 即来自 [BulkScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 的目录条目自身的 inode mtime（Finder 风格）。
    /// 不做 max(子孙) 聚合，避免每个文件叶子都要回写所有祖先字段；nil 表示尚未拿到（极早期 publish 帧）。
    private struct DirAgg: Sendable {
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var modificationDate: Date? = nil
    }
    private var dirIndex: [String: DirAgg] = [:]
    /// 父目录 -> 直接子项集合（含目录与文件路径）。文件叶子也存进来方便单层展示。
    private var childEdges: [String: Set<String>] = [:]
    /// 叶子文件 path -> (allocated size, logical size, isDir, mtime?)；展示时区分文件与目录。
    /// v1.5.4 加 modificationDate：来源同 dirIndex —— 直接拿 [FSNode.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/FSNode.swift#L14)。
    /// v2026.10.08: retain the producer's regular-file classification through refresh,
    /// Tree projection and pruning; a zero-byte FIFO is still not a regular file.
    private struct IndexedFileLeaf: Sendable {
        let bytes: Int64
        let logicalBytes: Int64
        let isDir: Bool
        let modificationDate: Date?
        var isRegularFile: Bool = true
        var fileCount: Int { isRegularFile ? 1 : 0 }
    }

    private var fileLeaves: [String: IndexedFileLeaf] = [:]

    /// TreeBrowserView 的按需子树扫描缓存。
    ///
    /// 当 `enableTreeDeepIndex == false`（v1.3.z 起的默认）时，内存里没有
    /// `childEdges/dirIndex/fileLeaves`，TreeBrowserView 不能再同步拿到子项。
    /// 但 SwiftUI body 不能 await，所以这里做"同步表面 + 后台填充"双层缓存：
    ///   - body 每次调 `directChildren(of:sortedBy:)`，先看本 cache
    ///   - cache miss → 同步返 [], 同时启一个后台 Task 扫描当前目录子树并写回 cache
    ///   - 写回时 @Published 触发 view 重算, 第二帧拿到结果
    ///
    /// key = `"\(path)|\(sortKey.rawValue)"`，让不同排序各自缓存（用户切排序不丢上次结果）。
    /// 扫描结束 / 切类目 / 切根 时由 cancel/reset 主动清空，避免跨会话脏数据。
    ///
    /// **Step 9a / 2026-06**：从 `@Published` 解耦为普通字典。
    /// 历史问题：`@Published` 字典每次写入都会让整个 ScanCoordinator
    /// `objectWillChange` fire，所有 view（含 MainView 主列表 / SystemProbe banner）
    /// 都被波及一次重算；而真正需要被通知的只有 TreeBrowserView，
    /// 已经通过 [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L328-L332)
    /// 显式触发。新做法：cache 自己是普通字典，配套一条
    /// [childrenCacheVersion](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 计数器 @Published（仅给可能要按 cache 失效细粒度刷新的 view 订阅）。
    /// 主流程依赖 structuralRevision 即可。
    private var treeChildrenCache: [String: [TreeRow]] = [:]
    /// A bounded, explicitly non-authoritative disclosure preview. It must never be merged into
    /// `treeChildrenCache`: that cache means a complete measured/projected direct-child set and is
    /// consumed by prune/reconciliation code. Preview identity includes every source that affects
    /// its rows; repeated SwiftUI getters for the same revision are therefore O(1).
    private struct IndexedTreePreviewCacheEntry: Sendable {
        let sourceRevision: UInt64
        let generation: UUID
        let localeIdentifier: String
        let fanOut: Int
        let inspectedCount: Int
        let rows: [TreeRow]
    }
    private var indexedTreePreviewCache: [String: IndexedTreePreviewCacheEntry] = [:]
    /// Completed root rows, materialized once on a generic executor for every supported Tree
    /// ordering. Root `directChildren` reads are O(1) dictionary lookups even when SwiftUI asks
    /// repeatedly during layout.
    private var snapshotTreeRowsBySort: [TreeSortKey: [TreeRow]] = [:]
    /// **Step 9a / 2026-06**：cache 写入计数器，monotonic UInt64。
    /// 任何 `treeChildrenCache` 写入（写新键 / 移除旧键 / 整轮 removeAll）后
    /// 都必须经过 [bumpChildrenCacheVersion()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 把它 &+= 1。view 端**通常不需要**直接订阅这条信号（structuralRevision 已经
    /// 覆盖），保留它是为：
    ///   - 单元测试断言"cache 写入 N 次 → version 自增 N 次"
    ///   - 未来 view 想做"按 cache 命中率细粒度刷新"留 hook
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var childrenCacheVersion: UInt64 = 0
    /// in-flight 路径集合：避免同 path 在 cache miss 时被 view body 多次重算疯狂启 Task。
    /// **不**参与 @Published（不需要触发 view 更新）。
    private var treeChildrenInFlight: Set<String> = []
    private struct TreeChildrenTaskState: Sendable {
        enum OwnerKind: Sendable, Equatable {
            case presentation
            case filesystem
        }

        let token: UUID
        let task: Task<Void, Never>
        let ownerKind: OwnerKind
    }
    /// v2026.07.16：generation 只能阻止旧结果写回，不能停止旧磁盘 IO。
    /// 保存每个按需 Tree 任务及其唯一 token，切换扫描/刷新目录时真实 cancel。
    /// 清理必须同时匹配 cacheKey + token；否则旧任务 A 的迟到收尾会把同 key 的
    /// 新任务 B 从 in-flight 集合移除，随后 View 重算又派发第三轮重复深扫。
    private var treeChildrenTasks: [String: TreeChildrenTaskState] = [:]
    /// Cache revisions do not cover task owner replacement. Subtree rescan CAS checks this
    /// independent counter so a completed/replaced task can never be overwritten by a stale
    /// off-main dictionary snapshot.
    private var treeChildrenOwnershipRevision: UInt64 = 0
    /// MainActor methods are reentrant across `await`. Refresh intent is path-scoped: a newer
    /// overlapping request replaces the old token, while unrelated directories remain independent
    /// and may use the second Tree gate permit. A singleton token/revision here used to make a
    /// refresh under `/Users/A` cancel `/Users/B` even though the filesystem producers did not
    /// overlap.
    private struct IndexedSubtreeTaskState: Sendable {
        let token: UUID
        let identity: TreeFilesystemMeasurementIdentity
        let task: Task<IndexedSubtreeMeasurement?, Never>
        let cancel: @Sendable () -> Void
    }
    private struct IndexedSubtreeRequestState: Sendable {
        let token: UUID
        let identity: TreeFilesystemMeasurementIdentity
    }
    private var indexedSubtreeRequests: [String: IndexedSubtreeRequestState] = [:]
    private var indexedSubtreeScanTasks: [String: IndexedSubtreeTaskState] = [:]
    /// Public `directChildrenAsync` callers are not represented in the View-owned cache task
    /// dictionary. Track their admitted intent on MainActor so primary cancellation still requests
    /// one lease-domain snapshot even when this is the only active Tree producer.
    private var directTreeAsyncFilesystemOwners: [
        UUID: TreeFilesystemMeasurementIdentity
    ] = [:]
    private var treeLocaleProjectionTask: Task<Void, Never>?
    private var treeLocaleProjectionToken: UUID?
    private var mtimeFallbackProbeTask: Task<Void, Never>?
    private var mtimeFallbackProbeToken: UUID?
    private struct MtimeFallbackFilesystemTaskState: Sendable {
        let token: UUID
        let paths: [String]
        let task: Task<[String: MtimeFallbackResult], Never>
    }
    private var mtimeFallbackFilesystemTaskState: MtimeFallbackFilesystemTaskState?
    private var mtimeFallbackPendingPaths: Set<String> = []
    private var mtimeFallbackPendingParentCounts: [String: Int] = [:]
    private var mtimeFallbackContinuationParents: Set<String> = []
    nonisolated private static let mtimeFallbackBatchSize = 256
    nonisolated private static let mtimeFallbackPendingLimit = 2_048

    /// Cancels every Tree owner and returns settlement handles for real filesystem work only.
    /// Callers that are about to admit a primary scan must attach these handles to that primary
    /// admission reservation. Presentation-only cancellation intentionally returns no handle.
    @discardableResult
    private func cancelAllTreeChildrenFetches() -> [Task<Void, Never>] {
        treeFetchGeneration = UUID()
        let childTaskStates = Array(treeChildrenTasks.values)
        for state in childTaskStates { state.task.cancel() }
        treeLocaleProjectionTask?.cancel()
        mtimeFallbackProbeTask?.cancel()
        let mtimeFilesystemState = mtimeFallbackFilesystemTaskState
        mtimeFilesystemState?.task.cancel()
        let indexedTaskStates = Array(indexedSubtreeScanTasks.values)
        for state in indexedTaskStates { state.cancel() }
        var filesystemSettlements: [Task<Void, Never>] = []
        var filesystemOwnerPaths = Set<String>()
        for (cacheKey, state) in treeChildrenTasks where state.ownerKind == .filesystem {
            if let separator = cacheKey.lastIndex(of: "|") {
                filesystemOwnerPaths.insert(String(cacheKey[..<separator]))
            }
        }
        for state in indexedTaskStates {
            filesystemOwnerPaths.insert(state.identity.publicPath)
        }
        filesystemOwnerPaths.formUnion(
            indexedSubtreeRequests.values.map { $0.identity.publicPath }
        )
        filesystemOwnerPaths.formUnion(
            directTreeAsyncFilesystemOwners.values.map(\.publicPath)
        )
        let hadTreeFilesystemOwner = childTaskStates.contains {
            $0.ownerKind == .filesystem
        } || !indexedTaskStates.isEmpty
            || !indexedSubtreeRequests.isEmpty
            || !directTreeAsyncFilesystemOwners.isEmpty
        if hadTreeFilesystemOwner {
            let leaseDomain = treeFilesystemLeaseDomain
            filesystemSettlements.append(Task.detached(priority: .utility) {
                await leaseDomain.cancelAllAndWait(reason: "primary_cancel")
            })
        }
        // Only the pure attributes-of-item producer enters settlement. Its controller and the
        // cache/sort projection worker are cancelled/CAS-rejected but never awaited by primary
        // admission.
        if let mtimeFilesystemState {
            filesystemOwnerPaths.formUnion(mtimeFilesystemState.paths)
            filesystemSettlements.append(Task.detached(priority: .utility) {
                _ = await mtimeFilesystemState.task.value
            })
        }
        let pendingRetirement = MtimePendingRetirementWorker(
            paths: mtimeFallbackPendingPaths,
            parentCounts: mtimeFallbackPendingParentCounts,
            continuationParents: mtimeFallbackContinuationParents
        )
        let hadTreeChildrenOwnership = !treeChildrenTasks.isEmpty || !treeChildrenInFlight.isEmpty
        treeChildrenTasks.removeAll(keepingCapacity: true)
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        if hadTreeChildrenOwnership {
            treeChildrenOwnershipRevision &+= 1
        }
        treeLocaleProjectionTask = nil
        treeLocaleProjectionToken = nil
        mtimeFallbackProbeTask = nil
        mtimeFallbackProbeToken = nil
        mtimeFallbackFilesystemTaskState = nil
        indexedSubtreeRequests.removeAll(keepingCapacity: true)
        indexedSubtreeScanTasks.removeAll(keepingCapacity: true)
        mtimeFallbackPendingPaths = []
        mtimeFallbackPendingParentCounts = [:]
        mtimeFallbackContinuationParents = []
        Task { @MainActor in
            await Task.yield()
            await pendingRetirement.retire()
        }
        GSYLog.info(
            .flow,
            "tree.fs_lease.cancel_snapshot handles=\(filesystemSettlements.count) "
                + "path_count=\(filesystemOwnerPaths.count) "
                + "presentation_owners=\(childTaskStates.filter { $0.ownerKind == .presentation }.count)"
        )
        return filesystemSettlements
    }

    private func treeChildrenTaskIsCurrent(
        cacheKey: String,
        token: UUID,
        generation: UUID
    ) -> Bool {
        treeFetchGeneration == generation && treeChildrenTasks[cacheKey]?.token == token
    }

    /// v2026.07.19 performance-regression guard: primary admission must observe only the exact
    /// filesystem portion of a disclosure task. Shallow/deep projection, sorting and cache commit
    /// remain cancellable, but changing their owner kind prevents presentation work from creating
    /// a false filesystem settlement barrier.
    private func setTreeChildrenTaskOwnerKind(
        _ ownerKind: TreeChildrenTaskState.OwnerKind,
        cacheKey: String,
        token: UUID
    ) {
        guard let state = treeChildrenTasks[cacheKey],
              state.token == token,
              state.ownerKind != ownerKind
        else { return }
        treeChildrenTasks[cacheKey] = TreeChildrenTaskState(
            token: state.token,
            task: state.task,
            ownerKind: ownerKind
        )
        treeChildrenOwnershipRevision &+= 1
    }

    /// Ends one Tree producer. When `publishTerminalRevision` is true, ownership is cleared before
    /// the single UI revision is emitted, so a subscriber can never observe committed rows while
    /// `isFetchingChildren` still reports true.
    ///
    /// v2026.07.19 regression note: publishing the cache first and removing ownership afterward
    /// left the final flat projection permanently stuck on its loading frame.
    private func finishTreeChildrenTask(
        cacheKey: String,
        token: UUID,
        publishTerminalRevision: Bool = false,
        changedPath: String? = nil
    ) {
        guard treeChildrenTasks[cacheKey]?.token == token else { return }
        treeChildrenTasks.removeValue(forKey: cacheKey)
        let removedVisibleFetch = treeChildrenInFlight.remove(cacheKey) != nil
        treeChildrenOwnershipRevision &+= 1
        if publishTerminalRevision, removedVisibleFetch {
            // v2026.07.20 performance guard: a single disclosure terminal changes only that
            // parent's rows/loading state. Preserve its identity so TreeBrowserView can patch the
            // contiguous segment instead of rebuilding every visible row.
            bumpChildrenCacheVersion(changedPath: changedPath)
        }
    }

    /// v2026.07.20 Tree loading-contract regression fix: publish the complete direct-child
    /// identity frame without ending the measurement owner. Names become visible immediately,
    /// while `treeChildrenInFlight` remains authoritative until exact subtree bytes/counts and
    /// the requested sort have committed. Clearing ownership here made the spinner disappear
    /// tens of seconds before `/Users` enrichment actually finished.
    private func publishTreeChildrenShallowFrame(
        path: String,
        cacheKey: String,
        token: UUID
    ) {
        guard treeChildrenTasks[cacheKey]?.token == token else { return }
        guard treeChildrenInFlight.contains(cacheKey) else { return }
        bumpChildrenCacheVersion(changedPath: path)
    }

    /// v2026.06.20 **目录 mtime 兜底缓存**。
    ///
    /// 背景：用户反馈"为什么有的地方修改时间就一直不显示"。
    /// 现状：BulkScanner 只对真正 yield 出的 `.node` 写入
    /// [DirAgg.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L189)；
    /// 但中间层目录（叶子上溯过程中累加的 ancestor）可能没有自己的 `.node` 事件，
    /// 这些 row 在后台内存 Tree 投影输出时 `modificationDate == nil`，UI 永远显示 `·`。
    ///
    /// 修复策略：directChildren 输出真实存在的"目录"行时，若 agg.modificationDate=nil，
    /// MainActor 只读缓存并把 miss 合并进一个有界后台批次。文件属性读取、字典扩容和
    /// 旧 COW 存储析构都由 worker 承担；generation/revision CAS 阻止旧扫描写回。
    /// **不命中磁盘的虚拟节点（如多根伪 root `(开发者构建产物)`）不会落到这里**——
    /// 它们走 [synthesizeMultiRootTopLevel](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1777)，
    /// path 不是真实文件系统路径，stat 失败时缓存 `.failure` 表示"问就是 nil"，
    /// 下次同样命中直接返回 nil 不再 stat（避免 4w 行 × 每帧重 stat）。
    ///
    /// 缓存 key 是绝对路径；生命周期与扫描会话绑定，[startScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 在切换 root 时一并 removeAll，避免跨扫描泄漏陈旧 mtime。
    private enum MtimeFallbackResult: Sendable {
        case found(Date)
        case failure
    }
    private var mtimeFallbackCache: [String: MtimeFallbackResult] = [:]

    /// MainActor 的唯一 mtime fallback 读取边界。cache miss 必须返回 nil；这里禁止任何
    /// FileManager/lstat 调用，避免 Tree 重建或选择回调把元数据延迟带进 UI executor。
    private func cachedDirMtimeFallback(forPath path: String) -> Date? {
        if let cached = mtimeFallbackCache[path] {
            switch cached {
            case .found(let d): return d
            case .failure:      return nil
            }
        }
        return nil
    }

    /// Pure bounded filesystem producer for mtime fallback. Cache mutation and TreeRow sorting are
    /// intentionally absent so primary settlement can await this Task without waiting for any
    /// presentation work.
    nonisolated private static func measureMtimeFallbackFilesystem(
        paths: [String]
    ) -> [String: MtimeFallbackResult] {
        var measurements: [String: MtimeFallbackResult] = [:]
        measurements.reserveCapacity(paths.count)
        for path in paths {
            guard !Task.isCancelled else { break }
            // Product TCC policy runs before the first physical metadata touch.
            guard !TCCSkipList.shouldSkip(path) else {
                measurements[path] = .failure
                continue
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                if let date = attrs[.modificationDate] as? Date {
                    measurements[path] = .found(date)
                } else {
                    measurements[path] = .failure
                }
            } catch {
                // Typed best effort: scan completeness evidence remains authoritative; caching a
                // failure only prevents repeated UI-triggered stat attempts.
                measurements[path] = .failure
            }
        }
        return measurements
    }

    /// Coalesces cache misses into one producer. At most one Task exists and the pending set is
    /// capped; a later Tree rebuild naturally offers paths that did not fit the current window.
    /// This preserves eventual mtime projection without spawning one task per SwiftUI row.
    @discardableResult
    private func enqueueMtimeFallbackProbes<S: Sequence>(_ paths: S) -> Bool
    where S.Element == String {
        guard !isPrimaryScanSettling else { return false }
        var acceptedAll = true
        for path in paths {
            guard mtimeFallbackCache[path] == nil else { continue }
            guard !mtimeFallbackPendingPaths.contains(path) else { continue }
            guard mtimeFallbackPendingPaths.count < Self.mtimeFallbackPendingLimit else {
                acceptedAll = false
                break
            }
            mtimeFallbackPendingPaths.insert(path)
            let parent = String._gsyParentPath(of: path)
            mtimeFallbackPendingParentCounts[parent, default: 0] &+= 1
        }
        guard !mtimeFallbackPendingPaths.isEmpty,
              mtimeFallbackProbeTask == nil
        else { return acceptedAll }

        let token = UUID()
        let generation = treeFetchGeneration
        mtimeFallbackProbeToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainMtimeFallbackProbes(
                expectedGeneration: generation,
                token: token
            )
        }
        mtimeFallbackProbeTask = task
        return acceptedAll
    }

    private enum MtimeFallbackCommitResult {
        case committed
        case retry
        case obsolete
    }

    private func drainMtimeFallbackProbes(
        expectedGeneration: UUID,
        token: UUID
    ) async {
        probeLoop: while !Task.isCancelled,
              treeFetchGeneration == expectedGeneration,
              mtimeFallbackProbeToken == token {
            let batch = Array(
                mtimeFallbackPendingPaths.prefix(Self.mtimeFallbackBatchSize)
            )
            guard !batch.isEmpty else { break }
            switch await prepareAndCommitMtimeFallbackBatch(
                batch,
                expectedGeneration: expectedGeneration,
                expectedToken: token
            ) {
            case .committed:
                for path in batch {
                    guard mtimeFallbackPendingPaths.remove(path) != nil else { continue }
                    let parent = String._gsyParentPath(of: path)
                    let remaining = max(
                        0,
                        (mtimeFallbackPendingParentCounts[parent] ?? 1) - 1
                    )
                    if remaining == 0 {
                        mtimeFallbackPendingParentCounts.removeValue(forKey: parent)
                    } else {
                        mtimeFallbackPendingParentCounts[parent] = remaining
                    }
                }
                resumeOneMtimeContinuationIfReady()
            case .retry:
                await Task.yield()
                continue
            case .obsolete:
                break probeLoop
            }
            await Task.yield()
        }
        guard mtimeFallbackProbeToken == token else { return }
        mtimeFallbackProbeTask = nil
        mtimeFallbackProbeToken = nil
    }

    /// A memory projection exposes at most one bounded metadata window. Once every path for a
    /// parent in that window settles, start one new index projection; it skips cached dates and
    /// offers the next window. Only one ready continuation is admitted per mtime batch, avoiding
    /// an unbounded task fan-out when many parents are expanded together.
    private func resumeOneMtimeContinuationIfReady() {
        guard !isScanning, !isPrimaryScanSettling else { return }
        while let parent = mtimeFallbackContinuationParents.first(where: {
            mtimeFallbackPendingParentCounts[$0] == nil
                && !hasInFlightTreeChildren(path: $0)
        }) {
            guard let kids = childEdges[parent] else {
                mtimeFallbackContinuationParents.remove(parent)
                continue
            }
            startMemoryTreeProjection(
                path: parent,
                kids: kids,
                sortedBy: .mtimeDesc
            )
            return
        }
    }

    private func prepareAndCommitMtimeFallbackBatch(
        _ paths: [String],
        expectedGeneration: UUID,
        expectedToken: UUID?,
        beforeCommitForTesting: (@MainActor () -> Void)? = nil
    ) async -> MtimeFallbackCommitResult {
        let sourceRevision = pruneSourceRevision
        let locale = presentationLocale
        let filesystemToken = UUID()
        let filesystemStarted = DispatchTime.now().uptimeNanoseconds
        let filesystemTask = Task.detached(priority: .utility) {
            Self.measureMtimeFallbackFilesystem(paths: paths)
        }
        mtimeFallbackFilesystemTaskState = MtimeFallbackFilesystemTaskState(
            token: filesystemToken,
            paths: paths,
            task: filesystemTask
        )
        GSYLog.info(
            .flow,
            "tree.mtime_probe.fs.start token=\(filesystemToken) paths=\(paths.count)"
        )
        let measurements = await withTaskCancellationHandler {
            await filesystemTask.value
        } onCancel: {
            filesystemTask.cancel()
        }
        if mtimeFallbackFilesystemTaskState?.token == filesystemToken {
            mtimeFallbackFilesystemTaskState = nil
        }
        let filesystemElapsedMs = Double(
            DispatchTime.now().uptimeNanoseconds - filesystemStarted
        ) / 1_000_000
        GSYLog.info(
            .flow,
            "tree.mtime_probe.fs.finish token=\(filesystemToken) paths=\(paths.count) "
                + "measured=\(measurements.count) cancelled=\(Task.isCancelled) "
                + "elapsed_ms=\(String(format: "%.2f", filesystemElapsedMs))"
        )
        guard !Task.isCancelled,
              treeFetchGeneration == expectedGeneration,
              expectedToken.map({ mtimeFallbackProbeToken == $0 }) ?? true
        else { return .obsolete }

        let worker = MtimeFallbackPresentationWorker(
            cache: mtimeFallbackCache,
            treeCache: treeChildrenCache,
            paths: paths,
            measurements: measurements,
            locale: locale
        )
        var prepared = await worker.prepare()
        beforeCommitForTesting?()

        guard !Task.isCancelled,
              treeFetchGeneration == expectedGeneration,
              expectedToken.map({ mtimeFallbackProbeToken == $0 }) ?? true
        else {
            prepared = nil
            await retireMtimeFallbackWorkerAndRecord(worker)
            return .obsolete
        }
        guard sourceRevision == pruneSourceRevision,
              locale.identifier == presentationLocale.identifier
        else {
            prepared = nil
            await retireMtimeFallbackWorkerAndRecord(worker)
            return .retry
        }
        guard let prepared else {
            await retireMtimeFallbackWorkerAndRecord(worker)
            return .obsolete
        }

        // The complete dictionary is already built off-main. Keep the worker alive through the
        // synchronous publish turn so replacing a wide cache cannot make MainActor its last owner.
        mtimeFallbackCache = prepared.cache
        treeChildrenCache = prepared.treeCache
        lastMtimePreparationRanOnMainThread = prepared.ranOnMainThread
        lastMtimeTreeSortCount = prepared.treeSortCount
        bumpChildrenCacheVersion()
        scheduleMtimeFallbackRetirement(worker)
        return .committed
    }

    private func scheduleMtimeFallbackRetirement(
        _ worker: MtimeFallbackPresentationWorker
    ) {
        Task { @MainActor [weak self] in
            await Task.yield()
            let diagnostics = await worker.retire()
            self?.lastMtimeRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastMtimeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private func retireMtimeFallbackWorkerAndRecord(
        _ worker: MtimeFallbackPresentationWorker
    ) async {
        let diagnostics = await worker.retire()
        lastMtimeRetirementRanOnMainThread = diagnostics.ranOnMainThread
        lastMtimeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
    }

    /// **Step 9a / 2026-06**：cache 写入版本号统一推进入口。
    /// 所有改 [treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的位置（写新键 / 删旧键 / removeAll / patch-by-prune）必须串到这里。
    /// 用 `&+=` 让计数器溢出时回卷而非 trap；订阅者只关心"变没变"，绝对值无意义。
    @inline(__always)
    private func bumpChildrenCacheVersion(
        changedPath: String? = nil,
        advanceSourceRevision: Bool = true
    ) {
        // v2026.07.19 Tree one-click regression closure: the cache mutation revision is part of
        // the state being published. `@Published` delivers synchronously, so advancing this after
        // `treeBrowser.bumpChildrenCacheVersion` let the subscriber freeze revision R and then
        // immediately changed the coordinator to R+1. Every async projection spawned by that
        // notification therefore failed its CAS, and the next click was required to reveal the
        // previous directory. Commit the complete source identity before emitting the version;
        // never weaken the stale-projection guard.
        if advanceSourceRevision {
            notePruneSourceMutation()
        }
        childrenCacheVersion &+= 1
        treeBrowser.bumpChildrenCacheVersion(changedPath: changedPath)
    }

    /// v1.5.4：树形视图扁平化重算的"统一脏标"。
    /// [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 把 visibleRows 从 computed 改为 `@State flatRows: [FlatTreeRow]`（性能修复，
    /// 避免一次操作里 4 次重复递归整棵展开树），重建时机靠 `onChange(of: treeRevision)` 串。
    ///
    /// 所有可能改变"directChildren(of:_) 输出"的入口必须 `treeRevision &+= 1`：
    /// 1. [publishSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1873)（流式 ingest tick / finished 收尾）
    /// 2. `treeChildrenCache` 主线程写回（按需子树扫描完成）
    /// 3. [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1174)（删除成功后的状态同步）
    /// 4. 启动新扫描 / cancel 后的 cache 清空
    /// 5. [invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1147)（扫描结束清 cache）
    ///
    /// 用 `&+=` 让计数器溢出时自然回卷而非 trap；view 端只关心"变没变"，绝对值无意义。
    ///
    /// v2026.06.21 perf：**移除 @Published**。
    /// 旧设计让 4 个 revision 都是 @Published mirror，导致 ScanCoordinator 任一 bump
    /// 都让 MainView body / sidebar / footer 全失效（dev 扫每秒 ≥5 次 body 重算 = 卡顿核心）。
    /// 现在 view 端走 `coordinator.treeBrowser.*`（独立 ObservableObject）订阅；
    /// 本字段保留为普通 `public private(set) var` 仅供单测 / 外部代码直接读数。
    public private(set) var treeRevision: UInt64 = 0

    /// Step 2 P0-2 / 2026-06：treeRevision 拆分 —— 结构性脏标。
    /// 含义：节点新增 / 节点删除 / 排序键变化 / cache 整轮失效。订阅这条信号的 view
    /// **必须**重建 flatRows（一次 O(N) 拍平 + verdict 计算）。
    ///
    /// 与 `tickRevision` 的边界由 [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) /
    /// [bumpTickRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 两个 helper 单点收敛 —— 任何代码不再直接写
    /// `treeRevision &+= 1`，避免漏判类别。
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var structuralRevision: UInt64 = 0

    /// v1.5.7：结构变化的 hint —— "本次 structuralRevision 升的根因是这些 path 被删了"。
    /// 仅在 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1422-L1542)
    /// 路径上写一次，订阅方需在 onChange(structuralRevision) 同步段内调
    /// [consumeLastPrunedPaths()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 一次性取走（取后立刻置 nil），避免下次 unrelated bump 误用。
    /// TreeBrowserView 在 hint 非 nil 时走"只剔被删 path 子树"的增量 patch，
    /// 避免对万级目录整树 rebuild。
    private var lastPrunedPaths: [String]? = nil

    /// 删除成功后的本轮扫描 tombstone。扫描事件和异步树缓存可能在删除完成后
    /// 继续回调；这些路径必须在当前扫描会话内持续屏蔽，直到下一次新扫描从文件系统
    /// 真实状态重新建立数据源。
    /// 不可变删除路径索引。父子最小化、排序与 Set rehash 全部由 prune worker 在
    /// generic executor 完成；MainActor 只替换这一条引用。查询沿候选祖先链命中 Set，
    /// 不再随 tombstone root 数量线性退化。
    private enum AllocationCatalog: Sendable {
        case producer(InodeSet)
        case committed(FileAllocationSnapshot)
        func snapshot() -> FileAllocationSnapshot {
            switch self {
            case .producer(let ledger): return ledger.allocationSnapshot()
            case .committed(let value): return value
            }
        }
    }
    private var allocationCatalog: AllocationCatalog?
    private var scanResultRoots: [String] = []
    /// v2026.10.09: refresh/Undo belong to the original producer's enumeration scope. Keep
    /// the complete value with its catalog; changing UI settings cannot widen an old result.
    private var retainedScanOptions: ScanOptions = .default
    private var allocationRebaseline: (@MainActor () -> Void)?

    /// v2026.10.08 Undo review: discovery rows are semantic candidates, not a root's children.
    /// Restore must re-run their original producer (retention/rules/options) through admission.
    /// The root inventory survives pruning and recovery scans so consecutive receipts still match.
    private enum DiscoveryScanPlan: Sendable {
        case versionedRoots(home: URL)
        case commonAppCaches(includeConfirm: Bool, options: CommonAppCacheScanner.Options?)

        var forcesLeafPresentation: Bool {
            if case .versionedRoots = self { return true }
            return false
        }
    }
    private struct DiscoveryScanState: Sendable {
        let plan: DiscoveryScanPlan
        let candidateRoots: [String]
    }
    // Candidate entries are not enumeration roots: explicit subtree refresh must keep them
    // as semantic rows instead of replacing them with the measured directory's children.
    private var discoveryScanState: DiscoveryScanState?

    private var deletedPathTombstones = DeletedPathIndex.empty

    /// 后台 prune transaction 的扫描会话代际。任何 cancel / 新扫描都会刷新，
    /// 因而旧会话基于 COW 快照算出的 plan 永远不能覆盖新扫描状态。
    private var pruneStateGeneration = UUID()

    /// prune 读取的数据源 revision。扫描 ingest、节流发布、树缓存写回以及另一个
    /// prune commit 都会推进它；后台 plan 回来时 revision 不一致就重新取快照计算。
    /// 这条计数器不参与 UI 发布，只是 transaction 的 compare-and-swap 版本号。
    private var pruneSourceRevision: UInt64 = 0

    /// 后台 prune plan 计算期间的短事务栅栏。扫描事件在写入索引前会协作式让出，
    /// 避免 planner 基于 COW 快照计算时又不断产生新写入而饥饿重试；UI 主线程本身
    /// 不被阻塞，仍可正常渲染与处理手势。
    private var activePruneTransactionCount = 0

    /// 仅供聚焦测试确认 production planner 的真实执行线程与耗时；不参与 UI。
    private var lastPrunePlanRanOnMainThread: Bool?
    private var lastPrunePlanDurationNanoseconds: UInt64?
    private var lastPruneTreeCacheContributionIndexBuilt: Bool?
    private var lastPruneTombstoneMergeRanOnMainThread: Bool?
    private var lastPruneRetirementRanOnMainThread: Bool?
    private var lastPruneRetirementDurationNanoseconds: UInt64?
    private var latestPruneDiagnosticsTransactionID: UUID?
    /// Successful prune commits are already authoritative. Serialize their old-generation ARC
    /// retirement off the result path so repeated cleanups cannot create an unbounded release fanout.
    private var pruneRetirementTail: Task<Void, Never>?

    /// Terminal projection materialization can be proportional to the number of visible roots.
    /// This diagnostic is test-only evidence that the production worker stayed off MainActor.
    private var lastTerminalPreparationRanOnMainThread: Bool?
    private var lastTerminalRetirementRanOnMainThread: Bool?
    private var lastTerminalRetirementDurationNanoseconds: UInt64?
    private var lastTreePreparationRanOnMainThread: Bool?
    private var lastTreePreparationAttemptCount: Int = 0
    private var lastTreeRetirementRanOnMainThread: Bool?
    private var lastTreeRetirementDurationNanoseconds: UInt64?
    /// Test-visible evidence for the synchronous disclosure boundary. The complete fan-out may be
    /// arbitrarily wide, but MainActor is allowed to inspect/materialize only the fixed preview
    /// window before handing the authoritative projection to `MemoryTreePresentationWorker`.
    private var lastIndexedTreePreviewFanOut: Int = 0
    private var lastIndexedTreePreviewInspectedCount: Int = 0
    private var lastIndexedTreePreviewMaterializedCount: Int = 0
    private var indexedTreePreviewBuildCount: UInt64 = 0
    private var lastSubtreeRescanPreparationRanOnMainThread: Bool?
    private var lastSubtreeRescanRetirementRanOnMainThread: Bool?
    private var lastSubtreeRescanRetirementDurationNanoseconds: UInt64?
    private var lastSubtreeRescanAttemptCount: Int = 0
    private var lastSessionRetirementRanOnMainThread: Bool?
    private var lastSessionRetirementDurationNanoseconds: UInt64?
    private var lastPerRootPreparationRanOnMainThread: Bool?
    private var lastMtimePreparationRanOnMainThread: Bool?
    private var lastMtimeRetirementRanOnMainThread: Bool?
    private var lastMtimeRetirementDurationNanoseconds: UInt64?
    private var lastMtimeTreeSortCount: Int?

    /// 一次性消费 v1.5.7 prune hint：取走当前值并立刻清 nil。
    /// 设计目的：避免 TreeBrowserView onChange 闭包跨 runloop tick 读到陈旧值。
    public func consumeLastPrunedPaths() -> [String]? {
        let v = lastPrunedPaths
        lastPrunedPaths = nil
        return v
    }

    private func isDeletedTombstoned(_ candidate: String) -> Bool {
        deletedPathTombstones.matcher.contains(candidate)
    }

    /// 每个扫描入口统一调用的删除会话重置。旧索引通过 detached task 保留到后台，
    /// 避免大型 roots/Set 的最后一次释放落在 MainActor。
    private actor AllocationCatalogRetirementWorker {
        private var value: AllocationCatalog?
        init(_ value: AllocationCatalog?) { self.value = value }
        func snapshot() -> FileAllocationSnapshot? { value?.snapshot() }
        func retire() { value = nil }
    }

    private func beginAllocationCatalog(roots: [String], options: ScanOptions) -> InodeSet {
        let ledger = InodeSet(tracksPaths: true)
        allocationCatalog = .producer(ledger)
        scanResultRoots = roots
        retainedScanOptions = options
        return ledger
    }

    private func freezeAllocationCatalog(expectedGeneration: UUID) async {
        guard scanGeneration == expectedGeneration, case .producer = allocationCatalog else { return }
        let worker = AllocationCatalogRetirementWorker(allocationCatalog)
        let frozen = await worker.snapshot()
        if scanGeneration == expectedGeneration, let frozen {
            allocationCatalog = .committed(frozen)
        }
        await worker.retire()
    }

    private func retireAllocationCatalog() {
        let worker = AllocationCatalogRetirementWorker(allocationCatalog)
        allocationCatalog = nil
        scanResultRoots = []
        retainedScanOptions = .default
        Task { @MainActor in
            await Task.yield()
            await worker.retire()
        }
    }

    private func resetDeletionStateForNewScanSession() {
        retireAllocationCatalog()
        allocationRebaseline = nil
        discoveryScanState = nil
        treeBrowser.resetDeletionPresentation()
        guard !deletedPathTombstones.matcher.roots.isEmpty else { return }
        // retirementWorker 在 swap 前先取得强引用；即使 MainActor 当前栈随即结束，旧
        // matcher 也不会成为本地变量的最后引用。下一 MainActor turn 再让 worker actor
        // 于 generic executor 清空，形成可证明的 ownership handoff。
        let retirementWorker = DeletedPathRetirementWorker(index: deletedPathTombstones)
        deletedPathTombstones = .empty
        Task { @MainActor in
            await Task.yield()
            await retirementWorker.retire()
        }
    }

    @inline(__always)
    private func notePruneSourceMutation() {
        pruneSourceRevision &+= 1
    }

    /// 扫描消费者在每个事件写入前经过该协作式栅栏。prune 的 O(N) 工作在 detached
    /// executor 上执行，这里只 yield，不占用 MainActor 帧预算。
    private func waitForPruneTransactionBarrier() async -> Bool {
        while activePruneTransactionCount > 0 {
            if Task.isCancelled { return false }
            await Task.yield()
        }
        return !Task.isCancelled
    }

    /// Step 2 P0-2 / 2026-06：treeRevision 拆分 —— 数值脏标（非结构性）。
    /// 含义：已有节点的 bytes / fileCount / isActive 变了，**节点拓扑没变**。订阅这条
    /// 信号的 view **不需要**重建 flatRows，只需让 RowView 内部读最新 bucket（通过其它
    /// @Published 入口，这里仅作"我又跳了一次"的通知）。
    ///
    /// publishSnapshot 流式 tick（0.4s/帧）只推这条；当帧检测到 `(buckets.count,
    /// dirIndex.count, fileLeaves.count)` 三元组变化时，由 helper 兜底升格为 structural。
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var tickRevision: UInt64 = 0

    /// 上一帧 publishSnapshot 时三个核心索引的 (count, count, count) 快照，用于 O(1)
    /// 判定"本帧是否新增节点"——任一计数变化即视为结构变化。
    private var lastIndexSnapshot: (buckets: Int, dirIndex: Int, fileLeaves: Int) = (0, 0, 0)

    /// 单点收敛：推进结构脏标。
    /// 同时推 `treeRevision`（兼容外部已订阅 treeRevision 的代码）和 `structuralRevision`。
    /// `tickRevision` 也顺带 +1 —— 任何 structural 都隐含一次 tick（一致性保证）。
    private func bumpStructuralRevision(advanceSourceRevision: Bool = true) {
        // v2026.10.08: all Tree signals must publish the committed source identity. Like the
        // children-cache boundary, synchronous @Published subscribers freeze their source here;
        // advancing it afterwards rejects the last refresh after a successful recycle forever.
        // When paired immediately after `bumpChildrenCacheVersion()`, pass `advanceSourceRevision: false`
        // so `pruneSourceRevision` is not advanced a second time after `childrenCacheVersion` has
        // already notified synchronous subscribers.
        if advanceSourceRevision {
            notePruneSourceMutation()
        }
        structuralRevision &+= 1
        tickRevision &+= 1
        treeRevision &+= 1
        treeBrowser.bumpStructuralRevision()
    }

    /// 单点收敛：推进数值脏标。
    /// 仅在确认"节点拓扑没变（仅 buckets[k].bytes 累加之类）"时调用。
    ///
    /// v1.5 P2 滑动卡顿修复：
    /// 此前为了"兼容订阅者不死寂"也把 `treeRevision` 一起推 —— 但 `treeRevision` 是
    /// TreeBrowserView 的"结构变化"信号，每帧 +1 等于强制 TreeBrowserView rebuildFlatRows()
    /// + 整个主列表所有 RowView body 重算，是滑动期主帧丢的第二大头（review-swarm 命中 #5）。
    /// 现在只 tick 数值通道（`tickRevision` + `treeBrowser.bumpTickRevision()`），
    /// 树形视图按"显式 structural"通道感知拓扑变化，纯 bytes 累加不再打扰它。
    private func bumpTickRevision() {
        // Same publication contract as structural/cache changes; never invalidate our own signal.
        notePruneSourceMutation()
        tickRevision &+= 1
        // v2026.06.21 perf：保持与 [TreeBrowserStore.bumpTickRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L67-L70)
        // 完全对齐（store 端 tick 也会推 treeRevision 作老订阅者兼容），
        // 否则 [TreeBrowserStoreTests.test_扫描期间coord的mirror与store同步](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/TreeBrowserStoreTests.swift#L96-L99)
        // 会判 coord.treeRevision 落后 store.treeRevision 一个 tick。
        treeRevision &+= 1
        treeBrowser.bumpTickRevision()
    }

    /// Step 3 P0-3 / 2026-06：bucket cachedVerdict 命中率计数器。
    /// publishSnapshot 走 cache 路径时，`miss = 首次计算并写回`，`hit = 直接读现有值`。
    /// 仅作运行期遥测与测试观察用，**不参与 @Published**（不触发 view 更新）。
    private var verdictCacheHits: Int = 0
    private var verdictCacheMisses: Int = 0

    /// v1.5 P1-C：publishSnapshot 流式帧"排序结果"缓存。
    /// 不变量：扫描中 ingest 只 add 不 remove bucket（buckets.count 单调增），
    /// 同时白名单 whitelistSnapshot 在帧间一般不变 ——
    /// 所以当 `(buckets.count, whitelistSnapshot.count)` 与上一帧相同时，
    /// 流式帧（finished=false）的 sorted id 序（path 字典序）必然与上一帧完全一致，
    /// 可直接复用，跳过 O(N log N) 排序。
    /// finished=true 帧走用户 sort，不参与缓存。
    private var lastStreamSortedIds: [String] = []
    private var lastStreamSortCacheKey: (bucketCount: Int, whitelistCount: Int) = (-1, -1)

    /// 测试观察口：暴露 verdict cache 命中统计。
    /// 仅 internal —— 同 module 的测试代码可读；外部 framework 不可见。
    /// 用于 [BucketVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/BucketVerdictCacheTests.swift) 验证 P0-3 缓存生效。
    func verdictCacheStatsForTesting() -> (hits: Int, misses: Int) {
        (verdictCacheHits, verdictCacheMisses)
    }

    /// 测试触发口：在已扫完的状态下手动再触发一次 publishSnapshot。
    /// 用途：fake home fixture 太小时，扫描可能只跑一帧 publishSnapshot（150ms 节流没触发流式帧），
    /// 测试看不到 cache hit。该方法让 [BucketVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/BucketVerdictCacheTests.swift) 能在确定的 buckets 状态下
    /// 再调一次 publishSnapshot 验证"第二次访问 = cache hit"。生产路径不调它。
    func forcePublishSnapshotForTesting(categoryID: String = "_test_") {
        publishSnapshot(categoryID: categoryID, finished: false)
    }

    /// Regression probe for the production `.topLevel` progress boundary. It intentionally uses
    /// the same narrow publisher as `runScan` without constructing a filesystem producer.
    func _publishLiveProgressForTesting(
        categoryID: String = "_test_live_",
        totalBytes: Int64,
        scannedFiles: Int
    ) {
        if startedAt == .distantPast { startedAt = Date() }
        self.totalBytes = totalBytes
        self.scannedFiles = scannedFiles
        publishLiveProgress(categoryID: categoryID)
    }

    /// UI 专用的工作计时口径。
    ///
    /// `snapshot.elapsed` 只会在扫描数据发布时更新；勘察、聚合、一次性规则扫描等阶段可能
    /// 长时间没有新 snapshot，若 UI 直接读它就会出现“有些入口计时动、有些入口停在 0”的错觉。
    /// 这里把“工作计时”从“扫描结果发布”里解耦：扫描中按会话起点实时计算，结束后回到最终快照。
    public func elapsedForDisplay(referenceDate: Date = Date()) -> TimeInterval {
        guard isScanning, startedAt > .distantPast else {
            return max(0, snapshot.elapsed)
        }
        return max(0, max(snapshot.elapsed, referenceDate.timeIntervalSince(startedAt)))
    }

    /// v1.0 T4：大文件叶子集合。
    /// 仅当 `largeFileMinBytes > 0` 时才会被填充（避免普通扫描浪费内存）。
    /// 每条记录原样保留 path / bytes / mtime，让 `largeFiles(...)` 能按多种 sortKey
    /// 自由切换排序，**无需重扫**。
    public struct LargeFileLeaf: Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let logicalBytes: Int64
        public let modificationDate: Date?

        public init(path: String,
                    bytes: Int64,
                    logicalBytes: Int64? = nil,
                    modificationDate: Date?) {
            self.path = path
            self.bytes = bytes
            self.logicalBytes = logicalBytes ?? bytes
            self.modificationDate = modificationDate
        }
    }
    private var largeFileLeaves: LargeFileLeafTopNHeap = LargeFileLeafTopNHeap(capacity: ScanCoordinator.largeFileTopNCapacity)
    /// **Step 9c / 2026-06**：Top-N 容量上限（绝对硬顶）。
    /// 选 1000：
    ///   - LargeFilesView 本就只渲染 limit=200，N=1000 留 5×缓冲量给排序切换。
    ///   - 内存：1000 × ~64B（path/bytes/mtime）= ~64KB，常驻可忽略。
    ///   - 插入复杂度：O(log 1000) ≈ 10 次比较，远小于原"无脑 append + 末尾 N log N 排序"。
    public static let largeFileTopNCapacity: Int = 1000
    /// compactAfterScanPreservingCache 之后的"二级缓存"。
    /// 把 Top N 大文件保留到这，UI 重进大文件页时仍可同步渲染——
    /// 既享受了主索引被释放的内存收益，又不让 UI 出现空白回退。
    /// `nil` 表示尚未 compact 或主路径仍可用；非 nil 表示 largeFileLeaves 已清空，UI 应读这里。
    private var compactedLargeFileTopN: [LargeFileLeaf]?
    /// 当前扫描会话中"采集大文件的下限"。0 表示不采集。
    private var largeFileMinBytes: Int64 = 0
    /// 大文件入口只需要文件级 Top-N，不需要主列表 bucket / 树形索引 / Safety verdict 行。
    /// 保持这个边界能避免百万级文件扫描把 MainActor 拖进通用结果树构建。
    private var largeFileTopNOnlyScan: Bool = false

    private var totalBytes: Int64 = 0
    private var scannedFiles: Int = 0
    /// v2026.07.16 性能合同诊断：生产默认/推荐/Large Files 投影链路必须保持 0。
    /// 非零表示某入口意外退回 complete stream，把逐 inode DTO 重新送上 MainActor。
    private var incrementalNodeDeliveryCount: Int = 0
    private var startedAt: Date = .distantPast

    /// v1.3：扫描吞吐 EWMA 速率（bytes/s）。在 publishSnapshot 时基于
    /// (totalBytes - lastSampleBytes) / (now - lastSampleAt) 增量采样并 EWMA 平滑：
    ///   rate' = α × instant + (1-α) × rate，α = 0.3 让短期跳变不至于把数字拉飞，
    ///   也让长期趋势能跟得上。
    private var bytesPerSecondEMA: Double = 0
    private var lastSampleAt: Date?
    private var lastSampleBytes: Int64 = 0

    /// 可信进度分母。v2026.07.16 起仅整盘扫描复用已经存在的卷容量快照；
    /// 推荐/自定义/Large Files 不再为了一个不可靠 ETA 重复遍历同一棵树。
    /// nil 表示没有可信分母，UI 只展示已扫文件、容量和已用时间。
    @Published public private(set) var expectedTotalBytes: Int64? = nil

    /// 清理页主值固定使用 macOS 的 on-disk allocated size。
    ///
    /// 这是 System Settings「储存空间」以及 `du` 的清理语义；不能让用户把整页切到
    /// sparse 文件的虚拟长度，否则 Docker.raw 会再次显示出超过磁盘容量的“可清理”总量。
    /// `logicalSize` 仍随 RowItem 保留，只在详情中像 Finder「显示简介」一样作为副值展示。
    @inline(__always)
    private func displayBytes(of node: FSNode) -> Int64 {
        node.allocatedSize
    }

    /// v1.3.z 性能开关：是否在 ingest 时构建多层下钻索引（dirIndex / childEdges / fileLeaves）。
    /// - true：扫描期就维护好整棵树索引，TreeBrowserView 进入即可同步渲染。
    ///   **代价**：大目录（70 GB / 72 万文件）下，主线程会被 576 万次祖先上溯字典写入压住 ~5 分钟。
    /// - false（v1.3.zz 起的默认）：跳过深索引维护；TreeBrowserView 通过后台按需扫描异步下钻
    ///   （首次 cache miss → 后台 Task 扫当前目录 → 回填 cache → SwiftUI 重新渲染）。
    /// 切换不影响：buckets（主列表）、totalBytes、scannedFiles、largeFileLeaves。
    /// Product coordinators use the default `false`. The non-default initializer exists only for
    /// deterministic index/benchmark fixtures; external runtime code cannot turn it back on after
    /// a full-disk or developer admission has selected the on-demand Tree contract.
    public private(set) var enableTreeDeepIndex: Bool = false

    /// One disclosure frame needs only enough rows to fill the visible viewport. Capping the
    /// synchronous preview at 64 keeps the getter independent of directory fan-out while still
    /// avoiding the empty/long-loading regression. The worker publishes the complete sorted set.
    ///
    /// v2026.07.19 regression reason: the previous "immediate first frame" fix rebuilt and sorted
    /// every `childEdges[parent]` entry on MainActor. A high fan-out directory therefore restored
    /// the exact rainbow-cursor class that Tree workers were introduced to remove.
    nonisolated static let indexedTreeFirstFramePreviewCapacity = 64
    nonisolated private static let indexedTreeFirstFrameInspectionCapacity =
        indexedTreeFirstFramePreviewCapacity * 2

    /// Product scan admission that must never retain the optional complete in-memory deep index.
    /// Both cases can contain millions of descendants; their Tree contract is a complete shallow
    /// direct-child terminal followed by non-UI-blocking deep enrichment.
    private enum OnDemandTreeProductEntry: String, Sendable {
        case fullDisk = "full_disk"
        case developerArtifacts = "developer_artifacts"
    }

    private func enforceOnDemandTreeProductEntry(_ entry: OnDemandTreeProductEntry) {
        guard enableTreeDeepIndex else { return }
        GSYLog.info(
            .scan,
            "tree.index.product_admission entry=\(entry.rawValue) "
                + "deep_index_before=true deep_index_after=false"
        )
        enableTreeDeepIndex = false
    }

    /// Step 10a / 2026-06：系统探针 SSOT。
    /// fdaStatus / volumeSnapshot / swapSnapshot 三个字段的写入路径全部经此 store；
    /// ScanCoordinator 自身保留 @Published mirror（向后兼容）。
    public let systemProbe: SystemProbeStore

    /// Step 10b / 2026-06：树形浏览状态 SSOT 接口外壳。
    /// 让新代码 / 单测可以单独订阅 `coordinator.treeBrowser.structuralRevision` 等，
    /// 不再依赖整个 ScanCoordinator.objectWillChange。
    /// ScanCoordinator 自身保留对应字段作 @Published mirror（向后兼容）；
    /// bumpStructuralRevision / bumpTickRevision / bumpChildrenCacheVersion
    /// 三个 helper 内部双写到 store 与 mirror 保证一致。
    public let treeBrowser: TreeBrowserStore
    /// v2026.07.20 performance boundary: live counters notify only status/HUD consumers. Never
    /// wrap this in `@Published`; doing so would reconnect the same broad MainView invalidation.
    public let liveProgress: ScanLiveProgressStore
    private static let fullDiskDataRootPath = Firmlinks.recommendedDataVolumeRoot.path
    private let fullDiskPathNamespace: ScanPathNamespace
    private var undoRestoreCancellable: AnyCancellable?
    private var undoReconciliationTask: Task<Void, Never>?

    public init(vendors: [VendorRule] = [], home: String = NSHomeDirectory(),
                enableTreeDeepIndex: Bool = false,
                whitelistStore: WhitelistStore = .shared,
                commonAppCacheExecution: CommonAppCacheExecutionMode = .inProcess,
                primaryScanAdmissionRegistry: PrimaryScanAdmissionRegistry = PrimaryScanAdmissionRegistry(),
                primaryScanAdmissionClientID: PrimaryScanAdmissionRegistry.ClientID = .init(),
                systemProbeStore: SystemProbeStore? = nil) {
        let initialScanGeneration = UUID()
        self.scanGeneration = initialScanGeneration
        self.publishedScanSessionID = initialScanGeneration
        self.primaryScanAdmissionRegistry = primaryScanAdmissionRegistry
        self.primaryScanAdmissionClientID = primaryScanAdmissionClientID
        self.vendors = vendors
        self.home = home
        self.enableTreeDeepIndex = enableTreeDeepIndex
        self.whitelistStore = whitelistStore
        self.commonAppCacheExecution = commonAppCacheExecution
        self.fullDiskPathNamespace = Self.makeFullDiskPathNamespace()
        // 性能关键：vendors 在 init 时已确定，扫描期不会变。
        // 一次构建 trie 复用整个生命周期，避免 publishSnapshot 每帧 N 次重建。
        self.trie = VendorTrie.build(vendors: vendors, home: home)
        self.liveProgress = ScanLiveProgressStore()
        // Step 10a / 2026-06：抽 SystemProbeStore 持有 fdaStatus/volumeSnapshot/swapSnapshot。
        // store 的 init 内部就会探一次三个值。
        // v2026.09.06: additional workspace scan owners share the process probe. Creating
        // a result session must not duplicate synchronous probes or mount/active timers.
        let probe = systemProbeStore ?? SystemProbeStore(home: home)
        self.systemProbe = probe
        // Step 10b / 2026-06：抽 TreeBrowserStore 提供 cache / revision 的 SSOT 接口外壳。
        // ScanCoordinator 上同名字段保留作 @Published mirror（向后兼容）；
        // bump* helper 双写保证 store 与 mirror 一致。
        self.treeBrowser = TreeBrowserStore()
        // 向后兼容 mirror：保留 ScanCoordinator 上 @Published 字段供老 view / 老测试读取，
        // 写入唯一来源是 systemProbe。
        self.fdaStatus = probe.fdaStatus
        self.volumeSnapshot = probe.volumeSnapshot
        self.swapSnapshot = probe.swapSnapshot
        self.undoRestoreCancellable = NotificationCenter.default
            .publisher(for: .gsyUndoDidRestore)
            .sink { [weak self] notification in
                guard let paths = notification.userInfo?["paths"] as? [String],
                      !paths.isEmpty else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.enqueueRestoredPaths(paths) }
                } else {
                    Task { @MainActor [weak self] in self?.enqueueRestoredPaths(paths) }
                }
            }
    }

    private func enqueueRestoredPaths(_ paths: [String]) {
        let previous = undoReconciliationTask
        let session = publishedScanSessionID
        undoReconciliationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.publishedScanSessionID == session else { return }
            await self.reconcileRestoredPaths(paths)
        }
    }

    /// v2026.10.08: Undo is a filesystem mutation, not a cache invalidation. Re-measure
    /// affected parents through the same indexed transaction as explicit refresh. Discovery
    /// candidates instead replay their semantic producer through primary admission. Neither
    /// strategy may restore a discarded frame or unhide rows before authoritative measurement.
    public func reconcileRestoredPaths(_ rawPaths: [String]) async {
        // Root history survives pruning, but cancelled/cross-mode frames no longer own results.
        guard currentRootPath != nil else { return }
        let session = publishedScanSessionID
        let discoveryState = discoveryScanState
        let discoveryPlan = discoveryState?.plan
        let knownRoots = discoveryState?.candidateRoots ?? (scanResultRoots.isEmpty
            ? ([currentRootPath].compactMap { $0?.hasPrefix("/") == true ? $0 : nil }
                + Array(perRootStaging.keys) + Array(perRootFinishedSlim.keys))
            : scanResultRoots)
        let usesDiscoveryCandidates = discoveryPlan != nil
        let pathNamespace = treeScanPathNamespace
        let request = await Task.detached(priority: .userInitiated) {
            // Discovery roots are candidate entries. A conflict-renamed restore is their
            // sibling, so invalidate the candidate's parent domain, then re-run its rules.
            let scopeRoots = usesDiscoveryCandidates
                ? Array(Set(knownRoots.map { String._gsyParentPath(of: $0) }))
                : knownRoots
            let observed = Set(rawPaths.filter { $0.hasPrefix("/") }.map {
                let path = URL(fileURLWithPath: $0).standardizedFileURL.path
                return pathNamespace?.publicPath(forPhysicalPath: path) ?? path
            }).filter { path in
                // Undo can restore a broken symlink; fileExists follows its missing target.
                // The restored directory entry itself is the object we must reconcile.
                var metadata = stat()
                let physicalPath = pathNamespace?.physicalPath(forPublicPath: path) ?? path
                return physicalPath.withCString { lstat($0, &metadata) == 0 }
            }
            var restored = observed
            let namespaces = scopeRoots.map { root in
                let physicalRoot = pathNamespace?.physicalPath(forPublicPath: root) ?? root
                return ScanPathNamespace(
                    physicalRoot: URL(fileURLWithPath: physicalRoot).resolvingSymlinksInPath().standardizedFileURL.path,
                    publicRoot: root)
            }
            // v2026.10.08: Undo journals and directory enumeration can use different aliases
            // for the same root. Map into the retained scan namespace, without following the
            // restored final symlink (its directory entry, not its target, was restored).
            for path in observed {
                let entry = URL(fileURLWithPath: pathNamespace?.physicalPath(forPublicPath: path) ?? path)
                let resolvedEntry = entry.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(entry.lastPathComponent).standardizedFileURL.path
                for namespace in namespaces {
                    if Self.pathBelongsToSubtree(resolvedEntry, rootPath: namespace.physicalRoot) {
                        restored.insert(namespace.publicPath(forPhysicalPath: resolvedEntry))
                    } else if Self.pathBelongsToSubtree(namespace.physicalRoot, rootPath: resolvedEntry) {
                        restored.insert(namespace.publicRoot)
                    }
                }
            }
            var parents = Set<String>()
            for path in restored {
                for root in scopeRoots {
                    if Self.pathBelongsToSubtree(path, rootPath: root) {
                        parents.insert(path == root ? root : String._gsyParentPath(of: path))
                    } else if Self.pathBelongsToSubtree(root, rootPath: path) {
                        parents.insert(root)
                    }
                }
            }
            let scopes = parents.filter { candidate in
                !parents.contains { $0 != candidate && Self.pathBelongsToSubtree(candidate, rootPath: $0) }
            }.sorted()
            return (restored: Array(restored), scopes: scopes)
        }.value
        guard publishedScanSessionID == session, !request.scopes.isEmpty, !Task.isCancelled else { return }
        if let discoveryPlan {
            restartDiscoveryScan(discoveryPlan, reconciliationRoots: knownRoots)
            return
        }
        if isScanning || isPrimaryScanSettling {
            GSYLog.notice(.operation, "scan.cancel reason=filesystem_mutated_during_restore")
            cancel()
            refreshVolumeCapacity()
            return
        }
        for scope in request.scopes {
            guard publishedScanSessionID == session,
                  !isScanning,
                  !isPrimaryScanSettling,
                  !Task.isCancelled else { return }
            await rescanSubtreeTransaction(at: scope, beforeCommitForTesting: nil,
                                          restoredPaths: request.restored)
        }
        guard publishedScanSessionID == session else { return }
        refreshVolumeCapacity()
    }

    /// A new admitted session clears the old projection and tombstones together; only its
    /// authoritative discovery publishes replacement candidates. Never unhide stale rows first.
    private func restartDiscoveryScan(_ plan: DiscoveryScanPlan, reconciliationRoots: [String]) {
        switch plan {
        case .versionedRoots(let home):
            schedulePrimaryScanIntent(.versionedRoots) { [weak self] in
                self?.startKnownVersionedRootsScan(home: home, reconciliationRoots: reconciliationRoots)
            }
        case .commonAppCaches(let includeConfirm, let options):
            schedulePrimaryScanIntent(.commonAppCaches) { [weak self] in
                self?.startCommonAppCacheScan(includeConfirm: includeConfirm, scannerOptions: options,
                                             reconciliationRoots: reconciliationRoots)
            }
        }
    }

    internal func _waitForUndoReconciliationForTesting() async {
        await undoReconciliationTask?.value
    }

    /// v1.3：用户从系统设置回到 App 后调用，重探 FDA 状态与卷容量。
    /// 推荐绑定到 `.onAppear` 与"打开系统设置"按钮的 `NSApplication.didBecomeActive` 回调。
    /// Step 10a / 2026-06：写入唯一来源 [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L474-L474)，
    /// 之后同步回 mirror 字段。
    public func refreshFDAStatus() {
        systemProbe.refreshFDAStatus()
        fdaStatus = systemProbe.fdaStatus
        volumeSnapshot = systemProbe.volumeSnapshot
        swapSnapshot = systemProbe.swapSnapshot
    }

    /// v1.3：每次扫描完成 / 删除完成后调用，重探卷容量（FDA 不变就不动）。
    /// Step 10a / 2026-06：写入唯一来源 [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L474-L474)，
    /// 之后同步回 mirror 字段。
    public func refreshVolumeCapacity() {
        systemProbe.refreshVolumeCapacity()
        volumeSnapshot = systemProbe.volumeSnapshot
        swapSnapshot = systemProbe.swapSnapshot
    }

    /// Atomically rotates every potentially wide scan-session container to fresh storage. The
    /// retirement actor is created first, so MainActor never becomes the final owner while the
    /// old snapshot, Tree cache, indexes, evidence or per-root arrays are being discarded.
    private func rotateWideSessionStateToEmpty() {
        // v2026.10.08: the replay strategy belongs to this visible result owner. Cancellation
        // and cross-mode invalidation must revoke it; an admitted replay reinstalls its capture.
        discoveryScanState = nil
        retainedScanOptions = .default
        let retirementWorker = ScanSessionRetirementWorker(
            snapshotRows: snapshot.rows,
            buckets: buckets,
            lastIngestAt: lastIngestAt,
            streamSortedIDs: lastStreamSortedIds,
            dirIndex: dirIndex,
            childEdges: childEdges,
            fileLeaves: fileLeaves,
            treeCache: treeChildrenCache,
            treePreviewCache: indexedTreePreviewCache,
            mtimeCache: mtimeFallbackCache,
            primaryEvidence: primaryIncompleteEvidence,
            treeEvidence: treeIncompleteEvidenceByRoot,
            issues: incompleteScanIssues,
            permissionPaths: permissionDeniedPaths,
            tccPaths: tccProtectedSkippedPaths,
            allIncompletePaths: incompleteScanPaths,
            treeEvidenceProjection: treeScanEvidenceProjection,
            perRootStaging: perRootStaging,
            perRootActive: perRootProgressActive,
            perRootFinished: perRootFinishedSlim,
            perRootSorted: perRootProgressSorted,
            perRootTreeRows: perRootTreeRowsBySort,
            snapshotTreeRows: snapshotTreeRowsBySort,
            largeFileLeaves: largeFileLeaves,
            compactedLargeFileTopN: compactedLargeFileTopN
        )

        snapshot = .empty
        buckets = [:]
        lastIngestAt = [:]
        lastStreamSortedIds = []
        lastStreamSortCacheKey = (-1, -1)
        dirIndex = [:]
        childEdges = [:]
        fileLeaves = [:]
        treeChildrenCache = [:]
        indexedTreePreviewCache = [:]
        snapshotTreeRowsBySort = [:]
        mtimeFallbackCache = [:]
        primaryIncompleteEvidence = ScanIncompleteEvidenceIndex()
        treeIncompleteEvidenceByRoot = [:]
        incompleteScanIssues = []
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []
        incompleteScanPaths = []
        treeScanEvidenceProjection = TreeScanEvidenceProjection()
        incompleteEvidenceProjectionDirty = false
        incompleteEvidenceProjectionRebuildCount &+= 1
        incompleteEvidenceSourceRevision &+= 1
        perRootStaging = [:]
        perRootProgressActive = [:]
        perRootFinishedSlim = [:]
        perRootFinishedCount = 0
        perRootProgressSorted = []
        perRootTreeRowsBySort = [:]
        largeFileLeaves = LargeFileLeafTopNHeap(capacity: Self.largeFileTopNCapacity)
        compactedLargeFileTopN = nil
        lastIndexSnapshot = (0, 0, 0)
        bumpChildrenCacheVersion()
        bumpStructuralRevision(advanceSourceRevision: false)

        Task { @MainActor [weak self] in
            // Let synchronous @Published delivery finish before the actor drops its retained roots.
            await Task.yield()
            let diagnostics = await retirementWorker.retire()
            self?.lastSessionRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastSessionRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private var isPrimaryScanSettling: Bool {
        if case .settling = scanPhase { return true }
        return false
    }

    /// Registry invalidation cancels orchestration/presentation immediately, but returns only real
    /// Tree filesystem settlements. The registry attaches those handles to the invalidated
    /// reservation before deciding whether the replacement may start.
    private func handlePrimaryAdmissionInvalidation(
        _ context: PrimaryScanAdmissionRegistry.InvalidationContext
    ) -> [Task<Void, Never>] {
        scanTask?.cancel()
        scanTask = nil
        activePrimaryReservation = nil
        activeCategoryID = nil
        commonAppCacheProgress = nil
        isScanning = false
        let filesystemSettlements = cancelAllTreeChildrenFetches()

        // Invalidate every late presentation write even when the replacement belongs to another
        // coordinator. A same-client replacement keeps the stable predecessor frame visible until
        // admission; cross-mode replacement clears the now-hidden frame and revokes all actions.
        scanGeneration = UUID()
        if !context.preservesPresentation(for: primaryScanAdmissionClientID) {
            publishedScanSessionID = scanGeneration
            rotateWideSessionStateToEmpty()
            currentRootPath = nil
            lastError = nil
            terminalFailure = nil
            lastProducerTerminalElapsed = nil
            lastConsumerDrainLag = nil
            largeFileTopNOnlyScan = false
            incrementalNodeDeliveryCount = 0
            pruneStateGeneration = UUID()
            notePruneSourceMutation()
            scanPhase = .idle
        }
        return filesystemSettlements
    }

    /// MainActor-only reset performed in the same synchronous turn that starts the admitted scan.
    /// No observer can see an empty/new snapshot while the old producer is still settling.
    private func prepareForAdmittedPrimaryScan() {
        // v2026.07.19 settlement regression fix: producer invalidation and visible snapshot
        // identity are separate clocks. Advance the visible identity only in the same turn that
        // discards the predecessor frame and starts the admitted replacement.
        publishedScanSessionID = scanGeneration
        rotateWideSessionStateToEmpty()
        currentRootPath = nil
        lastError = nil
        terminalFailure = nil
        lastProducerTerminalElapsed = nil
        lastConsumerDrainLag = nil
        largeFileTopNOnlyScan = false
        incrementalNodeDeliveryCount = 0
        pruneStateGeneration = UUID()
        notePruneSourceMutation()
    }

    /// Serializes primary scan admission without retaining one waiter Task per click. The shared
    /// registry keeps exactly one current reservation and one latest pending request. Tree-to-Tree
    /// replacement uses its path-scoped true-termination registry; only a primary replacement
    /// consumes the cancelled Tree filesystem handles returned above.
    private func schedulePrimaryScanIntent(
        _ intent: PrimaryScanIntent,
        start: @escaping @MainActor @Sendable () -> Void
    ) {
        // Cancel this coordinator's orchestration/presentation immediately. Filesystem ownership
        // is still retained by the registry lease until exact producer termination and payload
        // handoff, so this does not create an overlap window.
        scanTask?.cancel()
        scanTask = nil
        // A completed snapshot may still own on-demand Tree filesystem work. Register its exact
        // cancellation settlement before requesting primary admission, including the idle-
        // registry case; otherwise the new primary walk can overlap a Tree walk on the same disk.
        primaryScanAdmissionRegistry.registerExternalSettlements(
            cancelAllTreeChildrenFetches(),
            reason: "primary_request"
        )
        let predecessorGeneration = scanGeneration
        let intentID = UUID()
        let state = ScanSettlementState(
            intent: intent,
            predecessorGeneration: predecessorGeneration,
            intentID: intentID
        )
        let startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let decision = primaryScanAdmissionRegistry.request(
            clientID: primaryScanAdmissionClientID,
            intent: intent.logValue,
            onInvalidated: { [weak self] context in
                self?.handlePrimaryAdmissionInvalidation(context) ?? []
            },
            onAdmitted: { [weak self] reservation in
                self?.admitPendingPrimaryIntent(
                    intentID: intentID,
                    reservation: reservation,
                    start: start
                )
            },
            onDiscarded: { [weak self] in
                self?.discardPendingPrimaryIntent(intentID: intentID) ?? []
            }
        )
        // Registry invalidation may rotate the predecessor generation synchronously. Install the
        // incoming producer generation only after request() returns.
        scanGeneration = intentID

        switch decision {
        case .admitted(let reservation):
            activePrimaryReservation = reservation
            pendingPrimaryScanIntent = nil
            lastScanSettlementDuration = 0
            prepareForAdmittedPrimaryScan()
            start()
        case .queued(let requestToken, let blockers):
            pendingPrimaryScanIntent = PendingPrimaryScanIntent(
                state: state,
                startedUptimeNanoseconds: startedUptimeNanoseconds,
                requestToken: requestToken
            )
            scanPhase = .settling(state)
            isScanning = false
            GSYLog.notice(
                .scan,
                "scan.settlement.wait.start intent=\(intent.logValue) "
                    + "old_generation=\(predecessorGeneration.uuidString) "
                    + "new_intent=\(intentID.uuidString) blockers=\(blockers.count)"
            )
        }
    }

    private func admitPendingPrimaryIntent(
        intentID: UUID,
        reservation: PrimaryScanAdmissionRegistry.ReservationToken,
        start: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let pending = pendingPrimaryScanIntent,
              pending.state.intentID == intentID,
              scanGeneration == intentID,
              primaryScanAdmissionRegistry.isCurrent(reservation)
        else {
            primaryScanAdmissionRegistry.cancelReservation(reservation)
            return
        }
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - pending.startedUptimeNanoseconds
        ) / 1_000_000_000
        activePrimaryReservation = reservation
        pendingPrimaryScanIntent = nil
        lastScanSettlementDuration = elapsed
        GSYLog.notice(
            .scan,
            "scan.settlement.wait.finish intent=\(pending.state.intent.logValue) "
                + "new_intent=\(intentID.uuidString) result=settled "
                + "duration_ms=\(String(format: "%.2f", elapsed * 1_000))"
        )
        prepareForAdmittedPrimaryScan()
        start()
    }

    private func discardPendingPrimaryIntent(intentID: UUID) -> [Task<Void, Never>] {
        guard pendingPrimaryScanIntent?.state.intentID == intentID else { return [] }
        pendingPrimaryScanIntent = nil
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        let filesystemSettlements = cancelAllTreeChildrenFetches()
        activeCategoryID = nil
        commonAppCacheProgress = nil
        isScanning = false
        // Pending supersession never owned or replaced the visible predecessor frame. Preserve
        // that stable terminal snapshot/session instead of clearing the UI when latest-wins drops
        // an obsolete click. A subsequent admitted request advances the visible identity in one
        // atomic MainActor turn.
        scanPhase = .idle
        return filesystemSettlements
    }

    private func finishPrimaryFilesystemProducer(
        leaseID: PrimaryScanAdmissionRegistry.ProducerLeaseID,
        reservation: PrimaryScanAdmissionRegistry.ReservationToken,
        finishesPipeline: Bool
    ) {
        primaryScanAdmissionRegistry.finishProducerAfterPayloadHandoff(
            leaseID,
            reservation: reservation
        )
        guard finishesPipeline else { return }
        if primaryScanAdmissionRegistry.finishPipeline(reservation: reservation),
           activePrimaryReservation == reservation {
            activePrimaryReservation = nil
        }
    }

    private func finishPrimaryPipeline(
        reservation: PrimaryScanAdmissionRegistry.ReservationToken
    ) {
        if primaryScanAdmissionRegistry.finishPipeline(reservation: reservation),
           activePrimaryReservation == reservation {
            activePrimaryReservation = nil
        }
    }

    public func cancel() {
        if isScanning || scanTask != nil || pendingPrimaryScanIntent != nil {
            GSYLog.notice(.operation, "scan.cancel activeCategory=\(activeCategoryID ?? "nil") root=\(currentRootPath ?? "nil")")
        }
        if let requestToken = pendingPrimaryScanIntent?.requestToken {
            primaryScanAdmissionRegistry.cancelRequest(requestToken)
        }
        pendingPrimaryScanIntent = nil
        if let reservation = activePrimaryReservation {
            primaryScanAdmissionRegistry.cancelReservation(reservation)
        } else {
            scanTask?.cancel()
            scanTask = nil
            primaryScanAdmissionRegistry.registerExternalSettlements(
                cancelAllTreeChildrenFetches(),
                reason: "coordinator_cancel"
            )
        }
        let cancelledGeneration = UUID()
        scanGeneration = cancelledGeneration
        publishedScanSessionID = cancelledGeneration
        if isScanning { isScanning = false }
        // Cancel task ownership and clear the disclosed frame before any `.idle` publication.
        // When cancel is called from an already-idle completed result, assigning the same false
        // value to @Published would otherwise synchronously expose the old terminal snapshot.
        rotateWideSessionStateToEmpty()
        commonAppCacheProgress = nil
        // v1.3：cancel 同时清 activeCategoryID，让旧 stream 残留事件能被自检识别为"过期"并丢弃。
        activeCategoryID = nil
        // v1.3 review-fix：cancel 必须 reset snapshot 与 currentRootPath，
        // 否则 isPristine 判定（rows.isEmpty + scannedFileCount==0）失真，
        // statusBar 会把"扫到一半被打断"误显示成"还未扫描"。
        // 同时把 permissionDeniedPaths / tccProtectedSkippedPaths / lastError 一起清掉，
        // 避免上一轮 banner 漂到下一类目。
        currentRootPath = nil
        lastError = nil
        terminalFailure = nil
        lastProducerTerminalElapsed = nil
        lastConsumerDrainLag = nil
        largeFileTopNOnlyScan = false
        incrementalNodeDeliveryCount = 0
        // v1.3：标记本次状态为"用户主动停止"，让 statusBar 显示"已停止"而非"还未扫描"。
        wasCancelled = true
        pruneStateGeneration = UUID()
        notePruneSourceMutation()
        // v2026.07.19 settlement regression fix: `.idle` is the authoritative terminal publish.
        // Emit it only after the predecessor frame, session identity and evidence have all been
        // reset; otherwise consumers can briefly authorize the retained finished snapshot.
        scanPhase = .idle
    }

    /// v2026.07.17 scan-ownership fix: leaving Professional mode must stop an
    /// in-flight on-demand Tree traversal even when the primary scan has already
    /// finished. Unlike `cancel()`, this preserves the completed snapshot so a
    /// later mode switch can restore results without another full-disk scan.
    public func cancelOnDemandTreeScansPreservingResults() {
        primaryScanAdmissionRegistry.registerExternalSettlements(
            cancelAllTreeChildrenFetches(),
            reason: "mode_exit"
        )
    }

    public func scan(category: ScanCategory, includeHidden: Bool = true,
                     largeFileMinBytes: Int64 = 0) {
        schedulePrimaryScanIntent(.category(category.id)) { [weak self] in
            self?.startCategoryScan(
                category: category,
                includeHidden: includeHidden,
                largeFileMinBytes: largeFileMinBytes
            )
        }
    }

    private func startCategoryScan(
        category: ScanCategory,
        includeHidden: Bool,
        largeFileMinBytes: Int64
    ) {
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        allocationRebaseline = { [weak self] in
            self?.scan(category: category, includeHidden: includeHidden, largeFileMinBytes: largeFileMinBytes)
        }
        verdictCacheHits = 0
        verdictCacheMisses = 0
        let topNOnlyLargeFileScan = category.kind == .largeFiles
        self.largeFileTopNOnlyScan = topNOnlyLargeFileScan
        self.largeFileMinBytes = max(0, largeFileMinBytes)
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        // v1.3：ETA 采样状态归零；仅整盘扫给 ETA（其它扫描不知道总量）。
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        // v1.3.x：所有非整盘扫描也开 ETA 闸门——是否真的能出 ETA 取决于 expectedTotalBytes 是否估出来。
        expectedTotalBytes = nil
        currentRootPath = category.rootPath
        snapshot = ScanSnapshot(categoryID: category.id, rows: [], totalBytes: 0,
                                scannedFileCount: 0, isFinished: false, elapsed: 0)
        liveProgress.reset(categoryID: category.id, startedAt: startedAt)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        // v1.3：cancel() 把 activeCategoryID 清空了，本次 scan 入口重新打上当前 token；
        // runScan 内每个事件先校验 `categoryID == activeCategoryID`，过期 stream 残留事件会被自动丢弃。
        activeCategoryID = category.id

        // 白名单是最高优先级边界：必须先拿到完整快照，再让 scanner 产生第一个 node。
        // 旧实现把快照加载与扫描并发启动，首帧可能短暂暴露甚至选中已加白路径。
        whitelistSnapshot = []

        // v2026.07.18 全盘正确性修复：`/` 是只读 System 卷视图，不是整台 Mac 的
        // 数据枚举根。若物理扫描 `/`，staySingleVolume 会把 Data 卷挡在卷边界外，
        // 最终只剩截图中的 System/usr 等小量结果。全盘会话必须从 Data 卷枚举，
        // 同时继续用公开 `/` 作为 UI、Tree 与安全证据命名空间。
        let rootURL = Self.physicalScanRootURL(for: category)
        let displayRootPath = category.rootPath
        let categoryID = category.id
        let generation = scanGeneration
        guard let reservation = activePrimaryReservation else { return }
        GSYLog.notice(.flow, "scan.start category=\(category.id) root=\(rootURL.path) includeHidden=\(includeHidden) largeFileMinBytes=\(largeFileMinBytes)")

        treeFetchGeneration = UUID()

        // v2026.07.16 性能回归根治：删除非整盘的 TreeSizeEstimator 重复遍历。
        // ETA 已于 2026.06.23 停止展示；继续并发 walk 同一棵树只会让取消后的旧 I/O
        // 最多再运行 4 秒并与新扫描争抢磁盘。整盘仍可直接复用卷容量快照，不产生额外 I/O。
        if category.kind == .fullDisk, let used = volumeSnapshot?.usedBytes {
            // 整盘扫直接把 used 当 expectedTotalBytes 暴露给 UI，统一口径
            self.expectedTotalBytes = used
        }
        // v2026.07.17 全链路性能边界：所有扫描根都固定在该根所在卷。
        // 用户选中外置卷本身时，root device 就是该外置卷，仍能完整扫描；
        // 只会拦住其内另一个嵌套 mount/FileProvider/网络卷。旧实现只对整盘开启，
        // HOME/推荐/开发者根可被嵌套挂载无界拉长，造成同一入口耗时不可预测。
        let isFullDisk = category.kind == .fullDisk
        // v1.3 P0-C：整盘扫描节点量 100k+，deep index 在 MainActor ingest 内做
        // 祖先回溯 + childEdges/dirIndex/fileLeaves 写入会瞬间打爆主线程帧预算。
        // 整盘永远走按需子树扫描路径（同步表面 + 后台填充）。
        if isFullDisk {
            enforceOnDemandTreeProductEntry(.fullDisk)
        }
        let whitelistStore = self.whitelistStore
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard let self,
                  self.ownsScan(categoryID: categoryID, generation: generation) else { return }
            self.whitelistSnapshot = whitelist
            await self.runScan(rootURL: rootURL,
                               displayRootPath: displayRootPath,
                               categoryID: categoryID,
                               generation: generation,
                               reservation: reservation,
                               includeHidden: includeHidden, staySingleVolume: true,
                               largeFileTopNOnly: topNOnlyLargeFileScan)
        }
    }

    /// v1.0 T5：整盘扫描便捷入口 —— 等价于 `scan(category: .fullDisk)`。
    /// MainView 路径栏输入 `/` 回车 / 整盘扫描按钮 都走这个 API，避免在多处硬编码 `ScanCategory.fullDisk`。
    public func scanFullDisk(includeHidden: Bool = true) {
        scan(category: .fullDisk, includeHidden: includeHidden)
    }

    /// 物理枚举根与公开 category 路径的唯一映射边界。保留为 internal 供入口合同测试，
    /// 防止未来重构再次把整盘物理根退回只读 System 卷的 `/`。
    nonisolated static func physicalScanRootURL(for category: ScanCategory) -> URL {
        category.kind == .fullDisk
            ? Firmlinks.recommendedDataVolumeRoot
            : category.rootURL
    }

    /// M4-T2：版本化收集根扫描入口。
    ///
    /// 调用 [KnownVersionedRoots.scanAllWithEvidence(home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift)
    /// 拿到所有可回收的旧版本子目录（Xcode DeviceSupport / JetBrains Toolbox 等），
    /// 直接构造 [RowItem](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift)
    /// 发布一个 finished snapshot 给 UI。每个候选仍使用独立 BulkScanner 会话计量，
    /// 但不把海量 node materialize 到主列表；主线程只接收最终 rows 和完整性证据。
    ///
    /// categoryID 固定 `"developer.versioned"`，方便上层按 id 区分。
    /// 每条 Hit 的物理/逻辑大小、文件数、permissionDenied/TCC/partial 都来自同一
    /// BulkScanner 扫描会话。任何不完整候选仍可展示，但会以 `.accessDenied` 锁定，
    /// 且其证据同步进入最终 TrashPipeline 预检，绝不能移动未完整扫描的父目录。
    ///
    /// 与 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
    /// 的关系：每条命中仍然走 `engine.evaluate(path:trie:home:)`，让 forbid 路径
    /// 在 UI 上以 lock 形式显示而非被静默删除（与主扫描行为对齐）。
    public func scanKnownVersionedRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        schedulePrimaryScanIntent(.versionedRoots) { [weak self] in
            self?.startKnownVersionedRootsScan(home: home)
        }
    }

    private func startKnownVersionedRootsScan(home: URL, reconciliationRoots: [String] = []) {
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        discoveryScanState = .init(plan: .versionedRoots(home: home), candidateRoots: reconciliationRoots)
        largeFileTopNOnlyScan = false
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        expectedTotalBytes = nil
        // v2026.06.21：用专用 sentinel 而非 home.path，让 TreeBrowserView 走
        // [synthesizeVersionedTopLevel] 把 snapshot.rows 合成树形顶层；
        // 否则 directChildren(of: home.path) 在 childEdges/store 都找不到子项，
        // 树形视图永远空（用户反馈"清单 28 文件，树形为空"）。
        let categoryID = "developer.versioned"
        currentRootPath = ScanCoordinator.versionedRootSentinelPath
        snapshot = ScanSnapshot(categoryID: categoryID, rows: [], totalBytes: 0,
                                scannedFileCount: 0, isFinished: false, elapsed: 0)
        liveProgress.reset(categoryID: categoryID, startedAt: startedAt)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        whitelistSnapshot = []
        activeCategoryID = categoryID
        let generation = scanGeneration
        GSYLog.notice(.flow, "scan.versioned.start home=\(home.path)")

        guard let reservation = activePrimaryReservation else { return }
        let engineCopy = engine
        let trieRef = trie
        let homeStr = self.home
        let startedAtCopy = startedAt
        let localeCopy = presentationLocale
        let whitelistStore = self.whitelistStore
        let scanOptions = ScanOptions(
            includeHidden: true,
            includePackageContents: true,
            followSymlinks: false,
            followFirmlinks: false,
            dedupByInode: true,
            staySingleVolume: true,
            mediaAware: true,
            // v2026.07.18 privacy contract: TCCSkipList is an unconditional hard boundary.
            // FDA state only describes OS authorization and must never widen product scope.
            respectTCCSkipList: Self.shouldRespectTCCSkipList(fdaStatus: fdaStatus)
        )
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard !Task.isCancelled,
                  let self,
                  self.ownsScan(categoryID: categoryID, generation: generation),
                  let producerLaunch = self.primaryScanAdmissionRegistry.reserveProducerLaunch(
                    reservation: reservation,
                    kind: .versionedRoots
                  )
            else { return }
            self.whitelistSnapshot = whitelist
            let producer = Task.detached(priority: .userInitiated) {
                let producerStartedAt = DispatchTime.now().uptimeNanoseconds
                let discovery = KnownVersionedRoots.scanAllWithEvidence(home: home)
                var entries: [VersionedRootMeasuredHit] = []
                entries.reserveCapacity(discovery.hits.count)
                var wasCancelled = discovery.wasCancelled
                if !wasCancelled {
                    for hit in discovery.hits where !Self.isWhitelisted(hit.url.path, in: whitelist) {
                        guard !Task.isCancelled,
                              let measurement = await Self.measureVersionedRoot(
                                at: hit.url,
                                options: scanOptions
                              )
                        else {
                            wasCancelled = true
                            break
                        }
                        entries.append(VersionedRootMeasuredHit(
                            hit: hit,
                            measurement: measurement
                        ))
                    }
                }
                return VersionedRootsProducerOutput(
                    entries: entries,
                    discoveryIssues: discovery.incompleteIssues,
                    wasCancelled: wasCancelled,
                    elapsed: Double(
                        DispatchTime.now().uptimeNanoseconds - producerStartedAt
                    ) / 1_000_000_000
                )
            }
            let termination = Task.detached(priority: .userInitiated) {
                _ = await producer.value
            }
            guard let leaseID = self.primaryScanAdmissionRegistry.activateProducer(
                launch: producerLaunch,
                reservation: reservation,
                cancel: { producer.cancel() },
                termination: termination
            ) else {
                await termination.value
                self.primaryScanAdmissionRegistry.abandonProducerLaunch(
                    producerLaunch,
                    reservation: reservation
                )
                return
            }
            let output = await withTaskCancellationHandler {
                await producer.value
            } onCancel: {
                producer.cancel()
            }
            await termination.value
            let payloadOwner = ProducerPayloadOwner(output)
            self.finishPrimaryFilesystemProducer(
                leaseID: leaseID,
                reservation: reservation,
                finishesPipeline: true
            )
            guard self.ownsScan(categoryID: categoryID, generation: generation),
                  let presentation = await Self.prepareVersionedRootsPresentation(
                    owner: payloadOwner,
                    engine: engineCopy,
                    trie: trieRef,
                    home: homeStr,
                    locale: localeCopy,
                    reconciliationRoots: reconciliationRoots
                  ),
                  self.ownsScan(categoryID: categoryID, generation: generation)
            else {
                await payloadOwner.retire()
                return
            }

            self.discoveryScanState = .init(plan: .versionedRoots(home: home), candidateRoots: presentation.rootPaths)
            self.replaceIncompleteEvidence(with: presentation.incompleteIssues)
            self.totalBytes = presentation.totalBytes
            self.scannedFiles = presentation.fileCount
            self.snapshot = ScanSnapshot(
                categoryID: categoryID,
                rows: presentation.rows,
                totalBytes: presentation.totalBytes,
                scannedFileCount: presentation.fileCount,
                isFinished: true,
                elapsed: Date().timeIntervalSince(startedAtCopy),
                isComplete: presentation.incompleteIssues.isEmpty
            )
            self.snapshotTreeRowsBySort = presentation.treeRowsBySort
            if localeCopy.identifier != self.presentationLocale.identifier {
                self.scheduleLocaleReprojection(locale: self.presentationLocale)
            }
            self.lastFinishedCategoryID = categoryID
            self.isScanning = false
            self.scanPhase = .idle
            self.scanTask = nil
            self.activeCategoryID = nil
            self.invalidateTreeCacheAfterScan()
            self.refreshVolumeCapacity()
            self.recordTerminalPerformanceEvidence(
                producerElapsed: presentation.producerElapsed
            )
            GSYLog.notice(
                .flow,
                "scan.versioned.finish rows=\(presentation.rows.count) "
                    + "files=\(presentation.fileCount) totalBytes=\(presentation.totalBytes) "
                    + "complete=\(self.snapshot.isComplete) "
                    + "discoveryIssues=\(presentation.discoveryIssueCount) "
                    + "producerElapsed=\(String(format: "%.3f", presentation.producerElapsed))s "
                    + "elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAtCopy)))s"
            )
        }
    }

    /// 常见应用缓存扫描入口。
    ///
    /// 这里不是从某个大根目录递归构建树，而是消费 `vendors.yaml` 里审计过的
    /// `category=common_app_cache` 路径规则，做"规则命中列表"。因此：
    /// - IO 和目录计量全部在后台 executor 完成；
    /// - 主线程只在开始/结束各发布一次状态，不产生扫描中列表抖动；
    /// - 发布前仍走 SafetyEngine，保证硬禁区不会被规则误写绕过。
    public func scanCommonAppCaches(
        includeConfirm: Bool = true,
        scannerOptions: CommonAppCacheScanner.Options? = nil
    ) {
        schedulePrimaryScanIntent(.commonAppCaches) { [weak self] in
            self?.startCommonAppCacheScan(
                includeConfirm: includeConfirm,
                scannerOptions: scannerOptions
            )
        }
    }

    private func startCommonAppCacheScan(
        includeConfirm: Bool,
        scannerOptions: CommonAppCacheScanner.Options?,
        reconciliationRoots: [String] = []
    ) {
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        discoveryScanState = .init(plan: .commonAppCaches(includeConfirm: includeConfirm, options: scannerOptions),
                                   candidateRoots: reconciliationRoots)
        verdictCacheHits = 0
        verdictCacheMisses = 0
        largeFileTopNOnlyScan = false
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        expectedTotalBytes = nil
        currentRootPath = ScanCoordinator.commonAppCacheSentinelPath
        snapshot = ScanSnapshot(categoryID: ScanCoordinator.commonAppCacheCategoryID,
                                rows: [],
                                totalBytes: 0,
                                scannedFileCount: 0,
                                isFinished: false,
                                elapsed: 0)
        liveProgress.reset(
            categoryID: ScanCoordinator.commonAppCacheCategoryID,
            startedAt: startedAt
        )
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        devArtifactDidTruncate = false
        devArtifactDidTimeout = false
        activeCategoryID = ScanCoordinator.commonAppCacheCategoryID
        whitelistSnapshot = []
        treeFetchGeneration = UUID()
        let generation = scanGeneration
        guard let reservation = activePrimaryReservation else { return }
        commonAppCacheProgress = CommonAppCacheScanner.Progress(
            phase: .resolvingCandidates,
            completedGroups: 0,
            totalGroups: 0
        )

        let categoryID = ScanCoordinator.commonAppCacheCategoryID
        let activeStartedAt = startedAt
        let localeCopy = presentationLocale
        let vendorsCopy = vendors
        let engineCopy = engine
        let trieRef = trie
        let homeStr = home
        let homeURL = URL(fileURLWithPath: homeStr, isDirectory: true)
        let included: Set<SafetyVerdict> = includeConfirm ? [.safe, .confirm] : [.safe]
        var options = scannerOptions ?? CommonAppCacheScanner.Options()
        options.includedVerdicts = included
        // v2026.07.17 C4 App Data regression: neither a worker process nor a hard timeout makes
        // protected Container access non-interactive. On Sonoma+ the first glob/lstat/open may
        // synchronously present a system consent sheet and block the scan. Only a positive FDA
        // probe authorizes the non-interactive cache pass; denied/unknown keep scanning ordinary
        // caches while the scanner returns typed protected-path evidence before touching TCC.
        // This is independent from whether the owning App is running and must never become a
        // running-process admission gate.
        options.allowsProtectedAppDataAccess = Self.commonAppCacheAllowsProtectedAppDataAccess(
            fdaStatus: fdaStatus,
            scanHome: home
        )
        let whitelistStore = self.whitelistStore
        let detectorOverride = commonAppCacheDetector
        let standardRuleDiscoveryOverride = standardInstalledAppCacheRuleDiscovery
        let executionMode = commonAppCacheExecution
        let progressRelay = CommonAppCacheProgressRelay()
        let progressHandler: CommonAppCacheScanner.ProgressHandler = { [weak self] progress in
            progressRelay.store(progress)
            Task { @MainActor [weak self] in
                guard let self,
                      self.ownsScan(categoryID: categoryID, generation: generation) else { return }
                self.commonAppCacheProgress = progress
            }
        }
        GSYLog.notice(.flow,
                      "scan.common_app_cache.start rules=\(vendorsCopy.filter { $0.category == "common_app_cache" }.count) includeConfirm=\(includeConfirm)")

        // v2026.09.20：捕获配置值快照，避免外层 MainActor Task 与 detached producer
        // 共享 options 的可变捕获盒；Swift 6 严格并发要求跨隔离传递不可变 Sendable 值。
        scanTask = Task { [weak self, options] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard !Task.isCancelled,
                  let self,
                  self.ownsScan(categoryID: categoryID, generation: generation),
                  let launch = self.primaryScanAdmissionRegistry.reserveProducerLaunch(
                    reservation: reservation,
                    kind: .commonAppCaches
                  )
            else { return }
            self.whitelistSnapshot = whitelist
            let producer = Task.detached(priority: .userInitiated) {
                () -> CommonAppCacheProducerOutput? in
                let producerStartedAt = DispatchTime.now().uptimeNanoseconds
                let standardDiscovery: StandardInstalledAppCacheRuleDiscoveryResult
                if let standardRuleDiscoveryOverride {
                    standardDiscovery = await standardRuleDiscoveryOverride()
                } else {
                    standardDiscovery = await Self.standardInstalledAppCacheRules()
                }
                guard !Task.isCancelled, !standardDiscovery.wasCancelled else { return nil }
                for issue in standardDiscovery.issues {
                    GSYLog.warning(
                        .scan,
                        "scan.common_app_cache.standard_discovery \(issue.logFields)"
                    )
                }
                var effectiveOptions = options
                effectiveOptions.excludedCandidatePathPrefixes.formUnion(whitelist)
                let rules = vendorsCopy + standardDiscovery.rules
                let scanResult: CommonAppCacheScanner.ScanResult
                if let detectorOverride {
                    scanResult = detectorOverride(rules, homeURL, effectiveOptions)
                } else {
                    switch executionMode {
                    case .inProcess:
                        scanResult = CommonAppCacheScanner.detect(
                            vendors: rules,
                            home: homeURL,
                            options: effectiveOptions,
                            onProgress: progressHandler
                        )
                    case .isolated(let executableURL):
                        scanResult = await CommonAppCacheWorkerBridge.scanIsolated(
                            executableURL: executableURL,
                            vendors: rules,
                            home: homeURL,
                            options: effectiveOptions,
                            onProgress: progressHandler
                        )
                    }
                }
                guard !Task.isCancelled, !scanResult.wasCancelled else { return nil }
                var modificationDates: [String: Date] = [:]
                modificationDates.reserveCapacity(scanResult.hits.count)
                for hit in scanResult.hits {
                    guard !Task.isCancelled else { return nil }
                    let path = hit.url.standardizedFileURL.path
                    if let date = Self.modificationDate(at: hit.url) {
                        modificationDates[path] = date
                    }
                }
                return CommonAppCacheProducerOutput(
                    standardDiscovery: standardDiscovery,
                    scanResult: scanResult,
                    modificationDates: modificationDates,
                    latestProgress: progressRelay.snapshot,
                    elapsed: Double(
                        DispatchTime.now().uptimeNanoseconds - producerStartedAt
                    ) / 1_000_000_000
                )
            }
            let termination = Task.detached(priority: .userInitiated) {
                _ = await producer.value
            }
            guard let leaseID = self.primaryScanAdmissionRegistry.activateProducer(
                launch: launch,
                reservation: reservation,
                cancel: { producer.cancel() },
                termination: termination
            ) else {
                await termination.value
                self.primaryScanAdmissionRegistry.abandonProducerLaunch(
                    launch,
                    reservation: reservation
                )
                return
            }
            let output = await withTaskCancellationHandler {
                await producer.value
            } onCancel: {
                producer.cancel()
            }
            await termination.value
            guard let output else {
                self.finishPrimaryFilesystemProducer(
                    leaseID: leaseID,
                    reservation: reservation,
                    finishesPipeline: true
                )
                return
            }
            let payloadOwner = ProducerPayloadOwner(output)
            self.finishPrimaryFilesystemProducer(
                leaseID: leaseID,
                reservation: reservation,
                finishesPipeline: true
            )
            guard self.ownsScan(categoryID: categoryID, generation: generation),
                  let presentation = await Self.prepareCommonAppCachePresentation(
                    owner: payloadOwner,
                    whitelist: whitelist,
                    engine: engineCopy,
                    trie: trieRef,
                    home: homeStr,
                    locale: localeCopy,
                    reconciliationRoots: reconciliationRoots
                  ),
                  self.ownsScan(categoryID: categoryID, generation: generation)
            else {
                await payloadOwner.retire()
                return
            }
            self.discoveryScanState = .init(plan: .commonAppCaches(includeConfirm: includeConfirm, options: scannerOptions),
                                            candidateRoots: presentation.rootPaths)
            self.replaceIncompleteEvidence(with: presentation.issues)
            for issue in presentation.issues {
                GSYLog.warning(
                    .scan,
                    "scan.common_app_cache.incomplete path=\(issue.path) "
                        + "reason=\(issue.reason.rawValue) stage=\(issue.stage?.rawValue ?? "none")"
                )
            }
            self.totalBytes = presentation.totalBytes
            self.scannedFiles = presentation.fileCount
            self.commonAppCacheProgress = presentation.terminalProgress
            self.snapshot = ScanSnapshot(
                categoryID: categoryID,
                rows: presentation.rows,
                totalBytes: presentation.totalBytes,
                scannedFileCount: presentation.fileCount,
                isFinished: true,
                elapsed: Date().timeIntervalSince(activeStartedAt),
                isComplete: presentation.isComplete
            )
            self.snapshotTreeRowsBySort = presentation.treeRowsBySort
            if localeCopy.identifier != self.presentationLocale.identifier {
                self.scheduleLocaleReprojection(locale: self.presentationLocale)
            }
            self.lastFinishedCategoryID = categoryID
            self.isScanning = false
            self.scanPhase = .idle
            self.scanTask = nil
            self.activeCategoryID = nil
            self.invalidateTreeCacheAfterScan()
            self.refreshVolumeCapacity()
            self.recordTerminalPerformanceEvidence(
                producerElapsed: presentation.producerElapsed
            )
            GSYLog.notice(
                .flow,
                "scan.common_app_cache.finish rows=\(presentation.rows.count) "
                    + "totalBytes=\(presentation.totalBytes) entries=\(presentation.fileCount) "
                    + "complete=\(presentation.isComplete) "
                    + "scanIssues=\(presentation.scanIssueCount) "
                    + "discoveryIssues=\(presentation.discoveryIssueCount) "
                    + "producerElapsed=\(String(format: "%.3f", presentation.producerElapsed))s "
                    + "elapsed=\(String(format: "%.2f", Date().timeIntervalSince(activeStartedAt)))s"
            )
        }
    }

    /// Application enumeration is a filesystem producer boundary. `async nonisolated` keeps it
    /// on the generic executor even if a future caller stops using the current detached task.
    nonisolated private static func standardInstalledAppCacheRules() async ->
        StandardInstalledAppCacheRuleDiscoveryResult {
        await discoverStandardInstalledAppCacheRules(
            applicationsRoot: URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileSystem: .live
        )
    }

    /// v2026.07.18 testable production algorithm: rules and incomplete evidence are one terminal
    /// value. Healthy apps survive a sibling metadata failure, but the round cannot claim complete.
    nonisolated static func discoverStandardInstalledAppCacheRules(
        applicationsRoot: URL,
        fileSystem: StandardInstalledAppCacheRuleFileSystem
    ) async -> StandardInstalledAppCacheRuleDiscoveryResult {
        guard !Task.isCancelled else { return .cancelled }
        let names: [String]
        do {
            names = try fileSystem.contentsOfDirectory(applicationsRoot).sorted()
        } catch {
            if standardInstalledAppDiscoveryWasCancelled(error) {
                return .cancelled
            }
            return StandardInstalledAppCacheRuleDiscoveryResult(
                rules: [],
                issues: [standardInstalledAppRootIssue(
                    path: applicationsRoot.standardizedFileURL.path,
                    error: error
                )]
            )
        }

        var rules: [VendorRule] = []
        var issues: [StandardInstalledAppCacheRuleDiscoveryIssue] = []
        rules.reserveCapacity(names.count)
        issues.reserveCapacity(names.count / 8)
        for name in names where name.hasSuffix(".app") {
            guard !Task.isCancelled else { return .cancelled }
            let appURL = applicationsRoot.appendingPathComponent(name, isDirectory: true)
            let metadataURL = appURL.appendingPathComponent("Contents/Info.plist")
            let meta: AppMetadata
            do {
                meta = try fileSystem.readMetadata(appURL, { Task.isCancelled })
            } catch {
                if standardInstalledAppDiscoveryWasCancelled(error) {
                    return .cancelled
                }
                issues.append(standardInstalledAppMetadataIssue(
                    path: metadataURL.standardizedFileURL.path,
                    error: error
                ))
                continue
            }
            guard !Task.isCancelled else { return .cancelled }
            let bundleID = meta.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else {
                issues.append(StandardInstalledAppCacheRuleDiscoveryIssue(
                    path: metadataURL.standardizedFileURL.path,
                    stage: .metadataDecode,
                    reason: .malformedMetadata,
                    posixErrorCode: nil
                ))
                continue
            }
            let paths = [
                "~/Library/Caches/\(bundleID)",
                "~/Library/Containers/\(bundleID)/Data/Library/Caches",
                "~/Library/HTTPStorages/\(bundleID)"
            ].map {
                PathRule(path: $0,
                         verdict: .safe,
                         reason: "common_app_cache.standard.reason")
            }

            rules.append(VendorRule(
                // The scanner carries the app name as data. AppUI combines it with the catalog
                // template only when a concrete locale renders the resulting RowItem.
                name: meta.appName,
                bundleIDPrefix: bundleID,
                category: "common_app_cache",
                source: "standard-macos-cache",
                paths: paths
            ))
        }
        return StandardInstalledAppCacheRuleDiscoveryResult(rules: rules, issues: issues)
    }

    nonisolated private static func standardInstalledAppRootIssue(
        path: String,
        error: Error
    ) -> StandardInstalledAppCacheRuleDiscoveryIssue {
        let code = standardInstalledAppPOSIXErrorCode(error)
        return StandardInstalledAppCacheRuleDiscoveryIssue(
            path: path,
            stage: .rootEnumeration,
            reason: standardInstalledAppIsPermissionDenied(error)
                ? .permissionDenied
                : .enumerationFailed,
            posixErrorCode: code
        )
    }

    nonisolated private static func standardInstalledAppMetadataIssue(
        path: String,
        error: Error
    ) -> StandardInstalledAppCacheRuleDiscoveryIssue {
        if let bounded = error as? BoundedLocalFileReadError {
            let reason: StandardInstalledAppCacheRuleDiscoveryIssue.Reason
            switch bounded {
            case .tooLarge:
                reason = .tooLarge
            case .unsafeType:
                reason = .unsafeType
            case .changed:
                reason = .changed
            case .cancelled:
                // The caller handles cancellation before classification. Keep this exhaustive and
                // fail closed if a synthetic source violates that call contract.
                reason = .metadataUnavailable
            case .invalidFileURL, .metadataUnavailable, .openFailed, .readFailed:
                reason = standardInstalledAppIsPermissionDenied(bounded)
                    ? .permissionDenied
                    : .metadataUnavailable
            }
            return StandardInstalledAppCacheRuleDiscoveryIssue(
                path: path,
                stage: .metadataRead,
                reason: reason,
                posixErrorCode: bounded.posixErrorCode
            )
        }
        if error is AppMetadataReadError {
            return StandardInstalledAppCacheRuleDiscoveryIssue(
                path: path,
                stage: .metadataDecode,
                reason: .malformedMetadata,
                posixErrorCode: nil
            )
        }
        let code = standardInstalledAppPOSIXErrorCode(error)
        if code != nil || standardInstalledAppIsPermissionDenied(error) {
            return StandardInstalledAppCacheRuleDiscoveryIssue(
                path: path,
                stage: .metadataRead,
                reason: standardInstalledAppIsPermissionDenied(error)
                    ? .permissionDenied
                    : .metadataUnavailable,
                posixErrorCode: code
            )
        }
        // Production reaches this branch only after bytes were read and PropertyList decoding
        // failed. Persist the semantic class, never the parser's localized/raw Error text.
        return StandardInstalledAppCacheRuleDiscoveryIssue(
            path: path,
            stage: .metadataDecode,
            reason: .malformedMetadata,
            posixErrorCode: nil
        )
    }

    nonisolated private static func standardInstalledAppDiscoveryWasCancelled(
        _ error: Error
    ) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return error as? BoundedLocalFileReadError == .cancelled
    }

    nonisolated private static func standardInstalledAppIsPermissionDenied(
        _ error: Error
    ) -> Bool {
        if let code = standardInstalledAppPOSIXErrorCode(error) {
            return code == EACCES || code == EPERM
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return standardInstalledAppIsPermissionDenied(underlying)
        }
        return false
    }

    nonisolated private static func standardInstalledAppPOSIXErrorCode(
        _ error: Error
    ) -> Int32? {
        if let bounded = error as? BoundedLocalFileReadError {
            return bounded.posixErrorCode
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(exactly: nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return standardInstalledAppPOSIXErrorCode(underlying)
        }
        return nil
    }

    /// App Data consent was introduced after the Ventura deployment floor. Ventura should keep
    /// the historical direct filesystem path and report any real errno; Sonoma+ must not trigger
    /// a consent sheet from an automatic scan unless FDA has been positively established.
    ///
    /// v2026.07.17 static-review correction: the OS protects the signed-in user's real HOME,
    /// not an arbitrary fixture/custom root that merely contains `Library/Containers`. Applying
    /// the production TCC policy to `/tmp/...` made otherwise complete test/custom scans partial
    /// because standard rules are appended independently of fixture vendors. Compare normalized
    /// configured roots without filesystem resolution on MainActor, and only gate the normal
    /// current-HOME session; custom roots keep reporting their real errno.
    nonisolated static func commonAppCacheAllowsProtectedAppDataAccess(
        fdaStatus: FDAProbe.Status,
        scanHome: String,
        currentUserHome: String = NSHomeDirectory(),
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        let normalizedScanHome = URL(fileURLWithPath: scanHome)
            .standardizedFileURL
            .path
        let normalizedCurrentHome = URL(fileURLWithPath: currentUserHome)
            .standardizedFileURL
            .path
        guard normalizedScanHome == normalizedCurrentHome else { return true }
        return macOSMajorVersion < 14 || fdaStatus == .granted
    }

    nonisolated private static func commonAppCacheIncompleteIssue(
        _ issue: CommonAppCacheScanner.IncompletePath
    ) -> ScanIncompleteIssue {
        switch issue.reason {
        case .metadataUnavailable,
             .pathIdentityChanged:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .metadataUnavailable,
                stage: .metadata
            )
        case .directoryOpenFailed:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .enumerationFailed,
                stage: .open
            )
        case .enumerationFailed,
             .deadlineExceeded,
             .entryLimitReached,
             .globExpansionLimitReached,
             .workerProtocolFailed:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .enumerationFailed,
                stage: .enumerate
            )
        case .protectedAppDataSkipped:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .tccProtectedSkipped
            )
        case .workerLaunchFailed:
            return ScanIncompleteIssue(
                path: issue.path,
                reason: .enumerationFailed,
                stage: .open
            )
        }
    }

    /// 旧版本候选的唯一计量入口。完整性证据和大小来自同一 BulkScanner 会话，
    /// 不再用 `FileManager.enumerator(errorHandler:nil)` 静默跳过失败子树。
    nonisolated private static func measureVersionedRoot(
        at url: URL,
        options: ScanOptions
    ) async -> VersionedRootScanMeasurement? {
        let scanner = BulkScanner(options: options)
        var summary: ScanSummary?
        var incompleteIssues = Set<ScanIncompleteIssue>()

        // v2026.07.16 性能回归根治：旧版本卡片只需要终态容量与完整性证据。
        // `.complete` 会为 GB 级 DeviceSupport 生成并丢弃每个 FSNode；summary-only
        // 保留相同 ScanSummary/typed issue，且不会建立无界节点队列。
        let scanSession = scanner.scanSession(root: url, delivery: .summaryOnly)
        await withTaskCancellationHandler {
            for await event in scanSession.events {
                if Task.isCancelled { break }
                switch event {
                case .permissionDenied(let path):
                    incompleteIssues.insert(ScanIncompleteIssue(path: path, reason: .permissionDenied))
                case .tccProtectedSkipped(let path):
                    incompleteIssues.insert(ScanIncompleteIssue(path: path, reason: .tccProtectedSkipped))
                case .failed(let error):
                    let issue: ScanIncompleteIssue
                    switch scanFailureScope(error, rootPath: url.path) {
                    case .root(let value), .descendant(let value):
                        issue = value
                    }
                    incompleteIssues.insert(issue)
                    GSYLog.warning(.scan,
                                   "KnownVersionedRoots BulkScanner failed root=\(url.path) error=\(error)")
                case .incomplete(let issue):
                    incompleteIssues.insert(issue)
                case .finished(let value):
                    summary = value
                    incompleteIssues.formUnion(value.incompleteIssues)
                    if value.completionStatus == .partial,
                       value.incompleteIssues.isEmpty {
                        incompleteIssues.insert(ScanIncompleteIssue(
                            path: url.path,
                            reason: .enumerationFailed,
                            stage: .enumerate
                        ))
                    }
                    if value.permissionDeniedCount > 0,
                       !incompleteIssues.contains(where: { $0.reason == .permissionDenied }) {
                        incompleteIssues.insert(ScanIncompleteIssue(
                            path: url.path,
                            reason: .permissionDenied
                        ))
                    }
                    if value.tccProtectedSkippedCount > 0,
                       !incompleteIssues.contains(where: { $0.reason == .tccProtectedSkipped }) {
                        incompleteIssues.insert(ScanIncompleteIssue(
                            path: url.path,
                            reason: .tccProtectedSkipped
                        ))
                    }
                case .heartbeat, .node, .nodes, .progress, .cacheDirTagged:
                    break
                }
            }
        } onCancel: {
            scanSession.cancel()
        }
        await scanSession.waitForTermination()
        guard !Task.isCancelled else { return nil }
        guard let summary else {
            incompleteIssues.insert(ScanIncompleteIssue(
                path: url.path,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
            return VersionedRootScanMeasurement(
                allocatedBytes: 0,
                logicalBytes: 0,
                fileCount: 0,
                incompleteIssues: incompleteIssues
            )
        }
        return VersionedRootScanMeasurement(
            allocatedBytes: summary.totalAllocatedBytes,
            logicalBytes: summary.totalLogicalBytes,
            fileCount: summary.fileCount,
            incompleteIssues: incompleteIssues
        )
    }

    nonisolated private static func modificationDate(at url: URL) -> Date? {
        do {
            return try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        } catch {
            // Versioned-root mtime is optional presentation metadata. Preserve the candidate and
            // record the technical failure only in structured diagnostics; do not expose raw
            // URL/error text through RowItem.
            GSYLog.debug(
                .scan,
                "scan.versioned.mtime.unavailable path=\(url.path) error=\(String(describing: error))"
            )
            return nil
        }
    }

    /// v1.3：多根并行扫描入口（"全部推荐扫描"）。
    ///
    /// 解决用户反馈："扫描看起来还是只有一个目录在动" —— 走 [MultiRootScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
    /// 把 ScanCategories.recommended() 的 5 个根 **同时** 启动，每根独立 BulkScanner + InodeSet + 6 worker，
    /// 真正打满 M*6 个并行工作单元。
    ///
    /// 实现要点：
    /// - currentRootPath 设 "(多目录)"：UI 在 finishedEmpty / 树视图等场景需要一个非 nil 占位；
    ///   这里不能用具体的某根路径（否则 5 根中只能选 1 个展示，逻辑混乱）。
    /// - activeCategoryID = multiRootCategoryID 哨兵：与单根 scan 共用 `runScan` 防过期事件机制；
    ///   现有 `cancel()` 把 activeCategoryID 清空 → 旧 stream 残留事件自动丢弃。
    /// - perRootProgress 预填 5 条：UI 立刻能渲染 5 行"扫描中…"，不等第一个事件到达。
    /// - bucket key 形如 "{rootPath}/{firstSegment}"：现有 ingest 走的是 rootPath 前缀切割，
    ///   多根时不同根不会撞 key（路径前缀不同），现有逻辑无需改。
    public func scanRecommended(includeHidden: Bool = true) {
        scanMultiRootCategories(
            ScanCategories.recommended(home: home),
            includeHidden: includeHidden,
            categoryID: ScanCoordinator.multiRootCategoryID,
            sentinelPath: ScanCoordinator.multiRootSentinelPath,
            logName: "recommended"
        )
    }

    /// Smart Care 的“系统与日志”真实扫描入口。
    ///
    /// 普通模式的应用缓存与开发缓存各自有独立 scanner；这里仅扫描
    /// [ScanCategories.smartCareCore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCategory.swift)
    /// 声明的非重叠根，不能复用包含 `~/Library/Caches` 与 DerivedData 的完整推荐计划。
    public func scanSmartCareCore(includeHidden: Bool = true) {
        scanMultiRootCategories(
            ScanCategories.smartCareCore(home: home),
            includeHidden: includeHidden,
            categoryID: ScanCoordinator.smartCareCoreCategoryID,
            sentinelPath: ScanCoordinator.smartCareCoreSentinelPath,
            logName: "smart_care.core"
        )
    }

    /// 推荐扫描与 Smart Care core 的共享多根启动器。
    ///
    /// 白名单必须在真正创建 `MultiRootScanner` 之前完成加载；这样从第一个 node 开始，
    /// 本轮 `publishSnapshot` 使用的就是同一份不可变快照，不存在首帧暴露已加白路径的窗口。
    private func scanMultiRootCategories(_ categories: [ScanCategory],
                                         includeHidden: Bool,
                                         categoryID: String,
                                         sentinelPath: String,
                                         logName: String) {
        schedulePrimaryScanIntent(.multiRoot(logName)) { [weak self] in
            self?.startMultiRootCategories(
                categories,
                includeHidden: includeHidden,
                categoryID: categoryID,
                sentinelPath: sentinelPath,
                logName: logName
            )
        }
    }

    private func startMultiRootCategories(_ categories: [ScanCategory],
                                          includeHidden: Bool,
                                          categoryID: String,
                                          sentinelPath: String,
                                          logName: String) {
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        allocationRebaseline = { [weak self] in
            self?.scanMultiRootCategories(categories, includeHidden: includeHidden,
                categoryID: categoryID, sentinelPath: sentinelPath, logName: logName)
        }
        verdictCacheHits = 0
        verdictCacheMisses = 0
        largeFileTopNOnlyScan = false
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        expectedTotalBytes = nil
        currentRootPath = sentinelPath
        snapshot = ScanSnapshot(categoryID: categoryID, rows: [],
                                totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)
        liveProgress.reset(categoryID: categoryID, startedAt: startedAt)
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        activeCategoryID = categoryID
        let generation = scanGeneration
        guard let reservation = activePrimaryReservation else { return }
        whitelistSnapshot = []

        treeFetchGeneration = UUID()

        // 预填 perRootProgress，UI 立刻能看到 5 行"扫描中…"行；
        // 后续 .node / .finished 事件再原地累加 / 翻 isFinished。
        var initial: [String: PerRootProgress] = [:]
        for c in categories {
            initial[c.rootPath] = PerRootProgress(
                rootPath: c.rootPath,
                title: c.title,
                titleLocalizationKey: c.titleIsLocalizationKey ? c.title : nil,
                titlePresentation: c.titlePresentation
            )
        }
        syncPerRootPublished(from: initial)
        // v1.3.zz 性能修复：staging 同步初始化，让 .node 事件累计的目标存在
        perRootStaging = initial
        notePruneSourceMutation()

        let roots = categories.map(\.rootURL)
        GSYLog.notice(.flow, "scan.\(logName).start roots=\(roots.map(\.path).joined(separator: ",")) includeHidden=\(includeHidden)")
        let activeID = categoryID
        // v2026.07.16：推荐扫描不再并发启动第二轮 TreeSizeEstimator。真实扫描 progress
        // 已提供文件数与容量；重复估算既不参与最终结果，也无法可靠提供 ETA。
        // v2026.07.18 privacy contract: granted/unknown/denied only affect how OS failures
        // are presented. They never disable the product's TCC hard-skip namespace.
        let respectTCC = Self.shouldRespectTCCSkipList(fdaStatus: fdaStatus)
        let options = ScanOptions(includeHidden: includeHidden,
                                  staySingleVolume: true,
                                  respectTCCSkipList: respectTCC)
        let whitelistStore = self.whitelistStore
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard let self,
                  self.ownsScan(categoryID: activeID, generation: generation) else { return }
            self.whitelistSnapshot = whitelist
            // v1.5 性能修复：推荐扫描 5 根固定，但常见命中 ~/Library/Caches、
            // ~/Library/Logs、~/Library/Application Support 等大根；并发上限 3 足够
            // 让吞吐拉满又不会让整机 IO 子系统拥塞（详见 MultiRootScanner.scan 注释）。
            await self.runMultiRootScan(roots: roots, options: options,
                                        generation: generation,
                                        reservation: reservation,
                                        categoryID: activeID,
                                        maxConcurrentRoots: 3)
        }
    }

    /// v1.4：开发者构建产物多根并行扫描入口。
    ///
    /// 流程：
    /// 1. [DevArtifactScanner] 在 `~` 下勘察命中规则的目录（不计字节，只列 URL + 规则元数据）；
    /// 2. 用 [DevArtifactRule.Verdict] 过滤——本入口只接收 `.safe` + `.confirm` 两类，
    ///    勾选默认值由 verdict 决定（safe 默认勾选、confirm 默认不勾，与 ScanCategory 体系一致）；
    /// 3. 把命中目录转成多根，复用 [runMultiRootScan]——这样 UI 全套（perRootProgress / footerBar /
    ///    treeBrowser / safety / TrashPipeline）零改动；
    /// 4. 命中数为 0 时直接 publish 一个 finished=true 的空 snapshot，避免 UI 无限"扫描中…"。
    ///
    /// - Parameters:
    ///   - includeHidden: 透传 ScanOptions.includeHidden（开发者产物里很多隐藏目录如 `.next`，应保持 true）
    ///   - enabledRuleIDs: 启用的规则 ID 集合，缺省 = 全部启用；调用方传入用户设置中关掉的差集
    public func scanDeveloper(includeHidden: Bool = true,
                              enabledRuleIDs: Set<String> = DevArtifactRules.allIDs) {
        schedulePrimaryScanIntent(.developerArtifacts) { [weak self] in
            self?.startDeveloperScan(
                includeHidden: includeHidden,
                enabledRuleIDs: enabledRuleIDs
            )
        }
    }

    private func startDeveloperScan(
        includeHidden: Bool,
        enabledRuleIDs: Set<String>
    ) {
        wasCancelled = false
        resetDeletionStateForNewScanSession()
        allocationRebaseline = { [weak self] in
            self?.scanDeveloper(includeHidden: includeHidden, enabledRuleIDs: enabledRuleIDs)
        }
        // v1.3 P0-C：开发者构建产物扫描典型命中 30+ 根 × 每根上万 node，
        // 若 enableTreeDeepIndex 开着，MainActor ingest 会被祖先回溯 + index 写入打挂。
        // 强制关闭，让 TreeBrowser 走按需子树扫描路径（与全盘扫一致策略）。
        enforceOnDemandTreeProductEntry(.developerArtifacts)
        verdictCacheHits = 0
        verdictCacheMisses = 0
        largeFileTopNOnlyScan = false
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        expectedTotalBytes = nil
        currentRootPath = ScanCoordinator.developerSentinelPath
        snapshot = ScanSnapshot(categoryID: ScanCoordinator.developerCategoryID, rows: [],
                                totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)
        liveProgress.reset(
            categoryID: ScanCoordinator.developerCategoryID,
            startedAt: startedAt
        )
        isScanning = true
        scanPhase = .scanning
        lastError = nil
        terminalFailure = nil
        resetIncompleteEvidence()
        // v1.3 P0-D：dev 扫描入口归零截断标志，避免上次的状态污染本次 banner。
        devArtifactDidTruncate = false
        devArtifactDidTimeout = false
        activeCategoryID = ScanCoordinator.developerCategoryID
        let generation = scanGeneration
        guard let reservation = activePrimaryReservation else { return }
        whitelistSnapshot = []

        treeFetchGeneration = UUID()

        // v2026.07.18 privacy contract: developer discovery also preserves the unconditional
        // TCC hard-skip boundary; FDA must not silently widen a different scan entry.
        let respectTCC = Self.shouldRespectTCCSkipList(fdaStatus: fdaStatus)
        let options = ScanOptions(includeHidden: includeHidden,
                                  staySingleVolume: true,
                                  respectTCCSkipList: respectTCC)
        let activeID = ScanCoordinator.developerCategoryID
        let activeStartedAt = startedAt
        let whitelistStore = self.whitelistStore
        // Candidate construction is pure. Physical existence checks cross the nonisolated async
        // discovery boundary below; even a handful of stale/unmounted developer paths must never
        // make the scan button synchronously wait on FileManager from MainActor.
        let knownDeveloperRootCandidates = ScanCategories.developerCacheRoots(home: home)

        // One orchestration task owns both discovery and the subsequent MultiRoot stage. The old
        // implementation overwrote `scanTask` from inside itself, losing cancellation/settlement
        // ownership exactly while a second filesystem producer was starting.
        scanTask = Task { [weak self] in
            let whitelist = await whitelistStore.snapshotPaths()
            guard !Task.isCancelled,
                  let owner = self,
                  owner.ownsScan(categoryID: activeID, generation: generation) else { return }
            owner.whitelistSnapshot = whitelist
            let homeStr = owner.home
            let partialSyncBox = PartialSyncWindow()
            let onPartial: @Sendable ([DevArtifactScanner.Hit]) -> Void = { [weak self] batch in
                Task { @MainActor [weak self] in
                    guard let self,
                          await self.waitForPruneTransactionBarrier(),
                          self.ownsScan(categoryID: activeID, generation: generation)
                    else { return }
                    var stagingDidChange = false
                    for hit in batch {
                        let path = hit.url.path
                        if Self.isWhitelisted(path, in: whitelist)
                            || self.isDeletedTombstoned(path)
                            || self.perRootStaging[path] != nil { continue }
                        let shortPath = self.shortenPath(path, home: homeStr)
                        let suffix = " · \(shortPath)"
                        let titleBase: LocalizedTextDescriptor = hit.displayName.hasPrefix("rule.")
                            ? .catalog(hit.displayName)
                            : .verbatim(hit.displayName)
                        self.perRootStaging[path] = PerRootProgress(
                            rootPath: path,
                            title: hit.displayName + suffix,
                            titleLocalizationKey: hit.displayName,
                            titleSuffix: suffix,
                            titlePresentation: titleBase.appendingVerbatim(suffix)
                        )
                        stagingDidChange = true
                    }
                    if stagingDidChange { self.notePruneSourceMutation() }
                    let now = Date().timeIntervalSinceReferenceDate
                    if now - partialSyncBox.lastSync >= 0.4 {
                        partialSyncBox.lastSync = now
                        self.publishDeveloperDiscoveryProgress()
                    }
                }
            }

            guard let producerLaunch = owner.primaryScanAdmissionRegistry.reserveProducerLaunch(
                reservation: reservation,
                kind: .developerDiscovery
            ) else { return }
            let producer = Task.detached(priority: .userInitiated) {
                let producerStartedAt = DispatchTime.now().uptimeNanoseconds
                let knownRoots = await Self.existingDirectoryCategories(
                    knownDeveloperRootCandidates
                )
                let scanner = DevArtifactScanner(options: .init(
                    enabledRuleIDs: enabledRuleIDs
                ))
                let result = await scanner.discoverWithMetadataStreamed(
                    home: URL(fileURLWithPath: homeStr),
                    flushEvery: 20,
                    onPartial: onPartial
                )
                let elapsed = Double(
                    DispatchTime.now().uptimeNanoseconds - producerStartedAt
                ) / 1_000_000_000
                return DeveloperDiscoveryProducerOutput(
                    knownRoots: knownRoots,
                    discovery: result,
                    elapsed: elapsed
                )
            }
            let producerTermination = Task.detached(priority: .userInitiated) {
                _ = await producer.value
            }
            guard let producerLeaseID = owner.primaryScanAdmissionRegistry.activateProducer(
                launch: producerLaunch,
                reservation: reservation,
                cancel: { producer.cancel() },
                termination: producerTermination
            ) else {
                await producerTermination.value
                owner.primaryScanAdmissionRegistry.abandonProducerLaunch(
                    producerLaunch,
                    reservation: reservation
                )
                return
            }
            let output = await withTaskCancellationHandler {
                await producer.value
            } onCancel: {
                producer.cancel()
            }
            await producerTermination.value
            let payloadOwner = ProducerPayloadOwner(output)
            owner.finishPrimaryFilesystemProducer(
                leaseID: producerLeaseID,
                reservation: reservation,
                finishesPipeline: false
            )
            guard owner.ownsScan(categoryID: activeID, generation: generation) else {
                await payloadOwner.retire()
                return
            }

            guard let prepared = await Self.prepareDeveloperDiscoveryPresentation(
                owner: payloadOwner,
                whitelist: whitelist,
                baseStaging: owner.perRootStaging,
                tombstones: owner.deletedPathTombstones.matcher,
                home: homeStr
            ), owner.ownsScan(categoryID: activeID, generation: generation) else { return }
            owner.devArtifactDidTruncate = prepared.didTruncate
            owner.devArtifactDidTimeout = prepared.didTimeout
            owner.replaceIncompleteEvidence(with: prepared.incompleteIssues)
            let discoveryWasIncomplete = !Self.developerDiscoveryIsComplete(
                didTimeout: prepared.didTimeout,
                didTruncate: prepared.didTruncate,
                hasIncompleteEvidence: !prepared.incompleteIssues.isEmpty
            )
            GSYLog.notice(
                .scan,
                "scan.developer.discovery.terminal roots=\(prepared.roots.count) "
                    + "issues=\(prepared.incompleteIssues.count) "
                    + "timeout=\(prepared.didTimeout) truncated=\(prepared.didTruncate) "
                    + "producer_elapsed=\(String(format: "%.3f", prepared.producerElapsed))s"
            )

            if prepared.roots.isEmpty {
                owner.finishPrimaryPipeline(reservation: reservation)
                guard owner.ownsScan(categoryID: activeID, generation: generation) else { return }
                owner.resetPerRootPublished()
                owner.perRootStaging = [:]
                owner.notePruneSourceMutation()
                owner.snapshot = ScanSnapshot(
                    categoryID: activeID,
                    rows: [],
                    totalBytes: 0,
                    scannedFileCount: 0,
                    isFinished: true,
                    elapsed: Date().timeIntervalSince(activeStartedAt),
                    isComplete: !discoveryWasIncomplete
                )
                owner.isScanning = false
                owner.scanPhase = .idle
                owner.lastFinishedCategoryID = activeID
                owner.scanTask = nil
                owner.activeCategoryID = nil
                owner.recordTerminalPerformanceEvidence(
                    producerElapsed: prepared.producerElapsed
                )
                owner.refreshVolumeCapacity()
                GSYLog.notice(.scan, "scan.developer.finish reason=no_roots")
                return
            }

            owner.perRootStaging = prepared.staging
            owner.notePruneSourceMutation()
            owner.publishDeveloperDiscoveryProgress()
            guard owner.ownsScan(categoryID: activeID, generation: generation) else { return }
            await owner.runMultiRootScan(
                roots: prepared.roots,
                options: options,
                generation: generation,
                reservation: reservation,
                categoryID: activeID,
                maxConcurrentRoots: 2,
                upstreamWasIncomplete: discoveryWasIncomplete
            )
        }
    }

    /// Filesystem existence is producer work even when the candidate list is small. As a
    /// nonisolated async function this executes on the generic executor and cooperatively stops
    /// between paths when the owning scan is cancelled or replaced.
    nonisolated private static func existingDirectoryCategories(
        _ candidates: [ScanCategory]
    ) async -> [ScanCategory] {
        var existing: [ScanCategory] = []
        existing.reserveCapacity(candidates.count)
        for category in candidates {
            guard !Task.isCancelled else { return [] }
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(
                atPath: category.rootPath,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                existing.append(category)
            }
        }
        return existing
    }

    /// v1.4：把 `~/Foo/Bar/node_modules` 缩成 `~/Foo/Bar` 形式以便 UI 展示。
    private nonisolated func shortenPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func runScan(rootURL: URL,
                         displayRootPath: String,
                         categoryID: String,
                         generation: UUID,
                         reservation: PrimaryScanAdmissionRegistry.ReservationToken,
                         includeHidden: Bool,
                         staySingleVolume: Bool = true,
                         largeFileTopNOnly: Bool = false) async {
        // v2026.07.19 regression fix: reserve the App-level producer launch before constructing
        // a scanner/session. No replacement may observe an idle registry while filesystem I/O is
        // already able to start.
        guard let producerLaunch = primaryScanAdmissionRegistry.reserveProducerLaunch(
            reservation: reservation,
            kind: .singleRoot
        ) else { return }
        // 物理枚举根与公开展示根在整盘会话中刻意不同：
        // `/System/Volumes/Data` 提供完整数据，`/` 保持 Finder/用户熟悉的路径合同。
        let rootPath = displayRootPath
        // v1.0 T2：把 AppSettings.showHidden 透传到 ScanOptions
        // v1.0 T5：整盘扫描时叠加 staySingleVolume=true（详见 ScanOptions 文档）
        // v2026.07.18 privacy contract: TCCSkipList is a product hard-skip boundary, not a
        // permission fallback. Every FDA state must therefore use the same scan scope.
        let respectTCC = Self.shouldRespectTCCSkipList(fdaStatus: fdaStatus)
        let options = ScanOptions(
            includeHidden: includeHidden,
            staySingleVolume: staySingleVolume,
            respectTCCSkipList: respectTCC
        )
        let scanner = BulkScanner(options: options)
        // v2026.07.16 性能回归根治：默认 Tree 已经按需展开，不需要把全树节点送到
        // MainActor。普通扫描只接收后台一级聚合；Large Files 只接收后台 Top-N；只有
        // 显式 deep-index 调试/测试仍保留完整 node stream。
        let delivery: BulkScanner.EventDelivery
        if largeFileTopNOnly {
            delivery = .largeFiles(
                minimumAllocatedBytes: largeFileMinBytes,
                maximumResults: Self.largeFileTopNCapacity
            )
        } else if enableTreeDeepIndex {
            delivery = .complete
        } else {
            delivery = .topLevel
        }
        let usesProjection = delivery != .complete
        var lastEmit = Date(timeIntervalSince1970: 0)
        // v1.3.z 性能修复（App 实测 90s 定位结论）：
        // 主线程 sample 显示 95% 时间在 SwiftUI ViewGraph flushTransactions / MainView.body 重算，
        // 节流 150ms = 每秒 6.7 帧 body，扫 90s = 600 次全 body 重计算（results / statusBar /
        // footerBar / selectedRows.filter）；扫描期 UI 没人盯帧率，250-400ms 完全够看到字节跳动。
        // 抬到 0.40 后预期 ViewGraph 重算次数降到 ~2.5 fps，主线程让出给 ingest。
        let throttle: TimeInterval = 0.40
        // v1.3.y / v2026.06.25 性能修复：
        // BulkScanner 会把一个目录下的多个 node 合并成 `.nodes(arr)`。旧实现按"事件数"
        // 计数让出，百万级文件扫描时一个事件可能代表几百个 node，MainActor 仍会被连续
        // 占住太久。这里改为按实际 node 数计数，让 SwiftUI / RunLoop 有稳定空档。
        let yieldEvery = 256
        var consumedSinceYield = 0
        var finishedCompletionStatus: ScanCompletionStatus?
        var finishedSummaryIssuesWereEmpty: Bool?
        var finishedProducerElapsed: TimeInterval?
        var sawRootFailure = false
        var terminalProjections: [TerminalProjectionEnvelope] = []

        let pathNamespace: ScanPathNamespace? = categoryID == ScanCategory.fullDisk.id
            ? fullDiskPathNamespace
            : nil
        let scanSession = scanner.scanSession(
            root: rootURL,
            delivery: delivery,
            pathNamespace: pathNamespace,
            topLevelProjectionRootPath: rootPath == "/" ? "/" : nil,
            allocationLedger: beginAllocationCatalog(roots: [displayRootPath], options: options)
        )
        let producerTermination = Task.detached(priority: .userInitiated) {
            await scanSession.waitForTermination()
        }
        guard let producerLeaseID = primaryScanAdmissionRegistry.activateProducer(
            launch: producerLaunch,
            reservation: reservation,
            cancel: { scanSession.cancel() },
            termination: producerTermination
        ) else {
            await producerTermination.value
            primaryScanAdmissionRegistry.abandonProducerLaunch(
                producerLaunch,
                reservation: reservation
            )
            return
        }
        await withTaskCancellationHandler {
            for await event in scanSession.events {
                if Task.isCancelled { break }
                guard await waitForPruneTransactionBarrier() else { break }
            // v1.3 防 [坑 1]：旧 stream 残留事件污染新 snapshot。
            // activeCategoryID 在 cancel() 里被清空、在新 scan 入口被重新打上；只要本次 stream 已被
            // 新一轮 scan 取代，下面这一行就会让旧 for-await 立刻跳出循环，不再写 buckets/dirIndex。
            guard ownsScan(categoryID: categoryID, generation: generation) else { break }
            var consumedThisEvent = 1
            switch event {
            case .heartbeat:
                // 只证明 producer 在超宽目录内仍有进展，不改变容量/文件数。
                break
            case .node(let node):
                incrementalNodeDeliveryCount &+= 1
                if largeFileTopNOnly {
                    ingestLargeFileNode(node, rootPath: rootPath)
                } else {
                    ingest(node: node, rootPath: rootPath)
                }
            case .nodes(let arr):
                incrementalNodeDeliveryCount &+= arr.count
                // Step 13B micro-batch：批量 ingest，减少跨 actor hop 开销。
                // 大文件入口只保留 Top-N，不构建通用树形/主列表索引。
                for node in arr {
                    if largeFileTopNOnly {
                        ingestLargeFileNode(node, rootPath: rootPath)
                    } else {
                        ingest(node: node, rootPath: rootPath)
                    }
                }
                consumedThisEvent = max(1, arr.count)
            case .progress(let bytes, let count):
                // 投影扫描没有逐节点 ingest；进度是 ScanStats 的单调绝对值。
                // 只用于扫描期展示，终态仍由同一轮 ScanSummary 精确覆盖。
                if usesProjection {
                    totalBytes = max(totalBytes, bytes)
                    scannedFiles = max(scannedFiles, count)
                }
            case .finished(let summary):
                finishedCompletionStatus = summary.completionStatus
                finishedSummaryIssuesWereEmpty = summary.incompleteIssues.isEmpty
                finishedProducerElapsed = summary.elapsed
                if usesProjection {
                    totalBytes = summary.totalAllocatedBytes
                    scannedFiles = summary.fileCount
                    if case .topLevel = summary.projection {
                        // Terminal projection width is unbounded. Freeze producer output now;
                        // merge/verdict/filter/sort are prepared off MainActor after settlement.
                        terminalProjections.append(TerminalProjectionEnvelope(
                            projection: summary.projection,
                            rootPath: rootPath
                        ))
                    } else {
                        // Large Files is explicitly capped at Top-N; other projection kinds do
                        // not materialize visible rows in ScanCoordinator.
                        applyProjection(summary.projection, rootPath: rootPath)
                    }
                }
                for issue in summary.incompleteIssues {
                    recordIncompleteIssue(issue, displayRootPath: rootPath)
                }
                if summary.completionStatus == .partial,
                   summary.incompleteIssues.isEmpty {
                    recordIncompleteIssue(ScanIncompleteIssue(
                        path: rootPath,
                        reason: .enumerationFailed,
                        stage: .enumerate
                    ), displayRootPath: rootPath)
                }
            case .failed(let error):
                if consumeScanFailure(
                    error,
                    rootPath: rootPath,
                    displayRootPath: rootPath,
                    publishPresentationImmediately: !usesProjection
                ) {
                    sawRootFailure = true
                }
            case .incomplete(let issue):
                recordIncompleteIssue(issue, displayRootPath: rootPath)
            case .permissionDenied(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .permissionDenied
                ), displayRootPath: rootPath)
            case .tccProtectedSkipped(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .tccProtectedSkipped
                ), displayRootPath: rootPath)
            case .cacheDirTagged:
                // v1.5 Step 8：CACHEDIR.TAG 命中——单根扫描忽略；
                // safe 候选由后续 SafetyEngine 路径级 verdict 兜底，这里不重复 banner。
                break
            }

            // 节流：≥150ms 推一次（PITFALLS §5.4）
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                if usesProjection {
                    publishLiveProgress(categoryID: categoryID)
                } else {
                    publishSnapshot(categoryID: categoryID, finished: false)
                }
            }

            // 性能修复：每 N 个事件让出一次主 actor（详见上方注释）
                consumedSinceYield += consumedThisEvent
                if consumedSinceYield >= yieldEvery {
                    consumedSinceYield = 0
                    await Task.yield()
                }
            }
        } onCancel: {
            scanSession.cancel()
        }
        // Stream closure is not the ownership boundary. Await the exact producer handle, then
        // move the unbounded raw projection to an off-MainActor owner before releasing its lease.
        // Sorting and terminal presentation intentionally happen after filesystem ownership ends.
        await producerTermination.value
        await freezeAllocationCatalog(expectedGeneration: generation)
        let projectionOwner = TerminalProjectionRetirementWorker(
            projections: terminalProjections
        )
        terminalProjections = []
        finishPrimaryFilesystemProducer(
            leaseID: producerLeaseID,
            reservation: reservation,
            finishesPipeline: true
        )
        // v1.3 防 [坑 1] 收尾：只有当本次 runScan 仍是当前活跃 scan 时才标记 finished。
        // 若已被新 scan 取代，本次"完成"事件不应该覆盖新的 in-progress snapshot；
        // isScanning / scanTask 由新 scan 自己管理，这里也不要重置。
        guard ownsScan(categoryID: categoryID, generation: generation) else {
            await projectionOwner.retire()
            return
        }
        let completedSuccessfully = !Task.isCancelled
            && !sawRootFailure
            && finishedCompletionStatus == .complete
        if sawRootFailure
            || finishedCompletionStatus == nil
            || (finishedCompletionStatus == .partial
                && finishedSummaryIssuesWereEmpty == true) {
            // 流关闭/失败却没有完整 summary 时，不能只把 UI 画成 partial；删除预检
            // 还必须得到根级证据，否则父根仍可能被当成完整结果移入废纸篓。
            recordIncompleteIssue(ScanIncompleteIssue(
                path: rootPath,
                reason: .enumerationFailed,
                stage: .enumerate
            ), displayRootPath: rootPath)
        }
        // 精确 child issue 由结构化 banner/Tree lock 表达，绝不能再塞进 lastError
        // 变成一条看似整轮崩溃的红字。只有根事件流没有可信 summary，或 summary
        // 自己只给出 opaque partial，才需要根级通用错误。
        let hasOpaqueRootFailure = finishedCompletionStatus == nil
            || (finishedCompletionStatus == .partial
                && finishedSummaryIssuesWereEmpty == true)
        let terminalMessage: String? = !completedSuccessfully
            && (sawRootFailure || hasOpaqueRootFailure)
            && lastError == nil
            ? AppLocalization.string("main.scan.incomplete", locale: presentationLocale)
            : nil
        let projectionsForPresentation = await projectionOwner.snapshot()
        let preparedTransaction = await prepareTerminalPresentation(
            projections: projectionsForPresentation,
            categoryID: categoryID,
            generation: generation
        )
        scheduleTerminalProjectionOwnerRetirementAfterCommit(projectionOwner)
        guard let transaction = preparedTransaction else { return }
        applyPreparedPerRootProjection(transaction.perRoot)
        if let evidence = transaction.evidence {
            applyPreparedIncompleteEvidenceProjection(evidence)
        }
        if let terminalMessage {
            lastError = terminalMessage
            if finishedCompletionStatus == nil {
                terminalFailure = TerminalFailure(message: terminalMessage)
            }
        }
        publishPreparedTerminalSnapshot(
            categoryID: categoryID,
            complete: completedSuccessfully,
            presentation: transaction.presentation
        )
        liveProgress.finish(with: snapshot)
        scheduleTerminalRetirement(transaction.worker)
        recordTerminalPerformanceEvidence(producerElapsed: finishedProducerElapsed)
        // v2026.07.17 performance-regression evidence: scanner-side elapsed alone cannot prove
        // the real App has drained its MainActor/SwiftUI consumer. Emit a distinct UI-owned
        // terminal marker only after the authoritative finished snapshot has been published.
        // `incrementalNodes` must stay zero for production projection modes; a future call-site
        // accidentally reconnecting `.complete` to MainActor becomes visible in the same record.
        GSYLog.notice(
            .flow,
            "scan.ui.terminal category=\(categoryID) generation=\(generation.uuidString) delivery=\(Self.diagnosticDeliveryName(delivery)) complete=\(completedSuccessfully) producerElapsed=\(Self.diagnosticSeconds(lastProducerTerminalElapsed)) drainLag=\(Self.diagnosticSeconds(lastConsumerDrainLag)) elapsed=\(String(format: "%.3f", snapshot.elapsed))s files=\(snapshot.scannedFileCount) bytes=\(snapshot.totalBytes) rows=\(snapshot.rows.count) incrementalNodes=\(incrementalNodeDeliveryCount)"
        )
        isScanning = false
        scanPhase = .idle
        scanTask = nil
        activeCategoryID = nil
        // v1.3.zz 流式修复 ③：扫描结束后清掉 treeChildrenCache 里"扫描期间被钉空"
        // 的所有项目，让 TreeBrowserView 下一帧重新拉一次"finalize 之后的全量结果"。
        // 之所以放在 isScanning=false 之后：directChildren 写回逻辑判 isScanning 决定是否
        // 钉 cache；这里清完后下一次 fetch 即便 rows 仍然空也会被正常缓存（终态空 = 真没数据）。
        invalidateTreeCacheAfterScan()
        // v1.3：扫描完成后刷新一次容量，与 Finder/系统设置口径一致。
        // 删除发生时另行调 refreshVolumeCapacity（见 MainView.performDelete）。
        refreshVolumeCapacity()
    }

    /// v1.3：多根并行扫描的主消费循环。
    ///
    /// 与 [runScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的差别：
    /// - 事件流是 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)，
    ///   带 `rootPath` 信封，`ingest(node:rootPath:)` 直接拿到正确根；
    /// - 每个 .node 同时累加全局 totalBytes / scannedFiles **和** 该根的 perRootProgress；
    /// - 每个 .finished 翻该根的 isFinished=true；所有根 finish 后 stream 自然关闭。
    private func runMultiRootScan(roots: [URL], options: ScanOptions,
                                  generation: UUID,
                                  reservation: PrimaryScanAdmissionRegistry.ReservationToken,
                                  categoryID: String,
                                  maxConcurrentRoots: Int = 4,
                                  upstreamWasIncomplete: Bool = false) async {
        // v2026.07.16：重复根、尾斜杠等价根和祖先/后代根不能并发各扫一遍；否则
        // 同一 inode/容量被重复统计，Set 终态判断还可能在第一份重复根完成时提前退出。
        let normalizedRoots = Self.minimalNonOverlappingRoots(roots)
        let normalizedRootPaths = Set(normalizedRoots.map(\.path))
        if normalizedRoots.count != roots.count {
            perRootStaging = perRootStaging.filter { normalizedRootPaths.contains($0.key) }
            notePruneSourceMutation()
            await syncPerRootPublishedOffMain(from: perRootStaging)
            GSYLog.notice(
                .scan,
                "scan.multi.roots.normalized input=\(roots.count) effective=\(normalizedRoots.count)"
            )
        }
        // 默认树形结果按需展开，因此多根扫描也只需要每根一级投影。显式 deep-index
        // 才保留完整节点合同；推荐/Smart Care/Developer 的生产路径默认全部走投影。
        let delivery: BulkScanner.EventDelivery = enableTreeDeepIndex ? .complete : .topLevel
        let usesProjection = delivery != .complete
        let expectedRootPaths = normalizedRootPaths
        var finishedRootPaths = Set<String>()
        var failedRootPaths = Set<String>()
        var maximumProducerElapsed: TimeInterval?
        // Developer discovery may time out/truncate before the per-root scanners start.
        // Discovered roots can still be measured precisely, but the overall session must remain partial.
        var sawPartialRoot = upstreamWasIncomplete
        var sawRootFailure = false
        var lastEmit = Date(timeIntervalSince1970: 0)
        var terminalProjections: [TerminalProjectionEnvelope] = []
        // v1.3.z 性能修复：见 runScan 同名注释。多根模式 throttle 同步抬到 0.40。
        let throttle: TimeInterval = 0.40
        // v1.3.y 性能修复：见 runScan 同名注释。多根模式同样需要让出主 actor。
        // v2026.06.21 修复 #4（卡顿+超长）：
        //   - 旧实现 `yieldEvery=256` 是按**事件数**计，而 `.nodes(arr)` 一个事件可能含
        //     几百个 node，主线程实际处理时间远超字面值。dev scan discover 命中几十根 +
        //     每根几万 node 时，主线程被 ingest 连续占住 200~500ms，列表滑动直接卡死。
        //   - 改为按**实际处理的 node 个数**累加：`.node` 计 1、`.nodes(arr)` 计 `arr.count`。
        //   - 阈值降到 96：node 路径上典型 ingest ~5–15µs，96 节点 ≈ 0.5–1.5ms 让出一次，
        //     既能保证 ProMotion 120Hz 滑动 (8.3ms/帧) 有足够主线程空隙，又不让 ingest
        //     吞吐被 yield 反噬（一次 await 调度本身有几十微秒成本）。
        let yieldEvery = 96
        var consumedSinceYield = 0

        // The normalization/projection above is presentation-only. Register the producer launch
        // immediately before constructing the MultiRoot scanner and crossing its async session
        // creation boundary, so admission covers exactly real filesystem ownership.
        guard let producerLaunch = primaryScanAdmissionRegistry.reserveProducerLaunch(
            reservation: reservation,
            kind: .multiRoot
        ) else { return }
        let scanner = MultiRootScanner(options: options)
        let multiRootSession = await scanner.scanSession(
            roots: normalizedRoots,
            maxConcurrentRoots: maxConcurrentRoots,
            delivery: delivery,
            allocationLedger: beginAllocationCatalog(roots: normalizedRoots.map(\.path), options: options)
        )
        let producerTermination = Task.detached(priority: .userInitiated) {
            await multiRootSession.waitForTermination()
        }
        guard let producerLeaseID = primaryScanAdmissionRegistry.activateProducer(
            launch: producerLaunch,
            reservation: reservation,
            cancel: { multiRootSession.cancel() },
            termination: producerTermination
        ) else {
            await producerTermination.value
            primaryScanAdmissionRegistry.abandonProducerLaunch(
                producerLaunch,
                reservation: reservation
            )
            return
        }
        await withTaskCancellationHandler {
            for await wrapped in multiRootSession.events {
                if Task.isCancelled { break }
                guard await waitForPruneTransactionBarrier() else { break }
            // 与 runScan 同款过期事件保护：activeCategoryID 被覆盖即旧 stream 残留事件，丢弃。
            guard ownsScan(categoryID: categoryID, generation: generation) else { break }
            let rootPath = wrapped.rootPath
            if isDeletedTombstoned(rootPath) {
                if case .finished(let summary) = wrapped.event {
                    finishedRootPaths.insert(rootPath)
                    let producerElapsed = wrapped.producerCompletedAt.map {
                        max(0, $0.timeIntervalSince(startedAt))
                    } ?? summary.elapsed
                    maximumProducerElapsed = max(
                        maximumProducerElapsed ?? 0,
                        producerElapsed
                    )
                    for issue in summary.incompleteIssues {
                        recordIncompleteIssue(issue)
                    }
                    if summary.completionStatus == .partial,
                       summary.incompleteIssues.isEmpty {
                        recordIncompleteIssue(ScanIncompleteIssue(
                            path: rootPath,
                            reason: .enumerationFailed,
                            stage: .enumerate
                        ))
                    }
                    if summary.completionStatus == .partial {
                        sawPartialRoot = true
                    }
                }
                if !expectedRootPaths.isEmpty,
                   expectedRootPaths.isSubset(of: finishedRootPaths) {
                    break
                }
                continue
            }
            // v2026.06.21 修复 #4：本事件实际"处理了几个 node"，作为 yield 计数权重。
            // .node 计 1；.nodes(arr) 计 arr.count；非数据事件计 1（让控制类事件也参与 yield）。
            var consumedThisEvent = 1
            switch wrapped.event {
            case .heartbeat:
                break
            case .node(let node):
                incrementalNodeDeliveryCount &+= 1
                ingestMultiRootNode(node, rootPath: rootPath)
            case .nodes(let arr):
                incrementalNodeDeliveryCount &+= arr.count
                ingestMultiRootNodes(arr, rootPath: rootPath)
                consumedThisEvent = max(1, arr.count)
            case .progress(let bytes, let fileCount):
                if usesProjection {
                    reconcileProjectedRootAccounting(
                        rootPath: rootPath,
                        allocatedBytes: bytes,
                        logicalBytes: nil,
                        fileCount: fileCount,
                        authoritativeTerminal: false
                    )
                }
            case .finished(let summary):
                finishedRootPaths.insert(rootPath)
                let producerElapsed = wrapped.producerCompletedAt.map {
                    max(0, $0.timeIntervalSince(startedAt))
                } ?? summary.elapsed
                maximumProducerElapsed = max(
                    maximumProducerElapsed ?? 0,
                    producerElapsed
                )
                if usesProjection {
                    reconcileProjectedRootAccounting(
                        rootPath: rootPath,
                        allocatedBytes: summary.totalAllocatedBytes,
                        logicalBytes: summary.totalLogicalBytes,
                        fileCount: summary.fileCount,
                        authoritativeTerminal: true
                    )
                    if case .topLevel = summary.projection {
                        terminalProjections.append(TerminalProjectionEnvelope(
                            projection: summary.projection,
                            rootPath: rootPath
                        ))
                    } else {
                        applyProjection(summary.projection, rootPath: rootPath)
                    }
                }
                for issue in summary.incompleteIssues {
                    recordIncompleteIssue(issue)
                }
                let isPartial = summary.completionStatus == .partial
                if isPartial {
                    sawPartialRoot = true
                    if summary.incompleteIssues.isEmpty {
                        recordIncompleteIssue(ScanIncompleteIssue(
                            path: rootPath,
                            reason: .enumerationFailed,
                            stage: .enumerate
                        ))
                    }
                }
                if var p = perRootStaging[rootPath] {
                    p.isFinished = true
                    p.isPartial = isPartial
                    perRootStaging[rootPath] = p
                    notePruneSourceMutation()
                }
                // v1.3：原本 .finished 是低频事件，立刻同步到 @Published 让 UI 看到"该根已完成"。
                // v1.5 性能修复：dev scan discover 命中几十/几百根时，.finished 风暴密集
                // 触发，每个 finished 都立即整体替换 perRootProgress dict → SwiftUI 把整个
                // sidebar / statusBar / list 重 diff 一次，列表滑动直接卡死。
                // 现在 .finished 也并入下面的 throttle 统一节流（每 0.4s 同步一次），
                // 单根/少量根的扫描场景下 throttle 间隔本来就足够小，肉眼无感差异；
                // 而 dev scan 几百根场景下重画次数从 N 降到 ~elapsed/0.4，主线程立刻回归。
                //
                // v1.5 review-fix #8：小批量根（≤10）场景把 .finished 立刻 publish 出去——
                // 推荐扫描固定 5 根、整盘扫描 1 根，throttle 0.4s 滞后看得见；
                // 仅 dev scan / fullDisk discover 命中很多根时才走纯 throttle 路径。
                if perRootStaging.count <= 10 {
                    await syncPerRootPublishedOffMain(
                        from: perRootStaging,
                        commitEvidence: !usesProjection
                    )
                    lastEmit = Date()
                }
            case .failed(let error):
                let title = perRootStaging[rootPath]?.title ?? rootPath
                let isRootFailure = consumeScanFailure(
                    error,
                    rootPath: rootPath,
                    messagePrefix: title,
                    publishPresentationImmediately: !usesProjection
                )
                if isRootFailure {
                    sawRootFailure = true
                    failedRootPaths.insert(rootPath)
                } else {
                    sawPartialRoot = true
                }
                if var progress = perRootStaging[rootPath] {
                    progress.isPartial = true
                    perRootStaging[rootPath] = progress
                    notePruneSourceMutation()
                }
            case .incomplete(let issue):
                sawPartialRoot = true
                recordIncompleteIssue(issue)
            case .permissionDenied(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .permissionDenied
                ))
            case .tccProtectedSkipped(let path):
                recordIncompleteIssue(ScanIncompleteIssue(
                    path: path,
                    reason: .tccProtectedSkipped
                ))
            case .cacheDirTagged:
                // v1.5 Step 8：多根模式下命中 CACHEDIR.TAG 同样静默——SafetyEngine 兜底。
                break
            }

            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                // v1.3.zz 性能修复：节流同步 staging → @Published，让 UI 0.4s 看一次进度
                await syncPerRootPublishedOffMain(
                    from: perRootStaging,
                    commitEvidence: !usesProjection
                )
                if usesProjection {
                    publishLiveProgress(categoryID: categoryID)
                } else {
                    publishSnapshot(categoryID: categoryID, finished: false)
                }
                // Consumer still yields after each throttled frame. Production projection frames
                // now invalidate only the narrow progress views; explicit `.complete` fixtures
                // keep the historical snapshot path and also benefit from this scheduling gap.
                try? await Task.sleep(nanoseconds: 1_000_000)
            }

            // v2026.06.21 修复 #4：按"实际 node 个数"累加，不再按 event 个数。
            // .nodes(arr) 一个 event 累 arr.count，从而真正让 yield 跟主线程占用对齐。
            consumedSinceYield += consumedThisEvent
            if consumedSinceYield >= yieldEvery {
                consumedSinceYield = 0
                await Task.yield()
            }
                if !expectedRootPaths.isEmpty,
                   expectedRootPaths.isSubset(of: finishedRootPaths) {
                    break
                }
            }
        } onCancel: {
            multiRootSession.cancel()
        }
        await producerTermination.value
        await freezeAllocationCatalog(expectedGeneration: generation)
        let projectionOwner = TerminalProjectionRetirementWorker(
            projections: terminalProjections
        )
        terminalProjections = []
        finishPrimaryFilesystemProducer(
            leaseID: producerLeaseID,
            reservation: reservation,
            finishesPipeline: true
        )
        guard ownsScan(categoryID: categoryID, generation: generation) else {
            await projectionOwner.retire()
            return
        }
        let completedSuccessfully = Self.multiRootCompletionIsSuccessful(
            expectedRootPaths: expectedRootPaths,
            finishedRootPaths: finishedRootPaths,
            sawPartialRoot: sawPartialRoot,
            sawFailure: sawRootFailure,
            consumerCancelled: Task.isCancelled
        )
        let fallbackRoots = Self.multiRootTerminalFallbackPaths(
            expectedRootPaths: expectedRootPaths,
            finishedRootPaths: finishedRootPaths,
            failedRootPaths: failedRootPaths
        )
        for rootPath in fallbackRoots.sorted() {
            recordIncompleteIssue(ScanIncompleteIssue(
                path: rootPath,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
            if var progress = perRootStaging[rootPath] {
                // 终态未收到完整 summary 的根不能继续显示旋转中的状态，也不能保持 normal。
                progress.isFinished = true
                progress.isPartial = true
                perRootStaging[rootPath] = progress
                notePruneSourceMutation()
            }
        }
        let terminalMessage: String? = !fallbackRoots.isEmpty && lastError == nil
            ? AppLocalization.string("main.scan.incomplete", locale: presentationLocale)
            : nil
        let projectionsForPresentation = await projectionOwner.snapshot()
        let preparedTransaction = await prepareTerminalPresentation(
            projections: projectionsForPresentation,
            categoryID: categoryID,
            generation: generation
        )
        scheduleTerminalProjectionOwnerRetirementAfterCommit(projectionOwner)
        guard let transaction = preparedTransaction else { return }
        applyPreparedPerRootProjection(transaction.perRoot)
        if let evidence = transaction.evidence {
            applyPreparedIncompleteEvidenceProjection(evidence)
        }
        if let terminalMessage {
            lastError = terminalMessage
            terminalFailure = TerminalFailure(message: terminalMessage)
        }
        publishPreparedTerminalSnapshot(
            categoryID: categoryID,
            complete: completedSuccessfully,
            presentation: transaction.presentation
        )
        liveProgress.finish(with: snapshot)
        scheduleTerminalRetirement(transaction.worker)
        recordTerminalPerformanceEvidence(producerElapsed: maximumProducerElapsed)
        // v2026.07.17：多根入口使用与单根相同的真实 UI terminal marker；这样推荐、
        // Smart Care 与 Developer 不会再只凭每个 BulkScanner 的完成日志误判端到端性能。
        GSYLog.notice(
            .flow,
            "scan.ui.terminal category=\(categoryID) generation=\(generation.uuidString) delivery=\(Self.diagnosticDeliveryName(delivery)) complete=\(completedSuccessfully) producerElapsed=\(Self.diagnosticSeconds(lastProducerTerminalElapsed)) drainLag=\(Self.diagnosticSeconds(lastConsumerDrainLag)) elapsed=\(String(format: "%.3f", snapshot.elapsed))s files=\(snapshot.scannedFileCount) bytes=\(snapshot.totalBytes) rows=\(snapshot.rows.count) roots=\(expectedRootPaths.count) incrementalNodes=\(incrementalNodeDeliveryCount)"
        )
        isScanning = false
        scanPhase = .idle
        scanTask = nil
        activeCategoryID = nil
        // v2026.07.19 regression fix: terminal preparation may have committed an authoritative
        // developer root -> direct-children projection. The former unconditional invalidation
        // destroyed that DTO immediately, so the first disclosure repeated the filesystem scan.
        // Derive ownership from the committed transaction itself; other categories keep the
        // historical scan-period invalidation contract.
        finalizeTreeCacheAfterScan(
            transaction.presentation.developerTreeChildrenProjection == nil
                ? .invalidateScanPeriodCache
                : .preserveCommittedDeveloperProjection
        )
        refreshVolumeCapacity()
    }

    /// 事件流关闭只代表生产者停止，不代表所有根完整成功。
    ///
    /// 终态必须同时满足：任务未取消、没有 `.failed`、没有 synthetic partial summary，
    /// 且每个预期根都明确发出 `.finished`。这样 total deadline、未来 watchdog 或意外闭流
    /// 都不会再被包装成成功。
    nonisolated static func multiRootCompletionIsSuccessful(
        expectedRootPaths: Set<String>,
        finishedRootPaths: Set<String>,
        sawPartialRoot: Bool,
        sawFailure: Bool,
        consumerCancelled: Bool
    ) -> Bool {
        !consumerCancelled
            && !sawPartialRoot
            && !sawFailure
            && expectedRootPaths.isSubset(of: finishedRootPaths)
    }

    /// Records both sides of the same scan revision only after the authoritative final snapshot
    /// has been published. Multi-root callers derive the elapsed value from the absolute producer
    /// terminal frozen in `MultiRootEvent`; subtracting the slowest individual root duration or
    /// adding two relative clocks would misclassify discovery, task hops and root queueing as
    /// coordinator/UI drain.
    private func recordTerminalPerformanceEvidence(producerElapsed: TimeInterval?) {
        guard let producerElapsed else {
            lastProducerTerminalElapsed = nil
            lastConsumerDrainLag = nil
            return
        }
        let normalizedProducer = max(0, producerElapsed)
        lastProducerTerminalElapsed = normalizedProducer
        lastConsumerDrainLag = max(0, snapshot.elapsed - normalizedProducer)
    }

    nonisolated private static func diagnosticSeconds(_ value: TimeInterval?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.3fs", value)
    }

    /// Stable, non-localized diagnostic label used by local performance evidence. Keeping this
    /// mapping next to the coordinator prevents UI logs from depending on Swift enum formatting.
    nonisolated private static func diagnosticDeliveryName(
        _ delivery: BulkScanner.EventDelivery
    ) -> String {
        switch delivery {
        case .complete:
            return "complete"
        case .summaryOnly:
            return "summaryOnly"
        case .summaryWithProgress:
            return "summaryWithProgress"
        case .topLevel:
            return "topLevel"
        case .largeFiles:
            return "largeFiles"
        case .fileCandidates:
            return "fileCandidates"
        }
    }

    /// 保留最小、不重叠的规范化根集合，并按调用方原顺序返回。
    /// 不解析 symlink，避免改变用户选择的命名空间；只折叠 `.`/`..`/尾斜杠与严格祖先覆盖。
    nonisolated static func minimalNonOverlappingRoots(_ roots: [URL]) -> [URL] {
        var unique: [(index: Int, url: URL, path: String)] = []
        var seen = Set<String>()
        for (index, root) in roots.enumerated() {
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            unique.append((index, URL(fileURLWithPath: path, isDirectory: true), path))
        }

        let ancestorFirst = unique.sorted {
            if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
            return $0.path < $1.path
        }
        var retained: [(index: Int, url: URL, path: String)] = []
        for candidate in ancestorFirst {
            let covered = retained.contains { ancestor in
                ancestor.path == "/"
                    ? candidate.path.hasPrefix("/")
                    : candidate.path == ancestor.path
                        || candidate.path.hasPrefix(ancestor.path + "/")
            }
            if !covered { retained.append(candidate) }
        }
        return retained.sorted { $0.index < $1.index }.map(\.url)
    }

    nonisolated static func developerDiscoveryIsComplete(
        didTimeout: Bool,
        didTruncate: Bool,
        hasIncompleteEvidence: Bool
    ) -> Bool {
        !didTimeout && !didTruncate && !hasIncompleteEvidence
    }

    /// 单根事件流在没有完整、可信 summary 时必须补一条根级 incomplete 证据。
    /// 精确 issues 非空的 partial summary 已能锁住受影响祖先，无需扩大到整根。
    nonisolated static func singleRootNeedsTerminalFallback(
        sawFailure: Bool,
        summary: ScanSummary?
    ) -> Bool {
        if sawFailure || summary == nil { return true }
        return summary?.completionStatus == .partial
            && summary?.incompleteIssues.isEmpty == true
    }

    /// 多根流的事件通道关闭不等于每根成功。未发出 finished 的根和明确 failed 的根
    /// 都必须进入最终删除拒绝集合；调用方再把它们同步成 partial 终态行。
    nonisolated static func multiRootTerminalFallbackPaths(
        expectedRootPaths: Set<String>,
        finishedRootPaths: Set<String>,
        failedRootPaths: Set<String>
    ) -> Set<String> {
        expectedRootPaths.subtracting(finishedRootPaths).union(failedRootPaths)
    }

    /// 投影扫描的 progress/summary 都是“该根累计绝对值”，不能像 node stream 一样直接
    /// 相加。这里按已记录根值替换全局中的单根分量；终态 summary 会精确校正最后一帧。
    ///
    /// v2026.07.17 progress ordering closure: worker merges are actor-serialized, but the tasks
    /// can resume and yield their absolute progress in the opposite order. A non-terminal sample
    /// therefore may only advance the displayed lower bound. Only the following authoritative
    /// `.finished` summary may replace it exactly, so a throttled/stale progress frame can neither
    /// regress capacity nor masquerade as terminal evidence.
    private func reconcileProjectedRootAccounting(
        rootPath: String,
        allocatedBytes: Int64,
        logicalBytes: Int64?,
        fileCount: Int,
        authoritativeTerminal: Bool
    ) {
        guard var progress = perRootStaging[rootPath] else { return }
        let reportedBytes = max(0, allocatedBytes)
        let reportedFiles = max(0, fileCount)
        let nextBytes = authoritativeTerminal
            ? reportedBytes
            : max(progress.bytes, reportedBytes)
        let nextFiles = authoritativeTerminal
            ? reportedFiles
            : max(progress.fileCount, reportedFiles)
        totalBytes = Self.replacingAggregateComponent(
            total: totalBytes,
            previous: progress.bytes,
            next: nextBytes
        )
        scannedFiles = Self.replacingAggregateComponent(
            total: scannedFiles,
            previous: progress.fileCount,
            next: nextFiles
        )
        progress.bytes = nextBytes
        progress.fileCount = nextFiles
        if let logicalBytes {
            progress.logicalBytes = max(0, logicalBytes)
        }
        perRootStaging[rootPath] = progress
        notePruneSourceMutation()
    }

    private nonisolated static func replacingAggregateComponent<T: FixedWidthInteger>(
        total: T,
        previous: T,
        next: T
    ) -> T where T: SignedInteger {
        // All three values are non-negative by contract. Clamp an inconsistent prior snapshot
        // fail-safe, then saturate the replacement sum instead of trapping on hostile metadata.
        let base = total >= previous ? total - previous : 0
        let sum = base.addingReportingOverflow(next)
        return sum.overflow ? .max : sum.partialValue
    }

    private func ingestMultiRootNode(_ node: FSNode, rootPath: String) {
        guard ingest(node: node, rootPath: rootPath), node.isRegularFile,
              var progress = perRootStaging[rootPath] else { return }
        progress.bytes += displayBytes(of: node)
        progress.logicalBytes += node.logicalSize
        progress.fileCount += 1
        perRootStaging[rootPath] = progress
    }

    private func ingestMultiRootNodes(_ nodes: [FSNode], rootPath: String) {
        // Step 13B micro-batch：只累计真正被全局 ingest 接受的 node。
        // tombstone / 越界 node 返回 false，不能再进入 per-root staging。
        var stagingDelta: (bytes: Int64, logicalBytes: Int64, files: Int) = (0, 0, 0)
        for node in nodes where ingest(node: node, rootPath: rootPath) && node.isRegularFile {
            stagingDelta.bytes += displayBytes(of: node)
            stagingDelta.logicalBytes += node.logicalSize
            stagingDelta.files += 1
        }
        guard stagingDelta.files > 0, var progress = perRootStaging[rootPath] else { return }
        progress.bytes += stagingDelta.bytes
        progress.logicalBytes += stagingDelta.logicalBytes
        progress.fileCount += stagingDelta.files
        perRootStaging[rootPath] = progress
    }

    /// 测试专用注入：模拟 BulkScanner yield 的 .permissionDenied 路径，
    /// 走的是和 runScan 同一条去重逻辑。仅 `@testable` 可见。
    ///
    /// SwiftPM 的 Release 测试 target 也会编译同一组测试源；若用 `#if DEBUG`
    /// 删除这些 internal symbol，`swift test -c release` 会在编译阶段失败。
    internal func _testInjectPermissionDenied(path: String) {
        recordIncompleteIssue(ScanIncompleteIssue(path: path, reason: .permissionDenied))
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    /// 测试专用注入：模拟 BulkScanner yield 的 .tccProtectedSkipped 路径。
    internal func _testInjectTCCSkipped(path: String) {
        recordIncompleteIssue(ScanIncompleteIssue(path: path, reason: .tccProtectedSkipped))
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    internal func _testInjectIncomplete(
        _ issue: ScanIncompleteIssue,
        displayRootPath: String
    ) {
        recordIncompleteIssue(issue, displayRootPath: displayRootPath)
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    internal func _testReplaceIncompleteEvidence(_ issues: [ScanIncompleteIssue]) {
        replaceIncompleteEvidence(with: issues)
    }

    internal func _testConsumeScanFailure(
        _ error: any Error,
        rootPath: String,
        publishPresentationImmediately: Bool = true
    ) -> Bool {
        let isTerminal = consumeScanFailure(
            error,
            rootPath: rootPath,
            publishPresentationImmediately: publishPresentationImmediately
        )
        if publishPresentationImmediately {
            commitIncompleteEvidenceProjectionsIfNeeded()
        }
        return isTerminal
    }

    /// 测试专用批量入口：模拟同一 throttle 窗口内连续到达的 typed issues，故意不提交。
    /// 生产事件流仍逐条调用 `recordIncompleteIssue`，测试据此锁定“记录 O(1)、批次只重建一次”。
    internal func _testRecordIncompleteEvidenceWithoutPublishing(
        _ issues: [ScanIncompleteIssue]
    ) {
        for issue in issues {
            recordIncompleteIssue(issue)
        }
    }

    internal func _testCommitIncompleteEvidence() {
        commitIncompleteEvidenceProjectionsIfNeeded()
    }

    internal var _testIncompleteEvidenceProjectionRebuildCount: Int {
        incompleteEvidenceProjectionRebuildCount
    }

    internal func _testResetIncompleteEvidence() {
        resetIncompleteEvidence()
    }

    internal func _testAccessState(for path: String) -> TreeRow.AccessState {
        commitIncompleteEvidenceProjectionsIfNeeded()
        return projectedTreeState(for: path).accessState
    }

    internal func _testSubtreeCompleteness(for path: String) -> TreeRow.SubtreeCompleteness {
        commitIncompleteEvidenceProjectionsIfNeeded()
        return projectedTreeState(for: path).subtreeCompleteness
    }

    internal func _testIngestMultiRootNodes(rootPath: String, nodes: [FSNode]) {
        ingestMultiRootNodes(nodes, rootPath: rootPath)
        syncPerRootPublished(from: perRootStaging)
    }

    /// 将 node 写入全局聚合，并返回它是否通过本轮 tombstone/投影边界。
    /// 多根扫描必须只对返回 `true` 的 node 累加 per-root 进度，否则已删除子树的
    /// 晚到事件虽然不会复活 bucket，却仍会把父根 bytes/fileCount 加回来。
    @discardableResult
    private func ingest(node: FSNode, rootPath: String) -> Bool {
        // 把 node 归到"根的第一级子目录"——这是聚合行，不展平
        let nodePath = displayPathForScanNode(node.path, rootPath: rootPath)
        guard !isDeletedTombstoned(nodePath) else { return false }
        guard let projection = Self.bucketProjection(nodePath: nodePath, rootPath: rootPath) else { return false }
        let tail = projection.tail
        let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init) ?? tail
        guard !firstSegment.isEmpty else { return false }
        let bucketPath = projection.bucketPath

        // v1.3：刷新该 bucket 的"最近 ingest 时间"，作为 active 判定的活跃度信号。
        // 用 timeIntervalSinceReferenceDate 比 Date() 更轻量，单调递增足够。
        // v1.3.y 性能修复：72 万 .node 每次都写一次 lastIngestAt 主线程字典 → 主线程压力大。
        // 该值仅用于 publishSnapshot 时（≥150ms 一次）判 active，精度做到 ~50ms 完全够；
        // 同 bucket 在 50ms 窗口内重复的写入直接跳过，把字典写入次数从 N 降到 N / (50ms 内同 bucket node 数)。
        // v1.5 P1-D：去抖窗口从 0.05s 抬到 0.2s。配合 publishSnapshot 0.4s 节流与
        // activityWindow=0.8s 仍完全安全（active 判定不会误失活），但字典写入再降一档，
        // dev scan 几十/几百根高密度 ingest 时主线程字典写入压力进一步下降。
        let nowTI = Date.timeIntervalSinceReferenceDate
        if let prev = lastIngestAt[bucketPath], nowTI - prev < 0.20 {
            // 窗口内已写过，跳过
        } else {
            lastIngestAt[bucketPath] = nowTI
        }

        // 主值固定累计 allocated bytes；logicalBytes 只作为 Finder 式详情副值保留。
        let bytes = displayBytes(of: node)

        // 文件累计
        if node.isRegularFile {
            scannedFiles += 1
            totalBytes += bytes
        }

        let isDir = node.isDirectory
        // v1.3.z 性能优化：把"两次哈希查找"合并为"一次默认值构造 + modify accessor 写回"。
        // sample(80125, 5s) 显示 ingest 在主线程占 372 ticks，buckets 字典访问是其中热点之一。
        // 旧写法：`var b = buckets[k] ?? Bucket(...); ...; buckets[k] = b` —— 即便 hit
        // 也要每次构造 URL 默认值，且要做两次 hash 定位。
        // 新写法：用 `[k, default:]` 的 modify accessor —— hit 时不构造 URL，只走一次 hash。
        buckets[bucketPath, default: Bucket(
            url: URL(fileURLWithPath: bucketPath, isDirectory: true),
            isDirectory: true
        )].applyIngest(
            isFileNode: node.isRegularFile,
            isTopLevelBucket: nodePath == bucketPath,
            isDirEffective: isDir,
            bytes: bytes,
            logicalBytes: node.logicalSize,
            nodeMTime: node.modificationDate
        )

        // v1.0 T3：构建多层下钻索引。
        // - 叶子文件：累计到所有祖先目录的 dirIndex
        // - 任意 node：把它登记为父目录的直接子项（childEdges）
        // v1.3.z 性能开关：CLI bench / 性能基线场景关掉，跳过 576 万次主线程字典写入。
        if !node.isDirectory {
            // v1.0 T4：达到大文件阈值的叶子单独留底，供 LargeFilesView 用。
            // 注：与深索引开关解耦，largeFileLeaves 即便 deepIndex=off 也照常采集。
            if node.isRegularFile && largeFileMinBytes > 0 && bytes >= largeFileMinBytes && !isWhitelisted(nodePath) {
                largeFileLeaves.consider(LargeFileLeaf(
                    path: nodePath,
                    bytes: bytes,
                    logicalBytes: node.logicalSize,
                    modificationDate: node.modificationDate
                ))
            }
            if enableTreeDeepIndex {
                fileLeaves[nodePath] = IndexedFileLeaf(
                    bytes: bytes,
                    logicalBytes: node.logicalSize,
                    isDir: false,
                    modificationDate: node.modificationDate,
                    isRegularFile: node.isRegularFile
                )
                // v1.5.7 perf：沿路径回溯到 rootPath，把 size 加到所有祖先。
                // 旧实现：每步 `(cursor as NSString).deletingLastPathComponent` 触发一次
                // NSString 桥接 + 路径拷贝；大目录（>5w 文件）下 instrument 显示
                // NSPathStore2 / NSString.bridgeFromObjC 占主线程 ~12% 时间。
                // 新实现：在原生 String 上用 lastIndex(of: "/") 切片，零桥接零额外 alloc。
                var cursor = String._gsyParentPath(of: nodePath)
                while !cursor.isEmpty, cursor.hasPrefix(rootPath) {
                    var agg = dirIndex[cursor] ?? DirAgg()
                    agg.bytes += bytes
                    agg.logicalBytes += node.logicalSize
                    agg.fileCount += node.isRegularFile ? 1 : 0
                    dirIndex[cursor] = agg
                    if cursor == rootPath { break }
                    let parent = String._gsyParentPath(of: cursor)
                    childEdges[parent, default: []].insert(cursor)
                    cursor = parent
                }
                // 文件本身也作为父目录的直接子项
                let parent = String._gsyParentPath(of: nodePath)
                childEdges[parent, default: []].insert(nodePath)
            }
        } else if enableTreeDeepIndex {
            // 目录节点（即使没有累计字节，也把它登记到边集，避免空目录在树里漏掉）
            // v1.5.4：把目录自身的 inode mtime 写入 DirAgg（保留已有 bytes/fileCount/logicalBytes）
            var agg = dirIndex[nodePath] ?? DirAgg()
            // 仅在目录节点 ingest 时覆盖 modificationDate；后续叶子累加路径不再回写它，
            // 保持"目录 mtime = 目录自身 inode mtime"的 Finder 语义。
            if let m = node.modificationDate {
                agg.modificationDate = m
            }
            dirIndex[nodePath] = agg
            if nodePath != rootPath {
                let parent = (nodePath as NSString).deletingLastPathComponent
                if parent.hasPrefix(rootPath) || parent == rootPath {
                    childEdges[parent, default: []].insert(nodePath)
                }
            }
        }
        notePruneSourceMutation()
        return true
    }

    private func ingestLargeFileNode(_ node: FSNode, rootPath: String) {
        guard node.isRegularFile else { return }
        let nodePath = displayPathForScanNode(node.path, rootPath: rootPath)
        guard !isDeletedTombstoned(nodePath), !isWhitelisted(nodePath) else { return }
        let bytes = displayBytes(of: node)
        scannedFiles += 1
        totalBytes += bytes
        if largeFileMinBytes > 0 && bytes >= largeFileMinBytes {
            largeFileLeaves.consider(LargeFileLeaf(
                path: nodePath,
                bytes: bytes,
                logicalBytes: node.logicalSize,
                modificationDate: node.modificationDate
            ))
        }
        notePruneSourceMutation()
    }

    /// 把 ScanKit 的权威后台投影一次性落到 UI store。
    ///
    /// **v2026.07.16 性能回归根治：** 这里的循环规模最多是“一级可见行数”或固定
    /// Top-1000，而不是扫描到的全部 inode。projection 与 summary 来自同一轮枚举，
    /// 因而不会为提速牺牲 hardlink 去重、allocated/logical 口径或完整性证据。
    private func applyProjection(_ projection: ScanProjectionResult, rootPath: String) {
        switch projection {
        case .none:
            return
        case .topLevel(let entries):
            for entry in entries {
                let path = displayPathForScanNode(entry.path, rootPath: rootPath)
                guard !isDeletedTombstoned(path) else { continue }
                // 多根扫描及整盘 firmlink 映射可能把多个投影规范到同一展示路径。
                // 不能 last-writer-wins 覆盖，否则全局 summary 在累加而行容量被丢失。
                var bucket = buckets[path] ?? Bucket(
                    url: URL(fileURLWithPath: path, isDirectory: entry.isDirectory),
                    isDirectory: entry.isDirectory
                )
                bucket.bytes &+= entry.allocatedBytes
                bucket.logicalBytes &+= entry.logicalBytes
                bucket.fileCount &+= entry.fileCount
                bucket.isDirectory = bucket.isDirectory || entry.isDirectory
                bucket.hasChildren = bucket.hasChildren || entry.hasChildren
                if bucket.modificationDate == nil {
                    bucket.modificationDate = entry.modificationDate
                }
                buckets[path] = bucket
            }
        case .largeFiles(let nodes):
            for node in nodes {
                let path = displayPathForScanNode(node.path, rootPath: rootPath)
                guard !isDeletedTombstoned(path), !isWhitelisted(path) else { continue }
                largeFileLeaves.consider(LargeFileLeaf(
                    path: path,
                    bytes: node.allocatedSize,
                    logicalBytes: node.logicalSize,
                    modificationDate: node.modificationDate
                ))
            }
        case .fileCandidates:
            // 该投影是 DuplicateScanner 的内容分桶边界，不是可见行。
            // ScanCoordinator 生产入口不请求此模式，即使未来误传也不能将
            // 数万候选投影成 UI 列表。
            return
        }
        notePruneSourceMutation()
    }

    /// Builds the authoritative terminal list without touching actor-isolated state.
    ///
    /// v2026.07.18 root-cause fix: a top-level projection is bounded by "number of visible
    /// descendants", not by a fixed constant. On a wide root that can still mean tens of
    /// thousands of dictionary merges, SafetyEngine evaluations and comparisons. Running only
    /// `sort` in the background would therefore leave most of the freeze intact; the complete
    /// materialization transaction belongs on the generic executor.
    /// Evaluates terminal cache misses with a fixed, small worker bound. One task per row would
    /// turn a filesystem-heavy safety phase into scheduler pressure; four contiguous chunks keep
    /// concurrency explicit while preserving the exact evaluator and final ordering contract.
    nonisolated private static func evaluateTerminalSafety(
        paths: [String],
        engine: SafetyEngine,
        trie: VendorTrieNode,
        home: String
    ) async -> PreparedTerminalSafetyEvaluations? {
        guard !paths.isEmpty else {
            return PreparedTerminalSafetyEvaluations(
                evaluations: [],
                workerCount: 0,
                observedMainThread: false
            )
        }
        let minimumRowsPerWorker = 512
        let workerLimit = 4
        let workerCount = min(
            workerLimit,
            max(1, (paths.count + minimumRowsPerWorker - 1) / minimumRowsPerWorker)
        )
        let chunkSize = (paths.count + workerCount - 1) / workerCount

        func evaluateChunk(_ range: Range<Int>) -> TerminalSafetyChunk? {
            var evaluations: [TerminalSafetyEvaluation] = []
            evaluations.reserveCapacity(range.count)
            let observedMainThread = Thread.isMainThread
            for index in range {
                guard !Task.isCancelled else { return nil }
                let path = paths[index]
                let result = engine.evaluate(path: path, trie: trie, home: home)
                evaluations.append(TerminalSafetyEvaluation(
                    path: path,
                    verdict: result.0,
                    rejection: result.1,
                    vendor: result.2
                ))
            }
            return TerminalSafetyChunk(
                evaluations: evaluations,
                observedMainThread: observedMainThread
            )
        }

        if workerCount == 1 {
            guard let chunk = evaluateChunk(0..<paths.count) else { return nil }
            return PreparedTerminalSafetyEvaluations(
                evaluations: chunk.evaluations,
                workerCount: 1,
                observedMainThread: chunk.observedMainThread
            )
        }

        return await withTaskGroup(
            of: TerminalSafetyChunk?.self,
            returning: PreparedTerminalSafetyEvaluations?.self
        ) { group in
            for workerIndex in 0..<workerCount {
                let lowerBound = workerIndex * chunkSize
                let upperBound = min(paths.count, lowerBound + chunkSize)
                guard lowerBound < upperBound else { continue }
                group.addTask {
                    evaluateChunk(lowerBound..<upperBound)
                }
            }

            var evaluations: [TerminalSafetyEvaluation] = []
            evaluations.reserveCapacity(paths.count)
            var observedMainThread = false
            for await chunk in group {
                guard let chunk else {
                    group.cancelAll()
                    return nil
                }
                evaluations.append(contentsOf: chunk.evaluations)
                observedMainThread = observedMainThread || chunk.observedMainThread
            }
            guard evaluations.count == paths.count, !Task.isCancelled else { return nil }
            return PreparedTerminalSafetyEvaluations(
                evaluations: evaluations,
                workerCount: workerCount,
                observedMainThread: observedMainThread
            )
        }
    }

    nonisolated private static func buildTerminalPresentation(
        baseBuckets: [String: Bucket],
        projections: [TerminalProjectionEnvelope],
        seedDeveloperTreeChildrenCache: Bool,
        fullDiskPathNamespace: ScanPathNamespace,
        tombstones: PrunedPathMatcher,
        engine: SafetyEngine,
        trie: VendorTrieNode,
        home: String,
        whitelist: Set<String>,
        sortKey: MainListSortKey,
        locale: Locale,
        treeEvidence: TreeScanEvidenceProjection
    ) async -> PreparedTerminalPresentation? {
        let totalStarted = DispatchTime.now().uptimeNanoseconds
        let mergeStarted = totalStarted
        var nextBuckets = baseBuckets
        var developerTreeRootPaths = Set<String>()
        var developerRootByChildPath: [String: String] = [:]
        if seedDeveloperTreeChildrenCache {
            developerTreeRootPaths.reserveCapacity(projections.count)
        }

        for envelope in projections {
            guard !Task.isCancelled else { return nil }
            guard case .topLevel(let entries) = envelope.projection else { continue }
            if seedDeveloperTreeChildrenCache,
               !tombstones.contains(envelope.rootPath) {
                // Recording the root even for an empty projection is intentional: an empty,
                // completed artifact root must be an authoritative cache hit rather than an
                // invitation to scan the same filesystem root again on disclosure.
                developerTreeRootPaths.insert(envelope.rootPath)
            }
            for entry in entries {
                guard !Task.isCancelled else { return nil }
                let path = envelope.rootPath == "/"
                    ? fullDiskPathNamespace.publicPath(forPhysicalPath: entry.path)
                    : entry.path
                guard !tombstones.contains(path) else { continue }

                // Multiple producer roots can legitimately normalize to the same public row.
                // Preserve the existing additive contract instead of last-writer-wins.
                var bucket = nextBuckets[path] ?? Bucket(
                    url: URL(fileURLWithPath: path, isDirectory: entry.isDirectory),
                    isDirectory: entry.isDirectory
                )
                bucket.bytes &+= entry.allocatedBytes
                bucket.logicalBytes &+= entry.logicalBytes
                bucket.fileCount &+= entry.fileCount
                bucket.isDirectory = bucket.isDirectory || entry.isDirectory
                bucket.hasChildren = bucket.hasChildren || entry.hasChildren
                if bucket.modificationDate == nil {
                    bucket.modificationDate = entry.modificationDate
                }
                nextBuckets[path] = bucket

                if seedDeveloperTreeChildrenCache,
                   !tombstones.contains(envelope.rootPath),
                   !isWhitelisted(path, in: whitelist) {
                    developerRootByChildPath[path] = envelope.rootPath
                }
            }
        }
        let mergeFinished = DispatchTime.now().uptimeNanoseconds

        var cacheHits = 0
        var missingSafetyPaths: [String] = []
        missingSafetyPaths.reserveCapacity(nextBuckets.count)
        var safetyByPath: [String: TerminalSafetyEvaluation] = [:]
        safetyByPath.reserveCapacity(nextBuckets.count)
        for (path, bucket) in nextBuckets {
            guard !Task.isCancelled else { return nil }
            if let verdict = bucket.cachedVerdict,
               let rejection = bucket.cachedRejection {
                safetyByPath[path] = TerminalSafetyEvaluation(
                    path: path,
                    verdict: verdict,
                    rejection: rejection,
                    vendor: bucket.cachedVendor
                )
                cacheHits &+= 1
            } else {
                missingSafetyPaths.append(path)
            }
        }

        let safetyStarted = DispatchTime.now().uptimeNanoseconds
        guard let preparedSafety = await evaluateTerminalSafety(
            paths: missingSafetyPaths,
            engine: engine,
            trie: trie,
            home: home
        ) else { return nil }
        for evaluation in preparedSafety.evaluations {
            guard !Task.isCancelled,
                  var bucket = nextBuckets[evaluation.path]
            else { return nil }
            bucket.cachedVerdict = evaluation.verdict
            bucket.cachedRejection = evaluation.rejection
            bucket.cachedVendor = evaluation.vendor
            nextBuckets[evaluation.path] = bucket
            safetyByPath[evaluation.path] = evaluation
        }
        let safetyFinished = DispatchTime.now().uptimeNanoseconds
        let cacheMisses = preparedSafety.evaluations.count

        let rowMaterializationStarted = safetyFinished
        var rows: [RowItem] = []
        rows.reserveCapacity(nextBuckets.count)
        var rowRollup = ScanSnapshotRowRollup()
        for (path, bucket) in nextBuckets {
            guard !Task.isCancelled else { return nil }
            guard let safety = safetyByPath[path] else { return nil }

            guard whitelist.isEmpty || !Self.isWhitelisted(path, in: whitelist) else {
                continue
            }
            rows.append(RowItem(
                id: path,
                url: bucket.url,
                title: bucket.url.lastPathComponent,
                isDirectory: bucket.isDirectory,
                bytes: bucket.bytes,
                logicalBytes: bucket.logicalBytes,
                fileCount: bucket.fileCount,
                verdict: safety.verdict,
                rejection: safety.rejection,
                vendorName: safety.vendor?.name,
                vendorNote: safety.vendor?.note,
                runningBundleIDPrefix: safety.vendor?.bundleIDPrefix,
                isActive: false,
                hasChildren: bucket.hasChildren,
                modificationDate: bucket.modificationDate
            ))
            rowRollup.record(verdict: safety.verdict, bytes: bucket.bytes)
        }
        let rowMaterializationFinished = DispatchTime.now().uptimeNanoseconds

        guard !Task.isCancelled else { return nil }
        let mainSortStarted = DispatchTime.now().uptimeNanoseconds
        rows.sort { sortKey.lessThan($0, $1, locale: locale) }
        let mainSortFinished = DispatchTime.now().uptimeNanoseconds
        let treeProjectionStarted = mainSortFinished
        let treeRowsBySort: [TreeSortKey: [TreeRow]]
        let developerTreeChildrenProjection: PreparedDeveloperTreeChildrenProjection?
        if seedDeveloperTreeChildrenCache {
            // The developer Tree root is the multi-root sentinel and consumes
            // `perRootTreeRowsBySort`, never `snapshotTreeRowsBySort`. Building eight global
            // locale-aware sorts for all terminal child rows was therefore dead work. Materialize
            // semantic rows once, group by producer root, then sort each usually-small sibling set.
            guard let semanticRows = buildSemanticTreeRows(
                rows: rows,
                evidence: treeEvidence,
                forceLeafPresentation: false
            ) else { return nil }
            let treeProjectionFinished = DispatchTime.now().uptimeNanoseconds
            let developerGroupingStarted = treeProjectionFinished
            var rowsByRoot: [String: [TreeRow]] = [:]
            rowsByRoot.reserveCapacity(developerTreeRootPaths.count)
            for row in semanticRows {
                guard !Task.isCancelled else { return nil }
                guard let rootPath = developerRootByChildPath[row.path] else { continue }
                rowsByRoot[rootPath, default: []].append(row)
            }
            var cache: [String: [TreeRow]] = [:]
            cache.reserveCapacity(developerTreeRootPaths.count * TreeSortKey.allCases.count)
            for rootPath in developerTreeRootPaths {
                guard !Task.isCancelled else { return nil }
                let rootRows = rowsByRoot[rootPath] ?? []
                for treeSortKey in TreeSortKey.allCases {
                    cache["\(rootPath)|\(treeSortKey.rawValue)"] = rootRows.sorted {
                        sortTreeRow($0, before: $1, by: treeSortKey, locale: locale)
                    }
                }
            }
            let developerGroupingFinished = DispatchTime.now().uptimeNanoseconds
            treeRowsBySort = [:]
            developerTreeChildrenProjection = PreparedDeveloperTreeChildrenProjection(
                cache: cache,
                rootCount: developerTreeRootPaths.count,
                directChildCount: developerRootByChildPath.count,
                ranOnMainThread: currentThreadIsMainForDiagnostics()
            )
            let totalFinished = DispatchTime.now().uptimeNanoseconds
            return PreparedTerminalPresentation(
                buckets: nextBuckets,
                rows: rows,
                treeRowsBySort: treeRowsBySort,
                rowRollup: rowRollup,
                verdictCacheHits: cacheHits,
                verdictCacheMisses: cacheMisses,
                developerTreeChildrenProjection: developerTreeChildrenProjection,
                diagnostics: TerminalProjectionDiagnostics(
                    projectionCount: projections.count,
                    rowCount: rows.count,
                    safetyEvaluationCount: cacheMisses,
                    safetyWorkerCount: preparedSafety.workerCount,
                    safetyWorkerObservedMainThread: preparedSafety.observedMainThread,
                    projectionMergeNanoseconds: mergeFinished - mergeStarted,
                    safetyEvaluationNanoseconds: safetyFinished - safetyStarted,
                    rowMaterializationNanoseconds:
                        rowMaterializationFinished - rowMaterializationStarted,
                    mainRowSortNanoseconds: mainSortFinished - mainSortStarted,
                    treeProjectionNanoseconds: treeProjectionFinished - treeProjectionStarted,
                    developerCacheGroupingNanoseconds:
                        developerGroupingFinished - developerGroupingStarted,
                    totalNanoseconds: totalFinished - totalStarted
                ),
                ranOnMainThread: currentThreadIsMainForDiagnostics()
            )
        } else {
            guard let preparedTreeRows = buildSnapshotTreeRows(
                rows: rows,
                evidence: treeEvidence,
                locale: locale
            ) else { return nil }
            treeRowsBySort = preparedTreeRows
            developerTreeChildrenProjection = nil
        }
        let treeProjectionFinished = DispatchTime.now().uptimeNanoseconds
        let totalFinished = treeProjectionFinished
        return PreparedTerminalPresentation(
            buckets: nextBuckets,
            rows: rows,
            treeRowsBySort: treeRowsBySort,
            rowRollup: rowRollup,
            verdictCacheHits: cacheHits,
            verdictCacheMisses: cacheMisses,
            developerTreeChildrenProjection: developerTreeChildrenProjection,
            diagnostics: TerminalProjectionDiagnostics(
                projectionCount: projections.count,
                rowCount: rows.count,
                safetyEvaluationCount: cacheMisses,
                safetyWorkerCount: preparedSafety.workerCount,
                safetyWorkerObservedMainThread: preparedSafety.observedMainThread,
                projectionMergeNanoseconds: mergeFinished - mergeStarted,
                safetyEvaluationNanoseconds: safetyFinished - safetyStarted,
                rowMaterializationNanoseconds:
                    rowMaterializationFinished - rowMaterializationStarted,
                mainRowSortNanoseconds: mainSortFinished - mainSortStarted,
                treeProjectionNanoseconds: treeProjectionFinished - treeProjectionStarted,
                developerCacheGroupingNanoseconds: 0,
                totalNanoseconds: totalFinished - totalStarted
            ),
            ranOnMainThread: currentThreadIsMainForDiagnostics()
        )
    }

    /// Runs the terminal materialization as a compare-and-swap transaction. Generation prevents
    /// an old scan from writing into a new scan of the same category; source revision prevents a
    /// concurrent prune/tree mutation from being overwritten by a stale COW snapshot.
    private func prepareTerminalPresentation(
        projections: [TerminalProjectionEnvelope],
        categoryID: String,
        generation: UUID,
        beforeCommitForTesting: (@MainActor () -> Void)? = nil
    ) async -> PreparedTerminalTransaction? {
        let transactionStarted = DispatchTime.now().uptimeNanoseconds
        var cumulativeWorkerNanoseconds: UInt64 = 0
        var pendingTestHook = beforeCommitForTesting
        var attemptCount = 0
        while ownsScan(categoryID: categoryID, generation: generation) {
            attemptCount &+= 1
            guard !Task.isCancelled else { return nil }
            let sourceRevision = pruneSourceRevision
            let evidenceRevision = incompleteEvidenceSourceRevision
            let sortKey = mainListSortKey
            let locale = presentationLocale
            let worker = TerminalPresentationWorker(
                retainedState: TerminalRetainedState(
                    baseBuckets: buckets,
                    projections: projections,
                    replacedDeveloperTreeChildrenCache:
                        categoryID == ScanCoordinator.developerCategoryID
                            ? treeChildrenCache
                            : nil,
                    previousSnapshotRows: snapshot.rows,
                    previousSnapshotTreeRows: snapshotTreeRowsBySort,
                    previousLastIngestAt: lastIngestAt,
                    previousStreamSortedIDs: lastStreamSortedIds,
                    primaryEvidence: primaryIncompleteEvidence,
                    treeEvidenceByRoot: treeIncompleteEvidenceByRoot,
                    previousIssues: incompleteScanIssues,
                    previousPermissionPaths: permissionDeniedPaths,
                    previousTCCPaths: tccProtectedSkippedPaths,
                    previousAllPaths: incompleteScanPaths,
                    previousTreeProjection: treeScanEvidenceProjection,
                    perRootStaging: perRootStaging,
                    previousPerRootActive: perRootProgressActive,
                    previousPerRootFinished: perRootFinishedSlim,
                    previousPerRootFinishedCount: perRootFinishedCount,
                    previousPerRootSorted: perRootProgressSorted,
                    previousPerRootTreeRows: perRootTreeRowsBySort
                ),
                evidenceWasDirty: incompleteEvidenceProjectionDirty,
                fullDiskPathNamespace: fullDiskPathNamespace,
                tombstones: deletedPathTombstones.matcher,
                engine: engine,
                trie: trie,
                home: home,
                whitelist: whitelistSnapshot,
                sortKey: sortKey,
                locale: locale
            )
            var prepared = await worker.prepare()
            if let prepared {
                cumulativeWorkerNanoseconds &+= prepared.presentation.diagnostics.totalNanoseconds
            }

            if let hook = pendingTestHook {
                pendingTestHook = nil
                hook()
            }
            guard !Task.isCancelled,
                  ownsScan(categoryID: categoryID, generation: generation)
            else {
                prepared = nil
                await retireTerminalWorkerAndRecord(worker)
                return nil
            }
            guard sortKey == mainListSortKey,
                  locale.identifier == presentationLocale.identifier
            else {
                let attemptMilliseconds = prepared.map {
                    Double($0.presentation.diagnostics.totalNanoseconds) / 1_000_000
                } ?? 0
                GSYLog.info(
                    .flow,
                    "scan.terminal.projection.retry category=\(categoryID) "
                        + "attempt=\(attemptCount) reason=presentation_contract_changed "
                        + "attempt_total_ms=\(String(format: "%.2f", attemptMilliseconds))"
                )
                // Sort/locale changes do not mutate scan indexes, so they intentionally do not
                // advance pruneSourceRevision. They still invalidate presentation work.
                prepared = nil
                await retireTerminalWorkerAndRecord(worker)
                await Task.yield()
                continue
            }
            guard sourceRevision == pruneSourceRevision,
                  evidenceRevision == incompleteEvidenceSourceRevision
            else {
                let attemptMilliseconds = prepared.map {
                    Double($0.presentation.diagnostics.totalNanoseconds) / 1_000_000
                } ?? 0
                GSYLog.info(
                    .flow,
                    "scan.terminal.projection.retry category=\(categoryID) "
                        + "attempt=\(attemptCount) reason=source_revision_changed "
                        + "attempt_total_ms=\(String(format: "%.2f", attemptMilliseconds))"
                )
                prepared = nil
                await retireTerminalWorkerAndRecord(worker)
                await Task.yield()
                continue
            }
            guard let prepared else {
                await retireTerminalWorkerAndRecord(worker)
                return nil
            }

            // COW storage swap only. `worker` keeps the old buckets and all other wide source
            // storage alive until the caller has also swapped snapshot/evidence and retires it.
            buckets = prepared.presentation.buckets
            verdictCacheHits &+= prepared.presentation.verdictCacheHits
            verdictCacheMisses &+= prepared.presentation.verdictCacheMisses
            let terminalDiagnostics = prepared.presentation.diagnostics
            let transactionNanoseconds = DispatchTime.now().uptimeNanoseconds - transactionStarted
            func milliseconds(_ nanoseconds: UInt64) -> String {
                String(format: "%.2f", Double(nanoseconds) / 1_000_000)
            }
            GSYLog.notice(
                .flow,
                "scan.terminal.projection category=\(categoryID) "
                    + "attempt=\(attemptCount) projections=\(terminalDiagnostics.projectionCount) "
                    + "rows=\(terminalDiagnostics.rowCount) "
                    + "safety_evaluations=\(terminalDiagnostics.safetyEvaluationCount) "
                    + "safety_workers=\(terminalDiagnostics.safetyWorkerCount) "
                    + "safety_worker_main=\(terminalDiagnostics.safetyWorkerObservedMainThread) "
                    + "merge_ms=\(milliseconds(terminalDiagnostics.projectionMergeNanoseconds)) "
                    + "safety_ms=\(milliseconds(terminalDiagnostics.safetyEvaluationNanoseconds)) "
                    + "rows_ms=\(milliseconds(terminalDiagnostics.rowMaterializationNanoseconds)) "
                    + "main_sort_ms=\(milliseconds(terminalDiagnostics.mainRowSortNanoseconds)) "
                    + "tree_projection_ms=\(milliseconds(terminalDiagnostics.treeProjectionNanoseconds)) "
                    + "developer_group_ms=\(milliseconds(terminalDiagnostics.developerCacheGroupingNanoseconds)) "
                    + "attempt_total_ms=\(milliseconds(terminalDiagnostics.totalNanoseconds)) "
                    + "worker_cumulative_ms=\(milliseconds(cumulativeWorkerNanoseconds)) "
                    + "transaction_total_ms=\(milliseconds(transactionNanoseconds))"
            )
            if let developerTree = prepared.presentation.developerTreeChildrenProjection {
                treeChildrenCache = developerTree.cache
                bumpChildrenCacheVersion()
                GSYLog.info(
                    .flow,
                    "tree.developer.terminal_cache.commit roots=\(developerTree.rootCount) "
                        + "direct_children=\(developerTree.directChildCount) "
                        + "sort_projections=\(developerTree.cache.count) "
                        + "worker_main=\(developerTree.ranOnMainThread) "
                        + "filesystem_fetch_required=false"
                )
            }
            lastTerminalPreparationRanOnMainThread = prepared.presentation.ranOnMainThread
            return PreparedTerminalTransaction(
                presentation: prepared.presentation,
                evidence: prepared.evidence,
                perRoot: prepared.perRoot,
                worker: worker,
                attemptCount: attemptCount
            )
        }
        return nil
    }

    /// Transfers the caller's COW buffer before clearing it. `retire()` executes on the worker
    /// actor, so a rejected/cancelled terminal projection never destructs thousands of envelope
    /// entries while returning from the MainActor scan task.
    private func handOffTerminalProjectionsForRetirement(
        _ projections: inout [TerminalProjectionEnvelope]
    ) {
        guard !projections.isEmpty else { return }
        let worker = TerminalProjectionRetirementWorker(projections: projections)
        projections = []
        Task {
            await worker.retire()
        }
    }

    /// Terminal CAS has already committed coordinator storage when preparation returns. Do not
    /// insert another `await` before the caller applies the DTO: that would let a replacement scan
    /// interleave and then receive stale rows. The MainActor barrier guarantees the caller's local
    /// COW reference has left scope before the actor drops the final raw producer owner.
    private func scheduleTerminalProjectionOwnerRetirementAfterCommit(
        _ owner: TerminalProjectionRetirementWorker
    ) {
        Task.detached(priority: .utility) {
            await MainActor.run {}
            await owner.retire()
        }
    }

    /// Publishes rows that were already materialized and sorted off MainActor. This mirrors the
    /// terminal tail of `publishSnapshot` but deliberately contains no O(width) map/filter/sort.
    private func publishPreparedTerminalSnapshot(
        categoryID: String,
        complete: Bool,
        presentation: PreparedTerminalPresentation
    ) {
        let elapsedTotal = sampleScanRate()
        snapshot = ScanSnapshot(
            categoryID: categoryID,
            rows: presentation.rows,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            isFinished: true,
            elapsed: elapsedTotal,
            isComplete: complete,
            bytesPerSecond: bytesPerSecondEMA,
            estimatedRemaining: nil,
            rowRollup: presentation.rowRollup
        )
        snapshotTreeRowsBySort = presentation.treeRowsBySort
        lastFinishedCategoryID = categoryID
        // Assignment is O(1); TerminalPresentationWorker still owns the old storage and releases
        // it on its actor executor. `removeAll` here would destruct every key/row on MainActor.
        lastIngestAt = [:]
        lastStreamSortedIds = []
        lastStreamSortCacheKey = (-1, -1)

        let indexSnapshot = (
            buckets: buckets.count,
            dirIndex: dirIndex.count,
            fileLeaves: fileLeaves.count
        )
        if indexSnapshot != lastIndexSnapshot {
            lastIndexSnapshot = indexSnapshot
            bumpStructuralRevision()
        } else {
            bumpTickRevision()
        }
    }

    /// Retirement is intentionally fire-and-observe: the terminal snapshot is already safe to
    /// render, so a large generic-executor teardown must not keep the scanning spinner alive.
    private func scheduleTerminalRetirement(_ worker: TerminalPresentationWorker) {
        Task { @MainActor [weak self] in
            let diagnostics = await worker.retire()
            self?.lastTerminalRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastTerminalRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private func retireTerminalWorkerAndRecord(_ worker: TerminalPresentationWorker) async {
        let diagnostics = await worker.retire()
        lastTerminalRetirementRanOnMainThread = diagnostics.ranOnMainThread
        lastTerminalRetirementDurationNanoseconds = diagnostics.durationNanoseconds
    }

    /// v2026.07.18：整盘会话的唯一物理/公开路径合同。精确 firmlink 规则和 Data 根
    /// fallback 在这里一次冻结；容量投影、TCC、Tree 逆投影和完整性证据不得再各自拼路径。
    private static func makeFullDiskPathNamespace() -> ScanPathNamespace {
        let firmlinkRules = Firmlinks.load()
            .map { source, target in
                let publicPrefix = source.hasPrefix("/") ? source : "/" + source
                let relativeTarget = target.hasPrefix("/") ? String(target.dropFirst()) : target
                return ScanPathPrefixMapping(
                    sourcePrefix: fullDiskDataRootPath + "/" + relativeTarget,
                    destinationPrefix: publicPrefix
                )
            }
        return ScanPathNamespace(
            physicalRoot: fullDiskDataRootPath,
            publicRoot: "/",
            mappings: firmlinkRules
        )
    }

    private func displayPathForScanNode(_ path: String, rootPath: String) -> String {
        guard rootPath == "/" else { return path }
        return fullDiskPathNamespace.publicPath(forPhysicalPath: path)
    }

    /// Tree 行始终保存公开路径；只有整盘会话需要在真正触碰文件系统前逆投影回 Data 卷。
    /// snapshot category 是会话身份，不能仅凭路径以 `/` 开头判断，否则普通自定义扫描会
    /// 被错误重写。
    private var treeScanPathNamespace: ScanPathNamespace? {
        guard snapshot.categoryID == ScanCategory.fullDisk.id,
              currentRootPath == "/"
        else { return nil }
        return fullDiskPathNamespace
    }

    nonisolated static func bucketProjection(nodePath: String, rootPath: String) -> (tail: String, bucketPath: String)? {
        if rootPath == "/" {
            guard nodePath.hasPrefix("/"), nodePath != "/" else { return nil }
            let tail = String(nodePath.dropFirst())
            guard let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init),
                  !firstSegment.isEmpty else { return nil }
            return (tail, "/" + firstSegment)
        }
        guard nodePath.hasPrefix(rootPath + "/") else { return nil }
        let tail = String(nodePath.dropFirst(rootPath.count + 1))
        guard let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init),
              !firstSegment.isEmpty else { return nil }
        return (tail, "\(rootPath)/\(firstSegment)")
    }

    // MARK: - T3 多层下钻 API

    /// 给 TreeBrowserView 用：取某目录路径下"直接子项"按 size 降序排好的列表。
    /// `path` 必须是当前扫描根的子路径或根本身。返回数组顺序稳定（size 大在前，size 相同按 path 升序）。
    public func directChildren(of path: String) -> [TreeRow] {
        directChildren(of: path, sortedBy: .sizeDesc)
    }

    /// v1.0 T5：支持自定义排序键的列出。供 TreeBrowserView 表头点击切排序。
    /// 排序稳定性：主键相等时一律按 path 升序兜底，保证 ForEach 不抖。
    ///
    /// v2026.07.19：完成扫描已经持有 `childEdges` 时，第一帧不能退回空白长
    /// loading，也不能在 MainActor 上复制、投影和排序整个宽目录。cache miss 只同步
    /// 生成一个严格有界的可见预览，完整行集、全部排序键和 mtime 补齐仍归后台
    /// `MemoryTreePresentationWorker`。generation + task token + source revision 防止旧投影
    /// 覆盖新树。
    public func directChildren(of path: String, sortedBy key: TreeSortKey) -> [TreeRow] {
        // 扫描中禁用树表从 staging / snapshot 拉半成品数据。扫描期间树表只显示
        // loading，等最终快照发布后再一次性展示稳定节点，避免滚动卡顿
        // 和 8KB / 0KB 这种目录 inode 半成品误导用户。
        if isScanning {
            return []
        }
        // v2026.07.18: an explicit refresh owns this subtree's producer boundary. Keep the last
        // exact projection visible while it runs, but do not start a memory/disk fetch from the
        // superseded index; the atomic refresh transaction will publish every sort on completion.
        if indexedSubtreeRequests.keys.contains(where: {
            Self.pathBelongsToSubtree(path, rootPath: $0)
        }) {
            return treeChildrenCache["\(path)|\(key.rawValue)"] ?? []
        }
        // v1.5：多根扫描伪路径分支——把 perRootProgress 里的真实根升级成顶层 TreeRow。
        // 没有这一支时 path == "(多目录)" / "(开发者构建产物)" 在 childEdges / 按需扫描里
        // 都查不到真实文件系统子项 → directChildren 返 [] → TreeBrowserView 渲染
        // "No expandable children yet"（用户截图反馈）。
        // 真实根（如 ~/Library/Caches）展开后走的还是原 directChildren 逻辑。
        if path == ScanCoordinator.versionedRootSentinelPath {
            // v2026.06.21：开发者旧版本扫描不进 BulkScanner，所以 perRootProgress 是空的。
            // 直接把 snapshot.rows 升级为顶层 TreeRow——title/bytes 都现成，
            // 复用 [synthesizeVersionedTopLevel] 集中维护排序与 hasChildren=false 语义。
            return synthesizeVersionedTopLevel(sortedBy: key)
        }
        if path == ScanCoordinator.commonAppCacheSentinelPath {
            return snapshotTopLevelRows(sortedBy: key)
        }
        if ScanCoordinator.multiRootSentinelPaths.contains(path) {
            return synthesizeMultiRootTopLevel(sortedBy: key)
        }
        // Completed root rows were already materialized for every sort on the terminal worker.
        // Prefer that O(1) cache over rebuilding the same childEdges bucket in a view getter.
        if path == currentRootPath, !isScanning, snapshot.isFinished {
            return snapshotTopLevelRows(sortedBy: key)
        }
        if let kids = childEdges[path] {
            if let cached = cachedTreeChildren(path: path, sortedBy: key) {
                return cached
            }
            let cacheKey = "\(path)|\(key.rawValue)"
            if let preview = indexedTreePreviewCache[cacheKey],
               preview.sourceRevision == pruneSourceRevision,
               preview.generation == treeFetchGeneration,
               preview.localeIdentifier == presentationLocale.identifier {
                lastIndexedTreePreviewFanOut = preview.fanOut
                lastIndexedTreePreviewInspectedCount = preview.inspectedCount
                lastIndexedTreePreviewMaterializedCount = preview.rows.count
                if !isPrimaryScanSettling, !hasInFlightTreeChildren(path: path) {
                    startMemoryTreeProjection(
                        path: path,
                        kids: kids,
                        sortedBy: key
                    )
                }
                return preview.rows
            }
            // The entry is bounded, so dropping a stale preview cannot itself become a wide
            // MainActor deallocation. Session-wide cleanup also clears this dictionary.
            indexedTreePreviewCache.removeValue(forKey: cacheKey)
            let started = DispatchTime.now().uptimeNanoseconds
            let firstFrame = materializeBoundedIndexedChildrenPreview(
                kids: kids,
                sortedBy: key
            )
            indexedTreePreviewCache[cacheKey] = IndexedTreePreviewCacheEntry(
                sourceRevision: pruneSourceRevision,
                generation: treeFetchGeneration,
                localeIdentifier: presentationLocale.identifier,
                fanOut: kids.count,
                inspectedCount: lastIndexedTreePreviewInspectedCount,
                rows: firstFrame
            )
            if !isPrimaryScanSettling, !hasInFlightTreeChildren(path: path) {
                startMemoryTreeProjection(
                    path: path,
                    kids: kids,
                    sortedBy: key
                )
                let elapsedMs = Double(
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000
                GSYLog.info(
                    .tree,
                    "tree.index.preview_ready path=\(path) sort=\(key.rawValue) "
                        + "fanout=\(kids.count) inspected=\(lastIndexedTreePreviewInspectedCount) "
                        + "rows=\(firstFrame.count) limit=\(Self.indexedTreeFirstFramePreviewCapacity) "
                        + "ui_bounded=true elapsed_ms=\(String(format: "%.2f", elapsedMs))"
                )
            }
            return firstFrame
        }
        // 内存索引不命中。enableTreeDeepIndex=on 时这就是"真没有"，直接返空（保持旧语义）。
        guard !enableTreeDeepIndex else { return [] }
        // deepIndex=off 路径：进按需子树扫描缓存。
        let cacheKey = "\(path)|\(key.rawValue)"
        if let cached = cachedTreeChildren(path: path, sortedBy: key) {
            // v1.3.zz 流式修复 ②：扫描进行中时，cache 里的"空快照"会被周期性清掉
            // （见 invalidateEmptyCachesDuringScan），这里只在真正命中**非空** cache 时才返回。
            // 这样可以解决"第一次树形出来就空，再切回来还空"的死锁——
            // 扫描中从来不让一个空结果被钉死。
            if !cached.isEmpty || !isScanning {
                return cached
            }
        }
        // cache miss：启动 staged fetch（同 path 复用，不重复发）。
        if !isScanning, !isPrimaryScanSettling, !hasInFlightTreeChildren(path: path) {
            startTreeChildrenFetch(path: path, sortedBy: key, cacheKey: cacheKey)
        }
        return []
    }

    /// Immediate disclosure preview for an already completed deep index.
    ///
    /// Both inspected identities and emitted rows have hard caps. In particular, filtering
    /// tombstones must not use `kids.lazy.filter(...).prefix(...)`: if most children were deleted,
    /// that shape could still walk the complete Set on MainActor. The complete, authoritative
    /// projection is always produced off-main and replaces this loading preview atomically.
    private func materializeBoundedIndexedChildrenPreview(
        kids: Set<String>,
        sortedBy key: TreeSortKey
    ) -> [TreeRow] {
        var rows: [TreeRow] = []
        rows.reserveCapacity(min(kids.count, Self.indexedTreeFirstFramePreviewCapacity))
        let tombstones = deletedPathTombstones.matcher
        var inspectedCount = 0
        for childPath in kids {
            guard inspectedCount < Self.indexedTreeFirstFrameInspectionCapacity,
                  rows.count < Self.indexedTreeFirstFramePreviewCapacity
            else { break }
            inspectedCount &+= 1
            guard !tombstones.contains(childPath), !isWhitelisted(childPath) else { continue }
            let projectedState = projectedTreeState(for: childPath)
            if let aggregate = dirIndex[childPath] {
                rows.append(TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: aggregate.bytes,
                    logicalBytes: aggregate.logicalBytes,
                    fileCount: aggregate.fileCount,
                    isDirectory: true,
                    hasChildren: !(childEdges[childPath]?.isEmpty ?? true),
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: aggregate.modificationDate
                        ?? cachedDirMtimeFallback(forPath: childPath)
                ))
            } else if let leaf = fileLeaves[childPath] {
                rows.append(TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: leaf.bytes,
                    logicalBytes: leaf.logicalBytes,
                    fileCount: leaf.fileCount,
                    isDirectory: leaf.isDir,
                    hasChildren: false,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: leaf.modificationDate
                ))
            } else {
                rows.append(TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: 0,
                    fileCount: 0,
                    isDirectory: false,
                    hasChildren: false,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness
                ))
            }
        }
        lastIndexedTreePreviewFanOut = kids.count
        lastIndexedTreePreviewInspectedCount = inspectedCount
        lastIndexedTreePreviewMaterializedCount = rows.count
        indexedTreePreviewBuildCount &+= 1
        rows.sort {
            Self.sortTreeRow($0, before: $1, by: key, locale: presentationLocale)
        }
        return rows
    }

    /// Freezes only COW roots and bounded task-owner metadata for one Tree presentation request.
    /// The caller supplies the currently expanded path set, so MainActor performs at most one cache
    /// lookup per expanded directory; it never walks or materializes the visible row graph here.
    ///
    /// v2026.07.18 P1: the returned revision is checked again after the generic-executor worker
    /// finishes. Any cache write, prune/scan rotation, task replacement or scanning-state change
    /// invalidates the result before it can overwrite a newer Tree frame.
    func makeTreeFlatProjectionSource(
        rootPath: String,
        sortedBy key: TreeSortKey,
        expandedPaths: Set<String>
    ) -> TreeFlatProjectionSource {
        let rootRows = directChildren(of: rootPath, sortedBy: key)
        var childrenByParent: [String: [TreeRow]] = [:]
        childrenByParent.reserveCapacity(expandedPaths.count)
        var fetchingPaths = Set<String>()
        fetchingPaths.reserveCapacity(expandedPaths.count)

        for path in expandedPaths where path != rootPath {
            childrenByParent[path] = directChildren(of: path, sortedBy: key)
            if isFetchingChildren(of: path, sortedBy: key) {
                fetchingPaths.insert(path)
            }
        }
        // v2026.07.20: freeze raw measurement ownership here. The full worker already gates its
        // empty-root placeholder on `rootRows.isEmpty`; incremental projection needs the raw bit
        // after shallow rows appear so the expanded parent keeps its inline spinner until exact
        // metrics and sorting reach their terminal commit.
        let rootIsFetching = isFetchingChildren(of: rootPath, sortedBy: key)
        let revision = TreeFlatProjectionSourceRevision(
            sourceRevision: pruneSourceRevision,
            generation: treeFetchGeneration,
            isScanning: isScanning
        )
        return TreeFlatProjectionSource(
            revision: revision,
            rootRows: rootRows,
            childrenByParent: childrenByParent,
            fetchingPaths: fetchingPaths,
            isFetchingRoot: rootIsFetching,
            // Freeze the matcher in the same source revision as the raw COW row arrays. Filtering
            // those arrays here would put 1k-40k row work back on MainActor; the projection workers
            // own that work and the revision CAS rejects any older matcher/row combination.
            receiptTombstones: deletedPathTombstones.presentationMatcher,
            deletionEvaluation: treeDeletionEvaluationSnapshot
        )
    }

    var treeDeletionEvaluationSnapshot: TreeDeletionEvaluationSnapshot {
        TreeDeletionEvaluationSnapshot(
            cacheNamespace: treeDeletionEvaluationCacheNamespace,
            engine: engine,
            trie: trie,
            home: home
        )
    }

    func treeFlatProjectionSourceIsCurrent(
        _ revision: TreeFlatProjectionSourceRevision
    ) -> Bool {
        revision.sourceRevision == pruneSourceRevision
            && revision.generation == treeFetchGeneration
            && revision.isScanning == isScanning
    }

    /// 文件系统测量的 identity 是 path，不是展示排序。本 getter 只对请求的
    /// exact path/sort cache 做 O(1) 命中；exact miss 时可以复用其它 sort 已完整测量的
    /// COW 数组作为暂时顺序，但排序比较和 authoritative cache 写入必须由后台
    /// worker 完成。禁止在此恢复 `measured.sorted`，否则切换列排序会再次按宽度
    /// 占用 MainActor。暂时返回期间保持 in-flight，完整全局排序 commit 后才发终态 revision。
    private func cachedTreeChildren(path: String, sortedBy key: TreeSortKey) -> [TreeRow]? {
        let requestedKey = "\(path)|\(key.rawValue)"
        if let exact = treeChildrenCache[requestedKey] {
            return exact
        }
        for existingSort in TreeSortKey.allCases where existingSort != key {
            let existingKey = "\(path)|\(existingSort.rawValue)"
            guard let measured = treeChildrenCache[existingKey] else { continue }
            startTreeSortProjection(path: path, sortedBy: key, rows: measured)
            // Existing rows remain visible for this single async projection frame. New production
            // measurements eagerly prepare all sort variants, so this branch is only for legacy or
            // test-seeded caches and never performs comparison work in a SwiftUI getter.
            return measured
        }
        return nil
    }

    private func startMemoryTreeProjection(
        path: String,
        kids: Set<String>,
        sortedBy key: TreeSortKey
    ) {
        guard !isPrimaryScanSettling else { return }
        let cacheKey = "\(path)|\(key.rawValue)"
        guard treeChildrenTasks[cacheKey] == nil else { return }
        let generation = treeFetchGeneration
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareMemoryTreeProjection(
                path: path,
                initialKids: kids,
                cacheKey: cacheKey,
                expectedGeneration: generation,
                expectedTaskToken: token
            )
            self.finishTreeChildrenTask(
                cacheKey: cacheKey,
                token: token,
                publishTerminalRevision: true,
                changedPath: path
            )
            self.resumeOneMtimeContinuationIfReady()
        }
        treeChildrenTasks[cacheKey] = TreeChildrenTaskState(
            token: token,
            task: task,
            ownerKind: .presentation
        )
        treeChildrenInFlight.insert(cacheKey)
        treeChildrenOwnershipRevision &+= 1
    }

    private func prepareMemoryTreeProjection(
        path: String,
        initialKids: Set<String>,
        cacheKey: String,
        expectedGeneration: UUID,
        expectedTaskToken: UUID,
        beforeCommitForTesting: (@MainActor () -> Void)? = nil
    ) async {
        var pendingTestHook = beforeCommitForTesting
        var attemptCount = 0
        var currentKids = initialKids
        while !Task.isCancelled {
            attemptCount &+= 1
            guard treeChildrenTaskIsCurrent(
                cacheKey: cacheKey,
                token: expectedTaskToken,
                generation: expectedGeneration
            ) else { return }

            let sourceRevision = pruneSourceRevision
            let locale = presentationLocale
            let worker = MemoryTreePresentationWorker(
                retainedState: MemoryTreeRetainedState(
                    cache: treeChildrenCache,
                    kids: currentKids,
                    dirIndex: dirIndex,
                    childEdges: childEdges,
                    fileLeaves: fileLeaves,
                    evidence: treeScanEvidenceProjection,
                    mtimeCache: mtimeFallbackCache
                ),
                parentPath: path,
                tombstones: deletedPathTombstones.matcher,
                whitelist: whitelistSnapshot,
                locale: locale
            )
            var prepared = await worker.prepare()
            if let hook = pendingTestHook {
                pendingTestHook = nil
                hook()
            }
            guard !Task.isCancelled,
                  treeChildrenTaskIsCurrent(
                    cacheKey: cacheKey,
                    token: expectedTaskToken,
                    generation: expectedGeneration
                  )
            else {
                prepared = nil
                await retireMemoryTreeWorkerAndRecord(worker)
                return
            }
            guard sourceRevision == pruneSourceRevision,
                  locale.identifier == presentationLocale.identifier
            else {
                prepared = nil
                await retireMemoryTreeWorkerAndRecord(worker)
                guard let latestKids = childEdges[path] else { return }
                currentKids = latestKids
                await Task.yield()
                continue
            }
            guard let prepared else {
                await retireMemoryTreeWorkerAndRecord(worker)
                return
            }

            treeChildrenCache = prepared.cache
            // A complete projection has now replaced the non-authoritative preview for every
            // ordering. TreeSortKey is a fixed small enum, so this cleanup is O(1) with respect to
            // directory width and cannot reintroduce a MainActor fan-out walk.
            for sortKey in TreeSortKey.allCases {
                indexedTreePreviewCache.removeValue(
                    forKey: "\(path)|\(sortKey.rawValue)"
                )
            }
            lastTreePreparationRanOnMainThread = prepared.ranOnMainThread
            lastTreePreparationAttemptCount = attemptCount
            let acceptedAllMtimePaths = enqueueMtimeFallbackProbes(
                prepared.missingMtimePaths
            )
            if prepared.hasMoreMtimePaths || !acceptedAllMtimePaths {
                mtimeFallbackContinuationParents.insert(path)
            } else {
                mtimeFallbackContinuationParents.remove(path)
            }
            scheduleMemoryTreeRetirement(worker)
            return
        }
    }

    private func scheduleMemoryTreeRetirement(
        _ worker: MemoryTreePresentationWorker
    ) {
        Task { @MainActor [weak self] in
            await Task.yield()
            let diagnostics = await worker.retire()
            self?.lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private func retireMemoryTreeWorkerAndRecord(
        _ worker: MemoryTreePresentationWorker
    ) async {
        let diagnostics = await worker.retire()
        lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
        lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
    }

    private func startTreeSortProjection(path: String, sortedBy key: TreeSortKey, rows: [TreeRow]) {
        guard !isPrimaryScanSettling else { return }
        let cacheKey = "\(path)|\(key.rawValue)"
        guard treeChildrenTasks[cacheKey] == nil else { return }
        let generation = treeFetchGeneration
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.storeFetchedChildren(
                path: path,
                sortedBy: key,
                rows: rows,
                authority: .shallowIdentityComplete,
                expectedGeneration: generation,
                expectedTaskToken: token,
                reconcileParent: false,
                publishRevisionOnCommit: false
            )
            self.finishTreeChildrenTask(
                cacheKey: cacheKey,
                token: token,
                publishTerminalRevision: true,
                changedPath: path
            )
        }
        treeChildrenTasks[cacheKey] = TreeChildrenTaskState(
            token: token,
            task: task,
            ownerKind: .presentation
        )
        treeChildrenInFlight.insert(cacheKey)
        treeChildrenOwnershipRevision &+= 1
    }

    private func scheduleLocaleReprojection(locale: Locale) {
        treeLocaleProjectionTask?.cancel()
        let token = UUID()
        treeLocaleProjectionToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reprojectLocaleOffMain(locale: locale, token: token)
        }
        treeLocaleProjectionTask = task
    }

    private func reprojectLocaleOffMain(locale: Locale, token: UUID) async {
        while !Task.isCancelled,
              treeLocaleProjectionToken == token,
              presentationLocale.identifier == locale.identifier {
            let sourceRevision = pruneSourceRevision
            let sortKey = mainListSortKey
            let worker = TreeLocalePresentationWorker(
                retainedState: TreeLocaleRetainedState(
                    cache: treeChildrenCache,
                    snapshotTreeRows: snapshotTreeRowsBySort,
                    perRootTreeRows: perRootTreeRowsBySort,
                    snapshotRows: snapshot.rows
                ),
                locale: locale,
                mainSortKey: sortKey
            )
            var prepared = await worker.prepare()
            guard !Task.isCancelled,
                  treeLocaleProjectionToken == token,
                  presentationLocale.identifier == locale.identifier
            else {
                prepared = nil
                _ = await worker.retire()
                return
            }
            guard sourceRevision == pruneSourceRevision,
                  sortKey == mainListSortKey
            else {
                prepared = nil
                _ = await worker.retire()
                await Task.yield()
                continue
            }
            guard let prepared else {
                _ = await worker.retire()
                return
            }
            treeChildrenCache = prepared.cache
            snapshotTreeRowsBySort = prepared.snapshotTreeRows
            perRootTreeRowsBySort = prepared.perRootTreeRows
            if snapshot.isFinished {
                snapshot = ScanSnapshot(
                    categoryID: snapshot.categoryID,
                    rows: prepared.snapshotRows,
                    totalBytes: snapshot.totalBytes,
                    scannedFileCount: snapshot.scannedFileCount,
                    isFinished: snapshot.isFinished,
                    elapsed: snapshot.elapsed,
                    isComplete: snapshot.isComplete,
                    bytesPerSecond: snapshot.bytesPerSecond,
                    estimatedRemaining: snapshot.estimatedRemaining,
                    rowRollup: prepared.snapshotRowRollup
                )
            }
            lastTreePreparationRanOnMainThread = prepared.ranOnMainThread
            bumpChildrenCacheVersion()
            bumpStructuralRevision(advanceSourceRevision: false)
            treeLocaleProjectionTask = nil
            treeLocaleProjectionToken = nil
            Task { @MainActor [weak self] in
                await Task.yield()
                let diagnostics = await worker.retire()
                self?.lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
                self?.lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
            }
            return
        }
    }

    private func hasInFlightTreeChildren(path: String) -> Bool {
        let prefix = "\(path)|"
        return treeChildrenInFlight.contains { $0.hasPrefix(prefix) }
    }

    @MainActor
    private func startTreeChildrenFetch(
        path: String,
        sortedBy key: TreeSortKey,
        cacheKey: String
    ) {
        guard !isPrimaryScanSettling,
              !treeChildrenInFlight.contains(cacheKey)
        else { return }
        treeChildrenInFlight.insert(cacheKey)
        GSYLog.info(.flow, "tree.children.fetch.start path=\(path) sort=\(key.rawValue)")
        let dispatchedGeneration = treeFetchGeneration
        let taskToken = UUID()
        let accessProjection = treeScanEvidenceProjection
        let pathNamespace = treeScanPathNamespace
        let scanOptions = retainedScanOptions
        let knownAllocationCatalog = allocationCatalog
        let physicalPath = pathNamespace?.physicalPath(forPublicPath: path) ?? path
        let measurementIdentity = TreeFilesystemMeasurementIdentity(
            publicPath: path,
            physicalPath: physicalPath
        )
        let leaseDomain = treeFilesystemLeaseDomain

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled,
                  self.treeChildrenTaskIsCurrent(
                    cacheKey: cacheKey,
                    token: taskToken,
                    generation: dispatchedGeneration
                  )
            else {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                return
            }

            let shallowStarted = DispatchTime.now().uptimeNanoseconds
            let shallowLease = await leaseDomain.run(
                identity: measurementIdentity,
                stage: .shallow,
                intentID: taskToken
            ) {
                Self.scanDirectChildrenShallow(
                    rootPath: path,
                    accessProjection: accessProjection,
                    pathNamespace: pathNamespace,
                    options: scanOptions,
                    knownAllocationCatalog: knownAllocationCatalog
                )
            }
            guard case .produced(let shallowMeasurement) = shallowLease else {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                GSYLog.info(
                    .flow,
                    "tree.children.fetch.drop_stale_stage=shallow_lease path=\(path) "
                        + "sort=\(key.rawValue) intent=\(taskToken)"
                )
                return
            }
            self.setTreeChildrenTaskOwnerKind(
                .presentation,
                cacheKey: cacheKey,
                token: taskToken
            )
            // TreeFilesystemLeaseDomain creates and owns the detached producer. Normal terminal
            // must still enumerate every direct child; cancellation/typed incomplete are the only
            // early exits, and the overlapping successor cannot enter until that producer returns.
            let shallowRows = shallowMeasurement.rows
            let shallowElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - shallowStarted) / 1_000_000

            guard !Task.isCancelled,
                  self.treeChildrenTaskIsCurrent(
                    cacheKey: cacheKey,
                    token: taskToken,
                    generation: dispatchedGeneration
                  )
            else {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                GSYLog.info(.flow, "tree.children.fetch.drop_stale_stage=shallow path=\(path) sort=\(key.rawValue) rows=\(shallowRows.count) elapsed_ms=\(String(format: "%.2f", shallowElapsedMs))")
                return
            }
            if !shallowMeasurement.incompleteIssues.isEmpty {
                await self.storeFetchedChildren(
                    path: path,
                    sortedBy: key,
                    rows: shallowMeasurement.rows,
                    authority: shallowMeasurement.authority,
                    parentState: shallowMeasurement.parentState,
                    incompleteIssues: shallowMeasurement.incompleteIssues,
                    expectedGeneration: dispatchedGeneration,
                    expectedTaskToken: taskToken,
                    publishRevisionOnCommit: false
                )
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                GSYLog.notice(.scan,
                              "tree.children.fetch.tcc_skipped path=\(path) sort=\(key.rawValue)")
                return
            }
            if !self.isScanning {
                await self.storeFetchedChildren(
                    path: path,
                    sortedBy: key,
                    rows: shallowRows,
                    authority: .shallowIdentityComplete,
                    expectedGeneration: dispatchedGeneration,
                    expectedTaskToken: taskToken,
                    publishRevisionOnCommit: false
                )
                self.publishTreeChildrenShallowFrame(
                    path: path,
                    cacheKey: cacheKey,
                    token: taskToken
                )
                GSYLog.info(
                    .flow,
                    "tree.children.fetch.shallow_frame path=\(path) sort=\(key.rawValue) "
                        + "direct_children=\(shallowRows.count) identity_complete=true "
                        + "metrics_pending=true fetching=true "
                        + "elapsed_ms=\(String(format: "%.2f", shallowElapsedMs))"
                )
            }

            guard !self.isScanning,
                  !Task.isCancelled,
                  self.treeChildrenTaskIsCurrent(
                    cacheKey: cacheKey,
                    token: taskToken,
                    generation: dispatchedGeneration
                  )
            else {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                return
            }

            let deepStarted = DispatchTime.now().uptimeNanoseconds
            GSYLog.info(
                .flow,
                "tree.children.enrichment.start path=\(path) sort=\(key.rawValue) ui_blocking=false"
            )
            self.setTreeChildrenTaskOwnerKind(
                .filesystem,
                cacheKey: cacheKey,
                token: taskToken
            )
            let currentAllocationCatalog = self.allocationCatalog ?? knownAllocationCatalog
            let deepLease = await leaseDomain.run(
                identity: measurementIdentity,
                stage: .deep,
                intentID: taskToken
            ) {
                // Lease admission precedes gate admission. Reversing this order lets a blocked
                // overlapping request consume one of two permits and can deadlock the predecessor
                // that still needs a permit to terminate.
                guard await Self.treeChildrenFetchGate.acquire() else {
                    return TreeChildrenProducerOutput.terminal(.cancelled)
                }
                let producerOutput: TreeChildrenProducerOutput
                if Task.isCancelled {
                    producerOutput = .terminal(.cancelled)
                } else {
                    producerOutput = await Self.scanDirectChildrenProducer(
                        rootPath: path,
                        pathNamespace: pathNamespace,
                        options: scanOptions,
                        knownAllocationCatalog: currentAllocationCatalog
                    )
                }
                // acquire success has one linear release path, including cancellation.
                await Self.treeChildrenFetchGate.release()
                return producerOutput
            }
            guard case .produced(let producerOutput) = deepLease else {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                GSYLog.info(
                    .flow,
                    "tree.children.enrichment.drop_stale path=\(path) sort=\(key.rawValue) "
                        + "intent=\(taskToken) reason=lease_cancelled"
                )
                return
            }
            self.setTreeChildrenTaskOwnerKind(
                .presentation,
                cacheKey: cacheKey,
                token: taskToken
            )
            let projectionTask = Task.detached(priority: .userInitiated) {
                Self.projectDirectChildrenProducerOutput(
                    producerOutput,
                    rootPath: path,
                    accessProjection: accessProjection
                )
            }
            let measurement = await withTaskCancellationHandler {
                await projectionTask.value
            } onCancel: {
                projectionTask.cancel()
            }
            let deepElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - deepStarted) / 1_000_000

            guard !Task.isCancelled,
                  self.treeChildrenTaskIsCurrent(
                    cacheKey: cacheKey,
                    token: taskToken,
                    generation: dispatchedGeneration
                  )
            else {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                GSYLog.info(.flow, "tree.children.enrichment.drop_stale path=\(path) sort=\(key.rawValue) rows=\(measurement.rows.count) elapsed_ms=\(String(format: "%.2f", deepElapsedMs))")
                return
            }
            if measurement.rows.isEmpty && self.isScanning {
                self.finishTreeChildrenTask(
                    cacheKey: cacheKey,
                    token: taskToken,
                    publishTerminalRevision: true,
                    changedPath: path
                )
                GSYLog.info(.flow, "tree.children.enrichment.drop_scanning path=\(path) sort=\(key.rawValue) elapsed_ms=\(String(format: "%.2f", deepElapsedMs))")
                return
            }
            await self.storeFetchedChildren(
                path: path,
                sortedBy: key,
                rows: measurement.rows,
                authority: measurement.authority,
                parentState: measurement.parentState,
                incompleteIssues: measurement.incompleteIssues,
                expectedGeneration: dispatchedGeneration,
                expectedTaskToken: taskToken,
                publishRevisionOnCommit: false
            )
            // Exact rows and requested ordering are already committed. Clear ownership first and
            // publish one terminal revision so no subscriber can observe exact rows still loading
            // or pending rows already idle.
            self.finishTreeChildrenTask(
                cacheKey: cacheKey,
                token: taskToken,
                publishTerminalRevision: true,
                changedPath: path
            )
            GSYLog.info(.flow, "tree.children.enrichment.finish path=\(path) sort=\(key.rawValue) rows=\(measurement.rows.count) authority=\(measurement.authority.logValue) elapsed_ms=\(String(format: "%.2f", deepElapsedMs))")
            // v2026.06.21 性能：这里仍只 bump childrenCacheVersion，避免每次后台
            // 回写都触发整树 structural rebuild。
        }
        treeChildrenTasks[cacheKey] = TreeChildrenTaskState(
            token: taskToken,
            task: task,
            ownerKind: .filesystem
        )
        treeChildrenOwnershipRevision &+= 1
    }

    /// 后台按需子节点扫描结果的唯一写入口。
    ///
    /// 除了写 `path|sortKey` 自身 cache，还会把 `path` 这条父行同步回已存在的祖先 cache。
    /// 这样可以避免竞态下出现"父目录仍是 0KB，但展开后子项已经有几十 GB"的视觉矛盾。
    /// 完整 deep 结果替换父行；shallow 已完整列出直接子项，但子树容量仍只能
    /// 提高 lower bound；partial 连直接枚举都不完整。具体合同统一由
    /// `TreeChildrenMeasurementAuthority` 表达。
    private func storeFetchedChildren(
        path: String,
        sortedBy key: TreeSortKey,
        rows: [TreeRow],
        authority: TreeChildrenMeasurementAuthority,
        parentState: TreeScanEvidenceProjection.ProjectedState? = nil,
        incompleteIssues: [ScanIncompleteIssue]? = nil,
        expectedGeneration: UUID? = nil,
        expectedTaskToken: UUID? = nil,
        reconcileParent: Bool = true,
        publishRevisionOnCommit: Bool = true,
        beforeCommitForTesting: (@MainActor () -> Void)? = nil
    ) async {
        let cacheKey = "\(path)|\(key.rawValue)"
        var pendingTestHook = beforeCommitForTesting
        var attemptCount = 0
        while !Task.isCancelled {
            attemptCount &+= 1
            if let expectedGeneration,
               expectedGeneration != treeFetchGeneration {
                return
            }
            if let expectedTaskToken,
               treeChildrenTasks[cacheKey]?.token != expectedTaskToken {
                return
            }

            let sourceRevision = pruneSourceRevision
            let evidenceRevision = incompleteEvidenceSourceRevision
            let locale = presentationLocale
            let worker = TreeCachePresentationWorker(
                retainedState: TreeCacheRetainedState(
                    cache: treeChildrenCache,
                    primaryEvidence: primaryIncompleteEvidence,
                    treeEvidenceByRoot: treeIncompleteEvidenceByRoot,
                    previousIssues: incompleteScanIssues,
                    previousPermissionPaths: permissionDeniedPaths,
                    previousTCCPaths: tccProtectedSkippedPaths,
                    previousAllPaths: incompleteScanPaths,
                    previousTreeProjection: treeScanEvidenceProjection,
                    inputRows: rows
                ),
                path: path,
                requestedSort: key,
                authority: authority,
                measuredParentState: parentState,
                incompleteIssues: incompleteIssues,
                tombstones: deletedPathTombstones.matcher,
                whitelist: whitelistSnapshot,
                locale: locale,
                reconcileParent: reconcileParent
            )
            var prepared = await worker.prepare()

            if let hook = pendingTestHook {
                pendingTestHook = nil
                hook()
            }

            guard !Task.isCancelled else {
                prepared = nil
                await retireTreeWorkerAndRecord(worker)
                return
            }
            if let expectedGeneration,
               expectedGeneration != treeFetchGeneration {
                prepared = nil
                await retireTreeWorkerAndRecord(worker)
                return
            }
            if let expectedTaskToken,
               treeChildrenTasks[cacheKey]?.token != expectedTaskToken {
                prepared = nil
                await retireTreeWorkerAndRecord(worker)
                return
            }
            guard sourceRevision == pruneSourceRevision,
                  evidenceRevision == incompleteEvidenceSourceRevision,
                  locale.identifier == presentationLocale.identifier
            else {
                prepared = nil
                await retireTreeWorkerAndRecord(worker)
                await Task.yield()
                continue
            }
            guard let prepared else {
                await retireTreeWorkerAndRecord(worker)
                return
            }

            // O(1) COW swaps only. The worker retains both the old and prepared storage until the
            // next MainActor turn, so neither success nor stale rejection tears wide arrays down here.
            treeChildrenCache = prepared.cache
            if incompleteIssues != nil {
                treeIncompleteEvidenceByRoot = prepared.treeEvidenceByRoot
                incompleteEvidenceSourceRevision &+= 1
                if let evidence = prepared.evidence {
                    applyPreparedIncompleteEvidenceProjection(evidence)
                }
            }
            lastTreePreparationRanOnMainThread = prepared.ranOnMainThread
            lastTreePreparationAttemptCount = attemptCount
            if publishRevisionOnCommit {
                bumpChildrenCacheVersion(changedPath: path)
            }
            scheduleTreeRetirement(worker)
            return
        }
    }

    private func scheduleTreeRetirement(_ worker: TreeCachePresentationWorker) {
        Task { @MainActor [weak self] in
            await Task.yield()
            let diagnostics = await worker.retire()
            self?.lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private func retireTreeWorkerAndRecord(_ worker: TreeCachePresentationWorker) async {
        let diagnostics = await worker.retire()
        lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
        lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
    }

    nonisolated private static func sortKeyFromCacheKey(_ cacheKey: String) -> TreeSortKey? {
        guard let pipe = cacheKey.lastIndex(of: "|") else { return nil }
        return TreeSortKey(rawValue: String(cacheKey[cacheKey.index(after: pipe)...]))
    }

    /// 扫描结束时作废展开缓存，下一次 view body 会按当前最终快照重新拉取。
    /// 扫描会话切换已真实取消旧任务；这里不会留下仅靠 generation 丢结果、
    /// 却继续占用磁盘 IO 的后台深扫。
    @MainActor
    fileprivate func invalidateTreeCacheAfterScan() {
        let retirementWorker = TreeCacheRetirementWorker(
            cache: treeChildrenCache,
            previewCache: indexedTreePreviewCache
        )
        treeChildrenCache = [:]
        indexedTreePreviewCache = [:]
        bumpChildrenCacheVersion()
        bumpStructuralRevision(advanceSourceRevision: false)
        Task { @MainActor [weak self] in
            await Task.yield()
            let diagnostics = await retirementWorker.retire()
            self?.lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    /// Completes the exact scan-end cache lifecycle after the terminal presentation commits.
    ///
    /// Preserving the developer cache does not preserve indexed previews: those are derived from
    /// a previous `childEdges` revision and must still be retired. The terminal commit already
    /// published `childrenCacheVersion`, so this branch only advances the structural revision.
    @MainActor
    private func finalizeTreeCacheAfterScan(_ finalization: TerminalTreeCacheFinalization) {
        switch finalization {
        case .invalidateScanPeriodCache:
            invalidateTreeCacheAfterScan()
        case .preserveCommittedDeveloperProjection:
            let retirementWorker = TreeCacheRetirementWorker(
                cache: [:],
                previewCache: indexedTreePreviewCache
            )
            indexedTreePreviewCache = [:]
            bumpStructuralRevision()
            GSYLog.info(
                .flow,
                "tree.developer.terminal_cache.finalize disposition=preserve "
                    + "sort_projections=\(treeChildrenCache.count) "
                    + "filesystem_fetch_required=false"
            )
            Task { @MainActor [weak self] in
                await Task.yield()
                let diagnostics = await retirementWorker.retire()
                self?.lastTreeRetirementRanOnMainThread = diagnostics.ranOnMainThread
                self?.lastTreeRetirementDurationNanoseconds = diagnostics.durationNanoseconds
            }
        }
    }

    /// v2026.07.18 Tree P2 root-cause fix: "refresh this directory" is a real isolated subtree
    /// scan. The previous cache-only contract could never refresh an indexed directory because
    /// `directChildren` immediately rebuilt the removed rows from stale `childEdges/dirIndex`.
    /// The new transaction cancels prior subtree producers, rebuilds descendants and typed
    /// incomplete evidence off-main, then atomically swaps the index/projection generation.
    @MainActor
    public func rescanSubtree(at path: String) async {
        guard !isPrimaryScanSettling else { return }
        await rescanSubtreeTransaction(at: path, beforeCommitForTesting: nil)
    }

    private func rescanSubtreeTransaction(
        at rawPath: String,
        beforeCommitForTesting: (@MainActor () async -> Void)?,
        restoredPaths: [String] = []
    ) async {
        if isScanning {
            GSYLog.notice(.operation, "scan.cancel reason=filesystem_mutated_during_refresh")
            cancel()
            return
        }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let generation = treeFetchGeneration
        let token = UUID()
        let identity = treeFilesystemMeasurementIdentity(publicPath: path)
        let replacementCounts = beginIndexedSubtreeRequest(
            path: path,
            identity: identity,
            token: token
        )
        GSYLog.notice(
            .operation,
            "tree.subtree.refresh.start path=\(path) physical_path=\(identity.physicalPath) "
                + "intent=\(token) replaced_requests=\(replacementCounts.requests) "
                + "cancelled_producers=\(replacementCounts.producers)"
        )
        // Cancel every old Tree owner first, but keep the last published rows visible until the
        // replacement is ready. The filesystem lease, rather than the UI task token, proves that
        // each overlapping producer has really returned before this request touches disk.
        await performSubtreeRescan(
            at: path,
            expectedGeneration: generation,
            expectedRequestPath: path,
            expectedRequestToken: token,
            removeCache: false,
            beforeCommitForTesting: nil
        )
        guard indexedSubtreeRequestIsCurrent(
            path: path,
            token: token,
            generation: generation
        ) else {
            GSYLog.info(
                .operation,
                "tree.subtree.refresh.drop_stale path=\(path) intent=\(token) stage=prepare"
            )
            return
        }

        let pathNamespace = treeScanPathNamespace
        let knownAllocationCatalog = allocationCatalog
        let options = retainedScanOptions
        let leaseDomain = treeFilesystemLeaseDomain
        let scanTask: Task<IndexedSubtreeMeasurement?, Never> = Task(priority: .userInitiated) {
            let lease = await leaseDomain.run(
                identity: identity,
                stage: .indexedSubtree,
                intentID: token
            ) { () async -> IndexedSubtreeMeasurement? in
                guard await Self.treeChildrenFetchGate.acquire() else { return nil }
                let measurement: IndexedSubtreeMeasurement?
                if Task.isCancelled {
                    measurement = nil
                } else {
                    measurement = await Self.scanIndexedSubtreeOnDemand(
                        rootPath: path,
                        pathNamespace: pathNamespace,
                        options: options,
                        knownAllocationCatalog: knownAllocationCatalog
                    )
                }
                await Self.treeChildrenFetchGate.release()
                return measurement
            }
            switch lease {
            case .produced(let measurement): return measurement
            case .dropped: return nil
            }
        }
        indexedSubtreeScanTasks[path] = IndexedSubtreeTaskState(
            token: token,
            identity: identity,
            task: scanTask,
            cancel: { scanTask.cancel() }
        )
        let measurement = await scanTask.value
        guard indexedSubtreeRequestIsCurrent(
            path: path,
            token: token,
            generation: generation
        ) else {
            finishIndexedSubtreeRequest(path: path, token: token)
            GSYLog.info(
                .operation,
                "tree.subtree.refresh.drop_stale path=\(path) intent=\(token) stage=measurement"
            )
            return
        }
        if indexedSubtreeScanTasks[path]?.token == token {
            indexedSubtreeScanTasks.removeValue(forKey: path)
        }

        guard let measurement else {
            finishIndexedSubtreeRequest(path: path, token: token)
            GSYLog.info(
                .operation,
                "tree.subtree.refresh.cancelled path=\(path) intent=\(token)"
            )
            bumpStructuralRevision()
            return
        }
        let committed = await commitIndexedSubtreeMeasurement(
            measurement,
            expectedGeneration: generation,
            expectedRequestPath: path,
            expectedRequestToken: token,
            beforeCommitForTesting: beforeCommitForTesting,
            restoredPaths: restoredPaths
        )
        if committed {
            GSYLog.notice(
                .operation,
                "tree.subtree.refresh.finish path=\(path) intent=\(token) "
                    + "complete=\(measurement.isComplete) directories=\(measurement.dirIndex.count) "
                    + "edges=\(measurement.childEdges.count) leaves=\(measurement.fileLeaves.count) "
                    + "issues=\(measurement.incompleteIssues.count)"
            )
            return
        }
        // A successful commit retires this owner before publishing its final Tree frame. On a
        // rejected commit, settle only our still-current request; never clear a newer refresh.
        guard indexedSubtreeRequests[path]?.token == token else { return }
        finishIndexedSubtreeRequest(path: path, token: token)
        GSYLog.info(
            .operation,
            "tree.subtree.refresh.drop_stale path=\(path) intent=\(token) stage=commit"
        )
        bumpStructuralRevision()
    }

    private func treeFilesystemMeasurementIdentity(
        publicPath rawPath: String
    ) -> TreeFilesystemMeasurementIdentity {
        let publicPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let physicalPath = treeScanPathNamespace?.physicalPath(forPublicPath: publicPath)
            ?? publicPath
        return TreeFilesystemMeasurementIdentity(
            publicPath: publicPath,
            physicalPath: physicalPath
        )
    }

    /// Installs the newest overlapping intent before any suspension. Old UI owners are cancelled
    /// immediately, while their real shallow/deep/indexed producer retirement remains owned by
    /// TreeFilesystemLeaseDomain. Non-overlapping dictionary entries are untouched.
    private func beginIndexedSubtreeRequest(
        path: String,
        identity: TreeFilesystemMeasurementIdentity,
        token: UUID
    ) -> (requests: Int, producers: Int) {
        let overlappingRequestPaths = indexedSubtreeRequests.compactMap { key, state in
            state.identity.overlaps(identity) ? key : nil
        }
        for key in overlappingRequestPaths {
            indexedSubtreeRequests.removeValue(forKey: key)
        }

        let overlappingProducerPaths = indexedSubtreeScanTasks.compactMap { key, state in
            state.identity.overlaps(identity) ? key : nil
        }
        for key in overlappingProducerPaths {
            indexedSubtreeScanTasks.removeValue(forKey: key)?.cancel()
        }
        indexedSubtreeRequests[path] = IndexedSubtreeRequestState(
            token: token,
            identity: identity
        )
        return (overlappingRequestPaths.count, overlappingProducerPaths.count)
    }

    private func indexedSubtreeRequestIsCurrent(
        path: String,
        token: UUID,
        generation: UUID
    ) -> Bool {
        generation == treeFetchGeneration
            && indexedSubtreeRequests[path]?.token == token
    }

    private func finishIndexedSubtreeRequest(path: String, token: UUID) {
        if indexedSubtreeScanTasks[path]?.token == token {
            indexedSubtreeScanTasks.removeValue(forKey: path)
        }
        if indexedSubtreeRequests[path]?.token == token {
            indexedSubtreeRequests.removeValue(forKey: path)
        }
    }

    /// v2026.07.18 Tree P2 regression fix: cache identity is the path before the final sort
    /// separator. Compare that identity through the same component-aware matcher used by prune;
    /// string concatenation made the filesystem root become `//` and prefix matching also risks
    /// treating `/Cache-old` as a descendant of `/Cache`.
    nonisolated private static func subtreeCacheKey(_ key: String, belongsTo path: String) -> Bool {
        guard let separator = key.lastIndex(of: "|") else { return false }
        let cachePath = String(key[..<separator])
        return pathBelongsToSubtree(cachePath, rootPath: path)
    }

    nonisolated private static func pathBelongsToSubtree(
        _ candidate: String,
        rootPath: String
    ) -> Bool {
        if rootPath == "/" { return candidate.hasPrefix("/") }
        return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }

    /// Wide key matching and COW rebuild run on SubtreeRescanWorker. A concurrent Tree write,
    /// task completion/replacement, prune or scan-session rotation invalidates the snapshot and
    /// retries against the latest owner; no stale transaction can resurrect removed cache state.
    private func performSubtreeRescan(
        at path: String,
        expectedGeneration: UUID,
        expectedRequestPath: String,
        expectedRequestToken: UUID,
        removeCache: Bool,
        beforeCommitForTesting: (@MainActor () async -> Void)?
    ) async {
        var pendingTestHook = beforeCommitForTesting
        var attemptCount = 0
        var previouslyCancelledTokens = Set<UUID>()
        var forceRefreshAfterCancellation = false

        while indexedSubtreeRequestIsCurrent(
            path: expectedRequestPath,
            token: expectedRequestToken,
            generation: expectedGeneration
        ) {
            attemptCount &+= 1
            let cacheRevision = childrenCacheVersion
            let ownershipRevision = treeChildrenOwnershipRevision
            let sourceRevision = pruneSourceRevision
            let worker = SubtreeRescanWorker(
                retainedState: SubtreeRescanRetainedState(
                    cache: treeChildrenCache,
                    tasks: treeChildrenTasks,
                    inFlight: treeChildrenInFlight
                ),
                path: path,
                hasIndexedChildren: childEdges[path] != nil,
                removeCache: removeCache,
                forceRefresh: forceRefreshAfterCancellation,
                previouslyCancelledTokens: previouslyCancelledTokens
            )
            var prepared = await worker.prepare()
            guard let transaction = prepared else {
                await retireSubtreeRescanWorkerAndRecord(worker)
                return
            }

            // Cancellation already happened on the worker. Do not bridge these owner tasks to a
            // filesystem barrier: the transaction also contains cache/sort presentation work.
            // Every real shallow/deep producer is independently registered in the path lease
            // domain, which the replacement awaits before touching an overlapping subtree.
            previouslyCancelledTokens.formUnion(transaction.cancelledTaskTokens)
            if transaction.removedTaskKeyCount > 0 || transaction.removedInFlightKeyCount > 0 {
                forceRefreshAfterCancellation = true
            }

            if let hook = pendingTestHook {
                pendingTestHook = nil
                await hook()
            }

            guard indexedSubtreeRequestIsCurrent(
                path: expectedRequestPath,
                token: expectedRequestToken,
                generation: expectedGeneration
            )
            else {
                prepared = nil
                await retireSubtreeRescanWorkerAndRecord(worker)
                return
            }
            guard cacheRevision == childrenCacheVersion,
                  ownershipRevision == treeChildrenOwnershipRevision,
                  sourceRevision == pruneSourceRevision
            else {
                prepared = nil
                await retireSubtreeRescanWorkerAndRecord(worker)
                await Task.yield()
                continue
            }

            guard transaction.shouldCommit else {
                lastSubtreeRescanPreparationRanOnMainThread = transaction.ranOnMainThread
                lastSubtreeRescanAttemptCount = attemptCount
                prepared = nil
                await retireSubtreeRescanWorkerAndRecord(worker)
                return
            }

            // O(1) ownership swaps only. The worker retains both old and prepared dictionaries,
            // sets and TreeRow arrays until the next MainActor turn performs retirement.
            treeChildrenCache = transaction.cache
            treeChildrenTasks = transaction.tasks
            treeChildrenInFlight = transaction.inFlight
            if transaction.removedTaskKeyCount > 0 || transaction.removedInFlightKeyCount > 0 {
                treeChildrenOwnershipRevision &+= 1
            }
            lastSubtreeRescanPreparationRanOnMainThread = transaction.ranOnMainThread
            lastSubtreeRescanAttemptCount = attemptCount
            bumpChildrenCacheVersion()
            bumpStructuralRevision(advanceSourceRevision: false)
            scheduleSubtreeRescanRetirement(worker)
            return
        }
    }

    /// Compare-and-swap boundary for the real subtree index. Cache writes from unrelated expanded
    /// directories, prune commits, evidence changes, locale switches and session rotation all
    /// invalidate the worker snapshot; the transaction retries from the latest owner instead of
    /// overwriting it with a stale full-dictionary copy.
    private func commitIndexedSubtreeMeasurement(
        _ measurement: IndexedSubtreeMeasurement,
        expectedGeneration: UUID,
        expectedRequestPath: String,
        expectedRequestToken: UUID,
        beforeCommitForTesting: (@MainActor () async -> Void)?,
        restoredPaths: [String] = []
    ) async -> Bool {
        var pendingTestHook = beforeCommitForTesting
        var attemptCount = 0
        while indexedSubtreeRequestIsCurrent(
            path: expectedRequestPath,
            token: expectedRequestToken,
            generation: expectedGeneration
        ), !Task.isCancelled {
            attemptCount &+= 1
            let sourceRevision = pruneSourceRevision
            let cacheRevision = childrenCacheVersion
            let ownershipRevision = treeChildrenOwnershipRevision
            let evidenceRevision = incompleteEvidenceSourceRevision
            let locale = presentationLocale
            let sortKey = mainListSortKey
            let worker = IndexedSubtreeTransactionWorker(
                retainedState: IndexedSubtreeRetainedState(
                    snapshot: snapshot,
                    totalBytes: totalBytes,
                    scannedFiles: scannedFiles,
                    buckets: buckets,
                    snapshotTreeRows: snapshotTreeRowsBySort,
                    perRootStaging: perRootStaging,
                    perRootActive: perRootProgressActive,
                    perRootFinished: perRootFinishedSlim,
                    perRootSorted: perRootProgressSorted,
                    perRootTreeRows: perRootTreeRowsBySort,
                    mainListSortKey: sortKey,
                    dirIndex: dirIndex,
                    childEdges: childEdges,
                    fileLeaves: fileLeaves,
                    treeCache: treeChildrenCache,
                    mtimeCache: mtimeFallbackCache,
                    primaryEvidence: primaryIncompleteEvidence,
                    treeEvidenceByRoot: treeIncompleteEvidenceByRoot,
                    previousIssues: incompleteScanIssues,
                    previousPermissionPaths: permissionDeniedPaths,
                    previousTCCPaths: tccProtectedSkippedPaths,
                    previousAllPaths: incompleteScanPaths,
                    previousTreeProjection: treeScanEvidenceProjection,
                    allocationCatalog: allocationCatalog,
                    largeFileLeaves: largeFileLeaves,
                    compactedLargeFileTopN: compactedLargeFileTopN,
                    largeFileMinBytes: largeFileMinBytes,
                    scanResultRoots: scanResultRoots,
                    usesPerRootPresentation: discoveryScanState == nil
                        && currentRootPath.map(Self.multiRootSentinelPaths.contains) == true,
                    forceSnapshotTreeLeafPresentation: discoveryScanState?.plan.forcesLeafPresentation ?? false,
                    usesLargeFileTopNOnly: largeFileTopNOnlyScan,
                    engine: engine,
                    trie: trie,
                    home: home
                ),
                measurement: measurement,
                tombstones: deletedPathTombstones.matcher,
                whitelist: whitelistSnapshot,
                locale: locale,
                restoredPaths: restoredPaths
            )
            var prepared = await worker.prepare()
            if let hook = pendingTestHook {
                pendingTestHook = nil
                await hook()
            }
            guard indexedSubtreeRequestIsCurrent(
                path: expectedRequestPath,
                token: expectedRequestToken,
                generation: expectedGeneration
            ), !Task.isCancelled else {
                prepared = nil
                _ = await worker.retire()
                return false
            }
            guard sourceRevision == pruneSourceRevision,
                  cacheRevision == childrenCacheVersion,
                  ownershipRevision == treeChildrenOwnershipRevision,
                  evidenceRevision == incompleteEvidenceSourceRevision,
                  sortKey == mainListSortKey,
                  locale.identifier == presentationLocale.identifier else {
                prepared = nil
                _ = await worker.retire()
                await Task.yield()
                continue
            }
            guard let prepared else {
                _ = await worker.retire()
                return false
            }

            // v2026.10.08: a formerly single-link allocation may acquire a link outside
            // the refreshed subtree between scans. Its old path was deliberately not retained
            // by the sparse catalog. Invalidate the allocation baseline and use the original
            // primary scan plan; applying a local delta here would count that allocation twice.
            if prepared.requiresAllocationRebaseline, let rebaseline = allocationRebaseline {
                GSYLog.notice(.operation, "tree.subtree.refresh.rebaseline reason=new_linked_identity path=\(expectedRequestPath)")
                scheduleIndexedSubtreeRetirement(worker)
                rebaseline()
                return false
            }

            notePruneSourceMutation()
            if let restoredIndex = prepared.restoredTombstones {
                deletedPathTombstones = restoredIndex
            }
            allocationCatalog = prepared.allocationCatalog
            largeFileLeaves = prepared.largeFileLeaves
            compactedLargeFileTopN = prepared.compactedLargeFileTopN
            totalBytes = prepared.totalBytes
            scannedFiles = prepared.scannedFiles
            buckets = prepared.buckets
            dirIndex = prepared.dirIndex
            childEdges = prepared.childEdges
            fileLeaves = prepared.fileLeaves
            treeChildrenCache = prepared.treeCache
            snapshotTreeRowsBySort = prepared.snapshotTreeRows
            perRootStaging = prepared.perRootStaging
            snapshot = prepared.snapshot
            perRootProgressActive = prepared.perRootActive
            perRootFinishedSlim = prepared.perRootFinished
            perRootFinishedCount = prepared.perRootFinishedCount
            perRootProgressSorted = prepared.perRootSorted
            perRootTreeRowsBySort = prepared.perRootTreeRows
            mtimeFallbackCache = prepared.mtimeCache
            treeIncompleteEvidenceByRoot = prepared.treeEvidenceByRoot
            incompleteEvidenceSourceRevision &+= 1
            applyPreparedIncompleteEvidenceProjection(prepared.evidence)
            lastSubtreeRescanPreparationRanOnMainThread = prepared.ranOnMainThread
            lastSubtreeRescanAttemptCount = attemptCount
            // v2026.10.08 C4: Tree freezes fetching ownership synchronously from these
            // notifications. Retiring the request afterward left its final frame busy forever.
            // Settle the matching owner in the same no-suspension commit as rows/evidence.
            finishIndexedSubtreeRequest(
                path: expectedRequestPath,
                token: expectedRequestToken
            )
            bumpChildrenCacheVersion()
            bumpStructuralRevision(advanceSourceRevision: false)
            if prepared.restoredTombstones != nil {
                treeBrowser.publishDeletionPresentation(matcher: deletedPathTombstones.presentationMatcher)
                storeRevision &+= 1
            }
            scheduleIndexedSubtreeRetirement(worker)
            return true
        }
        return false
    }

    private func scheduleIndexedSubtreeRetirement(
        _ worker: IndexedSubtreeTransactionWorker
    ) {
        Task { @MainActor [weak self] in
            await Task.yield()
            let diagnostics = await worker.retire()
            self?.lastSubtreeRescanRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastSubtreeRescanRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private func scheduleSubtreeRescanRetirement(_ worker: SubtreeRescanWorker) {
        Task { @MainActor [weak self] in
            await Task.yield()
            let diagnostics = await worker.retire()
            self?.lastSubtreeRescanRetirementRanOnMainThread = diagnostics.ranOnMainThread
            self?.lastSubtreeRescanRetirementDurationNanoseconds = diagnostics.durationNanoseconds
        }
    }

    private func retireSubtreeRescanWorkerAndRecord(_ worker: SubtreeRescanWorker) async {
        let diagnostics = await worker.retire()
        lastSubtreeRescanRetirementRanOnMainThread = diagnostics.ranOnMainThread
        lastSubtreeRescanRetirementDurationNanoseconds = diagnostics.durationNanoseconds
    }

    private struct PruneContribution: Sendable {
        let path: String
        var bytes: Int64
        var logicalBytes: Int64
        var fileCount: Int
        var isDirectory: Bool? = nil

        mutating func add(_ other: PruneContribution) {
            bytes &+= other.bytes
            logicalBytes &+= other.logicalBytes
            fileCount &+= other.fileCount
        }
    }

    /// 目录边界匹配器。把父子重复的删除路径压成最小根集合，再用 ancestor Set
    /// 查询代替“每个候选 × 每个删除路径”的嵌套扫描。
    private struct PrunedPathMatcher: Sendable {
        let roots: [String]
        private let rootSet: Set<String>

        init<S: Sequence>(paths: S) where S.Element == String {
            let unique = Set(paths.lazy.map(Self.normalize).filter { !$0.isEmpty })
            let sorted = unique.sorted()
            var minimal: [String] = []
            var minimalSet: Set<String> = []
            minimal.reserveCapacity(sorted.count)
            minimalSet.reserveCapacity(sorted.count)
            for path in sorted {
                if Self.hasAncestor(of: path, in: minimalSet) {
                    continue
                }
                minimal.append(path)
                minimalSet.insert(path)
            }
            roots = minimal
            rootSet = minimalSet
        }

        func contains(_ candidate: String) -> Bool {
            matchingRoot(for: candidate) != nil
        }

        func matchingRoot(for candidate: String) -> String? {
            guard !candidate.isEmpty else { return nil }
            if rootSet.contains("/"), candidate.hasPrefix("/") { return "/" }
            var cursor = Self.normalize(candidate)
            while !cursor.isEmpty {
                if rootSet.contains(cursor) { return cursor }
                if cursor == "/" { break }
                let parent = String._gsyParentPath(of: cursor)
                if parent == cursor { break }
                cursor = parent
            }
            return nil
        }

        private static func normalize(_ path: String) -> String {
            var value = path
            while value.count > 1, value.hasSuffix("/") {
                value.removeLast()
            }
            return value
        }

        private static func hasAncestor(of candidate: String, in roots: Set<String>) -> Bool {
            if roots.contains("/"), candidate.hasPrefix("/") { return true }
            var cursor = candidate
            while !cursor.isEmpty {
                if roots.contains(cursor) { return true }
                if cursor == "/" { break }
                let parent = String._gsyParentPath(of: cursor)
                if parent == cursor { break }
                cursor = parent
            }
            return false
        }
    }

    /// tombstone matcher 的不可变引用壳。引用替换是 O(1)，并让旧 Set/Array storage
    /// 能被 prune worker 持有到 MainActor commit 之后再于后台显式释放。
    private final class DeletedPathIndex: Sendable {
        static let empty = DeletedPathIndex(matcher: PrunedPathMatcher(paths: EmptyCollection<String>()))

        let matcher: PrunedPathMatcher
        let presentationMatcher: DeletionPresentationPathMatcher

        init(matcher: PrunedPathMatcher) {
            self.matcher = matcher
            // Both receipt and authoritative prune workers construct non-empty indexes off-main.
            // Freeze the Tree-facing matcher once so each later View remount copies COW roots in
            // O(1), instead of sorting/rehashing tombstones on MainActor per projection.
            presentationMatcher = DeletionPresentationPathMatcher(paths: matcher.roots)
        }
    }

    private actor DeletedPathRetirementWorker {
        private var retainedIndex: DeletedPathIndex?

        init(index: DeletedPathIndex) {
            retainedIndex = index
        }

        func retire() {
            retainedIndex = nil
        }
    }

    /// v2026.07.20：成功 receipt 到达后先合并本轮 tombstone，不能让 Tree 的晚到 fetch
    /// 在宽 prune 完成前把磁盘上已移走的项目重新发布。Set/排序/父子归一化在 actor 上完成；
    /// MainActor 只交换不可变索引并发布窄展示 revision。
    private actor DeletionPresentationTombstoneWorker {
        private var retainedCurrent: DeletedPathIndex?
        private var requestedPaths: [String]?
        private var prepared: DeletedPathIndex?

        init(current: DeletedPathIndex, requestedPaths: [String]) {
            retainedCurrent = current
            self.requestedPaths = requestedPaths
        }

        func prepare() -> DeletedPathIndex? {
            guard let retainedCurrent, let requestedPaths, !Task.isCancelled else { return nil }
            let matcher = PrunedPathMatcher(
                paths: retainedCurrent.matcher.roots + requestedPaths
            )
            let result = DeletedPathIndex(matcher: matcher)
            prepared = result
            return result
        }

        func retire() {
            retainedCurrent = nil
            requestedPaths = nil
            prepared = nil
        }
    }

    private actor PruneRequestPathRetirementWorker {
        private var retainedPaths: [String]?

        init(paths: [String]) {
            retainedPaths = paths
        }

        func retire() {
            retainedPaths = nil
        }
    }

    /// deep-index 关闭时，按需树缓存是删除前仍可用的权威子树统计来源。
    /// 同一路径会因不同排序键出现在多个 cache entry；这里先按 path 取最大完整值去重，
    /// 再为“完整 direct-children cache”聚合父目录贡献，避免父行 + 子行重复累计。
    private struct TreeCacheContributionIndex: Sendable {
        private let exactByPath: [String: PruneContribution]
        private let aggregateByParent: [String: PruneContribution]

        init(cache: [String: [TreeRow]]) {
            var exact: [String: PruneContribution] = [:]
            var completeChildrenByParent: [String: [String: PruneContribution]] = [:]

            for (cacheKey, rows) in cache {
                let parentPath: String
                if let pipe = cacheKey.lastIndex(of: "|") {
                    parentPath = String(cacheKey[..<pipe])
                } else {
                    parentPath = cacheKey
                }

                let isCompleteEntry = rows.allSatisfy {
                    !$0.isSizePending && $0.hasCompleteAccessEvidence
                }
                if isCompleteEntry, completeChildrenByParent[parentPath] == nil {
                    // 空数组同样是“已完整枚举且贡献为 0”，不能与 cache miss 混淆。
                    completeChildrenByParent[parentPath] = [:]
                }

                for row in rows where !row.isSizePending && row.hasCompleteAccessEvidence {
                    let item = PruneContribution(
                        path: row.path,
                        bytes: row.bytes,
                        logicalBytes: row.logicalBytes,
                        fileCount: row.fileCount,
                        isDirectory: row.isDirectory
                    )
                    exact[row.path] = Self.preferred(exact[row.path], item)
                    if isCompleteEntry {
                        let current = completeChildrenByParent[parentPath]?[row.path]
                        completeChildrenByParent[parentPath]?[row.path] = Self.preferred(current, item)
                    }
                }
            }

            var aggregate: [String: PruneContribution] = [:]
            aggregate.reserveCapacity(completeChildrenByParent.count)
            for (parent, children) in completeChildrenByParent {
                var value = PruneContribution(
                    path: parent,
                    bytes: 0,
                    logicalBytes: 0,
                    fileCount: 0,
                    isDirectory: true
                )
                for child in children.values {
                    value.add(child)
                }
                aggregate[parent] = value
            }
            exactByPath = exact
            aggregateByParent = aggregate
        }

        func contribution(for path: String) -> PruneContribution? {
            exactByPath[path] ?? aggregateByParent[path]
        }

        private static func preferred(_ current: PruneContribution?,
                                      _ candidate: PruneContribution) -> PruneContribution {
            guard let current else { return candidate }
            return PruneContribution(
                path: candidate.path,
                bytes: max(current.bytes, candidate.bytes),
                logicalBytes: max(current.logicalBytes, candidate.logicalBytes),
                fileCount: max(current.fileCount, candidate.fileCount),
                isDirectory: candidate.isDirectory ?? current.isDirectory
            )
        }
    }

    /// MainActor 上只取得这些 COW storage 的不可变快照；真正触发 copy/mutate 的第一笔
    /// 写发生在 `PruneStateWorker` actor 中，不在 UI executor 上做全表遍历。
    private struct PruneStateSnapshot: Sendable {
        let snapshot: ScanSnapshot
        let totalBytes: Int64
        let scannedFiles: Int
        let buckets: [String: Bucket]
        let dirIndex: [String: DirAgg]
        let childEdges: [String: Set<String>]
        let fileLeaves: [String: IndexedFileLeaf]
        let treeChildrenCache: [String: [TreeRow]]
        let snapshotTreeRows: [TreeSortKey: [TreeRow]]
        let treeEvidenceProjection: TreeScanEvidenceProjection
        let locale: Locale
        let largeFileLeaves: LargeFileLeafTopNHeap
        let compactedLargeFileTopN: [LargeFileLeaf]?
        let perRootStaging: [String: PerRootProgress]
        let perRootActive: [String: PerRootProgress]
        let perRootFinished: [String: PerRootProgress]
        /// commit 会替换的其余 COW storage 也必须由 worker 跨过 MainActor swap 强持有。
        let perRootSorted: [PerRootProgress]
        let perRootTreeRows: [TreeSortKey: [TreeRow]]
        let mainListSortKey: MainListSortKey
        let previousPrunedPaths: [String]?
        let allocationCatalog: AllocationCatalog?
        let largeFileMinBytes: Int64
    }

    private struct PrunePlan: Sendable {
        var prunedRoots: [String]
        var snapshot: ScanSnapshot
        var totalBytes: Int64
        var scannedFiles: Int
        var buckets: [String: Bucket]
        var dirIndex: [String: DirAgg]
        var childEdges: [String: Set<String>]
        var fileLeaves: [String: IndexedFileLeaf]
        var treeChildrenCache: [String: [TreeRow]]
        var snapshotTreeRows: [TreeSortKey: [TreeRow]]
        var largeFileLeaves: LargeFileLeafTopNHeap
        var compactedLargeFileTopN: [LargeFileLeaf]?
        var perRootStaging: [String: PerRootProgress]
        var perRootActive: [String: PerRootProgress]
        var perRootFinished: [String: PerRootProgress]
        var perRootFinishedCount: Int
        var perRootSorted: [PerRootProgress]
        var perRootTreeRows: [TreeSortKey: [TreeRow]]
        var largeRemoved: Int
        var compactedLargeRemoved: Int
        var treeCacheContributionIndexBuilt: Bool
        var ranOnMainThread: Bool
        var allocationCatalog: AllocationCatalog?
        var allocationRemovals: [FileAllocationSnapshot.RemovedContribution]
        var durationNanoseconds: UInt64 = 0
    }

    private struct PreparedPrune: Sendable {
        let tombstones: DeletedPathIndex
        let plan: PrunePlan
        let mergeRanOnMainThread: Bool
    }

    private struct PruneRetirementDiagnostics: Sendable {
        let ranOnMainThread: Bool
        let durationNanoseconds: UInt64
    }

    /// 持有删除前全部 COW storage 与旧 tombstone index，直到 MainActor 完成 O(1) commit。
    /// `retire` 在本 actor 的 generic executor 上把最后引用置 nil，避免 Dictionary/Array
    /// 大量元素析构占用 UI 帧。actor 本身是 Sendable，不需要 unchecked 逃逸并发检查。
    private actor PruneStateWorker {
        private var retainedState: PruneStateSnapshot?
        private var retainedTombstones: DeletedPathIndex?
        private var requestedPaths: [String]?
        private var preparedOutput: PreparedPrune?

        init(state: PruneStateSnapshot,
             tombstones: DeletedPathIndex,
             requestedPaths: [String]) {
            retainedState = state
            retainedTombstones = tombstones
            self.requestedPaths = requestedPaths
        }

        func prepare() -> PreparedPrune? {
            guard let state = retainedState,
                  let previous = retainedTombstones,
                  let requestedPaths else { return nil }

            var mergedPaths = previous.matcher.roots
            mergedPaths.reserveCapacity(mergedPaths.count + requestedPaths.count)
            mergedPaths.append(contentsOf: requestedPaths)
            let matcher = PrunedPathMatcher(paths: mergedPaths)
            let deltaMatcher = PrunedPathMatcher(paths: requestedPaths)
            let mergeRanOnMainThread = Thread.isMainThread

            let started = DispatchTime.now().uptimeNanoseconds
            var plan = ScanCoordinator.makePrunePlan(
                from: state,
                matcher: matcher,
                deltaMatcher: deltaMatcher
            )
            if let catalog = state.allocationCatalog {
                let replacement = catalog.snapshot().replacing(with: .init(),
                    replacesPath: { matcher.contains($0) }, removedContributions: plan.allocationRemovals)
                ScanCoordinator.reconcileAllocationPresentation(replacement.externalDeltas,
                    snapshot: &plan.snapshot, totalBytes: &plan.totalBytes,
                    buckets: &plan.buckets, dirIndex: &plan.dirIndex, fileLeaves: &plan.fileLeaves,
                    treeCache: &plan.treeChildrenCache, perRoot: &plan.perRootStaging,
                    largeFiles: &plan.largeFileLeaves, compacted: &plan.compactedLargeFileTopN,
                    largeFileMinBytes: state.largeFileMinBytes, sortKey: state.mainListSortKey, locale: state.locale)
                plan.allocationCatalog = .committed(replacement.snapshot)
                if !replacement.externalDeltas.isEmpty {
                    if !plan.snapshotTreeRows.isEmpty {
                        plan.snapshotTreeRows = ScanCoordinator.buildSnapshotTreeRows(
                            rows: plan.snapshot.rows,
                            evidence: state.treeEvidenceProjection,
                            locale: state.locale,
                            forceLeafPresentation: state.snapshot.categoryID == "developer.versioned"
                        ) ?? [:]
                    }
                    let projection = ScanCoordinator.buildPerRootProjection(staging: plan.perRootStaging,
                        tombstones: matcher, previousActive: plan.perRootActive,
                        previousFinished: plan.perRootFinished, previousFinishedCount: plan.perRootFinishedCount,
                        previousSorted: plan.perRootSorted, evidence: state.treeEvidenceProjection,
                        locale: state.locale, sessionIsScanning: false)
                    plan.perRootActive = projection.active
                    plan.perRootFinished = projection.finished
                    plan.perRootFinishedCount = projection.finishedCount
                    plan.perRootSorted = projection.sorted
                    plan.perRootTreeRows = projection.treeRowsBySort
                }
            }
            plan.durationNanoseconds = DispatchTime.now().uptimeNanoseconds - started
            let output = PreparedPrune(
                tombstones: DeletedPathIndex(matcher: matcher),
                plan: plan,
                mergeRanOnMainThread: mergeRanOnMainThread
            )
            preparedOutput = output
            return output
        }

        func retire(beforeRelease: (@Sendable () async -> Void)? = nil) async
            -> PruneRetirementDiagnostics {
            if let beforeRelease {
                await beforeRelease()
            }
            let ranOnMainThread = ScanCoordinator.currentThreadIsMainForDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            preparedOutput = nil
            retainedState = nil
            retainedTombstones = nil
            requestedPaths = nil
            return PruneRetirementDiagnostics(
                ranOnMainThread: ranOnMainThread,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started
            )
        }
    }

    /// Foundation 把 `Thread.isMainThread` 标成 async-unavailable；诊断只读线程标签，
    /// 经同步 nonisolated helper 读取，不把任何业务隔离建立在线程身份之上。
    private nonisolated static func currentThreadIsMainForDiagnostics() -> Bool {
        Thread.isMainThread
    }

    /// 把已成功移入废纸篓的路径从 ScanCoordinator 的全部派生数据源中原子剔除。
    ///
    /// O(N) 路径过滤、祖先聚合扣减、边集和树缓存重建全部由 worker actor 完成；
    /// MainActor 只做 COW 快照、generation/revision compare-and-swap 与最终 storage 提交。
    /// 若新扫描已开始，旧 plan 直接丢弃；同一会话若后台树缓存等状态有变化，则重取
    /// 最新快照重算，绝不让旧 plan 覆盖新状态。
    public func pruneDeleted(paths: [String]) async {
        // v2026.07.16 扫描事务边界：磁盘已发生删除时，进行中的投影 progress/summary
        // 仍代表删除前的枚举视图，无法从 Top-N/一级聚合反推出被删深层路径的精确贡献。
        // 与其让晚到绝对总量把 prune 扣减覆盖回来，不如终止本轮并要求下一轮从磁盘
        // 重建权威状态。正常专业删除本来就禁止扫描中提交；此分支保护跨模式删除。
        if isScanning {
            GSYLog.notice(.operation, "scan.cancel reason=filesystem_mutated_during_scan deletedPaths=\(paths.count)")
            cancel()
            refreshVolumeCapacity()
            return
        }
        await performPruneTransaction(
            paths: paths,
            beforeCommitForTesting: nil,
            awaitSuccessfulRetirement: false
        )
    }

    /// Receipt-first presentation boundary. Only the caller that owns a successful recycle
    /// receipt may invoke this method. It does not change bytes/counts or authoritative rows;
    /// `pruneDeleted` remains the sole full-model reconciler. Binding the commit to the current
    /// prune generation prevents a late receipt from hiding rows in a newly started scan.
    public func acknowledgeSuccessfulDeletionForPresentation(paths: [String]) async {
        await performDeletionPresentationAcknowledgement(
            paths: paths,
            beforeCommitForTesting: nil
        )
    }

    /// Deterministic race hook: tests may commit a second receipt between prepare and CAS. The
    /// production entry above never supplies a hook.
    func _acknowledgeSuccessfulDeletionForPresentationForTesting(
        paths: [String],
        beforeCommit: @escaping @MainActor @Sendable () async -> Void
    ) async {
        await performDeletionPresentationAcknowledgement(
            paths: paths,
            beforeCommitForTesting: beforeCommit
        )
    }

    private func performDeletionPresentationAcknowledgement(
        paths: [String],
        beforeCommitForTesting: (@MainActor @Sendable () async -> Void)?
    ) async {
        guard !paths.isEmpty else { return }
        let requestGeneration = pruneStateGeneration
        var pendingTestHook = beforeCommitForTesting
        while requestGeneration == pruneStateGeneration, !Task.isCancelled {
            let sourceRevision = pruneSourceRevision
            let worker = DeletionPresentationTombstoneWorker(
                current: deletedPathTombstones,
                requestedPaths: paths
            )
            guard let prepared = await worker.prepare(), !Task.isCancelled else {
                await worker.retire()
                return
            }
            if let hook = pendingTestHook {
                pendingTestHook = nil
                await hook()
            }
            guard requestGeneration == pruneStateGeneration else {
                await worker.retire()
                return
            }
            guard sourceRevision == pruneSourceRevision else {
                await worker.retire()
                await Task.yield()
                continue
            }

            // v2026.07.20: source revision is the compare-and-swap authority. Without it, two
            // concurrent receipts could both merge from the same old index and the later commit
            // would erase the first tombstone, allowing a late Tree fetch to resurrect a deleted
            // path in the same scan session.
            deletedPathTombstones = prepared
            notePruneSourceMutation()
            treeBrowser.publishDeletionPresentation(matcher: prepared.presentationMatcher)

            // Keep the old COW roots owned by the worker until subscribers have consumed the new
            // revision, then release them away from MainActor.
            Task { @MainActor in
                await Task.yield()
                await worker.retire()
            }
            return
        }
    }

    /// 测试专用确定性竞态注入：plan 已算完但 CAS 尚未执行时切换扫描代际，验证旧 plan
    /// 会被拒绝。生产调用永远传 nil，不引入延迟或分支依赖。
    func _pruneDeletedForTesting(
        paths: [String],
        beforeCommit: @escaping @MainActor @Sendable () -> Void,
        beforeRetire: (@Sendable () async -> Void)? = nil,
        awaitSuccessfulRetirement: Bool = true
    ) async {
        await performPruneTransaction(
            paths: paths,
            beforeCommitForTesting: beforeCommit,
            beforeRetireForTesting: beforeRetire,
            awaitSuccessfulRetirement: awaitSuccessfulRetirement
        )
    }

    /// `paths` 可能是上万条临时数组。必须在 perform 返回前先交给 actor 强持有，
    /// 下一 MainActor turn 才允许 generic executor 清空；否则函数参数会在 UI executor
    /// 成为最后一份 Array storage 引用并逐项析构。
    private func handOffPruneRequestPathsForRetirement(_ paths: [String]) {
        let retirementWorker = PruneRequestPathRetirementWorker(paths: paths)
        Task { @MainActor in
            await Task.yield()
            await retirementWorker.retire()
        }
    }

    private func performPruneTransaction(
        paths: [String],
        beforeCommitForTesting: (@MainActor @Sendable () -> Void)?,
        beforeRetireForTesting: (@Sendable () async -> Void)? = nil,
        awaitSuccessfulRetirement: Bool = true
    ) async {
        guard !paths.isEmpty else { return }

        let transactionID = UUID()
        let transactionStartedAt = DispatchTime.now().uptimeNanoseconds
        let requestGeneration = pruneStateGeneration
        activePruneTransactionCount += 1
        defer { activePruneTransactionCount = max(0, activePruneTransactionCount - 1) }

        var pendingTestHook = beforeCommitForTesting

        while requestGeneration == pruneStateGeneration {
            let sourceRevision = pruneSourceRevision
            let snapshotRowCount = snapshot.rows.count
            let directoryCount = dirIndex.count
            let treeCacheCount = treeChildrenCache.count
            GSYLog.info(
                .scan,
                "prune.transaction stage=prepare_start transaction_id=\(transactionID.uuidString) "
                    + "path_count=\(paths.count) snapshot_rows=\(snapshotRowCount) "
                    + "dir_count=\(directoryCount) tree_cache_count=\(treeCacheCount)"
            )
            let worker = PruneStateWorker(
                state: capturePruneStateSnapshot(),
                tombstones: deletedPathTombstones,
                requestedPaths: paths
            )
            var prepared = await worker.prepare()
            // 这里只把是否有输出投影成标量；不能把完整 tombstone index 绑定在
            // MainActor loop 作用域，否则 CAS reject 时它可能成为宽 storage 最后引用。
            let hasPreparedTombstones = prepared?.tombstones.matcher.roots.isEmpty == false
            guard hasPreparedTombstones else {
                prepared = nil
                _ = await worker.retire()
                handOffPruneRequestPathsForRetirement(paths)
                return
            }

            if let hook = pendingTestHook {
                pendingTestHook = nil
                hook()
            }
            guard requestGeneration == pruneStateGeneration else {
                prepared = nil
                _ = await worker.retire()
                handOffPruneRequestPathsForRetirement(paths)
                return
            }
            guard sourceRevision == pruneSourceRevision else {
                prepared = nil
                _ = await worker.retire()
                await Task.yield()
                continue
            }
            guard let prepared else {
                _ = await worker.retire()
                handOffPruneRequestPathsForRetirement(paths)
                return
            }

            // 两个大状态都只做引用/storage swap；旧索引与旧 COW storage 仍由 worker
            // 强持有，因此下面的 MainActor 赋值不会触发其最后一次析构。
            // v2026.07.19 诊断 ID 只在成功 commit 边界换代；被 CAS 拒绝的事务不能
            // 吞掉上一笔已提交事务稍后到达的 retirement 诊断。
            latestPruneDiagnosticsTransactionID = transactionID
            lastPruneRetirementRanOnMainThread = nil
            lastPruneRetirementDurationNanoseconds = nil
            deletedPathTombstones = prepared.tombstones
            lastPruneTombstoneMergeRanOnMainThread = prepared.mergeRanOnMainThread
            commitPrunePlan(prepared.plan)
            let commitElapsedMilliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - transactionStartedAt
            ) / 1_000_000
            let planMilliseconds = String(
                format: "%.2f",
                Double(prepared.plan.durationNanoseconds) / 1_000_000
            )
            let totalMilliseconds = String(format: "%.2f", commitElapsedMilliseconds)
            GSYLog.info(
                .scan,
                "prune.transaction stage=commit_complete transaction_id=\(transactionID.uuidString) "
                    + "plan_ms=\(planMilliseconds) elapsed_ms=\(totalMilliseconds)"
            )
            if awaitSuccessfulRetirement {
                let retirement = await worker.retire(beforeRelease: beforeRetireForTesting)
                recordPruneRetirement(retirement, transactionID: transactionID)
            } else {
                schedulePruneRetirement(
                    worker,
                    beforeRelease: beforeRetireForTesting,
                    transactionID: transactionID
                )
            }
            handOffPruneRequestPathsForRetirement(paths)
            return
        }
        handOffPruneRequestPathsForRetirement(paths)
    }

    private func schedulePruneRetirement(
        _ worker: PruneStateWorker,
        beforeRelease: (@Sendable () async -> Void)?,
        transactionID: UUID
    ) {
        let predecessor = pruneRetirementTail
        pruneRetirementTail = Task { @MainActor [weak self] in
            await predecessor?.value
            let retirement = await worker.retire(beforeRelease: beforeRelease)
            self?.recordPruneRetirement(retirement, transactionID: transactionID)
        }
    }

    private func recordPruneRetirement(
        _ retirement: PruneRetirementDiagnostics,
        transactionID: UUID
    ) {
        if latestPruneDiagnosticsTransactionID == transactionID {
            lastPruneRetirementRanOnMainThread = retirement.ranOnMainThread
            lastPruneRetirementDurationNanoseconds = retirement.durationNanoseconds
        }
        let retirementMilliseconds = String(
            format: "%.2f",
            Double(retirement.durationNanoseconds) / 1_000_000
        )
        GSYLog.info(
            .scan,
            "prune.transaction stage=retirement_complete transaction_id=\(transactionID.uuidString) "
                + "retirement_ms=\(retirementMilliseconds) "
                + "main_thread=\(retirement.ranOnMainThread)"
        )
    }

    private func capturePruneStateSnapshot() -> PruneStateSnapshot {
        PruneStateSnapshot(
            snapshot: snapshot,
            totalBytes: totalBytes,
            scannedFiles: scannedFiles,
            buckets: buckets,
            dirIndex: dirIndex,
            childEdges: childEdges,
            fileLeaves: fileLeaves,
            treeChildrenCache: treeChildrenCache,
            snapshotTreeRows: snapshotTreeRowsBySort,
            treeEvidenceProjection: treeScanEvidenceProjection,
            locale: presentationLocale,
            largeFileLeaves: largeFileLeaves,
            compactedLargeFileTopN: compactedLargeFileTopN,
            perRootStaging: perRootStaging,
            perRootActive: perRootProgressActive,
            perRootFinished: perRootFinishedSlim,
            perRootSorted: perRootProgressSorted,
            perRootTreeRows: perRootTreeRowsBySort,
            mainListSortKey: mainListSortKey,
            previousPrunedPaths: lastPrunedPaths,
            allocationCatalog: allocationCatalog,
            largeFileMinBytes: largeFileMinBytes
        )
    }

    private nonisolated static func makePrunePlan(
        from state: PruneStateSnapshot,
        matcher: PrunedPathMatcher,
        deltaMatcher: PrunedPathMatcher
    ) -> PrunePlan {
        var sourcePerRoot = state.perRootStaging
        if sourcePerRoot.isEmpty {
            sourcePerRoot = state.perRootFinished
            for (path, progress) in state.perRootActive {
                sourcePerRoot[path] = progress
            }
        }

        let rowsByID = Dictionary(uniqueKeysWithValues: state.snapshot.rows.map { ($0.id, $0) })
        // v2026.07.20 deletion regression fix: developer terminal state can contain one cache
        // entry per root and sort key (11,872 in the reported trace). Most submitted paths already
        // have an authoritative snapshot/per-root/leaf contribution, so eagerly indexing every
        // Tree cache row made a one-item deletion pay for the complete Tree. Build this fallback
        // only if every cheaper authoritative source misses the requested path.
        var treeCacheContributions: TreeCacheContributionIndex?
        // large-file-only 会话不构建 rows/fileLeaves/dirIndex；Top-N heap 是用户可删
        // 文件唯一的精确贡献来源。主 heap 与 compact cache 可能在过渡态同时存在，
        // 按 path 去重并取较大字节，绝不能把同一叶子累计两次。
        var largeFileContributions: [String: PruneContribution] = [:]
        let largeFileCandidates = state.largeFileLeaves.snapshot()
            + (state.compactedLargeFileTopN ?? [])
        largeFileContributions.reserveCapacity(largeFileCandidates.count)
        for leaf in largeFileCandidates {
            let candidate = PruneContribution(
                path: leaf.path,
                bytes: leaf.bytes,
                logicalBytes: leaf.logicalBytes,
                fileCount: 1,
                isDirectory: false
            )
            if let current = largeFileContributions[leaf.path], current.bytes >= candidate.bytes {
                continue
            }
            largeFileContributions[leaf.path] = candidate
        }
        func contribution(for path: String) -> PruneContribution? {
            if let leaf = state.fileLeaves[path] {
                return PruneContribution(path: path, bytes: leaf.bytes,
                                         logicalBytes: leaf.logicalBytes, fileCount: leaf.fileCount,
                                         isDirectory: false)
            }
            if let agg = state.dirIndex[path] {
                return PruneContribution(path: path, bytes: agg.bytes,
                                         logicalBytes: agg.logicalBytes, fileCount: agg.fileCount,
                                         isDirectory: true)
            }
            if let bucket = state.buckets[path] {
                return PruneContribution(path: path, bytes: bucket.bytes,
                                         logicalBytes: bucket.logicalBytes, fileCount: bucket.fileCount,
                                         isDirectory: bucket.isDirectory)
            }
            if let row = rowsByID[path] {
                return PruneContribution(path: path, bytes: row.bytes,
                                         logicalBytes: row.logicalBytes, fileCount: row.fileCount,
                                         isDirectory: row.isDirectory)
            }
            if let progress = sourcePerRoot[path] {
                return PruneContribution(path: path, bytes: progress.bytes,
                                         logicalBytes: progress.logicalBytes, fileCount: progress.fileCount,
                                         isDirectory: true)
            }
            if let largeFile = largeFileContributions[path] {
                return largeFile
            }
            // deep-index=off 时深层目录不会进入 dirIndex/fileLeaves/buckets；用户展开树后，
            // 完整按需 cache 是文件移入废纸篓前最后一份精确子树贡献。
            if treeCacheContributions == nil {
                treeCacheContributions = TreeCacheContributionIndex(
                    cache: state.treeChildrenCache
                )
            }
            if let cached = treeCacheContributions?.contribution(for: path) {
                return cached
            }
            if let catalogContribution = state.allocationCatalog?.snapshot().contribution(forPath: path) {
                return PruneContribution(
                    path: path,
                    bytes: catalogContribution.allocatedBytes,
                    logicalBytes: catalogContribution.logicalBytes,
                    fileCount: catalogContribution.fileCount
                )
            }
            return nil
        }

        // 只对本次新请求的 deltaMatcher.roots 计算扣减贡献，避免第 2+ 次删除时对已在上一轮
        // prune 掉的历史路径重复查询而误触发 TreeCacheContributionIndex 全量构建或二次扣减。
        let indexedContributions = deltaMatcher.roots.compactMap(contribution(for:))
        let treeCacheContributionIndexBuilt = treeCacheContributions != nil
        let indexedMatcher = PrunedPathMatcher(paths: indexedContributions.map(\.path))
        let perRootContributions = sourcePerRoot.values.compactMap { progress -> PruneContribution? in
            guard deltaMatcher.contains(progress.rootPath),
                  !indexedMatcher.contains(progress.rootPath) else { return nil }
            return PruneContribution(path: progress.rootPath, bytes: progress.bytes,
                                     logicalBytes: progress.logicalBytes, fileCount: progress.fileCount,
                                     isDirectory: true)
        }
        let deletedContributions = indexedContributions + perRootContributions
        let totalDeletedBytes = deletedContributions.reduce(Int64(0)) { $0 &+ $1.bytes }
        let totalDeletedFiles = deletedContributions.reduce(0) { $0 &+ $1.fileCount }

        // 一次构建“祖先 -> 总扣减量”，snapshot rows / dirIndex / perRoot 后续均 O(1) 查表。
        var ancestorDecrements: [String: PruneContribution] = [:]
        ancestorDecrements.reserveCapacity(deletedContributions.count * 4)
        for item in deletedContributions {
            var cursor = String._gsyParentPath(of: item.path)
            while !cursor.isEmpty, cursor != "/" {
                if matcher.contains(cursor) { break }
                let delta = PruneContribution(path: cursor, bytes: item.bytes,
                                              logicalBytes: item.logicalBytes,
                                              fileCount: item.fileCount,
                                              isDirectory: true)
                if var current = ancestorDecrements[cursor] {
                    current.add(delta)
                    ancestorDecrements[cursor] = current
                } else {
                    ancestorDecrements[cursor] = delta
                }
                let parent = String._gsyParentPath(of: cursor)
                if parent == cursor { break }
                cursor = parent
            }
        }

        var nextChildEdges: [String: Set<String>] = [:]
        nextChildEdges.reserveCapacity(state.childEdges.count)
        for (parent, children) in state.childEdges where !matcher.contains(parent) {
            nextChildEdges[parent] = Set(children.lazy.filter { !matcher.contains($0) })
        }

        // A cached parent row owns its disclosure state, while the actual direct children live in
        // a separate `parent|sort` entry. Resolve the post-delete child state once across all sort
        // variants so deleting the last child removes the stale empty chevron immediately. When no
        // cache exists for a path we preserve the row's prior value instead of guessing.
        var cachedParentHasSurvivingChildren: [String: Bool] = [:]
        cachedParentHasSurvivingChildren.reserveCapacity(state.treeChildrenCache.count)
        for (cacheKey, rows) in state.treeChildrenCache {
            let parentPath: String
            if let pipe = cacheKey.lastIndex(of: "|") {
                parentPath = String(cacheKey[..<pipe])
            } else {
                parentPath = cacheKey
            }
            guard !matcher.contains(parentPath) else { continue }
            let hasSurvivingChild = rows.contains { !matcher.contains($0.path) }
            cachedParentHasSurvivingChildren[parentPath] =
                (cachedParentHasSurvivingChildren[parentPath] ?? false) || hasSurvivingChild
        }

        var newRows: [RowItem] = []
        newRows.reserveCapacity(state.snapshot.rows.count)
        var removedRowBytes: Int64 = 0
        var mutatedIndices: [Int] = []
        for row in state.snapshot.rows {
            if matcher.contains(row.id) {
                removedRowBytes &+= row.bytes
                continue
            }
            let dec = ancestorDecrements[row.id]
            let hasAggregateChange = dec.map {
                $0.bytes > 0 || $0.logicalBytes > 0 || $0.fileCount > 0
            } ?? false
            let updatedHasChildren = cachedParentHasSurvivingChildren[row.id]
                ?? (nextChildEdges[row.id].map { !$0.isEmpty } ?? row.hasChildren)
            guard hasAggregateChange || updatedHasChildren != row.hasChildren else {
                newRows.append(row)
                continue
            }
            if hasAggregateChange {
                mutatedIndices.append(newRows.count)
            }
            newRows.append(RowItem(
                id: row.id,
                url: row.url,
                title: row.title,
                isDirectory: row.isDirectory,
                bytes: max(0, row.bytes - (dec?.bytes ?? 0)),
                logicalBytes: max(0, row.logicalBytes - (dec?.logicalBytes ?? 0)),
                fileCount: max(0, row.fileCount - (dec?.fileCount ?? 0)),
                verdict: row.verdict,
                rejection: row.rejection,
                vendorName: row.vendorName,
                vendorNote: row.vendorNote,
                runningBundleIDPrefix: row.runningBundleIDPrefix,
                isActive: row.isActive,
                hasChildren: updatedHasChildren,
                modificationDate: row.modificationDate,
                titlePresentation: row.titlePresentation,
                vendorNamePresentation: row.vendorNamePresentation,
                vendorNotePresentation: row.vendorNotePresentation
            ))
        }
        let sortKeyDependsOnAggregates: Bool = {
            switch state.mainListSortKey {
            case .sizeDesc, .sizeAsc, .fileCountDesc, .fileCountAsc:
                return true
            case .nameAsc, .nameDesc, .mtimeDesc, .mtimeAsc:
                return false
            }
        }()
        if !mutatedIndices.isEmpty && state.snapshot.isFinished && sortKeyDependsOnAggregates {
            let sortKey = state.mainListSortKey
            let locale = state.locale
            let violatesNeighborOrder = mutatedIndices.contains { idx in
                (idx > 0 && sortKey.lessThan(newRows[idx], newRows[idx - 1], locale: locale))
                    || (idx + 1 < newRows.count && sortKey.lessThan(newRows[idx + 1], newRows[idx], locale: locale))
            }
            if violatesNeighborOrder {
                if mutatedIndices.count * 16 < newRows.count {
                    let mutatedSet = Set(mutatedIndices)
                    var unchangedRows: [RowItem] = []
                    unchangedRows.reserveCapacity(newRows.count - mutatedIndices.count)
                    var mutatedRows: [RowItem] = []
                    mutatedRows.reserveCapacity(mutatedIndices.count)
                    var unchangedIsSorted = true
                    for (idx, row) in newRows.enumerated() {
                        if mutatedSet.contains(idx) {
                            mutatedRows.append(row)
                        } else {
                            if let prev = unchangedRows.last,
                               sortKey.lessThan(row, prev, locale: locale) {
                                unchangedIsSorted = false
                            }
                            unchangedRows.append(row)
                        }
                    }
                    if unchangedIsSorted {
                        mutatedRows.sort { sortKey.lessThan($0, $1, locale: locale) }
                        var merged: [RowItem] = []
                        merged.reserveCapacity(newRows.count)
                        var i = 0
                        var j = 0
                        while i < unchangedRows.count && j < mutatedRows.count {
                            if sortKey.lessThan(mutatedRows[j], unchangedRows[i], locale: locale) {
                                merged.append(mutatedRows[j])
                                j &+= 1
                            } else {
                                merged.append(unchangedRows[i])
                                i &+= 1
                            }
                        }
                        if i < unchangedRows.count {
                            merged.append(contentsOf: unchangedRows[i...])
                        }
                        if j < mutatedRows.count {
                            merged.append(contentsOf: mutatedRows[j...])
                        }
                        newRows = merged
                    } else {
                        newRows.sort { sortKey.lessThan($0, $1, locale: locale) }
                    }
                } else {
                    newRows.sort { sortKey.lessThan($0, $1, locale: locale) }
                }
            }
        }
        let snapshotBytesToSubtract = totalDeletedBytes > 0 ? totalDeletedBytes : removedRowBytes
        let nextSnapshot = ScanSnapshot(
            categoryID: state.snapshot.categoryID,
            rows: newRows,
            totalBytes: max(0, state.snapshot.totalBytes - snapshotBytesToSubtract),
            scannedFileCount: max(0, state.snapshot.scannedFileCount - totalDeletedFiles),
            isFinished: state.snapshot.isFinished,
            elapsed: state.snapshot.elapsed,
            isComplete: state.snapshot.isComplete,
            bytesPerSecond: state.snapshot.bytesPerSecond,
            estimatedRemaining: state.snapshot.estimatedRemaining
        )
        // Developer multi-root presentation intentionally owns per-root Tree cache projections
        // and leaves the global snapshot projection empty. Rebuilding eight locale-aware global
        // sorts here is dead work and caused the measured 11.45-second one-item prune. Preserve
        // that representation boundary; categories that actually own global rows still rebuild.
        let nextSnapshotTreeRows: [TreeSortKey: [TreeRow]]
        if state.snapshotTreeRows.isEmpty {
            nextSnapshotTreeRows = [:]
        } else {
            nextSnapshotTreeRows = buildSnapshotTreeRows(
                rows: newRows,
                evidence: state.treeEvidenceProjection,
                locale: state.locale,
                forceLeafPresentation: state.snapshot.categoryID == "developer.versioned"
            ) ?? [:]
        }

        var nextBuckets: [String: Bucket] = [:]
        nextBuckets.reserveCapacity(state.buckets.count)
        for (bucketPath, bucket) in state.buckets where !matcher.contains(bucketPath) {
            let dec = ancestorDecrements[bucketPath]
            let hasAggregateChange = dec.map {
                $0.bytes > 0 || $0.logicalBytes > 0 || $0.fileCount > 0
            } ?? false
            let updatedHasChildren = cachedParentHasSurvivingChildren[bucketPath]
                ?? (nextChildEdges[bucketPath].map { !$0.isEmpty } ?? bucket.hasChildren)
            if hasAggregateChange || updatedHasChildren != bucket.hasChildren {
                var updated = bucket
                updated.bytes = max(0, bucket.bytes - (dec?.bytes ?? 0))
                updated.logicalBytes = max(0, bucket.logicalBytes - (dec?.logicalBytes ?? 0))
                updated.fileCount = max(0, bucket.fileCount - (dec?.fileCount ?? 0))
                updated.hasChildren = updatedHasChildren
                nextBuckets[bucketPath] = updated
            } else {
                nextBuckets[bucketPath] = bucket
            }
        }

        var nextDirIndex = state.dirIndex
        for (ancestor, dec) in ancestorDecrements {
            guard var agg = nextDirIndex[ancestor] else { continue }
            agg.bytes = max(0, agg.bytes - dec.bytes)
            agg.logicalBytes = max(0, agg.logicalBytes - dec.logicalBytes)
            agg.fileCount = max(0, agg.fileCount - dec.fileCount)
            nextDirIndex[ancestor] = agg
        }
        nextDirIndex = nextDirIndex.filter { !matcher.contains($0.key) }

        var nextPerRoot: [String: PerRootProgress] = [:]
        nextPerRoot.reserveCapacity(sourcePerRoot.count)
        for (rootPath, progress) in sourcePerRoot where !matcher.contains(rootPath) {
            if let dec = ancestorDecrements[rootPath],
               dec.bytes > 0 || dec.logicalBytes > 0 || dec.fileCount > 0 {
                var updated = progress
                updated.bytes = max(0, updated.bytes - dec.bytes)
                updated.logicalBytes = max(0, updated.logicalBytes - dec.logicalBytes)
                updated.fileCount = max(0, updated.fileCount - dec.fileCount)
                nextPerRoot[rootPath] = updated
            } else {
                nextPerRoot[rootPath] = progress
            }
        }
        var nextActive: [String: PerRootProgress] = [:]
        var nextFinished: [String: PerRootProgress] = [:]
        nextActive.reserveCapacity(nextPerRoot.count)
        nextFinished.reserveCapacity(nextPerRoot.count)
        for (path, progress) in nextPerRoot {
            if progress.isFinished {
                nextFinished[path] = progress
            } else {
                nextActive[path] = progress
            }
        }
        let nextSorted = nextPerRoot.values.sorted { $0.rootPath < $1.rootPath }
        let nextPerRootProjection = buildPerRootProjection(
            staging: nextPerRoot,
            tombstones: matcher,
            previousActive: state.perRootActive,
            previousFinished: state.perRootFinished,
            previousFinishedCount: state.perRootFinished.count,
            previousSorted: state.perRootSorted,
            evidence: state.treeEvidenceProjection,
            locale: state.locale,
            sessionIsScanning: false
        )

        var nextLargeFileLeaves = state.largeFileLeaves
        let largeRemoved = nextLargeFileLeaves.removeAll { matcher.contains($0.path) }
        var nextCompacted = state.compactedLargeFileTopN
        let compactedLargeRemoved: Int
        if var cache = nextCompacted {
            let before = cache.count
            cache.removeAll { matcher.contains($0.path) }
            compactedLargeRemoved = before - cache.count
            nextCompacted = cache
        } else {
            compactedLargeRemoved = 0
        }

        var nextTreeCache: [String: [TreeRow]] = [:]
        nextTreeCache.reserveCapacity(state.treeChildrenCache.count)

        for (cacheKey, rows) in state.treeChildrenCache {
            let parentPath: String
            if let pipe = cacheKey.lastIndex(of: "|") {
                parentPath = String(cacheKey[..<pipe])
            } else {
                parentPath = cacheKey
            }
            if matcher.contains(parentPath) { continue }

            var anyRemoved = false
            var anyRowChanged = false
            var anyAggregateChanged = false
            for row in rows {
                if matcher.contains(row.path) {
                    anyRemoved = true
                    continue
                }
                let decrement = ancestorDecrements[row.path]
                let hasAggregateChange = decrement.map {
                    $0.bytes > 0 || $0.logicalBytes > 0 || $0.fileCount > 0
                } ?? false
                let updatedHasChildren = cachedParentHasSurvivingChildren[row.path]
                    ?? (nextChildEdges[row.path].map { !$0.isEmpty } ?? row.hasChildren)
                if hasAggregateChange {
                    anyAggregateChanged = true
                    anyRowChanged = true
                } else if updatedHasChildren != row.hasChildren {
                    anyRowChanged = true
                }
            }
            if !anyRemoved && !anyRowChanged {
                nextTreeCache[cacheKey] = rows
                continue
            }

            var nextRows: [TreeRow] = []
            nextRows.reserveCapacity(rows.count)
            for row in rows where !matcher.contains(row.path) {
                let decrement = ancestorDecrements[row.path]
                let hasAggregateChange = decrement.map {
                    $0.bytes > 0 || $0.logicalBytes > 0 || $0.fileCount > 0
                } ?? false
                let updatedHasChildren = cachedParentHasSurvivingChildren[row.path]
                    ?? (nextChildEdges[row.path].map { !$0.isEmpty } ?? row.hasChildren)
                guard hasAggregateChange || updatedHasChildren != row.hasChildren else {
                    nextRows.append(row)
                    continue
                }

                // deep-index 关闭时，已展开目录只存在于按需 cache。删除其后代后，
                // 必须与 snapshot/dirIndex/perRoot 在同一个 prune plan 内扣减祖先行；
                // 否则磁盘已删除但 Tree 会一直显示旧大小，直到用户重扫或重新展开。
                // 这里只更新聚合字段，其余访问证据、展开能力和元数据必须原样保留。
                nextRows.append(TreeRow(
                    path: row.path,
                    title: row.title,
                    bytes: max(0, row.bytes - (decrement?.bytes ?? 0)),
                    logicalBytes: max(0, row.logicalBytes - (decrement?.logicalBytes ?? 0)),
                    fileCount: max(0, row.fileCount - (decrement?.fileCount ?? 0)),
                    isDirectory: row.isDirectory,
                    hasChildren: updatedHasChildren,
                    accessState: row.accessState,
                    subtreeCompleteness: row.subtreeCompleteness,
                    modificationDate: row.modificationDate,
                    isSizePending: row.isSizePending,
                    titlePresentation: row.titlePresentation
                ))
            }
            if anyAggregateChanged,
               let sortKey = sortKeyFromCacheKey(cacheKey),
               sortKey == .sizeDesc || sortKey == .sizeAsc || sortKey == .countDesc || sortKey == .countAsc {
                nextRows.sort { sortTreeRow($0, before: $1, by: sortKey, locale: state.locale) }
            }
            nextTreeCache[cacheKey] = nextRows
        }

        return PrunePlan(
            prunedRoots: matcher.roots,
            snapshot: nextSnapshot,
            totalBytes: snapshotBytesToSubtract > 0
                ? max(0, state.totalBytes - snapshotBytesToSubtract)
                : state.totalBytes,
            scannedFiles: totalDeletedFiles > 0
                ? max(0, state.scannedFiles - totalDeletedFiles)
                : state.scannedFiles,
            buckets: nextBuckets,
            dirIndex: nextDirIndex,
            childEdges: nextChildEdges,
            fileLeaves: state.fileLeaves.filter { !matcher.contains($0.key) },
            treeChildrenCache: nextTreeCache,
            snapshotTreeRows: nextSnapshotTreeRows,
            largeFileLeaves: nextLargeFileLeaves,
            compactedLargeFileTopN: nextCompacted,
            perRootStaging: nextPerRoot,
            perRootActive: nextActive,
            perRootFinished: nextFinished,
            perRootFinishedCount: nextFinished.count,
            perRootSorted: nextSorted,
            perRootTreeRows: nextPerRootProjection.treeRowsBySort,
            largeRemoved: largeRemoved,
            compactedLargeRemoved: compactedLargeRemoved,
            treeCacheContributionIndexBuilt: treeCacheContributionIndexBuilt,
            ranOnMainThread: Thread.isMainThread,
            allocationCatalog: state.allocationCatalog,
            allocationRemovals: deletedContributions.map {
                .init(
                    path: $0.path,
                    allocatedBytes: $0.bytes,
                    logicalBytes: $0.logicalBytes,
                    fileCount: $0.fileCount,
                    isDirectory: $0.isDirectory
                )
            }
        )
    }

    /// Compare-and-swap 已在调用方完成。这里不再做任何 keys.filter / sort / reduce；
    /// Dictionary/Array storage 赋值是 O(1) COW 提交，随后只发布必要 revision。
    private func commitPrunePlan(_ plan: PrunePlan) {
        allocationCatalog = plan.allocationCatalog
        totalBytes = plan.totalBytes
        scannedFiles = plan.scannedFiles
        buckets = plan.buckets
        dirIndex = plan.dirIndex
        childEdges = plan.childEdges
        fileLeaves = plan.fileLeaves
        treeChildrenCache = plan.treeChildrenCache
        snapshotTreeRowsBySort = plan.snapshotTreeRows
        largeFileLeaves = plan.largeFileLeaves
        compactedLargeFileTopN = plan.compactedLargeFileTopN
        perRootStaging = plan.perRootStaging
        snapshot = plan.snapshot
        perRootProgressActive = plan.perRootActive
        perRootFinishedSlim = plan.perRootFinished
        perRootFinishedCount = plan.perRootFinishedCount
        perRootProgressSorted = plan.perRootSorted
        perRootTreeRowsBySort = plan.perRootTreeRows

        lastPrunedPaths = plan.prunedRoots
        lastPrunePlanRanOnMainThread = plan.ranOnMainThread
        lastPrunePlanDurationNanoseconds = plan.durationNanoseconds
        lastPruneTreeCacheContributionIndexBuilt = plan.treeCacheContributionIndexBuilt
        bumpChildrenCacheVersion()
        bumpStructuralRevision(advanceSourceRevision: false)
        storeRevision &+= 1

        if plan.largeRemoved > 0 {
            GSYLog.info(.scan, "pruneDeleted largeFileLeaves 剔除 \(plan.largeRemoved)")
        }
        if plan.compactedLargeRemoved > 0 {
            GSYLog.info(.scan, "pruneDeleted compactedLargeFileTopN 剔除 \(plan.compactedLargeRemoved)")
        }
    }

    /// v1.3.zz：暴露给 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 区分"后台 fetch 还在飞" vs "真的查到 0 条子项"——
    /// 前者应显 ProgressView 占位避免误导用户以为没数据；后者才显"还没有可展开的子节点"。
    ///
    /// 实现：cacheKey 在 `treeChildrenInFlight` 集合里，表示后台按需扫描已经派发但 cache 还没写回。
    public func isFetchingChildren(of path: String, sortedBy key: TreeSortKey) -> Bool {
        // 扫描中树表不做子节点加载，避免"扫描还没结束却显示正在加载子节点"。
        if isScanning { return false }
        if indexedSubtreeRequests.keys.contains(where: {
            Self.pathBelongsToSubtree(path, rootPath: $0)
        }) {
            return true
        }
        // v1.5：多根伪路径下 directChildren 是同步合成（perRootProgress），不存在 fetching。
        if ScanCoordinator.multiRootSentinelPaths.contains(path) { return false }
        // v2026.07.18：deep-index cache miss 也必须在后台完成 materialize/sort；命中
        // childEdges 不再等于“同步已就绪”。这条状态必须让 UI 展示 loading，而不是把
        // 首帧 cache miss 误报成空目录。
        if childEdges[path] != nil {
            return hasInFlightTreeChildren(path: path)
        }
        guard !enableTreeDeepIndex else { return false }
        if hasInFlightTreeChildren(path: path) { return true }
        if cachedTreeChildren(path: path, sortedBy: key) != nil { return false }
        return false
    }

    /// v1.5：多根扫描伪路径下合成"顶层" TreeRow——把 perRootProgress 里的真实根
    /// 升级成树形顶层节点。每行 path 是真实目录（如 ~/Library/Caches），
    /// 用户展开时 TreeBrowserView 会再次调 [directChildren(of:sortedBy:)](#) 拿真实的下一层
    /// （走原 childEdges / 按需子树扫描路径，无需改动）。
    /// - bytes / fileCount 直接复用 已统计好的值
    /// - title 沿用 .title（已带 displayName + 短路径）
    ///
    /// 扫描中不再由树表读取 staging；这里在完成态优先读已经发布给 UI 的
    /// perRootProgress，避免最终列表继续拿到 staging 里的半成品 inode 行。
    /// review-fix #6：hasChildren 不再硬编码 true—— fileCount==0 的 root（discover
    /// 命中但还未 ingest，或扫完确实空）就不显示披露三角，避免"展开后空树"的误导。
    private func synthesizeMultiRootTopLevel(sortedBy key: TreeSortKey) -> [TreeRow] {
        perRootTreeRowsBySort[key] ?? []
    }

    /// v2026.06.21：开发者旧版本扫描结束后的 TreeBrowserView 顶层合成。
    ///
    /// 与 [synthesizeMultiRootTopLevel] 的区别：旧版本扫描不进 BulkScanner 管线，
    /// `perRootProgress` 永远空；hits 都已经放在 `snapshot.rows` 里（titlePresentation
    /// 保存 catalog key + 原样版本后缀），所以直接把 snapshot.rows
    /// 上升成 TreeRow。`hasChildren=false`——TreeBrowserView 拿这个判定不画披露
    /// 三角；用户要看具体子文件可在 Finder 里展开（与多根 1-tier 风格一致）。
    private func synthesizeVersionedTopLevel(sortedBy key: TreeSortKey) -> [TreeRow] {
        snapshotTreeRowsBySort[key] ?? []
    }

    private func snapshotTopLevelRows(sortedBy key: TreeSortKey) -> [TreeRow] {
        snapshotTreeRowsBySort[key] ?? []
    }

    nonisolated private static func sortTreeRow(
        _ a: TreeRow,
        before b: TreeRow,
        by key: TreeSortKey,
        locale: Locale = .current
    ) -> Bool {
        switch key {
        case .sizeDesc:
            if a.bytes != b.bytes { return a.bytes > b.bytes }
        case .sizeAsc:
            if a.bytes != b.bytes { return a.bytes < b.bytes }
        case .nameAsc:
            let cmp = a.displayTitle(locale: locale).compare(
                b.displayTitle(locale: locale),
                options: [.caseInsensitive],
                range: nil,
                locale: locale
            )
            if cmp != .orderedSame { return cmp == .orderedAscending }
        case .nameDesc:
            let cmp = a.displayTitle(locale: locale).compare(
                b.displayTitle(locale: locale),
                options: [.caseInsensitive],
                range: nil,
                locale: locale
            )
            if cmp != .orderedSame { return cmp == .orderedDescending }
        case .countDesc:
            if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
        case .countAsc:
            if a.fileCount != b.fileCount { return a.fileCount < b.fileCount }
        case .mtimeDesc:
            let av = a.modificationDate, bv = b.modificationDate
            if av == nil && bv != nil { return false }
            if av != nil && bv == nil { return true }
            if let l = av, let r = bv, l != r { return l > r }
        case .mtimeAsc:
            let av = a.modificationDate, bv = b.modificationDate
            if av == nil && bv != nil { return false }
            if av != nil && bv == nil { return true }
            if let l = av, let r = bv, l != r { return l < r }
        }
        return a.path < b.path
    }

    /// Converts terminal rows to their Tree semantics once. Developer multi-root presentation
    /// reuses this before grouping by producer root; other categories feed the same values into
    /// the global Tree sort projections below.
    nonisolated private static func buildSemanticTreeRows(
        rows: [RowItem],
        evidence: TreeScanEvidenceProjection,
        forceLeafPresentation: Bool = false
    ) -> [TreeRow]? {
        var semanticRows: [TreeRow] = []
        semanticRows.reserveCapacity(rows.count)
        for row in rows {
            guard !Task.isCancelled else { return nil }
            let projectedState = evidence.projectedState(for: row.url.path)
            semanticRows.append(TreeRow(
                path: row.url.path,
                title: row.title,
                bytes: row.bytes,
                logicalBytes: row.logicalBytes,
                fileCount: row.fileCount,
                isDirectory: row.isDirectory,
                hasChildren: forceLeafPresentation ? false : row.isDirectory && row.hasChildren,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: row.modificationDate,
                titlePresentation: row.titlePresentation
            ))
        }
        return semanticRows
    }

    /// Materializes the completed flat snapshot into every Tree ordering once. This is deliberately
    /// independent from coordinator state so terminal, specialized and locale-reprojection workers
    /// can all share the exact same semantic boundary.
    nonisolated private static func buildSnapshotTreeRows(
        rows: [RowItem],
        evidence: TreeScanEvidenceProjection,
        locale: Locale,
        forceLeafPresentation: Bool = false
    ) -> [TreeSortKey: [TreeRow]]? {
        guard let semanticRows = buildSemanticTreeRows(
            rows: rows,
            evidence: evidence,
            forceLeafPresentation: forceLeafPresentation
        ) else { return nil }

        var result: [TreeSortKey: [TreeRow]] = [:]
        result.reserveCapacity(TreeSortKey.allCases.count)
        for sortKey in TreeSortKey.allCases {
            guard !Task.isCancelled else { return nil }
            result[sortKey] = semanticRows.sorted {
                sortTreeRow($0, before: $1, by: sortKey, locale: locale)
            }
        }
        return result
    }

    /// Pure deep-index projection used by the memory Tree worker. It reads no actor state and
    /// performs no filesystem I/O; missing dates are returned as one bounded request list for the
    /// separate metadata producer.
    nonisolated private static func buildMemoryTreeProjection(
        retainedState: MemoryTreeRetainedState,
        parentPath: String,
        tombstones: PrunedPathMatcher,
        whitelist: Set<String> = [],
        locale: Locale
    ) -> PreparedMemoryTreeProjection? {
        guard !Task.isCancelled else { return nil }
        var semanticRows: [TreeRow] = []
        semanticRows.reserveCapacity(retainedState.kids.count)
        var missingMtimePaths: [String] = []
        missingMtimePaths.reserveCapacity(
            min(retainedState.kids.count, mtimeFallbackPendingLimit)
        )
        var hasMoreMtimePaths = false

        for childPath in retainedState.kids
            where !tombstones.contains(childPath) && !isWhitelisted(childPath, in: whitelist)
        {
            guard !Task.isCancelled else { return nil }
            let projectedState = retainedState.evidence.projectedState(for: childPath)
            if let aggregate = retainedState.dirIndex[childPath] {
                let fallbackDate: Date?
                switch retainedState.mtimeCache[childPath] {
                case .found(let date): fallbackDate = date
                case .failure, .none: fallbackDate = nil
                }
                if aggregate.modificationDate == nil,
                   retainedState.mtimeCache[childPath] == nil {
                    if missingMtimePaths.count < mtimeFallbackPendingLimit {
                        missingMtimePaths.append(childPath)
                    } else {
                        hasMoreMtimePaths = true
                    }
                }
                semanticRows.append(TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: aggregate.bytes,
                    logicalBytes: aggregate.logicalBytes,
                    fileCount: aggregate.fileCount,
                    isDirectory: true,
                    hasChildren: !(retainedState.childEdges[childPath]?.isEmpty ?? true),
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: aggregate.modificationDate ?? fallbackDate
                ))
            } else if let leaf = retainedState.fileLeaves[childPath] {
                semanticRows.append(TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: leaf.bytes,
                    logicalBytes: leaf.logicalBytes,
                    fileCount: leaf.fileCount,
                    isDirectory: leaf.isDir,
                    hasChildren: false,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: leaf.modificationDate
                ))
            } else {
                semanticRows.append(TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: 0,
                    fileCount: 0,
                    isDirectory: false,
                    hasChildren: false,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness
                ))
            }
        }

        var nextCache = retainedState.cache
        for sortKey in TreeSortKey.allCases {
            guard !Task.isCancelled else { return nil }
            nextCache["\(parentPath)|\(sortKey.rawValue)"] = semanticRows.sorted {
                sortTreeRow($0, before: $1, by: sortKey, locale: locale)
            }
        }
        return PreparedMemoryTreeProjection(
            cache: nextCache,
            missingMtimePaths: missingMtimePaths,
            hasMoreMtimePaths: hasMoreMtimePaths,
            ranOnMainThread: Thread.isMainThread
        )
    }

    /// v2026.10.08: rebase local scan contributions against the transaction catalog before
    /// deriving any directory delta. Regular-file counts describe paths and do not change when
    /// the physical allocation moves between hardlink aliases.
    nonisolated private static func applyIncomingAllocationDeltas(
        _ deltas: [FileAllocationSnapshot.Delta], to measurement: inout IndexedSubtreeMeasurement
    ) {
        var ancestors: [String: (bytes: Int64, logical: Int64)] = [:]
        for delta in deltas {
            guard let leaf = measurement.fileLeaves[delta.path] else { continue }
            measurement.fileLeaves[delta.path] = IndexedFileLeaf(
                bytes: delta.resultingAllocatedBytes, logicalBytes: delta.resultingLogicalBytes,
                isDir: leaf.isDir, modificationDate: leaf.modificationDate,
                isRegularFile: leaf.isRegularFile)
            var parent = String._gsyParentPath(of: delta.path)
            while pathBelongsToSubtree(parent, rootPath: measurement.rootPath) {
                let old = ancestors[parent] ?? (0, 0)
                ancestors[parent] = (old.bytes + delta.allocatedBytes, old.logical + delta.logicalBytes)
                if parent == measurement.rootPath { break }
                let next = String._gsyParentPath(of: parent)
                guard next != parent else { break }
                parent = next
            }
        }
        for (path, delta) in ancestors {
            guard var value = measurement.dirIndex[path] else { continue }
            value.bytes = max(0, value.bytes + delta.bytes)
            value.logicalBytes = max(0, value.logicalBytes + delta.logical)
            measurement.dirIndex[path] = value
        }
    }

    /// Shared by subtree replacement and pruning. Accumulate signed corrections first, then
    /// project once into every source, so alias ownership transfer cannot drift between views.
    nonisolated private static func reconcileAllocationPresentation(
        _ deltas: [FileAllocationSnapshot.Delta],
        snapshot: inout ScanSnapshot, totalBytes: inout Int64,
        buckets: inout [String: Bucket], dirIndex: inout [String: DirAgg],
        fileLeaves: inout [String: IndexedFileLeaf], treeCache: inout [String: [TreeRow]],
        perRoot: inout [String: PerRootProgress], largeFiles: inout LargeFileLeafTopNHeap,
        compacted: inout [LargeFileLeaf]?, largeFileMinBytes: Int64,
        sortKey: MainListSortKey, locale: Locale
    ) {
        guard !deltas.isEmpty else { return }
        var adjustments: [String: (bytes: Int64, logical: Int64)] = [:]
        var totalDelta: Int64 = 0
        for delta in deltas {
            totalDelta += delta.allocatedBytes
            var cursor = delta.path
            while !cursor.isEmpty {
                let old = adjustments[cursor] ?? (0, 0)
                adjustments[cursor] = (old.bytes + delta.allocatedBytes, old.logical + delta.logicalBytes)
                if cursor == "/" { break }
                let parent = String._gsyParentPath(of: cursor)
                guard parent != cursor else { break }
                cursor = parent
            }
            if let leaf = fileLeaves[delta.path] {
                fileLeaves[delta.path] = IndexedFileLeaf(
                    bytes: delta.resultingAllocatedBytes, logicalBytes: delta.resultingLogicalBytes,
                    isDir: leaf.isDir, modificationDate: leaf.modificationDate,
                    isRegularFile: leaf.isRegularFile)
            }
        }
        for (path, delta) in adjustments {
            if var value = dirIndex[path] {
                value.bytes = max(0, value.bytes + delta.bytes)
                value.logicalBytes = max(0, value.logicalBytes + delta.logical)
                dirIndex[path] = value
            }
            if var value = buckets[path] {
                value.bytes = max(0, value.bytes + delta.bytes)
                value.logicalBytes = max(0, value.logicalBytes + delta.logical)
                buckets[path] = value
            }
            if var value = perRoot[path] {
                value.bytes = max(0, value.bytes + delta.bytes)
                value.logicalBytes = max(0, value.logicalBytes + delta.logical)
                perRoot[path] = value
            }
        }
        var rows = snapshot.rows.map { row in
            guard let delta = adjustments[row.id] else { return row }
            return RowItem(id: row.id, url: row.url, title: row.title, isDirectory: row.isDirectory,
                bytes: max(0, row.bytes + delta.bytes), logicalBytes: max(0, row.logicalBytes + delta.logical),
                fileCount: row.fileCount, verdict: row.verdict, rejection: row.rejection,
                vendorName: row.vendorName, vendorNote: row.vendorNote,
                runningBundleIDPrefix: row.runningBundleIDPrefix, isActive: row.isActive,
                hasChildren: row.hasChildren, modificationDate: row.modificationDate,
                titlePresentation: row.titlePresentation, vendorNamePresentation: row.vendorNamePresentation,
                vendorNotePresentation: row.vendorNotePresentation)
        }
        if snapshot.isFinished { rows.sort { sortKey.lessThan($0, $1, locale: locale) } }
        snapshot = ScanSnapshot(categoryID: snapshot.categoryID, rows: rows,
            totalBytes: max(0, snapshot.totalBytes + totalDelta), scannedFileCount: snapshot.scannedFileCount,
            isFinished: snapshot.isFinished, elapsed: snapshot.elapsed, isComplete: snapshot.isComplete,
            bytesPerSecond: snapshot.bytesPerSecond, estimatedRemaining: snapshot.estimatedRemaining)
        totalBytes = max(0, totalBytes + totalDelta)
        for (key, oldRows) in treeCache {
            let updated = oldRows.map { row in
                guard let delta = adjustments[row.path] else { return row }
                return TreeRow(path: row.path, title: row.title,
                    bytes: max(0, row.bytes + delta.bytes), logicalBytes: max(0, row.logicalBytes + delta.logical),
                    fileCount: row.fileCount, isDirectory: row.isDirectory, hasChildren: row.hasChildren,
                    accessState: row.accessState, subtreeCompleteness: row.subtreeCompleteness,
                    modificationDate: row.modificationDate, isSizePending: row.isSizePending,
                    titlePresentation: row.titlePresentation)
            }
            if let treeSort = sortKeyFromCacheKey(key) {
                treeCache[key] = updated.sorted { sortTreeRow($0, before: $1, by: treeSort, locale: locale) }
            } else { treeCache[key] = updated }
        }
        let byPath = Dictionary(uniqueKeysWithValues: deltas.map { ($0.path, $0) })
        let oldLarge = largeFiles.snapshot() + (compacted ?? [])
        var heap = LargeFileLeafTopNHeap(capacity: largeFiles.capacity)
        var seen = Set<String>()
        for leaf in oldLarge where byPath[leaf.path] == nil && seen.insert(leaf.path).inserted {
            heap.consider(leaf)
        }
        for delta in deltas where largeFileMinBytes > 0 && delta.resultingAllocatedBytes >= largeFileMinBytes {
            let mtime = fileLeaves[delta.path]?.modificationDate
                ?? oldLarge.first(where: { $0.path == delta.path })?.modificationDate
            heap.consider(LargeFileLeaf(path: delta.path, bytes: delta.resultingAllocatedBytes,
                logicalBytes: delta.resultingLogicalBytes, modificationDate: mtime))
        }
        largeFiles = heap
        if compacted != nil { compacted = heap.snapshot() }
    }

    nonisolated private static func applyExternalAllocationDeltas(
        _ deltas: [FileAllocationSnapshot.Delta], to state: inout IndexedSubtreeRetainedState,
        locale: Locale
    ) {
        guard !deltas.isEmpty else { return }
        reconcileAllocationPresentation(deltas, snapshot: &state.snapshot, totalBytes: &state.totalBytes,
            buckets: &state.buckets, dirIndex: &state.dirIndex, fileLeaves: &state.fileLeaves,
            treeCache: &state.treeCache, perRoot: &state.perRootStaging,
            largeFiles: &state.largeFileLeaves, compacted: &state.compactedLargeFileTopN,
            largeFileMinBytes: state.largeFileMinBytes, sortKey: state.mainListSortKey, locale: locale)
        if !state.snapshotTreeRows.isEmpty {
            state.snapshotTreeRows = buildSnapshotTreeRows(rows: state.snapshot.rows,
                evidence: state.previousTreeProjection, locale: locale,
                forceLeafPresentation: state.forceSnapshotTreeLeafPresentation) ?? [:]
        }
        let projection = buildPerRootProjection(staging: state.perRootStaging, tombstones: .init(paths: []),
            previousActive: state.perRootActive, previousFinished: state.perRootFinished,
            previousFinishedCount: state.perRootFinished.count, previousSorted: state.perRootSorted,
            evidence: state.previousTreeProjection, locale: locale, sessionIsScanning: false)
        state.perRootActive = projection.active
        state.perRootFinished = projection.finished
        state.perRootSorted = projection.sorted
        state.perRootTreeRows = projection.treeRowsBySort
    }

    /// v2026.10.09: an incomplete enumeration has no authority to remove published children.
    /// Merge the indexed observations with retained projection members on the worker, including
    /// shallow primary scans and expanded on-demand caches that have no deep-index identities.
    nonisolated private static func buildIndexedTreeChildren(
        parentPath: String,
        retainedRows: [TreeRow],
        dirIndex: [String: DirAgg],
        fileLeaves: [String: IndexedFileLeaf],
        childEdges: [String: Set<String>],
        isComplete: Bool,
        isAuthoritativelyEnumeratedPath: ((String) -> Bool)? = nil,
        evidence: TreeScanEvidenceProjection,
        tombstones: PrunedPathMatcher,
        whitelist: Set<String>
    ) -> [TreeRow]? {
        var rowsByPath: [String: TreeRow] = [:]
        if !isComplete {
            let observedChildren = childEdges[parentPath] ?? []
            for row in retainedRows {
                if let isAuthoritativelyEnumeratedPath,
                   isAuthoritativelyEnumeratedPath(row.path),
                   !observedChildren.contains(row.path) {
                    continue
                }
                rowsByPath[row.path] = row
            }
        }
        let children = (childEdges[parentPath] ?? []).union(rowsByPath.keys)
        for path in children {
            guard !Task.isCancelled else { return nil }
            guard !tombstones.contains(path), !isWhitelisted(path, in: whitelist) else {
                rowsByPath.removeValue(forKey: path)
                continue
            }
            let old = rowsByPath[path]
            let directory = dirIndex[path]
            let leaf = fileLeaves[path]
            guard directory != nil || leaf != nil || old != nil else { continue }
            let isDirectory = directory != nil || leaf?.isDir == true
                || leaf == nil && old?.isDirectory == true
            let state = evidence.projectedState(for: path)
            let hasChildren = isDirectory && (
                !(childEdges[path]?.isEmpty ?? true) || !isComplete && old?.hasChildren == true
            )
            rowsByPath[path] = TreeRow(
                path: path,
                title: old?.title ?? (path as NSString).lastPathComponent,
                bytes: directory?.bytes ?? leaf?.bytes ?? old?.bytes ?? 0,
                logicalBytes: directory?.logicalBytes ?? leaf?.logicalBytes ?? old?.logicalBytes ?? 0,
                fileCount: directory?.fileCount ?? leaf?.fileCount ?? old?.fileCount ?? 0,
                isDirectory: isDirectory,
                hasChildren: hasChildren,
                accessState: state.accessState,
                subtreeCompleteness: state.subtreeCompleteness,
                modificationDate: directory?.modificationDate ?? leaf?.modificationDate ?? old?.modificationDate,
                isSizePending: directory != nil && !isComplete,
                titlePresentation: old?.titlePresentation
            )
        }
        return Array(rowsByPath.values)
    }

    /// Builds the atomic replacement for an explicit indexed-subtree refresh. A complete
    /// measurement may shrink/remove old nodes; a partial measurement is only a lower bound and
    /// therefore unions observed identities while preserving unobserved old state fail-closed.
    /// v2026.07.18: all width-dependent filtering/materialization/sorting stays in the worker.
    nonisolated private static func buildIndexedSubtreeTransaction(
        retainedState: IndexedSubtreeRetainedState,
        measurement: IndexedSubtreeMeasurement,
        tombstones: PrunedPathMatcher,
        whitelist: Set<String> = [],
        locale: Locale
    ) -> PreparedIndexedSubtreeTransaction? {
        guard !Task.isCancelled else { return nil }
        let rootPath = measurement.rootPath
        guard !tombstones.contains(rootPath), !isWhitelisted(rootPath, in: whitelist) else {
            return nil
        }

        var retainedState = retainedState
        var measurement = measurement
        let rootEnumerated = measurement.allocations.hasObservedDirectory(rootPath)
        let incompleteSubtreeRoots = Set(measurement.incompleteIssues.map(\.path))
        let incompleteDirectDirectories = Set(
            measurement.incompleteIssues.compactMap { issue -> String? in
                guard issue.stage == .metadata else { return nil }
                return String._gsyParentPath(of: issue.path)
            }
        )
        let isAuthoritativelyEnumeratedPath: (String) -> Bool = { path in
            guard pathBelongsToSubtree(path, rootPath: rootPath) else { return false }
            if measurement.isComplete { return true }
            if measurement.fileLeaves[path] != nil { return true }
            guard rootEnumerated else { return false }
            if incompleteDirectDirectories.contains(where: { pathBelongsToSubtree(path, rootPath: $0) }) {
                return false
            }
            return !incompleteSubtreeRoots.contains { issuePath in
                pathBelongsToSubtree(path, rootPath: issuePath)
            }
        }
        let previousAllocations = retainedState.allocationCatalog?.snapshot()
        var scopedExternalByteDelta: Int64 = 0
        var scopedExternalLogicalDelta: Int64 = 0
        if let catalog = previousAllocations {
            let replacement = catalog.replacing(
                with: measurement.allocations,
                replacesPath: isAuthoritativelyEnumeratedPath,
                excludesPath: { tombstones.contains($0) }
            )
            applyIncomingAllocationDeltas(replacement.incomingDeltas, to: &measurement)
            applyExternalAllocationDeltas(replacement.externalDeltas, to: &retainedState, locale: locale)
            // A partial refresh can retain a hardlink owner inside this scope. Its correction
            // already updated published totals above, so it also advances the delta baseline.
            for delta in replacement.externalDeltas where pathBelongsToSubtree(delta.path, rootPath: rootPath) {
                scopedExternalByteDelta += delta.allocatedBytes
                scopedExternalLogicalDelta += delta.logicalBytes
            }
            retainedState.allocationCatalog = .committed(replacement.snapshot)
        } else {
            retainedState.allocationCatalog = .committed(measurement.allocations)
        }

        var nextTreeEvidence = retainedState.treeEvidenceByRoot
        let replacementIssues = measurement.incompleteIssues
            .map(normalizedIncompleteIssue)
            .filter { !tombstones.contains($0.path) }
            .sorted(by: incompleteIssueComesBefore)
        let replacementEvidence = ScanIncompleteEvidenceIndex(issues: replacementIssues)
        if replacementEvidence.isEmpty {
            nextTreeEvidence.removeValue(forKey: rootPath)
        } else {
            nextTreeEvidence[rootPath] = replacementEvidence
        }
        let preparedEvidence = buildIncompleteEvidenceProjection(
            primaryEvidence: retainedState.primaryEvidence,
            treeEvidenceByRoot: nextTreeEvidence,
            previousIssues: retainedState.previousIssues,
            previousPermissionPaths: retainedState.previousPermissionPaths,
            previousTCCPaths: retainedState.previousTCCPaths,
            previousAllPaths: retainedState.previousAllPaths
        )
        let evidenceProjection = preparedEvidence.treeProjection

        let oldRootAggregate: DirAgg = {
            if let previousAllocations, previousAllocations.covers(directory: rootPath) {
                let aggregate = previousAllocations.aggregate(inDirectory: rootPath)
                return DirAgg(bytes: aggregate.allocatedBytes + scopedExternalByteDelta,
                              logicalBytes: aggregate.logicalBytes + scopedExternalLogicalDelta,
                              fileCount: aggregate.fileCount)
            }
            if let aggregate = retainedState.dirIndex[rootPath] { return aggregate }
            let parentPath = String._gsyParentPath(of: rootPath)
            for sortKey in TreeSortKey.allCases {
                let key = "\(parentPath)|\(sortKey.rawValue)"
                if let row = retainedState.treeCache[key]?.first(where: { $0.path == rootPath }) {
                    return DirAgg(
                        bytes: row.bytes,
                        logicalBytes: row.logicalBytes,
                        fileCount: row.fileCount,
                        modificationDate: row.modificationDate
                    )
                }
            }
            if let bucket = retainedState.buckets[rootPath] {
                return DirAgg(
                    bytes: bucket.bytes,
                    logicalBytes: bucket.logicalBytes,
                    fileCount: bucket.fileCount,
                    modificationDate: bucket.modificationDate
                )
            }
            if let row = retainedState.snapshot.rows.first(where: { $0.id == rootPath }) {
                return DirAgg(
                    bytes: row.bytes,
                    logicalBytes: row.logicalBytes,
                    fileCount: row.fileCount,
                    modificationDate: row.modificationDate
                )
            }
            if let progress = retainedState.perRootFinished[rootPath]
                ?? retainedState.perRootStaging[rootPath]
            {
                return DirAgg(
                    bytes: progress.bytes,
                    logicalBytes: progress.logicalBytes,
                    fileCount: progress.fileCount,
                    modificationDate: nil
                )
            }
            for rows in retainedState.snapshotTreeRows.values {
                if let row = rows.first(where: { $0.path == rootPath }) {
                    return DirAgg(
                        bytes: row.bytes,
                        logicalBytes: row.logicalBytes,
                        fileCount: row.fileCount,
                        modificationDate: row.modificationDate
                    )
                }
            }
            for rows in retainedState.perRootTreeRows.values {
                if let row = rows.first(where: { $0.path == rootPath }) {
                    return DirAgg(
                        bytes: row.bytes,
                        logicalBytes: row.logicalBytes,
                        fileCount: row.fileCount,
                        modificationDate: row.modificationDate
                    )
                }
            }
            if !retainedState.usesPerRootPresentation, retainedState.scanResultRoots.contains(rootPath) {
                return DirAgg(bytes: retainedState.snapshot.totalBytes,
                    logicalBytes: retainedState.snapshot.rows.reduce(0) { $0 + $1.logicalBytes },
                    fileCount: retainedState.snapshot.scannedFileCount)
            }
            return DirAgg()
        }()

        var nextDirIndex: [String: DirAgg]
        var nextChildEdges: [String: Set<String>]
        var nextFileLeaves: [
            String: IndexedFileLeaf
        ]
        if measurement.isComplete {
            nextDirIndex = retainedState.dirIndex.filter {
                !pathBelongsToSubtree($0.key, rootPath: rootPath)
            }
            nextChildEdges = retainedState.childEdges.filter {
                !pathBelongsToSubtree($0.key, rootPath: rootPath)
            }
            nextFileLeaves = retainedState.fileLeaves.filter {
                !pathBelongsToSubtree($0.key, rootPath: rootPath)
            }
            for (path, aggregate) in measurement.dirIndex
                where !tombstones.contains(path) && !isWhitelisted(path, in: whitelist)
            {
                nextDirIndex[path] = aggregate
            }
            for (parent, children) in measurement.childEdges
                where !tombstones.contains(parent) && !isWhitelisted(parent, in: whitelist)
            {
                nextChildEdges[parent] = Set(
                    children.lazy.filter {
                        !tombstones.contains($0) && !isWhitelisted($0, in: whitelist)
                    }
                )
            }
            for (path, leaf) in measurement.fileLeaves
                where !tombstones.contains(path) && !isWhitelisted(path, in: whitelist)
            {
                nextFileLeaves[path] = leaf
            }
        } else {
            nextDirIndex = retainedState.dirIndex.filter {
                !isAuthoritativelyEnumeratedPath($0.key) || measurement.dirIndex[$0.key] != nil
            }
            // A production shallow scan has a catalog/projection baseline but no deep index.
            // Missing indexed state is not evidence that the previously measured root was empty.
            nextDirIndex[rootPath] = oldRootAggregate
            nextChildEdges = retainedState.childEdges.filter {
                !isAuthoritativelyEnumeratedPath($0.key)
            }
            nextFileLeaves = retainedState.fileLeaves.filter {
                !isAuthoritativelyEnumeratedPath($0.key)
            }
            for (path, incoming) in measurement.dirIndex
                where !tombstones.contains(path) && !isWhitelisted(path, in: whitelist)
            {
                let old = nextDirIndex[path] ?? DirAgg()
                if isAuthoritativelyEnumeratedPath(path) {
                    nextDirIndex[path] = DirAgg(
                        bytes: incoming.bytes,
                        logicalBytes: incoming.logicalBytes,
                        fileCount: incoming.fileCount,
                        modificationDate: incoming.modificationDate ?? old.modificationDate
                    )
                } else {
                    nextDirIndex[path] = DirAgg(
                        bytes: max(old.bytes, incoming.bytes),
                        logicalBytes: max(old.logicalBytes, incoming.logicalBytes),
                        fileCount: max(old.fileCount, incoming.fileCount),
                        modificationDate: incoming.modificationDate ?? old.modificationDate
                    )
                }
            }
            for (parent, children) in measurement.childEdges
                where !tombstones.contains(parent) && !isWhitelisted(parent, in: whitelist)
            {
                let filteredChildren = Set(
                    children.lazy.filter {
                        !tombstones.contains($0) && !isWhitelisted($0, in: whitelist)
                    }
                )
                if isAuthoritativelyEnumeratedPath(parent) {
                    let preservedUnenumerated = (retainedState.childEdges[parent] ?? []).filter {
                        !isAuthoritativelyEnumeratedPath($0)
                            && !tombstones.contains($0)
                            && !isWhitelisted($0, in: whitelist)
                    }
                    nextChildEdges[parent] = filteredChildren.union(preservedUnenumerated)
                } else {
                    nextChildEdges[parent, default: []].formUnion(filteredChildren)
                }
            }
            for (path, leaf) in measurement.fileLeaves
                where !tombstones.contains(path) && !isWhitelisted(path, in: whitelist)
            {
                nextFileLeaves[path] = leaf
            }
        }

        // v2026.10.09: the merged sparse catalog is the shared allocation authority. A partial
        // root's total is the sum of retained and observed directories, not max(old, incoming).
        // Materialize its aggregates once on this worker to avoid one catalog walk per node.
        if let catalog = retainedState.allocationCatalog?.snapshot(), catalog.covers(directory: rootPath) {
            let aggregates = catalog.directoryAggregates(inDirectory: rootPath)
            for path in Array(nextDirIndex.keys) where pathBelongsToSubtree(path, rootPath: rootPath) {
                if let value = aggregates[path] {
                    var directory = nextDirIndex[path] ?? DirAgg()
                    directory.bytes = value.allocatedBytes
                    directory.logicalBytes = value.logicalBytes
                    directory.fileCount = value.fileCount
                    nextDirIndex[path] = directory
                } else if isAuthoritativelyEnumeratedPath(path) {
                    var directory = nextDirIndex[path] ?? DirAgg()
                    directory.bytes = 0
                    directory.logicalBytes = 0
                    directory.fileCount = 0
                    nextDirIndex[path] = directory
                }
            }
        }

        let newRootAggregate = nextDirIndex[rootPath] ?? oldRootAggregate
        let byteDelta = newRootAggregate.bytes - oldRootAggregate.bytes
        let logicalDelta = newRootAggregate.logicalBytes - oldRootAggregate.logicalBytes
        let fileDelta = newRootAggregate.fileCount - oldRootAggregate.fileCount
        var affectedAggregatePaths: Set<String> = [rootPath]
        var ancestor = String._gsyParentPath(of: rootPath)
        while !ancestor.isEmpty, ancestor != rootPath {
            affectedAggregatePaths.insert(ancestor)
            if var aggregate = nextDirIndex[ancestor] {
                aggregate.bytes = max(0, aggregate.bytes &+ byteDelta)
                aggregate.logicalBytes = max(0, aggregate.logicalBytes &+ logicalDelta)
                aggregate.fileCount = max(0, aggregate.fileCount &+ fileDelta)
                nextDirIndex[ancestor] = aggregate
            }
            if ancestor == "/" { break }
            let parent = String._gsyParentPath(of: ancestor)
            guard parent != ancestor else { break }
            ancestor = parent
        }

        var nextMtimeCache = retainedState.mtimeCache
        if measurement.isComplete {
            nextMtimeCache = nextMtimeCache.filter {
                !pathBelongsToSubtree($0.key, rootPath: rootPath)
            }
        } else {
            for path in measurement.dirIndex.keys {
                nextMtimeCache.removeValue(forKey: path)
            }
        }

        var nextTreeCache: [String: [TreeRow]] = [:]
        nextTreeCache.reserveCapacity(retainedState.treeCache.count)
        for (cacheKey, oldRows) in retainedState.treeCache {
            guard !Task.isCancelled else { return nil }
            guard let separator = cacheKey.lastIndex(of: "|") else {
                nextTreeCache[cacheKey] = oldRows
                continue
            }
            let cachePath = String(cacheKey[..<separator])
            if pathBelongsToSubtree(cachePath, rootPath: rootPath) {
                if !measurement.isComplete, let sortKey = sortKeyFromCacheKey(cacheKey) {
                    guard let rows = buildIndexedTreeChildren(
                        parentPath: cachePath, retainedRows: oldRows, dirIndex: nextDirIndex,
                        fileLeaves: nextFileLeaves, childEdges: nextChildEdges, isComplete: false,
                        isAuthoritativelyEnumeratedPath: isAuthoritativelyEnumeratedPath,
                        evidence: evidenceProjection, tombstones: tombstones, whitelist: whitelist
                    ) else { return nil }
                    nextTreeCache[cacheKey] = rows.sorted {
                        sortTreeRow($0, before: $1, by: sortKey, locale: locale)
                    }
                }
                continue
            }
            var rows = oldRows
            var changed = false
            for index in rows.indices {
                let old = rows[index]
                guard affectedAggregatePaths.contains(old.path) else { continue }
                let updatedBytes: Int64
                let updatedLogicalBytes: Int64
                let updatedFileCount: Int
                let updatedHasChildren: Bool
                let updatedMtime: Date?
                if let aggregate = nextDirIndex[old.path] {
                    updatedBytes = aggregate.bytes
                    updatedLogicalBytes = aggregate.logicalBytes
                    updatedFileCount = aggregate.fileCount
                    updatedHasChildren = !(nextChildEdges[old.path]?.isEmpty ?? true)
                    updatedMtime = aggregate.modificationDate ?? old.modificationDate
                } else {
                    updatedBytes = max(0, old.bytes &+ byteDelta)
                    updatedLogicalBytes = max(0, old.logicalBytes &+ logicalDelta)
                    updatedFileCount = max(0, old.fileCount &+ fileDelta)
                    updatedHasChildren = nextChildEdges[old.path].map { !$0.isEmpty }
                        ?? old.hasChildren
                    updatedMtime = old.modificationDate
                }
                let projectedState = evidenceProjection.projectedState(
                    for: old.path,
                    fallbackAccessState: old.accessState,
                    fallbackSubtreeCompleteness: old.subtreeCompleteness
                )
                rows[index] = TreeRow(
                    path: old.path,
                    title: old.title,
                    bytes: updatedBytes,
                    logicalBytes: updatedLogicalBytes,
                    fileCount: updatedFileCount,
                    isDirectory: old.isDirectory,
                    hasChildren: updatedHasChildren,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: updatedMtime,
                    isSizePending: old.path == rootPath && measurement.isComplete
                        ? false
                        : old.isSizePending,
                    titlePresentation: old.titlePresentation
                )
                changed = true
            }
            if changed, let sortKey = sortKeyFromCacheKey(cacheKey) {
                rows.sort { sortTreeRow($0, before: $1, by: sortKey, locale: locale) }
            }
            nextTreeCache[cacheKey] = rows
        }

        // Complete observations replace the graph. Partial observations merge every previously
        // published source, including shallow List rows that never entered childEdges.
        var retainedRootRows: [TreeRow] = []
        for sortKey in TreeSortKey.allCases {
            if let rows = retainedState.treeCache["\(rootPath)|\(sortKey.rawValue)"] {
                retainedRootRows = rows
                break
            }
        }
        if !measurement.isComplete, !retainedState.usesLargeFileTopNOnly,
           retainedState.scanResultRoots.contains(rootPath) {
            guard let publishedRows = buildSemanticTreeRows(
                rows: retainedState.snapshot.rows.filter { String._gsyParentPath(of: $0.id) == rootPath },
                evidence: evidenceProjection,
                forceLeafPresentation: retainedState.forceSnapshotTreeLeafPresentation
            ) else { return nil }
            retainedRootRows.append(contentsOf: publishedRows)
        }
        guard let semanticRows = buildIndexedTreeChildren(
            parentPath: rootPath, retainedRows: retainedRootRows, dirIndex: nextDirIndex,
            fileLeaves: nextFileLeaves, childEdges: nextChildEdges, isComplete: measurement.isComplete,
            isAuthoritativelyEnumeratedPath: isAuthoritativelyEnumeratedPath,
            evidence: evidenceProjection, tombstones: tombstones, whitelist: whitelist
        ) else { return nil }
        for sortKey in TreeSortKey.allCases {
            guard !Task.isCancelled else { return nil }
            nextTreeCache["\(rootPath)|\(sortKey.rawValue)"] = semanticRows.sorted {
                sortTreeRow($0, before: $1, by: sortKey, locale: locale)
            }
        }

        // Reconcile top-level buckets, snapshot rows, snapshotTreeRows, and perRoot progress
        // when the refreshed subtree is itself a top-level item or a descendant of one.
        var nextBuckets = retainedState.buckets
        for (bucketPath, bucket) in retainedState.buckets
            where affectedAggregatePaths.contains(bucketPath)
        {
            var updated = bucket
            if let agg = nextDirIndex[bucketPath] {
                updated.bytes = agg.bytes
                updated.logicalBytes = agg.logicalBytes
                updated.fileCount = agg.fileCount
                if let mtime = agg.modificationDate {
                    updated.modificationDate = mtime
                }
            } else {
                updated.bytes = max(0, bucket.bytes &+ byteDelta)
                updated.logicalBytes = max(0, bucket.logicalBytes &+ logicalDelta)
                updated.fileCount = max(0, bucket.fileCount &+ fileDelta)
            }
            if let kids = nextChildEdges[bucketPath] {
                updated.hasChildren = !kids.isEmpty
            }
            nextBuckets[bucketPath] = updated
        }

        var nextRows = retainedState.snapshot.rows
        var didMutateSnapshotRows = false
        for idx in nextRows.indices {
            let row = nextRows[idx]
            guard affectedAggregatePaths.contains(row.id) else { continue }
            let updatedBytes: Int64
            let updatedLogicalBytes: Int64
            let updatedFileCount: Int
            if let agg = nextDirIndex[row.id] {
                updatedBytes = agg.bytes
                updatedLogicalBytes = agg.logicalBytes
                updatedFileCount = agg.fileCount
            } else {
                updatedBytes = max(0, row.bytes &+ byteDelta)
                updatedLogicalBytes = max(0, row.logicalBytes &+ logicalDelta)
                updatedFileCount = max(0, row.fileCount &+ fileDelta)
            }
            let updatedHasChildren = retainedState.forceSnapshotTreeLeafPresentation
                ? false
                : (nextChildEdges[row.id].map { !$0.isEmpty } ?? row.hasChildren)
            let updatedMtime = nextDirIndex[row.id]?.modificationDate ?? row.modificationDate
            nextRows[idx] = RowItem(
                id: row.id,
                url: row.url,
                title: row.title,
                isDirectory: row.isDirectory,
                bytes: updatedBytes,
                logicalBytes: updatedLogicalBytes,
                fileCount: updatedFileCount,
                verdict: row.verdict,
                rejection: row.rejection,
                vendorName: row.vendorName,
                vendorNote: row.vendorNote,
                runningBundleIDPrefix: row.runningBundleIDPrefix,
                isActive: row.isActive,
                hasChildren: updatedHasChildren,
                modificationDate: updatedMtime,
                titlePresentation: row.titlePresentation,
                vendorNamePresentation: row.vendorNamePresentation,
                vendorNotePresentation: row.vendorNotePresentation
            )
            didMutateSnapshotRows = true
        }
        // v2026.10.08 Undo review: multi-root List rows are also first-level children.
        // Rebuild this root's rows while retaining every other root's published members.
        if !retainedState.usesLargeFileTopNOnly,
           retainedState.scanResultRoots.contains(rootPath) {
            let children = nextChildEdges[rootPath] ?? []
            let oldRowsByPath = Dictionary(uniqueKeysWithValues: retainedState.snapshot.rows.map { ($0.id, $0) })
            var rowsByPath: [String: RowItem] = [:]
            if !measurement.isComplete {
                for row in nextRows where String._gsyParentPath(of: row.id) == rootPath
                    && !tombstones.contains(row.id) && !isWhitelisted(row.id, in: whitelist)
                    && (!isAuthoritativelyEnumeratedPath(row.id) || children.contains(row.id)) {
                    rowsByPath[row.id] = row
                }
            }
            for path in children where !tombstones.contains(path) && !isWhitelisted(path, in: whitelist) {
                let directory = nextDirIndex[path]
                let leaf = nextFileLeaves[path]
                guard directory != nil || leaf != nil else { continue }
                let bytes = directory?.bytes ?? leaf?.bytes ?? 0
                let logical = directory?.logicalBytes ?? leaf?.logicalBytes ?? 0
                let count = directory?.fileCount ?? leaf?.fileCount ?? 0
                let isDirectory = directory != nil
                let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
                let safety = retainedState.engine.evaluate(path: path, trie: retainedState.trie, home: retainedState.home)
                var bucket = Bucket(url: url, bytes: bytes, logicalBytes: logical,
                    fileCount: count, isDirectory: isDirectory,
                    hasChildren: !(nextChildEdges[path]?.isEmpty ?? true)
                        || !measurement.isComplete && oldRowsByPath[path]?.hasChildren == true,
                    modificationDate: directory?.modificationDate ?? leaf?.modificationDate)
                bucket.cachedVerdict = safety.0
                bucket.cachedRejection = safety.1
                bucket.cachedVendor = safety.2
                nextBuckets[path] = bucket
                let old = oldRowsByPath[path]
                rowsByPath[path] = RowItem(id: path, url: url, title: old?.title ?? url.lastPathComponent,
                    isDirectory: isDirectory, bytes: bytes, logicalBytes: logical, fileCount: count,
                    verdict: safety.0, rejection: safety.1, vendorName: safety.2?.name,
                    vendorNote: safety.2?.note,
                    runningBundleIDPrefix: safety.2?.bundleIDPrefix ?? old?.runningBundleIDPrefix,
                    hasChildren: bucket.hasChildren, modificationDate: bucket.modificationDate,
                    titlePresentation: old?.titlePresentation)
            }
            if measurement.isComplete {
                nextBuckets = nextBuckets.filter { !pathBelongsToSubtree($0.key, rootPath: rootPath) || children.contains($0.key) }
            } else {
                nextBuckets = nextBuckets.filter {
                    !pathBelongsToSubtree($0.key, rootPath: rootPath)
                        || !isAuthoritativelyEnumeratedPath($0.key)
                        || children.contains($0.key)
                }
            }
            if retainedState.usesPerRootPresentation {
                nextRows.removeAll { pathBelongsToSubtree($0.id, rootPath: rootPath) }
                nextRows.append(contentsOf: rowsByPath.values)
            } else {
                nextRows = Array(rowsByPath.values)
            }
            didMutateSnapshotRows = true
        }
        if didMutateSnapshotRows && retainedState.snapshot.isFinished {
            let sortKey = retainedState.mainListSortKey
            nextRows.sort { sortKey.lessThan($0, $1, locale: locale) }
        }

        var nextPerRootStaging = retainedState.perRootStaging
        var didMutatePerRoot = false
        for (perRootKey, progress) in retainedState.perRootStaging
            where affectedAggregatePaths.contains(perRootKey)
        {
            var updated = progress
            if let agg = nextDirIndex[perRootKey] {
                updated.bytes = agg.bytes
                updated.logicalBytes = agg.logicalBytes
                updated.fileCount = agg.fileCount
            } else {
                updated.bytes = max(0, progress.bytes &+ byteDelta)
                updated.logicalBytes = max(0, progress.logicalBytes &+ logicalDelta)
                updated.fileCount = max(0, progress.fileCount &+ fileDelta)
            }
            nextPerRootStaging[perRootKey] = updated
            didMutatePerRoot = true
        }
        for (perRootKey, progress) in retainedState.perRootFinished
            where affectedAggregatePaths.contains(perRootKey) && nextPerRootStaging[perRootKey] == nil
        {
            var updated = progress
            if let agg = nextDirIndex[perRootKey] {
                updated.bytes = agg.bytes
                updated.logicalBytes = agg.logicalBytes
                updated.fileCount = agg.fileCount
            } else {
                updated.bytes = max(0, progress.bytes &+ byteDelta)
                updated.logicalBytes = max(0, progress.logicalBytes &+ logicalDelta)
                updated.fileCount = max(0, progress.fileCount &+ fileDelta)
            }
            nextPerRootStaging[perRootKey] = updated
            didMutatePerRoot = true
        }

        if retainedState.usesPerRootPresentation, retainedState.scanResultRoots.contains(rootPath),
           nextPerRootStaging[rootPath] == nil, let aggregate = nextDirIndex[rootPath] {
            nextPerRootStaging[rootPath] = PerRootProgress(rootPath: rootPath,
                title: URL(fileURLWithPath: rootPath).lastPathComponent,
                bytes: aggregate.bytes, logicalBytes: aggregate.logicalBytes, fileCount: aggregate.fileCount,
                isFinished: true, isPartial: !measurement.isComplete)
            didMutatePerRoot = true
        }

        let nextPerRootActive: [String: PerRootProgress]
        let nextPerRootFinished: [String: PerRootProgress]
        let nextPerRootSorted: [PerRootProgress]
        let nextPerRootTreeRows: [TreeSortKey: [TreeRow]]
        if didMutatePerRoot {
            var active: [String: PerRootProgress] = [:]
            var finished: [String: PerRootProgress] = [:]
            for (path, progress) in nextPerRootStaging {
                if progress.isFinished {
                    finished[path] = progress
                } else {
                    active[path] = progress
                }
            }
            nextPerRootActive = active
            nextPerRootFinished = finished
            nextPerRootSorted = nextPerRootStaging.values.sorted { $0.rootPath < $1.rootPath }
            let perRootProjection = buildPerRootProjection(
                staging: nextPerRootStaging,
                tombstones: tombstones,
                previousActive: retainedState.perRootActive,
                previousFinished: retainedState.perRootFinished,
                previousFinishedCount: retainedState.perRootFinished.count,
                previousSorted: retainedState.perRootSorted,
                evidence: evidenceProjection,
                locale: locale,
                sessionIsScanning: false
            )
            nextPerRootTreeRows = perRootProjection.treeRowsBySort
        } else {
            nextPerRootActive = retainedState.perRootActive
            nextPerRootFinished = retainedState.perRootFinished
            nextPerRootSorted = retainedState.perRootSorted
            nextPerRootTreeRows = retainedState.perRootTreeRows
        }

        let didAffectTopLevelTotals = didMutateSnapshotRows
            || didMutatePerRoot || previousAllocations != nil
            || retainedState.scanResultRoots.contains(rootPath)
            || retainedState.buckets.keys.contains(where: { affectedAggregatePaths.contains($0) })
        let nextTotalBytes = didAffectTopLevelTotals
            ? max(0, retainedState.totalBytes &+ byteDelta)
            : retainedState.totalBytes
        let nextScannedFiles = didAffectTopLevelTotals
            ? max(0, retainedState.scannedFiles &+ fileDelta)
            : retainedState.scannedFiles
        let nextSnapshot: ScanSnapshot
        if didMutateSnapshotRows || didAffectTopLevelTotals {
            nextSnapshot = ScanSnapshot(
                categoryID: retainedState.snapshot.categoryID,
                rows: nextRows,
                totalBytes: max(0, retainedState.snapshot.totalBytes &+ byteDelta),
                scannedFileCount: max(0, retainedState.snapshot.scannedFileCount &+ fileDelta),
                isFinished: retainedState.snapshot.isFinished,
                elapsed: retainedState.snapshot.elapsed,
                isComplete: retainedState.snapshot.isComplete,
                bytesPerSecond: retainedState.snapshot.bytesPerSecond,
                estimatedRemaining: retainedState.snapshot.estimatedRemaining
            )
        } else {
            nextSnapshot = retainedState.snapshot
        }

        let nextSnapshotTreeRows: [TreeSortKey: [TreeRow]]
        // Projection availability follows mode semantics, never the old cache's emptiness.
        if retainedState.usesPerRootPresentation || retainedState.usesLargeFileTopNOnly || nextRows.isEmpty {
            nextSnapshotTreeRows = [:]
        } else if didMutateSnapshotRows || retainedState.snapshotTreeRows.isEmpty {
            nextSnapshotTreeRows = buildSnapshotTreeRows(
                rows: nextRows,
                evidence: evidenceProjection,
                locale: locale,
                forceLeafPresentation: retainedState.forceSnapshotTreeLeafPresentation
            ) ?? retainedState.snapshotTreeRows
        } else {
            nextSnapshotTreeRows = retainedState.snapshotTreeRows
        }

        var nextLargeFileLeaves = LargeFileLeafTopNHeap(capacity: retainedState.largeFileLeaves.capacity)
        let retainedLargeFiles = retainedState.largeFileLeaves.snapshot() + (retainedState.compactedLargeFileTopN ?? [])
        var seenLargePaths = Set<String>()
        for leaf in retainedLargeFiles where !pathBelongsToSubtree(leaf.path, rootPath: rootPath)
            || !measurement.isComplete && measurement.fileLeaves[leaf.path] == nil {
            if seenLargePaths.insert(leaf.path).inserted { nextLargeFileLeaves.consider(leaf) }
        }
        for (path, leaf) in nextFileLeaves where pathBelongsToSubtree(path, rootPath: rootPath)
            && leaf.isRegularFile && retainedState.largeFileMinBytes > 0
            && leaf.bytes >= retainedState.largeFileMinBytes
            && !tombstones.contains(path) && !isWhitelisted(path, in: whitelist) {
            nextLargeFileLeaves.consider(LargeFileLeaf(path: path, bytes: leaf.bytes,
                logicalBytes: leaf.logicalBytes, modificationDate: leaf.modificationDate))
        }
        let nextCompactedLargeFiles = retainedState.compactedLargeFileTopN == nil
            ? nil : nextLargeFileLeaves.snapshot()

        return PreparedIndexedSubtreeTransaction(
            snapshot: nextSnapshot,
            totalBytes: nextTotalBytes,
            scannedFiles: nextScannedFiles,
            buckets: nextBuckets,
            snapshotTreeRows: nextSnapshotTreeRows,
            perRootStaging: nextPerRootStaging,
            perRootActive: nextPerRootActive,
            perRootFinished: nextPerRootFinished,
            perRootFinishedCount: nextPerRootFinished.count,
            perRootSorted: nextPerRootSorted,
            perRootTreeRows: nextPerRootTreeRows,
            dirIndex: nextDirIndex,
            childEdges: nextChildEdges,
            fileLeaves: nextFileLeaves,
            treeCache: nextTreeCache,
            mtimeCache: nextMtimeCache,
            treeEvidenceByRoot: nextTreeEvidence,
            evidence: preparedEvidence,
            allocationCatalog: retainedState.allocationCatalog,
            largeFileLeaves: nextLargeFileLeaves,
            compactedLargeFileTopN: nextCompactedLargeFiles,
            ranOnMainThread: currentThreadIsMainForDiagnostics()
        )
    }

    /// Pure on-demand Tree transaction. A path can exist in several sort projections, while its
    /// parent row exists in the direct parent's projections only. Addressing those exact keys keeps
    /// work bounded by `TreeSortKey.allCases` instead of scanning every expanded directory cache.
    nonisolated private static func buildTreeCacheTransaction(
        retainedState: TreeCacheRetainedState,
        path: String,
        requestedSort: TreeSortKey,
        authority: TreeChildrenMeasurementAuthority,
        measuredParentState: TreeScanEvidenceProjection.ProjectedState?,
        incompleteIssues: [ScanIncompleteIssue]?,
        tombstones: PrunedPathMatcher,
        whitelist: Set<String> = [],
        locale: Locale,
        reconcileParent: Bool
    ) -> PreparedTreeCacheTransaction? {
        guard !Task.isCancelled else { return nil }
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let requestedKey = "\(normalizedPath)|\(requestedSort.rawValue)"

        var nextTreeEvidence = retainedState.treeEvidenceByRoot
        var preparedEvidence: PreparedIncompleteEvidenceProjection?
        if let incompleteIssues {
            let normalizedCandidates = incompleteIssues
                .map(normalizedIncompleteIssue)
                .sorted(by: incompleteIssueComesBefore)
            let replacement = ScanIncompleteEvidenceIndex(issues: normalizedCandidates)
            if tombstones.contains(normalizedPath) || replacement.isEmpty {
                nextTreeEvidence.removeValue(forKey: normalizedPath)
            } else {
                nextTreeEvidence[normalizedPath] = replacement
            }
            preparedEvidence = buildIncompleteEvidenceProjection(
                primaryEvidence: retainedState.primaryEvidence,
                treeEvidenceByRoot: nextTreeEvidence,
                previousIssues: retainedState.previousIssues,
                previousPermissionPaths: retainedState.previousPermissionPaths,
                previousTCCPaths: retainedState.previousTCCPaths,
                previousAllPaths: retainedState.previousAllPaths
            )
        }
        let evidenceProjection = preparedEvidence?.treeProjection
            ?? retainedState.previousTreeProjection

        var nextCache = retainedState.cache
        guard !tombstones.contains(normalizedPath),
              !isWhitelisted(normalizedPath, in: whitelist)
        else {
            for sortKey in TreeSortKey.allCases {
                nextCache.removeValue(forKey: "\(normalizedPath)|\(sortKey.rawValue)")
            }
            return PreparedTreeCacheTransaction(
                cache: nextCache,
                treeEvidenceByRoot: nextTreeEvidence,
                evidence: preparedEvidence,
                ranOnMainThread: Thread.isMainThread
            )
        }

        let visibleRows = retainedState.inputRows
            .filter {
                !tombstones.contains($0.path) && !isWhitelisted($0.path, in: whitelist)
            }
            .sorted { sortTreeRow($0, before: $1, by: requestedSort, locale: locale) }
        nextCache[requestedKey] = visibleRows

        // Existing derived projections remain live across sort switches. Refresh each of them from
        // the same authoritative measurement on this worker, never in a synchronous View getter.
        for sortKey in TreeSortKey.allCases where sortKey != requestedSort {
            guard !Task.isCancelled else { return nil }
            let key = "\(normalizedPath)|\(sortKey.rawValue)"
            nextCache[key] = visibleRows.sorted {
                sortTreeRow($0, before: $1, by: sortKey, locale: locale)
            }
        }

        guard reconcileParent else {
            return PreparedTreeCacheTransaction(
                cache: nextCache,
                treeEvidenceByRoot: nextTreeEvidence,
                evidence: preparedEvidence,
                ranOnMainThread: Thread.isMainThread
            )
        }

        let childBytes = visibleRows.reduce(Int64(0)) { $0 &+ $1.bytes }
        let childLogicalBytes = visibleRows.reduce(Int64(0)) { $0 &+ $1.logicalBytes }
        let childFileCount = visibleRows.reduce(0) { $0 &+ $1.fileCount }
        let parentCachePath = URL(fileURLWithPath: normalizedPath)
            .deletingLastPathComponent()
            .standardizedFileURL.path

        guard parentCachePath != normalizedPath else {
            return PreparedTreeCacheTransaction(
                cache: nextCache,
                treeEvidenceByRoot: nextTreeEvidence,
                evidence: preparedEvidence,
                ranOnMainThread: Thread.isMainThread
            )
        }

        for sortKey in TreeSortKey.allCases {
            guard !Task.isCancelled else { return nil }
            let cacheKey = "\(parentCachePath)|\(sortKey.rawValue)"
            guard var parentRows = nextCache[cacheKey],
                  let index = parentRows.firstIndex(where: { $0.path == normalizedPath })
            else { continue }
            let old = parentRows[index]
            let projectedState = evidenceProjection.projectedState(
                for: old.path,
                fallbackAccessState: measuredParentState?.accessState ?? old.accessState,
                fallbackSubtreeCompleteness: measuredParentState?.subtreeCompleteness
                    ?? old.subtreeCompleteness
            )

            let reconciledBytes: Int64
            let reconciledLogicalBytes: Int64
            let reconciledFileCount: Int
            let reconciledHasChildren: Bool
            let reconciledIsPending: Bool
            switch authority {
            case .complete:
                reconciledBytes = childBytes
                reconciledLogicalBytes = childLogicalBytes
                reconciledFileCount = childFileCount
                reconciledHasChildren = !visibleRows.isEmpty
                reconciledIsPending = false
            case .shallowIdentityComplete:
                reconciledBytes = max(old.bytes, childBytes)
                reconciledLogicalBytes = max(old.logicalBytes, childLogicalBytes)
                reconciledFileCount = max(old.fileCount, childFileCount)
                reconciledHasChildren = old.hasChildren || !visibleRows.isEmpty
                reconciledIsPending = true
            case .partialLowerBound:
                reconciledBytes = max(old.bytes, childBytes)
                reconciledLogicalBytes = max(old.logicalBytes, childLogicalBytes)
                reconciledFileCount = max(old.fileCount, childFileCount)
                reconciledHasChildren = old.hasChildren || !visibleRows.isEmpty
                reconciledIsPending = false
            }
            parentRows[index] = TreeRow(
                path: old.path,
                title: old.title,
                bytes: reconciledBytes,
                logicalBytes: reconciledLogicalBytes,
                fileCount: reconciledFileCount,
                isDirectory: old.isDirectory,
                hasChildren: reconciledHasChildren,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: old.modificationDate,
                isSizePending: reconciledIsPending,
                titlePresentation: old.titlePresentation
            )
            parentRows.sort {
                sortTreeRow($0, before: $1, by: sortKey, locale: locale)
            }
            nextCache[cacheKey] = parentRows
        }

        return PreparedTreeCacheTransaction(
            cache: nextCache,
            treeEvidenceByRoot: nextTreeEvidence,
            evidence: preparedEvidence,
            ranOnMainThread: Thread.isMainThread
        )
    }

    /// 子树测量对父行聚合的证据强度。`shallowIdentityComplete` 已经枚举完全部
    /// 直接子项，但目录子树容量仍是未知，因此父容量只能保留 lower bound；
    /// `partialLowerBound` 则连枚举证据都不完整。只有 BulkScanner 完整终态允许容量收缩。
    private enum TreeChildrenMeasurementAuthority: Sendable {
        case shallowIdentityComplete
        case partialLowerBound
        case complete

        var logValue: String {
            switch self {
            case .shallowIdentityComplete: return "shallow_identity_complete"
            case .partialLowerBound: return "partial_lower_bound"
            case .complete: return "complete"
            }
        }
    }

    private struct TreeChildrenMeasurement: Sendable {
        let rows: [TreeRow]
        let authority: TreeChildrenMeasurementAuthority
        let parentState: TreeScanEvidenceProjection.ProjectedState?
        let incompleteIssues: [ScanIncompleteIssue]

        static let cancelled = TreeChildrenMeasurement(
            rows: [],
            authority: .partialLowerBound,
            parentState: nil,
            incompleteIssues: []
        )
    }

    /// Raw terminal of the deep Tree filesystem producer. BulkScanner termination owns this
    /// boundary; TreeRow mapping and ordering happen only after the path lease has been released.
    private enum TreeChildrenProducerOutput: Sendable {
        case terminal(TreeChildrenMeasurement)
        case topLevel(
            entries: [ScanTopLevelEntry],
            issues: [ScanIncompleteIssue],
            terminalStatus: ScanCompletionStatus?,
            sawFailure: Bool
        )
    }

    /// TCC policy is expressed in the public namespace and must run before *any* physical
    /// `fileExists`, enumerator creation, or metadata request. Returning the same typed evidence
    /// used by BulkScanner keeps Tree lock rendering and deletion preflight in one contract.
    nonisolated private static func tccProtectedTreeMeasurement(
        publicRootPath: String
    ) -> TreeChildrenMeasurement? {
        guard TCCSkipList.shouldSkip(publicRootPath) else { return nil }
        let issue = ScanIncompleteIssue(
            path: publicRootPath,
            reason: .tccProtectedSkipped,
            stage: .open
        )
        let state = TreeScanEvidenceProjection(issues: [issue]).projectedState(for: publicRootPath)
        return TreeChildrenMeasurement(
            rows: [],
            authority: .partialLowerBound,
            parentState: state,
            incompleteIssues: [issue]
        )
    }

    nonisolated private static func scanDirectChildrenShallow(
        rootPath: String,
        accessProjection: TreeScanEvidenceProjection,
        pathNamespace: ScanPathNamespace? = nil,
        options: ScanOptions = .default,
        knownAllocationCatalog: AllocationCatalog? = nil
    ) -> TreeChildrenMeasurement {
        if let protected = tccProtectedTreeMeasurement(
            publicRootPath: rootPath
        ) {
            return protected
        }
        let physicalRootPath = pathNamespace?.physicalPath(forPublicPath: rootPath) ?? rootPath
        var isRootDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: physicalRootPath, isDirectory: &isRootDirectory),
              isRootDirectory.boolValue
        else {
            return TreeChildrenMeasurement(
                rows: [],
                authority: .shallowIdentityComplete,
                parentState: nil,
                incompleteIssues: []
            )
        }

        let root = URL(fileURLWithPath: physicalRootPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey
        ]
        // `contentsOfDirectory` 会先把超宽目录完整物化；父 Tree 任务即使取消，旧 listing
        // 仍会继续占用 IO/内存。DirectoryEnumerator 按 entry 拉取，并在每项检查取消，
        // 同时 `skipsSubdirectoryDescendants` 保持“只列直接子项”的产品合同。
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in !Task.isCancelled }
        ) else {
            return TreeChildrenMeasurement(
                rows: [],
                authority: .shallowIdentityComplete,
                parentState: nil,
                incompleteIssues: []
            )
        }

        let nonOwnerAliases = knownAllocationCatalog?.snapshot().nonOwnerAliasPaths(inDirectory: rootPath) ?? []
        var rows: [TreeRow] = []
        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return .cancelled }
            if !options.includeHidden && url.lastPathComponent.hasPrefix(".") {
                continue
            }
            let path = pathNamespace?.publicPath(forPhysicalPath: url.path) ?? url.path
            let values = try? url.resourceValues(forKeys: keys)
            let isSymlink = values?.isSymbolicLink ?? false
            let isDirectory = (values?.isDirectory ?? false) && !isSymlink
            let projectedState = accessProjection.projectedState(for: path)
            let accessState = projectedState.accessState

            let bytes: Int64
            let logicalBytes: Int64
            let fileCount: Int
            if isDirectory {
                bytes = 0
                logicalBytes = 0
                fileCount = 0
            } else if values?.isRegularFile == true && !isSymlink {
                if nonOwnerAliases.contains(path) {
                    bytes = 0
                    logicalBytes = 0
                } else {
                    let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
                    let logical = values?.totalFileSize ?? values?.fileSize
                    // 不得回退到 logical size：那会把 sparse 虚拟容量混入磁盘占用主值。
                    // 本地文件系统未提供 allocated 值时先展示 0；完整后台阶段仍由
                    // BulkScanner 的 `st_blocks` 结果覆盖，而不是用另一种语义伪造一个数。
                    bytes = Int64(max(0, allocated ?? 0))
                    logicalBytes = Int64(max(0, logical ?? 0))
                }
                fileCount = 1
            } else {
                bytes = 0
                logicalBytes = 0
                fileCount = 0
            }

            rows.append(TreeRow(
                path: path,
                title: url.lastPathComponent,
                bytes: bytes,
                logicalBytes: logicalBytes,
                fileCount: fileCount,
                isDirectory: isDirectory,
                hasChildren: isDirectory && accessState == .normal,
                accessState: accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: values?.contentModificationDate,
                isSizePending: isDirectory && accessState == .normal
            ))
        }

        return TreeChildrenMeasurement(
            rows: rows,
            authority: .shallowIdentityComplete,
            parentState: nil,
            incompleteIssues: []
        )
    }

    /// v2026.07.18 Tree P2 root-cause fix: explicit refresh consumes the complete node stream on
    /// a generic executor and rebuilds the descendant graph, not merely its visible first level.
    /// This keeps `childEdges`, directory aggregates and leaf identity from replaying the previous
    /// scan after the user has changed the filesystem.
    nonisolated private static func scanIndexedSubtreeOnDemand(
        rootPath: String,
        pathNamespace: ScanPathNamespace?,
        options: ScanOptions,
        knownAllocationCatalog: AllocationCatalog? = nil
    ) async -> IndexedSubtreeMeasurement? {
        let ranOnMainThread = currentThreadIsMainForDiagnostics()
        if let protected = tccProtectedTreeMeasurement(publicRootPath: rootPath) {
            return IndexedSubtreeMeasurement(
                rootPath: rootPath,
                dirIndex: [rootPath: DirAgg()],
                childEdges: [rootPath: []],
                fileLeaves: [:],
                incompleteIssues: protected.incompleteIssues,
                completionStatus: .partial,
                ranOnMainThread: ranOnMainThread
            )
        }

        let physicalRootPath = pathNamespace?.physicalPath(forPublicPath: rootPath) ?? rootPath
        var rootIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: physicalRootPath,
            isDirectory: &rootIsDirectory
        ), rootIsDirectory.boolValue else {
            let issue = ScanIncompleteIssue(
                path: rootPath,
                reason: .metadataUnavailable,
                stage: .metadata
            )
            return IndexedSubtreeMeasurement(
                rootPath: rootPath,
                dirIndex: [:],
                childEdges: [:],
                fileLeaves: [:],
                incompleteIssues: [issue],
                completionStatus: .partial,
                ranOnMainThread: ranOnMainThread
            )
        }

        let rootURL = URL(fileURLWithPath: physicalRootPath, isDirectory: true)
        let rootMtime = try? rootURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        var indexedDirectories: [String: DirAgg] = [
            rootPath: DirAgg(modificationDate: rootMtime)
        ]
        var indexedEdges: [String: Set<String>] = [rootPath: []]
        var indexedLeaves: [
            String: IndexedFileLeaf
        ] = [:]
        var issues = Set<ScanIncompleteIssue>()
        var terminalStatus: ScanCompletionStatus?
        var sawRootFailure = false

        let scanner = BulkScanner(options: options)
        let allocationLedger = InodeSet(tracksPaths: true, trackingPathsFor: knownAllocationCatalog?.snapshot() ?? .init())
        let scanSession = scanner.scanSession(
            root: rootURL,
            delivery: .complete,
            pathNamespace: pathNamespace,
            topLevelProjectionRootPath: nil,
            allocationLedger: allocationLedger
        )
        await withTaskCancellationHandler {
            for await event in scanSession.events {
                if Task.isCancelled { break }
                switch event {
                case .node(let node):
                    accumulateIndexedSubtreeNode(
                        node,
                        rootPath: rootPath,
                        dirIndex: &indexedDirectories,
                        childEdges: &indexedEdges,
                        fileLeaves: &indexedLeaves
                    )
                case .nodes(let nodes):
                    for node in nodes {
                        guard !Task.isCancelled else { break }
                        accumulateIndexedSubtreeNode(
                            node,
                            rootPath: rootPath,
                            dirIndex: &indexedDirectories,
                            childEdges: &indexedEdges,
                            fileLeaves: &indexedLeaves
                        )
                    }
                case .permissionDenied(let path):
                    issues.insert(ScanIncompleteIssue(path: path, reason: .permissionDenied))
                case .tccProtectedSkipped(let path):
                    issues.insert(ScanIncompleteIssue(path: path, reason: .tccProtectedSkipped))
                case .incomplete(let issue):
                    issues.insert(issue)
                case .failed:
                    sawRootFailure = true
                    issues.insert(ScanIncompleteIssue(
                        path: rootPath,
                        reason: .enumerationFailed,
                        stage: .enumerate
                    ))
                case .finished(let summary):
                    terminalStatus = summary.completionStatus
                    issues.formUnion(summary.incompleteIssues)
                case .heartbeat, .progress, .cacheDirTagged:
                    continue
                }
            }
        } onCancel: {
            scanSession.cancel()
        }
        await scanSession.waitForTermination()
        guard !Task.isCancelled else { return nil }

        if terminalStatus == nil {
            issues.insert(ScanIncompleteIssue(
                path: rootPath,
                reason: .enumerationFailed,
                stage: .enumerate
            ))
        }
        let completionStatus: ScanCompletionStatus =
            !sawRootFailure && terminalStatus == .complete && issues.isEmpty
                ? .complete
                : .partial
        return IndexedSubtreeMeasurement(
            rootPath: rootPath,
            dirIndex: indexedDirectories,
            childEdges: indexedEdges,
            fileLeaves: indexedLeaves,
            incompleteIssues: Array(issues),
            completionStatus: completionStatus,
            ranOnMainThread: ranOnMainThread,
            allocations: allocationLedger.allocationSnapshot()
        )
    }

    /// Serial accumulator for the complete subtree stream. Every mutation happens in the
    /// background consumer task; `MainActor` never sees one dictionary insert per inode.
    nonisolated private static func accumulateIndexedSubtreeNode(
        _ node: FSNode,
        rootPath: String,
        dirIndex: inout [String: DirAgg],
        childEdges: inout [String: Set<String>],
        fileLeaves: inout [String: IndexedFileLeaf]
    ) {
        let nodePath = node.path
        guard pathBelongsToSubtree(nodePath, rootPath: rootPath),
              nodePath != rootPath else { return }
        let parentPath = String._gsyParentPath(of: nodePath)
        guard pathBelongsToSubtree(parentPath, rootPath: rootPath) else { return }
        childEdges[parentPath, default: []].insert(nodePath)

        if node.isDirectory {
            var aggregate = dirIndex[nodePath] ?? DirAgg()
            if let modificationDate = node.modificationDate {
                aggregate.modificationDate = modificationDate
            }
            dirIndex[nodePath] = aggregate
            // An explicit empty set is authoritative for a completely scanned empty directory.
            if childEdges[nodePath] == nil {
                childEdges[nodePath] = []
            }
            return
        }

        fileLeaves[nodePath] = IndexedFileLeaf(
            bytes: node.allocatedSize,
            logicalBytes: node.logicalSize,
            isDir: false,
            modificationDate: node.modificationDate,
            isRegularFile: node.isRegularFile
        )
        var cursor = parentPath
        while pathBelongsToSubtree(cursor, rootPath: rootPath) {
            var aggregate = dirIndex[cursor] ?? DirAgg()
            aggregate.bytes &+= node.allocatedSize
            aggregate.logicalBytes &+= node.logicalSize
            aggregate.fileCount &+= node.isRegularFile ? 1 : 0
            dirIndex[cursor] = aggregate
            if cursor == rootPath { break }
            let next = String._gsyParentPath(of: cursor)
            guard next != cursor else { break }
            cursor = next
        }
    }

    nonisolated private static func scanDirectChildrenProducer(
        rootPath: String,
        pathNamespace: ScanPathNamespace? = nil,
        options: ScanOptions = .default,
        knownAllocationCatalog: AllocationCatalog? = nil
    ) async -> TreeChildrenProducerOutput {
        if let protected = tccProtectedTreeMeasurement(
            publicRootPath: rootPath
        ) {
            return .terminal(protected)
        }
        let physicalRootPath = pathNamespace?.physicalPath(forPublicPath: rootPath) ?? rootPath
        guard FileManager.default.fileExists(atPath: physicalRootPath) else {
            let issue = ScanIncompleteIssue(
                path: rootPath,
                reason: .metadataUnavailable,
                stage: .metadata
            )
            return .terminal(TreeChildrenMeasurement(
                rows: [],
                authority: .partialLowerBound,
                parentState: TreeScanEvidenceProjection.ProjectedState(
                    accessState: .incomplete,
                    subtreeCompleteness: .complete
                ),
                incompleteIssues: [issue]
            ))
        }

        let root = URL(fileURLWithPath: physicalRootPath, isDirectory: true)
        let scanner = BulkScanner(options: options)
        let knownSnapshot = knownAllocationCatalog?.snapshot()
        let allocationLedger = InodeSet(
            tracksPaths: knownSnapshot != nil,
            trackingPathsFor: knownSnapshot ?? .init()
        )

        var entries: [ScanTopLevelEntry] = []
        var localIssues = Set<ScanIncompleteIssue>()
        var terminalStatus: ScanCompletionStatus?
        var sawFailure = false
        let scanSession = scanner.scanSession(
            root: root,
            delivery: .topLevel,
            pathNamespace: pathNamespace,
            topLevelProjectionRootPath: rootPath,
            allocationLedger: allocationLedger
        )
        await withTaskCancellationHandler {
            for await event in scanSession.events {
                if Task.isCancelled { break }
                switch event {
                case .heartbeat:
                    continue
                case .permissionDenied(let path):
                    localIssues.insert(ScanIncompleteIssue(path: path, reason: .permissionDenied))
                case .tccProtectedSkipped(let path):
                    localIssues.insert(ScanIncompleteIssue(path: path, reason: .tccProtectedSkipped))
                case .incomplete(let issue):
                    localIssues.insert(issue)
                case .finished(let summary):
                    terminalStatus = summary.completionStatus
                    localIssues.formUnion(summary.incompleteIssues)
                    if case .topLevel(let projectedEntries) = summary.projection {
                        entries = projectedEntries
                    }
                case .node, .nodes:
                    // `.topLevel` 的硬合同：不得把完整节点流送到按需 Tree 聚合任务。
                    assertionFailure("topLevel delivery emitted an incremental node")
                case .failed:
                    sawFailure = true
                    localIssues.insert(ScanIncompleteIssue(
                        path: rootPath,
                        reason: .enumerationFailed,
                        stage: .enumerate
                    ))
                case .progress, .cacheDirTagged:
                    continue
                }
            }
        } onCancel: {
            scanSession.cancel()
        }
        await scanSession.waitForTermination()
        guard !Task.isCancelled else { return .terminal(.cancelled) }
        if let knownSnapshot, !entries.isEmpty {
            let replacement = knownSnapshot.replacing(
                with: allocationLedger.allocationSnapshot(),
                replacesPath: { _ in false }
            )
            if !replacement.incomingDeltas.isEmpty {
                var deltasByBucket: [String: (allocated: Int64, logical: Int64)] = [:]
                for delta in replacement.incomingDeltas {
                    let bucketPath = bucketProjection(
                        nodePath: delta.path,
                        rootPath: rootPath
                    )?.bucketPath ?? (String._gsyParentPath(of: delta.path) == rootPath ? delta.path : nil)
                    guard let bucketPath else { continue }
                    let old = deltasByBucket[bucketPath] ?? (0, 0)
                    deltasByBucket[bucketPath] = (
                        old.allocated + delta.allocatedBytes,
                        old.logical + delta.logicalBytes
                    )
                }
                if !deltasByBucket.isEmpty {
                    entries = entries.map { entry in
                        guard let delta = deltasByBucket[entry.path] else { return entry }
                        return ScanTopLevelEntry(
                            path: entry.path,
                            allocatedBytes: max(0, entry.allocatedBytes + delta.allocated),
                            logicalBytes: max(0, entry.logicalBytes + delta.logical),
                            fileCount: entry.fileCount,
                            isDirectory: entry.isDirectory,
                            hasChildren: entry.hasChildren,
                            modificationDate: entry.modificationDate
                        )
                    }
                }
            }
        }
        return .topLevel(
            entries: entries,
            issues: Array(localIssues),
            terminalStatus: terminalStatus,
            sawFailure: sawFailure
        )
    }

    /// Pure presentation projection for a completed deep producer. This function performs no
    /// filesystem access and must stay outside TreeFilesystemLeaseDomain.
    nonisolated private static func projectDirectChildrenProducerOutput(
        _ output: TreeChildrenProducerOutput,
        rootPath: String,
        accessProjection: TreeScanEvidenceProjection
    ) -> TreeChildrenMeasurement {
        switch output {
        case .terminal(let measurement):
            return measurement
        case .topLevel(let entries, let producerIssues, let terminalStatus, let sawFailure):
            var localIssues = Set(producerIssues)
            // 闭流但没收到 finished 也不是完整证据。给根行一个 typed incomplete 投影，
            // 防止“空数组”被误解为“目录已清空”而把旧容量直接归零。
            if terminalStatus == nil {
                localIssues.insert(ScanIncompleteIssue(
                    path: rootPath,
                    reason: .enumerationFailed,
                    stage: .enumerate
                ))
            }

            let localProjection = TreeScanEvidenceProjection(issues: Array(localIssues))
            let localParentState = localProjection.projectedState(for: rootPath)
            let parentState = accessProjection.projectedState(
                for: rootPath,
                fallbackAccessState: localParentState.accessState,
                fallbackSubtreeCompleteness: localParentState.subtreeCompleteness
            )
            var rows: [TreeRow] = []
            rows.reserveCapacity(entries.count)
            for entry in entries {
                guard !Task.isCancelled else { return .cancelled }
                let localState = localProjection.projectedState(for: entry.path)
                let projectedState = accessProjection.projectedState(
                    for: entry.path,
                    fallbackAccessState: localState.accessState,
                    fallbackSubtreeCompleteness: localState.subtreeCompleteness
                )
                rows.append(TreeRow(
                    path: entry.path,
                    title: (entry.path as NSString).lastPathComponent,
                    bytes: entry.allocatedBytes,
                    logicalBytes: entry.logicalBytes,
                    fileCount: entry.fileCount,
                    isDirectory: entry.isDirectory,
                    hasChildren: entry.isDirectory && entry.hasChildren,
                    accessState: projectedState.accessState,
                    subtreeCompleteness: projectedState.subtreeCompleteness,
                    modificationDate: entry.modificationDate
                ))
            }
            let authority: TreeChildrenMeasurementAuthority =
                !sawFailure && terminalStatus == .complete && localIssues.isEmpty
                    ? .complete
                    : .partialLowerBound
            return TreeChildrenMeasurement(
                rows: rows,
                authority: authority,
                parentState: parentState,
                incompleteIssues: localIssues.sorted(by: incompleteIssueComesBefore)
            )
        }
    }

    /// Test/convenience wrapper. Production disclosure calls the producer and projector as two
    /// explicit stages so primary admission never waits for presentation mapping or sorting.
    nonisolated private static func scanDirectChildrenOnDemand(
        rootPath: String,
        sortedBy key: TreeSortKey,
        accessProjection: TreeScanEvidenceProjection,
        pathNamespace: ScanPathNamespace? = nil,
        options: ScanOptions = .default,
        knownAllocationCatalog: AllocationCatalog? = nil
    ) async -> TreeChildrenMeasurement {
        let output = await scanDirectChildrenProducer(
            rootPath: rootPath,
            pathNamespace: pathNamespace,
            options: options,
            knownAllocationCatalog: knownAllocationCatalog
        )
        let projected = projectDirectChildrenProducerOutput(
            output,
            rootPath: rootPath,
            accessProjection: accessProjection
        )
        return TreeChildrenMeasurement(
            rows: projected.rows.sorted { sortTreeRow($0, before: $1, by: key) },
            authority: projected.authority,
            parentState: projected.parentState,
            incompleteIssues: projected.incompleteIssues
        )
    }

    /// 异步 directChildren —— deepIndex 关闭时，后台扫描当前目录并聚合直接子项。
    ///
    /// 这条路径替代旧扫描数据库 fallback：
    /// - 不写全量节点数据库，不产生扫描收尾落盘等待；
    /// - 不在主线程遍历文件系统；
    /// - 只在用户真正展开某个目录时扫描该目录子树，结果写入 `treeChildrenCache`。
    public func directChildrenAsync(of path: String, sortedBy key: TreeSortKey) async -> [TreeRow] {
        if let kids = childEdges[path] {
            if let cached = cachedTreeChildren(path: path, sortedBy: key) {
                return cached
            }
            if !hasInFlightTreeChildren(path: path) {
                startMemoryTreeProjection(path: path, kids: kids, sortedBy: key)
            }
            let prefix = "\(path)|"
            let inFlight = treeChildrenTasks.first(where: { $0.key.hasPrefix(prefix) })?.value.task
            await inFlight?.value
            return cachedTreeChildren(path: path, sortedBy: key) ?? []
        }
        let accessProjection = treeScanEvidenceProjection
        let pathNamespace = treeScanPathNamespace
        let scanOptions = retainedScanOptions
        let knownAllocationCatalog = allocationCatalog
        let physicalPath = pathNamespace?.physicalPath(forPublicPath: path) ?? path
        let identity = TreeFilesystemMeasurementIdentity(
            publicPath: path,
            physicalPath: physicalPath
        )
        let generation = treeFetchGeneration
        let intentID = UUID()
        directTreeAsyncFilesystemOwners[intentID] = identity

        // This public async entry is a real producer too. Running it outside the lease registry
        // left a hidden overlap path even after View-triggered disclosure was fixed.
        let lease = await treeFilesystemLeaseDomain.run(
            identity: identity,
            stage: .deep,
            intentID: intentID
        ) {
            guard await Self.treeChildrenFetchGate.acquire() else {
                return TreeChildrenProducerOutput.terminal(.cancelled)
            }
            let producerOutput: TreeChildrenProducerOutput
            if Task.isCancelled {
                producerOutput = .terminal(.cancelled)
            } else {
                producerOutput = await Self.scanDirectChildrenProducer(
                    rootPath: path,
                    pathNamespace: pathNamespace,
                    options: scanOptions,
                    knownAllocationCatalog: knownAllocationCatalog
                )
            }
            await Self.treeChildrenFetchGate.release()
            return producerOutput
        }
        // v2026.07.19 regression guard: this owner represents filesystem access only. Projection
        // remains cancellable/stale-rejected, but it must never extend a primary admission barrier.
        directTreeAsyncFilesystemOwners.removeValue(forKey: intentID)
        guard case .produced(let producerOutput) = lease,
              !Task.isCancelled,
              generation == treeFetchGeneration
        else { return [] }
        let whitelist = whitelistSnapshot
        let tombstones = deletedPathTombstones.matcher
        let projectionTask = Task.detached(priority: .userInitiated) {
            let projected = Self.projectDirectChildrenProducerOutput(
                producerOutput,
                rootPath: path,
                accessProjection: accessProjection
            )
            return TreeChildrenMeasurement(
                rows: projected.rows
                    .filter { !tombstones.contains($0.path) && !Self.isWhitelisted($0.path, in: whitelist) }
                    .sorted {
                        Self.sortTreeRow($0, before: $1, by: key)
                    },
                authority: projected.authority,
                parentState: projected.parentState,
                incompleteIssues: projected.incompleteIssues
            )
        }
        let measurement = await withTaskCancellationHandler {
            await projectionTask.value
        } onCancel: {
            projectionTask.cancel()
        }
        guard !Task.isCancelled,
              generation == treeFetchGeneration
        else { return [] }
        replaceTreeIncompleteEvidence(rootPath: path, with: measurement.incompleteIssues)
        return measurement.rows
    }

    /// v1.3 bug1：根据 path O(1) 反查 TreeRow。
    /// 用于 TreeBrowserView 选中变化的 onSelect 回调——之前每点一次都要把整棵展开树
    /// 拍平递归一遍 (`visibleRows`)，4w 级展开节点下卡顿明显。这里用 dirIndex / fileLeaves
    /// 字典直接定位，避免遍历。
    public func row(for path: String) -> TreeRow? {
        if let agg = dirIndex[path] {
            // Selection must use the same cache-only contract as Tree materialization. A miss is
            // coalesced into the shared bounded producer; the children-cache revision refreshes
            // the Tree/detail projection after the background result commits.
            let cachedMtime = cachedDirMtimeFallback(forPath: path)
            if agg.modificationDate == nil, mtimeFallbackCache[path] == nil {
                enqueueMtimeFallbackProbes(CollectionOfOne(path))
            }
            let mtime = agg.modificationDate ?? cachedMtime
            let projectedState = projectedTreeState(for: path)
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: agg.bytes,
                logicalBytes: agg.logicalBytes,
                fileCount: agg.fileCount,
                isDirectory: true,
                hasChildren: !(childEdges[path]?.isEmpty ?? true),
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: mtime
            )
        }
        if let leaf = fileLeaves[path] {
            let projectedState = projectedTreeState(for: path)
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: leaf.bytes,
                logicalBytes: leaf.logicalBytes,
                fileCount: leaf.fileCount,
                isDirectory: leaf.isDir,
                hasChildren: false,
                accessState: projectedState.accessState,
                subtreeCompleteness: projectedState.subtreeCompleteness,
                modificationDate: leaf.modificationDate
            )
        }
        return nil
    }

    /// Post-prune refresh for MainView's value-type Tree selection. Indexed rows stay O(1); lazy
    /// deep-index-off rows use direct-parent cache keys, and top-level snapshot rows are rebuilt
    /// from the just-committed aggregate. This path runs once per successful delete, not per frame.
    public func refreshedTreeRow(for path: String) -> TreeRow? {
        if let indexed = row(for: path) { return indexed }

        let parentPath = String._gsyParentPath(of: path)
        for sortKey in TreeSortKey.allCases {
            let cacheKey = "\(parentPath)|\(sortKey.rawValue)"
            if let cached = treeChildrenCache[cacheKey]?.first(where: { $0.path == path }) {
                return cached
            }
        }

        for sortKey in TreeSortKey.allCases {
            if let perRoot = perRootTreeRowsBySort[sortKey]?.first(where: { $0.path == path }) {
                return perRoot
            }
            if let topRow = snapshotTreeRowsBySort[sortKey]?.first(where: { $0.path == path }) {
                return topRow
            }
        }

        guard let item = snapshot.rows.first(where: { $0.id == path }) else { return nil }
        let projectedState = projectedTreeState(for: path)
        return TreeRow(
            path: path,
            title: item.title,
            bytes: item.bytes,
            logicalBytes: item.logicalBytes,
            fileCount: item.fileCount,
            isDirectory: item.isDirectory,
            hasChildren: item.hasChildren,
            accessState: projectedState.accessState,
            subtreeCompleteness: projectedState.subtreeCompleteness,
            modificationDate: item.modificationDate,
            titlePresentation: item.titlePresentation
        )
    }

    /// 删除 UI 的唯一预检入口。Tree / Large Files 等页面必须通过当前扫描会话持有的
    /// engine + vendor trie + home 评估，不能再各自 new 一个裸 SafetyEngine；否则 UI
    /// 可能显示可删，而 TrashPipeline 最终按完整 vendor 规则拒绝。
    public func deletionSafetyEvaluation(
        for path: String
    ) -> (verdict: SafetyVerdict, rejection: SafetyRejection, vendor: VendorRule?) {
        let result = engine.evaluate(path: path, trie: trie, home: home)
        return (result.0, result.1, result.2)
    }

    // MARK: - T4 大文件 API

    /// v1.0 T4：取扫描期收集到的大文件，按视图阈值二次过滤、按 sortKey 排序、截到 limit 项。
    ///
    /// - Parameters:
    ///   - minSizeMB: 视图层阈值（MB）。**必须 ≥ 扫描期阈值**，否则视图能给出的就只是
    ///     当前已采集到的子集——这种情况下 UI 应当提示用户重新扫描（见 LargeFilesView）。
    ///   - sortKey: 排序键。
    ///   - limit: Top N 截断；ROADMAP T4 默认 200，避免一次性渲染数千行卡 UI。
    ///   - mtimeFilter: v1.2 P1-4 修改日期过滤。`.all` 时不做时间过滤。
    public func largeFiles(minSizeMB: Int,
                           sortKey: LargeFileSortKey,
                           limit: Int = 200,
                           mtimeFilter: AppSettings.MtimeFilter = .all)
        -> [LargeFileItem]
    {
        guard limit > 0 else { return [] }
        let minBytes = Int64(max(0, minSizeMB)) * 1024 * 1024
        let now = Date()
        // 主索引已被 compact 释放时回退到二级缓存（内存保留的 Top N）。
        // 既保证 UI 同步路径不变，又不让 compact 后页面空白。
        let source: [LargeFileLeaf]
        if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
            // compactedLargeFileTopN 是一个有限子集。自动 compact 已在 LargeFilesView 侧禁用，
            // 但测试/手动调用 compact 后仍应保持 list/count 一致。
            source = cache
        } else {
            source = largeFileLeaves.snapshot()
        }
        let tombstones = deletedPathTombstones.matcher
        let whitelist = whitelistSnapshot
        let filtered = source
            .filter { !tombstones.contains($0.path) && !Self.isWhitelisted($0.path, in: whitelist) }
            .filter { $0.bytes >= minBytes }
            .filter { mtimeFilter.passes($0.modificationDate, now: now) }
            .map {
                LargeFileItem(
                    path: $0.path,
                    bytes: $0.bytes,
                    logicalBytes: $0.logicalBytes,
                    modificationDate: $0.modificationDate
                )
            }
        let sorted = filtered.sorted { (a, b) in
            switch sortKey {
            case .sizeDesc:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .sizeAsc:
                if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .mtimeDesc:
                let ad = a.modificationDate ?? .distantPast
                let bd = b.modificationDate ?? .distantPast
                if ad != bd { return ad > bd }
            case .mtimeAsc:
                let ad = a.modificationDate ?? .distantFuture
                let bd = b.modificationDate ?? .distantFuture
                if ad != bd { return ad < bd }
            }
            // 主键相等 → path 升序兜底，保 ForEach 不抖
            return a.path < b.path
        }
        return Array(sorted.prefix(limit))
    }

    /// v1.0 T4：当前扫描会话采集到的"原始大文件叶子总数"——视图想提示
    /// "还有 X 项被截断"或者"未达到任何阈值"时用。
    /// M3：compact 之后回退到二级缓存的 count，UI 拿到的"集合大小"语义不变。
    public var largeFileCollectedCount: Int {
        let tombstones = deletedPathTombstones.matcher
        let whitelist = whitelistSnapshot
        guard !tombstones.roots.isEmpty || !whitelist.isEmpty else {
            if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
                return cache.count
            }
            return largeFileLeaves.count
        }
        if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
            return cache.lazy.filter {
                !tombstones.contains($0.path) && !Self.isWhitelisted($0.path, in: whitelist)
            }.count
        }
        return largeFileLeaves.snapshot().lazy.filter {
            !tombstones.contains($0.path) && !Self.isWhitelisted($0.path, in: whitelist)
        }.count
    }

    /// v1.0 T4：当前会话扫描期阈值（bytes）。视图据此判断是否需要"调阈值后重扫"。
    public var largeFileScanThresholdBytes: Int64 { largeFileMinBytes }

    private func sampleScanRate(nowDate: Date = Date()) -> TimeInterval {
        let sampleStart = lastSampleAt ?? startedAt
        let dt = nowDate.timeIntervalSince(sampleStart)
        let dBytes = totalBytes - lastSampleBytes
        if dt >= 0.05, dBytes >= 0 {
            let instant = Double(dBytes) / max(dt, 0.001)
            if bytesPerSecondEMA == 0 {
                bytesPerSecondEMA = instant
            } else {
                let alpha = 0.3
                bytesPerSecondEMA = alpha * instant + (1 - alpha) * bytesPerSecondEMA
            }
            lastSampleAt = nowDate
            lastSampleBytes = totalBytes
        }
        return nowDate.timeIntervalSince(startedAt)
    }

    /// Production projection scans have no authoritative rows until terminal preparation. Publish
    /// only their small live counters here: no `ScanCoordinator.objectWillChange`, no Tree tick,
    /// and therefore no NavigationSplitView/sidebar invalidation on the 0.4-second cadence.
    private func publishLiveProgress(categoryID: String) {
        let elapsed = sampleScanRate()
        liveProgress.updateTotals(
            categoryID: categoryID,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            elapsed: elapsed,
            bytesPerSecond: bytesPerSecondEMA
        )
    }

    private func publishSnapshot(
        categoryID: String,
        finished: Bool,
        complete: Bool? = nil,
        commitEvidence: Bool = true
    ) {
        // 完整性事件与扫描数据使用同一个既有 UI throttle：先把本批 typed evidence
        // 原子提交，再发布对应 ScanSnapshot。这样不会每条 issue 重绘，也不会出现
        // snapshot 已显示本批容量、删除预检却仍看不到本批拒绝证据的状态撕裂。
        if commitEvidence {
            commitIncompleteEvidenceProjectionsIfNeeded()
        }
        let isComplete = complete ?? finished
        if largeFileTopNOnlyScan {
            let elapsedTotal = sampleScanRate()
            let nextSnapshot = ScanSnapshot(
                categoryID: categoryID,
                rows: [],
                totalBytes: totalBytes,
                scannedFileCount: scannedFiles,
                isFinished: finished,
                elapsed: elapsedTotal,
                isComplete: isComplete,
                bytesPerSecond: bytesPerSecondEMA,
                estimatedRemaining: nil
            )
            if !finished && snapshot == nextSnapshot { return }
            snapshot = nextSnapshot
            if finished {
                lastFinishedCategoryID = categoryID
                lastIngestAt.removeAll(keepingCapacity: true)
                lastStreamSortedIds.removeAll(keepingCapacity: true)
                lastStreamSortCacheKey = (-1, -1)
            }
            return
        }

        // v1.3 修「只有一行在动」错觉：
        //   扫描期间按 path 字典序排（位置稳定），让用户看到所有一级子目录的字节
        //   各自独立、同时跳动；只有 finished=true 那一帧切到用户选定的 mainListSortKey
        //   （默认 sizeDesc），呈现最终结果。
        //
        // 背景：之前一直按 bytes 降序排，结果"最大的 bucket"永远固定在第一行，且
        //   它的字节增长得最快——视觉上就是"列表只有第一行数字在变"，给用户造成
        //   "多线程没生效，只在扫一个目录"的错觉。实际上 6 worker 真的在扫 6 个
        //   不同子目录，所有 bucket 都在涨。
        //
        // v1.3：每个 row 携带 isActive 标志（最近 activityWindow 内有 ingest 写入即 active），
        //   UI 给 active 行的 bytes 数字上色 + 脉动，让"哪些 worker 正在扫"视觉化。
        //   finished=true 那帧强制 isActive=false（扫完就不该再亮）。
        //
        // 副作用：扫描期间行序按 path 字典序而非 size 降序——这是必要的代价，
        //   且与许多竞品（CleanMyMac 实时扫描态）一致。完成后立刻切回用户排序。
        let now = Date.timeIntervalSinceReferenceDate
        let activeCutoff = now - activityWindow

        // 先 map 出无序 rows，再统一排序——避免在 sort 闭包里反复算 evaluate
        // 性能：走 trie 版 evaluate（init 期一次性 build，扫描期复用），
        // 比 evaluate(path:vendors:home:) 每次重建 trie 快一个量级。
        //
        // Step 3 P0-3 / 2026-06：bucket cachedVerdict 缓存。
        // path/engine/trie/home 在扫描期间均不变 —— 同 path 的 evaluate 结果永远相同。
        // 第一帧把每个 bucket 的 verdict/rejection/vendor 算一次写回 bucket struct，
        // 后续帧（流式 0.4s 一次）直接读字段。一次扫描 N=数百~数千 bucket × 数十帧
        // 的重复 evaluate 收敛到"每 bucket 只算一次"。
        var unsorted: [RowItem] = []
        unsorted.reserveCapacity(buckets.count)
        for path in buckets.keys {
            // 通过 buckets[path] 路径 read-modify-write —— Bucket 是 value type，
            // 必须从 dict 重新写回才能保留 cache 字段。
            guard var bucket = buckets[path] else { continue }
            let verdict: SafetyVerdict
            let rejection: SafetyRejection
            let vendor: VendorRule?
            if let v = bucket.cachedVerdict, let r = bucket.cachedRejection {
                // hit：path/engine/trie/home 都没变，verdict 永远相同 —— 直接读
                verdict = v
                rejection = r
                vendor = bucket.cachedVendor
                verdictCacheHits &+= 1
            } else {
                // miss：算一次并写回 bucket
                let result = engine.evaluate(path: path, trie: trie, home: home)
                verdict = result.0
                rejection = result.1
                vendor = result.2
                bucket.cachedVerdict = verdict
                bucket.cachedRejection = rejection
                bucket.cachedVendor = vendor
                buckets[path] = bucket
                verdictCacheMisses &+= 1
            }

            let active: Bool
            if finished {
                active = false
            } else if let ts = lastIngestAt[path] {
                active = ts >= activeCutoff
            } else {
                active = false
            }
            unsorted.append(RowItem(
                id: path,
                url: bucket.url,
                title: bucket.url.lastPathComponent,
                isDirectory: bucket.isDirectory,
                bytes: bucket.bytes,
                logicalBytes: bucket.logicalBytes,
                fileCount: bucket.fileCount,
                verdict: verdict,
                rejection: rejection,
                vendorName: vendor?.name,
                vendorNote: vendor?.note,
                runningBundleIDPrefix: vendor?.bundleIDPrefix,
                isActive: active,
                hasChildren: bucket.hasChildren,
                modificationDate: bucket.modificationDate
            ))
        }
        let rows: [RowItem]
        // M4-T1：白名单过滤——命中规则与 WhitelistStore.isWhitelisted 等价（同步快照版）。
        let filtered: [RowItem]
        if whitelistSnapshot.isEmpty {
            filtered = unsorted
        } else {
            filtered = unsorted.filter {
                !Self.isWhitelisted($0.url.path, in: whitelistSnapshot)
            }
        }
        if finished {
            rows = filtered.sorted(by: {
                mainListSortKey.lessThan($0, $1, locale: presentationLocale)
            })
            // 流式 cache 不用于 finished，但避免下次扫描首帧误命中——失效掉
            lastStreamSortedIds.removeAll(keepingCapacity: true)
            lastStreamSortCacheKey = (-1, -1)
        } else {
            // v1.5 P1-C：流式帧排序缓存。
            // 命中条件：bucketCount 与上次相同（ingest 单调增 → 相同即 key set 完全相同）
            // 且 whitelistCount 与上次相同（避免白名单变化产生不同的 filtered 序列影响）。
            // 命中时直接按上次的 id 序重排 filtered，跳过 O(N log N) 排序。
            let currentKey = (bucketCount: buckets.count, whitelistCount: whitelistSnapshot.count)
            let cacheHit = currentKey.bucketCount > 0
                && currentKey.bucketCount == lastStreamSortCacheKey.bucketCount
                && currentKey.whitelistCount == lastStreamSortCacheKey.whitelistCount
                && lastStreamSortedIds.count == filtered.count
            if cacheHit {
                // 按缓存 id 序重组 filtered（一次哈希构表 + 一次顺序拼装，O(N) 替代 O(N log N)）。
                var byID: [String: RowItem] = [:]
                byID.reserveCapacity(filtered.count)
                for r in filtered { byID[r.id] = r }
                var reordered: [RowItem] = []
                reordered.reserveCapacity(filtered.count)
                for id in lastStreamSortedIds {
                    if let r = byID[id] { reordered.append(r) }
                }
                // 兜底：若映射出现不一致（理论上不应该发生），fallback 走真排序
                if reordered.count == filtered.count {
                    rows = reordered
                } else {
                    rows = filtered.sorted { $0.id < $1.id }
                    lastStreamSortedIds = rows.map { $0.id }
                    lastStreamSortCacheKey = currentKey
                }
            } else {
                rows = filtered.sorted { $0.id < $1.id }
                lastStreamSortedIds = rows.map { $0.id }
                lastStreamSortCacheKey = currentKey
            }
        }

        // v1.3：ETA 采样 —— 在每帧 publishSnapshot 时基于自上次采样的字节增量算瞬时速率，
        // 再 EWMA 平滑（α=0.3）。注意 elapsed 起点是 startedAt，速率窗口起点是 lastSampleAt
        // （第一帧没有"上次"，初始化成 startedAt 让首个采样长度 = elapsed）。
        let nowDate = Date()
        let elapsedTotal = sampleScanRate(nowDate: nowDate)

        // v2026.06.23 产品决策：不再向 UI 下发 ETA（剩余时间）。
        // 长扫场景下速率窗口噪声 + estimator 偏小都会让 ETA 严重失真，呈现给用户反而误导。
        // 上游 UI / HUD 已停止读取 estimatedRemaining；这里把字段恒置 nil，作为单一数据源闸门，
        // 杜绝未来某条入口"偷偷"把 ETA 再加回来。`expectedTotalBytes` 仍然继续算并下发，
        // 给"有分母时显示进度条 + 百分比"用——这是用户唯一信得过的进度表达。
        let eta: TimeInterval? = nil

        let nextSnapshot = ScanSnapshot(
            categoryID: categoryID,
            rows: rows,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            isFinished: finished,
            elapsed: elapsedTotal,
            isComplete: isComplete,
            bytesPerSecond: bytesPerSecondEMA,
            estimatedRemaining: finished ? nil : eta
        )
        // v2026.06.21 perf：Equatable 短路。
        // 用户对比反馈"开发者构建产物比 Library 卡得夸张"——根因之一是 @Published
        // 不会自动比较，每帧重复赋同样内容仍会 send objectWillChange，把 MainView.body
        // 整体失效，连带 sidebar / statusBar / listResults 全跑 O(N)。
        // ScanSnapshot 现在 Equatable（rows / 三桶字节 / max / bytesPerSecond / eta 全字段
        // 参与对比），等价帧直接 return 不写 @Published；典型 dev 扫场景"两根并行 throttle
        // 错峰共振导致空帧 publish"会被这里挡下，body 失效频率从 ≥5次/秒 降到内容真有变化
        // 才触发。等价比较的代价是 N 行 RowItem.== 浅比，远低于 SwiftUI body 重新跑一次。
        //
        // 注意：finished 帧不能短路——下游 lastFinishedCategoryID / lastIngestAt 清理
        // 与 (buckets/dirIndex/fileLeaves) 索引快照对齐都依赖这里跑完。
        if !finished && snapshot == nextSnapshot { return }
        snapshot = nextSnapshot
        if finished {
            lastFinishedCategoryID = categoryID
            // 扫完清空 lastIngestAt，避免下一次切排序键 / 重扫前的 stale 数据让旧 row 误亮
            lastIngestAt.removeAll(keepingCapacity: true)
        }
        // Step 2 P0-2 / 2026-06：treeRevision 拆分。
        // 流式扫描 publishSnapshot 帧（0.4s/帧）以前一律 `treeRevision &+= 1` —— 这会让
        // TreeBrowserView 把上万节点的 flatRows 整树重建一遍。但 95% 的帧只是已有节点
        // 的 bytes/fileCount 累加（节点拓扑没变），整树重建纯属浪费。
        //
        // 这里用三元组 `(buckets.count, dirIndex.count, fileLeaves.count)` 做 O(1) 判定：
        //   - 任一计数变化 → 必然有新节点首次出现 → 升格为 structural
        //   - 三元组全等 → 仅数值变化 → 只推 tickRevision，flatRows 不重建
        //
        // 漏判风险：dirIndex 内 children 集合微调（同一 parent 下子项排序变）不会让 count 变。
        // 但这种排序级变化在我们的 ingest 路径里**不会发生**（每次 insert 只 add/不 remove），
        // 所以三元组对索引集合的"严格单调增"语义足够安全。
        let snapshot = (
            buckets: buckets.count,
            dirIndex: dirIndex.count,
            fileLeaves: fileLeaves.count
        )
        if snapshot != lastIndexSnapshot {
            lastIndexSnapshot = snapshot
            bumpStructuralRevision()
        } else {
            bumpTickRevision()
        }
    }

    // MARK: - Testing helpers (Step 15)

    /// 仅供 [PruneDeletedTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/PruneDeletedTests.swift)
    /// / [PerformDeleteIntegrationTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/PerformDeleteIntegrationTests.swift)
    /// 注入内部状态。
    ///
    /// 同 [forcePublishSnapshotForTesting](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L389)
    /// 风格：`internal` 可见性，配合 `@testable import AppUI` 在测试 target 内可用，
    /// 生产路径不会调到。
    ///
    /// 全部参数都 optional，默认 nil = 不动该字段。Bucket/DirAgg 是 private struct，
    /// 这里以"简化字典"接收（path -> bytes 即可）由方法内部包装成真实结构。
    func _seedForTesting(
        snapshot: ScanSnapshot? = nil,
        currentRootPath: String? = nil,
        isScanning: Bool? = nil,
        buckets: [String: Int64]? = nil,
        dirIndex: [String]? = nil,
        dirIndexFull: [String: (bytes: Int64, fileCount: Int)]? = nil,
        fileLeaves: [String]? = nil,
        fileLeavesFull: [String: Int64]? = nil,
        childEdges: [String: Set<String>]? = nil,
        treeChildrenCache: [String: [TreeRow]]? = nil,
        snapshotTreeRows: [TreeSortKey: [TreeRow]]? = nil,
        perRootStaging: [String: PerRootProgress]? = nil,
        totalBytes: Int64? = nil,
        scannedFiles: Int? = nil,
        allocationSnapshot: FileAllocationSnapshot? = nil,
        largeFileMinBytes: Int64? = nil
    ) {
        if let largeFileMinBytes { self.largeFileMinBytes = largeFileMinBytes }
        if let allocationSnapshot { allocationCatalog = .committed(allocationSnapshot) }
        if let snap = snapshot {
            self.snapshot = snap
            self.snapshotTreeRowsBySort = Self.buildSnapshotTreeRows(
                rows: snap.rows,
                evidence: treeScanEvidenceProjection,
                locale: presentationLocale
            ) ?? [:]
        }
        if let currentRootPath {
            self.currentRootPath = currentRootPath
            self.scanResultRoots = [currentRootPath]
        }
        if let isScanning {
            self.isScanning = isScanning
        }
        if let buckets {
            self.buckets.removeAll()
            for (path, bytes) in buckets {
                self.buckets[path] = Bucket(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    bytes: bytes,
                    logicalBytes: bytes,
                    fileCount: 1,
                    isDirectory: true
                )
            }
        }
        if let dirIndex {
            self.dirIndex.removeAll()
            for path in dirIndex {
                self.dirIndex[path] = DirAgg(bytes: 1, logicalBytes: 1, fileCount: 1)
            }
        }
        // v1.5.7：带 (bytes, fileCount) 的 seed，让 prune 减法契约能拿到可验证的祖先聚合。
        if let dirIndexFull {
            self.dirIndex.removeAll()
            for (path, val) in dirIndexFull {
                self.dirIndex[path] = DirAgg(bytes: val.bytes, logicalBytes: val.bytes, fileCount: val.fileCount)
            }
        }
        if let fileLeaves {
            self.fileLeaves.removeAll()
            for path in fileLeaves {
                self.fileLeaves[path] = IndexedFileLeaf(bytes: 1, logicalBytes: 1, isDir: false, modificationDate: nil)
            }
        }
        if let fileLeavesFull {
            self.fileLeaves.removeAll()
            for (path, b) in fileLeavesFull {
                self.fileLeaves[path] = IndexedFileLeaf(bytes: b, logicalBytes: b, isDir: false, modificationDate: nil)
            }
        }
        if let childEdges {
            self.childEdges = childEdges
        }
        if let treeChildrenCache {
            self.treeChildrenCache = treeChildrenCache
        }
        if let snapshotTreeRows {
            self.snapshotTreeRowsBySort = snapshotTreeRows
        }
        if let perRootStaging {
            self.scanResultRoots = perRootStaging.keys.sorted()
            self.perRootStaging = perRootStaging
            syncPerRootPublished(from: perRootStaging)
        }
        if let totalBytes {
            self.totalBytes = totalBytes
        }
        if let scannedFiles {
            self.scannedFiles = scannedFiles
        }
        notePruneSourceMutation()
    }

    func _bucketsKeysForTesting() -> [String] { Array(buckets.keys) }
    func _bucketsBytesForTesting(_ path: String) -> Int64? { buckets[path]?.bytes }
    func _seedLargeFileLeavesForTesting(_ leaves: [(path: String, bytes: Int64)]) {
        largeFileLeaves = LargeFileLeafTopNHeap(capacity: max(1, leaves.count))
        for item in leaves {
            largeFileLeaves.consider(LargeFileLeaf(
                path: item.path,
                bytes: item.bytes,
                logicalBytes: item.bytes,
                modificationDate: nil
            ))
        }
    }
    func _dirIndexKeysForTesting() -> [String] { Array(dirIndex.keys) }
    /// v1.5.7：暴露 dirIndex 聚合值，让 pruneDeleted 祖先减法契约可验证。
    func _dirIndexAggForTesting(_ path: String) -> (bytes: Int64, fileCount: Int)? {
        guard let agg = dirIndex[path] else { return nil }
        return (agg.bytes, agg.fileCount)
    }
    func _fileLeavesKeysForTesting() -> [String] { Array(fileLeaves.keys) }
    func _childEdgesForTesting() -> [String: Set<String>] { childEdges }
    func _treeChildrenCacheForTesting() -> [String: [TreeRow]] { treeChildrenCache }
    func _snapshotTreeRowsForTesting(_ key: TreeSortKey) -> [TreeRow] {
        snapshotTreeRowsBySort[key] ?? []
    }
    func _perRootTreeRowsForTesting(_ key: TreeSortKey) -> [TreeRow] {
        perRootTreeRowsBySort[key] ?? []
    }
    func _treeLifecycleDiagnosticsForTesting() -> (
        preparationRanOnMainThread: Bool?,
        retirementRanOnMainThread: Bool?,
        retirementDurationNanoseconds: UInt64?,
        attemptCount: Int
    ) {
        (
            lastTreePreparationRanOnMainThread,
            lastTreeRetirementRanOnMainThread,
            lastTreeRetirementDurationNanoseconds,
            lastTreePreparationAttemptCount
        )
    }
    func _indexedTreePreviewDiagnosticsForTesting() -> (
        fanOut: Int,
        inspectedCount: Int,
        materializedCount: Int,
        buildCount: UInt64,
        cachedEntryCount: Int
    ) {
        (
            lastIndexedTreePreviewFanOut,
            lastIndexedTreePreviewInspectedCount,
            lastIndexedTreePreviewMaterializedCount,
            indexedTreePreviewBuildCount,
            indexedTreePreviewCache.count
        )
    }
    func _subtreeRescanLifecycleDiagnosticsForTesting() -> (
        preparationRanOnMainThread: Bool?,
        retirementRanOnMainThread: Bool?,
        retirementDurationNanoseconds: UInt64?,
        attemptCount: Int
    ) {
        (
            lastSubtreeRescanPreparationRanOnMainThread,
            lastSubtreeRescanRetirementRanOnMainThread,
            lastSubtreeRescanRetirementDurationNanoseconds,
            lastSubtreeRescanAttemptCount
        )
    }
    func _sessionRetirementDiagnosticsForTesting() -> (
        ranOnMainThread: Bool?,
        durationNanoseconds: UInt64?
    ) {
        (lastSessionRetirementRanOnMainThread, lastSessionRetirementDurationNanoseconds)
    }
    func _perRootPreparationRanOnMainThreadForTesting() -> Bool? {
        lastPerRootPreparationRanOnMainThread
    }

    func _livePerRootProjectionDiagnosticsForTesting() -> (
        ownerIsRunning: Bool,
        pendingRequestCount: Int,
        activeWorkerCount: Int,
        maxActiveWorkerCount: Int,
        buildCount: UInt64,
        commitCount: UInt64,
        staleDropCount: UInt64,
        coalescedRequestCount: UInt64,
        sourceRevision: UInt64
    ) {
        (
            livePerRootProjectionOwnerIsRunning,
            pendingLivePerRootProjection == nil ? 0 : 1,
            livePerRootProjectionActiveWorkerCount,
            livePerRootProjectionMaxActiveWorkerCount,
            livePerRootProjectionBuildCount,
            livePerRootProjectionCommitCount,
            livePerRootProjectionStaleDropCount,
            livePerRootProjectionCoalescedRequestCount,
            pruneSourceRevision
        )
    }

    func _syncPerRootPublishedOffMainForTesting(
        beforeCommit: (@MainActor () -> Void)? = nil
    ) async {
        await syncPerRootPublishedOffMain(
            from: perRootStaging,
            beforeCommitForTesting: beforeCommit
        )
    }

    func _publishDeveloperDiscoveryProgressForTesting() {
        publishDeveloperDiscoveryProgress()
    }

    func _requestLivePerRootProjectionForTesting(
        staging: [String: PerRootProgress],
        beforeCommit: (@MainActor () -> Void)? = nil,
        preparationDelayNanoseconds: UInt64 = 0,
        waitForDrain: Bool = true
    ) async {
        perRootStaging = staging
        notePruneSourceMutation()
        await syncPerRootPublishedOffMain(
            from: staging,
            beforeCommitForTesting: beforeCommit,
            preparationDelayNanosecondsForTesting: preparationDelayNanoseconds,
            waitForDrain: waitForDrain
        )
    }
    nonisolated static func _shouldEmitLivePerRootProjectionDrainLogForTesting(
        elapsedMilliseconds: Double,
        coalescedRequests: UInt64,
        staleDrops: UInt64
    ) -> Bool {
        shouldEmitLivePerRootProjectionDrainLog(
            elapsedMilliseconds: elapsedMilliseconds,
            coalescedRequests: coalescedRequests,
            staleDrops: staleDrops
        )
    }
    func _mtimeFallbackDiagnosticsForTesting() -> (
        preparationRanOnMainThread: Bool?,
        retirementRanOnMainThread: Bool?,
        retirementDurationNanoseconds: UInt64?,
        treeSortCount: Int?
    ) {
        (
            lastMtimePreparationRanOnMainThread,
            lastMtimeRetirementRanOnMainThread,
            lastMtimeRetirementDurationNanoseconds,
            lastMtimeTreeSortCount
        )
    }
    func _mtimeFallbackDateForTesting(_ path: String) -> Date? {
        cachedDirMtimeFallback(forPath: path)
    }
    func _mtimeFallbackQueueDiagnosticsForTesting() -> (
        cachedCount: Int,
        pendingCount: Int,
        continuationParentCount: Int
    ) {
        (
            mtimeFallbackCache.count,
            mtimeFallbackPendingPaths.count,
            mtimeFallbackContinuationParents.count
        )
    }
    func _probeMtimeFallbackForTesting(
        paths: [String],
        beforeCommit: (@MainActor () -> Void)? = nil
    ) async {
        let generation = treeFetchGeneration
        _ = await prepareAndCommitMtimeFallbackBatch(
            paths,
            expectedGeneration: generation,
            expectedToken: nil,
            beforeCommitForTesting: beforeCommit
        )
    }
    func _prunePlanDiagnosticsForTesting() -> (ranOnMainThread: Bool?, durationNanoseconds: UInt64?) {
        (lastPrunePlanRanOnMainThread, lastPrunePlanDurationNanoseconds)
    }
    func _pruneTreeCacheContributionIndexBuiltForTesting() -> Bool? {
        lastPruneTreeCacheContributionIndexBuilt
    }
    func _pruneLifecycleDiagnosticsForTesting() -> (
        mergeRanOnMainThread: Bool?,
        retirementRanOnMainThread: Bool?,
        retirementDurationNanoseconds: UInt64?
    ) {
        (
            lastPruneTombstoneMergeRanOnMainThread,
            lastPruneRetirementRanOnMainThread,
            lastPruneRetirementDurationNanoseconds
        )
    }
    func _awaitPruneRetirementForTesting() async {
        let retirement = pruneRetirementTail
        await retirement?.value
    }
    func _deletedTombstoneRootsForTesting() -> [String] {
        deletedPathTombstones.matcher.roots
    }
    func _isDeletedTombstonedForTesting(_ path: String) -> Bool {
        isDeletedTombstoned(path)
    }
    func _aggregateTotalsForTesting() -> (bytes: Int64, files: Int) {
        (totalBytes, scannedFiles)
    }
    func _beginTerminalPreparationSessionForTesting(categoryID: String) -> UUID {
        buckets.removeAll()
        lastTerminalPreparationRanOnMainThread = nil
        lastTerminalRetirementRanOnMainThread = nil
        lastTerminalRetirementDurationNanoseconds = nil
        activeCategoryID = categoryID
        scanGeneration = UUID()
        notePruneSourceMutation()
        return scanGeneration
    }
    /// Seeds every wide terminal COW boundary with storage that has no owner outside the
    /// coordinator. A subsequent terminal transaction must swap these containers on MainActor,
    /// while `TerminalPresentationWorker.retire()` performs their final release off-main.
    /// v2026.07.18 regression fixture: terminal retirement must cover more than result rows.
    func _seedWideTerminalRetirementStateForTesting(count: Int) {
        precondition(count > 0)
        var seededBuckets: [String: Bucket] = [:]
        seededBuckets.reserveCapacity(count)
        var seededRows: [RowItem] = []
        seededRows.reserveCapacity(count)
        var seededLastIngestAt: [String: TimeInterval] = [:]
        seededLastIngestAt.reserveCapacity(count)
        var seededStreamIDs: [String] = []
        seededStreamIDs.reserveCapacity(count)
        var seededActive: [String: PerRootProgress] = [:]
        seededActive.reserveCapacity(count / 2)
        var seededFinished: [String: PerRootProgress] = [:]
        seededFinished.reserveCapacity(count / 2)
        var seededPerRootSorted: [PerRootProgress] = []
        seededPerRootSorted.reserveCapacity(count)
        var seededIssues: [ScanIncompleteIssue] = []
        seededIssues.reserveCapacity(count)

        for index in 0..<count {
            let path = "/terminal-retirement/old-\(index)"
            let bytes = Int64(index + 1)
            let url = URL(fileURLWithPath: path, isDirectory: true)
            seededBuckets[path] = Bucket(
                url: url,
                bytes: bytes,
                logicalBytes: bytes,
                fileCount: 1,
                isDirectory: true,
                hasChildren: true
            )
            seededRows.append(RowItem(
                id: path,
                url: url,
                title: url.lastPathComponent,
                isDirectory: true,
                bytes: bytes,
                logicalBytes: bytes,
                fileCount: 1,
                verdict: .safe,
                rejection: .ok,
                hasChildren: true
            ))
            seededLastIngestAt[path] = TimeInterval(index)
            seededStreamIDs.append(path)

            let progress = PerRootProgress(
                rootPath: path,
                title: url.lastPathComponent,
                bytes: bytes,
                fileCount: 1,
                isFinished: index.isMultiple(of: 2)
            )
            if progress.isFinished {
                seededFinished[path] = progress
            } else {
                seededActive[path] = progress
            }
            seededPerRootSorted.append(progress)

            let reason: ScanIncompleteReason
            switch index % 3 {
            case 0: reason = .permissionDenied
            case 1: reason = .tccProtectedSkipped
            default: reason = .metadataUnavailable
            }
            seededIssues.append(ScanIncompleteIssue(
                path: path + "/incomplete",
                reason: reason,
                stage: .metadata
            ))
        }

        buckets = seededBuckets
        snapshot = ScanSnapshot(
            categoryID: "terminal-retirement-old",
            rows: seededRows,
            totalBytes: seededRows.reduce(0) { $0 &+ $1.bytes },
            scannedFileCount: count,
            isFinished: false,
            elapsed: 0
        )
        lastIngestAt = seededLastIngestAt
        lastStreamSortedIds = seededStreamIDs
        lastStreamSortCacheKey = (count, 0)

        // Empty staging makes the terminal DTO swap the old published per-root containers out.
        perRootStaging = [:]
        perRootProgressActive = seededActive
        perRootFinishedSlim = seededFinished
        perRootFinishedCount = seededFinished.count
        perRootProgressSorted = seededPerRootSorted

        // Empty authoritative sources make the terminal evidence DTO replace every old public
        // projection, including the Tree hash sets, while the worker remains their sole owner.
        primaryIncompleteEvidence = ScanIncompleteEvidenceIndex()
        treeIncompleteEvidenceByRoot = [:]
        incompleteScanIssues = seededIssues
        permissionDeniedPaths = seededIssues
            .filter { $0.reason == .permissionDenied }
            .map(\.path)
        tccProtectedSkippedPaths = seededIssues
            .filter { $0.reason == .tccProtectedSkipped }
            .map(\.path)
        incompleteScanPaths = seededIssues.map(\.path)
        treeScanEvidenceProjection = TreeScanEvidenceProjection(issues: seededIssues)
        incompleteEvidenceProjectionDirty = true
        incompleteEvidenceSourceRevision &+= 1
        notePruneSourceMutation()
    }
    func _invalidateTerminalPreparationGenerationForTesting() {
        scanGeneration = UUID()
        notePruneSourceMutation()
    }
    func _prepareTerminalProjectionForTesting(
        entries: [ScanTopLevelEntry],
        rootPath: String,
        categoryID: String,
        generation: UUID,
        beforeCommit: (@MainActor () -> Void)? = nil
    ) async -> (
        committed: Bool,
        rows: [RowItem],
        preparationRanOnMainThread: Bool?,
        retirementRanOnMainThread: Bool?,
        evidenceRanOnMainThread: Bool?,
        evidenceIssueCount: Int,
        perRootRanOnMainThread: Bool?,
        attemptCount: Int,
        safetyEvaluationCount: Int,
        safetyWorkerCount: Int,
        safetyWorkerObservedMainThread: Bool
    ) {
        guard let transaction = await prepareTerminalPresentation(
            projections: [TerminalProjectionEnvelope(
                projection: .topLevel(entries),
                rootPath: rootPath
            )],
            categoryID: categoryID,
            generation: generation,
            beforeCommitForTesting: beforeCommit
        ) else {
            return (
                false,
                [],
                lastTerminalPreparationRanOnMainThread,
                lastTerminalRetirementRanOnMainThread,
                nil,
                0,
                nil,
                0,
                0,
                0,
                false
            )
        }
        applyPreparedPerRootProjection(transaction.perRoot)
        if let evidence = transaction.evidence {
            applyPreparedIncompleteEvidenceProjection(evidence)
        }
        publishPreparedTerminalSnapshot(
            categoryID: categoryID,
            complete: true,
            presentation: transaction.presentation
        )
        finalizeTreeCacheAfterScan(
            transaction.presentation.developerTreeChildrenProjection == nil
                ? .invalidateScanPeriodCache
                : .preserveCommittedDeveloperProjection
        )
        await retireTerminalWorkerAndRecord(transaction.worker)
        return (
            true,
            transaction.presentation.rows,
            transaction.presentation.ranOnMainThread,
            lastTerminalRetirementRanOnMainThread,
            transaction.evidence?.ranOnMainThread,
            transaction.evidence?.combinedIssues.count ?? 0,
            transaction.perRoot.ranOnMainThread,
            transaction.attemptCount,
            transaction.presentation.diagnostics.safetyEvaluationCount,
            transaction.presentation.diagnostics.safetyWorkerCount,
            transaction.presentation.diagnostics.safetyWorkerObservedMainThread
        )
    }
    func _incrementalNodeDeliveryCountForTesting() -> Int {
        incrementalNodeDeliveryCount
    }
    /// Deterministic ownership seams for settlement regression tests. They expose the production
    /// admission state machine without starting a real filesystem scan or weakening the producer
    /// boundary asserted by those tests.
    func _retireProducerForSettlementTesting(_ task: Task<Void, Never>) {
        let decision = primaryScanAdmissionRegistry.request(
            clientID: primaryScanAdmissionClientID,
            intent: "settlement-fixture",
            onInvalidated: { [weak self] context in
                self?.handlePrimaryAdmissionInvalidation(context) ?? []
            },
            onAdmitted: { _ in
                assertionFailure("settlement fixture must be admitted synchronously")
            },
            onDiscarded: { [] }
        )
        guard case .admitted(let reservation) = decision,
              let launch = primaryScanAdmissionRegistry.reserveProducerLaunch(
                reservation: reservation,
                kind: .singleRoot
              )
        else {
            assertionFailure("settlement fixture could not acquire an idle admission registry")
            return
        }
        activePrimaryReservation = reservation
        _ = primaryScanAdmissionRegistry.activateProducer(
            launch: launch,
            reservation: reservation,
            cancel: { task.cancel() },
            termination: task,
            requiresPayloadHandoff: false
        )
        task.cancel()
    }
    func _schedulePrimaryScanIntentForTesting(
        _ intent: PrimaryScanIntent,
        onStart: @escaping @MainActor @Sendable () -> Void
    ) {
        schedulePrimaryScanIntent(intent) { [weak self] in
            guard let self else { return }
            self.isScanning = true
            self.scanPhase = .scanning
            onStart()
        }
    }
    /// Executes the exact admission helpers called by `scan(.fullDisk)` / `scanDeveloper`
    /// without starting a real filesystem producer.
    func _admitFullDiskTreePolicyForTesting() {
        enforceOnDemandTreeProductEntry(.fullDisk)
    }
    func _admitDeveloperTreePolicyForTesting() {
        enforceOnDemandTreeProductEntry(.developerArtifacts)
    }
    func _treeChildrenInFlightForTesting() -> Set<String> { treeChildrenInFlight }
    func _treeChildrenTaskKeysForTesting() -> Set<String> { Set(treeChildrenTasks.keys) }
    func _seedPresentationTreeTaskForSettlementTesting(_ task: Task<Void, Never>) {
        let key = "__presentation_settlement_fixture__|sizeDesc"
        treeChildrenTasks[key] = TreeChildrenTaskState(
            token: UUID(),
            task: task,
            ownerKind: .presentation
        )
        treeChildrenInFlight.insert(key)
        treeChildrenOwnershipRevision &+= 1
    }
    nonisolated static func _treeFilesystemPathsOverlapForTesting(
        publicPath lhsPublicPath: String,
        physicalPath lhsPhysicalPath: String,
        otherPublicPath rhsPublicPath: String,
        otherPhysicalPath rhsPhysicalPath: String
    ) -> Bool {
        TreeFilesystemMeasurementIdentity(
            publicPath: lhsPublicPath,
            physicalPath: lhsPhysicalPath
        ).overlaps(TreeFilesystemMeasurementIdentity(
            publicPath: rhsPublicPath,
            physicalPath: rhsPhysicalPath
        ))
    }
    /// Deterministic lease-domain driver. `sort` is accepted only to prove the production
    /// measurement identity ignores presentation ordering; it never enters the lease key.
    func _runTreeFilesystemLeaseForTesting(
        publicPath: String,
        physicalPath: String? = nil,
        sort: TreeSortKey = .sizeDesc,
        stage rawStage: String = "deep",
        usesTreeGate: Bool = false,
        tracksPrimaryOwner: Bool = false,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        _ = sort
        let stage: TreeFilesystemProducerStage
        switch rawStage {
        case "shallow": stage = .shallow
        case "indexed_subtree": stage = .indexedSubtree
        default: stage = .deep
        }
        let identity = TreeFilesystemMeasurementIdentity(
            publicPath: publicPath,
            physicalPath: physicalPath ?? publicPath
        )
        let intentID = UUID()
        if tracksPrimaryOwner {
            directTreeAsyncFilesystemOwners[intentID] = identity
        }
        defer {
            if tracksPrimaryOwner {
                directTreeAsyncFilesystemOwners.removeValue(forKey: intentID)
            }
        }
        let outcome = await treeFilesystemLeaseDomain.run(
            identity: identity,
            stage: stage,
            intentID: intentID
        ) {
            guard usesTreeGate else {
                await operation()
                return
            }
            guard await Self.treeChildrenFetchGate.acquire() else { return }
            await operation()
            await Self.treeChildrenFetchGate.release()
        }
        switch outcome {
        case .produced: return true
        case .dropped: return false
        }
    }
    func _treeFilesystemLeaseDiagnosticsForTesting() async -> (
        active: Int,
        waiting: Int,
        reserved: Int
    ) {
        await treeFilesystemLeaseDomain.diagnostics()
    }
    nonisolated static func _treeFilesystemGateDiagnosticsForTesting() async -> (
        active: Int,
        waiting: Int
    ) {
        await treeChildrenFetchGate.diagnostics()
    }
    func _cancelTreeFilesystemLeaseDomainForTesting() -> Task<Void, Never> {
        let domain = treeFilesystemLeaseDomain
        return Task.detached(priority: .utility) {
            await domain.cancelAllAndWait(reason: "test_primary_cancel")
        }
    }
    func _cancelAllTreeChildrenFetchesForTesting() -> [Task<Void, Never>] {
        cancelAllTreeChildrenFetches()
    }
    @discardableResult
    func _seedIndexedSubtreeOwnerForTesting(
        publicPath: String,
        owner: Task<Void, Never>
    ) -> (replacedRequests: Int, cancelledProducers: Int) {
        let path = URL(fileURLWithPath: publicPath).standardizedFileURL.path
        let identity = treeFilesystemMeasurementIdentity(publicPath: path)
        let token = UUID()
        let replacements = beginIndexedSubtreeRequest(
            path: path,
            identity: identity,
            token: token
        )
        let bridge: Task<IndexedSubtreeMeasurement?, Never> = Task {
            await withTaskCancellationHandler {
                await owner.value
                return nil
            } onCancel: {
                owner.cancel()
            }
        }
        indexedSubtreeScanTasks[path] = IndexedSubtreeTaskState(
            token: token,
            identity: identity,
            task: bridge,
            cancel: {
                bridge.cancel()
                owner.cancel()
            }
        )
        return (replacements.requests, replacements.producers)
    }
    func _indexedSubtreeRequestPathsForTesting() -> Set<String> {
        Set(indexedSubtreeRequests.keys)
    }
    func _seedTreeChildrenTasksForTesting(keys: [String]) {
        guard !keys.isEmpty else { return }
        for key in keys {
            treeChildrenTasks[key] = TreeChildrenTaskState(
                token: UUID(),
                task: Task.detached(priority: .utility) {},
                ownerKind: .presentation
            )
            treeChildrenInFlight.insert(key)
        }
        treeChildrenOwnershipRevision &+= 1
    }
    func _rescanSubtreeForTesting(
        at path: String,
        beforeCommit: (@MainActor () async -> Void)? = nil
    ) async {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let identity = treeFilesystemMeasurementIdentity(publicPath: normalizedPath)
        let token = UUID()
        _ = beginIndexedSubtreeRequest(
            path: normalizedPath,
            identity: identity,
            token: token
        )
        await performSubtreeRescan(
            at: normalizedPath,
            expectedGeneration: treeFetchGeneration,
            expectedRequestPath: normalizedPath,
            expectedRequestToken: token,
            removeCache: true,
            beforeCommitForTesting: beforeCommit
        )
        finishIndexedSubtreeRequest(path: normalizedPath, token: token)
    }
    /// v2026.07.18: deterministic entry for real filesystem refresh/CAS tests. Production and
    /// tests share the scanner, ownership, evidence and commit path; only the suspension hook is
    /// injected.
    func _rescanIndexedSubtreeForTesting(
        at path: String,
        beforeCommit: (@MainActor () async -> Void)? = nil
    ) async {
        await rescanSubtreeTransaction(at: path, beforeCommitForTesting: beforeCommit)
    }
    nonisolated static func _subtreeCacheKeyBelongsForTesting(
        _ key: String,
        rootPath: String
    ) -> Bool {
        subtreeCacheKey(key, belongsTo: rootPath)
    }
    func _storeFetchedChildrenForTesting(
        path: String,
        sortedBy key: TreeSortKey,
        rows: [TreeRow],
        beforeCommit: (@MainActor () -> Void)? = nil
    ) async {
        await storeFetchedChildren(
            path: path,
            sortedBy: key,
            rows: rows,
            authority: .complete,
            incompleteIssues: [],
            beforeCommitForTesting: beforeCommit
        )
    }
    /// Drives the production deep-index worker with a deterministic suspension hook. The helper
    /// only installs task ownership; row materialization, revision retry and commit are identical
    /// to an actual disclosure request.
    func _prepareIndexedTreeProjectionForTesting(
        path: String,
        sortedBy key: TreeSortKey,
        beforeCommit: (@MainActor () -> Void)? = nil
    ) async {
        guard let kids = childEdges[path] else { return }
        let cacheKey = "\(path)|\(key.rawValue)"
        let generation = treeFetchGeneration
        let token = UUID()
        treeChildrenTasks[cacheKey] = TreeChildrenTaskState(
            token: token,
            task: Task.detached(priority: .utility) {},
            ownerKind: .presentation
        )
        treeChildrenInFlight.insert(cacheKey)
        treeChildrenOwnershipRevision &+= 1
        await prepareMemoryTreeProjection(
            path: path,
            initialKids: kids,
            cacheKey: cacheKey,
            expectedGeneration: generation,
            expectedTaskToken: token,
            beforeCommitForTesting: beforeCommit
        )
        finishTreeChildrenTask(
            cacheKey: cacheKey,
            token: token,
            publishTerminalRevision: true,
            changedPath: path
        )
    }
    func _storeShallowFetchedChildrenForTesting(path: String, sortedBy key: TreeSortKey, rows: [TreeRow]) async {
        await storeFetchedChildren(
            path: path,
            sortedBy: key,
            rows: rows,
            authority: .shallowIdentityComplete
        )
    }
    func _storePartialFetchedChildrenForTesting(path: String, sortedBy key: TreeSortKey, rows: [TreeRow]) async {
        await storeFetchedChildren(
            path: path,
            sortedBy: key,
            rows: rows,
            authority: .partialLowerBound
        )
    }
    func _replaceTreeIncompleteEvidenceForTesting(
        rootPath: String,
        issues: [ScanIncompleteIssue]
    ) {
        replaceTreeIncompleteEvidence(rootPath: rootPath, with: issues)
    }
    func _displayPathForScanNodeForTesting(_ path: String, rootPath: String) -> String {
        displayPathForScanNode(path, rootPath: rootPath)
    }
    func _physicalPathForFullDiskTreeForTesting(_ publicPath: String) -> String {
        fullDiskPathNamespace.physicalPath(forPublicPath: publicPath)
    }
    nonisolated static func _shouldRespectTCCSkipListForTesting(
        fdaStatus: FDAProbe.Status
    ) -> Bool {
        shouldRespectTCCSkipList(fdaStatus: fdaStatus)
    }
    nonisolated static func _scanDirectChildrenOnDemandForTesting(
        publicRootPath: String,
        pathNamespace: ScanPathNamespace
    ) async -> (
        rows: [TreeRow],
        issues: [ScanIncompleteIssue],
        isComplete: Bool,
        parentAccessState: TreeRow.AccessState?
    ) {
        let measurement = await scanDirectChildrenOnDemand(
            rootPath: publicRootPath,
            sortedBy: .nameAsc,
            accessProjection: TreeScanEvidenceProjection(),
            pathNamespace: pathNamespace
        )
        let isComplete: Bool
        switch measurement.authority {
        case .complete: isComplete = true
        case .shallowIdentityComplete, .partialLowerBound: isComplete = false
        }
        return (
            measurement.rows,
            measurement.incompleteIssues,
            isComplete,
            measurement.parentState?.accessState
        )
    }

    nonisolated static func _scanDirectChildrenShallowForTesting(
        publicRootPath: String,
        pathNamespace: ScanPathNamespace
    ) -> (
        rows: [TreeRow],
        issues: [ScanIncompleteIssue],
        parentAccessState: TreeRow.AccessState?
    ) {
        let measurement = scanDirectChildrenShallow(
            rootPath: publicRootPath,
            accessProjection: TreeScanEvidenceProjection(),
            pathNamespace: pathNamespace
        )
        return (
            measurement.rows.sorted {
                sortTreeRow($0, before: $1, by: .nameAsc)
            },
            measurement.incompleteIssues,
            measurement.parentState?.accessState
        )
    }

    // MARK: - Step 17-A: 内存占用护栏 readers（仅供 [DirIndexMemoryFootprintTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/DirIndexMemoryFootprintTests.swift)）

    /// 暴露 DirAgg / Bucket 的 MemoryLayout.size，让护栏测能钉死结构体大小不变量。
    /// DirAgg / Bucket 是 private struct，测试 target 看不到 type 本身——
    /// 这里以静态值返回 size，外面只断言"不超过上限"，无字段 schema 暴露。
    static var _dirAggSizeForTesting: Int { MemoryLayout<DirAgg>.size }
    static var _bucketSizeForTesting: Int { MemoryLayout<Bucket>.size }

}

// MARK: - v1.5.7 perf：原生 String 路径切分（避免 NSString 桥接 + 拷贝）

extension String {
    /// 返回 path 的父目录路径（与 `(p as NSString).deletingLastPathComponent` 等价的
    /// **常见 case** 子集，针对 POSIX 绝对路径优化）。
    ///
    /// 关键差异：仅在原生 `String` 上用 `lastIndex(of: "/")` 切片，**不**触发 NSString
    /// bridging / NSPathStore2 分配。ingest 热路径每个叶子文件回溯 O(depth) 次，
    /// 在 5w+ 文件场景下原方案 NSString 桥接占主线程 ~12% 时间（Instruments 采样口径）。
    ///
    /// 行为契约：
    /// - `/` → `/`
    /// - `/A` → `/`
    /// - `/A/B` → `/A`
    /// - `/A/B/C` → `/A/B`
    /// - 空串 → 空串
    /// 与 NSString.deletingLastPathComponent 在"POSIX 绝对路径、单 / 分隔、无尾 /"
    /// 输入下完全一致；ingest 调用方保证传入路径都是 FileManager.enumerator 给出
    /// 的规范绝对路径，无尾斜杠、无 `.`/`..`，所以这个简化版安全。
    @inline(__always)
    static func _gsyParentPath(of p: String) -> String {
        if p.isEmpty { return "" }
        guard let slash = p.lastIndex(of: "/") else { return "" }
        // 根目录 "/X" → "/"
        if slash == p.startIndex { return "/" }
        return String(p[p.startIndex..<slash])
    }
}

// MARK: - v2026.06.21 perf：onPartial 节流窗口

/// `scanDeveloperArtifacts` 的 `onPartial` 闭包需要在多次回调之间共享"上次 sync 时间戳"。
/// 闭包要 `@Sendable`，又要可变状态——直接用 var capture 会被 Swift 6 拒绝；
/// 包一层 reference type 即可。所有读写都被 `Task { @MainActor ... }` 串行化在主 actor
/// 上，没有 data race，因此不需要 lock。
@MainActor
final class PartialSyncWindow {
    /// 上次调用 `syncPerRootPublished` 的时间戳（`Date.timeIntervalSinceReferenceDate`）。
    /// 0 = 首次，肯定通过 0.4s 阈值——保证 sidebar 第一行立刻出现。
    var lastSync: TimeInterval = 0
}
