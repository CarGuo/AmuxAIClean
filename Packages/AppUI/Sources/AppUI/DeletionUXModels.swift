import Foundation
import ScanKit
import SafetyKit

/// 删除确认页产生的语义化动作，避免用一个含义不清的 Bool 在 UI 与执行层之间传递。
public enum DeleteSheetAction: Sendable, Equatable {
    /// 仅供 Debug 构建诊断，不移动文件。
    case preview
    /// 真正尝试移到废纸篓；运行中 App 只影响本次选择策略，不改变安全等级。
    case moveToTrash(
        resolution: RunningAppGuard.Resolution,
        runningApplications: [RunningAppGuard.RunningApplication],
        confirmedConflicts: [RunningAppGuard.Conflict]
    )

    public var isDryRun: Bool {
        if case .preview = self { return true }
        return false
    }
}

/// 用户从哪个专业模式表面发起删除。它既决定审计日志来源，也让成功后的 UI
/// 只清理对应选择状态；执行安全规则不随来源变化。
public enum DeleteRequestOrigin: String, Sendable, Hashable {
    case scanSelection
    case tree
    case largeFiles
    case stash
    case smartCare
    case brew
    case duplicate
    case uninstall
    case workflowFilesystem

    var historySource: String {
        switch self {
        case .scanSelection: return "clean"
        case .tree: return "tree"
        case .largeFiles: return "large-file"
        case .stash: return "stash"
        case .smartCare: return "smart-care"
        case .brew: return "brew"
        case .duplicate: return "duplicate"
        case .uninstall: return "uninstall"
        case .workflowFilesystem: return "workflow"
        }
    }
}

/// 把 Tree 当前可见行冻结成删除确认使用的不可变 `RowItem`。
///
/// 按需展开的 `TreeRow` 不保证进入 ScanCoordinator 的全局索引，因此这里明确要求
/// 调用方传入完整行，而不是只传 URL 后再回查。这样确认页、运行项检测与删除后的
/// 统计始终消费用户点击时看到的 size/count/directory 事实。
enum DeletionRowSnapshotFactory {
    static func tree(
        _ row: TreeRow,
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        vendorName: String? = nil,
        vendorNote: String? = nil,
        runningBundleIDPrefix: String? = nil
    ) -> RowItem? {
        // A pending lazy row has not established its byte/count facts yet. Freezing it would turn
        // an unknown directory into a misleading zero-byte deletion request. Every Tree entry
        // point also disables the action, while this guard protects future/non-UI callers.
        guard !row.isSizePending else { return nil }
        return RowItem(
            id: row.path,
            url: URL(fileURLWithPath: row.path).standardizedFileURL,
            title: row.title,
            isDirectory: row.isDirectory,
            bytes: row.bytes,
            logicalBytes: row.logicalBytes,
            fileCount: row.fileCount,
            verdict: verdict,
            rejection: rejection,
            vendorName: vendorName,
            vendorNote: vendorNote,
            runningBundleIDPrefix: runningBundleIDPrefix,
            modificationDate: row.modificationDate
        )
    }
}

/// Reconciles the value-type Tree selection after the coordinator commits a successful prune.
/// A deleted selection disappears; a surviving ancestor is replaced with the coordinator's new
/// aggregate so the detail pane cannot keep the pre-delete size/count snapshot.
@MainActor
enum TreeSelectionReconciler {
    static func afterSuccessfulDeletion(
        selected: TreeRow?,
        succeededPaths: [String],
        refreshedRow: (String) -> TreeRow?
    ) -> TreeRow? {
        guard let selected else { return nil }
        if succeededPaths.contains(where: { deletedPath in
            selected.path == deletedPath || selected.path.hasPrefix(deletedPath + "/")
        }) {
            return nil
        }
        return refreshedRow(selected.path) ?? selected
    }
}

/// 删除意图形成时的产品模式。模式只影响哪些产品风险可进入严格确认，不能改变
/// `TrashPipeline` 的路径范围、hard-forbid 或最终重验。
public enum DeletionUserMode: String, Sendable, Equatable {
    case normal
    case professional
}

/// 用户看到候选时对应的扫描/发现快照身份。所有授权都必须绑定该身份；相同类目
/// 重新扫描后即使路径文本相同，也不能复用旧确认。
public struct DeletionSnapshotIdentity: Sendable, Equatable, Hashable, Codable {
    public let sessionID: UUID
    public let revision: UInt64
    public let categoryID: String?

    public init(sessionID: UUID, revision: UInt64, categoryID: String? = nil) {
        self.sessionID = sessionID
        self.revision = revision
        self.categoryID = categoryID
    }
}

/// 扫描证据不完整的精确来源。它描述“我们没看全”，不等价于 macOS 一定不能
/// 移动目标；专业严格尝试前仍必须完成目标级路径/父目录能力重验。
public enum DeletionIncompleteReason: String, Sendable, Equatable {
    case permissionDenied
    case tccProtected
    case incompleteEnumeration
    /// 兼容当前 `accessDenied` 聚合证据；迁移完成后生产代码不应继续产生此值。
    case unspecified
}

extension DeletionIncompleteReason {
    init(scanIncompleteReason: ScanIncompleteReason) {
        switch scanIncompleteReason {
        case .permissionDenied:
            self = .permissionDenied
        case .tccProtectedSkipped:
            self = .tccProtected
        case .enumerationFailed, .metadataUnavailable:
            self = .incompleteEnumeration
        }
    }
}

