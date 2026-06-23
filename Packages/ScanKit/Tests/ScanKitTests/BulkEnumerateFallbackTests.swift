import XCTest
@testable import ScanKit

final class BulkEnumerateFallbackTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BulkEnumerateFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_fileManagerFallback_跳过已由bulk返回过的entry() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let alreadySeen = dir.appendingPathComponent("seen.bin")
        let remaining = dir.appendingPathComponent("remaining.bin")
        try Data(repeating: 1, count: 128).write(to: alreadySeen)
        try Data(repeating: 2, count: 256).write(to: remaining)

        var entries: [BulkEntry] = []
        let count = BulkEnumerate.enumerateWithFileManagerFallback(
            dirPath: dir.path,
            skipping: ["seen.bin"]
        ) { entry in
            entries.append(entry)
            return true
        }

        XCTAssertEqual(count, 1)
        XCTAssertEqual(entries.map(\.name), ["remaining.bin"])
        XCTAssertEqual(entries.first?.logicalSize, 256)
        XCTAssertEqual(entries.first?.isDirectory, false)
        XCTAssertEqual(entries.first?.isSymlink, false)
        XCTAssertGreaterThan(entries.first?.inode ?? 0, 0)
    }
}
