import SwiftUI

public enum UserGuidePresentationTrigger: Sendable, Equatable {
    case firstVisit(SmartCareInterfaceMode)
    case manual
}

public enum UserGuidePresentationPolicy {
    public static func shouldAutoPresentOnVisit(
        mode: SmartCareInterfaceMode,
        completedModes: Set<SmartCareInterfaceMode>,
        isRunningTests: Bool = false
    ) -> Bool {
        !completedModes.contains(mode) && !isRunningTests
    }
}

// v2026.10.10 product correction: onboarding teaches the controls in the current window.
// Feature cards/pages are removed. Targets are semantic view registrations, never screen coordinates.
enum ControlGuideTarget: String, CaseIterable, Sendable {
    case interfaceMode, analyze, analysisScope, analysisScan, clean, optimize, status
    case sidebarOperations, diskCapacity, scanCategory, customPaths, professionalTools, workflows
    case pathInput, rescan, rowActions, resultsMode, deleteSelection, stash, history, reopenGuide

    var titleKey: String {
        switch self {
        case .interfaceMode: "user_guide.control.mode.title"
        case .analyze: "user_guide.control.analyze.title"
        case .analysisScope: "user_guide.control.scope.title"
        case .analysisScan: "user_guide.control.scan.title"
        case .clean: "user_guide.control.clean.title"
        case .optimize: "user_guide.control.optimize.title"
        case .status: "user_guide.control.status.title"
        case .sidebarOperations: "user_guide.control.sidebar.title"
        case .diskCapacity: "user_guide.control.capacity.title"
        case .scanCategory: "user_guide.control.category.title"
        case .customPaths: "user_guide.control.custom.title"
        case .professionalTools: "user_guide.control.tools.title"
        case .workflows: "user_guide.control.workflows.title"
        case .pathInput: "user_guide.control.path.title"
        case .rescan: "user_guide.control.rescan.title"
        case .rowActions: "user_guide.control.row_actions.title"
        case .resultsMode: "user_guide.control.results.title"
        case .deleteSelection: "user_guide.control.delete.title"
        case .stash: "user_guide.control.stash.title"
        case .history: "user_guide.control.history.title"
        case .reopenGuide: "user_guide.control.reopen.title"
        }
    }

    var bodyKey: String {
        switch self {
        case .interfaceMode: "user_guide.control.mode.body"
        case .analyze: "user_guide.control.analyze.body"
        case .analysisScope: "user_guide.control.scope.body"
        case .analysisScan: "user_guide.control.scan.body"
        case .clean: "user_guide.control.clean.body"
        case .optimize: "user_guide.control.optimize.body"
        case .status: "user_guide.control.status.body"
        case .sidebarOperations: "user_guide.control.sidebar.body"
        case .diskCapacity: "user_guide.control.capacity.body"
        case .scanCategory: "user_guide.control.category.body"
        case .customPaths: "user_guide.control.custom.body"
        case .professionalTools: "user_guide.control.tools.body"
        case .workflows: "user_guide.control.workflows.body"
        case .pathInput: "user_guide.control.path.body"
        case .rescan: "user_guide.control.rescan.body"
        case .rowActions: "user_guide.control.row_actions.body"
        case .resultsMode: "user_guide.control.results.body"
        case .deleteSelection: "user_guide.control.delete.body"
        case .stash: "user_guide.control.stash.body"
        case .history: "user_guide.control.history.body"
        case .reopenGuide: "user_guide.control.reopen.body"
        }
    }

