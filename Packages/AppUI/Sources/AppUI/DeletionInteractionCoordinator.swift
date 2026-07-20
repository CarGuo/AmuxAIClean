import Foundation
import ScanKit
import SafetyKit

/// Immutable metadata accepted by the shared deletion coordinator.
///
/// Tool views may describe size and presentation facts, but they do not decide
/// safety.  Every snapshot starts as an ordinary candidate and the production
/// `DeletionPipeline.preflight` result is the only input that can classify it as
/// normal, strict-override eligible, or non-bypassable.
struct DeletionInteractionCandidateSnapshot: Sendable, Equatable {
    let path: String
    let title: String
    let titlePresentation: LocalizedTextDescriptor
    let isDirectory: Bool
    let bytes: Int64
    let fileCount: Int
    let runningBundleIDPrefix: String?
    let accessEvidence: DeletionAccessEvidence
    let sourceObjectIdentity: TrashObjectIdentity?

    init(
        path: String,
        title: String,
        isDirectory: Bool,
        bytes: Int64,
        fileCount: Int,
        runningBundleIDPrefix: String? = nil,
        accessEvidence: DeletionAccessEvidence = .complete,
        sourceObjectIdentity: TrashObjectIdentity? = nil,
        titlePresentation: LocalizedTextDescriptor? = nil
    ) {
        self.path = path
        self.title = title
        self.titlePresentation = titlePresentation ?? .verbatim(title)
        self.isDirectory = isDirectory
        self.bytes = max(0, bytes)
        self.fileCount = max(0, fileCount)
        self.runningBundleIDPrefix = runningBundleIDPrefix
        self.accessEvidence = accessEvidence
        self.sourceObjectIdentity = sourceObjectIdentity
    }

    fileprivate var intentCandidate: DeletionIntentCandidate {
        DeletionIntentCandidate(
            path: path,
            title: title,
            isDirectory: isDirectory,
            bytes: bytes,
            fileCount: fileCount,
            verdict: .safe,
            rejection: .ok,
            accessEvidence: accessEvidence,
            runningBundleIDPrefix: runningBundleIDPrefix,
            sourceObjectIdentity: sourceObjectIdentity,
            titlePresentation: titlePresentation
        )
    }
}

/// The only input a compact/strict Professional confirmation view may consume.
/// It binds presentation back to the exact typed plan created by production
/// preflight; views never infer override eligibility from strings or booleans.
struct DeletionPreparedInteraction: Sendable, Equatable {
    let plan: DeletionConfirmationPlan
    let vendorOverrideRequest: VendorPathOverrideRequest?
    let scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    let carriedRunningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]

    var confirmationCandidates: [RunningAppGuard.Candidate] {
        plan.submittableItems.map { item in
            RunningAppGuard.Candidate(
                path: item.candidate.rawPath,
                title: item.candidate.title,
                bundleIDPrefix: item.candidate.runningBundleIDPrefix,
                titlePresentation: item.candidate.titlePresentation
            )
        }
    }

    var paths: [String] { confirmationCandidates.map(\.path) }
}

struct DeletionInteractionBlock: Sendable, Equatable {
    let intentID: UUID
    let rejections: [DeletionPreflight.Rejection]
}

enum DeletionInteractionPreparation: Sendable, Equatable {
    case confirmation(DeletionPreparedInteraction)
    case blocked(DeletionInteractionBlock)
    case cancelled(intentID: UUID)
}

struct DeletionAuthorizedInteraction: Sendable, Equatable {
    let prepared: DeletionPreparedInteraction
    let authorization: DeletionExecutionAuthorization
    let vendorOverrideRequest: VendorPathOverrideRequest?
    let scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    let runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
}

enum DeletionInteractionAuthorizationDecision: Sendable, Equatable {
    case authorized(DeletionAuthorizedInteraction)
    case blocked(DeletionInteractionBlock)
    /// A legitimate no-op after the user chose to skip every running item.
    /// It crosses neither the submission boundary nor the result boundary.
    case cancelled(intentID: UUID)
}

