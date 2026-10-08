import SwiftUI
import AppKit

/// Result presentation accepts only opaque completions minted by the execution
/// coordinators. There is intentionally no case for a raw `TrashOutcome`, a
/// preflight rejection, or an optional receipt.
enum OperationResultCompletion: Identifiable, Sendable {
    /// Full deletion interaction: typed intent, authorization and Trash receipt.
    case deletion(DeletionCompletedInteraction)
    /// Main/Smart Care currently submit through the shared Trash coordinator
    /// directly; its completion is an equivalent unforgeable recycle receipt.
    case trash(
        TrashActionCoordinator.CompletedSubmission,
        runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    )

    var id: UUID {
        switch self {
        case .deletion(let completed): return completed.receipt.id
        case .trash(let completed, _): return completed.receipt.id
        }
    }

    var resultPayload: OperationResultPayload {
        switch self {
        case .deletion(let completed):
            return .trash(
                completed.trashSubmission,
                runningAppSkipped: completed.runningAppSkipped
            )
        case .trash(let completed, let runningAppSkipped):
            return .trash(completed, runningAppSkipped: runningAppSkipped)
        }
    }
}

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
/// 接入点：调用方只能把执行协调器签发的强类型 completion 交给本 sheet；
/// raw `TrashOutcome`、预检拒绝和未执行的授权状态都无法构造结果页。
public struct OperationResultPayload: Identifiable {
    public struct RunningAppSkippedItem: Identifiable, Sendable, Equatable {
        public var id: String { path }
        public let path: String
        public let itemTitle: String
        public let itemTitlePresentation: LocalizedTextDescriptor
        public let appName: String

        public init(path: String, itemTitle: String, appName: String,
                    itemTitlePresentation: LocalizedTextDescriptor? = nil) {
            self.path = path
            self.itemTitle = itemTitle
            self.itemTitlePresentation = itemTitlePresentation ?? .verbatim(itemTitle)
            self.appName = appName
        }

        public func displayItemTitle(locale: Locale) -> String {
            itemTitlePresentation.localized(locale: locale)
        }
    }

    public let id: UUID
    /// 成功移入废纸篓的 (原路径, 废纸篓路径) 对
    public let movedPairs: [(originalPath: String, trashedPath: String)]
    /// NSWorkspace.recycle 真正失败的路径
    public let failedPaths: [String]
    /// 已提交给系统，但 `NSWorkspace.recycle` 尚未回调最终状态的路径。
    public let pendingPaths: [String]
    /// 已进入同步 AppKit API，但连 API 是否接受请求都还无法确认的路径。
    public let submissionUnknownPaths: [String]
    /// 因前一批状态未知而主动停止、尚未提交给系统的路径。
    public let notSubmittedPaths: [String]
    public let notSubmittedReasons: [String: TrashPendingOperationRejection.Reason]
    /// 每条 recycle 失败路径对应的系统错误原因。
    public let failureReasons: [String: String]
    /// 被 SafetyEngine / accessDenied 拦的 (path, reason) 对
    public let safetyRejected: [(path: String, reason: String)]
    /// 用户明确选择跳过的运行中 App 相关项；它不是系统失败，也不是 SafetyEngine 拦截。
    public let runningAppSkipped: [RunningAppSkippedItem]
    fileprivate init(id: UUID,
                     movedPairs: [(String, String)] = [],
                     failedPaths: [String] = [],
                     pendingPaths: [String] = [],
                     submissionUnknownPaths: [String] = [],
                     notSubmittedPaths: [String] = [],
                     notSubmittedReasons: [String: TrashPendingOperationRejection.Reason] = [:],
                     failureReasons: [String: String] = [:],
                     safetyRejected: [(String, String)] = [],
                     runningAppSkipped: [RunningAppSkippedItem] = []) {
        self.id = id
        self.movedPairs = movedPairs.map { (originalPath: $0.0, trashedPath: $0.1) }
        self.failedPaths = failedPaths
        self.pendingPaths = pendingPaths
        self.submissionUnknownPaths = submissionUnknownPaths
        self.notSubmittedPaths = notSubmittedPaths
        self.notSubmittedReasons = notSubmittedReasons
        self.failureReasons = failureReasons
        self.safetyRejected = safetyRejected.map { (path: $0.0, reason: $0.1) }
        self.runningAppSkipped = runningAppSkipped
    }

