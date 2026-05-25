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
    /// - Returns: (movedCount, skippedCount, error?)
    func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?)

    /// 注入"上层一票否决路径集合"（v1.3.zzzz Phase 3-A 协议化 → Phase 3-E 全链路接通）。
    ///
    /// 协议层接受这个钩子是为了**让"漏调=误拒"风险被强类型保护**：
    /// 历史上 [MainView.performDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 只对 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
    /// 走 `if let trash = pipeline as? TrashPipeline` cast 注入；现在 Helper 路线已下线，
    /// 实际只剩 TrashPipeline 一份实现，但协议层仍保留这个钩子——给未来如 dry-run-only 调试管道、
    /// 远程 audit 管道等新实现一个安全默认值，不强迫每个实现都接 accessDenied。
    func setAccessDeniedPaths(_ paths: Set<String>)
}

extension DeletionPipeline {
    /// 默认 no-op：给"不需要 accessDenied 投影"的 DeletionPipeline 实现一个安全默认值。
    /// TrashPipeline 自己 override 真实现。
    public func setAccessDeniedPaths(_ paths: Set<String>) {
        // intentional no-op
    }
}
