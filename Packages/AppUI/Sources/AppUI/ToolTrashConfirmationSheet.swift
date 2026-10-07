import SwiftUI

enum ToolTrashConfirmationProfile: Sendable, Equatable {
    case normal
    case vendorOverride
    case scanIncompleteOverride

    static func resolve(
        hasVendorOverride: Bool,
        hasScanIncompleteOverride: Bool
    ) -> Self {
        // An incomplete scan is the broader uncertainty: when both capabilities
        // are present the sheet still renders both risk rows, while the headline
        // must explain that the selected target could not be fully inspected.
        if hasScanIncompleteOverride { return .scanIncompleteOverride }
        if hasVendorOverride { return .vendorOverride }
        return .normal
    }
}

struct ToolTrashConfirmationCopy: Sendable, Equatable {
    let title: String
    let message: String
}

/// v2026.09.06 SR-03: Normal review consumes the complete plan. Directory file counts and
/// source are frozen review facts, not the number of selected top-level paths.
struct NormalDeletionReviewCopy: Equatable {
    let summary: String
    let source: String

    static func resolve(plan: DeletionConfirmationPlan, locale: Locale) -> Self {
        let files = plan.intent.candidates.reduce(Int64(0)) { total, candidate in
            let addition = total.addingReportingOverflow(Int64(max(0, candidate.fileCount)))
            return addition.overflow ? Int64.max : addition.partialValue
        }
        let bytes = plan.intent.candidates.reduce(Int64(0)) { total, candidate in
            let addition = total.addingReportingOverflow(max(0, candidate.bytes))
            return addition.overflow ? Int64.max : addition.partialValue
        }
        return Self(
            summary: AppLocalization.format(
                "delete.review.summary %lld %lld %@", locale: locale,
                arguments: [Int64(plan.intent.candidates.count), files, AppLocalization.byteCount(bytes, locale: locale)]
            ),
            source: AppLocalization.format(
                "delete.review.source %@", locale: locale,
                arguments: [AppLocalization.string(sourceKey(plan.intent.origin), locale: locale)]
            )
        )
    }

    private static func sourceKey(_ origin: DeleteRequestOrigin) -> String {
        switch origin {
        case .scanSelection: return "delete.review.origin.scan"
        case .tree: return "delete.review.origin.tree"
        case .largeFiles: return "delete.review.origin.large_files"
        case .stash: return "delete.review.origin.stash"
        case .smartCare: return "delete.review.origin.smart_care"
        case .brew: return "delete.review.origin.brew"
        case .duplicate: return "delete.review.origin.duplicate"
        case .uninstall: return "delete.review.origin.uninstall"
        case .workflowFilesystem: return "delete.review.origin.workflow"
        case .storageAnalysis: return "delete.review.origin.storage_analysis"
        }
    }
}

enum ToolTrashConfirmationCopyResolver {
    static func resolve(
        profile: ToolTrashConfirmationProfile,
        itemCount: Int,
        totalBytes: Int64,
        locale: Locale
    ) -> ToolTrashConfirmationCopy {
        let count = Int64(max(0, itemCount))
        switch profile {
        case .normal:
            return ToolTrashConfirmationCopy(
                title: AppLocalization.string("delete.professional.confirm.title", locale: locale),
                message: AppLocalization.format(
                    "delete.professional.confirm.message %lld %@",
                    locale: locale,
                    arguments: [
                        count,
                        AppLocalization.byteCount(totalBytes, locale: locale)
                    ]
                )
            )

        case .vendorOverride:
            return ToolTrashConfirmationCopy(
                title: AppLocalization.string("delete.vendor_override.title", locale: locale),
                message: AppLocalization.format(
                    "delete.vendor_override.body %lld",
                    locale: locale,
                    arguments: [count]
                )
            )

        case .scanIncompleteOverride:
            return ToolTrashConfirmationCopy(
                title: AppLocalization.string("delete.scan_incomplete_override.title", locale: locale),
                message: AppLocalization.format(
                    "delete.scan_incomplete_override.body %lld",
                    locale: locale,
                    arguments: [count]
                )
            )
        }
    }
}

