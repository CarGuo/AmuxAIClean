import SwiftUI
import BrewKit
import LogKit
import SafetyKit

/// v2026.07.18：BrewKit 保持零依赖并返回稳定字段；AppUI 作为消费边界统一写入本地日志。
/// 不记录 JSON 原文或 localizedDescription，避免诊断意外携带缓存内容。
private enum BrewLocalDiagnosticLogger {
    static func record(_ diagnostics: [BrewDiagnostic]) {
        for diagnostic in diagnostics {
            let errorDomain = diagnostic.errorDomain ?? "none"
            let errorCode = diagnostic.errorCode.map { String($0) } ?? "none"
            let rejectedEntryCount = diagnostic.rejectedEntryCount.map { String($0) } ?? "none"
            GSYLog.warning(
                .app,
                "brew.local_evidence_issue source=\(diagnostic.source.rawValue) "
                    + "stage=\(diagnostic.stage.rawValue) reason=\(diagnostic.reason.rawValue) "
                    + "path=\(diagnostic.path) error_domain=\(errorDomain) "
                    + "error_code=\(errorCode) rejected_entries=\(rejectedEntryCount)"
            )
        }
    }
}

/// v2026.07.18 P2 UI contract: a zero count is not an empty state by itself. Installed and
/// Cleanup use this same projection so only `.complete`/`.missing` evidence can authorize empty
/// copy; partial/unavailable results must remain visibly incomplete.
enum BrewEvidencePresentation: Sendable, Equatable {
    case idle
    case authoritativeEmpty
    case incompleteEmpty
    case content(incomplete: Bool)

    static func evaluate(
        itemCount: Int,
        status: BrewEvidenceStatus?
    ) -> BrewEvidencePresentation {
        guard let status else { return .idle }
        if itemCount == 0 {
            return status.isAuthoritative ? .authoritativeEmpty : .incompleteEmpty
        }
        return .content(incomplete: status.isIncomplete)
    }
}

/// “没有可升级项”只有在相关 registry 完整时才是权威结论；cache 缺失或损坏是不同终态。
enum BrewOutdatedEvidenceState: Sendable, Equatable {
    case idle
    case complete
    case cacheMissing
    case incomplete

    static func evaluate(
        installed: BrewPackageListResult,
        registry: BrewRegistry
    ) -> BrewOutdatedEvidenceState {
        guard installed.status.isAuthoritative else { return .incomplete }
        var statuses: [BrewRegistrySourceStatus] = []
        if installed.packages.contains(where: { $0.kind == .formula }) {
            statuses.append(registry.formulaStatus)
        }
        if installed.packages.contains(where: { $0.kind == .cask }) {
            statuses.append(registry.caskStatus)
        }
        if statuses.isEmpty {
            statuses = [registry.formulaStatus, registry.caskStatus]
        }
        if statuses.contains(where: { $0 == .unavailable || $0 == .partial }) {
            return .incomplete
        }
        if statuses.contains(.missing) {
            return .cacheMissing
        }
        return .complete
    }
}

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

/// Brew 的三个只读刷新入口共用一个 owner。`Task.cancel()` 只发出停止请求，真正决定
/// 谁能写 packages/outdated/cleanupPlan 和关闭 spinner 的是这条 revision 身份。
enum BrewReloadKind: String, Sendable, Equatable {
    case installed
    case outdated
    case cleanup
}

struct BrewReloadIdentity: Sendable, Equatable {
    let ownerID: UUID
    let revision: UInt64
    let kind: BrewReloadKind
}

struct BrewReloadGate: Sendable, Equatable {
    private(set) var current: BrewReloadIdentity?

    mutating func begin(_ identity: BrewReloadIdentity) {
        current = identity
    }

    mutating func invalidate() {
        current = nil
    }

