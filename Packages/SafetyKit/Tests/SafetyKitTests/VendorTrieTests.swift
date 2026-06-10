import XCTest
@testable import SafetyKit

final class VendorTrieTests: XCTestCase {

    private let home = "/Users/foo"
    private let engine = SafetyEngine()

    // MARK: - 行为正确性

    func test_trie命中根目录返回isExactRootTrue() {
        let rule = VendorRule(name: "Adobe", appSupportSubdir: "Adobe")
        let root = VendorTrie.build(vendors: [rule], home: home)
        let path = "/Users/foo/Library/Application Support/Adobe"

        guard let hit = VendorTrie.match(standardizedPath: path, in: root) else {
            return XCTFail("应当命中 vendor 根")
        }
        XCTAssertTrue(hit.isExactRoot, "路径恰好等于 vendor 根 → isExactRoot = true")
        XCTAssertEqual(hit.rule.name, "Adobe")

        // 与上层 evaluate 联动：vendor 根强制 confirm
        let (verdict, _, vrule) = engine.evaluate(path: path, trie: root, home: home)
        XCTAssertEqual(verdict, .confirm)
        XCTAssertEqual(vrule?.name, "Adobe")
    }

    func test_trie命中子目录返回isExactRootFalse() {
        let rule = VendorRule(name: "Brew", cachesPath: "~/Library/Caches/Homebrew")
        let root = VendorTrie.build(vendors: [rule], home: home)
        let path = "/Users/foo/Library/Caches/Homebrew/downloads/abc.tar.gz"

        guard let hit = VendorTrie.match(standardizedPath: path, in: root) else {
            return XCTFail("应当命中 vendor 子目录")
        }
        XCTAssertFalse(hit.isExactRoot, "路径是 vendor 子目录 → isExactRoot = false")
        XCTAssertEqual(hit.rule.name, "Brew")

        // 与上层 evaluate 联动：子目录保持 base verdict（safe，因为命中 ~/Library/Caches/）
        let (verdict, _, vrule) = engine.evaluate(path: path, trie: root, home: home)
        XCTAssertEqual(verdict, .safe)
        XCTAssertEqual(vrule?.name, "Brew")
    }

    // MARK: - 与朴素实现等价性（200 path × 50 vendor 随机对拍）

    func test_trie与朴素evaluate结果完全一致() {
        let vendors = Self.makeVendors(count: 50, seed: 0xC0FFEE)
        let paths = Self.makePaths(home: home, vendors: vendors, count: 200, seed: 0xBEEF)
        let trie = VendorTrie.build(vendors: vendors, home: home)

        for p in paths {
            let trieResult = engine.evaluate(path: p, trie: trie, home: home)
            let naiveResult = Self.naiveEvaluate(engine: engine, path: p,
                                                 vendors: vendors, home: home)
            XCTAssertEqual(trieResult.0, naiveResult.0,
                           "verdict 不一致 path=\(p)")
            XCTAssertEqual(trieResult.1, naiveResult.1,
                           "rejection 不一致 path=\(p)")
            XCTAssertEqual(trieResult.2?.name, naiveResult.2?.name,
                           "命中 vendor 不一致 path=\(p)")
        }
    }

    // MARK: - C 阶段：path 级 override 在 trie 中的存储与命中

    func test_trie保留path级override并通过match返回() {
        let pathRule = PathRule(path: "~/Library/Developer/Xcode/DerivedData",
                                verdict: .safe,
                                reason: "build cache",
                                recipe: "rm -rf 即可")
        let vendor = VendorRule(name: "Xcode", paths: [pathRule])
        let root = VendorTrie.build(vendors: [vendor], home: home)

        // 命中根：应同时返回 rule + override
        guard let hit = VendorTrie.match(
            standardizedPath: "/Users/foo/Library/Developer/Xcode/DerivedData",
            in: root
        ) else { return XCTFail("应当命中") }
        XCTAssertTrue(hit.isExactRoot)
        XCTAssertEqual(hit.rule.name, "Xcode")
        XCTAssertEqual(hit.pathOverride?.verdict, .safe)
        XCTAssertEqual(hit.pathOverride?.recipe, "rm -rf 即可")
    }

