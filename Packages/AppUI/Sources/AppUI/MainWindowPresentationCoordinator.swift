import Combine
import SwiftUI

/// v2026.10.10 review correction: requests belong to their originating window, while
/// physical sheets, requested presentations and business transactions have separate lifetimes.
/// A sheet's false binding does not end an operation; a removed presenter cannot retain a lease.
@MainActor
public final class MainWindowPresentationCoordinator: ObservableObject {
    enum Request {
        case userGuide(UserGuidePresentationTrigger)
        case fullDiskAccess
        case update(ReleaseInfo)
    }

    private struct PendingRequest {
        let request: Request
        var hostID: UUID?
    }

    struct Presentation: Identifiable {
        enum Content {
            case userGuide(interfaceMode: SmartCareInterfaceMode)
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
    }

    private struct BusinessLease {
        let hostID: UUID
        let isTransaction: Bool
        let isActive: @MainActor () -> Bool
    }

    public let updateChecker: UpdateChecker
    @Published private(set) var requestRevision: UInt64 = 0
    private var requests: [PendingRequest] = []
    private var hosts: [UUID] = []
    private var focusActions: [UUID: @MainActor () -> Void] = [:]
    private var preferredHostID: UUID?
    private var presentations: [UUID: Presentation] = [:]
    private var dismissingHosts: Set<UUID> = []
    private var scheduledHosts: Set<UUID> = []
    private var hasEvaluatedFullDiskAccess = false
    private(set) var fullDiskAccessEvaluationTask: Task<Void, Never>?
    private var businessLeases: [UUID: BusinessLease] = [:]
    private var nativeSheetHosts: Set<UUID> = []
    private var updateSubscription: AnyCancellable?
    private var publicationTask: Task<Void, Never>?

    var isOccupied: Bool { !presentations.isEmpty || !scheduledHosts.isEmpty }
    var isDismissing: Bool { !dismissingHosts.isEmpty }
    var pendingCount: Int { requests.count }
    var businessModalCount: Int { businessLeases.values.filter { $0.isActive() }.count + nativeSheetHosts.count }
    public var hasAttachedHost: Bool { !hosts.isEmpty }

    func isOccupied(for hostID: UUID?) -> Bool {
        guard let hostID else { return false }
        return presentations[hostID] != nil || scheduledHosts.contains(hostID)
    }

    // v2026.10.11 review: a scan replaces selection/revision as well as disk work. All
    // producers must use live host admission, including the native closing barrier and
    // nested tools whose transaction has changed before SwiftUI published another frame.
    func canReplaceScanContext(for hostID: UUID, hasLocalTransaction: Bool) -> Bool {
        !hasLocalTransaction && !isOccupied(for: hostID) && businessModalCount(for: hostID) == 0
    }

    public init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker
        updateSubscription = updateChecker.$availableUpdate.sink { [weak self] release in
            self?.updateAvailableRelease(release)
        }
    }

    public func requestUserGuide(hostID: UUID? = nil) {
        // v2026.10.11: a direct control request selects its window even while native
        // activation is pending. Help and the tour share this owner, not transient key flags.
        if let hostID { focusHost(hostID) }
        enqueueUserGuide(trigger: .manual, hostID: hostID ?? preferredHostID)
        if hostID == nil, let preferredHostID { focusActions[preferredHostID]?() }
    }

    func requestFirstVisitUserGuideIfNeeded(
        hostID: UUID, mode: SmartCareInterfaceMode,
        completedModes: Set<SmartCareInterfaceMode>, isRunningTests: Bool
    ) {
        // v1.6.9 (2026.10.12): startup and mode transitions share this reconciliation.
        // Automatic requests are tied to a visible mode; Help retains its explicit window intent.
        let previousCount = requests.count
        requests.removeAll {
            guard case .userGuide(.firstVisit(let requestedMode)) = $0.request else { return false }
            return completedModes.contains(requestedMode)
                || (($0.hostID == hostID || $0.hostID == nil) && requestedMode != mode)
        }
        if requests.count != previousCount { changed() }
        guard hosts.contains(hostID), UserGuidePresentationPolicy.shouldAutoPresentOnVisit(
            mode: mode, completedModes: completedModes,
            isRunningTests: isRunningTests
        ) else { return }
        // First-visit tours are app-wide per mode; two hosts do not both auto-teach one mode.
        guard !requests.contains(where: {
            if case .userGuide(.firstVisit(let requestedMode)) = $0.request { return requestedMode == mode }; return false
        }), !presentations.values.contains(where: {
            if case .userGuide(let presentedMode) = $0.content { return presentedMode == mode }; return false
        }) else { return }
        enqueueUserGuide(trigger: .firstVisit(mode), hostID: hostID)
    }

