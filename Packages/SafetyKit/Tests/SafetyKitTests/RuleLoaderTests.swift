import XCTest
@testable import SafetyKit

final class RuleLoaderTests: XCTestCase {

    func testParseMinimalEntry() throws {
        let yaml = """
        # comment
        vendors:
          - name: "Adobe"
            bundle_id_prefix: "com.adobe"
            app_support_subdir: "Adobe"
            note: "shared"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "Adobe")
        XCTAssertEqual(rules[0].bundleIDPrefix, "com.adobe")
        XCTAssertEqual(rules[0].appSupportSubdir, "Adobe")
        XCTAssertEqual(rules[0].note, "shared")
    }

    func testParseMultipleEntries() throws {
        let yaml = """
        vendors:
          - name: "Slack"
            app_support_subdir: "Slack"
          - name: "Homebrew"
            caches_path: "~/Library/Caches/Homebrew"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].name, "Slack")
        XCTAssertEqual(rules[1].cachesPath, "~/Library/Caches/Homebrew")
    }

    func testIgnoresUnknownKeysForwardCompat() throws {
        let yaml = """
        vendors:
          - name: "X"
            app_support_subdir: "X"
            unknown_future_key: "whatever"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "X")
    }

    func testHardForbidRejectsMaliciousRule() throws {
        let yaml = """
        vendors:
          - name: "Malicious"
            app_support_subdir: "../../../../System/Library"
        """
        let dir = NSTemporaryDirectory() + "RuleLoaderTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/v.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        let rules = try RuleLoader.loadVendors(from: url, home: "/Users/foo")
        XCTAssertTrue(rules.isEmpty, "命中 hardForbid 的恶意规则必须被过滤掉")
    }

    func testVendorRulePrefixesExpandHome() {
        let r = VendorRule(name: "X", appSupportSubdir: "Adobe",
                           cachesPath: "~/Library/Caches/Homebrew")
        let prefixes = r.absolutePathPrefixes(home: "/Users/foo")
        XCTAssertTrue(prefixes.contains("/Users/foo/Library/Application Support/Adobe"))
        XCTAssertTrue(prefixes.contains("/Users/foo/Library/Caches/Homebrew"))
    }

    func testEvaluateWithVendorDowngradesSafeRoot() {
        let engine = SafetyEngine()
        let rule = VendorRule(name: "Adobe", appSupportSubdir: "Adobe")
        // 这里造一个 ~/Library/Caches/Adobe 的"根"，本来是 safe
        let path = "/Users/foo/Library/Application Support/Adobe"
        let (verdict, _, hit) = engine.evaluate(path: path, vendors: [rule], home: "/Users/foo")
        XCTAssertEqual(verdict, .confirm, "vendor 根目录必须降级到 confirm")
        XCTAssertEqual(hit?.name, "Adobe")
    }

    func testEvaluateVendorSubpathKeepsSafe() {
        let engine = SafetyEngine()
        let rule = VendorRule(name: "Some", cachesPath: "~/Library/Caches/Homebrew")
        // /Users/foo/Library/Caches/Homebrew/abc 既被 safeCachePrefixes 命中（safe），
        // 也是 vendor 子路径（保留 safe）
        let path = "/Users/foo/Library/Caches/Homebrew/downloads/abc"
        let (verdict, _, _) = engine.evaluate(path: path, vendors: [rule], home: "/Users/foo")
        XCTAssertEqual(verdict, .safe, "vendor 子路径保持 safe，方便用户清掉 brew 缓存内容")
    }

    // MARK: - C 阶段：path 级规则解析（DEV_ARTIFACTS_RULES §2.x schema 升级）

    func testParsePathsWithVerdictAndReason() throws {
        // 模拟 DEV_ARTIFACTS_RULES §2.5 CocoaPods 真实条目
        let yaml = """
        vendors:
          - name: "CocoaPods"
            bundle_id_prefix: "org.cocoapods"
            paths:
              - path: "~/Library/Caches/CocoaPods"
                verdict: "safe"
                reason: "可重新下载，pod install 自愈"
                recipe: "pod cache clean --all"
              - path: "~/.cocoapods/repos"
                verdict: "confirm"
                reason: "Specs 仓库 ~3GB；删后首次 pod install 会重新 clone"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        let r = rules[0]
        XCTAssertEqual(r.name, "CocoaPods")
        XCTAssertEqual(r.bundleIDPrefix, "org.cocoapods")
        XCTAssertEqual(r.paths.count, 2)
        XCTAssertEqual(r.paths[0].path, "~/Library/Caches/CocoaPods")
        XCTAssertEqual(r.paths[0].verdict, .safe)
        XCTAssertEqual(r.paths[0].reason, "可重新下载，pod install 自愈")
        XCTAssertEqual(r.paths[0].recipe, "pod cache clean --all")
        XCTAssertEqual(r.paths[1].path, "~/.cocoapods/repos")
        XCTAssertEqual(r.paths[1].verdict, .confirm)
        XCTAssertNil(r.paths[1].recipe)
    }

    func testParsePathsBackwardCompatibleWithLegacyYaml() throws {
        // 现有 vendors.yaml 没有 paths 字段，必须继续 OK（向后兼容）
        let yaml = """
        vendors:
          - name: "Slack"
            bundle_id_prefix: "com.tinyspeck.slackmacgap"
            app_support_subdir: "Slack"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "Slack")
        XCTAssertTrue(rules[0].paths.isEmpty, "未声明 paths 时应为空数组")
    }

    func testParsePathsRejectsInvalidVerdict() {
        let yaml = """
        vendors:
          - name: "X"
            paths:
              - path: "~/foo"
                verdict: "delete"
        """
        XCTAssertThrowsError(try RuleLoader.parse(yaml)) { err in
            guard case RuleLoader.LoadError.malformed(_, let reason) = err else {
                return XCTFail("应抛出 malformed: \(err)")
            }
            XCTAssertTrue(reason.contains("verdict 必须是"),
                          "错误信息应说明合法 verdict 取值，得到 \(reason)")
        }
    }

    func testParsePathsMixWithVendorRoot() throws {
        // path 级规则与传统 vendor 根字段共存
        let yaml = """
        vendors:
          - name: "Xcode"
            bundle_id_prefix: "com.apple.dt.Xcode"
            paths:
              - path: "~/Library/Developer/Xcode/DerivedData"
                verdict: "safe"
                reason: "构建缓存，下次 build 重生成"
              - path: "~/Library/Developer/Xcode/Archives"
                verdict: "forbid"
                reason: "归档了用于上架的 dSYM 与符号，删了无法重建"
          - name: "Slack"
            app_support_subdir: "Slack"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].paths.count, 2)
        XCTAssertEqual(rules[0].paths[0].verdict, .safe)
        XCTAssertEqual(rules[0].paths[1].verdict, .forbid)
        XCTAssertEqual(rules[1].name, "Slack")
        XCTAssertTrue(rules[1].paths.isEmpty)
    }

    func testHardForbidRejectsMaliciousPathsEntry() throws {
        // 即使把恶意路径塞进 paths.path，loadVendors 也必须把整条 vendor 丢弃
        let yaml = """
        vendors:
          - name: "Trojan"
            paths:
              - path: "/System/Library"
                verdict: "safe"
                reason: "I promise it's fine"
        """
        let dir = NSTemporaryDirectory() + "RuleLoaderTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/v.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        let rules = try RuleLoader.loadVendors(from: url, home: "/Users/foo")
        XCTAssertTrue(rules.isEmpty,
                      "paths 中包含 hardForbid 路径的恶意 vendor 必须被整条丢弃")
    }

    func testHardForbidKeepsExplicitForbidPathRule() throws {
        // D 阶段细化：作者主动声明 verdict: forbid 的硬禁区路径，应**保留**
        // 形成"硬安全网 + yaml 显式 forbid"的多重防御，UI 还能展示 reason。
        let yaml = """
        vendors:
          - name: "Apple Developer Tools"
            paths:
              - path: "~/Library/MobileDevice/Provisioning Profiles"
                verdict: "forbid"
                reason: "描述文件，删了真机 / 上架直接断"
              - path: "~/Library/Developer/Xcode/DerivedData"
                verdict: "safe"
                reason: "构建中间产物，下次 build 自动重建"
        """
        let dir = NSTemporaryDirectory() + "RuleLoaderTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/v.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        let rules = try RuleLoader.loadVendors(from: url, home: "/Users/foo")
        XCTAssertEqual(rules.count, 1,
                       "verdict: forbid 与硬禁区重叠的合法多重防御条目必须保留")
        XCTAssertEqual(rules.first?.paths.count, 2)
    }

    // MARK: - C 阶段：path 级规则在 evaluate 中的语义

    func testPathOverrideSafeBeatsConfirm() {
        let engine = SafetyEngine()
        // ~/Library/Developer/Xcode/Archives 默认 base 是 confirm（在 ~/Library 下、
        // 不在 safeCachePrefixes），但 vendor 把 DerivedData 显式 safe。
        let rule = VendorRule(
            name: "Xcode",
            paths: [PathRule(path: "~/Library/Developer/Xcode/DerivedData",
                             verdict: .safe,
                             reason: "构建缓存")]
        )
        let (verdict, rejection, hit) = engine.evaluate(
            path: "/Users/foo/Library/Developer/Xcode/DerivedData",
            vendors: [rule], home: "/Users/foo"
        )
        XCTAssertEqual(verdict, .safe, "path 级 safe 必须把 confirm 降级为 safe")
        XCTAssertEqual(rejection, .ok)
        XCTAssertEqual(hit?.name, "Xcode")
    }

    func testPathOverrideSafeInheritsToSubpaths() {
        let engine = SafetyEngine()
        let rule = VendorRule(
            name: "Xcode",
            paths: [PathRule(path: "~/Library/Developer/Xcode/DerivedData",
                             verdict: .safe)]
        )
        // 子节点必须继承 safe，否则 ~/Library/Developer/Xcode/DerivedData/MyApp-abc/Build
        // 这种典型构建产物每条都得在 yaml 里声明
        let (verdict, _, hit) = engine.evaluate(
            path: "/Users/foo/Library/Developer/Xcode/DerivedData/MyApp-abc123/Build/Intermediates",
            vendors: [rule], home: "/Users/foo"
        )
        XCTAssertEqual(verdict, .safe, "path 级 safe 必须沿子树继承")
        XCTAssertEqual(hit?.name, "Xcode")
    }

    func testPathOverrideForbidEscalates() {
        let engine = SafetyEngine()
        let rule = VendorRule(
            name: "Xcode",
            paths: [PathRule(path: "~/Library/Developer/Xcode/Archives",
                             verdict: .forbid,
                             reason: "归档含上架 dSYM，删了无法重建")]
        )
        let (verdict, rejection, hit) = engine.evaluate(
            path: "/Users/foo/Library/Developer/Xcode/Archives/2026-05-23/MyApp.xcarchive",
            vendors: [rule], home: "/Users/foo"
        )
        XCTAssertEqual(verdict, .forbid, "path 级 forbid 必须把 confirm 升级为 forbid")
        XCTAssertEqual(rejection, .vendorPathRule,
                       "rejection 应标识为 vendorPathRule 便于审计")
        XCTAssertEqual(hit?.name, "Xcode",
                       "命中规则要带回 vendor 元数据，方便 UI 展示规则来源")
    }

    func testPathOverrideCannotBypassHardForbid() {
        let engine = SafetyEngine()
        // 恶意作者声明 ~/.ssh 是 safe —— 必须被硬安全网（B 阶段）兜住
        let rule = VendorRule(
            name: "Evil",
            paths: [PathRule(path: "~/.ssh", verdict: .safe,
                             reason: "trust me bro")]
        )
        let (verdict, rejection, _) = engine.evaluate(
            path: "/Users/foo/.ssh/id_rsa", vendors: [rule], home: "/Users/foo"
        )
        XCTAssertEqual(verdict, .forbid,
                       "硬安全网必须优先于 path 级 override")
        XCTAssertEqual(rejection, .sensitiveCredential,
                       "rejection 应保持 sensitiveCredential，证明走的是 B 阶段红线")
    }

    // MARK: - D1 阶段：真实 vendors.yaml 契约校验

    /// 把仓库根的 Resources/Rules/vendors.yaml 当成"实际产物"喂进解析器，
    /// 验证 §2.1 的 21 条 Apple Developer Tools path-rule 全部可被加载、
    /// verdict 分布正确，并经过 hardForbid 反向校验后整条 vendor 仍被保留
    /// （依赖 D0b 的 loadVendors 修复：显式 verdict=forbid 与硬安全网重叠时不被丢弃）。
    func testRealVendorsYamlLoadsApplePathRules() throws {
        // 测试运行时 cwd = SafetyKit 包根；从 Tests 文件向上回溯到 repo 根。
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()  // SafetyKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SafetyKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // <repo root>
        let yamlURL = repoRoot
            .appendingPathComponent("Resources/Rules/vendors.yaml")
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在于预期位置 \(yamlURL.path)")
        }
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: "/Users/foo")
        guard let apple = rules.first(where: { $0.name == "Apple Developer Tools" }) else {
            return XCTFail("vendors.yaml 应包含 Apple Developer Tools vendor")
        }
        XCTAssertEqual(apple.paths.count, 21,
                       "§2.1 表共 21 条 path-rule，全部要落地")

        // 抽样校验关键 verdict
        let byPath = Dictionary(uniqueKeysWithValues:
            apple.paths.map { ($0.path, $0.verdict) })
        XCTAssertEqual(byPath["~/Library/Developer/Xcode/DerivedData"], .safe)
        XCTAssertEqual(byPath["~/Library/Developer/Xcode/Archives"], .confirm)
        XCTAssertEqual(byPath["~/Library/Developer/CoreSimulator/Devices"], .confirm)
        XCTAssertEqual(byPath["~/Library/MobileDevice/Provisioning Profiles"], .forbid)
        XCTAssertEqual(byPath["~/Library/org.swift.swiftpm/security"], .forbid)
        XCTAssertEqual(byPath["~/Library/Developer/Xcode/UserData/CodeSnippets"], .forbid)

        // CoreSimulator/Devices 必须带 recipe（引导用户走 simctl delete）
        let devicesRule = apple.paths.first {
            $0.path == "~/Library/Developer/CoreSimulator/Devices"
        }
        XCTAssertNotNil(devicesRule?.recipe,
                        "Devices 应附操作处方，UI 才能引导走 xcrun simctl delete")

        // 关键不变量：所有 path 必须有 reason（UI 透明度要求）
        for p in apple.paths {
            XCTAssertNotNil(p.reason, "\(p.path) 缺少 reason 字段")
            XCTAssertFalse(p.reason?.isEmpty ?? true,
                           "\(p.path) 的 reason 不能为空字符串")
        }
    }

    /// 把 D0b 改动钉死：用真实 yaml 的 `~/Library/MobileDevice/Provisioning Profiles`
    /// 这条 verdict=forbid 的多重防御条目，证明 vendor **没**被 loadVendors 整条丢弃。
    func testRealVendorsYamlPreservesDefenseInDepthForbids() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let yamlURL = repoRoot
            .appendingPathComponent("Resources/Rules/vendors.yaml")
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: "/Users/foo")
        let apple = rules.first { $0.name == "Apple Developer Tools" }
        XCTAssertNotNil(apple,
                        "Apple Developer Tools 不应被 loadVendors 误丢——尽管它包含与硬安全网重叠的 forbid 路径")
    }

    // MARK: - D2.1 阶段：JetBrains 全家桶 + VS Code/Cursor/Trae 真实 yaml 契约

    /// 校验 §2.2 表落地后：JetBrains vendor 含 13 条 path-rule，
    /// 其中 10 条是 `<product>*` glob（10 款 IDE 产品的 ~/Library/Caches 缓存）。
    func testRealVendorsYamlLoadsJetBrainsPathRules() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let yamlURL = repoRoot.appendingPathComponent("Resources/Rules/vendors.yaml")
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: "/Users/foo")

        guard let jb = rules.first(where: { $0.name == "JetBrains" }) else {
            return XCTFail("vendors.yaml 应保留 JetBrains vendor")
        }
        XCTAssertEqual(jb.paths.count, 13,
                       "§2.2 JetBrains 表落地：10 款 IDE × Caches glob + Logs/Toolbox/consentOptions = 13 条")

        // 抽样校验：IntelliJ 缓存 glob 必在
        let hasIntelliJ = jb.paths.contains {
            $0.path == "~/Library/Caches/JetBrains/IntelliJIdea*" && $0.verdict == .safe
        }
        XCTAssertTrue(hasIntelliJ, "IntelliJIdea* 缓存 glob 必落地为 safe")

        // Toolbox / consentOptions：confirm
        let toolbox = jb.paths.first { $0.path == "~/Library/Application Support/JetBrains/Toolbox" }
        XCTAssertEqual(toolbox?.verdict, .confirm)
        let consent = jb.paths.first { $0.path == "~/Library/Application Support/JetBrains/consentOptions" }
        XCTAssertEqual(consent?.verdict, .confirm)

        // 所有 path-rule 必须带 reason（UI 透明度）
        for p in jb.paths {
            XCTAssertFalse(p.reason?.isEmpty ?? true,
                           "JetBrains \(p.path) 的 reason 不能为空")
        }
    }

    /// 校验 §2.2 VS Code / Cursor / Trae：每个 vendor 6 条 path-rule，
    /// globalStorage 必为 forbid（多重防御）。
    func testRealVendorsYamlLoadsCodeFamilyPathRules() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let yamlURL = repoRoot.appendingPathComponent("Resources/Rules/vendors.yaml")
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: "/Users/foo")

        // 三个 Electron 系编辑器结构一致 —— 同样 6 条 path-rule
        for vendorName in ["Code", "Cursor", "Trae"] {
            guard let v = rules.first(where: { $0.name == vendorName }) else {
                XCTFail("\(vendorName) 应在 vendors.yaml")
                continue
            }
            XCTAssertEqual(v.paths.count, 6,
                           "\(vendorName) 应落地 6 条 path-rule（Cache/CachedData/CachedExtensionVSIXs/logs/workspaceStorage/globalStorage）")

            // globalStorage 必为 forbid（含登录 token / 同步密钥）
            let global = v.paths.first {
                $0.path.hasSuffix("/User/globalStorage")
            }
            XCTAssertEqual(global?.verdict, .forbid,
                           "\(vendorName) globalStorage 必须 forbid（多重防御）")

            // workspaceStorage：confirm（删了丢面板布局）
            let ws = v.paths.first {
                $0.path.hasSuffix("/User/workspaceStorage")
            }
            XCTAssertEqual(ws?.verdict, .confirm)

            // Cache / CachedData：safe
            let cache = v.paths.first { $0.path.hasSuffix("/Cache") }
            XCTAssertEqual(cache?.verdict, .safe)
        }
    }

    /// 端到端：构 trie + 真实 yaml，喂一条 IntelliJ 版本号路径，
    /// 应当通过 glob 命中并降到 safe。
    func testRealVendorsYamlJetBrainsGlobIntegration() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let yamlURL = repoRoot.appendingPathComponent("Resources/Rules/vendors.yaml")
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let home = "/Users/foo"
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // 模拟真实 IntelliJ 2024.3 缓存子目录
        let path = "/Users/foo/Library/Caches/JetBrains/IntelliJIdea2024.3/index"
        let (verdict, _, vendor) = engine.evaluate(path: path, trie: trie, home: home)
        XCTAssertEqual(verdict, .safe,
                       "IntelliJIdea<version>/index 应通过 glob 命中并降到 safe")
        XCTAssertEqual(vendor?.name, "JetBrains")
    }

    // MARK: - D2.2 阶段：Android / Gradle / AVD 真实 yaml 契约

    /// 校验 §2.3 表落地后：Gradle vendor 含 7 条 path-rule，
    /// 含与 dotfileCredentialSuffixes 重叠的 init.d / gradle.properties 多重防御 forbid。
    func testRealVendorsYamlLoadsGradlePathRules() throws {
        let yamlURL = Self.vendorsYamlURL()
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let home = "/Users/foo"
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: home)
        guard let gradle = rules.first(where: { $0.name == "Gradle" }) else {
            return XCTFail("vendors.yaml 应含 Gradle vendor")
        }
        XCTAssertEqual(gradle.paths.count, 7,
                       "§2.3 Gradle 表落地：5 safe/confirm + 2 forbid（多重防御）= 7 条")

        // 多重防御：init.d / gradle.properties 必须保留为 forbid
        let initD = gradle.paths.first { $0.path == "~/.gradle/init.d" }
        XCTAssertEqual(initD?.verdict, .forbid,
                       "init.d 必为 forbid（与 dotfileCredentialSuffixes 重叠的多重防御）")
        let props = gradle.paths.first { $0.path == "~/.gradle/gradle.properties" }
        XCTAssertEqual(props?.verdict, .forbid)

        // caches：safe + 含 recipe（提示 ./gradlew --stop）
        let caches = gradle.paths.first { $0.path == "~/.gradle/caches" }
        XCTAssertEqual(caches?.verdict, .safe)
        XCTAssertNotNil(caches?.recipe, "Gradle caches 应附 ./gradlew --stop 处方")
    }

    /// 校验 §2.3 表落地后：Android vendor 含 9 条 path-rule，
    /// SDK 本体 + 调试凭证均为 forbid。
    func testRealVendorsYamlLoadsAndroidPathRules() throws {
        let yamlURL = Self.vendorsYamlURL()
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let home = "/Users/foo"
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: home)
        guard let android = rules.first(where: { $0.name == "Android" }) else {
            return XCTFail("vendors.yaml 应含 Android vendor")
        }
        XCTAssertEqual(android.paths.count, 8,
                       "§2.3 Android 表落地：2 safe + 1 confirm(avd) + 5 forbid = 8 条")

        // AVD：confirm + 含 recipe
        let avd = android.paths.first { $0.path == "~/.android/avd" }
        XCTAssertEqual(avd?.verdict, .confirm)
        XCTAssertNotNil(avd?.recipe, "AVD 应附 avdmanager 处方")

        // SDK 本体两条都必须 forbid
        let sdk1 = android.paths.first { $0.path == "~/.android/sdk" }
        XCTAssertEqual(sdk1?.verdict, .forbid)
        let sdk2 = android.paths.first { $0.path == "~/Library/Android/sdk" }
        XCTAssertEqual(sdk2?.verdict, .forbid)

        // 调试 keystore / adbkey：多重防御 forbid
        XCTAssertEqual(android.paths.first { $0.path == "~/.android/debug.keystore" }?.verdict, .forbid)
        XCTAssertEqual(android.paths.first { $0.path == "~/.android/adbkey" }?.verdict, .forbid)
        XCTAssertEqual(android.paths.first { $0.path == "~/.android/adbkey.pub" }?.verdict, .forbid)
    }

    /// 端到端：AndroidStudio 用 glob 匹配版本号。
    /// `~/Library/Caches/Google/AndroidStudio2024.1/index` → safe；
    /// `~/Library/Application Support/Google/AndroidStudio2024.1/keys.dat` → forbid（含 SDK Path 配置）。
    func testRealVendorsYamlAndroidStudioGlobIntegration() throws {
        let yamlURL = Self.vendorsYamlURL()
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("vendors.yaml 不存在")
        }
        let home = "/Users/foo"
        let rules = try RuleLoader.loadVendors(from: yamlURL, home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // safe：缓存子目录
        let cachePath = "/Users/foo/Library/Caches/Google/AndroidStudio2024.1/index"
        let (verdict1, _, vendor1) = engine.evaluate(path: cachePath, trie: trie, home: home)
        XCTAssertEqual(verdict1, .safe,
                       "AS 缓存子目录应 glob 命中并降到 safe")
        XCTAssertEqual(vendor1?.name, "AndroidStudio")

        // forbid：Application Support 配置目录（含 SDK Path）
        let configPath = "/Users/foo/Library/Application Support/Google/AndroidStudio2024.1/options"
        let (verdict2, _, _) = engine.evaluate(path: configPath, trie: trie, home: home)
        XCTAssertEqual(verdict2, .forbid,
                       "AS Application Support 子目录应 glob 命中并升到 forbid")
    }

    // MARK: - D3 §2.5 RN/Flutter/前端工具链

    /// D3.1：CocoaPods 4 条 path-rule（trunk safe + repos confirm + Pods/Release/External safe）
    func testRealVendorsYamlLoadsCocoaPodsPathRules() throws {
        let rules = try Self.loadRealRules()
        guard let cp = rules.first(where: { $0.name == "CocoaPods" }) else {
            return XCTFail("vendors.yaml 应含 CocoaPods vendor")
        }
        XCTAssertEqual(cp.paths.count, 4,
                       "§2.5 CocoaPods：trunk safe + repos confirm + Release/External safe = 4 条")
        XCTAssertEqual(cp.paths.first { $0.path == "~/.cocoapods/repos/trunk" }?.verdict, .safe)
        XCTAssertEqual(cp.paths.first { $0.path == "~/.cocoapods/repos" }?.verdict, .confirm)
        XCTAssertEqual(cp.paths.first { $0.path == "~/Library/Caches/CocoaPods/Pods/Release" }?.verdict, .safe)
        XCTAssertEqual(cp.paths.first { $0.path == "~/Library/Caches/CocoaPods/Pods/External" }?.verdict, .safe)
    }

    /// D3.1：CocoaPods 父子 path 层级语义：trunk(safe) 子目录走 safe；非 trunk 子目录走 confirm 父
    func testRealVendorsYamlCocoaPodsTrunkOverridesParent() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // trunk 子目录 → safe
        let trunkSpec = "/Users/foo/.cocoapods/repos/trunk/Specs/0/0/1/AFNetworking"
        XCTAssertEqual(engine.evaluate(path: trunkSpec, trie: trie, home: home).0, .safe,
                       "trunk 子目录被更深 path-rule 覆盖为 safe")

        // 非 trunk 私有 spec 子目录 → confirm（继承父 repos 的 verdict）
        let privateSpec = "/Users/foo/.cocoapods/repos/MyPrivateSpecs/Specs/Foo"
        XCTAssertEqual(engine.evaluate(path: privateSpec, trie: trie, home: home).0, .confirm,
                       "私有 spec 仓库继承父 repos confirm")
    }

    /// D3.2：NodePackagers 11 条 path-rule，覆盖 npm/yarn/pnpm/bun
    func testRealVendorsYamlLoadsNodePackagersPathRules() throws {
        let rules = try Self.loadRealRules()
        guard let np = rules.first(where: { $0.name == "NodePackagers" }) else {
            return XCTFail("vendors.yaml 应含 NodePackagers vendor")
        }
        XCTAssertEqual(np.paths.count, 10,
                       "§2.5 NodePackagers：1 Yarn + 1 Yarn-Berry + 3 npm + 2 pnpm-store(confirm) + 1 pnpm-cache + 2 bun = 10 条")

        // pnpm store：confirm + recipe（硬链风险）
        let pnpmStore = np.paths.first { $0.path == "~/Library/pnpm/store" }
        XCTAssertEqual(pnpmStore?.verdict, .confirm)
        XCTAssertNotNil(pnpmStore?.recipe, "pnpm store 应附 recipe（pnpm store prune）")

        // npm cache：safe（无 token 风险，.npmrc 由 dotfileCredentialSuffixes 兜底）
        XCTAssertEqual(np.paths.first { $0.path == "~/.npm/_cacache" }?.verdict, .safe)
    }

    /// D3.3：Flutter pub-cache，bin 必须 forbid
    func testRealVendorsYamlLoadsFlutterPathRules() throws {
        let rules = try Self.loadRealRules()
        guard let fl = rules.first(where: { $0.name == "Flutter" }) else {
            return XCTFail("vendors.yaml 应含 Flutter vendor")
        }
        XCTAssertEqual(fl.paths.count, 3,
                       "§2.5 Flutter：hosted/git confirm + bin forbid = 3 条")
        XCTAssertEqual(fl.paths.first { $0.path == "~/.pub-cache/bin" }?.verdict, .forbid,
                       "pub-cache/bin 是全局 dart 工具二进制，必须 forbid")
    }

    /// D3.4：ReactNative Metro/Watchman/Expo/EAS
    func testRealVendorsYamlLoadsReactNativePathRules() throws {
        let rules = try Self.loadRealRules()
        guard let rn = rules.first(where: { $0.name == "ReactNative" }) else {
            return XCTFail("vendors.yaml 应含 ReactNative vendor")
        }
        XCTAssertEqual(rn.paths.count, 4,
                       "§2.5 RN：Metro/Watchman safe + Expo/EAS confirm = 4 条")

        // Watchman 应附 recipe（先 shutdown-server）
        let watchman = rn.paths.first { $0.path == "~/Library/Caches/Watchman" }
        XCTAssertEqual(watchman?.verdict, .safe)
        XCTAssertNotNil(watchman?.recipe)

        // Expo 含 token：confirm（严格意义不属硬安全网，但 UI 默认不勾）
        XCTAssertEqual(rn.paths.first { $0.path == "~/.expo" }?.verdict, .confirm)
    }

    // MARK: - D3 §2.6 后端 / 通用工具链

    /// D3.5：Cargo registry/git safe + bin/config forbid（多重防御）
    func testRealVendorsYamlLoadsCargoPathRules() throws {
        let rules = try Self.loadRealRules()
        guard let cargo = rules.first(where: { $0.name == "Cargo" }) else {
            return XCTFail("vendors.yaml 应含 Cargo vendor")
        }
        XCTAssertEqual(cargo.paths.count, 5,
                       "§2.6 Cargo：registry/cache,registry/src,git/db safe + bin,config.toml forbid = 5 条")
        XCTAssertEqual(cargo.paths.first { $0.path == "~/.cargo/bin" }?.verdict, .forbid)
        XCTAssertEqual(cargo.paths.first { $0.path == "~/.cargo/config.toml" }?.verdict, .forbid,
                       "config.toml 显式 forbid（同时被 dotfileCredentialSuffixes 多重防御）")
    }

    /// D3.6：Cargo config.toml 即便绕过 yaml 也被硬安全网兜底
    func testRealVendorsYamlCargoConfigBlockedByHardForbid() {
        let home = "/Users/foo"
        let engine = SafetyEngine()
        let path = "/Users/foo/.cargo/config.toml"
        let (verdict, reason) = engine.evaluate(path: path, home: home)
        XCTAssertEqual(verdict, .forbid)
        XCTAssertEqual(reason, .sensitiveCredential,
                       "config.toml 命中 dotfileCredentialSuffixes 硬安全网")
    }

    /// D3.7：Python pip/Poetry 缓存
    func testRealVendorsYamlLoadsPythonPathRules() throws {
        let rules = try Self.loadRealRules()
        guard let py = rules.first(where: { $0.name == "Python" }) else {
            return XCTFail("vendors.yaml 应含 Python vendor")
        }
        XCTAssertEqual(py.paths.count, 3, "§2.6 Python：pip + pypoetry(2 路径) = 3 条")
        XCTAssertTrue(py.paths.allSatisfy { $0.verdict == .safe },
                      "全部 safe（无凭证风险）")
    }

    /// D3.8：Containers Docker/Colima/Kube/minikube
    func testRealVendorsYamlLoadsContainersPathRules() throws {
        let rules = try Self.loadRealRules()
        guard let ct = rules.first(where: { $0.name == "Containers" }) else {
            return XCTFail("vendors.yaml 应含 Containers vendor")
        }
        XCTAssertEqual(ct.paths.count, 6,
                       "§2.6 Containers：Docker.raw,Colima,minikube + kube/cache safe + Group Containers,kubeconfig forbid = 6 条")

        // Docker.raw：confirm + recipe（不能直接 rm）
        let dockerRaw = ct.paths.first {
            $0.path == "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        }
        XCTAssertEqual(dockerRaw?.verdict, .confirm)
        XCTAssertNotNil(dockerRaw?.recipe, "Docker.raw 应附 recipe（docker system prune）")

        // Group Containers/group.com.docker：forbid 多重防御
        XCTAssertEqual(
            ct.paths.first { $0.path == "~/Library/Group Containers/group.com.docker" }?.verdict,
            .forbid)
        // kube/config：forbid 多重防御（同时被 dotfileCredentialSuffixes 兜底）
        XCTAssertEqual(ct.paths.first { $0.path == "~/.kube/config" }?.verdict, .forbid)
    }

    /// D3.9：端到端 D3 多 vendor 集成 —— Cargo 缓存 safe / Cargo bin forbid / Homebrew 缓存 safe
    func testRealVendorsYamlD3EndToEnd() throws {
        let home = "/Users/foo"
        let rules = try Self.loadRealRules(home: home)
        let trie = VendorTrie.build(vendors: rules, home: home)
        let engine = SafetyEngine()

        // Cargo registry cache：safe
        XCTAssertEqual(
            engine.evaluate(path: "/Users/foo/.cargo/registry/cache/foo.crate",
                            trie: trie, home: home).0,
            .safe)

        // Cargo bin：forbid（yaml 显式 + 硬安全网无）
        XCTAssertEqual(
            engine.evaluate(path: "/Users/foo/.cargo/bin", trie: trie, home: home).0,
            .forbid)

        // Homebrew bottle 缓存：safe
        XCTAssertEqual(
            engine.evaluate(path: "/Users/foo/Library/Caches/Homebrew/downloads",
                            trie: trie, home: home).0,
            .safe)

        // Go module 下载缓存：safe
        XCTAssertEqual(
            engine.evaluate(path: "/Users/foo/go/pkg/mod/cache/download/github.com",
                            trie: trie, home: home).0,
            .safe)

        // Watchman：safe（不在硬安全网内，由 yaml 降级到 safe）
        XCTAssertEqual(
            engine.evaluate(path: "/Users/foo/Library/Caches/Watchman/state",
                            trie: trie, home: home).0,
            .safe)
    }

    // MARK: - review 高危 #2 回归：PartialPathRule.buildOrError 严格模式

    func testPartialPathRuleMissingVerdictThrows() {
        // path 写了但忘写 verdict —— 旧实现静默丢弃（path-rule 凭空消失，
        // 调用方与 yaml 作者完全不知）。新实现必须抛 LoadError.malformed。
        let yaml = """
        vendors:
          - name: "BadVendor"
            paths:
              - path: "~/Library/Caches/com.bad"
                reason: "忘写 verdict"
        """
        XCTAssertThrowsError(try RuleLoader.parse(yaml)) { err in
            guard case let RuleLoader.LoadError.malformed(_, reason) = err else {
                return XCTFail("应抛 LoadError.malformed，实际：\(err)")
            }
            XCTAssertTrue(reason.contains("verdict"),
                          "错误原因必须明确指出缺 verdict，实际：\(reason)")
        }
    }

    func testPartialPathRuleVerdictTypoThrows() {
        // 把 `verdict:` 拼成 `verdic:`（review 工程债 #2 直接复现）
        // —— 旧实现：`verdict` 永远 nil，path-rule 静默丢弃。
        // 新实现：parse 不识别 verdic 这个 key，verdict 仍 nil，build 时报错。
        let yaml = """
        vendors:
          - name: "TypoVendor"
            paths:
              - path: "~/Library/Caches/com.typo"
                verdic: "safe"
                reason: "verdict 拼错"
        """
        XCTAssertThrowsError(try RuleLoader.parse(yaml)) { err in
            guard case let RuleLoader.LoadError.malformed(_, reason) = err else {
                return XCTFail("应抛 LoadError.malformed，实际：\(err)")
            }
            XCTAssertTrue(reason.contains("verdict"),
                          "错误原因必须提示缺 verdict（变相帮作者发现拼写错），实际：\(reason)")
        }
    }

    func testPartialPathRuleMissingPathThrows() {
        // 反向场景：写了 verdict 但忘写 path。也应抛错。
        let yaml = """
        vendors:
          - name: "NoPathVendor"
            paths:
              - verdict: "safe"
                reason: "忘写 path"
        """
        XCTAssertThrowsError(try RuleLoader.parse(yaml)) { err in
            guard case let RuleLoader.LoadError.malformed(_, reason) = err else {
                return XCTFail("应抛 LoadError.malformed，实际：\(err)")
            }
            XCTAssertTrue(reason.contains("path"),
                          "错误原因必须明确指出缺 path，实际：\(reason)")
        }
    }

    func testEmptyPartialPathRuleSkippedSilently() {
        // 边界情况：paths: 块翻开但本 vendor 一条 path-rule 都还没填字段
        // （parse 流尾部 currentPath 是个完全空 partial）—— 这种允许跳过，不报错。
        let yaml = """
        vendors:
          - name: "EmptyPathsVendor"
            bundle_id_prefix: "com.empty"
        """
        let rules = try? RuleLoader.parse(yaml)
        XCTAssertEqual(rules?.count, 1, "完全没声明 paths 的 vendor 应正常解析")
        XCTAssertTrue(rules?.first?.paths.isEmpty ?? false)
    }

    // MARK: - review 高危 #3 回归：paths: 块按 leading 缩进退出

    func testPathsBlockDoesNotSwallowFollowingTopLevelKeys() throws {
        // 旧实现 bug：vendor.paths: 之后再出现 vendor 顶层 key（如 note / bundle_id_prefix），
        // pathsMode 不会自动退出，导致这些 key 被当成 paths-item 子键 / 抛 malformed。
        // 修复后：遇到 leading <= 4 的非 `- ` 行先关 paths 块，再走 vendor 顶层解析。
        let yaml = """
        vendors:
          - name: "OrderedVendor"
            bundle_id_prefix: "com.ordered"
            paths:
              - path: "~/Library/Caches/com.ordered"
                verdict: "safe"
                reason: "正常 cache"
            note: "paths 之后紧跟的 vendor 顶层 key 不应被吞掉"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 1)
        let v = rules[0]
        XCTAssertEqual(v.name, "OrderedVendor")
        XCTAssertEqual(v.paths.count, 1, "只该有 1 条 path-rule，不应把 note 也吞进 paths")
        XCTAssertEqual(v.paths.first?.path, "~/Library/Caches/com.ordered")
        XCTAssertEqual(v.paths.first?.verdict, .safe)
    }

    func testPathsBlockExitsBeforeNextVendor() throws {
        // 多个 vendor 紧挨：第一个 vendor 末尾的 paths-item 没有显式分隔，
        // 第二个 vendor 的 `- name:` 必须能被识别为新顶层项而不是 paths 子项。
        let yaml = """
        vendors:
          - name: "First"
            paths:
              - path: "~/Library/Caches/com.first"
                verdict: "safe"
          - name: "Second"
            paths:
              - path: "~/Library/Caches/com.second"
                verdict: "confirm"
        """
        let rules = try RuleLoader.parse(yaml)
        XCTAssertEqual(rules.count, 2, "两个独立 vendor，不应合并成一个")
        XCTAssertEqual(rules[0].name, "First")
        XCTAssertEqual(rules[0].paths.count, 1)
        XCTAssertEqual(rules[0].paths.first?.verdict, .safe)
        XCTAssertEqual(rules[1].name, "Second")
        XCTAssertEqual(rules[1].paths.count, 1)
        XCTAssertEqual(rules[1].paths.first?.verdict, .confirm)
    }

    /// 提取仓库根的 vendors.yaml URL（与上面三处 #filePath 拷贝重复，集中到一处）
    private static func vendorsYamlURL() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Rules/vendors.yaml")
    }

    /// 加载仓库根 vendors.yaml 真实规则（D3 起所有 testRealVendorsYaml... 系列复用入口）。
    /// 抽出原因（review 工程债 #1/#2）：30+ 处测试出现 `let yamlURL = Self.vendorsYamlURL();
    /// let home = "/Users/foo"; let rules = try RuleLoader.loadVendors(from: yamlURL, home: home)`
    /// 三连重复。集中到一处后，未来若 home 默认值变化（如改为 NSHomeDirectory()）或装载入口
    /// 名字调整，只需改这里一处。
    /// - Parameter home: 测试用 home（默认 `/Users/foo`，与现有 D2/D3 全部测试一致）
    /// - Returns: 经 RuleLoader.loadVendors 装载、过滤完的真实 vendors（含硬安全网过滤）
    static func loadRealRules(home: String = "/Users/foo") throws -> [VendorRule] {
        try RuleLoader.loadVendors(from: vendorsYamlURL(), home: home)
    }
}
