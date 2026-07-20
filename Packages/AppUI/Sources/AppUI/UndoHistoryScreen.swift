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

/// v2026.07.18 P2 history-load race fix: the production store bootstraps from disk on a
/// background task. A one-shot view task can therefore observe an empty `.loading` snapshot and
/// finish before persisted records arrive, leaving every decoded non-terminal recovery state at
/// `.checking`. This small identity is the task ownership contract: storage readiness, a newly
/// loaded batch, or additional journal pairs starts one new probe; recovery-state-only publishes
/// keep the same identity and cannot create an update loop.
struct UndoHistoryRecoveryRefreshRevision: Equatable, Sendable {
    struct RecordRevision: Equatable, Sendable {
        let id: UUID
        let filePairCount: Int
    }

    let storageReady: Bool
    let records: [RecordRevision]

    init(
        storageState: UndoHistoryStore.StorageState,
        history: [UndoHistoryStore.Record]
    ) {
        storageReady = storageState == .ready
        records = history.map {
            RecordRevision(id: $0.id, filePairCount: $0.filePairs.count)
        }
    }

    var shouldRefresh: Bool {
        storageReady && !records.isEmpty
    }
}

/// Step 7：「最近清理」面板 —— 渲染 [UndoHistoryStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift)
/// 当前记录，每条带"恢复"按钮把整批 trash 反推回原位。
///
/// 设计要点：
/// - 仅消费组合根显式注入的 [UndoHistoryStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift)，
///   避免每屏自己开 store 实例造成数据不一致，也避免测试/Preview 误读生产历史。
/// - 列表 + 详情双栏（master-detail）：左侧批次时间轴，右侧展开看 pair。
/// - 恢复操作走 [restoreRecord](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift#L200)
///   —— 失败时弹 alert 不静默。
struct UndoHistoryScreen: View {
    @ObservedObject private var store: UndoHistoryStore
    @State private var selectedRecordID: UUID?
    @State private var alertPresentation: UndoHistoryAlertPresentation?
    @State private var isRestoring = false
    @State private var isPreparingRestore = false
    @State private var pendingConflictRecord: UndoHistoryStore.Record?
    @State private var pendingConflictCount = 0
    @State private var showConflictDecision = false
    @Environment(\.locale) private var locale

    // v2026.07.20 P1: pipeline and Undo history are one persistence domain.
    // Requiring the owner here makes a hidden fallback to the production shared
    // history impossible for MainView fixtures and scripted deletion surfaces.
    init(store: UndoHistoryStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    private var selectedRecord: UndoHistoryStore.Record? {
        guard let id = selectedRecordID else { return nil }
        return store.history.first(where: { $0.id == id })
    }

    private var recoveryRefreshRevision: UndoHistoryRecoveryRefreshRevision {
        UndoHistoryRecoveryRefreshRevision(
            storageState: store.storageState,
            history: store.history
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.completionJournalState == .blocked {
                storageWarning("undo_history.storage.journal_failed")
            }
            if let historyStorageMessageKey {
                storageWarning(historyStorageMessageKey)
            }
            Group {
                if store.storageState == .loading, store.history.isEmpty {
                    loadingState
                } else if store.history.isEmpty,
                          historyStorageMessageKey != nil
                            || store.completionJournalState == .blocked {
                    storageUnavailableState
                } else if store.history.isEmpty {
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
        .task(id: recoveryRefreshRevision) {
            // 文件身份探测全部在 Store 的 utility task 中完成；View 只消费状态。绑定 revision
            // 后，页面先于后台历史加载出现时会在 records 到达后重新启动一次，而不是永久
            // 停在空态或 `.checking`；离开页面仍由 SwiftUI 取消当前 presentation owner。
            guard recoveryRefreshRevision.shouldRefresh else { return }
            await store.refreshRecoveryStates()
        }
        .onValueChange(of: store.history.map(\.id), initial: true) { _, recordIDs in
            // 迟到回调可能在历史页已打开后才补写第一条记录；批次保留后选中态也不再
            // 依赖“恢复后删除 record”的旧合同。始终选择仍存在的批次或最新一条。
            if let selectedRecordID, recordIDs.contains(selectedRecordID) { return }
            selectedRecordID = recordIDs.first
        }
    }

    private var historyStorageMessageKey: LocalizedStringKey? {
        switch store.storageState {
        case .loading, .ready:
            return nil
        case .readFailed:
            return "undo_history.storage.read_failed"
        case .corrupt:
            return "undo_history.storage.corrupt"
        case .storeTooLarge:
            return "undo_history.storage.too_large"
        case .recordRejected:
            return "undo_history.storage.record_rejected"
        case .writeFailed:
            return "undo_history.storage.write_failed"
        }
    }

    private func storageWarning(_ key: LocalizedStringKey) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(key, bundle: .module)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.08))
            Divider()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("undo_history.storage.loading", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var storageUnavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            if let key = historyStorageMessageKey {
                Text(key, bundle: .module)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            } else if store.completionJournalState == .blocked {
                Text("undo_history.storage.journal_failed", bundle: .module)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .disabled(isRestoring || isPreparingRestore || !record.hasRestorableItems)
                }
                Divider()
                List(record.filePairs.indices, id: \.self) { index in
                    let pair = record.filePairs[index]
                    let state = record.recoveryState(at: index)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(pair.original)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            recoveryStateLabel(state)
                        }
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
                        if state.status == .restored,
                           let destination = state.restoredDestination {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                                Text(destination)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
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

    @ViewBuilder
    private func recoveryStateLabel(
        _ state: UndoHistoryStore.Record.RecoveryState
    ) -> some View {
        let presentation = RecoveryStatePresentation(status: state.status)
        Label {
            Text(presentation.localizationKey, bundle: .module)
        } icon: {
            Image(systemName: presentation.systemImage)
        }
        .font(.caption2)
        .foregroundStyle(presentation.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(presentation.color.opacity(0.12), in: Capsule())
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
    }
}

/// v2026.07.18：恢复状态是类型化事实，颜色和文案只在 presentation 层投影。
/// 禁止把 errno、raw enum 或路径身份诊断直接暴露给用户。
private struct RecoveryStatePresentation {
    let localizationKey: LocalizedStringKey
    let systemImage: String
    let color: Color

    init(status: UndoHistoryStore.Record.RecoveryStatus) {
        switch status {
        case .checking:
            localizationKey = "undo_history.state.checking"
            systemImage = "clock"
            color = .secondary
        case .available:
            localizationKey = "undo_history.state.available"
            systemImage = "checkmark.circle"
            color = .green
        case .missing:
            localizationKey = "undo_history.state.missing"
            systemImage = "questionmark.circle"
            color = .orange
        case .identityChanged:
            localizationKey = "undo_history.state.identity_changed"
            systemImage = "exclamationmark.shield"
            color = .red
        case .unavailable:
            localizationKey = "undo_history.state.unavailable"
            systemImage = "lock.shield"
            color = .orange
        case .restored:
            localizationKey = "undo_history.state.restored"
            systemImage = "arrow.uturn.backward.circle.fill"
            color = .blue
        }
    }
}
