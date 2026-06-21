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
///
/// **并发与可变性契约（v1.5.7 显式化）**：
/// - `safety` / `trie` 一旦 init 完成即 immutable；`@unchecked Sendable` 是基于这一前提
///   外加 `_accessDeniedPaths` 用 `accessDeniedLock` 保护的可变状态。
/// - 调用 `setAccessDeniedPaths(_:)` 是更新可变状态的**唯一**入口，其它任何字段都不
///   可在 init 后改写；如新增字段必须重审 Sendable 假设。
/// - `moveToTrash` / `partitionByForbid` 可被多 actor / 多并发 await chain 调用，
///   `trie` / `safety` 的并发读由 SafetyKit 保证（参见 [VendorTrieNode](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L29) 的生命周期契约）。
public final class TrashPipeline: DeletionPipeline, @unchecked Sendable {

    private let safety: SafetyEngine
    /// 预建的 vendor 路径树（M4-P0 修复）。
    /// **生命周期**：init 注入，全程只读；read 阶段并发安全详见 [VendorTrieNode](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/VendorTrie.swift#L29) 契约。
    /// 非 nil 时 partitionByForbid 走 [SafetyEngine.evaluate(path:trie:home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L342)，
    /// 让 vendors.yaml 中通过 `paths: [{verdict: forbid}]` 声明的硬禁区
    /// （`~/.cargo/bin`、`~/.android/sdk`、`~/Library/Developer/Xcode/UserData/KeyBindings/...` 等）
    /// 在 pipeline 这道最后闸门也能被拦住——而不是仅靠 SafetyEngine 的硬编码列表。
    /// nil 时退回 base evaluate，与历史行为一致（仅供未注入 vendors 的测试 / 旧入口使用）。
    private let trie: VendorTrieNode?

