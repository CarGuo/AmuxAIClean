import Foundation

/// Helper 内部"是否允许执行删除"的最终决策器。
///
/// 这是**第三道闸门**（前两道是：HMAC 签名、SafetyEngine 黑名单）。
/// 设计原则：
/// - **Helper 永远不信主 App**：即使 HMAC 签名通过，也要再过一遍 SafetyEngine
/// - **dryRun 默认 true**：除非环境/请求都明确允许真删，一律 dry-run
/// - **批量请求里只要有一个被禁，整批拒绝**（防"夹带私货"攻击）
/// - **Helper 的硬黑名单可以比 App 更严**，反过来不行
public struct HelperDecision: Sendable {
    public enum Outcome: Sendable, Equatable {
        case allowReal      // 允许真删（路径合法 + dryRun=false + 全局开关 ON）
        case allowDryRun    // 允许 dry-run（只打日志）
        case rejectBatch(reason: String, badPath: String?)
    }

    public let allowRealDeletes: Bool   // 全局总开关；环境变量控制；默认 false
    public let engine: SafetyEngine

    public init(allowRealDeletes: Bool, engine: SafetyEngine = SafetyEngine()) {
        self.allowRealDeletes = allowRealDeletes
        self.engine = engine
    }

    public func decide(paths: [String], dryRun: Bool, home: String = NSHomeDirectory()) -> Outcome {
        // 1. 批内任意路径被禁就整批拒——防夹带
        for p in paths {
            let (verdict, reason) = engine.evaluate(path: p, home: home)
            if verdict == .forbid {
                return .rejectBatch(reason: "blocked by SafetyEngine: \(reason.rawValue)", badPath: p)
            }
        }
        // 2. 即便单个路径合法，全局开关没开也不真删
        if dryRun || !allowRealDeletes {
            return .allowDryRun
        }
        return .allowReal
    }
}
