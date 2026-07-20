import SwiftUI
import AIKit
import SafetyKit
import LogKit

/// M5 / 2026-06：AI 询问结果展示 Sheet。
///
/// 触发：用户在 [RowView contextMenu](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowView.swift)
/// 点击"问 AI"。
///
/// 状态机：
/// - .idle / .loading：onAppear 立刻 fire 一次请求
/// - .success(advice)：展示三段（summary / 删除建议 / 原因 + 副作用列表）
/// - .failure(message)：展示错误 + 友好提示（最常见：无 API Key / 401 / 网络）
///
/// **重要边界**：
/// - 这里**只展示**，不改任何 RowItem.selected 状态；
/// - 即便 AI 说 "safe"，UI 也不会自动勾上——本地三档闸是唯一勾选权威。
struct AIAdviceSheet: View {
    @Environment(\.locale) private var locale

    let row: RowItem
    @ObservedObject var aiSettings: AISettings
    let onClose: () -> Void

    @State private var state: PhaseState = .idle

    enum PhaseState {
        case idle
        case loading
        case success(AIAdvice)
        case failure(FailurePresentation)
    }

    /// v2026.07.15：请求失败可能在 sheet 内停留很久；状态只保存错误种类与安全参数，
    /// 不保存启动语言下翻译出的 String。
    /// v2026.07.16：服务 body、transport 文本与未知 Error 不再进入用户界面。
    /// v2026.07.18：它们也不得进入技术日志；日志只保留 status、字节数或 transport code。
    enum FailurePresentation: Equatable, Sendable {
        case notConfigured
        case invalidBaseURL
        case insecureBaseURL(scheme: String, host: String)
        case missingAPIKey
        case keychain(KeychainUserFacingError.Presentation)
        case http(status: Int)
        case transport
        case unexpected

