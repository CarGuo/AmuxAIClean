import Foundation
import ScanKit
import SafetyKit

/// 删除链路抽象 —— v1.3.zzzz 之后只保留主 App 内 [TrashPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TrashPipeline.swift) 一份实现。
///
/// 历史背景（已下线）：早期版本曾设计过 HelperClient（XPC + LaunchDaemon + HMAC 三道闸门）作为另一份实现，
/// 思路是"App 端只发请求，Helper 端做最后一道安全校验"。在产品仅删 `$HOME` 下用户态文件、
/// 完全不需要 root 权限的现实场景里，Helper 链路属于纯负担——增加进程数、增加 SMAppService 注册流程、
/// 增加用户首跑授权对话框、增加 Free Apple ID 自签下根本跑不通的 Team ID 校验旁路——
/// 所以 v1.3.zzzz 直接把 Helper / HelperClient / XPCBridge 整套删除，只留 TrashPipeline。
///
/// **设计原则**：
/// - 默认 dryRun=true（PITFALLS §5.7：trash preview 模式）
/// - 5s 超时（PITFALLS §1.7：禁止同步阻塞）
public protocol DeletionPipeline: Sendable {
    /// v2026.09.06: read-only object evidence frozen before user confirmation. The default
    /// probes real filesystem objects off the UI executor; scripted pipelines must explicitly
    /// supply their own object domain and cannot silently drop this proof during submission.
    func prepareReviewedObjects(
        paths: [String], expectedIdentities: [String: TrashObjectIdentity]
    ) async -> ReviewedDeletionObjectPreparation

    /// 删除确认前的完整只读预检。生产实现必须与最终执行使用同一套
    /// SafetyEngine / vendor trie / whitelist / access-denied 合同；UI 不得再用
    /// 自己拼出的部分判定决定是否展示确认框。
    func preflight(
        paths: [String],
        accessDeniedPaths: Set<String>
    ) async -> DeletionPreflight

    /// Professional 扫描缺口入口。实现必须在后台完成逐目标身份、Safety/scope/whitelist
    /// 与父目录移动能力检查；无法取得 typed issue 时保持 fail-closed。
    func prepareScanIncompleteOverride(
        rows: [RowItem],
        scanIssues: [ScanIncompleteIssue],
        scanSessionID: UUID
    ) async -> ScanIncompleteOverridePreparation

    /// - Returns: (movedCount, skippedCount, error?, trashedPairs)
    ///
    /// `trashedPairs` 是 `[(originalPath, trashedPath)]`，仅在 `dryRun=false` 且
    /// NSWorkspace.recycle 真正把文件移入用户废纸篓后才有非空内容；其余路径
    /// （dryRun / 全 forbid 拦截 / recycle 失败）一律返回空数组。Step 7
    /// UndoHistory 用这份 pair 写入 `~/Library/Application Support/AmuxAIClean/UndoHistory.json`
    /// 以支持"最近清理 → 恢复"。
    func moveToTrash(paths: [String], dryRun: Bool) async -> (Int, Int, String?, [(String, String)])

    /// 注入"上层一票否决路径集合"（v1.3.zzzz Phase 3-A 协议化 → Phase 3-E 全链路接通）。
    ///
    /// 协议层接受这个钩子是为了**让"漏调=误拒"风险被强类型保护**：
    /// 历史上 [MainView.performDelete](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift)
    /// 只对 [TrashPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)
    /// 走 `if let trash = pipeline as? TrashPipeline` cast 注入；现在 Helper 路线已下线，
    /// 实际只剩 TrashPipeline 一份实现。
    ///
    /// **v2026.06.17 (AUDIT A2)**：取消 protocol 默认 no-op 实现 ——
    /// 默认 no-op 让"上层忘了调"变成静默放行而非 compile-error，是契约靠手记维系的脆弱点。
    /// 现在所有 `DeletionPipeline` 实现都必须显式提供该方法：
    /// - 真删除链路（[TrashPipeline](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TrashPipeline.swift)）：真存进 `accessDeniedPaths` Set 并 normalize；
    /// - 测试 stub / dry-run 调试管道：可显式 no-op，但**必须自己写出来**，签字画押。
    func setAccessDeniedPaths(_ paths: Set<String>)

