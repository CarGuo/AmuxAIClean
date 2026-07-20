import ScanKit
import XCTest
@testable import AppUI

/// v2026.07.18 regression coverage for terminal projection materialization.
///
/// A projection is bounded by visible rows rather than a fixed Top-N. These tests therefore pin
/// both halves of the transaction: all width-dependent work stays off MainActor, and stale COW
/// output cannot overwrite a newer scan generation or prune-source revision.
@MainActor
final class TerminalProjectionPreparationTests: XCTestCase {
    func test_wideTerminalProjectionMaterializesVerdictsAndSortsOffMainThread() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-wide-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        var entries: [ScanTopLevelEntry] = []
        entries.reserveCapacity(2_048)
        for index in 0..<2_048 {
            entries.append(ScanTopLevelEntry(
                path: "/terminal-wide/item-\(index)",
                allocatedBytes: Int64(2_048 - index) * 4_096,
                logicalBytes: Int64(2_048 - index) * 4_096,
                fileCount: index + 1,
                isDirectory: true,
                hasChildren: true,
                modificationDate: nil
            ))
        }

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: entries,
            rootPath: "/terminal-wide",
            categoryID: categoryID,
            generation: generation
        )

        XCTAssertTrue(result.committed)
        XCTAssertEqual(result.preparationRanOnMainThread, false)
        XCTAssertEqual(result.retirementRanOnMainThread, false)
        XCTAssertEqual(result.perRootRanOnMainThread, false)
        XCTAssertEqual(result.safetyEvaluationCount, entries.count)
        XCTAssertEqual(result.safetyWorkerCount, 4)
        XCTAssertFalse(result.safetyWorkerObservedMainThread)
        XCTAssertEqual(result.rows.count, entries.count)
        XCTAssertEqual(result.rows.first?.bytes, entries.first?.allocatedBytes)
        XCTAssertEqual(result.rows.last?.bytes, entries.last?.allocatedBytes)
        XCTAssertTrue(zip(result.rows, result.rows.dropFirst()).allSatisfy { lhs, rhs in
            lhs.bytes >= rhs.bytes
        })
        XCTAssertEqual(
            coordinator.snapshot.safeBytes,
            result.rows.lazy.filter { $0.verdict == .safe }.reduce(0) { $0 &+ $1.bytes }
        )
        XCTAssertEqual(
            coordinator.snapshot.confirmBytes,
            result.rows.lazy.filter { $0.verdict == .confirm }.reduce(0) { $0 &+ $1.bytes }
        )
        XCTAssertEqual(
            coordinator.snapshot.forbidBytes,
            result.rows.lazy.filter { $0.verdict == .forbid }.reduce(0) { $0 &+ $1.bytes }
        )
        XCTAssertEqual(coordinator.snapshot.maxRowBytes, result.rows.map(\.bytes).max())
        for row in result.rows {
            let expected = coordinator.deletionSafetyEvaluation(for: row.id)
            XCTAssertEqual(row.verdict, expected.verdict)
            XCTAssertEqual(row.rejection, expected.rejection)
            XCTAssertEqual(row.vendorName, expected.vendor?.name)
        }
    }

    /// v2026.07.19 regression: the developer primary scan already paid for a complete `.topLevel`
    /// projection per artifact root. Disclosure must consume that terminal evidence directly;
    /// starting the shallow/deep Tree producer here repeats the same filesystem traversal and is
    /// exactly the long post-scan loading reported from the real App log.
    func test_developerTerminalProjectionMakesFirstDisclosureACacheHitWithoutFilesystemLease() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let rootPath = "/developer-terminal-\(UUID().uuidString)"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: ScanCoordinator.developerCategoryID
        )
        let entries = [
            ScanTopLevelEntry(
                path: rootPath + "/small",
                allocatedBytes: 4_096,
                logicalBytes: 8_192,
                fileCount: 2,
                isDirectory: true,
                hasChildren: true,
                modificationDate: nil
            ),
            ScanTopLevelEntry(
                path: rootPath + "/large",
                allocatedBytes: 16_384,
                logicalBytes: 32_768,
                fileCount: 8,
                isDirectory: true,
                hasChildren: true,
                modificationDate: nil
            )
        ]

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: entries,
            rootPath: rootPath,
            categoryID: ScanCoordinator.developerCategoryID,
            generation: generation
        )

        XCTAssertTrue(result.committed)
        let cache = coordinator._treeChildrenCacheForTesting()
        for sortKey in TreeSortKey.allCases {
            XCTAssertEqual(
                cache["\(rootPath)|\(sortKey.rawValue)"]?.count,
                entries.count,
                "developer terminal must prepare every Tree ordering off-main"
            )
        }

        let rows = coordinator.directChildren(of: rootPath, sortedBy: .sizeDesc)
        XCTAssertEqual(rows.map(\.path), [rootPath + "/large", rootPath + "/small"])
        XCTAssertEqual(rows.map(\.bytes), [16_384, 4_096])
        XCTAssertTrue(rows.allSatisfy { !$0.isSizePending })
        XCTAssertTrue(coordinator._treeChildrenTaskKeysForTesting().isEmpty)
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty)
        XCTAssertFalse(coordinator.isFetchingChildren(of: rootPath, sortedBy: .sizeDesc))
        let leases = await coordinator._treeFilesystemLeaseDiagnosticsForTesting()
        XCTAssertEqual(leases.active, 0)
        XCTAssertEqual(leases.waiting, 0)
        XCTAssertEqual(leases.reserved, 0)
    }

    /// The developer Tree is rooted at the multi-root sentinel, whose first tier comes from
    /// `perRootTreeRowsBySort`. Its terminal child rows must therefore populate only the
    /// producer-root cache; rebuilding the same wide row set into eight unused global Tree sorts
    /// is both semantically redundant and a measured terminal-drain regression.
    func test_developerWideTerminalSkipsGlobalTreeSortsAndKeepsEveryDirectChild() async {
        let coordinator = ScanCoordinator(home: NSTemporaryDirectory())
        let rootPath = "/developer-wide-terminal-\(UUID().uuidString)"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: ScanCoordinator.developerCategoryID
        )
        var entries: [ScanTopLevelEntry] = []
        entries.reserveCapacity(2_048)
        for index in 0..<2_048 {
            entries.append(ScanTopLevelEntry(
                path: rootPath + "/child-\(index)",
                allocatedBytes: Int64(index + 1) * 4_096,
                logicalBytes: Int64(index + 1) * 8_192,
                fileCount: index + 1,
                isDirectory: true,
                hasChildren: true,
                modificationDate: nil
            ))
        }

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: entries,
            rootPath: rootPath,
            categoryID: ScanCoordinator.developerCategoryID,
            generation: generation
        )

        XCTAssertTrue(result.committed)
        XCTAssertEqual(result.safetyEvaluationCount, entries.count)
        XCTAssertEqual(result.safetyWorkerCount, 4)
        XCTAssertFalse(result.safetyWorkerObservedMainThread)
        for sortKey in TreeSortKey.allCases {
            XCTAssertTrue(
                coordinator._snapshotTreeRowsForTesting(sortKey).isEmpty,
                "developer sentinel must not build an unused global terminal Tree ordering"
            )
            XCTAssertEqual(
                coordinator._treeChildrenCacheForTesting()[
                    "\(rootPath)|\(sortKey.rawValue)"
                ]?.count,
                entries.count
            )
        }
        XCTAssertEqual(
            coordinator.directChildren(of: rootPath, sortedBy: .sizeDesc).map(\.bytes),
            entries.reversed().map { $0.allocatedBytes }
        )
        XCTAssertTrue(coordinator._treeChildrenTaskKeysForTesting().isEmpty)
        XCTAssertTrue(coordinator._treeChildrenInFlightForTesting().isEmpty)
    }

    func test_wideOldTerminalContainersAreProjectedAndFinallyRetiredOffMainThread() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-retirement-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        let count = 2_048
        coordinator._seedWideTerminalRetirementStateForTesting(count: count)
        XCTAssertEqual(coordinator.snapshot.rows.count, count)
        XCTAssertEqual(coordinator.perRootProgressSorted.count, count)
        XCTAssertEqual(coordinator.incompleteScanIssues.count, count)

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: [],
            rootPath: "/terminal-retirement",
            categoryID: categoryID,
            generation: generation
        )

        XCTAssertTrue(result.committed)
        XCTAssertEqual(result.preparationRanOnMainThread, false)
        XCTAssertEqual(result.evidenceRanOnMainThread, false)
        XCTAssertEqual(result.perRootRanOnMainThread, false)
        XCTAssertEqual(result.retirementRanOnMainThread, false)
        XCTAssertEqual(result.rows.count, count)
        XCTAssertTrue(coordinator.perRootProgressActive.isEmpty)
        XCTAssertTrue(coordinator.perRootFinishedSlim.isEmpty)
        XCTAssertTrue(coordinator.perRootProgressSorted.isEmpty)
        XCTAssertTrue(coordinator.incompleteScanIssues.isEmpty)
        XCTAssertTrue(coordinator.permissionDeniedPaths.isEmpty)
        XCTAssertTrue(coordinator.tccProtectedSkippedPaths.isEmpty)
        XCTAssertTrue(coordinator.incompleteScanPaths.isEmpty)
    }

    func test_generationChangeDropsPreparedTerminalProjection() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-generation-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        let entry = ScanTopLevelEntry(
            path: "/terminal-generation/stale",
            allocatedBytes: 4_096,
            logicalBytes: 4_096,
            fileCount: 1,
            isDirectory: true,
            hasChildren: true,
            modificationDate: nil
        )

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: [entry],
            rootPath: "/terminal-generation",
            categoryID: categoryID,
            generation: generation,
            beforeCommit: {
                coordinator._invalidateTerminalPreparationGenerationForTesting()
            }
        )

        XCTAssertFalse(result.committed)
        XCTAssertEqual(result.retirementRanOnMainThread, false,
                       "rejected wide DTO storage must be released by its worker actor")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(coordinator._bucketsKeysForTesting().isEmpty,
                      "old generation must not write even when categoryID is unchanged")
    }

    func test_wideIncompleteEvidenceMergeAndRetirementStayOffMainThread() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-evidence-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        var issues: [ScanIncompleteIssue] = []
        issues.reserveCapacity(2_048)
        for index in 0..<2_048 {
            issues.append(ScanIncompleteIssue(
                path: "/terminal-evidence/root-\(index)/child",
                reason: index.isMultiple(of: 2) ? .metadataUnavailable : .permissionDenied,
                stage: .metadata
            ))
        }
        coordinator._testRecordIncompleteEvidenceWithoutPublishing(issues)

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: [],
            rootPath: "/terminal-evidence",
            categoryID: categoryID,
            generation: generation
        )

        XCTAssertTrue(result.committed)
        XCTAssertEqual(result.evidenceRanOnMainThread, false)
        XCTAssertEqual(result.retirementRanOnMainThread, false)
        XCTAssertEqual(result.evidenceIssueCount, issues.count)
        XCTAssertEqual(coordinator.incompleteScanIssues.count, issues.count)
        XCTAssertEqual(coordinator.incompleteScanPaths.count, issues.count)
    }

    func test_sourceRevisionChangeRetriesAgainstNewestBucketsBeforeCommit() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-revision-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        let projected = ScanTopLevelEntry(
            path: "/terminal-revision/projected",
            allocatedBytes: 10,
            logicalBytes: 10,
            fileCount: 1,
            isDirectory: true,
            hasChildren: true,
            modificationDate: nil
        )

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: [projected],
            rootPath: "/terminal-revision",
            categoryID: categoryID,
            generation: generation,
            beforeCommit: {
                coordinator._seedForTesting(
                    buckets: ["/terminal-revision/concurrent": 99]
                )
            }
        )

        XCTAssertTrue(result.committed)
        XCTAssertGreaterThanOrEqual(result.attemptCount, 2)
        XCTAssertEqual(Set(coordinator._bucketsKeysForTesting()), Set([
            "/terminal-revision/concurrent",
            "/terminal-revision/projected"
        ]))
        XCTAssertEqual(result.rows.map(\.bytes), [99, 10],
                       "revision mismatch must retry from the newest COW source, not overwrite it")
    }

    func test_sortChangeDuringPreparationRetriesWithCurrentPresentationContract() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-sort-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        let entries = [
            ScanTopLevelEntry(
                path: "/terminal-sort/large",
                allocatedBytes: 100,
                logicalBytes: 100,
                fileCount: 1,
                isDirectory: true,
                hasChildren: true,
                modificationDate: nil
            ),
            ScanTopLevelEntry(
                path: "/terminal-sort/small",
                allocatedBytes: 1,
                logicalBytes: 1,
                fileCount: 1,
                isDirectory: true,
                hasChildren: true,
                modificationDate: nil
            )
        ]

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: entries,
            rootPath: "/terminal-sort",
            categoryID: categoryID,
            generation: generation,
            beforeCommit: {
                coordinator.mainListSortKey = .sizeAsc
            }
        )

        XCTAssertTrue(result.committed)
        XCTAssertGreaterThanOrEqual(result.attemptCount, 2)
        XCTAssertEqual(result.rows.map(\.bytes), [1, 100])
    }

    func test_evidenceRevisionChangeRetriesAndIncludesNewestIssue() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-evidence-revision-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        let lateIssue = ScanIncompleteIssue(
            path: "/terminal-evidence-revision/late",
            reason: .metadataUnavailable,
            stage: .metadata
        )

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: [],
            rootPath: "/terminal-evidence-revision",
            categoryID: categoryID,
            generation: generation,
            beforeCommit: {
                coordinator._testRecordIncompleteEvidenceWithoutPublishing([lateIssue])
            }
        )

        XCTAssertTrue(result.committed)
        XCTAssertGreaterThanOrEqual(result.attemptCount, 2)
        XCTAssertEqual(result.evidenceIssueCount, 1)
        XCTAssertEqual(coordinator.incompleteScanIssues, [lateIssue])
    }

    func test_localeChangeDuringPreparationInvalidatesOldPresentationDTO() async {
        let coordinator = ScanCoordinator(home: NSHomeDirectory())
        let categoryID = "terminal-locale-test"
        let generation = coordinator._beginTerminalPreparationSessionForTesting(
            categoryID: categoryID
        )
        let previousLocale = coordinator._presentationLocaleIdentifierForTesting
        let nextLocale = Locale(identifier: previousLocale.hasPrefix("en") ? "zh-Hans" : "en")

        let result = await coordinator._prepareTerminalProjectionForTesting(
            entries: [],
            rootPath: "/terminal-locale",
            categoryID: categoryID,
            generation: generation,
            beforeCommit: {
                coordinator.updatePresentationLocale(nextLocale)
            }
        )

        XCTAssertTrue(result.committed)
        XCTAssertGreaterThanOrEqual(result.attemptCount, 2)
        XCTAssertEqual(coordinator._presentationLocaleIdentifierForTesting, nextLocale.identifier)
    }
}
