import XCTest
import SafetyKit
@testable import AppUI

/// **v1.5.6 Tree 性能优化回归契约**：钉死"增量 patch 等价于全量重建"。
///
/// 背景（用户反馈"tree 展开还是好卡"）：旧实现每次 expanded 字典变化都走
/// [rebuildFlatRows](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L289)
/// 整树重算。已展开 200 个目录 / 每目录 50 子项的场景下，单次点击需要
/// 200 次 directChildren + 200 次 sort + N 次 verdict 计算。
///
/// 新实现 [applyExpansionPatch](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L400)
/// 走 diff：单点 expand → 在老 flatRows 里就地插入子树；单点 collapse → 用 depth
/// 边界扫描剪枝。复杂度从 O(N total) 降到 O(N new subtree)。
///
/// 等价性是核心契约：任何未来对增量 patch 的优化都必须**与"老 flatRows 完全等价于
/// 全量重建结果"**这条不变量比对，否则会导致 view 显示与展开状态不一致。
@MainActor
final class FlatRowsIncrementalPatchTests: XCTestCase {

    // MARK: - 测试工具：用 in-memory tree fixture 代替 ScanCoordinator

    /// in-memory 树 fixture：path -> 直接子项（按 path 升序排好，与 sortKey 无关，
    /// 让测试只关心增量等价性而非排序）。
    struct InMemoryTree {
        /// parent path -> children paths（直接子项）
        let edges: [String: [String]]
        /// path -> 是否目录（默认 true，叶子要显式标 false）
        let isDirectory: [String: Bool]

        func children(of parent: String) -> [TreeRow] {
            (edges[parent] ?? []).map { p in
                TreeRow(
                    path: p,
                    title: (p as NSString).lastPathComponent,
                    bytes: 100,
                    fileCount: 1,
                    isDirectory: isDirectory[p] ?? true,
                    hasChildren: (edges[p]?.isEmpty == false)
                )
            }
        }
    }

    /// 构造一棵小但深的树：root/A{X,Y,Z}; root/B{P{P1,P2},Q}; root/C
    private static func makeFixture() -> InMemoryTree {
        InMemoryTree(
            edges: [
                "/root": ["/root/A", "/root/B", "/root/C"],
                "/root/A": ["/root/A/X", "/root/A/Y", "/root/A/Z"],
                "/root/B": ["/root/B/P", "/root/B/Q"],
                "/root/B/P": ["/root/B/P/P1", "/root/B/P/P2"],
            ],
            isDirectory: [
                "/root/A": true, "/root/B": true, "/root/C": false,
                "/root/A/X": false, "/root/A/Y": false, "/root/A/Z": false,
                "/root/B/P": true, "/root/B/Q": false,
                "/root/B/P/P1": false, "/root/B/P/P2": false,
            ]
        )
    }

    /// "全量重建" reference 实现：复用 production [computeVerdicts](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L478)
    /// 但子树拍平自己写，避免依赖 ScanCoordinator。
    private static func fullRebuild(
        root: String,
        expanded: [String: Bool],
        tree: InMemoryTree
    ) -> [FlatTreeRow] {
        func dfs(parent: String, depth: Int, into out: inout [(TreeRow, Int)]) {
            for kid in tree.children(of: parent) {
                out.append((kid, depth))
                if kid.isDirectory && (expanded[kid.path] ?? false) {
                    dfs(parent: kid.path, depth: depth + 1, into: &out)
                }
            }
        }
        var pairs: [(TreeRow, Int)] = []
        dfs(parent: root, depth: 0, into: &pairs)
        return TreeBrowserView.computeVerdicts(for: pairs) { _ in .safe }
    }

    // MARK: - 契约 1：展开单点等价于全量重建

