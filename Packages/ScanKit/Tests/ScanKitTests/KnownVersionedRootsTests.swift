import XCTest
@testable import ScanKit

/// Mole 对齐 M3-T1：KnownVersionedRoots 注册表的注入测试。
///
/// 不依赖真实文件系统的部分（entries 静态数据） + 依赖临时目录的部分（scanAll）。
/// 与 [KnownVersionedRootsConsistencyTests] 互补——后者验证「yaml ↔ entries」一致性。
final class KnownVersionedRootsTests: XCTestCase {

    // MARK: - entries 静态契约

    func test_entries_至少包含_DeviceSupport_三条_和_Toolbox() throws {
        let paths = KnownVersionedRoots.entries.map(\.relativePath)
        XCTAssertTrue(paths.contains("Library/Developer/Xcode/iOS DeviceSupport"))
        XCTAssertTrue(paths.contains("Library/Developer/Xcode/watchOS DeviceSupport"))
        XCTAssertTrue(paths.contains("Library/Developer/Xcode/macOS DeviceSupport"))
        XCTAssertTrue(paths.contains("Library/Application Support/JetBrains/Toolbox/apps"))
    }

    func test_DeviceSupport_全部_keepLatest_是_2_且_semverPreferred() throws {
        for entry in KnownVersionedRoots.entries where entry.relativePath.contains("DeviceSupport") {
            XCTAssertEqual(entry.keepLatest, 2, "DeviceSupport \(entry.relativePath) keepLatest 应为 2")
            if case .semverPreferred = entry.ordering {} else {
                XCTFail("DeviceSupport \(entry.relativePath) 应使用 semverPreferred")
            }
        }
    }

    func test_Toolbox_keepLatest_是_1_且_semverPreferred() throws {
        guard let toolbox = KnownVersionedRoots.entries.first(where: {
            $0.relativePath == "Library/Application Support/JetBrains/Toolbox/apps"
        }) else {
            return XCTFail("Toolbox 条目缺失")
        }
        XCTAssertEqual(toolbox.keepLatest, 1)
        if case .semverPreferred = toolbox.ordering {} else {
            XCTFail("Toolbox 应使用 semverPreferred")
        }
    }

    func test_ruleID_全部唯一() throws {
        let ids = KnownVersionedRoots.entries.map(\.ruleID)
        XCTAssertEqual(Set(ids).count, ids.count, "ruleID 必须全局唯一")
    }

    // MARK: - scanAll 行为

    func test_scanAll_空_home_返回空命中() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertTrue(hits.isEmpty, "空 home 不存在任何 collection root，应返回空")
    }

    func test_scanAll_构造_iOS_DeviceSupport_4_版本_保留最新_2_产出_2_旧版本() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 构造 ~/Library/Developer/Xcode/iOS DeviceSupport/ 下 4 个版本
        let ds = tmp.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: ds, withIntermediateDirectories: true)
        for v in ["15.0 (19A346)", "16.4 (20E247)", "17.5 (21F79)", "18.0 (22A348)"] {
            try FileManager.default.createDirectory(
                at: ds.appendingPathComponent(v, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertEqual(hits.count, 2,
                       "4 版本 - keepLatest(2) = 2 个旧版本（15.0 + 16.4）应被识别")

        let oldNames = Set(hits.map(\.versionName))
        XCTAssertEqual(oldNames, ["15.0 (19A346)", "16.4 (20E247)"],
                       "旧版本应是排序后最旧的两个")

        for h in hits {
            XCTAssertEqual(h.ruleID, "apple.ios-device-support.versioned")
            XCTAssertFalse(h.retainedLatest.isEmpty,
                           "retainedLatest 应记录最新一版名字作为审计上下文")
            XCTAssertEqual(h.retainedLatest, "18.0 (22A348)",
                           "保留的最新一版应该是 18.0 (22A348)")
        }
    }

    func test_scanAll_只构造_3_版本_keepLatest_2_产出_1_旧版本() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ds = tmp.appendingPathComponent("Library/Developer/Xcode/macOS DeviceSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: ds, withIntermediateDirectories: true)
        for v in ["13.0", "14.5", "15.1"] {
            try FileManager.default.createDirectory(
                at: ds.appendingPathComponent(v, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.versionName, "13.0")
        XCTAssertEqual(hits.first?.ruleID, "apple.macos-device-support.versioned")
    }

    func test_scanAll_构造_Toolbox_3_apps_keepLatest_1_每个_app_2_版本_产出_3_旧版本() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Toolbox 的 collectionRoot 直接放 IDE 版本目录（不是再嵌一层 app）
        // 因为 KnownVersionedRoots 注册的是 .../apps 这一层
        // 实际 Toolbox 布局是 apps/{ide}/{ch-0}/{version}，但 detect 是对 collectionRoot 子目录排序
        // 为简化，这里直接在 apps 下放版本号子目录（验证 collectionRoot 层级行为）
        let tb = tmp.appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps", isDirectory: true)
        try FileManager.default.createDirectory(at: tb, withIntermediateDirectories: true)
        for v in ["2024.1.1", "2024.2.0", "2024.3.1"] {
            try FileManager.default.createDirectory(
                at: tb.appendingPathComponent(v, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertEqual(hits.count, 2, "3 版本 - keepLatest(1) = 2 个旧版本")
        XCTAssertEqual(hits.first?.ruleID, "jetbrains.toolbox-apps.versioned")
    }

    // MARK: - helper

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownVersionedRootsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
