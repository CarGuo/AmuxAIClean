import Combine
import Foundation
import ScanKit

/// v1.0 用户偏好（隐藏文件 toggle / 大文件阈值 / 排序方式）。
///
/// 设计要点：
/// 1. 走 `UserDefaults`（默认 `.standard`，单测可注入隔离 suite），
///    避开 `@AppStorage` 的 SwiftUI 属性包装器在跨 actor / 单测下的麻烦。
/// 2. v2026.07.16 起使用 Combine `ObservableObject` / `@Published`，统一覆盖 macOS 13.5+；
///    SwiftUI 消费者通过 `@ObservedObject` / `@StateObject` 和 projected value 双向绑定。
/// 3. 决策来源（v1.3 修订）：
///    - v1.0 原拍板"隐藏文件默认 OFF"被证明是错的产品决策——
///      ijkplayer 真实占盘 18.86 GB / 195,979 items（Finder），但默认 OFF 时只扫到
///      552.6 MB / 1,209 items，差 30 倍 / 文件数差 160 倍，根本对不上 Finder/du。
///    - 业界惯例（DaisyDisk / CleanMyMac / Finder 文件夹大小 / `du` / `df`）默认全算隐藏。
///    - 故 v1.3 起 `showHidden` 默认 **ON**；用户仍可在设置面板显式关掉。
@MainActor
public final class AppSettings: ObservableObject {
    public static let defaultMinFileSizeMB = 100
    public static let allowedMinFileSizeMB = 10
    public static let allowedMaxFileSizeMB = 10_240

    // MARK: - 持久化键

    public enum Keys {
        public static let showHidden = "v1.show_hidden"
        public static let minFileSizeMB = "v1.min_file_size_mb"
        public static let sortKey = "v1.sort_key"
        /// 启动时是否检查更新（v1.1）。默认 ON，可在设置里关闭。
        public static let updateCheckEnabled = "v1.update_check_enabled"
        /// 用户主动"跳过此版本"后记录的 tag_name（v1.1）。
        public static let skippedUpdateTag = "v1.skipped_update_tag"
        /// 大文件 / 树视图修改日期过滤（v1.2 P1-4）。
        public static let mtimeFilter = "v1.mtime_filter"
        /// v1.3：主列表（推荐清理 / 自定义路径）排序键，默认 sizeDesc
        public static let mainListSortKey = "v1.main_list_sort_key"
        /// v1.3：扫描悬浮窗（HUD）开关，默认 ON
        public static let hudEnabled = "v1.hud_enabled"
        /// v1.3：状态栏托盘图标开关，默认 ON
        public static let trayEnabled = "v1.tray_enabled"
        /// v1.3：HUD 常驻模式（即使未在扫描也一直显示，作为桌面/顶部小挂件），默认 OFF
        public static let hudPersistent = "v1.hud_persistent"
        /// v1.3：HUD 位置（顶部刘海下居中 / 桌面右上 / 桌面右下 / 桌面左下）
        public static let hudPlacement = "v1.hud_placement"
        /// v1.3.x：HUD 强制默认到灵动岛的迁移标记。
        /// 老版本默认 `.notchUnder`，新版本要求"开箱即灵动岛"——
        /// 启动时若该 key 未设置则把 hudPlacement **强制覆盖**为 `.dynamicIsland`
        /// 并把这个 key 落 true，今后用户怎么改都不再覆盖。
        public static let hudPlacementForcedIsland = "v1.hud_placement_forced_island_v1"
        /// v1.3.x：关掉主窗口后是否把 App 从 Dock / 顶部主菜单隐藏（切到 .accessory）。
        /// **v1.5.5 起默认 ON**（用户反馈：菜单栏托盘已是完整入口，Dock 图标重复）。
        /// 开启后 App 更接近"菜单栏小工具"形态：关窗 = 入后台，要靠菜单栏托盘把它拉回来。
        public static let hideFromDockWhenClosed = "v1.hide_from_dock_when_closed"
        /// v1.4：开发者构建产物扫描的规则启用集合，存为 `[String]`（DevArtifactRule.id 数组）。
        /// 默认 = `DevArtifactRules.allIDs`（全开），用户可在设置面板逐项关。
        public static let enabledDevArtifactRuleIDs = "v1.4.enabled_dev_artifact_rules"
        /// v2026.07.20：普通模式首次启用“开发缓存”时的耗时提示确认。
        /// 该键只记录用户已理解扫描可能较慢，不改变专业模式的规则集合。
        public static let smartCareDeveloperCacheWarningAcknowledged =
            "v2026.07.smart_care_developer_cache_warning_acknowledged"
        /// v1.6：Sentinel 后台守护开关（SMAppService.agent）。默认 OFF —— 用户必须在
        /// 「设置 → 高级 → 后台守护」显式打开才会注册 helper。详见 [docs/SENTINEL_DESIGN.md](file:///Users/amuxuser/workspace/AmuxAIClean/docs/SENTINEL_DESIGN.md) §4。
        public static let sentinelEnabled = "v1.6.sentinel_enabled"
        /// v1.6：Sentinel 最近一次成功 register 的时间戳（双向写入；register 时刷，
        /// unregister 时清）。给设置面板「最近被 Sentinel 发现的候选」面板做"自从启用以来"
        /// 的时间窗起点；同时用于诊断"用户开了但从来没成功过"的边界情况。
        public static let sentinelLastEnabled = "v1.6.sentinel_last_enabled"
        /// v2026.07.19 P1：是否仍有可信证据表明某代 Sentinel authority 需要完成关闭核验。
        /// 该证据与 Toggle、最近启用时间分离：Toggle 是用户期望，时间戳可在 current Agent
        /// 关闭后清空；只有 current Agent 与两代 legacy Daemon 都明确 `.notRegistered` 才能
        /// 清除此标记。默认不存在/false，避免从未启用的用户被状态查询错误打扰。
        static let sentinelRequiresShutdownVerification =
            "v1.6.sentinel_requires_shutdown_verification_v2"
        /// v1.7：用户在设置面板里手动指定的 UI 语言（覆盖系统跟随）。
        /// 持久化 raw string（`LanguageOverride.rawValue`）；`.system` 视为不覆盖。
        /// 改动后会同步写 `AppleLanguages`，并由 App 层把同一 locale 实时同步给
        /// SwiftUI、tooltip、托盘和原生主菜单；系统拥有的面板仍按系统自身策略取语言。
        public static let preferredLanguage = "v1.7.preferred_language"
        /// v1.6.9 (2026.10.12): the old Boolean did not identify a mode. It cannot prove that
        /// either specific tour was acknowledged, and must never suppress both tours on upgrade.
        static let legacyUserGuideCompleted = "v2026.10.control_guide_completed"
        public static let completedUserGuideModes = "v2026.10.control_guide_completed_modes"
    }

