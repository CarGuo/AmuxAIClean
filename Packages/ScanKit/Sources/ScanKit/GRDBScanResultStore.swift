import Foundation
import GRDB
import LogKit

/// SQLite 存储描述快照（UI 设置面板用）。
public struct ScanStoreDescription: Sendable, Equatable {
    /// 主 db 文件 URL（.sqlite）。
    public let databaseURL: URL
    /// .sqlite + -wal + -shm 三个文件的总字节数。
    public let totalSizeBytes: Int64
    /// scan_session 表的 row 数。
    public let sessionCount: Int
    /// scan_result 表的 row 数。
    public let resultRowCount: Int

    public init(databaseURL: URL, totalSizeBytes: Int64, sessionCount: Int, resultRowCount: Int) {
        self.databaseURL = databaseURL
        self.totalSizeBytes = totalSizeBytes
        self.sessionCount = sessionCount
        self.resultRowCount = resultRowCount
    }
}

public actor GRDBScanResultStore: ScanResultStore {
    public enum StoreError: Error, Sendable, Equatable {
        case cannotResolveStoreDirectory
        /// `pruneOldSessions(keepLatest:)` 收到 `<= 0` 入参——拒绝执行。
        /// "全清"语义请走 [clearAll()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift)，避免与"保留 N 个"API 共用同一入口造成误删。
        case refuseDestructivePrune
    }

    /// 默认保留最新 session 数。竞品多数是 in-memory（DaisyDisk / GP / ODS），
    /// 我们持久化的本意是"上次扫完关掉，下次开应用秒开"，3 个 session 足够覆盖
    /// 该体验，且单 session 平均 ~300k 行 × 285 B/行 ≈ 86 MB，3 个 = 258 MB，
    /// 配合 incremental_vacuum 稳态可控。
    public static let defaultKeepLatestSessions: Int = 3

    private let dbPool: DatabasePool
    private let location: URL
    /// 单次 finalize 自动 prune 的保留 session 数。
    ///
    /// - `> 0`：finalize 末尾自动 `pruneOldSessions(keepLatest: keepLatestSessions + 1)`
    ///   （+1 cushion 是为了保护"刚 finalize 完但 UI 仍在浏览上一轮结果"的 session 不被 race 删掉，
    ///   详见 [finalizeSession()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 注释）。
    /// - `<= 0`：禁用 finalize 自动 prune（**仅测试用**）。生产构造一律走 [defaultKeepLatestSessions](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 默认值。
    ///   注意：这与公共方法 [pruneOldSessions(keepLatest:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 的入参语义**不同**——
    ///   后者 `<= 0` 是显式错误（throw `StoreError.refuseDestructivePrune`），避免误删。
    private let keepLatestSessions: Int

    public init(
        databaseURL: URL,
        keepLatestSessions: Int = GRDBScanResultStore.defaultKeepLatestSessions
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // **DB 体积治理**：auto_vacuum 必须在**首次建库**前设置才生效（SQLite 硬约束，
        // 后期 PRAGMA 只对新库生效，对老库要 VACUUM 整库重写才能改 auto_vacuum 模式）。
        // 这里在 DatabasePool 打开之前判断文件是否存在：不存在 → 新库 → 之后设
        // auto_vacuum=INCREMENTAL；已存在 → 老库 → 跳过（避免无效 PRAGMA 制造误解），
        // 用户可在「设置 → 存储与日志」走 clearAll / deleteDatabaseFiles 来 reset 拿到新模式。
        let isFreshDatabase = !FileManager.default.fileExists(atPath: databaseURL.path)
        var config = Configuration()
        config.prepareDatabase { db in
            // P0-A 修复：SQLite 默认 foreign_keys = OFF，导致 scan_result 表
            // 上的 ON DELETE CASCADE 不会真的级联——evictSession / clearAll
            // 删 scan_session 行时会留下孤儿 scan_result，长期累积污染查询。
            // 必须每次连接都显式开启（per-connection 状态，prepareDatabase 是
            // GRDB 推荐挂点，DatabasePool 中每条 reader/writer 都会执行）。
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            // **注意**：auto_vacuum 不能放这里。prepareDatabase 对**所有**连接执行，
            // 包括只读 reader 连接；只读连接跑 `PRAGMA auto_vacuum = INCREMENTAL`
            // 会抛 SQLite error 8（attempt to write a readonly database）。
            // 改在 init 末尾用 writer 显式设一次（仅新库）。
        }
        do {
            self.dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
        } catch {
            GSYLog.error(.db, "DatabasePool 打开失败 path=\(databaseURL.path) err=\(error)")
            throw error
        }
        self.location = databaseURL
        self.keepLatestSessions = keepLatestSessions
        // 新库首次打开后立刻设 auto_vacuum=INCREMENTAL：必须在任何表创建前 + 必须
        // 在 writer 连接上跑。设完会自动落盘到 sqlite header 的 auto_vacuum 字段，
        // 之后所有连接（reader / writer）读到的都是该值，无需重复 PRAGMA。
        // 删行后页面进 freelist，可以走 [vacuum()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 的 incremental_vacuum 路径
        // 把页归还 OS，避免整库 VACUUM 需要 1× 库大小临时空间的灾难。
        if isFreshDatabase {
            do {
                try self.dbPool.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                    // SQLite 文档要求：设完 auto_vacuum 之后必须 VACUUM 一次才能让该
                    // 模式真正生效（即便是空库也要这一步）。空库 VACUUM 几乎零成本。
                    try db.execute(sql: "VACUUM")
                }
            } catch {
                // 设失败不致命：库仍可用，只是 vacuum() 会退化到整库重写路径。
                GSYLog.warning(.db, "设置 auto_vacuum=INCREMENTAL 失败（已退化为 NONE 模式）：\(error)")
            }
        }
        do {
            try Self.migrator.migrate(self.dbPool)
        } catch {
            GSYLog.error(.db, "迁移失败 path=\(databaseURL.path) err=\(error)")
            throw error
        }
        GSYLog.info(.db, "GRDBScanResultStore 已就绪 path=\(databaseURL.path) keepLatest=\(keepLatestSessions)")
    }

    public static func defaultDatabaseURL(
        bundleIdentifier: String = "GSYCleanMac",
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.cannotResolveStoreDirectory
        }
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("scan.sqlite", isDirectory: false)
    }

    public var databaseURL: URL { location }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_create_scan_results") { db in
            try db.create(table: "scan_session") { t in
                t.primaryKey("id", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("finalized_at", .double)
            }
            try db.create(table: "scan_result") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("session_id", .text).notNull().indexed()
                    .references("scan_session", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("parent_path", .text).indexed()
                t.column("is_directory", .integer).notNull()
                t.column("is_symlink", .integer).notNull()
                t.column("allocated_size", .integer).notNull()
                t.column("logical_size", .integer).notNull()
                t.column("inode", .integer).notNull()
                t.column("device", .integer).notNull()
                t.column("modification_date", .double)
            }
            try db.create(
                index: "scan_result_session_alloc_idx",
                on: "scan_result",
                columns: ["session_id", "allocated_size"]
            )
        }
        // v1.3.z：TreeBrowserView 在 deepIndex=off + store-only 模式下，需要按
        // "path LIKE 'parent/%'" 做子树 SUM/COUNT，否则一级目录在树视图全显示 0KB。
        // 给 (session_id, path) 加复合索引，让 LIKE 前缀匹配能走 range scan，
        // 避免 22 个目录 × 70w 全表扫的 O(N²) 灾难。
        m.registerMigration("v2_scan_result_path_index") { db in
            try db.create(
                index: "scan_result_session_path_idx",
                on: "scan_result",
                columns: ["session_id", "path"]
            )
        }
        // v3：DROP `scan_result_on_parent_path` 单列索引。
        //
        // **背景**：v1 schema 在 `parent_path` 列声明 `.indexed()`，GRDB 自动建索引
        // `scan_result_on_parent_path`。这条索引按 path 字符串排序（avg 113 B/key），
        // 在 1490 万行规模下贡献 ~1.5 GB on-disk。
        //
        // **为什么可删**：
        //   - "按 parent 列子项" 的查询只在 [query()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 的 `parent_path = ?`
        //     分支，且 WHERE 总带 `session_id = ?`；
        //   - v2 的 `scan_result_session_path_idx (session_id, path)` 已能服务该 query
        //     （SQLite 优化器选这条复合索引做 range scan，本来就比单列索引更高效）；
        //   - [directChildrenAggregated()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L279) 走的也是
        //     `(session_id, path)` 范围扫，不依赖 parent_path 索引。
        //
        // 等价地，老库升级到 v3 不会丢失任何 query 能力，只释放磁盘 ~10%。
        m.registerMigration("v3_drop_redundant_parent_path_index") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS scan_result_on_parent_path")
        }
        return m
    }

    public func beginSession(_ id: ScanSessionID) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO scan_session (id, created_at, finalized_at) VALUES (?, ?, NULL)",
                arguments: [id.raw, Date().timeIntervalSince1970]
            )
            try db.execute(
                sql: "DELETE FROM scan_result WHERE session_id = ?",
                arguments: [id.raw]
            )
        }
    }

    /// 批量写入。
    ///
    /// **事务边界（v1.3.zzzz Phase 3-B 文档化）**：GRDB 的 `dbPool.write { ... }`
    /// 闭包**整体**包在一个 SQLite 事务里——一次 `insert(records)` 调用 = 一次
    /// `BEGIN ... COMMIT` + 一次 WAL flush。所以"分批 N 次小 insert"=N 次事务，
    /// 调用方（如 [PerfBench.runDirectChildrenBench](file:///Users/guoshuyu/workspace/GSYCleanMac/Tools/PerfBench/Sources/PerfBench/PerfBench.swift#L124)）
    /// 想要单事务大批量灌就一次性传完整数组，想要分摊内存峰值就自行切片调用。
    /// 不要把"事务"误以为只是 stmt 复用——prepared stmt 是独立优化，事务由 closure 边界决定。
    public func insert(_ records: [ScanResultRecord]) async throws {
        guard !records.isEmpty else { return }
        try await dbPool.write { db in
            let stmt = try db.makeStatement(sql: """
                INSERT INTO scan_result
                    (session_id, path, parent_path, is_directory, is_symlink,
                     allocated_size, logical_size, inode, device, modification_date)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for record in records {
                stmt.setUncheckedArguments([
                    record.sessionID.raw,
                    record.path,
                    record.parentPath,
                    record.isDirectory ? 1 : 0,
                    record.isSymlink ? 1 : 0,
                    record.allocatedSize,
                    record.logicalSize,
                    Int64(bitPattern: record.inode),
                    Int64(bitPattern: record.device),
                    record.modificationDate?.timeIntervalSince1970
                ])
                try stmt.execute()
            }
        }
    }

    public func finalizeSession(_ id: ScanSessionID) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE scan_session SET finalized_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id.raw]
            )
        }
        // **DB 体积治理**：finalize 完一个 session 之后立刻 prune 旧 session。
        // 这是把"无界增长"扼杀在最早期的关键挂点——之前 89 个 session / 1490 万行
        // / 11 GB 的灾难根因正是这里缺失。
        //
        // **+1 cushion**（修 race）：实际保留 keepLatestSessions + 1 个 session。
        // 场景：用户在主窗口扫完 A（持有 sid=A 渲染树视图）→ 又连点 keepLatest 次
        // 扫描 B/C/D…，最后一次 finalize 时若用 keepLatest 直切，A 会被静默清掉，
        // 而 LargeFilesView 异步 query 返回 [] → 视图突然变空。+1 cushion 在 finalize
        // 自动路径保留"上一轮可能仍在被 view 持有"的 session；UI 显式 prune
        // 走 [pruneOldSessions(keepLatest:)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 仍按精确值。
        //
        // 容错：prune 失败不影响 finalize 语义（只是磁盘多占点空间），日志记录即可，
        // 绝不向调用方抛——finalize 是用户感知的"扫描完成"语义，不能因为后台清理失败
        // 让用户看到错误。
        if keepLatestSessions > 0 {
            do {
                try await pruneOldSessions(keepLatest: keepLatestSessions + 1)
            } catch {
                GSYLog.error(.db, "finalize 自动 prune 失败 id=\(id.raw) err=\(error)")
            }
        }
    }

    /// **DB 体积治理核心方法**：按 `COALESCE(finalized_at, created_at)` 降序保留最新 N 个 session，
    /// 其余删除（ON DELETE CASCADE 自动级联清掉 scan_result 行）。
    ///
    /// 调用时机：
    ///   1. 每次 [finalizeSession()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 完成后自动调（keepLatestSessions > 0 时）
    ///   2. UI 在「设置 → 存储与日志」也可以显式触发（带回收空间提示）
    ///
    /// 配合 PRAGMA auto_vacuum=INCREMENTAL：删行后页面进 freelist，下次
    /// [vacuum()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 走
    /// `PRAGMA incremental_vacuum` 路径释放给 OS。**不**走整库 VACUUM，避免
    /// 11G 库需要 11G 临时空间这种磁盘灾难（详见 [docs/regression/2026_06_11/db_size.md](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/db_size.md)）。
    ///
    /// - Parameter keepLatest: 保留最新 N 个 session。**必须 > 0**，
    ///   否则 throw `StoreError.refuseDestructivePrune`（"全清"语义请走 [clearAll()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift)，
    ///   避免与"保留 N 个"API 共用同一入口造成误删）。
    /// - Returns: 实际删除的 session 行数。
    @discardableResult
    public func pruneOldSessions(keepLatest: Int) async throws -> Int {
        guard keepLatest > 0 else {
            // 拒绝破坏性入参：保留"保留 N 个最新"的纯粹语义，不再兼任"全清"。
            // 全清请显式走 [clearAll()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift)；测试若需禁用 finalize 自动 prune，
            // 在 init 时把 keepLatestSessions 传 0 即可（finalize 内部用 > 0 判断）。
            GSYLog.warning(.db, "pruneOldSessions 拒绝执行：keepLatest=\(keepLatest) <= 0；如需全清请走 clearAll()")
            throw StoreError.refuseDestructivePrune
        }
        let deleted = try await dbPool.write { db -> Int in
            // 用子查询保留最新 keepLatest 个 session id，其余删。
            // ORDER BY COALESCE(finalized_at, created_at) DESC, id DESC：
            //   - 主排序键：finalize 过的按 finalize 时间；未 finalize（异常残留）按 created_at 兜底。
            //   - **tiebreaker `id DESC`**：同毫秒批量 finalize / 时钟回退 / NULL 等场景下
            //     SQLite 对相等键的相对顺序未定义，会导致同样的库两次 prune 得到不同"保留集"，
            //     甚至误删本应保留的最新 session。id 是 UUID TEXT，作为稳定 tiebreaker 足够。
            // LIMIT/OFFSET 比 NOT IN 更利于 SQLite 走 scan_session 主键扫，
            // 但 IN 表达式更直观；scan_session 行数永远 < 1000 级别，差异可忽略。
            try db.execute(
                sql: """
                    DELETE FROM scan_session
                    WHERE id NOT IN (
                        SELECT id FROM scan_session
                        ORDER BY COALESCE(finalized_at, created_at) DESC, id DESC
                        LIMIT ?
                    )
                    """,
                arguments: [keepLatest]
            )
            return db.changesCount
        }
        if deleted > 0 {
            GSYLog.info(.db, "pruneOldSessions keepLatest=\(keepLatest) 删除=\(deleted) session")
            // 主动 wal_checkpoint(TRUNCATE) 把 WAL 清空，让 incremental_vacuum
            // 立刻能把 freelist 页归还 OS（否则 freelist 页一直被 WAL 持有的快照引用）。
            try await dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        return deleted
    }

    public func query(_ q: ScanResultQuery) async throws -> [ScanResultRecord] {
        try await dbPool.read { db in
            var conditions: [String] = ["session_id = ?"]
            var args: [DatabaseValueConvertible?] = [q.sessionID.raw]
            if let parent = q.parentPath {
                conditions.append("parent_path = ?")
                args.append(parent)
            }
            if let prefix = q.pathPrefix {
                conditions.append("path LIKE ?")
                args.append(prefix + "%")
            }
            if q.onlyFiles {
                conditions.append("is_directory = 0")
            }
            let order: String
            switch q.sort {
            case .allocatedSizeDescending: order = "allocated_size DESC, rowid ASC"
            case .modificationDateDescending: order = "modification_date DESC NULLS LAST, rowid ASC"
            case .pathAscending: order = "path ASC"
            }
            var sql = """
                SELECT path, parent_path, is_directory, is_symlink,
                       allocated_size, logical_size, inode, device, modification_date
                FROM scan_result
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(order)
                """
            if let limit = q.limit {
                sql += " LIMIT \(limit) OFFSET \(q.offset)"
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                let modTs: Double? = row["modification_date"]
                let inode: Int64 = row["inode"]
                let device: Int64 = row["device"]
                return ScanResultRecord(
                    sessionID: q.sessionID,
                    path: row["path"],
                    isDirectory: (row["is_directory"] as Int) != 0,
                    isSymlink: (row["is_symlink"] as Int) != 0,
                    allocatedSize: row["allocated_size"],
                    logicalSize: row["logical_size"],
                    inode: UInt64(bitPattern: inode),
                    device: UInt64(bitPattern: device),
                    modificationDate: modTs.map { Date(timeIntervalSince1970: $0) },
                    parentPath: row["parent_path"]
                )
            }
        }
    }

    public func aggregate(
        sessionID: ScanSessionID,
        parentPath: String?
    ) async throws -> ScanResultAggregate {
        try await dbPool.read { db in
            var sql = """
                SELECT COUNT(*) AS cnt,
                       COALESCE(SUM(allocated_size), 0) AS alloc,
                       COALESCE(SUM(logical_size), 0) AS logi
                FROM scan_result
                WHERE session_id = ?
                """
            var args: [DatabaseValueConvertible?] = [sessionID.raw]
            if let parent = parentPath {
                sql += " AND parent_path = ?"
                args.append(parent)
            }
            guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) else {
                return ScanResultAggregate.empty
            }
            return ScanResultAggregate(
                totalCount: row["cnt"],
                totalAllocatedBytes: row["alloc"],
                totalLogicalBytes: row["logi"]
            )
        }
    }

    /// v1.3.zzzz：树形 Tab 展开 prefix 的"直接子项 + 每段子树聚合"——单条 SQL GROUP BY 实现。
    ///
    /// 对比旧版 [ScanCoordinator.directChildrenAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1045)
    /// 的"拉所有子孙 record + Swift Dictionary GROUP BY"路径（实测 ~Library/Caches 33w 条 ~100ms），
    /// 把整段聚合下推到 SQLite C 内层，预期降到 ~10ms 级，且不再把数据拉回 Swift 内存。
    ///
    /// 性能要点：
    /// 1) 用 `path >= lower AND path < upper` 的 range scan（不依赖 LIKE 优化器）：
    ///    lower = parentPath + "/"，upper = lower + "\u{10FFFF}" sentinel；
    ///    命中 `scan_result_session_path_idx` 复合索引做 range scan；
    /// 2) 用 `substr(path, prefixLen+1, ...)` 抽出 segment，prefixLen 在 Swift 侧算好
    ///    传入避免每行重复算（GROUP BY 表达式必须确定可比较）；
    /// 3) 用 `instr(suffix||'/', '/')` 找第一个分隔符位置（相当于 split first；
    ///    suffix 没有 '/' 的话末尾追加 '/' 让 instr 返回 length+1，统一处理）。
    ///
    /// 边界与"hasInode" 含义：record 中 path == prefix+seg 的那条就是 segment 自身的 inode
    /// （vendor bucket 模式或沙盒被拒目录可能没 inode，仅子孙 leaf 在）。SQL 用
    /// `MAX(CASE ... THEN 1 ELSE 0 END)` 折叠出来，实现成本几乎 0。
    public func directChildrenAggregated(
        sessionID: ScanSessionID,
        parentPath: String
    ) async throws -> [DirectChildAggregate] {
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let prefixLen = prefix.utf8.count
        let lower = prefix
        // sentinel：U+10FFFF 是 Unicode 最大码点，BINARY collation 下保证比所有合法子路径都大。
        let upper = prefix + "\u{10FFFF}"
        // SQLite substr 的 start 是 1-based。prefixLen 是 prefix 的 utf8 字节数；
        // path 是 UTF-8 编码 TEXT，substr(path, prefixLen+1) 即"prefix 之后的 suffix"。
        // 注意：所有用户路径在 macOS 下都是 UTF-8，且 substr 在 SQLite 里按字符切；
        // 由于我们在 ASCII '/' 边界切，UTF-8 多字节字符不会出现在分隔位置，所以
        // 字节长度 == 字符长度的假设在分段位置上成立（中文段名也安全）。
        // 安全做法：传入 length(prefix) 让 SQLite 在 SQL 层算字符长度更稳。
        // 这里用 length(?prefix) 子查询为 0 成本（常量），但 GRDB 不支持，改用绑定常量。
        let sql = """
            WITH children AS (
              SELECT
                CASE
                  WHEN instr(substr(path, ?+1) || '/', '/') = 0
                    THEN substr(path, ?+1)
                  ELSE substr(path, ?+1, instr(substr(path, ?+1) || '/', '/') - 1)
                END AS seg,
                path,
                is_directory,
                allocated_size,
                logical_size,
                modification_date
              FROM scan_result
              WHERE session_id = ?
                AND path >= ?
                AND path < ?
            )
            SELECT
              seg,
              SUM(allocated_size) AS bytes,
              SUM(logical_size) AS logical_bytes,
              COUNT(*) AS cnt,
              MAX(CASE WHEN path = ? || seg THEN 1 ELSE 0 END) AS has_inode,
              MAX(CASE WHEN path = ? || seg AND is_directory = 1 THEN 1 ELSE 0 END) AS dir_inode,
              SUM(CASE WHEN is_directory = 0 THEN 1 ELSE 0 END) AS file_cnt,
              SUM(CASE WHEN is_directory = 0 THEN allocated_size ELSE 0 END) AS file_bytes,
              -- v1.5.4：取该 segment 自身 inode 行的 mtime（**非** max 子孙），与 Finder 语义一致。
              -- hasInode=false（vendor bucket / 沙盒被拒）则该聚合值为 NULL。
              MAX(CASE WHEN path = ? || seg THEN modification_date ELSE NULL END) AS inode_mtime
            FROM children
            WHERE seg <> ''
            GROUP BY seg
            ORDER BY bytes DESC
            """
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [
                    prefixLen, prefixLen, prefixLen, prefixLen,
                    sessionID.raw, lower, upper,
                    prefix, prefix, prefix
                ]
            )
            return rows.map { row in
                let hasInode = (row["has_inode"] as Int) != 0
                let dirInode = (row["dir_inode"] as Int) != 0
                let cnt: Int = row["cnt"]
                let fileCnt: Int = row["file_cnt"]
                // hasInode=true 时听 inode 自己的；否则只要 cnt > 1 或没文件 leaf 就当目录
                let isDir: Bool = hasInode ? dirInode : (cnt > 1 || fileCnt == 0)
                let inodeMtimeTs: Double? = row["inode_mtime"]
                let inodeMtime: Date? = inodeMtimeTs.map { Date(timeIntervalSince1970: $0) }
                return DirectChildAggregate(
                    segment: row["seg"],
                    isDirectory: isDir,
                    hasInode: hasInode,
                    descendantCount: cnt,
                    descendantBytes: row["bytes"],
                    descendantLogicalBytes: row["logical_bytes"],
                    fileDescendantCount: fileCnt,
                    fileDescendantBytes: row["file_bytes"],
                    inodeModificationDate: inodeMtime
                )
            }
        }
    }

    public func evictSession(_ id: ScanSessionID) async throws {
        GSYLog.info(.db, "evictSession 开始 id=\(id.raw)")
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM scan_session WHERE id = ?",
                arguments: [id.raw]
            )
        }
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        GSYLog.info(.db, "evictSession 完成 id=\(id.raw)")
    }

    /// **v1.5.3**：按路径精确 + 前缀剧除该 session 中的 scan_result 行。
    ///
    /// 解决"删除完后页面 dim 重渲染又把已删项拉回来"的死循环：
    /// [ScanCoordinator.directChildren](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1048)
    /// 在内存索引 miss 时会走 store-fallback 异步读 GRDB；如果 store 还有那条记录，
    /// 它会原样写回 treeChildrenCache，UI 看到的就是"刚删完又冒出来"。
    ///
    /// SQL 上利用 `(session_id, path)` 复合索引（见 [migrator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L112)）：
    /// 单条 DELETE 既匹配 path = ? 自身行，也匹配 path LIKE ? || '/%' 整段子树，
    /// 等价于"删 prefix 这一棵子树"。批处理多条 path 时整体放进同一个事务，
    /// 避免每条触发一次 fsync。
    public func deletePaths(sessionID: ScanSessionID, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // 规范化：去掉末尾 `/`，让 LIKE 前缀比较稳定（"/A/B/" 与 "/A/B" 等价）
        let normalized: [String] = paths.map { p in
            (p.count > 1 && p.hasSuffix("/")) ? String(p.dropLast()) : p
        }
        GSYLog.info(.db, "deletePaths 开始 sid=\(sessionID.raw) count=\(normalized.count)")
        try await dbPool.write { db in
            for path in normalized {
                // 精确匹配 + 子树 LIKE 前缀。两条独立 DELETE 比 OR 一条更利于走索引。
                try db.execute(
                    sql: "DELETE FROM scan_result WHERE session_id = ? AND path = ?",
                    arguments: [sessionID.raw, path]
                )
                try db.execute(
                    sql: "DELETE FROM scan_result WHERE session_id = ? AND path LIKE ?",
                    arguments: [sessionID.raw, path + "/%"]
                )
            }
        }
        GSYLog.info(.db, "deletePaths 完成 sid=\(sessionID.raw)")
    }

    public func clearAll() async throws {
        GSYLog.notice(.db, "clearAll 开始 path=\(location.path)")
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM scan_session")
            try db.execute(sql: "DELETE FROM scan_result")
        }
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
        }
        GSYLog.notice(.db, "clearAll 完成（已 vacuum）")
    }

    /// v1.3.zzzz Phase 6：仅 vacuum，不动业务数据。用户在「设置 → 存储与日志」点击。
    /// 与 [clearAll](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift#L350) 的区别：clearAll 会先 truncate 再 vacuum，
    /// 这里只 vacuum 紧凑空间——给"想释放但不想丢扫描历史"的用户用。
    ///
    /// **2026-06-11 改造**：优先用 `PRAGMA incremental_vacuum`（auto_vacuum=INCREMENTAL
    /// 模式下零临时空间），只在老库（auto_vacuum=NONE）才退化到 `VACUUM` 整库重写。
    /// 这样 11G 库不会因为"想 vacuum 一下"瞬间需要 11G 临时空间而把磁盘打爆。
    public func vacuum() async throws {
        GSYLog.notice(.db, "vacuum 开始")
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        // 读 auto_vacuum 模式（0=NONE / 1=FULL / 2=INCREMENTAL），决定走哪条路径。
        let autoVacuumMode = try await dbPool.read { db -> Int in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
        }
        if autoVacuumMode == 2 {
            // INCREMENTAL：把 freelist 中所有空闲页归还 OS（参数 0 表示全部）。
            // 不需要临时空间，O(freelist_pages) 时间。
            try await dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA incremental_vacuum(0)")
                // incremental_vacuum 本身是写操作，会再生成 WAL。再 checkpoint 一次
                // 保证调用方测量 file size 时 WAL 已 truncate 到 0，避免 size
                // 数据失真（实测不补这一步，删空 + vacuum 后主库收缩 1 MB+ 但 WAL
                // 又涨回去 800 KB，呈现"vacuum 没生效"的假象）。
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            GSYLog.notice(.db, "vacuum 完成（incremental，零临时空间）")
        } else {
            // NONE / FULL 老库回退到 VACUUM。需要 ~1× 库大小临时空间。
            try await dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
            GSYLog.notice(.db, "vacuum 完成（VACUUM 整库重写，auto_vacuum=\(autoVacuumMode)）")
        }
    }

    /// v1.3.zzzz Phase 6：返回 DB 的体积/计数快照，给「设置 → 存储与日志」UI 用。
    /// 总字节数 = .sqlite + -wal + -shm 三个 sibling 文件之和。
    public func describeStorage() async throws -> ScanStoreDescription {
        let sessions = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_session") ?? 0
        }
        let rows = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_result") ?? 0
        }
        let total = Self.totalDatabaseFileBytes(at: location)
        return ScanStoreDescription(
            databaseURL: location,
            totalSizeBytes: total,
            sessionCount: sessions,
            resultRowCount: rows
        )
    }

    /// v1.3.zzzz Phase 6：返回 sqlite + -wal + -shm 三个文件的合计字节数。
    /// 任何一个不存在按 0 处理。这是个 nonisolated 静态方法，避免 actor hop。
    nonisolated public static func totalDatabaseFileBytes(at sqliteURL: URL) -> Int64 {
        let suffixes = ["", "-wal", "-shm"]
        var total: Int64 = 0
        for s in suffixes {
            let url = URL(fileURLWithPath: sqliteURL.path + s)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// 测试专用：返回 scan_result 表当前总行数（不按 session 过滤）。
    /// 用来验证 P0-A 修复后 ON DELETE CASCADE 真的级联清掉了子表行。
    /// 仅 internal，避免被生产代码误用。
    internal func _debugRawScanResultCount() async throws -> Int {
        try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_result") ?? 0
        }
    }

    /// 测试专用：返回当前 DB 的 `PRAGMA auto_vacuum` 值（0=NONE / 1=FULL / 2=INCREMENTAL）。
    /// 用来直接验证 init 时 `PRAGMA auto_vacuum=INCREMENTAL` 真的写入了 sqlite header——
    /// 否则只看"vacuum 后 file size 收缩"这种间接信号，纯 VACUUM 也能通过，
    /// 测试会在 INCREMENTAL 失效时仍然 pass，提供虚假信心。
    internal func _debugAutoVacuumMode() async throws -> Int {
        try await dbPool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
        }
    }
}

// MARK: - 文件级删除（破坏性最强）

extension GRDBScanResultStore {
    /// v1.3.zzzz Phase 6：从磁盘上**直接删除** sqlite 文件 + -wal + -shm。
    ///
    /// **使用前提**：
    /// 1. 调用方必须先释放对应的 [GRDBScanResultStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/GRDBScanResultStore.swift) 实例（否则 actor 仍持有 dbPool 句柄）
    /// 2. 调用后下次构造 store 会自动重建 schema（迁移机制兜底）
    ///
    /// 这是 nonisolated 静态方法：因为 actor 实例本身就要被销毁，没法在自己 await 期间删自己的 db。
    nonisolated public static func deleteDatabaseFiles(at sqliteURL: URL) throws {
        GSYLog.warning(.db, "deleteDatabaseFiles 开始 path=\(sqliteURL.path)")
        let suffixes = ["", "-wal", "-shm"]
        var lastError: Error?
        var deletedCount = 0
        for s in suffixes {
            let url = URL(fileURLWithPath: sqliteURL.path + s)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    deletedCount += 1
                } catch {
                    lastError = error
                    GSYLog.error(.db, "删除 \(url.path) 失败：\(error)")
                }
            }
        }
        GSYLog.warning(.db, "deleteDatabaseFiles 完成 deleted=\(deletedCount)/3")
        if let lastError { throw lastError }
    }
}