    func test_增量展开等价于全量重建() {
        let tree = Self.makeFixture()
        // 初始：root 顶层（A B C）+ A 已展开
        let initialExpanded: [String: Bool] = ["/root/A": true]
        let initial = Self.fullRebuild(root: "/root", expanded: initialExpanded, tree: tree)

        // 翻转：把 B 也展开
        var nextExpanded = initialExpanded
        nextExpanded["/root/B"] = true

        // 增量 patch
        let patched = TreeBrowserView.applyExpansionPatch(
            old: initial,
            togglePath: "/root/B",
            isExpanding: true,
            sortKey: .sizeDesc,
            expandedAfter: nextExpanded,
            childrenProvider: { p, _ in tree.children(of: p) },
            evaluator: { _ in .safe }
        )

        // 全量重建
        let rebuilt = Self.fullRebuild(root: "/root", expanded: nextExpanded, tree: tree)

        XCTAssertEqual(patched, rebuilt,
                       "单点展开后增量 patch 必须与全量重建逐行等价")
    }

    // MARK: - 契约 2：折叠单点等价于全量重建

    func test_增量折叠等价于全量重建() {
        let tree = Self.makeFixture()
        // 初始：A B P 都展开
        let initialExpanded: [String: Bool] = [
            "/root/A": true, "/root/B": true, "/root/B/P": true,
        ]
        let initial = Self.fullRebuild(root: "/root", expanded: initialExpanded, tree: tree)

        // 翻转：把 B 折叠（B 子树整段消失，包括 B/P 与 B/P/P1 P2）
        var nextExpanded = initialExpanded
        nextExpanded["/root/B"] = false

        let patched = TreeBrowserView.applyExpansionPatch(
            old: initial,
            togglePath: "/root/B",
            isExpanding: false,
            sortKey: .sizeDesc,
            expandedAfter: nextExpanded,
            childrenProvider: { p, _ in tree.children(of: p) },
            evaluator: { _ in .safe }
        )
        let rebuilt = Self.fullRebuild(root: "/root", expanded: nextExpanded, tree: tree)

        XCTAssertEqual(patched, rebuilt,
                       "单点折叠后增量 patch 必须与全量重建逐行等价（防 depth 边界扫描漏剪）")
    }

    // MARK: - 契约 3：展开一个已展开孙子的父节点 → 子树要带着孙子一起出来

    func test_展开父节点时已展开的孙子也要拍平出来() {
        let tree = Self.makeFixture()
        // 初始：B 折叠，但 B/P 在 expanded 字典里已经是 true（用户之前展过又折了 B）
        let initialExpanded: [String: Bool] = ["/root/B/P": true]
        let initial = Self.fullRebuild(root: "/root", expanded: initialExpanded, tree: tree)
        // 此时 flatRows 只有 root 顶层 3 行，B 没展开 P 的展开状态根本看不见

        // 翻转：展开 B
        var nextExpanded = initialExpanded
        nextExpanded["/root/B"] = true

        let patched = TreeBrowserView.applyExpansionPatch(
            old: initial,
            togglePath: "/root/B",
            isExpanding: true,
            sortKey: .sizeDesc,
            expandedAfter: nextExpanded,
            childrenProvider: { p, _ in tree.children(of: p) },
            evaluator: { _ in .safe }
        )
        let rebuilt = Self.fullRebuild(root: "/root", expanded: nextExpanded, tree: tree)

        XCTAssertEqual(patched, rebuilt,
                       "展开 B 时，已经在 expanded 字典里的 B/P 必须把 P1/P2 一起拍出来")
        // 多断一句：必须真的能看到 P1 P2，防 patched/rebuilt 都漏的隐性 bug
        XCTAssertTrue(patched?.contains(where: { $0.row.path == "/root/B/P/P1" }) ?? false,
                      "B/P/P1 必须出现在 patched 结果里")
    }

    // MARK: - 契约 4：togglePath 不在 old → 返回 nil（caller 走 fallback）

