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

    func test_entries_包含_Android_SDK_三条_keepLatest_2_且_semverPreferred() throws {
        let androidPaths = [
            "Library/Android/sdk/build-tools",
            "Library/Android/sdk/platforms",
            "Library/Android/sdk/system-images",
        ]
        for p in androidPaths {
            guard let entry = KnownVersionedRoots.entries.first(where: { $0.relativePath == p }) else {
                XCTFail("缺失 Android SDK entry：\(p)")
                continue
            }
            XCTAssertEqual(entry.keepLatest, 2, "\(p) keepLatest 应为 2（DEVELOPER_ONE_CLICK_PLAN §3）")
            if case .semverPreferred = entry.ordering {} else {
                XCTFail("\(p) 应使用 semverPreferred 才能正确比较 34.0.0 / android-34 / android-34-ext10")
            }
            XCTAssertTrue(entry.ruleID.hasPrefix("android.sdk-"),
                          "\(p) ruleID 应以 android.sdk- 开头，便于 UI 聚合")
        }
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

    func test_scanAll_Toolbox真实IDE布局_不误删产品目录_仅回收ch0内旧版本() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tb = tmp.appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps", isDirectory: true)
        for (ide, versions) in [
            ("IDEA-U", ["241.14494.240", "242.20224.300"]),
            ("PyCharm-P", ["242.21829.153"]),
            ("WebStorm", ["241.15989.105", "242.20224.342"])
        ] {
            let ch0 = tb.appendingPathComponent(ide, isDirectory: true)
                .appendingPathComponent("ch-0", isDirectory: true)
            try FileManager.default.createDirectory(at: ch0, withIntermediateDirectories: true)
            for v in versions {
                try FileManager.default.createDirectory(
                    at: ch0.appendingPathComponent(v, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        let hitNames = Set(hits.map(\.versionName))
        XCTAssertEqual(hitNames, ["241.14494.240", "241.15989.105"],
                       "只应回收各 IDE ch-0 通道内的旧版本，绝不能把 IDEA-U / PyCharm-P 产品目录当作旧版本")
        let groupKeys = Set(hits.compactMap(\.groupKey))
        XCTAssertEqual(groupKeys, ["IDEA-U", "WebStorm"])
    }

    func test_scanAll_构造_Android_SDK_build_tools_5_版本_keepLatest_2_产出_3_旧版本() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bt = tmp.appendingPathComponent("Library/Android/sdk/build-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: bt, withIntermediateDirectories: true)
        // 真实样本：build-tools 子目录名是纯 semver
        for v in ["30.0.3", "31.0.0", "33.0.1", "34.0.0", "35.0.0"] {
            try FileManager.default.createDirectory(
                at: bt.appendingPathComponent(v, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertEqual(hits.count, 3, "5 版本 - keepLatest(2) = 3 个旧版本")
        let oldNames = Set(hits.map(\.versionName))
        XCTAssertEqual(oldNames, ["30.0.3", "31.0.0", "33.0.1"],
                       "应保留 34.0.0 / 35.0.0 两个最新版本")
        for h in hits {
            XCTAssertEqual(h.ruleID, "android.sdk-build-tools.versioned")
            XCTAssertEqual(h.retainedLatest, "35.0.0",
                           "retainedLatest 应记录最大版本 35.0.0")
        }
    }

    func test_scanAll_构造_Android_SDK_platforms_含_android_dash_前缀_semver_正确识别() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pl = tmp.appendingPathComponent("Library/Android/sdk/platforms", isDirectory: true)
        try FileManager.default.createDirectory(at: pl, withIntermediateDirectories: true)
        // 真实样本：platforms 子目录名带 `android-` 前缀
        for v in ["android-30", "android-33", "android-34", "android-35"] {
            try FileManager.default.createDirectory(
                at: pl.appendingPathComponent(v, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertEqual(hits.count, 2, "4 版本 - keepLatest(2) = 2 个旧版本")
        let oldNames = Set(hits.map(\.versionName))
        // semverPreferred 会提取首段 [0-9.]+ 切片做 compareNumeric；
        // `android-` 是前缀，semver 解析失败时 fallback 字典序。
        // 字典序结果：android-30 < android-33 < android-34 < android-35
        // 因此最旧两版应该是 android-30 / android-33
        XCTAssertEqual(oldNames, ["android-30", "android-33"])
        for h in hits {
            XCTAssertEqual(h.ruleID, "android.sdk-platforms.versioned")
        }
    }

    func test_scanAll_ToolboxDirectAndCh0OrphanPluginsDoNotEvictActiveIDE() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tb = tmp.appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps", isDirectory: true)
        // 1) Direct version layout directly under Toolbox/apps: 1 active version + 1 companion .plugins + 1 higher orphan .plugins
        try FileManager.default.createDirectory(at: tb.appendingPathComponent("242.20224.300"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tb.appendingPathComponent("242.20224.300.plugins"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tb.appendingPathComponent("243.99999.1.plugins"), withIntermediateDirectories: true)

        // 2) ch-0 layout under PyCharm-Ch0: 1 active version + 1 companion .plugins
        let ch0 = tb.appendingPathComponent("PyCharm-Ch0/ch-0", isDirectory: true)
        try FileManager.default.createDirectory(at: ch0.appendingPathComponent("242.21829.153"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ch0.appendingPathComponent("242.21829.153.plugins"), withIntermediateDirectories: true)

        let hits = KnownVersionedRoots.scanAll(home: tmp)
        XCTAssertEqual(hits.map(\.versionName), ["243.99999.1.plugins"],
                       "Direct 与 ch-0 布局下均不得将唯一活跃 IDE 本体或其同版本 .plugins 误判为旧版本")
        XCTAssertEqual(hits.first?.retainedLatest, "242.20224.300")
    }

    // MARK: - helper

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownVersionedRootsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
