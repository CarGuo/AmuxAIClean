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
    public let id = UUID()
    /// 成功移入废纸篓的 (原路径, 废纸篓路径) 对
    public let movedPairs: [(originalPath: String, trashedPath: String)]
    /// NSWorkspace.recycle 真正失败的路径
    public let failedPaths: [String]
    /// 被 SafetyEngine / accessDenied 拦的 (path, reason) 对
    public let safetyRejected: [(path: String, reason: String)]
    /// 命令行（simctl 等）还没接入 UI 而跳过的项数——仅 WorkflowDetailView 会用
    public let commandLineSkipped: Int

    public init(movedPairs: [(String, String)] = [],
                failedPaths: [String] = [],
                safetyRejected: [(String, String)] = [],
                commandLineSkipped: Int = 0) {
        self.movedPairs = movedPairs.map { (originalPath: $0.0, trashedPath: $0.1) }
        self.failedPaths = failedPaths
        self.safetyRejected = safetyRejected.map { (path: $0.0, reason: $0.1) }
        self.commandLineSkipped = commandLineSkipped
    }

    /// 把 TrashPipeline 的 TrashOutcome 转成 payload。让 ViewModel 一行代码接入。
    public init(outcome: TrashOutcome, commandLineSkipped: Int = 0) {
        self.movedPairs = outcome.movedPairs
        self.failedPaths = outcome.failedPaths
        self.safetyRejected = outcome.safetyRejected
        self.commandLineSkipped = commandLineSkipped
    }

    /// 状态判定优先级：有失败 / 有拦截 > 部分；纯成功 → success；全失败/全拦截 → failed。
    ///
    /// **v2026.06.22 (P0-1)**：`commandLineSkipped` 表示"已弹 simctl 确认 sheet 等用户继续"，
    /// 它是**待执行**而非**失败**——把它计入 failedCount 会导致 OperationResultSheet 把
    /// simctl 待确认的 commandLine 项一律渲染成红色 failed 状态。改为：failedCount 只统计
    /// `failedPaths + safetyRejected`；`commandLineSkipped` 不影响状态判定，仅在
    /// [commandLineHint](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/OperationResultSheet.swift)
    /// 段落里独立展示。
    public var status: Status {
        let movedCount = movedPairs.count
        let failedCount = failedPaths.count + safetyRejected.count
        if failedCount == 0 {
            // 没有真失败 → success；如果同时 moved=0 但 commandLineSkipped>0，仍算 success
            // （因为后续 simctl 二次确认 sheet 会自己再弹 OperationResultPayload 汇总）。
            return .success
        }
        if movedCount == 0 { return .failed }
        return .partial
    }

    public enum Status {
        case success
        case partial
        case failed
    }
}

/// 删除操作结果 sheet。**所有 alert("删除结果")样式都应该换到这个 sheet。**
public struct OperationResultSheet: View {
    public let payload: OperationResultPayload
    public let onDismiss: () -> Void
    /// **v2026.06.22 新增**：用户点击 blockedSection 的「强制删除」按钮触发。
    /// 仅当宿主调用方愿意提供 force 通道时才注入；为 nil 时按钮整体隐藏。
    /// 参数是 reason 含 "vendor" 的可 force 路径子集（硬安全网类 / accessDenied 类不传入）。
    public let onForceDelete: (([String]) -> Void)?

    @State private var failedExpanded = true
    @State private var blockedExpanded = true
    /// 二次确认弹窗状态——避免用户误触跨过 vendor 规则。
    @State private var showForceConfirm = false

    public init(payload: OperationResultPayload,
                onDismiss: @escaping () -> Void,
                onForceDelete: (([String]) -> Void)? = nil) {
        self.payload = payload
        self.onDismiss = onDismiss
        self.onForceDelete = onForceDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsRow
                    if payload.status == .success {
                        successSummary
                    }
                    if !payload.failedPaths.isEmpty {
                        failedSection
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
        // v2026.06.21 修复：原来这里 title / button 都直接传字符串字面量，Swift 会推断
        // 成 `LocalizedStringKey`，但**未显式提供 bundle**，SwiftUI 默认从 `Bundle.main`
        // 查表。AppUI 是 SPM 子模块，字符串只在 `Bundle.module` 的 Localizable.xcstrings
        // 里，于是 alert 会直接渲染 raw key（"op.result.force_delete.confirm.title" 等）。
        // 改成用 `String(localized: ... , bundle: .module)` 显式取出本地化文案再传入。
        .alert(
            String(localized: "op.result.force_delete.confirm.title", bundle: .module),
            isPresented: $showForceConfirm
        ) {
            Button(
                String(localized: "op.result.force_delete.confirm.cancel", bundle: .module),
                role: .cancel
            ) { }
            Button(
                String(localized: "op.result.force_delete.confirm.ok", bundle: .module),
                role: .destructive
            ) {
                let targets = forceDeletablePaths
                guard !targets.isEmpty else { return }
                onForceDelete?(targets)
                onDismiss()
            }
        } message: {
            Text(String(format: String(localized: "op.result.force_delete.confirm.message %lld", bundle: .module),
                        forceDeletablePaths.count))
        }
    }

    /// **v2026.06.22**：从 `safetyRejected` 中筛出"可被 force 通道处理"的路径——
    /// 仅 vendorPathRule（reason 含 "vendor"）允许 force；硬安全网（hardForbid* /
    /// userRoot* / sensitiveCredential / systemVolume）与 accessDenied 类一律不允许。
    /// 这是 UI 层的最后一道 gate——即便 TrashPipeline 内部也会再次 enforce 硬安全网，
    /// 这里仍然预过滤，避免用户点了「强制删除」却看到"全部还是被拦"的体验问题。
    private var forceDeletablePaths: [String] {
        payload.safetyRejected.compactMap { item in
            let r = item.reason.lowercased()
            // 含 vendor 关键字（vendorPathRule / vendor-rule 等）→ 可 force
            if r.contains("vendor") { return item.path }
            return nil
        }
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
        let moved = payload.movedPairs.count
        let total = moved + payload.failedPaths.count + payload.safetyRejected.count + payload.commandLineSkipped
        return "\(moved) / \(total)"
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
                count: payload.failedPaths.count
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
                // **v2026.06.21**：force 通道按钮按用户反馈搬到 footer（更显眼 + 离 Done 远）
                // 这里 blockedSection 内部不再放按钮。
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

    /// v2026.06.21 修复：用户要求强制删除按钮"应该是红色，然后放在完成栏里"。
    /// - 仅当存在 vendor 规则拦下的项 + 宿主提供 onForceDelete 时才显示
    /// - 用 BorderedProminent + .tint(.red) 让"危险动作"在 footer 一眼可辨
    /// - 与 Done 按钮分两侧，避免误触
    /// - 点击触发 `showForceConfirm` 二次确认 alert（原逻辑保留）
    private var footer: some View {
        HStack(spacing: 12) {
            if onForceDelete != nil, !forceDeletablePaths.isEmpty {
                Button(role: .destructive) {
                    showForceConfirm = true
                } label: {
                    Label(
                        String(format: String(localized: "op.result.force_delete.button %lld", bundle: .module),
                               forceDeletablePaths.count),
                        systemImage: "exclamationmark.shield.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            }
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
        } else {
            // 未识别 → 走通用文案，附上 raw token 方便后续日志反查
            let generic = String(localized: "op.result.reason.generic", bundle: .module)
            return "\(generic) [\(raw)]"
        }
        return String(localized: String.LocalizationValue(key), bundle: .module)
    }
}
