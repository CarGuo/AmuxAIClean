import SwiftUI
import AppKit

/// v2026.07.18：应用根发现缺口与单 App 容量缺口共同决定总量语义。
/// 只检查已加载 rows 会把未枚举到的 `/Applications` 根错误显示成精确总计。
enum AppFootprintMetricProjection {
    static func isComplete(
        items: [AppFootprintItem],
        discoveryIssues: [InstalledAppDiscoveryIssue]
    ) -> Bool {
        discoveryIssues.isEmpty && items.allSatisfy(\.isComplete)
    }
}
import SafetyKit

/// v2026.07.17：App 图标读取的异步、严格有界 LRU。
///
/// `NSWorkspace.icon(forFile:)` 可能触发 LaunchServices / bundle metadata I/O；旧实现把它
/// 直接放在 SwiftUI row body，任意列表 invalidation 都会同步重复读取。这里的 cache miss
/// 只登记到有界队列，真正读取使用 Apple 明确标注“可从任意线程调用”的
/// `NSWorkspace.icon(forFiles:)`，并在 utility detached task 内把图标冻结成 `Data` 后再回到
/// MainActor 构造 UI image。这样既不把 AppKit 可变对象跨线程共享，也不阻塞 row body。
/// 缓存、pending 和 active load 均有硬上限；每轮 reload 清空，避免旧图标永久驻留。
@MainActor
final class AppFootprintIconCache: ObservableObject {
    typealias Loader = @Sendable (String) async -> Data?

