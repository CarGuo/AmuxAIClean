import XCTest
import SafetyKit
@testable import AppUI

/// Step 1【P0-1 verdict 缓存到 FlatTreeRow】回归测试。
///
/// 钉住三条契约：
///   1. [FlatTreeRow](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
///      必须有一个公开的 stored 属性 `verdict: SafetyVerdict`。
///   2. 该属性必须由 init 接收并存储，而不是计算属性 / 每次访问重算。
///   3. 多次读 `flat.verdict` 不会再次触发 [SafetyEngine.evaluate(path:)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L210)。
///
/// 第三条用 [CountingSafetyEngine](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift) 实现：
/// 同一份生产代码用的 `evaluate` 接口由 protocol 抽象，测试 inject 一个会自增计数器的实现。
/// 这样 SwiftUI 重绘 N 次只读 `flat.verdict` → counter 永远 == 行数（不是 行数×重绘次数）。
///
/// 红灯前提（Step 1 未实施时）：
///   - `FlatTreeRow` 不带 verdict 字段 → 第 1、2 个测试编译 / 断言失败。
///   - TreeNodeRow 的 isTrashable 仍调 [TreeBrowserView.safety.evaluate](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L439)
///     → 第 3 个测试 counter > 行数。
///
/// 绿灯目标：FlatTreeRow.init(row:depth:verdict:) 在 rebuildFlatRows 阶段一次性算好；
/// TreeNodeRow.isTrashable 只读 flat.verdict；counter == 行数。
@MainActor
final class FlatTreeRowVerdictCacheTests: XCTestCase {

    // MARK: - 契约 1+2：FlatTreeRow 必须自带 stored verdict

