import Foundation
import SafetyKit

/// M5 / 2026-06：内置提示词构造。**整 App 只此一处**生成 prompt——
/// 不允许 UI 暴露自由 prompt 编辑，防止 prompt injection 弱化本地 SafetyEngine 红线。
///
/// 决策来源：[docs/MOLE_ALIGNMENT.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/MOLE_ALIGNMENT.md) §M5
/// "按需触发"路线——一个 system + 一个 user，纯 JSON 输出，不做流式。
public struct PromptBuilder: Sendable {

    public init() {}

    /// 构造一对 (system, user) 消息。
    /// **不**包含去敏——调用方应在传入前把 [PathInquiry.path](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/PathInquiry.swift#L17)
    /// 与 [childPreview](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/PathInquiry.swift#L43)
    /// 先过 [PathRedactor](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/PathRedactor.swift) 处理；
    /// 这样 PromptBuilder 自身保持纯函数，无 IO 无网络。
    public func makeMessages(for inquiry: PathInquiry) -> [ChatMessage] {
        let system = ChatMessage(role: .system, content: Self.systemPrompt)
        let user = ChatMessage(role: .user, content: Self.renderUserPrompt(inquiry))
        return [system, user]
    }

    // MARK: - System Prompt（硬编码红线）

    public static let systemPrompt: String = """
    你是一名 macOS 文件清理领域的资深助理。你的任务是根据给定的文件/目录元数据，
    判断它"是什么、能否删除、删后有什么副作用"，并**只返回一段 JSON**，不能包含
    其它任何文字、Markdown 包裹、解释、前缀或后缀。

    返回 JSON schema（严格）：
    {
      "summary": "<= 80 字的一句话定性，中文",
      "canDelete": "safe" | "confirm" | "forbid",
      "reason": "<= 200 字的简要原因，中文",
      "sideEffects": ["删除后果短句", ...]
    }

    硬规则（**违反任意一条都会被本地后置校验强制覆盖**）：
    1. 路径以 /System、/Library/Apple、/private/var、/usr、/bin、/sbin、/etc 开头：
       canDelete 必须为 "forbid"。
    2. 输入字段 "localVerdict" 已是 "forbid"：canDelete 必须 echo "forbid"。
    3. 含 SSH/GPG/AWS/GitHub/npm 等凭证子串（.ssh、.gnupg、.aws、credentials、
       token、keychain、Provisioning Profiles）：canDelete 必须为 "forbid"。
    4. 不确定 / 信息不足 → 选 "confirm"，绝不主观选 "safe"。
    5. 输出 reason 不要复述路径（用户已知），只解释"是什么 / 为什么这么判"。
    6. sideEffects 必须是动词短语，例："下次启动会重建该缓存"。

    回复语言：始终中文。
    """

    // MARK: - User Prompt 渲染

    public static func renderUserPrompt(_ inquiry: PathInquiry) -> String {
        var lines: [String] = []
        lines.append("path: \(inquiry.path)")
        lines.append("isDirectory: \(inquiry.isDirectory)")
        lines.append("bytes: \(inquiry.bytes)")
        lines.append("fileCount: \(inquiry.fileCount)")
        if let date = inquiry.modificationDate {
            let fmt = ISO8601DateFormatter()
            lines.append("mtime: \(fmt.string(from: date))")
        } else {
            lines.append("mtime: (unknown)")
        }
        lines.append("localVerdict: \(inquiry.verdict.rawValue)")
        if let v = inquiry.vendorName {
            lines.append("vendorName: \(v)")
        }
        if let n = inquiry.vendorNote {
            lines.append("vendorNote: \(n)")
        }
        if !inquiry.childPreview.isEmpty {
            let joined = inquiry.childPreview.joined(separator: ", ")
            lines.append("childPreview: \(joined)")
        }
        lines.append("")
        lines.append("请按 system prompt 的 JSON schema 输出一段 JSON。")
        return lines.joined(separator: "\n")
    }
}

/// OpenAI chat completions 消息体。最小集，仅 role + content。
public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// 本地后置校验——把 AI 返回的 advice 与本地真相做硬钳制。
/// 调用时机：[OpenAIChatClient.ask(...)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)
/// 拿到原始 AIAdvice 后立即过这里，再返回给 UI。
public enum AIAdviceClamp {

