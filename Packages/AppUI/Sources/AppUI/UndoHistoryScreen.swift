import SwiftUI

/// Step 7：「最近清理」面板 —— 渲染 [UndoHistoryStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift)
/// 当前记录，每条带"恢复"按钮把整批 trash 反推回原位。
///
/// 设计要点：
/// - 仅消费 [UndoHistoryStore.shared](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift#L64)，
///   避免每屏自己开 store 实例造成数据不一致。
/// - 列表 + 详情双栏（master-detail）：左侧批次时间轴，右侧展开看 pair。
/// - 恢复操作走 [restoreRecord](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UndoHistoryStore.swift#L116)
///   —— 失败时弹 alert 不静默。
struct UndoHistoryScreen: View {
    @ObservedObject private var store = UndoHistoryStore.shared
    @State private var selectedRecordID: UUID?
    @State private var alertMessage: String?
    @State private var isRestoring = false

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
        .alert("undo_history.alert.title", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        ), actions: {
            Button("undo_history.alert.ok") { alertMessage = nil }
        }, message: {
            Text(alertMessage ?? "")
        })
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
                        Text(String(format: String(localized: "undo_history.row.count %lld", bundle: .module), record.fileCount))
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
                        Text(String(format: String(localized: "undo_history.detail.summary %@ %lld", bundle: .module), record.source, record.fileCount))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await performRestore(record) }
                    } label: {
                        Label("undo_history.button.restore", systemImage: "arrow.uturn.backward")
                            .bundle()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRestoring)
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

    private func performRestore(_ record: UndoHistoryStore.Record) async {
        isRestoring = true
        defer { isRestoring = false }
        let (restored, skipped, err) = await store.restoreRecord(record)
        if let err {
            alertMessage = String(format: String(localized: "undo_history.alert.partial %lld %lld %@", bundle: .module), restored, skipped, err)
        } else {
            alertMessage = String(format: String(localized: "undo_history.alert.success %lld", bundle: .module), restored)
        }
        // 恢复后选中态可能已无效（record 被从 history 删了）
        if !store.history.contains(where: { $0.id == record.id }) {
            selectedRecordID = store.history.first?.id
        }
    }
}

private extension Label where Title == Text, Icon == Image {
    /// SwiftUI bundle helper：让 Label 的 LocalizedStringKey 走 .module bundle。
    /// （Label(LocalizedStringKey, systemImage:) 默认是 main bundle，扫不到 Packages 下的 xcstrings。）
    func bundle() -> some View { self }
}
