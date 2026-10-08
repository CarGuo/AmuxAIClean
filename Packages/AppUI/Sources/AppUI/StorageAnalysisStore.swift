import Combine
import Foundation
import ScanKit

enum StorageAnalysisPhase: Equatable {
    case idle, scanning, loadingDirectory, ready, cancelled, failed
}

struct StorageDirectoryAccessPresentation: Equatable {
    let titleKey: String
    let detailKey: String

    init?(state: TreeRow.AccessState) {
        switch state {
        case .normal: return nil
        case .tccProtected:
            titleKey = "workspace.storage.access.privacy.title"
            detailKey = "workspace.storage.access.privacy.detail"
        case .permissionDenied:
            titleKey = "workspace.storage.access.permission.title"
            detailKey = "workspace.storage.access.permission.detail"
        case .incomplete:
            titleKey = "workspace.storage.access.incomplete.title"
            detailKey = "workspace.storage.access.incomplete.detail"
        }
    }
}

/// v2026.09.06: Normal analysis is a separate presentation owner, sharing the
/// primary producer admission registry with Professional and Smart Care. Leaving a
/// page cancels its producers; completed scans survive navigation. No partial tree
/// is materialized on the UI executor and late projections require the same revision.
@MainActor
final class StorageAnalysisStore: ObservableObject {
    let scanner: ScanCoordinator
    @Published private(set) var phase: StorageAnalysisPhase = .idle
    @Published private(set) var projection: StorageDirectoryProjection?
    @Published private(set) var projectionIdentity: DeletionSnapshotIdentity?
    @Published private(set) var directoryAccessState: TreeRow.AccessState = .normal
    @Published private(set) var breadcrumbs: [String] = []
    @Published private(set) var category: ScanCategory = .fullDisk
    @Published private(set) var isProjecting = false
    @Published private(set) var listScope: StorageDirectoryListScope = .all
    @Published var query = "" {
        didSet {
            if oldValue != query {
                limit = 100
                listScope = .all
                refresh()
            }
        }
    }
    private var limit = 100
    private var viewportSize: CGSize = .zero
    private var hasRequestedScan = false
    private var isActive = false
    private var revision: UInt64 = 0
    private var projectionTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var locale = Locale.current
    private var lastKey: ProjectionKey?

    private struct ProjectionKey: Equatable {
        let session: UUID
        let treeRevision: UInt64
        let childrenRevision: UInt64
        let sourceRevision: UInt64
        let directoryAccess: TreeRow.AccessState
        let path: String
        let query: String
        let limit: Int
        let locale: String
        let fetching: Bool
        let viewportSize: CGSize
        var listScope: StorageDirectoryListScope
    }

    init(scanner: ScanCoordinator) {
        self.scanner = scanner
        scanner.$isScanning.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        scanner.$scanPhase.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        scanner.$snapshot.map(\.isFinished).removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        scanner.$incompleteScanIssues.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        scanner.treeBrowser.$treeRevision.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        // A lazy directory's exact terminal uses the narrow children-cache signal,
        // not the whole-tree revision. Observe both or a measured folder stays loading.
        scanner.treeBrowser.$childrenCacheVersion.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
    }

    var path: String { breadcrumbs.last ?? category.rootPath }

    func activate(locale: Locale) {
        isActive = true
        self.locale = locale
        scanner.updatePresentationLocale(locale)
        refresh()
    }

    func deactivate() {
        isActive = false
        invalidateProjection()
        if scanner.hasActivePrimaryScanOwnership {
            scanner.cancel()
            phase = .cancelled
        }
        scanner.cancelOnDemandTreeScansPreservingResults()
    }

    func scan(_ category: ScanCategory? = nil) {
        // A folder chooser may complete after its page has departed. Hidden pages
        // cannot acquire the shared scan producer through a late UI callback.
        guard isActive else { return }
        invalidateProjection()
        if let category { self.category = category }
        hasRequestedScan = false
        breadcrumbs = [self.category.rootPath]
        projection = nil
        projectionIdentity = nil
        directoryAccessState = .normal
        query = ""
        limit = 100
        listScope = .all
        phase = .scanning
        scanner.scan(category: self.category, includeHidden: true)
        hasRequestedScan = true
    }

    func cancel() {
        invalidateProjection()
        scanner.cancel()
        phase = .cancelled
    }

    func open(_ row: TreeRow) {
        guard row.isDirectory, row.accessState == .normal, !row.isSizePending else { return }
        navigate(to: row.path)
    }

    func navigate(to path: String) {
        invalidateProjection()
        scanner.cancelOnDemandTreeScansPreservingResults()
        if let index = breadcrumbs.firstIndex(of: path) {
            breadcrumbs = Array(breadcrumbs.prefix(index + 1))
        } else {
            breadcrumbs.append(path)
        }
        projection = nil
        projectionIdentity = nil
        directoryAccessState = .normal
        limit = 100
        listScope = .all
        query = ""
        refresh()
    }

