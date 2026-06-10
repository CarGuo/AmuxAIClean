import XCTest
@testable import SafetyKit

final class BundleProtectionTests: XCTestCase {

    // MARK: - JSON 数据完整性契约

    /// 数据资产能从 bundle 正常加载，schema 不漂移。
    func testProtectedBundlesJSONLoads() throws {
        let matcher = try BundleProtectionMatcher.loadFromBundle()
        XCTAssertNil(matcher.loadError, "loadError should be nil after successful load")
        XCTAssertEqual(matcher.data.version, 1)
        XCTAssertEqual(matcher.data.source, "tw93/Mole@app_protection_data.sh")
        XCTAssertFalse(matcher.data.updatedAt.isEmpty)
    }

    /// 三类规则数量都应远大于零（防止误删除数据资产）。
    func testProtectedBundlesHasMinimumRules() throws {
        let m = try BundleProtectionMatcher.loadFromBundle()
        XCTAssertGreaterThanOrEqual(m.data.systemCritical.count, 50,
                                    "system_critical 规则太少，可能误删数据资产")
        XCTAssertGreaterThanOrEqual(m.data.dataProtected.count, 200,
                                    "data_protected 规则太少，可能误删数据资产")
        XCTAssertGreaterThanOrEqual(m.data.officialUninstallerRequired.count, 4,
                                    "MDM 厂商列表缺失")
    }

    /// 三类规则内部无重复（避免维护漂移）。
    func testProtectedBundlesNoDuplicates() throws {
        let m = try BundleProtectionMatcher.loadFromBundle()
        XCTAssertEqual(Set(m.data.systemCritical).count, m.data.systemCritical.count,
                       "system_critical 有重复条目")
        XCTAssertEqual(Set(m.data.dataProtected).count, m.data.dataProtected.count,
                       "data_protected 有重复条目")
    }

    // MARK: - 精确匹配

    func testExactSystemCritical_finderForbidden() {
        let match = BundleProtection.match(bundleID: "com.apple.finder")
        XCTAssertEqual(match?.kind, .systemCritical)
        XCTAssertEqual(match?.pattern, "com.apple.finder")
    }

    func testExactSystemCritical_dockForbidden() {
        let match = BundleProtection.match(bundleID: "com.apple.dock")
        XCTAssertEqual(match?.kind, .systemCritical)
    }

    func testExactDataProtected_wechat() {
        let match = BundleProtection.match(bundleID: "com.tencent.xinWeChat")
        XCTAssertEqual(match?.kind, .dataProtected)
        XCTAssertEqual(match?.pattern, "com.tencent.xinWeChat")
    }

    // MARK: - 前缀通配（末尾 *）

    func testPrefixWildcard_1passwordVariants() {
        let m1 = BundleProtection.match(bundleID: "com.1password.7")
        XCTAssertEqual(m1?.kind, .dataProtected)
        XCTAssertEqual(m1?.pattern, "com.1password.*")

        let m2 = BundleProtection.match(bundleID: "com.1password.macos")
        XCTAssertEqual(m2?.kind, .dataProtected)
    }

    func testPrefixWildcard_jetbrainsAllIDEs() {
        for id in ["com.jetbrains.intellij", "com.jetbrains.goland",
                   "com.jetbrains.pycharm", "com.jetbrains.WebStorm"] {
            let m = BundleProtection.match(bundleID: id)
            XCTAssertEqual(m?.kind, .dataProtected, "expected JetBrains protected: \(id)")
        }
    }

    func testPrefixWildcard_settingsApp() {
        let m = BundleProtection.match(bundleID: "com.apple.Settings.PrivacySecurity")
        XCTAssertEqual(m?.kind, .systemCritical)
        XCTAssertEqual(m?.pattern, "com.apple.Settings*")
    }

    // MARK: - 含中段通配（*foo* / *foo）

    func testContainsWildcard_dropbox() {
        let m = BundleProtection.match(bundleID: "com.acme.MyDropboxHelper")
        XCTAssertEqual(m?.kind, .dataProtected, "*dropbox* 应命中 contains 桶")
    }

    func testContainsWildcard_wireguard() {
        let m = BundleProtection.match(bundleID: "tunnel.WireGuard")
        XCTAssertEqual(m?.kind, .dataProtected, "*WireGuard* 应命中")
    }

    // MARK: - 否定 case（未命中保持 nil，永不误升级）

    func testUnknownBundleReturnsNil() {
        XCTAssertNil(BundleProtection.match(bundleID: "com.example.totally.unknown.app"))
    }

    func testEmptyBundleReturnsNil() {
        XCTAssertNil(BundleProtection.match(bundleID: ""))
    }

    // MARK: - 优先级（systemCritical > dataProtected > appleUninstallable）

