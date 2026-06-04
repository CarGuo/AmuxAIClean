import XCTest
@testable import AppUI

/// Step 17-A / 2026-06：dirIndex / childEdges 内存占用护栏测。
///
/// 不优化产品代码，仅在测试层把当前内存占用契约钉住，对新引入的字段或数据结构
/// 改动建立"无声膨胀"防线。与 Step 17-D（i18n lint 钉 backlog）同款风格——
/// 零产品代码改动，纯测试层增项。
///
/// 三类契约：
///
/// 1. **结构体大小不变量（MemoryLayout）**：
///    - DirAgg：当前 4 字段（3×Int64 + Date?） → MemoryLayout.size = 33B（含 1B
///      tag bit）。设上限 64B：足够容纳再加 1 个 Optional Int64 字段，但能挡住
///      "把 Date? 换成更大 reference type"或"加一堆 String 字段"的退化改动。
///    - Bucket：当前字段更多（含 SafetyVerdict / SafetyRejection / VendorRule
///      enum cache）—— 上限 256B，留够 trace cache 字段未来扩展余地。
///
/// 2. **字典 entry-count 不变量（无幽灵 entry）**：
///    seed N 条独立 path 后，`_dirIndexKeysForTesting().count == N`、
///    `_childEdgesForTesting().keys.count == N`。防止 ingest 路径误把某个 key
///    重复登记到不同字典或塞进 placeholder entry。
///
/// 3. **Set 去重契约**：
///    childEdges 用 `Set<String>` 而非 `Array<String>` 的根本原因是：祖先回溯
///    会让同一 (parent, child) pair 被反复 insert（每个文件叶子都会让 cursor
///    走到同一目录然后 insert 同一个 child）。Set 自带去重保证存储不爆。
///    本契约直接验证：插入 N 条重复 → 实际 set.count == 1。
///
/// 取舍：
///   - 不跑真扫描（费时且依赖 fixture），用 `_seedForTesting` 注入。
///   - 不测 reset 路径（[scan L571](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L571)
///     的 `keepingCapacity: true` 是性能优化，行为契约由现有 ScanCoordinatorTests 兜底）。
///   - 不测真实 ingest 路径里的"100k 文件后 dirIndex.count 应当为多少"——这要重新
///     发明 fixture，也不该是本测的范畴。
@MainActor
final class DirIndexMemoryFootprintTests: XCTestCase {

    // MARK: - 契约 1：结构体大小不变量

    /// DirAgg 是 ingest hot path 上每条目录都要分配的小结构体。
    /// 当前：bytes(8) + logicalBytes(8) + fileCount(8 on 64-bit) + Date?(17) = 33B。
    /// 设上限 64B：留 1 倍 buffer 以容纳"再加 1 个 Optional Int64"，但挡住更激进的扩张。
    func test_DirAgg_size_不超过64B() {
        let size = ScanCoordinator._dirAggSizeForTesting
        XCTAssertLessThanOrEqual(
            size, 64,
            "DirAgg 结构体当前 size=\(size)B，超过 64B 上限。新增字段或换大类型前请评估每条目录的内存占用——10 万条目录 × Δ字节 = MB 级膨胀。"
        )
        // 同时设下限：防止有人误把字段全删光让 size 跌到 0/异常值
        XCTAssertGreaterThanOrEqual(
            size, 16,
            "DirAgg size=\(size)B 异常偏小——预期至少含 bytes/fileCount 两个 Int64 字段。"
        )
    }

    /// Bucket 是一级子目录聚合，含 SafetyEngine 缓存（verdict/rejection/vendor 三 enum cache）。
    /// 当前实测约 100~200B（具体由 enum cache 字段决定）。设上限 256B：
    /// 留够"再加 1 个 cache 字段"的余地，但挡住"把整个 SafetyEngine 引用塞进每个 Bucket"。
    func test_Bucket_size_不超过256B() {
        let size = ScanCoordinator._bucketSizeForTesting
        XCTAssertLessThanOrEqual(
            size, 256,
            "Bucket 结构体当前 size=\(size)B，超过 256B 上限。Bucket 是每个一级子目录都要分配的——数千 bucket × Δ字节 = 显著内存压力。"
        )
        XCTAssertGreaterThanOrEqual(
            size, 32,
            "Bucket size=\(size)B 异常偏小——预期至少含 url+bytes+isDirectory。"
        )
    }

