import Combine
import SwiftUI

/// v2026.10.10: window-independent intents and one sheet owner replace transient Help
/// notifications and competing App/Main presenters. Native onDismiss, not a false binding,
/// releases the slot; a replaced window cannot finish another window's presentation.
@MainActor
public final class MainWindowPresentationCoordinator: ObservableObject {
    enum Request {
        case userGuide(UserGuidePresentationTrigger)
        case fullDiskAccess
        case update(ReleaseInfo)
    }

    struct Presentation: Identifiable {
        enum Content {
            case userGuide(initialPage: UserGuidePage, interfaceMode: SmartCareInterfaceMode)
            case fullDiskAccess
            case update(ReleaseInfo)
        }

        let id = UUID()
        let hostID: UUID
        let request: Request
        let content: Content
    }

    struct Dismissal {
        let presentation: Presentation
        let targetMode: SmartCareInterfaceMode?
    }

    public let updateChecker: UpdateChecker
    @Published private(set) var requestRevision: UInt64 = 0
    @Published private(set) var activePresentation: Presentation?
    @Published private(set) var isDismissing = false
    @Published private(set) var isDrainScheduled = false
    @Published private(set) var businessModalCount = 0

    private var requests: [Request] = []
    private var hostID: UUID?
    private var targetMode: SmartCareInterfaceMode?
    private var hasEvaluatedInitialGuide = false
    private var businessModalHosts: [UUID: UUID] = [:]
    private var updateSubscription: AnyCancellable?

    var isOccupied: Bool { activePresentation != nil || isDrainScheduled }
    var pendingCount: Int { requests.count }

    func isOccupied(for hostID: UUID?) -> Bool {
        self.hostID == hostID && hostID != nil && isOccupied
    }

