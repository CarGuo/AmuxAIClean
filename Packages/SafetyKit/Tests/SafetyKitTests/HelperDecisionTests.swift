import XCTest
@testable import SafetyKit

/// HelperDecision 单元测试 —— Helper 侧"第三道闸门"。
///
/// 关键场景（按"用户的场景很危险"原则设计）：
/// 1. 默认 allowRealDeletes=false → 永远 dry-run
/// 2. 路径合法 + dryRun=true → dry-run
/// 3. 路径合法 + dryRun=false + 全局开 → real
/// 4. 批内夹带一条非法 → 整批拒（防"夹带私货"攻击）
/// 5. 全部非法 → 在第一个就拒
final class HelperDecisionTests: XCTestCase {

    private let safeHome = "/Users/test"
    private let safePath = "/Users/test/Library/Caches/com.foo.bar"
    private let badPath = "/System/Library/CoreServices"

    func testDefaultDeniesRealDelete() {
        let d = HelperDecision(allowRealDeletes: false)
        let outcome = d.decide(paths: [safePath], dryRun: false, home: safeHome)
        XCTAssertEqual(outcome, .allowDryRun, "全局开关关 → 即便 dryRun=false 也只能 dry-run")
    }

    func testDryRunWhenRequested() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(paths: [safePath], dryRun: true, home: safeHome)
        XCTAssertEqual(outcome, .allowDryRun)
    }

    func testRealDeleteRequiresBothFlags() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(paths: [safePath], dryRun: false, home: safeHome)
        XCTAssertEqual(outcome, .allowReal)
    }

    func testSmugglingRejectsWholeBatch() {
        // 关键安全场景：攻击者把一个合法路径和一个 /System 路径放一起，
        // 期望 Helper "至少删一个就行"。HelperDecision 必须整批拒。
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(paths: [safePath, badPath], dryRun: false, home: safeHome)
        if case .rejectBatch(_, let bad) = outcome {
            XCTAssertEqual(bad, badPath, "应该报告出问题的具体路径")
        } else {
            XCTFail("应该 rejectBatch，实际 \(outcome)")
        }
    }

    func testRejectsHomeRootDelete() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(paths: [safeHome], dryRun: false, home: safeHome)
        if case .rejectBatch = outcome {} else {
            XCTFail("家目录根级别必须拒")
        }
    }

    func testRejectsRelativePath() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(paths: ["relative/path"], dryRun: false, home: safeHome)
        if case .rejectBatch = outcome {} else {
            XCTFail("相对路径必须拒")
        }
    }

    func testRejectsDotDot() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(
            paths: ["/Users/test/Library/Caches/../../../etc/passwd"],
            dryRun: false,
            home: safeHome
        )
        if case .rejectBatch = outcome {} else {
            XCTFail(".. 路径穿越必须拒")
        }
    }

    func testEmptyPathsAllowed() {
        // 空批次本身不算"危险"，让上层自己判
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(paths: [], dryRun: false, home: safeHome)
        XCTAssertEqual(outcome, .allowReal)
    }

    // MARK: - 第四道闸门（v1.3.zzzz Phase 3-E）

    /// paths 里某条与 accessDeniedPaths 完全字面命中 → rejectBatch。
    func testAccessDeniedExactMatchRejectsBatch() {
        let d = HelperDecision(allowRealDeletes: true)
        let denied = "/Users/test/Library/Caches/com.foo.bar"
        let outcome = d.decide(
            paths: [safePath],   // safePath == denied
            dryRun: false,
            accessDeniedPaths: [denied],
            home: safeHome
        )
        if case .rejectBatch(let reason, let bad) = outcome {
            XCTAssertEqual(bad, safePath)
            XCTAssertTrue(reason.contains("accessDenied"), "reason 必须包含 accessDenied 字样：\(reason)")
        } else {
            XCTFail("accessDenied 命中必须 rejectBatch，实际 \(outcome)")
        }
    }

    /// firmlink 折叠：accessDenied 给的是 `/private/var/...` 但 paths 给的是 `/var/...`，仍要命中拒批。
    func testAccessDeniedFirmlinkFoldingRejectsBatch() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(
            paths: ["/var/folders/zz/abc/T/cache.bin"],
            dryRun: false,
            accessDeniedPaths: ["/private/var/folders/zz/abc/T/cache.bin"],
            home: safeHome
        )
        if case .rejectBatch = outcome {} else {
            XCTFail("firmlink 折叠后应命中 accessDenied，实际 \(outcome)")
        }
    }

    /// 反向 firmlink：accessDenied 是 `/var/...`，paths 是 `/private/var/...`，也要命中。
    func testAccessDeniedReverseFirmlinkRejectsBatch() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(
            paths: ["/private/var/folders/zz/abc/T/cache.bin"],
            dryRun: false,
            accessDeniedPaths: ["/var/folders/zz/abc/T/cache.bin"],
            home: safeHome
        )
        if case .rejectBatch = outcome {} else {
            XCTFail("反向 firmlink 折叠应命中，实际 \(outcome)")
        }
    }

    /// accessDeniedPaths 非空但与 paths 不交叉 → 闸门 4 通过，回退到原有 SafetyEngine 流程。
    func testAccessDeniedDisjointFallsThrough() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(
            paths: [safePath],
            dryRun: false,
            accessDeniedPaths: ["/Users/test/Library/SomeOther/path"],
            home: safeHome
        )
        XCTAssertEqual(outcome, .allowReal, "无交集应放行到 allowReal")
    }

    /// 闸门 4 优先级高于闸门 3（SafetyEngine）：当一条路径同时被 SafetyEngine 判 forbid 又在
    /// accessDenied 里时，应先报 accessDenied 原因——便于审计区分"用户没扫成功"与"系统硬黑名单"。
    func testAccessDeniedPriorityOverSafetyEngine() {
        let d = HelperDecision(allowRealDeletes: true)
        let outcome = d.decide(
            paths: [badPath],
            dryRun: false,
            accessDeniedPaths: [badPath],
            home: safeHome
        )
        if case .rejectBatch(let reason, _) = outcome {
            XCTAssertTrue(reason.contains("accessDenied"),
                          "应先报 accessDenied，实际：\(reason)")
        } else {
            XCTFail("应 rejectBatch")
        }
    }

    /// 空 accessDeniedPaths 行为完全等价于不传——保证向后兼容。
    func testEmptyAccessDeniedEquivalentToOmitted() {
        let d = HelperDecision(allowRealDeletes: true)
        let withEmpty = d.decide(paths: [safePath], dryRun: false,
                                 accessDeniedPaths: [], home: safeHome)
        let withoutArg = d.decide(paths: [safePath], dryRun: false, home: safeHome)
        XCTAssertEqual(withEmpty, withoutArg)
    }
}