    func test_trie让pathOverride沿子树继承() {
        let pathRule = PathRule(path: "~/Library/Developer/Xcode/DerivedData",
                                verdict: .safe)
        let vendor = VendorRule(name: "Xcode", paths: [pathRule])
        let root = VendorTrie.build(vendors: [vendor], home: home)

        // 命中子目录：override 必须沿祖先继承
        guard let hit = VendorTrie.match(
            standardizedPath: "/Users/foo/Library/Developer/Xcode/DerivedData/MyApp-abc/Build",
            in: root
        ) else { return XCTFail("应当命中") }
        XCTAssertFalse(hit.isExactRoot)
        XCTAssertNotNil(hit.pathOverride, "祖先节点的 pathOverride 必须传递到后代")
        XCTAssertEqual(hit.pathOverride?.verdict, .safe)
    }

    func test_trie默认vendor根无pathOverride() {
        // 仅用 appSupportSubdir/cachesPath 的 vendor，不应给节点挂 pathOverride
        let vendor = VendorRule(name: "Slack", appSupportSubdir: "Slack")
        let root = VendorTrie.build(vendors: [vendor], home: home)
        guard let hit = VendorTrie.match(
            standardizedPath: "/Users/foo/Library/Application Support/Slack",
            in: root
        ) else { return XCTFail("应当命中") }
        XCTAssertNil(hit.pathOverride, "传统 vendor 根不应自带 pathOverride")
    }

    // MARK: - 性能基准（159 vendor × 5000 evaluate）

    func test_trie匹配159条vendor性能基准() {
        let vendors = Self.makeVendors(count: 159, seed: 0x1234)
        let trie = VendorTrie.build(vendors: vendors, home: home)
        let paths = Self.makePaths(home: home, vendors: vendors, count: 5000, seed: 0x5678)

        // 用 measure 记录耗时；用 maxDuration 断言 <100ms
        let opts = XCTMeasureOptions()
        opts.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: opts) {
            for p in paths {
                _ = engine.evaluate(path: p, trie: trie, home: home)
            }
        }

        // 显式再跑一次拿到具体耗时（不依赖 measure 内部断言）
        let start = Date()
        for p in paths {
            _ = engine.evaluate(path: p, trie: trie, home: home)
        }
        let elapsed = Date().timeIntervalSince(start) * 1000.0 // ms

