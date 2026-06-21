import Foundation
import ScanKit
import SafetyKit

/// 列表行模型 —— 用聚合到第一级子目录的方式展示，避免 4w 文件全平铺（PITFALLS §5.4）。
public struct RowItem: Identifiable, Hashable, Sendable {
    public let id: String          // = url.path（稳定 ID）
    public let url: URL
    public let title: String       // = lastPathComponent
    public let isDirectory: Bool
    public let bytes: Int64        // allocatedSize 累计
    public let logicalBytes: Int64 // logicalSize 累计；与 bytes 偏差大表示 iCloud 占位
    public let fileCount: Int      // 子项总数
    public let verdict: SafetyVerdict
    public let rejection: SafetyRejection
    public let vendorName: String?
    public let vendorNote: String?
    /// v1.3：该聚合行是否"正在被扫描"。
    ///
    /// 判定来自 [ScanCoordinator](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/ScanCoordinator.swift)
    /// 维护的 `lastIngestAt[bucketPath]`：该 bucket 最近一次 ingest 距 publishSnapshot 时间 < 800ms 即视为 active。
    /// UI 给 active 行的 bytes 数字上色 + 轻微脉动，让用户一眼看出多 worker 同时在扫不同子树。
    /// 扫描结束后所有行的 isActive 一律 false。
    public let isActive: Bool
    /// v1.5.4：该行（聚合后第一级子目录或单个文件）对应 inode 的最近修改时间。
    ///
    /// 设计选择（A 方案，与 Finder 一致）：聚合行采用**目录自身 inode** 的 mtime，
    /// 即 ScanCoordinator 在 ingest 阶段从 [FSNode.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/FSNode.swift#L14)
    /// 取来直接挂上；不走"max(子孙 mtime)"聚合，避免 dirIndex 多维护一字段以及 publish 抖动。
    /// 数据来源已经在扫描层免费——[BulkScanner.enumerate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L390-L412)
    /// 的 attrlist 位图已请求 ATTR_CMN_MODTIME，本字段从源头透传过来不增加 syscall。
    /// 可选是因为：极早期 publish 帧 / store-fallback 拉到的旧记录可能缺失。
    public let modificationDate: Date?

    public init(id: String, url: URL, title: String, isDirectory: Bool, bytes: Int64,
                logicalBytes: Int64, fileCount: Int, verdict: SafetyVerdict, rejection: SafetyRejection,
                vendorName: String? = nil, vendorNote: String? = nil,
                isActive: Bool = false,
                modificationDate: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.verdict = verdict
        self.rejection = rejection
        self.vendorName = vendorName
        self.vendorNote = vendorNote
        self.isActive = isActive
        self.modificationDate = modificationDate
    }

    /// `forbid` 项不允许勾选；其余可勾。
    public var isSelectable: Bool { verdict != .forbid }

    /// UI 默认是否勾上：仅 `.safe`。
    public var defaultSelected: Bool { verdict == .safe }
}

/// v1.3：主列表（推荐清理 / 自定义路径）排序键。
///
/// 设计要点：
/// - 默认值 `.sizeDesc`（按字节大小降序）—— 大的清理项先出现，符合"挑大的删"的直觉
/// - 与 [TreeSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L72)
///   不复用：树视图含 count 列；主列表行的 fileCount 也展示，但维度更少（无独立列头）
/// - **扫描进行中不参与排序选择**——publishSnapshot 在 finished=false 阶段强制按 path 字典序，
///   保证多 worker 同时刷新时行位置稳定，避免"只一行在动"错觉（v1.3 修订背景见 ScanCoordinator）；
///   `finished=true` 那一帧才按用户选定的 sortKey 排
public enum MainListSortKey: String, CaseIterable, Sendable, Hashable, Identifiable {
    case sizeDesc
    case sizeAsc
    case nameAsc
    case nameDesc
    case fileCountDesc
    case fileCountAsc
    /// v1.5.4：按修改时间排序——最近改的在前 / 最久没动的在前。
    /// 与 sizeDesc 并列常用："找最大的删 / 找最久没动的删"。
    case mtimeDesc
    case mtimeAsc

    public var id: String { rawValue }

