import XCTest
@testable import ScanKit

/// v1.3.x：TreeSizeEstimator 行为测试。
final class TreeSizeEstimatorTests: XCTestCase {

    func test_estimate_单一目录_应返回所有常规文件大小之和() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeFile(in: tmp, name: "a.bin", bytes: 1024)
        try writeFile(in: tmp, name: "b.bin", bytes: 2048)
        // 子目录里的也要算
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(in: sub, name: "c.bin", bytes: 4096)

        let total = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 4.0)
        XCTAssertEqual(total, 1024 + 2048 + 4096)
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

        let total = await TreeSizeEstimator.estimate(roots: [tmp1, tmp2], timeout: 4.0)
        XCTAssertEqual(total, 300)
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
        defer { try? FileManager.default.removeItem(at: tmp) }
        let total = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 1.0)
        XCTAssertEqual(total, 0, "空目录是合法估算结果，应返回 0 字节")
    }

    func test_estimate_符号链接不应被递归吞() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeFile(in: tmp, name: "real.bin", bytes: 500)
        // 创建一个指向自己的 symlink，如果 estimator 跟着递归就会爆炸
        let link = tmp.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp)

        let total = await TreeSizeEstimator.estimate(roots: [tmp], timeout: 2.0)
        XCTAssertNotNil(total)
        // 至少包含 real.bin；不应该因为 symlink 循环爆栈/超时
        XCTAssertGreaterThanOrEqual(total ?? 0, 500)
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
}
