import AIKit
import SafetyKit
import SwiftUI

enum SmartCarePresentation {
    static let normalBuckets: [SmartCareBucketID] = [
        .systemJunk,
        .appCache,
        .developerCache
    ]

    static func titleKey(for bucket: SmartCareBucketID) -> String {
        switch bucket {
        case .systemJunk: return "smart_care.bucket.system_junk.title"
        case .appCache: return "smart_care.bucket.app_cache.title"
        case .developerCache: return "smart_care.bucket.developer_cache.title"
        case .largeFiles: return "smart_care.bucket.large_files.title"
        case .appLeftovers: return "smart_care.bucket.app_leftovers.title"
        case .duplicates: return "smart_care.bucket.duplicates.title"
        }
    }

    static func subtitleKey(for bucket: SmartCareBucketID) -> String {
        switch bucket {
        case .systemJunk: return "smart_care.bucket.system_junk.subtitle"
        case .appCache: return "smart_care.bucket.app_cache.subtitle"
        case .developerCache: return "smart_care.bucket.developer_cache.subtitle"
        case .largeFiles: return "smart_care.bucket.large_files.subtitle"
        case .appLeftovers: return "smart_care.bucket.app_leftovers.subtitle"
        case .duplicates: return "smart_care.bucket.duplicates.subtitle"
        }
    }

    static func iconName(for bucket: SmartCareBucketID) -> String {
        switch bucket {
        case .systemJunk: return "trash"
        case .appCache: return "archivebox"
        case .developerCache: return "hammer"
        case .largeFiles: return "externaldrive"
        case .appLeftovers: return "app.dashed"
        case .duplicates: return "doc.on.doc"
        }
    }

    static func tint(for bucket: SmartCareBucketID) -> Color {
        switch bucket {
        case .systemJunk: return Color(red: 0.18, green: 0.58, blue: 0.84)
        case .appCache: return Color(red: 0.42, green: 0.48, blue: 0.86)
        case .developerCache: return Color(red: 0.18, green: 0.62, blue: 0.56)
        case .largeFiles: return Color(red: 0.84, green: 0.52, blue: 0.18)
        case .appLeftovers: return Color(red: 0.78, green: 0.42, blue: 0.38)
        case .duplicates: return Color(red: 0.50, green: 0.58, blue: 0.66)
        }
    }

    static func titleKey(for stage: SmartCareScanStage) -> String {
        switch stage {
        case .core: return "smart_care.scope.system.title"
        case .appCaches: return "smart_care.scope.apps.title"
        case .developerCaches: return "smart_care.scope.developer.title"
        }
    }

    static func subtitleKey(for stage: SmartCareScanStage) -> String {
        switch stage {
        case .core: return "smart_care.scope.system.subtitle"
        case .appCaches: return "smart_care.scope.apps.subtitle"
        case .developerCaches: return "smart_care.scope.developer.subtitle"
        }
    }

    static func iconName(for stage: SmartCareScanStage) -> String {
        switch stage {
        case .core: return "doc.text.magnifyingglass"
        case .appCaches: return "shippingbox"
        case .developerCaches: return "hammer"
        }
    }

    static func tint(for stage: SmartCareScanStage) -> Color {
        switch stage {
        case .core: return SmartCareMotionPalette.blueColor
        case .appCaches: return SmartCareMotionPalette.tealColor
        case .developerCaches: return SmartCareMotionPalette.amberColor
        }
    }

    static func durationBadgeKey(for stage: SmartCareScanStage) -> String? {
        stage == .developerCaches ? "smart_care.scope.may_take_longer" : nil
    }

    static func primaryActionTitleKey(for action: SmartCarePrimaryAction,
                                      requiresConfirmation: Bool = false) -> String {
        switch action {
        case .startScan: return "smart_care.action.start_scan"
        case .stopScan: return "smart_care.action.stop_scan"
        case .cleanSafeItems, .confirmClean:
            return requiresConfirmation
                ? "smart_care.action.review_selected"
                : "smart_care.action.review_cleanup"
        case .cleaning: return "smart_care.action.cleaning"
        case .scanAgain: return "smart_care.action.scan_again"
        case .retry: return "smart_care.action.retry"
        case .continueScan: return "smart_care.action.continue_scan"
        }
    }

    static func primaryActionIconName(for action: SmartCarePrimaryAction,
                                      requiresConfirmation: Bool = false) -> String {
        switch action {
        case .startScan: return "magnifyingglass"
        case .stopScan: return "stop.fill"
        case .cleanSafeItems, .confirmClean:
            return requiresConfirmation ? "exclamationmark.shield" : "doc.text.magnifyingglass"
        case .cleaning: return "trash"
        case .scanAgain: return "arrow.clockwise"
        case .retry: return "arrow.counterclockwise"
        case .continueScan: return "play"
        }
    }

