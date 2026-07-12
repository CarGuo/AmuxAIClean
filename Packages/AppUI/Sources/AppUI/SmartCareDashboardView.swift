import AppKit
import SafetyKit
import SwiftUI

struct SmartCareDashboardView: View {
    let coordinator: SmartCareCoordinator
    let session: SmartCareSession?
    let aiIsConfigured: Bool
    let aiIsRunning: Bool
    let aiProcessed: Int
    let aiTotal: Int
    let aiError: String?
    let aiItemStates: [String: SmartCareAIItemState]
    let onPrimaryAction: (SmartCarePrimaryAction) -> Void
    let onAIReview: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resultExpansion: SmartCareResultExpansion?

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
                case .failed:
                    failedExperience
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

            Text(
                LocalizedStringKey(SmartCarePresentation.activityTitleKey(for: progress.activity)),
                bundle: .module
            )
            .font(.system(.title2, design: .rounded).weight(.bold))
            .contentTransition(.opacity)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.78),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            SmartCareStageStrip(progress: progress)
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
        VStack(spacing: 14) {
            resultHeader

            ScrollView {
                VStack(spacing: 12) {
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
            .frame(maxWidth: 900)
            .frame(maxHeight: resultExpansion == nil ? 356 : .infinity)

            resultActions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 36)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private var resultHeader: some View {
        HStack(spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SmartCarePresentation.tint(for: .safe))
                    Text("smart_care.result.scan_complete", bundle: .module)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }

                Text(verbatim: formattedSmartCareBytes(coordinator.selectedBytes))
                    .font(.system(size: resultExpansion == nil ? 42 : 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                HStack(spacing: 14) {
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

            Button {
                onPrimaryAction(.scanAgain)
            } label: {
                Label {
                    Text("smart_care.action.scan_again", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .help(Text("smart_care.action.scan_again", bundle: .module))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, resultExpansion == nil ? 16 : 10)
        .frame(maxWidth: 900)
        .frame(height: resultExpansion == nil ? 184 : 126)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.9),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(.smooth(duration: reduceMotion ? 0.1 : 0.24), value: resultExpansion)
    }

    private var categorySelectionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(resultBuckets.enumerated()), id: \.element.id) { index, bucket in
                if index > 0 {
                    Divider()
                        .padding(.leading, 48)
                }

                let selectedStats = coordinator.selectedSafeBucketStats[bucket.id]
                    ?? SmartCareBucketSelectionStats()
                SmartCareCategorySection(
                    bucket: bucket,
                    selectedIDs: coordinator.selection.selectedIDs,
                    selectedBytes: selectedStats.bytes,
                    aiItemStates: aiItemStates,
                    isExpanded: expansionBinding(for: .bucket(bucket.id)),
                    onToggleAll: { selected in
                        coordinator.setSafeItemsSelected(selected, bucketID: bucket.id)
                    },
                    onToggleItem: { selected, item in
                        _ = coordinator.setSelected(selected, item: item)
                    }
                )
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }

    private var riskSelectionList: some View {
        VStack(spacing: 0) {
            if !coordinator.summary.confirmItems.isEmpty {
                SmartCareRiskSection(
                    kind: .confirm,
                    bytes: coordinator.summary.confirmBytes,
                    items: coordinator.summary.confirmItems,
                    selectedIDs: coordinator.selection.selectedIDs,
                    isExpanded: expansionBinding(for: .needsReview),
                    onToggleItem: { selected, item in
                        _ = coordinator.setSelected(selected, item: item)
                    }
                )
            }

            if !coordinator.summary.confirmItems.isEmpty
                && !coordinator.summary.forbidItems.isEmpty {
                Divider()
                    .padding(.leading, 48)
            }

            if !coordinator.summary.forbidItems.isEmpty {
                SmartCareRiskSection(
                    kind: .protectedItems,
                    bytes: coordinator.summary.forbidBytes,
                    items: coordinator.summary.forbidItems,
                    selectedIDs: [],
                    isExpanded: expansionBinding(for: .protectedItems),
                    onToggleItem: { _, _ in }
                )
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    SmartCarePresentation.tint(for: .confirm).opacity(0.18),
                    lineWidth: 1
                )
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
            .disabled(!coordinator.hasSelection)

            Button(action: onAIReview) {
                if aiIsRunning {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: aiProgressText)
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
            .disabled(aiIsRunning)
            .help(Text(
                aiIsConfigured
                    ? "smart_care.ai.help"
                    : "smart_care.ai.help.not_configured",
                bundle: .module
            ))
        }
        .frame(maxWidth: 900)
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
        VStack(spacing: 14) {
            Spacer(minLength: 28)

            Image(systemName: "checkmark")
                .font(.system(size: 92, weight: .light))
                .foregroundStyle(SmartCarePresentation.tint(for: .safe))
                .symbolEffect(.bounce, value: result.movedCount)

            Text("smart_care.phase.completed", bundle: .module)
                .font(.system(.title, design: .rounded).weight(.semibold))

            Text(String(
                format: String(localized: "smart_care.detail.completed %lld %@", bundle: .module),
                Int64(result.movedCount),
                formattedSmartCareBytes(result.releasedBytes)
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

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

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var failedExperience: some View {
        SmartCareRecoveryView(
            icon: "exclamationmark.triangle",
            titleKey: "smart_care.phase.failed",
            detailKey: "smart_care.detail.failed",
            primaryKey: "smart_care.action.retry",
            primaryIcon: "arrow.counterclockwise",
            tint: SmartCarePresentation.tint(for: .confirm),
            primaryAction: { onPrimaryAction(.retry) }
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
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: formattedSmartCareBytes(value))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(LocalizedStringKey(labelKey), bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
                    Text("smart_care.metric.safe", bundle: .module)
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

private struct SmartCareStageStrip: View {
    let progress: SmartCareProgress

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(progress.plannedStages.enumerated()), id: \.element) { index, stage in
                stageNode(stage)
                if index < progress.plannedStages.count - 1 {
                    connector(completed: progress.completedStages.contains(stage))
                }
            }
            connector(completed: progress.completedStages.count == progress.plannedStages.count)
            finalNode
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func connector(completed: Bool) -> some View {
        Rectangle()
            .fill(completed
                  ? SmartCarePresentation.tint(for: .safe).opacity(0.48)
                  : Color.secondary.opacity(0.18))
            .frame(minWidth: 28, maxWidth: 72)
            .frame(height: 1)
    }

    private func stageNode(_ stage: SmartCareScanStage) -> some View {
        let status = status(for: stage)
        return VStack(spacing: 5) {
            stageDot(status: status, icon: SmartCarePresentation.iconName(for: stage))
            Text(LocalizedStringKey(SmartCarePresentation.titleKey(for: stage)), bundle: .module)
                .font(.caption2)
                .foregroundStyle(status == .pending ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(minWidth: 96)
    }

    private var finalNode: some View {
        let status: StageStatus = progress.activity == .finalizing ? .active : .pending
        return VStack(spacing: 5) {
            stageDot(status: status, icon: "checkmark.shield")
            Text("smart_care.stage.final_check", bundle: .module)
                .font(.caption2)
                .foregroundStyle(status == .pending ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(minWidth: 96)
    }

    @ViewBuilder
    private func stageDot(status: StageStatus, icon: String) -> some View {
        ZStack {
            Circle()
                .fill(status.tint.opacity(status == .pending ? 0.07 : 0.13))
                .frame(width: 28, height: 28)
            switch status {
            case .active:
                Circle()
                    .fill(status.tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(status.tint.opacity(0.24), lineWidth: 5))
            case .complete:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(status.tint)
            case .pending:
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func status(for stage: SmartCareScanStage) -> StageStatus {
        if progress.completedStages.contains(stage) { return .complete }
        if progress.activity.stage == stage { return .active }
        return .pending
    }

    private enum StageStatus: Equatable {
        case pending
        case active
        case complete

        var tint: Color {
            switch self {
            case .pending: return .secondary
            case .active: return .accentColor
            case .complete: return SmartCarePresentation.tint(for: .safe)
            }
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
                        .foregroundStyle(selectionState == .none ? Color.secondary : Color.accentColor)
                        .frame(width: 24, height: 24)
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
                            .foregroundStyle(SmartCarePresentation.tint(for: bucket.id))
                            .frame(width: 26, height: 26)
                            .background(
                                SmartCarePresentation.tint(for: bucket.id).opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )

                        Text(
                            LocalizedStringKey(SmartCarePresentation.titleKey(for: bucket.id)),
                            bundle: .module
                        )
                        .font(.body.weight(.medium))

                        Spacer(minLength: 14)

                        Text(verbatim: selectionSizeText)
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(selectionState == .none ? .secondary : .primary)
                            .contentTransition(.numericText())

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)

            if isExpanded {
                Divider()
                    .padding(.leading, 48)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(bucket.safeItems.enumerated()), id: \.element.id) { index, item in
                            SmartCareSelectableItemRow(
                                item: item,
                                selected: selectedIDs.contains(item.id),
                                aiState: aiItemStates[item.id],
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
                .background(Color(nsColor: .textBackgroundColor).opacity(0.34))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
                        .frame(width: 24)

                    Text(LocalizedStringKey(kind.titleKey), bundle: .module)
                        .font(.body.weight(.medium))

                    Spacer(minLength: 12)

                    Text(verbatim: formattedSmartCareBytes(bytes))
                        .font(.body.monospacedDigit().weight(.semibold))

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)

            if isExpanded {
                Divider()
                    .padding(.leading, 48)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SmartCareSelectableItemRow(
                                item: item,
                                selected: selectedIDs.contains(item.id),
                                aiState: nil,
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
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
                Toggle("", isOn: Binding(
                    get: { selected },
                    set: { onToggle($0) }
                ))
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
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(SmartCarePresentation.tint(for: .confirm))
                .help(Text("smart_care.ai.item_failed", bundle: .module))
        case .pending, nil:
            EmptyView()
        }
    }
}

private struct SmartCareRecoveryView: View {
    let icon: String
    let titleKey: String
    let detailKey: String
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

            Text(LocalizedStringKey(detailKey), bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