    private static func isValidMinFileSizeMB(_ value: Int) -> Bool {
        (allowedMinFileSizeMB...allowedMaxFileSizeMB).contains(value)
    }

    /// v1.3：HUD 屏幕位置预设。
    ///
    /// 设计要点：
    /// - **notchUnder**（默认）：顶部居中、紧贴菜单栏下 8pt。视觉等同"刘海挂件"，
    ///   level=.floating，跨 Space / 全屏不被遮。适合扫描 HUD。
    /// - **desktopTopRight / desktopBottomRight / desktopBottomLeft**：桌面挂件三档位。
    ///   level 设为 `kCGDesktopIconWindowLevel + 1` —— 在桌面图标之上、所有 App 窗口之下，
    ///   类似 GeekTool / Übersicht / iStat Menus 桌面挂件的层级；
    ///   只有在"显示桌面"或最小化所有 App 时才完整可见。
    ///
    /// **桌面层级 vs 悬浮层级**的关键差别：
    /// - 桌面层级：当作桌面背景的一部分，**不打扰** App 工作流，但被 App 窗口遮挡
    /// - 悬浮层级：永远在最上层，**永远可见**，但会盖住其它内容
    /// 用户根据"想随时看"还是"不想被打扰"自选。
    public enum HUDPlacement: String, CaseIterable, Sendable, Hashable {
        case dynamicIsland         // 仿 iPhone 灵动岛：贴刘海、收起态/展开态、hover 自动展开（statusBar 级）
        case notchUnder            // 顶部居中、刘海正下方（floating 级）
        case desktopTopRight       // 桌面右上角（桌面级）
        case desktopBottomRight    // 桌面右下角（桌面级）
        case desktopBottomLeft     // 桌面左下角（桌面级）

        public var label: String {
            label(in: .current)
        }

        public func label(in locale: Locale) -> String {
            let key: String
            switch self {
            case .dynamicIsland:      key = "hud.placement.dynamic_island"
            case .notchUnder:         key = "hud.placement.notch_under"
            case .desktopTopRight:    key = "hud.placement.desktop_top_right"
            case .desktopBottomRight: key = "hud.placement.desktop_bottom_right"
            case .desktopBottomLeft:  key = "hud.placement.desktop_bottom_left"
            }
            return AppLocalization.string(key, locale: locale)
        }

        /// 是否走桌面层级（在 App 窗口下、桌面图标上）。
        public var isDesktopLevel: Bool {
            switch self {
            case .notchUnder, .dynamicIsland: return false
            case .desktopTopRight, .desktopBottomRight, .desktopBottomLeft: return true
            }
        }

        /// 是否走 statusBar 级（贴刘海，盖住菜单栏区域）。
        public var isStatusBarLevel: Bool {
            self == .dynamicIsland
        }
    }

