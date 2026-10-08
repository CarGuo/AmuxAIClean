import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ScanKit
import LogKit
import SafetyKit

/// Pure routing boundary for Duplicate deletion. Keeping target-scope selection outside the
/// SwiftUI state machine makes the sibling-vs-selected incomplete contract behavior-testable.
enum DuplicateDeletionPreparationPolicy {
    static func relevantIssues(
        overlappingAny paths: [String],
        in issues: [ScanIncompleteIssue]
    ) -> [ScanIncompleteIssue] {
        var seen = Set<ScanIncompleteIssue>()
        return paths.flatMap { path in
            DeletionTargetRevalidator.relevantIssues(for: path, from: issues)
        }.filter { seen.insert($0).inserted }
    }

    static func accessEvidence(
        for path: String,
        issues: [ScanIncompleteIssue]
    ) -> DeletionAccessEvidence {
        guard let issue = DeletionTargetRevalidator.relevantIssues(
            for: path,
            from: issues
        ).first else {
            return .complete
        }
        return .incomplete(DeletionIncompleteReason(scanIncompleteReason: issue.reason))
    }

    @MainActor
    static func prepare(
        pipeline: any DeletionPipeline,
        coordinator: DeletionInteractionCoordinator,
        intent: DeletionIntent,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        rows: [RowItem],
        relevantIssues: [ScanIncompleteIssue]
    ) async -> DeletionInteractionPreparation {
        guard !relevantIssues.isEmpty else {
            return await coordinator.prepare(
                intent: intent,
                currentSnapshotIdentity: currentSnapshotIdentity
            )
        }
        let targetPreparation = await pipeline.prepareScanIncompleteOverride(
            rows: rows,
            scanIssues: relevantIssues,
            scanSessionID: currentSnapshotIdentity.sessionID
        )
        return coordinator.prepareRevalidatedScanIncomplete(
            intent: intent,
            currentSnapshotIdentity: currentSnapshotIdentity,
            preparation: targetPreparation
        )
    }
}

/// Final Duplicate authorization is valid only for the exact scan snapshot that produced it.
/// The View evaluates this boundary both after sheet dismissal and immediately before submit,
/// so a newer scan can never reuse an older confirmation even when the path text is unchanged.
enum DuplicateDeletionSubmissionGate {
    enum Decision: Sendable, Equatable {
        case current
        case cancelled([DeletionPreflight.Rejection])
    }

    static func evaluate(
        requestSessionID: UUID,
        requestRevision: UInt64,
        boundSnapshotIdentity: DeletionSnapshotIdentity,
        currentSessionID: UUID,
        currentRevision: UInt64,
        paths: [String]
    ) -> Decision {
        let requestIdentity = DeletionSnapshotIdentity(
            sessionID: requestSessionID,
            revision: requestRevision,
            categoryID: "duplicate"
        )
        guard boundSnapshotIdentity == requestIdentity,
              currentSessionID == requestSessionID,
              currentRevision == requestRevision else {
            return .cancelled(paths.map {
                .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
            })
        }
        return .current
    }
}

/// Owner for the one Duplicate execution whose progress is allowed to reach this screen.
/// Request ID is included in addition to scan identity because a user may review two different
/// groups without rescanning; neither operation may consume the other's late progress.
struct DuplicateDeletionExecutionOwner: Sendable, Equatable, Identifiable {
    let id: UUID
    let scanSessionID: UUID
    let scanRevision: UInt64
}

struct DuplicateDeletionExecutionStatus: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing
        case verifyingTargets
        case verifyingRetainedReference
        case finalizingVerification
        case submittingToTrash
        case cancelling

        var rank: Int {
            switch self {
            case .preparing: return 0
            case .verifyingTargets: return 1
            case .verifyingRetainedReference: return 2
            case .finalizingVerification: return 3
            case .cancelling: return 4
            // v2026.07.17 cancellation/submission race: the synchronous boundary is the safety
            // authority, and a subsequent submission event must replace a possibly stale
            // "stopping" presentation. Old verification frames still rank below cancelling.
            case .submittingToTrash: return 5
            }
        }

        var allowsCancellation: Bool {
            switch self {
            case .preparing, .verifyingTargets, .verifyingRetainedReference,
                 .finalizingVerification:
                return true
            case .submittingToTrash, .cancelling:
                return false
            }
        }

        var showsVerificationFraction: Bool {
            switch self {
            case .verifyingTargets, .verifyingRetainedReference:
                return true
            case .preparing, .finalizingVerification, .submittingToTrash, .cancelling:
                return false
            }
        }

        func localizedTitle(locale: Locale) -> String {
            let key: String
            switch self {
            case .preparing: key = "duplicate.execution.preparing"
            case .verifyingTargets: key = "duplicate.execution.verifying_targets"
            case .verifyingRetainedReference: key = "duplicate.execution.verifying_retained"
            case .finalizingVerification: key = "duplicate.execution.finalizing"
            case .submittingToTrash: key = "duplicate.execution.submitting"
            case .cancelling: key = "duplicate.execution.cancelling"
            }
            return AppLocalization.string(key, locale: locale)
        }
    }

    let phase: Phase
    let completedItems: Int?
    let totalItems: Int?
    let currentPath: String?

    static let preparing = DuplicateDeletionExecutionStatus(
        phase: .preparing,
        completedItems: nil,
        totalItems: nil,
        currentPath: nil
    )

    var allowsCancellation: Bool { phase.allowsCancellation }

    func markingCancellationRequested() -> DuplicateDeletionExecutionStatus {
        .init(
            phase: .cancelling,
            completedItems: completedItems,
            totalItems: totalItems,
            currentPath: currentPath
        )
    }
}

/// Synchronous, lock-protected record of the irreversible submission boundary. Progress is
/// delivered to SwiftUI through an async stream, so the visible phase may briefly lag behind the
/// worker. Navigation/cancel decisions must consult this source record instead of assuming the
/// MainActor has already rendered `.submittingToTrash`.
final class DuplicateDeletionExecutionBoundary: @unchecked Sendable {
    let owner: DuplicateDeletionExecutionOwner

    private let lock = NSLock()
    private var crossedSubmissionBoundary = false

    init(owner: DuplicateDeletionExecutionOwner) {
        self.owner = owner
    }

    func observe(_ event: DeletionExecutionProgress) {
        guard case .duplicate(let progress) = event,
              progress.phase == .submittingToTrash else { return }
        lock.lock()
        crossedSubmissionBoundary = true
        lock.unlock()
    }

    var hasCrossedSubmissionBoundary: Bool {
        lock.lock()
        defer { lock.unlock() }
        return crossedSubmissionBoundary
    }
}

/// Navigation/disappearance follows the same irreversible boundary as the execution sheet.
/// Before TrashPipeline publishes `.submittingToTrash`, cancellation is a real pre-submit
/// request observed by the full-file verifier. Once submission begins, cancelling only the
/// Swift task could orphan an in-flight NSWorkspace callback, so the operation stays owned and
/// must reach its typed terminal result. (v2026.07.17 long-task lifecycle closure.)
enum DuplicateDeletionDeparturePolicy {
    enum Action: Sendable, Equatable {
        case requestCancellation
        case preserveTrackedTransaction
        case none
    }

    static func action(
        for status: DuplicateDeletionExecutionStatus?,
        hasExecutionTask: Bool,
        hasCrossedSubmissionBoundary: Bool
    ) -> Action {
        guard hasExecutionTask, let status else { return .none }
        if hasCrossedSubmissionBoundary {
            return .preserveTrackedTransaction
        }
        return status.allowsCancellation
            ? .requestCancellation
            : .preserveTrackedTransaction
    }
}