        // budget：
        // - **release** 模式：M 系列裸金属 ~110-130ms / CI macos-15 共享 runner ~135ms。
        //   200ms（本地）/ 350ms（CI）= 守住"线性扫 trie 不爆性能"的回归底线。
        // - **debug** 模式：未 -O 编译时字符串比较成本翻 5-7×，本地实测 ~700-800ms，
        //   再叠 CI 共享 runner 的抖动给到 1500ms 上限，避免日常 `swift test` 误杀。
        //
        // 历史：原本 60/100/250ms 是基于 SafetyEngine 仅做 12 条前缀扫描的版本设定。
        // DEV_ARTIFACTS_RULES §2.7 黄金禁区落地后，evaluateStandardized 内固定要扫
        // 凭证桶（dotfile ~21 项 / Library 4 项，分桶后单次评估均摊 ~13 项）+ 后缀
        // 6 项 + 路径段 1 项 ≈ 多出 20 个字符串比较。线性扫 trie 主路径并未变化。
        let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        #if DEBUG
        let budgetMs: Double = isCI ? 1500.0 : 1000.0
        #else
        let budgetMs: Double = isCI ? 350.0 : 200.0
        #endif
        XCTAssertLessThan(elapsed, budgetMs,
                          "5000 次 evaluate 耗时 \(elapsed)ms 应小于 \(budgetMs)ms (CI=\(isCI))")
    }

    // MARK: - Helpers

    /// 朴素实现 —— 与重构前的 evaluate(path:vendors:home:) 逻辑完全一致，
    /// 用于对拍 trie 版本的等价性。
    private static func naiveEvaluate(engine: SafetyEngine, path: String,
                                      vendors: [VendorRule], home: String)
    -> (SafetyVerdict, SafetyRejection, VendorRule?)
    {
        let (baseVerdict, rejection) = engine.evaluate(path: path, home: home)
        if baseVerdict == .forbid { return (baseVerdict, rejection, nil) }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for rule in vendors {
            for prefix in rule.absolutePathPrefixes(home: home) {
                let std = URL(fileURLWithPath: prefix).standardizedFileURL.path
                if standardized == std {
                    return (.confirm, .ok, rule)
                }
                if standardized.hasPrefix(std + "/") {
                    return (baseVerdict, rejection, rule)
                }
            }
        }
        return (baseVerdict, rejection, nil)
    }

    /// 构造 N 条 vendor，确保 prefix 不会撞 hardForbid 黑名单。
    /// 一半挂在 Application Support，一半挂在 Caches。
    private static func makeVendors(count: Int, seed: UInt64) -> [VendorRule] {
        var rng = SplitMix64(seed: seed)
        var out: [VendorRule] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let token = "Vendor\(i)_\(rng.next() % 100000)"
            if i % 2 == 0 {
                out.append(VendorRule(name: token, appSupportSubdir: token))
            } else {
                out.append(VendorRule(name: token,
                                      cachesPath: "~/Library/Caches/\(token)"))
            }
        }
        return out
    }

    /// 构造 N 条评估用路径，混合：
    /// - 命中 vendor 根
    /// - 命中 vendor 子目录
    /// - 完全无关路径
    /// - 进入 hardForbid 区
    private static func makePaths(home: String, vendors: [VendorRule],
                                  count: Int, seed: UInt64) -> [String] {
        var rng = SplitMix64(seed: seed)
        var out: [String] = []
        out.reserveCapacity(count)
        let unrelated = [
            "\(home)/Documents/x.pdf",
            "\(home)/Library/Caches/com.apple.Safari/file.bin",
            "\(home)/Library/Developer/Xcode/DerivedData/MyApp-abc/Build",
            "/System/Library/Frameworks/Foo",
            "/Applications/Safari.app",
            "\(home)/Movies/clip.mp4"
        ]
        for _ in 0..<count {
            let bucket = rng.next() % 4
            switch bucket {
            case 0: // vendor 根
                let v = vendors[Int(rng.next() % UInt64(vendors.count))]
                out.append(v.absolutePathPrefixes(home: home).first ?? unrelated[0])
            case 1: // vendor 子目录
                let v = vendors[Int(rng.next() % UInt64(vendors.count))]
                let base = v.absolutePathPrefixes(home: home).first ?? unrelated[0]
                out.append("\(base)/sub_\(rng.next() % 1000)/leaf")
            case 2: // 完全无关
                out.append(unrelated[Int(rng.next() % UInt64(unrelated.count))])
            default: // 子目录两层
                let v = vendors[Int(rng.next() % UInt64(vendors.count))]
                let base = v.absolutePathPrefixes(home: home).first ?? unrelated[0]
                out.append("\(base)/x/y/z")
            }
        }
        return out
    }
}

// MARK: - D2 阶段：glob path-rule 集成（通配符场景）

final class VendorTrieGlobTests: XCTestCase {
    private let home = "/Users/foo"
    private let engine = SafetyEngine()

    func test_glob规则不进trie而进globRules() {
        // 含 * 的 path-rule 应被 build() 路由到 root.globRules，不污染 trie 字面量索引
        let pr = PathRule(path: "~/Library/Logs/JetBrains/IntelliJIdea*/idea.log",
                          verdict: .safe)
        let vendor = VendorRule(name: "JetBrains", paths: [pr])
        let root = VendorTrie.build(vendors: [vendor], home: home)

        XCTAssertEqual(root.globRules.count, 1, "glob 规则应进入 globRules 桶")
        XCTAssertTrue(root.children.isEmpty, "glob 规则不应把字面段插入 trie")
    }

