import Foundation

/// Apple 工作流配套：simctl 运行时（iOS / watchOS / tvOS / visionOS Runtimes）扫描器（v1.7 M1 PR-3）。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §Apple）：
/// - 现状：`~/Library/Developer/CoreSimulator/Volumes/iOS_*` 是 Xcode 16+ 后落地的
///   「按需下载 Runtime」存储位置，单个 runtime 通常数 GB。
/// - 目标：扫出已安装 runtime 清单、系统报告大小与安全卸载 UUID，
///   交给 [DeveloperWorkflow] 的 Apple 卡片渲染。
///
/// 与 [PkgutilReceiptsScanner] / [KnownVersionedRoots] 的关系：
/// - 三者都是"路径源探测器"，但 runtime 清单与安全卸载 ID 的权威来源是
///   `xcrun simctl runtime list -j`。它直接给出 runtime UUID、`deletable` 与 `sizeBytes`，
///   不需要扫描整个 RuntimeRoot 才能展示大小。
/// - 老版 Xcode 不支持上述命令时，才 fallback 到 `simctl list runtimes --json`。
///   legacy payload 没有系统卸载 UUID，因此只展示，不会把 semantic identifier 当成卸载参数。
///
/// 双入口（对位 [KnownVersionedRoots] 静态 detect + actor discover 范式）：
/// 1. `static detect(from json:)`：**纯解析**，无 IO，专供单测；
/// 2. `actor discover()`：起 subprocess 拿 JSON，不遍历 runtime 目录，生产用。
///
/// 完整性红线：
/// - 只有成功命令返回合法空 payload 才是 `[]`；
/// - launch / timeout / nonzero / schema 变化都必须成为 typed failure + Workflow evidence；
/// - managed 子命令真实“不支持”可 fallback legacy，但 managed 成功却 JSON 非法不能被 fallback
///   掩盖，因为那代表当前 Xcode 输出合同已变化。
public actor SimctlRuntimeScanner {

    private let executor: SubprocessExecutor

    public init(executor: SubprocessExecutor) {
        self.executor = executor
    }

    /// 优先起 `xcrun simctl runtime list -j` 拿托管 runtime 元数据。
    ///
    /// **2026-07-15 根因修复**：旧实现先拿 legacy list，再遍历每个 RuntimeRoot
    /// 估算大小，同时把 semantic identifier 传给 `runtime delete`。新实现使用 simctl
    /// 直接返回的 UUID/sizeBytes；仅当新命令不可用时才进入只读 legacy fallback。
    ///
    /// - Returns: runtime 列表；完整成功空 payload 才返回 `[]`。
    /// - Throws: [SimctlDiscoveryError]，上层必须保留为不完整证据。
    public func discover() async throws -> [SimctlRuntime] {
        let managedResult: SubprocessExecutor.Result
        do {
            managedResult = try executor.run(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "runtime", "list", "-j"]
            )
        } catch {
            throw SimctlDiscoveryError.commandRejected(query: .managedRuntimes)
        }

        if managedResult.exitCode == 0 {
            guard let runtimes = Self.decodeManagedRuntimeList(from: managedResult.output) else {
                throw SimctlDiscoveryError.invalidPayload(query: .managedRuntimes)
            }
            return runtimes
        }
        if managedResult.exitCode == -1 || managedResult.exitCode == -2 {
            throw SimctlDiscoveryError.commandFailure(
                for: managedResult,
                query: .managedRuntimes
            )!
        }
        guard Self.shouldUseLegacyFallback(for: managedResult) else {
            throw SimctlDiscoveryError.commandFailed(
                query: .managedRuntimes,
                exitCode: managedResult.exitCode
            )
        }

        // 仅当输出明确表示 runtime 子命令不存在时，才按“旧 Xcode”降级。
        // 其它 nonzero 可能是当前 Xcode/CoreSimulator 故障，必须保留为 incomplete，不能
        // 静默变成 legacy 伪完整结果。
        // legacy 没有 runtime disk-image UUID，managedUninstallIdentifier 始终为 nil。
        let legacyResult: SubprocessExecutor.Result
        do {
            legacyResult = try executor.run(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "list", "runtimes", "--json"]
            )
        } catch {
            throw SimctlDiscoveryError.commandRejected(query: .legacyRuntimes)
        }
        if let failure = SimctlDiscoveryError.commandFailure(
            for: legacyResult,
            query: .legacyRuntimes
        ) {
            throw failure
        }
        guard let parsed = Self.decodeLegacyRuntimeList(from: legacyResult.output) else {
            throw SimctlDiscoveryError.invalidPayload(query: .legacyRuntimes)
        }
        return parsed
    }

    /// 纯解析入口：支持 managed runtime map 与 legacy runtimes array 两种 JSON。
    ///
    /// 兼容 hits-only 测试/调用方的纯解析入口。生产 discover 不使用此入口判断完整性。
    public static func detect(from json: String) -> [SimctlRuntime] {
        if let managed = decodeManagedRuntimeList(from: json) {
            return managed
        }
        return decodeLegacyRuntimeList(from: json) ?? []
    }

    /// 严格纯解析入口。合法 managed/legacy 空 payload 返回空；结构不匹配抛 typed failure。
    public static func decode(from json: String) throws -> [SimctlRuntime] {
        if let managed = decodeManagedRuntimeList(from: json) {
            return managed
        }
        if let legacy = decodeLegacyRuntimeList(from: json) {
            return legacy
        }
        throw SimctlDiscoveryError.invalidPayload(query: .managedRuntimes)
    }

    /// legacy fallback 的窄能力判定。CLI 文本只参与能力探测，不进入用户文案；任意普通
    /// runtime failure 都返回 false，由 Workflow 显示可重试的扫描失败。
    static func shouldUseLegacyFallback(for result: SubprocessExecutor.Result) -> Bool {
        guard result.exitCode > 0 else { return false }
        let output = result.output.lowercased()
        guard output.contains("runtime") else { return false }
        return output.contains("unrecognized subcommand")
            || output.contains("unknown subcommand")
            || output.contains("unknown command")
            || output.contains("invalid command")
    }

    // MARK: - JSON DTO

    private static func decodeManagedRuntimeList(from json: String) -> [SimctlRuntime]? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: ManagedRuntimeDTO].self, from: data) else {
            return nil
        }

        var runtimes: [SimctlRuntime] = []
        runtimes.reserveCapacity(payload.count)
        for (key, dto) in payload {
            let uninstallIdentifier = dto.identifier ?? key
            guard let runtimeIdentifier = dto.runtimeIdentifier,
                  let version = dto.version,
                  let runtimeRoot = dto.runtimeBundlePath ?? dto.mountPath else {
                // 成功 JSON 中出现不符合 runtime DTO 的 entry 是 schema mismatch，不能
                // compactMap 成“完整空清单”。
                return nil
            }
            let hasCanonicalUUID = UUID(uuidString: uninstallIdentifier) != nil
            let safeUninstallIdentifier = dto.deletable == true && hasCanonicalUUID
                ? uninstallIdentifier
                : nil
            runtimes.append(SimctlRuntime(
                runtimeIdentifier: runtimeIdentifier,
                managedUninstallIdentifier: safeUninstallIdentifier,
                version: version,
                buildversion: dto.build,
                runtimeRoot: runtimeRoot,
                isAvailable: dto.state == nil || dto.state == "Ready",
                deletable: dto.deletable,
                sizeBytes: dto.sizeBytes,
                discoverySource: .managed
            ))
        }
        return runtimes.sorted { $0.runtimeIdentifier < $1.runtimeIdentifier }
    }

    private static func decodeLegacyRuntimeList(from json: String) -> [SimctlRuntime]? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LegacyRuntimeListPayload.self, from: data) else {
            return nil
        }
        return payload.runtimes.map { dto in
            SimctlRuntime(
                runtimeIdentifier: dto.identifier,
                managedUninstallIdentifier: nil,
                version: dto.version,
                buildversion: dto.buildversion,
                runtimeRoot: dto.runtimeRoot,
                isAvailable: dto.isAvailable,
                deletable: nil,
                sizeBytes: nil,
                discoverySource: .legacyReadOnly
            )
        }
    }

    private struct ManagedRuntimeDTO: Decodable {
        let identifier: String?
        let runtimeIdentifier: String?
        let version: String?
        let build: String?
        let runtimeBundlePath: String?
        let mountPath: String?
        let state: String?
        let deletable: Bool?
        let sizeBytes: Int64?
    }

    /// legacy 顶层：`{"runtimes": [ ... ]}`
    private struct LegacyRuntimeListPayload: Decodable {
        let runtimes: [LegacyRuntimeDTO]
    }

    private struct LegacyRuntimeDTO: Decodable {
        let identifier: String
        let version: String
        let buildversion: String?
        let runtimeRoot: String
        let isAvailable: Bool
    }
}

