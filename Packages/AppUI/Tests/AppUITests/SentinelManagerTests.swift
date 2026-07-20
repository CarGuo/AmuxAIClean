import XCTest
import ServiceManagement
@testable import AppUI

/// Step 6.5：[SentinelManager](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelManager.swift)
/// 可单测部分（不触发 NSAlert 模态、不真实 register/unregister）。
///
/// **能测什么**：
/// - `Status` 枚举对 `SMAppService.Status` 的全量映射 + `displayLabel` 文案契约
/// - 当前用户 Agent 与两代 Daemon 迁移描述符使用三个独立文件名/Label；旧域只有注销路径
/// - `currentStatus()` 在测试 bundle（未签名）下能稳定读到一个非崩溃值
///
/// **不能测什么**：
/// - `enable()` / `disable()` —— 调 `SMAppService.agent().register()` 在 SwiftPM
///   test bundle（无 .app wrapper / 无 LaunchAgents embed）下必抛错，
///   失败路径会进 `NSAlert.runModal()` 阻塞测试（XCTest 没有 NSApp run loop 来 dismiss alert）。
///   v2026.07.16 起不再用快速启停 Runner 覆盖。真签名 `.app` + 用户授权流只允许在
///   明确批准的一次持续 C4 中验证，不能由自动化反复 register/unregister 系统服务。
final class SentinelManagerTests: XCTestCase {

    private enum StubError: Error { case operationFailed }

    @MainActor
    private final class StubService: SentinelManager.ServiceControlling {
        var status: SentinelManager.Status
        var statusAfterRegister: SentinelManager.Status?
        var statusAfterUnregister: SentinelManager.Status?
        var registerError: Error?
        var unregisterError: Error?
        var legacyStatuses: [SentinelManager.LegacyDaemonDescriptor: SentinelManager.Status]
        var legacyStatusesAfterUnregister:
            [SentinelManager.LegacyDaemonDescriptor: SentinelManager.Status] = [:]
        var legacyUnregisterErrors: [SentinelManager.LegacyDaemonDescriptor: Error] = [:]
        private(set) var operationOrder: [String] = []
        private(set) var legacyStatusReads: [SentinelManager.LegacyDaemonDescriptor] = []
        private(set) var legacyUnregisterCalls: [SentinelManager.LegacyDaemonDescriptor] = []
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(status: SentinelManager.Status) {
            self.status = status
            self.legacyStatuses = Dictionary(
                uniqueKeysWithValues: SentinelManager.legacyDaemonDescriptors.map {
                    ($0, .notRegistered)
                }
            )
        }

        func legacyDaemonStatus(
            for descriptor: SentinelManager.LegacyDaemonDescriptor
        ) -> SentinelManager.Status {
            operationOrder.append("legacy-status:\(descriptor.label)")
            legacyStatusReads.append(descriptor)
            return legacyStatuses[descriptor] ?? .notFound
        }

        func unregisterLegacyDaemon(
            _ descriptor: SentinelManager.LegacyDaemonDescriptor
        ) throws {
            operationOrder.append("legacy-unregister:\(descriptor.label)")
            legacyUnregisterCalls.append(descriptor)
            if let finalStatus = legacyStatusesAfterUnregister[descriptor] {
                legacyStatuses[descriptor] = finalStatus
            }
            if let error = legacyUnregisterErrors[descriptor] { throw error }
        }

        func register() throws {
            operationOrder.append("agent-register")
            registerCalls += 1
            if let registerError { throw registerError }
            if let statusAfterRegister { status = statusAfterRegister }
        }

        func unregister() throws {
            operationOrder.append("agent-unregister")
            unregisterCalls += 1
            if let statusAfterUnregister { status = statusAfterUnregister }
            if let unregisterError { throw unregisterError }
        }
    }

    @MainActor
    private func makeSettings(_ suffix: String) -> AppSettings {
        let suite = "GSYCleanMac.tests.SentinelManager.\(suffix).\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return AppSettings(testSuite: suite)
    }

    func test_reconciliationPolicyDoesNotUnregisterOnDefaultOffLaunch() {
        XCTAssertEqual(
            SentinelManager.reconciliationAction(
                isEnabled: false,
                currentStatus: .notRegistered
            ),
            .none
        )
        XCTAssertEqual(
            SentinelManager.reconciliationAction(
                isEnabled: true,
                currentStatus: .notRegistered
            ),
            .enable
        )
        XCTAssertEqual(
            SentinelManager.reconciliationAction(
                isEnabled: false,
                currentStatus: .enabled
            ),
            .disable
        )
        XCTAssertEqual(
            SentinelManager.reconciliationAction(
                isEnabled: false,
                currentStatus: .requiresApproval
            ),
            .disable,
            "OFF must unregister a stale service even during launch reconciliation"
        )
        XCTAssertEqual(
            SentinelManager.reconciliationAction(
                isEnabled: true,
                currentStatus: .enabled
            ),
            .none,
            "ON plus enabled must not repeat register"
        )
    }

    func test_registrationDomainIsNonPrivilegedUserAgent() {
        XCTAssertEqual(SentinelManager.registrationDomain, .userAgent)
    }