/// Monotonic reducer for worker-queue progress. AsyncStream preserves the verifier's emission
/// order, while this reducer additionally rejects stale owner/revision events and any numeric or
/// phase regression. This is the UI-side half of the v2026.07.17 long-rehash regression closure.
enum DuplicateDeletionExecutionProgressReducer {
    static func reduce(
        current: DuplicateDeletionExecutionStatus?,
        event: DeletionExecutionProgress,
        eventOwner: DuplicateDeletionExecutionOwner,
        currentOwner: DuplicateDeletionExecutionOwner?,
        currentSessionID: UUID,
        currentRevision: UInt64
    ) -> DuplicateDeletionExecutionStatus? {
        guard currentOwner == eventOwner,
              currentSessionID == eventOwner.scanSessionID,
              currentRevision == eventOwner.scanRevision,
              case .duplicate(let progress) = event,
              progress.totalItems > 0,
              (0...progress.totalItems).contains(progress.completedItems) else {
            return current
        }

        let phase: DuplicateDeletionExecutionStatus.Phase
        switch progress.phase {
        case .verifyingTargets:
            phase = .verifyingTargets
        case .verifyingRetainedReference:
            phase = .verifyingRetainedReference
        case .submittingToTrash:
            phase = .submittingToTrash
        case .completed:
            // Every read completed, but the verifier may still return identity/content
            // rejections. Only TrashPipeline's later `.submittingToTrash` event may name the
            // submission stage; progress never declares recycle success.
            phase = .finalizingVerification
        case .cancelled:
            phase = .cancelling
        }

        if let current {
            if current.phase.rank > phase.rank { return current }
            if let currentTotal = current.totalItems,
               currentTotal != progress.totalItems { return current }
            if let currentCompleted = current.completedItems,
               currentCompleted > progress.completedItems { return current }
        }
        return .init(
            phase: phase,
            completedItems: progress.completedItems,
            totalItems: progress.totalItems,
            currentPath: progress.currentPath
        )
    }
}

private struct DuplicateDeletionExecutionSheet: View {
    @Environment(\.locale) private var locale

