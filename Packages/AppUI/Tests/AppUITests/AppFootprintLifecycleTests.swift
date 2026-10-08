import Foundation
import AppKit
import XCTest
import SafetyKit
@testable import AppUI

/// v2026.07.17：App Footprint 生命周期测试只使用受控 AsyncStream 与 fake snapshot，
/// 不读取真实 /Applications，也不启动 App。
@MainActor
final class AppFootprintReloadModelTests: XCTestCase {
    /// v2026.10.08: reproduces real App search leaving an unrelated App in the detail pane.
    /// Exercise both intermediate and terminal arrivals after search-driven deselection.
    func test_searchDeselectsHiddenAppAndLateStreamCannotRestoreItsDetails() async {
        let alpha = makeApp(bundleID: "com.example.alpha", path: "/Alpha.app")
        let beta = makeApp(bundleID: "com.example.beta", path: "/Beta.app")
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { InstalledAppDiscoveryResult(apps: [alpha, beta]) },
            streamFactory: { _ in probe.session(key: "search") },
            batchLimit: 1
        )
        model.reload()
        let started = await eventually { await probe.hasStarted("search") }
        XCTAssertTrue(started)
        XCTAssertEqual(model.selected?.id, alpha.id)

        model.updateSearchQuery("  BETA  ")
        XCTAssertEqual(model.searchProjection.items.map(\.id), [beta.id])
        XCTAssertNil(model.selected, "a hidden App cannot remain the detail/action owner")
        await probe.yield(item(for: alpha, bytes: 100, deliveryPhase: .intermediate), to: "search")
        let intermediateArrived = await eventually { model.items.first(where: { $0.id == alpha.id })?.totalBytes == 100 }
        XCTAssertTrue(intermediateArrived)
        XCTAssertNil(model.selected)
        await probe.yield(item(for: alpha, bytes: 200), to: "search")
        await probe.yield(item(for: beta, bytes: 50), to: "search")
        await probe.finish("search")
        let finished = await eventually { !model.isLoading }
        XCTAssertTrue(finished)
        XCTAssertNil(model.selected)