    /// v2026.06.16：上一轮 `moveToTrash` 的兼容结构化快照。
    ///
    /// 旧协议返回的 4 元组 `(moved, skipped, err?, pairs)` 只能用一行文案拼接
    /// "Trash: X succeeded / Y skipped\nError: ..."，UI 没法做"展开失败列表 / 重试失败项"。
    /// 改协议返回值的代价过大（≥10 处生产 + ≥10 处测试），故走"外挂结构体"模式：
    /// 历史实现会把 `moveToTrash` 结果记录到 lastOutcome；生产 UI 已禁止读取这个进程级槽位，
    /// 只能消费当前调用返回的 typed disposition/result。
    ///
    /// 协议给默认 nil 实现——历史 stub / dry-run pipeline 不强制提供。
    ///
    /// **v2026.06.22 (P0-3)**：side-channel 单槽位被识别为线程安全脆弱点
    /// （MainView/WorkflowDetailView 任何两次并发 `moveToTrash` 都会互相覆盖快照，
    /// 导致写错 UndoHistory + 展示错 OperationResultSheet）。生产路径应改用
    /// 新方法 [moveToTrashReturningOutcome](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/DeletionPipeline.swift)
    /// 直接拿返回值；本方法保留向后兼容但仅用作"老调用方临时回退"，不应被新代码引用。
    /// 注意：outcome 本身不证明调用跨过 recycle 边界；新 Professional 代码必须使用
    /// `submitToTrashReturningDisposition` 的 typed case。
    func snapshotLastOutcome() -> TrashOutcome?

    /// **v2026.06.22 (P0-3)**：替代 `moveToTrash + snapshotLastOutcome()` 的 side-channel 模式，
    /// 一次调用同时返回旧 4 元组（向后兼容）与结构化 `TrashOutcome`。
    ///
    /// 调用方应优先使用 `outcome` 字段；4 元组保留是为了让历史 call site 渐进迁移。
    ///
    /// 默认实现走旧 `moveToTrash` + `snapshotLastOutcome()`，保证已有 stub 不破。
    func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)

    /// request-scoped accessDenied 入口。生产实现必须让 denied 快照与 paths 同一次调用交接，
    /// 避免并发请求通过共享 setter 覆盖彼此的安全上下文。
    func moveToTrashReturningOutcome(
        paths: [String],
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)

    /// 仅允许覆盖 vendors.yaml 的 path-level forbid。请求只能由一次可信预检结果生成；
    /// 生产实现仍必须在最终执行前重新验证全部路径，不能把这个值当作“已授权即可直通”。
    func moveToTrashVendorPathOverride(
        request: VendorPathOverrideRequest,
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)

    /// Professional 确认后的真实提交入口。该 API 没有 dry-run 参数，并把“最终重验在
    /// `NSWorkspace.recycle` 之前拒绝”和“至少一次 recycle 调用已经完成”建模为互斥
    /// case。结果页只能消费 `.recycleCompleted`，不得再从空 pairs / outcome 内容猜测
    /// 是否跨过系统提交边界。
    func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?
    ) async -> TrashSubmissionDisposition

    /// 带扫描缺口严格请求的 Professional 提交。旧实现默认只在 request=nil 时退回普通
    /// typed boundary；非 nil 时必须 fail-closed，禁止静默丢失目标级最终重验。
    func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    ) async -> TrashSubmissionDisposition

    /// **v2026.07.16 durable review binding**: carries the exact scan/review snapshot that
    /// produced the confirmation into the persistent recycle ledger. Production callers must
    /// use this overload; the legacy overload remains for test/debug implementations and is
    /// deliberately represented by `nil`, which cannot clear a durable fresh-review tombstone.
    func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?
    ) async -> TrashSubmissionDisposition

    /// v2026.07.17 source-proof boundary. Duplicate submissions carry their frozen full-content
    /// evidence all the way into the production pipeline; compatibility implementations must
    /// fail closed rather than silently discard a non-nil proof.
    func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?
    ) async -> TrashSubmissionDisposition

    /// v2026.07.17 observable long-task boundary. The optional observer mirrors typed progress
    /// from either source-proof work or the ordinary recycle transaction. Compatibility
    /// implementations fail closed when an observer is requested rather than presenting a
    /// minutes-long opaque spinner while silently discarding updates.
    func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?,
        executionProgressObserver: DeletionExecutionProgressObserver?
    ) async -> TrashSubmissionDisposition

    /// 历史兼容入口。它不能泛化绕过 `.forbid`，因此实现只能等价于普通删除；
    /// vendorPathRule 的专业模式能力必须走上面的类型化请求与最终重验，不能复用本接口。
    func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?)
}

