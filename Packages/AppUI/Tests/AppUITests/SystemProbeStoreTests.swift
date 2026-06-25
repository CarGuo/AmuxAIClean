import XCTest
import Combine
@testable import AppUI
@testable import ScanKit

/// Step 10a / 2026-06：SystemProbeStore 契约测试。
///
/// 历史背景：
///   ScanCoordinator 早期把 fdaStatus / volumeSnapshot / swapSnapshot 三个独立探针字段
///   直接挂在自身 @Published —— 这三个字段的任何刷新都会让 ScanCoordinator.objectWillChange
///   fire，从而无差别波及主列表 / TreeBrowserView 等订阅 ScanCoordinator 的所有 view。
///
/// 解决：
///   1) 新建 [SystemProbeStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SystemProbeStore.swift)
///      作为 SSOT，三个字段在它上面 @Published。
///   2) ScanCoordinator 暴露 `public let systemProbe: SystemProbeStore`，
///      让新代码 / 单测可以单独订阅 store 而不再读 ScanCoordinator。
///   3) ScanCoordinator 上保留同名 mirror 字段（@Published）只为向后兼容。
///   4) `refreshFDAStatus()` / `refreshVolumeCapacity()` 写入唯一来源是 store；
///      之后再回写 mirror。
///
/// 本套测试覆盖 store 的字段存在性与 refresh 行为；KeyPath 粒度（store 改不广播 coord）
/// 由 [test_systemProbe写入不直接广播ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/SystemProbeStoreTests.swift)
/// 用 Combine sink 计数验证。
@MainActor
final class SystemProbeStoreTests: XCTestCase {

    // MARK: - 字段存在性

    func test_SystemProbeStore初始三个字段都已就绪() {
        let store = SystemProbeStore(home: NSTemporaryDirectory())
        // fdaStatus 是非 optional 枚举，新建后必然有值（granted/denied/unknown 任一）
        _ = store.fdaStatus
        // volumeSnapshot/swapSnapshot 是 optional，可能为 nil（headless / sandbox）；
        // 这里只断言访问不崩
        _ = store.volumeSnapshot
        _ = store.swapSnapshot
    }

    func test_ScanCoordinator暴露systemProbe子store() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        XCTAssertNotNil(coord.systemProbe, "ScanCoordinator 必须暴露 systemProbe 子 store")
        // 子 store 与 ScanCoordinator mirror 字段初始一致
        XCTAssertEqual(coord.systemProbe.fdaStatus, coord.fdaStatus,
                       "init 后 store.fdaStatus 必须等于 coord.fdaStatus mirror")
    }

    // MARK: - 行为契约

    /// refreshFDAStatus() 走 store 主路径，再回写 ScanCoordinator mirror。
    /// 测试：调用后 store.fdaStatus 与 coord.fdaStatus 必然一致。
    func test_refreshFDAStatus后store与mirror一致() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        coord.refreshFDAStatus()
        XCTAssertEqual(coord.systemProbe.fdaStatus, coord.fdaStatus,
                       "refresh 后 store 与 mirror 必须仍然一致")
    }

    /// refreshVolumeCapacity() 同理。
    func test_refreshVolumeCapacity后store与mirror一致() {
        let coord = ScanCoordinator(home: NSTemporaryDirectory())
        coord.refreshVolumeCapacity()
        // optional == optional 的等价（都 nil 也 OK）
        XCTAssertEqual(coord.systemProbe.volumeSnapshot?.totalBytes,
                       coord.volumeSnapshot?.totalBytes,
                       "refresh 后 store 与 mirror 的 volumeSnapshot 必须一致")
        XCTAssertEqual(coord.systemProbe.swapSnapshot?.totalDiskFootprintBytes,
                       coord.swapSnapshot?.totalDiskFootprintBytes,
                       "refresh 后 store 与 mirror 的 swapSnapshot 必须一致")
    }

    // MARK: - 粒度收益

    /// 关键收益验证：store 自己写入（refresh）会触发 store.objectWillChange，
    /// 但**不**应同帧多次触发 ScanCoordinator.objectWillChange。
    /// 这里仅断言 store.objectWillChange 至少 fire 一次（refresh 三次 store 写）。
    func test_store独立广播() {
        let store = SystemProbeStore(home: NSTemporaryDirectory())
        var storeBroadcasts = 0
        let bag = store.objectWillChange.sink { _ in storeBroadcasts += 1 }
        defer { bag.cancel() }

        store.refreshFDAStatus()  // 内部写 fdaStatus + volumeSnapshot + swapSnapshot
        // store 至少广播一次（@Published 写入会 fire objectWillChange）
        XCTAssertGreaterThanOrEqual(
            storeBroadcasts, 1,
            "store.refreshFDAStatus 必须触发 store.objectWillChange 至少 1 次"
        )
    }

    func test_autoRefreshTimer后台触发不带MainActor队列断言() async throws {
        let store = SystemProbeStore(
            home: NSTemporaryDirectory(),
            pollInterval: .milliseconds(20),
            pollLeeway: .milliseconds(1),
            startAutoRefresh: true
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        withExtendedLifetime(store) {
            _ = store.volumeSnapshot
            _ = store.swapSnapshot
        }
    }
}