    /// UI 菜单文案。
    public var label: String {
        switch self {
        case .sizeDesc:      return String(localized: "sort.size.desc", bundle: .module)
        case .sizeAsc:       return String(localized: "sort.size.asc", bundle: .module)
        case .nameAsc:       return String(localized: "sort.name.asc", bundle: .module)
        case .nameDesc:      return String(localized: "sort.name.desc", bundle: .module)
        case .fileCountDesc: return String(localized: "sort.filecount.desc", bundle: .module)
        case .fileCountAsc:  return String(localized: "sort.filecount.asc", bundle: .module)
        case .mtimeDesc:     return String(localized: "sort.mtime.desc", bundle: .module)
        case .mtimeAsc:      return String(localized: "sort.mtime.asc", bundle: .module)
        }
    }

    /// 比较函数。主键相等时一律按 path 升序兜底，保证 ForEach 不抖。
    public func lessThan(_ a: RowItem, _ b: RowItem) -> Bool {
        switch self {
        case .sizeDesc:
            if a.bytes != b.bytes { return a.bytes > b.bytes }
        case .sizeAsc:
            if a.bytes != b.bytes { return a.bytes < b.bytes }
        case .nameAsc:
            let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
            if cmp != .orderedSame { return cmp == .orderedAscending }
        case .nameDesc:
            let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
            if cmp != .orderedSame { return cmp == .orderedDescending }
        case .fileCountDesc:
            if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
        case .fileCountAsc:
            if a.fileCount != b.fileCount { return a.fileCount < b.fileCount }
        case .mtimeDesc:
            // nil mtime（缺失）一律排最后，避免它们抢占"最近改"头部。
            switch (a.modificationDate, b.modificationDate) {
            case let (l?, r?): if l != r { return l > r }
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   break
            }
        case .mtimeAsc:
            // nil mtime 同样压最后——避免污染"最久没动"头部。
            switch (a.modificationDate, b.modificationDate) {
            case let (l?, r?): if l != r { return l < r }
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   break
            }
        }
        return a.id < b.id
    }
}

/// v1.0 T3：树视图行模型 —— 给 OutlineGroup / TreeBrowserView 用。
/// 故意比 RowItem 简一档：树视图只展示 size 与层级，不参与勾选清理决策。
public struct TreeRow: Identifiable, Hashable, Sendable {
    public let path: String
    public let title: String
    public let bytes: Int64
    public let fileCount: Int
    public let isDirectory: Bool
    /// 是否还有 direct children 可展开 —— 用于 OutlineGroup 决定要不要画披露三角。
    public let hasChildren: Bool
    /// v1.3.zzzz：访问状态——区分"真的 0KB"和"被 sandbox/TCC/permission denied 拦掉看不到"。
    /// UI 据此渲染锁定徽章 + tooltip + 不可勾选；不打 banner 误导用户以为是 bug。
    public let accessState: AccessState
    /// v1.5.4：节点 inode 自身的最近修改时间。
    ///
    /// 与 [RowItem.modificationDate](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L33)
    /// 一致采用 Finder 风格——目录就是它自己 inode 的 mtime（修改子项时由内核自动更新），
    /// 不再额外聚合 max(子孙)。store-fallback 路径会从 GRDB.modification_date 列拉。
    public let modificationDate: Date?

    public enum AccessState: String, Sendable, Hashable, Codable {
        /// 正常扫描得到的数据
        case normal
        /// 被 BulkScanner 的 [permissionDenied](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L175) 拦掉
        /// （open(O_RDONLY) 失败，子目录里所有文件都没 emit）
        case permissionDenied
        /// 被 TCC 雷区硬 skip（[respectTCCSkipList](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift#L210)），
        /// 通常是用户没给 Full Disk Access
        case tccProtected
    }

    public var id: String { path }

    public init(path: String, title: String, bytes: Int64, fileCount: Int,
                isDirectory: Bool, hasChildren: Bool,
                accessState: AccessState = .normal,
                modificationDate: Date? = nil) {
        self.path = path
        self.title = title
        self.bytes = bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.hasChildren = hasChildren
        self.accessState = accessState
        self.modificationDate = modificationDate
    }
}

