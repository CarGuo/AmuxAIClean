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
/// 容错红线（与 SimctlRuntimeScanner 一致）：
/// - simctl 不可用（throw / exitCode -1 launch 失败 / -2 timeout / 非 0 退出）→ 返回 `[]`，**不抛**；
///   非 Apple 开发者机器没装 Xcode 是常见场景，UI 侧表现为"空清单"，不应让错误冒泡污染整个工作流。
/// - JSON 非法 / 顶层结构不对 → 返回 `[]` 并通过 [LogKit] 打 warning，便于排查 simctl 输出格式变迁。
/// - `dataPathSize` 字段在老 simctl（Xcode 14 之前）可能不存在，解析为 `nil` 而非 0，UI 侧据此显示 "—"。
public actor SimctlDevicesScanner {

    private let executor: SubprocessExecutor

    public init(executor: SubprocessExecutor = SubprocessExecutor()) {
        self.executor = executor
    }

    /// 起 `xcrun simctl list devices --json` 拿全部已创建模拟器实例。
    ///
    /// - Returns: 设备列表（已 flatten 各 runtime 下的子数组）；任何失败一律返回 `[]`。
    public func discover() async throws -> [SimctlDevice] {
        let result: SubprocessExecutor.Result
        do {
            result = try executor.run(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "list", "devices", "--json"]
            )
        } catch {
            // allowlist 拒绝 / 其他主动 throw（注入了不兼容的 executor 时才可能走到）
            return []
        }
        // exitCode != 0 包括 -1 launch 失败、-2 timeout、xcrun 真实非 0 退出
        // 非 Apple 开发者机器没装 Xcode 时 xcrun 会直接报错，全部按"空清单"处理
        guard result.isSuccess else { return [] }
        return Self.detect(from: result.output)
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
    /// 任何解析失败（空串、非 JSON、顶层 `devices` 不是 dict）一律返回 `[]`，并打 warning。
    public static func detect(from json: String) -> [SimctlDevice] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8) else {
            return []
        }
        // 用 JSONSerialization 而非 Decodable：因为外层 key（runtime identifier）是动态的，
        // 自定义 CodingKey 容器反而比 dictionary 遍历更绕。
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            GSYLog.warning(.app, "SimctlDevicesScanner JSON 解析失败: \(error)")
            return []
        }
        guard let root = object as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else {
            GSYLog.warning(.app, "SimctlDevicesScanner 顶层结构不匹配（缺 devices dict）")
            return []
        }

        var result: [SimctlDevice] = []
        result.reserveCapacity(devicesByRuntime.count * 4)
        // 排序保证 detect 输出确定性（同 runtime 下保留 simctl 原顺序）
        for runtimeID in devicesByRuntime.keys.sorted() {
            guard let list = devicesByRuntime[runtimeID] as? [[String: Any]] else { continue }
            for raw in list {
                guard let udid = raw["udid"] as? String,
                      let name = raw["name"] as? String,
                      let state = raw["state"] as? String,
                      let dataPath = raw["dataPath"] as? String else {
                    continue
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