struct DeletionCompletedInteraction: Sendable {
    let receipt: DeletionSubmissionReceipt
    let trashSubmission: TrashActionCoordinator.CompletedSubmission
    let runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]

    var result: TrashActionCoordinator.Result { trashSubmission.result }
    var submissionState: DeletionSubmissionState { .submitted(receipt) }

    fileprivate init(
        receipt: DeletionSubmissionReceipt,
        trashSubmission: TrashActionCoordinator.CompletedSubmission,
        runningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    ) {
        self.receipt = receipt
        self.trashSubmission = trashSubmission
        self.runningAppSkipped = runningAppSkipped
    }
}

enum DeletionInteractionSubmission {
    case requiresConfirmation(DeletionPreparedInteraction)
    case blocked(DeletionInteractionBlock)
    case completed(DeletionCompletedInteraction)
}

/// Production adapter for the deletion interaction contract.
///
/// The coordinator is deliberately the only type that performs all five
/// transitions:
///
/// `DeletionIntent -> DeletionConfirmationPlan -> ExecutionAuthorization ->`
/// `typed Trash submission -> DeletionSubmissionReceipt + TrashOutcome`.
///
/// A pre-submit rejection has no result-bearing case, so a caller cannot turn a
/// safety explanation into `Cleanup Failed 0/N` by accident.
@MainActor
struct DeletionInteractionCoordinator {
    let pipeline: any DeletionPipeline
    let undoHistoryStore: UndoHistoryStore

    init(
        pipeline: any DeletionPipeline,
        // v2026.07.20: Keep the persistent Undo owner explicit. Compatibility pipelines can
        // return moved pairs without a durable journal capability, so a hidden `.shared`
        // default let tests contaminate production Application Support.
        undoHistoryStore: UndoHistoryStore
    ) {
        self.pipeline = pipeline
        self.undoHistoryStore = undoHistoryStore
    }

    func makeIntent(
        origin: DeleteRequestOrigin,
        mode: DeletionUserMode,
        snapshotIdentity: DeletionSnapshotIdentity,
        candidates: [DeletionInteractionCandidateSnapshot],
        executionVerification: DeletionExecutionVerification? = nil
    ) throws -> DeletionIntent {
        try DeletionIntent(
            origin: origin,
            mode: mode,
            snapshotIdentity: snapshotIdentity,
            candidates: candidates.map(\.intentCandidate),
            executionVerification: executionVerification
        )
    }

    func prepare(
        intent: DeletionIntent,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        accessDeniedPaths: Set<String> = []
    ) async -> DeletionInteractionPreparation {
        let preflight = await pipeline.preflight(
            paths: intent.candidates.map(\.rawPath),
            accessDeniedPaths: accessDeniedPaths
        )
        return preparation(
            intent: intent,
            preflight: preflight,
            currentSnapshotIdentity: currentSnapshotIdentity,
            carriedRunningAppSkipped: []
        )
    }