    /// v1.0 排序枚举（T4 大文件模块 + T5 列表通用）。
    public enum SortKey: String, CaseIterable, Sendable {
        case sizeDesc
        case sizeAsc
        case nameAsc
        case nameDesc
        case mtimeDesc
        case mtimeAsc
    }

    /// v1.2 P1-4：大文件 / 树视图按修改日期过滤。
    ///
    /// 设计要点：
    /// 1. **天数粒度**——以"距今 N 天内修改"为口径。竞品（CleanMyMac / Sensei）也是这个口径。
    /// 2. **"全部"是默认值**——不要默认就把"3 个月没动"的文件藏起来，用户得先看到全貌再缩范围。
    /// 3. 时间窗在 **应用过滤的瞬间**计算（now - days），不存"截止时间"，
    ///    避免缓存日期变成"昨天的过滤口径"。
    /// 4. mtime 缺失（少数 SMB / iCloud 占位）按"全部"处理：保留显示，
    ///    跟 LargeFileSortKey.mtimeAsc/Desc 对 nil 的兜底策略一致。
    public enum MtimeFilter: String, CaseIterable, Sendable, Hashable {
        case all
        case last30Days
        case last1Year

        public var label: String {
            label(in: .current)
        }

        public func label(in locale: Locale) -> String {
            let key: String
            switch self {
            case .all:        key = "mtime.filter.all"
            case .last30Days: key = "mtime.filter.last30days"
            case .last1Year:  key = "mtime.filter.last1year"
            }
            return AppLocalization.string(key, locale: locale)
        }

        /// 转为天数；`.all` 返回 nil，调用方据此跳过比较。
        public var days: Int? {
            switch self {
            case .all:        return nil
            case .last30Days: return 30
            case .last1Year:  return 365
            }
        }

        /// 给定 reference now，过滤通过的判断。`date == nil` 时返回 true（不丢数据）。
        public func passes(_ date: Date?, now: Date = Date()) -> Bool {
            guard let days = self.days else { return true }
            guard let date else { return true }
            // 注意：用 timeIntervalSince 取秒差，避开 Calendar.dateComponents 在跨夏令时 / 闰秒下的不稳定。
            // 1 天 = 86_400 秒；用户视角是"过去 N 天"，秒差 ≤ N×86_400 即通过。
            return now.timeIntervalSince(date) <= TimeInterval(days) * 86_400
        }
    }

    /// v1.7：UI 语言覆盖。
    ///
    /// 设计要点：
    /// - **`.system`（默认）**：不覆盖。沿用 macOS 系统语言（系统设置 → 通用 →
    ///   语言与地区 → 应用程序 里给本 App 单独指定的语言；若未指定则跟随系统首选语言）。
    /// - **`.zhHans`、`.en`**：用户在「设置 → 扫描 → 界面语言」里显式选定，此时：
    ///   1. 即时生效：通过 [effectiveLocale](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    ///      + `.environment(\.locale, ...)` 让所有走 SwiftUI 字符串目录的 `Text` 当次会话即换语言。
    ///   2. 非 SwiftUI 消费者：App 层用同一个 locale 重建托盘菜单，并只更新主菜单的
    ///      title（保留 target/action/responder chain）；不再要求用户重启。
    ///   3. 跨进程：[applyToAppleLanguagesIfNeeded](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    ///      仍同步 `AppleLanguages`，让下一次进程和系统拥有的原生面板保持一致。
    public enum LanguageOverride: String, CaseIterable, Sendable, Hashable {
        case system
        case zhHans = "zh-Hans"
        case en

        /// 默认 label（沿用 process Bundle.main.preferredLocalizations，与原行为兼容）。
        /// **注意 bug 历史**：这里的 `String(localized:)` 重载不读 SwiftUI 环境 locale，
        /// 而是读进程级 `Bundle.main.preferredLocalizations`。在用户已经把 App 整体环境
        /// locale 改成 zh-Hans、但 Bundle.main 仍是 en 的窗口里，Picker 选项会显示为
        /// 英文（"Simplified Chinese / Follow System / English"），与周围中文 UI 不一致。
        /// 解决：UI 调用方应使用下面的 [label(in:)](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppSettings.swift)，
        /// 把当前 SwiftUI 环境的 `Locale` 透传进来，确保选项文本与界面其它文本同语言。
        public var label: String {
            label(in: nil)
        }

