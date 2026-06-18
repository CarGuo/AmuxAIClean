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

    let row: RowItem
    let aiSettings: AISettings
    let onClose: () -> Void

    @State private var state: PhaseState = .idle

    enum PhaseState {
        case idle
        case loading
        case success(AIAdvice)
        case failure(String)
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
                Text(row.title)
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
                Text(advice.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

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
                        Text(advice.reason)
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

        case .failure(let msg):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("ai.sheet.failed.title", bundle: .module)
                        .font(.headline)
                }
                Text(msg)
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

    // MARK: - 行为

    private func runIfNeeded() async {
        if case .loading = state { return }
        if case .success = state { return }
        state = .loading
        guard aiSettings.isReadyForUI else {
            state = .failure(String(localized: "ai.sheet.error.not_configured", bundle: .module))
            return
        }
        // 异步：抓 API Key + 拼 inquiry + 发请求
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: aiSettings.baseURL,
            model: aiSettings.model,
            temperature: aiSettings.temperature,
            redactPaths: aiSettings.redactPaths
        )
        let store = KeychainAPIKeyStore()
        let apiKey: String
        do {
            guard let raw = try store.load(), !raw.isEmpty else {
                state = .failure(String(localized: "ai.sheet.error.no_api_key", bundle: .module))
                return
            }
            apiKey = raw
        } catch {
            state = .failure(String(format: String(localized: "ai.sheet.error.keychain.format", bundle: .module),
                                    String(describing: error)))
            return
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
            vendorName: row.vendorName,
            vendorNote: row.vendorNote,
            childPreview: preview
        )

        let client = OpenAIChatClient(settings: snapshot, apiKey: apiKey)
        do {
            let advice = try await client.ask(inquiry)
            state = .success(advice)
        } catch let OpenAIChatClient.Error.http(status, body) {
            // **v2026.06.22 (P0-4)**：body 已在 [OpenAIChatClient](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)
            // 抛出前经 PathRedactor.redact 去敏，这里只用作 UI 展示，**不再二次 log body**——
            // 避免把脱敏前/后的内容都落到日志里增加泄漏面。OpenAIChatClient 已经 log 了
            // status + body length，已足以排障。
            state = .failure(String(format: String(localized: "ai.sheet.error.http.format", bundle: .module),
                                    status, body.prefix(160).description))
        } catch let OpenAIChatClient.Error.transport(msg) {
            state = .failure(String(format: String(localized: "ai.sheet.error.transport.format", bundle: .module), msg))
        } catch OpenAIChatClient.Error.missingAPIKey {
            state = .failure(String(localized: "ai.sheet.error.no_api_key", bundle: .module))
        } catch OpenAIChatClient.Error.invalidBaseURL {
            state = .failure(String(localized: "ai.sheet.error.invalid_base_url", bundle: .module))
        } catch {
            state = .failure(String(describing: error))
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
        case .safe: return String(localized: "ai.sheet.verdict.safe", bundle: .module)
        case .confirm: return String(localized: "ai.sheet.verdict.confirm", bundle: .module)
        case .forbid: return String(localized: "ai.sheet.verdict.forbid", bundle: .module)
        }
    }
}
