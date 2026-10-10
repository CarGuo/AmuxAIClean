import AppKit
import SwiftUI

public enum UserGuidePresentationTrigger: Sendable, Equatable {
    case automaticFirstLaunch
    case manual
}

public struct UserGuideFeatureCard: Identifiable, Sendable, Equatable {
    public let id: String
    public let icon: String
    public let badgeKey: String
    public let titleKey: String
    public let bodyKey: String
    public let actionFlowKey: String

    public init(
        id: String,
        icon: String,
        badgeKey: String,
        titleKey: String,
        bodyKey: String,
        actionFlowKey: String
    ) {
        self.id = id
        self.icon = icon
        self.badgeKey = badgeKey
        self.titleKey = titleKey
        self.bodyKey = bodyKey
        self.actionFlowKey = actionFlowKey
    }
}

public enum UserGuidePage: String, CaseIterable, Identifiable, Sendable {
    case normalMode = "normal_mode"
    case proNavigation = "pro_navigation"
    case proDeletion = "pro_deletion"
    case proToolbox = "pro_toolbox"

    public var id: String { rawValue }

    public var stepNumber: Int {
        switch self {
        case .normalMode: return 1
        case .proNavigation: return 2
        case .proDeletion: return 3
        case .proToolbox: return 4
        }
    }

    public var isProfessionalTopic: Bool {
        switch self {
        case .normalMode:
            return false
        case .proNavigation, .proDeletion, .proToolbox:
            return true
        }
    }

    public var icon: String {
        switch self {
        case .normalMode: return "sparkles"
        case .proNavigation: return "sidebar.left"
        case .proDeletion: return "trash"
        case .proToolbox: return "wrench.and.screwdriver"
        }
    }

    public var modeBadgeKey: String {
        switch self {
        case .normalMode:
            return "smart_care.mode.normal"
        case .proNavigation, .proDeletion, .proToolbox:
            return "smart_care.mode.professional"
        }
    }

    public var tabTitleKey: String {
        switch self {
        case .normalMode: return "user_guide.page.normal.tab"
        case .proNavigation: return "user_guide.page.pro_nav.tab"
        case .proDeletion: return "user_guide.page.pro_delete.tab"
        case .proToolbox: return "user_guide.page.pro_tools.tab"
        }
    }

    public var titleKey: String {
        switch self {
        case .normalMode: return "user_guide.page.normal.title"
        case .proNavigation: return "user_guide.page.pro_nav.title"
        case .proDeletion: return "user_guide.page.pro_delete.title"
        case .proToolbox: return "user_guide.page.pro_tools.title"
        }
    }

    public var subtitleKey: String {
        switch self {
        case .normalMode: return "user_guide.page.normal.subtitle"
        case .proNavigation: return "user_guide.page.pro_nav.subtitle"
        case .proDeletion: return "user_guide.page.pro_delete.subtitle"
        case .proToolbox: return "user_guide.page.pro_tools.subtitle"
        }
    }

    public var tipKey: String {
        switch self {
        case .normalMode: return "user_guide.page.normal.tip"
        case .proNavigation: return "user_guide.page.pro_nav.tip"
        case .proDeletion: return "user_guide.page.pro_delete.tip"
        case .proToolbox: return "user_guide.page.pro_tools.tip"
        }
    }

    public var previousPage: UserGuidePage? {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx > 0 else { return nil }
        return all[idx - 1]
    }

    public var nextPage: UserGuidePage? {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx + 1 < all.count else { return nil }
        return all[idx + 1]
    }

