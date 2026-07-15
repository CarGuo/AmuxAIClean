import CoreServices
import Foundation
import LogKit
import Security

/// OpenAI API Key 的 Keychain 托管错误。
///
/// `100002` 是 file-based Keychain 在其 ACL 仍指向已不存在的 App 路径时返回的
/// `kPOSIXErrorENOENT`。它不是“没有保存 API Key”，必须作为可恢复的凭证存储错误
/// 上抛给 UI，不能降级成空 key。
public enum KeychainAPIKeyStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case staleFileBasedReference(OSStatus)
    case unhandled(OSStatus)
    case encoding

    init(status: OSStatus) {
        if status == OSStatus(kPOSIXErrorENOENT) {
            self = .staleFileBasedReference(status)
        } else {
            self = .unhandled(status)
        }
    }

    public var status: OSStatus? {
        switch self {
        case .staleFileBasedReference(let status), .unhandled(let status): status
        case .encoding: nil
        }
    }

    public var diagnosticMessage: String {
        guard let status else { return "API key encoding failed" }
        let systemMessage = SecCopyErrorMessageString(status, nil) as String?
        return systemMessage ?? "OSStatus \(status)"
    }

    public var description: String {
        guard let status else { return diagnosticMessage }
        return "\(diagnosticMessage) (OSStatus \(status))"
    }
}

/// 可注入的同步后端。生产实现只在 `KeychainAPIKeyStore` actor 内调用，因此
/// `SecItem*` 的同步 I/O 不会占用 MainActor；测试则可注入纯内存闭包。
struct KeychainAPIKeyStoreBackend: Sendable {
    let save: @Sendable (String?) throws -> Void
    let load: @Sendable () throws -> String?
    let remove: @Sendable () throws -> Void

    static func security(service: String, account: String) -> Self {
        Self(
            save: { key in
                try SecurityKeychainAPIKeyStore.save(key, service: service, account: account)
            },
            load: {
                try SecurityKeychainAPIKeyStore.load(service: service, account: account)
            },
            remove: {
                try SecurityKeychainAPIKeyStore.remove(service: service, account: account)
            }
        )
    }
}

/// API Key 的异步、串行 Keychain 边界。
///
/// macOS `SecItem*` 是同步 API，且在 Keychain 锁定、ACL 迁移或系统授权判断时可能
/// 阻塞。actor 让所有调用方必须 `await`，并把实际 I/O 与 SwiftUI 的 MainActor 隔离。
public actor KeychainAPIKeyStore {
    public static let service = "com.amux.ai.Clean.ai.apiKey"
    public static let defaultAccount = "default"
    public static let shared = KeychainAPIKeyStore()

    private let backend: KeychainAPIKeyStoreBackend

    public init(
        service: String = KeychainAPIKeyStore.service,
        account: String = KeychainAPIKeyStore.defaultAccount
    ) {
        self.backend = .security(service: service, account: account)
    }

    init(backend: KeychainAPIKeyStoreBackend) {
        self.backend = backend
    }

    /// 写入或覆盖 API Key。传 `nil` / 空串等价于删除。
    public func save(_ key: String?) throws {
        try backend.save(key)
    }

    /// 读取 API Key。条目不存在返回 nil；不可访问等系统错误原样上抛。
    public func load() throws -> String? {
        try backend.load()
    }

    /// 删除 API Key。条目不存在视为成功。
    public func remove() throws {
        try backend.remove()
    }

    /// 给 Settings 面板用：返回掩码，不暴露完整 key。
    public static func masked(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.count <= 8 { return String(repeating: "*", count: raw.count) }
        let head = raw.prefix(3)
        let tail = raw.suffix(4)
        return "\(head)***...***\(tail)"
    }
}

/// 当前发布版本仍使用现有 file-based Keychain 查询口径。这里刻意不引入
/// `kSecUseDataProtectionKeychain`、access group 或 service 迁移；这些改动必须和
/// entitlements / Developer ID provisioning profile 一起完成，不能做成 Debug-only 修复。
private enum SecurityKeychainAPIKeyStore {
    static func save(_ key: String?, service: String, account: String) throws {
        guard let key, !key.isEmpty else {
            try remove(service: service, account: account)
            return
        }
        guard let data = key.data(using: .utf8) else {
            throw KeychainAPIKeyStoreError.encoding
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            updateAttributes as CFDictionary
        )

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            GSYLog.warning(.settings, "[AIKit] keychain update failed status=\(updateStatus)")
            throw KeychainAPIKeyStoreError(status: updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            GSYLog.warning(.settings, "[AIKit] keychain add failed status=\(addStatus)")
            throw KeychainAPIKeyStoreError(status: addStatus)
        }
    }

    static func load(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            GSYLog.warning(.settings, "[AIKit] keychain load failed status=\(status)")
            throw KeychainAPIKeyStoreError(status: status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            GSYLog.warning(.settings, "[AIKit] keychain delete failed status=\(status)")
            throw KeychainAPIKeyStoreError(status: status)
        }
    }
}
