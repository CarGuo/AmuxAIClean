import Dispatch
import Foundation
import XCTest
@testable import AppUI
import SafetyKit

final class SmartCareModelsTests: XCTestCase {
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
            verdict: verdict,
            riskNote: nil
        )
    }

    func test_summary_按三色聚合容量和数量() {
        let bucket = SmartCareBucketSummary(id: .systemJunk, items: [
            item("safe-a", bytes: 10, verdict: .safe),
            item("safe-b", bytes: 20, verdict: .safe),
            item("confirm", bytes: 30, verdict: .confirm),
            item("forbid", bytes: 40, verdict: .forbid)
        ])
        let summary = SmartCareSummary(buckets: [bucket])

        XCTAssertEqual(summary.safeBytes, 30)
        XCTAssertEqual(summary.confirmBytes, 30)
        XCTAssertEqual(summary.forbidBytes, 40)
        XCTAssertEqual(summary.totalBytes, 100)
        XCTAssertEqual(summary.forbiddenCount, 1)
        XCTAssertEqual(bucket.safeCount, 2)
        XCTAssertEqual(bucket.confirmCount, 1)
        XCTAssertEqual(bucket.forbidCount, 1)
    }

    func test_selection_默认只勾选safe() {
        let safe = item("safe", verdict: .safe)
        let confirm = item("confirm", verdict: .confirm)
        let forbid = item("forbid", verdict: .forbid)

        let selection = SmartCareSelection(items: [safe, confirm, forbid])

        XCTAssertTrue(selection.isSelected(safe))
        XCTAssertFalse(selection.isSelected(confirm))
        XCTAssertFalse(selection.isSelected(forbid))
        XCTAssertEqual(selection.selectedItems(in: [safe, confirm, forbid]), [safe])
    }

    func test_selection_confirm可由用户主动勾选() {
        let confirm = item("confirm", bytes: 88, verdict: .confirm)
        var selection = SmartCareSelection(items: [confirm])

        XCTAssertTrue(selection.setSelected(true, item: confirm))

        XCTAssertTrue(selection.isSelected(confirm))
        XCTAssertEqual(selection.selectedConfirmCount(in: [confirm]), 1)
        XCTAssertEqual(selection.selectedBytes(in: [confirm]), 88)
    }

    func test_selection_forbid永远不可勾选() {
        let forbid = item("forbid", verdict: .forbid)
        var selection = SmartCareSelection(items: [forbid])

        XCTAssertFalse(selection.setSelected(true, item: forbid))

        XCTAssertFalse(selection.isSelected(forbid))
        XCTAssertEqual(selection.selectedItems(in: [forbid]), [])
        XCTAssertEqual(selection.userOverriddenIDs, [])
    }

    func test_selection_用户取消safe后_reconcile不会重新勾回() {
        let safeV1 = item("safe", bytes: 100, verdict: .safe)
        let safeV2 = item("safe", bytes: 200, verdict: .safe)
        var selection = SmartCareSelection(items: [safeV1])

        XCTAssertTrue(selection.isSelected(safeV1))
        XCTAssertTrue(selection.setSelected(false, item: safeV1))
        selection.reconcile(with: [safeV2])

        XCTAssertFalse(selection.isSelected(safeV2),
                       "用户手动取消过的 safe 项，重新聚合后不能被默认选择逻辑勾回")
        XCTAssertEqual(selection.selectedBytes(in: [safeV2]), 0)
    }

    func test_selection_用户主动勾选confirm后_reconcile保留选择() {
        let confirmV1 = item("confirm", bytes: 100, verdict: .confirm)
        let confirmV2 = item("confirm", bytes: 200, verdict: .confirm)
        var selection = SmartCareSelection(items: [confirmV1])

        XCTAssertTrue(selection.setSelected(true, item: confirmV1))
        selection.reconcile(with: [confirmV2])

        XCTAssertTrue(selection.isSelected(confirmV2))
        XCTAssertEqual(selection.selectedBytes(in: [confirmV2]), 200)
    }

    func test_selection_桶级批量开关只影响safe_保留confirm意图() {
        let safeA = item("safe-a", verdict: .safe)
        let safeB = item("safe-b", verdict: .safe)
        let confirm = item("confirm", verdict: .confirm)
        let forbid = item("forbid", verdict: .forbid)
        var selection = SmartCareSelection(items: [safeA, safeB, confirm, forbid])
        XCTAssertTrue(selection.setSelected(true, item: confirm))

        selection.setSafeItemIDsSelected(false, safeIDs: [safeA.id, safeB.id])

        XCTAssertFalse(selection.isSelected(safeA))
        XCTAssertFalse(selection.isSelected(safeB))
        XCTAssertTrue(selection.isSelected(confirm))
        XCTAssertFalse(selection.isSelected(forbid))

        selection.setSafeItemIDsSelected(true, safeIDs: [safeA.id, safeB.id])

        XCTAssertTrue(selection.isSelected(safeA))
        XCTAssertTrue(selection.isSelected(safeB))
        XCTAssertTrue(selection.isSelected(confirm))
    }

    func test_selection_条目降级为forbid时_移除选择和用户覆盖记录() {
        let safe = item("candidate", verdict: .safe)
        let forbidden = item("candidate", verdict: .forbid)
        var selection = SmartCareSelection(items: [safe])

        XCTAssertTrue(selection.setSelected(false, item: safe))
        XCTAssertEqual(selection.userOverriddenIDs, ["candidate"])

        selection.reconcile(with: [forbidden])

        XCTAssertFalse(selection.isSelected(forbidden))
        XCTAssertEqual(selection.selectedIDs, [])
        XCTAssertEqual(selection.userOverriddenIDs, [])
    }

    func test_phase_primaryAction_符合状态机合同() {
        XCTAssertEqual(SmartCarePhase.idle.primaryAction, .startScan)
        XCTAssertEqual(SmartCarePhase.scanning(progress: SmartCareProgress()).primaryAction, .stopScan)
        XCTAssertEqual(SmartCarePhase.reviewing(summary: .empty).primaryAction, .cleanSafeItems)
        XCTAssertEqual(SmartCarePhase.confirming(selection: SmartCareSelection()).primaryAction, .confirmClean)
        XCTAssertEqual(SmartCarePhase.cleaning(progress: SmartCareCleanProgress(completedCount: 0, totalCount: 1)).primaryAction, .cleaning)
        XCTAssertEqual(SmartCarePhase.completed(result: SmartCareResult(movedCount: 1, skippedCount: 0, releasedBytes: 100)).primaryAction, .scanAgain)
        XCTAssertEqual(SmartCarePhase.completed(result: SmartCareResult(movedCount: 1, skippedCount: 1, releasedBytes: 100)).primaryAction, .cleanSafeItems)
        XCTAssertEqual(SmartCarePhase.failed(.scanFailed("x")).primaryAction, .retry)
        XCTAssertEqual(SmartCarePhase.cancelled(partial: nil).primaryAction, .continueScan)
    }

    func test_result_跳过项使完成事务具有部分完成语义() {
        let complete = SmartCareResult(movedCount: 2, skippedCount: 0, releasedBytes: 200)
        let partial = SmartCareResult(movedCount: 1, skippedCount: 1, releasedBytes: 100)
        let allSkipped = SmartCareResult(movedCount: 0, skippedCount: 2, releasedBytes: 0)

        XCTAssertEqual(complete.completion, .complete)
        XCTAssertEqual(partial.completion, .partial)
        XCTAssertEqual(allSkipped.completion, .partial)
    }

    func test_progress保留本轮实际扫描范围() {
        let progress = SmartCareProgress(
            activity: .scanning(.developerCaches),
            plannedStages: [.developerCaches]
        )

        XCTAssertEqual(progress.plannedStages, [.developerCaches])
    }

    @MainActor
    func test_mainView默认进入普通模式() {
        XCTAssertEqual(MainView.defaultInterfaceMode, .normal)
    }

    func test_item保留删除预览所需元数据() {
        let item = SmartCareItem(
            id: "cache",
            bucketID: .appCache,
            path: "/tmp/cache",
            title: "cache",
            bytes: 20,
            logicalBytes: 30,
            fileCount: 4,
            isDirectory: false,
            verdict: .safe,
            runningBundleIDPrefix: "com.example.app"
        )

        XCTAssertEqual(item.logicalBytes, 30)
        XCTAssertEqual(item.fileCount, 4)
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.runningBundleIDPrefix, "com.example.app")
    }

    @MainActor
    func test_deletionAccounting_keepsMainActorHeartbeatResponsive() async {
        let workerStarted = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let removed = item("removed", bytes: 120, verdict: .safe)
        let retained = item("retained", bytes: 300, verdict: .safe)
        var accountingFinished = false
        let accounting = Task { @MainActor in
            let result = await SmartCareDeletionAccountingExecutor.run(
                items: [removed, retained],
                succeededPaths: [removed.path],
                professionalSelection: [removed.path, retained.path],
                operation: { items, paths, selection in
                    workerStarted.signal()
                    guard releaseWorker.wait(timeout: .now() + 2) == .success else {
                        return SmartCareDeletionAccounting(
                            succeededPaths: [],
                            remainingProfessionalSelection: selection,
                            releasedBytes: -1
                        )
                    }
                    return SmartCareDeletionAccountingExecutor.compute(
                        items: items,
                        succeededPaths: paths,
                        professionalSelection: selection
                    )
                }
            )
            accountingFinished = true
            return result
        }

        let started = await Task.detached {
            waitForSmartCareAccountingSemaphore(workerStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(started, .success)
        let heartbeatObservedPendingAccounting = await Task { @MainActor in
            let wasPending = !accountingFinished
            releaseWorker.signal()
            return wasPending
        }.value
        XCTAssertTrue(heartbeatObservedPendingAccounting)

        let result = await accounting.value
        XCTAssertTrue(accountingFinished)
        XCTAssertEqual(result.succeededPaths, [removed.path])
        XCTAssertEqual(result.remainingProfessionalSelection, [retained.path])
        XCTAssertEqual(result.releasedBytes, 120)
    }
}

private func waitForSmartCareAccountingSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}
