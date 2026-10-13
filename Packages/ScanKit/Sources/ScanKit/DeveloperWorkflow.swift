import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 「开发者一键清理」工作流抽象（v1.7 M1 骨架）。
///
/// 设计动机（详见 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md)）：
/// - 现状：iOS / Android / Flutter / Node 等开发者向规则散落在 vendors.yaml + DevArtifactRules + KnownVersionedRoots；
///   用户视角无法"按工作流一键勾选"，比如 iOS 开发者要点 7、8 个不同入口才能清完
///   DerivedData / Archives / DeviceSupport / CoreSimulator Caches 等。
/// - 目标：把"按生态分组的工作流"抽成统一协议，每个 Workflow 暴露若干 Card，
///   UI 侧（AppUI v1.7 后续 PR）渲染为侧边栏二级节点 + 详情区可勾选清单。
///
/// 本骨架版本（v1.7 M1 PR-1）的边界：
/// 1. **仅落协议 + Apple 空实现**：cards() 暂返 `[]`，编译可过、不影响现网；
/// 2. **不接 AppUI / 不进侧边栏**：避免半成品功能误导用户；
/// 3. **托管卸载是封闭集合**：CoreSimulator 资源只能选择 [ManagedUninstallRecipe]
///    中预先定义的类型，不向上层暴露任意可执行文件与参数。
///
/// 与 [Scanner] / [VersionedRetainScanner] 的关系：
/// - Workflow 是**入口层**，决定"展示什么卡片、卡片对应哪些路径源"；
/// - 真正的扫描仍交给 BulkScanner / VersionedRetainScanner / KnownVersionedRoots.scanAll；
/// - Workflow 只做"路径源 → Card → 待 SafetyEngine 评估"的编排。
public protocol DeveloperWorkflow: Sendable {

    /// 工作流稳定 ID，用于持久化用户的"折叠/勾选"状态。
    /// 命名约定：`workflow.<ecosystem>`，如 `workflow.apple` / `workflow.android` / `workflow.web-node`。
    var id: String { get }

    /// 侧边栏展示名（中文为主，i18n 由上层处理）。
    var displayName: String { get }

    /// 工作流副标题/简述（≤ 40 字），在详情区顶部展示。
    var subtitle: String { get }

    /// 该工作流的卡片清单。
    ///
    /// **本骨架版本一律返回空列表**——具体卡片由后续 PR 注入。
    /// 设计上允许该方法读取 home / 环境探测（如检测是否安装 Xcode、是否存在 `~/Library/Android/sdk`）
    /// 来动态决定是否展示某张卡，避免空集合污染 UI。
    func cards(home: URL) -> [DeveloperCard]
}

/// 一张「开发者清理卡片」。
public struct DeveloperCard: Sendable, Hashable, Identifiable {
    /// Optional semantic role for cards that are two projections of one filesystem scan.
    /// AppUI may coalesce matching roles into one immutable snapshot; this is scan planning
    /// metadata only and never changes deletion semantics.
    public enum SharedScanRole: Sendable, Hashable {
        case derivedDataRoot
        case derivedDataProjects
    }

    /// 稳定 ID，命名约定 `card.<workflow>.<topic>`，如 `card.apple.derived-data`。
    public let id: String
    /// 卡片标题，如 "Xcode DerivedData"。
    public let title: String
    /// 简短描述（≤ 60 字），如 "Xcode 编译派生数据，可被任意 Xcode 命令重建"。
    public let summary: String
    /// 该卡片对应的"路径源"。可能是单条目录，也可能是 KnownVersionedRoots 中的某个 ruleID。
    public let source: PathSource
    /// 删除方案。详见 [DeletionRecipe]。
    public let recipe: DeletionRecipe
    /// 风险等级：safe / confirm / blocked。
    /// - safe：可静默列入推荐清理；
    /// - confirm：必须用户显式确认；
    /// - blocked：仅在某条件解除后才允许（如 Simulator 运行中的版本目录）。
    public let risk: Risk
    /// 与该卡文件路径直接关联的 macOS App bundle ID 前缀。它只驱动删除前的
    /// “应用仍在运行”提示，不参与 Safety 判定，也不能放宽任何删除规则。
    public let runningBundleIDPrefix: String?
    /// **v2026.07.16 root-cause fix:** explicitly models shared DerivedData projections so
    /// the scheduler does not infer relationships from card IDs or path-name hardcoding.
    public let sharedScanRole: SharedScanRole?

