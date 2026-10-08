import Foundation
import LogKit

/// Mole 对齐 M3-T2：用户白名单持久化。
///
/// 解决的痛点：用户在某次扫描中标记了「这条路径以后别再扫给我看」（例如某个开发者
/// 自己 know-it 的目录），下一次扫描完成后还是出现，体验很差。
///
/// 设计：
/// - **JSON file 持久化**：默认写在 `~/Library/Application Support/AmuxAIClean/whitelist.json`，
///   走文件而非 UserDefaults 是为了便于用户自己编辑 / 备份；
/// - **actor 隔离 + 内存缓存**：每次 add/remove 立刻更新内存 set 并异步落盘，避免阻塞 UI；
/// - **prefix 匹配**：判断一条扫描结果是否被加白时，用 path prefix 命中（用户把 `~/X` 加白后
///   `~/X/sub` 也应该跳过），但只在目录边界匹配（防止 `~/Xtra` 被 `~/X` 错命中）；
/// - **空白单例不读盘**：测试态可以注入空 store 跳过文件 IO。
///
/// 与 [SafetyEngine] 的关系：白名单是**用户级覆盖**——即使 vendors.yaml 标了 `.safe`，
/// 一旦命中白名单也强制视为不显示（最高优先级）。
public actor WhitelistStore {

    // MARK: - 数据模型

    /// 持久化数据格式。版本字段为将来兼容预留（schema 升级时可平滑迁移）。
    public struct Persisted: Codable, Sendable {
        public var version: Int
        public var entries: [Entry]

        public init(version: Int = 1, entries: [Entry] = []) {
            self.version = version
            self.entries = entries
        }
    }

    /// 单条白名单。
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        /// 标准化绝对路径（已去尾 `/`、resolved symlinks 之前的原路径）
        public let path: String
        /// 加白原因（用户自填，可空；UI 上用于回顾「我当时为什么加白」）
        public let reason: String?
        /// 加白时间戳，UI 列表按它倒序展示
        public let addedAt: Date

        public var id: String { path }

        public init(path: String, reason: String? = nil, addedAt: Date = Date()) {
            self.path = path
            self.reason = reason
            self.addedAt = addedAt
        }
    }

    // MARK: - 状态

    private var inMemoryEntries: [String: Entry] = [:]
    private let storageURL: URL?
    private var loaded: Bool = false

    /// 共享单例：使用默认 Application Support 路径。
    public static let shared = WhitelistStore(storageURL: WhitelistStore.defaultStorageURL())

    /// 测试入口：传 nil 表示纯内存 store，不持久化到磁盘。
    public init(storageURL: URL?) {
        self.storageURL = storageURL
    }

    // MARK: - 公开 API

    /// 加白一条路径（idempotent，重复加白会刷新 addedAt）。
    public func add(path: String, reason: String? = nil) async {
        await loadIfNeeded()
        let normalized = WhitelistStore.normalize(path)
        let key = normalized.lowercased()
        inMemoryEntries[key] = Entry(path: normalized, reason: reason)
        await persist()
        GSYLog.info(.safety, "Whitelist + path=\(normalized) reason=\(reason ?? "<nil>")")
    }

    /// 取消加白。
    @discardableResult
    public func remove(path: String) async -> Bool {
        await loadIfNeeded()
        let normalized = WhitelistStore.normalize(path)
        let key = normalized.lowercased()
        let removed = inMemoryEntries.removeValue(forKey: key) != nil
        if removed {
            await persist()
            GSYLog.info(.safety, "Whitelist - path=\(normalized)")
        }
        return removed
    }

    /// 全量列表，按 addedAt 倒序（UI 直接渲染）。
    public func list() async -> [Entry] {
        await loadIfNeeded()
        return inMemoryEntries.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// M4-T1：返回当前所有 normalized path 的 Set 快照。
    /// 用于 ScanCoordinator 这类不便在 hot path 反复 await actor 的同步调用方。
    public func snapshotPaths() async -> Set<String> {
        await loadIfNeeded()
        return Set(inMemoryEntries.values.map(\.path))
    }

    /// 判定某条扫描结果是否被加白。
    ///
    /// 命中规则：
    /// 1. **完全相等** —— 显然命中；
    /// 2. **白名单路径是 query 的 prefix 且后跟 `/`** —— 加了 `~/X` 视为整个子树都加白；
    /// 3. **query 是白名单路径的 prefix + `/`** —— 用户加白了一个子项（`~/X/sub`），
    ///    扫描根 `~/X` 本身不会被加白，这是反向不命中（避免用户误以为加白子项就静默父级）。
    public func isWhitelisted(_ path: String) async -> Bool {
        await loadIfNeeded()
        let normalized = WhitelistStore.normalize(path).lowercased()
        let resolved = WhitelistStore.resolveSymlinks(path).lowercased()
        for entry in inMemoryEntries.values {
            let entryNorm = WhitelistStore.normalize(entry.path).lowercased()
            if normalized == entryNorm || normalized.hasPrefix(entryNorm + "/") {
                return true
            }
            if resolved != normalized && (resolved == entryNorm || resolved.hasPrefix(entryNorm + "/")) {
                return true
            }
            let entryResolved = WhitelistStore.resolveSymlinks(entry.path).lowercased()
            if entryResolved != entryNorm {
                if normalized == entryResolved || normalized.hasPrefix(entryResolved + "/") {
                    return true
                }
                if resolved == entryResolved || resolved.hasPrefix(entryResolved + "/") {
                    return true
                }
            }
        }
        return false
    }

    /// 测试 / UI 刷新用：强制清空内存缓存并重读磁盘。
    public func reload() async {
        loaded = false
        inMemoryEntries.removeAll(keepingCapacity: false)
        await loadIfNeeded()
    }

    /// 测试用：清空全部（包括磁盘）。
    public func clearAllForTesting() async {
        inMemoryEntries.removeAll(keepingCapacity: false)
        loaded = true
        await persist()
    }

    // MARK: - 内部

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let url = storageURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(Persisted.self, from: data)
            var loadedEntries: [String: Entry] = [:]
            for item in persisted.entries {
                let norm = WhitelistStore.normalize(item.path)
                loadedEntries[norm.lowercased()] = Entry(
                    path: norm,
                    reason: item.reason,
                    addedAt: item.addedAt
                )
            }
            inMemoryEntries = loadedEntries
            GSYLog.info(.safety, "Whitelist loaded count=\(inMemoryEntries.count)")
        } catch {
            GSYLog.warning(.safety, "Whitelist 加载失败 path=\(url.path) err=\(error)")
        }
    }

    private func persist() async {
        guard let url = storageURL else { return }
        let snapshot = Persisted(version: 1,
                                 entries: Array(inMemoryEntries.values))
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            GSYLog.warning(.safety, "Whitelist 持久化失败 err=\(error)")
        }
    }

    private static func normalize(_ path: String) -> String {
        var p = SafetyEngine.stripDataVolumePrefix(path)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if p.hasPrefix("/") {
            p = URL(fileURLWithPath: p).standardizedFileURL.path
            p = SafetyEngine.stripDataVolumePrefix(p)
        }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func resolveSymlinks(_ path: String) -> String {
        let stripped = normalize(path)
        guard stripped.hasPrefix("/") else { return stripped }
        let fm = FileManager.default
        var current = stripped
        var trailingComponents: [String] = []
        while current != "/" && !current.isEmpty && !fm.fileExists(atPath: current) {
            let ns = current as NSString
            let last = ns.lastPathComponent
            if !last.isEmpty && last != "/" {
                trailingComponents.append(last)
            }
            current = ns.deletingLastPathComponent
        }
        var resolvedBase = URL(fileURLWithPath: current).resolvingSymlinksInPath().standardizedFileURL.path
        resolvedBase = SafetyEngine.stripDataVolumePrefix(resolvedBase)
        for comp in trailingComponents.reversed() {
            if resolvedBase == "/" {
                resolvedBase = "/" + comp
            } else {
                resolvedBase += "/" + comp
            }
        }
        return normalize(resolvedBase)
    }

    private static func defaultStorageURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: nil,
                                            create: true) else { return nil }
        return appSupport.appendingPathComponent("AmuxAIClean/whitelist.json")
    }
}
