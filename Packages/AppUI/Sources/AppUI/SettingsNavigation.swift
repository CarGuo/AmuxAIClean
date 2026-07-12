import Observation

@MainActor
@Observable
public final class SettingsNavigation {
    public enum Destination: Hashable, Sendable {
        case scan
        case largeFiles
        case customPaths
        case update
        case developerScan
        case storageAndLogs
        case ai
        case advanced
    }

    public var destination: Destination

    public init(destination: Destination = .scan) {
        self.destination = destination
    }

    public func select(_ destination: Destination) {
        self.destination = destination
    }
}
