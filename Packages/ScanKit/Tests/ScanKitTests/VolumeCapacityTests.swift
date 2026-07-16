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
        XCTAssertEqual(s.usedBytes + s.availableBytes, s.totalBytes,
                       "主 used + 普通 available 必须严格守恒")
        if let estimate = s.estimatedReclaimableBytes {
            XCTAssertGreaterThanOrEqual(estimate, 0, "预计可回收容量不能为负")
            XCTAssertLessThanOrEqual(estimate, s.totalBytes - s.availableBytes,
                                     "预计回收后可用不能超过卷总容量")
            XCTAssertEqual(s.availableIfReclaimedBytes,
                           s.availableBytes + estimate,
                           "回收后预计可用只能是普通 available + estimate")
        } else {
            XCTAssertNil(s.availableIfReclaimedBytes,
                         "缺少预计可回收口径时不能伪造回收后可用")
        }
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
        XCTAssertEqual(s.availableBytes, 100,
                       "Snapshot 边界必须统一钳制普通 available，不能把异常值交给 UI")
    }

    /// v2026.07.15：根因合同——ordinary available 永远是主数，important usage
    /// 只产出独立差值；防止 headline 再次把预计回收后的 200 当成真实空闲。
    func test_makeSnapshot_普通可用是主数_important只形成独立估算() throws {
        let s = try XCTUnwrap(VolumeCapacity.makeSnapshot(
            volumeName: "Test",
            totalBytes: 500,
            ordinaryAvailableBytes: 60,
            importantUsageAvailableBytes: 200
        ))

        XCTAssertEqual(s.availableBytes, 60)
        XCTAssertEqual(s.usedBytes, 440)
        XCTAssertEqual(s.estimatedReclaimableBytes, 140)
        XCTAssertEqual(s.availableIfReclaimedBytes, 200)
        XCTAssertEqual(s.usedBytes + s.availableBytes, s.totalBytes,
                       "estimate 不得进入主容量守恒式")
    }

    func test_makeSnapshot_缺少普通可用时_拒绝拿important冒充主数() {
        let s = VolumeCapacity.makeSnapshot(
            volumeName: "Test",
            totalBytes: 500,
            ordinaryAvailableBytes: nil,
            importantUsageAvailableBytes: 200
        )

        XCTAssertNil(s)
    }

    func test_makeSnapshot_important低于普通可用时_保留物理主数但估算未知() throws {
        let s = try XCTUnwrap(VolumeCapacity.makeSnapshot(
            volumeName: "Test",
            totalBytes: 500,
            ordinaryAvailableBytes: 200,
            importantUsageAvailableBytes: 60
        ))

        XCTAssertEqual(s.availableBytes, 200)
        XCTAssertEqual(s.usedBytes, 300)
        XCTAssertNil(s.estimatedReclaimableBytes)
        XCTAssertNil(s.availableIfReclaimedBytes)
    }

    func test_Snapshot_预计可回收会钳制到卷剩余空间_但不改变主数() {
        let s = VolumeCapacity.Snapshot(
            volumeName: "Test",
            totalBytes: 100,
            availableBytes: 40,
            estimatedReclaimableBytes: 200
        )

        XCTAssertEqual(s.availableBytes, 40)
        XCTAssertEqual(s.usedBytes, 60)
        XCTAssertEqual(s.estimatedReclaimableBytes, 60)
        XCTAssertEqual(s.availableIfReclaimedBytes, 100)
    }

    func test_Snapshot_负预计可回收保持未知而不是伪造零() {
        let s = VolumeCapacity.Snapshot(
            volumeName: "Test",
            totalBytes: 100,
            availableBytes: 40,
            estimatedReclaimableBytes: -1
        )

        XCTAssertNil(s.estimatedReclaimableBytes)
        XCTAssertNil(s.availableIfReclaimedBytes)
    }
}
