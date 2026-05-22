import Foundation
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

    /// 当前/最近一次扫描的根路径；`nil` 表示尚未发起任何扫描（notStarted 态）。
    /// UI 用它在 `finishedEmpty(rootPath:)` 三态里显示具体目录，避免硬编码 `~/Library/Caches`。
    @Published public private(set) var currentRootPath: String?

    /// 便利属性 —— 转发自 `snapshot.isFinished`，
    /// 让 UI 可以直接 `coordinator.isFinished` 判断三态，不必每处都写 `coordinator.snapshot.isFinished`。
    public var isFinished: Bool { snapshot.isFinished }

    private let engine = SafetyEngine()
    private let vendors: [VendorRule]
    private let home: String
    private var scanTask: Task<Void, Never>?

    /// 一级子目录 -> 累计统计；用 path 作 key 保证稳定。
    private struct Bucket {
        var url: URL
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var fileCount: Int = 0
        var isDirectory: Bool
    }
    private var buckets: [String: Bucket] = [:]

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
    /// 当前扫描会话中"采集大文件的下限"。0 表示不采集。
    private var largeFileMinBytes: Int64 = 0

    private var totalBytes: Int64 = 0
    private var scannedFiles: Int = 0
    private var startedAt: Date = .distantPast

    public init(vendors: [VendorRule] = [], home: String = NSHomeDirectory()) {
        self.vendors = vendors
        self.home = home
    }

    public func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    public func scan(category: ScanCategory, includeHidden: Bool = false,
                     largeFileMinBytes: Int64 = 0) {
        cancel()
        buckets.removeAll(keepingCapacity: true)
        dirIndex.removeAll(keepingCapacity: true)
        childEdges.removeAll(keepingCapacity: true)
        fileLeaves.removeAll(keepingCapacity: true)
        largeFileLeaves.removeAll(keepingCapacity: true)
        self.largeFileMinBytes = max(0, largeFileMinBytes)
        totalBytes = 0
        scannedFiles = 0
        startedAt = Date()
        currentRootPath = category.rootPath
        snapshot = ScanSnapshot(categoryID: category.id, rows: [], totalBytes: 0,
                                scannedFileCount: 0, isFinished: false, elapsed: 0)
        isScanning = true
        lastError = nil
        permissionDeniedPaths = []
        tccProtectedSkippedPaths = []

        let rootURL = category.rootURL
        let categoryID = category.id
        // v1.0 T5：整盘扫描时强制开启 staySingleVolume，避免误吃外接卷 / 网络挂载点把扫描时间打爆
        let isFullDisk = category.kind == .fullDisk
        scanTask = Task { [weak self] in
            await self?.runScan(rootURL: rootURL, categoryID: categoryID,
                                includeHidden: includeHidden, staySingleVolume: isFullDisk)
        }
    }

    /// v1.0 T5：整盘扫描便捷入口 —— 等价于 `scan(category: .fullDisk)`。
    /// MainView 路径栏输入 `/` 回车 / 整盘扫描按钮 都走这个 API，避免在多处硬编码 `ScanCategory.fullDisk`。
    public func scanFullDisk(includeHidden: Bool = false) {
        scan(category: .fullDisk, includeHidden: includeHidden)
    }

    private func runScan(rootURL: URL, categoryID: String, includeHidden: Bool, staySingleVolume: Bool = false) async {
        let rootPath = rootURL.path
        // v1.0 T2：把 AppSettings.showHidden 透传到 ScanOptions
        // v1.0 T5：整盘扫描时叠加 staySingleVolume=true（详见 ScanOptions 文档）
        let options = ScanOptions(includeHidden: includeHidden, staySingleVolume: staySingleVolume)
        let scanner = BulkScanner(options: options)
        var lastEmit = Date(timeIntervalSince1970: 0)
        let throttle: TimeInterval = 0.15

        for await event in scanner.scan(root: rootURL) {
            if Task.isCancelled { break }
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
        }
        publishSnapshot(categoryID: categoryID, finished: true)
        isScanning = false
        scanTask = nil
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

        // 文件累计
        if !node.isDirectory {
            scannedFiles += 1
            totalBytes += node.allocatedSize
        }

        let isDir = nodePath == bucketPath ? true : node.isDirectory
        var b = buckets[bucketPath] ?? Bucket(
            url: URL(fileURLWithPath: bucketPath, isDirectory: true),
            isDirectory: true
        )
        if !node.isDirectory {
            b.bytes += node.allocatedSize
            b.logicalBytes += node.logicalSize
            b.fileCount += 1
        }
        // 顶层 bucket 自身可能是文件（极少见），保留 isDirectory 信息
        if nodePath == bucketPath {
            b.isDirectory = isDir
            if !isDir {
                b.bytes += node.allocatedSize
                b.logicalBytes += node.logicalSize
                b.fileCount = 1
            }
        }
        buckets[bucketPath] = b

        // v1.0 T3：构建多层下钻索引。
        // - 叶子文件：累计到所有祖先目录的 dirIndex
        // - 任意 node：把它登记为父目录的直接子项（childEdges）
        if !node.isDirectory {
            fileLeaves[nodePath] = (bytes: node.allocatedSize, isDir: false)
            // v1.0 T4：达到大文件阈值的叶子单独留底，供 LargeFilesView 用。
            if largeFileMinBytes > 0 && node.allocatedSize >= largeFileMinBytes {
                largeFileLeaves.append(LargeFileLeaf(
                    path: nodePath,
                    bytes: node.allocatedSize,
                    modificationDate: node.modificationDate
                ))
            }
            // 沿路径回溯到 rootPath，把 size 加到所有祖先
            var cursor = (nodePath as NSString).deletingLastPathComponent
            while !cursor.isEmpty, cursor.hasPrefix(rootPath) {
                var agg = dirIndex[cursor] ?? DirAgg()
                agg.bytes += node.allocatedSize
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
        } else {
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
    public func directChildren(of path: String, sortedBy key: TreeSortKey) -> [TreeRow] {
        guard let kids = childEdges[path] else { return [] }
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
        let filtered = largeFileLeaves
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
    public var largeFileCollectedCount: Int { largeFileLeaves.count }

    /// v1.0 T4：当前会话扫描期阈值（bytes）。视图据此判断是否需要"调阈值后重扫"。
    public var largeFileScanThresholdBytes: Int64 { largeFileMinBytes }

    private func publishSnapshot(categoryID: String, finished: Bool) {
        // 排序 + 计算 verdict
        let rows: [RowItem] = buckets
            .sorted { $0.value.bytes > $1.value.bytes }
            .map { (path, bucket) in
                let (verdict, rejection, vendor) = engine.evaluate(path: path, vendors: vendors, home: home)
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
                    vendorNote: vendor?.note
                )
            }
        snapshot = ScanSnapshot(
            categoryID: categoryID,
            rows: rows,
            totalBytes: totalBytes,
            scannedFileCount: scannedFiles,
            isFinished: finished,
            elapsed: Date().timeIntervalSince(startedAt)
        )
    }
}
