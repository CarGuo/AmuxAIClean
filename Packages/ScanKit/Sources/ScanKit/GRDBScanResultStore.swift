import Foundation
import GRDB

public actor GRDBScanResultStore: ScanResultStore {
    public enum StoreError: Error, Sendable, Equatable {
        case cannotResolveStoreDirectory
    }

    private let dbPool: DatabasePool
    private let location: URL

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
        }
        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
        self.location = databaseURL
        try Self.migrator.migrate(self.dbPool)
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

    /// v1.3.z：批量子树聚合。一次事务内 prefixes.count 次 range scan
    /// （依赖 `scan_result_session_path_idx` 复合索引）。
    ///
    /// 性能要点：用 `path >= 'X/' AND path < <X/'s_next_char>` 的 range 比较而**不是** LIKE。
    /// SQLite 的 LIKE 优化器只在 **没有 ESCAPE 子句 + BINARY collation + 默认 case_sensitive_like = 0**
    /// 时才会自动转 range scan，受全局 PRAGMA 影响很脆弱。
    /// 用纯 `>=` / `<` 比较，索引前缀走 range 是 SQLite **强保证**（不依赖 LIKE 优化器）。
    /// upper bound 取 `prefix + "/" + Character(UnicodeScalar(0x10FFFF))` 兜底所有 UTF-8 字符。
    /// 实际我们直接把 "/" 换成下一个 ASCII '0' 不行（path 里可能有更高字符），
    /// 用一个保证比任何合法子路径都大的 sentinel：附加一个 "\u{10FFFF}"。
    public func subtreeAggregates(
        sessionID: ScanSessionID,
        pathPrefixes: [String]
    ) async throws -> [String: ScanResultAggregate] {
        guard !pathPrefixes.isEmpty else { return [:] }
        return try await dbPool.read { db in
            var out: [String: ScanResultAggregate] = [:]
            let sql = """
                SELECT COUNT(*) AS cnt,
                       COALESCE(SUM(allocated_size), 0) AS alloc,
                       COALESCE(SUM(logical_size), 0) AS logi
                FROM scan_result
                WHERE session_id = ?
                  AND path >= ?
                  AND path < ?
                """
            // sentinel：比所有合法 UTF-8 子路径都大。U+10FFFF 是 Unicode 最大值，
            // SQLite TEXT 列按 BINARY collation 排序时，任何后续字符串都不会大于它。
            let sentinel = "\u{10FFFF}"
            for prefix in pathPrefixes {
                let lower = prefix + "/"
                let upper = prefix + "/" + sentinel
                if let row = try Row.fetchOne(
                    db,
                    sql: sql,
                    arguments: [sessionID.raw, lower, upper]
                ) {
                    out[prefix] = ScanResultAggregate(
                        totalCount: row["cnt"],
                        totalAllocatedBytes: row["alloc"],
                        totalLogicalBytes: row["logi"]
                    )
                } else {
                    out[prefix] = .empty
                }
            }
            return out
        }
    }

    /// v1.3.zzzz：树形 Tab 展开 prefix 的"直接子项 + 每段子树聚合"——单条 SQL GROUP BY 实现。
    ///
    /// 对比旧版 [ScanCoordinator.directChildrenAsync](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift#L1045)
    /// 的"拉所有子孙 record + Swift Dictionary GROUP BY"路径（实测 ~Library/Caches 33w 条 ~100ms），
    /// 把整段聚合下推到 SQLite C 内层，预期降到 ~10ms 级，且不再把数据拉回 Swift 内存。
    ///
    /// 性能要点：
    /// 1) 走与 subtreeAggregates 相同的 path range（[lower, upper)），命中
    ///    `scan_result_session_path_idx` 复合索引做 range scan；
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
        // sentinel：与 subtreeAggregates 同款 U+10FFFF，保证比所有合法子路径都大。
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
                logical_size
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
              SUM(CASE WHEN is_directory = 0 THEN allocated_size ELSE 0 END) AS file_bytes
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
                    prefix, prefix
                ]
            )
            return rows.map { row in
                let hasInode = (row["has_inode"] as Int) != 0
                let dirInode = (row["dir_inode"] as Int) != 0
                let cnt: Int = row["cnt"]
                let fileCnt: Int = row["file_cnt"]
                // hasInode=true 时听 inode 自己的；否则只要 cnt > 1 或没文件 leaf 就当目录
                let isDir: Bool = hasInode ? dirInode : (cnt > 1 || fileCnt == 0)
                return DirectChildAggregate(
                    segment: row["seg"],
                    isDirectory: isDir,
                    hasInode: hasInode,
                    descendantCount: cnt,
                    descendantBytes: row["bytes"],
                    descendantLogicalBytes: row["logical_bytes"],
                    fileDescendantCount: fileCnt,
                    fileDescendantBytes: row["file_bytes"]
                )
            }
        }
    }

    public func evictSession(_ id: ScanSessionID) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM scan_session WHERE id = ?",
                arguments: [id.raw]
            )
        }
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func clearAll() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM scan_session")
            try db.execute(sql: "DELETE FROM scan_result")
        }
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
        }
    }

    /// 测试专用：返回 scan_result 表当前总行数（不按 session 过滤）。
    /// 用来验证 P0-A 修复后 ON DELETE CASCADE 真的级联清掉了子表行。
    /// 仅 internal，避免被生产代码误用。
    internal func _debugRawScanResultCount() async throws -> Int {
        try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_result") ?? 0
        }
    }
}
