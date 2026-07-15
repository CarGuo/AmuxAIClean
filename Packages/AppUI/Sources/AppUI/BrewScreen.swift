import SwiftUI
import BrewKit
import SafetyKit

/// Orders the post-submission UI transition for Professional file tools.
///
/// The terminal projection is deliberately synchronous and MainActor-isolated:
/// it can only reconcile the already-known submission outcome into the visible
/// model, so presenting a result never waits on a fresh filesystem scan.  A
/// later user refresh may discover unrelated changes, but it cannot be used as
/// a prerequisite for acknowledging the completed submission.
@MainActor
enum ToolDeletionResultOrdering {
    static func finish<Payload>(
        updateModelToTerminalState: () -> Void,
        makePayload: () -> Payload,
        present: (Payload) -> Void
    ) async {
        updateModelToTerminalState()
        present(makePayload())
    }
}

struct BrewCleanupTerminalState: Equatable, Sendable {
    let plan: BrewCleanupPlan
    let bytesByPath: [String: Int64]
}

enum BrewCleanupTerminalProjection {
    static func applying(
        succeededPaths: Set<String>,
        to state: BrewCleanupTerminalState
    ) -> BrewCleanupTerminalState {
        let currentPaths = Set(state.plan.stalePaths.map(\.path))
        let removedPaths = succeededPaths.intersection(currentPaths)
        let remaining = state.plan.stalePaths.filter { !removedPaths.contains($0.path) }
        let remainingBytes = state.bytesByPath.filter { !removedPaths.contains($0.key) }

        let totalBytes: Int64
        if remaining.isEmpty {
            totalBytes = 0
        } else {
            let removedBytes = removedPaths.reduce(Int64(0)) { partial, path in
                let value = max(0, state.bytesByPath[path] ?? 0)
                let sum = partial.addingReportingOverflow(value)
                return sum.overflow ? .max : sum.partialValue
            }
            totalBytes = removedBytes >= state.plan.totalBytes
                ? 0
                : state.plan.totalBytes - removedBytes
        }

        return BrewCleanupTerminalState(
            plan: BrewCleanupPlan(stalePaths: remaining, totalBytes: totalBytes),
            bytesByPath: remainingBytes
        )
    }
}

/// F-2-4 / 2026-06：Homebrew 包管理屏（sidebar 入口接入）。
///
/// dev 期 MVP（直接读 Cellar / Caskroom，不执行 brew 命令）：
/// - 顶部三个 tab：Installed / Outdated / Cleanup
/// - Installed：列 [BrewController.listAll()](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewController.swift)
/// - Outdated：需要先加载一次 [BrewRegistry](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewRegistry.swift)
///   的 jws cache（用户首次点 Refresh 才下载，离线时跳过）
/// - Cleanup：调 [BrewCleanup.dryRun](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/BrewKit/Sources/BrewKit/BrewCleanup.swift)
///   只列 stale paths，不真删（dev 期保守，避免误删 bottle）
///
/// brew 未安装时显示空态指引。所有字面量走英文 + 中文注释，不引入新 xcstrings。
public struct BrewScreen: View {
    private let controller: BrewController?
    private let cleanup: BrewCleanup?
    private let pipeline: any DeletionPipeline

    @State private var packages: [BrewPackage] = []
    @State private var outdated: [BrewOutdated] = []
    @State private var cleanupPlan: BrewCleanupPlan?
    @State private var cleanupBytesByPath: [String: Int64] = [:]
    @State private var selectedTab: Tab = .installed
    @State private var isLoading: Bool = false
    @State private var isCleaning: Bool = false
    @State private var lastError: String?
    @State private var activeSheet: ActiveSheet?
    @State private var cleanupDeletionHandoff = ToolDeletionHandoff<CleanupConfirmedDeletion>()
    @State private var cleanupPreflightTask: Task<Void, Never>?
    @State private var cleanupPreflightGate = ToolDeletionPreflightRequestGate<[String]>()

    private struct CleanupDeleteRequest: Identifiable, Sendable {
        let id = UUID()
        let items: [RunningAppGuard.Candidate]
        let totalBytes: Int64
        let prepared: DeletionPreparedInteraction

