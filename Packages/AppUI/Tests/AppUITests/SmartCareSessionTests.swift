import XCTest
@testable import AppUI

@MainActor
final class SmartCareSessionTests: XCTestCase {
    func testDefaultSourcesKeepFastSafeScanOrder() {
        XCTAssertEqual(
            SmartCareSession.defaultSources,
            [.recommended, .commonAppCache, .developer]
        )
        XCTAssertEqual(
            SmartCareSession.defaultStages,
            [.core, .appCaches, .developerCaches]
        )
    }

    func testScanScopesAreSelectableBeforeScanning() {
        let session = SmartCareSession(scanCoordinator: ScanCoordinator(vendors: []))

        session.setStage(.appCaches, selected: false)
        session.setStage(.developerCaches, selected: false)

        XCTAssertEqual(session.orderedSelectedStages, [.core])

        session.setStage(.developerCaches, selected: true)
        XCTAssertEqual(session.orderedSelectedStages, [.core, .developerCaches])
    }

    func testScanDoesNotStartWhenEveryScopeIsDisabled() {
        let scanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(scanCoordinator: scanner)
        for stage in SmartCareSession.defaultStages {
            session.setStage(stage, selected: false)
        }

        session.startScan(includeHidden: false, enabledDeveloperRuleIDs: [])

        XCTAssertEqual(session.care.phase, .idle)
        XCTAssertFalse(scanner.isScanning)
        XCTAssertFalse(scanner.wasCancelled)
    }

    func testPrepareForRescanReturnsToScopeSelectionWithoutStartingScanner() {
        let care = SmartCareCoordinator(summary: .empty)
        care.beginScan()
        care.finishScan(.empty)
        let scanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(care: care, scanCoordinator: scanner)

        session.prepareForRescan()

        XCTAssertEqual(care.phase, .idle)
        XCTAssertFalse(scanner.isScanning)
        XCTAssertEqual(session.orderedSelectedStages, SmartCareSession.defaultStages)
    }

    func testCancelMovesCareStateToCancelled() {
        let care = SmartCareCoordinator()
        let scanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(care: care, scanCoordinator: scanner)

        session.cancelScan()

        guard case .cancelled = care.phase else {
            return XCTFail("Expected cancelled phase")
        }
        XCTAssertFalse(session.isBusy)
    }

    func testSessionOwnsDedicatedScannerAndCannotCancelProfessionalScanner() {
        let professionalScanner = ScanCoordinator(vendors: [])
        let normalScanner = ScanCoordinator(vendors: [])
        let session = SmartCareSession(scanCoordinator: normalScanner)

        session.cancelScan()

        XCTAssertTrue(session.scanCoordinator === normalScanner)
        XCTAssertTrue(normalScanner.wasCancelled)
        XCTAssertFalse(professionalScanner.wasCancelled)
    }
}
