import XCTest
@testable import ScanKit

/// v1.7 PR-3 新增：[KnownVersionedRoots] groupingRegex 分组扫描行为契约。
///
/// 与 [KnownVersionedRootsTests] 互补：
/// - 前者测既有非分组（nil groupingRegex）行为；
/// - 本文件测分组（JetBrains 跨产品场景）+ 降级保护。
///
/// 关键不变式：
/// 1. 旧 entries（groupingRegex=nil）行为完全不变 → 已由 [KnownVersionedRootsTests] 覆盖；
/// 2. JetBrains Caches/AppSupport/Logs 三条 entries 必须存在且 groupingRegex 非空；
/// 3. 同 root 下并存多产品时，IDEA 2024.1/2/3 应触发旧版淘汰，
///    PyCharm 单版应**不被识别**；
/// 4. 未匹配子目录（无版本号、隐藏文件）被忽略不报错；
/// 5. groupingRegex 编译失败 → warn 一行后**降级为旧行为**，不抛不丢扫描。
final class KnownVersionedRootsGroupingTests: XCTestCase {

    // MARK: - entries 静态契约（PR-3）

    func test_PR3_entries_包含_JetBrains_Caches_AppSupport_Logs_三条_且_groupingRegex_非空() throws {
        let expectedPaths = [
            "Library/Caches/JetBrains",
            "Library/Application Support/JetBrains",
            "Library/Logs/JetBrains",
        ]
        for p in expectedPaths {
            guard let entry = KnownVersionedRoots.entries.first(where: { $0.relativePath == p }) else {
                XCTFail("PR-3 缺失 JetBrains entry：\(p)")
                continue
            }
            XCTAssertNotNil(entry.groupingRegex,
                            "\(p) 必须带 groupingRegex 才能跨产品分组")
            XCTAssertEqual(entry.keepLatest, 1,
                           "\(p) keepLatest 应为 1（JetBrains 年版更新场景）")
            if case .semverPreferred = entry.ordering {} else {
                XCTFail("\(p) ordering 应为 semverPreferred 才能比较 2024.1 / 2024.2")
            }
            XCTAssertTrue(entry.ruleID.hasPrefix("jetbrains."),
                          "\(p) ruleID 应以 jetbrains. 开头，便于 UI 聚合")
        }
    }

