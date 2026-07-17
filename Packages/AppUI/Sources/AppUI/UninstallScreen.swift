import SwiftUI
import Foundation
import LogKit
import SafetyKit

// MARK: - 数据模型

/// 已安装的 .app 条目（一层扫 /Applications）。
public struct InstalledApp: Hashable, Sendable, Identifiable {
    public var id: String { appURL.path }
    public let appURL: URL
    public let metadata: AppMetadata

    public init(appURL: URL, metadata: AppMetadata) {
        self.appURL = appURL
        self.metadata = metadata
    }
}

struct UninstallCandidateTerminalState: Equatable, Sendable {
    let candidates: [UninstallCandidate]
    let checked: Set<String>
}

enum UninstallCandidateTerminalProjection {
    static func applying(
        succeededPaths: Set<String>,
        to state: UninstallCandidateTerminalState
    ) -> UninstallCandidateTerminalState {
        UninstallCandidateTerminalState(
            candidates: state.candidates.filter { !succeededPaths.contains($0.path) },
            checked: state.checked.subtracting(succeededPaths)
        )
    }
}

/// v2026.07.17：卸载候选的展示值和删除资格必须消费同一份 typed snapshot。
/// 预算截断/枚举失败的 bytes 是下界，不能因为路径匹配正确就自动获得删除资格。
enum UninstallDeletionSelectionPolicy {
    static func isSelectable(_ candidate: UninstallCandidate) -> Bool {
        candidate.hasCompleteSnapshot
    }

    static func selectablePaths(in candidates: [UninstallCandidate]) -> Set<String> {
        Set(candidates.lazy.filter(isSelectable).map(\.path))
    }

    static func canSubmit(_ candidates: [UninstallCandidate]) -> Bool {
        !candidates.isEmpty && candidates.allSatisfy(isSelectable)
    }

    static func interactionSnapshot(
        for candidate: UninstallCandidate,
        runningBundleIDPrefix: String
    ) -> DeletionInteractionCandidateSnapshot {
        DeletionInteractionCandidateSnapshot(
            path: candidate.path,
            title: URL(fileURLWithPath: candidate.path).lastPathComponent,
            isDirectory: candidate.isDirectory,
            bytes: candidate.bytes,
            fileCount: candidate.fileCount,
            runningBundleIDPrefix: runningBundleIDPrefix,
            accessEvidence: accessEvidence(for: candidate)
        )
    }

    private static func accessEvidence(for candidate: UninstallCandidate) -> DeletionAccessEvidence {
        guard !candidate.hasCompleteSnapshot else { return .complete }
        let hasPermissionIssue = candidate.snapshotIssues.contains { issue in
            issue.reason == .permissionDenied
        }
        return .incomplete(hasPermissionIssue ? .permissionDenied : .incompleteEnumeration)
    }
}

/// A confirmed uninstall request is valid only for the exact app selection that produced it.
/// The View checks this boundary when the user confirms, after the sheet has dismissed, and
/// immediately before the typed authorization reaches the recycle submit boundary.
enum UninstallDeletionSubmissionGate {
    enum Decision: Sendable, Equatable {
        case current
        case cancelled([DeletionPreflight.Rejection])
    }

    static func evaluate(
        requestAppID: String,
        requestSelectionRevision: UInt64,
        boundSnapshotIdentity: DeletionSnapshotIdentity,
        currentAppID: String?,
        currentScanSessionID: UUID,
        currentSelectionRevision: UInt64,
        paths: [String]
    ) -> Decision {
        guard !requestAppID.isEmpty,
              boundSnapshotIdentity.categoryID == requestAppID,
              boundSnapshotIdentity.sessionID == currentScanSessionID,
              boundSnapshotIdentity.revision == requestSelectionRevision,
              currentAppID == requestAppID,
              currentSelectionRevision == requestSelectionRevision else {
            return .cancelled(paths.map {
                .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
            })
        }
        return .current
    }
}

/// Revision-owned publication gate for one selected App's candidate scan.
///
/// v2026.07.17 root-cause record: cancelling an old `Task` does not guarantee that its body
/// has already started. The old implementation published `isLoadingCandidates = true` and
/// cleared the visible rows *inside* that asynchronous body. A cancelled A task could therefore
/// start after B had been selected, erase B's rows, then return at its cancellation guard without
/// clearing the spinner. The selection callback now publishes the start state synchronously and
/// every terminal path must claim this exact App + session + revision before touching the UI.
struct UninstallCandidateLoadIdentity: Sendable, Equatable {
    let appID: String
    let scanSessionID: UUID
    let selectionRevision: UInt64
}

struct UninstallCandidateLoadGate: Sendable, Equatable {
    enum CurrentCompletion: Sendable, Equatable {
        case publishResult
        case cancelled
    }

    private(set) var current: UninstallCandidateLoadIdentity?

    mutating func begin(_ identity: UninstallCandidateLoadIdentity) {
        current = identity
    }

