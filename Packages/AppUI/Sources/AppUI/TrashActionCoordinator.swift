import Foundation

extension Notification.Name {
    /// 所有成功的废纸篓操作统一广播真实 moved original paths；跨功能页面据此
    /// 使扫描快照失效，避免 Brew/卸载/重复文件删除后 Smart Care 仍展示旧结果。
    static let gsyTrashDidMove = Notification.Name("com.amux.ai.clean.trash-did-move")
}

/// Single execution core for UI trash actions.
///
/// UI surfaces still own confirmation, selection, and presentation, but this
/// type centralizes the actual pipeline call and the invariant that movedPairs
/// are the source of truth for undo/prune/stat updates.
@MainActor
struct TrashActionCoordinator {
    enum Mode {
        case normal
        case force
    }

    struct Request {
        let paths: [String]
        let dryRun: Bool
        let source: String
        let accessDeniedPaths: Set<String>
        let mode: Mode

        init(paths: [String],
             dryRun: Bool,
             source: String,
             accessDeniedPaths: Set<String>,
             mode: Mode = .normal) {
            self.paths = paths
            self.dryRun = dryRun
            self.source = source
            self.accessDeniedPaths = accessDeniedPaths
            self.mode = mode
        }
    }

    struct Result {
        let moved: Int
        let skipped: Int
        let err: String?
        let pairs: [(String, String)]
        let outcome: TrashOutcome?
        let succeededPaths: [String]
    }

    private struct MovedPairProjection: Sendable {
        let succeededPaths: [String]
        let undoFilePairs: [UndoHistoryStore.Record.FilePair]

        static let empty = MovedPairProjection(succeededPaths: [], undoFilePairs: [])
    }

    let pipeline: DeletionPipeline
    let undoHistoryStore: UndoHistoryStore

    init(pipeline: DeletionPipeline,
         undoHistoryStore: UndoHistoryStore = .shared) {
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
    }

    func run(_ request: Request) async -> Result {
        let raw: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
        switch request.mode {
        case .normal:
            raw = await pipeline.moveToTrashReturningOutcome(
                paths: request.paths,
                dryRun: request.dryRun,
                accessDeniedPaths: request.accessDeniedPaths
            )
        case .force:
            // 历史 mode 只保留调用兼容；安全语义与 normal 完全一致，vendor `.forbid`
            // 永远不会因为 UI 操作模式被绕过。
            raw = await pipeline.moveToTrashReturningOutcome(
                paths: request.paths,
                dryRun: request.dryRun,
                accessDeniedPaths: request.accessDeniedPaths
            )
        }

        let (moved, skipped, err, pairs) = raw.legacy
        let projection: MovedPairProjection
        if pairs.isEmpty {
            projection = .empty
        } else {
            projection = await Task.detached(priority: .userInitiated) {
                var succeededPaths: [String] = []
                var undoFilePairs: [UndoHistoryStore.Record.FilePair] = []
                succeededPaths.reserveCapacity(pairs.count)
                undoFilePairs.reserveCapacity(pairs.count)
                for pair in pairs {
                    succeededPaths.append(pair.0)
                    undoFilePairs.append(.init(original: pair.0, trashed: pair.1))
                }
                return MovedPairProjection(
                    succeededPaths: succeededPaths,
                    undoFilePairs: undoFilePairs
                )
            }.value
        }
        if !request.dryRun, !pairs.isEmpty {
            undoHistoryStore.addRecord(
                source: request.source,
                filePairs: projection.undoFilePairs
            )
            NotificationCenter.default.post(
                name: .gsyTrashDidMove,
                object: nil,
                userInfo: [
                    "paths": projection.succeededPaths,
                    "source": request.source
                ]
            )
        }
        return Result(
            moved: moved,
            skipped: skipped,
            err: err,
            pairs: pairs,
            outcome: raw.outcome,
            succeededPaths: projection.succeededPaths
        )
    }
}
