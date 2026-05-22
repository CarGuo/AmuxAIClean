import SwiftUI
import SafetyKit

/// 列表行 —— 颜色徽章 + 体积条 + 勾选框（forbid 不可勾）。
/// 见 PITFALLS §5.5：默认勾选只勾 .safe，confirm 不勾，forbid 锁定。
struct RowView: View {
    let row: RowItem
    @Binding var selected: Bool
    let maxBytes: Int64

    private var ratio: CGFloat {
        guard maxBytes > 0 else { return 0 }
        return CGFloat(Double(row.bytes) / Double(maxBytes))
    }

    var body: some View {
        HStack(spacing: 12) {
            // 勾选框
            Group {
                if row.isSelectable {
                    Toggle("", isOn: $selected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                } else {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("受保护：\(row.rejection.rawValue)")
                }
            }
            .frame(width: 24)

            // 徽章
            VerdictBadge(verdict: row.verdict)
                .frame(width: 12, height: 12)

            // 标题 + 体积条
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.title)
                        .font(.system(.body, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let vendor = row.vendorName {
                        Text(vendor)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.18))
                            )
                            .overlay(
                                Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 0.5)
                            )
                            .foregroundStyle(.orange)
                            .help(row.vendorNote ?? vendor)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geo.size.width * ratio, height: 4)
                    }
                }
                .frame(height: 4)
            }

            // 文件数
            Text("\(row.fileCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .help(row.url.path)
    }

    private var barColor: Color {
        switch row.verdict {
        case .safe: return .green.opacity(0.8)
        case .confirm: return .yellow.opacity(0.85)
        case .forbid: return .red.opacity(0.7)
        }
    }
}

struct VerdictBadge: View {
    let verdict: SafetyVerdict
    var body: some View {
        Circle()
            .fill(color)
            .help(label)
    }
    private var color: Color {
        switch verdict {
        case .safe: return .green
        case .confirm: return .yellow
        case .forbid: return .red
        }
    }
    private var label: String {
        switch verdict {
        case .safe: return "可放心清理"
        case .confirm: return "需要你确认"
        case .forbid: return "受保护，无法删除"
        }
    }
}