        /// 按指定 locale 返回 label。`nil` 时退化为 process 默认（与 [label](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppSettings.swift) 等价）。
        ///
        /// 实现统一走 [AppLocalization](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppLocalization.swift)，
        /// 显式把 locale 交给 String Catalog。不要再自行拼 `.lproj` 路径；那会绕过
        /// Foundation 的语言回退规则，也会让相同问题在 tooltip / AppKit menu 重复出现。
        public func label(in locale: Locale?) -> String {
            let key: String
            switch self {
            case .system: key = "settings.language.system"
            case .zhHans: key = "settings.language.zh_hans"
            case .en:     key = "settings.language.en"
            }
            return AppLocalization.string(key, locale: locale ?? .current)
        }

        /// 转成 SwiftUI / Foundation 的 `Locale`。`.system` 返回 nil，
        /// 让 environment(\.locale, nil) 退回 SwiftUI 默认（继承自宿主 process）。
        public var locale: Locale? {
            switch self {
            case .system: return nil
            case .zhHans: return Locale(identifier: "zh-Hans")
            case .en:     return Locale(identifier: "en")
            }
        }

        /// 转成写入 `AppleLanguages` 的字符串数组。`.system` 返回 nil
        /// 表示"删除覆盖键，回归系统选择"。
        public var appleLanguagesValue: [String]? {
            switch self {
            case .system: return nil
            case .zhHans: return ["zh-Hans"]
            case .en:     return ["en"]
            }
        }
    }

    // MARK: - 后端

    private let defaults: UserDefaults

