import SwiftUI
import SafetyKit
import AIKit

/// 列表行 —— 颜色徽章 + 体积条 + 勾选框（forbid 不可勾）。
/// 见 PITFALLS §5.5：默认勾选只勾 .safe，confirm 不勾，forbid 锁定。
struct RowView: View {
    let row: RowItem
    @Binding var selected: Bool
    let maxBytes: Int64
    /// M5 / 2026-06：AI 入口配置。
    /// - nil 或 `!isReadyForUI`：contextMenu 不显示"问 AI"按钮（功能未启用）
    /// - 非 nil：点击触发 `onAskAI(row)` 由父视图弹 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
    var aiSettings: AISettings?
    var onAskAI: ((RowItem) -> Void)?

    /// v1.3：active 行的字节数字脉动动画相位（0→1→0），由 .onAppear 触发。
    /// 仅在 row.isActive 时驱动，让"正在被扫描"的行字节数字明显闪动。
    @State private var pulse: Bool = false

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
                        .help(Text(String(format: String(localized: "row.help.protected %@", bundle: .module), row.rejection.rawValue)))
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
                    bytesLabel
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

            // v1.5.4：mtime 列——与 [TreeBrowserRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L622) 行内格式一致；
            // 缺失时占位"—"防止列错位，hover help 给完整时间。
            Text(RowView.mtimeShort(row.modificationDate))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 86, alignment: .trailing)
                .help(RowView.mtimeFull(row.modificationDate))
        }
        .padding(.vertical, 4)
        .help(row.url.path)
        // M4-T1：右键加入用户白名单。WhitelistStore 是 actor + JSON 持久化，
        // 加白后立即生效（在 ScanCoordinator 的下一轮扫描里过滤）。
        // 这里只调 store，不强制重扫——让用户决定何时刷新视图，避免把扫描动作藏在右键里。
        .contextMenu {
            Button {
                let path = row.url.path
                Task.detached {
                    await WhitelistStore.shared.add(path: path,
                                                    reason: "user contextMenu")
                }
            } label: {
                Label(String(localized: "row.context.whitelist.add", bundle: .module),
                      systemImage: "hand.raised")
            }
            // M5 / 2026-06：按需触发"问 AI"。仅当 AISettings 已启用且具备最小条件
            // （baseURL/model 非空）时显示；API Key 缺失留到 sheet 内提示。
            if let ai = aiSettings, ai.isReadyForUI, let cb = onAskAI {
                Divider()
                Button {
                    cb(row)
                } label: {
                    Label(String(localized: "row.context.ask_ai", bundle: .module),
                          systemImage: "sparkles")
                }
            }
        }
    }

    /// 列内 mtime 短文案：当年 MM-dd / 跨年 yyyy-MM-dd / nil → "—"。
    static func mtimeShort(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let cal = Calendar.current
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.shortFmt.string(from: date)
        }
        return Self.fullFmt.string(from: date)
    }

    /// help/tooltip：完整本地化 datetime；nil 给空串避免没必要 tooltip。
    static func mtimeFull(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return Self.fullDateTimeFmt.string(from: date)
    }

    private static let shortFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd"; f.locale = .current; return f
    }()
    private static let fullFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = .current; return f
    }()
    private static let fullDateTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.locale = .current; return f
    }()

    /// v1.3：bytes 文本——active 行用 accent 色加粗 + 缓慢脉动透明度，
    /// 让多 worker 并发扫不同子树时"哪几行正在扫"一眼可见；非 active 行保持原样（secondary 灰）。
    @ViewBuilder
    private var bytesLabel: some View {
        let text = ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)
        if row.isActive {
            HStack(spacing: 6) {
                // 小圆点指示"正在扫描"
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 0.35 : 1.0)
                Text(text)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(pulse ? 0.65 : 1.0)
            }
            .help(Text("row.help.scanning", bundle: .module))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onDisappear { pulse = false }
            // 用 row.id+isActive 强制 onAppear 在状态切换时被触发
            .id("\(row.id)-active")
        } else {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
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
        case .safe: return String(localized: "verdict.label.safe", bundle: .module)
        case .confirm: return String(localized: "verdict.label.confirm", bundle: .module)
        case .forbid: return String(localized: "verdict.label.forbid", bundle: .module)
        }
    }
}