/// 单个 simctl 运行时记录。
public struct SimctlRuntime: Sendable, Hashable, Identifiable {
    public enum DiscoverySource: Sendable, Hashable {
        case managed
        /// 旧 Xcode 的 legacy list 没有 disk-image UUID / deletable / sizeBytes；只能展示，
        /// 不能勾选为 App 内受管卸载项。
        case legacyReadOnly
    }

    /// 如 `"com.apple.CoreSimulator.SimRuntime.iOS-18-0"`，用于展示与设备关联。
    /// 它不是 `simctl runtime delete` 的安全参数。
    public let runtimeIdentifier: String
    /// `simctl runtime list -j` 返回的 disk-image UUID。
    /// 只有 UUID 合法且 `deletable == true` 时才有值；legacy 扫描恒为 nil。
    public let managedUninstallIdentifier: String?
    /// 如 `"18.0"`。
    public let version: String
    /// 如 `"22A348"`；老版本 simctl 可能不返回，所以可空。
    public let buildversion: String?
    /// managed payload 优先使用 runtimeBundlePath，缺失时用 mountPath；legacy 为 runtimeRoot。
    public let runtimeRoot: String
    /// legacy 直接使用 isAvailable；managed payload 根据 `state == Ready` 判定。
    public let isAvailable: Bool
    /// 系统托管 runtime list 中的原始 `deletable` 状态；legacy payload 为 nil（未知）。
    public let deletable: Bool?
    /// managed payload 的系统报告占用（字节）；legacy 因不再遍历大型目录而为 nil。
    public let sizeBytes: Int64?
    public let discoverySource: DiscoverySource

    public var id: String { managedUninstallIdentifier ?? runtimeIdentifier }

    public init(runtimeIdentifier: String,
                managedUninstallIdentifier: String?,
                version: String,
                buildversion: String?,
                runtimeRoot: String,
                isAvailable: Bool,
                deletable: Bool?,
                sizeBytes: Int64?,
                discoverySource: DiscoverySource = .managed) {
        self.runtimeIdentifier = runtimeIdentifier
        self.managedUninstallIdentifier = managedUninstallIdentifier
        self.version = version
        self.buildversion = buildversion
        self.runtimeRoot = runtimeRoot
        self.isAvailable = isAvailable
        self.deletable = deletable
        self.sizeBytes = sizeBytes
        self.discoverySource = discoverySource
    }
}