/// Synchronous acceptance rule shared by the confirmation UI and its behavior tests.
///
/// The sheet does not own the deletion intent after dismissal. Therefore it may latch its
/// submitted state only when the caller has synchronously accepted the plan into the caller's
/// one-shot handoff. Returning `false` is not an error terminal state: the sheet stays enabled.
enum ToolTrashConfirmationSubmissionContract {
    static func accepts(
        hasSubmitted: Bool,
        freezeInCallerHandoff: () -> Bool
    ) -> Bool {
        guard !hasSubmitted else { return false }
        return freezeInCallerHandoff()
    }
}

/// 专业模式共用的“移到废纸篓”最终确认页。
///
/// 普通候选只展示简洁 Yes/No；类型化 vendor / scan-incomplete override
/// 才展开风险、路径和输入确认。运行中 App 只会触发“跳过 / 仍尝试全部”的选择；无论选择哪一项，
/// 真正执行时仍会再次经过 TrashPipeline 的 Safety/vendor/access-denied 硬门。
struct ToolTrashConfirmationSheet: View {
    let items: [RunningAppGuard.Candidate]
    let totalBytes: Int64
    let vendorOverrideRequest: VendorPathOverrideRequest?
    let scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest?
    /// v2026.09.06: tools embedded in Normal mode present the frozen, typed review
    /// items. The same coordinator still owns safety and final authorization.
    let reviewPlan: DeletionConfirmationPlan?
    let onCancel: () -> Void
    /// Returns `true` only after the caller has synchronously frozen the plan in its
    /// dismissal handoff. A rejected handoff must leave this sheet interactive so the
    /// user's confirmation is never converted into a disabled no-op.
    let onConfirm: (ToolTrashExecutionPlan) -> Bool

    @Environment(\.locale) private var locale
    @State private var displayedConflictAppNames: [String] = []
    @State private var decisionConflicts: [RunningAppGuard.Conflict] = []
    @State private var decisionAppNames: [String] = []
    @State private var decisionConflictCount = 0
    @State private var showRunningAppDecision = false
    @State private var isResolvingRunningApps = false
    @State private var hasSubmitted = false
    @State private var conflictResolutionTask: Task<Void, Never>?
    @State private var typedConfirmation = ""