/// 单次删除请求的不可变预检结果。若任一路径被拒绝，批级原子合同会让
/// `allowedPaths` 为空，并把原本可处理的路径以 `batchContainsForbidden` 一并列入
/// `rejections`；因此 UI 展示和最终执行的计数保持一致。
public struct DeletionPreflight: Sendable, Equatable {
    public struct Rejection: Sendable, Equatable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public let allowedPaths: [String]
    public let rejections: [Rejection]
    /// 只有整批仍处于用户删除能力范围内，且至少一项只因
    /// `vendorPathRule` 被拒时非空。同批原本安全项的
    /// `batchContainsForbidden` 是原子批处理的派生原因，不会单独取消资格；
    /// hard forbid / whitelist / accessDenied / protected bundle 等任一真实安全原因仍会让整批为空。
    public let vendorOverrideEligiblePaths: [String]

    public init(allowedPaths: [String], rejections: [Rejection]) {
        self.allowedPaths = allowedPaths
        self.rejections = rejections
        self.vendorOverrideEligiblePaths = []
    }

    init(allowedPaths: [String],
         rejections: [Rejection],
         vendorOverrideEligiblePaths: [String]) {
        self.allowedPaths = allowedPaths
        self.rejections = rejections
        self.vendorOverrideEligiblePaths = vendorOverrideEligiblePaths
    }

    public var canProceed: Bool { rejections.isEmpty }
}

/// 由生产预检铸造的 vendor-only override 请求。
///
/// 构造器不公开给包外调用方；同一模块内即使拿到/裁剪了请求，TrashPipeline 最终仍会
/// 重新预检，所以这个类型表达的是用户意图，不是绕过底层校验的 bearer token。
public struct VendorPathOverrideRequest: Sendable, Equatable {
    public let paths: [String]
    public let vendorRuleProtectedPaths: [String]

    init?(preflight: DeletionPreflight) {
        self.init(
            eligiblePaths: preflight.vendorOverrideEligiblePaths,
            rejectedPaths: preflight.rejections.map(\.path),
            vendorProtectedPaths: preflight.rejections.compactMap {
                $0.reason == SafetyRejection.vendorPathRule.rawValue ? $0.path : nil
            },
            hasAllowedPaths: !preflight.allowedPaths.isEmpty
        )
    }

    init?(eligiblePaths: [String],
          rejectedPaths: [String],
          vendorProtectedPaths: [String],
          hasAllowedPaths: Bool = false) {
        guard !eligiblePaths.isEmpty,
              !hasAllowedPaths,
              Set(eligiblePaths) == Set(rejectedPaths),
              !vendorProtectedPaths.isEmpty,
              vendorProtectedPaths.allSatisfy(Set(eligiblePaths).contains) else { return nil }
        self.paths = eligiblePaths
        self.vendorRuleProtectedPaths = vendorProtectedPaths
    }

    private init(validatedPaths: [String], vendorProtectedPaths: [String]) {
        self.paths = validatedPaths
        self.vendorRuleProtectedPaths = vendorProtectedPaths
    }

