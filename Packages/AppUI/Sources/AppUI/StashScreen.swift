import SwiftUI
import AIKit
import SafetyKit

/// v2026.06.18 **稍后处理（购物车）主界面**。
///
/// 由 [MainView.toolbar](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
/// 的 `tray.full.fill` 按钮以 `.sheet` 形式弹出。承载用户从树视图陆续加入的待处理目录，
/// 提供"剔除 / 一键清理 / 单独清理 / 一键 AI / 单独 AI"集中操作。
///
/// 设计要点：
/// 1. **不复用 TreeBrowserView**——这里的数据源是
///    [StashStore.entries](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift#L56)
///    一维数组（非真正的目录树），用 `List` 渲染最直观；
///    "tree 模式"在购物车这个语义下其实退化为"按 path 罗列"，无需展开子项。
/// 2. **删除走主链路**：通过 `onCleanOne / onCleanAll` 回调把 URL 交给
///    MainView 的已确认 Stash 执行入口，
///    复用 deletion pipeline（accessDenied 兜底 / UndoHistory / 结果 sheet），
///    不在 StashScreen 自己造第二条删除链路；删除完成后只对成功 movedPairs 调
///    [StashStore.remove](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashStore.swift#L90)
///    联动摘掉对应条目。
/// 3. **AI 入口同样复用** [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
///    —— 单独 AI 时 onAskAIOne 关闭本 sheet 后切到 AIAdviceSheet（macOS 不支持 sheet 套 sheet）。
///    **v2026.06.19 更新**：一键 AI 已通过 [StashAIQueue](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashAIQueue.swift)
///    落地（footer 三态：idle / running / 错误 + 重试），节流与并发由 queue 引擎内部串行化处理；
///    UI 上仍在 stash 为空 / aiSettings 未就绪 / 已 running 时 disable，配合 tooltip 解释。
/// 4. **危险操作二次确认**：真正删除统一交给 MainView 的 DeleteSheet；这里只为
///    “清空购物车但不删文件”保留本地 confirmationDialog，避免同一动作弹两次确认。
struct StashScreen: View {
    /// v2026.07.15：tooltip、格式串与 confirmationDialog 都先要求具体 String；
    /// 必须显式读取 View locale，不能让进程级字符串解析固化为启动语言。
    @Environment(\.locale) private var locale

    /// 共享购物车 store。@Bindable 让 entries 变化自动驱动 List。
    @Bindable var stash: StashStore
    /// v2026.06.19 **一键 AI 队列引擎**。@Bindable 让 phase/processed/total/currentPath
    /// 实时驱动 footer 进度条与行内徽标刷新。
    @Bindable var aiQueue: StashAIQueue
    /// 用于决定单独 AI 按钮是否可点（key 未配置 / 未开启 → 禁用）。
    let aiSettings: AISettings
    /// 关闭 sheet 回调（MainView 内置 isPresented binding）。
    let onClose: () -> Void
    /// 单独清理回调；交由 MainView 走主删除 pipeline。
    let onCleanOne: (StashStore.StashEntry) -> Void
    /// 批量清理回调；同上一条，区别只是一次批量提交。
    let onCleanAll: ([StashStore.StashEntry]) -> Void
    /// 单独 AI 询问回调；MainView 会先关本 sheet 再弹 AIAdviceSheet。
    let onAskAIOne: (StashStore.StashEntry) -> Void
    /// v2026.06.19 一键 AI 批量回调；MainView 在闭包里调
    /// [aiQueue.start](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StashAIQueue.swift)
    /// 并把 stash / aiSettings 灌进去——避免 StashScreen 直接持有
    /// AISettings 的 @MainActor 引用做异步调度。
    let onRunAIBatch: () -> Void