    init(items: [RunningAppGuard.Candidate],
         totalBytes: Int64,
         vendorOverrideRequest: VendorPathOverrideRequest? = nil,
         scanIncompleteOverrideRequest: ScanIncompleteOverrideRequest? = nil,
         reviewPlan: DeletionConfirmationPlan? = nil,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (ToolTrashExecutionPlan) -> Bool) {
        self.items = items
        self.totalBytes = max(0, totalBytes)
        self.vendorOverrideRequest = vendorOverrideRequest
        self.scanIncompleteOverrideRequest = scanIncompleteOverrideRequest
        self.reviewPlan = reviewPlan
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var nonConflictingItemCount: Int {
        max(0, items.count - decisionConflictCount)
    }

    private var skipActionTitle: String {
        if nonConflictingItemCount == 0 {
            return AppLocalization.format(
                "delete.running_app.choice.skip_all %lld",
                locale: locale,
                arguments: [decisionConflictCount]
            )
        }
        return AppLocalization.format(
            "delete.running_app.choice.skip %lld %lld",
            locale: locale,
            arguments: [decisionConflictCount, nonConflictingItemCount]
        )
    }

    private var expectedConfirmationToken: String {
        AppLocalization.string("delete.vendor_override.token", locale: locale)
    }

    private var requiresStrictConfirmation: Bool {
        confirmationProfile != .normal
    }

    private var confirmationProfile: ToolTrashConfirmationProfile {
        .resolve(
            hasVendorOverride: vendorOverrideRequest != nil,
            hasScanIncompleteOverride: scanIncompleteOverrideRequest != nil
        )
    }

    private var copy: ToolTrashConfirmationCopy {
        ToolTrashConfirmationCopyResolver.resolve(
            profile: confirmationProfile,
            itemCount: items.count,
            totalBytes: totalBytes,
            locale: locale
        )
    }

    private var typedConfirmationIsValid: Bool {
        !requiresStrictConfirmation || typedConfirmation == expectedConfirmationToken
    }

    private var destructiveActionTitle: String {
        switch confirmationProfile {
        case .vendorOverride:
            return AppLocalization.string("delete.vendor_override.action", locale: locale)
        case .scanIncompleteOverride:
            return AppLocalization.string("delete.scan_incomplete_override.action", locale: locale)
        case .normal:
            return AppLocalization.string("delete.action.confirm", locale: locale)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text(verbatim: reviewPlan == nil ? copy.title : AppLocalization.string("delete.summary.title", locale: locale))
                    .font(.title3.bold())
            }

            if let reviewPlan {
                let reviewCopy = NormalDeletionReviewCopy.resolve(plan: reviewPlan, locale: locale)
                Text(verbatim: reviewCopy.summary)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("delete.review.summary")
                Text(verbatim: reviewCopy.source)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("delete.review.source")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(reviewPlan.items, id: \.candidate.standardizedPath) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.candidate.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: item.candidate.titlePresentation.localized(locale: locale))
                                        .font(.callout.weight(.medium))
                                    Text(verbatim: item.candidate.rawPath)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.middle)
                                    Text(verbatim: AppLocalization.format(
                                        "delete.review.files %lld", locale: locale,
                                        arguments: [Int64(max(0, item.candidate.fileCount))]
                                    ))
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(verbatim: AppLocalization.byteCount(item.candidate.bytes, locale: locale))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }.frame(minHeight: 160, maxHeight: 280)
                Text("workspace.delete.review_note", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(verbatim: copy.message)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if requiresStrictConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        if vendorOverrideRequest != nil {
                            Label {
                                Text("delete.vendor_override.risk", bundle: .module)
                            } icon: {
                                Image(systemName: "exclamationmark.shield.fill")
                            }
                        }
                        if scanIncompleteOverrideRequest != nil {
                            Label {
                                Text("delete.scan_incomplete_override.risk", bundle: .module)
                            } icon: {
                                Image(systemName: "externaldrive.badge.questionmark")
                            }
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)

                    Text(AppLocalization.format(
                        "delete.vendor_override.type_prompt %@",
                        locale: locale,
                        arguments: [expectedConfirmationToken]
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    TextField(
                        AppLocalization.string("delete.vendor_override.field", locale: locale),
                        text: $typedConfirmation
                    )
                    .textFieldStyle(.roundedBorder)
                }
                .padding(10)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            if !displayedConflictAppNames.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("delete.running_app.warning.title", bundle: .module)
                            .font(.callout.weight(.semibold))
                        Text(RunningAppNoticeFormatter.text(
                            localizationKey: "delete.running_app.warning.detail %@",
                            appNames: displayedConflictAppNames,
                            locale: locale
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if requiresStrictConfirmation {
                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            Text(verbatim: item.path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            HStack {
                Spacer()
                if isResolvingRunningApps {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(AppLocalization.string("delete.action.cancel", locale: locale), role: .cancel) {
                    cancelAndClose()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(hasSubmitted)
                if !displayedConflictAppNames.isEmpty && decisionConflictCount > 0 {
                    Button(skipActionTitle) {
                        submitFinalResolution(.skipConflictingItems)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hasSubmitted || isResolvingRunningApps || !typedConfirmationIsValid)

                    Button(role: .destructive) {
                        submitFinalResolution(.moveAllToTrash)
                    } label: {
                        Text("delete.running_app.choice.move_all", bundle: .module)
                    }
                    .disabled(hasSubmitted || isResolvingRunningApps || !typedConfirmationIsValid)
                } else {
                    Button(
                        destructiveActionTitle,
                        role: .destructive
                    ) {
                        resolveCurrentConflicts()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hasSubmitted || isResolvingRunningApps || !typedConfirmationIsValid)
                }
            }
        }
        .padding(20)
        .frame(width: requiresStrictConfirmation || reviewPlan != nil || !displayedConflictAppNames.isEmpty ? 560 : 440)
        .task {
            await refreshDisplayedConflicts()
        }
        .onDisappear {
            conflictResolutionTask?.cancel()
        }
    }

    private func resolveCurrentConflicts() {
        guard !hasSubmitted else { return }
        conflictResolutionTask?.cancel()
        let runningApplications = RunningAppGuard.currentRunningApplications()
        isResolvingRunningApps = true
        conflictResolutionTask = Task { @MainActor in
            do {
                let projection = try await DeleteExecutionPlanner.runningConflictProjectionAsync(
                    candidates: items,
                    runningApplications: runningApplications
                )
                try Task.checkCancellation()
                isResolvingRunningApps = false
                conflictResolutionTask = nil
                guard !projection.conflicts.isEmpty else {
                    submitOnce(ToolTrashExecutionPlanner.makePlan(
                        candidates: items,
                        resolution: .moveAllToTrash,
                        runningApplications: runningApplications,
                        vendorOverrideRequest: vendorOverrideRequest,
                        scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
                        strictConfirmationToken: !requiresStrictConfirmation
                            ? nil
                            : typedConfirmation
                    ))
                    return
                }
                displayedConflictAppNames = projection.appNames
                decisionConflicts = projection.conflicts
                decisionAppNames = projection.appNames
                decisionConflictCount = projection.uniquePathCount
            } catch is CancellationError {
                isResolvingRunningApps = false
            } catch {
                isResolvingRunningApps = false
                assertionFailure("Unexpected tool running-app projection error: \(error)")
            }
        }
    }

    private func submitFinalResolution(_ resolution: RunningAppGuard.Resolution) {
        let runningApplications = RunningAppGuard.currentRunningApplications()
        let plan = ToolTrashExecutionPlanner.makePlan(
            candidates: items,
            resolution: resolution,
            runningApplications: runningApplications,
            confirmedConflicts: decisionConflicts,
            vendorOverrideRequest: vendorOverrideRequest,
            scanIncompleteOverrideRequest: scanIncompleteOverrideRequest,
            strictConfirmationToken: !requiresStrictConfirmation
                ? nil
                : typedConfirmation
        )
        submitOnce(plan)
    }

    private func submitOnce(_ plan: ToolTrashExecutionPlan) {
        guard ToolTrashConfirmationSubmissionContract.accepts(
            hasSubmitted: hasSubmitted,
            freezeInCallerHandoff: { onConfirm(plan) }
        ) else { return }
        hasSubmitted = true
        conflictResolutionTask?.cancel()
    }

    @MainActor
    private func refreshDisplayedConflicts() async {
        let runningApplications = RunningAppGuard.currentRunningApplications()
        do {
            let projection = try await DeleteExecutionPlanner.runningConflictProjectionAsync(
                candidates: items,
                runningApplications: runningApplications
            )
            try Task.checkCancellation()
            displayedConflictAppNames = projection.appNames
            decisionConflicts = projection.conflicts
            decisionAppNames = projection.appNames
            decisionConflictCount = projection.uniquePathCount
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected tool running-app banner projection error: \(error)")
        }
    }

    private func cancelAndClose() {
        guard !hasSubmitted else { return }
        conflictResolutionTask?.cancel()
        onCancel()
    }
}
