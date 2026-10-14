import SwiftUI
import SafetyKit

/// Confirmation-time safety rejection. This is deliberately not an operation
/// result: no deletion has been submitted when this model is presented.
struct DeletionPreflightNotice: Identifiable, Sendable, Equatable {
    enum Message: String, Sendable, Equatable {
        case rejected = "delete.preflight.message"
        case scanChanged = "delete.preflight.scan_changed"
        case scanInProgress = "delete.preflight.scan_in_progress"
    }

    let id: UUID
    let message: Message
    let rejections: [DeletionPreflight.Rejection]

    init(
        id: UUID = UUID(),
        message: Message = .rejected,
        rejections: [DeletionPreflight.Rejection]
    ) {
        self.id = id
        self.message = message
        self.rejections = rejections
    }
}

/// v2026.10.14: only confirmed success is transient feedback. A rejected request gets a
/// dedicated modal explanation with every affected item; it still cannot mint a recycle receipt.
struct DeletionPreflightNoticeSheet: View {
    let notice: DeletionPreflightNotice
    let onDismiss: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(AppLocalization.string("delete.preflight.title", locale: locale),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)
            Text(AppLocalization.string(notice.message.rawValue, locale: locale))
                .foregroundStyle(.secondary)
            if !notice.rejections.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(notice.rejections.enumerated()), id: \.offset) { _, rejection in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: rejection.path)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(DeletionPreflightReasonPresentation.text(for: rejection.reason, locale: locale))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 300)
            }
            HStack {
                Spacer()
                Button(AppLocalization.string("delete.preflight.dismiss", locale: locale), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .accessibilityIdentifier("delete.preflight.sheet")
        .onExitCommand(perform: onDismiss)
    }
}

extension View {
    func deletionPreflightNoticeSheet(_ notice: Binding<DeletionPreflightNotice?>) -> some View {
        localizedSheet(item: notice) { value in
            DeletionPreflightNoticeSheet(notice: value, onDismiss: { notice.wrappedValue = nil })
        }
    }
}

/// Dedicated pre-submit copy. Operation result reasons intentionally keep their own
/// `op.result.*` namespace because they describe a different lifecycle boundary.
enum DeletionPreflightReasonPresentation {
    static func text(for raw: String, locale: Locale) -> String {
        AppLocalization.string(localizationKey(for: raw), locale: locale)
    }

    static func localizationKey(for raw: String) -> String {
        if let pendingReason = TrashPendingOperationRejection.Reason(rawValue: raw) {
            switch pendingReason {
            case .priorOperationPending:
                return "delete.preflight.reason.busy"
            case .identityChanged, .targetMissing,
                 .duplicateTargetIdentityChanged, .duplicateRetainedReferenceChanged:
                return "delete.preflight.reason.target_changed"
            case .ledgerUnavailable:
                return "delete.preflight.reason.history_unavailable"
            case .submissionQueueExpired:
                return "delete.preflight.reason.queue_expired"
            case .freshReviewRequired:
                return "delete.preflight.reason.review_required"
            case .duplicateVerificationCancelled:
                return "delete.preflight.reason.cancelled"
            }
        }
        if let targetReason = ScanIncompleteTargetRejectionReason(rawValue: raw) {
            switch targetReason {
            case .missingTypedEvidence, .invalidStrictRequest:
                return "delete.preflight.reason.review_required"
            case .identityChanged, .targetMissing, .targetTypeChanged, .symlinkNotEligible:
                return "delete.preflight.reason.target_changed"
            case .parentUnavailable, .posixPermissionDenied, .unclassifiedAccessFailure,
                 .immutable, .readOnlyVolume:
                return "delete.preflight.reason.unavailable"
            }
        }
        if let duplicateReason = DuplicateDeletionVerificationRejectionReason(rawValue: raw) {
            switch duplicateReason {
            case .invalidEvidence:
                return "delete.preflight.reason.review_required"
            case .targetIdentityChanged, .targetContentChanged, .retainedReferenceChanged:
                return "delete.preflight.reason.target_changed"
            case .verificationCancelled:
                return "delete.preflight.reason.cancelled"
            }
        }
        guard let rejection = SafetyRejection(rawValue: raw) else {
            return "delete.preflight.reason.generic"
        }
        switch rejection {
        case .preflightCancelled:
            return "delete.preflight.reason.cancelled"
        case .symbolicLinkResolutionFailed:
            return "delete.preflight.reason.symbolic_link_resolution_failed"
        case .accessDenied:
            return "delete.preflight.reason.access_denied"
        case .batchContainsForbidden:
            return "delete.preflight.reason.batch_atomic"
        case .relativePath, .dotDotInPath, .outsideUserDeletionScope, .rootOrAboveHome,
             .userDocumentsRoot, .hardForbidPrefix, .insideAppBundle, .bundleSystemCritical,
             .bundleDataProtected, .systemVolume, .sensitiveCredential, .vendorPathRule,
             .userWhitelisted:
            return "delete.preflight.reason.protected"
        case .ok:
            return "delete.preflight.reason.generic"
        @unknown default:
            return "delete.preflight.reason.generic"
        }
    }
}