    func restricting(to paths: [String]) -> VendorPathOverrideRequest? {
        let original = Set(self.paths)
        guard !paths.isEmpty, paths.allSatisfy(original.contains) else { return nil }
        let remaining = Set(paths)
        let remainingVendorPaths = vendorRuleProtectedPaths.filter(remaining.contains)
        guard !remainingVendorPaths.isEmpty else { return nil }
        return VendorPathOverrideRequest(
            validatedPaths: paths,
            vendorProtectedPaths: remainingVendorPaths
        )
    }
}

/// v2026.07.15：TrashPipeline 自身产生的摘要错误保持为结构化事实。旧四元组中的
/// String 只保留兼容诊断；用户界面必须在渲染时调用 `message(locale:)`。
public enum TrashFailureSummary: Sendable, Equatable, Hashable {
    public static let unknownRecycleReasonKey = "trash.recycle.failure.unknown"

    case safetyBlocked(count: Int, firstReason: String, preview: Bool)
    case previewMissing(count: Int)
    case recycleFailed(failedCount: Int, movedCount: Int, firstPath: String?)
    /// v2026.07.16：系统已接受废纸篓请求，但在产品等待窗口内没有回调。此状态既不
    /// 是成功也不是失败；调用方必须保留原扫描结果，并提示用户稍后重新扫描确认。
    case recyclePending(pendingCount: Int, notSubmittedCount: Int, movedCount: Int)
    /// The synchronous AppKit API did not return, so acceptance itself is unknown.
    case recycleSubmissionUnknown(unknownCount: Int, notSubmittedCount: Int, movedCount: Int)
    /// 整体等待预算耗尽，后续路径明确没有交给系统；它们可在重新审阅后安全重试。
    case recycleBudgetExpired(notSubmittedCount: Int, movedCount: Int, failedCount: Int)

    public func message(locale: Locale) -> String {
        switch self {
        case .safetyBlocked(let count, let firstReason, let preview):
            if preview {
                return AppLocalization.format(
                    "trash.err.dryrun.safety_blocked %lld",
                    locale: locale,
                    arguments: [Int64(count)]
                ) + AppLocalization.format(
                    "trash.err.first_reason_suffix %@",
                    locale: locale,
                    arguments: [firstReason]
                )
            }
            return AppLocalization.format(
                "trash.err.safety_blocked_only %lld %@",
                locale: locale,
                arguments: [Int64(count), firstReason]
            )
        case .previewMissing(let count):
            return AppLocalization.format(
                "trash.err.dryrun.missing %lld",
                locale: locale,
                arguments: [Int64(count)]
            )
        case .recycleFailed(let failedCount, let movedCount, let firstPath):
            let partialNote = movedCount > 0
                ? AppLocalization.format(
                    "trash.err.partial_note %lld",
                    locale: locale,
                    arguments: [Int64(movedCount)]
                )
                : ""
            let firstFailure = firstPath.map {
                AppLocalization.format(
                    "trash.err.first_fail_path %@",
                    locale: locale,
                    arguments: [$0]
                )
            } ?? ""
            return AppLocalization.format(
                "trash.err.recycle_failed %lld %@ %@",
                locale: locale,
                arguments: [Int64(failedCount), partialNote, firstFailure]
            )
        case .recyclePending(let pendingCount, let notSubmittedCount, let movedCount):
            return AppLocalization.format(
                "trash.err.recycle_pending %lld %lld %lld",
                locale: locale,
                arguments: [Int64(pendingCount), Int64(notSubmittedCount), Int64(movedCount)]
            )
        case .recycleSubmissionUnknown(let unknownCount, let notSubmittedCount, let movedCount):
            return AppLocalization.format(
                "trash.err.recycle_submission_unknown %lld %lld %lld",
                locale: locale,
                arguments: [Int64(unknownCount), Int64(notSubmittedCount), Int64(movedCount)]
            )
        case .recycleBudgetExpired(let notSubmittedCount, let movedCount, let failedCount):
            return AppLocalization.format(
                "trash.err.recycle_budget_expired %lld %lld %lld",
                locale: locale,
                arguments: [Int64(notSubmittedCount), Int64(movedCount), Int64(failedCount)]
            )
        }
    }

