import Foundation
import ScanKit

/// swap / sleepimage tooltip 的统一本地化格式化器。
///
/// HUD 与容量卡片展示的是同一份系统探测数据；所有用户可见标签和说明都复用 String
/// Catalog，避免动态拼装绕过 SwiftUI `Text` 后悄悄泄漏硬编码语言。
public enum VirtualMemoryTooltipFormatter {
    public static func text(
        for snapshot: SwapProbe.Snapshot,
        locale: Locale = .current,
        formatBytes: (Int64) -> String
    ) -> String {
        text(
            for: snapshot,
            locale: locale,
            formatBytes: formatBytes,
            localize: { key in
                String(
                    localized: String.LocalizationValue(key),
                    bundle: .module,
                    locale: locale
                )
            }
        )
    }

    /// 单测可注入的纯格式化核心；生产入口始终使用上面的 String Catalog resolver。
    static func text(
        for snapshot: SwapProbe.Snapshot,
        locale: Locale,
        formatBytes: (Int64) -> String,
        localize: (String) -> String
    ) -> String {
        var parts: [String] = []

        if snapshot.swapFileSizeMeasured {
            let countFormat = localize("capacity.swap.allocated.hint.real")
            let countDescription = String(
                format: countFormat,
                locale: locale,
                Int64(snapshot.swapFileCount)
            )
            parts.append("\(countDescription): \(formatBytes(snapshot.swapFileBytesOnDisk))")
        } else if snapshot.swapTotalBytes > 0 {
            let label = localize("capacity.swap.allocated")
            let hint = localize("capacity.swap.allocated.hint.fallback")
            parts.append("\(label): \(formatBytes(snapshot.swapTotalBytes)) (\(hint))")
        }

        if snapshot.sleepImageBytes > 0 {
            let label = localize("capacity.sleepimage")
            parts.append("\(label): \(formatBytes(snapshot.sleepImageBytes))")
        }

        if snapshot.swapTotalBytes > 0 {
            let label = localize("capacity.swap.used")
            let hint = localize("capacity.swap.used.hint")
            parts.append(
                "\(label): \(formatBytes(snapshot.swapUsedBytes)) / "
                    + "\(formatBytes(snapshot.swapTotalBytes)) (\(hint))"
            )
        }

        if snapshot.sleepImageBytes > 0 {
            parts.append(localize("capacity.sleepimage.hint"))
        }

        return parts.joined(separator: "\n")
    }
}
