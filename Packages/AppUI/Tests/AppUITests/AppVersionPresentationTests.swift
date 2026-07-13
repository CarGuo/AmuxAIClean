import XCTest
@testable import AppUI

final class AppVersionPresentationTests: XCTestCase {
    func test_mainToolbar_展示Bundle真实版本而不是写死版本号() throws {
        let source = try mainViewSource()

        XCTAssertTrue(source.contains("appVersionBadge"))
        XCTAssertTrue(source.contains("let version = UpdateChecker.currentVersion"))
        XCTAssertTrue(source.contains("Text(verbatim: version)"))
        XCTAssertFalse(source.contains("Text(verbatim: \"1.6.0\")"))
    }

    func test_mainToolbar_版本号具备本地化辅助说明() throws {
        let source = try mainViewSource()

        XCTAssertTrue(source.contains("updater.prompt.current_version %@"))
        XCTAssertTrue(source.contains(".accessibilityLabel(accessibleLabel)"))
        XCTAssertTrue(source.contains(".help(accessibleLabel)"))
    }

    private func mainViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("AppUI")
            .appendingPathComponent("MainView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
