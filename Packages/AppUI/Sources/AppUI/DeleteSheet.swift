import SwiftUI
import SafetyKit

/// 删除前的预览 sheet —— Pearcleaner 模式：让用户看清楚要删什么、可改 dryRun。
/// 见 PITFALLS §5.7。
public struct DeleteSheet: View {
    public let items: [RowItem]
    public let runningConflicts: [RunningAppGuard.Conflict]
    public let onCancel: () -> Void
    public let onConfirm: (_ dryRun: Bool) -> Void

    @State private var dryRun: Bool = true

    public init(items: [RowItem],
                runningConflicts: [RunningAppGuard.Conflict] = [],
                onCancel: @escaping () -> Void,
                onConfirm: @escaping (Bool) -> Void) {
        self.items = items
        self.runningConflicts = runningConflicts
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
    private var conflictTitles: [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for conflict in runningConflicts where seen.insert(conflict.title).inserted {
            titles.append(conflict.title)
            if titles.count >= 5 { break }
        }
        return titles
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

            if !conflictTitles.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("delete.running_app.warning.title", bundle: .module)
                            .font(.callout.weight(.semibold))
                        Text(String(format: String(localized: "delete.running_app.warning.detail %@", bundle: .module),
                                    conflictTitles.joined(separator: ", ")))
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
                Spacer()
                Button(String(localized: "delete.action.cancel", bundle: .module), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(
                    dryRun
                        ? String(localized: "delete.action.preview", bundle: .module)
                        : String(localized: "delete.action.confirm", bundle: .module),
                    role: dryRun ? nil : .destructive
                ) {
                    onConfirm(dryRun)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!dryRun && !conflictTitles.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
