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
    /// 也兼容 `/System/Volumes/Data/Users/foo`、`/users/foo` 及结尾无斜杠的情况。
    private func redactUsersPrefix(in s: String) -> String {
        let stripped = replaceAll(
            in: s,
            pattern: #"(?i)/System/Volumes/Data(?=/Users(?:/|$))"#,
            with: ""
        )
        return replacePathSegments(prefix: "/Users/", in: stripped, with: Self.userPlaceholder)
    }

    /// Linux/Docker 残留路径偶尔出现 `/home/<user>/...`
    private func redactHomePrefix(in s: String) -> String {
        replacePathSegments(prefix: "/home/", in: s, with: Self.userPlaceholder)
    }

    /// `/Volumes/<name>/...` —— 若 name 命中 systemVolumes 白名单则保留，
    /// 否则用 `<VOLUME>` 占位。
    private func redactVolumes(in s: String) -> String {
        let token = "/Volumes/"
        var out = s
        var searchStart = out.startIndex
        while let range = out.range(of: token, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
            let tail = out[range.upperBound...]
            let endIdx = tail.firstIndex(of: "/") ?? tail.endIndex
            let volume = String(tail[..<endIdx])
            if volume.isEmpty {
                searchStart = range.upperBound
                continue
            }
            if Self.systemVolumes.contains(where: { $0.caseInsensitiveCompare(volume) == .orderedSame }) {
                searchStart = endIdx
                continue
            }
            out.replaceSubrange(range.upperBound..<endIdx, with: Self.volumePlaceholder)
            searchStart = out.index(range.upperBound, offsetBy: Self.volumePlaceholder.count, limitedBy: out.endIndex) ?? out.endIndex
        }
        return out
    }

    /// 通用：把每个 `<prefix><segment>(/<rest>)?` 里的 `<segment>` 替换为占位符（大小写不敏感匹配 prefix，输出规范化 prefix）。
    private func replacePathSegments(prefix: String, in s: String, with placeholder: String) -> String {
        var out = s
        var searchStart = out.startIndex
        let replacement = prefix + placeholder
        while let range = out.range(of: prefix, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
            let tail = out[range.upperBound...]
            let endIdx = tail.firstIndex(of: "/") ?? tail.endIndex
            if tail[..<endIdx].isEmpty {
                searchStart = range.upperBound
                continue
            }
            out.replaceSubrange(range.lowerBound..<endIdx, with: replacement)
            searchStart = out.index(range.lowerBound, offsetBy: replacement.count, limitedBy: out.endIndex) ?? out.endIndex
        }
        return out
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