    public init(id: String,
                title: String,
                summary: String,
                source: PathSource,
                recipe: DeletionRecipe,
                risk: Risk,
                runningBundleIDPrefix: String? = nil,
                sharedScanRole: SharedScanRole? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.source = source
        self.recipe = recipe
        self.risk = risk
        self.runningBundleIDPrefix = runningBundleIDPrefix
        self.sharedScanRole = sharedScanRole
    }

    /// 风险等级（与 SafetyEngine 三档对齐，但语义更偏 UI 展示）。
    public enum Risk: String, Sendable, Hashable {
        case safe
        case confirm
        case blocked
    }

    /// 卡片对应的路径来源。
    public enum PathSource: Sendable, Hashable {
        /// 直接给定一组绝对/相对（相对 home）路径。
        case literal(paths: [String])
        /// 复用 [KnownVersionedRoots] 中的某条 ruleID，调用方 scanAll 取 hits 即可。
        case versionedRoot(ruleID: String)
        /// 复用 vendors.yaml 中某 vendor 的所有 path。
        case vendor(name: String)
        /// 由专用 Scanner 提供（如 SimctlDevicesScanner 输出的 device 列表）。
        /// `scannerID` 由 AppUI 侧 ScannerRegistry 注册，避免本协议直接耦合具体 scanner。
        case dynamicScanner(scannerID: String)
    }
}

/// 由系统管理器执行的卸载类型。
///
/// **2026-07-15 安全边界修订**：原有 `DeletionRecipe.commandLine` 可以携带任意
/// executable/args，使得清理数据模型变成了泛化命令执行通道。现改为封闭 enum：
/// 上层只能选择已审核的 CoreSimulator 资源类型，实际执行仍必须再经过
/// [SubprocessExecutor] allowlist 与尾参格式双重校验。
public enum ManagedUninstallRecipe: String, CaseIterable, Sendable, Hashable {
    case simulatorDevice
    case simulatorRuntime

    /// 托管卸载的系统入口。枚举不接受外部 executable，避免数据注入。
    public var executable: String { "/usr/bin/xcrun" }

    /// 不包含资源标识符的固定参数前缀。
    public var argsPrefix: [String] {
        switch self {
        case .simulatorDevice:
            return ["simctl", "delete"]
        case .simulatorRuntime:
            return ["simctl", "runtime", "delete"]
        }
    }
}

/// 清理方案：决定 UI 点击"清理"按钮后的实际动作。
public enum DeletionRecipe: Sendable, Hashable {
    /// 走 [NSWorkspace.recycle]——这是项目唯一允许的"删除"通道，最终落回收站。
    case filesystem
    /// 走受管系统 API 的卸载通道。不允许调用方自定义 executable/args。
    case managedUninstall(ManagedUninstallRecipe)

    /// 当前是否允许直接执行。
    ///
    /// - `.filesystem`：永远允许（回收站删除是项目唯一的安全删除通道）；
    /// - `.managedUninstall`：固定命令前缀仍必须命中 SubprocessExecutor.defaultAllowlist。
    ///   这一层是执行器之外的第二道安全闸门。
    public var isExecutableInCurrentBuild: Bool {
        switch self {
        case .filesystem:
            return true
        case .managedUninstall(let managed):
            return SubprocessExecutor.defaultAllowlist.contains { entry in
                entry.executable == managed.executable
                    && entry.argsPrefix == managed.argsPrefix
            }
        }
    }
}

// MARK: - Apple 工作流（PR-1：6 张静态卡片 + PR-2：3 张 simctl/per-project 卡片）