        func localizedMessage(locale: Locale) -> String {
            switch self {
            case .notConfigured:
                return AppLocalization.string("ai.sheet.error.not_configured", locale: locale)
            case .invalidBaseURL:
                return AppLocalization.string("ai.sheet.error.invalid_base_url", locale: locale)
            case .insecureBaseURL(let scheme, let host):
                return AppLocalization.format(
                    "ai.sheet.error.insecure_base_url.format",
                    locale: locale,
                    arguments: [scheme, host]
                )
            case .missingAPIKey:
                return AppLocalization.string("ai.sheet.error.no_api_key", locale: locale)
            case .keychain(let presentation):
                return presentation.localizedMessage(locale: locale)
            case .http(let status):
                return AppLocalization.format(
                    "ai.sheet.error.http.status %lld",
                    locale: locale,
                    arguments: [Int64(status)]
                )
            case .transport:
                return AppLocalization.string("ai.sheet.error.transport", locale: locale)
            case .unexpected:
                return AppLocalization.string("ai.sheet.error.unexpected", locale: locale)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding()
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .task { await runIfNeeded() }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ai.sheet.title", bundle: .module)
                    .font(.headline)
                Text(verbatim: row.displayTitle(locale: locale))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Text(row.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("ai.sheet.loading", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .success(let advice):
            VStack(alignment: .leading, spacing: 14) {
                // 摘要
                if advice.summary == AIAdvice.unparsableSummaryKey {
                    Text(LocalizedStringKey(AIAdvice.unparsableSummaryKey), bundle: .module)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: advice.summary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 三档徽章
                HStack(spacing: 8) {
                    verdictBadge(advice.canDelete)
                    Text(verdictLabel(advice.canDelete))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }

                // 原因
                if !advice.reason.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.sheet.reason", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: localizedReason(advice.reason))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 副作用
                if !advice.sideEffects.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.sheet.side_effects", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(advice.sideEffects, id: \.self) { eff in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(eff)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                // 红线提示——AI 建议仅供参考，本地三档闸是最终权威
                Text("ai.sheet.disclaimer", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

        case .failure(let failure):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("ai.sheet.failed.title", bundle: .module)
                        .font(.headline)
                }
                Text(verbatim: failure.localizedMessage(locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if case .failure = state {
                Button {
                    state = .idle
                    Task { await runIfNeeded() }
                } label: {
                    Text("ai.sheet.retry", bundle: .module)
                }
            }
            Button {
                onClose()
            } label: {
                Text("ai.sheet.close", bundle: .module)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    /// 识别 AIKit 暴露的本地策略覆盖 sentinel 前缀，替换为本地化文案。
    private func localizedReason(_ reason: String) -> String {
        let prefix = AIAdviceClamp.localPolicyOverridePrefix
        guard reason.hasPrefix(prefix) else { return reason }
        let tail = String(reason.dropFirst(prefix.count))
        let localizedPrefix = AppLocalization.string(
            "ai.advice.local_policy_override.prefix",
            locale: locale
        )
        return localizedPrefix + tail
    }

    // MARK: - 行为

    private func runIfNeeded() async {
        if case .loading = state { return }
        if case .success = state { return }
        state = .loading
        guard aiSettings.isReadyForUI else {
            state = .failure(.notConfigured)
            return
        }
        // 异步：抓 API Key + 拼 inquiry + 发请求
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: aiSettings.baseURL,
            model: aiSettings.model,
            temperature: aiSettings.temperature,
            redactPaths: aiSettings.redactPaths
        )
        let authOptional: Bool
        do {
            authOptional = try OpenAIChatClient.allowsMissingAPIKey(baseURL: snapshot.baseURL)
        } catch OpenAIChatClient.Error.invalidBaseURL {
            state = .failure(.invalidBaseURL)
            return
        } catch OpenAIChatClient.Error.insecureBaseURL(let scheme, let host) {
            state = .failure(.insecureBaseURL(scheme: scheme, host: host))
            return
        } catch {
            GSYLog.warning(
                .operation,
                "AI advice endpoint validation failed kind=unexpected"
            )
            state = .failure(.unexpected)
            return
        }
        let apiKey: String
        do {
            let raw = try await KeychainAPIKeyStore.shared.load() ?? ""
            guard !raw.isEmpty || authOptional else {
                state = .failure(.missingAPIKey)
                return
            }
            apiKey = raw
        } catch {
            if authOptional {
                apiKey = ""
            } else {
                state = .failure(.keychain(KeychainUserFacingError.presentation(for: error)))
                return
            }
        }

        // 异步采子项预览，避免在 main 上阻塞
        let path = row.url.path
        let isDir = row.isDirectory
        let preview: [String] = await Task.detached(priority: .userInitiated) {
            guard isDir else { return [] }
            return PathInquiry.sampleChildren(at: path, limit: 5)
        }.value

        let inquiry = PathInquiry(
            path: path,
            isDirectory: isDir,
            bytes: row.bytes,
            fileCount: row.fileCount,
            modificationDate: row.modificationDate,
            verdict: row.verdict,
            // AI is a presentation consumer too: resolve locale-neutral rule metadata at request
            // time instead of forwarding whichever language happened to be active during scan.
            vendorName: row.displayVendorName(locale: locale),
            vendorNote: row.displayVendorNote(locale: locale),
            childPreview: preview
        )

        let client = OpenAIChatClient(settings: snapshot, apiKey: apiKey)
        do {
            let advice = try await client.ask(inquiry)
            state = .success(advice)
        } catch let OpenAIChatClient.Error.http(status, _) {
            // v2026.07.18：OpenAIChatClient.Error 不再携带 body；UI 只投影 status。
            state = .failure(.http(status: status))
        } catch let OpenAIChatClient.Error.transport(domain, code) {
            GSYLog.warning(
                .operation,
                "AI advice transport failed domain=\(domain) code=\(code)"
            )
            state = .failure(.transport)
        } catch OpenAIChatClient.Error.decoding {
            GSYLog.warning(.operation, "AI advice request failed kind=decoding")
            state = .failure(.unexpected)
        } catch OpenAIChatClient.Error.missingAPIKey {
            state = .failure(.missingAPIKey)
        } catch OpenAIChatClient.Error.invalidBaseURL {
            state = .failure(.invalidBaseURL)
        } catch OpenAIChatClient.Error.insecureBaseURL(let scheme, let host) {
            state = .failure(.insecureBaseURL(scheme: scheme, host: host))
        } catch {
            GSYLog.warning(
                .operation,
                "AI advice request failed kind=unexpected"
            )
            state = .failure(.unexpected)
        }
    }

    // MARK: - 渲染辅助

    @ViewBuilder
    private func verdictBadge(_ v: SafetyVerdict) -> some View {
        Circle()
            .fill(verdictColor(v))
            .frame(width: 10, height: 10)
    }

    private func verdictColor(_ v: SafetyVerdict) -> Color {
        switch v {
        case .safe: return .green
        case .confirm: return .yellow
        case .forbid: return .red
        }
    }

    private func verdictLabel(_ v: SafetyVerdict) -> String {
        switch v {
        case .safe: return AppLocalization.string("ai.sheet.verdict.safe", locale: locale)
        case .confirm: return AppLocalization.string("ai.sheet.verdict.confirm", locale: locale)
        case .forbid: return AppLocalization.string("ai.sheet.verdict.forbid", locale: locale)
        }
    }
}
