import Foundation

/// Apple 工作流配套：simctl 运行时（iOS / watchOS / tvOS / visionOS Runtimes）扫描器（v1.7 M1 PR-3）。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §Apple）：
/// - 现状：`~/Library/Developer/CoreSimulator/Volumes/iOS_*` 是 Xcode 16+ 后落地的
///   「按需下载 Runtime」存储位置，单个 18.x runtime ≈ 6~10 GB。用户没法在
///   Xcode UI 一键卸载旧版本，只能用 `xcrun simctl runtime delete <id>` 命令清。
/// - 目标：扫出已安装 runtime 清单 + 占用估算，交给 [DeveloperWorkflow] 的 Apple 卡片渲染，
///   后续 PR-4 接 `simctl runtime delete` 删除路径。
///
/// 与 [PkgutilReceiptsScanner] / [KnownVersionedRoots] 的关系：
/// - 三者都是"路径源探测器"，但本扫描器**不走 FS 枚举**——runtime 清单的权威是
///   `xcrun simctl list runtimes --json`（包含 `isAvailable` / `buildversion` 等元数据，
///   FS 枚举拿不到），FileManager 只参与 sizeBytes 估算这一步。
/// - 依赖 [SubprocessExecutor]：白名单已包含 `["simctl", "list", "runtimes", "--json"]`，
///   不可绕过；这是「v1.7 M1 PR-2 → PR-3」契约。
///
/// 双入口（对位 [KnownVersionedRoots] 静态 detect + actor discover 范式）：
/// 1. `static detect(from json:)`：**纯解析**，无 IO，无 sizeBytes 估算，专供单测；
/// 2. `actor discover()`：起 subprocess 拿 JSON、再补 sizeBytes，生产用。
///
/// 容错红线：
/// - simctl 不可用（exitCode ≠ 0）→ 返回 `[]`，**不抛**；
/// - JSON 非法 / 顶层结构不对 → 返回 `[]`，**不抛**；
/// - 这与 UI 侧"展示空清单 + 引导用户检查 Xcode 安装"的策略一致，避免错误冒泡污染整个工作流。
public actor SimctlRuntimeScanner {

    private let executor: SubprocessExecutor

    public init(executor: SubprocessExecutor) {
        self.executor = executor
    }

    /// 起 `xcrun simctl list runtimes --json` 拿全部已安装 runtime，并对每条估算 sizeBytes。
    ///
    /// - Returns: runtime 列表；任何失败（subprocess 报错、JSON 非法）一律返回 `[]`。
    public func discover() async throws -> [SimctlRuntime] {
        let result: SubprocessExecutor.Result
        do {
            result = try executor.run(
                executable: "/usr/bin/xcrun",
                args: ["simctl", "list", "runtimes", "--json"]
            )
        } catch {
            return []
        }
        // dryRun 或失败：output 不会是合法 JSON，detect 会返回 []
        guard result.isSuccess else { return [] }
        let parsed = Self.detect(from: result.output)
        // 补 sizeBytes 估算
        return parsed.map { runtime in
            SimctlRuntime(
                identifier: runtime.identifier,
                version: runtime.version,
                buildversion: runtime.buildversion,
                runtimeRoot: runtime.runtimeRoot,
                isAvailable: runtime.isAvailable,
                sizeBytes: Self.estimateSize(at: runtime.runtimeRoot)
            )
        }
    }

    /// 纯解析入口：把 simctl JSON 字符串转 `[SimctlRuntime]`，**不**填 sizeBytes（恒为 nil）。
    ///
    /// 任何解析失败（空串、非 JSON、顶层不是 `{"runtimes": [...]}`）一律返回 `[]`。
    public static func detect(from json: String) -> [SimctlRuntime] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8) else {
            return []
        }
        do {
            let payload = try JSONDecoder().decode(SimctlListPayload.self, from: data)
            return payload.runtimes.map { dto in
                SimctlRuntime(
                    identifier: dto.identifier,
                    version: dto.version,
                    buildversion: dto.buildversion,
                    runtimeRoot: dto.runtimeRoot,
                    isAvailable: dto.isAvailable,
                    sizeBytes: nil
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - sizeBytes 估算

    /// 遍历 runtimeRoot 目录累加 totalFileAllocatedSize。
    ///
    /// 失败语义：路径不存在 / 不是目录 / 无权限读 → 返回 nil（UI 侧显示 "—"）。
    /// 注意 runtimeRoot 实际是嵌套较深的 `.../iOS 18.0.simruntime/Contents/Resources/RuntimeRoot`，
    /// 这里**只统计该深层目录**，与 simctl 报告的"runtime 占用"语义对齐。
    static func estimateSize(at path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - JSON DTO

    /// 顶层：`{"runtimes": [ ... ]}`
    private struct SimctlListPayload: Decodable {
        let runtimes: [RuntimeDTO]
    }

    private struct RuntimeDTO: Decodable {
        let identifier: String
        let version: String
        let buildversion: String?
        let runtimeRoot: String
        let isAvailable: Bool
    }
}

/// 单个 simctl 运行时记录。
public struct SimctlRuntime: Sendable, Hashable, Identifiable {
    /// 如 `"com.apple.CoreSimulator.SimRuntime.iOS-18-0"`，simctl 的稳定主键。
    public let identifier: String
    /// 如 `"18.0"`。
    public let version: String
    /// 如 `"22A348"`；老版本 simctl 可能不返回，所以可空。
    public let buildversion: String?
    /// 如 `"/Library/Developer/CoreSimulator/Volumes/iOS_18.0/.../RuntimeRoot"`。
    public let runtimeRoot: String
    /// simctl 自报"是否可被 Simulator 使用"，**不可用**通常意味着签名失效 / 部分文件缺失，
    /// 但仍占盘，所以扫描器照样纳入结果，让 UI 决定是否过滤。
    public let isAvailable: Bool
    /// runtimeRoot 目录大小（字节）。`nil` 表示路径不存在或无权限读。
    public let sizeBytes: Int64?

    public var id: String { identifier }

    public init(identifier: String,
                version: String,
                buildversion: String?,
                runtimeRoot: String,
                isAvailable: Bool,
                sizeBytes: Int64?) {
        self.identifier = identifier
        self.version = version
        self.buildversion = buildversion
        self.runtimeRoot = runtimeRoot
        self.isAvailable = isAvailable
        self.sizeBytes = sizeBytes
    }
}