    @State private var isConfirmClearAllPresented: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if stash.entries.isEmpty {
                emptyState
            } else {
                listSection
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 520)
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "tray.full.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("stash.screen.title", bundle: .module)
                    .font(.headline)
                Text(summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(AppLocalization.string("stash.action.close", locale: locale))
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("stash.empty.title", bundle: .module)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("stash.empty.subtitle", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listSection: some View {
        List {
            ForEach(stash.entries) { entry in
                row(for: entry)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(for entry: StashStore.StashEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // v2026.06.19 行内 AI 队列结果徽标（pending 默认不渲染，避免 12 行全是灰点干扰）。
            aiBadge(for: entry)
            Text(AppLocalization.byteCount(entry.bytes, locale: locale))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            // 行内 AI 按钮：未启用时整体 disable + tooltip 解释。
            // 队列跑期间禁用以免并发冲突（队列内部串行也不会真的并发，但 UI 语义更清晰）。
            Button {
                onAskAIOne(entry)
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.string("stash.action.ai_one", locale: locale))
            .disabled(!aiSettings.isReadyForUI || aiQueue.phase == .running)
            // 行内单独清理：→ 主删除链路。
            Button(role: .destructive) {
                onCleanOne(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.string("stash.action.trash_one", locale: locale))
            .disabled(aiQueue.phase == .running)
            // 行内剔除：仅从购物车移除，不删文件。
            Button {
                stash.remove(entry.path)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.string("stash.row.remove", locale: locale))
            .disabled(aiQueue.phase == .running)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                onAskAIOne(entry)
            } label: {
                Label(AppLocalization.string("stash.action.ai_one", locale: locale),
                      systemImage: "sparkles")
            }
            .disabled(!aiSettings.isReadyForUI || aiQueue.phase == .running)
            Button(role: .destructive) {
                onCleanOne(entry)
            } label: {
                Label(AppLocalization.string("stash.action.trash_one", locale: locale),
                      systemImage: "trash")
            }
            .disabled(aiQueue.phase == .running)
            Divider()
            Button {
                stash.remove(entry.path)
            } label: {
                Label(AppLocalization.string("stash.row.remove", locale: locale),
                      systemImage: "xmark.circle")
            }
            .disabled(aiQueue.phase == .running)
        }
    }

    /// v2026.06.19 行内 AI 徽标。
    /// - `.pending`：若正是正在询问的当前条目 → 显示小转圈；否则隐藏（避免一片灰点干扰）
    /// - `.done(.safe, _)`：绿色 ✓ + "可清理"
    /// - `.done(.confirm, _)`：橙色 ? + "建议确认"
    /// - `.done(.forbid, _)`：红色 ✕ + "建议保留"
    /// - `.error`：红色感叹号 + "判断失败" + tooltip 显示错误消息
    ///
    /// v2026.06.21 修复：原来只渲染 SF Symbol 图标 + tooltip，用户原话「一键 AI 判断
    /// 你显示结论文本，不能只显示个图标」。改成 icon + 短文案的胶囊样式，结论
    /// 一眼可见；tooltip 仍保留 LLM 返回的 summary / error，供想看细节的用户悬停查阅。
    @ViewBuilder
    private func aiBadge(for entry: StashStore.StashEntry) -> some View {
        switch entry.aiVerdict {
        case .pending:
            if aiQueue.phase == .running && aiQueue.currentPath == entry.path {
                ProgressView()
                    .controlSize(.small)
                    .help(AppLocalization.string("stash.ai.row.querying", locale: locale))
            } else {
                EmptyView()
            }
        case .done(let verdict, let summary):
            verdictChip(for: verdict)
                .help(summary)
        case .error(let failure):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("stash.ai.verdict.error", bundle: .module)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12), in: Capsule())
            // v2026.07.16：tooltip 从 typed failure 按当前 App locale 投影；不得显示
            // transport/body/任意 Error 原文，也不需要重启才能切换语言。
            .help(Self.localizedItemAIFailure(failure, locale: locale))
        }
    }

    static func localizedItemAIFailure(
        _ failure: StashStore.AIVerdictCache.Failure,
        locale: Locale
    ) -> String {
        switch failure {
        case .http(let status):
            return AppLocalization.format(
                "stash.ai.verdict.error.http %lld",
                locale: locale,
                arguments: [Int64(status)]
            )
        case .transport:
            return AppLocalization.string("stash.ai.verdict.error.transport", locale: locale)
        case .decoding:
            return AppLocalization.string("stash.ai.verdict.error.decoding", locale: locale)
        case .configuration:
            return AppLocalization.string("stash.ai.verdict.error.configuration", locale: locale)
        case .unexpected:
            return AppLocalization.string("stash.ai.verdict.error.unexpected", locale: locale)
        }
    }

    /// 三档 verdict → SF Symbol + 颜色 + 短文案胶囊。与本地 SafetyEngine 着色保持一致语义。
    /// 文案 key 走新增的 `stash.ai.verdict.*`，已多语言。
    @ViewBuilder
    private func verdictChip(for verdict: SafetyVerdict) -> some View {
        let style: (icon: String, color: Color, key: LocalizedStringKey) = {
            switch verdict {
            case .safe:
                return ("checkmark.circle.fill", .green, "stash.ai.verdict.safe")
            case .confirm:
                return ("questionmark.circle.fill", .orange, "stash.ai.verdict.confirm")
            case .forbid:
                return ("xmark.octagon.fill", .red, "stash.ai.verdict.forbid")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
            Text(style.key, bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.color.opacity(0.12), in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // 清空（仅清空购物车，不删文件）。
            Button(role: .destructive) {
                isConfirmClearAllPresented = true
            } label: {
                Label(AppLocalization.string("stash.action.clear_all", locale: locale),
                      systemImage: "xmark.bin")
            }
            .disabled(stash.entries.isEmpty || aiQueue.phase == .running)
            .confirmationDialog(
                AppLocalization.string("stash.confirm.clear_all.title", locale: locale),
                isPresented: $isConfirmClearAllPresented,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("stash.confirm.clear_all.confirm", locale: locale),
                       role: .destructive) {
                    stash.clear()
                }
                Button(AppLocalization.string("stash.confirm.cancel", locale: locale),
                       role: .cancel) {}
            } message: {
                Text("stash.confirm.clear_all.message", bundle: .module)
            }

            Spacer()

            // v2026.06.19 一键 AI 判断 —— 三态：
            // - idle + 有条目 + AI 已就绪 → 显示"一键 AI 判断"按钮
            // - running → 替换为 ProgressView + 进度文案 + 取消按钮
            // - idle + lastGlobalError != nil → 显示错误文案 + 一键 AI（允许重试）
            aiBatchControl

            // 一键全部移到废纸篓。
            Button(role: .destructive) {
                onCleanAll(stash.entries)
            } label: {
                Label(AppLocalization.string("stash.action.trash_all", locale: locale),
                      systemImage: "trash.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(stash.entries.isEmpty || aiQueue.phase == .running)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// v2026.06.19 footer 中段：一键 AI 控件三态视图。
    /// 抽出来是为了让 `body` 不变形（HStack 里嵌 if/switch 视觉上很乱）。
    @ViewBuilder
    private var aiBatchControl: some View {
        switch aiQueue.phase {
        case .running:
            HStack(spacing: 8) {
                ProgressView(value: Double(aiQueue.processed),
                             total: Double(max(aiQueue.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text(progressLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    aiQueue.cancel()
                } label: {
                    Label(AppLocalization.string("stash.ai.batch.cancel", locale: locale),
                          systemImage: "stop.circle")
                }
            }
        case .idle:
            HStack(spacing: 8) {
                if let error = aiQueue.lastGlobalError {
                    Text(Self.localizedGlobalError(error, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button {
                    onRunAIBatch()
                } label: {
                    Label(AppLocalization.string("stash.action.ai_all", locale: locale),
                          systemImage: "sparkles")
                }
                .disabled(stash.entries.isEmpty || !aiSettings.isReadyForUI)
                .help(aiSettings.isReadyForUI
                      ? AppLocalization.string("stash.action.ai_all.help", locale: locale)
                      : AppLocalization.string(
                          "stash.action.ai_all.help_disabled_not_configured",
                          locale: locale
                      ))
            }
        }
    }

    /// 进度文案："3 / 12 · 正在询问 xxx"。currentPath 缺失时只显示数字。
    private var progressLine: String {
        if let p = aiQueue.currentPath {
            return AppLocalization.format(
                "stash.ai.batch.progress.with_path",
                locale: locale,
                arguments: [
                    Int64(aiQueue.processed),
                    Int64(aiQueue.total),
                    (p as NSString).lastPathComponent
                ]
            )
        } else {
            return AppLocalization.format(
                "stash.ai.batch.progress",
                locale: locale,
                arguments: [Int64(aiQueue.processed), Int64(aiQueue.total)]
            )
        }
    }

    /// 把 StashAIQueue 的语义错误按 View 当前 locale 投影；技术参数原样嵌入模板。
    static func localizedGlobalError(
        _ error: StashAIQueue.GlobalError,
        locale: Locale
    ) -> String {
        switch error {
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
        case .credentialStorage(let failure):
            let presentation: KeychainUserFacingError.Presentation
            switch failure {
            case .staleFileReference:
                presentation = .staleFileReference
            case .system(let technicalDetail):
                presentation = .system(technicalDetail: technicalDetail)
            case .unknown:
                presentation = .unknown
            }
            return presentation.localizedMessage(locale: locale)
        case .unknown:
            return KeychainUserFacingError.Presentation.unknown.localizedMessage(locale: locale)
        }
    }

    // MARK: - Helpers

    /// 顶部摘要文案："N 项 · X.X MB"，与 toolbar badge 信号一致。
    private var summaryLine: String {
        AppLocalization.format(
            "stash.summary.count_bytes",
            locale: locale,
            arguments: [
                Int64(stash.count),
                AppLocalization.byteCount(stash.totalBytes, locale: locale)
            ]
        )
    }
}
