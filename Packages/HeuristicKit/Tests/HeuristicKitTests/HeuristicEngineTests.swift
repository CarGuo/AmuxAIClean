import XCTest
import SafetyKit
@testable import HeuristicKit

final class HeuristicEngineTests: XCTestCase {

    // MARK: - helpers

    private let home = "/Users/tester"

    private func makeEngine() -> HeuristicEngine {
        HeuristicEngine(safety: SafetyEngine(), home: home)
    }

    private func ts(_ delta: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + delta)
    }

    // MARK: - 1. 行为累积：trash 多次后 score 上扬

    func testTrashAccumulatesPositiveScore() async {
        let engine = makeEngine()
        let path = "\(home)/Library/Caches/com.acme/blob1.bin"

        let before = await engine.score(path: path)
        XCTAssertEqual(before, 0.0, accuracy: 1e-9, "无信号时 score 应为 0")

        for i in 0..<5 {
            await engine.record(action: .trashedPath(path, timestamp: ts(Double(i))))
        }
        let after = await engine.score(path: path)
        XCTAssertGreaterThan(after, 0.0, "多次 trashed 后 score 应为正")
    }

    // MARK: - 2. score 单调性：trash 越多分越高

    func testScoreMonotonicWithMoreTrashes() async {
        let engine = makeEngine()
        let path = "\(home)/Library/Caches/com.bar/x.tmp"

        var prev = await engine.score(path: path)
        for i in 1...10 {
            await engine.record(action: .trashedPath(path, timestamp: ts(Double(i))))
            let cur = await engine.score(path: path)
            XCTAssertGreaterThanOrEqual(cur, prev, "第 \(i) 次 trash 后 score 不应下降")
            prev = cur
        }
        XCTAssertLessThanOrEqual(prev, 1.0, "score 必须 ≤ 1.0")
    }

    // MARK: - 3. restore 后立刻负分

    func testRestoreImmediatelyTurnsScoreNegative() async {
        let engine = makeEngine()
        let path = "\(home)/Library/Caches/com.baz/maybe-needed.dat"

        // 先 trash 几次累积正分
        for i in 0..<3 {
            await engine.record(action: .trashedPath(path, timestamp: ts(Double(i))))
        }
        let positive = await engine.score(path: path)
        XCTAssertGreaterThan(positive, 0.0)

        // 然后 restore 一次
        await engine.record(action: .restoredPath(path, timestamp: ts(10)))
        let afterRestore = await engine.score(path: path)
        XCTAssertLessThan(afterRestore, 0.0, "restore 之后必须立刻翻成负分")
    }

    // MARK: - 4. forbid 路径永远不输出正分

    func testForbiddenPathNeverGetsPositiveScore() async {
        let engine = makeEngine()
        // /System/... 是 SafetyEngine 硬编码 forbid
        let forbid = "/System/Library/Frameworks/Foo.framework"

        // 即使狂 trash 100 次（理论上不可能发生，但模拟之）
        for i in 0..<100 {
            await engine.record(action: .trashedPath(forbid, timestamp: ts(Double(i))))
        }
        let s = await engine.score(path: forbid)
        XCTAssertLessThanOrEqual(s, 0.0, "forbid 路径 score 必须 ≤ 0")
    }

    func testHomeRootForbiddenNeverPositive() async {
        let engine = makeEngine()
        // home 根目录在 SafetyEngine 里也是 forbid（userDocumentsRoot）
        let forbid = "\(home)/Documents"

        for i in 0..<20 {
            await engine.record(action: .trashedPath(forbid, timestamp: ts(Double(i))))
        }
        let s = await engine.score(path: forbid)
        XCTAssertLessThanOrEqual(s, 0.0, "用户文档根目录永不正分")
    }

    // MARK: - 5. JSON round-trip

    func testJSONPersistAndLoadRoundTrip() async throws {
        let engine = makeEngine()
        let p1 = "\(home)/Library/Caches/com.x/a"
        let p2 = "\(home)/Library/Caches/com.y/b"

        await engine.record(action: .trashedPath(p1, timestamp: ts(1)))
        await engine.record(action: .trashedPath(p1, timestamp: ts(2)))
        await engine.record(action: .restoredPath(p2, timestamp: ts(3)))
        await engine.record(action: .keptPath(p2, timestamp: ts(4)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heuristic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try await engine.persist(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // 新引擎，load 后状态应等价
        let engine2 = makeEngine()
        try await engine2.load(from: url)

        let snap1 = await engine.snapshot()
        let snap2 = await engine2.snapshot()
        XCTAssertEqual(snap1, snap2, "JSON round-trip 后快照必须完全一致")

        // 关键路径 score 也必须一致
        let s1a = await engine.score(path: p1)
        let s2a = await engine2.score(path: p1)
        XCTAssertEqual(s1a, s2a, accuracy: 1e-9)

        let s1b = await engine.score(path: p2)
        let s2b = await engine2.score(path: p2)
        XCTAssertEqual(s1b, s2b, accuracy: 1e-9)
    }

    // MARK: - 6. score 永远在 [-1, 1]

    func testScoreAlwaysInRange() async {
        let engine = makeEngine()
        let p = "\(home)/Library/Caches/com.range/blob"

        // 极端正向
        for i in 0..<10_000 {
            await engine.record(action: .trashedPath(p, timestamp: ts(Double(i))))
        }
        let pos = await engine.score(path: p)
        XCTAssertLessThanOrEqual(pos, 1.0)
        XCTAssertGreaterThanOrEqual(pos, -1.0)

        // 极端负向
        let q = "\(home)/Library/Caches/com.range/q"
        for i in 0..<10_000 {
            await engine.record(action: .restoredPath(q, timestamp: ts(Double(i))))
        }
        let neg = await engine.score(path: q)
        XCTAssertLessThanOrEqual(neg, 1.0)
        XCTAssertGreaterThanOrEqual(neg, -1.0)
        XCTAssertLessThan(neg, 0.0)
    }

    // MARK: - 7. 前缀累积：祖先目录继承子节点统计

    func testAncestorPrefixesAccumulate() async {
        let engine = makeEngine()
        let leaf = "\(home)/Library/Caches/com.prefix/sub/leaf.bin"
        let parent = "\(home)/Library/Caches/com.prefix/sub"
        let grand  = "\(home)/Library/Caches/com.prefix"

        for i in 0..<4 {
            await engine.record(action: .trashedPath(leaf, timestamp: ts(Double(i))))
        }

        let leafEntry   = await engine.snapshotEntry(for: leaf)
        let parentEntry = await engine.snapshotEntry(for: parent)
        let grandEntry  = await engine.snapshotEntry(for: grand)

        XCTAssertEqual(leafEntry?.deletedCount, 4)
        XCTAssertEqual(parentEntry?.deletedCount, 4, "父目录前缀必须继承子节点的 trashed 计数")
        XCTAssertEqual(grandEntry?.deletedCount, 4, "祖父目录前缀同样继承")
    }

    // MARK: - 8. 祖先链上有 restore → 子节点也警惕

    func testRestoreOnAncestorPropagatesNegativeToDescendants() async {
        let engine = makeEngine()
        let ancestor = "\(home)/Library/Caches/com.lineage"
        let child    = "\(home)/Library/Caches/com.lineage/child/file.dat"

        // 子节点 trash 多次 → 通常应该正分
        for i in 0..<5 {
            await engine.record(action: .trashedPath(child, timestamp: ts(Double(i))))
        }
        // 但是祖先发生过一次 restore（用户曾在该 vendor 反悔）
        await engine.record(action: .restoredPath(ancestor, timestamp: ts(100)))

        let s = await engine.score(path: child)
        XCTAssertLessThanOrEqual(s, 0.0, "祖先链上有 restore 时，子节点必须警惕（非正分）")
    }

    // MARK: - 9. kept 提供温和负向，但不会一票否决

    func testKeptIsMildlyNegativeNotForbidding() async {
        let engine = makeEngine()
        let p = "\(home)/Library/Caches/com.kept/x"

        // 单纯 kept 一次 → score 略 < 0
        await engine.record(action: .keptPath(p, timestamp: ts(1)))
        let onlyKept = await engine.score(path: p)
        XCTAssertLessThan(onlyKept, 0.0)

        // 但比 restore 弱很多
        let q = "\(home)/Library/Caches/com.kept/y"
        await engine.record(action: .restoredPath(q, timestamp: ts(1)))
        let onlyRestored = await engine.score(path: q)

        XCTAssertGreaterThan(onlyKept, onlyRestored,
            "kept 的负向力度必须明显弱于 restore")
    }

    // MARK: - 10. ancestorPrefixes 工具函数

    func testAncestorPrefixesUtility() {
        let prefixes = HeuristicEngine.ancestorPrefixes(of: "/A/B/c.log")
        XCTAssertEqual(prefixes, ["/A/B/c.log", "/A/B", "/A"])

        let single = HeuristicEngine.ancestorPrefixes(of: "/Foo")
        XCTAssertEqual(single, ["/Foo"])

        let none = HeuristicEngine.ancestorPrefixes(of: "relative/path")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - 11. 共享容器根不跨 vendor 传染 restore

    func testRestoreDoesNotPoisonUnrelatedVendorViaSharedContainers() async {
        let engine = makeEngine()
        let restoredVendorFile = "\(home)/Library/Caches/com.vendorA/data.bin"
        let unrelatedVendorFile = "\(home)/Library/Caches/com.vendorB/cache.bin"

        await engine.record(action: .restoredPath(restoredVendorFile, timestamp: ts(1)))
        for i in 0..<4 {
            await engine.record(action: .trashedPath(unrelatedVendorFile, timestamp: ts(Double(10 + i))))
        }

        let scoreA = await engine.score(path: "\(home)/Library/Caches/com.vendorA/other.bin")
        let scoreB = await engine.score(path: unrelatedVendorFile)
        XCTAssertLessThan(scoreA, 0.0, "同一 vendor 下的兄弟文件仍应继承 restore 警惕负分")
        XCTAssertGreaterThan(scoreB, 0.0, "不同 vendor 不得因共用 ~/Library/Caches 或 $HOME 而被污染为负分")
        let cachesEntry = await engine.snapshotEntry(for: "\(home)/Library/Caches")
        let homeEntry = await engine.snapshotEntry(for: home)
        XCTAssertNil(cachesEntry, "共享容器 ~/Library/Caches 不应累积跨应用计数")
        XCTAssertNil(homeEntry, "$HOME 根不应累积跨应用计数")
    }

    func testDataVolumeFirmlinkAndAdditionalSharedContainerRoots() async {
        let engine = makeEngine()
        let firmlinkRestored = "/System/Volumes/Data\(home)/Library/HTTPStorages/com.vendorA/http.db"
        let siblingVendor = "\(home)/Library/HTTPStorages/com.vendorB/http.db"

        await engine.record(action: .restoredPath(firmlinkRestored, timestamp: ts(1)))
        for i in 0..<4 {
            await engine.record(action: .trashedPath(siblingVendor, timestamp: ts(Double(10 + i))))
        }

        let scoreA = await engine.score(path: "\(home)/Library/HTTPStorages/com.vendorA/other.db")
        let scoreB = await engine.score(path: siblingVendor)
        XCTAssertLessThan(scoreA, 0.0, "/System/Volumes/Data 录入的 restore 应归一化并传染同 vendor 子项")
        XCTAssertGreaterThan(scoreB, 0.0, "~/Library/HTTPStorages 作为共享容器根不得跨应用传染 restore")
        let httpRootEntry = await engine.snapshotEntry(for: "\(home)/Library/HTTPStorages")
        XCTAssertNil(httpRootEntry, "~/Library/HTTPStorages 根不应累积跨应用计数")
    }
}
