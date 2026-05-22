import Foundation
import SwiftUI

/// v1.2 P2-3：按扩展名把大文件分到 8 个语义桶，每桶自带 SF Symbol 与色卡。
///
/// 设计要点：
/// 1. **决策维度**与 LargeFileSortKey 一致 —— 大文件清理的核心是"这是哪类东西"，
///    用户决策"该不该删"几乎都先看类型，再看大小。所以入桶比单独的扩展名图标更有用。
/// 2. **色卡选择**走"语义直觉"：视频暖红、镜像紫、归档橙、安装绿、设计粉、代码青、
///    文档灰、其他石板灰。避免和系统强调色（Color.accentColor）冲突。
/// 3. **公开静态扩展名映射**便于单测与 UI 共用同一份事实来源；不再让 UI 重复写 switch。
/// 4. **all 桶**作为筛选 chip 的"全部"档；FileKind 自己不参与"全部"逻辑——
///    UI 用 `Optional<FileKind>` 表达"无筛选"。
public enum FileKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case video       // mov mp4 mkv avi m4v webm flv
    case image       // jpg jpeg png gif heic webp tiff bmp svg raw
    case audio       // mp3 m4a aac flac wav ogg aiff
    case archive     // zip tar gz bz2 xz 7z rar tgz
    case disk        // iso dmg img vmdk vdi qcow2
    case installer   // pkg ipa app deb msi
    case design      // psd ai sketch fig xd indd
    case document    // pdf doc docx xls xlsx ppt pptx txt md log csv
    case code        // swift c h cpp m mm py js ts go rs java kt sql json xml plist yml yaml
    case other       // 兜底

    public var id: String { rawValue }

    /// 用户可见名称。
    public var label: String {
        switch self {
        case .video:     return "视频"
        case .image:     return "图片"
        case .audio:     return "音频"
        case .archive:   return "归档"
        case .disk:      return "镜像"
        case .installer: return "安装包"
        case .design:    return "设计稿"
        case .document:  return "文档"
        case .code:      return "代码"
        case .other:     return "其他"
        }
    }

    /// SF Symbol 名（Image(systemName:) 直接用）。
    public var systemImageName: String {
        switch self {
        case .video:     return "film"
        case .image:     return "photo"
        case .audio:     return "music.note"
        case .archive:   return "archivebox"
        case .disk:      return "opticaldisc"
        case .installer: return "shippingbox"
        case .design:    return "paintbrush"
        case .document:  return "doc.richtext"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .other:     return "doc"
        }
    }

    /// 染色色卡。**故意不用 Color.accent**，避开与"选中态"强调色冲突。
    public var tint: Color {
        switch self {
        case .video:     return Color(red: 0.86, green: 0.31, blue: 0.34) // 暖红
        case .image:     return Color(red: 0.20, green: 0.65, blue: 0.78) // 海蓝
        case .audio:     return Color(red: 0.55, green: 0.40, blue: 0.85) // 紫
        case .archive:   return Color(red: 0.92, green: 0.58, blue: 0.20) // 琥珀橙
        case .disk:      return Color(red: 0.40, green: 0.30, blue: 0.70) // 深紫
        case .installer: return Color(red: 0.30, green: 0.70, blue: 0.40) // 草绿
        case .design:    return Color(red: 0.88, green: 0.42, blue: 0.66) // 粉
        case .document:  return Color(red: 0.45, green: 0.55, blue: 0.65) // 石板蓝
        case .code:      return Color(red: 0.20, green: 0.55, blue: 0.65) // 青
        case .other:     return Color.secondary
        }
    }

    /// 主映射：扩展名（小写无 `.`）→ 桶。
    /// 故意暴露 `static let` 而不是私有 dict —— 单测可以直接断言映射规则。
    public static let extensionMap: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        let table: [(FileKind, [String])] = [
            (.video,     ["mov", "mp4", "mkv", "avi", "m4v", "webm", "flv", "wmv", "ts"]),
            (.image,     ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp",
                          "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef", "arw"]),
            (.audio,     ["mp3", "m4a", "aac", "flac", "wav", "ogg", "aiff", "ape"]),
            (.archive,   ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "tbz", "txz"]),
            (.disk,      ["iso", "dmg", "img", "vmdk", "vdi", "qcow2", "sparseimage"]),
            (.installer, ["pkg", "ipa", "app", "deb", "msi", "rpm"]),
            (.design,    ["psd", "ai", "sketch", "fig", "xd", "indd"]),
            (.document,  ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
                          "txt", "md", "log", "csv", "rtf", "pages", "numbers", "key"]),
            (.code,      ["swift", "c", "h", "cpp", "cc", "m", "mm",
                          "py", "js", "ts", "tsx", "jsx",
                          "go", "rs", "java", "kt", "kts", "scala", "rb", "php",
                          "sql", "json", "xml", "plist", "yml", "yaml",
                          "html", "css", "sh", "zsh", "bash", "fish"])
        ]
        for (kind, exts) in table {
            for ext in exts { m[ext] = kind }
        }
        return m
    }()

    /// 入桶 —— 取扩展名小写后查表，未命中给 `.other`。
    public static func from(extension ext: String) -> FileKind {
        guard !ext.isEmpty else { return .other }
        return extensionMap[ext.lowercased()] ?? .other
    }

    /// 入桶（path 路径版）。
    public static func from(path: String) -> FileKind {
        from(extension: (path as NSString).pathExtension)
    }
}

public extension LargeFileItem {
    /// v1.2 P2-3：当前文件所属桶。基于 `fileExtension`（小写无 `.`）。
    var kind: FileKind { FileKind.from(extension: fileExtension) }
}