    /// v1.3.zzzz：上层一票否决集合（`permissionDenied` / `tccProtected` 路径），
    /// `moveToTrash` 内部用 NSLock 保护读写，调用方通过 [setAccessDeniedPaths](#) 注入最新快照。
    /// 协议 [DeletionPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift#L37)
    /// 自 v2026.06.17 (AUDIT A2) 起取消 protocol extension 默认 no-op：每个实现都必须
    /// 显式提供本方法，杜绝"上层忘了调"被静默放行的脆弱契约。
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
        let result = await performMoveToTrash(paths: paths, dryRun: dryRun)
        return result.legacy
    }

    /// **v2026.06.17 (P0-3)**：原子返回结构化 outcome，避免 side-channel 单槽位被并发覆盖。
    /// 同时也会同步写入 `_lastOutcome`，保持老 callsite 通过 `snapshotLastOutcome()` 读取的兼容。
    public func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        return await performMoveToTrash(paths: paths, dryRun: dryRun)
    }

    /// **v2026.06.22**：用户从 [OperationResultSheet](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/OperationResultSheet.swift) "强制删除"
    /// 按钮触发的二次提交通道——**绕过 vendor 规则**（vendors.yaml 中
    /// `paths: [{verdict: forbid}]` 整段不再生效），但**保留** SafetyEngine 的所有
    /// 硬安全网（[hardForbidPrefixes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L185)
    /// / [userRootForbidden](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L155)
    /// / sensitive credentials / system volumes / hard 后缀）以及 `accessDeniedPaths`
    /// 一票否决——这两类是物理安全底线，无论用户多坚持都不允许越过。
    ///
    /// 实现：内部走与 `moveToTrash` 同一份 `performMoveToTrash`，但临时把 `trie` 置 nil
    /// 让 `partitionByForbid` 退化到无 vendor 规则的判定路径。
    ///
    /// 用户契约：UI 必须先弹一次「二次确认」对话框（建议命名"我已知风险，仍然删除"），
    /// 把"vendor 规则曾经拦下"的原因写明，避免误触。
    public func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        return await performMoveToTrash(paths: paths, dryRun: dryRun, skipVendorRule: true)
    }

    /// 共享实现：一次计算 legacy 4 元组 + 结构化 outcome，**返回值**即权威结果，
    /// 同时 `recordOutcome` 写入 lastOutcome 槽位仅为兼容旧 `snapshotLastOutcome()` 读取方。
    /// `skipVendorRule=true` 时把 trie 置 nil 让 [partitionByForbid](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L151)
    /// 走"无 vendor 规则"路径——仅供 `moveToTrashForce` 内部使用。
    private func performMoveToTrash(paths: [String], dryRun: Bool, skipVendorRule: Bool = false) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        guard !paths.isEmpty else {
            let outcome = TrashOutcome(movedPairs: [], failedPaths: [], safetyRejected: [], missingPaths: [])
            recordOutcome(outcome)
            return ((0, 0, nil, []), outcome)
        }
        GSYLog.info(.trash, "moveToTrash 开始 dryRun=\(dryRun) paths=\(paths.count)")

        // M4 闸门：先按 SafetyEngine 切批。被 forbid 的不进入后续逻辑（既不 dryRun present
        // 计数、也不真 recycle），统一计入 skipped。
        // v1.3.zzzz：把上层注入的 accessDeniedPaths 一并带上，让 partitionByForbid 一次切净
        // accessDenied + forbid 两类。
        let accessDenied = snapshotAccessDeniedPaths()
        let (allowed, rejected) = Self.partitionByForbid(
            paths: paths,
            safety: safety,
            trie: skipVendorRule ? nil : trie,
            accessDeniedPaths: accessDenied
        )
        if skipVendorRule {
            GSYLog.warning(.trash, "moveToTrashForce 启用 skipVendorRule=true vendor 规则被绕过，仅保留 SafetyEngine 硬安全网 + accessDenied")
        }
        if !rejected.isEmpty {
            GSYLog.warning(.trash, "moveToTrash 被 SafetyEngine 拦截 \(rejected.count)/\(paths.count) firstReason=\(rejected[0].reason.rawValue) firstPath=\(rejected[0].path)")
        }
        let safetyRejectedTuples: [(String, String)] = rejected.map { ($0.path, $0.reason.rawValue) }

        if dryRun {
            var present = 0
            var missingPaths: [String] = []
            let fm = FileManager.default
            for p in allowed {
                if fm.fileExists(atPath: p) {
                    present += 1
                } else {
                    missingPaths.append(p)
                }
            }
            let missing = missingPaths.count
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
            let outcome = TrashOutcome(movedPairs: [],
                                       failedPaths: [],
                                       safetyRejected: safetyRejectedTuples,
                                       missingPaths: missingPaths)
            recordOutcome(outcome)
            return ((present, skipped, err, []), outcome)
        }

        // 全部都被 forbid：直接返回，不打扰 NSWorkspace
        if allowed.isEmpty {
            GSYLog.warning(.trash, "moveToTrash 全量拦截 rejected=\(rejected.count) firstReason=\(rejected.first?.reason.rawValue ?? "unknown")")
            let outcome = TrashOutcome(movedPairs: [],
                                       failedPaths: [],
                                       safetyRejected: safetyRejectedTuples,
                                       missingPaths: [])
            recordOutcome(outcome)
            return ((
                0,
                rejected.count,
                "safety-blocked: \(rejected.count) 路径被安全策略拦截；首条原因=\(rejected.first?.reason.rawValue ?? "unknown")",
                []
            ), outcome)
        }

        // **v2026.06.16 修复 #2（system-images 删除拒绝）**：
        // 旧实现把 allowed 整批（可能 100+ 条、单条 1-3GB）一次性塞给 NSWorkspace.recycle。
        // NSWorkspace.recycle 在如下场景容易整批返回 "Some files could not be moved" 而不告知是哪条：
        // 1. 批内单条文件被进程占用（emulator / qemu 持有 system.img 句柄）
        // 2. 批内含 0444 只读文件 + xattr 复杂的 system image
        // 3. 单次回收站操作有路径/数量上限
        //
        // 新实现：分批 → 批失败回退到单 URL 隔离重试，能精确捕获哪条 path 失败、不让一条坏路径拖垮整批。
        let allowedURLs = allowed.map { URL(fileURLWithPath: $0) }
        let movedPairs = await recycleInBatches(urls: allowedURLs)
        let movedSet = Set(movedPairs.map { $0.0 })
        let failedPaths = allowed.filter { !movedSet.contains($0) }

        let outcome = TrashOutcome(movedPairs: movedPairs,
                                   failedPaths: failedPaths,
                                   safetyRejected: safetyRejectedTuples,
                                   missingPaths: [])
        recordOutcome(outcome)

        let movedCount = movedPairs.count
        let totalSkipped = failedPaths.count + rejected.count
        let firstReason = rejected.first?.reason.rawValue
        let err: String?
        if !failedPaths.isEmpty {
            let partialNote = movedCount > 0 ? "（已成功放入废纸篓 \(movedCount) 项，可在「最近删除」恢复）" : ""
            let firstFail = failedPaths.first.map { " 首个失败路径=\($0)" } ?? ""
            if !rejected.isEmpty {
                err = "recycle-failed: \(failedPaths.count) 项无法移到废纸篓\(partialNote)\(firstFail)"
                    + "；另有 \(rejected.count) 路径被安全策略拦截（首条原因=\(firstReason ?? "unknown")）"
            } else {
                err = "recycle-failed: \(failedPaths.count) 项无法移到废纸篓\(partialNote)\(firstFail)"
            }
        } else if !rejected.isEmpty {
            err = "safety-blocked: \(rejected.count) 路径被安全策略拦截；首条原因=\(firstReason ?? "unknown")"
        } else {
            err = nil
        }
        GSYLog.info(.trash, "moveToTrash 完成 moved=\(movedCount) failed=\(failedPaths.count) safetyRejected=\(rejected.count) totalSkipped=\(totalSkipped) pairs=\(movedPairs.count)")
        return ((movedCount, totalSkipped, err, movedPairs), outcome)
    }

    /// **v2026.06.16 修复 #2**：分批 recycle + 单 URL 隔离重试。
    /// - 第一轮：把 urls 按 `batchSize` 切片，每批一次 `NSWorkspace.recycle`；
    /// - 任一批失败（含部分失败）→ 只对该批未成功的 URL **逐条** 再 recycle 一次，
    ///   把"哪一条具体卡住"暴露出来，不让坏路径拖垮整批。
    ///
    /// **批大小 32**：经验值——既能利用 recycle 批处理优势降低系统开销，又能让单批失败时
    /// 隔离重试的代价（最多 32 次单 URL recycle）可控。可改 `batchSize` 调优。
    private func recycleInBatches(urls: [URL], batchSize: Int = 32) async -> [(String, String)] {
        var allMoved: [(String, String)] = []
        allMoved.reserveCapacity(urls.count)

        var idx = 0
        while idx < urls.count {
            let end = min(idx + batchSize, urls.count)
            let batch = Array(urls[idx..<end])
            idx = end

            let (batchMoved, batchHadError) = await Self.recycleOnce(urls: batch)
            allMoved.append(contentsOf: batchMoved)

            if batchHadError {
                // 批失败：对未成功项逐条隔离 recycle，精确定位失败路径
                let movedSet = Set(batchMoved.map { $0.0 })
                let unmoved = batch.filter { !movedSet.contains($0.path) }
                if !unmoved.isEmpty {
                    GSYLog.warning(.trash, "moveToTrash 批失败，回退到单 URL 隔离重试 batch=\(batch.count) unmoved=\(unmoved.count)")
                }
                for url in unmoved {
                    let (singleMoved, _) = await Self.recycleOnce(urls: [url])
                    allMoved.append(contentsOf: singleMoved)
                    // 单条仍失败：什么都不做——上层会通过 `allowed - allMoved` 反推 failedPaths
                }
            }
        }
        return allMoved
    }

    /// 单次 recycle 调用——把 NSWorkspace 的回调 async 化。
    /// 返回：(成功 pair 列表, 是否触发 error 回调)。
    /// 注意：error≠nil 不代表全失败，trashed 可能有部分项。
    private static func recycleOnce(urls: [URL]) async -> (moved: [(String, String)], hadError: Bool) {
        await withCheckedContinuation { (cc: CheckedContinuation<([(String, String)], Bool), Never>) in
            let gate = RecycleOnceGate(cc: cc)
            NSWorkspace.shared.recycle(urls) { trashed, error in
                let pairs: [(String, String)] = trashed.map { (orig, trashedURL) in
                    (orig.path, trashedURL.path)
                }
                if let error {
                    GSYLog.warning(.trash, "NSWorkspace.recycle 单批失败 batchSize=\(urls.count) moved=\(pairs.count) err=\(error.localizedDescription)")
                }
                gate.fire((pairs, error != nil))
            }
        }
    }

    // MARK: - lastOutcome 快照（OperationResultSheet 消费）

    private let outcomeLock = NSLock()
    private var _lastOutcome: TrashOutcome?

    private func recordOutcome(_ outcome: TrashOutcome) {
        outcomeLock.lock()
        _lastOutcome = outcome
        outcomeLock.unlock()
    }

    /// 暴露最后一次 moveToTrash 的结构化结果。UI 在 await 后立刻读。
    public func snapshotLastOutcome() -> TrashOutcome? {
        outcomeLock.lock()
        defer { outcomeLock.unlock() }
        return _lastOutcome
    }
}

/// `recycleOnce` 用的单次 continuation 守门员，避免 NSWorkspace 偶发的多次回调导致双 resume crash。
private final class RecycleOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cc: CheckedContinuation<([(String, String)], Bool), Never>

    init(cc: CheckedContinuation<([(String, String)], Bool), Never>) {
        self.cc = cc
    }

    func fire(_ value: ([(String, String)], Bool)) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        lock.unlock()
        cc.resume(returning: value)
    }
}

