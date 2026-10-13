import XCTest
@testable import AppUI
import SafetyKit

/// v1.6 / 2026-06：可清理字节口径契约测试。
///
/// 背景：用户截图反馈 sidebar 的 "Cleanable" 跟 scanning total 一比一相等
/// （扫到 133.49 GB → 报 Cleanable 133.49 GB）。根因是 [MainView.sidebar](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift)
/// 历史上把 `coordinator.snapshot.totalBytes` 错灌进 [VolumeCapacityCard.cleanableBytes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/VolumeCapacityCard.swift#L26)；
/// 而灵动岛 [FloatingScanHUD](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
/// 自己 reduce `verdict == .safe` 求和——两条口径漂移。
///
/// 这一轮把口径收敛到 [ScanSnapshot.cleanableBytes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L389-L394)
/// 作为**单一源**，本测试钉死四条不变量：
///
///   1) `cleanableBytes == safeBytes`（业界口径：只算 `.safe`）
///   2) `cleanableBytes != totalBytes`（在 verdict 混合的真实 snapshot 中，
///      "已扫总量" 与"可清理"必须脱钩——这是用户当面质疑的那一条）
///   3) `safeBytes + confirmBytes + forbidBytes == Σ rows.bytes`（三档守恒，
///      防止后续 [SafetyVerdict](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L5-L9)
///      加 case 时漏更新这里）
///   4) 空 / 纯单档 snapshot 的边界条件不抛、值为 0 / 等于总和
///
/// 不测 UI 层：本契约只盯字节算法，UI 颜色 / 严重度 / 图例归
/// [VolumeCapacityCard](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/VolumeCapacityCard.swift) 视觉回归专项。
final class CleanableBytesContractTests: XCTestCase {

    // MARK: - Fixture helpers

    /// 构造一条已 verdict 评过分的 [RowItem](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L6)。
    /// 字段最小化，专注 verdict + bytes 两个本契约关心的维度。
    private func row(_ id: String, _ bytes: Int64, _ verdict: SafetyVerdict) -> RowItem {
        RowItem(
            id: id,
            url: URL(fileURLWithPath: "/tmp/" + id),
            title: id,
            isDirectory: true,
            bytes: bytes,
            logicalBytes: bytes,
            fileCount: 1,
            verdict: verdict,
            rejection: verdict == .forbid ? .hardForbidPrefix : .ok
        )
    }

    /// 拼一个混合 verdict 的 finished snapshot。
    /// 注意 `totalBytes` 故意比 Σrows.bytes **大**——模拟 ScanCoordinator 真实行为：
    /// `totalBytes` 累计的是 ingest 过程中所有文件字节（含未聚合 / 已被丢弃的子项），
    /// 跟最终 publish 的 rows 不一定逐字节相等。这恰恰是 sidebar 报错 GB 数的根源。
    private func mixedFinishedSnapshot() -> ScanSnapshot {
        let rows: [RowItem] = [
            row("caches",     5_000_000_000, .safe),     //  5 GB · 可一键
            row("logs",         800_000_000, .safe),     //  0.8 GB · 可一键
            row("downloads",  3_200_000_000, .confirm),  //  3.2 GB · 待确认
            row("documents", 12_000_000_000, .forbid),   // 12 GB · 文档根，绝不动
            row("ssh-keys",       4_000_000, .forbid),   //  4 MB · 凭证
        ]
        // totalBytes 故意 > Σ(rows.bytes)：模拟 ingest 总量 > publish 聚合
        let rowsSum = rows.reduce(0) { $0 + $1.bytes }
        return ScanSnapshot(
            categoryID: "test.mixed",
            rows: rows,
            totalBytes: rowsSum + 30_000_000_000, // +30 GB"已扫但未聚合到 rows"
            scannedFileCount: 12_345,
            isFinished: true,
            elapsed: 4.2
        )
    }

    // MARK: - 契约 1：cleanableBytes == safeBytes

    func test_cleanableBytes_口径只算safe() {
        let snap = mixedFinishedSnapshot()

        XCTAssertEqual(snap.cleanableBytes, snap.safeBytes,
                       "cleanableBytes 必须严格 == safeBytes —— 这是与 CleanMyMac / Onyx / macOS Storage 对齐的业界口径")

        // 显式数值断言：caches 5 GB + logs 0.8 GB = 5.8 GB
        XCTAssertEqual(snap.cleanableBytes, 5_800_000_000)
    }