/// v1.0 T5：树视图列排序键。
///
/// 设计要点：
/// - 升降两态由枚举 case 直接表达，省去 (key, ascending) 二元组的同步问题
/// - 同一列再点 → toggle 升降序；不同列点 → 按 UI 习惯，size/count 默认降序，name 默认升序
/// - 排序时主键相等永远 fallback 到 path 升序，避免 ForEach 抖动
public enum TreeSortKey: String, CaseIterable, Sendable, Hashable {
    case sizeDesc, sizeAsc
    case nameAsc, nameDesc
    case countDesc, countAsc
    /// v1.5.4：按修改时间排序——和 LargeFileSortKey.mtime 对齐。
    case mtimeDesc, mtimeAsc

    /// 抽象出"主列"：UI 用它判断点的是哪一列、画哪一个箭头。
    public enum Column: String, CaseIterable, Sendable {
        case size, name, count, mtime
    }

    public var column: Column {
        switch self {
        case .sizeDesc, .sizeAsc:   return .size
        case .nameAsc, .nameDesc:   return .name
        case .countDesc, .countAsc: return .count
        case .mtimeDesc, .mtimeAsc: return .mtime
        }
    }

    public var isDescending: Bool {
        switch self {
        case .sizeDesc, .nameDesc, .countDesc, .mtimeDesc: return true
        case .sizeAsc, .nameAsc, .countAsc, .mtimeAsc:    return false
        }
    }

    /// 给 UI 用：当前点击 column 应该切到的下一个排序键。
    /// - 已是该列 → 反转方向
    /// - 不是该列 → size/count/mtime 默认 desc，name 默认 asc（符合 Finder 习惯）
    public func toggled(to column: Column) -> TreeSortKey {
        if column == self.column {
            switch self {
            case .sizeDesc:  return .sizeAsc
            case .sizeAsc:   return .sizeDesc
            case .nameAsc:   return .nameDesc
            case .nameDesc:  return .nameAsc
            case .countDesc: return .countAsc
            case .countAsc:  return .countDesc
            case .mtimeDesc: return .mtimeAsc
            case .mtimeAsc:  return .mtimeDesc
            }
        }
        switch column {
        case .size:  return .sizeDesc
        case .name:  return .nameAsc
        case .count: return .countDesc
        case .mtime: return .mtimeDesc
        }
    }

    /// v1.5 P2 / Q1：把全局 [MainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L71)
    /// 映射到树视图排序键。
    ///
    /// 树视图 4 列（size/name/count/mtime）几乎与主列表一一对应；fileCount 映到 count。
    /// 用法：TreeBrowserView 不再持 @State，改 `TreeSortKey.from(global: settings.mainListSortKey)`。
    public static func from(global key: MainListSortKey) -> TreeSortKey {
        switch key {
        case .sizeDesc:      return .sizeDesc
        case .sizeAsc:       return .sizeAsc
        case .nameAsc:       return .nameAsc
        case .nameDesc:      return .nameDesc
        case .fileCountDesc: return .countDesc
        case .fileCountAsc:  return .countAsc
        case .mtimeDesc:     return .mtimeDesc
        case .mtimeAsc:      return .mtimeAsc
        }
    }

    /// 反向映射：列头点击后写回全局键，让所有列表保持同步。
    public var asGlobal: MainListSortKey {
        switch self {
        case .sizeDesc:  return .sizeDesc
        case .sizeAsc:   return .sizeAsc
        case .nameAsc:   return .nameAsc
        case .nameDesc:  return .nameDesc
        case .countDesc: return .fileCountDesc
        case .countAsc:  return .fileCountAsc
        case .mtimeDesc: return .mtimeDesc
        case .mtimeAsc:  return .mtimeAsc
        }
    }
}

/// v1.0 T4：大文件列表行模型。
///
/// 与 RowItem / TreeRow 区分原因：
/// - RowItem 是"按一级目录聚合后"的行（用于推荐清理 / 自定义路径）；
/// - TreeRow 是"目录树"任意层一行（用于多层下钻）；
/// - LargeFileItem **总是叶子文件**（isDirectory=false 隐含），
///   字段最少：path / bytes / mtime + 类型图标用的扩展名。
public struct LargeFileItem: Identifiable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let modificationDate: Date?

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var title: String { (path as NSString).lastPathComponent }
    /// 取扩展名（小写，无 `.`），无后缀给空串，UI 据此选 SF Symbol。
    public var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    public init(path: String, bytes: Int64, modificationDate: Date?) {
        self.path = path
        self.bytes = bytes
        self.modificationDate = modificationDate
    }
}

