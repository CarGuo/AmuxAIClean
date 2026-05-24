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
    /// v1.3 review-fix Must1：snapshot == nil 时（卷容量探测失败 / 卷被 unmount 重挂瞬间）
    /// 触发 UI 重试入口；nil 表示不显示重试按钮（仅显示"未知"占位）。
    let onRetry: (() -> Void)?
    /// v1.3.x：macOS 拿去当虚拟内存的硬盘空间（swap + sleepimage）。
    /// 仅做**只读展示**，不参与"可清理"段（swap 由内核管理，App 不应清理）。
    /// nil 表示尚未探测或环境不支持。
    let swap: SwapProbe.Snapshot?

    public init(snapshot: VolumeCapacity.Snapshot?,
                cleanableBytes: Int64,
                swap: SwapProbe.Snapshot? = nil,
                onRetry: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.cleanableBytes = cleanableBytes
        self.swap = swap
        self.onRetry = onRetry
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
                if let swap, swap.totalDiskFootprintBytes > 0 || swap.swapTotalBytes > 0 {
                    swapInfoRow(swap: swap)
                }
            }
            .padding(10)
            .background(.thinMaterial)
            .overlay(Divider(), alignment: .top)
        } else {
            // v1.3 review-fix Must1：探测失败/未就绪时的占位卡片。
            // 防御理由：之前 nil 直接整张卡片不渲染，sidebar 底部出现一块莫名的空白且无重试入口。
            // 现在保持卡片高度稳定，让用户明确知道"卷容量未知"，并提供"重试"按钮回到 ScanCoordinator.refreshVolumeCapacity()。
            unknownPlaceholder
                .padding(10)
                .background(.thinMaterial)
                .overlay(Divider(), alignment: .top)
        }
    }

    /// snapshot 缺失时的占位。布局结构与正常态对齐（避免 sidebar 抖动）。
    @ViewBuilder
    private var unknownPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("卷容量未知")
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("重试探测")
                }
            }
            // 保持与正常态相同的占位高度（8pt 灰条 + legend 三行），sidebar 底部高度恒定。
            Rectangle()
                .fill(Color.gray.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: 8)
            VStack(alignment: .leading, spacing: 3) {
                placeholderLegendRow(label: "可清理")
                placeholderLegendRow(label: "其它已用")
                placeholderLegendRow(label: "可用")
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private func placeholderLegendRow(label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.gray.opacity(0.3)).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("—").foregroundStyle(.secondary).monospacedDigit()
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

    /// v1.3.x：swap / sleepimage 占盘信息行。
    ///
    /// 设计原则（用户原话："只提示，不执行"）：
    /// - 仅展示数字 + 一行人话说明，**不**给清理按钮——swap/sleepimage 由内核管理，
    ///   删了立即被 `dynamic_pager` / hibernate 重建，且可能引发 paging 错误或破坏休眠。
    /// - 优先展示**物理占盘**（用户能直接换算成"我硬盘上少了多少"），
    ///   sysctl 内核口径放进 tooltip 给好奇用户看，避免主信息行字数爆炸。
    /// - sleepimage 存在时给一句"如不使用休眠，可手动…"的善意提醒（仅文案，不替用户执行命令）。
    /// - **v1.3.x review-fix**：主数字与 macOS 活动监视器 "Swap Used" 对齐，
    ///   即 `swap used + sleepimage`。原来用 `swap total + sleepimage`（已分配但内核可能没全用）
    ///   会让用户对照活动监视器时疑惑"我看到 34 G，你显示 36 G"。
    @ViewBuilder
    private func swapInfoRow(swap: SwapProbe.Snapshot) -> some View {
        // 主数字与活动监视器对齐：实际"在用"的 swap + sleepimage。
        // sysctl 读不到时（极少见）退化到 totalDiskFootprintBytes。
        let primaryBytes: Int64 = {
            if swap.swapUsedBytes > 0 { return swap.swapUsedBytes + swap.sleepImageBytes }
            return swap.totalDiskFootprintBytes
        }()
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 2)
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Text("虚拟内存占盘")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(primaryBytes))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            // 详细分项：swap 已用 + swap 已分配 + sleepimage。
            // 已用与已分配可能不同：内核会预留 swap 文件位（"分配"），但只有真正写入 page 时才"使用"。
            if swap.swapUsedBytes > 0 {
                swapDetailRow(
                    label: "swap 已用",
                    bytes: swap.swapUsedBytes,
                    hint: "活动监视器 Swap Used 同口径（用单位 GB=10⁹ 与 GiB=2³⁰ 之间会有 ~7% 显示差异）"
                )
            }
            if swap.swapDiskBytes > 0,
               swap.swapDiskBytes != swap.swapUsedBytes {
                swapDetailRow(
                    label: "swap 已分配",
                    bytes: swap.swapDiskBytes,
                    hint: swap.swapFileSizeMeasured
                        ? "\(swap.swapFileCount) 个 swapfile 的真实文件大小"
                        : "来自 sysctl vm.swapusage total（系统保护下无法直接列 /private/var/vm 内的 swapfile）"
                )
            }
            if swap.sleepImageBytes > 0 {
                swapDetailRow(
                    label: "休眠镜像",
                    bytes: swap.sleepImageBytes,
                    hint: "终端运行 `sudo pmset -a hibernatemode 0; sudo rm /private/var/vm/sleepimage` 可释放（如不使用休眠）"
                )
            }
        }
    }

    @ViewBuilder
    private func swapDetailRow(label: String, bytes: Int64, hint: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption2)
        .help(hint)
    }
}
