import SwiftUI
import AppKit

/// Result presentation accepts only opaque completions minted by the execution
/// coordinators. There is intentionally no case for a raw `TrashOutcome`, a
/// preflight rejection, or an optional receipt.
enum OperationResultCompletion: Identifiable, Sendable {
    /// Full deletion interaction: typed intent, authorization and Trash receipt.
    case deletion(DeletionCompletedInteraction)
    /// A mixed Workflow already completed its Trash phase, then the user cancelled
    /// the still-pending command phase. The result remains anchored to the real Trash
    /// receipt while preserving the frozen command items that were explicitly not run.
    case deletionWithSkippedCommands(
        deletion: DeletionCompletedInteraction,
        skippedCommands: [SimulatorDeleteCoordinator.Item]
    )
    /// Main/Smart Care currently submit through the shared Trash coordinator
    /// directly; its completion is an equivalent unforgeable recycle receipt.
    case trash(
        TrashActionCoordinator.CompletedSubmission,
        runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    )
    /// simctl is a destructive command, not a Trash operation, and therefore
    /// carries its own independent command receipt.
    case command(
        SimulatorDeleteCoordinator.CompletedSubmission,
        runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    )
    case combined(
        deletion: DeletionCompletedInteraction,
        command: SimulatorDeleteCoordinator.CompletedSubmission
    )

    var id: UUID {
        switch self {
        case .deletion(let completed): return completed.receipt.id
        case .deletionWithSkippedCommands(let deletion, _): return deletion.receipt.id
        case .trash(let completed, _): return completed.receipt.id
        case .command(let completed, _): return completed.receipt.id
        case .combined(_, let command): return command.receipt.id
        }
    }