    @MainActor
    func test_任一历史RootDaemon未收敛时不会再注册UserAgent_且仍检查另一身份() {
        let settings = makeSettings("legacy-daemon-cleanup")
        settings.sentinelEnabled = true
        let service = StubService(status: .notRegistered)
        let original = SentinelManager.legacyDaemonDescriptors[0]
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        service.legacyStatuses[original] = .enabled
        service.legacyUnregisterErrors[original] = StubError.operationFailed
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertEqual(
            service.legacyStatusReads,
            [original, original, renamed],
            "first migration failure must not skip the remaining historical authority"
        )
        XCTAssertEqual(service.legacyUnregisterCalls, [original])
        XCTAssertEqual(service.registerCalls, 0, "legacy root daemon未收敛时不能叠加user agent")
        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: true))
        XCTAssertEqual(
            result.presentation,
            .desiredOnUnverified,
            "legacy daemon cleanup failure must never project the current Agent alone as verified"
        )
        XCTAssertEqual(presented, [.legacyMigrationFailed(requestedEnabled: true)])
        XCTAssertTrue(settings.sentinelEnabled, "启动修复失败保留用户意图并明确呈现不一致")
    }

    @MainActor
    func test_legacyRootDaemon清理失败后刷新也不能伪装成已验证关闭() {
        let settings = makeSettings("legacy-daemon-refresh")
        settings.sentinelEnabled = false
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .notRegistered)
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        service.legacyStatuses[renamed] = .unknown(91)
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: false))
        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(presented, [.legacyMigrationFailed(requestedEnabled: false)])
        XCTAssertEqual(manager.presentationState, .desiredOffUnverified)

        manager.refreshPresentation()

        XCTAssertEqual(
            manager.presentationState,
            .desiredOffUnverified,
            "refresh must retain the unresolved legacy authority dimension"
        )
    }

    @MainActor
    func test_userOFF先注销CurrentAgent_再迁移两代Root_legacy失败不回滚ON() {
        let settings = makeSettings("user-off-agent-first")
        settings.sentinelEnabled = true
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let original = SentinelManager.legacyDaemonDescriptors[0]
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        service.legacyStatuses[original] = .notFound
        service.legacyStatuses[renamed] = .enabled
        service.legacyStatusesAfterUnregister[renamed] = .notRegistered
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = false
        let result = manager.reconcile(trigger: .user)

        XCTAssertFalse(settings.sentinelEnabled, "a verified Agent OFF must remain least privilege")
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.status, .notRegistered)
        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: false))
        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(presented, [.legacyMigrationFailed(requestedEnabled: false)])
        XCTAssertEqual(
            service.operationOrder,
            [
                "agent-unregister",
                "legacy-status:\(original.label)",
                "legacy-status:\(renamed.label)",
                "legacy-unregister:\(renamed.label)",
                "legacy-status:\(renamed.label)",
            ],
            "OFF must reduce current capability before any legacy descriptor lookup"
        )
    }

    @MainActor
    func test_startupOFF先注销CurrentAgent_legacy失败仍保留OFF意图() {
        let settings = makeSettings("startup-off-agent-first")
        settings.sentinelEnabled = false
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let original = SentinelManager.legacyDaemonDescriptors[0]
        service.legacyStatuses[original] = .unknown(404)
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.status, .notRegistered)
        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: false))
        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(service.operationOrder.first, "agent-unregister")
    }

    @MainActor
    func test_currentAgent注销抛错但复读notRegistered_不回滚OFF() {
        let settings = makeSettings("agent-error-but-off")
        settings.sentinelEnabled = true
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        service.unregisterError = StubError.operationFailed
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in XCTFail("authoritative Agent OFF must win") }
        )

        settings.sentinelEnabled = false
        let result = manager.reconcile(trigger: .user)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertFalse(
            settings.sentinelRequiresShutdownVerification,
            "current Agent 与两代 legacy identity 全部收敛后才可清 authority 证据"
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.status, .notRegistered)
        XCTAssertEqual(result.presentation, .disabledVerified)
    }

    @MainActor
    func test_两代RootDaemon逐项权威收敛后才允许注册UserAgent() {
        let settings = makeSettings("both-legacy-daemons")
        settings.sentinelEnabled = true
        let service = StubService(status: .notRegistered)
        let original = SentinelManager.legacyDaemonDescriptors[0]
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        for descriptor in [original, renamed] {
            service.legacyStatuses[descriptor] = .enabled
            service.legacyStatusesAfterUnregister[descriptor] = .notRegistered
        }
        service.statusAfterRegister = .enabled
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in XCTFail("success must not present failure") }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.presentation, .enabledVerified)
        XCTAssertEqual(service.legacyUnregisterCalls, [original, renamed])
        XCTAssertEqual(
            service.operationOrder,
            [
                "legacy-status:\(original.label)",
                "legacy-unregister:\(original.label)",
                "legacy-status:\(original.label)",
                "legacy-status:\(renamed.label)",
                "legacy-unregister:\(renamed.label)",
                "legacy-status:\(renamed.label)",
                "agent-register",
            ],
            "new Agent admission requires final notRegistered proof for both root identities"
        )
    }

    @MainActor
    func test_一代notFound仍清理另一代但整体失败关闭() {
        let settings = makeSettings("legacy-not-found")
        settings.sentinelEnabled = true
        let service = StubService(status: .notRegistered)
        let original = SentinelManager.legacyDaemonDescriptors[0]
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        service.legacyStatuses[original] = .notFound
        service.legacyStatuses[renamed] = .requiresApproval
        service.legacyStatusesAfterUnregister[renamed] = .notRegistered
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: true))
        XCTAssertEqual(result.presentation, .desiredOnUnverified)
        XCTAssertEqual(service.legacyUnregisterCalls, [renamed])
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(
            service.legacyStatusReads,
            [original, renamed, renamed],
            "notFound is fail-closed but must not abandon a cleanable sibling identity"
        )
    }

    @MainActor
    func test_userON_legacy失败且CurrentAgent已enabled_安全注销后回滚OFF() {
        let settings = makeSettings("user-on-safety-shutdown-success")
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let original = SentinelManager.legacyDaemonDescriptors[0]
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        service.legacyStatuses[original] = .notFound
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = true
        let result = manager.reconcile(trigger: .user)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.status, .notRegistered)
        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: true))
        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(presented, [.legacyMigrationFailed(requestedEnabled: true)])
        XCTAssertEqual(
            service.operationOrder,
            [
                "legacy-status:\(original.label)",
                "legacy-status:\(renamed.label)",
                "agent-unregister",
            ]
        )
    }

    @MainActor
    func test_startupON_legacy失败且CurrentAgent已enabled_安全注销但保留ON期望() {
        let settings = makeSettings("startup-on-safety-shutdown-success")
        settings.sentinelEnabled = true
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let original = SentinelManager.legacyDaemonDescriptors[0]
        service.legacyStatuses[original] = .unknown(73)
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertTrue(settings.sentinelEnabled, "startup keeps persisted intent, not actual runtime state")
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.status, .notRegistered)
        XCTAssertEqual(result.failure, .legacyMigrationFailed(requestedEnabled: true))
        XCTAssertEqual(result.presentation, .desiredOnUnverified)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(service.operationOrder.last, "agent-unregister")
    }

    @MainActor
    func test_userON_legacy失败且CurrentAgent安全注销失败_不伪装已停() {
        let settings = makeSettings("user-on-safety-shutdown-failure")
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.unregisterError = StubError.operationFailed
        let original = SentinelManager.legacyDaemonDescriptors[0]
        service.legacyStatuses[original] = .notFound
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = true
        let result = manager.reconcile(trigger: .user)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertNotNil(settings.sentinelLastEnabled, "actual Agent is still enabled")
        XCTAssertEqual(result.status, .enabled)
        XCTAssertEqual(result.failure, .legacyMigrationSafetyShutdownFailed)
        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(presented, [.legacyMigrationSafetyShutdownFailed])
    }

    @MainActor
    func test_startupON_legacy失败且CurrentAgent安全注销失败_保留期望但实际unverified() {
        let settings = makeSettings("startup-on-safety-shutdown-failure")
        settings.sentinelEnabled = true
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.unregisterError = StubError.operationFailed
        let original = SentinelManager.legacyDaemonDescriptors[0]
        service.legacyStatuses[original] = .unknown(88)
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertNotNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.status, .enabled)
        XCTAssertEqual(result.failure, .legacyMigrationSafetyShutdownFailed)
        XCTAssertEqual(result.presentation, .desiredOnUnverified)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    @MainActor
    func test_历史Daemon注销抛错但复读已notRegistered_以权威终态为准() {
        let settings = makeSettings("legacy-error-but-converged")
        settings.sentinelEnabled = true
        let service = StubService(status: .notRegistered)
        let original = SentinelManager.legacyDaemonDescriptors[0]
        service.legacyStatuses[original] = .enabled
        service.legacyStatusesAfterUnregister[original] = .notRegistered
        service.legacyUnregisterErrors[original] = StubError.operationFailed
        service.statusAfterRegister = .enabled
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in XCTFail("authoritative convergence must win") }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.presentation, .enabledVerified)
        XCTAssertEqual(service.legacyUnregisterCalls, [original])
        XCTAssertEqual(service.registerCalls, 1)
    }

    func test_enablePolicyRegistersOnlyWhenServiceIsNotRegistered() {
        // v2026.07.16：锁定 SMAppService 幂等边界；重复 register 是已知系统错误来源。
        XCTAssertEqual(SentinelManager.enableAction(for: .enabled), .alreadyEnabled)
        XCTAssertEqual(SentinelManager.enableAction(for: .notRegistered), .register)
        XCTAssertEqual(SentinelManager.enableAction(for: .requiresApproval), .requestApproval)
        XCTAssertEqual(SentinelManager.enableAction(for: .notFound), .unavailable)
        XCTAssertEqual(SentinelManager.enableAction(for: .unknown(99)), .unavailable)
    }

    func test_offPolicy_neverTreatsServiceLookupFailureAsVerifiedUnregistered() {
        XCTAssertEqual(
            SentinelManager.reconciliationAction(isEnabled: false, currentStatus: .notRegistered),
            .none
        )
        XCTAssertEqual(
            SentinelManager.reconciliationAction(isEnabled: false, currentStatus: .notFound),
            .unavailable
        )
        XCTAssertEqual(
            SentinelManager.reconciliationAction(isEnabled: false, currentStatus: .unknown(99)),
            .unavailable
        )
        XCTAssertEqual(
            SentinelManager.presentationState(desiredEnabled: false, status: .notFound),
            .desiredOffUnverified
        )
    }

    @MainActor
    func test_startupDefaultOFF无Authority证据_三身份notFound只记日志不弹窗() {
        let settings = makeSettings("fresh-default-off-not-found")
        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertFalse(settings.sentinelRequiresShutdownVerification)
        let service = StubService(status: .notFound)
        for descriptor in SentinelManager.legacyDaemonDescriptors {
            service.legacyStatuses[descriptor] = .notFound
        }
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertFalse(settings.sentinelRequiresShutdownVerification)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertNil(result.failure, "fresh/default-OFF lookup failure is diagnostic, not user work")
        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(service.unregisterCalls, 0, "status lookup failure is not an unregister attempt")
        XCTAssertTrue(service.legacyUnregisterCalls.isEmpty)
        XCTAssertEqual(service.legacyStatusReads, SentinelManager.legacyDaemonDescriptors)
        XCTAssertTrue(presented.isEmpty, "never-enabled users must not receive a startup modal")
    }

    @MainActor
    func test_startup已有Authority证据但状态notFound_保留FailClosed并给出专用错误() {
        let settings = makeSettings("known-authority-not-found")
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(settings.sentinelRequiresShutdownVerification)
        let service = StubService(status: .notFound)
        for descriptor in SentinelManager.legacyDaemonDescriptors {
            service.legacyStatuses[descriptor] = .notFound
        }
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertTrue(settings.sentinelRequiresShutdownVerification)
        XCTAssertNotNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.failure, .shutdownVerificationUnavailable(.notFound))
        XCTAssertEqual(presented, [.shutdownVerificationUnavailable(.notFound)])
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    @MainActor
    func test_startupDefaultOFF但系统明确AgentEnabled_仍注销且全收敛后清证据() {
        let settings = makeSettings("default-off-active-authority")
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertEqual(service.unregisterCalls, 1, "explicit active status must override missing defaults")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.presentation, .disabledVerified)
        XCTAssertFalse(settings.sentinelRequiresShutdownVerification)
        XCTAssertTrue(presented.isEmpty)
    }

    func test_legacyMigrationPolicy_onlyExplicitNotRegisteredIsCleared() {
        XCTAssertEqual(
            SentinelManager.legacyMigrationAction(for: .notRegistered),
            .alreadyCleared
        )
        XCTAssertEqual(
            SentinelManager.legacyMigrationAction(for: .enabled),
            .unregister
        )
        XCTAssertEqual(
            SentinelManager.legacyMigrationAction(for: .requiresApproval),
            .unregister
        )
        XCTAssertEqual(
            SentinelManager.legacyMigrationAction(for: .notFound),
            .unavailable
        )
        XCTAssertEqual(
            SentinelManager.legacyMigrationAction(for: .unknown(99)),
            .unavailable
        )
    }

    @MainActor
    func test_userTurnsOffWhenStatusNotFound_rollsBackAndRetainsTimestamp() {
        let settings = makeSettings("off-not-found")
        settings.sentinelEnabled = false
        let enabledAt = Date(timeIntervalSince1970: 123)
        settings.sentinelLastEnabled = enabledAt
        let service = StubService(status: .notFound)
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .user)

        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertEqual(settings.sentinelLastEnabled, enabledAt)
        XCTAssertEqual(result.failure, .shutdownVerificationUnavailable(.notFound))
        XCTAssertEqual(result.presentation, .desiredOnUnverified)
        XCTAssertEqual(presented, [.shutdownVerificationUnavailable(.notFound)])
    }

    func test_presentationPolicy_期望与权威状态分开建模() {
        XCTAssertEqual(
            SentinelManager.presentationState(desiredEnabled: true, status: .enabled),
            .enabledVerified
        )
        XCTAssertEqual(
            SentinelManager.presentationState(desiredEnabled: true, status: .notRegistered),
            .desiredOnNotRunning
        )
        XCTAssertEqual(
            SentinelManager.presentationState(desiredEnabled: true, status: .unknown(88)),
            .desiredOnUnverified,
            "ON + unavailable must never be projected as enabled"
        )
        XCTAssertEqual(
            SentinelManager.presentationState(desiredEnabled: false, status: .enabled),
            .desiredOffStillRegistered
        )
        XCTAssertEqual(
            SentinelManager.presentationState(desiredEnabled: false, status: .unknown(88)),
            .desiredOffUnverified
        )
    }

    @MainActor
    func test_userDisable失败_恢复toggle保留时间戳并呈现typedFailure() {
        let settings = makeSettings("disable-user-failure")
        settings.sentinelEnabled = true
        let enabledAt = Date(timeIntervalSince1970: 1_780_000_000)
        settings.sentinelLastEnabled = enabledAt
        let service = StubService(status: .enabled)
        service.unregisterError = StubError.operationFailed
        let renamed = SentinelManager.legacyDaemonDescriptors[1]
        service.legacyStatuses[renamed] = .enabled
        service.legacyStatusesAfterUnregister[renamed] = .notRegistered
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = false
        let result = manager.reconcile(trigger: .user)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(
            service.operationOrder,
            ["agent-unregister"] + SentinelManager.legacyDaemonDescriptors.flatMap {
                $0 == renamed
                    ? [
                        "legacy-status:\($0.label)",
                        "legacy-unregister:\($0.label)",
                        "legacy-status:\($0.label)",
                    ]
                    : ["legacy-status:\($0.label)"]
            },
            "current Agent注销失败仍须继续收敛两代root，但交互回滚由current失败决定"
        )
        XCTAssertTrue(settings.sentinelEnabled, "failed OFF gesture must restore the prior ON toggle")
        XCTAssertEqual(settings.sentinelLastEnabled, enabledAt)
        XCTAssertEqual(result.failure, .unregistrationFailed)
        XCTAssertEqual(result.presentation, .enabledVerified)
        XCTAssertEqual(presented, [.unregistrationFailed])
    }

    @MainActor
    func test_onChangeFeedbackLoop_enable失败只register回滚提示各一次() {
        let settings = makeSettings("enable-feedback-loop")
        let service = StubService(status: .notRegistered)
        service.registerError = StubError.operationFailed
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        // 第一轮是 Toggle 真实用户手势：OFF -> ON。
        settings.sentinelEnabled = true
        let userChange = manager.handleObservedToggleChange(from: false, to: true)
        guard case .reconciledUserChange(let result) = userChange else {
            return XCTFail("真实用户变化必须进入一次 reconcile")
        }
        XCTAssertEqual(result.failure, .registrationFailed)
        XCTAssertFalse(settings.sentinelEnabled, "失败必须恰好一次回滚到 OFF")
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(presented, [.registrationFailed])

        // 第二轮模拟 SwiftUI 因 manager 回滚产生的 onChange：ON -> OFF。
        // 它必须只消费 programmatic transaction，绝不能再被当作一次用户关闭动作。
        let rollbackFeedback = manager.handleObservedToggleChange(from: true, to: false)
        guard case .suppressedProgrammaticChange(let transaction) = rollbackFeedback else {
            return XCTFail("程序性回滚必须被 typed transaction 消费")
        }
        XCTAssertEqual(transaction.reason, .failureRollback)
        XCTAssertFalse(transaction.targetEnabled)
        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertEqual(service.registerCalls, 1, "一次用户手势只能提交一次 register")
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(presented, [.registrationFailed], "一次失败只能提示一次")
    }

    @MainActor
    func test_failurePresenter嵌套runLoop期间回授_仍只消费事务不重入系统动作() {
        let settings = makeSettings("nested-feedback-loop")
        let service = StubService(status: .notRegistered)
        service.registerError = StubError.operationFailed
        var promptCount = 0
        var nestedFeedback: SentinelManager.ObservedToggleChangeResult?
        var manager: SentinelManager!
        manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in
                promptCount += 1
                // NSAlert.runModal 会运行嵌套 event loop；真实 App 的回滚 onChange 可能在
                // reconcile 尚未返回时到达。事务必须在 presenter 之前已经登记完成。
                nestedFeedback = manager.handleObservedToggleChange(from: true, to: false)
            }
        )
        defer { manager = nil }

        settings.sentinelEnabled = true
        let outer = manager.handleObservedToggleChange(from: false, to: true)

        guard case .reconciledUserChange(let result) = outer,
              case .suppressedProgrammaticChange(let transaction)? = nestedFeedback else {
            return XCTFail("嵌套 run loop 的 rollback feedback 必须命中同一 typed transaction")
        }
        XCTAssertEqual(result.failure, .registrationFailed)
        XCTAssertEqual(transaction.reason, .failureRollback)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(promptCount, 1)
        XCTAssertFalse(settings.sentinelEnabled)
    }

    @MainActor
    func test_onChangeFeedbackLoop_disable失败只unregister回滚提示各一次() {
        let settings = makeSettings("disable-feedback-loop")
        settings.sentinelEnabled = true
        let service = StubService(status: .enabled)
        service.unregisterError = StubError.operationFailed
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = false
        let userChange = manager.handleObservedToggleChange(from: true, to: false)
        guard case .reconciledUserChange(let result) = userChange else {
            return XCTFail("真实用户变化必须进入一次 reconcile")
        }
        XCTAssertEqual(result.failure, .unregistrationFailed)
        XCTAssertTrue(settings.sentinelEnabled, "失败必须恰好一次回滚到 ON")
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(presented, [.unregistrationFailed])

        let rollbackFeedback = manager.handleObservedToggleChange(from: false, to: true)
        guard case .suppressedProgrammaticChange(let transaction) = rollbackFeedback else {
            return XCTFail("程序性回滚必须被 typed transaction 消费")
        }
        XCTAssertEqual(transaction.reason, .failureRollback)
        XCTAssertTrue(transaction.targetEnabled)
        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertEqual(service.unregisterCalls, 1, "一次用户手势只能提交一次 unregister")
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(presented, [.unregistrationFailed], "一次失败只能提示一次")
    }

    @MainActor
    func test_programmaticTransaction被合并后_下一次真实手势不会被误抑制() {
        let settings = makeSettings("coalesced-programmatic-change")
        let service = StubService(status: .notRegistered)
        service.registerError = StubError.operationFailed
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in }
        )

        settings.sentinelEnabled = true
        _ = manager.handleObservedToggleChange(from: false, to: true)
        XCTAssertFalse(settings.sentinelEnabled)

        // 假设 SwiftUI 合并掉了回滚的第二轮通知：pending target 仍是 false。
        // 用户下一次必然从当前 false 改到 true；target 不匹配时必须退休旧事务并正常处理。
        service.registerError = nil
        service.statusAfterRegister = .enabled
        settings.sentinelEnabled = true
        let nextUserChange = manager.handleObservedToggleChange(from: false, to: true)

        guard case .reconciledUserChange(let result) = nextUserChange else {
            return XCTFail("离开旧 target 的新变化必须被识别为真实用户手势")
        }
        XCTAssertNil(result.failure)
        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertEqual(service.registerCalls, 2)
    }

    @MainActor
    func test_directAPICommit也由typed事务抑制App二次动作() {
        let settings = makeSettings("direct-api-commit")
        let service = StubService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in XCTFail("success must not present failure") }
        )

        XCTAssertTrue(manager.enable())
        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(
            service.operationOrder,
            SentinelManager.legacyDaemonDescriptors.map {
                "legacy-status:\($0.label)"
            } + ["agent-register"],
            "两代旧 daemon 未逐项收敛前不得注册新 agent"
        )

        let observedCommit = manager.handleObservedToggleChange(from: false, to: true)
        guard case .suppressedProgrammaticChange(let transaction) = observedCommit else {
            return XCTFail("直接 API 的 setting commit 必须被标记为 programmatic")
        }
        XCTAssertEqual(transaction.reason, .directAPICommit)
        XCTAssertTrue(transaction.targetEnabled)
        XCTAssertEqual(service.registerCalls, 1, "App onChange 不得重复 direct API 的系统动作")
    }

    @MainActor
    func test_startupDisable失败_保留OFF意图并明确显示仍注册() {
        let settings = makeSettings("disable-startup-failure")
        settings.sentinelEnabled = false
        let service = StubService(status: .enabled)
        service.unregisterError = StubError.operationFailed
        var presented: [SentinelManager.OperationFailure] = []
        var presentedTriggers: [SentinelManager.ReconciliationTrigger] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, trigger, _ in
                presented.append(failure)
                presentedTriggers.append(trigger)
            }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertFalse(settings.sentinelEnabled, "launch repair must retain persisted intent")
        XCTAssertEqual(result.presentation, .desiredOffStillRegistered)
        XCTAssertEqual(result.failure, .unregistrationFailed)
        XCTAssertEqual(presented, [.unregistrationFailed],
                       "launch reconciliation failure cannot be silent")
        XCTAssertEqual(presentedTriggers, [.startup],
                       "startup failure copy must not claim an interactive toggle was restored")
    }

    @MainActor
    func test_startupEnable注册失败_保留ON意图但不假装enabled() {
        let settings = makeSettings("enable-startup-failure")
        settings.sentinelEnabled = true
        let service = StubService(status: .notRegistered)
        service.registerError = StubError.operationFailed
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        let result = manager.reconcile(trigger: .startup)

        XCTAssertTrue(settings.sentinelEnabled)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertEqual(result.presentation, .desiredOnNotRunning)
        XCTAssertEqual(result.failure, .registrationFailed)
        XCTAssertEqual(presented, [.registrationFailed])
    }

    @MainActor
    func test_userEnable状态不可用_恢复OFF并呈现typedFailure() {
        let settings = makeSettings("enable-user-unavailable")
        let service = StubService(status: .unknown(77))
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = true
        let result = manager.reconcile(trigger: .user)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertEqual(service.registerCalls, 0, "unknown authority must not blindly register")
        XCTAssertEqual(result.failure, .registrationUnavailable(.unknown(77)))
        XCTAssertEqual(result.presentation, .desiredOffUnverified)
        XCTAssertEqual(presented, [.registrationUnavailable(.unknown(77))])
    }

    @MainActor
    func test_disable成功_权威notRegistered后才清时间戳() {
        let settings = makeSettings("disable-success")
        settings.sentinelEnabled = true
        settings.sentinelLastEnabled = Date(timeIntervalSince1970: 1_780_000_000)
        let service = StubService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { _, _, _ in XCTFail("success must not present failure") }
        )

        settings.sentinelEnabled = false
        let result = manager.reconcile(trigger: .user)

        XCTAssertFalse(settings.sentinelEnabled)
        XCTAssertNil(settings.sentinelLastEnabled)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.presentation, .disabledVerified)
        XCTAssertEqual(
            service.legacyStatusReads,
            SentinelManager.legacyDaemonDescriptors
        )
        XCTAssertTrue(service.legacyUnregisterCalls.isEmpty)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(
            service.operationOrder,
            ["agent-unregister"] + SentinelManager.legacyDaemonDescriptors.map {
                "legacy-status:\($0.label)"
            }
        )
    }

    func test_typedFailure与unverified状态_中英文实时投影() {
        let failure = SentinelManager.OperationFailure.unregistrationFailed
        XCTAssertEqual(failure.localizedTitle(locale: Locale(identifier: "en")), "Disable Failed")
        XCTAssertEqual(failure.localizedTitle(locale: Locale(identifier: "zh-Hans")), "关闭失败")
        XCTAssertTrue(failure.localizedBody(
            locale: Locale(identifier: "en")
        ).contains("tried to stop"))
        XCTAssertTrue(failure.localizedBody(
            locale: Locale(identifier: "zh-Hans")
        ).contains("已尝试停止"))
        XCTAssertTrue(failure.localizedBody(
            locale: Locale(identifier: "en"),
            trigger: .startup
        ).contains("previously enabled"))
        XCTAssertFalse(failure.localizedBody(
            locale: Locale(identifier: "zh-Hans"),
            trigger: .startup
        ).contains("开关恢复"), "启动对账不能谎称发生了交互回滚")

        let lookupFailure = SentinelManager.OperationFailure
            .shutdownVerificationUnavailable(.notFound)
        XCTAssertEqual(
            lookupFailure.localizedTitle(locale: Locale(identifier: "zh-Hans")),
            "后台状态无法确认"
        )
        let lookupBody = lookupFailure.localizedBody(locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(lookupBody.contains("本次没有执行关闭操作"))
        XCTAssertTrue(lookupBody.contains("系统设置 → 通用 → 登录项与扩展"))
        XCTAssertTrue(lookupBody.contains("设置 → 存储 → 日志"))
        XCTAssertFalse(lookupBody.contains("/Users/"), "用户提示不得裸露日志路径或账户名")
        XCTAssertEqual(
            SentinelManager.PresentationState.desiredOnUnverified.localized(
                locale: Locale(identifier: "en")
            ),
            "Requested on · Actual status not verified"
        )
        XCTAssertEqual(
            SentinelManager.PresentationState.desiredOnUnverified.localized(
                locale: Locale(identifier: "zh-Hans")
            ),
            "期望开启 · 实际状态尚未验证"
        )

        let incompleteOff = SentinelManager.OperationFailure.legacyMigrationFailed(
            requestedEnabled: false
        )
        XCTAssertEqual(
            incompleteOff.localizedTitle(locale: Locale(identifier: "en")),
            "Historical Sentinel Status Not Verified"
        )
        XCTAssertTrue(
            incompleteOff.localizedBody(
                locale: Locale(identifier: "en")
            ).contains("current login agent is off")
        )
        XCTAssertTrue(
            incompleteOff.localizedBody(
                locale: Locale(identifier: "zh-Hans")
            ).contains("当前登录代理已关闭")
        )

        let blockedEnable = SentinelManager.OperationFailure.legacyMigrationFailed(
            requestedEnabled: true
        )
        XCTAssertTrue(
            blockedEnable.localizedBody(
                locale: Locale(identifier: "en"),
                trigger: .startup
            ).contains("previously chose to enable")
        )

        let safetyShutdown = SentinelManager.OperationFailure
            .legacyMigrationSafetyShutdownFailed
        XCTAssertEqual(
            safetyShutdown.localizedTitle(locale: Locale(identifier: "zh-Hans")),
            "Sentinel 安全停机尚未验证"
        )
        XCTAssertTrue(
            safetyShutdown.localizedBody(
                locale: Locale(identifier: "en")
            ).contains("Neither the current login agent")
        )
        XCTAssertTrue(
            safetyShutdown.localizedBody(
                locale: Locale(identifier: "en"),
                trigger: .startup
            ).contains("neither the current login agent")
        )
    }

    // MARK: - Status 枚举映射

    func test_Status_init_全量映射SMAppService_Status() {
        XCTAssertEqual(SentinelManager.Status(.notRegistered),    .notRegistered)
        XCTAssertEqual(SentinelManager.Status(.enabled),          .enabled)
        XCTAssertEqual(SentinelManager.Status(.requiresApproval), .requiresApproval)
        XCTAssertEqual(SentinelManager.Status(.notFound),         .notFound)
    }

    func test_Status_displayLabel_必有非空中文文案() {
        // 任何 case 的 displayLabel 都不应为空，且必须包含中文
        // （UI 直接展示，不能漏文案）。
        let cases: [SentinelManager.Status] = [
            .notRegistered, .enabled, .requiresApproval, .notFound, .unknown(99)
        ]
        for s in cases {
            XCTAssertFalse(s.displayLabel.isEmpty, "\(s) displayLabel 不能空")
        }
        // 产品契约：`displayLabel` 走 xcstrings，SwiftPM XCTest 进程默认
        // 不加载包本地化 lproj → 拿到的是 raw key。此处只锁契约稳定：
        //   1. notRegistered / enabled / requiresApproval / notFound
        //      各自返回一个稳定非空字符串（前几行 assertFalse isEmpty 已覆盖）
        //   2. unknown(raw) 必须把 raw 值带出来方便诊断
        // 具体本地化字面量校验交给 [I18nIntegrityTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/I18nIntegrityTests.swift)；
        // 系统服务真实状态只能在一次持续运行、明确观察的 C4 中验收。
        XCTAssertTrue(SentinelManager.Status.unknown(42).displayLabel.contains("42"),
                      "unknown 必须把 raw 值带出来方便诊断")
    }

    func test_Status_unknown_不同raw值不相等() {
        XCTAssertNotEqual(SentinelManager.Status.unknown(1), SentinelManager.Status.unknown(2))
        XCTAssertEqual(SentinelManager.Status.unknown(7),    SentinelManager.Status.unknown(7))
    }

    // MARK: - 常量契约

    func test_当前Agent与两代旧Daemon迁移描述符必须使用三个独立身份() {
        // v2026.07.18 P1：品牌前后两代 root Label 必须各有文件名对应的迁移 descriptor；
        // 新 Agent 再使用第三个 identity，不能靠改写同一个 plist 的 Label 猜测旧注册已注销。
        XCTAssertEqual(
            SentinelManager.agentPlistName,
            "com.amux.ai.Clean.sentinel.agent.plist"
        )
        XCTAssertEqual(
            SentinelManager.originalBrandLegacyDaemonPlistName,
            "com.guoshuyu.cleanmac.sentinel.plist"
        )
        XCTAssertEqual(
            SentinelManager.renamedBrandLegacyDaemonPlistName,
            "com.amux.ai.Clean.sentinel.plist"
        )
        XCTAssertEqual(
            SentinelManager.legacyDaemonDescriptors,
            [
                .init(
                    plistName: "com.guoshuyu.cleanmac.sentinel.plist",
                    label: "com.guoshuyu.cleanmac.sentinel"
                ),
                .init(
                    plistName: "com.amux.ai.Clean.sentinel.plist",
                    label: "com.amux.ai.Clean.sentinel"
                ),
            ]
        )
        XCTAssertEqual(
            Set(
                [SentinelManager.agentPlistName]
                    + SentinelManager.legacyDaemonDescriptors.map(\.plistName)
            ).count,
            3
        )
    }

    // MARK: - currentStatus 烟测（不触发 register）

    @MainActor
    func test_currentStatus_测试bundle下应返回一个稳定值_不崩溃() {
        let suite = "GSYCleanMac.tests.SentinelManager.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(testSuite: suite)
        let mgr = SentinelManager(settings: settings)
        // 测试 bundle 下一般会拿到 .notRegistered（plist 未在系统数据库中）
        // 或 .notFound——任何具体值都行，只要不崩。这条用例核心是验证
        // SMAppService.agent(plistName:) + service.status 在测试环境下能稳定读取。
        let status = mgr.currentStatus()
        switch status {
        case .notRegistered, .enabled, .requiresApproval, .notFound, .unknown:
            break // 全部合法
        }
    }

    // MARK: - 与 AppSettings 的耦合契约

    @MainActor
    func test_默认设置下sentinelEnabled应为false_守住默认OFF契约() {
        // v1.6 关键守护：升级到带 Sentinel 的版本，存量用户必须默认 OFF，
        // 否则就会在毫无感知下多了个后台守护。
        let suite = "GSYCleanMac.tests.SentinelManager.default.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(testSuite: suite)
        XCTAssertFalse(settings.sentinelEnabled, "Sentinel 默认必须 OFF")
        XCTAssertNil(settings.sentinelLastEnabled, "未启用时不应有时间戳")
        XCTAssertFalse(
            settings.sentinelRequiresShutdownVerification,
            "fresh/default-OFF 不能凭空生成历史 authority 证据"
        )
    }

    @MainActor
    func test_lastEnabled清空后必须持久化_不残留旧时间戳() {
        // v2026.07.16：真正的 disable 状态转移已由上面的 StubService 用例覆盖：只有
        // 权威状态确认未注册才清时间戳，失败会保留。这里单独锁定 AppSettings 的 nil
        // 持久化语义，避免下次启动重新读出 stale Date。
        let suite = "GSYCleanMac.tests.SentinelManager.disable.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(testSuite: suite)
        let earlier = Date(timeIntervalSince1970: 1_780_000_000)
        settings.sentinelLastEnabled = earlier
        XCTAssertEqual(settings.sentinelLastEnabled, earlier)

        // 不触发真实 SMAppService，只验证 `sentinelLastEnabled = nil` 的存储合同。
        settings.sentinelLastEnabled = nil
        XCTAssertNil(settings.sentinelLastEnabled, "= nil 后必须立即体现为 nil")

        // 重启 AppSettings 验证持久化端没有残留 stale Date
        let reloaded = AppSettings(testSuite: suite)
        XCTAssertNil(reloaded.sentinelLastEnabled, "重启后 sentinelLastEnabled 不应残留")
    }

    /// v2026.07.16 App 接线合同：兼容 change 边界不得直接调用 `.user` reconcile；
    /// old/new 必须先交给 SentinelManager 的 typed source boundary。启动对账保留独立入口。
    func test_AppSentinelOnChange_只通过typed事件来源边界() throws {
        let root = try repoRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/GSYCleanMacApp.swift"),
            encoding: .utf8
        )
        guard let start = source.range(
                of: ".onValueChange(of: settings.sentinelEnabled) { oldValue, newValue in"
              ),
              let end = source.range(
                of: ".onValueChange(of: settings.preferredLanguage)",
                range: start.lowerBound..<source.endIndex
              ) else {
            return XCTFail("找不到 Sentinel setting 的 App change 接线")
        }
        let handler = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(handler.contains("oldValue, newValue"))
        XCTAssertTrue(handler.contains("sentinelManager.handleObservedToggleChange("))
        XCTAssertTrue(handler.contains("from: oldValue"))
        XCTAssertTrue(handler.contains("to: newValue"))
        XCTAssertFalse(handler.contains("reconcile(trigger: .user)"))
        XCTAssertFalse(handler.contains("reconcileSentinel"))
        XCTAssertTrue(source.contains("private func reconcileSentinelAtStartup()"))
        XCTAssertTrue(source.contains("sentinelManager.reconcile(trigger: .startup)"))
    }

    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".git").path
            ) {
                return url
            }
        }
        throw NSError(
            domain: "SentinelManagerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "找不到 .git 仓库根"]
        )
    }
}
