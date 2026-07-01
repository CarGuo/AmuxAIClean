import XCTest
@testable import ScanKit

/// AndroidWorkflow 卡片注入测试。
///
/// 设计动机：与 [AppleWorkflowCardsTests] 同构——用 tmp 目录构造伪 home，
/// 不依赖真实 `~/.gradle` / `~/.android`，避免在 CI / 本地真机上互相污染。
///
/// 测试矩阵：
/// 1. 空 home：所有 Android 根都不存在 → 大前提 guard 触发 → 0 卡
/// 2. 仅 `~/.gradle` 存在：只出 gradle-caches / gradle-daemon 两张
/// 3. 仅 `~/.android` + build-cache + cache + avd 子目录存在：
///    出 .android 系列 3 张（含 AVD）；SDK 3 张 + JetBrains 2 张属于无条件输出，不纳入计数断言
/// 4. 全部目录存在：10 张齐出 + ID 全局唯一
/// 5. sdk-system-images 风险等级必须 confirm（与单镜像数 GB 不可逆删除语义对齐）
final class AndroidWorkflowCardsTests: XCTestCase {

    // MARK: - 1. 空 home

    func test_空home_无任何卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 不造任何子目录：大前提 guard 应直接返回 []
        let cards = AndroidWorkflow().cards(home: home)
        XCTAssertTrue(cards.isEmpty, "空 home 必须返回 0 卡，避免污染 UI 入口")
    }

    // MARK: - 2. 仅 gradle 存在

    func test_仅gradle存在_出2张gradle卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try makeDir(at: ".gradle", in: home)

        let cards = AndroidWorkflow().cards(home: home)
        let ids = Set(cards.map(\.id))

        // 仅 .gradle 存在：.android 系列 0 张 + SDK 3 张（无条件）+ JetBrains 2 张（glob 无法预检，无条件）
        // 因此总卡数 = 2 gradle + 3 SDK + 2 JetBrains = 7 张
        XCTAssertEqual(cards.count, 7,
                       "仅 .gradle 存在时：2 gradle + 3 SDK + 2 JetBrains = 7 张")
        XCTAssertTrue(ids.contains("card.android.gradle-caches"))
        XCTAssertTrue(ids.contains("card.android.gradle-daemon"))

        // 反向断言：.android 系列三卡均不出
        XCTAssertFalse(ids.contains("card.android.android-build-cache"))
        XCTAssertFalse(ids.contains("card.android.android-cache"))
        XCTAssertFalse(ids.contains("card.android.android-avd"))

        // gradle 两卡核心契约
        let caches = try XCTUnwrap(cards.first(where: { $0.id == "card.android.gradle-caches" }))
        XCTAssertEqual(caches.risk, .safe)
        XCTAssertEqual(caches.recipe, .filesystem)
        if case .literal(let paths) = caches.source {
            XCTAssertEqual(paths, ["~/.gradle/caches"], "literal 路径必须保留 ~/ 形式由 UI 层 expand")
        } else {
            XCTFail("gradle-caches 必须使用 .literal 源")
        }
    }

    // MARK: - 3. 仅 .android 存在

    func test_仅android存在_出含avd在内的3张android卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 造 ~/.android + 三个子目录：build-cache / cache / avd
        try makeDir(at: ".android", in: home)
        try makeDir(at: ".android/build-cache", in: home)
        try makeDir(at: ".android/cache", in: home)
        try makeDir(at: ".android/avd", in: home)

        let cards = AndroidWorkflow().cards(home: home)
        let ids = Set(cards.map(\.id))

        // 核心断言：3 张 .android 卡均出，且含 AVD
        XCTAssertTrue(ids.contains("card.android.android-build-cache"))
        XCTAssertTrue(ids.contains("card.android.android-cache"))
        XCTAssertTrue(ids.contains("card.android.android-avd"), "AVD 子目录存在时必须出 AVD 卡")

        // 反向：gradle 系列不出
        XCTAssertFalse(ids.contains("card.android.gradle-caches"))
        XCTAssertFalse(ids.contains("card.android.gradle-daemon"))

        // AVD 必须 confirm（删除前需用户确认）
        let avd = try XCTUnwrap(cards.first(where: { $0.id == "card.android.android-avd" }))
        XCTAssertEqual(avd.risk, .confirm, "AVD 删除不可逆，必须 confirm")
        // 产品契约：DeveloperCard.title 存 xcstrings raw key，UI 层用 LocalizedStringKey 消费。
        XCTAssertEqual(avd.title, "card.android.android-avd.title")
        XCTAssertFalse(avd.summary.isEmpty)
        if case .literal(let paths) = avd.source {
            XCTAssertEqual(paths, ["~/.android/avd"])
        } else {
            XCTFail("AVD 必须使用 .literal 源")
        }
    }

    // MARK: - 4. 全部目录存在

    func test_全部目录存在_出齐10张卡() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for sub in [
            ".gradle",
            ".android",
            ".android/build-cache",
            ".android/cache",
            ".android/avd",
            // JetBrains 两张卡的预检父目录（路径含 glob *，本身不预检子目录）
            "Library/Caches/Google",
            "Library/Logs/Google",
            // SDK 三张走 versionedRoot 不预检，但造个父目录便于"大前提"通过
            "Library/Android/sdk",
        ] {
            try makeDir(at: sub, in: home)
        }

        let cards = AndroidWorkflow().cards(home: home)
        XCTAssertEqual(cards.count, 10, "全部目录存在时必须出齐 10 卡（工厂顺序 1-10）")

        let ids = cards.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "卡片 ID 必须全局唯一")

        let expectedIDs: Set<String> = [
            "card.android.gradle-caches",
            "card.android.gradle-daemon",
            "card.android.android-build-cache",
            "card.android.android-cache",
            "card.android.android-avd",
            "card.android.sdk-build-tools",
            "card.android.sdk-platforms",
            "card.android.sdk-system-images",
            "card.android.jetbrains-androidstudio-caches",
            "card.android.jetbrains-androidstudio-logs",
        ]
        XCTAssertEqual(Set(ids), expectedIDs, "10 张卡 ID 必须与设计文档对位")

        // 工厂顺序断言：1-10 与文档保持一致
        let expectedOrder: [String] = [
            "card.android.gradle-caches",
            "card.android.gradle-daemon",
            "card.android.android-build-cache",
            "card.android.android-cache",
            "card.android.android-avd",
            "card.android.sdk-build-tools",
            "card.android.sdk-platforms",
            "card.android.sdk-system-images",
            "card.android.jetbrains-androidstudio-caches",
            "card.android.jetbrains-androidstudio-logs",
        ]
        XCTAssertEqual(ids, expectedOrder, "工厂顺序必须按 1-10 排列")

        // summary 文案保护：非空 + 长度可控
        for card in cards {
            XCTAssertFalse(card.title.isEmpty, "title 不能为空：\(card.id)")
            XCTAssertFalse(card.summary.isEmpty, "summary 不能为空：\(card.id)")
            XCTAssertLessThanOrEqual(card.summary.count, 80, "summary 应 ≤ 80 字：\(card.id)")
        }
    }

    // MARK: - 5. system-images risk

    func test_sdk_system_images_risk_是_confirm() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 大前提通过即可（SDK 卡无条件输出）
        try makeDir(at: ".gradle", in: home)

        let cards = AndroidWorkflow().cards(home: home)
        let sysImg = try XCTUnwrap(cards.first(where: { $0.id == "card.android.sdk-system-images" }),
                                   "sdk-system-images 卡必须输出")
        XCTAssertEqual(sysImg.risk, .confirm, "system-images 单镜像 1~3 GB 删除不可逆，必须 confirm")
        XCTAssertEqual(sysImg.recipe, .filesystem)
        if case .versionedRoot(let ruleID) = sysImg.source {
            XCTAssertEqual(ruleID, "android.sdk-system-images.versioned",
                           "必须复用 KnownVersionedRoots ruleID")
        } else {
            XCTFail("sdk-system-images 必须使用 .versionedRoot 源")
        }

        // 另外两张 SDK 卡应为 safe（仅 system-images 是 confirm）
        let buildTools = try XCTUnwrap(cards.first(where: { $0.id == "card.android.sdk-build-tools" }))
        XCTAssertEqual(buildTools.risk, .safe)
        let platforms = try XCTUnwrap(cards.first(where: { $0.id == "card.android.sdk-platforms" }))
        XCTAssertEqual(platforms.risk, .safe)
    }

    // MARK: - helper

    private func makeTmpHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidWorkflowCardsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(at relativePath: String, in home: URL) throws {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
