import Darwin
import Combine
import XCTest
@testable import AppUI
@testable import ScanKit

/// v2026.07.18 regression coverage for the rainbow-cursor root cause: wide presentation work and
/// final COW teardown must stay off MainActor, while stale worker results must never overwrite a
/// newer Tree/session revision.
@MainActor
final class ScanCoordinatorPresentationWorkerTests: XCTestCase {
    private func treeRow(_ path: String, bytes: Int64) -> TreeRow {
        TreeRow(
            path: path,
            title: (path as NSString).lastPathComponent,
            bytes: bytes,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
    }

    private func waitForTreeRetirement(_ coordinator: ScanCoordinator) async {
        for _ in 0..<500 {
            if coordinator._treeLifecycleDiagnosticsForTesting().retirementRanOnMainThread != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForSubtreeRescanRetirement(_ coordinator: ScanCoordinator) async {
        for _ in 0..<5_000 {
            if coordinator
                ._subtreeRescanLifecycleDiagnosticsForTesting()
                .retirementRanOnMainThread != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForSessionRetirement(_ coordinator: ScanCoordinator) async {
        for _ in 0..<500 {
            if coordinator._sessionRetirementDiagnosticsForTesting().ranOnMainThread != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForMtimeFallback(
        _ coordinator: ScanCoordinator,
        path: String
    ) async {
        for _ in 0..<500 {
            if coordinator._mtimeFallbackDateForTesting(path) != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func assertProductOnDemandTreePublishesAllDirectChildren(
        _ coordinator: ScanCoordinator,
        categoryID: String,
        fixturePrefix: String
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fixturePrefix)-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let childCount = 96
        var expectedChildNames: [String] = []
        expectedChildNames.reserveCapacity(childCount)
        for index in 0..<childCount {
            let child = parent.appendingPathComponent(
                String(format: "child-%03d", index),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index % 255), count: 1_024).write(
                to: child.appendingPathComponent("payload.bin")
            )
            expectedChildNames.append(child.lastPathComponent)
        }

        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: categoryID,
                rows: [],
                totalBytes: Int64(childCount * 1_024),
                scannedFileCount: childCount,
                isFinished: true,
                elapsed: 1
            ),
            currentRootPath: root.path,
            isScanning: false
        )

        let cacheKey = "\(parent.path)|\(TreeSortKey.nameAsc.rawValue)"
        let shallowTerminal = expectation(description: "complete direct-child identity terminal")
        var publishedRows: [TreeRow] = []
        var fetchingAtTerminal: Bool?
        var rootFetchingAtTerminal: Bool?
        var enrichmentOwnedAtTerminal: Bool?
        var didCaptureTerminal = false
        var cancellable: AnyCancellable?
        cancellable = coordinator.treeBrowser.$childrenCacheVersion
            .dropFirst()
            .sink { @MainActor _ in
                guard !didCaptureTerminal else { return }
                let rows = coordinator._treeChildrenCacheForTesting()[cacheKey] ?? []
                guard rows.count == childCount else { return }
                didCaptureTerminal = true
                publishedRows = rows
                fetchingAtTerminal = coordinator.isFetchingChildren(
                    of: parent.path,
                    sortedBy: .nameAsc
                )
                rootFetchingAtTerminal = coordinator.makeTreeFlatProjectionSource(
                    rootPath: parent.path,
                    sortedBy: .nameAsc,
                    expandedPaths: [parent.path]
                ).isFetchingRoot
                enrichmentOwnedAtTerminal = coordinator
                    ._treeChildrenTaskKeysForTesting()
                    .contains(cacheKey)
                shallowTerminal.fulfill()
            }

        XCTAssertTrue(
            coordinator.directChildren(of: parent.path, sortedBy: .nameAsc).isEmpty,
            "normal cache miss waits for one complete direct-child enumeration; it never emits 64 rows"
        )
        await fulfillment(of: [shallowTerminal], timeout: 5)

        XCTAssertEqual(publishedRows.count, childCount)
        XCTAssertEqual(
            publishedRows.map { ($0.path as NSString).lastPathComponent },
            expectedChildNames
        )
        XCTAssertTrue(publishedRows.allSatisfy(\.isSizePending))
        XCTAssertEqual(
            fetchingAtTerminal,
            true,
            "identity rows are visible immediately, but exact metrics/sort still own loading"
        )
        XCTAssertEqual(rootFetchingAtTerminal, true)
        XCTAssertEqual(
            enrichmentOwnedAtTerminal,
            true,
            "deep enrichment and visible loading must have the same owner"
        )
        XCTAssertEqual(
            coordinator._indexedTreePreviewDiagnosticsForTesting().buildCount,
            0,
            "normal product on-demand Tree must never enter the explicit deep-index 64-row branch"
        )
        cancellable?.cancel()

        for _ in 0..<10_000 {
            let rows = coordinator._treeChildrenCacheForTesting()[cacheKey] ?? []
            if !coordinator._treeChildrenTaskKeysForTesting().contains(cacheKey),
               rows.count == childCount,
               rows.allSatisfy({ !$0.isSizePending }) {
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let enrichedRows = coordinator._treeChildrenCacheForTesting()[cacheKey] ?? []
        XCTAssertEqual(
            enrichedRows.map { ($0.path as NSString).lastPathComponent },
            expectedChildNames
        )
        XCTAssertTrue(enrichedRows.allSatisfy { !$0.isSizePending })
        XCTAssertTrue(enrichedRows.allSatisfy { $0.fileCount == 1 && $0.bytes > 0 })
        XCTAssertFalse(coordinator._treeChildrenTaskKeysForTesting().contains(cacheKey))
        XCTAssertFalse(coordinator._treeChildrenInFlightForTesting().contains(cacheKey))
        XCTAssertFalse(coordinator.isFetchingChildren(of: parent.path, sortedBy: .nameAsc))
    }

    func test_fullDiskProductAdmissionForcesOnDemandTreeAndPublishesAll96Children() async throws {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        coordinator._admitFullDiskTreePolicyForTesting()
        XCTAssertFalse(coordinator.enableTreeDeepIndex)
        try await assertProductOnDemandTreePublishesAllDirectChildren(
            coordinator,
            categoryID: ScanCategory.fullDisk.id,
            fixturePrefix: "FullDiskProductTree"
        )
    }

    func test_developerProductAdmissionForcesOnDemandTreeAndPublishesAll96Children() async throws {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        coordinator._admitDeveloperTreePolicyForTesting()
        XCTAssertFalse(coordinator.enableTreeDeepIndex)
        try await assertProductOnDemandTreePublishesAllDirectChildren(
            coordinator,
            categoryID: ScanCoordinator.developerCategoryID,
            fixturePrefix: "DeveloperProductTree"
        )
    }

    func test_wideTreeWritebackBuildsEverySortAndRetiresOffMainActor() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let root = "/wide-tree"
        let rows = (0..<4_096).map { index in
            treeRow("\(root)/item-\(index)", bytes: Int64(4_096 - index))
        }

        await coordinator._storeFetchedChildrenForTesting(
            path: root,
            sortedBy: .sizeDesc,
            rows: rows
        )
        await waitForTreeRetirement(coordinator)

        let cache = coordinator._treeChildrenCacheForTesting()
        for sortKey in TreeSortKey.allCases {
            XCTAssertEqual(cache["\(root)|\(sortKey.rawValue)"]?.count, rows.count)
        }
        let diagnostics = coordinator._treeLifecycleDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.preparationRanOnMainThread, false)
        XCTAssertEqual(diagnostics.retirementRanOnMainThread, false)
        XCTAssertGreaterThan(diagnostics.retirementDurationNanoseconds ?? 0, 0)
    }

    func test_explicitDeepIndexFixturePublishesBoundedFirstFrameThenCompleteProjection() async {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        let root = "/memory-wide"
        var leaves: [String: Int64] = [:]
        var kids = Set<String>()
        for index in 0..<4_096 {
            let path = "\(root)/item-\(index)"
            leaves[path] = Int64(4_096 - index)
            kids.insert(path)
        }
        coordinator._seedForTesting(
            fileLeavesFull: leaves,
            childEdges: [root: kids]
        )

        let firstFrame = coordinator.directChildren(of: root, sortedBy: .sizeDesc)
        XCTAssertEqual(
            firstFrame.count,
            ScanCoordinator.indexedTreeFirstFramePreviewCapacity,
            "first disclosure must be useful immediately but independent of directory fan-out"
        )
        XCTAssertEqual(firstFrame.map(\.bytes), firstFrame.map(\.bytes).sorted(by: >))
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().contains("\(root)|sizeDesc"))
        XCTAssertNil(
            coordinator._treeChildrenCacheForTesting()["\(root)|sizeDesc"],
            "bounded preview must never enter the authoritative complete-children cache"
        )
        let firstDiagnostics = coordinator._indexedTreePreviewDiagnosticsForTesting()
        XCTAssertEqual(firstDiagnostics.fanOut, kids.count)
        XCTAssertLessThanOrEqual(
            firstDiagnostics.inspectedCount,
            ScanCoordinator.indexedTreeFirstFramePreviewCapacity * 2
        )
        XCTAssertEqual(firstDiagnostics.materializedCount, firstFrame.count)

        let repeatedFrame = coordinator.directChildren(of: root, sortedBy: .sizeDesc)
        XCTAssertEqual(repeatedFrame, firstFrame)
        XCTAssertEqual(
            coordinator._indexedTreePreviewDiagnosticsForTesting().buildCount,
            firstDiagnostics.buildCount,
            "same path/sort/revision must reuse the separate preview cache in O(1)"
        )

        for _ in 0..<10_000 {
            let cache = coordinator._treeChildrenCacheForTesting()
            if TreeSortKey.allCases.allSatisfy({
                cache["\(root)|\($0.rawValue)"]?.count == kids.count
            }) { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        for sortKey in TreeSortKey.allCases {
            XCTAssertEqual(
                coordinator._treeChildrenCacheForTesting()["\(root)|\(sortKey.rawValue)"]?.count,
                kids.count
            )
        }
        let completeSizeRows = coordinator._treeChildrenCacheForTesting()["\(root)|sizeDesc"] ?? []
        XCTAssertEqual(completeSizeRows.map(\.bytes), completeSizeRows.map(\.bytes).sorted(by: >))
        XCTAssertEqual(completeSizeRows.first?.bytes, 4_096)
        XCTAssertFalse(coordinator._treeChildrenInFlightForTesting().contains("\(root)|sizeDesc"))
        XCTAssertEqual(coordinator._indexedTreePreviewDiagnosticsForTesting().cachedEntryCount, 0)
        XCTAssertEqual(
            coordinator._treeLifecycleDiagnosticsForTesting().preparationRanOnMainThread,
            false
        )
    }

    func test_explicitDeepIndexFixture100kGetterIsBoundedAndKeepsMainActorHeartbeat() async {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        let root = "/memory-100k"
        let count = 100_000
        var leaves: [String: Int64] = [:]
        leaves.reserveCapacity(count)
        var kids = Set<String>()
        kids.reserveCapacity(count)
        for index in 0..<count {
            let path = "\(root)/item-\(index)"
            leaves[path] = Int64(count - index)
            kids.insert(path)
        }
        coordinator._seedForTesting(
            fileLeavesFull: leaves,
            childEdges: [root: kids]
        )

        let armed = DispatchSemaphore(value: 0)
        let heartbeat = Task.detached { () -> UInt64 in
            armed.signal()
            try? await Task.sleep(nanoseconds: 1_000_000)
            let requested = DispatchTime.now().uptimeNanoseconds
            return await MainActor.run {
                DispatchTime.now().uptimeNanoseconds - requested
            }
        }
        XCTAssertEqual(armed.wait(timeout: .now() + 1), .success)

        let started = DispatchTime.now().uptimeNanoseconds
        let first = coordinator.directChildren(of: root, sortedBy: .sizeDesc)
        let afterFirst = coordinator._indexedTreePreviewDiagnosticsForTesting()
        let second = coordinator.directChildren(of: root, sortedBy: .sizeDesc)
        let getterElapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertEqual(first.count, ScanCoordinator.indexedTreeFirstFramePreviewCapacity)
        XCTAssertEqual(second, first)
        XCTAssertEqual(afterFirst.fanOut, count)
        XCTAssertLessThanOrEqual(
            afterFirst.inspectedCount,
            ScanCoordinator.indexedTreeFirstFramePreviewCapacity * 2
        )
        XCTAssertEqual(
            coordinator._indexedTreePreviewDiagnosticsForTesting().buildCount,
            afterFirst.buildCount
        )
        XCTAssertLessThan(getterElapsed, 100_000_000, "100k fan-out getter exceeded 100ms")
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().contains("\(root)|sizeDesc"))
        XCTAssertNil(coordinator._treeChildrenCacheForTesting()["\(root)|sizeDesc"])

        // Cancel before yielding to the newly-created MainActor task. This validates that the
        // bounded preview remains non-authoritative and no cancelled full result can arrive later.
        coordinator.cancelOnDemandTreeScansPreservingResults()
        let heartbeatLatency = await heartbeat.value
        XCTAssertLessThan(heartbeatLatency, 150_000_000, "MainActor heartbeat stalled over 150ms")
        await Task.yield()
        XCTAssertNil(coordinator._treeChildrenCacheForTesting()["\(root)|sizeDesc"])
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty)
    }

    func test_explicitDeepIndexFixture100kSortSwitchAvoidsMainActorResort() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let root = "/sort-switch-100k"
        let count = 100_000
        let measured = (0..<count).map { index in
            treeRow("\(root)/item-\(index)", bytes: Int64(count - index))
        }
        coordinator._seedForTesting(treeChildrenCache: ["\(root)|sizeDesc": measured])

        let started = DispatchTime.now().uptimeNanoseconds
        let firstNameFrame = coordinator.directChildren(of: root, sortedBy: .nameAsc)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertEqual(firstNameFrame.first?.path, measured.first?.path)
        XCTAssertEqual(firstNameFrame.last?.path, measured.last?.path)
        XCTAssertLessThan(elapsed, 100_000_000, "sort-key cache miss synchronously resorted 100k rows")
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().contains("\(root)|nameAsc"))
        XCTAssertNil(coordinator._treeChildrenCacheForTesting()["\(root)|nameAsc"])
        coordinator.cancelOnDemandTreeScansPreservingResults()
        await Task.yield()
        XCTAssertNil(coordinator._treeChildrenCacheForTesting()["\(root)|nameAsc"])
    }

    func test_explicitDeepIndexFixtureWorkerRetriesRevisionAndDropsOldTree() async {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        let root = "/memory-revision"
        let oldPaths = Set((0..<2_048).map { "\(root)/old-\($0)" })
        let newPath = "\(root)/new-only"
        coordinator._seedForTesting(
            fileLeaves: Array(oldPaths),
            childEdges: [root: oldPaths]
        )

        await coordinator._prepareIndexedTreeProjectionForTesting(
            path: root,
            sortedBy: .sizeDesc,
            beforeCommit: {
                coordinator._seedForTesting(
                    fileLeavesFull: [newPath: 9_999],
                    childEdges: [root: [newPath]]
                )
            }
        )

        for sortKey in TreeSortKey.allCases {
            XCTAssertEqual(
                coordinator._treeChildrenCacheForTesting()["\(root)|\(sortKey.rawValue)"]?.map(\.path),
                [newPath]
            )
        }
        XCTAssertGreaterThanOrEqual(
            coordinator._treeLifecycleDiagnosticsForTesting().attemptCount,
            2
        )
    }

    func test_explicitDeepIndexFixtureCancellationDropsPreparedOldResult() async {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        let root = "/memory-cancel"
        let paths = Set((0..<4_096).map { "\(root)/item-\($0)" })
        coordinator._seedForTesting(
            fileLeaves: Array(paths),
            childEdges: [root: paths]
        )

        await coordinator._prepareIndexedTreeProjectionForTesting(
            path: root,
            sortedBy: .sizeDesc,
            beforeCommit: {
                coordinator.cancelOnDemandTreeScansPreservingResults()
            }
        )

        XCTAssertTrue(coordinator._treeChildrenCacheForTesting().isEmpty)
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty)
    }

    func test_mtimeContinuationDrainsBeyondPendingWindow() async {
        let coordinator = ScanCoordinator(
            home: NSTemporaryDirectory(),
            enableTreeDeepIndex: true
        )
        let root = "/mtime-continuation-\(UUID().uuidString)"
        let count = 2_304
        var directories: [String] = []
        var kids = Set<String>()
        for index in 0..<count {
            let path = "\(root)/missing-\(index)"
            directories.append(path)
            kids.insert(path)
        }
        coordinator._seedForTesting(
            dirIndex: directories,
            childEdges: [root: kids]
        )

        _ = coordinator.directChildren(of: root, sortedBy: .mtimeDesc)
        for _ in 0..<5_000 {
            let diagnostics = coordinator._mtimeFallbackQueueDiagnosticsForTesting()
            if diagnostics.cachedCount == count,
               diagnostics.pendingCount == 0,
               diagnostics.continuationParentCount == 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let diagnostics = coordinator._mtimeFallbackQueueDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.cachedCount, count)
        XCTAssertEqual(diagnostics.pendingCount, 0)
        XCTAssertEqual(diagnostics.continuationParentCount, 0)
    }

    func test_treeCASRetriesAndPreservesNewerCacheRevision() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let root = "/tree-cas"
        let latePath = "/newer/late"
        let rows = (0..<1_024).map { index in
            treeRow("\(root)/item-\(index)", bytes: Int64(index))
        }

        await coordinator._storeFetchedChildrenForTesting(
            path: root,
            sortedBy: .sizeDesc,
            rows: rows,
            beforeCommit: {
                coordinator._seedForTesting(treeChildrenCache: [
                    "/newer|sizeDesc": [self.treeRow(latePath, bytes: 7)]
                ])
            }
        )

        let cache = coordinator._treeChildrenCacheForTesting()
        XCTAssertEqual(cache["/newer|sizeDesc"]?.first?.path, latePath)
        XCTAssertEqual(cache["\(root)|sizeDesc"]?.count, rows.count)
        XCTAssertGreaterThanOrEqual(
            coordinator._treeLifecycleDiagnosticsForTesting().attemptCount,
            2
        )
    }

