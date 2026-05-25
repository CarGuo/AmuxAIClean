import Foundation
import XPCBridge
import SafetyKit

// 特权 Helper 入口（v0.2 安全闸门版本）。
//
// **三道闸门**（按调用顺序）：
//   1. shouldAcceptNewConnection：校验调用方 Team ID + bundle ID + designated requirement
//   2. HMAC 签名：DeletionTokenSigner.verify(envelope, key:)
//   3. SafetyEngine + HelperDecision：批内任一路径不合法整批拒绝
//
// **dryRun 默认 true**：环境变量 GSYCLEAN_ALLOW_REAL_DELETE=1 才会真删。
// **不 unlink，只 trash**：用 NSWorkspace.recycle，给用户最后一道安全网。
//
// 见 [PITFALLS §1, §3](file:///Users/guoshuyu/workspace/GSYCleanMac/PITFALLS.md)。

import AppKit
import Security

private let kAllowedTeamID = "TEAMIDPLACE"   // TODO: 替换为真实 Team ID
private let kAllowedClientBundleIDs: Set<String> = [
    "com.guoshuyu.cleanmac",
    "com.guoshuyu.cleanmac.dev"
]

private let allowRealDeletes: Bool = {
    ProcessInfo.processInfo.environment["GSYCLEAN_ALLOW_REAL_DELETE"] == "1"
}()

/// 共享密钥占位。生产环境用 keychain access group + kSecAttrAccessibleAfterFirstUnlock。
/// 这里临时从环境变量读，本地调试用。
private let sharedSigningKey: Data = {
    if let hex = ProcessInfo.processInfo.environment["GSYCLEAN_HMAC_KEY_HEX"],
       let data = Data(hexString: hex) {
        return data
    }
    return Data(repeating: 0, count: 32) // 故意留空：没配 key Helper 应该拒收所有签名
}()

private let decision = HelperDecision(allowRealDeletes: allowRealDeletes)

final class HelperListener: NSObject, NSXPCListenerDelegate, GSYCleanHelperXPC {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // —— 闸门 1：调用方代码签名校验 ——
        guard let info = peerSigningInfo(for: connection) else {
            NSLog("[GSYClean] reject XPC: cannot read peer signing info")
            return false
        }
        guard kAllowedClientBundleIDs.contains(info.bundleID) else {
            NSLog("[GSYClean] reject XPC: bundleID=\(info.bundleID)")
            return false
        }
        guard info.teamID == kAllowedTeamID else {
            NSLog("[GSYClean] reject XPC: teamID=\(info.teamID)")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: GSYCleanHelperXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(reply: @escaping (String) -> Void) {
        let euid = geteuid()
        reply("pong from helper, euid=\(euid), allowRealDeletes=\(allowRealDeletes)")
    }

    func moveToTrash(signedRequest: Data, reply: @escaping (Int, Int, String?) -> Void) {
        // —— 闸门 2：HMAC 签名 ——
        let envelope: SignedDeletionRequest
        do {
            envelope = try JSONDecoder().decode(SignedDeletionRequest.self, from: signedRequest)
        } catch {
            reply(0, 0, "decode-failed: \(error)")
            return
        }
        if let rejection = DeletionTokenSigner.verify(envelope, key: sharedSigningKey) {
            NSLog("[GSYClean] reject delete: \(rejection) reqID=\(envelope.request.requestID)")
            reply(0, envelope.request.paths.count, "signature-rejected: \(rejection)")
            return
        }

        // —— 闸门 3：SafetyEngine + HelperDecision（含 v1.3.zzzz Phase 3-E 第四道闸门：accessDeniedPaths）——
        let outcome = decision.decide(
            paths: envelope.request.paths,
            dryRun: envelope.request.dryRun,
            accessDeniedPaths: envelope.request.accessDeniedPaths
        )
        switch outcome {
        case .rejectBatch(let reason, let bad):
            NSLog("[GSYClean] reject batch: \(reason) bad=\(bad ?? "?") reqID=\(envelope.request.requestID)")
            reply(0, envelope.request.paths.count, reason)
            return
        case .allowDryRun:
            NSLog("[GSYClean] DRY-RUN reqID=\(envelope.request.requestID) paths=\(envelope.request.paths)")
            reply(envelope.request.paths.count, 0, nil) // 计入 movedCount 以便 UI 显示，但不真动
            return
        case .allowReal:
            break
        }

        // —— 真删（走废纸篓） ——
        var moved = 0
        var skipped = 0
        for p in envelope.request.paths {
            let url = URL(fileURLWithPath: p)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
                NSLog("[GSYClean] trashed: \(p) reqID=\(envelope.request.requestID)")
            } catch {
                skipped += 1
                NSLog("[GSYClean] trash-failed: \(p) err=\(error)")
            }
        }
        reply(moved, skipped, nil)
    }
}

// MARK: - Code signing inspection

private struct PeerSigningInfo {
    let teamID: String
    let bundleID: String
}

private func peerSigningInfo(for connection: NSXPCConnection) -> PeerSigningInfo? {
    let pid = connection.processIdentifier
    var pidValue = pid
    let pidData = Data(bytes: &pidValue, count: MemoryLayout<pid_t>.size)
    let attrs: NSDictionary = [
        kSecGuestAttributePid: pidData
    ]
    var code: SecCode?
    let status = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
    guard status == errSecSuccess, let code else { return nil }

    var infoDict: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
        code as! SecStaticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &infoDict
    )
    guard infoStatus == errSecSuccess, let info = infoDict as NSDictionary? else { return nil }

    let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
    let bundleID = (info[kSecCodeInfoIdentifier as String] as? String) ?? ""
    return PeerSigningInfo(teamID: teamID, bundleID: bundleID)
}

// MARK: - hex helper

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i..<i+2]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self = Data(bytes)
    }
}

@main
struct HelperMain {
    static func main() {
        let delegate = HelperListener()
        let listener = NSXPCListener(machServiceName: XPCNames.helperMachService)
        listener.delegate = delegate
        listener.resume()
        NSLog("[GSYClean] helper online; allowRealDeletes=\(allowRealDeletes)")
        RunLoop.current.run()
    }
}
