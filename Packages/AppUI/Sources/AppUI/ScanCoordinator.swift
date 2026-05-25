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
    @Published public private(set) var perRootProgress: [String: PerRootProgress] = [:]

    /// v1.3.zz 性能修复用：staging 累计区，每 .node 事件直接累计这里，避开 @Published 触发 SwiftUI invalidation。
    /// publishSnapshot 节流点会把它同步到 perRootProgress（0.4s 一次）。
    private var perRootStaging: [String: PerRootProgress] = [:]

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
    private var activeCategoryID: String?

    /// 一级子目录 -> 累计统计；用 path 作 key 保证稳定。
    private struct Bucket {
        var url: URL
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var isDirectory: Bool

        /// v1.3.z 性能优化：把 ingest hot path 的 read-modify-write 收敛进 Bucket 自身。
        /// 配合 `buckets[k, default: ...].applyIngest(...)` 让 hit 路径只走一次哈希查找，
        /// 且 hit 时不构造 default 值（autoclosure 不求值）。
        mutating func applyIngest(
            isFileNode: Bool,
            isTopLevelBucket: Bool,
            isDirEffective: Bool,
            bytes nodeBytes: Int64,
            logicalBytes nodeLogical: Int64
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
    private struct DirAgg {
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
    }
    private var dirIndex: [String: DirAgg] = [:]
    /// 父目录 -> 直接子项集合（含目录与文件路径）。文件叶子也存进来方便单层展示。
    private var childEdges: [String: Set<String>] = [:]
    /// 叶子文件 path -> (size, mtime?)；展示时区分文件与目录。
    private var fileLeaves: [String: (bytes: Int64, isDir: Bool)] = [:]

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
    @Published private var treeChildrenCache: [String: [TreeRow]] = [:]
    /// in-flight 路径集合：避免同 path 在 cache miss 时被 view body 多次重算疯狂启 Task。
    /// **不**参与 @Published（不需要触发 view 更新）。
    private var treeChildrenInFlight: Set<String> = []

    /// v1.0 T4：大文件叶子集合。
    /// 仅当 `largeFileMinBytes > 0` 时才会被填充（避免普通扫描浪费内存）。
    /// 每条记录原样保留 path / bytes / mtime，让 `largeFiles(...)` 能按多种 sortKey
    /// 自由切换排序，**无需重扫**。
    public struct LargeFileLeaf: Sendable, Hashable {
        public let path: String
        public let bytes: Int64
        public let modificationDate: Date?
    }
    private var largeFileLeaves: [LargeFileLeaf] = []
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
        // v1.3：启动即探一次 FDA 状态与卷容量，UI 立即拿到结果。
        // FDAProbe 会试 open ~/Library/Mail（或 fallback），微秒级开销。
        self.fdaStatus = FDAProbe.probe(home: home)
        self.volumeSnapshot = VolumeCapacity.probe()
        // v1.3.x：swap/sleepimage 占盘探测，无权限要求，开销 ~毫秒级
        self.swapSnapshot = SwapProbe.probe()
    }

    /// v1.3：用户从系统设置回到 App 后调用，重探 FDA 状态与卷容量。
    /// 推荐绑定到 `.onAppear` 与"打开系统设置"按钮的 `NSApplication.didBecomeActive` 回调。
    public func refreshFDAStatus() {
        fdaStatus = FDAProbe.probe(home: home)
        volumeSnapshot = VolumeCapacity.probe()
        swapSnapshot = SwapProbe.probe()
    }

    /// v1.3：每次扫描完成 / 删除完成后调用，重探卷容量（FDA 不变就不动）。
    public func refreshVolumeCapacity() {
        volumeSnapshot = VolumeCapacity.probe()
        swapSnapshot = SwapProbe.probe()
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
        perRootProgress = [:]
        perRootStaging = [:]
        // v1.3：标记本次状态为"用户主动停止"，让 statusBar 显示"已停止"而非"还未扫描"。
        wasCancelled = true
        // M1 内存优化：本轮取消后 store 中残留的半截 session 直接 evict，避免占盘。
        if let store = resultStore, let sid = currentSessionID {
            Task.detached { try? await store.evictSession(sid) }
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
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        // v1.3.z：清掉上一轮的 TreeBrowserView store-fallback 缓存，
        // 避免新 sessionID 期间 view 看到旧 sessionID 的 store query 结果。
        treeChildrenCache.removeAll(keepingCapacity: true)
        treeChildrenInFlight.removeAll(keepingCapacity: true)
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
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        // v1.3.z：清掉上一轮的 TreeBrowserView store-fallback 缓存，
        // 避免新 sessionID 期间 view 看到旧 sessionID 的 store query 结果。
        treeChildrenCache.removeAll(keepingCapacity: true)
        treeChildrenInFlight.removeAll(keepingCapacity: true)
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
        currentRootPath = "(多目录)"
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
            initial[c.rootPath] = PerRootProgress(rootPath: c.rootPath, title: c.title)
        }
        perRootProgress = initial
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
            await self?.runMultiRootScan(roots: roots, options: options,
                                         categoryID: ScanCoordinator.multiRootCategoryID)
        }
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
    private func runMultiRootScan(roots: [URL], options: ScanOptions, categoryID: String) async {
        let scanner = MultiRootScanner(options: options)
        var lastEmit = Date(timeIntervalSince1970: 0)
        // v1.3.z 性能修复：见 runScan 同名注释。多根模式 throttle 同步抬到 0.40。
        let throttle: TimeInterval = 0.40
        // v1.3.y 性能修复：见 runScan 同名注释。多根模式同样需要让出主 actor。
        let yieldEvery = 256
        var consumedSinceYield = 0

        for await wrapped in await scanner.scan(roots: roots) {
            if Task.isCancelled { break }
            // 与 runScan 同款过期事件保护：activeCategoryID 被覆盖即旧 stream 残留事件，丢弃。
            guard activeCategoryID == categoryID else { break }
            let rootPath = wrapped.rootPath
            switch wrapped.event {
            case .node(let node):
                ingest(node: node, rootPath: rootPath)
                if !node.isDirectory, var p = perRootStaging[rootPath] {
                    p.bytes += displayBytes(of: node)
                    p.fileCount += 1
                    perRootStaging[rootPath] = p
                }
            case .progress:
                break
            case .finished:
                if var p = perRootStaging[rootPath] {
                    p.isFinished = true
                    perRootStaging[rootPath] = p
                }
                // .finished 是低频事件，立刻同步到 @Published 让 UI 看到"该根已完成"
                perRootProgress[rootPath] = perRootStaging[rootPath]
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
            }

            let now = Date()
            if now.timeIntervalSince(lastEmit) >= throttle {
                lastEmit = now
                // v1.3.zz 性能修复：节流同步 staging → @Published，让 UI 0.4s 看一次进度
                perRootProgress = perRootStaging
                publishSnapshot(categoryID: categoryID, finished: false)
            }

            // 性能修复：每 N 个事件让出一次主 actor
            consumedSinceYield += 1
            if consumedSinceYield >= yieldEvery {
                consumedSinceYield = 0
                await Task.yield()
            }
        }
        guard activeCategoryID == categoryID else { return }
        // v1.3.zz 性能修复：收尾把 staging 最后状态同步到 @Published，让 UI 看到完整最终值
        perRootProgress = perRootStaging
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
        let nodePath = node.url.path
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
        let nowTI = Date.timeIntervalSinceReferenceDate
        if let prev = lastIngestAt[bucketPath], nowTI - prev < 0.05 {
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
            logicalBytes: node.logicalSize
        )

        // v1.0 T3：构建多层下钻索引。
        // - 叶子文件：累计到所有祖先目录的 dirIndex
        // - 任意 node：把它登记为父目录的直接子项（childEdges）
        // v1.3.z 性能开关：CLI bench / 性能基线场景关掉，跳过 576 万次主线程字典写入。
        if !node.isDirectory {
            // v1.0 T4：达到大文件阈值的叶子单独留底，供 LargeFilesView 用。
            // 注：与深索引开关解耦，largeFileLeaves 即便 deepIndex=off 也照常采集。
            if largeFileMinBytes > 0 && bytes >= largeFileMinBytes {
                largeFileLeaves.append(LargeFileLeaf(
                    path: nodePath,
                    bytes: bytes,
                    modificationDate: node.modificationDate
                ))
            }
            if enableTreeDeepIndex {
                fileLeaves[nodePath] = (bytes: bytes, isDir: false)
                // 沿路径回溯到 rootPath，把 size 加到所有祖先
                var cursor = (nodePath as NSString).deletingLastPathComponent
                while !cursor.isEmpty, cursor.hasPrefix(rootPath) {
                    var agg = dirIndex[cursor] ?? DirAgg()
                    agg.bytes += bytes
                    agg.logicalBytes += node.logicalSize
                    agg.fileCount += 1
                    dirIndex[cursor] = agg
                    if cursor == rootPath { break }
                    let parent = (cursor as NSString).deletingLastPathComponent
                    childEdges[parent, default: []].insert(cursor)
                    cursor = parent
                }
                // 文件本身也作为父目录的直接子项
                let parent = (nodePath as NSString).deletingLastPathComponent
                childEdges[parent, default: []].insert(nodePath)
            }
        } else if enableTreeDeepIndex {
            // 目录节点（即使没有累计字节，也把它登记到边集，避免空目录在树里漏掉）
            if dirIndex[nodePath] == nil {
                dirIndex[nodePath] = DirAgg()
            }
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
                    self.treeChildrenInFlight.remove(cacheKey)
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
    }

    /// v1.3.zz：暴露给 [TreeBrowserView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TreeBrowserView.swift)
    /// 区分"刚 cache miss、后台 fetch 还在飞" vs "真的查到 0 条子项"——
    /// 前者应显 ProgressView 占位避免误导用户以为没数据；后者才显"还没有可展开的子节点"。
    ///
    /// 实现：cacheKey 在 `treeChildrenInFlight` 集合 / 或者 deepIndex=off + store/sid 在场
    /// 但 cache 还没写回（首帧尚未派发 Task），都算 fetching。
    public func isFetchingChildren(of path: String, sortedBy key: TreeSortKey) -> Bool {
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

    /// 内存索引命中时的"老路径"渲染——抽出来给同步 directChildren 与 directChildrenAsync 复用。
    private func materializeFromMemory(kids: Set<String>, sortedBy key: TreeSortKey) -> [TreeRow] {
        let rows: [TreeRow] = kids.map { childPath in
            if let agg = dirIndex[childPath] {
                // 目录
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: agg.bytes,
                    fileCount: agg.fileCount,
                    isDirectory: true,
                    hasChildren: !(childEdges[childPath]?.isEmpty ?? true)
                )
            } else if let leaf = fileLeaves[childPath] {
                // 文件
                return TreeRow(
                    path: childPath,
                    title: (childPath as NSString).lastPathComponent,
                    bytes: leaf.bytes,
                    fileCount: 1,
                    isDirectory: leaf.isDir,
                    hasChildren: false
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
    /// UI 据此渲染 🔒 徽章而不是误导性的 0KB。
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
                    accessState: accessState
                )
            } else {
                // 目录：bytes/count 用子树累加值。hasChildren 判定与旧版一致：
                // 至少 1 条记录，且不是"唯一一条直接孩子叶子"。
                return TreeRow(
                    path: segPath,
                    title: agg.segment,
                    bytes: agg.descendantBytes,
                    fileCount: max(agg.descendantCount, 1),
                    isDirectory: true,
                    hasChildren: agg.descendantCount >= 1
                        && !(agg.descendantCount == 1 && agg.hasInode == false),
                    accessState: accessState
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
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: agg.bytes,
                fileCount: agg.fileCount,
                isDirectory: true,
                hasChildren: !(childEdges[path]?.isEmpty ?? true)
            )
        }
        if let leaf = fileLeaves[path] {
            return TreeRow(
                path: path,
                title: (path as NSString).lastPathComponent,
                bytes: leaf.bytes,
                fileCount: 1,
                isDirectory: leaf.isDir,
                hasChildren: false
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
            source = cache
        } else {
            source = largeFileLeaves
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
            if healthy, !pending.isEmpty {
                try? await storeRef.insert(pending)
            }
            try? await storeRef.finalizeSession(sid)
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
    /// daisychain 语义保留：storeWriteChain 仍然指向最后一个 task，并发 cancel 等场景行为不变。
    private func flushAndFinalizeStoreAsync() async {
        guard let store = resultStore, let sid = currentSessionID else { return }
        let pending = storeBatch
        storeBatch.removeAll(keepingCapacity: false)
        let healthy = storeHealthy
        let prev = storeWriteChain
        let task = Task.detached { [storeRef = store] in
            await prev?.value
            if healthy, !pending.isEmpty {
                try? await storeRef.insert(pending)
            }
            try? await storeRef.finalizeSession(sid)
        }
        storeWriteChain = task
        // **关键差异**：等到 detached task 真的跑完再返回，view 看到 finished 时 GRDB ready。
        await task.value
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
        let unsorted: [RowItem] = buckets.map { (path, bucket) in
            let (verdict, rejection, vendor) = engine.evaluate(path: path, trie: trie, home: home)
            let active: Bool
            if finished {
                active = false
            } else if let ts = lastIngestAt[path] {
                active = ts >= activeCutoff
            } else {
                active = false
            }
            return RowItem(
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
                isActive: active
            )
        }
        let rows: [RowItem]
        if finished {
            rows = unsorted.sorted(by: { mainListSortKey.lessThan($0, $1) })
        } else {
            rows = unsorted.sorted { $0.id < $1.id }
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
        let eta: TimeInterval?
        if !finished,
           etaEligible,
           bytesPerSecondEMA > 1024,
           elapsedTotal > 0.5,
           let denom = expectedTotalBytes,
           denom > totalBytes {
            let remainingBytes = Double(denom - totalBytes)
            // 上限保护：ETA 不超过 4 小时（防呆——速率瞬时低导致估天文数）
            eta = min(remainingBytes / bytesPerSecondEMA, 4 * 3600)
        } else {
            eta = nil
        }

        snapshot = ScanSnapshot(
            categoryID: categoryID,
            rows: rows,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            isFinished: finished,
            elapsed: elapsedTotal,
            bytesPerSecond: bytesPerSecondEMA,
            estimatedRemaining: finished ? nil : eta
        )
        if finished {
            lastFinishedCategoryID = categoryID
            // 扫完清空 lastIngestAt，避免下一次切排序键 / 重扫前的 stale 数据让旧 row 误亮
            lastIngestAt.removeAll(keepingCapacity: true)
        }
    }
}
