import AppKit
import Combine
import Foundation
import LogKit
import ServiceManagement

/// v1.6 Sentinel 管理器：唯一负责用户态 [SMAppService.agent](https://developer.apple.com/documentation/servicemanagement/smappservice)
/// 的 register / unregister + 状态查询，把 ServiceManagement 的副作用从
/// `AppSettings` 中剥离，配置层保持纯 UserDefaults。
///
/// **整体职责**（详见 `docs/SENTINEL_DESIGN.md` §5.2）：
/// - `enable()`：调 `SMAppService.agent(plistName:).register()`，成功后写 `sentinelLastEnabled = Date()`
/// - `disable()`：调 `service.unregister()`，权威状态确认未注册后才清掉 `sentinelLastEnabled`
/// - `currentStatus()`：读 `service.status` 给 UI 展示
/// - 失败兜底：识别 `requiresApproval`，弹原生 NSAlert + 引导用户跳「系统设置 → 通用 → 登录项」
///
/// **不直接做什么**：
/// - 不监听 AppSettings 变化（由 `AmuxAICleanApp` `.onChange(of: settings.sentinelEnabled)` 钩子驱动），保持单向数据流
/// - 不处理 URL Scheme 路由（那是 `SentinelURLRouter` 的事）
@MainActor
public final class SentinelManager: ObservableObject {

