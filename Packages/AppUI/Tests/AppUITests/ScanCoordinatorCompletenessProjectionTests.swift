import Foundation
import ScanKit
import SafetyKit
import XCTest
@testable import AppUI

@MainActor
final class ScanCoordinatorCompletenessProjectionTests: XCTestCase {
    func testAccessProjectionLocksExactScopeAndDescendantsButOnlyMarksAncestorsPartial() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let issuePath = "/scan/A/locked"
        coordinator._testReplaceIncompleteEvidence([
            ScanIncompleteIssue(
                path: issuePath,
                reason: .enumerationFailed,
                stage: .enumerate,
                posixErrorCode: 5
            )
        ])

        XCTAssertEqual(coordinator._testAccessState(for: issuePath), .incomplete)
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: issuePath), .complete)
        XCTAssertEqual(coordinator._testAccessState(for: issuePath + "/child"), .incomplete,
                       "真实不可访问 scope 的后代同样不可声称可完整读取")
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: issuePath + "/child"), .complete)

        XCTAssertEqual(coordinator._testAccessState(for: "/scan/A"), .normal,
                       "后代不完整不能把可正常读取的祖先画成锁")
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: "/scan/A"),
                       .containsIncompleteDescendant)
        XCTAssertEqual(coordinator._testAccessState(for: "/scan"), .normal)
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: "/scan"),
                       .containsIncompleteDescendant)

        XCTAssertEqual(coordinator._testAccessState(for: "/scan/B"), .normal,
                       "精确 A 子树证据不能污染兄弟 B")
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: "/scan/B"), .complete)
        XCTAssertEqual(coordinator._testAccessState(for: "/scan/A/locked-peer"), .normal,
                       "路径前缀相似但不在组件边界内的兄弟不能被误锁")
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: "/scan/A/locked-peer"), .complete)
    }

    func testPermissionTCCAndEnumerationReasonsStayOnTheirRealScopes() {
        let cases: [(issue: ScanIncompleteIssue, expected: TreeRow.AccessState, label: String)] = [
            (
                ScanIncompleteIssue(
                    path: "/scan/permission/locked",
                    reason: .permissionDenied,
                    stage: .open,
                    posixErrorCode: 13
                ),
                .permissionDenied,
                "permission"
            ),
            (
                ScanIncompleteIssue(
                    path: "/scan/tcc/locked",
                    reason: .tccProtectedSkipped
                ),
                .tccProtected,
                "tcc"
            ),
            (
                ScanIncompleteIssue(
                    path: "/scan/enumeration/locked",
                    reason: .enumerationFailed,
                    stage: .enumerate,
                    posixErrorCode: 5
                ),
                .incomplete,
                "enumeration"
            )
        ]

        for entry in cases {
            let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
            coordinator._testReplaceIncompleteEvidence([entry.issue])
            let ancestor = (entry.issue.path as NSString).deletingLastPathComponent

            XCTAssertEqual(coordinator._testAccessState(for: entry.issue.path),
                           entry.expected,
                           "\(entry.label) 的真实目录必须保留具体访问原因")
            XCTAssertEqual(coordinator._testAccessState(for: entry.issue.path + "/child"),
                           entry.expected,
                           "\(entry.label) scope 内的后代必须继承直接访问状态")
            XCTAssertEqual(coordinator._testAccessState(for: ancestor),
                           .normal,
                           "\(entry.label) 不能向祖先传播锁")
            XCTAssertEqual(coordinator._testSubtreeCompleteness(for: ancestor),
                           .containsIncompleteDescendant,
                           "\(entry.label) 必须在祖先保留 partial 证据")
            XCTAssertEqual(coordinator._testAccessState(for: "/scan/sibling"), .normal)
            XCTAssertEqual(coordinator._testSubtreeCompleteness(for: "/scan/sibling"), .complete)
        }
    }

    func testStructuredEvidenceIsAuthorityForLegacyPathProjections() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let permission = ScanIncompleteIssue(
            path: "/scan/permission",
            reason: .permissionDenied,
            stage: .open,
            posixErrorCode: 13
        )
        let tcc = ScanIncompleteIssue(
            path: "/scan/tcc",
            reason: .tccProtectedSkipped
        )
        let metadata = ScanIncompleteIssue(
            path: "/scan/metadata",
            reason: .metadataUnavailable,
            stage: .metadata,
            posixErrorCode: 5
        )

        coordinator._testReplaceIncompleteEvidence([permission, tcc, metadata])

        XCTAssertEqual(coordinator.incompleteScanIssues, [permission, tcc, metadata])
        XCTAssertEqual(coordinator.permissionDeniedPaths, [permission.path])
        XCTAssertEqual(coordinator.tccProtectedSkippedPaths, [tcc.path])
        XCTAssertEqual(coordinator.incompleteScanPaths,
                       [permission.path, tcc.path, metadata.path])
        XCTAssertEqual(coordinator._testAccessState(for: permission.path), .permissionDenied)
        XCTAssertEqual(coordinator._testAccessState(for: tcc.path), .tccProtected)
        XCTAssertEqual(coordinator._testAccessState(for: metadata.path), .incomplete)
        XCTAssertEqual(coordinator._testAccessState(for: "/scan"), .normal)
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: "/scan"),
                       .containsIncompleteDescendant)
    }

    func testDescendantFailedCompatibilityEventDoesNotBecomeTerminalOrExpandToRoot() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let root = "/scan"
        let child = "/scan/A/locked"
        let error = ScanError.cannotEnumerate(
            path: child,
            stage: .enumerate,
            posixErrorCode: 5
        )

        XCTAssertFalse(coordinator._testConsumeScanFailure(error, rootPath: root))
        XCTAssertNil(coordinator.terminalFailure)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(coordinator.incompleteScanPaths, [child])
        XCTAssertFalse(coordinator.incompleteScanPaths.contains(root))
        XCTAssertEqual(coordinator.incompleteScanIssues.first?.stage, .enumerate)
        XCTAssertEqual(coordinator.incompleteScanIssues.first?.posixErrorCode, 5)
        XCTAssertEqual(coordinator._testAccessState(for: root), .normal)
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: root),
                       .containsIncompleteDescendant)
        XCTAssertEqual(coordinator._testAccessState(for: child), .incomplete)
    }

    func testRootFailedEventRemainsTerminal() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let root = "/scan"
        let error = ScanError.cannotEnumerate(
            path: root,
            stage: .open,
            posixErrorCode: 5
        )

        XCTAssertTrue(coordinator._testConsumeScanFailure(error, rootPath: root))
        XCTAssertNotNil(coordinator.terminalFailure)
        XCTAssertNotNil(coordinator.lastError)
        XCTAssertEqual(coordinator.incompleteScanPaths, [root])
        XCTAssertEqual(coordinator._testAccessState(for: root), .incomplete)
        XCTAssertEqual(coordinator._testSubtreeCompleteness(for: root), .complete)
    }

    func testRootFailedEventDoesNotPublishRawErrorText() {
        struct DiagnosticOnlyFailure: Error, CustomStringConvertible {
            let description = "RAW_SCAN_FAILURE_SHOULD_STAY_IN_LOGS"
        }

        // v2026.07.17 regression: TerminalFailure/lastError are long-lived presentation state.
        // Raw Error descriptions belong only in structured logs, even when today's primary UI
        // happens to consume the typed fatal flag instead of rendering the stored message.
        let locale = Locale(identifier: "en")
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        coordinator.updatePresentationLocale(locale)

        XCTAssertTrue(coordinator._testConsumeScanFailure(
            DiagnosticOnlyFailure(),
            rootPath: "/scan"
        ))

        let expected = AppLocalization.string("main.scan.incomplete", locale: locale)
        XCTAssertEqual(coordinator.terminalFailure?.message, expected)
        XCTAssertEqual(coordinator.lastError, expected)
        XCTAssertFalse(coordinator.terminalFailure?.message.contains("RAW_SCAN_FAILURE") == true)
        XCTAssertFalse(coordinator.lastError?.contains("RAW_SCAN_FAILURE") == true)
    }

    func testMemoryTreeRowSynthesisKeepsDirectAccessAndSubtreeCompletenessOrthogonal() throws {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let root = "/scan"
        let affected = "/scan/A"
        let locked = "/scan/A/locked"
        let sibling = "/scan/B"
        coordinator._seedForTesting(
            dirIndexFull: [
                affected: (bytes: 10, fileCount: 1),
                locked: (bytes: 1, fileCount: 1),
                sibling: (bytes: 20, fileCount: 1)
            ],
            childEdges: [
                root: [affected, sibling],
                affected: [locked]
            ]
        )
        coordinator._testReplaceIncompleteEvidence([
            ScanIncompleteIssue(
                path: locked,
                reason: .enumerationFailed,
                stage: .enumerate
            )
        ])

        let rows = coordinator.directChildren(of: root, sortedBy: .nameAsc)
        let affectedRow = try XCTUnwrap(rows.first(where: { $0.path == affected }))
        let siblingRow = try XCTUnwrap(rows.first(where: { $0.path == sibling }))
        let lockedRow = try XCTUnwrap(
            coordinator.directChildren(of: affected, sortedBy: .nameAsc)
                .first(where: { $0.path == locked })
        )

        XCTAssertEqual(affectedRow.accessState, .normal)
        XCTAssertEqual(affectedRow.subtreeCompleteness, .containsIncompleteDescendant)
        XCTAssertFalse(affectedRow.hasCompleteAccessEvidence)
        XCTAssertEqual(siblingRow.accessState, .normal)
        XCTAssertEqual(siblingRow.subtreeCompleteness, .complete)
        XCTAssertTrue(siblingRow.hasCompleteAccessEvidence)
        XCTAssertEqual(lockedRow.accessState, .incomplete)
        XCTAssertEqual(lockedRow.subtreeCompleteness, .complete)
        XCTAssertFalse(lockedRow.hasCompleteAccessEvidence)

        XCTAssertEqual(coordinator.row(for: affected), affectedRow)
        XCTAssertEqual(coordinator.row(for: sibling), siblingRow)
        XCTAssertEqual(coordinator.row(for: locked), lockedRow)

        XCTAssertTrue(TreeBrowserView.canExpand(affectedRow),
                      "祖先只有 partial 标记时仍必须允许继续定位真实问题目录")
        XCTAssertTrue(TreeBrowserView.shouldTraverseDescendants(of: affectedRow, expanded: true))
        XCTAssertFalse(TreeBrowserView.canExpand(lockedRow),
                       "真实锁定目录不能展开")
        XCTAssertFalse(TreeBrowserView.shouldTraverseDescendants(of: lockedRow, expanded: true),
                       "即使旧 expanded 状态残留，也不能继续遍历锁定目录的后代")
    }

    func testDeletionCompleteEvidenceRequiresBothDirectAccessAndCompleteSubtree() {
        let complete = TreeRow(
            path: "/scan/complete",
            title: "complete",
            bytes: 1,
            fileCount: 1,
            isDirectory: true,
            hasChildren: true
        )
        let ancestorPartial = TreeRow(
            path: "/scan/partial",
            title: "partial",
            bytes: 1,
            fileCount: 1,
            isDirectory: true,
            hasChildren: true,
            accessState: .normal,
            subtreeCompleteness: .containsIncompleteDescendant
        )
        let directlyLocked = TreeRow(
            path: "/scan/locked",
            title: "locked",
            bytes: 0,
            fileCount: 0,
            isDirectory: true,
            hasChildren: false,
            accessState: .permissionDenied
        )

        XCTAssertTrue(complete.hasCompleteAccessEvidence)
        XCTAssertFalse(ancestorPartial.hasCompleteAccessEvidence,
                       "父行可浏览不代表其部分子树已具备完整删除证据")
        XCTAssertFalse(directlyLocked.hasCompleteAccessEvidence)

        XCTAssertTrue(DeletionEntryPolicy.canInitiate(
            verdict: .safe,
            rejection: .ok,
            hasCompleteAccessEvidence: complete.hasCompleteAccessEvidence,
            allowsVendorPathOverride: false
        ))
        XCTAssertFalse(DeletionEntryPolicy.canInitiate(
            verdict: .safe,
            rejection: .ok,
            hasCompleteAccessEvidence: ancestorPartial.hasCompleteAccessEvidence,
            allowsVendorPathOverride: false
        ))
    }

    func testPartialMultiRootUsesSubtreeMarkerWithoutLockingTopLevelRow() throws {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let root = "/scan/A"
        coordinator._seedForTesting(
            currentRootPath: ScanCoordinator.multiRootSentinelPath,
            isScanning: false,
            perRootStaging: [
                root: ScanCoordinator.PerRootProgress(
                    rootPath: root,
                    title: "A",
                    bytes: 10,
                    fileCount: 1,
                    isFinished: true,
                    isPartial: true
                )
            ]
        )

        let row = try XCTUnwrap(
            coordinator.directChildren(
                of: ScanCoordinator.multiRootSentinelPath,
                sortedBy: .nameAsc
            ).first(where: { $0.path == root })
        )

        XCTAssertEqual(row.accessState, .normal,
                       "partial root 不等于 root 本身不可访问")
        XCTAssertEqual(row.subtreeCompleteness, .containsIncompleteDescendant)
        XCTAssertFalse(row.hasCompleteAccessEvidence)
        XCTAssertTrue(TreeBrowserView.canExpand(row))
    }

    /// v2026.07.17 performance-regression guard: companion dedupe must happen at the
    /// issue-key index without dropping distinct rich diagnostics or rebuilding per event.
    func testBufferedEvidenceKeepsRichSemanticsAndCommitsExactlyOnce() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let generic = ScanIncompleteIssue(
            path: "/scan/locked",
            reason: .enumerationFailed
        )
        let rich = ScanIncompleteIssue(
            path: generic.path,
            reason: generic.reason,
            stage: .enumerate,
            posixErrorCode: 5
        )
        let secondRich = ScanIncompleteIssue(
            path: generic.path,
            reason: generic.reason,
            stage: .enumerate,
            posixErrorCode: 13
        )
        let rebuildsBefore = coordinator._testIncompleteEvidenceProjectionRebuildCount

        coordinator._testRecordIncompleteEvidenceWithoutPublishing([
            generic,
            rich,
            rich,
            secondRich,
            generic
        ])

        XCTAssertTrue(coordinator.incompleteScanIssues.isEmpty,
                      "同一 throttle 窗口的逐事件记录不得逐条发布")
        XCTAssertEqual(coordinator._testIncompleteEvidenceProjectionRebuildCount,
                       rebuildsBefore)

        coordinator._testCommitIncompleteEvidence()

        XCTAssertEqual(coordinator.incompleteScanIssues, [rich, secondRich],
                       "rich evidence 应原位替换 generic；exact duplicate 与迟到 generic 忽略，不同 errno 保留")
        XCTAssertEqual(coordinator._testIncompleteEvidenceProjectionRebuildCount,
                       rebuildsBefore + 1)
    }

    func testSafetyOverlapReadFlushesBufferedEvidenceBeforeDeletionPreflight() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let issue = ScanIncompleteIssue(
            path: "/scan/parent/locked",
            reason: .permissionDenied,
            stage: .open,
            posixErrorCode: 13
        )
        let rebuildsBefore = coordinator._testIncompleteEvidenceProjectionRebuildCount
        coordinator._testRecordIncompleteEvidenceWithoutPublishing([issue])

        let overlapping = coordinator.incompleteIssues(overlappingAny: ["/scan/parent"])

        XCTAssertEqual(overlapping, [issue])
        XCTAssertEqual(coordinator.incompleteScanIssues, [issue])
        XCTAssertEqual(coordinator._testIncompleteEvidenceProjectionRebuildCount,
                       rebuildsBefore + 1,
                       "删除安全读不能等待下一次 UI snapshot")
    }

    func testResetDropsUncommittedPreviousRevisionEvidence() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let stale = ScanIncompleteIssue(
            path: "/old-revision/locked",
            reason: .enumerationFailed,
            stage: .enumerate
        )
        let current = ScanIncompleteIssue(
            path: "/current-revision/locked",
            reason: .tccProtectedSkipped
        )

        coordinator._testRecordIncompleteEvidenceWithoutPublishing([stale])
        coordinator._testResetIncompleteEvidence()
        coordinator._testRecordIncompleteEvidenceWithoutPublishing([current])
        coordinator._testCommitIncompleteEvidence()

        XCTAssertEqual(coordinator.incompleteScanIssues, [current])
        XCTAssertFalse(coordinator.incompleteScanPaths.contains(stale.path),
                       "旧 generation 在 terminal 前被替换时，buffered evidence 不得越过 reset")
    }

    func testIssueHeavyBatchHasOneProjectionRebuildAndDepthBoundedTreeLookups() {
        let coordinator = ScanCoordinator(enableTreeDeepIndex: true)
        let issueCount = 5_000
        let issues = (0..<issueCount).map { index in
            ScanIncompleteIssue(
                path: "/scan/issues/\(index)/locked",
                reason: .enumerationFailed,
                stage: .enumerate,
                posixErrorCode: 5
            )
        }
        let rebuildsBefore = coordinator._testIncompleteEvidenceProjectionRebuildCount

        let recordStart = CFAbsoluteTimeGetCurrent()
        coordinator._testRecordIncompleteEvidenceWithoutPublishing(issues)
        let recordElapsed = CFAbsoluteTimeGetCurrent() - recordStart

        XCTAssertEqual(coordinator._testIncompleteEvidenceProjectionRebuildCount,
                       rebuildsBefore,
                       "5,000 条事件只能更新哈希索引，不能逐条重建公开/Tree 投影")
        XCTAssertLessThan(recordElapsed, 5.0,
                          "该宽松上限用于阻止数组扫描 + 全投影重建的 O(n²) 回归")

        coordinator._testCommitIncompleteEvidence()
        XCTAssertEqual(coordinator.incompleteScanIssues.count, issueCount)
        XCTAssertEqual(coordinator._testIncompleteEvidenceProjectionRebuildCount,
                       rebuildsBefore + 1)

        let projectionStart = CFAbsoluteTimeGetCurrent()
        var mismatches = 0
        for index in 0..<issueCount {
            if coordinator._testAccessState(
                for: "/scan/issues/\(index)/locked/child"
            ) != .incomplete {
                mismatches += 1
            }
        }
        let projectionElapsed = CFAbsoluteTimeGetCurrent() - projectionStart
        XCTAssertEqual(mismatches, 0)
        XCTAssertLessThan(projectionElapsed, 5.0,
                          "Tree row 投影应按路径深度哈希查找，不能恢复为 rows × issues")
    }
}
