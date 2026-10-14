import Darwin
import Foundation
import ScanKit
import XCTest

@testable import AppUI

@MainActor
final class StorageAnalysisStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkspaceAnalysis-\(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 16_384).write(to: root.appendingPathComponent("Folder/payload.bin"))
        // Test-owned temporary fixture only; production cleanup always uses TrashPipeline.
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool)
        async throws
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The observable flow must reach a terminal state.", file: file, line: line)
    }

    func testRealFixtureScanDrilldownBackAndSearchPreserveScanSession() async throws {
        let root = try fixture()
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: Locale(identifier: "en"))
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.phase == .ready && store.projection != nil && !store.isProjecting }
        let session = scanner.currentScanSessionID
        let folder = try XCTUnwrap(store.projection?.rows.first { $0.title == "Folder" })
        XCTAssertGreaterThan(folder.bytes, 0)
        store.open(folder)
        try await waitUntil {
            store.phase == .ready && store.projection?.rows.first?.title == "payload.bin"
                && !store.isProjecting
        }
        XCTAssertEqual(store.breadcrumbs, [root.path, folder.path])
        store.navigate(to: root.path)
        try await waitUntil {
            store.phase == .ready && store.projection?.rows.first?.title == "Folder" && !store.isProjecting
        }
        store.query = "missing"
        try await waitUntil { !store.isProjecting && store.projection?.totalCount == 0 }
        store.query = "folder"
        try await waitUntil { !store.isProjecting && store.projection?.totalCount == 1 }
        XCTAssertEqual(
            scanner.currentScanSessionID, session, "Search/back must reuse measured scan evidence.")
        store.deactivate()
        store.activate(locale: Locale(identifier: "zh-Hans"))
        try await waitUntil { !store.isProjecting && store.projection?.totalCount == 1 }
        XCTAssertEqual(scanner.currentScanSessionID, session)
        store.deactivate()
    }

    func testDepartureCancelsProducerAndStaleProjectionCannotRestoreOldMap() async throws {
        let root = try fixture()
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: .current)
        store.scan(.makeCustom(url: root))
        store.deactivate()
        XCTAssertFalse(scanner.hasActivePrimaryScanOwnership)
        XCTAssertEqual(store.phase, .cancelled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.projection)
        let departedSession = scanner.currentScanSessionID
        store.scan(.makeCustom(url: root))
        XCTAssertEqual(scanner.currentScanSessionID, departedSession)
        XCTAssertFalse(
            scanner.hasActivePrimaryScanOwnership, "A late folder chooser cannot scan a hidden page.")
        store.activate(locale: .current)
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.phase == .ready && store.projection != nil }
        store.query = "never-publish"
        store.invalidateAfterExternalChange()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.projection)
        store.deactivate()
    }

    func testQueuedDeletionReceiptCannotMutateOrCancelReplacementScan() async throws {
        let root = try fixture()
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: Locale(identifier: "en"))
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.phase == .ready && store.projection != nil && !store.isProjecting }

        let reconciliation = try XCTUnwrap(store.applyExternalDeletedPaths([
            root.appendingPathComponent("Folder/payload.bin").path
        ]))
        // Same MainActor turn: the receipt is queued but has not entered its async body.
        scanner.cancel()
        let replacementSession = scanner.currentScanSessionID
        scanner._seedForTesting(isScanning: true)
        await reconciliation.value

        XCTAssertTrue(scanner.isScanning, "An old receipt must not cancel the replacement producer")
        XCTAssertEqual(scanner.currentScanSessionID, replacementSession)
        scanner.cancel()
        store.deactivate()
    }

    func testReceiptUpdatesMapAndListBeforeAuthoritativePrune() async throws {
        let root = try fixture()
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: Locale(identifier: "en"))
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.phase == .ready && store.projection?.totalCount == 1 && !store.isProjecting }
        let originalSnapshot = scanner.snapshot
        await scanner.acknowledgeSuccessfulDeletionForPresentation(
            paths: [root.appendingPathComponent("Folder").path]
        )
        try await waitUntil { store.projection?.totalCount == 0 && !store.isProjecting }
        XCTAssertTrue(store.projection?.rows.isEmpty == true)
        XCTAssertTrue(store.projection?.mapItems.isEmpty == true)
        XCTAssertEqual(scanner.snapshot, originalSnapshot,
                       "receipt visibility must not wait for or forge authoritative accounting")
        store.deactivate()
    }

    func testConcurrentDeletionReceiptsMergeWithinTheSameCompletedScan() async throws {
        let root = try fixture()
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 2, count: 8_192).write(to: second)
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: Locale(identifier: "en"))
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.phase == .ready && store.projection != nil && !store.isProjecting }
        let session = scanner.currentScanSessionID
        let first = try XCTUnwrap(store.applyExternalDeletedPaths([root.appendingPathComponent("Folder").path]))
        let next = try XCTUnwrap(store.applyExternalDeletedPaths([second.path]))

        await first.value
        await next.value
        try await waitUntil { store.projection?.rows.isEmpty == true && !store.isProjecting }

        XCTAssertEqual(scanner.currentScanSessionID, session)
        XCTAssertEqual(store.phase, .ready)
        store.deactivate()
    }

    func testCanonicalTemporaryRootRetainsPrivacySkipEvidenceInsteadOfClaimingEmpty() async throws {
        let fixtureRoot = try fixture()
        // NSOpenPanel returns the physical /private namespace. Foundation's URL resolver folds
        // /private/var back to /var, so use realpath to reproduce the observed picker boundary.
        let physicalPath = try XCTUnwrap(realpath(fixtureRoot.path, nil))
        defer { free(physicalPath) }
        let root = URL(fileURLWithPath: String(cString: physicalPath))
        XCTAssertTrue(TCCSkipList.shouldSkip(root.path), "Use the actual system-picker namespace")
        let scanner = ScanCoordinator()
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: Locale(identifier: "zh-Hans"))
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.phase == .ready && store.projection != nil && !store.isProjecting }

        XCTAssertEqual(store.directoryAccessState, .tccProtected)
        XCTAssertTrue(store.projection?.rows.isEmpty == true)
        let message = try XCTUnwrap(StorageDirectoryAccessPresentation(state: store.directoryAccessState))
        XCTAssertTrue(AppLocalization.string(message.detailKey, locale: Locale(identifier: "zh-Hans")).contains("隐私"))
        XCTAssertTrue(AppLocalization.string(message.detailKey, locale: Locale(identifier: "en")).contains("privacy"))
        XCTAssertFalse(scanner.incompleteScanIssues.isEmpty)
        store.deactivate()
    }

    func testSmallerItemFocusResizesAndReturnsWithoutRescanningOrLosingRows() async throws {
        let root = try fixture()
        try Data(repeating: 7, count: 524_288).write(to: root.appendingPathComponent("Folder/payload.bin"))
        for index in 0..<3 {
            let child = root.appendingPathComponent("small-\(index)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: child.appendingPathComponent("data.bin"))
        }
        let scanner = ScanCoordinator(home: root.path)
        let store = StorageAnalysisStore(scanner: scanner)
        store.activate(locale: .current)
        store.updateMapViewport(CGSize(width: 900, height: 400))
        store.scan(.makeCustom(url: root))
        try await waitUntil { store.projection != nil && !store.isProjecting }
        let session = scanner.currentScanSessionID
        XCTAssertEqual(store.projection?.mapPresentation.smallerItems?.groupedCount, 3)
        store.showSmallerItems()
        try await waitUntil { store.projection?.listScope == .smallerItems && !store.isProjecting }
        XCTAssertEqual(store.projection?.rows.count, 3)
        XCTAssertTrue(store.projection?.rows.allSatisfy { $0.title.hasPrefix("small-") } == true)
        store.showAllItems()
        try await waitUntil { store.projection?.listScope == .all && !store.isProjecting }
        XCTAssertEqual(store.projection?.rows.count, 4)
        store.showSmallerItems()
        store.updateMapViewport(CGSize(width: 4000, height: 2000))
        try await waitUntil {
            store.projection?.mapPresentation.chartSize.width == 4000 && !store.isProjecting
        }
        // At this allocation ratio the remaining strip is still < 104 points
        // wide. A large window alone cannot justify removing the readable group.
        XCTAssertEqual(store.projection?.mapPresentation.smallerItems?.groupedCount, 3)
        XCTAssertEqual(store.projection?.rows.count, 3)
        store.updateMapViewport(CGSize(width: 8000, height: 2000))
        try await waitUntil { store.projection?.listScope == .all && !store.isProjecting }
        XCTAssertNil(store.projection?.mapPresentation.smallerItems)
        XCTAssertEqual(store.projection?.rows.count, 4)
        store.updateMapViewport(CGSize(width: 900, height: 400))
        try await waitUntil { store.projection?.mapPresentation.smallerItems != nil && !store.isProjecting }
        store.showSmallerItems()
        store.query = "Folder"
        try await waitUntil { store.projection?.rows.count == 1 && !store.isProjecting }
        XCTAssertEqual(store.projection?.listScope, .all)
        XCTAssertEqual(store.projection?.rows.first?.title, "Folder")
        XCTAssertEqual(scanner.currentScanSessionID, session)
        store.deactivate()
    }

    func testNormalMapDeletionRejectsPendingAndIncompleteEvidenceBeforePreflight() {
        func row(
            pending: Bool = false, access: TreeRow.AccessState = .normal,
            completeness: TreeRow.SubtreeCompleteness = .complete
        ) -> TreeRow {
            TreeRow(
                path: "/fixture/a", title: "a", bytes: 99, fileCount: 1,
                isDirectory: true, hasChildren: true, accessState: access,
                subtreeCompleteness: completeness, isSizePending: pending)
        }
        XCTAssertNil(StorageAnalysisTrashStore.candidate(row(pending: true)))
        XCTAssertNil(StorageAnalysisTrashStore.candidate(row(access: .tccProtected)))
        XCTAssertNil(StorageAnalysisTrashStore.candidate(row(completeness: .containsIncompleteDescendant)))
        XCTAssertEqual(StorageAnalysisTrashStore.candidate(row())?.bytes, 99)
        XCTAssertEqual(DeleteRequestOrigin.storageAnalysis.historySource, "storage-analysis")
    }

    private actor PausedPipeline: DeletionPipeline {
        private var continuation: CheckedContinuation<DeletionPreflight, Never>?
        private var paths: [String] = []
        var calls = 0
        var moves = 0
        func preflight(paths: [String], accessDeniedPaths: Set<String>) async -> DeletionPreflight {
            calls += 1
            self.paths = paths
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish() {
            continuation?.resume(returning: DeletionPreflight(allowedPaths: paths, rejections: []))
            continuation = nil
        }
        func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
            moves += 1
            return (0, 0, nil, [])
        }
        nonisolated func setAccessDeniedPaths(_ paths: Set<String>) {}
    }

    func testOldProjectionAndLatePreflightCannotAuthorizeNewScanFacts() async throws {
        let root = try fixture()
        let scanner = ScanCoordinator(home: root.path)
        let row = TreeRow(
            path: root.appendingPathComponent("Folder").path, title: "Folder",
            bytes: 16_384, fileCount: 1, isDirectory: true, hasChildren: true)
        let snapshot = ScanSnapshot(
            categoryID: "fixture", rows: [], totalBytes: row.bytes,
            scannedFileCount: 1, isFinished: true, elapsed: 1)
        scanner._seedForTesting(snapshot: snapshot, currentRootPath: root.path, isScanning: false)
        let pipeline = PausedPipeline()
        let undo = UndoHistoryStore(
            storeURL: root.appendingPathComponent("undo.json"), allowedRestoreRoots: [root.path])
        let trash = StorageAnalysisTrashStore(scanner: scanner, pipeline: pipeline, undoHistoryStore: undo)
        let oldIdentity = trash.currentIdentity
        scanner._seedForTesting(snapshot: snapshot)
        trash.prepare(row, snapshotIdentity: oldIdentity)
        XCTAssertFalse(trash.isBusy, "A stale displayed row must be rejected before preflight.")
        let initialCalls = await pipeline.calls
        XCTAssertEqual(initialCalls, 0)

        trash.prepare(row, snapshotIdentity: trash.currentIdentity)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await pipeline.calls == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let calls = await pipeline.calls
        XCTAssertEqual(calls, 1)
        scanner._seedForTesting(snapshot: snapshot)
        await pipeline.finish()
        try await waitUntil { trash.notice != nil }
        guard case .preflightNotice = trash.sheet else { return XCTFail("Rejection must own the failure sheet") }
        XCTAssertTrue(trash.isBusy)
        trash.cancelReview()
        trash.dismiss()
        XCTAssertFalse(trash.isBusy)
        let moves = await pipeline.moves
        XCTAssertEqual(moves, 0)
        trash.deactivate()
    }

    func testChangedEvidenceRejectsBothConfirmationAndDismissalHandoff() async throws {
        let root = try fixture()
        let scanner = ScanCoordinator(home: root.path)
        let row = TreeRow(
            path: root.appendingPathComponent("Folder").path, title: "Folder",
            bytes: 16_384, fileCount: 1, isDirectory: true, hasChildren: true)
        let snapshot = ScanSnapshot(
            categoryID: "fixture", rows: [], totalBytes: row.bytes,
            scannedFileCount: 1, isFinished: true, elapsed: 1)
        let undo = UndoHistoryStore(
            storeURL: root.appendingPathComponent("undo.json"), allowedRestoreRoots: [root.path])
        for invalidateBeforeAccept in [true, false] {
            scanner._seedForTesting(snapshot: snapshot, currentRootPath: root.path, isScanning: false)
            let pipeline = PausedPipeline()
            let trash = StorageAnalysisTrashStore(
                scanner: scanner, pipeline: pipeline, undoHistoryStore: undo)
            trash.prepare(row, snapshotIdentity: trash.currentIdentity)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await pipeline.calls == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            await pipeline.finish()
            try await waitUntil { trash.sheet != nil }
            guard case .review(let review) = trash.sheet else {
                XCTFail("Current, complete evidence must reach the normal review.")
                return
            }
            if invalidateBeforeAccept { scanner._seedForTesting(snapshot: snapshot) }
            let accepted = trash.accept(
                review, plan: ToolTrashExecutionPlan(paths: [row.path], runningAppSkipped: []))
            XCTAssertEqual(accepted, !invalidateBeforeAccept)
            XCTAssertTrue(trash.isBusy, "The modal slot remains occupied until the sheet actually dismisses.")
            if !invalidateBeforeAccept {
                scanner._seedForTesting(snapshot: snapshot)
            }
            trash.dismiss()
            guard case .preflightNotice = trash.sheet else { return XCTFail("Stale evidence must open failure details") }
            XCTAssertNotNil(trash.notice)
            XCTAssertTrue(trash.isBusy)
            trash.cancelReview()
            trash.dismiss()
            XCTAssertNil(trash.sheet)
            XCTAssertFalse(trash.isBusy)
            let moves = await pipeline.moves
            XCTAssertEqual(moves, 0, "No stale evidence may cross the submission boundary.")
            trash.deactivate()
        }
    }
}
