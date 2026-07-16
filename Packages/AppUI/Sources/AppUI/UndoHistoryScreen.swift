import SwiftUI

/// v2026.07.15：恢复完成后只保存事实，alert 打开期间切换语言时再按当前 locale 投影。
/// 文件系统错误原文保持 verbatim，不把一次异步结果提前冻结成启动语言字符串。
enum UndoHistoryAlertPresentation: Equatable, Sendable {
    case partial(
        restored: Int,
        skipped: Int,
        failure: UndoHistoryStore.RestoreFailure
    )
    case renamed(restored: Int, renamed: Int)
    case success(restored: Int)

    func text(locale: Locale) -> String {
        switch self {
        case .partial(let restored, let skipped, let failure):
            return AppLocalization.format(
                "undo_history.alert.partial %lld %lld %@",
                locale: locale,
                arguments: [
                    Int64(restored),
                    Int64(skipped),
                    failure.message(locale: locale)
                ]
            )
        case .renamed(let restored, let renamed):
            let summary = AppLocalization.format(
                "undo_history.alert.success %lld",
                locale: locale,
                arguments: [Int64(restored)]
            )
            let detail = AppLocalization.format(
                "undo_history.alert.renamed_detail %lld",
                locale: locale,
                arguments: [Int64(renamed)]
            )
            return "\(summary) \(detail)"
        case .success(let restored):
            return AppLocalization.format(
                "undo_history.alert.success %lld",
                locale: locale,
                arguments: [Int64(restored)]
            )
        }
    }
}

/// Step 7：「最近清理」面板 —— 渲染 [UndoHistoryStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift)
/// 当前记录，每条带"恢复"按钮把整批 trash 反推回原位。
///
/// 设计要点：
/// - 仅消费 [UndoHistoryStore.shared](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift#L64)，
///   避免每屏自己开 store 实例造成数据不一致。
/// - 列表 + 详情双栏（master-detail）：左侧批次时间轴，右侧展开看 pair。
/// - 恢复操作走 [restoreRecord](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift#L200)
///   —— 失败时弹 alert 不静默。
struct UndoHistoryScreen: View {
    @ObservedObject private var store = UndoHistoryStore.shared
    @State private var selectedRecordID: UUID?
    @State private var alertPresentation: UndoHistoryAlertPresentation?
    @State private var isRestoring = false
    @State private var isPreparingRestore = false
    @State private var pendingConflictRecord: UndoHistoryStore.Record?
    @State private var pendingConflictCount = 0
    @State private var showConflictDecision = false
    @Environment(\.locale) private var locale

    private var selectedRecord: UndoHistoryStore.Record? {
        guard let id = selectedRecordID else { return nil }
        return store.history.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if store.history.isEmpty {
                emptyState
            } else {
                HSplitView {
                    historyList
                        .frame(minWidth: 240, idealWidth: 280)
                    detailView
                        .frame(minWidth: 320)
                }
            }
        }
        .onAppear {
            // 视图打开时主动刷新一次：用户可能刚清空了系统废纸篓
            store.cleanupStaleEntries()
        }
        .alert(AppLocalization.string("undo_history.alert.title", locale: locale), isPresented: Binding(
            get: { alertPresentation != nil },
            set: { if !$0 { alertPresentation = nil } }
        ), actions: {
            Button(AppLocalization.string("undo_history.alert.ok", locale: locale)) {
                alertPresentation = nil
            }
        }, message: {
            Text(alertPresentation?.text(locale: locale) ?? "")
        })
        .confirmationDialog(
            AppLocalization.string("undo_history.conflict.title", locale: locale),
            isPresented: $showConflictDecision,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("undo_history.conflict.restore_new_name", locale: locale)) {
                resolvePendingConflict(with: .restoreWithUniqueName)
            }
            Button(AppLocalization.string("undo_history.conflict.skip_existing", locale: locale)) {
                resolvePendingConflict(with: .skipExisting)
            }
            Button(AppLocalization.string("common.button.cancel", locale: locale), role: .cancel) {
                pendingConflictRecord = nil
                pendingConflictCount = 0
                showConflictDecision = false
            }
        } message: {
            Text(AppLocalization.format(
                "undo_history.conflict.message %lld",
                locale: locale,
                arguments: [Int64(pendingConflictCount)]
            ))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("undo_history.empty.title", bundle: .module)
                .font(.title3)
            Text("undo_history.empty.subtitle", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var historyList: some View {
        List(selection: $selectedRecordID) {
            ForEach(store.history) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.timestamp, style: .date)
                            .font(.callout.weight(.medium))
                        Text(record.timestamp, style: .time)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(record.source.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                        Text(AppLocalization.format(
                            "undo_history.row.count %lld",
                            locale: locale,
                            arguments: [Int64(record.fileCount)]
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(record.id)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let record = selectedRecord {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.timestamp, style: .date) + Text(" ") + Text(record.timestamp, style: .time)
                        Text(AppLocalization.format(
                            "undo_history.detail.summary %@ %lld",
                            locale: locale,
                            arguments: [record.source, Int64(record.fileCount)]
                        ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await requestRestore(record) }
                    } label: {
                        Label {
                            Text("undo_history.button.restore", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring || isPreparingRestore)
                }
                Divider()
                List(record.filePairs, id: \.original) { pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.original)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                            Text(pair.trashed)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding()
        } else {
            VStack(spacing: 8) {
                Text("undo_history.detail.placeholder", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func requestRestore(_ record: UndoHistoryStore.Record) async {
        guard !isRestoring, !isPreparingRestore else { return }
        isPreparingRestore = true
        let plan = await store.prepareRestore(record)
        isPreparingRestore = false

        guard store.history.contains(where: { $0.id == record.id }) else { return }
        if plan.requiresConflictChoice {
            pendingConflictRecord = record
            pendingConflictCount = plan.conflictPaths.count
            showConflictDecision = true
        } else {
            await performRestore(record, conflictPolicy: .skipExisting)
        }
    }

    private func resolvePendingConflict(with policy: UndoHistoryStore.RestoreConflictPolicy) {
        guard let record = pendingConflictRecord else { return }
        pendingConflictRecord = nil
        pendingConflictCount = 0
        showConflictDecision = false
        Task { await performRestore(record, conflictPolicy: policy) }
    }

    private func performRestore(
        _ record: UndoHistoryStore.Record,
        conflictPolicy: UndoHistoryStore.RestoreConflictPolicy
    ) async {
        isRestoring = true
        defer { isRestoring = false }
        let result = await store.restoreRecord(
            record,
            conflictPolicy: conflictPolicy,
            locale: locale
        )
        if let failure = result.firstFailure {
            alertPresentation = .partial(
                restored: result.restoredCount,
                skipped: result.skippedCount,
                failure: failure
            )
        } else if result.renamedCount > 0 {
            alertPresentation = .renamed(
                restored: result.restoredCount,
                renamed: result.renamedCount
            )
        } else {
            alertPresentation = .success(restored: result.restoredCount)
        }
        // 恢复后选中态可能已无效（record 被从 history 删了）
        if !store.history.contains(where: { $0.id == record.id }) {
            selectedRecordID = store.history.first?.id
        }
    }
}
