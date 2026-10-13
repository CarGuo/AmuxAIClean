import SwiftUI
import ScanKit

private enum CapacityCardMetrics {
    static let valueMinWidth: CGFloat = 72
}

/// v2026.07.15：容量卡的显示口径投影。
///
/// 把主数与解释性估算在类型层分开，避免 View 重构时再次把
/// `availableIfReclaimedBytes` 接到 headline、容量条或 Physical Free 行。
struct VolumeCapacityDisplayValues: Sendable, Equatable {
    let headlineUsedBytes: Int64
    let physicalFreeBytes: Int64
    let estimatedReclaimableBytes: Int64?
    let availableIfReclaimedBytes: Int64?

    init(snapshot: VolumeCapacity.Snapshot) {
        headlineUsedBytes = snapshot.usedBytes
        physicalFreeBytes = snapshot.availableBytes
        estimatedReclaimableBytes = snapshot.estimatedReclaimableBytes
        availableIfReclaimedBytes = snapshot.availableIfReclaimedBytes
    }
}

/// v1.3：sidebar 底部固定的"卷容量条"。
///
/// 类似 macOS 系统设置 → 通用 → 储存空间 顶部那条彩色堆叠条。
/// 数据源：[VolumeCapacity.swift](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/VolumeCapacity.swift)
/// 经由 [ScanCoordinator.refreshVolumeCapacity()](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// 在启动 / 扫描完成 / 删除完成 三个时机刷新。
///
/// 显示四个段（v1.6 / 2026-06 由"三段"升级为"四段"，对齐业界 CleanMyMac / DaisyDisk）：
/// 1. **安全可清 (绿/黄/橙/红 按 severity 变色)**：`SafetyVerdict.safe` 的行字节合计；
///    用户视觉感知"我们能直接帮你清这么多"——同时随删除会缩小
/// 2. **需要确认 (黄色 caution 固定)**：`SafetyVerdict.confirm` 的行字节合计；
///    需要用户在主区域逐项 review/勾选后才能清的部分（应用残留、大文件、旧下载等）。
///    **不计入"自动清"数字**，单独成段是因为：用户能看出"还有多少潜在空间没释放"，
///    但不会被误导以为这部分是一键清的
/// 3. **其它已用 (灰色)**：usedBytes - safe - confirm，系统/应用/文档/不可清理等
/// 4. **物理空闲 (按 available severity 变色)**：普通 `availableBytes`
///
/// macOS 可按需释放估算不进入上述堆叠条；它来自 important-usage 与普通 available
/// 的差值，只在条下方作为解释性附加行展示。
///
/// 设计权衡：
/// - **为什么不一锅炖把 safe + confirm 合并为"可清理"**：v1.6 之前就这么干过，
///   结果是 sidebar 数字 = 所有"看似能清"的总和，包括用户根本不想清的文件，
///   会让用户误以为点一下"清理"就能回收这么多 → 严重违背"白名单加法"原则
/// - **为什么不做四段以上**（系统/应用/文档/缓存）：那种细分需要扫整盘且对齐
///   APFS 子卷 + System Integrity Protection 边界，工程量过大且不在我们的清理目标粒度
/// - confirm 段固定 caution 黄而不跟 severity 变色：避免与 safe 段颜色冲突，
///   且语义上 confirm 段越大不是越"危险"，只是"等用户决定"
public struct VolumeCapacityCard: View {

    @Environment(\.locale) private var locale
    @State private var isReclaimableInfoPresented = false

    let snapshot: VolumeCapacity.Snapshot?
    /// 当前会话本 App 识别到的"可直接安全清理"字节数。来自 [ScanSnapshot.safeBytes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L375-L377)。
    /// 0 时不渲染绿色段。
    let safeBytes: Int64
    /// 当前会话识别到的"需要用户确认才能清"字节数。来自 [ScanSnapshot.confirmBytes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L380-L382)。
    /// 0 时不渲染黄色段；非 0 时单独成段提示"还有 X 待你确认"。
    let confirmBytes: Int64
    /// v1.3 review-fix Must1：snapshot == nil 时（卷容量探测失败 / 卷被 unmount 重挂瞬间）
    /// 触发 UI 重试入口；nil 表示不显示重试按钮（仅显示"未知"占位）。
    let onRetry: (() -> Void)?
    /// v1.3.x：macOS 拿去当虚拟内存的硬盘空间（swap + sleepimage）。
    /// 仅做**只读展示**，不参与"可清理"段（swap 由内核管理，App 不应清理）。
    /// nil 表示尚未探测或环境不支持。
    let swap: SwapProbe.Snapshot?

