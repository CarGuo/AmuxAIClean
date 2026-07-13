import SwiftUI
import AppKit

/// **v2026.06.16 修复 #4（删除结果弹窗 UX 重做）**
///
/// 旧 `.alert` 把"成功 X / 跳过 Y / 错误描述 / 命令行待办"四段文案拼接到一个 Text 里，
/// 用户看到一堆纯文字"也不知道说明啥"。改造为结构化 sheet：
///
/// 1. **顶部状态**：大图标（绿/橙/红）+ 一句话标题（"清理完成 / 部分清理 / 清理失败"）
/// 2. **三栏统计**：已移入废纸篓 / 失败 / 被安全规则拦截
/// 3. **失败明细**（可折叠）：列出具体路径，提示常见原因 + Reveal in Finder / 复制路径列表
/// 4. **被拦明细**（可折叠）：列出被 SafetyEngine 拦的路径与原因
/// 5. **Done** 关闭
///
/// 接入点：调用方通过 `TrashActionCoordinator` 取得结构化结果，
/// 把 [TrashOutcome](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift)
/// 包装成 `OperationResultPayload` 喂给本 sheet。
public struct OperationResultPayload: Identifiable {
    public struct CommandLineFailure: Equatable {
        public let item: String
        public let exitCode: Int32
        public let detail: String

        public init(item: String, exitCode: Int32, detail: String) {
            self.item = item
            self.exitCode = exitCode
            self.detail = detail
        }
    }

    public let id = UUID()
    /// 成功移入废纸篓的 (原路径, 废纸篓路径) 对
    public let movedPairs: [(originalPath: String, trashedPath: String)]
    /// NSWorkspace.recycle 真正失败的路径
    public let failedPaths: [String]
    /// 被 SafetyEngine / accessDenied 拦的 (path, reason) 对
    public let safetyRejected: [(path: String, reason: String)]
    /// 命令行（simctl 等）还没接入 UI 而跳过的项数——仅 WorkflowDetailView 会用
    public let commandLineSkipped: Int
    /// 已经成功执行的命令行清理项数。命令行操作不经过废纸篓，不能伪装成 movedPairs。
    public let commandLineSucceeded: Int
    /// 命令行清理的失败结果。单独建模，避免把 simctl 失败伪装成可在 Finder 中定位的文件路径。
    public let commandLineFailures: [CommandLineFailure]

    public init(movedPairs: [(String, String)] = [],
                failedPaths: [String] = [],
                safetyRejected: [(String, String)] = [],
                commandLineSkipped: Int = 0,
                commandLineSucceeded: Int = 0,
                commandLineFailures: [CommandLineFailure] = []) {
        self.movedPairs = movedPairs.map { (originalPath: $0.0, trashedPath: $0.1) }
        self.failedPaths = failedPaths
        self.safetyRejected = safetyRejected.map { (path: $0.0, reason: $0.1) }
        self.commandLineSkipped = commandLineSkipped
        self.commandLineSucceeded = commandLineSucceeded
        self.commandLineFailures = commandLineFailures
    }

    /// 把 TrashPipeline 的 TrashOutcome 转成 payload。让 ViewModel 一行代码接入。
    public init(outcome: TrashOutcome, commandLineSkipped: Int = 0) {
        self.movedPairs = outcome.movedPairs
        self.failedPaths = outcome.failedPaths
        self.safetyRejected = outcome.safetyRejected
        self.commandLineSkipped = commandLineSkipped
        self.commandLineSucceeded = 0
        self.commandLineFailures = []
    }

    /// 状态判定优先级：有失败 / 有拦截 > 部分；纯成功 → success；全失败/全拦截 → failed。
    ///
    /// **v2026.06.22 (P0-1)**：`commandLineSkipped` 表示"已弹 simctl 确认 sheet 等用户继续"，
    /// 它是**待执行**而非**失败**——把它计入 failedCount 会导致 OperationResultSheet 把
    /// simctl 待确认的 commandLine 项一律渲染成红色 failed 状态。改为：failedCount 只统计
    /// `failedPaths + safetyRejected + commandLineFailures`；`commandLineSkipped` 不影响状态判定，仅在
    /// [commandLineHint](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/OperationResultSheet.swift)
    /// 段落里独立展示。
    public var status: Status {
        let succeededCount = movedPairs.count + commandLineSucceeded
        let failedCount = failedPaths.count + safetyRejected.count + commandLineFailures.count
        if failedCount == 0 {
            // 没有真失败 → success；如果同时 moved=0 但 commandLineSkipped>0，仍算 success
            // （因为后续 simctl 二次确认 sheet 会自己再弹 OperationResultPayload 汇总）。
            return .success
        }
        if succeededCount == 0 { return .failed }
        return .partial
    }

