import Foundation

/// macOS 15+ TCC（Transparency Consent and Control）雷区目录硬编码 skip list。
///
/// 背景：从 macOS 15 (Sequoia) 起，系统把以下目录列为高敏区，扫描器只要 `open(2)`
/// 命中，就会触发原生权限弹窗（"AmuxAIClean想要访问你的 Apple Music 媒体库"等）。
/// 即便用户一律点"不允许"，弹窗本身已经严重打断扫描流程；多 worker 并行下钻还会
/// 一次弹好几个，体验极差。
///
/// 业界做法对比：
/// - **CleanMyMac**：硬编码 skip + 仅在用户主动选择"清理 Mail/Photos 缓存"时才申请
///   对应权限（按需触发）。
/// - **AppCleaner**：根本不进 ~/Library 高敏子目录，绕开问题。
/// - **Pearcleaner**：开源代码里能看到一份 skip table，覆盖 Mail/Messages/Photos。
/// - **DaisyDisk**：扫整盘时跳过 ~/Library，要求用户单独勾选才进入。
///
/// 我们的策略（v1.1）：
/// 1. **硬 skip**：扫描 walker 一律不下钻这些路径，源头杜绝弹窗
/// 2. **统计可见**：把"被 skip 的雷区目录数"汇总到 ScanSummary，UI banner 提示
/// 3. **绝不申请权限**：本 App 定位是"清缓存/重复文件"，没有合法理由读 Apple Music
///    媒体库或邮件正文，宁可少扫一点
///
/// 参考：
/// - Apple《macOS Sequoia Privacy》：Music / Photos / Calendar / Contacts / Mail
/// - WWDC24 "What's new in privacy"
/// - https://github.com/objective-see/Whats-Your-Sign 仓库 issue 区有完整 TCC 列表
public enum TCCSkipList {

    /// 文件名后缀型雷区（Music / Photos / TV / iMovie 媒体库都是 .xxxlibrary 包目录）。
    public static let dangerousSuffixes: [String] = [
        ".musiclibrary",       // Music.app 媒体库
        ".photoslibrary",      // Photos.app 媒体库
        ".tvlibrary",          // TV.app 媒体库
        ".imovielibrary",      // iMovie 媒体库
        ".theater",            // iMovie Theater
        ".photobooklibrary",   // Photo Booth 媒体库
        ".aplibrary",          // Aperture（老）
        ".migratedaperturelibrary"
    ]

    /// 绝对路径型雷区（相对 home 目录的尾段，运行时拼 home 前缀比对）。
    /// 这些目录是系统 TCC 守卫的"原生敏感数据库"。
    public static let dangerousHomeRelative: [String] = [
        // 邮件
        "Library/Mail",
        "Library/Containers/com.apple.mail",
        // 短信 / iMessage
        "Library/Messages",
        "Library/Containers/com.apple.MobileSMS",
        // 通讯录
        "Library/Application Support/AddressBook",
        "Library/Containers/com.apple.AddressBook",
        // 日历
        "Library/Calendars",
        "Library/Containers/com.apple.iCal",
        // 提醒事项
        "Library/Reminders",
        "Library/Containers/com.apple.reminders",
        // 通话记录
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CallHistoryTransactions",
        // Safari 浏览历史 / 书签（macOS 14+ TCC 守卫）
        "Library/Safari",
        "Library/Containers/com.apple.Safari",
        // HomeKit
        "Library/Application Support/com.apple.HomeKit",
        "Library/Containers/com.apple.Home",
        // Suggestions / Spotlight 索引私有
        "Library/Suggestions",
        "Library/Application Support/com.apple.spotlight",
        "Library/Metadata/CoreSpotlight",
        // 健康（Mac 上较少，但 iOS 同步过来的可能存在）
        "Library/Health",
        // 备忘录正文（虽然没明文 prompt，但属隐私范畴，不下钻避免误删）
        "Library/Group Containers/group.com.apple.notes",
        "Library/Containers/com.apple.Notes"
    ]

    /// 系统级绝对路径雷区（与 home 无关）。
    public static let dangerousAbsolute: [String] = [
        "/Library/Application Support/com.apple.TCC",  // TCC.db 本身
        "/private/var/db/locationd",
        "/private/var/folders"  // 临时文件，FDA 也未必读得动
    ]

    /// 综合判断：传入一个绝对路径，是否应该 skip（不下钻）。
    ///
    /// - Parameter absPath: 绝对路径（不含 trailing slash）
    /// - Returns: true 表示该路径是 TCC 雷区，walker 不应进入
    public static func shouldSkip(_ absPath: String) -> Bool {
        // 1. 后缀匹配（媒体库类 bundle 根及其内部子路径）
        for suffix in dangerousSuffixes {
            if absPath.hasSuffix(suffix) || absPath.contains(suffix + "/") {
                return true
            }
        }

        // 2. 系统绝对路径
        for prefix in dangerousAbsolute {
            if absPath == prefix || absPath.hasPrefix(prefix + "/") {
                return true
            }
        }

        // 3. home 相对路径
        // v2026.07.18 整盘公开命名空间合同：NSHomeDirectory 只能识别运行用户。
        // 从 `/` 扫描时还会看到 `/Users/<other-user>`，其 Mail/Messages 必须在
        // 触碰物理文件系统前使用同一 hard-skip 合同。但不能只按后缀匹配，
        // 否则 `/tmp/custom-home/Library/Mail` 这类 fixture/备份目录会被误当成 TCC home。
        if let relative = relativePath(absPath, underHome: NSHomeDirectory()),
           isDangerousHomeRelative(relative) {
            return true
        }
        if let relative = relativePathInPublicUsersNamespace(absPath),
           isDangerousHomeRelative(relative) {
            return true
        }

        return false
    }

    private static func isDangerousHomeRelative(_ relativePath: String) -> Bool {
        dangerousHomeRelative.contains { rule in
            relativePath == rule || relativePath.hasPrefix(rule + "/")
        }
    }

    private static func relativePath(_ path: String, underHome rawHome: String) -> String? {
        var home = rawHome
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }

    /// Returns the path below `/Users/<one-user-segment>` in the public namespace.
    /// Nested backup paths such as `/tmp/custom-home` and `/Volumes/backup/Users/...` do not
    /// qualify, which keeps namespace identity explicit instead of inferring a home from a suffix.
    private static func relativePathInPublicUsersNamespace(_ path: String) -> String? {
        let prefix = "/Users/"
        guard path.hasPrefix(prefix) else { return nil }
        let afterUsers = path.dropFirst(prefix.count)
        guard let separator = afterUsers.firstIndex(of: "/") else { return nil }
        let user = afterUsers[..<separator]
        guard !user.isEmpty, user != ".", user != ".." else { return nil }
        let relativeStart = afterUsers.index(after: separator)
        guard relativeStart < afterUsers.endIndex else { return nil }
        return String(afterUsers[relativeStart...])
    }
}
