import Foundation

/// M5 / 2026-06：出网前对路径做去敏。
///
/// **红线**：出 HTTP 之前，所有传给 AI 的字符串必须先过这里。
/// 由 [OpenAIChatClient.ask(...)](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)
/// 在请求构造阶段调用，调用方无须关心。
///
/// 去敏维度（按 ROI 排）：
/// 1. **用户名**：`/Users/<name>` / `/home/<name>` → `/Users/<USER>` —— 最普遍泄漏点
/// 2. **UUID**：iOS DeviceSupport / CoreSimulator / Provisioning Profiles 大量含 UUID，
///    本身不直接敏感但能与用户其它数据交叉关联，统一打码
/// 3. **邮箱**：iCloud Drive 路径偶有 `<email>@icloud.com` 段
/// 4. **盘符卷名**：`/Volumes/Macintosh HD - Data` → 保留；`/Volumes/<user-defined>` → `/Volumes/<VOLUME>`
///
/// **故意不做**的事：
/// - 不做 IP / 域名 / 信用卡 / 手机号去敏——清理工具的 path 元数据里不会出现这些
/// - 不去敏 vendor 名（如 "Xcode DerivedData"）——那是 AI 给出建议的关键上下文
/// - 不破坏路径合法性——保留分隔符 `/`，仍能被 AI 识别为路径结构
public struct PathRedactor: Sendable {

    /// 用户名占位
    public static let userPlaceholder = "<USER>"
    /// UUID 占位
    public static let uuidPlaceholder = "<UUID>"
    /// 邮箱占位
    public static let emailPlaceholder = "<EMAIL>"
    /// 自定义卷名占位
    public static let volumePlaceholder = "<VOLUME>"

    /// 系统/Apple 卷名白名单，不打码（这些不是隐私）
    public static let systemVolumes: Set<String> = [
        "Macintosh HD",
        "Macintosh HD - Data",
        "Data",
        "Preboot",
        "Recovery",
        "VM",
        "Update"
    ]

    public init() {}

    /// 入口：对一段字符串做去敏。
    /// 非破坏性——传入空串 / 不含敏感模式直接原样返回。
    public func redact(_ input: String) -> String {
        var s = input
        s = redactUsersPrefix(in: s)
        s = redactHomePrefix(in: s)
        s = redactVolumes(in: s)
        s = redactUUIDs(in: s)
        s = redactEmails(in: s)
        return s
    }

    /// 批量入口——给 [PathInquiry.childPreview](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AIKit/Sources/AIKit/PathInquiry.swift#L43) 用。
    public func redact(_ inputs: [String]) -> [String] {
        inputs.map { redact($0) }
    }

    // MARK: - 内部

    /// `/Users/foo/...` → `/Users/<USER>/...`
    /// 也兼容 `/Users/foo` 结尾无斜杠的情况。
    private func redactUsersPrefix(in s: String) -> String {
        replaceFirstPathSegment(prefix: "/Users/", in: s, with: Self.userPlaceholder)
    }

    /// Linux/Docker 残留路径偶尔出现 `/home/<user>/...`
    private func redactHomePrefix(in s: String) -> String {
        replaceFirstPathSegment(prefix: "/home/", in: s, with: Self.userPlaceholder)
    }

    /// `/Volumes/<name>/...` —— 若 name 命中 systemVolumes 白名单则保留，
    /// 否则用 `<VOLUME>` 占位。
    private func redactVolumes(in s: String) -> String {
        let token = "/Volumes/"
        guard let range = s.range(of: token) else { return s }
        let tail = s[range.upperBound...]
        // 切到下一个 `/` 之前
        let endIdx = tail.firstIndex(of: "/") ?? tail.endIndex
        let volume = String(tail[..<endIdx])
        if volume.isEmpty { return s }
        if Self.systemVolumes.contains(volume) { return s }
        let head = s[..<range.upperBound]
        return "\(head)\(Self.volumePlaceholder)\(tail[endIdx...])"
    }

    /// 通用：把 `<prefix><segment>(/<rest>)?` 里的 `<segment>` 替换为占位符。
    /// 仅替换**第一次出现**——后续段不会再有用户名形态。
    private func replaceFirstPathSegment(prefix: String, in s: String, with placeholder: String) -> String {
        guard let range = s.range(of: prefix) else { return s }
        let tail = s[range.upperBound...]
        let endIdx = tail.firstIndex(of: "/") ?? tail.endIndex
        let segment = tail[..<endIdx]
        if segment.isEmpty { return s }
        let head = s[..<range.upperBound]
        return "\(head)\(placeholder)\(tail[endIdx...])"
    }

    /// UUID 经典形：`8-4-4-4-12` hex。
    /// 用 NSRegularExpression 一次性替换；不存在则原样返回。
    private func redactUUIDs(in s: String) -> String {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        return replaceAll(in: s, pattern: pattern, with: Self.uuidPlaceholder)
    }

    /// 简化邮箱：`local@domain.tld`，不严格 RFC 5322（路径里出现的邮箱形态有限）。
    private func redactEmails(in s: String) -> String {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        return replaceAll(in: s, pattern: pattern, with: Self.emailPlaceholder)
    }

    private func replaceAll(in s: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return s
        }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: replacement)
    }
}
