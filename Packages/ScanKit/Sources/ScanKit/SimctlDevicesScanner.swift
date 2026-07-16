import Foundation
import LogKit

/// Apple 工作流配套：simctl 模拟器**设备实例**扫描器（v1.7 M1 PR-3）。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §Apple）：
/// - 现状：`~/Library/Developer/CoreSimulator/Devices/<UDID>` 是每个模拟器实例的 sandbox 根，
///   单台 iPhone 模拟器装上 App + 截图 + 缓存后常驻 1~3 GB，跨多个 runtime / 多型号
///   设备实例叠加后能轻易占用 10~30 GB。Xcode UI 只暴露"Erase All Content"，不解决残留实例本身。
/// - 目标：枚举所有已创建的 simctl device（包括 Shutdown / Booted 各种状态），
///   并把 simctl 自报的 `dataPathSize` 直出，交给 [DeveloperWorkflow] 的 Apple 卡片渲染；
///   后续 PR 接 `simctl delete <UDID>` 删除路径（allowlist 已就绪）。
///
/// 与 [SimctlRuntimeScanner] / [PkgutilReceiptsScanner] 的关系：
/// - 与 SimctlRuntimeScanner 是**姊妹扫描器**：一个管 runtime（系统镜像），一个管 device（实例 sandbox）；
///   都依赖 [SubprocessExecutor]，且共享 `xcrun simctl list ...` 白名单条目。
/// - 与 PkgutilReceiptsScanner 一样**不走 FS 枚举**——device 清单的权威是
///   `xcrun simctl list devices --json`，里面带 udid / state / dataPath / dataPathSize 元数据，
///   FS 枚举拿不到（也无法判断"是否正在 Booted 中"）。
///
/// 双入口（对位 [KnownVersionedRoots] 静态 detect + actor discover 范式，
/// 与 [SimctlRuntimeScanner] 完全同构）：
/// 1. `static detect(from json:)`：**纯解析**，无 IO，专供单测；
/// 2. `actor discover()`：起 subprocess 拿 JSON，生产用。
///
/// 完整性红线（与 SimctlRuntimeScanner 一致）：
/// - 只有命令成功、JSON 合法且 `devices` 确实为空才返回 `[]`；
/// - launch / timeout / 非 0 / schema 变化抛 [SimctlDiscoveryError]，由 Workflow evidence
///   展示“扫描失败，可重试”，不能伪装成“没有设备”。
/// - `dataPathSize` 字段在老 simctl（Xcode 14 之前）可能不存在，解析为 `nil` 而非 0，UI 侧据此显示 "—"。
public actor SimctlDevicesScanner {

    private let executor: SubprocessExecutor

    public init(executor: SubprocessExecutor = SubprocessExecutor()) {
        self.executor = executor
    }

    /// 起 `xcrun simctl list devices --json` 拿全部已创建模拟器实例。
    ///
    /// - Returns: 设备列表（已 flatten 各 runtime 下的子数组）；完整成功空清单才返回 `[]`。
    /// - Throws: [SimctlDiscoveryError]，表示本轮结果不完整、不可解释为“没有设备”。
    public func discover() async throws -> [SimctlDevice] {
        let result: SubprocessExecutor.Result
        do {
            result = try executor.run(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "list", "devices", "--json"]
            )
        } catch {
            throw SimctlDiscoveryError.commandRejected(query: .devices)
        }
        if let failure = SimctlDiscoveryError.commandFailure(for: result, query: .devices) {
            GSYLog.warning(.app, "SimctlDevicesScanner command failure: \(failure); output=\(Self.logExcerpt(result.output))")
            throw failure
        }
        return try Self.decode(from: result.output)
    }

    /// 纯解析入口：把 simctl JSON 字符串转 `[SimctlDevice]`。
    ///
    /// simctl 顶层结构（基于 Apple 公开 API）：
    /// ```json
    /// {
    ///   "devices": {
    ///     "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
    ///       {"udid":"...","name":"iPhone 16","state":"Shutdown","dataPath":"...","dataPathSize":12345}
    ///     ]
    ///   }
    /// }
    /// ```
    /// 外层 key（runtime identifier）会被 flatten 注入到每条 device 的 `runtimeIdentifier` 字段。
    ///
    /// 兼容 hits-only 调用方的纯解析入口。生产 discover 使用 throwing [decode(from:)]，
    /// 因此这里的空数组不能作为完整性证据。
    public static func detect(from json: String) -> [SimctlDevice] {
        do {
            return try decode(from: json)
        } catch {
            GSYLog.warning(.app, "SimctlDevicesScanner JSON 解析失败: \(error)")
            return []
        }
    }

    /// 严格解析入口：schema 不匹配即抛 typed failure；合法 `{"devices": {}}` 返回空。
    public static func decode(from json: String) throws -> [SimctlDevice] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8) else {
            throw SimctlDiscoveryError.invalidPayload(query: .devices)
        }
        // 用 JSONSerialization 而非 Decodable：因为外层 key（runtime identifier）是动态的，
        // 自定义 CodingKey 容器反而比 dictionary 遍历更绕。
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SimctlDiscoveryError.invalidPayload(query: .devices)
        }
        guard let root = object as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else {
            throw SimctlDiscoveryError.invalidPayload(query: .devices)
        }

        var result: [SimctlDevice] = []
        result.reserveCapacity(devicesByRuntime.count * 4)
        // 排序保证 detect 输出确定性（同 runtime 下保留 simctl 原顺序）
        for runtimeID in devicesByRuntime.keys.sorted() {
            guard let list = devicesByRuntime[runtimeID] as? [[String: Any]] else {
                throw SimctlDiscoveryError.invalidPayload(query: .devices)
            }
            for raw in list {
                guard let udid = raw["udid"] as? String,
                      let name = raw["name"] as? String,
                      let state = raw["state"] as? String,
                      let dataPath = raw["dataPath"] as? String else {
                    throw SimctlDiscoveryError.invalidPayload(query: .devices)
                }
                let dataPathSize = Self.parseDataPathSize(raw["dataPathSize"])
                result.append(SimctlDevice(
                    udid: udid,
                    name: name,
                    state: state,
                    runtimeIdentifier: runtimeID,
                    dataPath: dataPath,
                    dataPathSize: dataPathSize
                ))
            }
        }
        return result
    }

    private static func logExcerpt(_ output: String) -> String {
        String(output.prefix(512)).replacingOccurrences(of: "\n", with: " ")
    }

    /// `dataPathSize` 在不同 simctl 版本可能是 NSNumber（Int64）/ Int / Double，统一兜底为 Int64?。
    /// 字段不存在 / 类型非法 / 负数 → 返回 nil。
    private static func parseDataPathSize(_ raw: Any?) -> Int64? {
        guard let raw else { return nil }
        if let n = raw as? Int64 { return n >= 0 ? n : nil }
        if let n = raw as? Int { return n >= 0 ? Int64(n) : nil }
        if let n = raw as? NSNumber { return n.int64Value >= 0 ? n.int64Value : nil }
        if let d = raw as? Double { return d >= 0 ? Int64(d) : nil }
        return nil
    }
}

