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
    public let title: String
    public let subtitle: String
    public let rootPath: String
    /// 默认 verdict —— 决定子项默认是否被勾选。
    public let defaultVerdict: SafetyVerdict
    /// v1.0 类目种类。默认 `.preset` 保持向后兼容。
    public let kind: Kind

    public var rootURL: URL { URL(fileURLWithPath: rootPath) }

    public init(id: String, title: String, subtitle: String, rootPath: String,
                defaultVerdict: SafetyVerdict, kind: Kind = .preset) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.rootPath = rootPath
        self.defaultVerdict = defaultVerdict
        self.kind = kind
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
            kind: .custom
        )
    }

    /// v1.0 工厂：整盘扫描（`/`）。
    public static let fullDisk = ScanCategory(
        id: "fulldisk.root",
        title: "整盘扫描",
        subtitle: "/",
        rootPath: "/",
        defaultVerdict: .confirm,
        kind: .fullDisk
    )

    /// v1.0 T4：大文件入口。默认走 `~`（用户主目录），由 `LargeFilesView` 配合
    /// `AppSettings.minFileSizeMB` 阈值过滤后展示 Top N。`rootPath` 可被调用方覆盖
    /// （比如想扫整盘大文件就传 `/`）。
    public static func largeFiles(home: String = NSHomeDirectory()) -> ScanCategory {
        ScanCategory(
            id: "largefiles.home",
            title: "🐘 大文件",
            subtitle: "~（按阈值过滤 Top 200）",
            rootPath: home,
            defaultVerdict: .confirm,
            kind: .largeFiles
        )
    }
}

public enum ScanCategories {
    /// 默认展示的"推荐清理"类目（PITFALLS §5.6：先 5 个，多了反伤）。
    public static func recommended(home: String = NSHomeDirectory()) -> [ScanCategory] {
        [
            .init(
                id: "user.caches",
                title: "用户缓存",
                subtitle: "~/Library/Caches",
                rootPath: "\(home)/Library/Caches",
                defaultVerdict: .safe
            ),
            .init(
                id: "user.logs",
                title: "应用日志",
                subtitle: "~/Library/Logs",
                rootPath: "\(home)/Library/Logs",
                defaultVerdict: .safe
            ),
            .init(
                id: "xcode.derived",
                title: "Xcode 构建产物",
                subtitle: "DerivedData / Archives",
                rootPath: "\(home)/Library/Developer/Xcode/DerivedData",
                defaultVerdict: .safe
            ),
            .init(
                id: "user.downloads",
                title: "下载",
                subtitle: "~/Downloads（confirm，需手动确认）",
                rootPath: "\(home)/Downloads",
                defaultVerdict: .confirm
            ),
            .init(
                id: "trash",
                title: "废纸篓",
                subtitle: "~/.Trash",
                rootPath: "\(home)/.Trash",
                defaultVerdict: .confirm
            )
        ]
    }
}

