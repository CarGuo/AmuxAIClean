import XCTest
@testable import AppUI

final class PresentationCoordinationTests: XCTestCase {
    func test_smartCarePreviewGate_快速双击只有第一个事务能开始() {
        var gate = SmartCareDeletePreviewGate()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let first = gate.begin(summaryRevision: 10, selectionRevision: 20, id: firstID)
        let second = gate.begin(summaryRevision: 10, selectionRevision: 20, id: secondID)

        XCTAssertEqual(first?.id, firstID)
        XCTAssertNil(second)
        XCTAssertTrue(gate.isInFlight)
    }

    func test_smartCarePreviewGate_完成必须同时匹配token修订和Modal空闲() {
        var gate = SmartCareDeletePreviewGate()
        let token = gate.begin(summaryRevision: 10, selectionRevision: 20)!

        XCTAssertTrue(gate.allowsCompletion(
            token: token,
            currentSummaryRevision: 10,
            currentSelectionRevision: 20,
            requestSummaryRevision: 10,
            requestSelectionRevision: 20,
            modalAvailable: true
        ))
        XCTAssertFalse(gate.allowsCompletion(
            token: token,
            currentSummaryRevision: 11,
            currentSelectionRevision: 20,
            requestSummaryRevision: 10,
            requestSelectionRevision: 20,
            modalAvailable: true
        ))
        XCTAssertFalse(gate.allowsCompletion(
            token: token,
            currentSummaryRevision: 10,
            currentSelectionRevision: 21,
            requestSummaryRevision: 10,
            requestSelectionRevision: 21,
            modalAvailable: true
        ))
        XCTAssertFalse(gate.allowsCompletion(
            token: token,
            currentSummaryRevision: 10,
            currentSelectionRevision: 20,
            requestSummaryRevision: 10,
            requestSelectionRevision: 20,
            modalAvailable: false
        ))
    }

    func test_smartCarePreviewGate_过期任务不能释放更新事务() {
        var gate = SmartCareDeletePreviewGate()
        let first = gate.begin(summaryRevision: 1, selectionRevision: 1)!
        XCTAssertTrue(gate.finish(first))
        let current = gate.begin(summaryRevision: 2, selectionRevision: 2)!

        XCTAssertFalse(gate.finish(first))
        XCTAssertEqual(gate.activeToken, current)
        XCTAssertTrue(gate.isInFlight)
    }

    func test_sentinelQueue_Modal忙时不调度且事件不丢失() {
        var queue = SentinelPresentationQueue()
        queue.enqueue(.inviteFullScan)

        XCTAssertFalse(queue.requestDrainIfPossible(isModalBusy: true))
        XCTAssertEqual(queue.pendingCount, 1)

        XCTAssertTrue(queue.requestDrainIfPossible(isModalBusy: false))
        XCTAssertEqual(
            queue.takeScheduledIfPossible(isModalBusy: false),
            .inviteFullScan
        )
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func test_sentinelQueue_调度后若Modal被占用仍保留队首并稍后FIFO恢复() {
        var queue = SentinelPresentationQueue()
        queue.enqueue(.openUninstall(path: "/Applications/A.app"))
        queue.enqueue(.inviteFullScan)

        XCTAssertTrue(queue.requestDrainIfPossible(isModalBusy: false))
        XCTAssertFalse(queue.requestDrainIfPossible(isModalBusy: false), "同一轮只允许一个 drain")
        XCTAssertNil(queue.takeScheduledIfPossible(isModalBusy: true))
        XCTAssertEqual(queue.pendingCount, 2, "抢占发生时不能丢掉已排队意图")

        XCTAssertTrue(queue.requestDrainIfPossible(isModalBusy: false))
        XCTAssertEqual(
            queue.takeScheduledIfPossible(isModalBusy: false),
            .openUninstall(path: "/Applications/A.app")
        )
        XCTAssertTrue(queue.requestDrainIfPossible(isModalBusy: false))
        XCTAssertEqual(
            queue.takeScheduledIfPossible(isModalBusy: false),
            .inviteFullScan
        )
        XCTAssertEqual(queue.pendingCount, 0)
    }
}
