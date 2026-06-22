import Foundation
import LogKit
import ScanKit
import SafetyKit

/// 扫描协调器 —— UI 与 BulkScanner 之间的"减压阀"。
///
/// 设计目标（每条都来自 PITFALLS §5）：
/// - **聚合到一级子目录**：4 万文件 yield 进 SwiftUI List 主线程必崩
/// - **节流 commit**：≥150ms 才发一次 snapshot；每条 .node 直接更新 state 是错的
/// - **按 size 实时排名**：每次 commit 重排，但发现期不动 row identity
/// - **SafetyEngine 内嵌**：每个一级子目录拿到 verdict，UI 直接渲染徽章
/// - **节流期总字节优先稳定**：UI 上的"已扫 X MB"不能跳变
@MainActor
public final class ScanCoordinator: ObservableObject {
    @Published public private(set) var snapshot: ScanSnapshot = .empty
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var permissionDeniedPaths: [String] = []
    /// v1.1：因 TCC 雷区（Music / Photos / Mail 等）被主动 skip 的路径列表。
    /// 与 permissionDeniedPaths 合并展示在统一 banner，**不会触发系统弹窗**。
    @Published public private(set) var tccProtectedSkippedPaths: [String] = []

    /// v1.3 P0-D：开发者构建产物勘察是否触发了截断（命中数达上限 或 walk 超时）。
    /// UI 在 dev 扫描结果区可读此标志展示 banner："命中过多，仅展示前 N 项"。
    /// 仅在 scanDeveloper 路径上有意义；其他扫描入口启动时会被清零。
    @Published public private(set) var devArtifactDidTruncate: Bool = false
    @Published public private(set) var devArtifactDidTimeout: Bool = false

    /// M4-T1：本轮扫描启动时从 [WhitelistStore.shared](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/WhitelistStore.swift)
    /// 拉一份的内存快照（normalized 后的 path Set）。publishSnapshot 是同步函数，
    /// 不能在 hot path 里 `await` 一个 actor —— 因此扫描入口拉一次快照，全程同步命中。
    /// 命中判定与 WhitelistStore.isWhitelisted 一致：完全相等 或 entry+"/" 作为 path prefix。
    private var whitelistSnapshot: Set<String> = []

    /// v1.3：主列表（推荐清理 / 自定义路径）排序键。默认 `.sizeDesc`（按大小从大到小）。
    ///
    /// - 切换时立刻重发当前 snapshot，UI 列表实时按新排序刷新（不需要重扫）。
    /// - **仅作用于扫描完成态（finished=true）**；扫描进行中 publishSnapshot 强制按 path 字典序，
    ///   避免最大 bucket 永远霸占第一行造成"只一行在动"错觉（v1.3 publishSnapshot 注释有详细背景）。
    /// - 由 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    ///   在启动时与 onChange 时从 [AppSettings.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    ///   同步过来。
    @Published public var mainListSortKey: MainListSortKey = .sizeDesc {
        didSet {
            guard oldValue != mainListSortKey else { return }
            // 切换排序键即重发 snapshot，让 List 立刻按新顺序排
            // 仅当扫描已结束（finished=true）时才让排序生效；扫描中保持 path 字典序
            guard let categoryID = activeCategoryID ?? lastFinishedCategoryID,
                  snapshot.isFinished else { return }
            publishSnapshot(categoryID: categoryID, finished: true)
        }
    }
    private var lastFinishedCategoryID: String?

    /// 当前/最近一次扫描的根路径；`nil` 表示尚未发起任何扫描（notStarted 态）。
    /// UI 用它在 `finishedEmpty(rootPath:)` 三态里显示具体目录，避免硬编码 `~/Library/Caches`。
    @Published public private(set) var currentRootPath: String?

    /// v1.3：FDA（完全磁盘访问）探测结果。
    /// - `granted`：用户已在系统设置勾选了本 App，扫描不再硬 skip TCC 雷区，banner 不显示
    /// - `denied` / `unknown`：保持保守 skip 行为，banner 仍可能显示
    /// 启动时探测一次；`refreshFDAStatus()` 让 UI（如从设置回到 App）能手动重探。
    @Published public private(set) var fdaStatus: FDAProbe.Status

    /// v1.3：磁盘卷容量信息（"482.95 GB of 494.38 GB used"）。
    /// 启动时探一次，每次扫描完成 / 删除完成后再探一次（容量是系统数据，需要重新读）。
    @Published public private(set) var volumeSnapshot: VolumeCapacity.Snapshot?

    /// v1.3.x：macOS 用了多少**硬盘空间**当虚拟内存（swap）+ 休眠镜像（sleepimage）。
    /// 与 [volumeSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L55-L55)
    /// 共用同一刷新时机：启动 / 扫描完成 / 删除完成。
    /// 仅供 UI 只读展示——swap 与 sleepimage 由内核管理，App 不应清理。
    @Published public private(set) var swapSnapshot: SwapProbe.Snapshot?

    /// v1.3：上一次扫描是否被用户主动 cancel 而中断。
    /// statusBar 借此把"已停止"与"还未扫描"区分开——
    /// 不区分会让用户以为按下停止后什么都没干。
    /// 任何新 scan 入口启动时清回 false。
    @Published public private(set) var wasCancelled: Bool = false

    /// v1.3：多根并行扫描时每根的进度信息。key=rootPath。
    /// - 单根扫描入口（scan/scanFullDisk）保持空 dict —— UI 据此回退到老的"扫描中… N 个文件 · X MB"单行；
    /// - 多根扫描入口（scanRecommended）会预填 5 条（每根一条）isFinished=false，
    ///   每收到一条 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
    ///   按 rootPath 累加 bytes / fileCount；该根 .finished 事件到达时翻 isFinished=true。
    /// v1.3.zz 性能修复：每文件不再直接写 @Published（每写都触发 SwiftUI 全 view 重算），改成
    /// 写到 perRootStaging（普通字典），由 publishSnapshot（throttle 0.4s）批量同步到这里。
    ///
    /// v1.5 P1-B 性能修复：旧实现是整个 dict 替换 → SwiftUI 把 statusBar / 多根 ScrollView
    /// 大面积重 diff。dev scan 几十/几百根时极其卡。改为拆分为两份 @Published：
    /// - [perRootProgressActive](#)：仅 in-flight（isFinished==false）的根，体量小、变化频繁；
    /// - [perRootFinishedSlim](#)：已 finished 的根的轻量快照，体量随完成数增长但每个根只 push 一次；
    /// - [perRootFinishedCount](#)：finished 数量，方便 UI 只看个数变化触发刷新。
    /// 本字段保留为只读计算属性合并两者，让现有读取者（树形顶层合成 / status banner）无须改动。
    public var perRootProgress: [String: PerRootProgress] {
        if perRootFinishedSlim.isEmpty { return perRootProgressActive }
        if perRootProgressActive.isEmpty { return perRootFinishedSlim }
        return perRootProgressActive.merging(perRootFinishedSlim) { active, _ in active }
    }

    /// v1.5 P1-B：in-flight 根的进度。throttle 同步时只触达"还在扫"的根，整体重 diff 面收敛。
    @Published public private(set) var perRootProgressActive: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：已 finished 根的轻量快照（保留 bytes/fileCount/title 用于树形顶层），
    /// 每根 finish 时一次性 push，之后不再变化 —— SwiftUI 对该字典的子树渲染会稳定下来。
    @Published public private(set) var perRootFinishedSlim: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：已 finished 根的数量。便于 UI 只关心数量变化（例如显示 "3/5 已完成"）时，
    /// 避免依赖整 dict 触发重 diff。
    @Published public private(set) var perRootFinishedCount: Int = 0

    /// v2026.06.22 perf：UI 展示用的「已按 rootPath 字典序预排序」的数组形态。
    ///
    /// 背景（trace 6.67 s，主线程 NSHostingView.layout 778 ms）：
    /// 旧实现在 [statusBar L1549](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1549)
    /// 每帧 body 重 eval 都跑一次 `perRootProgress.values.sorted(by: { $0.rootPath < $1.rootPath })`：
    ///   - sort 几百根 String 字典序比较：~10 ms（_stringCompare 链）
    ///   - sort 闭包带 MainActor 上下文：每对比较都触发 `swift_task_isCurrentExecutor` ~6 ms
    ///   - 总计 statusBar.getter 单帧 44.3 ms，60fps 滚动直接吃光 frame budget。
    ///
    /// 现在：在 syncPerRootPublished 同步点一次性排序好，UI 直接读，零 sort。
    /// 由于 perRootProgressActive + perRootFinishedSlim 已经 @Published（throttle 0.4s
    /// 才更新），这个数组的更新频率天然就被 throttle 住——比每帧 sort 收益大几个量级。
    @Published public private(set) var perRootProgressSorted: [PerRootProgress] = []

    /// v1.3.zz 性能修复用：staging 累计区，每 .node 事件直接累计这里，避开 @Published 触发 SwiftUI invalidation。
    /// publishSnapshot 节流点会把它同步到 perRootProgress（0.4s 一次）。
    private var perRootStaging: [String: PerRootProgress] = [:]

    /// v1.5 P1-B：把 staging 字典拆分同步到 active / finishedSlim / finishedCount。
    /// - 仅当 active / finishedSlim 真的变化时才 assign，避免无谓 willChange。
    /// - finishedSlim 的 key set 单调增（finish 后不会回到 in-flight），所以只比 count 就够。
    private func syncPerRootPublished(from staging: [String: PerRootProgress]) {
        var nextActive: [String: PerRootProgress] = [:]
        nextActive.reserveCapacity(staging.count)
        var nextFinishedCount = 0
        var newlyFinished: [(String, PerRootProgress)] = []
        for (k, v) in staging {
            if v.isFinished {
                nextFinishedCount += 1
                // 与已有 slim 不同才记下，避免无谓写入
                if perRootFinishedSlim[k] != v {
                    newlyFinished.append((k, v))
                }
            } else {
                nextActive[k] = v
            }
        }
        if perRootProgressActive != nextActive {
            perRootProgressActive = nextActive
        }
        if !newlyFinished.isEmpty {
            var slim = perRootFinishedSlim
            for (k, v) in newlyFinished { slim[k] = v }
            perRootFinishedSlim = slim
        }
        if perRootFinishedCount != nextFinishedCount {
            perRootFinishedCount = nextFinishedCount
        }

        // v2026.06.22 perf：同步维护 sorted 数组（UI 直接读，零 sort）。
        // staging 是合并后的最终态；这里就一次性按 rootPath 字典序排好。
        // 仅当真的变化才 assign，避免无谓 willChange / SwiftUI 重 diff。
        let nextSorted = staging.values.sorted(by: { $0.rootPath < $1.rootPath })
        if perRootProgressSorted != nextSorted {
            perRootProgressSorted = nextSorted
        }
    }

    /// v1.5 P1-B：完整重置三份 @Published（用于 cancel / 重新预填）。
    private func resetPerRootPublished() {
        if !perRootProgressActive.isEmpty { perRootProgressActive = [:] }
        if !perRootFinishedSlim.isEmpty { perRootFinishedSlim = [:] }
        if perRootFinishedCount != 0 { perRootFinishedCount = 0 }
        if !perRootProgressSorted.isEmpty { perRootProgressSorted = [] }
    }

    /// 单根的实时进度快照。
    /// - title：UI 直接展示的中文友好名（取自 ScanCategory.title），如"用户缓存"/"应用日志"；
    /// - bytes / fileCount：该根累计已扫到的字节与文件数；
    /// - isFinished：该根的 BulkScanner 是否已 yield 过 .finished。多根全部 isFinished=true 时
    ///   stream 关闭，runMultiRootScan 自身把 isScanning 翻 false。
    public struct PerRootProgress: Sendable, Equatable {
        public let rootPath: String
        public let title: String
        public var bytes: Int64
        public var fileCount: Int
        public var isFinished: Bool
        public init(rootPath: String, title: String,
                    bytes: Int64 = 0, fileCount: Int = 0, isFinished: Bool = false) {
            self.rootPath = rootPath
            self.title = title
            self.bytes = bytes
            self.fileCount = fileCount
            self.isFinished = isFinished
        }
    }

    /// v1.3：多根并行扫描的特殊 categoryID 哨兵，与 ScanCategory.id 解耦。
    /// runScan 的 activeCategoryID 校验沿用此值；UI 不应依赖它做业务判断（用 perRootProgress 判更可靠）。
    public static let multiRootCategoryID: String = "recommended.multi"

    /// v1.4：开发者构建产物多根并行扫描的 categoryID 哨兵。与 multiRootCategoryID 区分，
    /// 让 UI 可以渲染不同标题（"开发者构建产物" vs "全部推荐扫描"），但底层 runMultiRootScan 共用。
    public static let developerCategoryID: String = "developer.multi"

    /// v1.5：多根扫描时 [currentRootPath](#) 设为这两个伪路径之一，给 UI 占位
    /// （树形/finishedEmpty 等场景需要一个非 nil 值）。这两个值不是真实目录，
    /// store 里也不会有"以它们为父"的子项；树形视图遇到它们时要走「合成多根顶层」分支
    /// （见 [directChildren(of:sortedBy:)](#)），把 perRootProgress 的真实根升级成顶层 TreeRow。
    ///
    /// v2026.06.21：原值为中文字面（"(多目录)" / "(开发者构建产物)" / "(开发者旧版本)"），
    /// 由于 [placeholder(for:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift#L1572)
    /// 的 `.finishedEmpty(rootPath)` 分支会直接 `Text(rootPath)` 给英文用户看，
    /// 那相当于英文 UI 露出三个中文 token。统一改成纯英文 sentinel ID（带双下划线前后缀，
    /// 不会与任何真实文件路径冲突），UI 侧检测到 sentinel 后走 `path.sentinel.*`
    /// xcstrings key 走本地化显示。
    public static let multiRootSentinelPath: String = "__sentinel_multi_root__"
    public static let developerSentinelPath: String = "__sentinel_dev_artifact__"
    public static let versionedRootSentinelPath: String = "__sentinel_versioned_root__"
    public static let multiRootSentinelPaths: Set<String> = [
        multiRootSentinelPath, developerSentinelPath, versionedRootSentinelPath
    ]

    /// 便利属性 —— 转发自 `snapshot.isFinished`，
    /// 让 UI 可以直接 `coordinator.isFinished` 判断三态，不必每处都写 `coordinator.snapshot.isFinished`。
    public var isFinished: Bool { snapshot.isFinished }

    private let engine = SafetyEngine()
    private let vendors: [VendorRule]
    private let home: String
    /// 预构建的 VendorTrie —— 性能关键：
    /// `publishSnapshot` 每帧（≥150ms）会对 N 个 bucket 调 `engine.evaluate`。
    /// 朴素 `evaluate(path:vendors:home:)` 内部**每次都重建 trie**（含 ~42 条 path-rule
    /// 的 `URL.standardizedFileURL` —— 系统调用级开销），整盘扫 buckets ~100+ 时
    /// 实测每秒重建上百次 trie，把主线程 publishSnapshot 拖到 50–200ms 一帧，
    /// 反向阻塞 BulkScanner 的 unbounded continuation.yield → 看起来"线扫描很慢"。
    /// 这里一次构建、扫描期间复用，evaluate 走 trie 版 O(路径深度) 路径。
    /// vendors 在 init 时就锁定，扫描期不会动；用 lazy + `let` 等价的 stored property 即可。
    private let trie: VendorTrieNode
    private var scanTask: Task<Void, Never>?

    /// v1.3.x（M1 内存优化）：扫描结果落盘后端。可选注入；nil 表示走"全量内存"原行为。
    /// 开启路径：[AppSettings.useScanStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 在 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// 启动时根据 flag 决定是否注入 [GRDBScanResultStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift)。
    public let resultStore: ScanResultStore?

    /// 当前扫描会话 ID。每次 scan() / scanRecommended() 入口生成一个新的。
    /// 写入 store 时全部携带这个 sessionID，evict 时按 session 删除。
    public private(set) var currentSessionID: ScanSessionID?

    /// 写入 store 的 batch 缓冲区。达到 [ScanCoordinator.storeFlushBatchSize](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 即异步 flush 一次。仅在 resultStore != nil 时写入。
    private var storeBatch: [ScanResultRecord] = []
    /// 每 1000 条 flush 一次——经验值：太小频繁写、太大主线程内存抖。
    private let storeFlushBatchSize = 1000
    /// store 是否处于"健康"状态：任何一次 insert / begin 失败即 false，后续写入静默跳过，
    /// 不能让 store 故障污染主扫描流程（功能正常优先于内存优化）。
    private var storeHealthy: Bool = true

    /// P0-B 修复：store 写盘任务的 daisychain 头。
    /// flushStoreBatch / flushAndFinalizeStore 都把自己的工作 append 到这条链尾，
    /// 保证 insert / finalize **严格按调用顺序**到达 store actor。
    /// 修复前两个 detached Task 互相竞争 actor 入队顺序——可能 finalize 先于 in-flight insert。
    private var storeWriteChain: Task<Void, Never>?

    /// v1.3：当前"活跃"的 categoryID。
    /// 防 [坑 1]：旧 scan 被 cancel 后，AsyncStream 缓冲里残留的 .node 事件仍可能被旧 for-await
    /// 循环消费一两轮（cancel 的传播是协作式，不是抢占式）。如果不带本次 token，
    /// 旧 ingest 会把数据写到刚被新 scan 重置过的 buckets/dirIndex 上，污染新 categoryID 的 snapshot。
    /// runScan 的每次事件处理之前先校验 `myCategoryID == activeCategoryID`，不一致直接 break。
    /// v1.3 P0-D：暴露 read-only 给 UI 用于判断 banner 上下文（仍是内部更新）。
    public private(set) var activeCategoryID: String?

    /// 一级子目录 -> 累计统计；用 path 作 key 保证稳定。
    private struct Bucket {
        var url: URL
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var isDirectory: Bool
        /// v1.5.4：bucket（一级聚合行 = 一级子目录或单个顶层文件）自身 inode 的 mtime。
        ///
        /// 仅在 isTopLevelBucket=true 时写入——即 BulkScanner 真的 yield 出该 bucket 自己的
        /// node entry（首次 ingest 一定会触发），所以扫完一定有值，无需额外探测。
        /// 为什么不维护"max(子孙 mtime)"：见 [RowItem.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L33) 文档——
        /// Finder 风格目录 mtime = 目录 inode 自身 mtime（在该目录里增删文件即由内核更新）。
        var modificationDate: Date? = nil

        /// Step 3 P0-3 / 2026-06：bucket 节点的 SafetyEngine.evaluate 结果缓存。
        ///
        /// 为什么这里能 cache：bucket 的 key 是 `path: String`，永久不变；`engine` 自身、
        /// vendor `trie` 与 `home` 在 ScanCoordinator 的生命周期里都是 `let` immutable —— 
        /// 所以同一 path 的 evaluate 结果**永远相同**。
        ///
        /// 旧 publishSnapshot 每帧（流式扫描 0.4s/帧）都对全部 N 个 bucket 调一次
        /// evaluate(trie:)。一次扫描扫到 K=数百~数千 bucket，× 数十帧，多出几千~几十万次
        /// 主线程纯函数调用 —— 对 Tree View 就是直接的卡顿源。
        ///
        /// 缓存策略：首次 publishSnapshot 看到该 bucket 时算一次写回；之后命中直接读。
        /// `nil` = 还没算过；非 nil = 已经算过且永远有效（因 cache 失效条件不存在 ——
        /// startScan/rescan/cancel 会整个 buckets.removeAll()，cache 字段自然消失）。
        var cachedVerdict: SafetyVerdict? = nil
        var cachedRejection: SafetyRejection? = nil
        var cachedVendor: VendorRule? = nil

        /// v1.3.z 性能优化：把 ingest hot path 的 read-modify-write 收敛进 Bucket 自身。
        /// 配合 `buckets[k, default: ...].applyIngest(...)` 让 hit 路径只走一次哈希查找，
        /// 且 hit 时不构造 default 值（autoclosure 不求值）。
        mutating func applyIngest(
            isFileNode: Bool,
            isTopLevelBucket: Bool,
            isDirEffective: Bool,
            bytes nodeBytes: Int64,
            logicalBytes nodeLogical: Int64,
            nodeMTime: Date? = nil
        ) {
            if isFileNode {
                bytes += nodeBytes
                logicalBytes += nodeLogical
                fileCount += 1
            }
            // 顶层 bucket 自身可能是文件（极少见），保留 isDirectory 信息
            if isTopLevelBucket {
                isDirectory = isDirEffective
                if !isDirEffective {
                    bytes += nodeBytes
                    logicalBytes += nodeLogical
                    fileCount = 1
                }
                // 仅在确实拿到 mtime 时覆盖；保留已有值避免被空帧清零
                if let m = nodeMTime {
                    modificationDate = m
                }
            }
        }
    }
    private var buckets: [String: Bucket] = [:]

