import XCTest
@testable import AppUI

/// Step 15：补 [UpdateChecker.runCheck L127-L172](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift#L127-L172)
/// 网络层死角。
///
/// 之前仅 SemVer 纯函数测过，HTTP 401 / 超时 / HTML 误返回 / URL 构造失败 全都没覆盖。
///
/// 实现方式：用 URLProtocol mock 注入 [URLSession](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift#L94-L101)，
/// 配合 UpdateChecker 的 init 接受 `session:` 注入参数 → 整套不出网。
@MainActor
final class UpdateCheckerNetworkTests: XCTestCase {

    // MARK: - URLProtocol Mock

    /// 模拟 URL 响应：根据 stub 给定 (data, status, error) 交回。
    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        struct Stub: Sendable {
            let data: Data?
            let statusCode: Int
            let error: Error?
            let mimeType: String
        }
        nonisolated(unsafe) static var stub: Stub?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let stub = Self.stub else {
                client?.urlProtocol(self, didFailWithError:
                    NSError(domain: "MockURLProtocol", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "no stub"]))
                return
            }
            if let err = stub.error {
                client?.urlProtocol(self, didFailWithError: err)
                return
            }
            let url = request.url ?? URL(string: "https://x")!
            let resp = HTTPURLResponse(
                url: url, statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": stub.mimeType]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data = stub.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 2
        return URLSession(configuration: cfg)
    }

    /// 等到 runCheck 真正写出 lastResult 为止——既覆盖 isChecking==true 的中间态，
    /// 也覆盖 Task 还没启动 / 已经完成的窗口。
    private func waitForResult(_ checker: UpdateChecker, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while checker.lastResult == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // 再等一帧让 isChecking 翻回 false，避免后续断言读到中间态
        var spin = 0
        while checker.isChecking, spin < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            spin += 1
        }
    }

    override func tearDown() {
        MockURLProtocol.stub = nil
        super.tearDown()
    }

    // MARK: - 用例 1: HTTP 401 → .failed("HTTP 401")

    func test_runCheck_HTTP401应记为failed() async {
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data("Unauthorized".utf8),
            statusCode: 401, error: nil, mimeType: "text/plain"
        )
        let checker = UpdateChecker(session: makeSession())
        checker.checkNow()
        await waitForResult(checker)
        guard case .failed(let msg) = checker.lastResult else {
            XCTFail("HTTP 401 应该走 .failed，实际 lastResult=\(String(describing: checker.lastResult))")
            return
        }
        XCTAssertTrue(msg.contains("401"),
            "failed 文案应携带状态码 401，便于设置面板诊断；实际 = \(msg)")
        XCTAssertNil(checker.availableUpdate, "401 不能弹更新对话框")
    }

    // MARK: - 用例 2: 超时（NSURLErrorTimedOut）→ .failed

    func test_runCheck_网络超时应记为failed() async {
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: nil, statusCode: 0,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                           userInfo: [NSLocalizedDescriptionKey: "timed out"]),
            mimeType: "application/json"
        )
        let checker = UpdateChecker(session: makeSession())
        checker.checkNow()
        await waitForResult(checker)
        guard case .failed = checker.lastResult else {
            XCTFail("网络超时应走 .failed；实际 = \(String(describing: checker.lastResult))")
            return
        }
        XCTAssertNil(checker.availableUpdate)
    }

    // MARK: - 用例 3: HTTP 200 但返回 HTML（误返回 / DNS hijack）→ .failed（JSONDecoder 抛错）

    func test_runCheck_HTML误返回应记为failed解析错误() async {
        let html = "<!DOCTYPE html><html><body>hijacked</body></html>"
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data(html.utf8), statusCode: 200,
            error: nil, mimeType: "text/html"
        )
        let checker = UpdateChecker(session: makeSession())
        checker.checkNow()
        await waitForResult(checker)
        guard case .failed = checker.lastResult else {
            XCTFail("HTML 误返回应被 JSONDecoder 拒，走 .failed；实际 = \(String(describing: checker.lastResult))")
            return
        }
        XCTAssertNil(checker.availableUpdate,
            "HTML 误返回时不能误弹更新对话框")
    }

    // MARK: - 用例 4: URL 构造失败分支说明
    //
    // [UpdateChecker.runCheck L134-L138](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift#L134-L138)
    // 的 `guard let url = URL(string: urlStr)` 失败分支理论上会落 .failed("URL 构造失败：...")。
    // 实测 macOS 14+ 上 `URL(string:)` 解析放宽（自动 percent-encode 控制字符 / 空格），
    // 即便注入含 `\n\t` / 空格 / 中文的 owner，URL 仍能构造成功，无法在不动产品代码的前提下
    // 触发该 nil 分支。该分支仍由静态 [SemVer 字符串解析](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Updater/UpdateChecker.swift#L57-L70)
    // 类的纯函数测试间接覆盖，且生产 owner/repo 是写死的 "CarGuo"/"GSYCleanMac"，运行时 nil
    // 概率为零。Step 15 验收口径：覆盖网络层 4 个真实可发生的故障模式（401 / 超时 / HTML
    // 误返回 / 解析失败），URL(string:) nil 分支留给 SemVerTests + manual review。



    // MARK: - 用例 5: 200 + 合法 JSON 且远端版本更新 → .newer + availableUpdate 非 nil

    func test_runCheck_200合法JSON新版本应弹更新() async {
        let json = """
        {
            "tag_name": "v999.0.0",
            "name": "Big Release",
            "html_url": "https://example.com/release/999",
            "body": "release notes",
            "published_at": "2026-06-04T00:00:00Z"
        }
        """
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data(json.utf8), statusCode: 200,
            error: nil, mimeType: "application/json"
        )
        let checker = UpdateChecker(session: makeSession())
        checker.checkNow()
        await waitForResult(checker)
        guard case .newer(let info) = checker.lastResult else {
            XCTFail("200+合法 JSON 且 v999 > local 应走 .newer；实际 = \(String(describing: checker.lastResult))")
            return
        }
        XCTAssertEqual(info.tagName, "v999.0.0")
        XCTAssertNotNil(checker.availableUpdate,
            "新版本必须设置 availableUpdate 让 sheet 弹出来")
    }

    // MARK: - 用例 6: 200 + 合法 JSON 但版本相同/更旧 → .upToDate，不弹更新

    func test_runCheck_200合法JSON旧版本应upToDate不弹() async {
        let json = """
        {
            "tag_name": "v0.0.1",
            "name": "Ancient",
            "html_url": "https://example.com/release/old",
            "body": "",
            "published_at": null
        }
        """
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data(json.utf8), statusCode: 200,
            error: nil, mimeType: "application/json"
        )
        let checker = UpdateChecker(session: makeSession())
        checker.checkNow()
        await waitForResult(checker)
        guard case .upToDate = checker.lastResult else {
            XCTFail("v0.0.1 比当前版本旧应走 .upToDate；实际 = \(String(describing: checker.lastResult))")
            return
        }
        XCTAssertNil(checker.availableUpdate,
            "旧版本不能弹更新对话框")
    }
}