/// CoreSimulator 设备运行态的权威、同步提交前探针。
///
/// **v2026.07.16 根因修复**：只看 `Simulator.app` 进程会漏掉由 `simctl boot`、测试任务
/// 或 Xcode 启动的 headless Booted device。managed delete 的最后执行闸必须读取
/// `simctl list devices --json`；查询/解析失败时 fail closed，绝不把“不知道”当作安全。
public struct SimctlBootedDeviceProbe: Sendable {
    public enum ProbeResult: Sendable, Hashable {
        /// 所有权威清单里的设备都处于 Shutdown；可继续做相邻的 App-process 复核。
        case safeToSubmit
        /// 至少一个设备处于 Booted/Booting/Shutting Down 或未来未知的非 Shutdown 状态。
        case activeDevices(displayNames: [String])
        /// 命令拒绝、launch/timeout/nonzero 或 payload 变化，无法证明安全。
        case verificationUnavailable
    }

    private let executor: SubprocessExecutor

    public init(executor: SubprocessExecutor = SubprocessExecutor(timeout: 5)) {
        self.executor = executor
    }

    /// 同步 API 是刻意设计：它由 `SubprocessExecutor` 的 detached producer 在
    /// `Process.run()` 前调用，调用完成到 destructive process 提交之间没有 await。
    public func probe() -> ProbeResult {
        let result: SubprocessExecutor.Result
        do {
            result = try executor.run(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "list", "devices", "--json"]
            )
        } catch {
            GSYLog.warning(.app, "Simulator submit guard: simctl devices query rejected: \(error)")
            return .verificationUnavailable
        }
        guard result.exitCode == 0 else {
            GSYLog.warning(
                .app,
                "Simulator submit guard: simctl devices query failed exit=\(result.exitCode) output=\(Self.logExcerpt(result.output))"
            )
            return .verificationUnavailable
        }

        return Self.classify(json: result.output)
    }

    /// 纯解析入口供提交闸测试；未知/过渡状态也视为 active，只有全 Shutdown 才安全。
    static func classify(json: String) -> ProbeResult {
        guard let devices = try? SimctlDevicesScanner.decode(from: json) else {
            return .verificationUnavailable
        }
        let active = devices.filter {
            $0.state.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Shutdown") != .orderedSame
        }
        guard active.isEmpty else {
            return .activeDevices(displayNames: active.map { "\($0.name) (\($0.state))" })
        }
        return .safeToSubmit
    }

    private static func logExcerpt(_ output: String) -> String {
        String(output.prefix(512)).replacingOccurrences(of: "\n", with: " ")
    }
}

