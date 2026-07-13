import AIKit
import SafetyKit
import SwiftUI

/// Stable, UI-only projection of one Smart Care AI review run.
///
/// Keeping this projection separate from the session actor prevents a sheet redraw from
/// observing a half-mutated run. A presentation is immutable; the only mutable state here is
/// the user's explicit, not-yet-applied selection proposal.
struct SmartCareAIReviewResultPresentation: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case empty
        case success
        case partial
        case failed
        case cancelled
        case stale
    }

    struct Row: Identifiable, Equatable, Sendable {
        enum Result: Equatable, Sendable {
            case success(AIAdvice)
            case failure(kind: SmartCareAIReviewFailure.Kind, httpStatus: Int?)
            case pending
        }

        let id: String
        let path: String
        let title: String
        let bytes: Int64
        let localVerdict: SafetyVerdict
        let selectedAtStart: Bool
        let currentSelected: Bool
        let result: Result

        init(
            id: String,
            path: String,
            title: String,
            bytes: Int64,
            localVerdict: SafetyVerdict,
            selectedAtStart: Bool,
            currentSelected: Bool,
            result: Result
        ) {
            self.id = id
            self.path = path
            self.title = title
            self.bytes = bytes
            self.localVerdict = localVerdict
            self.selectedAtStart = selectedAtStart
            self.currentSelected = currentSelected
            self.result = result
        }
    }

    let status: Status
    let rows: [Row]
    let requestedCount: Int
    let succeededCount: Int
    let failedCount: Int
    let completedCount: Int
    let remainingCount: Int
    let safeAdviceCount: Int
    let confirmAdviceCount: Int
    let forbidAdviceCount: Int
    let summaryRevision: UInt64
    let globalFailureKind: SmartCareAIReviewFailure.Kind?
    let globalFailureHTTPStatus: Int?
    let settingsRecommended: Bool
    let retryAvailable: Bool
    let retryIncludesRemaining: Bool
    let selectedOutsideReviewCount: Int
    let canReviewCleanup: Bool

    init(
        report: SmartCareAIReviewReport,
        currentSelectedItemIDs: Set<SmartCareItem.ID>
    ) {
        self.status = switch report.status {
        case .empty: .empty
        case .success: .success
        case .partial: .partial
        case .failed: .failed
        case .cancelled: .cancelled
        case .stale: .stale
        }
        self.rows = report.items.map { outcome in
            let result: Row.Result = switch outcome.result {
            case .advice(let advice): .success(advice)
            case .failure(let failure): .failure(
                kind: failure.kind,
                httpStatus: failure.httpStatus
            )
            case .notReviewed: .pending
            }
            return Row(
                id: outcome.id,
                path: outcome.path,
                title: outcome.item.title,
                bytes: outcome.item.bytes,
                localVerdict: outcome.localVerdict,
                selectedAtStart: outcome.selectedAtStart,
                currentSelected: currentSelectedItemIDs.contains(outcome.item.id),
                result: result
            )
        }
        self.requestedCount = report.requestedCount
        self.succeededCount = report.succeededCount
        self.failedCount = report.failedCount
        self.completedCount = min(report.requestedCount, report.succeededCount + report.failedCount)
        // run-level 预检失败不等于每个 item 已经处理失败；尚未发起的条目继续归入 remaining。
        self.remainingCount = report.remainingCount
        self.safeAdviceCount = report.safeAdviceCount
        self.confirmAdviceCount = report.confirmAdviceCount
        self.forbidAdviceCount = report.forbidAdviceCount
        self.summaryRevision = report.sourceSummaryRevision
        self.globalFailureKind = report.globalFailure?.kind
        self.globalFailureHTTPStatus = report.globalFailure?.httpStatus
        self.settingsRecommended = report.globalFailure?.shouldOpenSettings == true
            || report.items.contains(where: { $0.failure?.shouldOpenSettings == true })
        // “可恢复入口”与本次错误是否适合原样瞬时重试是两件事。配置/鉴权
        // 错误在用户修好 Settings 后也必须能回到报告，只重试未解决目标。
        self.retryAvailable = report.globalFailure != nil
            ? report.items.contains(where: { $0.failure != nil || $0.isNotReviewed })
            : report.items.contains(where: { $0.failure != nil })
        self.retryIncludesRemaining = report.globalFailure != nil && report.remainingCount > 0
        let reviewedIDs = Set(report.items.map(\.id))
        let selectedOutsideReviewCount = currentSelectedItemIDs.subtracting(reviewedIDs).count
        self.selectedOutsideReviewCount = selectedOutsideReviewCount
        self.canReviewCleanup = selectedOutsideReviewCount > 0
            || report.items.contains { currentSelectedItemIDs.contains($0.id) }
    }

    func hasCleanupSelection(proposedSelectionByPath: [String: Bool]) -> Bool {
        if selectedOutsideReviewCount > 0 { return true }
        return rows.contains { row in
            proposedSelectionByPath[row.path] ?? row.currentSelected
        }
    }

}

