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

    /// v2026.09.20：同一份清单可能同时包含旧 /Library 挂载与新 Cryptex 挂载。
    /// /private/var/run 是已有系统目录，稳定触发 Foundation 去掉 /private 的旧误判；
    /// 其余路径不要求实际安装 runtime，解码结果不能依赖挂载目录是否存在。
    func test_decode_managedMixedMountPaths_preservesCompleteListAndSourcePaths() throws {
        let oldID = "11111111-2222-3333-4444-555555555555"
        let newID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let oldMount = "/Library/Developer/CoreSimulator/Volumes/iOS_23C54"
        let oldBundle = oldMount + "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.2.simruntime"
        for (mount, bundle) in [
            ("/private/var/run", "/private/var/run"),
            ("/private/var/run/com.apple.security.cryptexd/mnt/TestRuntime",
             "/private/var/run/com.apple.security.cryptexd/mnt/TestRuntime/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime"),
            ("/var/run/com.apple.security.cryptexd/mnt/TestRuntime",
             "/var/run/com.apple.security.cryptexd/mnt/TestRuntime/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime"),
        ] {
            let payload: [String: Any] = [
                oldID: [
                    "identifier": oldID, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
                    "version": "26.2", "runtimeBundlePath": oldBundle, "mountPath": oldMount,
                    "state": "Ready", "deletable": true, "sizeBytes": 8_381_044_573,
                ],
                newID: [
                    "identifier": newID, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                    "version": "27.0", "runtimeBundlePath": bundle, "mountPath": mount,
                    "state": "Ready", "deletable": true, "sizeBytes": 8_067_000_161,
                ],
            ]
            let runtimes = try SimctlRuntimeScanner.decode(from: jsonString(payload))
            XCTAssertEqual(runtimes.map(\.runtimeRoot), [oldBundle, bundle])
            XCTAssertEqual(runtimes.map(\.managedUninstallIdentifier), [oldID, newID])
            XCTAssertEqual(runtimes.map(\.sizeBytes), [8_381_044_573, 8_067_000_161])
            XCTAssertTrue(runtimes.allSatisfy { $0.isAvailable && $0.discoverySource == .managed })
        }
    }

    func test_decode_legacyAndMountOnly_acceptValidPathsWithoutInventingUninstallAuthority() throws {
        let identifier = "11111111-2222-3333-4444-555555555555"
        for path in [
            "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.0.simruntime",
            "/private/var/run",
            "/private/var/run/com.apple.security.cryptexd/mnt/TestRuntime",
        ] {
            let legacy = try SimctlRuntimeScanner.decode(from: jsonString([
                "runtimes": [[
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                    "version": "18.0", "runtimeRoot": path, "isAvailable": false,
                ]],
            ]))
            XCTAssertEqual(legacy.count, 1)
            XCTAssertEqual(legacy.first?.runtimeRoot, path)
            XCTAssertEqual(legacy.first?.discoverySource, .legacyReadOnly)
            XCTAssertNil(legacy.first?.managedUninstallIdentifier)
            XCTAssertNil(legacy.first?.sizeBytes)

            let mountOnly = try SimctlRuntimeScanner.decode(from: jsonString([
                identifier: [
                    "identifier": identifier, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                    "version": "18.0", "mountPath": path, "state": "Staging", "deletable": false,
                ],
            ]))
            XCTAssertEqual(mountOnly.count, 1)
            XCTAssertEqual(mountOnly.first?.runtimeRoot, path)
            XCTAssertEqual(mountOnly.first?.isAvailable, false)
            XCTAssertNil(mountOnly.first?.managedUninstallIdentifier)
        }
    }

    func test_decode_rejectsAmbiguousPathsInEveryRuntimePathField() throws {
        let identifier = "11111111-2222-3333-4444-555555555555"
        for path in [
            "", "/", "relative/runtime", "file:///private/var/run",
            "/private/var/../run", "/private/var/./run", "/private//var/run",
            "/private/var/run/", "/private/var/run\0other",
        ] {
            for field in ["runtimeBundlePath", "mountPath"] {
                let payload: [String: Any] = [identifier: [
                    "identifier": identifier, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                    "version": "18.0", field: path,
                ]]
                XCTAssertThrowsError(try SimctlRuntimeScanner.decode(from: jsonString(payload)), "\(field): \(path)")
            }
            let legacy: [String: Any] = ["runtimes": [[
                "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                "version": "18.0", "runtimeRoot": path, "isAvailable": true,
            ]]]
            XCTAssertThrowsError(try SimctlRuntimeScanner.decode(from: jsonString(legacy)), path)
        }
    }

    func test_decode_rejectsBundleOutsideMountIncludingSiblingPrefix() throws {
        let identifier = "11111111-2222-3333-4444-555555555555"
        for mount in [
            "/Library/Developer/CoreSimulator/Volumes/TestRuntime",
            "/private/var/run/com.apple.security.cryptexd/mnt/TestRuntime",
        ] {
            for bundle in [mount + "-other/iOS.simruntime", "/Library/Unrelated/iOS.simruntime"] {
                let payload: [String: Any] = [identifier: [
                    "identifier": identifier, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
                    "version": "18.0", "runtimeBundlePath": bundle, "mountPath": mount,
                ]]
                XCTAssertThrowsError(try SimctlRuntimeScanner.decode(from: jsonString(payload)))
            }
        }
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func test_detect_空字符串_返回空() {
        XCTAssertEqual(SimctlRuntimeScanner.detect(from: "").count, 0)
    }

    func test_detect_managedRuntimeList_解析UUID_deletable_sizeBytes_runtimeIdentifier() {
        let json = """
        {
          "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7": {
            "identifier": "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "kind": "Cryptex Disk Image",
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
            "platformIdentifier": "com.apple.platform.watchsimulator",
            "kind": "Patchable Cryptex Disk Image",
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
        XCTAssertEqual(runtimes[0].platformIdentifier, "com.apple.platform.iphonesimulator")
        XCTAssertEqual(runtimes[0].kind, "Cryptex Disk Image")
        XCTAssertEqual(runtimes[0].platformDisplayName, "iOS")
        XCTAssertEqual(runtimes[0].displayName, "iOS 18.0")
        XCTAssertEqual(runtimes[0].version, "18.0")
        XCTAssertEqual(runtimes[0].buildversion, "22A3351")
        XCTAssertEqual(runtimes[0].sizeBytes, 8_361_951_702)
        XCTAssertEqual(runtimes[0].deletable, true)
        XCTAssertTrue(runtimes[0].isAvailable)
        XCTAssertEqual(runtimes[1].deletable, false)
        XCTAssertNil(runtimes[1].managedUninstallIdentifier,
                     "deletable=false 的 runtime 只展示，不得产出卸载 ID")
        XCTAssertEqual(runtimes[1].platformDisplayName, "watchOS")
        XCTAssertEqual(runtimes[1].displayName, "watchOS 11.0")
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
        XCTAssertNil(runtimes[0].platformIdentifier)
        XCTAssertNil(runtimes[0].kind)
        XCTAssertEqual(runtimes[0].platformDisplayName, "tvOS")
        XCTAssertEqual(runtimes[0].displayName, "tvOS 17.5")
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

    func test_detect_managedRuntimeList_按真实平台区分visionOS而不是硬编码iOS() {
        let json = """
        {
          "12345678-1234-1234-1234-123456789ABC": {
            "identifier": "12345678-1234-1234-1234-123456789ABC",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.xrOS-2-0",
            "platformIdentifier": "com.apple.platform.xrsimulator",
            "kind": "Patchable Cryptex Disk Image",
            "version": "2.0",
            "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/xrOS_2",
            "state": "Ready",
            "deletable": true,
            "sizeBytes": 2048
          }
        }
        """

        let runtime = SimctlRuntimeScanner.detect(from: json).first
        XCTAssertEqual(runtime?.platformIdentifier, "com.apple.platform.xrsimulator")
        XCTAssertEqual(runtime?.kind, "Patchable Cryptex Disk Image")
        XCTAssertEqual(runtime?.platformDisplayName, "visionOS")
        XCTAssertEqual(runtime?.displayName, "visionOS 2.0")
    }

    func test_detect_managedRuntimeList_未知真实平台不回退冒充iOS() {
        let json = """
        {
          "12345678-1234-1234-1234-123456789ABC": {
            "identifier": "12345678-1234-1234-1234-123456789ABC",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-99-0",
            "platformIdentifier": "com.apple.platform.futureSimulator",
            "kind": "Future Disk Image",
            "version": "99.0",
            "runtimeBundlePath": "/tmp/Future.simruntime",
            "deletable": true
          }
        }
        """

        let runtime = SimctlRuntimeScanner.detect(from: json).first
        XCTAssertEqual(runtime?.platformDisplayName, "Simulator")
        XCTAssertEqual(runtime?.displayName, "Simulator 99.0")
        XCTAssertNotEqual(runtime?.displayName, "iOS 99.0")
    }

    func test_decode_拒绝重复identifier与空相对歧义runtimeRoot() {
        let duplicateRuntimeIdentifier = """
        {
          "11111111-1111-1111-1111-111111111111": {
            "identifier": "11111111-1111-1111-1111-111111111111",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            "version": "18.0", "mountPath": "/Library/Runtime/A"
          },
          "22222222-2222-2222-2222-222222222222": {
            "identifier": "22222222-2222-2222-2222-222222222222",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            "version": "18.0", "mountPath": "/Library/Runtime/B"
          }
        }
        """
        let relativeRoot = """
        {"11111111-1111-1111-1111-111111111111": {
          "identifier": "11111111-1111-1111-1111-111111111111",
          "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
          "version": "18.0", "runtimeBundlePath": "relative/runtime"
        }}
        """
        let ambiguousRoots = """
        {"11111111-1111-1111-1111-111111111111": {
          "identifier": "11111111-1111-1111-1111-111111111111",
          "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
          "version": "18.0",
          "runtimeBundlePath": "/Library/Runtime/A/iOS.simruntime",
          "mountPath": "/Library/Runtime/B"
        }}
        """
        let duplicateLegacyIdentifier = """
        {"runtimes": [
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","version":"18.0","runtimeRoot":"/Library/A","isAvailable":true},
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","version":"18.0","runtimeRoot":"/Library/B","isAvailable":true}
        ]}
        """

        for payload in [
            duplicateRuntimeIdentifier,
            relativeRoot,
            ambiguousRoots,
            duplicateLegacyIdentifier,
        ] {
            XCTAssertEqual(SimctlRuntimeScanner.detect(from: payload), [])
            XCTAssertThrowsError(try SimctlRuntimeScanner.decode(from: payload))
        }
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