    mutating func invalidate() {
        current = nil
    }

    mutating func completeIfCurrent(
        _ identity: UninstallCandidateLoadIdentity,
        selectedAppID: String?,
        scanSessionID: UUID,
        selectionRevision: UInt64,
        taskWasCancelled: Bool
    ) -> CurrentCompletion? {
        guard current == identity,
              selectedAppID == identity.appID,
              scanSessionID == identity.scanSessionID,
              selectionRevision == identity.selectionRevision else {
            return nil
        }
        current = nil
        return taskWasCancelled ? .cancelled : .publishResult
    }
}

/// Revision owner for the installed-App list. This is separate from candidate selection because
/// refreshes can overlap selection changes and must not let an older `/Applications` snapshot
/// overwrite a newer one or close its spinner.
struct UninstallAppListLoadIdentity: Sendable, Equatable {
    let operationID: UUID
    let revision: UInt64
}

struct UninstallAppListLoadGate: Sendable, Equatable {
    private(set) var current: UninstallAppListLoadIdentity?

    mutating func begin(_ identity: UninstallAppListLoadIdentity) { current = identity }
    mutating func invalidate() { current = nil }

    mutating func finishIfCurrent(
        _ identity: UninstallAppListLoadIdentity,
        taskWasCancelled: Bool
    ) -> Bool? {
        guard current == identity else { return nil }
        current = nil
        return !taskWasCancelled
    }
}

struct UninstallExecutionOwner: Sendable, Equatable, Identifiable {
    let id: UUID
    let appID: String
    let scanSessionID: UUID
    let selectionRevision: UInt64
}

struct UninstallExecutionStatus: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing
        case finalValidation
        case submitting
        case diagnosingItems
        case finalizing

        func localizedTitle(locale: Locale) -> String {
            let key: String
            switch self {
            case .preparing: key = "uninstall.execution.preparing"
            case .finalValidation: key = "uninstall.execution.validating"
            case .submitting: key = "uninstall.execution.submitting"
            case .diagnosingItems: key = "uninstall.execution.diagnosing"
            case .finalizing: key = "uninstall.execution.finalizing"
            }
            return AppLocalization.string(key, locale: locale)
        }
    }

    let phase: Phase
    let completedItems: Int
    let totalItems: Int
    let currentPath: String?

    static func preparing(totalItems: Int) -> UninstallExecutionStatus {
        .init(
            phase: .preparing,
            completedItems: 0,
            totalItems: max(0, totalItems),
            currentPath: nil
        )
    }
}

enum UninstallExecutionProgressReducer {
    static func reduce(
        current: UninstallExecutionStatus,
        event: DeletionExecutionProgress,
        eventOwner: UninstallExecutionOwner,
        currentOwner: UninstallExecutionOwner?,
        currentAppID: String?,
        currentScanSessionID: UUID,
        currentSelectionRevision: UInt64
    ) -> UninstallExecutionStatus {
        guard currentOwner == eventOwner,
              currentAppID == eventOwner.appID,
              currentScanSessionID == eventOwner.scanSessionID,
              currentSelectionRevision == eventOwner.selectionRevision,
              case .trash(let progress) = event,
              progress.totalItems == current.totalItems,
              progress.completedItems >= current.completedItems else {
            return current
        }
        let phase: UninstallExecutionStatus.Phase
        switch progress.phase {
        case .finalValidation: phase = .finalValidation
        case .submitting: phase = .submitting
        case .diagnosingItems: phase = .diagnosingItems
        case .finalizing: phase = .finalizing
        }
        // v2026.07.17: batch execution may legitimately alternate
        // submitting -> diagnosing one failed item -> submitting the next batch. Treat only
        // final validation and finalizing as ordered boundaries; counts stay monotonic.
        let acceptsPhase: Bool = switch (current.phase, phase) {
        case (.finalizing, .finalizing): true
        case (.finalizing, _): false
        case (.preparing, _): true
        case (.finalValidation, .finalValidation),
             (.finalValidation, .submitting),
             (.finalValidation, .diagnosingItems),
             (.finalValidation, .finalizing): true
        case (.submitting, .submitting),
             (.submitting, .diagnosingItems),
             (.submitting, .finalizing): true
        case (.diagnosingItems, .submitting),
             (.diagnosingItems, .diagnosingItems),
             (.diagnosingItems, .finalizing): true
        case (_, .finalValidation): false
        case (_, .preparing): false
        }
        guard acceptsPhase else { return current }
        return .init(
            phase: phase,
            completedItems: progress.completedItems,
            totalItems: progress.totalItems,
            currentPath: progress.currentPath
        )
    }
}

private struct UninstallExecutionSheet: View {
    @Environment(\.locale) private var locale

