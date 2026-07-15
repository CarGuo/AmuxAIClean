import Foundation
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
    public var id: String { bundleID }
    public let bundleID: String
    public let appName: String
    public let appURL: URL
    /// true 表示 bundle 与关联目录都已统计；false 表示只完成了部分阶段。
    public let isComplete: Bool
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
        appBundleBytes: Int64,
        relatedBytes: Int64,
        buckets: [AppFootprintBucket]
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.appURL = appURL
        self.isComplete = isComplete
        self.appBundleBytes = appBundleBytes
        self.relatedBytes = relatedBytes
        self.buckets = buckets
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
                            let bundleSnap = snapshot.snapshot(at: app.appURL.path)
                            if Task.isCancelled { return nil }
                            return AppFootprintScanner.makeItem(
                                app: app,
                                bundleSnap: bundleSnap,
                                relatedBuckets: [],
                                isComplete: true
                            )
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

    /// 面向 UI 的渐进式扫描：先 yield `.app` bundle 本体，再后台补关联目录。
    ///
    /// 与 `scanAllStream` 的区别：
    /// - `scanAllStream` 保持旧契约：每个 app 只 yield 一条完整结果，方便单测和批处理。
    /// - 本方法每个 app 最多 yield 两条同 id item：`isComplete=false` 的 bundle 阶段，
    ///   以及 `isComplete=true` 的完整阶段。UI 按 id 覆盖即可，不会长期显示 0 KB。
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
                            let bundleSnap = snapshot.snapshot(at: app.appURL.path)
                            let partial = AppFootprintScanner.makeItem(
                                app: app,
                                bundleSnap: bundleSnap,
                                relatedBuckets: [],
                                isComplete: false
                            )
                            if !Task.isCancelled {
                                continuation.yield(partial)
                            }
                            if Task.isCancelled { return }
                            let relatedBuckets = await self.relatedBuckets(for: app)
                            let complete = AppFootprintScanner.makeItem(
                                app: app,
                                bundleSnap: bundleSnap,
                                relatedBuckets: relatedBuckets,
                                isComplete: true
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
        let bundleSnap = snapshot.snapshot(at: app.appURL.path)
        let relatedBuckets = await relatedBuckets(for: app)
        return Self.makeItem(app: app, bundleSnap: bundleSnap, relatedBuckets: relatedBuckets, isComplete: true)
    }

    private nonisolated func relatedBuckets(for app: InstalledApp) async -> [AppFootprintBucket] {
        let cands = await uninstaller.candidatesAsync(for: app.metadata)
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
        return relatedBuckets
    }

    private static func makeItem(
        app: InstalledApp,
        bundleSnap: FSSnapshot,
        relatedBuckets: [AppFootprintBucket],
        isComplete: Bool
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