/// Complete result surface for a Normal-mode AI review.
///
/// Safety contract:
/// - AI results never mutate selection while this sheet is presented.
/// - Only `onApplySelectionChanges` receives a user-confirmed diff.
/// - Locally forbidden rows are immutable regardless of the AI verdict.
struct SmartCareAIReviewResultSheet: View {
    let presentation: SmartCareAIReviewResultPresentation
    let onClose: () -> Void
    let onRetryFailed: () -> Void
    let onContinueRemaining: () -> Void
    let onApplySelectionChanges: ([String: Bool]) -> Void
    let onReviewCleanup: () -> Void
    let onOpenSettings: () -> Void
    let onRerun: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var proposedSelectionByPath: [String: Bool]
    @State private var baselineSelectionByPath: [String: Bool]
    @State private var expandedRowIDs: Set<String>

    init(
        presentation: SmartCareAIReviewResultPresentation,
        onClose: @escaping () -> Void,
        onRetryFailed: @escaping () -> Void,
        onContinueRemaining: @escaping () -> Void,
        onApplySelectionChanges: @escaping ([String: Bool]) -> Void,
        onReviewCleanup: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onRerun: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.onClose = onClose
        self.onRetryFailed = onRetryFailed
        self.onContinueRemaining = onContinueRemaining
        self.onApplySelectionChanges = onApplySelectionChanges
        self.onReviewCleanup = onReviewCleanup
        self.onOpenSettings = onOpenSettings
        self.onRerun = onRerun
        let currentSelections = presentation.rows.reduce(into: [String: Bool]()) { result, row in
            result[row.path] = row.currentSelected
        }
        _proposedSelectionByPath = State(initialValue: currentSelections)
        _baselineSelectionByPath = State(initialValue: currentSelections)
        _expandedRowIDs = State(initialValue: Set(presentation.rows.map(\.id)))
    }

    init(
        report: SmartCareAIReviewReport,
        currentSelectedItemIDs: Set<SmartCareItem.ID>,
        onClose: @escaping () -> Void,
        onRetryFailed: @escaping () -> Void,
        onContinueRemaining: @escaping () -> Void,
        onApplySelectionChanges: @escaping ([String: Bool]) -> Void,
        onReviewCleanup: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onRerun: @escaping () -> Void
    ) {
        self.init(
            presentation: SmartCareAIReviewResultPresentation(
                report: report,
                currentSelectedItemIDs: currentSelectedItemIDs
            ),
            onClose: onClose,
            onRetryFailed: onRetryFailed,
            onContinueRemaining: onContinueRemaining,
            onApplySelectionChanges: onApplySelectionChanges,
            onReviewCleanup: onReviewCleanup,
            onOpenSettings: onOpenSettings,
            onRerun: onRerun
        )
    }

