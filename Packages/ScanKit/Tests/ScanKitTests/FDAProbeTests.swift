import XCTest
import Darwin
@testable import ScanKit

/// v1.3：FDAProbe 行为测试。
/// 注意：本机是否真授予 FDA 不确定，所以只断言"返回值在合法枚举集内 + 不抛错"。
final class FDAProbeTests: XCTestCase {

    func test_探测当前用户_应返回合法枚举值之一() {
        let status = FDAProbe.probe()
        XCTAssertTrue([.granted, .denied, .unknown].contains(status),
                      "意外的探测状态: \(status)")
    }

    func test_探测不存在的家目录_应返回unknown() {
        // 三个探针 (Mail/Safari/Messages) 在伪造路径下都不存在 → unknown
        let fake = "/tmp/nonexistent-home-\(UUID().uuidString)"
        let status = FDAProbe.probe(home: fake)
        XCTAssertEqual(status, .unknown,
                       "三个探针都不存在的伪 home 应返回 unknown")
    }

    func test_探测_tmp目录可读_应返回granted() throws {
        // 构造一个有 Library/Mail 探针的伪 home，且本进程一定能读
        let fakeHome = NSTemporaryDirectory() + "fda-probe-test-\(UUID().uuidString)"
        let mailPath = "\(fakeHome)/Library/Mail"
        try FileManager.default.createDirectory(atPath: mailPath,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fakeHome) }

        let status = FDAProbe.probe(home: fakeHome)
        XCTAssertEqual(status, .granted,
                       "伪 home 下 Library/Mail 我们自己创建的，open 必成功")
    }

    func test_第一个探针被拒但后续探针可读_应返回granted避免误报() throws {
        let fakeHome = NSTemporaryDirectory() + "fda-probe-mixed-\(UUID().uuidString)"
        let mailPath = "\(fakeHome)/Library/Mail"
        let safariPath = "\(fakeHome)/Library/Safari"
        try FileManager.default.createDirectory(atPath: mailPath,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: safariPath,
                                                withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.chmod(mailPath, 0), 0)
        defer {
            _ = Darwin.chmod(mailPath, S_IRWXU)
            try? FileManager.default.removeItem(atPath: fakeHome)
        }

        let status = FDAProbe.probe(home: fakeHome)
        XCTAssertEqual(status, .granted,
                       "不能因为第一个存在的探针失败就直接判 FDA denied；后续 TCC 探针可读时应认为当前进程具备可用访问能力")
    }

    func test_所有存在探针都被拒_应返回denied() throws {
        let fakeHome = NSTemporaryDirectory() + "fda-probe-denied-\(UUID().uuidString)"
        let mailPath = "\(fakeHome)/Library/Mail"
        try FileManager.default.createDirectory(atPath: mailPath,
                                                withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.chmod(mailPath, 0), 0)
        defer {
            _ = Darwin.chmod(mailPath, S_IRWXU)
            try? FileManager.default.removeItem(atPath: fakeHome)
        }

        let status = FDAProbe.probe(home: fakeHome)
        XCTAssertEqual(status, .denied)
    }
}