    static func phaseTitleKey(for phase: SmartCarePhase) -> String {
        switch phase {
        case .idle: return "smart_care.phase.idle"
        case .scanning: return "smart_care.phase.scanning"
        case .reviewing: return "smart_care.phase.reviewing"
        case .confirming: return "smart_care.phase.confirming"
        case .cleaning: return "smart_care.phase.cleaning"
        case .completed: return "smart_care.phase.completed"
        case .failed: return "smart_care.phase.failed"
        case .cancelled: return "smart_care.phase.cancelled"
        }
    }

    static func activityTitleKey(for activity: SmartCareScanActivity) -> String {
        switch activity {
        case .scanning(.core): return "smart_care.activity.scan.core"
        case .scanning(.appCaches): return "smart_care.activity.scan.app_cache"
        case .scanning(.developerCaches): return "smart_care.activity.scan.developer_cache"
        case .organizing: return "smart_care.activity.organizing"
        case .finalizing: return "smart_care.activity.finalizing"
        }
    }

    static func activityIconName(for activity: SmartCareScanActivity) -> String {
        switch activity {
        case .scanning(let stage), .organizing(let stage):
            return iconName(for: stage)
        case .finalizing:
            return "checkmark.shield"
        }
    }

    static func verdictTitleKey(for verdict: SafetyVerdict) -> String {
        switch verdict {
        case .safe: return "smart_care.item.safe"
        case .confirm: return "smart_care.item.confirm"
        case .forbid: return "smart_care.item.locked"
        }
    }

    static func tint(for verdict: SafetyVerdict) -> Color {
        switch verdict {
        case .safe: return Color(red: 0.18, green: 0.62, blue: 0.34)
        case .confirm: return Color(red: 0.86, green: 0.58, blue: 0.18)
        case .forbid: return Color(red: 0.78, green: 0.24, blue: 0.22)
        }
    }

    static func defaultRiskKey(for item: SmartCareItem) -> String? {
        if item.verdict == .forbid {
            return "smart_care.risk.protected"
        }
        guard item.verdict == .confirm else { return nil }
        switch item.bucketID {
        case .systemJunk: return "smart_care.risk.system_junk"
        case .appCache: return "smart_care.risk.app_cache"
        case .developerCache: return "smart_care.risk.developer_cache"
        case .largeFiles: return "smart_care.risk.large_files"
        case .appLeftovers: return "smart_care.risk.app_leftovers"
        case .duplicates: return "smart_care.risk.duplicates"
        }
    }

    static func aiFailureSummaryKey(for kind: SmartCareAIReviewFailure.Kind) -> String {
        switch kind {
        case .configuration: return "smart_care.ai.report.failure.configuration"
        case .authentication: return "smart_care.ai.report.failure.authentication"
        case .rateLimit: return "smart_care.ai.report.failure.rate_limit"
        case .network: return "smart_care.ai.report.failure.network"
        case .server: return "smart_care.ai.report.failure.server"
        case .decoding: return "smart_care.ai.report.failure.decoding"
        case .unknown: return "smart_care.ai.report.failure.unknown"
        }
    }
}

public struct SmartCareHomeView: View {
    public let coordinator: SmartCareCoordinator

    private let session: SmartCareSession?
    private let aiIsConfigured: Bool
    private let aiIsRunning: Bool
    private let aiProcessed: Int
    private let aiTotal: Int
    private let aiError: String?
    private let aiItemStates: [String: SmartCareAIItemState]
    private let aiReportAvailable: Bool
    private let onPrimaryAction: (SmartCarePrimaryAction) -> Void
    private let onAIReview: () -> Void
    private let onAICancel: () -> Void
    private let onAIShowReport: () -> Void

    public init(coordinator: SmartCareCoordinator,
                session: SmartCareSession? = nil,
                aiIsConfigured: Bool = false,
                aiIsRunning: Bool = false,
                aiProcessed: Int = 0,
                aiTotal: Int = 0,
                aiError: String? = nil,
                aiItemStates: [String: SmartCareAIItemState] = [:],
                aiReportAvailable: Bool = false,
                onPrimaryAction: @escaping (SmartCarePrimaryAction) -> Void = { _ in },
                onAIReview: @escaping () -> Void = {},
                onAICancel: @escaping () -> Void = {},
                onAIShowReport: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.session = session
        self.aiIsConfigured = aiIsConfigured
        self.aiIsRunning = aiIsRunning
        self.aiProcessed = aiProcessed
        self.aiTotal = aiTotal
        self.aiError = aiError
        self.aiItemStates = aiItemStates
        self.aiReportAvailable = aiReportAvailable
        self.onPrimaryAction = onPrimaryAction
        self.onAIReview = onAIReview
        self.onAICancel = onAICancel
        self.onAIShowReport = onAIShowReport
    }

    public var body: some View {
        SmartCareDashboardView(
            coordinator: coordinator,
            session: session,
            aiIsConfigured: aiIsConfigured,
            aiIsRunning: aiIsRunning,
            aiProcessed: aiProcessed,
            aiTotal: aiTotal,
            aiError: aiError,
            aiItemStates: aiItemStates,
            aiReportAvailable: aiReportAvailable,
            onPrimaryAction: onPrimaryAction,
            onAIReview: onAIReview,
            onAICancel: onAICancel,
            onAIShowReport: onAIShowReport
        )
    }
}
