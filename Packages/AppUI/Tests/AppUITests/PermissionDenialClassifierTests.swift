import Darwin
import XCTest
import ScanKit
@testable import AppUI

final class PermissionDenialClassifierTests: XCTestCase {
    func test_filesystemBlockedPaths_onlyClassifiesAfterFDAGranted() throws {
        let root = try makeTempDir()
        defer { cleanup(root) }
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(blocked.path, 0), 0)

        XCTAssertEqual(
            PermissionDenialClassifier.filesystemBlockedPaths(in: [blocked.path], fdaStatus: .denied),
            [],
            "FDA denied 时不能把同一条路径改判成 filesystem blocked，否则会隐藏真实授权问题"
        )
        XCTAssertEqual(
            PermissionDenialClassifier.filesystemBlockedPaths(in: [blocked.path], fdaStatus: .granted),
            [blocked.path]
        )
    }

    func test_readableDirectory_isNotFilesystemBlocked() throws {
        let root = try makeTempDir()
        defer { cleanup(root) }
        let readable = root.appendingPathComponent("readable", isDirectory: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)

        XCTAssertFalse(PermissionDenialClassifier.isFilesystemBlocked(readable.path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionDenialClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        _ = chmod(url.path, S_IRWXU)
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator {
                _ = chmod(child.path, S_IRWXU)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}
