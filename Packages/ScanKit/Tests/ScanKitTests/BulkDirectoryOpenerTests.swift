import Darwin
import XCTest
@testable import ScanKit

final class BulkDirectoryOpenerTests: XCTestCase {
    func testInterruptedOpenRetriesUntilSuccessWithoutReturningFailure() {
        var attempts: [BulkDirectoryOpener.Attempt] = [
            .failed(EINTR),
            .failed(EINTR),
            .opened(42)
        ]
        var observedPaths: [String] = []

        let outcome = BulkDirectoryOpener.open(
            path: "/fixture/root",
            shouldCancel: { false },
            attempt: { path in
                observedPaths.append(path)
                return attempts.removeFirst()
            }
        )

        XCTAssertEqual(outcome, .opened(42))
        XCTAssertEqual(observedPaths, ["/fixture/root", "/fixture/root", "/fixture/root"])
        XCTAssertTrue(attempts.isEmpty)
    }

    func testNonInterruptedFailurePreservesExactErrnoAfterRetry() {
        var attempts: [BulkDirectoryOpener.Attempt] = [
            .failed(EINTR),
            .failed(EACCES)
        ]

        let outcome = BulkDirectoryOpener.open(
            path: "/fixture/denied",
            shouldCancel: { false },
            attempt: { _ in attempts.removeFirst() }
        )

        XCTAssertEqual(outcome, .failed(EACCES))
        XCTAssertTrue(attempts.isEmpty)
    }

    func testCancellationBeforeOpenDoesNotInvokeSyscallOrReturnFailure() {
        var attemptCount = 0

        let outcome = BulkDirectoryOpener.open(
            path: "/fixture/cancelled",
            shouldCancel: { true },
            attempt: { _ in
                attemptCount += 1
                return .failed(EACCES)
            }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(attemptCount, 0)
    }

    func testCancellationAfterInterruptedOpenStopsRetryWithoutReturningFailure() {
        var isCancelled = false
        var attemptCount = 0

        let outcome = BulkDirectoryOpener.open(
            path: "/fixture/cancelled-after-interrupt",
            shouldCancel: { isCancelled },
            attempt: { _ in
                attemptCount += 1
                isCancelled = true
                return .failed(EINTR)
            }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(attemptCount, 1)
    }
}
