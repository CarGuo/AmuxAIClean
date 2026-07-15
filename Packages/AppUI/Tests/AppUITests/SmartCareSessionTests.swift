import Dispatch
import Foundation
import SafetyKit
import ScanKit
import XCTest
@testable import AppUI

@MainActor
final class SmartCareSessionTests: XCTestCase {
    func testDefaultSourcesKeepFastSafeScanOrder() {
        XCTAssertEqual(
            SmartCareSession.defaultSources,
            [.recommended, .commonAppCache, .developer]
        )
        XCTAssertEqual(
            SmartCareSession.defaultStages,
            [.core, .appCaches, .developerCaches]
        )
    }

    func testPartialTerminalSnapshotIsAcceptedInsteadOfEscalatedToFatal() {
        let partial = ScanSnapshot(
            categoryID: ScanCoordinator.commonAppCacheCategoryID,
            rows: [],
            totalBytes: 0,
            scannedFileCount: 0,
            isFinished: true,
            elapsed: 12,
            isComplete: false
        )

        XCTAssertEqual(
            SmartCareSnapshotCompletionPolicy.decision(
                snapshot: partial,
                isScanning: false,
                terminalFailure: nil,
                hasDeletionDeniedEvidence: true,
                fallbackError: "14 locations were incomplete"
            ),
            .accept(isComplete: false),
            "部分扫描有独立删除拒绝证据，不能把整轮结果升级成 Action failed"
        )
    }

    func testPartialTerminalWithoutDeniedEvidenceFailsClosed() {
        let partial = ScanSnapshot(
            categoryID: ScanCoordinator.commonAppCacheCategoryID,
            rows: [],
            totalBytes: 0,
            scannedFileCount: 0,
            isFinished: true,
            elapsed: 1,
            isComplete: false
        )

        XCTAssertEqual(
            SmartCareSnapshotCompletionPolicy.decision(
                snapshot: partial,
                isScanning: false,
                terminalFailure: nil,
                hasDeletionDeniedEvidence: false,
                fallbackError: "producer omitted incomplete-path evidence"
            ),
            .fail("producer omitted incomplete-path evidence")
        )
    }

    func testScannerFatalFailureWinsOverPartialAppearance() {
        let partial = ScanSnapshot(
            categoryID: ScanCoordinator.developerCategoryID,
            rows: [],
            totalBytes: 0,
            scannedFileCount: 0,
            isFinished: true,
            elapsed: 1,
            isComplete: false
        )
        let failure = ScanCoordinator.TerminalFailure(message: "stream failed")

        XCTAssertEqual(
            SmartCareSnapshotCompletionPolicy.decision(
                snapshot: partial,
                isScanning: false,
                terminalFailure: failure,
                hasDeletionDeniedEvidence: true,
                fallbackError: "incomplete"
            ),
            .fail("stream failed"),
            "真实 scanner failure 不能把该阶段写入 completedStages"
        )
    }

    func testStoppedNonTerminalSnapshotRemainsFatal() {
        let unfinished = ScanSnapshot(
            categoryID: ScanCoordinator.commonAppCacheCategoryID,
            rows: [],
            totalBytes: 0,
            scannedFileCount: 0,
            isFinished: false,
            elapsed: 1
        )

        XCTAssertEqual(
            SmartCareSnapshotCompletionPolicy.decision(
                snapshot: unfinished,
                isScanning: false,
                terminalFailure: nil,
                hasDeletionDeniedEvidence: false,
                fallbackError: "scanner stopped unexpectedly"
            ),
            .fail("scanner stopped unexpectedly")
        )
    }

    func testCompleteEmptySnapshotWithRealErrorRemainsFatal() {
        let failed = ScanSnapshot(
            categoryID: ScanCoordinator.commonAppCacheCategoryID,
            rows: [],
            totalBytes: 0,
            scannedFileCount: 0,
            isFinished: true,
            elapsed: 1,
            isComplete: true
        )

        XCTAssertEqual(
            SmartCareSnapshotCompletionPolicy.decision(
                snapshot: failed,
                isScanning: false,
                terminalFailure: nil,
                hasDeletionDeniedEvidence: false,
                fallbackError: "I/O failed"
            ),
            .fail("I/O failed")
        )
    }