    /// 是否在扫描结果中显示 `.` 开头的隐藏文件，并把它们计入体积统计。
    /// **默认 ON**（v1.3 修订；v1.0 原默认 OFF 已证明是错误决策，详见类型注释）。
    @Published public var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: Keys.showHidden) }
    }

    /// 大文件模块阈值（单位 MB）。默认 100MB。
    @Published public var minFileSizeMB: Int {
        didSet { defaults.set(minFileSizeMB, forKey: Keys.minFileSizeMB) }
    }

    /// 当前列表排序方式。默认 `.sizeDesc`（按大小降序）。
    @Published public var sortKey: SortKey {
        didSet { defaults.set(sortKey.rawValue, forKey: Keys.sortKey) }
    }

    /// 启动时检查更新（v1.1）。默认 ON。
    /// 关掉后 App 启动 / Help 菜单的"立即检查更新"仍可用，但不会自动联网。
    @Published public var updateCheckEnabled: Bool {
        didSet { defaults.set(updateCheckEnabled, forKey: Keys.updateCheckEnabled) }
    }

    /// 用户对某个版本点了"跳过此版本"，记录 tag_name；下次启动若拉到的还是这个 tag 则不再提示。
    @Published public var skippedUpdateTag: String? {
        didSet {
            if let tag = skippedUpdateTag {
                defaults.set(tag, forKey: Keys.skippedUpdateTag)
            } else {
                defaults.removeObject(forKey: Keys.skippedUpdateTag)
            }
        }
    }

    /// 大文件 / 树视图按修改日期过滤（v1.2 P1-4）。默认 `.all`。
    @Published public var mtimeFilter: MtimeFilter {
        didSet { defaults.set(mtimeFilter.rawValue, forKey: Keys.mtimeFilter) }
    }

    /// v1.3：主列表排序键，默认 `.sizeDesc`（按字节大小从大到小）。
    /// 持久化存 raw string；通过 [AmuxAICleanApp](file:///Users/amuxuser/workspace/AmuxAIClean/App/AmuxAICleanApp.swift)
    /// / [MainView](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// onChange 实时同步到 [ScanCoordinator.mainListSortKey](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)。
    @Published public var mainListSortKey: MainListSortKey {
        didSet { defaults.set(mainListSortKey.rawValue, forKey: Keys.mainListSortKey) }
    }

    /// v1.3：扫描悬浮窗（HUD）开关，默认 `true`。
    /// 关掉就完全不会创建 [FloatingScanHUDController](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
    /// 的 NSPanel，零开销。
    @Published public var hudEnabled: Bool {
        didSet { defaults.set(hudEnabled, forKey: Keys.hudEnabled) }
    }

    /// v1.3：状态栏托盘开关，默认 `true`。
    /// 关掉后 [StatusItemController](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/StatusItemController.swift)
    /// 不会注册 NSStatusItem，菜单栏右侧不会有图标。
    ///
    /// **v1.3.x 互斥兜底（与 hideFromDockWhenClosed 对偶）**：
    /// 关托盘的时候如果"关窗藏 Dock"还开着，关窗后 App 就彻底失踪了，
    /// 所以这里强制把 hideFromDockWhenClosed 也关掉，回到能看到 Dock 的安全态。
    @Published public var trayEnabled: Bool {
        didSet {
            defaults.set(trayEnabled, forKey: Keys.trayEnabled)
            if !trayEnabled, hideFromDockWhenClosed {
                hideFromDockWhenClosed = false
            }
        }
    }

    /// v1.3：HUD 常驻模式开关，默认 `false`。
    ///
    /// 打开后 HUD 不再依赖 `coordinator.isScanning`：即使没在扫描也持续显示，
    /// 显示"上次扫描可清理 X GB"等闲置态信息，并提供"立即扫描"按钮。
    /// 适合用户当作桌面/顶部小挂件长期挂着。
    /// 关掉则恢复原行为（仅扫描时弹出，结束 0.8s 后渐隐）。
    @Published public var hudPersistent: Bool {
        didSet { defaults.set(hudPersistent, forKey: Keys.hudPersistent) }
    }

    /// v1.3：HUD 屏幕位置预设。默认 `.notchUnder`（顶部刘海下居中）。
    /// 切换到桌面级（topRight / bottomRight / bottomLeft）后会以"桌面挂件"姿态显示，
    /// App 窗口会盖在它上面，但桌面图标在它下面，类似 GeekTool / iStat Menus 桌面挂件。
    @Published public var hudPlacement: HUDPlacement {
        didSet { defaults.set(hudPlacement.rawValue, forKey: Keys.hudPlacement) }
    }

    /// v1.3.x：关闭主窗口后把 App 从 Dock / 顶部主菜单隐藏，切到 `NSApp.accessory` 模式。
    /// **v1.5.5 起默认 `true`**（用户原话："只要顶部状态栏还在不就好了"）。
    ///
    /// 设计来源：用户原话「我们都有顶部托盘托管了，关闭后是不是可以不显示在底部托管」。
    /// 既然菜单栏托盘已经能完成"打开主窗口 / 立即扫描 / toggle HUD"三件事，
    /// 关窗后再保留 Dock 图标就重复了——参考 Bartender / iStat Menus / Rectangle 等
    /// 菜单栏 App 的标准玩法，关窗 → accessory（隐 Dock + 隐主菜单），开窗 → regular。
    ///
    /// **互斥兜底**：
    /// 用户不能同时关掉 trayEnabled 又开 hideFromDockWhenClosed——那会让 App 完全没入口
    /// （关窗后 Dock 没图标 + 菜单栏没托盘 = 只能 Activity Monitor / kill 重开）。
    /// didSet 里在打开本开关时**强制把 trayEnabled 拉回 true**，
    /// 同时 trayEnabled 的 didSet 也做对偶约束（关托盘时强制关本开关），形成双向锁。
    @Published public var hideFromDockWhenClosed: Bool {
        didSet {
            defaults.set(hideFromDockWhenClosed, forKey: Keys.hideFromDockWhenClosed)
            // 互斥兜底：开启本开关时托盘必须留着，否则 App 就完全失踪了。
            if hideFromDockWhenClosed, !trayEnabled {
                trayEnabled = true
            }
        }
    }

    /// v1.4：开发者构建产物扫描启用的规则 ID 集合。
    ///
    /// 设计：
    /// - **内置全开**：默认 = [DevArtifactRules.allIDs](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DevArtifactRules.swift)，
    ///   覆盖 30 条规则（node_modules / .next / Pods / .gradle / build / target / __pycache__ ...）。
    /// - **逐项可关**：用户可在 [SettingsScene](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SettingsScene.swift)
    ///   的"开发者扫描规则"分组按生态逐条关（比如不写 Rust 的关 `target/`，避免误伤别的 target）。
    /// - **持久化**：UserDefaults 存 `[String]` 数组（rawValue），读时反序列化为 `Set<String>`，
    ///   保持 O(1) 查询（`DevArtifactScanner` 在每个 entry 上要查一次）。
    /// - **空集兜底**：若用户把所有规则都关掉，[DevArtifactScanner.discover](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/DevArtifactScanner.swift)
    ///   会直接 warning 并返回空命中，[scanDeveloper](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    ///   走 0 命中分支直接结束，不会卡 UI。
    @Published public var enabledDevArtifactRuleIDs: Set<String> {
        didSet { defaults.set(Array(enabledDevArtifactRuleIDs), forKey: Keys.enabledDevArtifactRuleIDs) }
    }

    /// 普通模式的开发缓存耗时提示只在首次显式开启时出现。确认状态持久化，
    /// 避免用户每次取消再选择都被相同提示打断；它不授权删除，也不启用任何专业规则。
    @Published public var smartCareDeveloperCacheWarningAcknowledged: Bool {
        didSet {
            defaults.set(
                smartCareDeveloperCacheWarningAcknowledged,
                forKey: Keys.smartCareDeveloperCacheWarningAcknowledged
            )
        }
    }

    /// v1.6.9: first-visit acknowledgement belongs to the tour's mode, not the whole App.
    /// Finishing/skipping Normal must leave Professional eligible on its first entry.
    @Published public private(set) var completedUserGuideModes: Set<SmartCareInterfaceMode> {
        didSet {
            defaults.set(completedUserGuideModes.map(\.rawValue).sorted(), forKey: Keys.completedUserGuideModes)
        }
    }

    public var hasAcknowledgedAnyUserGuide: Bool { !completedUserGuideModes.isEmpty }

    func acknowledgeUserGuide(in mode: SmartCareInterfaceMode) {
        guard !completedUserGuideModes.contains(mode) else { return }
        completedUserGuideModes.insert(mode)
    }

    /// v1.6：Sentinel 后台守护开关。默认 `false` —— 用户必须显式在
    /// 「设置 → 高级 → 后台守护」勾选启用，避免存量用户升级后多了个守护进程。
    ///
    /// `didSet` 仅持久化到 UserDefaults；register / unregister 由
    /// [SentinelManager](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SentinelManager.swift)
    /// 在 [AmuxAICleanApp](file:///Users/amuxuser/workspace/AmuxAIClean/App/AmuxAICleanApp.swift)
    /// `onChange(of: settings.sentinelEnabled)` 钩子里完成（避免 AppSettings 直接依赖
    /// ServiceManagement，保持配置层纯）。
    @Published public var sentinelEnabled: Bool {
        didSet { defaults.set(sentinelEnabled, forKey: Keys.sentinelEnabled) }
    }

    /// v1.6：Sentinel 最近一次成功 register 的时间戳。
    /// register 成功后 [SentinelManager](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/SentinelManager.swift)
    /// 调本属性 setter 写入 `Date()`；unregister 后写 nil。
    @Published public var sentinelLastEnabled: Date? {
        didSet {
            if let date = sentinelLastEnabled {
                defaults.set(date, forKey: Keys.sentinelLastEnabled)
                // v2026.07.19 P1：成功 register 的时间戳是可信 authority 证据；后续即使
                // current Agent 已停，也要等 legacy identities 一并权威收敛后才能清证据。
                sentinelRequiresShutdownVerification = true
            } else {
                defaults.removeObject(forKey: Keys.sentinelLastEnabled)
            }
        }
    }

    /// v2026.07.19 P1：跨启动保存的 Sentinel authority 证据。
    ///
    /// 这不是另一个用户开关。它只由 `SentinelManager` 在系统明确报告 active/register
    /// 成功时置 true，并在 current Agent + 两代 legacy Daemon 全部明确 notRegistered 后
    /// 清除。把它独立持久化可同时守住两条边界：fresh/default-OFF 不弹误报；曾启用但
    /// 状态不可用时仍 fail-closed，不把查询失败冒充已关闭。
    var sentinelRequiresShutdownVerification: Bool {
        didSet {
            if sentinelRequiresShutdownVerification {
                defaults.set(true, forKey: Keys.sentinelRequiresShutdownVerification)
            } else {
                defaults.removeObject(forKey: Keys.sentinelRequiresShutdownVerification)
            }
        }
    }

    /// v1.7：UI 语言覆盖（默认 `.system`）。
    /// `didSet`：
    /// 1. 同步持久化（`.system` → 删 key）。
    /// 2. 同步把覆盖值写到 `AppleLanguages`（保持跨进程/系统资源选择一致）。
    @Published public var preferredLanguage: LanguageOverride {
        didSet {
            if preferredLanguage == .system {
                defaults.removeObject(forKey: Keys.preferredLanguage)
            } else {
                defaults.set(preferredLanguage.rawValue, forKey: Keys.preferredLanguage)
            }
            applyToAppleLanguagesIfNeeded()
        }
    }

    /// v1.7：把 [preferredLanguage](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/AppSettings.swift)
    /// 映射成 SwiftUI 用的 `Locale`，给 `WindowGroup.environment(\.locale, ...)` 用。
    /// `.system` 时返回 `Locale.autoupdatingCurrent`，让 SwiftUI 自然跟随系统。
    public var effectiveLocale: Locale {
        preferredLanguage.locale ?? .autoupdatingCurrent
    }

    /// v1.7：把覆盖值同步到 `UserDefaults.standard` 的 `AppleLanguages`。
    /// 只在 backend 是 `UserDefaults.standard` 时执行（单测用独立 suite 时短路），
    /// 避免测试时污染主域。当前进程的用户可见菜单/tooltip 不依赖这里重新加载 Bundle，
    /// 而由显式 locale resolver 和 ApplicationMenuLocalizer 实时刷新。
    public func applyToAppleLanguagesIfNeeded() {
        guard defaults == UserDefaults.standard else { return }
        if let value = preferredLanguage.appleLanguagesValue {
            UserDefaults.standard.set(value, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    // MARK: - 构造

    /// 标准构造（生产代码用）：直接使用 `UserDefaults.standard`。
    public convenience init() {
        self.init(defaultsBackend: UserDefaults.standard)
    }

    /// 单测专用构造：传 suite name，类内部自己造 `UserDefaults`，
    /// 避免 Swift 6 严格并发把非 Sendable 的 UserDefaults 跨 actor 传递。
    public convenience init(testSuite: String) {
        self.init(defaultsBackend: UserDefaults(suiteName: testSuite) ?? .standard)
    }

    private init(defaultsBackend defaults: UserDefaults) {
        self.defaults = defaults
        // 用 object(forKey:) 区分 "未写入" vs "写入 false"，
        // 这样首启默认值才能落地为 true 而非被 bool(forKey:) 的 false 默认覆盖。
        if let raw = defaults.object(forKey: Keys.showHidden) as? Bool {
            self.showHidden = raw
        } else {
            self.showHidden = true
        }
        if let raw = defaults.object(forKey: Keys.minFileSizeMB) as? Int,
           Self.isValidMinFileSizeMB(raw) {
            self.minFileSizeMB = raw
        } else {
            self.minFileSizeMB = Self.defaultMinFileSizeMB
            defaults.set(Self.defaultMinFileSizeMB, forKey: Keys.minFileSizeMB)
        }
        if let raw = defaults.string(forKey: Keys.sortKey),
           let parsed = SortKey(rawValue: raw) {
            self.sortKey = parsed
        } else {
            self.sortKey = .sizeDesc
        }
        if let raw = defaults.object(forKey: Keys.updateCheckEnabled) as? Bool {
            self.updateCheckEnabled = raw
        } else {
            self.updateCheckEnabled = true
        }
        self.skippedUpdateTag = defaults.string(forKey: Keys.skippedUpdateTag)
        if let raw = defaults.string(forKey: Keys.mtimeFilter),
           let parsed = MtimeFilter(rawValue: raw) {
            self.mtimeFilter = parsed
        } else {
            self.mtimeFilter = .all
        }
        if let raw = defaults.string(forKey: Keys.mainListSortKey),
           let parsed = MainListSortKey(rawValue: raw) {
            self.mainListSortKey = parsed
        } else {
            self.mainListSortKey = .sizeDesc
        }
        if let raw = defaults.object(forKey: Keys.hudEnabled) as? Bool {
            self.hudEnabled = raw
        } else {
            self.hudEnabled = true
        }
        if let raw = defaults.object(forKey: Keys.trayEnabled) as? Bool {
            self.trayEnabled = raw
        } else {
            self.trayEnabled = true
        }
        // hudPersistent 默认 ON —— 用户原话「不只是扫描，我希望我可以一直存在」，
        // 默认就让灵动岛常驻，闲置态显示磁盘可用 + severity 警示。
        if let raw = defaults.object(forKey: Keys.hudPersistent) as? Bool {
            self.hudPersistent = raw
        } else {
            self.hudPersistent = true
        }
        if let raw = defaults.string(forKey: Keys.hudPlacement),
           let parsed = HUDPlacement(rawValue: raw) {
            self.hudPlacement = parsed
        } else {
            self.hudPlacement = .dynamicIsland
        }
        // 一次性强制迁移：老版本默认 .notchUnder，老用户的 UserDefaults 已经写死，
        // 改默认值救不了他。这里检测到从未跑过迁移就把当前值直接覆盖为 .dynamicIsland，
        // 并落 forcedIsland 标记，今后绝不重复覆盖（用户主动切走也尊重他的选择）。
        if defaults.object(forKey: Keys.hudPlacementForcedIsland) == nil {
            self.hudPlacement = .dynamicIsland
            defaults.set(true, forKey: Keys.hudPlacementForcedIsland)
        }
        // **v1.5.5（用户反馈）**：原话「现在点击关闭按键，macos 的 dock 托盘为什么还在？
        // 我们只要顶部状态栏还在不就好了」——既然 trayEnabled 默认 ON，菜单栏托盘已经
        // 提供「打开主窗口 / 立即扫描 / toggle HUD」三件套完整入口，关窗后还留 Dock 图标
        // 就是重复的"半驻留"形态。改默认 ON，与 trayEnabled 默认 ON 配合形成
        // 「关窗 → .accessory（隐 Dock + 隐主菜单），开窗 → .regular」的标准菜单栏 App
        // 玩法（参考 Bartender / iStat Menus / Rectangle）。
        //
        // 行为兜底（已写在 didSet 与下方初始化纠偏）：
        // - 用户若手动关 trayEnabled，会反向把本开关拉回 false，避免关窗后 App 完全失踪
        // - 已落盘的 user defaults（老用户 / 用户手动改过）走 `if let raw` 分支，原值不动
        if let raw = defaults.object(forKey: Keys.hideFromDockWhenClosed) as? Bool {
            self.hideFromDockWhenClosed = raw
        } else {
            self.hideFromDockWhenClosed = true
        }
        // v1.4：开发者构建产物扫描规则——首启 / 未配置时全开，并把
        // 后续新增的内置规则**自动并入**当前用户启用集合。
        // 设计要点：用户先前关掉的规则（即已写入 defaults 但 raw 中不含的）保持关闭尊重用户选择；
        // 但 App 升级后新增的规则（rawSet 不包含、allIDs 包含）默认随版本启用，避免新生态被默默漏扫。
        if let raw = defaults.array(forKey: Keys.enabledDevArtifactRuleIDs) as? [String] {
            self.enabledDevArtifactRuleIDs = Set(raw)
        } else {
            self.enabledDevArtifactRuleIDs = DevArtifactRules.allIDs
        }
        self.smartCareDeveloperCacheWarningAcknowledged =
            (defaults.object(forKey: Keys.smartCareDeveloperCacheWarningAcknowledged) as? Bool)
            ?? false
        // The legacy flag has no mode provenance. Start mode-specific acknowledgement from
        // known records only; each tour will be offered once on its own first visit after upgrade.
        self.completedUserGuideModes = Set(
            (defaults.stringArray(forKey: Keys.completedUserGuideModes) ?? [])
                .compactMap(SmartCareInterfaceMode.init(rawValue:))
        )
        // v1.6：Sentinel 默认 OFF（用户必须显式启用，避免存量用户升级后多了个守护进程）。
        let loadedSentinelEnabled =
            (defaults.object(forKey: Keys.sentinelEnabled) as? Bool) ?? false
        self.sentinelEnabled = loadedSentinelEnabled
        let loadedSentinelLastEnabled =
            defaults.object(forKey: Keys.sentinelLastEnabled) as? Date
        self.sentinelLastEnabled = loadedSentinelLastEnabled
        if let raw = defaults.object(
            forKey: Keys.sentinelRequiresShutdownVerification
        ) as? Bool {
            self.sentinelRequiresShutdownVerification = raw
        } else {
            // v2026.07.19 P1 migration：旧版本没有独立 authority 标记。保存的 ON 期望或
            // 成功启用时间都是可信历史证据；fresh install 两者都没有，必须保持 false。
            let derivedEvidence = loadedSentinelEnabled || loadedSentinelLastEnabled != nil
            self.sentinelRequiresShutdownVerification = derivedEvidence
            if derivedEvidence {
                defaults.set(true, forKey: Keys.sentinelRequiresShutdownVerification)
            }
        }
        // v1.7：UI 语言覆盖。默认 .system（跟随系统）。
        // 不存在 / 解析失败 / 显式 "system" 都视为 .system，避免污染主域 AppleLanguages。
        if let raw = defaults.string(forKey: Keys.preferredLanguage),
           let parsed = LanguageOverride(rawValue: raw) {
            self.preferredLanguage = parsed
        } else {
            self.preferredLanguage = .system
        }
        // 初始化期一致性纠偏：万一上一次进程崩溃前留下了"trayEnabled=false 且 hideFromDockWhenClosed=true"
        // 的非法组合（didSet 没来得及触发），启动时强制以 trayEnabled 为准。
        if hideFromDockWhenClosed, !trayEnabled {
            self.hideFromDockWhenClosed = false
        }
    }

    /// 单测专用：把当前实例所有键从 defaults 清掉。
    public func _testReset() {
        defaults.removeObject(forKey: Keys.showHidden)
        defaults.removeObject(forKey: Keys.minFileSizeMB)
        defaults.removeObject(forKey: Keys.sortKey)
        defaults.removeObject(forKey: Keys.updateCheckEnabled)
        defaults.removeObject(forKey: Keys.skippedUpdateTag)
        defaults.removeObject(forKey: Keys.mtimeFilter)
        defaults.removeObject(forKey: Keys.mainListSortKey)
        defaults.removeObject(forKey: Keys.hudEnabled)
        defaults.removeObject(forKey: Keys.trayEnabled)
        defaults.removeObject(forKey: Keys.hudPersistent)
        defaults.removeObject(forKey: Keys.hudPlacement)
        defaults.removeObject(forKey: Keys.hudPlacementForcedIsland)
        defaults.removeObject(forKey: Keys.hideFromDockWhenClosed)
        defaults.removeObject(forKey: Keys.enabledDevArtifactRuleIDs)
        defaults.removeObject(forKey: Keys.smartCareDeveloperCacheWarningAcknowledged)
        defaults.removeObject(forKey: Keys.legacyUserGuideCompleted)
        defaults.removeObject(forKey: Keys.completedUserGuideModes)
        defaults.removeObject(forKey: Keys.sentinelEnabled)
        defaults.removeObject(forKey: Keys.sentinelLastEnabled)
        defaults.removeObject(forKey: Keys.sentinelRequiresShutdownVerification)
        defaults.removeObject(forKey: Keys.preferredLanguage)
    }
}