    public var cards: [UserGuideFeatureCard] {
        switch self {
        case .normalMode:
            return [
                UserGuideFeatureCard(
                    id: "normal.analyze",
                    icon: "chart.pie",
                    badgeKey: "workspace.tab.analyze",
                    titleKey: "user_guide.normal.card.analyze.title",
                    bodyKey: "user_guide.normal.card.analyze.body",
                    actionFlowKey: "user_guide.normal.card.analyze.flow"
                ),
                UserGuideFeatureCard(
                    id: "normal.clean",
                    icon: "sparkles",
                    badgeKey: "workspace.tab.clean",
                    titleKey: "user_guide.normal.card.clean.title",
                    bodyKey: "user_guide.normal.card.clean.body",
                    actionFlowKey: "user_guide.normal.card.clean.flow"
                ),
                UserGuideFeatureCard(
                    id: "normal.optimize",
                    icon: "slider.horizontal.3",
                    badgeKey: "workspace.tab.optimize",
                    titleKey: "user_guide.normal.card.optimize.title",
                    bodyKey: "user_guide.normal.card.optimize.body",
                    actionFlowKey: "user_guide.normal.card.optimize.flow"
                ),
                UserGuideFeatureCard(
                    id: "normal.status",
                    icon: "clock.arrow.circlepath",
                    badgeKey: "sidebar.section.undo_history",
                    titleKey: "user_guide.normal.card.status.title",
                    bodyKey: "user_guide.normal.card.status.body",
                    actionFlowKey: "user_guide.normal.card.status.flow"
                ),
            ]

        case .proNavigation:
            return [
                UserGuideFeatureCard(
                    id: "pro_nav.sidebar",
                    icon: "sidebar.left",
                    badgeKey: "user_guide.badge.scan_entry",
                    titleKey: "user_guide.pro_nav.card.sidebar.title",
                    bodyKey: "user_guide.pro_nav.card.sidebar.body",
                    actionFlowKey: "user_guide.pro_nav.card.sidebar.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_nav.tree",
                    icon: "rectangle.grid.1x2",
                    badgeKey: "main.results.mode.tree",
                    titleKey: "user_guide.pro_nav.card.tree.title",
                    bodyKey: "user_guide.pro_nav.card.tree.body",
                    actionFlowKey: "user_guide.pro_nav.card.tree.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_nav.list",
                    icon: "list.bullet",
                    badgeKey: "main.results.mode.list",
                    titleKey: "user_guide.pro_nav.card.list.title",
                    bodyKey: "user_guide.pro_nav.card.list.body",
                    actionFlowKey: "user_guide.pro_nav.card.list.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_nav.safety",
                    icon: "checkmark.shield",
                    badgeKey: "user_guide.badge.safety",
                    titleKey: "user_guide.pro_nav.card.safety.title",
                    bodyKey: "user_guide.pro_nav.card.safety.body",
                    actionFlowKey: "user_guide.pro_nav.card.safety.flow"
                ),
            ]

        case .proDeletion:
            return [
                UserGuideFeatureCard(
                    id: "pro_delete.direct",
                    icon: "trash",
                    badgeKey: "user_guide.badge.direct_trash",
                    titleKey: "user_guide.pro_delete.card.direct.title",
                    bodyKey: "user_guide.pro_delete.card.direct.body",
                    actionFlowKey: "user_guide.pro_delete.card.direct.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_delete.batch",
                    icon: "checkmark.square",
                    badgeKey: "user_guide.badge.batch_clean",
                    titleKey: "user_guide.pro_delete.card.batch.title",
                    bodyKey: "user_guide.pro_delete.card.batch.body",
                    actionFlowKey: "user_guide.pro_delete.card.batch.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_delete.stash",
                    icon: "tray.full.fill",
                    badgeKey: "user_guide.badge.stash_clean",
                    titleKey: "user_guide.pro_delete.card.stash.title",
                    bodyKey: "user_guide.pro_delete.card.stash.body",
                    actionFlowKey: "user_guide.pro_delete.card.stash.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_delete.recovery",
                    icon: "arrow.uturn.backward.circle",
                    badgeKey: "user_guide.badge.safe_recycle",
                    titleKey: "user_guide.pro_delete.card.recovery.title",
                    bodyKey: "user_guide.pro_delete.card.recovery.body",
                    actionFlowKey: "user_guide.pro_delete.card.recovery.flow"
                ),
            ]

        case .proToolbox:
            return [
                UserGuideFeatureCard(
                    id: "pro_tools.workflows",
                    icon: "hammer",
                    badgeKey: "workflow.sidebar.section",
                    titleKey: "user_guide.pro_tools.card.workflows.title",
                    bodyKey: "user_guide.pro_tools.card.workflows.body",
                    actionFlowKey: "user_guide.pro_tools.card.workflows.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_tools.cleanup",
                    icon: "trash.slash",
                    badgeKey: "sidebar.section.apps",
                    titleKey: "user_guide.pro_tools.card.cleanup_tools.title",
                    bodyKey: "user_guide.pro_tools.card.cleanup_tools.body",
                    actionFlowKey: "user_guide.pro_tools.card.cleanup_tools.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_tools.runtime",
                    icon: "network",
                    badgeKey: "main.section.dev_tools",
                    titleKey: "user_guide.pro_tools.card.runtime.title",
                    bodyKey: "user_guide.pro_tools.card.runtime.body",
                    actionFlowKey: "user_guide.pro_tools.card.runtime.flow"
                ),
                UserGuideFeatureCard(
                    id: "pro_tools.ai_hud",
                    icon: "sparkles",
                    badgeKey: "settings.tab.ai",
                    titleKey: "user_guide.pro_tools.card.ai_hud.title",
                    bodyKey: "user_guide.pro_tools.card.ai_hud.body",
                    actionFlowKey: "user_guide.pro_tools.card.ai_hud.flow"
                ),
            ]
        }
    }
}