public enum DeletionAccessEvidence: Sendable, Equatable {
    case complete
    case incomplete(DeletionIncompleteReason)
}

/// 可由专业模式严格确认表达的产品风险。这里是确认计划中的资格，不是底层删除
/// bearer token；真正执行仍需要由生产预检铸造的类型化授权并最终重验。
public enum ProfessionalOverrideReason: Sendable, Equatable {
    case vendorPathRule
    case scanIncomplete(DeletionIncompleteReason)
}

/// 单个候选相对于专业覆盖能力的完整判定，避免用 `Bool force` 把“需专业模式”、
/// “需独立重验”和“永不可绕过”混成一个状态。
public enum ProfessionalOverrideEligibility: Sendable, Equatable {
    /// 普通确认即可提交。
    case notRequired
    /// 已满足进入严格确认页的资格；仍不代表最终执行必然放行。
    case eligible(ProfessionalOverrideReason)
    /// 风险种类可覆盖，但当前仍是 Normal 模式。
    case requiresProfessionalMode(ProfessionalOverrideReason)
    /// 扫描证据不足，必须先完成目标级路径/父目录能力重验。
    case requiresTargetRevalidation(ProfessionalOverrideReason)
    /// 能力、身份或 hard-forbid 边界，任何模式都不能覆盖。
    case nonBypassable(SafetyRejection)
}

/// 扫描不完整证据相对于用户所选删除目标的位置。子孙节点不可枚举只说明容量/内容
/// 证据不完整，并不自动证明父目标不能被 `NSWorkspace.recycle` 移动。
enum DeletionIncompleteEvidenceScope: Sendable, Equatable {
    case selectedTarget
    case descendant
}

struct DeletionScopedIncompleteEvidence: Sendable, Equatable {
    let reason: DeletionIncompleteReason
    let scope: DeletionIncompleteEvidenceScope
}

/// 目标级重验必须携带此前扫描不完整证据，而不是用一次浅层 `stat` 把风险抹掉。
/// `.incomplete` 可同时包含目标自身与后代问题；`.unavailable` 表示无法可靠分类，
/// 不能被解释为“完整”。
enum DeletionTargetScanEvidence: Sendable, Equatable {
    case complete
    case incomplete([DeletionScopedIncompleteEvidence])
    case unavailable
}

/// 此处的“匹配”要求证据生产者比较稳定文件身份、文件类型和解析后的路径范围，
/// 不能只比较用户可见路径字符串。该值只是规划证据，不是执行授权。
enum DeletionTargetIdentityEvidence: Sendable, Equatable {
    case matchesSnapshot
    case changed
    case missing
    case unavailable
}

/// 目标当前不能进入移动尝试的精确来源。POSIX、TCC、ACL 与文件系统状态分开表达，
/// presentation 层因此无需把所有失败误导成“请授予完全磁盘访问权限”。
enum DeletionTargetMoveDenial: Sendable, Equatable {
    case posixPermissionDenied
    case tccDenied
    case aclDenied
    case immutable
    case readOnlyVolume
    case parentUnavailable
    case targetUnavailable
    case unclassifiedAccessFailure
}

/// `.eligibleForAttempt` 只表示目标级预检没有发现阻止“尝试移到废纸篓”的事实，
/// 不保证 `NSWorkspace.recycle` 一定成功；操作系统的实际结果仍是最终依据。
enum DeletionTargetMoveAttemptEvidence: Sendable, Equatable {
    case eligibleForAttempt
    case denied(DeletionTargetMoveDenial)
    case unavailable
}

/// 独立目标级重验的不可变输入。它必须绑定原候选身份与标准化路径，并携带当下重新
/// 计算的 SafetyEngine 结果。View 不能用本类型直接构造 `DeletionExecutionAuthorization`。
struct DeletionTargetRevalidationEvidence: Sendable, Equatable {
    let candidateID: UUID
    let standardizedPath: String
    let identity: DeletionTargetIdentityEvidence
    let currentVerdict: SafetyVerdict
    let currentRejection: SafetyRejection
    let scanEvidence: DeletionTargetScanEvidence
    let moveAttempt: DeletionTargetMoveAttemptEvidence

    init(
        candidateID: UUID,
        path: String,
        identity: DeletionTargetIdentityEvidence,
        currentVerdict: SafetyVerdict,
        currentRejection: SafetyRejection,
        scanEvidence: DeletionTargetScanEvidence,
        moveAttempt: DeletionTargetMoveAttemptEvidence
    ) {
        self.candidateID = candidateID
        self.standardizedPath = DeletionIntentCandidate.pathIdentity(path)
        self.identity = identity
        self.currentVerdict = currentVerdict
        self.currentRejection = currentRejection
        self.scanEvidence = scanEvidence
        self.moveAttempt = moveAttempt
    }
}

/// 严格尝试要向用户解释的全部风险，而不是一个会丢信息的 `force: Bool`。
enum DeletionTargetStrictAttemptReason: Sendable, Equatable {
    case vendorPathRule
    case scanIncomplete(DeletionScopedIncompleteEvidence)
}

struct DeletionTargetStrictAttempt: Sendable, Equatable {
    let reasons: [DeletionTargetStrictAttemptReason]
}

