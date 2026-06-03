import AppKit
import Foundation
import LogKit
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
    /// 协议 [DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift) 签名不变，
    /// 给未来其它 DeletionPipeline 实现一个安全默认值（v1.3.zzzz 路线 B 删 Helper 后实际只剩 TrashPipeline 一份）。
    ///
    /// **锁的作用范围（必读）**：`accessDeniedLock` 只盖 Set 的"写入"和"快照交接"
    /// （[setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L52) /
    /// [snapshotAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L62)）
    /// 这两个 O(1) 临界区。`partitionByForbid` 内部的 `for p in paths` 循环里走的是
    /// **值拷贝（CoW）后的本地 Set.contains O(1)**，**不持锁**——这是设计而非疏漏，避免锁
    /// 在大批量删除时成为热点。改动该锁范围前请确保理解此约束。
    private let accessDeniedLock = NSLock()
    private var _accessDeniedPaths: Set<String> = []

    public init(safety: SafetyEngine = SafetyEngine(),
                vendors: [VendorRule] = [],
                home: String = NSHomeDirectory()) {
        self.safety = safety
        self.trie = vendors.isEmpty ? nil : VendorTrie.build(vendors: vendors, home: home)
    }

    /// 替换上层注入的 accessDenied 集合。每次扫描完成后由 UI 层调一次。
    /// 线程安全：所有读写都在 [accessDeniedLock](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L43) 下进行。
    ///
    /// **路径标准化（v1.3.zzzz Phase 2-F-A）**：入集前对每条路径做
    /// `URL(fileURLWithPath:).standardizedFileURL.path`，把 `/private/var/folders/...`
    /// 这类 firmlink 折叠成 `/var/folders/...`，与 [SafetyEngine.evaluate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L215)
    /// 的口径一致；`partitionByForbid` 比较时对入参 `p` 也做同样处理（见 [normalize](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)）。
    /// 防御场景：BulkScanner 给的 deniedPaths 与 selectedRows 里的 url.path 来源不同，
    /// firmlink 形态可能不一致——任一侧未标准化都会造成"明明在 deniedSet 却 contains 落空"
    /// 漏拦。
    public func setAccessDeniedPaths(_ paths: Set<String>) {
        let normalized = Set(paths.map(Self.normalizePath))
        accessDeniedLock.lock()
        _accessDeniedPaths = normalized
        accessDeniedLock.unlock()
    }

    /// 当前 accessDenied 快照（仅供单测断言使用）。已经是标准化后的形式。
    func snapshotAccessDeniedPaths() -> Set<String> {
        accessDeniedLock.lock()
        defer { accessDeniedLock.unlock() }
        return _accessDeniedPaths
    }

    /// 路径标准化（v1.3.zzzz Phase 2-F-A）：折叠 firmlink，与 SafetyEngine 口径对齐。
    ///
    /// **为什么不用 `URL(fileURLWithPath:).standardizedFileURL.path`**：
    /// macOS 的 `standardizedFileURL` 对**不存在**的路径不会折叠 firmlink（实测：
    /// `/private/var/folders/zz/abc/T/x` 不存在时会原样返回 `/private/var/folders/...`，
    /// 不会变成 `/var/folders/...`）。这导致 BulkScanner 给的 `/private/var/...` 形态
    /// 和 selectedRows 拿到的 `/var/...` 形态在 `Set.contains` 上对不上。
    /// SafetyEngine 之所以能正常工作，是因为它的 hardForbid 列表里同时膨胀了
    /// `/private/var` 和 `/var` 两套前缀（见 [hardForbidPrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L185)），
    /// 不依赖路径标准化吃 firmlink。
    ///
    /// **本函数实现**：用纯字符串规则折叠已知 firmlink 前缀，与磁盘是否存在解耦：
    /// - `/private/var/...` → `/var/...`
    /// - `/private/tmp/...` → `/tmp/...`
    /// - `/private/etc/...` → `/etc/...`
    ///
    /// 这三条覆盖 macOS 当前所有标准 firmlink，且与 `getattrlist(ATTR_CMNEXT_NOFIRMLINKPATH)`
    /// 折叠出的形态等价。再叠一层 `URL.standardizedFileURL` 处理 `..` / 重复 `/`。
    /// 复杂度：单次 O(path 长度)。调用规模是 paths.count（几十~几千）级别，
    /// 不是 BulkScanner 节点数（30w）级别，可放心走。
    static func normalizePath(_ raw: String) -> String {
        let trimmed = URL(fileURLWithPath: raw).standardizedFileURL.path
        // 已知 firmlink 前缀：长前缀优先，避免 `/private/var/...` 被 `/private/...` 截短。
        let firmlinks: [(String, String)] = [
            ("/private/var/", "/var/"),
            ("/private/tmp/", "/tmp/"),
            ("/private/etc/", "/etc/"),
        ]
        for (priv, pub) in firmlinks {
            if trimmed.hasPrefix(priv) {
                return pub + String(trimmed.dropFirst(priv.count))
            }
            // 整体等于 `/private/var` 这种边界（无尾斜杠）也归一化
            let privNoSlash = String(priv.dropLast())
            if trimmed == privNoSlash {
                return String(pub.dropLast())
            }
        }
        return trimmed
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
    ///
    /// **路径口径（v1.3.zzzz Phase 2-F-A）**：循环内对每个待判路径 p 做
    /// [normalizePath](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L80)
    /// 后再 `Set.contains`，确保两侧 firmlink 形态一致；`accessDeniedPaths` 入参允许
    /// 调用方传入未标准化的 Set（外部测试 / 旧 callsite），Set 元素也被假定将经过
    /// [setAccessDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L63)
    /// 注入路径标准化——若直接以 static 方式调用，调用方需自行确保两侧口径一致。
    /// `rejected` 仍返回原始 p（不替换为标准化后的字符串），便于 UI / 日志展示用户能识别的路径。
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
        // accessDeniedPaths 容量小（几十~几千），对它做一次性 normalize 比每个 p 都拿临时 Set 划算。
        // 当 set 已经经 setAccessDeniedPaths 注入时，normalize 是幂等空操作。
        let normalizedDenied: Set<String> = accessDeniedPaths.isEmpty
            ? []
            : Set(accessDeniedPaths.map(normalizePath))
        for p in paths {
            // 优先级 1：accessDenied 一票否决（最高优先，不走 SafetyEngine）
            // 用 normalize(p) 与 normalizedDenied 比，确保 /private/var ↔ /var firmlink 互通。
            if !normalizedDenied.isEmpty,
               normalizedDenied.contains(normalizePath(p))
            {
                rejected.append((p, .accessDenied))
                continue
            }
            // 优先级 2：原有 SafetyEngine.evaluate（内部已自带 standardizedFileURL）
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

    public func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)]) {
        guard !paths.isEmpty else { return (0, 0, nil, []) }
        GSYLog.info(.trash, "moveToTrash 开始 dryRun=\(dryRun) paths=\(paths.count)")

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
        if !rejected.isEmpty {
            GSYLog.warning(.trash, "moveToTrash 被 SafetyEngine 拦截 \(rejected.count)/\(paths.count) firstReason=\(rejected[0].reason.rawValue) firstPath=\(rejected[0].path)")
        }

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
            GSYLog.info(.trash, "moveToTrash dryRun 完成 present=\(present) skipped=\(skipped) missing=\(missing)")
            return (present, skipped, err, [])
        }

        // 全部都被 forbid：直接返回，不打扰 NSWorkspace
        if allowed.isEmpty {
            GSYLog.warning(.trash, "moveToTrash 全量拦截 rejected=\(rejected.count) firstReason=\(rejected.first?.reason.rawValue ?? "unknown")")
            return (
                0,
                rejected.count,
                "safety-blocked: \(rejected.count) 路径被安全策略拦截；首条原因=\(rejected.first?.reason.rawValue ?? "unknown")",
                []
            )
        }

        let urls = allowed.map { URL(fileURLWithPath: $0) }
        let rejectedCount = rejected.count
        let firstReason = rejected.first?.reason.rawValue

        return await withCheckedContinuation { (cc: CheckedContinuation<(Int, Int, String?, [(String, String)]), Never>) in
            let gate = TrashGate(cc: cc)
            // recycle 是 async 回调，且最后只回调一次（成功 trashedURLs 列出，失败给 error）
            NSWorkspace.shared.recycle(urls) { trashed, error in
                let movedCount = trashed.count
                let recycleSkipped = urls.count - movedCount
                let totalSkipped = recycleSkipped + rejectedCount
                // Step 7：把 NSWorkspace 回填的 [URL: URL] 转成 (originalPath, trashedPath) pair。
                // 仅在 error == nil 时落盘——recycle 的语义是"成功项放进 trashed 字典；失败项不在
                // 字典里，但 error 描述聚合错误"。partial success 的情况字典只有部分 entry，
                // 此时我们倾向于不写 history（保守：宁缺勿乱），等下次干净的成功再写。
                let pairs: [(String, String)]
                if error == nil {
                    pairs = trashed.map { (orig, trashedURL) in
                        (orig.path, trashedURL.path)
                    }
                } else {
                    pairs = []
                }
                let err: String?
                if let error {
                    GSYLog.error(.trash, "NSWorkspace.recycle 失败 moved=\(movedCount)/\(urls.count) err=\(error.localizedDescription)")
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
                GSYLog.info(.trash, "moveToTrash 完成 moved=\(movedCount) skipped=\(totalSkipped) pairs=\(pairs.count)")
                gate.fire((movedCount, totalSkipped, err, pairs))
            }
        }
    }
}

/// recycle 回调可能在任意线程；用 OneShot 保证 cc 只 resume 一次。
private final class TrashGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cc: CheckedContinuation<(Int, Int, String?, [(String, String)]), Never>

    init(cc: CheckedContinuation<(Int, Int, String?, [(String, String)]), Never>) {
        self.cc = cc
    }

    @discardableResult
    func fire(_ value: (Int, Int, String?, [(String, String)])) -> Bool {
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