    let status: UninstallExecutionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("uninstall.execution.title", bundle: .module)
                        .font(.title3.bold())
                    Text("uninstall.execution.subtitle", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                if status.totalItems > 0
                    && (status.phase == .submitting || status.phase == .diagnosingItems) {
                    ProgressView(
                        value: Double(status.completedItems),
                        total: Double(status.totalItems)
                    )
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(status.phase.localizedTitle(locale: locale))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if status.totalItems > 0 {
                        Text("\(status.completedItems) / \(status.totalItems)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let path = status.currentPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Text("uninstall.execution.safety_note", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        // v2026.07.17: Preserve the execution sheet geometry through SwiftUI's valid
        // flexible-frame overload instead of the nonexistent width/minHeight combination.
        .frame(minWidth: 540, maxWidth: 540, minHeight: 270)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uninstall.execution-sheet")
    }
}

// MARK: - Store

/// 卸载视图的状态 actor —— 把 IO/扫描搬出主线程，UI 只 await 它。
///
/// 设计要点：
/// - 仅扫一层 `/Applications`（不递归），每条条目附带 `AppMetadata`
/// - 解析失败的 .app（缺少 Info.plist / 缺 CFBundleIdentifier）静默跳过
/// - 候选项委托给已有的 `AppUninstaller.candidatesAsync(for:)`，**不重复实现匹配规则**
/// - 孤儿残留独立扫描：`scanOrphans()` 走 [OrphanScanner](OrphanScanner.swift)，反查无主目录
public actor UninstallStore {
    private let applicationsPath: String
    private let uninstaller: AppUninstaller
    private let orphanScanner: OrphanScanner
    private let fileManager: FileManager

    public init(
        applicationsPath: String = "/Applications",
        uninstaller: AppUninstaller = AppUninstaller(),
        orphanScanner: OrphanScanner = OrphanScanner(),
        fileManager: FileManager = .default
    ) {
        self.applicationsPath = applicationsPath
        self.uninstaller = uninstaller
        self.orphanScanner = orphanScanner
        self.fileManager = fileManager
    }

    /// 扫 `/Applications` 一层，仅取 `*.app`，逐个解析 Info.plist。
    public func listInstalledApps() async -> [InstalledApp] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: applicationsPath, isDirectory: &isDir),
              isDir.boolValue,
              let names = try? fileManager.contentsOfDirectory(atPath: applicationsPath)
        else {
            return []
        }

        var out: [InstalledApp] = []
        for name in names where name.hasSuffix(".app") {
            // v2026.07.17: refresh revisions are cancellable owners; do not keep parsing every
            // Info.plist after a newer refresh or page departure invalidated this list.
            guard !Task.isCancelled else { return [] }
            let appURL = URL(fileURLWithPath: applicationsPath).appendingPathComponent(name)
            guard let meta = try? AppMetadata.read(appURL: appURL) else { continue }
            out.append(InstalledApp(appURL: appURL, metadata: meta))
        }
        out.sort { $0.metadata.appName.localizedCaseInsensitiveCompare($1.metadata.appName) == .orderedAscending }
        return out
    }

    /// 给定一个已选 App，返回卸载残留候选项。
    public func selectApp(_ app: InstalledApp) async -> [UninstallCandidate] {
        await uninstaller.candidatesAsync(for: app.metadata, includeFallbacks: false)
    }

    /// 反向扫描三大用户库目录，列出"无主"残留候选。
    public func scanOrphans() async -> [OrphanCandidate] {
        orphanScanner.scan()
    }
}

// MARK: - SwiftUI 屏幕

/// 卸载残留扫描的独立屏幕：左 App 列表 / 右候选项 + 删除按钮。
///
/// 安全契约：
/// - Professional 只展示不可变候选 + 删除确认，不提供 Preview/dry-run 分支
/// - 用户确认后的执行固定为 `dryRun = false`
public struct UninstallScreen: View {
    /// v2026.07.15：占位、汇总、按钮和匹配原因都在当前 View locale 下解析；
    /// 不再经由进程级字符串解析锁定 App 启动时的语言。
    @Environment(\.locale) private var locale

    private let store: UninstallStore
    private let pipeline: any DeletionPipeline

    @State private var apps: [InstalledApp] = []
    @State private var selectedApp: InstalledApp?
    @State private var candidates: [UninstallCandidate] = []
    @State private var checked: Set<String> = []
    @State private var isLoadingApps: Bool = false
    @State private var appListTask: Task<Void, Never>?
    @State private var appListRevision: UInt64 = 0
    @State private var appListLoadGate = UninstallAppListLoadGate()
    @State private var isLoadingCandidates: Bool = false
    @State private var isDeleting: Bool = false
    @State private var candidateTask: Task<Void, Never>?
    @State private var candidateLoadGate = UninstallCandidateLoadGate()
    @State private var activeSheet: ActiveSheet?
    @State private var uninstallDeletionHandoff = ToolDeletionHandoff<UninstallExecutionRequest>()
    @State private var uninstallPreflightTask: Task<Void, Never>?
    @State private var uninstallPreflightGate = ToolDeletionPreflightRequestGate<UninstallPreflightContext>()
    @State private var uninstallExecutionTask: Task<Void, Never>?
    @State private var uninstallExecutionOwner: UninstallExecutionOwner?
    @State private var uninstallExecutionStatus: UninstallExecutionStatus?
    @State private var selectedAppRevision: UInt64 = 0
    /// v2026.07.16: identifies the candidate scan, not the confirmation click. This closes the
    /// path where a random UUID made every retry look like a fresh review after restart.
    @State private var selectedAppScanSessionID = UUID()

