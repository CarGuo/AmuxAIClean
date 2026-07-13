import SafetyKit
import XCTest
@testable import AppUI

@MainActor
final class ScanCoordinatorWhitelistTests: XCTestCase {
    func test_scanNeverPublishesWhitelistedBucket() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorWhitelist-\(UUID().uuidString)",
                                    isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }

        let hidden = root.appendingPathComponent("hidden", isDirectory: true)
        let visible = root.appendingPathComponent("visible", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        try Data(repeating: 0xA1, count: 128)
            .write(to: hidden.appendingPathComponent("secret.bin"))
        try Data(repeating: 0xB2, count: 64)
            .write(to: visible.appendingPathComponent("public.bin"))

        let whitelist = WhitelistStore(storageURL: nil)
        await whitelist.add(path: hidden.path, reason: "test")
        let coordinator = ScanCoordinator(home: root.path, whitelistStore: whitelist)
        coordinator.scan(category: .makeCustom(url: root), includeHidden: true)
        await waitForFinished(coordinator)

        XCTAssertTrue(coordinator.snapshot.isFinished)
        XCTAssertFalse(coordinator.snapshot.rows.contains { $0.url.path == hidden.path })
        XCTAssertTrue(coordinator.snapshot.rows.contains { $0.url.path == visible.path })
    }

    private func waitForFinished(_ coordinator: ScanCoordinator,
                                 timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.isScanning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
}