    /// Xcode 同时落在 dataProtected (`com.apple.dt.Xcode`) 和
    /// apple_uninstallable (`com.apple.dt.*`)。
    /// 期望命中 dataProtected（用户数据保护优先于"可卸载"标记）。
    func testXcodeFallsIntoDataProtectedNotAppleUninstallable() {
        let m = BundleProtection.match(bundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(m?.kind, .dataProtected,
                       "Xcode 应被 data_protected 拦下，apple_uninstallable 仅供 uninstall 流程绕道用")
    }

    // MARK: - Glob 实现单元测试（防止特殊字符 regex 注入）

    func testGlobMatch_handlesDotsInBundleID() {
        XCTAssertTrue(BundleProtectionMatcher.globMatch(pattern: "*dropbox*",
                                                       candidate: "com.dropbox.app"))
        XCTAssertTrue(BundleProtectionMatcher.globMatch(pattern: "*.inputmethod",
                                                       candidate: "com.foo.inputmethod"))
        XCTAssertFalse(BundleProtectionMatcher.globMatch(pattern: "*.inputmethod",
                                                        candidate: "com.foo.inputmethodX"))
    }

    func testGlobMatch_caseInsensitive() {
        XCTAssertTrue(BundleProtectionMatcher.globMatch(pattern: "*ClashX*",
                                                       candidate: "com.acme.clashx.helper"))
    }

    // MARK: - SafetyEngine 集成（M1-T4）

    private let engine = SafetyEngine()
    private let fakeHome = "/Users/testuser"

    /// dataProtected app 的 Caches 路径：原本是 .safe，bundle 接入后升级为 .confirm。
    func testEngineUpgradesSafeToConfirmForProtectedApp() {
        let path = "\(fakeHome)/Library/Caches/com.1password.7/Logs/foo.log"
        let (verdict, rejection) = engine.evaluate(path: path, home: fakeHome)
        XCTAssertEqual(verdict, .confirm)
        XCTAssertEqual(rejection, .bundleDataProtected)
    }

    /// dataProtected app 的 Preferences plist：confirm 默认出口前被 bundle 兜底命中。
    func testEnginePreferencesPlistConfirm() {
        let path = "\(fakeHome)/Library/Preferences/com.jetbrains.intellij.plist"
        let (verdict, rejection) = engine.evaluate(path: path, home: fakeHome)
        XCTAssertEqual(verdict, .confirm)
        XCTAssertEqual(rejection, .bundleDataProtected)
    }

    /// dataProtected app 的 Containers：confirm + bundleDataProtected。
    func testEngineContainersConfirm() {
        let path = "\(fakeHome)/Library/Containers/com.tencent.xinWeChat/Data/file.dat"
        let (verdict, rejection) = engine.evaluate(path: path, home: fakeHome)
        XCTAssertEqual(verdict, .confirm)
        XCTAssertEqual(rejection, .bundleDataProtected)
    }

    /// systemCritical app：升级到 .confirm + bundleSystemCritical。
    /// **设计取舍**：不再强 forbid（详见 SafetyEngine §9 注释）。
    /// 真正"绝对禁删"的系统区由 hardForbidPrefixes 完全拦截；
    /// `~/Library/Containers/com.apple.*` 是用户数据容器，应允许用户在 confirm 后清理。
    func testEngineSystemCriticalUpgradeToConfirm() {
        let path = "\(fakeHome)/Library/Containers/com.apple.dock/Data/foo"
        let (verdict, rejection) = engine.evaluate(path: path, home: fakeHome)
        XCTAssertEqual(verdict, .confirm)
        XCTAssertEqual(rejection, .bundleSystemCritical)
    }

    /// 真正的硬禁区（/System 下）仍 forbid。
    func testEngineSystemDirStillForbidden() {
        let (verdict, rejection) = engine.evaluate(path: "/System/Library/CoreServices/Dock.app",
                                                   home: fakeHome)
        XCTAssertEqual(verdict, .forbid)
        XCTAssertEqual(rejection, .hardForbidPrefix)
    }

    // MARK: - 不破坏现有红线（非破坏性回归）

    /// `/System/x` 必须仍 forbid + hardForbidPrefix（不被 bundle 规则降级）。
    func testEngineHardForbidNotOverridden() {
        let (verdict, rejection) = engine.evaluate(path: "/System/Library/Foo", home: fakeHome)
        XCTAssertEqual(verdict, .forbid)
        XCTAssertEqual(rejection, .hardForbidPrefix)
    }

    /// 普通缓存路径（无 bundle 命中）：仍走 safe。
    func testEngineUnknownCacheStillSafe() {
        let path = "\(fakeHome)/Library/Caches/com.example.unknown.app/temp.db"
        let (verdict, rejection) = engine.evaluate(path: path, home: fakeHome)
        XCTAssertEqual(verdict, .safe, "未命中 bundle 保护的缓存必须保持 safe")
        XCTAssertEqual(rejection, .ok)
    }

    /// 非 ~/Library 路径不应触发 bundle 解析（避免误升级）。
    func testEngineNonLibraryPathNotAffected() {
        let path = "\(fakeHome)/Desktop/MyFile.txt"
        // Desktop 根本身被 userDocumentsRoot 守住，子文件走 confirm 默认。
        let (verdict, rejection) = engine.evaluate(path: path, home: fakeHome)
        XCTAssertEqual(verdict, .confirm)
        XCTAssertEqual(rejection, .ok, "Desktop 子文件不应被 bundle 规则升级到其他 rejection")
    }
}