    var body: some View {
        ZStack {
            ambientBackground

            VStack(spacing: 0) {
                header
                Divider().opacity(0.55)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        scopeNotice
                        statsGrid

                        if let globalFailureKind = presentation.globalFailureKind {
                            globalFailureCard(
                                kind: globalFailureKind,
                                httpStatus: presentation.globalFailureHTTPStatus
                            )
                        }

                        if presentation.rows.isEmpty {
                            emptyState
                        } else {
                            resultSections
                        }

                        safetyNotice
                    }
                    .padding(20)
                }
                .scrollIndicators(.automatic)

                Divider().opacity(0.55)
                footer
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 590, idealHeight: 680)
        .animation(.smooth(duration: reduceMotion ? 0.12 : 0.28), value: changedSelections.count)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 15) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.13))
                    .frame(width: 52, height: 52)
                Circle()
                    .strokeBorder(statusTint.opacity(0.34), lineWidth: 1)
                    .frame(width: 52, height: 52)
                Image(systemName: statusIconName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(statusTitleKey), bundle: .module)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(
                    String(
                        format: String(
                            localized: "smart_care.ai.report.subtitle.format",
                            bundle: .module
                        ),
                        presentation.completedCount,
                        presentation.requestedCount
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            Text("smart_care.ai.report.badge", bundle: .module)
                .font(.caption.weight(.bold))
                .foregroundStyle(SmartCareMotionPalette.blueColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SmartCareMotionPalette.blueColor.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(SmartCareMotionPalette.blueColor.opacity(0.24)))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    // MARK: Summary

    private var scopeNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SmartCareMotionPalette.blueColor)
                .frame(width: 30, height: 30)
                .background(SmartCareMotionPalette.blueColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("smart_care.ai.report.scope.title", bundle: .module)
                    .font(.callout.weight(.semibold))
                Text(
                    String(
                        format: String(
                            localized: "smart_care.ai.report.scope.description.format",
                            bundle: .module
                        ),
                        presentation.requestedCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .techSurface(tint: SmartCareMotionPalette.blueColor, cornerRadius: 12)
    }

    private var statsGrid: some View {
        HStack(spacing: 10) {
            statCard(
                icon: "checkmark.circle.fill",
                tint: SmartCarePresentation.tint(for: .safe),
                value: presentation.safeAdviceCount,
                titleKey: "smart_care.ai.report.stat.safe"
            )
            statCard(
                icon: "exclamationmark.triangle.fill",
                tint: SmartCarePresentation.tint(for: .confirm),
                value: presentation.confirmAdviceCount,
                titleKey: "smart_care.ai.report.stat.review"
            )
            statCard(
                icon: "hand.raised.fill",
                tint: SmartCarePresentation.tint(for: .forbid),
                value: presentation.forbidAdviceCount,
                titleKey: "smart_care.ai.report.stat.avoid"
            )
            statCard(
                icon: "xmark.octagon.fill",
                tint: SmartCarePresentation.tint(for: .forbid),
                value: presentation.failedCount,
                titleKey: "smart_care.ai.report.stat.failed"
            )
        }
    }

    private func statCard(icon: String, tint: Color, value: Int, titleKey: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(value)")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text(LocalizedStringKey(titleKey), bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .techSurface(tint: tint, cornerRadius: 11)
    }

    private func globalFailureCard(
        kind: SmartCareAIReviewFailure.Kind,
        httpStatus: Int?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(statusTint)
            VStack(alignment: .leading, spacing: 4) {
                Text("smart_care.ai.report.global_failure.title", bundle: .module)
                    .font(.callout.weight(.semibold))
                Text(
                    LocalizedStringKey(SmartCarePresentation.aiFailureSummaryKey(for: kind)),
                    bundle: .module
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let httpStatus {
                    Text(verbatim: "HTTP \(httpStatus)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .techSurface(tint: statusTint, cornerRadius: 12)
    }

    // MARK: Result list

    private var resultSections: some View {
        VStack(alignment: .leading, spacing: 15) {
            let successes = presentation.rows.filter {
                if case .success = $0.result { return true }
                return false
            }
            let failures = presentation.rows.filter {
                if case .failure = $0.result { return true }
                return false
            }
            let pending = presentation.rows.filter {
                if case .pending = $0.result { return true }
                return false
            }

            if !successes.isEmpty {
                resultSection(
                    titleKey: "smart_care.ai.report.section.reviewed",
                    icon: "sparkles",
                    tint: SmartCarePresentation.tint(for: .safe),
                    rows: successes
                )
            }
            if !failures.isEmpty {
                resultSection(
                    titleKey: "smart_care.ai.report.section.failed",
                    icon: "exclamationmark.triangle.fill",
                    tint: SmartCarePresentation.tint(for: .confirm),
                    rows: failures
                )
            }
            if !pending.isEmpty {
                resultSection(
                    titleKey: "smart_care.ai.report.section.remaining",
                    icon: "hourglass",
                    tint: Color.secondary,
                    rows: pending
                )
            }
        }
    }

    private func resultSection(
        titleKey: String,
        icon: String,
        tint: Color,
        rows: [SmartCareAIReviewResultPresentation.Row]
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text(LocalizedStringKey(titleKey), bundle: .module)
                    .font(.headline)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }

            ForEach(rows) { row in
                resultRow(row)
            }
        }
    }

    private func resultRow(_ row: SmartCareAIReviewResultPresentation.Row) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedRowIDs.contains(row.id) },
                set: { expanded in
                    if expanded {
                        expandedRowIDs.insert(row.id)
                    } else {
                        expandedRowIDs.remove(row.id)
                    }
                }
            )
        ) {
            rowDetail(row)
                .padding(.top, 11)
        } label: {
            HStack(spacing: 10) {
                resultSymbol(row.result)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: row.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(verbatim: formattedBytes(row.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .padding(12)
        .techSurface(tint: rowTint(row), cornerRadius: 13)
    }

    @ViewBuilder
    private func rowDetail(_ row: SmartCareAIReviewResultPresentation.Row) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                verdictPill(
                    labelKey: "smart_care.ai.report.verdict.local",
                    verdict: row.localVerdict
                )

                if case .success(let advice) = row.result {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    verdictPill(
                        labelKey: "smart_care.ai.report.verdict.ai",
                        verdict: advice.canDelete
                    )
                }

                Spacer(minLength: 0)
            }

            switch row.result {
            case .success(let advice):
                adviceContent(advice)
            case .failure(let kind, let httpStatus):
                failureContent(kind: kind, httpStatus: httpStatus)
            case .pending:
                Label {
                    Text("smart_care.ai.report.item.pending", bundle: .module)
                } icon: {
                    Image(systemName: "hourglass")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            selectionControl(row)
        }
    }

    private func adviceContent(_ advice: AIAdvice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("smart_care.ai.report.item.summary", bundle: .module)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if advice.summary == AIAdvice.unparsableSummaryKey {
                    Text(LocalizedStringKey(AIAdvice.unparsableSummaryKey), bundle: .module)
                        .font(.callout)
                } else {
                    Text(verbatim: advice.summary)
                        .font(.callout)
                }
            }

            if !advice.reason.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ai.sheet.reason", bundle: .module)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: localizedAdviceReason(advice.reason))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !advice.sideEffects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ai.sheet.side_effects", bundle: .module)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(advice.sideEffects.enumerated()), id: \.offset) { _, effect in
                        Label {
                            Text(verbatim: effect)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func failureContent(
        kind: SmartCareAIReviewFailure.Kind,
        httpStatus: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("smart_care.ai.report.item.failure", bundle: .module)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SmartCarePresentation.tint(for: .confirm))
            Text(
                LocalizedStringKey(SmartCarePresentation.aiFailureSummaryKey(for: kind)),
                bundle: .module
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if let httpStatus {
                Text(verbatim: "HTTP \(httpStatus)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func selectionControl(_ row: SmartCareAIReviewResultPresentation.Row) -> some View {
        Divider().opacity(0.55)

        if presentation.status == .stale {
            Label {
                Text("smart_care.ai.report.selection.stale", bundle: .module)
            } icon: {
                Image(systemName: "clock.badge.exclamationmark")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        } else if row.localVerdict == .forbid {
            Label {
                Text("smart_care.ai.report.selection.locked", bundle: .module)
            } icon: {
                Image(systemName: "lock.shield.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(SmartCarePresentation.tint(for: .forbid))
        } else if case .success(let advice) = row.result,
                  selectionCanBeProposed(for: row, advice: advice) {
            Toggle(
                isOn: Binding(
                    get: { proposedSelectionByPath[row.path] ?? row.currentSelected },
                    set: { proposedSelectionByPath[row.path] = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("smart_care.ai.report.selection.proposal", bundle: .module)
                        .font(.caption.weight(.semibold))
                    Text("smart_care.ai.report.selection.proposal.help", bundle: .module)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("smart_care.ai.report.selection.unchanged", bundle: .module)
                        .font(.caption.weight(.semibold))
                    Text("smart_care.ai.report.selection.unchanged.help", bundle: .module)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "shield.checkered")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func selectionCanBeProposed(
        for row: SmartCareAIReviewResultPresentation.Row,
        advice: AIAdvice
    ) -> Bool {
        if row.localVerdict == .safe { return true }
        // 用户在 AI 复核前已经手动选中的 confirm 项仍可在报告中取消；
        // 新增 confirm 选择则只在 AI 建议 safe 时开放，最终仍要经过清理预览。
        return row.currentSelected || advice.canDelete == .safe
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(statusTint)
            Text("smart_care.ai.report.empty.title", bundle: .module)
                .font(.headline)
            Text("smart_care.ai.report.empty.description", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .techSurface(tint: statusTint, cornerRadius: 14)
    }

    private var safetyNotice: some View {
        Label {
            Text("smart_care.ai.report.safety_notice", bundle: .module)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "shield.lefthalf.filled")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            statusSpecificLeadingActions

            Spacer(minLength: 12)

            if canApplyChanges {
                Button {
                    applyPendingSelectionChanges()
                } label: {
                    Label {
                        Text(
                            String(
                                format: String(
                                    localized: "smart_care.ai.report.action.apply.format",
                                    bundle: .module
                                ),
                                changedSelections.count
                            )
                        )
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(changedSelections.isEmpty)
            }

            if presentation.status != .stale,
               presentation.hasCleanupSelection(
                   proposedSelectionByPath: proposedSelectionByPath
               ) {
                Button {
                    applyPendingSelectionChanges()
                    onReviewCleanup()
                } label: {
                    Label {
                        Text("smart_care.ai.report.action.review_cleanup", bundle: .module)
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                onClose()
            } label: {
                Text("smart_care.ai.report.action.close", bundle: .module)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.64))
    }

    @ViewBuilder
    private var statusSpecificLeadingActions: some View {
        switch presentation.status {
        case .empty:
            EmptyView()
        case .success:
            EmptyView()
        case .partial:
            if presentation.retryAvailable {
                Button(action: onRetryFailed) {
                    Label {
                        Text(
                            LocalizedStringKey(
                                presentation.retryIncludesRemaining
                                    ? "smart_care.ai.report.action.continue"
                                    : "smart_care.ai.report.action.retry_failed"
                            ),
                            bundle: .module
                        )
                    } icon: {
                        Image(systemName: presentation.retryIncludesRemaining
                            ? "play.fill"
                            : "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
            }
            settingsButtonIfNeeded
        case .failed:
            if presentation.retryAvailable {
                Button(action: onRetryFailed) {
                    Label {
                        Text("smart_care.ai.report.action.retry", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
            }
            settingsButtonIfNeeded
        case .cancelled:
            Button(action: onContinueRemaining) {
                Label {
                    Text("smart_care.ai.report.action.continue", bundle: .module)
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.bordered)
        case .stale:
            Button(action: onRerun) {
                Label {
                    Text("smart_care.ai.report.action.rerun", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var settingsButtonIfNeeded: some View {
        if presentation.settingsRecommended {
            Button(action: onOpenSettings) {
                Label {
                    Text("smart_care.ai.report.action.open_settings", bundle: .module)
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Styling and state

    private var ambientBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [
                    statusTint.opacity(0.11),
                    SmartCareMotionPalette.tealColor.opacity(0.035),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 610
            )
            LinearGradient(
                colors: [Color.white.opacity(0.025), Color.clear, statusTint.opacity(0.018)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var changedSelections: [String: Bool] {
        guard presentation.status != .stale else { return [:] }
        return presentation.rows.reduce(into: [:]) { changes, row in
            guard row.localVerdict != .forbid else { return }
            let baseline = baselineSelectionByPath[row.path] ?? row.currentSelected
            let proposed = proposedSelectionByPath[row.path] ?? row.currentSelected
            if proposed != baseline {
                changes[row.path] = proposed
            }
        }
    }

    private var canApplyChanges: Bool {
        presentation.status != .stale && !presentation.rows.isEmpty
    }

    private func applyPendingSelectionChanges() {
        let changes = changedSelections
        guard !changes.isEmpty else { return }
        onApplySelectionChanges(changes)
        for (path, selected) in changes {
            baselineSelectionByPath[path] = selected
        }
    }

    private var statusTitleKey: String {
        switch presentation.status {
        case .empty: return "smart_care.ai.report.title.empty"
        case .success: return "smart_care.ai.report.title.success"
        case .partial: return "smart_care.ai.report.title.partial"
        case .failed: return "smart_care.ai.report.title.failed"
        case .cancelled: return "smart_care.ai.report.title.cancelled"
        case .stale: return "smart_care.ai.report.title.stale"
        }
    }

    private var statusIconName: String {
        switch presentation.status {
        case .empty: return "sparkles.rectangle.stack"
        case .success: return "checkmark.seal.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        }
    }

    private var statusTint: Color {
        switch presentation.status {
        case .empty: return SmartCareMotionPalette.blueColor
        case .success: return SmartCarePresentation.tint(for: .safe)
        case .partial, .cancelled: return SmartCarePresentation.tint(for: .confirm)
        case .failed: return SmartCarePresentation.tint(for: .forbid)
        case .stale: return SmartCareMotionPalette.blueColor
        }
    }

    private func resultSymbol(_ result: SmartCareAIReviewResultPresentation.Row.Result) -> some View {
        let style: (icon: String, tint: Color) = switch result {
        case .success: ("checkmark.circle.fill", SmartCarePresentation.tint(for: .safe))
        case .failure: ("exclamationmark.triangle.fill", SmartCarePresentation.tint(for: .confirm))
        case .pending: ("hourglass", Color.secondary)
        }
        return Image(systemName: style.icon)
            .foregroundStyle(style.tint)
            .frame(width: 24, height: 24)
            .background(style.tint.opacity(0.09), in: Circle())
    }

    @ViewBuilder
    private func verdictPill(labelKey: String, verdict: SafetyVerdict) -> some View {
        let tint = SmartCarePresentation.tint(for: verdict)
        HStack(spacing: 5) {
            Text(LocalizedStringKey(labelKey), bundle: .module)
                .foregroundStyle(.secondary)
            Image(systemName: verdictIcon(verdict))
            Text(
                LocalizedStringKey(SmartCarePresentation.verdictTitleKey(for: verdict)),
                bundle: .module
            )
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.09), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 1))
    }

    private func verdictIcon(_ verdict: SafetyVerdict) -> String {
        switch verdict {
        case .safe: return "checkmark.shield.fill"
        case .confirm: return "exclamationmark.triangle.fill"
        case .forbid: return "lock.shield.fill"
        }
    }

    private func rowTint(_ row: SmartCareAIReviewResultPresentation.Row) -> Color {
        switch row.result {
        case .success(let advice): return SmartCarePresentation.tint(for: advice.canDelete)
        case .failure: return SmartCarePresentation.tint(for: .confirm)
        case .pending: return Color.secondary
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func localizedAdviceReason(_ reason: String) -> String {
        let prefix = AIAdviceClamp.localPolicyOverridePrefix
        guard reason.hasPrefix(prefix) else { return reason }
        let localizedPrefix = String(
            localized: "ai.advice.local_policy_override.prefix",
            bundle: .module
        )
        return localizedPrefix + String(reason.dropFirst(prefix.count))
    }

}

private extension View {
    func techSurface(tint: Color, cornerRadius: CGFloat) -> some View {
        modifier(SmartCareAIReviewTechSurface(tint: tint, cornerRadius: cornerRadius))
    }
}

private struct SmartCareAIReviewTechSurface: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .windowBackgroundColor).opacity(0.5),
                                tint.opacity(0.055),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            tint.opacity(0.25),
                            Color.primary.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
    }
}
