import SwiftUI

public enum UserGuidePresentationTrigger: Sendable, Equatable {
    case automaticFirstLaunch
    case manual
}

public enum UserGuidePresentationPolicy {
    public static func shouldAutoPresentOnLaunch(
        userGuideCompleted: Bool,
        hasEvaluatedInitialUserGuide: Bool,
        hasConflictingModal: Bool,
        isRunningTests: Bool = false
    ) -> Bool {
        !userGuideCompleted && !hasEvaluatedInitialUserGuide && !hasConflictingModal && !isRunningTests
    }
}

// v2026.10.10 product correction: onboarding teaches the controls in the current window.
// Feature cards/pages are removed. Targets are semantic view registrations, never screen coordinates.
enum ControlGuideTarget: String, CaseIterable, Sendable {
    case interfaceMode, analyze, analysisScope, analysisScan, clean, optimize, status
    case sidebarOperations, diskCapacity, scanCategory, largeFiles, recommendedCleanup, customPaths, libraryBrowsing, fullDisk
    case professionalTools, duplicates, maintenance, brew, workflows
    case pathInput, rescan, resultsMode, deleteSelection, stash, history, reopenGuide

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
        case .largeFiles: "user_guide.control.large_files.title"
        case .recommendedCleanup: "user_guide.control.recommended.title"
        case .customPaths: "user_guide.control.custom.title"
        case .libraryBrowsing: "user_guide.control.library.title"
        case .fullDisk: "user_guide.control.full_disk.title"
        case .professionalTools: "user_guide.control.tools.title"
        case .duplicates: "user_guide.control.duplicates.title"
        case .maintenance: "user_guide.control.maintenance.title"
        case .brew: "user_guide.control.brew.title"
        case .workflows: "user_guide.control.workflows.title"
        case .pathInput: "user_guide.control.path.title"
        case .rescan: "user_guide.control.rescan.title"
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
        case .largeFiles: "user_guide.control.large_files.body"
        case .recommendedCleanup: "user_guide.control.recommended.body"
        case .customPaths: "user_guide.control.custom.body"
        case .libraryBrowsing: "user_guide.control.library.body"
        case .fullDisk: "user_guide.control.full_disk.body"
        case .professionalTools: "user_guide.control.tools.body"
        case .duplicates: "user_guide.control.duplicates.body"
        case .maintenance: "user_guide.control.maintenance.body"
        case .brew: "user_guide.control.brew.body"
        case .workflows: "user_guide.control.workflows.body"
        case .pathInput: "user_guide.control.path.body"
        case .rescan: "user_guide.control.rescan.body"
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
            : [.interfaceMode, .sidebarOperations, .scanCategory, .largeFiles, .recommendedCleanup, .customPaths,
               .libraryBrowsing, .fullDisk, .professionalTools, .duplicates, .history, .maintenance, .brew, .workflows, .diskCapacity, .pathInput,
               .rescan, .resultsMode, .deleteSelection, .stash, .reopenGuide]
        // Contextual controls require real views. Scrollable groups register a semantic
        // reveal action; the controller scrolls them into view before measuring a spotlight.
        return candidates.filter { available.contains($0) }
    }
}

enum ControlGuideEnd: Sendable, Equatable {
    case completed, skipped, contextChanged
    var acknowledgesOnboarding: Bool { self != .contextChanged }
}

struct ControlGuideSession {
    let presentationID: UUID
    let mode: SmartCareInterfaceMode
    let steps: [ControlGuideTarget]
    private(set) var index = 0
    var target: ControlGuideTarget { steps[index] }
    var isLastStep: Bool { index == steps.count - 1 }

    init?(presentationID: UUID, mode: SmartCareInterfaceMode, available: Set<ControlGuideTarget>) {
        let steps = ControlGuideTarget.sequence(mode: mode, available: available)
        guard available.contains(.interfaceMode), !steps.isEmpty else { return nil }
        self.presentationID = presentationID
        self.mode = mode
        self.steps = steps
    }

    mutating func advance() -> Bool {
        guard !isLastStep else { return false }
        index += 1
        return true
    }
}

/// Layout is computed from a real anchor and measured text, including translated wrapping.
/// There is no per-control position table or fixed-height instruction panel.
enum ControlGuideLayout {
    static func bubbleFrame(target: CGRect, size: CGSize, bounds: CGRect) -> CGRect {
        let margin: CGFloat = 16
        let gap: CGFloat = 18
        let area = bounds.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
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
    let focus: CGRect
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        ControlGuideSpotlight(focus: focus) {
            ControlGuideBubble(session: session, onNext: onNext, onSkip: onSkip)
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
                .accessibilityIdentifier("user_guide.next")
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }

}
