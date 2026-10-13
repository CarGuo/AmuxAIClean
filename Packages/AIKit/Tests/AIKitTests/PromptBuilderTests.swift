import XCTest
import SafetyKit
@testable import AIKit

final class PromptBuilderTests: XCTestCase {

    private func makeInquiry(path: String = "/Users/amuxuser/Library/Caches/foo",
                             verdict: SafetyVerdict = .safe) -> PathInquiry {
        PathInquiry(
            path: path,
            isDirectory: true,
            bytes: 12_345_678,
            fileCount: 42,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            verdict: verdict,
            vendorName: "TestVendor",
            vendorNote: "test reason",
            childPreview: ["a.bin", "b.log", "c"]
        )
    }

    func test_system_prompt_contains_hard_rules() {
        let sys = PromptBuilder.systemPrompt
        XCTAssertTrue(sys.contains("/System"), "system prompt 必须含硬禁路径")
        XCTAssertTrue(sys.contains("forbid"), "system prompt 必须把 forbid 作为输出枚举")
        XCTAssertTrue(sys.contains("JSON"), "system prompt 必须强制 JSON 输出")
    }

    func test_user_prompt_renders_all_fields() {
        let inquiry = makeInquiry()
        let user = PromptBuilder.renderUserPrompt(inquiry)
        XCTAssertTrue(user.contains("path: /Users/amuxuser/Library/Caches/foo"))
        XCTAssertTrue(user.contains("isDirectory: true"))
        XCTAssertTrue(user.contains("bytes: 12345678"))
        XCTAssertTrue(user.contains("fileCount: 42"))
        XCTAssertTrue(user.contains("localVerdict: safe"))
        XCTAssertTrue(user.contains("vendorName: TestVendor"))
        XCTAssertTrue(user.contains("vendorNote: test reason"))
        XCTAssertTrue(user.contains("childPreview: a.bin, b.log, c"))
    }

    func test_make_messages_two_roles_in_order() {
        let msgs = PromptBuilder().makeMessages(for: makeInquiry())
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .system)
        XCTAssertEqual(msgs[1].role, .user)
        XCTAssertEqual(msgs[0].content, PromptBuilder.systemPrompt)
    }

    // MARK: - AIAdviceClamp 红线契约

    func test_clamp_local_forbid_overrides_ai_safe() {
        let inquiry = makeInquiry(verdict: .forbid)
        let aiSays = AIAdvice(summary: "看起来没问题",
                              canDelete: .safe,
                              reason: "AI 主观觉得安全",
                              sideEffects: [])
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped.canDelete, .forbid)
        // 产品契约：clamp 降级时贴 sentinel prefix，UI 层再替换为本地化文案。
        XCTAssertTrue(clamped.reason.hasPrefix(AIAdviceClamp.localPolicyOverridePrefix),
                      "实际=\(clamped.reason)")
    }

    func test_clamp_hard_forbid_prefix_overrides_ai_safe() {
        let inquiry = makeInquiry(path: "/System/Library/Foo", verdict: .safe)
        let aiSays = AIAdvice(summary: "is cache", canDelete: .safe, reason: "x", sideEffects: [])
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped.canDelete, .forbid, "/System 前缀必须强制 forbid")
    }

    func test_clamp_noop_when_local_safe_and_ai_safe() {
        let inquiry = makeInquiry(verdict: .safe)
        let aiSays = AIAdvice(summary: "x", canDelete: .safe, reason: "ok", sideEffects: ["重建缓存"])
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped, aiSays, "无需 clamp 的场景应原样返回")
    }

    func test_clamp_hard_forbid_path_detection() {
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/System"))
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/System/Library/x"))
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/usr/local/bin"))
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/private/var/db/foo"))
        // Review fix #3，2026-06-15：clamp 现在复用 SafetyEngine.hardForbidPrefixes
        // 单一真相源；SafetyEngine 把 /Applications 也列为硬禁（"不允许通过本工具删 App"），
        // 所以 /Applications/Safari.app 也会被钳。这是**变严**，安全侧期望。
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/Applications/Safari.app"),
                      "/Applications/* 也在 SafetyEngine 硬禁名单内（不通过本工具删 App）")
        // Review fix #3：system prompt 承诺 /private/var 整段 forbid → 这里覆盖
        // /private/var/folders 等 SafetyEngine 不锁的系统私有路径。
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/private/var/folders/abc/T"),
                      "/private/var/* 在 AI clamp 中被宽前缀覆盖（system prompt 承诺）")
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/System/Volumes/Data"))
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/system/volumes/data/private/var/folders/abc/T"))
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/PRIVATE/VAR/db/foo"))
        XCTAssertTrue(AIAdviceClamp.pathIsHardForbid("/Users/otheruser/.ssh/id_rsa"))
        XCTAssertFalse(AIAdviceClamp.pathIsHardForbid("/Users/amuxuser/Library/Caches/foo"))
        XCTAssertFalse(AIAdviceClamp.pathIsHardForbid("/Systemic"), "前缀必须严格匹配，不允许误吃")
    }

    func test_clamp_local_confirm_clamps_ai_safe_to_confirm() {
        let inquiry = makeInquiry(path: "/Users/amuxuser/Documents/report.pdf", verdict: .confirm)
        let aiSays = AIAdvice(summary: "文档", canDelete: .safe, reason: "AI 误判为 safe", sideEffects: [])
        let clamped = AIAdviceClamp.clamp(aiSays, against: inquiry)
        XCTAssertEqual(clamped.canDelete, .confirm, "本地 confirm 时 AI 返回 safe 必须被钳制回 confirm")
        XCTAssertTrue(clamped.reason.hasPrefix(AIAdviceClamp.localPolicyOverridePrefix))
    }
}
