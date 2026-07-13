import AIKit
import Foundation
import SafetyKit
import Testing
@testable import AppUI

@Suite("Smart Care AI review result presentation")
struct SmartCareAIReviewResultSheetTests {
    @Test("reopening uses the current selection while retaining the review-start audit value")
    func reopeningUsesCurrentSelection() {
        let item = makeItem("cache", verdict: .safe)
        let report = makeReport(
            status: .success,
            outcomes: [
                SmartCareAIReviewItemOutcome(
                    item: item,
                    selectedAtStart: false,
                    result: .advice(makeAdvice(.safe))
                )
            ]
        )

        let presentation = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: [item.id]
        )

        #expect(presentation.rows.count == 1)
        #expect(presentation.rows[0].selectedAtStart == false)
        #expect(presentation.rows[0].currentSelected == true)
        #expect(presentation.canReviewCleanup)
    }

    @Test("cleanup availability follows explicit proposals and selections outside review scope")
    func cleanupAvailabilityTracksEffectiveSelection() {
        let reviewed = makeItem("reviewed", verdict: .safe)
        let outside = makeItem("outside", verdict: .safe)
        let report = makeReport(
            status: .success,
            outcomes: [
                SmartCareAIReviewItemOutcome(
                    item: reviewed,
                    selectedAtStart: false,
                    result: .advice(makeAdvice(.safe))
                )
            ]
        )

        let empty = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: []
        )
        #expect(!empty.canReviewCleanup)
        #expect(empty.hasCleanupSelection(proposedSelectionByPath: [reviewed.path: true]))

        let inside = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: [reviewed.id]
        )
        #expect(!inside.hasCleanupSelection(proposedSelectionByPath: [reviewed.path: false]))

        let outsideScope = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: [outside.id]
        )
        #expect(outsideScope.selectedOutsideReviewCount == 1)
        #expect(outsideScope.hasCleanupSelection(proposedSelectionByPath: [reviewed.path: false]))
    }

    @Test("full AI advice survives projection into the result sheet")
    func fullAdviceSurvivesProjection() {
        let advice = AIAdvice(
            summary: "summary",
            canDelete: .confirm,
            reason: "reason",
            sideEffects: ["effect one", "effect two"]
        )
        let item = makeItem("developer", verdict: .confirm)
        let report = makeReport(
            status: .success,
            outcomes: [
                SmartCareAIReviewItemOutcome(
                    item: item,
                    selectedAtStart: false,
                    result: .advice(advice)
                )
            ]
        )

        let presentation = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: []
        )

        guard case .success(let projected) = presentation.rows[0].result else {
            Issue.record("Expected projected advice")
            return
        }
        #expect(projected == advice)
        #expect(projected.reason == "reason")
        #expect(projected.sideEffects == ["effect one", "effect two"])
        #expect(presentation.safeAdviceCount == 0)
        #expect(presentation.confirmAdviceCount == 1)
        #expect(presentation.forbidAdviceCount == 0)
    }

    @Test("retry and settings actions derive from typed failures")
    func typedFailuresDriveActions() {
        let settingsItem = makeItem("settings", verdict: .safe)
        let retryItem = makeItem("retry", verdict: .confirm)
        let report = makeReport(
            status: .failed,
            outcomes: [
                SmartCareAIReviewItemOutcome(
                    item: settingsItem,
                    selectedAtStart: true,
                    result: .failure(SmartCareAIReviewFailure(
                        kind: .authentication,
                        canRetry: false,
                        shouldOpenSettings: true
                    ))
                ),
                SmartCareAIReviewItemOutcome(
                    item: retryItem,
                    selectedAtStart: false,
                    result: .failure(SmartCareAIReviewFailure(
                        kind: .network,
                        canRetry: true
                    ))
                )
            ]
        )

        let presentation = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: [settingsItem.id]
        )

        #expect(presentation.failedCount == 2)
        #expect(presentation.settingsRecommended)
        #expect(presentation.canReviewCleanup)
        #expect(presentation.retryAvailable)
        guard case .failure(let kind, let httpStatus) = presentation.rows[0].result else {
            Issue.record("Expected typed failure projection")
            return
        }
        #expect(kind == .authentication)
        #expect(httpStatus == nil)
    }

    @Test("global preflight failure counts the full scope once")
    func globalPreflightFailureCountsScopeOnce() {
        let first = makeItem("first", verdict: .safe)
        let second = makeItem("second", verdict: .confirm)
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: 7,
            observedSummaryRevision: 7,
            status: .failed,
            items: [first, second].map { item in
                SmartCareAIReviewItemOutcome(
                    item: item,
                    selectedAtStart: false,
                    result: .notReviewed
                )
            },
            globalFailure: SmartCareAIReviewFailure(
                kind: .configuration,
                canRetry: false,
                shouldOpenSettings: true
            ),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2)
        )

        let presentation = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: []
        )

        #expect(presentation.failedCount == 0)
        #expect(presentation.completedCount == 0)
        #expect(presentation.remainingCount == 2)
        #expect(presentation.settingsRecommended)
        #expect(presentation.retryAvailable)
        #expect(!presentation.canReviewCleanup)
    }

    @Test("partial continuation preflight failure keeps remaining action semantics")
    func continuationPreflightFailureKeepsRemainingSemantics() {
        let done = makeItem("done", verdict: .safe)
        let remaining = makeItem("remaining", verdict: .confirm)
        let report = SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: 8,
            observedSummaryRevision: 8,
            status: .partial,
            items: [
                SmartCareAIReviewItemOutcome(
                    item: done,
                    selectedAtStart: true,
                    result: .advice(makeAdvice(.safe))
                ),
                SmartCareAIReviewItemOutcome(
                    item: remaining,
                    selectedAtStart: false,
                    result: .notReviewed
                )
            ],
            globalFailure: SmartCareAIReviewFailure(
                kind: .configuration,
                canRetry: false,
                shouldOpenSettings: true
            ),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2)
        )

        let presentation = SmartCareAIReviewResultPresentation(
            report: report,
            currentSelectedItemIDs: [done.id]
        )
        #expect(presentation.succeededCount == 1)
        #expect(presentation.failedCount == 0)
        #expect(presentation.remainingCount == 1)
        #expect(presentation.retryAvailable)
        #expect(presentation.retryIncludesRemaining)
    }

    @Test(arguments: [
        SmartCareAIReviewReportStatus.empty,
        .success,
        .partial,
        .failed,
        .cancelled,
        .stale
    ])
    func everyTerminalStatusHasAPresentation(status: SmartCareAIReviewReportStatus) {
        let presentation = SmartCareAIReviewResultPresentation(
            report: makeReport(status: status, outcomes: []),
            currentSelectedItemIDs: []
        )

        let expected: SmartCareAIReviewResultPresentation.Status = switch status {
        case .empty: .empty
        case .success: .success
        case .partial: .partial
        case .failed: .failed
        case .cancelled: .cancelled
        case .stale: .stale
        }
        #expect(presentation.status == expected)
    }

    @Test("fresh reports present immediately or queue behind a competing modal")
    func freshReportAutoPresentationRespectsModalOwnership() {
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: .success,
            isNormalInterface: true,
            isAIReportVisible: false,
            isCleanupVisible: false,
            hasOtherModalPresentation: false
        ) == .present)
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: .failed,
            isNormalInterface: true,
            isAIReportVisible: false,
            isCleanupVisible: true,
            hasOtherModalPresentation: false
        ) == .ignore)
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: .partial,
            isNormalInterface: true,
            isAIReportVisible: false,
            isCleanupVisible: false,
            hasOtherModalPresentation: true
        ) == .queue)
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: .success,
            isNormalInterface: false,
            isAIReportVisible: false,
            isCleanupVisible: false,
            hasOtherModalPresentation: false
        ) == .queue)
    }

    @Test("stale report updates an open report but never reopens after cleanup")
    func staleReportDoesNotReopenAfterCleanup() {
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: .stale,
            isNormalInterface: true,
            isAIReportVisible: false,
            isCleanupVisible: false,
            hasOtherModalPresentation: false
        ) == .ignore)
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: .stale,
            isNormalInterface: true,
            isAIReportVisible: true,
            isCleanupVisible: false,
            hasOtherModalPresentation: false
        ) == .present)
        #expect(SmartCareAIReviewAutoPresentationPolicy.action(
            reportStatus: nil,
            isNormalInterface: true,
            isAIReportVisible: true,
            isCleanupVisible: false,
            hasOtherModalPresentation: false
        ) == .dismiss)
    }

    @Test("AI cleanup preview remains linked to the reviewed summary revision")
    func cleanupPreviewRequiresMatchingReviewedRevision() {
        #expect(SmartCareAIReviewCleanupLinkPolicy.allowsPresentation(
            expectedSummaryRevision: 12,
            currentSummaryRevision: 12,
            requestSummaryRevision: 12
        ))
        #expect(!SmartCareAIReviewCleanupLinkPolicy.allowsPresentation(
            expectedSummaryRevision: 12,
            currentSummaryRevision: 13,
            requestSummaryRevision: 13
        ))
        #expect(!SmartCareAIReviewCleanupLinkPolicy.allowsPresentation(
            expectedSummaryRevision: 12,
            currentSummaryRevision: 12,
            requestSummaryRevision: 11
        ))
    }

    @Test("deferred report actions cannot cross into a reset or newer summary")
    func deferredActionsRequireTheSameRunAndSummary() {
        let report = makeReport(status: .stale, outcomes: [])
        #expect(SmartCareAIReviewDeferredActionPolicy.allows(
            expectedRunID: report.runID,
            expectedSummaryRevision: 8,
            latestReport: report,
            currentSummaryRevision: 8,
            aiIsRunning: false
        ))
        #expect(!SmartCareAIReviewDeferredActionPolicy.allows(
            expectedRunID: report.runID,
            expectedSummaryRevision: 8,
            latestReport: nil,
            currentSummaryRevision: 8,
            aiIsRunning: false
        ))
        #expect(!SmartCareAIReviewDeferredActionPolicy.allows(
            expectedRunID: report.runID,
            expectedSummaryRevision: 8,
            latestReport: report,
            currentSummaryRevision: 9,
            aiIsRunning: false
        ))
        #expect(!SmartCareAIReviewDeferredActionPolicy.allows(
            expectedRunID: report.runID,
            expectedSummaryRevision: 8,
            latestReport: report,
            currentSummaryRevision: 8,
            aiIsRunning: true
        ))
    }

    private func makeReport(
        status: SmartCareAIReviewReportStatus,
        outcomes: [SmartCareAIReviewItemOutcome]
    ) -> SmartCareAIReviewReport {
        SmartCareAIReviewReport(
            runID: UUID(),
            sourceSummaryRevision: 7,
            observedSummaryRevision: status == .stale ? 8 : 7,
            status: status,
            items: outcomes,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func makeItem(_ name: String, verdict: SafetyVerdict) -> SmartCareItem {
        SmartCareItem(
            id: "/tmp/\(name)",
            bucketID: .appCache,
            path: "/tmp/\(name)",
            title: name,
            bytes: 128,
            verdict: verdict
        )
    }

    private func makeAdvice(_ verdict: SafetyVerdict) -> AIAdvice {
        AIAdvice(
            summary: "summary",
            canDelete: verdict,
            reason: "reason",
            sideEffects: []
        )
    }
}