    /// nil 表示迟到的旧 owner，无权触碰任何 UI 状态；false 表示当前 owner 已收敛，
    /// 但因为取消或 tab 已变化不能发布结果。只有 true 可以提交值模型。
    mutating func finishIfCurrent(
        _ identity: BrewReloadIdentity,
        visibleKind: BrewReloadKind,
        taskWasCancelled: Bool
    ) -> Bool? {
        guard current == identity else { return nil }
        current = nil
        return !taskWasCancelled && visibleKind == identity.kind
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
    /// v2026.07.20 P0: injected pipelines must carry their explicit Undo persistence owner.
    private let undoHistoryStore: UndoHistoryStore

    @State private var packages: [BrewPackage] = []
    @State private var installedEvidenceStatus: BrewEvidenceStatus?
    @State private var outdated: [BrewOutdated] = []
    @State private var outdatedEvidenceState: BrewOutdatedEvidenceState = .idle
    @State private var cleanupPlan: BrewCleanupPlan?
    @State private var cleanupBytesByPath: [String: Int64] = [:]
    @State private var cleanupEvidenceStatus: BrewEvidenceStatus?
    @State private var selectedTab: Tab = .installed
    @State private var isLoading: Bool = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var reloadRevision: UInt64 = 0
    @State private var reloadGate = BrewReloadGate()
    @State private var isCleaning: Bool = false
    @State private var activeSheet: ActiveSheet?
    @State private var preflightNotice: DeletionPreflightNotice?
    @State private var cleanupDeletionHandoff = ToolDeletionHandoff<CleanupConfirmedDeletion>()
    @State private var cleanupPreflightTask: Task<Void, Never>?
    @State private var cleanupPreflightGate = ToolDeletionPreflightRequestGate<[String]>()
    /// v2026.07.16: one stable capability lineage per cleanup result set. The session changes
    /// only when Homebrew is scanned again; repeated confirmation clicks reuse the same token
    /// and therefore cannot clear a durable pending-operation invalidation.
    @State private var cleanupScanSessionID = UUID()
    @State private var cleanupScanRevision: UInt64 = 0
    /// v2026.07.15：Brew 模型只保存命令事实；格式串与容量按当前 View locale 即时投影。
    @Environment(\.locale) private var locale

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
        case result(OperationResultCompletion)

        var id: String {
            switch self {
            case .confirm(let request): return "confirm-\(request.id)"
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
                cleanup: BrewCleanup? = BrewCleanup.defaultCacheCandidate(),
                pipeline: any DeletionPipeline,
                undoHistoryStore: UndoHistoryStore) {
        self.controller = controller
        self.cleanup = cleanup
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
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
        // v2026.07.20 P0: rejection evidence must not insert a persistent row into tool content.
        .deletionPreflightNoticeOverlay(preflightNotice) {
            preflightNotice = nil
        }
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
            case .result(let completion):
                OperationResultSheet(completion: completion) {
                    activeSheet = nil
                }
            }
        }
        .onDisappear {
            cancelReloadForDeparture()
            cancelCleanupPreflight()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("brew.header.title", bundle: .module)
                    .font(.title2.bold())
                if let prefix = controller?.prefix.path {
                    Text(verbatim: AppLocalization.format(
                        "brew.header.prefix %@",
                        locale: locale,
                        arguments: [prefix]
                    ))
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
        .onValueChange(of: selectedTab) { _, new in
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
        // v2026.07.16：Brew 当前 API 只返回值模型；这里不保留通用 String 错误槽。
        // 后续若增加失败态，必须先定义 typed presentation，不能重新直出 raw Error。
        switch selectedTab {
        case .installed: installedSection
        case .outdated:  outdatedSection
        case .cleanup:   cleanupSection
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedSection: some View {
        switch BrewEvidencePresentation.evaluate(
            itemCount: packages.count,
            status: installedEvidenceStatus
        ) {
        case .idle:
            EmptyView()
        case .authoritativeEmpty:
            Text("brew.installed.empty", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
        case .incompleteEmpty:
            Text("brew.installed.incomplete", bundle: .module)
                .font(.callout)
                .foregroundStyle(.orange)
        case .content(let incomplete):
            VStack(alignment: .leading, spacing: 6) {
                if incomplete {
                    Text("brew.installed.incomplete", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(verbatim: AppLocalization.format(
                    "brew.installed.count %lld",
                    locale: locale,
                    arguments: [Int64(packages.count)]
                ))
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
            Text(outdatedEvidenceState == .complete
                 ? "brew.outdated.empty_hint"
                 : outdatedEvidenceState == .incomplete
                    ? "brew.outdated.registry_incomplete"
                    : "brew.outdated.registry_missing", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if outdatedEvidenceState == .incomplete {
                    Text("brew.outdated.registry_incomplete", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(verbatim: AppLocalization.format(
                    "brew.outdated.count %lld",
                    locale: locale,
                    arguments: [Int64(outdated.count)]
                ))
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
            if cleanupEvidenceStatus == .missing {
                Text("brew.cleanup.cache_missing", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                switch BrewEvidencePresentation.evaluate(
                    itemCount: plan.stalePaths.count,
                    status: cleanupEvidenceStatus
                ) {
                case .idle:
                    EmptyView()
                case .incompleteEmpty:
                    Text("brew.cleanup.incomplete", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.orange)
                case .authoritativeEmpty:
                    cleanupPlanContent(plan, incomplete: false)
                case .content(let incomplete):
                    cleanupPlanContent(plan, incomplete: incomplete)
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

    @ViewBuilder
    private func cleanupPlanContent(
        _ plan: BrewCleanupPlan,
        incomplete: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if incomplete {
                Text("brew.cleanup.incomplete", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Label {
                    Text(verbatim: AppLocalization.format(
                        "brew.cleanup.summary %lld %@",
                        locale: locale,
                        arguments: [Int64(plan.stalePaths.count), byteString(plan.totalBytes)]
                    ))
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
                    Label(AppLocalization.string("brew.cleanup.move_to_trash", locale: locale),
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
        let (identity, previousOwner) = beginReload(kind: .installed)
        reloadTask = Task { @MainActor in
            if let previousOwner { await previousOwner.value }
            guard reloadGate.current == identity, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                let result = ctl.listAllWithDiagnostics()
                BrewLocalDiagnosticLogger.record(result.diagnostics)
                return result
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let shouldPublish = reloadGate.finishIfCurrent(
                identity,
                visibleKind: selectedReloadKind,
                taskWasCancelled: Task.isCancelled
            ) else { return }
            reloadTask = nil
            isLoading = false
            guard shouldPublish else { return }
            // v2026.07.18 P2: diagnostics are not merely logged; the evidence status is committed
            // with the same reload identity and controls whether the empty copy is authoritative.
            packages = result.packages
            installedEvidenceStatus = result.status
        }
    }

    private func reloadOutdated() {
        guard let ctl = controller else { return }
        let (identity, previousOwner) = beginReload(kind: .outdated)
        reloadTask = Task { @MainActor in
            if let previousOwner { await previousOwner.value }
            guard reloadGate.current == identity, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                // BrewRegistry 只读用户本地 brew api cache；缺失与损坏都不能被解释为
                // “全部已是最新”，终态由 BrewOutdatedEvidenceState 单独承载。
                let installed = ctl.listAllWithDiagnostics()
                let registry = BrewRegistry.loadDefault()
                BrewLocalDiagnosticLogger.record(installed.diagnostics + registry.diagnostics)
                return (
                    ctl.outdated(installedPackages: installed.packages, using: registry),
                    BrewOutdatedEvidenceState.evaluate(
                        installed: installed,
                        registry: registry
                    )
                )
            }
            let (result, evidenceState) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let shouldPublish = reloadGate.finishIfCurrent(
                identity,
                visibleKind: selectedReloadKind,
                taskWasCancelled: Task.isCancelled
            ) else { return }
            reloadTask = nil
            isLoading = false
            guard shouldPublish else { return }
            outdated = result
            outdatedEvidenceState = evidenceState
        }
    }

    private func reloadCleanup() {
        let scanSessionID = UUID()
        cleanupScanSessionID = scanSessionID
        cleanupScanRevision &+= 1
        let scanRevision = cleanupScanRevision
        guard let c = cleanup else {
            cancelReloadForDeparture()
            cleanupPlan = nil
            cleanupBytesByPath = [:]
            cleanupEvidenceStatus = .missing
            return
        }
        let (identity, previousOwner) = beginReload(kind: .cleanup)
        reloadTask = Task { @MainActor in
            if let previousOwner { await previousOwner.value }
            guard reloadGate.current == identity, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                // v2026.07.18 P2: plan, per-path bytes, completeness and diagnostics are produced
                // by one filesystem snapshot. AppUI never re-reads attributes with a zero fallback.
                let result = c.dryRunWithEvidence()
                BrewLocalDiagnosticLogger.record(result.diagnostics)
                return result
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let shouldPublish = reloadGate.finishIfCurrent(
                identity,
                visibleKind: selectedReloadKind,
                taskWasCancelled: Task.isCancelled
            ) else { return }
            reloadTask = nil
            isLoading = false
            // 删除能力 identity 与 UI reload owner 双重绑定；任一变化都拒绝旧结果。
            guard shouldPublish,
                  cleanupScanSessionID == scanSessionID,
                  cleanupScanRevision == scanRevision else { return }
            cleanupPlan = result.plan
            cleanupBytesByPath = result.bytesByPath
            cleanupEvidenceStatus = result.status
        }
    }

    private var selectedReloadKind: BrewReloadKind {
        switch selectedTab {
        case .installed: return .installed
        case .outdated: return .outdated
        case .cleanup: return .cleanup
        }
    }

    private func beginReload(
        kind: BrewReloadKind
    ) -> (identity: BrewReloadIdentity, previousOwner: Task<Void, Never>?) {
        let previousOwner = reloadTask
        previousOwner?.cancel()
        reloadRevision &+= 1
        let identity = BrewReloadIdentity(
            ownerID: UUID(),
            revision: reloadRevision,
            kind: kind
        )
        reloadGate.begin(identity)
        isLoading = true
        return (identity, previousOwner)
    }

    private func cancelReloadForDeparture() {
        // 先失效 owner，再取消任务；即使同步 FileManager 调用随后才返回，也不能写回。
        reloadGate.invalidate()
        reloadTask?.cancel()
        reloadTask = nil
        isLoading = false
    }

    private func prepareCleanupForTrash(_ plan: BrewCleanupPlan) {
        guard !plan.isEmpty,
              !isCleaning,
              !cleanupDeletionHandoff.hasPending,
              activeSheet == nil else { return }
        // v2026.07.20: non-modal rejection evidence never owns the sheet slot.
        preflightNotice = nil
        let paths = plan.stalePaths.map(\.path)
        cleanupPreflightTask?.cancel()
        let token = cleanupPreflightGate.begin(context: paths)
        let identity = DeletionSnapshotIdentity(
            sessionID: cleanupScanSessionID,
            revision: cleanupScanRevision,
            categoryID: "brew-cleanup"
        )
        isCleaning = true
        cleanupPreflightTask = Task { @MainActor in
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
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
                  cleanupScanSessionID == identity.sessionID,
                  cleanupScanRevision == identity.revision,
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
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
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
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
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
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(
                    rejections: block.rejections
                )
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
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
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
        AppLocalization.byteCount(bytes, locale: locale)
    }
}
