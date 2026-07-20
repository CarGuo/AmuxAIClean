import Foundation
import Dispatch
import Darwin
import SafetyKit

/// v1.2 P1-6 应用占用排行榜 —— 数据模型与扫描器。
///
/// 设计原则（PITFALLS §5.4 / §5.5 / §5.6）：
/// - **只读、不删** —— 这一屏只展示"哪个 app 在你磁盘上吃了多少空间"，不附带任何"清理"按钮。
///   想真正清理某 app 的数据请走「卸载残留」屏（UninstallScreen），那里有 SafetyEngine 默认勾选 + dryRun + 二次确认。
/// - **默认只看 App 本体** —— 安装清单走 [UninstallStore.listInstalledApps()](UninstallScreen.swift)；
///   应用占用 UI 只统计 `.app` bundle 自身体积。关联目录属于「应用卸载」的精细候选扫描，
///   不在本屏默认触发。
/// - **TCC 不踩** —— AppUninstaller 内部用 `firstLevelEntries(at:)` 反查残留；同时本扫描不下钻到
///   ~/Library/Mail / Photos / Music 等 TCC 雷区（vendors.yaml 没有这些 vendor 的 catch-all 路径）。
/// - **不并发死命发** —— `AppFootprintScanner.scanAllStream()` 只开有限外层并发，
///   `candidatesAsync` 内部也有限流；真实磁盘 snapshot 还有单目录预算，避免大型 App 把页面等死。

// MARK: - 数据模型

/// 单个 app 的占用桶 —— 用来在 UI 上展开"它的体积分布在哪些目录"。
public struct AppFootprintBucket: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let fileCount: Int
    public let kind: Kind

    public enum Kind: String, Hashable, Sendable {
        /// .app bundle 自身（通常在 /Applications 下）。
        case bundle
        /// 用户级关联目录（Library/Application Support / Caches / Logs / Containers / ...）。
        case userData
        /// 启动项 plist（LaunchAgents / LaunchDaemons）。
        case launchAgent
        /// vendors.yaml 命中的厂商级目录。
        case vendorRule
    }

    public init(path: String, bytes: Int64, fileCount: Int, kind: Kind) {
        self.path = path
        self.bytes = bytes
        self.fileCount = fileCount
        self.kind = kind
    }
}

/// 排行榜单条 —— 一个 app 的体积聚合。
public struct AppFootprintItem: Hashable, Sendable, Identifiable {
    /// v2026.07.17：流的交付阶段与容量证据完整度是两个正交维度。
    ///
    /// `intermediate` 只用于 progressive stream 的 bundle-only 首阶段；`terminal`
    /// 表示该 app 本轮已不再有后续更新。终态仍可能因为预算或访问缺口而
    /// `isComplete == false`，因此消费方禁止再用 `isComplete` 推断进度完成。
    public enum DeliveryPhase: String, Hashable, Sendable {
        case intermediate
        case terminal
    }

    /// v2026.07.17：安装实例由 bundle 路径唯一标识。不同路径可能安装同一个
    /// Bundle ID；若用 bundleID 作为 List/刷新键，会让一条结果覆盖另一条，且与
    /// `InstalledApp.id` 的路径身份不一致，导致 pending 永远无法收敛。
    public var id: String { appURL.path }
    public let bundleID: String
    public let appName: String
    public let appURL: URL
    /// true 表示当前已交付范围的容量证据完整；false 表示容量扫描命中预算/访问缺口，
    /// 或 intermediate 阶段尚未覆盖最终范围。是否还会收到后续更新只看
    /// `deliveryPhase`，不能从这个布尔值反推。
    public let isComplete: Bool
    /// 当前 item 是两阶段流的中间交付，还是该 app 本轮的终态交付。
    public let deliveryPhase: DeliveryPhase
    /// .app bundle 自身字节数（如 /Applications/Foo.app 整个目录的大小）。
    public let appBundleBytes: Int64
    /// 关联目录（用户数据 + 启动项 + vendor 命中）的字节数总和。
    public let relatedBytes: Int64
    /// 各桶的细分。可在 UI 右侧展开"为什么这个 app 占了这么多"。
    public let buckets: [AppFootprintBucket]

    public var totalBytes: Int64 { appBundleBytes + relatedBytes }