        model.selected = model.searchProjection.items.first
        XCTAssertEqual(model.selected?.id, beta.id)
        model.updateSearchQuery("no such App")
        XCTAssertTrue(model.searchProjection.items.isEmpty)
        XCTAssertNil(model.selected)
        model.updateSearchQuery("")
        XCTAssertEqual(model.items.count, 2)
        XCTAssertNil(model.selected, "clearing search must not revive the previous hidden owner")
    }

    func test_reloadAndDeletionFallbackKeepSelectionWithinCurrentSearch() async {
        let alpha = makeApp(bundleID: "com.example.alpha", path: "/Alpha.app")
        let beta = makeApp(bundleID: "com.example.beta", path: "/Beta.app")
        let gamma = makeApp(bundleID: "com.example.beta.extra", path: "/Gamma.app")
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { InstalledAppDiscoveryResult(apps: [alpha, beta, gamma]) },
            streamFactory: { _ in probe.session(key: "filtered-reload") },
            batchLimit: 1
        )
        model.updateSearchQuery("com.example.beta")
        model.reload()
        let started = await eventually { await probe.hasStarted("filtered-reload") }
        XCTAssertTrue(started)
        XCTAssertEqual(model.selected?.id, beta.id, "reload must choose from the visible list")
        await probe.yield(item(for: alpha, bytes: 1_000), to: "filtered-reload")
        await probe.yield(item(for: beta, bytes: 200), to: "filtered-reload")
        await probe.yield(item(for: gamma, bytes: 100), to: "filtered-reload")
        await probe.finish("filtered-reload")
        let finished = await eventually { !model.isLoading }
        XCTAssertTrue(finished)

        model.pruneDeletedPaths([beta.appURL.path])
        XCTAssertEqual(model.selected?.id, gamma.id,
                       "the largest hidden App must not become the post-deletion detail")
        model.pruneDeletedPaths([gamma.appURL.path])
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.items.map(\.id), [alpha.id])
        XCTAssertTrue(model.searchProjection.items.isEmpty)
    }

    func test_cancel离页终止producer且后续item不能再写状态() async {
        let app = makeApp(bundleID: "old", path: "/Old.app")
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { [app] in InstalledAppDiscoveryResult(apps: [app]) },
            streamFactory: { probe.session(key: $0[0].metadata.bundleID) }
        )

        model.reload()
        let oldStarted = await eventually { await probe.hasStarted("old") }
        XCTAssertTrue(oldStarted)
        model.cancel()
        let producerStopped = await eventually { await probe.activeCount() == 0 }
        let terminationObserved = await eventually { await probe.terminationCount(for: "old") == 1 }
        XCTAssertTrue(producerStopped)
        XCTAssertTrue(terminationObserved)

        await probe.yield(item(for: app, bytes: 999), to: "old")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.progressDone, 0)
        XCTAssertEqual(model.items.first?.totalBytes, 0,
                       "离页旋转 revision 后，旧 producer 的晚到 item 不能再写入 UI")
    }

    func test_reload等待旧producer退出_旧item和旧终态不能覆盖新revision() async {
        let old = makeApp(bundleID: "old", path: "/Old.app")
        let fresh = makeApp(bundleID: "fresh", path: "/Fresh.app")
        let loader = AppFootprintSequenceLoader(rounds: [[old], [fresh]])
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { InstalledAppDiscoveryResult(apps: await loader.load()) },
            streamFactory: { probe.session(key: $0[0].metadata.bundleID) }
        )

        model.reload()
        let oldStarted = await eventually { await probe.hasStarted("old") }
        XCTAssertTrue(oldStarted)
        model.reload()

        let freshStarted = await eventually { await probe.hasStarted("fresh") }
        let maximumActive = await probe.maximumActiveCount()
        XCTAssertTrue(freshStarted)
        XCTAssertEqual(maximumActive, 1,
                       "重复 reload 必须等待旧 producer 排空，不能叠加 bundle snapshot I/O")
        XCTAssertTrue(model.isLoading,
                      "旧轮终态不能把仍在运行的新 revision 错误标成 finished")

        await probe.yield(item(for: old, bytes: 9_999), to: "old")
        await probe.yield(item(for: fresh, bytes: 222), to: "fresh")
        await probe.finish("fresh")
        let finished = await eventually { !model.isLoading }
        XCTAssertTrue(finished)

        XCTAssertEqual(model.items.map(\.id), [fresh.id])
        XCTAssertEqual(model.items.first?.totalBytes, 222)
        XCTAssertEqual(model.progressDone, 1)
        XCTAssertTrue(model.pendingIDs.isEmpty)
    }

    func test_快速item采用有界批量提交且终态仍强排序() async {
        let apps = (0..<25).map {
            makeApp(bundleID: "app.\($0)", path: "/App\($0).app")
        }
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { InstalledAppDiscoveryResult(apps: apps) },
            streamFactory: { _ in probe.session(key: "batch") },
            batchLimit: 8,
            flushDelayNanoseconds: 1_000_000_000
        )

        model.reload()
        let batchStarted = await eventually { await probe.hasStarted("batch") }
        XCTAssertTrue(batchStarted)
        for (index, app) in apps.enumerated() {
            await probe.yield(item(for: app, bytes: Int64(index + 1)), to: "batch")
        }
        await probe.finish("batch")
        let finished = await eventually { !model.isLoading }
        XCTAssertTrue(finished)

        XCTAssertEqual(model.progressDone, apps.count)
        XCTAssertTrue(model.pendingIDs.isEmpty)
        XCTAssertEqual(model.items.map { $0.totalBytes }, Array((1...25).reversed()).map(Int64.init),
                       "流终态必须做最终强排序，批量发布不能牺牲排行榜正确性")
        XCTAssertLessThanOrEqual(model.displayCommitCount, 5,
                                 "25 条快速结果不应触发 25 次 MainActor 全表排序")
    }

    func test_progressive中间态不结束进度_partial终态仍正常收敛() async {
        let app = makeApp(bundleID: "progressive", path: "/Progressive.app")
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { [app] in InstalledAppDiscoveryResult(apps: [app]) },
            streamFactory: { _ in probe.session(key: "progressive") },
            batchLimit: 1
        )

        model.reload()
        let started = await eventually { await probe.hasStarted("progressive") }
        XCTAssertTrue(started)

        await probe.yield(
            item(
                for: app,
                bytes: 100,
                isComplete: false,
                deliveryPhase: .intermediate
            ),
            to: "progressive"
        )
        let intermediatePublished = await eventually {
            model.items.first?.totalBytes == 100
        }
        XCTAssertTrue(intermediatePublished)
        XCTAssertEqual(model.progressDone, 0,
                       "bundle-only 中间态不能被误算成 app 扫描完成")
        XCTAssertTrue(model.pendingIDs.contains(app.id))

        await probe.yield(
            item(
                for: app,
                bytes: 150,
                isComplete: false,
                deliveryPhase: .terminal
            ),
            to: "progressive"
        )
        await probe.finish("progressive")
        let finished = await eventually { !model.isLoading }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.progressDone, 1)
        XCTAssertTrue(model.pendingIDs.isEmpty)
        XCTAssertFalse(model.items[0].isComplete,
                       "partial 终态应结束进度，但容量仍必须保留下界语义")
        XCTAssertEqual(model.items[0].deliveryPhase, .terminal)
    }

    func test_terminal之后迟到intermediate不能令状态倒退() async {
        let app = makeApp(bundleID: "monotonic", path: "/Monotonic.app")
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: { [app] in InstalledAppDiscoveryResult(apps: [app]) },
            streamFactory: { _ in probe.session(key: "monotonic") },
            batchLimit: 1
        )

        model.reload()
        let started = await eventually { await probe.hasStarted("monotonic") }
        XCTAssertTrue(started)
        await probe.yield(item(for: app, bytes: 200), to: "monotonic")
        let terminalPublished = await eventually { model.progressDone == 1 }
        XCTAssertTrue(terminalPublished)

        await probe.yield(
            item(
                for: app,
                bytes: 100,
                isComplete: false,
                deliveryPhase: .intermediate
            ),
            to: "monotonic"
        )
        await probe.finish("monotonic")
        let finished = await eventually { !model.isLoading }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.items.first?.totalBytes, 200)
        XCTAssertEqual(model.items.first?.deliveryPhase, .terminal)
        XCTAssertEqual(model.progressDone, 1)
    }

    func test_应用根缺口与App列表属于同一revision并贯穿到页面模型() async {
        let app = makeApp(bundleID: "partial", path: "/Applications/Partial.app")
        let issue = InstalledAppDiscoveryIssue(
            rootPath: "/Users/me/Applications",
            path: "/Users/me/Applications",
            reason: .permissionDenied
        )
        let probe = ControlledAppFootprintSessionProbe()
        let model = AppFootprintReloadModel(
            loader: {
                InstalledAppDiscoveryResult(apps: [app], incompleteIssues: [issue])
            },
            streamFactory: { _ in probe.session(key: "partial") }
        )

        model.reload()
        let started = await eventually { await probe.hasStarted("partial") }
        XCTAssertTrue(started)
        XCTAssertEqual(model.discoveryIssues, [issue])
        XCTAssertEqual(model.items.map(\.id), [app.id])

        await probe.finish("partial")
        _ = await eventually { !model.isLoading }

        XCTAssertFalse(AppFootprintMetricProjection.isComplete(
            items: model.items,
            discoveryIssues: model.discoveryIssues
        ), "未读取到的应用根必须让 footer 保持下界语义")
    }

    func test_metricProjection_只有根发现和每个App都完整才显示精确总量() {
        let app = makeApp(bundleID: "complete", path: "/Applications/Complete.app")
        let completeItem = item(for: app, bytes: 42)
        XCTAssertTrue(AppFootprintMetricProjection.isComplete(
            items: [completeItem],
            discoveryIssues: []
        ))

        let issue = InstalledAppDiscoveryIssue(
            rootPath: "/Users/me/Applications",
            path: "/Users/me/Applications",
            reason: .permissionDenied
        )
        XCTAssertFalse(AppFootprintMetricProjection.isComplete(
            items: [completeItem],
            discoveryIssues: [issue]
        ))
    }

    func test_同BundleID的不同安装路径拥有独立identity() {
        let first = makeApp(bundleID: "com.example.same", path: "/Applications/A.app")
        let second = makeApp(bundleID: "com.example.same", path: "/Users/me/Applications/A.app")

        XCTAssertNotEqual(item(for: first, bytes: 1).id, item(for: second, bytes: 2).id)
        XCTAssertEqual(first.id, item(for: first, bytes: 1).id,
                       "InstalledApp 与 AppFootprintItem 必须共享路径身份")
    }

    private func eventually(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }
}

