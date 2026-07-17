import XCTest
@testable import ScanKit

/// v2026.07.17 regression coverage for public scan deadline normalization.
final class ScanDeadlineTests: XCTestCase {
    func test_invalidAndNonPositiveTimeoutsExpireImmediately() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ScanDeadline.make(timeout: .nan, now: now), now)
        XCTAssertEqual(ScanDeadline.make(timeout: -.infinity, now: now), now)
        XCTAssertEqual(ScanDeadline.make(timeout: -1, now: now), now)
        XCTAssertEqual(ScanDeadline.make(timeout: 0, now: now), now)
    }

    func test_positiveFiniteTimeoutPreservesDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ScanDeadline.make(timeout: 1.25, now: now),
            now.addingTimeInterval(1.25)
        )
    }

    func test_infiniteAndHugeTimeoutsSaturate() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ScanDeadline.make(timeout: .infinity, now: now), .distantFuture)
        XCTAssertEqual(
            ScanDeadline.make(timeout: .greatestFiniteMagnitude, now: now),
            .distantFuture
        )
    }
}
