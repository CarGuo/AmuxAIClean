import XCTest
@testable import ScanKit

/// v2026.07.17 MultiRoot 静默扫描的 watchdog 回归合同。
///
/// `summaryOnly` 为避免百万节点事件积压，公开合同明确不发送 node/progress/heartbeat。
/// 若仍启用 idle watchdog，正常但安静的长扫描会被误判为 hang 并合成 partial 终态；
/// 其它 delivery 均有节点、绝对进度或 heartbeat 作为存活证据，应继续受 watchdog 保护。
final class MultiRootWatchdogPolicyTests: XCTestCase {
    private enum FixtureError: Error {
        case couldNotCreateFile(String)
    }

    /// v2026.07.17 regression: public TimeInterval values must never reach a trapping UInt64
    /// conversion in Task.sleep. Invalid/non-positive values expire immediately; +infinity and
    /// huge finite values saturate without wrapping.
    func test_timeoutNanosecondNormalizationIsTotalForAllDoubleClasses() {
        XCTAssertEqual(MultiRootScanner.normalizedTimeoutNanoseconds(.nan), 0)
        XCTAssertEqual(MultiRootScanner.normalizedTimeoutNanoseconds(-1), 0)
        XCTAssertEqual(MultiRootScanner.normalizedTimeoutNanoseconds(-.infinity), 0)
        XCTAssertEqual(MultiRootScanner.normalizedTimeoutNanoseconds(0), 0)
        XCTAssertEqual(MultiRootScanner.normalizedTimeoutNanoseconds(1.5), 1_500_000_000)
        XCTAssertEqual(MultiRootScanner.normalizedTimeoutNanoseconds(.infinity), .max)
        XCTAssertEqual(
            MultiRootScanner.normalizedTimeoutNanoseconds(.greatestFiniteMagnitude),
            .max
        )
    }

    func test_delivery策略仅summaryOnly禁用noProgressWatchdog() {
        XCTAssertFalse(
            MultiRootScanner.usesNoProgressWatchdog(delivery: .summaryOnly),
            "summaryOnly 没有 idle 存活事件，不能启用 no-progress watchdog"
        )
        XCTAssertTrue(
            MultiRootScanner.usesNoProgressWatchdog(delivery: .complete),
            "完整节点流必须保留 idle watchdog"
        )
        XCTAssertTrue(
            MultiRootScanner.usesNoProgressWatchdog(delivery: .topLevel),
            "topLevel 有 progress/heartbeat，必须保留 idle watchdog"
        )
        XCTAssertTrue(
            MultiRootScanner.usesNoProgressWatchdog(
                delivery: .largeFiles(minimumAllocatedBytes: 1, maximumResults: 100)
            ),
            "largeFiles 有 progress/heartbeat，必须保留 idle watchdog"
        )
    }

    func test_multiRootSummaryOnly在极短noProgress阈值下仍返回真实完整终态() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiRoot-SummaryOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0xA5, count: 1_024)
        for index in 0..<64 {
            let path = root.appendingPathComponent("file-\(index).bin").path
            guard FileManager.default.createFile(atPath: path, contents: payload) else {
                throw FixtureError.couldNotCreateFile(path)
            }
        }

        let scanner = MultiRootScanner(
            options: ScanOptions(
                includeHidden: true,
                concurrency: 1,
                maxConcurrency: 1,
                mediaAware: false,
                respectTCCSkipList: false
            )
        )
        var terminalSummaries: [ScanSummary] = []
        var nonTerminalEventCount = 0
        for await wrapped in await scanner.scan(
            roots: [root],
            maxConcurrentRoots: 1,
            perRootTimeout: 10,
            noProgressTimeout: 0.001,
            totalDeadline: 10,
            delivery: .summaryOnly
        ) {
            XCTAssertEqual(wrapped.rootPath, root.path)
            switch wrapped.event {
            case .finished(let summary):
                terminalSummaries.append(summary)
            case .failed(let error):
                XCTFail("临时 fixture 不应整轮失败：\(error)")
            case .incomplete(let issue):
                XCTFail("临时 fixture 不应产生 incomplete：\(issue)")
            case .permissionDenied(let path):
                XCTFail("临时 fixture 不应权限失败：\(path)")
            case .tccProtectedSkipped(let path):
                XCTFail("临时 fixture 不应命中 TCC skip：\(path)")
            case .heartbeat, .progress, .node, .nodes, .cacheDirTagged:
                nonTerminalEventCount += 1
            }
        }

        let summary = try XCTUnwrap(terminalSummaries.first)
        XCTAssertEqual(terminalSummaries.count, 1, "不能追加 synthetic partial finished")
        XCTAssertEqual(nonTerminalEventCount, 0,
                       "summaryOnly 必须维持安静事件合同，不能靠恢复节点风暴喂活 watchdog")
        XCTAssertEqual(summary.completionStatus, .complete,
                       "极短 idle 阈值不能把正常 summaryOnly 扫描误杀为 partial")
        XCTAssertEqual(summary.fileCount, 64)
        XCTAssertEqual(summary.projection, .none)
    }
}