    fileprivate static func trash(
        _ completed: TrashActionCoordinator.CompletedSubmission,
        runningAppSkipped: [RunningAppSkippedItem]
    ) -> OperationResultPayload {
        if let outcome = completed.outcome {
            return OperationResultPayload(
                id: completed.receipt.id,
                movedPairs: outcome.movedPairs,
                failedPaths: outcome.failedPaths,
                pendingPaths: outcome.pendingPaths,
                submissionUnknownPaths: outcome.submissionUnknownPaths,
                notSubmittedPaths: outcome.notSubmittedPaths,
                notSubmittedReasons: outcome.notSubmittedReasons,
                failureReasons: outcome.failureReasons,
                safetyRejected: outcome.safetyRejected,
                runningAppSkipped: runningAppSkipped
            )
        }
        let succeeded = Set(completed.succeededPaths)
        let failedPaths = completed.err != nil || completed.skipped > 0
            ? completed.attemptedPaths.filter { !succeeded.contains($0) }
            : []
        let failureReasons = completed.err.map { error in
            Dictionary(uniqueKeysWithValues: failedPaths.map { ($0, error) })
        } ?? [:]
        return OperationResultPayload(
            id: completed.receipt.id,
            movedPairs: completed.pairs,
            failedPaths: failedPaths,
            failureReasons: failureReasons,
            runningAppSkipped: runningAppSkipped
        )
    }

    /// v2026.07.16：未知系统终态优先于成功/失败。pending 只能通过重新扫描收敛，
    /// 不能被“部分成功”文案掩盖，也不能诱导用户立即重复提交。
    public var status: Status {
        let succeededCount = movedPairs.count
        let failedCount = failedPaths.count + safetyRejected.count
        return OperationResultStatusPolicy.status(
            succeededCount: succeededCount,
            failedCount: failedCount,
            runningAppSkippedCount: runningAppSkipped.count,
            pendingCount: pendingPaths.count,
            submissionUnknownCount: submissionUnknownPaths.count,
            notSubmittedCount: notSubmittedPaths.count
        )
    }

    public enum Status: Equatable {
        case success
        case partial
        case failed
        case pending
    }
}

enum OperationResultStatusPolicy {
    static func status(
        succeededCount: Int,
        failedCount: Int,
        runningAppSkippedCount: Int,
        pendingCount: Int = 0,
        submissionUnknownCount: Int = 0,
        notSubmittedCount: Int = 0
    ) -> OperationResultPayload.Status {
        if pendingCount > 0 || submissionUnknownCount > 0 { return .pending }
        if notSubmittedCount > 0 { return .partial }
        if failedCount == 0 {
            return runningAppSkippedCount == 0
                ? .success
                : .partial
        }
        if succeededCount == 0 { return .failed }
        return .partial
    }
}

/// Receipt details for partial, failed or uncertain outcomes. Full success uses the shared
/// non-modal OperationCompletionPresentation route (v2026.10.08).
public struct OperationResultSheet: View {
    @Environment(\.locale) private var locale
    public let payload: OperationResultPayload
    public let onDismiss: () -> Void

    @State private var failedExpanded = true
    @State private var blockedExpanded = true
    @State private var runningAppSkippedExpanded = true
    @State private var pendingExpanded = true

    init(completion: OperationResultCompletion,
         onDismiss: @escaping () -> Void) {
        self.payload = completion.resultPayload
        self.onDismiss = onDismiss
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
                    if !payload.failedPaths.isEmpty {
                        failedSection
                    }
                    if !payload.pendingPaths.isEmpty
                        || !payload.submissionUnknownPaths.isEmpty
                        || !payload.notSubmittedPaths.isEmpty {
                        pendingSection
                    }
                    if !payload.safetyRejected.isEmpty {
                        blockedSection
                    }
                    if !payload.runningAppSkipped.isEmpty {
                        runningAppSkippedSection
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
        case .pending: return "clock.arrow.circlepath"
        }
    }

    private var statusColor: Color {
        switch payload.status {
        case .success: return .green
        case .partial: return .orange
        case .failed: return .red
        case .pending: return .blue
        }
    }

    private var statusTitleKey: LocalizedStringKey {
        switch payload.status {
        case .success: return "op.result.title.success"
        case .partial: return "op.result.title.partial"
        case .failed: return "op.result.title.failed"
        case .pending: return "op.result.title.pending"
        }
    }

