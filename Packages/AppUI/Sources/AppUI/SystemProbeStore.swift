import Foundation
import AppKit
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
///
/// **v2026.06.20 实时刷新**（用户反馈"清空回收站 / 删除文件后可用空间不更新"）：
/// 新增三类被动触发，让 `volumeSnapshot` 在不靠手动 refresh 的情况下也能跟住磁盘变化：
/// 1. **NSWorkspace mount/unmount**：插拔外部硬盘 / 网络卷 / DMG 加载卸载——立即重探。
///    （仅给 SSOT 一个机会更新；UI 是否变化由 SwiftUI 的 @Published diff 决定。）
/// 2. **App becomes active**（NSApplication.didBecomeActiveNotification）：用户切回 App 时
///    Finder/其他工具已经清了回收站 / 删了大文件，立即重探一次同步显示。
/// 3. **15s 轻量轮询定时器**：覆盖"App 一直在前台、用户在另一个窗口删文件"的盲区。
///    `URLResourceValues` 不读文件 inode，只查 statfs 级别元数据，CPU < 0.1%，可接受。
///    扫描中也照常跑——重探只更新 `volumeSnapshot`，与扫描 totalBytes 是两个字段，互不打架。
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
    private let refreshBridge = SystemProbeRefreshBridge()

    public convenience init(home: String = NSHomeDirectory()) {
        self.init(home: home, pollInterval: .seconds(15), pollLeeway: .seconds(3), startAutoRefresh: true)
    }

    init(home: String,
         pollInterval: DispatchTimeInterval,
         pollLeeway: DispatchTimeInterval,
         startAutoRefresh: Bool) {
        self.home = home
        self.fdaStatus = FDAProbe.probe(home: home)
        self.volumeSnapshot = VolumeCapacity.probe()
        self.swapSnapshot = SwapProbe.probe()
        self.refreshBridge.store = self
        if startAutoRefresh {
            refreshBridge.installAutoRefreshHooks(pollInterval: pollInterval, pollLeeway: pollLeeway)
        }
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

    /// v2026.06.20 启动 NSWorkspace mount/unmount + App active + 15s 轮询的被动刷新管线。
    /// 只在 init 期间调用一次；所有 source 的生命周期与 store 一致。
    ///
    /// 不挂 FSEventStream 监听根目录：那是 PathScale 级开销（任何 syscall 都会触发回调），
    /// 对"卷可用容量"这种粒度的指标完全过 spec。轻量轮询 15s 已经足以覆盖
    /// "用户清完回收站 → 切回 App"的典型动作链。
    fileprivate func applyVolumeRefresh(_ snapshot: SystemProbeRefreshSnapshot) {
        if snapshot.volume != volumeSnapshot {
            volumeSnapshot = snapshot.volume
        }
        if snapshot.swap != swapSnapshot {
            swapSnapshot = snapshot.swap
        }
    }
}

private struct SystemProbeRefreshSnapshot: Sendable {
    let volume: VolumeCapacity.Snapshot?
    let swap: SwapProbe.Snapshot?
}

private final class SystemProbeRefreshBridge: @unchecked Sendable {
    static let queue = DispatchQueue(label: "com.amux.ai.Clean.system-probe", qos: .utility)

    weak var store: SystemProbeStore?
    private let tokenBag = NotificationTokenBag()
    private var pollTimer: DispatchSourceTimer?

    deinit {
        pollTimer?.cancel()
    }

    func installAutoRefreshHooks(pollInterval: DispatchTimeInterval, pollLeeway: DispatchTimeInterval) {
        let wsNC = NSWorkspace.shared.notificationCenter

        let mountToken = wsNC.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleVolumeRefresh()
        }
        let unmountToken = wsNC.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleVolumeRefresh()
        }
        let appActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleVolumeRefresh()
        }
        tokenBag.append(mountToken)
        tokenBag.append(unmountToken)
        tokenBag.append(appActiveToken)

        // 关键边界：timer handler 必须在非 MainActor 类型里创建。否则 Swift 6 会把
        // @MainActor store 方法中的闭包标成 MainActor executor，在后台 queue 入口 trap。
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: pollLeeway)
        timer.setEventHandler { [weak self] in
            self?.probeAndPublish()
        }
        timer.resume()
        pollTimer = timer
    }

    func scheduleVolumeRefresh() {
        Self.queue.async { [weak self] in
            self?.probeAndPublish()
        }
    }

    private func probeAndPublish() {
        let snapshot = SystemProbeRefreshSnapshot(
            volume: VolumeCapacity.probe(),
            swap: SwapProbe.probe()
        )
        Task { @MainActor [weak self] in
            self?.store?.applyVolumeRefresh(snapshot)
        }
    }
}

/// `SystemProbeStore.deinit` 不在 MainActor 上跑、Swift 6 又禁止从非隔离上下文访问
/// `[any NSObjectProtocol]`（NSObjectProtocol 不 Sendable）。把 token 数组关到独立
/// `nonisolated` 的引用类型里，它自己的 `deinit` 在自己的隔离域里跑就合法了。
/// NotificationCenter 的 `removeObserver` 是线程安全的，可以直接调。
private final class NotificationTokenBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func append(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
