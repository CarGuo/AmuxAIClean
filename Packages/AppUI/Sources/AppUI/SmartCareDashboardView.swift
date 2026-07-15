import AppKit
import SafetyKit
import SwiftUI

struct SmartCareFailurePresentation: Equatable, Sendable {
    let titleKey: String
    let detailText: String
    let primaryKey: String
    let primaryIcon: String

    init(error: SmartCareError) {
        switch error {
        case .scanFailed(let message):
            titleKey = "smart_care.failure.scan.title"
            detailText = String(
                format: String(localized: "smart_care.failure.scan.detail %@", bundle: .module),
                message
            )
            primaryKey = "smart_care.action.retry_scan"
            primaryIcon = "arrow.counterclockwise"
        case .cleanFailed(let message):
            titleKey = "smart_care.failure.clean.title"
            detailText = String(
                format: String(localized: "smart_care.failure.clean.detail %@", bundle: .module),
                message
            )
            primaryKey = "smart_care.action.review_cleanup_again"
            primaryIcon = "doc.text.magnifyingglass"
        }
    }
}

extension SmartCareScanLimitationProjection {
    var titleText: String {
        String(
            format: String(localized: "smart_care.scan_limitations.title %lld", bundle: .module),
            Int64(totalCount)
        )
    }

    var remainingText: String? {
        guard remainingCount > 0 else { return nil }
        return String(
            format: String(localized: "smart_care.scan_limitations.remaining %lld", bundle: .module),
            Int64(remainingCount)
        )
    }
}