    func showMore() {
        limit += 100
        refresh()
    }

    func updateMapViewport(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            viewportSize != size else { return }
        viewportSize = size
        refresh()
    }

    func showSmallerItems() {
        guard projection?.mapPresentation.smallerItems != nil, listScope != .smallerItems else { return }
        listScope = .smallerItems
        limit = 100
        refresh()
    }

    func showAllItems() {
        guard listScope != .all else { return }
        listScope = .all
        limit = 100
        refresh()
    }

    @discardableResult
    func applyExternalDeletedPaths(_ paths: [String]) -> Task<Void, Never>? {
        guard !paths.isEmpty else {
            invalidateAfterExternalChange()
            return nil
        }
        if scanner.snapshot.isFinished, !scanner.isScanning,
            phase == .ready || phase == .loadingDirectory
        {
            // v2026.10.07: freeze ownership before enqueueing, and recheck after each await.
            // Presentation acknowledgement and authoritative pruning are separate transactions;
            // a replacement scan must never inherit an old receipt or be cancelled by its prune.
            // Do not bind to projection revision: navigation and concurrent same-session receipts
            // legitimately change it, and ScanCoordinator merges those with its source CAS.
            let sessionID = scanner.currentScanSessionID
            return Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled,
                    self.scanner.currentScanSessionID == sessionID else { return }
                await self.scanner.acknowledgeSuccessfulDeletionForPresentation(paths: paths)
                guard !Task.isCancelled,
                    self.scanner.currentScanSessionID == sessionID else { return }
                await self.scanner.pruneDeleted(paths: paths)
            }
        } else if phase != .idle {
            invalidateAfterExternalChange()
        }
        return nil
    }

    func invalidateAfterExternalChange() {
        // A moved file invalidates allocation evidence, including hardlink attribution.
        // A new scan is explicit; do not silently rescan the user's disk after deletion.
        cancel()
        projection = nil
        projectionIdentity = nil
        directoryAccessState = .normal
        hasRequestedScan = false
        listScope = .all
        phase = .idle
    }

    private func invalidateProjection() {
        revision &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        isProjecting = false
        lastKey = nil
    }

    private func refresh() {
        guard isActive, hasRequestedScan else { return }
        if case .settling = scanner.scanPhase {
            phase = .scanning
            return
        }
        if scanner.isScanning {
            phase = .scanning
            return
        }
        if scanner.wasCancelled {
            phase = .cancelled
            return
        }
        if scanner.terminalFailure != nil {
            phase = .failed
            return
        }
        guard scanner.snapshot.isFinished else { return }
        let rows = scanner.directChildren(of: path, sortedBy: .sizeDesc)
        let fetching = scanner.isFetchingChildren(of: path, sortedBy: .sizeDesc)
        let key = ProjectionKey(
            session: scanner.currentScanSessionID,
            treeRevision: scanner.treeBrowser.treeRevision,
            childrenRevision: scanner.treeBrowser.childrenCacheVersion,
            sourceRevision: scanner.deletionPresentationSourceRevision,
            directoryAccess: scanner.directoryAccessState(for: path), path: path,
            query: query, limit: limit, locale: locale.identifier, fetching: fetching,
            viewportSize: viewportSize, listScope: listScope)
        guard key != lastKey else { return }
        invalidateProjection()
        lastKey = key
        phase = fetching ? .loadingDirectory : .ready
        isProjecting = true
        let expectedRevision = revision
        let currentLocale = locale
        let worker = Task.detached(priority: .userInitiated) {
            try StorageDirectoryProjection.make(
                rows: rows, query: key.query,
                limit: key.limit, locale: currentLocale,
                viewportSize: key.viewportSize, listScope: key.listScope)
        }
        projectionTask = Task { [weak self] in
            let prepared: StorageDirectoryProjection
            do {
                prepared = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch { return }  // The pure projection throws only cooperative cancellation.
            guard let self, !Task.isCancelled, self.isActive,
                self.revision == expectedRevision, self.lastKey == key
            else { return }
            guard self.scanner.currentScanSessionID == key.session,
                self.scanner.deletionPresentationSourceRevision == key.sourceRevision,
                self.scanner.directoryAccessState(for: key.path) == key.directoryAccess
            else {
                self.lastKey = nil
                self.refresh()
                return
            }
            self.directoryAccessState = key.directoryAccess
            self.projection = prepared
            self.listScope = prepared.listScope
            var committedKey = key
            committedKey.listScope = prepared.listScope
            self.lastKey = committedKey
            self.projectionIdentity = DeletionSnapshotIdentity(
                sessionID: key.session, revision: key.sourceRevision,
                categoryID: self.scanner.snapshot.categoryID)
            self.isProjecting = false
            self.projectionTask = nil
        }
    }
}
