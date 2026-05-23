import XCTest
@testable import ScanKit

/// v1.3：VolumeCapacity 行为测试。CI 与本地的 disk 状态不同，
/// 只能断言"探测成功后字段值满足语义不变量"。
final class VolumeCapacityTests: XCTestCase {

    func test_探测根目录_应返回非nil_且usedBytes不为负() throws {
        guard let s = VolumeCapacity.probe(at: "/") else {
            XCTFail("根 / 必须可探测")
            return
        }
        XCTAssertGreaterThan(s.totalBytes, 0, "总容量必须 > 0")
        XCTAssertGreaterThanOrEqual(s.availableBytes, 0, "可用容量不能为负")
        XCTAssertLessThanOrEqual(s.availableBytes, s.totalBytes, "可用 ≤ 总容量")
        XCTAssertGreaterThanOrEqual(s.usedBytes, 0, "已用 = 总-可用，应 ≥ 0")
        XCTAssertFalse(s.volumeName.isEmpty, "卷名不应为空")
    }

    func test_探测不存在路径_应返回nil() {
        let s = VolumeCapacity.probe(at: "/this/path/does/not/exist/zzz")
        XCTAssertNil(s, "不存在路径 resourceValues 失败应返回 nil")
    }

    func test_Snapshot_usedBytes_等于_total减available() {
        let s = VolumeCapacity.Snapshot(volumeName: "Test",
                                        totalBytes: 100,
                                        availableBytes: 30)
        XCTAssertEqual(s.usedBytes, 70)
    }

    func test_Snapshot_avail大于total时_usedBytes兜底为0() {
        // 异常输入：available > total
        let s = VolumeCapacity.Snapshot(volumeName: "Test",
                                        totalBytes: 100,
                                        availableBytes: 200)
        XCTAssertEqual(s.usedBytes, 0, "max(0,100-200)=0 兜底")
    }
}
