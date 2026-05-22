import XCTest
@testable import AppUI

final class TrashPipelineDryRunTests: XCTestCase {

    func test_dryRun遇到不存在路径计入skipped() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashDryRun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let real = dir + "/real.txt"
        try "ok".write(toFile: real, atomically: true, encoding: .utf8)

        let missing1 = dir + "/no-such-file-1.bin"
        let missing2 = dir + "/no-such-file-2.bin"

        let pipe = TrashPipeline()
        let (present, missing, err) = await pipe.moveToTrash(
            paths: [real, missing1, missing2],
            dryRun: true
        )
        print("[dryRun-mixed] present=\(present) missing=\(missing) err=\(err ?? "nil")")
        XCTAssertEqual(present, 1)
        XCTAssertEqual(missing, 2)
        XCTAssertNotNil(err)
    }

    func test_dryRun全路径都存在时error为nil() async throws {
        let dir = NSTemporaryDirectory() + "GSYCleanTrashDryRun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let f1 = dir + "/a.txt"
        let f2 = dir + "/b.txt"
        let f3 = dir + "/c.txt"
        try "a".write(toFile: f1, atomically: true, encoding: .utf8)
        try "b".write(toFile: f2, atomically: true, encoding: .utf8)
        try "c".write(toFile: f3, atomically: true, encoding: .utf8)

        let pipe = TrashPipeline()
        let (present, missing, err) = await pipe.moveToTrash(
            paths: [f1, f2, f3],
            dryRun: true
        )
        print("[dryRun-all-exist] present=\(present) missing=\(missing) err=\(err ?? "nil")")
        XCTAssertEqual(present, 3)
        XCTAssertEqual(missing, 0)
        XCTAssertNil(err)
    }
}
