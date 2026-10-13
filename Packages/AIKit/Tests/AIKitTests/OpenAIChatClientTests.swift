import CoreServices
import os
import XCTest
import SafetyKit
@testable import AIKit

/// M5 / 2026-06：OpenAIChatClient 单元测试。
/// 用 URLProtocol 桩拦截所有 HTTP 请求，**不打真接口**——也不依赖网络。
final class OpenAIChatClientTests: XCTestCase {

    // MARK: - URL 构造

    /// v2026.07.18 privacy regression: the production default must not silently inherit
    /// URLSession.shared's disk cache, shared cookies or credential storage.
    func test_publicInitializers_useIsolatedRedirectRejectingSession() throws {
        let settings = OpenAIChatClient.SettingsSnapshot(
            baseURL: "https://api.openai.com",
            model: "gpt-4o-mini",
            temperature: 0.2,
            redactPaths: true
        )
        let clients: [OpenAIChatClient] = [
            OpenAIChatClient(settings: settings, apiKey: "sk-test"),
            OpenAIChatClient(settings: settings, apiKeyProvider: { "sk-test" }),
            OpenAIChatClient(settings: settings, asyncAPIKeyProvider: { "sk-test" }),
        ]

        for client in clients {
            let session = try XCTUnwrap(
                Mirror(reflecting: client).children.first(where: { $0.label == "session" })?.value
                    as? URLSession
            )
            defer { session.invalidateAndCancel() }
            let configuration = session.configuration

            XCTAssertNil(configuration.identifier)
            XCTAssertNil(configuration.urlCache)
            XCTAssertNil(configuration.httpCookieStorage)
            XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
            XCTAssertFalse(configuration.httpShouldSetCookies)
            XCTAssertNil(configuration.urlCredentialStorage)
            XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(configuration.waitsForConnectivity)
            XCTAssertTrue(session.delegate is OpenAIChatRedirectRejectingDelegate)
        }
    }

    func test_endpoint_url_appends_v1_chat() throws {
        let u1 = try OpenAIChatClient.endpointURL(baseURL: "https://api.openai.com")
        XCTAssertEqual(u1.absoluteString, "https://api.openai.com/v1/chat/completions")
        let u2 = try OpenAIChatClient.endpointURL(baseURL: "https://api.openai.com/")
        XCTAssertEqual(u2.absoluteString, "https://api.openai.com/v1/chat/completions")
        let u3 = try OpenAIChatClient.endpointURL(baseURL: "http://localhost:11434/v1")
        XCTAssertEqual(u3.absoluteString, "http://localhost:11434/v1/chat/completions")

        let prefixed = try OpenAIChatClient.endpointURL(
            baseURL: "https://gateway.example/openai/v1"
        )
        XCTAssertEqual(
            prefixed.absoluteString,
            "https://gateway.example/openai/v1/chat/completions"
        )

        let complete = try OpenAIChatClient.endpointURL(
            baseURL: "https://gateway.example/openai/v1/chat/completions"
        )
        XCTAssertEqual(
            complete.absoluteString,
            "https://gateway.example/openai/v1/chat/completions"
        )
    }

    /// v2026.07.18 P2 origin regression: URLComponents that can alter authority or endpoint
    /// semantics are rejected before any credential lookup or URLSession task is created.
    func test_endpoint_url_拒绝模糊origin与endpoint组件() {
        let invalidBases = [
            "",
            " https://api.openai.com",
            "https://api.openai.com ",
            "https://",
            "https:///v1",
            "https://user@api.openai.com",
            "https://user:password@api.openai.com/v1",
            "https://api.openai.com?v=1",
            "https://api.openai.com?",
            "https://api.openai.com#provider",
            "https://api.openai.com#",
            "https://api.openai.com:",
            "https://api.openai.com:65536",
            "https://api.openai.com/a//b",
            "https://api.openai.com/a/../b",
            "https://api.openai.com/a/%2F/b",
            "https://api.openai.com/a\\@other.example",
        ]

        for invalidBase in invalidBases {
            XCTAssertThrowsError(
                try OpenAIChatClient.endpointURL(baseURL: invalidBase),
                "baseURL=\(invalidBase) 必须在发送前被拒"
            ) { error in
                XCTAssertEqual(error as? OpenAIChatClient.Error, .invalidBaseURL)
            }
        }
    }

