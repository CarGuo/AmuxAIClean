import Combine
import Foundation

/// M5 / 2026-06：AI 模块用户配置（按需触发版）。
///
/// 设计要点（与 [AppSettings](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppSettings.swift) 风格保持一致）：
/// 1. 走 `UserDefaults`（生产用 `.standard`，单测可注入隔离 suite）；
/// 2. **API Key 不在这里**——由 [KeychainAPIKeyStore](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/KeychainAPIKeyStore.swift)
///    独立托管走 macOS Keychain，绝不入 UserDefaults / plist；
/// 3. **enabled 默认 OFF**——任何 UI 入口在 `enabled == false` 时都必须隐藏，
///    保证整 App 在用户没主动启用 AI 时**零网络请求**；
/// 4. `baseURL` 默认 OpenAI 官方端点；兼容任何 OpenAI 协议端（Azure / DeepSeek / OpenRouter /
///    Ollama `http://localhost:11434/v1` / vLLM / 通义），无需额外字段。
///
/// 决策来源：本仓库 [docs/MOLE_ALIGNMENT.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/MOLE_ALIGNMENT.md) §M5
/// "按需触发 AI"路线——不做缓存 / 不做 rate limiter / 不做流式 SSE，
/// 把复杂度降到"用户点 = 一次 HTTP = 一张卡片"。
/// v2026.07.16：为 macOS 13.5 兼容，状态发布统一使用 Combine；持久化后端仍不参与 UI 刷新。
@MainActor
public final class AISettings: ObservableObject {

    // MARK: - 持久化键

    public enum Keys {
        public static let enabled      = "v1.6.ai.enabled"
        public static let baseURL      = "v1.6.ai.base_url"
        public static let model        = "v1.6.ai.model"
        public static let temperature  = "v1.6.ai.temperature"
        public static let redactPaths  = "v1.6.ai.redact_paths"
    }

    // MARK: - 默认值

    public static let defaultBaseURL   = "https://api.openai.com"
    public static let defaultModel     = "gpt-4o-mini"
    public static let defaultTemperature = 0.2

    // MARK: - 后端

    private let defaults: UserDefaults

    // MARK: - 字段

    /// AI 总开关。默认 `false`——关闭时 UI 入口（[RowView contextMenu "问 AI"](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowView.swift)）必须隐藏；
    /// 任何 AI 网络请求路径都 short-circuit。
    @Published public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    /// OpenAI 协议 base URL。
    /// 不强制结尾斜杠；[OpenAIChatClient](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)
    /// 内部统一 append `/v1/chat/completions`。
    @Published public var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }

    /// 模型名。自由文本，UI 给常用项下拉但允许用户改 string。
    @Published public var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    /// temperature，默认 0.2，**偏低**——本场景要稳定 JSON 输出，不要创造性。
    @Published public var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    /// 出网前是否对路径去敏（用户名 / UUID / 邮箱）。默认 `true`——
    /// 关闭仅供高级用户调试，UI 必须给红字警告。
    @Published public var redactPaths: Bool {
        didSet { defaults.set(redactPaths, forKey: Keys.redactPaths) }
    }

    // MARK: - 构造

    public convenience init() {
        self.init(defaultsBackend: UserDefaults.standard)
    }

    public convenience init(testSuite: String) {
        self.init(defaultsBackend: UserDefaults(suiteName: testSuite) ?? .standard)
    }

    private init(defaultsBackend defaults: UserDefaults) {
        self.defaults = defaults

        // 与 AppSettings 一致：用 object(forKey:) 区分"未写入"vs"写入 false"，
        // 让首启默认值（enabled=false / redactPaths=true）能正确落地，
        // 而不会被 bool(forKey:) 的 false 默认值污染。
        if let raw = defaults.object(forKey: Keys.enabled) as? Bool {
            self.enabled = raw
        } else {
            self.enabled = false
        }
        if let raw = defaults.string(forKey: Keys.baseURL), !raw.isEmpty {
            self.baseURL = raw
        } else {
            self.baseURL = Self.defaultBaseURL
        }
        if let raw = defaults.string(forKey: Keys.model), !raw.isEmpty {
            self.model = raw
        } else {
            self.model = Self.defaultModel
        }
        if let raw = defaults.object(forKey: Keys.temperature) as? Double {
            self.temperature = raw
        } else {
            self.temperature = Self.defaultTemperature
        }
        if let raw = defaults.object(forKey: Keys.redactPaths) as? Bool {
            self.redactPaths = raw
        } else {
            self.redactPaths = true
        }
    }

    // MARK: - 便捷

    /// UI 决策：是否已具备"可以发起一次询问"的全部条件。
    /// 不读 API Key（避免 Keychain 同步 IO）；UI 在弹 sheet 那一刻再现查 Keychain，
    /// 缺 key 时显示"未配置 API Key"提示卡片，不阻塞 contextMenu 显示。
    public var isReadyForUI: Bool {
        guard enabled else { return false }
        guard !baseURL.isEmpty else { return false }
        guard !model.isEmpty else { return false }
        return true
    }
}