/// 目标级重验后的真正阻断原因。安全边界与当前文件系统能力分开，避免把一次 POSIX
/// 拒绝伪装成 hard-forbid，也避免专业模式误绕过永不可覆盖的边界。
enum DeletionTargetRevalidationBlockReason: Sendable, Equatable {
    case evidenceBoundToDifferentCandidate
    case evidenceBoundToDifferentPath
    case identityChanged
    case targetMissing
    case identityUnavailable
    case inconsistentSafetyEvidence(SafetyVerdict, SafetyRejection)
    case safety(SafetyRejection)
    case scanEvidenceUnavailable
    case incompleteEvidenceNotCarriedForward
    case emptyIncompleteEvidence
    case unresolvedIncompleteReason
    case moveDenied(DeletionTargetMoveDenial)
    case moveCapabilityUnavailable
    case requiresProfessionalMode
}

/// 纯规划决策：普通确认、专业严格尝试、或有精确原因的禁止。即使返回严格尝试，
/// 后续仍必须走统一确认状态机、TrashPipeline 与执行前最终重验。
enum DeletionTargetRevalidationDecision: Sendable, Equatable {
    case ordinaryAllow
    case strictAttempt(DeletionTargetStrictAttempt)
    case prohibited(DeletionTargetRevalidationBlockReason)
}

/// 一个删除候选的原始不可变快照。`rawPath` 保留原始文本供 SafetyEngine 检查
/// relative/`..`；`standardizedPath` 只用于候选之间的稳定身份比较，不能代替最终
/// symlink/scope 重验。
public struct DeletionIntentCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let rawPath: String
    public let standardizedPath: String
    public let title: String
    public let isDirectory: Bool
    public let bytes: Int64
    public let fileCount: Int
    public let verdict: SafetyVerdict
    public let rejection: SafetyRejection
    public let accessEvidence: DeletionAccessEvidence
    public let runningBundleIDPrefix: String?

    public init(
        id: UUID = UUID(),
        path: String,
        title: String,
        isDirectory: Bool,
        bytes: Int64,
        fileCount: Int,
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        accessEvidence: DeletionAccessEvidence = .complete,
        runningBundleIDPrefix: String? = nil
    ) {
        self.id = id
        self.rawPath = path
        self.standardizedPath = Self.pathIdentity(path)
        self.title = title
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.fileCount = fileCount
        self.verdict = verdict
        self.rejection = rejection
        self.accessEvidence = accessEvidence
        self.runningBundleIDPrefix = runningBundleIDPrefix
    }

    static func pathIdentity(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public enum DeletionIntentValidationError: Error, Sendable, Equatable {
    case emptyCandidates
    case emptyPath(candidateID: UUID)
    case duplicatePath(String)
    case duplicateCandidateID(UUID)
}

/// 所有真实文件删除入口提交给统一交互协调器的唯一输入。构造时拒绝空项和重复路径，
/// 防止确认页计数与最终 `NSWorkspace.recycle` 调用身份不一致。
public struct DeletionIntent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let origin: DeleteRequestOrigin
    public let mode: DeletionUserMode
    public let snapshotIdentity: DeletionSnapshotIdentity
    public let candidates: [DeletionIntentCandidate]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        origin: DeleteRequestOrigin,
        mode: DeletionUserMode,
        snapshotIdentity: DeletionSnapshotIdentity,
        candidates: [DeletionIntentCandidate],
        createdAt: Date = Date()
    ) throws {
        guard !candidates.isEmpty else {
            throw DeletionIntentValidationError.emptyCandidates
        }
        var candidateIDs = Set<UUID>()
        var paths = Set<String>()
        for candidate in candidates {
            guard !candidate.rawPath.isEmpty else {
                throw DeletionIntentValidationError.emptyPath(candidateID: candidate.id)
            }
            guard candidateIDs.insert(candidate.id).inserted else {
                throw DeletionIntentValidationError.duplicateCandidateID(candidate.id)
            }
            guard paths.insert(candidate.standardizedPath).inserted else {
                throw DeletionIntentValidationError.duplicatePath(candidate.standardizedPath)
            }
        }
        self.id = id
        self.origin = origin
        self.mode = mode
        self.snapshotIdentity = snapshotIdentity
        self.candidates = candidates
        self.createdAt = createdAt
    }
}

/// 确认页中不可提交项的精确原因。需切专业模式或目标级重验的项目当前同样不能
/// 进入授权，但它们与真正的 hard-forbid 分开表达，UI 才能给出正确下一步。
public enum DeletionConfirmationBlockReason: Sendable, Equatable {
    case safety(SafetyRejection)
    case requiresProfessionalMode(ProfessionalOverrideReason)
    case requiresTargetRevalidation(ProfessionalOverrideReason)
    case unrecognizedPreflightReason(String)
    case missingPreflightDecision
}

public enum DeletionConfirmationDisposition: Sendable, Equatable {
    case normal
    case strictOverride(ProfessionalOverrideReason)
    case nonBypassable(DeletionConfirmationBlockReason)
    case changedSinceScan
}

public struct DeletionConfirmationItem: Identifiable, Sendable, Equatable {
    public var id: UUID { candidate.id }
    public let candidate: DeletionIntentCandidate
    public let disposition: DeletionConfirmationDisposition

