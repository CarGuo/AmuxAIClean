import Foundation
import LogKit
import SafetyKit

/// M5 / 2026-06：OpenAI 协议 chat completions 客户端（**非流式**）。
///
/// 设计要点（按需触发版）：
/// - 纯 `URLSession`，不引入任何第三方 SDK——保持仓库供应链可审计（与
///   [FEATURE_GAP §3.1](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/FEATURE_GAP.md#L226-L228) 开源审计承诺一致）；
/// - 不做流式 SSE——按需触发场景下用户期望"点完一会儿出一张完整卡片"，
///   一次性响应足够，省 200+ 行 SSE 解析；
/// - 不做缓存 / 不做 rate limiter——用户自控点击次数（[PathInquiry](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/PathInquiry.swift) 已克制 prompt 大小）；
/// - 后置 [AIAdviceClamp](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/PromptBuilder.swift)
///   把 AI 输出与本地 SafetyEngine 红线做强制对齐；
/// - 可注入 [URLSession]——单测用 URLProtocol fake 拦截，不打真接口。
public struct OpenAIChatClient: Sendable, CustomDebugStringConvertible, CustomReflectable {

    public enum Error: Swift.Error, Equatable {
        case missingAPIKey
        case invalidBaseURL
        /// **Review fix-soon #7，2026-06-15**：用户配的 baseURL scheme 不在白名单内
        /// （只接受 `https://` 与 `http://localhost`、`http://127.0.0.1`、`http://[::1]`
        /// 本地端点）。明文 `http://` 远端会让 `Authorization: Bearer <key>` 中间节点
        /// 可见，必须拒绝。
        case insecureBaseURL(scheme: String, host: String)
        /// **v2026.06.22 (P0-4)**：`body` 已经过 [PathRedactor.redact](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/PathRedactor.swift)
        /// 处理。请上层 UI/日志直接展示——不要再加任何去敏，也不要再原样 log raw body。
        case http(status: Int, body: String)
        case decoding(String)
        case transport(String)
    }

    private let settings: SettingsSnapshot
    /// **v2026.06.22 (P0-4)**：apiKey 改为按需闭包拉取，避免常驻 struct 字段被 Mirror
    /// 反射或 `String(describing:)` 顺手 dump 到日志/崩溃报告里。
    /// 闭包内部典型实现：从 Keychain 取值（参考
    /// [AISettings.apiKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/AISettings.swift)）。
    /// 闭包 throws 直接转 `Error.missingAPIKey`，UI 引导用户去 Settings 重新填。
    private let apiKeyProvider: @Sendable () throws -> String
    private let session: URLSession
    private let redactor: PathRedactor
    private let prompts: PromptBuilder

    /// 不可变 settings 快照——避免持有 @MainActor 的 [AISettings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/AISettings.swift)
    /// 跨 actor 传递；UI 在调用 ask 前把当前值打成快照即可。
    public struct SettingsSnapshot: Sendable, Equatable {
        public let baseURL: String
        public let model: String
        public let temperature: Double
        public let redactPaths: Bool
        public init(baseURL: String, model: String, temperature: Double, redactPaths: Bool) {
            self.baseURL = baseURL
            self.model = model
            self.temperature = temperature
            self.redactPaths = redactPaths
        }
    }

    /// **v2026.06.22 (P0-4)**：apiKey 走闭包按需读取——典型 prod 用例：
    /// `OpenAIChatClient(settings: ..., apiKeyProvider: { try AISettings.keychainReadAPIKey() })`。
    /// 测试可注入 `{ "test-key" }`。闭包 throws 视为 missingAPIKey。
    public init(settings: SettingsSnapshot,
                apiKeyProvider: @escaping @Sendable () throws -> String,
                session: URLSession = .shared,
                redactor: PathRedactor = PathRedactor(),
                prompts: PromptBuilder = PromptBuilder()) {
        self.settings = settings
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.redactor = redactor
        self.prompts = prompts
    }

    /// 兼容旧 callsite：直接传字符串 apiKey。新代码请用 `apiKeyProvider:` 闭包入口。
    public init(settings: SettingsSnapshot,
                apiKey: String,
                session: URLSession = .shared,
                redactor: PathRedactor = PathRedactor(),
                prompts: PromptBuilder = PromptBuilder()) {
        self.init(settings: settings,
                  apiKeyProvider: { apiKey },
                  session: session,
                  redactor: redactor,
                  prompts: prompts)
    }

