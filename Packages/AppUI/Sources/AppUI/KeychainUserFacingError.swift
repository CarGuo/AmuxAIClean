import AIKit
import Foundation

/// 把 Keychain 技术错误收敛成一致、可操作且不泄漏凭证内容的用户文案。
enum KeychainUserFacingError {
    /// v2026.07.15：异步 Keychain 操作只保存这个语义 payload，不保存已经按进程语言
    /// 翻译好的 String。这样设置页保持错误可见时切换语言，View 仍能用当前 locale
    /// 重新投影文案；同时技术详情只保留安全的 OSStatus 描述，不携带凭证内容。
    enum Presentation: Equatable, Sendable {
        case staleFileReference
        case system(technicalDetail: String)
        case unknown

        var localizationKey: String {
            switch self {
            case .staleFileReference: return "ai.keychain.error.stale_file_reference"
            case .system: return "ai.keychain.error.system.format"
            case .unknown: return "ai.keychain.error.unknown"
            }
        }

        func localizedMessage(locale: Locale) -> String {
            switch self {
            case .staleFileReference, .unknown:
                return AppLocalization.string(localizationKey, locale: locale)
            case .system(let technicalDetail):
                return AppLocalization.format(
                    localizationKey,
                    locale: locale,
                    arguments: [technicalDetail]
                )
            }
        }
    }

    static func presentation(for error: any Error) -> Presentation {
        guard let keychainError = error as? KeychainAPIKeyStoreError else {
            return .unknown
        }
        switch keychainError {
        case .staleFileBasedReference:
            return .staleFileReference
        case .unhandled:
            return .system(technicalDetail: keychainError.description)
        case .encoding:
            return .unknown
        }
    }

    /// 兼容仍以 String 保存错误的旧界面；新界面应保存 `Presentation`，并在 View
    /// 读取当前 locale 后调用 `localizedMessage(locale:)`。
    static func message(for error: any Error) -> String {
        presentation(for: error).localizedMessage(locale: .current)
    }
}