    static func sequence(mode: SmartCareInterfaceMode, available: Set<Self>) -> [Self] {
        let candidates: [Self] = mode == .normal
            ? [.interfaceMode, .analyze, .analysisScope, .analysisScan, .clean, .optimize, .status, .history, .reopenGuide]
            // v1.6.9 (2026.10.12): teach adjacent sidebar sections together. Row actions are
            // mandatory: the production renderer supplies a demonstration before any scan.
            : [.interfaceMode, .scanCategory, .customPaths, .professionalTools, .workflows,
               .diskCapacity, .pathInput, .rescan, .rowActions, .resultsMode, .deleteSelection, .stash, .reopenGuide]
        // Contextual controls require real views. Scrollable groups register a semantic
        // reveal action; the controller scrolls them into view before measuring a spotlight.
        return candidates.filter { available.contains($0) }
    }

    static func requiredTargets(mode: SmartCareInterfaceMode, showsAnalysisControls: Bool = true) -> Set<Self> {
        // v2026.10.11 review: permanent controls are an interface contract, not whatever
        // happens to have mounted in the first frame. Only result-dependent controls vary.
        let contextOnly: Set<Self> = mode == .normal && !showsAnalysisControls
            ? [.analysisScope, .analysisScan] : []
        return Set(sequence(mode: mode, available: Set(allCases)))
            .subtracting([.resultsMode, .deleteSelection]).subtracting(contextOnly)
    }
}

enum ControlGuideEnd: Sendable, Equatable {
    case completed, skipped, contextChanged
    var acknowledgesOnboarding: Bool { self != .contextChanged }
}

struct ControlGuideSession {
    let presentationID: UUID
    let mode: SmartCareInterfaceMode
    private(set) var steps: [ControlGuideTarget]
    private(set) var index = 0
    var target: ControlGuideTarget { steps[index] }
    var isLastStep: Bool { index == steps.count - 1 }

    init?(presentationID: UUID, mode: SmartCareInterfaceMode, available: Set<ControlGuideTarget>,
          required: Set<ControlGuideTarget> = []) {
        let steps = ControlGuideTarget.sequence(mode: mode, available: available)
        guard required.isSubset(of: available), available.contains(.interfaceMode), !steps.isEmpty else { return nil }
        self.presentationID = presentationID
        self.mode = mode
        self.steps = steps
    }

    mutating func updateInitialAvailability(_ available: Set<ControlGuideTarget>) {
        guard index == 0 else { return }
        steps = ControlGuideTarget.sequence(mode: mode, available: available)
    }

    mutating func advance() -> Bool {
        guard !isLastStep else { return false }
        index += 1
        return true
    }
}

/// v2026.10.11 review: the native controller uses this state directly. Readiness and reveal
/// admission are testable without presenting an NSWindow or manufacturing native focus.
struct ControlGuideProgressState {
    enum Advance: Equatable { case ignored, advanced, completed }
    enum Location: Equatable { case ready, waiting, contextChanged }
    private(set) var session: ControlGuideSession?
    private(set) var isStepReady = false
    private var lastReveal: (target: ControlGuideTarget, layoutRevision: UInt64)?

    mutating func prepare(presentationID: UUID, mode: SmartCareInterfaceMode,
                          available: Set<ControlGuideTarget>, required: Set<ControlGuideTarget>) {
        isStepReady = false
        if session == nil {
            session = ControlGuideSession(presentationID: presentationID, mode: mode,
                                          available: available, required: required)
        } else if available.contains(.interfaceMode), required.isSubset(of: available) {
            session?.updateInitialAvailability(available)
        }
    }

    mutating func shouldReveal(isVisible: Bool, canReveal: Bool, layoutRevision: UInt64) -> Bool {
        guard let target = session?.target, canReveal else { return false }
        // Retry a missing target after actual layout/viewport changes. Repeating an unchanged
        // refresh never retries a no-op scroll; there is no timer or self-sustaining poll loop.
        guard lastReveal?.target != target
                || (!isVisible && lastReveal?.layoutRevision != layoutRevision) else { return false }
        lastReveal = (target, layoutRevision)
        return true
    }

    mutating func locate(isVisible: Bool, canReveal: Bool) -> Location {
        isStepReady = isVisible
        return isVisible ? .ready : (canReveal ? .waiting : .contextChanged)
    }