    /// Consumes the typed target-revalidation capability without downgrading it
    /// back to an ordinary preflight. The request must cover the exact frozen
    /// intent and the same scan session; otherwise the interaction is blocked.
    func prepareRevalidatedScanIncomplete(
        intent: DeletionIntent,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        preparation: ScanIncompleteOverridePreparation
    ) -> DeletionInteractionPreparation {
        switch preparation {
        case .blocked(let rejections):
            return .blocked(DeletionInteractionBlock(
                intentID: intent.id,
                rejections: rejections.isEmpty
                    ? invariantBlock(intent: intent).rejections
                    : rejections
            ))

        case .strictConfirmation(let scanRequest, let vendorRequest):
            let intentPaths = intent.candidates.map(\.standardizedPath)
            let scanPaths = normalizedPaths(scanRequest.paths)
            guard currentSnapshotIdentity == intent.snapshotIdentity,
                  scanRequest.scanSessionID == intent.snapshotIdentity.sessionID,
                  scanPaths == intentPaths,
                  Set(scanPaths).count == scanPaths.count,
                  vendorRequest == nil || normalizedPaths(vendorRequest?.paths ?? []) == intentPaths,
                  scanRequest.entries.contains(where: { !$0.incompleteIssues.isEmpty }) else {
                return .blocked(invariantBlock(intent: intent))
            }

            let scanEntryByPath = Dictionary(uniqueKeysWithValues: scanRequest.entries.map {
                (DeletionIntentCandidate.pathIdentity($0.path), $0)
            })
            let vendorProtected = Set(
                vendorRequest?.vendorRuleProtectedPaths.map(
                    DeletionIntentCandidate.pathIdentity
                ) ?? []
            )
            let items = intent.candidates.map { candidate -> DeletionConfirmationItem in
                guard let entry = scanEntryByPath[candidate.standardizedPath] else {
                    return DeletionConfirmationItem(
                        candidate: candidate,
                        disposition: .nonBypassable(.missingPreflightDecision)
                    )
                }
                if let issue = entry.incompleteIssues.first {
                    return DeletionConfirmationItem(
                        candidate: candidate,
                        disposition: .strictOverride(.scanIncomplete(
                            DeletionIncompleteReason(scanIncompleteReason: issue.reason)
                        ))
                    )
                }
                if vendorProtected.contains(candidate.standardizedPath) {
                    return DeletionConfirmationItem(
                        candidate: candidate,
                        disposition: .strictOverride(.vendorPathRule)
                    )
                }
                return DeletionConfirmationItem(candidate: candidate, disposition: .normal)
            }
            do {
                let plan = try DeletionConfirmationPlan(intent: intent, items: items)
                guard plan.nonBypassableItems.isEmpty else {
                    return .blocked(invariantBlock(intent: intent))
                }
                return .confirmation(DeletionPreparedInteraction(
                    plan: plan,
                    vendorOverrideRequest: vendorRequest,
                    scanIncompleteOverrideRequest: scanRequest,
                    carriedRunningAppSkipped: []
                ))
            } catch {
                assertionFailure("Scan-incomplete preparation invariant failed: \(error)")
                return .blocked(invariantBlock(intent: intent))
            }
        }
    }