    /// 兼容旧协议的稳定诊断，不进入产品 UI，也不依赖进程首选语言。
    var legacyDiagnostic: String {
        switch self {
        case .safetyBlocked(let count, let firstReason, let preview):
            return "trash.err.safety_blocked_only count=\(count) reason=\(firstReason) preview=\(preview)"
        case .previewMissing(let count):
            return "preview-missing count=\(count)"
        case .recycleFailed(let failedCount, let movedCount, let firstPath):
            return "recycle-failed failed=\(failedCount) moved=\(movedCount) first=\(firstPath ?? "none")"
        case .recyclePending(let pendingCount, let notSubmittedCount, let movedCount):
            return "recycle-pending pending=\(pendingCount) not-submitted=\(notSubmittedCount) moved=\(movedCount)"
        case .recycleSubmissionUnknown(let unknownCount, let notSubmittedCount, let movedCount):
            return "recycle-submission-unknown unknown=\(unknownCount) not-submitted=\(notSubmittedCount) moved=\(movedCount)"
        case .recycleBudgetExpired(let notSubmittedCount, let movedCount, let failedCount):
            return "recycle-budget-expired not-submitted=\(notSubmittedCount) moved=\(movedCount) failed=\(failedCount)"
        }
    }
}

/// v2026.06.16：单次 `moveToTrash` 的结构化明细。它不携带提交边界证明；只有与
/// `TrashSubmissionDisposition.recycleCompleted` 绑定时才能供执行结果页消费。
public struct TrashOutcome: Sendable, Equatable {
    /// 实际成功移入废纸篓的 (原路径, 废纸篓路径) 对——可写 UndoHistory。
    public let movedPairs: [(originalPath: String, trashedPath: String)]
    /// `NSWorkspace.recycle` 真正失败的路径清单（不含被 SafetyEngine 拦的）。
    /// 来自分批 recycle 中的"批失败回退单 URL 隔离"路径。
    public let failedPaths: [String]
    /// 已交给 `NSWorkspace.recycle`、但系统尚未返回最终回调的路径。它们不得计作失败、
    /// 不得自动重试，也不能写入 Undo；只能通过后续重新扫描确认最终状态。
    public let pendingPaths: [String]
    /// **v2026.07.16 根因修复**：提交队列已经取得调用 claim，并进入同步
    /// `NSWorkspace.recycle` API，但 API 本身在等待预算内没有返回。此时甚至不能断言
    /// macOS 已接受请求，必须与“API 已返回、只缺 callback”的 `pendingPaths` 分开。
    public let submissionUnknownPaths: [String]
    /// 因前一批仍处于未知状态而主动停止、尚未提交给系统的路径。
    public let notSubmittedPaths: [String]
    /// `notSubmittedPaths` 中由持久 gate 拒绝的精确 typed reason。普通预算停止无需逐项
    /// reason，保持空字典；身份变化/ledger 故障绝不能退化成通用失败字符串。
    public let notSubmittedReasons: [String: TrashPendingOperationRejection.Reason]
    /// 被 [SafetyEngine](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/SafetyEngine.swift) 或 `accessDeniedPaths`
    /// 拦下的路径清单（拒绝原因可读）。
    public let safetyRejected: [(path: String, reason: String)]
    /// dryRun 模式下的"路径不存在"清单（仅 dryRun=true 时填充）。
    public let missingPaths: [String]
    /// `NSWorkspace.recycle` 对每条最终失败路径返回的具体系统原因。
    /// key 必须同时出现在 `failedPaths`；旧调用方未提供时保持空字典。
    public let failureReasons: [String: String]
    /// 最终 normal 预检生成的 vendor-only override 能力；只用于后续呈现更严格确认。
    public let vendorOverrideEligiblePaths: [String]
    /// 产品自身生成的摘要失败；系统逐路径原文仍保存在 `failureReasons`。
    public let failureSummary: TrashFailureSummary?

