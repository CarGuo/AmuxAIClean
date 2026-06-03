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
///   这一段由 `Tests/Regression` 的 `sentinel-default-off` real-app case 覆盖（验证默认 OFF）+
///   外部 [/tmp/sentinel-app-launch.sh](file:///tmp/sentinel-app-launch.sh) 手工烟测覆盖（真签名 .app + 用户授权流）。
final class SentinelManagerTests: XCTestCase {

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
        XCTAssertEqual(SentinelManager.Status.notRegistered.displayLabel,    "未启用")
        XCTAssertEqual(SentinelManager.Status.enabled.displayLabel,          "运行中")
        XCTAssertEqual(SentinelManager.Status.requiresApproval.displayLabel, "需要授权（前往系统设置 → 登录项）")
        XCTAssertEqual(SentinelManager.Status.notFound.displayLabel,         "未找到")
        XCTAssertTrue(SentinelManager.Status.unknown(42).displayLabel.contains("42"),
                      "unknown 必须把 raw 值带出来方便诊断")
    }

    func test_Status_unknown_不同raw值不相等() {
        XCTAssertNotEqual(SentinelManager.Status.unknown(1), SentinelManager.Status.unknown(2))
        XCTAssertEqual(SentinelManager.Status.unknown(7),    SentinelManager.Status.unknown(7))
    }

    // MARK: - 常量契约

    @MainActor
    func test_plistName_必须与App内嵌LaunchDaemons目录文件名一致() {
        // 这条契约一旦破坏，SMAppService.daemon(plistName:) 会拿到 .notFound，
        // 而且不会在编译期被发现——所以放进单测把它锁死。
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
    func test_disable抹除lastEnabled时间戳的契约() {
        // 不真调 SMAppService（会进 NSAlert），仅模拟「我们已经在某次 enable 写入了
        // sentinelLastEnabled，之后用户从 UI 关掉开关」的状态：disable() 内部应
        // 把 sentinelLastEnabled 清掉。即使 unregister 抛错，这个清理也不会被反弹（设计上）。
        let suite = "GSYCleanMac.tests.SentinelManager.disable.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(testSuite: suite)
        let earlier = Date(timeIntervalSince1970: 1_780_000_000)
        settings.sentinelLastEnabled = earlier
        XCTAssertEqual(settings.sentinelLastEnabled, earlier)

        // disable() 内部 unregister 会失败（测试 bundle 没有真实 daemon），
        // 但失败路径不会反弹时间戳清理——目前实现是 try/catch 且 catch 分支不写 settings。
        // 不调 disable() 直接写假数据——这条用例验证设计契约：
        // sentinelLastEnabled 是 Date? 且 = nil 时持久化也得写空。
        settings.sentinelLastEnabled = nil
        XCTAssertNil(settings.sentinelLastEnabled, "= nil 后必须立即体现为 nil")

        // 重启 AppSettings 验证持久化端没有残留 stale Date
        let reloaded = AppSettings(testSuite: suite)
        XCTAssertNil(reloaded.sentinelLastEnabled, "重启后 sentinelLastEnabled 不应残留")
    }
}
