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

    /// 注入"上层一票否决路径集合"（v1.3.zzzz Phase 3-A 协议化 → Phase 3-E 全链路接通）。
    ///
    /// 协议层接受这个钩子是为了**让"漏调=误拒"风险被强类型保护**：
    /// 历史上 [MainView.performDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1141)
    /// 只对 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
    /// 走 `if let trash = pipeline as? TrashPipeline` cast 注入，
    /// 一旦 v2.0 切到 [HelperClient](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift#L43)
    /// 这条 cast 默默落空 → BulkScanner 期间被 `permissionDenied` / `tccProtected` 标记的
    /// 路径会被悄悄"放行"到 Helper 端真删。
    ///
    /// **现状（v1.3.zzzz Phase 3-E）**：
    /// - [TrashPipeline.setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L63) 在主 App 进程内 stash + partitionByForbid 拦
    /// - [HelperClient.setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 把集合**随 envelope 序列化**跨进程发给 Helper，
    ///   Helper 端 [HelperDecision.decide](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift) 第四道闸门拒批
    /// - [MockHelperClient.setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 同等接通，便于单测
    ///
    /// 协议层仍保留 protocol extension 默认 no-op——给未来新加的 `DeletionPipeline` 实现
    /// （如 dry-run-only 调试管道、远程 audit 管道）一个安全默认值，不强迫每个实现都接 accessDenied。
    func setAccessDeniedPaths(_ paths: Set<String>)
}

extension DeletionPipeline {
    /// 默认 no-op：给"不需要 accessDenied 投影"的 DeletionPipeline 实现一个安全默认值。
    /// TrashPipeline / HelperClient / MockHelperClient 都各自 override 真实现。
    public func setAccessDeniedPaths(_ paths: Set<String>) {
        // intentional no-op
    }
}

/// 真 XPC 客户端 —— 通过 mach service 连 Helper。
///
/// 注意：在 `SWIFT_STRICT_CONCURRENCY=complete` 下，NSXPCConnection 的回调不是
/// Sendable，所以这里用经典锁 + `@unchecked Sendable` 保证只 resume 一次。
public final class HelperClient: DeletionPipeline, @unchecked Sendable {
    private let key: Data
    private let machName: String

    /// v1.3.zzzz Phase 3-E：上层一票否决路径快照。
    /// 写入路径在 [setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 里加锁；
    /// 读取在 [moveToTrash](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 入口处一次性 snapshot 然后随 envelope 序列化跨进程发给 Helper——
    /// Helper 进程独立内存，必须随 IPC 一并送达。
    private let accessDeniedLock = NSLock()
    private var _accessDeniedPaths: Set<String> = []

    public init(signingKey: Data, machName: String = XPCNames.helperMachService) {
        self.key = signingKey
        self.machName = machName
    }

    /// 替换 accessDenied 集合（原始字符串入集，不在 client 端归一化——
    /// 路径标准化由 Helper 端 [HelperDecision.decide](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift) 与 SafetyEngine 自己负责）。
    public func setAccessDeniedPaths(_ paths: Set<String>) {
        accessDeniedLock.lock()
        _accessDeniedPaths = paths
        accessDeniedLock.unlock()
    }

    /// 取当前快照，用 sorted 数组返回——保证 [DeletionRequest.canonicalize](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/XPCBridge/Sources/XPCBridge/HelperProtocol.swift) 的 HMAC
    /// 在主 App 与 Helper 两端字节对齐。
    private func snapshotAccessDeniedPathsSorted() -> [String] {
        accessDeniedLock.lock()
        let arr = Array(_accessDeniedPaths)
        accessDeniedLock.unlock()
        return arr.sorted()
    }

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?) {
        let request = DeletionRequest(
            paths: paths,
            dryRun: dryRun,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(30).timeIntervalSince1970,
            requestID: UUID().uuidString,
            accessDeniedPaths: snapshotAccessDeniedPathsSorted()
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

    /// v1.3.zzzz Phase 3-E：与 [HelperClient._accessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift) 一致的语义。
    /// 因为协议方法 `setAccessDeniedPaths` 是 sync 而 actor 默认 isolated，必须用 NSLock + nonisolated 存储——
    /// 不能直接 stash 在 actor 状态里（会要求 protocol 改成 async）。
    private nonisolated(unsafe) let accessDeniedLock = NSLock()
    private nonisolated(unsafe) var _accessDeniedPaths: Set<String> = []

    public init(signingKey: Data) {
        self.key = signingKey
    }

    public nonisolated func setAccessDeniedPaths(_ paths: Set<String>) {
        accessDeniedLock.lock()
        _accessDeniedPaths = paths
        accessDeniedLock.unlock()
    }

    private nonisolated func snapshotAccessDeniedPathsSorted() -> [String] {
        accessDeniedLock.lock()
        let arr = Array(_accessDeniedPaths)
        accessDeniedLock.unlock()
        return arr.sorted()
    }

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?) {
        let request = DeletionRequest(
            paths: paths,
            dryRun: dryRun,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(30).timeIntervalSince1970,
            requestID: UUID().uuidString,
            accessDeniedPaths: snapshotAccessDeniedPathsSorted()
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