/// v2026.07.17：图标缓存只验证严格上限、LRU 与 reload 失效，不启动 App 或读取
/// `/Applications`。注入 loader 可证明 SwiftUI 重算同一行不会重复走 LaunchServices。
@MainActor
final class AppFootprintIconCacheTests: XCTestCase {
    func test_iconCache命中不重复读取且LRU始终遵守硬上限() async {
        let probe = AppFootprintIconLoaderProbe()
        let cache = AppFootprintIconCache(capacity: 2) { path in
            await probe.load(path)
        }
        let a = URL(fileURLWithPath: "/Applications/A.app")
        let b = URL(fileURLWithPath: "/Applications/B.app")
        let c = URL(fileURLWithPath: "/Applications/C.app")

        XCTAssertNil(cache.image(for: a), "cache miss 必须立即返回 placeholder，不同步读取图标")
        XCTAssertNil(cache.image(for: b))
        let initialPairLoaded = await eventually { cache.cachedImageCount == 2 }
        XCTAssertTrue(initialPairLoaded)
        XCTAssertNotNil(cache.image(for: a)) // A becomes most recently used; no loader call.
        XCTAssertNil(cache.image(for: c)) // B is evicted after C finishes.
        let cLoaded = await eventually { cache.image(for: c) != nil }
        XCTAssertTrue(cLoaded)

        XCTAssertEqual(cache.cachedImageCount, 2)
        let firstACount = await probe.count(for: a.path)
        let firstBCount = await probe.count(for: b.path)
        let firstCCount = await probe.count(for: c.path)
        XCTAssertEqual(firstACount, 1)
        XCTAssertEqual(firstBCount, 1)
        XCTAssertEqual(firstCCount, 1)

        XCTAssertNil(cache.image(for: b))
        let bReloaded = await eventually { cache.image(for: b) != nil }
        XCTAssertTrue(bReloaded)
        let finalBCount = await probe.count(for: b.path)
        XCTAssertEqual(finalBCount, 2,
                       "最久未使用的 B 必须在再次访问时重新加载")
        XCTAssertEqual(cache.cachedImageCount, 2, "任何访问顺序都不能突破硬容量上限")
    }

