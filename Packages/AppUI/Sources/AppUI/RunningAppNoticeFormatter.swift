import Foundation

/// 运行中 App 提示的统一格式化边界。
///
/// `ListFormatter.localizedString(byJoining:)` 只跟随进程默认语言，不会读取 SwiftUI
/// `environment(\.locale, ...)` 中的 App 语言覆盖。这里要求调用方显式传入环境 locale，
/// 同时用它解析 String Catalog 模板和列表连接规则，避免同一句提示混用两套语言。
enum RunningAppNoticeFormatter {
    static func appNameList(_ names: [String], locale: Locale) -> String {
        names.formatted(
            .list(type: .and, width: .standard)
                .locale(locale)
        )
    }

    static func text(
        localizationKey: String.LocalizationValue,
        appNames: [String],
        locale: Locale
    ) -> String {
        text(
            localizedTemplate: String(
                localized: localizationKey,
                bundle: .module,
                locale: locale
            ),
            appNames: appNames,
            locale: locale
        )
    }

    /// 已完成 String Catalog 解析后的纯格式化核心，供跨 locale 单测直接验证。
    /// SwiftPM 测试 bundle 只复制 `.xcstrings` 源文件，不会生成最终 App 中的 `.lproj`，
    /// 因此单测不依赖测试宿主的资源编译方式。
    static func text(
        localizedTemplate: String,
        appNames: [String],
        locale: Locale
    ) -> String {
        String(
            format: localizedTemplate,
            locale: locale,
            appNameList(appNames, locale: locale)
        )
    }
}