    func test_togglePath不在flatRows时返回nil让caller走fallback() {
        let tree = Self.makeFixture()
        let initial = Self.fullRebuild(root: "/root", expanded: [:], tree: tree)
        // 给一个 flatRows 里没有的 path（它在折叠态的孙子层）
        let result = TreeBrowserView.applyExpansionPatch(
            old: initial,
            togglePath: "/root/B/P/P1",
            isExpanding: true,
            sortKey: .sizeDesc,
            expandedAfter: ["/root/B/P/P1": true],
            childrenProvider: { p, _ in tree.children(of: p) },
            evaluator: { _ in .safe }
        )
        XCTAssertNil(result,
                     "togglePath 不在 old flatRows 时必须返回 nil，caller fallback 整树重建")
    }

    // MARK: - 契约 5：evaluator 只被新插入的子树调，老行 verdict 保留

    func test_增量展开时evaluator只被新子树调用() {
        let tree = Self.makeFixture()
        let initial = Self.fullRebuild(root: "/root", expanded: [:], tree: tree)
        // 顶层 3 行：A B C
        XCTAssertEqual(initial.count, 3)

        // 展开 A：新增 3 行（X Y Z）
        var evalCount = 0
        let patched = TreeBrowserView.applyExpansionPatch(
            old: initial,
            togglePath: "/root/A",
            isExpanding: true,
            sortKey: .sizeDesc,
            expandedAfter: ["/root/A": true],
            childrenProvider: { p, _ in tree.children(of: p) },
            evaluator: { _ in evalCount += 1; return .safe }
        )
        XCTAssertEqual(patched?.count, 6, "顶层 3 + A 的子项 3 = 6")
        XCTAssertEqual(evalCount, 3,
                       "evaluator 必须只被 A 的 3 个新子项调（X/Y/Z），原顶层 3 行 verdict 保留")
    }

    // MARK: - 契约 6：访问锁与子树 partial 不能再次混用

    func test_旧expanded状态不能让真实锁节点继续显示陈旧后代() {
        let locked = TreeRow(
            path: "/root/locked",
            title: "locked",
            bytes: 0,
            fileCount: 0,
            isDirectory: true,
            hasChildren: true,
            accessState: .permissionDenied
        )
        let old = [FlatTreeRow(
            row: locked,
            depth: 0,
            verdict: .safe,
            rejection: .ok
        )]
        var providerCalls = 0

        let patched = TreeBrowserView.applyExpansionPatch(
            old: old,
            togglePath: locked.path,
            isExpanding: true,
            sortKey: .nameAsc,
            expandedAfter: [locked.path: true],
            childrenProvider: { _, _ in
                providerCalls += 1
                return [TreeRow(
                    path: "/root/locked/stale",
                    title: "stale",
                    bytes: 1,
                    fileCount: 1,
                    isDirectory: false,
                    hasChildren: false
                )]
            },
            evaluator: { _ in .safe }
        )

        XCTAssertEqual(patched, old)
        XCTAssertEqual(providerCalls, 0,
                       "真实锁节点即使残留 expanded=true，也不能再读取或显示旧后代")
    }

    func test_仅含未完整后代的祖先仍可展开定位真实问题() {
        let partialAncestor = TreeRow(
            path: "/root/partial",
            title: "partial",
            bytes: 10,
            fileCount: 1,
            isDirectory: true,
            hasChildren: true,
            accessState: .normal,
            subtreeCompleteness: .containsIncompleteDescendant
        )
        let old = [FlatTreeRow(
            row: partialAncestor,
            depth: 0,
            verdict: .safe,
            rejection: .ok
        )]

        let patched = TreeBrowserView.applyExpansionPatch(
            old: old,
            togglePath: partialAncestor.path,
            isExpanding: true,
            sortKey: .nameAsc,
            expandedAfter: [partialAncestor.path: true],
            childrenProvider: { _, _ in
                [TreeRow(
                    path: "/root/partial/locked",
                    title: "locked",
                    bytes: 0,
                    fileCount: 0,
                    isDirectory: true,
                    hasChildren: false,
                    accessState: .incomplete
                )]
            },
            evaluator: { _ in .safe }
        )

        XCTAssertEqual(patched?.map(\.row.path), [partialAncestor.path, "/root/partial/locked"])
        XCTAssertEqual(patched?.last?.row.accessState, .incomplete)
    }
}