    func test_iconCache清空后重新读取_避免刷新继续展示旧图标() async {
        let probe = AppFootprintIconLoaderProbe()
        let cache = AppFootprintIconCache(capacity: 4) { path in
            await probe.load(path)
        }
        let app = URL(fileURLWithPath: "/Applications/Changed.app")

        XCTAssertNil(cache.image(for: app))
        let firstLoadFinished = await eventually { cache.image(for: app) != nil }
        XCTAssertTrue(firstLoadFinished)
        XCTAssertNotNil(cache.image(for: app))
        let firstLoadCount = await probe.count(for: app.path)
        XCTAssertEqual(firstLoadCount, 1)

        cache.removeAll()
        XCTAssertEqual(cache.cachedImageCount, 0)
        XCTAssertNil(cache.image(for: app))
        let reloadFinished = await eventually { cache.image(for: app) != nil }
        XCTAssertTrue(reloadFinished)
        let finalLoadCount = await probe.count(for: app.path)
        XCTAssertEqual(finalLoadCount, 2)
    }

    func test_iconCache离页时取消inFlight且旧generation不能回填() async {
        let probe = AppFootprintIconLoaderProbe(delayNanoseconds: 50_000_000)
        let cache = AppFootprintIconCache(capacity: 2, maximumConcurrentLoads: 1) { path in
            await probe.load(path)
        }
        let app = URL(fileURLWithPath: "/Applications/Hidden.app")

        XCTAssertNil(cache.image(for: app))
        let inFlight = await eventually { await probe.activeLoadCount() == 1 }
        XCTAssertTrue(inFlight)
        cache.removeAll()

        let oldWorkerDrained = await eventually { cache.activeLoadCount == 0 }
        XCTAssertTrue(oldWorkerDrained)
        XCTAssertEqual(cache.cachedImageCount, 0,
                       "离页失效的旧 generation 即使同步 worker 晚到也不能写回 cache")

        XCTAssertNil(cache.image(for: app))
        let currentGenerationLoaded = await eventually { cache.image(for: app) != nil }
        XCTAssertTrue(currentGenerationLoaded)
        let loadCount = await probe.count(for: app.path)
        XCTAssertEqual(loadCount, 2,
                       "重新进入页面必须由当前 generation 发起新的图标请求")
    }

