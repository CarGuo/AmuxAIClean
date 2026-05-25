import AppKit
import Foundation
import SafetyKit

/// v0 主链路：把文件移到废纸篓，不需要 root，不需要 Helper，不需要 Apple Developer Program。
///
/// **设计原则**（PITFALLS §5.9）：
/// - 走 [NSWorkspace.recycle](https://developer.apple.com/documentation/appkit/nsworkspace/1524800-recycle)：
///   - 用户可在 Finder 撤销
///   - 不调 unlink，可 100% 恢复
/// - dryRun=true 时只打印，不真动文件
/// - 任意一项失败都会被记入 skipped（不抛异常中断整批）
///
/// **M4 增强（清理更安全）**：
/// 即使 UI 层已经过 SafetyEngine 过滤，pipeline 自身仍然在最后一刻
/// 再走一次 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L203-L215)。
/// 任何被判 `.forbid` 的路径都**不会**进入 NSWorkspace.recycle，会被计入 skipped
/// 并通过 error 文案附带机器可读原因。这是最后一道闸门——防御:
/// 1. 调用方传入未经过滤的路径（比如未来直接接命令行 / scripting）
/// 2. UI 卡住老的 SafetyVerdict 缓存导致 forbid 漏检
/// 3. 用户硬塞 `..` 或绝对路径以外的形式
public final class TrashPipeline: DeletionPipeline, @unchecked Sendable {

    private let safety: SafetyEngine
    /// 预建的 vendor 路径树（M4-P0 修复）。
    /// 非 nil 时 partitionByForbid 走 [SafetyEngine.evaluate(path:trie:home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L342)，
    /// 让 vendors.yaml 中通过 `paths: [{verdict: forbid}]` 声明的硬禁区
    /// （`~/.cargo/bin`、`~/.android/sdk`、`~/Library/Developer/Xcode/UserData/KeyBindings/...` 等）
    /// 在 pipeline 这道最后闸门也能被拦住——而不是仅靠 SafetyEngine 的硬编码列表。
    /// nil 时退回 base evaluate，与历史行为一致（仅供未注入 vendors 的测试 / 旧入口使用）。
    private let trie: VendorTrieNode?

    /// v1.3.zzzz：上层一票否决集合（`permissionDenied` / `tccProtected` 路径），
    /// `moveToTrash` 内部用 NSLock 保护读写，调用方通过 [setAccessDeniedPaths](#) 注入最新快照。
    /// 协议 [DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HelperClient.swift#L10) 签名不变，避免影响 HelperClient / mock。
    private let accessDeniedLock = NSLock()
    private var _accessDeniedPaths: Set<String> = []

    public init(safety: SafetyEngine = SafetyEngine(),
                vendors: [VendorRule] = [],
                home: String = NSHomeDirectory()) {
        self.safety = safety
        self.trie = vendors.isEmpty ? nil : VendorTrie.build(vendors: vendors, home: home)
    }

    /// 替换上层注入的 accessDenied 集合。每次扫描完成后由 UI 层调一次。
    /// 线程安全：所有读写都在 [accessDeniedLock](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 下进行。
    public func setAccessDeniedPaths(_ paths: Set<String>) {
        accessDeniedLock.lock()
        _accessDeniedPaths = paths
        accessDeniedLock.unlock()
    }

    /// 当前 accessDenied 快照（仅供单测断言使用）。
    func snapshotAccessDeniedPaths() -> Set<String> {
        accessDeniedLock.lock()
        defer { accessDeniedLock.unlock() }
        return _accessDeniedPaths
    }