    public init(
        candidate: DeletionIntentCandidate,
        disposition: DeletionConfirmationDisposition
    ) {
        self.candidate = candidate
        self.disposition = disposition
    }
}

public enum DeletionConfirmationPlanValidationError: Error, Sendable, Equatable {
    case candidatePartitionMismatch
    case conflictOutsideSubmittableItems(String)
}

/// 预检的唯一 UI 输出。每个候选恰好有一个 disposition；运行中 App 是叠加在
/// normal/strict 项上的执行选择，不会改变 Safety 等级。
public struct DeletionConfirmationPlan: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let intent: DeletionIntent
    public let items: [DeletionConfirmationItem]
    public let runningAppConflicts: [RunningAppGuard.Conflict]
    public let preparedAt: Date

    init(
        id: UUID = UUID(),
        intent: DeletionIntent,
        items: [DeletionConfirmationItem],
        runningAppConflicts: [RunningAppGuard.Conflict] = [],
        preparedAt: Date = Date()
    ) throws {
        guard items.map(\.candidate.id) == intent.candidates.map(\.id) else {
            throw DeletionConfirmationPlanValidationError.candidatePartitionMismatch
        }
        let submittablePaths = Set(items.compactMap { item -> String? in
            switch item.disposition {
            case .normal, .strictOverride:
                return item.candidate.standardizedPath
            case .nonBypassable, .changedSinceScan:
                return nil
            }
        })
        for conflict in runningAppConflicts {
            let path = DeletionIntentCandidate.pathIdentity(conflict.path)
            guard submittablePaths.contains(path) else {
                throw DeletionConfirmationPlanValidationError.conflictOutsideSubmittableItems(path)
            }
        }
        self.id = id
        self.intent = intent
        self.items = items
        self.runningAppConflicts = runningAppConflicts
        self.preparedAt = preparedAt
    }

    public var normalItems: [DeletionConfirmationItem] {
        items.filter { if case .normal = $0.disposition { return true }; return false }
    }

    public var strictOverrideItems: [DeletionConfirmationItem] {
        items.filter { if case .strictOverride = $0.disposition { return true }; return false }
    }

    public var nonBypassableItems: [DeletionConfirmationItem] {
        items.filter { if case .nonBypassable = $0.disposition { return true }; return false }
    }

    public var changedSinceScanItems: [DeletionConfirmationItem] {
        items.filter { if case .changedSinceScan = $0.disposition { return true }; return false }
    }

    public var submittableItems: [DeletionConfirmationItem] {
        // Preserve the frozen intent order. Grouping normal items before strict
        // items would silently reorder the exact path list bound to typed
        // override requests and could make final revalidation reject a plan the
        // user just confirmed.
        items.filter {
            switch $0.disposition {
            case .normal, .strictOverride: return true
            case .nonBypassable, .changedSinceScan: return false
            }
        }
    }
}

/// prepare 阶段只有“展示确认计划”或“任务取消”，没有执行结果分支。即使计划全部是
/// non-bypassable，也必须由确认/解释页消费，不能伪造 `Cleanup Failed 0/N`。
public enum DeletionPreparationDecision: Sendable, Equatable {
    case requiresConfirmation(DeletionConfirmationPlan)
    case cancelled(intentID: UUID)
}

public enum DeletionRunningAppChoice: Sendable, Equatable {
    case noConflicts
    case skipRunningItems
    case requestQuitThenRevalidate
    case attemptWhileRunning
}

/// 用户确认的类型化证明。严格确认携带已经验证过的确认词和确认时间，不再使用裸
/// `Bool force`。实际协调器负责验证本地化输入，再构造本值。
public enum DeletionConfirmationProof: Sendable, Equatable {
    case standard(confirmedAt: Date)
    case professionalStrict(confirmationToken: String, confirmedAt: Date)
}

public struct DeletionProfessionalOverrideBinding: Sendable, Equatable {
    public let path: String
    public let reason: ProfessionalOverrideReason
}

public enum DeletionAuthorizationError: Error, Sendable, Equatable {
    case emptySelection
    case duplicateCandidateID(UUID)
    case candidateNotSubmittable(UUID)
    case strictConfirmationRequired
    case emptyStrictConfirmationToken
    case unresolvedRunningConflict(String)
    case noRunningConflictToResolve
}

