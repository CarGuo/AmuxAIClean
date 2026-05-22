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

    public init(id: String, url: URL, title: String, isDirectory: Bool, bytes: Int64,
                logicalBytes: Int64, fileCount: Int, verdict: SafetyVerdict, rejection: SafetyRejection,
                vendorName: String? = nil, vendorNote: String? = nil) {
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
    }

    /// `forbid` 项不允许勾选；其余可勾。
    public var isSelectable: Bool { verdict != .forbid }

    /// UI 默认是否勾上：仅 `.safe`。
    public var defaultSelected: Bool { verdict == .safe }
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

    public var id: String { path }

    public init(path: String, title: String, bytes: Int64, fileCount: Int,
                isDirectory: Bool, hasChildren: Bool) {
        self.path = path
        self.title = title
        self.bytes = bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.hasChildren = hasChildren
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

    /// 抽象出"主列"：UI 用它判断点的是哪一列、画哪一个箭头。
    public enum Column: String, CaseIterable, Sendable {
        case size, name, count
    }

    public var column: Column {
        switch self {
        case .sizeDesc, .sizeAsc:   return .size
        case .nameAsc, .nameDesc:   return .name
        case .countDesc, .countAsc: return .count
        }
    }

    public var isDescending: Bool {
        switch self {
        case .sizeDesc, .nameDesc, .countDesc: return true
        case .sizeAsc, .nameAsc, .countAsc:    return false
        }
    }

    /// 给 UI 用：当前点击 column 应该切到的下一个排序键。
    /// - 已是该列 → 反转方向
    /// - 不是该列 → size/count 默认 desc，name 默认 asc（符合 Finder 习惯）
    public func toggled(to column: Column) -> TreeSortKey {
        if column == self.column {
            switch self {
            case .sizeDesc:  return .sizeAsc
            case .sizeAsc:   return .sizeDesc
            case .nameAsc:   return .nameDesc
            case .nameDesc:  return .nameAsc
            case .countDesc: return .countAsc
            case .countAsc:  return .countDesc
            }
        }
        switch column {
        case .size:  return .sizeDesc
        case .name:  return .nameAsc
        case .count: return .countDesc
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
}

/// UI 节流后的扫描快照。
public struct ScanSnapshot: Sendable {
    public let categoryID: String
    public let rows: [RowItem]
    public let totalBytes: Int64
    public let scannedFileCount: Int
    public let isFinished: Bool
    public let elapsed: TimeInterval

    public static let empty = ScanSnapshot(categoryID: "", rows: [], totalBytes: 0, scannedFileCount: 0, isFinished: false, elapsed: 0)

    public init(categoryID: String, rows: [RowItem], totalBytes: Int64,
                scannedFileCount: Int, isFinished: Bool, elapsed: TimeInterval) {
        self.categoryID = categoryID
        self.rows = rows
        self.totalBytes = totalBytes
        self.scannedFileCount = scannedFileCount
        self.isFinished = isFinished
        self.elapsed = elapsed
    }
}
