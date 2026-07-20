import Combine
import Foundation
import AIKit
import SafetyKit
import LogKit

/// v2026.06.19 **稍后处理 · 一键 AI 队列引擎**。
///
/// 设计目标：把 [StashStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift)
/// 当前所有条目按"加入顺序"**串行**送进 [OpenAIChatClient.ask](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)，
/// 把结果（AI canDelete verdict / 失败原因）逐条回填到 store，让
/// [StashScreen](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashScreen.swift)
/// 行内显示 ✓ / ? / ✕ 徽标，footer 显示 ProgressView + "3 / 12 · 正在询问 xxx"。
///
/// 为什么是 **串行**：
/// - 免费/低 tier LLM 端点（OpenAI free / DeepSeek / 本地 Ollama）一并发就 429；
/// - 用户期望"一条一条出结果"的视觉节奏比"全部转圈再爆 12 条结果"更可控；
/// - 串行可在每条之间安全检测 `Task.isCancelled`，取消语义清晰；
/// - 复杂度低——无需 TaskGroup / Semaphore / 节流器；
/// - **代价**：12 条 × 6s ≈ 72s。Footer 进度条 + 单条耗时可见，用户不会失联。
///
/// 状态机：
/// ```
///   .idle ──start──▶ .running ──finish──▶ .idle
///                       │
///                       └──cancel──▶ .idle（已完成项保留 verdict）
/// ```
///
/// 失败处理：
/// - 单条抛错 → 写入 typed `.error(failure)` 到 store.entries[i].aiVerdict，**继续下一条**；
/// - 全局错误（invalidBaseURL / insecureBaseURL / missingAPIKey 在 start 前做一次预检）
///   → 整队列拒发 + 暴露 `lastGlobalError`，UI 直接展示错误条，不进 running 态。
/// v2026.07.16：队列只发布用户可见进度，任务句柄继续保持内部状态，兼容 macOS 13.5。
@MainActor
public final class StashAIQueue: ObservableObject {

    public enum Phase: Equatable, Sendable {
        case idle
        case running
    }

    /// v2026.07.15：全局预检错误可能在 footer 中持续显示；这里仅保存错误语义与
    /// 安全技术参数，不保存启动语言下生成的 String。StashScreen 按当前 locale 投影。
    public enum GlobalError: Equatable, Sendable {
        public enum CredentialStorageFailure: Equatable, Sendable {
            case staleFileReference
            case system(technicalDetail: String)
            case unknown
        }

        case notConfigured
        case invalidBaseURL
        case insecureBaseURL(scheme: String, host: String)
        case missingAPIKey
        case credentialStorage(CredentialStorageFailure)
        case unknown
    }

    /// 当前阶段；UI 决定按钮是渲染 "一键 AI" 还是 ProgressView。
    @Published public private(set) var phase: Phase = .idle

    /// 已处理条数（含成功 + 失败）。UI 进度文案：`processed / total`。
    @Published public private(set) var processed: Int = 0

    /// 本次队列总数（start 时一次性 snapshot store.entries.count，
    /// 跑过程中即使用户继续 add 新条目，本次 batch 也按 snapshot 走，
    /// 避免"永远跑不完"——下一轮 start 会重新 snapshot）。
    @Published public private(set) var total: Int = 0

    /// 正在询问中的条目 path（仅展示用，nil 表示空闲）。
    @Published public private(set) var currentPath: String? = nil

    /// 最近一次"全局"失败原因（baseURL / apiKey / scheme 等 start 前的预检失败）。
    /// 单条失败**不**写到这里——单条失败已逐项写入 store.entries[i].aiVerdict。
    @Published public private(set) var lastGlobalError: GlobalError? = nil

    private var runTask: Task<Void, Never>? = nil

    public init() {}

    /// 启动队列。重入安全——若已在 running，直接 no-op。
    /// - Parameters:
    ///   - stash: 共享购物车（写回 verdict）
    ///   - aiSettings: 取 snapshot 用，不持有引用跨 actor
    ///   - clientFactory: 注入点；默认走真正的 OpenAIChatClient + Keychain，
    ///     单测时可换成 mock 直接返回 AIAdvice。
    public func start(
        stash: StashStore,
        aiSettings: AISettings,
        clientFactory: (() throws -> OpenAIChatClient)? = nil
    ) {
        guard phase == .idle else { return }
        lastGlobalError = nil

        // 预检：未开 AI 或 key/url 不全直接拒发——比循环里第一次抛错友好得多。
        guard aiSettings.isReadyForUI else {
            lastGlobalError = .notConfigured
            return
        }

        // 一次性 snapshot：列表跑过程中可继续 add/remove，但本次 batch 只跑 snapshot 中的。
        let snapshotPaths: [String] = stash.entries.map(\.path)
        guard !snapshotPaths.isEmpty else { return }

        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: aiSettings.baseURL,
            model: aiSettings.model,
            temperature: aiSettings.temperature,
            redactPaths: aiSettings.redactPaths
        )

        // 先进入 running，再在任务内异步读取 Keychain。这样同步 SecItem I/O 永远不会
        // 卡住点击事件所在的 MainActor，同时也用 phase 锁住重复启动。
        phase = .running
        processed = 0
        total = snapshotPaths.count
        currentPath = nil

