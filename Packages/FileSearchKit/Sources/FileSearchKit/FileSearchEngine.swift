import Foundation

/// FileSearchKit MVP（Step 16-A）—— 仓库内最小可用 file-search engine。
///
/// 设计原则：
/// - **零外部依赖**：仅 Foundation，便于在任何 SPM consumer 里直接加 product。
/// - **流式输出**：`AsyncStream<FileSearchResult>` 让 UI 立刻能渲染第一个结果（参考
///   [Pearcleaner FileSearchLogic L109](file:///Users/amuxuser/workspace/AmuxAIClean/tmp/competitors/Pearcleaner/Pearcleaner/Logic/FileSearch/FileSearchLogic.swift#L109)
///   batchSize=1 的"立即出第一个结果"语义）。
/// - **`Sendable` + actor cancel**：`AsyncStream` 自带 cancel；engine 不持有可变状态，
///   每次搜索作为独立 task 跑，方便 SwiftUI 调用方一改 query 就 cancel 上一次。
/// - **Step 16-A MVP 4 类 filter**：name / extension / size / kind
/// - **Step 16-A2 增量**：date / tags / comment（达到 docs/AUDIT_2026_06.md L101 要求的 7 类）
public enum FileSearchFilter: Sendable, Equatable {
    /// 文件名匹配（case-insensitive substring；空串视作 match-all）
    case name(NameMatch, String)
    /// 扩展名（lowercased，无前导点；多个用 includes/excludes 集合）
    case fileExtension(ExtensionMatch, [String])
    /// 文件 size（字节；directory size 视作 0，不递归汇总）
    case size(SizeMatch)
    /// 类型（file / folder）
    case kind(KindMatch)
    /// 修改时间（mtime）——createdAt 在 macOS 不一定可靠，MVP 只做 mtime
    case date(DateMatch)
    /// Finder Tags（URLResourceKey.tagNamesKey）
    case tags(TagMatch)
    /// Finder Comment（xattr com.apple.metadata:kMDItemFinderComment + plist 反序列化）
    case comment(CommentMatch)

    public enum NameMatch: Sendable, Equatable {
        case contains
        case startsWith
        case endsWith
        case equals
    }

    public enum ExtensionMatch: Sendable, Equatable {
        case includes
        case excludes
    }

    public enum SizeMatch: Sendable, Equatable {
        case greaterThan(Int64)
        case lessThan(Int64)
        case between(Int64, Int64)
    }

    public enum KindMatch: Sendable, Equatable {
        case fileOnly
        case folderOnly
    }

    public enum DateMatch: Sendable, Equatable {
        case modifiedBefore(Date)
        case modifiedAfter(Date)
        case modifiedBetween(Date, Date)
    }

    public enum TagMatch: Sendable, Equatable {
        case hasTag(String)
        case hasAnyOf([String])
        case hasAllOf([String])
        case isEmpty
    }

    public enum CommentMatch: Sendable, Equatable {
        case contains(String)
        case equals(String)
        case isEmpty
    }
}

public struct FileSearchResult: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let dateModified: Date

    public init(url: URL, name: String, isDirectory: Bool, size: Int64, dateModified: Date) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.dateModified = dateModified
    }
}

public struct FileSearchOptions: Sendable {
    public var includeHidden: Bool
    public var caseSensitive: Bool
    public var includeSubfolders: Bool

    public init(includeHidden: Bool = false,
                caseSensitive: Bool = false,
                includeSubfolders: Bool = true) {
        self.includeHidden = includeHidden
        self.caseSensitive = caseSensitive
        self.includeSubfolders = includeSubfolders
    }
}

public struct FileSearchEngine: Sendable {

    public init() {}

