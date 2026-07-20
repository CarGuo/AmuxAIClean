import Combine
import XCTest
@testable import AppUI

/// v2026.07.18 scan ownership regression: revision/generation guards only protect state writes.
/// A replacement producer must also wait until the cancelled predecessor has completed cleanup,
/// otherwise both filesystem walks continue concurrently and contend for disk/UI delivery.
@MainActor
final class ScanProducerSettlementTests: XCTestCase {
    func test_replacementWaitsForCancelledProducerToActuallySettle() async throws {
        let probe = SettlementProbe()
        let chain = ScanProducerSettlementChain()

        let first = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Cancellation only requests shutdown. Simulate a real scanner that still has
                // descriptors/workers to reap before ownership is released.
            }
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let firstDidStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(firstDidStart)

        chain.retire([first])
        let predecessor = chain.barrier()
        let replacement = Task {
            guard await ScanProducerSettlementChain.waitForSettlement(predecessor) else { return }
            await probe.markReplacementStarted()
        }

        let cancellationWasObserved = await eventually { await probe.cancellationObserved }
        let replacementStartedBeforeCleanup = await probe.replacementStarted
        XCTAssertTrue(cancellationWasObserved)
        XCTAssertFalse(replacementStartedBeforeCleanup,
                       "generation replacement must not start heavy I/O while old cleanup is pending")