    var resultPayload: OperationResultPayload {
        switch self {
        case .deletion(let completed):
            return .trash(
                completed.trashSubmission,
                runningAppSkipped: completed.runningAppSkipped
            )
        case .deletionWithSkippedCommands(let deletion, let skippedCommands):
            return .trash(
                deletion.trashSubmission,
                runningAppSkipped: deletion.runningAppSkipped,
                commandLineSkipped: skippedCommands.count
            )
        case .trash(let completed, let runningAppSkipped):
            return .trash(completed, runningAppSkipped: runningAppSkipped)
        case .command(let completed, let runningAppSkipped):
            return .command(completed, runningAppSkipped: runningAppSkipped)
        case .combined(let deletion, let command):
            return .combined(deletion: deletion, command: command)
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
        public let appName: String

        public init(path: String, itemTitle: String, appName: String) {
            self.path = path
            self.itemTitle = itemTitle
            self.appName = appName
        }
    }

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

    public let id: UUID
    /// 成功移入废纸篓的 (原路径, 废纸篓路径) 对
    public let movedPairs: [(originalPath: String, trashedPath: String)]
    /// NSWorkspace.recycle 真正失败的路径
    public let failedPaths: [String]
    /// 每条 recycle 失败路径对应的系统错误原因。
    public let failureReasons: [String: String]
    /// 被 SafetyEngine / accessDenied 拦的 (path, reason) 对
    public let safetyRejected: [(path: String, reason: String)]
    /// 复合 Workflow 中，用户在文件阶段已经完成后明确取消、因而未执行的命令项数。
    public let commandLineSkipped: Int
    /// 已经成功执行的命令行清理项数。命令行操作不经过废纸篓，不能伪装成 movedPairs。
    public let commandLineSucceeded: Int
    /// 命令行清理的失败结果。单独建模，避免把 simctl 失败伪装成可在 Finder 中定位的文件路径。
    public let commandLineFailures: [CommandLineFailure]
    /// 用户明确选择跳过的运行中 App 相关项；它不是系统失败，也不是 SafetyEngine 拦截。
    public let runningAppSkipped: [RunningAppSkippedItem]
    fileprivate init(id: UUID,
                     movedPairs: [(String, String)] = [],
                     failedPaths: [String] = [],
                     failureReasons: [String: String] = [:],
                     safetyRejected: [(String, String)] = [],
                     commandLineSkipped: Int = 0,
                     commandLineSucceeded: Int = 0,
                     commandLineFailures: [CommandLineFailure] = [],
                     runningAppSkipped: [RunningAppSkippedItem] = []) {
        self.id = id
        self.movedPairs = movedPairs.map { (originalPath: $0.0, trashedPath: $0.1) }
        self.failedPaths = failedPaths
        self.failureReasons = failureReasons
        self.safetyRejected = safetyRejected.map { (path: $0.0, reason: $0.1) }
        self.commandLineSkipped = commandLineSkipped
        self.commandLineSucceeded = commandLineSucceeded
        self.commandLineFailures = commandLineFailures
        self.runningAppSkipped = runningAppSkipped
    }

    fileprivate static func trash(
        _ completed: TrashActionCoordinator.CompletedSubmission,
        runningAppSkipped: [RunningAppSkippedItem],
        commandLineSkipped: Int = 0
    ) -> OperationResultPayload {
        if let outcome = completed.outcome {
            return OperationResultPayload(
                id: completed.receipt.id,
                movedPairs: outcome.movedPairs,
                failedPaths: outcome.failedPaths,
                failureReasons: outcome.failureReasons,
                safetyRejected: outcome.safetyRejected,
                commandLineSkipped: commandLineSkipped,
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
            commandLineSkipped: commandLineSkipped,
            runningAppSkipped: runningAppSkipped
        )
    }

    fileprivate static func command(
        _ completed: SimulatorDeleteCoordinator.CompletedSubmission,
        runningAppSkipped: [RunningAppSkippedItem]
    ) -> OperationResultPayload {
        let failures = completed.outcomes.compactMap { outcome -> CommandLineFailure? in
            guard !outcome.isSuccess else { return nil }
            return CommandLineFailure(
                item: outcome.item.displayName,
                exitCode: outcome.exitCode,
                detail: outcome.truncatedOutput
            )
        }
        return OperationResultPayload(
            id: completed.receipt.id,
            commandLineSucceeded: completed.outcomes.count - failures.count,
            commandLineFailures: failures,
            runningAppSkipped: runningAppSkipped
        )
    }

    fileprivate static func combined(
        deletion: DeletionCompletedInteraction,
        command: SimulatorDeleteCoordinator.CompletedSubmission
    ) -> OperationResultPayload {
        let trash = OperationResultPayload.trash(
            deletion.trashSubmission,
            runningAppSkipped: deletion.runningAppSkipped
        )
        let commandResult = OperationResultPayload.command(
            command,
            runningAppSkipped: []
        )
        return OperationResultPayload(
            id: command.receipt.id,
            movedPairs: trash.movedPairs.map { ($0.originalPath, $0.trashedPath) },
            failedPaths: trash.failedPaths,
            failureReasons: trash.failureReasons,
            safetyRejected: trash.safetyRejected.map { ($0.path, $0.reason) },
            commandLineSucceeded: commandResult.commandLineSucceeded,
            commandLineFailures: commandResult.commandLineFailures,
            runningAppSkipped: trash.runningAppSkipped
        )
    }

    /// 状态判定优先级：有失败 / 有拦截 > 部分；纯成功 → success；全失败/全拦截 → failed。
    ///
    /// `commandLineSkipped` 不是执行失败，不能计入红色 failed；但它表示复合动作没有全部完成，
    /// 所以与运行中 App 跳过项一样让已经有成功结果的操作呈现为 partial。
    public var status: Status {
        let succeededCount = movedPairs.count + commandLineSucceeded
        let failedCount = failedPaths.count + safetyRejected.count + commandLineFailures.count
        return OperationResultStatusPolicy.status(
            succeededCount: succeededCount,
            failedCount: failedCount,
            runningAppSkippedCount: runningAppSkipped.count,
            commandLineSkippedCount: commandLineSkipped
        )
    }

    public enum Status: Equatable {
        case success
        case partial
        case failed
    }
}

enum OperationResultStatusPolicy {
    static func status(
        succeededCount: Int,
        failedCount: Int,
        runningAppSkippedCount: Int,
        commandLineSkippedCount: Int = 0
    ) -> OperationResultPayload.Status {
        if failedCount == 0 {
            return runningAppSkippedCount == 0 && commandLineSkippedCount == 0
                ? .success
                : .partial
        }
        if succeededCount == 0 { return .failed }
        return .partial
    }
}

/// 删除操作结果 sheet。**所有 alert("删除结果")样式都应该换到这个 sheet。**
public struct OperationResultSheet: View {
    public let payload: OperationResultPayload
    public let onDismiss: () -> Void

    @State private var failedExpanded = true
    @State private var blockedExpanded = true
    @State private var runningAppSkippedExpanded = true

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
                    if !payload.runningAppSkipped.isEmpty {
                        runningAppSkippedSection
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
            + payload.runningAppSkipped.count
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
            statTile(
                icon: "pause.circle.fill",
                color: .blue,
                titleKey: "op.result.stat.running_skipped",
                count: payload.runningAppSkipped.count
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
                            Text(DeletionSafetyReasonPresentation.text(for: item.reason))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .padding(.vertical, 2)
                    }
                    if payload.safetyRejected.count > 20 {
                        Text(String(
                            format: String(localized: "op.result.more %lld", bundle: .module),
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
                            Text(item.itemTitle)
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
                            format: String(localized: "op.result.more %lld", bundle: .module),
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

    private var failedPathListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(payload.failedPaths.prefix(20), id: \.self) { path in
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let reason = payload.failureReasons[path], !reason.isEmpty {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if payload.failedPaths.count > 20 {
                Text(String(
                    format: String(localized: "op.result.more %lld", bundle: .module),
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
                    format: String(localized: "op.result.more %lld", bundle: .module),
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