    /// **v2026.06.22 (P0-4)**：屏蔽 `String(describing:)` 暴露 apiKeyProvider 闭包 capture。
    public var debugDescription: String {
        "OpenAIChatClient(baseURL=\(settings.baseURL), model=\(settings.model), apiKey=<redacted>)"
    }

    /// **v2026.06.22 (P0-4)**：屏蔽 Mirror 反射 dump apiKeyProvider 闭包内部捕获的 key。
    /// `Mirror(reflecting: client).children` 将只看到 settings / session / redactor / prompts。
    public var customMirror: Mirror {
        Mirror(self, children: [
            "settings": settings,
            "apiKey": "<redacted>",
            "session": session,
            "redactor": redactor,
            "prompts": prompts,
        ])
    }

    /// 入口：按需触发一次 AI 询问。
    /// - 失败：抛 [Error](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)；
    /// - 成功：返回**已 clamp 过**的 AIAdvice，UI 可直接渲染。
    public func ask(_ inquiry: PathInquiry) async throws -> AIAdvice {
        // **v2026.06.22 (P0-4)**：按需取 key，不在 struct 字段常驻
        let apiKey: String
        do {
            apiKey = try apiKeyProvider()
        } catch {
            throw Error.missingAPIKey
        }
        guard !apiKey.isEmpty else { throw Error.missingAPIKey }
        let url = try Self.endpointURL(baseURL: settings.baseURL)

        // 1. 去敏（仅当用户开了 redactPaths 时执行；默认开）
        let sanitized: PathInquiry = settings.redactPaths
            ? sanitize(inquiry)
            : inquiry

        // 2. 构造 messages
        let messages = prompts.makeMessages(for: sanitized)

        // 3. 组装 request body
        let body = ChatRequest(
            model: settings.model,
            messages: messages,
            temperature: settings.temperature,
            responseFormat: .jsonObject
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30

        // 4. 发请求
        //
        // **Review fix-soon #6，2026-06-15**：cancellation 通道。
        // `URLSession.data(for:)` 在 Task 取消时不会主动中断飞行中的 HTTP 连接，
        // 必须用 `URLSessionDataTask` + `withTaskCancellationHandler` 把上游的
        // 取消信号桥到 `task.cancel()`——AIAdviceSheet 关闭时 `.task` 修饰符
        // 会 cancel 这个 Task，从而让在途的 token 流量真正立刻中断（节省 token
        // + 防止用户切下一张卡时被前一张卡的迟到响应干扰）。
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.dataWithCancellation(
                session: session,
                request: request
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw Error.transport("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // **Review fix-soon log 隐私**：不再把 body 截 200 字符落盘——
            // 服务端 4xx/5xx 的 message 字段可能 echo 用户路径 / model 名 / 部分
            // payload。只 log status code + body 长度，不 log body 内容。
            // **v2026.06.22 (P0-4)**：完整 body 也必须先经 PathRedactor.redact 去敏
            // 再抛给 UI 层——否则 UI 直接展示就把绝对路径泄漏到弹窗 / 日志 / 截图里。
            GSYLog.warning(.settings,
                           "[AIKit] http \(http.statusCode), body=\(data.count)B")
            let bodyRaw = String(data: data, encoding: .utf8) ?? ""
            let bodySafe = redactor.redact(bodyRaw)
            throw Error.http(status: http.statusCode, body: bodySafe)
        }

        // 5. 解析 chat 响应
        let envelope: ChatResponse
        do {
            envelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw Error.decoding("envelope: \(error)")
        }
        guard let raw = envelope.choices.first?.message.content,
              !raw.isEmpty else {
            throw Error.decoding("empty content")
        }

        // 6. 解析 AIAdvice JSON（模型可能多包一层 ```json...```，做一次剥离）
        let cleaned = Self.stripCodeFence(raw)
        let advice: AIAdvice
        if let parsed = Self.tryDecodeAdvice(cleaned) {
            advice = parsed
        } else {
            GSYLog.warning(.settings, "[AIKit] advice decode fallback, raw=\(raw.prefix(120))")
            advice = .unparsable(rawText: raw)
        }

        // 7. 后置 clamp——AI 不允许覆盖本地 SafetyEngine 红线
        return AIAdviceClamp.clamp(advice, against: inquiry)
    }

    // MARK: - 工具

    /// 拼 base URL → `/v1/chat/completions`。兼容尾部带不带 `/`、带不带 `/v1`。
    ///
    /// **Review fix-soon #7，2026-06-15**：scheme 白名单。
    /// 拒绝任何非 `https://` 的远端端点；只对 `localhost` / `127.0.0.1` / `[::1]`
    /// 开 `http://` 例外（让用户能跑本地 Ollama / vLLM / LM Studio）。其它 `http://`
    /// 一律抛 `insecureBaseURL`——`Authorization: Bearer <key>` 走明文链路风险过高。
    public static func endpointURL(baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !trimmed.isEmpty else { throw Error.invalidBaseURL }
        let withV1 = trimmed.contains("/v1") ? trimmed : trimmed + "/v1"
        let full = withV1 + "/chat/completions"
        guard let url = URL(string: full),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased() else {
            throw Error.invalidBaseURL
        }
        let host = (comps.host ?? "").lowercased()
        switch scheme {
        case "https":
            return url
        case "http":
            // 只放行本机环回地址
            if Self.loopbackHosts.contains(host) {
                return url
            }
            throw Error.insecureBaseURL(scheme: scheme, host: host)
        default:
            throw Error.insecureBaseURL(scheme: scheme, host: host)
        }
    }

    /// 本机环回 host 白名单（用于 baseURL scheme 校验放行 http://localhost）。
    private static let loopbackHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]"
    ]

