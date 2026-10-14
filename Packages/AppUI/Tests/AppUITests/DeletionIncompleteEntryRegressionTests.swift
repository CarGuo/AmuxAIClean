import Darwin
import Foundation
import SafetyKit
import ScanKit
import XCTest
@testable import AppUI

/// v2026.10.14: a scan coverage gap is not a SafetyEngine prohibition. Preserve both
/// dimensions so Professional List can reach the same target revalidation as Tree;
/// Normal still cannot turn an incomplete snapshot into ordinary deletion authority.
@MainActor
final class DeletionIncompleteEntryRegressionTests: XCTestCase {
    func testCommonCacheBudgetGapPreservesSafetyAndProfessionalEntry() async throws {
        let home = try makeHome()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.EntryRegression", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1]).write(to: cache.appendingPathComponent("a.bin"))
        try Data([2]).write(to: cache.appendingPathComponent("b.bin"))
        let coordinator = ScanCoordinator(vendors: [VendorRule(
            name: "Entry Regression",
            category: "common_app_cache",
            paths: [PathRule(path: "~/Library/Caches/com.example.EntryRegression", verdict: .safe)]
        )], home: home.path)
        coordinator.standardInstalledAppCacheRuleDiscovery = {
            StandardInstalledAppCacheRuleDiscoveryResult(rules: [])
        }
        coordinator.scanCommonAppCaches(scannerOptions: .init(maxEntriesPerPath: 1))
        try await waitForScan(coordinator)

        let row = try XCTUnwrap(coordinator.snapshot.rows.first { $0.url.path == cache.path })
        XCTAssertFalse(coordinator.snapshot.isComplete)
        XCTAssertTrue(coordinator.permissionDeniedPaths.isEmpty,
                      "A traversal budget is not a POSIX or FDA denial")
        try await assertIndependentAccessEvidence(row, coordinator: coordinator, home: home)
    }

