import XCTest
@testable import AppUI

/// v2026.07.18：Brew Installed / Outdated / Cleanup 共用 reload owner。
/// 这些测试不读取真实 Homebrew 目录，只验证迟到任务永远不能覆盖新值或提前关闭 spinner。
final class BrewReloadGateTests: XCTestCase {
    func test_旧owner迟到终态不能claim新owner() {
        var gate = BrewReloadGate()
        let old = BrewReloadIdentity(ownerID: UUID(), revision: 1, kind: .installed)
        let current = BrewReloadIdentity(ownerID: UUID(), revision: 2, kind: .outdated)
        gate.begin(old)
        gate.begin(current)

        XCTAssertNil(gate.finishIfCurrent(
            old,
            visibleKind: .outdated,
            taskWasCancelled: true
        ))
        XCTAssertEqual(gate.current, current,
                       "旧 Installed 任务不能清除新 Outdated owner 或提前关闭其 spinner")
        XCTAssertEqual(gate.finishIfCurrent(
            current,
            visibleKind: .outdated,
            taskWasCancelled: false
        ), true)
        XCTAssertNil(gate.current)
    }

    func test_当前owner取消后收敛但不发布结果() {
        var gate = BrewReloadGate()
        let identity = BrewReloadIdentity(ownerID: UUID(), revision: 7, kind: .installed)
        gate.begin(identity)

        XCTAssertEqual(gate.finishIfCurrent(
            identity,
            visibleKind: .installed,
            taskWasCancelled: true
        ), false)
        XCTAssertNil(gate.current)
    }

    func test_tab变化后即使任务未观察取消也拒绝发布() {
        var gate = BrewReloadGate()
        let identity = BrewReloadIdentity(ownerID: UUID(), revision: 9, kind: .outdated)
        gate.begin(identity)

        XCTAssertEqual(gate.finishIfCurrent(
            identity,
            visibleKind: .cleanup,
            taskWasCancelled: false
        ), false)
        XCTAssertNil(gate.current)
    }

    func test_onDisappear先invalidate后迟到终态没有状态权限() {
        var gate = BrewReloadGate()
        let identity = BrewReloadIdentity(ownerID: UUID(), revision: 11, kind: .installed)
        gate.begin(identity)
        gate.invalidate()

        XCTAssertNil(gate.finishIfCurrent(
            identity,
            visibleKind: .installed,
            taskWasCancelled: false
        ))
        XCTAssertNil(gate.current)
    }
}
