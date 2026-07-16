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
    @State private var isLoadingCandidates: Bool = false
    @State private var isDeleting: Bool = false
    @State private var candidateTask: Task<Void, Never>?
    @State private var activeSheet: ActiveSheet?
    @State private var uninstallDeletionHandoff = ToolDeletionHandoff<UninstallExecutionRequest>()
    @State private var uninstallPreflightTask: Task<Void, Never>?
    @State private var uninstallPreflightGate = ToolDeletionPreflightRequestGate<UninstallPreflightContext>()
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
        .task { await reloadApps() }
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
            candidateTask?.cancel()
            candidateTask = nil
            cancelUninstallPreflight()
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
                    Task { await reloadApps() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isDeletionTransactionActive)
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
            .onChange(of: selectedApp) { _, new in
                selectedAppRevision &+= 1
                selectedAppScanSessionID = UUID()
                let scanSessionID = selectedAppScanSessionID
                cancelUninstallPreflight()
                candidateTask?.cancel()
                guard let app = new else {
                    candidates = []
                    checked = []
                    isLoadingCandidates = false
                    return
                }
                candidateTask = Task {
                    await reloadCandidates(for: app, scanSessionID: scanSessionID)
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
                if newValue { checked.insert(cand.path) }
                else { checked.remove(cand.path) }
            }
        )
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .disabled(isDeletionTransactionActive)
            VStack(alignment: .leading, spacing: 2) {
                Text(cand.path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(reasonLabel(cand.matchReason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .disabled(checked.isEmpty || isDeletionTransactionActive)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var allChecked: Bool {
        !candidates.isEmpty && checked.count == candidates.count
    }

    private var checkedPaths: [String] {
        candidates.map(\.path).filter { checked.contains($0) }
    }

    private var totalCheckedBytes: Int64 {
        candidates.reduce(Int64(0)) { acc, c in
            checked.contains(c.path) ? acc + c.bytes : acc
        }
    }

    private func toggleAll() {
        if allChecked {
            checked.removeAll()
        } else {
            checked = Set(candidates.map(\.path))
        }
    }

    private func reloadApps() async {
        guard !isDeletionTransactionActive else { return }
        isLoadingApps = true
        let list = await store.listInstalledApps()
        await MainActor.run {
            self.apps = list
            self.isLoadingApps = false
        }
    }

    private func reloadCandidates(for app: InstalledApp, scanSessionID: UUID) async {
        let selectedID = app.id
        await MainActor.run {
            self.isLoadingCandidates = true
            self.candidates = []
            self.checked = []
        }
        let list = await store.selectApp(app)
        await MainActor.run {
            guard !Task.isCancelled else { return }
            guard self.selectedApp?.id == selectedID,
                  self.selectedAppScanSessionID == scanSessionID else { return }
            self.candidates = list
            self.isLoadingCandidates = false
        }
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
                        DeletionInteractionCandidateSnapshot(
                            path: candidate.path,
                            title: URL(fileURLWithPath: candidate.path).lastPathComponent,
                            isDirectory: candidate.fileCount != 1,
                            bytes: candidate.bytes,
                            fileCount: candidate.fileCount,
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
        Task { await performDelete(request: request) }
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

    /// 只由确认 sheet 的确定性交接触发；Professional 不提供 dry-run 执行分支。
    private func performDelete(request: UninstallExecutionRequest) async {
        guard !isDeleting,
              requireCurrentUninstallExecutionRequest(request) else { return }
        isDeleting = true
        defer { isDeleting = false }
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
        let disposition = await coordinator.submit(authorization, accessDeniedPaths: [])
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
