import Foundation
import XCTest
@testable import AppUI

/// v2026.10.08: real port/Dart actions showed a blocking alert after confirmed success.
/// Acknowledgement may be nonmodal only when no unresolved or failed result remains.
final class ProcessTerminationCompletionTests: XCTestCase {
    func test_onlyConfirmedFullSuccessUsesNonmodalFeedback() {
        let success = summary([.terminated, .alreadyExited])
        XCTAssertEqual(ProcessTerminationSuccessFeedback(summary: success)?.stoppedCount, 2)
        XCTAssertNil(ProcessTerminationSuccessFeedback(summary: summary([])))
        for unresolved: ProcessKillDisposition in [
            .terminationRequested, .notSubmittedBatchLimit, .identityChanged,
            .identityUnavailable, .currentApplicationProtected, .invalidPID,
            .processBecameProtected, .systemFailure(code: 1)
        ] {
            let mixed = summary([.terminated, unresolved])
            XCTAssertNil(ProcessTerminationSuccessFeedback(summary: mixed),
                         "\(unresolved) must retain the detailed result instead of a success banner")
        }
    }

    func test_feedbackLocalizesAtPresentationAndKeepsReceiptIdentityDistinct() throws {
        // SwiftPM copies raw xcstrings; its DEBUG fallback cannot resolve plural tokens.
        // Compile the real catalog with Apple's tool, retaining exact runtime assertions.
        let catalog = try compiledCatalogBundle()
        let one = try XCTUnwrap(ProcessTerminationSuccessFeedback(summary: summary([.terminated])))
        let two = try XCTUnwrap(ProcessTerminationSuccessFeedback(summary: summary([.terminated, .alreadyExited])))
        XCTAssertNotEqual(one.id, two.id, "an old dismiss timer must not own a later receipt")
        XCTAssertEqual(one.message.localized(locale: Locale(identifier: "en"), bundle: catalog), "1 process stopped")
        XCTAssertEqual(two.message.localized(locale: Locale(identifier: "en"), bundle: catalog), "2 processes stopped")
        XCTAssertEqual(two.message.localized(locale: Locale(identifier: "zh-Hans"), bundle: catalog), "已结束 2 个进程")
    }

    private func summary(_ dispositions: [ProcessKillDisposition]) -> ProcessKillResultSummary {
        ProcessKillResultSummary.summarize(dispositions.enumerated().map {
            ProcessKillResult(pid: Int32(10_000 + $0.offset), disposition: $0.element)
        })
    }

    private func compiledCatalogBundle() throws -> Bundle {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = package.appendingPathComponent("Sources/AppUI/Resources/Localizable.xcstrings")
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppUI-CompiledCatalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["xcstringstool", "compile", "--output-directory", output.path, catalog.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "real String Catalog compilation must succeed")
        return try XCTUnwrap(Bundle(path: output.path))
    }
}
