import XCTest
@testable import AppUI

/// Step 15：补 `UpdateChecker.runCheck` 网络层死角。
///
/// 之前仅 SemVer 纯函数测过，HTTP 401 / 超时 / HTML 误返回 / URL 构造失败 全都没覆盖。
///
/// 实现方式：用 URLProtocol mock 只替换 session 的 protocol class，
/// UpdateChecker 仍由生产工厂统一创建 ephemeral/redirect-deny session，整套不出网。
/// v2026.07.18：禁止恢复 public URLSession 注入，否则生产调用方可绕过来源策略。
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
        nonisolated(unsafe) static var responseURLOverride: URL?
        private static let requestCountLock = NSLock()
        nonisolated(unsafe) static var requestCountStorage = 0
        nonisolated(unsafe) static var lastRequestStorage: URLRequest?

        static func resetRequestCount() {
            requestCountLock.lock()
            requestCountStorage = 0
            lastRequestStorage = nil
            requestCountLock.unlock()
        }

        static func requestCount() -> Int {
            requestCountLock.lock()
            defer { requestCountLock.unlock() }
            return requestCountStorage
        }

        static func lastRequest() -> URLRequest? {
            requestCountLock.lock()
            defer { requestCountLock.unlock() }
            return lastRequestStorage
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requestCountLock.lock()
            Self.requestCountStorage += 1
            Self.lastRequestStorage = request
            Self.requestCountLock.unlock()
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
            let url = Self.responseURLOverride ?? request.url ?? URL(string: "https://x")!
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

    private func makeChecker(
        owner: String = "CarGuo",
        repo: String = "AmuxAIClean",
        settings: AppSettings? = nil
    ) -> UpdateChecker {
        UpdateChecker(
            owner: owner,
            repo: repo,
            protocolClasses: [MockURLProtocol.self],
            settings: settings
        )
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
        MockURLProtocol.responseURLOverride = nil
        MockURLProtocol.resetRequestCount()
        super.tearDown()
    }

    // v2026.10.14: production defaults must target the public distribution repository.
    // Explicit repository injection in the other tests cannot detect a private-source default.
    func test_defaultRepositoryUsesPublicDistributionForRequestAndReleaseValidation() async {
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data("""
                {
                  "tag_name": "v999.0.0",
                  "name": "AmuxAIClean 999.0.0",
                  "html_url": "https://github.com/CarGuo/AmuxAICleanRelease/releases/tag/v999.0.0",
                  "body": "release notes",
                  "published_at": null,
                  "assets": [{
                    "name": "AmuxAIClean-999.0.0.dmg",
                    "browser_download_url": "https://github.com/CarGuo/AmuxAICleanRelease/releases/download/v999.0.0/AmuxAIClean-999.0.0.dmg",
                    "size": 1024
                  }]
                }
                """.utf8),
            statusCode: 200, error: nil, mimeType: "application/json"
        )
        let checker = UpdateChecker(protocolClasses: [MockURLProtocol.self])
        checker.checkNow()
        await waitForResult(checker)

        XCTAssertEqual(
            MockURLProtocol.lastRequest()?.url?.absoluteString,
            "https://api.github.com/repos/CarGuo/AmuxAICleanRelease/releases/latest"
        )
        guard case .newer(let release) = checker.lastResult else {
            XCTFail("Production defaults must accept releases from the public distribution repository")
            return
        }
        XCTAssertEqual(release.assets.map(\.name), ["AmuxAIClean-999.0.0.dmg"])
        XCTAssertEqual(checker.availableUpdate, release)
    }

    // MARK: - 用例 1: HTTP 401 → .failed("HTTP 401")

    func test_runCheck_HTTP401应记为failed() async {
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data("Unauthorized".utf8),
            statusCode: 401, error: nil, mimeType: "text/plain"
        )
        let checker = makeChecker()
        checker.checkNow()
        await waitForResult(checker)
        guard case .failed(let failure) = checker.lastResult else {
            XCTFail("HTTP 401 应该走 .failed，实际 lastResult=\(String(describing: checker.lastResult))")
            return
        }
        let msg = failure.message(locale: Locale(identifier: "en"))
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
        let checker = makeChecker()
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
        let checker = makeChecker()
        checker.checkNow()
        await waitForResult(checker)
        guard case .failed = checker.lastResult else {
            XCTFail("HTML 误返回应被 JSONDecoder 拒，走 .failed；实际 = \(String(describing: checker.lastResult))")
            return
        }
        XCTAssertNil(checker.availableUpdate,
            "HTML 误返回时不能误弹更新对话框")
    }

    // v2026.07.18：不再依赖宽松的 `URL(string:)` 是否返回 nil。owner/repo
    // 先按 ASCII GitHub path component 合同验证，非法路由必须在请求计数为 0 时
    // 类型化失败，对应用例见本文件后半部。

    // MARK: - 用例 5: 200 + 合法 JSON 且远端版本更新 → .newer + availableUpdate 非 nil

    func test_runCheck_200合法JSON新版本应弹更新() async {
        let json = """
        {
            "tag_name": "v999.0.0",
            "name": "Big Release",
            "html_url": "https://github.com/CarGuo/AmuxAIClean/releases/tag/v999.0.0",
            "body": "release notes",
            "published_at": "2026-06-04T00:00:00Z"
        }
        """
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data(json.utf8), statusCode: 200,
            error: nil, mimeType: "application/json"
        )
        let checker = makeChecker()
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
            "html_url": "https://github.com/CarGuo/AmuxAIClean/releases/tag/v0.0.1",
            "body": "",
            "published_at": null
        }
        """
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data(json.utf8), statusCode: 200,
            error: nil, mimeType: "application/json"
        )
        let checker = makeChecker()
        checker.checkNow()
        await waitForResult(checker)
        guard case .upToDate = checker.lastResult else {
            XCTFail("v0.0.1 比当前版本旧应走 .upToDate；实际 = \(String(describing: checker.lastResult))")
            return
        }
        XCTAssertNil(checker.availableUpdate,
            "旧版本不能弹更新对话框")
    }

    /// v2026.07.18：WindowGroup 关闭后重建会重新执行 `.task`。同一
    /// UpdateChecker 实例的自动检查必须保持每进程最多一次。
    func test_checkOnLaunch_同一进程重建窗口不重复请求() async {
        let suite = "UpdateCheckerNetworkTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(testSuite: suite)
        settings.updateCheckEnabled = true
        MockURLProtocol.resetRequestCount()
        MockURLProtocol.stub = MockURLProtocol.Stub(
            data: Data("""
                {
                  "tag_name": "v0.0.1",
                  "name": "Old",
                  "html_url": "https://github.com/CarGuo/AmuxAIClean/releases/tag/v0.0.1",
                  "body": "",
                  "published_at": null
                }
                """.utf8),
            statusCode: 200,
            error: nil,
            mimeType: "application/json"
        )
        let checker = makeChecker(settings: settings)

        checker.checkOnLaunch()
        checker.checkOnLaunch()
        await waitForResult(checker)

        XCTAssertEqual(MockURLProtocol.requestCount(), 1)
    }

    // MARK: - v2026.07.18 来源与重定向合同

    func test_sessionConfiguration_禁CookieCacheCredential并复用生产策略() {
        let configuration = UpdateSessionFactory.configuration(
            protocolClasses: [MockURLProtocol.self]
        )

        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(
            configuration.protocolClasses?.first.map(ObjectIdentifier.init),
            ObjectIdentifier(MockURLProtocol.self)
        )
    }

    func test_APIRequest_只向固定仓库GET且不携凭据Cookie或Body() async {
        MockURLProtocol.stub = validOldReleaseStub()
        let checker = makeChecker()

        checker.checkNow()
        await waitForResult(checker)

        let request = MockURLProtocol.lastRequest()
        XCTAssertEqual(
            request?.url?.absoluteString,
            "https://api.github.com/repos/CarGuo/AmuxAIClean/releases/latest"
        )
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertNil(request?.httpBody)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func test_redirectPolicy_同源与跨源都拒绝() {
        let requests = [
            URLRequest(url: URL(string: "https://api.github.com/repos/CarGuo/AmuxAIClean/releases/1")!),
            URLRequest(url: URL(string: "https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.0.0")!),
            URLRequest(url: URL(string: "https://objects.example.invalid/asset")!),
        ]

        for request in requests {
            XCTAssertNil(UpdateRedirectPolicy.requestAfterRedirect(request))
        }
    }

    func test_repositoryBoundary_仅接受精确HTTPSReleasePage() {
        let boundary = UpdateRepositoryNetworkBoundary(owner: "CarGuo", repo: "AmuxAIClean")!
        XCTAssertTrue(boundary.ownsReleasePageURL(
            URL(string: "https://github.com/carguo/amuxaiclean/releases/tag/v1.6.1")!,
            tag: "v1.6.1"
        ))

        let rejected = [
            "http://github.com/CarGuo/AmuxAIClean/releases/tag/v1.6.1",
            "https://github.com.evil.invalid/CarGuo/AmuxAIClean/releases/tag/v1.6.1",
            "https://github.com@evil.invalid/CarGuo/AmuxAIClean/releases/tag/v1.6.1",
            "https://github.com:444/CarGuo/AmuxAIClean/releases/tag/v1.6.1",
            "https://github.com/CarGuo2/AmuxAIClean/releases/tag/v1.6.1",
            "https://github.com/CarGuo/AmuxAIClean2/releases/tag/v1.6.1",
            "https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.6.2",
            "https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.6.1/extra",
            "https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.6.1?next=evil",
            "https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.6.1#fragment",
            "https://github.com/CarGuo/AmuxAIClean/releases/tag/v1.6.1%2Fevil",
        ]
        for raw in rejected {
            XCTAssertFalse(
                boundary.ownsReleasePageURL(URL(string: raw)!, tag: "v1.6.1"),
                "应拒绝 \(raw)"
            )
        }
    }

    func test_repositoryBoundary_仅接受同仓库同Tag同文件名Asset() {
        let boundary = UpdateRepositoryNetworkBoundary(owner: "CarGuo", repo: "AmuxAIClean")!
        XCTAssertTrue(boundary.ownsReleaseAssetURL(
            URL(string: "https://github.com/CarGuo/AmuxAIClean/releases/download/v1.6.1/AmuxAIClean.dmg.sha256")!,
            tag: "v1.6.1",
            assetName: "AmuxAIClean.dmg.sha256"
        ))

        let rejected = [
            "http://github.com/CarGuo/AmuxAIClean/releases/download/v1.6.1/AmuxAIClean.dmg.sha256",
            "https://objects.githubusercontent.com/CarGuo/AmuxAIClean/AmuxAIClean.dmg.sha256",
            "https://github.com/Other/AmuxAIClean/releases/download/v1.6.1/AmuxAIClean.dmg.sha256",
            "https://github.com/CarGuo/Other/releases/download/v1.6.1/AmuxAIClean.dmg.sha256",
            "https://github.com/CarGuo/AmuxAIClean/releases/download/v1.6.2/AmuxAIClean.dmg.sha256",
            "https://github.com/CarGuo/AmuxAIClean/releases/download/v1.6.1/other.sha256",
            "https://github.com/CarGuo/AmuxAIClean/releases/download/v1.6.1/AmuxAIClean.dmg.sha256?token=x",
            "https://github.com/CarGuo/AmuxAIClean/releases/download/v1.6.1/AmuxAIClean.dmg.sha256/extra",
        ]
        for raw in rejected {
            XCTAssertFalse(
                boundary.ownsReleaseAssetURL(
                    URL(string: raw)!,
                    tag: "v1.6.1",
                    assetName: "AmuxAIClean.dmg.sha256"
                ),
                "应拒绝 \(raw)"
            )
        }
    }

    func test_runCheck_releasePage跨源应类型化拒绝() async {
        MockURLProtocol.stub = releaseStub(
            htmlURL: "https://example.com/CarGuo/AmuxAIClean/releases/tag/v999.0.0"
        )
        let checker = makeChecker()

        checker.checkNow()
        await waitForResult(checker)

        guard case .failed(.untrustedResponseSource) = checker.lastResult else {
            return XCTFail("跨源 Release page 应被类型化拒绝")
        }
        XCTAssertNil(checker.availableUpdate)
    }

    func test_runCheck_checksumAsset跨仓库应拒绝整个Release() async {
        MockURLProtocol.stub = releaseStub(
            assetsJSON: """
            [{
              "name": "AmuxAIClean.dmg.sha256",
              "browser_download_url": "https://github.com/Other/Repo/releases/download/v999.0.0/AmuxAIClean.dmg.sha256",
              "size": 128
            }]
            """
        )
        let checker = makeChecker()

        checker.checkNow()
        await waitForResult(checker)

        guard case .failed(.untrustedResponseSource) = checker.lastResult else {
            return XCTFail("跨仓库 checksum asset 应拒绝整个 Release")
        }
        XCTAssertNil(checker.availableUpdate)
    }

    func test_runCheck_最终响应URL偏离固定API应拒绝() async {
        MockURLProtocol.stub = validOldReleaseStub()
        MockURLProtocol.responseURLOverride = URL(string: "https://example.com/releases/latest")!
        let checker = makeChecker()

        checker.checkNow()
        await waitForResult(checker)

        guard case .failed(.untrustedResponseSource) = checker.lastResult else {
            return XCTFail("最终响应 URL 偏离固定 API 应被拒绝")
        }
    }

    func test_runCheck_非法仓库路由在发请求前拒绝() async {
        MockURLProtocol.stub = validOldReleaseStub()
        let checker = makeChecker(owner: "CarGuo/Other")

        checker.checkNow()
        await waitForResult(checker)

        guard case .failed(.invalidRequestURL) = checker.lastResult else {
            return XCTFail("非法 owner 应在 URL 构造边界被拒绝")
        }
        XCTAssertEqual(MockURLProtocol.requestCount(), 0)
    }

    func test_validReleaseAsset_仅解析元数据不发起第二请求() async {
        MockURLProtocol.stub = releaseStub(
            assetsJSON: """
            [{
              "name": "AmuxAIClean.dmg.sha256",
              "browser_download_url": "https://github.com/CarGuo/AmuxAIClean/releases/download/v999.0.0/AmuxAIClean.dmg.sha256",
              "size": 128
            }]
            """
        )
        let checker = makeChecker()

        checker.checkNow()
        await waitForResult(checker)

        guard case .newer(let release) = checker.lastResult else {
            return XCTFail("合法 Release 应解析成新版本")
        }
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(MockURLProtocol.requestCount(), 1)
        XCTAssertEqual(
            UpdateChecker.automaticChecksumFetchPolicy,
            .disabledBecauseRedirectDestinationIsUnverifiable
        )
    }

    private func validOldReleaseStub() -> MockURLProtocol.Stub {
        releaseStub(tag: "v0.0.1")
    }

    private func releaseStub(
        tag: String = "v999.0.0",
        htmlURL: String? = nil,
        assetsJSON: String = "[]"
    ) -> MockURLProtocol.Stub {
        let releaseURL = htmlURL
            ?? "https://github.com/CarGuo/AmuxAIClean/releases/tag/\(tag)"
        return MockURLProtocol.Stub(
            data: Data("""
                {
                  "tag_name": "\(tag)",
                  "name": "Release \(tag)",
                  "html_url": "\(releaseURL)",
                  "body": "",
                  "published_at": null,
                  "assets": \(assetsJSON)
                }
                """.utf8),
            statusCode: 200,
            error: nil,
            mimeType: "application/json"
        )
    }
}
