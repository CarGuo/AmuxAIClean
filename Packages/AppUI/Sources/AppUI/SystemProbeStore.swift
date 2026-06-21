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

    /// v2026.06.20 NSWorkspace mount / unmount / app-active 三类通知 token，
    /// 包装在独立 nonisolated 容器里，让 `deinit`（非 MainActor 隔离）能安全释放。
    /// `NotificationTokenBag` 自己的 deinit 会逐个 removeObserver。
    private let tokenBag = NotificationTokenBag()

    /// v2026.06.20 15s 轻量轮询定时器；DispatchSourceTimer 而非 Timer 是因为
    /// Timer 受 RunLoop 模式影响（拖拽窗口时停摆），SourceTimer 走独立 queue，
    /// 主线程 hop 由 [tickPoll](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/SystemProbeStore.swift)
    /// 内显式 `Task { @MainActor in ... }` 完成。
    /// `nonisolated(unsafe)` 因为我们只在 init 写、deinit 读取 cancel，单线程顺序安全。
    private nonisolated(unsafe) var pollTimer: DispatchSourceTimer?

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.fdaStatus = FDAProbe.probe(home: home)
        self.volumeSnapshot = VolumeCapacity.probe()
        self.swapSnapshot = SwapProbe.probe()
        installAutoRefreshHooks()
    }

    deinit {
        // tokenBag.deinit 会触发 removeObserver；pollTimer.cancel 线程安全。
        pollTimer?.cancel()
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
    private func installAutoRefreshHooks() {
        let wsNC = NSWorkspace.shared.notificationCenter

        // v2026.06.21 修复（第三轮，最终版）：
        // 此前两轮分别用 `MainActor.assumeIsolated` / `Task { @MainActor in ... }` /
        // `DispatchQueue.main.async { self?.tickPoll() }` 都未能消灭崩溃：
        //   Thread 8 (com.apple.root.background-qos) → _dispatch_assert_queue_fail
        //   "Block was expected to execute on queue [com.apple.main-thread]"
        // 根因：Swift 6 严格并发模式下，**只要 `@Sendable` closure 捕获 `@MainActor`
        // 隔离类型的 `self`（即便是 [weak self]）**，runtime 在 closure prologue 就会
        // 用 `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue(main)` 校验
        // 当前 executor，在 background queue 上必 trap。
        //
        // 最终方案：让所有 closure **从一开始就跑在 main queue**，根本不需要 hop：
        // 1. NotificationCenter observer 全部 `queue: .main`（OperationQueue.main 投递）
        // 2. closure 内部再 `DispatchQueue.main.async`，把执行从 OperationQueue.main 切到
        //    main dispatch queue —— 这恰好就是 MainActor 的底层执行器，无 trap。
        // 3. **DispatchSourceTimer 的 queue 直接用 `DispatchQueue.main`** 而非 background。
        //    这样 timer event handler 一启动就在 main，self?.tickPoll() 直接调用，
        //    完全绕过 `dispatch_assert_queue` 校验路径。
        //    15s/次 + 仅做 statfs 级 syscall，主线程 < 1ms 抖动，可接受。
        let mountToken = wsNC.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshVolumeCapacity() }
        }
        let unmountToken = wsNC.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshVolumeCapacity() }
        }
        // App becomes active：用户从 Finder 清完回收站切回我们时立即同步。
        let appActiveToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshVolumeCapacity() }
        }
        tokenBag.append(mountToken)
        tokenBag.append(unmountToken)
        tokenBag.append(appActiveToken)

        // 15s 轻量轮询：DispatchSourceTimer 直接挂在 main queue —— 不再下 background。
        // 代价：tick 时主线程多一次 statfs syscall（< 1ms），可忽略。
        // 收益：彻底无 executor hop，无 dispatch_assert_queue trap 风险。
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.tickPoll()
        }
        timer.resume()
        pollTimer = timer
    }

    /// 轮询事件：只在卷容量真的变化时才发 @Published 更新（VolumeCapacity.Snapshot 是 Equatable，
    /// 相等不写入就不广播 → SwiftUI 不重绘）。
    private func tickPoll() {
        let fresh = VolumeCapacity.probe()
        if fresh != volumeSnapshot {
            volumeSnapshot = fresh
        }
        let freshSwap = SwapProbe.probe()
        if freshSwap != swapSnapshot {
            swapSnapshot = freshSwap
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