    private var statusSubtitle: String {
        let succeeded = payload.movedPairs.count
        let total = succeeded
            + payload.failedPaths.count
            + payload.safetyRejected.count
            + payload.runningAppSkipped.count
            + payload.pendingPaths.count
            + payload.submissionUnknownPaths.count
            + payload.notSubmittedPaths.count
        return "\(succeeded) / \(total)"
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
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
                count: payload.failedPaths.count
            )
            statTile(
                icon: "shield.lefthalf.filled",
                color: .orange,
                titleKey: "op.result.stat.blocked",
                count: payload.safetyRejected.count
            )
            statTile(
                icon: "pause.circle.fill",
                color: .blue,
                titleKey: "op.result.stat.running_skipped",
                count: payload.runningAppSkipped.count
            )
            statTile(
                icon: "clock.arrow.circlepath",
                color: .blue,
                titleKey: "op.result.stat.pending",
                count: payload.pendingPaths.count
                    + payload.submissionUnknownPaths.count
                    + payload.notSubmittedPaths.count
            )
        }
    }

    // MARK: - Pending Section

    private var pendingSection: some View {
        DisclosureGroup(isExpanded: $pendingExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    LocalizedStringKey(
                        payload.pendingPaths.isEmpty && payload.submissionUnknownPaths.isEmpty
                            ? "op.result.hint.not_submitted"
                            : !payload.submissionUnknownPaths.isEmpty
                                ? "op.result.hint.submission_unknown"
                            : "op.result.hint.pending"
                    ),
                    bundle: .module
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !payload.pendingPaths.isEmpty {
                    Label {
                        Text("op.result.pending.submitted", bundle: .module)
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    pathListView(paths: payload.pendingPaths, color: .blue)
                }
                if !payload.submissionUnknownPaths.isEmpty {
                    Label {
                        Text("op.result.pending.submission_unknown", bundle: .module)
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                    pathListView(paths: payload.submissionUnknownPaths, color: .purple)
                }
                if !payload.notSubmittedPaths.isEmpty {
                    Label {
                        Text("op.result.pending.not_submitted", bundle: .module)
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "pause.circle")
                    }
                    notSubmittedPathListView
                }
                Button {
                    copyToPasteboard(
                        (payload.pendingPaths
                            + payload.submissionUnknownPaths
                            + payload.notSubmittedPaths)
                            .joined(separator: "\n")
                    )
                } label: {
                    Label {
                        Text("op.result.button.copy", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                Text("op.result.section.pending", bundle: .module).bold()
                Text("(\(payload.pendingPaths.count + payload.submissionUnknownPaths.count + payload.notSubmittedPaths.count))")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
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
            Text(String(format: AppLocalization.string("op.result.summary.success %lld", locale: locale), payload.movedPairs.count))
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

    // MARK: - Failed Section（可折叠 + Reveal / Copy）

    private var failedSection: some View {
        DisclosureGroup(isExpanded: $failedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("op.result.hint.failed", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                failedPathListView
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
                            Text(DeletionSafetyReasonPresentation.text(
                                for: item.reason,
                                locale: locale
                            ))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .padding(.vertical, 2)
                    }
                    if payload.safetyRejected.count > 20 {
                        Text(String(
                            format: AppLocalization.string("op.result.more %lld", locale: locale),
                            payload.safetyRejected.count - 20
                        ))
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

    // MARK: - Running App Skipped Section

    private var runningAppSkippedSection: some View {
        DisclosureGroup(isExpanded: $runningAppSkippedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("op.result.hint.running_skipped", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(payload.runningAppSkipped.prefix(20)) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.displayItemTitle(locale: locale))
                                .font(.caption.weight(.medium))
                            Text(item.path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.appName)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                    if payload.runningAppSkipped.count > 20 {
                        Text(String(
                            format: AppLocalization.string("op.result.more %lld", locale: locale),
                            payload.runningAppSkipped.count - 20
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.blue.opacity(0.06))
                )
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle").foregroundStyle(.blue)
                Text("op.result.section.running_skipped", bundle: .module).bold()
                Text("(\(payload.runningAppSkipped.count))")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    // MARK: - 路径列表通用渲染

    private var failedPathListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(payload.failedPaths.prefix(20), id: \.self) { path in
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let reason = payload.failureReasons[path], !reason.isEmpty {
                        // v2026.07.16：NSError 原文仍留在结构化 outcome/log 供诊断；结果页
                        // 只显示稳定的产品语义，避免 errno、枚举名或未本地化系统文本泄漏。
                        Text(reason == TrashFailureSummary.unknownRecycleReasonKey
                            ? AppLocalization.string(reason, locale: locale)
                            : AppLocalization.string("op.result.reason.recycle_failed", locale: locale))
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if payload.failedPaths.count > 20 {
                Text(String(
                    format: AppLocalization.string("op.result.more %lld", locale: locale),
                    payload.failedPaths.count - 20
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(0.06))
        )
    }

    private var notSubmittedPathListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(payload.notSubmittedPaths.prefix(20), id: \.self) { path in
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let reason = payload.notSubmittedReasons[path] {
                        Text(DeletionSafetyReasonPresentation.text(
                            for: reason.rawValue,
                            locale: locale
                        ))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.06))
        )
    }

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
                Text(String(
                    format: AppLocalization.string("op.result.more %lld", locale: locale),
                    paths.count - 20
                ))
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

}
