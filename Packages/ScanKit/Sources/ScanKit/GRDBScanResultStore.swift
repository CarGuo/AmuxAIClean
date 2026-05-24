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