    func test_iconCache快速滚动时active与pending都有硬上限() async {
        let probe = AppFootprintIconLoaderProbe(delayNanoseconds: 30_000_000)
        let cache = AppFootprintIconCache(capacity: 4, maximumConcurrentLoads: 2) { path in
            await probe.load(path)
        }

        for index in 0..<40 {
            _ = cache.image(for: URL(fileURLWithPath: "/Applications/App\(index).app"))
            XCTAssertLessThanOrEqual(cache.activeLoadCount, 2)
            XCTAssertLessThanOrEqual(cache.pendingLoadCount, 4)
        }

        let started = await eventually { await probe.maximumActiveCount() > 0 }
        XCTAssertTrue(started)
        let maximumActive = await probe.maximumActiveCount()
        XCTAssertLessThanOrEqual(maximumActive, 2,
                                 "快速滚动不能绕过 icon loader 的全局并发上限")
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await condition()
    }
}

private actor AppFootprintIconLoaderProbe {
    private let delayNanoseconds: UInt64
    private var counts: [String: Int] = [:]
    private var activeCount = 0
    private var maximumActive = 0

    init(delayNanoseconds: UInt64 = 1_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func load(_ path: String) async -> Data? {
        counts[path, default: 0] += 1
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        defer { activeCount -= 1 }
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        // Invalid image data intentionally exercises the cache's bounded generic fallback
        // without touching LaunchServices or real applications in package tests.
        return Data([0])
    }

    func count(for path: String) -> Int { counts[path, default: 0] }
    func activeLoadCount() -> Int { activeCount }
    func maximumActiveCount() -> Int { maximumActive }
}

final class AppFootprintBundleSessionTests: XCTestCase {
    func test_关联候选partial令聚合结果保持下界语义() async throws {
        let home = "/H"
        let fixture = try makeRealAppFootprintTestApp(
            bundleID: "com.demo.partial",
            name: "Demo"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.app
        let cacheRoot = "\(home)/Library/Caches"
        let relatedPath = "\(cacheRoot)/com.demo.partial"
        let issue = FSSnapshotIssue(
            path: relatedPath,
            reason: .timeBudgetExceeded(limitMilliseconds: 10),
            stage: .budget
        )
        let snapshot = MappedAppFootprintSnapshot(
            entries: [cacheRoot: [.init(name: "com.demo.partial", path: relatedPath)]],
            values: [
                app.appURL.path: appFootprintBundleSnapshot(
                    bytes: 100,
                    fileCount: 1,
                    app: app
                ),
                relatedPath: .init(
                    bytes: 500,
                    fileCount: 5,
                    exists: true,
                    isDirectory: true,
                    completion: .partial,
                    issues: [issue]
                )
            ]
        )
        let uninstaller = AppUninstaller(
            homeDirectory: home,
            fileManager: snapshot,
            vendorRules: [],
            appMetadataReader: { _ in app.metadata }
        )
        let scanner = AppFootprintScanner(uninstaller: uninstaller, snapshot: snapshot)

        let item = await scanner.scanOne(app: app)

        XCTAssertEqual(item.totalBytes, 600)
        XCTAssertFalse(item.isComplete,
                       "任一关联候选为 partial 时，聚合总量也只能是已知下界")
    }

    func test_partialSnapshot保留下界但不会伪装成完整值() async {
        let app = makeApp(bundleID: "partial", path: "/Partial.app")
        let issue = FSSnapshotIssue(
            path: app.appURL.path,
            reason: .fileBudgetExceeded(limit: 3),
            stage: .budget
        )
        let snapshot = FixedAppFootprintSnapshot(
            value: FSSnapshot(
                bytes: 321,
                fileCount: 3,
                exists: true,
                isDirectory: true,
                completion: .partial,
                issues: [issue]
            )
        )
        let scanner = AppFootprintScanner(snapshot: snapshot)

        var items: [AppFootprintItem] = []
        for await item in scanner.scanBundleStream(apps: [app], maxConcurrent: 1) {
            items.append(item)
        }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].totalBytes, 321)
        XCTAssertFalse(items[0].isComplete,
                       "预算命中的 bytes 只是已观察下界，不能作为精确排行榜值")
    }

    func test_cancelledSnapshot不发布零字节或partialItem() async {
        let app = makeApp(bundleID: "cancelled", path: "/Cancelled.app")
        let snapshot = FixedAppFootprintSnapshot(
            value: FSSnapshot(
                bytes: 0,
                fileCount: 0,
                exists: true,
                isDirectory: true,
                completion: .cancelled,
                issues: [.init(path: app.appURL.path, reason: .cancelled, stage: .cancellation)]
            )
        )
        let scanner = AppFootprintScanner(snapshot: snapshot)

        var count = 0
        for await _ in scanner.scanBundleStream(apps: [app], maxConcurrent: 1) {
            count += 1
        }
        XCTAssertEqual(count, 0)
    }

    func test_consumer取消触发onTermination并停止补充新snapshot任务() async {
        let apps = (0..<30).map {
            makeApp(bundleID: "cancel.\($0)", path: "/Cancel\($0).app")
        }
        let snapshot = CancellableAppFootprintSnapshot()
        let scanner = AppFootprintScanner(snapshot: snapshot)
        let consumer = Task {
            for await _ in scanner.scanBundleStream(apps: apps, maxConcurrent: 2) {}
        }

        let workersStarted = await waitUntil { snapshot.startedCount >= 2 }
        XCTAssertTrue(workersStarted)
        consumer.cancel()
        await consumer.value
        let workersStopped = await waitUntil { snapshot.activeCount == 0 }
        XCTAssertTrue(workersStopped)

        XCTAssertLessThanOrEqual(snapshot.startedCount, 2,
                                 "onTermination 后只允许已在飞的任务收敛，不能继续补满剩余 apps")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }
}