public enum UserGuidePresentationPolicy {
    public static func shouldAutoPresentOnLaunch(
        userGuideCompleted: Bool,
        hasEvaluatedInitialUserGuide: Bool,
        hasConflictingModal: Bool,
        isRunningTests: Bool = false
    ) -> Bool {
        !userGuideCompleted
            && !hasEvaluatedInitialUserGuide
            && !hasConflictingModal
            && !isRunningTests
    }

    public static func initialPage(
        for interfaceMode: SmartCareInterfaceMode,
        trigger: UserGuidePresentationTrigger
    ) -> UserGuidePage {
        switch trigger {
        case .automaticFirstLaunch:
            return .normalMode
        case .manual:
            return interfaceMode == .professional ? .proNavigation : .normalMode
        }
    }

    public static func targetModeForSwitchAction(
        currentPage: UserGuidePage,
        currentInterfaceMode: SmartCareInterfaceMode
    ) -> SmartCareInterfaceMode? {
        if currentPage.isProfessionalTopic, currentInterfaceMode != .professional {
            return .professional
        }
        if currentPage == .normalMode, currentInterfaceMode != .normal {
            return .normal
        }
        return nil
    }
}

public struct UserGuideView: View {
    private let initialPage: UserGuidePage
    private let currentInterfaceMode: SmartCareInterfaceMode
    private let onDismiss: (_ targetMode: SmartCareInterfaceMode?) -> Void

    @Environment(\.locale) private var locale
    @State private var currentPage: UserGuidePage

