import Darwin
import Foundation
import XCTest
@testable import ScanKit

/// v2026.07.17 regression ledger for the shared BulkScanner directory boundary.
///
/// These fixtures use only temporary directories. They intentionally model the two provenance
/// failures that previously made capacity and traversal disagree with the pathname later shown
/// to the user: a symlink scan root, and a queued child replaced before `open`.
final class BulkScannerDirectoryIdentityTests: XCTestCase {
    func testRootSymlinkIsRejectedWhenFollowingIsDisabled() async throws {
        let fixture = try makeFixture(named: "root-no-follow")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("target", isDirectory: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8 * 1_024).write(
            to: target.appendingPathComponent("must-not-be-counted.bin")
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let events = await collectEvents(
            root: alias,
            options: ScanOptions(
                followSymlinks: false,
                concurrency: 1,
                maxConcurrency: 1,
                mediaAware: false,
                respectTCCSkipList: false
            )
        )

        let summary = try XCTUnwrap(events.compactMap(\.summary).last)
        XCTAssertEqual(summary.totalAllocatedBytes, 0)
        XCTAssertEqual(summary.fileCount, 0)
        XCTAssertEqual(summary.completionStatus, .partial)
        XCTAssertTrue(events.contains { event in
            guard case .failed(.cannotEnumerate(let path, let stage, _)) = event else {
                return false
            }
            return path == alias.path && stage == .metadata
        })
        XCTAssertTrue(summary.incompleteIssues.contains { issue in
            issue.path == alias.path
                && issue.reason == .metadataUnavailable
                && issue.stage == .metadata
        })
    }

    func testRootSymlinkExplicitFollowUsesFrozenTargetIdentity() async throws {
        let fixture = try makeFixture(named: "root-explicit-follow")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("target", isDirectory: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 8 * 1_024).write(
            to: target.appendingPathComponent("counted.bin")
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let events = await collectEvents(
            root: alias,
            options: ScanOptions(
                followSymlinks: true,
                concurrency: 1,
                maxConcurrency: 1,
                mediaAware: false,
                respectTCCSkipList: false
            )
        )

        let summary = try XCTUnwrap(events.compactMap(\.summary).last)
        XCTAssertEqual(summary.completionStatus, .complete)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertGreaterThan(summary.totalAllocatedBytes, 0)
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false })
    }

    func testQueuedChildReplacementCannotFollowSymlinkTarget() throws {
        let fixture = try makeFixture(named: "queued-child-swap")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let queuedPath = fixture.appendingPathComponent("queued", isDirectory: true)
        let parkedOriginal = fixture.appendingPathComponent("parked-original", isDirectory: true)
        let replacementTarget = fixture.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: queuedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementTarget, withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 8 * 1_024).write(
            to: replacementTarget.appendingPathComponent("unrelated.bin")
        )

        var queuedMetadata = stat()
        XCTAssertEqual(lstat(queuedPath.path, &queuedMetadata), 0)
        let queuedWork = BulkDirectoryWork(
            path: queuedPath.path,
            identity: BulkDirectoryIdentity(metadata: queuedMetadata),
            followsFinalSymlink: false,
            isRoot: false
        )
        try FileManager.default.moveItem(at: queuedPath, to: parkedOriginal)
        try FileManager.default.createSymbolicLink(
            at: queuedPath,
            withDestinationURL: replacementTarget
        )

        let outcome = BulkDirectoryOpener.open(work: queuedWork, shouldCancel: { false })
        guard case .identityChanged = outcome else {
            return XCTFail("queued pathname replacement must fail the descriptor identity fence: \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replacementTarget.appendingPathComponent("unrelated.bin").path
        ))
    }

    func testExplicitFollowRejectsRetargetedSymlinkBeforeOpen() throws {
        let fixture = try makeFixture(named: "follow-retarget")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let firstTarget = fixture.appendingPathComponent("first", isDirectory: true)
        let secondTarget = fixture.appendingPathComponent("second", isDirectory: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstTarget)

        let resolution = BulkDirectoryWorkResolver.resolveRoot(
            path: alias.path,
            followSymlinks: true,
            shouldCancel: { false }
        )
        guard case .resolved(let frozenWork) = resolution else {
            return XCTFail("explicit follow fixture should resolve: \(resolution)")
        }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondTarget)

        let outcome = BulkDirectoryOpener.open(work: frozenWork, shouldCancel: { false })
        guard case .identityChanged = outcome else {
            return XCTFail("retargeted explicit symlink must not inherit the old proof: \(outcome)")
        }
    }

    func testExplicitFollowRejectsSymlinkReplacedBeforeTargetResolution() throws {
        let fixture = try makeFixture(named: "follow-replaced-before-resolution")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let firstTarget = fixture.appendingPathComponent("first", isDirectory: true)
        let secondTarget = fixture.appendingPathComponent("second", isDirectory: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstTarget)

        var sourceMetadata = stat()
        XCTAssertEqual(lstat(alias.path, &sourceMetadata), 0)
        let sourceEntry = BulkEntry(
            name: alias.lastPathComponent,
            isDirectory: false,
            isSymlink: true,
            allocatedSize: Int64(sourceMetadata.st_blocks) * 512,
            logicalSize: Int64(sourceMetadata.st_size),
            inode: UInt64(sourceMetadata.st_ino),
            device: UInt64(bitPattern: Int64(sourceMetadata.st_dev)),
            modificationDate: nil
        )
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondTarget)

        let resolution = BulkDirectoryWorkResolver.resolveDescendant(
            path: alias.path,
            entry: sourceEntry,
            followSymlinks: true,
            shouldCancel: { false }
        )
        XCTAssertEqual(resolution, .failed(ESTALE))
    }

    func testDescriptorFallbackRemainsOnOpenedDirectoryAfterPathReplacement() throws {
        let fixture = try makeFixture(named: "descriptor-fallback-replacement")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let openedPath = fixture.appendingPathComponent("opened", isDirectory: true)
        let parkedOriginal = fixture.appendingPathComponent("parked-original", isDirectory: true)
        let unrelated = fixture.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: openedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([0x01]).write(to: openedPath.appendingPathComponent("original.bin"))
        try Data([0x02]).write(to: unrelated.appendingPathComponent("unrelated.bin"))

        let descriptor = Darwin.open(
            openedPath.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        try FileManager.default.moveItem(at: openedPath, to: parkedOriginal)
        try FileManager.default.createSymbolicLink(at: openedPath, withDestinationURL: unrelated)

        var names: [String] = []
        _ = BulkEnumerate.enumerateWithDescriptorFallback(
            fd: descriptor,
            dirPath: openedPath.path,
            skipping: []
        ) { entry in
            names.append(entry.name)
            return true
        }

        XCTAssertEqual(names, ["original.bin"])
        XCTAssertFalse(names.contains("unrelated.bin"))
    }

    private func makeFixture(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BulkScannerDirectoryIdentity-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func collectEvents(
        root: URL,
        options: ScanOptions
    ) async -> [ScanEvent] {
        var events: [ScanEvent] = []
        let scanner = BulkScanner(options: options)
        for await event in scanner.scan(root: root, delivery: .summaryOnly) {
            events.append(event)
        }
        return events
    }
}

private extension ScanEvent {
    var summary: ScanSummary? {
        guard case .finished(let summary) = self else { return nil }
        return summary
    }
}