    /// v2026.07.16：启动与用户开关都必须把持久化期望和 SMAppService 权威状态对账。
    /// OFF + 未注册是 no-op，避免默认启动无条件 unregister；OFF + 实际仍启用才注销，
    /// 防止 UI 显示关闭但遗留 service 继续运行。ON 的细分由 `enable()` 再紧邻重验。
    public enum ReconciliationAction: Equatable, Sendable {
        case none
        case enable
        case disable
        case unavailable
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
        case .notRegistered:
            return .none
        case .notFound, .unknown:
            // v2026.07.18 P1: `notFound` means ServiceManagement could not resolve the
            // service, not that launchd authoritatively reports it unregistered. Unknown
            // future states have the same proof gap. An OFF intent must therefore fail
            // closed instead of clearing state or reporting a verified stop.
            return .unavailable
        }
    }

    /// One-way policy for registrations created by historical root-daemon builds.
    /// Only `.notRegistered` proves that one migration identity is complete. `.notFound` is
    /// an SMAppService lookup/configuration error and must never authorize the new Agent.
    enum LegacyMigrationAction: Equatable, Sendable {
        case alreadyCleared
        case unregister
        case unavailable
    }

    nonisolated static func legacyMigrationAction(for status: Status) -> LegacyMigrationAction {
        switch status {
        case .notRegistered:
            return .alreadyCleared
        case .enabled, .requiresApproval:
            return .unregister
        case .notFound, .unknown:
            return .unavailable
        }
    }

    /// 与当前用户 Agent 描述符文件名严格一致（SMAppService 用文件名定位 plist）。
    /// v2026.07.18：当前 Agent 与旧 Daemon 使用不同文件名和 Label；旧服务注销尚未
    /// 完成时，也不会与新服务的 launchd identity 冲突。
    /// 明确声明 `nonisolated`，让非 UI 的 ServiceManagement 适配器无需错误地继承
    /// `SentinelManager` 的 MainActor 隔离，也不需要用 unchecked 绕过并发检查。
    public nonisolated static let agentPlistName = "com.amux.ai.Clean.sentinel.agent.plist"

    /// v2026.10.14：品牌更名不会移除已注册的 launchd authority。两代 root Label 都必须
    /// 保留文件名对应的独立迁移描述符，直到有升级窗口结束证据；只能查询/注销，永不重新注册。
    struct LegacyDaemonDescriptor: Equatable, Hashable, Sendable {
        let plistName: String
        let label: String
    }

    public nonisolated static let originalBrandLegacyDaemonPlistName =
        "com.guoshuyu.cleanmac.sentinel.plist"
    public nonisolated static let legacyDaemonPlistName =
        "com.amux.ai.Clean.sentinel.plist"

    nonisolated static let legacyDaemonDescriptors: [LegacyDaemonDescriptor] = [
        LegacyDaemonDescriptor(
            plistName: originalBrandLegacyDaemonPlistName,
            label: "com.guoshuyu.cleanmac.sentinel"
        ),
        LegacyDaemonDescriptor(
            plistName: legacyDaemonPlistName,
            label: "com.amux.ai.Clean.sentinel"
        ),
    ]

    /// v2026.07.18：Sentinel 读取登录用户的 Trash/Home 热点，注册域必须是 user agent。
    /// 该语义常量由单测和 release contract 锁定，防止再次退回 root LaunchDaemon。
    enum RegistrationDomain: Equatable, Sendable { case userAgent }
    nonisolated static let registrationDomain: RegistrationDomain = .userAgent

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

    /// v2026.07.18: the current Agent status alone cannot prove that the historical root
    /// Daemon is gone. Keep this as a separate authority dimension so a later Settings refresh
    /// cannot turn a failed migration into a misleading "verified" presentation.
    enum LegacyMigrationState: Equatable, Sendable {
        case unverified
        case verifiedCleared
    }

    /// Stable product failures. Raw `Error`/NSError stays in logs; alerts and settings only
    /// retain this semantic value and localize at presentation time.
    public enum OperationFailure: Equatable, Sendable {
        case registrationUnavailable(Status)
        case registrationFailed
        /// Status lookup failed before an OFF operation could be attempted. This is deliberately
        /// distinct from `unregistrationFailed`: user copy must not claim a close operation ran.
        case shutdownVerificationUnavailable(Status)
        case unregistrationFailed
        /// Historical privileged daemon authority is independent from the current user Agent.
        /// The associated desired state keeps enable-blocked and disable-incomplete copy honest.
        case legacyMigrationFailed(requestedEnabled: Bool)
        /// ON migration failed and the already-existing current Agent also could not be
        /// authoritatively stopped. Keep this distinct so UI never claims safe shutdown.
        case legacyMigrationSafetyShutdownFailed

        public func localizedTitle(locale: Locale) -> String {
            let key: String
            switch self {
            case .registrationUnavailable:
                key = "sentinel.alert.status_unavailable.title"
            case .registrationFailed:
                key = "sentinel.alert.register_failed.title"
            case .shutdownVerificationUnavailable:
                key = "sentinel.alert.shutdown_verification_unavailable.title"
            case .unregistrationFailed:
                key = "sentinel.alert.unregister_failed.title"
            case .legacyMigrationFailed:
                key = "sentinel.alert.legacy_migration_failed.title"
            case .legacyMigrationSafetyShutdownFailed:
                key = "sentinel.alert.legacy_migration_shutdown_failed.title"
            }
            return AppLocalization.string(key, locale: locale)
        }

        public func localizedBody(
            locale: Locale,
            trigger: ReconciliationTrigger = .user
        ) -> String {
            let key: String
            switch (self, trigger) {
            case (.registrationUnavailable, .startup):
                key = "sentinel.alert.status_unavailable.startup.body"
            case (.registrationFailed, .startup):
                key = "sentinel.alert.register_failed.startup.body"
            case (.shutdownVerificationUnavailable, .startup):
                key = "sentinel.alert.shutdown_verification_unavailable.startup.body"
            case (.unregistrationFailed, .startup):
                key = "sentinel.alert.unregister_failed.startup.body"
            case (.legacyMigrationFailed(requestedEnabled: true), .startup):
                key = "sentinel.alert.legacy_migration_failed.enable.startup.body"
            case (.legacyMigrationFailed(requestedEnabled: false), .startup):
                key = "sentinel.alert.legacy_migration_failed.disable.body"
            case (.legacyMigrationSafetyShutdownFailed, .startup):
                key = "sentinel.alert.legacy_migration_shutdown_failed.startup.body"
            case (.registrationUnavailable, .user):
                key = "sentinel.alert.status_unavailable.body"
            case (.registrationFailed, .user):
                key = "sentinel.alert.register_failed.body"
            case (.shutdownVerificationUnavailable, .user):
                key = "sentinel.alert.shutdown_verification_unavailable.body"
            case (.unregistrationFailed, .user):
                key = "sentinel.alert.unregister_failed.body"
            case (.legacyMigrationFailed(requestedEnabled: true), .user):
                key = "sentinel.alert.legacy_migration_failed.enable.body"
            case (.legacyMigrationFailed(requestedEnabled: false), .user):
                key = "sentinel.alert.legacy_migration_failed.disable.body"
            case (.legacyMigrationSafetyShutdownFailed, .user):
                key = "sentinel.alert.legacy_migration_shutdown_failed.body"
            }
            return AppLocalization.string(key, locale: locale)
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
        /// Each historical Label is a separate authority dimension. The manager reads and
        /// re-reads every one before allowing the current Agent registration path to proceed.
        func legacyDaemonStatus(for descriptor: LegacyDaemonDescriptor) -> Status
        func unregisterLegacyDaemon(_ descriptor: LegacyDaemonDescriptor) throws
        func register() throws
        func unregister() throws
    }

    private enum LegacyServiceMigrationError: Error {
        case incomplete
    }

    @MainActor
    private final class SystemService: ServiceControlling {
        private let service: SMAppService
        private let legacyDaemons: [LegacyDaemonDescriptor: SMAppService]

        init() {
            // v2026.07.18 P1：LaunchDaemon runs in the system/root domain, so
            // `homeDirectoryForCurrentUser` resolves the wrong Trash/Downloads. Sentinel is a
            // non-privileged per-login monitor and must use Contents/Library/LaunchAgents.
            service = SMAppService.agent(plistName: SentinelManager.agentPlistName)
            legacyDaemons = Dictionary(
                uniqueKeysWithValues: SentinelManager.legacyDaemonDescriptors.map { descriptor in
                    (
                        descriptor,
                        SMAppService.daemon(plistName: descriptor.plistName)
                    )
                }
            )
        }

        var status: Status { Status(service.status) }
        func legacyDaemonStatus(for descriptor: LegacyDaemonDescriptor) -> Status {
            guard let daemon = legacyDaemons[descriptor] else {
                // v2026.07.18 P1：内部 descriptor/service 映射丢失也不能被解释为已注销。
                return .notFound
            }
            return Status(daemon.status)
        }
        func unregisterLegacyDaemon(_ descriptor: LegacyDaemonDescriptor) throws {
            guard let daemon = legacyDaemons[descriptor] else {
                throw LegacyServiceMigrationError.incomplete
            }
            try daemon.unregister()
        }
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
        case .notRegistered: return .disabledVerified
        case .enabled, .requiresApproval: return .desiredOffStillRegistered
        case .notFound, .unknown: return .desiredOffUnverified
        }
    }

    private let service: any ServiceControlling
    private let legacyDaemonDescriptors: [LegacyDaemonDescriptor]
    private let failurePresenter: (OperationFailure, ReconciliationTrigger, Locale) -> Void
    private let approvalPresenter: (Locale) -> Void
    /// 由 `AmuxAICleanApp` 初始化时注入；register / unregister 成功后会写
    /// `sentinelLastEnabled` 时间戳。
    private weak var settings: AppSettings?

    /// 下一次由本 manager 写入的 Toggle 事务。MainActor 串行保证“登记来源 → 写设置 →
    /// App onChange 消费”不会竞态；匹配 target 而非依赖 oldValue，可兼容 SwiftUI 合并更新。
    private var pendingProgrammaticToggleTransaction: ProgrammaticToggleTransaction?

    /// Latest desired/actual projection shown by Settings. It changes only after an explicit
    /// authoritative status read, never by assuming the toggle itself proves service state.
    @Published public private(set) var presentationState: PresentationState
    @Published public private(set) var lastFailure: OperationFailure?
    private var legacyMigrationState: LegacyMigrationState

    public init(settings: AppSettings) {
        let service = SystemService()
        self.service = service
        self.legacyDaemonDescriptors = Self.legacyDaemonDescriptors
        self.settings = settings
        self.failurePresenter = { failure, trigger, locale in
            SentinelManager.presentFailureAlert(failure, trigger: trigger, locale: locale)
        }
        self.approvalPresenter = { locale in
            SentinelManager.presentApprovalAlert(locale: locale)
        }
        self.presentationState = settings.sentinelEnabled
            ? .desiredOnUnverified
            : .desiredOffUnverified
        self.lastFailure = nil
        self.legacyMigrationState = .unverified
        self.pendingProgrammaticToggleTransaction = nil
    }

    init(
        settings: AppSettings,
        service: any ServiceControlling,
        legacyDaemonDescriptors: [LegacyDaemonDescriptor] = SentinelManager.legacyDaemonDescriptors,
        failurePresenter: @escaping (OperationFailure, ReconciliationTrigger, Locale) -> Void,
        approvalPresenter: @escaping (Locale) -> Void = { _ in }
    ) {
        self.service = service
        self.legacyDaemonDescriptors = legacyDaemonDescriptors
        self.settings = settings
        self.failurePresenter = failurePresenter
        self.approvalPresenter = approvalPresenter
        self.presentationState = settings.sentinelEnabled
            ? .desiredOnUnverified
            : .desiredOffUnverified
        self.lastFailure = nil
        self.legacyMigrationState = .unverified
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
        presentationState = projectPresentation(
            desiredEnabled: desiredEnabled,
            status: currentStatus()
        )
    }

    private func projectPresentation(
        desiredEnabled: Bool,
        status: Status
    ) -> PresentationState {
        guard legacyMigrationState == .verifiedCleared else {
            return desiredEnabled ? .desiredOnUnverified : .desiredOffUnverified
        }
        return Self.presentationState(desiredEnabled: desiredEnabled, status: status)
    }

    /// v2026.07.19 P1：系统明确报告某个 current authority 已注册时，持久化关闭核验证据。
    /// `.notFound` / `.unknown` 不是 active 证据；fresh/default-OFF 不能仅凭查询失败被要求
    /// 进入系统设置。相反，一旦见过 enabled/requiresApproval，证据只能在全部身份明确
    /// notRegistered 后清除。
    private func recordCurrentAuthorityEvidenceIfNeeded(_ status: Status) {
        guard status == .enabled || status == .requiresApproval else { return }
        settings?.sentinelRequiresShutdownVerification = true
    }

    /// A user-initiated OFF is always actionable. Startup lookup failures are actionable only
    /// when a prior successful registration/active system status supplied durable evidence.
    private func shouldSurfaceUnavailableShutdown(
        trigger: ReconciliationTrigger
    ) -> Bool {
        trigger == .user || settings?.sentinelRequiresShutdownVerification == true
    }

    /// Clear durable evidence only after the current Agent and historical identities have
    /// independently converged. This prevents a current-Agent success from erasing a legacy
    /// authority gap, while keeping never-enabled fresh installs quiet.
    private func clearShutdownVerificationEvidenceIfFullyConverged(
        currentStatus: Status
    ) {
        guard currentStatus == .notRegistered,
              legacyMigrationState == .verifiedCleared else { return }
        settings?.sentinelLastEnabled = nil
        settings?.sentinelRequiresShutdownVerification = false
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
    /// unregister error could leave UI OFF while launchd still ran the service.
    ///
    /// Current-Agent interactive failures restore the pre-gesture Toggle (`!requestedEnabled`).
    /// v2026.07.18 P1: a successful current-Agent OFF must never be reversed merely because a
    /// historical descriptor remains unverified; OFF stays persisted and receives a separate
    /// typed migration failure. Startup failures retain persisted intent. No raw NSError crosses
    /// the UI boundary.
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
        let locale = settings?.effectiveLocale ?? .current
        // v2026.07.18 P1：ON 是能力增加，必须先证明旧 root identity 已退出；OFF 是
        // 能力减少，必须优先注销 current Agent，不能被无关 legacy lookup 故障阻断。
        if requestedEnabled {
            do {
                try reconcileLegacyDaemons()
                legacyMigrationState = .verifiedCleared
            } catch {
                legacyMigrationState = .unverified
                AmuxLog.error(.sentinel, "legacy root daemon migration blocked enable: \(error)")
                let safetyShutdown = stopCurrentAgentAfterBlockedEnable()
                let current = safetyShutdown.status
                let failure: OperationFailure = safetyShutdown.isStopped
                    ? .legacyMigrationFailed(requestedEnabled: true)
                    : .legacyMigrationSafetyShutdownFailed
                let effectiveToggleEnabled = trigger == .user ? false : true
                if settings?.sentinelEnabled != effectiveToggleEnabled {
                    writeToggleProgrammatically(
                        effectiveToggleEnabled,
                        reason: trigger == .user ? .failureRollback : .directAPICommit
                    )
                }
                let presentation = projectPresentation(
                    desiredEnabled: effectiveToggleEnabled,
                    status: current
                )
                presentationState = presentation
                lastFailure = failure
                failurePresenter(failure, trigger, locale)
                return ReconciliationResult(
                    requestedEnabled: requestedEnabled,
                    effectiveToggleEnabled: effectiveToggleEnabled,
                    status: current,
                    presentation: presentation,
                    failure: failure
                )
            }
        }

        let initialStatus = currentStatus()
        recordCurrentAuthorityEvidenceIfNeeded(initialStatus)
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
            } else if !requestedEnabled, initialStatus == .notRegistered {
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
                AmuxLog.error(.sentinel, "register unavailable; status=\(initialStatus)")
            case .register:
                do {
                    try service.register()
                    finalStatus = currentStatus()
                    recordCurrentAuthorityEvidenceIfNeeded(finalStatus)
                    AmuxLog.info(.sentinel, "register returned; authoritativeStatus=\(finalStatus)")
                    switch finalStatus {
                    case .enabled:
                        settings?.sentinelLastEnabled = Date()
                    case .requiresApproval:
                        approvalPresenter(locale)
                    case .notRegistered, .notFound, .unknown:
                        failure = .registrationUnavailable(finalStatus)
                    }
                } catch {
                    AmuxLog.error(.sentinel, "register failed: \(error)")
                    failure = .registrationFailed
                    finalStatus = currentStatus()
                    recordCurrentAuthorityEvidenceIfNeeded(finalStatus)
                }
            }
        case .unavailable:
            // v2026.07.19 P1 root fix：status lookup failed before unregister was attempted, so
            // calling this `unregistrationFailed` is factually wrong. Fresh/default-OFF users
            // have no authority evidence and receive a structured diagnostic only; explicit OFF
            // gestures or durable registration evidence remain fail-closed and actionable.
            if shouldSurfaceUnavailableShutdown(trigger: trigger) {
                failure = .shutdownVerificationUnavailable(initialStatus)
                AmuxLog.error(
                    .sentinel,
                    "shutdown verification unavailable; status=\(initialStatus) "
                        + "trigger=\(trigger) evidence=true unregisterAttempted=false"
                )
            } else {
                AmuxLog.warning(
                    .sentinel,
                    "default-off status unavailable; status=\(initialStatus) "
                        + "evidence=false unregisterAttempted=false userActionRequired=false"
                )
            }
        case .disable:
            do {
                try service.unregister()
                finalStatus = currentStatus()
                recordCurrentAuthorityEvidenceIfNeeded(finalStatus)
                AmuxLog.info(.sentinel, "unregister returned; authoritativeStatus=\(finalStatus)")
                switch finalStatus {
                case .notRegistered:
                    settings?.sentinelLastEnabled = nil
                case .enabled, .requiresApproval, .notFound, .unknown:
                    failure = .unregistrationFailed
                }
            } catch {
                AmuxLog.error(.sentinel, "unregister failed: \(error)")
                finalStatus = currentStatus()
                recordCurrentAuthorityEvidenceIfNeeded(finalStatus)
                if finalStatus == .notRegistered {
                    // The API error is not authority. If the post-call read proves OFF, preserve
                    // the user's least-privilege intent and clear the enabled timestamp.
                    settings?.sentinelLastEnabled = nil
                    AmuxLog.notice(
                        .sentinel,
                        "unregister returned error but authoritative status converged to notRegistered"
                    )
                } else {
                    failure = .unregistrationFailed
                }
            }
        }

        let currentAgentFailure = failure
        if !requestedEnabled {
            do {
                try reconcileLegacyDaemons()
                legacyMigrationState = .verifiedCleared
            } catch {
                legacyMigrationState = .unverified
                AmuxLog.error(.sentinel, "legacy root daemon migration incomplete after Agent OFF: \(error)")
                if failure == nil,
                   settings?.sentinelRequiresShutdownVerification == true {
                    failure = .legacyMigrationFailed(requestedEnabled: false)
                } else if failure == nil {
                    // No persisted/current/legacy active evidence exists. Keep the status visible
                    // as unverified and retain the structured log, but do not instruct a fresh
                    // default-OFF user to repair a service they never enabled.
                    AmuxLog.warning(
                        .sentinel,
                        "legacy migration unavailable without authority evidence; "
                            + "userActionRequired=false"
                    )
                }
            }
            clearShutdownVerificationEvidenceIfFullyConverged(currentStatus: finalStatus)
        }

        let effectiveToggleEnabled: Bool
        let shouldRollbackUserGesture = currentAgentFailure != nil && trigger == .user
        if shouldRollbackUserGesture {
            effectiveToggleEnabled = !requestedEnabled
        } else {
            effectiveToggleEnabled = requestedEnabled
        }
        if settings?.sentinelEnabled != effectiveToggleEnabled {
            let reason: ProgrammaticToggleTransaction.Reason =
                shouldRollbackUserGesture
                    ? .failureRollback
                    : .directAPICommit
            writeToggleProgrammatically(
                effectiveToggleEnabled,
                reason: reason
            )
        }
        let presentation = projectPresentation(
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

    /// Migrate every historical root identity as one admission barrier for the current Agent.
    ///
    /// The loop deliberately does not fail fast: an unavailable descriptor must not prevent us
    /// from unregistering another daemon if that job is still active. Conversely, the aggregate
    /// succeeds only when *every* final status is explicitly `.notRegistered`; `.notFound`,
    /// future unknown states and a still-registered service all fail closed.
    private func reconcileLegacyDaemons() throws {
        var hasUnsettledIdentity = false

        for descriptor in legacyDaemonDescriptors {
            let initialStatus = service.legacyDaemonStatus(for: descriptor)
            if initialStatus == .enabled || initialStatus == .requiresApproval {
                // v2026.07.19 P1：即使本地 defaults 丢失，系统明确报告 active 仍是可信
                // authority 证据；在其它 identity 查询失败时必须继续保留并提示用户。
                settings?.sentinelRequiresShutdownVerification = true
            }
            switch Self.legacyMigrationAction(for: initialStatus) {
            case .alreadyCleared:
                AmuxLog.notice(
                    .sentinel,
                    "legacy root daemon migration verified; label=\(descriptor.label) status=notRegistered"
                )

            case .unavailable:
                hasUnsettledIdentity = true
                AmuxLog.error(
                    .sentinel,
                    "legacy root daemon migration status unavailable; label=\(descriptor.label) status=\(initialStatus)"
                )

            case .unregister:
                do {
                    try service.unregisterLegacyDaemon(descriptor)
                } catch {
                    // Do not decide from the API error alone. A final authoritative read is the
                    // only proof, and remaining descriptors still need their own migration pass.
                    AmuxLog.error(
                        .sentinel,
                        "legacy root daemon unregister returned error; label=\(descriptor.label) error=\(error)"
                    )
                }

                let finalStatus = service.legacyDaemonStatus(for: descriptor)
                if finalStatus == .enabled || finalStatus == .requiresApproval {
                    settings?.sentinelRequiresShutdownVerification = true
                }
                if finalStatus == .notRegistered {
                    AmuxLog.notice(
                        .sentinel,
                        "legacy root daemon migration converged; label=\(descriptor.label) status=notRegistered"
                    )
                } else {
                    hasUnsettledIdentity = true
                    AmuxLog.error(
                        .sentinel,
                        "legacy root daemon migration did not converge; label=\(descriptor.label) status=\(finalStatus)"
                    )
                }
            }
        }

        guard !hasUnsettledIdentity else {
            throw LegacyServiceMigrationError.incomplete
        }
    }

    /// ON migration failure is an admission failure, but a previously registered current Agent
    /// may already be running. Reduce capability before returning: unregister enabled/approval
    /// states and always re-read authority. Only `.notRegistered` proves the safety shutdown;
    /// lookup failures and future states remain explicitly unverified.
    private func stopCurrentAgentAfterBlockedEnable() -> (status: Status, isStopped: Bool) {
        var status = currentStatus()
        recordCurrentAuthorityEvidenceIfNeeded(status)
        switch Self.reconciliationAction(isEnabled: false, currentStatus: status) {
        case .none:
            settings?.sentinelLastEnabled = nil
            return (status, true)

        case .disable:
            do {
                try service.unregister()
            } catch {
                AmuxLog.error(
                    .sentinel,
                    "current Agent safety shutdown returned error after legacy migration failure: \(error)"
                )
            }
            status = currentStatus()
            recordCurrentAuthorityEvidenceIfNeeded(status)
            if status == .notRegistered {
                settings?.sentinelLastEnabled = nil
                AmuxLog.notice(
                    .sentinel,
                    "current Agent safety shutdown converged after legacy migration failure"
                )
                return (status, true)
            }
            AmuxLog.error(
                .sentinel,
                "current Agent safety shutdown did not converge; status=\(status)"
            )
            return (status, false)

        case .unavailable:
            AmuxLog.error(
                .sentinel,
                "current Agent safety shutdown status unavailable; status=\(status)"
            )
            return (status, false)

        case .enable:
            // OFF reconciliation never returns `.enable`; retain fail-closed behavior if the
            // policy changes in a future SDK/refactor.
            AmuxLog.error(.sentinel, "current Agent safety shutdown reached invalid enable action")
            return (status, false)
        }
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
        // v2026.07.19 P1：状态/errno/路径继续进入结构化日志；用户只看到具体动作与
        // App 内“设置 → 存储 → 日志”入口。裸目录路径既不可操作，也会泄露账户名，不能再
        // 作为所谓“技术详情”塞进 modal。
        alert.informativeText = failure.localizedBody(
            locale: locale,
            trigger: trigger
        )
        alert.addButton(withTitle: AppLocalization.string("sentinel.alert.button.open_settings", locale: locale))
        alert.addButton(withTitle: AppLocalization.string("sentinel.alert.button.keep_current", locale: locale))
        alert.alertStyle = .warning
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
