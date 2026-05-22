import XCTest
@testable import AppUI

/// TCCProbe —— 完全磁盘访问探针测试
///
/// 通过注入 fake reader 模拟系统对 `~/Library/Mail`、`~/Library/Safari`、`~/Library/Calendars`
/// 三个高敏目录的 `contentsOfDirectory` 行为：
/// - 成功 read   → 视为已授权
/// - errno=1（NSPOSIXErrorDomain Operation not permitted）→ 视为拒绝
/// - 其它错误（如 NSCocoaError 文件不存在）→ 不计入拒绝
final class TCCProbeTests: XCTestCase {

    /// 可编程的 fake reader：按 url 路径后缀决定是否抛错、抛什么错
    private struct FakeReader: TCCDirectoryReader {
        /// key: 子目录名（"Mail" / "Safari" / "Calendars"），value: 抛出的 error；nil 表示 read 成功
        let errorsByLeaf: [String: NSError?]

        func read(_ url: URL) throws {
            let leaf = url.lastPathComponent
            if let entry = errorsByLeaf[leaf], let error = entry {
                throw error
            }
        }
    }

    private static func opNotPermitted() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
    }

    private static func cocoaFileNotFound() -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: nil
        )
    }

    // MARK: - 用例 1：全部可读 → granted

    func test_全部可读时返回granted() async {
        let reader = FakeReader(errorsByLeaf: [
            "Mail": nil,
            "Safari": nil,
            "Calendars": nil
        ])
        let probe = TCCProbe(
            reader: reader,
            homeDirectory: URL(fileURLWithPath: "/tmp/fake-home")
        )

        let status = await probe.probe()
        XCTAssertEqual(status, .granted)
    }

    // MARK: - 用例 2：全部 errno=1 → deniedReadable(3)

    func test_三个高敏目录全部被拒时返回deniedReadable计数为3() async {
        let reader = FakeReader(errorsByLeaf: [
            "Mail": Self.opNotPermitted(),
            "Safari": Self.opNotPermitted(),
            "Calendars": Self.opNotPermitted()
        ])
        let probe = TCCProbe(
            reader: reader,
            homeDirectory: URL(fileURLWithPath: "/tmp/fake-home")
        )

        let status = await probe.probe()
        XCTAssertEqual(status, .deniedReadable(probedDenialCount: 3))
    }

    // MARK: - 用例 3：部分拒（Mail+Safari 拒，Calendars 通过）→ deniedReadable(2)

    func test_部分目录被拒时返回deniedReadable对应计数() async {
        let reader = FakeReader(errorsByLeaf: [
            "Mail": Self.opNotPermitted(),
            "Safari": Self.opNotPermitted(),
            "Calendars": nil
        ])
        let probe = TCCProbe(
            reader: reader,
            homeDirectory: URL(fileURLWithPath: "/tmp/fake-home")
        )

        let status = await probe.probe()
        XCTAssertEqual(status, .deniedReadable(probedDenialCount: 2))
    }

    // MARK: - 用例 4（边界）：errno 非 1 的错误不应计入拒绝

    func test_非errno1错误不计入拒绝仍判定为granted() async {
        let reader = FakeReader(errorsByLeaf: [
            "Mail": Self.cocoaFileNotFound(),
            "Safari": nil,
            "Calendars": nil
        ])
        let probe = TCCProbe(
            reader: reader,
            homeDirectory: URL(fileURLWithPath: "/tmp/fake-home")
        )

        let status = await probe.probe()
        XCTAssertEqual(status, .granted, "NSCocoaError 文件不存在不应被识别为 TCC 拒绝")
    }
}
