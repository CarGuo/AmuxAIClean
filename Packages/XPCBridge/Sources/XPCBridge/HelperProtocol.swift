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

    public init(paths: [String], dryRun: Bool, nonce: String, expiresAt: TimeInterval, requestID: String) {
        self.paths = paths
        self.dryRun = dryRun
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.requestID = requestID
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