        var paths: [String] { items.map(\.path) }
    }

    private struct CleanupConfirmedDeletion: Sendable {
        let request: CleanupDeleteRequest
        let executionPlan: ToolTrashExecutionPlan
    }

    private enum ActiveSheet: Identifiable {
        case confirm(CleanupDeleteRequest)
        case preflightNotice(DeletionPreflightNotice)
        case result(OperationResultCompletion)

        var id: String {
            switch self {
            case .confirm(let request): return "confirm-\(request.id)"
            case .preflightNotice(let notice): return "preflightNotice-\(notice.id)"
            case .result(let payload): return "result-\(payload.id)"
            }
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case installed, outdated, cleanup
        var id: String { rawValue }
        var labelKey: LocalizedStringKey {
            switch self {
            case .installed: return "brew.tab.installed"
            case .outdated:  return "brew.tab.outdated"
            case .cleanup:   return "brew.tab.cleanup"
            }
        }
        var icon: String {
            switch self {
            case .installed: return "shippingbox"
            case .outdated:  return "arrow.up.circle"
            case .cleanup:   return "trash.circle"
            }
        }
    }

    public init(controller: BrewController? = BrewController.detectDefault(),
                cleanup: BrewCleanup? = BrewCleanup.detectDefault(),
                pipeline: any DeletionPipeline) {
        self.controller = controller
        self.cleanup = cleanup
        self.pipeline = pipeline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if controller == nil {
                notInstalledHint
            } else {
                tabBar
                Divider()
                content
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { reloadInstalled() }
        .sheet(item: $activeSheet, onDismiss: completeCleanupSheetDismissal) { sheet in
            switch sheet {
            case .confirm(let request):
                ToolTrashConfirmationSheet(
                    items: request.items,
                    totalBytes: request.totalBytes,
                    vendorOverrideRequest: request.prepared.vendorOverrideRequest,
                    scanIncompleteOverrideRequest: request.prepared.scanIncompleteOverrideRequest,
                    onCancel: { activeSheet = nil },
                    onConfirm: { executionPlan in
                        guard cleanupDeletionHandoff.schedule(CleanupConfirmedDeletion(
                            request: request,
                            executionPlan: executionPlan
                        )) else { return false }
                        activeSheet = nil
                        return true
                    }
                )
            case .preflightNotice(let notice):
                DeletionPreflightNoticeSheet(notice: notice) {
                    activeSheet = nil
                }
            case .result(let completion):
                OperationResultSheet(completion: completion) {
                    activeSheet = nil
                }
            }
        }
        .onDisappear {
            cancelCleanupPreflight()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("brew.header.title", bundle: .module)
                    .font(.title2.bold())
                if let prefix = controller?.prefix.path {
                    Text(verbatim: String(format: String(localized: "brew.header.prefix %@", bundle: .module), prefix))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                refresh()
            } label: {
                Label {
                    Text("brew.action.refresh", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(controller == nil || isLoading)
        }
    }

    private var notInstalledHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("brew.not_installed.title", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.headline)
                .foregroundStyle(.orange)
            Text("brew.not_installed.body", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private var tabBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(Tab.allCases) { t in
                Label {
                    Text(t.labelKey, bundle: .module)
                } icon: {
                    Image(systemName: t.icon)
                }.tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: selectedTab) { _, new in
            cancelCleanupPreflight()
            switch new {
            case .installed: reloadInstalled()
            case .outdated:  reloadOutdated()
            case .cleanup:   reloadCleanup()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = lastError {
            Label {
                Text(verbatim: err)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.callout)
                .foregroundStyle(.red)
        }
        switch selectedTab {
        case .installed: installedSection
        case .outdated:  outdatedSection
        case .cleanup:   cleanupSection
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedSection: some View {
        if packages.isEmpty && !isLoading {
            Text("brew.installed.empty", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: String(format: String(localized: "brew.installed.count %lld", bundle: .module), packages.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(packages, id: \.path) { pkg in
                            packageRow(pkg)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func packageRow(_ pkg: BrewPackage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pkg.kind == .cask ? "macwindow" : "terminal")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: pkg.name).font(.system(.body, design: .monospaced))
                    Text(verbatim: pkg.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pkg.installedOnRequest == false && pkg.kind == .formula {
                        Text("brew.tag.dep", bundle: .module).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let tap = pkg.tap {
                    Text(verbatim: tap).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(byteString(pkg.sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if let date = pkg.installedAt {
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: - Outdated

    @ViewBuilder
    private var outdatedSection: some View {
        if outdated.isEmpty && !isLoading {
            // dev 期不下载 jws；用户主动点 Refresh 才尝试。
            Text("brew.outdated.empty_hint", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: String(format: String(localized: "brew.outdated.count %lld", bundle: .module), outdated.count))
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(outdated, id: \.package.path) { o in
                            outdatedRow(o)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outdatedRow(_ o: BrewOutdated) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(verbatim: o.package.name).font(.system(.body, design: .monospaced))
            Text(verbatim: "\(o.package.version) → \(o.latestVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    // MARK: - Cleanup

    @ViewBuilder
    private var cleanupSection: some View {
        if let plan = cleanupPlan {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label {
                        Text(verbatim: String(format: String(localized: "brew.cleanup.summary %lld %@", bundle: .module),
                                              plan.stalePaths.count, byteString(plan.totalBytes)))
                    } icon: {
                        Image(systemName: "trash")
                    }
                        .font(.subheadline)
                        .foregroundStyle(plan.isEmpty ? Color.secondary : Color.orange)
                    Spacer()
                    if isCleaning {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        prepareCleanupForTrash(plan)
                    } label: {
                        Label(String(localized: "brew.cleanup.move_to_trash", bundle: .module),
                              systemImage: "trash")
                    }
                    .disabled(plan.isEmpty || isCleaning)
                }
                Text("brew.cleanup.review_note", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.stalePaths, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(verbatim: url.lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.05)))
                        }
                    }
                }
            }
        } else if isLoading {
            Text("brew.cleanup.computing", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if cleanup == nil {
            Text("brew.cleanup.cache_missing", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            Text("brew.cleanup.idle_hint", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - actions

    private func refresh() {
        switch selectedTab {
        case .installed: reloadInstalled()
        case .outdated:  reloadOutdated()
        case .cleanup:   reloadCleanup()
        }
    }

    private func reloadInstalled() {
        guard let ctl = controller else { return }
        isLoading = true
        lastError = nil
        Task.detached {
            let pkgs = ctl.listAll()
            await MainActor.run {
                packages = pkgs
                isLoading = false
            }
        }
    }

    private func reloadOutdated() {
        guard let ctl = controller else { return }
        isLoading = true
        lastError = nil
        Task.detached {
            // BrewRegistry 用户本地 brew api cache（brew update 一下就有）。
            // 完全离线场景下 registry 是空的，outdated == [] 是合理结果。
            let registry = BrewRegistry.loadDefault()
            let result = ctl.outdated(using: registry)
            await MainActor.run {
                outdated = result
                isLoading = false
            }
        }
    }

    private func reloadCleanup() {
        guard let c = cleanup else {
            cleanupPlan = nil
            cleanupBytesByPath = [:]
            return
        }
        isLoading = true
        lastError = nil
        Task.detached {
            let plan = c.dryRun()
            let bytesByPath = Dictionary(uniqueKeysWithValues: plan.stalePaths.map { url in
                let bytes: Int64
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                } catch {
                    // Per-item bytes are presentation metadata only.  The aggregate from
                    // BrewCleanup remains authoritative when a file disappears between
                    // enumeration and this snapshot, so a missing value is not a cleanup
                    // failure and must not abort the refresh.
                    bytes = 0
                }
                return (url.path, max(0, bytes))
            })
            await MainActor.run {
                cleanupPlan = plan
                cleanupBytesByPath = bytesByPath
                isLoading = false
            }
        }
    }

    private func prepareCleanupForTrash(_ plan: BrewCleanupPlan) {
        guard !plan.isEmpty,
              !isCleaning,
              !cleanupDeletionHandoff.hasPending,
              activeSheet == nil else { return }
        let paths = plan.stalePaths.map(\.path)
        cleanupPreflightTask?.cancel()
        let token = cleanupPreflightGate.begin(context: paths)
        isCleaning = true
        cleanupPreflightTask = Task { @MainActor in
            let identity = DeletionSnapshotIdentity(sessionID: UUID(), revision: 0)
            let coordinator = DeletionInteractionCoordinator(pipeline: pipeline)
            let decision: DeletionInteractionPreparation
            do {
                let intent = try coordinator.makeIntent(
                    origin: .brew,
                    mode: .professional,
                    snapshotIdentity: identity,
                    candidates: plan.stalePaths.map { url in
                        DeletionInteractionCandidateSnapshot(
                            path: url.path,
                            title: url.lastPathComponent,
                            isDirectory: url.hasDirectoryPath,
                            bytes: cleanupBytesByPath[url.path] ?? 0,
                            fileCount: 1
                        )
                    }
                )
                decision = await coordinator.prepare(
                    intent: intent,
                    currentSnapshotIdentity: identity
                )
            } catch {
                decision = .blocked(DeletionInteractionBlock(
                    intentID: UUID(),
                    rejections: paths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                ))
            }
            guard cleanupPreflightGate.finishIfCurrent(token, context: paths) else { return }
            cleanupPreflightTask = nil
            isCleaning = false
            guard !Task.isCancelled,
                  !cleanupDeletionHandoff.hasPending,
                  activeSheet == nil else { return }
            switch decision {
            case .confirmation(let prepared):
                activeSheet = .confirm(CleanupDeleteRequest(
                    items: prepared.confirmationCandidates,
                    totalBytes: cleanupTotalBytes(for: prepared.paths),
                    prepared: prepared
                ))
            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
            case .cancelled:
                return
            }
        }
    }

    private func completeCleanupSheetDismissal() {
        guard let confirmed = cleanupDeletionHandoff.takeAfterSheetDismissal() else { return }
        moveCleanupToTrash(confirmed)
    }

    private func cancelCleanupPreflight() {
        cleanupPreflightTask?.cancel()
        cleanupPreflightTask = nil
        if cleanupPreflightGate.cancel() {
            isCleaning = false
        }
    }

    private func moveCleanupToTrash(_ confirmed: CleanupConfirmedDeletion) {
        guard !isCleaning else { return }
        isCleaning = true
        Task { @MainActor in
            defer { isCleaning = false }
            let coordinator = DeletionInteractionCoordinator(pipeline: pipeline)
            let authorization: DeletionAuthorizedInteraction
            switch coordinator.authorize(
                prepared: confirmed.request.prepared,
                executionPlan: confirmed.executionPlan
            ) {
            case .authorized(let value):
                authorization = value
            case .cancelled:
                return
            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(
                    rejections: block.rejections
                ))
                return
            }
            let submission = await coordinator.submit(authorization, accessDeniedPaths: [])
            let completed: DeletionCompletedInteraction
            switch submission {
            case .completed(let value):
                completed = value
            case .requiresConfirmation(let prepared):
                activeSheet = .confirm(CleanupDeleteRequest(
                    items: prepared.confirmationCandidates,
                    totalBytes: cleanupTotalBytes(for: prepared.paths),
                    prepared: prepared
                ))
                return
            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
                return
            }
            let result = completed.result
            let succeeded = Set(result.succeededPaths)
            await ToolDeletionResultOrdering.finish(
                updateModelToTerminalState: {
                    guard let cleanupPlan else { return }
                    let terminal = BrewCleanupTerminalProjection.applying(
                        succeededPaths: succeeded,
                        to: BrewCleanupTerminalState(
                            plan: cleanupPlan,
                            bytesByPath: cleanupBytesByPath
                        )
                    )
                    self.cleanupPlan = terminal.plan
                    self.cleanupBytesByPath = terminal.bytesByPath
                },
                makePayload: { OperationResultCompletion.deletion(completed) },
                present: { completion in
                    activeSheet = .result(completion)
                }
            )
        }
    }

    private func cleanupTotalBytes(for paths: [String]) -> Int64 {
        paths.reduce(Int64(0)) { partial, path in
            let value = max(0, cleanupBytesByPath[path] ?? 0)
            let sum = partial.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
