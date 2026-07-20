import XCTest
@testable import AppUI

/// v2026.07.19 regression coverage: Tree generation/token checks prevent stale writes, but they
/// do not prevent an already-running filesystem producer from overlapping its replacement. These
/// tests exercise the path-scoped producer boundary independently of cache/sort presentation.
@MainActor
final class TreeFilesystemLeaseDomainTests: XCTestCase {
    func test_componentSafeIdentityUsesStandardizedPublicAndPhysicalPaths() {
        XCTAssertTrue(ScanCoordinator._treeFilesystemPathsOverlapForTesting(
            publicPath: "/Users/one/../one",
            physicalPath: "/System/Volumes/Data/Users/one",
            otherPublicPath: "/Users/one/Library",
            otherPhysicalPath: "/System/Volumes/Data/Users/one/Library"
        ))
        XCTAssertFalse(ScanCoordinator._treeFilesystemPathsOverlapForTesting(
            publicPath: "/Users",
            physicalPath: "/System/Volumes/Data/Users",
            otherPublicPath: "/Users2",
            otherPhysicalPath: "/System/Volumes/Data/Users2"
        ))
        XCTAssertTrue(ScanCoordinator._treeFilesystemPathsOverlapForTesting(
            publicPath: "/Visible/A",
            physicalPath: "/System/Volumes/Data/Shared",
            otherPublicPath: "/Visible/B",
            otherPhysicalPath: "/System/Volumes/Data/Shared/Child"
        ), "physical aliases of one subtree must serialize even when public paths differ")
    }

    func test_samePathDifferentSortWaitsForRealProducerTermination() async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let release = AsyncTestLatch()

