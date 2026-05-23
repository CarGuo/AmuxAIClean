import SwiftUI
import ScanKit

/// v1.3：sidebar 底部固定的"卷容量条"。
///
/// 类似 macOS 系统设置 → 通用 → 储存空间 顶部那条彩色堆叠条。
/// 数据源：[VolumeCapacity.swift](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/VolumeCapacity.swift)
/// 经由 [ScanCoordinator.refreshVolumeCapacity()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// 在启动 / 扫描完成 / 删除完成 三个时机刷新。
///
/// 显示三个段：
/// 1. **可清理 (绿色)**：当前会话内 ScanCoordinator 累积识别到的可清理字节数；
///    用户视觉感知"我们能帮你清这么多"——同时随着删除会缩小（snapshot.totalBytes 实时变化）
/// 2. **其它已用 (灰色)**：usedBytes - cleanable，系统/应用/文档等不区分
/// 3. **可用 (浅灰)**：availableBytes
///
/// 设计权衡：
/// - 不做"系统/应用/文档/缓存"四段细分（如系统设置那种）：那种细分需要扫整盘且对齐
///   APFS 子卷 + System Integrity Protection 边界，工程量过大且我们的清理目标不在那个粒度。
/// - 改为**"可清理 vs 其它已用 vs 可用"** 三段，专注本 App 的核心价值。
public struct VolumeCapacityCard: View {

    let snapshot: VolumeCapacity.Snapshot?
    /// 当前会话本 App 识别到的"可清理"字节数。来自 `coordinator.snapshot.totalBytes`。
    /// 0 时不渲染绿色段。
    let cleanableBytes: Int64

    public init(snapshot: VolumeCapacity.Snapshot?, cleanableBytes: Int64) {
        self.snapshot = snapshot
        self.cleanableBytes = cleanableBytes
    }

    public var body: some View {
        if let s = snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(s.volumeName)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                    Spacer()
                    Text("\(formatBytes(s.usedBytes)) / \(formatBytes(s.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                stackedBar(snapshot: s)
                legend(snapshot: s)
            }
            .padding(10)
            .background(.thinMaterial)
            .overlay(Divider(), alignment: .top)
        }
    }

    /// 三段堆叠条：可清理 / 其它已用 / 可用
    @ViewBuilder
    private func stackedBar(snapshot s: VolumeCapacity.Snapshot) -> some View {
        // 防御：若 cleanable > used（极端情况：扫描结果含跨卷文件），按 used 兜底
        let cleanable = max(0, min(cleanableBytes, s.usedBytes))
        let otherUsed = max(0, s.usedBytes - cleanable)
        let total = max(1, s.totalBytes)
        let cleanableColor = CleanableSeverity.forCleanableBytes(cleanable).color

        GeometryReader { geo in
            let w = geo.size.width
            // 浮点计算，把每段宽度算到至少 1pt（除非该段为 0）
            let cleanW = cleanable > 0 ? max(2, CGFloat(Double(cleanable) / Double(total)) * w) : 0
            let otherW = otherUsed > 0 ? max(2, CGFloat(Double(otherUsed) / Double(total)) * w) : 0
            let availW = max(0, w - cleanW - otherW)
            HStack(spacing: 0) {
                if cleanW > 0 {
                    Rectangle().fill(cleanableColor).frame(width: cleanW)
                }
                if otherW > 0 {
                    Rectangle().fill(Color.gray.opacity(0.6)).frame(width: otherW)
                }
                if availW > 0 {
                    Rectangle().fill(Color.gray.opacity(0.18)).frame(width: availW)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(height: 8)
        }
        .frame(height: 8)
    }

    /// 图例：每段一个色块 + 文案 + 字节数
    @ViewBuilder
    private func legend(snapshot s: VolumeCapacity.Snapshot) -> some View {
        let cleanable = max(0, min(cleanableBytes, s.usedBytes))
        let otherUsed = max(0, s.usedBytes - cleanable)
        let cleanableSeverity = CleanableSeverity.forCleanableBytes(cleanable)
        let availableSeverity = CleanableSeverity.forAvailableBytes(s.availableBytes)
        VStack(alignment: .leading, spacing: 3) {
            if cleanable > 0 {
                legendRow(
                    color: cleanableSeverity.color,
                    label: "可清理",
                    bytes: cleanable,
                    valueColor: cleanableSeverity.color,
                    bold: true
                )
            }
            legendRow(color: .gray.opacity(0.6), label: "其它已用", bytes: otherUsed)
            // 可用段也按"可用空间 severity"上色（绿/黄/橙/红）：剩越少越红
            legendRow(
                color: availableSeverity.color,
                label: "可用",
                bytes: s.availableBytes,
                valueColor: availableSeverity.color,
                bold: availableSeverity == .critical || availableSeverity == .warning
            )
        }
        .font(.caption2)
    }

    @ViewBuilder
    private func legendRow(
        color: Color,
        label: String,
        bytes: Int64,
        valueColor: Color? = nil,
        bold: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(bytes))
                .foregroundStyle(valueColor ?? .secondary)
                .fontWeight(bold ? .semibold : .regular)
                .monospacedDigit()
        }
    }

    /// 字节数格式化：用 ByteCountFormatter（与系统设置 / Finder 同口径）。
    private func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        f.countStyle = .file  // 对齐 Finder 的 1 KB = 1000 B 口径
        return f.string(fromByteCount: max(0, n))
    }
}