    /// 把传入的路径按 SafetyEngine 判定切成两堆：可继续 trash 的 + 被禁的（连同 rejection）。
    ///
    /// 暴露成 `static`（@testable 可见）的目的：
    /// - 单测可以独立验证拦截策略，无需触发真的 NSWorkspace.recycle
    /// - UI 层可以在弹窗前调一次拿到拒绝清单，提示用户"以下 N 项不会被删"
    ///
    /// `trie` 非 nil 时启用 vendor 路径覆盖判定（vendors.yaml `paths: [{verdict: forbid}]`），
    /// 命中即拒、reason=`.vendorPathRule`。这是修复"vendor-only forbid 路径在最后闸门漏拦"的硬伤。
    ///
    /// `accessDeniedPaths`（v1.3.zzzz）是上层一票否决集合：BulkScanner 期间被标记
    /// `permissionDenied` / `tccProtected` 的路径里实质没有数据，"对它 trash"是个伪操作；
    /// 命中即直接拒、reason=`.accessDenied`，**不再走 SafetyEngine**——优先级最高，
    /// 避免在审计/日志里把这类路径误归到 SafetyEngine 的 hardForbid 等原因。
    static func partitionByForbid(
        paths: [String],
        safety: SafetyEngine,
        trie: VendorTrieNode? = nil,
        accessDeniedPaths: Set<String> = [],
        home: String = NSHomeDirectory()
    ) -> (allowed: [String], rejected: [(path: String, reason: SafetyRejection)]) {
        var allowed: [String] = []
        var rejected: [(String, SafetyRejection)] = []
        allowed.reserveCapacity(paths.count)
        for p in paths {
            // 优先级 1：accessDenied 一票否决（最高优先，不走 SafetyEngine）
            if accessDeniedPaths.contains(p) {
                rejected.append((p, .accessDenied))
                continue
            }
            // 优先级 2：原有 SafetyEngine.evaluate
            let verdict: SafetyVerdict
            let reason: SafetyRejection
            if let trie {
                let (v, r, _) = safety.evaluate(path: p, trie: trie, home: home)
                verdict = v
                reason = r
            } else {
                (verdict, reason) = safety.evaluate(path: p, home: home)
            }
            if verdict == .forbid {
                rejected.append((p, reason))
            } else {
                allowed.append(p)
            }
        }
        return (allowed, rejected)
    }

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?) {
        guard !paths.isEmpty else { return (0, 0, nil) }

        // M4 闸门：先按 SafetyEngine 切批。被 forbid 的不进入后续逻辑（既不 dryRun present
        // 计数、也不真 recycle），统一计入 skipped。
        // v1.3.zzzz：把上层注入的 accessDeniedPaths 一并带上，让 partitionByForbid 一次切净
        // accessDenied + forbid 两类。
        let accessDenied = snapshotAccessDeniedPaths()
        let (allowed, rejected) = Self.partitionByForbid(
            paths: paths,
            safety: safety,
            trie: trie,
            accessDeniedPaths: accessDenied
        )

        if dryRun {
            var present = 0
            var missing = 0
            let fm = FileManager.default
            for p in allowed {
                if fm.fileExists(atPath: p) { present += 1 } else { missing += 1 }
            }
            let skipped = missing + rejected.count
            let err: String?
            if !rejected.isEmpty {
                err = "dryRun: \(rejected.count) 路径被安全策略拦截"
                    + (missing > 0 ? "，\(missing) 路径不存在或无权限" : "")
                    + "；首条原因=\(rejected[0].reason.rawValue)"
            } else if missing > 0 {
                err = "dryRun: \(missing) 路径不存在或无权限"
            } else {
                err = nil
            }
            return (present, skipped, err)
        }

        // 全部都被 forbid：直接返回，不打扰 NSWorkspace
        if allowed.isEmpty {
            return (
                0,
                rejected.count,
                "safety-blocked: \(rejected.count) 路径被安全策略拦截；首条原因=\(rejected.first?.reason.rawValue ?? "unknown")"
            )
        }

        let urls = allowed.map { URL(fileURLWithPath: $0) }
        let rejectedCount = rejected.count
        let firstReason = rejected.first?.reason.rawValue

        return await withCheckedContinuation { (cc: CheckedContinuation<(Int, Int, String?), Never>) in
            let gate = TrashGate(cc: cc)
            // recycle 是 async 回调，且最后只回调一次（成功 trashedURLs 列出，失败给 error）
            NSWorkspace.shared.recycle(urls) { trashed, error in
                let movedCount = trashed.count
                let recycleSkipped = urls.count - movedCount
                let totalSkipped = recycleSkipped + rejectedCount
                let err: String?
                if let error {
                    if rejectedCount > 0 {
                        err = "recycle-failed: \(error.localizedDescription)"
                            + "；另有 \(rejectedCount) 路径被安全策略拦截"
                            + "（首条原因=\(firstReason ?? "unknown")）"
                    } else {
                        err = "recycle-failed: \(error.localizedDescription)"
                    }
                } else if rejectedCount > 0 {
                    err = "safety-blocked: \(rejectedCount) 路径被安全策略拦截；首条原因=\(firstReason ?? "unknown")"
                } else {
                    err = nil
                }
                gate.fire((movedCount, totalSkipped, err))
            }
        }
    }
}

/// recycle 回调可能在任意线程；用 OneShot 保证 cc 只 resume 一次。
private final class TrashGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cc: CheckedContinuation<(Int, Int, String?), Never>

    init(cc: CheckedContinuation<(Int, Int, String?), Never>) {
        self.cc = cc
    }

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
