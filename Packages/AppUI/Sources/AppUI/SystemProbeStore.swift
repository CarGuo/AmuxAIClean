import Foundation
import ScanKit

/// Step 10a / 2026-06：系统探针 SSOT。
///
/// 把 [ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
/// 早期内嵌的三个独立探针字段（FDA 授权状态 / 卷容量 / swap 占盘）抽到独立 store，
/// 让 banner / VolumeCapacityCard / FloatingScanHUD 可以**单独订阅它**，
/// 而不再被 ScanCoordinator 上每次扫描 ingest 的高频 `objectWillChange` 波及。
///
/// 设计：
/// 1. `@MainActor` + `ObservableObject` —— 与 ScanCoordinator 同 actor，
///    两者交互无 hop，`refreshFDAStatus()` 的调用零异步。
/// 2. 三个字段都 `@Published private(set)`，写入只能经由本 store 的方法（refresh*）
///    或 ScanCoordinator 显式同步（`syncFromCoordinatorRefresh()`）。
/// 3. **不**注入到 SwiftUI 全局环境；ScanCoordinator 暴露
///    [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
///    属性，下游 view 可以选择新订阅 `coordinator.systemProbe.fdaStatus`（细粒度）
///    或继续用 `coordinator.fdaStatus`（forwarding 镜像，向后兼容）。
@MainActor
public final class SystemProbeStore: ObservableObject {
    /// FDA（完全磁盘访问）授权状态。启动时探测一次，之后由 [refreshFDAStatus()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SystemProbeStore.swift#L43-L48)
    /// 重探（用户从系统设置回到 App 时调用）。
    @Published public private(set) var fdaStatus: FDAProbe.Status

    /// 磁盘卷容量信息（"X GB of Y GB used"）。启动 / 扫描完成 / 删除完成后刷新。
    @Published public private(set) var volumeSnapshot: VolumeCapacity.Snapshot?

    /// macOS swap + sleepimage 占盘探测（仅展示，不参与清理）。
    /// 与 [volumeSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SystemProbeStore.swift#L29-L29)
    /// 共用刷新时机。
    @Published public private(set) var swapSnapshot: SwapProbe.Snapshot?

    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.fdaStatus = FDAProbe.probe(home: home)
        self.volumeSnapshot = VolumeCapacity.probe()
        self.swapSnapshot = SwapProbe.probe()
    }

    /// 用户从系统设置回到 App 后调用，重探 FDA 状态与卷容量。
    public func refreshFDAStatus() {
        fdaStatus = FDAProbe.probe(home: home)
        volumeSnapshot = VolumeCapacity.probe()
        swapSnapshot = SwapProbe.probe()
    }

    /// 每次扫描完成 / 删除完成后调用，重探卷容量（FDA 不变就不动）。
    public func refreshVolumeCapacity() {
        volumeSnapshot = VolumeCapacity.probe()
        swapSnapshot = SwapProbe.probe()
    }
}
