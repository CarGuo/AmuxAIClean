import XCTest
@testable import AppUI

/// Step 6.5：[SentinelURLRouter](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelURLRouter.swift)
/// 路由解析 + 路径防注入 单测。
///
/// 设计要点：
/// - `handle(_:)` 是 `@discardableResult` 同步方法，直接断言 `Outcome`；
///   附带的 NotificationCenter 副作用用 `expectation(forNotification:)` 验证。
/// - `validateAbsolutePath(_:)` 直接走真实 [FileManager](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelURLRouter.swift#L74-L83)
///   ——用 `/tmp` 下的临时文件覆盖真实存在分支。
final class SentinelURLRouterTests: XCTestCase {

    /// expectation(forNotification:) 的 handler 是 `@Sendable`，
    /// 直接捕获 `var` 会触发 Swift 6 mode 的并发警告。
    /// 用 NSLock-保护的引用 box 把可变捕获包成 sendable-safe 形式。
    private final class CapturedInfo: @unchecked Sendable {
        private let lock = NSLock()
        private var _info: [AnyHashable: Any]?
        func set(_ info: [AnyHashable: Any]?) {
            lock.lock(); defer { lock.unlock() }
            _info = info
        }
        var info: [AnyHashable: Any]? {
            lock.lock(); defer { lock.unlock() }
            return _info
        }
    }

    // MARK: - host 路由

    func test_handle_未知scheme_应记ignored() {
        let outcome = SentinelURLRouter.handle(URL(string: "https://example.com/uninstall")!)
        XCTAssertEqual(outcome, .ignored(reason: "bad-scheme"))
    }

    func test_handle_未知host_应记ignored() {
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://wat")!)
        XCTAssertEqual(outcome, .ignored(reason: "unknown-host"))
    }

    func test_handle_action未知子段_应记ignored() {
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://action/scan/quick")!)
        XCTAssertEqual(outcome, .ignored(reason: "unknown-action"))
    }

    func test_handle_actionScanFull_应广播通知_并返回startFullScan() {
        let exp = expectation(forNotification: .gsySentinelStartFullScan, object: nil)
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://action/scan/full")!)
        XCTAssertEqual(outcome, .startFullScan)
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - uninstall 路径校验

    func test_handle_uninstall无path_应广播空userInfo() {
        let captured = CapturedInfo()
        let exp = expectation(forNotification: .gsySentinelOpenUninstall, object: nil) { note in
            captured.set(note.userInfo)
            return true
        }
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://uninstall")!)
        XCTAssertEqual(outcome, .openUninstall(path: nil))
        wait(for: [exp], timeout: 1.0)
        XCTAssertNil(captured.info?[SentinelURLRouter.uninstallPathKey])
    }

    func test_handle_uninstall合法path_应携带path广播() throws {
        let tmp = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let captured = CapturedInfo()
        let exp = expectation(forNotification: .gsySentinelOpenUninstall, object: nil) { note in
            captured.set(note.userInfo)
            return true
        }
        let encoded = tmp.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tmp.path
        let url = URL(string: "amuxaiclean://uninstall?path=\(encoded)")!
        let outcome = SentinelURLRouter.handle(url)
        XCTAssertEqual(outcome, .openUninstall(path: tmp.path))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(captured.info?[SentinelURLRouter.uninstallPathKey] as? String, tmp.path)
    }

    func test_handle_uninstall相对path_应被拒_广播nil() {
        let captured = CapturedInfo()
        let exp = expectation(forNotification: .gsySentinelOpenUninstall, object: nil) { note in
            captured.set(note.userInfo)
            return true
        }
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://uninstall?path=Applications/Foo")!)
        XCTAssertEqual(outcome, .openUninstall(path: nil), "相对路径必须被拒")
        wait(for: [exp], timeout: 1.0)
        XCTAssertNil(captured.info?[SentinelURLRouter.uninstallPathKey])
    }

    func test_handle_uninstall路径含dotdot_应被拒() {
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://uninstall?path=/Applications/../etc")!)
        XCTAssertEqual(outcome, .openUninstall(path: nil), "含 .. 必须被拒")
    }

    func test_handle_uninstall不存在路径_应被拒() {
        let bogus = "/tmp/__gsy_sentinel_router_should_not_exist_\(UUID().uuidString)"
        let encoded = bogus.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bogus
        let outcome = SentinelURLRouter.handle(URL(string: "amuxaiclean://uninstall?path=\(encoded)")!)
        XCTAssertEqual(outcome, .openUninstall(path: nil), "不存在的路径必须被拒")
    }

    // MARK: - validateAbsolutePath 直测

    func test_validate_空字符串_返回nil() {
        XCTAssertNil(SentinelURLRouter.validateAbsolutePath(nil))
        XCTAssertNil(SentinelURLRouter.validateAbsolutePath(""))
    }

    func test_validate_合法绝对路径_返回标准化形态() throws {
        let tmp = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = SentinelURLRouter.validateAbsolutePath(tmp.path)
        XCTAssertEqual(result, (tmp.path as NSString).standardizingPath)
    }

    func test_validate_含dotdot_返回nil() {
        XCTAssertNil(SentinelURLRouter.validateAbsolutePath("/Applications/../etc"))
    }

    func test_validate_相对路径_返回nil() {
        XCTAssertNil(SentinelURLRouter.validateAbsolutePath("Applications/Foo"))
    }

    // MARK: - 常量契约

    func test_scheme常量与Info_plist一致() {
        XCTAssertEqual(SentinelURLRouter.scheme, "amuxaiclean",
                       "URL Scheme 必须与 App/Info.plist CFBundleURLSchemes 一致")
    }

    func test_uninstallPathKey常量() {
        XCTAssertEqual(SentinelURLRouter.uninstallPathKey, "path")
    }

    // MARK: - Helpers

    private func makeTempFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gsy-sentinel-router-test-\(UUID().uuidString).bin")
        try Data("ok".utf8).write(to: url)
        return url
    }
}