        await probe.releaseCleanup()
        await replacement.value
        let order = await probe.order
        XCTAssertEqual(order, ["first.start", "first.finish", "replacement.start"])
    }

    /// v2026.07.19 regression: Tree disclosure used the same global settlement barrier as a
    /// replacement primary scan. One cancelled producer stuck at a synchronous filesystem edge
    /// therefore made an unrelated disclosure row spin indefinitely. Tree owns path-scoped CAS;
    /// it must be able to publish the latest path while the primary chain remains unsettled.
    func test_unsettledPrimaryChainDoesNotBlockLatestTreeDisclosure() async throws {
        let coordinator = ScanCoordinator()
        let probe = SettlementProbe()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-settlement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x41]).write(to: root.appendingPathComponent("child.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let blocker = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // The cancelled producer still owns cleanup until the test explicitly releases it.
            }
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let blockerStarted = await eventually { await probe.firstStarted }
        XCTAssertTrue(blockerStarted)
        coordinator._retireProducerForSettlementTesting(blocker)
        let cancellationObserved = await eventually { await probe.cancellationObserved }
        XCTAssertTrue(cancellationObserved)

        _ = coordinator.directChildren(of: root.path, sortedBy: .nameAsc)
        var rows: [TreeRow] = []
        for _ in 0..<200 where rows.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
            rows = coordinator.directChildren(of: root.path, sortedBy: .nameAsc)
        }
        XCTAssertEqual(rows.map(\.title), ["child.txt"])
        let orderBeforeRelease = await probe.order
        XCTAssertFalse(orderBeforeRelease.contains("first.finish"),
                       "Tree disclosure must not consume the primary settlement barrier")

        await probe.releaseCleanup()
        await blocker.value
    }

    /// A replacement request waiting for real producer teardown must retain the old frame and
    /// expose a typed phase. Repeated user input replaces the pending intent; it must neither set
    /// fake scan progress nor start an obsolete intent after settlement.
    func test_latestPrimaryIntentOwnsTypedSettlementAndStartsAfterTeardown() async throws {
        let coordinator = ScanCoordinator()
        let stableSnapshot = ScanSnapshot(
            categoryID: "stable",
            rows: [],
            totalBytes: 42,
            scannedFileCount: 1,
            isFinished: true,
            elapsed: 1
        )
        coordinator._seedForTesting(
            snapshot: stableSnapshot,
            currentRootPath: "/stable",
            isScanning: false
        )
        let probe = SettlementProbe()
        let blocker = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let blockerStarted = await eventually { await probe.firstStarted }
        XCTAssertTrue(blockerStarted)
        coordinator._retireProducerForSettlementTesting(blocker)

        let startedIntents = StartedIntentRecorder()
        coordinator._schedulePrimaryScanIntentForTesting(.category("first")) {
            startedIntents.append("first")
        }
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertEqual(coordinator.snapshot.categoryID, "stable")
        guard case .settling(let firstState) = coordinator.scanPhase else {
            return XCTFail("replacement must expose settling before the producer returns")
        }
        XCTAssertEqual(firstState.intent, .category("first"))

        coordinator._schedulePrimaryScanIntentForTesting(.category("latest")) {
            startedIntents.append("latest")
        }
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertEqual(coordinator.snapshot.categoryID, "stable")
        guard case .settling(let latestState) = coordinator.scanPhase else {
            return XCTFail("latest replacement must remain typed while ownership is unsettled")
        }
        XCTAssertEqual(latestState.intent, .category("latest"))
        XCTAssertTrue(startedIntents.values.isEmpty)

        await probe.releaseCleanup()
        let latestDidStart = await eventually { !startedIntents.values.isEmpty }
        XCTAssertTrue(latestDidStart)
        XCTAssertEqual(startedIntents.values, ["latest"])
        XCTAssertTrue(coordinator.isScanning)
        XCTAssertEqual(coordinator.scanPhase, .scanning)
        XCTAssertNotNil(coordinator.lastScanSettlementDuration)
        await blocker.value
        coordinator.cancel()
    }

    /// v2026.07.19 regression: settlement intentionally keeps the last terminal frame visible,
    /// but that frame belongs to the predecessor. It must never authorize deletion/stash under
    /// the incoming intent's generation while the producer handoff is unresolved.
    func test_resultActionsRemainBlockedAcrossSettlementUntilANewTerminalSnapshotExists() async {
        let coordinator = ScanCoordinator()
        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "stable",
                rows: [],
                totalBytes: 42,
                scannedFileCount: 1,
                isFinished: true,
                elapsed: 1
            ),
            currentRootPath: "/stable",
            isScanning: false
        )
        let stableSessionID = coordinator.currentScanSessionID
        XCTAssertTrue(coordinator.canUseCurrentScanResultsForActions)

        let probe = SettlementProbe()
        let blocker = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let blockerDidStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(blockerDidStart)
        coordinator._retireProducerForSettlementTesting(blocker)
        coordinator._schedulePrimaryScanIntentForTesting(.category("replacement")) {}

        XCTAssertEqual(coordinator.snapshot.categoryID, "stable")
        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertEqual(coordinator.currentScanSessionID, stableSessionID,
                       "可见 predecessor 快照必须继续携带自己的 session identity")
        XCTAssertTrue(coordinator.hasActivePrimaryScanOwnership)
        XCTAssertFalse(coordinator.canUseCurrentScanResultsForActions)

        await probe.releaseCleanup()
        let replacementDidStart = await eventually { coordinator.scanPhase == .scanning }
        XCTAssertTrue(replacementDidStart)
        XCTAssertNotEqual(coordinator.currentScanSessionID, stableSessionID,
                          "replacement 真正替换 frame 时才推进可见 session identity")
        XCTAssertFalse(coordinator.canUseCurrentScanResultsForActions)
        await blocker.value
        coordinator.cancel()
        XCTAssertFalse(coordinator.hasActivePrimaryScanOwnership)
    }

    func test_cancelPublishesEmptyFrameBeforeAuthoritativeIdle() {
        let coordinator = ScanCoordinator()
        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "stable",
                rows: [],
                totalBytes: 1,
                scannedFileCount: 1,
                isFinished: true,
                elapsed: 1
            ),
            isScanning: false
        )
        var authorizationStates: [Bool] = []
        let observation = coordinator.$snapshot
            .combineLatest(coordinator.$isScanning, coordinator.$scanPhase)
            .sink { snapshot, isScanning, phase in
                authorizationStates.append(
                    phase == .idle && !isScanning && snapshot.isFinished
                )
            }

        coordinator.cancel()
        withExtendedLifetime(observation) {}

        XCTAssertEqual(authorizationStates.first, true)
        guard let firstBlocked = authorizationStates.firstIndex(of: false) else {
            return XCTFail("cancel must revoke terminal result authority")
        }
        XCTAssertFalse(authorizationStates[firstBlocked...].contains(true),
                       "cancel must not republish idle while the predecessor frame is still visible")
        XCTAssertFalse(coordinator.canUseCurrentScanResultsForActions)
        XCTAssertFalse(coordinator.snapshot.isFinished)
    }

    /// Pure Tree projection retirement must not become a filesystem admission barrier. A wide
    /// cancelled projection can finish off-main while the replacement scan starts immediately;
    /// source generation/CAS still prevents the old presentation from committing.
    func test_cancelledPresentationTreeWorkerDoesNotDelayPrimaryAdmission() async {
        let coordinator = ScanCoordinator()
        let probe = SettlementProbe()
        let presentation = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let presentationDidStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(presentationDidStart)
        coordinator._seedPresentationTreeTaskForSettlementTesting(presentation)

        coordinator.cancelOnDemandTreeScansPreservingResults()
        let cancellationWasObserved = await eventually { await probe.cancellationObserved }
        XCTAssertTrue(cancellationWasObserved)
        let started = StartedIntentRecorder()
        coordinator._schedulePrimaryScanIntentForTesting(.category("replacement")) {
            started.append("replacement")
        }

        XCTAssertEqual(started.values, ["replacement"])
        XCTAssertEqual(coordinator.scanPhase, .scanning)
        let orderBeforeRelease = await probe.order
        XCTAssertFalse(orderBeforeRelease.contains("first.finish"),
                       "replacement must not await presentation-only retirement")

        await probe.releaseCleanup()
        await presentation.value
        coordinator.cancel()
    }

    /// Professional and Smart Care use different client identities but one App-level registry.
    /// The first producer is registered while active—not pre-retired—so this proves the registry
    /// closes the old tail-only hole before admitting a cross-coordinator replacement.
    func test_sharedRegistryBlocksCrossCoordinatorReplacementUntilActiveProducerTerminates() async {
        let registry = PrimaryScanAdmissionRegistry()
        let professional = ScanCoordinator(
            primaryScanAdmissionRegistry: registry,
            primaryScanAdmissionClientID: .init()
        )
        let smartCare = ScanCoordinator(
            primaryScanAdmissionRegistry: registry,
            primaryScanAdmissionClientID: .init()
        )
        XCTAssertTrue(
            professional.primaryScanAdmissionRegistry === smartCare.primaryScanAdmissionRegistry
        )
        XCTAssertNotEqual(
            professional.primaryScanAdmissionClientID,
            smartCare.primaryScanAdmissionClientID
        )
        let probe = SettlementProbe()
        let oldProducer = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let oldDidStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(oldDidStart)
        professional._retireProducerForSettlementTesting(oldProducer)

        let started = StartedIntentRecorder()
        smartCare._schedulePrimaryScanIntentForTesting(.category("smart-care")) {
            started.append("smart-care")
        }
        guard case .settling = smartCare.scanPhase else {
            return XCTFail("second coordinator must observe the shared active producer")
        }
        XCTAssertTrue(started.values.isEmpty)
        let queued = registry.diagnostics()
        XCTAssertTrue(queued.hasCurrent)
        XCTAssertEqual(queued.activeLeaseCount, 1)
        XCTAssertEqual(queued.pendingCount, 1)

        await probe.releaseCleanup()
        let replacementDidStart = await eventually { started.values == ["smart-care"] }
        XCTAssertTrue(replacementDidStart)
        XCTAssertEqual(smartCare.scanPhase, .scanning)
        await oldProducer.value
        smartCare.cancel()
        professional.cancel()
    }

    /// The pending slot is globally bounded and latest-wins across client identities. Repeated
    /// mode/category input while a cancelled producer settles must not accumulate waiter Tasks or
    /// resurrect an obsolete Smart Care request after the producer finally returns.
    func test_sharedRegistryKeepsOnlyLatestCrossCoordinatorPendingIntent() async {
        let registry = PrimaryScanAdmissionRegistry()
        let professional = ScanCoordinator(
            primaryScanAdmissionRegistry: registry,
            primaryScanAdmissionClientID: .init()
        )
        let smartCare = ScanCoordinator(
            primaryScanAdmissionRegistry: registry,
            primaryScanAdmissionClientID: .init()
        )
        let probe = SettlementProbe()
        let oldProducer = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let oldDidStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(oldDidStart)
        professional._retireProducerForSettlementTesting(oldProducer)

        let discardedStart = StartedIntentRecorder()
        let latestStart = StartedIntentRecorder()
        smartCare._schedulePrimaryScanIntentForTesting(.category("discarded")) {
            discardedStart.append("discarded")
        }
        professional._schedulePrimaryScanIntentForTesting(.category("latest")) {
            latestStart.append("latest")
        }

        let queued = registry.diagnostics()
        XCTAssertEqual(queued.activeLeaseCount, 1)
        XCTAssertEqual(queued.pendingCount, 1,
                       "latest-wins admission must retain exactly one pending request")
        XCTAssertTrue(discardedStart.values.isEmpty)
        XCTAssertTrue(latestStart.values.isEmpty)

        await probe.releaseCleanup()
        let latestDidStart = await eventually { latestStart.values == ["latest"] }
        XCTAssertTrue(latestDidStart)
        XCTAssertTrue(discardedStart.values.isEmpty,
                      "discarded pending intent must never be admitted after settlement")
        XCTAssertEqual(registry.diagnostics().pendingCount, 0)
        await oldProducer.value
        smartCare.cancel()
        professional.cancel()
    }

    /// Presentation-only Tree retirement belongs to local generation/CAS, not the shared
    /// filesystem registry. A different coordinator may acquire its reservation immediately even
    /// while the cancelled presentation task still owns wide in-memory rows.
    func test_crossCoordinatorPresentationOnlyRetirementDoesNotBlockAdmission() async {
        let registry = PrimaryScanAdmissionRegistry()
        let professional = ScanCoordinator(
            primaryScanAdmissionRegistry: registry,
            primaryScanAdmissionClientID: .init()
        )
        let smartCare = ScanCoordinator(
            primaryScanAdmissionRegistry: registry,
            primaryScanAdmissionClientID: .init()
        )
        let probe = SettlementProbe()
        let presentation = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let presentationDidStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(presentationDidStart)
        professional._seedPresentationTreeTaskForSettlementTesting(presentation)
        professional.cancelOnDemandTreeScansPreservingResults()
        let cancellationWasObserved = await eventually { await probe.cancellationObserved }
        XCTAssertTrue(cancellationWasObserved)

        let started = StartedIntentRecorder()
        smartCare._schedulePrimaryScanIntentForTesting(.category("smart-care")) {
            started.append("smart-care")
        }

        XCTAssertEqual(started.values, ["smart-care"])
        XCTAssertEqual(smartCare.scanPhase, .scanning)
        XCTAssertEqual(registry.diagnostics().activeLeaseCount, 0)
        let orderBeforeRelease = await probe.order
        XCTAssertFalse(orderBeforeRelease.contains("first.finish"),
                       "presentation-only retirement must not enter shared admission")

        await probe.releaseCleanup()
        await presentation.value
        smartCare.cancel()
        professional.cancel()
    }

    /// v2026.07.19 regression: admission must close before scanner/session construction. A
    /// replacement can arrive in the reserve -> activate gap; activation must then cancel the
    /// exact producer and keep the replacement queued until that producer truly terminates.
    func test_sharedRegistryLaunchReservationClosesConstructionGap() async {
        let registry = PrimaryScanAdmissionRegistry()
        let firstClient = PrimaryScanAdmissionRegistry.ClientID()
        let secondClient = PrimaryScanAdmissionRegistry.ClientID()
        let secondStarted = StartedIntentRecorder()

        let firstDecision = registry.request(
            clientID: firstClient,
            intent: "first",
            onInvalidated: { _ in [] },
            onAdmitted: { _ in XCTFail("first request must be admitted synchronously") },
            onDiscarded: { [] }
        )
        guard case .admitted(let firstReservation) = firstDecision,
              let launch = registry.reserveProducerLaunch(
                reservation: firstReservation,
                kind: .developerDiscovery
              )
        else { return XCTFail("first producer must reserve the construction gap") }

        let secondDecision = registry.request(
            clientID: secondClient,
            intent: "second",
            onInvalidated: { _ in [] },
            onAdmitted: { _ in secondStarted.append("second") },
            onDiscarded: { [] }
        )
        guard case .queued = secondDecision else {
            return XCTFail("launching producer must already block replacement admission")
        }

        let probe = SettlementProbe()
        let producer = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let termination = Task.detached(priority: .userInitiated) {
            await producer.value
        }
        let lease = registry.activateProducer(
            launch: launch,
            reservation: firstReservation,
            cancel: { producer.cancel() },
            termination: termination,
            requiresPayloadHandoff: false
        )
        XCTAssertNotNil(lease)
        let cancellationObserved = await eventually { await probe.cancellationObserved }
        XCTAssertTrue(cancellationObserved)
        XCTAssertTrue(secondStarted.values.isEmpty)
        XCTAssertEqual(registry.diagnostics().activeLeaseCount, 1)

        await probe.releaseCleanup()
        await termination.value
        let replacementStarted = await eventually { secondStarted.values == ["second"] }
        XCTAssertTrue(replacementStarted)
        XCTAssertEqual(registry.diagnostics().activeLeaseCount, 0)
    }

    /// Repeated UI intent replacement is deliberately O(1) in retained waiters. This larger
    /// cardinality catches accidental reintroduction of one waiting Task per click.
    func test_sharedRegistryHundredRequestsRetainOnlyLatestPendingIntent() async {
        let registry = PrimaryScanAdmissionRegistry()
        let owner = PrimaryScanAdmissionRegistry.ClientID()
        let replacement = PrimaryScanAdmissionRegistry.ClientID()
        let probe = SettlementProbe()
        let producer = Task {
            await probe.markFirstStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            await probe.markCancellationObserved()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let initial = registry.request(
            clientID: owner,
            intent: "owner",
            onInvalidated: { _ in [] },
            onAdmitted: { _ in XCTFail("owner must be admitted synchronously") },
            onDiscarded: { [] }
        )
        guard case .admitted(let reservation) = initial,
              let launch = registry.reserveProducerLaunch(
                reservation: reservation,
                kind: .singleRoot
              ),
              registry.activateProducer(
                launch: launch,
                reservation: reservation,
                cancel: { producer.cancel() },
                termination: producer,
                requiresPayloadHandoff: false
              ) != nil
        else { return XCTFail("fixture producer must become active") }

        let started = StartedIntentRecorder()
        let discarded = IntegerRecorder()
        for index in 0..<100 {
            let decision = registry.request(
                clientID: replacement,
                intent: "replacement-\(index)",
                onInvalidated: { _ in [] },
                onAdmitted: { _ in started.append("replacement-\(index)") },
                onDiscarded: {
                    discarded.increment()
                    return []
                }
            )
            guard case .queued = decision else {
                return XCTFail("request \(index) must remain queued during teardown")
            }
            XCTAssertEqual(registry.diagnostics().pendingCount, 1)
        }
        XCTAssertEqual(discarded.value, 99)
        XCTAssertTrue(started.values.isEmpty)

        await probe.releaseCleanup()
        await producer.value
        let latestStarted = await eventually { started.values == ["replacement-99"] }
        XCTAssertTrue(latestStarted)
        XCTAssertEqual(registry.diagnostics().pendingCount, 0)
    }

    /// A reservation may never be released while a filesystem launch/lease is present. This is
    /// the fail-closed half of the ownership contract and prevents a second heavy walk from
    /// starting merely because presentation code reached its terminal branch early.
    func test_sharedRegistryRejectsPipelineFinishWithOutstandingLaunchLease() {
        let registry = PrimaryScanAdmissionRegistry()
        let decision = registry.request(
            clientID: .init(),
            intent: "owner",
            onInvalidated: { _ in [] },
            onAdmitted: { _ in XCTFail("owner must be admitted synchronously") },
            onDiscarded: { [] }
        )
        guard case .admitted(let reservation) = decision,
              let launch = registry.reserveProducerLaunch(
                reservation: reservation,
                kind: .multiRoot
              )
        else { return XCTFail("fixture launch must be reserved") }

        XCTAssertFalse(registry.finishPipeline(reservation: reservation))
        XCTAssertEqual(registry.diagnostics().activeLeaseCount, 1)
        XCTAssertTrue(registry.diagnostics().hasCurrent)

        registry.abandonProducerLaunch(launch, reservation: reservation)
        XCTAssertTrue(registry.finishPipeline(reservation: reservation))
        XCTAssertFalse(registry.diagnostics().hasCurrent)
    }

    /// Tree filesystem work can outlive a completed primary snapshot. Registering its exact
    /// termination handle while the registry is otherwise idle must still block a new primary
    /// producer; presentation-only work is covered by the separate non-blocking test above.
    func test_sharedRegistryIdleExternalFilesystemSettlementBlocksAdmission() async {
        let registry = PrimaryScanAdmissionRegistry()
        let probe = SettlementProbe()
        let treeProducer = Task {
            await probe.markFirstStarted()
            await probe.waitForCleanupRelease()
            await probe.markFirstFinished()
        }
        let didStart = await eventually { await probe.firstStarted }
        XCTAssertTrue(didStart)
        registry.registerExternalSettlements(
            [treeProducer],
            reason: "idle_tree_fixture"
        )

        let started = StartedIntentRecorder()
        let decision = registry.request(
            clientID: .init(),
            intent: "primary",
            onInvalidated: { _ in [] },
            onAdmitted: { _ in started.append("primary") },
            onDiscarded: { [] }
        )
        guard case .queued = decision else {
            return XCTFail("idle Tree filesystem settlement must block primary admission")
        }
        XCTAssertTrue(started.values.isEmpty)
        XCTAssertEqual(registry.diagnostics().activeLeaseCount, 1)

        await probe.releaseCleanup()
        await treeProducer.value
        let primaryStarted = await eventually { started.values == ["primary"] }
        XCTAssertTrue(primaryStarted)
        XCTAssertEqual(registry.diagnostics().activeLeaseCount, 0)
    }

    func test_settlementStatusPresentationIsActionableAndLocalized() {
        let state = ScanCoordinator.ScanSettlementState(
            intent: .developerArtifacts,
            predecessorGeneration: UUID(),
            intentID: UUID()
        )
        let presentation = ScanCoordinator.ScanPhase
            .settling(state)
            .settlementStatusPresentation
        XCTAssertEqual(
            presentation?.localized(locale: Locale(identifier: "en")),
            "Finishing the previous scan. The new scan will start automatically…"
        )
        XCTAssertEqual(
            presentation?.localized(locale: Locale(identifier: "zh-Hans")),
            "正在结束上一次扫描，随后会自动开始新扫描…"
        )
        XCTAssertNil(ScanCoordinator.ScanPhase.idle.settlementStatusPresentation)
        XCTAssertNil(ScanCoordinator.ScanPhase.scanning.settlementStatusPresentation)
    }

    private func eventually(
        attempts: Int = 200,
        predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

@MainActor
private final class StartedIntentRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class IntegerRecorder {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SettlementProbe {
    private(set) var firstStarted = false
    private(set) var cancellationObserved = false
    private(set) var replacementStarted = false
    private(set) var order: [String] = []
    private var cleanupReleased = false
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

    func markFirstStarted() {
        firstStarted = true
        order.append("first.start")
    }

    func markCancellationObserved() {
        cancellationObserved = true
    }

    func waitForCleanupRelease() async {
        guard !cleanupReleased else { return }
        await withCheckedContinuation { continuation in
            cleanupWaiters.append(continuation)
        }
    }

    func releaseCleanup() {
        cleanupReleased = true
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func markFirstFinished() {
        order.append("first.finish")
    }

    func markReplacementStarted() {
        replacementStarted = true
        order.append("replacement.start")
    }
}
