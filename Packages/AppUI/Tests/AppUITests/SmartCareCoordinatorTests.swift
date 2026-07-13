import Dispatch
import Foundation
import XCTest
@testable import AppUI
import SafetyKit

@MainActor
final class SmartCareCoordinatorTests: XCTestCase {
    private func item(_ id: String,
                      bucket: SmartCareBucketID = .systemJunk,
                      bytes: Int64 = 100,
                      verdict: SafetyVerdict) -> SmartCareItem {
        SmartCareItem(
            id: id,
            bucketID: bucket,
            path: "/tmp/\(id)",
            title: id,
            bytes: bytes,
            verdict: verdict
        )
    }

    private func summary(_ items: [SmartCareItem]) -> SmartCareSummary {
        SmartCareSummary(buckets: [
            SmartCareBucketSummary(id: .systemJunk, items: items)
        ])
    }

    func test_init_有summary时进入reviewing并默认选择safe() {
        let safe = item("safe", verdict: .safe)
        let confirm = item("confirm", verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([safe, confirm]))

        XCTAssertEqual(coordinator.phase.primaryAction, .cleanSafeItems)
        XCTAssertEqual(coordinator.selectedItems, [safe])
        XCTAssertEqual(coordinator.selectedBytes, 100)
        XCTAssertEqual(
            coordinator.selectedBucketStats[.systemJunk],
            SmartCareBucketSelectionStats(count: 1, bytes: 100)
        )
    }

    func test_beginScan_清空旧summary和selection() {
        let coordinator = SmartCareCoordinator(summary: summary([
            item("safe", verdict: .safe)
        ]))

        coordinator.beginScan()

        XCTAssertEqual(coordinator.summary, .empty)
        XCTAssertEqual(coordinator.selectedItems, [])
        XCTAssertEqual(coordinator.selectedBucketStats, [:])
        XCTAssertEqual(coordinator.phase.primaryAction, .stopScan)
    }

    func test_finishScan_新扫描重置为默认safe选择() {
        let safe = item("safe", verdict: .safe)
        let coordinator = SmartCareCoordinator(summary: summary([safe]))
        XCTAssertTrue(coordinator.setSelected(false, itemID: "safe"))

        coordinator.finishScan(summary([safe]))

        XCTAssertEqual(coordinator.selectedItems, [safe],
                       "新一轮扫描应重置为默认 safe 选择；保留用户意图只用于同一结果重聚合")
    }

    func test_replaceSummaryPreservingSelection_保留用户取消safe和勾选confirm() {
        let safeV1 = item("safe", bytes: 100, verdict: .safe)
        let confirmV1 = item("confirm", bytes: 200, verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([safeV1, confirmV1]))

        XCTAssertTrue(coordinator.setSelected(false, itemID: "safe"))
        XCTAssertTrue(coordinator.setSelected(true, itemID: "confirm"))

        let safeV2 = item("safe", bytes: 300, verdict: .safe)
        let confirmV2 = item("confirm", bytes: 400, verdict: .confirm)
        coordinator.replaceSummaryPreservingSelection(summary([safeV2, confirmV2]))

        XCTAssertEqual(coordinator.selectedItems, [confirmV2])
        XCTAssertEqual(coordinator.selectedBytes, 400)
        XCTAssertEqual(coordinator.selectedConfirmCount, 1)
    }

    func test_setSelected_forbid返回false且不进入清理请求() async throws {
        let safe = item("safe", verdict: .safe)
        let forbidden = item("forbid", verdict: .forbid)
        let coordinator = SmartCareCoordinator(summary: summary([safe, forbidden]))

        XCTAssertFalse(coordinator.setSelected(true, itemID: "forbid"))

        let request = try await coordinator.makeCleanRequest()
        XCTAssertEqual(request.items, [safe])
        XCTAssertEqual(request.paths, ["/tmp/safe"])
        XCTAssertFalse(request.requiresConfirmation)
    }

