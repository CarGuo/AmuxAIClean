import XCTest
@testable import ScanKit

/// TimeMachineFailedBackupScanner 单元测试（Step 12A / AUDIT §4.2 P1）。
///
/// Time Machine 备份库布局：
/// 1) 本地磁盘：`<volume>/Backups.backupdb/<HostName>/<YYYY-MM-DD-HHMMSS>(.inProgress)?`
/// 2) 稀疏镜像：`<volume>/<HostName>.sparsebundle`（不在本扫描器范围）
///
/// 失败 / 中断的备份目录会带 `.inProgress` 后缀，下次成功备份后会被 macOS 自动清理；
/// 但当系统崩溃 / 强制断电 / 移除目标盘时，孤儿 `.inProgress` 会留在原地永远不被清。
///
/// 安全窗：< 24h 的 `.inProgress` 可能正属于当前活跃备份进程（被 backupd hold open），
/// 必须**不返回**到 hits；> 24h 视为孤儿失败备份候选。
final class TimeMachineFailedBackupTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TMFailedBackupTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Fixture helpers

    /// 在 `volumeRoot/Backups.backupdb/<host>` 下铺一组备份目录。
    /// `entries` 形如 `[("2026-06-03-101234", false), ("2026-06-04-080000.inProgress", true)]`，
    /// 第二元为 false 表示**已完成**备份，true 表示 `.inProgress` 后缀。
    /// 每条目录的 mtime 用 `mtimeOffsets` 偏移当下的小时数（负数表示过去）。
    private func makeBackupDB(
        volumeRoot: URL,
        host: String,
        entries: [(name: String, mtimeHoursAgo: Double)]
    ) throws {
        let fm = FileManager.default
        let dbRoot = volumeRoot
            .appendingPathComponent("Backups.backupdb", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
        try fm.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let now = Date()
        for (name, hoursAgo) in entries {
            let dir = dbRoot.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let mtime = now.addingTimeInterval(-hoursAgo * 3600)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dir.path)
        }
    }

    // MARK: - 1. 经典 happy path：识别 > 24h 孤儿 .inProgress

    /// .inProgress 且 > 24h → hits 应包含；已完成的备份目录不应进入 hits。
    func test_arrhythmic_inProgress_older_than_24h_is_hit() throws {
        try makeBackupDB(
            volumeRoot: tempRoot, host: "MacBookPro",
            entries: [
                ("2026-06-01-080000",            mtimeHoursAgo: 72), // 已完成 3 天前
                ("2026-06-02-080000.inProgress", mtimeHoursAgo: 48), // 孤儿 2 天前
                ("2026-06-03-080000",            mtimeHoursAgo: 24), // 已完成
            ])
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 24, now: Date()
            )
        )
        XCTAssertEqual(hits.count, 1, "只有 .inProgress + > 24h 才进入候选，得到 \(hits)")
        XCTAssertEqual(hits.first?.url.lastPathComponent,
                       "2026-06-02-080000.inProgress")
        XCTAssertEqual(hits.first?.host, "MacBookPro")
    }

    // MARK: - 2. 安全窗：< 24h 的 .inProgress 必须排除

    /// 当前活跃备份进程持有的 .inProgress（如刚崩了的备份）必须 NOT 进入 hits。
    func test_inProgress_within_safety_window_is_excluded() throws {
        try makeBackupDB(
            volumeRoot: tempRoot, host: "iMac",
            entries: [
                ("2026-06-04-070000.inProgress", mtimeHoursAgo: 0.5),   // 30 分钟前
                ("2026-06-04-040000.inProgress", mtimeHoursAgo: 4),    // 4h 前
                ("2026-06-03-101234.inProgress", mtimeHoursAgo: 23.5), // 23.5h 前
            ])
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 24, now: Date()
            )
        )
        XCTAssertTrue(hits.isEmpty,
                      "< 24h 的 .inProgress 都在安全窗内，必须排除，得到 \(hits)")
    }

    // MARK: - 3. 已完成备份 (无 .inProgress 后缀) 永不进 hits

    /// 不能误删已成功的快照。
    func test_completed_backups_never_appear_in_hits() throws {
        try makeBackupDB(
            volumeRoot: tempRoot, host: "MBA",
            entries: [
                ("2025-01-01-000000", mtimeHoursAgo: 24.0 * 365), // 一年前已完成备份
                ("2024-06-04-080000", mtimeHoursAgo: 24.0 * 730), // 两年前
            ])
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 24, now: Date()
            )
        )
        XCTAssertTrue(hits.isEmpty,
                      "已完成备份（无 .inProgress 后缀）必须永不进 hits")
    }

    // MARK: - 4. 多 host 隔离

    /// 同一卷可能同时给多台 Mac 备份；hits 必须区分 host。
    func test_multiple_hosts_each_returns_own_inProgress() throws {
        try makeBackupDB(
            volumeRoot: tempRoot, host: "MacA",
            entries: [("2026-05-01-080000.inProgress", mtimeHoursAgo: 800)]
        )
        try makeBackupDB(
            volumeRoot: tempRoot, host: "MacB",
            entries: [("2026-05-15-080000.inProgress", mtimeHoursAgo: 480)]
        )
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 24, now: Date()
            )
        )
        XCTAssertEqual(hits.count, 2)
        let hosts = Set(hits.map(\.host))
        XCTAssertEqual(hosts, ["MacA", "MacB"])
    }

    // MARK: - 5. 边界：Backups.backupdb 不存在

    /// volumeRoot 下根本没有 TM 备份库 → 返回空，不抛错。
    func test_no_backupdb_returns_empty() {
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: .default
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 6. 边界：host 目录里只有非目录文件

    /// 防御：Backups.backupdb/<host>/.DS_Store 之类不应当成 .inProgress。
    func test_non_directory_entries_are_skipped() throws {
        let fm = FileManager.default
        let hostRoot = tempRoot
            .appendingPathComponent("Backups.backupdb", isDirectory: true)
            .appendingPathComponent("MacX", isDirectory: true)
        try fm.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let dsStore = hostRoot.appendingPathComponent(".DS_Store")
        try Data().write(to: dsStore)
        let bogusName = hostRoot.appendingPathComponent("not_a_backup.inProgress")
        try Data().write(to: bogusName) // 普通文件，不是目录

        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 24, now: Date()
            )
        )
        XCTAssertTrue(hits.isEmpty,
                      "非目录条目（即使带 .inProgress 后缀）必须被跳过")
    }

    // MARK: - 7. 自定义安全窗

    /// 调用方可注入更激进 / 保守的安全窗。
    func test_custom_safety_window_is_respected() throws {
        try makeBackupDB(
            volumeRoot: tempRoot, host: "MacC",
            entries: [
                ("2026-06-03-100000.inProgress", mtimeHoursAgo: 36),
                ("2026-06-04-040000.inProgress", mtimeHoursAgo: 6),
            ])
        // 安全窗放宽到 48h → 36h 也应被排除
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 48, now: Date()
            )
        )
        XCTAssertTrue(hits.isEmpty,
                      "安全窗 48h 应同时排除 36h 与 6h 的 .inProgress，得到 \(hits)")
    }

    // MARK: - 8. Hit 元数据完整性

    /// Hit 应携带完整 url / host / mtime / ageHours 元数据，便于 UI 展示与排序。
    func test_hit_metadata_is_complete() throws {
        try makeBackupDB(
            volumeRoot: tempRoot, host: "MacZ",
            entries: [("2025-12-01-101234.inProgress", mtimeHoursAgo: 100)]
        )
        let now = Date()
        let hits = TimeMachineFailedBackupScanner.detect(
            volumeRoot: tempRoot,
            options: TimeMachineFailedBackupScanner.Options(
                safetyWindowHours: 24, now: now
            )
        )
        XCTAssertEqual(hits.count, 1)
        let h = hits[0]
        XCTAssertEqual(h.host, "MacZ")
        XCTAssertEqual(h.url.lastPathComponent, "2025-12-01-101234.inProgress")
        XCTAssertEqual(h.id, h.url.path)
        XCTAssertEqual(h.ageHours, 100, accuracy: 0.5,
                       "ageHours 应以注入的 now 为基准计算")
    }
}
