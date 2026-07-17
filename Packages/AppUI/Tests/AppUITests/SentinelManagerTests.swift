import XCTest
import ServiceManagement
@testable import AppUI

/// Step 6.5：[SentinelManager](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SentinelManager.swift)
/// 可单测部分（不触发 NSAlert 模态、不真实 register/unregister）。
///
/// **能测什么**：
/// - `Status` 枚举对 `SMAppService.Status` 的全量映射 + `displayLabel` 文案契约
/// - `plistName` 常量与
///   [App/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist](file:///Users/guoshuyu/workspace/GSYCleanMac/App/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist) 文件名一致
/// - `currentStatus()` 在测试 bundle（未签名）下能稳定读到一个非崩溃值
///
/// **不能测什么**：
/// - `enable()` / `disable()` —— 调 `SMAppService.daemon().register()` 在 SwiftPM
///   test bundle（无 .app wrapper / 无 LaunchDaemons embed）下必抛错，
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
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(status: SentinelManager.Status) {
            self.status = status
        }

        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
            if let statusAfterRegister { status = statusAfterRegister }
        }

        func unregister() throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
            if let statusAfterUnregister { status = statusAfterUnregister }
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

    func test_enablePolicyRegistersOnlyWhenServiceIsNotRegistered() {
        // v2026.07.16：锁定 SMAppService 幂等边界；重复 register 是已知系统错误来源。
        XCTAssertEqual(SentinelManager.enableAction(for: .enabled), .alreadyEnabled)
        XCTAssertEqual(SentinelManager.enableAction(for: .notRegistered), .register)
        XCTAssertEqual(SentinelManager.enableAction(for: .requiresApproval), .requestApproval)
        XCTAssertEqual(SentinelManager.enableAction(for: .notFound), .unavailable)
        XCTAssertEqual(SentinelManager.enableAction(for: .unknown(99)), .unavailable)
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
        var presented: [SentinelManager.OperationFailure] = []
        let manager = SentinelManager(
            settings: settings,
            service: service,
            failurePresenter: { failure, _, _ in presented.append(failure) }
        )

        settings.sentinelEnabled = false
        let result = manager.reconcile(trigger: .user)

        XCTAssertEqual(service.unregisterCalls, 1)
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
    }

    func test_typedFailure与unverified状态_中英文实时投影() {
        let failure = SentinelManager.OperationFailure.unregistrationFailed
        XCTAssertEqual(failure.localizedTitle(locale: Locale(identifier: "en")), "Disable Failed")
        XCTAssertEqual(failure.localizedTitle(locale: Locale(identifier: "zh-Hans")), "关闭失败")
        XCTAssertTrue(failure.localizedBody(
            locale: Locale(identifier: "en"),
            logHint: "/tmp/app.log"
        ).contains("switch was restored"))
        XCTAssertTrue(failure.localizedBody(
            locale: Locale(identifier: "zh-Hans"),
            logHint: "/tmp/app.log"
        ).contains("开关已恢复"))
        XCTAssertTrue(failure.localizedBody(
            locale: Locale(identifier: "en"),
            logHint: "/tmp/app.log",
            trigger: .startup
        ).contains("saved request"))
        XCTAssertFalse(failure.localizedBody(
            locale: Locale(identifier: "zh-Hans"),
            logHint: "/tmp/app.log",
            trigger: .startup
        ).contains("开关已恢复"), "启动对账保留持久化期望，文案不能谎称恢复了交互开关")
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

    func test_plistName_必须与App内嵌LaunchDaemons目录文件名一致() {
        // v2026.07.16：除文件名契约外，本测试故意保持 nonisolated，锁定该不可变
        // 常量能被 ServiceManagement 适配器跨 actor 安全读取，防止再次阻断 Swift 6 编译。
        // 文件名一旦破坏，SMAppService.daemon(plistName:) 会拿到 .notFound。
        XCTAssertEqual(SentinelManager.plistName, "com.guoshuyu.cleanmac.sentinel.plist")
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
        // SMAppService.daemon(plistName:) + service.status 在沙箱外环境下能稳定读取。
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
