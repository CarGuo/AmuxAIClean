import Dispatch
import Foundation
import LogKit

/// Step 7：UndoHistory 持久化 + 单点恢复链路。
///
/// **职责**：
/// - 记录最近 N 次 trash 操作（默认 10），每次记录一个"批次"，含原路径 → 废纸篓路径 pair。
/// - 把记录持久化到 `~/Library/Application Support/GSYCleanMac/UndoHistory.json`（atomic write）。
/// - 支持单条恢复：把 `trashedPath` mv 回 `originalPath`。
/// - 若 `originalPath` 已存在，先生成显式冲突计划；只有用户选择“跳过”或“恢复为新名称”后才执行。
///   恢复链路本身永远不会移动、覆盖或删除用户后来创建的同名文件。
/// - cleanupStaleEntries：用户清空了系统废纸篓后，若 trashedPath 已不存在则该批次自动从历史里剔除。
///
/// **设计参考**：[Pearcleaner UndoHistoryManager](file:///Users/guoshuyu/workspace/GSYCleanMac/tmp/competitors/Pearcleaner/Pearcleaner/Logic/UndoHistoryManager.swift)。
///
/// **测试钩子**：`init(storeURL:)` 让 `UndoHistoryStoreTests` 能注入 FixtureFS 临时目录，
/// 不污染真实用户 Application Support。生产代码用 `UndoHistoryStore.shared`。
///
/// **并发**：`@MainActor`，与 [HeuristicRecorder](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeuristicRecorder.swift)
/// 不同——本 store 是 UI 直接消费的（侧栏列表渲染），跑在主 Actor 反而省一层桥接。
@MainActor
public final class UndoHistoryStore: ObservableObject {

    /// 原路径重新出现时的显式冲突策略。刻意不提供“替换现有文件”：恢复不应暗中变成删除入口。
    public enum RestoreConflictPolicy: Sendable, Equatable {
        /// 保留原路径上的现有项目，并把废纸篓中的对应项目留给以后再次恢复。
        case skipExisting
        /// 保留原路径上的现有项目，把待恢复项目恢复为同目录下不冲突的新名称。
        case restoreWithUniqueName
    }

    /// 恢复按钮触发后先生成的只读计划。UI 看到冲突后必须让用户明确选择策略。
    public struct RestorePlan: Sendable, Equatable {
        public let readyCount: Int
        public let conflictPaths: [String]
        public let missingTrashPaths: [String]

        public var requiresConflictChoice: Bool { !conflictPaths.isEmpty }
    }

    /// 一次恢复的结构化结果。`firstError` 会直接进入用户可见的结果弹窗。
    public struct RestoreResult: Sendable, Equatable {
        public let restoredCount: Int
        public let skippedCount: Int
        public let renamedCount: Int
        public let firstError: String?
    }

    private struct RestoreExecution: Sendable {
        let result: RestoreResult
        let remainingPairs: [Record.FilePair]
    }

    /// 单条 trash 批次记录。`Identifiable` 让 SwiftUI List 能直接 ForEach。
    public struct Record: Codable, Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        /// 来源标签，如 `"clean"` / `"uninstall"` / `"large-file"`。仅用于侧栏显示分类，不参与恢复逻辑。
        public let source: String
        /// 该批次共多少条 path（== filePairs.count，但单独存一份避免 decode 后再算）。
        public let fileCount: Int
        /// (originalPath, trashedPath) pair 列表。pair 顺序保留统一删除管道的成功回调顺序。
        public let filePairs: [FilePair]

        public struct FilePair: Codable, Equatable, Sendable {
            public let original: String
            public let trashed: String
            public init(original: String, trashed: String) {
                self.original = original
                self.trashed = trashed
            }
        }

