import XCTest
@testable import AppUI
import HeuristicKit

final class HeuristicRecorderTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HRTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("heuristic.json")
    }

    func testRecordTrashedPersistsAndPushesScorePositive() async throws {
        let url = tempStoreURL()
        let recorder = HeuristicRecorder(engine: HeuristicEngine(), storeURL: url)
        await recorder.recordTrashed(paths: ["/A/B/c.log"])
        await recorder.recordTrashed(paths: ["/A/B/d.log"])
        await recorder.recordTrashed(paths: ["/A/B/e.log"])

        let s = await recorder.score(of: "/A/B")
        XCTAssertGreaterThan(s, 0.0)

        // 文件确实写盘了
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRestoredOverridesPositive() async throws {
        let url = tempStoreURL()
        let recorder = HeuristicRecorder(engine: HeuristicEngine(), storeURL: url)
        await recorder.recordTrashed(paths: ["/X/Y/a.log", "/X/Y/b.log", "/X/Y/c.log"])
        await recorder.recordRestored(paths: ["/X/Y/a.log"])
        let s = await recorder.score(of: "/X/Y")
        XCTAssertLessThan(s, 0.0)
    }

    func testRecorderReloadsFromDisk() async throws {
        let url = tempStoreURL()
        do {
            let r1 = HeuristicRecorder(engine: HeuristicEngine(), storeURL: url)
            await r1.recordTrashed(paths: ["/Persist/P/a.log"])
        }
        // 第二次构造，应当从磁盘恢复
        let r2 = HeuristicRecorder(engine: HeuristicEngine(), storeURL: url)
        let s = await r2.score(of: "/Persist/P/a.log")
        XCTAssertGreaterThan(s, 0.0)
    }
}