    public init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker
        // The subscription lives with the App-owned queue, including while MainView is absent.
        updateSubscription = updateChecker.$availableUpdate.sink { [weak self] release in
            self?.updateAvailableRelease(release)
        }
    }

    public func requestUserGuide() {
        enqueueUserGuide(trigger: .manual)
    }

    func requestInitialUserGuideIfNeeded(userGuideCompleted: Bool, isRunningTests: Bool) {
        guard !hasEvaluatedInitialGuide else { return }
        hasEvaluatedInitialGuide = true
        guard UserGuidePresentationPolicy.shouldAutoPresentOnLaunch(
            userGuideCompleted: userGuideCompleted,
            hasEvaluatedInitialUserGuide: false,
            hasConflictingModal: false,
            isRunningTests: isRunningTests
        ) else { return }
        enqueueUserGuide(trigger: .automaticFirstLaunch)
    }

    private func enqueueUserGuide(trigger: UserGuidePresentationTrigger) {
        if case .userGuide = activePresentation?.request { return }
        guard !requests.contains(where: { if case .userGuide = $0 { return true }; return false })
        else { return }
        requests.append(.userGuide(trigger))
        requestRevision &+= 1
    }

    public func requestFullDiskAccessGuide() {
        if case .fullDiskAccess = activePresentation?.request { return }
        guard !requests.contains(where: { if case .fullDiskAccess = $0 { return true }; return false })
        else { return }
        requests.append(.fullDiskAccess)
        requestRevision &+= 1
    }

    private func updateAvailableRelease(_ release: ReleaseInfo?) {
        requests.removeAll { if case .update = $0 { return true }; return false }
        if case .update(let current) = activePresentation?.request {
            if release?.tagName == current.tagName { return }
            isDismissing = true
        }
        if let release { requests.append(.update(release)) }
        requestRevision &+= 1
    }

    @discardableResult
    func attachHost(_ id: UUID) -> Bool {
        guard hostID == nil || hostID == id else { return false }
        hostID = id
        return true
    }

    func detachHost(_ id: UUID) {
        businessModalHosts = businessModalHosts.filter { $0.value != id }
        businessModalCount = businessModalHosts.count
        guard hostID == id else { return }
        // Closing the window is abandonment, not completion of its walkthrough. Keep the
        // original intent for the next window, and invalidate late native dismissal callbacks.
        if let activePresentation {
            switch activePresentation.request {
            case .update(let release):
                if updateChecker.availableUpdate?.tagName == release.tagName {
                    requests.insert(activePresentation.request, at: 0)
                }
            case .userGuide, .fullDiskAccess:
                requests.insert(activePresentation.request, at: 0)
            }
        }
        activePresentation = nil
        isDismissing = false
        isDrainScheduled = false
        targetMode = nil
        hostID = nil
        requestRevision &+= 1
    }

    func requestDrainIfPossible(hostID: UUID, isBusinessModalBusy: Bool) -> Bool {
        guard self.hostID == hostID, !requests.isEmpty, !isOccupied,
              !isBusinessModalBusy, businessModalCount(for: hostID) == 0 else { return false }
        isDrainScheduled = true
        return true
    }

    func takeScheduledIfPossible(
        hostID: UUID,
        isBusinessModalBusy: Bool,
        interfaceMode: SmartCareInterfaceMode
    ) -> Presentation? {
        guard self.hostID == hostID, isDrainScheduled else { return nil }
        isDrainScheduled = false
        guard activePresentation == nil, !isBusinessModalBusy,
              businessModalCount(for: hostID) == 0, !requests.isEmpty else { return nil }
        let request = requests.removeFirst()
        let content: Presentation.Content
        switch request {
        case .userGuide(let trigger):
            content = .userGuide(
                initialPage: UserGuidePresentationPolicy.initialPage(for: interfaceMode, trigger: trigger),
                interfaceMode: interfaceMode
            )
        case .fullDiskAccess:
            content = .fullDiskAccess
        case .update(let release):
            content = .update(release)
        }
        let presentation = Presentation(hostID: hostID, request: request, content: content)
        activePresentation = presentation
        return presentation
    }

    func visiblePresentation(for hostID: UUID) -> Presentation? {
        guard !isDismissing, activePresentation?.hostID == hostID else { return nil }
        return activePresentation
    }

    func dismiss(hostID: UUID, targetMode: SmartCareInterfaceMode? = nil) {
        guard activePresentation?.hostID == hostID, !isDismissing else { return }
        if case .userGuide = activePresentation?.request { self.targetMode = targetMode }
        isDismissing = true
    }

    func finishDismissal(hostID: UUID, presentationID: UUID) -> Dismissal? {
        guard let activePresentation, activePresentation.hostID == hostID,
              activePresentation.id == presentationID, isDismissing else { return nil }
        let dismissal = Dismissal(presentation: activePresentation, targetMode: targetMode)
        self.activePresentation = nil
        isDismissing = false
        targetMode = nil
        return dismissal
    }

    func businessModalCount(for hostID: UUID) -> Int {
        businessModalHosts.values.filter { $0 == hostID }.count
    }

    func beginBusinessModal(_ id: UUID, hostID: UUID? = nil) {
        guard let owner = hostID ?? self.hostID, businessModalHosts[id] == nil else { return }
        businessModalHosts[id] = owner
        businessModalCount = businessModalHosts.count
    }

    func endBusinessModal(_ id: UUID) {
        guard businessModalHosts.removeValue(forKey: id) != nil else { return }
        businessModalCount = businessModalHosts.count
    }
}

private struct MainWindowPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: MainWindowPresentationCoordinator? = nil
}

private struct MainWindowPresentationHostEnvironmentKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var mainWindowPresentationCoordinator: MainWindowPresentationCoordinator? {
        get { self[MainWindowPresentationEnvironmentKey.self] }
        set { self[MainWindowPresentationEnvironmentKey.self] = newValue }
    }

    var mainWindowPresentationHostID: UUID? {
        get { self[MainWindowPresentationHostEnvironmentKey.self] }
        set { self[MainWindowPresentationHostEnvironmentKey.self] = newValue }
    }
}