    func testPartialCommonCacheFlowsThroughSessionAndRemainsDeletionDenied() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-care-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }
        let cache = home.appendingPathComponent("Library/Caches/com.example.Partial", isDirectory: true)

        let scanner = ScanCoordinator(vendors: [], home: home.path)
        scanner.commonAppCacheDetector = { _, _, _ in
            CommonAppCacheScanner.ScanResult(
                hits: [CommonAppCacheScanner.Hit(
                    ruleName: "Partial Cache",
                    bundleIDPrefix: "com.example.Partial",
                    source: "fixture",
                    url: cache,
                    isDirectory: true,
                    verdict: .safe,
                    reason: "cache",
                    sizeBytes: 4_096,
                    logicalSizeBytes: 128,
                    entryCount: 1
                )],
                incompletePaths: [CommonAppCacheScanner.IncompletePath(
                    path: cache.path,
                    reason: .deadlineExceeded
                )]
            )
        }
        let session = SmartCareSession(scanCoordinator: scanner)
        session.setStage(.core, selected: false)
        session.setStage(.developerCaches, selected: false)

        session.startScan(
            includeHidden: false,
            enabledDeveloperRuleIDs: [],
            home: home.path
        )
        try await waitForSmartCareTerminal(session)

        guard case .reviewing = session.care.phase else {
            return XCTFail("带精确拒绝证据的 partial 应进入结果页，而不是 Action failed")
        }
        XCTAssertEqual(session.deletionDeniedPaths, [cache.standardizedFileURL.path])
        XCTAssertEqual(session.scanLimitationProjection.totalCount, 1)
        XCTAssertEqual(session.scanLimitationProjection.displayedPaths, [cache.standardizedFileURL.path])
        XCTAssertEqual(session.care.summary.items.map(\.path), [cache.standardizedFileURL.path])
        XCTAssertEqual(session.care.summary.items.first?.verdict, .forbid)

        let partition = TrashPipeline.partitionByForbid(
            paths: [cache.path],
            safety: SafetyEngine(),
            accessDeniedPaths: session.deletionDeniedPaths,
            home: home.path
        )
        XCTAssertTrue(partition.allowed.isEmpty)
        XCTAssertEqual(partition.rejected.first?.reason, .accessDenied)
    }

    func testScanScopesAreSelectableBeforeScanning() {
        let session = SmartCareSession(scanCoordinator: ScanCoordinator(vendors: []))

        session.setStage(.appCaches, selected: false)
        session.setStage(.developerCaches, selected: false)

        XCTAssertEqual(session.orderedSelectedStages, [.core])

        session.setStage(.developerCaches, selected: true)
        XCTAssertEqual(session.orderedSelectedStages, [.core, .developerCaches])
    }

    func testScanDoesNotStartWhenEveryScopeIsDisabled() {
        let scanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(scanCoordinator: scanner)
        for stage in SmartCareSession.defaultStages {
            session.setStage(stage, selected: false)
        }

        session.startScan(includeHidden: false, enabledDeveloperRuleIDs: [])

        XCTAssertEqual(session.care.phase, .idle)
        XCTAssertFalse(scanner.isScanning)
        XCTAssertFalse(scanner.wasCancelled)
    }

    func testPrepareForRescanReturnsToScopeSelectionWithoutStartingScanner() {
        let care = SmartCareCoordinator(summary: .empty)
        care.beginScan()
        care.finishScan(.empty)
        let scanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(care: care, scanCoordinator: scanner)

        session.prepareForRescan()

        XCTAssertEqual(care.phase, .idle)
        XCTAssertFalse(scanner.isScanning)
        XCTAssertEqual(session.orderedSelectedStages, SmartCareSession.defaultStages)
    }

    func testCancelMovesCareStateToCancelled() {
        let care = SmartCareCoordinator()
        let scanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(care: care, scanCoordinator: scanner)

        session.cancelScan()

        guard case .cancelled = care.phase else {
            return XCTFail("Expected cancelled phase")
        }
        XCTAssertFalse(session.isBusy)
    }

    func testSessionOwnsDedicatedScannerAndCannotCancelProfessionalScanner() {
        let professionalScanner = ScanCoordinator(vendors: [])
        let normalScanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(scanCoordinator: normalScanner)

        session.cancelScan()

        XCTAssertTrue(session.scanCoordinator === normalScanner)
        XCTAssertTrue(normalScanner.wasCancelled)
        XCTAssertFalse(professionalScanner.wasCancelled)
    }

    func testCheckpointRecordsCompletedStageAndKeepsRemainingPlan() {
        let candidate = SmartCareCandidate(
            source: .recommended,
            bucketID: .systemJunk,
            path: "/tmp/logs",
            title: "logs",
            bytes: 120,
            fileCount: 3,
            verdict: .safe
        )
        let summary = SmartCareSummaryBuilder.build(candidates: [candidate])
        let snapshot = ScanSnapshot(
            categoryID: ScanCoordinator.smartCareCoreCategoryID,
            rows: [],
            totalBytes: 120,
            scannedFileCount: 3,
            isFinished: true,
            elapsed: 0
        )
        var checkpoint = SmartCareScanCheckpoint(plannedStages: SmartCareScanStage.allCases)

        checkpoint.record(
            stage: .core,
            snapshot: snapshot,
            aggregation: SmartCareAggregationResult(
                candidates: [candidate],
                summary: summary
            ),
            deniedPaths: ["/tmp/logs/locked"]
        )

        XCTAssertEqual(checkpoint.completedStages, [.core])
        XCTAssertEqual(checkpoint.remainingStages, [.appCaches, .developerCaches])
        XCTAssertEqual(checkpoint.completedBytes, 120)
        XCTAssertEqual(checkpoint.completedFileCount, 3)
        XCTAssertEqual(checkpoint.deniedPaths, ["/tmp/logs/locked"])
        XCTAssertEqual(checkpoint.completedSummary.items.map(\.path), ["/tmp/logs"])
    }

    func testRetryFailedScanUsesRemainingCheckpointWithoutResurrectingDeletedCandidate() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-care-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let deletedPath = home.appendingPathComponent("Library/Logs/old.log").path
        let retryPath = home.appendingPathComponent("Library/Caches/com.example.Retry", isDirectory: true)
        let oldCandidate = SmartCareCandidate(
            source: .recommended,
            bucketID: .systemJunk,
            path: deletedPath,
            title: "Old Log",
            bytes: 512,
            fileCount: 1,
            verdict: .safe
        )
        let oldSummary = SmartCareSummaryBuilder.build(candidates: [oldCandidate])
        var checkpoint = SmartCareScanCheckpoint(plannedStages: [.core, .appCaches])
        checkpoint.record(
            stage: .core,
            snapshot: ScanSnapshot(
                categoryID: ScanCoordinator.smartCareCoreCategoryID,
                rows: [],
                totalBytes: 512,
                scannedFileCount: 1,
                isFinished: true,
                elapsed: 0
            ),
            aggregation: SmartCareAggregationResult(
                candidates: [oldCandidate],
                summary: oldSummary
            ),
            deniedPaths: []
        )

        let care = SmartCareCoordinator(summary: oldSummary)
        let scanner = ScanCoordinator(vendors: [], home: home.path)
        scanner.commonAppCacheDetector = { _, _, _ in
            CommonAppCacheScanner.ScanResult(
                hits: [CommonAppCacheScanner.Hit(
                    ruleName: "Retry Cache",
                    bundleIDPrefix: "com.example.Retry",
                    source: "fixture",
                    url: retryPath,
                    isDirectory: true,
                    verdict: .safe,
                    reason: "cache",
                    sizeBytes: 2_048,
                    logicalSizeBytes: 64,
                    entryCount: 1
                )],
                incompletePaths: []
            )
        }
        let session = SmartCareSession(
            care: care,
            scanCoordinator: scanner,
            checkpoint: checkpoint,
            deletionAggregator: { paths, candidates in
                await Task.detached(priority: .userInitiated) {
                    SmartCareSummaryBuilder.removingCandidates(paths: paths, from: candidates)
                }.value
            }
        )

        await session.applySuccessfulDeletion(paths: [deletedPath])
        XCTAssertTrue(care.summary.items.isEmpty)
        care.fail(.scanFailed("previous app-cache attempt failed"))

        session.retryFailedScan(
            includeHidden: false,
            enabledDeveloperRuleIDs: [],
            home: home.path
        )
        try await waitForSmartCareTerminal(session)

        guard case .reviewing = care.phase else {
            return XCTFail("Retry 应从剩余 app-cache 阶段恢复到结果页")
        }
        XCTAssertEqual(care.summary.items.map(\.path), [retryPath.standardizedFileURL.path])
        XCTAssertFalse(care.summary.items.contains { $0.path == deletedPath })
    }

    func testCoordinatorCancelUsesPublishedCheckpointAsPartial() {
        let candidate = SmartCareCandidate(
            source: .recommended,
            bucketID: .systemJunk,
            path: "/tmp/partial",
            title: "partial",
            bytes: 10,
            verdict: .safe
        )
        let summary = SmartCareSummaryBuilder.build(candidates: [candidate])
        let care = SmartCareCoordinator()
        care.beginScan()
        care.publishScanCheckpoint(
            summary,
            progress: SmartCareProgress(completedStages: [.core])
        )

        care.cancel(partial: summary)

        guard case .cancelled(let partial) = care.phase else {
            return XCTFail("Expected cancelled phase")
        }
        XCTAssertEqual(partial?.items.map(\.path), ["/tmp/partial"])
    }

    func testSmartCareCorePlanDoesNotOverlapAppOrDeveloperCaches() {
        let home = "/Users/test"
        let core = ScanCategories.smartCareCore(home: home)
        XCTAssertEqual(core.map(\.id), ["user.logs"])
        XCTAssertFalse(core.contains { $0.rootPath == "\(home)/Library/Caches" })
        XCTAssertFalse(core.contains { $0.rootPath.contains("DerivedData") })
        XCTAssertFalse(core.contains { $0.rootPath == "\(home)/Downloads" })
        XCTAssertFalse(core.contains { $0.rootPath == "\(home)/.Trash" })
    }

    func testAggregationExecutorPropagatesParentCancellationAfterWorkerStarts() async {
        let workerStarted = DispatchSemaphore(value: 0)
        let workerObservedCancellation = DispatchSemaphore(value: 0)
        let parent = Task.detached { () throws -> Void in
            try await SmartCareAggregationExecutor.run {
                workerStarted.signal()
                let deadline = DispatchTime.now() + .seconds(2)
                do {
                    while DispatchTime.now() < deadline {
                        try Task.checkCancellation()
                    }
                    throw SmartCareCancellationTestError.workerTimedOut
                } catch {
                    if error is CancellationError {
                        workerObservedCancellation.signal()
                    }
                    throw error
                }
            }
        }

        XCTAssertEqual(workerStarted.wait(timeout: .now() + 2), .success)
        parent.cancel()

        do {
            try await parent.value
            XCTFail("Expected parent cancellation")
        } catch is CancellationError {
            // Expected: the parent's cancellation handler cancelled the detached worker.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(workerObservedCancellation.wait(timeout: .now() + 2), .success)
    }

    func testExternalChildDeletionRemovesStaleSmartCareAncestorSummary() async {
        let parent = "/Users/test/Library/Caches/App"
        let sibling = "/Users/test/Library/Caches/Application"
        let summary = SmartCareSummaryBuilder.build(candidates: [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: parent,
                               title: "App",
                               bytes: 100,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: sibling,
                               title: "Application",
                               bytes: 200,
                               verdict: .safe)
        ])
        let care = SmartCareCoordinator(summary: summary)
        let session = SmartCareSession(care: care, scanCoordinator: ScanCoordinator(vendors: []))

        await session.applySuccessfulDeletion(paths: [parent + "/child/cache.bin"])

        XCTAssertEqual(care.summary.items.map(\.path), [sibling])
        guard case .reviewing(let revised) = care.phase else {
            return XCTFail("Expected reviewing phase after external deletion")
        }
        XCTAssertEqual(revised.items.map(\.path), [sibling])
    }

    func testConcurrentExternalDeletionsCommitLinearlyWithoutResurrectingCheckpointItems() async {
        let paths = [
            "/Users/test/Library/Caches/AppA",
            "/Users/test/Library/Caches/AppB",
            "/Users/test/Library/Caches/AppC"
        ]
        let candidates = paths.enumerated().map { index, path in
            SmartCareCandidate(
                source: .commonAppCache,
                bucketID: .appCache,
                path: path,
                title: "App\(index)",
                bytes: Int64((index + 1) * 100),
                fileCount: index + 1,
                verdict: .safe
            )
        }
        let summary = SmartCareSummaryBuilder.build(candidates: candidates)
        var checkpoint = SmartCareScanCheckpoint(plannedStages: [.appCaches])
        checkpoint.candidates = candidates
        checkpoint.completedSummary = summary
        checkpoint.completedBytes = summary.totalBytes
        checkpoint.completedFileCount = candidates.reduce(0) { $0 + $1.fileCount }
        checkpoint.completedStages = [.appCaches]

        let gate = SmartCareDeletionAggregationGate()
        let care = SmartCareCoordinator(summary: summary)
        let session = SmartCareSession(
            care: care,
            scanCoordinator: ScanCoordinator(vendors: []),
            checkpoint: checkpoint,
            deletionAggregator: { removedPaths, currentCandidates in
                await gate.suspendInvocation()
                return SmartCareSummaryBuilder.removingCandidates(
                    paths: removedPaths,
                    from: currentCandidates
                )
            }
        )

        let first = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [paths[0]])
        }
        await gate.waitForInvocationCount(1)
        let second = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [paths[1]])
        }
        await gate.waitForInvocationCount(2)

        // 让后启动的删除先提交，制造旧实现的 last-writer-wins 竞态。
        await gate.releaseInvocation(2)
        await second.value
        await gate.releaseInvocation(1)
        await gate.waitForInvocationCount(3)
        await gate.releaseInvocation(3)
        await first.value

        XCTAssertEqual(care.summary.items.map(\.path), [paths[2]])

        // 再从 checkpoint 删掉最后一项；如果前两次只更新了可见 summary，
        // 这里会把 AppA/AppB 重新聚合回来。
        let third = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [paths[2]])
        }
        await gate.waitForInvocationCount(4)
        await gate.releaseInvocation(4)
        await third.value
        XCTAssertTrue(care.summary.items.isEmpty)
    }

    func testDeletionAwaitThenContinueScanRebasesAndCannotRepublishDeletedCheckpointItem() async {
        let removedPath = "/Users/test/Library/Caches/Removed"
        let retainedPath = "/Users/test/Library/Caches/Retained"
        let candidates = [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: removedPath,
                               title: "Removed",
                               bytes: 100,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: retainedPath,
                               title: "Retained",
                               bytes: 200,
                               verdict: .safe)
        ]
        let summary = SmartCareSummaryBuilder.build(candidates: candidates)
        var checkpoint = SmartCareScanCheckpoint(plannedStages: [.appCaches, .developerCaches])
        checkpoint.candidates = candidates
        checkpoint.completedSummary = summary
        checkpoint.completedBytes = summary.totalBytes
        checkpoint.completedStages = [.appCaches]

        let gate = SmartCareDeletionAggregationGate()
        let care = SmartCareCoordinator(summary: summary)
        care.cancel(partial: summary)
        let scanner = ScanCoordinator(
            vendors: [],
            home: NSTemporaryDirectory() + "/smart-care-lifecycle-\(UUID().uuidString)"
        )
        let session = SmartCareSession(
            care: care,
            scanCoordinator: scanner,
            checkpoint: checkpoint,
            deletionAggregator: { removedPaths, currentCandidates in
                await gate.suspendInvocation()
                return SmartCareSummaryBuilder.removingCandidates(
                    paths: removedPaths,
                    from: currentCandidates
                )
            }
        )

        let deletion = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [removedPath])
        }
        await gate.waitForInvocationCount(1)

        session.continueScan(
            includeHidden: false,
            enabledDeveloperRuleIDs: [],
            home: NSTemporaryDirectory()
        )
        guard case .scanning = care.phase else {
            return XCTFail("Expected resumed scan while deletion aggregation is suspended")
        }

        await gate.releaseInvocation(1)
        // scan generation 改变必须使第一份删除结果失效，并从最新
        // checkpoint 发起第二次聚合；旧实现会直接提交第一份结果。
        await gate.waitForInvocationCount(2)
        if case .scanning = care.phase {
            XCTFail("Deletion reconciliation must cancel an active resumed scan")
        }
        XCTAssertFalse(scanner.isScanning)
        await gate.releaseInvocation(2)
        await deletion.value

        XCTAssertEqual(care.summary.items.map(\.path), [retainedPath])

        // 再从 checkpoint 清除保留项，防止延迟的 runScan 局部副本在删除后覆盖。
        let finalDeletion = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [retainedPath])
        }
        await gate.waitForInvocationCount(3)
        await gate.releaseInvocation(3)
        await finalDeletion.value
        XCTAssertTrue(care.summary.items.isEmpty)
    }

    func testDeniedPathCheckpointMutationInvalidatesAwaitingDeletionTransaction() async {
        let removedPath = "/Users/test/Library/Caches/Removed"
        let retainedPath = "/Users/test/Library/Caches/Retained"
        let deniedPath = "/Users/test/Library/Caches/Denied"
        let candidates = [
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: removedPath,
                               title: "Removed",
                               bytes: 100,
                               verdict: .safe),
            SmartCareCandidate(source: .commonAppCache,
                               bucketID: .appCache,
                               path: retainedPath,
                               title: "Retained",
                               bytes: 200,
                               verdict: .safe)
        ]
        let summary = SmartCareSummaryBuilder.build(candidates: candidates)
        var checkpoint = SmartCareScanCheckpoint(plannedStages: [.appCaches])
        checkpoint.candidates = candidates
        checkpoint.completedSummary = summary
        checkpoint.completedStages = [.appCaches]

        let gate = SmartCareDeletionAggregationGate()
        let care = SmartCareCoordinator(summary: summary)
        let session = SmartCareSession(
            care: care,
            scanCoordinator: ScanCoordinator(vendors: []),
            checkpoint: checkpoint,
            deletionAggregator: { removedPaths, currentCandidates in
                await gate.suspendInvocation()
                return SmartCareSummaryBuilder.removingCandidates(
                    paths: removedPaths,
                    from: currentCandidates
                )
            }
        )

        let deletion = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [removedPath])
        }
        await gate.waitForInvocationCount(1)
        session.recordDeniedPaths([deniedPath])
        await gate.releaseInvocation(1)
        await gate.waitForInvocationCount(2)
        await gate.releaseInvocation(2)
        await deletion.value

        XCTAssertEqual(session.deletionDeniedPaths, [deniedPath])
        XCTAssertEqual(care.summary.items.map(\.path), [retainedPath])
    }

    func testDeletionProjection_keepsMainActorHeartbeatResponsive() async {
        let removedPath = "/Users/test/Library/Caches/Removed"
        let candidate = SmartCareCandidate(
            source: .commonAppCache,
            bucketID: .appCache,
            path: removedPath,
            title: "Removed",
            bytes: 100,
            verdict: .safe
        )
        let summary = SmartCareSummaryBuilder.build(candidates: [candidate])
        let workerStarted = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let care = SmartCareCoordinator(
            summary: summary,
            projectionBuilder: { selection, items in
                workerStarted.signal()
                guard releaseWorker.wait(timeout: .now() + 2) == .success else {
                    throw SmartCareDeletionHeartbeatError.workerReleaseTimedOut
                }
                return try SmartCareCoordinator.reconciledProjectionCheckingCancellation(
                    selection: selection,
                    items: items
                )
            }
        )
        let session = SmartCareSession(
            care: care,
            scanCoordinator: ScanCoordinator(vendors: [])
        )
        var deletionFinished = false
        let deletion = Task { @MainActor in
            await session.applySuccessfulDeletion(paths: [removedPath])
            deletionFinished = true
        }

        let started = await Task.detached {
            waitForSmartCareDeletionSemaphore(workerStarted, timeout: .now() + 2)
        }.value
        XCTAssertEqual(started, .success)

        let heartbeatObservedPendingDeletion = await Task { @MainActor in
            let wasPending = !deletionFinished
            releaseWorker.signal()
            return wasPending
        }.value
        XCTAssertTrue(heartbeatObservedPendingDeletion)
        await deletion.value
        XCTAssertTrue(deletionFinished)
        XCTAssertTrue(care.summary.items.isEmpty)
    }
}

