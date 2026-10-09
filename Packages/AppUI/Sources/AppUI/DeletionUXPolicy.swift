import Foundation
import SafetyKit

/// Release 构建只向用户提供“移到废纸篓”。dry-run 是开发诊断能力，
/// 继续保留在底层管线和 Debug UI 中，但不再泄漏到正式产品流程。
public enum DeletionPreviewPolicy {
    public static let isEnabledInCurrentBuild: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()
}

/// Professional mode shares one preflight state machine but not Normal mode's
/// detailed preview presentation. The route itself is pure and testable so a
/// vendor-only rejection can never regress into a fake operation result.
enum ProfessionalDeletionPreflightRoute: Sendable, Equatable {
    case simpleConfirmation
    case strictConfirmation(VendorPathOverrideRequest)
    case blockedExplanation([DeletionPreflight.Rejection])
}

enum ProfessionalDeletionPreflightRouter {
    static func route(_ preflight: DeletionPreflight) -> ProfessionalDeletionPreflightRoute {
        if preflight.canProceed {
            return .simpleConfirmation
        }
        if let request = VendorPathOverrideRequest(preflight: preflight) {
            return .strictConfirmation(request)
        }
        return .blockedExplanation(preflight.rejections)
    }
}

/// 删除确认期间安全证据只能单调变严格。Sheet 冻结的是用户看过的上下文；真正
/// 提交前还必须与同一扫描会话此刻新增的 denied/incomplete/TCC 证据取并集。
enum DeletionDeniedPathPolicy {
    static func final(
        frozen: Set<String>,
        current: Set<String>
    ) -> Set<String> {
        frozen.union(current)
    }
}

/// 统一确认模型使用的专业覆盖资格判定。它只描述“下一步需要什么”，不会铸造
/// `VendorPathOverrideRequest`，也不会放宽 TrashPipeline 的最终边界。
public enum ProfessionalOverridePolicy {
    public static func eligibility(
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        accessEvidence: DeletionAccessEvidence,
        mode: DeletionUserMode
    ) -> ProfessionalOverrideEligibility {
        if case .incomplete(let reason) = accessEvidence {
            let overrideReason = ProfessionalOverrideReason.scanIncomplete(reason)
            return mode == .professional
                ? .requiresTargetRevalidation(overrideReason)
                : .requiresProfessionalMode(overrideReason)
        }

        guard verdict == .forbid else { return .notRequired }
        switch rejection {
        case .vendorPathRule:
            return mode == .professional
                ? .eligible(.vendorPathRule)
                : .requiresProfessionalMode(.vendorPathRule)
        case .accessDenied:
            // 当前 preflight 仍把 permission/TCC/incomplete 聚合为 accessDenied。
            // 在证据拆分前只能要求目标级重验，绝不能把它直接当作可执行授权。
            let overrideReason = ProfessionalOverrideReason.scanIncomplete(.unspecified)
            return mode == .professional
                ? .requiresTargetRevalidation(overrideReason)
                : .requiresProfessionalMode(overrideReason)
        case .relativePath,
             .dotDotInPath,
             .symbolicLinkResolutionFailed,
             .rootOrAboveHome,
             .outsideUserDeletionScope,
             .preflightCancelled,
             .hardForbidPrefix,
             .userDocumentsRoot,
             .systemVolume,
             .insideAppBundle,
             .sensitiveCredential,
             .userWhitelisted,
             .batchContainsForbidden,
             .bundleSystemCritical,
             .bundleDataProtected,
             .ok:
            return .nonBypassable(rejection)
        }
    }
}

/// 把独立目标级重验收敛成一个 fail-closed 决策。这里同时消费扫描快照与当前安全
/// 结果，安全证据只会单调增加：旧 hard-forbid 不会因为新一次评估返回 safe 而消失。
///
/// 本策略不探测文件系统、不铸造执行授权，也不调用删除 API；证据必须由后续统一的
/// target revalidator 产生，再由确认协调器消费。
enum DeletionTargetRevalidationPolicy {
    private enum SafetyRequirement {
        case ordinary
        case vendorStrict
        case typedScanEvidence
        case prohibited(SafetyRejection)
        case inconsistent
    }