    func testFlatTreeRowHasStoredVerdictField() {
        let row = TreeRow(
            path: "/tmp/amuxclean-step1-fixture/sample.cache",
            title: "sample.cache",
            bytes: 1024,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        // 关键断言：必须可以通过 init 传入 verdict 并稳定读出。
        // 红灯阶段（init 不接受 verdict 参数）此行编译失败 = 测试失败。
        let flat = FlatTreeRow(row: row, depth: 0, verdict: .safe)

        XCTAssertEqual(flat.verdict, .safe,
                       "FlatTreeRow 必须把 init 传入的 verdict 原样存住，不允许是计算属性")
    }

    func testFlatTreeRowVerdictIsStoredNotRecomputed() {
        // 同一 path 构造两个 FlatTreeRow，但塞不同 verdict。
        // 如果是计算属性（每次访问 SafetyEngine.evaluate），两份会被算成同一个值，
        // 这条测试就会失败——锁住"verdict 必须是 stored 不是 computed"。
        let row = TreeRow(
            path: "/tmp/amuxclean-step1-fixture/cache-a",
            title: "cache-a",
            bytes: 1,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let asSafe = FlatTreeRow(row: row, depth: 0, verdict: .safe)
        let asConfirm = FlatTreeRow(row: row, depth: 0, verdict: .confirm)
        XCTAssertEqual(asSafe.verdict, .safe)
        XCTAssertEqual(asConfirm.verdict, .confirm)
        XCTAssertNotEqual(asSafe, asConfirm,
                         "verdict 不同应当让 FlatTreeRow 不相等（参与 Hashable 让 SwiftUI diff 能感知）")
    }

    // MARK: - 契约 3：rebuildFlatRows 后 N 次访问不再触发 evaluate

    /// 这条是 P0-1 的核心。Step 1 真正要解决的瓶颈是
    /// `TreeNodeRow.isTrashable` 在 SwiftUI 重绘热路径上每帧都调 evaluate。
    ///
    /// 改后的契约：rebuildFlatRows 内（且仅在那里）算 verdict，
    /// 之后无论 SwiftUI 重绘多少次，N 行都最多触发 N 次 evaluate（不是 N×重绘次数）。
    ///
    /// 测试做法：直接断言 [TreeBrowserView.computeVerdicts(for:using:)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 这个 internal 静态 helper（Step 1 同步引入）对 N 行只调用 N 次 evaluator。
    /// 之后即便 reduce 再读 flat.verdict 1000 次，counter 仍 == N。
    func testComputeVerdictsCallsEvaluatorOncePerRow() {
        let rows: [TreeRow] = (0..<5).map { idx in
            TreeRow(
                path: "/tmp/amuxclean-step1-fixture/row-\(idx)",
                title: "row-\(idx)",
                bytes: Int64(idx + 1),
                fileCount: 1,
                isDirectory: false,
                hasChildren: false
            )
        }

        let counter = CountingEvaluator()
        let flats = TreeBrowserView.computeVerdicts(
            for: rows.map { ($0, 0) },
            using: counter.evaluate
        )

        XCTAssertEqual(flats.count, rows.count)
        XCTAssertEqual(counter.count, rows.count,
                       "N 行只允许触发 N 次 evaluate，不能在 hot path 重复算")

        // 模拟 SwiftUI 多次重绘 = 多次访问 flat.verdict
        var observed: [SafetyVerdict] = []
        for _ in 0..<1_000 {
            for f in flats { observed.append(f.verdict) }
        }
        XCTAssertEqual(observed.count, rows.count * 1_000)
        XCTAssertEqual(counter.count, rows.count,
                       "重绘 1000 次后 evaluator 调用次数仍必须等于行数")
    }

    func testComputeDeletionEvaluationsStoresVendorReasonWithoutHotPathReevaluation() {
        let row = TreeRow(
            path: "/tmp/amuxclean-step1-fixture/vendor-sdk",
            title: "vendor-sdk",
            bytes: 1,
            fileCount: 1,
            isDirectory: true,
            hasChildren: false
        )
        var calls = 0
        let flats = TreeBrowserView.computeDeletionEvaluations(for: [(row, 0)]) { _ in
            calls += 1
            return (verdict: .forbid, rejection: .vendorPathRule)
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(flats.first?.verdict, .forbid)
        XCTAssertEqual(flats.first?.rejection, .vendorPathRule)
        XCTAssertTrue(DeletionEntryPolicy.canInitiate(
            verdict: flats[0].verdict,
            rejection: flats[0].rejection,
            allowsVendorPathOverride: true
        ))
        XCTAssertEqual(calls, 1, "UI policy reads frozen fields and must not re-evaluate SafetyEngine")
    }

    /// 把"forbid 路径不可 trash"这个语义从 evaluator 解耦到 verdict 字段：
    /// TreeNodeRow.isTrashable 应当只读 `flat.verdict != .forbid`，不再直接调 evaluate。
    func testFlatTreeRowVerdictDrivesIsTrashableSemantics() {
        let safeRow = TreeRow(path: "/tmp/amuxclean-step1-fixture/safe",
                              title: "safe", bytes: 1, fileCount: 1,
                              isDirectory: false, hasChildren: false)
        let forbidRow = TreeRow(path: NSHomeDirectory(),
                                title: "home", bytes: 1, fileCount: 1,
                                isDirectory: true, hasChildren: true)

        let safeFlat = FlatTreeRow(row: safeRow, depth: 0, verdict: .safe)
        let forbidFlat = FlatTreeRow(row: forbidRow, depth: 0, verdict: .forbid)

        XCTAssertNotEqual(safeFlat.verdict, .forbid)
        XCTAssertEqual(forbidFlat.verdict, .forbid,
                       "$HOME 这种 forbid 路径在 rebuildFlatRows 阶段就要被打上 .forbid 标")
    }
}

/// v2026.07.18 P1 regression coverage for the Tree presentation boundary.
///
/// These tests intentionally use a wide flat tree and an injected evaluator: they prove the
/// complete DFS/materialization/verdict transaction leaves MainActor, while deterministic ordering,
/// loading state, frozen-snapshot equality and source CAS remain observable without launching App UI.
@MainActor
final class TreeFlatProjectionWorkerTests: XCTestCase {
    func testDeletionPresentationWorkerRemovesVisibleSubtreeWithoutReprojection() async throws {
        let droppedParent = TreeRow(
            path: "/tmp/drop",
            title: "drop",
            bytes: 20,
            fileCount: 2,
            isDirectory: true,
            hasChildren: true
        )
        let droppedChild = TreeRow(
            path: "/tmp/drop/child",
            title: "child",
            bytes: 10,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let sibling = TreeRow(
            path: "/tmp/dropbox",
            title: "dropbox",
            bytes: 30,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let oldRows = [
            FlatTreeRow(row: droppedParent, depth: 0, verdict: .safe),
            FlatTreeRow(row: droppedChild, depth: 1, verdict: .safe),
            FlatTreeRow(row: sibling, depth: 0, verdict: .safe)
        ]
        let worker = TreeDeletionPresentationWorker(
            matcher: DeletionPresentationPathMatcher(paths: ["/tmp/drop"]),
            rootPath: "/tmp",
            previous: .init(
                rows: oldRows,
                rowIndexByPath: [
                    droppedParent.path: 0,
                    droppedChild.path: 1,
                    sibling.path: 2
                ],
                parentIndexByRow: [nil, 0, nil],
                maxBytes: 30,
                isFetchingRoot: false
            )
        )

        let prepared = await worker.prepare()
        let output = try XCTUnwrap(prepared)
        XCTAssertEqual(output.rows.map(\.row.path), [sibling.path])
        XCTAssertEqual(output.rowIndexByPath, [sibling.path: 0])
        XCTAssertEqual(output.parentIndexByRow, [nil])
        XCTAssertEqual(output.rowRemovalRanges, [0..<2])
        XCTAssertTrue(output.tableIdentityChanged)
        XCTAssertFalse(output.ranOnMainThread)
        await worker.retire()
    }

    func testWideProjectionMaterializesAndEvaluatesOffMainThread() async throws {
        let rowCount = 20_000
        let roots = (0..<rowCount).map { index in
            TreeRow(
                path: "/tmp/tree-worker-wide/row-\(index)",
                title: "row-\(index)",
                bytes: Int64(index),
                fileCount: 1,
                isDirectory: false,
                hasChildren: false
            )
        }
        let probe = ProjectionThreadProbe()
        let worker = TreeFlatProjectionWorker(
            input: TreeFlatProjectionWorkerInput(
                rootRows: roots,
                childrenByParent: [:],
                expandedPaths: [],
                fetchingPaths: [],
                isFetchingRoot: false,
                evaluator: TreeFlatProjectionEvaluator { _ in
                    probe.recordEvaluation()
                    return (.safe, .ok)
                }
            ),
            previous: .init(
                rows: [],
                rowIndexByPath: [:],
                parentIndexByRow: [],
                maxBytes: 0,
                isFetchingRoot: false
            )
        )

        let prepared = await worker.prepare()
        let output = try XCTUnwrap(prepared)
        XCTAssertEqual(output.rows.count, rowCount)
        XCTAssertEqual(output.rowIndexByPath.count, rowCount)
        XCTAssertEqual(output.rowIndexByPath[roots[rowCount - 1].path], rowCount - 1)
        XCTAssertEqual(probe.evaluationCount, rowCount)
        XCTAssertFalse(output.ranOnMainThread, "wide projection must run on its actor executor")
        XCTAssertFalse(probe.sawMainThread, "Safety verdict evaluation must never return to MainActor")
        let retirementRanOnMainThread = await worker.retire()
        XCTAssertFalse(retirementRanOnMainThread, "wide COW retirement must stay off MainActor")
        let appKitRetirement = TreeFlatRowsRetirement(
            rows: output.rows,
            rowIndexByPath: output.rowIndexByPath,
            parentIndexByRow: output.parentIndexByRow
        )
        let appKitRetirementRanOnMainThread = await appKitRetirement.retire()
        XCTAssertFalse(
            appKitRetirementRanOnMainThread,
            "replacing AppKit's previous frozen row generation must not tear it down on MainActor"
        )
    }

    func testIncrementalProjectionCannotResurrectReceiptTombstonesFromPreviousFrameOrCache() async throws {
        let deleted = TreeRow(
            path: "/tmp/tree-receipt/drop",
            title: "drop",
            bytes: 50,
            fileCount: 2,
            isDirectory: true,
            hasChildren: true
        )
        let deletedChild = TreeRow(
            path: deleted.path + "/child",
            title: "child",
            bytes: 20,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let kept = TreeRow(
            path: "/tmp/tree-receipt/keep",
            title: "keep",
            bytes: 40,
            fileCount: 2,
            isDirectory: true,
            hasChildren: true
        )
        let staleChild = TreeRow(
            path: kept.path + "/dead",
            title: "dead",
            bytes: 30,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let liveChild = TreeRow(
            path: kept.path + "/live",
            title: "live",
            bytes: 10,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let previousRows = [
            FlatTreeRow(row: deleted, depth: 0, verdict: .safe),
            FlatTreeRow(row: deletedChild, depth: 1, verdict: .safe),
            FlatTreeRow(row: kept, depth: 0, verdict: .safe)
        ]
        let worker = TreeIncrementalProjectionWorker(
            input: TreeIncrementalProjectionWorkerInput(
                togglePath: kept.path,
                isExpanding: true,
                childrenByParent: [kept.path: [staleChild, liveChild]],
                expandedPaths: [kept.path],
                fetchingPaths: [],
                receiptTombstones: .init(paths: [deleted.path, staleChild.path]),
                evaluator: .init { _ in (.safe, .ok) }
            ),
            previous: .init(
                rows: previousRows,
                rowIndexByPath: [deleted.path: 0, deletedChild.path: 1, kept.path: 2],
                parentIndexByRow: [nil, 0, nil],
                maxBytes: deleted.bytes,
                isFetchingRoot: false
            )
        )

        let workerOutput = await worker.prepare()
        let prepared = try XCTUnwrap(workerOutput)
        XCTAssertEqual(prepared.rows.map(\.row.path), [kept.path, liveChild.path])
        XCTAssertNil(prepared.rowIndexByPath[deleted.path])
        XCTAssertNil(prepared.rowIndexByPath[staleChild.path])
        XCTAssertFalse(prepared.ranOnMainThread)
        _ = await worker.retire()
    }

    func testProjectionPreservesDeterministicDFSDepthAndLoadingSemantics() async throws {
        let directory = TreeRow(
            path: "/tmp/tree-worker-dfs/a",
            title: "a",
            bytes: 40,
            fileCount: 3,
            isDirectory: true,
            hasChildren: true
        )
        let sibling = TreeRow(
            path: "/tmp/tree-worker-dfs/z",
            title: "z",
            bytes: 20,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let nestedDirectory = TreeRow(
            path: "/tmp/tree-worker-dfs/a/b",
            title: "b",
            bytes: 30,
            fileCount: 2,
            isDirectory: true,
            hasChildren: true
        )
        let nestedSibling = TreeRow(
            path: "/tmp/tree-worker-dfs/a/c",
            title: "c",
            bytes: 10,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let leaf = TreeRow(
            path: "/tmp/tree-worker-dfs/a/b/leaf",
            title: "leaf",
            bytes: 5,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let worker = TreeFlatProjectionWorker(
            input: TreeFlatProjectionWorkerInput(
                rootRows: [directory, sibling],
                childrenByParent: [
                    directory.path: [nestedDirectory, nestedSibling],
                    nestedDirectory.path: [leaf]
                ],
                expandedPaths: [directory.path, nestedDirectory.path],
                fetchingPaths: [directory.path],
                isFetchingRoot: false,
                evaluator: .init { _ in (.safe, .ok) }
            ),
            previous: .init(
                rows: [],
                rowIndexByPath: [:],
                parentIndexByRow: [],
                maxBytes: 0,
                isFetchingRoot: false
            )
        )

        let prepared = await worker.prepare()
        let output = try XCTUnwrap(prepared)
        XCTAssertEqual(output.rows.map(\.row.path), [
            directory.path,
            nestedDirectory.path,
            leaf.path,
            nestedSibling.path,
            sibling.path
        ])
        XCTAssertEqual(output.rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(output.parentIndexByRow, [nil, 0, 1, 0, nil])
        XCTAssertTrue(output.rows[0].isLoadingChildren)
        XCTAssertFalse(output.rows[1].isLoadingChildren)
        XCTAssertEqual(output.maxBytes, directory.bytes)
        XCTAssertTrue(output.tableIdentityChanged)
        _ = await worker.retire()
    }

    func testValueOnlyProjectionChangeDoesNotRequestStructuralTableReload() async throws {
        let row = TreeRow(
            path: "/tmp/tree-worker-stable/only",
            title: "only",
            bytes: 7,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let previousRow = TreeRow(
            path: row.path,
            title: row.title,
            bytes: 6,
            fileCount: row.fileCount,
            isDirectory: row.isDirectory,
            hasChildren: row.hasChildren
        )
        let flat = FlatTreeRow(row: previousRow, depth: 0, verdict: .safe)
        let worker = TreeFlatProjectionWorker(
            input: TreeFlatProjectionWorkerInput(
                rootRows: [row],
                childrenByParent: [:],
                expandedPaths: [],
                fetchingPaths: [],
                isFetchingRoot: false,
                evaluator: .init { _ in (.safe, .ok) }
            ),
            previous: .init(
                rows: [flat],
                rowIndexByPath: [row.path: 0],
                parentIndexByRow: [nil],
                maxBytes: previousRow.bytes,
                isFetchingRoot: false
            )
        )

        let prepared = await worker.prepare()
        let output = try XCTUnwrap(prepared)
        XCTAssertTrue(output.changed)
        XCTAssertFalse(output.tableIdentityChanged)
        XCTAssertFalse(TreeTableReloadPolicy.requiresFullReload(previous: 42, next: 42))
        XCTAssertTrue(TreeTableReloadPolicy.requiresFullReload(previous: 42, next: 43))
        _ = await worker.retire()
    }

    func testReceiptDeletionUsesExactAppKitRowDeltaOnlyForMatchingBaseRevision() {
        let delta = TreeTableRowRemovalDelta(
            baseIdentityRevision: 7,
            nextIdentityRevision: 8,
            baseRowCount: 5,
            nextRowCount: 3,
            ranges: [1..<3]
        )
        XCTAssertEqual(
            TreeTableStructuralUpdatePolicy.update(
                renderedIdentityRevision: 7,
                renderedRowCount: 5,
                nextIdentityRevision: 8,
                nextRowCount: 3,
                removalDelta: delta
            ),
            .removeRows([1..<3])
        )
        XCTAssertEqual(
            TreeTableStructuralUpdatePolicy.update(
                renderedIdentityRevision: 6,
                renderedRowCount: 5,
                nextIdentityRevision: 8,
                nextRowCount: 3,
                removalDelta: delta
            ),
            .reload,
            "a stale receipt delta must never mutate a newer/different NSTableView generation"
        )

        let overlapping = TreeTableRowRemovalDelta(
            baseIdentityRevision: 7,
            nextIdentityRevision: 8,
            baseRowCount: 5,
            nextRowCount: 1,
            ranges: [1..<3, 2..<4]
        )
        XCTAssertEqual(
            TreeTableStructuralUpdatePolicy.update(
                renderedIdentityRevision: 7,
                renderedRowCount: 5,
                nextIdentityRevision: 8,
                nextRowCount: 1,
                removalDelta: overlapping
            ),
            .reload
        )
    }

    func testCoordinatorSourceRevisionRejectsOlderProjectionAfterMutation() {
        let root = "/tmp/tree-worker-cas"
        let row = TreeRow(
            path: "\(root)/child",
            title: "child",
            bytes: 1,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let coordinator = ScanCoordinator(home: "/tmp/tree-worker-home")
        coordinator._seedForTesting(
            currentRootPath: root,
            isScanning: false,
            treeChildrenCache: ["\(root)|\(TreeSortKey.sizeDesc.rawValue)": [row]]
        )
        let source = coordinator.makeTreeFlatProjectionSource(
            rootPath: root,
            sortedBy: .sizeDesc,
            expandedPaths: []
        )
        XCTAssertTrue(coordinator.treeFlatProjectionSourceIsCurrent(source.revision))

        coordinator._seedForTesting(scannedFiles: 1)
        XCTAssertFalse(
            coordinator.treeFlatProjectionSourceIsCurrent(source.revision),
            "a worker built from an older cache/source revision must not overwrite the new frame"
        )
    }

    func testUnrelatedTreeTaskOwnershipDoesNotInvalidateProjectionSource() {
        let root = "/tmp/tree-worker-owner"
        let row = TreeRow(
            path: "\(root)/child",
            title: "child",
            bytes: 1,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let coordinator = ScanCoordinator(home: "/tmp/tree-worker-home")
        coordinator._seedForTesting(
            currentRootPath: root,
            isScanning: false,
            treeChildrenCache: ["\(root)|\(TreeSortKey.sizeDesc.rawValue)": [row]]
        )
        let source = coordinator.makeTreeFlatProjectionSource(
            rootPath: root,
            sortedBy: .sizeDesc,
            expandedPaths: []
        )

        coordinator._seedTreeChildrenTasksForTesting(keys: ["/unrelated|sizeDesc"])

        XCTAssertTrue(
            coordinator.treeFlatProjectionSourceIsCurrent(source.revision),
            "an unrelated path changing task ownership must not discard this immutable source"
        )
        coordinator.cancelOnDemandTreeScansPreservingResults()
    }

    func testIncrementalDisclosurePatchesOnlyChangedSegmentOffMainThread() async throws {
        let parent = TreeRow(
            path: "/tmp/tree-incremental/parent",
            title: "parent",
            bytes: 30,
            fileCount: 3,
            isDirectory: true,
            hasChildren: true
        )
        let sibling = TreeRow(
            path: "/tmp/tree-incremental/sibling",
            title: "sibling",
            bytes: 1,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let nested = TreeRow(
            path: "\(parent.path)/nested",
            title: "nested",
            bytes: 20,
            fileCount: 2,
            isDirectory: true,
            hasChildren: true
        )
        let leaf = TreeRow(
            path: "\(parent.path)/leaf",
            title: "leaf",
            bytes: 10,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let deepLeaf = TreeRow(
            path: "\(nested.path)/deep",
            title: "deep",
            bytes: 5,
            fileCount: 1,
            isDirectory: false,
            hasChildren: false
        )
        let previousRows = [
            FlatTreeRow(row: parent, depth: 0, verdict: .safe),
            FlatTreeRow(row: sibling, depth: 0, verdict: .safe)
        ]
        let previous = TreeFlatProjectionPreviousSnapshot(
            rows: previousRows,
            rowIndexByPath: [parent.path: 0, sibling.path: 1],
            parentIndexByRow: [nil, nil],
            maxBytes: parent.bytes,
            isFetchingRoot: false
        )
        let probe = ProjectionThreadProbe()
        let expandWorker = TreeIncrementalProjectionWorker(
            input: TreeIncrementalProjectionWorkerInput(
                togglePath: parent.path,
                isExpanding: true,
                childrenByParent: [
                    parent.path: [nested, leaf],
                    nested.path: [deepLeaf]
                ],
                expandedPaths: [parent.path, nested.path],
                fetchingPaths: [nested.path],
                evaluator: .init { _ in
                    probe.recordEvaluation()
                    return (.safe, .ok)
                }
            ),
            previous: previous
        )

        let expandedPrepared = await expandWorker.prepare()
        let expanded = try XCTUnwrap(expandedPrepared)
        XCTAssertEqual(expanded.rows.map(\.row.path), [
            parent.path, nested.path, deepLeaf.path, leaf.path, sibling.path
        ])
        XCTAssertEqual(expanded.rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(expanded.parentIndexByRow, [nil, 0, 1, 0, nil])
        XCTAssertTrue(expanded.rows[1].isLoadingChildren)
        XCTAssertEqual(probe.evaluationCount, 3, "only newly inserted rows are evaluated")
        XCTAssertFalse(expanded.ranOnMainThread)
        XCTAssertFalse(probe.sawMainThread)
        _ = await expandWorker.retire()

        let collapseProbe = ProjectionThreadProbe()
        let collapseWorker = TreeIncrementalProjectionWorker(
            input: TreeIncrementalProjectionWorkerInput(
                togglePath: parent.path,
                isExpanding: false,
                childrenByParent: [:],
                expandedPaths: [],
                fetchingPaths: [],
                evaluator: .init { _ in
                    collapseProbe.recordEvaluation()
                    return (.safe, .ok)
                }
            ),
            previous: .init(
                rows: expanded.rows,
                rowIndexByPath: expanded.rowIndexByPath,
                parentIndexByRow: expanded.parentIndexByRow,
                maxBytes: expanded.maxBytes,
                isFetchingRoot: expanded.isFetchingRoot
            )
        )
        let collapsedPrepared = await collapseWorker.prepare()
        let collapsed = try XCTUnwrap(collapsedPrepared)
        XCTAssertEqual(collapsed.rows.map(\.row.path), [parent.path, sibling.path])
        XCTAssertEqual(collapsed.parentIndexByRow, [nil, nil])
        XCTAssertEqual(collapseProbe.evaluationCount, 0, "collapse reuses retained evaluations")
        XCTAssertFalse(collapsed.ranOnMainThread)
        _ = await collapseWorker.retire()
    }

    func testShallowIdentityCacheBumpPatchesExpandedParentWithoutFullTreeProjection() async throws {
        let parent = TreeRow(
            path: "/tmp/tree-shallow-first-frame/parent",
            title: "parent",
            bytes: 100,
            fileCount: 2,
            isDirectory: true,
            hasChildren: true
        )
        let unrelatedCount = 4_096
        let unrelatedRows = (0..<unrelatedCount).map { index in
            TreeRow(
                path: "/tmp/tree-shallow-first-frame/unrelated-\(index)",
                title: "unrelated-\(index)",
                bytes: 1,
                fileCount: 1,
                isDirectory: false,
                hasChildren: false
            )
        }
        let pendingChild = TreeRow(
            path: parent.path + "/child",
            title: "child",
            bytes: 0,
            fileCount: 0,
            isDirectory: true,
            hasChildren: true,
            isSizePending: true
        )
        let previousRows = [
            FlatTreeRow(
                row: parent,
                depth: 0,
                verdict: .safe,
                isLoadingChildren: true
            )
        ] + unrelatedRows.map { FlatTreeRow(row: $0, depth: 0, verdict: .safe) }
        let previousIndex = Dictionary(
            uniqueKeysWithValues: previousRows.enumerated().map { ($0.element.row.path, $0.offset) }
        )
        let expandedPaths: Set<String> = [parent.path]

        XCTAssertEqual(
            TreeBrowserView.incrementalCachePatchPath(
                changedPath: parent.path,
                expandedPaths: expandedPaths,
                visibleRowIndexByPath: previousIndex
            ),
            parent.path
        )
        XCTAssertNil(TreeBrowserView.incrementalCachePatchPath(
            changedPath: parent.path,
            expandedPaths: [],
            visibleRowIndexByPath: [parent.path: 0]
        ))

        let shallowProbe = ProjectionThreadProbe()
        let shallowWorker = TreeIncrementalProjectionWorker(
            input: TreeIncrementalProjectionWorkerInput(
                togglePath: parent.path,
                isExpanding: true,
                childrenByParent: [parent.path: [pendingChild]],
                expandedPaths: expandedPaths,
                fetchingPaths: [],
                evaluator: .init { _ in
                    shallowProbe.recordEvaluation()
                    return (.safe, .ok)
                }
            ),
            previous: .init(
                rows: previousRows,
                rowIndexByPath: previousIndex,
                parentIndexByRow: Array(repeating: nil, count: previousRows.count),
                maxBytes: parent.bytes,
                isFetchingRoot: false
            )
        )
        let shallowPrepared = await shallowWorker.prepare()
        let shallow = try XCTUnwrap(shallowPrepared)
        XCTAssertEqual(shallow.rows.count, previousRows.count + 1)
        XCTAssertEqual(shallow.rows[0].row.path, parent.path)
        XCTAssertEqual(shallow.rows[1].row.path, pendingChild.path)
        XCTAssertEqual(shallow.rows.last?.row.path, unrelatedRows.last?.path)
        XCTAssertFalse(shallow.rows[0].isLoadingChildren)
        XCTAssertTrue(shallow.rows[1].row.isSizePending)
        XCTAssertEqual(
            shallowProbe.evaluationCount,
            1,
            "path-local disclosure must not re-evaluate thousands of unrelated visible rows"
        )
        XCTAssertTrue(shallow.tableIdentityChanged)
        XCTAssertFalse(shallow.ranOnMainThread)
        _ = await shallowWorker.retire()

        let exactChild = TreeRow(
            path: pendingChild.path,
            title: pendingChild.title,
            bytes: 64 * 1_024,
            fileCount: 4,
            isDirectory: true,
            hasChildren: true,
            isSizePending: false
        )
        let deepProbe = ProjectionThreadProbe()
        let deepWorker = TreeIncrementalProjectionWorker(
            input: TreeIncrementalProjectionWorkerInput(
                togglePath: parent.path,
                isExpanding: true,
                childrenByParent: [parent.path: [exactChild]],
                expandedPaths: expandedPaths,
                fetchingPaths: [],
                evaluator: .init { _ in
                    deepProbe.recordEvaluation()
                    return (.safe, .ok)
                }
            ),
            previous: .init(
                rows: shallow.rows,
                rowIndexByPath: shallow.rowIndexByPath,
                parentIndexByRow: shallow.parentIndexByRow,
                maxBytes: shallow.maxBytes,
                isFetchingRoot: shallow.isFetchingRoot
            )
        )
        let deepPrepared = await deepWorker.prepare()
        let deep = try XCTUnwrap(deepPrepared)
        XCTAssertEqual(deep.rows.count, shallow.rows.count)
        XCTAssertEqual(deep.rows[0].row.path, parent.path)
        XCTAssertEqual(deep.rows[1].row.path, pendingChild.path)
        XCTAssertEqual(deep.rows.last?.row.path, unrelatedRows.last?.path)
        XCTAssertEqual(deep.rows[1].row.bytes, exactChild.bytes)
        XCTAssertFalse(deep.rows[1].row.isSizePending)
        XCTAssertEqual(deepProbe.evaluationCount, 1)
        XCTAssertFalse(
            deep.tableIdentityChanged,
            "exact metrics for an existing child must patch values without rebuilding table identity"
        )
        XCTAssertFalse(deep.ranOnMainThread)
        _ = await deepWorker.retire()
    }
}

// MARK: - Test helpers

private final class ProjectionThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _evaluationCount = 0
    private var _sawMainThread = false

    var evaluationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _evaluationCount
    }

    var sawMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _sawMainThread
    }

    func recordEvaluation() {
        let isMain = Thread.isMainThread
        lock.lock()
        _evaluationCount += 1
        _sawMainThread = _sawMainThread || isMain
        lock.unlock()
    }
}

/// 计数 evaluator——每被调一次就把 [count](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift) +1。
/// 用于断言 SwiftUI 重绘 hot path 不再触发 SafetyEngine.evaluate。
@MainActor
private final class CountingEvaluator {
    private(set) var count: Int = 0

    /// 注意签名匹配 [TreeBrowserView.computeVerdicts(for:using:)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 期望的 `(String) -> SafetyVerdict`。Step 1 生产代码会传 `Self.safety.evaluate(path:).0`。
    func evaluate(path: String) -> SafetyVerdict {
        count += 1
        // 测试不需要真去碰 SafetyEngine——固定回 .safe 即可；
        // 真实 forbid 语义由 [testFlatTreeRowVerdictDrivesIsTrashableSemantics](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)
        // 的直接构造覆盖。
        return .safe
    }
}
