import AppKit
import Foundation
import LogKit
import ServiceManagement

/// v1.6 Sentinel 管理器：唯一负责 [SMAppService.daemon](https://developer.apple.com/documentation/servicemanagement/smappservice)
/// 的 register / unregister + 状态查询，把 ServiceManagement 的副作用从
/// [AppSettings](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
/// 中剥离，配置层保持纯 UserDefaults。
///
/// **整体职责**（详见 [docs/SENTINEL_DESIGN.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/SENTINEL_DESIGN.md) §5.2）：
/// - `enable()`：调 `SMAppService.daemon(plistName:).register()`，成功后写 `sentinelLastEnabled = Date()`
/// - `disable()`：调 `service.unregister()`，并清掉 `sentinelLastEnabled`
/// - `currentStatus()`：读 `service.status` 给 UI 展示
/// - 失败兜底：识别 `requiresApproval`，弹原生 NSAlert + 引导用户跳「系统设置 → 通用 → 登录项」
///
/// **不直接做什么**：
/// - 不监听 AppSettings 变化（由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
///   `.onChange(of: settings.sentinelEnabled)` 钩子驱动），保持单向数据流
/// - 不处理 URL Scheme 路由（那是 [SentinelURLRouter](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelURLRouter.swift) 的事）
@MainActor
public final class SentinelManager {

    /// 与 [com.guoshuyu.cleanmac.sentinel.plist](file:///Users/guoshuyu/workspace/GSYCleanMac/App/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist)
    /// 文件名严格一致（SMAppService 用文件名定位 plist）。
    public static let plistName = "com.guoshuyu.cleanmac.sentinel.plist"

    /// 简化后的对外状态枚举，避开直接暴露 `SMAppService.Status` 给 UI 层。
    public enum Status: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown(Int)

        init(_ raw: SMAppService.Status) {
            switch raw {
            case .notRegistered: self = .notRegistered
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound: self = .notFound
            @unknown default: self = .unknown(raw.rawValue)
            }
        }

        /// UI 展示的人类可读文案。
        public var displayLabel: String {
            switch self {
            case .notRegistered: return String(localized: "sentinel.status.not_registered", bundle: .module)
            case .enabled: return String(localized: "sentinel.status.enabled", bundle: .module)
            case .requiresApproval: return String(localized: "sentinel.status.requires_approval", bundle: .module)
            case .notFound: return String(localized: "sentinel.status.not_found", bundle: .module)
            case .unknown(let raw): return String(format: String(localized: "sentinel.status.unknown %lld", bundle: .module), raw)
            }
        }
    }

    private let service: SMAppService
    /// 由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 初始化时注入；register / unregister 成功后会写
    /// `sentinelLastEnabled` 时间戳。
    private weak var settings: AppSettings?

    public init(settings: AppSettings) {
        self.service = SMAppService.daemon(plistName: Self.plistName)
        self.settings = settings
    }

    /// 当前 SMAppService 状态。直接桥接 `service.status`，不缓存。
    public func currentStatus() -> Status {
        Status(service.status)
    }

    /// 启用守护：调 `service.register()`，并按结果驱动 settings 时间戳和 UI alert。
    /// 成功 → 写 `sentinelLastEnabled = Date()`；失败 → 弹 NSAlert（如 requiresApproval 引导跳系统设置）。
    @discardableResult
    public func enable() -> Bool {
        do {
            try service.register()
            settings?.sentinelLastEnabled = Date()
            GSYLog.info(.sentinel, "register succeeded; status=\(currentStatus().displayLabel)")
            // register() 成功后 status 可能是 .enabled 也可能是 .requiresApproval（首次安装）。
            if case .requiresApproval = currentStatus() {
                presentApprovalAlert()
            }
            return true
        } catch {
            GSYLog.error(.sentinel, "register failed: \(error.localizedDescription)")
            presentRegisterFailureAlert(error: error)
            return false
        }
    }

    /// 关闭守护：调 `service.unregister()`，并清掉时间戳。
    /// 失败时不强行写 settings，由调用方决定是否回滚 toggle。
    @discardableResult
    public func disable() -> Bool {
        do {
            try service.unregister()
            settings?.sentinelLastEnabled = nil
            GSYLog.info(.sentinel, "unregister succeeded")
            return true
        } catch {
            GSYLog.error(.sentinel, "unregister failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Alert 兜底

    private func presentApprovalAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "sentinel.alert.approval.title", bundle: .module)
        alert.informativeText = String(localized: "sentinel.alert.approval.body", bundle: .module)
        alert.addButton(withTitle: String(localized: "sentinel.alert.button.open_settings", bundle: .module))
        alert.addButton(withTitle: String(localized: "sentinel.alert.button.later", bundle: .module))
        alert.alertStyle = .informational
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentRegisterFailureAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "sentinel.alert.register_failed.title", bundle: .module)
        let logHint = GSYLog.currentLogFileURL()?.path ?? String(localized: "sentinel.alert.register_failed.log_hint_fallback", bundle: .module)
        alert.informativeText = String(format: String(localized: "sentinel.alert.register_failed.body %@ %@", bundle: .module),
                                        error.localizedDescription, logHint)
        alert.addButton(withTitle: String(localized: "sentinel.alert.button.open_settings", bundle: .module))
        alert.addButton(withTitle: String(localized: "sentinel.alert.button.ok", bundle: .module))
        alert.alertStyle = .warning
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