    public enum Status: Equatable {
        case success
        case partial
        case failed
    }
}

/// 删除操作结果 sheet。**所有 alert("删除结果")样式都应该换到这个 sheet。**
public struct OperationResultSheet: View {
    public let payload: OperationResultPayload
    public let onDismiss: () -> Void

    @State private var failedExpanded = true
    @State private var blockedExpanded = true

    public init(payload: OperationResultPayload,
                onDismiss: @escaping () -> Void,
                onForceDelete: (([String]) -> Void)? = nil) {
        self.payload = payload
        self.onDismiss = onDismiss
        // 参数暂留一版源码兼容，避免现有宿主必须与安全修复同步改动。回调不会被展示或执行：
        // SafetyEngine / vendor `.forbid` 是不可越过的产品合同。
        _ = onForceDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsRow
                    if payload.status == .success, !payload.movedPairs.isEmpty {
                        successSummary
                    }
                    if payload.commandLineSucceeded > 0 {
                        commandLineSuccessSummary
                    }
                    if !payload.failedPaths.isEmpty {
                        failedSection
                    }
                    if !payload.commandLineFailures.isEmpty {
                        commandLineFailureSection
                    }
                    if !payload.safetyRejected.isEmpty {
                        blockedSection
                    }
                    if payload.commandLineSkipped > 0 {
                        commandLineHint
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIconName)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitleKey, bundle: .module)
                    .font(.title2.bold())
                Text(statusSubtitle)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(20)
    }

    private var statusIconName: String {
        switch payload.status {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch payload.status {
        case .success: return .green
        case .partial: return .orange
        case .failed: return .red
        }
    }

    private var statusTitleKey: LocalizedStringKey {
        switch payload.status {
        case .success: return "op.result.title.success"
        case .partial: return "op.result.title.partial"
        case .failed: return "op.result.title.failed"
        }
    }

    private var statusSubtitle: String {
        let succeeded = payload.movedPairs.count + payload.commandLineSucceeded
        let total = succeeded
            + payload.failedPaths.count
            + payload.safetyRejected.count
            + payload.commandLineFailures.count
            + payload.commandLineSkipped
        return "\(succeeded) / \(total)"
    }

    // MARK: - Stats Row（三栏统计）

    private var statsRow: some View {
        HStack(spacing: 12) {
            statTile(
                icon: "trash.fill",
                color: .green,
                titleKey: "op.result.stat.moved",
                count: payload.movedPairs.count
            )
            statTile(
                icon: "xmark.circle.fill",
                color: .red,
                titleKey: "op.result.stat.failed",
                count: payload.failedPaths.count + payload.commandLineFailures.count
            )
            statTile(
                icon: "shield.lefthalf.filled",
                color: .orange,
                titleKey: "op.result.stat.blocked",
                count: payload.safetyRejected.count
            )
        }
    }

    @ViewBuilder
    private func statTile(icon: String, color: Color, titleKey: LocalizedStringKey, count: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text("\(count)")
                    .font(.title3.monospacedDigit().bold())
            }
            Text(titleKey, bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(count > 0 ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(count > 0 ? 0.35 : 0.10), lineWidth: 1)
        )
    }

    // MARK: - Success Summary

    private var successSummary: some View {
        Label {
            Text(String(format: String(localized: "op.result.summary.success %lld", bundle: .module), payload.movedPairs.count))
                .font(.callout)
        } icon: {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
    }

    private var commandLineSuccessSummary: some View {
        Label {
            Text(String(format: String(localized: "op.result.cmdline.succeeded %lld", bundle: .module),
                        payload.commandLineSucceeded))
                .font(.callout)
        } icon: {
            Image(systemName: "terminal.fill").foregroundStyle(.green)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
    }

    private var commandLineFailureSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("op.result.hint.cmdline_failed", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(payload.commandLineFailures.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.item)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(String(
                                format: String(localized: "op.result.cmdline.failure.detail %lld %@", bundle: .module),
                                Int64(failure.exitCode),
                                failure.detail
                            ))
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red.opacity(0.06))
                )
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill").foregroundStyle(.red)
                Text("op.result.section.cmdline_failed", bundle: .module).bold()
                Text("(\(payload.commandLineFailures.count))")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    // MARK: - Failed Section（可折叠 + Reveal / Copy）

    private var failedSection: some View {
        DisclosureGroup(isExpanded: $failedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("op.result.hint.failed", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                pathListView(paths: payload.failedPaths, color: .red)
                HStack(spacing: 8) {
                    Button {
                        copyToPasteboard(payload.failedPaths.joined(separator: "\n"))
                    } label: {
                        Label {
                            Text("op.result.button.copy", bundle: .module)
                        } icon: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    if let first = payload.failedPaths.first {
                        Button {
                            revealInFinder(path: first)
                        } label: {
                            Label {
                                Text("op.result.button.reveal", bundle: .module)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle").foregroundStyle(.red)
                Text("op.result.section.failed", bundle: .module).bold()
                Text("(\(payload.failedPaths.count))").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    // MARK: - Blocked Section

    private var blockedSection: some View {
        DisclosureGroup(isExpanded: $blockedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("op.result.hint.blocked", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(payload.safetyRejected.prefix(20), id: \.path) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // v2026.06.21 修复：原来直接显示 `reason: \(item.reason)`，
                            // raw 字符串例如 "vendorPathRule" 用户根本看不懂，也没多语言。
                            // 改为通过 humanReadableReason() 映射到本地化文案。
                            Text(humanReadableReason(item.reason))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .padding(.vertical, 2)
                    }
                    if payload.safetyRejected.count > 20 {
                        Text("… +\(payload.safetyRejected.count - 20)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.06))
                )
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
                Text("op.result.section.blocked", bundle: .module).bold()
                Text("(\(payload.safetyRejected.count))").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    // MARK: - 命令行待办提示

    private var commandLineHint: some View {
        Label {
            Text(String(format: String(localized: "op.result.cmdline.skipped %lld", bundle: .module), payload.commandLineSkipped))
                .font(.callout)
        } icon: {
            Image(systemName: "terminal").foregroundStyle(.blue)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
    }

    // MARK: - 路径列表通用渲染

    @ViewBuilder
    private func pathListView(paths: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(paths.prefix(20), id: \.self) { path in
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if paths.count > 20 {
                Text("… +\(paths.count - 20)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.06))
        )
    }

    // MARK: - Footer

    /// 结果页只展示完成入口。被安全规则拒绝的路径没有 UI 绕过通道。
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                onDismiss()
            } label: {
                Text("op.result.button.done", bundle: .module)
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - 系统集成

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// v2026.06.21 修复：把 SafetyEngine / TrashPipeline 抛上来的 raw reason 字符串
    /// （vendorPathRule / hardForbid* / userRootEssential / sensitiveCredential /
    /// systemVolumeReadOnly / accessDenied …）映射成用户能看懂、且已多语言的本地化文案。
    /// 任何未识别的 reason 退化为「命中内置安全规则」+ 把原 raw reason 拼到末尾，
    /// 既不会让用户对着 raw token 发呆，也方便我们排查时一眼看出是哪条规则。
    private func humanReadableReason(_ raw: String) -> String {
        let lower = raw.lowercased()
        let key: String
        if lower.contains("vendor") {
            key = "op.result.reason.vendor_path_rule"
        } else if lower.contains("hardforbid") || lower.contains("hard_forbid") || lower.contains("hard-forbid") {
            key = "op.result.reason.hard_forbid"
        } else if lower.contains("userroot") || lower.contains("user_root") || lower.contains("user-root") {
            key = "op.result.reason.user_root"
        } else if lower.contains("credential") || lower.contains("keychain") {
            key = "op.result.reason.sensitive_credential"
        } else if lower.contains("systemvolume") || lower.contains("system_volume") || lower.contains("readonly") || lower.contains("sealed") {
            key = "op.result.reason.system_volume"
        } else if lower.contains("accessdenied") || lower.contains("access_denied") || lower.contains("permission") {
            key = "op.result.reason.access_denied"
        } else if lower.contains("userwhitelisted") || lower.contains("user_whitelist") {
            key = "op.result.reason.user_whitelist"
        } else if lower.contains("batchcontainsforbidden") || lower.contains("batch_atomic") {
            key = "op.result.reason.batch_atomic"
        } else {
            // 未识别 → 走通用文案，附上 raw token 方便后续日志反查
            let generic = String(localized: "op.result.reason.generic", bundle: .module)
            return "\(generic) [\(raw)]"
        }
        return String(localized: String.LocalizationValue(key), bundle: .module)
    }
}