    /// **Review fix-soon #6**：用 `URLSessionDataTask` + `withTaskCancellationHandler`
    /// 把 Swift Concurrency 的 Task 取消信号真正桥到底层 HTTP 连接 cancel。
    ///
    /// 实现要点：
    /// - 用 `withCheckedThrowingContinuation` 把 `URLSessionDataTask` 完成回调
    ///   桥成 async；
    /// - `withTaskCancellationHandler` 在外层 Task 被 cancel 时调用
    ///   `dataTask.cancel()`，让底层 URLSession 立刻断连接、不再等服务端响应；
    /// - cancellation 路径把 `URLError.cancelled` 翻译为 Swift 的
    ///   `CancellationError`，便于上层用 `catch is CancellationError` 精确处理。
    /// - **continuation 单 resume 保证**：用 `resumed` 计数器防止 cancel 与
    ///   completion 竞争时双 resume crash（Swift Concurrency 严格要求恰好 resume 一次）。
    private static func dataWithCancellation(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        // 用引用包一下，让 cancellation handler 能访问到 dataTask。
        final class TaskBox: @unchecked Sendable {
            var task: URLSessionDataTask?
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Swift.Error>) in
                let dataTask = session.dataTask(with: request) { data, response, error in
                    if let error {
                        // URLError.cancelled → 翻译成 CancellationError
                        if (error as? URLError)?.code == .cancelled {
                            cont.resume(throwing: CancellationError())
                        } else {
                            cont.resume(throwing: error)
                        }
                        return
                    }
                    guard let data, let response else {
                        cont.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    cont.resume(returning: (data, response))
                }
                box.task = dataTask
                // 如果 Task 已经被 cancel（race：cancel 在 dataTask 启动前到达），
                // 立即 cancel（dataTask.cancel 是幂等的）。
                if Task.isCancelled {
                    dataTask.cancel()
                }
                dataTask.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// 去掉 markdown ```json...``` 包裹。
    public static func stripCodeFence(_ s: String) -> String {
        var x = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.hasPrefix("```") {
            // 删掉首行 ```（可能 ```json）
            if let firstNewline = x.firstIndex(of: "\n") {
                x = String(x[x.index(after: firstNewline)...])
            }
            if x.hasSuffix("```") {
                x = String(x.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return x
    }

    private static func tryDecodeAdvice(_ s: String) -> AIAdvice? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AIAdvice.self, from: data)
    }

    /// 对 inquiry 做去敏（path + childPreview），其它字段原样。
    private func sanitize(_ inquiry: PathInquiry) -> PathInquiry {
        PathInquiry(
            path: redactor.redact(inquiry.path),
            isDirectory: inquiry.isDirectory,
            bytes: inquiry.bytes,
            fileCount: inquiry.fileCount,
            modificationDate: inquiry.modificationDate,
            verdict: inquiry.verdict,
            vendorName: inquiry.vendorName,
            vendorNote: inquiry.vendorNote,
            childPreview: redactor.redact(inquiry.childPreview)
        )
    }
}

// MARK: - 线上协议体

/// OpenAI 协议 chat 请求体（最小集）。
private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
    }

    struct ResponseFormat: Encodable {
        let type: String
        static let jsonObject = ResponseFormat(type: "json_object")
    }
}

/// OpenAI 协议 chat 响应体（最小集，忽略 usage / id / created）。
private struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: ChatMessage
    }
}