    public init(
        bundleID: String,
        appName: String,
        appURL: URL,
        isComplete: Bool = true,
        deliveryPhase: DeliveryPhase = .terminal,
        appBundleBytes: Int64,
        relatedBytes: Int64,
        buckets: [AppFootprintBucket]
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.appURL = appURL
        self.isComplete = isComplete
        self.deliveryPhase = deliveryPhase
        self.appBundleBytes = appBundleBytes
        self.relatedBytes = relatedBytes
        self.buckets = buckets
    }
}

/// 一轮 App Footprint 流的 producer 所有权。
///
/// `AsyncStream` 自身只能通知 producer “消费者已经离开”，不能让下一轮 reload 等待
/// 上一轮同步文件系统调用真正退出。这个 session 同时暴露 cancel 与 terminal wait，
/// 让界面在启动新一轮 I/O 前先排空旧 producer，避免快速刷新叠加磁盘遍历。
struct AppFootprintStreamSession: Sendable {
    let stream: AsyncStream<AppFootprintItem>
    private let cancelProducer: @Sendable () -> Void
    private let waitForProducer: @Sendable () async -> Void

    init(
        stream: AsyncStream<AppFootprintItem>,
        cancel: @escaping @Sendable () -> Void,
        waitForTermination: @escaping @Sendable () async -> Void
    ) {
        self.stream = stream
        self.cancelProducer = cancel
        self.waitForProducer = waitForTermination
    }

    func cancel() {
        cancelProducer()
    }

    func waitForTermination() async {
        await waitForProducer()
    }
}

// MARK: - 扫描器

