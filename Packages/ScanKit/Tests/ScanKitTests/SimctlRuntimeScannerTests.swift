import XCTest
@testable import ScanKit

/// v1.7 M1 PR-3：SimctlRuntimeScanner 行为契约。
///
/// 关注两条入口：
/// 1. `static detect(from:)` —— 同时覆盖 managed runtime map 与 legacy runtimes array；
/// 2. 只有 managed JSON 中 `deletable=true` 的合法 UUID 才能成为卸载 ID；
/// 3. legacy 可展示但绝不会产出托管卸载 ID。
final class SimctlRuntimeScannerTests: XCTestCase {

    // MARK: - detect 纯解析

    func test_detect_空字符串_返回空() {
        XCTAssertEqual(SimctlRuntimeScanner.detect(from: "").count, 0)
    }

    func test_detect_managedRuntimeList_解析UUID_deletable_sizeBytes_runtimeIdentifier() {
        let json = """
        {
          "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7": {
            "identifier": "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            "version": "18.0",
            "build": "22A3351",
            "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/iOS_22A3351/iOS 18.0.simruntime",
            "state": "Ready",
            "deletable": true,
            "sizeBytes": 8361951702
          },
          "11111111-2222-3333-4444-555555555555": {
            "identifier": "11111111-2222-3333-4444-555555555555",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
            "version": "11.0",
            "build": "22R345",
            "mountPath": "/Library/Developer/CoreSimulator/Volumes/watchOS_22R345",
            "state": "Staging",
            "deletable": false,
            "sizeBytes": 4096
          }
        }
        """
        let runtimes = SimctlRuntimeScanner.detect(from: json)
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(runtimes[0].runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        XCTAssertEqual(runtimes[0].managedUninstallIdentifier,
                       "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7")
        XCTAssertEqual(runtimes[0].version, "18.0")
        XCTAssertEqual(runtimes[0].buildversion, "22A3351")
        XCTAssertEqual(runtimes[0].sizeBytes, 8_361_951_702)
        XCTAssertEqual(runtimes[0].deletable, true)
        XCTAssertTrue(runtimes[0].isAvailable)
        XCTAssertEqual(runtimes[1].deletable, false)
        XCTAssertNil(runtimes[1].managedUninstallIdentifier,
                     "deletable=false 的 runtime 只展示，不得产出卸载 ID")
        XCTAssertFalse(runtimes[1].isAvailable)
    }

    func test_detect_managedRuntimeList_deletable但UUID非法_不产出卸载ID() {
        let json = """
        {
          "not-a-uuid": {
            "identifier": "not-a-uuid",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            "version": "18.0",
            "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/iOS_18",
            "deletable": true,
            "sizeBytes": 1024
          }
        }
        """
        let runtime = SimctlRuntimeScanner.detect(from: json).first
        XCTAssertNotNil(runtime)
        XCTAssertNil(runtime?.managedUninstallIdentifier)
        XCTAssertEqual(runtime?.deletable, true)
    }

    func test_detect_legacy缺少buildversion_容错为nil且永不产出卸载ID() {
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
        XCTAssertEqual(runtimes[0].runtimeIdentifier,
                       "com.apple.CoreSimulator.SimRuntime.tvOS-17-5")
        XCTAssertNil(runtimes[0].managedUninstallIdentifier)
        XCTAssertNil(runtimes[0].deletable,
                     "legacy payload 没有 deletable 语义，必须保留未知而非猜测")
        XCTAssertNil(runtimes[0].sizeBytes)
        XCTAssertEqual(runtimes[0].discoverySource, .legacyReadOnly)
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

    func test_discover_dryRun模式_非法payload抛typedError() async {
        let executor = SubprocessExecutor(dryRun: true)
        let scanner = SimctlRuntimeScanner(executor: executor)
        do {
            _ = try await scanner.discover()
            XCTFail("dryRun 文本不是合法 JSON，不能伪装成完整空 runtime 清单")
        } catch let error as SimctlDiscoveryError {
            XCTAssertEqual(error, .invalidPayload(query: .managedRuntimes))
        } catch {
            XCTFail("应抛 SimctlDiscoveryError，实际：\(error)")
        }
    }

    func test_decode_合法managed与legacy空payload才返回完整空清单() throws {
        XCTAssertEqual(try SimctlRuntimeScanner.decode(from: "{}"), [])
        XCTAssertEqual(try SimctlRuntimeScanner.decode(from: #"{"runtimes":[]}"#), [])
    }

    func test_decode_非法payload抛typedError() {
        for payload in ["not-json", #"{"devices":{}}"#, #"{"runtimes":"oops"}"#] {
            XCTAssertThrowsError(try SimctlRuntimeScanner.decode(from: payload)) { error in
                XCTAssertEqual(
                    error as? SimctlDiscoveryError,
                    .invalidPayload(query: .managedRuntimes)
                )
            }
        }
    }

    func test_legacyFallback_只接受明确不支持子命令_不吞真实runtime失败() {
        XCTAssertTrue(SimctlRuntimeScanner.shouldUseLegacyFallback(for: .init(
            exitCode: 64,
            output: "Unrecognized subcommand: runtime"
        )))
        XCTAssertTrue(SimctlRuntimeScanner.shouldUseLegacyFallback(for: .init(
            exitCode: 1,
            output: "Unknown command runtime"
        )))
        XCTAssertFalse(SimctlRuntimeScanner.shouldUseLegacyFallback(for: .init(
            exitCode: 1,
            output: "CoreSimulator service failed while listing runtime images"
        )))
        XCTAssertFalse(SimctlRuntimeScanner.shouldUseLegacyFallback(for: .init(
            exitCode: -2,
            output: "timeout"
        )))
    }
}