private actor AppFootprintSequenceLoader {
    private let rounds: [[InstalledApp]]
    private var index = 0

    init(rounds: [[InstalledApp]]) {
        self.rounds = rounds
    }

    func load() -> [InstalledApp] {
        let current = min(index, rounds.count - 1)
        index += 1
        return rounds[current]
    }
}

private actor ControlledAppFootprintSessionProbe {
    private var continuations: [String: AsyncStream<AppFootprintItem>.Continuation] = [:]
    private var activeKeys: Set<String> = []
    private var startedKeys: Set<String> = []
    private var terminations: [String: Int] = [:]
    private var maximumActive = 0

    nonisolated func session(key: String) -> AppFootprintStreamSession {
        let pair = AsyncStream<AppFootprintItem>.makeStream(bufferingPolicy: .unbounded)
        let continuation = pair.continuation
        let producer = Task {
            await self.start(key: key, continuation: continuation)
            do {
                try await Task.sleep(nanoseconds: UInt64.max)
            } catch {
                // Cancellation is the expected controlled terminal signal.
            }
            continuation.finish()
            await self.stop(key: key)
        }
        continuation.onTermination = { _ in
            producer.cancel()
            Task { await self.recordTermination(key: key) }
        }
        return AppFootprintStreamSession(
            stream: pair.stream,
            cancel: {
                producer.cancel()
                continuation.finish()
            },
            waitForTermination: { await producer.value }
        )
    }

    func yield(_ item: AppFootprintItem, to key: String) {
        _ = continuations[key]?.yield(item)
    }

    func finish(_ key: String) {
        continuations[key]?.finish()
    }

    func hasStarted(_ key: String) -> Bool { startedKeys.contains(key) }
    func activeCount() -> Int { activeKeys.count }
    func maximumActiveCount() -> Int { maximumActive }
    func terminationCount(for key: String) -> Int { terminations[key, default: 0] }

    private func start(
        key: String,
        continuation: AsyncStream<AppFootprintItem>.Continuation
    ) {
        continuations[key] = continuation
        startedKeys.insert(key)
        activeKeys.insert(key)
        maximumActive = max(maximumActive, activeKeys.count)
    }

    private func stop(key: String) {
        continuations.removeValue(forKey: key)
        activeKeys.remove(key)
    }

    private func recordTermination(key: String) {
        terminations[key, default: 0] += 1
    }
}