    func testVersionedRootUnreadableDescendantPreservesProfessionalEntry() async throws {
        let home = try makeHome()
        let support = home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
        for version in ["15.0", "16.0", "17.0", "18.0"] {
            let directory = support.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("visible.bin"))
        }
        let target = support.appendingPathComponent("15.0", isDirectory: true)
        let lockedChild = target.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedChild, withIntermediateDirectories: true)
        try Data([2]).write(to: lockedChild.appendingPathComponent("hidden.bin"))
        XCTAssertEqual(chmod(lockedChild.path, 0), 0)
        defer {
            XCTAssertEqual(chmod(lockedChild.path, S_IRWXU), 0)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: home))
        }
        let coordinator = ScanCoordinator(home: home.path)
        coordinator.scanKnownVersionedRoots(home: home)
        try await waitForScan(coordinator)

        let row = try XCTUnwrap(coordinator.snapshot.rows.first { $0.url.path == target.path })
        XCTAssertFalse(coordinator.snapshot.isComplete)
        XCTAssertTrue(coordinator.permissionDeniedPaths.contains(lockedChild.path))
        try await assertIndependentAccessEvidence(row, coordinator: coordinator, home: home)
    }

    func testSmartCareMergeKeepsCoverageGapsOutOfNormalSelectionAndCleanableCapacity() throws {
        let path = "/Fixture/Home/Library/Caches/com.example.Partial"
        let row = RowItem(
            id: path, url: URL(fileURLWithPath: path), title: "Partial", isDirectory: true,
            bytes: 128, logicalBytes: 128, fileCount: 2, verdict: .safe, rejection: .ok,
            scanIncompleteReasons: [.permissionDenied]
        )
        let healthy = SmartCareCandidate(
            source: .recommended, bucketID: .appCache,
            path: "/Fixture/Home/Library/Caches/com.example.Complete", title: "Complete",
            bytes: 64, verdict: .safe
        )
        let summary = SmartCareSummaryBuilder.build(candidates:
            SmartCareSummaryBuilder.candidates(from: [row], source: .commonAppCache,
                                               home: "/Fixture/Home") + [
                SmartCareCandidate(source: .recommended, bucketID: .appCache, path: path,
                                   title: "Duplicate source", bytes: 128, verdict: .safe),
                SmartCareCandidate(source: .recommended, bucketID: .appCache,
                                   path: path + "/child", title: "Child", bytes: 32, verdict: .safe,
                                   scanIncompleteReasons: [.enumerationFailed]),
                healthy
            ]
        )
        let merged = try XCTUnwrap(summary.items.first { $0.path == path })
        XCTAssertEqual(merged.verdict, .safe, "Keep Safety separate from ordinary-mode eligibility")
        XCTAssertEqual(merged.scanIncompleteReasons, [.permissionDenied, .enumerationFailed])
        XCTAssertFalse(merged.isSelectable)
        XCTAssertFalse(merged.isDefaultSelected)
        XCTAssertEqual(summary.safeBytes, 64, "Partial capacity is not ordinary cleanable capacity")
        XCTAssertEqual(summary.forbidItems.map(\.path), [path])
        XCTAssertEqual(SmartCareSelection(items: summary.items).selectedIDs, [healthy.path])
        XCTAssertEqual(SmartCareCleanRequest(items: summary.items).paths, [healthy.path])
    }

    func testSnapshotCapacityExcludesCoverageGapsForConstructedAndPreparedRollups() {
        // v2026.10.14: preserving the true Safety verdict must not make incomplete
        // capacity appear ordinary-cleanable through either snapshot publication path.
        func makeRow(
            _ name: String, bytes: Int64, verdict: SafetyVerdict,
            reasons: Set<ScanIncompleteReason> = []
        ) -> RowItem {
            let path = "/Fixture/Home/Library/Caches/" + name
            return RowItem(
                id: path, url: URL(fileURLWithPath: path), title: name, isDirectory: true,
                bytes: bytes, logicalBytes: bytes, fileCount: 1, verdict: verdict,
                rejection: verdict == .forbid ? .vendorPathRule : .ok,
                scanIncompleteReasons: reasons
            )
        }
        let rows = [
            makeRow("complete-safe", bytes: 64, verdict: .safe),
            makeRow("complete-confirm", bytes: 32, verdict: .confirm),
            makeRow("policy-forbid", bytes: 16, verdict: .forbid),
            makeRow("incomplete-safe", bytes: 128, verdict: .safe, reasons: [.enumerationFailed]),
            makeRow("incomplete-confirm", bytes: 256, verdict: .confirm, reasons: [.permissionDenied])
        ]
        let constructed = ScanSnapshot(
            categoryID: "fixture", rows: rows, totalBytes: 496, scannedFileCount: 5,
            isFinished: true, elapsed: 0, isComplete: false
        )
        var rollup = ScanSnapshotRowRollup()
        for row in rows { rollup.record(row: row) }
        let prepared = ScanSnapshot(
            categoryID: "fixture", rows: rows, totalBytes: 496, scannedFileCount: 5,
            isFinished: true, elapsed: 0, isComplete: false, rowRollup: rollup
        )

        XCTAssertEqual(constructed, prepared)
        for snapshot in [constructed, prepared] {
            XCTAssertEqual(snapshot.safeBytes, 64)
            XCTAssertEqual(snapshot.cleanableBytes, 64)
            XCTAssertEqual(snapshot.confirmBytes, 32)
            XCTAssertEqual(snapshot.forbidBytes, 400, "Retain unavailable bytes without claiming cleanability")
            XCTAssertEqual(snapshot.totalBytes, 496)
            XCTAssertEqual(snapshot.safeBytes + snapshot.confirmBytes + snapshot.forbidBytes, 496)
            XCTAssertEqual(snapshot.maxRowBytes, 256, "Incomplete rows still participate in size presentation")
            XCTAssertEqual(snapshot.rows.map(\.verdict), [.safe, .confirm, .forbid, .safe, .confirm])
        }
    }

    private func assertIndependentAccessEvidence(
        _ row: RowItem, coordinator: ScanCoordinator, home: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let issues = coordinator.incompleteIssues(overlappingAny: [row.url.path])
        XCTAssertFalse(issues.isEmpty, file: file, line: line)
        XCTAssertEqual(row.scanIncompleteReasons, Set(issues.map(\.reason)), file: file, line: line)
        XCTAssertFalse(row.isSelectable, file: file, line: line)
        XCTAssertFalse(row.defaultSelected, file: file, line: line)
        let safety = coordinator.deletionSafetyEvaluation(for: row.url.path)
        XCTAssertEqual(row.verdict, safety.verdict,
                       "Scan completeness must not overwrite the product safety verdict", file: file, line: line)
        XCTAssertEqual(row.rejection, safety.rejection,
                       "Keep typed scan issues instead of inventing accessDenied", file: file, line: line)
        XCTAssertTrue(DeletionEntryPolicy.canInitiate(
            verdict: row.verdict, rejection: row.rejection,
            hasCompleteAccessEvidence: row.hasCompleteAccessEvidence, allowsTargetRevalidation: true,
            allowsVendorPathOverride: true
        ), "Professional must be able to request independent target revalidation", file: file, line: line)
        XCTAssertFalse(DeletionEntryPolicy.canInitiate(
            verdict: row.verdict, rejection: row.rejection,
            hasCompleteAccessEvidence: row.hasCompleteAccessEvidence, allowsTargetRevalidation: false,
            allowsVendorPathOverride: false
        ), "Normal mode cannot acquire an incomplete-scan override", file: file, line: line)

        let preparation = await TrashPipeline(home: home.path).prepareScanIncompleteOverride(
            rows: [row], scanIssues: issues, scanSessionID: coordinator.currentScanSessionID
        )
        guard case .strictConfirmation(let request, _) = preparation else {
            return XCTFail("The writable target should reach strict review; got \(preparation)", file: file, line: line)
        }
        XCTAssertEqual(request.paths, [row.url.path], file: file, line: line)
        XCTAssertFalse(request.entries[0].incompleteIssues.isEmpty, file: file, line: line)
    }

    private func makeHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionIncompleteEntry-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForScan(_ coordinator: ScanCoordinator) async throws {
        let deadline = Date().addingTimeInterval(8)
        while (coordinator.scanPhase != .idle || !coordinator.snapshot.isFinished) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(coordinator.scanPhase, .idle)
        XCTAssertTrue(coordinator.snapshot.isFinished)
    }
}