    /// Mints request-scoped authorization from the exact prepared plan and the
    /// compact sheet's frozen decision.  The sheet can propose paths; it cannot
    /// create capability or validate its own strict token.
    func authorize(
        prepared: DeletionPreparedInteraction,
        executionPlan: ToolTrashExecutionPlan
    ) -> DeletionInteractionAuthorizationDecision {
        let intent = prepared.plan.intent
        let candidateByPath = Dictionary(
            uniqueKeysWithValues: intent.candidates.map { ($0.standardizedPath, $0) }
        )
        let submittedPaths = executionPlan.paths.map(DeletionIntentCandidate.pathIdentity)
        let skippedPaths = executionPlan.runningAppSkipped.map {
            DeletionIntentCandidate.pathIdentity($0.path)
        }
        let originalPaths = intent.candidates.map(\.standardizedPath)

        guard Set(submittedPaths).count == submittedPaths.count,
              Set(skippedPaths).count == skippedPaths.count,
              Set(submittedPaths).isDisjoint(with: Set(skippedPaths)),
              Set(submittedPaths).union(skippedPaths) == Set(originalPaths),
              submittedPaths.allSatisfy({ candidateByPath[$0] != nil }) else {
            return .blocked(invariantBlock(intent: intent))
        }

        let expectedOverride = prepared.vendorOverrideRequest.flatMap {
            $0.restricting(to: executionPlan.paths)
        }
        guard expectedOverride == executionPlan.vendorOverrideRequest else {
            return .blocked(invariantBlock(intent: intent))
        }
        let expectedScanOverride = prepared.scanIncompleteOverrideRequest.flatMap {
            $0.restricting(to: executionPlan.paths)
        }
        guard expectedScanOverride == executionPlan.scanIncompleteOverrideRequest else {
            return .blocked(invariantBlock(intent: intent))
        }
        guard !submittedPaths.isEmpty else {
            return .cancelled(intentID: intent.id)
        }

        let confirmedConflicts = executionPlan.confirmedRunningAppConflicts
        let conflictPaths = confirmedConflicts.map {
            DeletionIntentCandidate.pathIdentity($0.path)
        }
        guard Set(conflictPaths).count == conflictPaths.count,
              conflictPaths.allSatisfy({ candidateByPath[$0] != nil }) else {
            return .blocked(invariantBlock(intent: intent))
        }

        let runningChoice: DeletionRunningAppChoice
        if confirmedConflicts.isEmpty {
            runningChoice = .noConflicts
        } else if !executionPlan.runningAppSkipped.isEmpty {
            runningChoice = .skipRunningItems
        } else {
            runningChoice = .attemptWhileRunning
        }

        let proof: DeletionConfirmationProof
        if expectedOverride != nil || expectedScanOverride != nil {
            // v2026.07.16：严格确认词是跨语言不变的安全协议值（两份 catalog 均为
            // DELETE），执行边界固定从英文表解析，不能偷偷依赖进程启动语言。
            let expectedToken = AppLocalization.string(
                "delete.vendor_override.token",
                locale: Locale(identifier: "en")
            )
            guard executionPlan.strictConfirmationToken == expectedToken else {
                return .blocked(invariantBlock(intent: intent))
            }
            proof = .professionalStrict(
                confirmationToken: expectedToken,
                confirmedAt: Date()
            )
        } else {
            proof = .standard(confirmedAt: Date())
        }

        do {
            let authorizationPlan = try DeletionConfirmationPlan(
                id: prepared.plan.id,
                intent: intent,
                items: prepared.plan.items,
                runningAppConflicts: confirmedConflicts,
                preparedAt: prepared.plan.preparedAt
            )
            let candidateIDs = submittedPaths.compactMap { candidateByPath[$0]?.id }
            let authorization = try DeletionExecutionAuthorization.make(
                plan: authorizationPlan,
                selectedCandidateIDs: candidateIDs,
                runningAppChoice: runningChoice,
                proof: proof
            )
            return .authorized(DeletionAuthorizedInteraction(
                prepared: prepared,
                authorization: authorization,
                vendorOverrideRequest: expectedOverride,
                scanIncompleteOverrideRequest: expectedScanOverride,
                runningAppSkipped: mergeRunningAppSkipped(
                    prepared.carriedRunningAppSkipped,
                    executionPlan.runningAppSkipped
                )
            ))
        } catch {
            assertionFailure("Deletion authorization invariant failed: \(error)")
            return .blocked(invariantBlock(intent: intent))
        }
    }

