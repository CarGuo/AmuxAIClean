import Foundation
import Observation
import AIKit
import SafetyKit

/// Normal Smart Care 的一次 AI 复核由此领域对象独立管理。
///
/// 这里刻意不复用 `StashAIQueue`：购物车队列只需要逐行徽标，而 Normal 模式还需要
/// 可持久展示的终态报告、失败项重试、取消语义和 summary revision 失效保护。
@MainActor
@Observable
public final class SmartCareAIReviewSession {
    public private(set) var phase: SmartCareAIReviewPhase = .idle
    public private(set) var latestReport: SmartCareAIReviewReport?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var activeRun: ActiveRun?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// 对当前 summary 的条目启动一次全新复核。运行中重入会被拒绝。
    ///
    /// `selectedItemIDs` 只作为报告快照保存；AI 永远不会直接改变选择状态。
    @discardableResult
    public func start(
        items: [SmartCareItem],
        selectedItemIDs: Set<SmartCareItem.ID> = [],
        summaryRevision: UInt64,
        using worker: SmartCareAIReviewWorker
    ) -> UUID? {
        guard !phase.isRunning else { return nil }

        let uniqueItems = Self.uniqued(items)
        guard !uniqueItems.isEmpty else {
            return finishEmpty(summaryRevision: summaryRevision)?.runID
        }

        let outcomes = uniqueItems.map { item in
            SmartCareAIReviewItemOutcome(
                item: item,
                selectedAtStart: selectedItemIDs.contains(item.id),
                result: .notReviewed
            )
        }
        latestReport = nil
        return begin(
            allOutcomes: outcomes,
            targets: uniqueItems,
            sourceSummaryRevision: summaryRevision,
            worker: worker
        )
    }

