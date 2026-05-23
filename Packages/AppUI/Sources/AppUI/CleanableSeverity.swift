import SwiftUI

/// v1.3.x：磁盘清理 / 占用 的"严重度配色"统一阈值表。
///
/// 设计目标 —— 用户原话：「10G 应该是红色警告了之类」、「可用部分也要增加颜色警告，
/// 这种都是有一定变化，比如绿色，黄色，橙色，红色」。
///
/// 因此把所有"严重度"统一成 5 档（绿 / 黄 / 橙 / 红 / 灰），主 App 与灵动岛共用。
///
/// 三个语义入口：
/// 1. `forCleanableBytes(_:)` —— 可清理体量越大越红
///    - ≥ 10 GB → critical（红）
///    - ≥ 3 GB  → warning （橙）
///    - ≥ 500 MB → caution（黄）
///    - ≥ 50 MB → healthy（绿）
///    - 否则     → idle（灰，几乎没东西可清）
///
/// 2. `forAvailableBytes(_:)` —— 可用空间越少越红（与"可清理"反向）
///    - ≤ 5 GB  → critical（红）
///    - ≤ 20 GB → warning （橙）
///    - ≤ 50 GB → caution（黄）
///    - 否则     → healthy（绿）
///
/// 3. `forDiskUsedRatio(_:)` —— 已用占比越高越红
///    - ≥ 95% → critical（红）
///    - ≥ 85% → warning （橙）
///    - ≥ 70% → caution（黄）
///    - 否则   → healthy（绿）
///
/// **必须主 App 与灵动岛共用**（`VolumeCapacityCard` / `FloatingScanHUDView`），
/// 单一阈值源避免视觉口径分裂。
public enum CleanableSeverity: Sendable, Hashable {
    case idle
    case healthy
    case caution
    case warning
    case critical

    // MARK: - 阈值

    /// 字节阈值（与 `ByteCountFormatter(.file)` 一致，1 GB = 10^9 B）。
    private static let mb: Int64 = 1_000_000
    private static let gb: Int64 = 1_000_000_000

    /// "可清理字节数"分档 —— 主用法：扫描完成 / 灵动岛展示数字时配色。
    public static func forCleanableBytes(_ bytes: Int64) -> CleanableSeverity {
        if bytes >= 10 * gb { return .critical }
        if bytes >= 3 * gb  { return .warning }
        if bytes >= 500 * mb { return .caution }
        if bytes >= 50 * mb  { return .healthy }
        return .idle
    }

    /// "可用空间"分档 —— 越少越红。主用法：HUD 与 VolumeCapacityCard 的"可用"图例。
    public static func forAvailableBytes(_ bytes: Int64) -> CleanableSeverity {
        if bytes <= 5 * gb   { return .critical }
        if bytes <= 20 * gb  { return .warning }
        if bytes <= 50 * gb  { return .caution }
        return .healthy
    }

    /// "磁盘已用占比"分档 —— 主用法：闲置态提示"磁盘紧张"。
    /// `usedRatio` 取值 [0, 1]。
    public static func forDiskUsedRatio(_ ratio: Double) -> CleanableSeverity {
        if ratio >= 0.95 { return .critical }
        if ratio >= 0.85 { return .warning }
        if ratio >= 0.70 { return .caution }
        return .healthy
    }

    // MARK: - 视觉映射

    /// 主色（数字 / 状态点 / 比例条主段）
    public var color: Color {
        switch self {
        case .critical: return Color(red: 0.93, green: 0.27, blue: 0.27)  // 偏 systemRed
        case .warning:  return Color(red: 0.97, green: 0.62, blue: 0.16)  // 偏 systemOrange
        case .caution:  return Color(red: 0.96, green: 0.82, blue: 0.18)  // 暖黄
        case .healthy:  return Color.green
        case .idle:     return Color.secondary
        }
    }

    /// 次色（背景胶囊 / 浅色填充）
    public var tintBackground: Color {
        color.opacity(0.18)
    }

    /// 简短状态文案
    public var label: String {
        switch self {
        case .critical: return "需要清理"
        case .warning:  return "建议清理"
        case .caution:  return "可以关注"
        case .healthy:  return "状态良好"
        case .idle:     return "无需清理"
        }
    }

    /// SF Symbol（用于灵动岛收起态左侧图标 / 主 App 状态徽章）
    public var symbolName: String {
        switch self {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .caution:  return "exclamationmark.bubble.fill"
        case .healthy:  return "checkmark.circle.fill"
        case .idle:     return "circle.dashed"
        }
    }
}
