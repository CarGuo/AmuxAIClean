import Foundation

/// 删除链路抽象 —— v1.3.zzzz 之后只保留主 App 内 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 一份实现。
///
/// 历史背景（已下线）：早期版本曾设计过 HelperClient（XPC + LaunchDaemon + HMAC 三道闸门）作为另一份实现，
/// 思路是"App 端只发请求，Helper 端做最后一道安全校验"。在产品仅删 `$HOME` 下用户态文件、
/// 完全不需要 root 权限的现实场景里，Helper 链路属于纯负担——增加进程数、增加 SMAppService 注册流程、
/// 增加用户首跑授权对话框、增加 Free Apple ID 自签下根本跑不通的 Team ID 校验旁路——
/// 所以 v1.3.zzzz 直接把 Helper / HelperClient / XPCBridge 整套删除，只留 TrashPipeline。
///
/// **设计原则**：
/// - 默认 dryRun=true（PITFALLS §5.7：trash preview 模式）
/// - 5s 超时（PITFALLS §1.7：禁止同步阻塞）
public protocol DeletionPipeline: Sendable {
    /// - Returns: (movedCount, skippedCount, error?, trashedPairs)
    ///
    /// `trashedPairs` 是 `[(originalPath, trashedPath)]`，仅在 `dryRun=false` 且
    /// NSWorkspace.recycle 真正把文件移入用户废纸篓后才有非空内容；其余路径
    /// （dryRun / 全 forbid 拦截 / recycle 失败）一律返回空数组。Step 7
    /// UndoHistory 用这份 pair 写入 `~/Library/Application Support/GSYCleanMac/UndoHistory.json`
    /// 以支持"最近清理 → 恢复"。
    func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)])

    /// 注入"上层一票否决路径集合"（v1.3.zzzz Phase 3-A 协议化 → Phase 3-E 全链路接通）。
    ///
    /// 协议层接受这个钩子是为了**让"漏调=误拒"风险被强类型保护**：
    /// 历史上 [MainView.performDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 只对 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
    /// 走 `if let trash = pipeline as? TrashPipeline` cast 注入；现在 Helper 路线已下线，
    /// 实际只剩 TrashPipeline 一份实现。
    ///
    /// **v2026.06.17 (AUDIT A2)**：取消 protocol 默认 no-op 实现 ——
    /// 默认 no-op 让"上层忘了调"变成静默放行而非 compile-error，是契约靠手记维系的脆弱点。
    /// 现在所有 `DeletionPipeline` 实现都必须显式提供该方法：
    /// - 真删除链路（[TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)）：真存进 `accessDeniedPaths` Set 并 normalize；
    /// - 测试 stub / dry-run 调试管道：可显式 no-op，但**必须自己写出来**，签字画押。
    func setAccessDeniedPaths(_ paths: Set<String>)

    /// v2026.06.16：上一轮 `moveToTrash` 的**结构化结果快照**——给 OperationResultSheet 用。
    ///
    /// 旧协议返回的 4 元组 `(moved, skipped, err?, pairs)` 只能用一行文案拼接
    /// "Trash: X succeeded / Y skipped\nError: ..."，UI 没法做"展开失败列表 / 重试失败项"。
    /// 改协议返回值的代价过大（≥10 处生产 + ≥10 处测试），故走"外挂结构体"模式：
    /// 每次 `moveToTrash` 内部记录到 lastOutcome，UI 在 await 之后立刻 `snapshotLastOutcome()` 读。
    ///
    /// 协议给默认 nil 实现——历史 stub / dry-run pipeline 不强制提供。
    ///
    /// **v2026.06.22 (P0-3)**：side-channel 单槽位被识别为线程安全脆弱点
    /// （MainView/WorkflowDetailView 任何两次并发 `moveToTrash` 都会互相覆盖快照，
    /// 导致写错 UndoHistory + 展示错 OperationResultSheet）。生产路径应改用
    /// 新方法 [moveToTrashReturningOutcome](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift)
    /// 直接拿返回值；本方法保留向后兼容但仅用作"老调用方临时回退"，不应被新代码引用。
    func snapshotLastOutcome() -> TrashOutcome?

    /// **v2026.06.22 (P0-3)**：替代 `moveToTrash + snapshotLastOutcome()` 的 side-channel 模式，
    /// 一次调用同时返回旧 4 元组（向后兼容）与结构化 `TrashOutcome`。
    ///
    /// 调用方应优先使用 `outcome` 字段；4 元组保留是为了让历史 call site 渐进迁移。
    ///
    /// 默认实现走旧 `moveToTrash` + `snapshotLastOutcome()`，保证已有 stub 不破。
    func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)

    /// request-scoped accessDenied 入口。生产实现必须让 denied 快照与 paths 同一次调用交接，
    /// 避免并发请求通过共享 setter 覆盖彼此的安全上下文。
    func moveToTrashReturningOutcome(
        paths: [String],
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)

    /// 历史兼容入口。`.forbid` 是不可被任何模式越过的硬合同，因此实现只能等价于普通删除；
    /// 新 UI 不应再暴露“强制删除被安全规则拦截项”的入口。
    func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
}

