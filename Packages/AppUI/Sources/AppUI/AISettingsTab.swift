import SwiftUI
import AIKit
import Combine

/// v2026.07.15：AI 设置页保存语义反馈而不是已翻译 String。状态跨语言切换保持不变，
/// View 每次按当前环境 locale 解析，避免“保存成功/Keychain 错误”停留在启动语言。
enum AISettingsAPIKeyFeedback: Equatable, Sendable {
    case saved
    case removed
    case failure(KeychainUserFacingError.Presentation)

    func localizedMessage(locale: Locale) -> String {
        switch self {
        case .saved:
            return AppLocalization.string("settings.ai.api_key.saved", locale: locale)
        case .removed:
            return AppLocalization.string("settings.ai.api_key.removed", locale: locale)
        case .failure(let presentation):
            return presentation.localizedMessage(locale: locale)
        }
    }
}

/// AI 设置页的瞬态编辑会话。
///
/// v2026.07.16：Ventura 兼容设置页使用 NavigationSplitView，未选中的 detail 会离开
/// View 树。由 SettingsScene 以 StateObject 持有本对象，确保侧栏切换不丢未保存 Key、
/// 不重复读取 Keychain，并让同步 Keychain I/O 始终停留在 AIKit actor 而非主线程。
@MainActor
final class AISettingsTabState: ObservableObject {
    @Published var apiKeyInput = ""
    @Published private(set) var storedKeyMasked = ""
    @Published private(set) var feedback: AISettingsAPIKeyFeedback?
    @Published private(set) var isKeychainBusy = false

    private let keyStore: KeychainAPIKeyStore
    private var hasAttemptedInitialLoad = false

    init(keyStore: KeychainAPIKeyStore = .shared) {
        self.keyStore = keyStore
    }

    func refreshMaskedKeyIfNeeded() async {
        guard !hasAttemptedInitialLoad, !isKeychainBusy else { return }
        hasAttemptedInitialLoad = true
        isKeychainBusy = true
        defer { isKeychainBusy = false }
        do {
            let raw = try await keyStore.load()
            storedKeyMasked = KeychainAPIKeyStore.masked(raw)
        } catch {
            feedback = .failure(KeychainUserFacingError.presentation(for: error))
        }
    }

    func saveKey() async {
        guard !isKeychainBusy, !apiKeyInput.isEmpty else { return }
        let submittedKey = apiKeyInput
        isKeychainBusy = true
        defer { isKeychainBusy = false }
        do {
            try await keyStore.save(submittedKey)
            let raw = try await keyStore.load()
            if apiKeyInput == submittedKey {
                apiKeyInput = ""
            }
            storedKeyMasked = KeychainAPIKeyStore.masked(raw)
            feedback = .saved
        } catch {
            feedback = .failure(KeychainUserFacingError.presentation(for: error))
        }
    }

    func removeKey() async {
        guard !isKeychainBusy else { return }
        isKeychainBusy = true
        defer { isKeychainBusy = false }
        do {
            try await keyStore.remove()
            storedKeyMasked = ""
            feedback = .removed
        } catch {
            feedback = .failure(KeychainUserFacingError.presentation(for: error))
        }
    }
}

/// M5 / 2026-06：AI 设置 Tab。
///
/// 位置：[SettingsScene](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SettingsScene.swift)
/// TabView 第 8 项（在 advancedTab 之前插入）。
///
/// 设计要点：
/// - **enabled OFF 时其它字段全部 disabled**：避免用户改了 baseURL/model 却没启用反而困惑；
/// - **API Key 单独一行 SecureField + 保存/清除按钮**：与 baseURL/model 的 didSet 持久化不同，
///   key 走 Keychain，必须显式按"保存"才落盘，避免输入到一半就 commit；
/// - **redactPaths 关闭时给红字警告**：默认 ON，关闭意味着用户名/UUID/邮箱会原样发给模型端；
/// - **不内嵌"测试连接"按钮**：测试 = 发一次 chat 请求 = 消耗一次 token，
///   按需触发场景下用户在主列表右键"问 AI"那一刻就是天然的连通性测试，无须重复。
struct AISettingsTab: View {