    /// v1.3：每个 bucket 最近一次有 ingest 写入的时间戳（reference time interval）。
    ///
    /// 用法：publishSnapshot 时计算 `now - lastIngestAt[bucketPath] < activityWindow` 即视为 active，
    /// 写到 [RowItem.isActive](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L24)；
    /// UI（[ScanRow](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanRow.swift)）
    /// 据此给 bytes 数字上色 + 脉动。
    ///
    /// 为什么这样设计：BulkScanner 的 6 worker 在不同子树并发枚举时，每个 worker yield .node 进 ingest
    /// 都会落到对应 bucketPath（一级祖先），所以"哪些 bucket 最近有数据进来"= "哪些子树正在被扫"。
    /// 不需要额外的 worker → bucket 通知通道，零侵入到 ScanKit。
    private var lastIngestAt: [String: TimeInterval] = [:]

    /// v1.3：active 判定窗口。最近 N 秒内有 ingest 即视为正在扫描。
    /// 800ms 是经验值——大于 BulkScanner 默认 progress 节流（150ms）的若干倍，能容忍小的 ingest 间隙；
    /// 又显著小于"扫一个普通子目录的耗时"（通常 1~10s），不会让停掉的 bucket 持续假亮。
    private let activityWindow: TimeInterval = 0.8

    /// v1.0 T3：任意目录子树聚合索引，支撑 TreeBrowserView 多层下钻。
    /// key = 任意目录全路径，value = 该目录"整个子树"累计的 bytes / fileCount。
    /// 还额外维护 parent->Set<directChildPath> 边，让 OutlineGroup 能 O(1) 取子。
    ///
    /// v1.5.4：新增 `modificationDate` —— 仅在该目录"作为节点本身被 ingest"时写入，
    /// 即来自 [BulkScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift) 的目录条目自身的 inode mtime（Finder 风格）。
    /// 不做 max(子孙) 聚合，避免每个文件叶子都要回写所有祖先字段；nil 表示尚未拿到（极早期 publish 帧）。
    private struct DirAgg {
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var modificationDate: Date? = nil
    }
    private var dirIndex: [String: DirAgg] = [:]
    /// 父目录 -> 直接子项集合（含目录与文件路径）。文件叶子也存进来方便单层展示。
    private var childEdges: [String: Set<String>] = [:]
    /// 叶子文件 path -> (size, isDir, mtime?)；展示时区分文件与目录。
    /// v1.5.4 加 modificationDate：来源同 dirIndex —— 直接拿 [FSNode.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/FSNode.swift#L14)。
    private var fileLeaves: [String: (bytes: Int64, isDir: Bool, modificationDate: Date?)] = [:]

    /// v1.3.z：TreeBrowserView 的 store-fallback 缓存。
    ///
    /// 当 `enableTreeDeepIndex == false`（v1.3.z 起的默认）时，内存里没有
    /// `childEdges/dirIndex/fileLeaves`，TreeBrowserView 不能再同步拿到子项。
    /// 但 SwiftUI body 不能 await，所以这里做"同步表面 + 后台填充"双层缓存：
    ///   - body 每次调 `directChildren(of:sortedBy:)`，先看本 cache
    ///   - cache miss → 同步返 [], 同时启一个后台 Task 走 GRDB 查 store, 写回 cache
    ///   - 写回时 @Published 触发 view 重算, 第二帧拿到结果
    ///
    /// key = `"\(path)|\(sortKey.rawValue)"`，让不同排序各自缓存（用户切排序不丢上次结果）。
    /// 扫描结束 / 切类目 / 切根 时由 cancel/reset 主动清空，避免跨会话脏数据。
    ///
    /// **Step 9a / 2026-06**：从 `@Published` 解耦为普通字典。
    /// 历史问题：`@Published` 字典每次写入都会让整个 ScanCoordinator
    /// `objectWillChange` fire，所有 view（含 MainView 主列表 / SystemProbe banner）
    /// 都被波及一次重算；而真正需要被通知的只有 TreeBrowserView，
    /// 已经通过 [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L328-L332)
    /// 显式触发。新做法：cache 自己是普通字典，配套一条
    /// [childrenCacheVersion](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 计数器 @Published（仅给可能要按 cache 失效细粒度刷新的 view 订阅）。
    /// 主流程依赖 structuralRevision 即可。
    private var treeChildrenCache: [String: [TreeRow]] = [:]
    /// **Step 9a / 2026-06**：cache 写入计数器，monotonic UInt64。
    /// 任何 `treeChildrenCache` 写入（写新键 / 移除旧键 / 整轮 removeAll）后
    /// 都必须经过 [bumpChildrenCacheVersion()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 把它 &+= 1。view 端**通常不需要**直接订阅这条信号（structuralRevision 已经
    /// 覆盖），保留它是为：
    ///   - 单元测试断言"cache 写入 N 次 → version 自增 N 次"
    ///   - 未来 view 想做"按 cache 命中率细粒度刷新"留 hook
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var childrenCacheVersion: UInt64 = 0
    /// in-flight 路径集合：避免同 path 在 cache miss 时被 view body 多次重算疯狂启 Task。
    /// **不**参与 @Published（不需要触发 view 更新）。
    private var treeChildrenInFlight: Set<String> = []

    /// v2026.06.20 **目录 mtime 兜底缓存**。
    ///
    /// 背景：用户反馈"为什么有的地方修改时间就一直不显示"。
    /// 现状：BulkScanner 只对真正 yield 出的 `.node` 写入
    /// [DirAgg.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L189)；
    /// 但中间层目录（叶子上溯过程中累加的 ancestor）可能没有自己的 `.node` 事件，
    /// 这些 row 在 [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 输出时 `modificationDate == nil`，UI 永远显示 `·`。
    ///
    /// 修复策略：directChildren 输出真实存在的"目录"行时，若 agg.modificationDate=nil
    /// 但路径在磁盘上存在，就 `lstat` 一次拿 inode mtime 兜底，并缓存避免每帧重算。
    /// **不命中磁盘的虚拟节点（如多根伪 root `(开发者构建产物)`）不会落到这里**——
    /// 它们走 [synthesizeMultiRootTopLevel](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1777)，
    /// path 不是真实文件系统路径，stat 失败时缓存 `.failure` 表示"问就是 nil"，
    /// 下次同样命中直接返回 nil 不再 stat（避免 4w 行 × 每帧重 stat）。
    ///
    /// 缓存 key 是绝对路径；生命周期与扫描会话绑定，[startScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 在切换 root 时一并 removeAll，避免跨扫描泄漏陈旧 mtime。
    private enum MtimeFallbackResult {
        case found(Date)
        case failure
    }
    private var mtimeFallbackCache: [String: MtimeFallbackResult] = [:]

    /// 给目录路径 `path` 取一次磁盘 inode mtime；命中缓存直接返回。
    /// 该函数只读 file 系统，不写状态，故无需 @MainActor 隔离能保证（ScanCoordinator
    /// 本身就是 @MainActor），但 `lstat` 的耗时（亚毫秒级）和调用频率（每条可见行最多
    /// 一次，命中缓存后零成本）权衡下来落在主线程也可接受——避免引入 actor hop。
    private func resolveDirMtimeFallback(forPath path: String) -> Date? {
        if let cached = mtimeFallbackCache[path] {
            switch cached {
            case .found(let d): return d
            case .failure:      return nil
            }
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let d = attrs[.modificationDate] as? Date {
            mtimeFallbackCache[path] = .found(d)
            return d
        }
        mtimeFallbackCache[path] = .failure
        return nil
    }

    /// **Step 9a / 2026-06**：cache 写入版本号统一推进入口。
    /// 所有改 [treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的位置（写新键 / 删旧键 / removeAll / patch-by-prune）必须串到这里。
    /// 用 `&+=` 让计数器溢出时回卷而非 trap；订阅者只关心"变没变"，绝对值无意义。
    @inline(__always)
    private func bumpChildrenCacheVersion() {
        childrenCacheVersion &+= 1
        treeBrowser.bumpChildrenCacheVersion()
    }

    /// v1.5.4：树形视图扁平化重算的"统一脏标"。
    /// [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 把 visibleRows 从 computed 改为 `@State flatRows: [FlatTreeRow]`（性能修复，
    /// 避免一次操作里 4 次重复递归整棵展开树），重建时机靠 `onChange(of: treeRevision)` 串。
    ///
    /// 所有可能改变"directChildren(of:_) 输出"的入口必须 `treeRevision &+= 1`：
    /// 1. [publishSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1873)（流式 ingest tick / finished 收尾）
    /// 2. `treeChildrenCache` 主线程写回（store-fallback 异步 fetch 完成）
    /// 3. [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1174)（删除乐观更新）
    /// 4. 启动新扫描 / cancel 后的 cache 清空
    /// 5. [invalidateTreeCacheAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1147)（扫描结束清 cache）
    ///
    /// 用 `&+=` 让计数器溢出时自然回卷而非 trap；view 端只关心"变没变"，绝对值无意义。
    ///
    /// v2026.06.21 perf：**移除 @Published**。
    /// 旧设计让 4 个 revision 都是 @Published mirror，导致 ScanCoordinator 任一 bump
    /// 都让 MainView body / sidebar / footer 全失效（dev 扫每秒 ≥5 次 body 重算 = 卡顿核心）。
    /// 现在 view 端走 `coordinator.treeBrowser.*`（独立 ObservableObject）订阅；
    /// 本字段保留为普通 `public private(set) var` 仅供单测 / 外部代码直接读数。
    public private(set) var treeRevision: UInt64 = 0

    /// Step 2 P0-2 / 2026-06：treeRevision 拆分 —— 结构性脏标。
    /// 含义：节点新增 / 节点删除 / 排序键变化 / cache 整轮失效。订阅这条信号的 view
    /// **必须**重建 flatRows（一次 O(N) 拍平 + verdict 计算）。
    ///
    /// 与 `tickRevision` 的边界由 [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) /
    /// [bumpTickRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 两个 helper 单点收敛 —— 任何代码不再直接写
    /// `treeRevision &+= 1`，避免漏判类别。
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var structuralRevision: UInt64 = 0

    /// v1.5.7：结构变化的 hint —— "本次 structuralRevision 升的根因是这些 path 被删了"。
    /// 仅在 [pruneDeleted](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1422-L1542)
    /// 路径上写一次，订阅方需在 onChange(structuralRevision) 同步段内调
    /// [consumeLastPrunedPaths()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 一次性取走（取后立刻置 nil），避免下次 unrelated bump 误用。
    /// TreeBrowserView 在 hint 非 nil 时走"只剔被删 path 子树"的增量 patch，
    /// 避免对万级目录整树 rebuild。
    private var lastPrunedPaths: [String]? = nil

    /// 一次性消费 v1.5.7 prune hint：取走当前值并立刻清 nil。
    /// 设计目的：避免 TreeBrowserView onChange 闭包跨 runloop tick 读到陈旧值。
    public func consumeLastPrunedPaths() -> [String]? {
        let v = lastPrunedPaths
        lastPrunedPaths = nil
        return v
    }

    /// Step 2 P0-2 / 2026-06：treeRevision 拆分 —— 数值脏标（非结构性）。
    /// 含义：已有节点的 bytes / fileCount / isActive 变了，**节点拓扑没变**。订阅这条
    /// 信号的 view **不需要**重建 flatRows，只需让 RowView 内部读最新 bucket（通过其它
    /// @Published 入口，这里仅作"我又跳了一次"的通知）。
    ///
    /// publishSnapshot 流式 tick（0.4s/帧）只推这条；当帧检测到 `(buckets.count,
    /// dirIndex.count, fileLeaves.count)` 三元组变化时，由 helper 兜底升格为 structural。
    ///
    /// v2026.06.21 perf：移除 @Published（同 treeRevision 的理由）。
    public private(set) var tickRevision: UInt64 = 0

    /// 上一帧 publishSnapshot 时三个核心索引的 (count, count, count) 快照，用于 O(1)
    /// 判定"本帧是否新增节点"——任一计数变化即视为结构变化。
    private var lastIndexSnapshot: (buckets: Int, dirIndex: Int, fileLeaves: Int) = (0, 0, 0)

    /// 单点收敛：推进结构脏标。
    /// 同时推 `treeRevision`（兼容外部已订阅 treeRevision 的代码）和 `structuralRevision`。
    /// `tickRevision` 也顺带 +1 —— 任何 structural 都隐含一次 tick（一致性保证）。
    private func bumpStructuralRevision() {
        structuralRevision &+= 1
        tickRevision &+= 1
        treeRevision &+= 1
        treeBrowser.bumpStructuralRevision()
    }

    /// 单点收敛：推进数值脏标。
    /// 仅在确认"节点拓扑没变（仅 buckets[k].bytes 累加之类）"时调用。
    ///
    /// v1.5 P2 滑动卡顿修复：
    /// 此前为了"兼容订阅者不死寂"也把 `treeRevision` 一起推 —— 但 `treeRevision` 是
    /// TreeBrowserView 的"结构变化"信号，每帧 +1 等于强制 TreeBrowserView rebuildFlatRows()
    /// + 整个主列表所有 RowView body 重算，是滑动期主帧丢的第二大头（review-swarm 命中 #5）。
    /// 现在只 tick 数值通道（`tickRevision` + `treeBrowser.bumpTickRevision()`），
    /// 树形视图按"显式 structural"通道感知拓扑变化，纯 bytes 累加不再打扰它。
    private func bumpTickRevision() {
        tickRevision &+= 1
        // v2026.06.21 perf：保持与 [TreeBrowserStore.bumpTickRevision](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserStore.swift#L67-L70)
        // 完全对齐（store 端 tick 也会推 treeRevision 作老订阅者兼容），
        // 否则 [TreeBrowserStoreTests.test_扫描期间coord的mirror与store同步](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/TreeBrowserStoreTests.swift#L96-L99)
        // 会判 coord.treeRevision 落后 store.treeRevision 一个 tick。
        treeRevision &+= 1
        treeBrowser.bumpTickRevision()
    }

    /// Step 3 P0-3 / 2026-06：bucket cachedVerdict 命中率计数器。
    /// publishSnapshot 走 cache 路径时，`miss = 首次计算并写回`，`hit = 直接读现有值`。
    /// 仅作运行期遥测与测试观察用，**不参与 @Published**（不触发 view 更新）。
    private var verdictCacheHits: Int = 0
    private var verdictCacheMisses: Int = 0

    /// v1.5 P1-C：publishSnapshot 流式帧"排序结果"缓存。
    /// 不变量：扫描中 ingest 只 add 不 remove bucket（buckets.count 单调增），
    /// 同时白名单 whitelistSnapshot 在帧间一般不变 ——
    /// 所以当 `(buckets.count, whitelistSnapshot.count)` 与上一帧相同时，
    /// 流式帧（finished=false）的 sorted id 序（path 字典序）必然与上一帧完全一致，
    /// 可直接复用，跳过 O(N log N) 排序。
    /// finished=true 帧走用户 sort，不参与缓存。
    private var lastStreamSortedIds: [String] = []
    private var lastStreamSortCacheKey: (bucketCount: Int, whitelistCount: Int) = (-1, -1)

    /// 测试观察口：暴露 verdict cache 命中统计。
    /// 仅 internal —— 同 module 的测试代码可读；外部 framework 不可见。
    /// 用于 [BucketVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/BucketVerdictCacheTests.swift) 验证 P0-3 缓存生效。
    func verdictCacheStatsForTesting() -> (hits: Int, misses: Int) {
        (verdictCacheHits, verdictCacheMisses)
    }

    /// 测试触发口：在已扫完的状态下手动再触发一次 publishSnapshot。
    /// 用途：fake home fixture 太小时，扫描可能只跑一帧 publishSnapshot（150ms 节流没触发流式帧），
    /// 测试看不到 cache hit。该方法让 [BucketVerdictCacheTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/BucketVerdictCacheTests.swift) 能在确定的 buckets 状态下
    /// 再调一次 publishSnapshot 验证"第二次访问 = cache hit"。生产路径不调它。
    func forcePublishSnapshotForTesting(categoryID: String = "_test_") {
        publishSnapshot(categoryID: categoryID, finished: false)
    }

    /// v1.0 T4：大文件叶子集合。
    /// 仅当 `largeFileMinBytes > 0` 时才会被填充（避免普通扫描浪费内存）。
    /// 每条记录原样保留 path / bytes / mtime，让 `largeFiles(...)` 能按多种 sortKey
    /// 自由切换排序，**无需重扫**。
    public struct LargeFileLeaf: Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let modificationDate: Date?
    }
    private var largeFileLeaves: LargeFileLeafTopNHeap = LargeFileLeafTopNHeap(capacity: ScanCoordinator.largeFileTopNCapacity)
    /// **Step 9c / 2026-06**：Top-N 容量上限（绝对硬顶）。
    /// 选 1000：
    ///   - LargeFilesView 本就只渲染 limit=200，N=1000 留 5×缓冲量给排序切换。
    ///   - 内存：1000 × ~64B（path/bytes/mtime）= ~64KB，常驻可忽略。
    ///   - 插入复杂度：O(log 1000) ≈ 10 次比较，远小于原"无脑 append + 末尾 N log N 排序"。
    public static let largeFileTopNCapacity: Int = 1000
    /// M3：compactAfterScanPreservingCache 之后的"二级缓存"。
    /// 把 store 里的 Top N 大文件预读到这，UI 重进大文件页时仍可同步渲染——
    /// 既享受了主索引被释放的内存收益，又不让 UI 出现空白回退。
    /// `nil` 表示尚未 compact 或主路径仍可用；非 nil 表示 largeFileLeaves 已清空，UI 应读这里。
    private var compactedLargeFileTopN: [LargeFileLeaf]?
    /// 当前扫描会话中"采集大文件的下限"。0 表示不采集。
    private var largeFileMinBytes: Int64 = 0

    private var totalBytes: Int64 = 0
    private var scannedFiles: Int = 0
    private var startedAt: Date = .distantPast

    /// v1.3：扫描吞吐 EWMA 速率（bytes/s）。在 publishSnapshot 时基于
    /// (totalBytes - lastSampleBytes) / (now - lastSampleAt) 增量采样并 EWMA 平滑：
    ///   rate' = α × instant + (1-α) × rate，α = 0.3 让短期跳变不至于把数字拉飞，
    ///   也让长期趋势能跟得上。
    private var bytesPerSecondEMA: Double = 0
    private var lastSampleAt: Date?
    private var lastSampleBytes: Int64 = 0

    /// v1.3：本次扫描是否能给 ETA。仅当 category.kind == .fullDisk 且 volumeSnapshot 已知时为 true，
    /// 此时"剩余字节" = volumeSnapshot.usedBytes - totalBytes 是个有意义的上限。
    /// 推荐扫描 / 自定义路径不报 ETA（不知道总量），UI 显示"估算中…"。
    private var etaEligible: Bool = false

    /// v1.3.x：用户反馈"扫描感觉很久也没 ETA"——给推荐扫描 / 自定义根扫描提供 ETA 分母。
    ///
    /// 与 [etaEligible](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L195-L195)
    /// 互补：整盘扫用 `volumeSnapshot.usedBytes` 作为分母（无需采样），推荐/自定义扫
    /// 在 [scanRecommended](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L331-L331)
    /// 启动时**异步**用 [TreeSizeEstimator.estimate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/TreeSizeEstimator.swift)
    /// 快速 walk 5 个根的元数据（不分类、不去重 hardlink），写到这个字段。
    /// nil = 还在估算 / 无法估算（沙盒挡住），UI 显示"估算中…"。
    @Published public private(set) var expectedTotalBytes: Int64? = nil

    /// v1.3：字节口径（logical / physical）。
    ///
    /// 默认 `.logical`，与系统设置 / Finder / "信息"面板对齐。
    /// - logical：`node.logicalSize`（ATTR_FILE_TOTALSIZE），文件 fork 完整字节数；
    ///   APFS clone / hardlink 不去重，每个文件按完整 size 算。
    /// - physical：`node.allocatedSize`（ATTR_FILE_ALLOCSIZE），实际占用磁盘 block 字节；
    ///   sparse 文件按真实占用算（更小），与 `du` 口径一致。
    ///
    /// 通过 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/GSYCleanMacApp.swift)
    /// 在启动时与 onChange 时从 [AppSettings.sizeAccountingMode](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 同步过来。切换需要重新扫描才能生效（已扫的 ingest 数据按当时口径累计）。
    public var accountingMode: AppSettings.SizeAccountingMode = .logical

    /// 根据当前口径取该节点应该计入"显示总量"的字节数。
    @inline(__always)
    private func displayBytes(of node: FSNode) -> Int64 {
        switch accountingMode {
        case .logical:  return node.logicalSize
        case .physical: return node.allocatedSize
        }
    }

    /// v1.3.z 性能开关：是否在 ingest 时构建多层下钻索引（dirIndex / childEdges / fileLeaves）。
    /// - true：扫描期就维护好整棵树索引，TreeBrowserView 进入即可同步渲染。
    ///   **代价**：大目录（70 GB / 72 万文件）下，主线程会被 576 万次祖先上溯字典写入压住 ~5 分钟。
    /// - false（v1.3.zz 起的默认）：跳过深索引维护；TreeBrowserView 通过 GRDB store-fallback 异步下钻
    ///   （首次 cache miss → 后台 Task 查 store → 回填 cache → SwiftUI 重新渲染），首屏延迟 100ms 级。
    /// 切换不影响：buckets（主列表）、totalBytes、scannedFiles、largeFileLeaves、resultStore 落库。
    public var enableTreeDeepIndex: Bool = false

