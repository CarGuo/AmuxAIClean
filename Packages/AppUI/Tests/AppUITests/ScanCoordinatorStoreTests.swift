import XCTest
@testable import AppUI
@testable import ScanKit

/// M1 必补 E2E：ScanCoordinator 与真实 GRDBScanResultStore 联动行为契约。
///
/// 现有 4 个 ScanCoordinator 测试文件全部用 `resultStore: nil` 默认参数，
/// 等价于"feature flag OFF 路径回归"。本文件专注 ON 路径——即真注入 store
/// 后扫描期 ingest → flush → finalize → compactAfterScan → largeFilesFromStore
/// 这一整条 M1 新增链路的契约。
///
/// 单测节奏：
/// - fixture 都是 /tmp 下小目录，避免触碰真实 ~/。
/// - store 落 /tmp 的临时 sqlite，每个用例独立 dbURL，不会污染生产 store。
/// - 等待 finalize：扫描结束（snapshot.isFinished）后还需要等 detached
///   `flushAndFinalizeStore` Task 完成才能 query 出最终结果，所以用
///   `waitFinalized` 轮询 aggregate.totalCount > 0 / == 期望值 兜底。
@MainActor
final class ScanCoordinatorStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScanCoordStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Fixture & helpers

    /// 在 fixture 根下批量造小文件，文件名递增，每个 `bytesEach` 字节。
    private func seedFiles(in root: URL, count: Int, bytesEach: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<count {
            let url = root.appendingPathComponent("f\(i).bin")
            try Data(repeating: 0xAB, count: bytesEach).write(to: url)
        }
    }

    /// 在多根 fixture 下造 5 个 `Library/Caches`-like 子目录，每个塞几个小文件。
    private func makeMultiRootFakeHome() throws -> String {
        let raw = tempDir.appendingPathComponent("home-\(UUID().uuidString)").path
        let home = URL(fileURLWithPath: raw).standardizedFileURL.path
        let subs = [
            "Library/Caches",
            "Library/Logs",
            "Library/Developer/Xcode/DerivedData",
            "Downloads",
            ".Trash"
        ]
        for s in subs {
            let dir = home + "/" + s
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x11, count: 256)
                .write(to: URL(fileURLWithPath: dir + "/sample.bin"))
        }
        return home
    }

    private func makeCategory(rootPath: String) -> ScanCategory {
        ScanCategory(
            id: "test.store",
            title: "test",
            subtitle: "",
            rootPath: rootPath,
            defaultVerdict: .confirm,
            kind: .largeFiles
        )
    }

    /// 等扫描事件循环结束（isScanning false 且 snapshot.isFinished）。
    private func waitScanFinished(_ coord: ScanCoordinator,
                                  timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (coord.isScanning || !coord.snapshot.isFinished) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }
    }

    /// 等到 store 中本 session 的 aggregate count >= 期望值。
    /// 因为 flush + finalize 是 detached Task，扫描"看起来结束"和"sqlite 落盘"
    /// 之间存在毫秒级缝隙，必须等。
    private func waitStoreAggregate(
        store: GRDBScanResultStore,
        sid: ScanSessionID,
        atLeast: Int,
        timeout: TimeInterval = 4
    ) async throws -> ScanResultAggregate {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ScanResultAggregate.empty
        while Date() < deadline {
            last = try await store.aggregate(sessionID: sid, parentPath: nil)
            if last.totalCount >= atLeast { return last }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return last
    }

    /// 等到 store 中本 session 的 aggregate.totalCount 稳定在某值若干次采样
    /// （等 finalize 完成的兜底）。
    private func waitStoreSettled(
        store: GRDBScanResultStore,
        sid: ScanSessionID,
        timeout: TimeInterval = 4
    ) async throws {
        var lastCount = -1
        var stableTicks = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let agg = try await store.aggregate(sessionID: sid, parentPath: nil)
            if agg.totalCount == lastCount {
                stableTicks += 1
                if stableTicks >= 3 { return }
            } else {
                lastCount = agg.totalCount
                stableTicks = 0
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func makeStore() throws -> GRDBScanResultStore {
        let dbURL = tempDir.appendingPathComponent("scan-\(UUID().uuidString).sqlite")
        return try GRDBScanResultStore(databaseURL: dbURL)
    }

    // MARK: - 用例

    /// 注入真实 store + 扫一个非空 fixture：扫完后 store 内 row 数应 >= fixture 中的文件数。
    /// 这是 ScanCoordinator → ingest → flush → finalize 整条链路最基础的端到端验证。
    func test_注入store_扫完后session被finalize且能查到全部文件() async throws {
        let root = tempDir.appendingPathComponent("seed-basic")
        try seedFiles(in: root, count: 12, bytesEach: 1024)

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        coord.scan(category: makeCategory(rootPath: root.path), includeHidden: true)
        await waitScanFinished(coord)

        let sid = try XCTUnwrap(coord.currentSessionID,
                                "scan() 应在启动时建立 currentSessionID")
        // 至少 12 个文件落盘（目录条目可能也写入，所以用 >= 12 而不是 == 12）
        let agg = try await waitStoreAggregate(store: store, sid: sid, atLeast: 12)
        XCTAssertGreaterThanOrEqual(agg.totalCount, 12,
                                    "扫描结束后 store 中应至少包含 fixture 12 个文件的记录")
    }

    /// 空目录扫描：store 中 session 仍被 finalize（虽然 row 数为 0）。
    /// 防御 ingest 路径里"空 batch 不发 finalize"的常见误实现。
    func test_空目录扫描_session仍被finalize_aggregate为empty() async throws {
        let root = tempDir.appendingPathComponent("seed-empty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        coord.scan(category: makeCategory(rootPath: root.path), includeHidden: true)
        await waitScanFinished(coord)
        let sid = try XCTUnwrap(coord.currentSessionID)

        try await waitStoreSettled(store: store, sid: sid)
        let agg = try await store.aggregate(sessionID: sid, parentPath: nil)
        // 允许 root 自身被作为目录条目写入，所以最多 1 条；不能更多。
        XCTAssertLessThanOrEqual(agg.totalCount, 1,
                                 "空目录扫描后 store 不应有任何子文件记录")
    }

    /// 跨过 1000 阈值的中途 flush：fixture 1100 个小文件，最终 row 数 >= 1100。
    /// 验证 storeBatch 满 1000 时触发 flushStoreBatch + 收尾 flushAndFinalizeStore
    /// 配合无丢失。
    func test_超过flushBatchSize文件数_最终row数完整() async throws {
        let root = tempDir.appendingPathComponent("seed-1100")
        try seedFiles(in: root, count: 1100, bytesEach: 64)

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        coord.scan(category: makeCategory(rootPath: root.path), includeHidden: true)
        await waitScanFinished(coord, timeout: 15)

        let sid = try XCTUnwrap(coord.currentSessionID)
        let agg = try await waitStoreAggregate(store: store, sid: sid, atLeast: 1100, timeout: 8)
        XCTAssertGreaterThanOrEqual(agg.totalCount, 1100,
                                    "跨阈值 flush 不能丢任何文件")
    }

    /// scan 启动后立刻 cancel：cancel 内 evictSession + 清 currentSessionID 应生效。
    /// 保证用户连点"扫描-停止"不会让 store 留下半截 session。
    func test_cancel后currentSessionID被清空且session从store中evict() async throws {
        let root = tempDir.appendingPathComponent("seed-cancel")
        try seedFiles(in: root, count: 3, bytesEach: 128)

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        coord.scan(category: makeCategory(rootPath: root.path), includeHidden: true)

        // scan 同步路径已分配 sid
        let sid = try XCTUnwrap(coord.currentSessionID,
                                "scan() 同步路径应在启动帧分配 sid")

        coord.cancel()
        XCTAssertNil(coord.currentSessionID,
                     "cancel 必须把 currentSessionID 置 nil，否则下一轮会复用旧 sid")
        XCTAssertFalse(coord.isScanning)

        // evictSession 是 detached，等异步落盘
        let deadline = Date().addingTimeInterval(3)
        var agg = try await store.aggregate(sessionID: sid, parentPath: nil)
        while agg.totalCount > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            agg = try await store.aggregate(sessionID: sid, parentPath: nil)
        }
        XCTAssertEqual(agg.totalCount, 0,
                       "cancel 后该 session 在 store 中应被 evict 干净")
    }

    /// scanRecommended：5 根共享同一个 sessionID。
    /// 防御未来误改为"每根一个 session"导致 evict 粒度错位。
    func test_scanRecommended多根共享同一sessionID() async throws {
        let home = try makeMultiRootFakeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let store = try makeStore()
        let coord = ScanCoordinator(home: home, resultStore: store)
        coord.scanRecommended(includeHidden: true)
        await waitScanFinished(coord, timeout: 10)

        let sid = try XCTUnwrap(coord.currentSessionID,
                                "scanRecommended 应在启动帧建立单一共享 sid")
        // 5 根每根至少 1 个 sample.bin，store 中至少 5 行
        let agg = try await waitStoreAggregate(store: store, sid: sid, atLeast: 5, timeout: 8)
        XCTAssertGreaterThanOrEqual(agg.totalCount, 5,
                                    "5 根的全部文件应落在同一 sid 下")
    }

    /// compactAfterScan + largeFilesFromStore：核心 happy path。
    /// compact 后内存里 largeFileLeaves 被清掉，但 largeFilesFromStore 仍能从盘读到。
    func test_compactAfterScan后largeFilesFromStore仍能读到大文件() async throws {
        let root = tempDir.appendingPathComponent("seed-large")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 造 3 个 ≥ 2MB 的文件，触发 largeFile 收集（视图阈值 1MB）
        for i in 0..<3 {
            let url = root.appendingPathComponent("big\(i).bin")
            try Data(repeating: 0xCD, count: 2 * 1024 * 1024).write(to: url)
        }

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        // 用 scan(category:) 显式传 largeFileMinBytes，让 ScanCoordinator
        // 在扫描期就把这些文件标到 largeFileLeaves
        coord.scan(category: makeCategory(rootPath: root.path),
                   includeHidden: true,
                   largeFileMinBytes: 1024 * 1024)
        await waitScanFinished(coord, timeout: 8)

        let sid = try XCTUnwrap(coord.currentSessionID)
        _ = try await waitStoreAggregate(store: store, sid: sid, atLeast: 3, timeout: 4)

        // compact：largeFileLeaves 应被清空
        coord.compactAfterScan()
        XCTAssertEqual(coord.largeFileCollectedCount, 0,
                       "compactAfterScan 应清空 largeFileLeaves")

        // store 路径仍能拿回大文件（minSizeMB=1 即 ≥1MB）
        let items = await coord.largeFilesFromStore(minSizeMB: 1, sortKey: .sizeDesc, limit: 50)
        XCTAssertGreaterThanOrEqual(items.count, 3,
                                    "compact 后 largeFilesFromStore 仍应能从盘读出全部大文件")
        XCTAssertTrue(items.allSatisfy { $0.bytes >= 1024 * 1024 })
    }

    /// compactAfterScan 在未结束 / store nil 时是 noop —— OFF 路径行为锁定。
    func test_compactAfterScan_未finished或storeNil时是noop() async throws {
        // store nil 路径：内存版本不应被 compact
        let coord1 = ScanCoordinator()
        coord1.compactAfterScan() // 不崩
        XCTAssertEqual(coord1.largeFileCollectedCount, 0) // 本来就空

        // store 注入但未启动扫描：isFinished == false → noop
        let store = try makeStore()
        let coord2 = ScanCoordinator(resultStore: store)
        XCTAssertFalse(coord2.snapshot.isFinished)
        coord2.compactAfterScan() // 不崩
    }

    /// largeFilesFromStore 在 store nil / sid nil 时返回空数组而非崩溃。
    func test_largeFilesFromStore_storeNil或sidNil时返回空() async throws {
        let coord = ScanCoordinator()
        let items = await coord.largeFilesFromStore(minSizeMB: 1, sortKey: .sizeDesc)
        XCTAssertTrue(items.isEmpty)
    }

    /// M3 核心：调 compactAfterScanPreservingCache 后，largeFiles(...) **仍能**
    /// 同步返回大文件——既享受了内存释放，UI 又不会回退为空白。
    /// 这是修复原 review P0-D 的硬验证（"store 路径未真正接通 LargeFilesView"）。
    func test_compactAfterScanPreservingCache_largeFiles同步仍可读() async throws {
        let root = tempDir.appendingPathComponent("seed-cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<3 {
            let url = root.appendingPathComponent("big\(i).bin")
            try Data(repeating: 0xCD, count: 2 * 1024 * 1024).write(to: url)
        }

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        coord.scan(category: makeCategory(rootPath: root.path),
                   includeHidden: true,
                   largeFileMinBytes: 1024 * 1024)
        await waitScanFinished(coord, timeout: 8)

        let sid = try XCTUnwrap(coord.currentSessionID)
        _ = try await waitStoreAggregate(store: store, sid: sid, atLeast: 3, timeout: 4)

        // compact preserving cache：大文件叶子应被释放 + Top N 回填到内部缓存。
        await coord.compactAfterScanPreservingCache(topN: 50)

        // 关键断言 1：largeFiles(...) 仍能同步返回大文件（走二级缓存）
        let items = coord.largeFiles(minSizeMB: 1, sortKey: .sizeDesc, limit: 50)
        XCTAssertGreaterThanOrEqual(items.count, 3,
                                    "compactAfterScanPreservingCache 后 largeFiles(...) 应同步返回 ≥3 个大文件")
        XCTAssertTrue(items.allSatisfy { $0.bytes >= 1024 * 1024 })

        // 关键断言 2：largeFileCollectedCount 走缓存 count（≥3，非 0）
        XCTAssertGreaterThanOrEqual(coord.largeFileCollectedCount, 3,
                                    "compact 后 largeFileCollectedCount 应回退到缓存 count，不应是 0")
    }

    /// M3 边界：topN=0 时退化为旧 compactAfterScan 行为（清主索引、不填缓存）。
    func test_compactAfterScanPreservingCache_topN0_等价于旧行为() async throws {
        let root = tempDir.appendingPathComponent("seed-topn0")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<3 {
            let url = root.appendingPathComponent("big\(i).bin")
            try Data(repeating: 0xCD, count: 2 * 1024 * 1024).write(to: url)
        }

        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store)
        coord.scan(category: makeCategory(rootPath: root.path),
                   includeHidden: true,
                   largeFileMinBytes: 1024 * 1024)
        await waitScanFinished(coord, timeout: 8)

        await coord.compactAfterScanPreservingCache(topN: 0)
        XCTAssertEqual(coord.largeFileCollectedCount, 0,
                       "topN=0 时不应填缓存，count 应为 0（行为与同步 compactAfterScan 一致）")
        XCTAssertEqual(coord.largeFiles(minSizeMB: 1, sortKey: .sizeDesc, limit: 50).count, 0)
    }

    /// M3 边界：未 finished 或 store nil 时 compactAfterScanPreservingCache 是 noop。
    func test_compactAfterScanPreservingCache_未finished或storeNil时是noop() async throws {
        // store nil
        let coord = ScanCoordinator()
        await coord.compactAfterScanPreservingCache()
        XCTAssertEqual(coord.largeFileCollectedCount, 0)

        // store 有但 isFinished=false
        let store = try makeStore()
        let coord2 = ScanCoordinator(resultStore: store)
        await coord2.compactAfterScanPreservingCache()
        XCTAssertEqual(coord2.largeFileCollectedCount, 0)
    }

    /// v1.3.z：deepIndex=off 时 directChildrenAsync 应通过 GRDB 拿到子项。
    /// 这是 TreeBrowserView 在性能模式下仍能下钻的契约。
    func test_directChildrenAsync_deepIndexOff时走store能查到子目录() async throws {
        let store = try makeStore()
        // deepIndex 关闭 —— 内存里 childEdges/dirIndex/fileLeaves 都是空。
        let coord = ScanCoordinator(resultStore: store, enableTreeDeepIndex: false)

        let root = tempDir.appendingPathComponent("dca-\(UUID().uuidString)")
        let subA = root.appendingPathComponent("subA")
        let subB = root.appendingPathComponent("subB")
        try seedFiles(in: subA, count: 3, bytesEach: 4096)
        try seedFiles(in: subB, count: 2, bytesEach: 1024)

        let cat = ScanCategory(id: "t.dca", title: "", subtitle: "",
                               rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitScanFinished(coord)
        guard let sid = coord.currentSessionID else {
            return XCTFail("currentSessionID 不应为 nil")
        }
        try await waitStoreSettled(store: store, sid: sid)

        // 内存里没有 childEdges（deepIndex 关），同步 directChildren 必返空。
        XCTAssertTrue(coord.directChildren(of: root.path).isEmpty,
                      "deepIndex=off 时同步 API 必空（内存索引未构建）")

        // async 版本应通过 store 查回 subA/subB。
        let kids = await coord.directChildrenAsync(of: root.path, sortedBy: .sizeDesc)
        let names = Set(kids.map(\.title))
        XCTAssertTrue(names.contains("subA"), "store fallback 应返回 subA")
        XCTAssertTrue(names.contains("subB"), "store fallback 应返回 subB")
        // sizeDesc 排序：subA (3*4K=12K) 应该排在 subB (2*1K=2K) 之前；
        // 但 store 路径下我们只取直接子项的 allocatedSize，不聚合后代，所以
        // 这里的字节数仅是单条目录 inode 的 allocatedSize（通常 0 或 4K），
        // 顺序不一定按聚合 size 排——只断言两个都在即可。
        XCTAssertEqual(kids.count, 2, "顶层应恰好两个子目录")
    }

    /// v1.3.z：directChildrenAsync 在 store nil 且内存索引为空时返回 [].
    func test_directChildrenAsync_storeNil且无内存索引返回空() async throws {
        let coord = ScanCoordinator(enableTreeDeepIndex: false)
        let kids = await coord.directChildrenAsync(of: "/nonexistent",
                                                   sortedBy: .sizeDesc)
        XCTAssertTrue(kids.isEmpty)
    }

    /// v1.3.z：同步 directChildren 在 deepIndex=off + store 命中时，
    /// 首次返空启 Task，第二次（足够等待后）应返回 store fallback 结果。
    /// 这是 TreeBrowserView "同步表面 + 后台填充"双层缓存的核心契约。
    func test_directChildrenSync_deepIndexOff_首次返空后cache命中() async throws {
        let store = try makeStore()
        let coord = ScanCoordinator(resultStore: store, enableTreeDeepIndex: false)

        let root = tempDir.appendingPathComponent("dcs-\(UUID().uuidString)")
        let subA = root.appendingPathComponent("subA")
        try seedFiles(in: subA, count: 2, bytesEach: 1024)

        let cat = ScanCategory(id: "t.dcs", title: "", subtitle: "",
                               rootPath: root.path, defaultVerdict: .safe)
        coord.scan(category: cat)
        await waitScanFinished(coord)
        guard let sid = coord.currentSessionID else {
            return XCTFail("currentSessionID 不应为 nil")
        }
        try await waitStoreSettled(store: store, sid: sid)

        // 首次同步调用：内存空 + cache 空 → 返 []，且后台启 Task。
        let firstShot = coord.directChildren(of: root.path, sortedBy: .sizeDesc)
        XCTAssertTrue(firstShot.isEmpty, "首次 cache miss 同步返空")

        // 等后台 Task 把 store 查询结果写回 cache（最多 1.5s）。
        let deadline = Date().addingTimeInterval(1.5)
        var cached: [TreeRow] = []
        while Date() < deadline {
            cached = coord.directChildren(of: root.path, sortedBy: .sizeDesc)
            if !cached.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(cached.isEmpty, "后台 fetch 完成后同步调用应返回 cache 命中结果")
        XCTAssertTrue(cached.contains(where: { $0.title == "subA" }),
                      "cache 命中结果应包含子目录 subA")
    }
}
