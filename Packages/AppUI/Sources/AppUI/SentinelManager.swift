import AppKit
import Combine
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
/// - `disable()`：调 `service.unregister()`，权威状态确认未注册后才清掉 `sentinelLastEnabled`
/// - `currentStatus()`：读 `service.status` 给 UI 展示
/// - 失败兜底：识别 `requiresApproval`，弹原生 NSAlert + 引导用户跳「系统设置 → 通用 → 登录项」
///
/// **不直接做什么**：
/// - 不监听 AppSettings 变化（由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
///   `.onChange(of: settings.sentinelEnabled)` 钩子驱动），保持单向数据流
/// - 不处理 URL Scheme 路由（那是 [SentinelURLRouter](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelURLRouter.swift) 的事）
@MainActor
public final class SentinelManager: ObservableObject {

    /// v2026.07.16：启动与用户开关都必须把持久化期望和 SMAppService 权威状态对账。
    /// OFF + 未注册是 no-op，避免默认启动无条件 unregister；OFF + 实际仍启用才注销，
    /// 防止 UI 显示关闭但遗留 daemon 继续运行。ON 的细分由 `enable()` 再紧邻重验。
    public enum ReconciliationAction: Equatable, Sendable {
        case none
        case enable
        case disable
    }

    /// 持久化开关为 ON 时，仍必须先读取 SMAppService 的权威状态。重复 register 在
    /// macOS 上可能返回 Operation not permitted；enabled 是幂等成功，待审批只做引导，
    /// 只有 notRegistered 才能真正调用 register。
    public enum EnableAction: Equatable, Sendable {
        case alreadyEnabled
        case register
        case requestApproval
        case unavailable
    }

    /// Whether reconciliation is repairing persisted intent during launch or applying a new
    /// user gesture. On an interactive failure the toggle must return to its previous value;
    /// launch reconciliation instead preserves the persisted intent and exposes any mismatch.
    public enum ReconciliationTrigger: Equatable, Sendable {
        case startup
        case user
    }

    public nonisolated static func enableAction(for status: Status) -> EnableAction {
        switch status {
        case .enabled: return .alreadyEnabled
        case .notRegistered: return .register
        case .requiresApproval: return .requestApproval
        case .notFound, .unknown: return .unavailable
        }
    }

    public nonisolated static func reconciliationAction(
        isEnabled: Bool,
        currentStatus: Status
    ) -> ReconciliationAction {
        if isEnabled {
            return enableAction(for: currentStatus) == .alreadyEnabled ? .none : .enable
        }
        switch currentStatus {
        case .enabled, .requiresApproval:
            return .disable
        case .notRegistered, .notFound, .unknown:
            return .none
        }
    }

    /// 与 [com.guoshuyu.cleanmac.sentinel.plist](file:///Users/guoshuyu/workspace/GSYCleanMac/App/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist)
    /// 文件名严格一致（SMAppService 用文件名定位 plist）。
    /// v2026.07.16：plist 文件名是不可变、可跨 actor 安全读取的产品常量。
    /// 明确声明 `nonisolated`，让非 UI 的 ServiceManagement 适配器无需错误地继承
    /// `SentinelManager` 的 MainActor 隔离，也不需要用 unchecked 绕过并发检查。
    public nonisolated static let plistName = "com.guoshuyu.cleanmac.sentinel.plist"

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

        /// v2026.07.15：状态只保存语义，显示时按当前 App locale 投影。
        public func displayLabel(locale: Locale) -> String {
            let key: String
            switch self {
            case .notRegistered: key = "sentinel.status.not_registered"
            case .enabled: key = "sentinel.status.enabled"
            case .requiresApproval: key = "sentinel.status.requires_approval"
            case .notFound: key = "sentinel.status.not_found"
            case .unknown(let raw):
                return AppLocalization.format(
                    "sentinel.status.unknown %lld",
                    locale: locale,
                    arguments: [Int64(raw)]
                )
            }
            return AppLocalization.string(key, locale: locale)
        }

