import XCTest
@testable import ScanKit

/// MailDownloadsScanner 单元测试（Step 12B / AUDIT §4.2 P1 / line 116 + 434）。
///
/// macOS Mail.app 在以下两类路径下保留用户已下载 / 已查看附件的本地副本：
/// 1) 沙盒容器（10.13+）：`~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/<UUID>/<file>`
/// 2) 历史路径：`~/Library/Mail Downloads/<UUID>/<file>`（旧 macOS / 部分迁移用户）
///
/// 这些副本是邮件附件被点开 / 用预览看一眼后落盘的"二次拷贝"，删除并**不会**影响
/// `~/Library/Mail/V*/` 中的原始邮件存档。但删除是用户感知层面的"丢东西"高危动作，
/// 因此扫描走严格的 30 天龄保守过滤：
///   - mtime <= now - 30d  AND  atime <= now - 30d  → 候选（两轴都老）
///   - 任一时间戳在窗内 → 排除（用户近期用过）
///
/// 测试覆盖：30 天双轴边界 / 多容器路径 / 子目录递归 / 空容器 / 元数据完整性。
final class MailDownloadsTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MailDownloadsTests-\(UUID().uuidString)",
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

    /// 在 `<container>/<UUID>/<name>` 落一份附件，并用 POSIX `utimes(2)` 同步设置
    /// atime / mtime 偏移（FileManager 不暴露 atime，`utimes` 第一参数为 atime，
    /// 第二参数为 mtime，必须分别传入两个不同的 timeval）。
    @discardableResult
    private func makeAttachment(
        container: URL,
        uuid: String,
        name: String,
        sizeBytes: Int = 16,
        mtimeDaysAgo: Double,
        atimeDaysAgo: Double,
        referenceNow: Date = Date()
    ) throws -> URL {
        let fm = FileManager.default
        let dir = container.appendingPathComponent(uuid, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xCA, count: sizeBytes).write(to: url)
        let atime = referenceNow.addingTimeInterval(-atimeDaysAgo * 86400)
        let mtime = referenceNow.addingTimeInterval(-mtimeDaysAgo * 86400)
        try setTimes(url: url, atime: atime, mtime: mtime)
        return url
    }

    /// 用 POSIX `utimes(2)` 直接设置 atime/mtime（FileManager 不暴露 atime）。
    private func setTimes(url: URL, atime: Date, mtime: Date) throws {
        func toTimeval(_ d: Date) -> timeval {
            let ts = d.timeIntervalSince1970
            let sec = time_t(ts)
            let usec = suseconds_t((ts - Double(sec)) * 1_000_000)
            return timeval(tv_sec: sec, tv_usec: usec)
        }
        var times = [toTimeval(atime), toTimeval(mtime)]
        let res = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return times.withUnsafeBufferPointer { buf in
                utimes(ptr, buf.baseAddress)
            }
        }
        if res != 0 {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "utimes failed"])
        }
    }

    // MARK: - 1. happy path：双轴 > 30d 命中

    func test_old_attachment_with_both_mtime_atime_older_than_30d_is_hit() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        try makeAttachment(container: container,
                           uuid: "ABC-123", name: "report.pdf",
                           sizeBytes: 2048,
                           mtimeDaysAgo: 60, atimeDaysAgo: 60)
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 30, now: Date())
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url.lastPathComponent, "report.pdf")
        XCTAssertEqual(hits.first?.sizeBytes, 2048)
    }

    // MARK: - 2. 30d 边界两侧：< 阈值排除，> 阈值命中

    /// 阈值的语义 = "**严格** 大于 30 天才算老"。用 29.5 与 30.5 两条样本明确划界，
    /// 避开浮点 ULP / utimes 微秒精度抖动带来的"正好 30 天"边界毛刺。
    func test_age_threshold_strict_boundary() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        let now = Date()
        try makeAttachment(container: container,
                           uuid: "INSIDE", name: "inside.pdf",
                           mtimeDaysAgo: 29.5, atimeDaysAgo: 29.5,
                           referenceNow: now)
        try makeAttachment(container: container,
                           uuid: "OUTSIDE", name: "outside.pdf",
                           mtimeDaysAgo: 30.5, atimeDaysAgo: 30.5,
                           referenceNow: now)
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 30, now: now)
        )
        XCTAssertEqual(hits.count, 1, "29.5d 排除 / 30.5d 命中，得到 \(hits)")
        XCTAssertEqual(hits.first?.url.lastPathComponent, "outside.pdf")
    }

    // MARK: - 3. atime 在窗内：必须排除（近期被打开过）

    func test_recent_atime_excludes_even_when_mtime_old() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        try makeAttachment(container: container,
                           uuid: "ACT", name: "active.pdf",
                           mtimeDaysAgo: 200,    // 半年没改
                           atimeDaysAgo: 3)      // 但 3 天前刚打开过
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 30, now: Date())
        )
        XCTAssertTrue(hits.isEmpty,
                      "atime 在 30d 窗内说明用户最近读过，必须排除")
    }

    // MARK: - 4. mtime 在窗内：也必须排除（近期被改写过）

    func test_recent_mtime_excludes_even_when_atime_old() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        try makeAttachment(container: container,
                           uuid: "EDIT", name: "edit.pdf",
                           mtimeDaysAgo: 5,
                           atimeDaysAgo: 200)
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 30, now: Date())
        )
        XCTAssertTrue(hits.isEmpty,
                      "mtime 在窗内说明用户最近改写过（罕见但需保守），必须排除")
    }

    // MARK: - 5. 多 container roots：沙盒 + 历史路径同时扫

    func test_multiple_container_roots_are_all_scanned() throws {
        let sandbox = tempRoot
            .appendingPathComponent("Containers/com.apple.mail/Data/Library/Mail Downloads",
                                    isDirectory: true)
        let legacy = tempRoot
            .appendingPathComponent("Mail Downloads", isDirectory: true)
        try makeAttachment(container: sandbox,
                           uuid: "S1", name: "sb.pdf",
                           mtimeDaysAgo: 90, atimeDaysAgo: 90)
        try makeAttachment(container: legacy,
                           uuid: "L1", name: "lg.pdf",
                           mtimeDaysAgo: 90, atimeDaysAgo: 90)
        let hits = MailDownloadsScanner.detect(
            containerRoots: [sandbox, legacy],
            options: MailDownloadsScanner.Options(ageDays: 30, now: Date())
        )
        XCTAssertEqual(hits.count, 2)
        let names = Set(hits.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["sb.pdf", "lg.pdf"])
    }

    // MARK: - 6. 子目录递归（UUID/sub/file 也要扫到）

    /// Mail.app 偶尔会按 UUID/<sub-UUID>/<file> 多层嵌套，递归一层不够。
    func test_nested_subdirectories_are_walked() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        let deep = container
            .appendingPathComponent("UUID-A", isDirectory: true)
            .appendingPathComponent("UUID-B", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let url = deep.appendingPathComponent("nested.pdf")
        try Data(repeating: 0xAB, count: 32).write(to: url)
        let old = Date().addingTimeInterval(-90 * 86400)
        try setTimes(url: url, atime: old, mtime: old)

        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 30, now: Date())
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url.lastPathComponent, "nested.pdf")
    }

    // MARK: - 7. 边界：container 不存在（用户从未用过 Mail）→ 空

    func test_missing_container_returns_empty() {
        let ghost = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        let hits = MailDownloadsScanner.detect(
            containerRoots: [ghost],
            options: .default
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 8. 边界：空 container（目录存在但里面没文件）→ 空

    func test_empty_container_returns_empty() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: container,
                                                withIntermediateDirectories: true)
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: .default
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 9. Hit 元数据完整性

    func test_hit_metadata_is_complete() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        let url = try makeAttachment(container: container,
                                     uuid: "META", name: "meta.pdf",
                                     sizeBytes: 4096,
                                     mtimeDaysAgo: 90, atimeDaysAgo: 90)
        let now = Date()
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 30, now: now)
        )
        XCTAssertEqual(hits.count, 1)
        let h = hits[0]
        // FileManager.enumerator 返回的 URL 会规范化 /var → /private/var；
        // 用 standardizedFileURL 做对称归一后再比较。
        XCTAssertEqual(h.url.standardizedFileURL.resolvingSymlinksInPath(),
                       url.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(h.url.lastPathComponent, "meta.pdf")
        XCTAssertEqual(h.id, h.url.path)
        XCTAssertEqual(h.sizeBytes, 4096)
        XCTAssertEqual(h.ageDays, 90, accuracy: 1.0)
        XCTAssertNotNil(h.modificationDate)
        XCTAssertNotNil(h.accessDate)
    }

    // MARK: - 10. 自定义阈值：60 天放宽

    func test_custom_age_days_is_respected() throws {
        let container = tempRoot.appendingPathComponent("Mail Downloads", isDirectory: true)
        try makeAttachment(container: container,
                           uuid: "C45", name: "fortyfive.pdf",
                           mtimeDaysAgo: 45, atimeDaysAgo: 45)
        try makeAttachment(container: container,
                           uuid: "C90", name: "ninety.pdf",
                           mtimeDaysAgo: 90, atimeDaysAgo: 90)
        // 阈值 60 天 → 45 天的应被排除，90 天的应命中
        let hits = MailDownloadsScanner.detect(
            containerRoots: [container],
            options: MailDownloadsScanner.Options(ageDays: 60, now: Date())
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url.lastPathComponent, "ninety.pdf")
    }
}
