import Foundation
import SafetyKit

/// 侧边一级类目。把 BulkScanner 默认从用户友好的"清理类目"出发，
/// 而不是直接给一个 `/`，符合 PITFALLS §5.6（OnyX 教训：选项过多吓退用户）。
public struct ScanCategory: Identifiable, Hashable, Sendable {
    /// 类目种类。v1.0 引入：区分内置推荐、用户自定义路径、整盘扫描三类，
    /// 让 UI 能据此渲染不同图标 / 删除按钮 / 引导文案。
    public enum Kind: String, Hashable, Sendable {
        case preset      // 内置推荐（Caches / Logs / DerivedData / Downloads / .Trash）
        case custom      // 用户通过 + 添加路径 / 拖文件夹加入的任意目录
        case fullDisk    // `/` 整盘扫描（v1.0 T5）
        case largeFiles  // 大文件模块（v1.0 T4）—— 走 home 整树，按阈值过滤平铺 Top N
    }

    public let id: String
    /// 标题：可能是 i18n key（preset/fullDisk/largeFiles 用），也可能是直接显示的字符串（custom 用 path 名）。
    /// 优先用 `displayTitle` 拿本地化文案。
    public let title: String
    /// 副标题：同上。
    public let subtitle: String
    public let rootPath: String
    /// 默认 verdict —— 决定子项默认是否被勾选。
    public let defaultVerdict: SafetyVerdict
    /// v1.0 类目种类。默认 `.preset` 保持向后兼容。
    public let kind: Kind
    /// `title`/`subtitle` 是否为 i18n key（true→用 catalog 翻译；false→直接显示原文，常见于 custom）。
    public let titleIsLocalizationKey: Bool

    public var rootURL: URL { URL(fileURLWithPath: rootPath) }

    /// 本地化后的标题。`titleIsLocalizationKey == false` 时直接返回原值。
    public var displayTitle: String {
        if titleIsLocalizationKey {
            return String(localized: String.LocalizationValue(title), bundle: .module)
        }
        return title
    }

    /// 本地化后的副标题。同上策略。
    public var displaySubtitle: String {
        if titleIsLocalizationKey {
            return String(localized: String.LocalizationValue(subtitle), bundle: .module)
        }
        return subtitle
    }

    public init(id: String, title: String, subtitle: String, rootPath: String,
                defaultVerdict: SafetyVerdict, kind: Kind = .preset,
                titleIsLocalizationKey: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.rootPath = rootPath
        self.defaultVerdict = defaultVerdict
        self.kind = kind
        self.titleIsLocalizationKey = titleIsLocalizationKey
    }

    /// v1.0 工厂：从用户自定义 URL 构造一个 `.custom` 类目。
    /// id 用 path 的 SHA-style 哈希前缀以保证稳定。
    public static func makeCustom(url: URL) -> ScanCategory {
        let p = url.path
        let id = "custom.\(abs(p.hashValue))"
        return ScanCategory(
            id: id,
            title: url.lastPathComponent.isEmpty ? p : url.lastPathComponent,
            subtitle: p,
            rootPath: p,
            defaultVerdict: .confirm,
            kind: .custom,
            titleIsLocalizationKey: false
        )
    }

    /// v1.0 工厂：整盘扫描（`/`）。
    public static let fullDisk = ScanCategory(
        id: "fulldisk.root",
        title: "category.full_disk.title",
        subtitle: "/",
        rootPath: "/",
        defaultVerdict: .confirm,
        kind: .fullDisk,
        titleIsLocalizationKey: true
    )

    // MARK: v1.5 — Batch Scans Sidebar Sentinel IDs
    //
    // toolbar 上的 3 个扫描入口（推荐 / 开发者 / 全盘）以前只能从右上角触发，
    // 用户感知不到"我现在在跑哪条"。v1.5 在 sidebar 顶部新加 Batch Scans section
    // 列 3 行；点 row = 触发对应 toolbar 按钮，扫描进行中 selectedCategory 自动
    // 同步到对应 sentinel id，从而让 sidebar 蓝条高亮跟手。
    //
    // 这 3 个 id 不进 sidebarRow 的标题/副标题渲染（在 sidebarList 里另起 view），
    // 也不会被 allCategories 包含，避免误进 onChange 的 startScan 分支。
    public static let batchRecommendedID: String = "batch.recommended"
    public static let batchDeveloperID: String = "batch.developer"
    public static let batchFullDiskID: String = "batch.fulldisk"
    public static let batchScanIDs: Set<String> = [batchRecommendedID, batchDeveloperID, batchFullDiskID]

    /// v1.0 T4：大文件入口。默认走 `~`（用户主目录），由 `LargeFilesView` 配合
    /// `AppSettings.minFileSizeMB` 阈值过滤后展示 Top N。`rootPath` 可被调用方覆盖
    /// （比如想扫整盘大文件就传 `/`）。
    public static func largeFiles(home: String = NSHomeDirectory()) -> ScanCategory {
        ScanCategory(
            id: "largefiles.home",
            title: "category.large_files.title",
            subtitle: "category.large_files.subtitle",
            rootPath: home,
            defaultVerdict: .confirm,
            kind: .largeFiles,
            titleIsLocalizationKey: true
        )
    }
}

public enum ScanCategories {
    /// 默认展示的"推荐清理"类目（PITFALLS §5.6：先 5 个，多了反伤）。
    public static func recommended(home: String = NSHomeDirectory()) -> [ScanCategory] {
        [
            .init(
                id: "user.caches",
                title: "category.user_caches.title",
                subtitle: "category.user_caches.subtitle",
                rootPath: "\(home)/Library/Caches",
                defaultVerdict: .safe,
                titleIsLocalizationKey: true
            ),
            .init(
                id: "user.logs",
                title: "category.app_logs.title",
                subtitle: "category.app_logs.subtitle",
                rootPath: "\(home)/Library/Logs",
                defaultVerdict: .safe,
                titleIsLocalizationKey: true
            ),
            .init(
                id: "xcode.derived",
                title: "category.xcode.title",
                subtitle: "category.xcode.subtitle",
                rootPath: "\(home)/Library/Developer/Xcode/DerivedData",
                defaultVerdict: .safe,
                titleIsLocalizationKey: true
            ),
            .init(
                id: "user.downloads",
                title: "category.downloads.title",
                subtitle: "category.downloads.subtitle",
                rootPath: "\(home)/Downloads",
                defaultVerdict: .confirm,
                titleIsLocalizationKey: true
            ),
            .init(
                id: "trash",
                title: "category.trash.title",
                subtitle: "category.trash.subtitle",
                rootPath: "\(home)/.Trash",
                defaultVerdict: .confirm,
                titleIsLocalizationKey: true
            )
        ]
    }
}

