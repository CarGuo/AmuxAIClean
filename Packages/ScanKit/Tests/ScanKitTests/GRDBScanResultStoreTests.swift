import XCTest
@testable import ScanKit

final class GRDBScanResultStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScanResultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("scan.sqlite")
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeRecord(
        sessionID: ScanSessionID,
        path: String,
        size: Int64,
        isDir: Bool = false,
        parent: String? = nil
    ) -> ScanResultRecord {
        ScanResultRecord(
            sessionID: sessionID,
            path: path,
            isDirectory: isDir,
            isSymlink: false,
            allocatedSize: size,
            logicalSize: size,
            inode: 0,
            device: 0,
            modificationDate: nil,
            parentPath: parent
        )
    }

    func test_数据库目录被自动创建() async throws {
        let nested = tempDir.appendingPathComponent("a/b/c/scan.sqlite")
        let store = try GRDBScanResultStore(databaseURL: nested)
        let session = ScanSessionID()
        try await store.beginSession(session)
        let agg = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(agg, .empty)
    }

    func test_批量插入与查询返回顺序按字节降序() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)

        try await store.insert([
            makeRecord(sessionID: session, path: "/a", size: 100, parent: "/"),
            makeRecord(sessionID: session, path: "/b", size: 300, parent: "/"),
            makeRecord(sessionID: session, path: "/c", size: 200, parent: "/")
        ])
        try await store.finalizeSession(session)

        let q = ScanResultQuery(sessionID: session, parentPath: "/", limit: 10)
        let rows = try await store.query(q)
        XCTAssertEqual(rows.map(\.path), ["/b", "/c", "/a"])
    }

    func test_aggregate_汇总字节数与条目数() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/a", size: 10, parent: "/p"),
            makeRecord(sessionID: session, path: "/b", size: 20, parent: "/p"),
            makeRecord(sessionID: session, path: "/c", size: 5, parent: "/q")
        ])

        let p = try await store.aggregate(sessionID: session, parentPath: "/p")
        XCTAssertEqual(p.totalCount, 2)
        XCTAssertEqual(p.totalAllocatedBytes, 30)

        let all = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(all.totalCount, 3)
        XCTAssertEqual(all.totalAllocatedBytes, 35)
    }

    func test_evictSession_删除指定会话且不影响其他会话() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let s1 = ScanSessionID()
        let s2 = ScanSessionID()
        try await store.beginSession(s1)
        try await store.beginSession(s2)
        try await store.insert([
            makeRecord(sessionID: s1, path: "/a", size: 10, parent: "/")
        ])
        try await store.insert([
            makeRecord(sessionID: s2, path: "/b", size: 20, parent: "/")
        ])

        try await store.evictSession(s1)

        let a1 = try await store.aggregate(sessionID: s1, parentPath: nil)
        XCTAssertEqual(a1, .empty)
        let a2 = try await store.aggregate(sessionID: s2, parentPath: nil)
        XCTAssertEqual(a2.totalCount, 1)
        XCTAssertEqual(a2.totalAllocatedBytes, 20)
    }

    func test_clearAll_清空所有会话() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let s1 = ScanSessionID()
        try await store.beginSession(s1)
        try await store.insert([
            makeRecord(sessionID: s1, path: "/a", size: 10, parent: "/")
        ])
        try await store.clearAll()
        let agg = try await store.aggregate(sessionID: s1, parentPath: nil)
        XCTAssertEqual(agg, .empty)
    }

    func test_beginSession_重复开启会清空旧数据() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/a", size: 10, parent: "/")
        ])
        try await store.beginSession(session)
        let agg = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(agg, .empty)
    }

    func test_inode_device_使用UInt64极值能正确往返() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        let extremeInode = UInt64.max - 1
        let extremeDevice = UInt64(Int64.max) + 1
        let rec = ScanResultRecord(
            sessionID: session,
            path: "/extreme",
            isDirectory: false,
            isSymlink: false,
            allocatedSize: 1,
            logicalSize: 1,
            inode: extremeInode,
            device: extremeDevice,
            modificationDate: nil,
            parentPath: "/"
        )
        try await store.insert([rec])

        let rows = try await store.query(
            ScanResultQuery(sessionID: session, parentPath: "/", limit: 10)
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inode, extremeInode)
        XCTAssertEqual(rows[0].device, extremeDevice)
    }

    func test_query_pathPrefix_前缀过滤() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/Users/a/foo.txt", size: 1, parent: "/Users/a"),
            makeRecord(sessionID: session, path: "/Users/a/bar.txt", size: 2, parent: "/Users/a"),
            makeRecord(sessionID: session, path: "/etc/hosts", size: 3, parent: "/etc")
        ])

        let rows = try await store.query(
            ScanResultQuery(sessionID: session, pathPrefix: "/Users/a", limit: 10)
        )
        XCTAssertEqual(Set(rows.map(\.path)), Set(["/Users/a/foo.txt", "/Users/a/bar.txt"]))
    }

    func test_query_onlyFiles_仅文件() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/d", size: 0, isDir: true, parent: "/"),
            makeRecord(sessionID: session, path: "/f", size: 1, isDir: false, parent: "/")
        ])
        let rows = try await store.query(
            ScanResultQuery(sessionID: session, parentPath: "/", onlyFiles: true, limit: 10)
        )
        XCTAssertEqual(rows.map(\.path), ["/f"])
    }

    // MARK: - 协议补强（M1 review 必补）

    /// `insert` 空数组应当 no-op：不抛错、不影响 aggregate。
    /// `flushStoreBatch` 在调用前已经 guard 了非空，但协议契约层也必须保证。
    func test_insert_空数组不抛错且不影响aggregate() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([])
        let agg = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(agg, .empty)
    }

    /// finalize 之后再 insert：当前 GRDB 实现允许追加（外键不绑定 finalized 状态）。
    /// 这条用例固化该语义，防止后续把 finalize 改成"封档"行为时静默打破 ScanCoordinator
    /// 的 detached flush+finalize 顺序假设。
    func test_finalizeSession_后再insert仍能追加() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/a", size: 10, parent: "/")
        ])
        try await store.finalizeSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/late", size: 20, parent: "/")
        ])
        let agg = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(agg.totalCount, 2)
        XCTAssertEqual(agg.totalAllocatedBytes, 30)
    }

    /// 同一 session 内同一 path 重复 insert：当前实现是"追加多行"（rowid 自增）。
    /// 这条用例固化该语义，避免后续误改成"upsert"打破 ingest 的并发去重假设。
    func test_insert_同session同path重复写入会追加多行() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/dup", size: 10, parent: "/")
        ])
        try await store.insert([
            makeRecord(sessionID: session, path: "/dup", size: 10, parent: "/")
        ])
        let agg = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(agg.totalCount, 2, "重复 path 应追加多行而非 upsert")
        XCTAssertEqual(agg.totalAllocatedBytes, 20)
    }

    /// 跨 session 隔离：sessionA 的 query 不能命中 sessionB 的 row。
    func test_query_跨session隔离() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let s1 = ScanSessionID()
        let s2 = ScanSessionID()
        try await store.beginSession(s1)
        try await store.beginSession(s2)
        try await store.insert([
            makeRecord(sessionID: s1, path: "/in-s1", size: 1, parent: "/")
        ])
        try await store.insert([
            makeRecord(sessionID: s2, path: "/in-s2", size: 2, parent: "/")
        ])
        let rows1 = try await store.query(
            ScanResultQuery(sessionID: s1, limit: 10)
        )
        let rows2 = try await store.query(
            ScanResultQuery(sessionID: s2, limit: 10)
        )
        XCTAssertEqual(rows1.map(\.path), ["/in-s1"])
        XCTAssertEqual(rows2.map(\.path), ["/in-s2"])
    }

    /// `Sort.modificationDateDescending` 应按 mtime 降序，nil 排到末尾或开头都可，
    /// 但相对顺序必须稳定且非 nil 的全部按 mtime desc。
    func test_query_排序_modificationDateDescending() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        let now = Date()
        let recOld = ScanResultRecord(
            sessionID: session, path: "/old", isDirectory: false, isSymlink: false,
            allocatedSize: 1, logicalSize: 1, inode: 0, device: 0,
            modificationDate: now.addingTimeInterval(-3600), parentPath: "/"
        )
        let recNew = ScanResultRecord(
            sessionID: session, path: "/new", isDirectory: false, isSymlink: false,
            allocatedSize: 1, logicalSize: 1, inode: 0, device: 0,
            modificationDate: now, parentPath: "/"
        )
        try await store.insert([recOld, recNew])
        let rows = try await store.query(
            ScanResultQuery(sessionID: session, limit: 10,
                            sort: .modificationDateDescending)
        )
        let pathsWithMtime = rows.compactMap { $0.modificationDate != nil ? $0.path : nil }
        XCTAssertEqual(pathsWithMtime, ["/new", "/old"])
    }

    /// `Sort.pathAscending` 应按路径字典序升序。
    func test_query_排序_pathAscending() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        try await store.insert([
            makeRecord(sessionID: session, path: "/c", size: 1, parent: "/"),
            makeRecord(sessionID: session, path: "/a", size: 1, parent: "/"),
            makeRecord(sessionID: session, path: "/b", size: 1, parent: "/")
        ])
        let rows = try await store.query(
            ScanResultQuery(sessionID: session, limit: 10, sort: .pathAscending)
        )
        XCTAssertEqual(rows.map(\.path), ["/a", "/b", "/c"])
    }

    /// `offset + limit` 分页：第一页 + 第二页拼起来等于全集，且无重复。
    func test_query_offset与limit组合分页() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        // 5 条按 alloc 降序 5,4,3,2,1
        try await store.insert((1...5).map {
            makeRecord(sessionID: session,
                       path: "/p\($0)",
                       size: Int64($0),
                       parent: "/")
        })
        let page1 = try await store.query(
            ScanResultQuery(sessionID: session, limit: 2, offset: 0)
        )
        let page2 = try await store.query(
            ScanResultQuery(sessionID: session, limit: 2, offset: 2)
        )
        XCTAssertEqual(page1.map(\.allocatedSize), [5, 4])
        XCTAssertEqual(page2.map(\.allocatedSize), [3, 2])
    }

    /// `aggregate` 必须对 `totalLogicalBytes` 与 `totalAllocatedBytes` 独立汇总，
    /// 防止后续误把某一列拷成两份导致数字一致幻觉。
    func test_aggregate_logical与allocated独立汇总() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let session = ScanSessionID()
        try await store.beginSession(session)
        let rec = ScanResultRecord(
            sessionID: session, path: "/x", isDirectory: false, isSymlink: false,
            allocatedSize: 4096, logicalSize: 100,
            inode: 0, device: 0, modificationDate: nil, parentPath: "/"
        )
        try await store.insert([rec])
        let agg = try await store.aggregate(sessionID: session, parentPath: nil)
        XCTAssertEqual(agg.totalCount, 1)
        XCTAssertEqual(agg.totalAllocatedBytes, 4096)
        XCTAssertEqual(agg.totalLogicalBytes, 100,
                       "logical 与 allocated 必须独立汇总，不允许任一列被拷贝顶替")
    }

    /// `evictSession` 对不存在的 sessionID 不能抛错（防御式契约）。
    func test_evictSession_不存在的sid不抛错() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let ghost = ScanSessionID()
        try await store.evictSession(ghost) // 不抛
        let agg = try await store.aggregate(sessionID: ghost, parentPath: nil)
        XCTAssertEqual(agg, .empty)
    }

    /// P0-A 回归：foreign_keys 必须开，evictSession 删 scan_session 后
    /// 子表 scan_result 的对应行必须级联清空（不能留孤儿）。
    /// 修复前因 SQLite 默认 foreign_keys=OFF，子表会留下永久孤儿。
    func test_evictSession_级联删除scan_result_无孤儿() async throws {
        let store = try GRDBScanResultStore(databaseURL: dbURL)
        let s1 = ScanSessionID()
        let s2 = ScanSessionID()
        try await store.beginSession(s1)
        try await store.beginSession(s2)
        try await store.insert([
            makeRecord(sessionID: s1, path: "/x", size: 100),
            makeRecord(sessionID: s1, path: "/y", size: 200),
            makeRecord(sessionID: s2, path: "/z", size: 300),
        ])
        // 修复前：evict s1 后 raw 仍是 3（孤儿 /x、/y）
        // 修复后：raw 应该等于 1（仅剩 s2 的 /z）
        try await store.evictSession(s1)
        let raw = try await store._debugRawScanResultCount()
        XCTAssertEqual(raw, 1, "evictSession 必须级联删 scan_result，否则子表留孤儿")

        // s2 应仍可正常查询
        let agg2 = try await store.aggregate(sessionID: s2, parentPath: nil)
        XCTAssertEqual(agg2.totalCount, 1)
        XCTAssertEqual(agg2.totalAllocatedBytes, 300)

        // s1 已经看不到了
        let agg1 = try await store.aggregate(sessionID: s1, parentPath: nil)
        XCTAssertEqual(agg1, .empty)
    }
}
