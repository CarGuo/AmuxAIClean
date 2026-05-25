import Foundation
import Observation

/// v1.0 用户偏好（隐藏文件 toggle / 大文件阈值 / 排序方式）。
///
/// 设计要点：
/// 1. 走 `UserDefaults`（默认 `.standard`，单测可注入隔离 suite），
///    避开 `@AppStorage` 的 SwiftUI 属性包装器在跨 actor / 单测下的麻烦。
/// 2. 用 `@Observable`（Swift 6.0 / macOS 15+ 原生），SwiftUI 视图直接 `@Bindable` 即可双向绑定。
/// 3. 决策来源（v1.3 修订）：
///    - v1.0 原拍板"隐藏文件默认 OFF"被证明是错的产品决策——
///      ijkplayer 真实占盘 18.86 GB / 195,979 items（Finder），但默认 OFF 时只扫到
///      552.6 MB / 1,209 items，差 30 倍 / 文件数差 160 倍，根本对不上 Finder/du。
///    - 业界惯例（DaisyDisk / CleanMyMac / Finder 文件夹大小 / `du` / `df`）默认全算隐藏。
///    - 故 v1.3 起 `showHidden` 默认 **ON**；用户仍可在设置面板显式关掉。
@MainActor
@Observable
public final class AppSettings {
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
        /// v1.3：字节口径（logical / physical），默认 logical 与系统设置/Finder 对齐
        public static let sizeAccountingMode = "v1.size_accounting_mode"
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
        /// v1.3.x：关掉主窗口后是否把 App 从 Dock / 顶部主菜单隐藏（切到 .accessory）。默认 OFF。
        /// 开启后 App 会更接近"菜单栏小工具"形态：关窗 = 入后台，要靠菜单栏托盘把它拉回来。
        public static let hideFromDockWhenClosed = "v1.hide_from_dock_when_closed"
        /// v1.3.x（M1 内存优化）：扫描结果是否落 SQLite store 并在扫完后允许内存 compact。
        /// 默认 OFF（feature flag），稳定后默认 ON。开启后扫描期会异步把 node 批量写入
        /// `~/Library/Application Support/GSYCleanMac/scan.sqlite`，UI 在大文件视图等场景
        /// 可以在退出页面时主动 compact 内存中的大文件叶子缓存，下次进入再从 store 取。
        public static let useScanStore = "v1.use_scan_store"
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
            switch self {
            case .dynamicIsland:      return "灵动岛模式（贴刘海，hover 展开）"
            case .notchUnder:         return "顶部居中（刘海下方）"
            case .desktopTopRight:    return "桌面右上角"
            case .desktopBottomRight: return "桌面右下角"
            case .desktopBottomLeft:  return "桌面左下角"
            }
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
            switch self {
            case .all:        return "全部"
            case .last30Days: return "≤ 30 天"
            case .last1Year:  return "≤ 1 年"
            }
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

    /// v1.3：字节计算口径。
    ///
    /// 根本问题：用户报告"扫出来 67 GB，系统设置说 121 GB"，差 ~45%。
    /// 调查后发现是**两种合法但口径不同的统计方式**：
    ///
    /// - **logical（系统设置 / Finder / "信息"）口径**：
    ///   `ATTR_FILE_TOTALSIZE`，文件 fork 的逻辑字节数；
    ///   APFS clone / hardlink **不去重**，每个文件按完整 size 算。
    ///   **优势**：与系统所有内置工具读数一致，用户第一直觉。
    ///   **劣势**：删了一个 hardlink/clone 不能等量释放磁盘——预期可能落空。
    ///
    /// - **physical（du / df）口径**：
    ///   `ATTR_FILE_ALLOCSIZE`，文件实际占用磁盘 block 字节；
    ///   APFS sparse 文件按真实占用算（更小）；可选叠加 inode 去重让 hardlink 只算一次。
    ///   **优势**：删了真能释放这么多——清理工具该用的口径。
    ///   **劣势**：与系统设置数字对不上，用户会困惑。
    ///
    /// **默认 logical**：与系统设置对齐，避免用户每次扫描都怀疑漏算了。
    /// 高阶用户可在设置里切到 physical 看"删后能真正释放多少"。
    public enum SizeAccountingMode: String, CaseIterable, Sendable, Hashable {
        /// 逻辑大小（系统设置 / Finder 口径）
        case logical
        /// 物理占用（du / df 口径）
        case physical

