import Foundation
import CommonCrypto

/// 主 App ↔ 特权 Helper 之间的 XPC 协议。
///
/// 设计原则（写死的红线，**别动**）：
/// - **路径必须由主 App HMAC 签名**：Helper 不接受任何"裸路径"，避免被恶意注入路径
/// - **默认 moveToTrash，不 unlink**：用户最后的安全网是废纸篓
/// - **默认 dryRun=true**：调试 / 灰度阶段只打日志不动手
/// - **Helper 必须二重检查**：即使签名通过，仍要走 SafetyEngine + 硬编码黑名单
/// - 调用方校验：Helper 的 `shouldAcceptNewConnection` 必须验 Team ID + Bundle ID + designated requirement
///
/// 见 [PITFALLS.md §1, §3](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)。
@objc public protocol GSYCleanHelperXPC {
    /// 健康检查。
    func ping(reply: @escaping (String) -> Void)

    /// 把签名后的路径条目移动到调用用户的废纸篓。
    /// - Parameters:
    ///   - signedRequest: `DeletionRequest` 的 JSON Data（含 paths + nonce + expiresAt + HMAC）
    ///   - reply: (movedCount, skippedCount, errorDescription)
    func moveToTrash(
        signedRequest: Data,
        reply: @escaping (Int, Int, String?) -> Void
    )
}

/// XPC mach service 名称——必须与 Helper 的 LaunchDaemon plist 中 `MachServices` 一致。
public enum XPCNames {
    public static let helperMachService = "com.guoshuyu.cleanmac.helper"
}

// MARK: - 删除请求 / HMAC 签名

/// 主 App → Helper 的删除请求结构。
///
/// **不可变**：所有字段都参与 HMAC 计算；任何一个字段被改 Helper 都会拒绝。
public struct DeletionRequest: Codable, Sendable, Equatable {
    /// 要删的绝对路径列表。
    public let paths: [String]
    /// 是否仅 dry-run（默认 true，**只有用户在 UI 明确点过"确认删除"才会传 false**）。
    public let dryRun: Bool
    /// 一次性随机数，防 replay。
    public let nonce: String
    /// 过期时间戳（Unix epoch seconds），> 60s 的请求 Helper 会拒。
    public let expiresAt: TimeInterval
    /// 请求 ID（审计用）。
    public let requestID: String
    /// BulkScanner 期间被 [`permissionDenied`/`tccProtected`](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift#L14-L28) 标记的"上层一票否决"路径集合。
    ///
    /// **设计意图**（v1.3.zzzz Phase 3-E）：把"扫描没扫成功"这条软证据作为 Helper 端的**第四道闸门**输入——
    /// `paths` 里**不能**与 `accessDeniedPaths` 有交集（典型场景：BulkScanner 标了 `~/Library` 拿不到 inode，
    /// 但主 App 误把 `~/Library/Caches/foo` 派下来真删）。
    /// - 必须**有序**：参与 HMAC canonical JSON 计算，乱序会导致主 App 与 Helper 算出不同签名
    /// - 默认空数组：保持与 v0.2 envelope 二进制兼容（Codable decode 老主 App 请求时缺字段不会抛）
    public let accessDeniedPaths: [String]

    public init(paths: [String],
                dryRun: Bool,
                nonce: String,
                expiresAt: TimeInterval,
                requestID: String,
                accessDeniedPaths: [String] = []) {
        self.paths = paths
        self.dryRun = dryRun
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.requestID = requestID
        self.accessDeniedPaths = accessDeniedPaths
    }

    // MARK: - Codable（自定义实现保证 decode 老 envelope 时 accessDeniedPaths 缺失 fallback 空数组）

    private enum CodingKeys: String, CodingKey {
        case paths, dryRun, nonce, expiresAt, requestID, accessDeniedPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.paths = try c.decode([String].self, forKey: .paths)
        self.dryRun = try c.decode(Bool.self, forKey: .dryRun)
        self.nonce = try c.decode(String.self, forKey: .nonce)
        self.expiresAt = try c.decode(TimeInterval.self, forKey: .expiresAt)
        self.requestID = try c.decode(String.self, forKey: .requestID)
        self.accessDeniedPaths = try c.decodeIfPresent([String].self, forKey: .accessDeniedPaths) ?? []
    }