        public init(id: UUID = UUID(),
                    timestamp: Date = Date(),
                    source: String,
                    filePairs: [FilePair]) {
            self.id = id
            self.timestamp = timestamp
            self.source = source
            self.fileCount = filePairs.count
            self.filePairs = filePairs
        }
    }

    /// 当前内存中的历史记录，最新的在最前。视图直接绑定。
    @Published public private(set) var history: [Record] = []

    /// 最多保留 N 条，超出按 LRU 丢弃。
    private let maxHistoryCount: Int
    private let storeURL: URL
    private let fm: FileManager
    /// 所有后台落盘都进入同一 FIFO 队列，保证较旧的 snapshot 不会在较新的 snapshot
    /// 之后完成并覆盖磁盘。队列不承载 UI 状态，只做不可变 Data 的文件 IO。
    private let persistenceQueue: DispatchQueue
    /// v1.5.7：落盘策略。生产单例用 `.background`（串行队列卸主 actor），
    /// 测试用 `.synchronous` 保证 `addRecord` 返回后 `XCTAssertTrue(fileExists)` 立刻成立。
    private let saveStrategy: SaveStrategy

    public enum SaveStrategy: Sendable {
        case synchronous
        case background
    }

    /// 共享单例。生产代码所有调用方都走它。
    public static let shared = UndoHistoryStore()

    private convenience init() {
        self.init(storeURL: UndoHistoryStore.defaultStoreURL(),
                  maxHistoryCount: 10,
                  saveStrategy: .background)
    }

    /// 测试 / DI 用初始化器。**默认 synchronous**，保证测试断言可靠。
    public init(storeURL: URL,
                maxHistoryCount: Int = 10,
                fm: FileManager = .default,
                saveStrategy: SaveStrategy = .synchronous) {
        self.storeURL = storeURL
        self.maxHistoryCount = maxHistoryCount
        self.fm = fm
        self.saveStrategy = saveStrategy
        self.persistenceQueue = DispatchQueue(
            label: "com.amux.ai.clean.undo-history.\(UUID().uuidString)",
            qos: .utility
        )
        loadHistory()
    }

    /// 默认存储路径：`~/Library/Application Support/GSYCleanMac/UndoHistory.json`，与
    /// [HeuristicRecorder.defaultStoreURL](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeuristicRecorder.swift#L23-L35)
    /// 同目录。
    public static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support.appendingPathComponent("GSYCleanMac", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/GSYCleanMac",
                                        isDirectory: true)
        }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            GSYLog.error(.trash, "UndoHistory 默认目录创建失败 path=\(base.path) err=\(error.localizedDescription)")
        }
        return base.appendingPathComponent("UndoHistory.json")
    }

    // MARK: - Public API

    /// 写一条新记录（最新在最前，超过 maxHistoryCount 丢最旧）。空 pair 直接 no-op。
    public func addRecord(source: String, filePairs: [Record.FilePair]) {
        guard !filePairs.isEmpty else { return }
        let record = Record(source: source, filePairs: filePairs)
        history.insert(record, at: 0)
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }
        saveHistory()
        GSYLog.info(.trash, "UndoHistory 写入 source=\(source) pairs=\(filePairs.count) total=\(history.count)")
    }

    /// 检查并移除"trashedPath 已不存在"的陈旧 pair（用户手动清空了系统废纸篓）。
    /// **判定口径**：逐 pair 剔除不可恢复项；若 record 已没有任何可恢复 pair，才剔除整条 record。
    public func cleanupStaleEntries() {
        let oldHistory = history
        history = history.compactMap { record in
            let existingPairs = record.filePairs.filter { pair in
                fm.fileExists(atPath: pair.trashed)
            }
            guard !existingPairs.isEmpty else { return nil }
            if existingPairs.count == record.filePairs.count { return record }
            return Record(
                id: record.id,
                timestamp: record.timestamp,
                source: record.source,
                filePairs: existingPairs
            )
        }
        if history != oldHistory {
            saveHistory()
            GSYLog.info(.trash, "UndoHistory cleanupStaleEntries 更新 records \(oldHistory.count) → \(history.count)")
        }
    }

    /// 后台检查一条记录，冻结恢复前的冲突 / 缺失快照。执行时仍会重新检查目标路径，
    /// 因而计划生成后出现的新文件也绝不会被覆盖。
    public func prepareRestore(_ record: Record) async -> RestorePlan {
        await Task.detached(priority: .userInitiated) {
            Self.buildRestorePlan(record)
        }.value
    }

    /// 恢复一条记录。调用方必须显式传入冲突策略；API 不再存在会暗中处理现有文件的默认分支。
    /// 文件系统 IO 在后台执行，MainActor 只更新 history 和持久化快照。
    @discardableResult
    public func restoreRecord(
        _ record: Record,
        conflictPolicy: RestoreConflictPolicy
    ) async -> RestoreResult {
        let execution = await Task.detached(priority: .userInitiated) {
            Self.executeRestore(record, conflictPolicy: conflictPolicy)
        }.value

        let remainingPairs = execution.remainingPairs
        if let idx = history.firstIndex(where: { $0.id == record.id }) {
            if remainingPairs.isEmpty {
                history.remove(at: idx)
            } else {
                history[idx] = Record(
                    id: record.id,
                    timestamp: record.timestamp,
                    source: record.source,
                    filePairs: remainingPairs
                )
            }
            saveHistory()
        }

        let result = execution.result
        GSYLog.info(
            .trash,
            "UndoHistory restoreRecord 完成 restored=\(result.restoredCount) renamed=\(result.renamedCount) skipped=\(result.skippedCount) err=\(result.firstError ?? "nil")"
        )
        return result
    }

    nonisolated private static func buildRestorePlan(_ record: Record) -> RestorePlan {
        let fm = FileManager.default
        var readyCount = 0
        var conflictPaths: [String] = []
        var missingTrashPaths: [String] = []
        var reservedDestinations: Set<String> = []

        for pair in record.filePairs {
            guard fm.fileExists(atPath: pair.trashed) else {
                missingTrashPaths.append(pair.trashed)
                continue
            }

            let normalizedDestination = URL(fileURLWithPath: pair.original)
                .standardizedFileURL.path
            let firstUse = reservedDestinations.insert(normalizedDestination).inserted
            if !firstUse || fm.fileExists(atPath: pair.original) {
                conflictPaths.append(pair.original)
            } else {
                readyCount += 1
            }
        }

        return RestorePlan(
            readyCount: readyCount,
            conflictPaths: conflictPaths,
            missingTrashPaths: missingTrashPaths
        )
    }

    nonisolated private static func executeRestore(
        _ record: Record,
        conflictPolicy: RestoreConflictPolicy
    ) -> RestoreExecution {
        let fm = FileManager.default
        var restored = 0
        var skipped = 0
        var renamed = 0
        var firstError: String?
        var remainingPairs: [Record.FilePair] = []
        var reservedDestinations = Set(record.filePairs.map { pair in
            URL(fileURLWithPath: pair.original).standardizedFileURL.path
        })

        for pair in record.filePairs {
            let trashedURL = URL(fileURLWithPath: pair.trashed)
            let originalURL = URL(fileURLWithPath: pair.original)

            guard fm.fileExists(atPath: pair.trashed) else {
                skipped += 1
                if firstError == nil {
                    firstError = String(format: String(localized: "undo.err.trashed_missing %@", bundle: .module), pair.trashed)
                }
                continue
            }

            var destinationURL = originalURL
            if fm.fileExists(atPath: pair.original) {
                switch conflictPolicy {
                case .skipExisting:
                    skipped += 1
                    remainingPairs.append(pair)
                    if firstError == nil {
                        firstError = String(
                            format: String(localized: "undo.err.original_exists %@", bundle: .module),
                            pair.original
                        )
                    }
                    continue
                case .restoreWithUniqueName:
                    destinationURL = availableRecoveryDestination(
                        for: originalURL,
                        fileManager: fm,
                        reservedDestinations: reservedDestinations
                    )
                    reservedDestinations.insert(destinationURL.standardizedFileURL.path)
                }
            }

            // 父目录可能在用户清理后被删了，先确保它存在
            let parentDir = destinationURL.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                skipped += 1
                remainingPairs.append(pair)
                if firstError == nil {
                    firstError = String(
                        format: String(localized: "undo.err.create_parent_failed %@", bundle: .module),
                        error.localizedDescription
                    )
                }
                GSYLog.error(
                    .trash,
                    "UndoHistory restoreRecord 父目录创建失败 path=\(parentDir.path) err=\(error.localizedDescription)"
                )
                continue
            }

            do {
                try fm.moveItem(at: trashedURL, to: destinationURL)
                restored += 1
                if destinationURL != originalURL {
                    renamed += 1
                }
            } catch {
                skipped += 1
                remainingPairs.append(pair)
                if firstError == nil {
                    firstError = String(format: String(localized: "undo.err.move_item_failed %@", bundle: .module), error.localizedDescription)
                }
                GSYLog.error(.trash, "UndoHistory restoreRecord mv 失败 \(pair.trashed) → \(destinationURL.path) err=\(error.localizedDescription)")
            }
        }

        return RestoreExecution(
            result: RestoreResult(
                restoredCount: restored,
                skippedCount: skipped,
                renamedCount: renamed,
                firstError: firstError
            ),
            remainingPairs: remainingPairs
        )
    }

    /// 为冲突恢复分配同目录下的唯一名称；只检查候选路径，不移动现有项目。
    nonisolated private static func availableRecoveryDestination(
        for originalURL: URL,
        fileManager fm: FileManager,
        reservedDestinations: Set<String>
    ) -> URL {
        let parent = originalURL.deletingLastPathComponent()
        let pathExtension = originalURL.pathExtension
        let stem = pathExtension.isEmpty
            ? originalURL.lastPathComponent
            : originalURL.deletingPathExtension().lastPathComponent
        let recovered = String(localized: "undo.restore.recovered_suffix", bundle: .module)
        var sequence = 1

        while true {
            let marker = sequence == 1 ? recovered : "\(recovered) \(sequence)"
            let name = pathExtension.isEmpty
                ? "\(stem) (\(marker))"
                : "\(stem) (\(marker)).\(pathExtension)"
            let candidate = parent.appendingPathComponent(name)
            if !reservedDestinations.contains(candidate.standardizedFileURL.path),
               !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            sequence += 1
        }
    }

    /// 公开 storeURL 供测试断言（@MainActor 可见即可）。
    public var underlyingStoreURL: URL { storeURL }

    // MARK: - Persistence

    /// v1.5.7：编码 + 落盘从主 actor 卸到后台。
    ///
    /// 之前 `data.write(to:options:.atomic)` 同步在 MainActor 跑，删除大批量文件后历史可能 ≈ 几 MB，
    /// FileManager 的 atomic write 会做"写临时文件 → fsync → rename"三段 IO，
    /// 在机械硬盘 / 慢 SSD 上能让 UI 卡 100~300ms。这里：
    /// 1. 在主 actor 只复制 `Record` 数组的值语义 snapshot
    /// 2. 单一 serial queue 按 FIFO 做 JSON encode + atomic write
    /// 3. 失败只打日志（写失败不应回滚 in-memory state）
    ///
    /// 测试或进程退出前如需确认所有 snapshot 已落盘，await `flushPendingWrites()`。
    private func saveHistory() {
        let url = storeURL
        switch saveStrategy {
        case .synchronous:
            Self.writeHistory(history, to: url)
        case .background:
            // Record/FilePair 都是 Sendable 值类型；主 actor 只截取 snapshot，
            // 可能达到 MB 级的 JSON encode 与文件 IO 全部留给 utility queue。
            let records = history
            persistenceQueue.async {
                Self.writeHistory(records, to: url)
            }
        }
    }

    /// 等待调用前已经提交的所有后台写完成。serial queue 上的 barrier token 只有在前面
    /// 的写全部退出后才执行；不阻塞 MainActor。
    public func flushPendingWrites() async {
        let queue = persistenceQueue
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    /// 测试用同步落盘入口；serial queue 的 sync 会先排空较旧 snapshot，再写当前状态。
    /// 生产 UI 不应调用，退出收尾使用 `flushPendingWrites()`。
    public func saveHistorySync() {
        let records = history
        let url = storeURL
        persistenceQueue.sync {
            Self.writeHistory(records, to: url)
        }
    }

    nonisolated private static func writeHistory(_ records: [Record], to url: URL) {
        guard let data = encodeHistory(records) else { return }
        writeData(data, to: url)
    }

    nonisolated private static func encodeHistory(_ records: [Record]) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(records)
        } catch {
            GSYLog.error(.trash, "UndoHistory encode 失败 err=\(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func writeData(_ data: Data, to url: URL) {
        do {
            let fm = FileManager.default
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            GSYLog.error(.trash, "UndoHistory write 失败 err=\(error.localizedDescription)")
        }
    }

    /// v1.5.7：init 阶段的轻量级同步加载。
    ///
    /// 现状下 UndoHistory 上限 10 条 record，每条最多几百个 pair，整个 JSON 通常 < 100 KB，
    /// 同步 decode < 1ms，比 detached 切换还便宜，所以保持同步。如果未来 maxHistoryCount
    /// 提升到 100+ 或 pair 数爆炸式增长，需重构成 async init + UI 先显示空列表。
    private func loadHistory() {
        guard fm.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            history = try decoder.decode([Record].self, from: data)
            cleanupStaleEntries()
        } catch {
            GSYLog.error(.trash, "UndoHistory loadHistory 失败 err=\(error.localizedDescription) path=\(storeURL.path)")
        }
    }
}