    private func enqueueUserGuide(trigger: UserGuidePresentationTrigger, hostID: UUID?) {
        let destination = hostID ?? preferredHostID
        if let destination, case .userGuide = presentations[destination]?.request { return }
        guard !requests.contains(where: {
            if case .userGuide = $0.request { return ($0.hostID ?? preferredHostID) == destination }
            return false
        }) else { return }
        requests.append(PendingRequest(request: .userGuide(trigger), hostID: hostID))
        changed()
    }

    /// App-owned evaluation survives WindowGroup task cancellation. "Later" suppresses this
    /// launch only; the persistent preference is still changed only by opening System Settings.
    public func evaluateFullDiskAccessOnboardingIfNeeded(
        isPermanentlyDismissed: Bool,
        needsGuide: @escaping @Sendable () async -> Bool
    ) {
        guard !hasEvaluatedFullDiskAccess else { return }
        hasEvaluatedFullDiskAccess = true
        guard !isPermanentlyDismissed else { return }
        fullDiskAccessEvaluationTask = Task { [weak self] in
            let shouldPresent = await needsGuide()
            guard let self, !Task.isCancelled else { return }
            self.fullDiskAccessEvaluationTask = nil
            if shouldPresent { self.requestFullDiskAccessGuide() }
        }
    }

    public func requestFullDiskAccessGuide() {
        guard !presentations.values.contains(where: {
            if case .fullDiskAccess = $0.request { return true }; return false
        }), !requests.contains(where: {
            if case .fullDiskAccess = $0.request { return true }; return false
        }) else { return }
        requests.append(PendingRequest(request: .fullDiskAccess, hostID: nil))
        changed()
    }

    private func updateAvailableRelease(_ release: ReleaseInfo?) {
        requests.removeAll { if case .update = $0.request { return true }; return false }
        for presentation in presentations.values {
            if case .update(let current) = presentation.request {
                if release?.tagName == current.tagName { return }
                dismissingHosts.insert(presentation.hostID)
            }
        }
        if let release { requests.append(PendingRequest(request: .update(release), hostID: nil)) }
        changed()
    }

    @discardableResult
    func attachHost(_ id: UUID, focusWindow: (@MainActor () -> Void)? = nil) -> Bool {
        if let focusWindow { focusActions[id] = focusWindow }
        guard !hosts.contains(id) else { return true }
        hosts.append(id)
        if preferredHostID == nil { preferredHostID = id }
        changed()
        return true
    }

    func focusHost(_ id: UUID) {
        guard hosts.contains(id), preferredHostID != id else { return }
        preferredHostID = id
        changed()
    }

    func isFocusedHost(_ id: UUID) -> Bool { preferredHostID == id }

    func detachHost(_ id: UUID) {
        guard hosts.contains(id) else { return }
        hosts.removeAll { $0 == id }
        focusActions.removeValue(forKey: id)
        businessLeases = businessLeases.filter { $0.value.hostID != id }
        nativeSheetHosts.remove(id)
        if preferredHostID == id { preferredHostID = hosts.first }
        for index in requests.indices where requests[index].hostID == id {
            requests[index].hostID = nil
        }
        if let presentation = presentations.removeValue(forKey: id) {
            switch presentation.request {
            case .update(let release):
                if updateChecker.availableUpdate?.tagName == release.tagName {
                    requests.insert(PendingRequest(request: presentation.request, hostID: nil), at: 0)
                }
            case .userGuide, .fullDiskAccess:
                // v1.6.9 C4: changing the split view can temporarily detach its native host.
                // Preserve the intent, including its first-visit mode, until admission rechecks
                // the live window. A mismatched automatic mode is never displayed/acknowledged.
                requests.insert(PendingRequest(request: presentation.request, hostID: nil), at: 0)
            }
        }
        dismissingHosts.remove(id)
        scheduledHosts.remove(id)
        changed()
    }

    private func nextRequestIndex(for hostID: UUID) -> Int? {
        requests.firstIndex { ($0.hostID ?? preferredHostID) == hostID }
    }