    /// 当前扫描没有进入 AI 优先复核范围的项目时，也要形成可呈现的明确终态。
    /// 该入口不需要构造客户端或读取 Keychain，因此不会把“没有项目”误报为配置失败。
    @discardableResult
    public func finishEmpty(summaryRevision: UInt64) -> SmartCareAIReviewReport? {
        guard !phase.isRunning else { return nil }
        let timestamp = now()
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: summaryRevision,
            observedSummaryRevision: summaryRevision,
            status: .empty,
            items: [],
            startedAt: timestamp,
            finishedAt: timestamp
        )
        latestReport = report
        phase = .result(report)
        return report
    }

    /// 仅重试上次终态报告中的失败项，并把新结果合并回原始条目顺序。
    /// 过期报告不能重试，必须基于当前扫描结果重新发起复核。
    @discardableResult
    public func retryFailed(using worker: SmartCareAIReviewWorker) -> UUID? {
        guard !phase.isRunning,
              let report = latestReport,
              report.isCurrent,
              report.status == .partial || report.status == .failed else {
            return nil
        }
        let targets = report.items.compactMap { outcome -> SmartCareItem? in
            if case .failure = outcome.result { return outcome.item }
            if report.globalFailure != nil, outcome.isNotReviewed { return outcome.item }
            return nil
        }
        guard !targets.isEmpty else { return nil }
        return begin(
            allOutcomes: report.items,
            targets: targets,
            sourceSummaryRevision: report.sourceSummaryRevision,
            worker: worker
        )
    }

    /// 继续处理用户取消后尚未开始的条目。已成功和已失败的结果都会保留。
    @discardableResult
    public func continueUnreviewed(using worker: SmartCareAIReviewWorker) -> UUID? {
        guard !phase.isRunning,
              let report = latestReport,
              report.isCurrent,
              report.status == .cancelled else {
            return nil
        }
        let targets = report.items.compactMap { outcome -> SmartCareItem? in
            guard case .notReviewed = outcome.result else { return nil }
            return outcome.item
        }
        guard !targets.isEmpty else { return nil }
        return begin(
            allOutcomes: report.items,
            targets: targets,
            sourceSummaryRevision: report.sourceSummaryRevision,
            worker: worker
        )
    }

    /// 用户取消只终止 AI 请求；已经得到的结果仍保留在 cancelled 报告里。
    public func cancel() {
        guard let runID = activeRun?.runID else { return }
        activeRun?.termination = .cancelled
        runTask?.cancel()
        // 终态不能依赖 provider 是否及时响应 cancellation。先立即发布取消报告；
        // 即使底层请求迟到返回，也会因 active run 已清空 / runID 不匹配而被丢弃。
        finish(runID: runID)
    }

    /// 把客户端构造 / 凭证预检失败提升为可展示的正式终态，而不是留在旧式 Alert。
    /// 全局失败只保存一次，不复制到每个条目造成重复错误内容。
    @discardableResult
    public func failPreflight(
        items: [SmartCareItem],
        selectedItemIDs: Set<SmartCareItem.ID> = [],
        summaryRevision: UInt64,
        failure: SmartCareAIReviewFailure
    ) -> SmartCareAIReviewReport? {
        guard !phase.isRunning else { return nil }
        let uniqueItems = Self.uniqued(items)
        let timestamp = now()
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: summaryRevision,
            observedSummaryRevision: summaryRevision,
            status: .failed,
            items: uniqueItems.map { item in
                SmartCareAIReviewItemOutcome(
                    item: item,
                    selectedAtStart: selectedItemIDs.contains(item.id),
                    result: .notReviewed
                )
            },
            globalFailure: failure,
            startedAt: timestamp,
            finishedAt: timestamp
        )
        latestReport = report
        phase = .result(report)
        return report
    }

    /// “重试失败项 / 继续剩余项”在客户端预检阶段失败时，保留上一份报告的成功内容。
    /// 不能退化成只含失败目标的新报告，否则用户会误以为已经完成的建议丢失。
    @discardableResult
    public func failContinuationPreflight(
        failure: SmartCareAIReviewFailure
    ) -> SmartCareAIReviewReport? {
        guard !phase.isRunning,
              let previous = latestReport,
              previous.isCurrent,
              [.partial, .failed, .cancelled].contains(previous.status) else {
            return nil
        }
        let timestamp = now()
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: previous.sourceSummaryRevision,
            observedSummaryRevision: previous.observedSummaryRevision,
            status: previous.succeededCount > 0 ? .partial : .failed,
            items: previous.items,
            globalFailure: failure,
            startedAt: timestamp,
            finishedAt: timestamp
        )
        latestReport = report
        phase = .result(report)
        return report
    }

    /// 告知 session 当前 Smart Care summary revision。
    ///
    /// revision 一旦变化，旧报告不能再关联选择或清理操作：运行中的请求会取消并产出
    /// `.stale` 报告，已经完成的报告会原地转为 `.stale`。
    public func synchronizeSummaryRevision(_ revision: UInt64) {
        if var activeRun, activeRun.sourceSummaryRevision != revision {
            activeRun.termination = .stale(observedSummaryRevision: revision)
            self.activeRun = activeRun
            runTask?.cancel()
            // 与用户取消一致，revision 失效必须立刻成为 UI 可观察终态，不能等待
            // 第三方 provider 配合取消后才锁住选择和清理操作。
            finish(runID: activeRun.runID)
            return
        }

        guard var report = latestReport,
              report.sourceSummaryRevision != revision,
              report.status != .stale else {
            return
        }
        report = report.markedStale(observedSummaryRevision: revision)
        latestReport = report
        phase = .result(report)
    }

    /// 显式丢弃当前结果。关闭结果 Sheet 不应调用它，报告需支持再次查看。
    public func reset() {
        runTask?.cancel()
        runTask = nil
        activeRun = nil
        latestReport = nil
        phase = .idle
    }

    @discardableResult
    private func begin(
        allOutcomes: [SmartCareAIReviewItemOutcome],
        targets: [SmartCareItem],
        sourceSummaryRevision: UInt64,
        worker: SmartCareAIReviewWorker
    ) -> UUID {
        let runID = UUID()
        let startedAt = now()
        let run = ActiveRun(
            runID: runID,
            sourceSummaryRevision: sourceSummaryRevision,
            outcomes: allOutcomes,
            targets: targets,
            startedAt: startedAt,
            processed: 0,
            currentItemID: nil,
            globalFailure: nil,
            termination: nil
        )
        // 新 run 的进行态只以 progress 为真相源；旧终态不能在重试/继续期间再次被打开。
        latestReport = nil
        activeRun = run
        publishProgress(run)

        runTask = Task { [weak self] in
            await self?.execute(runID: runID, worker: worker)
        }
        return runID
    }

    private func execute(runID: UUID, worker: SmartCareAIReviewWorker) async {
        guard let initialRun = activeRun, initialRun.runID == runID else { return }

        for item in initialRun.targets {
            guard var run = activeRun, run.runID == runID else { return }
            if Task.isCancelled || run.termination != nil { break }
            var shouldStopBatchAfterCurrentItem = false

            run.currentItemID = item.id
            activeRun = run
            publishProgress(run)

            do {
                let rawAdvice = try await worker.review(item)
                try Task.checkCancellation()
                if rawAdvice.summary == AIAdvice.unparsableSummaryKey {
                    replaceOutcome(
                        itemID: item.id,
                        with: .failure(SmartCareAIReviewFailure(
                            kind: .decoding,
                            canRetry: true
                        )),
                        runID: runID
                    )
                } else {
                    let advice = Self.enforceSafetyBoundary(rawAdvice, for: item)
                    replaceOutcome(itemID: item.id, with: .advice(advice), runID: runID)
                }
            } catch is CancellationError {
                // reset 后可以立刻开始新 run；旧 worker 的迟到 cancellation 绝不能
                // 把新 activeRun 污染为 cancelled。
                guard var currentRun = activeRun, currentRun.runID == runID else { return }
                if currentRun.termination == nil {
                    currentRun.termination = .cancelled
                    activeRun = currentRun
                }
                break
            } catch {
                // 某些自定义 worker 可能把底层 cancellation 包装成 transport error。
                // 一旦领域层已经收到 cancel / stale，不得把迟到错误污染成单项失败。
                if Task.isCancelled || activeRun?.termination != nil { break }
                let failure = SmartCareAIReviewFailure(error: error)
                replaceOutcome(itemID: item.id, with: .failure(failure), runID: runID)
                if failure.stopsBatch {
                    guard var currentRun = activeRun, currentRun.runID == runID else { return }
                    currentRun.globalFailure = failure
                    activeRun = currentRun
                    shouldStopBatchAfterCurrentItem = true
                }
            }

            guard var updated = activeRun, updated.runID == runID else { return }
            updated.processed += 1
            updated.currentItemID = nil
            activeRun = updated
            publishProgress(updated)
            if shouldStopBatchAfterCurrentItem { break }
        }

        finish(runID: runID)
    }

    private func replaceOutcome(
        itemID: SmartCareItem.ID,
        with result: SmartCareAIReviewItemResult,
        runID: UUID
    ) {
        guard var run = activeRun, run.runID == runID,
              let index = run.outcomes.firstIndex(where: { $0.item.id == itemID }) else {
            return
        }
        let previous = run.outcomes[index]
        run.outcomes[index] = SmartCareAIReviewItemOutcome(
            item: previous.item,
            selectedAtStart: previous.selectedAtStart,
            result: result
        )
        activeRun = run
    }

    private func finish(runID: UUID) {
        guard let run = activeRun, run.runID == runID else { return }

        let observedRevision: UInt64
        let forcedStatus: SmartCareAIReviewReportStatus?
        switch run.termination {
        case .cancelled:
            observedRevision = run.sourceSummaryRevision
            forcedStatus = .cancelled
        case .stale(let revision):
            observedRevision = revision
            forcedStatus = .stale
        case nil:
            observedRevision = run.sourceSummaryRevision
            forcedStatus = nil
        }

        let status: SmartCareAIReviewReportStatus
        if let forcedStatus {
            status = forcedStatus
        } else if run.globalFailure != nil {
            status = run.outcomes.contains(where: { $0.advice != nil }) ? .partial : .failed
        } else {
            status = SmartCareAIReviewReport.terminalStatus(for: run.outcomes)
        }
        let report = SmartCareAIReviewReport(
            runID: run.runID,
            sourceSummaryRevision: run.sourceSummaryRevision,
            observedSummaryRevision: observedRevision,
            status: status,
            items: run.outcomes,
            globalFailure: run.globalFailure,
            startedAt: run.startedAt,
            finishedAt: now()
        )
        runTask = nil
        activeRun = nil
        latestReport = report
        phase = .result(report)
    }

    private func publishProgress(_ run: ActiveRun) {
        phase = .running(SmartCareAIReviewProgress(
            runID: run.runID,
            sourceSummaryRevision: run.sourceSummaryRevision,
            processedCount: run.processed,
            totalCount: run.targets.count,
            currentItemID: run.currentItemID,
            items: run.outcomes
        ))
    }

    private static func uniqued(_ items: [SmartCareItem]) -> [SmartCareItem] {
        var seen: Set<SmartCareItem.ID> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    /// 即使测试或未来其它 provider 注入了未 clamp 的 worker，领域边界仍会复用
    /// AIKit 的统一安全钳制，保证本地 `.forbid` / hard-forbid 路径永远不会被 AI 放行。
    private static func enforceSafetyBoundary(
        _ advice: AIAdvice,
        for item: SmartCareItem
    ) -> AIAdvice {
        let inquiry = PathInquiry(
            path: item.path,
            isDirectory: item.isDirectory,
            bytes: item.bytes,
            fileCount: item.fileCount,
            modificationDate: nil,
            verdict: item.verdict,
            vendorName: nil,
            vendorNote: item.riskNote,
            childPreview: []
        )
        return AIAdviceClamp.clamp(advice, against: inquiry)
    }

    private struct ActiveRun {
        let runID: UUID
        let sourceSummaryRevision: UInt64
        var outcomes: [SmartCareAIReviewItemOutcome]
        let targets: [SmartCareItem]
        let startedAt: Date
        var processed: Int
        var currentItemID: SmartCareItem.ID?
        var globalFailure: SmartCareAIReviewFailure?
        var termination: Termination?
    }

    private enum Termination: Equatable {
        case cancelled
        case stale(observedSummaryRevision: UInt64)
    }
}

