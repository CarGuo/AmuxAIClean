import Darwin
import CryptoKit
import Dispatch
import Foundation
import LogKit

/// Step 7：UndoHistory 持久化 + 单点恢复链路。
///
/// **职责**：
/// - 记录最近 N 次 trash 操作（默认 10），每次记录一个"批次"，含原路径 → 废纸篓路径 pair。
/// - 把记录持久化到 `~/Library/Application Support/AmuxAIClean/UndoHistory.json`。
///   App 内读写共享同一 flock；写入以固定 WAL 先落盘，再对已存在文件做 descriptor-bound
///   rewrite。该协议保证 App 内不会观察到中间态，但不对绕过 flock 的外部读取宣称原子可见。
/// - 支持单条恢复：只有 `trashedPath` 仍指向写历史时冻结的同一文件对象，才把它移回原路径。
/// - 若 `originalPath` 已存在，先生成显式冲突计划；只有用户选择“跳过”或“恢复为新名称”后才执行。
///   恢复链路本身永远不会移动、覆盖或删除用户后来创建的同名文件。
/// - 最近操作记录与“当前仍可恢复”是两个不同事实：`filePairs` 是不可变操作事实，
///   `recoveryStates` 是每个 pair 的可变恢复状态。清空废纸篓、路径复用或成功恢复都不能
///   删除或改写这次清理事实。
///
/// **设计参考**：[Pearcleaner UndoHistoryManager](file:///Users/guoshuyu/workspace/GSYCleanMac/tmp/competitors/Pearcleaner/Pearcleaner/Logic/UndoHistoryManager.swift)。
///
/// **测试钩子**：`init(storeURL:)` 让 `UndoHistoryStoreTests` 能注入 FixtureFS 临时目录，
/// 不污染真实用户 Application Support。生产代码用 `UndoHistoryStore.shared`。
///
/// **并发**：`@MainActor`，与 [HeuristicRecorder](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/HeuristicRecorder.swift)
/// 不同——本 store 是 UI 直接消费的（侧栏列表渲染），跑在主 Actor 反而省一层桥接。
public extension Notification.Name {
    static let gsyUndoDidRestore = Notification.Name("GSYCleanMac.UndoDidRestore")
}

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
        public let identityChangedTrashPaths: [String]
        public let unavailableTrashPaths: [String]
        public let unavailableDestinationPaths: [String]
        public let outOfScopeDestinationPaths: [String]

        public var requiresConflictChoice: Bool { !conflictPaths.isEmpty }
    }

    /// v2026.07.15：恢复失败只保存语义和系统原文；结果弹窗在渲染时按当前 App locale
    /// 投影，避免异步恢复完成时把某一种语言长期冻结在状态里。
    public enum RestoreFailure: Sendable, Equatable {
        case trashedItemMissing(path: String)
        case trashedItemIdentityChanged(path: String)
        case trashedItemIdentityUnavailable(path: String)
        case historyRecordUnavailable
        case restoreAlreadyInProgress
        case destinationAlreadyExists(path: String)
        case destinationOutsideAllowedScope(path: String)
        case destinationUnavailable(path: String)
        case createDestinationDirectoryFailed(systemDescription: String)
        case moveFailed(systemDescription: String)

        public func message(locale: Locale) -> String {
            switch self {
            case .trashedItemMissing(let path):
                return AppLocalization.format(
                    "undo.err.trashed_missing %@",
                    locale: locale,
                    arguments: [path]
                )
            case .trashedItemIdentityChanged(let path):
                return AppLocalization.format(
                    "undo.err.trashed_identity_changed %@",
                    locale: locale,
                    arguments: [path]
                )
            case .trashedItemIdentityUnavailable(let path):
                return AppLocalization.format(
                    "undo.err.trashed_identity_unavailable %@",
                    locale: locale,
                    arguments: [path]
                )
            case .historyRecordUnavailable:
                return AppLocalization.string("undo.err.history_record_unavailable", locale: locale)
            case .restoreAlreadyInProgress:
                return AppLocalization.string("undo.err.restore_in_progress", locale: locale)
            case .destinationAlreadyExists(let path):
                return AppLocalization.format(
                    "undo.err.original_exists %@",
                    locale: locale,
                    arguments: [path]
                )
            case .destinationOutsideAllowedScope:
                return AppLocalization.string(
                    "undo.err.destination_outside_scope",
                    locale: locale
                )
            case .destinationUnavailable(let path):
                return AppLocalization.format(
                    "undo.err.destination_unavailable %@",
                    locale: locale,
                    arguments: [path]
                )
            case .createDestinationDirectoryFailed:
                // v2026.07.16：关联值仅用于诊断/日志，用户界面不展示 raw FileManager Error。
                return AppLocalization.string("undo.err.create_parent_failed", locale: locale)
            case .moveFailed:
                return AppLocalization.string("undo.err.move_item_failed", locale: locale)
            }
        }
    }

    /// 一次恢复的结构化结果。`firstFailure` 由 View 按当前 locale 投影。
    public struct RestoreResult: Sendable, Equatable {
        public let restoredCount: Int
        public let skippedCount: Int
        public let renamedCount: Int
        public let firstFailure: RestoreFailure?
        public let restoredPaths: [String]
        public let restoredOriginalPaths: [String]

        public init(
            restoredCount: Int,
            skippedCount: Int,
            renamedCount: Int,
            firstFailure: RestoreFailure?,
            restoredPaths: [String] = [],
            restoredOriginalPaths: [String] = []
        ) {
            self.restoredCount = restoredCount
            self.skippedCount = skippedCount
            self.renamedCount = renamedCount
            self.firstFailure = firstFailure
            self.restoredPaths = restoredPaths
            self.restoredOriginalPaths = restoredOriginalPaths
        }
    }

    private struct RestoreExecution: Sendable {
        let result: RestoreResult
        let recoveryStates: [Record.RecoveryState]
        let restoredPaths: [String]
    }

    private struct RestorePreparation: Sendable {
        let plan: RestorePlan
        let recoveryStates: [Record.RecoveryState]
    }

    /// 单条 trash 批次记录。`Identifiable` 让 SwiftUI List 能直接 ForEach。
    public struct Record: Codable, Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        /// 来源标签，如 `"clean"` / `"uninstall"` / `"large-file"`。仅用于侧栏显示分类，不参与恢复逻辑。
        public let source: String
        /// Non-nil for records assembled from durable recycle callbacks. Multiple callback
        /// batches for the same user operation merge into this one immutable history fact.
        public let journalOperationID: UUID?
        /// 该批次共多少条 path（== filePairs.count，但单独存一份避免 decode 后再算）。
        public let fileCount: Int
        /// (originalPath, trashedPath) pair 列表。pair 顺序保留统一删除管道的成功回调顺序。
        public let filePairs: [FilePair]
        /// v2026.07.18：与 `filePairs` 等长、按 index 对齐的当前恢复状态。
        /// 它可以变化，但绝不反向删除或改写 filePairs 记录的操作事实。
        public let recoveryStates: [RecoveryState]

        /// Ledger、completion journal 与 Undo 恢复共用同一个身份合同；禁止各自维护略有
        /// 差异的 inode/birthtime 结构，否则迁移或回调边界会重新打开 ABA 窗口。
        public typealias FileIdentity = TrashObjectIdentity

        public struct FilePair: Codable, Equatable, Sendable {
            public let original: String
            public let trashed: String
            /// nil 只来自旧 JSON 或写入时无法取得身份；两者都必须 fail-closed，不能猜测恢复。
            public let trashedIdentity: FileIdentity?
            /// 新完成协议写入的幂等键。跨进程 RMW 只以这个键去重，路径不能承担事务身份。
            public let journalID: String?
            /// Exact AppKit attempt bound into `journalID`. Schema-2 pairs did not persist this
            /// capability and are migrated conservatively instead of guessing it from an opaque
            /// digest (v2026.07.18 receipt-binding fix).
            public let journalAttemptID: UUID?
            /// 删除预检时冻结的恢复范围根。旧记录可在 Store 的受信根中重新归属；新记录
            /// 必须携带它，防止修改 JSON 后把恢复目标指向授权范围之外。
            public let restoreScopeRoot: String?

            public init(original: String, trashed: String) {
                self.original = original
                self.trashed = trashed
                self.trashedIdentity = Record.probeIdentity(atPath: trashed).identity
                self.journalID = nil
                self.journalAttemptID = nil
                self.restoreScopeRoot = nil
            }

            init(
                original: String,
                trashed: String,
                trashedIdentity: FileIdentity,
                journalID: String,
                journalAttemptID: UUID,
                restoreScopeRoot: String
            ) {
                self.original = TrashPipeline.normalizePath(original)
                self.trashed = TrashPipeline.normalizePath(trashed)
                self.trashedIdentity = trashedIdentity
                self.journalID = journalID
                self.journalAttemptID = journalAttemptID
                self.restoreScopeRoot = TrashPipeline.normalizePath(restoreScopeRoot)
            }

            fileprivate init(
                migrating pair: FilePair,
                journalID: String?,
                journalAttemptID: UUID?
            ) {
                self.original = pair.original
                self.trashed = pair.trashed
                self.trashedIdentity = pair.trashedIdentity
                self.journalID = journalID
                self.journalAttemptID = journalAttemptID
                self.restoreScopeRoot = pair.restoreScopeRoot
            }
        }

        public enum RecoveryStatus: String, Codable, Equatable, Sendable {
            case checking
            case available
            case missing
            case identityChanged
            case unavailable
            case restored
        }

        public struct RecoveryState: Codable, Equatable, Sendable {
            public let status: RecoveryStatus
            /// 仅 restored 时非 nil；冲突恢复可能与 original 不同。
            public let restoredDestination: String?

            public init(status: RecoveryStatus, restoredDestination: String? = nil) {
                self.status = status
                self.restoredDestination = restoredDestination
            }
        }

        public init(id: UUID = UUID(),
                    timestamp: Date = Date(),
                    source: String,
                    filePairs: [FilePair],
                    recoveryStates: [RecoveryState]? = nil,
                    journalOperationID: UUID? = nil) {
            self.id = id
            self.timestamp = timestamp
            self.source = source
            self.journalOperationID = journalOperationID
            self.fileCount = filePairs.count
            self.filePairs = filePairs
            if let recoveryStates, recoveryStates.count == filePairs.count {
                self.recoveryStates = recoveryStates
            } else {
                self.recoveryStates = filePairs.map {
                    RecoveryState(status: $0.trashedIdentity == nil ? .unavailable : .available)
                }
            }
        }

        public func recoveryState(at index: Int) -> RecoveryState {
            guard recoveryStates.indices.contains(index) else {
                return RecoveryState(status: .unavailable)
            }
            return recoveryStates[index]
        }

        public var hasRestorableItems: Bool {
            recoveryStates.contains { $0.status == .available }
        }

        private enum CodingKeys: String, CodingKey {
            case id, timestamp, source, journalOperationID, fileCount, filePairs, recoveryStates
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            source = try container.decode(String.self, forKey: .source)
            journalOperationID = try container.decodeIfPresent(UUID.self, forKey: .journalOperationID)
            filePairs = try container.decode([FilePair].self, forKey: .filePairs)
            fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount) ?? filePairs.count

            let persisted = try container.decodeIfPresent(
                [RecoveryState].self,
                forKey: .recoveryStates
            )
            if let persisted, persisted.count == filePairs.count {
                // v2026.07.18：available 只是上次进程的观察，重启后必须重新探测；
                // restored 是已经发生的历史终态，不依赖废纸篓路径继续存在。
                recoveryStates = persisted.map { state in
                    state.status == .restored ? state : RecoveryState(status: .checking)
                }
            } else {
                // 旧 JSON 没有可信对象身份。即使路径现在存在，也可能已经被复用，必须保守拒绝。
                recoveryStates = filePairs.map { _ in RecoveryState(status: .unavailable) }
            }
        }

        fileprivate func updatingRecoveryStates(_ states: [RecoveryState]) -> Record {
            Record(
                id: id,
                timestamp: timestamp,
                source: source,
                filePairs: filePairs,
                recoveryStates: states,
                journalOperationID: journalOperationID
            )
        }

        fileprivate enum IdentityProbe: Sendable {
            case present(FileIdentity)
            case missing
            case unavailable

            var identity: FileIdentity? {
                guard case .present(let identity) = self else { return nil }
                return identity
            }
        }

        fileprivate static func probeIdentity(atPath path: String) -> IdentityProbe {
            switch TrashObjectIdentity.probe(path: path) {
            case .present(let identity): return .present(identity)
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
        }
    }

    /// 当前内存中的历史记录，最新的在最前。视图直接绑定。
    @Published public private(set) var history: [Record] = []

    /// Read/write failures are product state, not “an empty history”. The UI localizes these
    /// semantic cases and keeps raw errno/paths in structured logs only.
    public enum StorageState: Sendable, Equatable {
        case loading
        case ready
        case readFailed
        case corrupt
        case storeTooLarge(maxBytes: Int)
        case recordRejected(maxPairs: Int)
        case writeFailed
    }

    @Published public private(set) var storageState: StorageState = .loading

    /// Callback-journal health is orthogonal to UndoHistory read/write health. It is derived from
    /// the ledger's full set of exact blocked attempts, never from the success of an unrelated
    /// journal receipt prune (v2026.07.18 operation-scoped health fix).
    public enum CompletionJournalState: Sendable, Equatable {
        case ready
        case blocked
    }

    /// Fail closed until one complete startup recovery proves both durable stores empty/healthy.
    /// A default `.ready` creates a real window where UI can authorize deletion before replay.
    @Published public private(set) var completionJournalState: CompletionJournalState = .blocked
    private var blockedCompletionJournalAttempts: Set<TrashPendingAttemptIdentity> = []
    /// A callback whose journal fact is immutable but whose ledger transition has not crossed
    /// fsync is process-local authority. A later empty disk snapshot must not erase it.
    private var locallyUnsettledCompletionAttempts: Set<TrashPendingAttemptIdentity> = []
    /// Non-structured callbacks can enqueue MainActor work out of order. Revisions are assigned
    /// from the synchronous retry state (`pending=0`, later terminal retry > 0), so a delayed
    /// pending projection can never overwrite a terminal one for the same exact attempt.
    private var completionJournalSettlementRevisions: [TrashPendingAttemptIdentity: Int] = [:]
    private var activeCompletionJournalRecoveries: Set<UUID> = []
    /// A failed ledger/journal read cannot be projected as an authoritative empty set. Preserve a
    /// blocked UI state until a later full snapshot succeeds.
    private var completionJournalAuthorityUnavailable = false

    /// 最多保留 N 条，超出按 LRU 丢弃。
    private let maxHistoryCount: Int
    private let storeURL: URL
    private let legacyStoreURL: URL?
    private let allowedRestoreRoots: [String]
    /// 所有后台落盘都进入同一 FIFO 队列，保证较旧的 snapshot 不会在较新的 snapshot
    /// 之后完成并覆盖磁盘。队列不承载 UI 状态，只做不可变 Data 的文件 IO。
    private let persistenceQueue: DispatchQueue
    /// v1.5.7：落盘策略。生产单例用 `.background`（串行队列卸主 actor），
    /// 测试用 `.synchronous` 保证 `addRecord` 返回后 `XCTAssertTrue(fileExists)` 立刻成立。
    private let saveStrategy: SaveStrategy
    /// 同一批次只能有一个真实恢复 owner；View guard 只是 presentation，Store 才是并发边界。
    private var activeRestoreRecordIDs: Set<UUID> = []
    /// v2026.07.18 P2: history presentation can request a refresh again when background loading
    /// publishes late records. The store, rather than the View, owns the single-flight boundary:
    /// a newer generation cancels and joins the previous filesystem probe before starting, and
    /// only the current generation may publish a result.
    private var recoveryRefreshGeneration: UInt64 = 0
    private struct RecoveryRefreshOutput: Sendable {
        let records: [Record]
        let changed: Bool
    }
    private var recoveryRefreshWorker: Task<RecoveryRefreshOutput?, Never>?
    private var recoveryRefreshWorkerGeneration: UInt64?
    /// O(1) publication identity for wide history snapshots. Record equality can traverse up to
    /// 100k file pairs and must never be used as a MainActor CAS at bootstrap/refresh boundaries.
    private var historyRevision: UInt64 = 0
    /// Background persistence completions may return after a newer MainActor mutation. Only the
    /// latest issued revision may replace the in-memory projection.
    private var persistenceRevision: UInt64 = 0
    private var appliedPersistenceRevision: UInt64 = 0
    /// Deterministic regression hook for the otherwise nanosecond source-name TOCTOU window.
    /// Production never sets it; the Sendable closure is snapshotted before leaving MainActor.
    private var restoreBeforeRenameHookForTesting: (@Sendable () -> Void)?
    /// Deterministic regression hook proving that all durable mutations share one FIFO queue.
    /// Production never sets it; the closure must not call back into this MainActor store.
    private var persistenceMutationHookForTesting: (@Sendable (String) -> Void)?
    /// MainActor publication-attempt hook for ordering tests. It fires before the latest-revision
    /// guard so a rejected stale completion can be observed without timing-based Task.yield loops.
    private var persistencePublicationHookForTesting: (@Sendable (UInt64) -> Void)?
    /// Deterministic interleaving hook for refresh cancellation/CAS tests. It runs on the utility
    /// worker before probing one Trash path and must never call back into this MainActor store.
    private var recoveryRefreshProbeHookForTesting: (@Sendable (String) -> Void)?

    public enum SaveStrategy: Sendable {
        case synchronous
        case background
    }

    public enum LoadStrategy: Sendable {
        case synchronous
        case background
    }

    nonisolated static let maximumStoreBytes = 8 * 1_024 * 1_024
    nonisolated static let maximumPairsPerRecord = 10_000
    nonisolated private static let maximumPathBytes = 16 * 1_024

    /// 共享单例。生产代码所有调用方都走它。
    public static let shared = UndoHistoryStore()

    private convenience init() {
        self.init(
            storeURL: UndoHistoryStore.defaultStoreURL(),
            maxHistoryCount: 10,
            saveStrategy: .background,
            loadStrategy: .background,
            legacyStoreURL: UndoHistoryStore.defaultLegacyStoreURL()
        )
    }

    /// 测试 / DI 用初始化器。**默认 synchronous**，保证测试断言可靠。
    public init(storeURL: URL,
                maxHistoryCount: Int = 10,
                saveStrategy: SaveStrategy = .synchronous,
                loadStrategy: LoadStrategy = .synchronous,
                legacyStoreURL: URL? = nil,
                allowedRestoreRoots: [String]? = nil) {
        self.storeURL = storeURL
        self.legacyStoreURL = legacyStoreURL
        self.maxHistoryCount = maxHistoryCount
        self.restoreBeforeRenameHookForTesting = nil
        self.persistenceMutationHookForTesting = nil
        self.recoveryRefreshProbeHookForTesting = nil
        self.allowedRestoreRoots = (allowedRestoreRoots ?? Self.defaultRestoreRoots())
            .map(TrashPipeline.normalizePath)
            .sorted { $0.count > $1.count }
        self.saveStrategy = saveStrategy
        self.persistenceQueue = DispatchQueue(
            label: "com.amux.ai.clean.undo-history.\(UUID().uuidString)",
            qos: .utility
        )
        switch loadStrategy {
        case .synchronous:
            let loaded = Self.bootstrapHistory(
                storeURL: storeURL,
                legacyStoreURL: legacyStoreURL,
                maxHistoryCount: maxHistoryCount,
                fileManager: .default
            )
            applyLoadedHistory(loaded)
        case .background:
            storageState = .loading
            // v2026.07.19 diagnostics contract: an empty History screen can mean "no durable
            // records", "bootstrap still running", or a typed storage failure. Record the
            // lifecycle boundary without persisting paths or record contents so field reports can
            // distinguish those states instead of treating every empty projection as user error.
            GSYLog.info(.trash, "undo_history.bootstrap.start strategy=background")
            Task { [weak self] in
                while let self {
                    let revision = self.persistenceRevision
                    let queue = self.persistenceQueue
                    let mutationHook = self.persistenceMutationHookForTesting
                    // v2026.07.18 P2 bootstrap ordering fix: read/decode joins the same serial
                    // persistence domain as snapshot/journal/receipt RMW. Every mutation bumps
                    // persistenceRevision before it enters that queue, so a bootstrap that ran
                    // ahead of a later callback is discarded and re-read after that callback.
                    // Reusing one detached `loaded` value across revisions could otherwise turn
                    // a valid same-operation file-pair extension into `.corrupt`.
                    let loaded = await withCheckedContinuation { continuation in
                        queue.async {
                            mutationHook?("bootstrap")
                            continuation.resume(returning: Self.bootstrapHistory(
                                storeURL: storeURL,
                                legacyStoreURL: legacyStoreURL,
                                maxHistoryCount: maxHistoryCount,
                                // Construct the Foundation reference inside its owning utility
                                // queue. Capturing an injected FileManager (and possible delegate)
                                // across this @Sendable boundary violated Swift 6 isolation.
                                fileManager: FileManager.default
                            ))
                        }
                    }
                    guard self.persistenceRevision == revision else { continue }

                    // A late bootstrap can overlap a callback merge containing up to 100k pairs.
                    // Snapshot comparison and union stay on a utility worker; MainActor only checks
                    // the revision and publishes the prepared value.
                    let current = self.history
                    let currentHistoryRevision = self.historyRevision
                    let prepared = await Task.detached(priority: .utility) {
                        Self.prepareBootstrapApplication(
                            loaded,
                            current: current,
                            maxHistoryCount: maxHistoryCount
                        )
                    }.value
                    guard self.persistenceRevision == revision,
                          self.historyRevision == currentHistoryRevision else { continue }
                    self.applyLoadedHistory(prepared)
                    break
                }
            }
        }
    }

    /// v2026.07.18：默认存储路径统一到当前品牌目录
    /// `~/Library/Application Support/AmuxAIClean/UndoHistory.json`。
    ///
    /// 生产单例的迁移、读取和 JSON 解码都在 utility task 完成。每次启动都通过 fd-bound
    /// 完整解码旧 `GSYCleanMac/UndoHistory.json`，再与当前品牌 envelope 做单调合并；不能把
    /// “新文件已存在”误当成旧进程已停止写入的证据。两边的 records、terminal state 与 receipts
    /// 都不会被另一边的旧快照撤销。legacy 文件始终保留，避免用 pathname unlink 重开替换竞态。
    /// 迁移失败记录结构化日志并投影 typed storage failure，禁止把失败伪装成空历史。
    public static func defaultStoreURL() -> URL {
        let support: URL
        if let standardSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            // Keep the standard Foundation location as the single base for both old and new names.
            // The fallback below is only for environments where the directory query fails.
            support = standardSupport
        } else {
            support = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        let base = support.appendingPathComponent("AmuxAIClean", isDirectory: true)
        return base.appendingPathComponent("UndoHistory.json")
    }

    private static func defaultLegacyStoreURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("GSYCleanMac", isDirectory: true)
            .appendingPathComponent("UndoHistory.json")
    }

    nonisolated private static func defaultRestoreRoots() -> [String] {
        var roots = [NSHomeDirectory()]
        for name in [Int32(_CS_DARWIN_USER_TEMP_DIR), Int32(_CS_DARWIN_USER_CACHE_DIR)] {
            let length = confstr(name, nil, 0)
            guard length > 1 else { continue }
            var buffer = [CChar](repeating: 0, count: length)
            guard confstr(name, &buffer, length) > 0 else { continue }
            let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
            roots.append(String(decoding: buffer[..<terminator].map {
                UInt8(bitPattern: $0)
            }, as: UTF8.self))
        }
        return roots
    }

    /// Internal so temp-fixture tests can verify migration without touching real Application Support.
    enum LegacyMigrationOutcome: Sendable, Equatable {
        /// No legacy entry exists, or reconciliation proved the retained source adds no new
        /// authority beyond the destination envelope plus its durable observed-ID watermark.
        case notNeeded
        /// A validated monotonic merge reached the durable destination boundary. Source retained.
        case migrated
        /// Migration could not prove a safe result. Bootstrap must expose this typed state instead
        /// of reading a raced destination or presenting an authoritative empty history.
        case rejected(StorageState)
    }

    /// v2026.07.19 P1 performance contract: this is the steady-state WAL budget after control
    /// files exist. It deliberately counts full-payload work separately from small marker writes;
    /// bootstrap/reserve allocation are one-time namespace work and are not hidden in these
    /// numbers. Tests consume the same diagnostic that production logs, so adding an accidental
    /// recovery pass or verification read cannot silently restore the 12x O(data) regression.
    struct LegacyMigrationCommitIODiagnostic: Sendable, Equatable {
        let mode: String
        let canonicalSnapshotFullReads: Int
        let walVerificationFullReads: Int
        let canonicalVerificationFullReads: Int
        let walFullWrites: Int
        let canonicalFullWrites: Int
        let markerWrites: Int
        let walDataFsyncs: Int
        let canonicalDataFsyncs: Int
        let markerFsyncs: Int
        let parentDirectoryFsyncs: Int
    }

    private struct LegacyMigrationObjectIdentity: Codable, Sendable, Equatable {
        var device: UInt64
        let inode: UInt64
        let fileType: UInt16
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let generation: UInt32

        init(
            device: UInt64,
            inode: UInt64,
            fileType: UInt16,
            birthSeconds: Int64,
            birthNanoseconds: Int64,
            generation: UInt32
        ) {
            self.device = device
            self.inode = inode
            self.fileType = fileType
            self.birthSeconds = birthSeconds
            self.birthNanoseconds = birthNanoseconds
            self.generation = generation
        }

        init(_ metadata: stat) {
            device = UInt64(bitPattern: Int64(metadata.st_dev))
            inode = UInt64(metadata.st_ino)
            fileType = UInt16(truncatingIfNeeded: metadata.st_mode & S_IFMT)
            birthSeconds = Int64(metadata.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(metadata.st_birthtimespec.tv_nsec)
            generation = UInt32(metadata.st_gen)
        }

        /// `st_dev` identifies the current mount instance; macOS may assign a different value
        /// after reboot even though the APFS object is unchanged. Persisted WAL authority is
        /// therefore bound by the fixed parent descriptor plus inode, birth time, generation and
        /// file type. Runtime descriptor/path CAS checks still use exact `Equatable` identity.
        ///
        /// v2026.07.20 P0: treating `st_dev` as a permanent volume identifier made every valid
        /// Undo WAL fail with `foreignMarkerIdentity` after a mount-device renumber, blocking all
        /// otherwise authorized Trash operations before `NSWorkspace.recycle` was called.
        func hasSameStableIdentityIgnoringMountDevice(as other: Self) -> Bool {
            inode == other.inode
                && fileType == other.fileType
                && birthSeconds == other.birthSeconds
                && birthNanoseconds == other.birthNanoseconds
                && generation == other.generation
        }

        func rebasedFromPersistedMount(
            device persistedDevice: UInt64,
            to currentDevice: UInt64
        ) -> Self? {
            guard device == persistedDevice else { return nil }
            var rebased = self
            rebased.device = currentDevice
            return rebased
        }
    }

    private struct LegacyMigrationFingerprint: Codable, Sendable, Equatable {
        var device: UInt64
        let inode: UInt64
        let mode: UInt16
        let linkCount: UInt64
        let ownerID: UInt32
        let groupID: UInt32
        let flags: UInt32
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let generation: UInt32

        init(_ metadata: stat) {
            device = UInt64(bitPattern: Int64(metadata.st_dev))
            inode = UInt64(metadata.st_ino)
            mode = UInt16(truncatingIfNeeded: metadata.st_mode)
            linkCount = UInt64(metadata.st_nlink)
            ownerID = UInt32(metadata.st_uid)
            groupID = UInt32(metadata.st_gid)
            flags = UInt32(metadata.st_flags)
            byteCount = Int64(metadata.st_size)
            modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
            birthSeconds = Int64(metadata.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(metadata.st_birthtimespec.tv_nsec)
            generation = UInt32(metadata.st_gen)
        }

        var isRegularSingleLink: Bool {
            mode_t(mode) & S_IFMT == S_IFREG && linkCount == 1 && byteCount >= 0
        }

        var isSecureControlFile: Bool {
            isRegularSingleLink
                && ownerID == UInt32(geteuid())
                && mode_t(mode) & mode_t(0o777) == mode_t(S_IRUSR | S_IWUSR)
        }

        var objectIdentity: LegacyMigrationObjectIdentity {
            LegacyMigrationObjectIdentity(
                device: device,
                inode: inode,
                fileType: mode & UInt16(S_IFMT),
                birthSeconds: birthSeconds,
                birthNanoseconds: birthNanoseconds,
                generation: generation
            )
        }

        func hasSameObjectIdentity(as other: LegacyMigrationFingerprint) -> Bool {
            objectIdentity == other.objectIdentity
        }

        func rebasedFromPersistedMount(
            device persistedDevice: UInt64,
            to currentDevice: UInt64
        ) -> Self? {
            guard device == persistedDevice else { return nil }
            var rebased = self
            rebased.device = currentDevice
            return rebased
        }

        var renameStableMetadata: LegacyMigrationRenameStableMetadata {
            LegacyMigrationRenameStableMetadata(
                mode: mode,
                linkCount: linkCount,
                ownerID: ownerID,
                groupID: groupID,
                flags: flags,
                byteCount: byteCount,
                modificationSeconds: modificationSeconds,
                modificationNanoseconds: modificationNanoseconds
            )
        }
    }

    /// RENAME_EXCL and descriptor-bound content writes change ctime. Recovery therefore uses the
    /// full `stat` only before mutation; afterwards these stable fields plus a bounded digest prove
    /// exact old/new bytes without treating ctime as a cross-mutation invariant.
    private struct LegacyMigrationRenameStableMetadata: Codable, Sendable, Equatable {
        let mode: UInt16
        let linkCount: UInt64
        let ownerID: UInt32
        let groupID: UInt32
        let flags: UInt32
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private struct LegacyMigrationVersionEvidence: Codable, Sendable, Equatable {
        let objectIdentity: LegacyMigrationObjectIdentity
        let metadata: LegacyMigrationRenameStableMetadata
        let contentSHA256: String

        init(fingerprint: LegacyMigrationFingerprint, data: Data) {
            objectIdentity = fingerprint.objectIdentity
            metadata = fingerprint.renameStableMetadata
            contentSHA256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }

        private init(
            objectIdentity: LegacyMigrationObjectIdentity,
            metadata: LegacyMigrationRenameStableMetadata,
            contentSHA256: String
        ) {
            self.objectIdentity = objectIdentity
            self.metadata = metadata
            self.contentSHA256 = contentSHA256
        }

        func rebasedFromPersistedMount(
            device persistedDevice: UInt64,
            to currentDevice: UInt64
        ) -> Self? {
            guard let rebasedIdentity = objectIdentity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ) else { return nil }
            return Self(
                objectIdentity: rebasedIdentity,
                metadata: metadata,
                contentSHA256: contentSHA256
            )
        }
    }

    private enum LegacyMigrationTransactionPhase: String, Codable, Sendable {
        case idle
        case allocatingReserve
        case rewritingStage
        case prepared
    }

    /// v2026.07.19 P2: Darwin has no conditional pathname replacement primitive. Existing
    /// destinations therefore use two fixed WAL data slots plus two marker generations, and the
    /// canonical JSON is rewritten only through a frozen descriptor. A later pathname replacement
    /// is never swapped, renamed or unlinked by this transaction. Missing destinations alone use
    /// RENAME_EXCL. Control inodes are identity-bound and fixed-count; ambiguous bytes remain for
    /// diagnosis instead of being guessed or automatically rolled back.
    private struct LegacyMigrationTransactionPayload: Codable, Sendable, Equatable {
        static let protocolVersion = 2

        let protocolVersion: Int
        let generation: UInt64
        let phase: LegacyMigrationTransactionPhase
        let transactionID: UUID?
        let destinationName: String
        let stageName: String
        let expectedDestination: LegacyMigrationFingerprint?
        let expectedDestinationVersion: LegacyMigrationVersionEvidence?
        let stageFingerprint: LegacyMigrationFingerprint
        let stageVersion: LegacyMigrationVersionEvidence
        let reserveStageName: String?
        let reserveStageFingerprint: LegacyMigrationFingerprint?
        let reserveStageVersion: LegacyMigrationVersionEvidence?
        let marker0Identity: LegacyMigrationObjectIdentity
        let marker1Identity: LegacyMigrationObjectIdentity

        /// Checksum verification always happens against the exact persisted bytes first. Only
        /// after both fixed marker names are descriptor-bound and their stable identities agree
        /// do we rebase mount-scoped device values for this boot. This preserves strict in-process
        /// CAS semantics without confusing an APFS mount renumber with object replacement.
        func rebasedFromPersistedMount(
            device persistedDevice: UInt64,
            to currentDevice: UInt64
        ) -> Self? {
            let rebasedExpectedDestination: LegacyMigrationFingerprint?
            if let expectedDestination {
                guard let value = expectedDestination.rebasedFromPersistedMount(
                    device: persistedDevice,
                    to: currentDevice
                ) else { return nil }
                rebasedExpectedDestination = value
            } else {
                rebasedExpectedDestination = nil
            }
            let rebasedExpectedDestinationVersion: LegacyMigrationVersionEvidence?
            if let expectedDestinationVersion {
                guard let value = expectedDestinationVersion.rebasedFromPersistedMount(
                    device: persistedDevice,
                    to: currentDevice
                ) else { return nil }
                rebasedExpectedDestinationVersion = value
            } else {
                rebasedExpectedDestinationVersion = nil
            }
            let rebasedReserveStageFingerprint: LegacyMigrationFingerprint?
            if let reserveStageFingerprint {
                guard let value = reserveStageFingerprint.rebasedFromPersistedMount(
                    device: persistedDevice,
                    to: currentDevice
                ) else { return nil }
                rebasedReserveStageFingerprint = value
            } else {
                rebasedReserveStageFingerprint = nil
            }
            let rebasedReserveStageVersion: LegacyMigrationVersionEvidence?
            if let reserveStageVersion {
                guard let value = reserveStageVersion.rebasedFromPersistedMount(
                    device: persistedDevice,
                    to: currentDevice
                ) else { return nil }
                rebasedReserveStageVersion = value
            } else {
                rebasedReserveStageVersion = nil
            }
            guard let rebasedStageFingerprint = stageFingerprint.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ), let rebasedStageVersion = stageVersion.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ), let rebasedMarker0Identity = marker0Identity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ), let rebasedMarker1Identity = marker1Identity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ) else { return nil }
            return Self(
                protocolVersion: protocolVersion,
                generation: generation,
                phase: phase,
                transactionID: transactionID,
                destinationName: destinationName,
                stageName: stageName,
                expectedDestination: rebasedExpectedDestination,
                expectedDestinationVersion: rebasedExpectedDestinationVersion,
                stageFingerprint: rebasedStageFingerprint,
                stageVersion: rebasedStageVersion,
                reserveStageName: reserveStageName,
                reserveStageFingerprint: rebasedReserveStageFingerprint,
                reserveStageVersion: rebasedReserveStageVersion,
                marker0Identity: rebasedMarker0Identity,
                marker1Identity: rebasedMarker1Identity
            )
        }
    }

    private struct LegacyMigrationTransactionRecord: Codable, Sendable, Equatable {
        let slot: Int
        let markerIdentity: LegacyMigrationObjectIdentity
        let payload: LegacyMigrationTransactionPayload
        let checksum: String
    }

    private struct LegacyMigrationTransactionChecksumMaterial: Codable, Sendable {
        let slot: Int
        let markerIdentity: LegacyMigrationObjectIdentity
        let payload: LegacyMigrationTransactionPayload
    }

    private struct LegacyMigrationBootstrapStagePayload: Codable, Sendable, Equatable {
        let protocolVersion: Int
        let destinationName: String
        let stageName: String
        let stageIdentity: LegacyMigrationObjectIdentity
        let reserveStageName: String
        let reserveStageIdentity: LegacyMigrationObjectIdentity
        let marker0Identity: LegacyMigrationObjectIdentity
        let marker1Identity: LegacyMigrationObjectIdentity

        func rebasedFromPersistedMount(
            device persistedDevice: UInt64,
            to currentDevice: UInt64
        ) -> Self? {
            guard let stageIdentity = stageIdentity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ), let reserveStageIdentity = reserveStageIdentity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ), let marker0Identity = marker0Identity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ), let marker1Identity = marker1Identity.rebasedFromPersistedMount(
                device: persistedDevice,
                to: currentDevice
            ) else { return nil }
            return Self(
                protocolVersion: protocolVersion,
                destinationName: destinationName,
                stageName: stageName,
                stageIdentity: stageIdentity,
                reserveStageName: reserveStageName,
                reserveStageIdentity: reserveStageIdentity,
                marker0Identity: marker0Identity,
                marker1Identity: marker1Identity
            )
        }
    }

    private struct LegacyMigrationBootstrapStageRecord: Codable, Sendable, Equatable {
        let payload: LegacyMigrationBootstrapStagePayload
        let checksum: String
    }

    private struct LegacyMigrationTransactionState: Sendable {
        let activeSlot: Int
        let activeMarkerIdentity: LegacyMigrationObjectIdentity
        let payload: LegacyMigrationTransactionPayload
    }

    private struct LegacyMigrationStageSet: Sendable {
        let name: String
        let fingerprint: LegacyMigrationFingerprint
        let version: LegacyMigrationVersionEvidence
        let reserveName: String?
        let reserveFingerprint: LegacyMigrationFingerprint?
        let reserveVersion: LegacyMigrationVersionEvidence?
    }

    private struct ValidatedLegacyMigrationMarker {
        let record: LegacyMigrationTransactionRecord
        let liveMarkerIdentity: LegacyMigrationObjectIdentity
        let rebasedPayload: LegacyMigrationTransactionPayload
    }

    private enum LegacyMigrationMarkerReadResult {
        case absent
        case torn(identity: LegacyMigrationObjectIdentity, reason: String)
        case invalid(reason: String)
        case valid(ValidatedLegacyMigrationMarker)
    }

    private enum LegacyMigrationEntryProbe {
        case absent
        case present(LegacyMigrationFingerprint)
        case failed(errno: Int32)
    }

    private enum LegacyMigrationEntryReadResult {
        case absent
        case present(fingerprint: LegacyMigrationFingerprint, data: Data)
        case failed(reason: String, errno: Int32?)
    }

    private enum LegacyMigrationRecoveryDisposition {
        case ready(LegacyMigrationTransactionState)
        case committed(LegacyMigrationTransactionState)
        case rejected(reason: String, errno: Int32?)
    }

    private enum LegacyMigrationControlLoadResult {
        case absent
        case loaded(LegacyMigrationTransactionState)
        case rejected(reason: String, errno: Int32?)
    }

    private struct LegacyMigrationTransactionFailure: Error, Sendable {
        let reason: String
        let errno: Int32?
    }

    nonisolated private static let legacyMigrationStageNames = [
        ".UndoHistory.schema4-cas.stage-0",
        ".UndoHistory.schema4-cas.stage-1"
    ]
    nonisolated private static let legacyMigrationMarkerNames = [
        ".UndoHistory.schema4-cas.marker-0",
        ".UndoHistory.schema4-cas.marker-1"
    ]
    nonisolated private static let maximumLegacyMigrationMarkerBytes = 16 * 1_024

    private struct LegacyMigrationControlNames: Sendable {
        let stages: [String]
        let markers: [String]
    }

    /// v2026.07.19 P2 namespace fix: the production `UndoHistory.json` keeps the documented fixed
    /// names. Custom/test store URLs in the same directory receive a deterministic digest suffix,
    /// otherwise one store's marker authority can make another readable JSON fail closed.
    nonisolated private static func legacyMigrationControlNames(
        destinationName: String
    ) -> LegacyMigrationControlNames {
        guard destinationName != "UndoHistory.json" else {
            return LegacyMigrationControlNames(
                stages: legacyMigrationStageNames,
                markers: legacyMigrationMarkerNames
            )
        }
        let digest = SHA256.hash(data: Data(destinationName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let prefix = ".UndoHistory.schema4-cas.\(digest)"
        return LegacyMigrationControlNames(
            stages: ["\(prefix).stage-0", "\(prefix).stage-1"],
            markers: ["\(prefix).marker-0", "\(prefix).marker-1"]
        )
    }

    private enum FrozenLegacyReadResult {
        case success(Data)
        case failed(errno: Int32)
    }

    private struct FrozenDestinationEnvelope: Sendable {
        let envelope: HistoryEnvelope
        let fingerprint: LegacyMigrationFingerprint?
        let versionEvidence: LegacyMigrationVersionEvidence?
        let data: Data?
        let requiresPersistenceMigration: Bool
    }

    private enum FrozenDestinationReadResult {
        case success(FrozenDestinationEnvelope)
        case rejected(StorageState, stage: String, reason: String, errno: Int32?)
    }

    /// One anchored lock implementation is shared by migration and every ordinary App read/RMW.
    /// Returning an already-flocked descriptor prevents a pathname symlink/replacement from
    /// silently splitting cooperating processes across different lock inodes.
    nonisolated private static func acquireHistoryLock(
        parentDescriptor: Int32,
        lockName: String
    ) -> Int32? {
        guard validLeafName(lockName) else { errno = EINVAL; return nil }
        let descriptor = lockName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else { return nil }

        var descriptorMetadata = stat()
        errno = 0
        guard fstat(descriptor, &descriptorMetadata) == 0,
              secureLegacyMigrationControlMetadata(descriptorMetadata, maximumBytes: 0),
              flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            errno = code == 0 ? EPERM : code
            return nil
        }

        var lockedDescriptorMetadata = stat()
        var lockedPathMetadata = stat()
        let pathProbe = lockName.withCString {
            fstatat(parentDescriptor, $0, &lockedPathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &lockedDescriptorMetadata) == 0,
              secureLegacyMigrationControlMetadata(lockedDescriptorMetadata, maximumBytes: 0),
              pathProbe == 0,
              LegacyMigrationFingerprint(lockedPathMetadata)
                == LegacyMigrationFingerprint(lockedDescriptorMetadata) else {
            let code = errno
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            errno = code == 0 ? ESTALE : code
            return nil
        }
        return descriptor
    }

    /// v2026.07.19 P1 authority fix: migration is a monotonic reconciliation transaction, never
    /// a pathname move or a one-time "destination wins" copy. A non-cooperating old process can
    /// still append to the retained legacy path after any source fence; therefore every bootstrap
    /// re-reads that path through one no-follow, bounded descriptor and unions its records,
    /// terminal recovery states and commit receipts with the current-brand envelope. The current
    /// destination is read and replaced only while its stable flock is held. The source is
    /// deliberately retained because Darwin has no identity-bound unlink-by-fd operation.
    ///
    /// The final source fence proves only the snapshot included in this commit. A write that starts
    /// after that fence remains durable in the retained legacy file and is imported by the next
    /// bootstrap; no finite transaction can make an uncooperative second pathname synchronously
    /// quiescent. This eventual reconciliation boundary is explicit and regression-tested.
    @discardableResult
    nonisolated static func migrateLegacyStoreIfNeeded(
        from legacyURL: URL,
        to destinationURL: URL,
        fileManager _: FileManager = .default,
        beforeCommitHookForTesting: (@Sendable () -> Void)? = nil,
        afterSourceFenceHookForTesting: (@Sendable () -> Void)? = nil,
        beforeDestinationCommitHookForTesting: (@Sendable () -> Void)? = nil,
        afterDestinationDescriptorFenceHookForTesting: (@Sendable () -> Void)? = nil,
        transactionInterruptionHookForTesting: (@Sendable (String) -> Bool)? = nil,
        commitIODiagnosticHookForTesting: (@Sendable (LegacyMigrationCommitIODiagnostic) -> Void)? = nil,
        maxHistoryCount: Int = 10
    ) -> LegacyMigrationOutcome {
        let legacy = legacyURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let legacyName = legacy.lastPathComponent
        let destinationName = destination.lastPathComponent
        guard legacy.isFileURL,
              destination.isFileURL,
              legacy.path.hasPrefix("/"),
              destination.path.hasPrefix("/"),
              validLeafName(legacyName),
              validLeafName(destinationName) else {
            return legacyMigrationRejected(
                .readFailed,
                stage: "validatePath",
                reason: "invalidPath",
                legacy: legacy,
                destination: destination
            )
        }

        let legacyParent = legacy.deletingLastPathComponent()
        let legacyParentFD = legacyParent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard legacyParentFD >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .notNeeded }
            return legacyMigrationRejected(
                .readFailed,
                stage: "openLegacyParent",
                reason: "posix",
                errno: code,
                legacy: legacy,
                destination: destination
            )
        }
        defer { Darwin.close(legacyParentFD) }

        guard let destinationParentFD = openOrCreateLegacyMigrationDestinationParent(
            destination.deletingLastPathComponent()
        ) else {
            return legacyMigrationRejected(
                .writeFailed,
                stage: "openDestinationParent",
                reason: "posix",
                errno: errno,
                legacy: legacy,
                destination: destination
            )
        }
        defer { Darwin.close(destinationParentFD) }

        let lockName = destinationName + ".lock"
        guard let lockFD = acquireHistoryLock(
            parentDescriptor: destinationParentFD,
            lockName: lockName
        ) else {
            return legacyMigrationRejected(
                .writeFailed,
                stage: "openLock",
                reason: "unsafeLock",
                errno: errno,
                legacy: legacy,
                destination: destination
            )
        }
        defer { Darwin.close(lockFD) }
        defer { _ = flock(lockFD, LOCK_UN) }

        var transactionState: LegacyMigrationTransactionState?
        switch loadLegacyMigrationTransactionState(
            parentDescriptor: destinationParentFD,
            destinationName: destinationName
        ) {
        case .absent:
            break
        case .rejected(let reason, let code):
            return legacyMigrationRejected(
                .writeFailed,
                stage: "recoverDestinationTransaction",
                reason: reason,
                errno: code,
                legacy: legacy,
                destination: destination
            )
        case .loaded(let loadedState):
            switch recoverLegacyMigrationTransaction(
                loadedState,
                parentDescriptor: destinationParentFD
            ) {
            case .ready(let recovered), .committed(let recovered):
                transactionState = recovered
            case .rejected(let reason, let code):
                return legacyMigrationRejected(
                    .writeFailed,
                    stage: "recoverDestinationTransaction",
                    reason: reason,
                    errno: code,
                    legacy: legacy,
                    destination: destination
                )
            }
        }

        var destinationMetadata = stat()
        errno = 0
        let destinationProbe = destinationName.withCString {
            fstatat(destinationParentFD, $0, &destinationMetadata, AT_SYMLINK_NOFOLLOW)
        }
        let destinationExists = destinationProbe == 0
        guard destinationExists || errno == ENOENT else {
            return legacyMigrationRejected(
                .writeFailed,
                stage: "probeDestination",
                reason: "posix",
                errno: errno,
                legacy: legacy,
                destination: destination
            )
        }

        let legacyFD = legacyName.withCString {
            openat(
                legacyParentFD,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard legacyFD >= 0 else {
            let code = errno
            if code == ENOENT { return .notNeeded }
            return legacyMigrationRejected(
                .readFailed,
                stage: "openLegacy",
                reason: code == ELOOP ? "symlink" : "posix",
                errno: code,
                legacy: legacy,
                destination: destination
            )
        }
        defer { Darwin.close(legacyFD) }

        var openedMetadata = stat()
        guard fstat(legacyFD, &openedMetadata) == 0 else {
            return legacyMigrationRejected(
                .readFailed,
                stage: "statLegacy",
                reason: "posix",
                errno: errno,
                legacy: legacy,
                destination: destination
            )
        }
        let openedFingerprint = LegacyMigrationFingerprint(openedMetadata)
        guard openedFingerprint.isRegularSingleLink else {
            return legacyMigrationRejected(
                .readFailed,
                stage: "validateLegacy",
                reason: "notRegularSingleLink",
                legacy: legacy,
                destination: destination
            )
        }
        guard openedFingerprint.byteCount <= Int64(maximumStoreBytes) else {
            return legacyMigrationRejected(
                .storeTooLarge(maxBytes: maximumStoreBytes),
                stage: "validateLegacy",
                reason: "byteLimit",
                legacy: legacy,
                destination: destination
            )
        }

        let legacyData: Data
        switch readFrozenLegacyData(
            descriptor: legacyFD,
            expectedByteCount: Int(openedFingerprint.byteCount)
        ) {
        case .success(let data):
            legacyData = data
        case .failed(let code):
            return legacyMigrationRejected(
                code == EFBIG
                    ? .storeTooLarge(maxBytes: maximumStoreBytes)
                    : .readFailed,
                stage: "readLegacy",
                reason: code == EFBIG ? "byteLimit" : "posix",
                errno: code,
                legacy: legacy,
                destination: destination
            )
        }

        var postReadMetadata = stat()
        guard fstat(legacyFD, &postReadMetadata) == 0,
              LegacyMigrationFingerprint(postReadMetadata) == openedFingerprint else {
            return legacyMigrationRejected(
                .readFailed,
                stage: "readLegacy",
                reason: "versionChanged",
                legacy: legacy,
                destination: destination
            )
        }
        guard let decoded = decodeEnvelope(legacyData) else {
            return legacyMigrationRejected(
                .corrupt,
                stage: "decodeLegacy",
                reason: "invalidJSON",
                legacy: legacy,
                destination: destination
            )
        }
        if decoded.records.contains(where: { $0.filePairs.count > maximumPairsPerRecord }) {
            return legacyMigrationRejected(
                .recordRejected(maxPairs: maximumPairsPerRecord),
                stage: "decodeLegacy",
                reason: "recordLimit",
                legacy: legacy,
                destination: destination
            )
        }
        guard let migratedLegacy = migrateLegacyJournalIdentifiers(decoded),
              validate(migratedLegacy.envelope) else {
            return legacyMigrationRejected(
                .corrupt,
                stage: "validateEnvelope",
                reason: "invalidShape",
                legacy: legacy,
                destination: destination
            )
        }

        let destinationSnapshot: FrozenDestinationEnvelope
        if destinationExists {
            switch readFrozenDestinationEnvelope(
                parentDescriptor: destinationParentFD,
                leafName: destinationName,
                probedMetadata: destinationMetadata
            ) {
            case .success(let snapshot):
                destinationSnapshot = snapshot
            case .rejected(let state, let stage, let reason, let code):
                return legacyMigrationRejected(
                    state,
                    stage: stage,
                    reason: reason,
                    errno: code,
                    legacy: legacy,
                    destination: destination
                )
            }
        } else {
            destinationSnapshot = FrozenDestinationEnvelope(
                envelope: .empty,
                fingerprint: nil,
                versionEvidence: nil,
                data: nil,
                requiresPersistenceMigration: false
            )
        }

        let destinationRecordIDs = Set(destinationSnapshot.envelope.records.map(\.id))
        let legacyRecordsToReconcile = migratedLegacy.envelope.records.filter { record in
            destinationRecordIDs.contains(record.id)
                || !destinationSnapshot.envelope.legacyReconciliation.observedRecordIDs
                    .contains(record.id)
        }
        guard let mergedRecords = mergeRecordSnapshots(
            disk: destinationSnapshot.envelope.records,
            incoming: legacyRecordsToReconcile,
            maxHistoryCount: max(0, maxHistoryCount)
        ) else {
            return legacyMigrationRejected(
                .corrupt,
                stage: "mergeEnvelopes",
                reason: "conflictingRecordVersions",
                legacy: legacy,
                destination: destination
            )
        }
        var mergedReceipts = destinationSnapshot.envelope.committedJournalIDs
        for (identifier, recordedAt) in migratedLegacy.envelope.committedJournalIDs {
            if let existing = mergedReceipts[identifier] {
                // A receipt's key is the authority. Its date only supports bounded retention, so
                // keeping the later observation is monotonic and cannot revoke the commit fact.
                mergedReceipts[identifier] = max(existing, recordedAt)
            } else if !destinationSnapshot.envelope.legacyReconciliation
                .observedReceiptIDs.contains(identifier) {
                mergedReceipts[identifier] = recordedAt
            }
        }
        guard mergedReceipts.count <= maximumCommittedJournalIDs else {
            return legacyMigrationRejected(
                .recordRejected(maxPairs: maximumPairsPerRecord),
                stage: "mergeEnvelopes",
                reason: "receiptLimit",
                legacy: legacy,
                destination: destination
            )
        }
        var reconciliation = destinationSnapshot.envelope.legacyReconciliation
        reconciliation.observedRecordIDs.formUnion(
            migratedLegacy.envelope.records.map(\.id)
        )
        reconciliation.observedReceiptIDs.formUnion(
            migratedLegacy.envelope.committedJournalIDs.keys
        )
        guard reconciliation.observedRecordIDs.count <= maximumLegacyReconciliationIDs,
              reconciliation.observedReceiptIDs.count <= maximumLegacyReconciliationIDs else {
            return legacyMigrationRejected(
                .storeTooLarge(maxBytes: maximumStoreBytes),
                stage: "mergeEnvelopes",
                reason: "reconciliationWatermarkLimit",
                legacy: legacy,
                destination: destination
            )
        }
        let mergedEnvelope = HistoryEnvelope(
            schemaVersion: 4,
            records: mergedRecords,
            committedJournalIDs: mergedReceipts,
            legacyReconciliation: reconciliation
        )
        guard validate(mergedEnvelope), let mergedData = encodeHistory(mergedEnvelope) else {
            return legacyMigrationRejected(
                .corrupt,
                stage: "mergeEnvelopes",
                reason: "invalidMergedEnvelope",
                legacy: legacy,
                destination: destination
            )
        }
        guard mergedData.count <= maximumStoreBytes else {
            return legacyMigrationRejected(
                .storeTooLarge(maxBytes: maximumStoreBytes),
                stage: "mergeEnvelopes",
                reason: "byteLimit",
                legacy: legacy,
                destination: destination
            )
        }
        let destinationNeedsWrite = !destinationExists
            || destinationSnapshot.requiresPersistenceMigration
            || mergedEnvelope != destinationSnapshot.envelope

        guard destinationNeedsWrite else { return .notNeeded }

        let sourceFence: @Sendable () -> LegacyMigrationTransactionFailure? = {
            beforeCommitHookForTesting?()

            // v2026.07.19 P1: the retained legacy source must still be the exact descriptor/path
            // version that produced this transaction. A later old-process write remains in the
            // retained source and is imported by the next bootstrap.
            var finalDescriptorMetadata = stat()
            var finalPathMetadata = stat()
            let finalPathProbe = legacyName.withCString {
                fstatat(legacyParentFD, $0, &finalPathMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(legacyFD, &finalDescriptorMetadata) == 0,
                  LegacyMigrationFingerprint(finalDescriptorMetadata) == openedFingerprint,
                  finalPathProbe == 0,
                  LegacyMigrationFingerprint(finalPathMetadata) == openedFingerprint else {
                return .init(reason: "sourceChanged", errno: nil)
            }

            afterSourceFenceHookForTesting?()
            return nil
        }

        switch commitHistoryDataWithWAL(
            mergedData,
            destinationSnapshot: destinationSnapshot,
            transactionState: transactionState,
            parentDescriptor: destinationParentFD,
            destinationName: destinationName,
            beforePreparedFence: sourceFence,
            beforeDestinationCommitHook: beforeDestinationCommitHookForTesting,
            afterDestinationDescriptorFenceHook: afterDestinationDescriptorFenceHookForTesting,
            interruptionHook: transactionInterruptionHookForTesting,
            ioDiagnosticHook: commitIODiagnosticHookForTesting
        ) {
        case .success:
            break
        case .failure(let failure):
            let sourceChanged = failure.reason == "sourceChanged"
            return legacyMigrationRejected(
                sourceChanged ? .readFailed : .writeFailed,
                stage: sourceChanged ? "commitFence" : "commitDestinationWAL",
                reason: failure.reason,
                errno: failure.errno,
                legacy: legacy,
                destination: destination
            )
        }

        GSYLog.info(
            .trash,
            "undo_history.legacy_migration.complete mode=monotonicReconcile "
                + "sourceRetained=true records=\(mergedEnvelope.records.count) "
                + "receipts=\(mergedEnvelope.committedJournalIDs.count) "
                + "bytes=\(mergedData.count) from=\(legacy.path) to=\(destination.path)"
        )
        return .migrated
    }

    /// Single writer for migration and ordinary Undo RMW. Callers must own the destination flock
    /// and provide a frozen canonical snapshot from that same lock epoch.
    nonisolated private static func commitHistoryDataWithWAL(
        _ data: Data,
        destinationSnapshot: FrozenDestinationEnvelope,
        transactionState: LegacyMigrationTransactionState?,
        parentDescriptor: Int32,
        destinationName: String,
        beforePreparedFence: (@Sendable () -> LegacyMigrationTransactionFailure?)? = nil,
        beforeDestinationCommitHook: (@Sendable () -> Void)? = nil,
        afterDestinationDescriptorFenceHook: (@Sendable () -> Void)? = nil,
        interruptionHook: (@Sendable (String) -> Bool)? = nil,
        ioDiagnosticHook: (@Sendable (LegacyMigrationCommitIODiagnostic) -> Void)? = nil
    ) -> Result<LegacyMigrationTransactionState, LegacyMigrationTransactionFailure> {
        var ready: LegacyMigrationTransactionState
        switch ensureLegacyMigrationTransactionState(
            transactionState,
            parentDescriptor: parentDescriptor,
            destinationName: destinationName,
            interruptionHook: interruptionHook
        ) {
        case .loaded(let state): ready = state
        case .absent:
            return .failure(.init(reason: "missingControlState", errno: nil))
        case .rejected(let reason, let code):
            return .failure(.init(reason: reason, errno: code))
        }
        if ready.payload.reserveStageName == nil {
            switch ensureLegacyMigrationReserveStage(
                ready,
                parentDescriptor: parentDescriptor,
                interruptionHook: interruptionHook
            ) {
            case .success(let state): ready = state
            case .failure(let failure): return .failure(failure)
            }
        }

        let stageFD: Int32
        switch openLegacyMigrationStage(
            parentDescriptor: parentDescriptor,
            destinationName: destinationName,
            stageName: ready.payload.stageName,
            expected: ready.payload.stageFingerprint,
            expectedVersion: ready.payload.stageVersion
        ) {
        case .success(let descriptor): stageFD = descriptor
        case .failure(let failure): return .failure(failure)
        }
        defer { Darwin.close(stageFD) }
        guard let reserveName = ready.payload.reserveStageName,
              let reserveFingerprint = ready.payload.reserveStageFingerprint,
              let reserveVersion = ready.payload.reserveStageVersion else {
            return .failure(.init(reason: "missingReserveStage", errno: nil))
        }
        let reserveFD: Int32
        switch openLegacyMigrationStage(
            parentDescriptor: parentDescriptor,
            destinationName: destinationName,
            stageName: reserveName,
            expected: reserveFingerprint,
            expectedVersion: reserveVersion
        ) {
        case .success(let descriptor): reserveFD = descriptor
        case .failure(let failure): return .failure(failure)
        }
        defer { Darwin.close(reserveFD) }

        let transactionID = UUID()
        let rewriting: LegacyMigrationTransactionState
        switch advanceLegacyMigrationTransaction(
            ready,
            phase: .rewritingStage,
            transactionID: transactionID,
            expectedDestination: destinationSnapshot.fingerprint,
            expectedDestinationVersion: destinationSnapshot.versionEvidence,
            stageFingerprint: ready.payload.stageFingerprint,
            stageVersion: ready.payload.stageVersion,
            parentDescriptor: parentDescriptor
        ) {
        case .success(let state): rewriting = state
        case .failure(let failure): return .failure(failure)
        }
        if interruptionHook?("afterRewritingMarkerFsync") == true {
            return .failure(.init(reason: "interruptedAfterRewritingMarkerFsync", errno: nil))
        }

        func exactPathFence(
            descriptor: Int32,
            name: String,
            expected: LegacyMigrationFingerprint
        ) -> Bool {
            var descriptorMetadata = stat()
            var pathMetadata = stat()
            let pathProbe = name.withCString {
                fstatat(parentDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW)
            }
            return fstat(descriptor, &descriptorMetadata) == 0
                && LegacyMigrationFingerprint(descriptorMetadata) == expected
                && pathProbe == 0
                && LegacyMigrationFingerprint(pathMetadata) == expected
        }
        guard exactPathFence(
            descriptor: stageFD,
            name: rewriting.payload.stageName,
            expected: ready.payload.stageFingerprint
        ), exactPathFence(
            descriptor: reserveFD,
            name: reserveName,
            expected: reserveFingerprint
        ) else {
            return .failure(.init(reason: "controlSlotChangedAfterRewriteIntent", errno: nil))
        }

        guard rewriteLegacyMigrationStage(data, descriptor: stageFD) else {
            return .failure(.init(reason: "newSnapshotWrite", errno: errno))
        }
        if interruptionHook?("afterNewWALFsync") == true {
            return .failure(.init(reason: "interruptedAfterNewWALFsync", errno: nil))
        }
        let oldData = destinationSnapshot.data ?? Data()
        guard rewriteLegacyMigrationStage(oldData, descriptor: reserveFD) else {
            return .failure(.init(reason: "oldSnapshotWrite", errno: errno))
        }
        if interruptionHook?("afterOldWALFsync") == true {
            return .failure(.init(reason: "interruptedAfterOldWALFsync", errno: nil))
        }
        if let fenceFailure = beforePreparedFence?() { return .failure(fenceFailure) }

        var newMetadata = stat()
        var oldMetadata = stat()
        guard fstat(stageFD, &newMetadata) == 0, fstat(reserveFD, &oldMetadata) == 0 else {
            return .failure(.init(reason: "snapshotStat", errno: errno))
        }
        let newFingerprint = LegacyMigrationFingerprint(newMetadata)
        let oldFingerprint = LegacyMigrationFingerprint(oldMetadata)
        guard newFingerprint.isSecureControlFile,
              oldFingerprint.isSecureControlFile,
              exactPathFence(
                descriptor: stageFD,
                name: rewriting.payload.stageName,
                expected: newFingerprint
              ),
              exactPathFence(
                descriptor: reserveFD,
                name: reserveName,
                expected: oldFingerprint
              ) else {
            return .failure(.init(reason: "controlSlotChangedAfterSnapshotWrite", errno: nil))
        }
        let stageSet = LegacyMigrationStageSet(
            name: rewriting.payload.stageName,
            fingerprint: newFingerprint,
            version: LegacyMigrationVersionEvidence(fingerprint: newFingerprint, data: data),
            reserveName: reserveName,
            reserveFingerprint: oldFingerprint,
            reserveVersion: LegacyMigrationVersionEvidence(fingerprint: oldFingerprint, data: oldData)
        )
        let prepared: LegacyMigrationTransactionState
        switch advanceLegacyMigrationTransaction(
            rewriting,
            phase: .prepared,
            transactionID: transactionID,
            expectedDestination: destinationSnapshot.fingerprint,
            expectedDestinationVersion: destinationSnapshot.versionEvidence,
            stageFingerprint: newFingerprint,
            stageVersion: stageSet.version,
            stageSet: stageSet,
            parentDescriptor: parentDescriptor
        ) {
        case .success(let state): prepared = state
        case .failure(let failure): return .failure(failure)
        }
        if interruptionHook?("afterPreparedMarkerFsync") == true {
            return .failure(.init(reason: "interruptedAfterPreparedMarkerFsync", errno: nil))
        }

        beforeDestinationCommitHook?()
        let isFirstCreation = destinationSnapshot.fingerprint == nil
        let committedStageSet: LegacyMigrationStageSet
        if let expectedDestination = destinationSnapshot.fingerprint,
           let expectedVersion = destinationSnapshot.versionEvidence {
            guard expectedVersion.objectIdentity == expectedDestination.objectIdentity,
                  expectedVersion.metadata == expectedDestination.renameStableMetadata else {
                return .failure(.init(reason: "destinationSnapshotContract", errno: nil))
            }
            let destinationFD = destinationName.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard destinationFD >= 0 else {
                return .failure(.init(reason: "destinationOpen", errno: errno))
            }
            defer { Darwin.close(destinationFD) }
            var openedMetadata = stat()
            var pathMetadata = stat()
            let pathProbe = destinationName.withCString {
                fstatat(parentDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(destinationFD, &openedMetadata) == 0,
                  LegacyMigrationFingerprint(openedMetadata) == expectedDestination,
                  pathProbe == 0,
                  LegacyMigrationFingerprint(pathMetadata) == expectedDestination else {
                return .failure(.init(reason: "destinationChangedBeforeDescriptorCommit", errno: nil))
            }
            // The canonical payload was read once under this same anchored lock epoch. Exact
            // descriptor/path fingerprint equality is the CAS fence; re-reading the full JSON
            // here used to double O(data) work while a ctime-changing same-inode mutation would
            // already fail the fingerprint check above.
            afterDestinationDescriptorFenceHook?()
            if let failure = rewriteLegacyMigrationDestination(
                data,
                descriptor: destinationFD,
                interruptionHook: interruptionHook
            ) {
                return .failure(failure)
            }
            var committedDescriptorMetadata = stat()
            var committedPathMetadata = stat()
            let committedPathProbe = destinationName.withCString {
                fstatat(parentDescriptor, $0, &committedPathMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(destinationFD, &committedDescriptorMetadata) == 0,
                  committedPathProbe == 0 else {
                return .failure(.init(reason: "canonicalPostCommitStat", errno: errno))
            }
            let committedDescriptorFingerprint = LegacyMigrationFingerprint(
                committedDescriptorMetadata
            )
            guard
                  committedDescriptorFingerprint.isRegularSingleLink,
                  committedDescriptorFingerprint.ownerID == UInt32(geteuid()),
                  LegacyMigrationFingerprint(committedPathMetadata)
                    == committedDescriptorFingerprint,
                  committedDescriptorFingerprint.objectIdentity
                    == expectedDestination.objectIdentity else {
                return .failure(.init(reason: "canonicalReplacedAfterDescriptorFence", errno: nil))
            }
            committedStageSet = stageSet
        } else {
            let renameResult = prepared.payload.stageName.withCString { stageLeaf in
                destinationName.withCString { destinationLeaf in
                    renameatx_np(
                        parentDescriptor,
                        stageLeaf,
                        parentDescriptor,
                        destinationLeaf,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameResult == 0 else {
                let code = errno
                return .failure(.init(
                    reason: code == EEXIST ? "destinationAppeared" : "destinationInstall",
                    errno: code
                ))
            }
            if interruptionHook?("afterDestinationNamespaceCommit") == true {
                return .failure(.init(reason: "interruptedAfterDestinationNamespaceCommit", errno: nil))
            }
            // The stage was durable before PREPARED, but after rename recovery must be able to
            // state the stronger invariant directly: the descriptor now naming canonical has
            // crossed fsync and the namespace rename has crossed the parent-directory fsync.
            var installedDescriptorMetadata = stat()
            var installedPathMetadata = stat()
            let installedPathProbe = destinationName.withCString {
                fstatat(parentDescriptor, $0, &installedPathMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard fsync(stageFD) == 0,
                  fstat(stageFD, &installedDescriptorMetadata) == 0,
                  installedPathProbe == 0,
                  LegacyMigrationFingerprint(installedPathMetadata)
                    == LegacyMigrationFingerprint(installedDescriptorMetadata),
                  LegacyMigrationFingerprint(installedDescriptorMetadata).objectIdentity
                    == newFingerprint.objectIdentity,
                  fsync(parentDescriptor) == 0 else {
                return .failure(.init(reason: "destinationDirectoryFsync", errno: errno))
            }
            if interruptionHook?("afterDestinationDirectoryFsync") == true {
                return .failure(.init(reason: "interruptedAfterDestinationDirectoryFsync", errno: nil))
            }
            guard let committedReserveVersion = stageSet.reserveVersion else {
                return .failure(.init(reason: "missingCommittedReserveVersion", errno: nil))
            }
            // v2026.07.20 P0: first creation renames the freshly written stage into the
            // canonical destination and promotes the reserve slot to the next active stage.
            // Its idle marker must therefore bind `oldFingerprint` to the version evidence
            // captured after `oldData` was written. Reusing the pre-write `reserveVersion`
            // produced a self-contradictory marker, so the very next Undo RMW failed closed and
            // left an otherwise committed Trash journal blocking production interaction.
            committedStageSet = LegacyMigrationStageSet(
                name: reserveName,
                fingerprint: oldFingerprint,
                version: committedReserveVersion,
                reserveName: nil,
                reserveFingerprint: nil,
                reserveVersion: nil
            )
        }

        // v2026.07.19 P1 performance fix: the normal writer already owns verified descriptors and
        // has just completed every required fsync/path fence. Running crash recovery here again
        // re-read stage, reserve and canonical in full. Persist the idle generation directly;
        // should this final marker write fail, PREPARED remains the highest valid generation and a
        // later lock epoch performs the conservative recovery path.
        let committed: LegacyMigrationTransactionState
        switch transitionLegacyMigrationToIdle(
            prepared,
            stageSet: committedStageSet,
            parentDescriptor: parentDescriptor
        ) {
        case .success(let state): committed = state
        case .failure(let failure): return .failure(failure)
        }
        if interruptionHook?("afterIdleMarkerFsync") == true {
            return .failure(.init(reason: "interruptedAfterIdleMarkerFsync", errno: nil))
        }
        let io = LegacyMigrationCommitIODiagnostic(
            mode: isFirstCreation ? "first_create" : "existing",
            canonicalSnapshotFullReads: isFirstCreation ? 0 : 1,
            walVerificationFullReads: 0,
            canonicalVerificationFullReads: 0,
            walFullWrites: 2,
            canonicalFullWrites: isFirstCreation ? 0 : 1,
            markerWrites: 3,
            walDataFsyncs: 2,
            canonicalDataFsyncs: 1,
            markerFsyncs: 3,
            parentDirectoryFsyncs: isFirstCreation ? 1 : 0
        )
        ioDiagnosticHook?(io)
        GSYLog.info(
            .trash,
            "undo_history.wal.commit_io transaction_id=\(transactionID.uuidString) "
                + "mode=\(io.mode) bytes=\(data.count) canonical_snapshot_full_reads="
                + "\(io.canonicalSnapshotFullReads) wal_verification_full_reads="
                + "\(io.walVerificationFullReads) canonical_verification_full_reads="
                + "\(io.canonicalVerificationFullReads) wal_full_writes=\(io.walFullWrites) "
                + "canonical_full_writes=\(io.canonicalFullWrites) marker_writes="
                + "\(io.markerWrites) wal_data_fsyncs=\(io.walDataFsyncs) "
                + "canonical_data_fsyncs=\(io.canonicalDataFsyncs) marker_fsyncs="
                + "\(io.markerFsyncs) parent_directory_fsyncs=\(io.parentDirectoryFsyncs) "
                + "bootstrap_or_reserve_io_excluded=true final_generation="
                + "\(committed.payload.generation)"
        )
        return .success(committed)
    }

    nonisolated private static func legacyMigrationChecksum<T: Encodable>(
        _ value: T
    ) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            GSYLog.error(.trash, "undo_history.legacy_migration.marker encode_failed")
            return nil
        }
    }

    nonisolated private static func encodedLegacyMigrationRecord<T: Encodable>(
        _ value: T
    ) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch {
            GSYLog.error(.trash, "undo_history.legacy_migration.marker encode_failed")
            return nil
        }
    }

    nonisolated private static func secureLegacyMigrationControlMetadata(
        _ metadata: stat,
        maximumBytes: Int64
    ) -> Bool {
        let permissions = metadata.st_mode & mode_t(0o777)
        return metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_uid == geteuid()
            && permissions == mode_t(S_IRUSR | S_IWUSR)
            && metadata.st_size >= 0
            && metadata.st_size <= maximumBytes
    }

    nonisolated private static func probeLegacyMigrationEntry(
        parentDescriptor: Int32,
        name: String
    ) -> LegacyMigrationEntryProbe {
        var metadata = stat()
        errno = 0
        let result = name.withCString {
            fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return .present(LegacyMigrationFingerprint(metadata)) }
        let code = errno
        if code == ENOENT { return .absent }
        return .failed(errno: code)
    }

    /// Reads one bounded pathname through an anchored, no-follow descriptor and proves the path
    /// still names the same full pre-read version. Recovery calls this only after an object-identity
    /// classification, so a foreign/oversized entry is never materialized or modified.
    nonisolated private static func readLegacyMigrationEntry(
        parentDescriptor: Int32,
        name: String,
        maximumBytes: Int64 = Int64(maximumStoreBytes)
    ) -> LegacyMigrationEntryReadResult {
        let descriptor = name.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return errno == ENOENT
                ? .absent
                : .failed(reason: "open", errno: errno)
        }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            return .failed(reason: "stat", errno: errno)
        }
        let openedFingerprint = LegacyMigrationFingerprint(openedMetadata)
        guard openedFingerprint.isRegularSingleLink else {
            return .failed(reason: "notRegularSingleLink", errno: nil)
        }
        guard openedFingerprint.byteCount <= maximumBytes else {
            return .failed(reason: "byteLimit", errno: EFBIG)
        }
        let data: Data
        switch readFrozenLegacyData(
            descriptor: descriptor,
            expectedByteCount: Int(openedFingerprint.byteCount)
        ) {
        case .success(let bytes): data = bytes
        case .failed(let code): return .failed(reason: "read", errno: code)
        }

        var postReadMetadata = stat()
        var finalPathMetadata = stat()
        let finalPathProbe = name.withCString {
            fstatat(parentDescriptor, $0, &finalPathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &postReadMetadata) == 0,
              LegacyMigrationFingerprint(postReadMetadata) == openedFingerprint,
              finalPathProbe == 0,
              LegacyMigrationFingerprint(finalPathMetadata) == openedFingerprint else {
            return .failed(reason: "versionChanged", errno: nil)
        }
        return .present(fingerprint: openedFingerprint, data: data)
    }

    nonisolated private static func readLegacyMigrationMarker(
        slot: Int,
        parentDescriptor: Int32,
        destinationName: String
    ) -> LegacyMigrationMarkerReadResult {
        let controlNames = legacyMigrationControlNames(destinationName: destinationName)
        guard controlNames.markers.indices.contains(slot) else {
            return .invalid(reason: "markerSlot")
        }
        let name = controlNames.markers[slot]
        let descriptor = name.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .absent : .invalid(reason: "markerOpen")
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              secureLegacyMigrationControlMetadata(
                metadata,
                maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
              ) else {
            return .invalid(reason: "markerMetadata")
        }
        let openedFingerprint = LegacyMigrationFingerprint(metadata)
        let identity = openedFingerprint.objectIdentity
        guard metadata.st_size > 0 else {
            return .torn(identity: identity, reason: "empty")
        }
        let data: Data
        switch readFrozenLegacyData(
            descriptor: descriptor,
            expectedByteCount: Int(metadata.st_size)
        ) {
        case .success(let bytes):
            data = bytes
        case .failed:
            return .torn(identity: identity, reason: "read")
        }
        var postReadMetadata = stat()
        var finalPathMetadata = stat()
        let finalPathProbe = name.withCString {
            fstatat(parentDescriptor, $0, &finalPathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &postReadMetadata) == 0,
              LegacyMigrationFingerprint(postReadMetadata) == openedFingerprint,
              finalPathProbe == 0,
              LegacyMigrationFingerprint(finalPathMetadata) == openedFingerprint else {
            return .invalid(reason: "markerVersionChanged")
        }
        let record: LegacyMigrationTransactionRecord
        do {
            record = try JSONDecoder().decode(LegacyMigrationTransactionRecord.self, from: data)
        } catch {
            return .torn(identity: identity, reason: "decode")
        }
        let material = LegacyMigrationTransactionChecksumMaterial(
            slot: record.slot,
            markerIdentity: record.markerIdentity,
            payload: record.payload
        )
        guard legacyMigrationChecksum(material) == record.checksum else {
            return .torn(identity: identity, reason: "checksum")
        }
        guard record.markerIdentity.hasSameStableIdentityIgnoringMountDevice(as: identity),
              let rebasedPayload = record.payload.rebasedFromPersistedMount(
                device: record.markerIdentity.device,
                to: identity.device
              ) else {
            return .invalid(reason: "foreignMarkerIdentity")
        }
        guard record.slot == slot,
              record.payload.protocolVersion
                == LegacyMigrationTransactionPayload.protocolVersion,
              record.payload.destinationName == destinationName,
              controlNames.stages.contains(record.payload.stageName),
              record.payload.reserveStageName.map(controlNames.stages.contains) ?? true
        else {
            return .invalid(reason: "markerContract")
        }
        return .valid(ValidatedLegacyMigrationMarker(
            record: record,
            liveMarkerIdentity: identity,
            rebasedPayload: rebasedPayload
        ))
    }

    nonisolated private static func loadLegacyMigrationTransactionState(
        parentDescriptor: Int32,
        destinationName: String
    ) -> LegacyMigrationControlLoadResult {
        let markerCount = legacyMigrationControlNames(destinationName: destinationName).markers.count
        let reads = (0..<markerCount).map {
            readLegacyMigrationMarker(
                slot: $0,
                parentDescriptor: parentDescriptor,
                destinationName: destinationName
            )
        }
        for read in reads {
            if case .invalid(let reason) = read {
                return .rejected(reason: reason, errno: nil)
            }
        }
        let validMarkers: [ValidatedLegacyMigrationMarker] = reads.compactMap {
            guard case .valid(let marker) = $0 else { return nil }
            return marker
        }
        guard !validMarkers.isEmpty else {
            let slotsCanBeInitialized = reads.allSatisfy { read in
                switch read {
                case .absent, .torn: return true
                case .invalid, .valid: return false
                }
            }
            if slotsCanBeInitialized {
                // Fixed control names are reserved by this storage protocol. Initialization may
                // have crashed after any O_EXCL create; `ensure...` adopts only exact current-uid,
                // 0600, regular single-link empty slots or a self-bound bootstrap record.
                return .absent
            }
            return .rejected(reason: "noValidMarkerGeneration", errno: nil)
        }

        if validMarkers.count == 2,
           validMarkers[0].rebasedPayload.generation
            == validMarkers[1].rebasedPayload.generation {
            return .rejected(reason: "conflictingMarkerGeneration", errno: nil)
        }
        let selected = validMarkers.max {
            $0.rebasedPayload.generation < $1.rebasedPayload.generation
        }!
        let payload = selected.rebasedPayload

        func actualIdentity(for slot: Int) -> LegacyMigrationObjectIdentity? {
            switch reads[slot] {
            case .valid(let marker): return marker.liveMarkerIdentity
            case .torn(let identity, _): return identity
            case .absent, .invalid: return nil
            }
        }
        let actual0 = actualIdentity(for: 0)
        let actual1 = actualIdentity(for: 1)
        var parentMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0,
              let actual0, let actual1,
              actual0.device == actual1.device,
              actual0.device == UInt64(bitPattern: Int64(parentMetadata.st_dev)),
              actual0 == payload.marker0Identity,
              actual1 == payload.marker1Identity else {
            return .rejected(reason: "foreignMarkerIdentity", errno: nil)
        }
        if validMarkers.count == 2 {
            for marker in validMarkers {
                guard marker.rebasedPayload.marker0Identity == actual0,
                      marker.rebasedPayload.marker1Identity == actual1 else {
                    return .rejected(reason: "markerIdentityDisagreement", errno: nil)
                }
            }
        }
        let activeMarkerIdentity = selected.record.slot == 0 ? actual0 : actual1
        return .loaded(LegacyMigrationTransactionState(
            activeSlot: selected.record.slot,
            activeMarkerIdentity: activeMarkerIdentity,
            payload: payload
        ))
    }

    nonisolated private static func ensureLegacyMigrationTransactionState(
        _ existing: LegacyMigrationTransactionState?,
        parentDescriptor: Int32,
        destinationName: String,
        interruptionHook: (@Sendable (String) -> Bool)?
    ) -> LegacyMigrationControlLoadResult {
        if let existing { return .loaded(existing) }

        let controlNames = legacyMigrationControlNames(destinationName: destinationName)
        let stage0Name = controlNames.stages[0]
        let stage1Name = controlNames.stages[1]
        let marker0Name = controlNames.markers[0]
        let marker1Name = controlNames.markers[1]

        func openOrCreateReservedSlot(
            _ name: String,
            maximumBytes: Int64
        ) -> (descriptor: Int32, created: Bool)? {
            var created = false
            var descriptor = name.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if descriptor < 0, errno == ENOENT {
                descriptor = name.withCString {
                    openat(
                        parentDescriptor,
                        $0,
                        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
                if descriptor >= 0 {
                    created = true
                }
            }
            guard descriptor >= 0 else { return nil }
            if created,
               (fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) != 0
                    || fsync(descriptor) != 0
                    || fsync(parentDescriptor) != 0) {
                let code = errno
                Darwin.close(descriptor)
                errno = code
                return nil
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  secureLegacyMigrationControlMetadata(
                    metadata,
                    maximumBytes: maximumBytes
                  ) else {
                Darwin.close(descriptor)
                errno = EPERM
                return nil
            }
            return (descriptor, created)
        }

        guard let stage0Slot = openOrCreateReservedSlot(
            stage0Name,
            maximumBytes: Int64(maximumStoreBytes)
        ) else {
            return .rejected(reason: "stage0OpenOrCreate", errno: errno)
        }
        let stage0FD = stage0Slot.descriptor
        defer { Darwin.close(stage0FD) }
        if stage0Slot.created, interruptionHook?("afterStage0Create") == true {
            return .rejected(reason: "interruptedAfterStage0Create", errno: nil)
        }
        guard let stage1Slot = openOrCreateReservedSlot(
            stage1Name,
            maximumBytes: Int64(maximumStoreBytes)
        ) else {
            return .rejected(reason: "stage1OpenOrCreate", errno: errno)
        }
        let stage1FD = stage1Slot.descriptor
        defer { Darwin.close(stage1FD) }
        if stage1Slot.created, interruptionHook?("afterStage1Create") == true {
            return .rejected(reason: "interruptedAfterStage1Create", errno: nil)
        }
        guard let marker0Slot = openOrCreateReservedSlot(
            marker0Name,
            maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
        ) else {
            return .rejected(reason: "marker0OpenOrCreate", errno: errno)
        }
        let marker0FD = marker0Slot.descriptor
        defer { Darwin.close(marker0FD) }
        if marker0Slot.created, interruptionHook?("afterMarker0Create") == true {
            return .rejected(reason: "interruptedAfterMarker0Create", errno: nil)
        }
        guard let marker1Slot = openOrCreateReservedSlot(
            marker1Name,
            maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
        ) else {
            return .rejected(reason: "marker1OpenOrCreate", errno: errno)
        }
        let marker1FD = marker1Slot.descriptor
        defer { Darwin.close(marker1FD) }
        if marker1Slot.created, interruptionHook?("afterMarker1Create") == true {
            return .rejected(reason: "interruptedAfterMarker1Create", errno: nil)
        }

        var stage0Metadata = stat()
        var stage1Metadata = stat()
        var marker0Metadata = stat()
        var marker1Metadata = stat()
        guard fstat(stage0FD, &stage0Metadata) == 0,
              fstat(stage1FD, &stage1Metadata) == 0,
              fstat(marker0FD, &marker0Metadata) == 0,
              fstat(marker1FD, &marker1Metadata) == 0,
              secureLegacyMigrationControlMetadata(
                stage0Metadata,
                maximumBytes: Int64(maximumStoreBytes)
              ), secureLegacyMigrationControlMetadata(
                stage1Metadata,
                maximumBytes: Int64(maximumStoreBytes)
              ), secureLegacyMigrationControlMetadata(
                marker0Metadata,
                maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
              ), secureLegacyMigrationControlMetadata(
                marker1Metadata,
                maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
              ) else {
            return .rejected(reason: "transactionFileMetadata", errno: errno)
        }
        guard stage1Metadata.st_size == 0 else {
            return .rejected(reason: "foreignBootstrapReserveContent", errno: nil)
        }
        let bootstrapPayload = LegacyMigrationBootstrapStagePayload(
            protocolVersion: LegacyMigrationTransactionPayload.protocolVersion,
            destinationName: destinationName,
            stageName: stage0Name,
            stageIdentity: LegacyMigrationObjectIdentity(stage0Metadata),
            reserveStageName: stage1Name,
            reserveStageIdentity: LegacyMigrationObjectIdentity(stage1Metadata),
            marker0Identity: LegacyMigrationObjectIdentity(marker0Metadata),
            marker1Identity: LegacyMigrationObjectIdentity(marker1Metadata)
        )
        guard let bootstrapChecksum = legacyMigrationChecksum(bootstrapPayload),
              let bootstrapData = encodedLegacyMigrationRecord(
                LegacyMigrationBootstrapStageRecord(
                    payload: bootstrapPayload,
                    checksum: bootstrapChecksum
                )
              ), bootstrapData.count <= maximumLegacyMigrationMarkerBytes else {
            return .rejected(reason: "bootstrapEncode", errno: EINVAL)
        }

        if stage0Metadata.st_size == 0 {
            guard marker0Metadata.st_size == 0, marker1Metadata.st_size == 0 else {
                return .rejected(reason: "unboundBootstrapMarkerContent", errno: nil)
            }
        } else {
            let existingBootstrapData: Data
            switch readFrozenLegacyData(
                descriptor: stage0FD,
                expectedByteCount: Int(stage0Metadata.st_size)
            ) {
            case .success(let data): existingBootstrapData = data
            case .failed(let code):
                return .rejected(reason: "bootstrapStageRead", errno: code)
            }
            guard let existingRecord = try? JSONDecoder().decode(
                LegacyMigrationBootstrapStageRecord.self,
                from: existingBootstrapData
            ), legacyMigrationChecksum(existingRecord.payload) == existingRecord.checksum,
                  let rebasedPayload = existingRecord.payload.rebasedFromPersistedMount(
                    device: existingRecord.payload.stageIdentity.device,
                    to: bootstrapPayload.stageIdentity.device
                  ), rebasedPayload == bootstrapPayload else {
                return .rejected(reason: "foreignBootstrapStageContent", errno: nil)
            }
        }

        guard rewriteLegacyMigrationStage(bootstrapData, descriptor: stage0FD),
              fsync(stage1FD) == 0,
              fsync(parentDescriptor) == 0,
              fstat(stage0FD, &stage0Metadata) == 0,
              fstat(stage1FD, &stage1Metadata) == 0 else {
            return .rejected(reason: "bootstrapPersist", errno: errno)
        }
        if interruptionHook?("afterBootstrapStageFsync") == true {
            return .rejected(reason: "interruptedAfterBootstrapStageFsync", errno: nil)
        }
        let stage0Fingerprint = LegacyMigrationFingerprint(stage0Metadata)
        let stage1Fingerprint = LegacyMigrationFingerprint(stage1Metadata)
        let payload = LegacyMigrationTransactionPayload(
            protocolVersion: LegacyMigrationTransactionPayload.protocolVersion,
            generation: 1,
            phase: .idle,
            transactionID: nil,
            destinationName: destinationName,
            stageName: stage0Name,
            expectedDestination: nil,
            expectedDestinationVersion: nil,
            stageFingerprint: stage0Fingerprint,
            stageVersion: LegacyMigrationVersionEvidence(
                fingerprint: stage0Fingerprint,
                data: bootstrapData
            ),
            reserveStageName: stage1Name,
            reserveStageFingerprint: stage1Fingerprint,
            reserveStageVersion: LegacyMigrationVersionEvidence(
                fingerprint: stage1Fingerprint,
                data: Data()
            ),
            marker0Identity: LegacyMigrationObjectIdentity(marker0Metadata),
            marker1Identity: LegacyMigrationObjectIdentity(marker1Metadata)
        )
        guard writeLegacyMigrationMarkerRecord(
            slot: 0,
            markerDescriptor: marker0FD,
            markerIdentity: LegacyMigrationObjectIdentity(marker0Metadata),
            payload: payload
        ) else {
            return .rejected(reason: "marker0Persist", errno: errno)
        }
        var persistedMarker0Metadata = stat()
        var persistedMarker0PathMetadata = stat()
        let marker0PathProbe = marker0Name.withCString {
            fstatat(parentDescriptor, $0, &persistedMarker0PathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(marker0FD, &persistedMarker0Metadata) == 0,
              LegacyMigrationObjectIdentity(persistedMarker0Metadata)
                == payload.marker0Identity,
              marker0PathProbe == 0,
              LegacyMigrationFingerprint(persistedMarker0PathMetadata)
                == LegacyMigrationFingerprint(persistedMarker0Metadata),
              fsync(parentDescriptor) == 0 else {
            return .rejected(reason: "marker0PathFence", errno: errno)
        }
        GSYLog.info(
            .trash,
            "undo_history.legacy_migration.transaction event=bootstrap generation=1 "
                + "phase=idle active_slot=0 transaction_id=none"
        )
        if interruptionHook?("afterBootstrapMarkerFsync") == true {
            return .rejected(reason: "interruptedAfterBootstrapMarkerFsync", errno: nil)
        }
        return .loaded(LegacyMigrationTransactionState(
            activeSlot: 0,
            activeMarkerIdentity: LegacyMigrationObjectIdentity(marker0Metadata),
            payload: payload
        ))
    }

    nonisolated private static func writeLegacyMigrationMarkerRecord(
        slot: Int,
        markerDescriptor: Int32,
        markerIdentity: LegacyMigrationObjectIdentity,
        payload: LegacyMigrationTransactionPayload
    ) -> Bool {
        let material = LegacyMigrationTransactionChecksumMaterial(
            slot: slot,
            markerIdentity: markerIdentity,
            payload: payload
        )
        guard let checksum = legacyMigrationChecksum(material),
              let data = encodedLegacyMigrationRecord(LegacyMigrationTransactionRecord(
                slot: slot,
                markerIdentity: markerIdentity,
                payload: payload,
                checksum: checksum
              )), data.count <= maximumLegacyMigrationMarkerBytes else {
            errno = EINVAL
            return false
        }
        return rewriteLegacyMigrationStage(data, descriptor: markerDescriptor)
    }

    nonisolated private static func advanceLegacyMigrationTransaction(
        _ current: LegacyMigrationTransactionState,
        phase: LegacyMigrationTransactionPhase,
        transactionID: UUID?,
        expectedDestination: LegacyMigrationFingerprint?,
        expectedDestinationVersion: LegacyMigrationVersionEvidence?,
        stageFingerprint: LegacyMigrationFingerprint,
        stageVersion: LegacyMigrationVersionEvidence,
        stageSet: LegacyMigrationStageSet? = nil,
        parentDescriptor: Int32
    ) -> Result<LegacyMigrationTransactionState, LegacyMigrationTransactionFailure> {
        guard current.payload.generation < UInt64.max else {
            return .failure(.init(reason: "markerGenerationOverflow", errno: nil))
        }
        let nextSlot = current.activeSlot == 0 ? 1 : 0
        let expectedNextIdentity = nextSlot == 0
            ? current.payload.marker0Identity
            : current.payload.marker1Identity
        let markerNames = legacyMigrationControlNames(
            destinationName: current.payload.destinationName
        ).markers
        let markerFD = markerNames[nextSlot].withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard markerFD >= 0 else {
            return .failure(.init(reason: "markerOpen", errno: errno))
        }
        var openedMarkerMetadata = stat()
        guard fstat(markerFD, &openedMarkerMetadata) == 0,
              secureLegacyMigrationControlMetadata(
                openedMarkerMetadata,
                maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
              ), LegacyMigrationObjectIdentity(openedMarkerMetadata) == expectedNextIdentity else {
            Darwin.close(markerFD)
            return .failure(.init(reason: "foreignMarkerIdentity", errno: nil))
        }
        defer { Darwin.close(markerFD) }
        var markerMetadata = stat()
        guard fstat(markerFD, &markerMetadata) == 0,
              secureLegacyMigrationControlMetadata(
                markerMetadata,
                maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
              ) else {
            return .failure(.init(reason: "markerMetadata", errno: errno))
        }
        let markerIdentity = LegacyMigrationObjectIdentity(markerMetadata)
        let marker0Identity = nextSlot == 0
            ? markerIdentity
            : current.payload.marker0Identity
        let marker1Identity = nextSlot == 1
            ? markerIdentity
            : current.payload.marker1Identity
        let nextPayload = LegacyMigrationTransactionPayload(
            protocolVersion: LegacyMigrationTransactionPayload.protocolVersion,
            generation: current.payload.generation + 1,
            phase: phase,
            transactionID: transactionID,
            destinationName: current.payload.destinationName,
            stageName: stageSet?.name ?? current.payload.stageName,
            expectedDestination: expectedDestination,
            expectedDestinationVersion: expectedDestinationVersion,
            stageFingerprint: stageSet?.fingerprint ?? stageFingerprint,
            stageVersion: stageSet?.version ?? stageVersion,
            reserveStageName: stageSet == nil
                ? current.payload.reserveStageName
                : stageSet?.reserveName,
            reserveStageFingerprint: stageSet == nil
                ? current.payload.reserveStageFingerprint
                : stageSet?.reserveFingerprint,
            reserveStageVersion: stageSet == nil
                ? current.payload.reserveStageVersion
                : stageSet?.reserveVersion,
            marker0Identity: marker0Identity,
            marker1Identity: marker1Identity
        )
        guard writeLegacyMigrationMarkerRecord(
            slot: nextSlot,
            markerDescriptor: markerFD,
            markerIdentity: markerIdentity,
            payload: nextPayload
        ) else {
            return .failure(.init(reason: "markerPersist", errno: errno))
        }
        var persistedMarkerMetadata = stat()
        var persistedMarkerPathMetadata = stat()
        let markerPathProbe = markerNames[nextSlot].withCString {
            fstatat(parentDescriptor, $0, &persistedMarkerPathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(markerFD, &persistedMarkerMetadata) == 0,
              secureLegacyMigrationControlMetadata(
                persistedMarkerMetadata,
                maximumBytes: Int64(maximumLegacyMigrationMarkerBytes)
              ), markerPathProbe == 0,
              LegacyMigrationFingerprint(persistedMarkerPathMetadata)
                == LegacyMigrationFingerprint(persistedMarkerMetadata) else {
            return .failure(.init(reason: "markerPathFence", errno: errno))
        }
        // v2026.07.19 P1 performance fix: marker names are created with O_EXCL and their parent
        // directory is fsynced during bootstrap. Advancing a generation mutates only that already
        // durable inode; fsync(markerFD) above is the commit boundary, while another directory
        // fsync per phase added three metadata flushes to every ordinary history write.
        GSYLog.info(
            .trash,
            "undo_history.legacy_migration.transaction event=advance generation="
                + "\(nextPayload.generation) phase=\(nextPayload.phase.rawValue) active_slot="
                + "\(nextSlot) transaction_id="
                + "\(nextPayload.transactionID?.uuidString ?? "none")"
        )
        return .success(LegacyMigrationTransactionState(
            activeSlot: nextSlot,
            activeMarkerIdentity: markerIdentity,
            payload: nextPayload
        ))
    }

    nonisolated private static func openLegacyMigrationStage(
        parentDescriptor: Int32,
        destinationName: String,
        stageName: String,
        expected: LegacyMigrationFingerprint,
        expectedVersion: LegacyMigrationVersionEvidence
    ) -> Result<Int32, LegacyMigrationTransactionFailure> {
        guard legacyMigrationControlNames(destinationName: destinationName)
            .stages.contains(stageName) else {
            return .failure(.init(reason: "invalidStageName", errno: nil))
        }
        let descriptor = stageName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return .failure(.init(reason: "stageOpen", errno: errno))
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              secureLegacyMigrationControlMetadata(
                metadata,
                maximumBytes: Int64(maximumStoreBytes)
              ) else {
            Darwin.close(descriptor)
            return .failure(.init(reason: "stageMetadata", errno: nil))
        }
        let openedFingerprint = LegacyMigrationFingerprint(metadata)
        guard openedFingerprint == expected,
              expectedVersion.objectIdentity == openedFingerprint.objectIdentity,
              expectedVersion.metadata == openedFingerprint.renameStableMetadata else {
            Darwin.close(descriptor)
            return .failure(.init(reason: "foreignStageVersion", errno: nil))
        }
        var finalPathMetadata = stat()
        let finalPathProbe = stageName.withCString {
            fstatat(parentDescriptor, $0, &finalPathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        // v2026.07.19 P1 performance fix: an exact Darwin fingerprint includes inode identity,
        // size, mtime and ctime. A same-inode content mutation necessarily changes ctime, which a
        // non-privileged peer cannot restore. Re-reading both 8 MiB slots before immediately
        // overwriting them added two O(data) passes without strengthening this CAS fence.
        guard finalPathProbe == 0,
              LegacyMigrationFingerprint(finalPathMetadata) == openedFingerprint else {
            Darwin.close(descriptor)
            return .failure(.init(reason: "foreignStageVersion", errno: nil))
        }
        return .success(descriptor)
    }

    /// Descriptor-bound rewrite of an already-authorized stage/marker inode. The previous marker
    /// generation is advanced to `rewritingStage` before this function is called, so a crash after
    /// truncate never leaves the highest valid marker pretending the old stage version survived.
    nonisolated private static func rewriteLegacyMigrationStage(
        _ data: Data,
        descriptor: Int32
    ) -> Bool {
        guard ftruncate(descriptor, 0) == 0 else { return false }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = pwrite(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { errno = EIO; return false }
                offset += count
            }
            return true
        }
        return wroteAll && fsync(descriptor) == 0
    }

    /// Existing canonical JSON is never replaced through the namespace. A fully durable WAL is
    /// already PREPARED when this descriptor-bound rewrite begins. One final fsync keeps the I/O
    /// count constant; crash-torn bytes are not guessed recoverable and leave both WAL snapshots.
    nonisolated private static func rewriteLegacyMigrationDestination(
        _ data: Data,
        descriptor: Int32,
        interruptionHook: (@Sendable (String) -> Bool)?
    ) -> LegacyMigrationTransactionFailure? {
        guard ftruncate(descriptor, 0) == 0 else {
            return .init(reason: "destinationTruncate", errno: errno)
        }
        if interruptionHook?("afterDestinationTruncate") == true {
            return .init(reason: "interruptedAfterDestinationTruncate", errno: nil)
        }
        // Deterministic crash fixture only. Production passes no interruption hook and therefore
        // takes the normal write loop below. The prefix proves recovery never treats "new prefix"
        // as a committed canonical version.
        if data.count > 1,
           interruptionHook?("afterDestinationPartialWrite") == true {
            let prefixCount = max(1, min(data.count / 2, 64 * 1_024))
            let wrotePrefix = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < prefixCount {
                    let count = pwrite(
                        descriptor,
                        base.advanced(by: offset),
                        prefixCount - offset,
                        off_t(offset)
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    guard count > 0 else { errno = EIO; return false }
                    offset += count
                }
                return true
            }
            guard wrotePrefix else {
                return .init(reason: "destinationPartialWrite", errno: errno)
            }
            return .init(reason: "interruptedAfterDestinationPartialWrite", errno: nil)
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = pwrite(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { errno = EIO; return false }
                offset += count
            }
            return true
        }
        guard wroteAll else {
            return .init(reason: "destinationWrite", errno: errno)
        }
        if interruptionHook?("afterDestinationWrite") == true {
            return .init(reason: "interruptedAfterDestinationWrite", errno: nil)
        }
        guard fsync(descriptor) == 0 else {
            return .init(reason: "destinationFsync", errno: errno)
        }
        if interruptionHook?("afterDestinationFsync") == true {
            return .init(reason: "interruptedAfterDestinationFsync", errno: nil)
        }
        return nil
    }

    nonisolated private static func transitionLegacyMigrationToIdle(
        _ current: LegacyMigrationTransactionState,
        stageSet: LegacyMigrationStageSet,
        parentDescriptor: Int32
    ) -> Result<LegacyMigrationTransactionState, LegacyMigrationTransactionFailure> {
        advanceLegacyMigrationTransaction(
            current,
            phase: .idle,
            transactionID: nil,
            expectedDestination: nil,
            expectedDestinationVersion: nil,
            stageFingerprint: stageSet.fingerprint,
            stageVersion: stageSet.version,
            stageSet: stageSet,
            parentDescriptor: parentDescriptor
        )
    }

    /// Replenishes the fixed stage slot consumed by a prior first-create. The allocation intent is
    /// durable before O_EXCL. Recovery may adopt only an empty 0600/current-uid/single-link file at
    /// that one reserved name; non-empty or wrong-identity entries are never truncated or removed.
    nonisolated private static func ensureLegacyMigrationReserveStage(
        _ current: LegacyMigrationTransactionState,
        parentDescriptor: Int32,
        interruptionHook: (@Sendable (String) -> Bool)?
    ) -> Result<LegacyMigrationTransactionState, LegacyMigrationTransactionFailure> {
        if current.payload.reserveStageName != nil { return .success(current) }
        guard current.payload.phase == .idle,
              let reserveName = legacyMigrationControlNames(
                destinationName: current.payload.destinationName
              ).stages.first(where: {
                $0 != current.payload.stageName
              }) else {
            return .failure(.init(reason: "reserveAllocationContract", errno: nil))
        }
        let allocatingStageSet = LegacyMigrationStageSet(
            name: current.payload.stageName,
            fingerprint: current.payload.stageFingerprint,
            version: current.payload.stageVersion,
            reserveName: reserveName,
            reserveFingerprint: nil,
            reserveVersion: nil
        )
        let allocating: LegacyMigrationTransactionState
        switch advanceLegacyMigrationTransaction(
            current,
            phase: .allocatingReserve,
            transactionID: UUID(),
            expectedDestination: nil,
            expectedDestinationVersion: nil,
            stageFingerprint: current.payload.stageFingerprint,
            stageVersion: current.payload.stageVersion,
            stageSet: allocatingStageSet,
            parentDescriptor: parentDescriptor
        ) {
        case .success(let state): allocating = state
        case .failure(let failure): return .failure(failure)
        }
        if interruptionHook?("afterReserveIntentFsync") == true {
            return .failure(.init(reason: "interruptedAfterReserveIntentFsync", errno: nil))
        }
        return completeLegacyMigrationReserveAllocation(
            allocating,
            parentDescriptor: parentDescriptor,
            interruptionHook: interruptionHook
        )
    }

    nonisolated private static func completeLegacyMigrationReserveAllocation(
        _ current: LegacyMigrationTransactionState,
        parentDescriptor: Int32,
        interruptionHook: (@Sendable (String) -> Bool)?
    ) -> Result<LegacyMigrationTransactionState, LegacyMigrationTransactionFailure> {
        let payload = current.payload
        guard payload.phase == .allocatingReserve,
              payload.transactionID != nil,
              let reserveName = payload.reserveStageName,
              payload.reserveStageFingerprint == nil,
              payload.reserveStageVersion == nil,
              reserveName != payload.stageName,
              legacyMigrationControlNames(destinationName: payload.destinationName)
                .stages.contains(reserveName) else {
            return .failure(.init(reason: "reserveAllocationContract", errno: nil))
        }
        guard case .success(let activeFingerprint) = verifyLegacyMigrationEntryVersion(
            parentDescriptor: parentDescriptor,
            name: payload.stageName,
            expectedFullFingerprint: payload.stageFingerprint,
            expectedVersion: payload.stageVersion,
            requireSecureControlFile: true
        ) else {
            return .failure(.init(reason: "reserveAllocationActiveStage", errno: nil))
        }

        var reserveFD = reserveName.withCString {
            openat(parentDescriptor, $0, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        var created = false
        if reserveFD < 0, errno == ENOENT {
            reserveFD = reserveName.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            created = reserveFD >= 0
        }
        guard reserveFD >= 0 else {
            return .failure(.init(reason: "reserveAllocationOpenOrCreate", errno: errno))
        }
        defer { Darwin.close(reserveFD) }
        if created {
            guard fchmod(reserveFD, mode_t(S_IRUSR | S_IWUSR)) == 0,
                  fsync(reserveFD) == 0,
                  fsync(parentDescriptor) == 0 else {
                return .failure(.init(reason: "reserveAllocationPersist", errno: errno))
            }
        }
        var reserveMetadata = stat()
        guard fstat(reserveFD, &reserveMetadata) == 0,
              secureLegacyMigrationControlMetadata(
                reserveMetadata,
                maximumBytes: Int64(maximumStoreBytes)
              ), reserveMetadata.st_size == 0 else {
            return .failure(.init(reason: "foreignReserveAllocation", errno: nil))
        }
        var reservePathMetadata = stat()
        let reservePathProbe = reserveName.withCString {
            fstatat(parentDescriptor, $0, &reservePathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard reservePathProbe == 0,
              LegacyMigrationFingerprint(reservePathMetadata)
                == LegacyMigrationFingerprint(reserveMetadata) else {
            return .failure(.init(reason: "reserveAllocationPathFence", errno: nil))
        }
        if created, interruptionHook?("afterReserveCreateFsync") == true {
            return .failure(.init(reason: "interruptedAfterReserveCreateFsync", errno: nil))
        }

        let reserveFingerprint = LegacyMigrationFingerprint(reserveMetadata)
        let stageSet = LegacyMigrationStageSet(
            name: payload.stageName,
            fingerprint: activeFingerprint,
            version: payload.stageVersion,
            reserveName: reserveName,
            reserveFingerprint: reserveFingerprint,
            reserveVersion: LegacyMigrationVersionEvidence(
                fingerprint: reserveFingerprint,
                data: Data()
            )
        )
        let idle: LegacyMigrationTransactionState
        switch transitionLegacyMigrationToIdle(
            current,
            stageSet: stageSet,
            parentDescriptor: parentDescriptor
        ) {
        case .success(let state): idle = state
        case .failure(let failure): return .failure(failure)
        }
        if interruptionHook?("afterReserveMarkerFsync") == true {
            return .failure(.init(reason: "interruptedAfterReserveMarkerFsync", errno: nil))
        }
        return .success(idle)
    }

    nonisolated private static func validateLegacyMigrationReserveStage(
        _ payload: LegacyMigrationTransactionPayload,
        parentDescriptor: Int32
    ) -> LegacyMigrationTransactionFailure? {
        guard let reserveName = payload.reserveStageName else {
            return payload.reserveStageFingerprint == nil
                    && payload.reserveStageVersion == nil
                ? nil
                : .init(reason: "reserveStageContract", errno: nil)
        }
        guard reserveName != payload.stageName,
              legacyMigrationControlNames(destinationName: payload.destinationName)
                .stages.contains(reserveName),
              let expected = payload.reserveStageFingerprint,
              let expectedVersion = payload.reserveStageVersion else {
            return .init(reason: "reserveStageContract", errno: nil)
        }
        switch readLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: reserveName
        ) {
        case .present(let current, let data)
            where current == expected
                && current.isSecureControlFile
                && LegacyMigrationVersionEvidence(
                    fingerprint: current,
                    data: data
                ) == expectedVersion:
            return nil
        case .failed(_, let code):
            return .init(reason: "reserveStageProbe", errno: code)
        case .absent, .present:
            return .init(reason: "foreignReserveStageVersion", errno: nil)
        }
    }

    nonisolated private static func verifyLegacyMigrationEntryVersion(
        parentDescriptor: Int32,
        name: String,
        expectedFullFingerprint: LegacyMigrationFingerprint?,
        expectedVersion: LegacyMigrationVersionEvidence,
        requireSecureControlFile: Bool
    ) -> Result<LegacyMigrationFingerprint, LegacyMigrationTransactionFailure> {
        switch readLegacyMigrationEntry(parentDescriptor: parentDescriptor, name: name) {
        case .absent:
            return .failure(.init(reason: "entryAbsent", errno: ENOENT))
        case .failed(let reason, let code):
            return .failure(.init(reason: "entry\(reason.capitalized)", errno: code))
        case .present(let fingerprint, let data):
            guard expectedFullFingerprint.map({ $0 == fingerprint }) ?? true,
                  (!requireSecureControlFile || fingerprint.isSecureControlFile),
                  LegacyMigrationVersionEvidence(
                    fingerprint: fingerprint,
                    data: data
                  ) == expectedVersion else {
                return .failure(.init(reason: "entryVersionMismatch", errno: nil))
            }
            return .success(fingerprint)
        }
    }

    /// Makes already-observed exact bytes a durable recovery fact. Visibility through the page
    /// cache is not commit evidence: after a crash at `afterDestinationWrite`, recovery may see the
    /// complete new JSON even though the write never crossed fsync. Re-open through the anchored
    /// parent descriptor, prove the same inode/full stat before and after fsync, and retain PREPARED
    /// on every failure.
    nonisolated private static func fenceLegacyMigrationEntryDurability(
        parentDescriptor: Int32,
        name: String,
        expectedFingerprint: LegacyMigrationFingerprint,
        requireSecureControlFile: Bool
    ) -> Result<LegacyMigrationFingerprint, LegacyMigrationTransactionFailure> {
        guard validLeafName(name) else {
            return .failure(.init(reason: "durabilityFenceInvalidName", errno: EINVAL))
        }
        let descriptor = name.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return .failure(.init(reason: "durabilityFenceOpen", errno: errno))
        }
        defer { Darwin.close(descriptor) }

        func exactFence() -> Bool {
            var descriptorMetadata = stat()
            var pathMetadata = stat()
            let pathProbe = name.withCString {
                fstatat(parentDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(descriptor, &descriptorMetadata) == 0, pathProbe == 0 else {
                return false
            }
            let descriptorFingerprint = LegacyMigrationFingerprint(descriptorMetadata)
            let pathFingerprint = LegacyMigrationFingerprint(pathMetadata)
            let metadataIsAuthorized = requireSecureControlFile
                ? descriptorFingerprint.isSecureControlFile
                : descriptorFingerprint.isRegularSingleLink
                    && descriptorFingerprint.ownerID == UInt32(geteuid())
            return metadataIsAuthorized
                && descriptorFingerprint == expectedFingerprint
                && pathFingerprint == descriptorFingerprint
        }

        guard exactFence() else {
            return .failure(.init(reason: "durabilityFenceVersionChanged", errno: nil))
        }
        guard fsync(descriptor) == 0 else {
            return .failure(.init(reason: "durabilityFenceFsync", errno: errno))
        }
        guard exactFence() else {
            return .failure(.init(reason: "durabilityFencePostFsyncChanged", errno: nil))
        }
        return .success(expectedFingerprint)
    }

    nonisolated private static func recoverLegacyMigrationTransaction(
        _ state: LegacyMigrationTransactionState,
        parentDescriptor: Int32
    ) -> LegacyMigrationRecoveryDisposition {
        let payload = state.payload
        let reserveContractIsComplete = payload.reserveStageName == nil
            ? payload.reserveStageFingerprint == nil && payload.reserveStageVersion == nil
            : payload.reserveStageFingerprint != nil && payload.reserveStageVersion != nil
        let reserveContractIsAllocating = payload.phase == .allocatingReserve
            && payload.reserveStageName != nil
            && payload.reserveStageFingerprint == nil
            && payload.reserveStageVersion == nil
        let expectedDestinationContractIsComplete: Bool
        if let expected = payload.expectedDestination,
           let expectedVersion = payload.expectedDestinationVersion {
            expectedDestinationContractIsComplete = expectedVersion.objectIdentity
                == expected.objectIdentity
                && expectedVersion.metadata == expected.renameStableMetadata
        } else {
            expectedDestinationContractIsComplete = payload.expectedDestination == nil
                && payload.expectedDestinationVersion == nil
        }
        let reserveVersionContractIsComplete: Bool
        if let reserveFingerprint = payload.reserveStageFingerprint,
           let reserveVersion = payload.reserveStageVersion {
            reserveVersionContractIsComplete = reserveVersion.objectIdentity
                == reserveFingerprint.objectIdentity
                && reserveVersion.metadata == reserveFingerprint.renameStableMetadata
        } else {
            reserveVersionContractIsComplete = payload.reserveStageFingerprint == nil
                && payload.reserveStageVersion == nil
        }
        guard payload.protocolVersion == LegacyMigrationTransactionPayload.protocolVersion,
              legacyMigrationControlNames(destinationName: payload.destinationName)
                .stages.contains(payload.stageName),
              validLeafName(payload.destinationName),
              payload.stageVersion.objectIdentity == payload.stageFingerprint.objectIdentity,
              payload.stageVersion.metadata == payload.stageFingerprint.renameStableMetadata,
              expectedDestinationContractIsComplete,
              reserveVersionContractIsComplete,
              reserveContractIsComplete || reserveContractIsAllocating,
              payload.marker0Identity != payload.marker1Identity else {
            return .rejected(reason: "transactionContract", errno: nil)
        }
        if payload.phase == .allocatingReserve {
            switch completeLegacyMigrationReserveAllocation(
                state,
                parentDescriptor: parentDescriptor,
                interruptionHook: nil
            ) {
            case .success(let idle): return .ready(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }
        }
        if payload.phase == .idle {
            guard payload.transactionID == nil,
                  payload.expectedDestination == nil,
                  payload.expectedDestinationVersion == nil else {
                return .rejected(reason: "idleContract", errno: nil)
            }
            let activeFD: Int32
            switch openLegacyMigrationStage(
                parentDescriptor: parentDescriptor,
                destinationName: payload.destinationName,
                stageName: payload.stageName,
                expected: payload.stageFingerprint,
                expectedVersion: payload.stageVersion
            ) {
            case .success(let descriptor): activeFD = descriptor
            case .failure(let failure):
                return .rejected(
                    reason: "idle\(failure.reason.capitalized)",
                    errno: failure.errno
                )
            }
            Darwin.close(activeFD)
            if let reserveName = payload.reserveStageName,
               let reserveFingerprint = payload.reserveStageFingerprint,
               let reserveVersion = payload.reserveStageVersion {
                let reserveFD: Int32
                switch openLegacyMigrationStage(
                    parentDescriptor: parentDescriptor,
                    destinationName: payload.destinationName,
                    stageName: reserveName,
                    expected: reserveFingerprint,
                    expectedVersion: reserveVersion
                ) {
                case .success(let descriptor): reserveFD = descriptor
                case .failure(let failure):
                    return .rejected(
                        reason: "idleReserve\(failure.reason.capitalized)",
                        errno: failure.errno
                    )
                }
                Darwin.close(reserveFD)
            }
            GSYLog.info(
                .trash,
                "undo_history.legacy_migration.transaction event=recover_idle generation="
                    + "\(payload.generation) phase=idle active_slot=\(state.activeSlot) "
                    + "transaction_id=none wal_full_reads=0"
            )
            return .ready(state)
        }
        let destinationProbe = probeLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: payload.destinationName
        )
        let stageProbe = probeLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: payload.stageName
        )
        if case .failed(let code) = destinationProbe {
            return .rejected(reason: "destinationProbe", errno: code)
        }
        if case .failed(let code) = stageProbe {
            return .rejected(reason: "stageProbe", errno: code)
        }
        let expectedIdentity = payload.expectedDestination?.objectIdentity
        let stagedIdentity = payload.stageFingerprint.objectIdentity
        func classification(_ probe: LegacyMigrationEntryProbe) -> String {
            switch probe {
            case .absent: return "absent"
            case .failed: return "probe_failed"
            case .present(let fingerprint):
                if fingerprint.objectIdentity == stagedIdentity { return "staged" }
                if fingerprint.objectIdentity == expectedIdentity { return "expected_old" }
                return "foreign"
            }
        }
        GSYLog.info(
            .trash,
            "undo_history.legacy_migration.transaction event=recover generation="
                + "\(payload.generation) phase=\(payload.phase.rawValue) active_slot="
                + "\(state.activeSlot) transaction_id="
                + "\(payload.transactionID?.uuidString ?? "none") destination_state="
                + "\(classification(destinationProbe)) stage_state=\(classification(stageProbe))"
        )

        switch payload.phase {
        case .idle:
            return .rejected(reason: "unreachableIdleRecovery", errno: nil)

        case .rewritingStage:
            guard payload.transactionID != nil,
                  case .present(let stageFingerprint) = stageProbe,
                  stageFingerprint.isRegularSingleLink,
                  stageFingerprint.hasSameObjectIdentity(as: payload.stageFingerprint),
                  let reserveName = payload.reserveStageName,
                  let reserveExpectedFingerprint = payload.reserveStageFingerprint else {
                return .rejected(reason: "rewritingStageIdentity", errno: nil)
            }
            let stageData: Data
            let currentStageFingerprint: LegacyMigrationFingerprint
            switch readLegacyMigrationEntry(
                parentDescriptor: parentDescriptor,
                name: payload.stageName
            ) {
            case .present(let current, let data)
                where current.isSecureControlFile
                    && current.hasSameObjectIdentity(as: payload.stageFingerprint):
                stageData = data
                currentStageFingerprint = current
            case .failed(let reason, let code):
                return .rejected(reason: "rewritingStage\(reason.capitalized)", errno: code)
            case .absent, .present:
                return .rejected(reason: "rewritingStageVersion", errno: nil)
            }
            let reserveData: Data
            let currentReserveFingerprint: LegacyMigrationFingerprint
            switch readLegacyMigrationEntry(
                parentDescriptor: parentDescriptor,
                name: reserveName
            ) {
            case .present(let current, let data)
                where current.isSecureControlFile
                    && current.hasSameObjectIdentity(as: reserveExpectedFingerprint):
                reserveData = data
                currentReserveFingerprint = current
            case .failed(let reason, let code):
                return .rejected(reason: "rewritingReserve\(reason.capitalized)", errno: code)
            case .absent, .present:
                return .rejected(reason: "rewritingReserveVersion", errno: nil)
            }
            let stageSet = LegacyMigrationStageSet(
                name: payload.stageName,
                fingerprint: currentStageFingerprint,
                version: LegacyMigrationVersionEvidence(
                    fingerprint: currentStageFingerprint,
                    data: stageData
                ),
                reserveName: reserveName,
                reserveFingerprint: currentReserveFingerprint,
                reserveVersion: LegacyMigrationVersionEvidence(
                    fingerprint: currentReserveFingerprint,
                    data: reserveData
                )
            )
            // A crash can leave complete scratch bytes visible before their fsync returned. The
            // recovery generation may adopt those bytes only after both exact inodes cross a fresh
            // durability fence; otherwise the older marker remains authoritative.
            switch fenceLegacyMigrationEntryDurability(
                parentDescriptor: parentDescriptor,
                name: payload.stageName,
                expectedFingerprint: currentStageFingerprint,
                requireSecureControlFile: true
            ) {
            case .success: break
            case .failure(let failure):
                return .rejected(
                    reason: "rewritingStage\(failure.reason.capitalized)",
                    errno: failure.errno
                )
            }
            switch fenceLegacyMigrationEntryDurability(
                parentDescriptor: parentDescriptor,
                name: reserveName,
                expectedFingerprint: currentReserveFingerprint,
                requireSecureControlFile: true
            ) {
            case .success: break
            case .failure(let failure):
                return .rejected(
                    reason: "rewritingReserve\(failure.reason.capitalized)",
                    errno: failure.errno
                )
            }
            switch transitionLegacyMigrationToIdle(
                state,
                stageSet: stageSet,
                parentDescriptor: parentDescriptor
            ) {
            case .success(let idle): return .ready(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }

        case .prepared:
            guard payload.transactionID != nil else {
                return .rejected(reason: "preparedWithoutTransaction", errno: nil)
            }
            if let expected = payload.expectedDestination,
               let expectedVersion = payload.expectedDestinationVersion {
                return recoverLegacyMigrationReplacement(
                    state,
                    expectedDestination: expected,
                    expectedDestinationVersion: expectedVersion,
                    destinationProbe: destinationProbe,
                    stageProbe: stageProbe,
                    parentDescriptor: parentDescriptor
                )
            }
            return recoverLegacyMigrationFirstCreation(
                state,
                destinationProbe: destinationProbe,
                stageProbe: stageProbe,
                parentDescriptor: parentDescriptor
            )
        case .allocatingReserve:
            return .rejected(reason: "unreachableReserveAllocation", errno: nil)
        }
    }

    nonisolated private static func recoverLegacyMigrationReplacement(
        _ state: LegacyMigrationTransactionState,
        expectedDestination: LegacyMigrationFingerprint,
        expectedDestinationVersion: LegacyMigrationVersionEvidence,
        destinationProbe: LegacyMigrationEntryProbe,
        stageProbe: LegacyMigrationEntryProbe,
        parentDescriptor: Int32
    ) -> LegacyMigrationRecoveryDisposition {
        let payload = state.payload
        let expectedIdentity = expectedDestination.objectIdentity
        let stagedIdentity = payload.stageFingerprint.objectIdentity
        guard case .present(let destinationFingerprint) = destinationProbe,
              destinationFingerprint.objectIdentity == expectedIdentity,
              case .present(let stageFingerprint) = stageProbe,
              stageFingerprint.objectIdentity == stagedIdentity else {
            GSYLog.warning(
                .trash,
                "undo_history.legacy_migration.transaction event=canonical_replacement_preserved "
                    + "generation=\(payload.generation) phase=\(payload.phase.rawValue) "
                    + "active_slot=\(state.activeSlot) transaction_id="
                    + "\(payload.transactionID?.uuidString ?? "none")"
            )
            return .rejected(reason: "canonicalReplacementPreserved", errno: nil)
        }

        let stagedData: Data
        switch readLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: payload.stageName
        ) {
        case .present(let current, let data)
            where current == payload.stageFingerprint
                && current.isSecureControlFile
                && LegacyMigrationVersionEvidence(
                    fingerprint: current,
                    data: data
                ) == payload.stageVersion:
            stagedData = data
        case .failed(let reason, let code):
            return .rejected(reason: "preparedStage\(reason.capitalized)", errno: code)
        case .absent, .present:
            return .rejected(reason: "preparedStageVersionMismatch", errno: nil)
        }
        let oldSnapshotData: Data
        guard let reserveName = payload.reserveStageName,
              let reserveFingerprint = payload.reserveStageFingerprint,
              let reserveVersion = payload.reserveStageVersion else {
            return .rejected(reason: "preparedOldSnapshotMissing", errno: nil)
        }
        switch readLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: reserveName
        ) {
        case .present(let current, let data)
            where current == reserveFingerprint
                && current.isSecureControlFile
                && LegacyMigrationVersionEvidence(
                    fingerprint: current,
                    data: data
                ) == reserveVersion:
            oldSnapshotData = data
        case .failed(let reason, let code):
            return .rejected(reason: "preparedOldSnapshot\(reason.capitalized)", errno: code)
        case .absent, .present:
            return .rejected(reason: "preparedOldSnapshotVersionMismatch", errno: nil)
        }
        guard SHA256.hash(data: oldSnapshotData)
            .map({ String(format: "%02x", $0) }).joined()
            == expectedDestinationVersion.contentSHA256 else {
            return .rejected(reason: "preparedOldSnapshotDigestMismatch", errno: nil)
        }

        let canonicalData: Data
        let currentCanonicalFingerprint: LegacyMigrationFingerprint
        switch readLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: payload.destinationName
        ) {
        case .present(let current, let data)
            where current.objectIdentity == expectedIdentity:
            canonicalData = data
            currentCanonicalFingerprint = current
        case .failed(let reason, let code):
            return .rejected(reason: "preparedCanonical\(reason.capitalized)", errno: code)
        case .absent, .present:
            return .rejected(reason: "canonicalReplacementPreserved", errno: nil)
        }
        let stageSet = LegacyMigrationStageSet(
            name: payload.stageName,
            fingerprint: payload.stageFingerprint,
            version: payload.stageVersion,
            reserveName: reserveName,
            reserveFingerprint: reserveFingerprint,
            reserveVersion: reserveVersion
        )
        if canonicalData == oldSnapshotData {
            switch transitionLegacyMigrationToIdle(
                state,
                stageSet: stageSet,
                parentDescriptor: parentDescriptor
            ) {
            case .success(let idle): return .ready(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }
        }
        if canonicalData == stagedData {
            // Exact-new bytes prove classification, not durability. A writer interrupted after
            // pwrite but before fsync leaves those bytes visible in cache; commit PREPARED only
            // after this exact canonical inode/path survives a successful recovery fsync.
            switch fenceLegacyMigrationEntryDurability(
                parentDescriptor: parentDescriptor,
                name: payload.destinationName,
                expectedFingerprint: currentCanonicalFingerprint,
                requireSecureControlFile: false
            ) {
            case .success: break
            case .failure(let failure):
                return .rejected(
                    reason: "preparedCanonical\(failure.reason.capitalized)",
                    errno: failure.errno
                )
            }
            switch transitionLegacyMigrationToIdle(
                state,
                stageSet: stageSet,
                parentDescriptor: parentDescriptor
            ) {
            case .success(let idle): return .committed(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }
        }
        // Neither exact old nor exact new is sufficient evidence. This may be a crash-torn write
        // or a non-cooperating same-inode writer; Darwin cannot distinguish them. Preserve WAL.
        return .rejected(reason: "canonicalContentAmbiguousWALPreserved", errno: nil)
    }

    nonisolated private static func recoverLegacyMigrationFirstCreation(
        _ state: LegacyMigrationTransactionState,
        destinationProbe: LegacyMigrationEntryProbe,
        stageProbe: LegacyMigrationEntryProbe,
        parentDescriptor: Int32
    ) -> LegacyMigrationRecoveryDisposition {
        let payload = state.payload
        let destinationFingerprint: LegacyMigrationFingerprint?
        if case .present(let fingerprint) = destinationProbe {
            destinationFingerprint = fingerprint
        } else {
            destinationFingerprint = nil
        }
        let stageFingerprint: LegacyMigrationFingerprint?
        if case .present(let fingerprint) = stageProbe {
            stageFingerprint = fingerprint
        } else {
            stageFingerprint = nil
        }

        let stagedIdentity = payload.stageFingerprint.objectIdentity
        if destinationFingerprint == nil,
           stageFingerprint?.objectIdentity == stagedIdentity {
            guard case .success(let verifiedStage) = verifyLegacyMigrationEntryVersion(
                parentDescriptor: parentDescriptor,
                name: payload.stageName,
                expectedFullFingerprint: payload.stageFingerprint,
                expectedVersion: payload.stageVersion,
                requireSecureControlFile: true
            ) else {
                return .rejected(reason: "firstCreatePreRenameVersionMismatch", errno: nil)
            }
            let stageSet = LegacyMigrationStageSet(
                name: payload.stageName,
                fingerprint: verifiedStage,
                version: payload.stageVersion,
                reserveName: payload.reserveStageName,
                reserveFingerprint: payload.reserveStageFingerprint,
                reserveVersion: payload.reserveStageVersion
            )
            switch transitionLegacyMigrationToIdle(
                state,
                stageSet: stageSet,
                parentDescriptor: parentDescriptor
            ) {
            case .success(let idle): return .ready(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }
        }

        if destinationFingerprint?.objectIdentity == stagedIdentity,
           stageFingerprint == nil,
           let reserveName = payload.reserveStageName,
           let reserveFingerprint = payload.reserveStageFingerprint,
           let reserveVersion = payload.reserveStageVersion {
            guard case .success(let verifiedCanonical) = verifyLegacyMigrationEntryVersion(
                parentDescriptor: parentDescriptor,
                name: payload.destinationName,
                expectedFullFingerprint: nil,
                expectedVersion: payload.stageVersion,
                requireSecureControlFile: true
            ) else {
                return .rejected(reason: "firstCreatePostRenameVersionMismatch", errno: nil)
            }
            switch fenceLegacyMigrationEntryDurability(
                parentDescriptor: parentDescriptor,
                name: payload.destinationName,
                expectedFingerprint: verifiedCanonical,
                requireSecureControlFile: true
            ) {
            case .success: break
            case .failure(let failure):
                return .rejected(
                    reason: "firstCreateCanonical\(failure.reason.capitalized)",
                    errno: failure.errno
                )
            }
            // Recovery may be running after the rename but before its original parent fsync.
            // Canonical data durability and namespace durability are separate commit facts.
            guard fsync(parentDescriptor) == 0 else {
                return .rejected(reason: "firstCreateDirectoryFsync", errno: errno)
            }
            let stageSet = LegacyMigrationStageSet(
                name: reserveName,
                fingerprint: reserveFingerprint,
                version: reserveVersion,
                reserveName: nil,
                reserveFingerprint: nil,
                reserveVersion: nil
            )
            switch transitionLegacyMigrationToIdle(
                state,
                stageSet: stageSet,
                parentDescriptor: parentDescriptor
            ) {
            case .success(let idle): return .committed(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }
        }

        // RENAME_EXCL never ran when the exact prepared stage still exists. If a different
        // canonical object appeared, it is an external winner—not an ambiguous partial commit.
        // Preserve that pathname untouched and retire only the marker intent; both fixed WAL files
        // remain owned and will be reused by the next locked transaction.
        if let destinationFingerprint,
           destinationFingerprint.objectIdentity != stagedIdentity,
           stageFingerprint?.objectIdentity == stagedIdentity {
            guard case .success(let verifiedStage) = verifyLegacyMigrationEntryVersion(
                parentDescriptor: parentDescriptor,
                name: payload.stageName,
                expectedFullFingerprint: payload.stageFingerprint,
                expectedVersion: payload.stageVersion,
                requireSecureControlFile: true
            ) else {
                return .rejected(reason: "firstCreateExternalWinnerStageMismatch", errno: nil)
            }
            let stageSet = LegacyMigrationStageSet(
                name: payload.stageName,
                fingerprint: verifiedStage,
                version: payload.stageVersion,
                reserveName: payload.reserveStageName,
                reserveFingerprint: payload.reserveStageFingerprint,
                reserveVersion: payload.reserveStageVersion
            )
            GSYLog.warning(
                .trash,
                "undo_history.legacy_migration.transaction event=first_create_external_winner_preserved "
                    + "generation=\(payload.generation) active_slot=\(state.activeSlot) "
                    + "transaction_id=\(payload.transactionID?.uuidString ?? "none")"
            )
            switch transitionLegacyMigrationToIdle(
                state,
                stageSet: stageSet,
                parentDescriptor: parentDescriptor
            ) {
            case .success(let idle): return .ready(idle)
            case .failure(let failure):
                return .rejected(reason: failure.reason, errno: failure.errno)
            }
        }

        GSYLog.warning(
            .trash,
            "undo_history.legacy_migration.transaction event=first_create_mismatch_no_rollback "
                + "generation=\(payload.generation) phase=\(payload.phase.rawValue) active_slot="
                + "\(state.activeSlot) transaction_id="
                + "\(payload.transactionID?.uuidString ?? "none")"
        )
        return .rejected(reason: "ambiguousFirstCreationNoRollback", errno: nil)
    }

    nonisolated private static func openOrCreateLegacyMigrationDestinationParent(
        _ destinationParent: URL
    ) -> Int32? {
        let container = destinationParent.deletingLastPathComponent()
        let name = destinationParent.lastPathComponent
        guard validLeafName(name) else { errno = EINVAL; return nil }
        let containerFD = container.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard containerFD >= 0 else { return nil }
        defer { Darwin.close(containerFD) }

        var descriptor = name.withCString {
            openat(containerFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor >= 0 { return descriptor }
        guard errno == ENOENT else { return nil }
        let created = name.withCString {
            mkdirat(containerFD, $0, mode_t(S_IRWXU))
        }
        guard created == 0 || errno == EEXIST else { return nil }
        descriptor = name.withCString {
            openat(containerFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        // v2026.07.19 durability fence: the file transaction fsyncs the new App directory,
        // while this parent fsync makes the App-directory entry itself durable when mkdirat won.
        // Running it after an EEXIST race is harmless and avoids guessing which process created it.
        guard fsync(containerFD) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            errno = code
            return nil
        }
        return descriptor
    }

    nonisolated private static func readFrozenLegacyData(
        descriptor: Int32,
        expectedByteCount: Int
    ) -> FrozenLegacyReadResult {
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset: off_t = 0
        while data.count < expectedByteCount {
            let requestCount = min(buffer.count, expectedByteCount - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, requestCount, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .failed(errno: errno)
            }
            guard count > 0 else { return .failed(errno: EIO) }
            data.append(contentsOf: buffer[..<count])
            offset += off_t(count)
        }

        var extraByte: UInt8 = 0
        let extraCount = withUnsafeMutablePointer(to: &extraByte) {
            Darwin.pread(descriptor, $0, 1, offset)
        }
        if extraCount < 0 { return .failed(errno: errno) }
        guard extraCount == 0 else { return .failed(errno: EFBIG) }
        return .success(data)
    }

    /// Reads the current-brand side of legacy reconciliation without following a leaf symlink or
    /// trusting a pathname preflight. The caller owns the destination flock and parent descriptor;
    /// this helper still binds probe/open/read/final-name verification to one regular single-link
    /// object so migration never merges bytes from a raced namespace entry.
    nonisolated private static func readFrozenDestinationEnvelope(
        parentDescriptor: Int32,
        leafName: String,
        probedMetadata: stat
    ) -> FrozenDestinationReadResult {
        let probedFingerprint = LegacyMigrationFingerprint(probedMetadata)
        guard probedFingerprint.isRegularSingleLink,
              probedFingerprint.ownerID == UInt32(geteuid()) else {
            return .rejected(
                .readFailed,
                stage: "validateDestination",
                reason: "notOwnedRegularSingleLink",
                errno: nil
            )
        }
        guard probedFingerprint.byteCount <= Int64(maximumStoreBytes) else {
            return .rejected(
                .storeTooLarge(maxBytes: maximumStoreBytes),
                stage: "validateDestination",
                reason: "byteLimit",
                errno: nil
            )
        }

        let descriptor = leafName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            return .rejected(
                .readFailed,
                stage: "openDestination",
                reason: code == ELOOP ? "symlink" : "posix",
                errno: code
            )
        }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            return .rejected(
                .readFailed,
                stage: "statDestination",
                reason: "posix",
                errno: errno
            )
        }
        let openedFingerprint = LegacyMigrationFingerprint(openedMetadata)
        guard openedFingerprint == probedFingerprint else {
            return .rejected(
                .readFailed,
                stage: "openDestination",
                reason: "destinationChanged",
                errno: nil
            )
        }

        let data: Data
        switch readFrozenLegacyData(
            descriptor: descriptor,
            expectedByteCount: Int(openedFingerprint.byteCount)
        ) {
        case .success(let value):
            data = value
        case .failed(let code):
            return .rejected(
                code == EFBIG
                    ? .storeTooLarge(maxBytes: maximumStoreBytes)
                    : .readFailed,
                stage: "readDestination",
                reason: code == EFBIG ? "byteLimit" : "posix",
                errno: code
            )
        }

        var postReadMetadata = stat()
        var finalPathMetadata = stat()
        let finalPathProbe = leafName.withCString {
            fstatat(parentDescriptor, $0, &finalPathMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &postReadMetadata) == 0,
              LegacyMigrationFingerprint(postReadMetadata) == openedFingerprint,
              finalPathProbe == 0,
              LegacyMigrationFingerprint(finalPathMetadata) == openedFingerprint else {
            return .rejected(
                .readFailed,
                stage: "readDestination",
                reason: "versionChanged",
                errno: nil
            )
        }
        guard let decoded = decodeEnvelope(data) else {
            return .rejected(
                .corrupt,
                stage: "decodeDestination",
                reason: "invalidJSON",
                errno: nil
            )
        }
        if decoded.records.contains(where: { $0.filePairs.count > maximumPairsPerRecord }) {
            return .rejected(
                .recordRejected(maxPairs: maximumPairsPerRecord),
                stage: "decodeDestination",
                reason: "recordLimit",
                errno: nil
            )
        }
        guard let migrated = migrateLegacyJournalIdentifiers(decoded),
              validate(migrated.envelope) else {
            return .rejected(
                .corrupt,
                stage: "validateDestination",
                reason: "invalidShape",
                errno: nil
            )
        }
        return .success(FrozenDestinationEnvelope(
            envelope: migrated.envelope,
            fingerprint: openedFingerprint,
            versionEvidence: LegacyMigrationVersionEvidence(
                fingerprint: openedFingerprint,
                data: data
            ),
            data: data,
            requiresPersistenceMigration: migrated.changed
        ))
    }

    nonisolated private static func writeLegacyMigrationData(
        _ data: Data,
        descriptor: Int32
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { errno = EIO; return false }
                offset += count
            }
            return true
        }
    }

    nonisolated private static func legacyMigrationRejected(
        _ state: StorageState,
        stage: String,
        reason: String,
        errno code: Int32? = nil,
        legacy: URL,
        destination: URL
    ) -> LegacyMigrationOutcome {
        GSYLog.error(
            .trash,
            "undo_history.legacy_migration.rejected stage=\(stage) reason=\(reason) "
                + "errno=\(code.map(String.init) ?? "none") from=\(legacy.path) "
                + "to=\(destination.path) sourceRetained=true"
        )
        return .rejected(state)
    }

    // MARK: - Public API

    /// 写一条新记录（最新在最前，超过 maxHistoryCount 丢最旧）。空 pair 直接 no-op。
    public func addRecord(source: String, filePairs: [Record.FilePair]) {
        guard !filePairs.isEmpty else { return }
        guard filePairs.count <= Self.maximumPairsPerRecord else {
            storageState = .recordRejected(maxPairs: Self.maximumPairsPerRecord)
            GSYLog.error(
                .trash,
                "UndoHistory record rejected pairs=\(filePairs.count) max=\(Self.maximumPairsPerRecord)"
            )
            return
        }
        let unverifiedCount = filePairs.lazy.filter { $0.trashedIdentity == nil }.count
        if unverifiedCount > 0 {
            // Fail-closed is intentional: preserving the operation fact is still useful, but a
            // pathname without frozen object identity must never become a restore capability.
            GSYLog.warning(
                .trash,
                "UndoHistory 写入时无法冻结部分对象身份 source=\(source) unavailable=\(unverifiedCount)/\(filePairs.count)"
            )
        }
        let record = Record(source: source, filePairs: filePairs)
        var updated = history
        updated.insert(record, at: 0)
        if updated.count > maxHistoryCount {
            updated = Array(updated.prefix(maxHistoryCount))
        }
        publishHistory(updated)
        saveHistory()
        GSYLog.info(.trash, "UndoHistory 写入 source=\(source) pairs=\(filePairs.count) total=\(history.count)")
    }

    func setRestoreBeforeRenameHookForTesting(_ hook: (@Sendable () -> Void)?) {
        restoreBeforeRenameHookForTesting = hook
    }

    func setPersistenceMutationHookForTesting(
        _ hook: (@Sendable (String) -> Void)?
    ) {
        persistenceMutationHookForTesting = hook
    }

    func setPersistencePublicationHookForTesting(
        _ hook: (@Sendable (UInt64) -> Void)?
    ) {
        persistencePublicationHookForTesting = hook
    }

    func setRecoveryRefreshProbeHookForTesting(
        _ hook: (@Sendable (String) -> Void)?
    ) {
        recoveryRefreshProbeHookForTesting = hook
    }

    var persistenceRevisionForTesting: UInt64 {
        persistenceRevision
    }

    /// 后台检查一条记录，冻结恢复前的冲突 / 缺失快照。执行时仍会重新检查目标路径，
    /// 因而计划生成后出现的新文件也绝不会被覆盖。
    public func prepareRestore(_ record: Record) async -> RestorePlan {
        let current = history.first(where: { $0.id == record.id }) ?? record
        let currentHistoryRevision = historyRevision
        let restoreRoots = allowedRestoreRoots
        let preparation = await Task.detached(priority: .userInitiated) {
            Self.buildRestorePreparation(current, allowedRestoreRoots: restoreRoots)
        }.value

        if historyRevision == currentHistoryRevision,
           let index = history.firstIndex(where: { $0.id == current.id }) {
            let latest = history[index]
            let merged = latest.updatingRecoveryStates(
                Self.mergingObservedStates(
                    current: latest.recoveryStates,
                    observed: preparation.recoveryStates
                )
            )
            if merged != latest {
                history[index] = merged
                historyRevision &+= 1
                saveHistory()
            }
        }
        return preparation.plan
    }

    /// v2026.07.18：历史页出现或后台加载晚到时，在 utility worker 刷新所有非终态条目的
    /// 恢复能力。Store 负责取消并 join 上一轮；每个 pair 都有协作取消点，且提交前对整个
    /// history snapshot 做 CAS。若 journal/restore 在探测期间改变了历史，新 owner 会基于最新
    /// 快照重试，旧观察绝不能覆盖较新的恢复状态。
    public func refreshRecoveryStates() async {
        recoveryRefreshGeneration &+= 1
        let generation = recoveryRefreshGeneration

        if let previous = recoveryRefreshWorker {
            previous.cancel()
            _ = await previous.value
        }
        guard generation == recoveryRefreshGeneration, !Task.isCancelled else { return }

        while generation == recoveryRefreshGeneration, !Task.isCancelled {
            let snapshots = history
            let snapshotHistoryRevision = historyRevision
            let probeHook = recoveryRefreshProbeHookForTesting
            let worker = Task.detached(priority: .utility) { () -> RecoveryRefreshOutput? in
                var refreshed: [Record] = []
                refreshed.reserveCapacity(snapshots.count)
                var changed = false
                for record in snapshots {
                    guard !Task.isCancelled,
                          let states = Self.probeRecoveryStates(
                            for: record,
                            probeHook: probeHook
                          ) else {
                        return nil
                    }
                    let updated = record.updatingRecoveryStates(states)
                    changed = changed || updated != record
                    refreshed.append(updated)
                }
                return RecoveryRefreshOutput(records: refreshed, changed: changed)
            }
            recoveryRefreshWorker = worker
            recoveryRefreshWorkerGeneration = generation

            let refreshed = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            if recoveryRefreshWorkerGeneration == generation {
                recoveryRefreshWorker = nil
                recoveryRefreshWorkerGeneration = nil
            }
            guard generation == recoveryRefreshGeneration,
                  !Task.isCancelled,
                  let refreshed else {
                return
            }

            // Any concurrent journal merge, restore, or newer observation changes the value
            // snapshot. Retry from that state instead of trying to define a false ordering over
            // available/missing/identityChanged observations.
            guard historyRevision == snapshotHistoryRevision else { continue }
            guard refreshed.changed else { return }
            publishHistory(refreshed.records)
            saveHistory()
            return
        }
    }

    /// 恢复一条记录。调用方必须显式传入冲突策略；API 不再存在会暗中处理现有文件的默认分支。
    /// 文件系统 IO 在后台执行，MainActor 只更新 history 和持久化快照。
    @discardableResult
    public func restoreRecord(
        _ record: Record,
        conflictPolicy: RestoreConflictPolicy,
        locale: Locale
    ) async -> RestoreResult {
        guard let current = history.first(where: { $0.id == record.id }) else {
            return RestoreResult(
                restoredCount: 0,
                skippedCount: 0,
                renamedCount: 0,
                firstFailure: .historyRecordUnavailable
            )
        }
        guard activeRestoreRecordIDs.insert(record.id).inserted else {
            return RestoreResult(
                restoredCount: 0,
                skippedCount: 0,
                renamedCount: 0,
                firstFailure: .restoreAlreadyInProgress
            )
        }
        defer { activeRestoreRecordIDs.remove(record.id) }
        let restoreRoots = allowedRestoreRoots
        let beforeRenameHook = restoreBeforeRenameHookForTesting
        let execution = await Task.detached(priority: .userInitiated) {
            Self.executeRestore(
                current,
                conflictPolicy: conflictPolicy,
                locale: locale,
                allowedRestoreRoots: restoreRoots,
                beforeRenameHook: beforeRenameHook
            )
        }.value

        if let idx = history.firstIndex(where: { $0.id == current.id }) {
            // v2026.07.18 P2 side-effect settlement fix: filesystem rename is already real when
            // the worker returns. An unrelated history publication must not make an O(1) global
            // CAS discard that terminal fact. Merge the executed frozen record into the latest
            // same-ID version using the strict pair-prefix/receipt-upgrade contract, preserving a
            // concurrently appended journal suffix while recording restored destinations.
            let executed = current.updatingRecoveryStates(execution.recoveryStates)
            if let merged = Self.mergeVersionsOfSameRecord(
                disk: history[idx],
                incoming: executed
            ) {
                history[idx] = merged
                historyRevision &+= 1
                saveHistory()
            } else {
                storageState = .corrupt
                GSYLog.error(
                    .trash,
                    "UndoHistory restore settlement rejected record metadata conflict id=\(current.id)"
                )
            }
        } else if execution.result.restoredCount > 0 {
            // A record can be evicted only by unrelated newer history while its Store-owned
            // restore is in flight. Preserve the side-effect evidence in memory instead of
            // silently losing every restored destination; persistence will still apply the
            // global LRU contract under its stable lock.
            var updated = history
            updated.insert(current.updatingRecoveryStates(execution.recoveryStates), at: 0)
            publishHistory(Array(updated.prefix(maxHistoryCount)))
            saveHistory()
        }

        if !execution.restoredPaths.isEmpty {
            NotificationCenter.default.post(
                name: .gsyUndoDidRestore,
                object: self,
                userInfo: ["paths": execution.restoredPaths]
            )
        }

        let result = execution.result
        GSYLog.info(
            .trash,
            "UndoHistory restoreRecord 完成 restored=\(result.restoredCount) renamed=\(result.renamedCount) skipped=\(result.skippedCount) failure=\(String(describing: result.firstFailure))"
        )
        return result
    }

    nonisolated private static func buildRestorePreparation(
        _ record: Record,
        allowedRestoreRoots: [String]
    ) -> RestorePreparation {
        var readyCount = 0
        var conflictPaths: [String] = []
        var missingTrashPaths: [String] = []
        var identityChangedTrashPaths: [String] = []
        var unavailableTrashPaths: [String] = []
        var unavailableDestinationPaths: [String] = []
        var outOfScopeDestinationPaths: [String] = []
        var reservedDestinations: Set<String> = []
        var states = normalizedRecoveryStates(for: record)

        for index in record.filePairs.indices {
            let pair = record.filePairs[index]
            if states[index].status == .restored { continue }

            guard restoreScopeRoot(for: pair, allowedRoots: allowedRestoreRoots) != nil else {
                outOfScopeDestinationPaths.append(pair.original)
                continue
            }

            switch validatedRecoveryState(for: pair) {
            case .available:
                states[index] = Record.RecoveryState(status: .available)
            case .missing:
                states[index] = Record.RecoveryState(status: .missing)
                missingTrashPaths.append(pair.trashed)
                continue
            case .identityChanged:
                states[index] = Record.RecoveryState(status: .identityChanged)
                identityChangedTrashPaths.append(pair.trashed)
                continue
            case .unavailable, .checking:
                states[index] = Record.RecoveryState(status: .unavailable)
                unavailableTrashPaths.append(pair.trashed)
                continue
            case .restored:
                continue
            }

            let normalizedDestination = URL(fileURLWithPath: pair.original)
                .standardizedFileURL.path
            let firstUse = reservedDestinations.insert(normalizedDestination).inserted
            if !firstUse {
                conflictPaths.append(pair.original)
            } else {
                switch pathEntryProbe(atPath: pair.original) {
                case .present:
                    conflictPaths.append(pair.original)
                case .absent:
                    readyCount += 1
                case .unavailable:
                    unavailableDestinationPaths.append(pair.original)
                }
            }
        }

        return RestorePreparation(
            plan: RestorePlan(
                readyCount: readyCount,
                conflictPaths: conflictPaths,
                missingTrashPaths: missingTrashPaths,
                identityChangedTrashPaths: identityChangedTrashPaths,
                unavailableTrashPaths: unavailableTrashPaths,
                unavailableDestinationPaths: unavailableDestinationPaths,
                outOfScopeDestinationPaths: outOfScopeDestinationPaths
            ),
            recoveryStates: states
        )
    }

    nonisolated private static func executeRestore(
        _ record: Record,
        conflictPolicy: RestoreConflictPolicy,
        locale: Locale,
        allowedRestoreRoots: [String],
        beforeRenameHook: (@Sendable () -> Void)?
    ) -> RestoreExecution {
        var restored = 0
        var skipped = 0
        var renamed = 0
        var firstFailure: RestoreFailure?
        var states = normalizedRecoveryStates(for: record)
        var restoredPaths: [String] = []
        var restoredOriginalPaths: [String] = []
        var reservedDestinations = Set(record.filePairs.map { pair in
            URL(fileURLWithPath: pair.original).standardizedFileURL.path
        })

        for index in record.filePairs.indices {
            let pair = record.filePairs[index]
            if states[index].status == .restored { continue }

            guard let restoreRoot = restoreScopeRoot(
                for: pair,
                allowedRoots: allowedRestoreRoots
            ) else {
                skipped += 1
                if firstFailure == nil {
                    firstFailure = .destinationOutsideAllowedScope(path: pair.original)
                }
                continue
            }

            let originalURL = URL(fileURLWithPath: pair.original)

            switch validatedRecoveryState(for: pair) {
            case .missing:
                skipped += 1
                states[index] = Record.RecoveryState(status: .missing)
                if firstFailure == nil {
                    firstFailure = .trashedItemMissing(path: pair.trashed)
                }
                continue
            case .identityChanged:
                skipped += 1
                states[index] = Record.RecoveryState(status: .identityChanged)
                if firstFailure == nil {
                    firstFailure = .trashedItemIdentityChanged(path: pair.trashed)
                }
                continue
            case .unavailable, .checking:
                skipped += 1
                states[index] = Record.RecoveryState(status: .unavailable)
                if firstFailure == nil {
                    firstFailure = .trashedItemIdentityUnavailable(path: pair.trashed)
                }
                continue
            case .available:
                states[index] = Record.RecoveryState(status: .available)
            case .restored:
                continue
            }

            var destinationURL = originalURL
            switch pathEntryProbe(atPath: pair.original) {
            case .present:
                switch conflictPolicy {
                case .skipExisting:
                    skipped += 1
                    if firstFailure == nil {
                        firstFailure = .destinationAlreadyExists(path: pair.original)
                    }
                    continue
                case .restoreWithUniqueName:
                    guard let uniqueDestination = availableRecoveryDestination(
                        for: originalURL,
                        reservedDestinations: reservedDestinations,
                        locale: locale
                    ) else {
                        skipped += 1
                        if firstFailure == nil {
                            firstFailure = .destinationUnavailable(path: pair.original)
                        }
                        continue
                    }
                    destinationURL = uniqueDestination
                    reservedDestinations.insert(destinationURL.standardizedFileURL.path)
                }
            case .absent:
                break
            case .unavailable:
                skipped += 1
                if firstFailure == nil {
                    firstFailure = .destinationUnavailable(path: pair.original)
                }
                continue
            }

            switch secureRestore(
                pair: pair,
                destinationPath: destinationURL.path,
                restoreScopeRoot: restoreRoot,
                beforeRenameHook: beforeRenameHook
            ) {
            case .moved:
                restored += 1
                if destinationURL != originalURL { renamed += 1 }
                states[index] = Record.RecoveryState(
                    status: .restored,
                    restoredDestination: destinationURL.path
                )
                // v2026.10.08: a conflict rename restores only the actual destination.
                // Publishing the original path would revive a different occupied object and
                // incorrectly clear that path's deletion tombstone in scan consumers.
                restoredPaths.append(destinationURL.path)
                restoredOriginalPaths.append(pair.original)
            case .sourceMissing:
                skipped += 1
                states[index] = Record.RecoveryState(status: .missing)
                if firstFailure == nil {
                    firstFailure = .trashedItemMissing(path: pair.trashed)
                }
            case .sourceIdentityChanged:
                skipped += 1
                states[index] = Record.RecoveryState(status: .identityChanged)
                if firstFailure == nil {
                    firstFailure = .trashedItemIdentityChanged(path: pair.trashed)
                }
            case .sourceUnavailable:
                skipped += 1
                states[index] = Record.RecoveryState(status: .unavailable)
                if firstFailure == nil {
                    firstFailure = .trashedItemIdentityUnavailable(path: pair.trashed)
                }
            case .destinationExists:
                skipped += 1
                if firstFailure == nil {
                    firstFailure = .destinationAlreadyExists(path: destinationURL.path)
                }
            case .destinationParentUnavailable(let detail):
                skipped += 1
                if firstFailure == nil {
                    firstFailure = .createDestinationDirectoryFailed(
                        systemDescription: detail
                    )
                }
            case .moveFailed(let detail):
                skipped += 1
                if firstFailure == nil {
                    firstFailure = .moveFailed(systemDescription: detail)
                }
            }
        }

        return RestoreExecution(
            result: RestoreResult(
                restoredCount: restored,
                skippedCount: skipped,
                renamedCount: renamed,
                firstFailure: firstFailure,
                restoredPaths: restoredPaths,
                restoredOriginalPaths: restoredOriginalPaths
            ),
            recoveryStates: states,
            restoredPaths: restoredPaths
        )
    }

    nonisolated private static func normalizedRecoveryStates(
        for record: Record
    ) -> [Record.RecoveryState] {
        guard record.recoveryStates.count == record.filePairs.count else {
            return record.filePairs.map { pair in
                Record.RecoveryState(
                    status: pair.trashedIdentity == nil ? .unavailable : .checking
                )
            }
        }
        return record.recoveryStates
    }

    /// Refresh only needs to revalidate the Trash-side frozen identity. Reusing
    /// `buildRestorePreparation` also probed every destination and conflict on each page open,
    /// multiplying filesystem work and making cancellation coarse. Keep this projection narrow
    /// and check cancellation on both sides of the deterministic test hook and every `lstat`.
    nonisolated private static func probeRecoveryStates(
        for record: Record,
        probeHook: (@Sendable (String) -> Void)?
    ) -> [Record.RecoveryState]? {
        var states = normalizedRecoveryStates(for: record)
        for index in record.filePairs.indices {
            guard !Task.isCancelled else { return nil }
            if states[index].status == .restored { continue }

            let pair = record.filePairs[index]
            probeHook?(pair.trashed)
            guard !Task.isCancelled else { return nil }

            let status = validatedRecoveryState(for: pair)
            guard !Task.isCancelled else { return nil }
            states[index] = Record.RecoveryState(status: status)
        }
        return states
    }

    /// A terminal restored fact is monotonic. A slower refresh/prepare probe may update any other
    /// state, but it can never turn a completed restore back into missing/available.
    nonisolated private static func mergingObservedStates(
        current: [Record.RecoveryState],
        observed: [Record.RecoveryState]
    ) -> [Record.RecoveryState] {
        guard current.count == observed.count else { return observed }
        return zip(current, observed).map { currentState, observedState in
            currentState.status == .restored ? currentState : observedState
        }
    }

    nonisolated private static func validatedRecoveryState(
        for pair: Record.FilePair
    ) -> Record.RecoveryStatus {
        guard let expected = pair.trashedIdentity else { return .unavailable }
        switch Record.probeIdentity(atPath: pair.trashed) {
        case .present(let current):
            // Migrated three-field identities intentionally match a stronger current probe by
            // the discriminators that were actually persisted. Full Equatable would reject every
            // legacy restorable item merely because optional birthtime/generation are now known.
            // Cross-reboot mount renumbering is accepted when full kernel discriminators match.
            return expected.matchesAllowingMountDeviceRebase(current) ? .available : .identityChanged
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    /// 为冲突恢复分配同目录下的唯一名称；只检查候选路径，不移动现有项目。
    nonisolated private static func availableRecoveryDestination(
        for originalURL: URL,
        reservedDestinations: Set<String>,
        locale: Locale
    ) -> URL? {
        let parent = originalURL.deletingLastPathComponent()
        let pathExtension = originalURL.pathExtension
        let stem = pathExtension.isEmpty
            ? originalURL.lastPathComponent
            : originalURL.deletingPathExtension().lastPathComponent
        let recovered = AppLocalization.string("undo.restore.recovered_suffix", locale: locale)
        var sequence = 1

        while true {
            let marker = sequence == 1 ? recovered : "\(recovered) \(sequence)"
            let name = pathExtension.isEmpty
                ? "\(stem) (\(marker))"
                : "\(stem) (\(marker)).\(pathExtension)"
            let candidate = parent.appendingPathComponent(name)
            if !reservedDestinations.contains(candidate.standardizedFileURL.path) {
                switch pathEntryProbe(atPath: candidate.path) {
                case .absent:
                    return candidate
                case .present:
                    break
                case .unavailable:
                    return nil
                }
            }
            sequence += 1
        }
    }

    private enum PathEntryProbe: Equatable, Sendable {
        case present
        case absent
        case unavailable
    }

    /// `FileManager.fileExists` follows symlinks and reports a broken symlink as absent. Recovery
    /// must distinguish every existing directory entry from a genuinely absent path, while probe
    /// errors fail closed instead of being guessed as either state.
    nonisolated private static func pathEntryProbe(atPath path: String) -> PathEntryProbe {
        var metadata = stat()
        errno = 0
        if lstat(path, &metadata) == 0 { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .unavailable
    }

    nonisolated private static func restoreScopeRoot(
        for pair: Record.FilePair,
        allowedRoots: [String]
    ) -> String? {
        let destination = TrashPipeline.normalizePath(pair.original)
        guard destination.hasPrefix("/") else { return nil }
        if let declared = pair.restoreScopeRoot.map(TrashPipeline.normalizePath) {
            guard allowedRoots.contains(declared),
                  destination.hasPrefix(declared == "/" ? "/" : declared + "/") else {
                return nil
            }
            return declared
        }
        return allowedRoots.first { root in
            destination.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }

    private enum SecureRestoreResult: Sendable {
        case moved
        case sourceMissing
        case sourceIdentityChanged
        case sourceUnavailable
        case destinationExists
        case destinationParentUnavailable(String)
        case moveFailed(String)
    }

    /// `renameatx_np(RENAME_EXCL)` is the no-replace commit boundary. Directory descriptors keep
    /// the authorized destination parent chain anchored even if pathnames are swapped after the
    /// plan was shown. Darwin has no rename-by-source-fd API; the remaining source-name window is
    /// narrowed to adjacent fstatat/renameatx_np and checked again at the destination, with a
    /// best-effort no-replace rollback on mismatch.
    nonisolated private static func secureRestore(
        pair: Record.FilePair,
        destinationPath: String,
        restoreScopeRoot: String,
        beforeRenameHook: (@Sendable () -> Void)?
    ) -> SecureRestoreResult {
        guard let expected = pair.trashedIdentity else { return .sourceUnavailable }
        let sourceURL = URL(fileURLWithPath: pair.trashed).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let sourceName = sourceURL.lastPathComponent
        let destinationName = destinationURL.lastPathComponent
        guard validLeafName(sourceName), validLeafName(destinationName) else {
            return .moveFailed("invalid leaf name")
        }

        // Probe the authorized scope root's current mount device first so destination parent
        // validation remains anchored even if the source in .Trash is missing. When the volume
        // was remounted across a reboot, scopeRoot and source share the current mount device.
        var rootStat = stat()
        let currentScopeDevice: UInt64
        if lstat(TrashPipeline.normalizePath(restoreScopeRoot), &rootStat) == 0 {
            currentScopeDevice = UInt64(bitPattern: Int64(rootStat.st_dev))
        } else {
            currentScopeDevice = expected.device
        }
        let targetMountDevice = expected.birthTimeSeconds != nil
            && expected.birthTimeNanoseconds != nil
            && expected.generation != nil
            ? currentScopeDevice
            : expected.device

        guard let destinationParentFD = openDestinationParent(
            scopeRoot: restoreScopeRoot,
            destinationParent: destinationURL.deletingLastPathComponent().path,
            expectedDevice: targetMountDevice
        ) else {
            return .destinationParentUnavailable("destination parent validation failed")
        }
        defer { Darwin.close(destinationParentFD) }

        let sourceParentPath = sourceURL.deletingLastPathComponent().path
        let sourceParentFD = sourceParentPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceParentFD >= 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .sourceMissing : .sourceUnavailable
        }
        defer { Darwin.close(sourceParentFD) }

        var sourceMetadata = stat()
        let sourceProbe = sourceName.withCString {
            fstatat(sourceParentFD, $0, &sourceMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceProbe == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .sourceMissing : .sourceUnavailable
        }
        let observedSource = TrashObjectIdentity(metadata: sourceMetadata)
        guard expected.matchesAllowingMountDeviceRebase(observedSource),
              observedSource.device == targetMountDevice else {
            return .sourceIdentityChanged
        }

        beforeRenameHook?()

        let renameResult = sourceName.withCString { sourceLeaf in
            destinationName.withCString { destinationLeaf in
                renameatx_np(
                    sourceParentFD,
                    sourceLeaf,
                    destinationParentFD,
                    destinationLeaf,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            let code = errno
            if code == EEXIST { return .destinationExists }
            if code == ENOENT || code == ENOTDIR { return .sourceMissing }
            let detail = String(cString: strerror(code))
            GSYLog.error(.trash, "UndoHistory renameatx_np 失败 errno=\(code) detail=\(detail)")
            return .moveFailed(detail)
        }

        var destinationMetadata = stat()
        let destinationProbe = destinationName.withCString {
            fstatat(destinationParentFD, $0, &destinationMetadata, AT_SYMLINK_NOFOLLOW)
        }
        let observedDestination = TrashObjectIdentity(metadata: destinationMetadata)
        guard destinationProbe == 0,
              expected.matchesAllowingMountDeviceRebase(observedDestination),
              observedDestination.device == targetMountDevice else {
            let rollback = destinationName.withCString { destinationLeaf in
                sourceName.withCString { sourceLeaf in
                    renameatx_np(
                        destinationParentFD,
                        destinationLeaf,
                        sourceParentFD,
                        sourceLeaf,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            GSYLog.error(
                .trash,
                "UndoHistory post-rename identity mismatch rollback=\(rollback == 0 ? "ok" : "failed") errno=\(errno)"
            )
            return .sourceIdentityChanged
        }
        return .moved
    }

    nonisolated private static func validLeafName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && name.utf8.count <= Int(NAME_MAX)
    }

    /// Opens/creates each destination directory relative to the authorized root. `O_NOFOLLOW`
    /// rejects a symlink at every traversed component, and the device check prevents a newly
    /// mounted subtree from expanding the deletion-time scope.
    nonisolated private static func openDestinationParent(
        scopeRoot: String,
        destinationParent: String,
        expectedDevice: UInt64
    ) -> Int32? {
        let root = TrashPipeline.normalizePath(scopeRoot)
        let parent = TrashPipeline.normalizePath(destinationParent)
        guard parent == root || parent.hasPrefix(root == "/" ? "/" : root + "/") else {
            return nil
        }
        var currentFD = root.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard currentFD >= 0 else { return nil }

        func directoryMatchesDevice(_ descriptor: Int32) -> Bool {
            var metadata = stat()
            return fstat(descriptor, &metadata) == 0
                && UInt64(bitPattern: Int64(metadata.st_dev)) == expectedDevice
        }
        guard directoryMatchesDevice(currentFD) else {
            Darwin.close(currentFD)
            return nil
        }

        let relative: String
        if parent == root {
            relative = ""
        } else if root == "/" {
            relative = String(parent.dropFirst())
        } else {
            relative = String(parent.dropFirst(root.count + 1))
        }
        for component in relative.split(separator: "/").map(String.init) {
            guard validLeafName(component) else {
                Darwin.close(currentFD)
                return nil
            }
            var nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if nextFD < 0, errno == ENOENT {
                let made = component.withCString { mkdirat(currentFD, $0, S_IRWXU) }
                if made != 0, errno != EEXIST {
                    Darwin.close(currentFD)
                    return nil
                }
                nextFD = component.withCString {
                    openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            guard nextFD >= 0, directoryMatchesDevice(nextFD) else {
                if nextFD >= 0 { Darwin.close(nextFD) }
                Darwin.close(currentFD)
                return nil
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    /// 公开 storeURL 供测试断言（@MainActor 可见即可）。
    public var underlyingStoreURL: URL { storeURL }

    // MARK: - Persistence

    /// Durable watermark for the retained legacy pathname. The old file cannot be deleted safely,
    /// so absence from current visible history (LRU eviction or a future explicit clear) must be
    /// distinguishable from "never imported". Observed IDs are tombstones as well as import
    /// watermarks: unchanged old facts are not resurrected, while genuinely new IDs still arrive.
    private struct LegacyReconciliationState: Codable, Equatable, Sendable {
        var observedRecordIDs: Set<UUID>
        var observedReceiptIDs: Set<String>

        nonisolated static let empty = LegacyReconciliationState(
            observedRecordIDs: [],
            observedReceiptIDs: []
        )
    }

    private struct HistoryEnvelope: Codable, Equatable, Sendable {
        let schemaVersion: Int
        var records: [Record]
        /// A commit receipt survives visible-history LRU trimming. If the App dies after the
        /// Undo file is fsynced but before the completion journal is acknowledged, replay still
        /// remains idempotent instead of resurrecting an old record.
        var committedJournalIDs: [String: Date]
        var legacyReconciliation: LegacyReconciliationState

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, records, committedJournalIDs, legacyReconciliation
        }

        init(
            schemaVersion: Int,
            records: [Record],
            committedJournalIDs: [String: Date],
            legacyReconciliation: LegacyReconciliationState = .empty
        ) {
            self.schemaVersion = schemaVersion
            self.records = records
            self.committedJournalIDs = committedJournalIDs
            self.legacyReconciliation = legacyReconciliation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            records = try container.decode([Record].self, forKey: .records)
            committedJournalIDs = try container.decodeIfPresent(
                [String: Date].self,
                forKey: .committedJournalIDs
            ) ?? [:]
            legacyReconciliation = try container.decodeIfPresent(
                LegacyReconciliationState.self,
                forKey: .legacyReconciliation
            ) ?? .empty
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(records, forKey: .records)
            try container.encode(committedJournalIDs, forKey: .committedJournalIDs)
            try container.encode(legacyReconciliation, forKey: .legacyReconciliation)
        }

        nonisolated static let empty = HistoryEnvelope(
            schemaVersion: 4,
            records: [],
            committedJournalIDs: [:]
        )
    }

    private struct LoadedHistory: Sendable {
        let envelope: HistoryEnvelope
        let state: StorageState
        let requiresPersistenceMigration: Bool
        /// Exact canonical bytes/version read during the same flock epoch. Mutators pass this
        /// directly to the WAL writer so ordinary RMW does not reread/materialize the JSON.
        let canonicalSnapshot: FrozenDestinationEnvelope?
        /// Recovered once at the beginning of this anchored lock epoch. Passing it into persist
        /// avoids a second marker recovery and repeated full reads of both WAL slots.
        let transactionState: LegacyMigrationTransactionState?

        init(
            envelope: HistoryEnvelope,
            state: StorageState,
            requiresPersistenceMigration: Bool = false,
            canonicalSnapshot: FrozenDestinationEnvelope? = nil,
            transactionState: LegacyMigrationTransactionState? = nil
        ) {
            self.envelope = envelope
            self.state = state
            self.requiresPersistenceMigration = requiresPersistenceMigration
            self.canonicalSnapshot = canonicalSnapshot
            self.transactionState = transactionState
        }
    }

    private struct PersistedHistory: Sendable {
        let envelope: HistoryEnvelope
        let state: StorageState
        var succeeded: Bool { state == .ready }
    }

    private enum HistoryWALRecoveryResult {
        case ready(LegacyMigrationTransactionState?)
        case failed(StorageState)
    }

    nonisolated private static let maximumCommittedJournalIDs = 50_000
    /// Never prune these tombstones silently: doing so would allow a retained stale legacy
    /// snapshot to resurrect records/receipts. Crossing the bound is a typed storage failure.
    nonisolated private static let maximumLegacyReconciliationIDs = 50_000

    /// MainActor captures only an immutable value snapshot. Every read/decode/flock/RMW/encode,
    /// fsync and rename runs on the persistence queue (or the explicit synchronous test mode).
    private func saveHistory() {
        let snapshot = history
        let url = storeURL
        let limit = maxHistoryCount
        let mutationHook = persistenceMutationHookForTesting
        persistenceRevision &+= 1
        let revision = persistenceRevision
        switch saveStrategy {
        case .synchronous:
            mutationHook?("snapshot")
            applyPersistedHistory(Self.mergeAndPersist(
                incoming: snapshot,
                to: url,
                maxHistoryCount: limit
            ), revision: revision)
        case .background:
            persistenceQueue.async { [weak self] in
                mutationHook?("snapshot")
                let persisted = Self.mergeAndPersist(
                    incoming: snapshot,
                    to: url,
                    maxHistoryCount: limit
                )
                Task { @MainActor [weak self] in
                    self?.applyPersistedHistory(persisted, revision: revision)
                }
            }
        }
    }

    /// Merges exact callback facts under a stable cross-process lock. Success means the new
    /// envelope and its commit receipts have crossed fsync + atomic rename; callers may then
    /// acknowledge the completion journal and pending-operation ledger.
    @discardableResult
    func addJournalEntriesDurably(
        source: String,
        entries: [TrashUndoJournalEntry]
    ) async -> Bool {
        guard !entries.isEmpty else { return true }
        let url = storeURL
        let limit = maxHistoryCount
        let mutationHook = persistenceMutationHookForTesting
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let queue = persistenceQueue
        let persisted = await withCheckedContinuation { continuation in
            queue.async {
                mutationHook?("journal")
                continuation.resume(returning: Self.mergeJournalEntriesAndPersist(
                    source: source,
                    entries: entries,
                    to: url,
                    maxHistoryCount: limit
                ))
            }
        }
        applyPersistedHistory(persisted, revision: revision)
        return persisted.succeeded
    }

    func reportCompletionJournalFailure(
        blockedAttempts: Set<TrashPendingAttemptIdentity>? = nil
    ) {
        if let blockedAttempts, !blockedAttempts.isEmpty {
            blockedCompletionJournalAttempts.formUnion(blockedAttempts)
        } else {
            completionJournalAuthorityUnavailable = true
        }
        updateCompletionJournalState()
    }

    /// v2026.07.18 P2: storage-unavailable callback settlement is neither stale nor a durable
    /// ledger block yet. Keep its exact generation independently until retry reaches a terminal
    /// durable transition; authoritative empty ledger snapshots cannot clear this set.
    func reportCompletionJournalSettlementPending(
        attempts: Set<TrashPendingAttemptIdentity>,
        revision: Int
    ) {
        for attempt in attempts {
            let previous = completionJournalSettlementRevisions[attempt] ?? Int.min
            guard revision >= previous else { continue }
            completionJournalSettlementRevisions[attempt] = revision
            locallyUnsettledCompletionAttempts.insert(attempt)
        }
        updateCompletionJournalState()
    }

    func resolveCompletionJournalSettlement(
        attempts: Set<TrashPendingAttemptIdentity>,
        durablyBlocked: Bool,
        revision: Int = .max
    ) {
        for attempt in attempts {
            let previous = completionJournalSettlementRevisions[attempt] ?? Int.min
            guard revision >= previous else { continue }
            completionJournalSettlementRevisions[attempt] = revision
            locallyUnsettledCompletionAttempts.remove(attempt)
            if durablyBlocked {
                blockedCompletionJournalAttempts.insert(attempt)
            }
        }
        updateCompletionJournalState()
    }

    /// Eviction is safe only after `TrashCompletionHealthTransitionQueue` has executed every
    /// predecessor (or while executing its current terminal block). At that point no older
    /// non-structured pending projection can still arrive. Revisions therefore remain bounded by
    /// currently unsettled exact attempts instead of growing with lifetime deletion count.
    func retireCompletionJournalSettlementRevisions(
        attempts: Set<TrashPendingAttemptIdentity>
    ) {
        for attempt in attempts where !locallyUnsettledCompletionAttempts.contains(attempt) {
            completionJournalSettlementRevisions.removeValue(forKey: attempt)
        }
    }

    var completionJournalSettlementRevisionCountForTesting: Int {
        completionJournalSettlementRevisions.count
    }

    /// One token represents the complete journal -> ledger recovery boundary. The state remains
    /// blocked throughout the async replay even when both stores initially appear empty.
    func beginCompletionJournalRecovery() -> UUID {
        let token = UUID()
        activeCompletionJournalRecoveries.insert(token)
        updateCompletionJournalState()
        return token
    }

    func finishCompletionJournalRecovery(
        token: UUID,
        blockedAttempts: Set<TrashPendingAttemptIdentity>?,
        reachedSuccessfulEmptyTerminal: Bool
    ) {
        guard activeCompletionJournalRecoveries.remove(token) != nil else { return }
        if reachedSuccessfulEmptyTerminal, let blockedAttempts {
            blockedCompletionJournalAttempts = blockedAttempts
            completionJournalAuthorityUnavailable = false
        } else {
            if let blockedAttempts {
                blockedCompletionJournalAttempts.formUnion(blockedAttempts)
            }
            completionJournalAuthorityUnavailable = true
        }
        updateCompletionJournalState()
    }

    /// Replace the projection only from one complete ledger snapshot. Nil explicitly means the
    /// authority could not be inspected and therefore cannot clear any previously known block.
    func synchronizeCompletionJournalAuthority(
        blockedAttempts: Set<TrashPendingAttemptIdentity>?
    ) {
        guard let blockedAttempts else {
            completionJournalAuthorityUnavailable = true
            updateCompletionJournalState()
            return
        }
        blockedCompletionJournalAttempts = blockedAttempts
        completionJournalAuthorityUnavailable = false
        updateCompletionJournalState()
    }

    private func updateCompletionJournalState() {
        completionJournalState = completionJournalAuthorityUnavailable
            || !blockedCompletionJournalAttempts.isEmpty
            || !locallyUnsettledCompletionAttempts.isEmpty
            || !activeCompletionJournalRecoveries.isEmpty
            ? .blocked
            : .ready
    }

    /// The journal row remains durably marked `receiptPrunePending` while this RMW removes its
    /// crash-window receipt. Only after success may the caller remove that last journal evidence.
    func acknowledgeCompletionJournal(ids: Set<String>) async -> Bool {
        guard !ids.isEmpty else { return true }
        let url = storeURL
        let mutationHook = persistenceMutationHookForTesting
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let queue = persistenceQueue
        let persisted = await withCheckedContinuation { continuation in
            queue.async {
                mutationHook?("receipt")
                continuation.resume(returning: Self.pruneCommittedJournalIDs(ids, at: url))
            }
        }
        applyPersistedHistory(persisted, revision: revision)
        // Receipt pruning is pair-local cleanup. It carries no authority over other operation
        // generations and therefore must never clear the ledger-derived health projection.
        return persisted.succeeded
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
        let limit = maxHistoryCount
        let mutationHook = persistenceMutationHookForTesting
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let persisted = persistenceQueue.sync {
            mutationHook?("snapshot")
            return Self.mergeAndPersist(
                incoming: records,
                to: url,
                maxHistoryCount: limit
            )
        }
        applyPersistedHistory(persisted, revision: revision)
    }

    /// Single MainActor publication boundary for the wide immutable history projection.
    /// Increment unconditionally: callers already own an authoritative transition, and avoiding
    /// an O(total filePairs) equality check is the reason this revision exists.
    private func publishHistory(_ records: [Record]) {
        historyRevision &+= 1
        history = records
    }

    private func applyLoadedHistory(_ loaded: LoadedHistory) {
        if loaded.state == .ready || history.isEmpty {
            publishHistory(loaded.envelope.records)
        }
        storageState = loaded.state
        GSYLog.info(
            .trash,
            "undo_history.bootstrap.finish state=\(Self.storageStateDiagnosticLabel(loaded.state)) records=\(loaded.envelope.records.count) receipts=\(loaded.envelope.committedJournalIDs.count) migration=\(loaded.requiresPersistenceMigration)"
        )
    }

    /// Stable, non-localized diagnostic token. Raw paths and decoded record contents remain in
    /// the private durable store and never enter the log line.
    nonisolated private static func storageStateDiagnosticLabel(_ state: StorageState) -> String {
        switch state {
        case .loading: return "loading"
        case .ready: return "ready"
        case .readFailed: return "read-failed"
        case .corrupt: return "corrupt"
        case .storeTooLarge: return "store-too-large"
        case .recordRejected: return "record-rejected"
        case .writeFailed: return "write-failed"
        }
    }

    nonisolated private static func prepareBootstrapApplication(
        _ loaded: LoadedHistory,
        current: [Record],
        maxHistoryCount: Int
    ) -> LoadedHistory {
        guard loaded.state == .ready, !current.isEmpty else { return loaded }
        guard let merged = mergeRecordSnapshots(
            disk: loaded.envelope.records,
            incoming: current,
            maxHistoryCount: maxHistoryCount
        ) else {
            return LoadedHistory(envelope: loaded.envelope, state: .corrupt)
        }
        var envelope = loaded.envelope
        envelope.records = merged
        return LoadedHistory(
            envelope: envelope,
            state: .ready,
            requiresPersistenceMigration: loaded.requiresPersistenceMigration
        )
    }

    private func applyPersistedHistory(
        _ persisted: PersistedHistory,
        revision: UInt64
    ) {
        persistencePublicationHookForTesting?(revision)
        // v2026.07.18 P2 publication ordering fix: issuing a newer mutation immediately revokes
        // every older completion's authority, even while that newer write is still queued. Letting
        // an older success publish here can erase the newer in-memory record permanently when the
        // newest write later fails.
        guard revision == persistenceRevision,
              revision >= appliedPersistenceRevision else { return }
        appliedPersistenceRevision = revision
        storageState = persisted.state
        guard persisted.succeeded else { return }
        publishHistory(Self.preservingResolvedRecoveryStates(
            persisted.envelope.records,
            current: history
        ))
    }

    nonisolated private static func preservingResolvedRecoveryStates(
        _ records: [Record],
        current: [Record]
    ) -> [Record] {
        guard !current.isEmpty else { return records }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return records.map { record in
            guard let existing = currentByID[record.id] else { return record }
            var mergedStates = record.recoveryStates
            var didChange = false
            for index in record.filePairs.indices {
                guard index < mergedStates.count,
                      mergedStates[index].status == .checking,
                      index < existing.filePairs.count,
                      index < existing.recoveryStates.count else { continue }
                let incomingPair = record.filePairs[index]
                let existingPair = existing.filePairs[index]
                let existingState = existing.recoveryStates[index]
                guard existingState.status != .checking,
                      TrashPipeline.normalizePath(incomingPair.original)
                        == TrashPipeline.normalizePath(existingPair.original),
                      TrashPipeline.normalizePath(incomingPair.trashed)
                        == TrashPipeline.normalizePath(existingPair.trashed),
                      incomingPair.trashedIdentity == existingPair.trashedIdentity else {
                    continue
                }
                mergedStates[index] = existingState
                didChange = true
            }
            guard didChange else { return record }
            return Record(
                id: record.id,
                timestamp: record.timestamp,
                source: record.source,
                filePairs: record.filePairs,
                recoveryStates: mergedStates,
                journalOperationID: record.journalOperationID
            )
        }
    }

    nonisolated private static func bootstrapHistory(
        storeURL: URL,
        legacyStoreURL: URL?,
        maxHistoryCount: Int,
        fileManager: FileManager
    ) -> LoadedHistory {
        if let legacyStoreURL {
            let migration = migrateLegacyStoreIfNeeded(
                from: legacyStoreURL,
                to: storeURL,
                fileManager: fileManager,
                maxHistoryCount: maxHistoryCount
            )
            if case .rejected(let state) = migration {
                // v2026.07.19 P1 state-contract fix: a retained legacy file plus failed migration
                // is not evidence of "no history". Surface the typed storage state and let the
                // next bootstrap retry; never continue into a missing destination as `.ready`.
                return LoadedHistory(envelope: .empty, state: state)
            }
        }
        let loaded = withHistoryLock(for: storeURL) { parentDescriptor in
            let loaded = readEnvelope(
                from: storeURL,
                parentDescriptor: parentDescriptor
            )
            guard loaded.state == .ready, loaded.requiresPersistenceMigration else {
                return loaded
            }
            let persisted = persistEnvelope(
                loaded.envelope,
                to: storeURL,
                destinationSnapshot: loaded.canonicalSnapshot,
                transactionState: loaded.transactionState,
                parentDescriptor: parentDescriptor
            )
            return LoadedHistory(envelope: persisted.envelope, state: persisted.state)
        } ?? LoadedHistory(envelope: .empty, state: .writeFailed)
        guard loaded.state == .ready else { return loaded }
        var envelope = loaded.envelope
        // Array order is the durable LRU order. Legacy ISO-8601 dates have one-second precision,
        // so re-sorting equal timestamps by UUID would randomly reshuffle same-second actions.
        envelope.records = Array(envelope.records.prefix(maxHistoryCount))
        return LoadedHistory(envelope: envelope, state: .ready)
    }

    nonisolated private static func encodeHistory(_ envelope: HistoryEnvelope) -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(envelope)
        } catch {
            GSYLog.error(.trash, "UndoHistory encode 失败 err=\(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func decodeHistory(_ data: Data) -> [Record]? {
        decodeEnvelope(data)?.records
    }

    nonisolated private static func decodeEnvelope(_ data: Data) -> HistoryEnvelope? {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let envelope = try decoder.decode(HistoryEnvelope.self, from: data)
                if envelope.schemaVersion == 2
                    || envelope.schemaVersion == 3
                    || envelope.schemaVersion == 4 {
                    return envelope
                }
            } catch {
                // A raw Record array is the documented schema-1 representation. Failure of this
                // explicit schema-2 probe is expected during migration and is not discarded as a
                // business error; the legacy decoder below remains the authoritative result.
            }
            // Schema 1 was the raw Record array. It is upgraded only during the next locked
            // write; a failed migration never destroys the readable legacy payload.
            let records = try decoder.decode([Record].self, from: data)
            return HistoryEnvelope(
                schemaVersion: 1,
                records: records,
                committedJournalIDs: [:]
            )
        } catch {
            GSYLog.error(.trash, "UndoHistory decode 失败 err=\(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func readEnvelope(
        from url: URL,
        parentDescriptor: Int32
    ) -> LoadedHistory {
        // Contract: every App call site reaches this helper only while `withHistoryLock` owns the
        // stable flock. Recover/finalize a prior bounded WAL generation before reading canonical
        // bytes; non-cooperating readers are outside that lock and are never promised atomic view.
        let transactionState: LegacyMigrationTransactionState?
        switch recoverHistoryWALIfNeeded(
            destinationName: url.standardizedFileURL.lastPathComponent,
            parentDescriptor: parentDescriptor
        ) {
        case .ready(let recovered):
            transactionState = recovered
        case .failed(let recoveryState):
            return LoadedHistory(envelope: .empty, state: recoveryState)
        }
        let destination = url.standardizedFileURL
        let data: Data
        let canonicalFingerprint: LegacyMigrationFingerprint
        switch readLegacyMigrationEntry(
            parentDescriptor: parentDescriptor,
            name: destination.lastPathComponent
        ) {
        case .absent:
            let emptySnapshot = FrozenDestinationEnvelope(
                envelope: .empty,
                fingerprint: nil,
                versionEvidence: nil,
                data: nil,
                requiresPersistenceMigration: false
            )
            return LoadedHistory(
                envelope: .empty,
                state: .ready,
                canonicalSnapshot: emptySnapshot,
                transactionState: transactionState
            )
        case .failed(let reason, let code):
            GSYLog.error(
                .trash,
                "UndoHistory frozen read failed reason=\(reason) errno="
                    + "\(code.map(String.init) ?? "none")"
            )
            return code == EFBIG
                ? LoadedHistory(
                    envelope: .empty,
                    state: .storeTooLarge(maxBytes: maximumStoreBytes)
                )
                : LoadedHistory(envelope: .empty, state: .readFailed)
        case .present(let fingerprint, let bytes):
            guard fingerprint.ownerID == UInt32(geteuid()) else {
                return LoadedHistory(envelope: .empty, state: .readFailed)
            }
            canonicalFingerprint = fingerprint
            data = bytes
        }
        guard let decoded = decodeEnvelope(data) else {
            return LoadedHistory(envelope: .empty, state: .corrupt)
        }
        if decoded.records.contains(where: {
            $0.filePairs.count > maximumPairsPerRecord
        }) {
            return LoadedHistory(
                envelope: .empty,
                state: .recordRejected(maxPairs: maximumPairsPerRecord)
            )
        }
        guard let migrated = migrateLegacyJournalIdentifiers(decoded),
              validate(migrated.envelope) else {
            return LoadedHistory(envelope: .empty, state: .corrupt)
        }
        return LoadedHistory(
            envelope: migrated.envelope,
            state: .ready,
            requiresPersistenceMigration: migrated.changed,
            canonicalSnapshot: FrozenDestinationEnvelope(
                envelope: migrated.envelope,
                fingerprint: canonicalFingerprint,
                versionEvidence: LegacyMigrationVersionEvidence(
                    fingerprint: canonicalFingerprint,
                    data: data
                ),
                data: data,
                requiresPersistenceMigration: migrated.changed
            ),
            transactionState: transactionState
        )
    }

    nonisolated private static func recoverHistoryWALIfNeeded(
        destinationName: String,
        parentDescriptor: Int32
    ) -> HistoryWALRecoveryResult {
        guard validLeafName(destinationName) else { return .failed(.writeFailed) }
        switch loadLegacyMigrationTransactionState(
            parentDescriptor: parentDescriptor,
            destinationName: destinationName
        ) {
        case .absent:
            return .ready(nil)
        case .rejected(let reason, let code):
            GSYLog.error(
                .trash,
                "undo_history.wal.recovery rejected reason=\(reason) errno="
                    + "\(code.map(String.init) ?? "none")"
            )
            return .failed(.writeFailed)
        case .loaded(let state):
            switch recoverLegacyMigrationTransaction(
                state,
                parentDescriptor: parentDescriptor
            ) {
            case .ready(let recovered), .committed(let recovered):
                return .ready(recovered)
            case .rejected(let reason, let code):
                GSYLog.error(
                    .trash,
                    "undo_history.wal.recovery rejected reason=\(reason) errno="
                        + "\(code.map(String.init) ?? "none")"
                )
                return .failed(.writeFailed)
            }
        }
    }

    nonisolated private static func validate(_ envelope: HistoryEnvelope) -> Bool {
        guard envelope.schemaVersion == 4,
              envelope.committedJournalIDs.count <= maximumCommittedJournalIDs,
              envelope.committedJournalIDs.keys.allSatisfy(TrashUndoJournalEntry.isOpaqueID),
              envelope.legacyReconciliation.observedRecordIDs.count
                <= maximumLegacyReconciliationIDs,
              envelope.legacyReconciliation.observedReceiptIDs.count
                <= maximumLegacyReconciliationIDs,
              envelope.legacyReconciliation.observedReceiptIDs
                .allSatisfy(TrashUndoJournalEntry.isOpaqueID) else {
            return false
        }
        var seenRecordIDs = Set<UUID>()
        var seenJournalIDs = Set<String>()
        for record in envelope.records {
            guard seenRecordIDs.insert(record.id).inserted,
                  record.fileCount == record.filePairs.count,
                  record.filePairs.count <= maximumPairsPerRecord,
                  record.recoveryStates.count == record.filePairs.count else { return false }
            for pair in record.filePairs {
                guard pair.original.utf8.count <= maximumPathBytes,
                      pair.trashed.utf8.count <= maximumPathBytes,
                      (pair.restoreScopeRoot?.utf8.count ?? 0) <= maximumPathBytes else {
                    return false
                }
                if let journalID = pair.journalID {
                    // One callback receipt identifies exactly one operation/path fact. Reusing it
                    // across pairs is corruption, even when the JSON otherwise decodes cleanly.
                    guard let operationID = record.journalOperationID,
                          let attemptID = pair.journalAttemptID,
                          TrashUndoJournalEntry.validatesOpaqueID(
                            journalID,
                            operationID: operationID,
                            attemptID: attemptID,
                            originalPath: pair.original,
                            trashedPath: pair.trashed
                          ),
                          seenJournalIDs.insert(journalID).inserted else { return false }
                } else if pair.journalAttemptID != nil {
                    return false
                }
            }
        }
        // A durable receipt and a visible pair may share the same ID by design. Duplicate values
        // cannot exist in a dictionary, but every visible ID must remain uniquely bound above.
        return true
    }

    /// v2026.07.18: old schema-2 builds embedded `originalPath` in journal IDs. Pair-local IDs
    /// are migrated to their opaque digest so a pending legacy journal can replay idempotently;
    /// plaintext commit receipts are dropped because the pair itself is enough to deduplicate
    /// that replay and retaining them would leak paths beyond the visible ten-record history.
    nonisolated private static func migrateLegacyJournalIdentifiers(
        _ input: HistoryEnvelope
    ) -> (envelope: HistoryEnvelope, changed: Bool)? {
        var changed = input.schemaVersion != 4
        let isLegacyJournalSchema = input.schemaVersion < 3
        var migratedRecords: [Record] = []
        migratedRecords.reserveCapacity(input.records.count)
        var receiptMapping: [String: String] = [:]
        for record in input.records {
            var migratedPairs: [Record.FilePair] = []
            migratedPairs.reserveCapacity(record.filePairs.count)
            for pair in record.filePairs {
                guard let persistedID = pair.journalID else {
                    migratedPairs.append(pair)
                    continue
                }
                if let migrated = TrashUndoJournalEntry.migratePersistedID(
                    persistedID,
                    originalPath: pair.original,
                    trashedPath: pair.trashed,
                    persistedAttemptID: pair.journalAttemptID,
                    expectedOperationID: record.journalOperationID
                ) {
                    changed = changed
                        || migrated.id != persistedID
                        || migrated.attemptID != pair.journalAttemptID
                    if let existing = receiptMapping[persistedID], existing != migrated.id {
                        return nil
                    }
                    receiptMapping[persistedID] = migrated.id
                    migratedPairs.append(Record.FilePair(
                        migrating: pair,
                        journalID: migrated.id,
                        journalAttemptID: migrated.attemptID
                    ))
                } else if isLegacyJournalSchema,
                          TrashUndoJournalEntry.isOpaqueID(persistedID),
                          pair.journalAttemptID == nil {
                    // Schema 2's digest omitted trashedPath and the pair omitted attemptID. There
                    // is no reversible proof. Preserve the visible/history/restore fact but strip
                    // its unprovable receipt; an exact pending journal can upgrade this pair later.
                    changed = true
                    migratedPairs.append(Record.FilePair(
                        migrating: pair,
                        journalID: nil,
                        journalAttemptID: nil
                    ))
                } else {
                    return nil
                }
            }
            migratedRecords.append(Record(
                id: record.id,
                timestamp: record.timestamp,
                source: record.source,
                filePairs: migratedPairs,
                recoveryStates: record.recoveryStates,
                journalOperationID: record.journalOperationID
            ))
        }

        var opaqueReceipts: [String: Date] = [:]
        for (persistedID, date) in input.committedJournalIDs {
            // Plaintext receipts are never retained after migration. The migrated visible pair
            // itself deduplicates a later journal replay, which can then mint a fresh v2 receipt.
            let migratedID = !isLegacyJournalSchema
                && TrashUndoJournalEntry.isOpaqueID(persistedID)
                ? persistedID
                : nil
            guard let migratedID else {
                changed = true
                continue
            }
            guard opaqueReceipts[migratedID] == nil else { return nil }
            opaqueReceipts[migratedID] = date
            changed = changed || migratedID != persistedID
        }
        return (
            HistoryEnvelope(
                schemaVersion: 4,
                records: migratedRecords,
                committedJournalIDs: opaqueReceipts,
                legacyReconciliation: input.legacyReconciliation
            ),
            changed
        )
    }

    nonisolated private static func mergeAndPersist(
        incoming: [Record],
        to url: URL,
        maxHistoryCount: Int
    ) -> PersistedHistory {
        guard incoming.allSatisfy({ $0.filePairs.count <= maximumPairsPerRecord }) else {
            return PersistedHistory(
                envelope: .empty,
                state: .recordRejected(maxPairs: maximumPairsPerRecord)
            )
        }
        return withHistoryLock(for: url) { parentDescriptor in
            let loaded = readEnvelope(from: url, parentDescriptor: parentDescriptor)
            guard loaded.state == .ready else {
                return PersistedHistory(envelope: loaded.envelope, state: loaded.state)
            }
            guard let records = mergeRecordSnapshots(
                disk: loaded.envelope.records,
                incoming: incoming,
                maxHistoryCount: maxHistoryCount
            ) else {
                return PersistedHistory(envelope: loaded.envelope, state: .corrupt)
            }
            var envelope = loaded.envelope
            envelope.records = records
            return persistEnvelope(
                envelope,
                to: url,
                destinationSnapshot: loaded.canonicalSnapshot,
                transactionState: loaded.transactionState,
                parentDescriptor: parentDescriptor
            )
        } ?? PersistedHistory(envelope: .empty, state: .writeFailed)
    }

    nonisolated private static func mergeJournalEntriesAndPersist(
        source: String,
        entries: [TrashUndoJournalEntry],
        to url: URL,
        maxHistoryCount: Int
    ) -> PersistedHistory {
        // Duplicate rows are malformed input even when byte-identical. Silently coalescing them
        // would make validation dependent on Dictionary construction order and hide producer bugs.
        guard entries.count == Set(entries.map(\.id)).count else {
            return PersistedHistory(envelope: .empty, state: .corrupt)
        }
        let uniqueEntries = entries

        return withHistoryLock(for: url) { parentDescriptor in
            let loaded = readEnvelope(from: url, parentDescriptor: parentDescriptor)
            guard loaded.state == .ready else {
                return PersistedHistory(envelope: loaded.envelope, state: loaded.state)
            }
            var envelope = loaded.envelope
            // Upgrade a schema-2 visible pair whose unprovable v1 receipt was stripped during
            // migration. The exact durable journal supplies the missing attempt and pair-bound
            // digest; path equality alone is never used for ordinary new-record deduplication.
            for entry in uniqueEntries where envelope.committedJournalIDs[entry.id] == nil {
                guard let recordIndex = envelope.records.firstIndex(where: {
                    $0.journalOperationID == entry.operationID
                }) else { continue }
                let record = envelope.records[recordIndex]
                let matchingIndices = record.filePairs.indices.filter { index in
                    let pair = record.filePairs[index]
                    return pair.journalID == nil
                        && TrashPipeline.normalizePath(pair.original) == entry.originalPath
                        && TrashPipeline.normalizePath(pair.trashed) == entry.trashedPath
                }
                guard matchingIndices.count <= 1 else {
                    return PersistedHistory(envelope: envelope, state: .corrupt)
                }
                guard let pairIndex = matchingIndices.first else { continue }
                let legacyPair = record.filePairs[pairIndex]
                guard let legacyIdentity = legacyPair.trashedIdentity,
                      legacyIdentity.matches(entry.originalIdentity) else {
                    return PersistedHistory(envelope: envelope, state: .corrupt)
                }
                var upgradedPairs = record.filePairs
                upgradedPairs[pairIndex] = Record.FilePair(
                    original: entry.originalPath,
                    trashed: entry.trashedPath,
                    trashedIdentity: entry.originalIdentity,
                    journalID: entry.id,
                    journalAttemptID: entry.attemptID,
                    restoreScopeRoot: entry.restoreScopeRoot
                )
                envelope.records[recordIndex] = Record(
                    id: record.id,
                    timestamp: record.timestamp,
                    source: record.source == "NSWorkspace" ? source : record.source,
                    filePairs: upgradedPairs,
                    recoveryStates: record.recoveryStates,
                    journalOperationID: record.journalOperationID
                )
            }
            let pending = uniqueEntries.filter {
                envelope.committedJournalIDs[$0.id] == nil
            }
            if pending.isEmpty {
                return loaded.requiresPersistenceMigration
                    ? persistEnvelope(
                        envelope,
                        to: url,
                        destinationSnapshot: loaded.canonicalSnapshot,
                        transactionState: loaded.transactionState,
                        parentDescriptor: parentDescriptor
                    )
                    : PersistedHistory(envelope: envelope, state: .ready)
            }
            guard envelope.committedJournalIDs.count + pending.count
                    <= maximumCommittedJournalIDs else {
                return PersistedHistory(
                    envelope: envelope,
                    state: .recordRejected(maxPairs: maximumPairsPerRecord)
                )
            }

            for (operationID, operationEntries) in Dictionary(grouping: pending, by: \.operationID) {
                let ordered = operationEntries.sorted {
                    if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                    return $0.id < $1.id
                }
                let newPairs = ordered.map {
                    Record.FilePair(
                        original: $0.originalPath,
                        trashed: $0.trashedPath,
                        trashedIdentity: $0.originalIdentity,
                        journalID: $0.id,
                        journalAttemptID: $0.attemptID,
                        restoreScopeRoot: $0.restoreScopeRoot
                    )
                }
                if let index = envelope.records.firstIndex(where: {
                    $0.journalOperationID == operationID
                }) {
                    let existing = envelope.records[index]
                    let existingIDs = Set(existing.filePairs.compactMap(\.journalID))
                    let novelPairs = newPairs.filter { pair in
                        pair.journalID.map { !existingIDs.contains($0) } ?? true
                    }
                    guard existing.filePairs.count + novelPairs.count
                            <= maximumPairsPerRecord else {
                        return PersistedHistory(
                            envelope: envelope,
                            state: .recordRejected(maxPairs: maximumPairsPerRecord)
                        )
                    }
                    envelope.records[index] = Record(
                        id: existing.id,
                        timestamp: existing.timestamp,
                        source: existing.source == "NSWorkspace" ? source : existing.source,
                        filePairs: existing.filePairs + novelPairs,
                        recoveryStates: existing.recoveryStates + novelPairs.map {
                            Record.RecoveryState(status: $0.trashedIdentity == nil ? .unavailable : .available)
                        },
                        journalOperationID: operationID
                    )
                } else {
                    guard newPairs.count <= maximumPairsPerRecord else {
                        return PersistedHistory(
                            envelope: envelope,
                            state: .recordRejected(maxPairs: maximumPairsPerRecord)
                        )
                    }
                    envelope.records.append(Record(
                        timestamp: ordered.first?.recordedAt ?? Date(),
                        source: source,
                        filePairs: newPairs,
                        journalOperationID: operationID
                    ))
                }
                for entry in ordered {
                    envelope.committedJournalIDs[entry.id] = entry.recordedAt
                }
            }
            envelope.records = globallyRecentRecords(
                envelope.records,
                maxHistoryCount: maxHistoryCount
            )
            return persistEnvelope(
                envelope,
                to: url,
                destinationSnapshot: loaded.canonicalSnapshot,
                transactionState: loaded.transactionState,
                parentDescriptor: parentDescriptor
            )
        } ?? PersistedHistory(envelope: .empty, state: .writeFailed)
    }

    nonisolated private static func pruneCommittedJournalIDs(
        _ ids: Set<String>,
        at url: URL
    ) -> PersistedHistory {
        withHistoryLock(for: url) { parentDescriptor in
            let loaded = readEnvelope(from: url, parentDescriptor: parentDescriptor)
            guard loaded.state == .ready else {
                return PersistedHistory(envelope: loaded.envelope, state: loaded.state)
            }
            var envelope = loaded.envelope
            var changed = loaded.requiresPersistenceMigration
            for id in ids where envelope.committedJournalIDs.removeValue(forKey: id) != nil {
                changed = true
            }
            return changed
                ? persistEnvelope(
                    envelope,
                    to: url,
                    destinationSnapshot: loaded.canonicalSnapshot,
                    transactionState: loaded.transactionState,
                    parentDescriptor: parentDescriptor
                )
                : PersistedHistory(envelope: envelope, state: .ready)
        } ?? PersistedHistory(envelope: .empty, state: .writeFailed)
    }

    /// Durable recycle callbacks may append file pairs to one immutable operation record after a
    /// second process or an older in-memory snapshot has already observed that record. Treat only
    /// a proven journal prefix extension (or the schema-2 receipt upgrade of the same pair) as a
    /// monotonic version of the same fact. Arbitrary edits to an ordinary record, reordered pairs,
    /// conflicting receipt identities, and divergent restore facts remain corruption.
    nonisolated private static func mergeVersionsOfSameRecord(
        disk: Record,
        incoming: Record
    ) -> Record? {
        guard disk.id == incoming.id,
              disk.journalOperationID == incoming.journalOperationID,
              timestampsIdentifySameRecord(disk.timestamp, incoming.timestamp),
              let mergedSource = mergeVersionsOfSameSource(
                disk: disk.source,
                incoming: incoming.source,
                isJournalRecord: disk.journalOperationID != nil
              ) else { return nil }
        let mergedTimestamp = max(disk.timestamp, incoming.timestamp)

        if disk.filePairs == incoming.filePairs {
            guard let mergedStates = mergeVersionsOfSameRecoveryStates(
                disk.recoveryStates,
                incoming.recoveryStates
            ) else { return nil }
            return Record(
                id: disk.id,
                timestamp: mergedTimestamp,
                source: mergedSource,
                filePairs: disk.filePairs,
                recoveryStates: mergedStates,
                journalOperationID: disk.journalOperationID
            )
        }

        guard let operationID = disk.journalOperationID,
              incoming.journalOperationID == operationID else { return nil }

        let sharedCount = min(disk.filePairs.count, incoming.filePairs.count)
        var mergedPairs: [Record.FilePair] = []
        var mergedStates: [Record.RecoveryState] = []
        mergedPairs.reserveCapacity(max(disk.filePairs.count, incoming.filePairs.count))
        mergedStates.reserveCapacity(max(disk.filePairs.count, incoming.filePairs.count))

        for index in 0..<sharedCount {
            guard let pair = mergeVersionsOfSameJournalPair(
                disk.filePairs[index],
                incoming.filePairs[index]
            ), let state = mergeVersionsOfSameRecoveryState(
                disk.recoveryStates[index],
                incoming.recoveryStates[index]
            ) else { return nil }
            mergedPairs.append(pair)
            mergedStates.append(state)
        }

        if disk.filePairs.count > sharedCount {
            mergedPairs.append(contentsOf: disk.filePairs[sharedCount...])
            mergedStates.append(contentsOf: disk.recoveryStates[sharedCount...])
        } else if incoming.filePairs.count > sharedCount {
            mergedPairs.append(contentsOf: incoming.filePairs[sharedCount...])
            mergedStates.append(contentsOf: incoming.recoveryStates[sharedCount...])
        }

        let journalIDs = mergedPairs.compactMap(\.journalID)
        guard journalIDs.count == Set(journalIDs).count,
              mergedPairs.count <= maximumPairsPerRecord else { return nil }

        return Record(
            id: disk.id,
            timestamp: mergedTimestamp,
            source: mergedSource,
            filePairs: mergedPairs,
            recoveryStates: mergedStates,
            journalOperationID: operationID
        )
    }

    /// JSONEncoder's `.iso8601` representation drops sub-second precision. A disk record and its
    /// still-live in-process version may therefore differ only inside the same integral second;
    /// allowing any broader timestamp rewrite would let a stale/corrupt record change LRU order.
    nonisolated private static func timestampsIdentifySameRecord(
        _ lhs: Date,
        _ rhs: Date
    ) -> Bool {
        floor(lhs.timeIntervalSince1970) == floor(rhs.timeIntervalSince1970)
    }

    nonisolated private static func mergeVersionsOfSameSource(
        disk: String,
        incoming: String,
        isJournalRecord: Bool
    ) -> String? {
        if disk == incoming { return disk }
        guard isJournalRecord else { return nil }
        if disk == "NSWorkspace" { return incoming }
        if incoming == "NSWorkspace" { return disk }
        return nil
    }

    nonisolated private static func mergeVersionsOfSameRecoveryStates(
        _ disk: [Record.RecoveryState],
        _ incoming: [Record.RecoveryState]
    ) -> [Record.RecoveryState]? {
        guard disk.count == incoming.count else { return nil }
        var merged: [Record.RecoveryState] = []
        merged.reserveCapacity(disk.count)
        for index in disk.indices {
            guard let state = mergeVersionsOfSameRecoveryState(
                disk[index],
                incoming[index]
            ) else { return nil }
            merged.append(state)
        }
        return merged
    }

    nonisolated private static func mergeVersionsOfSameJournalPair(
        _ disk: Record.FilePair,
        _ incoming: Record.FilePair
    ) -> Record.FilePair? {
        if disk == incoming { return disk }
        guard TrashPipeline.normalizePath(disk.original)
                == TrashPipeline.normalizePath(incoming.original),
              TrashPipeline.normalizePath(disk.trashed)
                == TrashPipeline.normalizePath(incoming.trashed),
              disk.trashedIdentity == incoming.trashedIdentity else { return nil }

        switch (disk.journalID, incoming.journalID) {
        case let (.some(diskID), .some(incomingID)):
            guard diskID == incomingID,
                  disk.journalAttemptID == incoming.journalAttemptID,
                  disk.restoreScopeRoot == incoming.restoreScopeRoot else { return nil }
            return disk
        case (.none, .some):
            guard disk.journalAttemptID == nil,
                  compatibleRestoreScope(disk.restoreScopeRoot, incoming.restoreScopeRoot) else {
                return nil
            }
            return incoming
        case (.some, .none):
            guard incoming.journalAttemptID == nil,
                  compatibleRestoreScope(disk.restoreScopeRoot, incoming.restoreScopeRoot) else {
                return nil
            }
            return disk
        case (.none, .none):
            return nil
        }
    }

    nonisolated private static func compatibleRestoreScope(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs else { return true }
        return TrashPipeline.normalizePath(lhs) == TrashPipeline.normalizePath(rhs)
    }

    nonisolated private static func mergeVersionsOfSameRecoveryState(
        _ disk: Record.RecoveryState,
        _ incoming: Record.RecoveryState
    ) -> Record.RecoveryState? {
        if disk.status == .restored, incoming.status == .restored {
            return disk == incoming ? disk : nil
        }
        if disk.status == .restored { return disk }
        return incoming
    }

    nonisolated private static func mergeRecordSnapshots(
        disk: [Record],
        incoming: [Record],
        maxHistoryCount: Int
    ) -> [Record]? {
        var diskByID: [UUID: Record] = [:]
        var diskOrder: [UUID: Int] = [:]
        for (index, record) in disk.enumerated() {
            guard diskByID.updateValue(record, forKey: record.id) == nil else { return nil }
            diskOrder[record.id] = index
        }
        var incomingByID: [UUID: Record] = [:]
        var incomingOrder: [UUID: Int] = [:]
        for (index, record) in incoming.enumerated() {
            guard incomingByID.updateValue(record, forKey: record.id) == nil else { return nil }
            incomingOrder[record.id] = index
        }

        struct MergeCandidate {
            let record: Record
            let recencyRank: Int
        }
        var candidates: [MergeCandidate] = []
        candidates.reserveCapacity(disk.count + incoming.count)
        var visited = Set<UUID>()
        for record in incoming {
            guard visited.insert(record.id).inserted else { return nil }
            if let current = diskByID[record.id] {
                guard let mergedRecord = mergeVersionsOfSameRecord(
                    disk: current,
                    incoming: record
                ) else { return nil }
                candidates.append(MergeCandidate(
                    record: mergedRecord,
                    recencyRank: min(
                        diskOrder[current.id] ?? Int.max,
                        incomingOrder[record.id] ?? Int.max
                    )
                ))
            } else {
                candidates.append(MergeCandidate(
                    record: record,
                    recencyRank: incomingOrder[record.id] ?? Int.max
                ))
            }
        }
        for record in disk where visited.insert(record.id).inserted {
            candidates.append(MergeCandidate(
                record: record,
                recencyRank: diskOrder[record.id] ?? Int.max
            ))
        }
        return Array(candidates.sorted { lhs, rhs in
            if lhs.record.timestamp != rhs.record.timestamp {
                return lhs.record.timestamp > rhs.record.timestamp
            }
            if lhs.recencyRank != rhs.recencyRank {
                return lhs.recencyRank < rhs.recencyRank
            }
            return lhs.record.id.uuidString < rhs.record.id.uuidString
        }.map(\.record).prefix(maxHistoryCount))
    }

    /// Cross-process mutations are applied to the latest locked disk envelope, then the union is
    /// globally ordered. UUID is a stable final tie-break for timestamps that lose sub-second
    /// precision in legacy ISO-8601 payloads; stale instance order can no longer evict a newer
    /// concurrent addition merely because it appeared first in an incoming snapshot.
    nonisolated private static func globallyRecentRecords(
        _ records: [Record],
        maxHistoryCount: Int
    ) -> [Record] {
        Array(records.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }.prefix(maxHistoryCount))
    }

    nonisolated private static func persistEnvelope(
        _ envelope: HistoryEnvelope,
        to url: URL,
        destinationSnapshot: FrozenDestinationEnvelope?,
        transactionState: LegacyMigrationTransactionState?,
        parentDescriptor: Int32
    ) -> PersistedHistory {
        guard validate(envelope), let data = encodeHistory(envelope) else {
            return PersistedHistory(envelope: envelope, state: .corrupt)
        }
        guard data.count <= maximumStoreBytes else {
            return PersistedHistory(
                envelope: envelope,
                state: .storeTooLarge(maxBytes: maximumStoreBytes)
            )
        }
        // v2026.07.19 P2 destination-authority fix: every ordinary Undo RMW commits from the
        // exact canonical bytes read during this flock epoch. A pathname temp-file replacement
        // here would reintroduce the same stale-target overwrite race fixed for legacy migration.
        guard let destinationSnapshot else {
            GSYLog.error(
                .trash,
                "undo_history.wal.commit_rejected reason=missing_locked_snapshot errno=none"
            )
            return PersistedHistory(envelope: envelope, state: .writeFailed)
        }
        if data == destinationSnapshot.data,
           !destinationSnapshot.requiresPersistenceMigration {
            return PersistedHistory(envelope: envelope, state: .ready)
        }

        let destination = url.standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard destination.isFileURL,
              destination.path.hasPrefix("/"),
              validLeafName(destinationName) else {
            GSYLog.error(
                .trash,
                "undo_history.wal.commit_rejected reason=invalid_destination errno=none"
            )
            return PersistedHistory(envelope: envelope, state: .writeFailed)
        }
        switch commitHistoryDataWithWAL(
            data,
            destinationSnapshot: destinationSnapshot,
            transactionState: transactionState,
            parentDescriptor: parentDescriptor,
            destinationName: destinationName
        ) {
        case .success:
            return PersistedHistory(envelope: envelope, state: .ready)
        case .failure(let failure):
            GSYLog.error(
                .trash,
                "undo_history.wal.commit_rejected reason=\(failure.reason) errno="
                    + "\(failure.errno.map(String.init) ?? "none")"
            )
            return PersistedHistory(envelope: envelope, state: .writeFailed)
        }
    }

    nonisolated private static func withHistoryLock<T>(
        for url: URL,
        _ body: (Int32) -> T
    ) -> T? {
        let destination = url.standardizedFileURL
        let destinationName = destination.lastPathComponent
        guard destination.isFileURL,
              destination.path.hasPrefix("/"),
              validLeafName(destinationName) else {
            GSYLog.error(.trash, "undo_history.lock rejected reason=invalid_destination errno=none")
            return nil
        }
        let parent = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            GSYLog.error(.trash, "UndoHistory lock directory 失败 err=\(error.localizedDescription)")
            return nil
        }
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            let code = errno
            GSYLog.error(.trash, "undo_history.lock rejected reason=parent_open errno=\(code)")
            return nil
        }
        defer { Darwin.close(parentDescriptor) }
        guard let descriptor = acquireHistoryLock(
            parentDescriptor: parentDescriptor,
            lockName: destinationName + ".lock"
        ) else {
            let code = errno
            GSYLog.error(.trash, "undo_history.lock rejected reason=unsafe_lock errno=\(code)")
            return nil
        }
        defer { Darwin.close(descriptor) }
        defer { _ = flock(descriptor, LOCK_UN) }
        // v2026.07.20 P1: the schema-4 WAL no longer creates UUID temporary siblings, but an
        // upgrade may inherit them from the legacy atomic writer. Retire only the exact old
        // grammar while this store owns the stable flock; the descriptor-bound sweep cannot
        // follow a symlink or reopen a substituted parent path.
        TrashDurableFileWriter.removeAbandonedTemporaryFiles(
            inParentDescriptor: parentDescriptor,
            temporaryPrefix: (destinationName as NSString).deletingPathExtension,
            logContext: "Undo history"
        )
        // v2026.07.19 P1: the same directory descriptor that owns the lock inode is the only
        // namespace authority passed to read/recover/persist. No helper reopens the parent path.
        return body(parentDescriptor)
    }

}
