import Foundation

/// Tree 数值列的共享展示合同。
///
/// `TreeRow` 保存扫描事实，本类型只负责把事实映射成适合窄列和详情区的文本：
/// - AppKit 自绘表、SwiftUI 备用行和详情区必须消费同一份 presentation；
/// - 未完整子树的数值是 lower bound，窄列不再把 `>=` 拼进数字造成截断；
/// - lower-bound 大小只能向下取整，不能把已知的 1.999 MB 显示成“至少 2 MB”；
/// - Count 的窄列文本使用 Foundation 的 locale-aware compact notation，详情保留完整数值。
struct TreeMetricPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case exact
        case lowerBound
        case pending
        case unavailable
    }

    struct Metric: Equatable, Sendable {
        /// 窄列使用的文本。lower-bound 语义由行状态标识承载，不侵占数值列宽。
        let compactText: String
        /// 详情或辅助功能使用的完整语义文本。
        let detailText: String
    }

    /// SwiftPM tests copy String Catalogs as source resources instead of compiling them into
    /// localized `.strings` tables. Injecting the three templates keeps this formatter testable
    /// without adding runtime fallbacks or hard-coded production copy.
    struct Localization: Equatable, Sendable {
        let lowerBoundFormat: String
        let partialStatus: String
        let partialHelpFormat: String

        static func resolved(locale: Locale) -> Self {
            Self(
                lowerBoundFormat: AppLocalization.string("tree.metric.lower_bound", locale: locale),
                partialStatus: AppLocalization.string("tree.subtree.partial.badge", locale: locale),
                partialHelpFormat: AppLocalization.string("tree.subtree.partial.help", locale: locale)
            )
        }
    }

    let state: State
    let size: Metric
    /// Logical size follows the same exact/lower-bound state and downward-rounding contract as
    /// physical size. Keeping it here prevents detail panes from rebuilding a contradictory value
    /// with ByteCountFormatter (for example "At least 2 MB" for 1,999,999 known bytes).
    let logicalSize: Metric
    let count: Metric
    /// lower-bound 行的本地化状态说明；其它状态为 nil。
    let partialStatusText: String?
    /// lower-bound 行的完整说明；AppKit 与 SwiftUI tooltip 共用。
    let helpText: String?

    init(
        row: TreeRow,
        locale: Locale = .current,
        localization: Localization? = nil
    ) {
        let resolvedState: State
        if row.accessState != .normal {
            resolvedState = .unavailable
        } else if row.isSizePending {
            resolvedState = .pending
        } else if row.subtreeCompleteness == .containsIncompleteDescendant {
            resolvedState = .lowerBound
        } else {
            resolvedState = .exact
        }
        state = resolvedState

        switch resolvedState {
        case .unavailable, .pending:
            size = Metric(compactText: "—", detailText: "—")
            logicalSize = Metric(compactText: "—", detailText: "—")
            count = Metric(compactText: "—", detailText: "—")
            partialStatusText = nil
            helpText = nil

        case .exact:
            let sizeText = Self.exactSize(max(0, row.bytes), locale: locale)
            let logicalSizeText = Self.exactSize(max(0, row.logicalBytes), locale: locale)
            let exactCount = Self.exactCount(max(0, row.fileCount), locale: locale)
            size = Metric(compactText: sizeText, detailText: sizeText)
            logicalSize = Metric(compactText: logicalSizeText, detailText: logicalSizeText)
            count = Metric(
                compactText: Self.compactCount(max(0, row.fileCount), locale: locale, roundingDown: false),
                detailText: exactCount
            )
            partialStatusText = nil
            helpText = nil

        case .lowerBound:
            // Only partial rows need localized status copy. Exact rows are the hot path in the
            // virtualized table, so they must not perform three bundle lookups per configure.
            let localization = localization ?? .resolved(locale: locale)
            let sizeValue = Self.lowerBoundSize(max(0, row.bytes), locale: locale)
            let logicalSizeValue = Self.lowerBoundSize(max(0, row.logicalBytes), locale: locale)
            let exactCount = Self.exactCount(max(0, row.fileCount), locale: locale)
            let sizeDetail = Self.lowerBoundDetail(
                value: sizeValue,
                format: localization.lowerBoundFormat,
                locale: locale
            )
            let countDetail = Self.lowerBoundDetail(
                value: exactCount,
                format: localization.lowerBoundFormat,
                locale: locale
            )
            size = Metric(compactText: sizeValue, detailText: sizeDetail)
            logicalSize = Metric(
                compactText: logicalSizeValue,
                detailText: Self.lowerBoundDetail(
                    value: logicalSizeValue,
                    format: localization.lowerBoundFormat,
                    locale: locale
                )
            )
            count = Metric(
                compactText: Self.compactCount(max(0, row.fileCount), locale: locale, roundingDown: true),
                detailText: countDetail
            )
            partialStatusText = localization.partialStatus
            helpText = String(
                format: localization.partialHelpFormat,
                locale: locale,
                sizeValue,
                exactCount
            )
        }
    }

    private static func exactSize(_ bytes: Int64, locale: Locale) -> String {
        AppLocalization.byteCount(bytes, locale: locale)
    }

    /// Finder/file-style decimal units with a downward rounding rule.
    /// `usage: .asProvided` prevents MeasurementFormatter from converting the chosen unit again.
    private static func lowerBoundSize(_ bytes: Int64, locale: Locale) -> String {
        let resolved: (value: Double, unit: UnitInformationStorage, fractionDigits: ClosedRange<Int>)
        switch bytes {
        case 1_000_000_000_000...:
            resolved = (Double(bytes) / 1_000_000_000_000, .terabytes, 0...2)
        case 1_000_000_000...:
            resolved = (Double(bytes) / 1_000_000_000, .gigabytes, 0...2)
        case 1_000_000...:
            resolved = (Double(bytes) / 1_000_000, .megabytes, 0...2)
        case 1_000...:
            resolved = (Double(bytes) / 1_000, .kilobytes, 0...2)
        default:
            resolved = (Double(bytes), .bytes, 0...0)
        }

        return Measurement(value: resolved.value, unit: resolved.unit).formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number
                    .precision(.fractionLength(resolved.fractionDigits))
                    .rounded(rule: .down)
            )
            .locale(locale)
        )
    }

    private static func compactCount(_ value: Int, locale: Locale, roundingDown: Bool) -> String {
        if roundingDown {
            return value.formatted(
                .number
                    .notation(.compactName)
                    .rounded(rule: .down)
                    .locale(locale)
            )
        }
        return value.formatted(.number.notation(.compactName).locale(locale))
    }

    private static func exactCount(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale))
    }

    private static func lowerBoundDetail(value: String, format: String, locale: Locale) -> String {
        String(format: format, locale: locale, value)
    }
}
