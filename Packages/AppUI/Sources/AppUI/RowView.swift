import SwiftUI
import SafetyKit
import AIKit

/// 列表行 —— 颜色徽章 + 体积条 + 勾选框。
/// 默认勾选仍只有 `.safe`；专业模式可显式开放 vendorPathRule 风险项进入严格确认，
/// 其它 `.forbid` 始终锁定。
struct RowView: View {
    let row: RowItem
    @Binding var selected: Bool
    let maxBytes: Int64
    /// 只控制是否允许 vendorPathRule 项发起预检；最终权限仍由 TrashPipeline 重验。
    var allowsVendorPathOverride: Bool = false
    /// M5 / 2026-06：AI 入口配置。
    /// - nil 或 `!isReadyForUI`：contextMenu 不显示"问 AI"按钮（功能未启用）
    /// - 非 nil：点击触发 `onAskAI(row)` 由父视图弹 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
    var aiSettings: AISettings?
    var onAskAI: ((RowItem) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // 勾选框
            Group {
                if isDeletionSelectable {
                    Toggle("", isOn: $selected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help(requiresVendorPathOverride
                              ? Text("delete.vendor_override.risk", bundle: .module)
                              : Text(row.url.path))
                } else {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help(Text(String(format: String(localized: "row.help.protected %@", bundle: .module), row.rejection.rawValue)))
                }
            }
            .frame(width: 24)

            // v1.3 P1-A：把行的"纯展示"部分（徽章/标题/进度条/字节/文件数/mtime）下沉到
            // [RowContentView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowView.swift)
            // 内层 View 并实现 Equatable，用 `.equatable()` 让 SwiftUI 在 RowItem 关键字段
            // 未变时跳过子树 body 重建。背景：扫描期 publishSnapshot 每 0.4s 一帧整发
            // snapshot，rows 大部分行的 bytes/fileCount 在窗口内未变，但 ForEach 仍会
            // 把每个 RowView 的 body 跑一遍 —— 拆出 Equatable 子 view 把"未变的行"短路掉。
            RowContentView(row: row, maxBytes: maxBytes)
                .equatable()
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
            // M5 / 2026-06：按需触发"问 AI"。
            //
            // v1.5 P2 / Q3 修复：之前判断 `if let ai = aiSettings, ai.isReadyForUI, ...`，
            // AI 未配置时按钮直接**隐藏**——用户看不到入口，不知道软件支持 AI，
            // 也不会被引导去设置。改为"只要 onAskAI 不为 nil 就显示按钮"：
            // 未就绪时同样回调 `onAskAI(row)`，由父视图（MainView）在 callback 内
            // 判 isReadyForUI → 未就绪则弹"AI 未配置，前往设置？"alert，
            // 跟用户截图诉求"应该提示用户去配置"对齐。
            if let cb = onAskAI {
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

    private var isDeletionSelectable: Bool {
        DeletionEntryPolicy.canInitiate(
            verdict: row.verdict,
            rejection: row.rejection,
            allowsVendorPathOverride: allowsVendorPathOverride
        )
    }

    private var requiresVendorPathOverride: Bool {
        DeletionEntryPolicy.requiresVendorPathOverride(
            verdict: row.verdict,
            rejection: row.rejection,
            allowsVendorPathOverride: allowsVendorPathOverride
        )
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
}

/// v1.3 P1-A：行内"纯展示"子视图 —— 实现 Equatable 让 SwiftUI 在扫描帧（0.4s 一帧）
/// 中遇到等价行直接跳过 body 重建，120Hz 滑动期间显著降低 RowView body 调用数量。
///
/// **比较语义**：只比较真正影响渲染的字段——bytes / fileCount / isActive / verdict /
/// vendorName / modificationDate / title / maxBytes。`row.url` 仅作为 help() tooltip 输入，
/// 与 id（=url.path）一对一，title 等价时 url 必然等价，不参与比较。
/// id 不变是 SwiftUI ForEach 的前提（id 变 = 不同 identity，根本不会走到 == 比较）。
///
/// v1.5 P2 滑动卡顿修复（review-swarm 共识）：
/// - 进度条改用 `Rectangle().scaleEffect(x: ratio, anchor: .leading)` 替代 GeometryReader，
///   消除每行一次 layout pass（千行场景 CPU 立刻回落）。
/// - bytes 的脉动动画改用全局 `TimelineView(.animation)` 心跳驱动 + opacity 计算函数，
///   不再每行 `withAnimation(.repeatForever)` 各开一个 CADisplayLink，且无 `.id` 强重建。
/// - 整行 `.frame(height: 28)` 钉死，避免 isActive / vendor 出现/消失时 NSTableView re-measure。
private struct RowContentView: View, Equatable {
    let row: RowItem
    let maxBytes: Int64

    private var ratio: CGFloat {
        guard maxBytes > 0 else { return 0 }
        // 上限钳到 1.0，避免 ratio > 1 时 scaleEffect 超出容器。
        return min(1.0, CGFloat(Double(row.bytes) / Double(maxBytes)))
    }

    var body: some View {
        HStack(spacing: 12) {
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
                // v1.5 P2：原 GeometryReader 改为 ZStack + scaleEffect，
                // 自适应父宽（HStack 给的宽度），无需测量 → 无 layout pass per row。
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(height: 4)
                        .scaleEffect(x: ratio, y: 1, anchor: .leading)
                }
                .frame(height: 4)
            }

            // 文件数
            Text("\(row.fileCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)

            // mtime 列
            Text(RowView.mtimeShort(row.modificationDate))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 86, alignment: .trailing)
                .help(RowView.mtimeFull(row.modificationDate))
        }
        // v1.5 P2：钉死行高，消除 isActive / vendor 切换造成的 NSTableView re-measure。
        // 28pt 实测能容纳 vendor capsule 与 active Circle 两种最高态。
        .frame(height: 28)
    }

    /// v1.3：bytes 文本——active 行用 accent 色加粗 + 缓慢脉动透明度。
    /// v1.5 P2：脉动改为 `TimelineView(.animation)` 全局心跳驱动，所有 active 行共享同一拍，
    /// 不再每行 `withAnimation(.repeatForever)` 启动独立 CADisplayLink；
    /// 也不再用 `.id("\(row.id)-active")` 强制重建子树（避免 active 翻转抖动）。
    @ViewBuilder
    private var bytesLabel: some View {
        let text = ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)
        if row.isActive {
            TimelineView(.animation(minimumInterval: 0.1, paused: false)) { ctx in
                // 0.7s 周期、easeInOut 拟合：用 cos 形成 0~1 振荡，映射到 0.35~1.0。
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * .pi / 0.7) + 1) * 0.5            // 0...1
                let opa = 0.35 + 0.65 * phase                         // 0.35...1.0
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(opa)
                    Text(text)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(0.65 + 0.35 * phase)
                }
            }
            .help(Text("row.help.scanning", bundle: .module))
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

    /// Equatable：仅比对**真正影响渲染**的字段。
    /// 命中相等时 SwiftUI 会直接跳过 body 重建——这是性能关键。
    /// 注意：row.url / row.id 在 ForEach.id 不变的前提下自然相等，无需参与比较。
    /// Swift 6 isolation：View 是隐式 @MainActor，但 Equatable 协议要求 nonisolated；
    /// 这里 == 只读 let / 值类型字段，没有 MainActor 状态访问，安全标记 nonisolated。
    nonisolated static func == (lhs: RowContentView, rhs: RowContentView) -> Bool {
        lhs.maxBytes == rhs.maxBytes
            && lhs.row.id == rhs.row.id
            && lhs.row.bytes == rhs.row.bytes
            && lhs.row.fileCount == rhs.row.fileCount
            && lhs.row.isActive == rhs.row.isActive
            && lhs.row.verdict == rhs.row.verdict
            && lhs.row.vendorName == rhs.row.vendorName
            && lhs.row.title == rhs.row.title
            && lhs.row.modificationDate == rhs.row.modificationDate
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