private enum SmartCareCancellationTestError: Error {
    case workerTimedOut
}

private enum SmartCareDeletionHeartbeatError: Error {
    case workerReleaseTimedOut
}

private enum SmartCareSessionIntegrationError: Error {
    case terminalStateTimedOut
}

@MainActor
private func waitForSmartCareTerminal(_ session: SmartCareSession) async throws {
    for _ in 0..<300 {
        if !session.isBusy { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SmartCareSessionIntegrationError.terminalStateTimedOut
}

private func waitForSmartCareDeletionSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}

private actor SmartCareDeletionAggregationGate {
    private struct CountWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var invocationCount = 0
    private var blockedInvocations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var countWaiters: [CountWaiter] = []

    func suspendInvocation() async {
        invocationCount += 1
        let invocation = invocationCount
        let ready = countWaiters.filter { invocationCount >= $0.target }
        countWaiters.removeAll { invocationCount >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
        await withCheckedContinuation { continuation in
            blockedInvocations[invocation] = continuation
        }
    }

    func waitForInvocationCount(_ target: Int) async {
        guard invocationCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    func releaseInvocation(_ invocation: Int) {
        guard let continuation = blockedInvocations.removeValue(forKey: invocation) else {
            preconditionFailure("Missing blocked Smart Care deletion invocation \(invocation)")
        }
        continuation.resume()
    }
}