    // MARK: - 契约 2：字典 entry-count 不变量

    /// seed N 条独立 path → dirIndex 应有恰好 N 个 entry，无多余无少。
    func test_dirIndex_seed_N条path_count等于N() {
        let coord = ScanCoordinator()
        let paths = (0..<100).map { "/seed/dir_\($0)" }
        coord._seedForTesting(dirIndex: paths)
        XCTAssertEqual(
            coord._dirIndexKeysForTesting().count, 100,
            "seed 100 条独立 path 应该让 dirIndex.count == 100，实际 = \(coord._dirIndexKeysForTesting().count)"
        )
        // 每条 key 都应当存在
        let actualKeys = Set(coord._dirIndexKeysForTesting())
        XCTAssertEqual(
            actualKeys, Set(paths),
            "dirIndex keys 与 seed 路径不一致——存在幽灵 entry 或丢失 entry。"
        )
    }

    /// seed N 条独立父 path 各 5 个孩子 → childEdges 应有恰好 N 个 parent key，每个 set 5 个孩子。
    func test_childEdges_seed_N父M子_条目数正确() {
        let coord = ScanCoordinator()
        var edges: [String: Set<String>] = [:]
        for i in 0..<50 {
            let parent = "/seed/parent_\(i)"
            edges[parent] = Set((0..<5).map { "\(parent)/child_\($0)" })
        }
        coord._seedForTesting(childEdges: edges)
        let actual = coord._childEdgesForTesting()
        XCTAssertEqual(
            actual.keys.count, 50,
            "childEdges 父集合数应为 50，实际 = \(actual.keys.count)"
        )
        for (parent, kids) in actual {
            XCTAssertEqual(
                kids.count, 5,
                "parent \(parent) 应有 5 个孩子，实际 = \(kids.count)"
            )
        }
    }

    // MARK: - 契约 3：Set 去重契约

    /// childEdges 的 Set<String> 必须对重复 insert 去重——这是 ingest 祖先回溯
    /// 路径正确性的基础（每个文件叶子都会让 cursor 走到同一目录然后 insert 同一 child）。
    func test_childEdges_重复insert必须去重() {
        let coord = ScanCoordinator()
        let parent = "/seed/dup_parent"
        let child = "/seed/dup_parent/the_only_child"
        // 模拟 ingest hot path：同一对 (parent, child) 被插入 1000 次
        var set: Set<String> = []
        for _ in 0..<1000 {
            set.insert(child)
        }
        coord._seedForTesting(childEdges: [parent: set])
        let actual = coord._childEdgesForTesting()
        XCTAssertEqual(
            actual[parent]?.count, 1,
            "Set 必须去重：1000 次插入同一 child 应当只有 1 个 entry，实际 = \(String(describing: actual[parent]?.count))"
        )
        XCTAssertTrue(
            actual[parent]?.contains(child) ?? false,
            "去重后 child 应当仍在 set 内，实际不存在"
        )
    }

    // MARK: - 契约 4：dirIndex / childEdges 互不污染

    /// seed dirIndex 不应当让 childEdges 出现幽灵 entry，反之亦然。
    /// 这条契约钉住"两个字典各管各的"——防止后续重构误把 dirIndex 写入也镜像到 childEdges。
    func test_dirIndex_与childEdges_互不污染() {
        let coord = ScanCoordinator()
        coord._seedForTesting(dirIndex: ["/only/in/dirIndex"])
        XCTAssertEqual(coord._dirIndexKeysForTesting().count, 1)
        XCTAssertEqual(
            coord._childEdgesForTesting().keys.count, 0,
            "seed dirIndex 不应当让 childEdges 出现 entry，实际 = \(coord._childEdgesForTesting().keys)"
        )

        let coord2 = ScanCoordinator()
        coord2._seedForTesting(childEdges: ["/parent": ["/parent/c1"]])
        XCTAssertEqual(coord2._childEdgesForTesting().keys.count, 1)
        XCTAssertEqual(
            coord2._dirIndexKeysForTesting().count, 0,
            "seed childEdges 不应当让 dirIndex 出现 entry，实际 = \(coord2._dirIndexKeysForTesting())"
        )
    }
}