    /// Executes one typed authorization.  A receipt is minted only after the
    /// pipeline returns `.recycleCompleted`; strict escalation and all final
    /// revalidation failures remain confirmation/explanation routes.
    // v2026.07.17: carry optional execution progress beside, never instead of, the authorization
    // and typed submission result. Non-Duplicate callers keep the nil/default path unchanged.
    func submit(
        _ confirmed: DeletionAuthorizedInteraction,
        accessDeniedPaths: Set<String>,
        executionProgressObserver: DeletionExecutionProgressObserver? = nil
    ) async -> DeletionInteractionSubmission {
        let authorization = confirmed.authorization
        let intent = confirmed.prepared.plan.intent
        guard authorization.intentID == intent.id,
              authorization.planID == confirmed.prepared.plan.id,
              authorization.snapshotIdentity == intent.snapshotIdentity else {
            return .blocked(invariantBlock(intent: intent))
        }

        // v2026.07.17 Duplicate TOCTOU closure: a Duplicate origin can cross the shared Trash
        // boundary only with full-hash proof frozen into its scan intent. Running-app filtering
        // may narrow targets, so the proof is narrowed by the exact authorization paths.
        let executionVerification: DeletionExecutionVerification?
        switch (intent.origin, intent.executionVerification) {
        case (.duplicate, .some(.duplicate(let request))):
            guard let restricted = request.restricting(to: authorization.paths) else {
                return .blocked(duplicateVerificationBlock(
                    intent: intent,
                    paths: authorization.paths
                ))
            }
            executionVerification = .duplicate(restricted)
        case (.uninstall, .some(.uninstall(let request))):
            guard let restricted = request.restricting(to: authorization.paths) else {
                return .blocked(uninstallVerificationBlock(
                    intent: intent,
                    paths: authorization.paths
                ))
            }
            executionVerification = .uninstall(restricted)
        case (.duplicate, nil):
            return .blocked(duplicateVerificationBlock(
                intent: intent,
                paths: authorization.paths
            ))
        case (.uninstall, nil):
            return .blocked(uninstallVerificationBlock(
                intent: intent,
                paths: authorization.paths
            ))
        case (_, nil):
            executionVerification = nil
        case (_, .some(_)):
            return .blocked(invariantBlock(intent: intent))
        }

        let submission = await TrashActionCoordinator(
            pipeline: pipeline,
            undoHistoryStore: undoHistoryStore
        ).submitConfirmed(
            paths: authorization.paths,
            source: intent.origin.historySource,
            accessDeniedPaths: accessDeniedPaths,
            vendorOverrideRequest: confirmed.vendorOverrideRequest,
            scanIncompleteOverrideRequest: confirmed.scanIncompleteOverrideRequest,
            // v2026.07.16: the persistent pending-operation ledger receives the exact
            // authorization snapshot. A path invalidated after restart cannot be retried by
            // reusing this token; only a newly scanned revision can replace its tombstone.
            reviewIdentity: authorization.snapshotIdentity,
            executionVerification: executionVerification,
            executionProgressObserver: executionProgressObserver
        )

        switch submission {
        case .recycleCompleted(let submission):
            // v2026.07.16：系统回收回调超时后，执行层会停止后续批次。此时真正提交的
            // 路径可以是授权集合的严格子集，但 outcome 必须精确证明 pending 与未提交
            // 的边界；缺失、重叠或越权都 fail closed，不能伪造成完成结果。
            guard submissionAccountsForAuthorization(
                submission,
                authorizedPaths: authorization.paths
            ) else {
                return .blocked(invariantBlock(intent: intent))
            }
            let receipt = DeletionSubmissionReceipt(
                id: submission.receipt.id,
                authorizationID: authorization.id,
                intentID: authorization.intentID,
                submittedPaths: submission.receipt.submittedPaths,
                submittedAt: submission.receipt.submittedAt
            )
            return .completed(DeletionCompletedInteraction(
                receipt: receipt,
                trashSubmission: submission,
                runningAppSkipped: confirmed.runningAppSkipped
            ))

        case .preSubmitRejected(.safety(let preflight)):
            guard confirmed.vendorOverrideRequest == nil,
                  confirmed.scanIncompleteOverrideRequest == nil else {
                return .blocked(block(intent: intent, preflight: preflight))
            }
            let narrowedIntent: DeletionIntent
            do {
                narrowedIntent = try restrictedIntent(
                    intent,
                    paths: authorization.paths
                )
            } catch {
                assertionFailure("Final deletion replan lost frozen candidates: \(error)")
                return .blocked(invariantBlock(intent: intent))
            }
            return switch preparation(
                intent: narrowedIntent,
                preflight: preflight,
                currentSnapshotIdentity: authorization.snapshotIdentity,
                carriedRunningAppSkipped: confirmed.runningAppSkipped
            ) {
            case .confirmation(let prepared):
                .requiresConfirmation(prepared)
            case .blocked(let block):
                .blocked(block)
            case .cancelled:
                .blocked(block(intent: narrowedIntent, preflight: preflight))
            }

        case .preSubmitRejected(.invalidVendorOverride(let preflight)):
            return .blocked(block(intent: intent, preflight: preflight))

        case .preSubmitRejected(.invalidScanIncompleteOverride(let rejections)):
            return .blocked(DeletionInteractionBlock(
                intentID: intent.id,
                rejections: rejections.isEmpty ? invariantBlock(intent: intent).rejections : rejections
            ))

        case .preSubmitRejected(.invalidDuplicateVerification(let rejections)):
            return .blocked(DeletionInteractionBlock(
                intentID: intent.id,
                rejections: rejections.isEmpty
                    ? duplicateVerificationBlock(intent: intent, paths: authorization.paths).rejections
                    : rejections
            ))

        case .preSubmitRejected(.pendingOperation(let rejection)):
            return .blocked(DeletionInteractionBlock(
                intentID: intent.id,
                rejections: rejection.preflightRejections.isEmpty
                    ? invariantBlock(intent: intent).rejections
                    : rejection.preflightRejections
            ))

        case .preSubmitRejected(.emptyRequest),
             .preSubmitRejected(.unsupportedPipeline):
            return .blocked(invariantBlock(intent: intent))
        }
    }

