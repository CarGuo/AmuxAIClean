import XCTest
@testable import SafetyKit

final class BundleProtectionTests: XCTestCase {

    // MARK: - JSON 数据完整性契约

    /// 数据资产能从 bundle 正常加载，schema 不漂移。
    func testProtectedBundlesJSONLoads() throws {
        let matcher = try BundleProtectionMatcher.loadFromBundle()
        XCTAssertNil(matcher.loadError, "loadError should be nil after successful load")
        XCTAssertEqual(matcher.loadState, .loaded)
        XCTAssertTrue(matcher.loadState.hasCompleteEvidence)
        XCTAssertEqual(matcher.data.version, 1)
        XCTAssertEqual(matcher.data.source, "tw93/Mole@app_protection_data.sh")
        XCTAssertFalse(matcher.data.updatedAt.isEmpty)
    }

    /// 加载失败是能力状态，不等价于“规则集合为空且已完整验证”。普通 evaluate 保持
    /// 历史兼容，不扩大成 forbid；destructive override 则能读取状态并 fail closed。
    func testUnavailableMatcherPreservesOrdinaryEvaluationButMarksEvidenceIncomplete() {
        let matcher = BundleProtectionMatcher.unavailable(failure: .resourceMissing)
        let engine = SafetyEngine(bundleProtectionMatcher: matcher)

        XCTAssertEqual(matcher.loadState, .unavailable(.resourceMissing))
        XCTAssertFalse(matcher.loadState.hasCompleteEvidence)
        XCTAssertFalse(engine.hasCompleteBundleProtectionEvidence)
        XCTAssertEqual(engine.bundleProtectionLoadState, .unavailable(.resourceMissing))
        XCTAssertEqual(engine.bundleProtectionEvidence(
            path: "/Users/testuser/Library/Caches/com.example.fixture", home: "/Users/testuser"
        ), .unresolved)

        let result = engine.evaluate(
            path: "/Users/testuser/Library/Caches/com.1password.7/rebuildable.tmp",
            home: "/Users/testuser"
        )
        XCTAssertEqual(result.0, .safe,
                       "资源失败不应把普通扫描结果全局扩大为 forbid")
        XCTAssertEqual(result.1, .ok)
    }

    func testLoadFailuresAreClassifiedWithoutParsingErrorDescriptions() {
        XCTAssertEqual(
            BundleProtectionLoadFailure.classify(BundleProtectionError.resourceMissing),
            .resourceMissing
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BundleProtectionData.self,
                from: Data("{not-json".utf8)
            )
        ) { error in
            XCTAssertEqual(BundleProtectionLoadFailure.classify(error), .invalidResource)
        }
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