    let status: DuplicateDeletionExecutionStatus
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("duplicate.execution.title", bundle: .module)
                        .font(.title3.bold())
                    Text("duplicate.execution.subtitle", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                if status.phase.showsVerificationFraction,
                   let completed = status.completedItems,
                   let total = status.totalItems {
                    ProgressView(
                        value: Double(completed),
                        total: Double(max(1, total))
                    )
                    HStack {
                        Text(status.phase.localizedTitle(locale: locale))
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(completed) / \(total)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    HStack {
                        Text(status.phase.localizedTitle(locale: locale))
                            .font(.callout.weight(.medium))
                        Spacer()
                        if let completed = status.completedItems,
                           let total = status.totalItems {
                            Text("\(completed) / \(total)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let path = status.currentPath {
                    Text(AppLocalization.format(
                        "duplicate.execution.current_path",
                        locale: locale,
                        arguments: [URL(fileURLWithPath: path).lastPathComponent]
                    ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Text("duplicate.execution.safety_note", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if status.allowsCancellation {
                    Button(role: .cancel, action: onCancel) {
                        Text("duplicate.execution.stop", bundle: .module)
                    }
                    .keyboardShortcut(.cancelAction)
                } else if status.phase == .cancelling {
                    Text("duplicate.execution.stop_pending", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(22)
        // v2026.07.17: Keep the review sheet's fixed width and minimum height in the
        // flexible-frame overload; SwiftUI has no `frame(width:minHeight:)` overload.
        .frame(minWidth: 540, maxWidth: 540, minHeight: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicates.execution-sheet")
    }
}

/// v1.2 P2-1 重复文件去重屏。
///
/// 与 [AppFootprintScreen.swift](AppFootprintScreen.swift) / [LaunchAgentScreen.swift] 同源约定：
/// - DuplicateScanner 只负责「查看 / 比对」，不暴露删除 API。
/// - UI 层提供每组处理入口，删除动作统一走 TrashPipeline 移到废纸篓。
/// - 顶部 banner 醒目提示「重复检测可能漏报或误报」，prefix-only 组建议手动核对。
public struct DuplicateScreen: View {
    /// Shared across view reconstruction so leaving and immediately re-entering the page cannot
    /// create a second duplicate walker while the cancelled screen's producer is still draining.
    @MainActor private static let scanProducerSettlement = ScanProducerSettlementChain()
    @Environment(\.locale) private var locale

    /// 顶栏「最小尺寸」滑杆挡位。
    enum SizeStep: Int, CaseIterable, Identifiable {
        case mb1 = 0, mb10, mb100, gb1
        var id: Int { rawValue }
        var bytes: Int64 {
            switch self {
            case .mb1:  return 1 * 1024 * 1024
            case .mb10: return 10 * 1024 * 1024
            case .mb100: return 100 * 1024 * 1024
            case .gb1:  return 1024 * 1024 * 1024
            }
        }
        var label: String {
            switch self {
            case .mb1:  return "1 MB"
            case .mb10: return "10 MB"
            case .mb100: return "100 MB"
            case .gb1:  return "1 GB"
            }
        }
    }

    /// v2026.07.15：扫描状态只保存稳定语义，不再保存启动语言下生成的阶段文案。
    /// footer 每次渲染都按当前 View locale 投影，切换语言不会等待下一轮扫描。
    enum ScanPhase: Equatable, Sendable {
        case enumerate
        case prefixHash
        case fullHash

        func localizedTitle(locale: Locale) -> String {
            let key: String
            switch self {
            case .enumerate: key = "duplicate.phase.enumerate"
            case .prefixHash: key = "duplicate.phase.prefix_hash"
            case .fullHash: key = "duplicate.phase.full_hash"
            }
            return AppLocalization.string(key, locale: locale)
        }
    }

    // MARK: - State

    @State private var roots: [URL] = DuplicateScreen.defaultRoots()
    @State private var minStep: SizeStep = .mb10
    @StateObject private var results = DuplicateResultsStore()
    private var groups: [DuplicateGroup] { results.groups }
    @State private var selectedGroupID: String?
    @State private var inlineSelectedPaths: Set<String> = []
    @State private var isScanning: Bool = false
    @State private var scanPhase: ScanPhase?
    @State private var bucketsDone: Int = 0
    @State private var bucketsTotal: Int = 0
    @State private var sizingFiles: Int = 0
    @State private var scanTask: Task<Void, Never>?
    @State private var tccSkippedRoots: [String] = []
    /// Typed completeness evidence belongs to one DuplicateScanner session. It is kept
    /// separately from the footer projection so an unrelated unreadable sibling cannot
    /// disable every deletion action in the screen.
    @State private var scanIncompleteIssues: [ScanIncompleteIssue] = []
    /// v2026.07.17 performance closure: preserve the array's stable presentation order while
    /// making duplicate evidence insertion O(1), not an O(n²) `Array.contains` scan on MainActor.
    @State private var scanIncompleteIssueIndex: Set<ScanIncompleteIssue> = []
    @State private var scanSessionID = UUID()
    @State private var scanRevision: UInt64 = 0
    @State private var activeSheet: ActiveSheet?
    @State private var preflightNotice: DeletionPreflightNotice?
    @State private var isDeletingDuplicates: Bool = false
    @State private var isRootImporterPresented = false
    @State private var duplicateDeletionHandoff = ToolDeletionHandoff<DuplicateConfirmedDeletion>()
    @State private var duplicatePreflightTask: Task<Void, Never>?
    @State private var duplicatePreflightGate = ToolDeletionPreflightRequestGate<DuplicatePreflightContext>()
    @State private var duplicateExecutionTask: Task<Void, Never>?
    @State private var duplicateExecutionOwner: DuplicateDeletionExecutionOwner?
    @State private var duplicateExecutionStatus: DuplicateDeletionExecutionStatus?
    @State private var duplicateExecutionBoundary: DuplicateDeletionExecutionBoundary?

    private let pipeline: any DeletionPipeline
    /// v2026.07.20 P0: never pair a scripted duplicate pipeline with production Undo history.
    private let undoHistoryStore: UndoHistoryStore

    private struct DuplicateDeleteRequest: Identifiable, Sendable {
        let id = UUID()
        let scanSessionID: UUID
        let scanRevision: UInt64
        let items: [RunningAppGuard.Candidate]
        let totalBytes: Int64
        let bytesByPath: [String: Int64]
        let accessEvidencePaths: Set<String>
        let prepared: DeletionPreparedInteraction

        var paths: [String] { items.map(\.path) }
    }

    private struct DuplicateConfirmedDeletion: Sendable {
        let request: DuplicateDeleteRequest
        let executionPlan: ToolTrashExecutionPlan
    }

    private struct DuplicatePreflightContext: Sendable, Equatable {
        let groupID: String
        let paths: [String]
        let scanSessionID: UUID
        let scanRevision: UInt64
    }

    private enum ActiveSheet: Identifiable {
        case handle(DuplicateGroup)
        case confirm(DuplicateDeleteRequest)
        case execution(DuplicateDeletionExecutionOwner)
        case result(OperationResultCompletion)

        var id: String {
            switch self {
            case .handle(let group): return "handle-\(group.id)"
            case .confirm(let request): return "confirm-\(request.id)"
            case .execution(let owner): return "execution-\(owner.id.uuidString)"
            case .result(let payload): return "result-\(payload.id)"
            }
        }
    }

    public init(
        pipeline: any DeletionPipeline,
        undoHistoryStore: UndoHistoryStore
    ) {
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
    }

    public var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            topBar
            Divider()
            // v1.3.aa：原本 HSplitView { left minWidth:320 + right minWidth:320 }，
            // 总和 640 远超外层 NavigationSplitView 的 detail 列容纳，会反向把
            // 外层 sidebar 挤掉一半（图 2 的"sidebar 推到右、内容溢出"）。
            // 改成 HStack + Divider 后约束传播正常，不再挤外层。
            // v1.3.ab：进一步——给左右栏都加 maxWidth: .infinity，强制平分剩余宽度，
            // 不让某栏内的长路径 ideal width 反向把整个 HStack 撑出窗口外（图2 第二轮根因）。
            HStack(spacing: 0) {
                leftList
                    .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity)
                    .layoutPriority(1)
                Divider()
                rightDetail
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .layoutPriority(1)
            }
            // v1.3.ab：HStack 本身也兜底 maxWidth，让 SwiftUI 把外层窗口宽度作为权威 proposed。
            .frame(maxWidth: .infinity)
            Divider()
            footer
        }
        // v1.3.ab：整个 VStack 也强制 maxWidth: .infinity，
        // 让 banner / topBar 内的 chip / 滑杆 即使 ideal width 较大也不会反推外层。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v2026.07.20 P0: preserve duplicate selection while the non-modal explanation floats.
        .deletionPreflightNoticeOverlay(preflightNotice) {
            preflightNotice = nil
        }
        .onDisappear {
            cancelActiveScan()
            cancelDuplicatePreflight()
            handleDuplicateExecutionDeparture()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gsyTrashDidMove)) { notification in
            let source = notification.userInfo?["source"] as? String
            guard source != DeleteRequestOrigin.duplicate.historySource else { return }
            let paths = notification.userInfo?["paths"] as? [String] ?? []
            guard !paths.isEmpty, !groups.isEmpty else { return }
            let expectedSessionID = scanSessionID
            Task { @MainActor in
                await pruneMovedDuplicatePaths(Set(paths), expectedSessionID: expectedSessionID)
            }
        }
        .localizedSheet(
            isPresented: Binding(
                get: { activeSheet != nil },
                set: {
                    if !$0 {
                        cancelDuplicatePreflight()
                        activeSheet = nil
                    }
                }
            ),
            onDismiss: completeDuplicateSheetDismissal
        ) {
            if let sheet = activeSheet {
                switch sheet {
                case .handle(let group):
                    DuplicateHandleSheet(
                        group: group,
                        isDeleting: isDeletingDuplicates,
                        onCancel: {
                            cancelDuplicatePreflight()
                            activeSheet = nil
                        },
                        onDefault: {
                            prepareDuplicateDeletion(
                                group: group,
                                paths: DuplicateHandlingPlan.defaultDeleteTargets(for: group)
                            )
                        },
                        onManual: { paths in
                            prepareDuplicateDeletion(group: group, paths: paths)
                        }
                    )
                case .confirm(let request):
                    ToolTrashConfirmationSheet(
                        items: request.items,
                        totalBytes: request.totalBytes,
                        vendorOverrideRequest: request.prepared.vendorOverrideRequest,
                        scanIncompleteOverrideRequest: request.prepared.scanIncompleteOverrideRequest,
                        onCancel: { activeSheet = nil },
                        onConfirm: { executionPlan in
                            guard requireCurrentDuplicateRequest(request) else { return false }
                            guard duplicateDeletionHandoff.schedule(DuplicateConfirmedDeletion(
                                request: request,
                                executionPlan: executionPlan
                            )) else { return false }
                            activeSheet = nil
                            return true
                        }
                    )
                case .execution(let owner):
                    DuplicateDeletionExecutionSheet(
                        status: duplicateExecutionStatus ?? .preparing,
                        onCancel: {
                            requestDuplicateExecutionCancellation(owner: owner)
                        }
                    )
                    .interactiveDismissDisabled(true)
                case .result(let completion):
                    OperationResultSheet(completion: completion) {
                        activeSheet = nil
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isRootImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true,
            onCompletion: handleRootImport
        )
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("duplicate.banner.title", bundle: .module)
                    .font(.callout.bold())
                Text("duplicate.banner.detail", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        // v1.3.ab：banner 强制 maxWidth: .infinity，避免标题文本 ideal width 反推。
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.10))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.orange.opacity(0.4)),
                 alignment: .bottom)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // 扫描根（固定默认 + 可加）
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.format(
                    "duplicate.topbar.roots",
                    locale: locale,
                    arguments: [Int64(roots.count)]
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                // v1.3.ab：扫描根 chip 横排——根多了之后 ideal width 会爆窗口，
                // 包一层 ScrollView(.horizontal) 让它在窗口窄时滚动，不再反推父容器。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(roots, id: \.self) { url in
                            rootChip(url)
                                // 单个 chip 内长路径已有 truncation，再硬限上限避免 chip 自己撑爆
                                .frame(maxWidth: 220)
                        }
                        Button {
                            isRootImporterPresented = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isScanning || isDeletionTransactionActive)
                    }
                }
            }
            // v1.3.ab：左侧 chip 区允许伸缩，但优先级低于右侧控件——
            // 让滑杆/按钮始终可见，多余宽度被 ScrollView 滚动吸收。
            .layoutPriority(0)
            Spacer(minLength: 12)
            // 最小尺寸滑杆
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.format(
                    "duplicate.topbar.min_size",
                    locale: locale,
                    arguments: [minStep.label]
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker("", selection: $minStep) {
                    ForEach(SizeStep.allCases) { step in
                        Text(step.label).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                // v1.3.ab：原本 `.frame(width: 280)` 死宽度，窗口窄时会反推父级。
                // 改成 minWidth/idealWidth/maxWidth，给 SwiftUI 空间在窄窗口下压缩。
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 320)
                .disabled(isScanning || isDeletionTransactionActive)
            }
            .layoutPriority(1)
            // 开始 / 停止
            if isScanning {
                Button(role: .cancel) {
                    cancelActiveScan()
                } label: {
                    Label {
                        Text("duplicate.topbar.stop", bundle: .module)
                    } icon: {
                        Image(systemName: "stop.circle")
                    }
                }
                // v2026.07.17 C4 contract: start/stop are one semantic control whose stable AX
                // identity survives the state swap; this adds no test-only branch or layout.
                .accessibilityIdentifier("duplicates.scan-control")
            } else {
                Button {
                    startScan()
                } label: {
                    Label {
                        Text("duplicate.topbar.start", bundle: .module)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty || isDeletionTransactionActive)
                .accessibilityIdentifier("duplicates.scan-control")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // v1.3.ab：topBar 整段强制 maxWidth: .infinity，与外层 VStack 一致，
        // 防止内部子视图本征宽度反推。
        .frame(maxWidth: .infinity)
    }

    private func rootChip(_ url: URL) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(displayName(for: url))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                roots.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isScanning || isDeletionTransactionActive)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Left list

    private var leftList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("duplicate.left.title", bundle: .module).font(.headline)
                if !groups.isEmpty {
                    Text("· \(groups.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if isScanning && groups.isEmpty {
                placeholder(
                    AppLocalization.string("duplicate.placeholder.scanning", locale: locale),
                    systemImage: "hourglass"
                )
            } else if groups.isEmpty {
                placeholder(
                    AppLocalization.string("duplicate.placeholder.no_results", locale: locale),
                    systemImage: "doc.on.doc"
                )
            } else {
                List(selection: $selectedGroupID) {
                    ForEach(groups) { g in
                        groupRow(g).tag(g.id)
                    }
                }
                .listStyle(.inset)
                .onValueChange(of: selectedGroupID) { _, newID in
                    if let g = groups.first(where: { $0.id == newID }) {
                        inlineSelectedPaths = Set(DuplicateHandlingPlan.keepNewestDeleteTargets(for: g))
                    } else {
                        inlineSelectedPaths = []
                    }
                }
            }
        }
    }

    private func groupRow(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: g.reliability == .full ? "checkmark.seal.fill" : "questionmark.circle.fill")
                    .foregroundStyle(g.reliability == .full ? .green : .orange)
                    .font(.caption)
                Text(AppLocalization.format(
                    "duplicate.group.copies",
                    locale: locale,
                    arguments: [Int64(g.files.count)]
                ))
                    .font(.callout.bold())
                Spacer()
                Text(byteString(g.totalBytes))
                    .font(.callout.monospacedDigit())
                Button {
                    activeSheet = .handle(g)
                } label: {
                    Label(AppLocalization.string("duplicate.action.handle", locale: locale),
                          systemImage: "checklist")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(AppLocalization.string("duplicate.action.handle", locale: locale))
                .disabled(isDeletingDuplicates)
            }
            Text(AppLocalization.format(
                "duplicate.group.reclaim_per",
                locale: locale,
                arguments: [byteString(g.reclaimableBytes), byteString(g.logicalBytes)]
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(g.files.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Right detail

    private var rightDetail: some View {
        VStack(spacing: 0) {
            if let g = selectedGroup {
                detailHeader(g)
                Divider()
                List {
                    ForEach(g.files, id: \.path) { file in
                        pathRow(file, in: g)
                            .contextMenu {
                                Button {
                                    QuickLookController.shared.preview(urls: [URL(fileURLWithPath: file.path)])
                                } label: {
                                    Text("tree.menu.quick_look", bundle: .module)
                                }
                                Button {
                                    revealInFinder(path: file.path)
                                } label: {
                                    Text("duplicate.menu.reveal_in_finder", bundle: .module)
                                }
                                Button {
                                    copyToPasteboard(file.path)
                                } label: {
                                    Text("duplicate.menu.copy_path", bundle: .module)
                                }
                            }
                    }
                }
                .listStyle(.inset)
                Divider()
                detailActionBar(g)
            } else {
                placeholder(
                    AppLocalization.string("duplicate.placeholder.select_group", locale: locale),
                    systemImage: "sidebar.right"
                )
            }
        }
    }

    private func detailHeader(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(AppLocalization.string(
                    g.reliability == .full
                        ? "duplicate.detail.full_hash"
                        : "duplicate.detail.prefix_hash",
                    locale: locale
                ))
                    .font(.callout.bold())
                    .foregroundStyle(g.reliability == .full ? .green : .orange)
                Spacer()
                Text(AppLocalization.format(
                    "duplicate.detail.copies_size",
                    locale: locale,
                    arguments: [Int64(g.files.count), byteString(g.logicalBytes)]
                ))
                    .font(.callout.monospacedDigit())
                Button {
                    inlineSelectedPaths = Set(DuplicateHandlingPlan.keepNewestDeleteTargets(for: g))
                } label: {
                    Label(AppLocalization.string("duplicate.handle.default.button", locale: locale),
                          systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(isDeletingDuplicates || !DuplicateHandlingPlan.isExecutableGroup(g))
                Button {
                    activeSheet = .handle(g)
                } label: {
                    Label(AppLocalization.string("duplicate.action.handle", locale: locale),
                          systemImage: "checklist")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .help(AppLocalization.string("duplicate.action.handle", locale: locale))
                .disabled(isDeletingDuplicates)
            }
            Text(AppLocalization.format(
                "duplicate.detail.reclaimable",
                locale: locale,
                arguments: [byteString(g.reclaimableBytes)]
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("duplicate.detail.tip", bundle: .module)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func detailActionBar(_ g: DuplicateGroup) -> some View {
        let validTargets = inlineSelectedPaths.intersection(Set(g.files.map(\.path)))
        let selectedBytes = g.allocatedBytes(for: Array(validTargets))
        return HStack {
            Text(AppLocalization.format(
                "duplicate.handle.selected %lld %@",
                locale: locale,
                arguments: [Int64(validTargets.count), byteString(selectedBytes)]
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("duplicate.handle.manual.button", locale: locale), role: .destructive) {
                prepareDuplicateDeletion(group: g, paths: Array(validTargets))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(
                isDeletingDuplicates
                    || !DuplicateHandlingPlan.isExecutableGroup(g)
                    || validTargets.isEmpty
                    || validTargets.count >= g.files.count
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func inlineBinding(for path: String, in group: DuplicateGroup) -> Binding<Bool> {
        Binding(
            get: { inlineSelectedPaths.contains(path) },
            set: { newValue in
                if newValue {
                    inlineSelectedPaths.insert(path)
                } else {
                    inlineSelectedPaths.remove(path)
                }
            }
        )
    }

    private func pathRow(_ file: DuplicateFile, in group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: inlineBinding(for: file.path, in: group))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isDeletingDuplicates || !DuplicateHandlingPlan.isExecutableGroup(group))
            Image(systemName: "doc")
                .foregroundStyle(.tint)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let mtime = DuplicateHandlingPlan.modificationDate(for: file) {
                Text(mtime.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button {
                QuickLookController.shared.preview(urls: [URL(fileURLWithPath: file.path)])
            } label: {
                Image(systemName: "eye")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.string("tree.menu.quick_look", locale: locale))
            Text(byteString(file.allocatedBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if isScanning {
                ProgressView().controlSize(.small)
                let phaseTitle = scanPhase?.localizedTitle(locale: locale) ?? ""
                if bucketsTotal > 0 {
                    Text(AppLocalization.format(
                        "duplicate.footer.phase_progress",
                        locale: locale,
                        arguments: [phaseTitle, Int64(bucketsDone), Int64(bucketsTotal)]
                    ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(AppLocalization.format(
                        "duplicate.footer.phase_candidates",
                        locale: locale,
                        arguments: [phaseTitle, Int64(sizingFiles)]
                    ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if let duplicateExecutionStatus {
                ProgressView().controlSize(.small)
                if let completed = duplicateExecutionStatus.completedItems,
                   let total = duplicateExecutionStatus.totalItems {
                    Text(AppLocalization.format(
                        "duplicate.footer.phase_progress",
                        locale: locale,
                        arguments: [
                            duplicateExecutionStatus.phase.localizedTitle(locale: locale),
                            Int64(completed),
                            Int64(total)
                        ]
                    ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(duplicateExecutionStatus.phase.localizedTitle(locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !groups.isEmpty {
                let totalReclaim = groups.map(\.reclaimableBytes).reduce(0, +)
                Text(AppLocalization.format(
                    "duplicate.footer.summary",
                    locale: locale,
                    arguments: [Int64(groups.count), byteString(totalReclaim)]
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !tccSkippedRoots.isEmpty {
                Text(AppLocalization.format(
                    "duplicate.footer.tcc_skipped",
                    locale: locale,
                    arguments: [Int64(tccSkippedRoots.count)]
                ))
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            if !scanIncompleteIssues.isEmpty {
                Text("main.scan.incomplete", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Text("duplicate.footer.delete_hint", bundle: .module)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicates.status")
    }

    // MARK: - Helpers

    private var selectedGroup: DuplicateGroup? {
        guard let id = selectedGroupID else { return nil }
        return groups.first { $0.id == id }
    }

    /// A scan revision must remain immutable from deletion preflight through final submit.
    /// The visible scan controls use this projection, while `startScan()` repeats the guard so
    /// programmatic or future entry points cannot bypass the UI-disabled state.
    private var isDeletionTransactionActive: Bool {
        if isDeletingDuplicates
            || duplicatePreflightTask != nil
            || duplicatePreflightGate.hasCurrentRequest
            || duplicateDeletionHandoff.hasPending {
            return true
        }
        switch activeSheet {
        case .handle, .confirm, .execution:
            return true
        case .result, .none:
            return false
        }
    }

    private static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL,
            home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL,
            home.appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL
        ]
    }

    private func displayName(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        if p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }

    private func byteString(_ b: Int64) -> String {
        AppLocalization.byteCount(b, locale: locale)
    }

    @ViewBuilder
    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleRootImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            for raw in urls {
                let url = raw.standardizedFileURL
                if !roots.contains(url) {
                    roots.append(url)
                }
            }
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            GSYLog.error(.settings, "duplicate root importer failed: \(error.localizedDescription)")
        }
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func prepareDuplicateDeletion(group: DuplicateGroup, paths: [String]) {
        guard !isDeletingDuplicates,
              !duplicateDeletionHandoff.hasPending else { return }
        // v2026.07.20: a prior rejection does not own deletion transaction state.
        preflightNotice = nil
        guard DuplicateHandlingPlan.isValidDeleteTargets(paths, for: group),
              let executionVerification = DuplicateDeletionVerificationRequest(
                  group: group,
                  targetPaths: paths
              ) else {
            // Invalid/stale duplicate evidence is still a zero-submission rejection. Do not
            // silently ignore the click or promote it into an execution result presentation.
            preflightNotice = DeletionPreflightNotice(
                rejections: paths.map {
                    .init(
                        path: $0,
                        reason: DuplicateDeletionVerificationRejectionReason.invalidEvidence.rawValue
                    )
                }
            )
            return
        }
        let sessionID = scanSessionID
        let revision = scanRevision
        let relevantIssues = incompleteIssues(overlappingAny: paths)
        let context = DuplicatePreflightContext(
            groupID: group.id,
            paths: paths,
            scanSessionID: sessionID,
            scanRevision: revision
        )
        duplicatePreflightTask?.cancel()
        let token = duplicatePreflightGate.begin(context: context)
        isDeletingDuplicates = true
        duplicatePreflightTask = Task { @MainActor in
            let identity = DeletionSnapshotIdentity(
                sessionID: sessionID,
                revision: revision,
                categoryID: "duplicate"
            )
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
            let decision: DeletionInteractionPreparation
            do {
                let bytesByPath = duplicateBytesByPath(paths: paths, in: group)
                let rows = duplicateDeletionRows(
                    paths: paths,
                    bytesByPath: bytesByPath
                )
                let intent = try coordinator.makeIntent(
                    origin: .duplicate,
                    mode: .professional,
                    snapshotIdentity: identity,
                    candidates: paths.map { path in
                        DeletionInteractionCandidateSnapshot(
                            path: path,
                            title: URL(fileURLWithPath: path).lastPathComponent,
                            isDirectory: false,
                            bytes: bytesByPath[path] ?? 0,
                            fileCount: 1,
                            accessEvidence: deletionAccessEvidence(
                                for: path,
                                issues: relevantIssues
                            )
                        )
                    },
                    executionVerification: .duplicate(executionVerification)
                )
                decision = await DuplicateDeletionPreparationPolicy.prepare(
                    pipeline: pipeline,
                    coordinator: coordinator,
                    intent: intent,
                    currentSnapshotIdentity: identity,
                    rows: rows,
                    relevantIssues: relevantIssues
                )
            } catch {
                decision = .blocked(DeletionInteractionBlock(
                    intentID: UUID(),
                    rejections: paths.map {
                        .init(path: $0, reason: SafetyRejection.preflightCancelled.rawValue)
                    }
                ))
            }
            guard duplicatePreflightGate.finishIfCurrent(token, context: context) else { return }
            duplicatePreflightTask = nil
            isDeletingDuplicates = false
            guard !Task.isCancelled,
                  scanSessionID == sessionID,
                  scanRevision == revision,
                  !duplicateDeletionHandoff.hasPending else { return }
            switch decision {
            case .confirmation(let prepared):
                activeSheet = .confirm(DuplicateDeleteRequest(
                    scanSessionID: sessionID,
                    scanRevision: revision,
                    items: prepared.confirmationCandidates,
                    totalBytes: selectedBytes(paths: prepared.paths, in: group),
                    bytesByPath: duplicateBytesByPath(paths: prepared.paths, in: group),
                    accessEvidencePaths: incompleteEvidencePaths(in: prepared),
                    prepared: prepared
                ))
            case .blocked(let block):
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
            case .cancelled:
                return
            }
        }
    }

    private func completeDuplicateSheetDismissal() {
        guard let submission = duplicateDeletionHandoff.takeAfterSheetDismissal() else { return }
        guard requireCurrentDuplicateRequest(submission.request) else { return }
        executeDuplicateDeletion(submission)
    }

    @discardableResult
    private func requireCurrentDuplicateRequest(
        _ request: DuplicateDeleteRequest,
        boundSnapshotIdentity: DeletionSnapshotIdentity? = nil
    ) -> Bool {
        let identity = boundSnapshotIdentity
            ?? request.prepared.plan.intent.snapshotIdentity
        switch DuplicateDeletionSubmissionGate.evaluate(
            requestSessionID: request.scanSessionID,
            requestRevision: request.scanRevision,
            boundSnapshotIdentity: identity,
            currentSessionID: scanSessionID,
            currentRevision: scanRevision,
            paths: request.paths
        ) {
        case .current:
            return true
        case .cancelled(let rejections):
            GSYLog.notice(
                .trash,
                "Duplicate rejected stale deletion intent revision=\(request.scanRevision) current=\(scanRevision)"
            )
            activeSheet = nil
            preflightNotice = DeletionPreflightNotice(rejections: rejections)
            return false
        }
    }

    private func cancelDuplicatePreflight() {
        duplicatePreflightTask?.cancel()
        duplicatePreflightTask = nil
        if duplicatePreflightGate.cancel() {
            isDeletingDuplicates = false
        }
    }

    private func executeDuplicateDeletion(_ submission: DuplicateConfirmedDeletion) {
        guard !isDeletingDuplicates,
              requireCurrentDuplicateRequest(submission.request) else { return }
        let owner = DuplicateDeletionExecutionOwner(
            id: submission.request.id,
            scanSessionID: submission.request.scanSessionID,
            scanRevision: submission.request.scanRevision
        )
        isDeletingDuplicates = true
        duplicateExecutionOwner = owner
        duplicateExecutionStatus = .preparing
        let executionBoundary = DuplicateDeletionExecutionBoundary(owner: owner)
        duplicateExecutionBoundary = executionBoundary
        activeSheet = .execution(owner)
        duplicateExecutionTask = Task { @MainActor in
            defer {
                isDeletingDuplicates = false
                duplicateExecutionTask = nil
                if duplicateExecutionOwner == owner {
                    duplicateExecutionOwner = nil
                    duplicateExecutionStatus = nil
                    duplicateExecutionBoundary = nil
                }
            }
            guard requireCurrentDuplicateRequest(submission.request) else { return }
            let executionPlan = submission.executionPlan
            let coordinator = DeletionInteractionCoordinator(
                pipeline: pipeline,
                undoHistoryStore: undoHistoryStore
            )
            let authorization: DeletionAuthorizedInteraction
            switch coordinator.authorize(
                prepared: submission.request.prepared,
                executionPlan: executionPlan
            ) {
            case .authorized(let value):
                authorization = value
            case .cancelled:
                activeSheet = nil
                return
            case .blocked(let block):
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(
                    rejections: block.rejections
                )
                return
            }
            guard requireCurrentDuplicateRequest(
                submission.request,
                boundSnapshotIdentity: authorization.authorization.snapshotIdentity
            ) else { return }
            let frozenEvidencePaths = incompleteEvidencePaths(in: authorization)
            guard frozenEvidencePaths.isSubset(of: submission.request.accessEvidencePaths) else {
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(
                    rejections: authorization.authorization.paths.map {
                        .init(
                            path: $0,
                            reason: ScanIncompleteTargetRejectionReason
                                .missingTypedEvidence.rawValue
                        )
                    }
                )
                return
            }
            let progressPair = AsyncStream<DeletionExecutionProgress>.makeStream(
                bufferingPolicy: .bufferingNewest(16)
            )
            let progressContinuation = progressPair.continuation
            let progressConsumer = Task { @MainActor in
                for await event in progressPair.stream {
                    duplicateExecutionStatus = DuplicateDeletionExecutionProgressReducer.reduce(
                        current: duplicateExecutionStatus,
                        event: event,
                        eventOwner: owner,
                        currentOwner: duplicateExecutionOwner,
                        currentSessionID: scanSessionID,
                        currentRevision: scanRevision
                    )
                }
            }
            let disposition = await coordinator.submit(
                authorization,
                accessDeniedPaths: frozenEvidencePaths,
                executionProgressObserver: { event in
                    // The verifier emits on its hashing queue. AsyncStream is a Sendable,
                    // bounded handoff; only the MainActor consumer above mutates SwiftUI state.
                    // Record the irreversible boundary before enqueueing its presentation event;
                    // otherwise navigation could cancel a recycle already submitted by a faster
                    // worker while MainActor still displays the previous phase.
                    executionBoundary.observe(event)
                    progressContinuation.yield(event)
                }
            )
            progressContinuation.finish()
            await progressConsumer.value
            // A terminal belongs to the same request owner that presented this execution sheet.
            // This guard does not decide success (the typed disposition below does); it only
            // prevents a theoretically late old task from replacing a newer sheet.
            guard duplicateExecutionOwner == owner else { return }
            let completed: DeletionCompletedInteraction
            switch disposition {
            case .completed(let value):
                completed = value

            case .requiresConfirmation(let prepared):
                let strictPaths = Set(prepared.paths)
                let totalBytes = prepared.paths.reduce(Int64(0)) { partial, path in
                    let value = max(0, submission.request.bytesByPath[path] ?? 0)
                    let sum = partial.addingReportingOverflow(value)
                    return sum.overflow ? .max : sum.partialValue
                }
                activeSheet = .confirm(DuplicateDeleteRequest(
                    scanSessionID: submission.request.scanSessionID,
                    scanRevision: submission.request.scanRevision,
                    items: prepared.confirmationCandidates,
                    totalBytes: totalBytes,
                    bytesByPath: submission.request.bytesByPath.filter {
                        strictPaths.contains($0.key)
                    },
                    accessEvidencePaths: incompleteEvidencePaths(in: prepared),
                    prepared: prepared
                ))
                return

            case .blocked(let block):
                activeSheet = nil
                preflightNotice = DeletionPreflightNotice(rejections: block.rejections)
                return
            }
            let result = completed.result
            let succeededPaths = result.succeededPaths
            let succeededSet = Set(succeededPaths.map(TrashPipeline.normalizePath))
            let releasedBytes = authorization.prepared.plan.submittableItems.reduce(Int64(0)) { partial, item in
                succeededSet.contains(TrashPipeline.normalizePath(item.candidate.rawPath))
                    ? partial + max(0, item.candidate.bytes)
                    : partial
            }
            activeSheet = .result(.deletion(completed))
            if !succeededPaths.isEmpty {
                await pruneMovedDuplicatePaths(
                    Set(succeededPaths), expectedSessionID: submission.request.scanSessionID
                )
                Task.detached(priority: .utility) { [releasedBytes, succeededPaths] in
                    await HeuristicRecorder().recordTrashed(paths: succeededPaths)
                    if releasedBytes > 0 {
                        await CleanStatsStore.shared.record(
                            bytesReclaimed: releasedBytes,
                            category: "duplicate"
                        )
                    }
                }
            }
        }
    }

    private func requestDuplicateExecutionCancellation(
        owner: DuplicateDeletionExecutionOwner
    ) {
        guard duplicateExecutionOwner == owner,
              let status = duplicateExecutionStatus,
              status.allowsCancellation,
              duplicateExecutionBoundary?.owner == owner,
              duplicateExecutionBoundary?.hasCrossedSubmissionBoundary == false else { return }
        duplicateExecutionStatus = status.markingCancellationRequested()
        duplicateExecutionTask?.cancel()
    }

    private func handleDuplicateExecutionDeparture() {
        switch DuplicateDeletionDeparturePolicy.action(
            for: duplicateExecutionStatus,
            hasExecutionTask: duplicateExecutionTask != nil,
            hasCrossedSubmissionBoundary:
                duplicateExecutionBoundary?.hasCrossedSubmissionBoundary ?? false
        ) {
        case .requestCancellation:
            guard let owner = duplicateExecutionOwner else { return }
            requestDuplicateExecutionCancellation(owner: owner)
        case .preserveTrackedTransaction:
            // The owner/task/status intentionally remain attached to this view state. The typed
            // recycle disposition may still arrive after navigation and is the only authority
            // allowed to replace the execution sheet with a result/notice.
            break
        case .none:
            break
        }
    }

    private func selectedBytes(paths: [String], in group: DuplicateGroup) -> Int64 {
        let selected = Set(paths)
        var total: Int64 = 0
        for file in group.files where selected.contains(file.path) {
            let sum = total.addingReportingOverflow(file.allocatedBytes)
            total = sum.overflow ? .max : sum.partialValue
        }
        return total
    }

    private func duplicateBytesByPath(
        paths: [String],
        in group: DuplicateGroup
    ) -> [String: Int64] {
        let selected = Set(paths)
        return Dictionary(uniqueKeysWithValues: group.files.lazy
            .filter { selected.contains($0.path) }
            .map { ($0.path, max(0, $0.allocatedBytes)) })
    }

    private func duplicateDeletionRows(
        paths: [String],
        bytesByPath: [String: Int64]
    ) -> [RowItem] {
        paths.map { path in
            RowItem(
                id: path,
                url: URL(fileURLWithPath: path),
                title: URL(fileURLWithPath: path).lastPathComponent,
                isDirectory: false,
                bytes: max(0, bytesByPath[path] ?? 0),
                logicalBytes: max(0, bytesByPath[path] ?? 0),
                fileCount: 1,
                verdict: .safe,
                rejection: .ok
            )
        }
    }

    private func incompleteIssues(overlappingAny paths: [String]) -> [ScanIncompleteIssue] {
        DuplicateDeletionPreparationPolicy.relevantIssues(
            overlappingAny: paths,
            in: scanIncompleteIssues
        )
    }

    private func deletionAccessEvidence(
        for path: String,
        issues: [ScanIncompleteIssue]
    ) -> DeletionAccessEvidence {
        DuplicateDeletionPreparationPolicy.accessEvidence(for: path, issues: issues)
    }

    private func incompleteEvidencePaths(
        in prepared: DeletionPreparedInteraction
    ) -> Set<String> {
        Set(prepared.scanIncompleteOverrideRequest?.entries
            .flatMap(\.incompleteIssues)
            .map(\.path) ?? [])
    }

    private func incompleteEvidencePaths(
        in authorized: DeletionAuthorizedInteraction
    ) -> Set<String> {
        Set(authorized.scanIncompleteOverrideRequest?.entries
            .flatMap(\.incompleteIssues)
            .map(\.path) ?? [])
    }

    private func recordIncompleteIssue(_ issue: ScanIncompleteIssue) {
        let normalized = ScanIncompleteIssue(
            path: URL(fileURLWithPath: issue.path).standardizedFileURL.path,
            reason: issue.reason,
            stage: issue.stage,
            posixErrorCode: issue.posixErrorCode
        )
        guard scanIncompleteIssueIndex.insert(normalized).inserted else { return }
        scanIncompleteIssues.append(normalized)
    }

    @MainActor
    private func pruneMovedDuplicatePaths(_ moved: Set<String>, expectedSessionID: UUID) async {
        guard await results.pruneMovedPaths(moved, expectedSessionID: expectedSessionID),
            scanSessionID == expectedSessionID, !Task.isCancelled else { return }
        let prunedGroups = groups
        let selectionSurvives = selectedGroupID.map { id in
            prunedGroups.contains(where: { $0.id == id })
        } ?? false
        if !selectionSurvives { selectedGroupID = prunedGroups.first?.id }
        if let currentID = self.selectedGroupID,
           let currentGroup = prunedGroups.first(where: { $0.id == currentID }) {
            // Preserve manual choices in a surviving group; an unrelated receipt must not
            // silently select extra deletion targets. A new group uses its usual default.
            inlineSelectedPaths = selectionSurvives
                ? inlineSelectedPaths.intersection(Set(currentGroup.files.map(\.path)))
                : Set(DuplicateHandlingPlan.keepNewestDeleteTargets(for: currentGroup))
        } else {
            inlineSelectedPaths = []
        }
    }

    // MARK: - Scan driver

    private func startScan() {
        guard !isScanning,
              !roots.isEmpty,
              !isDeletionTransactionActive else { return }
        selectedGroupID = nil
        inlineSelectedPaths = []
        tccSkippedRoots = []
        scanIncompleteIssues = []
        scanIncompleteIssueIndex = []
        scanRevision &+= 1
        let revision = scanRevision
        let sessionID = UUID()
        scanSessionID = sessionID
        results.beginScan(sessionID: sessionID)
        bucketsDone = 0
        bucketsTotal = 0
        sizingFiles = 0
        scanPhase = .enumerate
        isScanning = true

        let rootsSnapshot = roots
        let minimumBytes = minStep.bytes
        let predecessor = Self.scanProducerSettlement.barrier()
        scanTask = Task { @MainActor in
            guard await ScanProducerSettlementChain.waitForSettlement(predecessor) else {
                if scanSessionID == sessionID, scanRevision == revision {
                    isScanning = false
                    scanPhase = nil
                    scanTask = nil
                }
                return
            }

            let scanner = DuplicateScanner(roots: rootsSnapshot, minBytes: minimumBytes)
            let session = scanner.scanSession()
            await withTaskCancellationHandler {
                for await event in session.events {
                    if Task.isCancelled { break }
                    guard scanSessionID == sessionID, scanRevision == revision else { break }
                    switch event {
                    case .sizingProgress(let n):
                        scanPhase = .enumerate
                        sizingFiles = n
                    case .hashingProgress(let done, let total):
                        scanPhase = .prefixHash
                        bucketsDone = done
                        bucketsTotal = total
                    case .fullHashingProgress(let done, let total):
                        scanPhase = .fullHash
                        bucketsDone = done
                        bucketsTotal = total
                    case .finished(let g):
                        results.replaceGroups(g, sessionID: sessionID)
                        if selectedGroupID == nil, let first = g.first {
                            selectedGroupID = first.id
                            inlineSelectedPaths = Set(DuplicateHandlingPlan.keepNewestDeleteTargets(for: first))
                        }
                    case .cancelled:
                        // 用户/上游 cancel：保留 groups 不动，仅退出 isScanning 状态。
                        // 与「停止仅终止扫描、保留已有结果」UX 一致。
                        break
                    case .tccProtectedSkipped(let path):
                        if !tccSkippedRoots.contains(path) {
                            tccSkippedRoots.append(path)
                        }
                        recordIncompleteIssue(ScanIncompleteIssue(
                            path: path,
                            reason: .tccProtectedSkipped
                        ))
                    case .incomplete(let issue):
                        recordIncompleteIssue(issue)
                    }
                }
                if Task.isCancelled { session.cancel() }
                await session.waitForTermination()
            } onCancel: {
                session.cancel()
            }
            // 无论正常 finished 还是 cancel，退出循环时一并复位进度计数与标签，
            // 避免下次启动前 footer 闪显旧进度数字。
            if scanSessionID == sessionID, scanRevision == revision {
                isScanning = false
                scanPhase = nil
                bucketsDone = 0
                bucketsTotal = 0
                sizingFiles = 0
                scanTask = nil
            }
        }
    }

    /// Cancellation is not settlement. The shared chain retains and joins this UI-owned task;
    /// that task in turn joins `DuplicateScanner.ScanSession` and its nested BulkScanner session.
    private func cancelActiveScan() {
        guard let scanTask, !scanTask.isCancelled else { return }
        Self.scanProducerSettlement.retire([scanTask])
    }
}

private struct DuplicateHandleSheet: View {
    @Environment(\.locale) private var locale

    let group: DuplicateGroup
    let isDeleting: Bool
    let onCancel: () -> Void
    let onDefault: () -> Void
    let onManual: ([String]) -> Void

    @State private var manualTargets: Set<String>
    @State private var manualSelectedBytes: Int64
    private let allocatedBytesByPath: [String: Int64]

    init(group: DuplicateGroup,
         isDeleting: Bool,
         onCancel: @escaping () -> Void,
         onDefault: @escaping () -> Void,
         onManual: @escaping ([String]) -> Void) {
        self.group = group
        self.isDeleting = isDeleting
        self.onCancel = onCancel
        self.onDefault = onDefault
        self.onManual = onManual
        let defaultTargets = DuplicateHandlingPlan.defaultDeleteTargets(for: group)
        _manualTargets = State(initialValue: Set(defaultTargets))
        _manualSelectedBytes = State(initialValue: group.allocatedBytes(for: defaultTargets))
        var bytesByPath: [String: Int64] = [:]
        bytesByPath.reserveCapacity(group.files.count)
        for file in group.files {
            bytesByPath[file.path] = file.allocatedBytes
        }
        allocatedBytesByPath = bytesByPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                defaultSection
                Divider()
                manualSection
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: group.reliability == .full ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(group.reliability == .full ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("duplicate.handle.title", bundle: .module)
                    .font(.title2.bold())
                Text(AppLocalization.format(
                    "duplicate.handle.subtitle %lld %@",
                    locale: locale,
                    arguments: [
                        Int64(group.files.count),
                        AppLocalization.byteCount(group.reclaimableBytes, locale: locale)
                    ]
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var defaultSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "1.circle")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("duplicate.handle.default.title", bundle: .module)
                    .font(.headline)
                Text(AppLocalization.format(
                    "duplicate.handle.default.detail %@",
                    locale: locale,
                    arguments: [URL(fileURLWithPath: group.files.first?.path ?? "").lastPathComponent]
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if group.reliability != .full {
                    Text("duplicate.handle.prefix.warning", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                onDefault()
            } label: {
                if isDeleting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("duplicate.handle.default.button", bundle: .module)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDeleting || !DuplicateHandlingPlan.isExecutableGroup(group))
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("duplicate.handle.manual.title", bundle: .module)
                .font(.headline)
            Text("duplicate.handle.manual.detail", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(group.files, id: \.path) { file in
                    HStack(spacing: 8) {
                        Toggle(isOn: binding(for: file.path)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(isDeleting || !DuplicateHandlingPlan.isExecutableGroup(group))
                        Spacer()
                        if let mtime = DuplicateHandlingPlan.modificationDate(for: file) {
                            Text(mtime.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            QuickLookController.shared.preview(urls: [URL(fileURLWithPath: file.path)])
                        } label: {
                            Image(systemName: "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(AppLocalization.string("tree.menu.quick_look", locale: locale))
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 210)
        }
    }

    private var footer: some View {
        HStack {
            Text(AppLocalization.format(
                "duplicate.handle.selected %lld %@",
                locale: locale,
                arguments: [
                    Int64(manualTargets.count),
                    AppLocalization.byteCount(manualSelectedBytes, locale: locale)
                ]
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("delete.action.cancel", locale: locale), role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button(AppLocalization.string("duplicate.handle.manual.button", locale: locale), role: .destructive) {
                onManual(Array(manualTargets))
            }
            .disabled(
                isDeleting
                    || !DuplicateHandlingPlan.isExecutableGroup(group)
                    || manualTargets.isEmpty
                    || manualTargets.count >= group.files.count
            )
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { manualTargets.contains(path) },
            set: { newValue in
                if newValue {
                    if manualTargets.insert(path).inserted {
                        let bytes = allocatedBytesByPath[path] ?? 0
                        let sum = manualSelectedBytes.addingReportingOverflow(bytes)
                        manualSelectedBytes = sum.overflow ? .max : sum.partialValue
                    }
                } else if manualTargets.remove(path) != nil {
                    manualSelectedBytes = max(0, manualSelectedBytes - (allocatedBytesByPath[path] ?? 0))
                }
            }
        )
    }
}

enum DuplicateHandlingPlan {
    static func modificationDate(for file: DuplicateFile) -> Date? {
        guard let identity = file.snapshotIdentity else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(identity.modificationSeconds)
                + TimeInterval(identity.modificationNanoseconds) / 1_000_000_000
        )
    }

    static func defaultDeleteTargets(for group: DuplicateGroup) -> [String] {
        // v2026.07.17 重复文件安全回归：prefixOnly 只证明 size + 前 64KB
        // 一致，绝不是可删除证明。警告文案不能代替执行闸门；在可取消的
        // full-hash + 最终身份重验链路完成前，计划层直接不铸造任何删除目标。
        guard isExecutableGroup(group) else { return [] }
        return group.files.dropFirst().map(\.path)
    }

    static func keepNewestDeleteTargets(for group: DuplicateGroup) -> [String] {
        guard isExecutableGroup(group),
              let newest = group.files.max(by: { lhs, rhs in
                  let lSec = lhs.snapshotIdentity?.modificationSeconds ?? .min
                  let rSec = rhs.snapshotIdentity?.modificationSeconds ?? .min
                  if lSec != rSec { return lSec < rSec }
                  let lNano = lhs.snapshotIdentity?.modificationNanoseconds ?? .min
                  let rNano = rhs.snapshotIdentity?.modificationNanoseconds ?? .min
                  if lNano != rNano { return lNano < rNano }
                  return lhs.path > rhs.path
              }) else {
            return defaultDeleteTargets(for: group)
        }
        return group.files.filter { $0.path != newest.path }.map(\.path)
    }

    static func isValidDeleteTargets(_ paths: [String], for group: DuplicateGroup) -> Bool {
        guard isExecutableGroup(group) else { return false }
        let uniqueTargets = Set(paths)
        guard !uniqueTargets.isEmpty,
              uniqueTargets.count == paths.count,
              uniqueTargets.count < group.files.count else {
            return false
        }
        let allPaths = Set(group.files.map(\.path))
        return uniqueTargets.isSubset(of: allPaths)
    }

    static func isExecutableGroup(_ group: DuplicateGroup) -> Bool {
        guard group.reliability == .full,
              let fingerprint = group.contentFingerprint,
              fingerprint.logicalBytes == group.logicalBytes else { return false }
        return group.files.count >= 2 && group.files.allSatisfy {
            guard let identity = $0.snapshotIdentity else { return false }
            return identity.isRegularFile
                && identity.logicalBytes == fingerprint.logicalBytes
        }
    }

    /// 纯数据投影，调用方可安全放到 detached utility task，避免大重复集在主线程重聚合。
    static func pruning(_ groups: [DuplicateGroup], movedPaths: Set<String>) -> [DuplicateGroup] {
        guard !movedPaths.isEmpty else { return groups }
        let matcher = DeletionPresentationPathMatcher(paths: Array(movedPaths))
        var pruned: [DuplicateGroup] = []
        pruned.reserveCapacity(groups.count)
        for group in groups {
            // A retired projection has no publishable output; stop traversing wide groups.
            guard !Task.isCancelled else { return [] }
            var matchedPaths: Set<String> = []
            for file in group.files {
                guard !Task.isCancelled else { return [] }
                if matcher.contains(file.path) { matchedPaths.insert(file.path) }
            }
            if let remaining = matchedPaths.isEmpty ? group : group.removing(paths: matchedPaths) {
                pruned.append(remaining)
            }
        }
        return pruned
    }
}
