import XCTest
@testable import SafetyKit

final class SafetyEngineTests: XCTestCase {
    let engine = SafetyEngine()

    // MARK: - 黑名单

    func testSystemPathsAreForbidden() {
        XCTAssertEqual(engine.evaluate(path: "/System/Library/Frameworks/Foo").0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/usr/libexec/cups").0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/private/var/db/uuidtext").0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/Applications/Safari.app").0, .forbid)
    }

    // MARK: - 根目录保护

    func testRootIsForbidden() {
        XCTAssertEqual(engine.evaluate(path: "/").1, .rootOrAboveHome)
    }

    func testHomeRootIsForbidden() {
        XCTAssertEqual(engine.evaluate(path: "/Users/foo", home: "/Users/foo").1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Documents", home: "/Users/foo").1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Desktop", home: "/Users/foo").1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Library", home: "/Users/foo").1, .userDocumentsRoot)
    }

    func testHomeSubpathsAreConfirm() {
        // 子节点是允许"考虑删"的（confirm，不是 safe，也不是 forbid）
        let v = engine.evaluate(path: "/Users/foo/Documents/old.zip", home: "/Users/foo")
        XCTAssertEqual(v.0, .confirm)
    }

    // MARK: - 路径攻击

    func testRelativePathRejected() {
        XCTAssertEqual(engine.evaluate(path: "tmp/foo").1, .relativePath)
    }

