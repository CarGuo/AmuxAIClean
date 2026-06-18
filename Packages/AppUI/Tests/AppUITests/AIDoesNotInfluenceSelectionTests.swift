import XCTest
import AIKit
import SafetyKit
@testable import AppUI

/// v1.6 跨包契约：AI 模块不得越权影响本地三档闸 / 行勾选权威。
///
/// 背景：M5 接入 AIKit 后，AI 给出的 `AIAdvice.canDelete` 只是"参考意见"——
/// 本地 [SafetyEngine](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)
/// 仍是删除/勾选的**唯一权威**。这套测试把红线钉死：
///
/// 1. `RowItem.isSelectable` / `defaultSelected` **只**由 `verdict` 决定，AIAdvice 不参与；
/// 2. 即使 AI 把 `.forbid` 路径回成 `.safe`，[AIAdviceClamp](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/PromptBuilder.swift)
///    必须强制回写到 `.forbid`（本地优先）；
/// 3. 硬禁路径前缀（/System, /usr, /Library/Apple 等）即使 AI 判 `.safe`，clamp 也必须降到 `.forbid`。
@MainActor
final class AIDoesNotInfluenceSelectionTests: XCTestCase {

    // MARK: - 1. RowItem 勾选权威仅来自 verdict

    func test_RowItem_forbid_永远不可勾_且默认不选() {
        let row = makeRow(path: "/Library/Apple/Safari.app", verdict: .forbid)
        XCTAssertFalse(row.isSelectable, "verdict=.forbid 必须 isSelectable=false")
        XCTAssertFalse(row.defaultSelected, "verdict=.forbid 必须 defaultSelected=false")
    }

    func test_RowItem_confirm_可勾_但默认不选() {
        let row = makeRow(path: "/Users/x/Library/Caches/Foo", verdict: .confirm)
        XCTAssertTrue(row.isSelectable, "verdict=.confirm 用户可勾")
        XCTAssertFalse(row.defaultSelected, "verdict=.confirm 默认不选，需用户手动")
    }

    func test_RowItem_safe_可勾_且默认勾上() {
        let row = makeRow(path: "/Users/x/Library/Caches/Spotify", verdict: .safe)
        XCTAssertTrue(row.isSelectable)
        XCTAssertTrue(row.defaultSelected)
    }

    // MARK: - 2. AIAdviceClamp：本地 forbid 永远压住 AI 的 safe

