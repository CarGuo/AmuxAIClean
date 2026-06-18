import XCTest
import SafetyKit
@testable import AIKit

/// M5 / 2026-06：OpenAIChatClient 单元测试。
/// 用 URLProtocol 桩拦截所有 HTTP 请求，**不打真接口**——也不依赖网络。
final class OpenAIChatClientTests: XCTestCase {

    // MARK: - URL 构造

    func test_endpoint_url_appends_v1_chat() throws {
        let u1 = try OpenAIChatClient.endpointURL(baseURL: "https://api.openai.com")
        XCTAssertEqual(u1.absoluteString, "https://api.openai.com/v1/chat/completions")
        let u2 = try OpenAIChatClient.endpointURL(baseURL: "https://api.openai.com/")
        XCTAssertEqual(u2.absoluteString, "https://api.openai.com/v1/chat/completions")
        let u3 = try OpenAIChatClient.endpointURL(baseURL: "http://localhost:11434/v1")
        XCTAssertEqual(u3.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    /// Review fix-soon #7，2026-06-15：scheme 白名单——明文 http:// 远端被拒。
    /// 防 `Authorization: Bearer <key>` 走明文链路。
    func test_endpoint_url_拒绝明文http远端() {
        for bad in [
            "http://api.openai.com",
            "http://example.com:8080/v1",
            "http://192.168.1.10:11434"
        ] {
            do {
                _ = try OpenAIChatClient.endpointURL(baseURL: bad)
                XCTFail("baseURL=\(bad) 必须被拒")
            } catch OpenAIChatClient.Error.insecureBaseURL(let scheme, _) {
                XCTAssertEqual(scheme, "http", "应识别成 http scheme")
            } catch {
                XCTFail("意外错误类型: \(error) (bad=\(bad))")
            }
        }
    }

    /// 但 http://localhost 例外——支持本地 Ollama / vLLM / LM Studio。
    func test_endpoint_url_放行本机环回() throws {
        for ok in [
            "http://localhost:11434",
            "http://127.0.0.1:8000/v1",
            "http://[::1]:9999"
        ] {
            XCTAssertNoThrow(try OpenAIChatClient.endpointURL(baseURL: ok),
                             "本机环回 \(ok) 必须放行")
        }
    }

    /// 非 http/https scheme 一律拒绝。`javascript:` / `file:` / `ftp:` 等。
    func test_endpoint_url_拒绝非http_scheme() {
        for bad in ["ftp://api.openai.com", "file:///tmp/x"] {
            do {
                _ = try OpenAIChatClient.endpointURL(baseURL: bad)
                XCTFail("scheme=\(bad) 必须被拒")
            } catch OpenAIChatClient.Error.insecureBaseURL {
                // ok
            } catch OpenAIChatClient.Error.invalidBaseURL {
                // 也接受——这些 scheme 可能在 URL parse 阶段就被 reject
            } catch {
                XCTFail("意外: \(error)")
            }
        }
    }

    func test_strip_code_fence() {
        XCTAssertEqual(OpenAIChatClient.stripCodeFence("```json\n{\"a\":1}\n```"),
                       "{\"a\":1}")
        XCTAssertEqual(OpenAIChatClient.stripCodeFence("```\n{\"a\":1}\n```"),
                       "{\"a\":1}")
        XCTAssertEqual(OpenAIChatClient.stripCodeFence("{\"a\":1}"), "{\"a\":1}")
    }

    // MARK: - 端到端（URLProtocol 桩）

    func test_ask_happy_path_decodes_advice_and_clamps() async throws {
        let payload = """
        {
          "id": "x", "object": "chat.completion", "created": 0, "model": "m",
          "choices": [{
            "index": 0,
            "message": {
              "role": "assistant",
              "content": "{\\"summary\\":\\"测试摘要\\",\\"canDelete\\":\\"safe\\",\\"reason\\":\\"测试原因\\",\\"sideEffects\\":[\\"下次启动重建\\"]}"
            },
            "finish_reason": "stop"
          }]
        }
        """
        StubURLProtocol.nextResponse = .success(
            status: 200,
            data: payload.data(using: .utf8)!
        )

        let client = makeClient()
        let inquiry = makeInquiry(verdict: .safe)
        let advice = try await client.ask(inquiry)
        XCTAssertEqual(advice.summary, "测试摘要")
        XCTAssertEqual(advice.canDelete, .safe)
        XCTAssertEqual(advice.sideEffects, ["下次启动重建"])
    }

    func test_ask_local_forbid_clamps_ai_safe_to_forbid() async throws {
        let payload = """
        {"choices":[{"message":{"role":"assistant","content":"{\\"summary\\":\\"看似安全\\",\\"canDelete\\":\\"safe\\",\\"reason\\":\\"AI 主观\\",\\"sideEffects\\":[]}"}}]}
        """
        StubURLProtocol.nextResponse = .success(status: 200, data: payload.data(using: .utf8)!)
        let client = makeClient()
        let inquiry = makeInquiry(verdict: .forbid)
        let advice = try await client.ask(inquiry)
        XCTAssertEqual(advice.canDelete, .forbid, "本地 forbid 必须强制覆盖")
        XCTAssertTrue(advice.reason.contains("[本地安全策略已拒绝]"))
    }

    func test_ask_http_error_surfaces() async {
        StubURLProtocol.nextResponse = .success(status: 401, data: Data("unauthorized".utf8))
        let client = makeClient()
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("应抛 http error")
        } catch let OpenAIChatClient.Error.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("unauthorized"))
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
    }