    /// 主入口：返回 AsyncStream，consumer 可以在 SwiftUI 用 `for await r in stream`
    /// 流式渲染；Task.cancel 即可中断。
    public func search(rootPath: String,
                       filters: [FileSearchFilter],
                       options: FileSearchOptions = .init()) -> AsyncStream<FileSearchResult> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.performSearch(rootPath: rootPath,
                                   filters: filters,
                                   options: options,
                                   continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - core

    private static func performSearch(rootPath: String,
                                      filters: [FileSearchFilter],
                                      options: FileSearchOptions,
                                      continuation: AsyncStream<FileSearchResult>.Continuation) {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath)
        let resourceKeys: [URLResourceKey] = [
            .totalFileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey,
        ]
        let opt: FileManager.DirectoryEnumerationOptions = options.includeHidden
            ? [] : [.skipsHiddenFiles]

        if options.includeSubfolders {
            guard let enumerator = fm.enumerator(at: rootURL,
                                                 includingPropertiesForKeys: resourceKeys,
                                                 options: opt) else { return }
            while !Task.isCancelled, let url = enumerator.nextObject() as? URL {
                if let r = match(url: url, filters: filters, options: options) {
                    continuation.yield(r)
                }
            }
        } else {
            guard let contents = try? fm.contentsOfDirectory(at: rootURL,
                                                             includingPropertiesForKeys: resourceKeys,
                                                             options: opt) else { return }
            for url in contents {
                if Task.isCancelled { return }
                if let r = match(url: url, filters: filters, options: options) {
                    continuation.yield(r)
                }
            }
        }
    }

    private static func match(url: URL,
                              filters: [FileSearchFilter],
                              options: FileSearchOptions) -> FileSearchResult? {
        let name = url.lastPathComponent
        let needsTags = filters.contains {
            if case .tags = $0 { return true }
            return false
        }
        var resourceKeys: Set<URLResourceKey> = [
            .totalFileSizeKey, .contentModificationDateKey, .isDirectoryKey,
        ]
        if needsTags {
            resourceKeys.insert(.tagNamesKey)
        }
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let isDir = values?.isDirectory ?? url.hasDirectoryPath
        let size: Int64 = isDir ? 0 : Int64(values?.totalFileSize ?? 0)
        let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let tags = needsTags ? (values?.tagNames ?? []) : []

        // tags + comment 读取代价更高，仅在 filters 实际用到时才取 comment（懒加载）
        var commentCache: String? = nil

        for filter in filters {
            if !accepts(filter: filter, name: name, url: url,
                        size: size, mtime: mtime, tags: tags,
                        commentLoader: { () -> String in
                            if let c = commentCache { return c }
                            let c = readFinderComment(url: url)
                            commentCache = c
                            return c
                        },
                        isDir: isDir,
                        caseSensitive: options.caseSensitive) {
                return nil
            }
        }
        return FileSearchResult(url: url, name: name,
                                isDirectory: isDir, size: size,
                                dateModified: mtime)
    }

    private static func accepts(filter: FileSearchFilter,
                                name: String, url: URL,
                                size: Int64, mtime: Date, tags: [String],
                                commentLoader: () -> String,
                                isDir: Bool,
                                caseSensitive: Bool) -> Bool {
        switch filter {
        case .name(let m, let value):
            return matchName(m, name: name, value: value, caseSensitive: caseSensitive)
        case .fileExtension(let m, let exts):
            let fileExt = caseSensitive ? url.pathExtension : url.pathExtension.lowercased()
            let normalized = exts.map { ext -> String in
                let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                return caseSensitive ? trimmed : trimmed.lowercased()
            }
            switch m {
            case .includes: return normalized.contains(fileExt)
            case .excludes: return !normalized.contains(fileExt)
            }
        case .size(let s):
            switch s {
            case .greaterThan(let v): return size > v
            case .lessThan(let v):    return size < v
            case .between(let lo, let hi): return size >= lo && size <= hi
            }
        case .kind(let k):
            switch k {
            case .fileOnly:   return !isDir
            case .folderOnly: return isDir
            }
        case .date(let d):
            switch d {
            case .modifiedBefore(let t): return mtime < t
            case .modifiedAfter(let t):  return mtime > t
            case .modifiedBetween(let lo, let hi): return mtime >= lo && mtime <= hi
            }
        case .tags(let t):
            return matchTags(t, fileTags: tags, caseSensitive: caseSensitive)
        case .comment(let c):
            return matchComment(c, comment: commentLoader(), caseSensitive: caseSensitive)
        }
    }

