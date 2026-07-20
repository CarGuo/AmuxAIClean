import Foundation
import LogKit
import os
import SafetyKit

/// v2026.07.18 P2 response-boundary fix: a completion-handler data task buffers the complete
/// provider response inside Foundation before AIKit can inspect its size. The bounded delegate
/// below owns every in-flight transfer and admits bytes incrementally, so both declared and
/// chunked responses are rejected before AIKit retains more than the configured hard limit.
enum OpenAIChatBoundedResponseError: Swift.Error, Equatable, Sendable {
    case exceedsLimit(limitBytes: Int, observedBytes: Int)
}

/// v2026.07.18 P2 cancellation fix: cancellation and task creation are two independently
/// scheduled operations. This one-shot state machine serializes their ownership transition with
/// `OSAllocatedUnfairLock` (available on the product's macOS 13.5 floor) instead of sharing an
/// unsynchronized optional task behind `@unchecked Sendable`.
struct OpenAIChatTaskCancellationOwnership: Sendable {
    enum Installation: Equatable, Sendable {
        case installed
        case cancelledBeforeInstallation
    }

    private enum State: Sendable {
        case awaitingInstallation(cancellationRequested: Bool)
        case installed(cancel: @Sendable () -> Void)
        case cancelled
        case finished
    }

    private let state = OSAllocatedUnfairLock<State>(
        initialState: .awaitingInstallation(cancellationRequested: false)
    )

    /// Installs exactly one cancellation action. If cancellation won the race, the action is
    /// invoked once after releasing the lock; callers may then start/resume the already-cancelled
    /// URLSession task solely to let its completion path settle the checked continuation.
    func install(cancel: @escaping @Sendable () -> Void) -> Installation {
        let (result, action) = state.withLock { state -> (Installation, (@Sendable () -> Void)?) in
            switch state {
            case .awaitingInstallation(cancellationRequested: false):
                state = .installed(cancel: cancel)
                return (.installed, nil)
            case .awaitingInstallation(cancellationRequested: true):
                state = .cancelled
                return (.cancelledBeforeInstallation, cancel)
            case .installed, .cancelled, .finished:
                preconditionFailure("OpenAI data task cancellation ownership installed twice")
            }
        }
        action?()
        return result
    }

    /// May race with `install(cancel:)`. The installed action is extracted under the lock and
    /// executed outside it, so task cancellation is idempotent and cannot re-enter locked state.
    func requestCancellation() {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            switch state {
            case .awaitingInstallation(cancellationRequested: false):
                state = .awaitingInstallation(cancellationRequested: true)
                return nil
            case .awaitingInstallation(cancellationRequested: true), .cancelled, .finished:
                return nil
            case .installed(let cancel):
                state = .cancelled
                return cancel
            }
        }
        action?()
    }

    /// Releases the cancellation closure after the continuation reaches a terminal result.
    func finish() {
        state.withLock { state in
            state = .finished
        }
    }
}

/// v2026.07.18 P2 origin boundary fix: redirects are rejected before URL Loading System
/// creates the follow-up request. A response-origin check would be too late because the
/// Authorization header and AI payload may already have crossed to another endpoint.
///
/// v2026.07.18: this same delegate is also the single capped streaming path for production and
/// URLProtocol-injected tests. Its registry is protected by `OSAllocatedUnfairLock`; continuations
/// are always resumed after releasing the lock. Keeping redirect and byte admission in one
/// session delegate prevents either policy from being bypassed by a second transport path.
final class OpenAIChatRedirectRejectingDelegate: NSObject, URLSessionDataDelegate {
    typealias ResponseContinuation = CheckedContinuation<(Data, URLResponse), Swift.Error>

    private struct TaskKey: Hashable, Sendable {
        let session: ObjectIdentifier
        let taskIdentifier: Int
    }

    private struct Transfer: Sendable {
        let limitBytes: Int
        let continuation: ResponseContinuation
        var response: URLResponse?
        var data = Data()
    }