    public init(movedPairs: [(String, String)],
                failedPaths: [String],
                pendingPaths: [String] = [],
                submissionUnknownPaths: [String] = [],
                notSubmittedPaths: [String] = [],
                notSubmittedReasons: [String: TrashPendingOperationRejection.Reason] = [:],
                safetyRejected: [(String, String)],
                missingPaths: [String],
                failureReasons: [String: String] = [:],
                vendorOverrideEligiblePaths: [String] = [],
                failureSummary: TrashFailureSummary? = nil) {
        self.movedPairs = movedPairs.map { (originalPath: $0.0, trashedPath: $0.1) }
        self.failedPaths = failedPaths
        self.pendingPaths = pendingPaths
        self.submissionUnknownPaths = submissionUnknownPaths
        self.notSubmittedPaths = notSubmittedPaths
        let notSubmittedSet = Set(notSubmittedPaths)
        self.notSubmittedReasons = notSubmittedReasons.filter { notSubmittedSet.contains($0.key) }
        self.safetyRejected = safetyRejected.map { (path: $0.0, reason: $0.1) }
        self.missingPaths = missingPaths
        let failedPathSet = Set(failedPaths)
        self.failureReasons = failureReasons.filter { failedPathSet.contains($0.key) }
        self.vendorOverrideEligiblePaths = vendorOverrideEligiblePaths
        self.failureSummary = failureSummary
    }

    /// 本次请求涉及的路径总数。`notSubmittedPaths` 尚未跨过系统提交边界，但必须计入
    /// UI 结果，避免用户误以为整批已处理。
    public var totalSubmitted: Int {
        movedPairs.count + failedPaths.count + pendingPaths.count + submissionUnknownPaths.count
            + notSubmittedPaths.count
            + safetyRejected.count + missingPaths.count
    }

    /// Equatable：tuple 类型自定义比较（Swift tuple 不直接 Equatable）。
    public static func == (lhs: TrashOutcome, rhs: TrashOutcome) -> Bool {
        guard lhs.failedPaths == rhs.failedPaths,
              lhs.pendingPaths == rhs.pendingPaths,
              lhs.submissionUnknownPaths == rhs.submissionUnknownPaths,
              lhs.notSubmittedPaths == rhs.notSubmittedPaths,
              lhs.notSubmittedReasons == rhs.notSubmittedReasons,
              lhs.missingPaths == rhs.missingPaths,
              lhs.failureReasons == rhs.failureReasons,
              lhs.vendorOverrideEligiblePaths == rhs.vendorOverrideEligiblePaths,
              lhs.failureSummary == rhs.failureSummary,
              lhs.movedPairs.count == rhs.movedPairs.count,
              lhs.safetyRejected.count == rhs.safetyRejected.count else { return false }
        for i in lhs.movedPairs.indices {
            if lhs.movedPairs[i].originalPath != rhs.movedPairs[i].originalPath
                || lhs.movedPairs[i].trashedPath != rhs.movedPairs[i].trashedPath {
                return false
            }
        }
        for i in lhs.safetyRejected.indices {
            if lhs.safetyRejected[i].path != rhs.safetyRejected[i].path
                || lhs.safetyRejected[i].reason != rhs.safetyRejected[i].reason {
                return false
            }
        }
        return true
    }
}