public enum SmartCareAIReviewPhase: Sendable, Equatable {
    case idle
    case running(SmartCareAIReviewProgress)
    case result(SmartCareAIReviewReport)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Smart Care 在真正进入逐项 AI 复核前，需要异步读取一次 Keychain。
///
/// 这个 gate 把“准备凭证”也纳入单次运行互斥和取消语义，避免用户快速连点时并发
/// 读取 Keychain / 启动两批复核。token 防止旧任务在取消后迟到完成，误清掉新任务状态。
@MainActor
@Observable
final class SmartCareAIReviewPreparationGate {
    private(set) var isPreparing = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeToken: UUID?

    @discardableResult
    func start(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard activeToken == nil else { return false }

        let token = UUID()
        activeToken = token
        isPreparing = true
        task = Task { @MainActor [weak self] in
            await operation()
            self?.finish(token: token)
        }
        return true
    }

    func cancel() {
        activeToken = nil
        isPreparing = false
        task?.cancel()
        task = nil
    }

    private func finish(token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        isPreparing = false
        task = nil
    }
}

public struct SmartCareAIReviewProgress: Sendable, Equatable {
    public let runID: UUID
    public let sourceSummaryRevision: UInt64
    public let processedCount: Int
    public let totalCount: Int
    public let currentItemID: SmartCareItem.ID?
    public let items: [SmartCareAIReviewItemOutcome]

