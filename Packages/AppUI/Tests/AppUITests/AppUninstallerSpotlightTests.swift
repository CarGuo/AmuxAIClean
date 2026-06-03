import XCTest
@testable import AppUI

/// AppUninstaller —— Spotlight 兜底补刀测试（Step 11A / 2026-06）
///
/// 验证：[AppUninstaller.spotlightFallback](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppUninstaller.swift)
///
/// 测试主题：
/// 1. Spotlight 命中非典型路径 → 加入候选 + matchReason=.spotlight("bundleID")
/// 2. Spotlight 返回的路径已存在主路径中 → dedup 不重复添加
/// 3. Spotlight 返空 → candidatesAsync 正常返回主路径结果（fail-soft）
/// 4. Spotlight 命中的路径在 home/systemLibrary 之外 → 拒绝（防穿透 /System）
/// 5. appName 长度 < 4 / 命中常见噪音词 → 跳过 appName 谓词查询
final class AppUninstallerSpotlightTests: XCTestCase {

    // MARK: - Helpers

    /// In-memory FakeFM（与 [AppUninstallerTests.FakeFM](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Tests/AppUITests/AppUninstallerTests.swift)
    /// 同款思路）。
    private struct FakeFM: FileManagerSnapshotting {
        let entriesByRoot: [String: [FSEntry]]
        let snapshots: [String: FSSnapshot]

        func firstLevelEntries(at path: String) -> [FSEntry]? {
            entriesByRoot[path]
        }
        func snapshot(at path: String) -> FSSnapshot {
            snapshots[path] ?? .init(bytes: 0, fileCount: 0)
        }
    }

    /// FakeSpotlight：根据预设字典返回固定路径。
    private struct FakeSpotlight: SpotlightProbing {
        let byBundleID: [String: [String]]
        let byAppName: [String: [String]]
        func probeByBundleID(_ bundleID: String, timeout: TimeInterval) async -> [String] {
            byBundleID[bundleID] ?? []
        }
        func probeByAppName(_ appName: String, timeout: TimeInterval) async -> [String] {
            byAppName[appName] ?? []
        }
    }

    private let demoMeta = AppMetadata(
        bundleID: "com.acme.demo",
        bundleVendor: "com.acme",
        appName: "Demo",
        executableName: nil
    )

    // 长一点 + 非噪音词的 appName，用于 appName 谓词分支测试
    private let longNameMeta = AppMetadata(
        bundleID: "com.acme.unique",
        bundleVendor: "com.acme",
        appName: "AcmeUniqueApp",
        executableName: nil
    )

    // MARK: - 1. Spotlight 命中非典型路径

    func test_Spotlight命中非典型路径_补刀加入候选_matchReason为spotlight() async {
        let home = "/H"
        // 主路径所有 root 返空
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            // Spotlight 命中的非典型路径（不在主 12 root 第一层）
            "/H/Documents/AcmeData": .init(bytes: 9999, fileCount: 12)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: ["com.acme.demo": ["/H/Documents/AcmeData"]],
            byAppName: [:]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 1, "Spotlight 应补刀产出 1 条候选")
        let cand = result[0]
        XCTAssertEqual(cand.path, "/H/Documents/AcmeData")
        XCTAssertEqual(cand.bytes, 9999)
        XCTAssertEqual(cand.fileCount, 12)
        if case .spotlight(let kind) = cand.matchReason {
            XCTAssertEqual(kind, "bundleID", "matchReason 应携带谓词类别")
        } else {
            XCTFail("matchReason 应为 .spotlight(\"bundleID\")")
        }
    }

    // MARK: - 2. dedup 与主路径

    func test_Spotlight返回的路径已在主路径_dedup不重复添加() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        // 主路径下放一个 bundleID 严格相等命中（matchReason=.bundleID）
        let mainEntry = FSEntry(name: "com.acme.demo", path: "\(cachesPath)/com.acme.demo")
        let fake = FakeFM(
            entriesByRoot: [cachesPath: [mainEntry]],
            snapshots: [
                mainEntry.path: .init(bytes: 1000, fileCount: 5)
            ]
        )
        // Spotlight 返回**同一个**路径
        let spotlight = FakeSpotlight(
            byBundleID: ["com.acme.demo": [mainEntry.path]],
            byAppName: [:]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 1, "重复路径应去重")
        // 保留主路径的 matchReason，不被 spotlight 覆盖
        if case .bundleID = result[0].matchReason { } else {
            XCTFail("dedup 应保留主路径的 matchReason=.bundleID，而非被 spotlight 覆盖")
        }
    }

    // MARK: - 3. Spotlight 返空 fail-soft

    func test_Spotlight返空_candidatesAsync正常返回主路径结果() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        let mainEntry = FSEntry(name: "com.acme.demo", path: "\(cachesPath)/com.acme.demo")
        let fake = FakeFM(
            entriesByRoot: [cachesPath: [mainEntry]],
            snapshots: [mainEntry.path: .init(bytes: 100, fileCount: 1)]
        )
        let spotlight = FakeSpotlight(byBundleID: [:], byAppName: [:]) // 全返空
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 1, "Spotlight 返空不应影响主路径产出")
        XCTAssertEqual(result[0].path, mainEntry.path)
    }

    // MARK: - 4. 防穿透 /System 等无关路径

    func test_Spotlight命中home之外路径_拒绝加入候选() async {
        let home = "/H"
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            // 即便 fileManager 返非空，路径在 /System 也应被拒
            "/System/Library/Foo": .init(bytes: 1, fileCount: 1)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: ["com.acme.demo": ["/System/Library/Foo"]],
            byAppName: [:]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta)
        XCTAssertEqual(result.count, 0, "home/systemLibrary 之外的 spotlight 路径应被拒")
    }

    // MARK: - 5. appName 谓词分支：跳过短 / 噪音词

    func test_appName为常见噪音词_不发起appName谓词查询() async {
        // appName="Demo"（长度 4，但 lowercased 命中 noise list 里的 "demo"）→ 应跳过 appName 谓词
        let home = "/H"
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            "/H/Library/AppNameHit": .init(bytes: 1000, fileCount: 1)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: [:], // bundleID 不返
            byAppName: ["Demo": ["/H/Library/AppNameHit"]]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: demoMeta) // appName="Demo"
        XCTAssertEqual(result.count, 0, "噪音词 appName 应不触发 spotlight appName 谓词查询")
    }

    func test_appName长度足够且非噪音_发起appName谓词查询并补刀() async {
        let home = "/H"
        let fake = FakeFM(entriesByRoot: [:], snapshots: [
            "/H/Documents/AcmeUniqueAppData": .init(bytes: 5000, fileCount: 8)
        ])
        let spotlight = FakeSpotlight(
            byBundleID: [:], // bundleID 不返
            byAppName: ["AcmeUniqueApp": ["/H/Documents/AcmeUniqueAppData"]]
        )
        let unins = AppUninstaller(
            homeDirectory: home,
            systemLibrary: "/Library",
            fileManager: fake,
            spotlight: spotlight
        )

        let result = await unins.candidatesAsync(for: longNameMeta)
        XCTAssertEqual(result.count, 1, "长且非噪音 appName 应触发 appName 谓词补刀")
        if case .spotlight(let kind) = result[0].matchReason {
            XCTAssertEqual(kind, "appName")
        } else {
            XCTFail("matchReason 应为 .spotlight(\"appName\")")
        }
    }
}