    /// v2026.07.18 P2 redirect regression: both same-origin and cross-origin redirects must
    /// receive a nil follow-up request. This is a pre-follow policy, not a response-origin check.
    func test_defaultSession_发送前拒绝所有HTTP重定向() throws {
        let session = OpenAIChatClient.makeIsolatedSession()
        defer { session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(
            session.delegate as? OpenAIChatRedirectRejectingDelegate
        )
        let originalURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1/chat/completions"))
        let task = session.dataTask(with: originalURL)
        defer { task.cancel() }

        for (status, destination) in [
            (307, "https://api.openai.com/v2/chat/completions"),
            (302, "https://attacker.example/collect"),
        ] {
            let destinationURL = try XCTUnwrap(URL(string: destination))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: originalURL,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination]
                )
            )
            let decision = RedirectDecisionBox()

            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destinationURL)
            ) { proposedRequest in
                decision.record(proposedRequest)
            }

            let snapshot = decision.snapshot()
            XCTAssertTrue(snapshot.called, "redirect delegate 必须同步给出拒绝决定")
            XCTAssertNil(snapshot.request, "status=\(status) destination=\(destination) 不得跟随")
        }
    }

    /// v2026.07.18 P1 log-schema regression: diagnostics keep endpoint host + typed numeric
    /// facts, while authority credentials, path, query, fragment and payload text are excluded.
    func test_networkLogFacts_只保留hostStage与类型化诊断() throws {
        let endpoint = try XCTUnwrap(URL(
            string: "https://user:sk-url-secret@api.openai.com/private/prompt"
                + "?payload=provider-body#fragment"
        ))
        let httpFacts = OpenAIChatClient.networkLogFacts(
            endpoint: endpoint,
            stage: .http,
            status: 503,
            responseBytes: 4_096
        )
        XCTAssertEqual(
            httpFacts,
            "endpointHost=api.openai.com stage=http status=503 responseBytes=4096"
        )

        let transportFacts = OpenAIChatClient.networkLogFacts(
            endpoint: endpoint,
            stage: .transport,
            transportDomain: NSURLErrorDomain,
            transportCode: URLError.notConnectedToInternet.rawValue
        )
        XCTAssertEqual(
            transportFacts,
            "endpointHost=api.openai.com stage=transport "
                + "transportDomain=NSURLErrorDomain transportCode=-1009"
        )

        let responseLimitFacts = OpenAIChatClient.networkLogFacts(
            endpoint: endpoint,
            stage: .responseLimit,
            responseBytes: 1_048_577,
            responseLimitBytes: 1_048_576
        )
        XCTAssertEqual(
            responseLimitFacts,
            "endpointHost=api.openai.com stage=response-limit "
                + "responseBytes=1048577 responseLimitBytes=1048576"
        )

        for facts in [httpFacts, transportFacts, responseLimitFacts] {
            XCTAssertFalse(facts.contains("sk-url-secret"))
            XCTAssertFalse(facts.contains("/private/prompt"))
            XCTAssertFalse(facts.contains("provider-body"))
            XCTAssertFalse(facts.contains("fragment"))
        }
    }

    /// v2026.07.18 P2 ordering regression: invalid origin input must fail before Keychain access
    /// and before a URLSession task exists. Validation after either boundary is already too late.
    func test_ask_模糊baseURL在凭据读取与请求创建前失败() async {
        let keyReads = IntegerBox()
        StubURLProtocol.observedRequests = []
        let client = OpenAIChatClient(
            settings: OpenAIChatClient.SettingsSnapshot(
                baseURL: "https://user@api.openai.com?destination=other",
                model: "gpt-4o-mini",
                temperature: 0.2,
                redactPaths: true
            ),
            apiKeyProvider: {
                keyReads.increment()
                return "sk-must-not-be-read"
            },
            testingSession: stubSession()
        )

        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("模糊 baseURL 必须拒绝")
        } catch OpenAIChatClient.Error.invalidBaseURL {
            XCTAssertEqual(keyReads.value, 0)
            XCTAssertTrue(StubURLProtocol.observedRequests.isEmpty)
        } catch {
            XCTFail("意外错误：\(error)")
        }
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
        // 产品契约：AIKit 层降级时贴 sentinel prefix（见 AIAdviceClamp.localPolicyOverridePrefix），
        // UI 层再替换为本地化文案。此处锁 sentinel，不锁翻译后字面量。
        XCTAssertTrue(advice.reason.hasPrefix(AIAdviceClamp.localPolicyOverridePrefix),
                      "实际=\(advice.reason)")
    }

    func test_ask_unparsable_response_不保留provider原文() async throws {
        let raw = "secret-provider-payload /Users/alice/Library sk-sensitive-token"
        let payload = """
        {"choices":[{"message":{"role":"assistant","content":"\(raw)"}}]}
        """
        StubURLProtocol.nextResponse = .success(status: 200, data: Data(payload.utf8))

        let advice = try await makeClient().ask(makeInquiry())

        XCTAssertEqual(advice.summary, AIAdvice.unparsableSummaryKey)
        XCTAssertTrue(advice.reason.isEmpty)
        let storedDescription = String(describing: advice)
        XCTAssertFalse(storedDescription.contains("secret-provider-payload"))
        XCTAssertFalse(storedDescription.contains("/Users/alice"))
    }

    func test_ask_http_error_surfaces() async {
        let responseBody = Data("unauthorized".utf8)
        StubURLProtocol.nextResponse = .success(status: 401, data: responseBody)
        let client = makeClient()
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("应抛 http error")
        } catch let OpenAIChatClient.Error.http(status, responseBytes) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(responseBytes, responseBody.count)
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
    }

    /// v2026.07.18 P2 response-boundary regression: a declared Content-Length over the cap must
    /// be rejected from the response callback before the fixture sends any provider body.
    func test_ask_已知ContentLength超限时在body前取消() async {
        let limit = OpenAIChatClient.maximumResponseBytes
        StubURLProtocol.resetStopLoadingCount()
        StubURLProtocol.nextResponse = .streamThenHang(
            status: 200,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": String(limit + 1),
            ],
            chunks: []
        )

        do {
            _ = try await makeClient().ask(makeInquiry())
            XCTFail("声明长度超限必须在接收 body 前失败")
        } catch let OpenAIChatClient.Error.transport(domain, code) {
            XCTAssertEqual(domain, OpenAIChatClient.responseLimitTransportDomain)
            XCTAssertEqual(code, OpenAIChatClient.responseLimitTransportCode)
        } catch {
            XCTFail("必须投影为稳定 typed transport error，实际：\(error)")
        }

        await waitForStopLoading()
        XCTAssertGreaterThanOrEqual(
            StubURLProtocol.stopLoadingCount,
            1,
            "已知长度超限必须取消底层 URLProtocol load"
        )
    }

    /// v2026.07.18 P2 response-boundary regression: without Content-Length the first bytes up to
    /// the cap are admissible, but the next byte must cancel the task instead of being appended.
    func test_ask_未知ContentLength在刚超过硬上限时取消() async {
        let limit = OpenAIChatClient.maximumResponseBytes
        StubURLProtocol.resetStopLoadingCount()
        StubURLProtocol.nextResponse = .streamThenHang(
            status: 200,
            headers: ["Content-Type": "application/json"],
            chunks: [
                Data(repeating: 0x41, count: limit),
                Data([0x42]),
            ]
        )

        do {
            _ = try await makeClient().ask(makeInquiry())
            XCTFail("未知长度响应刚超过硬上限时必须失败")
        } catch let error as OpenAIChatClient.Error {
            XCTAssertEqual(
                error,
                .transport(
                    domain: OpenAIChatClient.responseLimitTransportDomain,
                    code: OpenAIChatClient.responseLimitTransportCode
                )
            )
            let description = String(describing: error)
            XCTAssertFalse(description.contains("provider"))
            XCTAssertFalse(description.contains("AAAA"))
        } catch {
            XCTFail("必须投影为稳定 typed transport error，实际：\(error)")
        }

        await waitForStopLoading()
        XCTAssertGreaterThanOrEqual(
            StubURLProtocol.stopLoadingCount,
            1,
            "未知长度超限必须取消底层 URLProtocol load"
        )
    }

    /// v2026.07.18 P1 privacy regression: redacting path-shaped substrings is insufficient.
    /// Provider text may echo arbitrary payloads or credentials, so it must never enter Error.
    func test_ask_http_error_只保留status与字节数_不保留provider正文() async {
        let leaky = #"{"error":{"message":"Bearer sk-secret payload /Users/alice/private"}}"#
        StubURLProtocol.nextResponse = .success(status: 400, data: Data(leaky.utf8))
        let client = makeClient()
        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("应抛 http error")
        } catch let error as OpenAIChatClient.Error {
            XCTAssertEqual(
                error,
                .http(status: 400, responseBytes: Data(leaky.utf8).count)
            )
            let description = String(describing: error)
            XCTAssertEqual(
                description,
                "OpenAIChatClient.Error.http(status=400, responseBytes=\(Data(leaky.utf8).count))"
            )
            XCTAssertFalse(description.contains("sk-secret"))
            XCTAssertFalse(description.contains("payload"))
            XCTAssertFalse(description.contains("/Users/alice"))
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
    }

    func test_ask_decoding_error_不保留provider正文() async {
        let leaky = "not-json Bearer sk-decoding-secret /Users/alice/private"
        StubURLProtocol.nextResponse = .success(status: 200, data: Data(leaky.utf8))
        do {
            _ = try await makeClient().ask(makeInquiry())
            XCTFail("应抛 decoding error")
        } catch let error as OpenAIChatClient.Error {
            XCTAssertEqual(error, .decoding)
            let description = String(describing: error)
            XCTAssertEqual(description, "OpenAIChatClient.Error.decoding")
            XCTAssertFalse(description.contains("sk-decoding-secret"))
            XCTAssertFalse(description.contains("/Users/alice"))
        } catch {
            XCTFail("意外错误类型: \(error)")
        }
    }

    func test_ask_unknownTransportError_只保留稳定类型不保留底层描述() async {
        let underlying = SensitiveTransportError()
        let underlyingNSError = underlying as NSError
        StubURLProtocol.nextResponse = .transport(underlying)
        do {
            _ = try await makeClient().ask(makeInquiry())
            XCTFail("应抛 transport error")
        } catch let error as OpenAIChatClient.Error {
            XCTAssertEqual(
                error,
                .transport(domain: underlyingNSError.domain, code: underlyingNSError.code)
            )
            let description = String(describing: error)
            XCTAssertEqual(
                description,
                "OpenAIChatClient.Error.transport(domain=\(underlyingNSError.domain), "
                    + "code=\(underlyingNSError.code))"
            )
            XCTAssertFalse(description.contains("sk-transport-secret"))
            XCTAssertFalse(description.contains("payload"))
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
            testingSession: stubSession()
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

    /// v2026.07.18 P1 regression: SettingsSnapshot is untrusted construction input. A malicious
    /// endpoint/model must not escape through debugDescription, String reflection or Mirror before
    /// endpointURL validates the network boundary in ask().
    func test_未校验恶意Settings_调试与Mirror只暴露稳定脱敏状态() {
        let secrets = [
            "userinfo-secret",
            "password-secret",
            "query-secret",
            "fragment-secret",
            "model-secret",
            "sk-settings-secret",
        ]
        let client = OpenAIChatClient(
            settings: OpenAIChatClient.SettingsSnapshot(
                baseURL: "https://userinfo-secret:password-secret@example.invalid/v1"
                    + "?token=query-secret#fragment-secret",
                model: "model-secret?token=query-secret#fragment-secret",
                temperature: 0.2,
                redactPaths: true
            ),
            apiKey: "sk-settings-secret",
            testingSession: stubSession()
        )

        let expected = "OpenAIChatClient(settings=<configured>, apiKey=<redacted>)"
        XCTAssertEqual(client.debugDescription, expected)
        XCTAssertEqual(String(describing: client), expected)
        XCTAssertEqual(String(reflecting: client), expected)

        let mirror = Mirror(reflecting: client)
        let reflectedSettings = mirror.children.first(where: { $0.label == "settings" })?.value
        XCTAssertEqual(reflectedSettings as? String, "<configured>")

        var dumpText = ""
        dump(client, to: &dumpText)
        let introspectionOutputs = [
            client.debugDescription,
            String(describing: client),
            String(reflecting: client),
            dumpText,
        ] + mirror.children.map { String(reflecting: $0.value) }

        for output in introspectionOutputs {
            for secret in secrets {
                XCTAssertFalse(output.contains(secret), "自省输出泄漏未校验设置: \(secret)\n\(output)")
            }
        }
        XCTAssertTrue(dumpText.contains("<configured>"))
        XCTAssertTrue(dumpText.contains("<redacted>"))
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
            testingSession: stubSession()
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

    func test_asyncAPIKeyProvider_保留Keychain错误而不是伪装成缺少Key() async {
        let expected = KeychainAPIKeyStoreError.staleFileBasedReference(
            OSStatus(kPOSIXErrorENOENT)
        )
        let client = OpenAIChatClient(
            settings: OpenAIChatClient.SettingsSnapshot(
                baseURL: "https://api.openai.com",
                model: "gpt-4o-mini",
                temperature: 0.2,
                redactPaths: true
            ),
            asyncAPIKeyProvider: { throw expected },
            testingSession: stubSession()
        )

        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("Keychain 错误不能被压成空 Key")
        } catch let error as KeychainAPIKeyStoreError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    func test_loopback免鉴权也不能吞掉provider取消() async {
        let client = OpenAIChatClient(
            settings: OpenAIChatClient.SettingsSnapshot(
                baseURL: "http://127.0.0.1:11434",
                model: "local-model",
                temperature: 0.2,
                redactPaths: true
            ),
            asyncAPIKeyProvider: { throw CancellationError() },
            testingSession: stubSession()
        )

        do {
            _ = try await client.ask(makeInquiry())
            XCTFail("本地免鉴权不能把取消降级成空 API Key 后继续请求")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    func test_ask_missing_api_key_throws_immediately() async {
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: "https://api.openai.com",
            model: "gpt-4o-mini",
            temperature: 0.2,
            redactPaths: true
        )
        let client = OpenAIChatClient(
            settings: snapshot,
            apiKey: "",
            testingSession: stubSession()
        )
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
        let client = OpenAIChatClient(
            settings: snapshot,
            apiKey: "",
            testingSession: stubSession()
        )
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
        _ = try await client.ask(makeInquiry(path: "/Users/amuxuser/Library/Caches/x"))
        let req = try XCTUnwrap(StubURLProtocol.observedRequests.first)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
        let bodyData = try XCTUnwrap(StubURLProtocol.observedBodies.first)
        let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains("amuxuser"), "出网 body 必须去敏掉用户名，实际:\n\(bodyText)")
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

    /// v2026.07.18 P2 deterministic interleaving: exercise the exact schedule that the old
    /// unsynchronized TaskBox could not represent safely—onCancel wins before task installation.
    func test_cancellationOwnership_cancel先于install_只取消一次() {
        let ownership = OpenAIChatTaskCancellationOwnership()
        let cancelCount = OSAllocatedUnfairLock(initialState: 0)

        ownership.requestCancellation()
        XCTAssertEqual(
            ownership.install {
                cancelCount.withLock { $0 += 1 }
            },
            .cancelledBeforeInstallation
        )
        ownership.requestCancellation()
        ownership.finish()
        ownership.requestCancellation()

        XCTAssertEqual(cancelCount.withLock { $0 }, 1)
    }

    /// The inverse schedule is also one-shot: install wins, then any number of cancellation
    /// notifications still invokes the URLSession cancellation action exactly once.
    func test_cancellationOwnership_install先于cancel_只取消一次() {
        let ownership = OpenAIChatTaskCancellationOwnership()
        let cancelCount = OSAllocatedUnfairLock(initialState: 0)

        XCTAssertEqual(
            ownership.install {
                cancelCount.withLock { $0 += 1 }
            },
            .installed
        )
        ownership.requestCancellation()
        ownership.requestCancellation()
        ownership.finish()

        XCTAssertEqual(cancelCount.withLock { $0 }, 1)
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
        } catch OpenAIChatClient.Error.transport(let domain, let code) {
            XCTAssertEqual(domain, NSURLErrorDomain)
            XCTAssertEqual(code, URLError.notConnectedToInternet.rawValue)
        } catch {
            XCTFail("意外: \(error)")
        }
    }

    // MARK: - 测试夹具

    private func makeInquiry(path: String = "/Users/amuxuser/Library/Caches/x",
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
        return OpenAIChatClient(
            settings: snapshot,
            apiKey: apiKey,
            testingSession: stubSession()
        )
    }

    private func stubSession() -> URLSession {
        OpenAIChatClient.makeIsolatedSession(protocolClasses: [StubURLProtocol.self])
    }

    private func waitForStopLoading() async {
        for _ in 0..<100 where StubURLProtocol.stopLoadingCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private struct SensitiveTransportError: Error, CustomStringConvertible {
    var description: String {
        "sk-transport-secret payload /Users/alice/private"
    }
}

private final class RedirectDecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var request: URLRequest?

    func record(_ request: URLRequest?) {
        lock.lock()
        called = true
        self.request = request
        lock.unlock()
    }

    func snapshot() -> (called: Bool, request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        return (called, request)
    }
}

private final class IntegerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
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
        /// Sends a response and zero or more chunks but deliberately never finishes. The
        /// production delegate must cancel the underlying load once its hard boundary is hit.
        case streamThenHang(status: Int, headers: [String: String], chunks: [Data])
    }

    nonisolated(unsafe) static var nextResponse: Stub = .success(status: 200, data: Data())
    nonisolated(unsafe) static var observedRequests: [URLRequest] = []
    nonisolated(unsafe) static var observedBodies: [Data] = []
    private static let stopCounter = OSAllocatedUnfairLock(initialState: 0)

    static var stopLoadingCount: Int {
        stopCounter.withLock { $0 }
    }

    static func resetStopLoadingCount() {
        stopCounter.withLock { $0 = 0 }
    }

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
        case let .streamThenHang(status, headers, chunks):
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
        }
    }

    override func stopLoading() {
        Self.stopCounter.withLock { $0 += 1 }
        // hang 模式下，URLSession 会在 dataTask.cancel() 时调 stopLoading；
        // 此时主动以 URLError.cancelled 完成，触发 OpenAIChatClient 的
        // CancellationError 翻译路径。
        switch Self.nextResponse {
        case .hang, .streamThenHang:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case .success, .transport:
            break
        }
    }
}