    private static func matchName(_ m: FileSearchFilter.NameMatch,
                                  name: String, value: String,
                                  caseSensitive: Bool) -> Bool {
        if value.isEmpty { return true }
        let lhs = caseSensitive ? name : name.lowercased()
        let rhs = caseSensitive ? value : value.lowercased()
        switch m {
        case .contains:   return lhs.contains(rhs)
        case .startsWith: return lhs.hasPrefix(rhs)
        case .endsWith:   return lhs.hasSuffix(rhs)
        case .equals:     return lhs == rhs
        }
    }

    private static func matchTags(_ m: FileSearchFilter.TagMatch,
                                  fileTags: [String],
                                  caseSensitive: Bool) -> Bool {
        // Finder tagNames 的颜色后缀（如 "Important\n6"）按 \n 截断到名字部分
        let normalized: [String] = fileTags.map { raw in
            let name = raw.split(separator: "\n").first.map(String.init) ?? raw
            return caseSensitive ? name : name.lowercased()
        }
        func norm(_ s: String) -> String {
            return caseSensitive ? s : s.lowercased()
        }
        switch m {
        case .hasTag(let value):
            return normalized.contains(norm(value))
        case .hasAnyOf(let values):
            let needles = values.map(norm)
            return needles.contains(where: { normalized.contains($0) })
        case .hasAllOf(let values):
            let needles = values.map(norm)
            return needles.allSatisfy({ normalized.contains($0) })
        case .isEmpty:
            return fileTags.isEmpty
        }
    }

    private static func matchComment(_ m: FileSearchFilter.CommentMatch,
                                     comment: String,
                                     caseSensitive: Bool) -> Bool {
        switch m {
        case .contains(let value):
            if value.isEmpty { return true }
            let lhs = caseSensitive ? comment : comment.lowercased()
            let rhs = caseSensitive ? value : value.lowercased()
            return lhs.contains(rhs)
        case .equals(let value):
            let lhs = caseSensitive ? comment : comment.lowercased()
            let rhs = caseSensitive ? value : value.lowercased()
            return lhs == rhs
        case .isEmpty:
            return comment.isEmpty
        }
    }

    /// 读取 Finder Comment：存储在 xattr `com.apple.metadata:kMDItemFinderComment`，
    /// value 是一个 binary plist 包裹的 String。参考
    /// [Pearcleaner getFinderComment L473-L495](file:///Users/amuxuser/workspace/AmuxAIClean/tmp/competitors/Pearcleaner/Pearcleaner/Logic/FileSearch/FileSearchLogic.swift#L473-L495)
    /// 此函数 internal-only（同模块测试可访问）以便 unit-test 直接验证。
    static func readFinderComment(url: URL) -> String {
        let attr = "com.apple.metadata:kMDItemFinderComment"
        let data: Data? = url.withUnsafeFileSystemRepresentation { cpath -> Data? in
            guard let cpath else { return nil }
            let length = getxattr(cpath, attr, nil, 0, 0, XATTR_NOFOLLOW)
            guard length > 0 else { return nil }
            var buf = Data(count: length)
            let n = buf.withUnsafeMutableBytes { raw -> ssize_t in
                getxattr(cpath, attr, raw.baseAddress, length, 0, XATTR_NOFOLLOW)
            }
            return n > 0 ? Data(buf.prefix(n)) : nil
        }
        guard let data else { return "" }
        if let s = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String {
            return s
        }
        return ""
    }
}
