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
    /// 可选的长说明：用于 tooltip / help，不参与扫描或排序热路径。
    public let help: String?
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
        displayTitle(locale: .current)
    }

    /// 按当前 SwiftUI 环境 locale 解析侧栏标题。
    /// `displayTitle` 保留给非 UI / 旧调用方；运行期可切语言的 View 必须使用本入口。
    public func displayTitle(locale: Locale) -> String {
        titleIsLocalizationKey ? AppLocalization.string(title, locale: locale) : title
    }

    /// 本地化后的副标题。同上策略。
    public var displaySubtitle: String {
        displaySubtitle(locale: .current)
    }

    public func displaySubtitle(locale: Locale) -> String {
        titleIsLocalizationKey ? AppLocalization.string(subtitle, locale: locale) : subtitle
    }

    /// 本地化后的长说明；未配置时退回副标题。
    public var displayHelp: String {
        displayHelp(locale: .current)
    }

    public func displayHelp(locale: Locale) -> String {
        guard let help else { return displaySubtitle(locale: locale) }
        return titleIsLocalizationKey ? AppLocalization.string(help, locale: locale) : help
    }

    /// 仅在显式配置长说明时返回 tooltip 文案；避免普通分类多做一次本地化。
    public var displayHelpIfConfigured: String? {
        displayHelpIfConfigured(locale: .current)
    }

    public func displayHelpIfConfigured(locale: Locale) -> String? {
        guard let help else { return nil }
        return titleIsLocalizationKey ? AppLocalization.string(help, locale: locale) : help
    }

    public init(id: String, title: String, subtitle: String, rootPath: String,
                defaultVerdict: SafetyVerdict, kind: Kind = .preset,
                titleIsLocalizationKey: Bool = false,
                help: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.help = help
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
    // toolbar 上的扫描入口（推荐 / 开发者 / 全盘 / 常见软件缓存）以前只能从右上角触发，
    // 用户感知不到"我现在在跑哪条"。v1.5 在 sidebar 顶部新加 Batch Scans section
    // 列出这些入口；点 row = 触发对应 toolbar 按钮，扫描进行中 selectedCategory 自动
    // 同步到对应 sentinel id，从而让 sidebar 蓝条高亮跟手。
    //
    // 这 3 个 id 不进 sidebarRow 的标题/副标题渲染（在 sidebarList 里另起 view），
    // 也不会被 allCategories 包含，避免误进 onChange 的 startScan 分支。
    public static let batchRecommendedID: String = "batch.recommended"
    public static let batchDeveloperID: String = "batch.developer"
    public static let batchFullDiskID: String = "batch.fulldisk"
    public static let batchCommonAppCacheID: String = "batch.common_app_cache"
    public static let batchScanIDs: Set<String> = [
        batchRecommendedID,
        batchDeveloperID,
        batchFullDiskID,
        batchCommonAppCacheID
    ]

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
                titleIsLocalizationKey: true,
                help: "category.xcode.help"
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

    /// Smart Care 的“系统与日志”范围。
    ///
    /// 普通模式的三个范围必须映射到互不重叠的真实扫描计划：
    /// - core：日志；
    /// - appCaches：由 CommonAppCacheScanner 扫应用缓存；
    /// - developerCaches：由 DevArtifactScanner 扫开发者构建产物。
    ///
    /// 因此这里不能直接复用 `recommended` 的全部 5 根：`~/Library/Caches`
    /// 与 DerivedData 会分别和后两个范围重复，Downloads / .Trash 又会被从整个
    /// home 勘察开发者产物的 scanner 二次遍历。个人文件与废纸篓仍保留在专业模式。
    public static func smartCareCore(home: String = NSHomeDirectory()) -> [ScanCategory] {
        let coreIDs: Set<String> = ["user.logs"]
        return recommended(home: home).filter { coreIDs.contains($0.id) }
    }

    /// 开发者扫描必须显式包含的已知安全根。
    ///
    /// DevArtifactScanner 为避免 TCC/误命中会剪掉整个 `~/Library`，因此无法通过
    /// “从 home 找目录名”的启发式发现 Xcode DerivedData。这里复用推荐分类这一份
    /// 路径真相，避免在 Smart Care、Professional 和设置页各写一条路径常量。
    public static func developerCacheRoots(home: String = NSHomeDirectory()) -> [ScanCategory] {
        let developerCacheIDs: Set<String> = ["xcode.derived"]
        return recommended(home: home).filter { developerCacheIDs.contains($0.id) }
    }
}
