import Foundation
import LogKit

/// Dynamic-hit 副标题的跨模块语义，而不是已经本地化的 String。
///
/// **v2026.07.15 根因修复**：simctl 的 `Shutdown` / `Booted` / availability 是协议值，
/// 过去被直接拼进 note，中文 UI 因而永久混入英文。ScanKit 现在只传递有限语义，AppUI
/// 在当前 locale 下投影；未知的新 simctl 状态也不会把 raw token 泄露给用户。
public enum WorkflowScanHitNote: Sendable, Hashable {
    public enum SimulatorDeviceState: Sendable, Hashable {
        case shutdown
        case booted
        case transitioning
        case unknown

        init(simctlValue: String) {
            switch simctlValue.lowercased() {
            case "shutdown": self = .shutdown
            case "booted": self = .booted
            case "booting", "shutting down", "creating": self = .transitioning
            default: self = .unknown
            }
        }
    }

    public enum SimulatorRuntimeManagement: Sendable, Hashable {
        case uninstallable
        case legacyReadOnly
        case notDeletable
    }

    case verbatim(String)
    case simulatorDevice(state: SimulatorDeviceState, runtimeIdentifier: String)
    case simulatorRuntime(
        runtimeIdentifier: String,
        isAvailable: Bool,
        management: SimulatorRuntimeManagement
    )
}

/// 「动态扫描器」统一产物（v1.7 M1 PR-4 骨架）。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §动态卡片）：
/// - [DeveloperCard.PathSource.dynamicScanner] 用 `scannerID` 字符串把卡片入口与具体扫描器解耦，
///   但 UI 侧最终需要一个**结构一致**的产物列表才能渲染（标题 / 大小 / 备注 / 唯一 ID）。
/// - 不同扫描器原生类型差异极大：
///   - [SimctlDevice] 主键是 `udid`、占用走 `dataPathSize`；
///   - [SimctlRuntime] 展示主键是 `runtimeIdentifier`，可卸载主键是 simctl runtime UUID；
///   - DerivedDataPerProject 主键是子目录路径、占用走 FS 估算。
/// - [WorkflowScanHit] 把这些异构产物折叠为统一 DTO，让 AppUI 侧不必关心扫描器内部细节。
///
/// 字段语义：
/// - `url`：对应资源的文件 URL（设备 sandbox / runtime 镜像目录 / DerivedData 子工程目录）。
///   即便扫描器原生数据没有 URL（如 simctl runtime 只给字符串），也必须由 [WorkflowRegistry] 转 file URL。
/// - `sizeBytes`：占用估算字节数；不可得时为 `nil`，UI 据此显示 "—" 而非 "0 B"。
/// - `displayName`：用户可读名（如 "iPhone 16 · iOS 18.0"）。
/// - `note`：普通文件路径/Project Hash 等不可翻译副标题；
/// - `semanticNote`：simctl 状态等需要在 AppUI 当前 locale 下投影的类型化副标题；
/// - `managedUninstallIdentifier`：仅 `.managedUninstall` recipe 卡片需要。
///   设备卡填 UDID；runtime 卡只有在 `simctl runtime list -j` 明确给出可卸载 UUID 时才填值。
///   legacy runtime list 可用于展示，但不把 semantic runtime identifier 冒充为安全卸载 ID。
/// - `id`：`Identifiable` 契约。统一用 `url.path` 作为稳定主键——这是所有动态扫描器都能提供的最低公约数，
///   避免不同扫描器各自选 udid / identifier 导致跨源 diff 时主键冲突。
public struct WorkflowScanHit: Sendable, Hashable, Identifiable {
    public let url: URL
    public let sizeBytes: Int64?
    public let displayName: String
    public let note: String?
    public let semanticNote: WorkflowScanHitNote?
    public let managedUninstallIdentifier: String?

    public var id: String { url.path }

    public init(url: URL,
                sizeBytes: Int64?,
                displayName: String,
                note: String?,
                semanticNote: WorkflowScanHitNote? = nil,
                managedUninstallIdentifier: String? = nil) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.displayName = displayName
        self.note = note
        self.semanticNote = semanticNote ?? note.map(WorkflowScanHitNote.verbatim)
        self.managedUninstallIdentifier = managedUninstallIdentifier
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
/// 完整性红线：
/// - 未知 `scannerID` → 兼容入口返回 `[]` 并打 warning；
/// - 文件系统扫描器的空 hits 必须和 `incompleteIssues` 一起消费，不能把 I/O 失败当作完整空结果；
/// - 任务取消由 evidence API 独立抛出 `CancellationError`，不伪装成磁盘扫描故障。
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
    /// - Returns: 统一产物列表；保留旧 hits-only 行为。
    public static func resolve(scannerID: String,
                               home: URL,
                               executor: SubprocessExecutor? = nil,
                               includeFilesystemSizes: Bool = true) async -> [WorkflowScanHit] {
        do {
            return try await resolveWithEvidence(
                scannerID: scannerID,
                home: home,
                executor: executor,
                includeFilesystemSizes: includeFilesystemSizes
            ).hits
        } catch is CancellationError {
            return []
        } catch {
            AmuxLog.error(.scan, "WorkflowRegistry unexpected discovery error scannerID=\(scannerID): \(error)")
            return []
        }
    }

