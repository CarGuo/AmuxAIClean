import Foundation
import XPCBridge

/// 删除链路抽象 —— 实现一份真 XPC，一份 mock。
///
/// **设计原则**（PITFALLS §1.5）：
/// - 主 App 永远只发**已签名**的请求
/// - 默认 dryRun=true（PITFALLS §5.7：trash preview 模式）
/// - 5s 超时（PITFALLS §1.7：禁止同步阻塞）
public protocol DeletionPipeline: Sendable {
    /// - Returns: (movedCount, skippedCount, error?)
    func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?)
}

/// 真 XPC 客户端 —— 通过 mach service 连 Helper。
///
/// 注意：在 `SWIFT_STRICT_CONCURRENCY=complete` 下，NSXPCConnection 的回调不是
/// Sendable，所以这里用经典锁 + `@unchecked Sendable` 保证只 resume 一次。
public final class HelperClient: DeletionPipeline, @unchecked Sendable {
    private let key: Data
    private let machName: String

    public init(signingKey: Data, machName: String = XPCNames.helperMachService) {
        self.key = signingKey
        self.machName = machName
    }

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?) {
        let request = DeletionRequest(
            paths: paths,
            dryRun: dryRun,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(30).timeIntervalSince1970,
            requestID: UUID().uuidString
        )
        let signature: String
        do {
            signature = try DeletionTokenSigner.sign(request, key: key)
        } catch {
            return (0, paths.count, "sign-failed: \(error)")
        }
        let envelope = SignedDeletionRequest(request: request, signature: signature)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(envelope)
        } catch {
            return (0, paths.count, "encode-failed: \(error)")
        }

        let pathsCount = paths.count
        let machName = self.machName
        return await withCheckedContinuation { (cc: CheckedContinuation<(Int, Int, String?), Never>) in
            let gate = OneShot(cc: cc)
            let conn = NSXPCConnection(machServiceName: machName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: GSYCleanHelperXPC.self)
            conn.invalidationHandler = {
                gate.fire((0, pathsCount, "xpc-invalidated"))
            }
            conn.interruptionHandler = {
                gate.fire((0, pathsCount, "xpc-interrupted"))
            }
            conn.resume()

            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                gate.fire((0, pathsCount, "proxy-error: \(error)"))
                conn.invalidate()
            } as? GSYCleanHelperXPC
            guard let proxy else {
                gate.fire((0, pathsCount, "proxy-cast-failed"))
                conn.invalidate()
                return
            }
            proxy.moveToTrash(signedRequest: payload) { moved, skipped, err in
                gate.fire((moved, skipped, err))
                conn.invalidate()
            }
            // 5s 超时（PITFALLS §1.7）
            // NSXPCConnection 不是 Sendable，用 ConnHolder 抓住引用
            let connHolder = ConnHolder(conn: conn)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if gate.fire((0, pathsCount, "timeout-5s")) {
                    connHolder.invalidate()
                }
            }
        }
    }
}

/// 把 NSXPCConnection 包成 unchecked Sendable，仅供超时分支使用。
private final class ConnHolder: @unchecked Sendable {
    private let conn: NSXPCConnection
    init(conn: NSXPCConnection) { self.conn = conn }
    func invalidate() { conn.invalidate() }
}

/// 一次性闸门 —— 保证 continuation 只被 resume 一次。
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cc: CheckedContinuation<(Int, Int, String?), Never>

    init(cc: CheckedContinuation<(Int, Int, String?), Never>) {
        self.cc = cc
    }

    /// - Returns: 是否真的把 cc 用掉了（true=本次胜出）。
    @discardableResult
    func fire(_ value: (Int, Int, String?)) -> Bool {
        lock.lock()
        if fired {
            lock.unlock()
            return false
        }
        fired = true
        lock.unlock()
        cc.resume(returning: value)
        return true
    }
}

/// 本地 mock —— 不依赖 launchd / 公证 / 签名安装，只在内存里跑闸门 2 + 闸门 3。
/// 用途：D-4 集成验证 + 单测。
public actor MockHelperClient: DeletionPipeline {
    private let key: Data
    public private(set) var lastSignedPayload: Data?
    public private(set) var lastResult: (Int, Int, String?)?

    public init(signingKey: Data) {
        self.key = signingKey
    }

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?) {
        let request = DeletionRequest(
            paths: paths,
            dryRun: dryRun,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(30).timeIntervalSince1970,
            requestID: UUID().uuidString
        )
        do {
            let signature = try DeletionTokenSigner.sign(request, key: key)
            let envelope = SignedDeletionRequest(request: request, signature: signature)
            let payload = try JSONEncoder().encode(envelope)
            lastSignedPayload = payload

            // 闸门 2 自检（保证主 App 自己签的能被自己验通过）
            if let rejection = DeletionTokenSigner.verify(envelope, key: key) {
                let r = (0, paths.count, "mock-self-verify-failed: \(rejection)")
                lastResult = r
                return r
            }
            // mock 永远 dry-run，不真动文件
            let r: (Int, Int, String?) = dryRun
                ? (paths.count, 0, nil)
                : (paths.count, 0, "mock-only-dry-run")
            lastResult = r
            return r
        } catch {
            let r = (0, paths.count, "mock-failed: \(error)")
            lastResult = r
            return r
        }
    }
}
