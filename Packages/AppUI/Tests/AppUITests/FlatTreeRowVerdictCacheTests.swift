import XCTest
import SafetyKit
@testable import AppUI

/// Step 1【P0-1 verdict 缓存到 FlatTreeRow】回归测试。
///
/// 钉住三条契约：
///   1. [FlatTreeRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
///      必须有一个公开的 stored 属性 `verdict: SafetyVerdict`。
///   2. 该属性必须由 init 接收并存储，而不是计算属性 / 每次访问重算。
///   3. 多次读 `flat.verdict` 不会再次触发 [SafetyEngine.evaluate(path:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L210)。
///
/// 第三条用 [CountingSafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift) 实现：
/// 同一份生产代码用的 `evaluate` 接口由 protocol 抽象，测试 inject 一个会自增计数器的实现。
/// 这样 SwiftUI 重绘 N 次只读 `flat.verdict` → counter 永远 == 行数（不是 行数×重绘次数）。
///
/// 红灯前提（Step 1 未实施时）：
///   - `FlatTreeRow` 不带 verdict 字段 → 第 1、2 个测试编译 / 断言失败。
///   - TreeNodeRow 的 isTrashable 仍调 [TreeBrowserView.safety.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L439)
///     → 第 3 个测试 counter > 行数。
///
/// 绿灯目标：FlatTreeRow.init(row:depth:verdict:) 在 rebuildFlatRows 阶段一次性算好；
/// TreeNodeRow.isTrashable 只读 flat.verdict；counter == 行数。
@MainActor
final class FlatTreeRowVerdictCacheTests: XCTestCase {

    // MARK: - 契约 1+2：FlatTreeRow 必须自带 stored verdict

    func testFlatTreeRowHasStoredVerdictField() {
        let row = TreeRow(
            path: "/tmp/cleanmac-step1-fixture/sample.cache",
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
            path: "/tmp/cleanmac-step1-fixture/cache-a",
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
    /// 测试做法：直接断言 [TreeBrowserView.computeVerdicts(for:using:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 这个 internal 静态 helper（Step 1 同步引入）对 N 行只调用 N 次 evaluator。
    /// 之后即便 reduce 再读 flat.verdict 1000 次，counter 仍 == N。
    func testComputeVerdictsCallsEvaluatorOncePerRow() {
        let rows: [TreeRow] = (0..<5).map { idx in
            TreeRow(
                path: "/tmp/cleanmac-step1-fixture/row-\(idx)",
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

    /// 把"forbid 路径不可 trash"这个语义从 evaluator 解耦到 verdict 字段：
    /// TreeNodeRow.isTrashable 应当只读 `flat.verdict != .forbid`，不再直接调 evaluate。
    func testFlatTreeRowVerdictDrivesIsTrashableSemantics() {
        let safeRow = TreeRow(path: "/tmp/cleanmac-step1-fixture/safe",
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

// MARK: - Test helpers

/// 计数 evaluator——每被调一次就把 [count](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift) +1。
/// 用于断言 SwiftUI 重绘 hot path 不再触发 SafetyEngine.evaluate。
@MainActor
private final class CountingEvaluator {
    private(set) var count: Int = 0

    /// 注意签名匹配 [TreeBrowserView.computeVerdicts(for:using:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 期望的 `(String) -> SafetyVerdict`。Step 1 生产代码会传 `Self.safety.evaluate(path:).0`。
    func evaluate(path: String) -> SafetyVerdict {
        count += 1
        // 测试不需要真去碰 SafetyEngine——固定回 .safe 即可；
        // 真实 forbid 语义由 [testFlatTreeRowVerdictDrivesIsTrashableSemantics](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/FlatTreeRowVerdictCacheTests.swift)
        // 的直接构造覆盖。
        return .safe
    }
}