    private struct Registry: Sendable {
        var transfers: [TaskKey: Transfer] = [:]
    }

    private enum Admission: Sendable {
        case accepted
        case rejected(ResponseContinuation, OpenAIChatBoundedResponseError)
        case inactive
    }

    static let shared = OpenAIChatRedirectRejectingDelegate()
    private let registry = OSAllocatedUnfairLock<Registry>(initialState: Registry())

    private override init() {
        super.init()
    }

    private func key(session: URLSession, task: URLSessionTask) -> TaskKey {
        TaskKey(
            session: ObjectIdentifier(session),
            taskIdentifier: task.taskIdentifier
        )
    }

    /// Registration happens while the data task is suspended, before `resume()`, so no delegate
    /// callback can outrun the continuation's registry entry.
    func register(
        session: URLSession,
        task: URLSessionDataTask,
        limitBytes: Int,
        continuation: ResponseContinuation
    ) -> Bool {
        precondition(limitBytes > 0)
        let taskKey = key(session: session, task: task)
        return registry.withLock { registry in
            guard registry.transfers[taskKey] == nil else { return false }
            registry.transfers[taskKey] = Transfer(
                limitBytes: limitBytes,
                continuation: continuation,
                response: nil
            )
            return true
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let taskKey = key(session: session, task: dataTask)
        let admission = registry.withLock { registry -> Admission in
            guard var transfer = registry.transfers.removeValue(forKey: taskKey) else {
                return .inactive
            }

            let declaredBytes = response.expectedContentLength
            if declaredBytes > Int64(transfer.limitBytes) {
                let observedBytes = declaredBytes > Int64(Int.max)
                    ? Int.max
                    : Int(declaredBytes)
                return .rejected(
                    transfer.continuation,
                    .exceedsLimit(
                        limitBytes: transfer.limitBytes,
                        observedBytes: observedBytes
                    )
                )
            }

            transfer.response = response
            if declaredBytes > 0 {
                transfer.data.reserveCapacity(Int(declaredBytes))
            }
            registry.transfers[taskKey] = transfer
            return .accepted
        }

        switch admission {
        case .accepted:
            completionHandler(.allow)
        case .rejected(let continuation, let error):
            completionHandler(.cancel)
            // Refuse the body before URL Loading System delivers its first data callback.
            dataTask.cancel()
            continuation.resume(throwing: error)
        case .inactive:
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let taskKey = key(session: session, task: dataTask)
        let admission = registry.withLock { registry -> Admission in
            guard var transfer = registry.transfers.removeValue(forKey: taskKey) else {
                return .inactive
            }

            let (observedBytes, overflow) = transfer.data.count.addingReportingOverflow(data.count)
            if overflow || observedBytes > transfer.limitBytes {
                // Do not append the chunk that crosses the boundary. The retained aggregate can
                // therefore never exceed `limitBytes`, even for unknown/chunked responses.
                return .rejected(
                    transfer.continuation,
                    .exceedsLimit(
                        limitBytes: transfer.limitBytes,
                        observedBytes: overflow ? Int.max : observedBytes
                    )
                )
            }

            transfer.data.append(data)
            registry.transfers[taskKey] = transfer
            return .accepted
        }

        if case .rejected(let continuation, let error) = admission {
            dataTask.cancel()
            continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Swift.Error?
    ) {
        let taskKey = key(session: session, task: task)
        let transfer = registry.withLock { registry in
            registry.transfers.removeValue(forKey: taskKey)
        }
        guard let transfer else { return }

        if let error {
            transfer.continuation.resume(throwing: error)
        } else if let response = transfer.response {
            transfer.continuation.resume(returning: (transfer.data, response))
        } else {
            transfer.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

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
/// - 生产 public API 只能使用隔离且拒绝重定向的会话；单测通过 internal
///   `testingSession` 注入 URLProtocol fake，不打真接口。
public struct OpenAIChatClient: Sendable, CustomDebugStringConvertible, CustomReflectable {

    /// v2026.07.18 P1 privacy boundary: this public error is safe to retain or stringify.
    /// Provider response text, request payloads, API keys and arbitrary Foundation error
    /// descriptions never enter the value. User-facing layers only need stable categories and
    /// HTTP status; logs may additionally retain response byte count or a numeric transport code.
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case missingAPIKey
        case invalidBaseURL
        /// **Review fix-soon #7，2026-06-15**：用户配的 baseURL scheme 不在白名单内
        /// （只接受 `https://` 与 `http://localhost`、`http://127.0.0.1`、`http://[::1]`
        /// 本地端点）。明文 `http://` 远端会让 `Authorization: Bearer <key>` 中间节点
        /// 可见，必须拒绝。
        case insecureBaseURL(scheme: String, host: String)
        case http(status: Int, responseBytes: Int)
        case decoding
        case transport(domain: String, code: Int)

        /// Stable logging projection. Host names, provider bodies and arbitrary system error
        /// descriptions are intentionally omitted even though some are useful in live UI state.
        public var description: String {
            switch self {
            case .missingAPIKey:
                return "OpenAIChatClient.Error.missingAPIKey"
            case .invalidBaseURL:
                return "OpenAIChatClient.Error.invalidBaseURL"
            case .insecureBaseURL(let scheme, _):
                return "OpenAIChatClient.Error.insecureBaseURL(scheme=\(scheme))"
            case .http(let status, let responseBytes):
                return "OpenAIChatClient.Error.http(status=\(status), responseBytes=\(responseBytes))"
            case .decoding:
                return "OpenAIChatClient.Error.decoding"
            case .transport(let domain, let code):
                return "OpenAIChatClient.Error.transport(domain=\(domain), code=\(code))"
            }
        }
    }

    private let settings: SettingsSnapshot
    /// **v2026.06.22 (P0-4)**：apiKey 改为按需闭包拉取，避免常驻 struct 字段被 Mirror
    /// 反射或 `String(describing:)` 顺手 dump 到日志/崩溃报告里。
    /// 闭包内部典型实现：从 Keychain 取值（参考
    /// [AISettings.apiKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/AISettings.swift)）。
    /// 闭包错误必须原样上抛。尤其 Keychain 的 ACL / 存储错误不是“没有 Key”，
    /// 如果压成 `missingAPIKey`，UI 会给出错误恢复建议并掩盖真实故障。
    private let apiKeyProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let redactor: PathRedactor
    private let prompts: PromptBuilder

    /// v2026.07.18 P2 availability boundary: the requested schema contains at most an 80-character
    /// summary, a 200-character reason and short side-effect phrases. A normal compatible
    /// Chat Completions envelope is therefore KiB-scale. One MiB leaves orders of magnitude for
    /// provider metadata and nonconforming-but-diagnosable text while placing a hard upper bound
    /// on response memory retained from a user-configured endpoint.
    static let maximumResponseBytes = 1 * 1_024 * 1_024
    static let responseLimitTransportDomain = "OpenAIChatClient.ResponseLimit"
    static let responseLimitTransportCode = 1

    /// v2026.07.18 P1 diagnostic schema: stage values are closed and locale-neutral so logs stay
    /// queryable without accepting arbitrary provider/system text.
    enum NetworkLogStage: String, Sendable {
        case transport
        case responseLimit = "response-limit"
        case responseType = "response-type"
        case http
        case envelopeDecode = "envelope-decode"
        case emptyContent = "empty-content"
        case adviceDecode = "advice-decode"
    }

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
    ///
    /// v2026.07.18 P2 origin boundary fix: production callers cannot inject a URLSession and
    /// bypass the cookie, credential, cache or redirect policy. Tests use the internal
    /// `testingSession` initializer below.
    public init(settings: SettingsSnapshot,
                apiKeyProvider: @escaping @Sendable () throws -> String,
                redactor: PathRedactor = PathRedactor(),
                prompts: PromptBuilder = PromptBuilder()) {
        self.init(
            settings: settings,
            resolvedAPIKeyProvider: { try apiKeyProvider() },
            session: Self.makeIsolatedSession(),
            redactor: redactor,
            prompts: prompts
        )
    }

    /// 异步凭证入口。Keychain 等同步系统 API 应由其独立 actor 包装后从这里 `await`，
    /// 不能在 SwiftUI / MainActor 上直接执行。
    public init(settings: SettingsSnapshot,
                asyncAPIKeyProvider: @escaping @Sendable () async throws -> String,
                redactor: PathRedactor = PathRedactor(),
                prompts: PromptBuilder = PromptBuilder()) {
        self.init(
            settings: settings,
            resolvedAPIKeyProvider: asyncAPIKeyProvider,
            session: Self.makeIsolatedSession(),
            redactor: redactor,
            prompts: prompts
        )
    }

    /// 兼容旧 callsite：直接传字符串 apiKey。新代码请用 `apiKeyProvider:` 闭包入口。
    public init(settings: SettingsSnapshot,
                apiKey: String,
                redactor: PathRedactor = PathRedactor(),
                prompts: PromptBuilder = PromptBuilder()) {
        self.init(settings: settings,
                  apiKeyProvider: { apiKey },
                  redactor: redactor,
                  prompts: prompts)
    }

    /// v2026.07.18 P2 test seam: URLSession injection is intentionally internal so an
    /// `@testable` target can install URLProtocol fixtures without exporting a production policy
    /// bypass. Callers outside AIKit cannot select this overload.
    init(settings: SettingsSnapshot,
         apiKeyProvider: @escaping @Sendable () throws -> String,
         testingSession: URLSession,
         redactor: PathRedactor = PathRedactor(),
         prompts: PromptBuilder = PromptBuilder()) {
        self.init(
            settings: settings,
            resolvedAPIKeyProvider: { try apiKeyProvider() },
            session: testingSession,
            redactor: redactor,
            prompts: prompts
        )
    }

    /// Internal async-credential counterpart of the URLProtocol test seam above.
    init(settings: SettingsSnapshot,
         asyncAPIKeyProvider: @escaping @Sendable () async throws -> String,
         testingSession: URLSession,
         redactor: PathRedactor = PathRedactor(),
         prompts: PromptBuilder = PromptBuilder()) {
        self.init(
            settings: settings,
            resolvedAPIKeyProvider: asyncAPIKeyProvider,
            session: testingSession,
            redactor: redactor,
            prompts: prompts
        )
    }

    /// Internal literal-key counterpart of the URLProtocol test seam above.
    init(settings: SettingsSnapshot,
         apiKey: String,
         testingSession: URLSession,
         redactor: PathRedactor = PathRedactor(),
         prompts: PromptBuilder = PromptBuilder()) {
        self.init(
            settings: settings,
            apiKeyProvider: { apiKey },
            testingSession: testingSession,
            redactor: redactor,
            prompts: prompts
        )
    }

    private init(
        settings: SettingsSnapshot,
        resolvedAPIKeyProvider: @escaping @Sendable () async throws -> String,
        session: URLSession,
        redactor: PathRedactor,
        prompts: PromptBuilder
    ) {
        self.settings = settings
        self.apiKeyProvider = resolvedAPIKeyProvider
        self.session = session
        self.redactor = redactor
        self.prompts = prompts
    }

    /// v2026.07.18 privacy root fix: `URLSession.shared` inherits the process-wide default
    /// cookie, credential and on-disk cache stores. A user-configured model host could therefore
    /// create local network state outside the AI settings/Keychain removal contract or attach a
    /// response cookie to a later request. The production default is now isolated, refuses
    /// cookies/cache/credential persistence, and rejects every HTTP redirect before a follow-up
    /// request is created. Injected protocol classes keep deterministic URLProtocol testing
    /// available without weakening the production session policy.
    static func makeIsolatedSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(
            configuration: configuration,
            delegate: OpenAIChatRedirectRejectingDelegate.shared,
            delegateQueue: nil
        )
    }

    /// v2026.07.18 P1 introspection boundary: `SettingsSnapshot` is caller-controlled and remains
    /// untrusted until `ask()` validates it. Debug output therefore exposes only a stable state
    /// marker, never raw baseURL/model/userinfo/query/fragment or credential-provider captures.
    public var debugDescription: String {
        "OpenAIChatClient(settings=<configured>, apiKey=<redacted>)"
    }

    /// v2026.07.18 P1: Mirror keeps the session seam used by policy tests, but replaces the whole
    /// unvalidated settings snapshot with a stable marker and never reflects the key provider.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "settings": "<configured>",
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
        let url = try Self.endpointURL(baseURL: settings.baseURL)
        // **v2026.06.22 (P0-4)**：按需取 key，不在 struct 字段常驻
        let apiKey: String
        do {
            apiKey = try await apiKeyProvider()
        } catch is CancellationError {
            // 本地免鉴权端点只允许忽略“凭证不可用”，不能吞掉父任务取消。
            // 否则用户关闭 AI sheet 后仍会继续构造并发送一次本地请求。
            throw CancellationError()
        } catch {
            guard Self.allowsMissingAPIKey(forEndpoint: url) else {
                throw error
            }
            apiKey = ""
        }
        guard !apiKey.isEmpty || Self.allowsMissingAPIKey(forEndpoint: url) else {
            throw Error.missingAPIKey
        }

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
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
                request: request,
                responseLimitBytes: Self.maximumResponseBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let boundedError as OpenAIChatBoundedResponseError {
            let limitBytes: Int
            let observedBytes: Int
            switch boundedError {
            case .exceedsLimit(let limit, let observed):
                limitBytes = limit
                observedBytes = observed
            }
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .responseLimit,
                responseBytes: observedBytes,
                responseLimitBytes: limitBytes
            )
            GSYLog.warning(
                .settings,
                "[AIKit] response rejected \(facts)"
            )
            // Preserve the established public error surface. The stable domain/code pair is a
            // typed, body-free category that AppUI already handles as a transport failure.
            throw Error.transport(
                domain: Self.responseLimitTransportDomain,
                code: Self.responseLimitTransportCode
            )
        } catch {
            let underlying = error as NSError
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .transport,
                transportDomain: underlying.domain,
                transportCode: underlying.code
            )
            GSYLog.warning(
                .settings,
                "[AIKit] request failed \(facts)"
            )
            throw Error.transport(domain: underlying.domain, code: underlying.code)
        }
        guard let http = response as? HTTPURLResponse else {
            let domain = "OpenAIChatClient.Response"
            let code = 1
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .responseType,
                transportDomain: domain,
                transportCode: code
            )
            GSYLog.warning(
                .settings,
                "[AIKit] request failed \(facts)"
            )
            throw Error.transport(domain: domain, code: code)
        }
        guard (200..<300).contains(http.statusCode) else {
            // v2026.07.18 P1 privacy fix: provider text may echo the prompt, API key or paths.
            // Do not decode or attach it to Error at all; status and byte count are sufficient
            // typed diagnostics and remain safe if a caller persists String(describing: error).
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .http,
                status: http.statusCode,
                responseBytes: data.count
            )
            GSYLog.warning(
                .settings,
                "[AIKit] request failed \(facts)"
            )
            throw Error.http(status: http.statusCode, responseBytes: data.count)
        }

