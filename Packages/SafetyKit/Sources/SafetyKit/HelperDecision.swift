import Foundation

/// Helper 内部"是否允许执行删除"的最终决策器。
///
/// 这是**第三道闸门**（前两道是：HMAC 签名、SafetyEngine 黑名单）。
/// v1.3.zzzz Phase 3-E 加了**第四道闸门**——`paths` 与 `accessDeniedPaths` 不能有交集（详见 [decide](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/HelperDecision.swift)）。
///
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

    public func decide(
        paths: [String],
        dryRun: Bool,
        accessDeniedPaths: [String] = [],
        home: String = NSHomeDirectory()
    ) -> Outcome {
        // —— 第四道闸门（v1.3.zzzz Phase 3-E）：accessDeniedPaths 一票否决 ——
        // BulkScanner 期间标了 permissionDenied / tccProtected 的路径"扫都没扫成功"，
        // 主 App 不应再以它们为目标真删；命中即整批拒，杜绝"客户端漏拦下放到 Helper"的灰区。
        // 路径口径与 [TrashPipeline.normalizePath](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L97-L116) 对齐——
        // 折叠 `/private/var ↔ /var` 等 firmlink 后比较，防御 accessDenied 集合与 paths 一边带 `/private` 前缀、
        // 另一边没带导致 Set.contains 漏命中的情况。
        if !accessDeniedPaths.isEmpty {
            let deniedSet = Set(accessDeniedPaths.map(Self.normalizePath))
            for p in paths {
                if deniedSet.contains(Self.normalizePath(p)) {
                    return .rejectBatch(
                        reason: "blocked by HelperDecision: accessDenied path in batch",
                        badPath: p
                    )
                }
            }
        }
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

    /// 折叠 firmlink 前缀，与 [TrashPipeline.normalizePath](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift#L97-L116) 同款规则。
    /// 不依赖 `URL.standardizedFileURL`（对不存在路径是 no-op，会让 firmlink 形态对不上）。
    static func normalizePath(_ raw: String) -> String {
        let firmlinks: [(String, String)] = [
            ("/private/var/", "/var/"),
            ("/private/tmp/", "/tmp/"),
            ("/private/etc/", "/etc/"),
        ]
        for (priv, pub) in firmlinks {
            if raw.hasPrefix(priv) {
                return pub + String(raw.dropFirst(priv.count))
            }
            let privNoSlash = String(priv.dropLast())
            if raw == privNoSlash {
                return String(pub.dropLast())
            }
        }
        return raw
    }
}