    public var remainingCount: Int { max(0, totalCount - processedCount) }
}

public enum SmartCareAIReviewReportStatus: String, Sendable, Equatable, Codable {
    case empty
    case success
    case partial
    case failed
    case cancelled
    case stale
}

public struct SmartCareAIReviewReport: Identifiable, Sendable, Equatable {
    public var id: UUID { runID }
    public let runID: UUID
    public let sourceSummaryRevision: UInt64
    public let observedSummaryRevision: UInt64
    public let status: SmartCareAIReviewReportStatus
    public let items: [SmartCareAIReviewItemOutcome]
    public let globalFailure: SmartCareAIReviewFailure?
    public let startedAt: Date
    public let finishedAt: Date

    public var outcomes: [SmartCareAIReviewItemOutcome] { items }
    public var requestedCount: Int { items.count }
    public var succeededCount: Int { items.count(where: { $0.advice != nil }) }
    public var failedCount: Int { items.count(where: { $0.failure != nil }) }
    public var remainingCount: Int { items.count(where: { $0.isNotReviewed }) }
    public var isCurrent: Bool {
        status != .stale && sourceSummaryRevision == observedSummaryRevision
    }

    public var safeAdviceCount: Int {
        items.count(where: { $0.advice?.canDelete == .safe })
    }