/// One localization boundary for SafetyKit's machine-readable rejection IDs.
/// Raw enum names remain available to structured logs, never to primary UI.
enum DeletionSafetyReasonPresentation {
    private static let genericKey = "op.result.reason.generic"

    /// v2026.07.15：raw reason 永远保持机器语义；用户文案只在当前 View locale 下投影。
    static func text(for raw: String, locale: Locale) -> String {
        let key = localizationKey(for: raw)
        return AppLocalization.string(key, locale: locale)
    }

    /// SafetyKit raw values are machine-readable identifiers, not a fuzzy text
    /// protocol. Only an exact enum value may select a specific user-facing
    /// explanation; malformed and future values deliberately remain generic.
    static func localizationKey(for raw: String) -> String {
        if let pendingReason = TrashPendingOperationRejection.Reason(rawValue: raw) {
            switch pendingReason {
            case .priorOperationPending:
                return "op.result.reason.trash_pending_operation"
            case .identityChanged:
                return "op.result.reason.trash_pending_identity_changed"
            case .targetMissing:
                return "op.result.reason.trash_pending_target_missing"
            case .ledgerUnavailable:
                return "op.result.reason.trash_pending_ledger_unavailable"
            case .submissionQueueExpired:
                return "op.result.reason.trash_submission_queue_expired"
            case .freshReviewRequired:
                return "op.result.reason.trash_pending_fresh_review_required"
            case .duplicateVerificationCancelled:
                return "op.result.reason.preflight_cancelled"
            case .duplicateTargetIdentityChanged:
                return "op.result.reason.target_identity_changed"
            case .duplicateRetainedReferenceChanged:
                return "op.result.reason.target_identity_changed"
            }
        }
        if let targetReason = ScanIncompleteTargetRejectionReason(rawValue: raw) {
            switch targetReason {
            case .missingTypedEvidence, .invalidStrictRequest:
                return "op.result.reason.target_evidence_missing"
            case .identityChanged, .targetMissing, .targetTypeChanged, .symlinkNotEligible:
                return "op.result.reason.target_identity_changed"
            case .parentUnavailable, .posixPermissionDenied, .unclassifiedAccessFailure:
                return "op.result.reason.target_move_unavailable"
            case .immutable:
                return "op.result.reason.target_immutable"
            case .readOnlyVolume:
                return "op.result.reason.target_read_only_volume"
            }
        }
        if let duplicateReason = DuplicateDeletionVerificationRejectionReason(rawValue: raw) {
            switch duplicateReason {
            case .invalidEvidence:
                return "op.result.reason.target_evidence_missing"
            case .targetIdentityChanged, .targetContentChanged, .retainedReferenceChanged:
                return "op.result.reason.target_identity_changed"
            case .verificationCancelled:
                return "op.result.reason.preflight_cancelled"
            }
        }
        guard let rejection = SafetyRejection(rawValue: raw) else {
            return genericKey
        }

        switch rejection {
        case .relativePath, .dotDotInPath, .outsideUserDeletionScope:
            return "op.result.reason.outside_user_scope"
        case .rootOrAboveHome, .userDocumentsRoot:
            return "op.result.reason.user_root"
        case .hardForbidPrefix, .insideAppBundle, .bundleSystemCritical, .bundleDataProtected:
            return "op.result.reason.hard_forbid"
        case .preflightCancelled:
            return "op.result.reason.preflight_cancelled"
        case .symbolicLinkResolutionFailed:
            return "op.result.reason.symbolic_link_resolution_failed"
        case .systemVolume:
            return "op.result.reason.system_volume"
        case .sensitiveCredential:
            return "op.result.reason.sensitive_credential"
        case .vendorPathRule:
            return "op.result.reason.vendor_path_rule"
        case .accessDenied:
            return "op.result.reason.access_denied"
        case .userWhitelisted:
            return "op.result.reason.user_whitelist"
        case .batchContainsForbidden:
            return "op.result.reason.batch_atomic"
        case .ok:
            return genericKey
        @unknown default:
            return genericKey
        }
    }
}
