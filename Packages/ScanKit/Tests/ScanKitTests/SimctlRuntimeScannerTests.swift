import XCTest
@testable import ScanKit

/// v1.7 M1 PR-3：SimctlRuntimeScanner 行为契约。
///
/// 关注两条入口：
/// 1. `static detect(from:)` —— 纯解析，覆盖空/合法/缺字段/非法/不可用各情形；
/// 2. `actor discover()` —— 走 SubprocessExecutor，dryRun 模式输出非合法 JSON，应回退为 []。
final class SimctlRuntimeScannerTests: XCTestCase {

    // MARK: - detect 纯解析

    func test_detect_空字符串_返回空() {
        XCTAssertEqual(SimctlRuntimeScanner.detect(from: "").count, 0)
    }

    func test_detect_合法包含两个runtime_全部解析() {
        let json = """
        {
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
              "version": "18.0",
              "buildversion": "22A348",
              "runtimeRoot": "/Library/Developer/CoreSimulator/Volumes/iOS_18.0/x/RuntimeRoot",
              "isAvailable": true
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
              "version": "11.0",
              "buildversion": "22R345",
              "runtimeRoot": "/Library/Developer/CoreSimulator/Volumes/watchOS_11.0/y/RuntimeRoot",
              "isAvailable": true
            }
          ]
        }
        """
        let runtimes = SimctlRuntimeScanner.detect(from: json)
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(runtimes[0].identifier, "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        XCTAssertEqual(runtimes[0].version, "18.0")
        XCTAssertEqual(runtimes[0].buildversion, "22A348")
        XCTAssertTrue(runtimes[0].runtimeRoot.contains("iOS_18.0"))
        XCTAssertTrue(runtimes[0].isAvailable)
        XCTAssertNil(runtimes[0].sizeBytes, "detect 入口不应填 sizeBytes")
        XCTAssertEqual(runtimes[1].identifier, "com.apple.CoreSimulator.SimRuntime.watchOS-11-0")
        XCTAssertEqual(runtimes[1].version, "11.0")
    }

    func test_detect_缺少buildversion_容错为nil() {
        let json = """
        {
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-17-5",
              "version": "17.5",
              "runtimeRoot": "/Library/Developer/CoreSimulator/Volumes/tvOS_17.5/z/RuntimeRoot",
              "isAvailable": true
            }
          ]
        }
        """
        let runtimes = SimctlRuntimeScanner.detect(from: json)
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertNil(runtimes[0].buildversion)
        XCTAssertEqual(runtimes[0].version, "17.5")
    }

    func test_detect_isAvailable_false_仍纳入结果() {
        let json = """
        {
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-4",
              "version": "16.4",
              "buildversion": "20F66",
              "runtimeRoot": "/Library/Developer/CoreSimulator/Volumes/iOS_16.4/x/RuntimeRoot",
              "isAvailable": false
            }
          ]
        }
        """
        let runtimes = SimctlRuntimeScanner.detect(from: json)
        XCTAssertEqual(runtimes.count, 1, "isAvailable=false 仍然要返回，让 UI 决定过滤策略")
        XCTAssertFalse(runtimes[0].isAvailable)
    }

    func test_detect_非法JSON_返回空不抛() {
        // 既测试根本不是 JSON 的字符串，也测试 JSON 但顶层结构不匹配的情形
        XCTAssertEqual(SimctlRuntimeScanner.detect(from: "not a json at all").count, 0)
        XCTAssertEqual(SimctlRuntimeScanner.detect(from: "{\"devices\":{}}").count, 0)
        XCTAssertEqual(SimctlRuntimeScanner.detect(from: "{\"runtimes\": \"oops\"}").count, 0)
    }

    // MARK: - discover (actor)

    func test_discover_dryRun模式_返回空数组() async throws {
        let executor = SubprocessExecutor(dryRun: true)
        let scanner = SimctlRuntimeScanner(executor: executor)
        let runtimes = try await scanner.discover()
        XCTAssertEqual(runtimes.count, 0,
                       "dryRun 输出不是合法 simctl JSON，应被 detect 兜底为空")
    }
}