/// Apple（iOS / macOS / watchOS / tvOS / visionOS）开发者工作流。
///
/// **v1.7 M1 PR-1**：注入 6 张零代码风险卡片（DerivedData / Archives / DeviceSupport×3 / CoreSimulator Caches）。
/// **v1.7 M1 PR-2**：追加 3 张高价值卡片：
/// - `card.apple.coresimulator-devices`：simctl 设备实例（托管卸载，Simulator 运行中 → blocked）
/// - `card.apple.coresimulator-runtimes`：simctl runtime（托管卸载，Simulator 运行中 → blocked）
/// - `card.apple.derived-data-per-project`：DerivedData 按工程分粒度（.filesystem，dynamicScanner 占位待 PR-4）
///
/// **v2026.07.15 安全修复**：不再生成 `CoreSimulator/Volumes` 文件系统卡。
/// 该目录是 CoreSimulator 挂载的只读 runtime 卷；仓库规则与事故文档均将其列为
/// forbid。Runtime 只能通过上面的受管 `simctl runtime delete` 卡处理，不能伪装成
/// 可移到废纸篓的普通目录。
///
/// 所有路径均与 [vendors.yaml Apple Developer Tools](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendors.yaml#L16-L102) 对位，
/// 不绕开 SafetyEngine、不引入新规则源，仅做"按工作流分组"的入口聚合。
///
/// 设计要点：
/// 1. **以 .literal 为主**：vendors.yaml 中 "Apple Developer Tools" 是单 vendor 包含 21 条 path，
///    若用 `.vendor("Apple Developer Tools")` 会一键打包 Xcode + Simulator + SwiftPM 全集，违背"按主题分卡"目标；
/// 2. **DeviceSupport 三卡走 .versionedRoot**：复用 [KnownVersionedRoots] 的 keepLatest=2 语义，
///    避免把"当前在用的 18.0"误识别为旧版；
/// 3. **存在性检测**：每张卡都先确认对应目录存在再展示，避免空入口污染 UI；
/// 4. **risk 与 vendors.yaml verdict 严格对齐**：DerivedData/CoreSimulator Caches=safe，Archives=confirm；
///    CoreSimulator Volumes=forbid，因此根本不生成清理卡；
/// 5. **.managedUninstall recipe 必须命中 [SubprocessExecutor.defaultAllowlist]**：
///    `isExecutableInCurrentBuild` 会做二次校验，未授权命令的卡片 UI 不允许执行；
/// 6. **Simulator 运行中 → risk = blocked**：检测 `com.apple.iphonesimulator` bundle id 是否在
///    NSRunningApplication 列表，命中则 devices/runtimes 两卡降级为 blocked，避免破坏正在运行的实例。
public struct AppleWorkflow: DeveloperWorkflow {
    public let id: String = "workflow.apple"
    /// i18n key —— UI 层用 `Text(LocalizedStringKey(...), bundle: .module)` 渲染。
    public let displayName: String = "workflow.apple.displayName"
    /// i18n key —— UI 层用 `Text(LocalizedStringKey(...), bundle: .module)` 渲染。
    public let subtitle: String = "workflow.apple.subtitle"

    /// Simulator 运行检测器：闭包注入便于测试时替换为 stub。
    /// 默认实现走 NSWorkspace（仅 macOS 主进程可用，单测中可注入恒 false 的 stub）。
    private let isSimulatorRunning: @Sendable () -> Bool

    public init(isSimulatorRunning: @escaping @Sendable () -> Bool = AppleWorkflow.defaultSimulatorRunning) {
        self.isSimulatorRunning = isSimulatorRunning
    }

    /// 默认 Simulator 运行检测：扫描 NSRunningApplication 是否含 `com.apple.iphonesimulator`。
    ///
    /// 非 macOS 主进程（如 swift test 在某些 CI 环境）可能拿不到 NSWorkspace，
    /// 此时返回 false（保守降级——宁可放行也不误 block）。
    public static let defaultSimulatorRunning: @Sendable () -> Bool = {
        #if canImport(AppKit)
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { $0.bundleIdentifier == "com.apple.iphonesimulator" }
        #else
        return false
        #endif
    }