    mutating func advance() -> Advance {
        guard isStepReady, var session else { return .ignored }
        isStepReady = false
        guard session.advance() else { return .completed }
        self.session = session
        return .advanced
    }

    mutating func suspend() { isStepReady = false }
}

enum ControlGuideAnchorPolicy {
    static func canReveal(_ target: ControlGuideTarget, registered: Set<ControlGuideTarget>,
                          sidebarIsVisible: Bool) -> Bool {
        sidebarIsVisible && registered.contains(target)
    }

    static func available(visible: Set<ControlGuideTarget>, registered: Set<ControlGuideTarget>) -> Set<ControlGuideTarget> {
        visible.contains(.sidebarOperations) ? visible.union(registered) : visible
    }
}

/// Layout is computed from a real anchor and measured text, including translated wrapping.
/// There is no per-control position table or fixed-height instruction panel.
enum ControlGuideLayout {
    static func bubbleFrame(target: CGRect, size: CGSize, bounds: CGRect) -> CGRect {
        let margin: CGFloat = 16
        let gap: CGFloat = 18
        // A zero/small initial layout proposal is valid. Construct a finite viewport rather
        // than insetting past its center, which produces CGRect.null / infinite coordinates.
        let insetX = min(margin, max(0, bounds.width / 2))
        let insetY = min(margin, max(0, bounds.height / 2))
        let area = CGRect(x: bounds.minX + insetX, y: bounds.minY + insetY,
                          width: max(0, bounds.width - 2 * insetX), height: max(0, bounds.height - 2 * insetY))
        let size = CGSize(width: max(0, min(size.width, area.width)), height: max(0, min(size.height, area.height)))
        let centeredX = min(max(target.midX - size.width / 2, area.minX), area.maxX - size.width)
        let centeredY = min(max(target.midY - size.height / 2, area.minY), area.maxY - size.height)
        let below = CGRect(origin: CGPoint(x: centeredX, y: target.maxY + gap), size: size)
        let above = CGRect(origin: CGPoint(x: centeredX, y: target.minY - gap - size.height), size: size)
        let right = CGRect(origin: CGPoint(x: target.maxX + gap, y: centeredY), size: size)
        let left = CGRect(origin: CGPoint(x: target.minX - gap - size.width, y: centeredY), size: size)
        let candidates = target.minX < area.minX + size.width / 2 ? [right, below, above, left] : [below, above, left, right]
        if let fitting = candidates.first(where: { area.contains($0) }) { return fitting }
        // Very small windows still use the measured viewport; never position outside it.
        let best = candidates.max { $0.intersection(area).area < $1.intersection(area).area } ?? below
        return CGRect(x: min(max(best.minX, area.minX), area.maxX - size.width),
                      y: min(max(best.minY, area.minY), area.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private enum ControlGuideCoordinateSpace: Hashable { case window }

/// v2026.10.11 C4: preference feedback initially supplied a zero height, placing a real
/// footer bubble outside the window. Measure and place the same subview in one layout pass.
/// Reference: developer.apple.com/documentation/swiftui/layout (macOS 13+).
private struct ControlGuideBubblePlacement: Layout {
    let target: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let width = min(320, max(0, bounds.width - 32))
        let measured = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let frame = ControlGuideLayout.bubbleFrame(
            target: target.offsetBy(dx: bounds.minX, dy: bounds.minY),
            size: CGSize(width: width, height: measured.height), bounds: bounds)
        content.place(at: frame.origin, anchor: .topLeading,
                      proposal: ProposedViewSize(width: width, height: measured.height))
    }
}

struct ControlGuideOverlay: View {
    let session: ControlGuideSession
    let focus: CGRect?
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        if let focus {
            ControlGuideSpotlight(focus: focus) {
                ControlGuideBubble(session: session, onNext: onNext, onSkip: onSkip)
            }
        } else {
            ControlGuideWaitingOverlay {
                ControlGuideBubble(session: session, isReady: false, onNext: onNext, onSkip: onSkip)
            }
        }
    }
}

struct ControlGuideWaitingOverlay<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.48).contentShape(Rectangle()).onTapGesture {}
            content().frame(maxWidth: 320)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ControlGuidePreparingOverlay: View {
    let onSkip: () -> Void
    var body: some View {
        ControlGuideWaitingOverlay {
            VStack(spacing: 16) {
                ProgressView { Text("user_guide.control.preparing", bundle: .module) }
                Button(action: onSkip) { Text("user_guide.action.skip", bundle: .module) }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("user_guide.skip")
            }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ControlGuideSpotlight<Content: View>: View {
    let focus: CGRect
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let highlight = focus.insetBy(dx: -6, dy: -6).intersection(bounds)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(bounds)
                    path.addRoundedRect(in: highlight, cornerSize: CGSize(width: 9, height: 9))
                }
                .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture { }
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: highlight.width, height: highlight.height)
                    .offset(x: highlight.minX, y: highlight.minY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ControlGuideBubblePlacement(target: highlight) {
                    content()
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { proxy in
                                let bubble = proxy.frame(in: .named(ControlGuideCoordinateSpace.window))
                                connector(from: highlight.offsetBy(dx: -bubble.minX, dy: -bubble.minY),
                                          to: CGRect(origin: .zero, size: proxy.size))
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            }
                            .allowsHitTesting(false).accessibilityHidden(true)
                        }
                }
            }
            .coordinateSpace(name: ControlGuideCoordinateSpace.window)
        }
    }

    private func connector(from focus: CGRect, to bubble: CGRect) -> Path {
        var path = Path()
        if bubble.minY >= focus.maxY {
            path.move(to: CGPoint(x: focus.midX, y: focus.maxY + 3))
            path.addLine(to: CGPoint(x: min(max(focus.midX, bubble.minX + 12), bubble.maxX - 12), y: bubble.minY))
        } else if bubble.maxY <= focus.minY {
            path.move(to: CGPoint(x: focus.midX, y: focus.minY - 3))
            path.addLine(to: CGPoint(x: min(max(focus.midX, bubble.minX + 12), bubble.maxX - 12), y: bubble.maxY))
        } else if bubble.minX >= focus.maxX {
            path.move(to: CGPoint(x: focus.maxX + 3, y: focus.midY))
            path.addLine(to: CGPoint(x: bubble.minX, y: min(max(focus.midY, bubble.minY + 12), bubble.maxY - 12)))
        } else if bubble.maxX <= focus.minX {
            path.move(to: CGPoint(x: focus.minX - 3, y: focus.midY))
            path.addLine(to: CGPoint(x: bubble.maxX, y: min(max(focus.midY, bubble.minY + 12), bubble.maxY - 12)))
        }
        return path
    }
}

struct ControlGuideBubble: View {
    let session: ControlGuideSession
    var isReady = true
    let onNext: () -> Void
    let onSkip: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(session.target.titleKey), bundle: .module)
                .font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("user_guide.step.\(session.target.rawValue)")
            Text(LocalizedStringKey(session.target.bodyKey), bundle: .module)
                .font(.callout).foregroundStyle(.secondary)
            if !isReady { ProgressView { Text("user_guide.control.preparing", bundle: .module) }.controlSize(.small) }
            HStack(spacing: 10) {
                Text(verbatim: AppLocalization.format("user_guide.step.counter %lld %lld", locale: locale,
                     arguments: [Int64(session.index + 1), Int64(session.steps.count)]))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { onSkip() } label: { Text("user_guide.action.skip", bundle: .module) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("user_guide.skip")
                Button { onNext() } label: {
                    if session.isLastStep { Text("user_guide.action.finish", bundle: .module) }
                    else { Text("user_guide.action.next", bundle: .module) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!isReady)
                .accessibilityIdentifier("user_guide.next")
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }

}
