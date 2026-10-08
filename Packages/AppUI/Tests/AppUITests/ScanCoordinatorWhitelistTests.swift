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

    func test_largeFilesAndTreeProjectionsNeverExposeWhitelistedDescendants() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCoordinatorWhitelistTree-\(UUID().uuidString)",
                                    isDirectory: true)
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = root.appendingPathComponent("container", isDirectory: true)
        let protectedDir = parent.appendingPathComponent("protected", isDirectory: true)
        let normalDir = parent.appendingPathComponent("normal", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalDir, withIntermediateDirectories: true)
        let protectedLarge = protectedDir.appendingPathComponent("protected_big.bin")
        let normalLarge = normalDir.appendingPathComponent("normal_big.bin")
        try Data(repeating: 0xC1, count: 2 * 1_048_576).write(to: protectedLarge)
        try Data(repeating: 0xD2, count: 2 * 1_048_576).write(to: normalLarge)

        let whitelist = WhitelistStore(storageURL: nil)
        await whitelist.add(path: protectedDir.path, reason: "test")
        let coordinator = ScanCoordinator(
            home: root.path,
            enableTreeDeepIndex: true,
            whitelistStore: whitelist
        )
        coordinator.scan(
            category: .makeCustom(url: root),
            includeHidden: true,
            largeFileMinBytes: 1_048_576
        )
        await waitForFinished(coordinator)

        let largePaths = coordinator.largeFiles(minSizeMB: 1, sortKey: .sizeDesc).map(\.path)
        XCTAssertFalse(largePaths.contains(protectedLarge.path))
        XCTAssertTrue(largePaths.contains(normalLarge.path))
        XCTAssertEqual(coordinator.largeFileCollectedCount, 1)

        let children = await coordinator.directChildrenAsync(of: parent.path, sortedBy: .sizeDesc)
        XCTAssertFalse(children.contains { $0.path == protectedDir.path })
        XCTAssertTrue(children.contains { $0.path == normalDir.path })
    }

    private func waitForFinished(_ coordinator: ScanCoordinator,
                                 timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.isScanning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
}
