import Foundation
import SafetyKit

/// v1.2 P1-6 应用占用排行榜 —— 数据模型与扫描器。
///
/// 设计原则（PITFALLS §5.4 / §5.5 / §5.6）：
/// - **只读、不删** —— 这一屏只展示"哪个 app 在你磁盘上吃了多少空间"，不附带任何"清理"按钮。
///   想真正清理某 app 的数据请走「卸载残留」屏（UninstallScreen），那里有 SafetyEngine 默认勾选 + dryRun + 二次确认。
/// - **复用既有能力** —— 安装清单走 [UninstallStore.listInstalledApps()](UninstallScreen.swift)；
///   每个 app 的关联目录及其字节数走 [AppUninstaller.candidatesAsync(for:)](AppUninstaller.swift)；
///   .app bundle 自身大小走 [DefaultFileManagerSnapshot.snapshot(at:)](AppUninstaller.swift)。
/// - **TCC 不踩** —— AppUninstaller 内部用 `firstLevelEntries(at:)` 反查残留；同时本扫描不下钻到
///   ~/Library/Mail / Photos / Music 等 TCC 雷区（vendors.yaml 没有这些 vendor 的 catch-all 路径）。
/// - **不并发死命发** —— `AppFootprintScanner.scanAll()` 串行处理 app（candidatesAsync 内部已经
///   做了 8 in-flight 限流，再外层并发会让磁盘 IO 抖得很厉害）。

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
        appBundleBytes: Int64,
        relatedBytes: Int64,
        buckets: [AppFootprintBucket]
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.appURL = appURL
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
        snapshot: any FileManagerSnapshotting = DefaultFileManagerSnapshot()
    ) {
        self.uninstaller = uninstaller
        self.snapshot = snapshot
    }

    /// 主入口：对每个 app 量 bundle + 关联目录字节数，按 totalBytes 倒序返回。
    ///
    /// 如果 `progress` 非 nil，每完成一个 app 都会回调一次（已完成数 / 总数）。
    ///
    /// **同步语义**：所有 app 扫完后才返回。如果 app 数量大（数百个），UI 会等到全扫
    /// 完才能看到第一条；这种情况建议改用 [scanAllStream(apps:)](x-source-tag://scanAllStream)，
    /// 它会在每个 app 扫完时立即 yield，让 UI 走"流式两阶段加载"——先填占位 + 已完成项，
    /// 后续 item 边算边 append。
    public func scanAll(
        apps: [InstalledApp],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [AppFootprintItem] {
        var out: [AppFootprintItem] = []
        out.reserveCapacity(apps.count)

        for (idx, app) in apps.enumerated() {
            let item = await scanOne(app: app)
            out.append(item)
            progress?(idx + 1, apps.count)
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
        apps: [InstalledApp]
    ) -> AsyncStream<AppFootprintItem> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                for app in apps {
                    if Task.isCancelled { break }
                    let item = await self.scanOne(app: app)
                    if Task.isCancelled { break }
                    continuation.yield(item)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 单个 app 的聚合 —— 包内可见以便测试。
    func scanOne(app: InstalledApp) async -> AppFootprintItem {
        // (1) bundle 自身
        let bundleSnap = snapshot.snapshot(at: app.appURL.path)
        let bundleBucket = AppFootprintBucket(
            path: app.appURL.path,
            bytes: bundleSnap.bytes,
            fileCount: bundleSnap.fileCount,
            kind: .bundle
        )

        // (2) 关联目录（走既有的 candidatesAsync，自带 8 in-flight 限流）
        let cands = await uninstaller.candidatesAsync(for: app.metadata)
        var relatedBytes: Int64 = 0
        var relatedBuckets: [AppFootprintBucket] = []
        relatedBuckets.reserveCapacity(cands.count)
        for c in cands {
            relatedBytes += c.bytes
            relatedBuckets.append(.init(
                path: c.path,
                bytes: c.bytes,
                fileCount: c.fileCount,
                kind: AppFootprintScanner.bucketKind(for: c.matchReason)
            ))
        }

        // 桶按字节数倒序，UI 上"哪条最肥"在最前面
        relatedBuckets.sort { $0.bytes > $1.bytes }
        let buckets = [bundleBucket] + relatedBuckets

        return AppFootprintItem(
            bundleID: app.metadata.bundleID,
            appName: app.metadata.appName,
            appURL: app.appURL,
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
        case .vendorRule: return .vendorRule
        }
    }
}