    public var confirmAdviceCount: Int {
        items.count(where: { $0.advice?.canDelete == .confirm })
    }

    public var forbidAdviceCount: Int {
        items.count(where: { $0.advice?.canDelete == .forbid })
    }

    public init(
        runID: UUID,
        sourceSummaryRevision: UInt64,
        observedSummaryRevision: UInt64,
        status: SmartCareAIReviewReportStatus,
        items: [SmartCareAIReviewItemOutcome],
        globalFailure: SmartCareAIReviewFailure? = nil,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.runID = runID
        self.sourceSummaryRevision = sourceSummaryRevision
        self.observedSummaryRevision = observedSummaryRevision
        self.status = status
        self.items = items
        self.globalFailure = globalFailure
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    fileprivate static func terminalStatus(
        for outcomes: [SmartCareAIReviewItemOutcome]
    ) -> SmartCareAIReviewReportStatus {
        let succeeded = outcomes.count(where: { $0.advice != nil })
        let failed = outcomes.count(where: { $0.failure != nil })
        let remaining = outcomes.count(where: { $0.isNotReviewed })
        if outcomes.isEmpty { return .empty }
        if remaining > 0 { return .cancelled }
        if failed == 0 { return .success }
        if succeeded == 0 { return .failed }
        return .partial
    }

    fileprivate func markedStale(observedSummaryRevision: UInt64) -> Self {
        Self(
            runID: runID,
            sourceSummaryRevision: sourceSummaryRevision,
            observedSummaryRevision: observedSummaryRevision,
            status: .stale,
            items: items,
            globalFailure: globalFailure,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

public struct SmartCareAIReviewItemOutcome: Identifiable, Sendable, Equatable {
    public var id: SmartCareItem.ID { item.id }
    public let item: SmartCareItem
    public let selectedAtStart: Bool
    public let result: SmartCareAIReviewItemResult

    public var path: String { item.path }
    public var localVerdict: SafetyVerdict { item.verdict }
    public var advice: AIAdvice? {
        guard case .advice(let advice) = result else { return nil }
        return advice
    }
    public var failure: SmartCareAIReviewFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }
    public var isNotReviewed: Bool {
        if case .notReviewed = result { return true }
        return false
    }

    public init(
        item: SmartCareItem,
        selectedAtStart: Bool,
        result: SmartCareAIReviewItemResult
    ) {
        self.item = item
        self.selectedAtStart = selectedAtStart
        self.result = result
    }
}

public enum SmartCareAIReviewItemResult: Sendable, Equatable {
    case advice(AIAdvice)
    case failure(SmartCareAIReviewFailure)
    case notReviewed
}

public struct SmartCareAIReviewFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case configuration
        case authentication
        case credentialStorage
        case rateLimit
        case network
        case server
        case decoding
        case unknown
    }

    public let kind: Kind
    /// HTTP status 是唯一允许进入 UI 报告的 provider 原始诊断字段。
    /// 响应 body、transport 文本和 unknown Error 描述一律不存储，避免依赖脆弱的
    /// secret 黑名单正则，也避免在 MainActor 上处理任意长度错误文本。
    public let httpStatus: Int?
    public let canRetry: Bool
    public let shouldOpenSettings: Bool

    public var isRetryable: Bool { canRetry }

    /// 这三类错误对同一 provider / 凭证下的整批请求具有一致性；继续逐项请求只会
    /// 重复失败或加重限流。单项解析、未知和普通 transport 错误仍继续收集部分结果。
    var stopsBatch: Bool {
        switch kind {
        case .configuration, .authentication, .credentialStorage, .rateLimit: true
        case .network, .server, .decoding, .unknown: false
        }
    }

    public init(
        kind: Kind,
        httpStatus: Int? = nil,
        canRetry: Bool,
        shouldOpenSettings: Bool = false
    ) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.canRetry = canRetry
        self.shouldOpenSettings = shouldOpenSettings
    }