/// v1.0 T4：大文件列表排序键。
///
/// 仅 4 个：size↓ / size↑ / mtime↓ / mtime↑（ROADMAP T4 验收 2 明确写）。
/// 不含 name 排序：大文件列表的核心维度是"占多大、放多久没动"，name 不是决策点。
public enum LargeFileSortKey: String, CaseIterable, Sendable, Hashable {
    case sizeDesc, sizeAsc
    case mtimeDesc, mtimeAsc

    public enum Column: String, CaseIterable, Sendable {
        case size, mtime
    }

    public var column: Column {
        switch self {
        case .sizeDesc, .sizeAsc:   return .size
        case .mtimeDesc, .mtimeAsc: return .mtime
        }
    }

    public var isDescending: Bool {
        switch self {
        case .sizeDesc, .mtimeDesc: return true
        case .sizeAsc, .mtimeAsc:   return false
        }
    }

    /// 点击列头切换排序：相同列反转方向，不同列默认降序（"大的先来 / 老的先来"符合直觉）。
    public func toggled(to column: Column) -> LargeFileSortKey {
        if column == self.column {
            switch self {
            case .sizeDesc:  return .sizeAsc
            case .sizeAsc:   return .sizeDesc
            case .mtimeDesc: return .mtimeAsc
            case .mtimeAsc:  return .mtimeDesc
            }
        }
        switch column {
        case .size:  return .sizeDesc
        case .mtime: return .mtimeDesc
        }
    }

    /// v1.5 P2 / Q1：把全局 [MainListSortKey](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/RowItem.swift#L71)
    /// 映射到大文件列表自己支持的子集。
    ///
    /// 大文件列表只展示 size + mtime 两列：
    /// - size / fileCount 维度（fileCount 在大文件无意义） → 全归 size 方向
    /// - name 维度（大文件没有"name 列"） → 也归 size desc（用户体感最一致）
    /// - mtime 维度 → 直接对应
    ///
    /// 用法：LargeFilesView 不再持 @State，改 `LargeFileSortKey.from(global: settings.mainListSortKey)`。
    public static func from(global key: MainListSortKey) -> LargeFileSortKey {
        switch key {
        case .sizeDesc, .fileCountDesc, .nameAsc, .nameDesc:
            return .sizeDesc
        case .sizeAsc, .fileCountAsc:
            return .sizeAsc
        case .mtimeDesc:
            return .mtimeDesc
        case .mtimeAsc:
            return .mtimeAsc
        }
    }

    /// 反向映射：列头点击后写回全局键。
    /// 大文件只有 size / mtime 两维，回写时其它维度保持不变（由调用方决定怎么 merge）。
    public var asGlobal: MainListSortKey {
        switch self {
        case .sizeDesc:  return .sizeDesc
        case .sizeAsc:   return .sizeAsc
        case .mtimeDesc: return .mtimeDesc
        case .mtimeAsc:  return .mtimeAsc
        }
    }
}

/// UI 节流后的扫描快照。
public struct ScanSnapshot: Sendable {
    public let categoryID: String
    public let rows: [RowItem]
    public let totalBytes: Int64
    public let scannedFileCount: Int
    public let isFinished: Bool
    public let elapsed: TimeInterval
    /// v1.3：实时扫描吞吐（bytes/s），EWMA 平滑后的速率。0 表示尚未估出。
    /// 用法：HUD 显示 "MB/s"；估算 ETA 时 / bytesPerSecond。
    public let bytesPerSecond: Double
    /// v1.3：预计剩余耗时（秒）。仅在以下条件全部成立时给出：
    ///   1) 当前在扫整盘且 [VolumeCapacity.Snapshot](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/ScanKit/Sources/ScanKit/VolumeCapacity.swift) 已知（有"已用容量"作上限）；
    ///   2) bytesPerSecond > 0 且 elapsed > 0.5s（采样不足时不报，避免开始 100ms 就显示"还需 6 小时"）；
    /// 否则为 nil —— UI 显示"估算中…"。
    public let estimatedRemaining: TimeInterval?

