import XCTest
@testable import ScanKit

/// Step 13B：BulkScanner micro-batch 行为测试。
///
/// 目标（AUDIT line 449-451）：把"逐 entry yield .node"改为"按目录批量 yield .nodes([FSNode])"，
/// 减少跨 actor / continuation hop 的频繁触发开销，但**不改变**最终扫到的文件总数。
///
/// 测试约束：
/// 1. 数据可达性：node 数量恒等（无论 yield 形态怎么改，扫到的文件总数不能少）
/// 2. yield 次数：.node + .nodes 累计 yield 次数应远低于 file count（典型 ≤ 目录数 + 几十）
/// 3. 兼容旧消费方：保留 `.node(FSNode)` 单 case，BulkScanner 默认按目录用 `.nodes` 批量
///    ——`.node` 仍可被产出（单 entry 目录场景），但绝对不出现"5000 文件 → 5000 次 yield"
final class BulkScannerMicroBatchTests: XCTestCase {

    /// 造 5000 个 1KB 文件铺到 50 个目录（每目录 100 文件）。
    private func makeFixture(fileCount: Int = 5000, dirCount: Int = 50) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BulkScannerMicroBatch-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let perDir = max(1, fileCount / dirCount)
        let payload = Data(repeating: 0xAB, count: 1024)
        for d in 0..<dirCount {
            let sub = root.appendingPathComponent("d\(d)", isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<perDir {
                try payload.write(to: sub.appendingPathComponent("f\(f).bin"))
            }
        }
        return root
    }

    /// 关键断言：5000 文件场景下，BulkScanner 的"含 node 数据的 yield 次数"应远低于 5000。
    /// 落到"按目录批量"实现下，期望 yield 次数 ≤ dirCount + 一些 root 类杂项 ≤ 200。
    /// AUDIT line 451 的精神：195k mock fixture yield 次数 ≤ 4000；这里取等比例尺度的 200。
    func test_5000文件场景_数据型yield次数应远低于文件数() async throws {
        let root = try makeFixture(fileCount: 5000, dirCount: 50)
        defer { try? FileManager.default.removeItem(at: root) }

        let opts = ScanOptions(includeHidden: false, concurrency: 4, maxConcurrency: 4, mediaAware: false)
        let scanner = BulkScanner(options: opts)

        var totalNodes = 0
        var dataYieldCount = 0   // .node + .nodes 各算 1 次 yield
        var batchYieldCount = 0  // 仅 .nodes
        var summary: ScanSummary?

        for await ev in scanner.scan(root: root) {
            switch ev {
            case .node:
                totalNodes += 1
                dataYieldCount += 1
            case .nodes(let arr):
                totalNodes += arr.count
                dataYieldCount += 1
                batchYieldCount += 1
            case .finished(let s):
                summary = s
            default:
                break
            }
        }

        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.fileCount, 5000, "数据完整性：5000 文件不能少扫")
        XCTAssertEqual(summary?.directoryCount, 50, "数据完整性：50 子目录都要扫到")

        // node + nodes 累计的 entry 数应等于"5000 文件 + 50 子目录"。
        // root 自身不会被 enumerate emit（BulkScanner 从 root 进入下钻，不为 root 自己生成 FSNode）
        XCTAssertEqual(totalNodes, 5000 + 50, "node 数据完整性")

        // micro-batch 主张：data 型 yield 次数远低于 entry 数
        XCTAssertLessThan(
            dataYieldCount, 200,
            "micro-batch 退化：5000 entry 场景 yield 次数 \(dataYieldCount) 仍超 200，疑似仍在逐 node yield"
        )

        // 至少有相当数量的批量 yield（避免"全走单 .node 路径"的退化）
        XCTAssertGreaterThan(
            batchYieldCount, 0,
            ".nodes batch yield 一次都没出现，BulkScanner 没启用 micro-batch"
        )
        print("[BulkScanner MicroBatch] entries=\(totalNodes) dataYield=\(dataYieldCount) batchYield=\(batchYieldCount)")
    }

    /// 兼容性：含 .node 路径的旧消费方继续工作（Coordinator / Bench / 大量测试都用 `case .node(let n)`）。
    /// BulkScanner 必须保证：把 .nodes 数组逐项当作 .node 处理后的 entry 总数与 .nodes 累计 entry 数一致。
    func test_兼容旧消费方_node与nodes累计entry一致() async throws {
        let root = try makeFixture(fileCount: 1000, dirCount: 10)
        defer { try? FileManager.default.removeItem(at: root) }

        let opts = ScanOptions(includeHidden: false, concurrency: 2, maxConcurrency: 2, mediaAware: false)
        let scanner = BulkScanner(options: opts)

        var collectedNodes: [FSNode] = []
        for await ev in scanner.scan(root: root) {
            switch ev {
            case .node(let n):
                collectedNodes.append(n)
            case .nodes(let arr):
                collectedNodes.append(contentsOf: arr)
            default:
                break
            }
        }

        let fileNodes = collectedNodes.filter { !$0.isDirectory }.count
        let dirNodes = collectedNodes.filter { $0.isDirectory }.count
        XCTAssertEqual(fileNodes, 1000, "把 .nodes 展平后文件总数应等于 fixture")
        XCTAssertEqual(dirNodes, 10, "把 .nodes 展平后子目录总数应等于 fixture（root 不被 emit）")
    }

    /// .nodes batch 内的元素必须**同根同目录**或至少 worker 内顺序合理。
    /// 这里验证更弱但本质的属性：batch 内所有 FSNode 的父路径一致。
    /// 防"未来某次重构把多目录 entry 混入同一 batch"破坏 UI 展示假设。
    func test_nodes_batch内元素应来自同一父目录() async throws {
        let root = try makeFixture(fileCount: 600, dirCount: 6)
        defer { try? FileManager.default.removeItem(at: root) }

        let opts = ScanOptions(includeHidden: false, concurrency: 2, maxConcurrency: 2, mediaAware: false)
        let scanner = BulkScanner(options: opts)

        var sawAtLeastOneBatch = false
        for await ev in scanner.scan(root: root) {
            if case .nodes(let arr) = ev, arr.count >= 2 {
                let parents = Set(arr.map { $0.url.deletingLastPathComponent().path })
                XCTAssertEqual(parents.count, 1, "同一 .nodes batch 应只来自一个父目录，发现 \(parents.count)")
                sawAtLeastOneBatch = true
            }
        }
        XCTAssertTrue(sawAtLeastOneBatch, "fixture 至少应触发一次 size>=2 的 .nodes batch")
    }
}
