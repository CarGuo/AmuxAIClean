import XCTest
@testable import ScanKit

/// `VersionedRetainScanner`（保留最新 N 版）单元测试（M2-T5）。
///
/// 覆盖：
/// 1. 语义化版本排序 + 保留 latest N（DeviceSupport 典型场景）
/// 2. 字典序排序兜底（非数字版本名）
/// 3. mtime 倒排（无版本号布局）
/// 4. keepLatest 边界（candidates ≤ keep → 整树不识别）
/// 5. 软链与文件被跳过（防误算入版本数）
/// 6. 隐藏目录与隐藏文件跳过；extractLeadingVersion 边界
final class VersionedRetainScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VersionedRetainScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func makeDirs(_ root: URL, names: [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try fm.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
    }

    // 1) 语义化版本号排序（DeviceSupport 真实样本）
    func test_semverPreferred_保留最新2版_iOSDeviceSupport布局() throws {
        let root = tempRoot.appendingPathComponent("iOS DeviceSupport", isDirectory: true)
        try makeDirs(root, names: [
            "17.5 (21F79)",
            "17.6 (21G80)",
            "18.0 (22A3354)",
            "18.1 (22B5054e)"
        ])
        let hits = VersionedRetainScanner.detect(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .semverPreferred)
        )
        XCTAssertEqual(hits.count, 2, "应回收 17.5 与 17.6，实得 \(hits.map(\.versionName))")
        let names = Set(hits.map(\.versionName))
        XCTAssertEqual(names, ["17.5 (21F79)", "17.6 (21G80)"])
        XCTAssertEqual(hits.first?.retainedLatest, "18.1 (22B5054e)")
    }

    // 2) 字典序排序兜底（非纯数字版本名，如 Toolbox build code）
    func test_lexicographic_按字典序保留尾2() throws {
        let root = tempRoot.appendingPathComponent("apps", isDirectory: true)
        try makeDirs(root, names: ["alpha", "beta", "gamma", "delta"])
        let hits = VersionedRetainScanner.detect(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .lexicographic)
        )
        // localizedStandardCompare 升序：alpha < beta < delta < gamma
        // 尾 2 保留：delta / gamma；旧 2 回收：alpha / beta
        let names = Set(hits.map(\.versionName))
        XCTAssertEqual(names, ["alpha", "beta"], "字典序回收应为 alpha + beta，实得 \(names)")
    }

    // 3) mtime 倒排（最旧的 mtime 最先回收）
    func test_mtime_最旧的mtime先回收() throws {
        let root = tempRoot.appendingPathComponent("mtimeBucket", isDirectory: true)
        try makeDirs(root, names: ["A", "B", "C"])
        let fm = FileManager.default
        // A: 30 天前；B: 1 天前；C: now
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86400)],
                             ofItemAtPath: root.appendingPathComponent("A").path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-86400)],
                             ofItemAtPath: root.appendingPathComponent("B").path)
        try fm.setAttributes([.modificationDate: now],
                             ofItemAtPath: root.appendingPathComponent("C").path)
        let hits = VersionedRetainScanner.detect(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .modificationDateDescending)
        )
        XCTAssertEqual(hits.count, 1, "保留 B + C 两个，回收 A 一个")
        XCTAssertEqual(hits.first?.versionName, "A")
    }

    // 4) keepLatest 边界：candidates ≤ keep → 整树不识别（安全）
    func test_候选数小于等于keepLatest时返回空() throws {
        let root = tempRoot.appendingPathComponent("just2", isDirectory: true)
        try makeDirs(root, names: ["1.0.0", "2.0.0"])
        let hits = VersionedRetainScanner.detect(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .semverPreferred)
        )
        XCTAssertTrue(hits.isEmpty, "仅 2 个版本而 keepLatest=2，不应识别任何旧版本（保留全部）")
    }

    // 5) 软链与文件跳过：防混入候选数
    func test_软链与文件被跳过_不计入版本数() throws {
        let root = tempRoot.appendingPathComponent("withSymlinkAndFile", isDirectory: true)
        let fm = FileManager.default
        try makeDirs(root, names: ["1.0.0", "1.1.0", "1.2.0", "1.3.0"])
        // 加一个软链 + 一个普通文件，都不应被算成版本目录
        let link = root.appendingPathComponent("currentLink")
        try fm.createSymbolicLink(atPath: link.path,
                                  withDestinationPath: "1.3.0")
        let plainFile = root.appendingPathComponent("README.txt")
        try Data("hello".utf8).write(to: plainFile)

        let hits = VersionedRetainScanner.detect(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .semverPreferred)
        )
        XCTAssertEqual(hits.count, 2, "应回收 1.0.0 + 1.1.0；软链/普通文件不计入版本数")
        let names = Set(hits.map(\.versionName))
        XCTAssertEqual(names, ["1.0.0", "1.1.0"])
        XCTAssertFalse(names.contains("currentLink"))
        XCTAssertFalse(names.contains("README.txt"))
    }

    // 6) 隐藏目录跳过 + extractLeadingVersion 边界
    func test_隐藏目录跳过_compareSemver边界() throws {
        // 6a 隐藏目录跳过
        let root = tempRoot.appendingPathComponent("hidden", isDirectory: true)
        try makeDirs(root, names: [".DS_Store_dir", "1.0", "2.0", "3.0"])
        let hits = VersionedRetainScanner.detect(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .semverPreferred, skipHiddenDirectories: true)
        )
        XCTAssertEqual(hits.count, 1, "三个有效版本中应回收最旧的 1.0")
        XCTAssertEqual(hits.first?.versionName, "1.0")

        // 6b extractLeadingVersion 边界
        XCTAssertEqual(VersionedRetainScanner.extractLeadingVersion("17.5 (21F79)"), "17.5")
        XCTAssertEqual(VersionedRetainScanner.extractLeadingVersion("242.20224.155"), "242.20224.155")
        XCTAssertNil(VersionedRetainScanner.extractLeadingVersion("alpha"), "无数字首段应返回 nil")
        XCTAssertNil(VersionedRetainScanner.extractLeadingVersion("..."), "纯点号应返回 nil（无数字字符）")

        // 6c compareSemver 关键样本
        XCTAssertEqual(VersionedRetainScanner.compareSemver("17.5", "18.0"), .orderedAscending)
        XCTAssertEqual(VersionedRetainScanner.compareSemver("0.7.2", "0.6.0"), .orderedDescending)
        // 同首段 → fallback 字典序
        XCTAssertEqual(VersionedRetainScanner.compareSemver("17.5 (a)", "17.5 (b)"), .orderedAscending)
        // 预发布后缀（-alpha / -beta / -rc）必须排在同核心版本的正式版之前（保留正式版）
        XCTAssertEqual(VersionedRetainScanner.compareSemver("1.0.0-alpha", "1.0.0"), .orderedAscending)
        XCTAssertEqual(VersionedRetainScanner.compareSemver("1.0.0", "1.0.0-beta.1"), .orderedDescending)
    }
}