    /// Step 10a / 2026-06：系统探针 SSOT。
    /// fdaStatus / volumeSnapshot / swapSnapshot 三个字段的写入路径全部经此 store；
    /// ScanCoordinator 自身保留 @Published mirror（向后兼容）。
    public let systemProbe: SystemProbeStore

    /// Step 10b / 2026-06：树形浏览状态 SSOT 接口外壳。
    /// 让新代码 / 单测可以单独订阅 `coordinator.treeBrowser.structuralRevision` 等，
    /// 不再依赖整个 ScanCoordinator.objectWillChange。
    /// ScanCoordinator 自身保留对应字段作 @Published mirror（向后兼容）；
    /// bumpStructuralRevision / bumpTickRevision / bumpChildrenCacheVersion
    /// 三个 helper 内部双写到 store 与 mirror 保证一致。
    public let treeBrowser: TreeBrowserStore

    public init(vendors: [VendorRule] = [], home: String = NSHomeDirectory(),
                resultStore: ScanResultStore? = nil,
                enableTreeDeepIndex: Bool = false) {
        self.vendors = vendors
        self.home = home
        self.resultStore = resultStore
        self.enableTreeDeepIndex = enableTreeDeepIndex
        // 性能关键：vendors 在 init 时已确定，扫描期不会变。
        // 一次构建 trie 复用整个生命周期，避免 publishSnapshot 每帧 N 次重建。
        self.trie = VendorTrie.build(vendors: vendors, home: home)
        // Step 10a / 2026-06：抽 SystemProbeStore 持有 fdaStatus/volumeSnapshot/swapSnapshot。
        // store 的 init 内部就会探一次三个值。
        let probe = SystemProbeStore(home: home)
        self.systemProbe = probe
        // Step 10b / 2026-06：抽 TreeBrowserStore 提供 cache / revision 的 SSOT 接口外壳。
        // ScanCoordinator 上同名字段保留作 @Published mirror（向后兼容）；
        // bump* helper 双写保证 store 与 mirror 一致。
        self.treeBrowser = TreeBrowserStore()
        // 向后兼容 mirror：保留 ScanCoordinator 上 @Published 字段供老 view / 老测试读取，
        // 写入唯一来源是 systemProbe。
        self.fdaStatus = probe.fdaStatus
        self.volumeSnapshot = probe.volumeSnapshot
        self.swapSnapshot = probe.swapSnapshot
    }

    /// v1.3：用户从系统设置回到 App 后调用，重探 FDA 状态与卷容量。
    /// 推荐绑定到 `.onAppear` 与"打开系统设置"按钮的 `NSApplication.didBecomeActive` 回调。
    /// Step 10a / 2026-06：写入唯一来源 [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L474-L474)，
    /// 之后同步回 mirror 字段。
    public func refreshFDAStatus() {
        systemProbe.refreshFDAStatus()
        fdaStatus = systemProbe.fdaStatus
        volumeSnapshot = systemProbe.volumeSnapshot
        swapSnapshot = systemProbe.swapSnapshot
    }

    /// v1.3：每次扫描完成 / 删除完成后调用，重探卷容量（FDA 不变就不动）。
    /// Step 10a / 2026-06：写入唯一来源 [systemProbe](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L474-L474)，
    /// 之后同步回 mirror 字段。
    public func refreshVolumeCapacity() {
        systemProbe.refreshVolumeCapacity()
        volumeSnapshot = systemProbe.volumeSnapshot
        swapSnapshot = systemProbe.swapSnapshot
    }

