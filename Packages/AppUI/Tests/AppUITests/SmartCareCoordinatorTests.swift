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

    func test_setSelected_forbid返回false且不进入清理请求() {
        let safe = item("safe", verdict: .safe)
        let forbidden = item("forbid", verdict: .forbid)
        let coordinator = SmartCareCoordinator(summary: summary([safe, forbidden]))

        XCTAssertFalse(coordinator.setSelected(true, itemID: "forbid"))

        let request = coordinator.makeCleanRequest()
        XCTAssertEqual(request.items, [safe])
        XCTAssertEqual(request.paths, ["/tmp/safe"])
        XCTAssertFalse(request.requiresConfirmation)
    }

    func test_setSafeItemsSelected_桶级更新不影响其他桶() {
        let target = item("target", bucket: .appCache, verdict: .safe)
        let other = item("other", bucket: .developerCache, verdict: .safe)
        let snapshot = SmartCareSummary(buckets: [
            SmartCareBucketSummary(id: .appCache, items: [target]),
            SmartCareBucketSummary(id: .developerCache, items: [other])
        ])
        let coordinator = SmartCareCoordinator(summary: snapshot)

        coordinator.setSafeItemsSelected(false, bucketID: .appCache)

        XCTAssertFalse(coordinator.selection.isSelected(target))
        XCTAssertTrue(coordinator.selection.isSelected(other))
        XCTAssertNil(coordinator.selectedBucketStats[.appCache])
        XCTAssertEqual(
            coordinator.selectedBucketStats[.developerCache],
            SmartCareBucketSelectionStats(count: 1, bytes: 100)
        )
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

    func test_prepareClean_只有safe时直接进入cleaning并返回request() {
        let safe = item("safe", bytes: 123, verdict: .safe)
        let coordinator = SmartCareCoordinator(summary: summary([safe]))

        let request = coordinator.prepareClean()

        XCTAssertEqual(request?.items, [safe])
        XCTAssertEqual(request?.totalBytes, 123)
        XCTAssertEqual(coordinator.phase.primaryAction, .cleaning)
    }

    func test_prepareClean_含confirm时进入confirming且不返回request() {
        let safe = item("safe", verdict: .safe)
        let confirm = item("confirm", verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([safe, confirm]))
        XCTAssertTrue(coordinator.setSelected(true, itemID: "confirm"))

        let request = coordinator.prepareClean()

        XCTAssertNil(request)
        XCTAssertEqual(coordinator.phase.primaryAction, .confirmClean)
        XCTAssertEqual(coordinator.selectedConfirmCount, 1)
    }

    func test_confirmClean_返回含confirm的request并进入cleaning() {
        let confirm = item("confirm", verdict: .confirm)
        let coordinator = SmartCareCoordinator(summary: summary([confirm]))
        XCTAssertTrue(coordinator.setSelected(true, itemID: "confirm"))
        XCTAssertNil(coordinator.prepareClean())

        let request = coordinator.confirmClean()

        XCTAssertEqual(request?.items, [confirm])
        XCTAssertTrue(request?.requiresConfirmation ?? false)
        XCTAssertEqual(request?.confirmCount, 1)
        XCTAssertEqual(coordinator.phase.primaryAction, .cleaning)
    }

    func test_completeCleaning_可接收剩余summary并清理已移除项选择() {
        let moved = item("moved", verdict: .safe)
        let remaining = item("remaining", verdict: .safe)
        let coordinator = SmartCareCoordinator(summary: summary([moved, remaining]))

        coordinator.completeCleaning(
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
}
