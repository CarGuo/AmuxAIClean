import Foundation
import LogKit

/// 「保留最新 N 个版本」识别器（Mole `clean_xcode_device_support` / `clean_dev_jetbrains_toolbox`
/// / `clean_versioned_agent_root` 系列函数的 Swift 等价物）。
///
/// 适用场景：根目录下每个子目录都是「同一软件的不同版本」，需要保留最新 N 个，
/// 把更旧的标 safe（候选删除）。典型布局：
/// ```
/// ~/Library/Developer/Xcode/iOS DeviceSupport/
///   ├── 17.5 (21F79)/                  ← 旧版本（safe）
///   ├── 17.6 (21G80)/                  ← 旧版本（safe）
///   ├── 18.0 (22A3354)/                ← 保留
///   └── 18.1 (22B5054e)/               ← 保留（active）
///
/// ~/Library/Application Support/JetBrains/Toolbox/apps/IDEA-U/
///   ├── ch-0/241.18034.62/             ← 旧
///   └── ch-0/242.20224.155/            ← 保留
///
/// ~/.claude/local/                     ← Anthropic Claude Code
///   ├── 0.5.1/
///   ├── 0.6.0/
///   └── 0.7.2/                         ← 保留
/// ```
///
/// 与 [VersionsScanner] 的差异：
/// - `VersionsScanner` 走「current 软链反查」语义（rustup / asdf 等工具链管理器）；
/// - `VersionedRetainScanner` 走「按版本号排序 + 保留最新 N」语义，没有 current 指针。
///
/// 安全护栏：
/// - 只识别**目录**版本（软链 / 文件全跳过）；
/// - 版本号比较器可注入（语义化 / 字典序 / mtime 倒排）；
/// - 子目录数 ≤ keepLatest → 返回空（永不让用户在「只剩 N 个」时删任何一个）；
/// - 根不存在 → 完整空结果；根不可读 → 结构化 incomplete evidence（兼容入口仍返回空 hits）。
public actor VersionedRetainScanner {

    /// 一次版本集合识别的完整结果。
    ///
    /// `hits` 只包含建立在完整候选集合上的旧版本；如果集合目录无法枚举，或任一可能
    /// 参与排序的子目录 metadata 不可用，该集合不会产出 hit，具体缺口由
    /// `incompleteIssues` 暴露给上层。这样“没有旧版本”和“扫描失败”不再共用空数组语义。
    public struct DetectionResult: Sendable, Equatable {
        public let hits: [Hit]
        public let incompleteIssues: [ScanIncompleteIssue]

        public var isComplete: Bool { incompleteIssues.isEmpty }

        public init(hits: [Hit], incompleteIssues: [ScanIncompleteIssue]) {
            self.hits = hits
            self.incompleteIssues = Self.normalized(incompleteIssues)
        }

        private static func normalized(_ issues: [ScanIncompleteIssue]) -> [ScanIncompleteIssue] {
            Set(issues).sorted {
                if $0.path == $1.path { return $0.reason.rawValue < $1.reason.rawValue }
                return $0.path < $1.path
            }
        }
    }

    /// 一条命中：某个旧版本目录。
    public struct Hit: Sendable, Hashable, Identifiable {
        /// 旧版本目录绝对路径。
        public let url: URL
        /// 版本集合所在根，如 `~/Library/Developer/Xcode/iOS DeviceSupport`。
        public let collectionRoot: URL
        /// 排序后该子目录的"版本名"（即 lastPathComponent）。
        public let versionName: String
        /// 该集合内被保留的最新版本名（最大者）。
        public let retainedLatest: String

        public var id: String { url.path }

        public init(url: URL, collectionRoot: URL, versionName: String, retainedLatest: String) {
            self.url = url
            self.collectionRoot = collectionRoot
            self.versionName = versionName
            self.retainedLatest = retainedLatest
        }
    }

    /// 排序策略：决定"哪些算更新的版本"。
    public enum Ordering: Sendable {
        /// 语义化版本号优先（提取首段连续 `[0-9.]+` 切片做 `compareNumeric`），
        /// 解析失败 fallback 到字典序。覆盖 `17.5 (21F79)` / `0.6.0` / `242.20224.155` 等。
        case semverPreferred
        /// 纯字典序（`String.compare`，case-insensitive 否定）。
        case lexicographic
        /// 文件 mtime 倒排（最新修改优先保留）。
        case modificationDateDescending
    }

    /// 勘察配置。
    public struct Options: Sendable {
        /// 保留最近 N 个版本（按 [Ordering] 排序后的尾 N 个）。≤ 0 视为 1。
        public var keepLatest: Int
        /// 排序策略。
        public var ordering: Ordering
        /// 是否跳过隐藏目录（`.` 前缀）。
        public var skipHiddenDirectories: Bool
        /// 是否跳过子目录是软链的项（防把别处链接误算入版本数）。
        public var skipSymlinks: Bool

        public init(
            keepLatest: Int = 2,
            ordering: Ordering = .semverPreferred,
            skipHiddenDirectories: Bool = true,
            skipSymlinks: Bool = true
        ) {
            self.keepLatest = max(1, keepLatest)
            self.ordering = ordering
            self.skipHiddenDirectories = skipHiddenDirectories
            self.skipSymlinks = skipSymlinks
        }

        public static let `default` = Options()
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    /// 异步入口。
    public func discover(collectionRoot: URL) async -> [Hit] {
        await discoverWithEvidence(collectionRoot: collectionRoot).hits
    }

    /// 异步结构化入口。与 [discover] 相比，它会区分“没有旧版本”和“发现阶段不完整”。
    public func discoverWithEvidence(collectionRoot: URL) async -> DetectionResult {
        let opts = options
        return await Task.detached(priority: .userInitiated) {
            VersionedRetainScanner.detectWithEvidence(collectionRoot: collectionRoot, options: opts)
        }.value
    }

    /// 同步识别（便于测试 + 并行批处理）。
    public nonisolated static func detect(
        collectionRoot: URL,
        options: Options = .default
    ) -> [Hit] {
        detectWithEvidence(collectionRoot: collectionRoot, options: options).hits
    }

    /// 同步结构化识别入口。
    ///
    /// 旧 [detect] API 保持不变并返回这里的 `hits`；需要安全删除证据的调用方应消费本入口，
    /// 不能再把空 `hits` 直接解释为“扫描完整且没有旧版本”。
    public nonisolated static func detectWithEvidence(
        collectionRoot: URL,
        options: Options = .default
    ) -> DetectionResult {
        detectWithEvidence(
            collectionRoot: collectionRoot,
            options: options,
            fileSystem: FileManager.default
        )
    }

    /// 注入文件系统仅供同模块聚合器与确定性测试使用；产品入口始终走 FileManager。
    nonisolated static func detectWithEvidence(
        collectionRoot: URL,
        options: Options,
        fileSystem: any VersionedRootFileSystem
    ) -> DetectionResult {
        let rootPath = collectionRoot.path

        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileSystem.attributesOfItem(atPath: rootPath)
        } catch {
            if isFileNotFound(error) {
                return DetectionResult(hits: [], incompleteIssues: [])
            }
            return incompleteResult(path: rootPath, error: error, metadataOperation: true)
        }

        guard let rootType = rootAttributes[.type] as? FileAttributeType else {
            return incompleteResult(path: rootPath, reason: .metadataUnavailable)
        }
        guard rootType == .typeDirectory || rootType == .typeSymbolicLink else {
            return DetectionResult(hits: [], incompleteIssues: [])
        }

        let entries: [String]
        do {
            entries = try fileSystem.contentsOfDirectory(atPath: rootPath)
        } catch {
            return incompleteResult(path: rootPath, error: error, metadataOperation: false)
        }

        var candidates: [Candidate] = []
        var incompleteIssues: [ScanIncompleteIssue] = []
        for name in entries {
            if options.skipHiddenDirectories && name.hasPrefix(".") { continue }
            let child = collectionRoot.appendingPathComponent(name)

            var attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileSystem.attributesOfItem(atPath: child.path)
            } catch {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: VersionedRootErrorClassifier.isPermissionDenied(error)
                        ? .permissionDenied
                        : .metadataUnavailable
                ))
                continue
            }

            guard let type = attributes[.type] as? FileAttributeType else {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
                continue
            }
            if type == .typeSymbolicLink {
                if options.skipSymlinks { continue }

                do {
                    let destination = try fileSystem.destinationOfSymbolicLink(atPath: child.path)
                    let targetURL: URL
                    if destination.hasPrefix("/") {
                        targetURL = URL(fileURLWithPath: destination)
                    } else {
                        targetURL = child.deletingLastPathComponent()
                            .appendingPathComponent(destination)
                            .standardizedFileURL
                    }
                    attributes = try fileSystem.attributesOfItem(atPath: targetURL.path)
                } catch {
                    incompleteIssues.append(ScanIncompleteIssue(
                        path: child.path,
                        reason: VersionedRootErrorClassifier.isPermissionDenied(error)
                            ? .permissionDenied
                            : .metadataUnavailable
                    ))
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            } else if type != .typeDirectory {
                continue
            }

            let modificationDate = attributes[.modificationDate] as? Date
            if case .modificationDateDescending = options.ordering,
               modificationDate == nil {
                incompleteIssues.append(ScanIncompleteIssue(
                    path: child.path,
                    reason: .metadataUnavailable
                ))
                continue
            }
            candidates.append(Candidate(
                name: name,
                url: child,
                modificationDate: modificationDate
            ))
        }

        // 版本排序的正确性依赖完整候选集。任一候选 metadata 缺口都会让“最新 N 个”失去
        // 可证明性，因此保留证据但不从这个集合返回任何可删除项。
        if !incompleteIssues.isEmpty {
            logIncomplete(rootPath: rootPath, issues: incompleteIssues)
            return DetectionResult(hits: [], incompleteIssues: incompleteIssues)
        }

        // 版本数 ≤ keepLatest → 安全起见整个集合不识别
        guard candidates.count > options.keepLatest else {
            return DetectionResult(hits: [], incompleteIssues: [])
        }

        // 排序：升序排列后，尾 N 个为保留版本，前面的都是旧版本
        let sorted = sort(candidates: candidates, ordering: options.ordering)
        let retainCount = options.keepLatest
        let oldCount = sorted.count - retainCount
        let retainedLatest = sorted.last?.name ?? ""

        var hits: [Hit] = []
        hits.reserveCapacity(oldCount)
        for i in 0..<oldCount {
            let entry = sorted[i]
            hits.append(Hit(
                url: entry.url,
                collectionRoot: collectionRoot,
                versionName: entry.name,
                retainedLatest: retainedLatest
            ))
        }

        if !hits.isEmpty {
            GSYLog.info(
                .scan,
                "VersionedRetainScanner root=\(rootPath) keep=\(retainCount) old=\(hits.count) latest=\(retainedLatest)"
            )
        }
        return DetectionResult(hits: hits, incompleteIssues: [])
    }

    struct Candidate: Sendable {
        let name: String
        let url: URL
        let modificationDate: Date?
    }

    /// 升序排序（最旧→最新）。**internal** 暴露用于测试。
    nonisolated static func sort(
        candidates: [Candidate],
        ordering: Ordering
    ) -> [Candidate] {
        switch ordering {
        case .lexicographic:
            return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modificationDateDescending:
            return candidates.sorted { lhs, rhs in
                let lDate = lhs.modificationDate ?? .distantPast
                let rDate = rhs.modificationDate ?? .distantPast
                return lDate < rDate  // 升序：最旧在前
            }
        case .semverPreferred:
            return candidates.sorted { lhs, rhs in
                compareSemver(lhs.name, rhs.name) == .orderedAscending
            }
        }
    }

    /// 提取版本名首段连续的 `[0-9.]+` 做数值比较；解析失败 → 字典序兜底。
    ///
    /// 用例：
    /// - `"17.5 (21F79)"` vs `"18.0 (22A3354)"` → 比较 `17.5` vs `18.0` → asc
    /// - `"242.20224.155"` vs `"241.18034.62"` → desc
    /// - `"0.7.2"` vs `"0.6.0"` → desc
    nonisolated static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsVersion = extractLeadingVersion(lhs)
        let rhsVersion = extractLeadingVersion(rhs)
        if let l = lhsVersion, let r = rhsVersion {
            let cmp = l.compare(r, options: .numeric)
            if cmp != .orderedSame { return cmp }
        }
        return lhs.localizedStandardCompare(rhs)
    }

    nonisolated static func extractLeadingVersion(_ s: String) -> String? {
        var buf = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                buf.append(ch)
            } else {
                break
            }
        }
        guard !buf.isEmpty, buf.contains(where: { $0.isNumber }) else { return nil }
        return buf
    }

    nonisolated private static func incompleteResult(
        path: String,
        error: Error,
        metadataOperation: Bool
    ) -> DetectionResult {
        let reason: ScanIncompleteReason
        if VersionedRootErrorClassifier.isPermissionDenied(error) {
            reason = .permissionDenied
        } else {
            reason = metadataOperation ? .metadataUnavailable : .enumerationFailed
        }
        return incompleteResult(path: path, reason: reason)
    }

    nonisolated private static func incompleteResult(
        path: String,
        reason: ScanIncompleteReason
    ) -> DetectionResult {
        let issue = ScanIncompleteIssue(path: path, reason: reason)
        logIncomplete(rootPath: path, issues: [issue])
        return DetectionResult(hits: [], incompleteIssues: [issue])
    }

    nonisolated private static func logIncomplete(
        rootPath: String,
        issues: [ScanIncompleteIssue]
    ) {
        let evidence = issues
            .map { "\($0.path):\($0.reason.rawValue)" }
            .joined(separator: ",")
        GSYLog.warning(
            .scan,
            "VersionedRetainScanner incomplete root=\(rootPath) evidence=\(evidence)"
        )
    }

    nonisolated private static func isFileNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isFileNotFound(underlying)
        }
        return false
    }
}

/// 版本化根发现所需的最小文件系统表面。协议保持模块内可见，避免把测试注入细节变成产品 API。
protocol VersionedRootFileSystem {
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func destinationOfSymbolicLink(atPath path: String) throws -> String
}

extension FileManager: VersionedRootFileSystem {}

enum VersionedRootErrorClassifier {
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }
}
