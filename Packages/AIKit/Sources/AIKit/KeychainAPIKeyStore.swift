import Foundation
import Security
import LogKit

/// M5 / 2026-06：OpenAI API Key 的 Keychain 托管。
///
/// 设计要点：
/// 1. **绝不入 UserDefaults / plist**——key 是敏感凭证；[AISettings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/AISettings.swift)
///    刻意不持有 apiKey 字段，UI 单独从这里读写。
/// 2. 用 `kSecClassGenericPassword`，service 名固定 `com.amux.ai.Clean.ai.apiKey`；
///    account 字段固定 `default`——目前仅支持单 provider 单 key；未来要多 provider
///    把 account 换成 provider 名即可，无破坏性。
/// 3. 所有 API 都 throws，让调用方决定"找不到 key"是错误还是空态——
///    本场景下 [AIAdviceSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AIAdviceSheet.swift)
///    会把"无 key"翻译成"请到设置面板配置"友好文案。
public enum KeychainAPIKeyStoreError: Error, Equatable {
    case unhandled(OSStatus)
    case encoding
}

public struct KeychainAPIKeyStore: Sendable {

    public static let service = "com.amux.ai.Clean.ai.apiKey"
    public static let defaultAccount = "default"

    private let service: String
    private let account: String

    public init(service: String = KeychainAPIKeyStore.service,
                account: String = KeychainAPIKeyStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    // MARK: - 写

    /// 写入 / 覆盖 API Key。传 `nil` 等价 [remove](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/KeychainAPIKeyStore.swift#L0-L0)。
    ///
    /// **Review fix-soon #4，2026-06-15**：
    /// 1. 所有查询都显式带 `kSecAttrSynchronizable=false`，确保 update / delete /
    ///    load 严格只命中本机条目；杜绝未来若有第三方组件把同 service/account
    ///    的条目写到 iCloud Keychain，被这里误读 / 误覆盖。
    /// 2. update 的 attrs 显式带 `kSecAttrAccessible` 与 `kSecAttrSynchronizable=false`：
    ///    在 macOS 上 SecItemUpdate 改 access class 是 no-op，所以行为不变；但**意图
    ///    在代码层面**和 add 路径保持完全一致，避免未来移植 / 迁移时漂移。
    /// 3. 任何写入路径都禁止上 iCloud Keychain——API Key 是按设备隔离的敏感凭证，
    ///    不入云是 by design（用户在 Mac 上不应该看到 iPhone 上配的 key 串）。
    public func save(_ key: String?) throws {
        guard let key, !key.isEmpty else {
            try remove()
            return
        }
        guard let data = key.data(using: .utf8) else {
            throw KeychainAPIKeyStoreError.encoding
        }

        // 先尝试 update（更常见路径），不存在则 add。
        // 查询条件必须带 synchronizable=false，确保只命中本机条目。
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            GSYLog.warning(.settings, "[AIKit] keychain update failed status=\(updateStatus)")
            throw KeychainAPIKeyStoreError.unhandled(updateStatus)
        }

        // not found → add
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            GSYLog.warning(.settings, "[AIKit] keychain add failed status=\(addStatus)")
            throw KeychainAPIKeyStoreError.unhandled(addStatus)
        }
    }

    // MARK: - 读

    /// 读 API Key。不存在 → 返回 nil（**不抛**——空态不是错误）。
    public func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainAPIKeyStoreError.unhandled(status)
        }
        guard let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty else {
            return nil
        }
        return s
    }

    // MARK: - 删

    /// 删 API Key。不存在静默成功——与 [save(nil)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/KeychainAPIKeyStore.swift) 行为一致。
    public func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.unhandled(status)
        }
    }

    // MARK: - UI 友好

    /// 给 Settings 面板用：返回 `sk-***...***xxxx` 掩码，不暴露完整 key。
    /// 空 / 短串直接返回空串（UI 据此显示 placeholder）。
    public static func masked(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.count <= 8 { return String(repeating: "*", count: raw.count) }
        let head = raw.prefix(3)
        let tail = raw.suffix(4)
        return "\(head)***...***\(tail)"
    }
}