    func test_wideAllSortSubtreeRescanPreparesAndRetiresOffMainActor() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let root = "/subtree-rescan-wide"
        let sibling = "/subtree-rescan-wide-sibling"
        let directoryCount = 4_096
        var cache: [String: [TreeRow]] = [:]
        cache.reserveCapacity(directoryCount * TreeSortKey.allCases.count)
        var targetTaskKeys: [String] = []
        targetTaskKeys.reserveCapacity(directoryCount)

        for index in 0..<directoryCount {
            let directory = "\(root)/directory-\(index)"
            for sortKey in TreeSortKey.allCases {
                cache["\(directory)|\(sortKey.rawValue)"] = [
                    treeRow("\(directory)/leaf", bytes: Int64(index + 1))
                ]
            }
            targetTaskKeys.append("\(directory)|\(TreeSortKey.sizeDesc.rawValue)")
        }

        var siblingKeys: [String] = []
        for sortKey in TreeSortKey.allCases {
            let key = "\(sibling)|\(sortKey.rawValue)"
            siblingKeys.append(key)
            cache[key] = [treeRow("\(sibling)/leaf", bytes: 99)]
        }
        coordinator._seedForTesting(treeChildrenCache: cache)
        coordinator._seedTreeChildrenTasksForTesting(keys: targetTaskKeys + siblingKeys)
        cache = [:]

