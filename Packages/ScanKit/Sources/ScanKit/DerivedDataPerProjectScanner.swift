import Foundation

/// Apple 工作流配套：DerivedData 按工程粒度扫描器。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §Apple）：
/// - `~/Library/Developer/Xcode/DerivedData` 下每个一级子目录命名形如
///   `MyApp-abc123xyz`，其中 `abc123xyz` 是 Xcode 为工作区生成的稳定 hash。
/// - 单个工程的 DerivedData（Build/Index/Logs/ModuleCache）动辄 1~5 GB，
///   长期切分支后会堆积 N 个旧工程残留目录；用户需要按工程粒度看占用并清理。
/// - 与既有 [KnownVersionedRoots]（整目录粒度）互补：前者负责"DerivedData 这一级"，
///   本扫描器下钻一层，给 UI 渲染「按工程的 DerivedData 占用列表」。
///
/// 与 [SimctlRuntimeScanner] 的关系：
/// - 同样采用「`static detect(home:)` 同步入口 + `actor discover()` 异步入口」双形态；
/// - `estimateSize(at:)` 实现风格完全对齐 [SimctlRuntimeScanner.estimateSize]——
///   `FileManager.enumerator` 遍历，优先 `totalFileAllocatedSize`，回退 `fileAllocatedSize`。
///
/// 容错红线：
/// - DerivedData 根不存在 / 不是目录 / 无权限读 → 返回 `[]`，**不抛**；
/// - 单个工程子目录 stat 失败 → 该项 `sizeBytes` / `modificationDate` 为 `nil`，但**仍纳入结果**；
/// - 这与 UI 侧「展示空清单 + 引导用户检查 Xcode 安装」策略一致，避免错误冒泡污染整个工作流。
public actor DerivedDataPerProjectScanner {

    public init() {}

    /// 异步入口：扫描 `~/Library/Developer/Xcode/DerivedData` 下每个工程子目录。
    ///
    /// - Parameter home: 用户 home 目录（注入便于测试，生产传 `FileManager.default.homeDirectoryForCurrentUser`）。
    /// - Returns: 工程命中列表；任何 IO 失败一律 `[]`，**不抛**。
    public func discover(home: URL) async -> [ProjectHit] {
        Self.detect(home: home)
    }

    /// 同步入口：纯 FS 遍历，无 subprocess，供单测直接调用。
    ///
    /// 流程：
    /// 1. 计算 DerivedData 根路径 `<home>/Library/Developer/Xcode/DerivedData`；
    /// 2. 列一级子目录，跳过 `ModuleCache.noindex` / `Manifest.plist` 等非工程项（仅保留目录）；
    /// 3. 对每个目录：解析工程名 + 估算大小 + 取 mtime。
    public static func detect(home: URL) -> [ProjectHit] {
        let fm = FileManager.default
        let root = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var hits: [ProjectHit] = []
        hits.reserveCapacity(children.count)
        for child in children {
            let values = try? child.resourceValues(forKeys: keys)
            // 仅保留目录；非目录（如 Manifest.plist）忽略
            guard values?.isDirectory == true else { continue }
            let name = child.lastPathComponent
            // 跳过 Xcode 自身公共缓存目录，不属于"按工程"维度
            if name == "ModuleCache.noindex" { continue }
            hits.append(ProjectHit(
                url: child,
                projectName: parseProjectName(from: name),
                sizeBytes: estimateSize(at: child.path),
                modificationDate: values?.contentModificationDate
            ))
        }
        return hits
    }

    // MARK: - 工程名解析

    /// 从形如 `MyApp-abc123xyz` 的子目录名中剥出 `MyApp`。
    ///
    /// 规则：
    /// - 截到**最后一个** `-` 之前；Xcode 的 hash 段不含 `-`，所以 rsplit 一次就够；
    /// - 若没有 `-`（异常命名）或剥完是空串，直接返回原名兜底。
    static func parseProjectName(from folderName: String) -> String {
        guard let dashIndex = folderName.lastIndex(of: "-") else {
            return folderName
        }
        let prefix = folderName[..<dashIndex]
        return prefix.isEmpty ? folderName : String(prefix)
    }

    // MARK: - sizeBytes 估算（对位 SimctlRuntimeScanner.estimateSize 风格）

    /// 遍历目录累加 totalFileAllocatedSize，回退 fileAllocatedSize。
    ///
    /// 失败语义：路径不存在 / 不是目录 / 无权限读 → 返回 `nil`（UI 侧显示 "—"）。
    static func estimateSize(at path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }
}

/// 单个 DerivedData 工程子目录的命中记录。
public struct ProjectHit: Sendable, Hashable, Identifiable {
    /// 子目录绝对 URL，如 `~/Library/Developer/Xcode/DerivedData/MyApp-abc123xyz`。
    public let url: URL
    /// 工程名（已剥掉 `-xxx` hash 后缀），如 `MyApp`。
    public let projectName: String
    /// 目录累计大小（字节）。`nil` 表示路径不存在或无权限读。
    public let sizeBytes: Int64?
    /// 目录 mtime。`nil` 表示 stat 失败。
    public let modificationDate: Date?

    public var id: URL { url }

    public init(url: URL,
                projectName: String,
                sizeBytes: Int64?,
                modificationDate: Date?) {
        self.url = url
        self.projectName = projectName
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
    }
}
