import XCTest
import Foundation
@testable import AIKit

final class AISettingsTests: XCTestCase {

    private func suiteName() -> String { "AIKitTests.AISettings.\(UUID().uuidString)" }

    @MainActor
    func test_default_values_on_fresh_suite() {
        let s = AISettings(testSuite: suiteName())
        XCTAssertFalse(s.enabled, "enabled must default OFF")
        XCTAssertEqual(s.baseURL, "https://api.openai.com")
        XCTAssertEqual(s.model, "gpt-4o-mini")
        XCTAssertEqual(s.temperature, 0.2, accuracy: 1e-9)
        XCTAssertTrue(s.redactPaths, "redactPaths must default ON for privacy")
        XCTAssertFalse(s.isReadyForUI, "enabled OFF → not ready")
    }

    @MainActor
    func test_didSet_persists_and_round_trip() {
        let suite = suiteName()
        do {
            let s = AISettings(testSuite: suite)
            s.enabled = true
            s.baseURL = "https://api.deepseek.com"
            s.model = "deepseek-chat"
            s.temperature = 0.7
            s.redactPaths = false
        }
        // 重新构造：值必须 round-trip
        let s2 = AISettings(testSuite: suite)
        XCTAssertTrue(s2.enabled)
        XCTAssertEqual(s2.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(s2.model, "deepseek-chat")
        XCTAssertEqual(s2.temperature, 0.7, accuracy: 1e-9)
        XCTAssertFalse(s2.redactPaths)
        XCTAssertTrue(s2.isReadyForUI)
    }

    @MainActor
    func test_isReadyForUI_requires_all_three() {
        let s = AISettings(testSuite: suiteName())
        XCTAssertFalse(s.isReadyForUI)
        s.enabled = true
        XCTAssertTrue(s.isReadyForUI, "enabled + 默认 baseURL/model 即可")
        s.baseURL = ""
        XCTAssertFalse(s.isReadyForUI)
        s.baseURL = "http://localhost:11434"
        s.model = ""
        XCTAssertFalse(s.isReadyForUI)
    }
}