    func test_setSafeItemsSelected_桶级更新不影响其他桶() async {
        let target = item("target", bucket: .appCache, verdict: .safe)
        let other = item("other", bucket: .developerCache, verdict: .safe)
        let snapshot = SmartCareSummary(buckets: [
            SmartCareBucketSummary(id: .appCache, items: [target]),
            SmartCareBucketSummary(id: .developerCache, items: [other])
        ])
        let coordinator = SmartCareCoordinator(summary: snapshot)

        await coordinator.setSafeItemsSelected(false, bucketID: .appCache)

        XCTAssertFalse(coordinator.selection.isSelected(target))
        XCTAssertTrue(coordinator.selection.isSelected(other))
        XCTAssertNil(coordinator.selectedBucketStats[.appCache])
        XCTAssertEqual(
            coordinator.selectedBucketStats[.developerCache],
            SmartCareBucketSelectionStats(count: 1, bytes: 100)
        )
    }

    func test_setSafeItemsSelected_keepsMainActorHeartbeatResponsive() async {
        let workerStarted = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let safe = item("safe", bucket: .appCache, verdict: .safe)
        let snapshot = SmartCareSummary(buckets: [
            SmartCareBucketSummary(id: .appCache, items: [safe])
        ])
        let coordinator = SmartCareCoordinator(
            summary: snapshot,
            projectionBuilder: { selection, items in
                workerStarted.signal()
                guard releaseWorker.wait(timeout: .now() + 2) == .success else {
                    throw SmartCareProjectionHeartbeatError.workerReleaseTimedOut
                }
                return try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )
        var toggleFinished = false
        let toggle = Task { @MainActor in
            await coordinator.setSafeItemsSelected(false, bucketID: .appCache)
            toggleFinished = true
        }
        let started = await Task.detached {
            waitForSmartCareSemaphore(workerStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(started, .success)

        let heartbeatObservedPendingToggle = await Task { @MainActor in
            let wasPending = !toggleFinished
            releaseWorker.signal()
            return wasPending
        }.value
        XCTAssertTrue(heartbeatObservedPendingToggle)
        await toggle.value
        XCTAssertTrue(toggleFinished)
        XCTAssertFalse(coordinator.selection.isSelected(safe))
    }

    func test_setSafeItemsSelected_rapidToggleCommitsLatestIntent() async {
        let deselectStarted = DispatchSemaphore(value: 0)
        let selectStarted = DispatchSemaphore(value: 0)
        let releaseDeselect = DispatchSemaphore(value: 0)
        let releaseSelect = DispatchSemaphore(value: 0)
        let safe = item("safe", bucket: .appCache, verdict: .safe)
        let snapshot = SmartCareSummary(buckets: [
            SmartCareBucketSummary(id: .appCache, items: [safe])
        ])
        let coordinator = SmartCareCoordinator(
            summary: snapshot,
            projectionBuilder: { selection, items in
                if selection.selectedIDs.contains(safe.id) {
                    selectStarted.signal()
                    guard releaseSelect.wait(timeout: .now() + 2) == .success else {
                        throw SmartCareProjectionHeartbeatError.workerReleaseTimedOut
                    }
                } else {
                    deselectStarted.signal()
                    guard releaseDeselect.wait(timeout: .now() + 2) == .success else {
                        throw SmartCareProjectionHeartbeatError.workerReleaseTimedOut
                    }
                }
                return try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )

        let first = Task { @MainActor in
            await coordinator.setSafeItemsSelected(false, bucketID: .appCache)
        }
        let didStartDeselect = await Task.detached {
            waitForSmartCareSemaphore(deselectStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(didStartDeselect, .success)
        let second = Task { @MainActor in
            await coordinator.setSafeItemsSelected(true, bucketID: .appCache)
        }
        let didStartSelect = await Task.detached {
            waitForSmartCareSemaphore(selectStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(didStartSelect, .success)

        // 后发的“选中”先完成，再释放旧“取消” worker。
        // 旧 worker 必须因 request revision 过期而丢弃，不能覆盖最新意图。
        releaseSelect.signal()
        await second.value
        releaseDeselect.signal()
        await first.value
        XCTAssertTrue(coordinator.selection.isSelected(safe))
    }

    func test_setSelected_增量更新对应桶统计() {
        let safe = item("safe", bucket: .appCache, bytes: 120, verdict: .safe)
        let confirm = item("confirm", bucket: .appCache, bytes: 80, verdict: .confirm)
        let snapshot = SmartCareSummary(buckets: [
            SmartCareBucketSummary(id: .appCache, items: [safe, confirm])
        ])
        let coordinator = SmartCareCoordinator(summary: snapshot)

        XCTAssertTrue(coordinator.setSelected(true, item: confirm))
        XCTAssertEqual(
            coordinator.selectedBucketStats[.appCache],
            SmartCareBucketSelectionStats(count: 2, bytes: 200)
        )

        XCTAssertTrue(coordinator.setSelected(false, item: safe))
        XCTAssertEqual(
            coordinator.selectedBucketStats[.appCache],
            SmartCareBucketSelectionStats(count: 1, bytes: 80)
        )
    }

    func test_prepareClean_只有safe时直接进入cleaning并返回request() async throws {
        let safe = item("safe", bytes: 123, verdict: .safe)
        let coordinator = SmartCareCoordinator(summary: summary([safe]))

        let request = try await coordinator.prepareClean()

        XCTAssertEqual(request?.items, [safe])
        XCTAssertEqual(request?.totalBytes, 123)
        XCTAssertEqual(coordinator.phase.primaryAction, .cleaning)
    }

    func test_prepareClean_含confirm时进入confirming且不返回request() async throws {
        let safe = item("safe", verdict: .safe)
        let confirm = item("confirm", verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([safe, confirm]))
        XCTAssertTrue(coordinator.setSelected(true, itemID: "confirm"))

        let request = try await coordinator.prepareClean()

        XCTAssertNil(request)
        XCTAssertEqual(coordinator.phase.primaryAction, .confirmClean)
        XCTAssertEqual(coordinator.selectedConfirmCount, 1)
    }

    func test_confirmClean_返回含confirm的request并进入cleaning() async throws {
        let confirm = item("confirm", verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([confirm]))
        XCTAssertTrue(coordinator.setSelected(true, itemID: "confirm"))
        let request = try await coordinator.makeCleanRequest()
        let prepared = try await coordinator.prepareClean()
        XCTAssertNil(prepared)
        XCTAssertTrue(coordinator.confirmClean(request))

        XCTAssertEqual(request.items, [confirm])
        XCTAssertTrue(request.requiresConfirmation)
        XCTAssertEqual(request.confirmCount, 1)
        XCTAssertEqual(coordinator.phase.primaryAction, .cleaning)
    }

    func test_confirmClean_拒绝sheet展示后扩张的选择() async throws {
        let safe = item("safe", verdict: .safe)
        let confirm = item("confirm", verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([safe, confirm]))
        let previewedRequest = try await coordinator.makeCleanRequest()
        XCTAssertEqual(previewedRequest.items, [safe])

        XCTAssertTrue(coordinator.setSelected(true, itemID: confirm.id))

        XCTAssertFalse(coordinator.confirmClean(previewedRequest),
                       "确认必须绑定 sheet 展示的 revision，不能静默加入后来勾选项")
        XCTAssertEqual(coordinator.phase.primaryAction, .cleanSafeItems)
        let refreshedRequest = try await coordinator.makeCleanRequest()
        XCTAssertEqual(refreshedRequest.items, [safe, confirm])
        XCTAssertTrue(coordinator.confirmClean(refreshedRequest))
    }

    func test_completeCleaning_可接收剩余summary并清理已移除项选择() async {
        let moved = item("moved", verdict: .safe)
        let remaining = item("remaining", verdict: .safe)
        let coordinator = SmartCareCoordinator(summary: summary([moved, remaining]))

        await coordinator.completeCleaning(
            SmartCareResult(movedCount: 1, skippedCount: 0, releasedBytes: 100),
            remainingSummary: summary([remaining])
        )

        XCTAssertEqual(coordinator.summary.items, [remaining])
        XCTAssertEqual(coordinator.selectedItems, [remaining])
        XCTAssertEqual(coordinator.phase.primaryAction, .scanAgain)
    }

    func test_cancel_有summary时保留partial_空summary时partial为nil() {
        let coordinator = SmartCareCoordinator(summary: summary([item("safe", verdict: .safe)]))
        coordinator.cancel()

        if case let .cancelled(partial) = coordinator.phase {
            XCTAssertEqual(partial?.items.count, 1)
        } else {
            XCTFail("应进入 cancelled")
        }

        coordinator.reset()
        coordinator.cancel()
        if case let .cancelled(partial) = coordinator.phase {
            XCTAssertNil(partial)
        } else {
            XCTFail("应进入 cancelled")
        }
    }

    func test_offMainCheckpointPublish_preservesOverrideAndMetricsContract() async throws {
        let safeV1 = item("safe", bytes: 100, verdict: .safe)
        let confirmV1 = item("confirm", bytes: 200, verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([safeV1, confirmV1]))
        XCTAssertTrue(coordinator.setSelected(false, itemID: safeV1.id))
        XCTAssertTrue(coordinator.setSelected(true, itemID: confirmV1.id))
        coordinator.resumeScan(SmartCareProgress())

        let safeV2 = item("safe", bytes: 300, verdict: .safe)
        let confirmV2 = item("confirm", bytes: 400, verdict: .confirm)
        try await coordinator.publishScanCheckpointOffMainActor(
            summary([safeV2, confirmV2]),
            progress: SmartCareProgress(completedStages: [.core])
        )

        XCTAssertEqual(coordinator.selectedItems, [confirmV2])
        XCTAssertEqual(coordinator.selectedBytes, 400)
        XCTAssertEqual(coordinator.selectedConfirmCount, 1)
        XCTAssertEqual(
            coordinator.selectedBucketStats[.systemJunk],
            SmartCareBucketSelectionStats(count: 1, bytes: 400)
        )
        guard case .scanning(let progress) = coordinator.phase else {
            return XCTFail("Expected scanning checkpoint phase")
        }
        XCTAssertEqual(progress.completedStages, [.core])
    }

    func test_offMainCheckpointPublish_20200ItemsCompletesWithinBudget() async throws {
        let count = 20_200
        let items = (0..<count).map { index in
            SmartCareItem(
                id: "item-\(index)",
                bucketID: .systemJunk,
                path: "/tmp/item-\(index)",
                title: "item-\(index)",
                bytes: Int64(index + 1),
                verdict: index.isMultiple(of: 5) ? .confirm : .safe
            )
        }
        let largeSummary = summary(items)
        let coordinator = SmartCareCoordinator()
        coordinator.beginScan()
        let started = Date()

        try await coordinator.publishScanCheckpointOffMainActor(
            largeSummary,
            progress: SmartCareProgress(completedStages: [.core])
        )

        let elapsed = Date().timeIntervalSince(started)
        let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        XCTAssertLessThan(
            elapsed,
            isCI ? 2.0 : 1.0,
            "20,200-item selection reconcile/metrics should stay within the checkpoint budget"
        )
        XCTAssertEqual(coordinator.summary.items.count, count)
        XCTAssertEqual(coordinator.selectedItems.count, count - (count / 5))
    }

    func test_offMainCheckpointProjection_keepsMainActorHeartbeatResponsive() async throws {
        let workerStarted = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let coordinator = SmartCareCoordinator(
            summary: .empty,
            projectionBuilder: { selection, items in
                workerStarted.signal()
                guard releaseWorker.wait(timeout: .now() + 2) == .success else {
                    throw SmartCareProjectionHeartbeatError.workerReleaseTimedOut
                }
                return try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )
        coordinator.beginScan()
        let nextSummary = summary([item("heartbeat", verdict: .safe)])
        var publicationFinished = false
        let publication = Task { @MainActor in
            try await coordinator.publishScanCheckpointOffMainActor(
                nextSummary,
                progress: SmartCareProgress(completedStages: [.core])
            )
            publicationFinished = true
        }

        let started = await Task.detached {
            waitForSmartCareSemaphore(workerStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(started, .success)

        // worker 在 gate 内挂起时，MainActor 必须仍能运行 heartbeat 并解锁它。
        // 如果 projection 意外回到主线，这里会因无人 signal 而超时。
        let heartbeatObservedPendingPublication = await Task { @MainActor in
            let wasPending = !publicationFinished
            releaseWorker.signal()
            return wasPending
        }.value
        XCTAssertTrue(heartbeatObservedPendingPublication)
        try await publication.value
        XCTAssertTrue(publicationFinished)
        XCTAssertEqual(coordinator.summary, nextSummary)
    }

    func test_makeCleanRequest_keepsMainActorHeartbeatResponsive() async throws {
        let workerStarted = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let safe = item("request-heartbeat", verdict: .safe)
        let coordinator = SmartCareCoordinator(
            summary: summary([safe]),
            projectionBuilder: { selection, items in
                try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            },
            cleanRequestBuilder: { selection, items in
                workerStarted.signal()
                guard releaseWorker.wait(timeout: .now() + 2) == .success else {
                    throw SmartCareProjectionHeartbeatError.workerReleaseTimedOut
                }
                return try SmartCareCoordinator.cleanRequestCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )
        var requestFinished = false
        let requestTask = Task { @MainActor in
            let request = try await coordinator.makeCleanRequest()
            requestFinished = true
            return request
        }
        let started = await Task.detached {
            waitForSmartCareSemaphore(workerStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(started, .success)

        let heartbeatObservedPendingRequest = await Task { @MainActor in
            let wasPending = !requestFinished
            releaseWorker.signal()
            return wasPending
        }.value
        XCTAssertTrue(heartbeatObservedPendingRequest)
        let request = try await requestTask.value
        XCTAssertTrue(requestFinished)
        XCTAssertEqual(request.items, [safe])
    }

    func test_finishPublishedScan_reusesFinalCheckpointProjectionWithoutSecondBuild() async throws {
        let projectionBuilt = DispatchSemaphore(value: 0)
        let coordinator = SmartCareCoordinator(
            summary: .empty,
            projectionBuilder: { selection, items in
                projectionBuilt.signal()
                return try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )
        coordinator.beginScan()
        let finalSummary = summary([item("final", verdict: .safe)])
        try await coordinator.publishScanCheckpointOffMainActor(
            finalSummary,
            progress: SmartCareProgress(completedStages: [.core])
        )
        XCTAssertEqual(
            waitForSmartCareSemaphore(projectionBuilt, timeout: .now()),
            .success
        )

        XCTAssertTrue(
            coordinator.finishPublishedScan(
                expectedSummaryRevision: coordinator.summaryRevision
            )
        )
        XCTAssertEqual(
            waitForSmartCareSemaphore(projectionBuilt, timeout: .now()),
            .timedOut,
            "Final phase commit must reuse the already published checkpoint projection"
        )
        guard case .reviewing(let published) = coordinator.phase else {
            return XCTFail("Expected reviewing phase")
        }
        XCTAssertEqual(published, finalSummary)
    }
}

private enum SmartCareProjectionHeartbeatError: Error {
    case workerReleaseTimedOut
}

private func waitForSmartCareSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}