    public func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        // v1.3：cancel 同时清 activeCategoryID，让旧 stream 残留事件能被自检识别为"过期"并丢弃。
        activeCategoryID = nil
        // v1.3 review-fix：cancel 必须 reset snapshot 与 currentRootPath，
        // 否则 isPristine 判定（rows.isEmpty + scannedFileCount==0）失真，
        // statusBar 会把"扫到一半被打断"误显示成"还未扫描"。
        // 同时把 permissionDeniedPaths / tccProtectedSkippedPaths / lastError 一起清掉，
        // 避免上一轮 banner 漂到下一类目。
        snapshot = .empty
        currentRootPath = nil
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []
        lastError = nil
        // v1.3：cancel 时同时清掉多根扫描进度，避免 statusBar 上残留旧根的"扫描中"行。
        resetPerRootPublished()
        perRootStaging = [:]
        // v1.3：标记本次状态为"用户主动停止"，让 statusBar 显示"已停止"而非"还未扫描"。
        wasCancelled = true
        // M1 内存优化：本轮取消后 store 中残留的半截 session 直接 evict，避免占盘。
        // v1.5.7：不再 try? 静默吞错，evict 失败要落日志，便于诊断半截 session 堆积。
        if let store = resultStore, let sid = currentSessionID {
            Task.detached {
                do {
                    try await store.evictSession(sid)
                } catch {
                    GSYLog.error(.scan, "cancelScan evictSession sid=\(sid) failed: \(error)")
                }
            }
        }
        currentSessionID = nil
        storeBatch.removeAll(keepingCapacity: false)
    }

    public func scan(category: ScanCategory, includeHidden: Bool = true,
                     largeFileMinBytes: Int64 = 0) {
        cancel()
        // v1.3：cancel() 在上面把 wasCancelled 置 true，但本次是新扫描入口而非"停止"，立刻清回 false
        wasCancelled = false
        buckets.removeAll(keepingCapacity: true)
        // Step 3 P0-3：buckets 整轮清空 → bucket 上的 cachedVerdict 也跟着消失。
        // 但独立维护的命中率计数器需要显式归零，否则跨会话累计无意义。
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        // v1.3.z：清掉上一轮的 TreeBrowserView store-fallback 缓存，
        // 避免新 sessionID 期间 view 看到旧 sessionID 的 store query 结果。
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        // v2026.06.20：mtime 兜底缓存也跟随会话清零——
        // 用户两次扫描之间完全可能在 Finder/CLI 改文件，旧 mtime 必须作废。
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        largeFileLeaves.removeAll(keepingCapacity: true)
        // M3：新 scan 启动必须清掉上一轮 compact 缓存的 Top N，避免新会话期间
        // largeFiles(...) 错误命中旧 cache（largeFileLeaves 当前空 + cache 非空）。
        compactedLargeFileTopN = nil
        // v1.3：清掉上一轮的 ingest 时间戳，避免新扫描启动瞬间旧 bucket 仍被判 active
        lastIngestAt.removeAll(keepingCapacity: true)
        self.largeFileMinBytes = max(0, largeFileMinBytes)
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        // v1.3：ETA 采样状态归零；仅整盘扫给 ETA（其它扫描不知道总量）。
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        // v1.3.x：所有非整盘扫描也开 ETA 闸门——是否真的能出 ETA 取决于 expectedTotalBytes 是否估出来。
        etaEligible = true
        expectedTotalBytes = nil
        currentRootPath = category.rootPath
        snapshot = ScanSnapshot(categoryID: category.id, rows: [], totalBytes: 0,
                                scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        lastError = nil
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []
        // v1.3：cancel() 把 activeCategoryID 清空了，本次 scan 入口重新打上当前 token；
        // runScan 内每个事件先校验 `categoryID == activeCategoryID`，过期 stream 残留事件会被自动丢弃。
        activeCategoryID = category.id

        // M4-T1：本轮扫描前异步预拉一份 whitelist 快照。
        // 异步拉完才能命中过滤——首帧 publishSnapshot 时 snapshot 可能仍是空 Set，
        // 这是可接受的：首帧用户也基本看不到几个 bucket，且后续帧都会命中。
        whitelistSnapshot = []
        Task { [weak self] in
            let snap = await WhitelistStore.shared.snapshotPaths()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.activeCategoryID == category.id else { return }
                self.whitelistSnapshot = snap
            }
        }

        let rootURL = category.rootURL
        let categoryID = category.id

        // M1 内存优化：开启 store 时为本轮扫描建会话；失败则降级（storeHealthy=false）。
        let session = ScanSessionID()
        currentSessionID = session
        storeBatch.removeAll(keepingCapacity: true)
        storeHealthy = true
        if let store = resultStore {
            Task.detached { [storeRef = store] in
                do { try await storeRef.beginSession(session) }
                catch { /* 静默降级，不影响扫描 */ }
            }
        }

        // v1.3.x：非整盘扫描启动 TreeSizeEstimator 给 ETA 分母；整盘扫直接用 volumeSnapshot.usedBytes
        // （在 publishSnapshot 内部判断），无需再 walk 一遍。
        if category.kind != .fullDisk {
            Task { [weak self] in
                let estimated = await TreeSizeEstimator.estimate(roots: [rootURL], timeout: 4.0)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.activeCategoryID == categoryID else { return }
                    self.expectedTotalBytes = estimated
                }
            }
        } else if let used = volumeSnapshot?.usedBytes {
            // 整盘扫直接把 used 当 expectedTotalBytes 暴露给 UI，统一口径
            self.expectedTotalBytes = used
        }
        // v1.0 T5：整盘扫描时强制开启 staySingleVolume，避免误吃外接卷 / 网络挂载点把扫描时间打爆
        let isFullDisk = category.kind == .fullDisk
        // v1.3 P0-C：整盘扫描节点量 100k+，deep index 在 MainActor ingest 内做
        // 祖先回溯 + childEdges/dirIndex/fileLeaves 写入会瞬间打爆主线程帧预算。
        // 整盘永远走 store-fallback 路径（同步表面 + 后台 GRDB 填充）。
        if isFullDisk && enableTreeDeepIndex {
            GSYLog.info(.scan, "ScanCoordinator 整盘扫描强制关闭 enableTreeDeepIndex（防止 MainActor ingest burst）")
            enableTreeDeepIndex = false
        }
        scanTask = Task { [weak self] in
            await self?.runScan(rootURL: rootURL, categoryID: categoryID,
                                includeHidden: includeHidden, staySingleVolume: isFullDisk)
        }
    }

    /// v1.0 T5：整盘扫描便捷入口 —— 等价于 `scan(category: .fullDisk)`。
    /// MainView 路径栏输入 `/` 回车 / 整盘扫描按钮 都走这个 API，避免在多处硬编码 `ScanCategory.fullDisk`。
    public func scanFullDisk(includeHidden: Bool = true) {
        scan(category: .fullDisk, includeHidden: includeHidden)
    }

    /// M4-T2：版本化收集根扫描入口。
    ///
    /// 直接调 [KnownVersionedRoots.scanAll(home:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/KnownVersionedRoots.swift#L111-L139)
    /// 拿到所有可回收的旧版本子目录（Xcode DeviceSupport / JetBrains Toolbox 等），
    /// 直接构造 [RowItem](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift)
    /// 发布一个 finished snapshot 给 UI——**不走** BulkScanner / 不走流式 ingest，
    /// 因为命中数极少（DeviceSupport ≤ 10，Toolbox ≤ 30），同步遍历总耗时 < 100ms。
    ///
    /// categoryID 固定 `"developer.versioned"`，方便上层按 id 区分。
    /// 每条 Hit 用 [FileManager.directorySizeBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
    /// 取真实 size；失败回退到 0（UI 仍能渲染条目，让用户决定是否删除）。
    ///
    /// 与 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
    /// 的关系：每条命中仍然走 `engine.evaluate(path:trie:home:)`，让 forbid 路径
    /// 在 UI 上以 lock 形式显示而非被静默删除（与主扫描行为对齐）。
    public func scanKnownVersionedRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cancel()
        wasCancelled = false
        buckets.removeAll(keepingCapacity: true)
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        largeFileLeaves.removeAll(keepingCapacity: true)
        compactedLargeFileTopN = nil
        lastIngestAt.removeAll(keepingCapacity: true)
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        etaEligible = false
        expectedTotalBytes = nil
        // v2026.06.21：用专用 sentinel 而非 home.path，让 TreeBrowserView 走
        // [synthesizeVersionedTopLevel] 把 snapshot.rows 合成树形顶层；
        // 否则 directChildren(of: home.path) 在 childEdges/store 都找不到子项，
        // 树形视图永远空（用户反馈"清单 28 文件，树形为空"）。
        currentRootPath = ScanCoordinator.versionedRootSentinelPath
        isScanning = true
        lastError = nil
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []
        let categoryID = "developer.versioned"
        activeCategoryID = categoryID

        // v2026.06.21 P0：原本 KnownVersionedRoots.scanAll + 逐 hit directorySize 的全
        // 同步遍历直接挂在 @MainActor 上跑，Xcode DeviceSupport / JetBrains Toolbox
        // 这类 GB 级目录会让主线程冻结到秒级（命中 30 条 × 每条 GB 全递归读 fileSize）。
        // 改用 Task.detached 派到默认 executor 做 IO，结尾 await MainActor.run 一次性
        // 回主线程发布 snapshot，参考 [scanDeveloper L1142-L1149] 同款模式，并保留
        // activeCategoryID 防过期检查避免用户中途切走时覆盖新分类的 snapshot。
        let engineCopy = engine
        let trieRef = trie
        let homeStr = self.home
        let startedAtCopy = startedAt
        scanTask = Task.detached { [weak self] in
            let hits = KnownVersionedRoots.scanAll(home: home)
            var rows: [RowItem] = []
            rows.reserveCapacity(hits.count)
            var totalAccum: Int64 = 0
            for hit in hits {
                if Task.isCancelled { return }
                let (verdict, rejection, vendor) = engineCopy.evaluate(path: hit.url.path,
                                                                       trie: trieRef, home: homeStr)
                let size = Self.directorySize(at: hit.url)
                totalAccum &+= size
                let localizedDisplay = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                let composedTitle: String
                if let groupKey = hit.groupKey, !groupKey.isEmpty {
                    composedTitle = "\(localizedDisplay) · \(groupKey) · \(hit.versionName)"
                } else {
                    composedTitle = "\(localizedDisplay) · \(hit.versionName)"
                }
                rows.append(RowItem(
                    id: hit.url.path,
                    url: hit.url,
                    title: composedTitle,
                    isDirectory: true,
                    bytes: size,
                    logicalBytes: size,
                    fileCount: 0,
                    verdict: verdict,
                    rejection: rejection,
                    vendorName: vendor?.name,
                    vendorNote: "retain: \(hit.retainedLatest)",
                    isActive: false,
                    modificationDate: nil
                ))
            }
            let sortedRows = rows.sorted { $0.bytes > $1.bytes }
            let rowsCount = rows.count
            let totalCaptured = totalAccum
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 防过期：用户在后台扫描期间切到别的分类入口时，activeCategoryID 已被
                // 后续 scan() 改写；本次结果直接丢弃，不污染新分类的 snapshot。
                guard self.activeCategoryID == categoryID else { return }
                self.snapshot = ScanSnapshot(
                    categoryID: categoryID,
                    rows: sortedRows,
                    totalBytes: totalCaptured,
                    scannedFileCount: rowsCount,
                    isFinished: true,
                    elapsed: Date().timeIntervalSince(startedAtCopy)
                )
                self.lastFinishedCategoryID = categoryID
                self.isScanning = false
                // **Review fix-soon #3，2026-06-15**：scanKnownVersionedRoots 会改变 snapshot
                // 里 "developer.versioned" 的行集合（特别是 PR 新增的 Android SDK / JetBrains
                // 分组规则上线后，老 cache 里同路径的子项可能与新分组结果不一致）。
                // 与 [scan(category:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1495-L1497)
                // 走完后调 [invalidateTreeCacheAfterScan()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1495-L1497)
                // 的行为对齐：本入口同样清掉 treeChildrenCache 并 bump childrenCacheVersion，
                // 让 TreeBrowserView 不会用旧 sessionID 的 store-fallback 结果误展示已被
                // 新规则重新分组的版本子目录。
                self.invalidateTreeCacheAfterScan()
                GSYLog.info(.app,
                            "scanKnownVersionedRoots: \(rowsCount) versioned candidates, total=\(totalCaptured)")
            }
        }
    }

    /// 单层递归 size 估算。仅用于 [scanKnownVersionedRoots](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 这种小目录场景；大目录会走 BulkScanner 的并发实现。
    ///
    /// v2026.06.21 P0：标 `nonisolated` 让 P0 修复后的 `Task.detached` 能在默认 executor
    /// 上直接调用，否则会被 ScanCoordinator 的 @MainActor 隔离拉回主线程，前面把 IO
    /// 派后台的努力全部作废。函数体只读 FileManager.enumerator，本来就线程安全。
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey],
                                             options: [.skipsHiddenFiles],
                                             errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total &+= Int64(size)
            }
        }
        return total
    }

    /// v1.3：多根并行扫描入口（"全部推荐扫描"）。
    ///
    /// 解决用户反馈："扫描看起来还是只有一个目录在动" —— 走 [MultiRootScanner](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)
    /// 把 ScanCategories.recommended() 的 5 个根 **同时** 启动，每根独立 BulkScanner + InodeSet + 6 worker，
    /// 真正打满 M*6 个并行工作单元。
    ///
    /// 实现要点：
    /// - currentRootPath 设 "(多目录)"：UI 在 finishedEmpty / 树视图等场景需要一个非 nil 占位；
    ///   这里不能用具体的某根路径（否则 5 根中只能选 1 个展示，逻辑混乱）。
    /// - activeCategoryID = multiRootCategoryID 哨兵：与单根 scan 共用 `runScan` 防过期事件机制；
    ///   现有 `cancel()` 把 activeCategoryID 清空 → 旧 stream 残留事件自动丢弃。
    /// - perRootProgress 预填 5 条：UI 立刻能渲染 5 行"扫描中…"，不等第一个事件到达。
    /// - bucket key 形如 "{rootPath}/{firstSegment}"：现有 ingest 走的是 rootPath 前缀切割，
    ///   多根时不同根不会撞 key（路径前缀不同），现有逻辑无需改。
    public func scanRecommended(includeHidden: Bool = true) {
        cancel()
        wasCancelled = false
        buckets.removeAll(keepingCapacity: true)
        // Step 3 P0-3：buckets 整轮清空 → bucket 上的 cachedVerdict 也跟着消失。
        // 但独立维护的命中率计数器需要显式归零，否则跨会话累计无意义。
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        // v1.3.z：清掉上一轮的 TreeBrowserView store-fallback 缓存，
        // 避免新 sessionID 期间 view 看到旧 sessionID 的 store query 结果。
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        // v2026.06.20：mtime 兜底缓存也跟随会话清零——
        // 用户两次扫描之间完全可能在 Finder/CLI 改文件，旧 mtime 必须作废。
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        largeFileLeaves.removeAll(keepingCapacity: true)
        // M3：新 scan 启动必须清掉上一轮 compact 缓存的 Top N，避免新会话期间
        // largeFiles(...) 错误命中旧 cache（largeFileLeaves 当前空 + cache 非空）。
        compactedLargeFileTopN = nil
        // v1.3：清掉上一轮的 ingest 时间戳，避免新扫描启动瞬间旧 bucket 仍被判 active
        lastIngestAt.removeAll(keepingCapacity: true)
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        // v1.3.x：用户反馈"扫描很久也没 ETA" —— 推荐扫描虽然没整盘 volumeSnapshot 可用，
        // 但 5 个根的总字节数可以异步快速估算（几百毫秒到几秒），估出来后开 ETA。
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        // 启动时先标记 eligible=true（等估算完成后由 expectedTotalBytes 决定能否真出数）；
        // 真正用 expectedTotalBytes 判断会在 publishSnapshot 里做，这里只是开闸。
        etaEligible = true
        expectedTotalBytes = nil  // 还没估算出来
        currentRootPath = ScanCoordinator.multiRootSentinelPath
        snapshot = ScanSnapshot(categoryID: ScanCoordinator.multiRootCategoryID, rows: [],
                                totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        lastError = nil
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []
        activeCategoryID = ScanCoordinator.multiRootCategoryID

        // M1 内存优化：多根扫描共享一个 session（all roots → one logical scan）。
        let session = ScanSessionID()
        currentSessionID = session
        storeBatch.removeAll(keepingCapacity: true)
        storeHealthy = true
        if let store = resultStore {
            Task.detached { [storeRef = store] in
                do { try await storeRef.beginSession(session) }
                catch { /* 静默降级 */ }
            }
        }

        let cats = ScanCategories.recommended(home: home)
        // 预填 perRootProgress，UI 立刻能看到 5 行"扫描中…"行；
        // 后续 .node / .finished 事件再原地累加 / 翻 isFinished。
        var initial: [String: PerRootProgress] = [:]
        for c in cats {
            initial[c.rootPath] = PerRootProgress(rootPath: c.rootPath, title: c.displayTitle)
        }
        syncPerRootPublished(from: initial)
        // v1.3.zz 性能修复：staging 同步初始化，让 .node 事件累计的目标存在
        perRootStaging = initial

        let roots = cats.map { $0.rootURL }
        // v1.3.x：异步估算总字节数，用作 ETA 分母。
        // 4s 软超时 + 后台 detached → 完全不阻塞正式扫描的启动。
        let activeID = ScanCoordinator.multiRootCategoryID
        Task { [weak self] in
            let estimated = await TreeSizeEstimator.estimate(roots: roots, timeout: 4.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 防止过期估算覆盖新一轮扫描
                guard self.activeCategoryID == activeID else { return }
                self.expectedTotalBytes = estimated
            }
        }
        // v1.3 review-fix Must4：原写法 `(fdaStatus != .granted)` 把 `.unknown` 也当成"未授权"处理，
        // 导致 FDAProbe 三探针目录全不存在时（沙盒 / 容器异常）会**误报**一个 TCC banner，
        // 而真实状态可能是已授权。改成只在 `.denied` 时才 respectTCCSkipList，`.unknown` 走默认（信任系统层 errno=EPERM 自然 skip），
        // 既保守又不会出现"什么都还没扫就闪 banner"。
        let respectTCC = (fdaStatus == .denied)
        let options = ScanOptions(includeHidden: includeHidden,
                                  staySingleVolume: false,
                                  respectTCCSkipList: respectTCC)
        scanTask = Task { [weak self] in
            // v1.5 性能修复：推荐扫描 5 根固定，但常见命中 ~/Library/Caches、
            // ~/Library/Logs、~/Library/Application Support 等大根；并发上限 3 足够
            // 让吞吐拉满又不会让整机 IO 子系统拥塞（详见 MultiRootScanner.scan 注释）。
            await self?.runMultiRootScan(roots: roots, options: options,
                                         categoryID: ScanCoordinator.multiRootCategoryID,
                                         maxConcurrentRoots: 3)
        }
    }

    /// v1.4：开发者构建产物多根并行扫描入口。
    ///
    /// 流程：
    /// 1. [DevArtifactScanner] 在 `~` 下勘察命中规则的目录（不计字节，只列 URL + 规则元数据）；
    /// 2. 用 [DevArtifactRule.Verdict] 过滤——本入口只接收 `.safe` + `.confirm` 两类，
    ///    勾选默认值由 verdict 决定（safe 默认勾选、confirm 默认不勾，与 ScanCategory 体系一致）；
    /// 3. 把命中目录转成多根，复用 [runMultiRootScan]——这样 UI 全套（perRootProgress / footerBar /
    ///    treeBrowser / safety / TrashPipeline）零改动；
    /// 4. 命中数为 0 时直接 publish 一个 finished=true 的空 snapshot，避免 UI 无限"扫描中…"。
    ///
    /// - Parameters:
    ///   - includeHidden: 透传 ScanOptions.includeHidden（开发者产物里很多隐藏目录如 `.next`，应保持 true）
    ///   - enabledRuleIDs: 启用的规则 ID 集合，缺省 = 全部启用；调用方传入用户设置中关掉的差集
    public func scanDeveloper(includeHidden: Bool = true,
                              enabledRuleIDs: Set<String> = DevArtifactRules.allIDs) {
        cancel()
        wasCancelled = false
        // v1.3 P0-C：开发者构建产物扫描典型命中 30+ 根 × 每根上万 node，
        // 若 enableTreeDeepIndex 开着，MainActor ingest 会被祖先回溯 + index 写入打挂。
        // 强制关闭，让 TreeBrowser 走 store-fallback 异步路径（与全盘扫一致策略）。
        if enableTreeDeepIndex {
            GSYLog.info(.scan, "ScanCoordinator dev 扫描强制关闭 enableTreeDeepIndex（防止 MainActor ingest burst）")
            enableTreeDeepIndex = false
        }
        buckets.removeAll(keepingCapacity: true)
        // Step 3 P0-3：buckets 整轮清空 → bucket 上的 cachedVerdict 也跟着消失。
        // 但独立维护的命中率计数器需要显式归零，否则跨会话累计无意义。
        verdictCacheHits = 0
        verdictCacheMisses = 0
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        treeChildrenInFlight.removeAll(keepingCapacity: true)
        // v2026.06.20：mtime 兜底缓存与扫描会话同寿，cancel/reset 一并清空。
        mtimeFallbackCache.removeAll(keepingCapacity: true)
        largeFileLeaves.removeAll(keepingCapacity: true)
        bumpStructuralRevision()
        compactedLargeFileTopN = nil
        lastIngestAt.removeAll(keepingCapacity: true)
        self.largeFileMinBytes = 0
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        bytesPerSecondEMA = 0
        lastSampleAt = nil
        lastSampleBytes = 0
        etaEligible = true
        expectedTotalBytes = nil
        currentRootPath = ScanCoordinator.developerSentinelPath
        snapshot = ScanSnapshot(categoryID: ScanCoordinator.developerCategoryID, rows: [],
                                totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        lastError = nil
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []
        // v1.3 P0-D：dev 扫描入口归零截断标志，避免上次的状态污染本次 banner。
        devArtifactDidTruncate = false
        devArtifactDidTimeout = false
        activeCategoryID = ScanCoordinator.developerCategoryID

        let session = ScanSessionID()
        currentSessionID = session
        storeBatch.removeAll(keepingCapacity: true)
        storeHealthy = true
        if let store = resultStore {
            Task.detached { [storeRef = store] in
                do { try await storeRef.beginSession(session) }
                catch { /* 静默降级 */ }
            }
        }

        let homeURL = URL(fileURLWithPath: home)
        let respectTCC = (fdaStatus == .denied)
        let options = ScanOptions(includeHidden: includeHidden,
                                  staySingleVolume: false,
                                  respectTCCSkipList: respectTCC)
        let activeID = ScanCoordinator.developerCategoryID

        // 异步勘察 + 启动扫描；勘察自身有 60s 超时和 GSYLog 埋点
        scanTask = Task { [weak self] in
            // v2026.06.21 总体方针修订：用户明确要求"不能进入截断/超时状态"——
            // 因此 maxHits 走 DevArtifactScanner 默认值 (.max)，命中再多也不截断；
            // timeoutSeconds 保留 60s 作为最后安全网（实际正常家目录几秒~十几秒走完）。
            // 同时换用 streamed 接口：每命中 [flushEvery] 条 hit 就把这批 partial
            // 通过 onPartial 回调推回主 actor 预填 perRootStaging，让 UI 在 walk
            // 还没完成时就能看到 sidebar 不断长出新的"待扫根"行——视觉上不再"卡死"。
            let opts = DevArtifactScanner.Options(enabledRuleIDs: enabledRuleIDs)
            let scanner = DevArtifactScanner(options: opts)
            let homeStr = self?.home ?? NSHomeDirectory()
            // partial 回调在 detached 线程，必须跳回主 actor 写 @MainActor 隔离的字段
            // v2026.06.21 性能：原本每个 batch（每 20 hit）都立刻调一次 syncPerRootPublished，
            // discover 命中几百条时 partial 阶段触发 10+ 次同步——每次都让 MainView 整 body
            // 重算，dev 扫主列表滑动卡顿的最大单点。改为：staging 写入是 hot path 保留；
            // syncPerRootPublished 节流到 0.4s 一次（与 runMultiRootScan throttle 对齐），
            // 用 nonisolated(unsafe) 包装一个时间戳 box 做窗口判定。最终 flush 由 walk 结束
            // 后的 MainActor.run（L1232 之后）兜底，不会漏掉尾巴。
            let partialSyncBox = PartialSyncWindow()
            let onPartial: @Sendable ([DevArtifactScanner.Hit]) -> Void = { [weak self] batch in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.activeCategoryID == activeID else { return }
                    // 把这一批 hit 预填进 perRootStaging（不动 @Published，等下次 throttle 同步）
                    for hit in batch {
                        let path = hit.url.path
                        if self.perRootStaging[path] != nil { continue }
                        let shortPath = self.shortenPath(path, home: homeStr)
                        let localizedDisplay = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                        let title = "\(localizedDisplay) · \(shortPath)"
                        self.perRootStaging[path] = PerRootProgress(rootPath: path, title: title)
                    }
                    // 节流：距离上次 sync ≥ 0.4s 才推；否则只动 staging，等下个 partial 或最终
                    // result 之后的兜底 sync。这样 sidebar 新行最坏延迟 0.4s 出现，UX 无感。
                    let now = Date().timeIntervalSinceReferenceDate
                    if now - partialSyncBox.lastSync >= 0.4 {
                        partialSyncBox.lastSync = now
                        self.syncPerRootPublished(from: self.perRootStaging)
                    }
                }
            }
            let result = await scanner.discoverWithMetadataStreamed(
                home: URL(fileURLWithPath: homeStr),
                flushEvery: 20,
                onPartial: onPartial
            )
            let hits = result.hits
            // 防过期：勘察期间用户可能切走或重新点击其他扫描入口
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.activeCategoryID == activeID else { return }
                // v2026.06.21：banner 状态字段保留（内部诊断用，UI 已不读），
                // 但 maxHits=.max 后实际永远不会进 truncated 路径。
                self.devArtifactDidTruncate = false
                self.devArtifactDidTimeout = false
                if hits.isEmpty {
                    // 0 命中：直接 publish 一个 finished snapshot，让 UI 不再卡在"扫描中…"
                    self.resetPerRootPublished()
                    self.perRootStaging = [:]
                    self.snapshot = ScanSnapshot(categoryID: activeID, rows: [],
                                                 totalBytes: 0, scannedFileCount: 0,
                                                 isFinished: true,
                                                 elapsed: Date().timeIntervalSince(self.startedAt))
                    self.isScanning = false
                    GSYLog.info(.scan, "DevArtifact 勘察 0 命中 直接结束扫描")
                    return
                }
                // v2026.06.21：partial 阶段已经把 hits 增量预填进 perRootStaging 了；
                // 这里只补齐 partial 没收到的尾巴（理论上 onPartial 在末尾会 flush 残余，
                // 但仍按"以最终结果为准"做一次最终对账）。
                var finalStaging = self.perRootStaging
                for hit in hits {
                    let path = hit.url.path
                    if finalStaging[path] != nil { continue }
                    let shortPath = self.shortenPath(path, home: self.home)
                    let localizedDisplay = String(localized: String.LocalizationValue(hit.displayName), bundle: .module)
                    let title = "\(localizedDisplay) · \(shortPath)"
                    finalStaging[path] = PerRootProgress(rootPath: path, title: title)
                }
                self.perRootStaging = finalStaging
                self.syncPerRootPublished(from: finalStaging)

                let roots = hits.map { $0.url }
                // 估算总字节，给 ETA 用
                Task { [weak self] in
                    let estimated = await TreeSizeEstimator.estimate(roots: roots, timeout: 4.0)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard self.activeCategoryID == activeID else { return }
                        self.expectedTotalBytes = estimated
                    }
                }

                // 起真正的多根扫描——复用 runMultiRootScan 全套
                // v2026.06.21：用户反馈"卡顿比之前更糟糕"。maxHits=.max 后 dev 扫
                // 命中数可能上千；fan-out 时 3 并发仍然每秒产生大量 .nodes 事件
                // 打主 actor。再降一档到 2，让 UI 有更多空档期 layout / 响应手势。
                self.scanTask = Task { [weak self] in
                    await self?.runMultiRootScan(roots: roots, options: options,
                                                 categoryID: activeID,
                                                 maxConcurrentRoots: 2)
                }
            }
        }
    }

    /// v1.4：把 `~/Foo/Bar/node_modules` 缩成 `~/Foo/Bar` 形式以便 UI 展示。
    private nonisolated func shortenPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func runScan(rootURL: URL, categoryID: String, includeHidden: Bool, staySingleVolume: Bool = false) async {
        let rootPath = rootURL.path
        // v1.0 T2：把 AppSettings.showHidden 透传到 ScanOptions
        // v1.0 T5：整盘扫描时叠加 staySingleVolume=true（详见 ScanOptions 文档）
        // v1.3：FDA 已授予时关掉 TCC 硬 skip，让用户原本就有权限读的目录被正常下钻；
        //       同时不再 yield .tccProtectedSkipped，banner 不再误报。
        // v1.3 review-fix Must4：见上方多根入口同名注释。`.unknown` 不应触发 TCC banner，仅 `.denied` 触发。
        let respectTCC = (fdaStatus == .denied)
        let options = ScanOptions(
            includeHidden: includeHidden,
            staySingleVolume: staySingleVolume,
            respectTCCSkipList: respectTCC
        )
        let scanner = BulkScanner(options: options)
        var lastEmit = Date(timeIntervalSince1970: 0)
        // v1.3.z 性能修复（App 实测 90s 定位结论）：
        // 主线程 sample 显示 95% 时间在 SwiftUI ViewGraph flushTransactions / MainView.body 重算，
        // 节流 150ms = 每秒 6.7 帧 body，扫 90s = 600 次全 body 重计算（results / statusBar /
        // footerBar / selectedRows.filter）；扫描期 UI 没人盯帧率，250-400ms 完全够看到字节跳动。
        // 抬到 0.40 后预期 ViewGraph 重算次数降到 ~2.5 fps，主线程让出给 ingest。
        let throttle: TimeInterval = 0.40
        // v1.3.y 性能修复（workspace 7 分钟卡死定位结论）：
        // BulkScanner unbounded buffer 在 72 万 .node 量级会让 for-await 在 @MainActor 上
        // 连续吃完缓冲区中的几百~几千个事件才返回，期间 SwiftUI ViewGraph 完全没机会渲染，
        // 但 publishSnapshot 又持续 mutate @Published snapshot 字段 → ObservationCenter
        // 累积海量 pending invalidate，下次让出时一次性遍历所有 KeyPath（hash 风暴），
        // 主线程被压在 ObservationRegistrar.State.cancel 里几乎 100% CPU 跑不动 ingest。
        // 解决：每处理 yieldEvery 个事件主动 await Task.yield()，让主 actor 短暂让出
        // 给 RunLoop / ViewGraph，invalidate 摊销而非堆积。
        let yieldEvery = 256
        var consumedSinceYield = 0

        for await event in scanner.scan(root: rootURL) {
            if Task.isCancelled { break }
            // v1.3 防 [坑 1]：旧 stream 残留事件污染新 snapshot。
            // activeCategoryID 在 cancel() 里被清空、在新 scan 入口被重新打上；只要本次 stream 已被
            // 新一轮 scan 取代，下面这一行就会让旧 for-await 立刻跳出循环，不再写 buckets/dirIndex。
            guard activeCategoryID == categoryID else { break }
            switch event {
            case .node(let node):
                ingest(node: node, rootPath: rootPath)
            case .nodes(let arr):
                // Step 13B micro-batch：批量 ingest，减少跨 actor hop 开销
                for node in arr { ingest(node: node, rootPath: rootPath) }
            case .progress(let bytes, let count):
                // BulkScanner 自带的 progress 我们也用上，但首选 node 累计
                _ = bytes
                _ = count
            case .finished:
                break
            case .failed(let error):
                lastError = "\(error)"
            case .permissionDenied(let path):
                // 权限被拒目录上报 UI：去重 + 保序累加到 permissionDeniedPaths
                // 不再覆盖 lastError，避免抹掉真正的 .failed 错误
                if !permissionDeniedPaths.contains(path) {
                    permissionDeniedPaths.append(path)
                }
            case .tccProtectedSkipped(let path):
                // v1.1：TCC 雷区目录被主动跳过，去重累加到 banner 列表
                if !tccProtectedSkippedPaths.contains(path) {
                    tccProtectedSkippedPaths.append(path)
                }
            case .cacheDirTagged:
                // v1.5 Step 8：CACHEDIR.TAG 命中——单根扫描忽略；
                // safe 候选由后续 SafetyEngine 路径级 verdict 兜底，这里不重复 banner。
                break
            }

            // 节流：≥150ms 推一次（PITFALLS §5.4）
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                publishSnapshot(categoryID: categoryID, finished: false)
            }

            // 性能修复：每 N 个事件让出一次主 actor（详见上方注释）
            consumedSinceYield += 1
            if consumedSinceYield >= yieldEvery {
                consumedSinceYield = 0
                await Task.yield()
            }
        }
        // v1.3 防 [坑 1] 收尾：只有当本次 runScan 仍是当前活跃 scan 时才标记 finished。
        // 若已被新 scan 取代，本次"完成"事件不应该覆盖新的 in-progress snapshot；
        // isScanning / scanTask 由新 scan 自己管理，这里也不要重置。
        guard activeCategoryID == categoryID else { return }
        // v1.3.zzz 关键时序修复：finalize 必须**先于** publishSnapshot(finished:true)。
        // 旧时序：publishSnapshot → view 立即拉树形 → query 0 条（GRDB 还没 commit）。
        // 新时序：先 await flushAndFinalizeStoreAsync() 让 GRDB 写入全部落盘，再 publish
        // finished → view 看到的"扫描完成"瞬间 query 一定能命中。
        // M1 内存优化：扫完把残留 batch 写盘并 finalize session。
        await flushAndFinalizeStoreAsync()
        publishSnapshot(categoryID: categoryID, finished: true)
        isScanning = false
        scanTask = nil
        activeCategoryID = nil
        // v1.3.zz 流式修复 ③：扫描结束后清掉 treeChildrenCache 里"扫描期间被钉空"
        // 的所有项目，让 TreeBrowserView 下一帧重新拉一次"finalize 之后的全量结果"。
        // 之所以放在 isScanning=false 之后：directChildren 写回逻辑判 isScanning 决定是否
        // 钉 cache；这里清完后下一次 fetch 即便 rows 仍然空也会被正常缓存（终态空 = 真没数据）。
        invalidateTreeCacheAfterScan()
        // v1.3：扫描完成后刷新一次容量，与 Finder/系统设置口径一致。
        // 删除发生时另行调 refreshVolumeCapacity（见 MainView.performDelete）。
        refreshVolumeCapacity()
    }

    /// v1.3：多根并行扫描的主消费循环。
    ///
    /// 与 [runScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的差别：
    /// - 事件流是 [MultiRootEvent](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/MultiRootScanner.swift)，
    ///   带 `rootPath` 信封，`ingest(node:rootPath:)` 直接拿到正确根；
    /// - 每个 .node 同时累加全局 totalBytes / scannedFiles **和** 该根的 perRootProgress；
    /// - 每个 .finished 翻该根的 isFinished=true；所有根 finish 后 stream 自然关闭。
    private func runMultiRootScan(roots: [URL], options: ScanOptions, categoryID: String, maxConcurrentRoots: Int = 4) async {
        let scanner = MultiRootScanner(options: options)
        var lastEmit = Date(timeIntervalSince1970: 0)
        // v1.3.z 性能修复：见 runScan 同名注释。多根模式 throttle 同步抬到 0.40。
        let throttle: TimeInterval = 0.40
        // v1.3.y 性能修复：见 runScan 同名注释。多根模式同样需要让出主 actor。
        // v2026.06.21 修复 #4（卡顿+超长）：
        //   - 旧实现 `yieldEvery=256` 是按**事件数**计，而 `.nodes(arr)` 一个事件可能含
        //     几百个 node，主线程实际处理时间远超字面值。dev scan discover 命中几十根 +
        //     每根几万 node 时，主线程被 ingest 连续占住 200~500ms，列表滑动直接卡死。
        //   - 改为按**实际处理的 node 个数**累加：`.node` 计 1、`.nodes(arr)` 计 `arr.count`。
        //   - 阈值降到 96：node 路径上典型 ingest ~5–15µs，96 节点 ≈ 0.5–1.5ms 让出一次，
        //     既能保证 ProMotion 120Hz 滑动 (8.3ms/帧) 有足够主线程空隙，又不让 ingest
        //     吞吐被 yield 反噬（一次 await 调度本身有几十微秒成本）。
        let yieldEvery = 96
        var consumedSinceYield = 0

        for await wrapped in await scanner.scan(roots: roots, maxConcurrentRoots: maxConcurrentRoots) {
            if Task.isCancelled { break }
            // 与 runScan 同款过期事件保护：activeCategoryID 被覆盖即旧 stream 残留事件，丢弃。
            guard activeCategoryID == categoryID else { break }
            let rootPath = wrapped.rootPath
            // v2026.06.21 修复 #4：本事件实际"处理了几个 node"，作为 yield 计数权重。
            // .node 计 1；.nodes(arr) 计 arr.count；非数据事件计 1（让控制类事件也参与 yield）。
            var consumedThisEvent = 1
            switch wrapped.event {
            case .node(let node):
                ingest(node: node, rootPath: rootPath)
                if !node.isDirectory, var p = perRootStaging[rootPath] {
                    p.bytes += displayBytes(of: node)
                    p.fileCount += 1
                    perRootStaging[rootPath] = p
                }
            case .nodes(let arr):
                // Step 13B micro-batch：批量 ingest，per-root staging 累计也批量更新
                var stagingDelta: (bytes: Int64, files: Int) = (0, 0)
                for node in arr {
                    ingest(node: node, rootPath: rootPath)
                    if !node.isDirectory {
                        stagingDelta.bytes += displayBytes(of: node)
                        stagingDelta.files += 1
                    }
                }
                if stagingDelta.files > 0, var p = perRootStaging[rootPath] {
                    p.bytes += stagingDelta.bytes
                    p.fileCount += stagingDelta.files
                    perRootStaging[rootPath] = p
                }
                consumedThisEvent = max(1, arr.count)
            case .progress:
                break
            case .finished:
                if var p = perRootStaging[rootPath] {
                    p.isFinished = true
                    perRootStaging[rootPath] = p
                }
                // v1.3：原本 .finished 是低频事件，立刻同步到 @Published 让 UI 看到"该根已完成"。
                // v1.5 性能修复：dev scan discover 命中几十/几百根时，.finished 风暴密集
                // 触发，每个 finished 都立即整体替换 perRootProgress dict → SwiftUI 把整个
                // sidebar / statusBar / list 重 diff 一次，列表滑动直接卡死。
                // 现在 .finished 也并入下面的 throttle 统一节流（每 0.4s 同步一次），
                // 单根/少量根的扫描场景下 throttle 间隔本来就足够小，肉眼无感差异；
                // 而 dev scan 几百根场景下重画次数从 N 降到 ~elapsed/0.4，主线程立刻回归。
                //
                // v1.5 review-fix #8：小批量根（≤10）场景把 .finished 立刻 publish 出去——
                // 推荐扫描固定 5 根、整盘扫描 1 根，throttle 0.4s 滞后看得见；
                // 仅 dev scan / fullDisk discover 命中很多根时才走纯 throttle 路径。
                if perRootStaging.count <= 10 {
                    syncPerRootPublished(from: perRootStaging)
                    lastEmit = Date()
                }
            case .failed(let error):
                // v1.3 review-fix P1-7：多根模式下错误必须带 rootPath 前缀，
                // 否则 5 根并发时同时 .failed 互相覆盖，用户看不到是哪根失败。
                let title = perRootStaging[rootPath]?.title ?? rootPath
                lastError = "[\(title)] \(error)"
            case .permissionDenied(let path):
                if !permissionDeniedPaths.contains(path) {
                    permissionDeniedPaths.append(path)
                }
            case .tccProtectedSkipped(let path):
                if !tccProtectedSkippedPaths.contains(path) {
                    tccProtectedSkippedPaths.append(path)
                }
            case .cacheDirTagged:
                // v1.5 Step 8：多根模式下命中 CACHEDIR.TAG 同样静默——SafetyEngine 兜底。
                break
            }

            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                // v1.3.zz 性能修复：节流同步 staging → @Published，让 UI 0.4s 看一次进度
                syncPerRootPublished(from: perRootStaging)
                publishSnapshot(categoryID: categoryID, finished: false)
                // v1.3 P0-C：publishSnapshot 触发 SwiftUI 大面积 invalidate，主动让 1ms
                // 给主线程跑 layout/render + 接受用户手势；不让的话下一批 .nodes 立即上来
                // 又把 MainActor 抢走，形成"扫得越快越卡"反馈环。
                try? await Task.sleep(nanoseconds: 1_000_000)
            }

            // v2026.06.21 修复 #4：按"实际 node 个数"累加，不再按 event 个数。
            // .nodes(arr) 一个 event 累 arr.count，从而真正让 yield 跟主线程占用对齐。
            consumedSinceYield += consumedThisEvent
            if consumedSinceYield >= yieldEvery {
                consumedSinceYield = 0
                await Task.yield()
            }
        }
        guard activeCategoryID == categoryID else { return }
        // v1.3.zz 性能修复：收尾把 staging 最后状态同步到 @Published，让 UI 看到完整最终值
        syncPerRootPublished(from: perRootStaging)
        // v1.3.zzz 关键时序修复（同 runScan 收尾）：finalize 必须**先于** publishSnapshot(finished:true)。
        // 旧时序：publishSnapshot → view 立即拉树形 → query 0 条（GRDB 还没 commit）。
        // 多根并行场景（推荐清理 5 根）原本一直是 fire-and-forget flushAndFinalizeStore()，
        // 用户反馈"还是一样"很可能就是命中此路径。改用 await 版本与 runScan 对齐。
        await flushAndFinalizeStoreAsync()
        publishSnapshot(categoryID: categoryID, finished: true)
        isScanning = false
        scanTask = nil
        activeCategoryID = nil
        // v1.3.zz 流式修复 ③：见 runScan 同名注释。
        invalidateTreeCacheAfterScan()
        refreshVolumeCapacity()
    }

    #if DEBUG
    /// 测试专用注入：模拟 BulkScanner yield 的 .permissionDenied 路径，
    /// 走的是和 runScan 同一条去重逻辑。仅 @testable 可见。
    internal func _testInjectPermissionDenied(path: String) {
        if !permissionDeniedPaths.contains(path) {
            permissionDeniedPaths.append(path)
        }
    }

    /// 测试专用注入：模拟 BulkScanner yield 的 .tccProtectedSkipped 路径。
    internal func _testInjectTCCSkipped(path: String) {
        if !tccProtectedSkippedPaths.contains(path) {
            tccProtectedSkippedPaths.append(path)
        }
    }
    #endif

    private func ingest(node: FSNode, rootPath: String) {
        // 把 node 归到"根的第一级子目录"——这是聚合行，不展平
        let nodePath = node.path
        guard nodePath.hasPrefix(rootPath + "/") else { return }
        let tail = String(nodePath.dropFirst(rootPath.count + 1))
        let firstSegment = tail.split(separator: "/", maxSplits: 1).first.map(String.init) ?? tail
        guard !firstSegment.isEmpty else { return }
        let bucketPath = "\(rootPath)/\(firstSegment)"

        // v1.3：刷新该 bucket 的"最近 ingest 时间"，作为 active 判定的活跃度信号。
        // 用 timeIntervalSinceReferenceDate 比 Date() 更轻量，单调递增足够。
        // v1.3.y 性能修复：72 万 .node 每次都写一次 lastIngestAt 主线程字典 → 主线程压力大。
        // 该值仅用于 publishSnapshot 时（≥150ms 一次）判 active，精度做到 ~50ms 完全够；
        // 同 bucket 在 50ms 窗口内重复的写入直接跳过，把字典写入次数从 N 降到 N / (50ms 内同 bucket node 数)。
        // v1.5 P1-D：去抖窗口从 0.05s 抬到 0.2s。配合 publishSnapshot 0.4s 节流与
        // activityWindow=0.8s 仍完全安全（active 判定不会误失活），但字典写入再降一档，
        // dev scan 几十/几百根高密度 ingest 时主线程字典写入压力进一步下降。
        let nowTI = Date.timeIntervalSinceReferenceDate
        if let prev = lastIngestAt[bucketPath], nowTI - prev < 0.20 {
            // 窗口内已写过，跳过
        } else {
            lastIngestAt[bucketPath] = nowTI
        }

        // v1.3：根据当前 accountingMode 选 logical / physical 字节作为"显示总量"。
        // logicalBytes 副字段始终维护 ATTR_FILE_TOTALSIZE，方便后续 UI 切口径无需重扫的优化。
        let bytes = displayBytes(of: node)

        // M1 内存优化：所有节点都进 store batch（store 开启时）。
        // 这里只 append 不 flush；flush 由满 1000 触发或 run* 收尾触发。
        if let sid = currentSessionID, resultStore != nil, storeHealthy {
            let parent = (nodePath as NSString).deletingLastPathComponent
            storeBatch.append(ScanResultRecord(
                sessionID: sid,
                node: node,
                parentPath: parent
            ))
            if storeBatch.count >= storeFlushBatchSize {
                flushStoreBatch()
            }
        }

        // 文件累计
        if !node.isDirectory {
            scannedFiles += 1
            totalBytes += bytes
        }

        let isDir = nodePath == bucketPath ? true : node.isDirectory
        // v1.3.z 性能优化：把"两次哈希查找"合并为"一次默认值构造 + modify accessor 写回"。
        // sample(80125, 5s) 显示 ingest 在主线程占 372 ticks，buckets 字典访问是其中热点之一。
        // 旧写法：`var b = buckets[k] ?? Bucket(...); ...; buckets[k] = b` —— 即便 hit
        // 也要每次构造 URL 默认值，且要做两次 hash 定位。
        // 新写法：用 `[k, default:]` 的 modify accessor —— hit 时不构造 URL，只走一次 hash。
        buckets[bucketPath, default: Bucket(
            url: URL(fileURLWithPath: bucketPath, isDirectory: true),
            isDirectory: true
        )].applyIngest(
            isFileNode: !node.isDirectory,
            isTopLevelBucket: nodePath == bucketPath,
            isDirEffective: isDir,
            bytes: bytes,
            logicalBytes: node.logicalSize,
            nodeMTime: node.modificationDate
        )

        // v1.0 T3：构建多层下钻索引。
        // - 叶子文件：累计到所有祖先目录的 dirIndex
        // - 任意 node：把它登记为父目录的直接子项（childEdges）
        // v1.3.z 性能开关：CLI bench / 性能基线场景关掉，跳过 576 万次主线程字典写入。
        if !node.isDirectory {
            // v1.0 T4：达到大文件阈值的叶子单独留底，供 LargeFilesView 用。
            // 注：与深索引开关解耦，largeFileLeaves 即便 deepIndex=off 也照常采集。
            if largeFileMinBytes > 0 && bytes >= largeFileMinBytes {
                largeFileLeaves.consider(LargeFileLeaf(
                    path: nodePath,
                    bytes: bytes,
                    modificationDate: node.modificationDate
                ))
            }
            if enableTreeDeepIndex {
                fileLeaves[nodePath] = (bytes: bytes, isDir: false, modificationDate: node.modificationDate)
                // v1.5.7 perf：沿路径回溯到 rootPath，把 size 加到所有祖先。
                // 旧实现：每步 `(cursor as NSString).deletingLastPathComponent` 触发一次
                // NSString 桥接 + 路径拷贝；大目录（>5w 文件）下 instrument 显示
                // NSPathStore2 / NSString.bridgeFromObjC 占主线程 ~12% 时间。
                // 新实现：在原生 String 上用 lastIndex(of: "/") 切片，零桥接零额外 alloc。
                var cursor = String._gsyParentPath(of: nodePath)
                while !cursor.isEmpty, cursor.hasPrefix(rootPath) {
                    var agg = dirIndex[cursor] ?? DirAgg()
                    agg.bytes += bytes
                    agg.logicalBytes += node.logicalSize
                    agg.fileCount += 1
                    dirIndex[cursor] = agg
                    if cursor == rootPath { break }
                    let parent = String._gsyParentPath(of: cursor)
                    childEdges[parent, default: []].insert(cursor)
                    cursor = parent
                }
                // 文件本身也作为父目录的直接子项
                let parent = String._gsyParentPath(of: nodePath)
                childEdges[parent, default: []].insert(nodePath)
            }
        } else if enableTreeDeepIndex {
            // 目录节点（即使没有累计字节，也把它登记到边集，避免空目录在树里漏掉）
            // v1.5.4：把目录自身的 inode mtime 写入 DirAgg（保留已有 bytes/fileCount/logicalBytes）
            var agg = dirIndex[nodePath] ?? DirAgg()
            // 仅在目录节点 ingest 时覆盖 modificationDate；后续叶子累加路径不再回写它，
            // 保持"目录 mtime = 目录自身 inode mtime"的 Finder 语义。
            if let m = node.modificationDate {
                agg.modificationDate = m
            }
            dirIndex[nodePath] = agg
            if nodePath != rootPath {
                let parent = (nodePath as NSString).deletingLastPathComponent
                if parent.hasPrefix(rootPath) || parent == rootPath {
                    childEdges[parent, default: []].insert(nodePath)
                }
            }
        }
    }

    // MARK: - T3 多层下钻 API

    /// 给 TreeBrowserView 用：取某目录路径下"直接子项"按 size 降序排好的列表。
    /// `path` 必须是当前扫描根的子路径或根本身。返回数组顺序稳定（size 大在前，size 相同按 path 升序）。
    public func directChildren(of path: String) -> [TreeRow] {
        directChildren(of: path, sortedBy: .sizeDesc)
    }

    /// v1.0 T5：支持自定义排序键的列出。供 TreeBrowserView 表头点击切排序。
    /// 排序稳定性：主键相等时一律按 path 升序兜底，保证 ForEach 不抖。
    ///
    /// v1.3.z 起：当 `enableTreeDeepIndex == false`（默认）且本路径不在内存索引中时，
    /// 走 store-fallback 缓存：本次同步返 cache（首次为空），同时启动后台 Task 通过
    /// `directChildrenAsync` 查 GRDB 写回 cache，下一帧 SwiftUI 自动重算。
    public func directChildren(of path: String, sortedBy key: TreeSortKey) -> [TreeRow] {
        // v1.5：多根扫描伪路径分支——把 perRootProgress 里的真实根升级成顶层 TreeRow。
        // 没有这一支时 path == "(多目录)" / "(开发者构建产物)" 在 store / childEdges 里
        // 都查不到任何子项 → directChildren 返 [] → TreeBrowserView 渲染
        // "No expandable children yet"（用户截图反馈）。
        // 真实根（如 ~/Library/Caches）展开后走的还是原 directChildren 逻辑。
        if path == ScanCoordinator.versionedRootSentinelPath {
            // v2026.06.21：开发者旧版本扫描不进 BulkScanner，所以 perRootProgress 是空的。
            // 直接把 snapshot.rows 升级为顶层 TreeRow——title/bytes 都现成，
            // 复用 [synthesizeVersionedTopLevel] 集中维护排序与 hasChildren=false 语义。
            return synthesizeVersionedTopLevel(sortedBy: key)
        }
        if ScanCoordinator.multiRootSentinelPaths.contains(path) {
            return synthesizeMultiRootTopLevel(sortedBy: key)
        }
        if let kids = childEdges[path] {
            return materializeFromMemory(kids: kids, sortedBy: key)
        }
        // 内存索引不命中。enableTreeDeepIndex=on 时这就是"真没有"，直接返空（保持旧语义）。
        guard !enableTreeDeepIndex else { return [] }
        // deepIndex=off 路径：进 store-fallback 缓存。
        let cacheKey = "\(path)|\(key.rawValue)"
        if let cached = treeChildrenCache[cacheKey] {
            // v1.3.zz 流式修复 ②：扫描进行中时，cache 里的"空快照"会被周期性清掉
            // （见 invalidateEmptyCachesDuringScan），这里只在真正命中**非空** cache 时才返回。
            // 这样可以解决"第一次树形出来就空，再切回来还空"的死锁——
            // 扫描中从来不让一个空结果被钉死。
            if !cached.isEmpty || !isScanning {
                return cached
            }
        }
        // cache miss：启动一次后台 fetch（同 path 复用，不重复发）。
        if !treeChildrenInFlight.contains(cacheKey), resultStore != nil, currentSessionID != nil {
            treeChildrenInFlight.insert(cacheKey)
            // 派发瞬间快照 sid，让 task 自带"我属于哪个 session"上下文，
            // 写回时如果 sid 已经被新 scan 顶掉，则丢弃结果（不污染新会话 cache）。
            let dispatchedSid = currentSessionID
            Task { [weak self] in
                guard let self else { return }
                let rows = await self.directChildrenAsync(of: path, sortedBy: key)
                // 写回主线程缓存。@Published 会触发只依赖此条 cache 的 view 重算。
                await MainActor.run {
                    // v1.3.zz 流式修复 ①：跨会话保护——若 sid 在 fetch 期间被 cancel/scan 顶掉，
                    // 这次结果是"上一辈子"的，不能写进当前会话的 cache（否则下次 view 看到的是错的）。
                    guard dispatchedSid == self.currentSessionID else {
                        self.treeChildrenInFlight.remove(cacheKey)
                        return
                    }
                    // v1.3.zz 流式修复 ②：**扫描进行中**且 rows 为空时，**不**写 cache。
                    // 否则空结果会被锁住直到下次 cancel/scan 才清——用户看到的就是
                    // "树形从来没出来，因为第一帧 fetch 时 store 还空"。不写 cache → 下次
                    // body 重渲染会再次触发 fetch，每次拉到的都是当下最新的 ingested 量。
                    // 节流保护见 treeChildrenInFlight：同 path 不会重复并发。
                    if rows.isEmpty && self.isScanning {
                        self.treeChildrenInFlight.remove(cacheKey)
                        return
                    }
                    self.treeChildrenCache[cacheKey] = rows
                    self.bumpChildrenCacheVersion()
                    self.treeChildrenInFlight.remove(cacheKey)
                    // v2026.06.21 性能：原本这里 `bumpStructuralRevision()` —— 但每次
                    // 后台 fetch 回写都让 TreeBrowserView 整树 rebuild（DFS + verdict +
                    // perRoot 顶层合成 O(N log N)），dev/批量扫描期 cache miss 频繁
                    // 时直接把主线程打满。改为只 bump `childrenCacheVersion`；
                    // TreeBrowserView 单独 onChange 它做"仅当影响可见 flatRows 时局部
                    // 刷新"。剪枝/scan 结束/排序切换那些真正的结构性变更仍走 structural。
                }
            }
        }
        return []
    }

    /// v1.3.zz 流式修复 ③：扫描结束（runScan/runMultiRootScan 末尾、flushAndFinalizeStore 之后）时调用，
    /// 把 cache 里**所有**项目作废，触发下一次 view body 重新拉一次"finalize 后的全量结果"。
    ///
    /// **v1.3.zzzz 修复**：之前实现是"只清空 cache，保留非空"，初衷是避免扫完后 600ms 真空闪烁。
    /// 但实测日志（[/tmp/gsy-tree.log](file:///tmp/gsy-tree.log) `snapshotFiles=1752 ... rows=1000`）暴露
    /// 一个更严重的 bug：扫描中第一次 fetch 时，[storeBatch](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 还没全 flush，GRDB 里只有 1000 条（`storeFlushBatchSize` 触发的批量提交节点），
    /// fetch 拿到的是**残缺的部分快照**。一旦写进 cache，"只清空"策略保留下这条
    /// 非空但残缺的 1000 行，扫完后 view 永远 cache-hit → **总和与清单对不上**。
    ///
    /// 闪烁其实来自上一轮的 GRDB query race（`flushAndFinalizeStore` fire-and-forget 导致
    /// query 拿 0 条），那个已经在 [flushAndFinalizeStoreAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 修干净。现在 finalize 之后 GRDB 一定 ready，全清 cache 后下一次 fetch
    /// 几十毫秒就回来，不会再有真空窗口。
    ///
    /// in-flight 集合**不**清，让正在飞的 task 自然写回（写回时跨会话守卫会自动跳过非当前 sid）。
    @MainActor
    fileprivate func invalidateTreeCacheAfterScan() {
        treeChildrenCache.removeAll(keepingCapacity: true)
        bumpChildrenCacheVersion()
        bumpStructuralRevision()
    }

    /// v2026.06 用户反馈 #1：Tree 右键"刷新此目录"入口。
    ///
    /// **范围**：仅清掉 store-fallback 缓存（[treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L299)）
    /// 中以 `path` 为根的所有 cacheKey（含子目录、所有 sortKey 组合），并触发
    /// [bumpStructuralRevision()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L379)
    /// 让 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 重新走 [directChildren(of:sortedBy:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1422)
    /// → store-fallback 异步重拉。
    ///
    /// **不做的事**：
    /// 1. 不重启 BulkScanner（那是 runScan 入口的事），全量扫描成本无法承担在右键菜单里；
    /// 2. 不改 `childEdges`（扫描期内存索引）——若该 path 命中 childEdges，下一帧 SwiftUI 仍走
    ///    [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1432)
    ///    返回 internal 索引（这是按设计：扫描态下树形已经是最新的，缓存只是冷启动的兜底）。
    /// 3. 不动 in-flight 集合，让正在飞的 task 自然写回（跨会话守卫已经保护好脏数据）。
    ///
    /// 用户在 deepIndex=off 路径下右键刷新一个目录，相当于"丢掉 store fallback 那一份残缺
    /// 快照，重新走 GRDB"——典型场景：浏览器 cache / Xcode DerivedData 在 app 后台跑过一轮，
    /// 用户回来发现 size 对不上，右键 refresh 即可。
    @MainActor
    public func rescanSubtree(at path: String) {
        let prefixSelf = "\(path)|"
        let prefixChildren = "\(path)/"
        let removedKeys = treeChildrenCache.keys.filter { key in
            key.hasPrefix(prefixSelf) || key.hasPrefix(prefixChildren)
        }
        guard !removedKeys.isEmpty || childEdges[path] == nil else {
            // 内存索引命中（扫描期最新数据）且无 store-fallback 缓存：无需任何动作。
            return
        }
        for key in removedKeys {
            treeChildrenCache.removeValue(forKey: key)
        }
        bumpChildrenCacheVersion()
        bumpStructuralRevision()
    }

    /// **v1.5.3**：把"已删除路径"从所有 UI 数据源里剔除——这是修复用户反馈
    /// "删除后没对应更新 item"的核心入口。
    ///
    /// 老实现的 [performDelete](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 真删成功后只 `selection.removeAll()` + `refreshVolumeCapacity()`，
    /// **从未告知 ScanCoordinator** 把已删 path 从 [snapshot.rows](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L268)
    /// 与 [treeChildrenCache](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L248)
    /// 移除——所以列表与树形继续显示已删行。
    ///
    /// 本方法处理三件事（按 UI 数据源分）：
    /// 1. **snapshot.rows**：基于 path 前缀过滤——删了 `/A/B` 时 `/A/B/C` 也算被删；
    ///    重新构造 [ScanSnapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L268)
    ///    时只动 rows / totalBytes / scannedFileCount，其他字段保持。
    /// 2. **buckets / dirIndex / childEdges / fileLeaves**：内存索引同步剔除，保证
    ///    [directChildren(of:sortedBy:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1048)
    ///    下次走 memory 分支也拿不到已删项；childEdges 受影响的"父"边集要去掉孩子。
    /// 3. **treeChildrenCache**：受影响的父目录条目失效。cacheKey 是 `"\(path)|\(sortKey)"`，
    ///    必须按 path 前缀匹配清掉所有该父目录的排序变体。
    ///
    /// 注：**store 层（GRDB）不动**——store 是"扫描结果归档"，删除是用户行为，
    /// 不应回写 store。下次扫描会重新建库覆盖旧 session。
    @MainActor
    public func pruneDeleted(paths: [String]) {
        guard !paths.isEmpty else { return }

        // 用前缀匹配 helper：直接相等或者 path 是 prefix + "/"。
        // 不能用纯 hasPrefix("/A/B")——会误中 "/A/Bbb"。
        let normalized: [String] = paths.map { p in
            // 去掉末尾的 `/` 让 prefix 比较稳定（"/A/B/" 与 "/A/B" 应等价）
            if p.count > 1, p.hasSuffix("/") { return String(p.dropLast()) }
            return p
        }
        func isUnderDeleted(_ candidate: String) -> Bool {
            for p in normalized {
                if candidate == p { return true }
                if candidate.hasPrefix(p + "/") { return true }
            }
            return false
        }

        // ① snapshot.rows：保持 categoryID / isFinished / elapsed 等。
        let oldSnap = self.snapshot
        let newRows = oldSnap.rows.filter { !isUnderDeleted($0.id) }
        if newRows.count != oldSnap.rows.count {
            let removedBytes = oldSnap.rows
                .filter { isUnderDeleted($0.id) }
                .reduce(Int64(0)) { $0 + $1.bytes }
            self.snapshot = ScanSnapshot(
                categoryID: oldSnap.categoryID,
                rows: newRows,
                totalBytes: max(0, oldSnap.totalBytes - removedBytes),
                scannedFileCount: oldSnap.scannedFileCount, // 不动：scannedFile 是历史扫描指标
                isFinished: oldSnap.isFinished,
                elapsed: oldSnap.elapsed,
                bytesPerSecond: oldSnap.bytesPerSecond,
                estimatedRemaining: oldSnap.estimatedRemaining
            )
        }

        // ② 内存索引：buckets/dirIndex/childEdges/fileLeaves
        let bucketKeys = buckets.keys.filter { isUnderDeleted($0) }
        for k in bucketKeys { buckets.removeValue(forKey: k) }

        // **v1.5.7 修订**：删除前先把每个被删项的贡献量从所有**祖先目录**的
        // [dirIndex](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L265-L265)
        // 减出去（这是与 [ingest L1219-L1231](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1219-L1231)
        // 严格对称的反操作）。否则祖先 `agg.bytes / agg.fileCount` 保留旧总和，
        // [materializeFromMemory L1593-L1602](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1593-L1602)
        // 取出来给 TreeBrowserView 的就是脏值——表现为"删完了子目录，祖先 size 没变"
        // （用户截图 gsy_flutter_demo 1.12 GB 不动）。
        //
        // 减法策略：
        // - **叶子文件**（fileLeaves 命中）：bytes、logicalBytes 用 leaf 自身值；fileCount 减 1
        // - **目录**（dirIndex 命中）：bytes/logicalBytes/fileCount 全部用 dirIndex 自身的聚合值
        //   （它已经包含子孙的累计 —— 因为 ingest 时祖先就把它整段累加上去）
        // - 沿路径回溯到 `/`（不限 rootPath，因为 prune 可能跨根；越界父节点 dict miss 直接跳过）
        //
        // 注意：被删项若有 *未被删的兄弟祖先链分支*，那条分支不受影响（按 path 上溯，分支天然隔离）。
        // 多次删同一棵子树的去重：被删项的祖先链如果本身也在 `paths` 里，对应父节点会在
        // 下面整段 removeValue 时一并清掉，减出来的值会消失（无副作用）。
        var pendingDecrements: [String: (bytes: Int64, logicalBytes: Int64, fileCount: Int)] = [:]
        @inline(__always)
        func accumulate(into ancestor: String, bytes: Int64, logicalBytes: Int64, fileCount: Int) {
            var cur = pendingDecrements[ancestor] ?? (0, 0, 0)
            cur.bytes &+= bytes
            cur.logicalBytes &+= logicalBytes
            cur.fileCount &+= fileCount
            pendingDecrements[ancestor] = cur
        }
        for delPath in normalized {
            // 取被删项的贡献量
            let contribBytes: Int64
            let contribLogical: Int64
            let contribCount: Int
            if let leaf = fileLeaves[delPath] {
                contribBytes = leaf.bytes
                contribLogical = leaf.bytes  // leaf 没单独存 logicalBytes，取近似
                contribCount = 1
            } else if let agg = dirIndex[delPath] {
                contribBytes = agg.bytes
                contribLogical = agg.logicalBytes
                contribCount = agg.fileCount
            } else {
                continue
            }
            // 沿路径回溯到顶层 "/"
            var cursor = (delPath as NSString).deletingLastPathComponent
            while !cursor.isEmpty, cursor != "/" {
                // 该祖先若本身在删除范围里，下面整段会 removeValue 掉，回溯无意义；早跳。
                if isUnderDeleted(cursor) { break }
                accumulate(into: cursor, bytes: contribBytes, logicalBytes: contribLogical, fileCount: contribCount)
                let parent = (cursor as NSString).deletingLastPathComponent
                if parent == cursor { break }
                cursor = parent
            }
        }
        for (ancestor, dec) in pendingDecrements {
            guard var agg = dirIndex[ancestor] else { continue }
            agg.bytes = max(0, agg.bytes - dec.bytes)
            agg.logicalBytes = max(0, agg.logicalBytes - dec.logicalBytes)
            agg.fileCount = max(0, agg.fileCount - dec.fileCount)
            dirIndex[ancestor] = agg
        }

        let dirKeys = dirIndex.keys.filter { isUnderDeleted($0) }
        for k in dirKeys { dirIndex.removeValue(forKey: k) }
        let leafKeys = fileLeaves.keys.filter { isUnderDeleted($0) }
        for k in leafKeys { fileLeaves.removeValue(forKey: k) }

        // **v2026.06.22**：把 LargeFilesView 的数据源 `largeFileLeaves` 一并清理。
        // 修复用户反馈"大文件列表删除后内容还在"——这条链路过去**完全独立**于 dirIndex/childEdges，
        // 历史 pruneDeleted 只动后两者，已删大文件永远残留 heap 直到下次 startScan 重置。
        // compactedLargeFileTopN（M3 内存优化后的二级缓存）同样需要清理，否则 compact
        // 之后大文件视图回退到该缓存时还会显示已删项。
        let largeRemoved = largeFileLeaves.removeAll(where: { isUnderDeleted($0.path) })
        if largeRemoved > 0 {
            GSYLog.info(.scan, "pruneDeleted largeFileLeaves 剔除 \(largeRemoved)")
        }
        if var cache = compactedLargeFileTopN {
            let beforeCache = cache.count
            cache.removeAll(where: { isUnderDeleted($0.path) })
            if cache.count != beforeCache {
                compactedLargeFileTopN = cache
                GSYLog.info(.scan, "pruneDeleted compactedLargeFileTopN 剔除 \(beforeCache - cache.count)")
            }
        }

        // childEdges 双向：把 key 命中的整段去掉；同时把别的父节点 children set 里的命中项剔除。
        let edgeKeysToDrop = childEdges.keys.filter { isUnderDeleted($0) }
        for k in edgeKeysToDrop { childEdges.removeValue(forKey: k) }
        for (parent, kids) in childEdges {
            let pruned = kids.filter { !isUnderDeleted($0) }
            if pruned.count != kids.count {
                childEdges[parent] = pruned
            }
        }

        // ③ **v1.5.3 修订**：原先这里粗暴 `treeChildrenCache.removeAll()`，
        // 后果是连"根目录"那条 cache 也被一起干掉，view 重渲拉根目录 → cache miss
        // → store-fallback 异步 fetch → 整页 "Loading children…"（用户截图：空白页）。
        //
        // 正确做法是**静默 patch**：
        //   a) cacheKey 的 path 部分本身是被删项或其子孙 → removeValue（这条 cache 已经无意义）
        //   b) cacheKey 的 path 不在被删范围内 → 行内 `rows.filter` 剔掉已删孩子
        //      （即便它不是真正的"父"，filter 也是 O(n) 安全 no-op）
        // 这样根目录 cache 与所有未受影响的祖先 cache 都保留同步路径，
        // view 重渲走 directChildren 时直接命中 cache，根本不触发 fetch。
        var newCache: [String: [TreeRow]] = [:]
        newCache.reserveCapacity(treeChildrenCache.count)
        for (cacheKey, rows) in treeChildrenCache {
            // cacheKey 形如 "path|sortKey.rawValue"，按最后一个 `|` 分割。
            // 任何 sortKey 都用 alphanumeric raw，不会出现在 path 里，简单 split 即可。
            let parentPath: String = {
                if let pipeIdx = cacheKey.lastIndex(of: "|") {
                    return String(cacheKey[..<pipeIdx])
                }
                return cacheKey
            }()
            // a) 这条 cache 自己就在被删范围内 → 整段丢
            if isUnderDeleted(parentPath) { continue }
            // b) 行内剔除已删孩子；filter 不命中时直接复用旧数组
            let pruned = rows.filter { !isUnderDeleted($0.path) }
            newCache[cacheKey] = (pruned.count == rows.count) ? rows : pruned
        }
        treeChildrenCache = newCache
        bumpChildrenCacheVersion()

        // v1.5.4：删除完毕 → 让 TreeBrowserView 立刻重建扁平 flatRows（移除已删行）。
        // v1.5.7：把"本次升 structuralRevision 的根因是这些 path 被删"以 hint 传出，
        // [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift#L190)
        // 在 onChange 闭包里通过 [consumeLastPrunedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L351)
        // 一次性取走，走"只剔子树"的增量 patch，避免万级目录整树 rebuild。
        lastPrunedPaths = Array(normalized)
        bumpStructuralRevision()

        // 卷容量重新探测：清完反馈"空闲变多"。
        refreshVolumeCapacity()

        // ④ **v1.5.3 新增**：把删除落到 store 层。不这样做的话 [directChildren](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1048)
        // 在内存索引 miss 时会走 store-fallback 异步读 GRDB，已删项原样写回 cache，
        // 用户视觉上"删了又冒出来"。后台 fire-and-forget：UI 已经走过乐观更新（步骤 ①-③），
        // store 写慢一点也不会影响视觉表现。
        if let store = resultStore, let sid = currentSessionID {
            let paths = normalized
            Task.detached {
                do {
                    try await store.deletePaths(sessionID: sid, paths: paths)
                } catch {
                    GSYLog.error(.scan, "deletePaths failed: \(error)")
                }
            }
        }
    }

    /// v1.3.zz：暴露给 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 区分"刚 cache miss、后台 fetch 还在飞" vs "真的查到 0 条子项"——
    /// 前者应显 ProgressView 占位避免误导用户以为没数据；后者才显"还没有可展开的子节点"。
    ///
    /// 实现：cacheKey 在 `treeChildrenInFlight` 集合 / 或者 deepIndex=off + store/sid 在场
    /// 但 cache 还没写回（首帧尚未派发 Task），都算 fetching。
    public func isFetchingChildren(of path: String, sortedBy key: TreeSortKey) -> Bool {
        // v1.5：多根伪路径下 directChildren 是同步合成（perRootProgress），不存在 fetching。
        if ScanCoordinator.multiRootSentinelPaths.contains(path) { return false }
        // 内存命中或 deepIndex=on 时，directChildren 已是同步路径，不存在 fetching。
        if childEdges[path] != nil { return false }
        guard !enableTreeDeepIndex else { return false }
        let cacheKey = "\(path)|\(key.rawValue)"
        if treeChildrenCache[cacheKey] != nil { return false }
        // store / sid 缺一就不可能 fetch，不算 fetching（让 view 立即显空态）。
        guard resultStore != nil, currentSessionID != nil else { return false }
        // 任意一种"还在飞 / 即将派发"都算 fetching：
        // - in-flight 集合含 cacheKey：Task 正在跑
        // - cache 没写回 + 不在 in-flight：这是 directChildren 第一帧的情况，下一帧才会派 Task
        return true
    }

    /// v1.5：多根扫描伪路径下合成"顶层" TreeRow——把 perRootProgress 里的真实根
    /// 升级成树形顶层节点。每行 path 是真实目录（如 ~/Library/Caches），
    /// 用户展开时 TreeBrowserView 会再次调 [directChildren(of:sortedBy:)](#) 拿真实的下一层
    /// （走原 childEdges / store-fallback 路径，无需改动）。
    /// - bytes / fileCount 直接复用 已统计好的值
    /// - title 沿用 .title（已带 displayName + 短路径）
    ///
    /// v1.5 review-fix #5：优先读 perRootStaging（实时最新），fallback perRootProgress。
    /// perRootProgress 经 throttle (0.4s) 才同步，扫描中切到树形顶层会有 ≤0.4s 滞后；
    /// 读 staging 拿到的是事件刚更新完的最新值。
    /// review-fix #6：hasChildren 不再硬编码 true—— fileCount==0 的 root（discover
    /// 命中但还未 ingest，或扫完确实空）就不显示披露三角，避免"展开后空树"的误导。
    private func synthesizeMultiRootTopLevel(sortedBy key: TreeSortKey) -> [TreeRow] {
        let source: [String: PerRootProgress] = perRootStaging.isEmpty ? perRootProgress : perRootStaging
        let rows: [TreeRow] = source.values.map { p in
            TreeRow(
                path: p.rootPath,
                title: p.title,
                bytes: p.bytes,
                fileCount: p.fileCount,
                isDirectory: true,
                hasChildren: p.fileCount > 0,
                accessState: .normal
            )
        }
        return sortTreeRows(rows, by: key)
    }

    /// v2026.06.21：开发者旧版本扫描结束后的 TreeBrowserView 顶层合成。
    ///
    /// 与 [synthesizeMultiRootTopLevel] 的区别：旧版本扫描不进 BulkScanner 管线，
    /// `perRootProgress` 永远空；hits 都已经放在 `snapshot.rows` 里（title 是带
    /// i18n 与版本号的 "iOS DeviceSupport · 18.0" 这种），所以直接把 snapshot.rows
    /// 上升成 TreeRow。`hasChildren=false`——TreeBrowserView 拿这个判定不画披露
    /// 三角；用户要看具体子文件可在 Finder 里展开（与多根 1-tier 风格一致）。
    private func synthesizeVersionedTopLevel(sortedBy key: TreeSortKey) -> [TreeRow] {
        let rows: [TreeRow] = snapshot.rows.map { row in
            TreeRow(
                path: row.url.path,
                title: row.title,
                bytes: row.bytes,
                fileCount: row.fileCount,
                isDirectory: row.isDirectory,
                hasChildren: false,
                accessState: .normal,
                modificationDate: row.modificationDate
            )
        }
        return sortTreeRows(rows, by: key)
    }

    /// v1.5：抽出 TreeRow 排序，给 synthesizeMultiRootTopLevel / 其他场景复用。
    /// 主键相等时统一按 path 升序兜底，保证 ForEach 不抖。
    private func sortTreeRows(_ rows: [TreeRow], by key: TreeSortKey) -> [TreeRow] {
        switch key {
        case .sizeDesc:
            return rows.sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.path < rhs.path
            }
        case .sizeAsc:
            return rows.sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes < rhs.bytes }
                return lhs.path < rhs.path
            }
        case .nameAsc:
            return rows.sorted { lhs, rhs in
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.path < rhs.path
            }
        case .nameDesc:
            return rows.sorted { lhs, rhs in
                if lhs.title != rhs.title { return lhs.title > rhs.title }
                return lhs.path < rhs.path
            }
        case .countDesc:
            return rows.sorted { lhs, rhs in
                if lhs.fileCount != rhs.fileCount { return lhs.fileCount > rhs.fileCount }
                return lhs.path < rhs.path
            }
        case .countAsc:
            return rows.sorted { lhs, rhs in
                if lhs.fileCount != rhs.fileCount { return lhs.fileCount < rhs.fileCount }
                return lhs.path < rhs.path
            }
        case .mtimeDesc:
            return rows.sorted { lhs, rhs in
                // nil 一律压最后，避免占位"最近"头部；与 LargeFile 排序一致
                let l = lhs.modificationDate, r = rhs.modificationDate
                if l == nil && r != nil { return false }
                if l != nil && r == nil { return true }
                if let l = l, let r = r, l != r { return l > r }
                return lhs.path < rhs.path
            }
        case .mtimeAsc:
            return rows.sorted { lhs, rhs in
                let l = lhs.modificationDate, r = rhs.modificationDate
                if l == nil && r != nil { return false }
                if l != nil && r == nil { return true }
                if let l = l, let r = r, l != r { return l < r }
                return lhs.path < rhs.path
            }
        }
    }

    /// 内存索引命中时的"老路径"渲染——抽出来给同步 directChildren 与 directChildrenAsync 复用。
    private func materializeFromMemory(kids: Set<String>, sortedBy key: TreeSortKey) -> [TreeRow] {
        let rows: [TreeRow] = kids.map { childPath in
            if let agg = dirIndex[childPath] {
                // 目录
                // v2026.06.20：agg.modificationDate 在"中间层 ancestor 目录"上经常为 nil
                // （BulkScanner 没单独 yield 该目录的 .node 事件，只把它当祖先累加 bytes）。
                // 用 [resolveDirMtimeFallback](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
                // lstat 一次拿磁盘 inode mtime，O(1) 缓存避免每帧 stat，让"修改时间"
                // 列对真实存在的目录都能显示出来。
                let mtime = agg.modificationDate ?? resolveDirMtimeFallback(forPath: childPath)
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: agg.bytes,
                    fileCount: agg.fileCount,
                    isDirectory: true,
                    hasChildren: !(childEdges[childPath]?.isEmpty ?? true),
                    modificationDate: mtime
                )
            } else if let leaf = fileLeaves[childPath] {
                // 文件
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: leaf.bytes,
                    fileCount: 1,
                    isDirectory: leaf.isDir,
                    hasChildren: false,
                    modificationDate: leaf.modificationDate
                )
            } else {
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: 0,
                    fileCount: 0,
                    isDirectory: false,
                    hasChildren: false
                )
            }
        }
        return rows.sorted { (a, b) in
            switch key {
            case .sizeDesc:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .sizeAsc:
                if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .nameAsc:
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case .nameDesc:
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                if cmp != .orderedSame { return cmp == .orderedDescending }
            case .countDesc:
                if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
            case .countAsc:
                if a.fileCount != b.fileCount { return a.fileCount < b.fileCount }
            case .mtimeDesc:
                let av = a.modificationDate, bv = b.modificationDate
                if av == nil && bv != nil { return false }
                if av != nil && bv == nil { return true }
                if let l = av, let r = bv, l != r { return l > r }
            case .mtimeAsc:
                let av = a.modificationDate, bv = b.modificationDate
                if av == nil && bv != nil { return false }
                if av != nil && bv == nil { return true }
                if let l = av, let r = bv, l != r { return l < r }
            }
            return a.path < b.path
        }
    }

    /// v1.3.z：异步 directChildren —— 当 deepIndex=off 让目录树仍可下钻。
    ///
    /// 路径选择：
    /// - 内存命中（deepIndex=on 或 path 已经在 childEdges 里）：直接走同步 `directChildren(of:sortedBy:)`，0 IO；
    /// - 否则若 store 已注入 + 当前会话 finalize 完毕：通过 `store.directChildrenAggregated(...)` 一条 SQL GROUP BY 拿结果；
    /// - 都没有：返回空数组（与同步版本同语义）。
    ///
    /// v1.3.zzzz 重写：把 Swift 侧的 Dictionary GROUP BY 整段下推到 SQL（参见
    /// [GRDBScanResultStore.directChildrenAggregated](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift)），
    /// 同时把 [permissionDeniedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L19)
    /// / [tccProtectedSkippedPaths](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L21)
    /// 合入结果的 [TreeRow.accessState](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L116)。
    /// UI 据此渲染锁定徽章而不是误导性的 0KB。
    ///
    /// 注意：本方法只读取 GRDB，不改任何 @Published / 内存索引；调用方负责把结果丢给 SwiftUI。
    public func directChildrenAsync(of path: String, sortedBy key: TreeSortKey) async -> [TreeRow] {
        // Fast path：内存里已经有，直接同步取（保持与 deepIndex=on 完全一致的行为）。
        if childEdges[path] != nil {
            return directChildren(of: path, sortedBy: key)
        }
        // Slow path：走 store。需要 store + 当前 sessionID 都在。
        guard let store = resultStore, let sid = currentSessionID else { return [] }
        GSYLog.debug(.tree, "directChildrenAsync 走 store path=\(path)")

        // v1.3.zzzz：把"该 path 的子项 + 子树聚合"整段下推到单条 SQL GROUP BY。
        // 替代旧版 query→Swift Dictionary GROUP BY 的 ~100ms 慢路径，目标 ~10ms。
        let aggregates: [DirectChildAggregate]
        do {
            aggregates = try await store.directChildrenAggregated(
                sessionID: sid,
                parentPath: path
            )
        } catch {
            GSYLog.error(.tree, "directChildrenAggregated 失败 path=\(path) err=\(error)")
            return []
        }

        // 从主线程读 access-denied 索引——这两个 @Published 数组在 ScanCoordinator
        // actor 上下文里访问是同步安全的。建 Set 之后查询是 O(1)。
        let deniedSet = Set(permissionDeniedPaths)
        let tccSet = Set(tccProtectedSkippedPaths)

        let prefix = path.hasSuffix("/") ? path : path + "/"
        let rows: [TreeRow] = aggregates.map { agg in
            let segPath = prefix + agg.segment
            // 决定这一行是文件还是目录：用 SQL 端聚合时算好的 isDirectory；
            // 兜底：hasInode=false 但只有 1 条文件 record 时 → 文件叶子。
            let isFileLeaf = !agg.isDirectory
                && agg.descendantCount == 1
                && agg.fileDescendantCount == 1
                && agg.descendantBytes == agg.fileDescendantBytes
            // accessState 优先级：tccProtected > permissionDenied > normal
            // tccProtected 是用户层"sandbox 整段拒"，permissionDenied 是"运行时拒"，
            // 都意味着子目录里没数据，但成因不同，UI 文案不一样。
            let accessState: TreeRow.AccessState
            if tccSet.contains(segPath) {
                accessState = .tccProtected
            } else if deniedSet.contains(segPath) {
                accessState = .permissionDenied
            } else {
                accessState = .normal
            }
            if isFileLeaf {
                return TreeRow(
                    path: segPath,
                    title: agg.segment,
                    bytes: agg.fileDescendantBytes,
                    fileCount: 1,
                    isDirectory: false,
                    hasChildren: false,
                    accessState: accessState,
                    modificationDate: agg.inodeModificationDate
                )
            } else {
                // 目录：bytes/count 用子树累加值。hasChildren 判定与旧版一致：
                // 至少 1 条记录，且不是"唯一一条直接孩子叶子"。
                // v2026.06.20：accessState == .normal 时（即真正能 stat 的目录）做 mtime 兜底，
                // 让 GRDB store-fallback 路径也能在 inodeModificationDate 缺失时显示出真实时间，
                // 与 [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
                // 的兜底逻辑一致。permissionDenied / tccProtected 不 stat，避免触发系统弹权限。
                let mtime: Date? = {
                    if let d = agg.inodeModificationDate { return d }
                    guard accessState == .normal else { return nil }
                    return resolveDirMtimeFallback(forPath: segPath)
                }()
                return TreeRow(
                    path: segPath,
                    title: agg.segment,
                    bytes: agg.descendantBytes,
                    fileCount: max(agg.descendantCount, 1),
                    isDirectory: true,
                    hasChildren: agg.descendantCount >= 1
                        && !(agg.descendantCount == 1 && agg.hasInode == false),
                    accessState: accessState,
                    modificationDate: mtime
                )
            }
        }

        return rows.sorted { (a, b) in
            switch key {
            case .sizeDesc:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .sizeAsc:
                if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .nameAsc:
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case .nameDesc:
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                if cmp != .orderedSame { return cmp == .orderedDescending }
            case .countDesc:
                if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
            case .countAsc:
                if a.fileCount != b.fileCount { return a.fileCount < b.fileCount }
            case .mtimeDesc:
                // nil 一律最后；保证"最近修改"头部不被空 mtime 占位
                let av = a.modificationDate, bv = b.modificationDate
                if av == nil && bv != nil { return false }
                if av != nil && bv == nil { return true }
                if let l = av, let r = bv, l != r { return l > r }
            case .mtimeAsc:
                let av = a.modificationDate, bv = b.modificationDate
                if av == nil && bv != nil { return false }
                if av != nil && bv == nil { return true }
                if let l = av, let r = bv, l != r { return l < r }
            }
            return a.path < b.path
        }
    }

    /// v1.3 bug1：根据 path O(1) 反查 TreeRow。
    /// 用于 TreeBrowserView 选中变化的 onSelect 回调——之前每点一次都要把整棵展开树
    /// 拍平递归一遍 (`visibleRows`)，4w 级展开节点下卡顿明显。这里用 dirIndex / fileLeaves
    /// 字典直接定位，避免遍历。
    public func row(for path: String) -> TreeRow? {
        if let agg = dirIndex[path] {
            // v2026.06.20：与 [materializeFromMemory](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
            // 同款 mtime 兜底，保证 onSelect → detail 面板与 tree 列里"修改时间"显示一致。
            let mtime = agg.modificationDate ?? resolveDirMtimeFallback(forPath: path)
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: agg.bytes,
                fileCount: agg.fileCount,
                isDirectory: true,
                hasChildren: !(childEdges[path]?.isEmpty ?? true),
                modificationDate: mtime
            )
        }
        if let leaf = fileLeaves[path] {
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: leaf.bytes,
                fileCount: 1,
                isDirectory: leaf.isDir,
                hasChildren: false,
                modificationDate: leaf.modificationDate
            )
        }
        return nil
    }

    // MARK: - T4 大文件 API

    /// v1.0 T4：取扫描期收集到的大文件，按视图阈值二次过滤、按 sortKey 排序、截到 limit 项。
    ///
    /// - Parameters:
    ///   - minSizeMB: 视图层阈值（MB）。**必须 ≥ 扫描期阈值**，否则视图能给出的就只是
    ///     当前已采集到的子集——这种情况下 UI 应当提示用户重新扫描（见 LargeFilesView）。
    ///   - sortKey: 排序键。
    ///   - limit: Top N 截断；ROADMAP T4 默认 200，避免一次性渲染数千行卡 UI。
    ///   - mtimeFilter: v1.2 P1-4 修改日期过滤。`.all` 时不做时间过滤。
    public func largeFiles(minSizeMB: Int,
                           sortKey: LargeFileSortKey,
                           limit: Int = 200,
                           mtimeFilter: AppSettings.MtimeFilter = .all)
        -> [LargeFileItem]
    {
        guard limit > 0 else { return [] }
        let minBytes = Int64(max(0, minSizeMB)) * 1024 * 1024
        let now = Date()
        // M3：主索引已被 compact 释放时回退到二级缓存（store 预读的 Top N）。
        // 既保证 UI 同步路径不变，又不让 compact 后页面空白。
        let source: [LargeFileLeaf]
        if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
            // compactedLargeFileTopN 是一个有限子集。自动 compact 已在 LargeFilesView 侧禁用，
            // 但测试/手动调用 compact 后仍应保持 list/count 一致；完整排序过滤需后续 store-backed 查询。
            source = cache
        } else {
            source = largeFileLeaves.snapshot()
        }
        let filtered = source
            .filter { $0.bytes >= minBytes }
            .filter { mtimeFilter.passes($0.modificationDate, now: now) }
            .map { LargeFileItem(path: $0.path, bytes: $0.bytes, modificationDate: $0.modificationDate) }
        let sorted = filtered.sorted { (a, b) in
            switch sortKey {
            case .sizeDesc:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .sizeAsc:
                if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .mtimeDesc:
                let ad = a.modificationDate ?? .distantPast
                let bd = b.modificationDate ?? .distantPast
                if ad != bd { return ad > bd }
            case .mtimeAsc:
                let ad = a.modificationDate ?? .distantFuture
                let bd = b.modificationDate ?? .distantFuture
                if ad != bd { return ad < bd }
            }
            // 主键相等 → path 升序兜底，保 ForEach 不抖
            return a.path < b.path
        }
        return Array(sorted.prefix(limit))
    }

    /// v1.0 T4：当前扫描会话采集到的"原始大文件叶子总数"——视图想提示
    /// "还有 X 项被截断"或者"未达到任何阈值"时用。
    /// M3：compact 之后回退到二级缓存的 count，UI 拿到的"集合大小"语义不变。
    public var largeFileCollectedCount: Int {
        if largeFileLeaves.isEmpty, let cache = compactedLargeFileTopN {
            return cache.count
        }
        return largeFileLeaves.count
    }

    /// v1.0 T4：当前会话扫描期阈值（bytes）。视图据此判断是否需要"调阈值后重扫"。
    public var largeFileScanThresholdBytes: Int64 { largeFileMinBytes }

    // MARK: - M1 内存优化：store flush / finalize / compact / 远端查询

    /// 把当前累计的 storeBatch 异步刷到 store。**MainActor 安全**：
    /// 取出 batch 引用 → 清空内存数组 → daisychain append。
    /// 失败把 storeHealthy 翻 false 静默降级。
    private func flushStoreBatch() {
        guard let store = resultStore, !storeBatch.isEmpty, storeHealthy else { return }
        let pending = storeBatch
        storeBatch.removeAll(keepingCapacity: true)
        // P0-B 修复：把这批 insert 串到 storeWriteChain 末尾，避免与后续 finalize 乱序。
        let prev = storeWriteChain
        storeWriteChain = Task.detached { [storeRef = store] in
            await prev?.value
            do {
                try await storeRef.insert(pending)
            } catch {
                // 失败仅静默降级——不能让 store 故障污染主扫描流程。
                // 不把 storeHealthy 翻 false 也无碍：下一次 flush 仍会尝试写，
                // 真要持续失败下次 batch 还是会失败，行为上等价，免去跨 actor 写共享态。
            }
        }
    }

    /// runScan / runMultiRootScan 收尾时调用：flush 残留 batch 并 finalize session。
    /// 任何失败都不抛出（functionality first：内存优化失败 != 扫描失败）。
    /// P0-B 修复：通过 daisychain 保证 finalize **严格在所有已派出 insert 之后**执行。
    ///
    /// **注意**：本方法是 fire-and-forget，detached task 还在跑就立刻返回。
    /// 如果调用方在返回后立刻发出"扫描完成"信号 → view 立刻 query GRDB →
    /// 会拿到 0 行（写入尚未落盘 / WAL 还没 commit）。
    /// 想确保 query 拿得到数据，必须改用 [flushAndFinalizeStoreAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)。
    private func flushAndFinalizeStore() {
        guard let store = resultStore, let sid = currentSessionID else { return }
        let pending = storeBatch
        storeBatch.removeAll(keepingCapacity: false)
        let healthy = storeHealthy
        let prev = storeWriteChain
        storeWriteChain = Task.detached { [storeRef = store] in
            // 等之前所有 insert 落盘后再 finalize，避免 finalize 抢先到 actor。
            await prev?.value
            // v1.5.7：不再 try?，insert/finalize 异常落日志（仍降级到 healthy 路径之外）。
            if healthy, !pending.isEmpty {
                do {
                    try await storeRef.insert(pending)
                } catch {
                    GSYLog.error(.scan, "flushStoreBatch insert sid=\(sid) count=\(pending.count) failed: \(error)")
                }
            }
            do {
                try await storeRef.finalizeSession(sid)
            } catch {
                GSYLog.error(.scan, "flushStoreBatch finalize sid=\(sid) failed: \(error)")
            }
        }
    }

    /// **v1.3.zzz 关键修复**：runScan / runMultiRootScan 收尾的"等待版"。
    ///
    /// 实测 bug（[/tmp/gsy-tree.log](file:///tmp/gsy-tree.log) `[grdb]` 行）：
    /// 扫完之后第一次 query GRDB 拿到 0 条记录，但 SQL 直接 `sqlite3 scan.sqlite`
    /// 同 sid 同 prefix 立即查得到 3631 条。差几百毫秒到几秒不等。
    ///
    /// 根因：旧的 fire-and-forget 版本 `flushAndFinalizeStore()` 把 insert+finalize
    /// 派到 `Task.detached` 里就立刻返回，runScan 紧接着 publishSnapshot(finished: true)，
    /// view 立刻渲染树形 → query 走 dbPool.read 拿到的是写入完成**之前**的快照。
    ///
    /// 修法：把 detached task 派出后**直接 await 它结束**。这样 publishSnapshot finished
    /// 之后所有写入都已 commit，view query 一定能命中。
    ///
    /// **v1.5.6 崩溃修复**（[Crash 2026-06-04 22:05:45](file:///Users/guoshuyu/Library/Logs/DiagnosticReports/GSYCleanMac-2026-06-04-220545.ips)
    /// `Thread stack size exceeded due to excessive recursion` /
    /// `swift_task_escalateImpl → withStatusRecordLock → callback_fn(escalateImpl::$_0)` 反复重入）：
    ///
    /// 旧实现把 insert+finalize 包在 `Task.detached`，detached 内 `await prev?.value`，
    /// caller 又 `await task.value` —— **两层 await 嵌套在同一条 task dependency chain 上**。
    /// macOS 26.2 / Swift 6.x runtime 在做 priority escalation 时遍历该 chain 出现递归不收敛，
    /// 把 cooperative 线程栈写穿（thread 7 栈顶 0x000000016b7d7ff0 落在 guard page）。
    ///
    /// 新实现去掉中间那层 detached：caller **直接在 MainActor 上**先等链尾，再亲自
    /// `await store.insert/finalize`。actor 本身的 mailbox 串行性 + 单一调用方 = 顺序保证。
    /// chain 字段保持 nil → fire-and-forget [flushStoreBatch](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1879)
    /// 的 daisychain 语义不受影响（它仍然继续 chain 自己的）。
    ///
    /// 测试覆盖：[StoreWriteOrderingTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/StoreWriteOrderingTests.swift)
    /// 全 4 契约（含"finalize 严格在所有 insert 之后"、"async 返回时 leftover/finalize 全落盘"）
    /// 必须仍然全绿。
    private func flushAndFinalizeStoreAsync() async {
        guard let store = resultStore, let sid = currentSessionID else { return }
        let pending = storeBatch
        storeBatch.removeAll(keepingCapacity: false)
        let healthy = storeHealthy
        // 取走当前链尾；把字段先清 nil 防止后续 fire-and-forget 续到这条死 chain 上。
        let prev = storeWriteChain
        storeWriteChain = nil
        // 1) 先在 MainActor 上等链上残余（fire-and-forget 的 insert）落盘。
        //    这一次 await 是"caller 上的纯等待"，不再嵌套到一个内部 await 同 chain 的 detached 里，
        //    runtime escalation 不会再有递归边。
        await prev?.value
        // 2) caller 亲自 await actor —— store 是 actor，mailbox 天然 FIFO；
        //    单调用方场景下，串行性由"先 insert 再 finalize"的代码顺序直接保证。
        // v1.5.7：不再 try? 静默吞错，insert/finalize 异常都要进日志。
        if healthy, !pending.isEmpty {
            do {
                try await store.insert(pending)
            } catch {
                GSYLog.error(.scan, "flushAndFinalize insert sid=\(sid) count=\(pending.count) failed: \(error)")
            }
        }
        do {
            try await store.finalizeSession(sid)
        } catch {
            GSYLog.error(.scan, "flushAndFinalize finalize sid=\(sid) failed: \(error)")
        }
    }

    /// **M1 核心**：把"扫完后内存大头"的缓存释放掉，下次需要时从 store 流式查询。
    ///
    /// 释放内容（实测口径）：
    /// - largeFileLeaves（大文件叶子）+ lastIngestAt（已不再有 active 判定需求）
    /// - 量级 KB ~ MB 级（取决于 `largeFileMinBytes` 与命中数）。**注意**：扫描后真正
    ///   占大头的是 dirIndex / childEdges / fileLeaves（百 MB 级），由 store 替代后续会处理；
    ///   本方法**不动**这些主索引（保留树视图依赖）。
    ///
    /// **保留**：
    /// - buckets（一级聚合行 —— RowItem 渲染需要，量小）
    /// - dirIndex / childEdges / fileLeaves（树视图依赖；后续 M 再迁移到 store）
    ///
    /// 调用约束：
    /// - 仅在 `isFinished == true` 且本轮 store 健康时才执行（否则 noop）。
    /// - 仅当 [AppSettings.useScanStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppSettings.swift) ON
    ///   且 resultStore 已注入时由 UI 主动调用（如 LargeFilesView.onDisappear）。
    /// - 调完之后 [largeFileCollectedCount](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    ///   会归零；UI 必须改走 [largeFilesFromStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    ///   读盘。
    public func compactAfterScan() {
        guard isFinished, resultStore != nil, storeHealthy else { return }
        largeFileLeaves.removeAll(keepingCapacity: false)
        lastIngestAt.removeAll(keepingCapacity: false)
    }

    /// **M3 核心**：[compactAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 的"UI 无感"增强版。
    ///
    /// 旧 [compactAfterScan](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift) 直接清空 [largeFileLeaves](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 后，UI 重进大文件页时 `largeFiles(...)` 返回空——必须改写视图层异步重新查询，侵入式。
    ///
    /// 本方法的玩法：
    /// 1. 先从 store 异步拿当前 session 的 Top N 大文件（默认 N=200，与 LargeFilesView 渲染上限一致）
    /// 2. 把结果回填到内部缓存 `compactedLargeFileTopN`
    /// 3. 再清空主索引 [largeFileLeaves](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 4. UI 端 `largeFiles(...)` 自动 fallback 到该缓存（同步、零侵入）
    ///
    /// 内存帐（实测口径，不夸大）：
    /// - 释放：本轮 session 累计的 `largeFileLeaves`（每记录 ~64B）+ `lastIngestAt`
    ///   字典。`largeFileMinBytes` 默认下大文件叶子量级是数百 ~ 数千条（KB ~ MB 量级），
    ///   并非主索引大头（dirIndex/childEdges/fileLeaves 才是真正百 MB 级，仍由 store 替代后再处理）。
    /// - 保留：Top N 缓存（N=200 → 200 × 64B ≈ 12.8 KB），可忽略。
    /// - 净收益：消除 LargeFilesView 长会话内的"叶子持续累积"，UI 体验无回退。
    ///
    /// 调用约束（与同步版一致）：
    /// - 仅 `isFinished == true` 且 store 可用时执行；否则 noop。
    /// - 任何 store 失败均静默降级（functionality first）。
    /// - **跨 await TOCTOU 防御**：`store.query` 是 async，期间 `cancel()` 或新 `scan()` 可能
    ///   把 `currentSessionID` 重置 / 替换。await 后必须重校验 `currentSessionID == sid && isFinished`，
    ///   否则会把上一会话的 Top N 错误覆盖到新会话状态、并清空新会话正在累积的 `largeFileLeaves`。
    public func compactAfterScanPreservingCache(topN: Int = 200) async {
        guard isFinished, let store = resultStore, let sid = currentSessionID, storeHealthy else { return }
        guard topN > 0 else {
            // 等价于旧同步行为
            largeFileLeaves.removeAll(keepingCapacity: false)
            lastIngestAt.removeAll(keepingCapacity: false)
            return
        }
        let q = ScanResultQuery(
            sessionID: sid,
            onlyFiles: true,
            limit: topN,
            offset: 0,
            sort: .allocatedSizeDescending
        )
        let preloaded: [LargeFileLeaf]
        do {
            let rows = try await store.query(q)
            preloaded = rows.map {
                LargeFileLeaf(path: $0.path, bytes: $0.allocatedSize, modificationDate: $0.modificationDate)
            }
        } catch {
            // store 故障：不释放主索引，避免空白回退；下次 UI 触发会重试。
            return
        }
        // M3-P0 修复：await 之后重校验 session/isFinished 一致性，规避 cancel→重扫 race
        guard currentSessionID == sid, isFinished else {
            // 上一会话的结果已不再适用：丢弃 preloaded、不动 largeFileLeaves
            return
        }
        compactedLargeFileTopN = preloaded
        largeFileLeaves.removeAll(keepingCapacity: false)
        lastIngestAt.removeAll(keepingCapacity: false)
    }

    /// 从 store 取大文件（异步分页查询版）。
    /// 仅当 store 注入且本轮 session 仍在时返回有效数据；否则返回空数组。
    ///
    /// 与同步版 [largeFiles](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 的差别：后者从内存数组读，compactAfterScan 之后会空；本方法走磁盘，compact 之后仍可用。
    /// LargeFilesView 应在 compact ON 路径下优先调本方法。
    public func largeFilesFromStore(minSizeMB: Int,
                                    sortKey: LargeFileSortKey,
                                    limit: Int = 200,
                                    mtimeFilter: AppSettings.MtimeFilter = .all) async -> [LargeFileItem] {
        guard let store = resultStore, let sid = currentSessionID, limit > 0 else { return [] }
        let q = ScanResultQuery(
            sessionID: sid,
            onlyFiles: true,
            limit: max(limit * 4, 800),
            offset: 0,
            sort: .allocatedSizeDescending
        )
        let rows: [ScanResultRecord]
        do { rows = try await store.query(q) } catch { return [] }
        let minBytes = Int64(max(0, minSizeMB)) * 1024 * 1024
        let now = Date()
        let filtered = rows
            .filter { $0.allocatedSize >= minBytes }
            .filter { mtimeFilter.passes($0.modificationDate, now: now) }
            .map { LargeFileItem(path: $0.path, bytes: $0.allocatedSize, modificationDate: $0.modificationDate) }
        let sorted = filtered.sorted { (a, b) in
            switch sortKey {
            case .sizeDesc:
                if a.bytes != b.bytes { return a.bytes > b.bytes }
            case .sizeAsc:
                if a.bytes != b.bytes { return a.bytes < b.bytes }
            case .mtimeDesc:
                let ad = a.modificationDate ?? .distantPast
                let bd = b.modificationDate ?? .distantPast
                if ad != bd { return ad > bd }
            case .mtimeAsc:
                let ad = a.modificationDate ?? .distantFuture
                let bd = b.modificationDate ?? .distantFuture
                if ad != bd { return ad < bd }
            }
            return a.path < b.path
        }
        return Array(sorted.prefix(limit))
    }

    private func publishSnapshot(categoryID: String, finished: Bool) {
        // v1.3 修「只有一行在动」错觉：
        //   扫描期间按 path 字典序排（位置稳定），让用户看到所有一级子目录的字节
        //   各自独立、同时跳动；只有 finished=true 那一帧切到用户选定的 mainListSortKey
        //   （默认 sizeDesc），呈现最终结果。
        //
        // 背景：之前一直按 bytes 降序排，结果"最大的 bucket"永远固定在第一行，且
        //   它的字节增长得最快——视觉上就是"列表只有第一行数字在变"，给用户造成
        //   "多线程没生效，只在扫一个目录"的错觉。实际上 6 worker 真的在扫 6 个
        //   不同子目录，所有 bucket 都在涨。
        //
        // v1.3：每个 row 携带 isActive 标志（最近 activityWindow 内有 ingest 写入即 active），
        //   UI 给 active 行的 bytes 数字上色 + 脉动，让"哪些 worker 正在扫"视觉化。
        //   finished=true 那帧强制 isActive=false（扫完就不该再亮）。
        //
        // 副作用：扫描期间行序按 path 字典序而非 size 降序——这是必要的代价，
        //   且与许多竞品（CleanMyMac 实时扫描态）一致。完成后立刻切回用户排序。
        let now = Date.timeIntervalSinceReferenceDate
        let activeCutoff = now - activityWindow

        // 先 map 出无序 rows，再统一排序——避免在 sort 闭包里反复算 evaluate
        // 性能：走 trie 版 evaluate（init 期一次性 build，扫描期复用），
        // 比 evaluate(path:vendors:home:) 每次重建 trie 快一个量级。
        //
        // Step 3 P0-3 / 2026-06：bucket cachedVerdict 缓存。
        // path/engine/trie/home 在扫描期间均不变 —— 同 path 的 evaluate 结果永远相同。
        // 第一帧把每个 bucket 的 verdict/rejection/vendor 算一次写回 bucket struct，
        // 后续帧（流式 0.4s 一次）直接读字段。一次扫描 N=数百~数千 bucket × 数十帧
        // 的重复 evaluate 收敛到"每 bucket 只算一次"。
        var unsorted: [RowItem] = []
        unsorted.reserveCapacity(buckets.count)
        for path in buckets.keys {
            // 通过 buckets[path] 路径 read-modify-write —— Bucket 是 value type，
            // 必须从 dict 重新写回才能保留 cache 字段。
            guard var bucket = buckets[path] else { continue }
            let verdict: SafetyVerdict
            let rejection: SafetyRejection
            let vendor: VendorRule?
            if let v = bucket.cachedVerdict, let r = bucket.cachedRejection {
                // hit：path/engine/trie/home 都没变，verdict 永远相同 —— 直接读
                verdict = v
                rejection = r
                vendor = bucket.cachedVendor
                verdictCacheHits &+= 1
            } else {
                // miss：算一次并写回 bucket
                let result = engine.evaluate(path: path, trie: trie, home: home)
                verdict = result.0
                rejection = result.1
                vendor = result.2
                bucket.cachedVerdict = verdict
                bucket.cachedRejection = rejection
                bucket.cachedVendor = vendor
                buckets[path] = bucket
                verdictCacheMisses &+= 1
            }

            let active: Bool
            if finished {
                active = false
            } else if let ts = lastIngestAt[path] {
                active = ts >= activeCutoff
            } else {
                active = false
            }
            unsorted.append(RowItem(
                id: path,
                url: bucket.url,
                title: bucket.url.lastPathComponent,
                isDirectory: bucket.isDirectory,
                bytes: bucket.bytes,
                logicalBytes: bucket.logicalBytes,
                fileCount: bucket.fileCount,
                verdict: verdict,
                rejection: rejection,
                vendorName: vendor?.name,
                vendorNote: vendor?.note,
                isActive: active,
                modificationDate: bucket.modificationDate
            ))
        }
        let rows: [RowItem]
        // M4-T1：白名单过滤——命中规则与 WhitelistStore.isWhitelisted 等价（同步快照版）。
        let filtered: [RowItem]
        if whitelistSnapshot.isEmpty {
            filtered = unsorted
        } else {
            filtered = unsorted.filter { row in
                let p = row.url.path
                if whitelistSnapshot.contains(p) { return false }
                for entry in whitelistSnapshot where p.hasPrefix(entry + "/") {
                    return false
                }
                return true
            }
        }
        if finished {
            rows = filtered.sorted(by: { mainListSortKey.lessThan($0, $1) })
            // 流式 cache 不用于 finished，但避免下次扫描首帧误命中——失效掉
            lastStreamSortedIds.removeAll(keepingCapacity: true)
            lastStreamSortCacheKey = (-1, -1)
        } else {
            // v1.5 P1-C：流式帧排序缓存。
            // 命中条件：bucketCount 与上次相同（ingest 单调增 → 相同即 key set 完全相同）
            // 且 whitelistCount 与上次相同（避免白名单变化产生不同的 filtered 序列影响）。
            // 命中时直接按上次的 id 序重排 filtered，跳过 O(N log N) 排序。
            let currentKey = (bucketCount: buckets.count, whitelistCount: whitelistSnapshot.count)
            let cacheHit = currentKey.bucketCount > 0
                && currentKey.bucketCount == lastStreamSortCacheKey.bucketCount
                && currentKey.whitelistCount == lastStreamSortCacheKey.whitelistCount
                && lastStreamSortedIds.count == filtered.count
            if cacheHit {
                // 按缓存 id 序重组 filtered（一次哈希构表 + 一次顺序拼装，O(N) 替代 O(N log N)）。
                var byID: [String: RowItem] = [:]
                byID.reserveCapacity(filtered.count)
                for r in filtered { byID[r.id] = r }
                var reordered: [RowItem] = []
                reordered.reserveCapacity(filtered.count)
                for id in lastStreamSortedIds {
                    if let r = byID[id] { reordered.append(r) }
                }
                // 兜底：若映射出现不一致（理论上不应该发生），fallback 走真排序
                if reordered.count == filtered.count {
                    rows = reordered
                } else {
                    rows = filtered.sorted { $0.id < $1.id }
                    lastStreamSortedIds = rows.map { $0.id }
                    lastStreamSortCacheKey = currentKey
                }
            } else {
                rows = filtered.sorted { $0.id < $1.id }
                lastStreamSortedIds = rows.map { $0.id }
                lastStreamSortCacheKey = currentKey
            }
        }

        // v1.3：ETA 采样 —— 在每帧 publishSnapshot 时基于自上次采样的字节增量算瞬时速率，
        // 再 EWMA 平滑（α=0.3）。注意 elapsed 起点是 startedAt，速率窗口起点是 lastSampleAt
        // （第一帧没有"上次"，初始化成 startedAt 让首个采样长度 = elapsed）。
        let nowDate = Date()
        let sampleStart = lastSampleAt ?? startedAt
        let dt = nowDate.timeIntervalSince(sampleStart)
        let dBytes = totalBytes - lastSampleBytes
        if dt >= 0.05, dBytes >= 0 {
            let instant = Double(dBytes) / max(dt, 0.001)
            if bytesPerSecondEMA == 0 {
                bytesPerSecondEMA = instant
            } else {
                let alpha = 0.3
                bytesPerSecondEMA = alpha * instant + (1 - alpha) * bytesPerSecondEMA
            }
            lastSampleAt = nowDate
            lastSampleBytes = totalBytes
        }
        let elapsedTotal = nowDate.timeIntervalSince(startedAt)

        // v1.3.x：ETA 分母统一走 expectedTotalBytes —— 整盘扫在 scan() 入口已设成 volumeSnapshot.usedBytes，
        // 推荐扫 / 自定义扫由 TreeSizeEstimator 异步填充。这里只判断是否已经有可信分母。
        //
        // v2026.06.21 修复 #1：原来 `min(estimate, 4*3600)` 会让"远超 30 分钟的估算"被钳成
        // 一个恒定的 "4:00:00"，HUD/主窗口长时间显示 "~ 4:00:00" 让用户以为"还要扫 4 小时"。
        // 实际上速率窗口噪声 / 多根 dev 扫的间歇 stall 都会让 instant ETA 飙到几十小时，
        // 这种估算根本不可信，呈现给用户反而是负价值。改为：
        //   - 估算值 > 30 分钟 → 视为"不可信"直接返回 nil，UI 回落到 "已用 %@" 文案
        //   - 估算值 <= 30 分钟 → 正常显示
        // 这样既保留"快完成时的精确剩余时间"，又避免"长扫时段一个假上限糊脸"。
        let eta: TimeInterval?
        if !finished,
           etaEligible,
           bytesPerSecondEMA > 1024,
           elapsedTotal > 0.5,
           let denom = expectedTotalBytes,
           denom > totalBytes {
            let remainingBytes = Double(denom - totalBytes)
            let raw = remainingBytes / bytesPerSecondEMA
            // 超过 30 分钟 = 估算不可信，宁可不显示 ETA（不再钳成 4:00:00 误导用户）
            eta = (raw.isFinite && raw <= 30 * 60) ? raw : nil
        } else {
            eta = nil
        }

        let nextSnapshot = ScanSnapshot(
            categoryID: categoryID,
            rows: rows,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            isFinished: finished,
            elapsed: elapsedTotal,
            bytesPerSecond: bytesPerSecondEMA,
            estimatedRemaining: finished ? nil : eta
        )
        // v2026.06.21 perf：Equatable 短路。
        // 用户对比反馈"开发者构建产物比 Library 卡得夸张"——根因之一是 @Published
        // 不会自动比较，每帧重复赋同样内容仍会 send objectWillChange，把 MainView.body
        // 整体失效，连带 sidebar / statusBar / listResults 全跑 O(N)。
        // ScanSnapshot 现在 Equatable（rows / 三桶字节 / max / bytesPerSecond / eta 全字段
        // 参与对比），等价帧直接 return 不写 @Published；典型 dev 扫场景"两根并行 throttle
        // 错峰共振导致空帧 publish"会被这里挡下，body 失效频率从 ≥5次/秒 降到内容真有变化
        // 才触发。等价比较的代价是 N 行 RowItem.== 浅比，远低于 SwiftUI body 重新跑一次。
        //
        // 注意：finished 帧不能短路——下游 lastFinishedCategoryID / lastIngestAt 清理
        // 与 (buckets/dirIndex/fileLeaves) 索引快照对齐都依赖这里跑完。
        if !finished && snapshot == nextSnapshot { return }
        snapshot = nextSnapshot
        if finished {
            lastFinishedCategoryID = categoryID
            // 扫完清空 lastIngestAt，避免下一次切排序键 / 重扫前的 stale 数据让旧 row 误亮
            lastIngestAt.removeAll(keepingCapacity: true)
        }
        // Step 2 P0-2 / 2026-06：treeRevision 拆分。
        // 流式扫描 publishSnapshot 帧（0.4s/帧）以前一律 `treeRevision &+= 1` —— 这会让
        // TreeBrowserView 把上万节点的 flatRows 整树重建一遍。但 95% 的帧只是已有节点
        // 的 bytes/fileCount 累加（节点拓扑没变），整树重建纯属浪费。
        //
        // 这里用三元组 `(buckets.count, dirIndex.count, fileLeaves.count)` 做 O(1) 判定：
        //   - 任一计数变化 → 必然有新节点首次出现 → 升格为 structural
        //   - 三元组全等 → 仅数值变化 → 只推 tickRevision，flatRows 不重建
        //
        // 漏判风险：dirIndex 内 children 集合微调（同一 parent 下子项排序变）不会让 count 变。
        // 但这种排序级变化在我们的 ingest 路径里**不会发生**（每次 insert 只 add/不 remove），
        // 所以三元组对索引集合的"严格单调增"语义足够安全。
        let snapshot = (
            buckets: buckets.count,
            dirIndex: dirIndex.count,
            fileLeaves: fileLeaves.count
        )
        if snapshot != lastIndexSnapshot {
            lastIndexSnapshot = snapshot
            bumpStructuralRevision()
        } else {
            bumpTickRevision()
        }
    }

    // MARK: - Testing helpers (Step 15)

    /// 仅供 [PruneDeletedTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/PruneDeletedTests.swift)
    /// / [PerformDeleteIntegrationTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/PerformDeleteIntegrationTests.swift)
    /// 注入内部状态。
    ///
    /// 同 [forcePublishSnapshotForTesting](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L389)
    /// 风格：`internal` 可见性，配合 `@testable import AppUI` 在测试 target 内可用，
    /// 生产路径不会调到。
    ///
    /// 全部参数都 optional，默认 nil = 不动该字段。Bucket/DirAgg 是 private struct，
    /// 这里以"简化字典"接收（path -> bytes 即可）由方法内部包装成真实结构。
    func _seedForTesting(
        snapshot: ScanSnapshot? = nil,
        buckets: [String: Int64]? = nil,
        dirIndex: [String]? = nil,
        dirIndexFull: [String: (bytes: Int64, fileCount: Int)]? = nil,
        fileLeaves: [String]? = nil,
        fileLeavesFull: [String: Int64]? = nil,
        childEdges: [String: Set<String>]? = nil,
        treeChildrenCache: [String: [TreeRow]]? = nil
    ) {
        if let snap = snapshot {
            self.snapshot = snap
        }
        if let buckets {
            self.buckets.removeAll()
            for (path, bytes) in buckets {
                self.buckets[path] = Bucket(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    bytes: bytes,
                    logicalBytes: bytes,
                    fileCount: 1,
                    isDirectory: true
                )
            }
        }
        if let dirIndex {
            self.dirIndex.removeAll()
            for path in dirIndex {
                self.dirIndex[path] = DirAgg(bytes: 1, logicalBytes: 1, fileCount: 1)
            }
        }
        // v1.5.7：带 (bytes, fileCount) 的 seed，让 prune 减法契约能拿到可验证的祖先聚合。
        if let dirIndexFull {
            self.dirIndex.removeAll()
            for (path, val) in dirIndexFull {
                self.dirIndex[path] = DirAgg(bytes: val.bytes, logicalBytes: val.bytes, fileCount: val.fileCount)
            }
        }
        if let fileLeaves {
            self.fileLeaves.removeAll()
            for path in fileLeaves {
                self.fileLeaves[path] = (bytes: 1, isDir: false, modificationDate: nil)
            }
        }
        if let fileLeavesFull {
            self.fileLeaves.removeAll()
            for (path, b) in fileLeavesFull {
                self.fileLeaves[path] = (bytes: b, isDir: false, modificationDate: nil)
            }
        }
        if let childEdges {
            self.childEdges = childEdges
        }
        if let treeChildrenCache {
            self.treeChildrenCache = treeChildrenCache
        }
    }

    func _bucketsKeysForTesting() -> [String] { Array(buckets.keys) }
    func _dirIndexKeysForTesting() -> [String] { Array(dirIndex.keys) }
    /// v1.5.7：暴露 dirIndex 聚合值，让 pruneDeleted 祖先减法契约可验证。
    func _dirIndexAggForTesting(_ path: String) -> (bytes: Int64, fileCount: Int)? {
        guard let agg = dirIndex[path] else { return nil }
        return (agg.bytes, agg.fileCount)
    }
    func _fileLeavesKeysForTesting() -> [String] { Array(fileLeaves.keys) }
    func _childEdgesForTesting() -> [String: Set<String>] { childEdges }
    func _treeChildrenCacheForTesting() -> [String: [TreeRow]] { treeChildrenCache }

    // MARK: - Step 17-A: 内存占用护栏 readers（仅供 [DirIndexMemoryFootprintTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/DirIndexMemoryFootprintTests.swift)）

    /// 暴露 DirAgg / Bucket 的 MemoryLayout.size，让护栏测能钉死结构体大小不变量。
    /// DirAgg / Bucket 是 private struct，测试 target 看不到 type 本身——
    /// 这里以静态值返回 size，外面只断言"不超过上限"，无字段 schema 暴露。
    static var _dirAggSizeForTesting: Int { MemoryLayout<DirAgg>.size }
    static var _bucketSizeForTesting: Int { MemoryLayout<Bucket>.size }

    // MARK: - Step 17-B: store 写盘 daisychain 顺序契约 helpers
    // 仅供 [StoreWriteOrderingTests](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/StoreWriteOrderingTests.swift)

    /// 注入 sessionID + storeBatch，让顺序契约测能直接驱动 flushStoreBatch / flushAndFinalize。
    /// 与 [_seedForTesting](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 同套路：`internal` 可见，optional 参数 nil-skip。
    func _seedStoreForTesting(
        sessionID: ScanSessionID? = nil,
        storeBatch: [ScanResultRecord]? = nil,
        storeHealthy: Bool? = nil
    ) {
        if let sessionID { self.currentSessionID = sessionID }
        if let storeBatch { self.storeBatch = storeBatch }
        if let storeHealthy { self.storeHealthy = storeHealthy }
    }

    /// 让顺序契约测从外部触发一次 storeBatch flush（产品代码 hot-path 走的也是这个入口）。
    func _flushStoreBatchForTesting() { flushStoreBatch() }

    /// 让顺序契约测从外部触发收尾 flush + finalize 并 await 落盘。
    func _flushAndFinalizeStoreAsyncForTesting() async { await flushAndFinalizeStoreAsync() }

    /// 等到当前 daisychain 链尾的 task 落盘——给 _flushStoreBatchForTesting 这种
    /// fire-and-forget 入口的测试用，断言前先确保 in-flight 写入已经全部落地。
    func _awaitStoreWriteChainForTesting() async { await storeWriteChain?.value }
}