    public init(snapshot: VolumeCapacity.Snapshot?,
                safeBytes: Int64,
                confirmBytes: Int64,
                swap: SwapProbe.Snapshot? = nil,
                onRetry: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.safeBytes = safeBytes
        self.confirmBytes = confirmBytes
        self.swap = swap
        self.onRetry = onRetry
    }

    public var body: some View {
        if let s = snapshot {
            let display = VolumeCapacityDisplayValues(snapshot: s)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(s.volumeName)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text("\(formatBytes(display.headlineUsedBytes)) / \(formatBytes(s.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                stackedBar(snapshot: s)
                legend(snapshot: s, display: display)
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
                Text("capacity.unknown", bundle: .module)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let onRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(AppLocalization.string("capacity.retry", locale: locale))
                }
            }
            // 保持与正常态相同的占位高度（8pt 灰条 + legend 三行），sidebar 底部高度恒定。
            Rectangle()
                .fill(Color.gray.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: 8)
            VStack(alignment: .leading, spacing: 3) {
                placeholderLegendRow(label: AppLocalization.string("capacity.legend.cleanable", locale: locale))
                placeholderLegendRow(label: AppLocalization.string("capacity.legend.other_used", locale: locale))
                placeholderLegendRow(label: AppLocalization.string("capacity.legend.available", locale: locale))
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private func placeholderLegendRow(label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.gray.opacity(0.3)).frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: CapacityCardMetrics.valueMinWidth, alignment: .trailing)
        }
    }

    /// 四段堆叠条：安全可清 / 需要确认 / 其它已用 / 可用
    @ViewBuilder
    private func stackedBar(snapshot s: VolumeCapacity.Snapshot) -> some View {
        let segs = clampedSegments(s: s)
        let total = max(1, s.totalBytes)
        let safeColor = CleanableSeverity.forCleanableBytes(segs.safe).color
        let confirmColor = CleanableSeverity.caution.color

        GeometryReader { geo in
            let w = geo.size.width
            // 浮点计算，把每段宽度算到至少 2pt（除非该段为 0），保证非零段在 sidebar 窄宽下仍可见
            let safeW    = segs.safe    > 0 ? max(2, CGFloat(Double(segs.safe)    / Double(total)) * w) : 0
            let confirmW = segs.confirm > 0 ? max(2, CGFloat(Double(segs.confirm) / Double(total)) * w) : 0
            let otherW   = segs.other   > 0 ? max(2, CGFloat(Double(segs.other)   / Double(total)) * w) : 0
            let availW   = max(0, w - safeW - confirmW - otherW)
            HStack(spacing: 0) {
                if safeW > 0 {
                    Rectangle().fill(safeColor).frame(width: safeW)
                }
                if confirmW > 0 {
                    Rectangle().fill(confirmColor).frame(width: confirmW)
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

    /// 图例：每段一个色块 + 文案 + 字节数。confirm 段为 0 时整行省略。
    @ViewBuilder
    private func legend(
        snapshot s: VolumeCapacity.Snapshot,
        display: VolumeCapacityDisplayValues
    ) -> some View {
        let segs = clampedSegments(s: s)
        let safeSeverity = CleanableSeverity.forCleanableBytes(segs.safe)
        let availableSeverity = CleanableSeverity.forAvailableBytes(display.physicalFreeBytes)
        VStack(alignment: .leading, spacing: 3) {
            if segs.safe > 0 {
                legendRow(
                    color: safeSeverity.color,
                    label: AppLocalization.string("capacity.legend.cleanable", locale: locale),
                    bytes: segs.safe,
                    valueColor: safeSeverity.color,
                    bold: true
                )
            }
            // confirm 段非零才出现：避免在没扫到任何 .confirm 行时白白多一行视觉噪音
            // 字节数颜色用 caution 黄，但不加粗 —— 视觉权重低于 safe，
            // 告诉用户"还有这些待你确认，但不是一键清的范围"
            if segs.confirm > 0 {
                legendRow(
                    color: CleanableSeverity.caution.color,
                    label: AppLocalization.string("capacity.legend.confirm", locale: locale),
                    bytes: segs.confirm,
                    valueColor: CleanableSeverity.caution.color,
                    bold: false
                )
            }
            legendRow(
                color: .gray.opacity(0.6),
                label: AppLocalization.string("capacity.legend.other_used", locale: locale),
                bytes: segs.other
            )
            // 可用段也按"可用空间 severity"上色（绿/黄/橙/红）：剩越少越红
            legendRow(
                color: availableSeverity.color,
                label: AppLocalization.string("capacity.legend.available", locale: locale),
                bytes: display.physicalFreeBytes,
                valueColor: availableSeverity.color,
                bold: availableSeverity == .critical || availableSeverity == .warning
            )
            // v2026.07.15：estimated reclaimable 是当前 used 中 macOS 认为可按需释放的
            // 动态估算，不是第五个容量段，也不是 AmuxAIClean 可逐文件删除的清单。
            if let reclaimable = display.estimatedReclaimableBytes {
                reclaimableLegendRows(
                    estimatedBytes: reclaimable,
                    availableIfReclaimedBytes: display.availableIfReclaimedBytes
                )
            }
        }
        .font(.caption2)
    }

    @ViewBuilder
    private func reclaimableLegendRows(
        estimatedBytes: Int64,
        availableIfReclaimedBytes: Int64?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // v2026.07.15：这里用公式中的“+”，而不是另一个容量分类圆点。
                // 上一行已经给出“当前空闲”，用户可直接顺序读成：当前空闲 + 系统可能释放 ≈ 预计可用上限。
                Text("+")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.blue)
                    .frame(width: 7, height: 7)
                Text("capacity.legend.system_reclaimable", bundle: .module)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    isReclaimableInfoPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("capacity.reclaimable.info.help", locale: locale))
                .accessibilityLabel(AppLocalization.string("capacity.reclaimable.info.help", locale: locale))
                .popover(isPresented: $isReclaimableInfoPresented, arrowEdge: .trailing) {
                    reclaimableInfoPopover
                        // Popover 由独立 NSHostingView 承载；locale 变化时用 identity
                        // 明确重建，避免已经打开的 tooltip 继续持有旧语言环境。
                        .id(locale.identifier)
                }
                Spacer()
                Text(formatBytes(estimatedBytes))
                    .foregroundStyle(.blue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: CapacityCardMetrics.valueMinWidth, alignment: .trailing)
                    .layoutPriority(1)
            }
            if let availableIfReclaimedBytes {
                HStack(spacing: 6) {
                    Text("≈")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 7, height: 7)
                    Text("capacity.legend.available_if_reclaimed", bundle: .module)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(formatBytes(availableIfReclaimedBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: CapacityCardMetrics.valueMinWidth, alignment: .trailing)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.leading, 4)
    }

    private var reclaimableInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(AppLocalization.string("capacity.reclaimable.info.title", locale: locale))
                    .font(.headline)
            } icon: {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.blue)
            }

            Text(AppLocalization.string("capacity.reclaimable.info.relationship", locale: locale))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            reclaimableInfoSection(
                titleKey: "capacity.reclaimable.info.changes.title",
                bodyKey: "capacity.reclaimable.info.changes"
            )
            reclaimableInfoSection(
                titleKey: "capacity.reclaimable.info.action.title",
                bodyKey: "capacity.reclaimable.info.action"
            )
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }

    /// v2026.07.15：把长篇技术说明拆成“为什么变化 / 能否清理”两个可扫读问题，
    /// 避免窄侧栏弹层成为一整块难以理解的系统术语。
    @ViewBuilder
    private func reclaimableInfoSection(titleKey: String, bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppLocalization.string(titleKey, locale: locale))
                .font(.caption.weight(.semibold))
            Text(AppLocalization.string(bodyKey, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 把 (safeBytes, confirmBytes) 钳制到 usedBytes 范围内，算出四段最终展示字节。
    ///
    /// 防御场景：
    /// - **跨卷文件**：扫描结果可能包含挂载到其他卷的 symlink target，导致 safe+confirm > used
    /// - **快照漂移**：volume snapshot 和 scan snapshot 不是同一瞬间采的，
    ///   极端情况下用户刚删了大文件 → usedBytes 已减小但 scan snapshot 还没刷
    ///
    /// 钳制策略（顺序很重要）：
    /// 1. 先各自非负
    /// 3. 否则若 safe + confirm > used，confirm 让步到 used - safe
    /// 4. other = used - safe - confirm（守恒不变量：safe + confirm + other == used）
    ///
    /// **不变量**：返回值满足 `safe + confirm + other == s.usedBytes`，且三者均 ≥ 0。
    private func clampedSegments(
        s: VolumeCapacity.Snapshot
    ) -> (safe: Int64, confirm: Int64, other: Int64) {
        let rawSafe = max(0, safeBytes)
        let rawConfirm = max(0, confirmBytes)
        let used = max(0, s.usedBytes)

        if rawSafe >= used {
            return (used, 0, 0)
        }
        let safe = rawSafe
        let confirm = min(rawConfirm, used - safe)
        let other = used - safe - confirm
        return (safe, confirm, other)
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
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(formatBytes(bytes))
                .foregroundStyle(valueColor ?? .secondary)
                .fontWeight(bold ? .semibold : .regular)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: CapacityCardMetrics.valueMinWidth, alignment: .trailing)
                .layoutPriority(1)
        }
    }

    /// 字节数格式化：使用 Foundation file 口径，并显式跟随 App 内当前语言。
    private func formatBytes(_ n: Int64) -> String {
        AppLocalization.byteCount(n, locale: locale)
    }

    /// v1.3.x：swap / sleepimage 占盘信息行。
    ///
    /// 设计原则（用户原话："只提示，不执行"）：
    /// - 仅展示数字 + 一行人话说明，**不**给清理按钮——swap/sleepimage 由内核管理，
    ///   删了立即被 `dynamic_pager` / hibernate 重建，且可能引发 paging 错误或破坏休眠。
    /// - 优先展示**物理占盘**（用户能直接换算成"我硬盘上少了多少"），
    ///   sysctl 内核口径放进 tooltip 给好奇用户看，避免主信息行字数爆炸。
    /// - v2026.07.15：sleepimage 只解释为系统管理空间，不再提供直接 `rm` 系统文件的
    ///   命令。容量说明不能诱导用户绕过统一废纸篓边界或破坏休眠恢复能力。
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
                Text("capacity.virtual_memory.title", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(formatBytes(primaryBytes))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: CapacityCardMetrics.valueMinWidth, alignment: .trailing)
                    .layoutPriority(1)
            }
            // 详细分项：swap 已用 + swap 已分配 + sleepimage。
            // 已用与已分配可能不同：内核会预留 swap 文件位（"分配"），但只有真正写入 page 时才"使用"。
            if swap.swapUsedBytes > 0 {
                swapDetailRow(
                    label: AppLocalization.string("capacity.swap.used", locale: locale),
                    bytes: swap.swapUsedBytes,
                    hint: AppLocalization.string("capacity.swap.used.hint", locale: locale)
                )
            }
            if swap.swapDiskBytes > 0,
               swap.swapDiskBytes != swap.swapUsedBytes {
                swapDetailRow(
                    label: AppLocalization.string("capacity.swap.allocated", locale: locale),
                    bytes: swap.swapDiskBytes,
                    hint: swap.swapFileSizeMeasured
                        ? AppLocalization.format(
                            "capacity.swap.allocated.hint.real",
                            locale: locale,
                            arguments: [swap.swapFileCount]
                        )
                        : AppLocalization.string("capacity.swap.allocated.hint.fallback", locale: locale)
                )
            }
            if swap.sleepImageBytes > 0 {
                swapDetailRow(
                    label: AppLocalization.string("capacity.sleepimage", locale: locale),
                    bytes: swap.sleepImageBytes,
                    hint: AppLocalization.string("capacity.sleepimage.hint", locale: locale)
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
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(formatBytes(bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: CapacityCardMetrics.valueMinWidth, alignment: .trailing)
                .layoutPriority(1)
        }
        .font(.caption2)
        .help(hint)
    }
}

/// v2026.07.15：容量卡的实时订阅容器。
///
/// `ScanCoordinator.volumeSnapshot` 是兼容旧代码的低频镜像；15 秒自动探针只发布到
/// `SystemProbeStore`。此前 sidebar 继续读镜像，导致系统已经回收大量空间后界面仍保持
/// 旧值，只有重新扫描或重启才更新。这里让容量卡直接观察 SSOT，同时保持扫描高频状态
/// 不会触发整张 sidebar 容量卡重算。
struct LiveVolumeCapacityCard: View {
    @ObservedObject var systemProbe: SystemProbeStore
    let safeBytes: Int64
    let confirmBytes: Int64
    let onRetry: (() -> Void)?

    var body: some View {
        VolumeCapacityCard(
            snapshot: systemProbe.volumeSnapshot,
            safeBytes: safeBytes,
            confirmBytes: confirmBytes,
            swap: systemProbe.swapSnapshot,
            onRetry: onRetry
        )
    }
}