    /// **v2026.06.22 (P0-4)**：4xx/5xx body 中如果服务端 echo 了用户绝对路径
    /// （`/Users/<name>/...`），抛给 UI 之前必须先经 [PathRedactor](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/PathRedactor.swift)
    /// 去敏；否则 UI 直接展示就把用户名泄漏到错误弹窗 / 截图 / 日志里。
    func test_ask_http_error_body_经过PathRedactor去敏() async {
        let leaky = #"{"error":{"message":"path /Users/guoshuyu/Library/Caches/x not allowed"}}"#
        StubURLProtocol.nextResponse = .success(status: 400, data: Data(leaky.utf8))
        let client = makeClient()
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("应抛 http error")
        } catch let OpenAIChatClient.Error.http(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertFalse(body.contains("guoshuyu"),
                           "Error.http body 必须先经 PathRedactor 去敏，不允许泄漏用户名，实际:\n\(body)")
            XCTAssertTrue(body.contains("<USER>"),
                          "PathRedactor 应把 /Users/<name>/ 替换为 /Users/<USER>/，实际:\n\(body)")
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
    }

    /// **v2026.06.22 (P0-4)**：屏蔽 `Mirror(reflecting:)` / `String(describing:)`
    /// 顺手把 apiKey dump 到日志/崩溃报告里。`customMirror` 与 `debugDescription`
    /// 都必须把 apiKey 字段写为 `<redacted>`，且 apiKeyProvider 闭包不在 Mirror children 里。
    func test_apiKey_对Mirror与debugDescription不可见() {
        let client = OpenAIChatClient(
            settings: OpenAIChatClient.SettingsSnapshot(
                baseURL: "https://api.openai.com",
                model: "gpt-4o-mini", temperature: 0.2, redactPaths: true),
            apiKey: "sk-supersecret-DEADBEEF",
            session: stubSession()
        )
        // 1. debugDescription
        let desc = String(reflecting: client)
        XCTAssertFalse(desc.contains("sk-supersecret"),
                       "String(reflecting:) 不允许暴露 apiKey，实际:\n\(desc)")
        XCTAssertTrue(desc.contains("<redacted>"))
        // 2. Mirror
        let mirror = Mirror(reflecting: client)
        for child in mirror.children {
            let dumped = "\(child.value)"
            XCTAssertFalse(dumped.contains("sk-supersecret"),
                           "Mirror child \(child.label ?? "?") 泄漏 apiKey: \(dumped)")
        }
    }