/// v2026.06.16：单次 `moveToTrash` 的结构化结果。`OperationResultSheet` 直接消费。
public struct TrashOutcome: Sendable, Equatable {
    /// 实际成功移入废纸篓的 (原路径, 废纸篓路径) 对——可写 UndoHistory。
    public let movedPairs: [(originalPath: String, trashedPath: String)]
    /// `NSWorkspace.recycle` 真正失败的路径清单（不含被 SafetyEngine 拦的）。
    /// 来自分批 recycle 中的"批失败回退单 URL 隔离"路径。
    public let failedPaths: [String]
    /// 被 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 或 `accessDeniedPaths`
    /// 拦下的路径清单（拒绝原因可读）。
    public let safetyRejected: [(path: String, reason: String)]
    /// dryRun 模式下的"路径不存在"清单（仅 dryRun=true 时填充）。
    public let missingPaths: [String]

    public init(movedPairs: [(String, String)],
                failedPaths: [String],
                safetyRejected: [(String, String)],
                missingPaths: [String]) {
        self.movedPairs = movedPairs.map { (originalPath: $0.0, trashedPath: $0.1) }
        self.failedPaths = failedPaths
        self.safetyRejected = safetyRejected.map { (path: $0.0, reason: $0.1) }
        self.missingPaths = missingPaths
    }

    /// 总计提交的路径数（成功 + 失败 + 拒绝 + 缺失）。
    public var totalSubmitted: Int {
        movedPairs.count + failedPaths.count + safetyRejected.count + missingPaths.count
    }

    /// Equatable：tuple 类型自定义比较（Swift tuple 不直接 Equatable）。
    public static func == (lhs: TrashOutcome, rhs: TrashOutcome) -> Bool {
        guard lhs.failedPaths == rhs.failedPaths,
              lhs.missingPaths == rhs.missingPaths,
              lhs.movedPairs.count == rhs.movedPairs.count,
              lhs.safetyRejected.count == rhs.safetyRejected.count else { return false }
        for i in lhs.movedPairs.indices {
            if lhs.movedPairs[i].originalPath != rhs.movedPairs[i].originalPath
                || lhs.movedPairs[i].trashedPath != rhs.movedPairs[i].trashedPath {
                return false
            }
        }
        for i in lhs.safetyRejected.indices {
            if lhs.safetyRejected[i].path != rhs.safetyRejected[i].path
                || lhs.safetyRejected[i].reason != rhs.safetyRejected[i].reason {
                return false
            }
        }
        return true
    }
}

extension DeletionPipeline {
    /// 默认 nil：历史 stub / dry-run pipeline 没有结构化结果可暴露——返回 nil 即可。
    /// UI 拿到 nil 会回退到旧的 4 元组拼接文案。
    public func snapshotLastOutcome() -> TrashOutcome? {
        return nil
    }

    /// **P0-3 默认实现**：复用旧 `moveToTrash` + `snapshotLastOutcome()`。
    /// 真删除链路（TrashPipeline）会 override 此方法，**原子**返回 outcome，
    /// 不再依赖 side-channel 快照槽位；stub / dryRun pipeline 走默认即可。
    public func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        let legacy = await moveToTrash(paths: paths, dryRun: dryRun)
        let outcome = snapshotLastOutcome()
        return (legacy, outcome)
    }

    /// 兼容实现先注入再调用旧接口；生产 TrashPipeline override 为真正的 request-scoped 原子入口。
    public func moveToTrashReturningOutcome(
        paths: [String],
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        setAccessDeniedPaths(accessDeniedPaths)
        return await moveToTrashReturningOutcome(paths: paths, dryRun: dryRun)
    }

    /// 历史兼容：force 也必须完整执行普通安全判定。
    public func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        return await moveToTrashReturningOutcome(paths: paths, dryRun: dryRun)
    }
}