    // MARK: - 契约 2：cleanableBytes 必须脱钩 totalBytes

    /// 用户截图里的"罪状"：扫到多少 = 报 Cleanable 多少。
    /// 在 verdict 混合的真实快照中，这两个数必须显著不等，否则就是回归到 v1.6 之前的 bug。
    func test_cleanableBytes_必须脱钩totalBytes() {
        let snap = mixedFinishedSnapshot()

        XCTAssertNotEqual(snap.cleanableBytes, snap.totalBytes,
                          "cleanableBytes == totalBytes 是 v1.6 之前的口径 bug —— sidebar 会显示'扫多少就 Cleanable 多少'")
        XCTAssertLessThan(snap.cleanableBytes, snap.totalBytes,
                          "可清理一定 < 已扫总量（混合 fixture 里有 confirm + forbid 段）")

        // 进一步：可清理 < 1/3 总量，量级体感与业界一致（典型 Mac 真实可清几 GB，整盘几百 GB）
        XCTAssertLessThan(Double(snap.cleanableBytes) / Double(snap.totalBytes), 1.0 / 3.0,
                          "在混合 fixture 下可清理应远小于总扫描量")
    }

    // MARK: - 契约 3：三档守恒

    /// safe + confirm + forbid 必须等于 Σ rows.bytes，否则后面有人给 [SafetyVerdict](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L5-L9)
    /// 加了第四档但忘了在 [ScanSnapshot](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/RowItem.swift#L315) 同步——CI 立刻红线。
    func test_三档verdict字节守恒() {
        let snap = mixedFinishedSnapshot()

        let rowsSum = snap.rows.reduce(Int64(0)) { $0 + $1.bytes }
        let bucketSum = snap.safeBytes + snap.confirmBytes + snap.forbidBytes

        XCTAssertEqual(bucketSum, rowsSum,
                       "safe + confirm + forbid 必须等于 Σ rows.bytes —— SafetyVerdict 若加 case，必须同步更新 ScanSnapshot 的三档求和")
    }

    // MARK: - 契约 4：边界条件

    func test_empty_snapshot_四个口径都为0() {
        let empty = ScanSnapshot.empty
        XCTAssertEqual(empty.cleanableBytes, 0)
        XCTAssertEqual(empty.safeBytes, 0)
        XCTAssertEqual(empty.confirmBytes, 0)
        XCTAssertEqual(empty.forbidBytes, 0)
    }

    func test_纯safe_snapshot_cleanable等于totalRowsSum() {
        let rows = [row("a", 100, .safe), row("b", 200, .safe), row("c", 300, .safe)]
        let snap = ScanSnapshot(categoryID: "test.allSafe", rows: rows,
                                totalBytes: 600, scannedFileCount: 3,
                                isFinished: true, elapsed: 0.1)
        XCTAssertEqual(snap.cleanableBytes, 600)
        XCTAssertEqual(snap.confirmBytes, 0)
        XCTAssertEqual(snap.forbidBytes, 0)
    }

    func test_纯forbid_snapshot_cleanable为0() {
        let rows = [row("doc1", 1_000_000_000, .forbid),
                    row("doc2", 2_000_000_000, .forbid)]
        let snap = ScanSnapshot(categoryID: "test.allForbid", rows: rows,
                                totalBytes: 3_000_000_000, scannedFileCount: 2,
                                isFinished: true, elapsed: 0.1)
        XCTAssertEqual(snap.cleanableBytes, 0,
                       "全 forbid 时 cleanable 必须为 0 —— 用户文档根 / 凭证再大也绝不能误报为可删")
        XCTAssertEqual(snap.forbidBytes, 3_000_000_000)
        XCTAssertGreaterThan(snap.totalBytes, 0,
                             "totalBytes 仍然反映扫到了多少（无论可不可删）")
    }

    func test_纯confirm_snapshot_cleanable为0() {
        let rows = [row("dl1", 500_000_000, .confirm)]
        let snap = ScanSnapshot(categoryID: "test.allConfirm", rows: rows,
                                totalBytes: 500_000_000, scannedFileCount: 1,
                                isFinished: true, elapsed: 0.1)
        XCTAssertEqual(snap.cleanableBytes, 0,
                       "confirm 段不应并进 cleanable 数字 —— 必须用户审阅后才计入")
        XCTAssertEqual(snap.confirmBytes, 500_000_000)
    }
}
