import Foundation

/// FileSearchKit MVP（Step 16-A）—— 仓库内最小可用 file-search engine。
///
/// 设计原则：
/// - **零外部依赖**：仅 Foundation，便于在任何 SPM consumer 里直接加 product。
/// - **流式输出**：`AsyncStream<FileSearchResult>` 让 UI 立刻能渲染第一个结果（参考
///   [Pearcleaner FileSearchLogic L109](file:///Users/guoshuyu/workspace/GSYCleanMac/tmp/competitors/Pearcleaner/Pearcleaner/Logic/FileSearch/FileSearchLogic.swift#L109)
///   batchSize=1 的"立即出第一个结果"语义）。
/// - **`Sendable` + actor cancel**：`AsyncStream` 自带 cancel；engine 不持有可变状态，
///   每次搜索作为独立 task 跑，方便 SwiftUI 调用方一改 query 就 cancel 上一次。
/// - **MVP 4 类 filter**：name / extension / size / kind；date/tags/comment 留下一刀。
public enum FileSearchFilter: Sendable, Equatable {
    /// 文件名匹配（case-insensitive substring；空串视作 match-all）
    case name(NameMatch, String)
    /// 扩展名（lowercased，无前导点；多个用 includes/excludes 集合）
    case fileExtension(ExtensionMatch, [String])
    /// 文件 size（字节；directory size 视作 0，不递归汇总）
    case size(SizeMatch)
    /// 类型（file / folder）
    case kind(KindMatch)

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
        let isDir = url.hasDirectoryPath
        let name = url.lastPathComponent
        let resourceKeys: Set<URLResourceKey> = [
            .totalFileSizeKey, .contentModificationDateKey, .isDirectoryKey
        ]
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let size: Int64 = isDir ? 0 : Int64(values?.totalFileSize ?? 0)
        let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)

        for filter in filters {
            if !accepts(filter: filter, name: name, url: url,
                        size: size, isDir: isDir,
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
                                size: Int64, isDir: Bool,
                                caseSensitive: Bool) -> Bool {
        switch filter {
        case .name(let m, let value):
            return matchName(m, name: name, value: value, caseSensitive: caseSensitive)
        case .fileExtension(let m, let exts):
            let fileExt = url.pathExtension.lowercased()
            let normalized = exts.map { $0.lowercased() }
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
}