    @Environment(\.locale) private var locale
    @ObservedObject var settings: AISettings
    @ObservedObject var state: AISettingsTabState

    init(settings: AISettings, state: AISettingsTabState) {
        self._settings = ObservedObject(wrappedValue: settings)
        self._state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        Form {
            // MARK: 如何使用（v2026.06.18 加）
            // 用户反馈：填了 API Key 后不知道功能从哪进入。这里给一段可见性极高的
            // 三步指引，并在总开关 OFF 时给一条额外提示，避免「填了 key 但开关没开」
            // 的隐藏失败模式（[isReadyForUI](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/AISettings.swift)
            // 在 enabled==false 时返回 false → contextMenu "问 AI" 不显示）。
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.ai.howto.step1", bundle: .module)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("settings.ai.howto.step2", bundle: .module)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("settings.ai.howto.step3", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !settings.enabled {
                        Label {
                            Text("settings.ai.howto.disabled_hint", bundle: .module)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 2)
                    }
                }
            } header: {
                Text("settings.ai.howto.title", bundle: .module)
            }

            // MARK: 总开关
            Section {
                Toggle(isOn: $settings.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.ai.enabled.title", bundle: .module)
                        Text("settings.ai.enabled.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("settings.ai.section.toggle", bundle: .module)
            }

            // MARK: 端点配置
            Section {
                LabeledContent {
                    TextField("", text: $settings.baseURL, prompt: Text(verbatim: AISettings.defaultBaseURL))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(minWidth: 280)
                } label: {
                    Text("settings.ai.base_url.title", bundle: .module)
                }
                LabeledContent {
                    TextField("", text: $settings.model, prompt: Text(verbatim: AISettings.defaultModel))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(minWidth: 280)
                } label: {
                    Text("settings.ai.model.title", bundle: .module)
                }
                Text("settings.ai.endpoint.detail", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.ai.section.endpoint", bundle: .module)
            }
            .disabled(!settings.enabled)

            // MARK: API Key
            Section {
                LabeledContent {
                    SecureField("", text: $state.apiKeyInput, prompt: Text(verbatim: "sk-..."))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 280)
                } label: {
                    Text("settings.ai.api_key.title", bundle: .module)
                }
                HStack {
                    Text(state.storedKeyMasked.isEmpty
                         ? AppLocalization.string("settings.ai.api_key.empty", locale: locale)
                         : state.storedKeyMasked)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await state.saveKey() }
                    } label: {
                        Text("settings.ai.api_key.save", bundle: .module)
                    }
                    .disabled(state.apiKeyInput.isEmpty || state.isKeychainBusy)
                    Button(role: .destructive) {
                        Task { await state.removeKey() }
                    } label: {
                        Text("settings.ai.api_key.remove", bundle: .module)
                    }
                    .disabled(state.storedKeyMasked.isEmpty || state.isKeychainBusy)
                }
                if let feedback = state.feedback {
                    Text(feedback.localizedMessage(locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.ai.section.api_key", bundle: .module)
            } footer: {
                Text("settings.ai.api_key.footer", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.enabled)

            // MARK: 高级
            Section {
                Toggle(isOn: $settings.redactPaths) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.ai.redact.title", bundle: .module)
                        Text("settings.ai.redact.detail", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !settings.redactPaths {
                    Text("settings.ai.redact.warning", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("settings.ai.temperature.title", bundle: .module)
                    Spacer()
                    Stepper(value: $settings.temperature, in: 0.0...1.0, step: 0.1) {
                        EmptyView()
                    }
                    .labelsHidden()
                    Text(String(format: "%.1f", settings.temperature))
                        .monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                }
            } header: {
                Text("settings.ai.section.advanced", bundle: .module)
            }
            .disabled(!settings.enabled)
        }
        .formStyle(.grouped)
        .padding()
        .task { await state.refreshMaskedKeyIfNeeded() }
    }
}
