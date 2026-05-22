import Foundation
import Observation

/// v1.0 用户偏好（隐藏文件 toggle / 大文件阈值 / 排序方式）。
///
/// 设计要点：
/// 1. 走 `UserDefaults`（默认 `.standard`，单测可注入隔离 suite），
///    避开 `@AppStorage` 的 SwiftUI 属性包装器在跨 actor / 单测下的麻烦。
/// 2. 用 `@Observable`（Swift 6.0 / macOS 15+ 原生），SwiftUI 视图直接 `@Bindable` 即可双向绑定。
/// 3. 决策来源：[docs/ROADMAP_V1.md](../../../../docs/ROADMAP_V1.md) §0 用户拍板
///    "隐藏文件默认 OFF + 显式开关"。
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

    // MARK: - 后端

    private let defaults: UserDefaults

    /// 是否在扫描结果中显示 `.` 开头的隐藏文件。**默认 OFF**（v1.0 拍板）。
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
        // 这样首启默认值才能落地为 false 而非被 bool(forKey:) 的 false 默认覆盖。
        if let raw = defaults.object(forKey: Keys.showHidden) as? Bool {
            self.showHidden = raw
        } else {
            self.showHidden = false
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
    }

    /// 单测专用：把当前实例所有键从 defaults 清掉。
    public func _testReset() {
        defaults.removeObject(forKey: Keys.showHidden)
        defaults.removeObject(forKey: Keys.minFileSizeMB)
        defaults.removeObject(forKey: Keys.sortKey)
        defaults.removeObject(forKey: Keys.updateCheckEnabled)
        defaults.removeObject(forKey: Keys.skippedUpdateTag)
        defaults.removeObject(forKey: Keys.mtimeFilter)
    }
}