        let first = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users/example",
                sort: .sizeDesc,
                stage: "deep"
            ) {
                await events.append("first.start")
                await release.wait()
                await events.append("first.finish")
            }
        }
        await assertEventually { await events.contains("first.start") }

        let second = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users/example",
                sort: .nameAsc,
                stage: "shallow"
            ) {
                await events.append("second.start")
            }
        }
        await assertEventually {
            await coordinator._treeFilesystemLeaseDiagnosticsForTesting().waiting == 1
        }
        let secondStartedWhileBlocked = await events.contains("second.start")
        XCTAssertFalse(secondStartedWhileBlocked,
                       "sort is presentation only and must not create a second measurement owner")

        await release.open()
        _ = await first.value
        _ = await second.value
        let finalEvents = await events.snapshot()
        XCTAssertEqual(finalEvents, [
            "first.start", "first.finish", "second.start"
        ])
    }

    func test_ancestorAndDescendantBothWaitWhilePrefixSiblingStartsImmediately() async throws {
        try await assertOverlappingLeaseOrder(
            firstPath: "/Users/example",
            secondPath: "/Users/example/Library"
        )
        try await assertOverlappingLeaseOrder(
            firstPath: "/Users/example/Library",
            secondPath: "/Users/example"
        )

        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let release = AsyncTestLatch()
        let first = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users",
                operation: {
                    await events.append("users.start")
                    await release.wait()
                }
            )
        }
        await assertEventually { await events.contains("users.start") }
        let unrelated = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users2",
                operation: { await events.append("users2.start") }
            )
        }
        await assertEventually(
            "component prefix siblings must not serialize"
        ) { await events.contains("users2.start") }
        let unrelatedCompleted = await unrelated.value
        XCTAssertTrue(unrelatedCompleted)
        await release.open()
        _ = await first.value
    }

    func test_distinctPublicPathsWaitWhenPhysicalSubtreesOverlap() async throws {
        try await assertOverlappingLeaseOrder(
            firstPath: "/Visible/A",
            firstPhysicalPath: "/System/Volumes/Data/Shared",
            secondPath: "/Visible/B",
            secondPhysicalPath: "/System/Volumes/Data/Shared/Child"
        )
    }

    func test_pendingOverlapCancellationNeverConsumesTreeGatePermit() async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let release = AsyncTestLatch()
        let first = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users/example",
                usesTreeGate: true
            ) {
                await events.append("first.start")
                await release.wait()
            }
        }
        await assertEventually { await events.contains("first.start") }
        await assertEventually {
            let gate = await ScanCoordinator._treeFilesystemGateDiagnosticsForTesting()
            return gate.active == 1 && gate.waiting == 0
        }

        let pending = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users/example/Library",
                usesTreeGate: true,
                operation: { await events.append("pending.start") }
            )
        }
        await assertEventually {
            await coordinator._treeFilesystemLeaseDiagnosticsForTesting().waiting == 1
        }
        let gateWhilePathPending = await ScanCoordinator
            ._treeFilesystemGateDiagnosticsForTesting()
        XCTAssertEqual(gateWhilePathPending.active, 1)
        XCTAssertEqual(gateWhilePathPending.waiting, 0,
                       "path admission must happen before bounded gate admission")

        pending.cancel()
        await assertEventually {
            let lease = await coordinator._treeFilesystemLeaseDiagnosticsForTesting()
            return lease.waiting == 0 && lease.reserved == 0
        }
        let pendingCompleted = await pending.value
        let pendingStarted = await events.contains("pending.start")
        XCTAssertFalse(pendingCompleted)
        XCTAssertFalse(pendingStarted)
        let gateAfterPendingCancel = await ScanCoordinator
            ._treeFilesystemGateDiagnosticsForTesting()
        XCTAssertEqual(gateAfterPendingCancel.active, 1)
        XCTAssertEqual(gateAfterPendingCancel.waiting, 0)

        await release.open()
        _ = await first.value
        await assertEventually {
            let gate = await ScanCoordinator._treeFilesystemGateDiagnosticsForTesting()
            return gate.active == 0 && gate.waiting == 0
        }
    }

    func test_primaryCancellationHandleWaitsForProducerCleanup() async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let releaseCleanup = AsyncTestLatch()
        let producer = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users/example",
                stage: "deep",
                tracksPrimaryOwner: true
            ) {
                await events.append("producer.start")
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await events.append("producer.cancel")
                }
                await releaseCleanup.wait()
                await events.append("producer.finish")
            }
        }
        await assertEventually { await events.contains("producer.start") }

        let settlements = coordinator._cancelAllTreeChildrenFetchesForTesting()
        XCTAssertEqual(settlements.count, 1,
                       "primary cancellation must snapshot the exact Tree filesystem domain")
        let settlement = try XCTUnwrap(settlements.first)
        let settlementObserver = Task {
            await settlement.value
            await events.append("settlement.finish")
        }
        await assertEventually { await events.contains("producer.cancel") }
        let settlementFinishedBeforeCleanup = await events.contains("settlement.finish")
        XCTAssertFalse(settlementFinishedBeforeCleanup,
                       "primary admission must await actual producer return, not cancellation request")

        await releaseCleanup.open()
        _ = await producer.value
        await settlementObserver.value
        let finalEvents = await events.snapshot()
        XCTAssertEqual(finalEvents, [
            "producer.start", "producer.cancel", "producer.finish", "settlement.finish"
        ])
    }

    func test_cancelAllDrainDropsNewLeaseWithoutStartingProducer() async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let releaseCleanup = AsyncTestLatch()
        let producer = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: "/Users/example",
                stage: "deep"
            ) {
                await events.append("producer.start")
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await events.append("producer.cancel")
                }
                await releaseCleanup.wait()
                await events.append("producer.finish")
            }
        }
        await assertEventually { await events.contains("producer.start") }

        let settlement = coordinator._cancelTreeFilesystemLeaseDomainForTesting()
        await assertEventually { await events.contains("producer.cancel") }
        let replacement = await coordinator._runTreeFilesystemLeaseForTesting(
            publicPath: "/Users/unrelated",
            stage: "shallow"
        ) {
            await events.append("replacement.start")
        }
        XCTAssertFalse(replacement,
                       "cancel-all must close admission until its filesystem snapshot settles")
        let replacementStarted = await events.contains("replacement.start")
        XCTAssertFalse(replacementStarted)

        await releaseCleanup.open()
        _ = await producer.value
        await settlement.value
    }

    func test_presentationOwnerIsCancelledButNeverReturnedAsFilesystemSettlement() async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let release = AsyncTestLatch()
        let presentation = Task {
            await events.append("presentation.start")
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                await events.append("presentation.cancel")
            }
            await release.wait()
            await events.append("presentation.finish")
        }
        await assertEventually { await events.contains("presentation.start") }
        coordinator._seedPresentationTreeTaskForSettlementTesting(presentation)

        let settlements = coordinator._cancelAllTreeChildrenFetchesForTesting()
        XCTAssertTrue(settlements.isEmpty,
                      "cache/sort/presentation retirement must not delay primary admission")
        await assertEventually { await events.contains("presentation.cancel") }
        await release.open()
        await presentation.value
    }

    func test_indexedRefreshOwnershipIsPathScopedAndLatestOverlapWins() async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let releaseA = AsyncTestLatch()
        let releaseB = AsyncTestLatch()
        let releasePrefix = AsyncTestLatch()

        let ownerA = makeCancellableOwner(
            name: "a",
            events: events,
            release: releaseA
        )
        let ownerB = makeCancellableOwner(
            name: "b",
            events: events,
            release: releaseB
        )
        let prefixSibling = makeCancellableOwner(
            name: "prefix",
            events: events,
            release: releasePrefix
        )
        coordinator._seedIndexedSubtreeOwnerForTesting(
            publicPath: "/Users/A",
            owner: ownerA
        )
        let nonOverlap = coordinator._seedIndexedSubtreeOwnerForTesting(
            publicPath: "/Users/B",
            owner: ownerB
        )
        let prefixResult = coordinator._seedIndexedSubtreeOwnerForTesting(
            publicPath: "/Users2",
            owner: prefixSibling
        )
        XCTAssertEqual(nonOverlap.cancelledProducers, 0)
        XCTAssertEqual(prefixResult.cancelledProducers, 0)
        XCTAssertEqual(coordinator._indexedSubtreeRequestPathsForTesting(), [
            "/Users/A", "/Users/B", "/Users2"
        ])

        let replacementRelease = AsyncTestLatch()
        let replacement = makeCancellableOwner(
            name: "replacement",
            events: events,
            release: replacementRelease
        )
        let replacementResult = coordinator._seedIndexedSubtreeOwnerForTesting(
            publicPath: "/Users",
            owner: replacement
        )
        XCTAssertEqual(replacementResult.replacedRequests, 2)
        XCTAssertEqual(replacementResult.cancelledProducers, 2)
        XCTAssertEqual(coordinator._indexedSubtreeRequestPathsForTesting(), [
            "/Users", "/Users2"
        ])
        await assertEventually {
            let snapshot = await events.snapshot()
            return snapshot.contains("a.cancel") && snapshot.contains("b.cancel")
        }
        let prefixWasCancelled = await events.contains("prefix.cancel")
        XCTAssertFalse(prefixWasCancelled,
                       "same string prefix is not a filesystem subtree overlap")

        await releaseA.open()
        await releaseB.open()
        await releasePrefix.open()
        await replacementRelease.open()
        await ownerA.value
        await ownerB.value
        await prefixSibling.value
        await replacement.value
        for handle in coordinator._cancelAllTreeChildrenFetchesForTesting() {
            await handle.value
        }
    }

    private func assertOverlappingLeaseOrder(
        firstPath: String,
        firstPhysicalPath: String? = nil,
        secondPath: String,
        secondPhysicalPath: String? = nil
    ) async throws {
        let coordinator = ScanCoordinator()
        let events = LeaseEventRecorder()
        let release = AsyncTestLatch()
        let first = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: firstPath,
                physicalPath: firstPhysicalPath,
                operation: {
                    await events.append("first.start")
                    await release.wait()
                    await events.append("first.finish")
                }
            )
        }
        await assertEventually { await events.contains("first.start") }
        let second = Task {
            await coordinator._runTreeFilesystemLeaseForTesting(
                publicPath: secondPath,
                physicalPath: secondPhysicalPath,
                operation: { await events.append("second.start") }
            )
        }
        await assertEventually {
            await coordinator._treeFilesystemLeaseDiagnosticsForTesting().waiting == 1
        }
        let secondStartedWhileBlocked = await events.contains("second.start")
        XCTAssertFalse(secondStartedWhileBlocked)
        await release.open()
        _ = await first.value
        _ = await second.value
        let finalEvents = await events.snapshot()
        XCTAssertEqual(finalEvents, [
            "first.start", "first.finish", "second.start"
        ])
    }

    private func makeCancellableOwner(
        name: String,
        events: LeaseEventRecorder,
        release: AsyncTestLatch
    ) -> Task<Void, Never> {
        Task {
            await events.append("\(name).start")
            await withTaskCancellationHandler {
                await release.wait()
            } onCancel: {
                Task { await events.append("\(name).cancel") }
            }
            await events.append("\(name).finish")
        }
    }

    private func eventually(
        attempts: Int = 300,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func assertEventually(
        _ message: String = "condition did not become true before the deterministic timeout",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let succeeded = await eventually(condition)
        XCTAssertTrue(succeeded, message, file: file, line: line)
    }
}

private actor AsyncTestLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

private actor LeaseEventRecorder {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func contains(_ value: String) -> Bool { values.contains(value) }
    func snapshot() -> [String] { values }
}