        public var label: String {
            switch self {
            case .logical:  return "逻辑大小（系统设置口径）"
            case .physical: return "物理占用（du 口径）"
            }
        }
    }

    // MARK: - 后端

    private let defaults: UserDefaults

    /// 是否在扫描结果中显示 `.` 开头的隐藏文件，并把它们计入体积统计。
    /// **默认 ON**（v1.3 修订；v1.0 原默认 OFF 已证明是错误决策，详见类型注释）。
    public var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: Keys.showHidden) }
    }

    /// 大文件模块阈值（单位 MB）。默认 100MB。
    public var minFileSizeMB: Int {
        didSet { defaults.set(minFileSizeMB, forKey: Keys.minFileSizeMB) }
    }

    /// 当前列表排序方式。默认 `.sizeDesc`（按大小降序）。
    public var sortKey: SortKey {
        didSet { defaults.set(sortKey.rawValue, forKey: Keys.sortKey) }
    }

    /// 启动时检查更新（v1.1）。默认 ON。
    /// 关掉后 App 启动 / Help 菜单的"立即检查更新"仍可用，但不会自动联网。
    public var updateCheckEnabled: Bool {
        didSet { defaults.set(updateCheckEnabled, forKey: Keys.updateCheckEnabled) }
    }

    /// 用户对某个版本点了"跳过此版本"，记录 tag_name；下次启动若拉到的还是这个 tag 则不再提示。
    public var skippedUpdateTag: String? {
        didSet {
            if let tag = skippedUpdateTag {
                defaults.set(tag, forKey: Keys.skippedUpdateTag)
            } else {
                defaults.removeObject(forKey: Keys.skippedUpdateTag)
            }
        }
    }

    /// 大文件 / 树视图按修改日期过滤（v1.2 P1-4）。默认 `.all`。
    public var mtimeFilter: MtimeFilter {
        didSet { defaults.set(mtimeFilter.rawValue, forKey: Keys.mtimeFilter) }
    }

    /// v1.3：字节口径（logical / physical），默认 `.logical` 与系统设置/Finder 对齐。
    public var sizeAccountingMode: SizeAccountingMode {
        didSet { defaults.set(sizeAccountingMode.rawValue, forKey: Keys.sizeAccountingMode) }
    }

    /// v1.3：主列表排序键，默认 `.sizeDesc`（按字节大小从大到小）。
    /// 持久化存 raw string；通过 [GSYCleanMacApp](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift)
    /// / [MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// onChange 实时同步到 [ScanCoordinator.mainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)。
    public var mainListSortKey: MainListSortKey {
        didSet { defaults.set(mainListSortKey.rawValue, forKey: Keys.mainListSortKey) }
    }

    /// v1.3：扫描悬浮窗（HUD）开关，默认 `true`。
    /// 关掉就完全不会创建 [FloatingScanHUDController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift)
    /// 的 NSPanel，零开销。
    public var hudEnabled: Bool {
        didSet { defaults.set(hudEnabled, forKey: Keys.hudEnabled) }
    }

    /// v1.3：状态栏托盘开关，默认 `true`。
    /// 关掉后 [StatusItemController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/StatusItemController.swift)
    /// 不会注册 NSStatusItem，菜单栏右侧不会有图标。
    ///
    /// **v1.3.x 互斥兜底（与 hideFromDockWhenClosed 对偶）**：
    /// 关托盘的时候如果"关窗藏 Dock"还开着，关窗后 App 就彻底失踪了，
    /// 所以这里强制把 hideFromDockWhenClosed 也关掉，回到能看到 Dock 的安全态。
    public var trayEnabled: Bool {
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
    public var hudPersistent: Bool {
        didSet { defaults.set(hudPersistent, forKey: Keys.hudPersistent) }
    }

    /// v1.3：HUD 屏幕位置预设。默认 `.notchUnder`（顶部刘海下居中）。
    /// 切换到桌面级（topRight / bottomRight / bottomLeft）后会以"桌面挂件"姿态显示，
    /// App 窗口会盖在它上面，但桌面图标在它下面，类似 GeekTool / iStat Menus 桌面挂件。
    public var hudPlacement: HUDPlacement {
        didSet { defaults.set(hudPlacement.rawValue, forKey: Keys.hudPlacement) }
    }

    /// v1.3.x：关闭主窗口后把 App 从 Dock / 顶部主菜单隐藏，切到 `NSApp.accessory` 模式。默认 `false`。
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
    public var hideFromDockWhenClosed: Bool {
        didSet {
            defaults.set(hideFromDockWhenClosed, forKey: Keys.hideFromDockWhenClosed)
            // 互斥兜底：开启本开关时托盘必须留着，否则 App 就完全失踪了。
            if hideFromDockWhenClosed, !trayEnabled {
                trayEnabled = true
            }
        }
    }

    /// v1.3.x（M1 内存优化）：扫描结果是否落 SQLite store。默认 `false`（feature flag）。
    ///
    /// 开启后：
    /// - [ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    ///   扫描期把 node 批量写入 `~/Library/Application Support/GSYCleanMac/scan.sqlite`
    /// - 大文件视图等可在退出时调 `compactAfterScan()` 释放内存中 LargeFileLeaf 数组（百 MB 级）
    /// - 后续重新进入大文件视图时从 store 流式分页查询
    ///
    /// 关闭则保持原"全量内存驻留"行为，确保功能不退化。
    public var useScanStore: Bool {
        didSet { defaults.set(useScanStore, forKey: Keys.useScanStore) }
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
        if let raw = defaults.object(forKey: Keys.minFileSizeMB) as? Int, raw > 0 {
            self.minFileSizeMB = raw
        } else {
            self.minFileSizeMB = 100
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
        if let raw = defaults.string(forKey: Keys.sizeAccountingMode),
           let parsed = SizeAccountingMode(rawValue: raw) {
            self.sizeAccountingMode = parsed
        } else {
            self.sizeAccountingMode = .logical
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
        // v1.3.x：「关窗藏 Dock」默认 OFF——保守策略：本 App 虽配套菜单栏托盘 +
        // 灵动岛 HUD 等多入口，但默认翻 ON 会让存量用户升级后突然 Dock 找不到 App、
        // ⌘Tab 也找不到，第一观感就是"App 弄丢了"。所以新装/未配置的用户保持
        // OFF，关窗仍按 macOS 标准行为：Dock 留图标、⌘Tab 可切回。
        // 用户可在设置里手动开 ON 切到"驻留态后台清理工具"形态
        // （行业标准玩法：Bartender / iStat Menus / Rectangle）。
        // 互斥兜底：开 ON 时必须 trayEnabled=true，否则关窗后没有任何入口；
        // 下方 trayEnabled=false 的修正一旦命中会反向把这个 flag 拉回 false。
        if let raw = defaults.object(forKey: Keys.hideFromDockWhenClosed) as? Bool {
            self.hideFromDockWhenClosed = raw
        } else {
            self.hideFromDockWhenClosed = false
        }
        // M1 内存优化：useScanStore feature flag 默认 OFF，灰度后再翻 ON。
        if let raw = defaults.object(forKey: Keys.useScanStore) as? Bool {
            self.useScanStore = raw
        } else {
            self.useScanStore = false
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
        defaults.removeObject(forKey: Keys.sizeAccountingMode)
        defaults.removeObject(forKey: Keys.mainListSortKey)
        defaults.removeObject(forKey: Keys.hudEnabled)
        defaults.removeObject(forKey: Keys.trayEnabled)
        defaults.removeObject(forKey: Keys.hudPersistent)
        defaults.removeObject(forKey: Keys.hudPlacement)
        defaults.removeObject(forKey: Keys.hudPlacementForcedIsland)
        defaults.removeObject(forKey: Keys.hideFromDockWhenClosed)
        defaults.removeObject(forKey: Keys.useScanStore)
    }
}