/// 真正进入系统 recycle 之前可能发生的终止原因。这里保留完整预检证据，使 UI 能
/// 直接区分“需要升级到 vendor 严格确认”和“不可覆盖的安全阻断”；不包含任何执行结果。
public enum TrashPreSubmitRejection: Sendable, Equatable {
    case emptyRequest
    case safety(DeletionPreflight)
    case invalidVendorOverride(DeletionPreflight)
    case invalidScanIncompleteOverride([DeletionPreflight.Rejection])
    case invalidDuplicateVerification([DeletionPreflight.Rejection])
    /// Persistent duplicate-submission / identity / queue-claim gate. This remains a
    /// confirmation-time typed block and can never construct an operation result.
    case pendingOperation(TrashPendingOperationRejection)
    /// 兼容测试/旧实现的 fail-closed case。生产 `TrashPipeline` 不会返回它。
    case unsupportedPipeline
}

/// 已完成至少一次 `NSWorkspace.recycle` 调用的结构化回执。`attemptedPaths` 是系统
/// 提交边界的精确输入。v2026.07.16 起真实 UI 还必须取得与它精确分区的 outcome；仅凭
/// legacy tuple 或 attemptedPaths 不足以铸造结果 receipt，也不能触发 Undo/模型通知。
///
/// v2026.07.16：类型名保留兼容，但“完成”只表示至少取得过系统调用 claim。
/// `submissionUnknownPaths` 表示同步 API 未返回，`pendingPaths` 表示 API 已返回但回调
/// 未到，`notSubmittedPaths` 表示未取得调用 claim；调用方不得把它们当成功、失败或
/// 可立即重试项。
public struct TrashRecycleCompletion: Sendable {
    public let attemptedPaths: [String]
    public let legacy: (Int, Int, String?, [(String, String)])
    public let outcome: TrashOutcome?
    /// Non-nil only for the production TrashPipeline. Callers must durably merge these exact
    /// journal rows into UndoHistory before consuming the capability.
    let undoCommit: TrashUndoCommitCapability?
    /// Moved paths whose callback fact could not cross the completion-journal boundary. They are
    /// intentionally retained in the pending ledger and surfaced as typed storage failure.
    let undoJournalFailedPaths: [String]
    /// Exact operation generations authoritatively retained by the ledger for those failures.
    /// Empty for compatibility pipelines and for completions with a healthy journal boundary.
    let undoJournalBlockedAttempts: Set<TrashPendingAttemptIdentity>

    public init(
        attemptedPaths: [String],
        legacy: (Int, Int, String?, [(String, String)]),
        outcome: TrashOutcome?
    ) {
        precondition(!attemptedPaths.isEmpty, "A recycle completion requires attempted paths")
        self.attemptedPaths = attemptedPaths
        self.legacy = legacy
        self.outcome = outcome
        self.undoCommit = nil
        self.undoJournalFailedPaths = []
        self.undoJournalBlockedAttempts = []
    }

    init(
        attemptedPaths: [String],
        legacy: (Int, Int, String?, [(String, String)]),
        outcome: TrashOutcome?,
        undoCommit: TrashUndoCommitCapability?,
        undoJournalFailedPaths: [String],
        undoJournalBlockedAttempts: Set<TrashPendingAttemptIdentity> = []
    ) {
        precondition(!attemptedPaths.isEmpty, "A recycle completion requires attempted paths")
        self.attemptedPaths = attemptedPaths
        self.legacy = legacy
        self.outcome = outcome
        self.undoCommit = undoCommit
        self.undoJournalFailedPaths = undoJournalFailedPaths
        self.undoJournalBlockedAttempts = undoJournalBlockedAttempts
    }
}

/// `TrashPipeline` 的真实提交边界。只有 `.recycleCompleted` 可继续构造
/// `TrashActionCoordinator.Result` / `OperationResultPayload`。
public enum TrashSubmissionDisposition: Sendable {
    case preSubmitRejected(TrashPreSubmitRejection)
    case recycleCompleted(TrashRecycleCompletion)
}

extension DeletionPipeline {
    public func prepareScanIncompleteOverride(
        rows: [RowItem],
        scanIssues: [ScanIncompleteIssue],
        scanSessionID: UUID
    ) async -> ScanIncompleteOverridePreparation {
        .blocked(rows.map {
            .init(
                path: $0.url.path,
                reason: ScanIncompleteTargetRejectionReason.invalidStrictRequest.rawValue
            )
        })
    }