    func testDotDotInPathRejected() {
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/../etc/passwd").1, .dotDotInPath)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/..").1, .dotDotInPath)
    }

    func testSystemVolumeRejected() {
        XCTAssertEqual(engine.evaluate(path: "/System/Volumes/Preboot/something").1, .hardForbidPrefix)
        // /System/Volumes/Data/Users/... 是数据卷穿透 → 命中 safeCachePrefixes 升级到 .safe
        let v = engine.evaluate(path: "/System/Volumes/Data/Users/foo/Library/Caches/x", home: "/Users/foo")
        XCTAssertEqual(v.0, .safe)
    }

    // MARK: - 缓存（允许处理）

    func testUserCachesAreSafe() {
        // ~/Library/Caches/* 是已知的清理友好路径，升级到 .safe（UI 默认勾选）
        let v = engine.evaluate(path: "/Users/foo/Library/Caches/com.apple.Safari", home: "/Users/foo")
        XCTAssertEqual(v.0, .safe)
    }

    func testSafeCacheSymlinkToApplicationsIsForbidden() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafetySymlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent("foo", isDirectory: true)
        let caches = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("apps-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Applications"))

        let v = engine.evaluate(path: link.appendingPathComponent("Safari.app").path,
                                home: home.path)
        XCTAssertEqual(v.0, .forbid)
        XCTAssertEqual(v.1, .hardForbidPrefix)
    }

    func testXcodeDerivedDataIsSafe() {
        let v = engine.evaluate(
            path: "/Users/foo/Library/Developer/Xcode/DerivedData/MyApp-abc",
            home: "/Users/foo"
        )
        XCTAssertEqual(v.0, .safe)
    }

    func testHomeDocumentsItemsAreConfirm() {
        // 见 testHomeSubpathsAreConfirm；这里再覆盖一次明确的语义
        let v = engine.evaluate(path: "/Users/foo/Documents/x.pdf", home: "/Users/foo")
        XCTAssertEqual(v.0, .confirm)
    }

    // MARK: - isForbidden 包装

    func testIsForbiddenWrapper() {
        XCTAssertTrue(engine.isForbidden(path: "/System/Library", home: "/Users/foo"))
        XCTAssertFalse(engine.isForbidden(path: "/Users/foo/Library/Caches/x", home: "/Users/foo"))
    }

    // MARK: - 黄金禁区契约（DEV_ARTIFACTS_RULES §2.7）

    /// 敏感凭证目录及其子节点都必须 forbid + `.sensitiveCredential`。
    /// 只要这条测试通过，开发者产物清理规则放开后就不可能误删凭证。
    func testGoldenZoneSensitiveCredentialsForbidden() {
        let home = "/Users/foo"
        let cases: [String] = [
            // SSH / GPG / Cloud
            "\(home)/.ssh",
            "\(home)/.ssh/id_rsa",
            "\(home)/.ssh/known_hosts",
            "\(home)/.gnupg",
            "\(home)/.gnupg/private-keys-v1.d/abc.key",
            "\(home)/.aws",
            "\(home)/.aws/credentials",
            "\(home)/.config/gh",
            "\(home)/.config/gh/hosts.yml",
            "\(home)/.netrc",
            "\(home)/.npmrc",
            "\(home)/.yarnrc",
            "\(home)/.yarnrc.yml",
            "\(home)/.pypirc",
            "\(home)/.gitconfig",
            "\(home)/.git-credentials",
            // Apple keychain / TCC / provisioning
            "\(home)/Library/Keychains",
            "\(home)/Library/Keychains/login.keychain-db",
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/MobileDevice/Provisioning Profiles",
            "\(home)/Library/MobileDevice/Provisioning Profiles/abc.mobileprovision",
            // Android 签名
            "\(home)/.android/debug.keystore",
            "\(home)/.android/adbkey",
            "\(home)/.android/adbkey.pub",
            // 包管理器全局配置
            "\(home)/.gradle/init.d",
            "\(home)/.gradle/init.d/repos.gradle",
            "\(home)/.gradle/gradle.properties",
            "\(home)/.cargo/config",
            "\(home)/.cargo/config.toml",
            "\(home)/.cargo/credentials",
            "\(home)/.cargo/credentials.toml",
            "\(home)/.m2/settings.xml",
            "\(home)/.m2/settings-security.xml",
            "\(home)/.kube/config",
            // SwiftPM 私有 keychain（关键：在 ~/Library/ 下，必须不能被 safeCache 升级）
            "\(home)/Library/org.swift.swiftpm/security",
            "\(home)/Library/org.swift.swiftpm/security/mirrors.json"
        ]
        for path in cases {
            let v = engine.evaluate(path: path, home: home)
            XCTAssertEqual(v.0, .forbid, "expected forbid for \(path), got \(v)")
            XCTAssertEqual(v.1, .sensitiveCredential,
                           "expected .sensitiveCredential for \(path), got \(v.1)")
        }
    }

    /// 文件名后缀禁区：签名容器与 provisioning。
    func testGoldenZoneSuffixForbidden() {
        let home = "/Users/foo"
        let cases: [String] = [
            // 项目目录里的签名材料（即使位置任意）
            "\(home)/Documents/Workspace/MyApp/release.jks",
            "\(home)/Documents/Workspace/MyApp/keystore.keystore",
            "\(home)/Downloads/distribution.p12",
            "\(home)/Downloads/code-sign.pfx",
            "\(home)/Library/MobileDevice/Provisioning Profiles/abc.mobileprovision",
            "\(home)/Documents/Profiles/dev.provisionprofile"
        ]
        for path in cases {
            let v = engine.evaluate(path: path, home: home)
            XCTAssertEqual(v.0, .forbid, "expected forbid for \(path), got \(v)")
            XCTAssertEqual(v.1, .sensitiveCredential,
                           "expected .sensitiveCredential for \(path), got \(v.1)")
        }
    }

    /// `.git` 路径段禁区：任何深度的 .git 目录都不允许被引擎放行。
    func testGoldenZoneGitSegmentForbidden() {
        let home = "/Users/foo"
        let cases: [String] = [
            "\(home)/Documents/Workspace/MyApp/.git",
            "\(home)/Documents/Workspace/MyApp/.git/HEAD",
            "\(home)/Documents/Workspace/MyApp/.git/objects/pack/pack-1.idx",
            "\(home)/Workspace/sub/dir/.git/refs/heads/main",
            // 即使夹在 confirm 类目下也要拦
            "\(home)/Downloads/some-clone/.git"
        ]
        for path in cases {
            let v = engine.evaluate(path: path, home: home)
            XCTAssertEqual(v.0, .forbid, "expected forbid for \(path), got \(v)")
            XCTAssertEqual(v.1, .sensitiveCredential,
                           "expected .sensitiveCredential for \(path), got \(v.1)")
        }
    }

    /// 边界：与禁区"形似"的合法路径不应被误伤。
    func testGoldenZoneNegativeCases() {
        let home = "/Users/foo"
        // .gitignore 不是 .git 段
        let v1 = engine.evaluate(
            path: "\(home)/Documents/Workspace/MyApp/.gitignore",
            home: home
        )
        XCTAssertEqual(v1.0, .confirm, "(.gitignore 不应命中 .git 段) got \(v1)")

        // .sshfoo 不是 .ssh 前缀（必须严格 == 或 + "/"）
        let v2 = engine.evaluate(path: "\(home)/.sshfoo/data", home: home)
        XCTAssertEqual(v2.0, .confirm, "(.sshfoo 不应命中 .ssh) got \(v2)")

        // 普通的 .properties 不是 gradle.properties
        let v3 = engine.evaluate(path: "\(home)/.gradle/caches/x.properties", home: home)
        XCTAssertEqual(v3.0, .confirm, "(普通 properties 不应命中 gradle.properties) got \(v3)")

        // ~/.cargo/registry 是缓存，不是 ~/.cargo/config
        let v4 = engine.evaluate(path: "\(home)/.cargo/registry/cache/abc", home: home)
        XCTAssertEqual(v4.0, .confirm, "(.cargo/registry 不应命中 .cargo/config) got \(v4)")
    }

    /// 路径子串硬安全网（review 中危 #4）：任何 Code-OSS 衍生编辑器的 globalStorage
    /// 都必须 forbid + `.sensitiveCredential`，无需依赖 vendors.yaml 列举。
    func testGoldenZoneGlobalStorageSubstringForbidden() {
        let home = "/Users/foo"
        let cases: [String] = [
            // 已知 vendor（与 yaml 重叠）
            "\(home)/Library/Application Support/Code/User/globalStorage",
            "\(home)/Library/Application Support/Code/User/globalStorage/github.copilot",
            "\(home)/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor",
            "\(home)/Library/Application Support/Trae/User/globalStorage/secret.json",
            // yaml 未列举的衍生编辑器（Windsurf / Cody）—— 子串硬安全网必须兜底
            "\(home)/Library/Application Support/Windsurf/User/globalStorage/token.json",
            "\(home)/Library/Application Support/Cody/User/globalStorage/session.db"
        ]
        for path in cases {
            let v = engine.evaluate(path: path, home: home)
            XCTAssertEqual(v.0, .forbid, "expected forbid for \(path), got \(v)")
            XCTAssertEqual(v.1, .sensitiveCredential,
                           "expected .sensitiveCredential for \(path), got \(v.1)")
        }
    }

    /// 路径子串硬安全网（review 中危 #6）：Flutter / Dart 全局工具二进制目录必须 forbid。
    /// 涵盖：(1) 子目录命中（含尾斜杠 fragment）；(2) 叶节点本身命中（hasSuffix 兜底）。
    func testGoldenZoneDartToolBinSubstringForbidden() {
        let home = "/Users/foo"
        let cases: [String] = [
            // .pub-cache/bin 子文件
            "\(home)/.pub-cache/bin/melos",
            "\(home)/.pub-cache/bin/dart_style",
            // .pub-cache/bin 叶节点本身（无尾斜杠 → hasSuffix 兜底命中）
            "\(home)/.pub-cache/bin",
            // dart-sdk/bin 子文件（手动解压安装路径）
            "\(home)/dev/dart-sdk/bin/dart",
            "\(home)/dev/dart-sdk/bin/dartanalyzer",
            "\(home)/Documents/dart-sdk/bin"
        ]
        for path in cases {
            let v = engine.evaluate(path: path, home: home)
            XCTAssertEqual(v.0, .forbid, "expected forbid for \(path), got \(v)")
            XCTAssertEqual(v.1, .sensitiveCredential,
                           "expected .sensitiveCredential for \(path), got \(v.1)")
        }
    }

    /// 边界：dart-sdk 段名虽强语义但非全局工具，必须配 `/bin/` 才视为禁区。
    func testGoldenZoneDartSdkWithoutBinIsConfirm() {
        let home = "/Users/foo"
        // dart-sdk 文档目录：不带 /bin/，应走 confirm 而非 forbid
        let v1 = engine.evaluate(path: "\(home)/Documents/dart-sdk-docs/api.html", home: home)
        XCTAssertEqual(v1.0, .confirm, "(dart-sdk 文档不应命中 dart-sdk/bin 子串) got \(v1)")

        // dart-sdk/lib 也不是 bin
        let v2 = engine.evaluate(path: "\(home)/dev/dart-sdk/lib/core/core.dart", home: home)
        XCTAssertEqual(v2.0, .confirm, "(dart-sdk/lib 不应被 dart-sdk/bin 子串命中) got \(v2)")
    }

    func testSymlinkInsideSafeVendorPathDoesNotDowngradeTargetToSafe() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("safety-symlink-\(UUID().uuidString)")
        let vendorCacheDir = tempHome.appendingPathComponent("Library/Application Support/Acme/Cache")
        let externalTarget = tempHome.appendingPathComponent("Documents/ImportantDoc.txt")
        try fm.createDirectory(at: vendorCacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("important".utf8).write(to: externalTarget)
        defer { try? fm.removeItem(at: tempHome) }

        let normalFile = vendorCacheDir.appendingPathComponent("normal.tmp")
        try Data("cache".utf8).write(to: normalFile)
        let symlinkFile = vendorCacheDir.appendingPathComponent("linked-doc.txt")
        try fm.createSymbolicLink(at: symlinkFile, withDestinationURL: externalTarget)

        let rule = VendorRule(
            name: "Acme",
            appSupportSubdir: "Acme",
            paths: [
                PathRule(path: "~/Library/Application Support/Acme/Cache", verdict: .safe)
            ]
        )

        let normalEval = engine.evaluate(path: normalFile.path, vendors: [rule], home: tempHome.path)
        XCTAssertEqual(normalEval.0, .safe, "vendor safe 子目录下的普通文件应为 .safe")

        let symlinkEval = engine.evaluate(path: symlinkFile.path, vendors: [rule], home: tempHome.path)
        XCTAssertEqual(symlinkEval.0, .confirm, "指向外部 .confirm 目标的 symlink 不得被 vendor safe 规则降级为 .safe")
    }

    func testSubpathGlobForbidOverridesInheritedParentSafeVendorRule() {
        let home = "/Users/foo"
        let rule = VendorRule(
            name: "Acme Glob",
            appSupportSubdir: "Acme",
            paths: [
                PathRule(path: "~/Library/Application Support/Acme", verdict: .safe),
                PathRule(path: "~/Library/Application Support/Acme/**/secrets/*", verdict: .forbid)
            ]
        )

        let safeChild = engine.evaluate(
            path: "\(home)/Library/Application Support/Acme/workspace/cache.db",
            vendors: [rule],
            home: home
        )
        XCTAssertEqual(safeChild.0, .safe)

        let forbiddenChild = engine.evaluate(
            path: "\(home)/Library/Application Support/Acme/workspace/secrets/token.json",
            vendors: [rule],
            home: home
        )
        XCTAssertEqual(forbiddenChild.0, .forbid, "更具体的子路径 glob forbid 必须优先于父目录继承的 .safe")
        XCTAssertEqual(forbiddenChild.1, .vendorPathRule)

        let zeroDepthForbidden = engine.evaluate(
            path: "\(home)/Library/Application Support/Acme/secrets/token.json",
            vendors: [rule],
            home: home
        )
        XCTAssertEqual(zeroDepthForbidden.0, .forbid, "** 匹配 0 个中间段时也必须命中 forbid")

        let multiDepthForbidden = engine.evaluate(
            path: "\(home)/Library/Application Support/Acme/a/b/c/secrets/token.json",
            vendors: [rule],
            home: home
        )
        XCTAssertEqual(multiDepthForbidden.0, .forbid, "** 匹配多层中间段时也必须命中 forbid")
    }

    func testCaseInsensitiveHardForbidAndCredentialsAndNormalizedHome() {
        let home = "/System/Volumes/Data/Users/foo/"
        XCTAssertEqual(engine.evaluate(path: "/system/Library/Frameworks", home: home).0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/APPLICATIONS/Safari.app", home: home).0, .forbid)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/documents", home: home).1, .userDocumentsRoot)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/.SSH/id_rsa", home: home).1, .sensitiveCredential)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/library/keychains/login.keychain-db", home: home).1, .sensitiveCredential)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/repo/.GIT/config", home: home).1, .sensitiveCredential)
        XCTAssertEqual(engine.evaluate(path: "/Users/foo/Downloads/cert.P12", home: home).1, .sensitiveCredential)
        XCTAssertEqual(engine.evaluate(path: "/system/volumes/data/Users/foo/.ssh/id_ed25519", home: home).1, .sensitiveCredential)
        let bundleRes = engine.evaluate(path: "/Users/foo/library/caches/COM.1PASSWORD.7/log.txt", home: home)
        XCTAssertEqual(bundleRes.0, .confirm)
        XCTAssertEqual(bundleRes.1, .bundleDataProtected)
    }

    func testSymlinkCanonicalVendorForbidAndResolvedVendorRootConfirmAndBundleRejectionPreserved() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("safety-trie-\(UUID().uuidString)")
        let cachesAcme = tempHome.appendingPathComponent("Library/Caches/Acme")
        let docsDir = tempHome.appendingPathComponent("Documents")
        let vendorRootInCaches = tempHome.appendingPathComponent("Library/Caches/ProtectedVendorRoot")
        try fm.createDirectory(at: cachesAcme, withIntermediateDirectories: true)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: vendorRootInCaches, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let docTarget = docsDir.appendingPathComponent("note.txt")
        try Data("doc".utf8).write(to: docTarget)
        let forbidSymlink = cachesAcme.appendingPathComponent("forbidden-link")
        try fm.createSymbolicLink(at: forbidSymlink, withDestinationURL: docTarget)

        let rootSymlink = cachesAcme.appendingPathComponent("vendor-root-link")
        try fm.createSymbolicLink(at: rootSymlink, withDestinationURL: vendorRootInCaches)

        let rules = [
            VendorRule(
                name: "Acme",
                cachesPath: "~/Library/Caches/ProtectedVendorRoot",
                paths: [
                    PathRule(path: "~/Library/Caches/Acme/forbidden-link", verdict: .forbid)
                ]
            ),
            VendorRule(
                name: "OnePasswordVendor",
                cachesPath: "~/Library/Caches/com.1password.7"
            )
        ]

        // 2A: canonical 路径命中 vendor forbid 时，即便 symlink 目标是 .confirm，也必须返回 .forbid
        let forbidEval = engine.evaluate(path: forbidSymlink.path, vendors: rules, home: tempHome.path)
        XCTAssertEqual(forbidEval.0, .forbid)
        XCTAssertEqual(forbidEval.1, .vendorPathRule)

        // 2B: symlink 指向 vendor 根时，必须保留 .confirm 而不能当成普通 Caches 子项放行 .safe
        let rootLinkEval = engine.evaluate(path: rootSymlink.path, vendors: rules, home: tempHome.path)
        XCTAssertEqual(rootLinkEval.0, .confirm)
        XCTAssertEqual(rootLinkEval.2?.name, "Acme")

        // 2C: 命中受保护 bundle 的路径叠加 vendor 根 confirm 时，不得丢失 .bundleDataProtected
        let bundleVendorEval = engine.evaluate(
            path: "\(tempHome.path)/Library/Caches/com.1password.7",
            vendors: rules,
            home: tempHome.path
        )
        XCTAssertEqual(bundleVendorEval.0, .confirm)
        XCTAssertEqual(bundleVendorEval.1, .bundleDataProtected)
    }
}

