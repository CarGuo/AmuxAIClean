import Foundation
import ScanKit

/// v2026.10.11 review: asynchronous input belongs to the exact window scan context that
/// requested it. Returning to the same category does not revive an older scan session.
struct MainScanContextIdentity: Equatable, Sendable {
    let interfaceMode: SmartCareInterfaceMode
    let categoryID: String?
    let scanSessionID: UUID
}

struct MainCategorySwitchIntent {
    let source: MainScanContextIdentity
    let destinationID: String?
    let fallbackCategory: ScanCategory?
    let customPaths: [URL]

    func isCurrent(in context: MainScanContextIdentity) -> Bool {
        source == context && context.interfaceMode == .professional
    }
}

struct MainScanInputRequestState {
    private(set) var requestID: UUID?
    private var source: MainScanContextIdentity?
    private var expectedInput: String?

    mutating func begin(in context: MainScanContextIdentity, input: String? = nil) -> UUID? {
        guard requestID == nil else { return nil }
        let id = UUID()
        requestID = id
        source = context
        expectedInput = input
        return id
    }

    func matches(_ context: MainScanContextIdentity, input: String) -> Bool {
        source == context && (expectedInput == nil || expectedInput == input)
    }

    mutating func take(_ id: UUID, in context: MainScanContextIdentity,
                       input: String = "", isAdmitted: Bool) -> Bool {
        guard requestID == id else { return false }
        defer { invalidate() }
        return isAdmitted && matches(context, input: input)
    }

    mutating func invalidate() { requestID = nil; source = nil; expectedInput = nil }
}

enum MainDirectoryInputSource {
    case path(String)
    case drop([NSItemProvider])
}

enum MainDirectoryInput {
    enum ValidationInput: Sendable { case path(String), urls([URL]) }
    struct Validation: Sendable {
        let candidates: [URL]
        let directories: [URL]
    }

    static func validate(_ input: ValidationInput) async -> Validation {
        await Task.detached(priority: .userInitiated) {
            let urls: [URL]
            switch input {
            case .path(let raw): urls = [URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)]
            case .urls(let loaded): urls = loaded
            }
            let directories = urls.filter { url in
                guard url.isFileURL else { return false }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            return Validation(candidates: urls, directories: directories)
        }.value
    }

    @MainActor
    static func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: url) }
            }
        }
    }
}