    public func cards(home: URL) -> [DeveloperCard] {
        var result: [DeveloperCard] = []
        result.reserveCapacity(9)

        // 0. 大前提：Xcode 开发者目录存在才有展示意义；否则视为"非 Apple 开发者机器"返回空。
        let xcodeRoot = home.appendingPathComponent("Library/Developer/Xcode", isDirectory: true)
        let csRoot = home.appendingPathComponent("Library/Developer/CoreSimulator", isDirectory: true)
        guard Self.dirExists(xcodeRoot) || Self.dirExists(csRoot) else {
            return []
        }

        // 1. DerivedData（safe）—— vendors.yaml L20-L22
        let derivedData = xcodeRoot.appendingPathComponent("DerivedData", isDirectory: true)
        if Self.dirExists(derivedData) {
            result.append(DeveloperCard(
                id: "card.apple.derived-data",
                title: "card.apple.derived-data.title",
                summary: "card.apple.derived-data.summary",
                source: .literal(paths: [derivedData.path]),
                recipe: .filesystem,
                risk: .safe,
                sharedScanRole: .derivedDataRoot))

            // 1b. DerivedData 按工程分粒度卡（PR-2 新增，dynamicScanner 占位）
            //     该卡与 card.apple.derived-data 同源不同粒度：整删走前者，按工程子目录单选走本卡
            //     真正的 per-project scanner 在 PR-4 接 UI 时实现，本 PR 仅注册卡片入口
            result.append(DeveloperCard(
                id: "card.apple.derived-data-per-project",
                title: "card.apple.derived-data-per-project.title",
                summary: "card.apple.derived-data-per-project.summary",
                source: .dynamicScanner(scannerID: "scanner.derived-data-per-project"),
                recipe: .filesystem,
                risk: .safe,
                sharedScanRole: .derivedDataProjects))
        }

        // 2. Archives（confirm）—— vendors.yaml L59-L61
        let archives = xcodeRoot.appendingPathComponent("Archives", isDirectory: true)
        if Self.dirExists(archives) {
            result.append(DeveloperCard(
                id: "card.apple.archives",
                title: "card.apple.archives.title",
                summary: "card.apple.archives.summary",
                source: .literal(paths: [archives.path]),
                recipe: .filesystem,
                risk: .confirm))
        }

        // 3-5. DeviceSupport 三系（safe）—— 走 KnownVersionedRoots 保留最新 2 版
        //      不直接清空 DeviceSupport 目录，避免误删当前在用版本
        for (subdir, ruleID, name) in [
            ("iOS DeviceSupport",    "apple.ios-device-support.versioned",     "card.apple.ios-devicesupport.title"),
            ("watchOS DeviceSupport", "apple.watchos-device-support.versioned", "card.apple.watchos-devicesupport.title"),
            ("macOS DeviceSupport",  "apple.macos-device-support.versioned",   "card.apple.macos-devicesupport.title"),
        ] {
            let dir = xcodeRoot.appendingPathComponent(subdir, isDirectory: true)
            guard Self.dirExists(dir) else { continue }
            // ID 中把空格替换为 dash，与 vendors.yaml 路径段一致但符合 ID 命名约定
            let idSuffix = subdir.lowercased().replacingOccurrences(of: " ", with: "-")
            result.append(DeveloperCard(
                id: "card.apple.\(idSuffix)",
                title: name,
                summary: "card.apple.devicesupport.summary",
                source: .versionedRoot(ruleID: ruleID),
                recipe: .filesystem,
                risk: .safe))
        }

        // 6. CoreSimulator Caches（safe）—— vendors.yaml L55-L57
        //    注意：不是 CoreSimulator 整目录，仅 Caches 子目录是 safe；Devices 走受管专卡，
        //    Volumes 是挂载卷并由规则 forbid，不能生成 filesystem 卡。
        let csCaches = csRoot.appendingPathComponent("Caches", isDirectory: true)
        if Self.dirExists(csCaches) {
            result.append(DeveloperCard(
                id: "card.apple.coresimulator-caches",
                title: "card.apple.coresimulator-caches.title",
                summary: "card.apple.coresimulator-caches.summary",
                source: .literal(paths: [csCaches.path]),
                recipe: .filesystem,
                risk: .safe))
        }

        // 7-8. simctl Devices / Runtimes（PR-2 新增，封闭的 managedUninstall recipe）
        //      Simulator 运行中检测：命中则 risk 降级为 blocked，UI 必须禁用删除按钮
        let simulatorRunning = isSimulatorRunning()
        let simctlRisk: DeveloperCard.Risk = simulatorRunning ? .blocked : .confirm

        // 7. Devices —— vendors.yaml L68-L71（Devices 整目录 verdict=confirm，单实例删除走 simctl delete）
        let csDevices = csRoot.appendingPathComponent("Devices", isDirectory: true)
        if Self.dirExists(csDevices) {
            result.append(DeveloperCard(
                id: "card.apple.coresimulator-devices",
                title: "card.apple.coresimulator-devices.title",
                summary: simulatorRunning
                    ? "card.apple.coresimulator-devices.summary.blocked"
                    : "card.apple.coresimulator-devices.summary",
                source: .dynamicScanner(scannerID: "scanner.simctl-devices"),
                recipe: .managedUninstall(.simulatorDevice),
                risk: simctlRisk))
        }

        // 8. Runtimes —— 通过 simctl runtime delete 删除老 iOS runtime
        //    仅当 CoreSimulator 根目录存在时输出（避免在纯 Xcode-only 机器上产生空入口）
        if Self.dirExists(csRoot) {
            result.append(DeveloperCard(
                id: "card.apple.coresimulator-runtimes",
                title: "card.apple.coresimulator-runtimes.title",
                summary: simulatorRunning
                    ? "card.apple.coresimulator-runtimes.summary.blocked"
                    : "card.apple.coresimulator-runtimes.summary",
                source: .dynamicScanner(scannerID: "scanner.simctl-runtimes"),
                recipe: .managedUninstall(.simulatorRuntime),
                risk: simctlRisk))
        }

        return result
    }

    /// 目录存在性检测：必须是目录、不是软链文件、不是普通文件。
    /// 命中 `isDirectory: false` 也算"不存在"——避免把同名文件误识别为可清理目录。
    private static func dirExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