        /// 兼容诊断/回归调用；用户可见 UI 必须使用 `displayLabel(locale:)`。
        public var displayLabel: String {
            displayLabel(locale: .current)
        }
    }

    /// User-facing projection keeps desired intent and verified system state separate. In
    /// particular, an ON toggle plus `.notFound`/`.unknown` is *not* "enabled".
    public enum PresentationState: Equatable, Sendable {
        case disabledVerified
        case enabledVerified
        case approvalRequired
        case desiredOnNotRunning
        case desiredOnUnverified
        case desiredOffStillRegistered
        case desiredOffUnverified

        public func localized(locale: Locale) -> String {
            let key: String
            switch self {
            case .disabledVerified: key = "sentinel.status.not_registered"
            case .enabledVerified: key = "sentinel.status.enabled"
            case .approvalRequired: key = "sentinel.status.requires_approval"
            case .desiredOnNotRunning: key = "sentinel.status.desired_on_not_running"
            case .desiredOnUnverified: key = "sentinel.status.desired_on_unverified"
            case .desiredOffStillRegistered: key = "sentinel.status.desired_off_still_registered"
            case .desiredOffUnverified: key = "sentinel.status.desired_off_unverified"
            }
            return AppLocalization.string(key, locale: locale)
        }
    }

    /// Stable product failures. Raw `Error`/NSError stays in logs; alerts and settings only
    /// retain this semantic value and localize at presentation time.
    public enum OperationFailure: Equatable, Sendable {
        case registrationUnavailable(Status)
        case registrationFailed
        case unregistrationFailed

        public func localizedTitle(locale: Locale) -> String {
            let key: String
            switch self {
            case .registrationUnavailable:
                key = "sentinel.alert.status_unavailable.title"
            case .registrationFailed:
                key = "sentinel.alert.register_failed.title"
            case .unregistrationFailed:
                key = "sentinel.alert.unregister_failed.title"
            }
            return AppLocalization.string(key, locale: locale)
        }

        public func localizedBody(
            locale: Locale,
            logHint: String,
            trigger: ReconciliationTrigger = .user
        ) -> String {
            let key: String
            switch (self, trigger) {
            case (.registrationUnavailable, .startup):
                key = "sentinel.alert.status_unavailable.startup.body %@"
            case (.registrationFailed, .startup):
                key = "sentinel.alert.register_failed.startup.body %@"
            case (.unregistrationFailed, .startup):
                key = "sentinel.alert.unregister_failed.startup.body %@"
            case (.registrationUnavailable, .user):
                key = "sentinel.alert.status_unavailable.body %@"
            case (.registrationFailed, .user):
                key = "sentinel.alert.register_failed.body %@"
            case (.unregistrationFailed, .user):
                key = "sentinel.alert.unregister_failed.body %@"
            }
            return AppLocalization.format(key, locale: locale, arguments: [logHint])
        }
    }

    public struct ReconciliationResult: Equatable, Sendable {
        public let requestedEnabled: Bool
        public let effectiveToggleEnabled: Bool
        public let status: Status
        public let presentation: PresentationState
        public let failure: OperationFailure?
    }

    /// v2026.07.16：`settings.sentinelEnabled` 的程序性写入必须携带来源与事务 ID。
    /// SwiftUI 的 `onChange` 只提供 old/new value，无法天然区分用户手势和失败回滚；
    /// 若直接把回滚再次当用户请求，就会重复 register/unregister、重复弹错，甚至反转最终值。
    public struct ProgrammaticToggleTransaction: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case failureRollback
            case directAPICommit
        }

        public let id: UUID
        public let targetEnabled: Bool
        public let reason: Reason
    }

    /// App 对一次 SwiftUI `onChange` 的类型化处理结果。只有 `.reconciledUserChange`
    /// 才消费真实用户变更；程序性事务、过期 observation 与无变化事件均不触发系统动作。
    public enum ObservedToggleChangeResult: Equatable, Sendable {
        case reconciledUserChange(ReconciliationResult)
        case suppressedProgrammaticChange(ProgrammaticToggleTransaction)
        case staleObservation
        case unchanged
    }

    /// v2026.07.16：ServiceManagement 的读写与状态事务由 MainActor 上的 manager 串行化。
    /// 把隔离写进协议合同，测试替身与系统适配器不会以 nonisolated conformance 跨越
    /// 主线程状态，也无需 `@preconcurrency` / `@unchecked Sendable` 掩盖竞态。
    @MainActor
    protocol ServiceControlling: AnyObject {
        var status: Status { get }
        func register() throws
        func unregister() throws
    }

    @MainActor
    private final class SystemService: ServiceControlling {
        private let service: SMAppService

        init() {
            service = SMAppService.daemon(plistName: SentinelManager.plistName)
        }

        var status: Status { Status(service.status) }
        func register() throws { try service.register() }
        func unregister() throws { try service.unregister() }
    }

    public nonisolated static func presentationState(
        desiredEnabled: Bool,
        status: Status
    ) -> PresentationState {
        if desiredEnabled {
            switch status {
            case .enabled: return .enabledVerified
            case .requiresApproval: return .approvalRequired
            case .notRegistered: return .desiredOnNotRunning
            case .notFound, .unknown: return .desiredOnUnverified
            }
        }
        switch status {
        case .notRegistered, .notFound: return .disabledVerified
        case .enabled, .requiresApproval: return .desiredOffStillRegistered
        case .unknown: return .desiredOffUnverified
        }
    }

    private let service: any ServiceControlling
    private let failurePresenter: (OperationFailure, ReconciliationTrigger, Locale) -> Void
    private let approvalPresenter: (Locale) -> Void
    /// 由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 初始化时注入；register / unregister 成功后会写
    /// `sentinelLastEnabled` 时间戳。
    private weak var settings: AppSettings?

    /// 下一次由本 manager 写入的 Toggle 事务。MainActor 串行保证“登记来源 → 写设置 →
    /// App onChange 消费”不会竞态；匹配 target 而非依赖 oldValue，可兼容 SwiftUI 合并更新。
    private var pendingProgrammaticToggleTransaction: ProgrammaticToggleTransaction?

    /// Latest desired/actual projection shown by Settings. It changes only after an explicit
    /// authoritative status read, never by assuming the toggle itself proves daemon state.
    @Published public private(set) var presentationState: PresentationState
    @Published public private(set) var lastFailure: OperationFailure?

    public init(settings: AppSettings) {
        let service = SystemService()
        self.service = service
        self.settings = settings
        self.failurePresenter = { failure, trigger, locale in
            SentinelManager.presentFailureAlert(failure, trigger: trigger, locale: locale)
        }
        self.approvalPresenter = { locale in
            SentinelManager.presentApprovalAlert(locale: locale)
        }
        self.presentationState = Self.presentationState(
            desiredEnabled: settings.sentinelEnabled,
            status: service.status
        )
        self.lastFailure = nil
        self.pendingProgrammaticToggleTransaction = nil
    }

    init(
        settings: AppSettings,
        service: any ServiceControlling,
        failurePresenter: @escaping (OperationFailure, ReconciliationTrigger, Locale) -> Void,
        approvalPresenter: @escaping (Locale) -> Void = { _ in }
    ) {
        self.service = service
        self.settings = settings
        self.failurePresenter = failurePresenter
        self.approvalPresenter = approvalPresenter
        self.presentationState = Self.presentationState(
            desiredEnabled: settings.sentinelEnabled,
            status: service.status
        )
        self.lastFailure = nil
        self.pendingProgrammaticToggleTransaction = nil
    }

    /// 当前 SMAppService 状态。直接桥接 `service.status`，不缓存。
    public func currentStatus() -> Status {
        service.status
    }

    /// Re-read authority without changing registration. Settings uses this when it appears so
    /// an external Login Items change does not leave a stale status chip.
    public func refreshPresentation() {
        let desiredEnabled = settings?.sentinelEnabled ?? false
        presentationState = Self.presentationState(
            desiredEnabled: desiredEnabled,
            status: currentStatus()
        )
    }

    /// App 的 Sentinel `onChange` 唯一入口。
    ///
    /// v2026.07.16 根因修复：失败回滚在写 `AppSettings` 前登记成类型化事务；下一轮
    /// `onChange` 命中同一 target 时只消费事务，不再执行 reconcile。若 SwiftUI 合并了
    /// 回滚通知，下一次真实用户手势必然会离开当前 target，因此会清掉过期事务并正常执行。
    /// 全程 MainActor 同步完成，不依赖 DispatchQueue 延时或时间窗口。
    @discardableResult
    public func handleObservedToggleChange(
        from oldValue: Bool,
        to newValue: Bool
    ) -> ObservedToggleChangeResult {
        if let pending = pendingProgrammaticToggleTransaction,
           pending.targetEnabled == newValue {
            pendingProgrammaticToggleTransaction = nil
            return .suppressedProgrammaticChange(pending)
        }

        // 若更新已被更晚的 setting value 覆盖，这只是 SwiftUI 的过期 observation；
        // 不能拿当前值冒充这次事件重新执行系统动作。保留 pending，等待其目标通知或
        // 下一次真实用户变更离开 target 时再清理。
        guard settings?.sentinelEnabled == newValue else {
            return .staleObservation
        }

        // 当前真实值已经离开 pending target，说明对应程序性通知被 SwiftUI 合并；
        // 此时这次变化只能是更新的用户意图，先退休旧事务再处理。
        pendingProgrammaticToggleTransaction = nil
        guard oldValue != newValue else { return .unchanged }
        return .reconciledUserChange(reconcile(trigger: .user))
    }

    /// **v2026.07.16 root-cause fix:** desired preference, authoritative service status and
    /// operation outcome are committed as one state transition. The old App-level switch
    /// discarded `disable()`'s Bool after the Toggle had already persisted OFF, so an
    /// unregister error could leave UI OFF while launchd still ran the daemon.
    ///
    /// Interactive failures restore the pre-gesture Toggle (`!requestedEnabled`). Startup
    /// failures retain the persisted intent but publish an explicit mismatch/unverified state.
    /// Both paths present a typed localized failure; no raw NSError crosses the UI boundary.
    @discardableResult
    public func reconcile(trigger: ReconciliationTrigger) -> ReconciliationResult {
        reconcile(
            requestedEnabled: settings?.sentinelEnabled ?? false,
            trigger: trigger
        )
    }

    private func reconcile(
        requestedEnabled: Bool,
        trigger: ReconciliationTrigger
    ) -> ReconciliationResult {
        let initialStatus = currentStatus()
        let locale = settings?.effectiveLocale ?? .current
        var finalStatus = initialStatus
        var failure: OperationFailure?

        switch Self.reconciliationAction(
            isEnabled: requestedEnabled,
            currentStatus: initialStatus
        ) {
        case .none:
            if requestedEnabled, initialStatus == .enabled,
               settings?.sentinelLastEnabled == nil {
                settings?.sentinelLastEnabled = Date()
            } else if !requestedEnabled,
                      initialStatus == .notRegistered || initialStatus == .notFound {
                settings?.sentinelLastEnabled = nil
            }
        case .enable:
            switch Self.enableAction(for: initialStatus) {
            case .alreadyEnabled:
                if settings?.sentinelLastEnabled == nil {
                    settings?.sentinelLastEnabled = Date()
                }
            case .requestApproval:
                approvalPresenter(locale)
            case .unavailable:
                failure = .registrationUnavailable(initialStatus)
                GSYLog.error(.sentinel, "register unavailable; status=\(initialStatus)")
            case .register:
                do {
                    try service.register()
                    finalStatus = currentStatus()
                    GSYLog.info(.sentinel, "register returned; authoritativeStatus=\(finalStatus)")
                    switch finalStatus {
                    case .enabled:
                        settings?.sentinelLastEnabled = Date()
                    case .requiresApproval:
                        approvalPresenter(locale)
                    case .notRegistered, .notFound, .unknown:
                        failure = .registrationUnavailable(finalStatus)
                    }
                } catch {
                    GSYLog.error(.sentinel, "register failed: \(error)")
                    failure = .registrationFailed
                    finalStatus = currentStatus()
                }
            }
        case .disable:
            do {
                try service.unregister()
                finalStatus = currentStatus()
                GSYLog.info(.sentinel, "unregister returned; authoritativeStatus=\(finalStatus)")
                switch finalStatus {
                case .notRegistered, .notFound:
                    settings?.sentinelLastEnabled = nil
                case .enabled, .requiresApproval, .unknown:
                    failure = .unregistrationFailed
                }
            } catch {
                GSYLog.error(.sentinel, "unregister failed: \(error)")
                failure = .unregistrationFailed
                finalStatus = currentStatus()
            }
        }

        let effectiveToggleEnabled: Bool
        if failure != nil, trigger == .user {
            effectiveToggleEnabled = !requestedEnabled
        } else {
            effectiveToggleEnabled = requestedEnabled
        }
        if settings?.sentinelEnabled != effectiveToggleEnabled {
            let reason: ProgrammaticToggleTransaction.Reason =
                failure != nil && trigger == .user
                    ? .failureRollback
                    : .directAPICommit
            writeToggleProgrammatically(
                effectiveToggleEnabled,
                reason: reason
            )
        }
        let presentation = Self.presentationState(
            desiredEnabled: effectiveToggleEnabled,
            status: finalStatus
        )
        presentationState = presentation
        lastFailure = failure
        if let failure {
            failurePresenter(failure, trigger, locale)
        }
        return ReconciliationResult(
            requestedEnabled: requestedEnabled,
            effectiveToggleEnabled: effectiveToggleEnabled,
            status: finalStatus,
            presentation: presentation,
            failure: failure
        )
    }

    private func writeToggleProgrammatically(
        _ enabled: Bool,
        reason: ProgrammaticToggleTransaction.Reason
    ) {
        guard settings?.sentinelEnabled != enabled else { return }
        let transaction = ProgrammaticToggleTransaction(
            id: UUID(),
            targetEnabled: enabled,
            reason: reason
        )
        pendingProgrammaticToggleTransaction = transaction
        settings?.sentinelEnabled = enabled
    }

    /// Compatibility entry points now delegate to the same reconciliation transaction so no
    /// caller can accidentally ignore failure rollback semantics.
    @discardableResult
    public func enable() -> Bool {
        // v2026.07.16：直接 API 也在同一事务里提交期望值，避免先写 setting 后由 App
        // onChange 重复 reconcile。成功 commit 会登记为 programmatic，失败则无需回滚。
        let result = reconcile(requestedEnabled: true, trigger: .user)
        return result.failure == nil && result.effectiveToggleEnabled
    }

    @discardableResult
    public func disable() -> Bool {
        let result = reconcile(requestedEnabled: false, trigger: .user)
        return result.failure == nil && !result.effectiveToggleEnabled
    }

    // MARK: - Alert 兜底

    private static func presentApprovalAlert(locale: Locale) {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string("sentinel.alert.approval.title", locale: locale)
        alert.informativeText = AppLocalization.string("sentinel.alert.approval.body", locale: locale)
        alert.addButton(withTitle: AppLocalization.string("sentinel.alert.button.open_settings", locale: locale))
        alert.addButton(withTitle: AppLocalization.string("sentinel.alert.button.later", locale: locale))
        alert.alertStyle = .informational
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func presentFailureAlert(
        _ failure: OperationFailure,
        trigger: ReconciliationTrigger,
        locale: Locale
    ) {
        let alert = NSAlert()
        alert.messageText = failure.localizedTitle(locale: locale)
        let logHint = GSYLog.currentLogFileURL()?.path
            ?? AppLocalization.string("sentinel.alert.register_failed.log_hint_fallback", locale: locale)
        // v2026.07.16：NSError/errno 只写结构化日志，用户界面给稳定的产品说明与日志位置。
        // 原始 localizedDescription 可能未本地化、携带实现细节，不能直接进入产品文案。
        alert.informativeText = failure.localizedBody(
            locale: locale,
            logHint: logHint,
            trigger: trigger
        )
        alert.addButton(withTitle: AppLocalization.string("sentinel.alert.button.open_settings", locale: locale))
        alert.addButton(withTitle: AppLocalization.string("sentinel.alert.button.ok", locale: locale))
        alert.alertStyle = .warning
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