    public static let empty = ScanSnapshot(categoryID: "", rows: [], totalBytes: 0,
                                           scannedFileCount: 0, isFinished: false, elapsed: 0,
                                           bytesPerSecond: 0, estimatedRemaining: nil)

    public init(categoryID: String, rows: [RowItem], totalBytes: Int64,
                scannedFileCount: Int, isFinished: Bool, elapsed: TimeInterval,
                bytesPerSecond: Double = 0, estimatedRemaining: TimeInterval? = nil) {
        self.categoryID = categoryID
        self.rows = rows
        self.totalBytes = totalBytes
        self.scannedFileCount = scannedFileCount
        self.isFinished = isFinished
        self.elapsed = elapsed
        self.bytesPerSecond = bytesPerSecond
        self.estimatedRemaining = estimatedRemaining
    }

    /// v1.3：用户语义"还未扫描过"的判定。
    /// 三态划分：isPristine（未开始）/ !isFinished && !isPristine（扫描中）/ isFinished（完成）。
    /// UI 用它区分"刚启动还没扫"和"扫完真的是 0 KB"，避免空状态显示 "0 KB · 0 个文件"。
    /// 判定条件：还没标 finished，且没扫过任何文件，且 rows 也是空。
    public var isPristine: Bool {
        !isFinished && scannedFileCount == 0 && rows.isEmpty
    }

    // MARK: - 可清理口径（v1.6 / 2026-06）
    //
    // 设计背景：截图反馈"扫多少 = Cleanable 多少"被用户当面质疑后，把"可清理字节数"
    // 收敛到 **ScanSnapshot 内** 作为单一权威口径，杜绝 totalBytes 被错灌进 sidebar 的
    // VolumeCapacityCard 的历史 bug（MainView.swift L318 旧赋值）。
    //
    // 业界对齐（CleanMyMac / Onyx / macOS Storage）：
    //   - "Cleanable" **只**计入安全可一键清理的桶（缓存 / 日志 / DerivedData / Trash 等），
    //     对应本项目的 SafetyVerdict.safe；
    //   - .confirm 项需用户审阅，独立桶单算（confirmBytes），UI 可拆为"需要确认"段；
    //   - .forbid 项是绝对不动（SIP / 用户文档 / 凭证），列出来仅为审计。
    //
    // 实现取舍：
    //   - O(N) reduce on rows —— rows 已是节流后聚合（一级子目录），数量级几十~几百行，
    //     远低于 ScanSnapshot publish 频率（节流 ≥150ms），不需要缓存；
    //   - 单元测试 [CleanableBytesContractTests] 守恒：safe + confirm + forbid == Σrows.bytes，
    //     防止后续 SafetyVerdict 增枚举时漏改这里。

    /// `.safe` 行字节合计 —— 即业界口径的"Cleanable / Auto-cleanable"。
    public var safeBytes: Int64 {
        rows.reduce(0) { $1.verdict == .safe ? $0 + $1.bytes : $0 }
    }

    /// `.confirm` 行字节合计 —— "需要用户确认"段，UI 应单列，**不要**并进 cleanable 数字。
    public var confirmBytes: Int64 {
        rows.reduce(0) { $1.verdict == .confirm ? $0 + $1.bytes : $0 }
    }

    /// `.forbid` 行字节合计 —— 仅供审计 / 调试输出，UI 一般不展示。
    public var forbidBytes: Int64 {
        rows.reduce(0) { $1.verdict == .forbid ? $0 + $1.bytes : $0 }
    }

    /// 业界口径的"可清理字节数"——**仅** `.safe` 行求和。
    ///
    /// **必须**用作 [VolumeCapacityCard.cleanableBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/VolumeCapacityCard.swift#L26) /
    /// [FloatingScanHUD.cleanableBytes](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/FloatingScanHUD.swift) 的唯一来源。
    /// **禁止**再回退到 `totalBytes`——那是已扫总量，跟"能不能删"无关。
    public var cleanableBytes: Int64 { safeBytes }
}