/// 确认页到执行层之间的 request-scoped 授权。初始化器从 plan 派生精确路径和 override
/// 绑定，调用方不能自行传裸路径伪造能力。
public struct DeletionExecutionAuthorization: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let intentID: UUID
    public let planID: UUID
    public let snapshotIdentity: DeletionSnapshotIdentity
    public let paths: [String]
    public let overrideBindings: [DeletionProfessionalOverrideBinding]
    public let runningAppChoice: DeletionRunningAppChoice
    public let proof: DeletionConfirmationProof

    static func make(
        id: UUID = UUID(),
        plan: DeletionConfirmationPlan,
        selectedCandidateIDs: [UUID],
        runningAppChoice: DeletionRunningAppChoice,
        proof: DeletionConfirmationProof
    ) throws -> DeletionExecutionAuthorization {
        guard !selectedCandidateIDs.isEmpty else {
            throw DeletionAuthorizationError.emptySelection
        }
        var selectedIDs = Set<UUID>()
        for candidateID in selectedCandidateIDs {
            guard selectedIDs.insert(candidateID).inserted else {
                throw DeletionAuthorizationError.duplicateCandidateID(candidateID)
            }
        }

        let selectedSet = Set(selectedCandidateIDs)
        let selectedItems = plan.items.filter { selectedSet.contains($0.id) }
        guard selectedItems.count == selectedCandidateIDs.count else {
            let knownIDs = Set(plan.items.map(\.id))
            let missing = selectedCandidateIDs.first { !knownIDs.contains($0) }
            throw DeletionAuthorizationError.candidateNotSubmittable(missing ?? selectedCandidateIDs[0])
        }
        for item in selectedItems {
            guard item.disposition.isSubmittable else {
                throw DeletionAuthorizationError.candidateNotSubmittable(item.id)
            }
        }

        let conflictPaths = Set(plan.runningAppConflicts.map {
            DeletionIntentCandidate.pathIdentity($0.path)
        })
        let selectedPaths = Set(selectedItems.map(\.candidate.standardizedPath))
        switch runningAppChoice {
        case .noConflicts:
            guard conflictPaths.isEmpty else {
                throw DeletionAuthorizationError.unresolvedRunningConflict(
                    conflictPaths.sorted().first ?? ""
                )
            }
        case .skipRunningItems:
            if let conflict = selectedPaths.intersection(conflictPaths).sorted().first {
                throw DeletionAuthorizationError.unresolvedRunningConflict(conflict)
            }
        case .requestQuitThenRevalidate, .attemptWhileRunning:
            guard !conflictPaths.isEmpty else {
                throw DeletionAuthorizationError.noRunningConflictToResolve
            }
        }

        let selectedByID = Dictionary(uniqueKeysWithValues: selectedItems.map { ($0.id, $0) })
        let orderedItems = selectedCandidateIDs.compactMap { selectedByID[$0] }
        let overrideBindings = orderedItems.compactMap { item -> DeletionProfessionalOverrideBinding? in
            guard case .strictOverride(let reason) = item.disposition else { return nil }
            return DeletionProfessionalOverrideBinding(
                path: item.candidate.standardizedPath,
                reason: reason
            )
        }
        if !overrideBindings.isEmpty {
            guard case .professionalStrict(let token, _) = proof else {
                throw DeletionAuthorizationError.strictConfirmationRequired
            }
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeletionAuthorizationError.emptyStrictConfirmationToken
            }
        }

        return DeletionExecutionAuthorization(
            id: id,
            intentID: plan.intent.id,
            planID: plan.id,
            snapshotIdentity: plan.intent.snapshotIdentity,
            paths: orderedItems.map(\.candidate.standardizedPath),
            overrideBindings: overrideBindings,
            runningAppChoice: runningAppChoice,
            proof: proof
        )
    }

    private init(
        id: UUID,
        intentID: UUID,
        planID: UUID,
        snapshotIdentity: DeletionSnapshotIdentity,
        paths: [String],
        overrideBindings: [DeletionProfessionalOverrideBinding],
        runningAppChoice: DeletionRunningAppChoice,
        proof: DeletionConfirmationProof
    ) {
        self.id = id
        self.intentID = intentID
        self.planID = planID
        self.snapshotIdentity = snapshotIdentity
        self.paths = paths
        self.overrideBindings = overrideBindings
        self.runningAppChoice = runningAppChoice
        self.proof = proof
    }
}

private extension DeletionConfirmationDisposition {
    var isSubmittable: Bool {
        switch self {
        case .normal, .strictOverride: return true
        case .nonBypassable, .changedSinceScan: return false
        }
    }
}

public struct DeletionSubmissionReceipt: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let authorizationID: UUID
    public let intentID: UUID
    public let submittedPaths: [String]
    public let submittedAt: Date

    init(
        id: UUID = UUID(),
        authorizationID: UUID,
        intentID: UUID,
        submittedPaths: [String],
        submittedAt: Date = Date()
    ) {
        self.id = id
        self.authorizationID = authorizationID
        self.intentID = intentID
        self.submittedPaths = submittedPaths
        self.submittedAt = submittedAt
    }
}

/// `OperationResultSheet` 的呈现门。只有 `.submitted` 表示真实请求已经交给执行层；
/// preparing/awaitingConfirmation/authorized 都不得包装成操作结果。
public enum DeletionSubmissionState: Sendable, Equatable {
    case preparing(intentID: UUID)
    case awaitingConfirmation(intentID: UUID, planID: UUID)
    case authorized(DeletionExecutionAuthorization)
    case submitting(intentID: UUID, authorizationID: UUID, submissionID: UUID)
    case submitted(DeletionSubmissionReceipt)
    case cancelled(intentID: UUID)

    public var mayPresentOperationResult: Bool {
        if case .submitted = self { return true }
        return false
    }

    /// 是否已经跨过“用户确认”边界并开始调用执行层；它不代表执行已返回。
    public var hasReachedSubmissionBoundary: Bool {
        switch self {
        case .submitting, .submitted: return true
        case .preparing, .awaitingConfirmation, .authorized, .cancelled: return false
        }
    }
}