    /// **v2026.06.22 (P0-4)**：apiKeyProvider 按需闭包入口——构造 client 时
    /// 闭包不应立即执行；只在 `ask()` 内才被调用。便于上层把 Keychain 读取放进闭包。
    func test_apiKeyProvider_按需调用_懒拉取() async {
        // 用 final class box 做 mutable counter——闭包 @Sendable 不能 capture var
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value: Int = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
        }
        let counter = Counter()
        let client = OpenAIChatClient(
            settings: OpenAIChatClient.SettingsSnapshot(
                baseURL: "https://api.openai.com",
                model: "gpt-4o-mini", temperature: 0.2, redactPaths: true),
            apiKeyProvider: { counter.bump(); return "" },
            session: stubSession()
        )
        XCTAssertEqual(counter.value, 0, "构造时不应触发 apiKeyProvider")
        // ask 内会取 key，取到空字符串 → 抛 missingAPIKey
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail()
        } catch OpenAIChatClient.Error.missingAPIKey {
            XCTAssertEqual(counter.value, 1, "ask() 调用一次 apiKeyProvider")
        } catch {
            XCTFail("意外: \(error)")
        }
    }

    func test_ask_missing_api_key_throws_immediately() async {
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: "https://api.openai.com",
            model: "gpt-4o-mini",
            temperature: 0.2,
            redactPaths: true
        )
        let client = OpenAIChatClient(settings: snapshot, apiKey: "", session: stubSession())
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail()
        } catch OpenAIChatClient.Error.missingAPIKey {
            // ok
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_ask_local_loopback_allows_empty_api_key_without_authorization_header() async throws {
        StubURLProtocol.observedRequests = []
        StubURLProtocol.observedBodies = []
        let payload = """
        {"choices":[{"message":{"role":"assistant","content":"{\\"summary\\":\\"local\\",\\"canDelete\\":\\"confirm\\",\\"reason\\":\\"r\\",\\"sideEffects\\":[]}"}}]}
        """
        StubURLProtocol.nextResponse = .success(status: 200, data: payload.data(using: .utf8)!)
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: "http://localhost:11434",
            model: "llama-local",
            temperature: 0.2,
            redactPaths: true
        )
        let client = OpenAIChatClient(settings: snapshot, apiKey: "", session: stubSession())
        let advice = try await client.ask(makeInquiry())
        XCTAssertEqual(advice.summary, "local")
        let req = try XCTUnwrap(StubURLProtocol.observedRequests.first)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                     "本地 loopback 端点空 key 时不应发送 Authorization header")
    }

    func test_request_uses_bearer_and_redacts_path() async throws {
        StubURLProtocol.observedRequests = []
        let payload = """
        {"choices":[{"message":{"role":"assistant","content":"{\\"summary\\":\\"s\\",\\"canDelete\\":\\"confirm\\",\\"reason\\":\\"r\\",\\"sideEffects\\":[]}"}}]}
        """
        StubURLProtocol.nextResponse = .success(status: 200, data: payload.data(using: .utf8)!)
        let client = makeClient(apiKey: "sk-test-123")
        _ = try await client.ask(makeInquiry(path: "/Users/guoshuyu/Library/Caches/x"))
        let req = try XCTUnwrap(StubURLProtocol.observedRequests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
        let bodyData = try XCTUnwrap(StubURLProtocol.observedBodies.first)
        let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains("guoshuyu"), "出网 body 必须去敏掉用户名，实际:\n\(bodyText)")
        XCTAssertTrue(bodyText.contains("<USER>"))
    }

    // MARK: - Review fix-soon #6：cancellation 通道

    /// 上层 Task 被 cancel → ask 必须立刻抛 `CancellationError`，
    /// 而不是继续等 30s timeout。
    func test_ask_cancellation_propagates_to_urlSessionTask() async {
        // 用永不响应的 stub：startLoading 后挂起，由 dataTask.cancel() 主动断开。
        StubURLProtocol.nextResponse = .hang
        let client = makeClient()
        let inquiry = makeInquiry()
        let task = Task { try await client.ask(inquiry) }
        // 给 Task 一点点时间真正发起请求
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancel 后应抛 CancellationError")
        } catch is CancellationError {
            // ok
        } catch {
            XCTFail("应抛 CancellationError，实际: \(error)")
        }
    }

    // MARK: - Review fix-soon：transport 错误路径

    /// URLSession 抛 transport 错误（如断网）→ 必须翻译为 OpenAIChatClient.Error.transport，
    /// 不允许向上泄漏裸 URLError。
    func test_ask_transport_error_翻译为Error_transport() async {
        StubURLProtocol.nextResponse = .transport(URLError(.notConnectedToInternet))
        let client = makeClient()
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("应抛 transport error")
        } catch OpenAIChatClient.Error.transport(let desc) {
            // 描述里能看到 notConnectedToInternet 关键字即可——细节由 URLError 决定
            XCTAssertTrue(desc.contains("notConnectedToInternet") || desc.contains("-1009"),
                          "transport desc 应包含底层错误标识，实际: \(desc)")
        } catch {
            XCTFail("意外: \(error)")
        }
    }

    // MARK: - 测试夹具

    private func makeInquiry(path: String = "/Users/guoshuyu/Library/Caches/x",
                             verdict: SafetyVerdict = .safe) -> PathInquiry {
        PathInquiry(path: path, isDirectory: true, bytes: 1, fileCount: 1,
                    modificationDate: nil, verdict: verdict,
                    vendorName: nil, vendorNote: nil, childPreview: [])
    }

    private func makeClient(apiKey: String = "sk-test") -> OpenAIChatClient {
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: "https://api.openai.com",
            model: "gpt-4o-mini",
            temperature: 0.2,
            redactPaths: true
        )
        return OpenAIChatClient(settings: snapshot, apiKey: apiKey, session: stubSession())
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// MARK: - StubURLProtocol

/// 测试用 URLProtocol：拦截所有请求，按 nextResponse 返回。
/// 同时把 observed request / body 落到静态数组，给断言用。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    enum Stub {
        case success(status: Int, data: Data)
        case transport(Error)
        /// **Review fix-soon #6 测试支持**：startLoading 后什么也不发，永不完成。
        /// 用于验证上层 cancel 能真正打断飞行中的 dataTask。
        case hang
    }

    nonisolated(unsafe) static var nextResponse: Stub = .success(status: 200, data: Data())
    nonisolated(unsafe) static var observedRequests: [URLRequest] = []
    nonisolated(unsafe) static var observedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.observedRequests.append(request)
        if let body = request.httpBody {
            Self.observedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            Self.observedBodies.append(data)
        }

        switch Self.nextResponse {
        case let .success(status, data):
            let resp = HTTPURLResponse(url: request.url!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .transport(err):
            client?.urlProtocol(self, didFailWithError: err)
        case .hang:
            // 故意什么也不做——由调用方 cancel() 触发 stopLoading()。
            break
        }
    }

    override func stopLoading() {
        // hang 模式下，URLSession 会在 dataTask.cancel() 时调 stopLoading；
        // 此时主动以 URLError.cancelled 完成，触发 OpenAIChatClient 的
        // CancellationError 翻译路径。
        if case .hang = Self.nextResponse {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }
}