    private let capacity: Int
    private let maximumConcurrentLoads: Int
    private let loader: Loader
    private var imagesByPath: [String: NSImage] = [:]
    private var leastToMostRecentPaths: [String] = []
    private var pendingPaths: [String] = []
    private var activeLoads: [String: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0

    init(
        capacity: Int = 256,
        maximumConcurrentLoads: Int = 4,
        loader: @escaping Loader = AppFootprintIconCache.loadIconData(for:)
    ) {
        self.capacity = max(1, capacity)
        self.maximumConcurrentLoads = max(1, min(maximumConcurrentLoads, self.capacity))
        self.loader = loader
        imagesByPath.reserveCapacity(self.capacity)
        leastToMostRecentPaths.reserveCapacity(self.capacity)
        pendingPaths.reserveCapacity(self.capacity)
    }

    /// Returns immediately. A cache miss schedules bounded background work and displays the
    /// caller's placeholder until `objectWillChange` announces the completed image.
    func image(for url: URL) -> NSImage? {
        let path = url.standardizedFileURL.path
        if let cached = imagesByPath[path] {
            if let index = leastToMostRecentPaths.firstIndex(of: path) {
                leastToMostRecentPaths.remove(at: index)
            }
            leastToMostRecentPaths.append(path)
            return cached
        }

        guard activeLoads[path] == nil, !pendingPaths.contains(path) else { return nil }
        if pendingPaths.count >= capacity {
            pendingPaths.removeFirst()
        }
        pendingPaths.append(path)
        startPendingLoads()
        return nil
    }

    func removeAll() {
        objectWillChange.send()
        generation &+= 1
        for task in activeLoads.values { task.cancel() }
        // A synchronous LaunchServices call cannot be force-interrupted. Keep cancelled old
        // workers in the active budget until they really return; otherwise reload could start
        // another full batch and temporarily multiply icon I/O across generations.
        pendingPaths.removeAll(keepingCapacity: true)
        imagesByPath.removeAll(keepingCapacity: true)
        leastToMostRecentPaths.removeAll(keepingCapacity: true)
    }

    private func startPendingLoads() {
        while activeLoads.count < maximumConcurrentLoads, !pendingPaths.isEmpty {
            let path = pendingPaths.removeFirst()
            let ownedGeneration = generation
            let loader = self.loader
            let task = Task { [weak self] in
                // removeAll/onDisappear 可能发生在这个 MainActor task 真正开始之前；
                // 先观察取消可避免已经失效的 generation 仍新开 LaunchServices I/O。
                guard !Task.isCancelled else {
                    guard let self else { return }
                    self.activeLoads.removeValue(forKey: path)
                    self.startPendingLoads()
                    return
                }
                let data = await loader(path)
                guard let self else { return }
                self.activeLoads.removeValue(forKey: path)
                guard !Task.isCancelled, self.generation == ownedGeneration else {
                    // `removeAll()` invalidated the request while its sync worker was still
                    // returning. Wake visible rows so the current generation can enqueue it.
                    self.objectWillChange.send()
                    self.startPendingLoads()
                    return
                }

                let image = data.flatMap(NSImage.init(data:))
                    ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
                    ?? NSImage(size: NSSize(width: 32, height: 32))
                self.objectWillChange.send()
                self.insert(image, for: path)
                self.startPendingLoads()
            }
            activeLoads[path] = task
        }
    }

    private func insert(_ image: NSImage, for path: String) {
        if imagesByPath.count >= capacity,
           let evictedPath = leastToMostRecentPaths.first {
            leastToMostRecentPaths.removeFirst()
            imagesByPath.removeValue(forKey: evictedPath)
        }
        imagesByPath[path] = image
        leastToMostRecentPaths.append(path)
    }

    /// Apple documents `icon(forFiles:)` and `NSWorkspace.shared` as callable from any app
    /// thread. The returned NSImage never crosses the task boundary; only immutable Data does.
    private nonisolated static func loadIconData(for path: String) async -> Data? {
        // v2026.07.17: State the detached result type explicitly so the cancellation branch
        // and the autoreleasepool branch share one optional-Data contract under Swift 6.
        let worker = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                NSWorkspace.shared.icon(forFiles: [path])?.tiffRepresentation
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Internal-only regression evidence for the hard memory bound.
    var cachedImageCount: Int { imagesByPath.count }
    var activeLoadCount: Int { activeLoads.count }
    var pendingLoadCount: Int { pendingPaths.count }

    deinit {
        for task in activeLoads.values { task.cancel() }
    }
}

/// v2026.07.17：App Footprint 的 revision-owned 加载状态机。
///
/// 根因记录：旧 View 把 `streamTask` 放在 `@State`，但 `.task { reload() }` 在创建
/// detached producer 后立即返回；离页不会取消该 producer，连续 reload 也只有布尔取消，
/// 没有等待旧同步 snapshot 真正退出。结果是不可见的旧扫描与新扫描叠加 I/O，而且旧轮
/// item/终态仍可能覆盖新轮。这里把 loader、producer session、revision 和有界 UI 提交收敛
/// 到一个状态机：旧 producer 排空之前不启动新 producer，所有发布都验证 owned revision。
@MainActor
final class AppFootprintReloadModel: ObservableObject {
    typealias InstalledAppsLoader = @Sendable () async -> InstalledAppDiscoveryResult
    typealias StreamFactory = @Sendable ([InstalledApp]) -> AppFootprintStreamSession

    @Published private(set) var items: [AppFootprintItem] = []
    @Published private(set) var discoveryIssues: [InstalledAppDiscoveryIssue] = []
    @Published var selected: AppFootprintItem?
    @Published private(set) var searchQuery = ""
    @Published private(set) var pendingIDs: Set<AppFootprintItem.ID> = []
    @Published private(set) var isLoading = false
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal = 0

    /// 仅供性能回归测试证明逐 item 全表 sort 已被有界批量替代。
    private(set) var displayCommitCount = 0

    private let loader: InstalledAppsLoader
    private let streamFactory: StreamFactory
    private let batchLimit: Int
    private let flushDelayNanoseconds: UInt64
    private var revision: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var scheduledFlushTask: Task<Void, Never>?
    private var activeSession: AppFootprintStreamSession?
    private var producerDrainTask: Task<Void, Never>?
    private var bufferedItems: [AppFootprintItem.ID: AppFootprintItem] = [:]
    /// 单轮内终态只能单向收敛；即使错误 producer 迟到一个 intermediate，也不能把
    /// 已完成/partial 终态倒退成“仍在扫描”。revision 旋转时整体清空。
    private var terminalIDs: Set<AppFootprintItem.ID> = []
    private var hasPublishedFirstResult = false

    var searchProjection: AppListSearchProjection<AppFootprintItem> {
        AppListSearchProjection(items: items, selection: selected, query: searchQuery) {
            $0.appName.localizedCaseInsensitiveContains($1)
                || $0.bundleID.localizedCaseInsensitiveContains($1)
        }
    }

    func updateSearchQuery(_ query: String) {
        let next = AppListSearchProjection(items: items, selection: selected, query: query) {
            $0.appName.localizedCaseInsensitiveContains($1)
                || $0.bundleID.localizedCaseInsensitiveContains($1)
        }
        // Clear the old owner before publishing a query that hides it. A later progressive
        // item cannot resurrect this selection, because commits retain only the current ID.
        selected = next.selection
        searchQuery = query
    }

    init(
        loader: @escaping InstalledAppsLoader,
        streamFactory: @escaping StreamFactory,
        batchLimit: Int = 12,
        flushDelayNanoseconds: UInt64 = 100_000_000
    ) {
        self.loader = loader
        self.streamFactory = streamFactory
        self.batchLimit = max(1, batchLimit)
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    func reload() {
        revision &+= 1
        let ownedRevision = revision
        loadTask?.cancel()
        let previousProducerDrain = cancelActiveProducer()
        cancelScheduledFlush()
        bufferedItems.removeAll(keepingCapacity: true)
        terminalIDs.removeAll(keepingCapacity: true)
        hasPublishedFirstResult = false

        isLoading = true
        progressDone = 0
        progressTotal = 0
        items = []
        discoveryIssues = []
        selected = nil
        pendingIDs = []
        displayCommitCount = 0

        let loader = self.loader
        let streamFactory = self.streamFactory
        loadTask = Task { [weak self] in
            let discovery = await loader()
            guard let self,
                  !Task.isCancelled,
                  self.revision == ownedRevision else { return }

            let installed = discovery.apps
            self.discoveryIssues = discovery.incompleteIssues

            self.progressTotal = installed.count
            let placeholders = installed.map(Self.placeholderItem(for:))
            self.pendingIDs = Set(placeholders.map(\.id))
            self.items = placeholders
            self.selected = self.searchProjection.items.first

            // 新列表元数据可以先展示；重型 bundle snapshot 必须等待上一轮 producer
            // 确认退出，避免快速刷新时把两组目录遍历压到同一块磁盘上。
            if let previousProducerDrain {
                await previousProducerDrain.value
            }
            guard !Task.isCancelled, self.revision == ownedRevision else { return }

            let session = streamFactory(installed)
            self.activeSession = session
            await withTaskCancellationHandler {
                for await item in session.stream {
                    guard !Task.isCancelled,
                          self.revision == ownedRevision else { break }
                    self.enqueue(item, revision: ownedRevision)
                }
            } onCancel: {
                session.cancel()
            }

            if Task.isCancelled {
                session.cancel()
            }
            // wait 是与下一轮的 I/O ownership 边界，而不是 UI 延迟：同步 snapshot
            // 只能在逐项边界 cooperative stop，必须等它真正回收后才允许新 producer。
            await session.waitForTermination()

            guard !Task.isCancelled,
                  self.revision == ownedRevision else { return }
            self.cancelScheduledFlush()
            self.flushBufferedItems(revision: ownedRevision, forceFinalSort: true)
            self.activeSession = nil
            self.producerDrainTask = nil
            self.isLoading = false
            self.loadTask = nil
        }
    }

    /// 离页终态：旋转 revision 后取消 consumer 与 producer。状态发布立即停止，producer
    /// 则通过 session token 在安全的文件枚举边界退出。
    func cancel() {
        revision &+= 1
        loadTask?.cancel()
        _ = cancelActiveProducer()
        cancelScheduledFlush()
        bufferedItems.removeAll(keepingCapacity: true)
        terminalIDs.removeAll(keepingCapacity: true)
        isLoading = false
    }

    func pruneDeletedPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let matcher = DeletionPresentationPathMatcher(paths: paths)
        var didChange = false
        let selectedID = selected?.id
        var nextItems: [AppFootprintItem] = []
        nextItems.reserveCapacity(items.count)
        for item in items {
            if matcher.contains(item.appURL.path) {
                didChange = true
                pendingIDs.remove(item.id)
                terminalIDs.remove(item.id)
                bufferedItems.removeValue(forKey: item.id)
                continue
            }
            let remainingBuckets = item.buckets.filter { !matcher.contains($0.path) }
            if remainingBuckets.count != item.buckets.count {
                didChange = true
                let bundleBytes = remainingBuckets
                    .filter { $0.kind == .bundle }
                    .reduce(Int64(0)) { $0 + $1.bytes }
                let relatedBytes = remainingBuckets
                    .filter { $0.kind != .bundle }
                    .reduce(Int64(0)) { $0 + $1.bytes }
                nextItems.append(AppFootprintItem(
                    bundleID: item.bundleID,
                    appName: item.appName,
                    appURL: item.appURL,
                    isComplete: item.isComplete,
                    deliveryPhase: item.deliveryPhase,
                    appBundleBytes: bundleBytes,
                    relatedBytes: relatedBytes,
                    buckets: remainingBuckets
                ))
            } else {
                nextItems.append(item)
            }
        }
        guard didChange else { return }
        items = nextItems
        sortItemsForDisplay()
        if let selectedID {
            selected = searchProjection.items.first(where: { $0.id == selectedID })
                ?? searchProjection.items.first
        }
    }

    private func cancelActiveProducer() -> Task<Void, Never>? {
        guard let session = activeSession else { return producerDrainTask }
        activeSession = nil
        session.cancel()
        let earlierDrain = producerDrainTask
        let drain = Task {
            if let earlierDrain { await earlierDrain.value }
            await session.waitForTermination()
        }
        producerDrainTask = drain
        return drain
    }

    private func enqueue(_ item: AppFootprintItem, revision ownedRevision: UInt64) {
        guard revision == ownedRevision else { return }
        // v2026.07.17 根因修复：`isComplete=false` 既可能是 progressive 中间态，也可能
        // 是预算截断后的可信终态。进度与 pending 必须依赖显式 delivery phase；同时
        // terminal 后拒绝迟到 intermediate，保证单轮状态单向收敛。
        if terminalIDs.contains(item.id), item.deliveryPhase == .intermediate {
            return
        }
        if item.deliveryPhase == .terminal {
            terminalIDs.insert(item.id)
        }
        bufferedItems[item.id] = item

        // 第一条即时发布，保证首屏响应；其后按数量或 100ms 有界提交，避免每个 app
        // 都在 MainActor firstIndex + 全表 sort + 触发整张 List 重算。
        if !hasPublishedFirstResult || bufferedItems.count >= batchLimit {
            cancelScheduledFlush()
            flushBufferedItems(revision: ownedRevision, forceFinalSort: false)
            hasPublishedFirstResult = true
        } else if scheduledFlushTask == nil {
            let delay = flushDelayNanoseconds
            scheduledFlushTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.revision == ownedRevision else { return }
                self.scheduledFlushTask = nil
                self.flushBufferedItems(revision: ownedRevision, forceFinalSort: false)
            }
        }
    }

    private func flushBufferedItems(revision ownedRevision: UInt64, forceFinalSort: Bool) {
        guard revision == ownedRevision else { return }
        let batch = Array(bufferedItems.values)
        bufferedItems.removeAll(keepingCapacity: true)

        if !batch.isEmpty {
            var updatedItems = items
            var updatedPendingIDs = pendingIDs
            var updatedProgressDone = progressDone
            var indexByID = Dictionary(uniqueKeysWithValues: updatedItems.indices.map { (updatedItems[$0].id, $0) })
            let selectedID = selected?.id
            for item in batch {
                if let index = indexByID[item.id] {
                    updatedItems[index] = item
                } else {
                    indexByID[item.id] = updatedItems.count
                    updatedItems.append(item)
                }
                // `isComplete` 只表示证据完整度；progress 必须由显式 terminal 交付收敛。
                // partial terminal 也应完成进度，intermediate 则继续保留 pending。
                if item.deliveryPhase == .terminal,
                   updatedPendingIDs.remove(item.id) != nil {
                    updatedProgressDone += 1
                }
            }
            updatedItems.sort { lhs, rhs in
                let lhsPending = updatedPendingIDs.contains(lhs.id)
                let rhsPending = updatedPendingIDs.contains(rhs.id)
                if lhsPending != rhsPending { return !lhsPending }
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
            items = updatedItems
            pendingIDs = updatedPendingIDs
            progressDone = updatedProgressDone
            if let selectedID {
                // v2026.10.08: progressive metadata may change the search match too.
                selected = searchProjection.items.first(where: { $0.id == selectedID })
            }
            displayCommitCount += 1
        } else if forceFinalSort {
            sortItemsForDisplay()
        }
    }

    private func sortItemsForDisplay() {
        items.sort { lhs, rhs in
            let lhsPending = pendingIDs.contains(lhs.id)
            let rhsPending = pendingIDs.contains(rhs.id)
            if lhsPending != rhsPending { return !lhsPending }
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    private func cancelScheduledFlush() {
        scheduledFlushTask?.cancel()
        scheduledFlushTask = nil
    }

    private static func placeholderItem(for app: InstalledApp) -> AppFootprintItem {
        AppFootprintItem(
            bundleID: app.metadata.bundleID,
            appName: app.metadata.appName,
            appURL: app.appURL,
            isComplete: false,
            deliveryPhase: .intermediate,
            appBundleBytes: 0,
            relatedBytes: 0,
            buckets: [
                AppFootprintBucket(
                    path: app.appURL.path,
                    bytes: 0,
                    fileCount: 0,
                    kind: .bundle
                )
            ]
        )
    }

    deinit {
        loadTask?.cancel()
        scheduledFlushTask?.cancel()
        activeSession?.cancel()
    }
}

/// v1.2 P1-6 应用占用排行榜屏。
///
/// 与 [UninstallScreen.swift](UninstallScreen.swift) 的关系：
/// - UninstallScreen 是「**清理**」入口（带 SafetyEngine 默认勾选 + dryRun + 二次确认）
/// - 本屏是「**查看**」入口（只展示哪些 app 在你磁盘上吃了多少空间，**不带删除按钮**）
///
/// 不破坏既有任何安全契约：
/// - 没有 trash 调用、没有勾选 set、没有清单提交
/// - 右键菜单仅 "在 Finder 中显示"（NSWorkspace.activateFileViewerSelecting，无写入操作）
public struct AppFootprintScreen: View {
    @StateObject private var reloadModel: AppFootprintReloadModel
    @StateObject private var iconCache = AppFootprintIconCache()
    /// v2026.07.15：String 型 placeholder、格式串与容量必须按当前界面语言即时投影。
    @Environment(\.locale) private var locale

    public init(
        store: UninstallStore? = nil,
        scanner: AppFootprintScanner? = nil,
        vendors: [VendorRule] = []
    ) {
        let unins = AppUninstaller(vendorRules: vendors)
        let resolvedStore = store ?? UninstallStore(uninstaller: unins)
        let resolvedScanner = scanner ?? AppFootprintScanner(uninstaller: unins)
        _reloadModel = StateObject(wrappedValue: AppFootprintReloadModel(
            loader: { await resolvedStore.listInstalledApps() },
            streamFactory: { resolvedScanner.scanBundleSession(apps: $0) }
        ))
    }

    public var body: some View {
        // v1.3.zz UI 修复：原本用 HSplitView + leftPane/rightPane 各 minWidth=360/320，
        // 嵌进 MainView NavigationSplitView 的 content 列（min:420 ideal:520）后，
        // 内层 minWidth 之和 680 > 外层 ideal 520，把外层 sidebar 都挤掉了一半。
        // 改成普通 HStack：左列表自适应、右详情固定占比。窄屏下整个 NavigationSplitView
        // 仍能正常约束，不会再撑破 sidebar。也去掉 navigationTitle，避免覆盖主窗"AmuxAIClean"。
        HStack(spacing: 0) {
            leftPane
                .frame(minWidth: 240, idealWidth: 320)
                .layoutPriority(1)
            Divider()
            rightPane
                .frame(minWidth: 220)
                .layoutPriority(1)
        }
        .task { reloadScreen() }
        .onReceive(NotificationCenter.default.publisher(for: .amuxTrashDidMove)) { notification in
            let paths = notification.userInfo?["paths"] as? [String] ?? []
            guard !paths.isEmpty else { return }
            reloadModel.pruneDeletedPaths(paths)
        }
        .onDisappear {
            // v2026.07.17：页面生命周期同时拥有磁盘 producer 与图标 I/O。只取消扫描
            // 会让 SwiftUI 保留的隐藏页面继续读取 LaunchServices；两者必须一起失效。
            reloadModel.cancel()
            iconCache.removeAll()
        }
    }

    // MARK: - 左栏：排行榜

    private var leftPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !reloadModel.discoveryIssues.isEmpty {
                Label {
                    Text(verbatim: AppLocalization.format(
                        "appfootprint.discovery.partial",
                        locale: locale,
                        arguments: [Int64(reloadModel.discoveryIssues.count)]
                    ))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07))
                Divider()
            }
            if reloadModel.isLoading && reloadModel.items.isEmpty {
                placeholder(AppLocalization.string("appfootprint.placeholder.loading", locale: locale), systemImage: "hourglass")
            } else if filtered.isEmpty {
                placeholder(emptyText, systemImage: "tray")
            } else {
                table
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("appfootprint.header.title", bundle: .module).font(.headline)
            if !reloadModel.items.isEmpty {
                Text("· \(reloadModel.items.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField(AppLocalization.string("appfootprint.header.search_placeholder", locale: locale), text: Binding(
                get: { reloadModel.searchQuery },
                set: { reloadModel.updateSearchQuery($0) }
            ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            if reloadModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                reloadScreen()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(reloadModel.isLoading)
            .accessibilityIdentifier("app-footprint.reload")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var table: some View {
        let maxBytes = max(1, reloadModel.items.map(\.totalBytes).max() ?? 1)
        return List(selection: Binding(
            get: { reloadModel.searchProjection.selection },
            set: { reloadModel.selected = $0 }
        )) {
            ForEach(filtered) { item in
                row(item, maxBytes: maxBytes)
                    .tag(item)
                    .contextMenu { contextMenu(for: item) }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("app-footprint.list")
    }

    @ViewBuilder
    private func row(_ item: AppFootprintItem, maxBytes: Int64) -> some View {
        let isPending = reloadModel.pendingIDs.contains(item.id)
        let ratio = Double(item.totalBytes) / Double(maxBytes)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                appIcon(for: item.appURL)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.appName)
                        .font(.system(.body, design: .rounded))
                        .lineLimit(1)
                    Text(item.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if isPending {
                        Text(item.totalBytes > 0
                             ? byteString(item.totalBytes)
                             : AppLocalization.string("appfootprint.row.computing", locale: locale))
                            .font(item.totalBytes > 0 ? .callout.monospacedDigit() : .caption)
                            .foregroundStyle(item.totalBytes > 0 ? .primary : .secondary)
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("appfootprint.row.computing", bundle: .module)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(displayedSize(for: item))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(item.isComplete ? Color.primary : Color.orange)
                        if !item.isComplete {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help(AppLocalization.string("appfootprint.partial.help", locale: locale))
                        }
                    }
                }
            }
            ratioBar(ratio: ratio, isPending: isPending)
        }
        .padding(.vertical, 4)
    }

    private func ratioBar(ratio: Double, isPending: Bool = false) -> some View {
        let clamped = min(1, max(0, ratio))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                if !isPending && clamped > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(clamped)))
                }
            }
        }
        .frame(height: 4)
    }