    /// 默认 nil：历史 stub / dry-run pipeline 没有结构化结果可暴露——返回 nil 即可。
    /// UI 拿到 nil 会回退到旧的 4 元组拼接文案。
    public func snapshotLastOutcome() -> TrashOutcome? {
        return nil
    }

    /// **P0-3 默认实现**：复用旧 `moveToTrash` + `snapshotLastOutcome()`。
    /// 真删除链路（TrashPipeline）会 override 此方法，**原子**返回 outcome，
    /// 不再依赖 side-channel 快照槽位；stub / dryRun pipeline 走默认即可。
    public func moveToTrashReturningOutcome(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        let legacy = await moveToTrash(paths: paths, dryRun: dryRun)
        let outcome = snapshotLastOutcome()
        return (legacy, outcome)
    }

    /// 兼容实现先注入再调用旧接口；生产 TrashPipeline override 为真正的 request-scoped 原子入口。
    public func moveToTrashReturningOutcome(
        paths: [String],
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        setAccessDeniedPaths(accessDeniedPaths)
        return await moveToTrashReturningOutcome(paths: paths, dryRun: dryRun)
    }

    /// 默认实现绝不放宽：只有生产 TrashPipeline 覆写后才能执行 vendor-only override。
    public func moveToTrashVendorPathOverride(
        request: VendorPathOverrideRequest,
        dryRun: Bool,
        accessDeniedPaths: Set<String>
    ) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        await moveToTrashReturningOutcome(
            paths: request.paths,
            dryRun: dryRun,
            accessDeniedPaths: accessDeniedPaths
        )
    }

    /// 未迁移的实现默认 fail closed。绝不能退回旧接口后依据 outcome/pairs 猜测它是否
    /// 调过 recycle；只有明确实现该 typed boundary 的 pipeline 才能供 Professional 提交。
    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?
    ) async -> TrashSubmissionDisposition {
        guard !paths.isEmpty else {
            return .preSubmitRejected(.emptyRequest)
        }
        return .preSubmitRejected(.unsupportedPipeline)
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    ) async -> TrashSubmissionDisposition {
        guard scanIncompleteOverrideRequest == nil else {
            return .preSubmitRejected(.unsupportedPipeline)
        }
        return await submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest
        )
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?,
        executionProgressObserver: DeletionExecutionProgressObserver?
    ) async -> TrashSubmissionDisposition {
        // Existing test/debug pipelines have no progress transport. Nil keeps their old behavior;
        // a requested observer must fail closed so production UI cannot show a fabricated spinner.
        guard executionProgressObserver == nil else {
            return .preSubmitRejected(.unsupportedPipeline)
        }
        return await submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity,
            executionVerification: executionVerification
        )
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?
    ) async -> TrashSubmissionDisposition {
        // v2026.07.16: compatibility stubs cannot persist a review capability themselves. Keep
        // their old typed boundary working, while the production TrashPipeline overrides this
        // overload and binds the identity to the durable reservation transaction.
        await submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest
        )
    }

    public func submitToTrashReturningDisposition(
        paths: [String],
        accessDeniedPaths: Set<String>,
        vendorOverrideRequest: VendorPathOverrideRequest?,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?,
        reviewIdentity: DeletionSnapshotIdentity?,
        executionVerification: DeletionExecutionVerification?
    ) async -> TrashSubmissionDisposition {
        guard executionVerification == nil else {
            return .preSubmitRejected(.unsupportedPipeline)
        }
        return await submitToTrashReturningDisposition(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            reviewIdentity: reviewIdentity
        )
    }

    /// 历史兼容：force 也必须完整执行普通安全判定。
    public func moveToTrashForce(paths: [String], dryRun: Bool) async -> (legacy: (Int, Int, String?, [(String, String)]), outcome: TrashOutcome?) {
        return await moveToTrashReturningOutcome(paths: paths, dryRun: dryRun)
    }
}