    private func submissionAccountsForAuthorization(
        _ submission: TrashActionCoordinator.CompletedSubmission,
        authorizedPaths: [String]
    ) -> Bool {
        let authorized = normalizedPaths(authorizedPaths)
        let attempted = normalizedPaths(submission.attemptedPaths)
        let authorizedSet = Set(authorized)
        let attemptedSet = Set(attempted)

        guard authorizedSet.count == authorized.count,
              attemptedSet.count == attempted.count,
              !attempted.isEmpty,
              attemptedSet.isSubset(of: authorizedSet) else { return false }

        let hasUnknownBoundary = !(submission.outcome?.pendingPaths.isEmpty ?? true)
            || !(submission.outcome?.submissionUnknownPaths.isEmpty ?? true)
            || !(submission.outcome?.notSubmittedPaths.isEmpty ?? true)
        if attemptedSet == authorizedSet, !hasUnknownBoundary {
            return true
        }

        guard let outcome = submission.outcome else { return false }
        let moved = Set(normalizedPaths(outcome.movedPairs.map(\.originalPath)))
        let failed = Set(normalizedPaths(outcome.failedPaths))
        let pending = Set(normalizedPaths(outcome.pendingPaths))
        let submissionUnknown = Set(normalizedPaths(outcome.submissionUnknownPaths))
        let notSubmitted = Set(normalizedPaths(outcome.notSubmittedPaths))
        guard moved.isDisjoint(with: failed),
              moved.isDisjoint(with: pending),
              moved.isDisjoint(with: submissionUnknown),
              failed.isDisjoint(with: pending),
              failed.isDisjoint(with: submissionUnknown),
              pending.isDisjoint(with: submissionUnknown),
              moved.union(failed).union(pending).union(submissionUnknown) == attemptedSet,
              notSubmitted == authorizedSet.subtracting(attemptedSet) else { return false }
        return true
    }

