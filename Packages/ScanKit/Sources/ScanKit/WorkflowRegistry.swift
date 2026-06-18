import Foundation
import LogKit

/// 「动态扫描器」统一产物（v1.7 M1 PR-4 骨架）。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §动态卡片）：
/// - [DeveloperCard.PathSource.dynamicScanner] 用 `scannerID` 字符串把卡片入口与具体扫描器解耦，
///   但 UI 侧最终需要一个**结构一致**的产物列表才能渲染（标题 / 大小 / 备注 / 唯一 ID）。
/// - 不同扫描器原生类型差异极大：
///   - [SimctlDevice] 主键是 `udid`、占用走 `dataPathSize`；
///   - [SimctlRuntime] 主键是 `identifier`、占用走 sizeBytes 估算；
///   - DerivedDataPerProject 主键是子目录路径、占用走 FS 估算。
/// - [WorkflowScanHit] 把这些异构产物折叠为统一 DTO，让 AppUI 侧不必关心扫描器内部细节。
///
/// 字段语义：
/// - `url`：对应资源的文件 URL（设备 sandbox / runtime 镜像目录 / DerivedData 子工程目录）。
///   即便扫描器原生数据没有 URL（如 simctl runtime 只给字符串），也必须由 [WorkflowRegistry] 转 file URL。
/// - `sizeBytes`：占用估算字节数；不可得时为 `nil`，UI 据此显示 "—" 而非 "0 B"。
/// - `displayName`：用户可读名（如 "iPhone 16 · iOS 18.0"）。
/// - `note`：可选副标题，承载 state / runtime / Project Hash 等次要信息。
/// - `commandLineTailArg`：v1.7 M1 PR-9 新增。仅 `.commandLine` recipe 卡片需要——
///   该字段承载 `xcrun simctl delete <尾参>` 的尾参（设备卡填 UDID、runtime 卡填 identifier）；
///   `.filesystem` recipe 卡保持 `nil`。这样 AppUI 侧无需关心扫描器细节就能拼出完整 args。
/// - `id`：`Identifiable` 契约。统一用 `url.path` 作为稳定主键——这是所有动态扫描器都能提供的最低公约数，
///   避免不同扫描器各自选 udid / identifier 导致跨源 diff 时主键冲突。
public struct WorkflowScanHit: Sendable, Hashable, Identifiable {
    public let url: URL
    public let sizeBytes: Int64?
    public let displayName: String
    public let note: String?
    public let commandLineTailArg: String?

    public var id: String { url.path }

    public init(url: URL,
                sizeBytes: Int64?,
                displayName: String,
                note: String?,
                commandLineTailArg: String? = nil) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.displayName = displayName
        self.note = note
        self.commandLineTailArg = commandLineTailArg
    }
}

/// 动态扫描器路由表（v1.7 M1 PR-4 骨架）。
///
/// 设计动机：
/// - [DeveloperCard.PathSource.dynamicScanner(scannerID:)] 故意只持有字符串 ID，
///   避免 ScanKit 协议层直接依赖具体扫描器类型；
/// - 但 AppUI 侧渲染时需要"按 ID 找到扫描器并要数据"的能力，因此引入本路由表。
/// - 路由表本身**不持有状态**（纯 `enum` + `static func`），保证每次 resolve 都是确定性查询。
///
/// 容错红线（与 [SimctlDevicesScanner] / [SimctlRuntimeScanner] 一致）：
/// - 未知 `scannerID` → 返回 `[]` 并打 warning，**不抛**；
///   防止 UI 侧因为某张卡的 ID 拼错就把整个工作流卡死。
/// - 扫描器自身失败（simctl 不可用 / JSON 非法）→ 内部已兜底为 `[]`，本路由表只透传。
///
/// 与 AppUI 的边界：
/// - 本类型**只允许依赖 ScanKit 内部 + Foundation + LogKit**；
///   任何 AppUI 类型（如 SwiftUI View / ViewModel）都禁止 import，否则会引入循环依赖。
/// - AppUI 侧调用本 API 后，自己把 `[WorkflowScanHit]` 映射为列表 row。
public enum WorkflowRegistry {

