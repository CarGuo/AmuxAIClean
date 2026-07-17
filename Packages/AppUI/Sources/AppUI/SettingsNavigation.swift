import Combine

/// v2026.07.16：使用 Combine 发布导航选择，避免依赖 macOS 14 才提供的 Observation。
@MainActor
public final class SettingsNavigation: ObservableObject {
    /// 设置导航的完整、稳定顺序。使用 CaseIterable 锁住所有入口，避免新增页面后
    /// 只塞进固定宽度 toolbar，最终掉进不可点击的 overflow 菜单。
    public enum Destination: String, CaseIterable, Identifiable, Hashable, Sendable {
        case scan
        case largeFiles
        case customPaths
        case update
        case developerScan
        case storageAndLogs
        case ai
        case advanced

        public var id: String { rawValue }
    }

    @Published public var destination: Destination

    public init(destination: Destination = .scan) {
        self.destination = destination
    }

    public func select(_ destination: Destination) {
        self.destination = destination
    }
}