    /// v2026.10.09: independent legacy bucket/regex oracle checks the optimized production
    /// matcher against every shipped glob, Unicode folding, escaping and anchoring.
    func testPrecompiledRulesPreserveLegacyGlobSemantics() throws {
        let shipped = try BundleProtectionMatcher.loadFromBundle().data
        let patterns = Set(shipped.systemCritical + shipped.dataProtected + shipped.appleUninstallable)
            .filter { $0.contains("*") }
            + ["*a.+?^$()[]{}|\\b*", "*Kelvin*", "*.終端*", "*a*b*", "*🙂*", "*x*\ny*"]
        for pattern in patterns {
            let data = BundleProtectionData(
                version: 1, source: "test", updatedAt: "", systemCritical: [],
                appleUninstallable: [], dataProtected: [pattern], officialUninstallerRequired: []
            )
            let matcher = BundleProtectionMatcher(data: data)
            XCTAssertEqual(matcher.loadState, .loaded)
            var legacy = "^"
            for character in pattern {
                if character == "*" { legacy += ".*" }
                else {
                    if ".+?^$()[]{}|\\".contains(character) { legacy += "\\" }
                    legacy.append(character)
                }
            }
            legacy += "$"
            let stem = pattern.replacingOccurrences(of: "*", with: "")
            for candidate in [stem, stem.uppercased(), stem.lowercased(), "prefix" + stem,
                              stem + "suffix", stem + "\n", "com.example.unknown", ""] {
                // Existing single trailing-star rules use prefix matching, including
                // newline input. Only middle/leading wildcard rules used String regex search.
                let isPrefix = pattern.hasSuffix("*") && !pattern.dropLast().contains("*")
                let expected = isPrefix
                    ? candidate.lowercased().hasPrefix(stem.lowercased())
                    : candidate.range(of: legacy, options: [.regularExpression, .caseInsensitive]) != nil
                XCTAssertEqual(matcher.match(bundleID: candidate) != nil, expected,
                               "pattern=\(pattern), candidate=\(candidate)")
                if expected { XCTAssertEqual(matcher.match(bundleID: candidate)?.pattern, pattern) }
            }
        }
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

    /// 大小写无关匹配：exact 与 prefix 桶对不同大小写的 bundleID 均能命中并返回原始 pattern。
    func testCaseInsensitiveExactAndPrefixBundleMatching() {
        let matcher = BundleProtection.shared
        let finderMixed = matcher.match(bundleID: "com.apple.Finder")
        XCTAssertEqual(finderMixed?.kind, .systemCritical)
        XCTAssertEqual(finderMixed?.pattern, "com.apple.finder")

        let jetbrainsMixed = matcher.match(bundleID: "com.JetBrains.IntelliJ")
        XCTAssertEqual(jetbrainsMixed?.kind, .dataProtected)
        XCTAssertEqual(jetbrainsMixed?.pattern, "com.jetbrains.*")
    }

    /// `/System/Volumes/Data` firmlink 镜像路径不得绕过用户根目录、凭证禁区或 bundle 保护。
    func testDataVolumeFirmlinkDoesNotBypassUserRootCredentialOrBundleProtection() {
        let dataHome = "/System/Volumes/Data\(fakeHome)"

        let (docVerdict, docRejection) = engine.evaluate(
            path: "\(dataHome)/Documents",
            home: fakeHome
        )
        XCTAssertEqual(docVerdict, .forbid)
        XCTAssertEqual(docRejection, .userDocumentsRoot)

        let (sshVerdict, sshRejection) = engine.evaluate(
            path: "\(dataHome)/.ssh/id_ed25519",
            home: fakeHome
        )
        XCTAssertEqual(sshVerdict, .forbid)
        XCTAssertEqual(sshRejection, .sensitiveCredential)

        let (keychainVerdict, keychainRejection) = engine.evaluate(
            path: "\(dataHome)/Library/Keychains/login.keychain-db",
            home: fakeHome
        )
        XCTAssertEqual(keychainVerdict, .forbid)
        XCTAssertEqual(keychainRejection, .sensitiveCredential)

        let protectedCachePath = "\(dataHome)/Library/Caches/com.1password.7/Logs/foo.log"
        let (cacheVerdict, cacheRejection) = engine.evaluate(
            path: protectedCachePath,
            home: fakeHome
        )
        XCTAssertEqual(cacheVerdict, .confirm)
        XCTAssertEqual(cacheRejection, .bundleDataProtected)
        XCTAssertTrue(engine.isPathBundleProtected(path: protectedCachePath, home: fakeHome))
    }

    /// `.app` 应用包内部成员必须返回 `.forbid` + `.insideAppBundle`，而整包卸载路径保持 `.confirm` + `.ok`。
    func testAppBundleInteriorForbiddenWhileWholeBundleRemainsConfirm() {
        let wholeApp = "\(fakeHome)/Applications/Alpha.app"
        let (wholeVerdict, wholeRejection) = engine.evaluate(path: wholeApp, home: fakeHome)
        XCTAssertEqual(wholeVerdict, .confirm)
        XCTAssertEqual(wholeRejection, .ok)

        let resourcePath = "\(fakeHome)/Applications/Alpha.app/Contents/Resources/shared.bin"
        let (resVerdict, resRejection) = engine.evaluate(path: resourcePath, home: fakeHome)
        XCTAssertEqual(resVerdict, .forbid)
        XCTAssertEqual(resRejection, .insideAppBundle)

        let nestedHelper = "\(fakeHome)/Downloads/Beta.app/Contents/Library/LoginItems/Helper.app"
        let (nestedVerdict, nestedRejection) = engine.evaluate(path: nestedHelper, home: fakeHome)
        XCTAssertEqual(nestedVerdict, .forbid)
        XCTAssertEqual(nestedRejection, .insideAppBundle)

        // Reverse-DNS bundle ID ending with `.app` under ~/Library/Caches must remain `.safe`
        let cacheContainer = "\(fakeHome)/Library/Caches/com.example.unknown.app/temp.db"
        let (cacheVerdict, cacheRejection) = engine.evaluate(path: cacheContainer, home: fakeHome)
        XCTAssertEqual(cacheVerdict, .safe)
        XCTAssertEqual(cacheRejection, .ok)

        // An actual `.app` bundle inside ~/Library/Caches must forbid interior files
        let cacheEmbeddedApp = "\(fakeHome)/Library/Caches/com.example.updater/Update.app/Contents/MacOS/Update"
        let (embVerdict, embRejection) = engine.evaluate(path: cacheEmbeddedApp, home: fakeHome)
        XCTAssertEqual(embVerdict, .forbid)
        XCTAssertEqual(embRejection, .insideAppBundle)
    }

    /// 指向受禁路径的悬空（dangling）符号链接也必须解析其目标并拦截。
    func testDanglingSymlinkToForbiddenTargetIsForbidden() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafetyDangling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let linkURL = tmpRoot.appendingPathComponent("dangling-system-link")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: "/System/Library/NonExistentTarget-\(UUID().uuidString)"
        )

        let (verdict, rejection) = engine.evaluate(path: linkURL.path, home: tmpRoot.path)
        XCTAssertEqual(verdict, .forbid)
        XCTAssertEqual(rejection, .hardForbidPrefix)
    }
}
