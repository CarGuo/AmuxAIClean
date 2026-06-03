import AppKit
import Foundation
import LogKit

/// Step 7：UndoHistory 持久化 + 单点恢复链路。
///
/// **职责**：
/// - 记录最近 N 次 trash 操作（默认 10），每次记录一个"批次"，含原路径 → 废纸篓路径 pair。
/// - 把记录持久化到 `~/Library/Application Support/GSYCleanMac/UndoHistory.json`（atomic write）。
/// - 支持单条恢复：把 `trashedPath` mv 回 `originalPath`；若 `originalPath` 已存在同名文件，
///   先把同名文件挪入用户废纸篓（"safe by default"），再 mv 回去。
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

    /// 单条 trash 批次记录。`Identifiable` 让 SwiftUI List 能直接 ForEach。
    public struct Record: Codable, Identifiable, Equatable {
        public let id: UUID
        public let timestamp: Date
        /// 来源标签，如 `"clean"` / `"uninstall"` / `"large-file"`。仅用于侧栏显示分类，不参与恢复逻辑。
        public let source: String
        /// 该批次共多少条 path（== filePairs.count，但单独存一份避免 decode 后再算）。
        public let fileCount: Int
        /// (originalPath, trashedPath) pair 列表。pair 顺序保留 NSWorkspace.recycle 回调顺序。
        public let filePairs: [FilePair]

        public struct FilePair: Codable, Equatable {
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

    /// 共享单例。生产代码所有调用方都走它。
    public static let shared = UndoHistoryStore()

    private convenience init() {
        self.init(storeURL: UndoHistoryStore.defaultStoreURL(), maxHistoryCount: 10)
    }

    /// 测试 / DI 用初始化器。
    public init(storeURL: URL, maxHistoryCount: Int = 10, fm: FileManager = .default) {
        self.storeURL = storeURL
        self.maxHistoryCount = maxHistoryCount
        self.fm = fm
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
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
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

    /// 检查并移除"trashedPath 已不存在"的陈旧记录（用户手动清空了系统废纸篓）。
    /// **判定口径**：record 的所有 pair 的 trashedPath 都不存在 → 整条 record 被剔除。
    /// 部分存在则保留（用户可能只清空了部分）。
    public func cleanupStaleEntries() {
        let initialCount = history.count
        history.removeAll { record in
            record.filePairs.allSatisfy { pair in
                !fm.fileExists(atPath: pair.trashed)
            }
        }
        if history.count < initialCount {
            saveHistory()
            GSYLog.info(.trash, "UndoHistory cleanupStaleEntries 剔除 \(initialCount - history.count) 条")
        }
    }

    /// 恢复一条记录。把所有 pair 的 trashedPath mv 回 originalPath。
    ///
    /// **冲突策略（"safe by default"）**：若 originalPath 已有同名文件 / 目录，
    /// 先把同名挪入用户废纸篓（NSWorkspace.recycle），再做 mv。这样不会丢用户当前文件。
    ///
    /// **返回**：(restoredCount, skippedCount, errorMessage?)
    /// - restoredCount：成功 mv 回原路径的 pair 数
    /// - skippedCount：trashedPath 不存在 / mv 失败的 pair 数
    /// - errorMessage：聚合的失败原因（仅 skipped > 0 时非 nil）
    ///
    /// 成功后该 record 自动从 history 移除。
    @discardableResult
    public func restoreRecord(_ record: Record) async -> (Int, Int, String?) {
        var restored = 0
        var skipped = 0
        var firstError: String?

        for pair in record.filePairs {
            let trashedURL = URL(fileURLWithPath: pair.trashed)
            let originalURL = URL(fileURLWithPath: pair.original)

            guard fm.fileExists(atPath: pair.trashed) else {
                skipped += 1
                if firstError == nil {
                    firstError = "trashedPath 不存在: \(pair.trashed)"
                }
                continue
            }

            // 冲突解决：originalPath 已存在 → 先把同名挪到废纸篓
            if fm.fileExists(atPath: pair.original) {
                let conflictResult = await Self.recycleConflict(at: originalURL)
                if let conflictErr = conflictResult {
                    skipped += 1
                    if firstError == nil {
                        firstError = "冲突解决失败: \(conflictErr)"
                    }
                    continue
                }
            }

            // 父目录可能在用户清理后被删了，先确保它存在
            let parentDir = originalURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            do {
                try fm.moveItem(at: trashedURL, to: originalURL)
                restored += 1
            } catch {
                skipped += 1
                if firstError == nil {
                    firstError = "moveItem 失败: \(error.localizedDescription)"
                }
                GSYLog.error(.trash, "UndoHistory restoreRecord mv 失败 \(pair.trashed) → \(pair.original) err=\(error.localizedDescription)")
            }
        }

        // 整条记录从历史剔除（即便 partial 成功，剩余的 trashed 也已不再可信）
        if let idx = history.firstIndex(where: { $0.id == record.id }) {
            history.remove(at: idx)
            saveHistory()
        }

        GSYLog.info(.trash, "UndoHistory restoreRecord 完成 restored=\(restored) skipped=\(skipped) err=\(firstError ?? "nil")")
        return (restored, skipped, firstError)
    }

    /// 用 NSWorkspace.recycle 把单个冲突文件丢到用户废纸篓。返回 nil = 成功，非 nil = 错误描述。
    /// 这是 restoreRecord 的子例程，独立 static 方便测试时替换。
    private static func recycleConflict(at url: URL) async -> String? {
        await withCheckedContinuation { (cc: CheckedContinuation<String?, Never>) in
            let gate = ConflictGate(cc: cc)
            NSWorkspace.shared.recycle([url]) { trashed, error in
                if let error {
                    gate.fire("recycle conflict failed: \(error.localizedDescription)")
                } else if trashed.isEmpty {
                    gate.fire("recycle returned empty trashed for \(url.path)")
                } else {
                    gate.fire(nil)
                }
            }
        }
    }

    /// 公开 storeURL 供测试断言（@MainActor 可见即可）。
    public var underlyingStoreURL: URL { storeURL }

    // MARK: - Persistence

    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(history)
            // 父目录可能尚未创建
            let parent = storeURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            GSYLog.error(.trash, "UndoHistory saveHistory 失败 err=\(error.localizedDescription)")
        }
    }

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

/// recycle 回调可能在任意线程；用 OneShot 保证 cc 只 resume 一次。
private final class ConflictGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cc: CheckedContinuation<String?, Never>

    init(cc: CheckedContinuation<String?, Never>) {
        self.cc = cc
    }

    @discardableResult
    func fire(_ value: String?) -> Bool {
        lock.lock()
        if fired {
            lock.unlock()
            return false
        }
        fired = true
        lock.unlock()
        cc.resume(returning: value)
        return true
    }
}