        // 5. 解析 chat 响应
        let envelope: ChatResponse
        do {
            envelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .envelopeDecode,
                responseBytes: data.count
            )
            GSYLog.warning(
                .settings,
                "[AIKit] response failed \(facts)"
            )
            throw Error.decoding
        }
        guard let raw = envelope.choices.first?.message.content,
              !raw.isEmpty else {
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .emptyContent,
                responseBytes: data.count
            )
            GSYLog.warning(
                .settings,
                "[AIKit] response failed \(facts)"
            )
            throw Error.decoding
        }

        // 6. 解析 AIAdvice JSON（模型可能多包一层 ```json...```，做一次剥离）
        let cleaned = Self.stripCodeFence(raw)
        let advice: AIAdvice
        if let parsed = Self.tryDecodeAdvice(cleaned) {
            advice = parsed
        } else {
            let facts = Self.networkLogFacts(
                endpoint: url,
                stage: .adviceDecode,
                responseBytes: raw.utf8.count
            )
            GSYLog.warning(
                .settings,
                "[AIKit] response degraded \(facts)"
            )
            advice = .unparsable(rawText: raw)
        }

        // 7. 后置 clamp——AI 不允许覆盖本地 SafetyEngine 红线
        return AIAdviceClamp.clamp(advice, against: inquiry)
    }

    // MARK: - 工具

    /// Builds the only network diagnostic format used by this client. It extracts the validated
    /// host but never authority user info, query, path, fragment, request payload or response
    /// body. Optional fields are numeric or NSError's stable domain/code pair.
    static func networkLogFacts(
        endpoint: URL,
        stage: NetworkLogStage,
        status: Int? = nil,
        responseBytes: Int? = nil,
        responseLimitBytes: Int? = nil,
        transportDomain: String? = nil,
        transportCode: Int? = nil
    ) -> String {
        let host = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )?.host?.lowercased() ?? "unknown"
        var fields = ["endpointHost=\(host)", "stage=\(stage.rawValue)"]
        if let status { fields.append("status=\(status)") }
        if let responseBytes { fields.append("responseBytes=\(responseBytes)") }
        if let responseLimitBytes { fields.append("responseLimitBytes=\(responseLimitBytes)") }
        if let transportDomain { fields.append("transportDomain=\(transportDomain)") }
        if let transportCode { fields.append("transportCode=\(transportCode)") }
        return fields.joined(separator: " ")
    }

    /// 拼 base URL → `/v1/chat/completions`。兼容尾部带不带 `/`、带不带 `/v1`。
    ///
    /// **Review fix-soon #7，2026-06-15**：scheme 白名单。
    /// 拒绝任何非 `https://` 的远端端点；只对 `localhost` / `127.0.0.1` / `[::1]`
    /// 开 `http://` 例外（让用户能跑本地 Ollama / vLLM / LM Studio）。其它 `http://`
    /// 一律抛 `insecureBaseURL`——`Authorization: Bearer <key>` 走明文链路风险过高。
    ///
    /// v2026.07.18 P2 origin boundary fix: parse and validate the configured base as a complete
    /// origin before appending endpoint path components. User info, query, fragment, an empty
    /// host, ambiguous path separators and invalid ports are rejected rather than normalized;
    /// otherwise a visually plausible setting can send the API key or payload somewhere the
    /// user did not configure.
    public static func endpointURL(baseURL: String) throws -> URL {
        guard !baseURL.isEmpty,
              baseURL.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              baseURL.rangeOfCharacter(from: .controlCharacters) == nil,
              !baseURL.contains("\\"),
              var components = URLComponents(string: baseURL),
              let schemeValue = components.scheme,
              let hostValue = components.host,
              !hostValue.isEmpty,
              components.user == nil,
              components.password == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              components.url != nil else {
            throw Error.invalidBaseURL
        }

        let scheme = schemeValue.lowercased()
        let host = hostValue.lowercased()
        if let port = components.port, !(1...65_535).contains(port) {
            throw Error.invalidBaseURL
        }

        // URLComponents accepts `https://host:` as a URL with a nil port. Keep the authority
        // contract explicit instead of letting different URL stacks interpret the empty port.
        guard let schemeSeparator = baseURL.range(of: "://") else {
            throw Error.invalidBaseURL
        }
        let authorityAndPath = baseURL[schemeSeparator.upperBound...]
        let authorityEnd = authorityAndPath.firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? authorityAndPath.endIndex
        let authority = authorityAndPath[..<authorityEnd]
        guard !authority.isEmpty, !authority.hasSuffix(":") else {
            throw Error.invalidBaseURL
        }

        switch scheme {
        case "https":
            break
        case "http":
            // 只放行本机环回地址
            guard Self.loopbackHosts.contains(host) else {
                throw Error.insecureBaseURL(scheme: scheme, host: host)
            }
        default:
            throw Error.insecureBaseURL(scheme: scheme, host: host)
        }

        let encodedPath = components.percentEncodedPath.lowercased()
        let decodedPath = components.path
        guard decodedPath.isEmpty || decodedPath.hasPrefix("/"),
              !decodedPath.contains("//"),
              !encodedPath.contains("%2f"),
              !encodedPath.contains("%5c") else {
            throw Error.invalidBaseURL
        }

        var pathSegments = decodedPath.split(separator: "/").map(String.init)
        guard !pathSegments.contains(where: { $0 == "." || $0 == ".." }) else {
            throw Error.invalidBaseURL
        }

        let completeEndpoint = ["v1", "chat", "completions"]
        if !pathSegments.suffix(completeEndpoint.count).elementsEqual(completeEndpoint) {
            if pathSegments.last == "v1" {
                pathSegments.append(contentsOf: ["chat", "completions"])
            } else {
                pathSegments.append(contentsOf: completeEndpoint)
            }
        }

        components.scheme = scheme
        components.path = "/" + pathSegments.joined(separator: "/")
        guard let endpoint = components.url else {
            throw Error.invalidBaseURL
        }
        return endpoint
    }

    /// 本机环回 host 白名单（用于 baseURL scheme 校验放行 http://localhost）。
    private static let loopbackHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]"
    ]

    public static func allowsMissingAPIKey(baseURL: String) throws -> Bool {
        try allowsMissingAPIKey(forEndpoint: endpointURL(baseURL: baseURL))
    }

    private static func allowsMissingAPIKey(forEndpoint url: URL) -> Bool {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() else {
            return false
        }
        return loopbackHosts.contains(host)
    }

    /// v2026.07.18 P2 root fix: the session's data delegate receives and caps chunks; this method
    /// only owns the cancellation bridge. `OpenAIChatTaskCancellationOwnership` linearizes the
    /// cancel-before-install and install-before-cancel schedules, and the delegate registry owns
    /// the checked continuation until exactly one terminal callback or size rejection removes it.
    static func dataWithCancellation(
        session: URLSession,
        request: URLRequest,
        responseLimitBytes: Int
    ) async throws -> (Data, URLResponse) {
        precondition(responseLimitBytes > 0)
        let cancellationOwnership = OpenAIChatTaskCancellationOwnership()
        return try await withTaskCancellationHandler {
            defer { cancellationOwnership.finish() }
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    guard let delegate = session.delegate as? OpenAIChatRedirectRejectingDelegate else {
                        continuation.resume(throwing: URLError(.unsupportedURL))
                        return
                    }

                    let dataTask = session.dataTask(with: request)
                    guard delegate.register(
                        session: session,
                        task: dataTask,
                        limitBytes: responseLimitBytes,
                        continuation: continuation
                    ) else {
                        dataTask.cancel()
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }

                    _ = cancellationOwnership.install {
                        dataTask.cancel()
                    }
                    // A task cancelled while still suspended needs one resume to drive the URL
                    // loading completion callback that settles the registered continuation.
                    dataTask.resume()
                }
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw error
            }
        } onCancel: {
            cancellationOwnership.requestCancellation()
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