/// 把 [InstalledApp] 转成 [AppFootprintItem]。
///
/// 串行处理 app（`candidatesAsync` 内部已经并发限流），保证主磁盘不会同时被 N 个全树
/// snapshot 撕开。
public actor AppFootprintScanner {
    private let uninstaller: AppUninstaller
    private let snapshot: any FileManagerSnapshotting

    public init(
        uninstaller: AppUninstaller = AppUninstaller(),
        snapshot: any FileManagerSnapshotting = DefaultFileManagerSnapshot(
            maxDescendantFiles: 120_000,
            maxSnapshotDuration: 4
        )
    ) {
        self.uninstaller = uninstaller
        self.snapshot = snapshot
    }

    /// 主入口：对每个 app 量 bundle + 关联目录字节数，按 totalBytes 倒序返回。
    ///
    /// 如果 `progress` 非 nil，每完成一个 app 都会回调一次（已完成数 / 总数）。
    ///
    /// 进度 sink 是 async，且每次发布都会等待前一次 sink 处理完毕。这是有意的
    /// 顺序边界：actor / UI 消费方可以直接 `await` 写入自己的状态，无需再开
    /// 一个无结构 `Task`，从而避免 `(1, total)` 与 `(2, total)` 被调度成倒序。
    /// sink 仍在扫描任务的 executor 上执行，不会把磁盘扫描或进度组装移到 MainActor。
    ///
    /// **同步语义**：所有 app 扫完后才返回。如果 app 数量大（数百个），UI 会等到全扫
    /// 完才能看到第一条；这种情况建议改用 [scanAllStream(apps:)](x-source-tag://scanAllStream)，
    /// 它会在每个 app 扫完时立即 yield，让 UI 走"流式两阶段加载"——先填占位 + 已完成项，
    /// 后续 item 边算边 append。
    public func scanAll(
        apps: [InstalledApp],
        progress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [AppFootprintItem] {
        var out: [AppFootprintItem] = []
        out.reserveCapacity(apps.count)

        for (idx, app) in apps.enumerated() {
            let item = await scanOne(app: app)
            out.append(item)
            await progress?(idx + 1, apps.count)
        }

        out.sort { $0.totalBytes > $1.totalBytes }
        return out
    }

    /// docs/AUDIT_2026_06.md §4.1 P3 —— 两阶段加载流式入口。
    ///
    /// 返回一个 `AsyncStream<AppFootprintItem>`：每完成一个 app 就 yield 一条，
    /// 消费方（AppFootprintScreen）可以边收边 append + 重排，**不必等所有 app 扫完
    /// 才看到第一行**。
    ///
    /// 复用同款 `scanOne(app:)`，所以单 app 聚合逻辑与 `scanAll` 完全一致。
    /// 字节数 / 桶分类 / bundle vs related 全部走同一条路径。
    ///
    /// **取消语义**：与 [FileSearchEngine](../FileSearchKit/Sources/FileSearchKit/FileSearchEngine.swift)
    /// 的流式 detached 模式一致——消费方 `break` 出 for-await 时，
    /// `continuation.onTermination` 会触发，detached 内层 task 被 cancel，停止后续 scanOne。
    ///
    /// - Tag: scanAllStream
    public nonisolated func scanAllStream(
        apps: [InstalledApp],
        maxConcurrent: Int = 3
    ) -> AsyncStream<AppFootprintItem> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard !apps.isEmpty else {
                    continuation.finish()
                    return
                }
                let limit = max(1, min(maxConcurrent, apps.count))
                await withTaskGroup(of: AppFootprintItem?.self) { group in
                    var iterator = apps.makeIterator()
                    var inFlight = 0

                    func enqueue(_ app: InstalledApp) {
                        inFlight += 1
                        group.addTask(priority: .utility) { [self] in
                            if Task.isCancelled { return nil }
                            let item = await self.scanOne(app: app)
                            if Task.isCancelled { return nil }
                            return item
                        }
                    }

                    while inFlight < limit, let app = iterator.next(), !Task.isCancelled {
                        enqueue(app)
                    }

                    while let item = await group.next() {
                        inFlight -= 1
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }
                        if let item {
                            continuation.yield(item)
                        }
                        if let next = iterator.next(), !Task.isCancelled {
                            enqueue(next)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// UI 默认入口：只统计 `.app` bundle 本体大小。
    ///
    /// 这避免了「应用占用」为了展示排行榜而复用卸载残留的关联目录扫描，尤其是
    /// WeChat / 浏览器 / Office 这类巨大 Container，不应在只读排行榜里被默认深扫。
    public nonisolated func scanBundleStream(
        apps: [InstalledApp],
        maxConcurrent: Int = 4
    ) -> AsyncStream<AppFootprintItem> {
        scanBundleSession(apps: apps, maxConcurrent: maxConcurrent).stream
    }

    /// v2026.07.17：UI 使用的可取消、可等待终态 session。
    ///
    /// 一轮共享 cancellation token，使同步 snapshot 能在目录逐项边界观察离页/刷新；
    /// `.cancelled` 快照绝不能作为 0 B 或 partial 排行结果发布。预算截断则保留已观察
    /// bytes，但 `isComplete=false`，明确表达“至少这些”而非精确值。
    nonisolated func scanBundleSession(
        apps: [InstalledApp],
        maxConcurrent: Int = 4
    ) -> AppFootprintStreamSession {
        let pair = AsyncStream<AppFootprintItem>.makeStream(bufferingPolicy: .unbounded)
        let continuation = pair.continuation
        let cancellationToken = FSSnapshotCancellationToken()
        let task = Task.detached(priority: .userInitiated) { [self] in
            guard !apps.isEmpty else {
                continuation.finish()
                return
            }
            let limit = max(1, min(maxConcurrent, apps.count))
            await withTaskGroup(of: AppFootprintItem?.self) { group in
                var iterator = apps.makeIterator()
                var inFlight = 0

                func enqueue(_ app: InstalledApp) {
                    inFlight += 1
                    group.addTask(priority: .utility) { [self] in
                        guard !Task.isCancelled, !cancellationToken.isCancelled else { return nil }
                        let measuredBundleSnap = await Self.snapshotOffCooperativeExecutor(
                            snapshot,
                            at: app.appURL.path,
                            cancellationToken: cancellationToken
                        )
                        let bundleSnap = Self.identityBoundBundleSnapshot(
                            measuredBundleSnap,
                            app: app
                        )
                        guard !Task.isCancelled,
                              !cancellationToken.isCancelled,
                              bundleSnap.completion != .cancelled else { return nil }
                        return AppFootprintScanner.makeItem(
                            app: app,
                            bundleSnap: bundleSnap,
                            relatedBuckets: [],
                            isComplete: Self.isComplete(bundleSnap)
                        )
                    }
                }

                while inFlight < limit,
                      let app = iterator.next(),
                      !Task.isCancelled,
                      !cancellationToken.isCancelled {
                    enqueue(app)
                }

                while let item = await group.next() {
                    inFlight -= 1
                    if Task.isCancelled || cancellationToken.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let item {
                        continuation.yield(item)
                    }
                    if let next = iterator.next(),
                       !Task.isCancelled,
                       !cancellationToken.isCancelled {
                        enqueue(next)
                    }
                }
            }
            continuation.finish()
        }

        let cancel: @Sendable () -> Void = {
            cancellationToken.cancel()
            task.cancel()
        }
        continuation.onTermination = { _ in
            cancel()
        }
        return AppFootprintStreamSession(
            stream: pair.stream,
            cancel: cancel,
            waitForTermination: { await task.value }
        )
    }

    /// 面向 UI 的渐进式扫描：先 yield `.app` bundle 本体，再后台补关联目录。
    ///
    /// 与 `scanAllStream` 的区别：
    /// - `scanAllStream` 保持旧契约：每个 app 只 yield 一条完整结果，方便单测和批处理。
    /// - 本方法每个 app 最多 yield 两条同 id item：`deliveryPhase=intermediate` 的
    ///   bundle 阶段，以及一次 `deliveryPhase=terminal` 终态；若终态 snapshot 有预算/
    ///   访问缺口，其 `isComplete` 仍为 false。
    ///   UI 按 id 覆盖即可，不会长期显示 0 KB，也不会把下界伪装为精确值。
    public nonisolated func scanProgressiveStream(
        apps: [InstalledApp],
        maxConcurrent: Int = 3
    ) -> AsyncStream<AppFootprintItem> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard !apps.isEmpty else {
                    continuation.finish()
                    return
                }
                let limit = max(1, min(maxConcurrent, apps.count))
                await withTaskGroup(of: Void.self) { group in
                    var iterator = apps.makeIterator()
                    var inFlight = 0

                    func enqueue(_ app: InstalledApp) {
                        inFlight += 1
                        group.addTask(priority: .utility) { [self] in
                            if Task.isCancelled { return }
                            let measuredBundleSnap = await Self.snapshotOffCooperativeExecutor(
                                snapshot,
                                at: app.appURL.path
                            )
                            let bundleSnap = Self.identityBoundBundleSnapshot(
                                measuredBundleSnap,
                                app: app
                            )
                            guard bundleSnap.completion != .cancelled else { return }
                            let partial = AppFootprintScanner.makeItem(
                                app: app,
                                bundleSnap: bundleSnap,
                                relatedBuckets: [],
                                isComplete: false,
                                deliveryPhase: .intermediate
                            )
                            if !Task.isCancelled {
                                continuation.yield(partial)
                            }
                            if Task.isCancelled { return }
                            let related = await self.relatedBuckets(for: app)
                            let complete = AppFootprintScanner.makeItem(
                                app: app,
                                bundleSnap: bundleSnap,
                                relatedBuckets: related.buckets,
                                isComplete: Self.isComplete(bundleSnap) && related.isComplete
                            )
                            if !Task.isCancelled {
                                continuation.yield(complete)
                            }
                        }
                    }

                    while inFlight < limit, let app = iterator.next(), !Task.isCancelled {
                        enqueue(app)
                    }

                    while await group.next() != nil {
                        inFlight -= 1
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }
                        if let next = iterator.next(), !Task.isCancelled {
                            enqueue(next)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 单个 app 的聚合 —— 包内可见以便测试。
    nonisolated func scanOne(app: InstalledApp) async -> AppFootprintItem {
        // (1) bundle 自身
        let measuredBundleSnap = await Self.snapshotOffCooperativeExecutor(
            snapshot,
            at: app.appURL.path
        )
        let bundleSnap = Self.identityBoundBundleSnapshot(measuredBundleSnap, app: app)
        let related = await relatedBuckets(for: app)
        return Self.makeItem(
            app: app,
            bundleSnap: bundleSnap,
            relatedBuckets: related.buckets,
            isComplete: Self.isComplete(bundleSnap) && related.isComplete
        )
    }

    private struct RelatedBucketsResult: Sendable {
        let buckets: [AppFootprintBucket]
        let isComplete: Bool
    }

    private nonisolated func relatedBuckets(for app: InstalledApp) async -> RelatedBucketsResult {
        // URL and metadata are one claim. AppUninstaller re-reads Info.plist at this production
        // boundary; a replaced bundle yields a typed identity issue and no related candidates.
        guard let selectedIdentity = UninstallSelectedAppIdentity(installedApp: app) else {
            return RelatedBucketsResult(buckets: [], isComplete: false)
        }
        let cands = await uninstaller.candidatesAsync(for: selectedIdentity)
        var relatedBuckets: [AppFootprintBucket] = []
        relatedBuckets.reserveCapacity(cands.count)
        for c in cands {
            relatedBuckets.append(.init(
                path: c.path,
                bytes: c.bytes,
                fileCount: c.fileCount,
                kind: AppFootprintScanner.bucketKind(for: c.matchReason)
            ))
        }

        // 桶按字节数倒序，UI 上"哪条最肥"在最前面
        relatedBuckets.sort { $0.bytes > $1.bytes }
        return RelatedBucketsResult(
            buckets: relatedBuckets,
            isComplete: cands.isDiscoveryComplete && cands.allSatisfy(\.hasCompleteSnapshot)
        )
    }

    private static func isComplete(_ snapshot: FSSnapshot) -> Bool {
        // A bundle that disappeared after installed-App discovery is not a precise 0-byte App.
        // Candidate discovery may treat exact ENOENT as a complete absence, but footprint rows must
        // retain the distinction between "clean path missing" and "installed bundle measured".
        snapshot.exists && snapshot.completion == .complete && snapshot.issues.isEmpty
    }

    /// v2026.07.18: a pathname measurement cannot be labelled with metadata from a different
    /// installed bundle. A missing scan-time capability, missing measured identity, non-directory
    /// root, or replacement publishes an incomplete zero lower bound instead of App B's bytes as A.
    private static func identityBoundBundleSnapshot(
        _ measured: FSSnapshot,
        app: InstalledApp
    ) -> FSSnapshot {
        guard let expected = app.fileIdentity,
              let observed = measured.objectIdentity,
              expected.matches(observed),
              observed.fileType == UInt16(S_IFDIR) else {
            var issues = measured.issues
            let issue = FSSnapshotIssue(
                path: app.appURL.path,
                reason: .metadataUnavailable,
                stage: .rootMetadata
            )
            if !issues.contains(issue) { issues.append(issue) }
            return FSSnapshot(
                bytes: 0,
                logicalBytes: 0,
                fileCount: 0,
                exists: measured.exists,
                isDirectory: true,
                objectIdentity: measured.objectIdentity,
                completion: measured.completion == .cancelled ? .cancelled : .partial,
                issues: issues
            )
        }
        return measured
    }

    /// v2026.07.17：`FileManager.enumerator` / `stat` 遍历是同步阻塞 I/O，不能直接占用
    /// Swift cooperative executor 的 worker。统一桥接到 utility DispatchQueue；取消通过
    /// typed token 在逐项边界传播，调用方仍 await 精确终态，不创建 fire-and-forget 工作。
    private static func snapshotOffCooperativeExecutor(
        _ snapshotter: any FileManagerSnapshotting,
        at path: String,
        cancellationToken providedToken: FSSnapshotCancellationToken? = nil
    ) async -> FSSnapshot {
        let token = providedToken ?? FSSnapshotCancellationToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: snapshotter.snapshot(
                        at: path,
                        cancellationToken: token
                    ))
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    private static func makeItem(
        app: InstalledApp,
        bundleSnap: FSSnapshot,
        relatedBuckets: [AppFootprintBucket],
        isComplete: Bool,
        deliveryPhase: AppFootprintItem.DeliveryPhase = .terminal
    ) -> AppFootprintItem {
        let bundleBucket = AppFootprintBucket(
            path: app.appURL.path,
            bytes: bundleSnap.bytes,
            fileCount: bundleSnap.fileCount,
            kind: .bundle
        )
        let relatedBytes = relatedBuckets.reduce(Int64(0)) { $0 + $1.bytes }
        let buckets = [bundleBucket] + relatedBuckets

        return AppFootprintItem(
            bundleID: app.metadata.bundleID,
            appName: app.metadata.appName,
            appURL: app.appURL,
            isComplete: isComplete,
            deliveryPhase: deliveryPhase,
            appBundleBytes: bundleSnap.bytes,
            relatedBytes: relatedBytes,
            buckets: buckets
        )
    }

    /// MatchReason → 桶的展示分类。
    static func bucketKind(for reason: MatchReason) -> AppFootprintBucket.Kind {
        switch reason {
        case .bundleID, .appName, .spotlight: return .userData
        case .bundleVendor: return .launchAgent
        case .vendorRule, .pkgReceipt: return .vendorRule
        }
    }
}