/// 持久 pending ledger 的权威对账探针。
///
/// tombstone 不能按时间删除，也不能因 App 重启就遗忘；只有 simctl 的当前设备/runtime
/// 清单明确不再包含目标 UUID 时才返回 `.absent`。任何命令或 schema 问题均 fail closed。
public struct SimctlManagedResourceAuthorityProbe: Sendable {
    public enum Presence: Sendable, Hashable {
        case present
        case absent
        case verificationUnavailable
    }

    private let executor: SubprocessExecutor

    public init(executor: SubprocessExecutor = SubprocessExecutor(timeout: 5)) {
        self.executor = executor
    }

    public func presence(
        of identifier: String,
        kind: ManagedUninstallRecipe
    ) -> Presence {
        guard let uuid = UUID(uuidString: identifier)?.uuidString.lowercased() else {
            return .verificationUnavailable
        }
        switch kind {
        case .simulatorDevice:
            return devicePresence(uuid: uuid)
        case .simulatorRuntime:
            return runtimePresence(uuid: uuid)
        }
    }

    private func devicePresence(uuid: String) -> Presence {
        guard let output = successfulOutput(
            args: ["simctl", "list", "devices", "--json"],
            label: "devices"
        ) else { return .verificationUnavailable }
        do {
            let devices = try SimctlDevicesScanner.decode(from: output)
            var identifiers = Set<String>()
            for device in devices {
                guard let canonical = UUID(uuidString: device.udid)?.uuidString.lowercased(),
                      identifiers.insert(canonical).inserted else {
                    return .verificationUnavailable
                }
            }
            return identifiers.contains(uuid) ? .present : .absent
        } catch {
            GSYLog.warning(.app, "Simulator authority: invalid devices payload: \(error)")
            return .verificationUnavailable
        }
    }

    private func runtimePresence(uuid: String) -> Presence {
        guard let output = successfulOutput(
            args: ["simctl", "runtime", "list", "-j"],
            label: "runtimes"
        ), let data = output.data(using: .utf8) else {
            return .verificationUnavailable
        }
        do {
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .verificationUnavailable
            }
            var identifiers = Set<String>()
            for (key, rawValue) in payload {
                guard let value = rawValue as? [String: Any],
                      let keyUUID = UUID(uuidString: key)?.uuidString.lowercased() else {
                    return .verificationUnavailable
                }
                if let rawIdentifier = value["identifier"] {
                    guard let identifier = rawIdentifier as? String,
                          let canonical = UUID(uuidString: identifier)?.uuidString.lowercased(),
                          canonical == keyUUID else {
                        return .verificationUnavailable
                    }
                }
                guard identifiers.insert(keyUUID).inserted else {
                    return .verificationUnavailable
                }
            }
            return identifiers.contains(uuid) ? .present : .absent
        } catch {
            GSYLog.warning(.app, "Simulator authority: invalid runtimes payload: \(error)")
            return .verificationUnavailable
        }
    }

    private func successfulOutput(args: [String], label: String) -> String? {
        do {
            let result = try executor.run(executable: "/usr/bin/xcrun", args: args)
            guard result.exitCode == 0 else {
                GSYLog.warning(
                    .app,
                    "Simulator authority: \(label) query failed exit=\(result.exitCode) output=\(String(result.output.prefix(512)))"
                )
                return nil
            }
            return result.output
        } catch {
            GSYLog.warning(.app, "Simulator authority: \(label) query rejected: \(error)")
            return nil
        }
    }
}

/// 单个 simctl 模拟器设备实例。
public struct SimctlDevice: Sendable, Hashable, Identifiable {
    /// simctl 主键 UDID，如 `"D1A4B...-..."`。后续 `simctl delete <udid>` 也以此为参数。
    public let udid: String
    /// 用户可读名，如 `"iPhone 16"` / `"iPhone 15 Pro Max"`。
    public let name: String
    /// 当前状态字符串：`"Shutdown"` / `"Booted"` / `"Shutting Down"` / `"Booting"` 等。
    /// 不枚举化以容纳 simctl 后续可能新增的状态值。
    public let state: String
    /// 所属 runtime 的 identifier，如 `"com.apple.CoreSimulator.SimRuntime.iOS-18-0"`。
    /// 由外层 dict key 注入。
    public let runtimeIdentifier: String
    /// 该设备 sandbox 目录绝对路径，通常形如
    /// `/Users/<u>/Library/Developer/CoreSimulator/Devices/<UDID>/data`。
    public let dataPath: String
    /// simctl 自报的 sandbox 占用（字节）。
    /// `nil` 表示该版本 simctl 未输出 `dataPathSize` 字段（Xcode 14 之前不带），
    /// UI 侧据此显示 "—" 而不是 "0 B"。
    public let dataPathSize: Int64?

    public var id: String { udid }

    public init(udid: String,
                name: String,
                state: String,
                runtimeIdentifier: String,
                dataPath: String,
                dataPathSize: Int64?) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtimeIdentifier = runtimeIdentifier
        self.dataPath = dataPath
        self.dataPathSize = dataPathSize
    }
}
