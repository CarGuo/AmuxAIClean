import Foundation

public enum TCCStatus: Equatable, Sendable {
    case granted
    case deniedReadable(probedDenialCount: Int)
    case unknown
}

public protocol TCCDirectoryReader: Sendable {
    func read(_ url: URL) throws
}

public struct DefaultTCCDirectoryReader: TCCDirectoryReader {
    public init() {}
    public func read(_ url: URL) throws {
        _ = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }
}

public actor TCCProbe {
    public static let probedSubpaths: [String] = [
        "Library/Mail",
        "Library/Safari",
        "Library/Calendars"
    ]

    private let reader: TCCDirectoryReader
    private let homeDirectory: URL

    public init(
        reader: TCCDirectoryReader = DefaultTCCDirectoryReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.reader = reader
        self.homeDirectory = homeDirectory
    }

    public func probe() async -> TCCStatus {
        var denialCount = 0
        var probedCount = 0

        for sub in Self.probedSubpaths {
            let url = homeDirectory.appendingPathComponent(sub, isDirectory: true)
            probedCount += 1
            do {
                try reader.read(url)
            } catch let error as NSError {
                if Self.isOperationNotPermitted(error) {
                    denialCount += 1
                }
            }
        }

        if probedCount == 0 {
            return .unknown
        }
        if denialCount == 0 {
            return .granted
        }
        return .deniedReadable(probedDenialCount: denialCount)
    }

    static func isOperationNotPermitted(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == 1 {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && underlying.code == 1 {
                return true
            }
        }
        if error.domain == NSCocoaErrorDomain {
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain,
               underlying.code == 1 {
                return true
            }
        }
        return false
    }
}