    static func decision(
        for candidate: DeletionIntentCandidate,
        evidence: DeletionTargetRevalidationEvidence,
        mode: DeletionUserMode
    ) -> DeletionTargetRevalidationDecision {
        guard evidence.candidateID == candidate.id else {
            return .prohibited(.evidenceBoundToDifferentCandidate)
        }
        guard evidence.standardizedPath == candidate.standardizedPath else {
            return .prohibited(.evidenceBoundToDifferentPath)
        }

        switch evidence.identity {
        case .matchesSnapshot:
            break
        case .changed:
            return .prohibited(.identityChanged)
        case .missing:
            return .prohibited(.targetMissing)
        case .unavailable:
            return .prohibited(.identityUnavailable)
        }

        var strictReasons: [DeletionTargetStrictAttemptReason] = []
        var requiresTypedScanEvidence = false

        let safetyPairs = [
            (candidate.verdict, candidate.rejection),
            (evidence.currentVerdict, evidence.currentRejection)
        ]
        for (verdict, rejection) in safetyPairs {
            switch safetyRequirement(verdict: verdict, rejection: rejection) {
            case .ordinary:
                break
            case .vendorStrict:
                appendUnique(.vendorPathRule, to: &strictReasons)
            case .typedScanEvidence:
                requiresTypedScanEvidence = true
            case .prohibited(let reason):
                return .prohibited(.safety(reason))
            case .inconsistent:
                return .prohibited(.inconsistentSafetyEvidence(verdict, rejection))
            }
        }

        if case .incomplete = candidate.accessEvidence {
            requiresTypedScanEvidence = true
        }

        switch evidence.scanEvidence {
        case .complete:
            guard !requiresTypedScanEvidence else {
                return .prohibited(.incompleteEvidenceNotCarriedForward)
            }
        case .unavailable:
            return .prohibited(.scanEvidenceUnavailable)
        case .incomplete(let issues):
            guard !issues.isEmpty else {
                return .prohibited(.emptyIncompleteEvidence)
            }
            for issue in issues {
                guard issue.reason != .unspecified else {
                    return .prohibited(.unresolvedIncompleteReason)
                }
                appendUnique(.scanIncomplete(issue), to: &strictReasons)
            }
        }

        switch evidence.moveAttempt {
        case .eligibleForAttempt:
            break
        case .denied(let reason):
            return .prohibited(.moveDenied(reason))
        case .unavailable:
            return .prohibited(.moveCapabilityUnavailable)
        }

        guard !strictReasons.isEmpty else { return .ordinaryAllow }
        guard mode == .professional else {
            return .prohibited(.requiresProfessionalMode)
        }
        return .strictAttempt(DeletionTargetStrictAttempt(reasons: strictReasons))
    }

    /// 只接受一致的 `(verdict, rejection)` 对；避免 `.safe + hardForbidPrefix` 这类
    /// 上游状态错误被当成普通允许。实际边界分类仍复用 ProfessionalOverridePolicy，
    /// 防止此处维护第二份 hard-forbid 清单。
    private static func safetyRequirement(
        verdict: SafetyVerdict,
        rejection: SafetyRejection
    ) -> SafetyRequirement {
        if verdict != .forbid {
            return rejection == .ok ? .ordinary : .inconsistent
        }
        guard rejection != .ok else { return .inconsistent }

        switch ProfessionalOverridePolicy.eligibility(
            verdict: verdict,
            rejection: rejection,
            accessEvidence: .complete,
            mode: .professional
        ) {
        case .notRequired:
            return .inconsistent
        case .eligible(.vendorPathRule):
            return .vendorStrict
        case .eligible(.scanIncomplete):
            return .typedScanEvidence
        case .requiresTargetRevalidation:
            return .typedScanEvidence
        case .requiresProfessionalMode:
            return .inconsistent
        case .nonBypassable(let reason):
            return .prohibited(reason)
        }
    }

    private static func appendUnique(
        _ reason: DeletionTargetStrictAttemptReason,
        to reasons: inout [DeletionTargetStrictAttemptReason]
    ) {
        guard !reasons.contains(reason) else { return }
        reasons.append(reason)
    }
}

