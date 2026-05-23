import XCTest
@testable import ScanKit

/// v1.3：MediaProbe 行为测试。
/// 注意：探测真实盘介质类型依赖 statfs，CI 与本地结果可能不同；
/// 这里只断言"路径可探测且不抛错"+"recommendedWorkerCount 满足业界共识"。
final class MediaProbeTests: XCTestCase {

    func test_探测当前用户目录_不应抛错_应返回非nil() throws {
        let kind = MediaProbe.probe(path: NSHomeDirectory())
        // M 系列 Mac 内置盘强制 APFS → 期望 .ssd；老款 Intel Mac 可能 hfsplus → .hdd；
        // CI 容器可能是 .unknown。任意一种都算合法。
        let allowed: [MediaProbe.Kind] = [.ssd, .hdd, .network, .unknown]
        XCTAssertTrue(allowed.contains(kind), "意外的介质类型: \(kind)")
    }

    func test_探测不存在路径_应返回unknown() {
        let kind = MediaProbe.probe(path: "/this/path/does/not/exist/at/all/zzz")
        XCTAssertEqual(kind, .unknown, "不存在路径 statfs 失败应回退 unknown")
    }

    func test_推荐worker_SSD应至少8个_受maxCap兜底() {
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .ssd, fallback: 4, maxCap: 8), 8)
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .ssd, fallback: 12, maxCap: 12), 12,
                       "SSD 在 maxCap 允许时取 max(fallback, 8)")
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .ssd, fallback: 4, maxCap: 6), 6,
                       "maxCap 必须兜底")
    }

    func test_推荐worker_HDD固定2() {
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .hdd, fallback: 8, maxCap: 8), 2)
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .hdd, fallback: 1, maxCap: 8), 2)
    }

    func test_推荐worker_网络盘固定1() {
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .network, fallback: 8, maxCap: 8), 1)
    }

    func test_推荐worker_unknown回退fallback() {
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .unknown, fallback: 4, maxCap: 8), 4)
        XCTAssertEqual(MediaProbe.recommendedWorkerCount(for: .unknown, fallback: 0, maxCap: 8), 1,
                       "fallback 0 应被 max(1,...) 兜成 1，避免 0 worker")
    }
}