    private func preparation(
        intent: DeletionIntent,
        preflight: DeletionPreflight,
        currentSnapshotIdentity: DeletionSnapshotIdentity,
        carriedRunningAppSkipped: [OperationResultPayload.RunningAppSkippedItem]
    ) -> DeletionInteractionPreparation {
        do {
            let decision = try DeletionConfirmationPlanner.makeDecision(
                intent: intent,
                preflight: preflight,
                currentSnapshotIdentity: currentSnapshotIdentity
            )
            switch decision {
            case .cancelled(let intentID):
                return .cancelled(intentID: intentID)
            case .requiresConfirmation(let plan):
                guard plan.nonBypassableItems.isEmpty,
                      plan.changedSinceScanItems.isEmpty,
                      !plan.submittableItems.isEmpty else {
                    return .blocked(block(intent: intent, preflight: preflight))
                }
                let overrideRequest: VendorPathOverrideRequest?
                if plan.strictOverrideItems.isEmpty {
                    overrideRequest = nil
                } else {
                    guard let request = VendorPathOverrideRequest(preflight: preflight) else {
                        return .blocked(block(intent: intent, preflight: preflight))
                    }
                    overrideRequest = request
                }
                return .confirmation(DeletionPreparedInteraction(
                    plan: plan,
                    vendorOverrideRequest: overrideRequest,
                    scanIncompleteOverrideRequest: nil,
                    carriedRunningAppSkipped: carriedRunningAppSkipped
                ))
            }
        } catch {
            assertionFailure("Deletion preparation invariant failed: \(error)")
            return .blocked(invariantBlock(intent: intent))
        }
    }

    private func restrictedIntent(
        _ intent: DeletionIntent,
        paths: [String]
    ) throws -> DeletionIntent {
        let selected = Set(paths.map(DeletionIntentCandidate.pathIdentity))
        let restrictedVerification: DeletionExecutionVerification?
        switch intent.executionVerification {
        case .some(.duplicate(let request)):
            guard let restricted = request.restricting(to: paths) else {
                throw DeletionIntentValidationError.invalidExecutionVerification
            }
            restrictedVerification = .duplicate(restricted)
        case .some(.uninstall(let request)):
            guard let restricted = request.restricting(to: paths) else {
                throw DeletionIntentValidationError.invalidExecutionVerification
            }
            restrictedVerification = .uninstall(restricted)
        case .none:
            restrictedVerification = nil
        }
        return try DeletionIntent(
            id: intent.id,
            origin: intent.origin,
            mode: intent.mode,
            snapshotIdentity: intent.snapshotIdentity,
            candidates: intent.candidates.filter { selected.contains($0.standardizedPath) },
            executionVerification: restrictedVerification,
            createdAt: intent.createdAt
        )
    }

    private func duplicateVerificationBlock(
        intent: DeletionIntent,
        paths: [String]
    ) -> DeletionInteractionBlock {
        DeletionInteractionBlock(
            intentID: intent.id,
            rejections: paths.map {
                .init(
                    path: $0,
                    reason: DuplicateDeletionVerificationRejectionReason.invalidEvidence.rawValue
                )
            }
        )
    }

    private func uninstallVerificationBlock(
        intent: DeletionIntent,
        paths: [String]
    ) -> DeletionInteractionBlock {
        DeletionInteractionBlock(
            intentID: intent.id,
            rejections: paths.map {
                .init(path: $0, reason: "uninstallVerification.invalidEvidence")
            }
        )
    }

    private func block(
        intent: DeletionIntent,
        preflight: DeletionPreflight
    ) -> DeletionInteractionBlock {
        guard !preflight.rejections.isEmpty else {
            return invariantBlock(intent: intent)
        }
        return DeletionInteractionBlock(
            intentID: intent.id,
            rejections: preflight.rejections
        )
    }

    private func invariantBlock(intent: DeletionIntent) -> DeletionInteractionBlock {
        DeletionInteractionBlock(
            intentID: intent.id,
            rejections: intent.candidates.map {
                DeletionPreflight.Rejection(
                    path: $0.rawPath,
                    reason: SafetyRejection.preflightCancelled.rawValue
                )
            }
        )
    }

    private func mergeRunningAppSkipped(
        _ lhs: [OperationResultPayload.RunningAppSkippedItem],
        _ rhs: [OperationResultPayload.RunningAppSkippedItem]
    ) -> [OperationResultPayload.RunningAppSkippedItem] {
        var seen = Set<String>()
        return (lhs + rhs).filter {
            seen.insert(DeletionIntentCandidate.pathIdentity($0.path)).inserted
        }
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        paths.map(DeletionIntentCandidate.pathIdentity)
    }

}
