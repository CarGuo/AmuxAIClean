import SwiftUI
import SafetyKit

/// Confirmation-time safety rejection. This is deliberately not an operation
/// result: no deletion has been submitted when this model is presented.
struct DeletionPreflightNotice: Identifiable, Sendable, Equatable {
    let id: UUID
    let rejections: [DeletionPreflight.Rejection]

    init(id: UUID = UUID(), rejections: [DeletionPreflight.Rejection]) {
        self.id = id
        self.rejections = rejections
    }
}

/// A typed explanation for non-bypassable preflight rejections.
///
/// `OperationResultSheet` is reserved for requests that crossed the actual
/// submission boundary. Keeping this as a separate view prevents a blocked
/// confirmation from being mislabeled as "Cleanup Failed".
struct DeletionPreflightNoticeSheet: View {
    let notice: DeletionPreflightNotice
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("op.result.section.blocked", bundle: .module)
                        .font(.title2.bold())
                    Text("op.result.hint.blocked", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(notice.rejections.enumerated()), id: \.offset) { _, rejection in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rejection.path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(DeletionSafetyReasonPresentation.text(for: rejection.reason))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.07))
                        )
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 300)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "main.delete.result.ok", bundle: .module)) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
    }
}

/// One localization boundary for SafetyKit's machine-readable rejection IDs.
/// Raw enum names remain available to structured logs, never to primary UI.
enum DeletionSafetyReasonPresentation {
    private static let genericKey = "op.result.reason.generic"

    static func text(for raw: String) -> String {
        let key = localizationKey(for: raw)
        return String(localized: String.LocalizationValue(key), bundle: .module)
    }

    /// SafetyKit raw values are machine-readable identifiers, not a fuzzy text
    /// protocol. Only an exact enum value may select a specific user-facing
    /// explanation; malformed and future values deliberately remain generic.
    static func localizationKey(for raw: String) -> String {
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