    func requestDrainIfPossible(hostID: UUID, isBusinessModalBusy: Bool) -> Bool {
        guard hosts.contains(hostID), nextRequestIndex(for: hostID) != nil,
              !isOccupied(for: hostID), !isBusinessModalBusy,
              businessModalCount(for: hostID) == 0 else { return false }
        scheduledHosts.insert(hostID)
        changed()
        return true
    }

    func takeScheduledIfPossible(
        hostID: UUID,
        isBusinessModalBusy: Bool,
        interfaceMode: SmartCareInterfaceMode
    ) -> Presentation? {
        guard hosts.contains(hostID), scheduledHosts.remove(hostID) != nil else { return nil }
        defer { changed() }
        guard presentations[hostID] == nil, !isBusinessModalBusy,
              businessModalCount(for: hostID) == 0,
              let index = nextRequestIndex(for: hostID) else { return nil }
        let request = requests.remove(at: index).request
        let content: Presentation.Content
        switch request {
        case .userGuide(let trigger):
            if case .firstVisit(let requestedMode) = trigger, requestedMode != interfaceMode { return nil }
            content = .userGuide(interfaceMode: interfaceMode)
        case .fullDiskAccess: content = .fullDiskAccess
        case .update(let release): content = .update(release)
        }
        let presentation = Presentation(hostID: hostID, request: request, content: content)
        presentations[hostID] = presentation
        return presentation
    }

    func visiblePresentation(for hostID: UUID) -> Presentation? {
        dismissingHosts.contains(hostID) ? nil : presentations[hostID]
    }

    func dismiss(hostID: UUID) {
        guard presentations[hostID] != nil, !dismissingHosts.contains(hostID) else { return }
        dismissingHosts.insert(hostID)
        changed()
    }

    func finishDismissal(hostID: UUID, presentationID: UUID) -> Dismissal? {
        guard let presentation = presentations[hostID], presentation.id == presentationID,
              dismissingHosts.contains(hostID) else { return nil }
        let dismissal = Dismissal(presentation: presentation)
        presentations.removeValue(forKey: hostID)
        dismissingHosts.remove(hostID)
        changed()
        return dismissal
    }

    func businessModalCount(for hostID: UUID) -> Int {
        businessLeases.values.filter { $0.hostID == hostID && $0.isActive() }.count
            + (nativeSheetHosts.contains(hostID) ? 1 : 0)
    }

    func businessTransactionCount(for hostID: UUID) -> Int {
        businessLeases.values.filter { $0.hostID == hostID && $0.isTransaction && $0.isActive() }.count
    }

    func beginBusinessModal(_ id: UUID, hostID: UUID? = nil) {
        guard let owner = hostID ?? preferredHostID, businessLeases[id] == nil else { return }
        businessLeases[id] = BusinessLease(hostID: owner, isTransaction: false, isActive: { true })
        changed()
    }

    // Recheck the actual owner's live phase at admission. View observation only wakes the
    // queue; it cannot be the authoritative phase, since rendering may lag a Task's start.
    func registerBusinessTransaction(_ id: UUID, hostID: UUID?, isActive: @escaping @MainActor () -> Bool) {
        guard let owner = hostID ?? preferredHostID else { return }
        businessLeases[id] = BusinessLease(hostID: owner, isTransaction: true, isActive: isActive)
        changed()
    }

    func businessTransactionChanged() { changed() }

    func endBusinessModal(_ id: UUID) {
        guard businessLeases.removeValue(forKey: id) != nil else { return }
        changed()
    }

    func nativeSheetChanged(isPresented: Bool, hostID: UUID) {
        guard hosts.contains(hostID) else { return }
        let didChange = isPresented ? nativeSheetHosts.insert(hostID).inserted
            : nativeSheetHosts.remove(hostID) != nil
        if didChange { changed() }
    }

    func hasNativeSheet(for hostID: UUID?) -> Bool {
        guard let hostID else { return false }
        return nativeSheetHosts.contains(hostID)
    }

    private func changed() {
        // v2026.10.10 native integration: AppKit can attach/end a sheet during SwiftUI's
        // update stack. Update authoritative state synchronously, then coalesce observation
        // outside that stack. No presentation admission depends on this scheduling tick.
        guard publicationTask == nil else { return }
        publicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.publicationTask = nil
            self.requestRevision &+= 1
        }
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
