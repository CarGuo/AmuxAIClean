import AIKit
import Foundation

/// 把 Keychain 技术错误收敛成一致、可操作且不泄漏凭证内容的用户文案。
enum KeychainUserFacingError {
    static func localizationKey(for error: any Error) -> String {
        guard let keychainError = error as? KeychainAPIKeyStoreError else {
            return "ai.keychain.error.unknown"
        }
        switch keychainError {
        case .staleFileBasedReference:
            return "ai.keychain.error.stale_file_reference"
        case .unhandled:
            return "ai.keychain.error.system.format"
        case .encoding:
            return "ai.keychain.error.unknown"
        }
    }

    static func message(for error: any Error) -> String {
        let key = localizationKey(for: error)
        if key == "ai.keychain.error.stale_file_reference" {
            return String(localized: "ai.keychain.error.stale_file_reference", bundle: .module)
        }
        if let keychainError = error as? KeychainAPIKeyStoreError,
           key == "ai.keychain.error.system.format" {
            return String(
                format: String(localized: "ai.keychain.error.system.format", bundle: .module),
                keychainError.description
            )
        }
        return String(localized: "ai.keychain.error.unknown", bundle: .module)
    }
}