    public init(
        initialPage: UserGuidePage = .normalMode,
        currentInterfaceMode: SmartCareInterfaceMode = .normal,
        onDismiss: @escaping (_ targetMode: SmartCareInterfaceMode?) -> Void
    ) {
        self.initialPage = initialPage
        self.currentInterfaceMode = currentInterfaceMode
        self.onDismiss = onDismiss
        self._currentPage = State(initialValue: initialPage)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().opacity(0.55)
            stepTabBar
            Divider().opacity(0.55)
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(0.55)
            footerBar
        }
        .frame(width: 790, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onValueChange(of: initialPage) { _, newPage in
            currentPage = newPage
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SmartCareMotionPalette.blueColor,
                                SmartCareMotionPalette.tealColor,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 42, height: 42)
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("user_guide.header.title", bundle: .module)
                    .font(.title3.bold())
                Text("user_guide.header.subtitle", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onDismiss(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help(AppLocalization.string("user_guide.action.close", locale: locale))
            .accessibilityLabel(Text("user_guide.action.close", bundle: .module))
            .accessibilityIdentifier("user_guide.close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var stepTabBar: some View {
        HStack(spacing: 8) {
            ForEach(UserGuidePage.allCases) { page in
                let isSelected = currentPage == page
                Button {
                    currentPage = page
                } label: {
                    HStack(spacing: 7) {
                        Text(verbatim: "\(page.stepNumber)")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .frame(width: 19, height: 19)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color.white : Color.primary.opacity(0.08))
                            )
                        Image(systemName: page.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(LocalizedStringKey(page.tabTitleKey), bundle: .module)
                            .font(.system(.callout, design: .rounded).weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: page.isProfessionalTopic
                                            ? [Color.indigo, SmartCareMotionPalette.blueColor]
                                            : [SmartCareMotionPalette.blueColor, SmartCareMotionPalette.tealColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("user_guide.tab.\(page.rawValue)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var pageContent: some View {
        let columns = [
            GridItem(.flexible(minimum: 320), spacing: 14),
            GridItem(.flexible(minimum: 320), spacing: 14),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(currentPage.modeBadgeKey), bundle: .module)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .foregroundStyle(currentPage.isProfessionalTopic ? Color.indigo : SmartCareMotionPalette.tealColor)
                        .background(
                            Capsule()
                                .fill(
                                    (currentPage.isProfessionalTopic ? Color.indigo : SmartCareMotionPalette.tealColor)
                                        .opacity(0.14)
                                )
                        )
                    Text(LocalizedStringKey(currentPage.titleKey), bundle: .module)
                        .font(.headline)
                }

                Text(LocalizedStringKey(currentPage.subtitleKey), bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(currentPage.cards) { card in
                    featureCardView(card)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(SmartCareMotionPalette.amberColor)
                    .font(.system(size: 14))
                Text(LocalizedStringKey(currentPage.tipKey), bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SmartCareMotionPalette.amberColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SmartCareMotionPalette.amberColor.opacity(0.22), lineWidth: 1)
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func featureCardView(_ card: UserGuideFeatureCard) -> some View {
        let accentColor = currentPage.isProfessionalTopic ? Color.indigo : SmartCareMotionPalette.blueColor
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: card.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(accentColor.opacity(0.12))
                    )

                Text(LocalizedStringKey(card.titleKey), bundle: .module)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(LocalizedStringKey(card.badgeKey), bundle: .module)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                    )
            }

            Text(LocalizedStringKey(card.bodyKey), bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)

            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(LocalizedStringKey(card.actionFlowKey), bundle: .module)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accentColor.opacity(0.07))
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var footerBar: some View {
        let switchTarget = UserGuidePresentationPolicy.targetModeForSwitchAction(
            currentPage: currentPage,
            currentInterfaceMode: currentInterfaceMode
        )
        return HStack(spacing: 12) {
            Text(
                AppLocalization.format(
                    "user_guide.step.counter %lld %lld",
                    locale: locale,
                    arguments: [
                        Int64(currentPage.stepNumber),
                        Int64(UserGuidePage.allCases.count),
                    ]
                )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if currentPage != .proToolbox {
                Button(AppLocalization.string("user_guide.action.skip", locale: locale)) {
                    onDismiss(nil)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("user_guide.skip")
            }

            Spacer(minLength: 8)

            if let switchTarget {
                Button(
                    AppLocalization.string(
                        switchTarget == .professional
                            ? "user_guide.action.try_professional"
                            : "user_guide.action.try_normal",
                        locale: locale
                    )
                ) {
                    onDismiss(switchTarget)
                }
                .accessibilityIdentifier("user_guide.switch_mode")
            }

            Button(AppLocalization.string("user_guide.action.previous", locale: locale)) {
                if let previous = currentPage.previousPage {
                    currentPage = previous
                }
            }
            .disabled(currentPage.previousPage == nil)
            .accessibilityIdentifier("user_guide.previous")

            if let nextPage = currentPage.nextPage {
                Button(AppLocalization.string("user_guide.action.next", locale: locale)) {
                    currentPage = nextPage
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("user_guide.next")
            } else {
                Button(AppLocalization.string("user_guide.action.finish", locale: locale)) {
                    onDismiss(nil)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("user_guide.finish")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
