import XCTest
@testable import ScanKit

/// v1.3.x：TreeSizeEstimator 行为测试。
final class TreeSizeEstimatorTests: XCTestCase {

    func test_estimate_单一目录_应返回所有常规文件磁盘占用之和() async throws {
        let tmp = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        try writeFile(in: tmp, name: "a.bin", bytes: 1024)
        try writeFile(in: tmp, name: "b.bin", bytes: 2048)
        // 子目录里的也要算
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(in: sub, name: "c.bin", bytes: 4096)

        let expected = try allocatedSize(of: tmp.appendingPathComponent("a.bin"))
            + allocatedSize(of: tmp.appendingPathComponent("b.bin"))
            + allocatedSize(of: sub.appendingPathComponent("c.bin"))
        let total = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 4.0)
        XCTAssertEqual(total, expected)
    }

    func test_estimate_多根_应累加() async throws {
        let tmp1 = try makeTempDir()
        let tmp2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }
        try writeFile(in: tmp1, name: "x.bin", bytes: 100)
        try writeFile(in: tmp2, name: "y.bin", bytes: 200)

        let expected = try allocatedSize(of: tmp1.appendingPathComponent("x.bin"))
            + allocatedSize(of: tmp2.appendingPathComponent("y.bin"))
        let total = await TreeSizeEstimator.estimate(roots: [tmp1, tmp2], timeout: 4.0)
        XCTAssertEqual(total, expected)
    }

    func test_estimate_空根列表_应返回nil() async {
        let total = await TreeSizeEstimator.estimate(roots: [], timeout: 1.0)
        XCTAssertNil(total)
    }

    func test_estimate_完全不存在的根_应优雅返回0或nil() async {
        let url = URL(fileURLWithPath: "/this/path/never/exists/zzz/\(UUID().uuidString)")
        let total = await TreeSizeEstimator.estimate(roots: [url], timeout: 1.0)
        // FileManager.enumerator 对不存在的路径会返回 enumerator 但立即迭代结束；
        // 我们的 walkRoot 因此返回 0 而非 nil。这两者在 UI 上等价（都视作"无估算"），
        // 所以验收条件放宽：0 或 nil 都接受，不接受任何正数。
        if let t = total {
            XCTAssertEqual(t, 0, "不存在路径估算结果只能是 0")
        }
    }

    func test_estimate_空目录_应返回0而非nil() async throws {
        let tmp = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let total = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 1.0)
        XCTAssertEqual(total, 0, "空目录是合法估算结果，应返回 0 字节")
    }

    func test_estimate_符号链接不应被递归吞() async throws {
        let tmp = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        try writeFile(in: tmp, name: "real.bin", bytes: 500)
        // 创建一个指向自己的 symlink，如果 estimator 跟着递归就会爆炸
        let link = tmp.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp)

        let total = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 2.0)
        XCTAssertNotNil(total)
        // 至少包含 real.bin；不应该因为 symlink 循环爆栈/超时
        XCTAssertGreaterThanOrEqual(total ?? 0, 500)
    }

    func test_estimate_稀疏文件_应返回磁盘占用而不是虚拟容量() async throws {
        let tmp = try makeTempDir()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: tmp)) }
        let sparse = tmp.appendingPathComponent("Docker.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data([0x1])))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try handle.close()

        let estimate = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 4.0)
        let total = try XCTUnwrap(estimate)
        XCTAssertEqual(total, try allocatedSize(of: sparse))
        XCTAssertLessThan(total, 64 * 1_024 * 1_024,
                          "ETA 分母不能把 Docker sparse 虚拟容量当成磁盘占用")
    }

    // MARK: - Step 13A 并发改造：5 根并发不应远慢于 1 根串行

    /// 5 根并发：`TreeSizeEstimator` 必须把多根分散到独立 detached Task 跑，
    /// 让总耗时趋近"最慢那根"的耗时，而不是"5 根串行求和"。
    /// 阈值取 ≤3.0x 最大单根耗时——给 Task 启动 / actor hop / IO 带宽争用留余量，
    /// 但能兜住"完全串行化"的退化（串行会是 ~5x）。
    /// AUDIT line 446 验收基线。
    func test_5根并发_总耗时不超过最慢单根的3倍() async throws {
        // 5 个根，每根铺 4000 个 4KB 文件，让 walk 耗时显著大于 Task 启动开销
        let perRootFiles = 4000
        let perFileBytes = 4096
        var roots: [URL] = []
        for _ in 0..<5 {
            let r = try makeTempDir()
            for i in 0..<perRootFiles {
                try writeFile(in: r, name: "f\(i).bin", bytes: perFileBytes)
            }
            roots.append(r)
        }
        defer {
            for r in roots { try? FileManager.default.removeItem(at: r) }
        }

        // 各跑三次取最优，规避首次 IO 缓存冷启动抖动
        func bestSingleRootElapsed(_ root: URL) async -> TimeInterval {
            var best: TimeInterval = .greatestFiniteMagnitude
            for _ in 0..<3 {
                let t0 = Date()
                _ = await TreeSizeEstimator.estimate(roots: [root], timeout: 8.0)
                best = min(best, Date().timeIntervalSince(t0))
            }
            return best
        }

        // 取 5 根中"最慢那根"的最优耗时作为分母（给 IO 缓存留同样优势）
        var slowestSingle: TimeInterval = 0
        for r in roots {
            slowestSingle = max(slowestSingle, await bestSingleRootElapsed(r))
        }

        // 跑 5 根并发的最优耗时
        var bestConcurrent: TimeInterval = .greatestFiniteMagnitude
        for _ in 0..<3 {
            let t0 = Date()
            _ = await TreeSizeEstimator.estimate(roots: roots, timeout: 12.0)
            bestConcurrent = min(bestConcurrent, Date().timeIntervalSince(t0))
        }

        let ratio = bestConcurrent / max(slowestSingle, 0.001)
        print("[TreeSizeEstimator Perf] 5-roots concurrent / slowest-single ratio = \(String(format: "%.2f", ratio))x  (concurrent=\(String(format: "%.3f", bestConcurrent))s, slowest=\(String(format: "%.3f", slowestSingle))s)")

        XCTAssertLessThan(
            ratio, 3.0,
            "5 根并发耗时超过最慢单根的 3.0x —— estimator 没真正并发，疑似仍是串行 walk（串行会 ~5x）"
        )
    }

    /// 并发改造下的总数正确性：5 根并发结果必须等于"5 根串行单独估算之和"。
    /// 防"并发改造改坏聚合"。
    func test_5根并发_结果应等于各根之和() async throws {
        let perRootFiles = 200
        let perFileBytes = 1024
        var roots: [URL] = []
        var expectedAllocated: Int64 = 0
        for _ in 0..<5 {
            let r = try makeTempDir()
            for i in 0..<perRootFiles {
                try writeFile(in: r, name: "f\(i).bin", bytes: perFileBytes)
                expectedAllocated += try allocatedSize(of: r.appendingPathComponent("f\(i).bin"))
            }
            roots.append(r)
        }
        defer {
            for r in roots { try? FileManager.default.removeItem(at: r) }
        }

        var sumOfSingles: Int64 = 0
        for r in roots {
            let t = await TreeSizeEstimator.estimate(roots: [r], timeout: 4.0) ?? 0
            sumOfSingles += t
        }
        let concurrent = await TreeSizeEstimator.estimate(roots: roots, timeout: 4.0) ?? -1
        XCTAssertEqual(concurrent, sumOfSingles, "5 根并发聚合结果应等于各根串行之和")
        XCTAssertEqual(concurrent, expectedAllocated, "结果应等于文件系统报告的磁盘分配量")
    }

    /// 并发改造下的取消传播：调用方 task 被取消时，所有根 walk 应及时结束（不等到全部跑完）。
    /// 用一个超大根 + 短 timeout 验证：估算器不能一直 spin 直到 walk 完。
    func test_5根并发_短timeout应及时返回() async throws {
        // 每根 1500 文件 × 5 根 = 7500 个文件，单根 walk 耗时仍显著大于 0.05s timeout
        let perRootFiles = 1500
        var roots: [URL] = []
        for _ in 0..<5 {
            let r = try makeTempDir()
            for i in 0..<perRootFiles {
                try writeFile(in: r, name: "f\(i).bin", bytes: 64)
            }
            roots.append(r)
        }
        defer {
            for r in roots { try? FileManager.default.removeItem(at: r) }
        }

        let t0 = Date()
        _ = await TreeSizeEstimator.estimate(roots: roots, timeout: 0.05)
        let elapsed = Date().timeIntervalSince(t0)
        // 给 0.5s 的 wall-clock 上限——0.05s timeout + 检查 granularity + Task 收尾
        XCTAssertLessThan(elapsed, 0.5, "短 timeout 下 5 根并发未能及时返回，疑似某根 walk 阻塞")
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TreeSizeEstimatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(in dir: URL, name: String, bytes: Int) throws {
        let data = Data(repeating: 0xCD, count: bytes)
        try data.write(to: dir.appendingPathComponent(name))
    }

    private func allocatedSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
