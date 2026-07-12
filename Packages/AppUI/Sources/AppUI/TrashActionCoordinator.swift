import Foundation

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

        var succeededPaths: [String] {
            pairs.map { $0.0 }
        }
    }

    let pipeline: DeletionPipeline
    let undoHistoryStore: UndoHistoryStore

    init(pipeline: DeletionPipeline,
         undoHistoryStore: UndoHistoryStore = .shared) {
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
    }

    func run(_ request: Request) async -> Result {
        pipeline.setAccessDeniedPaths(request.accessDeniedPaths)
        let raw: (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
        switch request.mode {
        case .normal:
            raw = await pipeline.moveToTrashReturningOutcome(paths: request.paths, dryRun: request.dryRun)
        case .force:
            raw = await pipeline.moveToTrashForce(paths: request.paths, dryRun: request.dryRun)
        }

        let (moved, skipped, err, pairs) = raw.legacy
        if !request.dryRun, !pairs.isEmpty {
            undoHistoryStore.addRecord(
                source: request.source,
                filePairs: pairs.map { UndoHistoryStore.Record.FilePair(original: $0.0, trashed: $0.1) }
            )
        }
        return Result(moved: moved, skipped: skipped, err: err, pairs: pairs, outcome: raw.outcome)
    }
}
