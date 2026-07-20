import Foundation
import ScanKit
import XCTest
@testable import AppUI

/// v2026.07.15：服务层只保留语义/系统事实；同一个结果可在同一进程按当前 App
/// locale 重投影。测试不执行删除、端口终止或网络请求。
final class ServiceLocalizationProjectionTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private let chinese = Locale(identifier: "zh-Hans")

    func testTypedServiceFailuresReprojectWithoutRepeatingOperation() {
        let undo = UndoHistoryStore.RestoreFailure.destinationAlreadyExists(path: "/tmp/item")
        assertReprojects(undo.message(locale: english), undo.message(locale: chinese))

        let port = PortCleanerKillDisposition.currentApplicationProtected
        assertReprojects(port.message(locale: english), port.message(locale: chinese))

        let metadata = AppMetadataReadError.missingBundleIdentifier
        assertReprojects(metadata.message(locale: english), metadata.message(locale: chinese))

        let updater = UpdateCheckFailure.httpStatus(503)
        assertReprojects(updater.message(locale: english), updater.message(locale: chinese))
        XCTAssertTrue(updater.message(locale: english).contains("503"))

        let trash = TrashFailureSummary.recycleFailed(
            failedCount: 2,
            movedCount: 1,
            firstPath: "/tmp/locked"
        )
        assertReprojects(trash.message(locale: english), trash.message(locale: chinese))
        XCTAssertTrue(trash.message(locale: chinese).contains("/tmp/locked"))

        let smartCare = SmartCareFailureDetail.scanIncomplete
        assertReprojects(
            smartCare.text(locale: english),
            smartCare.text(locale: chinese)
        )
    }

    func testSmartCareMissingFallbackRemainsSemanticUntilViewProjection() {
        let snapshot = ScanSnapshot(
            categoryID: "test",
            rows: [],
            totalBytes: 0,
            scannedFileCount: 0,
            isFinished: false,
            elapsed: 0
        )

        XCTAssertEqual(
            SmartCareSnapshotCompletionPolicy.decision(
                snapshot: snapshot,
                isScanning: false,
                scanPhase: .idle,
                terminalFailure: nil,
                hasDeletionDeniedEvidence: false,
                fallbackError: nil
            ),
            .fail(.scanIncomplete)
        )
    }

    private func assertReprojects(
        _ englishText: String,
        _ chineseText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(englishText, chineseText, file: file, line: line)
        XCTAssertFalse(englishText.isEmpty, file: file, line: line)
        XCTAssertFalse(chineseText.isEmpty, file: file, line: line)
    }
}
