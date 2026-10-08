import XCTest
@testable import HeuristicKit

final class HistoryAliasMigrationTests: XCTestCase {
    func testInitializationAndLoadMergeAllAliasObservations() async throws {
        let path = "/Users/tester/Library/Caches/acme/item"
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(100)
        let source = [
            path: PathScore(deletedCount: 20, keptCount: 2, lastUpdated: earlier),
            "/System/Volumes/Data/USERS/TESTER/LIBRARY/CACHES/ACME/ITEM":
                PathScore(deletedCount: 3, restoredCount: 1, keptCount: 4, lastUpdated: later)
        ]
        let expected = PathScore(deletedCount: 23, restoredCount: 1, keptCount: 6, lastUpdated: later)
        let engine = HeuristicEngine(home: "/Users/tester", initialScores: source)
        let initialized = await engine.snapshotEntry(for: path)
        XCTAssertEqual(initialized, expected)
        let initialScore = await engine.score(path: path)
        XCTAssertLessThan(initialScore, 0)

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) } // best-effort fixture cleanup
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(HeuristicSnapshot(scores: source)).write(to: url)
        let loaded = HeuristicEngine(home: "/Users/tester")
        try await loaded.load(from: url)
        let migrated = await loaded.snapshotEntry(for: path)
        XCTAssertEqual(migrated, expected)
        let migratedScore = await loaded.score(path: path)
        XCTAssertLessThan(migratedScore, 0)
    }

    func testCounterMergeAndSubsequentRecordingCannotOverflowOrLoseRestore() async {
        let path = "/Users/tester/Work/item"
        let engine = HeuristicEngine(initialScores: [
            path: PathScore(deletedCount: Int.max, restoredCount: 1),
            path.uppercased(): PathScore(deletedCount: 1)
        ])
        await engine.record(action: .trashedPath(path, timestamp: .now))
        let entry = await engine.snapshotEntry(for: path)
        XCTAssertEqual(entry?.deletedCount, Int.max)
        XCTAssertEqual(entry?.restoredCount, 1)
        let score = await engine.score(path: path)
        XCTAssertLessThan(score, 0)
    }
}