    func test_AIClamp_本地verdictForbid_AI说safe_仍被夹回forbid() {
        // AI 给的乐观建议
        let aiSays = AIAdvice(
            summary: "Looks fine",
            canDelete: .safe,
            reason: "AI thinks it's user-installed",
            sideEffects: []
        )
        let inquiry = makeInquiry(
            path: "/Users/alice/Library/Caches/SomeImportantThing",
            verdict: .forbid
        )
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped.canDelete, .forbid,
                       "inquiry.verdict=.forbid 时，AI 即使说 safe 也必须降为 forbid")
        XCTAssertTrue(clamped.reason.contains("本地安全策略"),
                      "降级时必须在 reason 前缀贴本地安全策略标签")
    }

    func test_AIClamp_硬禁前缀_System_AI说confirm_仍被夹回forbid() {
        let aiSays = AIAdvice(summary: "system", canDelete: .confirm, reason: "x", sideEffects: [])
        let inquiry = makeInquiry(
            path: "/System/Library/Frameworks/Foo.framework",
            verdict: .confirm
        )
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped.canDelete, .forbid,
                       "/System/* 在硬禁前缀名单内")
    }

    func test_AIClamp_硬禁前缀_LibraryApple_AI说safe_仍被夹回forbid() {
        let aiSays = AIAdvice(summary: "x", canDelete: .safe, reason: "x", sideEffects: [])
        let inquiry = makeInquiry(
            path: "/Library/Apple/Library/Bundles/Foo.bundle",
            verdict: .safe
        )
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped.canDelete, .forbid)
    }

    func test_AIClamp_硬禁前缀_usr_AI说safe_仍被夹回forbid() {
        let aiSays = AIAdvice(summary: "x", canDelete: .safe, reason: "x", sideEffects: [])
        let inquiry = makeInquiry(path: "/usr/local/bin/foo", verdict: .safe)
        XCTAssertEqual(AIAdviceClamp.clamp(aiSays, against: inquiry).canDelete, .forbid)
    }

    /// Review fix #3，2026-06-15：system prompt 第 1 条对 AI 承诺"/private/var
    /// 开头一律 forbid"，但旧版 clamp 只锁了 `/private/var/db`、`/private/var/protected`，
    /// 漏放了 `/private/var/folders/<hash>/T/...` 等系统私有路径（AI 若误判 .safe 不会被钳回）。
    /// 修复后 clamp 直接覆盖整个 `/private/var` 与 `/var` 前缀。
    func test_AIClamp_硬禁前缀_privateVarFolders_AI说safe_仍被夹回forbid() {
        let aiSays = AIAdvice(summary: "x", canDelete: .safe, reason: "x", sideEffects: [])
        let inquiry = makeInquiry(
            path: "/private/var/folders/abc/xyz/T/com.apple.cache",
            verdict: .safe
        )
        XCTAssertEqual(AIAdviceClamp.clamp(aiSays, against: inquiry).canDelete, .forbid,
                       "/private/var/folders/* 必须被 AI clamp 钳成 forbid")
    }

    func test_AIClamp_硬禁前缀_varDb_AI说safe_仍被夹回forbid() {
        let aiSays = AIAdvice(summary: "x", canDelete: .safe, reason: "x", sideEffects: [])
        let inquiry = makeInquiry(path: "/var/db/dyld/foo", verdict: .safe)
        XCTAssertEqual(AIAdviceClamp.clamp(aiSays, against: inquiry).canDelete, .forbid)
    }

    func test_AIClamp_硬禁前缀_Applications_AI说safe_仍被夹回forbid() {
        // /Applications 在 SafetyEngine.hardForbidPrefixes 内（不允许通过本工具删 App）。
        // 复用 SafetyEngine 列表后，AI clamp 自动覆盖。
        let aiSays = AIAdvice(summary: "x", canDelete: .safe, reason: "x", sideEffects: [])
        let inquiry = makeInquiry(path: "/Applications/Xcode.app", verdict: .safe)
        XCTAssertEqual(AIAdviceClamp.clamp(aiSays, against: inquiry).canDelete, .forbid)
    }

    /// 直接验证 AIAdviceClamp.pathIsHardForbid 与 SafetyEngine.hardForbidPrefixes
    /// 真的保持"AI 侧 ⊇ SafetyEngine 侧"的超集关系——未来若有人在 SafetyEngine
    /// 新增前缀但忘了同步，AI clamp 仍会自动覆盖（因为是直接 reference 同一份列表）。
    func test_AIClamp_硬禁列表_是SafetyEngine超集() {
        for p in SafetyEngine.hardForbidPrefixes {
            // 取一个子路径形式，确保覆盖 hasPrefix 路径，而不是单纯等值。
            let probe = p + "/__ai_clamp_probe__"
            XCTAssertTrue(AIAdviceClamp.pathIsHardForbid(probe),
                          "AIAdviceClamp 必须覆盖 SafetyEngine 的前缀 \(p)；列表已 drift")
        }
    }

    // MARK: - 3. AIAdviceClamp：用户目录下 AI 建议透传（不该过度收紧）

    func test_AIClamp_用户Caches_AI建议透传() {
        let inquiry = makeInquiry(
            path: "/Users/alice/Library/Caches/Spotify",
            verdict: .safe
        )
        let safe = AIAdvice(summary: "spotify cache", canDelete: .safe, reason: "ok", sideEffects: [])
        XCTAssertEqual(AIAdviceClamp.clamp(safe, against: inquiry).canDelete, .safe)

        let confirm = AIAdvice(summary: "cache", canDelete: .confirm, reason: "may resign-in", sideEffects: [])
        XCTAssertEqual(AIAdviceClamp.clamp(confirm, against: inquiry).canDelete, .confirm)
    }

    // MARK: - 4. 端到端契约：AIAdvice 不能反向写入 RowItem

    func test_RowItem_为值类型_AI无法mutate() {
        // RowItem 是 struct，外部完全无法通过引用回写。这条测试本质是个类型约束守护：
        // 如果有人把 RowItem 改成 class，AI 回调会有 mutation 风险。
        let row = makeRow(path: "/Users/x/Library/Caches/Foo", verdict: .confirm)
        let mirror = Mirror(reflecting: row)
        XCTAssertEqual(mirror.displayStyle, .struct,
                       "RowItem 必须保持 value type；如改 class，AI 回调会有 mutation 风险")
    }

    // MARK: - Helpers

    private func makeRow(path: String, verdict: SafetyVerdict) -> RowItem {
        let url = URL(fileURLWithPath: path)
        return RowItem(
            id: path,
            url: url,
            title: url.lastPathComponent,
            isDirectory: true,
            bytes: 1024,
            logicalBytes: 1024,
            fileCount: 1,
            verdict: verdict,
            rejection: .ok
        )
    }

    private func makeInquiry(path: String, verdict: SafetyVerdict) -> PathInquiry {
        PathInquiry(
            path: path,
            isDirectory: true,
            bytes: 1024,
            fileCount: 1,
            modificationDate: nil,
            verdict: verdict,
            vendorName: nil,
            vendorNote: nil,
            childPreview: []
        )
    }
}