private struct FixedAppFootprintSnapshot: FileManagerSnapshotting {
    let value: FSSnapshot

    func firstLevelEntries(at path: String) -> [FSEntry]? { [] }
    func snapshot(at path: String) -> FSSnapshot {
        appFootprintIdentityBoundSnapshot(value, path: path)
    }
    func snapshot(at path: String, cancellationToken: FSSnapshotCancellationToken) -> FSSnapshot {
        appFootprintIdentityBoundSnapshot(value, path: path)
    }
}

private struct MappedAppFootprintSnapshot: FileManagerSnapshotting {
    let entries: [String: [FSEntry]]
    let values: [String: FSSnapshot]

    func firstLevelEntries(at path: String) -> [FSEntry]? { entries[path] }
    func snapshot(at path: String) -> FSSnapshot {
        appFootprintIdentityBoundSnapshot(
            values[path] ?? FSSnapshot(bytes: 0, fileCount: 0, exists: false),
            path: path
        )
    }
}

/// NSLock protects the only mutable counters accessed by synchronous snapshot workers; the
/// explicit unchecked conformance is limited to this deterministic test double.
private final class CancellableAppFootprintSnapshot: FileManagerSnapshotting, @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var active = 0

    var startedCount: Int { withLock { started } }
    var activeCount: Int { withLock { active } }

    func firstLevelEntries(at path: String) -> [FSEntry]? { [] }

    func snapshot(at path: String) -> FSSnapshot {
        snapshot(at: path, cancellationToken: FSSnapshotCancellationToken())
    }

    func snapshot(at path: String, cancellationToken: FSSnapshotCancellationToken) -> FSSnapshot {
        withLock {
            started += 1
            active += 1
        }
        defer { withLock { active -= 1 } }

        for _ in 0..<100 {
            if cancellationToken.isCancelled {
                return appFootprintIdentityBoundSnapshot(FSSnapshot(
                    bytes: 0,
                    fileCount: 0,
                    exists: true,
                    isDirectory: true,
                    completion: .cancelled,
                    issues: [.init(path: path, reason: .cancelled, stage: .cancellation)]
                ), path: path)
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return appFootprintIdentityBoundSnapshot(
            FSSnapshot(bytes: 1, fileCount: 1, exists: true, isDirectory: true),
            path: path
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func makeApp(bundleID: String, path: String) -> InstalledApp {
    InstalledApp(
        appURL: URL(fileURLWithPath: path),
        metadata: AppMetadata(
            bundleID: bundleID,
            bundleVendor: AppMetadata.vendorPrefix(of: bundleID),
            appName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            executableName: "fixture"
        ),
        fileIdentity: appFootprintTestIdentity(for: path)
    )
}

private func item(
    for app: InstalledApp,
    bytes: Int64,
    isComplete: Bool = true,
    deliveryPhase: AppFootprintItem.DeliveryPhase = .terminal
) -> AppFootprintItem {
    AppFootprintItem(
        bundleID: app.metadata.bundleID,
        appName: app.metadata.appName,
        appURL: app.appURL,
        isComplete: isComplete,
        deliveryPhase: deliveryPhase,
        appBundleBytes: bytes,
        relatedBytes: 0,
        buckets: [
            AppFootprintBucket(
                path: app.appURL.path,
                bytes: bytes,
                fileCount: 1,
                kind: .bundle
            )
        ]
    )
}