    func test_glob命中版本号目录子树() {
        // 模拟 JetBrains 真实场景：每个版本号生成一个独立目录
        let pr = PathRule(path: "~/Library/Logs/JetBrains/IntelliJIdea*",
                          verdict: .safe,
                          reason: "可重新生成的 IDE 日志")
        let vendor = VendorRule(name: "JetBrains", paths: [pr])
        let root = VendorTrie.build(vendors: [vendor], home: home)

        // 命中根（精确匹配）
        let exact = "/Users/foo/Library/Logs/JetBrains/IntelliJIdea2024.3"
        guard let hit1 = VendorTrie.match(standardizedPath: exact, in: root) else {
            return XCTFail("应当 glob 命中精确根 \(exact)")
        }
        XCTAssertTrue(hit1.isExactRoot)
        XCTAssertEqual(hit1.pathOverride?.verdict, .safe)

        // 命中子目录（matchPrefix 分支）
        let sub = "/Users/foo/Library/Logs/JetBrains/IntelliJIdea2024.3/idea.log"
        guard let hit2 = VendorTrie.match(standardizedPath: sub, in: root) else {
            return XCTFail("应当 glob 命中子目录 \(sub)")
        }
        XCTAssertFalse(hit2.isExactRoot)
        XCTAssertEqual(hit2.pathOverride?.verdict, .safe)
    }

    func test_glob不跨段贪婪吞噬() {
        // `*` 不能跨 `/`：声明 ~/Library/Logs/JetBrains/IntelliJIdea*，
        // 不应命中 ~/Library/Logs/JetBrains/Other/IntelliJIdea
        let pr = PathRule(path: "~/Library/Logs/JetBrains/IntelliJIdea*",
                          verdict: .safe)
        let vendor = VendorRule(name: "JetBrains", paths: [pr])
        let root = VendorTrie.build(vendors: [vendor], home: home)

        let cross = "/Users/foo/Library/Logs/JetBrains/Other/IntelliJIdea"
        XCTAssertNil(VendorTrie.match(standardizedPath: cross, in: root),
                     "* 不应跨 / 段贪婪匹配")
    }

    func test_glob命中后仍走evaluate走硬安全网拦截() {
        // 即便 glob 命中并声明 safe，路径若进入硬禁区（如 .git 段），
        // evaluateStandardized 应在 trie/glob 之前先返回 forbid。
        // 这里构造一个会同时命中 glob 与硬禁区的场景。
        let pr = PathRule(path: "~/Library/Logs/JetBrains/*",
                          verdict: .safe)
        let vendor = VendorRule(name: "JetBrains", paths: [pr])
        let root = VendorTrie.build(vendors: [vendor], home: home)

        // 路径里嵌一个 .git/ 段：硬安全网应先拦截
        let dangerous = "/Users/foo/Library/Logs/JetBrains/proj/.git/HEAD"
        let (verdict, rejection, _) = engine.evaluate(path: dangerous,
                                                      trie: root, home: home)
        XCTAssertEqual(verdict, .forbid)
        XCTAssertEqual(rejection, .sensitiveCredential,
                       ".git 段必须由硬安全网先拦下，不能被 glob 的 safe 覆盖")
    }

    func test_glob加载时硬禁区前缀被丢弃() throws {
        // 恶意 yaml：试图通过 ~/Library/Keychains/* 把凭证目录降级为 safe
        let yaml = """
        vendors:
          - name: "MalGlob"
            paths:
              - path: "~/Library/Keychains/*"
                verdict: "safe"
                reason: "试图绕过黄金禁区"
        """
        // 写到临时文件，让 loadVendors 走真实路径
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalGlob_\(UUID().uuidString).yaml")
        try yaml.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loaded = try RuleLoader.loadVendors(from: tmp, home: home,
                                                engine: SafetyEngine())
        XCTAssertTrue(loaded.isEmpty,
                      "字面量前缀 ~/Library/Keychains/ 命中硬禁区 → 整条丢弃")
    }