    private var footer: some View {
        HStack {
            if reloadModel.isLoading && reloadModel.progressTotal > 0 {
                Text(AppLocalization.format(
                    "appfootprint.footer.progress",
                    locale: locale,
                    arguments: [reloadModel.progressDone, reloadModel.progressTotal]
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !reloadModel.items.isEmpty {
                Text(AppLocalization.format(
                    "appfootprint.footer.total",
                    locale: locale,
                    arguments: [displayedLoadedTotal]
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("common.read_only_no_delete", bundle: .module)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityIdentifier("app-footprint.status")
    }

    // MARK: - 右栏：详情

    private var rightPane: some View {
        VStack(spacing: 0) {
            if let item = reloadModel.searchProjection.selection {
                if reloadModel.pendingIDs.contains(item.id) {
                    pendingDetail(item)
                } else {
                    detailHeader(item)
                    Divider()
                    detailList(item)
                }
            } else {
                placeholder(AppLocalization.string("appfootprint.placeholder.select_app", locale: locale), systemImage: "sidebar.right")
            }
        }
    }

    private func pendingDetail(_ item: AppFootprintItem) -> some View {
        VStack(spacing: 12) {
            appIcon(for: item.appURL)
                .frame(width: 42, height: 42)
            Text(item.appName)
                .font(.title3)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("appfootprint.row.computing", bundle: .module)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader(_ item: AppFootprintItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon(for: item.appURL)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.appName).font(.title3)
                Text(item.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AppLocalization.format(
                    "appfootprint.detail.total_size",
                    locale: locale,
                    arguments: [displayedSize(for: item)]
                ))
                    .font(.callout.monospacedDigit())
                if !item.isComplete {
                    Label {
                        Text("tree.subtree.partial.badge", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(AppLocalization.string("appfootprint.partial.help", locale: locale))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func detailList(_ item: AppFootprintItem) -> some View {
        List {
            ForEach(item.buckets) { b in
                bucketRow(b)
                    .contextMenu {
                        Button {
                            revealInFinder(path: b.path)
                        } label: {
                            Text("appfootprint.menu.reveal_in_finder", bundle: .module)
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func bucketRow(_ b: AppFootprintBucket) -> some View {
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: bucketIcon(b.kind))
                    .foregroundStyle(bucketTint(b.kind))
                    .frame(width: 16)
                Text(b.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Text(byteString(b.bytes))
                    .font(.callout.monospacedDigit())
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private var filtered: [AppFootprintItem] {
        reloadModel.searchProjection.items
    }

    private var loadedItems: [AppFootprintItem] {
        reloadModel.items.filter { !reloadModel.pendingIDs.contains($0.id) }
    }

    private var emptyText: String {
        if !reloadModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalization.string("appfootprint.empty.no_match", locale: locale)
        }
        if !reloadModel.discoveryIssues.isEmpty {
            return AppLocalization.string("appfootprint.empty.partial", locale: locale)
        }
        return AppLocalization.string("appfootprint.empty.no_apps", locale: locale)
    }

    private var displayedLoadedTotal: String {
        let total = loadedItems.map(\.totalBytes).reduce(0, +)
        let value = byteString(total)
        guard AppFootprintMetricProjection.isComplete(
            items: loadedItems,
            discoveryIssues: reloadModel.discoveryIssues
        ) else {
            return AppLocalization.format(
                "tree.metric.lower_bound",
                locale: locale,
                arguments: [value]
            )
        }
        return value
    }

    private func displayedSize(for item: AppFootprintItem) -> String {
        let value = byteString(item.totalBytes)
        guard !item.isComplete else { return value }
        return AppLocalization.format(
            "tree.metric.lower_bound",
            locale: locale,
            arguments: [value]
        )
    }

    @ViewBuilder
    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func appIcon(for url: URL) -> some View {
        if let icon = iconCache.image(for: url) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.medium)
        } else {
            Image(systemName: "app")
                .resizable()
                .interpolation(.medium)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadScreen() {
        iconCache.removeAll()
        reloadModel.reload()
    }

    private func byteString(_ b: Int64) -> String {
        AppLocalization.byteCount(b, locale: locale)
    }

    private func bucketIcon(_ k: AppFootprintBucket.Kind) -> String {
        switch k {
        case .bundle:      return "app.fill"
        case .userData:    return "folder"
        case .launchAgent: return "play.square"
        case .vendorRule:  return "building.2"
        }
    }

    private func bucketTint(_ k: AppFootprintBucket.Kind) -> Color {
        switch k {
        case .bundle:      return .accentColor
        case .userData:    return .blue
        case .launchAgent: return .orange
        case .vendorRule:  return .purple
        }
    }

    @ViewBuilder
    private func contextMenu(for item: AppFootprintItem) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.appURL])
        } label: {
            Text("appfootprint.menu.reveal_in_finder", bundle: .module)
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.bundleID, forType: .string)
        } label: {
            Text("appfootprint.menu.copy_bundle_id", bundle: .module)
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
