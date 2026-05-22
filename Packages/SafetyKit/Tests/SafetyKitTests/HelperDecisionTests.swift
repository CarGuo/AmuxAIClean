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
}