        runTask = Task { [stash] in
            let client: OpenAIChatClient
            do {
                client = try await Self.makeClient(snapshot: snapshot, factory: clientFactory)
                try Task.checkCancellation()
            } catch is CancellationError {
                self.finishRun()
                return
            } catch {
                self.finishPreparationFailure(error)
                return
            }

            // 串行循环
            for path in snapshotPaths {
                if Task.isCancelled { break }

                // 当前条目可能已被用户在 sheet 内剔除——跳过（不算 processed++）。
                guard let entry = stash.entries.first(where: { $0.id == path }) else {
                    continue
                }

                self.currentPath = entry.path

                // 异步采子项预览
                let isDir = entry.isDirectory
                let p = entry.path
                let preview: [String] = await Task.detached(priority: .userInitiated) {
                    guard isDir else { return [] }
                    return PathInquiry.sampleChildren(at: p, limit: 5)
                }.value

                // 走本地 SafetyEngine 拿初判；与 AIAdviceSheet 行为一致
                let (verdict, _) = StashAIQueue.safety.evaluate(path: entry.path)
                let inquiry = PathInquiry(
                    path: entry.path,
                    isDirectory: entry.isDirectory,
                    bytes: entry.bytes,
                    fileCount: 0,
                    modificationDate: nil,
                    verdict: verdict,
                    vendorName: nil,
                    vendorNote: nil,
                    childPreview: preview
                )

                do {
                    let advice = try await client.ask(inquiry)
                    stash.setAIVerdict(path: entry.path,
                                       verdict: .done(advice.canDelete,
                                                      summary: advice.summary))
                } catch is CancellationError {
                    // 用户点了取消——保留本条 .pending（不写 verdict），跳出循环
                    break
                } catch {
                    // v2026.07.18 P1 privacy fix: both UI state and rolling logs receive only
                    // typed facts. Redaction is not a sufficient boundary for arbitrary provider
                    // bodies or Error descriptions because secrets need not look like paths.
                    let failure = StashAIQueue.itemFailure(error)
                    let diagnostic = StashAIQueue.loggingFacts(for: error)
                    stash.setAIVerdict(path: entry.path, verdict: .error(failure))
                    GSYLog.warning(.settings, "[StashAIQueue] ask failed: \(diagnostic)")
                }

                self.processed += 1
                if Task.isCancelled { break }
            }

            // 结束（无论 finish / cancel）—— 清状态、回到 idle
            self.finishRun()
        }
    }

    /// 取消队列。已得到的 verdict 保留；当前在途请求会通过
    /// [OpenAIChatClient.dataWithCancellation](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift#L269-L307)
    /// 立即断 HTTP 连接。
    public func cancel() {
        runTask?.cancel()
    }

    // MARK: - 内部

    /// 共享 SafetyEngine 实例——与 [TreeBrowserView.safety](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L57)
    /// 对齐，不重复构建。
    private static let safety = SafetyEngine()

    /// 默认 client 工厂：从 Keychain 取 key + 拼 SettingsSnapshot；
    /// 单测可通过 `clientFactory` 注入替换。
    private static func makeClient(
        snapshot: OpenAIChatClient.SettingsSnapshot,
        factory: (() throws -> OpenAIChatClient)?
    ) async throws -> OpenAIChatClient {
        if let factory { return try factory() }
        // 先校验 baseURL & scheme
        let authOptional = try OpenAIChatClient.allowsMissingAPIKey(baseURL: snapshot.baseURL)
        let raw: String
        do {
            raw = try await KeychainAPIKeyStore.shared.load() ?? ""
        } catch {
            if authOptional {
                raw = ""
            } else {
                throw error
            }
        }
        if raw.isEmpty && !authOptional {
            throw OpenAIChatClient.Error.missingAPIKey
        }
        return OpenAIChatClient(settings: snapshot, apiKey: raw)
    }

    private func finishPreparationFailure(_ error: any Error) {
        lastGlobalError = Self.globalError(for: error)
        finishRun()
    }

    /// 纯语义映射供聚焦测试覆盖；不读取 locale，也不触发网络或 Keychain IO。
    static func globalError(for error: any Error) -> GlobalError {
        switch error {
        case OpenAIChatClient.Error.invalidBaseURL:
            return .invalidBaseURL
        case OpenAIChatClient.Error.insecureBaseURL(let scheme, let host):
            return .insecureBaseURL(scheme: scheme, host: host)
        case OpenAIChatClient.Error.missingAPIKey:
            return .missingAPIKey
        case is KeychainAPIKeyStoreError:
            switch KeychainUserFacingError.presentation(for: error) {
            case .staleFileReference:
                return .credentialStorage(.staleFileReference)
            case .system(let technicalDetail):
                return .credentialStorage(.system(technicalDetail: technicalDetail))
            case .unknown:
                return .credentialStorage(.unknown)
            }
        default:
            return .unknown
        }
    }

    private func finishRun() {
        currentPath = nil
        phase = .idle
        runTask = nil
    }

    /// v2026.07.18 P1 logging contract: never stringify an arbitrary Error. Known AI errors
    /// already expose a stable body-free description; unknown failures collapse to one constant
    /// category so provider payloads, credentials and paths cannot reach the rolling file.
    static func loggingFacts(for error: any Error) -> String {
        guard let clientError = error as? OpenAIChatClient.Error else {
            return "OpenAIChatClient.Error.unexpected"
        }
        return clientError.description
    }

    /// v2026.07.16：把任意 Error 压成稳定语义。这里刻意不返回 String，避免异步状态
    /// 固化启动语言或把服务端/网络实现文本带进用户界面。
    private static func itemFailure(_ error: Error) -> StashStore.AIVerdictCache.Failure {
        switch error {
        case OpenAIChatClient.Error.missingAPIKey,
             OpenAIChatClient.Error.invalidBaseURL,
             OpenAIChatClient.Error.insecureBaseURL:
            return .configuration
        case let OpenAIChatClient.Error.http(status, _):
            return .http(status: status)
        case OpenAIChatClient.Error.transport:
            return .transport
        case OpenAIChatClient.Error.decoding:
            return .decoding
        default:
            return .unexpected
        }
    }
}