/// 主清理确认页的不可变快照。Sheet 展示、运行冲突决策与最终执行必须消费同一批 rows，
/// 防止用户看到 A、确认时却因 selection 更新而实际提交 A+B。
struct DeleteSheetRequest: Identifiable, Sendable, Equatable {
    var id: UUID { preparedInteraction.plan.id }
    let items: [RowItem]
    /// 与预览 rows 同一时刻冻结的扫描拒绝集合。执行层必须至少保留此集合；如果
    /// 同一完成会话在确认期间出现更多拒绝证据，只能做 frozen ∪ current，不能用
    /// 较新的较小集合覆盖它。
    let accessDeniedPaths: Set<String>
    /// Sheet 必须消费预检铸造的原计划，不能再用独立 Bool/请求状态重建严格确认资格。
    let preparedInteraction: DeletionPreparedInteraction

    var sourceCategoryID: String {
        preparedInteraction.plan.intent.snapshotIdentity.categoryID ?? ""
    }

    var scanSessionID: UUID {
        preparedInteraction.plan.intent.snapshotIdentity.sessionID
    }

    var origin: DeleteRequestOrigin { preparedInteraction.plan.intent.origin }

    var totalBytes: Int64 {
        let preparedPaths = Set(preparedInteraction.paths.map(DeletionIntentCandidate.pathIdentity))
        return items.reduce(Int64(0)) { partial, item in
            guard preparedPaths.contains(DeletionIntentCandidate.pathIdentity(item.url.path)) else {
                return partial
            }
            let sum = partial.addingReportingOverflow(max(0, item.bytes))
            return sum.overflow ? .max : sum.partialValue
        }
    }

    init(items: [RowItem],
         accessDeniedPaths: Set<String>,
         preparedInteraction: DeletionPreparedInteraction) {
        self.items = items
        self.accessDeniedPaths = accessDeniedPaths
        self.preparedInteraction = preparedInteraction
    }
}

/// DeleteSheet 关闭与结果 sheet 呈现之间的确定性交接。
/// 删除事务只能在前一张 sheet 的 onDismiss 之后取出，避免“全部跳过”等瞬时结果
/// 与 macOS 的 dismiss 动画竞争而丢失结果页。
enum DeleteSubmission: Sendable, Equatable {
    case professional(request: DeleteSheetRequest, executionPlan: ToolTrashExecutionPlan)
    case smartCare(
        request: SmartCareCleanRequest,
        action: DeleteSheetAction,
        accessDeniedPaths: Set<String>
    )
}

struct DeleteSubmissionHandoff: Sendable, Equatable {
    private(set) var pending: DeleteSubmission?

    var hasPending: Bool { pending != nil }

    @discardableResult
    mutating func schedule(_ submission: DeleteSubmission) -> Bool {
        guard pending == nil else { return false }
        pending = submission
        return true
    }

    mutating func takeAfterSheetDismissal() -> DeleteSubmission? {
        defer { pending = nil }
        return pending
    }
}

/// 专业工具迁移期的确认前安全门。新统一 coordinator 必须使用
/// `prepareConfirmationDecision`，其输出只有确认计划/取消；旧 `Decision` 暂留给尚未
/// 迁移的 View，不能再作为新入口合同，也不能把 `.rejection` 包装成执行结果。
enum ToolDeletionPreflightGate {
    enum Decision: Sendable, Equatable {
        case confirmation(paths: [String])
        case rejection([DeletionPreflight.Rejection])
        case vendorOverride(
            request: VendorPathOverrideRequest,
            rejections: [DeletionPreflight.Rejection]
        )
    }

    static func prepareConfirmationDecision(
        pipeline: any DeletionPipeline,
        intent: DeletionIntent,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        accessDeniedPaths: Set<String> = [],
        runningAppConflicts: [RunningAppGuard.Conflict] = []
    ) async throws -> DeletionPreparationDecision {
        let preflight = await pipeline.preflight(
            paths: intent.candidates.map(\.rawPath),
            accessDeniedPaths: accessDeniedPaths
        )
        return try DeletionConfirmationPlanner.makeDecision(
            intent: intent,
            preflight: preflight,
            currentSnapshotIdentity: currentSnapshotIdentity,
            runningAppConflicts: runningAppConflicts
        )
    }

    /// 仅供当前尚未迁移的工具 View 编译兼容。统一 coordinator 接入后删除。
    static func prepare(
        pipeline: any DeletionPipeline,
        paths: [String],
        accessDeniedPaths: Set<String> = []
    ) async -> Decision {
        let preflight = await pipeline.preflight(
            paths: paths,
            accessDeniedPaths: accessDeniedPaths
        )
        guard preflight.canProceed else {
            if let request = VendorPathOverrideRequest(preflight: preflight) {
                return .vendorOverride(
                    request: request,
                    rejections: preflight.rejections
                )
            }
            return .rejection(preflight.rejections)
        }
        return .confirmation(paths: preflight.allowedPaths)
    }
}

/// 工具确认 sheet 与真正执行之间的一次性交接。
/// 删除只能在 sheet 的 `onDismiss` 中取出，避免确认页的 dismiss 动画与极快的
/// 删除结果页竞争。泛型让三个工具共享同一条生命周期合同，而不把工具语义塞进
/// MainView / Smart Care 使用的 `DeleteSubmission`。
struct ToolDeletionHandoff<Value: Sendable>: Sendable {
    private(set) var pending: Value?

    var hasPending: Bool { pending != nil }

