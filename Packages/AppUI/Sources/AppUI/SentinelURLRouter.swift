import Foundation
import LogKit

/// v1.6 Sentinel URL Scheme 路由：解析 `gsycleanmac://` 系列链接，并广播
/// 为已订阅的 NotificationCenter 事件，与 [.gsyOpenMainWindowRequested](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L9-L11)
/// 同模式（避免新增 NavigationCoordinator 抽象，详见 [docs/SENTINEL_DESIGN.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/SENTINEL_DESIGN.md) §5.4）。
///
/// **支持的链接格式**：
/// - `gsycleanmac://uninstall?path=<percent-encoded absolute path>` —— 跳卸载页
/// - `gsycleanmac://action/scan/full` —— 触发完整扫描
///
/// **路径防注入**：
/// - `path` 参数必须是绝对路径（`/` 开头）
/// - 必须存在（`FileManager.fileExists(atPath:)`）
/// - 必须不包含 `..` 段（防 traversal）
/// - 校验失败 → 仅广播 `.gsySentinelOpenUninstall` 不带 path（让 UI 走默认 fallback）
public extension Notification.Name {
    /// daemon 通过 `gsycleanmac://uninstall?path=...` 拉起，主 App 监听后跳卸载页。
    /// `userInfo[SentinelURLRouter.uninstallPathKey]` = `String?`（绝对路径，已校验）。
    static let gsySentinelOpenUninstall = Notification.Name("GSYCleanMac.sentinel.openUninstall")
    /// daemon 通过 `gsycleanmac://action/scan/full` 拉起，主 App 监听后触发完整扫描。
    static let gsySentinelStartFullScan = Notification.Name("GSYCleanMac.sentinel.startFullScan")
}

public enum SentinelURLRouter {

    public static let scheme = "gsycleanmac"
    /// `Notification.userInfo` 用的 path 键。
    public static let uninstallPathKey = "path"

    /// 路由结果（用于单测断言 / 也方便 UI 决定是否需要弹错误 toast）。
    public enum Outcome: Equatable {
        case openUninstall(path: String?)
        case startFullScan
        case ignored(reason: String)
    }

    /// 主入口：解析 URL 并 post 对应通知。返回路由决策方便单测。
    @discardableResult
    public static func handle(_ url: URL) -> Outcome {
        guard url.scheme?.lowercased() == scheme else {
            GSYLog.warning(.sentinel, "ignored URL with bad scheme: \(url.absoluteString)")
            return .ignored(reason: "bad-scheme")
        }
        // URL host 在自定义 scheme 下可能是 nil 或空（依赖 URL 形态），
        // 因此用 percent-decoded 形式拼接 host + path 再分段。
        let host = (url.host ?? "").lowercased()
        let pathSegments = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "uninstall":
            let raw = url.queryParameter(named: uninstallPathKey)
            let validated = validateAbsolutePath(raw)
            var info: [AnyHashable: Any] = [:]
            if let p = validated { info[uninstallPathKey] = p }
            NotificationCenter.default.post(name: .gsySentinelOpenUninstall, object: nil, userInfo: info)
            GSYLog.info(.sentinel, "route uninstall path=\(validated ?? "<nil>")")
            return .openUninstall(path: validated)
        case "action":
            // 形如 gsycleanmac://action/scan/full —— host=action / pathSegments=[scan, full]
            if pathSegments == ["scan", "full"] {
                NotificationCenter.default.post(name: .gsySentinelStartFullScan, object: nil)
                GSYLog.info(.sentinel, "route action/scan/full")
                return .startFullScan
            }
            GSYLog.warning(.sentinel, "ignored unknown action: \(pathSegments.joined(separator: "/"))")
            return .ignored(reason: "unknown-action")
        default:
            GSYLog.warning(.sentinel, "ignored unknown host: \(host)")
            return .ignored(reason: "unknown-host")
        }
    }

    /// 路径校验：拒绝相对路径 / 含 `..` / 不存在 / 空串。校验失败返回 nil，让上层走 fallback。
    static func validateAbsolutePath(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("/") else { return nil }
        let comps = (raw as NSString).pathComponents
        if comps.contains("..") { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDir) else { return nil }
        return (raw as NSString).standardizingPath
    }
}

private extension URL {
    /// 安全取 query 参数（百分号解码后），缺省返回 nil。
    func queryParameter(named name: String) -> String? {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }
}