    func test_PR3_JetBrains_entries_与_Toolbox_entry_路径互不重叠() throws {
        // PITFALL: 防御 Toolbox apps 与 Caches/AppSupport 共享 ~/Library/Application Support/JetBrains 父路径，
        // 但精确 relativePath 必须互斥避免某条 entry 把 Toolbox 子目录又匹配一次。
        let toolboxPath = "Library/Application Support/JetBrains/Toolbox/apps"
        let appSupportPath = "Library/Application Support/JetBrains"
        XCTAssertTrue(toolboxPath.hasPrefix(appSupportPath),
                      "Toolbox 在 AppSupport 之下属预期")
        // groupingRegex 是 `^([A-Za-z]+)\d{4}\.\d+$`，
        // `Toolbox` 不带年版号 → fullMatch 失败 → 不会被 jetbrains.app-support 误识别。
        // 这里以一次实际扫描验证。
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appSupport = tmp.appendingPathComponent(appSupportPath, isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        // 仅造 Toolbox 子目录（不带年版号）+ 一条已注册但未匹配正则的 consentOptions
        for n in ["Toolbox", "consentOptions"] {
            try FileManager.default.createDirectory(
                at: appSupport.appendingPathComponent(n, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp).filter {
            $0.ruleID == "jetbrains.app-support.versioned-per-product"
        }
        XCTAssertTrue(hits.isEmpty,
                      "AppSupport/JetBrains 下仅有非版本目录（Toolbox / consentOptions），不应有命中")
    }

    // MARK: - 分组扫描行为

    func test_分组_IDEA_3版_PyCharm_单版_仅_IDEA_产出旧版() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let caches = tmp.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        // IDEA 3 版 + PyCharm 1 版 + WebStorm 2 版
        for n in [
            "IntelliJIdea2024.1", "IntelliJIdea2024.2", "IntelliJIdea2024.3",
            "PyCharm2024.2",
            "WebStorm2024.1", "WebStorm2024.2",
        ] {
            try FileManager.default.createDirectory(
                at: caches.appendingPathComponent(n, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let hits = KnownVersionedRoots.scanAll(home: tmp).filter {
            $0.ruleID == "jetbrains.caches.versioned-per-product"
        }

        // IDEA 3 版 - keepLatest(1) = 2 个旧版
        // PyCharm 1 版 → 不到淘汰阈值 0 个
        // WebStorm 2 版 - 1 = 1 个旧版
        let ideaHits = hits.filter { $0.versionName.hasPrefix("IntelliJIdea") }
        let pyHits = hits.filter { $0.versionName.hasPrefix("PyCharm") }
        let wsHits = hits.filter { $0.versionName.hasPrefix("WebStorm") }

        XCTAssertEqual(ideaHits.count, 2, "IDEA 应淘汰 2024.1 / 2024.2")
        XCTAssertEqual(pyHits.count, 0, "PyCharm 仅一版，应保留")
        XCTAssertEqual(wsHits.count, 1, "WebStorm 应淘汰 2024.1")

        XCTAssertEqual(Set(ideaHits.map(\.versionName)),
                       ["IntelliJIdea2024.1", "IntelliJIdea2024.2"])
        XCTAssertEqual(wsHits.first?.versionName, "WebStorm2024.1")

        // 产品契约：displayName 存 xcstrings raw key（如 versioned-root.jetbrains.caches.displayName），
        // UI 层用 LocalizedStringKey 消费。原始 group key（"IntelliJIdea"/"WebStorm"）通过 Hit.groupKey 暴露。
        XCTAssertTrue(ideaHits.allSatisfy { $0.groupKey == "IntelliJIdea" })
        XCTAssertTrue(wsHits.allSatisfy { $0.groupKey == "WebStorm" })
    }

    func test_分组_未匹配子目录_隐藏文件_无版本号目录_全部被忽略() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let caches = tmp.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        // 三类应被忽略的子目录 + 一个真实匹配的 IDEA（单版 不会淘汰）
        for n in [".DS_Store_dir", "Toolbox", "consentOptions", "IntelliJIdea2024.1"] {
            try FileManager.default.createDirectory(
                at: caches.appendingPathComponent(n, isDirectory: true),
                withIntermediateDirectories: true)
        }
        // 真正的隐藏文件
        let dsStore = caches.appendingPathComponent(".DS_Store")
        FileManager.default.createFile(atPath: dsStore.path, contents: Data())

        let hits = KnownVersionedRoots.scanAll(home: tmp).filter {
            $0.ruleID == "jetbrains.caches.versioned-per-product"
        }
        XCTAssertTrue(hits.isEmpty,
                      "未匹配 + 隐藏文件 + 单版本均不应产生命中")
    }

    // MARK: - 旧行为回归（防回归）

    func test_旧行为_DeviceSupport_4版_保留2_等同_KnownVersionedRootsTests() throws {
        let tmp = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ds = tmp.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: ds, withIntermediateDirectories: true)
        for v in ["15.0 (19A346)", "16.4 (20E247)", "17.5 (21F79)", "18.0 (22A348)"] {
            try FileManager.default.createDirectory(
                at: ds.appendingPathComponent(v, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let hits = KnownVersionedRoots.scanAll(home: tmp).filter {
            $0.ruleID == "apple.ios-device-support.versioned"
        }
        // 旧 entry（groupingRegex=nil）行为不变
        XCTAssertEqual(hits.count, 2)
    }

    // MARK: - helper

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KVRGroupingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