    @discardableResult
    mutating func schedule(_ value: Value) -> Bool {
        guard pending == nil else { return false }
        pending = value
        return true
    }

    mutating func takeAfterSheetDismissal() -> Value? {
        defer { pending = nil }
        return pending
    }
}

/// 异步预检的“最后一次请求获胜”令牌。
///
/// `Task.cancel()` 只能发出协作式取消信号，注入的 pipeline 可能已经进入不可取消的
/// 系统调用；因此 UI 在消费结果前还必须用 token + context 做一次原子式校验。
/// 关闭页面、切换选择或发起新请求后，旧任务即使晚返回也不能重新弹出确认页。
struct ToolDeletionPreflightRequestGate<Context: Sendable & Equatable>: Sendable {
    struct Token: Sendable, Equatable {
        fileprivate let id: UUID
        fileprivate let context: Context
    }

    private var current: Token?

    var hasCurrentRequest: Bool { current != nil }

    mutating func begin(context: Context) -> Token {
        let token = Token(id: UUID(), context: context)
        current = token
        return token
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let hadCurrentRequest = current != nil
        current = nil
        return hadCurrentRequest
    }

    mutating func finishIfCurrent(_ token: Token, context: Context) -> Bool {
        guard current == token, token.context == context else { return false }
        current = nil
        return true
    }
}

/// ToolTrashConfirmationSheet 冻结后的最终执行计划。
/// 跳过运行中 App 只会删减本次路径集合；留下的路径仍会由 TrashPipeline 重新进行
/// Safety/vendor/access-denied 预检，`.moveAllToTrash` 也绝不代表绕过 Safety。
public struct ToolTrashExecutionPlan: Sendable, Equatable {
    public let paths: [String]
    public let runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    public let vendorOverrideRequest: VendorPathOverrideRequest?
    public let scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    /// The conflicts the user actually resolved in the confirmation UI.  Keeping
    /// these separate from the display-only skipped rows lets the production
    /// coordinator mint a typed running-app authorization instead of inferring it
    /// from a reduced path array.
    public let confirmedRunningAppConflicts: [RunningAppGuard.Conflict]
    /// Raw strict-confirmation input.  This is not an authorization token: the
    /// production coordinator validates it against the localized expected value
    /// before it can create `DeletionExecutionAuthorization`.
    public let strictConfirmationToken: String?

    public init(paths: [String],
                runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem],
                vendorOverrideRequest: VendorPathOverrideRequest? = nil,
                scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest? = nil,
                confirmedRunningAppConflicts: [RunningAppGuard.Conflict] = [],
                strictConfirmationToken: String? = nil) {
        self.paths = paths
        self.runningAppSkipped = runningAppSkipped
        self.vendorOverrideRequest = vendorOverrideRequest
        self.scanIncompleteOverrideRequest = scanIncompleteOverrideRequest
        self.confirmedRunningAppConflicts = confirmedRunningAppConflicts
        self.strictConfirmationToken = strictConfirmationToken
    }
}

enum ToolTrashExecutionPlanner {
    static func makePlan(
        candidates: [RunningAppGuard.Candidate],
        resolution: RunningAppGuard.Resolution,
        runningApplications: [RunningAppGuard.RunningApplication],
        confirmedConflicts: [RunningAppGuard.Conflict] = [],
        vendorOverrideRequest: VendorPathOverrideRequest? = nil,
        scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest? = nil,
        strictConfirmationToken: String? = nil
    ) -> ToolTrashExecutionPlan {
        let currentConflicts = RunningAppGuard.conflicts(
            candidates: candidates,
            runningApplications: runningApplications
        )
        var conflictsByPath: [String: RunningAppGuard.Conflict] = [:]
        for conflict in confirmedConflicts {
            conflictsByPath[DeletionIntentCandidate.pathIdentity(conflict.path)] = conflict
        }
        for conflict in currentConflicts {
            conflictsByPath[DeletionIntentCandidate.pathIdentity(conflict.path)] = conflict
        }
        let runningPlan = RunningAppGuard.makePlan(
            candidates: candidates,
            runningApplications: runningApplications,
            resolution: resolution,
            confirmedConflicts: confirmedConflicts
        )
        return ToolTrashExecutionPlan(
            paths: runningPlan.candidates.map(\.path),
            runningAppSkipped: runningPlan.skippedConflicts.map {
                OperationResultPayload.RunningAppSkippedItem(
                    path: $0.path,
                    itemTitle: $0.title,
                    appName: $0.runningAppName
                )
            },
            vendorOverrideRequest: vendorOverrideRequest.flatMap {
                $0.restricting(to: runningPlan.candidates.map(\.path))
            },
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest.flatMap {
                $0.restricting(to: runningPlan.candidates.map(\.path))
            },
            confirmedRunningAppConflicts: candidates.compactMap {
                conflictsByPath[DeletionIntentCandidate.pathIdentity($0.path)]
            },
            strictConfirmationToken: strictConfirmationToken
        )
    }
}

/// 普通清理与 Smart Care 共用的执行投影。运行状态在用户确认时重新采样；
/// `.moveAllToTrash` 仅忽略运行中提示，后续仍完整经过 TrashPipeline / SafetyEngine。
public enum DeleteExecutionPlanner {
    public struct Plan: Sendable, Equatable {
        public let rows: [RowItem]
        public let paths: [String]
        public let runningAppSkipped: [RunningAppGuard.Conflict]
        public let runningAppSkippedResultItems: [OperationResultPayload.RunningAppSkippedItem]
        public let dryRun: Bool