    public init(error: any Error) {
        switch error {
        case SmartCareAIReviewPreflightError.notConfigured:
            self.init(
                kind: .configuration,
                canRetry: false,
                shouldOpenSettings: true
            )
        case OpenAIChatClient.Error.missingAPIKey:
            self.init(
                kind: .authentication,
                canRetry: false,
                shouldOpenSettings: true
            )
        case is KeychainAPIKeyStoreError:
            self.init(
                kind: .credentialStorage,
                canRetry: false,
                shouldOpenSettings: true
            )
        case OpenAIChatClient.Error.invalidBaseURL:
            self.init(
                kind: .configuration,
                canRetry: false,
                shouldOpenSettings: true
            )
        case OpenAIChatClient.Error.insecureBaseURL:
            self.init(
                kind: .configuration,
                canRetry: false,
                shouldOpenSettings: true
            )
        case let OpenAIChatClient.Error.http(status, _):
            let kind: Kind
            let retryable: Bool
            let shouldOpenSettings: Bool
            switch status {
            case 400, 404, 422:
                kind = .configuration
                retryable = false
                shouldOpenSettings = true
            case 401, 403:
                kind = .authentication
                retryable = false
                shouldOpenSettings = true
            case 429:
                kind = .rateLimit
                retryable = true
                shouldOpenSettings = false
            case 500...599:
                kind = .server
                retryable = true
                shouldOpenSettings = false
            default:
                kind = .server
                retryable = false
                shouldOpenSettings = false
            }
            self.init(
                kind: kind,
                httpStatus: status,
                canRetry: retryable,
                shouldOpenSettings: shouldOpenSettings
            )
        case OpenAIChatClient.Error.transport:
            self.init(kind: .network, canRetry: true)
        case OpenAIChatClient.Error.decoding:
            self.init(kind: .decoding, canRetry: true)
        default:
            self.init(
                kind: .unknown,
                canRetry: true
            )
        }
    }
}

public enum SmartCareAIReviewPreflightError: Error, Sendable, Equatable {
    case notConfigured
}

/// 结果 Sheet 提交的选择变更在进入 coordinator 前，先经过这个纯策略边界。
/// 只接受当前 report 实际展示、仍存在且本地可选择的项目；过期报告和 `.forbid` 一律拒绝。
struct SmartCareAIReviewSelectionChange: Sendable, Equatable {
    let item: SmartCareItem
    let selected: Bool
}

enum SmartCareAIReviewSelectionPolicy {
    static func validatedChanges(
        report: SmartCareAIReviewReport,
        currentSummaryRevision: UInt64,
        currentItemIDs: Set<SmartCareItem.ID>,
        proposedByPath: [String: Bool]
    ) -> [SmartCareAIReviewSelectionChange] {
        guard report.isCurrent,
              report.sourceSummaryRevision == currentSummaryRevision,
              !proposedByPath.isEmpty else {
            return []
        }

        var reportOutcomesByPath: [String: SmartCareAIReviewItemOutcome] = [:]
        reportOutcomesByPath.reserveCapacity(report.items.count)
        for outcome in report.items {
            reportOutcomesByPath[outcome.path] = outcome
        }

        return proposedByPath.compactMap { path, selected in
            guard let outcome = reportOutcomesByPath[path],
                  let advice = outcome.advice,
                  currentItemIDs.contains(outcome.item.id),
                  outcome.item.path == path,
                  outcome.item.isSelectable else {
                return nil
            }
            let item = outcome.item
            // 取消选择永远允许；把本地 confirm 从未选改为选中，只接受 AI safe 建议。
            // AI confirm / forbid 或请求失败时，用户仍可回主列表审阅，但报告不能放大清理集合。
            if selected, item.verdict == .confirm, advice.canDelete != .safe {
                return nil
            }
            return SmartCareAIReviewSelectionChange(item: item, selected: selected)
        }
        .sorted { $0.item.path < $1.item.path }
    }
}

/// 可注入的单条 AI worker。生产环境使用 `openAI(client:)`，测试可直接注入闭包。
public struct SmartCareAIReviewWorker: Sendable {
    private let operation: @Sendable (SmartCareItem) async throws -> AIAdvice