        let cacheVersion = coordinator.childrenCacheVersion
        let structuralRevision = coordinator.structuralRevision
        await coordinator._rescanSubtreeForTesting(at: root)
        await waitForSubtreeRescanRetirement(coordinator)

        let remainingCache = coordinator._treeChildrenCacheForTesting()
        let remainingTaskKeys = coordinator._treeChildrenTaskKeysForTesting()
        let remainingInFlight = coordinator._treeChildrenInFlightForTesting()
        XCTAssertEqual(
            directoryCount * TreeSortKey.allCases.count,
            32_768,
            "fixture must exercise at least 4096 paths across every Tree sort"
        )
        XCTAssertEqual(Set(remainingCache.keys), Set(siblingKeys))
        XCTAssertEqual(remainingTaskKeys, Set(siblingKeys))
        XCTAssertEqual(remainingInFlight, Set(siblingKeys))
        for key in siblingKeys {
            XCTAssertEqual(remainingCache[key]?.first?.path, "\(sibling)/leaf")
        }
        XCTAssertEqual(coordinator.childrenCacheVersion, cacheVersion &+ 1)
        XCTAssertEqual(coordinator.structuralRevision, structuralRevision &+ 1)

        let diagnostics = coordinator._subtreeRescanLifecycleDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.preparationRanOnMainThread, false)
        XCTAssertEqual(diagnostics.retirementRanOnMainThread, false)
        XCTAssertGreaterThan(diagnostics.retirementDurationNanoseconds ?? 0, 0)
        XCTAssertEqual(diagnostics.attemptCount, 1)
    }

    func test_subtreeRescanCASRetriesWithoutOverwritingNewCacheOrTaskOwners() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let root = "/subtree-rescan-cas"
        let initialTargetKey = "\(root)|\(TreeSortKey.sizeDesc.rawValue)"
        let lateTargetKey = "\(root)/late|\(TreeSortKey.nameAsc.rawValue)"
        let initialSurvivorKey = "/survivor/initial|\(TreeSortKey.sizeDesc.rawValue)"
        let lateSurvivorKey = "/survivor/late|\(TreeSortKey.nameAsc.rawValue)"
        coordinator._seedForTesting(treeChildrenCache: [
            initialTargetKey: [treeRow("\(root)/old", bytes: 1)],
            initialSurvivorKey: [treeRow("/survivor/initial/leaf", bytes: 2)]
        ])
        coordinator._seedTreeChildrenTasksForTesting(keys: [
            initialTargetKey,
            initialSurvivorKey
        ])

        await coordinator._rescanSubtreeForTesting(at: root) {
            // Simulate a second refresh/producer commit while the first worker is suspended. Both
            // source and task-owner revisions change, so the first snapshot must be rejected.
            coordinator._seedForTesting(treeChildrenCache: [
                lateTargetKey: [self.treeRow("\(root)/late/leaf", bytes: 3)],
                initialSurvivorKey: [self.treeRow("/survivor/initial/new", bytes: 4)],
                lateSurvivorKey: [self.treeRow("/survivor/late/leaf", bytes: 5)]
            ])
            coordinator._seedTreeChildrenTasksForTesting(keys: [
                lateTargetKey,
                lateSurvivorKey
            ])
        }
        await waitForSubtreeRescanRetirement(coordinator)

        let cache = coordinator._treeChildrenCacheForTesting()
        XCTAssertNil(cache[initialTargetKey])
        XCTAssertNil(cache[lateTargetKey])
        XCTAssertEqual(cache[initialSurvivorKey]?.first?.bytes, 4)
        XCTAssertEqual(cache[lateSurvivorKey]?.first?.bytes, 5)

        let taskKeys = coordinator._treeChildrenTaskKeysForTesting()
        XCTAssertFalse(taskKeys.contains(initialTargetKey))
        XCTAssertFalse(taskKeys.contains(lateTargetKey))
        XCTAssertTrue(taskKeys.contains(initialSurvivorKey))
        XCTAssertTrue(taskKeys.contains(lateSurvivorKey))
        XCTAssertEqual(coordinator._treeChildrenInFlightForTesting(), taskKeys)
        let diagnostics = coordinator._subtreeRescanLifecycleDiagnosticsForTesting()
        XCTAssertGreaterThanOrEqual(diagnostics.attemptCount, 2)
        XCTAssertEqual(diagnostics.preparationRanOnMainThread, false)
        XCTAssertEqual(diagnostics.retirementRanOnMainThread, false)
    }

    /// v2026.07.18 regression: an indexed refresh must replace the actual graph, aggregates and
    /// typed evidence. Clearing projection rows alone would make this fixture immediately replay
    /// `stale.bin` from childEdges.
    func test_indexedSubtreeRefreshRebuildsRealFilesystemGraphAndClearsRecoveredEvidence() async throws {
        let fm = FileManager.default
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("indexed-refresh-\(UUID().uuidString)", isDirectory: true)
        let target = fixtureRoot.appendingPathComponent("Cache", isDirectory: true)
        let samePrefixSibling = fixtureRoot.appendingPathComponent("Cache-old", isDirectory: true)
        let freshDirectory = target.appendingPathComponent("fresh", isDirectory: true)
        let freshNestedFile = freshDirectory.appendingPathComponent("nested.bin")
        let freshDirectFile = target.appendingPathComponent("direct.bin")
        try fm.createDirectory(at: freshDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: samePrefixSibling, withIntermediateDirectories: true)
        try Data(repeating: 0x3A, count: 8 * 1_024).write(to: freshNestedFile)
        try Data(repeating: 0x4B, count: 4 * 1_024).write(to: freshDirectFile)
        defer { try? fm.removeItem(at: fixtureRoot) }

        let staleFile = target.appendingPathComponent("stale.bin").path
        let siblingFile = samePrefixSibling.appendingPathComponent("keep.bin").path
        let coordinator = ScanCoordinator(home: fixtureRoot.path, enableTreeDeepIndex: true)
        coordinator._seedForTesting(
            currentRootPath: fixtureRoot.path,
            dirIndexFull: [
                fixtureRoot.path: (bytes: 101, fileCount: 2),
                target.path: (bytes: 100, fileCount: 1),
                samePrefixSibling.path: (bytes: 1, fileCount: 1)
            ],
            fileLeavesFull: [staleFile: 100, siblingFile: 1],
            childEdges: [
                fixtureRoot.path: [target.path, samePrefixSibling.path],
                target.path: [staleFile],
                samePrefixSibling.path: [siblingFile]
            ],
            treeChildrenCache: [
                "\(target.path)|\(TreeSortKey.sizeDesc.rawValue)": [
                    treeRow(staleFile, bytes: 100)
                ],
                "\(samePrefixSibling.path)|\(TreeSortKey.sizeDesc.rawValue)": [
                    treeRow(siblingFile, bytes: 1)
                ]
            ]
        )
        coordinator._replaceTreeIncompleteEvidenceForTesting(
            rootPath: target.path,
            issues: [ScanIncompleteIssue(
                path: target.appendingPathComponent("old-denied").path,
                reason: .permissionDenied,
                stage: .open,
                posixErrorCode: EACCES
            )]
        )

        await coordinator.rescanSubtree(at: target.path)

        let edges = coordinator._childEdgesForTesting()
        XCTAssertEqual(edges[target.path], [freshDirectory.path, freshDirectFile.path])
        XCTAssertEqual(edges[freshDirectory.path], [freshNestedFile.path])
        XCTAssertFalse(edges[target.path]?.contains(staleFile) ?? true)
        XCTAssertEqual(edges[samePrefixSibling.path], [siblingFile])
        XCTAssertEqual(coordinator._dirIndexAggForTesting(target.path)?.fileCount, 2)
        XCTAssertEqual(coordinator._dirIndexAggForTesting(freshDirectory.path)?.fileCount, 1)
        XCTAssertTrue(coordinator._fileLeavesKeysForTesting().contains(freshNestedFile.path))
        XCTAssertFalse(coordinator._fileLeavesKeysForTesting().contains(staleFile))
        XCTAssertTrue(coordinator.incompleteIssues(overlappingAny: [target.path]).isEmpty)

        let cache = coordinator._treeChildrenCacheForTesting()
        for sortKey in TreeSortKey.allCases {
            XCTAssertEqual(
                Set(cache["\(target.path)|\(sortKey.rawValue)"]?.map(\.path) ?? []),
                [freshDirectory.path, freshDirectFile.path]
            )
        }
        XCTAssertEqual(
            cache["\(samePrefixSibling.path)|\(TreeSortKey.sizeDesc.rawValue)"]?.first?.path,
            siblingFile
        )
        XCTAssertEqual(
            coordinator._subtreeRescanLifecycleDiagnosticsForTesting().preparationRanOnMainThread,
            false
        )
    }

    /// v2026.07.18 regression: a newer refresh owns the only commit right. The older completed
    /// measurement must not overwrite the filesystem generation produced after its CAS hook.
    func test_overlappingRealSubtreeRefreshLetsOnlyNewestRequestCommit() async throws {
        let fm = FileManager.default
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("indexed-refresh-cas-\(UUID().uuidString)", isDirectory: true)
        let target = fixtureRoot.appendingPathComponent("Cache", isDirectory: true)
        let oldFile = target.appendingPathComponent("old.bin")
        let newestFile = target.appendingPathComponent("newest.bin")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: 2_048).write(to: oldFile)
        defer { try? fm.removeItem(at: fixtureRoot) }

        let coordinator = ScanCoordinator(home: fixtureRoot.path, enableTreeDeepIndex: true)
        coordinator._seedForTesting(
            currentRootPath: fixtureRoot.path,
            dirIndexFull: [target.path: (bytes: 1, fileCount: 1)],
            fileLeavesFull: [oldFile.path: 1],
            childEdges: [target.path: [oldFile.path]]
        )

        await coordinator._rescanIndexedSubtreeForTesting(at: target.path) {
            _ = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.removeItem(at: oldFile)
                try? Data(repeating: 0x2, count: 4_096).write(to: newestFile)
            }.value
            await coordinator.rescanSubtree(at: target.path)
        }

        XCTAssertEqual(coordinator._childEdgesForTesting()[target.path], [newestFile.path])
        XCTAssertTrue(coordinator._fileLeavesKeysForTesting().contains(newestFile.path))
        XCTAssertFalse(coordinator._fileLeavesKeysForTesting().contains(oldFile.path))
        XCTAssertEqual(
            coordinator._treeChildrenCacheForTesting()[
                "\(target.path)|\(TreeSortKey.sizeDesc.rawValue)"
            ]?.map(\.path),
            [newestFile.path]
        )
    }

    /// v2026.07.18: a root that cannot be measured is not proof that its old contents vanished.
    /// Preserve the last lower bound and publish typed metadata evidence instead of clearing it.
    func test_partialIndexedRefreshPreservesOldGraphAndPublishesTypedEvidence() async {
        let target = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("missing-indexed-refresh-\(UUID().uuidString)", isDirectory: true)
        let oldLeaf = target.appendingPathComponent("last-known.bin").path
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory(), enableTreeDeepIndex: true)
        coordinator._seedForTesting(
            dirIndexFull: [target.path: (bytes: 8_192, fileCount: 1)],
            fileLeavesFull: [oldLeaf: 8_192],
            childEdges: [target.path: [oldLeaf]]
        )

        await coordinator.rescanSubtree(at: target.path)

        XCTAssertEqual(coordinator._childEdgesForTesting()[target.path], [oldLeaf])
        XCTAssertEqual(coordinator._dirIndexAggForTesting(target.path)?.bytes, 8_192)
        XCTAssertTrue(coordinator._fileLeavesKeysForTesting().contains(oldLeaf))
        XCTAssertEqual(
            coordinator.incompleteIssues(overlappingAny: [target.path]).map(\.reason),
            [.metadataUnavailable]
        )
        XCTAssertEqual(
            coordinator.incompleteIssues(overlappingAny: [target.path]).map(\.stage),
            [.metadata]
        )
    }

    func test_subtreeCacheIdentityHandlesFilesystemRootAndSamePrefixSiblings() {
        XCTAssertTrue(ScanCoordinator._subtreeCacheKeyBelongsForTesting(
            "/|sizeDesc",
            rootPath: "/"
        ))
        XCTAssertTrue(ScanCoordinator._subtreeCacheKeyBelongsForTesting(
            "/System/Library|nameAsc",
            rootPath: "/"
        ))
        XCTAssertFalse(ScanCoordinator._subtreeCacheKeyBelongsForTesting(
            "relative/path|nameAsc",
            rootPath: "/"
        ))
        XCTAssertTrue(ScanCoordinator._subtreeCacheKeyBelongsForTesting(
            "/tmp/Cache/child|mtimeDesc",
            rootPath: "/tmp/Cache"
        ))
        XCTAssertFalse(ScanCoordinator._subtreeCacheKeyBelongsForTesting(
            "/tmp/Cache-old|mtimeDesc",
            rootPath: "/tmp/Cache"
        ))
        XCTAssertFalse(ScanCoordinator._subtreeCacheKeyBelongsForTesting(
            "/tmp/Caches|mtimeDesc",
            rootPath: "/tmp/Cache"
        ))
    }

    func test_cancelSwapsWideSessionStateBeforeBackgroundRetirement() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let rows = (0..<4_096).map { index -> RowItem in
            let path = "/session-old/item-\(index)"
            return RowItem(
                id: path,
                url: URL(fileURLWithPath: path),
                title: "item-\(index)",
                isDirectory: false,
                bytes: Int64(index + 1),
                logicalBytes: Int64(index + 1),
                fileCount: 1,
                verdict: .safe,
                rejection: .ok
            )
        }
        let treeRows = rows.map { treeRow($0.id, bytes: $0.bytes) }
        coordinator._seedForTesting(
            snapshot: ScanSnapshot(
                categoryID: "old-session",
                rows: rows,
                totalBytes: rows.reduce(0) { $0 &+ $1.bytes },
                scannedFileCount: rows.count,
                isFinished: true,
                elapsed: 1
            ),
            treeChildrenCache: ["/session-old|sizeDesc": treeRows]
        )

        coordinator.cancel()
        XCTAssertTrue(coordinator.snapshot.rows.isEmpty)
        XCTAssertTrue(coordinator._treeChildrenCacheForTesting().isEmpty)
        await waitForSessionRetirement(coordinator)

        let diagnostics = coordinator._sessionRetirementDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.ranOnMainThread, false)
        XCTAssertGreaterThan(diagnostics.durationNanoseconds ?? 0, 0)
    }

    func test_nonterminalPerRootProjectionRunsOffMainActorWithoutBuildingTreeSorts() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        var staging: [String: ScanCoordinator.PerRootProgress] = [:]
        for index in 0..<2_048 {
            let path = "/roots/root-\(index)"
            staging[path] = ScanCoordinator.PerRootProgress(
                rootPath: path,
                title: "root-\(index)",
                bytes: Int64(index),
                fileCount: 1,
                isFinished: index.isMultiple(of: 2)
            )
        }
        coordinator._seedForTesting(isScanning: true, perRootStaging: staging)

        await coordinator._syncPerRootPublishedOffMainForTesting()

        XCTAssertEqual(coordinator._perRootPreparationRanOnMainThreadForTesting(), false)
        XCTAssertEqual(coordinator.perRootProgressSorted.count, staging.count)
        XCTAssertTrue(coordinator._perRootTreeRowsForTesting(.nameAsc).isEmpty)
        XCTAssertTrue(coordinator._perRootTreeRowsForTesting(.sizeDesc).isEmpty)
        let diagnostics = coordinator._livePerRootProjectionDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.maxActiveWorkerCount, 1)
        XCTAssertEqual(diagnostics.buildCount, 1)
        XCTAssertEqual(diagnostics.commitCount, 1)
    }

    func test_developerDiscoveryProgressDoesNotRetainStagingInAsyncProjectionWorker() {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        var staging: [String: ScanCoordinator.PerRootProgress] = [:]
        for index in 0..<2_048 {
            let path = "/developer/root-\(index)"
            staging[path] = ScanCoordinator.PerRootProgress(
                rootPath: path,
                title: "root-\(index)",
                bytes: Int64(index),
                fileCount: 1,
                isFinished: false
            )
        }
        coordinator._seedForTesting(isScanning: true, perRootStaging: staging)

        coordinator._publishDeveloperDiscoveryProgressForTesting()

        XCTAssertEqual(coordinator.perRootProgressSorted.count, staging.count)
        let diagnostics = coordinator._livePerRootProjectionDiagnosticsForTesting()
        XCTAssertFalse(diagnostics.ownerIsRunning)
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        XCTAssertEqual(diagnostics.activeWorkerCount, 0)
        XCTAssertEqual(diagnostics.buildCount, 0)
    }

    func test_overlappingPerRootRequestsCoalesceToOneWorkerAndLatestSnapshot() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        var original: [String: ScanCoordinator.PerRootProgress] = [:]
        for index in 0..<4_096 {
            let path = "/roots/original-\(index)"
            original[path] = ScanCoordinator.PerRootProgress(
                rootPath: path,
                title: "original-\(index)"
            )
        }
        let first = Task { @MainActor in
            await coordinator._requestLivePerRootProjectionForTesting(
                staging: original,
                preparationDelayNanoseconds: 100_000_000
            )
        }

        for _ in 0..<1_000 {
            if coordinator
                ._livePerRootProjectionDiagnosticsForTesting()
                .activeWorkerCount == 1 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(
            coordinator._livePerRootProjectionDiagnosticsForTesting().activeWorkerCount,
            1
        )

        var latestPath = ""
        for revision in 0..<32 {
            latestPath = "/roots/latest-\(revision)"
            let latest = [
                latestPath: ScanCoordinator.PerRootProgress(
                    rootPath: latestPath,
                    title: "latest-\(revision)",
                    bytes: Int64(revision),
                    fileCount: 1,
                    isFinished: true
                )
            ]
            await coordinator._requestLivePerRootProjectionForTesting(
                staging: latest,
                waitForDrain: false
            )
        }
        await first.value

        XCTAssertEqual(coordinator.perRootProgressSorted.map(\.rootPath), [latestPath])
        let diagnostics = coordinator._livePerRootProjectionDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.maxActiveWorkerCount, 1)
        XCTAssertEqual(diagnostics.activeWorkerCount, 0)
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        XCTAssertEqual(diagnostics.buildCount, 2, "32 overlapping updates must collapse to latest")
        XCTAssertEqual(diagnostics.commitCount, 1)
        XCTAssertEqual(diagnostics.staleDropCount, 1)
        XCTAssertEqual(diagnostics.coalescedRequestCount, 32)
        XCTAssertTrue(coordinator._perRootTreeRowsForTesting(.sizeDesc).isEmpty)
    }

    func test_livePerRootPresentationCommitDoesNotAdvanceSourceRevision() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let path = "/roots/revision"
        coordinator._seedForTesting(perRootStaging: [
            path: ScanCoordinator.PerRootProgress(
                rootPath: path,
                title: "revision",
                bytes: 1,
                fileCount: 1
            )
        ])
        let before = coordinator
            ._livePerRootProjectionDiagnosticsForTesting()
            .sourceRevision

        await coordinator._syncPerRootPublishedOffMainForTesting()

        let after = coordinator
            ._livePerRootProjectionDiagnosticsForTesting()
            .sourceRevision
        XCTAssertEqual(after, before)
        XCTAssertEqual(coordinator.perRootProgressSorted.map(\.rootPath), [path])
    }

    func test_livePerRootDrainLogIsSilentOnFastSingleRequestButReportsAmplification() {
        XCTAssertFalse(
            ScanCoordinator._shouldEmitLivePerRootProjectionDrainLogForTesting(
                elapsedMilliseconds: 99.99,
                coalescedRequests: 0,
                staleDrops: 0
            )
        )
        XCTAssertTrue(
            ScanCoordinator._shouldEmitLivePerRootProjectionDrainLogForTesting(
                elapsedMilliseconds: 1,
                coalescedRequests: 1,
                staleDrops: 0
            )
        )
        XCTAssertTrue(
            ScanCoordinator._shouldEmitLivePerRootProjectionDrainLogForTesting(
                elapsedMilliseconds: 1,
                coalescedRequests: 0,
                staleDrops: 1
            )
        )
        XCTAssertTrue(
            ScanCoordinator._shouldEmitLivePerRootProjectionDrainLogForTesting(
                elapsedMilliseconds: 100,
                coalescedRequests: 0,
                staleDrops: 0
            )
        )
    }

    func test_mtimeFallbackIsCoalescedAndProbedOffMainActor() async throws {
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mtime-worker-\(UUID().uuidString)", isDirectory: true)
        let child = fixtureRoot.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let coordinator = ScanCoordinator(home: fixtureRoot.path)
        coordinator._seedForTesting(
            dirIndex: [child.path],
            childEdges: [fixtureRoot.path: [child.path]]
        )

        let firstFrame = coordinator.directChildren(of: fixtureRoot.path, sortedBy: .mtimeDesc)
        XCTAssertNil(firstFrame.first?.modificationDate)
        await waitForMtimeFallback(coordinator, path: child.path)

        XCTAssertNotNil(coordinator._mtimeFallbackDateForTesting(child.path))
        XCTAssertEqual(
            coordinator._mtimeFallbackDiagnosticsForTesting().preparationRanOnMainThread,
            false
        )
    }

    func test_mtimeFallbackDropsResultAfterSessionGenerationChanges() async throws {
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mtime-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        await coordinator._probeMtimeFallbackForTesting(paths: [fixtureRoot.path]) {
            coordinator.cancel()
        }

        XCTAssertNil(coordinator._mtimeFallbackDateForTesting(fixtureRoot.path))
    }

    func test_mtimeBatchPatchesWideParentWithOnlyTwoSorts() async throws {
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mtime-sort-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        var paths: [String] = []
        var rows: [TreeRow] = []
        for index in 0..<256 {
            let child = fixtureRoot.appendingPathComponent(
                "child-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: child,
                withIntermediateDirectories: false
            )
            paths.append(child.path)
            rows.append(TreeRow(
                path: child.path,
                title: child.lastPathComponent,
                bytes: Int64(index),
                fileCount: 1,
                isDirectory: true,
                hasChildren: false
            ))
        }
        var cache: [String: [TreeRow]] = [:]
        for sortKey in TreeSortKey.allCases {
            cache["\(fixtureRoot.path)|\(sortKey.rawValue)"] = rows
        }
        let coordinator = ScanCoordinator(home: fixtureRoot.path)
        coordinator._seedForTesting(treeChildrenCache: cache)

        await coordinator._probeMtimeFallbackForTesting(paths: paths)

        XCTAssertEqual(
            coordinator._mtimeFallbackDiagnosticsForTesting().preparationRanOnMainThread,
            false
        )
        XCTAssertEqual(
            coordinator._mtimeFallbackDiagnosticsForTesting().treeSortCount,
            2,
            "one parent/batch may reorder only mtimeAsc and mtimeDesc"
        )
        XCTAssertNotNil(coordinator._mtimeFallbackDateForTesting(paths[0]))
        XCTAssertNotNil(coordinator._mtimeFallbackDateForTesting(paths[255]))
    }

    func test_finishedMainListSortUsesPresentationWorker() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let rows = (0..<4_096).map { index -> RowItem in
            let path = "/main-sort/item-\(index)"
            let bytes = Int64(4_096 - index)
            return RowItem(
                id: path,
                url: URL(fileURLWithPath: path),
                title: "item-\(index)",
                isDirectory: false,
                bytes: bytes,
                logicalBytes: bytes,
                fileCount: 1,
                verdict: .safe,
                rejection: .ok
            )
        }
        coordinator._seedForTesting(snapshot: ScanSnapshot(
            categoryID: "wide-main-sort",
            rows: rows,
            totalBytes: rows.reduce(0) { $0 &+ $1.bytes },
            scannedFileCount: rows.count,
            isFinished: true,
            elapsed: 1
        ))

        coordinator.mainListSortKey = .sizeAsc
        for _ in 0..<5_000 {
            if coordinator.snapshot.rows.first?.bytes == 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(coordinator.snapshot.rows.first?.bytes, 1)
        XCTAssertEqual(
            coordinator._treeLifecycleDiagnosticsForTesting().preparationRanOnMainThread,
            false
        )
    }
}