        public init(rows: [RowItem],
                    paths: [String]? = nil,
                    runningAppSkipped: [RunningAppGuard.Conflict],
                    dryRun: Bool) {
            self.rows = rows
            self.paths = paths ?? rows.map(\.url.path)
            self.runningAppSkipped = runningAppSkipped
            self.runningAppSkippedResultItems = runningAppSkipped.map {
                OperationResultPayload.RunningAppSkippedItem(
                    path: $0.path,
                    itemTitle: $0.title,
                    appName: $0.runningAppName
                )
            }
            self.dryRun = dryRun
        }
    }

    /// 供确认弹窗直接消费的轻量投影。冲突数组、唯一项计数和最多五个 App 名称
    /// 在同一个后台遍历中完成，避免 SwiftUI body 在 MainActor 上反复扫描大选择集。
    public struct RunningConflictProjection: Sendable, Equatable {
        public let conflicts: [RunningAppGuard.Conflict]
        public let uniquePathCount: Int
        public let appNames: [String]

        public init(conflicts: [RunningAppGuard.Conflict],
                    uniquePathCount: Int,
                    appNames: [String]) {
            self.conflicts = conflicts
            self.uniquePathCount = uniquePathCount
            self.appNames = appNames
        }
    }

    public struct SmartCarePlan: Sendable, Equatable {
        public let execution: Plan
        public let submittedItems: [SmartCareItem]

        public init(execution: Plan, submittedItems: [SmartCareItem]) {
            self.execution = execution
            self.submittedItems = submittedItems
        }
    }

    public static func makePlan(rows: [RowItem],
                                action: DeleteSheetAction) -> Plan {
        switch action {
        case .preview:
            return Plan(rows: rows, runningAppSkipped: [], dryRun: true)
        case .moveToTrash(let resolution, let runningApplications, let confirmedConflicts):
            let runningPlan = RunningAppGuard.makePlan(
                rows: rows,
                runningApplications: runningApplications,
                resolution: resolution,
                confirmedConflicts: confirmedConflicts
            )
            return Plan(
                rows: runningPlan.rows,
                runningAppSkipped: runningPlan.skippedConflicts,
                dryRun: false
            )
        }
    }

    public static func makePlanAsync(rows: [RowItem],
                                     action: DeleteSheetAction) async throws -> Plan {
        try await DeleteExecutionProjectionExecutor.run {
            makePlan(rows: rows, action: action)
        }
    }

    public static func runningConflictProjectionAsync(
        rows: [RowItem],
        runningApplications: [RunningAppGuard.RunningApplication]
    ) async throws -> RunningConflictProjection {
        try await DeleteExecutionProjectionExecutor.run {
            let conflicts = RunningAppGuard.conflicts(
                rows: rows,
                runningApplications: runningApplications
            )
            var uniquePaths = Set<String>()
            var uniqueAppNames = Set<String>()
            var appNames: [String] = []
            uniquePaths.reserveCapacity(conflicts.count)
            appNames.reserveCapacity(min(5, conflicts.count))
            for conflict in conflicts {
                uniquePaths.insert(conflict.path)
                if appNames.count < 5,
                   uniqueAppNames.insert(conflict.runningAppName).inserted {
                    appNames.append(conflict.runningAppName)
                }
            }
            return RunningConflictProjection(
                conflicts: conflicts,
                uniquePathCount: uniquePaths.count,
                appNames: appNames
            )
        }
    }

    static func runningConflictProjectionAsync(
        candidates: [RunningAppGuard.Candidate],
        runningApplications: [RunningAppGuard.RunningApplication]
    ) async throws -> RunningConflictProjection {
        try await DeleteExecutionProjectionExecutor.run {
            let conflicts = RunningAppGuard.conflicts(
                candidates: candidates,
                runningApplications: runningApplications
            )
            var uniquePaths = Set<String>()
            var uniqueAppNames = Set<String>()
            var appNames: [String] = []
            uniquePaths.reserveCapacity(conflicts.count)
            appNames.reserveCapacity(min(5, conflicts.count))
            for conflict in conflicts {
                uniquePaths.insert(conflict.path)
                if appNames.count < 5,
                   uniqueAppNames.insert(conflict.runningAppName).inserted {
                    appNames.append(conflict.runningAppName)
                }
            }
            return RunningConflictProjection(
                conflicts: conflicts,
                uniquePathCount: uniquePaths.count,
                appNames: appNames
            )
        }
    }

    public static func makeSmartCarePlanAsync(request: SmartCareCleanRequest,
                                              action: DeleteSheetAction) async throws -> SmartCarePlan {
        try await DeleteExecutionProjectionExecutor.run {
            let execution = makePlan(rows: request.previewRows, action: action)
            let submittedPathSet = Set(execution.paths)
            let submittedItems = request.items.filter { submittedPathSet.contains($0.path) }
            return SmartCarePlan(execution: execution, submittedItems: submittedItems)
        }
    }
}

/// 删除投影是纯 CPU 工作；大选择集必须离开 MainActor，同时保持父任务取消语义。
private enum DeleteExecutionProjectionExecutor {
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            do {
                let value = try await worker.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }
}