    private var isDeletionTransactionActive: Bool {
        isDeleting
            || uninstallPreflightGate.hasCurrentRequest
            || uninstallDeletionHandoff.hasPending
            || activeSheet != nil
    }

    private struct UninstallDeleteRequest: Identifiable, Sendable {
        let id = UUID()
        let items: [RunningAppGuard.Candidate]
        let totalBytes: Int64
        let bytesByPath: [String: Int64]
        let prepared: DeletionPreparedInteraction
        let appID: String
        let selectionRevision: UInt64

        var paths: [String] { items.map(\.path) }
    }

    private struct UninstallExecutionRequest: Sendable {
        let plan: ToolTrashExecutionPlan
        let request: UninstallDeleteRequest
        let appID: String
        let selectionRevision: UInt64
    }

    private struct UninstallPreflightContext: Sendable, Equatable {
        let appID: String
        let selectionRevision: UInt64
        let paths: [String]
    }

    private enum ActiveSheet: Identifiable {
        case confirm(UninstallDeleteRequest)
        case execution(UninstallExecutionOwner)
        case preflightNotice(DeletionPreflightNotice)
        case result(OperationResultCompletion)

        var id: String {
            switch self {
            case .confirm(let request): return "confirm-\(request.id)"
            case .execution(let owner): return "execution-\(owner.id.uuidString)"
            case .preflightNotice(let notice): return "preflightNotice-\(notice.id)"
            case .result(let payload): return "result-\(payload.id)"
            }
        }
    }

    public init(
        store: UninstallStore? = nil,
        pipeline: (any DeletionPipeline)? = nil,
        vendors: [VendorRule]
    ) {
        // 若没传 store，用注入的 vendors 现场装一个 AppUninstaller
        if let store {
            self.store = store
        } else {
            let unins = AppUninstaller(vendorRules: vendors)
            self.store = UninstallStore(uninstaller: unins)
        }
        self.pipeline = pipeline ?? TrashPipeline(vendors: vendors, whitelistStore: .shared)
    }