    public init(operation: @escaping @Sendable (SmartCareItem) async throws -> AIAdvice) {
        self.operation = operation
    }

    public func review(_ item: SmartCareItem) async throws -> AIAdvice {
        try await operation(item)
    }

    public static func openAI(client: OpenAIChatClient) -> Self {
        Self { item in
            let path = item.path
            let isDirectory = item.isDirectory
            let preview: [String] = await Task.detached(priority: .userInitiated) {
                guard isDirectory else { return [String]() }
                return PathInquiry.sampleChildren(at: path, limit: 5)
            }.value
            try Task.checkCancellation()
            return try await client.ask(PathInquiry(
                path: item.path,
                isDirectory: item.isDirectory,
                bytes: item.bytes,
                fileCount: item.fileCount,
                modificationDate: nil,
                verdict: item.verdict,
                vendorName: nil,
                vendorNote: item.riskNote,
                childPreview: preview
            ))
        }
    }

    /// 在主 actor 冻结用户配置，再通过 Keychain actor 为本次批处理只读取一次凭证。
    ///
    /// 远程端点在这里完成“凭证存储可访问 + 非空”预检，失败必须由
    /// `SmartCareAIReviewSession.failPreflight` 记录为 0 项已处理；不能等到第一条
    /// `ask` 才失败。loopback 端点允许没有凭证，仍保持 Ollama / vLLM 免鉴权兼容。
    @MainActor
    public static func makeOpenAI(settings: AISettings) async throws -> Self {
        try await makeOpenAI(
            settings: settings,
            credentialLoader: { try await KeychainAPIKeyStore.shared.load() }
        )
    }

    /// 测试注入点：验证凭证只在批处理预检阶段读取一次，不触发真实 Keychain。
    @MainActor
    static func makeOpenAI(
        settings: AISettings,
        credentialLoader: @escaping @Sendable () async throws -> String?
    ) async throws -> Self {
        guard settings.isReadyForUI else {
            throw SmartCareAIReviewPreflightError.notConfigured
        }
        let snapshot = OpenAIChatClient.SettingsSnapshot(
            baseURL: settings.baseURL,
            model: settings.model,
            temperature: settings.temperature,
            redactPaths: settings.redactPaths
        )
        let allowsMissingCredential = try OpenAIChatClient.allowsMissingAPIKey(
            baseURL: snapshot.baseURL
        )
        let apiKey: String
        do {
            apiKey = try await credentialLoader() ?? ""
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard allowsMissingCredential else { throw error }
            apiKey = ""
        }
        try Task.checkCancellation()
        guard !apiKey.isEmpty || allowsMissingCredential else {
            throw OpenAIChatClient.Error.missingAPIKey
        }
        return .openAI(client: OpenAIChatClient(
            settings: snapshot,
            apiKey: apiKey
        ))
    }
}