/// 把一次生产预检投影成唯一确认计划。拒绝项仍是 plan item；这里没有也不能返回
/// `OperationResultPayload`。执行结果只能在用户确认并实际提交之后产生。
public enum DeletionConfirmationPlanner {
    public static func makePlan(
        intent: DeletionIntent,
        preflight: DeletionPreflight,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        runningAppConflicts: [RunningAppGuard.Conflict] = []
    ) throws -> DeletionConfirmationPlan {
        guard currentSnapshotIdentity == intent.snapshotIdentity else {
            return try DeletionConfirmationPlan(
                intent: intent,
                items: intent.candidates.map {
                    DeletionConfirmationItem(candidate: $0, disposition: .changedSinceScan)
                }
            )
        }

        let allowedPaths = Set(preflight.allowedPaths.map(DeletionIntentCandidate.pathIdentity))
        let vendorEligiblePaths = Set(
            preflight.vendorOverrideEligiblePaths.map(DeletionIntentCandidate.pathIdentity)
        )
        var rejectionByPath: [String: String] = [:]
        for rejection in preflight.rejections {
            let path = DeletionIntentCandidate.pathIdentity(rejection.path)
            // 重复路径本身违反预检身份合同；保留第一次（通常是直接原因）并 fail closed。
            if rejectionByPath[path] == nil {
                rejectionByPath[path] = rejection.reason
            }
        }

        let items = intent.candidates.map { candidate -> DeletionConfirmationItem in
            let path = candidate.standardizedPath
            if vendorEligiblePaths.contains(path) {
                // 生产 preflight 的 typed vendor request 会覆盖整个原子批，但只有直接
                // vendorPathRule 项需要专业风险授权；batchContainsForbidden 的安全同批项
                // 仍属于 normal，避免把“能力请求包含它”误写成“它本身是 vendor 风险”。
                if rejectionByPath[path] == SafetyRejection.batchContainsForbidden.rawValue {
                    let eligibility = ProfessionalOverridePolicy.eligibility(
                        verdict: candidate.verdict,
                        rejection: candidate.rejection,
                        accessEvidence: candidate.accessEvidence,
                        mode: intent.mode
                    )
                    return DeletionConfirmationItem(
                        candidate: candidate,
                        disposition: disposition(for: eligibility)
                    )
                }
                let eligibility = ProfessionalOverridePolicy.eligibility(
                    verdict: .forbid,
                    rejection: .vendorPathRule,
                    accessEvidence: candidate.accessEvidence,
                    mode: intent.mode
                )
                return DeletionConfirmationItem(
                    candidate: candidate,
                    disposition: disposition(for: eligibility)
                )
            }

            if let rawReason = rejectionByPath[path] {
                guard let rejection = SafetyRejection(rawValue: rawReason) else {
                    return DeletionConfirmationItem(
                        candidate: candidate,
                        disposition: .nonBypassable(.unrecognizedPreflightReason(rawReason))
                    )
                }
                let eligibility = ProfessionalOverridePolicy.eligibility(
                    verdict: .forbid,
                    rejection: rejection,
                    accessEvidence: candidate.accessEvidence,
                    mode: intent.mode
                )
                return DeletionConfirmationItem(
                    candidate: candidate,
                    disposition: disposition(for: eligibility)
                )
            }

            if allowedPaths.contains(path) {
                let eligibility = ProfessionalOverridePolicy.eligibility(
                    verdict: candidate.verdict,
                    rejection: candidate.rejection,
                    accessEvidence: candidate.accessEvidence,
                    mode: intent.mode
                )
                return DeletionConfirmationItem(
                    candidate: candidate,
                    disposition: disposition(for: eligibility)
                )
            }

            return DeletionConfirmationItem(
                candidate: candidate,
                disposition: .nonBypassable(.missingPreflightDecision)
            )
        }
        return try DeletionConfirmationPlan(
            intent: intent,
            items: items,
            runningAppConflicts: runningAppConflicts
        )
    }

    public static func makeDecision(
        intent: DeletionIntent,
        preflight: DeletionPreflight,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        runningAppConflicts: [RunningAppGuard.Conflict] = []
    ) throws -> DeletionPreparationDecision {
        let parsedReasons = preflight.rejections.compactMap {
            SafetyRejection(rawValue: $0.reason)
        }
        if !preflight.rejections.isEmpty,
           parsedReasons.count == preflight.rejections.count,
           parsedReasons.allSatisfy({ $0 == .preflightCancelled }) {
            return .cancelled(intentID: intent.id)
        }
        return .requiresConfirmation(try makePlan(
            intent: intent,
            preflight: preflight,
            currentSnapshotIdentity: currentSnapshotIdentity,
            runningAppConflicts: runningAppConflicts
        ))
    }

    private static func disposition(
        for eligibility: ProfessionalOverrideEligibility
    ) -> DeletionConfirmationDisposition {
        switch eligibility {
        case .notRequired:
            return .normal
        case .eligible(let reason):
            return .strictOverride(reason)
        case .requiresProfessionalMode(let reason):
            return .nonBypassable(.requiresProfessionalMode(reason))
        case .requiresTargetRevalidation(let reason):
            return .nonBypassable(.requiresTargetRevalidation(reason))
        case .nonBypassable(let reason):
            return .nonBypassable(.safety(reason))
        }
    }
}

/// 删除 UI 的入口资格策略。
///
/// 这层只决定“用户能否发起预检”，不授予文件系统删除权限。真正执行仍必须经过
/// `TrashPipeline.preflight`、严格确认词和执行前最终重验。
///
/// 专业模式唯一额外开放的是 `.vendorPathRule`：它表示 vendors 规则声明的 SDK / 工具链
/// 风险路径，专业用户可以在看清风险后继续。系统根、凭据、受保护 bundle、白名单、
/// accessDenied / incomplete 等其它边界不会因为 UI 模式而降级。
public enum DeletionEntryPolicy {
    public static func canInitiate(
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        hasCompleteAccessEvidence: Bool = true,
        allowsTargetRevalidation: Bool = false,
        allowsVendorPathOverride: Bool
    ) -> Bool {
        // Incomplete evidence may open only the Professional target-revalidation flow. This
        // method still grants no deletion capability; ordinary/Normal callers keep the default
        // false and remain locked exactly as before.
        guard hasCompleteAccessEvidence || allowsTargetRevalidation else { return false }
        switch verdict {
        case .safe, .confirm:
            return true
        case .forbid:
            return allowsVendorPathOverride && rejection == .vendorPathRule
        }
    }

    public static func requiresVendorPathOverride(
        verdict: SafetyVerdict,
        rejection: SafetyRejection,
        allowsVendorPathOverride: Bool
    ) -> Bool {
        verdict == .forbid
            && rejection == .vendorPathRule
            && allowsVendorPathOverride
    }
}
