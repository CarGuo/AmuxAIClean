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
    }

    /// 单测专用：把当前实例所有键从 defaults 清掉。
    public func _testReset() {
        defaults.removeObject(forKey: Keys.showHidden)
        defaults.removeObject(forKey: Keys.minFileSizeMB)
        defaults.removeObject(forKey: Keys.sortKey)
    }
}
