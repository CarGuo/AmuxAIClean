import XCTest
@testable import AppUI

/// **Step 9c / 2026-06**：[LargeFileLeafTopNHeap](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/LargeFileLeafTopNHeap.swift) 单元测试。
///
/// 验证 min-heap Top-N 的契约：
/// - 数据量 < capacity：全部保留
/// - 数据量 >> capacity：只保留 Top-N（按 bytes 降序）
/// - capacity = 0：空收集
/// - bytes 相等的边界：稳定不抖动
final class LargeFileLeavesHeapTests: XCTestCase {

    // MARK: - helpers

    private func leaf(_ name: String, _ bytes: Int64) -> ScanCoordinator.LargeFileLeaf {
        ScanCoordinator.LargeFileLeaf(
            path: "/tmp/\(name)",
            bytes: bytes,
            modificationDate: nil
        )
    }

    /// 把 heap 内容按 bytes 降序排序后取数组（便于断言）。
    private func sortedDesc(_ heap: LargeFileLeafTopNHeap) -> [ScanCoordinator.LargeFileLeaf] {
        heap.snapshot().sorted { $0.bytes > $1.bytes }
    }

    // MARK: - capacity = 0：禁用收集

    func test_capacity为0_所有consider都被丢弃() {
        var heap = LargeFileLeafTopNHeap(capacity: 0)
        for i in 0..<100 {
            let accepted = heap.consider(leaf("a\(i)", Int64(i + 1) * 1024 * 1024))
            XCTAssertFalse(accepted, "capacity=0 时永远不接受")
        }
        XCTAssertTrue(heap.isEmpty)
        XCTAssertEqual(heap.count, 0)
    }

    // MARK: - 数据量 < capacity：全部保留

    func test_少于capacity全部保留() {
        var heap = LargeFileLeafTopNHeap(capacity: 1000)
        for i in 0..<300 {
            heap.consider(leaf("a\(i)", Int64(i + 1) * 1024 * 1024))
        }
        XCTAssertEqual(heap.count, 300, "少于 N 时全部保留")
    }

    func test_等于capacity恰好保留() {
        var heap = LargeFileLeafTopNHeap(capacity: 100)
        for i in 0..<100 {
            heap.consider(leaf("a\(i)", Int64(i + 1)))
        }
        XCTAssertEqual(heap.count, 100)
        let bytesSet = Set(heap.snapshot().map(\.bytes))
        XCTAssertEqual(bytesSet, Set((1...100).map(Int64.init)),
                       "前 N 条应原样保留，无丢失无重复")
    }

    // MARK: - 数据量 >> capacity：仅保留 Top-N

    func test_万条只保留top1000_按size降序() {
        var heap = LargeFileLeafTopNHeap(capacity: 1000)
        // bytes = 1...10000，乱序 push
        var bytesArr = (1...10_000).map(Int64.init)
        bytesArr.shuffle()
        for (i, b) in bytesArr.enumerated() {
            heap.consider(leaf("k\(i)", b))
        }
        XCTAssertEqual(heap.count, 1000, "硬顶 capacity=1000")
        let topDesc = sortedDesc(heap)
        // 应当恰好是 9001...10000，按降序
        XCTAssertEqual(topDesc.first?.bytes, 10_000, "Top-1 必是最大值 10000")
        XCTAssertEqual(topDesc.last?.bytes, 9_001, "Top-1000 必是 9001（最小被保留值）")
        let expectedBytes: [Int64] = stride(from: Int64(10_000), through: Int64(9_001), by: -1).map { $0 }
        XCTAssertEqual(topDesc.map(\.bytes), expectedBytes,
                       "应保留 [9001, 10000] 区间，全 1000 条按降序对齐")
    }

    // MARK: - 边界：bytes 相等

    func test_bytes相等不抖动() {
        var heap = LargeFileLeafTopNHeap(capacity: 3)
        // 先填满
        XCTAssertTrue(heap.consider(leaf("a", 100)))
        XCTAssertTrue(heap.consider(leaf("b", 100)))
        XCTAssertTrue(heap.consider(leaf("c", 100)))
        // 再来一条 bytes 相等的，应被拒（"严格大于"才替换）
        XCTAssertFalse(heap.consider(leaf("d", 100)),
                       "bytes 相等不替换，避免无意义抖动")
        XCTAssertEqual(heap.count, 3)
        // 比 100 小的 → 拒
        XCTAssertFalse(heap.consider(leaf("e", 99)))
        // 比 100 大的 → 接受，替换最小
        XCTAssertTrue(heap.consider(leaf("f", 200)))
        XCTAssertEqual(heap.count, 3)
        let bytes = Set(heap.snapshot().map(\.bytes))
        XCTAssertEqual(bytes, [100, 100, 200], "替换后留两条 100 和一条 200")
    }

    // MARK: - removeAll

    func test_removeAll清空() {
        var heap = LargeFileLeafTopNHeap(capacity: 10)
        for i in 0..<10 {
            heap.consider(leaf("x\(i)", Int64(i + 1)))
        }
        XCTAssertEqual(heap.count, 10)
        heap.removeAll(keepingCapacity: true)
        XCTAssertTrue(heap.isEmpty)
        XCTAssertEqual(heap.count, 0)
        // 清空后还能继续用
        heap.consider(leaf("post", 999))
        XCTAssertEqual(heap.count, 1)
    }

    // MARK: - 性能 sanity（不做硬阈值断言，单纯跑过 100w 次不卡）

    func test_百万次consider不爆() {
        var heap = LargeFileLeafTopNHeap(capacity: 1000)
        for i in 0..<1_000_000 {
            heap.consider(leaf("p\(i)", Int64.random(in: 1...1_000_000)))
        }
        XCTAssertEqual(heap.count, 1000, "无论压多少次，硬顶始终 = 1000")
    }
}