    func test_glob加载时显式forbid的多重防御保留() throws {
        // 善意 yaml：作者主动把硬禁区下的 glob 也声明 forbid，与硬安全网形成多重防御。
        // 与上一条对比，这条应被保留（因为 verdict==forbid，不是恶意降级）。
        let yaml = """
        vendors:
          - name: "DefenseGlob"
            paths:
              - path: "~/Library/Keychains/*"
                verdict: "forbid"
                reason: "多重防御：连 glob 也禁删"
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefGlob_\(UUID().uuidString).yaml")
        try yaml.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loaded = try RuleLoader.loadVendors(from: tmp, home: home,
                                                engine: SafetyEngine())
        XCTAssertEqual(loaded.count, 1,
                       "verdict==forbid 的多重防御条目应保留")
        XCTAssertEqual(loaded.first?.paths.first?.verdict, .forbid)
    }

    // MARK: - review 高危 #1 回归：跨 vendor 元数据同源

    func test_globHit跨vendor命中时rule与override同源() {
        // 场景：vendor A 仅声明字面量根（trie 命中，但**不**写 path-rule，根走默认 confirm
        // → inheritedOverride == nil，触发 globRules 兜底扫描），
        // vendor B 声明带 glob 的 path-rule。
        // 当扫描路径同时落在 A 的 trie 子树 + B 的 glob 命中时，旧实现会返回
        // (rule = A, override = B.pathOverride) —— 元数据来源不一致：
        // UI 拿到的 vendorName 是 A，但 verdict / reason / recipe 来自 B。
        // 修复后必须返回 (rule = B, override = B.pathOverride)，同源。
        //
        // 真实对照：§2.3 Google vendor 根（仅 bundleIDPrefix，无 path-rule）+
        // 独立 vendor "AndroidStudio" 携带 glob path-rule 的组合。
        // 注意：必须让 vendor A 不带任何 path-rule，否则 inheritedOverride 非 nil，
        // 走的是 trie 直接路径，永远不会触发 globHit 兜底分支。
        let vendorA = VendorRule(
            name: "Google",
            bundleIDPrefix: "com.google.",
            appSupportSubdir: "Google",  // 让 vendor A 通过 absolutePathPrefixes 自动挂 trie 根
                                          // 不写 path-rule → trie 节点 pathOverride==nil
                                          // → inheritedOverride 一路保持 nil
                                          // → 触发 fix-1 的 globHit 兜底分支
            paths: []
        )
        let vendorB = VendorRule(
            name: "AndroidStudio",
            bundleIDPrefix: "com.google.android.studio",
            paths: [
                PathRule(path: "~/Library/Application Support/Google/AndroidStudio*",
                         verdict: .safe,
                         reason: "Android Studio 配置（每次大版本可重建）",
                         recipe: "退出 Studio 后删除")
            ]
        )
        let root = VendorTrie.build(vendors: [vendorA, vendorB], home: home)

        let target = "/Users/foo/Library/Application Support/Google/AndroidStudio2024.1"
        guard let hit = VendorTrie.match(standardizedPath: target, in: root) else {
            return XCTFail("应能命中 \(target)")
        }
        // 关键断言：rule（vendor 名）必须来自 B，不能是 A
        XCTAssertEqual(hit.rule.name, "AndroidStudio",
                       "globHit 命中时 rule 必须替换为 glob 所属 vendor，避免元数据错位")
        // override 也必须来自 B
        XCTAssertEqual(hit.pathOverride?.verdict, .safe)
        XCTAssertEqual(hit.pathOverride?.reason, "Android Studio 配置（每次大版本可重建）")
        XCTAssertEqual(hit.pathOverride?.recipe, "退出 Studio 后删除")
        // 是 glob 的精确根
        XCTAssertTrue(hit.isExactRoot,
                      "AndroidStudio2024.1 与 glob 模板恰好同段数 → isExactRoot")
    }

    func test_globHit命中glob子节点isExactRoot应为false() {
        // 沿用上一条的 vendor B 配置，但路径是 glob 模板的子节点（matchPrefix 分支）。
        let vendorB = VendorRule(
            name: "AndroidStudio",
            paths: [
                PathRule(path: "~/Library/Application Support/Google/AndroidStudio*",
                         verdict: .safe)
            ]
        )
        let root = VendorTrie.build(vendors: [vendorB], home: home)

        let sub = "/Users/foo/Library/Application Support/Google/AndroidStudio2024.1/options/ide.general.xml"
        guard let hit = VendorTrie.match(standardizedPath: sub, in: root) else {
            return XCTFail("应能命中 glob 子节点 \(sub)")
        }
        XCTAssertEqual(hit.rule.name, "AndroidStudio")
        XCTAssertFalse(hit.isExactRoot,
                       "命中的是 glob 子节点而非 glob 模板本身，isExactRoot 必须 false")
        XCTAssertEqual(hit.pathOverride?.verdict, .safe)
    }
}

/// 测试专用伪随机 —— 不依赖 SystemRandomNumberGenerator，
/// 保证 CI 上的可复现性。
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