// MARK: - v1.5.7 perf：原生 String 路径切分（避免 NSString 桥接 + 拷贝）

extension String {
    /// 返回 path 的父目录路径（与 `(p as NSString).deletingLastPathComponent` 等价的
    /// **常见 case** 子集，针对 POSIX 绝对路径优化）。
    ///
    /// 关键差异：仅在原生 `String` 上用 `lastIndex(of: "/")` 切片，**不**触发 NSString
    /// bridging / NSPathStore2 分配。ingest 热路径每个叶子文件回溯 O(depth) 次，
    /// 在 5w+ 文件场景下原方案 NSString 桥接占主线程 ~12% 时间（Instruments 采样口径）。
    ///
    /// 行为契约：
    /// - `/` → `/`
    /// - `/A` → `/`
    /// - `/A/B` → `/A`
    /// - `/A/B/C` → `/A/B`
    /// - 空串 → 空串
    /// 与 NSString.deletingLastPathComponent 在"POSIX 绝对路径、单 / 分隔、无尾 /"
    /// 输入下完全一致；ingest 调用方保证传入路径都是 FileManager.enumerator 给出
    /// 的规范绝对路径，无尾斜杠、无 `.`/`..`，所以这个简化版安全。
    @inline(__always)
    static func _gsyParentPath(of p: String) -> String {
        if p.isEmpty { return "" }
        guard let slash = p.lastIndex(of: "/") else { return "" }
        // 根目录 "/X" → "/"
        if slash == p.startIndex { return "/" }
        return String(p[p.startIndex..<slash])
    }
}

// MARK: - v2026.06.21 perf：onPartial 节流窗口

/// `scanDeveloperArtifacts` 的 `onPartial` 闭包需要在多次回调之间共享"上次 sync 时间戳"。
/// 闭包要 `@Sendable`，又要可变状态——直接用 var capture 会被 Swift 6 拒绝；
/// 包一层 reference type 即可。所有读写都被 `Task { @MainActor ... }` 串行化在主 actor
/// 上，没有 data race，因此不需要 lock。
@MainActor
final class PartialSyncWindow {
    /// 上次调用 `syncPerRootPublished` 的时间戳（`Date.timeIntervalSinceReferenceDate`）。
    /// 0 = 首次，肯定通过 0.4s 阈值——保证 sidebar 第一行立刻出现。
    var lastSync: TimeInterval = 0
}
