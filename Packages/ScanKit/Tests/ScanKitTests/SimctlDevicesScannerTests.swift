import XCTest
@testable import ScanKit

/// v1.7 M1 PR-3：SimctlDevicesScanner 行为契约。
///
/// 关注两条入口（与 [SimctlRuntimeScannerTests] 同构）：
/// 1. `static detect(from:)` —— 纯解析，覆盖空 / 合法多 runtime / 缺字段 / 非法 各情形；
/// 2. `actor discover()` —— 走 SubprocessExecutor；任何命令/JSON 失败必须抛 typed error，
///    只有合法 `devices: {}` 才代表完整空清单。
final class SimctlDevicesScannerTests: XCTestCase {

    // MARK: - detect 纯解析

    func test_detect_空字符串_返回空() {
        XCTAssertEqual(SimctlDevicesScanner.detect(from: "").count, 0)
    }

    func test_detect_合法两个runtime三个设备_全部flatten() {
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              {
                "udid": "UDID-IPHONE-16",
                "name": "iPhone 16",
                "state": "Shutdown",
                "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/UDID-IPHONE-16/data",
                "dataPathSize": 123456789
              },
              {
                "udid": "UDID-IPHONE-15PM",
                "name": "iPhone 15 Pro Max",
                "state": "Booted",
                "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/UDID-IPHONE-15PM/data",
                "dataPathSize": 987654321
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
              {
                "udid": "UDID-WATCH-S10",
                "name": "Apple Watch Series 10",
                "state": "Shutdown",
                "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/UDID-WATCH-S10/data",
                "dataPathSize": 555
              }
            ]
          }
        }
        """

        let devices = SimctlDevicesScanner.detect(from: json)
        XCTAssertEqual(devices.count, 3, "两个 runtime 下三条设备应全部 flatten 出来")

        let byUDID = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0) })

        let p16 = byUDID["UDID-IPHONE-16"]!
        XCTAssertEqual(p16.name, "iPhone 16")
        XCTAssertEqual(p16.state, "Shutdown")
        XCTAssertEqual(p16.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        XCTAssertTrue(p16.dataPath.hasSuffix("UDID-IPHONE-16/data"))
        XCTAssertEqual(p16.dataPathSize, 123456789)
        XCTAssertEqual(p16.id, p16.udid, "Identifiable.id 应直接复用 udid")

        let p15 = byUDID["UDID-IPHONE-15PM"]!
        XCTAssertEqual(p15.state, "Booted", "Booted 实例也要纳入清单，让 UI 决定是否禁用删除按钮")
        XCTAssertEqual(p15.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-18-0")

        let watch = byUDID["UDID-WATCH-S10"]!
        XCTAssertEqual(watch.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
                       "外层 runtime key 必须被注入到对应 device")
        XCTAssertEqual(watch.dataPathSize, 555)
    }

    func test_detect_缺少dataPathSize字段_容错为nil() {
        // Xcode 14 之前的 simctl 不输出 dataPathSize，应解析成 nil 而非 0 / 报错
        let json = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
              {
                "udid": "UDID-LEGACY",
                "name": "iPhone 13",
                "state": "Shutdown",
                "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/UDID-LEGACY/data"
              }
            ]
          }
        }
        """
        let devices = SimctlDevicesScanner.detect(from: json)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].udid, "UDID-LEGACY")
        XCTAssertNil(devices[0].dataPathSize,
                     "缺字段必须为 nil（UI 据此显示 — 而不是 0 B）")
    }

    func test_detect_非法JSON_返回空不抛() {
        // 三种"非法"形式都应回退为空数组，且绝不抛出
        XCTAssertEqual(SimctlDevicesScanner.detect(from: "not a json at all").count, 0)
        XCTAssertEqual(SimctlDevicesScanner.detect(from: "{\"runtimes\":[]}").count, 0,
                       "顶层缺 devices 字段时应返回空")
        XCTAssertEqual(SimctlDevicesScanner.detect(from: "{\"devices\": \"oops\"}").count, 0,
                       "devices 不是 dict 时应返回空")
    }

    // MARK: - discover (actor)

    func test_discover_当simctl命令被拒绝时_抛typedError() async {
        let executor = SubprocessExecutor(allowlist: [], dryRun: true)
        let scanner = SimctlDevicesScanner(executor: executor)
        do {
            _ = try await scanner.discover()
            XCTFail("allowlist 拒绝不能伪装成空设备清单")
        } catch let error as SimctlDiscoveryError {
            XCTAssertEqual(error, .commandRejected(query: .devices))
        } catch {
            XCTFail("应抛 SimctlDiscoveryError，实际：\(error)")
        }
    }

    func test_discover_dryRun模式不真执行且非法payload抛typedError() async {
        // 通过 timeout=0.01 + dryRun=true 验证：
        // - 若真起了 /usr/bin/xcrun 子进程，0.01s 必定 timeout（exitCode = -2），
        //   但 dryRun 闸门保证压根不进入 Process()，所以 discover 应在毫秒内返回；
        // - dryRun 输出 "<dryRun> /usr/bin/xcrun simctl list devices --json" 不是合法 JSON，
        //   detect 把它兜底为 []。
        let executor = SubprocessExecutor(timeout: 0.01, dryRun: true)
        let scanner = SimctlDevicesScanner(executor: executor)

        let start = Date()
        do {
            _ = try await scanner.discover()
            XCTFail("dryRun 文本不是合法 JSON，不能解释为完整空清单")
        } catch let error as SimctlDiscoveryError {
            XCTAssertEqual(error, .invalidPayload(query: .devices))
        } catch {
            XCTFail("应抛 SimctlDiscoveryError，实际：\(error)")
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0,
                          "dryRun 不应真起 Process；若起了子进程会被 0.01s timeout 拖到秒级")
    }

    func test_decode_合法空devices才返回完整空清单() throws {
        XCTAssertEqual(try SimctlDevicesScanner.decode(from: #"{"devices":{}}"#), [])
    }

    func test_decode_非法JSON与缺字段抛invalidPayload() {
        for payload in ["not-json", #"{"runtimes":[]}"#, #"{"devices":"oops"}"#] {
            XCTAssertThrowsError(try SimctlDevicesScanner.decode(from: payload)) { error in
                XCTAssertEqual(error as? SimctlDiscoveryError, .invalidPayload(query: .devices))
            }
        }
    }

    func test_subprocess失败码_映射为不同typedDiscoveryError() {
        XCTAssertEqual(
            SimctlDiscoveryError.commandFailure(
                for: .init(exitCode: -1, output: "launch"),
                query: .devices
            ),
            .launchFailed(query: .devices)
        )
        XCTAssertEqual(
            SimctlDiscoveryError.commandFailure(
                for: .init(exitCode: -2, output: "timeout"),
                query: .devices
            ),
            .timedOut(query: .devices)
        )
        XCTAssertEqual(
            SimctlDiscoveryError.commandFailure(
                for: .init(exitCode: 72, output: "xcrun failure"),
                query: .devices
            ),
            .commandFailed(query: .devices, exitCode: 72)
        )
    }
}