struct SmartCareDashboardView: View {
    let coordinator: SmartCareCoordinator
    let session: SmartCareSession?
    let aiIsConfigured: Bool
    let aiIsRunning: Bool
    let aiProcessed: Int
    let aiTotal: Int
    let aiError: String?
    let aiItemStates: [String: SmartCareAIItemState]
    let aiReportAvailable: Bool
    let onPrimaryAction: (SmartCarePrimaryAction) -> Void
    let onAIReview: () -> Void
    let onAICancel: () -> Void
    let onAIShowReport: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resultExpansion: SmartCareResultExpansion?
    @State private var scanLimitationsExpanded = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            SmartCareAmbientMotionView(mode: motionMode, reduceMotion: reduceMotion)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            SmartCareBackgroundShaderView(
                mode: backgroundMode,
                reduceMotion: reduceMotion
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Group {
                switch coordinator.phase {
                case .idle:
                    idleExperience
                case .scanning(let progress):
                    scanningExperience(progress)
                case .reviewing, .confirming:
                    resultExperience
                case .cleaning(let progress):
                    cleaningExperience(progress)
                case .completed(let result):
                    completedExperience(result)
                case .failed(let error):
                    failedExperience(error)
                case .cancelled:
                    cancelledExperience
                }
            }
            .id(phaseID)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.992)))
        }
        .animation(.smooth(duration: reduceMotion ? 0.12 : 0.36), value: phaseID)
        .onChange(of: phaseID) { _, newValue in
            if newValue != "result" {
                resultExpansion = nil
                scanLimitationsExpanded = false
            }
        }
    }

    private var idleExperience: some View {
        SmartCareIdleVisual(
            selectedStages: session?.selectedStages ?? Set(SmartCareSession.defaultStages),
            reduceMotion: reduceMotion,
            onToggleStage: { stage, selected in
                session?.setStage(stage, selected: selected)
            },
            onScan: { onPrimaryAction(.startScan) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
    }

    private func scanningExperience(_ progress: SmartCareProgress) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 18)

            Text("smart_care.visual.scanning_badge", bundle: .module)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(0.78),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1))

            SmartCareWorkingVisual(
                mode: .scanning(bytes: progress.safeBytes),
                reduceMotion: reduceMotion
            )
            .frame(width: 270, height: 270)

            SmartCareActivityBadge(
                activity: progress.activity,
                reduceMotion: reduceMotion
            )

            SmartCareStageStrip(progress: progress, reduceMotion: reduceMotion)
                .frame(maxWidth: 700)

            Button {
                onPrimaryAction(.stopScan)
            } label: {
                Label {
                    Text("smart_care.action.stop_scan", bundle: .module)
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .frame(minWidth: 118)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.84),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 22)
    }

    private var resultExperience: some View {
        VStack(spacing: 16) {
            resultHeader

            ScrollView {
                VStack(spacing: 10) {
                    if !scanLimitations.isEmpty {
                        scanLimitationsNotice
                    }

                    if !resultBuckets.isEmpty {
                        categorySelectionList
                    }

                    if !coordinator.summary.confirmItems.isEmpty
                        || !coordinator.summary.forbidItems.isEmpty {
                        riskSelectionList
                    }

                    if let aiSummaryText {
                        Label {
                            Text(verbatim: aiSummaryText)
                        } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if let aiError, !aiError.isEmpty {
                        Label {
                            Text(verbatim: aiError)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundStyle(SmartCarePresentation.tint(for: .confirm))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: 940)
            .frame(maxHeight: resultExpansion == nil ? 382 : .infinity)

            resultActions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private var resultHeader: some View {
        let hasLimitations = !scanLimitations.isEmpty
        let headerTint = hasLimitations
            ? SmartCarePresentation.tint(for: .confirm)
            : SmartCarePresentation.tint(for: .safe)
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: hasLimitations ? "exclamationmark.shield.fill" : "checkmark.circle.fill")
                        .foregroundStyle(headerTint)
                    Text(
                        hasLimitations
                            ? "smart_care.result.scan_limited"
                            : "smart_care.result.scan_complete",
                        bundle: .module
                    )
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    headerTint.opacity(0.1),
                    in: Capsule()
                )

                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(verbatim: formattedSmartCareBytes(coordinator.selectedBytes))
                        .font(.system(
                            size: resultExpansion == nil ? 44 : 35,
                            weight: .bold,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("smart_care.metric.selected", bundle: .module)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    SmartCareMetricLabel(
                        icon: "checkmark.shield.fill",
                        value: coordinator.summary.safeBytes,
                        labelKey: "smart_care.metric.safe",
                        tint: SmartCarePresentation.tint(for: .safe)
                    )
                    if coordinator.summary.confirmBytes > 0 {
                        SmartCareMetricLabel(
                            icon: "exclamationmark.triangle.fill",
                            value: coordinator.summary.confirmBytes,
                            labelKey: "smart_care.metric.confirm",
                            tint: SmartCarePresentation.tint(for: .confirm)
                        )
                    }
                    if coordinator.summary.forbidBytes > 0 {
                        SmartCareMetricLabel(
                            icon: "lock.shield.fill",
                            value: coordinator.summary.forbidBytes,
                            labelKey: "smart_care.metric.protected",
                            tint: SmartCarePresentation.tint(for: .forbid)
                        )
                    }
                }
            }

            Spacer(minLength: 16)

            SmartCareResultRing(
                safeBytes: coordinator.summary.safeBytes,
                confirmBytes: coordinator.summary.confirmBytes,
                selectedBytes: coordinator.selectedBytes
            )
            .frame(width: resultExpansion == nil ? 146 : 106, height: resultExpansion == nil ? 146 : 106)

            SmartCareScanAgainButton(reduceMotion: reduceMotion) {
                onPrimaryAction(.scanAgain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, resultExpansion == nil ? 17 : 11)
        .frame(maxWidth: 940)
        .frame(height: resultExpansion == nil ? 188 : 138)
        .smartCareTechSurface(
            tint: SmartCareMotionPalette.blueColor,
            cornerRadius: 18,
            elevated: true
        )
        .animation(.smooth(duration: reduceMotion ? 0.1 : 0.24), value: resultExpansion)
    }

    private var categorySelectionList: some View {
        VStack(spacing: 10) {
            ForEach(resultBuckets, id: \.id) { bucket in
                let selectedStats = coordinator.selectedSafeBucketStats[bucket.id]
                    ?? SmartCareBucketSelectionStats()
                SmartCareCategorySection(
                    bucket: bucket,
                    selectedIDs: coordinator.selection.selectedIDs,
                    selectedBytes: selectedStats.bytes,
                    aiItemStates: aiItemStates,
                    isExpanded: expansionBinding(for: .bucket(bucket.id)),
                    onToggleAll: { selected in
                        Task { @MainActor in
                            await coordinator.setSafeItemsSelected(selected, bucketID: bucket.id)
                        }
                    },
                    onToggleItem: { selected, item in
                        _ = coordinator.setSelected(selected, item: item)
                    }
                )
            }
        }
    }

    private var riskSelectionList: some View {
        VStack(spacing: 10) {
            if !coordinator.summary.confirmItems.isEmpty {
                SmartCareRiskSection(
                    kind: .confirm,
                    bytes: coordinator.summary.confirmBytes,
                    items: coordinator.summary.confirmItems,
                    selectedIDs: coordinator.selection.selectedIDs,
                    aiItemStates: aiItemStates,
                    isExpanded: expansionBinding(for: .needsReview),
                    onToggleItem: { selected, item in
                        _ = coordinator.setSelected(selected, item: item)
                    }
                )
            }

            if !coordinator.summary.forbidItems.isEmpty {
                SmartCareRiskSection(
                    kind: .protectedItems,
                    bytes: coordinator.summary.forbidBytes,
                    items: coordinator.summary.forbidItems,
                    selectedIDs: [],
                    aiItemStates: aiItemStates,
                    isExpanded: expansionBinding(for: .protectedItems),
                    onToggleItem: { _, _ in }
                )
            }
        }
    }

    private var resultActions: some View {
        HStack(spacing: 10) {
            Button {
                onPrimaryAction(.cleanSafeItems)
            } label: {
                Label {
                    Text("smart_care.action.review_cleanup", bundle: .module)
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .frame(minWidth: 158)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!coordinator.hasSelection || aiIsRunning)

            Button(action: aiIsRunning ? onAICancel : onAIReview) {
                if aiIsRunning {
                    Label {
                        HStack(spacing: 6) {
                            Text("smart_care.ai.cancel", bundle: .module)
                            Text(verbatim: aiProgressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "stop.circle.fill")
                    }
                } else {
                    Label {
                        Text("smart_care.ai.review", bundle: .module)
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(Text(
                aiIsRunning
                    ? "smart_care.ai.cancel_help"
                    : (aiIsConfigured
                        ? "smart_care.ai.help"
                        : "smart_care.ai.help.not_configured"),
                bundle: .module
            ))

            if aiReportAvailable {
                Button(action: onAIShowReport) {
                    Label {
                        Text("smart_care.ai.view_report", bundle: .module)
                    } icon: {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(SmartCarePresentation.tint(for: .safe))
                .help(Text("smart_care.ai.view_report_help", bundle: .module))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.72),
                    SmartCareMotionPalette.blueColor.opacity(0.07),
                    SmartCareMotionPalette.tealColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: SmartCareMotionPalette.blueColor.opacity(0.08), radius: 12, y: 4)
        .frame(maxWidth: 940)
    }

    private func cleaningExperience(_: SmartCareCleanProgress) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 28)

            SmartCareWorkingVisual(
                mode: .cleaning,
                reduceMotion: reduceMotion
            )
            .frame(width: 242, height: 242)

            Text("smart_care.activity.cleaning", bundle: .module)
                .font(.system(.title2, design: .rounded).weight(.semibold))

            Text("smart_care.visual.moving_to_trash", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func completedExperience(_ result: SmartCareResult) -> some View {
        let isPartial = result.completion == .partial
        let tint = isPartial
            ? SmartCarePresentation.tint(for: .confirm)
            : SmartCarePresentation.tint(for: .safe)

        return VStack(spacing: 14) {
            Spacer(minLength: 28)

            Image(systemName: isPartial ? "exclamationmark.circle" : "checkmark")
                .font(.system(size: 92, weight: .light))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: result)

            Text(
                isPartial ? "smart_care.phase.partial" : "smart_care.phase.completed",
                bundle: .module
            )
                .font(.system(.title, design: .rounded).weight(.semibold))

            Text(completionDetail(for: result))
                .font(.callout)
                .foregroundStyle(.secondary)

            if isPartial {
                HStack(spacing: 10) {
                    Button {
                        onPrimaryAction(.cleanSafeItems)
                    } label: {
                        Label {
                            Text("smart_care.action.retry_remaining", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .frame(minWidth: 142)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(tint)

                    Button {
                        onPrimaryAction(.scanAgain)
                    } label: {
                        Label {
                            Text("smart_care.action.scan_again", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .frame(minWidth: 124)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                Button {
                    onPrimaryAction(.scanAgain)
                } label: {
                    Label {
                        Text("smart_care.action.scan_again", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .frame(minWidth: 124)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func completionDetail(for result: SmartCareResult) -> String {
        if result.completion == .partial {
            return String(
                format: String(
                    localized: "smart_care.detail.partial %lld %lld %@",
                    bundle: .module
                ),
                Int64(result.movedCount),
                Int64(result.skippedCount),
                formattedSmartCareBytes(result.releasedBytes)
            )
        }
        return String(
            format: String(localized: "smart_care.detail.completed %lld %@", bundle: .module),
            Int64(result.movedCount),
            formattedSmartCareBytes(result.releasedBytes)
        )
    }

    private func failedExperience(_ error: SmartCareError) -> some View {
        let presentation = SmartCareFailurePresentation(error: error)
        return SmartCareRecoveryView(
            icon: "exclamationmark.triangle",
            titleKey: presentation.titleKey,
            detailKey: "smart_care.detail.failed",
            detailText: presentation.detailText,
            primaryKey: presentation.primaryKey,
            primaryIcon: presentation.primaryIcon,
            tint: SmartCarePresentation.tint(for: .confirm),
            primaryAction: { onPrimaryAction(.retry) },
            secondaryKey: "smart_care.action.start_over",
            secondaryAction: { onPrimaryAction(.scanAgain) }
        )
    }

    private var cancelledExperience: some View {
        SmartCareRecoveryView(
            icon: "pause.circle",
            titleKey: "smart_care.phase.cancelled",
            detailKey: "smart_care.detail.cancelled",
            primaryKey: "smart_care.action.continue_scan",
            primaryIcon: "play.fill",
            tint: .secondary,
            primaryAction: { onPrimaryAction(.continueScan) },
            secondaryKey: "smart_care.action.scan_again",
            secondaryAction: { onPrimaryAction(.scanAgain) }
        )
    }

    private var resultBuckets: [SmartCareBucketSummary] {
        let byID = Dictionary(uniqueKeysWithValues: coordinator.summary.buckets.map { ($0.id, $0) })
        return SmartCarePresentation.normalBuckets.compactMap { bucketID in
            guard let bucket = byID[bucketID], !bucket.safeItems.isEmpty else { return nil }
            return bucket
        }
    }

    private var scanLimitations: SmartCareScanLimitationProjection {
        session?.scanLimitationProjection ?? .empty
    }

    private var scanLimitationsNotice: some View {
        DisclosureGroup(isExpanded: $scanLimitationsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(scanLimitations.displayedPaths, id: \.self) { path in
                    Text(verbatim: path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let remainingText = scanLimitations.remainingText {
                    Text(verbatim: remainingText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(SmartCarePresentation.tint(for: .confirm))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: scanLimitations.titleText)
                        .font(.callout.weight(.semibold))
                    Text("smart_care.scan_limitations.detail", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(
            SmartCarePresentation.tint(for: .confirm).opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    SmartCarePresentation.tint(for: .confirm).opacity(0.22),
                    lineWidth: 1
                )
        )
    }

    private func expansionBinding(for target: SmartCareResultExpansion) -> Binding<Bool> {
        Binding(
            get: { resultExpansion == target },
            set: { expanded in
                withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.22)) {
                    resultExpansion = expanded ? target : nil
                }
            }
        )
    }

    private var aiProgressText: String {
        String(
            format: String(localized: "smart_care.ai.progress %lld %lld", bundle: .module),
            Int64(aiProcessed),
            Int64(aiTotal)
        )
    }

    private var aiSummaryText: String? {
        if aiIsRunning { return aiProgressText }
        var safe = 0
        var review = 0
        var avoid = 0
        for state in aiItemStates.values {
            guard case .advice(let verdict, _) = state else { continue }
            switch verdict {
            case .safe: safe += 1
            case .confirm: review += 1
            case .forbid: avoid += 1
            }
        }
        guard safe + review + avoid > 0 else { return nil }
        return String(
            format: String(localized: "smart_care.ai.summary %lld %lld %lld", bundle: .module),
            Int64(safe),
            Int64(review),
            Int64(avoid)
        )
    }

    private var phaseID: String {
        switch coordinator.phase {
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .reviewing, .confirming: return "result"
        case .cleaning: return "cleaning"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private var motionMode: SmartCareMotionMode {
        switch coordinator.phase {
        case .idle, .failed, .cancelled:
            return .idle
        case .scanning:
            return .scanning
        case .reviewing, .confirming:
            return .complete
        case .cleaning:
            return .cleaning
        case .completed:
            return .complete
        }
    }

    private var backgroundMode: SmartCareBackgroundMode {
        SmartCareBackgroundMode.mode(for: coordinator.phase)
    }
}

private enum SmartCareResultExpansion: Hashable {
    case bucket(SmartCareBucketID)
    case needsReview
    case protectedItems
}

private struct SmartCareIdleVisual: View {
    let selectedStages: Set<SmartCareScanStage>
    let reduceMotion: Bool
    let onToggleStage: (SmartCareScanStage, Bool) -> Void
    let onScan: () -> Void
    @State private var scanHovered = false
    @State private var cardsRevealed = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Text("smart_care.visual.ready", bundle: .module)
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text(verbatim: scopeSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                SmartCareCoreMotionView(mode: .idle, reduceMotion: reduceMotion)
                    .frame(width: 270, height: 270)

                Button(action: onScan) {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 30, weight: .semibold))
                        Text("smart_care.action.start_scan", bundle: .module)
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 144, height: 144)
                    .background(
                        canScan ? Color.accentColor : Color.secondary.opacity(0.48),
                        in: Circle()
                    )
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                    .shadow(
                        color: canScan ? Color.accentColor.opacity(scanHovered ? 0.34 : 0.22) : .clear,
                        radius: scanHovered ? 24 : 16,
                        y: 8
                    )
                    .scaleEffect(scanHovered && canScan && !reduceMotion ? 1.035 : 1)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help(Text("smart_care.action.start_scan", bundle: .module))
                .disabled(!canScan)
                .onHover { scanHovered = $0 }
                .animation(.smooth(duration: 0.18), value: scanHovered)
            }
            .frame(width: 280, height: 280)

            HStack(spacing: 12) {
                ForEach(Array(SmartCareSession.defaultStages.enumerated()), id: \.element) { index, stage in
                    SmartCareScopeButton(
                        stage: stage,
                        selected: selectedStages.contains(stage),
                        revealed: cardsRevealed,
                        sequenceIndex: index,
                        reduceMotion: reduceMotion,
                        onToggle: { onToggleStage(stage, !selectedStages.contains(stage)) }
                    )
                }
            }
            .frame(maxWidth: 900)
            .onAppear { cardsRevealed = true }
            .onDisappear { cardsRevealed = false }

            Label {
                Text("smart_care.visual.safety_note", bundle: .module)
            } icon: {
                Image(systemName: "shield.checkered")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canScan: Bool {
        !selectedStages.isEmpty
    }

    private var scopeSummary: String {
        guard canScan else {
            return String(localized: "smart_care.scope.none_selected", bundle: .module)
        }
        return String(
            format: String(localized: "smart_care.scope.selected_count %lld", bundle: .module),
            Int64(selectedStages.count)
        )
    }
}

enum SmartCareScopeCardSilhouette: Hashable {
    case forwardCut
    case crossCut
    case trailingCut

    init(stage: SmartCareScanStage) {
        switch stage {
        case .core: self = .forwardCut
        case .appCaches: self = .crossCut
        case .developerCaches: self = .trailingCut
        }
    }
}

struct SmartCareScopeCardShape: Shape {
    let silhouette: SmartCareScopeCardSilhouette

    func path(in rect: CGRect) -> Path {
        let radius = min(8, rect.height * 0.16)
        let cut = min(18, rect.width * 0.09)
        let width = rect.width
        let height = rect.height
        var path = Path()

        switch silhouette {
        case .forwardCut:
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: width - cut, y: 0))
            path.addLine(to: CGPoint(x: width, y: cut))
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addQuadCurve(
                to: CGPoint(x: width - radius, y: height),
                control: CGPoint(x: width, y: height)
            )
            path.addLine(to: CGPoint(x: radius, y: height))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: height - radius),
                control: CGPoint(x: 0, y: height)
            )
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)

        case .crossCut:
            path.move(to: CGPoint(x: cut, y: 0))
            path.addLine(to: CGPoint(x: width - radius, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: width, y: radius),
                control: CGPoint(x: width, y: 0)
            )
            path.addLine(to: CGPoint(x: width, y: height - cut))
            path.addLine(to: CGPoint(x: width - cut, y: height))
            path.addLine(to: CGPoint(x: radius, y: height))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: height - radius),
                control: CGPoint(x: 0, y: height)
            )
            path.addLine(to: CGPoint(x: 0, y: cut))

        case .trailingCut:
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: width - radius, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: width, y: radius),
                control: CGPoint(x: width, y: 0)
            )
            path.addLine(to: CGPoint(x: width, y: height - radius))
            path.addQuadCurve(
                to: CGPoint(x: width - radius, y: height),
                control: CGPoint(x: width, y: height)
            )
            path.addLine(to: CGPoint(x: cut, y: height))
            path.addLine(to: CGPoint(x: 0, y: height - cut))
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        }

        path.closeSubpath()
        return path
    }
}

private struct SmartCareScopeButton: View {
    let stage: SmartCareScanStage
    let selected: Bool
    let revealed: Bool
    let sequenceIndex: Int
    let reduceMotion: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        let tint = SmartCarePresentation.tint(for: stage)
        let shape = SmartCareScopeCardShape(silhouette: SmartCareScopeCardSilhouette(stage: stage))
        Button(action: onToggle) {
            HStack(spacing: 11) {
                Image(systemName: SmartCarePresentation.iconName(for: stage))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(selected ? 0.14 : 0.075), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        LocalizedStringKey(SmartCarePresentation.titleKey(for: stage)),
                        bundle: .module
                    )
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                    Text(
                        LocalizedStringKey(SmartCarePresentation.subtitleKey(for: stage)),
                        bundle: .module
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? tint : Color.secondary.opacity(0.55))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: selected)

                    if let badgeKey = SmartCarePresentation.durationBadgeKey(for: stage) {
                        Label {
                            Text(LocalizedStringKey(badgeKey), bundle: .module)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.1), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)
            .background {
                shape.fill(.regularMaterial)
                shape.fill(tint.opacity(selected ? 0.055 : hovered ? 0.028 : 0))
            }
            .overlay {
                ZStack {
                    shape.stroke(
                        selected ? tint.opacity(hovered ? 0.5 : 0.32) : Color.primary.opacity(hovered ? 0.14 : 0.075),
                        lineWidth: 1
                    )
                    shape
                        .trim(from: 0.015, to: selected ? 0.38 : 0.14)
                        .stroke(
                            tint.opacity(selected ? 0.9 : hovered ? 0.48 : 0.24),
                            style: StrokeStyle(
                                lineWidth: selected ? 2.2 : 1.2,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? (hovered && !reduceMotion ? -3 : 0) : (reduceMotion ? 0 : 14))
        .scaleEffect(hovered && !reduceMotion ? 1.012 : 1)
        .rotation3DEffect(
            .degrees(hovered && !reduceMotion ? 1.4 : 0),
            axis: (x: 0.12, y: hoverTiltAxis, z: 0),
            perspective: 0.28
        )
        .shadow(
            color: tint.opacity(hovered ? 0.16 : selected ? 0.07 : 0),
            radius: hovered ? 12 : 5,
            y: hovered ? 6 : 2
        )
        .onHover { hovered = $0 }
        .animation(entryAnimation, value: revealed)
        .animation(.smooth(duration: 0.2), value: hovered)
        .animation(.snappy(duration: 0.24), value: selected)
        .accessibilityValue(Text(
            selected ? "smart_care.scope.selected" : "smart_care.scope.not_selected",
            bundle: .module
        ))
    }

    private var hoverTiltAxis: CGFloat {
        switch stage {
        case .core: return -1
        case .appCaches: return 0.35
        case .developerCaches: return 1
        }
    }

    private var entryAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.1)
        }
        return .spring(response: 0.46, dampingFraction: 0.8)
            .delay(Double(sequenceIndex) * 0.075)
    }
}

private struct SmartCareAppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(1.34)
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
        }
        .shadow(color: Color.accentColor.opacity(0.2), radius: size * 0.1, y: size * 0.04)
    }
}

private enum SmartCareWorkingVisualMode {
    case scanning(bytes: Int64)
    case cleaning
}

private struct SmartCareWorkingVisual: View {
    let mode: SmartCareWorkingVisualMode
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            SmartCareCoreMotionView(mode: motionMode, reduceMotion: reduceMotion)

            Circle()
                .fill(.regularMaterial)
                .frame(width: 166, height: 166)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

            VStack(spacing: 7) {
                SmartCareAppMark(size: 46)
                primaryReadout
                secondaryReadout
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var primaryReadout: some View {
        switch mode {
        case .scanning(let bytes):
            Text(verbatim: formattedSmartCareBytes(bytes))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        case .cleaning:
            EmptyView()
        }
    }

    @ViewBuilder
    private var secondaryReadout: some View {
        switch mode {
        case .scanning:
            Text("smart_care.visual.safe_so_far", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .cleaning:
            EmptyView()
        }
    }

    private var tint: Color {
        switch mode {
        case .scanning: return Color.accentColor
        case .cleaning: return SmartCarePresentation.tint(for: .safe)
        }
    }

    private var motionMode: SmartCareMotionMode {
        switch mode {
        case .scanning: return .scanning
        case .cleaning: return .cleaning
        }
    }
}

private struct SmartCareTechSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .windowBackgroundColor).opacity(0.66),
                                tint.opacity(0.065),
                                SmartCareMotionPalette.tealColor.opacity(0.025)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .clipShape(shape)
            .overlay {
                ZStack {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                tint.opacity(0.32),
                                Color.primary.opacity(0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    shape
                        .trim(from: 0.015, to: 0.22)
                        .stroke(
                            tint.opacity(0.6),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                        )
                }
            }
            .shadow(
                color: tint.opacity(elevated ? 0.12 : 0.055),
                radius: elevated ? 18 : 8,
                y: elevated ? 8 : 3
            )
    }
}

private extension View {
    func smartCareTechSurface(tint: Color,
                              cornerRadius: CGFloat,
                              elevated: Bool) -> some View {
        modifier(SmartCareTechSurfaceModifier(
            tint: tint,
            cornerRadius: cornerRadius,
            elevated: elevated
        ))
    }
}

private struct SmartCareMetricLabel: View {
    let icon: String
    let value: Int64
    let labelKey: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: formattedSmartCareBytes(value))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(LocalizedStringKey(labelKey), bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct SmartCareResultRing: View {
    let safeBytes: Int64
    let confirmBytes: Int64
    let selectedBytes: Int64

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(9, size * 0.085)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.075), lineWidth: lineWidth)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                SmartCareMotionPalette.blueColor.opacity(0.42),
                                SmartCareMotionPalette.tealColor.opacity(0.2),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .padding(lineWidth * -0.72)

                Circle()
                    .trim(from: 0, to: safeFraction)
                    .stroke(
                        SmartCarePresentation.tint(for: .safe),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                if confirmFraction > 0.01 {
                    Circle()
                        .trim(
                            from: min(0.98, safeFraction + 0.018),
                            to: min(1, safeFraction + confirmFraction)
                        )
                        .stroke(
                            SmartCarePresentation.tint(for: .confirm),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                VStack(spacing: 2) {
                    Text(verbatim: formattedSmartCareBytes(selectedBytes))
                        .font(.system(
                            size: size >= 120 ? 24 : 17,
                            weight: .bold,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Text("smart_care.metric.selected", bundle: .module)
                        .font(size >= 120 ? .caption : .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, lineWidth + 4)
            }
        }
    }

    private var safeFraction: CGFloat {
        let total = max(1, safeBytes + confirmBytes)
        return CGFloat(Double(safeBytes) / Double(total))
    }

    private var confirmFraction: CGFloat {
        let total = max(1, safeBytes + confirmBytes)
        return CGFloat(Double(confirmBytes) / Double(total))
    }
}

private struct SmartCareScanAgainButton: View {
    let reduceMotion: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SmartCareMotionPalette.blueColor)
                    .frame(width: 28, height: 28)
                    .background(
                        SmartCareMotionPalette.blueColor.opacity(hovered ? 0.16 : 0.1),
                        in: Circle()
                    )
                    .rotationEffect(.degrees(hovered && !reduceMotion ? -22 : 0))

                Text("smart_care.action.scan_again", bundle: .module)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(hovered ? SmartCareMotionPalette.blueColor : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                SmartCareMotionPalette.blueColor.opacity(hovered ? 0.15 : 0.09),
                                SmartCareMotionPalette.tealColor.opacity(hovered ? 0.11 : 0.055),
                                Color(nsColor: .windowBackgroundColor).opacity(0.36)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            SmartCareMotionPalette.blueColor.opacity(hovered ? 0.68 : 0.36),
                            SmartCareMotionPalette.tealColor.opacity(hovered ? 0.42 : 0.2),
                            Color.primary.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(
                color: SmartCareMotionPalette.blueColor.opacity(hovered ? 0.18 : 0.08),
                radius: hovered ? 12 : 7,
                y: hovered ? 5 : 3
            )
            .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: reduceMotion ? 0.1 : 0.18), value: hovered)
        .help(Text("smart_care.action.scan_again", bundle: .module))
    }
}

private struct SmartCareActivityBadge: View {
    let activity: SmartCareScanActivity
    let reduceMotion: Bool

    var body: some View {
        let titleKey = SmartCarePresentation.activityTitleKey(for: activity)
        let localizedTitle = String(
            localized: String.LocalizationValue(titleKey),
            bundle: .module
        )
        let activityTint = activity.stage.map(SmartCarePresentation.tint(for:))
            ?? SmartCarePresentation.tint(for: SafetyVerdict.safe)
        HStack(spacing: 9) {
            Image(systemName: SmartCarePresentation.activityIconName(for: activity))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(activityTint)
                .frame(width: 28, height: 28)
                .background(activityTint.opacity(0.1), in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: activity)
                .accessibilityHidden(true)

            SmartCareAnimatedActivityTextView(
                text: localizedTitle,
                activity: activity,
                reduceMotion: reduceMotion
            )
            .fixedSize()
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.86),
                    SmartCareMotionPalette.blueColor.opacity(0.08),
                    SmartCareMotionPalette.tealColor.opacity(0.055)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(activityTint.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: activityTint.opacity(0.07), radius: 9, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(titleKey), bundle: .module))
    }
}

enum SmartCareStageVisualStatus: Equatable {
    case pending
    case active
    case complete
}

enum SmartCareStageProgressPresentation {
    static func status(for stage: SmartCareScanStage,
                       in progress: SmartCareProgress) -> SmartCareStageVisualStatus {
        if progress.completedStages.contains(stage) { return .complete }
        if progress.activity.stage == stage { return .active }
        return .pending
    }

    static func connectorStatus(after stage: SmartCareScanStage,
                                in progress: SmartCareProgress) -> SmartCareStageVisualStatus {
        if progress.completedStages.contains(stage) { return .complete }
        if progress.activity.stage == stage { return .active }
        return .pending
    }

    static func finalStatus(in progress: SmartCareProgress) -> SmartCareStageVisualStatus {
        progress.activity == .finalizing ? .active : .pending
    }
}

private struct SmartCareStageStrip: View {
    let progress: SmartCareProgress
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(progress.plannedStages.enumerated()), id: \.element) { index, stage in
                stageNode(stage)
                if index < progress.plannedStages.count - 1 {
                    connector(status: SmartCareStageProgressPresentation.connectorStatus(
                        after: stage,
                        in: progress
                    ))
                }
            }
            if let finalPlannedStage = progress.plannedStages.last {
                connector(status: SmartCareStageProgressPresentation.connectorStatus(
                    after: finalPlannedStage,
                    in: progress
                ))
            }
            finalNode
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .smartCareTechSurface(
            tint: SmartCareMotionPalette.blueColor,
            cornerRadius: 14,
            elevated: false
        )
    }

    private func connector(status: SmartCareStageVisualStatus) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(status == .active
                      ? SmartCareMotionPalette.blueColor.opacity(0.16)
                      : Color.secondary.opacity(0.16))

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            SmartCarePresentation.tint(for: .safe).opacity(0.58),
                            SmartCareMotionPalette.tealColor.opacity(0.72)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .scaleEffect(x: status == .complete ? 1 : 0, anchor: .leading)

            SmartCareSignalBeamView(
                isActive: status == .active,
                reduceMotion: reduceMotion
            )
            .opacity(status == .active ? 1 : 0)
        }
        .frame(minWidth: 28, maxWidth: 72)
        .frame(height: 3)
        .animation(
            .smooth(duration: reduceMotion ? 0.1 : 0.42),
            value: status
        )
        .accessibilityHidden(true)
    }

    private func stageNode(_ stage: SmartCareScanStage) -> some View {
        let status = SmartCareStageProgressPresentation.status(for: stage, in: progress)
        return VStack(spacing: 6) {
            stageDot(status: status, icon: SmartCarePresentation.iconName(for: stage))
            Text(LocalizedStringKey(SmartCarePresentation.titleKey(for: stage)), bundle: .module)
                .font(.caption2.weight(status == .active ? .semibold : .regular))
                .foregroundStyle(status == .pending ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(minWidth: 96)
    }

    private var finalNode: some View {
        let status = SmartCareStageProgressPresentation.finalStatus(in: progress)
        return VStack(spacing: 6) {
            stageDot(status: status, icon: "checkmark.shield")
            Text("smart_care.stage.final_check", bundle: .module)
                .font(.caption2.weight(status == .active ? .semibold : .regular))
                .foregroundStyle(status == .pending ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(minWidth: 96)
    }

    @ViewBuilder
    private func stageDot(status: SmartCareStageVisualStatus, icon: String) -> some View {
        ZStack {
            SmartCareStagePulseView(
                isActive: status == .active,
                reduceMotion: reduceMotion
            )
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            Circle()
                .fill(tint(for: status).opacity(status == .pending ? 0.07 : 0.13))
                .frame(width: 30, height: 30)
            Circle()
                .strokeBorder(
                    tint(for: status).opacity(status == .active ? 0.34 : 0.08),
                    lineWidth: status == .active ? 2 : 1
                )
                .frame(width: 30, height: 30)
            switch status {
            case .active:
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint(for: status))
            case .complete:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint(for: status))
                    .symbolEffect(.bounce, value: status)
            case .pending:
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 40, height: 40)
        .scaleEffect(status == .active && !reduceMotion ? 1.03 : 1)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.1)
                : .spring(response: 0.34, dampingFraction: 0.72),
            value: status
        )
    }

    private func tint(for status: SmartCareStageVisualStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .active: return .accentColor
        case .complete: return SmartCarePresentation.tint(for: .safe)
        }
    }
}

private enum SmartCareSelectionState {
    case none
    case mixed
    case all

    var iconName: String {
        switch self {
        case .none: return "square"
        case .mixed: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }
}

private struct SmartCareSelectionRail: View {
    let fraction: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.065))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.72), SmartCareMotionPalette.tealColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .animation(
            .smooth(duration: reduceMotion ? 0.1 : 0.3),
            value: fraction
        )
        .accessibilityHidden(true)
    }
}

private struct SmartCareCategorySection: View {
    let bucket: SmartCareBucketSummary
    let selectedIDs: Set<SmartCareItem.ID>
    let selectedBytes: Int64
    let aiItemStates: [String: SmartCareAIItemState]
    @Binding var isExpanded: Bool
    let onToggleAll: (Bool) -> Void
    let onToggleItem: (Bool, SmartCareItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    onToggleAll(selectionState != .all)
                } label: {
                    Image(systemName: selectionState.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(selectionState == .none ? Color.secondary : tint)
                        .frame(width: 28, height: 28)
                        .background(
                            tint.opacity(selectionState == .none ? 0.035 : 0.1),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(Text("smart_care.bucket.toggle_safe", bundle: .module))
                .accessibilityLabel(Text("smart_care.bucket.toggle_safe", bundle: .module))
                .accessibilityValue(Text(verbatim: "\(selectedCount) / \(bucket.safeCount)"))

                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: SmartCarePresentation.iconName(for: bucket.id))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 34, height: 34)
                            .background(
                                tint.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                LocalizedStringKey(SmartCarePresentation.titleKey(for: bucket.id)),
                                bundle: .module
                            )
                            .font(.body.weight(.semibold))

                            Text(
                                LocalizedStringKey(SmartCarePresentation.subtitleKey(for: bucket.id)),
                                bundle: .module
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer(minLength: 14)

                        Text(verbatim: selectionSizeText)
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(selectionState == .none ? .secondary : .primary)
                            .contentTransition(.numericText())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.07), in: Capsule())

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 62)

            SmartCareSelectionRail(fraction: selectionFraction, tint: tint)
                .padding(.horizontal, 16)
                .padding(.bottom, 9)

            if isExpanded {
                Divider()
                    .padding(.leading, 58)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(bucket.safeItems.enumerated()), id: \.element.id) { index, item in
                            SmartCareSelectableItemRow(
                                item: item,
                                selected: selectedIDs.contains(item.id),
                                aiState: aiItemStates[item.path],
                                showsRisk: false,
                                onToggle: { onToggleItem($0, item) }
                            )
                            if index < bucket.safeItems.count - 1 {
                                Divider()
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
                .frame(height: expandedHeight)
                .background(tint.opacity(0.035))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .smartCareTechSurface(tint: tint, cornerRadius: 14, elevated: false)
    }

    private var selectedCount: Int {
        bucket.safeItemIDs.intersection(selectedIDs).count
    }

    private var selectionState: SmartCareSelectionState {
        if selectedCount == 0 { return .none }
        if selectedCount == bucket.safeCount { return .all }
        return .mixed
    }

    private var selectionSizeText: String {
        if selectionState == .all {
            return formattedSmartCareBytes(bucket.safeBytes)
        }
        return "\(formattedSmartCareBytes(selectedBytes)) / \(formattedSmartCareBytes(bucket.safeBytes))"
    }

    private var selectionFraction: Double {
        guard bucket.safeCount > 0 else { return 0 }
        return Double(selectedCount) / Double(bucket.safeCount)
    }

    private var tint: Color {
        SmartCarePresentation.tint(for: bucket.id)
    }

    private var expandedHeight: CGFloat {
        let visibleRows = min(bucket.safeItems.count, 5)
        return max(44, CGFloat(visibleRows * 44 + max(0, visibleRows - 1)))
    }
}

private enum SmartCareRiskSectionKind {
    case confirm
    case protectedItems

    var titleKey: String {
        switch self {
        case .confirm: return "smart_care.metric.confirm"
        case .protectedItems: return "smart_care.metric.protected"
        }
    }

    var iconName: String {
        switch self {
        case .confirm: return "exclamationmark.triangle"
        case .protectedItems: return "lock.shield"
        }
    }

    var verdict: SafetyVerdict {
        switch self {
        case .confirm: return .confirm
        case .protectedItems: return .forbid
        }
    }
}

private struct SmartCareRiskSection: View {
    let kind: SmartCareRiskSectionKind
    let bytes: Int64
    let items: [SmartCareItem]
    let selectedIDs: Set<SmartCareItem.ID>
    let aiItemStates: [String: SmartCareAIItemState]
    @Binding var isExpanded: Bool
    let onToggleItem: (Bool, SmartCareItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: kind.iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(
                            tint.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )

                    Text(LocalizedStringKey(kind.titleKey), bundle: .module)
                        .font(.body.weight(.semibold))

                    Spacer(minLength: 12)

                    Text(verbatim: formattedSmartCareBytes(bytes))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.075), in: Capsule())

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(minHeight: 58)

            if isExpanded {
                Divider()
                    .padding(.leading, 58)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SmartCareSelectableItemRow(
                                item: item,
                                selected: selectedIDs.contains(item.id),
                                aiState: aiItemStates[item.path],
                                showsRisk: true,
                                selectionEnabled: kind == .confirm,
                                onToggle: { onToggleItem($0, item) }
                            )
                            if index < items.count - 1 {
                                Divider()
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
                .frame(height: riskExpandedHeight)
                .background(tint.opacity(0.035))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .smartCareTechSurface(tint: tint, cornerRadius: 14, elevated: false)
    }

    private var tint: Color {
        SmartCarePresentation.tint(for: kind.verdict)
    }

    private var riskExpandedHeight: CGFloat {
        let visibleRows = min(items.count, 4)
        return max(56, CGFloat(visibleRows * 56 + max(0, visibleRows - 1)))
    }
}

private struct SmartCareSelectableItemRow: View {
    let item: SmartCareItem
    let selected: Bool
    let aiState: SmartCareAIItemState?
    let showsRisk: Bool
    var selectionEnabled: Bool = true
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if selectionEnabled {
                Toggle(isOn: Binding(
                    get: { selected },
                    set: { onToggle($0) }
                )) {
                    Text(verbatim: item.title)
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(SmartCarePresentation.tint(for: .forbid))
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(verbatim: item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    SmartCareAIAdviceBadge(state: aiState)
                }

                if showsRisk {
                    riskText
                }
            }

            Spacer(minLength: 12)

            Text(verbatim: formattedSmartCareBytes(item.bytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: showsRisk ? 56 : 44)
    }

    @ViewBuilder
    private var riskText: some View {
        if let key = SmartCarePresentation.defaultRiskKey(for: item) {
            Text(LocalizedStringKey(key), bundle: .module)
                .font(.caption)
                .foregroundStyle(riskTint)
                .lineLimit(1)
        }
    }

    private var riskTint: Color {
        SmartCarePresentation.tint(for: item.verdict)
    }
}

private struct SmartCareAIAdviceBadge: View {
    let state: SmartCareAIItemState?

    @ViewBuilder
    var body: some View {
        switch state {
        case .reviewing:
            ProgressView()
                .controlSize(.mini)
                .help(Text("smart_care.ai.reviewing_item", bundle: .module))
        case .advice(let verdict, let summary):
            Label {
                Text(
                    LocalizedStringKey(SmartCarePresentation.verdictTitleKey(for: verdict)),
                    bundle: .module
                )
            } icon: {
                Image(systemName: "wand.and.stars")
            }
            .font(.caption2)
            .foregroundStyle(SmartCarePresentation.tint(for: verdict))
            .help(Text(verbatim: summary))
        case .failed(let kind):
            Label {
                Text(
                    LocalizedStringKey(SmartCarePresentation.aiFailureSummaryKey(for: kind)),
                    bundle: .module
                )
                .lineLimit(1)
                .truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.caption2)
            .foregroundStyle(SmartCarePresentation.tint(for: .confirm))
            .help(
                Text(
                    LocalizedStringKey(SmartCarePresentation.aiFailureSummaryKey(for: kind)),
                    bundle: .module
                )
            )
        case .pending, nil:
            EmptyView()
        }
    }
}

private struct SmartCareRecoveryView: View {
    let icon: String
    let titleKey: String
    let detailKey: String
    var detailText: String? = nil
    let primaryKey: String
    let primaryIcon: String
    let tint: Color
    let primaryAction: () -> Void
    var secondaryKey: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 28)

            Image(systemName: icon)
                .font(.system(size: 84, weight: .light))
                .foregroundStyle(tint)

            Text(LocalizedStringKey(titleKey), bundle: .module)
                .font(.system(.title, design: .rounded).weight(.semibold))

            Group {
                if let detailText {
                    Text(verbatim: detailText)
                        .textSelection(.enabled)
                } else {
                    Text(LocalizedStringKey(detailKey), bundle: .module)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 760)

            HStack(spacing: 10) {
                Button(action: primaryAction) {
                    Label {
                        Text(LocalizedStringKey(primaryKey), bundle: .module)
                    } icon: {
                        Image(systemName: primaryIcon)
                    }
                    .frame(minWidth: 118)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let secondaryKey, let secondaryAction {
                    Button(action: secondaryAction) {
                        Text(LocalizedStringKey(secondaryKey), bundle: .module)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private func formattedSmartCareBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