    /// 把 `scannerID` 路由到对应扫描器并拿统一产物。
    ///
    /// - Parameters:
    ///   - scannerID: 与 [DeveloperCard.PathSource.dynamicScanner] 中的 ID 严格一致。
    ///   - home: 用户 home URL；仅 FS 类扫描器（如 derived-data-per-project）会用到。
    ///   - executor: 子进程执行器；为 `nil` 时按各扫描器约定使用默认实例。
    ///     测试侧可注入 `SubprocessExecutor(dryRun: true)` 避免真起 simctl。
    /// - Returns: 统一产物列表；未知 ID / 扫描器失败一律为 `[]`，**不抛**。
    public static func resolve(scannerID: String,
                               home: URL,
                               executor: SubprocessExecutor? = nil) async -> [WorkflowScanHit] {
        switch scannerID {
        case "scanner.derived-data-per-project":
            // v1.7 M1 PR-4：实接 DerivedDataPerProjectScanner.detect。
            // 选 detect 而非 discover 是因为该扫描器无 subprocess、纯 FS 遍历，
            // 不需要 actor 串行化，同步入口可避免一次 Task 切换开销。
            let projects = DerivedDataPerProjectScanner.detect(home: home)
            return projects.map { project in
                WorkflowScanHit(
                    url: project.url,
                    sizeBytes: project.sizeBytes,
                    displayName: project.projectName,
                    note: project.url.lastPathComponent
                )
            }

        case "scanner.simctl-devices":
            let scanner = SimctlDevicesScanner(executor: executor ?? SubprocessExecutor())
            let devices: [SimctlDevice]
            do {
                devices = try await scanner.discover()
            } catch {
                // discover 内部已兜底为 []，理论上不会抛；保留 catch 是为契约稳健性
                GSYLog.warning(.app, "WorkflowRegistry simctl-devices discover 抛错: \(error)")
                return []
            }
            return devices.map { device in
                WorkflowScanHit(
                    url: URL(fileURLWithPath: device.dataPath),
                    sizeBytes: device.dataPathSize,
                    displayName: "\(device.name) · \(device.udid)",
                    note: "\(device.state) · \(device.runtimeIdentifier)",
                    commandLineTailArg: device.udid
                )
            }

        case "scanner.simctl-runtimes":
            let scanner = SimctlRuntimeScanner(executor: executor ?? SubprocessExecutor())
            let runtimes: [SimctlRuntime]
            do {
                runtimes = try await scanner.discover()
            } catch {
                GSYLog.warning(.app, "WorkflowRegistry simctl-runtimes discover 抛错: \(error)")
                return []
            }
            return runtimes.map { runtime in
                let buildSuffix = runtime.buildversion.map { " (\($0))" } ?? ""
                return WorkflowScanHit(
                    url: URL(fileURLWithPath: runtime.runtimeRoot),
                    sizeBytes: runtime.sizeBytes,
                    displayName: "iOS \(runtime.version)\(buildSuffix)",
                    note: runtime.isAvailable ? runtime.identifier : "\(runtime.identifier) · unavailable",
                    commandLineTailArg: runtime.identifier
                )
            }

        case "scanner.node-modules-scattered":
            // WebNode 工作流：扫描 5 个常见 dev 根下的所有 node_modules。
            // 选 detect 而非 discover 是因为该扫描器无 subprocess、纯 FS 遍历，
            // 不需要 actor 串行化，同步入口可避免一次 Task 切换开销。
            //
            // 字段映射：
            // - displayName = projectName（父目录名），UI 优先展示工程名而非冗长路径；
            // - note = url.path，UI 用完整路径 disambiguate 跨根同名工程（如 ~/Code/foo vs ~/Projects/foo）。
            let hits = NodeModulesScanner.detect(home: home)
            return hits.map { hit in
                WorkflowScanHit(
                    url: hit.url,
                    sizeBytes: hit.sizeBytes,
                    displayName: hit.projectName,
                    note: hit.url.path
                )
            }

        default:
            GSYLog.warning(.app, "WorkflowRegistry 收到未知 scannerID=\(scannerID)，返回空列表")
            return []
        }
    }
}