    /// 自定义 encode：accessDeniedPaths 为空时**完全省略字段**——保证 v0.2 老主 App 签的
    /// 不含该字段的 envelope，与 v1.3.zzzz 新 Helper 重新 canonicalize 后**字节相等**，签名互通。
    /// 非空时正常 encode（已经在 init 时由调用方保证 sorted）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        try c.encode(dryRun, forKey: .dryRun)
        try c.encode(nonce, forKey: .nonce)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(requestID, forKey: .requestID)
        if !accessDeniedPaths.isEmpty {
            try c.encode(accessDeniedPaths, forKey: .accessDeniedPaths)
        }
    }
}

/// 带签名的请求信封。
public struct SignedDeletionRequest: Codable, Sendable {
    public let request: DeletionRequest
    /// 对 `request` 的 canonical JSON 计算的 HMAC-SHA256，base64 编码。
    public let signature: String

    public init(request: DeletionRequest, signature: String) {
        self.request = request
        self.signature = signature
    }
}

/// HMAC 签名 / 验签工具。
///
/// 共享密钥**只存在内存**，Helper 启动时从 keychain (kSecAttrAccessibleAfterFirstUnlock) 读取，
/// 主 App 通过同一个 keychain access group 取得。**不要把 secret 写进二进制或源码**。
public enum DeletionTokenSigner {
    /// 把 `request` 序列化成 canonical JSON。
    /// - 字段顺序固定：paths, dryRun, nonce, expiresAt, requestID
    /// - 数组保留原顺序（保证签名两端一致）
    public static func canonicalize(_ request: DeletionRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    /// 计算签名。
    public static func sign(_ request: DeletionRequest, key: Data) throws -> String {
        let payload = try canonicalize(request)
        let mac = HMACSHA256.compute(key: key, message: payload)
        return mac.base64EncodedString()
    }

    /// 验证签名 + 过期 + dryRun 默认值。
    /// - Returns: `nil` 表示通过；非 nil 是拒绝原因。
    public static func verify(_ envelope: SignedDeletionRequest, key: Data, now: Date = Date()) -> String? {
        let expected: String
        do {
            expected = try sign(envelope.request, key: key)
        } catch {
            return "sign-failed: \(error)"
        }
        // 用常量时间比较
        guard ConstantTimeCompare.equals(envelope.signature, expected) else {
            return "bad-signature"
        }
        if envelope.request.expiresAt <= now.timeIntervalSince1970 {
            return "expired"
        }
        if envelope.request.expiresAt - now.timeIntervalSince1970 > 60 {
            return "expires-too-far"
        }
        if envelope.request.paths.isEmpty {
            return "empty-paths"
        }
        return nil
    }
}

// MARK: - 内部工具

enum HMACSHA256 {
    /// 纯 Foundation/CommonCrypto 实现。
    static func compute(key: Data, message: Data) -> Data {
        var mac = Data(count: 32)
        mac.withUnsafeMutableBytes { macBuf in
            message.withUnsafeBytes { msgBuf in
                key.withUnsafeBytes { keyBuf in
                    CCHmacShim.run(
                        keyBytes: keyBuf.baseAddress, keyLen: key.count,
                        msgBytes: msgBuf.baseAddress, msgLen: message.count,
                        outBytes: macBuf.baseAddress
                    )
                }
            }
        }
        return mac
    }
}

/// 桥到 CommonCrypto 的 CCHmac。
enum CCHmacShim {
    static func run(
        keyBytes: UnsafeRawPointer?, keyLen: Int,
        msgBytes: UnsafeRawPointer?, msgLen: Int,
        outBytes: UnsafeMutableRawPointer?
    ) {
        CCHmac(
            CCHmacAlgorithm(kCCHmacAlgSHA256),
            keyBytes, keyLen,
            msgBytes, msgLen,
            outBytes
        )
    }
}

enum ConstantTimeCompare {
    /// 常量时间字符串比较，防 timing attack。
    static func equals(_ a: String, _ b: String) -> Bool {
        let aData = Data(a.utf8)
        let bData = Data(b.utf8)
        if aData.count != bData.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aData.count {
            diff |= aData[i] ^ bData[i]
        }
        return diff == 0
    }
}
