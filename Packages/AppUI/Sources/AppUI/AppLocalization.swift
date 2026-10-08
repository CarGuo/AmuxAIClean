import Foundation

/// v2026.07.15：运行期语言切换使用的统一字符串解析边界。
///
/// `String(localized:bundle:)` 使用进程启动时确定的 bundle 首选语言；它不会读取
/// SwiftUI 的 `EnvironmentValues.locale`。因此只要用户可见文案需要先落成 `String`
///（tooltip、AppKit menu、格式串、类型化错误），调用方就必须把当前界面的 locale
/// 显式传到这里。纯 SwiftUI `Text("key", bundle:)` 仍可直接使用环境 locale。
public enum AppLocalization {
    public static func string(_ key: String, locale: Locale) -> String {
        string(key, locale: locale, bundle: .module)
    }

    public static func format(
        _ key: String,
        locale: Locale,
        arguments: [any CVarArg]
    ) -> String {
        format(key, locale: locale, arguments: arguments, bundle: .module)
    }

    // v2026.10.08: plural verification must use compiled .stringsdict, just like the App.
    // The injectable bundle shares the production formatting path without a test-only parser.
    static func format(
        _ key: String,
        locale: Locale,
        arguments: [any CVarArg],
        bundle: Bundle
    ) -> String {
        String(
            format: string(key, locale: locale, bundle: bundle),
            locale: locale,
            arguments: arguments
        )
    }

    /// v2026.07.16：容量字符串与普通文案共用同一显式语言边界。
    /// `ByteCountFormatter.string` 读取进程默认语言，App 内切换语言后会留下 `Zero kB`
    /// 等旧语言文本；FormatStyle 的 locale 才能随 SwiftUI 环境即时重投影。
    public static func byteCount(_ bytes: Int64, locale: Locale) -> String {
        max(0, bytes).formatted(.byteCount(style: .file).locale(locale))
    }

    /// Bundle 可注入的核心仅供同包测试验证语言表选择；生产始终使用 `.module`。
    static func string(_ key: String, locale: Locale, bundle: Bundle) -> String {
        let language = Locale.Language(identifier: locale.identifier)

        // macOS 15.4 起 Foundation 提供“指定 localizations 顺序”的正式 API。
        // 与 String(localized:bundle:locale:) 不同，这个参数明确控制字符串表查找。
        if #available(macOS 15.4, *) {
            let localized = bundle.localizedString(
                forKey: key,
                value: nil,
                table: nil,
                localizations: [language]
            )
            if localized != key { return localized }
        }

        // v2026.07.16：产品最低支持 macOS 13.5；Ventura 至 15.3 使用相同 bundle 的
        // 具体 `.lproj` 子 bundle。只处理实际 ship 的 zh-Hans / en，其他语言退回默认。
        if let localization = shippedLocalization(for: locale),
           let path = bundle.path(forResource: localization, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            let localized = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key { return localized }
        }

        #if DEBUG
        // `swift test` 会原样复制 xcstrings，而 Xcode App 构建会编译成 lproj。
        // 这个只读 fallback 让包测试/Preview 也能验证真实 catalog；Release 不包含解析路径。
        if let localization = shippedLocalization(for: locale),
           let localized = rawCatalog[localization]?[key] {
            return localized
        }
        #endif

        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func shippedLocalization(for locale: Locale) -> String? {
        let identifier = locale.identifier.lowercased()
        if identifier.hasPrefix("zh") { return "zh-Hans" }
        if identifier.hasPrefix("en") { return "en" }
        return nil
    }

    #if DEBUG
    /// SwiftPM 的 raw xcstrings 只用于测试/Preview fallback。不可变 static let 只解析一次，
    /// 不在每个 View body 重读磁盘，也不存在跨线程可变缓存。
    private static let rawCatalog: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            return [:]
        }

        var result: [String: [String: String]] = [:]
        for (key, rawEntry) in strings {
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            for localization in ["en", "zh-Hans"] {
                guard let localizedEntry = localizations[localization] as? [String: Any],
                      let unit = localizedEntry["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { continue }
                result[localization, default: [:]][key] = value
            }
        }
        return result
    }()
    #endif
}