    public var body: some View {
        // bug2：之前用 HSplitView 是 NSSplitView 桥接，会向外抢宽度预算，导致
        // 嵌在 MainView 的 NavigationSplitView content 栏时，外层 sidebar 被
        // 强制压到几十像素宽，文字截断到只剩首字母。
        // 改成 HStack + Divider + maxWidth=.infinity，让两栏在 content 栏内部
        // 弹性平分，外层 sidebar 不再受到挤压。代价：失去拖拽分栏宽度的能力，
        // 但卸载残留是只读 + 二次确认流程，列宽固定 1:2 已足够。
        HStack(spacing: 0) {
            appsPane
                .frame(minWidth: 240, maxWidth: 360)
            Divider()
            candidatesPane
                .frame(maxWidth: .infinity)
        }
        .onAppear { startAppListReload() }
        // 确认与结果共用一个 ActiveSheet。真删只在确认 sheet 的 onDismiss
        // 之后从 handoff 取出，避免两张 sibling sheet 争抢呈现。
        .sheet(item: $activeSheet, onDismiss: completeUninstallSheetDismissal) { sheet in
            switch sheet {
            case .confirm(let request):
                ToolTrashConfirmationSheet(
                    items: request.items,
                    totalBytes: request.totalBytes,
                    vendorOverrideRequest: request.prepared.vendorOverrideRequest,
                    scanIncompleteOverrideRequest: request.prepared.scanIncompleteOverrideRequest,
                    onCancel: { activeSheet = nil },
                    onConfirm: { executionPlan in
                        guard requireCurrentUninstallRequest(request) else { return false }
                        guard uninstallDeletionHandoff.schedule(UninstallExecutionRequest(
                            plan: executionPlan,
                            request: request,
                            appID: request.appID,
                            selectionRevision: request.selectionRevision
                        )) else { return false }
                        activeSheet = nil
                        return true
                    }
                )
            case .execution:
                UninstallExecutionSheet(
                    status: uninstallExecutionStatus ?? .preparing(totalItems: 0)
                )
                .interactiveDismissDisabled(true)
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
            cancelAppListReloadForDeparture()
            cancelCandidateLoadForDeparture()
            cancelUninstallPreflight()
            // A confirmed recycle transaction is intentionally not cancelled on navigation or
            // window lifecycle. The execution sheet blocks normal navigation; if AppKit removes
            // the view externally, the owned Task and durable ledger still converge its typed
            // terminal instead of silently abandoning an already-submitted operation.
        }
    }

    // MARK: - 左栏

    private var appsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("uninstall.apps.title", bundle: .module).font(.headline)
                Spacer()
                if isLoadingApps { ProgressView().controlSize(.small) }
                Button {
                    startAppListReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingApps || isDeletionTransactionActive)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $selectedApp) {
                ForEach(apps) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.metadata.appName)
                            .font(.system(.body, design: .rounded))
                        Text(app.metadata.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(app)
                }
            }
            .listStyle(.inset)
            .disabled(isDeletionTransactionActive)
            .onValueChange(of: selectedApp) { _, new in
                selectedAppRevision &+= 1
                selectedAppScanSessionID = UUID()
                let scanSessionID = selectedAppScanSessionID
                cancelUninstallPreflight()
                candidateTask?.cancel()
                candidateTask = nil
                candidateLoadGate.invalidate()
                guard let app = new else {
                    candidates = []
                    checked = []
                    isLoadingCandidates = false
                    return
                }
                let identity = UninstallCandidateLoadIdentity(
                    appID: app.id,
                    scanSessionID: scanSessionID,
                    selectionRevision: selectedAppRevision
                )
                // Start-state publication is synchronous with the selection revision. The
                // asynchronous body below is never allowed to clear a newer result on startup.
                candidateLoadGate.begin(identity)
                isLoadingCandidates = true
                candidates = []
                checked = []
                candidateTask = Task {
                    await reloadCandidates(for: app, identity: identity)
                }
            }
        }
    }

    // MARK: - 右栏

    private var candidatesPane: some View {
        VStack(spacing: 0) {
            candidatesHeader
            Divider()
            if selectedApp == nil {
                placeholder(
                    AppLocalization.string("uninstall.placeholder.select.app", locale: locale),
                    icon: "app.dashed"
                )
            } else if isLoadingCandidates {
                loadingPlaceholder(
                    AppLocalization.string("uninstall.placeholder.scanning", locale: locale)
                )
            } else if candidates.isEmpty {
                placeholder(
                    AppLocalization.string("uninstall.placeholder.empty", locale: locale),
                    icon: "sparkles"
                )
            } else {
                List {
                    ForEach(candidates, id: \.path) { cand in
                        candidateRow(cand)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footerBar
        }
    }

    private var candidatesHeader: some View {
        HStack {
            if let app = selectedApp {
                Text(app.metadata.appName).font(.headline)
                Text(app.metadata.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("uninstall.candidates.title", bundle: .module).font(.headline)
            }
            Spacer()
            Text(AppLocalization.format(
                "uninstall.candidates.summary",
                locale: locale,
                arguments: [Int64(candidates.count), formattedBytes(totalCheckedBytes)]
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func candidateRow(_ cand: UninstallCandidate) -> some View {
        let isOn = Binding<Bool>(
            get: { checked.contains(cand.path) },
            set: { newValue in
                if newValue, UninstallDeletionSelectionPolicy.isSelectable(cand) {
                    checked.insert(cand.path)
                }
                else { checked.remove(cand.path) }
            }
        )
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .disabled(
                    isDeletionTransactionActive
                        || !UninstallDeletionSelectionPolicy.isSelectable(cand)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(cand.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(reasonLabel(cand.matchReason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !UninstallDeletionSelectionPolicy.isSelectable(cand) {
                    Text("uninstall.row.snapshot.partial", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedBytes(cand.bytes))
                    .font(.callout.monospacedDigit())
                Text(AppLocalization.format(
                    "uninstall.row.file.count",
                    locale: locale,
                    arguments: [Int64(cand.fileCount)]
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footerBar: some View {
        HStack {
            Button(AppLocalization.string(
                allChecked ? "uninstall.toggle.deselect.all" : "uninstall.toggle.select.all",
                locale: locale
            )) {
                toggleAll()
            }
            .disabled(candidates.isEmpty || isDeletionTransactionActive)

            Spacer()

            Text(AppLocalization.format(
                "uninstall.footer.selected",
                locale: locale,
                arguments: [Int64(checked.count), formattedBytes(totalCheckedBytes)]
            ))
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                prepareRealDelete()
            } label: {
                Label(
                    AppLocalization.string("uninstall.button.trash", locale: locale),
                    systemImage: "trash"
                )
            }
            .disabled(checkedPaths.isEmpty || isDeletionTransactionActive)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var allChecked: Bool {
        let selectable = UninstallDeletionSelectionPolicy.selectablePaths(in: candidates)
        return !selectable.isEmpty && checked.intersection(selectable) == selectable
    }

    private var checkedPaths: [String] {
        candidates
            .filter { checked.contains($0.path) && UninstallDeletionSelectionPolicy.isSelectable($0) }
            .map(\.path)
    }

    private var totalCheckedBytes: Int64 {
        candidates.reduce(Int64(0)) { acc, c in
            checked.contains(c.path) && UninstallDeletionSelectionPolicy.isSelectable(c)
                ? acc + c.bytes
                : acc
        }
    }

    private func toggleAll() {
        if allChecked {
            checked.removeAll()
        } else {
            checked = UninstallDeletionSelectionPolicy.selectablePaths(in: candidates)
        }
    }

    /// v2026.07.17 root-cause fix: refresh-button Tasks used to be anonymous and could overlap.
    /// An older `/Applications` result could publish after a newer refresh and close its spinner.
    /// Start state is now synchronous; every result must claim the exact reload revision.
    private func startAppListReload() {
        guard !isDeletionTransactionActive else { return }
        appListTask?.cancel()
        appListRevision &+= 1
        let identity = UninstallAppListLoadIdentity(
            operationID: UUID(),
            revision: appListRevision
        )
        appListLoadGate.begin(identity)
        isLoadingApps = true
        appListTask = Task {
            await reloadApps(identity: identity)
        }
    }

    private func reloadApps(identity: UninstallAppListLoadIdentity) async {
        let list = await store.listInstalledApps()
        let taskWasCancelled = Task.isCancelled
        await MainActor.run {
            guard let shouldPublish = self.appListLoadGate.finishIfCurrent(
                identity,
                taskWasCancelled: taskWasCancelled
            ) else { return }
            self.appListTask = nil
            self.isLoadingApps = false
            guard shouldPublish else { return }
            self.apps = list
        }
    }

    private func cancelAppListReloadForDeparture() {
        appListLoadGate.invalidate()
        appListTask?.cancel()
        appListTask = nil
        isLoadingApps = false
    }

    private func reloadCandidates(
        for app: InstalledApp,
        identity: UninstallCandidateLoadIdentity
    ) async {
        let list = await store.selectApp(app)
        let taskWasCancelled = Task.isCancelled
        await MainActor.run {
            guard let completion = self.candidateLoadGate.completeIfCurrent(
                identity,
                selectedAppID: self.selectedApp?.id,
                scanSessionID: self.selectedAppScanSessionID,
                selectionRevision: self.selectedAppRevision,
                taskWasCancelled: taskWasCancelled
            ) else { return }
            self.candidateTask = nil
            self.isLoadingCandidates = false
            guard completion == .publishResult else { return }
            self.candidates = list
        }
    }

    /// Leaving the page is a terminal owner transition for candidate discovery. Invalidate the
    /// gate before cancellation so a late synchronous filesystem return cannot publish even if
    /// the task has not observed cancellation yet. Existing rows are left untouched only to keep
    /// the disappearing frame stable; a future page instance creates a fresh scan identity.
    private func cancelCandidateLoadForDeparture() {
        candidateLoadGate.invalidate()
        candidateTask?.cancel()
        candidateTask = nil
        isLoadingCandidates = false
    }

    /// 冻结当前选择，先走与最终执行相同的 Safety / vendor / whitelist 预检。
    /// 只有完整通过才展示可执行确认；任意拒绝直接显示结构化结果，绝不调用 move。
    private func prepareRealDelete() {
        let selectedPaths = checkedPaths
        guard let selectedApp,
              !selectedPaths.isEmpty,
              !isDeleting,
              !uninstallDeletionHandoff.hasPending,
              activeSheet == nil else { return }
        let context = UninstallPreflightContext(
            appID: selectedApp.id,
            selectionRevision: selectedAppRevision,
            paths: selectedPaths
        )
        let selectedPathSet = Set(selectedPaths)
        let selectedCandidates = candidates.filter { selectedPathSet.contains($0.path) }
        // UI 已禁选 partial；这里仍在提交边界 fail closed，防止未来状态恢复/批量选择
        // 把旧的部分快照重新塞回 checked。
        guard UninstallDeletionSelectionPolicy.canSubmit(selectedCandidates) else { return }
        let selectedBytes = selectedCandidates.reduce(Int64(0)) { partial, candidate in
            let sum = partial.addingReportingOverflow(candidate.bytes)
            return sum.overflow ? .max : sum.partialValue
        }
        let bytesByPath = Dictionary(uniqueKeysWithValues: selectedCandidates.map {
            ($0.path, max(0, $0.bytes))
        })
        uninstallPreflightTask?.cancel()
        let token = uninstallPreflightGate.begin(context: context)
        let identity = DeletionSnapshotIdentity(
            sessionID: selectedAppScanSessionID,
            revision: selectedAppRevision,
            categoryID: selectedApp.id
        )
        isDeleting = true
        uninstallPreflightTask = Task { @MainActor in
            let coordinator = DeletionInteractionCoordinator(pipeline: pipeline)
            let decision: DeletionInteractionPreparation
            do {
                let intent = try coordinator.makeIntent(
                    origin: .uninstall,
                    mode: .professional,
                    snapshotIdentity: identity,
                    candidates: selectedCandidates.map { candidate in
                        UninstallDeletionSelectionPolicy.interactionSnapshot(
                            for: candidate,
                            runningBundleIDPrefix: selectedApp.metadata.bundleID
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
                    rejections: selectedPaths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                ))
            }
            let currentContext = UninstallPreflightContext(
                appID: self.selectedApp?.id ?? "",
                selectionRevision: selectedAppRevision,
                paths: selectedPaths
            )
            guard uninstallPreflightGate.finishIfCurrent(token, context: currentContext) else { return }
            uninstallPreflightTask = nil
            isDeleting = false
            guard !Task.isCancelled,
                  !uninstallDeletionHandoff.hasPending,
                  activeSheet == nil else { return }
            switch decision {
            case .confirmation(let prepared):
                activeSheet = .confirm(UninstallDeleteRequest(
                    items: prepared.confirmationCandidates,
                    totalBytes: selectedBytes,
                    bytesByPath: bytesByPath,
                    prepared: prepared,
                    appID: selectedApp.id,
                    selectionRevision: selectedAppRevision
                ))
            case .blocked(let block):
                activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
            case .cancelled:
                return
            }
        }
    }

    private func completeUninstallSheetDismissal() {
        guard let request = uninstallDeletionHandoff.takeAfterSheetDismissal() else { return }
        guard requireCurrentUninstallExecutionRequest(request) else { return }
        startUninstallExecution(request: request)
    }

    @discardableResult
    private func requireCurrentUninstallRequest(
        _ request: UninstallDeleteRequest,
        boundSnapshotIdentity: DeletionSnapshotIdentity? = nil
    ) -> Bool {
        let identity = boundSnapshotIdentity
            ?? request.prepared.plan.intent.snapshotIdentity
        switch UninstallDeletionSubmissionGate.evaluate(
            requestAppID: request.appID,
            requestSelectionRevision: request.selectionRevision,
            boundSnapshotIdentity: identity,
            currentAppID: selectedApp?.id,
            currentScanSessionID: selectedAppScanSessionID,
            currentSelectionRevision: selectedAppRevision,
            paths: request.paths
        ) {
        case .current:
            return true
        case .cancelled(let rejections):
            GSYLog.notice(
                .trash,
                "Uninstall rejected stale deletion intent app=\(request.appID) revision=\(request.selectionRevision) currentApp=\(selectedApp?.id ?? "nil") currentRevision=\(selectedAppRevision)"
            )
            activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: rejections))
            return false
        }
    }

    @discardableResult
    private func requireCurrentUninstallExecutionRequest(
        _ execution: UninstallExecutionRequest,
        boundSnapshotIdentity: DeletionSnapshotIdentity? = nil
    ) -> Bool {
        guard execution.appID == execution.request.appID,
              execution.selectionRevision == execution.request.selectionRevision else {
            activeSheet = .preflightNotice(DeletionPreflightNotice(
                rejections: execution.request.paths.map {
                    .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                }
            ))
            return false
        }
        return requireCurrentUninstallRequest(
            execution.request,
            boundSnapshotIdentity: boundSnapshotIdentity
        )
    }

    private func cancelUninstallPreflight() {
        uninstallPreflightTask?.cancel()
        uninstallPreflightTask = nil
        if uninstallPreflightGate.cancel() {
            isDeleting = false
        }
    }

    /// 只由确认 sheet 的确定性交接触发；先同步建立 owner/status/sheet，再启动异步工作，
    /// 因而不存在确认消失后数秒到数十秒的无反馈窗口。
    private func startUninstallExecution(request: UninstallExecutionRequest) {
        guard !isDeleting,
              requireCurrentUninstallExecutionRequest(request) else { return }
        let snapshot = request.request.prepared.plan.intent.snapshotIdentity
        let owner = UninstallExecutionOwner(
            id: request.request.id,
            appID: request.appID,
            scanSessionID: snapshot.sessionID,
            selectionRevision: request.selectionRevision
        )
        isDeleting = true
        uninstallExecutionOwner = owner
        uninstallExecutionStatus = .preparing(totalItems: request.request.paths.count)
        activeSheet = .execution(owner)
        uninstallExecutionTask = Task { @MainActor in
            await performDelete(request: request, owner: owner)
        }
    }

    /// v2026.07.17 revision-owned real recycle transaction. Progress is a typed side channel;
    /// only the coordinator's terminal disposition may replace the execution sheet with result.
    private func performDelete(
        request: UninstallExecutionRequest,
        owner: UninstallExecutionOwner
    ) async {
        defer {
            isDeleting = false
            uninstallExecutionTask = nil
            if uninstallExecutionOwner == owner {
                uninstallExecutionOwner = nil
                uninstallExecutionStatus = nil
            }
        }
        guard uninstallExecutionOwner == owner,
              requireCurrentUninstallExecutionRequest(request) else { return }
        let executionPlan = request.plan
        // v1.3.zzzz Phase 3-A 对称防御：UninstallScreen 没接 BulkScanner 的
        // permissionDenied 数据源（候选来自 [UninstallStore](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/UninstallStore.swift)
        // 的 NSMetadataQuery + AppCandidate），但 pipeline 是注入进来的、
        // 可能跨视图复用 [TrashPipeline](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
        // 实例。若 MainView 上一轮扫描遗留了 accessDeniedPaths 没清，
        // 切到 UninstallScreen 走 trash 时就会"莫名 accessDenied 拒了某个 ~/Library/.. 路径"。
        // 主动清空一次是 O(1) 锁开销，零误伤；实际执行与 UndoHistory 写入走统一删除入口。
        let coordinator = DeletionInteractionCoordinator(pipeline: pipeline)
        let authorization: DeletionAuthorizedInteraction
        switch coordinator.authorize(
            prepared: request.request.prepared,
            executionPlan: executionPlan
        ) {
        case .authorized(let value):
            authorization = value
        case .cancelled:
            activeSheet = nil
            return
        case .blocked(let block):
            activeSheet = .preflightNotice(DeletionPreflightNotice(
                rejections: block.rejections
            ))
            return
        }
        guard requireCurrentUninstallExecutionRequest(
            request,
            boundSnapshotIdentity: authorization.authorization.snapshotIdentity
        ) else { return }
        uninstallExecutionStatus = .preparing(
            totalItems: authorization.authorization.paths.count
        )
        let progressPair = AsyncStream<DeletionExecutionProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let progressContinuation = progressPair.continuation
        let progressConsumer = Task { @MainActor in
            for await event in progressPair.stream {
                guard let current = uninstallExecutionStatus else { continue }
                uninstallExecutionStatus = UninstallExecutionProgressReducer.reduce(
                    current: current,
                    event: event,
                    eventOwner: owner,
                    currentOwner: uninstallExecutionOwner,
                    currentAppID: selectedApp?.id,
                    currentScanSessionID: selectedAppScanSessionID,
                    currentSelectionRevision: selectedAppRevision
                )
            }
        }
        let disposition = await coordinator.submit(
            authorization,
            accessDeniedPaths: [],
            executionProgressObserver: { event in
                progressContinuation.yield(event)
            }
        )
        progressContinuation.finish()
        await progressConsumer.value
        guard uninstallExecutionOwner == owner else { return }
        let completed: DeletionCompletedInteraction
        switch disposition {
        case .completed(let value):
            completed = value
        case .requiresConfirmation(let prepared):
            guard requireCurrentUninstallExecutionRequest(request) else { return }
            let totalBytes = prepared.paths.reduce(Int64(0)) { partial, path in
                let value = request.request.bytesByPath[path] ?? 0
                let sum = partial.addingReportingOverflow(value)
                return sum.overflow ? .max : sum.partialValue
            }
            activeSheet = .confirm(UninstallDeleteRequest(
                items: prepared.confirmationCandidates,
                totalBytes: totalBytes,
                bytesByPath: request.request.bytesByPath,
                prepared: prepared,
                appID: request.appID,
                selectionRevision: request.selectionRevision
            ))
            return
        case .blocked(let block):
            activeSheet = .preflightNotice(DeletionPreflightNotice(rejections: block.rejections))
            return
        }
        let result = completed.result
        await ToolDeletionResultOrdering.finish(
            updateModelToTerminalState: {
                // Submit succeeded for these exact paths. Project them out even if a future
                // non-UI state change advanced the selection during the await; silently
                // keeping a path that has actually moved would leave the visible model false.
                let terminal = UninstallCandidateTerminalProjection.applying(
                    succeededPaths: Set(result.succeededPaths),
                    to: UninstallCandidateTerminalState(
                        candidates: self.candidates,
                        checked: self.checked
                    )
                )
                self.candidates = terminal.candidates
                self.checked = terminal.checked
            },
            makePayload: { OperationResultCompletion.deletion(completed) },
            present: { completion in
                self.activeSheet = .result(completion)
            }
        )
    }

    private func formattedBytes(_ b: Int64) -> String {
        AppLocalization.byteCount(b, locale: locale)
    }

    private func reasonLabel(_ r: MatchReason) -> String {
        switch r {
        case .bundleID(let s): return "bundleID · \(s)"
        case .bundleVendor(let s): return "vendor · \(s)"
        case .appName(let s): return "appName · \(s)"
        case .vendorRule(let s):
            return AppLocalization.format(
                "uninstall.reason.vendor.rule",
                locale: locale,
                arguments: [s]
            )
        case .spotlight(let kind): return "spotlight · \(kind)"
        case .pkgReceipt(let pkgID):
            return AppLocalization.format(
                "uninstall.reason.pkg_receipt",
                locale: locale,
                arguments: [pkgID]
            )
        }
    }

    @ViewBuilder
    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingPlaceholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeInOut(duration: 0.18), value: isLoadingCandidates)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
