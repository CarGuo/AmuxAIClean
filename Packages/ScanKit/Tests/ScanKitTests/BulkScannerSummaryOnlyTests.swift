import XCTest
@testable import ScanKit

/// v2026.07.16: Workflow capacity cards consume this contract instead of the lossless
/// incremental tree stream. These tests prevent a future optimization from reintroducing
/// node/progress backlogs or dropping typed completeness evidence.
final class BulkScannerSummaryOnlyTests: XCTestCase {
    func test_summaryWithProgress_只发布有界绝对进度而不恢复node流() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BulkScannerSummaryProgress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1_024 {
            try Data([UInt8(index % 255)]).write(
                to: root.appendingPathComponent("entry-\(index).bin")
            )
        }

        var progressEvents: [(bytes: Int64, files: Int)] = []
        var terminalSummary: ScanSummary?
        for await event in BulkScanner(options: .init(mediaAware: false)).scan(
            root: root,
            delivery: .summaryWithProgress
        ) {
            switch event {
            case .progress(let bytes, let files):
                progressEvents.append((bytes, files))
            case .finished(let summary):
                terminalSummary = summary
            case .node, .nodes, .cacheDirTagged:
                XCTFail("summary+progress 不得恢复增量节点 DTO: \(event)")
            case .heartbeat, .permissionDenied, .tccProtectedSkipped, .incomplete, .failed:
                break
            }
        }

        let summary = try XCTUnwrap(terminalSummary)
        XCTAssertFalse(progressEvents.isEmpty)
        XCTAssertTrue(zip(progressEvents, progressEvents.dropFirst()).allSatisfy { pair in
            pair.0.bytes <= pair.1.bytes && pair.0.files <= pair.1.files
        })
        XCTAssertEqual(progressEvents.last?.files, summary.fileCount)
        XCTAssertEqual(progressEvents.last?.bytes, summary.totalAllocatedBytes)
    }

    func test_summaryOnly_宽目录不发布nodeProgress或cacheTag_仍返回完整summary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BulkScannerSummaryOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<1_024 {
            try Data([UInt8(index % 255)]).write(
                to: root.appendingPathComponent("entry-\(index).bin")
            )
        }

        var terminalSummary: ScanSummary?
        for await event in BulkScanner(options: .init(mediaAware: false)).scan(
            root: root,
            delivery: .summaryOnly
        ) {
            switch event {
            case .heartbeat, .node, .nodes, .progress, .cacheDirTagged:
                XCTFail("summary-only 不能创建或发布增量树事件: \(event)")
            case .finished(let summary):
                terminalSummary = summary
            case .permissionDenied, .tccProtectedSkipped, .incomplete, .failed:
                break
            }
        }

        let summary = try XCTUnwrap(terminalSummary)
        XCTAssertEqual(summary.fileCount, 1_024)
        XCTAssertGreaterThan(summary.totalAllocatedBytes, 0)
        XCTAssertEqual(summary.completionStatus, .complete)
    }

    func test_summaryOnly_根失败仍保留incompleteFailed与finished终态() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("BulkScannerSummaryOnly-Missing-\(UUID().uuidString)")
        var incompleteIssues: [ScanIncompleteIssue] = []
        var failedCount = 0
        var terminalSummary: ScanSummary?

        for await event in BulkScanner(options: .init(mediaAware: false)).scan(
            root: missing,
            delivery: .summaryOnly
        ) {
            switch event {
            case .incomplete(let issue):
                incompleteIssues.append(issue)
            case .failed:
                failedCount += 1
            case .finished(let summary):
                terminalSummary = summary
            case .heartbeat, .node, .nodes, .progress, .cacheDirTagged:
                XCTFail("summary-only 根失败也不能夹带增量树事件")
            case .permissionDenied, .tccProtectedSkipped:
                break
            }
        }

        XCTAssertEqual(failedCount, 1)
        XCTAssertEqual(incompleteIssues.map(\.path), [missing.path])
        let summary = try XCTUnwrap(terminalSummary)
        XCTAssertEqual(summary.incompleteIssues.map(\.path), [missing.path])
        XCTAssertEqual(summary.completionStatus, .partial)
    }
}