    /// 本地策略覆盖 AI verdict 时给 reason 前缀的 sentinel marker。
    /// UI 层应当识别此前缀并替换为本地化文案。
    public static let localPolicyOverridePrefix: String = "[ai.advice.local_policy_override] "

    /// 钉死规则：本地 forbid → AI 必须 forbid；硬禁路径前缀 → 强制 forbid。
    /// 这是产品红线，**AI 不能替代 [SafetyEngine](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift)**。
    public static func clamp(_ advice: AIAdvice, against inquiry: PathInquiry) -> AIAdvice {
        // 规则 1 & 2：本地 forbid 或 路径命中硬禁前缀 → 强制 forbid
        if inquiry.verdict == .forbid || pathIsHardForbid(inquiry.path) {
            if advice.canDelete != .forbid {
                return AIAdvice(
                    summary: advice.summary,
                    canDelete: .forbid,
                    reason: Self.localPolicyOverridePrefix + advice.reason,
                    sideEffects: advice.sideEffects
                )
            }
            return advice
        }
        // 规则 3：本地 confirm 时，AI 不得把 verdict 升级放宽为 safe
        if inquiry.verdict == .confirm && advice.canDelete == .safe {
            return AIAdvice(
                summary: advice.summary,
                canDelete: .confirm,
                reason: Self.localPolicyOverridePrefix + advice.reason,
                sideEffects: advice.sideEffects
            )
        }
        return advice
    }

    /// 与 [SafetyEngine.hardForbidPrefixes](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift#L42-L52)
    /// 保持**单一真相源**——直接复用 SafetyEngine 列表，避免双份维护漂移
    /// （Review fix #3，2026-06-15）。
    ///
    /// 在此之上 AIKit 还额外补两条 system prompt 中承诺的"宽前缀"：
    /// - `/private/var`、`/var`：system prompt 第 1 条对 AI 的承诺是"/private/var
    ///   开头一律 forbid"。SafetyEngine 出于实际清理需要只锁了 `/var/db`、`/var/protected`
    ///   子目录（用户家目录之外但允许动 `/private/var/folders/<hash>/T` 这类临时区）。
    ///   AI 这一侧采取**更保守**策略，把整个 `/private/var` 钳成 forbid——AI 没有
    ///   SafetyEngine 那套精细化策略上下文，宁可拒错也别误开绿灯。
    private static let extraHardForbidPrefixes: [String] = [
        "/private/var", "/var"
    ]

    private static let lowerHardForbidPrefixes: [String] =
        SafetyEngine.hardForbidPrefixes.map { $0.lowercased() }
    private static let lowerExtraHardForbidPrefixes: [String] =
        extraHardForbidPrefixes.map { $0.lowercased() }

    private static func stripDataVolume(_ p: String) -> String {
        let dataPrefix = "/System/Volumes/Data"
        let lower = p.lowercased()
        if lower == "/system/volumes/data" {
            return "/"
        }
        if lower.hasPrefix("/system/volumes/data/") {
            return String(p.dropFirst(dataPrefix.count))
        }
        return p
    }

    private static func inferHome(from canonicalPath: String) -> String? {
        let lower = canonicalPath.lowercased()
        guard lower.hasPrefix("/users/") else { return nil }
        let afterUsers = canonicalPath.index(canonicalPath.startIndex, offsetBy: "/Users/".count)
        let endIdx = canonicalPath[afterUsers...].firstIndex(of: "/") ?? canonicalPath.endIndex
        let user = canonicalPath[afterUsers..<endIdx]
        guard !user.isEmpty else { return nil }
        return "/Users/\(user)"
    }

    public static func pathIsHardForbid(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return true }
        let stripped = stripDataVolume(path)
        let standardized = stripDataVolume(URL(fileURLWithPath: stripped).standardizedFileURL.path)
        let resolved = stripDataVolume(
            URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path
        )
        let candidates = resolved == standardized ? [standardized] : [standardized, resolved]
        let engine = SafetyEngine()
        for candidate in candidates {
            let lower = candidate.lowercased()
            for p in lowerHardForbidPrefixes {
                if lower == p || lower.hasPrefix(p + "/") { return true }
            }
            for p in lowerExtraHardForbidPrefixes {
                if lower == p || lower.hasPrefix(p + "/") { return true }
            }
            if engine.isForbidden(path: candidate) {
                return true
            }
            if let inferredHome = inferHome(from: candidate),
               engine.isForbidden(path: candidate, home: inferredHome) {
                return true
            }
        }
        return false
    }
}
