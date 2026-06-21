import Foundation
import Observation
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
/// - 单条抛错 → 写入 `.error(message)` 到 store.entries[i].aiVerdict，**继续下一条**；
/// - 全局错误（invalidBaseURL / insecureBaseURL / missingAPIKey 在 start 前做一次预检）
///   → 整队列拒发 + 暴露 `lastGlobalError`，UI 直接展示错误条，不进 running 态。
@MainActor
@Observable
public final class StashAIQueue {

    public enum Phase: Equatable, Sendable {
        case idle
        case running
    }

    /// 当前阶段；UI 决定按钮是渲染 "一键 AI" 还是 ProgressView。
    public private(set) var phase: Phase = .idle

    /// 已处理条数（含成功 + 失败）。UI 进度文案：`processed / total`。
    public private(set) var processed: Int = 0

    /// 本次队列总数（start 时一次性 snapshot store.entries.count，
    /// 跑过程中即使用户继续 add 新条目，本次 batch 也按 snapshot 走，
    /// 避免"永远跑不完"——下一轮 start 会重新 snapshot）。
    public private(set) var total: Int = 0

    /// 正在询问中的条目 path（仅展示用，nil 表示空闲）。
    public private(set) var currentPath: String? = nil

    /// 最近一次"全局"失败原因（baseURL / apiKey / scheme 等 start 前的预检失败）。
    /// 单条失败**不**写到这里——单条失败已逐项写入 store.entries[i].aiVerdict。
    public private(set) var lastGlobalError: String? = nil

    @ObservationIgnored
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
            lastGlobalError = "ai.sheet.error.not_configured"
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

        // 构造 client 失败 → 写 lastGlobalError 后退出。
        let client: OpenAIChatClient
        do {
            client = try Self.makeClient(snapshot: snapshot, factory: clientFactory)
        } catch OpenAIChatClient.Error.invalidBaseURL {
            lastGlobalError = "ai.sheet.error.invalid_base_url"
            return
        } catch OpenAIChatClient.Error.insecureBaseURL(let scheme, let host) {
            lastGlobalError = "[insecure] \(scheme)://\(host)"
            return
        } catch OpenAIChatClient.Error.missingAPIKey {
            lastGlobalError = "ai.sheet.error.no_api_key"
            return
        } catch {
            lastGlobalError = String(describing: error)
            return
        }

        // 进入 running 态
        phase = .running
        processed = 0
        total = snapshotPaths.count
        currentPath = nil

        runTask = Task { [stash] in
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
                    // 单条失败：写 .error 并继续下一条
                    let msg = StashAIQueue.shortError(error)
                    stash.setAIVerdict(path: entry.path, verdict: .error(message: msg))
                    GSYLog.warning(.settings, "[StashAIQueue] ask failed: \(msg)")
                }

                self.processed += 1
                if Task.isCancelled { break }
            }

            // 结束（无论 finish / cancel）—— 清状态、回到 idle
            self.currentPath = nil
            self.phase = .idle
            self.runTask = nil
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
    ) throws -> OpenAIChatClient {
        if let factory { return try factory() }
        // 先校验 baseURL & scheme
        let authOptional = try OpenAIChatClient.allowsMissingAPIKey(baseURL: snapshot.baseURL)
        let store = KeychainAPIKeyStore()
        let raw = (try? store.load()) ?? ""
        if raw.isEmpty && !authOptional {
            throw OpenAIChatClient.Error.missingAPIKey
        }
        return OpenAIChatClient(settings: snapshot, apiKey: raw)
    }

    /// 把任意 Error 压成"一句话错误"——UI 行内 tooltip 用，避免堆栈/巨长 body 撑爆 tooltip。
    private static func shortError(_ error: Error) -> String {
        switch error {
        case OpenAIChatClient.Error.missingAPIKey:
            return "missing api key"
        case OpenAIChatClient.Error.invalidBaseURL:
            return "invalid base url"
        case let OpenAIChatClient.Error.insecureBaseURL(scheme, host):
            return "insecure \(scheme)://\(host)"
        case let OpenAIChatClient.Error.http(status, _):
            return "http \(status)"
        case let OpenAIChatClient.Error.transport(msg):
            return "transport: \(msg.prefix(60))"
        case let OpenAIChatClient.Error.decoding(msg):
            return "decode: \(msg.prefix(60))"
        default:
            return String(describing: error).prefix(80).description
        }
    }
}
