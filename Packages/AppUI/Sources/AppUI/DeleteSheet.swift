import SwiftUI
import SafetyKit
import Foundation

/// 删除前的不可变预览 sheet。Release 中确认动作始终表示“移到废纸篓”；
/// Debug 才保留 dry-run 诊断入口。运行中 App 是可选择的风险提示，不再硬中断整批操作。
public struct DeleteSheet: View {
    public let items: [RowItem]
    public let onCancel: () -> Void
    public let onConfirm: (DeleteSheetAction) -> Void

    @Environment(\.locale) private var locale
    @State private var dryRun = DeletionPreviewPolicy.isEnabledInCurrentBuild
    @State private var displayedConflictAppNames: [String]
    @State private var decisionConflicts: [RunningAppGuard.Conflict] = []
    @State private var decisionAppNames: [String] = []
    @State private var decisionConflictCount = 0
    @State private var showRunningAppDecision = false
    @State private var isResolvingRunningApps = false
    @State private var hasSubmittedAction = false
    @State private var conflictResolutionTask: Task<Void, Never>?

    public init(items: [RowItem],
                runningConflicts: [RunningAppGuard.Conflict] = [],
                onCancel: @escaping () -> Void,
                onConfirm: @escaping (DeleteSheetAction) -> Void) {
        self.items = items
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        // 兼容旧调用方传入的初始提示，但初始化最多只接触五项；task 会立即用后台投影刷新。
        _displayedConflictAppNames = State(
            initialValue: runningConflicts.prefix(5).map(\.runningAppName)
        )
    }

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
    private var nonConflictingItemCount: Int {
        max(0, items.count - decisionConflictCount)
    }
    private var skipActionTitle: String {
        if nonConflictingItemCount == 0 {
            return String(
                format: String(
                    localized: "delete.running_app.choice.skip_all %lld",
                    bundle: .module,
                    locale: locale
                ),
                locale: locale,
                decisionConflictCount
            )
        }
        return String(
            format: String(
                localized: "delete.running_app.choice.skip %lld %lld",
                bundle: .module,
                locale: locale
            ),
            locale: locale,
            decisionConflictCount,
            nonConflictingItemCount
        )
    }
    private var isPreviewAction: Bool {
        DeletionPreviewPolicy.isEnabledInCurrentBuild && dryRun
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("delete.summary.title", bundle: .module)
                    .font(.title2.bold())
                Text(String(format: String(localized: "delete.summary.detail %lld %lld %@", bundle: .module), items.count, totalFiles, ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(20)

            Divider()

            if !displayedConflictAppNames.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("delete.running_app.warning.title", bundle: .module)
                            .font(.callout.weight(.semibold))
                        Text(RunningAppNoticeFormatter.text(
                            localizationKey: "delete.running_app.warning.detail %@",
                            appNames: displayedConflictAppNames,
                            locale: locale
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))

                Divider()
            }

            // 预览列表（最多前 30 行；多了滚动）
            List {
                ForEach(items.prefix(200), id: \.id) { item in
                    HStack(spacing: 8) {
                        VerdictBadge(verdict: item.verdict)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(.callout, design: .rounded))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.url.path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if items.count > 200 {
                    Text(String(format: String(localized: "delete.summary.more %lld", bundle: .module), items.count - 200))
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220, idealHeight: 320)

            Divider()

            HStack {
                if DeletionPreviewPolicy.isEnabledInCurrentBuild {
                    Toggle(isOn: $dryRun) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("delete.summary.preview_only", bundle: .module)
                                .font(.callout)
                            Text("delete.summary.preview_only.desc", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                Spacer()
                if isResolvingRunningApps {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "delete.action.cancel", bundle: .module), role: .cancel) {
                    cancelAndClose()
                }
                    .keyboardShortcut(.cancelAction)
                Button(
                    isPreviewAction
                        ? String(localized: "delete.action.preview", bundle: .module)
                        : String(localized: "delete.action.confirm", bundle: .module),
                    role: isPreviewAction ? nil : .destructive
                ) {
                    confirmCurrentAction()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isResolvingRunningApps)
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
        .confirmationDialog(
            String(
                localized: "delete.running_app.choice.title",
                bundle: .module,
                locale: locale
            ),
            isPresented: $showRunningAppDecision,
            titleVisibility: .visible
        ) {
            Button(skipActionTitle) {
                submitFinalAction(.skipConflictingItems)
            }
            Button(role: .destructive) {
                submitFinalAction(.moveAllToTrash)
            } label: {
                Text("delete.running_app.choice.move_all", bundle: .module)
            }
            Button(role: .cancel) {} label: {
                Text("delete.action.cancel", bundle: .module)
            }
        } message: {
            Text(RunningAppNoticeFormatter.text(
                localizationKey: "delete.running_app.choice.message %@",
                appNames: decisionAppNames,
                locale: locale
            ))
        }
        .task {
            await refreshDisplayedConflicts()
        }
        .onDisappear {
            conflictResolutionTask?.cancel()
        }
    }

    private func confirmCurrentAction() {
        if isPreviewAction {
            submitActionOnce(.preview)
            return
        }

        resolveCurrentConflicts()
    }

    private func resolveCurrentConflicts() {
        conflictResolutionTask?.cancel()
        let runningApplications = RunningAppGuard.currentRunningApplications()
        isResolvingRunningApps = true
        conflictResolutionTask = Task { @MainActor in
            do {
                let projection = try await DeleteExecutionPlanner.runningConflictProjectionAsync(
                    rows: items,
                    runningApplications: runningApplications
                )
                try Task.checkCancellation()
                isResolvingRunningApps = false
                conflictResolutionTask = nil
                guard !projection.conflicts.isEmpty else {
                    submitActionOnce(.moveToTrash(
                        resolution: .moveAllToTrash,
                        runningApplications: runningApplications,
                        confirmedConflicts: []
                    ))
                    return
                }
                decisionConflicts = projection.conflicts
                decisionAppNames = projection.appNames
                decisionConflictCount = projection.uniquePathCount
                showRunningAppDecision = true
            } catch is CancellationError {
                isResolvingRunningApps = false
            } catch {
                isResolvingRunningApps = false
                assertionFailure("Unexpected running-app projection error: \(error)")
            }
        }
    }

    private func submitFinalAction(_ resolution: RunningAppGuard.Resolution) {
        let runningApplications = RunningAppGuard.currentRunningApplications()
        submitActionOnce(.moveToTrash(
            resolution: resolution,
            runningApplications: runningApplications,
            confirmedConflicts: resolution == .skipConflictingItems ? decisionConflicts : []
        ))
    }

    private func submitActionOnce(_ action: DeleteSheetAction) {
        guard !hasSubmittedAction else { return }
        hasSubmittedAction = true
        conflictResolutionTask?.cancel()
        onConfirm(action)
    }

    @MainActor
    private func refreshDisplayedConflicts() async {
        let runningApplications = RunningAppGuard.currentRunningApplications()
        do {
            let projection = try await DeleteExecutionPlanner.runningConflictProjectionAsync(
                rows: items,
                runningApplications: runningApplications
            )
            try Task.checkCancellation()
            displayedConflictAppNames = projection.appNames
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected running-app banner projection error: \(error)")
        }
    }

    private func cancelAndClose() {
        conflictResolutionTask?.cancel()
        onCancel()
    }
}
