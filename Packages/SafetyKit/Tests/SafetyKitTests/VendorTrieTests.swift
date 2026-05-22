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
        XCTAssertLessThan(elapsed, 100.0,
                          "5000 次 evaluate 耗时 \(elapsed)ms 应小于 100ms")
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