    /// 结构化动态发现入口。文件系统缺口写入 evidence，任务取消独立抛出。
    public static func resolveWithEvidence(
        scannerID: String,
        home: URL,
        executor: SubprocessExecutor? = nil,
        includeFilesystemSizes: Bool = true
    ) async throws -> DiscoveryEvidence<WorkflowScanHit> {
        try await resolveWithEvidence(
            scannerID: scannerID,
            home: home,
            executor: executor,
            includeFilesystemSizes: includeFilesystemSizes,
            fileSystem: FileManager.default,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    /// 模块内注入入口，供确定性故障测试复用与产品入口相同的路由逻辑。
    static func resolveWithEvidence(
        scannerID: String,
        home: URL,
        executor: SubprocessExecutor?,
        includeFilesystemSizes: Bool,
        fileSystem: any DynamicDiscoveryFileSystem,
        cancellationCheck: () throws -> Void
    ) async throws -> DiscoveryEvidence<WorkflowScanHit> {
        try cancellationCheck()
        switch scannerID {
        case "scanner.derived-data-per-project":
            // v1.7 M1 PR-4：实接 DerivedDataPerProjectScanner.detect。
            // 选 detect 而非 discover 是因为该扫描器无 subprocess、纯 FS 遍历，
            // 不需要 actor 串行化，同步入口可避免一次 Task 切换开销。
            let projects = try DerivedDataPerProjectScanner.detectWithEvidence(
                home: home,
                includeSizes: includeFilesystemSizes,
                fileSystem: fileSystem,
                cancellationCheck: cancellationCheck
            )
            return projects.mapHits { project in
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
                try cancellationCheck()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 完整成功空清单与失败严格分离；typed failure 变成 card-scoped evidence。
                AmuxLog.warning(.app, "WorkflowRegistry simctl-devices discovery incomplete: \(error)")
                return DiscoveryEvidence(hits: [], incompleteIssues: [
                    ScanIncompleteIssue(path: "/usr/bin/xcrun", reason: .enumerationFailed)
                ])
            }
            return DiscoveryEvidence(hits: devices.map { device in
                WorkflowScanHit(
                    url: URL(fileURLWithPath: device.dataPath),
                    sizeBytes: device.dataPathSize,
                    displayName: "\(device.name) · \(device.udid)",
                    note: nil,
                    semanticNote: .simulatorDevice(
                        state: .init(simctlValue: device.state),
                        runtimeIdentifier: device.runtimeIdentifier
                    ),
                    managedUninstallIdentifier: device.udid
                )
            })

        case "scanner.simctl-runtimes":
            let scanner = SimctlRuntimeScanner(executor: executor ?? SubprocessExecutor())
            let runtimes: [SimctlRuntime]
            do {
                runtimes = try await scanner.discover()
                try cancellationCheck()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AmuxLog.warning(.app, "WorkflowRegistry simctl-runtimes discover 抛错: \(error)")
                return DiscoveryEvidence(hits: [], incompleteIssues: [
                    ScanIncompleteIssue(path: "/usr/bin/xcrun", reason: .enumerationFailed)
                ])
            }
            return DiscoveryEvidence(hits: runtimes.map(simulatorRuntimeHit))

        case "scanner.node-modules-scattered":
            // WebNode 工作流：扫描 5 个常见 dev 根下的所有 node_modules。
            // 选 detect 而非 discover 是因为该扫描器无 subprocess、纯 FS 遍历，
            // 不需要 actor 串行化，同步入口可避免一次 Task 切换开销。
            //
            // 字段映射：
            // - displayName = projectName（父目录名），UI 优先展示工程名而非冗长路径；
            // - note = url.path，UI 用完整路径 disambiguate 跨根同名工程（如 ~/Code/foo vs ~/Projects/foo）。
            let hits = try NodeModulesScanner.detectWithEvidence(
                home: home,
                maxDepth: 4,
                includeSizes: includeFilesystemSizes,
                fileSystem: fileSystem,
                cancellationCheck: cancellationCheck
            )
            return hits.mapHits { hit in
                WorkflowScanHit(
                    url: hit.url,
                    sizeBytes: hit.sizeBytes,
                    displayName: hit.projectName,
                    note: hit.url.path
                )
            }

        default:
            AmuxLog.warning(.app, "WorkflowRegistry 收到未知 scannerID=\(scannerID)，返回空列表")
            return DiscoveryEvidence(hits: [])
        }
    }

    /// 把 runtime 原始模型投影为通用 hit。独立纯函数让平台名称与 managed UUID 边界
    /// 可以不启动 xcrun 直接回归测试。
    static func simulatorRuntimeHit(_ runtime: SimctlRuntime) -> WorkflowScanHit {
        let buildSuffix = runtime.buildversion.map { " (\($0))" } ?? ""
        return WorkflowScanHit(
            url: URL(fileURLWithPath: runtime.runtimeRoot),
            sizeBytes: runtime.sizeBytes,
            // **v2026.07.16 根因修复**：显示名必须来自 SimctlRuntime 保留的
            // platformIdentifier/semantic identifier，不能在统一路由层硬编码 iOS。
            displayName: "\(runtime.displayName)\(buildSuffix)",
            note: nil,
            semanticNote: .simulatorRuntime(
                runtimeIdentifier: runtime.runtimeIdentifier,
                isAvailable: runtime.isAvailable,
                management: runtime.managedUninstallIdentifier != nil
                    ? .uninstallable
                    : (runtime.discoverySource == .legacyReadOnly
                       ? .legacyReadOnly
                       : .notDeletable)
            ),
            managedUninstallIdentifier: runtime.managedUninstallIdentifier
        )
    }
}
